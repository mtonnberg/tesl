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
  (only-in tesl/tesl/prelude String)
)


(provide UserId ProjectId Email makeUserId makeProjectId userId projectId emailAddress makeUserId-signature makeProjectId-signature userId-signature projectId-signature emailAddress-signature)

(define-newtype UserId String)

(define-newtype ProjectId String)

(define-newtype Email String)

(define/pow
  (makeUserId [raw : String])
  #:returns UserId
  (raw-value (UserId *raw)))

(define/pow
  (makeProjectId [raw : String])
  #:returns ProjectId
  (raw-value (ProjectId *raw)))

(define/pow
  (userId [id : UserId])
  #:returns String
  (raw-value id.value))

(define/pow
  (projectId [id : ProjectId])
  #:returns String
  (raw-value id.value))

(define/pow
  (emailAddress [email : Email])
  #:returns String
  (raw-value email.value))

(module+ test
  (require rackunit)
  (test-case "makeUserId round-trips"
  (define uid (makeUserId "user-123"))
  (check-equal? (raw-value (userId uid)) "user-123")
  )

  (test-case "makeProjectId round-trips"
  (define pid (makeProjectId "proj-456"))
  (check-equal? (raw-value (projectId pid)) "proj-456")
  )

)
