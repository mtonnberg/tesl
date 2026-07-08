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
  (prefix-in __tart_ (only-in tesl/tesl/agent defineAgent withTools tool anthropic openai mistral local tesl-agent-decode-args))
  (only-in tesl/tesl/prelude String Unit)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/queue FromQueue queueRead queueWrite pubsub)
  (only-in tesl/tesl/string [String.concat tesl_import_String_concat])
  (only-in tesl/tesl/api-test statusOk hasLength includesWhere subscribe collect JobResult JobOk JobFailed processNextJob pendingJobCount expectJobOk)
  (only-in tesl/tesl/agent aiProvider Agent Tool Conversation tool decodeAs mockToolProvider mockProvider toolUseStep textStep newConversation conversationFrom conversationJson converse turnReply turnConversation replyText)
)


(provide ReportServer)

(define-capture __inline_capturer_conversationId_1
  [conversationId : String]
  #:parser string-segment)

(define-capability reportAi (implies aiProvider))

(define-capability reportRead (implies dbRead))

(define-capability reportWrite (implies dbWrite))

(define-capability reportPubSub (implies pubsub))

(define-capability reportEnqueue (implies queueWrite))

(define-capability reportTurn (implies reportAi reportRead reportWrite reportPubSub reportEnqueue))

(define-capability reportWorker (implies queueRead reportAi reportRead reportWrite reportPubSub))

(define-entity ConversationRecord
  #:source (make-hash)
  #:table report_conversations
  #:primary-key id
  [Id id : String]
  [Transcript transcript : String]
)

(define-database ReportDb
  #:backend postgres
  #:database "demo"
  #:user "demo"
  #:password "demo"
  #:server "localhost"
  #:port 5432
  #:schema lesson70
  #:entities ConversationRecord)

(define-record ReportJob
  [conversationId : String]
  [kind : String]
)

(define (tesl-codec-encode-ReportJob _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'conversationId (tesl-encode-prim-string (raw-value (hash-ref _fields 'conversationId)))
        'kind (tesl-encode-prim-string (raw-value (hash-ref _fields 'kind)))
  ))
