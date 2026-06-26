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
  (only-in tesl/tesl/prelude Int String Fact)
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
)


(provide ValidScore checkScore ValidTag checkTag extractRaw showScore reattachAndUse justTheProof stripAndDescribe decomposeThenCall checkScore-signature checkTag-signature extractRaw-signature showScore-signature reattachAndUse-signature justTheProof-signature stripAndDescribe-signature decomposeThenCall-signature)

(define ValidScore 'ValidScore)
(define ValidTag 'ValidTag)

(define-checker
  (checkScore [n : Integer])
  #:returns [n : Integer ::: (ValidScore n)]
  (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 50 (list (cons 'n *n)) (lambda () (if (and (>= *n 0) (<= *n 100)) (accept (ValidScore n) #:value *n) (reject "score must be between 0 and 100" #:http-code 400)))))

(define-checker
  (checkTag [s : String])
  #:returns [s : String ::: (ValidTag s)]
  (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 59 (list (cons 's *s)) (lambda () (if (and (>= (raw-value (tesl_import_String_length *s)) 1) (<= (raw-value (tesl_import_String_length *s)) 20)) (accept (ValidTag s) #:value *s) (reject "tag must be 1-20 characters" #:http-code 400)))))

(define/pow
  (requiresValidScore [score : Integer ::: (ValidScore score)])
  #:returns String
  (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 66 (list (cons 'score *score)) (lambda () (format "score: ~a" (tesl-display-val *score)))))

(define/pow
  (requiresValidTag [tag : String ::: (ValidTag tag)])
  #:returns String
  (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 70 (list (cons 'tag *tag)) (lambda () (format "tag: ~a" (tesl-display-val *tag)))))

(define/pow
  (extractRaw [score : Integer ::: (ValidScore score)])
  #:returns Integer
  (let ([raw (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 80 (list (cons 'score *score)) (lambda () score))]) (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 81 (list (cons 'raw *raw) (cons 'score *score)) (lambda () raw))))

(define/pow
  (showScore [score : Integer ::: (ValidScore score)])
  #:returns String
  (let ([raw (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 84 (list (cons 'score *score)) (lambda () score))]) (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 85 (list (cons 'raw *raw) (cons 'score *score)) (lambda () (format "score is ~a" (tesl-display-val *raw))))))

(define/pow
  (reattachAndUse [score : Integer ::: (ValidScore score)])
  #:returns String
  (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 95 (list (cons 'score *score)) (lambda () (let ([tesl_proof_binding_0 score]) (let ([raw (forget-proof tesl_proof_binding_0)] [p (detach-all-proof tesl_proof_binding_0)]) (raw-value (requiresValidScore (attach-proof raw p))))))))

(define/pow
  (justTheProof [score : Integer ::: (ValidScore score)])
  #:returns String
  (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 107 (list (cons 'score *score)) (lambda () (let ([tesl_proof_binding_1 score]) (let ([_ (forget-proof tesl_proof_binding_1)] [_p (detach-all-proof tesl_proof_binding_1)]) "proof extracted")))))

(define/pow
  (stripAndDescribe [score : Integer ::: (ValidScore score)])
  #:returns String
  (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 117 (list (cons 'score *score)) (lambda () (let ([tesl_proof_binding_2 score]) (let ([raw (forget-proof tesl_proof_binding_2)] [p (detach-all-proof tesl_proof_binding_2)]) (let ([formatted (format "raw value: ~a" (tesl-display-val *raw))]) (let ([withProof (requiresValidScore (attach-proof raw p))]) (format "~a (~a)" (tesl-display-val *formatted) (tesl-display-val *withProof)))))))))

(define/pow
  (decomposeThenCall [score : Integer ::: (ValidScore score)] [tag : String ::: (ValidTag tag)])
  #:returns String
  (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 130 (list (cons 'score *score) (cons 'tag *tag)) (lambda () (let ([tesl_proof_binding_3 score]) (let ([rawScore (forget-proof tesl_proof_binding_3)] [scoreProof (detach-all-proof tesl_proof_binding_3)]) (let ([tesl_proof_binding_4 tag]) (let ([rawTag (forget-proof tesl_proof_binding_4)] [tagProof (detach-all-proof tesl_proof_binding_4)]) (let ([tesl_proof_binding_5 (attach-proof rawScore (list scoreProof tagProof))]) (let ([_ (forget-proof tesl_proof_binding_5)] [scoreProof2 (detach-all-proof tesl_proof_binding_5)]) (let ([tesl_proof_binding_6 (attach-proof rawScore (list scoreProof tagProof))]) (let ([_ (forget-proof tesl_proof_binding_6)] [tagProof2 (detach-all-proof tesl_proof_binding_6)]) (let ([scoreStr (requiresValidScore (attach-proof rawScore scoreProof2))]) (let ([tagStr (requiresValidTag (attach-proof rawTag tagProof2))]) (format "~a = ~a" (tesl-display-val *tagStr) (tesl-display-val *scoreStr)))))))))))))))

(module+ test
  (require rackunit)
  (test-case "extractRaw returns bare Int"
  (define n42 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 222 (list) (lambda () 42)))
  (define tesl_checked_7 (checkScore n42))
  (when (check-fail? tesl_checked_7)
    (raise-user-error 'tesl-test "unexpected failure in let s: ~a" (check-fail-message tesl_checked_7)))
  (define s tesl_checked_7)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 224 (list (cons 's s) (cons 'n42 n42)) (lambda () (extractRaw s)))) 42)
  (define n0 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 225 (list (cons 's s) (cons 'n42 n42)) (lambda () 0)))
  (define tesl_checked_8 (checkScore n0))
  (when (check-fail? tesl_checked_8)
    (raise-user-error 'tesl-test "unexpected failure in let s0: ~a" (check-fail-message tesl_checked_8)))
  (define s0 tesl_checked_8)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 227 (list (cons 's0 s0) (cons 'n0 n0) (cons 's s) (cons 'n42 n42)) (lambda () (extractRaw s0)))) 0)
  (define n100 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 228 (list (cons 's0 s0) (cons 'n0 n0) (cons 's s) (cons 'n42 n42)) (lambda () 100)))
  (define tesl_checked_9 (checkScore n100))
  (when (check-fail? tesl_checked_9)
    (raise-user-error 'tesl-test "unexpected failure in let s100: ~a" (check-fail-message tesl_checked_9)))
  (define s100 tesl_checked_9)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 230 (list (cons 's100 s100) (cons 'n100 n100) (cons 's0 s0) (cons 'n0 n0) (cons 's s) (cons 'n42 n42)) (lambda () (extractRaw s100)))) 100)
  )

  (test-case "showScore formats string"
  (define n75 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 234 (list) (lambda () 75)))
  (define tesl_checked_10 (checkScore n75))
  (when (check-fail? tesl_checked_10)
    (raise-user-error 'tesl-test "unexpected failure in let s: ~a" (check-fail-message tesl_checked_10)))
  (define s tesl_checked_10)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 236 (list (cons 's s) (cons 'n75 n75)) (lambda () (showScore s)))) "score is 75")
  (define n0 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 237 (list (cons 's s) (cons 'n75 n75)) (lambda () 0)))
  (define tesl_checked_11 (checkScore n0))
  (when (check-fail? tesl_checked_11)
    (raise-user-error 'tesl-test "unexpected failure in let s0: ~a" (check-fail-message tesl_checked_11)))
  (define s0 tesl_checked_11)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 239 (list (cons 's0 s0) (cons 'n0 n0) (cons 's s) (cons 'n75 n75)) (lambda () (showScore s0)))) "score is 0")
  )

  (test-case "reattachAndUse passes proof through"
  (define n30 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 243 (list) (lambda () 30)))
  (define tesl_checked_12 (checkScore n30))
  (when (check-fail? tesl_checked_12)
    (raise-user-error 'tesl-test "unexpected failure in let s: ~a" (check-fail-message tesl_checked_12)))
  (define s tesl_checked_12)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 245 (list (cons 's s) (cons 'n30 n30)) (lambda () (reattachAndUse s)))) "score: 30")
  (define n99 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 246 (list (cons 's s) (cons 'n30 n30)) (lambda () 99)))
  (define tesl_checked_13 (checkScore n99))
  (when (check-fail? tesl_checked_13)
    (raise-user-error 'tesl-test "unexpected failure in let s99: ~a" (check-fail-message tesl_checked_13)))
  (define s99 tesl_checked_13)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 248 (list (cons 's99 s99) (cons 'n99 n99) (cons 's s) (cons 'n30 n30)) (lambda () (reattachAndUse s99)))) "score: 99")
  )

  (test-case "justTheProof extracts proof without value"
  (define n50 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 252 (list) (lambda () 50)))
  (define tesl_checked_14 (checkScore n50))
  (when (check-fail? tesl_checked_14)
    (raise-user-error 'tesl-test "unexpected failure in let s: ~a" (check-fail-message tesl_checked_14)))
  (define s tesl_checked_14)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 254 (list (cons 's s) (cons 'n50 n50)) (lambda () (justTheProof s)))) "proof extracted")
  )

  (test-case "stripAndDescribe combines both halves"
  (define n7 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 258 (list) (lambda () 7)))
  (define tesl_checked_15 (checkScore n7))
  (when (check-fail? tesl_checked_15)
    (raise-user-error 'tesl-test "unexpected failure in let s: ~a" (check-fail-message tesl_checked_15)))
  (define s tesl_checked_15)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 260 (list (cons 's s) (cons 'n7 n7)) (lambda () (stripAndDescribe s)))) "raw value: 7 (score: 7)")
  )

  (test-case "decomposeThenCall uses both decomposed values"
  (define n88 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 264 (list) (lambda () 88)))
  (define tesl_checked_16 (checkScore n88))
  (when (check-fail? tesl_checked_16)
    (raise-user-error 'tesl-test "unexpected failure in let s: ~a" (check-fail-message tesl_checked_16)))
  (define s tesl_checked_16)
  (define tagStr (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 266 (list (cons 's s) (cons 'n88 n88)) (lambda () "player")))
  (define tesl_checked_17 (checkTag tagStr))
  (when (check-fail? tesl_checked_17)
    (raise-user-error 'tesl-test "unexpected failure in let t: ~a" (check-fail-message tesl_checked_17)))
  (define t tesl_checked_17)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 268 (list (cons 't t) (cons 'tagStr tagStr) (cons 's s) (cons 'n88 n88)) (lambda () (decomposeThenCall s t)))) "tag: player = score: 88")
  )

  (test-case "checkScore validates range"
  (define n0 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 272 (list) (lambda () 0)))
  (define n50 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 273 (list (cons 'n0 n0)) (lambda () 50)))
  (define n100 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 274 (list (cons 'n50 n50) (cons 'n0 n0)) (lambda () 100)))
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
  (check-equal? (raw-value (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 278 (list (cons 'n100_p n100_p) (cons 'n50_p n50_p) (cons 'no_p no_p) (cons 'n100 n100) (cons 'n50 n50) (cons 'n0 n0)) (lambda () (showScore no_p)))) "score is 0")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 279 (list (cons 'n100_p n100_p) (cons 'n50_p n50_p) (cons 'no_p no_p) (cons 'n100 n100) (cons 'n50 n50) (cons 'n0 n0)) (lambda () (showScore n50_p)))) "score is 50")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 280 (list (cons 'n100_p n100_p) (cons 'n50_p n50_p) (cons 'no_p no_p) (cons 'n100 n100) (cons 'n50 n50) (cons 'n0 n0)) (lambda () (showScore n100_p)))) "score is 100")
  )

  (test-case "checkScore rejects out-of-range"
  (define nNeg1 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 284 (list) (lambda () -1)))
  (define n101 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 285 (list (cons 'nNeg1 nNeg1)) (lambda () 101)))
  (define nNeg100 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 286 (list (cons 'n101 n101) (cons 'nNeg1 nNeg1)) (lambda () -100)))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 287 (list (cons 'nNeg100 nNeg100) (cons 'n101 n101) (cons 'nNeg1 nNeg1)) (lambda ()
                          (checkScore nNeg1))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkScore nNeg1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 288 (list (cons 'nNeg100 nNeg100) (cons 'n101 n101) (cons 'nNeg1 nNeg1)) (lambda ()
                          (checkScore n101))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkScore n101"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 289 (list (cons 'nNeg100 nNeg100) (cons 'n101 n101) (cons 'nNeg1 nNeg1)) (lambda ()
                          (checkScore nNeg100))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkScore nNeg100"))
  )

  (test-case "checkTag validates non-empty short strings"
  (define n1 (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 293 (list) (lambda () 1)))
  (define tesl_checked_21 (checkScore n1))
  (when (check-fail? tesl_checked_21)
    (raise-user-error 'tesl-test "unexpected failure in let score: ~a" (check-fail-message tesl_checked_21)))
  (define score tesl_checked_21)
  (define tagA (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 295 (list (cons 'score score) (cons 'n1 n1)) (lambda () "a")))
  (define tagHello (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 296 (list (cons 'tagA tagA) (cons 'score score) (cons 'n1 n1)) (lambda () "hello")))
  (define tesl_checked_22 (checkTag tagA))
  (when (check-fail? tesl_checked_22)
    (raise-user-error 'tesl-test "unexpected failure in let t1: ~a" (check-fail-message tesl_checked_22)))
  (define t1 tesl_checked_22)
  (define tesl_checked_23 (checkTag tagHello))
  (when (check-fail? tesl_checked_23)
    (raise-user-error 'tesl-test "unexpected failure in let t2: ~a" (check-fail-message tesl_checked_23)))
  (define t2 tesl_checked_23)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 299 (list (cons 't2 t2) (cons 't1 t1) (cons 'tagHello tagHello) (cons 'tagA tagA) (cons 'score score) (cons 'n1 n1)) (lambda () (decomposeThenCall score t1)))) "tag: a = score: 1")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 300 (list (cons 't2 t2) (cons 't1 t1) (cons 'tagHello tagHello) (cons 'tagA tagA) (cons 'score score) (cons 'n1 n1)) (lambda () (decomposeThenCall score t2)))) "tag: hello = score: 1")
  )

  (test-case "checkTag rejects invalid strings"
  (define empty (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 304 (list) (lambda () "")))
  (define tooLong (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 305 (list (cons 'empty empty)) (lambda () "this-tag-is-way-too-long-to-be-valid")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 306 (list (cons 'tooLong tooLong) (cons 'empty empty)) (lambda ()
                          (checkTag empty))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTag empty"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson38-proof-decomposition.tesl" 307 (list (cons 'tooLong tooLong) (cons 'empty empty)) (lambda ()
                          (checkTag tooLong))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTag tooLong"))
  )

)
