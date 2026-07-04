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
  (only-in tesl/tesl/prelude String)
  (only-in tesl/tesl/jwt jwt JwtToken JwtSecret [JWT.sign tesl_import_JWT_sign] [JWT.verify tesl_import_JWT_verify] [JWT.decode tesl_import_JWT_decode])
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
  (only-in tesl/tesl/dict [Dict.singleton tesl_import_Dict_singleton] [Dict.lookup tesl_import_Dict_lookup])
)


(provide makeLoginToken getUserFromToken decodeToken wrapAndVerify makeLoginToken-signature getUserFromToken-signature decodeToken-signature wrapAndVerify-signature)

(define-capability authCap (implies jwt))

(define/pow
  (makeLoginToken [userId : String] [secret : JwtSecret])
  #:capabilities [authCap]
  #:returns JwtToken
  (thsl-src! "example/learn/lesson57-jwt.tesl" 92 (list (cons 'userId *userId) (cons 'secret *secret)) (lambda () (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_singleton "sub" *userId)) *secret)))))

(define/pow
  (getUserFromToken [token : JwtToken] [secret : JwtSecret])
  #:capabilities [authCap]
  #:returns String
  (thsl-src-control! "example/learn/lesson57-jwt.tesl" 104 (list (cons 'token *token) (cons 'secret *secret)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "sub" (raw-value (tesl_import_JWT_verify *token *secret))))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson57-jwt.tesl" 105 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson57-jwt.tesl" 106 (list (cons 'userId userId)) (lambda () *userId)))])))))

(define/pow
  (decodeToken [token : JwtToken])
  #:capabilities [authCap]
  #:returns String
  (thsl-src-control! "example/learn/lesson57-jwt.tesl" 118 (list (cons 'token *token)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_Dict_lookup "sub" (raw-value (tesl_import_JWT_decode *token))))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/learn/lesson57-jwt.tesl" 119 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/learn/lesson57-jwt.tesl" 120 (list (cons 'userId userId)) (lambda () *userId)))])))))

(define/pow
  (wrapAndVerify [rawToken : String] [rawSecret : String])
  #:capabilities [authCap]
  #:returns String
  (let ([token (thsl-src! "example/learn/lesson57-jwt.tesl" 133 (list (cons 'rawToken *rawToken) (cons 'rawSecret *rawSecret)) (lambda () (raw-value (JwtToken *rawToken))))]) (let ([secret (thsl-src! "example/learn/lesson57-jwt.tesl" 134 (list (cons 'token *token) (cons 'rawToken *rawToken) (cons 'rawSecret *rawSecret)) (lambda () (raw-value (JwtSecret *rawSecret))))]) (thsl-src-control! "example/learn/lesson57-jwt.tesl" 135 (list (cons 'secret *secret) (cons 'token *token) (cons 'rawToken *rawToken) (cons 'rawSecret *rawSecret)) (lambda () (let ([tesl-case-2 (raw-value (tesl_import_Dict_lookup "sub" (raw-value (tesl_import_JWT_verify (raw-value token) (raw-value secret)))))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "example/learn/lesson57-jwt.tesl" 136 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "example/learn/lesson57-jwt.tesl" 137 (list (cons 'userId userId)) (lambda () *userId)))])))))))

