#lang racket/base

;;; Phase 2.5 (roadmap/next/ensure_sso_works.md) — RS256/ES256 JWS signature
;;; verification for OIDC ID tokens, verify-ONLY, over openssl/libcrypto
;;; (libsodium has neither RSA nor P-256).  No signing: Apple stays out.
;;;
;;; The public key is built from the JWK by DER-encoding a SubjectPublicKeyInfo
;;; and handing it to `d2i_PUBKEY`, which avoids the low-level RSA_new /
;;; EVP_PKEY_assign_RSA APIs OpenSSL 3.x deprecates — the same code path works on
;;; 1.1.1 and 3.x.
;;;
;;; Fail-closed everywhere.  The refusals that stop the classic bypasses are the
;;; product here: alg:none, an HMAC alg on an ID token (sign-with-the-public-key),
;;; an alg outside the pinned set, key material NOMINATED by the token header
;;; (jwk/jku/x5u/x5c) or a `crit` header, a JWE (5-segment) token, an RSA modulus
;;; below 2048 bits, and an unknown `kid`.

(require racket/string
         racket/list
         json
         ffi/unsafe
         openssl/libcrypto
         (only-in net/base64 base64-decode))

(provide verify-jws
         ;; exported for the regression suite
         es256-raw->der jwk->spki-der base64url->bytes)

