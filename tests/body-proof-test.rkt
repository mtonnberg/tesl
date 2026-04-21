#lang racket

(require rackunit
         rackunit/text-ui
         racket/match
         racket/runtime-path
         "../dsl/check.rkt"
         "../dsl/private/trusted.rkt")

(provide body-proof-suite)

(define-runtime-path check-rkt "../dsl/check.rkt")
(define-runtime-path web-rkt "../dsl/web.rkt")
(define-runtime-path private-trusted-rkt "../dsl/private/trusted.rkt")

(define (run-temp-module source [provided #f])
  (define temp-path (make-temporary-file "tesl-body-proof-test-~a.rkt"))
  (call-with-output-file temp-path
    (lambda (out)
      (display source out))
    #:exists 'replace)
  (dynamic-wind
    void
    (lambda ()
      (dynamic-require temp-path provided))
    (lambda ()
      (when (file-exists? temp-path)
        (delete-file temp-path)))))

(define (exn-message-matches? rx)
  (lambda (exn)
    (and (exn:fail? exn)
         (regexp-match? rx (exn-message exn)))))

(define positive-checker-source
  "(define-checker
  (positive [n : Integer])
  #:returns [n : Integer ::: (Positive n)]
  (if (> *n 0)
      (accept (Positive n))
      (reject \"not positive\" #:http-code 400)))\n")

(define cross-name-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define-trusted
  (cross-proof [source : Integer])
  #:returns [target : Integer ::: (Positive source)]
  (let ([proof (trusted-proof (Positive source))])
    (attach-proof (ensure-named 'target 99)
                  proof)))
(define result (cross-proof 5))
(provide result)
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define local-checker-scope-module
  (format "#lang racket
(require (file ~s))
(define-checker
  (local-positive)
  #:returns [value : Integer ::: (Positive value)]
  (let ([value 7])
    (accept (Positive value) #:value *value)))
(define result (local-positive))
(provide result)
"
          (path->string check-rkt)))

(define invalid-accept-unbound-module
  (format "#lang racket
(require (file ~s))
(define-checker
  (bad-local)
  #:returns [value : Integer ::: (Positive value)]
  (let ([value 7])
    (accept (Positive missing) #:value *value)))
"
          (path->string check-rkt)))

(define invalid-branch-leak-module
  (format "#lang racket
(require (file ~s))
~a
(define-checker
  (branchy [n : Integer])
  #:returns [n : Integer ::: (Positive n)]
  (if/check [checked (positive n)]
    checked
    (accept (Positive checked) #:value *n)))
"
          (path->string check-rkt)
          positive-checker-source))

(define invalid-trusted-proof-unbound-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define-trusted
  (bad-trusted [source : Integer])
  #:returns [target : Integer ::: (Positive source)]
  (let ([target 99])
    (attach-proof (ensure-named 'target *target)
                  (trusted-proof (Positive missing)))))
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define invalid-detach-unbound-module
  (format "#lang racket
(require (file ~s))
~a
(define-checker
  (bad-detach [n : Integer])
  #:returns [n : Integer ::: (Positive n)]
  (let/check ([checked (positive n)])
    (detach-proof checked (Positive missing))
    checked))
"
          (path->string check-rkt)
          positive-checker-source))

(define invalid-unpack-unbound-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define packed
  (pack ([label \"ok\"])
    (attach-proof (ensure-named 'payload 1)
                  (trusted-proof (Tagged label)))))
(unpack packed ([label] value)
  (detach-proof value (Tagged missing)))
"
          (path->string check-rkt)
          (path->string private-trusted-rkt)))

(define reattached-proof-module
  (format "#lang racket
(require (file ~s) (file ~s))
~a
(define/pow
  (needs-positive [value : Integer ::: (Positive value)])
  #:returns Integer
  *value)
(define forged
  (attach-proof 0 (detach-proof (positive 5))))
(define result
  (needs-positive forged))
(provide result)
"
          (path->string check-rkt)
          (path->string web-rkt)
          positive-checker-source))

(define packed-user-id
  (pack ([userId "anna"])
    *userId))

(define packed-tagged-payload
  (pack ([userId "anna"])
    (attach-proof (ensure-named 'payload 1)
                  (trusted-proof (Tagged userId)))))

(define sequential-packed
  (pack ([first "anna"]
         [second first])
    (list *first *second)))

(define body-proof-suite
  (test-suite
   "body proof regressions"
   (test-case "cross-name proof attachment inside define-trusted is legal"
     (define cross-result (run-temp-module cross-name-module 'result))
     (check-equal? (raw-value cross-result) 99)
     (check-true (symbol? (named-value-name cross-result)))
     (define proof (detach-proof cross-result))
     (define fact (detached-proof-fact proof))
     (define bindings (detached-proof-bindings proof))
     (match fact
       [`(Positive ,subject)
        (check-true (symbol? subject))
        (check-false (equal? subject (named-value-name cross-result)))
        (check-equal? (hash-ref bindings subject) 5)]
       [other
        (error 'test "unexpected cross-name proof shape: ~a" other)]))
   (test-case "checker with no args may use a local binder in an accept proof template"
     (define result (run-temp-module local-checker-scope-module 'result))
     (check-true (check-ok? result))
     (check-equal? (check-ok-value result) 7)
     (define proof (detach-proof result))
     (define fact (detached-proof-fact proof))
     (define bindings (detached-proof-bindings proof))
     (match fact
       [`(Positive ,subject)
        (check-true (symbol? subject))
        (check-equal? (hash-ref bindings subject) 7)]
       [other
        (error 'test "unexpected local checker proof shape: ~a" other)]))
   (test-case "accept rejects unbound proof names in checker bodies"
     (check-exn (exn-message-matches? #rx"unbound GDP name.*proof template")
                (lambda () (run-temp-module invalid-accept-unbound-module))))
   (test-case "if/check does not leak the success binder into the else branch proof template"
     (check-exn (exn-message-matches? #rx"unbound GDP name.*proof template")
                (lambda () (run-temp-module invalid-branch-leak-module))))
   (test-case "trusted-proof rejects unbound proof names in define-trusted bodies"
     (check-exn (exn-message-matches? #rx"unbound GDP name.*proof template")
                (lambda () (run-temp-module invalid-trusted-proof-unbound-module))))
   (test-case "detach-proof rejects unbound proof names in checker bodies"
     (check-exn (exn-message-matches? #rx"unbound GDP name.*proof template")
                (lambda () (run-temp-module invalid-detach-unbound-module))))
   (test-case "detach-proof rejects unbound proof names inside unpack bodies"
     (check-exn (exn-message-matches? #rx"unbound GDP name.*proof template")
                (lambda () (run-temp-module invalid-unpack-unbound-module))))
   (test-case "unpack can detach a proof using the original existential witness name"
     (check-equal?
      (unpack packed-tagged-payload ([userId] value)
        (let ([proof (detach-proof value (Tagged userId))])
          (list *userId (detached-proof? proof) *value)))
      '("anna" #t 1)))
   (test-case "later existential witness expressions may depend on earlier witnesses"
     (check-equal?
      (unpack sequential-packed ([first second] value)
        (list *first *second *value))
      '("anna" "anna" ("anna" "anna"))))
   (test-case "shadowing a proof name does not retarget the attached proof"
     (check-exn (exn-message-matches? #rx"is not attached")
                (lambda ()
                  (unpack packed-tagged-payload ([userId] value)
                    (let ([userId "bob"])
                      (detach-proof value (Tagged userId)))))))
   (test-case "attach-proof rejects plain fact lists"
     (check-exn (exn-message-matches? #rx"detached proof")
                (lambda ()
                  (attach-proof 5 '(Positive userId)))))
   (test-case "attach-proof rejects mixed detached-proof and non-proof lists"
     (check-exn (exn-message-matches? #rx"detached proof")
                (lambda ()
                  (attach-proof 5 (list (detach-proof (run-temp-module cross-name-module 'result))
                                        '(Positive userId))))))
   (test-case "reattached detached proofs do not satisfy proof-annotated define/pow inputs"
     (check-exn (exn-message-matches? #rx"declared proof")
                (lambda ()
                  (run-temp-module reattached-proof-module 'result))))
   (test-case "unpack rejects list-based hidden witness escapes"
     (check-exn (exn-message-matches? #rx"Skolem escape")
                (lambda ()
                  (unpack packed-user-id ([userId] value)
                    (list userId)))))
   (test-case "unpack rejects vector-based hidden witness escapes"
     (check-exn (exn-message-matches? #rx"Skolem escape")
                (lambda ()
                  (unpack packed-user-id ([userId] value)
                    (vector userId)))))
   (test-case "unpack rejects box-based hidden witness escapes"
     (check-exn (exn-message-matches? #rx"Skolem escape")
                (lambda ()
                  (unpack packed-user-id ([userId] value)
                    (box userId)))))
   (test-case "unpack rejects hash-based hidden witness escapes"
     (check-exn (exn-message-matches? #rx"Skolem escape")
                (lambda ()
                  (unpack packed-user-id ([userId] value)
                    (hash 'id userId)))))
   (test-case "raw list results are allowed after unpack"
     (check-equal?
      (unpack packed-user-id ([userId] value)
        (list *userId))
      '("anna")))
   (test-case "raw vector results are allowed after unpack"
     (check-equal?
      (unpack packed-user-id ([userId] value)
        (vector *userId))
      '#("anna")))
   (test-case "raw box results are allowed after unpack"
     (check-equal?
      (unpack packed-user-id ([userId] value)
        (box *userId))
      (box "anna")))
   (test-case "raw hash results are allowed after unpack"
     (check-equal?
      (unpack packed-user-id ([userId] value)
        (hash 'id *userId))
      (hash 'id "anna")))))

(module+ main
  (define failures (run-tests body-proof-suite))
  (unless (zero? failures)
    (error 'body-proof-test (format "~a body-proof regression tests are failing" failures))))
