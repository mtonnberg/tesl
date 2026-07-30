#lang racket

;;; Tesl.JWT — JSON Web Token support using HMAC-SHA256.
;;;
;;; Provides nominal newtypes JwtToken (a signed JWT string) and JwtSecret
;;; (a signing secret string), plus JWT.sign, JWT.verify, and JWT.decode.
;;;
;;; The `jwt` capability gates all JWT operations; `JWT.sign` additionally needs
;;; `time`, because it stamps the expiry from the wall clock.
;;;
;;; Usage:
;;;   import Tesl.JWT exposing [jwt, JwtToken, JwtSecret,
;;;                             JWT.sign, JWT.verify, JWT.decode, Authentic]
;;;
;;;   capability myAuth implies jwt, time
;;;
;;;   fn makeSession(userId: String, secret: JwtSecret) requires [myAuth] -> JwtToken =
;;;     JWT.sign (Dict.singleton "sub" userId) secret
;;;
;;; ── EXPIRY IS NOT THE CALLER'S TO SET ────────────────────────────────────────
;;;
;;; `JWT.sign` stamps `exp` itself, one hour ahead, and there is no parameter for
;;; it.  That is deliberate and follows Tesl.Crypto's design rule: no mechanism
;;; reaches the application author, because every knob is a place where a
;;; non-expert makes a wrong call and gets a plausible-looking result.  A caller
;;; who can pass an expiry can pass ten years.
;;;
;;; One hour is the session-token number.  A JWT here IS a session token; for a
;;; long-lived credential (an API key, a machine token) the documented answer is
;;; `Crypto.randomToken` plus storing only its `Crypto.fingerprint`, which is
;;; revocable — an unexpiring bearer token is not.  Renewing a session means
;;; signing a new token, which is one call.
;;;
;;; A caller-supplied `exp` in the claims dict is an ERROR, not something to
;;; overwrite: silently winning an argument with the caller about which expiry
;;; applies is how a token ends up living longer than the code says it does.
;;;
;;; ── UNIT: `exp` IS EPOCH SECONDS (RFC 7519) ──────────────────────────────────
;;;
;;; `exp` is a NumericDate as RFC 7519 §4.1.4 defines it: seconds since the Unix
;;; epoch.  Both the mint side (JWT.sign) and the verify side agree, and both
;;; agree with every other JWT library, so a Tesl token interoperates.
;;;
;;; It was MILLISECONDS until 2026-07-29 — 1000x too large, which a foreign
;;; verifier would have read as valid for ~50,000 years (fail-open), and which
;;; made every foreign token look long expired to Tesl (fail-closed).  The fix is
;;; a clean break with no dual-unit tolerance: a heuristic that guesses the unit
;;; is exactly the kind of hedge that outlives its reason.  Tokens minted before
;;; the break have a far-future `exp` and will still verify until they are
;;; re-signed; tokens minted by a Tesl older than the break, against a newer
;;; verifier, are unaffected for the same reason.
;;;
;;; Note the internal asymmetry this leaves: Tesl's own clock type,
;;; `PosixMillis`, is milliseconds, so the conversion happens HERE (once, at the
;;; JWT boundary) rather than leaking a second time unit into Tesl.Time.
;;;
;;; See LANGUAGE-SPEC.md §21.2.

(require "../dsl/capability.rkt"
         "../dsl/check.rkt"
         "../dsl/types.rkt"
         "private/runtime.rkt"
         (only-in "time.rkt" time)
         ;; `Authentic` is Tesl.Crypto's proof predicate, RE-EXPORTED here rather
         ;; than redefined: JWT.verify mints it, so `import Tesl.JWT exposing
         ;; [Authentic]` has to resolve to a real provide (the stdlib
         ;; binding-existence seam test enforces that).  Re-exporting keeps ONE
         ;; binding, so a program that reaches the name through both modules sees
         ;; the same identifier instead of a require conflict.
         (only-in "crypto.rkt" Authentic)
         (only-in "../dsl/private/evidence.rkt" check-fail)
         openssl/libcrypto
         ffi/unsafe
         ffi/unsafe/define
         openssl/sha1          ; for bytes->hex-string
         net/base64
         racket/string
         json)

(provide jwt JwtToken JwtSecret JWT.sign JWT.verify JWT.decode
         ;; re-exported from crypto.rkt — see the require note above
         Authentic)

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

