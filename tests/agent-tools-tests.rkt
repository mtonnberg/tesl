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
  (only-in tesl/tesl/prelude Int String Bool List Unit)
  (only-in tesl/tesl/string [String.concat tesl_import_String_concat])
  (only-in tesl/tesl/agent aiProvider Agent LlmProvider AgentReply Tool ToolStep mockProvider mockToolProvider toolUseStep textStep tool ask askReply askWith replyText replyTokens replyToolCalls decodeAs askFor)
)


(provide )

(define-capability supportBot (implies aiProvider))

(define-record WeatherArgs
  [city : String]
)

(define (tesl-codec-encode-WeatherArgs _v)
  (error "toJson is forbidden for type WeatherArgs: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-WeatherArgs-0 _j)
  (define _f_city (tesl-decode-prim-field _j "city" tesl-decode-prim-string))
  (record-value 'WeatherArgs (hash 'city _f_city)))
(register-type-codec! 'WeatherArgs tesl-codec-encode-WeatherArgs (list tesl-codec-decode-WeatherArgs-0))

(define-record Summary
  [title : String]
  [score : Integer]
)

(define (tesl-codec-encode-Summary _v)
  (error "toJson is forbidden for type Summary: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-Summary-0 _j)
  (define _f_title (tesl-decode-prim-field _j "title" tesl-decode-prim-string))
  (define _f_score (tesl-decode-prim-field _j "score" tesl-decode-prim-int))
  (record-value 'Summary (hash 'title _f_title 'score _f_score)))
(register-type-codec! 'Summary tesl-codec-encode-Summary (list tesl-codec-decode-Summary-0))

(define/pow
  (validateWeather [argsJson : String])
  #:returns WeatherArgs
  (thsl-src! "tests/agent-tools-tests.tesl" 78 (list (cons 'argsJson *argsJson)) (lambda () (raw-value (decodeAs "WeatherArgs" *argsJson)))))

(define/pow
  (dispatchWeather [args : WeatherArgs])
  #:returns String
  (thsl-src! "tests/agent-tools-tests.tesl" 83 (list (cons 'args *args)) (lambda () (raw-value (tesl_import_String_concat "weather in " (tesl-dot/runtime args 'city))))))

(define/pow
  (decodeSummary [j : String])
  #:returns Summary
  (thsl-src! "tests/agent-tools-tests.tesl" 87 (list (cons 'j *j)) (lambda () (raw-value (decodeAs "Summary" *j)))))

(define/pow
  (lookupWeather [city : String])
  #:returns String
  (thsl-src! "tests/agent-tools-tests.tesl" 93 (list (cons 'city *city)) (lambda () (raw-value (tesl_import_String_concat "weather in " *city)))))

(module+ test
  (require rackunit)
  (test-case "tool-calling loop dispatches the tool with validated args and returns final reply"
    (with-capabilities (supportBot)
    (define weatherTool (thsl-src! "tests/agent-tools-tests.tesl" 102 (list) (lambda () (raw-value (tool "get_weather" "Look up the weather for a city" "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}" validateWeather dispatchWeather)))))
    (define step1 (thsl-src! "tests/agent-tools-tests.tesl" 108 (list (cons 'weatherTool weatherTool)) (lambda () (raw-value (toolUseStep "get_weather" "call_1" "{\"city\":\"Malmo\"}")))))
    (define step2 (thsl-src! "tests/agent-tools-tests.tesl" 109 (list (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (textStep "It is sunny.")))))
    (define agent (thsl-src! "tests/agent-tools-tests.tesl" 110 (list (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list step1 step2))) (raw-value "You are a weather bot.") (raw-value 256)) (list weatherTool)))))
    (define reply (thsl-src! "tests/agent-tools-tests.tesl" 111 (list (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (askReply (raw-value agent) "What is the weather in Malmo?")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-tools-tests.tesl" 112 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyText (raw-value reply)))))) "It is sunny.")
    (check-equal? (raw-value (thsl-src! "tests/agent-tools-tests.tesl" 113 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
  )

  (test-case "asTool wraps a typed fn: schema derived, args decoded + dispatched"
    (with-capabilities (supportBot)
    (define step1 (thsl-src! "tests/agent-tools-tests.tesl" 121 (list) (lambda () (raw-value (toolUseStep "lookupWeather" "call_1" "{\"city\":\"Malmo\"}")))))
    (define step2 (thsl-src! "tests/agent-tools-tests.tesl" 122 (list (cons 'step1 step1)) (lambda () (raw-value (textStep "It is sunny.")))))
    (define agent (thsl-src! "tests/agent-tools-tests.tesl" 123 (list (cons 'step2 step2) (cons 'step1 step1)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list step1 step2))) (raw-value "You are a weather bot.") (raw-value 256)) (list (__tart_tool "lookupWeather" "A plain typed tool function for `asTool`: no hand-written schema/validator \226\128\148 the JSON schema is derived from the parameter type and the model's args are decoded into `city` under the hood." "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}" (lambda (_args) (__tart_tesl-agent-decode-args _args (list (cons "city" 'string)))) (lambda (_decoded) (apply lookupWeather _decoded))))))))
    (define reply (thsl-src! "tests/agent-tools-tests.tesl" 124 (list (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1)) (lambda () (raw-value (askReply (raw-value agent) "What is the weather in Malmo?")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-tools-tests.tesl" 125 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1)) (lambda () (raw-value (replyText (raw-value reply)))))) "It is sunny.")
    (check-equal? (raw-value (thsl-src! "tests/agent-tools-tests.tesl" 126 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
  )

  (test-case "malformed tool args are rejected as is_error and the loop continues"
    (with-capabilities (supportBot)
    (define weatherTool (thsl-src! "tests/agent-tools-tests.tesl" 137 (list) (lambda () (raw-value (tool "get_weather" "Look up the weather for a city" "{}" validateWeather dispatchWeather)))))
    (define step1 (thsl-src! "tests/agent-tools-tests.tesl" 145 (list (cons 'weatherTool weatherTool)) (lambda () (raw-value (toolUseStep "get_weather" "call_1" "{\"wrong\":\"field\"}")))))
    (define step2 (thsl-src! "tests/agent-tools-tests.tesl" 146 (list (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (textStep "Sorry, I could not look that up.")))))
    (define agent (thsl-src! "tests/agent-tools-tests.tesl" 147 (list (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list step1 step2))) (raw-value "You are a weather bot.") (raw-value 256)) (list weatherTool)))))
    (define reply (thsl-src! "tests/agent-tools-tests.tesl" 148 (list (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (askReply (raw-value agent) "weather?")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-tools-tests.tesl" 149 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyText (raw-value reply)))))) "Sorry, I could not look that up.")
    (check-equal? (raw-value (thsl-src! "tests/agent-tools-tests.tesl" 150 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
  )

  (test-case "askFor decodes a typed structured-output value on first reply"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-tools-tests.tesl" 158 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "{\"title\":\"All good\",\"score\":42}"))) (raw-value "Reply with JSON.") (raw-value 128)) (list)))))
    (define summary (thsl-src! "tests/agent-tools-tests.tesl" 159 (list (cons 'agent agent)) (lambda () (raw-value (askFor (raw-value agent) "summarize" decodeSummary 2)))))
    (check-equal? (thsl-src! "tests/agent-tools-tests.tesl" 160 (list (cons 'summary summary) (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime summary 'title)))) "All good")
    (check-equal? (thsl-src! "tests/agent-tools-tests.tesl" 161 (list (cons 'summary summary) (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime summary 'score)))) 42)
    )
  )

  (test-case "askFor retries after a decode failure then succeeds"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-tools-tests.tesl" 171 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "not json at all" "{\"title\":\"Recovered\",\"score\":7}"))) (raw-value "Reply with JSON.") (raw-value 128)) (list)))))
    (define summary (thsl-src! "tests/agent-tools-tests.tesl" 172 (list (cons 'agent agent)) (lambda () (raw-value (askFor (raw-value agent) "summarize" decodeSummary 2)))))
    (check-equal? (thsl-src! "tests/agent-tools-tests.tesl" 173 (list (cons 'summary summary) (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime summary 'title)))) "Recovered")
    (check-equal? (thsl-src! "tests/agent-tools-tests.tesl" 174 (list (cons 'summary summary) (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime summary 'score)))) 7)
    )
  )

  (test-case "askWith uses the BYOK provider override, not the agent default"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-tools-tests.tesl" 184 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "default reply"))) (raw-value "x") (raw-value 64)) (list)))))
    (define byok (thsl-src! "tests/agent-tools-tests.tesl" 185 (list (cons 'agent agent)) (lambda () (raw-value (mockProvider (list "override reply"))))))
    (define reply (thsl-src! "tests/agent-tools-tests.tesl" 186 (list (cons 'byok byok) (cons 'agent agent)) (lambda () (raw-value (askWith (raw-value agent) "hi" (raw-value byok))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-tools-tests.tesl" 187 (list (cons 'reply reply) (cons 'byok byok) (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value reply)))))) "override reply")
    )
  )

  (test-case "ask still returns plain text through the loop"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-tools-tests.tesl" 192 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "plain text"))) (raw-value "x") (raw-value 64)) (list)))))
    (check-equal? (raw-value (thsl-src! "tests/agent-tools-tests.tesl" 193 (list (cons 'agent agent)) (lambda () (raw-value (ask (raw-value agent) "hi"))))) "plain text")
    )
  )

)
