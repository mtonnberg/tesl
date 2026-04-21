#lang racket

(require json
         rackunit
         racket/file
         racket/port
         racket/runtime-path
         racket/string
         "../example/bookmark-api.rkt"
         "../dsl/capability.rkt"
         "../dsl/sql.rkt"
         "../dsl/web.rkt"
         "private/postgres-test-support.rkt")

(define-runtime-path bookmark-api-path "../example/bookmark-api.rkt")
(define-runtime-path tesl-compiler-path "../compiler/_build/default/bin/main.exe")
(define-runtime-path todo-api-source-path "../example/todo-api.tesl")

(define (with-env bindings thunk)
  (define saved
    (for/list ([binding (in-list bindings)])
      (define key (car binding))
      (cons key (getenv key))))
  (dynamic-wind
    (lambda ()
      (for ([binding (in-list bindings)])
        (putenv (car binding) (cdr binding))))
    thunk
    (lambda ()
      (for ([binding (in-list saved)])
        (define key (car binding))
        (define value (cdr binding))
        (if value
            (putenv key value)
            (putenv key ""))))))

(define (dispatch-with-server server capabilities method path #:cookie [cookie #f] #:body [body #f])
  (dispatch-request
   server
   (make-request method
                 path
                 #:headers (cond
                             [(and cookie body)
                              (hash "cookie" cookie
                                    "content-type" "application/json")]
                             [cookie
                              (hash "cookie" cookie)]
                             [body
                              (hash "content-type" "application/json")]
                             [else
                              (hash)])
                 #:body (if body (jsexpr->bytes body) #""))
   #:capabilities capabilities))

(define (module-private-value module-path symbol-name)
  (dynamic-require `(file ,(path->string module-path)) #f)
  (parameterize ([current-namespace (module->namespace `(file ,(path->string module-path)))])
    (namespace-variable-value
     symbol-name
     #t
     (lambda ()
       (error 'example-api-test "missing internal binding ~a in ~a" symbol-name module-path)))))

(define (write-temp-file pattern contents)
  (define output-path (make-temporary-file pattern))
  (call-with-output-file output-path
    #:exists 'truncate
    (lambda (out)
      (display contents out)))
  output-path)

(define (run-command executable args)
  (define-values (proc stdout stdin stderr)
    (apply subprocess #f #f #f (path->string executable) args))
  (close-output-port stdin)
  (define out (port->string stdout))
  (define err (port->string stderr))
  (subprocess-wait proc)
  (values (subprocess-status proc) out err))

(define (compile-tesl-module source-path)
  (define-values (status generated errors)
    (run-command tesl-compiler-path
                 (list (path->string source-path))))
  (unless (zero? status)
    (error 'example-api-test
           (string-append "tesl compiler failed: "
                          (if (string=? (string-trim errors) "")
                              "no compiler stderr"
                              (string-trim errors)))))
  (write-temp-file "tesl-example-api-test-~a.rkt" generated))

(define todo-api-module-path
  (compile-tesl-module todo-api-source-path))

(define bookmark-web-service (module-private-value bookmark-api-path 'bookmark-web-service))

(define (run-bookmark-tests)
  (seed-state!)

  (define bookmark-create-response
    (dispatch-with-server BookmarkServer (list bookmark-web-service)
                          'POST
                          '("bookmarks")
                          #:cookie "user=mikael"
                          #:body (hash 'title "Oz notes"
                                       'url "https://example.com/docs")))
  (check-equal? (dsl-response-status bookmark-create-response) 200)
  (define bookmark-id (hash-ref (dsl-response-body bookmark-create-response) 'id))
  (check-true (string-prefix? bookmark-id "bookmark-"))

  (define bookmark-list-response
    (dispatch-with-server BookmarkServer (list bookmark-web-service) 'GET '("bookmarks" "mine") #:cookie "user=mikael"))
  (check-equal? (dsl-response-status bookmark-list-response) 200)
  (check-equal? (length (dsl-response-body bookmark-list-response)) 2)

  (define bookmark-get-response
    (dispatch-with-server BookmarkServer (list bookmark-web-service) 'GET (list "bookmarks" bookmark-id) #:cookie "user=mikael"))
  (check-equal? (dsl-response-status bookmark-get-response) 200)
  (check-equal? (hash-ref (dsl-response-body bookmark-get-response) 'url) "https://example.com/docs"))

(define (todo-module-value symbol-name)
  (dynamic-require `(file ,(path->string todo-api-module-path)) symbol-name))

(define (run-todo-tests-with-config cfg)
  (with-env
   (list (cons "TESL_POSTGRES_HOST" (hash-ref cfg 'host))
         (cons "TESL_POSTGRES_PORT" (number->string (hash-ref cfg 'port)))
         (cons "TESL_POSTGRES_DATABASE" (hash-ref cfg 'database))
         (cons "TESL_POSTGRES_USER" (hash-ref cfg 'user))
         (cons "TESL_POSTGRES_PASSWORD" ""))
   (lambda ()
     (define todo-server (todo-module-value 'TodoServer))
     (define todo-database (todo-module-value 'TodoDatabase))
     (define seed-example-data! (todo-module-value 'seedExampleData))
    (define todo-db-read (module-private-value todo-api-module-path 'todoDbRead))
    (define todo-web-service (module-private-value todo-api-module-path 'todoWebService))

     (call-with-database
      todo-database
      (lambda ()
        (check-exn exn:fail:user?
                   (lambda ()
                     (seed-example-data!)))
        (check-exn exn:fail:user?
                   (lambda ()
                     (with-capabilities (todo-db-read)
                       (seed-example-data!))))
        (with-capabilities (todo-web-service)
          (check-equal? (seed-example-data!) 2)
          (check-equal? (seed-example-data!) 0))

        (define todo-create-response
          (dispatch-with-server todo-server (list todo-web-service)
                                'POST
                                '("todos")
                                #:cookie "user=mikael"
                                #:body (hash 'title "Ship automatic migrations")))
        (check-equal? (dsl-response-status todo-create-response) 200)
        (define todo-id (hash-ref (dsl-response-body todo-create-response) 'id))
        (check-true (string-prefix? todo-id "todo-"))
        (check-equal? (hash-ref (hash-ref (dsl-response-body todo-create-response) 'status) 'tag) "Open")

        (define todo-list-response
          (dispatch-with-server todo-server (list todo-web-service) 'GET '("todos" "mine") #:cookie "user=mikael"))
        (check-equal? (dsl-response-status todo-list-response) 200)
        (check-equal? (length (dsl-response-body todo-list-response)) 2)

        (define todo-get-response
          (dispatch-with-server todo-server (list todo-web-service) 'GET (list "todos" todo-id) #:cookie "user=mikael"))
        (check-equal? (dsl-response-status todo-get-response) 200)
        (check-equal? (hash-ref (dsl-response-body todo-get-response) 'title) "Ship automatic migrations")
        (check-equal? (hash-ref (hash-ref (dsl-response-body todo-get-response) 'status) 'tag) "Open")

        (define todo-complete-response
          (dispatch-with-server todo-server (list todo-web-service) 'PUT (list "todos" todo-id "complete") #:cookie "user=mikael"))
        (check-equal? (dsl-response-status todo-complete-response) 200)
        (check-equal? (hash-ref (hash-ref (dsl-response-body todo-complete-response) 'status) 'tag) "Done"))))))

(define (run-todo-example-tests)
  (if (not (postgres-tooling-available?))
      (displayln "Skipping example-api-test.rkt PostgreSQL portion because initdb/pg_ctl are not available")
      (call-with-temporary-postgres run-todo-tests-with-config)))

(run-bookmark-tests)
(run-todo-example-tests)
