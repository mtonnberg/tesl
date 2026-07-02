#lang racket

(require racket/string
         "../dsl/capability.rkt"
         "../dsl/check.rkt"
         "../dsl/otel.rkt"
         "../dsl/sql.rkt"
         "../dsl/web.rkt")

(provide DocumentAPI
         DocumentServer
         seed-state!
         current-doc-store
         current-task-store
         current-cache-store
         current-redis-healthy?
         resolve-example-port
         cookie-normal-auth-signature
         cookie-admin-auth-signature
         is-positive-signature
         is-safe-title-signature
         check-redis-health-signature
         attempt-cache-signature
         publish-doc-handler-signature
         get-task-handler-signature
         get-admin-task-handler-signature)

(define-capability redis)
(define-capability read-http-cookie)
(define-capability web-service (implies redis db-read db-write read-http-cookie))

(define current-doc-store (make-parameter (make-hash)))
(define current-task-store (make-parameter (make-hash)))
(define current-cache-store (make-parameter (make-hash)))
(define current-redis-healthy? (make-parameter #t))

(define (cache-result? value)
  (and (hash? value)
       (equal? (hash-ref value 'status #f) 'cached)
       (string? (hash-ref value 'docId #f))))

(define (new-document? value)
  (and (hash? value)
       (string? (hash-ref value 'title #f))))

(register-runtime-type! 'CacheResult cache-result?)
(register-runtime-type! 'UserId string?)
(register-runtime-type! 'NewDocument new-document?)


(define-entity Task
  #:source (lambda () (current-task-store))
  #:primary-key id
  [Id id : Integer]
  [Title title : String]
  [OwnerId ownerId : UserId]
  [Status status : String])

(define (seed-state!)
  (define tasks (make-hash))
  (hash-set! tasks 1 (hash 'id 1 'title "Pay invoices" 'ownerId "mikael" 'status "open"))
  (hash-set! tasks 2 (hash 'id 2 'title "Review audit log" 'ownerId "anna" 'status "open"))
  (current-task-store tasks)
  (current-doc-store (make-hash))
  (current-cache-store (make-hash))
  (current-redis-healthy? #t)
  (void))

(seed-state!)

(define (generate-doc-id)
  (format "doc-~a" (add1 (hash-count (current-doc-store)))))

(define (jsexpr-ref object key [default #f])
  (cond
    [(and (hash? object) (hash-has-key? object key))
     (hash-ref object key)]
    [(and (hash? object) (hash-has-key? object (symbol->string key)))
     (hash-ref object (symbol->string key))]
    [else default]))

(define default-example-port 8085)

(define (lookup-port-argument [args (vector->list (current-command-line-arguments))])
  (let loop ([remaining args])
    (cond
      [(null? remaining) #f]
      [(string-prefix? (car remaining) "--port=")
       (substring (car remaining) (string-length "--port="))]
      [(equal? (car remaining) "--port")
       (cond
         [(null? (cdr remaining))
          (raise-user-error 'document-api "`--port` requires a value")]
         [else
          (cadr remaining)])]
      [else
       (loop (cdr remaining))])))

(define (parse-port-string raw-port source)
  (define maybe-port (and raw-port (string->number raw-port)))
  (unless (and maybe-port
               (integer? maybe-port)
               (<= 1 maybe-port 65535))
    (raise-user-error 'document-api
                      (format "invalid ~a port value ~a; expected an integer between 1 and 65535"
                              source
                              raw-port)))
  maybe-port)

(define (resolve-example-port [args (vector->list (current-command-line-arguments))]
                              #:tesl-port [tesl-port (getenv "TESL_DOCUMENT_API_PORT")]
                              #:port [port-env (getenv "PORT")])
  (define cli-port (lookup-port-argument args))
  (cond
    [cli-port
     (parse-port-string cli-port "command-line")]
    [tesl-port
     (parse-port-string tesl-port "TESL_DOCUMENT_API_PORT")]
    [port-env
     (parse-port-string port-env "PORT")]
    [else
     default-example-port]))

(define (extract-cookie req key)
  (define cookie-header (or (request-header req "cookie" "") ""))
  (for/first ([part (in-list (map string-trim (string-split cookie-header ";")))]
              #:when (string-prefix? part (format "~a=" key)))
    (substring part (+ 1 (string-length key)))))

(define-auther
  (cookie-normal-auth [request : HttpRequest])
  #:capabilities [read-http-cookie]
  #:returns [requestUser : User ::: (Authenticated requestUser)]
  (define user-id (extract-cookie *request "user"))
  (if *user-id
      (accept Authenticated #:value (hash 'id *user-id 'role "user"))
      (reject "Missing or invalid user cookie" #:http-code 401)))

(define-auther
  (cookie-admin-auth [request : HttpRequest])
  #:capabilities [read-http-cookie]
  #:returns [requestUser : User ::: ((Authenticated requestUser) && (Admin requestUser))]
  (define user-id (extract-cookie *request "user"))
  (define role (extract-cookie *request "role"))
  (cond
    [(not *user-id)
     (reject "Missing or invalid user cookie" #:http-code 401)]
    [(not (equal? *role "admin"))
     (reject "Admin role required" #:http-code 403)]
    [else
     (accept AdminAuthenticated #:value (hash 'id *user-id 'role *role))]))

(define-checker
  (is-positive [num : Integer])
  #:returns [num : Integer ::: (Positive num)]
  (if (> *num 0)
      (accept (Positive num))
      (reject "Number must be strictly greater than zero" #:http-code 400)))

(define-checker
  (is-safe-title [title : String])
  #:returns [title : String ::: (TitleSafe title)]
  (if (and (string? *title)
           (<= (string-length *title) 100)
           (>= (string-length *title) 6))
      (accept (TitleSafe title))
      (reject "Title too short or too long" #:http-code 400)))

(define-trusted
  (published-document-result [docId : String]
                             [newDocument : NewDocument])
  #:returns
  (Exists [docId : String]
    (String ::: ((Published docId) && (CreatedWith newDocument docId))))
  (pack ([docId])
    (attach-proof
     (ensure-named docId *docId)
     (list (trusted-proof (Published docId))
           (trusted-proof (CreatedWith newDocument docId))))))

(define-trusted
  (owned-task-result [taskId : Integer ::: (Positive taskId)]
                     [task : Task ::: (FromDb [Id == taskId] task)])
  #:returns (Exists [userId : UserId]
              (? Task _entity ::: ((FromDb [Id == taskId] _entity) && (OwnedBy taskId userId))))
  (pack ([userId (hash-ref (raw-value task) 'ownerId)])
    (attach-proof task
                  (trusted-proof (OwnedBy taskId userId)))))

(define-capture positive-integer-capture
  [value : Integer ::: (Positive value)]
  #:parser integer-segment
  #:check is-positive)

(define-checker
  (check-redis-health)
  #:capabilities [redis]
  #:returns RedisAlive
  (if (current-redis-healthy?)
      (accept RedisAlive #:value #t)
      (reject "Redis unavailable" #:http-code 503)))

(define-trusted
  (attempt-cache [docId : String] [payload : NewDocument])
  #:capabilities [redis]
  #:returns (Maybe [cacheResult : CacheResult ::: ((Cached docId) && RedisAlive)])
  (if/check [redis-ok (check-redis-health)]
      (begin
        (hash-set! (current-cache-store) *docId *payload)
        (Something
         (attach-proof
          (attach-proof (ensure-named 'cacheResult
                                      (hash 'status 'cached
                                            'docId *docId))
                        (detach-proof redis-ok))
          (trusted-proof (Cached docId)))))
      Nothing))

(define-handler
  (publish-doc-handler [newDocument : NewDocument])
  #:capabilities [web-service]
  #:returns
  (Exists [docId : String]
    (String ::: ((Published docId)
                 && (CreatedWith newDocument docId))))
  (telemetry-event! "publish-doc.start"
                    #:attributes ([payload.kind "document"]))
  (define title (jsexpr-ref *newDocument 'title))
  (let/check ([title-ok (is-safe-title *title)])
    (define docId (generate-doc-id))
    (define cached? (attempt-cache *docId *newDocument))
    (define record
      (hash 'id *docId
            'title *title
            'body (jsexpr-ref *newDocument 'body "")
            'storage (if (Something? *cached?) "cache+db" "db-only")))
    (hash-set! (current-doc-store) *docId *record)
    (published-document-result docId newDocument)))

(define-handler
  (get-task-handler
    [requestUser : User ::: (Authenticated requestUser)]
    [taskId : Integer ::: (Positive taskId)])
  #:capabilities [db-read]
  #:returns (? Task _entity ::: (FromDb [Id == taskId] _entity))
  (telemetry-event! "task.fetch"
                    #:attributes ([user.id (hash-ref *requestUser 'id)]
                                  [task.id *taskId]))
  (let ([task (select-one (from Task)
                          (where (==. (Task-id) taskId)))])
    (cond
      [(not task)
       (reject "Task not found" #:http-code 404)]
      [(equal? (hash-ref (raw-value task) 'ownerId) (hash-ref *requestUser 'id))
       task]
      [else
       (reject "Task not owned by request user" #:http-code 403)])))

(define-handler
  (get-admin-task-handler
    [requestUser : User ::: ((Authenticated requestUser) && (Admin requestUser))]
    [taskId : Integer ::: (Positive taskId)])
  #:capabilities [db-read]
  #:returns (Exists [userId : UserId]
              (? Task _entity ::: ((FromDb [Id == taskId] _entity)
                         && (OwnedBy taskId userId))))
  (telemetry-event! "task.fetch.admin"
                    #:attributes ([user.id (hash-ref *requestUser 'id)]
                                  [task.id *taskId]))
  (let ([task (select-one (from Task)
                          (where (==. (Task-id) taskId)))])
    (if task
        (owned-task-result taskId task)
        (reject "Task not found" #:http-code 404))))

(define-api DocumentAPI
  [publish-doc :
    "docs"
    :> (ReqBody JSON [newDocument : NewDocument])
    :> (Post JSON
         (Exists [docId : String]
           (String ::: ((Published docId)
                        && (CreatedWith newDocument docId)))))]
  [get-task :
    (Auth [requestUser : User ::: (Authenticated requestUser)]
          #:via cookie-normal-auth)
    :> "tasks"
    :> (Capture positive-integer-capture
                [taskId : Integer ::: (Positive taskId)])
    :> (Get JSON
         (? Task _entity ::: (FromDb [Id == taskId] _entity)))]
  [get-admin-task :
    (Auth [requestUser : User ::: ((Authenticated requestUser) && (Admin requestUser))]
          #:via cookie-admin-auth)
    :> "tasks"
    :> "admin"
    :> (Capture positive-integer-capture
                [taskId : Integer ::: (Positive taskId)])
    :> (Get JSON
         (Exists [userId : UserId]
           (? Task _entity ::: ((FromDb [Id == taskId] _entity)
                      && (OwnedBy taskId userId)))))])

(define-server DocumentServer
  #:api DocumentAPI
  [publish-doc publish-doc-handler]
  [get-task get-task-handler]
  [get-admin-task get-admin-task-handler])

(module+ main
  (seed-state!)
  (init-opentelemetry! #:service-name "document-api" #:endpoint "in-memory" #:console? #t)
  (define port (resolve-example-port))
  (with-handlers ([exn:fail?
                   (lambda (exn)
                     (if (regexp-match? #rx"Address already in use" (exn-message exn))
                         (raise-user-error 'document-api
                                           (format "could not start the example API on port ~a; set TESL_DOCUMENT_API_PORT, PORT, or pass --port to choose another port"
                                                   port))
                         (raise exn)))])
    (serve DocumentServer #:port port #:capabilities (list web-service))))
