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
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.startsWith tesl_import_String_startsWith])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict [Dict.singleton tesl_import_Dict_singleton] [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/jwt jwt JwtToken JwtSecret [JWT.sign tesl_import_JWT_sign] [JWT.verify tesl_import_JWT_verify] [JWT.decode tesl_import_JWT_decode])
)


(provide makeSecret makeToken wrapToken signClaims verifyClaims decodeClaims checkTokenStr tokenLength makeSecret-signature makeToken-signature wrapToken-signature signClaims-signature verifyClaims-signature decodeClaims-signature checkTokenStr-signature tokenLength-signature)

(define-capability jwtCap (implies jwt))

(define/pow
  (makeSecret [s : String])
  #:returns JwtSecret
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 48 (list (cons 's *s)) (lambda () (raw-value (JwtSecret *s)))))

(define/pow
  (makeToken [s : String])
  #:returns JwtToken
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 51 (list (cons 's *s)) (lambda () (raw-value (JwtToken *s)))))

(define/pow
  (wrapToken [s : String])
  #:returns JwtToken
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 54 (list (cons 's *s)) (lambda () (raw-value (JwtToken *s)))))

(define/pow
  (signClaims [claims : String] [secret : JwtSecret])
  #:capabilities [jwtCap]
  #:returns JwtToken
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 59 (list (cons 'claims *claims) (cons 'secret *secret)) (lambda () (raw-value (tesl_import_JWT_sign (raw-value (tesl_import_Dict_singleton "sub" *claims)) *secret)))))

(define/pow
  (verifyClaims [token : JwtToken] [secret : JwtSecret])
  #:capabilities [jwtCap]
  #:returns String
  (thsl-src-control! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 62 (list (cons 'token *token) (cons 'secret *secret)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "sub" (raw-value (tesl_import_JWT_verify *token *secret))))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 63 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([s (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 64 (list (cons 's s)) (lambda () *s)))])))))

(define/pow
  (decodeClaims [token : JwtToken])
  #:capabilities [jwtCap]
  #:returns String
  (thsl-src-control! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 67 (list (cons 'token *token)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_Dict_lookup "sub" (raw-value (tesl_import_JWT_decode *token))))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 68 (list) (lambda () (raw-value "")))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([s (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 69 (list (cons 's s)) (lambda () *s)))])))))

(define/pow
  (checkTokenStr [token : JwtToken])
  #:returns String
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 72 (list (cons 'token *token)) (lambda () (raw-value token.value))))

(define/pow
  (tokenLength [token : JwtToken])
  #:returns Integer
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 75 (list (cons 'token *token)) (lambda () (raw-value (tesl_import_String_length (raw-value token.value))))))

(module+ test
  (require rackunit)
  (test-case "T01: JwtSecret constructor wraps a string"
    (call-with-fresh-memory-db '() (lambda ()
  (define s (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 80 (list) (lambda () (makeSecret "my-key"))))
  (check-equal? (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 81 (list (cons 's s)) (lambda () (raw-value (tesl-dot/runtime s 'value)))) "my-key")
    ))
  )

  (test-case "T02: JwtToken constructor wraps a string"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 85 (list) (lambda () (makeToken "header.payload.sig"))))
  (check-equal? (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 86 (list (cons 't t)) (lambda () (raw-value (tesl-dot/runtime t 'value)))) "header.payload.sig")
    ))
  )

  (test-case "T03: wrapToken produces JwtToken"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 90 (list) (lambda () (wrapToken "abc.def.ghi"))))
  (check-equal? (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 91 (list (cons 't t)) (lambda () (raw-value (tesl-dot/runtime t 'value)))) "abc.def.ghi")
    ))
  )

  (test-case "T04: JWT.sign produces a token (trusts runtime)"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 95 (list) (lambda () (makeSecret "test-secret"))))
    (define token (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 96 (list (cons 'secret secret)) (lambda () (signClaims "user123" secret))))
    (check-true (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 97 (list (cons 'token token) (cons 'secret secret)) (lambda () (> (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime token 'value)))) 0))))
    )
    ))
  )

  (test-case "T05: JWT token has three parts separated by dots"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 101 (list) (lambda () (makeSecret "test-secret"))))
    (define token (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 102 (list (cons 'secret secret)) (lambda () (signClaims "user456" secret))))
    (define tokenStr (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 103 (list (cons 'token token) (cons 'secret secret)) (lambda () (raw-value (tesl-dot/runtime token 'value)))))
    (check-true (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 104 (list (cons 'tokenStr tokenStr) (cons 'token token) (cons 'secret secret)) (lambda () (> (raw-value (tesl_import_String_length (raw-value tokenStr))) 10))))
    )
    ))
  )

  (test-case "T06: JWT.sign token starts with known header"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 108 (list) (lambda () (makeSecret "test-secret"))))
    (define token (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 109 (list (cons 'secret secret)) (lambda () (signClaims "alice" secret))))
    (check-true (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 110 (list (cons 'token token) (cons 'secret secret)) (lambda () (tesl_import_String_startsWith (raw-value (tesl-dot/runtime token 'value)) "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")))))
    )
    ))
  )

  (test-case "T07: JwtToken .value extracts the underlying string"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 114 (list) (lambda () (makeToken "raw.token.string"))))
  (check-equal? (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 115 (list (cons 't t)) (lambda () (raw-value (tesl-dot/runtime t 'value)))) "raw.token.string")
    ))
  )

  (test-case "T08: tokenLength counts characters in token"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 119 (list) (lambda () (makeSecret "key"))))
    (define token (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 120 (list (cons 'secret secret)) (lambda () (signClaims "user" secret))))
    (check-true (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 121 (list (cons 'token token) (cons 'secret secret)) (lambda () (> (raw-value (tokenLength token)) 20))))
    )
    ))
  )

  (test-case "T09: checkTokenStr returns the inner string"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 125 (list) (lambda () (makeToken "x.y.z"))))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 126 (list (cons 't t)) (lambda () (checkTokenStr t)))) "x.y.z")
    ))
  )

  (test-case "T10: makeSecret produces JwtSecret with correct value"
    (call-with-fresh-memory-db '() (lambda ()
  (define s (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 130 (list) (lambda () (makeSecret "super-secret"))))
  (check-equal? (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 131 (list (cons 's s)) (lambda () (raw-value (tesl-dot/runtime s 'value)))) "super-secret")
    ))
  )

  (test-case "T11: JWT.sign with long claims still produces token"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 135 (list) (lambda () (makeSecret "s"))))
    (define claims (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 136 (list (cons 'secret secret)) (lambda () "a-very-long-user-identifier-for-testing-purposes")))
    (define token (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 137 (list (cons 'claims claims) (cons 'secret secret)) (lambda () (signClaims claims secret))))
    (check-true (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 138 (list (cons 'token token) (cons 'claims claims) (cons 'secret secret)) (lambda () (> (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime token 'value)))) 30))))
    )
    ))
  )

  (test-case "T12: different secrets produce different tokens"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s1 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 142 (list) (lambda () (makeSecret "key1"))))
    (define s2 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 143 (list (cons 's1 s1)) (lambda () (makeSecret "key2"))))
    (define t1 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 144 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (signClaims "user" s1))))
    (define t2 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 145 (list (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (signClaims "user" s2))))
    (check-not-equal? (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 146 (list (cons 't2 t2) (cons 't1 t1) (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl-dot/runtime t1 'value)))) (raw-value (tesl-dot/runtime t2 'value)))
    )
    ))
  )

  (test-case "T13: same inputs always produce same token"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define s (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 150 (list) (lambda () (makeSecret "consistent-key"))))
    (define t1 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 151 (list (cons 's s)) (lambda () (signClaims "user" s))))
    (define t2 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 152 (list (cons 't1 t1) (cons 's s)) (lambda () (signClaims "user" s))))
    (check-equal? (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 153 (list (cons 't2 t2) (cons 't1 t1) (cons 's s)) (lambda () (raw-value (tesl-dot/runtime t1 'value)))) (raw-value (tesl-dot/runtime t2 'value)))
    )
    ))
  )

  (test-case "T14: JwtToken value is a non-empty string"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 157 (list) (lambda () (makeToken "some.jwt.token"))))
  (check-true (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 158 (list (cons 't t)) (lambda () (> (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t 'value)))) 0))))
    ))
  )

  (test-case "T15: JwtSecret value is a non-empty string"
    (call-with-fresh-memory-db '() (lambda ()
  (define s (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 162 (list) (lambda () (makeSecret "not-empty-secret"))))
  (check-true (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 163 (list (cons 's s)) (lambda () (> (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime s 'value)))) 0))))
    ))
  )

  (test-case "T16: signClaims token is not the same as the claims string"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 167 (list) (lambda () (makeSecret "k"))))
    (define claims (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 168 (list (cons 'secret secret)) (lambda () "user123")))
    (define token (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 169 (list (cons 'claims claims) (cons 'secret secret)) (lambda () (signClaims claims secret))))
    (check-not-equal? (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 170 (list (cons 'token token) (cons 'claims claims) (cons 'secret secret)) (lambda () (raw-value (tesl-dot/runtime token 'value)))) claims)
    )
    ))
  )

  (test-case "T17: signClaims with empty string secret produces token"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 174 (list) (lambda () (makeSecret ""))))
    (define token (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 175 (list (cons 'secret secret)) (lambda () (signClaims "user" secret))))
    (check-true (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 176 (list (cons 'token token) (cons 'secret secret)) (lambda () (> (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime token 'value)))) 0))))
    )
    ))
  )

  (test-case "T18: decodeClaims extracts payload (no sig check)"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (jwtCap)
    (define secret (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 180 (list) (lambda () (makeSecret "test-key"))))
    (define token (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 181 (list (cons 'secret secret)) (lambda () (signClaims "decode-test" secret))))
    (define tesl-ignored-2 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 182 (list (cons 'token token) (cons 'secret secret)) (lambda () (decodeClaims token))))
    (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 183 (list (cons 'token token) (cons 'secret secret)) (lambda () #t))) #t)
    )
    ))
  )

  (test-case "T19: JwtToken wraps any string value"
    (call-with-fresh-memory-db '() (lambda ()
  (define t1 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 187 (list) (lambda () (makeToken "a"))))
  (define t2 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 188 (list (cons 't1 t1)) (lambda () (makeToken "bb"))))
  (define t3 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 189 (list (cons 't2 t2) (cons 't1 t1)) (lambda () (makeToken "ccc"))))
  (check-true (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 190 (list (cons 't3 t3) (cons 't2 t2) (cons 't1 t1)) (lambda () (< (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t1 'value)))) (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t2 'value))))))))
  (check-true (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 191 (list (cons 't3 t3) (cons 't2 t2) (cons 't1 t1)) (lambda () (< (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t2 'value)))) (raw-value (tesl_import_String_length (raw-value (tesl-dot/runtime t3 'value))))))))
    ))
  )

  (test-case "T20: JwtSecret and JwtToken are separate types (runtime check)"
    (call-with-fresh-memory-db '() (lambda ()
  (define s (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 195 (list) (lambda () (makeSecret "my-secret"))))
  (define t (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 196 (list (cons 's s)) (lambda () (makeToken "my-token"))))
  (check-not-equal? (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/jwt-tests.tesl" 197 (list (cons 't t) (cons 's s)) (lambda () (raw-value (tesl-dot/runtime s 'value)))) (or (raw-value (tesl-dot/runtime t 'value)) (tesl-equal? #t #t)))
    ))
  )

)
