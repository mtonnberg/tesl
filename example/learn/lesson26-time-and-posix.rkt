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
  (only-in tesl/tesl/prelude Bool Int String List)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/time time nowMillis PosixMillis formatTime durationMs diffMs addMs subtractMs [Time.secondsToPosix tesl_import_Time_secondsToPosix])
  (only-in tesl/tesl/string [String.fromInt tesl_import_String_fromInt] [String.startsWith tesl_import_String_startsWith])
  (only-in tesl/tesl/random random)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/id generatePrefixedId)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
)


(provide TimedDatabase TimedServer currentTimestamp ageDescription formatPublishedAt createdRecently currentTimestamp-signature ageDescription-signature formatPublishedAt-signature createdRecently-signature)

(define Authenticated 'Authenticated)

(define-capability timedRead (implies dbRead))

(define-capability timedWrite (implies dbWrite time random))

(define-capability timedService (implies timedRead timedWrite))

(define-entity Event
  #:source (make-hash)
  #:table events
  #:primary-key id
  [Id id : String]
  [Name name : String #:db-type text]
  [CreatedAt createdAt : PosixMillis]
  [ExpiresAt expiresAt : PosixMillis]
)

(define-record CreateEventRequest
  [name : String]
  [durationMs : Integer]
)

(define (tesl-codec-encode-CreateEventRequest _v)
  (error "toJson is forbidden for type CreateEventRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-CreateEventRequest-0 _j)
  (define _f_name (tesl-decode-prim-field _j "name" tesl-decode-prim-string))
  (define _f_durationMs (tesl-decode-prim-field _j "durationMs" tesl-decode-prim-int))
  (record-value 'CreateEventRequest (hash 'name _f_name 'durationMs _f_durationMs)))
(register-type-codec! 'CreateEventRequest tesl-codec-encode-CreateEventRequest (list tesl-codec-decode-CreateEventRequest-0))

(define-database TimedDatabase
  #:backend postgres
  #:database (tesl-env-raw "TIMED_DB_NAME")
  #:user (tesl-env-raw "TIMED_DB_USER")
  #:password (tesl-env-raw "TIMED_DB_PASSWORD")
  #:server (tesl-env-raw "TIMED_DB_HOST")
  #:port (tesl-env-int-raw "TIMED_DB_PORT" 5432)
  #:schema timed_app
  #:entities Event)

(define-auther
  (cookieAuth [request : HttpRequest])
  #:capabilities [timedRead]
  #:returns [user : String ::: (Authenticated user)]
  (thsl-src-control! "example/learn/lesson26-time-and-posix.tesl" 135 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "user" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 136 (list) (lambda () (reject "not logged in" #:http-code 401)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([uid (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 137 (list (cons 'uid uid)) (lambda () (accept (Authenticated uid) #:value *uid))))])))))

(define/pow
  (currentTimestamp)
  #:capabilities [time]
  #:returns String
  (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 143 (list) (lambda () (formatTime (raw-value (nowMillis)) "UTC" "%Y-%m-%dT%H:%M:%S.%3NZ"))))

(define/pow
  (ageDescription [createdMs : PosixMillis] [nowMs : PosixMillis])
  #:returns String
  (let ([elapsedMs (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 149 (list (cons 'createdMs *createdMs) (cons 'nowMs *nowMs)) (lambda () (diffMs *createdMs *nowMs)))]) (let ([elapsedS (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 150 (list (cons 'elapsedMs *elapsedMs) (cons 'createdMs *createdMs) (cons 'nowMs *nowMs)) (lambda () (quotient (raw-value elapsedMs) 1000)))]) (let ([elapsedM (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 151 (list (cons 'elapsedS *elapsedS) (cons 'elapsedMs *elapsedMs) (cons 'createdMs *createdMs) (cons 'nowMs *nowMs)) (lambda () (quotient (raw-value elapsedS) 60)))]) (let ([elapsedH (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 152 (list (cons 'elapsedM *elapsedM) (cons 'elapsedS *elapsedS) (cons 'elapsedMs *elapsedMs) (cons 'createdMs *createdMs) (cons 'nowMs *nowMs)) (lambda () (quotient (raw-value elapsedM) 60)))]) (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 153 (list (cons 'elapsedH *elapsedH) (cons 'elapsedM *elapsedM) (cons 'elapsedS *elapsedS) (cons 'elapsedMs *elapsedMs) (cons 'createdMs *createdMs) (cons 'nowMs *nowMs)) (lambda () (if (> (raw-value elapsedH) 0) (raw-value (format "~ah ago" (tesl-display-val (tesl_import_String_fromInt (raw-value elapsedH))))) (if (> (raw-value elapsedM) 0) (raw-value (format "~am ago" (tesl-display-val (tesl_import_String_fromInt (raw-value elapsedM))))) (raw-value "just now"))))))))))

(define/pow
  (formatPublishedAt [posixMs : PosixMillis] [timezone : String])
  #:returns String
  (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 163 (list (cons 'posixMs *posixMs) (cons 'timezone *timezone)) (lambda () (formatTime *posixMs *timezone "%Y-%m-%d %H:%M:%S"))))

(define/pow
  (createdRecently [createdMs : PosixMillis] [nowMs : PosixMillis] [withinMs : Integer])
  #:returns Boolean
  (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 167 (list (cons 'createdMs *createdMs) (cons 'nowMs *nowMs) (cons 'withinMs *withinMs)) (lambda () (< (diffMs *createdMs *nowMs) *withinMs))))

(define-handler
  (createEvent [user : String ::: (Authenticated user)] [req : CreateEventRequest])
  #:capabilities [timedWrite]
  #:returns (Exists [eventId : String] (? Event _entity ::: (FromDb (Id == eventId) _entity)))
  (let ([eventId (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 176 (list (cons 'user *user) (cons 'req *req)) (lambda () (generatePrefixedId "evt")))]) (let ([nowTs (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 177 (list (cons 'eventId *eventId) (cons 'user *user) (cons 'req *req)) (lambda () (raw-value (nowMillis))))]) (let ([expiresAt (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 178 (list (cons 'nowTs *nowTs) (cons 'eventId *eventId) (cons 'user *user) (cons 'req *req)) (lambda () (addMs (raw-value nowTs) (raw-value req.durationMs))))]) (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 179 (list (cons 'expiresAt *expiresAt) (cons 'nowTs *nowTs) (cons 'eventId *eventId) (cons 'user *user) (cons 'req *req)) (lambda () (pack ([eventId]) (insert-one! Event (hash 'id eventId 'name (raw-value req.name) 'createdAt nowTs 'expiresAt expiresAt)))))))))

(define-handler
  (listActiveEvents [user : String ::: (Authenticated user)])
  #:capabilities [timedRead]
  #:returns (List Event)
  (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 192 (list (cons 'user *user)) (lambda () (select-many (from Event)))))

(define TimedServer-sse-routes '())
(define-api TimedApi
  [createEvent :
    (Auth [user : String ::: (Authenticated user)] #:via cookieAuth)
    :> "events"
    :> (ReqBody JSON [req : CreateEventRequest])
    :> (Post JSON (Exists [eventId : String] (? Event _entity ::: (FromDb (Id == eventId) _entity))))
    ]
  [listActiveEvents :
    (Auth [user : String ::: (Authenticated user)] #:via cookieAuth)
    :> "events"
    :> (Get JSON (List Event))
    ]
)

(define-server TimedServer
  #:api TimedApi
  [createEvent createEvent]
  [listActiveEvents listActiveEvents]
)

(module+ test
  (require rackunit)
  (test-case "ageDescription"
    (call-with-fresh-memory-db (list TimedDatabase) (lambda ()
  (define base (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 311 (list) (lambda () (raw-value (tesl_import_Time_secondsToPosix 1000)))))
  (define fiveMinLater (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 313 (list (cons 'base base)) (lambda () (addMs (raw-value base) (* (* 5 60) 1000)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 314 (list (cons 'fiveMinLater fiveMinLater) (cons 'base base)) (lambda () (ageDescription base fiveMinLater)))) "5m ago")
  (define twoHrLater (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 316 (list (cons 'fiveMinLater fiveMinLater) (cons 'base base)) (lambda () (addMs (raw-value base) (* (* (* 2 60) 60) 1000)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 317 (list (cons 'twoHrLater twoHrLater) (cons 'fiveMinLater fiveMinLater) (cons 'base base)) (lambda () (ageDescription base twoHrLater)))) "2h ago")
  (define almostNow (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 319 (list (cons 'twoHrLater twoHrLater) (cons 'fiveMinLater fiveMinLater) (cons 'base base)) (lambda () (addMs (raw-value base) 500))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 320 (list (cons 'almostNow almostNow) (cons 'twoHrLater twoHrLater) (cons 'fiveMinLater fiveMinLater) (cons 'base base)) (lambda () (ageDescription base almostNow)))) "just now")
    ))
  )

  (test-case "createdRecently"
    (call-with-fresh-memory-db (list TimedDatabase) (lambda ()
  (define nowTs (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 324 (list) (lambda () (raw-value (tesl_import_Time_secondsToPosix 1000)))))
  (define recent (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 325 (list (cons 'nowTs nowTs)) (lambda () (subtractMs (raw-value nowTs) 500))))
  (define old (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 326 (list (cons 'recent recent) (cons 'nowTs nowTs)) (lambda () (subtractMs (raw-value nowTs) 2000))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 327 (list (cons 'old old) (cons 'recent recent) (cons 'nowTs nowTs)) (lambda () (createdRecently recent nowTs 1000)))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 328 (list (cons 'old old) (cons 'recent recent) (cons 'nowTs nowTs)) (lambda () (createdRecently old nowTs 1000)))) #f)
    ))
  )

  (test-case "formatPublishedAt basics"
    (call-with-fresh-memory-db (list TimedDatabase) (lambda ()
  (define formatted (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 333 (list) (lambda () (formatPublishedAt (raw-value (tesl_import_Time_secondsToPosix 0)) "UTC"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 334 (list (cons 'formatted formatted)) (lambda () (tesl_import_String_startsWith (raw-value formatted) "1970-01-01")))) #t)
    ))
  )

  (test-case "diffMs and addMs"
    (call-with-fresh-memory-db (list TimedDatabase) (lambda ()
  (define t1 (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 339 (list) (lambda () (raw-value (tesl_import_Time_secondsToPosix 1000)))))
  (define t2 (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 340 (list (cons 't1 t1)) (lambda () (addMs (raw-value t1) 1500))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 341 (list (cons 't2 t2) (cons 't1 t1)) (lambda () (diffMs (raw-value t1) (raw-value t2))))) 1500)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson26-time-and-posix.tesl" 343 (list (cons 't2 t2) (cons 't1 t1)) (lambda () (diffMs (raw-value t1) (addMs (raw-value t1) 500))))) 500)
    ))
  )

)
