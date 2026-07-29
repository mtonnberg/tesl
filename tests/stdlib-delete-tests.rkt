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
  (only-in tesl/tesl/prelude Int String Bool)
  (only-in tesl/tesl/float Float)
  (only-in tesl/tesl/dict Dict [Dict.empty tesl_import_Dict_empty] [Dict.insert tesl_import_Dict_insert] [Dict.delete tesl_import_Dict_delete] [Dict.member tesl_import_Dict_member])
  (only-in tesl/tesl/set Set [Set.empty tesl_import_Set_empty] [Set.insert tesl_import_Set_insert] [Set.delete tesl_import_Set_delete] [Set.member tesl_import_Set_member])
  (only-in tesl/tesl/random random randomInt randomFloat)
  (only-in tesl/tesl/id generateId)
)


(provide )

(define/pow
  (dropKey [k : String])
  #:returns Boolean
  (let ([d (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/stdlib-delete-tests.tesl" 26 (list (cons 'k *k)) (lambda () (raw-value (tesl_import_Dict_insert *k 1 tesl_import_Dict_empty))))]) (let ([d2 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/stdlib-delete-tests.tesl" 27 (list (cons 'd *d) (cons 'k *k)) (lambda () (raw-value (tesl_import_Dict_delete *k (raw-value d)))))]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/stdlib-delete-tests.tesl" 28 (list (cons 'd2 *d2) (cons 'd *d) (cons 'k *k)) (lambda () (raw-value (tesl_import_Dict_member *k (raw-value d2))))))))

(define/pow
  (dropElem [x : Integer])
  #:returns Boolean
  (let ([s (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/stdlib-delete-tests.tesl" 31 (list (cons 'x *x)) (lambda () (raw-value (tesl_import_Set_insert *x tesl_import_Set_empty))))]) (let ([s2 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/stdlib-delete-tests.tesl" 32 (list (cons 's *s) (cons 'x *x)) (lambda () (raw-value (tesl_import_Set_delete *x (raw-value s)))))]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/stdlib-delete-tests.tesl" 33 (list (cons 's2 *s2) (cons 's *s) (cons 'x *x)) (lambda () (raw-value (tesl_import_Set_member *x (raw-value s2))))))))

(define/pow
  (rollInRange)
  #:capabilities [random]
  #:returns Integer
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/stdlib-delete-tests.tesl" 36 (list) (lambda () (raw-value (randomInt 5 6)))))

(define/pow
  (frac)
  #:capabilities [random]
  #:returns Real
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/stdlib-delete-tests.tesl" 39 (list) (lambda () (raw-value (randomFloat)))))

(define/pow
  (freshId)
  #:capabilities [random]
  #:returns String
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/stdlib-delete-tests.tesl" 42 (list) (lambda () (raw-value (generateId)))))

(module+ test
  (require rackunit)
  (test-case "Dict.delete removes the key (was unbound at runtime)"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/stdlib-delete-tests.tesl" 45 (list) (lambda () (dropKey "a")))) #f)
    ))
  )

  (test-case "Set.delete removes the element (was unbound at runtime)"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/stdlib-delete-tests.tesl" 49 (list) (lambda () (dropElem 7)))) #f)
    ))
  )

  (test-case "randomInt lo hi returns a value in [lo, hi) (was 1-arg arity crash)"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (random)
    (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/tests/stdlib-delete-tests.tesl" 53 (list) (lambda () (rollInRange)))) 5)
    )
    ))
  )

)
