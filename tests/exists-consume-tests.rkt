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
  (only-in tesl/tesl/prelude Bool Int String)
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.startsWith tesl_import_String_startsWith])
  (only-in tesl/tesl/random random)
  (only-in tesl/tesl/id generatePrefixedId)
)


(provide )

(define IsTokenId 'IsTokenId)

(define-checker
  (checkTokenId [s : String])
  #:returns [s : String ::: (IsTokenId s)]
  (thsl-src! "tests/exists-consume-tests.tesl" 23 (list (cons 's *s)) (lambda () (if (> (raw-value (tesl_import_String_length *s)) 3) (accept (IsTokenId s) #:value *s) (reject "bad token" #:http-code 400)))))

(define-capability idGen (implies random))

(define/pow
  (generateToken)
  #:capabilities [idGen]
  #:returns (Exists [tokenId : String] [tokenId : String ::: (IsTokenId tokenId)])
  (thsl-src! "tests/exists-consume-tests.tesl" 32 (list) (lambda () (let ([tokenId (generatePrefixedId "tok")]) (let/check ([tesl-checked-0 (checkTokenId tokenId)]) (let ([validated tesl-checked-0]) (pack ([tokenId]) validated)))))))

(module+ test
  (require rackunit)
  (test-case "exists result consumed as its underlying String type"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (idGen)
    (define tok (thsl-src! "tests/exists-consume-tests.tesl" 38 (list) (lambda () (generateToken))))
    (check-true (thsl-src! "tests/exists-consume-tests.tesl" 39 (list (cons 'tok tok)) (lambda () (> (raw-value (tesl_import_String_length (raw-value tok))) 3))))
    (check-true (raw-value (thsl-src! "tests/exists-consume-tests.tesl" 40 (list (cons 'tok tok)) (lambda () (tesl_import_String_startsWith (raw-value tok) "tok")))))
    (check-not-equal? (thsl-src! "tests/exists-consume-tests.tesl" 41 (list (cons 'tok tok)) (lambda () (format "wrapped:~a" (tesl-display-val tok)))) "wrapped:")
    )
    ))
  )

)
