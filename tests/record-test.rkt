#lang racket

(require json
         rackunit
         racket/file
         racket/match
         racket/runtime-path
         "../dsl/capability.rkt"
         "../dsl/sql.rkt"
         "../dsl/types.rkt"
         "../dsl/web.rkt"
         (only-in "../dsl/check.rkt"
                  define-checker
                  accept
                  reject
                  raw-value
                  facts-of
                  named-value?
                  check-fail?
                  check-fail-message
                  check-fail-status))

(define-runtime-path sql-rkt "../dsl/sql.rkt")
(define-runtime-path web-rkt "../dsl/web.rkt")
(define-runtime-path check-rkt "../dsl/check.rkt")

(define (run-temp-module source [provided #f])
  (define temp-path (make-temporary-file "tesl-record-test-~a.rkt"))
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

(define (call-with-temp-module-dir proc)
  (define dir (make-temporary-file "tesl-record-modules-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (proc dir))
    (lambda ()
      (when (directory-exists? dir)
        (delete-directory/files dir)))))

(define (write-module path content)
  (call-with-output-file path
    (lambda (out)
      (display content out))
    #:exists 'replace))

(define-record RecordUser
  [id : String]
  [role : String])

(define-record RecordEnvelope
  [title : String]
  [author : RecordUser])

(define-checker
  (positive-integer [n : Integer])
  #:returns [n : Integer ::: (Positive n)]
  (if (> *n 0)
      (accept (Positive n))
      (reject "not positive" #:http-code 400)))

(define-record PositiveCount
  [count : Integer ::: (Positive count) #:check positive-integer])

(define-record ProofOnlyCount
  [count : Integer ::: (Positive count)])

(define-adt TestStatus
  [Open]
  [Done])

(define sample-user
  (RecordUser #:id "mikael" #:role "admin"))

(define sample-envelope
  (RecordEnvelope #:title "Roadmap" #:author sample-user))

(check-not-false (lookup-record-spec 'RecordUser #f))
(check-not-false (lookup-field-access-spec 'RecordUser #f))
(check-true (RecordUser? sample-user))
(check-true (RecordEnvelope? sample-envelope))
(check-equal? (runtime-value->jsexpr sample-user)
              (hash 'id "mikael" 'role "admin"))
(check-equal? (runtime-value->jsexpr sample-envelope)
              (hash 'title "Roadmap"
                    'author (hash 'id "mikael" 'role "admin")))
(check-true (RecordUser? (jsexpr->typed-value 'RecordUser
                                           (hash 'id "mikael" 'role "admin"))))
(check-true (RecordEnvelope?
             (jsexpr->typed-value 'RecordEnvelope
                                 (hash 'title "Roadmap"
                                       'author (hash 'id "mikael" 'role "admin")))))
(check-equal? (field-access-ref sample-user 'id #f 'record-test) "mikael")
(check-equal? (runtime-value->jsexpr (field-access-ref sample-envelope 'author #f 'record-test))
              (hash 'id "mikael" 'role "admin"))

(define positive-count (PositiveCount #:count 5))
(define positive-count-from-proof (ProofOnlyCount #:count (positive-integer 7)))
(define positive-count-field (field-access-ref positive-count 'count #f 'record-test))
(define decoded-positive-count (jsexpr->typed-value 'PositiveCount (hash 'count 8) 'record-test))
(define decoded-positive-count-field (field-access-ref decoded-positive-count 'count #f 'record-test))
(define failed-positive-count-json
  (jsexpr->typed-value/result 'PositiveCount (hash 'count 0) 'record-test))
(define failed-proof-only-json
  (jsexpr->typed-value/result 'ProofOnlyCount (hash 'count 5) 'record-test))

(check-true (PositiveCount? positive-count))
(check-true (ProofOnlyCount? positive-count-from-proof))
(check-true (named-value? positive-count-field))
(check-equal? (raw-value positive-count-field) 5)
(match (facts-of positive-count-field)
  [`((Positive ,subject))
   (check-true (symbol? subject))]
  [other
   (error 'test (format "unexpected positive-count facts: ~a" other))])
(check-true (named-value? decoded-positive-count-field))
(check-equal? (raw-value decoded-positive-count-field) 8)
(check-equal? (runtime-value->jsexpr decoded-positive-count) (hash 'count 8))
(check-true (check-fail? failed-positive-count-json))
(check-equal? (check-fail-status failed-positive-count-json) 400)
(check-true (regexp-match? #rx"not positive" (check-fail-message failed-positive-count-json)))
(check-true (check-fail? failed-proof-only-json))
(check-equal? (check-fail-status failed-proof-only-json) 400)
(check-true (regexp-match? #rx"explicit #:check" (check-fail-message failed-proof-only-json)))

(check-exn (exn-message-matches? #rx"failed proof check: not positive")
           (lambda ()
             (PositiveCount #:count 0)))
(define raw-proof-only-count (ProofOnlyCount #:count 5))
(check-true (ProofOnlyCount? raw-proof-only-count))
(check-equal? (field-access-ref raw-proof-only-count 'count #f 'record-test) 5)

(check-exn (exn-message-matches? #rx"expected field id on record RecordUser to satisfy type String")
           (lambda ()
             (RecordUser #:id 1 #:role "admin")))
(check-exn (exn-message-matches? #rx"record JSON for type RecordUser is missing field")
           (lambda ()
             (jsexpr->typed-value 'RecordUser (hash 'id "mikael"))))
(check-exn (exn-message-matches? #rx"record JSON for type RecordUser has unexpected field")
           (lambda ()
             (jsexpr->typed-value 'RecordUser
                                 (hash 'id "mikael"
                                       'role "admin"
                                       'extra #t))))
(check-exn (exn-message-matches? #rx"dot access is only supported on declared record/entity values")
           (lambda ()
             (field-access-ref 1 'id #f 'record-test)))
(check-exn (exn-message-matches? #rx"dot access is only supported on declared record/entity values")
           (lambda ()
             (field-access-ref Open 'id #f 'record-test)))
(check-exn (exn-message-matches? #rx"unknown field")
           (lambda ()
             (field-access-ref sample-user 'name #f 'record-test)))

(define lowered-dot-module
  (format #<<MODULE
#lang racket
(require (file ~s))
(define-record LoweredPerson
  [id : String])
(define-adt LoweredStatus
  [Open]
  [Done])
(define/pow
  (record-dot)
  #:returns String
  (define user (LoweredPerson #:id "anna"))
  user.id)
(define/pow
  (scalar-dot)
  #:returns Any
  (define n 1)
  n.id)
(define/pow
  (adt-dot)
  #:returns Any
  Open.id)
(define/pow
  (unknown-dot)
  #:returns Any
  (define user (LoweredPerson #:id "anna"))
  user.name)
(define exports
  (hash 'record-dot record-dot
        'scalar-dot scalar-dot
        'adt-dot adt-dot
        'unknown-dot unknown-dot))
(provide exports)
MODULE
          (path->string web-rkt)))

(define lowered-dot-exports
  (run-temp-module lowered-dot-module 'exports))

(check-equal? ((hash-ref lowered-dot-exports 'record-dot)) "anna")
(check-exn (exn-message-matches? #rx"dot access is only supported on declared record/entity values")
           (lambda ()
             ((hash-ref lowered-dot-exports 'scalar-dot))))
(check-exn (exn-message-matches? #rx"dot access is only supported on declared record/entity values")
           (lambda ()
             ((hash-ref lowered-dot-exports 'adt-dot))))
(check-exn (exn-message-matches? #rx"unknown field")
           (lambda ()
             ((hash-ref lowered-dot-exports 'unknown-dot))))

(define no-record-accessor-module
  (format #<<MODULE
#lang racket
(require (file ~s))
(define-record NoAccessorPerson
  [id : String])
(NoAccessorPerson-id)
MODULE
          (path->string web-rkt)))

(check-exn (exn-message-matches? #rx"NoAccessorPerson-id")
           (lambda ()
             (run-temp-module no-record-accessor-module #f)))

(define request-body-module
  (format #<<MODULE
#lang racket
(require (file ~s) (file ~s))
(define current-request-task-rows
  (make-parameter
   (make-hash
    (list (cons 1 (hash 'id 1 'title "Pay invoices" 'ownerId "mikael"))))))
(define-record RequestTodo
  [title : String])
(define-entity RequestTask
  #:source (lambda () (current-request-task-rows))
  #:primary-key id
  [Id id : Integer]
  [Title title : String]
  [OwnerId ownerId : String])
(define/pow
  (selected-owner)
  #:capabilities [db-read]
  #:returns String
  (define task
    (select-one (from RequestTask)
                (where (==. (RequestTask-id) 1))))
  task.ownerId)
(define-handler
  (echo-title [newTodo : RequestTodo])
  #:returns String
  newTodo.title)
(define-api DotAPI
  [echo-title :
    "todos"
    :> (ReqBody JSON [newTodo : RequestTodo])
    :> (Post JSON String)])
(define-server DotServer
  #:api DotAPI
  [echo-title echo-title])
(define exports
  (hash 'selected-owner selected-owner
        'DotServer DotServer))
(provide exports)
MODULE
          (path->string web-rkt)
          (path->string sql-rkt)))

(define request-body-exports
  (run-temp-module request-body-module 'exports))

(check-equal? (with-capabilities (db-read) ((hash-ref request-body-exports 'selected-owner))) "mikael")

(define request-body-response
  (dispatch-request
   (hash-ref request-body-exports 'DotServer)
   (make-request 'POST
                 '("todos")
                 #:headers (hash "content-type" "application/json")
                 #:body (jsexpr->bytes (hash 'title "Ship migrations")))
   #:capabilities '()))

(check-equal? (dsl-response-status request-body-response) 200)
(check-equal? (dsl-response-body request-body-response) "Ship migrations")


(define proof-request-body-module
  (format #<<MODULE
#lang racket
(require (file ~s) (file ~s))
(define-checker
  (positive [n : Integer])
  #:returns [n : Integer ::: (Positive n)]
  (if (> *n 0)
      (accept (Positive n))
      (reject "not positive" #:http-code 400)))
(define-record ProofRequestTodo
  [priority : Integer ::: (Positive priority) #:check positive])
(define-handler
  (echo-priority [newTodo : ProofRequestTodo])
  #:returns Integer
  newTodo.priority)
(define-api ProofRequestAPI
  [echo-priority :
    "priorities"
    :> (ReqBody JSON [newTodo : ProofRequestTodo])
    :> (Post JSON Integer)])
(define-server ProofRequestServer
  #:api ProofRequestAPI
  [echo-priority echo-priority])
(provide ProofRequestServer)
MODULE
          (path->string check-rkt)
          (path->string web-rkt)))

(define proof-request-server
  (run-temp-module proof-request-body-module 'ProofRequestServer))

(define proof-request-success
  (dispatch-request
   proof-request-server
   (make-request 'POST
                 '("priorities")
                 #:headers (hash "content-type" "application/json")
                 #:body (jsexpr->bytes (hash 'priority 6)))
   #:capabilities '()))

(define proof-request-failure
  (dispatch-request
   proof-request-server
   (make-request 'POST
                 '("priorities")
                 #:headers (hash "content-type" "application/json")
                 #:body (jsexpr->bytes (hash 'priority 0)))
   #:capabilities '()))

(check-equal? (dsl-response-status proof-request-success) 200)
(check-equal? (dsl-response-body proof-request-success) 6)
(check-equal? (dsl-response-status proof-request-failure) 400)
(check-true (regexp-match? #rx"not positive" (hash-ref (dsl-response-body proof-request-failure) 'error)))


(call-with-temp-module-dir
 (lambda (dir)
   (define alpha-path (build-path dir "alpha.rkt"))
   (define beta-path (build-path dir "beta.rkt"))
   (define consumer-path (build-path dir "consumer.rkt"))
   (define permissive-path (build-path dir "permissive.rkt"))

   (write-module
    alpha-path
    (format #<<MODULE
#lang racket
(require (file ~s))
(define-record User
  [id : String])
(define (make-alpha-user)
  (User #:id "alpha"))
(provide User make-alpha-user)
MODULE
            (path->string web-rkt)))

   (write-module
    beta-path
    (format #<<MODULE
#lang racket
(require (file ~s))
(define-record User
  [id : Integer])
(define (make-beta-user)
  (User #:id 7))
(provide User make-beta-user)
MODULE
            (path->string web-rkt)))

   (write-module
    consumer-path
    (format #<<MODULE
#lang racket
(require (rename-in (file ~s)
                    [User AlphaUser]
                    [make-alpha-user make-alpha-user])
         (rename-in (file ~s)
                    [User BetaUser]
                    [make-beta-user make-beta-user])
         (file ~s))
(define/pow
  (accept-alpha [user : AlphaUser])
  #:returns Boolean
  #t)
(define/pow
  (accept-beta [user : BetaUser])
  #:returns Boolean
  #t)
(provide accept-alpha accept-beta make-alpha-user make-beta-user)
MODULE
            (path->string alpha-path)
            (path->string beta-path)
            (path->string web-rkt)))

   (write-module
    permissive-path
    (format #<<MODULE
#lang racket
(require (file ~s))
(define/pow
  (accept-local-user [user : User])
  #:returns Boolean
  #t)
(provide accept-local-user)
MODULE
            (path->string web-rkt)))

   (dynamic-require alpha-path #f)
   (dynamic-require beta-path #f)

   (define accept-alpha (dynamic-require consumer-path 'accept-alpha))
   (define accept-beta (dynamic-require consumer-path 'accept-beta))
   (define make-alpha-user (dynamic-require consumer-path 'make-alpha-user))
   (define make-beta-user (dynamic-require consumer-path 'make-beta-user))
   (define accept-local-user (dynamic-require permissive-path 'accept-local-user))

   (check-true (accept-alpha (make-alpha-user)))
   (check-true (accept-beta (make-beta-user)))
   (check-exn (exn-message-matches? #rx"declared type User")
              (lambda ()
                (accept-alpha (make-beta-user))))
   (check-exn (exn-message-matches? #rx"declared type User")
              (lambda ()
                (accept-beta (make-alpha-user))))
   (check-true (accept-local-user (hash 'id "plain-user")))))
