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
  (only-in tesl/tesl/prelude Int String Fact)
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
)


(provide ValidScore checkScore ValidTag checkTag extractRaw showScore reattachAndUse justTheProof stripAndDescribe decomposeThenCall checkScore-signature checkTag-signature extractRaw-signature showScore-signature reattachAndUse-signature justTheProof-signature stripAndDescribe-signature decomposeThenCall-signature)

(define ValidScore 'ValidScore)
(define ValidTag 'ValidTag)

(define-checker
  (checkScore [n : Integer])
  #:returns [n : Integer ::: (ValidScore n)]
  (if (and (>= *n 0) (<= *n 100)) (accept (ValidScore n) #:value *n) (reject "score must be between 0 and 100" #:http-code 400)))

(define-checker
  (checkTag [s : String])
  #:returns [s : String ::: (ValidTag s)]
  (if (and (>= (raw-value (tesl_import_String_length *s)) 1) (<= (raw-value (tesl_import_String_length *s)) 20)) (accept (ValidTag s) #:value *s) (reject "tag must be 1-20 characters" #:http-code 400)))

(define/pow
  (requiresValidScore [score : Integer ::: (ValidScore score)])
  #:returns String
  (format "score: ~a" (tesl-display-val *score)))

(define/pow
  (requiresValidTag [tag : String ::: (ValidTag tag)])
  #:returns String
  (format "tag: ~a" (tesl-display-val *tag)))

(define/pow
  (extractRaw [score : Integer ::: (ValidScore score)])
  #:returns Integer
  (let ([raw score]) raw))

(define/pow
  (showScore [score : Integer ::: (ValidScore score)])
  #:returns String
  (let ([raw score]) (format "score is ~a" (tesl-display-val *raw))))

(define/pow
  (reattachAndUse [score : Integer ::: (ValidScore score)])
  #:returns String
  (let ([tesl_proof_binding_0 score]) (let ([raw (forget-proof tesl_proof_binding_0)] [p (detach-all-proof tesl_proof_binding_0)]) (raw-value (requiresValidScore (attach-proof raw p))))))

(define/pow
  (justTheProof [score : Integer ::: (ValidScore score)])
  #:returns String
  (let ([tesl_proof_binding_1 score]) (let ([_ (forget-proof tesl_proof_binding_1)] [_p (detach-all-proof tesl_proof_binding_1)]) "proof extracted")))

(define/pow
  (stripAndDescribe [score : Integer ::: (ValidScore score)])
  #:returns String
  (let ([tesl_proof_binding_2 score]) (let ([raw (forget-proof tesl_proof_binding_2)] [p (detach-all-proof tesl_proof_binding_2)]) (let ([formatted (format "raw value: ~a" (tesl-display-val *raw))]) (let ([withProof (requiresValidScore (attach-proof raw p))]) (format "~a (~a)" (tesl-display-val *formatted) (tesl-display-val *withProof)))))))

(define/pow
  (decomposeThenCall [score : Integer ::: (ValidScore score)] [tag : String ::: (ValidTag tag)])
  #:returns String
  (let ([tesl_proof_binding_3 score]) (let ([rawScore (forget-proof tesl_proof_binding_3)] [scoreProof (detach-all-proof tesl_proof_binding_3)]) (let ([tesl_proof_binding_4 tag]) (let ([rawTag (forget-proof tesl_proof_binding_4)] [tagProof (detach-all-proof tesl_proof_binding_4)]) (let ([tesl_proof_binding_5 (attach-proof rawScore (list scoreProof tagProof))]) (let ([_ (forget-proof tesl_proof_binding_5)] [scoreProof2 (detach-all-proof tesl_proof_binding_5)]) (let ([tesl_proof_binding_6 (attach-proof rawScore (list scoreProof tagProof))]) (let ([_ (forget-proof tesl_proof_binding_6)] [tagProof2 (detach-all-proof tesl_proof_binding_6)]) (let ([scoreStr (requiresValidScore (attach-proof rawScore scoreProof2))]) (let ([tagStr (requiresValidTag (attach-proof rawTag tagProof2))]) (format "~a = ~a" (tesl-display-val *tagStr) (tesl-display-val *scoreStr)))))))))))))

(module+ test
  (require rackunit)
  (test-case "extractRaw returns bare Int"
  (define n42 42)
  (define tesl_checked_7 (checkScore n42))
  (when (check-fail? tesl_checked_7)
    (raise-user-error 'tesl-test "unexpected failure in let s: ~a" (check-fail-message tesl_checked_7)))
  (define s tesl_checked_7)
  (check-equal? (raw-value (extractRaw s)) 42)
  (define n0 0)
  (define tesl_checked_8 (checkScore n0))
  (when (check-fail? tesl_checked_8)
    (raise-user-error 'tesl-test "unexpected failure in let s0: ~a" (check-fail-message tesl_checked_8)))
  (define s0 tesl_checked_8)
  (check-equal? (raw-value (extractRaw s0)) 0)
  (define n100 100)
  (define tesl_checked_9 (checkScore n100))
  (when (check-fail? tesl_checked_9)
    (raise-user-error 'tesl-test "unexpected failure in let s100: ~a" (check-fail-message tesl_checked_9)))
  (define s100 tesl_checked_9)
  (check-equal? (raw-value (extractRaw s100)) 100)
  )

  (test-case "showScore formats string"
  (define n75 75)
  (define tesl_checked_10 (checkScore n75))
  (when (check-fail? tesl_checked_10)
    (raise-user-error 'tesl-test "unexpected failure in let s: ~a" (check-fail-message tesl_checked_10)))
  (define s tesl_checked_10)
  (check-equal? (raw-value (showScore s)) "score is 75")
  (define n0 0)
  (define tesl_checked_11 (checkScore n0))
  (when (check-fail? tesl_checked_11)
    (raise-user-error 'tesl-test "unexpected failure in let s0: ~a" (check-fail-message tesl_checked_11)))
  (define s0 tesl_checked_11)
  (check-equal? (raw-value (showScore s0)) "score is 0")
  )

  (test-case "reattachAndUse passes proof through"
  (define n30 30)
  (define tesl_checked_12 (checkScore n30))
  (when (check-fail? tesl_checked_12)
    (raise-user-error 'tesl-test "unexpected failure in let s: ~a" (check-fail-message tesl_checked_12)))
  (define s tesl_checked_12)
  (check-equal? (raw-value (reattachAndUse s)) "score: 30")
  (define n99 99)
  (define tesl_checked_13 (checkScore n99))
  (when (check-fail? tesl_checked_13)
    (raise-user-error 'tesl-test "unexpected failure in let s99: ~a" (check-fail-message tesl_checked_13)))
  (define s99 tesl_checked_13)
  (check-equal? (raw-value (reattachAndUse s99)) "score: 99")
  )

  (test-case "justTheProof extracts proof without value"
  (define n50 50)
  (define tesl_checked_14 (checkScore n50))
  (when (check-fail? tesl_checked_14)
    (raise-user-error 'tesl-test "unexpected failure in let s: ~a" (check-fail-message tesl_checked_14)))
  (define s tesl_checked_14)
  (check-equal? (raw-value (justTheProof s)) "proof extracted")
  )

  (test-case "stripAndDescribe combines both halves"
  (define n7 7)
  (define tesl_checked_15 (checkScore n7))
  (when (check-fail? tesl_checked_15)
    (raise-user-error 'tesl-test "unexpected failure in let s: ~a" (check-fail-message tesl_checked_15)))
  (define s tesl_checked_15)
  (check-equal? (raw-value (stripAndDescribe s)) "raw value: 7 (score: 7)")
  )

  (test-case "decomposeThenCall uses both decomposed values"
  (define n88 88)
  (define tesl_checked_16 (checkScore n88))
  (when (check-fail? tesl_checked_16)
    (raise-user-error 'tesl-test "unexpected failure in let s: ~a" (check-fail-message tesl_checked_16)))
  (define s tesl_checked_16)
  (define tagStr "player")
  (define tesl_checked_17 (checkTag tagStr))
  (when (check-fail? tesl_checked_17)
    (raise-user-error 'tesl-test "unexpected failure in let t: ~a" (check-fail-message tesl_checked_17)))
  (define t tesl_checked_17)
  (check-equal? (raw-value (decomposeThenCall s t)) "tag: player = score: 88")
  )

  (test-case "checkScore validates range"
  (define n0 0)
  (define n50 50)
  (define n100 100)
  (define tesl_checked_18 (checkScore n0))
  (when (check-fail? tesl_checked_18)
    (raise-user-error 'tesl-test "unexpected failure in let no_p: ~a" (check-fail-message tesl_checked_18)))
  (define no_p tesl_checked_18)
  (define tesl_checked_19 (checkScore n50))
  (when (check-fail? tesl_checked_19)
    (raise-user-error 'tesl-test "unexpected failure in let n50_p: ~a" (check-fail-message tesl_checked_19)))
  (define n50_p tesl_checked_19)
  (define tesl_checked_20 (checkScore n100))
  (when (check-fail? tesl_checked_20)
    (raise-user-error 'tesl-test "unexpected failure in let n100_p: ~a" (check-fail-message tesl_checked_20)))
  (define n100_p tesl_checked_20)
  (check-equal? (raw-value (showScore no_p)) "score is 0")
  (check-equal? (raw-value (showScore n50_p)) "score is 50")
  (check-equal? (raw-value (showScore n100_p)) "score is 100")
  )

  (test-case "checkScore rejects out-of-range"
  (define nNeg1 -1)
  (define n101 101)
  (define nNeg100 -100)
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkScore nNeg1))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkScore nNeg1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkScore n101))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkScore n101"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkScore nNeg100))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkScore nNeg100"))
  )

  (test-case "checkTag validates non-empty short strings"
  (define n1 1)
  (define tesl_checked_21 (checkScore n1))
  (when (check-fail? tesl_checked_21)
    (raise-user-error 'tesl-test "unexpected failure in let score: ~a" (check-fail-message tesl_checked_21)))
  (define score tesl_checked_21)
  (define tagA "a")
  (define tagHello "hello")
  (define tesl_checked_22 (checkTag tagA))
  (when (check-fail? tesl_checked_22)
    (raise-user-error 'tesl-test "unexpected failure in let t1: ~a" (check-fail-message tesl_checked_22)))
  (define t1 tesl_checked_22)
  (define tesl_checked_23 (checkTag tagHello))
  (when (check-fail? tesl_checked_23)
    (raise-user-error 'tesl-test "unexpected failure in let t2: ~a" (check-fail-message tesl_checked_23)))
  (define t2 tesl_checked_23)
  (check-equal? (raw-value (decomposeThenCall score t1)) "tag: a = score: 1")
  (check-equal? (raw-value (decomposeThenCall score t2)) "tag: hello = score: 1")
  )

  (test-case "checkTag rejects invalid strings"
  (define empty "")
  (define tooLong "this-tag-is-way-too-long-to-be-valid")
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTag empty))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTag empty"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTag tooLong))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTag tooLong"))
  )

)
