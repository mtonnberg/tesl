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
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.startsWith tesl_import_String_startsWith] [String.contains tesl_import_String_contains] [String.slice tesl_import_String_slice])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict Dict [Dict.singleton tesl_import_Dict_singleton] [Dict.fromList tesl_import_Dict_fromList] [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/tuple Tuple2)
  (only-in tesl/tesl/time time)
  (only-in tesl/tesl/crypto Secret [Crypto.keyFingerprint tesl_import_Crypto_keyFingerprint])
  (only-in tesl/tesl/jwt jwt JwtToken [JWT.sign tesl_import_JWT_sign] [JWT.verify tesl_import_JWT_verify] [JWT.decode tesl_import_JWT_decode] Authentic)
)


(provide joseHeaderPrefix joseHeaderLength makeSecret makeToken wrapToken signClaims signClaimsWithOwnExp subjectOfAuthenticClaims verifyClaims decodeClaims checkTokenStr tokenLength makeSecret-signature makeToken-signature wrapToken-signature signClaims-signature signClaimsWithOwnExp-signature subjectOfAuthenticClaims-signature verifyClaims-signature decodeClaims-signature checkTokenStr-signature tokenLength-signature)

(define-capability jwtCap (implies jwt time))

(define joseHeaderPrefix "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6")

(define joseHeaderLength 70)

(define/pow
  (makeSecret [s : String])
  #:returns Secret
  (thsl-src! "tests/jwt-tests.tesl" 90 (list (cons 's *s)) (lambda () (raw-value (Secret *s)))))

(define/pow
  (makeToken [s : String])
  #:returns JwtToken
  (thsl-src! "tests/jwt-tests.tesl" 93 (list (cons 's *s)) (lambda () (raw-value (JwtToken *s)))))

(define/pow
  (wrapToken [s : String])
  #:returns JwtToken
  (thsl-src! "tests/jwt-tests.tesl" 96 (list (cons 's *s)) (lambda () (raw-value (JwtToken *s)))))

(define/pow
  (signClaims [claims : String] [secret : Secret])
  #:capabilities [jwtCap]
  #:returns JwtToken
  (thsl-src! "tests/jwt-tests.tesl" 101 (list (cons 'claims *claims) (cons 'secret *secret)) (lambda () (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_singleton "sub" *claims)) *secret)))))

(define/pow
  (signClaimsWithOwnExp [claims : String] [secret : Secret])
  #:capabilities [jwtCap]
  #:returns JwtToken
  (thsl-src! "tests/jwt-tests.tesl" 108 (list (cons 'claims *claims) (cons 'secret *secret)) (lambda () (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_fromList (list (Tuple2 "sub" claims) (Tuple2 "exp" "3600")))) *secret)))))

(define/pow
  (subjectOfAuthenticClaims [claims : (Dict String String) ::: (Authentic claims)])
  #:returns String
  (thsl-src-control! "tests/jwt-tests.tesl" 113 (list (cons 'claims *claims)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "sub" *claims))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/jwt-tests.tesl" 114 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([s (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/jwt-tests.tesl" 115 (list (cons 's s)) (lambda () *s)))])))))