;; ── Argument normalisation: raw-value FIRST, then strip the newtype ──────────
;;
;; A stdlib function does not necessarily receive its argument as the value. The
;; GDP machinery may hand over the SUBJECT NAME (a bare symbol), which
;; `raw-value` resolves through `current-evidence-env`, and the argument may also
;; arrive wrapped in a `named-value` or a `check-ok`.
;;
;; The order matters and used to be wrong here: `(raw-value (if (newtype-value? x)
;; (newtype-value-value x) x))` tests for the wrapper BEFORE resolving, so a
;; named-value wrapping a JwtToken fell through the `if`, `raw-value` unwrapped
;; the named-value, and the result was still a `newtype-value` — which then hit
;; `string-split` as a contract violation. It stayed latent until `JWT.verify`
;; became check-shaped (the `Authentic` retrofit), because that changed how call
;; sites pass the argument. Identical to the bug fixed in `tesl/crypto.rkt`'s
;; `checkPassword`; `tesl/string.rkt`'s `raw-str` is the house idiom.
(define (jwt-raw-string v)
  (define r (raw-value v))
  (if (newtype-value? r) (newtype-value-value r) r))


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

;; Normalize an arbitrary Tesl claims value into a SYMBOL-KEYED jsexpr hash —
;; the shape `jsexpr->string` wants, and the shape the `exp` guard below
;; inspects.  Note what is deliberately NOT done here: a newtype-value claim is
;; left wrapped, so `jsexpr->string` raises on it.  Unwrapping would be more
;; forgiving but would silently serialize a `JwtSecret` (or any other
;; `define-secret-newtype`) into the payload in plaintext if one were ever
;; misplaced into the claims dict.  Fail loud instead.
(define (claims->jsexpr-hash who claims)
  (define raw (raw-value claims))
  (define h
    (cond
      [(hash? raw) raw]
      ;; Support association lists (Tesl dict internally may be an alist)
      [(list? raw)
       (for/hash ([pair (in-list raw)])
         (values (car pair) (raw-value (cdr pair))))]
      [else
       (raise-user-error who "JWT claims must be a hash/dict, got ~a" raw)]))
  ;; JSON object keys must be SYMBOLS for `jsexpr->string`, but Tesl Dict keys
  ;; are STRINGS — coerce them.  Unwrap any GDP-named values.
  (for/hash ([(k v) (in-hash h)])
    (values (if (string? k) (string->symbol k) k) (raw-value v))))

;; ── Expiry ───────────────────────────────────────────────────────────────────

;; The fixed session TTL, in SECONDS.  One hour.  Not a parameter, not
;; configurable, and not read from the environment — see the header note: every
;; knob here is a place where a non-expert makes a wrong call and gets a
;; plausible-looking result.  Renewing a session is one more `JWT.sign`.
(define jwt-ttl-seconds 3600)

;; NOW in epoch SECONDS (RFC 7519 NumericDate).  Tesl's own clock type is
;; PosixMillis, so the ms→s conversion lives here, at the JWT boundary, once.
(define (jwt-now-seconds)
  (inexact->exact (floor (/ (current-inexact-milliseconds) 1000.0))))

