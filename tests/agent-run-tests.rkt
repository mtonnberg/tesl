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
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/queue FromQueue queueRead queueWrite pubsub)
  (only-in tesl/tesl/string [String.concat tesl_import_String_concat])
  (only-in tesl/tesl/api-test statusOk hasLength includesWhere arrayAt fieldAt subscribe collect JobResult JobOk JobFailed processNextJob pendingJobCount expectJobOk)
  (only-in tesl/tesl/agent aiProvider mockToolProvider toolUseStep textStep Agent tool decodeAs agentRun)
)


(provide AgentRunServer)

(define-capture __inline_capturer_runId_1
  [runId : String]
  #:parser string-segment)

(define-capability runRead (implies dbRead))

(define-capability runWrite (implies dbWrite))

(define-capability runPubSub (implies pubsub))

(define-capability runQueue (implies queueWrite))

(define-capability runWorker (implies queueRead runPubSub aiProvider))

(define-capability runService (implies runRead runWrite runPubSub runQueue))

(define-record RunJob
  [prompt : String]
)

(define-record EchoArgs
  [text : String]
)

(define-adt RunEvent
  [Step [content : String]]
)

(define (tesl-codec-encode-RunJob _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'prompt (tesl-encode-prim-string (raw-value (hash-ref _fields 'prompt)))
  ))
(define (tesl-codec-decode-RunJob-0 _j)
  (define _f_prompt (tesl-decode-prim-field _j "prompt" tesl-decode-prim-string))
  (record-value 'RunJob (hash 'prompt _f_prompt)))