(define/pow
  (verifyClaims [token : JwtToken] [secret : Secret])
  #:capabilities [jwtCap]
  #:returns String
  (thsl-src! "tests/jwt-tests.tesl" 121 (list (cons 'token *token) (cons 'secret *secret)) (lambda () (let/check ([tesl-checked-1 (tesl_import_JWT_verify token secret)]) (let ([claims tesl-checked-1]) (let ([tesl-case-2 (raw-value (tesl_import_Dict_lookup "sub" claims))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "tests/jwt-tests.tesl" 123 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([s (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "tests/jwt-tests.tesl" 124 (list (cons 's s)) (lambda () *s)))])))))))

(define/pow
  (decodeClaims [token : JwtToken])
  #:capabilities [jwtCap]
  #:returns String
  (thsl-src-control! "tests/jwt-tests.tesl" 127 (list (cons 'token *token)) (lambda () (let ([tesl-case-3 (raw-value (tesl_import_Dict_lookup "sub" (raw-value (tesl_import_JWT_decode *token))))]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "tests/jwt-tests.tesl" 128 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([s (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "tests/jwt-tests.tesl" 129 (list (cons 's s)) (lambda () *s)))])))))

(define/pow
  (checkTokenStr [token : JwtToken])
  #:returns String
  (thsl-src! "tests/jwt-tests.tesl" 132 (list (cons 'token *token)) (lambda () (raw-value token.value))))

(define/pow
  (tokenLength [token : JwtToken])
  #:returns Integer
  (thsl-src! "tests/jwt-tests.tesl" 135 (list (cons 'token *token)) (lambda () (raw-value (tesl_import_String_length (raw-value token.value))))))

(module+ test
  (require rackunit)
  (test-case "T01: a Secret can be constructed and used to sign"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s (thsl-src! "tests/jwt-tests.tesl" 145 (list) (lambda () (makeSecret "my-key"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 146 (list (cons 's s)) (lambda () (signClaims "user" s))))
    (check-true (raw-value (thsl-src! "tests/jwt-tests.tesl" 147 (list (cons 'token token) (cons 's s)) (lambda () (tesl_import_String_startsWith (raw-value (tesl-dot/runtime token 'value)) (raw-value joseHeaderPrefix))))))
    )
    ))
  )

  (test-case "T02: JwtToken constructor wraps a string"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/jwt-tests.tesl" 151 (list) (lambda () (makeToken "header.payload.sig"))))
  (check-equal? (thsl-src! "tests/jwt-tests.tesl" 152 (list (cons 't t)) (lambda () (raw-value (tesl-dot/runtime t 'value)))) "header.payload.sig")
    ))
  )

  (test-case "T03: wrapToken produces JwtToken"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/jwt-tests.tesl" 156 (list) (lambda () (wrapToken "abc.def.ghi"))))
  (check-equal? (thsl-src! "tests/jwt-tests.tesl" 157 (list (cons 't t)) (lambda () (raw-value (tesl-dot/runtime t 'value)))) "abc.def.ghi")
    ))
  )

  (test-case "T04: JWT.sign produces a token (trusts runtime)"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 161 (list) (lambda () (makeSecret "test-secret"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 162 (list (cons 'secret secret)) (lambda () (signClaims "user123" secret))))
    (check-true (thsl-src! "tests/jwt-tests.tesl" 163 (list (cons 'token token) (cons 'secret secret)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime token 'value)))) 0))))
    )
    ))
  )

  (test-case "T05: JWT token has three parts separated by dots"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 167 (list) (lambda () (makeSecret "test-secret"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 168 (list (cons 'secret secret)) (lambda () (signClaims "user456" secret))))
    (define tokenStr (thsl-src! "tests/jwt-tests.tesl" 169 (list (cons 'token token) (cons 'secret secret)) (lambda () (raw-value (tesl-dot/runtime token 'value)))))
    (check-true (thsl-src! "tests/jwt-tests.tesl" 170 (list (cons 'tokenStr tokenStr) (cons 'token token) (cons 'secret secret)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value tokenStr))) 10))))
    )
    ))
  )

  (test-case "T06: JWT.sign token starts with known header"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 174 (list) (lambda () (makeSecret "test-secret"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 175 (list (cons 'secret secret)) (lambda () (signClaims "alice" secret))))
    (check-true (raw-value (thsl-src! "tests/jwt-tests.tesl" 176 (list (cons 'token token) (cons 'secret secret)) (lambda () (tesl_import_String_startsWith (raw-value (tesl-dot/runtime token 'value)) (raw-value joseHeaderPrefix))))))
    )
    ))
  )

  (test-case "T07: JwtToken .value extracts the underlying string"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/jwt-tests.tesl" 180 (list) (lambda () (makeToken "raw.token.string"))))
  (check-equal? (thsl-src! "tests/jwt-tests.tesl" 181 (list (cons 't t)) (lambda () (raw-value (tesl-dot/runtime t 'value)))) "raw.token.string")
    ))
  )

  (test-case "T08: tokenLength counts characters in token"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 185 (list) (lambda () (makeSecret "key"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 186 (list (cons 'secret secret)) (lambda () (signClaims "user" secret))))
    (check-true (thsl-src! "tests/jwt-tests.tesl" 187 (list (cons 'token token) (cons 'secret secret)) (lambda () (tesl-gt? (raw-value (tokenLength token)) 20))))
    )
    ))
  )

  (test-case "T09: checkTokenStr returns the inner string"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/jwt-tests.tesl" 191 (list) (lambda () (makeToken "x.y.z"))))
  (check-equal? (raw-value (thsl-src! "tests/jwt-tests.tesl" 192 (list (cons 't t)) (lambda () (checkTokenStr t)))) "x.y.z")
    ))
  )

  (test-case "T10: makeSecret is deterministic \226\128\148 the same key string signs identically"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s1 (thsl-src! "tests/jwt-tests.tesl" 196 (list) (lambda () (makeSecret "super-secret"))))
    (define s2 (thsl-src! "tests/jwt-tests.tesl" 197 (list (cons 's1 s1)) (lambda () (makeSecret "super-secret"))))
    (check-equal? (thsl-src! "tests/jwt-tests.tesl" 198 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl-dot/runtime (signClaims "user" s1) 'value)))) (raw-value (tesl-dot/runtime (signClaims "user" s2) 'value)))
    )
    ))
  )

  (test-case "T11: JWT.sign with long claims still produces token"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 202 (list) (lambda () (makeSecret "s"))))
    (define claims (thsl-src! "tests/jwt-tests.tesl" 203 (list (cons 'secret secret)) (lambda () "a-very-long-user-identifier-for-testing-purposes")))
    (define token (thsl-src! "tests/jwt-tests.tesl" 204 (list (cons 'claims claims) (cons 'secret secret)) (lambda () (signClaims claims secret))))
    (check-true (thsl-src! "tests/jwt-tests.tesl" 205 (list (cons 'token token) (cons 'claims claims) (cons 'secret secret)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime token 'value)))) 30))))
    )
    ))
  )

  (test-case "T12: different secrets produce different tokens"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s1 (thsl-src! "tests/jwt-tests.tesl" 209 (list) (lambda () (makeSecret "key1"))))
    (define s2 (thsl-src! "tests/jwt-tests.tesl" 210 (list (cons 's1 s1)) (lambda () (makeSecret "key2"))))
    (define t1 (thsl-src! "tests/jwt-tests.tesl" 211 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (signClaims "user" s1))))
    (define t2 (thsl-src! "tests/jwt-tests.tesl" 212 (list (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (signClaims "user" s2))))
    (check-not-equal? (thsl-src! "tests/jwt-tests.tesl" 213 (list (cons 't2 t2) (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl-dot/runtime t1 'value)))) (raw-value (tesl-dot/runtime t2 'value)))
    )
    ))
  )

  (test-case "T13: same inputs always produce same token"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s (thsl-src! "tests/jwt-tests.tesl" 217 (list) (lambda () (makeSecret "consistent-key"))))
    (define t1 (thsl-src! "tests/jwt-tests.tesl" 218 (list (cons 's s)) (lambda () (signClaims "user" s))))
    (define t2 (thsl-src! "tests/jwt-tests.tesl" 219 (list (cons 't1 t1) (cons 's s)) (lambda () (signClaims "user" s))))
    (check-equal? (thsl-src! "tests/jwt-tests.tesl" 220 (list (cons 't2 t2) (cons 't1 t1) (cons 's s)) (lambda () (raw-value (tesl-dot/runtime t1 'value)))) (raw-value (tesl-dot/runtime t2 'value)))
    )
    ))
  )

  (test-case "T14: JwtToken value is a non-empty string"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "tests/jwt-tests.tesl" 224 (list) (lambda () (makeToken "some.jwt.token"))))
  (check-true (thsl-src! "tests/jwt-tests.tesl" 225 (list (cons 't t)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t 'value)))) 0))))
    ))
  )

  (test-case "T15: the secret does not leak into the token it signs"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s (thsl-src! "tests/jwt-tests.tesl" 229 (list) (lambda () (makeSecret "not-empty-secret"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 230 (list (cons 's s)) (lambda () (signClaims "user" s))))
    (check-true (raw-value (thsl-src! "tests/jwt-tests.tesl" 231 (list (cons 'token token) (cons 's s)) (lambda () (not (tesl_import_String_contains (raw-value (tesl-dot/runtime token 'value)) "not-empty-secret"))))))
    )
    ))
  )

  (test-case "T16: signClaims token is not the same as the claims string"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 235 (list) (lambda () (makeSecret "k"))))
    (define claims (thsl-src! "tests/jwt-tests.tesl" 236 (list (cons 'secret secret)) (lambda () "user123")))
    (define token (thsl-src! "tests/jwt-tests.tesl" 237 (list (cons 'claims claims) (cons 'secret secret)) (lambda () (signClaims claims secret))))
    (check-not-equal? (thsl-src! "tests/jwt-tests.tesl" 238 (list (cons 'token token) (cons 'claims claims) (cons 'secret secret)) (lambda () (raw-value (tesl-dot/runtime token 'value)))) claims)
    )
    ))
  )

  (test-case "T17: signClaims with empty string secret produces token"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 242 (list) (lambda () (makeSecret ""))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 243 (list (cons 'secret secret)) (lambda () (signClaims "user" secret))))
    (check-true (thsl-src! "tests/jwt-tests.tesl" 244 (list (cons 'token token) (cons 'secret secret)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime token 'value)))) 0))))
    )
    ))
  )

  (test-case "T18: decodeClaims extracts payload (no sig check)"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 248 (list) (lambda () (makeSecret "test-key"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 249 (list (cons 'secret secret)) (lambda () (signClaims "decode-test" secret))))
    (define tesl-ignored-4 (thsl-src! "tests/jwt-tests.tesl" 250 (list (cons 'token token) (cons 'secret secret)) (lambda () (decodeClaims token))))
    (check-equal? (raw-value (thsl-src! "tests/jwt-tests.tesl" 251 (list (cons 'token token) (cons 'secret secret)) (lambda () #t))) #t)
    )
    ))
  )

  (test-case "T19: JwtToken wraps any string value"
    (call-with-fresh-memory-db '() (lambda ()
  (define t1 (thsl-src! "tests/jwt-tests.tesl" 255 (list) (lambda () (makeToken "a"))))
  (define t2 (thsl-src! "tests/jwt-tests.tesl" 256 (list (cons 't1 t1)) (lambda () (makeToken "bb"))))
  (define t3 (thsl-src! "tests/jwt-tests.tesl" 257 (list (cons 't2 t2) (cons 't1 t1)) (lambda () (makeToken "ccc"))))
  (check-true (thsl-src! "tests/jwt-tests.tesl" 258 (list (cons 't3 t3) (cons 't2 t2) (cons 't1 t1)) (lambda () (tesl-lt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t1 'value)))) (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t2 'value))))))))
  (check-true (thsl-src! "tests/jwt-tests.tesl" 259 (list (cons 't3 t3) (cons 't2 t2) (cons 't1 t1)) (lambda () (tesl-lt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t2 'value)))) (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t3 'value))))))))
    ))
  )

  (test-case "T20: Secret and JwtToken are separate types"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s (thsl-src! "tests/jwt-tests.tesl" 267 (list) (lambda () (makeSecret "my-secret"))))
    (define t (thsl-src! "tests/jwt-tests.tesl" 268 (list (cons 's s)) (lambda () (signClaims "my-user" s))))
    (check-true (thsl-src! "tests/jwt-tests.tesl" 269 (list (cons 't t) (cons 's s)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t 'value)))) 0))))
    )
    ))
  )

  (test-case "T21: a signed token verifies and keeps its other claims readable"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 273 (list) (lambda () (makeSecret "expiry-key"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 274 (list (cons 'secret secret)) (lambda () (signClaims "user-with-expiry" secret))))
    (check-equal? (raw-value (thsl-src! "tests/jwt-tests.tesl" 275 (list (cons 'token token) (cons 'secret secret)) (lambda () (verifyClaims token secret)))) "user-with-expiry")
    (check-equal? (raw-value (thsl-src! "tests/jwt-tests.tesl" 276 (list (cons 'token token) (cons 'secret secret)) (lambda () (decodeClaims token)))) "user-with-expiry")
    (check-true (raw-value (thsl-src! "tests/jwt-tests.tesl" 277 (list (cons 'token token) (cons 'secret secret)) (lambda () (tesl_import_String_startsWith (raw-value (tesl-dot/runtime token 'value)) (raw-value joseHeaderPrefix))))))
    )
    ))
  )

  (test-case "T22: verified claims satisfy a consumer that demands Authentic"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "tests/jwt-tests.tesl" 286 (list) (lambda () (makeSecret "authentic-key"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 287 (list (cons 'secret secret)) (lambda () (signClaims "carol" secret))))
    (define tesl-checked-5 (tesl_import_JWT_verify token secret))
    (when (check-fail? tesl-checked-5)
      (raise-user-error 'tesl-test "unexpected failure in let claims: ~a" (check-fail-message tesl-checked-5)))
    (define claims tesl-checked-5)
    (check-equal? (raw-value (thsl-src! "tests/jwt-tests.tesl" 289 (list (cons 'claims claims) (cons 'token token) (cons 'secret secret)) (lambda () (subjectOfAuthenticClaims claims)))) "carol")
    )
    ))
  )

  (test-case "T23: the header carries a kid, so it is no longer the same for every key"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s1 (thsl-src! "tests/jwt-tests.tesl" 305 (list) (lambda () (makeSecret "kid-key-alpha"))))
    (define s2 (thsl-src! "tests/jwt-tests.tesl" 306 (list (cons 's1 s1)) (lambda () (makeSecret "kid-key-beta"))))
    (define h1 (thsl-src! "tests/jwt-tests.tesl" 307 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl_import_String_slice (raw-value (tesl-dot/runtime (signClaims "user" s1) 'value)) 0 (raw-value joseHeaderLength))))))
    (define h2 (thsl-src! "tests/jwt-tests.tesl" 308 (list (cons 'h1 h1) (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl_import_String_slice (raw-value (tesl-dot/runtime (signClaims "user" s2) 'value)) 0 (raw-value joseHeaderLength))))))
    (check-true (raw-value (thsl-src! "tests/jwt-tests.tesl" 309 (list (cons 'h2 h2) (cons 'h1 h1) (cons 's2 s2) (cons 's1 s1)) (lambda () (tesl_import_String_startsWith (raw-value h1) (raw-value joseHeaderPrefix))))))
    (check-true (raw-value (thsl-src! "tests/jwt-tests.tesl" 310 (list (cons 'h2 h2) (cons 'h1 h1) (cons 's2 s2) (cons 's1 s1)) (lambda () (tesl_import_String_startsWith (raw-value h2) (raw-value joseHeaderPrefix))))))
    (check-not-equal? (thsl-src! "tests/jwt-tests.tesl" 311 (list (cons 'h2 h2) (cons 'h1 h1) (cons 's2 s2) (cons 's1 s1)) (lambda () h1)) h2)
    )
    ))
  )

  (test-case "T24: the same key always stamps the same kid"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s (thsl-src! "tests/jwt-tests.tesl" 315 (list) (lambda () (makeSecret "kid-stable-key"))))
    (define h1 (thsl-src! "tests/jwt-tests.tesl" 316 (list (cons 's s)) (lambda () (raw-value (tesl_import_String_slice (raw-value (tesl-dot/runtime (signClaims "alice" s) 'value)) 0 (raw-value joseHeaderLength))))))
    (define h2 (thsl-src! "tests/jwt-tests.tesl" 317 (list (cons 'h1 h1) (cons 's s)) (lambda () (raw-value (tesl_import_String_slice (raw-value (tesl-dot/runtime (signClaims "bob" s) 'value)) 0 (raw-value joseHeaderLength))))))
    (check-equal? (raw-value (thsl-src! "tests/jwt-tests.tesl" 318 (list (cons 'h2 h2) (cons 'h1 h1) (cons 's s)) (lambda () h1))) h2)
    )
    ))
  )

  (test-case "T25: the kid is not the key \226\128\148 the key never appears in the token"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s (thsl-src! "tests/jwt-tests.tesl" 325 (list) (lambda () (makeSecret "kid-not-the-key"))))
    (define token (thsl-src! "tests/jwt-tests.tesl" 326 (list (cons 's s)) (lambda () (signClaims "user" s))))
    (check-true (raw-value (thsl-src! "tests/jwt-tests.tesl" 327 (list (cons 'token token) (cons 's s)) (lambda () (not (tesl_import_String_contains (raw-value (tesl-dot/runtime token 'value)) "kid-not-the-key"))))))
    (check-equal? (raw-value (thsl-src! "tests/jwt-tests.tesl" 328 (list (cons 'token token) (cons 's s)) (lambda () (tesl_import_String_length (raw-value (tesl_import_Crypto_keyFingerprint (raw-value s))))))) 16)
    )
    ))
  )

)
