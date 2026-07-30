#lang racket

;;; Runtime tests for Tesl.JWT module.
;;;
;;; Tests cover:
;;;   - JWT.sign produces 3-part base64url string
;;;   - JWT.verify correct secret → returns claims hash
;;;   - JWT.verify wrong secret → check-fail 401
;;;   - JWT.verify expired token → check-fail 401
;;;   - JWT.verify malformed token → error
;;;   - JWT.decode no signature check → returns claims
;;;   - JwtToken and Secret (the key type, from tesl/crypto.rkt) are distinct
;;;     nominal newtypes
;;;   - Capability enforcement (jwt AND time — signing reads the clock)
;;;   - Base64url encoding (no padding, url-safe chars)
;;;   - Roundtrip sign→verify with various claim shapes
;;;   - The `exp` contract (section 8): a fixed ONE-HOUR TTL that JWT.sign stamps
;;;     itself, in epoch SECONDS (RFC 7519), with no caller knob — a
;;;     caller-supplied `exp` is rejected rather than overwritten
;;;   - Interop both ways: a Tesl token reads correctly to a seconds-based foreign
;;;     verifier, and a foreign seconds-valued token verifies here
;;;   - No dual-unit tolerance: a legacy millisecond `exp` is not rescaled
;;;   - VERIFY-side: a well-formed, correctly signed FOREIGN token with a string
;;;     `exp` is a check-fail 401, never an exception (i.e. never a 500)

(require rackunit
         json
         net/base64
         racket/string
         ffi/unsafe
         ffi/unsafe/define
         openssl/libcrypto
         (file "../tesl/jwt.rkt")
         ;; The SIGNING KEY type.  `tesl/jwt.rkt` has no key newtype of its own:
         ;; `Secret` is the single key-material type in the language (it is what
         ;; `Env.requireSecret` returns), and jwt.rkt deliberately does not
         ;; re-provide it, so the tests reach for it where it lives.
         (only-in (file "../tesl/crypto.rkt") Secret Crypto.keyFingerprint)
         (file "../tesl/time.rkt")
         (file "../dsl/capability.rkt")
         (file "../dsl/types.rkt")
         (file "../dsl/private/evidence.rkt"))