(register-type-codec! 'RunJob tesl-codec-encode-RunJob (list tesl-codec-decode-RunJob-0))

(define (tesl-codec-encode-EchoArgs _v)
  (error "toJson is forbidden for type EchoArgs: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-EchoArgs-0 _j)
  (define _f_text (tesl-decode-prim-field _j "text" tesl-decode-prim-string))
  (record-value 'EchoArgs (hash 'text _f_text)))
(register-type-codec! 'EchoArgs tesl-codec-encode-EchoArgs (list tesl-codec-decode-EchoArgs-0))

(define-entity RunLog
  #:source (make-hash)
  #:table run_log
  #:primary-key id
  [Id id : String]
)

(define-database RunDatabase
  #:backend postgres
  #:database "agent_run"
  #:user "tesl"
  #:password ""
  #:server "127.0.0.1"
  #:port 55432
  #:schema agent_run
  #:entities RunLog)

(define-queue RunQueue
  #:database RunDatabase
  #:job-types (RunJob)
  #:max-attempts 1
  #:backoff exponential
  #:initial-delay 0)

(define-channel RunSteps)

(define/pow
  (validateEcho [argsJson : String])
  #:returns EchoArgs
  (thsl-src! "tests/agent-run-tests.tesl" 139 (list (cons 'argsJson *argsJson)) (lambda () (raw-value (decodeAs "EchoArgs" *argsJson)))))

(define/pow
  (dispatchEcho [args : EchoArgs])
  #:returns String
  (thsl-src! "tests/agent-run-tests.tesl" 142 (list (cons 'args *args)) (lambda () (raw-value (tesl_import_String_concat "echo: " (tesl-dot/runtime args 'text))))))

(define/pow
  (publishStep [event : String])
  #:capabilities [runPubSub]
  #:returns Unit
  (thsl-src! "tests/agent-run-tests.tesl" 148 (list (cons 'event *event)) (lambda () (publish-event! RunSteps (format "~a" "run-1") (Step event)))))

(define-handler
  (startRun [req : RunJob])
  #:capabilities [runWrite runQueue]
  #:returns (Exists [logId : String] (? RunLog _entity ::: (FromDb (Id == logId) _entity)))
  (let ([logId (thsl-src! "tests/agent-run-tests.tesl" 154 (list (cons 'req *req)) (lambda () "run-1"))]) (thsl-src! "tests/agent-run-tests.tesl" 155 (list (cons 'logId *logId) (cons 'req *req)) (lambda () (call-with-queue-transaction (lambda () (begin (enqueue! RunQueue (RunJob #:prompt (raw-value req.prompt))) (pack ([logId]) (insert-one! RunLog (hash 'id logId))))))))))

(define/pow
  (runWorkerHandler [job : RunJob ::: (FromQueue (Id == jobId) job)])
  #:capabilities [runWorker]
  #:returns RunJob
  (let ([echoTool (thsl-src! "tests/agent-run-tests.tesl" 165 (list (cons 'job *job)) (lambda () (raw-value (tool "echo" "Echo back some text" "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}" validateEcho dispatchEcho))))]) (let ([steps (thsl-src! "tests/agent-run-tests.tesl" 166 (list (cons 'echoTool *echoTool) (cons 'job *job)) (lambda () (list (raw-value (toolUseStep "echo" "call_1" "{\"text\":\"hi\"}")) (raw-value (textStep "All done.")))))]) (let ([agent (thsl-src! "tests/agent-run-tests.tesl" 167 (list (cons 'steps *steps) (cons 'echoTool *echoTool) (cons 'job *job)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (raw-value steps))) (raw-value "You are a runner.") (raw-value 256)) (list *echoTool))))]) (let ([reply (thsl-src! "tests/agent-run-tests.tesl" 168 (list (cons 'agent *agent) (cons 'steps *steps) (cons 'echoTool *echoTool) (cons 'job *job)) (lambda () (raw-value (agentRun (raw-value agent) (raw-value job.prompt) publishStep))))]) (thsl-src! "tests/agent-run-tests.tesl" 169 (list (cons 'reply *reply) (cons 'agent *agent) (cons 'steps *steps) (cons 'echoTool *echoTool) (cons 'job *job)) (lambda () *job)))))))

(define AgentRunServer-sse-routes
  (list (list (list "events" "runs" #f) #f RunSteps 2 (list (cons 2 (sse-key-capture __inline_capturer_runId_1))))))
(define-api AgentRunApi
  [startRun :
    "runs"
    :> (ReqBody JSON [req : RunJob])
    :> (Post JSON (Exists [logId : String] (? RunLog _entity ::: (FromDb (Id == logId) _entity))))
    ]
)

(define-server AgentRunServer
  #:api AgentRunApi
  [startRun startRun]
)

(module+ test
  (require rackunit)
  (test-case "agentRun on a worker publishes step events a subscriber collects"
    (call-with-fresh-memory-db (list RunDatabase)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (runRead runWrite runPubSub runQueue runWorker)
              (define stream (subscribe AgentRunServer-sse-routes (list "events" "runs" "run-1") #:headers (hash) #:name "/events/runs/run-1"))
              (define posted (dispatch-api-test-request AgentRunServer 'post (list "runs") #:headers (hash) #:body (hash (string->symbol "prompt") "please echo") #:capabilities (list runRead runWrite runPubSub runQueue runWorker)))
              (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref posted 'status)))))
              (check-equal? (raw-value (pendingJobCount RunQueue)) 1)
              (define done (processNextJob RunQueue))
              (define job (expectJobOk (raw-value done)))
              (check-equal? (raw-value (api-test-field-access-ref job 'prompt)) "please echo")
              (check-equal? (raw-value (pendingJobCount RunQueue)) 0)
              (define events (collect (raw-value stream) #:count 2 #:timeout-ms 2000))
              (check-true (raw-value (hasLength 2 (raw-value events))))
              (define first (arrayAt 0 (raw-value events)))
              (define second (arrayAt 1 (raw-value events)))
              (check-equal? (raw-value (fieldAt "tag" (raw-value first))) "Step")
              (check-equal? (raw-value (fieldAt "tag" (raw-value second))) "Step")
              (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref first 'fields) 'content)) "tool: echo")
              (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref second 'fields) 'content)) "text: All done.")
              (check-true (raw-value (includesWhere (hash 'tag "Step" 'fields (hash 'content "tool: echo")) (raw-value events))))
              (check-true (raw-value (includesWhere (hash 'tag "Step" 'fields (hash 'content "text: All done.")) (raw-value events))))
            )
          ))
      ))
  )
)

(define RunQueueWorkers
  (list (cons RunQueue runWorkerHandler)))
(register-api-test-workers! (list (list RunQueue 'RunJob runWorkerHandler)))
