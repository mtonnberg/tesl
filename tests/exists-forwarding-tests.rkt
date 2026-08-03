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
  (only-in tesl/tesl/prelude Bool String)
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.startsWith tesl_import_String_startsWith])
  (only-in tesl/tesl/random random)
  (only-in tesl/tesl/id generatePrefixedId)
)


(provide )

(define IsTokenId 'IsTokenId)

(define-checker
  (checkTokenId [s : String])
  #:returns [s : String ::: (IsTokenId s)]
  (thsl-src! "tests/exists-forwarding-tests.tesl" 32 (list (cons 's *s)) (lambda () (if (tesl-gt? (raw-value (tesl_import_String_length *s)) 3) (accept (IsTokenId s) #:value *s) (reject "bad token" #:http-code 400)))))

(define-capability idGen (implies random))

(define/pow
  (generateToken)
  #:capabilities [idGen]
  #:returns (Exists [tokenId : String] [tokenId : String ::: (IsTokenId tokenId)])
  (thsl-src! "tests/exists-forwarding-tests.tesl" 41 (list) (lambda () (let ([tokenId (generatePrefixedId "tok")]) (let/check ([tesl-checked-0 (checkTokenId tokenId)]) (let ([validated tesl-checked-0]) (pack ([tokenId]) validated)))))))

(define/pow
  (forwardToken)
  #:capabilities [idGen]
  #:returns (Exists [tokenId : String] [tokenId : String ::: (IsTokenId tokenId)])
  (thsl-src! "tests/exists-forwarding-tests.tesl" 49 (list) (lambda () (generateToken))))

(define/pow
  (forwardTokenViaLet)
  #:capabilities [idGen]
  #:returns (Exists [tokenId : String] [tokenId : String ::: (IsTokenId tokenId)])
  (let ([packed (thsl-src! "tests/exists-forwarding-tests.tesl" 54 (list) (lambda () (generateToken)))]) (thsl-src! "tests/exists-forwarding-tests.tesl" 55 (list (cons 'packed *packed)) (lambda () packed))))

(define/pow
  (forwardTokenBranching [flag : Boolean])
  #:capabilities [idGen]
  #:returns (Exists [tokenId : String] [tokenId : String ::: (IsTokenId tokenId)])
  (thsl-src! "tests/exists-forwarding-tests.tesl" 61 (list (cons 'flag *flag)) (lambda () (if *flag (generateToken) (forwardToken)))))

(define/pow
  (packInBranch [flag : Boolean])
  #:capabilities [idGen]
  #:returns (Exists [tokenId : String] [tokenId : String ::: (IsTokenId tokenId)])
  (thsl-src! "tests/exists-forwarding-tests.tesl" 70 (list (cons 'flag *flag)) (lambda () (let ([tokenId (generatePrefixedId "tok")]) (let/check ([tesl-checked-1 (checkTokenId tokenId)]) (let ([validated tesl-checked-1]) (if *flag (pack ([tokenId]) validated) (pack ([tokenId]) validated))))))))

(define/pow
  (renamedWitness)
  #:capabilities [idGen]
  #:returns (Exists [tokenId : String] [tokenId : String ::: (IsTokenId tokenId)])
  (thsl-src! "tests/exists-forwarding-tests.tesl" 82 (list) (lambda () (let ([internal (generatePrefixedId "tok")]) (let/check ([tesl-checked-2 (checkTokenId internal)]) (let ([validated tesl-checked-2]) (pack ([tokenId internal]) validated)))))))

(module+ test
  (require rackunit)
  (test-case "forwarded existential is consumable as its underlying type"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (idGen)
    (define tok (thsl-src! "tests/exists-forwarding-tests.tesl" 88 (list) (lambda () (forwardToken))))
    (check-true (raw-value (thsl-src! "tests/exists-forwarding-tests.tesl" 89 (list (cons 'tok tok)) (lambda () (tesl_import_String_startsWith (raw-value tok) "tok")))))
    (check-true (thsl-src! "tests/exists-forwarding-tests.tesl" 90 (list (cons 'tok tok)) (lambda () (tesl-gt? (raw-value (tesl_import_String_length (raw-value tok))) 3))))
    )
    ))
  )

  (test-case "existential forwarded through a let binding"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (idGen)
    (define tok (thsl-src! "tests/exists-forwarding-tests.tesl" 94 (list) (lambda () (forwardTokenViaLet))))
    (check-true (raw-value (thsl-src! "tests/exists-forwarding-tests.tesl" 95 (list (cons 'tok tok)) (lambda () (tesl_import_String_startsWith (raw-value tok) "tok")))))
    )
    ))
  )

  (test-case "every branch forwarding is accepted and packs survive"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (idGen)
    (define a (thsl-src! "tests/exists-forwarding-tests.tesl" 99 (list) (lambda () (forwardTokenBranching #t))))
    (define b (thsl-src! "tests/exists-forwarding-tests.tesl" 100 (list (cons 'a a)) (lambda () (forwardTokenBranching #f))))
    (check-true (raw-value (thsl-src! "tests/exists-forwarding-tests.tesl" 101 (list (cons 'b b) (cons 'a a)) (lambda () (tesl_import_String_startsWith (raw-value a) "tok")))))
    (check-true (raw-value (thsl-src! "tests/exists-forwarding-tests.tesl" 102 (list (cons 'b b) (cons 'a a)) (lambda () (tesl_import_String_startsWith (raw-value b) "tok")))))
    )
    ))
  )

  (test-case "a pack in an if-branch keeps its package"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (idGen)
    (define tok (thsl-src! "tests/exists-forwarding-tests.tesl" 106 (list) (lambda () (packInBranch #t))))
    (check-true (raw-value (thsl-src! "tests/exists-forwarding-tests.tesl" 107 (list (cons 'tok tok)) (lambda () (tesl_import_String_startsWith (raw-value tok) "tok")))))
    )
    ))
  )

  (test-case "packing a differently-named local matches the declared binder"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (idGen)
    (define tok (thsl-src! "tests/exists-forwarding-tests.tesl" 111 (list) (lambda () (renamedWitness))))
    (check-true (raw-value (thsl-src! "tests/exists-forwarding-tests.tesl" 112 (list (cons 'tok tok)) (lambda () (tesl_import_String_startsWith (raw-value tok) "tok")))))
    )
    ))
  )

)
