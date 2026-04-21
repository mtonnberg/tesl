#lang racket

(require racket/string
         "../dsl/capability.rkt"
         "../dsl/check.rkt"
         "../dsl/otel.rkt"
         "../dsl/sql.rkt"
         "../dsl/web.rkt")

(provide BookmarkAPI
         BookmarkServer
         seed-state!
         current-bookmark-store
         resolve-example-port)

(define-capability bookmark-db-read (implies db-read))
(define-capability bookmark-db-write (implies db-write))
(define-capability bookmark-read-http-cookie)
(define-capability bookmark-web-service (implies bookmark-db-read bookmark-db-write bookmark-read-http-cookie))

(define current-bookmark-store (make-parameter (make-hash)))

(register-runtime-type! 'UserId string?)

(define (jsexpr-ref object key [default #f])
  (cond
    [(and (hash? object) (hash-has-key? object key))
     (hash-ref object key)]
    [(and (hash? object) (hash-has-key? object (symbol->string key)))
     (hash-ref object (symbol->string key))]
    [else default]))

(define (new-bookmark? value)
  (and (hash? value)
       (string? (jsexpr-ref value 'title #f))
       (string? (jsexpr-ref value 'url #f))))

(register-runtime-type! 'NewBookmark new-bookmark?)
(register-runtime-type!
 'BookmarkList
 (lambda (value)
   (and (list? value)
        (andmap (lambda (item)
                  (let ([raw (if (named-value? item) (raw-value item) item)])
                    ((runtime-type-predicate 'Bookmark) raw)))
                value))))

(define-entity Bookmark
  #:source (lambda () (current-bookmark-store))
  #:table bookmarks
  #:primary-key id
  [Id id : String]
  [Title title : String]
  [Url url : String]
  [Domain domain : String]
  [OwnerId ownerId : UserId #:db-type text])

(define default-example-port 8087)

(define (lookup-port-argument [args (vector->list (current-command-line-arguments))])
  (let loop ([remaining args])
    (cond
      [(null? remaining) #f]
      [(string-prefix? (car remaining) "--port=")
       (substring (car remaining) (string-length "--port="))]
      [(equal? (car remaining) "--port")
       (cond
         [(null? (cdr remaining))
          (raise-user-error 'bookmark-api "`--port` requires a value")]
         [else
          (cadr remaining)])]
      [else
       (loop (cdr remaining))])))

(define (parse-port-string raw-port source)
  (define maybe-port (and raw-port (string->number raw-port)))
  (unless (and maybe-port
               (integer? maybe-port)
               (<= 1 maybe-port 65535))
    (raise-user-error 'bookmark-api
                      (format "invalid ~a port value ~a; expected an integer between 1 and 65535"
                              source
                              raw-port)))
  maybe-port)

(define (resolve-example-port [args (vector->list (current-command-line-arguments))]
                              #:tesl-port [tesl-port (getenv "TESL_BOOKMARK_API_PORT")]
                              #:port [port-env (getenv "PORT")])
  (define cli-port (lookup-port-argument args))
  (cond
    [cli-port
     (parse-port-string cli-port "command-line")]
    [tesl-port
     (parse-port-string tesl-port "TESL_BOOKMARK_API_PORT")]
    [port-env
     (parse-port-string port-env "PORT")]
    [else
     default-example-port]))

(define (extract-cookie req key)
  (define cookie-header (or (request-header req "cookie" "") ""))
  (for/first ([part (in-list (map string-trim (string-split cookie-header ";")))]
              #:when (string-prefix? part (format "~a=" key)))
    (substring part (+ 1 (string-length key)))))

(define (generate-bookmark-id)
  (format "bookmark-~a-~a" (current-seconds) (random 1000000)))

(define (seed-state!)
  (define store (make-hash))
  (hash-set! store "bookmark-1"
             (hash 'id "bookmark-1"
                   'title "Racket docs"
                   'url "https://docs.racket-lang.org/"
                   'domain "docs.racket-lang.org"
                   'ownerId "mikael"))
  (hash-set! store "bookmark-2"
             (hash 'id "bookmark-2"
                   'title "PostgreSQL"
                   'url "https://www.postgresql.org/"
                   'domain "www.postgresql.org"
                   'ownerId "anna"))
  (current-bookmark-store store)
  (void))

(seed-state!)

(define-auther
  (cookie-auth [request : HttpRequest])
  #:capabilities [bookmark-read-http-cookie]
  #:returns [requestUser : User ::: (Authenticated requestUser)]
  (define user-id (extract-cookie *request "user"))
  (if *user-id
      (accept Authenticated #:value (hash 'id *user-id 'role "user"))
      (reject "Missing or invalid user cookie" #:http-code 401)))

(define-checker
  (is-safe-title [title : String])
  #:returns [title : String ::: (TitleSafe title)]
  (if (and (string? *title)
           (<= 3 (string-length *title) 120))
      (accept (TitleSafe title))
      (reject "Title must be between 3 and 120 characters" #:http-code 400)))

(define-checker
  (is-bookmark-id [bookmarkId : String])
  #:returns [bookmarkId : String ::: (BookmarkId bookmarkId)]
  (if (and (string-prefix? *bookmarkId "bookmark-")
           (> (string-length *bookmarkId) 9))
      (accept (BookmarkId bookmarkId))
      (reject "Malformed bookmark id" #:http-code 400)))

(define-checker
  (is-safe-url [url : String])
  #:returns [url : String ::: (SafeUrl url)]
  (if (or (string-prefix? *url "https://")
          (string-prefix? *url "http://"))
      (accept (SafeUrl url))
      (reject "URL must start with http:// or https://" #:http-code 400)))

(define-capture bookmark-id-capture
  [bookmarkId : String ::: (BookmarkId bookmarkId)]
  #:parser string-segment
  #:check is-bookmark-id)

(define (extract-domain-string url)
  (define cleaned-url
    (regexp-replace #rx"^https?://" url ""))
  (define pieces (string-split cleaned-url "/"))
  (define host (and (pair? pieces) (string-trim (car pieces))))
  (and host (not (string=? host "")) host))

(define/pow
  (extract-domain [url : String ::: (SafeUrl url)])
  #:returns (Result [domain : String] [problem : String])
  (define host? (extract-domain-string *url))
  (if host?
      (Ok (extract-domain-string *url))
      (Err "Could not extract a domain from the URL")))

(define-handler
  (create-bookmark-handler
    [requestUser : User ::: (Authenticated requestUser)]
    [newBookmark : NewBookmark])
  #:capabilities [bookmark-db-read bookmark-db-write]
  #:returns Bookmark
  (define title (jsexpr-ref *newBookmark 'title ""))
  (define url (jsexpr-ref *newBookmark 'url ""))
  (let/check ([title-ok (is-safe-title *title)]
              [url-ok (is-safe-url *url)])
    (cond
      [(Err? (extract-domain url-ok))
       (reject (Err-error (extract-domain url-ok)) #:http-code 400)]
      [else
       (insert-one! Bookmark
                    (hash 'id (generate-bookmark-id)
                          'title *title
                          'url *url
                          'domain (Ok-value (extract-domain url-ok))
                          'ownerId (hash-ref *requestUser 'id)))])))

(define-handler
  (list-my-bookmarks-handler [requestUser : User ::: (Authenticated requestUser)])
  #:capabilities [bookmark-db-read]
  #:returns BookmarkList
  (telemetry-event! "bookmark.list"
                    #:attributes ([user.id (hash-ref *requestUser 'id)]))
  (select-many (from Bookmark)
               (where (==. (Bookmark-ownerId) (hash-ref *requestUser 'id)))))

(define-handler
  (get-bookmark-handler
    [requestUser : User ::: (Authenticated requestUser)]
    [bookmarkId : String ::: (BookmarkId bookmarkId)])
  #:capabilities [bookmark-db-read]
  #:returns (? Bookmark _entity ::: (FromDb [Id == bookmarkId] _entity))
  (telemetry-event! "bookmark.get"
                    #:attributes ([user.id (hash-ref *requestUser 'id)]
                                  [bookmark.id *bookmarkId]))
  (define bookmark
    (select-one (from Bookmark)
                (where (==. (Bookmark-id) bookmarkId))))
  (cond
    [(not bookmark)
     (reject "Bookmark not found" #:http-code 404)]
    [(equal? (hash-ref (raw-value bookmark) 'ownerId) (hash-ref *requestUser 'id))
     bookmark]
    [else
     (reject "Bookmark not owned by request user" #:http-code 403)]))

(define-api BookmarkAPI
  [create-bookmark :
    (Auth [requestUser : User ::: (Authenticated requestUser)]
          #:via cookie-auth)
    :> "bookmarks"
    :> (ReqBody JSON [newBookmark : NewBookmark])
    :> (Post JSON Bookmark)]
  [list-my-bookmarks :
    (Auth [requestUser : User ::: (Authenticated requestUser)]
          #:via cookie-auth)
    :> "bookmarks"
    :> "mine"
    :> (Get JSON BookmarkList)]
  [get-bookmark :
    (Auth [requestUser : User ::: (Authenticated requestUser)]
          #:via cookie-auth)
    :> "bookmarks"
    :> (Capture bookmark-id-capture
                [bookmarkId : String ::: (BookmarkId bookmarkId)])
    :> (Get JSON
         (? Bookmark _entity ::: (FromDb [Id == bookmarkId] _entity)))])

(define-server BookmarkServer
  #:api BookmarkAPI
  [create-bookmark create-bookmark-handler]
  [list-my-bookmarks list-my-bookmarks-handler]
  [get-bookmark get-bookmark-handler])

(module+ main
  (seed-state!)
  (init-opentelemetry! #:service-name "bookmark-api" #:endpoint "in-memory" #:console? #t)
  (define port (resolve-example-port))
  (with-handlers ([exn:fail?
                   (lambda (exn)
                     (if (regexp-match? #rx"Address already in use" (exn-message exn))
                         (raise-user-error 'bookmark-api
                                           (format "could not start the bookmark API on port ~a; set TESL_BOOKMARK_API_PORT, PORT, or pass --port to choose another port"
                                                   port))
                         (raise exn)))])
    (serve BookmarkServer #:port port #:capabilities (list bookmark-web-service))))
