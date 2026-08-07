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
  (only-in tesl/tesl/prelude String Bool)
  (only-in tesl/tesl/env envInt envRead requireEnv)
  (only-in tesl/tesl/telemetry initTelemetry)
  (only-in tesl/tesl/agent aiProvider askReply replyText)
)


(provide AiServer askClaude AskRequest askClaude-signature)

(define-capability liveAi (implies aiProvider))

(define Assistant
  (with-env-bootstrap (__tart_withTools (__tart_defineAgent (raw-value (anthropic (raw-value (requireEnv "ANTHROPIC_API_KEY")) "claude-opus-4-8")) (raw-value "You are a helpful assistant. Answer in one short sentence.") (raw-value 256)) (list))))

(define-record AskRequest
  [prompt : String]
)

(define (tesl-codec-encode-AskRequest _v)
  (error "toJson is forbidden for type AskRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-AskRequest-0 _j)
  (define _f_prompt (tesl-decode-prim-field _j "prompt" tesl-decode-prim-string))
  (record-value 'AskRequest (tesl-hash 'prompt _f_prompt)))
(register-type-codec! 'AskRequest tesl-codec-encode-AskRequest (list tesl-codec-decode-AskRequest-0))

(define-handler
  (askClaude [req : AskRequest])
  #:capabilities [liveAi]
  #:returns String
  (thsl-src! "example/ai-live-check.tesl" 57 (list (cons 'req *req)) (lambda () (raw-value (replyText (raw-value (askReply Assistant (tesl-dot/runtime req 'prompt 'AskRequest))))))))

(define AiServer-sse-routes '())
(define-api AiApi
  [askClaude :
    "ask"
    :> (ReqBody JSON [req : AskRequest])
    :> (Post JSON String)
    ]
)

(define-server AiServer
  #:api AiApi
  [askClaude askClaude]
)

(define-database LiveDb
  #:backend memory
  #:schema ai_live
  #:entities )

(module+ main
  (thsl-src! "example/ai-live-check.tesl" 77 (list) (lambda () (with-capabilities (liveAi envRead) (call-with-database LiveDb (lambda () (let ([_ (init-opentelemetry! #:service-name "ai-live-check" #:endpoint "in-memory" #:console? #t)]) (let ([port (raw-value (envInt "PORT" 8088))]) (serve AiServer #:port port #:capabilities (list liveAi envRead) #:sse-routes AiServer-sse-routes)))))))))