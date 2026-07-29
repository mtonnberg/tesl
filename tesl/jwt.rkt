#lang racket

;;; Tesl.JWT — JSON Web Token support using HMAC-SHA256.
;;;
;;; Provides nominal newtypes JwtToken (a signed JWT string) and JwtSecret
;;; (a signing secret string), plus JWT.sign, JWT.verify, and JWT.decode.
;;;
;;; The `jwt` capability gates all JWT operations. Handlers that call
;;; JWT.sign or JWT.verify must declare `requires [jwt]`.
;;;
;;; Usage:
;;;   import Tesl.JWT exposing [jwt, JwtToken, JwtSecret, JWT.sign, JWT.verify, JWT.decode]
;;;
;;;   capability myAuth implies jwt
;;;
;;;   fn makeToken(userId: String, secret: JwtSecret) requires [jwt] -> JwtToken =
;;;     JWT.sign { sub: userId, exp: (nowMillis + 3600000) } secret

(require "../dsl/capability.rkt"
         "../dsl/check.rkt"
         "../dsl/types.rkt"
         "private/runtime.rkt"
         (only-in "../dsl/private/evidence.rkt" check-fail)
         openssl/libcrypto
         ffi/unsafe
         ffi/unsafe/define
         openssl/sha1          ; for bytes->hex-string
         net/base64
         racket/string
         json)

(provide jwt JwtToken JwtSecret JWT.sign JWT.verify JWT.decode)

;; ── Capability ───────────────────────────────────────────────────────────────

(define-capability jwt)

;; ── Nominal newtypes ─────────────────────────────────────────────────────────

;; JwtToken wraps a String — the dot-separated JWT string "header.payload.sig"
(define-newtype JwtToken String)

;; JwtSecret wraps a String — the HMAC-SHA256 signing key.
;; `define-secret-newtype` is `define-newtype` plus a registration in
;; `dsl/types.rkt`'s secret-type registry, so every rendering sink (telemetry,
;; the three debugger surfaces, structured logging) substitutes
;; `secret-redaction-text` instead of printing the key.  It is additive at
;; runtime — identical representation, identical SQL round-trip, `.value` still
;; works — so no emitted code changes.
(define-secret-newtype JwtSecret String)

;; ── HMAC-SHA256 via FFI (OpenSSL libcrypto) ──────────────────────────────────

(define-ffi-definer define-libcrypto libcrypto)

;; EVP_sha256() returns a pointer to the SHA256 message digest algorithm.
(define-libcrypto EVP_sha256
  (_fun -> _pointer))

;; HMAC(evp_md, key, key_len, data, data_len, md_out, md_len_out) -> _bytes
;; Returns a pointer to the HMAC output (same as md_out).
;; For SHA256 the output is always 32 bytes.
(define-libcrypto HMAC
  (_fun _pointer        ; const EVP_MD *evp_md
        _bytes          ; const void *key
        _int            ; int key_len
        _bytes          ; const unsigned char *data
        _int            ; int data_len
        _bytes          ; unsigned char *md  (must be pre-allocated, >= 32 bytes)
        (_ptr o _uint)  ; unsigned int *md_len  (written by HMAC; we ignore return)
        -> _pointer))

(define (hmac-sha256-bytes key-bytes data-bytes)
  (define sha256-md (EVP_sha256))
  (define out (make-bytes 32))
  (HMAC sha256-md key-bytes (bytes-length key-bytes)
        data-bytes (bytes-length data-bytes)
        out)
  out)

;; ── Base64url helpers (RFC 4648 §5 — no padding) ────────────────────────────