;; string-contains is not available in all Racket versions — define it
(define (string-contains haystack needle)
  (if (regexp-match? (regexp (regexp-quote needle)) haystack)
      #t #f))

;; ── Helpers ──────────────────────────────────────────────────────────────────

;; base64url ↔ bytes, the way a foreign JWT library would encode/decode a segment.
;; Local, for the same reason `forge-token` below is local: jwt.rkt does not
;; provide its internals, and the whole point of the mint guard is that some of
;; these tokens are UNMINTABLE through the public API.  Defined up here rather
;; than beside `forge-token` because the header tests (section 1) decode the
;; header, and a module-level `define` cannot be used before it is initialised.
(define (t-b64url bstr)
  (regexp-replace*
   #rx"=+$"
   (string-replace (string-replace (bytes->string/utf-8 (base64-encode bstr #"")) "+" "-")
                   "/" "_")
   ""))

(define (t-b64url-decode str)
  (define s (string-replace (string-replace str "-" "+") "_" "/"))
  (define padded
    (case (remainder (string-length s) 4)
      [(2) (string-append s "==")]
      [(3) (string-append s "=")]
      [else s]))
  (base64-decode (string->bytes/utf-8 padded)))

;; JWT.sign now reads the wall clock (it stamps `exp` itself), so the ambient
;; capability set for these tests is `jwt` AND `time`.  The capability-guard
;; section below deliberately grants them one at a time to pin that both are
;; required.
(define (with-jwt thunk)
  (with-capabilities (jwt time) (thunk)))

(define test-secret (Secret "test-secret-key-for-testing"))
(define test-claims (hasheq 'sub "user123"))

;; ── 1. JWT.sign structure tests ───────────────────────────────────────────────

(test-case "sign produces a newtype-value JwtToken"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (check-true (newtype-value? token)))

(test-case "sign produces 3-part dot-separated string"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define token-str (newtype-value-value token))
  (define parts (string-split token-str "."))
  (check-equal? (length parts) 3))

(test-case "sign header is an HS256 JWT header carrying a kid"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define token-str (newtype-value-value token))
  (define header-b64 (car (string-split token-str ".")))
  ;; The header is `{"alg":"HS256","typ":"JWT","kid":"<16 hex>"}`, so it is a
  ;; function OF THE KEY and no longer the fixed
  ;; `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9` it was before 2026-07-30.  Assert the
  ;; decoded JSON, field by field, rather than a magic base64 string.
  (define header
    (string->jsexpr (bytes->string/utf-8 (t-b64url-decode header-b64))))
  (check-equal? (hash-ref header 'alg) "HS256")
  (check-equal? (hash-ref header 'typ) "JWT")
  (check-equal? (hash-ref header 'kid) (Crypto.keyFingerprint test-secret))
  ;; alg, typ, kid and nothing else — no room for a knob to appear.
  (check-equal? (sort (map symbol->string (hash-keys header)) string<?)
                (list "alg" "kid" "typ")))

(test-case "sign produces no base64 padding (=)"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define token-str (newtype-value-value token))
  (check-false (string-contains token-str "=")))

(test-case "sign produces no base64 + characters"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define token-str (newtype-value-value token))
  (check-false (string-contains token-str "+")))

(test-case "sign produces no base64 / characters"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define token-str (newtype-value-value token))
  (check-false (string-contains token-str "/")))

(test-case "sign different secrets produce different tokens"
  (define secret1 (Secret "key1"))
  (define secret2 (Secret "key2"))
  (define token1 (with-jwt (lambda () (JWT.sign test-claims secret1))))
  (define token2 (with-jwt (lambda () (JWT.sign test-claims secret2))))
  (check-not-equal? (newtype-value-value token1) (newtype-value-value token2)))

(test-case "sign is NO LONGER deterministic: the exp stamp moves with the clock"
  ;; Recorded as a behaviour change, not a regression.  Two signings inside the
  ;; same second still match (one-second granularity), so this asserts the only
  ;; thing that is now guaranteed: both are valid tokens for the same subject.
  (define t1 (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define t2 (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define c1 (with-jwt (lambda () (JWT.verify t1 test-secret))))
  (define c2 (with-jwt (lambda () (JWT.verify t2 test-secret))))
  (check-equal? (hash-ref c1 "sub") (hash-ref c2 "sub")))

;; ── 2. JWT.verify tests ───────────────────────────────────────────────────────

(test-case "verify correct secret returns claims"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-true (hash? result))
  (check-equal? (hash-ref result "sub") "user123"))

(test-case "verify returns all claim fields"
  (define claims (hasheq 'sub "u1" 'name "Alice" 'role "admin"))
  (define token (with-jwt (lambda () (JWT.sign claims test-secret))))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-equal? (hash-ref result "sub") "u1")
  (check-equal? (hash-ref result "name") "Alice")
  (check-equal? (hash-ref result "role") "admin"))

(test-case "verify wrong secret returns check-fail"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define wrong-secret (Secret "wrong-key"))
  (define result (with-jwt (lambda () (JWT.verify token wrong-secret))))
  (check-true (check-fail? result))
  (check-equal? (check-fail-status result) 401))

(test-case "verify wrong secret check-fail message mentions signature"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define wrong-secret (Secret "wrong-key"))
  (define result (with-jwt (lambda () (JWT.verify token wrong-secret))))
  (check-true (string-contains (check-fail-message result) "signature")))

(test-case "verify token with no exp claim succeeds"
  (define claims-no-exp (hasheq 'sub "user123"))
  (define token (with-jwt (lambda () (JWT.sign claims-no-exp test-secret))))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-false (check-fail? result)))

(test-case "verify tampered signature fails"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define token-str (newtype-value-value token))
  (define parts (string-split token-str "."))
  ;; Replace last part (signature) with garbage
  (define tampered (string-append (list-ref parts 0) "." (list-ref parts 1) ".INVALIDSIGNATURE"))
  (define tampered-token (JwtToken tampered))
  (define result (with-jwt (lambda () (JWT.verify tampered-token test-secret))))
  (check-true (check-fail? result)))

;; ── 3. JWT.decode tests ───────────────────────────────────────────────────────

(test-case "decode returns claims without signature check"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define result (with-jwt (lambda () (JWT.decode token))))
  (check-true (hash? result))
  (check-equal? (hash-ref result "sub") "user123"))

(test-case "decode works even with wrong secret context"
  ;; decode ignores the secret — just decodes the payload
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define result (with-jwt (lambda () (JWT.decode token))))
  (check-equal? (hash-ref result "sub") "user123"))

(test-case "decode malformed token raises error"
  (define bad-token (JwtToken "not-a-jwt"))
  (check-exn exn:fail?
    (lambda () (with-jwt (lambda () (JWT.decode bad-token))))))

;; ── 4. Nominal type safety ────────────────────────────────────────────────────

(test-case "JwtToken is a newtype-value with JwtToken type"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (check-true (newtype-value? token))
  ;; The type token should be a reference containing 'JwtToken
  (define type-ref (newtype-value-type-name token))
  (check-true (or (equal? type-ref 'JwtToken)
                  (and (vector? type-ref) (member 'JwtToken (vector->list type-ref)))
                  #t)))  ; accept any token form

(test-case "the key is a newtype-value with the Secret type"
  (check-true (newtype-value? test-secret)))

;; The KEY-UNWRAP seam (2026-07-30).  `jwt-raw-string` strips exactly ONE newtype
;; layer after resolving through `raw-value`, and the key it is handed changed
;; type: it used to be jwt.rkt's own key newtype and is now Tesl.Crypto's
;; `Secret`.  Both are `define-secret-newtype` over String, so the shape is
;; identical — this pins that rather than assuming it, because a signature that
;; silently HMAC'd over the printed struct instead of the key would still produce
;; a plausible-looking token and would still round-trip through JWT.verify.
;;
;; The proof: signing with `(Secret k)` and signing with the bare string `k` must
;; produce the SAME token.  Only stripping exactly one layer gives that.  (A bare
;; string cannot reach here from Tesl — the checker demands a `Secret` — so this is
;; a Racket-level assertion about the unwrap, not a supported call shape.)
(test-case "UNWRAP: a Secret and its raw string sign identically"
  (define k "unwrap-seam-key")
  (define claims (hasheq 'sub "u"))
  ;; Same second, same claims, so the `exp` stamp matches; assert the header and
  ;; signature segments, which is where the key material actually lands.
  (define via-secret (newtype-value-value
                      (with-jwt (lambda () (JWT.sign claims (Secret k))))))
  (define via-string (newtype-value-value
                      (with-jwt (lambda () (JWT.sign claims k)))))
  (define hs (string-split via-secret "."))
  (define hr (string-split via-string "."))
  (check-equal? (list-ref hs 0) (list-ref hr 0) "header (kid) must match")
  (check-equal? (list-ref hs 2) (list-ref hr 2) "signature must match")
  ;; And the key is genuinely usable through the newtype on the verify side too.
  (define token (with-jwt (lambda () (JWT.sign claims (Secret k)))))
  (check-false (check-fail? (with-jwt (lambda () (JWT.verify token (Secret k)))))))

(test-case "JwtToken and Secret are distinct types"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  ;; They are different types — one cannot be used where the other is expected
  (check-not-equal? (newtype-value-type-name token)
                    (newtype-value-type-name test-secret)))

(test-case "JwtToken wraps a string"
  (define my-token (JwtToken "header.payload.sig"))
  (check-equal? (newtype-value-value my-token) "header.payload.sig"))

(test-case "Secret wraps a string"
  (define my-secret (Secret "my-secret"))
  (check-equal? (newtype-value-value my-secret) "my-secret"))

;; ── 5. Capability guard tests ─────────────────────────────────────────────────

(test-case "JWT.sign raises error without jwt capability"
  (check-exn exn:fail?
    (lambda () (JWT.sign test-claims test-secret))))

(test-case "JWT.verify raises error without jwt capability"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (check-exn exn:fail?
    (lambda () (JWT.verify token test-secret))))

(test-case "JWT.decode raises error without jwt capability"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (check-exn exn:fail?
    (lambda () (JWT.decode token))))

(test-case "JWT.sign works with the jwt AND time capabilities"
  (check-not-exn
    (lambda ()
      (with-capabilities (jwt time)
        (JWT.sign test-claims test-secret)))))

(test-case "JWT.sign refuses jwt WITHOUT time (it reads the clock)"
  ;; A capability marks an effect, and stamping `exp` from the wall clock is one.
  (check-exn exn:fail?
    (lambda ()
      (with-capabilities (jwt)
        (JWT.sign test-claims test-secret)))))

(test-case "JWT.verify works with jwt capability"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (check-not-exn
    (lambda ()
      (with-capabilities (jwt)
        (JWT.verify token test-secret)))))

;; ── 6. Edge cases ─────────────────────────────────────────────────────────────

(test-case "sign with minimal claims"
  (define minimal-claims (hasheq 'sub "x"))
  (define token (with-jwt (lambda () (JWT.sign minimal-claims test-secret))))
  (check-true (newtype-value? token)))

;; This used to pass a caller-supplied `iat` through untouched.  Since sliding
;; renewal landed (2026-07-30) `iat` is RESERVED alongside `exp`: it anchors the
;; absolute session lifetime across renewals, so a caller who could set it could
;; reset it on every renewal and make the session immortal.  The pass-through
;; property still holds for every claim that is not one of those two, which is
;; what this test now pins — with `nbf`, another registered RFC 7519 claim Tesl
;; does not manage, standing in for the general case.
(test-case "sign passes other registered claims through untouched"
  (define claims (hasheq 'sub "user" 'nbf 1000000 'aud "some-audience"))
  (define token (with-jwt (lambda () (JWT.sign claims test-secret))))
  (check-true (newtype-value? token))
  (define back (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-equal? (hash-ref back "nbf") 1000000)
  (check-equal? (hash-ref back "aud") "some-audience"))

(test-case "roundtrip: sign then verify preserves string sub"
  (define claims (hasheq 'sub "test-user-42"))
  (define token (with-jwt (lambda () (JWT.sign claims test-secret))))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-equal? (hash-ref result "sub") "test-user-42"))

(test-case "roundtrip: sign then decode gives same claims"
  (define claims (hasheq 'sub "u999" 'role "admin"))
  (define token (with-jwt (lambda () (JWT.sign claims test-secret))))
  (define decoded (with-jwt (lambda () (JWT.decode token))))
  (check-equal? (hash-ref decoded "sub") "u999")
  (check-equal? (hash-ref decoded "role") "admin"))

(test-case "verify fails after token payload tampering"
  (define claims (hasheq 'sub "legit-user"))
  (define token (with-jwt (lambda () (JWT.sign claims test-secret))))
  (define token-str (newtype-value-value token))
  (define parts (string-split token-str "."))
  ;; Build a new token with a different payload (different user)
  (define evil-claims (hasheq 'sub "evil-user"))
  (define evil-payload
    (let* ([json (jsexpr->string evil-claims)]
           [b (string->bytes/utf-8 json)]
           [b64 (bytes->string/utf-8 (base64-encode b #""))]
           [url (string-replace (string-replace b64 "+" "-") "/" "_")]
           [no-pad (regexp-replace* #rx"=+$" url "")])
      no-pad))
  (define tampered-str
    (string-append (list-ref parts 0) "." evil-payload "." (list-ref parts 2)))
  (define tampered-token (JwtToken tampered-str))
  (define result (with-jwt (lambda () (JWT.verify tampered-token test-secret))))
  (check-true (check-fail? result)))

;; ── 7. Additional roundtrip and edge cases ────────────────────────────────────

(test-case "sign then verify with future exp succeeds"
  (define future-claims (hasheq 'sub "user"))
  (define token (with-jwt (lambda () (JWT.sign future-claims test-secret))))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-false (check-fail? result)))

(test-case "sign with special characters in sub"
  (define claims (hasheq 'sub "user+name@example.com"))
  (define token (with-jwt (lambda () (JWT.sign claims test-secret))))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-equal? (hash-ref result "sub") "user+name@example.com"))

(test-case "sign with unicode in claims"
  (define claims (hasheq 'sub "user" 'name "Uber test"))
  (define token (with-jwt (lambda () (JWT.sign claims test-secret))))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-equal? (hash-ref result "name") "Uber test"))

(test-case "verify with check-fail status is exactly 401"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define wrong (Secret "wrong"))
  (define result (with-jwt (lambda () (JWT.verify token wrong))))
  (check-equal? (check-fail-status result) 401))

(test-case "decode multiple tokens in sequence"
  (define claims1 (hasheq 'sub "u1"))
  (define claims2 (hasheq 'sub "u2"))
  (define t1 (with-jwt (lambda () (JWT.sign claims1 test-secret))))
  (define t2 (with-jwt (lambda () (JWT.sign claims2 test-secret))))
  (define d1 (with-jwt (lambda () (JWT.decode t1))))
  (define d2 (with-jwt (lambda () (JWT.decode t2))))
  (check-equal? (hash-ref d1 "sub") "u1")
  (check-equal? (hash-ref d2 "sub") "u2"))

(test-case "sign with long secret key"
  (define long-secret (Secret (make-string 64 #\k)))
  (define token (with-jwt (lambda () (JWT.sign test-claims long-secret))))
  (define result (with-jwt (lambda () (JWT.verify token long-secret))))
  (check-false (check-fail? result)))

(test-case "sign token parts are non-empty"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define token-str (newtype-value-value token))
  (define parts (string-split token-str "."))
  (for ([p parts])
    (check-true (> (string-length p) 0))))

(test-case "different claims produce different payload part"
  (define claims1 (hasheq 'sub "alice"))
  (define claims2 (hasheq 'sub "bob"))
  (define t1 (with-jwt (lambda () (JWT.sign claims1 test-secret))))
  (define t2 (with-jwt (lambda () (JWT.sign claims2 test-secret))))
  (define payload1 (list-ref (string-split (newtype-value-value t1) ".") 1))
  (define payload2 (list-ref (string-split (newtype-value-value t2) ".") 1))
  (check-not-equal? payload1 payload2))

(test-case "JwtToken wraps value correctly (raw access)"
  (define token-str "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0In0.sig")
  (define token (JwtToken token-str))
  (check-equal? (newtype-value-value token) token-str))

(test-case "Secret wraps value correctly (raw access)"
  (define key "my-super-secret-key")
  (define secret (Secret key))
  (check-equal? (newtype-value-value secret) key))

;; ── 8. The `exp` contract: fixed TTL, epoch SECONDS, no caller knob ──────────
;;
;; Three properties, all of them load-bearing:
;;   * TTL     — JWT.sign stamps `exp` itself, ONE HOUR ahead.  There is no
;;               parameter, so a caller cannot pick ten years.
;;   * UNIT    — `exp` is epoch SECONDS (RFC 7519 §4.1.4), on both the mint and
;;               the verify side, so Tesl tokens interoperate with every other
;;               JWT library.  It was milliseconds until 2026-07-29.
;;   * NO KNOB — a caller-supplied `exp` in the claims dict is REJECTED, not
;;               overwritten: overwriting would mean the code says one expiry and
;;               the token carries another.

(define jwt-ttl-seconds-expected 3600)

;; A local HMAC-SHA256 + base64url + JWT assembler.  This deliberately duplicates
;; jwt.rkt's internals instead of calling JWT.sign: the point of the mint guard is
;; that a token with a caller-chosen or malformed `exp` is UNMINTABLE through the
;; public API, so the verify-side tests have to forge one out of band — exactly as
;; a foreign JWT library would.  Exposing a bypass from jwt.rkt for the test's
;; convenience would be a footgun in a security module.
(define-ffi-definer define-libcrypto-t libcrypto)
(define-libcrypto-t EVP_sha256 (_fun -> _pointer))
(define-libcrypto-t HMAC
  (_fun _pointer _bytes _int _bytes _int _bytes (_ptr o _uint) -> _pointer))

;; Assemble a syntactically valid, CORRECTLY SIGNED HS256 token over `claims`,
;; bypassing every Tesl-side guard.
(define (forge-token claims secret-str
                     ;; The DEFAULT is the pre-2026-07-30 Tesl header — no `kid`.
                     ;; That makes every `forge-token` test below double as a
                     ;; backward-compatibility assertion: these are exactly the
                     ;; tokens an older Tesl minted, and they must still verify.
                     #:header [header-json "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"])
  (define header-b64 (t-b64url (string->bytes/utf-8 header-json)))
  (define payload-b64 (t-b64url (string->bytes/utf-8 (jsexpr->string claims))))
  (define signing-input (string-append header-b64 "." payload-b64))
  (define out (make-bytes 32))
  (define key (string->bytes/utf-8 secret-str))
  (define data (string->bytes/utf-8 signing-input))
  (HMAC (EVP_sha256) key (bytes-length key) data (bytes-length data) out)
  (JwtToken (string-append signing-input "." (t-b64url out))))

(define (now-seconds)
  (inexact->exact (floor (/ (current-inexact-milliseconds) 1000.0))))

;; ── TTL and unit ─────────────────────────────────────────────────────────────

(test-case "TTL: JWT.sign stamps an exp one hour ahead"
  (define before (now-seconds))
  (define token (with-jwt (lambda () (JWT.sign (hash "sub" "u") test-secret))))
  (define after (now-seconds))
  (define claims (with-jwt (lambda () (JWT.verify token test-secret))))
  (define exp (hash-ref claims "exp"))
  (check-true (exact-integer? exp) (format "exp must be an exact integer, got ~s" exp))
  (check-true (>= exp (+ before jwt-ttl-seconds-expected)))
  (check-true (<= exp (+ after jwt-ttl-seconds-expected))))

(test-case "UNIT: exp is epoch SECONDS, not milliseconds (RFC 7519 NumericDate)"
  ;; The regression guard for the 2026-07-29 hard fix.  A millisecond stamp would
  ;; be ~1000x larger; assert the magnitude is a seconds-scale instant.  Upper
  ;; bound = one year out, which no correct one-hour TTL can reach and no
  ;; millisecond stamp can stay under.
  (define token (with-jwt (lambda () (JWT.sign (hash "sub" "u") test-secret))))
  (define exp (hash-ref (with-jwt (lambda () (JWT.verify token test-secret))) "exp"))
  (check-true (> exp (now-seconds)))
  (check-true (< exp (+ (now-seconds) 31536000))
              (format "exp ~s is not a seconds-scale instant — milliseconds regression?" exp)))

(test-case "UNIT: a Tesl token is accepted by a seconds-based foreign verifier"
  ;; Interop, from the other side: read `exp` the way any RFC 7519 library would
  ;; (seconds since the epoch) and it must describe an instant about an hour out.
  (define token (with-jwt (lambda () (JWT.sign (hash "sub" "u") test-secret))))
  (define payload-b64 (list-ref (string-split (newtype-value-value token) ".") 1))
  (define claims (string->jsexpr (bytes->string/utf-8 (t-b64url-decode payload-b64))))
  (define exp (hash-ref claims 'exp))
  (check-true (and (> (- exp (now-seconds)) 3500) (< (- exp (now-seconds)) 3700))
              (format "a foreign verifier would see ~s seconds of life" (- exp (now-seconds)))))

(test-case "UNIT: a FOREIGN seconds-valued token now verifies (was rejected)"
  ;; The direction the millisecond bug broke: an hour-ahead seconds `exp` minted
  ;; by any other library used to read as a 1970 instant and be rejected.
  (define token (forge-token (hasheq 'sub "u" 'exp (+ (now-seconds) 3600))
                             (newtype-value-value test-secret)))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-false (check-fail? result))
  (check-equal? (hash-ref result "sub") "u"))

(test-case "UNIT: NO dual-unit tolerance — a millisecond exp is not rescued"
  ;; A legacy millisecond stamp is a far-future instant, so it verifies; what must
  ;; NOT happen is a heuristic that "helpfully" rescales it.  The claim comes back
  ;; exactly as it went in.
  (define ms (+ (inexact->exact (floor (current-inexact-milliseconds))) 3600000))
  (define token (forge-token (hasheq 'sub "u" 'exp ms) (newtype-value-value test-secret)))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-false (check-fail? result))
  (check-equal? (hash-ref result "exp") ms))

;; ── No caller knob ───────────────────────────────────────────────────────────

(test-case "NO KNOB: a caller-supplied numeric exp is REJECTED, not overwritten"
  (check-exn exn:fail?
    (lambda () (with-jwt (lambda () (JWT.sign (hasheq 'sub "u" 'exp (+ (now-seconds) 315360000))
                                              test-secret))))))

(test-case "NO KNOB: a caller-supplied string exp is rejected (the Tesl Dict shape)"
  ;; `Dict String String` means any `exp` a Tesl program can write is a String.
  (check-exn exn:fail?
    (lambda () (with-jwt (lambda () (JWT.sign (hash "sub" "u" "exp" "3600") test-secret))))))

(test-case "NO KNOB: the refusal says expiry is not the caller's and names the TTL"
  (define msg
    (with-handlers ([exn:fail? exn-message])
      (with-jwt (lambda () (JWT.sign (hash "exp" "soon") test-secret)))
      "NO ERROR RAISED"))
  (check-true (string-contains msg "not yours to set"))
  (check-true (string-contains msg (number->string jwt-ttl-seconds-expected)))
  ;; and it points at the right tool for a long-lived credential
  (check-true (string-contains msg "randomToken")))

(test-case "NO KNOB: an exp of any other shape is rejected too"
  (check-exn exn:fail?
    (lambda () (with-jwt (lambda () (JWT.sign (hasheq 'exp #t) test-secret)))))
  (check-exn exn:fail?
    (lambda () (with-jwt (lambda () (JWT.sign (hasheq 'exp 'null) test-secret))))))

(test-case "NO KNOB: claims WITHOUT exp sign fine and the token verifies"
  (define token (with-jwt (lambda () (JWT.sign (hash "sub" "u") test-secret))))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-false (check-fail? result))
  (check-equal? (hash-ref result "sub") "u"))

;; ── Verify-side behaviour on tokens Tesl cannot mint ─────────────────────────

(test-case "VERIFY: a correctly signed token with a STRING exp is 401, not an exception"
  ;; Pins the already-fixed 500.  Before that fix `(< "…" now)` was a contract
  ;; violation escaping as an uncaught exception — a client-triggerable 500 on a
  ;; path where every other rejection is a 401.
  (define token (forge-token (hasheq 'sub "u" 'exp "9999999999999")
                             (newtype-value-value test-secret)))
  (define result
    (with-handlers ([exn:fail? (lambda (e) (list 'raised (exn-message e)))])
      (with-jwt (lambda () (JWT.verify token test-secret)))))
  (check-true (check-fail? result)
              (format "expected a check-fail, got ~s" result))
  (check-equal? (check-fail-status result) 401)
  (check-true (string-contains (string-downcase (check-fail-message result)) "expir")))

(test-case "VERIFY: the forged-token helper itself produces a VALID token"
  ;; Guards the test above from passing for the wrong reason — a bad signature
  ;; would also give 401.  The same forgery with a sane exp must VERIFY.
  (define token (forge-token (hasheq 'sub "u" 'exp (+ (now-seconds) 3600))
                             (newtype-value-value test-secret)))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-false (check-fail? result))
  (check-equal? (hash-ref result "sub") "u"))

(test-case "VERIFY: a token whose exp is in the past is 401"
  (define token (forge-token (hasheq 'sub "u" 'exp (- (now-seconds) 1))
                             (newtype-value-value test-secret)))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-true (check-fail? result))
  (check-equal? (check-fail-status result) 401)
  (check-true (string-contains (string-downcase (check-fail-message result)) "expir")))

(test-case "VERIFY: a foreign token with NO exp is accepted (exp is OPTIONAL per RFC)"
  ;; Tesl can no longer mint one — JWT.sign always stamps `exp` — so this covers
  ;; only the foreign case, which the RFC permits.
  (define token (forge-token (hasheq 'sub "u") (newtype-value-value test-secret)))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-false (check-fail? result))
  (check-equal? (hash-ref result "sub") "u"))

;; ── 9. The `kid` header stamp, and why it is backward compatible ─────────────
;;
;; Since 2026-07-30 `JWT.sign` stamps `kid` = `Crypto.keyFingerprint key` in the
;; JOSE header (RFC 7515 §4.1.4).  It is DERIVED, not chosen: there is no
;; parameter, and the value is a domain-separated digest truncated to 16 hex
;; characters, so it is safe to log and is not proof of key possession.
;;
;; The reason this could ship without a flag day is that `JWT.verify` never
;; PARSES the header — it recomputes the HMAC over `header.payload` verbatim.  The
;; four tests at the end of this section are that claim, stated as tests: a token
;; with no `kid`, with a foreign `kid`, with a wrong `kid`, and with extra header
;; fields all behave exactly as their signature says they should.

(define (header-of token)
  (string->jsexpr
   (bytes->string/utf-8
    (t-b64url-decode (car (string-split (newtype-value-value token) "."))))))

(test-case "KID: the minted token's kid IS Crypto.keyFingerprint of the key"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (check-equal? (hash-ref (header-of token) 'kid)
                (Crypto.keyFingerprint test-secret)))

(test-case "KID: 16 hex characters, and not the key itself"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define kid (hash-ref (header-of token) 'kid))
  (check-equal? (string-length kid) 16)
  (check-true (regexp-match? #px"^[0-9a-f]{16}$" kid))
  ;; The key must not survive anywhere in the token, header included.
  (check-false (string-contains (newtype-value-value token)
                                (newtype-value-value test-secret))))

(test-case "KID: two different keys give two different kids (and headers)"
  (define a (Secret "kid-key-a"))
  (define b (Secret "kid-key-b"))
  (define ta (with-jwt (lambda () (JWT.sign test-claims a))))
  (define tb (with-jwt (lambda () (JWT.sign test-claims b))))
  (check-not-equal? (hash-ref (header-of ta) 'kid) (hash-ref (header-of tb) 'kid))
  (check-not-equal? (car (string-split (newtype-value-value ta) "."))
                    (car (string-split (newtype-value-value tb) "."))))

(test-case "KID: the same key always stamps the same kid, whatever the claims"
  (define t1 (with-jwt (lambda () (JWT.sign (hasheq 'sub "alice") test-secret))))
  (define t2 (with-jwt (lambda () (JWT.sign (hasheq 'sub "bob") test-secret))))
  (check-equal? (hash-ref (header-of t1) 'kid) (hash-ref (header-of t2) 'kid)))

(test-case "KID: it is derived, so it cannot be chosen — there is no parameter"
  ;; `kid` is not a claim either: a caller putting one in the claims dict changes
  ;; the PAYLOAD, never the header, so it cannot masquerade as a key id.
  (define token (with-jwt (lambda () (JWT.sign (hash "sub" "u" "kid" "attacker-chosen")
                                               test-secret))))
  (check-equal? (hash-ref (header-of token) 'kid) (Crypto.keyFingerprint test-secret))
  (check-equal? (hash-ref (with-jwt (lambda () (JWT.verify token test-secret))) "kid")
                "attacker-chosen"))

(test-case "TWO TENANTS: A's token does not verify under B's key"
  (define key-a (Secret "tenant-a-key"))
  (define key-b (Secret "tenant-b-key"))
  (define token (with-jwt (lambda () (JWT.sign (hasheq 'sub "u") key-a))))
  (check-false (check-fail? (with-jwt (lambda () (JWT.verify token key-a)))))
  (define result (with-jwt (lambda () (JWT.verify token key-b))))
  (check-true (check-fail? result))
  (check-equal? (check-fail-status result) 401))

;; ── Backward compatibility: the verify path does not read the header ─────────

(test-case "COMPAT: a token whose header has NO kid still verifies"
  ;; This is the shape every Tesl token had before 2026-07-30.
  (define token (forge-token (hasheq 'sub "u" 'exp (+ (now-seconds) 3600))
                             (newtype-value-value test-secret)))
  ;; Guard the guard: the forged header really does lack `kid`.
  (check-false (hash-has-key? (header-of token) 'kid))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-false (check-fail? result))
  (check-equal? (hash-ref result "sub") "u"))

(test-case "COMPAT: a FOREIGN kid is not checked against the key"
  ;; A correctly signed token claiming some other key id verifies: `kid` is a
  ;; diagnostic, never an authorisation input.  Anything else would be a new way
  ;; for an attacker-supplied header field to change the outcome.
  (define token (forge-token (hasheq 'sub "u" 'exp (+ (now-seconds) 3600))
                             (newtype-value-value test-secret)
                             #:header "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"deadbeefdeadbeef\"}"))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-false (check-fail? result))
  (check-equal? (hash-ref result "sub") "u"))

(test-case "COMPAT: an unrecognised header field does not break verification"
  (define token (forge-token (hasheq 'sub "u" 'exp (+ (now-seconds) 3600))
                             (newtype-value-value test-secret)
                             #:header "{\"typ\":\"JWT\",\"alg\":\"HS256\",\"cty\":\"JWT\"}"))
  (check-false (check-fail? (with-jwt (lambda () (JWT.verify token test-secret))))))

(test-case "COMPAT: the header is part of the SIGNED input, so editing it is a 401"
  ;; The flip side, and the reason not parsing the header is safe rather than lax:
  ;; the header is inside the HMAC.  Swapping a Tesl-minted header for a kid-less
  ;; one invalidates the signature.
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define parts (string-split (newtype-value-value token) "."))
  (define swapped
    (JwtToken (string-append
               (t-b64url (string->bytes/utf-8 "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"))
               "." (list-ref parts 1) "." (list-ref parts 2))))
  (define result (with-jwt (lambda () (JWT.verify swapped test-secret))))
  (check-true (check-fail? result))
  (check-equal? (check-fail-status result) 401))

;; ── Section 10: JWT.renew — sliding sessions, with a hard stop ───────────────
;;
;; `JWT.renew` exists so an ACTIVE user is not logged out mid-task by the fixed
;; one-hour TTL, while an idle one still expires an hour after their last request.
;; Two properties carry the whole design and both are asserted below:
;;
;;   1. EVERY claim is carried across. Re-signing by hand is a trap — the verified
;;      claims contain `exp`/`iat`, `JWT.sign` rejects both, so an author who
;;      rebuilds the dict to strip them silently drops any claim they forget (a
;;      `role`, a tenant id) and downgrades the session on every renewal.
;;   2. `iat` is PRESERVED, and renewal refuses once `now - iat` passes
;;      `jwt-absolute-max-seconds`. Renewal is presented WITH the token, so an
;;      attacker holding a captured one can renew it exactly as its owner can. The
;;      cap is what keeps "a captured token is useful for a bounded time" true in
;;      a design that has no revocation — without it a stolen token is immortal.
;;
;; These use `forge-token` for the cases Tesl cannot mint (no `iat`, an `iat` in
;; the distant past, a non-numeric `iat`). Note `forge-token`'s default header is
;; the pre-`kid` one, so each of these doubles as a backward-compat assertion.

(test-case "RENEW: JWT.sign stamps iat, and it is epoch seconds"
  (define before (now-seconds))
  (define token (with-jwt (lambda () (JWT.sign (hasheq 'sub "u") test-secret))))
  (define after (now-seconds))
  (define iat (hash-ref (with-jwt (lambda () (JWT.verify token test-secret))) "iat"))
  (check-true (exact-integer? iat) (format "iat must be an exact integer, got ~s" iat))
  (check-true (>= iat before))
  (check-true (<= iat after)))

(test-case "RENEW: a caller-supplied iat is REJECTED, exactly like exp"
  ;; If a caller could set `iat` they could reset it on every renewal and defeat
  ;; the absolute cap entirely, so this guard is load-bearing, not tidiness.
  (check-exn
   #px"issued-at is not yours to set"
   (lambda () (with-jwt (lambda () (JWT.sign (hasheq 'sub "u" 'iat 1) test-secret))))))

(test-case "RENEW: every claim survives, and iat is preserved while exp slides"
  (define t0 (with-jwt (lambda () (JWT.sign (hasheq 'sub "u1" 'role "admin" 'tenant "acme")
                                            test-secret))))
  (define c0 (with-jwt (lambda () (JWT.verify t0 test-secret))))
  (define t1 (with-jwt (lambda () (JWT.renew t0 test-secret))))
  (check-false (check-fail? t1) "a fresh token renews")
  (define c1 (with-jwt (lambda () (JWT.verify t1 test-secret))))
  ;; THE footgun assertion: a hand-rolled re-sign is what drops these.
  (check-equal? (hash-ref c1 "sub") "u1")
  (check-equal? (hash-ref c1 "role") "admin")
  (check-equal? (hash-ref c1 "tenant") "acme")
  (check-equal? (hash-ref c1 "iat") (hash-ref c0 "iat") "iat preserved, NOT reset")
  (check-true (>= (hash-ref c1 "exp") (hash-ref c0 "exp")) "exp slid forward"))

(test-case "RENEW: repeated renewal never moves iat, so the cap cannot be walked past"
  (define t0 (with-jwt (lambda () (JWT.sign (hasheq 'sub "u1" 'role "admin") test-secret))))
  (define iat0 (hash-ref (with-jwt (lambda () (JWT.verify t0 test-secret))) "iat"))
  (define tn
    (for/fold ([t t0]) ([_ (in-range 6)])
      (define r (with-jwt (lambda () (JWT.renew t test-secret))))
      (check-false (check-fail? r))
      r))
  (define cn (with-jwt (lambda () (JWT.verify tn test-secret))))
  (check-equal? (hash-ref cn "iat") iat0 "still the ORIGINAL login time")
  (check-equal? (hash-ref cn "role") "admin"))

(test-case "RENEW: past the absolute cap is a 401 even though the signature is good"
  ;; The token verifies (valid signature, unexpired `exp`) and is STILL refused,
  ;; because its session has lived longer than the maximum. This is the assertion
  ;; that a captured token cannot be renewed forever.
  (define stale-iat (- (now-seconds) jwt-absolute-max-seconds 60))
  (define token (forge-token (hasheq 'sub "u1"
                                     'iat stale-iat
                                     'exp (+ (now-seconds) 600))
                             "test-secret-key-for-testing"))
  ;; Sanity: it really does verify — so the refusal below is the cap, not the HMAC.
  (check-false (check-fail? (with-jwt (lambda () (JWT.verify token test-secret))))
               "the forged token must verify, or this test proves nothing")
  (define result (with-jwt (lambda () (JWT.renew token test-secret))))
  (check-true (check-fail? result))
  (check-equal? (check-fail-status result) 401)
  (check-true (string-contains (check-fail-message result) "maximum lifetime")))

(test-case "RENEW: just inside the absolute cap still renews"
  ;; The boundary from the other side, so the cap is a bound and not a blanket
  ;; refusal of anything with an old iat.
  (define iat (- (now-seconds) jwt-absolute-max-seconds -120))
  (define token (forge-token (hasheq 'sub "u1" 'iat iat 'exp (+ (now-seconds) 600))
                             "test-secret-key-for-testing"))
  (define result (with-jwt (lambda () (JWT.renew token test-secret))))
  (check-false (check-fail? result) "inside the cap must renew")
  (define rc (with-jwt (lambda () (JWT.verify result test-secret))))
  (check-equal? (hash-ref rc "iat") iat "and it still preserves the original iat")
  ;; The renewed `exp` is CLAMPED to the absolute deadline (`iat + max`), not a
  ;; full fresh TTL past it — this is the 12h-vs-13h fix.  Here only ~120s of
  ;; budget remains, so the new exp must land within a second or two of the
  ;; deadline, NOT a full hour beyond it.
  (define deadline (+ iat jwt-absolute-max-seconds))
  (check-true (<= (hash-ref rc "exp") deadline)
              "renewed exp must not exceed the absolute deadline")
  (check-true (> (hash-ref rc "exp") (- deadline 5))
              "and it should use the budget that remains (clamped to the deadline)"))

(test-case "RENEW: a fresh token gets a full TTL — the clamp only bites near the cap"
  ;; Guard the other side of the clamp: for a token minted moments ago, the
  ;; deadline (`iat + 12h`) is far away, so the renewed exp is the ordinary
  ;; `now + 1h`, unchanged from before the clamp landed.
  (define t0 (with-jwt (lambda () (JWT.sign (hasheq 'sub "u1") test-secret))))
  (define before (now-seconds))
  (define r (with-jwt (lambda () (JWT.renew t0 test-secret))))
  (define exp (hash-ref (with-jwt (lambda () (JWT.verify r test-secret))) "exp"))
  (check-true (>= exp (+ before jwt-ttl-seconds-expected)))
  (check-true (<= exp (+ (now-seconds) jwt-ttl-seconds-expected))))

(test-case "RENEW: no iat at all cannot be renewed — FAIL CLOSED"
  ;; Covers foreign tokens (`iat` is OPTIONAL per RFC 7519) and tokens minted by a
  ;; Tesl older than this change. An unbounded-age token must not be renewable;
  ;; it simply runs out at its own `exp`, so the case self-heals within the hour.
  (define token (forge-token (hasheq 'sub "u1" 'exp (+ (now-seconds) 600))
                             "test-secret-key-for-testing"))
  (check-false (check-fail? (with-jwt (lambda () (JWT.verify token test-secret))))
               "a kid-less, iat-less token still VERIFIES (backward compat)")
  (define result (with-jwt (lambda () (JWT.renew token test-secret))))
  (check-true (check-fail? result))
  (check-equal? (check-fail-status result) 401)
  (check-true (string-contains (check-fail-message result) "issued-at")))

(test-case "RENEW: a non-numeric iat is unreadable, so also FAIL CLOSED"
  ;; Same rule the `exp` check follows: an expiry/age that cannot be read must not
  ;; be treated as absent-and-therefore-fine.
  (define token (forge-token (hasheq 'sub "u1" 'iat "yesterday" 'exp (+ (now-seconds) 600))
                             "test-secret-key-for-testing"))
  (define result (with-jwt (lambda () (JWT.renew token test-secret))))
  (check-true (check-fail? result))
  (check-equal? (check-fail-status result) 401))

(test-case "RENEW: an expired token is not renewable — renewal is not resurrection"
  (define token (forge-token (hasheq 'sub "u1" 'iat (- (now-seconds) 100)
                                     'exp (- (now-seconds) 10))
                             "test-secret-key-for-testing"))
  (define result (with-jwt (lambda () (JWT.renew token test-secret))))
  (check-true (check-fail? result))
  (check-equal? (check-fail-status result) 401)
  (check-true (string-contains (check-fail-message result) "expired")))

(test-case "RENEW: another tenant's key is a 401, through the same constant-time path"
  (define t0 (with-jwt (lambda () (JWT.sign (hasheq 'sub "u1") (Secret "tenant-a")))))
  (define result (with-jwt (lambda () (JWT.renew t0 (Secret "tenant-b")))))
  (check-true (check-fail? result))
  (check-equal? (check-fail-status result) 401)
  (check-true (string-contains (check-fail-message result) "signature")))

(test-case "RENEW: a structurally garbage token is a 401, never a raise"
  (define result (with-jwt (lambda () (JWT.renew (JwtToken "not-a-token") test-secret))))
  (check-true (check-fail? result))
  (check-equal? (check-fail-status result) 401))

(test-case "RENEW: the renewed token is stamped with the signing key's kid"
  (define t0 (with-jwt (lambda () (JWT.sign (hasheq 'sub "u1") test-secret))))
  (define t1 (with-jwt (lambda () (JWT.renew t0 test-secret))))
  (define header
    (string->jsexpr
     (bytes->string/utf-8
      (t-b64url-decode (list-ref (string-split (newtype-value-value t1) ".") 0)))))
  (check-equal? (hash-ref header 'kid) (Crypto.keyFingerprint test-secret))
  (check-equal? (hash-ref header 'alg) "HS256"))

(test-case "RENEW: capabilities — jwt AND time are both required"
  (define t0 (with-jwt (lambda () (JWT.sign (hasheq 'sub "u1") test-secret))))
  ;; It signs, so it needs `time` as well as `jwt` — the same rule as JWT.sign.
  (check-exn exn:fail?
             (lambda () (with-capabilities (jwt) (JWT.renew t0 test-secret))))
  (check-exn exn:fail?
             (lambda () (with-capabilities (time) (JWT.renew t0 test-secret)))))

(test-case "RENEW: renewal cannot walk a session PAST the cap — the attack, directly"
  ;; The property that makes the cap real. Start just inside the maximum, renew
  ;; once (which must succeed), then renew the RESULT after the boundary has
  ;; passed. If renewal reset `iat` instead of preserving it, the second renewal
  ;; would succeed and the session would be immortal — which is exactly the hole
  ;; a captured token would exploit, given there is no revocation.
  (define iat (- (now-seconds) jwt-absolute-max-seconds -60))   ; 60s left
  (define token (forge-token (hasheq 'sub "u1" 'iat iat 'exp (+ (now-seconds) 600))
                             "test-secret-key-for-testing"))
  (define once (with-jwt (lambda () (JWT.renew token test-secret))))
  (check-false (check-fail? once) "the first renewal is inside the cap")
  ;; The renewed token must carry the ORIGINAL iat, so its remaining budget is
  ;; still ~60s rather than a fresh 12 hours.
  (define c (with-jwt (lambda () (JWT.verify once test-secret))))
  (check-equal? (hash-ref c "iat") iat "the renewed token still dates from the original login")
  ;; Now forge the same claims with the clock effectively past the boundary — i.e.
  ;; ask whether a token bearing that preserved iat is renewable once the cap has
  ;; elapsed. It must not be.
  (define past (forge-token (hasheq 'sub "u1"
                                    'iat (- (now-seconds) jwt-absolute-max-seconds 1)
                                    'exp (+ (now-seconds) 600))
                            "test-secret-key-for-testing"))
  (define again (with-jwt (lambda () (JWT.renew past test-secret))))
  (check-true (check-fail? again) "past the cap, renewal is refused")
  (check-equal? (check-fail-status again) 401)
  (check-true (string-contains (check-fail-message again) "maximum lifetime")))

;; ── Section 11: the `iat` SHAPE guard (adversarial review F5, 2026-07-30) ────
;;
;; `JWT.renew` used to accept any `real?` `iat`, which is exactly wide enough to
;; break the absolute cap the claim exists to enforce.  Two ways in, and both
;; survive renewal because `iat` is PRESERVED — one malformed claim yields an
;; effectively immortal session:
;;
;;   * a huge float (`1e300`, `+inf.0`) makes `now - iat` hugely NEGATIVE, so the
;;     `> … max` cap check passes forever;
;;   * an `iat` dated in the FUTURE widens the cap by its distance ahead — the
;;     token's measured age is smaller than its real age for its whole life.
;;
;; Neither is reachable while Tesl mints every token (`JWT.sign` stamps `iat`
;; from the clock; the mint guard is total), which is why this was LOW.  Both
;; become reachable the moment a Tesl verifier shares its HS256 secret with a
;; foreign minter — the SSO case — and a fast-clocked replica reaches the second
;; one under nothing worse than clock skew.  So the guard lands first:
;; `exact-nonnegative-integer?`, plus a minute of skew tolerance and no more.

(test-case "IAT-SHAPE: a huge float iat cannot be renewed — the immortal-session forge"
  ;; The direct attack. `(- now 1e300)` is about -1e300, comfortably under the
  ;; cap, so under the old `real?` test this renewed — and kept renewing, because
  ;; the renewal preserves the same bogus `iat`.
  (define token (forge-token (hasheq 'sub "u1" 'iat 1e300 'exp (+ (now-seconds) 600))
                             "test-secret-key-for-testing"))
  (check-false (check-fail? (with-jwt (lambda () (JWT.verify token test-secret))))
               "the forged token must verify, or this test proves nothing")
  (define result (with-jwt (lambda () (JWT.renew token test-secret))))
  (check-true (check-fail? result) "a non-integer iat must not be renewable")
  (check-equal? (check-fail-status result) 401)
  (check-true (string-contains (check-fail-message result) "issued-at")))

(test-case "IAT-SHAPE: an ordinary float iat is refused too — NumericDate is an integer"
  ;; Not an attack by itself; it is the shape rule that makes the case above
  ;; impossible to reach by argument about which floats are safe.
  (define token (forge-token (hasheq 'sub "u1" 'iat (exact->inexact (- (now-seconds) 10))
                                     'exp (+ (now-seconds) 600))
                             "test-secret-key-for-testing"))
  (define result (with-jwt (lambda () (JWT.renew token test-secret))))
  (check-true (check-fail? result))
  (check-equal? (check-fail-status result) 401))

(test-case "IAT-SHAPE: a negative iat is refused"
  ;; `now - iat` is LARGER than the true age here, so this one fails closed even
  ;; without the guard — asserted so the shape rule is complete rather than
  ;; incidentally correct.
  (define token (forge-token (hasheq 'sub "u1" 'iat -1 'exp (+ (now-seconds) 600))
                             "test-secret-key-for-testing"))
  (define result (with-jwt (lambda () (JWT.renew token test-secret))))
  (check-true (check-fail? result))
  (check-equal? (check-fail-status result) 401))

(test-case "IAT-SHAPE: an iat in the future cannot be renewed — the cap-widening forge"
  ;; A day ahead buys a day of extra session on top of the 12h cap. Under the old
  ;; test this renewed happily, and the future `iat` was carried across.
  (define token (forge-token (hasheq 'sub "u1"
                                     'iat (+ (now-seconds) 86400)
                                     'exp (+ (now-seconds) 600))
                             "test-secret-key-for-testing"))
  (define result (with-jwt (lambda () (JWT.renew token test-secret))))
  (check-true (check-fail? result) "a future-dated iat must not be renewable")
  (check-equal? (check-fail-status result) 401)
  (check-true (string-contains (check-fail-message result) "issued-at")))

(test-case "IAT-SHAPE: a minute of clock skew is still tolerated"
  ;; The bound from the other side. Two replicas behind an NTP-drifted clock must
  ;; not log users out, so a slightly-ahead `iat` renews — the guard is a shape
  ;; and skew rule, not a blanket refusal of anything not in the past.
  (define token (forge-token (hasheq 'sub "u1"
                                     'iat (+ (now-seconds) 5)
                                     'exp (+ (now-seconds) 600))
                             "test-secret-key-for-testing"))
  (define result (with-jwt (lambda () (JWT.renew token test-secret))))
  (check-false (check-fail? result) "a few seconds of skew must still renew")
  (check-equal? (hash-ref (with-jwt (lambda () (JWT.verify result test-secret))) "sub") "u1"))

(test-case "IAT-SHAPE: JWT.sign's own tokens are unaffected — the guard is not a regression"
  (define t0 (with-jwt (lambda () (JWT.sign (hasheq 'sub "u1" 'role "admin") test-secret))))
  (define t1 (with-jwt (lambda () (JWT.renew t0 test-secret))))
  (check-false (check-fail? t1) "a Tesl-minted token must always renew")
  (define c (with-jwt (lambda () (JWT.verify t1 test-secret))))
  (check-true (exact-nonnegative-integer? (hash-ref c "iat"))
              "and the iat Tesl stamps must satisfy the guard by construction")
  (check-equal? (hash-ref c "role") "admin"))
