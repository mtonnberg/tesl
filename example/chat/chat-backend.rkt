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
  (only-in tesl/tesl/prelude Bool String List Fact Unit)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/queue queueRead queueWrite pubsub FromDeadQueue)
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
  (only-in tesl/tesl/time nowMillis time PosixMillis)
  (only-in tesl/tesl/id generatePrefixedId)
  (only-in tesl/tesl/env envInt envRead)
  (only-in tesl/tesl/random random)
  (only-in tesl/tesl/telemetry telemetry initTelemetry)
  (only-in tesl/tesl/api-test statusOk statusClientError jsonInt jsonString jsonLength isNotNull includesWhere excludesWhere hasLength isNotEmpty arrayAt hasField fieldAt bodyField jsonContains subscribe collect JobResult JobOk JobFailed processNextJob processNextDeadJob pendingJobCount expectJobOk expectJobFailed)
)


(provide ChatServer)

(define Authenticated 'Authenticated)
(define NonEmpty 'NonEmpty)
(define ValidRoomId 'ValidRoomId)

(define-capability chatRead (implies dbRead))

(define-capability chatWrite (implies dbWrite time random))

(define-capability chatPubSub (implies pubsub))

(define-capability chatQueue (implies queueWrite))

(define-capability notifyCap (implies queueRead))

(define-capability deadLetterCap (implies queueRead chatPubSub))

(define-capability chatService (implies chatRead chatWrite chatPubSub chatQueue))

(define-record SessionUser
  [id : String ::: (NonEmpty id)]
  [username : String ::: (NonEmpty username)]
)

(define-record LoginRequest
  [username : String ::: (NonEmpty username)]
)

(define-record CreateRoomRequest
  [name : String ::: (NonEmpty name)]
)

(define-record PostMessageRequest
  [content : String ::: (NonEmpty content)]
)

(define (tesl-codec-encode-SessionUser _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'id (tesl-encode-prim-string (raw-value (hash-ref _fields 'id)))
  ))
