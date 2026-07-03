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
  (only-in tesl/tesl/env with-env-bootstrap)
  (prefix-in __tart_ (only-in tesl/tesl/agent defineAgent withTools tool anthropic openai mistral local tesl-agent-decode-args))
  (only-in tesl/tesl/prelude String Unit Bool)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/env envInt requireEnv envRead)
  (only-in tesl/tesl/telemetry initTelemetry)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/queue pubsub)
  (only-in tesl/tesl/agent aiProvider Agent Conversation anthropic mistral mockProvider mockToolProvider toolUseStep textStep newConversation conversationFrom conversationJson conversationLength converseStreaming turnReply turnConversation replyText)
)


(provide ChatServer replyTurn loadConversation lookupOrderStatus Consumer lookupOrderStatus-signature loadConversation-signature replyTurn-signature)

(define Authenticated 'Authenticated)

(define-capability convAi (implies aiProvider))

(define-capability convRead (implies dbRead))

(define-capability convWrite (implies dbWrite))

(define-capability convPubSub (implies pubsub))

(define-capability httpAuth)

(define-capability convService (implies convAi convRead convWrite convPubSub httpAuth))

(define-record Consumer
  [id : String]
  [provider : String]
  [apiKey : String]
)

(define/pow
  (providerOf [request : HttpRequest])
  #:returns String
  (thsl-src-control! "example/ai-conversation-service.tesl" 83 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "provider" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([p (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/ai-conversation-service.tesl" 84 (list (cons 'p p)) (lambda () *p)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/ai-conversation-service.tesl" 85 (list) (lambda () (raw-value "claude")))])))))

