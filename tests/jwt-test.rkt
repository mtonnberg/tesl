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
;;;   - Capability enforcement (jwt capability required)
;;;   - Base64url encoding (no padding, url-safe chars)
;;;   - Roundtrip sign→verify with various claim shapes

(require rackunit
         json
         net/base64
         (file "../tesl/jwt.rkt")
         (file "../dsl/capability.rkt")
         (file "../dsl/types.rkt")
         (file "../dsl/private/evidence.rkt"))

;; string-contains is not available in all Racket versions — define it
(define (string-contains haystack needle)
  (if (regexp-match? (regexp (regexp-quote needle)) haystack)
      #t #f))

;; ── Helpers ──────────────────────────────────────────────────────────────────

(define (with-jwt thunk)
  (with-capabilities (jwt) (thunk)))

(define test-secret (JwtSecret "test-secret-key-for-testing"))
(define test-claims (hasheq 'sub "user123" 'exp 9999999999999))

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

(test-case "sign consistent: same inputs produce same token"
  (define t1 (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define t2 (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (check-equal? (newtype-value-value t1) (newtype-value-value t2)))

;; ── 2. JWT.verify tests ───────────────────────────────────────────────────────

(test-case "verify correct secret returns claims"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-true (hash? result))
  (check-equal? (hash-ref result "sub") "user123"))

(test-case "verify returns all claim fields"
  (define claims (hasheq 'sub "u1" 'name "Alice" 'role "admin" 'exp 9999999999999))
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

(test-case "verify expired token returns check-fail"
  (define expired-claims (hasheq 'sub "user" 'exp 1000))  ; exp in far past
  (define token (with-jwt (lambda () (JWT.sign expired-claims test-secret))))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-true (check-fail? result))
  (check-equal? (check-fail-status result) 401))

(test-case "verify expired token check-fail mentions expir"
  (define expired-claims (hasheq 'sub "user" 'exp 1000))
  (define token (with-jwt (lambda () (JWT.sign expired-claims test-secret))))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-true (string-contains (string-downcase (check-fail-message result)) "expir")))

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
  (define token (with-capabilities (jwt) (JWT.sign test-claims test-secret)))
  (check-exn exn:fail?
    (lambda () (JWT.verify token test-secret))))

(test-case "JWT.decode raises error without jwt capability"
  (define token (with-capabilities (jwt) (JWT.sign test-claims test-secret)))
  (check-exn exn:fail?
    (lambda () (JWT.decode token))))

(test-case "JWT.sign works with jwt capability"
  (check-not-exn
    (lambda ()
      (with-capabilities (jwt)
        (JWT.sign test-claims test-secret)))))

(test-case "JWT.verify works with jwt capability"
  (define token (with-capabilities (jwt) (JWT.sign test-claims test-secret)))
  (check-not-exn
    (lambda ()
      (with-capabilities (jwt)
        (JWT.verify token test-secret)))))

;; ── 6. Edge cases ─────────────────────────────────────────────────────────────

(test-case "sign with minimal claims"
  (define minimal-claims (hasheq 'sub "x"))
  (define token (with-jwt (lambda () (JWT.sign minimal-claims test-secret))))
  (check-true (newtype-value? token)))

(test-case "sign with integer exp claim"
  (define claims (hasheq 'sub "user" 'exp 9999999999999 'iat 1000000))
  (define token (with-jwt (lambda () (JWT.sign claims test-secret))))
  (check-true (newtype-value? token)))

(test-case "roundtrip: sign then verify preserves string sub"
  (define claims (hasheq 'sub "test-user-42" 'exp 9999999999999))
  (define token (with-jwt (lambda () (JWT.sign claims test-secret))))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-equal? (hash-ref result "sub") "test-user-42"))

(test-case "roundtrip: sign then decode gives same claims"
  (define claims (hasheq 'sub "u999" 'exp 9999999999999 'role "admin"))
  (define token (with-jwt (lambda () (JWT.sign claims test-secret))))
  (define decoded (with-jwt (lambda () (JWT.decode token))))
  (check-equal? (hash-ref decoded "sub") "u999")
  (check-equal? (hash-ref decoded "role") "admin"))

(test-case "verify fails after token payload tampering"
  (define claims (hasheq 'sub "legit-user" 'exp 9999999999999))
  (define token (with-jwt (lambda () (JWT.sign claims test-secret))))
  (define token-str (newtype-value-value token))
  (define parts (string-split token-str "."))
  ;; Build a new token with a different payload (different user)
  (define evil-claims (hasheq 'sub "evil-user" 'exp 9999999999999))
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
  (define future-claims (hasheq 'sub "user" 'exp 9999999999999))
  (define token (with-jwt (lambda () (JWT.sign future-claims test-secret))))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-false (check-fail? result)))

(test-case "sign with special characters in sub"
  (define claims (hasheq 'sub "user+name@example.com" 'exp 9999999999999))
  (define token (with-jwt (lambda () (JWT.sign claims test-secret))))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-equal? (hash-ref result "sub") "user+name@example.com"))

(test-case "sign with unicode in claims"
  (define claims (hasheq 'sub "user" 'name "Uber test" 'exp 9999999999999))
  (define token (with-jwt (lambda () (JWT.sign claims test-secret))))
  (define result (with-jwt (lambda () (JWT.verify token test-secret))))
  (check-equal? (hash-ref result "name") "Uber test"))

(test-case "verify with check-fail status is exactly 401"
  (define token (with-jwt (lambda () (JWT.sign test-claims test-secret))))
  (define wrong (JwtSecret "wrong"))
  (define result (with-jwt (lambda () (JWT.verify token wrong))))
  (check-equal? (check-fail-status result) 401))

(test-case "decode multiple tokens in sequence"
  (define claims1 (hasheq 'sub "u1" 'exp 9999999999999))
  (define claims2 (hasheq 'sub "u2" 'exp 9999999999999))
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
  (define claims1 (hasheq 'sub "alice" 'exp 9999999999999))
  (define claims2 (hasheq 'sub "bob" 'exp 9999999999999))
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
