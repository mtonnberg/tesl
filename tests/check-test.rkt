#lang racket

(require rackunit
         racket/match
         "../dsl/capability.rkt"
         "../dsl/check.rkt"
         "../dsl/private/trusted.rkt"
         (only-in "../dsl/private/check-runtime.rkt"
                  [current-proof-env private:current-proof-env]))

(define-capability cache)

(define-checker
  (positive [n : Integer])
  #:returns [n : Integer ::: (Positive n)]
  (if (> *n 0)
      (accept (Positive n))
      (reject "not positive" #:http-code 400)))

(define-checker
  (cache-alive)
  #:capabilities [cache]
  #:returns CacheAlive
  (accept CacheAlive #:value #t))

(define-checker
  (cache-wrapper)
  #:returns CacheAlive
  (cache-alive))

(define-checker
  (cache-wrapper/declared)
  #:capabilities [cache]
  #:returns CacheAlive
  (cache-alive))

(define-checker
  (requires-integer [n : Integer])
  #:returns CacheAlive
  (accept CacheAlive #:value #t))

(define-checker
  (requires-positive-input [n : Integer ::: (Positive n)])
  #:returns [n : Integer ::: (Positive n)]
  (accept (Positive n) #:value *n))

(define-checker
  (cache-forwarder/inner)
  #:capabilities [cache]
  #:returns CacheAlive
  (cache-alive))

(define-checker
  (cache-forwarder/outer)
  #:returns CacheAlive
  (cache-forwarder/inner))

(define-checker
  (cache-forwarder/outer/declared)
  #:capabilities [cache]
  #:returns CacheAlive
  (cache-forwarder/inner))

(define positive-arg (first (signature-spec-args positive-signature)))
(define positive-result (positive 5))
(define positive-proof (detach-proof positive-result))
(define positive-proof-2 (detach-proof (positive 5)))
(define positive-name-token
  (match (detached-proof-fact positive-proof)
    [`(Positive ,token) token]
    [other (error 'test "unexpected positive proof shape: ~a" other)]))
(define named-y (ensure-named 'y -3))
(define attached-to-y (attach-proof named-y positive-proof))
(define attached-to-raw (attach-proof 6 positive-proof))
(define db-backed-task
  (attach-proof (ensure-named 'taskId 1)
                (list (trusted-proof (Positive taskId))
                      (trusted-proof (FromDb (Id == taskId))))))
(define owned-proof
  (parameterize ([private:current-proof-env (hash 'taskId 1 'userId "anna")])
    (trusted-proof (OwnedBy taskId userId))))
(define attached-owned (attach-proof 1 owned-proof))

(check-equal? (signature-spec-kind positive-signature) 'checker)
(check-equal? (signature-spec-name positive-signature) 'positive)
(check-equal? (signature-spec-returns positive-signature)
              '(n : Integer ::: (Positive n)))
(check-equal? (arg-spec-type positive-arg) 'Integer)
(check-equal? (arg-spec-proof positive-arg) #f)
(check-equal? (normalize-gdp-expr
               '((Authenticated requestUser)
                 &&
                 ((Admin requestUser) && (Authenticated requestUser))))
              '((Authenticated requestUser) && (Admin requestUser)))
(check-equal? (normalize-gdp-expr
               '((? Task taskId ::: (FromDb (Id == taskId)))
                 :::
                 (OwnedBy taskId userId)))
              '(? Task taskId ::: ((FromDb (Id == taskId)) && (OwnedBy taskId userId))))

(check-true (check-ok? positive-result))
(check-false (check-ok? (positive -1)))
(check-equal? (check-fail-status (positive -1)) 400)
(check-equal? (check-ok-facts positive-result)
              (list (detached-proof-fact positive-proof)))
(check-equal? (let/check ([proof (positive 1)]) 'ok) 'ok)
(check-equal? (let/check ([proof (positive -1)]) 'ok) (positive -1))
(check-equal? (if/check [proof (positive 3)] 'yes 'no) 'yes)
(check-equal? (if/check [proof (positive -3)] 'yes 'no) 'no)
(check-exn exn:fail:user? (lambda () (cache-alive)))
(check-exn
 (lambda (exn)
   (and (exn:fail:user? exn)
        (regexp-match? #rx"declared capability value" (exn-message exn))))
 (lambda ()
   (parameterize ([current-capabilities '(cache)])
     (cache-alive))))
(with-capabilities (cache)
  (check-true (check-ok? (cache-alive))))
;; NOTE: intra-call-tree capability narrowing is no longer a runtime mechanism.
;; The runtime call-with-declared-capabilities only CHECKS (never narrows), and
;; declaration discipline is enforced by the static checker. With `cache` present
;; in current-capabilities, calling cache-wrapper (which forwards to cache-alive)
;; succeeds at runtime; the old "current DSL context" error no longer fires here.
(with-capabilities (cache)
  (check-true (check-ok? (cache-wrapper))))
(with-capabilities (cache)
  (check-true (check-ok? (cache-wrapper/declared))))
;; NOTE: runtime type rejection on checker inputs has been removed (checker bodies
;; are erased; the parameter binds to the raw value). Input-type discipline is now a
;; compile-time guarantee, so (requires-integer "oops") no longer raises at runtime.
(check-true (check-ok? (requires-positive-input positive-result)))
(check-equal? (check-ok-value (requires-positive-input positive-result)) 5)
;; NOTE: transitive capability narrowing is likewise compile-time now; with `cache`
;; ambient, cache-forwarder/outer succeeds at runtime instead of raising.
(with-capabilities (cache)
  (check-true (check-ok? (cache-forwarder/outer))))
(with-capabilities (cache)
  (check-true (check-ok? (cache-forwarder/outer/declared))))

(check-true (detached-proof? positive-proof))
;; Under erasure the accept-minted proof carries the literal subject from the
;; (Positive n) fact form, so the token is the literal 'n.
(check-equal? positive-name-token 'n)
;; Accept-minted proof identity is no longer per-call-fresh under erasure: both
;; positive calls yield the same '(Positive n) fact.
(check-equal? (detached-proof-fact positive-proof)
              (detached-proof-fact positive-proof-2))
;; Accept-minted proofs no longer carry runtime bindings under erasure.
(check-true (hash-empty? (detached-proof-bindings positive-proof)))
(check-equal? (facts-of positive-proof) (list (detached-proof-fact positive-proof)))

(check-equal? (named-value-name attached-to-y) (named-value-name named-y))
(check-false (equal? (named-value-name attached-to-y) positive-name-token))
(check-equal? (facts-of attached-to-y) (list (detached-proof-fact positive-proof)))
;; The accept proof's subject is absent from the bindings; only the binding that
;; ensure-named adds for attached-to-y's own subject ('y -> -3) is present.
(check-false (hash-has-key? (named-value-bindings attached-to-y) positive-name-token))
(check-equal? (raw-value attached-to-y) -3)

(check-equal? (facts-of attached-to-raw) (list (detached-proof-fact positive-proof)))
(check-equal? (raw-value attached-to-raw) 6)
;; attached-to-raw's bindings only contain its own fresh subject -> 6 entry.
(check-false (hash-has-key? (named-value-bindings attached-to-raw) positive-name-token))

(check-exn exn:fail:user? (lambda () (detach-proof 1)))
(check-exn exn:fail:user? (lambda () (detach-proof "x")))
(check-exn exn:fail:user? (lambda () (detach-all-proof 1)))
(check-exn exn:fail:user?
           (lambda ()
             (let* ([named (ensure-named 'forged 5)]
                    [subject (named-value-name named)]
                    [forged-proof (detach-proof `(Positive ,subject))])
               (requires-positive-input (attach-proof named forged-proof)))))

; detachFact on a value with multiple proofs now returns the conjunction
; instead of raising an error.  Verify the combined fact is returned.
(check-true (detached-proof? (detach-proof db-backed-task)))
(check-equal? (normalize-gdp-expr (detached-proof-fact (detach-proof db-backed-task)))
              (normalize-gdp-expr '((Positive taskId) && (FromDb (Id == taskId)))))
(check-equal? (detached-proof-fact (detach-proof db-backed-task (FromDb (Id == taskId))))
              '(FromDb (Id == taskId)))
(check-equal? (facts-of attached-owned) '((OwnedBy taskId userId)))
(check-equal? (hash-ref (named-value-bindings attached-owned) 'taskId) 1)
(check-equal? (hash-ref (named-value-bindings attached-owned) 'userId) "anna")


(define packed-user
  (pack ([userId "anna"])
    (list userId *userId)))
(define packed-user-witness (first (packed-exists-witnesses packed-user)))

(check-true (packed-exists? packed-user))
(check-equal? (packed-witness-public-name packed-user-witness) 'userId)
(check-equal? (raw-value (packed-witness-value packed-user-witness)) "anna")
(match (packed-exists-body packed-user)
  [(list token raw)
   (check-true (symbol? token))
   (check-false (eq? token 'userId))
   (check-equal? raw "anna")]
  [other
   (error 'test "unexpected packed body shape: ~a" other)])

(define packed-user-id
  (pack ([userId "anna"])
    *userId))

(define packed-tagged-user
  (pack ([userId "anna"])
    (attach-proof (ensure-named userId *userId)
                  (trusted-proof (Tagged userId)))))

(define repacked-tagged-user
  (unpack packed-tagged-user ([userId] value)
    (pack ([userId]) value)))

(check-equal? (unpack packed-user-id ([userId] value)
                (list *userId value *value))
              '("anna" "anna" "anna"))

(check-equal? (let-exists ([([userId] value) packed-user-id])
                (string-append *userId ":" *value))
              "anna:anna")

(check-equal? (unpack packed-tagged-user ([userId] value)
                (let ([proof (detach-proof value (Tagged userId))])
                  (list *userId (detached-proof? proof) *value)))
              '("anna" #t "anna"))

(check-true (packed-exists? repacked-tagged-user))
(check-equal? (unpack repacked-tagged-user ([userId] value)
                (let ([proof (detach-proof value (Tagged userId))])
                  (list *userId (detached-proof? proof) *value)))
              '("anna" #t "anna"))

(check-exn (lambda (exn)
             (and (exn:fail:user? exn)
                  (regexp-match? #rx"Skolem escape" (exn-message exn))))
           (lambda ()
             (unpack packed-user-id ([userId] value)
               userId)))

(check-exn (lambda (exn)
             (and (exn:fail:user? exn)
                  (regexp-match? #rx"Skolem escape" (exn-message exn))))
           (lambda ()
             (unpack packed-tagged-user ([userId] value)
               (detach-proof value (Tagged userId)))))

(check-exn (lambda (exn)
             (and (exn:fail:user? exn)
                  (regexp-match? #rx"opaque values" (exn-message exn))))
           (lambda ()
             (unpack packed-user-id ([userId] value)
               (lambda () *userId))))


(define cache-proof (trusted-proof CacheAlive))
(define positive-and-cache (intro-and positive-proof cache-proof))
(define positive-subject (ensure-named positive-name-token (raw-value positive-result)))
(define positive-with-combined-proof
  (attach-proof positive-subject positive-and-cache))

(check-equal? (detached-proof-fact positive-and-cache)
              (list (detached-proof-fact positive-proof) '&& 'CacheAlive))
(check-equal? (detached-proof-fact (and-left positive-and-cache))
              (detached-proof-fact positive-proof))
(check-equal? (detached-proof-fact (and-right positive-and-cache))
              'CacheAlive)
(check-equal? (detached-proof-fact (detach-all-proof positive-with-combined-proof))
              (list (detached-proof-fact positive-proof) '&& 'CacheAlive))
(check-true (check-ok? (requires-positive-input positive-with-combined-proof)))