;;; ── libcrypto bindings (memoised; lazy, per crypto.rkt's seam-test note) ──────
(define-syntax-rule (define-crypto id type)
  (define id
    (let ([c #f])
      (lambda args
        (unless c (set! c (get-ffi-obj 'id libcrypto type)))
        (apply c args)))))

(define-crypto EVP_sha256           (_fun -> _pointer))
(define-crypto EVP_MD_CTX_new       (_fun -> _pointer))
(define-crypto EVP_MD_CTX_free      (_fun _pointer -> _void))
(define-crypto EVP_PKEY_free        (_fun _pointer -> _void))
(define-crypto EVP_DigestVerifyInit (_fun _pointer _pointer _pointer _pointer _pointer -> _int))
(define-crypto EVP_DigestVerify     (_fun _pointer _bytes _size _bytes _size -> _int))
(define-crypto d2i_PUBKEY           (_fun _pointer _pointer _long -> _pointer))

;;; ── base64url ─────────────────────────────────────────────────────────────────
(define (base64url->bytes s)
  (define std (string-replace (string-replace s "-" "+") "_" "/"))
  (define pad (modulo (- 4 (modulo (string-length std) 4)) 4))
  (base64-decode (string->bytes/utf-8 (string-append std (make-string pad #\=)))))

;;; ── minimal DER encoder ───────────────────────────────────────────────────────
(define (der-len n)
  (cond
    [(< n 128) (bytes n)]
    [else
     (let loop ([n n] [acc '()])
       (if (zero? n)
           (bytes-append (bytes (bitwise-ior #x80 (length acc))) (list->bytes acc))
           (loop (quotient n 256) (cons (remainder n 256) acc))))]))

(define (der-tlv tag content)
  (bytes-append (bytes tag) (der-len (bytes-length content)) content))

;; A positive integer from big-endian bytes: strip leading 0x00, then prepend one
;; 0x00 if the top bit is set (so it is not read as negative).
(define (der-integer be)
  (define stripped
    (let loop ([b be])
      (cond [(and (> (bytes-length b) 1) (= (bytes-ref b 0) 0)) (loop (subbytes b 1))]
            [(= (bytes-length b) 0) (bytes 0)]
            [else b])))
  (define body (if (>= (bytes-ref stripped 0) #x80) (bytes-append (bytes 0) stripped) stripped))
  (der-tlv #x02 body))

(define (der-seq . parts)      (der-tlv #x30 (apply bytes-append parts)))
(define (der-bitstring content) (der-tlv #x03 (bytes-append (bytes 0) content))) ; 0 unused bits

;; Pre-encoded OBJECT IDENTIFIERs (tag+len+content), so no OID arithmetic here.
(define oid-rsa      (bytes #x06 #x09 #x2a #x86 #x48 #x86 #xf7 #x0d #x01 #x01 #x01)) ; 1.2.840.113549.1.1.1
(define oid-ec-pub   (bytes #x06 #x07 #x2a #x86 #x48 #xce #x3d #x02 #x01))            ; 1.2.840.10045.2.1
(define oid-p256     (bytes #x06 #x08 #x2a #x86 #x48 #xce #x3d #x03 #x01 #x07))       ; prime256v1
(define der-null     (bytes #x05 #x00))

;; RSA public key (n,e big-endian bytes) -> SPKI DER.
(define (rsa-spki n e)
  (der-seq (der-seq oid-rsa der-null)
           (der-bitstring (der-seq (der-integer n) (der-integer e)))))

;; EC P-256 public key (x,y 32-byte big-endian) -> SPKI DER (uncompressed point).
(define (ec-spki x y)
  (define point (bytes-append (bytes #x04) (left-pad x 32) (left-pad y 32)))
  (der-seq (der-seq oid-ec-pub oid-p256) (der-bitstring point)))

(define (left-pad b n)
  (cond [(= (bytes-length b) n) b]
        [(> (bytes-length b) n) (subbytes b (- (bytes-length b) n))] ; strip a leading 0x00
        [else (bytes-append (make-bytes (- n (bytes-length b)) 0) b)]))

;; Build the SPKI DER for a JWK, or (values #f reason).
(define (jwk->spki-der jwk)
  (define kty (hash-ref jwk 'kty #f))
  (cond
    [(equal? kty "RSA")
     (define n (base64url->bytes (hash-ref jwk 'n "")))
     (define e (base64url->bytes (hash-ref jwk 'e "")))
     (cond
       [(< (* 8 (bytes-length (strip-leading-zeros n))) 2048)
        (values #f "RSA modulus below 2048 bits")]
       [else (values (rsa-spki n e) #f)])]
    [(equal? kty "EC")
     (cond
       [(not (equal? (hash-ref jwk 'crv #f) "P-256")) (values #f "unsupported EC curve")]
       [else (values (ec-spki (base64url->bytes (hash-ref jwk 'x ""))
                              (base64url->bytes (hash-ref jwk 'y ""))) #f)])]
    [else (values #f "unsupported kty")]))

(define (strip-leading-zeros b)
  (let loop ([b b]) (if (and (> (bytes-length b) 1) (= (bytes-ref b 0) 0)) (loop (subbytes b 1)) b)))

;;; ── ES256 raw (r||s) -> DER ECDSA-Sig-Value ───────────────────────────────────
(define (es256-raw->der sig)
  (and (= (bytes-length sig) 64)
       (der-seq (der-integer (subbytes sig 0 32)) (der-integer (subbytes sig 32 64)))))

;;; ── the EVP verify call ───────────────────────────────────────────────────────
(define (evp-verify spki-der signing-input sig-der-or-raw)
  (define len (bytes-length spki-der))
  (define buf (malloc len 'atomic-interior))
  (memcpy buf spki-der len)
  (define pp (malloc _pointer 'atomic-interior))
  (ptr-set! pp _pointer buf)
  (define pkey (d2i_PUBKEY #f pp len))
  (cond
    [(not pkey) #f]
    [else
     (define ctx (EVP_MD_CTX_new))
     (define ok?
       (and (= 1 (EVP_DigestVerifyInit ctx #f (EVP_sha256) #f pkey))
            (= 1 (EVP_DigestVerify ctx sig-der-or-raw (bytes-length sig-der-or-raw)
                                   signing-input (bytes-length signing-input)))))
     (EVP_MD_CTX_free ctx)
     (EVP_PKEY_free pkey)
     ok?]))

;;; ── header hygiene ────────────────────────────────────────────────────────────
(define nominated-header-keys '(jwk jku x5u x5c crit))

(define (select-jwk jwks kid)
  (define keys (let ([k (hash-ref jwks 'keys #f)]) (if (list? k) k '())))
  (cond
    [kid (for/or ([j (in-list keys)]) (and (equal? (hash-ref j 'kid #f) kid) j))]
    [(= (length keys) 1) (car keys)]
    [else #f]))

;;; ── verify-jws ────────────────────────────────────────────────────────────────
;; token: compact JWS string.  jwks: {keys: [...]} jsexpr hash.  pinned-algs: a
;; list of the algs we will accept (already ∩ {"RS256","ES256"} by the caller).
;; Returns #t on a valid signature, or a short reason string.
(define (verify-jws token jwks #:algs pinned-algs)
  (define parts (string-split token "."))
  (cond
    [(= (length parts) 5) "a JWE (five-segment) token is not accepted"]
    [(not (= (length parts) 3)) "malformed JWS"]
    [else
     (define header
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (bytes->jsexpr (base64url->bytes (car parts)))))
     (cond
       [(not (hash? header)) "unparseable JWS header"]
       [(for/or ([k (in-list nominated-header-keys)]) (hash-has-key? header k))
        "token header nominates its own key (jwk/jku/x5u/x5c/crit) — refused"]
       [else
        (define alg (hash-ref header 'alg #f))
        (cond
          [(not (string? alg)) "alg absent"]
          [(string-ci=? alg "none") "alg:none refused"]
          [(regexp-match? #rx"^[Hh][Ss]" alg) "HMAC alg on an ID token refused"]
          [(not (member alg pinned-algs)) "alg not in the pinned set"]
          [else
           (define jwk (select-jwk jwks (hash-ref header 'kid #f)))
           (cond
             [(not jwk) "no JWKS key matches the token kid"]
             [(and (equal? alg "RS256") (not (equal? (hash-ref jwk 'kty #f) "RSA")))
              "RS256 requires an RSA key"]
             [(and (equal? alg "ES256") (not (equal? (hash-ref jwk 'kty #f) "EC")))
              "ES256 requires an EC key"]
             [else
              (define-values (spki reason) (jwk->spki-der jwk))
              (cond
                [(not spki) reason]
                [else
                 (define signing-input
                   (string->bytes/utf-8 (string-append (car parts) "." (cadr parts))))
                 (define raw-sig
                   (with-handlers ([exn:fail? (lambda (_) #f)]) (base64url->bytes (caddr parts))))
                 (define sig
                   (cond [(not raw-sig) #f]
                         [(equal? alg "ES256") (es256-raw->der raw-sig)]
                         [else raw-sig]))
                 (cond
                   [(not sig) "malformed signature"]
                   [(evp-verify spki signing-input sig) #t]
                   [else "signature verification failed"])])])])])]))