(module+ test
  (require rackunit)
  (test-case "makeLoginToken produces a 36+ character JwtToken"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 181 (list) (lambda () (raw-value (JwtSecret "lesson57-test-key")))))
    (define token (thsl-src! "example/learn/lesson57-jwt.tesl" 182 (list (cons 'secret secret)) (lambda () (makeLoginToken "user:alice" secret))))
    (check-true (thsl-src! "example/learn/lesson57-jwt.tesl" 183 (list (cons 'token token) (cons 'secret secret)) (lambda () (> (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime token 'value)))) 36))))
    )
    ))
  )

  (test-case "JwtToken.value retrieves the inner string"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw (thsl-src! "example/learn/lesson57-jwt.tesl" 187 (list) (lambda () "eyJhbGciOiJIUzI1NiJ9.payload.sig")))
  (define token (thsl-src! "example/learn/lesson57-jwt.tesl" 188 (list (cons 'raw raw)) (lambda () (raw-value (JwtToken (raw-value raw))))))
  (check-equal? (thsl-src! "example/learn/lesson57-jwt.tesl" 189 (list (cons 'token token) (cons 'raw raw)) (lambda () (raw-value (tesl-dot/runtime token 'value)))) raw)
    ))
  )

  (test-case "JwtSecret.value retrieves the inner key"
    (call-with-fresh-memory-db '() (lambda ()
  (define key (thsl-src! "example/learn/lesson57-jwt.tesl" 193 (list) (lambda () "my-signing-key-2025")))
  (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 194 (list (cons 'key key)) (lambda () (raw-value (JwtSecret (raw-value key))))))
  (check-equal? (thsl-src! "example/learn/lesson57-jwt.tesl" 195 (list (cons 'secret secret) (cons 'key key)) (lambda () (raw-value (tesl-dot/runtime secret 'value)))) key)
    ))
  )

  (test-case "different secrets produce different tokens"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define s1 (thsl-src! "example/learn/lesson57-jwt.tesl" 199 (list) (lambda () (raw-value (JwtSecret "key-alpha")))))
    (define s2 (thsl-src! "example/learn/lesson57-jwt.tesl" 200 (list (cons 's1 s1)) (lambda () (raw-value (JwtSecret "key-beta")))))
    (define t1 (thsl-src! "example/learn/lesson57-jwt.tesl" 201 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (makeLoginToken "user" s1))))
    (define t2 (thsl-src! "example/learn/lesson57-jwt.tesl" 202 (list (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (makeLoginToken "user" s2))))
    (check-not-equal? (thsl-src! "example/learn/lesson57-jwt.tesl" 203 (list (cons 't2 t2) (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl-dot/runtime t1 'value)))) (raw-value (tesl-dot/runtime t2 'value)))
    )
    ))
  )

  (test-case "same inputs always produce the same token (deterministic)"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 207 (list) (lambda () (raw-value (JwtSecret "stable-key")))))
    (define t1 (thsl-src! "example/learn/lesson57-jwt.tesl" 208 (list (cons 'secret secret)) (lambda () (makeLoginToken "user:123" secret))))
    (define t2 (thsl-src! "example/learn/lesson57-jwt.tesl" 209 (list (cons 't1 t1) (cons 'secret secret)) (lambda () (makeLoginToken "user:123" secret))))
    (check-equal? (thsl-src! "example/learn/lesson57-jwt.tesl" 210 (list (cons 't2 t2) (cons 't1 t1) (cons 'secret secret)) (lambda () (raw-value (tesl-dot/runtime t1 'value)))) (raw-value (tesl-dot/runtime t2 'value)))
    )
    ))
  )

  (test-case "different claims produce different tokens"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 214 (list) (lambda () (raw-value (JwtSecret "same-secret")))))
    (define t1 (thsl-src! "example/learn/lesson57-jwt.tesl" 215 (list (cons 'secret secret)) (lambda () (makeLoginToken "alice" secret))))
    (define t2 (thsl-src! "example/learn/lesson57-jwt.tesl" 216 (list (cons 't1 t1) (cons 'secret secret)) (lambda () (makeLoginToken "bob" secret))))
    (check-not-equal? (thsl-src! "example/learn/lesson57-jwt.tesl" 217 (list (cons 't2 t2) (cons 't1 t1) (cons 'secret secret)) (lambda () (raw-value (tesl-dot/runtime t1 'value)))) (raw-value (tesl-dot/runtime t2 'value)))
    )
    ))
  )

  (test-case "getUserFromToken round-trip: verify recovers claims"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 221 (list) (lambda () (raw-value (JwtSecret "roundtrip-key")))))
    (define token (thsl-src! "example/learn/lesson57-jwt.tesl" 222 (list (cons 'secret secret)) (lambda () (makeLoginToken "user:42" secret))))
    (define result (thsl-src! "example/learn/lesson57-jwt.tesl" 223 (list (cons 'token token) (cons 'secret secret)) (lambda () (getUserFromToken token secret))))
    (check-true (thsl-src! "example/learn/lesson57-jwt.tesl" 224 (list (cons 'result result) (cons 'token token) (cons 'secret secret)) (lambda () (> (raw-value (tesl_import_String_length (raw-value result))) 0))))
    )
    ))
  )

  (test-case "decodeToken extracts payload without verification"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 228 (list) (lambda () (raw-value (JwtSecret "decode-key")))))
    (define token (thsl-src! "example/learn/lesson57-jwt.tesl" 229 (list (cons 'secret secret)) (lambda () (makeLoginToken "decode-user" secret))))
    (define result (thsl-src! "example/learn/lesson57-jwt.tesl" 230 (list (cons 'token token) (cons 'secret secret)) (lambda () (decodeToken token))))
    (check-true (thsl-src! "example/learn/lesson57-jwt.tesl" 231 (list (cons 'result result) (cons 'token token) (cons 'secret secret)) (lambda () (> (raw-value (tesl_import_String_length (raw-value result))) 0))))
    )
    ))
  )

  (test-case "wrapAndVerify: wrap raw strings and verify"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 235 (list) (lambda () (raw-value (JwtSecret "wrap-test-key")))))
    (define token (thsl-src! "example/learn/lesson57-jwt.tesl" 236 (list (cons 'secret secret)) (lambda () (makeLoginToken "wrapped-user" secret))))
    (define result (thsl-src! "example/learn/lesson57-jwt.tesl" 237 (list (cons 'token token) (cons 'secret secret)) (lambda () (wrapAndVerify (raw-value (tesl-dot/runtime token 'value)) (raw-value (tesl-dot/runtime secret 'value))))))
    (check-true (thsl-src! "example/learn/lesson57-jwt.tesl" 238 (list (cons 'result result) (cons 'token token) (cons 'secret secret)) (lambda () (> (raw-value (tesl_import_String_length (raw-value result))) 0))))
    )
    ))
  )

  (test-case "token length grows with longer claims"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 242 (list) (lambda () (raw-value (JwtSecret "length-test")))))
    (define short (thsl-src! "example/learn/lesson57-jwt.tesl" 243 (list (cons 'secret secret)) (lambda () (makeLoginToken "u" secret))))
    (define long (thsl-src! "example/learn/lesson57-jwt.tesl" 244 (list (cons 'short short) (cons 'secret secret)) (lambda () (makeLoginToken "user:with-a-very-long-id-value-here-123456789" secret))))
    (check-true (thsl-src! "example/learn/lesson57-jwt.tesl" 245 (list (cons 'long long) (cons 'short short) (cons 'secret secret)) (lambda () (> (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime long 'value)))) (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime short 'value))))))))
    )
    ))
  )

  (test-case "signing with a long secret works"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define longKey (thsl-src! "example/learn/lesson57-jwt.tesl" 249 (list) (lambda () "a-very-long-secret-key-that-is-at-least-64-characters-long-abcdefgh")))
    (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 250 (list (cons 'longKey longKey)) (lambda () (raw-value (JwtSecret (raw-value longKey))))))
    (define token (thsl-src! "example/learn/lesson57-jwt.tesl" 251 (list (cons 'secret secret) (cons 'longKey longKey)) (lambda () (makeLoginToken "user" secret))))
    (check-true (thsl-src! "example/learn/lesson57-jwt.tesl" 252 (list (cons 'token token) (cons 'secret secret) (cons 'longKey longKey)) (lambda () (> (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime token 'value)))) 0))))
    )
    ))
  )

  (test-case "sequential sign-verify pairs work independently"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define s1 (thsl-src! "example/learn/lesson57-jwt.tesl" 256 (list) (lambda () (raw-value (JwtSecret "seq-key-1")))))
    (define s2 (thsl-src! "example/learn/lesson57-jwt.tesl" 257 (list (cons 's1 s1)) (lambda () (raw-value (JwtSecret "seq-key-2")))))
    (define t1 (thsl-src! "example/learn/lesson57-jwt.tesl" 258 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (makeLoginToken "user1" s1))))
    (define t2 (thsl-src! "example/learn/lesson57-jwt.tesl" 259 (list (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (makeLoginToken "user2" s2))))
    (define r1 (thsl-src! "example/learn/lesson57-jwt.tesl" 260 (list (cons 't2 t2) (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (getUserFromToken t1 s1))))
    (define r2 (thsl-src! "example/learn/lesson57-jwt.tesl" 261 (list (cons 'r1 r1) (cons 't2 t2) (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (getUserFromToken t2 s2))))
    (check-true (thsl-src! "example/learn/lesson57-jwt.tesl" 262 (list (cons 'r2 r2) (cons 'r1 r1) (cons 't2 t2) (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (> (raw-value (tesl_import_String_length (raw-value r1))) 0))))
    (check-true (thsl-src! "example/learn/lesson57-jwt.tesl" 263 (list (cons 'r2 r2) (cons 'r1 r1) (cons 't2 t2) (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (> (raw-value (tesl_import_String_length (raw-value r2))) 0))))
    )
    ))
  )

)
