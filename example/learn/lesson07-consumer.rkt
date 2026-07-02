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
  (only-in tesl/tesl/prelude Int String)
  (only-in (file "lesson07-home.rkt") InBounds Sanitized checkInBounds sanitize checkInBounds-signature sanitize-signature)
)


(provide processInput processInput-signature)

(define/pow
  (processInput [n : Integer ::: (InBounds n)] [label : String ::: (Sanitized label)])
  #:returns String
  (thsl-src! "example/learn/lesson07-consumer.tesl" 26 (list (cons 'n *n) (cons 'label *label)) (lambda () (format "processing ~a: ~a" (tesl-display-val *n) (tesl-display-val *label)))))

(define/pow
  (processRawInput [rawN : Integer] [rawLabel : String])
  #:returns String
  (thsl-src! "example/learn/lesson07-consumer.tesl" 32 (list (cons 'rawN *rawN) (cons 'rawLabel *rawLabel)) (lambda () (let/check ([tesl-checked-0 (checkInBounds rawN)]) (let ([validN tesl-checked-0]) (let/check ([tesl-checked-1 (sanitize rawLabel)]) (let ([validLabel tesl-checked-1]) (raw-value (processInput validN validLabel)))))))))

(module+ test
  (require rackunit)
  (test-case "processRawInput valid inputs"
  (define r1 (thsl-src! "example/learn/lesson07-consumer.tesl" 79 (list) (lambda () (processRawInput 5 "hello"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson07-consumer.tesl" 80 (list (cons 'r1 r1)) (lambda () r1))) "processing 5: hello")
  (define r2 (thsl-src! "example/learn/lesson07-consumer.tesl" 81 (list (cons 'r1 r1)) (lambda () (processRawInput 0 ""))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson07-consumer.tesl" 82 (list (cons 'r2 r2) (cons 'r1 r1)) (lambda () r2))) "processing 0: ")
  (define r3 (thsl-src! "example/learn/lesson07-consumer.tesl" 83 (list (cons 'r2 r2) (cons 'r1 r1)) (lambda () (processRawInput 1000 "max"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson07-consumer.tesl" 84 (list (cons 'r3 r3) (cons 'r2 r2) (cons 'r1 r1)) (lambda () r3))) "processing 1000: max")
  )

  (test-case "processRawInput invalid n"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson07-consumer.tesl" 88 (list) (lambda ()
                          (processRawInput -1 "hello"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: processRawInput -1 \"hello\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson07-consumer.tesl" 89 (list) (lambda ()
                          (processRawInput 1001 "hello"))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: processRawInput 1001 \"hello\""))
  )

)