(register-type-codec! 'SessionUser tesl-codec-encode-SessionUser (list ))

(define (tesl-codec-encode-LoginRequest _v)
  (error "toJson is forbidden for type LoginRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-LoginRequest-0 _j)
  (define _fraw_username (tesl-decode-prim-field _j "username" tesl-decode-prim-string))
  (define _r1_username
    (let ([_r (checkNonEmptyString _fraw_username)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_username
    (if (check-ok? _r1_username)
        (ensure-named 'username (check-ok-value _r1_username) (check-ok-facts _r1_username) (check-ok-bindings _r1_username) #:subject 'username)
        _r1_username))
  (or (and (check-fail? _f_username) _f_username)
      (record-value 'LoginRequest (hash 'username _f_username))))
(register-type-codec! 'LoginRequest tesl-codec-encode-LoginRequest (list tesl-codec-decode-LoginRequest-0))

(define (tesl-codec-encode-CreateRoomRequest _v)
  (error "toJson is forbidden for type CreateRoomRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-CreateRoomRequest-0 _j)
  (define _fraw_name (tesl-decode-prim-field _j "name" tesl-decode-prim-string))
  (define _r1_name
    (let ([_r (checkNonEmptyString _fraw_name)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_name
    (if (check-ok? _r1_name)
        (ensure-named 'name (check-ok-value _r1_name) (check-ok-facts _r1_name) (check-ok-bindings _r1_name) #:subject 'name)
        _r1_name))
  (or (and (check-fail? _f_name) _f_name)
      (record-value 'CreateRoomRequest (hash 'name _f_name))))
(register-type-codec! 'CreateRoomRequest tesl-codec-encode-CreateRoomRequest (list tesl-codec-decode-CreateRoomRequest-0))

(define (tesl-codec-encode-PostMessageRequest _v)
  (error "toJson is forbidden for type PostMessageRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-PostMessageRequest-0 _j)
  (define _fraw_content (tesl-decode-prim-field _j "content" tesl-decode-prim-string))
  (define _r1_content
    (let ([_r (checkNonEmptyString _fraw_content)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_content
    (if (check-ok? _r1_content)
        (ensure-named 'content (check-ok-value _r1_content) (check-ok-facts _r1_content) (check-ok-bindings _r1_content) #:subject 'content)
        _r1_content))
  (or (and (check-fail? _f_content) _f_content)
      (record-value 'PostMessageRequest (hash 'content _f_content))))
(register-type-codec! 'PostMessageRequest tesl-codec-encode-PostMessageRequest (list tesl-codec-decode-PostMessageRequest-0))

(define-record NotifyJob
  [senderName : String]
  [roomName : String]
  [content : String]
)

(define-adt RoomEvent
  [NewMessage [msgId : String] [userId : String] [username : String] [content : String] [createdAt : PosixMillis]]
  [UserJoined [userId : String] [username : String]]
  [NotifyFailed [senderName : String] [roomName : String]]
)

(define-entity ChatUser
  #:source (make-hash)
  #:table users
  #:primary-key id
  [Id id : String]
  [Username username : String #:db-type text]
)

(define-entity Room
  #:source (make-hash)
  #:table rooms
  #:primary-key id
  [Id id : String]
  [Name name : String #:db-type text]
  [CreatedAt createdAt : PosixMillis]
)

(define-entity Message
  #:source (make-hash)
  #:table messages
  #:primary-key id
  [Id id : String]
  [RoomId roomId : String #:db-type text]
  [UserId userId : String #:db-type text]
  [Username username : String #:db-type text]
  [Content content : String #:db-type text]
  [CreatedAt createdAt : PosixMillis]
)

(define-database ChatDatabase
  #:backend postgres
  #:database "chat"
  #:user "tesl"
  #:password ""
  #:server "127.0.0.1"
  #:port 55432
  #:schema chat
  #:entities ChatUser Room Message)

(define-queue NotificationQueue
  #:database ChatDatabase
  #:job-types (NotifyJob)
  #:max-attempts 3
  #:backoff exponential
  #:initial-delay 5)

(define-channel RoomMessages)

(define-auther
  (cookieAuth [request : HttpRequest])
  #:capabilities [chatRead]
  #:returns [session : SessionUser ::: (Authenticated session)]
  (thsl-src-control! "example/chat/chat-backend.tesl" 196 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "chatUserId" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/chat/chat-backend.tesl" 198 (list) (lambda () (reject "not logged in: set chatUserId cookie" #:http-code 401)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([uid (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/chat/chat-backend.tesl" 200 (list (cons 'uid uid)) (lambda () (let ([existing (let ([tesl_match (select-one (from ChatUser) (where (==. (entity-field-ref ChatUser 'id) uid)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl-case-1 (raw-value existing)]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/chat/chat-backend.tesl" 203 (list) (lambda () (reject "user not found" #:http-code 401)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([u (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/chat/chat-backend.tesl" 205 (list (cons 'u u)) (lambda () (let/check ([tesl-checked-2 (checkNonEmptyString uid)]) (let ([checkedUid tesl-checked-2]) (let/check ([tesl-checked-3 (checkNonEmptyString (raw-value u.username))]) (let ([checkedUsername tesl-checked-3]) (accept Authenticated #:value (SessionUser #:id checkedUid #:username checkedUsername)))))))))]))))))])))))

(define-checker
  (checkNonEmptyString [s : String])
  #:returns [s : String ::: (NonEmpty s)]
  (thsl-src! "example/chat/chat-backend.tesl" 214 (list (cons 's *s)) (lambda () (if (> (raw-value (tesl_import_String_length *s)) 0) (accept (NonEmpty s) #:value *s) (reject "cannot be empty string" #:http-code 400)))))

(define-checker
  (checkRoomId [id : String])
  #:returns [id : String ::: (ValidRoomId id)]
  (thsl-src! "example/chat/chat-backend.tesl" 222 (list (cons 'id *id)) (lambda () (if (> (raw-value (tesl_import_String_length *id)) 0) (accept (ValidRoomId id) #:value *id) (reject "invalid room id" #:http-code 400)))))

(define-capture roomIdCapture
  [roomId : String ::: (ValidRoomId roomId)]
  #:parser string-segment #:check checkRoomId)

(define-handler
  (login [req : LoginRequest])
  #:capabilities [chatRead]
  #:returns ChatUser
  (let ([existing (thsl-src! "example/chat/chat-backend.tesl" 233 (list (cons 'req *req)) (lambda () (let ([tesl_match (select-one (from ChatUser) (where (==. (entity-field-ref ChatUser 'username) (raw-value req.username))))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/chat/chat-backend.tesl" 234 (list (cons 'existing *existing) (cons 'req *req)) (lambda () (let ([tesl-case-4 (raw-value existing)]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Nothing)) (thsl-src! "example/chat/chat-backend.tesl" 236 (list) (lambda () (reject "user not found" #:http-code 401)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Something)) (let ([u (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "example/chat/chat-backend.tesl" 238 (list (cons 'u u)) (lambda () *u)))]))))))

(define-handler
  (seedUser [req : LoginRequest])
  #:capabilities [chatWrite]
  #:returns (Exists [userId : String] (? ChatUser _entity ::: (FromDb (Id == userId) _entity)))
  (let ([userId (thsl-src! "example/chat/chat-backend.tesl" 243 (list (cons 'req *req)) (lambda () (generatePrefixedId "usr")))]) (thsl-src! "example/chat/chat-backend.tesl" 244 (list (cons 'userId *userId) (cons 'req *req)) (lambda () (pack ([userId]) (insert-one! ChatUser (hash 'id userId 'username (raw-value req.username))))))))

(define-handler
  (listRooms [session : SessionUser ::: (Authenticated session)])
  #:capabilities [chatRead]
  #:returns (List Room)
  (let ([_ (thsl-src! "example/chat/chat-backend.tesl" 249 (list (cons 'session *session)) (lambda () (telemetry-event! "rooms.list" #:attributes (["user.id" (raw-value session.id)]))))]) (thsl-src! "example/chat/chat-backend.tesl" 250 (list (cons 'session *session)) (lambda () (select-many (from Room))))))

(define-handler
  (createRoom [session : SessionUser ::: (Authenticated session)] [req : CreateRoomRequest])
  #:capabilities [chatWrite]
  #:returns (Exists [roomId : String] (? Room _entity ::: (FromDb (Id == roomId) _entity)))
  (let ([roomId (thsl-src! "example/chat/chat-backend.tesl" 255 (list (cons 'session *session) (cons 'req *req)) (lambda () (generatePrefixedId "room")))]) (thsl-src! "example/chat/chat-backend.tesl" 256 (list (cons 'roomId *roomId) (cons 'session *session) (cons 'req *req)) (lambda () (pack ([roomId]) (insert-one! Room (hash 'id roomId 'name (raw-value req.name) 'createdAt (raw-value (nowMillis)))))))))

(define-handler
  (getMessages [session : SessionUser ::: (Authenticated session)] [roomId : String ::: (ValidRoomId roomId)])
  #:capabilities [chatRead]
  #:returns (List Message)
  (let ([_ (thsl-src! "example/chat/chat-backend.tesl" 263 (list (cons 'session *session) (cons 'roomId *roomId)) (lambda () (telemetry-event! "messages.get" #:attributes (["room.id" *roomId] ["user.id" (raw-value session.id)]))))]) (thsl-src! "example/chat/chat-backend.tesl" 264 (list (cons 'session *session) (cons 'roomId *roomId)) (lambda () (select-many (from Message) (where (==. (entity-field-ref Message 'roomId) roomId)))))))

(define-handler
  (postMessage [session : SessionUser ::: (Authenticated session)] [roomId : String ::: (ValidRoomId roomId)] [req : PostMessageRequest])
  #:capabilities [chatWrite chatPubSub chatQueue]
  #:returns (Exists [msgId : String] (? Message _entity ::: (FromDb (Id == msgId) _entity)))
  (let ([msgId (thsl-src! "example/chat/chat-backend.tesl" 271 (list (cons 'session *session) (cons 'roomId *roomId) (cons 'req *req)) (lambda () (generatePrefixedId "msg")))]) (thsl-src! "example/chat/chat-backend.tesl" 272 (list (cons 'msgId *msgId) (cons 'session *session) (cons 'roomId *roomId) (cons 'req *req)) (lambda () (call-with-queue-transaction (lambda () (begin (publish-event! RoomMessages (format "~a" *roomId) (NewMessage msgId (raw-value session.id) (raw-value session.username) (raw-value req.content) (raw-value (nowMillis)))) (begin (enqueue! NotificationQueue (NotifyJob #:senderName (raw-value session.username) #:roomName *roomId #:content (raw-value req.content))) (pack ([msgId]) (insert-one! Message (hash 'id msgId 'roomId roomId 'userId (raw-value session.id) 'username (raw-value session.username) 'content (raw-value req.content) 'createdAt (raw-value (nowMillis)))))))))))))

(define/pow
  (notifyWorker [job : NotifyJob ::: (FromQueue (Id == jobId) job)])
  #:returns NotifyJob
  (let ([_ (thsl-src! "example/chat/chat-backend.tesl" 318 (list (cons 'job *job)) (lambda () (telemetry-event! "notify.job" #:attributes (["sender" (raw-value job.senderName)] ["room" (raw-value job.roomName)]))))]) (thsl-src! "example/chat/chat-backend.tesl" 319 (list (cons 'job *job)) (lambda () (if (tesl-equal? (raw-value job.senderName) "anna") (reject "notifications blocked for anna" #:http-code 500) *job)))))

(define/pow
  (handleDeadNotify [job : NotifyJob ::: (FromDeadQueue (Id == jobId) job)])
  #:capabilities [deadLetterCap]
  #:returns NotifyJob
  (let ([_ (thsl-src! "example/chat/chat-backend.tesl" 331 (list (cons 'job *job)) (lambda () (telemetry-event! "notify.dead" #:attributes (["sender" (raw-value job.senderName)] ["room" (raw-value job.roomName)]))))]) (let ([_ (thsl-src! "example/chat/chat-backend.tesl" 332 (list (cons 'job *job)) (lambda () (publish-event! RoomMessages (format "~a" (raw-value job.roomName)) (NotifyFailed (raw-value job.senderName) (raw-value job.roomName)))))]) (thsl-src! "example/chat/chat-backend.tesl" 333 (list (cons 'job *job)) (lambda () *job)))))

(define ChatServer-sse-routes
  (list (list (list "events" "rooms") cookieAuth RoomMessages (sse-key-capture roomIdCapture))))
(define-api ChatApi
  [seedUser :
    "users"
    :> (ReqBody JSON [req : LoginRequest])
    :> (Post JSON (Exists [userId : String] (? ChatUser _entity ::: (FromDb (Id == userId) _entity))))
    ]
  [login :
    "login"
    :> (ReqBody JSON [req : LoginRequest])
    :> (Post JSON ChatUser)
    ]
  [listRooms :
    (Auth [session : SessionUser ::: (Authenticated session)] #:via cookieAuth)
    :> "rooms"
    :> (Get JSON (List Room))
    ]
  [createRoom :
    (Auth [session : SessionUser ::: (Authenticated session)] #:via cookieAuth)
    :> "rooms"
    :> (ReqBody JSON [req : CreateRoomRequest])
    :> (Post JSON (Exists [roomId : String] (? Room _entity ::: (FromDb (Id == roomId) _entity))))
    ]
  [getMessages :
    (Auth [session : SessionUser ::: (Authenticated session)] #:via cookieAuth)
    :> "rooms"
    :> (Capture roomIdCapture [roomId : String ::: (ValidRoomId roomId)])
    :> "messages"
    :> (Get JSON (List Message))
    ]
  [postMessage :
    (Auth [session : SessionUser ::: (Authenticated session)] #:via cookieAuth)
    :> "rooms"
    :> (Capture roomIdCapture [roomId : String ::: (ValidRoomId roomId)])
    :> "messages"
    :> (ReqBody JSON [req : PostMessageRequest])
    :> (Post JSON (Exists [msgId : String] (? Message _entity ::: (FromDb (Id == msgId) _entity))))
    ]
)

(define-server ChatServer
  #:api ChatApi
  [seedUser seedUser]
  [login login]
  [listRooms listRooms]
  [createRoom createRoom]
  [getMessages getMessages]
  [postMessage postMessage]
)

(module+ test
  (require rackunit)
  (test-case "rooms require authentication"
    (call-with-fresh-memory-db (list ChatDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (chatRead)
              (define rooms (dispatch-api-test-request ChatServer 'get (list "rooms") #:headers (hash) #:capabilities (list chatRead)))
              (check-true (raw-value (statusClientError (raw-value (api-test-field-access-ref rooms 'status)))))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "chat flow can reuse ids and fields from returned JSON"
    (call-with-fresh-memory-db (list ChatDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (chatRead chatWrite chatPubSub chatQueue)
              (define createdUser (dispatch-api-test-request ChatServer 'post (list "users") #:headers (hash) #:body (hash (string->symbol "username") "alice") #:capabilities (list chatRead chatWrite chatPubSub chatQueue)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref createdUser 'status)))))
              (check-true (raw-value (hasField "id" (raw-value (api-test-field-access-ref createdUser 'body)))))
              (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref createdUser 'body) 'username)) "alice")
              (define userId (jsonString (raw-value (api-test-field-access-ref (api-test-field-access-ref createdUser 'body) 'id))))
              (define createdRoom (dispatch-api-test-request ChatServer 'post (list "rooms") #:cookie (string-append "chatUserId=" (api-test-string-fragment (raw-value userId))) #:headers (hash) #:body (hash (string->symbol "name") "General") #:capabilities (list chatRead chatWrite chatPubSub chatQueue)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref createdRoom 'status)))))
              (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref createdRoom 'body) 'name)) "General")
              (define roomIdJson (bodyField "id" (raw-value createdRoom)))
              (define roomId (jsonString (raw-value roomIdJson)))
              (define roomName (jsonString (raw-value (api-test-field-access-ref (api-test-field-access-ref createdRoom 'body) 'name))))
              (define posted (dispatch-api-test-request ChatServer 'post (list "rooms" (api-test-path-fragment (raw-value roomId)) "messages") #:cookie (string-append "chatUserId=" (api-test-string-fragment (raw-value userId))) #:headers (hash) #:body (hash (string->symbol "content") (string-append "hello " (api-test-string-fragment (raw-value roomName)))) #:capabilities (list chatRead chatWrite chatPubSub chatQueue)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref posted 'status)))))
              (define postedRoomId (bodyField "roomId" (raw-value posted)))
              (check-equal? (raw-value (jsonString (raw-value postedRoomId))) roomId)
              (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref posted 'body) 'userId)) userId)
              (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref posted 'body) 'username)) "alice")
              (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref posted 'body) 'content)) "hello General")
              (define rooms (dispatch-api-test-request ChatServer 'get (list "rooms") #:cookie (string-append "chatUserId=" (api-test-string-fragment (raw-value userId))) #:headers (hash) #:capabilities (list chatRead chatWrite chatPubSub chatQueue)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref rooms 'status)))))
              (check-true (raw-value (isNotEmpty (raw-value (api-test-field-access-ref rooms 'body)))))
              (check-equal? (raw-value (jsonLength (raw-value (api-test-field-access-ref rooms 'body)))) 1)
              (check-true (raw-value (includesWhere (hash 'id (raw-value roomId) 'name (raw-value roomName)) (raw-value (api-test-field-access-ref rooms 'body)))))
              (check-true (raw-value (excludesWhere (hash 'name "Random") (raw-value (api-test-field-access-ref rooms 'body)))))
              (define firstRoom (arrayAt 0 (raw-value (api-test-field-access-ref rooms 'body))))
              (check-true (raw-value (hasField "createdAt" (raw-value firstRoom))))
              (define roomCreatedAt (fieldAt "createdAt" (raw-value firstRoom)))
              (check-true (raw-value (>= (raw-value (jsonInt (raw-value roomCreatedAt))) 0)))
              (define messages (dispatch-api-test-request ChatServer 'get (list "rooms" (api-test-path-fragment (raw-value roomId)) "messages") #:cookie (string-append "chatUserId=" (api-test-string-fragment (raw-value userId))) #:headers (hash) #:capabilities (list chatRead chatWrite chatPubSub chatQueue)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref messages 'status)))))
              (check-true (raw-value (hasLength 1 (raw-value (api-test-field-access-ref messages 'body)))))
              (check-true (raw-value (includesWhere (hash 'content "hello General" 'userId (raw-value userId)) (raw-value (api-test-field-access-ref messages 'body)))))
              (define firstMessage (arrayAt 0 (raw-value (api-test-field-access-ref messages 'body))))
              (check-equal? (raw-value (fieldAt "userId" (raw-value firstMessage))) userId)
              (define firstContent (fieldAt "content" (raw-value firstMessage)))
              (check-true (raw-value (jsonContains "General" (raw-value firstContent))))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "seed can prepare authenticated chat state"
    (call-with-fresh-memory-db (list ChatDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (chatRead chatWrite)
              (insert-one! ChatUser (hash 'id "usr-seeded" 'username "seeded-alice"))
              (insert-one! Room (hash 'id "room-seeded" 'name "Seeded room" 'createdAt 0))
              (insert-one! Message (hash 'id "msg-seeded" 'roomId "room-seeded" 'userId "usr-seeded" 'username "seeded-alice" 'content "hello from seed" 'createdAt 0))
              (define userId "usr-seeded")
              (define roomId "room-seeded")
              (define rooms (dispatch-api-test-request ChatServer 'get (list "rooms") #:cookie (string-append "chatUserId=" (api-test-string-fragment (raw-value userId))) #:headers (hash) #:capabilities (list chatRead chatWrite)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref rooms 'status)))))
              (check-true (raw-value (hasLength 1 (raw-value (api-test-field-access-ref rooms 'body)))))
              (define firstRoom (arrayAt 0 (raw-value (api-test-field-access-ref rooms 'body))))
              (check-equal? (raw-value (fieldAt "name" (raw-value firstRoom))) "Seeded room")
              (define messages (dispatch-api-test-request ChatServer 'get (list "rooms" (api-test-path-fragment (raw-value roomId)) "messages") #:cookie (string-append "chatUserId=" (api-test-string-fragment (raw-value userId))) #:headers (hash) #:capabilities (list chatRead chatWrite)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref messages 'status)))))
              (check-true (raw-value (hasLength 1 (raw-value (api-test-field-access-ref messages 'body)))))
              (define firstMessage (arrayAt 0 (raw-value (api-test-field-access-ref messages 'body))))
              (check-equal? (raw-value (fieldAt "username" (raw-value firstMessage))) "seeded-alice")
              (check-equal? (raw-value (fieldAt "content" (raw-value firstMessage))) "hello from seed")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "room streams buffer messages while queue jobs are processed separately"
    (call-with-fresh-memory-db (list ChatDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (chatRead chatWrite chatPubSub chatQueue notifyCap)
              (insert-one! ChatUser (hash 'id "usr-alice" 'username "alice"))
              (insert-one! ChatUser (hash 'id "usr-bob" 'username "bob"))
              (insert-one! Room (hash 'id "room-live" 'name "Live room" 'createdAt 0))
              (define roomId "room-live")
              (define aliceId "usr-alice")
              (define bobId "usr-bob")
              (define stream (subscribe ChatServer-sse-routes (list "events" "rooms" (api-test-path-fragment (raw-value roomId))) #:cookie (string-append "chatUserId=" (api-test-string-fragment (raw-value aliceId))) #:headers (hash) #:name "/events/rooms/{roomId}"))
              (define posted (dispatch-api-test-request ChatServer 'post (list "rooms" (api-test-path-fragment (raw-value roomId)) "messages") #:cookie (string-append "chatUserId=" (api-test-string-fragment (raw-value bobId))) #:headers (hash) #:body (hash (string->symbol "content") "Hello from Bob") #:capabilities (list chatRead chatWrite chatPubSub chatQueue notifyCap)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref posted 'status)))))
              (check-equal? (raw-value (pendingJobCount NotificationQueue)) 1)
              (define queued (processNextJob NotificationQueue))
              (define job (expectJobOk (raw-value queued)))
              (check-equal? (raw-value (api-test-field-access-ref job 'senderName)) "bob")
              (check-equal? (raw-value (api-test-field-access-ref job 'roomName)) roomId)
              (check-equal? (raw-value (api-test-field-access-ref job 'content)) "Hello from Bob")
              (check-equal? (raw-value (pendingJobCount NotificationQueue)) 0)
              (define events (collect (raw-value stream) #:count 1 #:timeout-ms 1500))
              (check-true (raw-value (isNotEmpty (raw-value events))))
              (check-true (raw-value (includesWhere (hash 'tag "NewMessage" 'fields (hash 'content "Hello from Bob" 'username "bob")) (raw-value events))))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "failed notification jobs publish dead-letter events to room streams"
    (call-with-fresh-memory-db (list ChatDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (chatRead chatWrite chatPubSub chatQueue notifyCap deadLetterCap)
              (insert-one! ChatUser (hash 'id "usr-anna" 'username "anna"))
              (insert-one! Room (hash 'id "room-failure" 'name "Failure room" 'createdAt 0))
              (define roomId "room-failure")
              (define annaId "usr-anna")
              (define stream (subscribe ChatServer-sse-routes (list "events" "rooms" (api-test-path-fragment (raw-value roomId))) #:cookie (string-append "chatUserId=" (api-test-string-fragment (raw-value annaId))) #:headers (hash) #:name "/events/rooms/{roomId}"))
              (define posted (dispatch-api-test-request ChatServer 'post (list "rooms" (api-test-path-fragment (raw-value roomId)) "messages") #:cookie (string-append "chatUserId=" (api-test-string-fragment (raw-value annaId))) #:headers (hash) #:body (hash (string->symbol "content") "notify failure demo") #:capabilities (list chatRead chatWrite chatPubSub chatQueue notifyCap deadLetterCap)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref posted 'status)))))
              (check-equal? (raw-value (pendingJobCount NotificationQueue)) 1)
              (define firstAttempt (processNextJob NotificationQueue))
              (define firstError (expectJobFailed (raw-value firstAttempt)))
              (check-true (raw-value (isNotNull (raw-value firstError))))
              (define secondAttempt (processNextJob NotificationQueue))
              (define secondError (expectJobFailed (raw-value secondAttempt)))
              (check-true (raw-value (isNotNull (raw-value secondError))))
              (define thirdAttempt (processNextJob NotificationQueue))
              (define thirdError (expectJobFailed (raw-value thirdAttempt)))
              (check-true (raw-value (isNotNull (raw-value thirdError))))
              (check-equal? (raw-value (pendingJobCount NotificationQueue)) 0)
              (define deadResult (processNextDeadJob NotificationQueue))
              (define deadJob (expectJobOk (raw-value deadResult)))
              (check-equal? (raw-value (api-test-field-access-ref deadJob 'senderName)) "anna")
              (check-equal? (raw-value (api-test-field-access-ref deadJob 'roomName)) roomId)
              (define events (collect (raw-value stream) #:timeout-ms 1500))
              (check-true (raw-value (includesWhere (hash 'tag "NewMessage" 'fields (hash 'content "notify failure demo")) (raw-value events))))
              (check-true (raw-value (includesWhere (hash 'tag "NotifyFailed" 'fields (hash 'senderName "anna" 'roomName (raw-value roomId))) (raw-value events))))
            )
          ))
      ))
  )
)

(module+ main
  (thsl-src! "example/chat/chat-backend.tesl" 540 (list) (lambda () (with-capabilities (chatService notifyCap deadLetterCap envRead) (call-with-database ChatDatabase (lambda () (let ([_ (init-opentelemetry! #:service-name "chat-backend" #:endpoint "in-memory" #:console? #t)]) (let ([port (raw-value (envInt "CHAT_PORT" 3000))]) (begin (start-workers! NotificationQueueWorkers (list notifyCap deadLetterCap) #:concurrency 3) (begin (start-dead-workers! NotificationQueueDeadWorkers (list notifyCap deadLetterCap) #:concurrency 3) (serve ChatServer #:port port #:capabilities (list chatService notifyCap deadLetterCap envRead) #:static-dir "example/chat/frontend" #:sse-routes ChatServer-sse-routes)))))))))))

(define NotificationQueueWorkers
  (list (cons NotificationQueue notifyWorker)))
(register-api-test-workers! (list (list NotificationQueue 'NotifyJob notifyWorker)))

(define NotificationQueueDeadWorkers
  (list (cons NotificationQueue handleDeadNotify)))
(register-api-test-dead-workers! (list (list NotificationQueue 'NotifyJob handleDeadNotify)))
