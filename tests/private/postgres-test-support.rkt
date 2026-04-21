#lang racket

(require db
         racket/file
         racket/format
         racket/path
         racket/string
         racket/system
         racket/tcp)

(provide postgres-tooling-available?
         call-with-shared-postgres-cluster
         call-with-temporary-postgres)

(define shared-host-env "TESL_TEST_POSTGRES_SHARED_HOST")
(define shared-port-env "TESL_TEST_POSTGRES_SHARED_PORT")
(define shared-user-env "TESL_TEST_POSTGRES_SHARED_USER")
(define shared-admin-database-env "TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE")

(define (non-empty-env name)
  (define value (getenv name))
  (and value
       (not (string=? value ""))
       value))

(define (postgres-binaries-available?)
  (and (find-executable-path "initdb")
       (find-executable-path "pg_ctl")))

(define (make-cluster-config host port user admin-database
                             #:temp-root [temp-root #f]
                             #:data-dir [data-dir #f]
                             #:log-path [log-path #f]
                             #:socket-dir [socket-dir #f])
  (hash 'host host
        'port port
        'database admin-database
        'admin-database admin-database
        'user user
        'temp-root temp-root
        'data-dir data-dir
        'log-path log-path
        'socket-dir socket-dir))

(define (shared-postgres-cluster-config)
  (define host (non-empty-env shared-host-env))
  (define port-str (non-empty-env shared-port-env))
  (define user (non-empty-env shared-user-env))
  (define admin-database (or (non-empty-env shared-admin-database-env) "postgres"))
  (cond
    [(and host port-str user)
     (define maybe-port (string->number port-str))
     (and (exact-positive-integer? maybe-port)
          (make-cluster-config host maybe-port user admin-database))]
    [else #f]))

(define (postgres-tooling-available?)
  (or (shared-postgres-cluster-config)
      (postgres-binaries-available?)))

(define (pick-free-port)
  (define listener (tcp-listen 0 4 #t))
  (define-values (_local-address port _remote-address _remote-port)
    (tcp-addresses listener #t))
  (tcp-close listener)
  port)

(define (run-command who . args)
  (unless (apply system* args)
    (error who "command failed: ~a" args)))

(define (shared-cluster-env-bindings cluster-config)
  (list (cons shared-host-env (hash-ref cluster-config 'host))
        (cons shared-port-env (number->string (hash-ref cluster-config 'port)))
        (cons shared-user-env (hash-ref cluster-config 'user))
        (cons shared-admin-database-env (hash-ref cluster-config 'admin-database))))

(define (call-with-env bindings thunk)
  (define saved
    (for/list ([binding (in-list bindings)])
      (define key (car binding))
      (cons key (getenv key))))
  (define env-copy (environment-variables-copy (current-environment-variables)))
  (for ([binding (in-list bindings)])
    (environment-variables-set!
     env-copy
     (string->bytes/utf-8 (car binding))
     (string->bytes/utf-8 (cdr binding))))
  (dynamic-wind
    (lambda ()
      (for ([binding (in-list bindings)])
        (putenv (car binding) (cdr binding))))
    (lambda ()
      (parameterize ([current-environment-variables env-copy])
        (thunk)))
    (lambda ()
      (for ([binding (in-list saved)])
        (define key (car binding))
        (define value (cdr binding))
        (if value
            (putenv key value)
            (putenv key ""))))))

(define (cleanup-cluster! temp-root socket-dir)
  (when (and temp-root (directory-exists? temp-root))
    (delete-directory/files temp-root))
  (when (and socket-dir (directory-exists? socket-dir))
    (delete-directory/files socket-dir)))

(define (stop-cluster! pg-ctl data-dir)
  (with-handlers ([exn:fail? (lambda (_exn) (void))])
    (run-command 'pg_ctl-stop
                 pg-ctl
                 "-D" (path->string data-dir)
                 "-m" "immediate"
                 "stop")))

(define (call-with-started-temporary-cluster thunk)
  (define initdb (find-executable-path "initdb"))
  (define pg-ctl (find-executable-path "pg_ctl"))
  (define temp-root (make-temporary-file "tesl-postgres-test~a" 'directory))
  (define data-dir (build-path temp-root "data"))
  (define log-path (build-path temp-root "postgres.log"))
  ;; Unix domain socket paths must fit in UNIX_PATH_MAX (108 bytes on Linux).
  ;; The nix-shell /tmp sub-dirs can be deep enough to exceed that limit, so
  ;; always keep the socket dir at the /tmp level with a short unique name.
  (define socket-dir (make-temporary-file "tesl-pg-sock~a" 'directory "/tmp"))
  (define port (pick-free-port))
  (define cluster-config
    (make-cluster-config "127.0.0.1"
                         port
                         "tesl"
                         "postgres"
                         #:temp-root temp-root
                         #:data-dir data-dir
                         #:log-path log-path
                         #:socket-dir socket-dir))
  (with-handlers ([exn:fail?
                   (lambda (exn)
                     (cleanup-cluster! temp-root socket-dir)
                     (raise exn))])
    (run-command 'initdb
                 initdb
                 "-D" (path->string data-dir)
                 "-A" "trust"
                 "-U" "tesl"
                 "--locale=C")
    (run-command 'pg_ctl
                 pg-ctl
                 "-D" (path->string data-dir)
                 "-l" (path->string log-path)
                 "-o" (~a "-F -k " (path->string socket-dir) " -p " port)
                 "-w"
                 "start"))
  (dynamic-wind
    void
    (lambda ()
      (thunk cluster-config))
    (lambda ()
      (stop-cluster! pg-ctl data-dir)
      (cleanup-cluster! temp-root socket-dir))))

(define (fresh-test-database-name)
  (regexp-replace* #px"[^a-z0-9_]"
                   (string-downcase (format "tesl_test_~a" (gensym 'db)))
                   "_"))

(define (connect-admin cluster-config)
  (postgresql-connect #:user (hash-ref cluster-config 'user)
                      #:database (hash-ref cluster-config 'admin-database)
                      #:server (hash-ref cluster-config 'host)
                      #:port (hash-ref cluster-config 'port)))

(define (make-test-config cluster-config database-name)
  (hash 'host (hash-ref cluster-config 'host)
        'port (hash-ref cluster-config 'port)
        'database database-name
        'admin-database (hash-ref cluster-config 'admin-database)
        'user (hash-ref cluster-config 'user)
        'temp-root (hash-ref cluster-config 'temp-root #f)
        'data-dir (hash-ref cluster-config 'data-dir #f)
        'log-path (hash-ref cluster-config 'log-path #f)
        'socket-dir (hash-ref cluster-config 'socket-dir #f)))

(define (call-with-fresh-test-database cluster-config thunk)
  (define admin-conn (connect-admin cluster-config))
  (define database-name (fresh-test-database-name))
  (with-handlers ([exn:fail?
                   (lambda (exn)
                     (with-handlers ([exn:fail? (lambda (_disconnect-exn) (void))])
                       (disconnect admin-conn))
                     (raise exn))])
    (query-exec admin-conn (format "create database ~a" database-name)))
  (dynamic-wind
    void
    (lambda ()
      (thunk (make-test-config cluster-config database-name)))
    (lambda ()
      (with-handlers ([exn:fail? (lambda (_exn) (void))])
        (query-exec admin-conn
                    "select pg_terminate_backend(pid) from pg_stat_activity where datname = $1 and pid <> pg_backend_pid()"
                    database-name)
        (query-exec admin-conn (format "drop database if exists ~a" database-name)))
      (with-handlers ([exn:fail? (lambda (_disconnect-exn) (void))])
        (disconnect admin-conn)))))

(define (call-with-shared-postgres-cluster thunk)
  (unless (procedure? thunk)
    (raise-user-error 'call-with-shared-postgres-cluster "expected a procedure, got ~a" thunk))
  (define shared-config (shared-postgres-cluster-config))
  (cond
    [shared-config
     (thunk shared-config)]
    [else
     (unless (postgres-binaries-available?)
       (raise-user-error 'call-with-shared-postgres-cluster
                         "PostgreSQL tools (initdb and pg_ctl) are not available on PATH"))
     (call-with-started-temporary-cluster
      (lambda (cluster-config)
        (call-with-env (shared-cluster-env-bindings cluster-config)
          (lambda ()
            (thunk cluster-config)))))]))

(define (call-with-temporary-postgres thunk)
  (unless (procedure? thunk)
    (raise-user-error 'call-with-temporary-postgres "expected a procedure, got ~a" thunk))
  (define shared-config (shared-postgres-cluster-config))
  (cond
    [shared-config
     (call-with-fresh-test-database shared-config thunk)]
    [else
     (unless (postgres-binaries-available?)
       (raise-user-error 'call-with-temporary-postgres
                         "PostgreSQL tools (initdb and pg_ctl) are not available on PATH"))
     (call-with-started-temporary-cluster
      (lambda (cluster-config)
        (call-with-fresh-test-database cluster-config thunk)))]))