;; MINT-SIDE GUARD.  `exp` is set by `JWT.sign` from the clock, so a caller
;; supplying one is rejected outright rather than silently overwritten:
;; overwriting would mean the code says one expiry and the token carries another,
;; and accepting it would hand the caller the knob the design deliberately
;; withholds.
;;
;; This RAISES rather than returning a check-fail.  A check-fail is the shape for
;; ATTACKER-supplied input (a token off the wire); the claims dict is the
;; program's OWN data on the way out, so it is a program bug, and the only place
;; it can be diagnosed at the right site is here — the dict may be assembled
;; dynamically, so no type catches every case.
(define (reject-caller-supplied-exp! who h)
  (when (hash-has-key? h 'exp)
    (raise-user-error
     who
     (string-append
      "expiry is not yours to set: the claims dict carries an `exp` (~s).\n"
      "  JWT.sign stamps `exp` itself, ~a seconds ahead, and there is no\n"
      "  parameter for it — a caller who can choose an expiry can choose ten\n"
      "  years.  Remove `exp` from the claims.\n"
      "  If you need a credential that outlives a session, a JWT is the wrong\n"
      "  tool: use `Crypto.randomToken` and store only its `Crypto.fingerprint`,\n"
      "  which you can revoke.")
     (hash-ref h 'exp)
     jwt-ttl-seconds)))

(define (jsexpr-hash->json-bytes h)
  (string->bytes/utf-8 (jsexpr->string h)))

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

;; Serialize an already-normalized, already-guarded jsexpr claims hash and HMAC it.
(define (sign-claims-hash h secret)
  (define secret-str (jwt-raw-string secret))
  (define secret-bytes (string->bytes/utf-8 secret-str))
  (define payload-b64
    (base64url-encode (jsexpr-hash->json-bytes h)))
  (define signing-input
    (string-append jwt-header-b64 "." payload-b64))
  (define sig-bytes
    (compute-signature secret-bytes signing-input))
  (define sig-b64 (base64url-encode sig-bytes))
  (JwtToken (string-append signing-input "." sig-b64)))

;; JWT.sign : Dict String String → JwtSecret → JwtToken
;;
;; Creates a signed session JWT from a string-keyed, string-valued claims dict,
;; and stamps `exp` one hour ahead (epoch SECONDS, RFC 7519).  There is no way to
;; choose the expiry, and no way to opt out of having one — see the header.
;;
;; Requires `time` as well as `jwt`: it reads the wall clock, and a capability
;; marks an effect.
;;
;; Example:
;;   JWT.sign (Dict.singleton "sub" userId) secret
(define (JWT.sign claims secret)
  (require-capabilities! (list jwt time))
  (define h (claims->jsexpr-hash 'JWT.sign claims))
  (reject-caller-supplied-exp! 'JWT.sign h)
  (sign-claims-hash
   (hash-set h 'exp (+ (jwt-now-seconds) jwt-ttl-seconds))
   secret))

;; JWT.verify : JwtToken → JwtSecret → Dict String String
;;
;; Verifies the JWT signature and checks expiry (`exp` claim, in epoch SECONDS
;; per RFC 7519 §4.1.4 — see the unit note in the module header).
;; Returns the claims hash on success, or a check-fail with HTTP 401.
;;
;; On success the claims carry an `Authentic` fact (Crypto Phase 2), so a
;; consumer can demand `Dict String String ::: Authentic claims` on a parameter
;; and "trusted a cookie without verifying it" stops compiling.
;;
;; Example:
;;   JWT.verify token secret
(define (JWT.verify token secret)
  (require-capabilities! (list jwt))
  (define token-str (jwt-raw-string token))
  (define secret-str (jwt-raw-string secret))
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
                  ;; Check expiry.  `exp` is epoch SECONDS (RFC 7519 §4.1.4), the
                  ;; same unit every other JWT library uses and the same unit
                  ;; JWT.sign writes.
                  ;;
                  ;; A MISSING `exp` is accepted (no expiry claim, no expiry
                  ;; check).  Tesl cannot mint such a token — JWT.sign always
                  ;; stamps one — so this only admits a foreign token that omits
                  ;; `exp`, which is legal per the RFC (`exp` is OPTIONAL).
                  ;;
                  ;; A NON-NUMERIC `exp` is treated as EXPIRED, not as absent.
                  ;; Two reasons, and the second is the important one:
                  ;;   * `(< "1785355686959" now)` is a contract violation, which
                  ;;     escapes as an uncaught exception and becomes a 500 —
                  ;;     while every other rejection on this path is a 401.  A
                  ;;     well-formed token with a string `exp` is enough to
                  ;;     trigger it.
                  ;;   * skipping the check on an unparseable `exp` would be
                  ;;     FAIL-OPEN: a token whose expiry cannot be read would be
                  ;;     accepted forever.  Unreadable expiry must mean expired.
                  ;; Tesl can no longer mint one either — JWT.sign sets `exp`
                  ;; itself from the clock — so this branch now fires only on a
                  ;; foreign or hand-forged token.
                  (let* ([exp (and (hash? claims) (hash-ref claims 'exp #f))]
                         [now (jwt-now-seconds)]
                         [expired?
                          (cond
                            [(eq? exp #f) #f]           ; no exp claim: no expiry
                            [(real? exp) (< exp now)]
                            [else #t])])                ; unreadable: fail closed
                    (if expired?
                        (check-fail "JWT token has expired" 401 '())
                        (jwt-claims->string-keyed claims)))))))))

;; JWT.decode : JwtToken → Dict String String
;;
;; Decodes the JWT payload WITHOUT verifying the signature.
;; Use this only when you have already verified the token or trust the source.
;;
;; Example:
;;   JWT.decode token
(define (JWT.decode token)
  (require-capabilities! (list jwt))
  (define token-str (jwt-raw-string token))
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
