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
  (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 66 (list (cons 'n *n)) (lambda () (* *n 2))))

(define/pow
  (addOne [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 68 (list (cons 'n *n)) (lambda () (+ *n 1))))

(define/pow
  (measureWord [raw : String])
  #:returns Integer
  (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 73 (list (cons 'raw *raw)) (lambda () (raw-value (tesl_import_String_length (raw-value (tesl_import_String_trim *raw)))))))

(define/pow
  (processWord [raw : String])
  #:returns Integer
  (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 78 (list (cons 'raw *raw)) (lambda () (raw-value (tesl_import_String_length (raw-value (tesl_import_String_trim *raw)))))))

(define/pow
  (describeLength [n : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 82 (list (cons 'n *n)) (lambda () (if (<= *n 4) (raw-value "short") (if (<= *n 10) (raw-value "medium") (raw-value "long"))))))

(define/pow
  (formatResult [label : String] [n : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 91 (list (cons 'label *label) (cons 'n *n)) (lambda () (format "~a: ~a" (tesl-display-val *label) (tesl-display-val *n)))))

(define/pow
  (processChain [n : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 97 (list (cons 'n *n)) (lambda () (raw-value (double (addOne (double n)))))))

(module+ test
  (require rackunit)
  (test-case "forward pipe: basic application"
  (define result (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 173 (list) (lambda () (double 5))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 174 (list (cons 'result result)) (lambda () result))) 10)
  )

  (test-case "forward pipe: chain two functions"
  (define result (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 178 (list) (lambda () (addOne (double 3)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 179 (list (cons 'result result)) (lambda () result))) 7)
  )

  (test-case "forward pipe: chain three functions"
  (define result (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 183 (list) (lambda () (double (addOne (double 2))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 184 (list (cons 'result result)) (lambda () result))) 10)
  )

  (test-case "backward pipe: basic application"
  (define result (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 188 (list) (lambda () (double 5))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 189 (list (cons 'result result)) (lambda () result))) 10)
  )

  (test-case "backward pipe: chain two functions"
  (define result (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 193 (list) (lambda () (addOne (double 3)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 194 (list (cons 'result result)) (lambda () result))) 7)
  )

  (test-case "backward pipe: chain three functions"
  (define result (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 198 (list) (lambda () (double (addOne (double 2))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 199 (list (cons 'result result)) (lambda () result))) 10)
  )

  (test-case "forward pipe with stdlib function"
  (define result (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 203 (list) (lambda () (tesl_import_String_length "hello"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 204 (list (cons 'result result)) (lambda () result))) 5)
  )

  (test-case "backward pipe with stdlib function"
  (define result (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 208 (list) (lambda () (tesl_import_String_length "hello"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 209 (list (cons 'result result)) (lambda () result))) 5)
  )

  (test-case "measureWord trims before measuring"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 213 (list) (lambda () (measureWord "  hi  ")))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 214 (list) (lambda () (measureWord "hello")))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 215 (list) (lambda () (measureWord "  ")))) 0)
  )

  (test-case "processWord gives same result as measureWord"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 219 (list) (lambda () (processWord "  hi  ")))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 220 (list) (lambda () (processWord "hello")))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 221 (list) (lambda () (processWord "  world  ")))) 5)
  )

  (test-case "processChain applies double, addOne, double in order"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 227 (list) (lambda () (processChain 3)))) 14)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 229 (list) (lambda () (processChain 0)))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 231 (list) (lambda () (processChain 1)))) 6)
  )

  (test-case "describeLength classifies correctly"
  (define short (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 235 (list) (lambda () (describeLength 3))))
  (define medium (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 236 (list (cons 'short short)) (lambda () (describeLength 7))))
  (define long (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 237 (list (cons 'medium medium) (cons 'short short)) (lambda () (describeLength 12))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 238 (list (cons 'long long) (cons 'medium medium) (cons 'short short)) (lambda () short))) "short")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 239 (list (cons 'long long) (cons 'medium medium) (cons 'short short)) (lambda () medium))) "medium")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson65-pipe-operators.tesl" 240 (list (cons 'long long) (cons 'medium medium) (cons 'short short)) (lambda () long))) "long")
  )

)