(define (tesl-codec-decode-ReportJob-0 _j)
  (define _f_conversationId (tesl-decode-prim-field _j "conversationId" tesl-decode-prim-string))
  (define _f_kind (tesl-decode-prim-field _j "kind" tesl-decode-prim-string))
  (record-value 'ReportJob (hash 'conversationId _f_conversationId 'kind _f_kind)))
(register-type-codec! 'ReportJob tesl-codec-encode-ReportJob (list tesl-codec-decode-ReportJob-0))

(define-record ReportSpec
  [kind : String]
)

(define (tesl-codec-encode-ReportSpec _v)
  (error "toJson is forbidden for type ReportSpec: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-ReportSpec-0 _j)
  (define _f_kind (tesl-decode-prim-field _j "kind" tesl-decode-prim-string))
  (record-value 'ReportSpec (hash 'kind _f_kind)))
(register-type-codec! 'ReportSpec tesl-codec-encode-ReportSpec (list tesl-codec-decode-ReportSpec-0))

(define-adt ChatEvent
  [Chunk [content : String]]
)

(define-channel ChatStream)

(define-queue ReportQueue
  #:database ReportDb
  #:job-types (ReportJob)
  #:max-attempts 1
  #:backoff exponential
  #:initial-delay 0)

(define/pow
  (validateReportSpec [argsJson : String])
  #:returns ReportSpec
  (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 175 (list (cons 'argsJson *argsJson)) (lambda () (raw-value (decodeAs "ReportSpec" *argsJson)))))

(define/pow
  (dispatchReport [conversationId : String] [spec : ReportSpec])
  #:capabilities [reportEnqueue]
  #:returns String
  (let ([_ (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 184 (list (cons 'conversationId *conversationId) (cons 'spec *spec)) (lambda () (enqueue! ReportQueue (ReportJob #:conversationId *conversationId #:kind (tesl-dot/runtime spec 'kind 'ReportSpec)))))]) (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 185 (list (cons 'conversationId *conversationId) (cons 'spec *spec)) (lambda () (raw-value (tesl_import_String_concat "Queued your report on: " (tesl-dot/runtime spec 'kind 'ReportSpec)))))))

(define/pow
  (reportTool [conversationId : String])
  #:capabilities [reportEnqueue]
  #:returns Tool
  (let ([argSchema (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 192 (list (cons 'conversationId *conversationId)) (lambda () "{\"type\":\"object\",\"properties\":{\"kind\":{\"type\":\"string\"}},\"required\":[\"kind\"]}"))]) (let ([toolDesc (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 193 (list (cons 'argSchema *argSchema) (cons 'conversationId *conversationId)) (lambda () "Generate a report for the user. Runs in the background; the user is told here when it is ready."))]) (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 194 (list (cons 'toolDesc *toolDesc) (cons 'argSchema *argSchema) (cons 'conversationId *conversationId)) (lambda () (raw-value (tool "requestReport" (raw-value toolDesc) (raw-value argSchema) validateReportSpec (raw-value (lambda (tesl-p-0-0) (dispatchReport *conversationId tesl-p-0-0))))))))))

(define/pow
  (loadConversation [agent : Agent] [conversationId : String])
  #:capabilities [reportRead]
  #:returns Conversation
  (thsl-src-control! "example/learn/lesson70-agent-async-work.tesl" 200 (list (cons 'agent *agent) (cons 'conversationId *conversationId)) (lambda () (let ([tesl-case-1 (raw-value (let ([tesl_match (select-one (from ConversationRecord) (where (==. (entity-field-ref ConversationRecord 'id) conversationId)))]) (if tesl_match (Something tesl_match) Nothing)))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([r (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 201 (list (cons 'r r)) (lambda () (raw-value (raw-value (conversationFrom *agent (tesl-dot/runtime r 'transcript 'ConversationRecord)))))))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 202 (list) (lambda () (raw-value (raw-value (newConversation *agent)))))])))))

(define/pow
  (updateTranscript [conversationId : String] [json : String])
  #:capabilities [reportWrite]
  #:returns Unit
  (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 206 (list (cons 'conversationId *conversationId) (cons 'json *json)) (lambda () (void (update-many! (from ConversationRecord) (hash (entity-field-ref ConversationRecord 'transcript) json) (where (==. (entity-field-ref ConversationRecord 'id) conversationId)))))))

(define/pow
  (insertTranscript [conversationId : String] [json : String])
  #:capabilities [reportWrite]
  #:returns Unit
  (let ([rows (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 212 (list (cons 'conversationId *conversationId) (cons 'json *json)) (lambda () (list (hash 'id *conversationId 'transcript *json))))]) (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 213 (list (cons 'rows *rows) (cons 'conversationId *conversationId) (cons 'json *json)) (lambda () (raw-value (insert-many! (from ConversationRecord) rows))))))

(define/pow
  (saveConversation [conversationId : String] [conv : Conversation])
  #:capabilities [reportRead reportWrite]
  #:returns Unit
  (let ([json (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 217 (list (cons 'conversationId *conversationId) (cons 'conv *conv)) (lambda () (raw-value (conversationJson *conv))))]) (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 218 (list (cons 'json *json) (cons 'conversationId *conversationId) (cons 'conv *conv)) (lambda () (call-with-queue-transaction (lambda () (let ([tesl-case-2 (raw-value (let ([tesl_match (select-one (from ConversationRecord) (where (==. (entity-field-ref ConversationRecord 'id) conversationId)))]) (if tesl_match (Something tesl_match) Nothing)))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([r (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 220 (list (cons 'r r)) (lambda () (raw-value (updateTranscript conversationId json)))))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 221 (list) (lambda () (raw-value (insertTranscript conversationId json))))]))))))))

(define/pow
  (publishChunk [conversationId : String] [event : String])
  #:capabilities [reportPubSub]
  #:returns Unit
  (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 228 (list (cons 'conversationId *conversationId) (cons 'event *event)) (lambda () (publish-event! ChatStream (format "~a" *conversationId) (Chunk event)))))

(define/pow
  (runTurn [agent : Agent] [conversationId : String] [message : String])
  #:capabilities [reportRead reportWrite reportAi]
  #:returns String
  (let ([conv (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 236 (list (cons 'agent *agent) (cons 'conversationId *conversationId) (cons 'message *message)) (lambda () (loadConversation agent conversationId)))]) (let ([turn (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 237 (list (cons 'conv *conv) (cons 'agent *agent) (cons 'conversationId *conversationId) (cons 'message *message)) (lambda () (raw-value (converse (raw-value conv) *message))))]) (let ([_ (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 238 (list (cons 'turn *turn) (cons 'conv *conv) (cons 'agent *agent) (cons 'conversationId *conversationId) (cons 'message *message)) (lambda () (saveConversation conversationId (raw-value (turnConversation (raw-value turn))))))]) (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 239 (list (cons '_ *_) (cons 'turn *turn) (cons 'conv *conv) (cons 'agent *agent) (cons 'conversationId *conversationId) (cons 'message *message)) (lambda () (raw-value (replyText (raw-value (turnReply (raw-value turn)))))))))))

(define/pow
  (resumeConversation [agent : Agent] [conversationId : String] [message : String])
  #:capabilities [reportRead reportWrite reportAi]
  #:returns String
  (let ([conv (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 247 (list (cons 'agent *agent) (cons 'conversationId *conversationId) (cons 'message *message)) (lambda () (loadConversation agent conversationId)))]) (let ([turn (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 248 (list (cons 'conv *conv) (cons 'agent *agent) (cons 'conversationId *conversationId) (cons 'message *message)) (lambda () (raw-value (converse (raw-value conv) *message))))]) (let ([_ (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 249 (list (cons 'turn *turn) (cons 'conv *conv) (cons 'agent *agent) (cons 'conversationId *conversationId) (cons 'message *message)) (lambda () (saveConversation conversationId (raw-value (turnConversation (raw-value turn))))))]) (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 250 (list (cons '_ *_) (cons 'turn *turn) (cons 'conv *conv) (cons 'agent *agent) (cons 'conversationId *conversationId) (cons 'message *message)) (lambda () (raw-value (replyText (raw-value (turnReply (raw-value turn)))))))))))

(define/pow
  (buildReport [kind : String])
  #:returns String
  (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 256 (list (cons 'kind *kind)) (lambda () (raw-value (tesl_import_String_concat (raw-value (tesl_import_String_concat "Report [" *kind)) "]: 3 items, all healthy.")))))

(define/pow
  (generateReport [job : ReportJob ::: (FromQueue (Id == jobId) job)])
  #:capabilities [reportWorker]
  #:returns ReportJob
  (let ([report (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 261 (list (cons 'job *job)) (lambda () (buildReport (raw-value job.kind))))]) (let ([resumeAgent (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 266 (list (cons 'report *report) (cons 'job *job)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "Your report is ready \u2014 I've posted it above."))) (raw-value "You manage the user's reports.") (raw-value 256)) (list))))]) (let ([resultMsg (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 272 (list (cons 'resumeAgent *resumeAgent) (cons 'report *report) (cons 'job *job)) (lambda () (raw-value (tesl_import_String_concat "The report finished. Result: " (raw-value report)))))]) (let ([reply (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 273 (list (cons 'resultMsg *resultMsg) (cons 'resumeAgent *resumeAgent) (cons 'report *report) (cons 'job *job)) (lambda () (resumeConversation resumeAgent (raw-value job.conversationId) resultMsg)))]) (let ([_ (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 277 (list (cons 'reply *reply) (cons 'resultMsg *resultMsg) (cons 'resumeAgent *resumeAgent) (cons 'report *report) (cons 'job *job)) (lambda () (publishChunk (raw-value job.conversationId) (raw-value (tesl_import_String_concat "report: " (raw-value report))))))]) (let ([_ (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 278 (list (cons '_ *_) (cons 'reply *reply) (cons 'resultMsg *resultMsg) (cons 'resumeAgent *resumeAgent) (cons 'report *report) (cons 'job *job)) (lambda () (publishChunk (raw-value job.conversationId) (raw-value (tesl_import_String_concat "text: " (raw-value reply))))))]) (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 279 (list (cons '_ *_) (cons '_ *_) (cons 'reply *reply) (cons 'resultMsg *resultMsg) (cons 'resumeAgent *resumeAgent) (cons 'report *report) (cons 'job *job)) (lambda () *job)))))))))

(define-record MessageRequest
  [conversationId : String]
  [message : String]
)

(define (tesl-codec-encode-MessageRequest _v)
  (error "toJson is forbidden for type MessageRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-MessageRequest-0 _j)
  (define _f_conversationId (tesl-decode-prim-field _j "conversationId" tesl-decode-prim-string))
  (define _f_message (tesl-decode-prim-field _j "message" tesl-decode-prim-string))
  (record-value 'MessageRequest (hash 'conversationId _f_conversationId 'message _f_message)))
(register-type-codec! 'MessageRequest tesl-codec-encode-MessageRequest (list tesl-codec-decode-MessageRequest-0))

(define/pow
  (turnAgent [conversationId : String])
  #:capabilities [reportEnqueue]
  #:returns Agent
  (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 302 (list (cons 'conversationId *conversationId)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list (raw-value (toolUseStep "requestReport" "call_1" "{\"kind\":\"q3-sales\"}")) (raw-value (textStep "I've queued your q3-sales report and will post it here when it's ready."))))) (raw-value "You manage the user's reports. Use requestReport for anything slow.") (raw-value 256)) (list (reportTool conversationId))))))

(define-handler
  (sendMessage [req : MessageRequest])
  #:capabilities [reportTurn]
  #:returns String
  (thsl-src! "example/learn/lesson70-agent-async-work.tesl" 314 (list (cons 'req *req)) (lambda () (runTurn (turnAgent (raw-value req.conversationId)) (raw-value req.conversationId) (raw-value req.message)))))

(define ReportServer-sse-routes
  (list (list (list "chat" #f "events") #f ChatStream 1 (list (cons 1 (sse-key-capture __inline_capturer_conversationId_1))))))
(define-api ReportApi
  [sendMessage :
    "chat"
    :> (ReqBody JSON [req : MessageRequest])
    :> (Post JSON String)
    ]
)

(define-server ReportServer
  #:api ReportApi
  [sendMessage sendMessage]
)

(module+ test
  (require rackunit)
  (test-case "the agent's tool enqueues slow work and the turn returns at once"
    (call-with-fresh-memory-db (list ReportDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (reportTurn)
              (define posted (dispatch-api-test-request ReportServer 'post (list "chat") #:headers (hash) #:body (hash (string->symbol "conversationId") "conv-1" (string->symbol "message") "generate my q3 sales report") #:capabilities (list reportTurn)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref posted 'status)))))
              (check-equal? (raw-value (pendingJobCount ReportQueue)) 1)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "the worker resumes the awaiting conversation when the job completes"
    (call-with-fresh-memory-db (list ReportDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (reportTurn reportWorker)
              (define stream (subscribe ReportServer-sse-routes (list "chat" "conv-1" "events") #:headers (hash) #:name "/chat/conv-1/events"))
              (define posted (dispatch-api-test-request ReportServer 'post (list "chat") #:headers (hash) #:body (hash (string->symbol "conversationId") "conv-1" (string->symbol "message") "generate my q3 sales report") #:capabilities (list reportTurn reportWorker)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref posted 'status)))))
              (check-equal? (raw-value (pendingJobCount ReportQueue)) 1)
              (define done (processNextJob ReportQueue))
              (define job (expectJobOk (raw-value done)))
              (check-equal? (raw-value (api-test-field-access-ref job 'conversationId)) "conv-1")
              (check-equal? (raw-value (pendingJobCount ReportQueue)) 0)
              (define events (collect (raw-value stream) #:count 2 #:timeout-ms 2000))
              (check-true (raw-value (hasLength 2 (raw-value events))))
              (check-true (raw-value (includesWhere (hash 'tag "Chunk" 'fields (hash 'content "report: Report [q3-sales]: 3 items, all healthy.")) (raw-value events))))
              (check-true (raw-value (includesWhere (hash 'tag "Chunk" 'fields (hash 'content "text: Your report is ready \u2014 I've posted it above.")) (raw-value events))))
            )
          ))
      ))
  )
)

(define ReportQueueWorkers
  (list (cons ReportQueue generateReport)))
(register-api-test-workers! (list (list ReportQueue 'ReportJob generateReport)))