(define (base64url-encode bstr)
  ;; Standard base64 with padding, then transform to base64url without padding
  (define b64 (bytes->string/utf-8 (base64-encode bstr #"")))
  (define url (string-replace (string-replace b64 "+" "-") "/" "_"))
  ;; Strip all trailing '=' padding characters
  (regexp-replace* #rx"=+$" url ""))

(define (base64url-decode str)
  ;; Restore standard base64 padding and characters, then decode
  (define s (string-replace (string-replace str "-" "+") "_" "/"))
  ;; Add padding back
  (define padded
    (case (remainder (string-length s) 4)
      [(0) s]
      [(2) (string-append s "==")]
      [(3) (string-append s "=")]
      [else s]))
  (base64-decode (string->bytes/utf-8 padded)))

;; ── Internal JWT helpers ─────────────────────────────────────────────────────

;; Build the standard JWT header (alg=HS256, typ=JWT) encoded as base64url.
(define jwt-header-b64
  (base64url-encode
   (string->bytes/utf-8 "{\"alg\":\"HS256\",\"typ\":\"JWT\"}")))

(define (claims->json-bytes claims)
  ;; `claims` is a Racket hash (or a Tesl record/dict value).
  ;; We convert it to a JSON byte string.
  (define raw (raw-value claims))
  (define h
    (cond
      [(hash? raw) raw]
      ;; Support association lists (Tesl dict internally may be an alist)
      [(list? raw)
       (for/hash ([pair (in-list raw)])
         (values (car pair) (raw-value (cdr pair))))]
      [else
       (raise-user-error 'JWT "JWT claims must be a hash/dict, got ~a" raw)]))
  ;; Convert to a jsexpr: JSON object keys must be SYMBOLS for `jsexpr->string`,
  ;; but Tesl Dict keys are STRINGS — coerce them. Unwrap any GDP-named values.
  (define plain-h
    (for/hash ([(k v) (in-hash h)])
      (values (if (string? k) (string->symbol k) k) (raw-value v))))
  (string->bytes/utf-8 (jsexpr->string plain-h)))

(define (compute-signature secret-bytes signing-input)
  (hmac-sha256-bytes secret-bytes (string->bytes/utf-8 signing-input)))

;; `string->jsexpr` decodes JSON object keys as SYMBOLS, but the Tesl Dict API
;; (Dict.lookup, Dict.member, …) keys by STRING. Re-key the decoded claims so a
;; verified/decoded payload behaves as a `Dict String v` on the Tesl surface.
(define (jwt-claims->string-keyed claims)
  (if (hash? claims)
      (for/hash ([(k v) (in-hash claims)])
        (values (if (symbol? k) (symbol->string k) k) v))
      claims))

;; ── Public API ───────────────────────────────────────────────────────────────

;; JWT.sign : ∀a. a → JwtSecret → JwtToken
;;
;; Creates a signed JWT from an arbitrary claims value (hash/dict).
;; The claims value should contain at least { sub: ..., exp: <posix-ms> }.
;;
;; Example:
;;   JWT.sign { sub: userId, exp: (nowMillis + 3600000) } secret
(define (JWT.sign claims secret)
  (require-capabilities! (list jwt))
  (define secret-str (raw-value (if (newtype-value? secret)
                                    (newtype-value-value secret)
                                    secret)))
  (define secret-bytes (string->bytes/utf-8 secret-str))
  (define payload-b64
    (base64url-encode (claims->json-bytes claims)))
  (define signing-input
    (string-append jwt-header-b64 "." payload-b64))
  (define sig-bytes
    (compute-signature secret-bytes signing-input))
  (define sig-b64 (base64url-encode sig-bytes))
  (JwtToken (string-append signing-input "." sig-b64)))

;; JWT.verify : ∀a. JwtToken → JwtSecret → a
;;
;; Verifies the JWT signature and checks expiry (exp claim, in posix milliseconds).
;; Returns the claims hash on success, or raises a check-fail with HTTP 401.
;;
;; Example:
;;   JWT.verify token secret
(define (JWT.verify token secret)
  (require-capabilities! (list jwt))
  (define token-str (raw-value (if (newtype-value? token)
                                   (newtype-value-value token)
                                   token)))
  (define secret-str (raw-value (if (newtype-value? secret)
                                    (newtype-value-value secret)
                                    secret)))
  (define parts (string-split token-str "."))
  ;; A STRUCTURALLY malformed token is a 401, not a raise.  The token comes off
  ;; the wire, so `Cookie: session=garbage` used to escape as an uncaught
  ;; `raise-user-error` — a client-triggerable 500 on every JWT-authenticated
  ;; endpoint, and an oracle that distinguishes "not a token" from "wrong
  ;; signature".  Every other rejection here is already `check-fail … 401`; this
  ;; one now agrees with them, and with `Crypto.signatureFromHex`, which parses
  ;; an inbound tag without ever raising, for the same reason.
  (if (not (= (length parts) 3))
      (check-fail "Invalid JWT format" 401 '())
      (let* ([header-b64  (list-ref parts 0)]
             [payload-b64 (list-ref parts 1)]
             [sig-b64     (list-ref parts 2)]
             ;; Re-derive signature
             [signing-input (string-append header-b64 "." payload-b64)]
             [secret-bytes (string->bytes/utf-8 secret-str)]
             [expected-sig (compute-signature secret-bytes signing-input)]
             ;; Likewise for a signature segment that is not valid base64url:
             ;; fall through to the constant-time compare with an empty tag,
             ;; which fails, rather than raising out of the handler.
             [actual-sig
              (with-handlers ([exn:fail? (lambda (_) #"")])
                (base64url-decode sig-b64))]
             ;; Constant-time comparison (byte-by-byte, always process all
             ;; bytes).  XOR every pair of bytes and OR them together; 0 means
             ;; equal.
             [sig-ok?
              (and (= (bytes-length expected-sig) (bytes-length actual-sig))
                   (= 0 (for/fold ([acc 0]) ([eb (in-bytes expected-sig)]
                                             [ab (in-bytes actual-sig)])
                          (bitwise-ior acc (bitwise-xor eb ab)))))])
        (if (not sig-ok?)
            (check-fail "Invalid JWT signature" 401 '())
            ;; Decode payload
            (let* ([payload-bytes
                    (with-handlers ([exn:fail? (lambda (_) #"")])
                      (base64url-decode payload-b64))]
                   [claims
                    (with-handlers ([exn:fail? (lambda (_) #f)])
                      (string->jsexpr (bytes->string/utf-8 payload-bytes)))])
              (if (not claims)
                  (check-fail "Malformed JWT payload" 401 '())
                  ;; Check expiry if present (exp is in ms since the epoch).
                  ;;
                  ;; A NON-NUMERIC `exp` is treated as expired, not as absent.
                  ;; Two reasons, and the second is the important one:
                  ;;   * `(< "1785355686959" now)` is a contract violation, which
                  ;;     escapes as an uncaught exception and becomes a 500 —
                  ;;     while every other rejection on this path is a 401.  A
                  ;;     well-formed token with a string `exp` is enough to
                  ;;     trigger it.
                  ;;   * skipping the check on an unparseable `exp` would be
                  ;;     FAIL-OPEN: a token whose expiry cannot be read would be
                  ;;     accepted forever.  Unreadable expiry must mean expired.
                  ;; (`JWT.sign`'s typed surface is `Dict String String`, so a
                  ;; Tesl program CAN put a string there and then have its own
                  ;; tokens rejected by its own verifier — better a clean 401
                  ;; than a 500, and better than accepting them.)
                  (let* ([exp (and (hash? claims) (hash-ref claims 'exp #f))]
                         [now (inexact->exact (floor (current-inexact-milliseconds)))]
                         [expired?
                          (cond
                            [(eq? exp #f) #f]           ; no exp claim: no expiry
                            [(real? exp) (< exp now)]
                            [else #t])])                ; unreadable: fail closed
                    (if expired?
                        (check-fail "JWT token has expired" 401 '())
                        (jwt-claims->string-keyed claims)))))))))

;; JWT.decode : ∀a. JwtToken → a
;;
;; Decodes the JWT payload WITHOUT verifying the signature.
;; Use this only when you have already verified the token or trust the source.
;;
;; Example:
;;   JWT.decode token
(define (JWT.decode token)
  (require-capabilities! (list jwt))
  (define token-str (raw-value (if (newtype-value? token)
                                   (newtype-value-value token)
                                   token)))
  (define parts (string-split token-str "."))
  (when (< (length parts) 2)
    (raise-user-error 'JWT.decode
                      "invalid JWT format: expected at least 2 dot-separated parts"))
  (define payload-b64 (list-ref parts 1))
  (define payload-bytes (base64url-decode payload-b64))
  (with-handlers ([exn:fail? (lambda (_)
                               (raise-user-error 'JWT.decode "malformed JWT payload"))])
    (jwt-claims->string-keyed
     (string->jsexpr (bytes->string/utf-8 payload-bytes)))))
