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
  (only-in tesl/tesl/jwt jwt JwtToken JwtSecret [JWT.sign tesl_import_JWT_sign] [JWT.verify tesl_import_JWT_verify] [JWT.decode tesl_import_JWT_decode] Authentic)
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
  (only-in tesl/tesl/dict Dict [Dict.singleton tesl_import_Dict_singleton] [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/time time)
)


(provide makeLoginToken getUserFromToken subjectOfVerifiedClaims decodeToken wrapAndVerify makeLoginToken-signature getUserFromToken-signature subjectOfVerifiedClaims-signature decodeToken-signature wrapAndVerify-signature)

(define-capability authCap (implies jwt time))

(define/pow
  (makeLoginToken [userId : String] [secret : JwtSecret])
  #:capabilities [authCap]
  #:returns JwtToken
  (thsl-src! "example/learn/lesson57-jwt.tesl" 108 (list (cons 'userId *userId) (cons 'secret *secret)) (lambda () (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_singleton "sub" *userId)) *secret)))))

(define/pow
  (getUserFromToken [token : JwtToken] [secret : JwtSecret])
  #:capabilities [authCap]
  #:returns String
  (thsl-src! "example/learn/lesson57-jwt.tesl" 133 (list (cons 'token *token) (cons 'secret *secret)) (lambda () (let/check ([tesl-checked-0 (tesl_import_JWT_verify token secret)]) (let ([claims tesl-checked-0]) (let ([tesl-case-1 (raw-value (tesl_import_Dict_lookup "sub" claims))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/learn/lesson57-jwt.tesl" 135 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/learn/lesson57-jwt.tesl" 136 (list (cons 'userId userId)) (lambda () *userId)))])))))))

(define/pow
  (subjectOfVerifiedClaims [claims : (Dict String String) ::: (Authentic claims)])
  #:returns String
  (thsl-src-control! "example/learn/lesson57-jwt.tesl" 153 (list (cons 'claims *claims)) (lambda () (let ([tesl-case-2 (raw-value (tesl_import_Dict_lookup "sub" *claims))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "example/learn/lesson57-jwt.tesl" 154 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "example/learn/lesson57-jwt.tesl" 155 (list (cons 'userId userId)) (lambda () *userId)))])))))

(define/pow
  (decodeToken [token : JwtToken])
  #:capabilities [authCap]
  #:returns String
  (thsl-src-control! "example/learn/lesson57-jwt.tesl" 167 (list (cons 'token *token)) (lambda () (let ([tesl-case-3 (raw-value (tesl_import_Dict_lookup "sub" (raw-value (tesl_import_JWT_decode *token))))]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "example/learn/lesson57-jwt.tesl" 168 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "example/learn/lesson57-jwt.tesl" 169 (list (cons 'userId userId)) (lambda () *userId)))])))))

