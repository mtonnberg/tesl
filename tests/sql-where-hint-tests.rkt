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
  (only-in tesl/tesl/prelude Bool Int List String)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/list [List.length tesl_import_List_length])
)


(provide )

(define-entity OrgW
  #:source (make-hash)
  #:table orgw
  #:primary-key id
  [Id id : String]
  [Name name : String]
)

(define-entity ProjW
  #:source (make-hash)
  #:table projw
  #:primary-key id
  [Id id : String]
  [Name name : String]
)

(define/pow
  (findOrg [pr : ProjW])
  #:capabilities [dbRead]
  #:returns (Maybe OrgW)
  (thsl-src! "tests/sql-where-hint-tests.tesl" 27 (list (cons 'pr *pr)) (lambda () (let ([tesl_match (select-one (from OrgW) (where (==. (entity-field-ref OrgW 'name) (tesl-dot/runtime pr 'name 'ProjW))))]) (if tesl_match (Something tesl_match) Nothing)))))

(define/pow
  (countBoth [pr : ProjW])
  #:capabilities [dbRead]
  #:returns Integer
  (let ([hits (thsl-src! "tests/sql-where-hint-tests.tesl" 30 (list (cons 'pr *pr)) (lambda () (select-many (from OrgW) (where (==. (entity-field-ref OrgW 'id) (tesl-dot/runtime pr 'id 'ProjW))) (where (==. (entity-field-ref OrgW 'name) (tesl-dot/runtime pr 'name 'ProjW))))))]) (thsl-src! "tests/sql-where-hint-tests.tesl" 31 (list (cons 'hits *hits) (cons 'pr *pr)) (lambda () (raw-value (tesl_import_List_length (raw-value hits)))))))

(module+ test
  (require rackunit)
  (test-case "shared-field read in where value operand does not trap (#27)"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-0 (thsl-src! "tests/sql-where-hint-tests.tesl" 34 (list) (lambda () (insert-one! OrgW (hash 'id "o1" 'name "acme")))))
    (define pr (thsl-src! "tests/sql-where-hint-tests.tesl" 35 (list) (lambda () (hash 'id "p1" 'name "acme"))))
    (check-true (raw-value (thsl-src! "tests/sql-where-hint-tests.tesl" 36 (list (cons 'pr pr)) (lambda () (let ([*tesl-case-1 (raw-value (findOrg pr))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([o (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "tests/sql-where-hint-tests.tesl" 37 (list (cons 'o o)) (lambda () (tesl-equal? (raw-value (tesl-dot/runtime o 'id 'OrgW)) "o1"))))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "tests/sql-where-hint-tests.tesl" 38 (list) (lambda () #f))]))))))
    )
    ))
  )

  (test-case "compound where with two shared-field value operands (#27)"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-2 (thsl-src! "tests/sql-where-hint-tests.tesl" 42 (list) (lambda () (insert-one! OrgW (hash 'id "same" 'name "beta")))))
    (define pr (thsl-src! "tests/sql-where-hint-tests.tesl" 43 (list) (lambda () (hash 'id "same" 'name "beta"))))
    (check-equal? (raw-value (thsl-src! "tests/sql-where-hint-tests.tesl" 44 (list (cons 'pr pr)) (lambda () (countBoth pr)))) 1)
    )
    ))
  )

  (test-case "no match returns Nothing without trapping (#27)"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define pr (thsl-src! "tests/sql-where-hint-tests.tesl" 48 (list) (lambda () (hash 'id "px" 'name "no-such-org"))))
    (check-true (raw-value (thsl-src! "tests/sql-where-hint-tests.tesl" 49 (list (cons 'pr pr)) (lambda () (let ([*tesl-case-3 (raw-value (findOrg pr))]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (thsl-src! "tests/sql-where-hint-tests.tesl" 50 (list) (lambda () #f))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "tests/sql-where-hint-tests.tesl" 51 (list) (lambda () #t))]))))))
    )
    ))
  )

)
