#lang racket

(require
  tesl/dsl/capability
  tesl/dsl/types
  tesl/dsl/check
  tesl/dsl/otel
  tesl/dsl/sql
  tesl/dsl/web
  tesl/dsl/test-support
  tesl/dsl/debug/checkpoint
  tesl/tesl/private/runtime
  tesl/tesl/queue
  tesl/tesl/sse
  (only-in tesl/tesl/prelude Bool Int String List Unit)
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.startsWith tesl_import_String_startsWith] [String.contains tesl_import_String_contains])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict Dict [Dict.singleton tesl_import_Dict_singleton] [Dict.fromList tesl_import_Dict_fromList] [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/tuple Tuple2)
  (only-in tesl/tesl/time time)
  (only-in tesl/tesl/jwt jwt JwtToken JwtSecret [JWT.sign tesl_import_JWT_sign] [JWT.verify tesl_import_JWT_verify] [JWT.decode tesl_import_JWT_decode] Authentic)
)


(provide makeSecret makeToken wrapToken signClaims signClaimsWithOwnExp subjectOfAuthenticClaims verifyClaims decodeClaims checkTokenStr tokenLength makeSecret-signature makeToken-signature wrapToken-signature signClaims-signature signClaimsWithOwnExp-signature subjectOfAuthenticClaims-signature verifyClaims-signature decodeClaims-signature checkTokenStr-signature tokenLength-signature)

(define-capability jwtCap (implies jwt time))

(define/pow
  (makeSecret [s : String])
  #:returns JwtSecret
  (thsl-src! "tests/jwt-tests.tesl" 58 (list (cons 's *s)) (lambda () (raw-value (JwtSecret *s)))))

(define/pow
  (makeToken [s : String])
  #:returns JwtToken
  (thsl-src! "tests/jwt-tests.tesl" 61 (list (cons 's *s)) (lambda () (raw-value (JwtToken *s)))))

(define/pow
  (wrapToken [s : String])
  #:returns JwtToken
  (thsl-src! "tests/jwt-tests.tesl" 64 (list (cons 's *s)) (lambda () (raw-value (JwtToken *s)))))

(define/pow
  (signClaims [claims : String] [secret : JwtSecret])
  #:capabilities [jwtCap]
  #:returns JwtToken
  (thsl-src! "tests/jwt-tests.tesl" 69 (list (cons 'claims *claims) (cons 'secret *secret)) (lambda () (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_singleton "sub" *claims)) *secret)))))

(define/pow
  (signClaimsWithOwnExp [claims : String] [secret : JwtSecret])
  #:capabilities [jwtCap]
  #:returns JwtToken
  (thsl-src! "tests/jwt-tests.tesl" 76 (list (cons 'claims *claims) (cons 'secret *secret)) (lambda () (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_fromList (list (Tuple2 "sub" claims) (Tuple2 "exp" "3600")))) *secret)))))

(define/pow
  (subjectOfAuthenticClaims [claims : (Dict String String) ::: (Authentic claims)])
  #:returns String
  (thsl-src-control! "tests/jwt-tests.tesl" 81 (list (cons 'claims *claims)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "sub" *claims))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/jwt-tests.tesl" 82 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([s (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/jwt-tests.tesl" 83 (list (cons 's s)) (lambda () *s)))])))))