(define/pow
  (wrapAndVerify [rawToken : String] [rawSecret : String])
  #:capabilities [authCap]
  #:returns String
  (thsl-src! "example/learn/lesson57-jwt.tesl" 187 (list (cons 'rawToken *rawToken) (cons 'rawSecret *rawSecret)) (lambda () (let ([token (raw-value (JwtToken *rawToken))]) (let ([secret (raw-value (JwtSecret *rawSecret))]) (let/check ([tesl-checked-4 (tesl_import_JWT_verify token secret)]) (let ([claims tesl-checked-4]) (let ([tesl-case-5 (raw-value (tesl_import_Dict_lookup "sub" claims))]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Nothing)) (thsl-src! "example/learn/lesson57-jwt.tesl" 191 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Something)) (let ([userId (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "example/learn/lesson57-jwt.tesl" 192 (list (cons 'userId userId)) (lambda () *userId)))])))))))))

(module+ test
  (require rackunit)
  (test-case "makeLoginToken produces a 36+ character JwtToken"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 236 (list) (lambda () (raw-value (JwtSecret "lesson57-test-key")))))
    (define token (thsl-src! "example/learn/lesson57-jwt.tesl" 237 (list (cons 'secret secret)) (lambda () (makeLoginToken "user:alice" secret))))
    (check-true (thsl-src! "example/learn/lesson57-jwt.tesl" 238 (list (cons 'token token) (cons 'secret secret)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime token 'value)))) 36))))
    )
    ))
  )

  (test-case "JwtToken.value retrieves the inner string"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw (thsl-src! "example/learn/lesson57-jwt.tesl" 242 (list) (lambda () "eyJhbGciOiJIUzI1NiJ9.payload.sig")))
  (define token (thsl-src! "example/learn/lesson57-jwt.tesl" 243 (list (cons 'raw raw)) (lambda () (raw-value (JwtToken (raw-value raw))))))
  (check-equal? (thsl-src! "example/learn/lesson57-jwt.tesl" 244 (list (cons 'token token) (cons 'raw raw)) (lambda () (raw-value (tesl-dot/runtime token 'value)))) raw)
    ))
  )

  (test-case "JwtSecret carries its key faithfully without exposing it"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define key (thsl-src! "example/learn/lesson57-jwt.tesl" 252 (list) (lambda () "my-signing-key-2025")))
    (define a (thsl-src! "example/learn/lesson57-jwt.tesl" 253 (list (cons 'key key)) (lambda () (raw-value (JwtSecret (raw-value key))))))
    (define b (thsl-src! "example/learn/lesson57-jwt.tesl" 254 (list (cons 'a a) (cons 'key key)) (lambda () (raw-value (JwtSecret (raw-value key))))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson57-jwt.tesl" 255 (list (cons 'b b) (cons 'a a) (cons 'key key)) (lambda () a))) b)
    (define ta (thsl-src! "example/learn/lesson57-jwt.tesl" 256 (list (cons 'b b) (cons 'a a) (cons 'key key)) (lambda () (makeLoginToken "user" a))))
    (define tb (thsl-src! "example/learn/lesson57-jwt.tesl" 257 (list (cons 'ta ta) (cons 'b b) (cons 'a a) (cons 'key key)) (lambda () (makeLoginToken "user" b))))
    (check-equal? (thsl-src! "example/learn/lesson57-jwt.tesl" 258 (list (cons 'tb tb) (cons 'ta ta) (cons 'b b) (cons 'a a) (cons 'key key)) (lambda () (raw-value (tesl-dot/runtime ta 'value)))) (raw-value (tesl-dot/runtime tb 'value)))
    )
    ))
  )

  (test-case "different secrets produce different tokens"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define s1 (thsl-src! "example/learn/lesson57-jwt.tesl" 262 (list) (lambda () (raw-value (JwtSecret "key-alpha")))))
    (define s2 (thsl-src! "example/learn/lesson57-jwt.tesl" 263 (list (cons 's1 s1)) (lambda () (raw-value (JwtSecret "key-beta")))))
    (define t1 (thsl-src! "example/learn/lesson57-jwt.tesl" 264 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (makeLoginToken "user" s1))))
    (define t2 (thsl-src! "example/learn/lesson57-jwt.tesl" 265 (list (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (makeLoginToken "user" s2))))
    (check-not-equal? (thsl-src! "example/learn/lesson57-jwt.tesl" 266 (list (cons 't2 t2) (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl-dot/runtime t1 'value)))) (raw-value (tesl-dot/runtime t2 'value)))
    )
    ))
  )

  (test-case "same inputs always produce the same token (deterministic)"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 270 (list) (lambda () (raw-value (JwtSecret "stable-key")))))
    (define t1 (thsl-src! "example/learn/lesson57-jwt.tesl" 271 (list (cons 'secret secret)) (lambda () (makeLoginToken "user:123" secret))))
    (define t2 (thsl-src! "example/learn/lesson57-jwt.tesl" 272 (list (cons 't1 t1) (cons 'secret secret)) (lambda () (makeLoginToken "user:123" secret))))
    (check-equal? (thsl-src! "example/learn/lesson57-jwt.tesl" 273 (list (cons 't2 t2) (cons 't1 t1) (cons 'secret secret)) (lambda () (raw-value (tesl-dot/runtime t1 'value)))) (raw-value (tesl-dot/runtime t2 'value)))
    )
    ))
  )

  (test-case "different claims produce different tokens"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 277 (list) (lambda () (raw-value (JwtSecret "same-secret")))))
    (define t1 (thsl-src! "example/learn/lesson57-jwt.tesl" 278 (list (cons 'secret secret)) (lambda () (makeLoginToken "alice" secret))))
    (define t2 (thsl-src! "example/learn/lesson57-jwt.tesl" 279 (list (cons 't1 t1) (cons 'secret secret)) (lambda () (makeLoginToken "bob" secret))))
    (check-not-equal? (thsl-src! "example/learn/lesson57-jwt.tesl" 280 (list (cons 't2 t2) (cons 't1 t1) (cons 'secret secret)) (lambda () (raw-value (tesl-dot/runtime t1 'value)))) (raw-value (tesl-dot/runtime t2 'value)))
    )
    ))
  )

  (test-case "getUserFromToken round-trip: verify recovers claims"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 284 (list) (lambda () (raw-value (JwtSecret "roundtrip-key")))))
    (define token (thsl-src! "example/learn/lesson57-jwt.tesl" 285 (list (cons 'secret secret)) (lambda () (makeLoginToken "user:42" secret))))
    (define result (thsl-src! "example/learn/lesson57-jwt.tesl" 286 (list (cons 'token token) (cons 'secret secret)) (lambda () (getUserFromToken token secret))))
    (check-true (thsl-src! "example/learn/lesson57-jwt.tesl" 287 (list (cons 'result result) (cons 'token token) (cons 'secret secret)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value result))) 0))))
    )
    ))
  )

  (test-case "decodeToken extracts payload without verification"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 291 (list) (lambda () (raw-value (JwtSecret "decode-key")))))
    (define token (thsl-src! "example/learn/lesson57-jwt.tesl" 292 (list (cons 'secret secret)) (lambda () (makeLoginToken "decode-user" secret))))
    (define result (thsl-src! "example/learn/lesson57-jwt.tesl" 293 (list (cons 'token token) (cons 'secret secret)) (lambda () (decodeToken token))))
    (check-true (thsl-src! "example/learn/lesson57-jwt.tesl" 294 (list (cons 'result result) (cons 'token token) (cons 'secret secret)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value result))) 0))))
    )
    ))
  )

  (test-case "wrapAndVerify: wrap raw strings and verify"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define rawSecret (thsl-src! "example/learn/lesson57-jwt.tesl" 301 (list) (lambda () "wrap-test-key")))
    (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 302 (list (cons 'rawSecret rawSecret)) (lambda () (raw-value (JwtSecret (raw-value rawSecret))))))
    (define token (thsl-src! "example/learn/lesson57-jwt.tesl" 303 (list (cons 'secret secret) (cons 'rawSecret rawSecret)) (lambda () (makeLoginToken "wrapped-user" secret))))
    (define result (thsl-src! "example/learn/lesson57-jwt.tesl" 304 (list (cons 'token token) (cons 'secret secret) (cons 'rawSecret rawSecret)) (lambda () (wrapAndVerify (raw-value (tesl-dot/runtime token 'value)) rawSecret))))
    (check-true (thsl-src! "example/learn/lesson57-jwt.tesl" 305 (list (cons 'result result) (cons 'token token) (cons 'secret secret) (cons 'rawSecret rawSecret)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value result))) 0))))
    )
    ))
  )

  (test-case "token length grows with longer claims"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 309 (list) (lambda () (raw-value (JwtSecret "length-test")))))
    (define short (thsl-src! "example/learn/lesson57-jwt.tesl" 310 (list (cons 'secret secret)) (lambda () (makeLoginToken "u" secret))))
    (define long (thsl-src! "example/learn/lesson57-jwt.tesl" 311 (list (cons 'short short) (cons 'secret secret)) (lambda () (makeLoginToken "user:with-a-very-long-id-value-here-123456789" secret))))
    (check-true (thsl-src! "example/learn/lesson57-jwt.tesl" 312 (list (cons 'long long) (cons 'short short) (cons 'secret secret)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime long 'value)))) (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime short 'value))))))))
    )
    ))
  )

  (test-case "signing with a long secret works"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define longKey (thsl-src! "example/learn/lesson57-jwt.tesl" 316 (list) (lambda () "a-very-long-secret-key-that-is-at-least-64-characters-long-abcdefgh")))
    (define secret (thsl-src! "example/learn/lesson57-jwt.tesl" 317 (list (cons 'longKey longKey)) (lambda () (raw-value (JwtSecret (raw-value longKey))))))
    (define token (thsl-src! "example/learn/lesson57-jwt.tesl" 318 (list (cons 'secret secret) (cons 'longKey longKey)) (lambda () (makeLoginToken "user" secret))))
    (check-true (thsl-src! "example/learn/lesson57-jwt.tesl" 319 (list (cons 'token token) (cons 'secret secret) (cons 'longKey longKey)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime token 'value)))) 0))))
    )
    ))
  )

  (test-case "sequential sign-verify pairs work independently"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (authCap)
    (define s1 (thsl-src! "example/learn/lesson57-jwt.tesl" 323 (list) (lambda () (raw-value (JwtSecret "seq-key-1")))))
    (define s2 (thsl-src! "example/learn/lesson57-jwt.tesl" 324 (list (cons 's1 s1)) (lambda () (raw-value (JwtSecret "seq-key-2")))))
    (define t1 (thsl-src! "example/learn/lesson57-jwt.tesl" 325 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (makeLoginToken "user1" s1))))
    (define t2 (thsl-src! "example/learn/lesson57-jwt.tesl" 326 (list (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (makeLoginToken "user2" s2))))
    (define r1 (thsl-src! "example/learn/lesson57-jwt.tesl" 327 (list (cons 't2 t2) (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (getUserFromToken t1 s1))))
    (define r2 (thsl-src! "example/learn/lesson57-jwt.tesl" 328 (list (cons 'r1 r1) (cons 't2 t2) (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (getUserFromToken t2 s2))))
    (check-true (thsl-src! "example/learn/lesson57-jwt.tesl" 329 (list (cons 'r2 r2) (cons 'r1 r1) (cons 't2 t2) (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value r1))) 0))))
    (check-true (thsl-src! "example/learn/lesson57-jwt.tesl" 330 (list (cons 'r2 r2) (cons 'r1 r1) (cons 't2 t2) (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value r2))) 0))))
    )
    ))
  )

)
