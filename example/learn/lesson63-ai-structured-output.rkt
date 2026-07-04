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
  (only-in tesl/tesl/prelude Int String)
  (only-in tesl/tesl/agent aiProvider LlmProvider mockProvider Agent anthropic askWith askFor decodeAs replyText)
  (only-in tesl/tesl/env requireEnv)
)


(provide Assistant classifyPriority Priority classifyPriority-signature)

(define-capability assistantAi (implies aiProvider))

(define-record Priority
  [level : Integer]
  [reason : String]
)

(define (tesl-codec-encode-Priority _v)
  (error "toJson is forbidden for type Priority: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-Priority-0 _j)
  (define _f_level (tesl-decode-prim-field _j "level" tesl-decode-prim-int))
  (define _f_reason (tesl-decode-prim-field _j "reason" tesl-decode-prim-string))
  (record-value 'Priority (hash 'level _f_level 'reason _f_reason)))
(register-type-codec! 'Priority tesl-codec-encode-Priority (list tesl-codec-decode-Priority-0))

(define/pow
  (decodePriority [j : String])
  #:returns Priority
  (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 57 (list (cons 'j *j)) (lambda () (raw-value (decodeAs "Priority" *j)))))

(define/pow
  (classifyPriority [provider : LlmProvider] [ticket : String])
  #:capabilities [assistantAi]
  #:returns Priority
  (let ([agent (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 63 (list (cons 'provider *provider) (cons 'ticket *ticket)) (lambda () (__tart_withTools (__tart_defineAgent *provider (raw-value "Classify the ticket's priority as JSON.") (raw-value 256)) (list))))]) (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 69 (list (cons 'agent *agent) (cons 'provider *provider) (cons 'ticket *ticket)) (lambda () (raw-value (askFor (raw-value agent) *ticket decodePriority 2))))))

(define Assistant
  (with-env-bootstrap (__tart_withTools (__tart_defineAgent (raw-value (anthropic (raw-value (requireEnv "ANTHROPIC_API_KEY")) "claude-opus-4-8")) (raw-value "You are a helpful assistant. Be concise.") (raw-value 256)) (list))))

(module+ test
  (require rackunit)
  (test-case "askFor decodes a typed Priority from the model's JSON"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (assistantAi)
    (define mock (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 92 (list) (lambda () (raw-value (mockProvider (list "{\"level\":1,\"reason\":\"production outage\"}"))))))
    (define p (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 93 (list (cons 'mock mock)) (lambda () (classifyPriority mock "the site is down"))))
    (check-equal? (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 94 (list (cons 'p p) (cons 'mock mock)) (lambda () (raw-value (tesl-dot/runtime p 'level)))) 1)
    (check-equal? (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 95 (list (cons 'p p) (cons 'mock mock)) (lambda () (raw-value (tesl-dot/runtime p 'reason)))) "production outage")
    )
    ))
  )

  (test-case "askFor retries past a malformed reply, then decodes"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (assistantAi)
    (define mock (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 101 (list) (lambda () (raw-value (mockProvider (list "not json" "{\"level\":3,\"reason\":\"cosmetic typo\"}"))))))
    (define p (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 102 (list (cons 'mock mock)) (lambda () (classifyPriority mock "there's a small typo on the about page"))))
    (check-equal? (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 103 (list (cons 'p p) (cons 'mock mock)) (lambda () (raw-value (tesl-dot/runtime p 'level)))) 3)
    (check-equal? (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 104 (list (cons 'p p) (cons 'mock mock)) (lambda () (raw-value (tesl-dot/runtime p 'reason)))) "cosmetic typo")
    )
    ))
  )

  (test-case "the same agent runs against different per-user providers (BYOK)"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (assistantAi)
    (define alice (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 110 (list) (lambda () (raw-value (mockProvider (list "Hello Alice!"))))))
    (define bob (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 111 (list (cons 'alice alice)) (lambda () (raw-value (mockProvider (list "Hello Bob!"))))))
    (define replyA (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 112 (list (cons 'bob bob) (cons 'alice alice)) (lambda () (raw-value (askWith Assistant "hi" (raw-value alice))))))
    (define replyB (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 113 (list (cons 'replyA replyA) (cons 'bob bob) (cons 'alice alice)) (lambda () (raw-value (askWith Assistant "hi" (raw-value bob))))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 114 (list (cons 'replyB replyB) (cons 'replyA replyA) (cons 'bob bob) (cons 'alice alice)) (lambda () (raw-value (replyText (raw-value replyA)))))) "Hello Alice!")
    (check-equal? (raw-value (thsl-src! "example/learn/lesson63-ai-structured-output.tesl" 115 (list (cons 'replyB replyB) (cons 'replyA replyA) (cons 'bob bob) (cons 'alice alice)) (lambda () (raw-value (replyText (raw-value replyB)))))) "Hello Bob!")
    )
    ))
  )

)
