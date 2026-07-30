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
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.trim tesl_import_String_trim] IsTrimmed)
)


(provide double addOne measureWord processWord describeLength formatResult processChain double-signature addOne-signature measureWord-signature processWord-signature describeLength-signature formatResult-signature processChain-signature)

(define/pow
  (double [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 67 (list (cons 'n *n)) (lambda () (* *n 2))))

(define/pow
  (addOne [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 69 (list (cons 'n *n)) (lambda () (+ *n 1))))

(define/pow
  (measureWord [raw : String])
  #:returns Integer
  (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 74 (list (cons 'raw *raw)) (lambda () (raw-value (tesl_import_String_length (raw-value (tesl_import_String_trim *raw)))))))

(define/pow
  (processWord [raw : String])
  #:returns Integer
  (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 79 (list (cons 'raw *raw)) (lambda () (raw-value (tesl_import_String_length (raw-value (tesl_import_String_trim *raw)))))))

(define/pow
  (describeLength [n : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 83 (list (cons 'n *n)) (lambda () (if (tesl-le? *n 4) (raw-value "short") (if (tesl-le? *n 10) (raw-value "medium") (raw-value "long"))))))

(define/pow
  (formatResult [label : String] [n : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 92 (list (cons 'label *label) (cons 'n *n)) (lambda () (format "~a: ~a" (tesl-display-val *label) (tesl-display-val *n)))))

(define/pow
  (processChain [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 98 (list (cons 'n *n)) (lambda () (raw-value (double (addOne (double n)))))))

(module+ test
  (require rackunit)
  (test-case "forward pipe: basic application"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 174 (list) (lambda () (double 5))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 175 (list (cons 'result result)) (lambda () result))) 10)
    ))
  )

  (test-case "forward pipe: chain two functions"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 179 (list) (lambda () (addOne (double 3)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 180 (list (cons 'result result)) (lambda () result))) 7)
    ))
  )

  (test-case "forward pipe: chain three functions"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 184 (list) (lambda () (double (addOne (double 2))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 185 (list (cons 'result result)) (lambda () result))) 10)
    ))
  )

  (test-case "backward pipe: basic application"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 189 (list) (lambda () (double 5))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 190 (list (cons 'result result)) (lambda () result))) 10)
    ))
  )

  (test-case "backward pipe: chain two functions"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 194 (list) (lambda () (addOne (double 3)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 195 (list (cons 'result result)) (lambda () result))) 7)
    ))
  )

  (test-case "backward pipe: chain three functions"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 199 (list) (lambda () (double (addOne (double 2))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 200 (list (cons 'result result)) (lambda () result))) 10)
    ))
  )

  (test-case "forward pipe with stdlib function"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 204 (list) (lambda () (tesl_import_String_length "hello"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 205 (list (cons 'result result)) (lambda () result))) 5)
    ))
  )

  (test-case "backward pipe with stdlib function"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 209 (list) (lambda () (tesl_import_String_length "hello"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 210 (list (cons 'result result)) (lambda () result))) 5)
    ))
  )

  (test-case "measureWord trims before measuring"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 214 (list) (lambda () (measureWord "  hi  ")))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 215 (list) (lambda () (measureWord "hello")))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 216 (list) (lambda () (measureWord "  ")))) 0)
    ))
  )

  (test-case "processWord gives same result as measureWord"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 220 (list) (lambda () (processWord "  hi  ")))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 221 (list) (lambda () (processWord "hello")))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 222 (list) (lambda () (processWord "  world  ")))) 5)
    ))
  )

  (test-case "processChain applies double, addOne, double in order"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 228 (list) (lambda () (processChain 3)))) 14)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 230 (list) (lambda () (processChain 0)))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 232 (list) (lambda () (processChain 1)))) 6)
    ))
  )

  (test-case "describeLength classifies correctly"
    (call-with-fresh-memory-db '() (lambda ()
  (define short (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 236 (list) (lambda () (describeLength 3))))
  (define medium (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 237 (list (cons 'short short)) (lambda () (describeLength 7))))
  (define long (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 238 (list (cons 'medium medium) (cons 'short short)) (lambda () (describeLength 12))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 239 (list (cons 'long long) (cons 'medium medium) (cons 'short short)) (lambda () short))) "short")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 240 (list (cons 'long long) (cons 'medium medium) (cons 'short short)) (lambda () medium))) "medium")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 241 (list (cons 'long long) (cons 'medium medium) (cons 'short short)) (lambda () long))) "long")
    ))
  )

)
