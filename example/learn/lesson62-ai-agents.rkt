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
  (only-in tesl/tesl/string [String.concat tesl_import_String_concat])
  (only-in tesl/tesl/env requireEnv)
  (only-in tesl/tesl/agent aiProvider anthropic Agent mockToolProvider toolUseStep textStep askWith replyText replyToolCalls)
)


(provide WeatherAgent getWeather bookTable getWeather-signature bookTable-signature)

(define-capability myAi (implies aiProvider))

(define/pow
  (getWeather [city : String])
  #:returns String
  (thsl-src! "example/learn/lesson62-ai-agents.tesl" 61 (list (cons 'city *city)) (lambda () (raw-value (tesl_import_String_concat "It is sunny in " *city)))))

(define/pow
  (bookTable [restaurant : String] [guests : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson62-ai-agents.tesl" 65 (list (cons 'restaurant *restaurant) (cons 'guests *guests)) (lambda () (if (> *guests 0) (raw-value (raw-value (tesl_import_String_concat "Booked a table at " *restaurant))) (raw-value "Need at least one guest to book a table")))))

(define WeatherAgent
  (with-env-bootstrap (__tart_withTools (__tart_defineAgent (raw-value (anthropic (raw-value (requireEnv "ANTHROPIC_API_KEY")) "claude-opus-4-8")) (raw-value "You are a helpful concierge. Use the tools to answer.") (raw-value 512)) (list (__tart_tool "getWeather" "Look up the current weather for a city." "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}" (lambda (_args) (__tart_tesl-agent-decode-args _args (list (cons "city" 'string)))) (lambda (_decoded) (apply getWeather _decoded))) (__tart_tool "bookTable" "Book a table for a number of guests at a restaurant." "{\"type\":\"object\",\"properties\":{\"restaurant\":{\"type\":\"string\"},\"guests\":{\"type\":\"integer\"}},\"required\":[\"restaurant\",\"guests\"]}" (lambda (_args) (__tart_tesl-agent-decode-args _args (list (cons "restaurant" 'string) (cons "guests" 'int)))) (lambda (_decoded) (apply bookTable _decoded)))))))

(module+ test
  (require rackunit)
  (test-case "the model calls a typed tool; its String arg is decoded and dispatched"
    (with-capabilities (myAi)
    (define call (thsl-src! "example/learn/lesson62-ai-agents.tesl" 93 (list) (lambda () (raw-value (toolUseStep "getWeather" "c1" "{\"city\":\"Paris\"}")))))
    (define final (thsl-src! "example/learn/lesson62-ai-agents.tesl" 94 (list (cons 'call call)) (lambda () (raw-value (textStep "It is sunny in Paris right now.")))))
    (define mock (thsl-src! "example/learn/lesson62-ai-agents.tesl" 95 (list (cons 'final final) (cons 'call call)) (lambda () (raw-value (mockToolProvider (list call final))))))
    (define reply (thsl-src! "example/learn/lesson62-ai-agents.tesl" 96 (list (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (askWith WeatherAgent "What is the weather in Paris?" (raw-value mock))))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson62-ai-agents.tesl" 97 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (replyText (raw-value reply)))))) "It is sunny in Paris right now.")
    (check-equal? (raw-value (thsl-src! "example/learn/lesson62-ai-agents.tesl" 98 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
  )

  (test-case "a multi-parameter tool decodes each argument by type"
    (with-capabilities (myAi)
    (define call (thsl-src! "example/learn/lesson62-ai-agents.tesl" 104 (list) (lambda () (raw-value (toolUseStep "bookTable" "c1" "{\"restaurant\":\"Chez Tesl\",\"guests\":4}")))))
    (define final (thsl-src! "example/learn/lesson62-ai-agents.tesl" 105 (list (cons 'call call)) (lambda () (raw-value (textStep "All set!")))))
    (define mock (thsl-src! "example/learn/lesson62-ai-agents.tesl" 106 (list (cons 'final final) (cons 'call call)) (lambda () (raw-value (mockToolProvider (list call final))))))
    (define reply (thsl-src! "example/learn/lesson62-ai-agents.tesl" 107 (list (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (askWith WeatherAgent "Book Chez Tesl for 4" (raw-value mock))))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson62-ai-agents.tesl" 108 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (replyText (raw-value reply)))))) "All set!")
    (check-equal? (raw-value (thsl-src! "example/learn/lesson62-ai-agents.tesl" 109 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
  )

  (test-case "malformed tool arguments do not reach the function and do not crash the run"
    (with-capabilities (myAi)
    (define call (thsl-src! "example/learn/lesson62-ai-agents.tesl" 115 (list) (lambda () (raw-value (toolUseStep "getWeather" "c1" "{\"wrong\":\"field\"}")))))
    (define final (thsl-src! "example/learn/lesson62-ai-agents.tesl" 116 (list (cons 'call call)) (lambda () (raw-value (textStep "I could not look that up.")))))
    (define mock (thsl-src! "example/learn/lesson62-ai-agents.tesl" 117 (list (cons 'final final) (cons 'call call)) (lambda () (raw-value (mockToolProvider (list call final))))))
    (define reply (thsl-src! "example/learn/lesson62-ai-agents.tesl" 118 (list (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (askWith WeatherAgent "weather?" (raw-value mock))))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson62-ai-agents.tesl" 119 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (replyText (raw-value reply)))))) "I could not look that up.")
    (check-equal? (raw-value (thsl-src! "example/learn/lesson62-ai-agents.tesl" 120 (list (cons 'reply reply) (cons 'mock mock) (cons 'final final) (cons 'call call)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
  )

)
