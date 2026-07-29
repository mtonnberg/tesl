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
  (only-in tesl/tesl/prelude String)
)


(provide UserId ProjectId Email makeUserId makeProjectId userId projectId emailAddress makeUserId-signature makeProjectId-signature userId-signature projectId-signature emailAddress-signature)

(define-newtype UserId String)

(define-newtype ProjectId String)

(define-newtype Email String)

(define/pow
  (makeUserId [raw : String])
  #:returns UserId
  (thsl-src! "example/learn/lesson04-newtypes.tesl" 34 (list (cons 'raw *raw)) (lambda () (raw-value (UserId *raw)))))

(define/pow
  (makeProjectId [raw : String])
  #:returns ProjectId
  (thsl-src! "example/learn/lesson04-newtypes.tesl" 38 (list (cons 'raw *raw)) (lambda () (raw-value (ProjectId *raw)))))

(define/pow
  (userId [id : UserId])
  #:returns String
  (thsl-src! "example/learn/lesson04-newtypes.tesl" 42 (list (cons 'id *id)) (lambda () (raw-value id.value))))

(define/pow
  (projectId [id : ProjectId])
  #:returns String
  (thsl-src! "example/learn/lesson04-newtypes.tesl" 46 (list (cons 'id *id)) (lambda () (raw-value id.value))))

(define/pow
  (emailAddress [email : Email])
  #:returns String
  (thsl-src! "example/learn/lesson04-newtypes.tesl" 50 (list (cons 'email *email)) (lambda () (raw-value email.value))))

(module+ test
  (require rackunit)
  (test-case "makeUserId round-trips"
    (call-with-fresh-memory-db '() (lambda ()
  (define uid (thsl-src! "example/learn/lesson04-newtypes.tesl" 103 (list) (lambda () (makeUserId "user-123"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson04-newtypes.tesl" 104 (list (cons 'uid uid)) (lambda () (userId uid)))) "user-123")
    ))
  )

  (test-case "makeProjectId round-trips"
    (call-with-fresh-memory-db '() (lambda ()
  (define pid (thsl-src! "example/learn/lesson04-newtypes.tesl" 108 (list) (lambda () (makeProjectId "proj-456"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson04-newtypes.tesl" 109 (list (cons 'pid pid)) (lambda () (projectId pid)))) "proj-456")
    ))
  )

)
