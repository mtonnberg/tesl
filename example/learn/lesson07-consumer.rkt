#lang racket

(require
  tesl/dsl/capability
  tesl/dsl/types
  tesl/dsl/check
  tesl/dsl/otel
  tesl/dsl/sql
  tesl/dsl/web
  tesl/dsl/test-support
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
  (format "processing ~a: ~a" (tesl-display-val *n) (tesl-display-val *label)))

(define/pow
  (processRawInput [rawN : Integer] [rawLabel : String])
  #:returns String
  (let/check ([tesl_checked_0 (checkInBounds rawN)]) (let ([validN tesl_checked_0]) (let/check ([tesl_checked_1 (sanitize rawLabel)]) (let ([validLabel tesl_checked_1]) (raw-value (processInput validN validLabel)))))))

(module+ test
  (require rackunit)
  (test-case "processRawInput valid inputs"
  (define r1 (processRawInput 5 "hello"))
  (check-equal? (raw-value r1) "processing 5: hello")
  (define r2 (processRawInput 0 ""))
  (check-equal? (raw-value r2) "processing 0: ")
  (define r3 (processRawInput 1000 "max"))
  (check-equal? (raw-value r3) "processing 1000: max")
  )

  (test-case "processRawInput invalid n"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (processRawInput -1 "hello"))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: processRawInput -1 \"hello\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (processRawInput 1001 "hello"))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: processRawInput 1001 \"hello\""))
  )

)
