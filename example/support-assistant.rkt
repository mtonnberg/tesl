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
  (only-in tesl/tesl/prelude Int String Bool)
  (only-in tesl/tesl/string [String.concat tesl_import_String_concat])
  (only-in tesl/tesl/env requireEnv)
  (only-in tesl/tesl/agent aiProvider LlmProvider Agent anthropic mockProvider mockToolProvider toolUseStep textStep ask askWith askFor decodeAs replyText replyToolCalls)
)


(provide SupportAgent classifyTicket Triage classifyTicket-signature)

(define-capability supportBot (implies aiProvider))

(define/pow
  (lookupOrder [orderId : String])
  #:returns String
  (thsl-src! "example/support-assistant.tesl" 54 (list (cons 'orderId *orderId)) (lambda () (raw-value (tesl_import_String_concat (raw-value (tesl_import_String_concat "order " *orderId)) " is: shipped")))))

(define/pow
  (refundOrder [orderId : String] [confirmed : Boolean])
  #:returns String
  (thsl-src! "example/support-assistant.tesl" 60 (list (cons 'orderId *orderId) (cons 'confirmed *confirmed)) (lambda () (if *confirmed (raw-value (raw-value (tesl_import_String_concat "refund issued for order " *orderId))) (raw-value "refund refused: not confirmed")))))

(define SupportAgent
  (with-env-bootstrap (__tart_withTools (__tart_defineAgent (raw-value (anthropic (raw-value (requireEnv "ANTHROPIC_API_KEY")) "claude-opus-4-8")) (raw-value "You are a concise customer-support assistant. Never invent order ids.") (raw-value 512)) (list (__tart_tool "lookupOrder" "Look up the shipping status of an order by its id." "{\"type\":\"object\",\"properties\":{\"orderId\":{\"type\":\"string\"}},\"required\":[\"orderId\"]}" (lambda (_args) (__tart_tesl-agent-decode-args _args (list (cons "orderId" 'string)))) (lambda (_decoded) (apply lookupOrder _decoded))) (__tart_tool "refundOrder" "Issue a refund for an order. The model must pass confirmed: true; the guard lives inside the typed value, so \"did the mutation actually happen?\" is answerable by asserting on the tool result, deterministically." "{\"type\":\"object\",\"properties\":{\"orderId\":{\"type\":\"string\"},\"confirmed\":{\"type\":\"boolean\"}},\"required\":[\"orderId\",\"confirmed\"]}" (lambda (_args) (__tart_tesl-agent-decode-args _args (list (cons "orderId" 'string) (cons "confirmed" 'bool)))) (lambda (_decoded) (apply refundOrder _decoded)))))))

(define-record Triage
  [category : String]
  [priority : Integer]
)

(define (tesl-codec-encode-Triage _v)
  (error "toJson is forbidden for type Triage: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-Triage-0 _j)
  (define _f_category (tesl-decode-prim-field _j "category" tesl-decode-prim-string))
  (define _f_priority (tesl-decode-prim-field _j "priority" tesl-decode-prim-int))
  (record-value 'Triage (hash 'category _f_category 'priority _f_priority)))
(register-type-codec! 'Triage tesl-codec-encode-Triage (list tesl-codec-decode-Triage-0))

(define/pow
  (decodeTriage [j : String])
  #:returns Triage
  (thsl-src! "example/support-assistant.tesl" 100 (list (cons 'j *j)) (lambda () (raw-value (decodeAs "Triage" *j)))))

(define/pow
  (classifyTicket [provider : LlmProvider] [ticket : String])
  #:capabilities [supportBot]
  #:returns Triage
  (let ([agent (thsl-src! "example/support-assistant.tesl" 103 (list (cons 'provider *provider) (cons 'ticket *ticket)) (lambda () (__tart_withTools (__tart_defineAgent *provider (raw-value "Classify the support ticket as JSON.") (raw-value 256)) (list))))]) (thsl-src! "example/support-assistant.tesl" 104 (list (cons 'agent *agent) (cons 'provider *provider) (cons 'ticket *ticket)) (lambda () (raw-value (askFor (raw-value agent) *ticket decodeTriage 2))))))

(module+ test
  (require rackunit)
  (test-case "lookup tool: derived-schema args reach the typed fn and the loop returns a reply"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (supportBot)
    (define call (thsl-src! "example/support-assistant.tesl" 117 (list) (lambda () (raw-value (toolUseStep "lookupOrder" "call_1" "{\"orderId\":\"A-100\"}")))))
    (define final (thsl-src! "example/support-assistant.tesl" 118 (list (cons 'call call)) (lambda () (raw-value (textStep "Your order A-100 has shipped.")))))
    (define mock (thsl-src! "example/support-assistant.tesl" 119 (list (cons 'final final) (cons 'call call)) (lambda () (raw-value (mockToolProvider (list call final))))))
    (define reply (thsl-src! "example/support-assistant.tesl" 120 (list (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (askWith SupportAgent "Where is my order A-100?" (raw-value mock))))))
    (check-equal? (raw-value (thsl-src! "example/support-assistant.tesl" 121 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (replyText (raw-value reply)))))) "Your order A-100 has shipped.")
    (check-equal? (raw-value (thsl-src! "example/support-assistant.tesl" 122 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
    ))
  )

  (test-case "refund tool: confirmed=true issues the refund"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (supportBot)
    (define call (thsl-src! "example/support-assistant.tesl" 128 (list) (lambda () (raw-value (toolUseStep "refundOrder" "call_1" "{\"orderId\":\"A-200\",\"confirmed\":true}")))))
    (define final (thsl-src! "example/support-assistant.tesl" 129 (list (cons 'call call)) (lambda () (raw-value (textStep "Done \u2014 your refund is on its way.")))))
    (define mock (thsl-src! "example/support-assistant.tesl" 130 (list (cons 'final final) (cons 'call call)) (lambda () (raw-value (mockToolProvider (list call final))))))
    (define reply (thsl-src! "example/support-assistant.tesl" 131 (list (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (askWith SupportAgent "Please refund order A-200, I confirm." (raw-value mock))))))
    (check-equal? (raw-value (thsl-src! "example/support-assistant.tesl" 132 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (replyText (raw-value reply)))))) "Done \u2014 your refund is on its way.")
    (check-equal? (raw-value (thsl-src! "example/support-assistant.tesl" 133 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
    ))
  )

  (test-case "refund tool: confirmed=false refuses the mutation but the loop continues"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (supportBot)
    (define call (thsl-src! "example/support-assistant.tesl" 140 (list) (lambda () (raw-value (toolUseStep "refundOrder" "call_1" "{\"orderId\":\"A-300\",\"confirmed\":false}")))))
    (define final (thsl-src! "example/support-assistant.tesl" 141 (list (cons 'call call)) (lambda () (raw-value (textStep "I can't refund without confirmation.")))))
    (define mock (thsl-src! "example/support-assistant.tesl" 142 (list (cons 'final final) (cons 'call call)) (lambda () (raw-value (mockToolProvider (list call final))))))
    (define reply (thsl-src! "example/support-assistant.tesl" 143 (list (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (askWith SupportAgent "Maybe refund A-300?" (raw-value mock))))))
    (check-equal? (raw-value (thsl-src! "example/support-assistant.tesl" 144 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (replyText (raw-value reply)))))) "I can't refund without confirmation.")
    (check-equal? (raw-value (thsl-src! "example/support-assistant.tesl" 145 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
    ))
  )

  (test-case "multi-step: lookup then refund is exactly two tool round-trips"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (supportBot)
    (define lookup (thsl-src! "example/support-assistant.tesl" 151 (list) (lambda () (raw-value (toolUseStep "lookupOrder" "call_1" "{\"orderId\":\"A-400\"}")))))
    (define refund (thsl-src! "example/support-assistant.tesl" 152 (list (cons 'lookup lookup)) (lambda () (raw-value (toolUseStep "refundOrder" "call_2" "{\"orderId\":\"A-400\",\"confirmed\":true}")))))
    (define final (thsl-src! "example/support-assistant.tesl" 153 (list (cons 'refund refund) (cons 'lookup lookup)) (lambda () (raw-value (textStep "Looked it up and refunded order A-400.")))))
    (define mock (thsl-src! "example/support-assistant.tesl" 154 (list (cons 'final final) (cons 'refund refund) (cons 'lookup lookup)) (lambda () (raw-value (mockToolProvider (list lookup refund final))))))
    (define reply (thsl-src! "example/support-assistant.tesl" 155 (list (cons 'mock mock) (cons 'final final) (cons 'refund refund) (cons 'lookup lookup)) (lambda () (raw-value (askWith SupportAgent "Refund A-400 if it already shipped." (raw-value mock))))))
    (check-equal? (raw-value (thsl-src! "example/support-assistant.tesl" 156 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'refund refund) (cons 'lookup lookup)) (lambda () (raw-value (replyText (raw-value reply)))))) "Looked it up and refunded order A-400.")
    (check-equal? (raw-value (thsl-src! "example/support-assistant.tesl" 157 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'refund refund) (cons 'lookup lookup)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 2)
    )
    ))
  )

  (test-case "malformed tool args become an is_error tool_result, not an exception"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (supportBot)
    (define call (thsl-src! "example/support-assistant.tesl" 165 (list) (lambda () (raw-value (toolUseStep "lookupOrder" "call_1" "{\"wrong\":\"shape\"}")))))
    (define final (thsl-src! "example/support-assistant.tesl" 166 (list (cons 'call call)) (lambda () (raw-value (textStep "Sorry, I couldn't find that order.")))))
    (define mock (thsl-src! "example/support-assistant.tesl" 167 (list (cons 'final final) (cons 'call call)) (lambda () (raw-value (mockToolProvider (list call final))))))
    (define reply (thsl-src! "example/support-assistant.tesl" 168 (list (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (askWith SupportAgent "status?" (raw-value mock))))))
    (check-equal? (raw-value (thsl-src! "example/support-assistant.tesl" 169 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (replyText (raw-value reply)))))) "Sorry, I couldn't find that order.")
    (check-equal? (raw-value (thsl-src! "example/support-assistant.tesl" 170 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
    ))
  )

  (test-case "structured output: classifyTicket decodes a typed Triage on the first reply"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (supportBot)
    (define mock (thsl-src! "example/support-assistant.tesl" 176 (list) (lambda () (raw-value (mockProvider (list "{\"category\":\"billing\",\"priority\":2}"))))))
    (define triage (thsl-src! "example/support-assistant.tesl" 177 (list (cons 'mock mock)) (lambda () (classifyTicket mock "I was double-charged"))))
    (check-equal? (thsl-src! "example/support-assistant.tesl" 178 (list (cons 'triage triage) (cons 'mock mock)) (lambda () (raw-value (tesl-dot/runtime triage 'category 'Triage)))) "billing")
    (check-equal? (thsl-src! "example/support-assistant.tesl" 179 (list (cons 'triage triage) (cons 'mock mock)) (lambda () (raw-value (tesl-dot/runtime triage 'priority 'Triage)))) 2)
    )
    ))
  )

  (test-case "structured output: classifyTicket retries past a bad reply then decodes"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (supportBot)
    (define mock (thsl-src! "example/support-assistant.tesl" 185 (list) (lambda () (raw-value (mockProvider (list "not json at all" "{\"category\":\"shipping\",\"priority\":1}"))))))
    (define triage (thsl-src! "example/support-assistant.tesl" 186 (list (cons 'mock mock)) (lambda () (classifyTicket mock "Where is my package?"))))
    (check-equal? (thsl-src! "example/support-assistant.tesl" 187 (list (cons 'triage triage) (cons 'mock mock)) (lambda () (raw-value (tesl-dot/runtime triage 'category 'Triage)))) "shipping")
    (check-equal? (thsl-src! "example/support-assistant.tesl" 188 (list (cons 'triage triage) (cons 'mock mock)) (lambda () (raw-value (tesl-dot/runtime triage 'priority 'Triage)))) 1)
    )
    ))
  )

  (test-case "plain ask returns the scripted reply"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (supportBot)
    (define agent (thsl-src! "example/support-assistant.tesl" 193 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "Hi! How can I help?"))) (raw-value "x") (raw-value 64)) (list)))))
    (check-equal? (raw-value (thsl-src! "example/support-assistant.tesl" 194 (list (cons 'agent agent)) (lambda () (raw-value (ask (raw-value agent) "hello"))))) "Hi! How can I help?")
    )
    ))
  )

)