(define/pow
  (keyOf [request : HttpRequest])
  #:returns String
  (thsl-src-control! "example/ai-conversation-service.tesl" 90 (list (cons 'request *request)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_Dict_lookup "x-llm-key" (raw-value request.headers)))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([k (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/ai-conversation-service.tesl" 91 (list (cons 'k k)) (lambda () *k)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/ai-conversation-service.tesl" 92 (list) (lambda () (raw-value "")))])))))

(define-auther
  (consumerAuth [request : HttpRequest])
  #:capabilities [httpAuth]
  #:returns [requestUser : Consumer ::: (Authenticated requestUser)]
  (thsl-src-control! "example/ai-conversation-service.tesl" 96 (list (cons 'request *request)) (lambda () (let ([tesl-case-2 (raw-value (tesl_import_Dict_lookup "consumerId" (raw-value request.cookies)))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([cid (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "example/ai-conversation-service.tesl" 98 (list (cons 'cid cid)) (lambda () (accept Authenticated #:value (Consumer #:id *cid #:provider (providerOf request) #:apiKey (keyOf request))))))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "example/ai-conversation-service.tesl" 99 (list) (lambda () (reject "Missing consumer identity" #:http-code 401)))])))))

(define-entity ConversationRecord
  #:source (make-hash)
  #:table ai_conversations
  #:primary-key id
  [Id id : String]
  [OwnerId ownerId : String]
  [Transcript transcript : String]
)

(define-entity Order
  #:source (make-hash)
  #:table orders
  #:primary-key id
  [Id id : String]
  [Status status : String]
)

(define-database ConversationDb
  #:backend postgres
  #:database (tesl-env-raw "TESL_POSTGRES_DATABASE")
  #:user (tesl-env-raw "TESL_POSTGRES_USER")
  #:password (tesl-env-raw "TESL_POSTGRES_PASSWORD")
  #:server (tesl-env-raw "TESL_POSTGRES_HOST")
  #:port (tesl-env-int-raw "TESL_POSTGRES_PORT" 5432)
  #:schema ai_conversations
  #:entities ConversationRecord Order)

(define-adt ChatEvent
  [Chunk [content : String]]
)

(define-channel ChatStream)

(define/pow
  (lookupOrderStatus [orderId : String])
  #:capabilities [convRead]
  #:returns String
  (thsl-src! "example/ai-conversation-service.tesl" 143 (list (cons 'orderId *orderId)) (lambda () (if (tesl-equal? *orderId "12") (raw-value "Under processing") (if (tesl-equal? *orderId "13") (raw-value "Shipped") (let ([tesl-case-3 (raw-value (let ([tesl_match (select-one (from Order) (where (==. (entity-field-ref Order 'id) orderId)))]) (if tesl_match (Something tesl_match) Nothing)))]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([o (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "example/ai-conversation-service.tesl" 149 (list (cons 'o o)) (lambda () (raw-value (raw-value o.status)))))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "example/ai-conversation-service.tesl" 150 (list) (lambda () (raw-value "no such order")))])))))))

(define MistralAgent
  (with-env-bootstrap (__tart_withTools (__tart_defineAgent (raw-value (mistral (raw-value (requireEnv "MISTRAL_API_KEY")) "mistral-large-latest")) (raw-value "You are a concise support assistant. Use lookupOrderStatus for order questions.") (raw-value 512)) (list (__tart_tool "lookupOrderStatus" "\226\148\128\226\148\128 Tool: a typed function the model may call, grounded in the database \226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128 The result is derived ONLY from a row fetched through the trusted SQL boundary, which carries a FromDb proof \226\128\148 so the model cannot make the tool assert a status for an order that isn't in the database (data integrity by construction)." "{\"type\":\"object\",\"properties\":{\"orderId\":{\"type\":\"string\"}},\"required\":[\"orderId\"]}" (lambda (_args) (__tart_tesl-agent-decode-args _args (list (cons "orderId" 'string)))) (lambda (_decoded) (apply lookupOrderStatus _decoded)))))))

(define/pow
  (claudeAgentFor [c : Consumer])
  #:capabilities [convAi convRead]
  #:returns Agent
  (thsl-src! "example/ai-conversation-service.tesl" 171 (list (cons 'c *c)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (anthropic (tesl-dot/runtime c 'apiKey) "claude-opus-4-8")) (raw-value "You are a concise support assistant. Use lookupOrderStatus for order questions.") (raw-value 512)) (list (__tart_tool "lookupOrderStatus" "\226\148\128\226\148\128 Tool: a typed function the model may call, grounded in the database \226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128 The result is derived ONLY from a row fetched through the trusted SQL boundary, which carries a FromDb proof \226\128\148 so the model cannot make the tool assert a status for an order that isn't in the database (data integrity by construction)." "{\"type\":\"object\",\"properties\":{\"orderId\":{\"type\":\"string\"}},\"required\":[\"orderId\"]}" (lambda (_args) (__tart_tesl-agent-decode-args _args (list (cons "orderId" 'string)))) (lambda (_decoded) (apply lookupOrderStatus _decoded))))))))

(define/pow
  (agentFor [c : Consumer])
  #:capabilities [convAi convRead]
  #:returns Agent
  (thsl-src! "example/ai-conversation-service.tesl" 182 (list (cons 'c *c)) (lambda () (if (tesl-equal? (tesl-dot/runtime c 'provider) "mistral") (raw-value MistralAgent) (raw-value (claudeAgentFor c))))))

(define/pow
  (loadConversation [agent : Agent] [requestUser : Consumer] [conversationId : String])
  #:capabilities [convRead]
  #:returns Conversation
  (thsl-src-control! "example/ai-conversation-service.tesl" 193 (list (cons 'agent *agent) (cons 'requestUser *requestUser) (cons 'conversationId *conversationId)) (lambda () (let ([tesl-case-4 (raw-value (let ([tesl_match (select-one (from ConversationRecord) (where (==. (entity-field-ref ConversationRecord 'id) conversationId)) (where (==. (entity-field-ref ConversationRecord 'ownerId) (tesl-dot/runtime requestUser 'id))))]) (if tesl_match (Something tesl_match) Nothing)))]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Something)) (let ([r (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "example/ai-conversation-service.tesl" 194 (list (cons 'r r)) (lambda () (raw-value (raw-value (conversationFrom *agent (tesl-dot/runtime r 'transcript)))))))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Nothing)) (thsl-src! "example/ai-conversation-service.tesl" 195 (list) (lambda () (raw-value (raw-value (newConversation *agent)))))])))))

(define/pow
  (updateTranscript [requestUser : Consumer] [conversationId : String] [json : String])
  #:capabilities [convWrite]
  #:returns Unit
  (thsl-src! "example/ai-conversation-service.tesl" 199 (list (cons 'requestUser *requestUser) (cons 'conversationId *conversationId) (cons 'json *json)) (lambda () (void (update-many! (from ConversationRecord) (hash (entity-field-ref ConversationRecord 'transcript) json) (where (==. (entity-field-ref ConversationRecord 'id) conversationId)) (where (==. (entity-field-ref ConversationRecord 'ownerId) (tesl-dot/runtime requestUser 'id))))))))

(define/pow
  (insertTranscript [requestUser : Consumer] [conversationId : String] [json : String])
  #:capabilities [convWrite]
  #:returns Unit
  (let ([rows (thsl-src! "example/ai-conversation-service.tesl" 205 (list (cons 'requestUser *requestUser) (cons 'conversationId *conversationId) (cons 'json *json)) (lambda () (list (hash 'id *conversationId 'ownerId (tesl-dot/runtime requestUser 'id) 'transcript *json))))]) (thsl-src! "example/ai-conversation-service.tesl" 206 (list (cons 'rows *rows) (cons 'requestUser *requestUser) (cons 'conversationId *conversationId) (cons 'json *json)) (lambda () (raw-value (insert-many! (from ConversationRecord) rows))))))

(define/pow
  (saveConversation [requestUser : Consumer] [conversationId : String] [conv : Conversation])
  #:capabilities [convRead convWrite]
  #:returns Unit
  (let ([json (thsl-src! "example/ai-conversation-service.tesl" 213 (list (cons 'requestUser *requestUser) (cons 'conversationId *conversationId) (cons 'conv *conv)) (lambda () (raw-value (conversationJson *conv))))]) (thsl-src! "example/ai-conversation-service.tesl" 214 (list (cons 'json *json) (cons 'requestUser *requestUser) (cons 'conversationId *conversationId) (cons 'conv *conv)) (lambda () (call-with-queue-transaction (lambda () (let ([tesl-case-5 (raw-value (let ([tesl_match (select-one (from ConversationRecord) (where (==. (entity-field-ref ConversationRecord 'id) conversationId)) (where (==. (entity-field-ref ConversationRecord 'ownerId) (tesl-dot/runtime requestUser 'id))))]) (if tesl_match (Something tesl_match) Nothing)))]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Something)) (let ([r (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "example/ai-conversation-service.tesl" 216 (list (cons 'r r)) (lambda () (raw-value (updateTranscript requestUser conversationId json)))))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Nothing)) (thsl-src! "example/ai-conversation-service.tesl" 217 (list) (lambda () (raw-value (insertTranscript requestUser conversationId json))))]))))))))

(define/pow
  (publishChunk [conversationId : String] [event : String])
  #:capabilities [convPubSub]
  #:returns Unit
  (thsl-src! "example/ai-conversation-service.tesl" 225 (list (cons 'conversationId *conversationId) (cons 'event *event)) (lambda () (publish-event! ChatStream (format "~a" *conversationId) (Chunk event)))))

(define/pow
  (replyTurn [agent : Agent] [requestUser : Consumer] [conversationId : String] [message : String])
  #:capabilities [convService]
  #:returns String
  (let ([conv (thsl-src! "example/ai-conversation-service.tesl" 234 (list (cons 'agent *agent) (cons 'requestUser *requestUser) (cons 'conversationId *conversationId) (cons 'message *message)) (lambda () (loadConversation agent requestUser conversationId)))]) (let ([turn (thsl-src! "example/ai-conversation-service.tesl" 235 (list (cons 'conv *conv) (cons 'agent *agent) (cons 'requestUser *requestUser) (cons 'conversationId *conversationId) (cons 'message *message)) (lambda () (raw-value (converseStreaming (raw-value conv) *message (let () (define/pow (tesl-lambda-6 [event : String]) #:returns Unit (publishChunk conversationId event)) tesl-lambda-6)))))]) (let ([_ (thsl-src! "example/ai-conversation-service.tesl" 236 (list (cons 'turn *turn) (cons 'conv *conv) (cons 'agent *agent) (cons 'requestUser *requestUser) (cons 'conversationId *conversationId) (cons 'message *message)) (lambda () (saveConversation requestUser conversationId (raw-value (turnConversation (raw-value turn))))))]) (thsl-src! "example/ai-conversation-service.tesl" 237 (list (cons '_ *_) (cons 'turn *turn) (cons 'conv *conv) (cons 'agent *agent) (cons 'requestUser *requestUser) (cons 'conversationId *conversationId) (cons 'message *message)) (lambda () (raw-value (replyText (raw-value (turnReply (raw-value turn)))))))))))

(define-record MessageRequest
  [message : String]
)

(define (tesl-codec-encode-MessageRequest _v)
  (error "toJson is forbidden for type MessageRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-MessageRequest-0 _j)
  (define _f_message (tesl-decode-prim-field _j "message" tesl-decode-prim-string))
  (record-value 'MessageRequest (hash 'message _f_message)))
(register-type-codec! 'MessageRequest tesl-codec-encode-MessageRequest (list tesl-codec-decode-MessageRequest-0))

(define/pow
  (parseConversationId [id : String])
  #:returns String
  (thsl-src! "example/ai-conversation-service.tesl" 255 (list (cons 'id *id)) (lambda () *id)))

(define-capture conversationIdCapture
  [conversationIdCapture : String]
  #:parser string-segment #:check parseConversationId)

(define-handler
  (sendMessage [requestUser : Consumer ::: (Authenticated requestUser)] [conversationId : String] [req : MessageRequest])
  #:capabilities [convService]
  #:returns String
  (thsl-src! "example/ai-conversation-service.tesl" 265 (list (cons 'requestUser *requestUser) (cons 'conversationId *conversationId) (cons 'req *req)) (lambda () (replyTurn (agentFor requestUser) requestUser conversationId (raw-value req.message)))))

(define ChatServer-sse-routes
  (list (list (list "chat" "events") consumerAuth ChatStream (sse-key-capture conversationIdCapture))))
(define-api ChatApi
  [sendMessage :
    (Auth [requestUser : Consumer ::: (Authenticated requestUser)] #:via consumerAuth)
    :> "chat"
    :> (Capture conversationIdCapture [conversationId : String])
    :> (ReqBody JSON [req : MessageRequest])
    :> (Post JSON String)
    ]
)

(define-server ChatServer
  #:api ChatApi
  [sendMessage sendMessage]
)

(module+ main
  (thsl-src! "example/ai-conversation-service.tesl" 284 (list) (lambda () (with-capabilities (convService envRead) (call-with-database ConversationDb (lambda () (let ([_ (init-opentelemetry! #:service-name "ai-conversation-service" #:endpoint "in-memory" #:console? #t)]) (let ([port (raw-value (envInt "PORT" 8089))]) (serve ChatServer #:port port #:capabilities (list convService envRead) #:sse-routes ChatServer-sse-routes)))))))))

(module+ test
  (require rackunit)
  (test-case "tool reads order status from the database (grounded, not fabricated)"
    (with-capabilities (convService)
    (define seed (thsl-src! "example/ai-conversation-service.tesl" 302 (list) (lambda () (list (hash 'id "ord-1" 'status "shipped")))))
    (insert-many! (from Order) seed)
    (check-equal? (raw-value (thsl-src! "example/ai-conversation-service.tesl" 304 (list (cons 'seed seed)) (lambda () (lookupOrderStatus "ord-1")))) "shipped")
    (check-equal? (raw-value (thsl-src! "example/ai-conversation-service.tesl" 305 (list (cons 'seed seed)) (lambda () (lookupOrderStatus "ord-unknown")))) "no such order")
    )
  )

  (test-case "a streamed turn calls the DB tool and returns the reply"
    (with-capabilities (convService)
    (define seed (thsl-src! "example/ai-conversation-service.tesl" 311 (list) (lambda () (list (hash 'id "ord-2" 'status "delivered")))))
    (insert-many! (from Order) seed)
    (define call (thsl-src! "example/ai-conversation-service.tesl" 313 (list (cons 'seed seed)) (lambda () (raw-value (toolUseStep "lookupOrderStatus" "c1" "{\"orderId\":\"ord-2\"}")))))
    (define final (thsl-src! "example/ai-conversation-service.tesl" 314 (list (cons 'call call) (cons 'seed seed)) (lambda () (raw-value (textStep "Order ord-2 has been delivered.")))))
    (define agent (thsl-src! "example/ai-conversation-service.tesl" 315 (list (cons 'final final) (cons 'call call) (cons 'seed seed)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list call final))) (raw-value "sys") (raw-value 256)) (list)))))
    (define reply (thsl-src! "example/ai-conversation-service.tesl" 316 (list (cons 'agent agent) (cons 'final final) (cons 'call call) (cons 'seed seed)) (lambda () (replyTurn agent (Consumer #:id "alice" #:provider "claude" #:apiKey "test-key") "conv-tool" "where is ord-2?"))))
    (check-equal? (raw-value (thsl-src! "example/ai-conversation-service.tesl" 317 (list (cons 'reply reply) (cons 'agent agent) (cons 'final final) (cons 'call call) (cons 'seed seed)) (lambda () reply))) "Order ord-2 has been delivered.")
    )
  )

  (test-case "a consumer resumes their own conversation across calls (cross-instance)"
    (with-capabilities (convService)
    (define agent (thsl-src! "example/ai-conversation-service.tesl" 323 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "Hi Alice." "Sure \u2014 more."))) (raw-value "sys") (raw-value 256)) (list)))))
    (define alice (thsl-src! "example/ai-conversation-service.tesl" 324 (list (cons 'agent agent)) (lambda () (Consumer #:id "alice" #:provider "claude" #:apiKey "test-key"))))
    (define r1 (thsl-src! "example/ai-conversation-service.tesl" 325 (list (cons 'alice alice) (cons 'agent agent)) (lambda () (replyTurn agent alice "conv-1" "hello"))))
    (check-equal? (raw-value (thsl-src! "example/ai-conversation-service.tesl" 326 (list (cons 'r1 r1) (cons 'alice alice) (cons 'agent agent)) (lambda () r1))) "Hi Alice.")
    (define r2 (thsl-src! "example/ai-conversation-service.tesl" 327 (list (cons 'r1 r1) (cons 'alice alice) (cons 'agent agent)) (lambda () (replyTurn agent alice "conv-1" "tell me more"))))
    (check-equal? (raw-value (thsl-src! "example/ai-conversation-service.tesl" 328 (list (cons 'r2 r2) (cons 'r1 r1) (cons 'alice alice) (cons 'agent agent)) (lambda () r2))) "Sure \u2014 more.")
    )
  )

  (test-case "a consumer cannot access another consumer's conversation (isolation)"
    (with-capabilities (convService)
    (define agent (thsl-src! "example/ai-conversation-service.tesl" 334 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "secret for alice"))) (raw-value "sys") (raw-value 256)) (list)))))
    (define alice (thsl-src! "example/ai-conversation-service.tesl" 335 (list (cons 'agent agent)) (lambda () (Consumer #:id "alice" #:provider "claude" #:apiKey "test-key"))))
    (define bob (thsl-src! "example/ai-conversation-service.tesl" 336 (list (cons 'alice alice) (cons 'agent agent)) (lambda () (Consumer #:id "bob" #:provider "mistral" #:apiKey "test-key"))))
    (define tesl-ignored-7 (thsl-src! "example/ai-conversation-service.tesl" 337 (list (cons 'bob bob) (cons 'alice alice) (cons 'agent agent)) (lambda () (replyTurn agent alice "shared-id" "remember my secret"))))
    (define bobConv (thsl-src! "example/ai-conversation-service.tesl" 338 (list (cons 'bob bob) (cons 'alice alice) (cons 'agent agent)) (lambda () (loadConversation agent bob "shared-id"))))
    (check-equal? (raw-value (thsl-src! "example/ai-conversation-service.tesl" 339 (list (cons 'bobConv bobConv) (cons 'bob bob) (cons 'alice alice) (cons 'agent agent)) (lambda () (raw-value (conversationLength (raw-value bobConv)))))) 0)
    )
  )

)
