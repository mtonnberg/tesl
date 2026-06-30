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
  (only-in tesl/tesl/prelude Int String Fact detachFact attachFact forgetFact)
)


(provide ValidScore checkScore requiresValidScore diagnoseCommonMistakes checkScore-signature requiresValidScore-signature diagnoseCommonMistakes-signature)

(define ValidScore 'ValidScore)

(define-checker
  (checkScore [n : Integer])
  #:returns [n : Integer ::: (ValidScore n)]
  (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 29 (list (cons 'n *n)) (lambda () (if (and (>= *n 0) (<= *n 100)) (accept (ValidScore n) #:value *n) (reject "score must be 0-100" #:http-code 400)))))

(define/pow
  (requiresValidScore [n : Integer ::: (ValidScore n)])
  #:returns String
  (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 35 (list (cons 'n *n)) (lambda () (format "score: ~a" (tesl-display-val *n)))))

(define/pow
  (diagnoseCommonMistakes [raw : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 55 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_0 (checkScore raw)]) (let ([validated tesl_checked_0]) (raw-value (requiresValidScore validated)))))))

(define-trusted
  (halvePreservesScore [n : Integer ::: (ValidScore n)])
  #:returns (Fact (ValidScore (n / 2)))
  (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 140 (list (cons 'n *n)) (lambda () (trusted-proof (ValidScore (quotient *n 2))))))

(define/pow
  (halveScore [n : Integer ::: (ValidScore n)])
  #:returns (? Integer _entity ::: (ValidScore _entity))
  (let ([result (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 143 (list (cons 'n *n)) (lambda () (quotient *n 2)))]) (let ([pf (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 144 (list (cons 'result *result) (cons 'n *n)) (lambda () (halvePreservesScore n)))]) (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 145 (list (cons 'pf *pf) (cons 'result *result) (cons 'n *n)) (lambda () (attach-proof result pf))))))

(define/pow
  (halveAndShow [n : Integer ::: (ValidScore n)])
  #:returns String
  (let ([halved (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 149 (list (cons 'n *n)) (lambda () (halveScore n)))]) (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 150 (list (cons 'halved *halved) (cons 'n *n)) (lambda () (raw-value (requiresValidScore halved))))))

(define/pow
  (roundtripProof [raw : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 153 (list (cons 'raw *raw)) (lambda () (let/check ([tesl_checked_1 (checkScore raw)]) (let ([validated tesl_checked_1]) (let ([pf (detach-all-proof validated)]) (let ([stripped (forget-proof validated)]) (let ([restored (attach-proof stripped pf)]) (raw-value (requiresValidScore restored))))))))))

(module+ test
  (require rackunit)
  (test-case "diagnoseCommonMistakes processes valid score"
  (define result (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 164 (list) (lambda () (diagnoseCommonMistakes 75))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 165 (list (cons 'result result)) (lambda () result))) "score: 75")
  )

  (test-case "diagnoseCommonMistakes rejects invalid score"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 169 (list) (lambda ()
                          ((diagnoseCommonMistakes 150) (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (diagnoseCommonMistakes 150) (list)"))
  )

  (test-case "halveScore preserves proof without revalidation"
  (define n (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 173 (list) (lambda () 80)))
  (define tesl_checked_2 (checkScore n))
  (when (check-fail? tesl_checked_2)
    (raise-user-error 'tesl-test "unexpected failure in let validated: ~a" (check-fail-message tesl_checked_2)))
  (define validated tesl_checked_2)
  (define result (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 175 (list (cons 'validated validated) (cons 'n n)) (lambda () (halveAndShow validated))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 176 (list (cons 'result result) (cons 'validated validated) (cons 'n n)) (lambda () result))) "score: 40")
  )

  (test-case "roundtripProof works"
  (define result (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 180 (list) (lambda () (roundtripProof 50))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson54-debugging-proof-errors.tesl" 181 (list (cons 'result result)) (lambda () result))) "score: 50")
  )

)
