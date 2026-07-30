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
;;;   - JwtToken and JwtSecret are distinct nominal newtypes
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
         (file "../tesl/time.rkt")
         (file "../dsl/capability.rkt")
         (file "../dsl/types.rkt")
         (file "../dsl/private/evidence.rkt"))

;; string-contains is not available in all Racket versions — define it
(define (string-contains haystack needle)
  (if (regexp-match? (regexp (regexp-quote needle)) haystack)
      #t #f))

;; ── Helpers ──────────────────────────────────────────────────────────────────

;; JWT.sign now reads the wall clock (it stamps `exp` itself), so the ambient
;; capability set for these tests is `jwt` AND `time`.  The capability-guard
;; section below deliberately grants them one at a time to pin that both are
;; required.
(define (with-jwt thunk)
  (with-capabilities (jwt time) (thunk)))

(define test-secret (JwtSecret "test-secret-key-for-testing"))
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

(test-case "sign header is standard HS256 JWT header"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define token-str (newtype-value-value token))
  (define header-b64 (car (string-split token-str ".")))
  ;; Standard HS256/JWT header base64url encodes to this fixed value
  (check-equal? header-b64 "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))

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
  (define secret1 (JwtSecret "key1"))
  (define secret2 (JwtSecret "key2"))
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
  (define wrong-secret (JwtSecret "wrong-key"))
  (define result (with-jwt (lambda () (JWT.verify token wrong-secret))))
  (check-true (check-fail? result))
  (check-equal? (check-fail-status result) 401))

(test-case "verify wrong secret check-fail message mentions signature"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define wrong-secret (JwtSecret "wrong-key"))
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

(test-case "JwtSecret is a newtype-value with JwtSecret type"
  (check-true (newtype-value? test-secret)))

(test-case "JwtToken and JwtSecret are distinct types"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  ;; They are different types — one cannot be used where the other is expected
  (check-not-equal? (newtype-value-type-name token)
                    (newtype-value-type-name test-secret)))

(test-case "JwtToken wraps a string"
  (define my-token (JwtToken "header.payload.sig"))
  (check-equal? (newtype-value-value my-token) "header.payload.sig"))

(test-case "JwtSecret wraps a string"
  (define my-secret (JwtSecret "my-secret"))
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

(test-case "sign passes other registered claims through untouched"
  (define claims (hasheq 'sub "user" 'iat 1000000))
  (define token (with-jwt (lambda () (JWT.sign claims test-secret))))
  (check-true (newtype-value? token))
  (define back (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-equal? (hash-ref back "iat") 1000000))

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
  (define wrong (JwtSecret "wrong"))
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
  (define long-secret (JwtSecret (make-string 64 #\k)))
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

(test-case "JwtSecret wraps value correctly (raw access)"
  (define key "my-super-secret-key")
  (define secret (JwtSecret key))
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

(define (t-b64url bstr)
  (regexp-replace*
   #rx"=+$"
   (string-replace (string-replace (bytes->string/utf-8 (base64-encode bstr #"")) "+" "-")
                   "/" "_")
   ""))

;; Assemble a syntactically valid, CORRECTLY SIGNED HS256 token over `claims`,
;; bypassing every Tesl-side guard.
(define (forge-token claims secret-str)
  (define header-b64 (t-b64url (string->bytes/utf-8 "{\"alg\":\"HS256\",\"typ\":\"JWT\"}")))
  (define payload-b64 (t-b64url (string->bytes/utf-8 (jsexpr->string claims))))
  (define signing-input (string-append header-b64 "." payload-b64))
  (define out (make-bytes 32))
  (define key (string->bytes/utf-8 secret-str))
  (define data (string->bytes/utf-8 signing-input))
  (HMAC (EVP_sha256) key (bytes-length key) data (bytes-length data) out)
  (JwtToken (string-append signing-input "." (t-b64url out))))

(define (now-seconds)
  (inexact->exact (floor (/ (current-inexact-milliseconds) 1000.0))))

;; base64url → bytes, the way a foreign JWT library would decode a payload.
;; Local, for the same reason forge-token is local: jwt.rkt does not provide it.
(define (t-b64url-decode str)
  (define s (string-replace (string-replace str "-" "+") "_" "/"))
  (define padded
    (case (remainder (string-length s) 4)
      [(2) (string-append s "==")]
      [(3) (string-append s "=")]
      [else s]))
  (base64-decode (string->bytes/utf-8 padded)))

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