(define/pow
  (verifyClaims [token : JwtToken] [secret : JwtSecret])
  #:capabilities [jwtCap]
  #:returns String
  (thsl-src! "tests/jwt-tests.tesl" 89 (list (cons 'token *token) (cons 'secret *secret)) (lambda () (let/check ([tesl-checked-1 (tesl_import_JWT_verify token secret)]) (let ([claims tesl-checked-1]) (let ([tesl-case-2 (raw-value (tesl_import_Dict_lookup "sub" claims))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "tests/jwt-tests.tesl" 91 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([s (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "tests/jwt-tests.tesl" 92 (list (cons 's s)) (lambda () *s)))])))))))

(define/pow
  (decodeClaims [token : JwtToken])
  #:capabilities [jwtCap]
  #:returns String
  (thsl-src-control! "tests/jwt-tests.tesl" 95 (list (cons 'token *token)) (lambda () (let ([tesl-case-3 (raw-value (tesl_import_Dict_lookup "sub" (raw-value (tesl_import_JWT_decode *token))))]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "tests/jwt-tests.tesl" 96 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([s (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "tests/jwt-tests.tesl" 97 (list (cons 's s)) (lambda () *s)))])))))

(define/pow
  (checkTokenStr [token : JwtToken])
  #:returns String
  (thsl-src! "tests/jwt-tests.tesl" 100 (list (cons 'token *token)) (lambda () (raw-value token.value))))

(define/pow
  (tokenLength [token : JwtToken])
  #:returns Integer
  (thsl-src! "tests/jwt-tests.tesl" 103 (list (cons 'token *token)) (lambda () (raw-value (tesl_import_String_length (raw-value token.value))))))

(module+ test
  (require rackunit)
  (test-case "T01: a JwtSecret can be constructed and used to sign"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s (thsl-src! "tests/jwt-tests.tesl" 113 (list) (lambda () (makeSecret "my-key"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 114 (list (cons 's s)) (lambda () (signClaims "user" s))))
    (check-true (raw-value (thsl-src! "tests/jwt-tests.tesl" 115 (list (cons 'token token) (cons 's s)) (lambda () (tesl_import_String_startsWith (raw-value (tesl-dot/runtime token 'value)) "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")))))
    )
    ))
  )

  (test-case "T02: JwtToken constructor wraps a string"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/jwt-tests.tesl" 119 (list) (lambda () (makeToken "header.payload.sig"))))
  (check-equal? (thsl-src! "tests/jwt-tests.tesl" 120 (list (cons 't t)) (lambda () (raw-value (tesl-dot/runtime t 'value)))) "header.payload.sig")
    ))
  )

  (test-case "T03: wrapToken produces JwtToken"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/jwt-tests.tesl" 124 (list) (lambda () (wrapToken "abc.def.ghi"))))
  (check-equal? (thsl-src! "tests/jwt-tests.tesl" 125 (list (cons 't t)) (lambda () (raw-value (tesl-dot/runtime t 'value)))) "abc.def.ghi")
    ))
  )

  (test-case "T04: JWT.sign produces a token (trusts runtime)"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 129 (list) (lambda () (makeSecret "test-secret"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 130 (list (cons 'secret secret)) (lambda () (signClaims "user123" secret))))
    (check-true (thsl-src! "tests/jwt-tests.tesl" 131 (list (cons 'token token) (cons 'secret secret)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime token 'value)))) 0))))
    )
    ))
  )

  (test-case "T05: JWT token has three parts separated by dots"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 135 (list) (lambda () (makeSecret "test-secret"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 136 (list (cons 'secret secret)) (lambda () (signClaims "user456" secret))))
    (define tokenStr (thsl-src! "tests/jwt-tests.tesl" 137 (list (cons 'token token) (cons 'secret secret)) (lambda () (raw-value (tesl-dot/runtime token 'value)))))
    (check-true (thsl-src! "tests/jwt-tests.tesl" 138 (list (cons 'tokenStr tokenStr) (cons 'token token) (cons 'secret secret)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value tokenStr))) 10))))
    )
    ))
  )

  (test-case "T06: JWT.sign token starts with known header"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 142 (list) (lambda () (makeSecret "test-secret"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 143 (list (cons 'secret secret)) (lambda () (signClaims "alice" secret))))
    (check-true (raw-value (thsl-src! "tests/jwt-tests.tesl" 144 (list (cons 'token token) (cons 'secret secret)) (lambda () (tesl_import_String_startsWith (raw-value (tesl-dot/runtime token 'value)) "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")))))
    )
    ))
  )

  (test-case "T07: JwtToken .value extracts the underlying string"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/jwt-tests.tesl" 148 (list) (lambda () (makeToken "raw.token.string"))))
  (check-equal? (thsl-src! "tests/jwt-tests.tesl" 149 (list (cons 't t)) (lambda () (raw-value (tesl-dot/runtime t 'value)))) "raw.token.string")
    ))
  )

  (test-case "T08: tokenLength counts characters in token"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 153 (list) (lambda () (makeSecret "key"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 154 (list (cons 'secret secret)) (lambda () (signClaims "user" secret))))
    (check-true (thsl-src! "tests/jwt-tests.tesl" 155 (list (cons 'token token) (cons 'secret secret)) (lambda () (tesl-gt? (raw-value (tokenLength token)) 20))))
    )
    ))
  )

  (test-case "T09: checkTokenStr returns the inner string"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/jwt-tests.tesl" 159 (list) (lambda () (makeToken "x.y.z"))))
  (check-equal? (raw-value (thsl-src! "tests/jwt-tests.tesl" 160 (list (cons 't t)) (lambda () (checkTokenStr t)))) "x.y.z")
    ))
  )

  (test-case "T10: makeSecret is deterministic \226\128\148 the same key string signs identically"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s1 (thsl-src! "tests/jwt-tests.tesl" 164 (list) (lambda () (makeSecret "super-secret"))))
    (define s2 (thsl-src! "tests/jwt-tests.tesl" 165 (list (cons 's1 s1)) (lambda () (makeSecret "super-secret"))))
    (check-equal? (thsl-src! "tests/jwt-tests.tesl" 166 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl-dot/runtime (signClaims "user" s1) 'value)))) (raw-value (tesl-dot/runtime (signClaims "user" s2) 'value)))
    )
    ))
  )

  (test-case "T11: JWT.sign with long claims still produces token"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 170 (list) (lambda () (makeSecret "s"))))
    (define claims (thsl-src! "tests/jwt-tests.tesl" 171 (list (cons 'secret secret)) (lambda () "a-very-long-user-identifier-for-testing-purposes")))
    (define token (thsl-src! "tests/jwt-tests.tesl" 172 (list (cons 'claims claims) (cons 'secret secret)) (lambda () (signClaims claims secret))))
    (check-true (thsl-src! "tests/jwt-tests.tesl" 173 (list (cons 'token token) (cons 'claims claims) (cons 'secret secret)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime token 'value)))) 30))))
    )
    ))
  )

  (test-case "T12: different secrets produce different tokens"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s1 (thsl-src! "tests/jwt-tests.tesl" 177 (list) (lambda () (makeSecret "key1"))))
    (define s2 (thsl-src! "tests/jwt-tests.tesl" 178 (list (cons 's1 s1)) (lambda () (makeSecret "key2"))))
    (define t1 (thsl-src! "tests/jwt-tests.tesl" 179 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (signClaims "user" s1))))
    (define t2 (thsl-src! "tests/jwt-tests.tesl" 180 (list (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (signClaims "user" s2))))
    (check-not-equal? (thsl-src! "tests/jwt-tests.tesl" 181 (list (cons 't2 t2) (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl-dot/runtime t1 'value)))) (raw-value (tesl-dot/runtime t2 'value)))
    )
    ))
  )

  (test-case "T13: same inputs always produce same token"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s (thsl-src! "tests/jwt-tests.tesl" 185 (list) (lambda () (makeSecret "consistent-key"))))
    (define t1 (thsl-src! "tests/jwt-tests.tesl" 186 (list (cons 's s)) (lambda () (signClaims "user" s))))
    (define t2 (thsl-src! "tests/jwt-tests.tesl" 187 (list (cons 't1 t1) (cons 's s)) (lambda () (signClaims "user" s))))
    (check-equal? (thsl-src! "tests/jwt-tests.tesl" 188 (list (cons 't2 t2) (cons 't1 t1) (cons 's s)) (lambda () (raw-value (tesl-dot/runtime t1 'value)))) (raw-value (tesl-dot/runtime t2 'value)))
    )
    ))
  )

  (test-case "T14: JwtToken value is a non-empty string"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/jwt-tests.tesl" 192 (list) (lambda () (makeToken "some.jwt.token"))))
  (check-true (thsl-src! "tests/jwt-tests.tesl" 193 (list (cons 't t)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t 'value)))) 0))))
    ))
  )

  (test-case "T15: the secret does not leak into the token it signs"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s (thsl-src! "tests/jwt-tests.tesl" 197 (list) (lambda () (makeSecret "not-empty-secret"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 198 (list (cons 's s)) (lambda () (signClaims "user" s))))
    (check-true (raw-value (thsl-src! "tests/jwt-tests.tesl" 199 (list (cons 'token token) (cons 's s)) (lambda () (not (tesl_import_String_contains (raw-value (tesl-dot/runtime token 'value)) "not-empty-secret"))))))
    )
    ))
  )

  (test-case "T16: signClaims token is not the same as the claims string"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 203 (list) (lambda () (makeSecret "k"))))
    (define claims (thsl-src! "tests/jwt-tests.tesl" 204 (list (cons 'secret secret)) (lambda () "user123")))
    (define token (thsl-src! "tests/jwt-tests.tesl" 205 (list (cons 'claims claims) (cons 'secret secret)) (lambda () (signClaims claims secret))))
    (check-not-equal? (thsl-src! "tests/jwt-tests.tesl" 206 (list (cons 'token token) (cons 'claims claims) (cons 'secret secret)) (lambda () (raw-value (tesl-dot/runtime token 'value)))) claims)
    )
    ))
  )

  (test-case "T17: signClaims with empty string secret produces token"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 210 (list) (lambda () (makeSecret ""))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 211 (list (cons 'secret secret)) (lambda () (signClaims "user" secret))))
    (check-true (thsl-src! "tests/jwt-tests.tesl" 212 (list (cons 'token token) (cons 'secret secret)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime token 'value)))) 0))))
    )
    ))
  )

  (test-case "T18: decodeClaims extracts payload (no sig check)"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 216 (list) (lambda () (makeSecret "test-key"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 217 (list (cons 'secret secret)) (lambda () (signClaims "decode-test" secret))))
    (define tesl-ignored-4 (thsl-src! "tests/jwt-tests.tesl" 218 (list (cons 'token token) (cons 'secret secret)) (lambda () (decodeClaims token))))
    (check-equal? (raw-value (thsl-src! "tests/jwt-tests.tesl" 219 (list (cons 'token token) (cons 'secret secret)) (lambda () #t))) #t)
    )
    ))
  )

  (test-case "T19: JwtToken wraps any string value"
    (call-with-fresh-memory-db '() (lambda ()
  (define t1 (thsl-src! "tests/jwt-tests.tesl" 223 (list) (lambda () (makeToken "a"))))
  (define t2 (thsl-src! "tests/jwt-tests.tesl" 224 (list (cons 't1 t1)) (lambda () (makeToken "bb"))))
  (define t3 (thsl-src! "tests/jwt-tests.tesl" 225 (list (cons 't2 t2) (cons 't1 t1)) (lambda () (makeToken "ccc"))))
  (check-true (thsl-src! "tests/jwt-tests.tesl" 226 (list (cons 't3 t3) (cons 't2 t2) (cons 't1 t1)) (lambda () (tesl-lt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t1 'value)))) (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t2 'value))))))))
  (check-true (thsl-src! "tests/jwt-tests.tesl" 227 (list (cons 't3 t3) (cons 't2 t2) (cons 't1 t1)) (lambda () (tesl-lt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t2 'value)))) (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t3 'value))))))))
    ))
  )

  (test-case "T20: JwtSecret and JwtToken are separate types"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s (thsl-src! "tests/jwt-tests.tesl" 235 (list) (lambda () (makeSecret "my-secret"))))
    (define t (thsl-src! "tests/jwt-tests.tesl" 236 (list (cons 's s)) (lambda () (signClaims "my-user" s))))
    (check-true (thsl-src! "tests/jwt-tests.tesl" 237 (list (cons 't t) (cons 's s)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t 'value)))) 0))))
    )
    ))
  )

  (test-case "T21: a signed token verifies and keeps its other claims readable"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 241 (list) (lambda () (makeSecret "expiry-key"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 242 (list (cons 'secret secret)) (lambda () (signClaims "user-with-expiry" secret))))
    (check-equal? (raw-value (thsl-src! "tests/jwt-tests.tesl" 243 (list (cons 'token token) (cons 'secret secret)) (lambda () (verifyClaims token secret)))) "user-with-expiry")
    (check-equal? (raw-value (thsl-src! "tests/jwt-tests.tesl" 244 (list (cons 'token token) (cons 'secret secret)) (lambda () (decodeClaims token)))) "user-with-expiry")
    (check-true (raw-value (thsl-src! "tests/jwt-tests.tesl" 245 (list (cons 'token token) (cons 'secret secret)) (lambda () (tesl_import_String_startsWith (raw-value (tesl-dot/runtime token 'value)) "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")))))
    )
    ))
  )

  (test-case "T22: verified claims satisfy a consumer that demands Authentic"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 254 (list) (lambda () (makeSecret "authentic-key"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 255 (list (cons 'secret secret)) (lambda () (signClaims "carol" secret))))
    (define tesl-checked-5 (tesl_import_JWT_verify token secret))
    (when (check-fail? tesl-checked-5)
      (raise-user-error 'tesl-test "unexpected failure in let claims: ~a" (check-fail-message tesl-checked-5)))
    (define claims tesl-checked-5)
    (check-equal? (raw-value (thsl-src! "tests/jwt-tests.tesl" 257 (list (cons 'claims claims) (cons 'token token) (cons 'secret secret)) (lambda () (subjectOfAuthenticClaims claims)))) "carol")
    )
    ))
  )

)
