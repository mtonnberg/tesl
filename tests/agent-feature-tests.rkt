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
  (only-in tesl/tesl/string [String.concat tesl_import_String_concat] [String.contains tesl_import_String_contains])
  (only-in tesl/tesl/agent aiProvider Agent LlmProvider AgentReply Tool ToolStep Conversation ConversationTurn mockProvider mockToolProvider toolUseStep textStep tool ask askReply askWith askFor replyText replyTokens replyToolCalls decodeAs newConversation conversationFrom conversationJson conversationLength converse turnReply turnConversation)
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

(define-record AddArgs
  [a : Integer]
  [b : Integer]
)

(define (tesl-codec-encode-AddArgs _v)
  (error "toJson is forbidden for type AddArgs: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-AddArgs-0 _j)
  (define _f_a (tesl-decode-prim-field _j "a" tesl-decode-prim-int))
  (define _f_b (tesl-decode-prim-field _j "b" tesl-decode-prim-int))
  (record-value 'AddArgs (hash 'a _f_a 'b _f_b)))
(register-type-codec! 'AddArgs tesl-codec-encode-AddArgs (list tesl-codec-decode-AddArgs-0))

(define-record FlagArgs
  [on : Boolean]
)

(define (tesl-codec-encode-FlagArgs _v)
  (error "toJson is forbidden for type FlagArgs: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-FlagArgs-0 _j)
  (define _f_on (tesl-decode-prim-field _j "on" tesl-decode-prim-bool))
  (record-value 'FlagArgs (hash 'on _f_on)))
(register-type-codec! 'FlagArgs tesl-codec-encode-FlagArgs (list tesl-codec-decode-FlagArgs-0))

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

(define-record Sentiment
  [label : String]
)

(define (tesl-codec-encode-Sentiment _v)
  (error "toJson is forbidden for type Sentiment: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-Sentiment-0 _j)
  (define _f_label (tesl-decode-prim-field _j "label" tesl-decode-prim-string))
  (record-value 'Sentiment (hash 'label _f_label)))
(register-type-codec! 'Sentiment tesl-codec-encode-Sentiment (list tesl-codec-decode-Sentiment-0))

(define/pow
  (validateWeather [argsJson : String])
  #:returns WeatherArgs
  (thsl-src! "tests/agent-feature-tests.tesl" 133 (list (cons 'argsJson *argsJson)) (lambda () (raw-value (decodeAs "WeatherArgs" *argsJson)))))

(define/pow
  (validateAdd [argsJson : String])
  #:returns AddArgs
  (thsl-src! "tests/agent-feature-tests.tesl" 136 (list (cons 'argsJson *argsJson)) (lambda () (raw-value (decodeAs "AddArgs" *argsJson)))))

(define/pow
  (validateFlag [argsJson : String])
  #:returns FlagArgs
  (thsl-src! "tests/agent-feature-tests.tesl" 139 (list (cons 'argsJson *argsJson)) (lambda () (raw-value (decodeAs "FlagArgs" *argsJson)))))

(define/pow
  (dispatchWeather [args : WeatherArgs])
  #:returns String
  (thsl-src! "tests/agent-feature-tests.tesl" 144 (list (cons 'args *args)) (lambda () (raw-value (tesl_import_String_concat "weather in " (tesl-dot/runtime args 'city))))))

(define/pow
  (dispatchAdd [args : AddArgs])
  #:returns String
  (thsl-src! "tests/agent-feature-tests.tesl" 147 (list (cons 'args *args)) (lambda () (raw-value (tesl_import_String_concat "sum computed for " (raw-value (tesl_import_String_concat (raw-value (intToString (tesl-dot/runtime args 'a))) (raw-value (tesl_import_String_concat " + " (raw-value (intToString (tesl-dot/runtime args 'b))))))))))))

(define/pow
  (dispatchFlag [args : FlagArgs])
  #:returns String
  (thsl-src! "tests/agent-feature-tests.tesl" 150 (list (cons 'args *args)) (lambda () (if (tesl-dot/runtime args 'on) (raw-value "flag is on") (raw-value "flag is off")))))

(define/pow
  (intToString [n : Integer])
  #:returns String
  (thsl-src! "tests/agent-feature-tests.tesl" 157 (list (cons 'n *n)) (lambda () (if (equal? *n 0) (raw-value "0") (raw-value "n")))))

(define/pow
  (decodeSummary [j : String])
  #:returns Summary
  (thsl-src! "tests/agent-feature-tests.tesl" 165 (list (cons 'j *j)) (lambda () (raw-value (decodeAs "Summary" *j)))))

(define/pow
  (decodeSentiment [j : String])
  #:returns Sentiment
  (thsl-src! "tests/agent-feature-tests.tesl" 168 (list (cons 'j *j)) (lambda () (raw-value (decodeAs "Sentiment" *j)))))

(define/pow
  (askMock [prompt : String])
  #:capabilities [supportBot]
  #:returns String
  (let ([agent (thsl-src! "tests/agent-feature-tests.tesl" 173 (list (cons 'prompt *prompt)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "wrapped reply"))) (raw-value "You are a bot.") (raw-value 100)) (list))))]) (thsl-src! "tests/agent-feature-tests.tesl" 174 (list (cons 'agent *agent) (cons 'prompt *prompt)) (lambda () (raw-value (ask (raw-value agent) *prompt))))))

(define/pow
  (classify [text : String])
  #:capabilities [supportBot]
  #:returns Sentiment
  (let ([agent (thsl-src! "tests/agent-feature-tests.tesl" 177 (list (cons 'text *text)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "{\"label\":\"positive\"}"))) (raw-value "Classify.") (raw-value 64)) (list))))]) (thsl-src! "tests/agent-feature-tests.tesl" 178 (list (cons 'agent *agent) (cons 'text *text)) (lambda () (raw-value (askFor (raw-value agent) *text decodeSentiment 2))))))

(module+ test
  (require rackunit)
  (test-case "ask returns the mock's first scripted reply"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 185 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "hello"))) (raw-value "x") (raw-value 100)) (list)))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 186 (list (cons 'agent agent)) (lambda () (raw-value (ask (raw-value agent) "hi"))))) "hello")
    )
  )

  (test-case "ask returns the exact scripted string verbatim"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 190 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "The answer is 42."))) (raw-value "x") (raw-value 100)) (list)))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 191 (list (cons 'agent agent)) (lambda () (raw-value (ask (raw-value agent) "q"))))) "The answer is 42.")
    )
  )

  (test-case "ask through a wrapper handler returns the scripted reply"
    (with-capabilities (supportBot)
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 195 (list) (lambda () (askMock "anything")))) "wrapped reply")
    )
  )

  (test-case "successive asks walk the mock script by call index"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 199 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "first" "second" "third"))) (raw-value "x") (raw-value 50)) (list)))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 200 (list (cons 'agent agent)) (lambda () (raw-value (ask (raw-value agent) "a"))))) "first")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 201 (list (cons 'agent agent)) (lambda () (raw-value (ask (raw-value agent) "b"))))) "second")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 202 (list (cons 'agent agent)) (lambda () (raw-value (ask (raw-value agent) "c"))))) "third")
    )
  )

  (test-case "ask ignores the prompt content \226\128\148 mock is prompt-independent"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 206 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "fixed"))) (raw-value "x") (raw-value 50)) (list)))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 207 (list (cons 'agent agent)) (lambda () (raw-value (ask (raw-value agent) "totally different prompt"))))) "fixed")
    )
  )

  (test-case "ask works with an empty system prompt"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 211 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "ok"))) (raw-value "") (raw-value 32)) (list)))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 212 (list (cons 'agent agent)) (lambda () (raw-value (ask (raw-value agent) "hi"))))) "ok")
    )
  )

  (test-case "ask returns an empty scripted reply unchanged"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 216 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list ""))) (raw-value "x") (raw-value 32)) (list)))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 217 (list (cons 'agent agent)) (lambda () (raw-value (ask (raw-value agent) "hi"))))) "")
    )
  )

  (test-case "ask preserves unicode in the scripted reply"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 221 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "caf\u00e9 \u2014 na\u00efve \u2713"))) (raw-value "x") (raw-value 64)) (list)))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 222 (list (cons 'agent agent)) (lambda () (raw-value (ask (raw-value agent) "hi"))))) "caf\u00e9 \u2014 na\u00efve \u2713")
    )
  )

  (test-case "two distinct agents keep independent mock scripts"
    (with-capabilities (supportBot)
    (define a1 (thsl-src! "tests/agent-feature-tests.tesl" 226 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "from a1"))) (raw-value "x") (raw-value 32)) (list)))))
    (define a2 (thsl-src! "tests/agent-feature-tests.tesl" 227 (list (cons 'a1 a1)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "from a2"))) (raw-value "x") (raw-value 32)) (list)))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 228 (list (cons 'a2 a2) (cons 'a1 a1)) (lambda () (raw-value (ask (raw-value a1) "hi"))))) "from a1")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 229 (list (cons 'a2 a2) (cons 'a1 a1)) (lambda () (raw-value (ask (raw-value a2) "hi"))))) "from a2")
    )
  )

  (test-case "askReply replyText matches the scripted text"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 237 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "reply body"))) (raw-value "x") (raw-value 64)) (list)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 238 (list (cons 'agent agent)) (lambda () (raw-value (askReply (raw-value agent) "hi")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 239 (list (cons 'reply reply) (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value reply)))))) "reply body")
    )
  )

  (test-case "askReply with no tools reports zero tool calls"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 243 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "plain"))) (raw-value "x") (raw-value 64)) (list)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 244 (list (cons 'agent agent)) (lambda () (raw-value (askReply (raw-value agent) "hi")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 245 (list (cons 'reply reply) (cons 'agent agent)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 0)
    )
  )

  (test-case "askReply replyTokens is non-negative"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 249 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "counts"))) (raw-value "x") (raw-value 64)) (list)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 250 (list (cons 'agent agent)) (lambda () (raw-value (askReply (raw-value agent) "hi")))))
    (check-true (thsl-src! "tests/agent-feature-tests.tesl" 251 (list (cons 'reply reply) (cons 'agent agent)) (lambda () (>= (raw-value (replyTokens (raw-value reply))) 0))))
    )
  )

  (test-case "askReply replyText equals ask result for the same script"
    (with-capabilities (supportBot)
    (define a1 (thsl-src! "tests/agent-feature-tests.tesl" 255 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "same"))) (raw-value "x") (raw-value 64)) (list)))))
    (define a2 (thsl-src! "tests/agent-feature-tests.tesl" 256 (list (cons 'a1 a1)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "same"))) (raw-value "x") (raw-value 64)) (list)))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 257 (list (cons 'a2 a2) (cons 'a1 a1)) (lambda () (raw-value (replyText (raw-value (askReply (raw-value a1) "hi"))))))) (raw-value (ask (raw-value a2) "hi")))
    )
  )

  (test-case "ask still returns plain text through the loop machinery"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 261 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "plain text"))) (raw-value "x") (raw-value 64)) (list)))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 262 (list (cons 'agent agent)) (lambda () (raw-value (ask (raw-value agent) "hi"))))) "plain text")
    )
  )

  (test-case "tool loop dispatches with validated args and returns final text"
    (with-capabilities (supportBot)
    (define weatherTool (thsl-src! "tests/agent-feature-tests.tesl" 270 (list) (lambda () (raw-value (tool "get_weather" "Look up the weather for a city" "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}" validateWeather dispatchWeather)))))
    (define step1 (thsl-src! "tests/agent-feature-tests.tesl" 276 (list (cons 'weatherTool weatherTool)) (lambda () (raw-value (toolUseStep "get_weather" "call_1" "{\"city\":\"Malmo\"}")))))
    (define step2 (thsl-src! "tests/agent-feature-tests.tesl" 277 (list (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (textStep "It is sunny.")))))
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 278 (list (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list step1 step2))) (raw-value "You are a weather bot.") (raw-value 256)) (list weatherTool)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 279 (list (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (askReply (raw-value agent) "What is the weather in Malmo?")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 280 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyText (raw-value reply)))))) "It is sunny.")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 281 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
  )

  (test-case "tool loop with two tool calls counts both round-trips"
    (with-capabilities (supportBot)
    (define weatherTool (thsl-src! "tests/agent-feature-tests.tesl" 285 (list) (lambda () (raw-value (tool "get_weather" "weather" "{}" validateWeather dispatchWeather)))))
    (define step1 (thsl-src! "tests/agent-feature-tests.tesl" 286 (list (cons 'weatherTool weatherTool)) (lambda () (raw-value (toolUseStep "get_weather" "call_1" "{\"city\":\"Oslo\"}")))))
    (define step2 (thsl-src! "tests/agent-feature-tests.tesl" 287 (list (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (toolUseStep "get_weather" "call_2" "{\"city\":\"Bergen\"}")))))
    (define step3 (thsl-src! "tests/agent-feature-tests.tesl" 288 (list (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (textStep "Both checked.")))))
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 289 (list (cons 'step3 step3) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list step1 step2 step3))) (raw-value "x") (raw-value 256)) (list weatherTool)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 290 (list (cons 'agent agent) (cons 'step3 step3) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (askReply (raw-value agent) "two cities")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 291 (list (cons 'reply reply) (cons 'agent agent) (cons 'step3 step3) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyText (raw-value reply)))))) "Both checked.")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 292 (list (cons 'reply reply) (cons 'agent agent) (cons 'step3 step3) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 2)
    )
  )

  (test-case "tool loop with three tool calls counts three"
    (with-capabilities (supportBot)
    (define weatherTool (thsl-src! "tests/agent-feature-tests.tesl" 296 (list) (lambda () (raw-value (tool "get_weather" "weather" "{}" validateWeather dispatchWeather)))))
    (define s1 (thsl-src! "tests/agent-feature-tests.tesl" 297 (list (cons 'weatherTool weatherTool)) (lambda () (raw-value (toolUseStep "get_weather" "c1" "{\"city\":\"A\"}")))))
    (define s2 (thsl-src! "tests/agent-feature-tests.tesl" 298 (list (cons 's1 s1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (toolUseStep "get_weather" "c2" "{\"city\":\"B\"}")))))
    (define s3 (thsl-src! "tests/agent-feature-tests.tesl" 299 (list (cons 's2 s2) (cons 's1 s1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (toolUseStep "get_weather" "c3" "{\"city\":\"C\"}")))))
    (define s4 (thsl-src! "tests/agent-feature-tests.tesl" 300 (list (cons 's3 s3) (cons 's2 s2) (cons 's1 s1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (textStep "done")))))
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 301 (list (cons 's4 s4) (cons 's3 s3) (cons 's2 s2) (cons 's1 s1) (cons 'weatherTool weatherTool)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list s1 s2 s3 s4))) (raw-value "x") (raw-value 256)) (list weatherTool)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 302 (list (cons 'agent agent) (cons 's4 s4) (cons 's3 s3) (cons 's2 s2) (cons 's1 s1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (askReply (raw-value agent) "three")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 303 (list (cons 'reply reply) (cons 'agent agent) (cons 's4 s4) (cons 's3 s3) (cons 's2 s2) (cons 's1 s1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 3)
    )
  )

  (test-case "tool loop dispatches an Int-typed validated arg"
    (with-capabilities (supportBot)
    (define addTool (thsl-src! "tests/agent-feature-tests.tesl" 307 (list) (lambda () (raw-value (tool "add" "add two ints" "{}" validateAdd dispatchAdd)))))
    (define step1 (thsl-src! "tests/agent-feature-tests.tesl" 308 (list (cons 'addTool addTool)) (lambda () (raw-value (toolUseStep "add" "call_1" "{\"a\":0,\"b\":0}")))))
    (define step2 (thsl-src! "tests/agent-feature-tests.tesl" 309 (list (cons 'step1 step1) (cons 'addTool addTool)) (lambda () (raw-value (textStep "Computed.")))))
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 310 (list (cons 'step2 step2) (cons 'step1 step1) (cons 'addTool addTool)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list step1 step2))) (raw-value "x") (raw-value 128)) (list addTool)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 311 (list (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'addTool addTool)) (lambda () (raw-value (askReply (raw-value agent) "add them")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 312 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'addTool addTool)) (lambda () (raw-value (replyText (raw-value reply)))))) "Computed.")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 313 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'addTool addTool)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
  )

  (test-case "tool loop dispatches a Bool-typed validated arg (true)"
    (with-capabilities (supportBot)
    (define flagTool (thsl-src! "tests/agent-feature-tests.tesl" 317 (list) (lambda () (raw-value (tool "set_flag" "set a flag" "{}" validateFlag dispatchFlag)))))
    (define step1 (thsl-src! "tests/agent-feature-tests.tesl" 318 (list (cons 'flagTool flagTool)) (lambda () (raw-value (toolUseStep "set_flag" "call_1" "{\"on\":true}")))))
    (define step2 (thsl-src! "tests/agent-feature-tests.tesl" 319 (list (cons 'step1 step1) (cons 'flagTool flagTool)) (lambda () (raw-value (textStep "Set.")))))
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 320 (list (cons 'step2 step2) (cons 'step1 step1) (cons 'flagTool flagTool)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list step1 step2))) (raw-value "x") (raw-value 128)) (list flagTool)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 321 (list (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'flagTool flagTool)) (lambda () (raw-value (askReply (raw-value agent) "turn it on")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 322 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'flagTool flagTool)) (lambda () (raw-value (replyText (raw-value reply)))))) "Set.")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 323 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'flagTool flagTool)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
  )

  (test-case "tool loop dispatches a Bool-typed validated arg (false)"
    (with-capabilities (supportBot)
    (define flagTool (thsl-src! "tests/agent-feature-tests.tesl" 327 (list) (lambda () (raw-value (tool "set_flag" "set a flag" "{}" validateFlag dispatchFlag)))))
    (define step1 (thsl-src! "tests/agent-feature-tests.tesl" 328 (list (cons 'flagTool flagTool)) (lambda () (raw-value (toolUseStep "set_flag" "call_1" "{\"on\":false}")))))
    (define step2 (thsl-src! "tests/agent-feature-tests.tesl" 329 (list (cons 'step1 step1) (cons 'flagTool flagTool)) (lambda () (raw-value (textStep "Cleared.")))))
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 330 (list (cons 'step2 step2) (cons 'step1 step1) (cons 'flagTool flagTool)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list step1 step2))) (raw-value "x") (raw-value 128)) (list flagTool)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 331 (list (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'flagTool flagTool)) (lambda () (raw-value (askReply (raw-value agent) "turn it off")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 332 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'flagTool flagTool)) (lambda () (raw-value (replyText (raw-value reply)))))) "Cleared.")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 333 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'flagTool flagTool)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
  )

  (test-case "tool loop with no tool calls (text only) reports zero"
    (with-capabilities (supportBot)
    (define weatherTool (thsl-src! "tests/agent-feature-tests.tesl" 337 (list) (lambda () (raw-value (tool "get_weather" "weather" "{}" validateWeather dispatchWeather)))))
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 338 (list (cons 'weatherTool weatherTool)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list (raw-value (textStep "no tools needed"))))) (raw-value "x") (raw-value 64)) (list weatherTool)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 339 (list (cons 'agent agent) (cons 'weatherTool weatherTool)) (lambda () (raw-value (askReply (raw-value agent) "hi")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 340 (list (cons 'reply reply) (cons 'agent agent) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyText (raw-value reply)))))) "no tools needed")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 341 (list (cons 'reply reply) (cons 'agent agent) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 0)
    )
  )

  (test-case "an agent with multiple tools still resolves the called one"
    (with-capabilities (supportBot)
    (define weatherTool (thsl-src! "tests/agent-feature-tests.tesl" 345 (list) (lambda () (raw-value (tool "get_weather" "weather" "{}" validateWeather dispatchWeather)))))
    (define addTool (thsl-src! "tests/agent-feature-tests.tesl" 346 (list (cons 'weatherTool weatherTool)) (lambda () (raw-value (tool "add" "add" "{}" validateAdd dispatchAdd)))))
    (define step1 (thsl-src! "tests/agent-feature-tests.tesl" 347 (list (cons 'addTool addTool) (cons 'weatherTool weatherTool)) (lambda () (raw-value (toolUseStep "add" "call_1" "{\"a\":0,\"b\":0}")))))
    (define step2 (thsl-src! "tests/agent-feature-tests.tesl" 348 (list (cons 'step1 step1) (cons 'addTool addTool) (cons 'weatherTool weatherTool)) (lambda () (raw-value (textStep "picked add")))))
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 349 (list (cons 'step2 step2) (cons 'step1 step1) (cons 'addTool addTool) (cons 'weatherTool weatherTool)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list step1 step2))) (raw-value "x") (raw-value 128)) (list weatherTool addTool)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 350 (list (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'addTool addTool) (cons 'weatherTool weatherTool)) (lambda () (raw-value (askReply (raw-value agent) "use add")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 351 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'addTool addTool) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyText (raw-value reply)))))) "picked add")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 352 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'addTool addTool) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
  )

  (test-case "malformed tool args (missing field) become is_error and loop continues"
    (with-capabilities (supportBot)
    (define weatherTool (thsl-src! "tests/agent-feature-tests.tesl" 360 (list) (lambda () (raw-value (tool "get_weather" "weather" "{}" validateWeather dispatchWeather)))))
    (define step1 (thsl-src! "tests/agent-feature-tests.tesl" 361 (list (cons 'weatherTool weatherTool)) (lambda () (raw-value (toolUseStep "get_weather" "call_1" "{\"wrong\":\"field\"}")))))
    (define step2 (thsl-src! "tests/agent-feature-tests.tesl" 362 (list (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (textStep "Sorry, could not look that up.")))))
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 363 (list (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list step1 step2))) (raw-value "x") (raw-value 256)) (list weatherTool)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 364 (list (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (askReply (raw-value agent) "weather?")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 365 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyText (raw-value reply)))))) "Sorry, could not look that up.")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 366 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
  )

  (test-case "malformed args (wrong type) are rejected as is_error, no exception"
    (with-capabilities (supportBot)
    (define addTool (thsl-src! "tests/agent-feature-tests.tesl" 370 (list) (lambda () (raw-value (tool "add" "add" "{}" validateAdd dispatchAdd)))))
    (define step1 (thsl-src! "tests/agent-feature-tests.tesl" 371 (list (cons 'addTool addTool)) (lambda () (raw-value (toolUseStep "add" "call_1" "{\"a\":\"not-a-number\",\"b\":2}")))))
    (define step2 (thsl-src! "tests/agent-feature-tests.tesl" 372 (list (cons 'step1 step1) (cons 'addTool addTool)) (lambda () (raw-value (textStep "recovered")))))
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 373 (list (cons 'step2 step2) (cons 'step1 step1) (cons 'addTool addTool)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list step1 step2))) (raw-value "x") (raw-value 256)) (list addTool)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 374 (list (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'addTool addTool)) (lambda () (raw-value (askReply (raw-value agent) "add")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 375 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'addTool addTool)) (lambda () (raw-value (replyText (raw-value reply)))))) "recovered")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 376 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'addTool addTool)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
  )

  (test-case "malformed args (empty object) are rejected as is_error"
    (with-capabilities (supportBot)
    (define weatherTool (thsl-src! "tests/agent-feature-tests.tesl" 380 (list) (lambda () (raw-value (tool "get_weather" "weather" "{}" validateWeather dispatchWeather)))))
    (define step1 (thsl-src! "tests/agent-feature-tests.tesl" 381 (list (cons 'weatherTool weatherTool)) (lambda () (raw-value (toolUseStep "get_weather" "call_1" "{}")))))
    (define step2 (thsl-src! "tests/agent-feature-tests.tesl" 382 (list (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (textStep "no city given")))))
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 383 (list (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list step1 step2))) (raw-value "x") (raw-value 256)) (list weatherTool)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 384 (list (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (askReply (raw-value agent) "weather")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 385 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyText (raw-value reply)))))) "no city given")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 386 (list (cons 'reply reply) (cons 'agent agent) (cons 'step2 step2) (cons 'step1 step1) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    )
  )

  (test-case "a bad tool call followed by a good one still completes"
    (with-capabilities (supportBot)
    (define weatherTool (thsl-src! "tests/agent-feature-tests.tesl" 390 (list) (lambda () (raw-value (tool "get_weather" "weather" "{}" validateWeather dispatchWeather)))))
    (define bad (thsl-src! "tests/agent-feature-tests.tesl" 391 (list (cons 'weatherTool weatherTool)) (lambda () (raw-value (toolUseStep "get_weather" "c1" "{\"nope\":1}")))))
    (define good (thsl-src! "tests/agent-feature-tests.tesl" 392 (list (cons 'bad bad) (cons 'weatherTool weatherTool)) (lambda () (raw-value (toolUseStep "get_weather" "c2" "{\"city\":\"Lund\"}")))))
    (define final (thsl-src! "tests/agent-feature-tests.tesl" 393 (list (cons 'good good) (cons 'bad bad) (cons 'weatherTool weatherTool)) (lambda () (raw-value (textStep "Looked up Lund.")))))
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 394 (list (cons 'final final) (cons 'good good) (cons 'bad bad) (cons 'weatherTool weatherTool)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list bad good final))) (raw-value "x") (raw-value 256)) (list weatherTool)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 395 (list (cons 'agent agent) (cons 'final final) (cons 'good good) (cons 'bad bad) (cons 'weatherTool weatherTool)) (lambda () (raw-value (askReply (raw-value agent) "retry weather")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 396 (list (cons 'reply reply) (cons 'agent agent) (cons 'final final) (cons 'good good) (cons 'bad bad) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyText (raw-value reply)))))) "Looked up Lund.")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 397 (list (cons 'reply reply) (cons 'agent agent) (cons 'final final) (cons 'good good) (cons 'bad bad) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 2)
    )
  )

  (test-case "askFor decodes a typed value on the first reply"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 405 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "{\"title\":\"All good\",\"score\":42}"))) (raw-value "JSON.") (raw-value 128)) (list)))))
    (define summary (thsl-src! "tests/agent-feature-tests.tesl" 406 (list (cons 'agent agent)) (lambda () (raw-value (askFor (raw-value agent) "summarize" decodeSummary 2)))))
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 407 (list (cons 'summary summary) (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime summary 'title)))) "All good")
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 408 (list (cons 'summary summary) (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime summary 'score)))) 42)
    )
  )

  (test-case "askFor decodes a single-field record"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 412 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "{\"label\":\"positive\"}"))) (raw-value "JSON.") (raw-value 64)) (list)))))
    (define s (thsl-src! "tests/agent-feature-tests.tesl" 413 (list (cons 'agent agent)) (lambda () (raw-value (askFor (raw-value agent) "classify" decodeSentiment 2)))))
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 414 (list (cons 's s) (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime s 'label)))) "positive")
    )
  )

  (test-case "askFor through a wrapper handler decodes the value"
    (with-capabilities (supportBot)
    (define s (thsl-src! "tests/agent-feature-tests.tesl" 418 (list) (lambda () (classify "great product"))))
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 419 (list (cons 's s)) (lambda () (raw-value (tesl-dot/runtime s 'label)))) "positive")
    )
  )

  (test-case "askFor succeeds with maxRetries of 1 when the first reply is valid"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 423 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "{\"title\":\"One shot\",\"score\":1}"))) (raw-value "JSON.") (raw-value 64)) (list)))))
    (define summary (thsl-src! "tests/agent-feature-tests.tesl" 424 (list (cons 'agent agent)) (lambda () (raw-value (askFor (raw-value agent) "x" decodeSummary 1)))))
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 425 (list (cons 'summary summary) (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime summary 'title)))) "One shot")
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 426 (list (cons 'summary summary) (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime summary 'score)))) 1)
    )
  )

  (test-case "askFor decodes a negative integer field"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 430 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "{\"title\":\"Cold\",\"score\":-5}"))) (raw-value "JSON.") (raw-value 64)) (list)))))
    (define summary (thsl-src! "tests/agent-feature-tests.tesl" 431 (list (cons 'agent agent)) (lambda () (raw-value (askFor (raw-value agent) "x" decodeSummary 2)))))
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 432 (list (cons 'summary summary) (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime summary 'score)))) -5)
    )
  )

  (test-case "askFor retries after one decode failure then succeeds"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 440 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "not json at all" "{\"title\":\"Recovered\",\"score\":7}"))) (raw-value "JSON.") (raw-value 128)) (list)))))
    (define summary (thsl-src! "tests/agent-feature-tests.tesl" 441 (list (cons 'agent agent)) (lambda () (raw-value (askFor (raw-value agent) "summarize" decodeSummary 2)))))
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 442 (list (cons 'summary summary) (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime summary 'title)))) "Recovered")
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 443 (list (cons 'summary summary) (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime summary 'score)))) 7)
    )
  )

  (test-case "askFor retries twice (two bad replies) then succeeds on the third"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 447 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "garbage" "{\"oops\":true}" "{\"title\":\"Third\",\"score\":3}"))) (raw-value "JSON.") (raw-value 128)) (list)))))
    (define summary (thsl-src! "tests/agent-feature-tests.tesl" 448 (list (cons 'agent agent)) (lambda () (raw-value (askFor (raw-value agent) "x" decodeSummary 3)))))
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 449 (list (cons 'summary summary) (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime summary 'title)))) "Third")
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 450 (list (cons 'summary summary) (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime summary 'score)))) 3)
    )
  )

  (test-case "askFor retry recovers a single-field decoder"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 454 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "bad" "{\"label\":\"neutral\"}"))) (raw-value "JSON.") (raw-value 64)) (list)))))
    (define s (thsl-src! "tests/agent-feature-tests.tesl" 455 (list (cons 'agent agent)) (lambda () (raw-value (askFor (raw-value agent) "x" decodeSentiment 2)))))
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 456 (list (cons 's s) (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime s 'label)))) "neutral")
    )
  )

  (test-case "askFor retry consumes the bad reply before the good one"
    (with-capabilities (supportBot)
    (define a1 (thsl-src! "tests/agent-feature-tests.tesl" 462 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "nope" "{\"title\":\"A\",\"score\":1}"))) (raw-value "JSON.") (raw-value 64)) (list)))))
    (define a2 (thsl-src! "tests/agent-feature-tests.tesl" 463 (list (cons 'a1 a1)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "{\"title\":\"B\",\"score\":2}"))) (raw-value "JSON.") (raw-value 64)) (list)))))
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 464 (list (cons 'a2 a2) (cons 'a1 a1)) (lambda () (raw-value (tesl-dot/runtime (raw-value (askFor (raw-value a1) "x" decodeSummary 2)) 'title)))) "A")
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 465 (list (cons 'a2 a2) (cons 'a1 a1)) (lambda () (raw-value (tesl-dot/runtime (raw-value (askFor (raw-value a2) "y" decodeSummary 2)) 'title)))) "B")
    )
  )

  (test-case "askWith uses the BYOK provider override, not the agent default"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 473 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "default reply"))) (raw-value "x") (raw-value 64)) (list)))))
    (define byok (thsl-src! "tests/agent-feature-tests.tesl" 474 (list (cons 'agent agent)) (lambda () (raw-value (mockProvider (list "override reply"))))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 475 (list (cons 'byok byok) (cons 'agent agent)) (lambda () (raw-value (askWith (raw-value agent) "hi" (raw-value byok))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 476 (list (cons 'reply reply) (cons 'byok byok) (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value reply)))))) "override reply")
    )
  )

  (test-case "askWith ignores the agent's bound provider entirely"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 480 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "WRONG" "ALSO WRONG"))) (raw-value "x") (raw-value 64)) (list)))))
    (define byok (thsl-src! "tests/agent-feature-tests.tesl" 481 (list (cons 'agent agent)) (lambda () (raw-value (mockProvider (list "right"))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 482 (list (cons 'byok byok) (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value (askWith (raw-value agent) "hi" (raw-value byok)))))))) "right")
    )
  )

  (test-case "askWith with a fresh override each call walks each override script"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 486 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "unused"))) (raw-value "x") (raw-value 64)) (list)))))
    (define r1 (thsl-src! "tests/agent-feature-tests.tesl" 487 (list (cons 'agent agent)) (lambda () (raw-value (askWith (raw-value agent) "a" (raw-value (mockProvider (list "o1"))))))))
    (define r2 (thsl-src! "tests/agent-feature-tests.tesl" 488 (list (cons 'r1 r1) (cons 'agent agent)) (lambda () (raw-value (askWith (raw-value agent) "b" (raw-value (mockProvider (list "o2"))))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 489 (list (cons 'r2 r2) (cons 'r1 r1) (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value r1)))))) "o1")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 490 (list (cons 'r2 r2) (cons 'r1 r1) (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value r2)))))) "o2")
    )
  )

  (test-case "askWith reports zero tool calls for a plain text override"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 494 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "x"))) (raw-value "x") (raw-value 64)) (list)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 495 (list (cons 'agent agent)) (lambda () (raw-value (askWith (raw-value agent) "hi" (raw-value (mockProvider (list "text only"))))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 496 (list (cons 'reply reply) (cons 'agent agent)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 0)
    )
  )

  (test-case "converse threads turn 1 history into turn 2"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 504 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "First reply about cats" "Second reply still about cats"))) (raw-value "bot.") (raw-value 128)) (list)))))
    (define conv0 (thsl-src! "tests/agent-feature-tests.tesl" 505 (list (cons 'agent agent)) (lambda () (raw-value (newConversation (raw-value agent))))))
    (define turn1 (thsl-src! "tests/agent-feature-tests.tesl" 506 (list (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (converse (raw-value conv0) "Tell me about cats")))))
    (define conv1 (thsl-src! "tests/agent-feature-tests.tesl" 507 (list (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value turn1))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 508 (list (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value (turnReply (raw-value turn1)))))))) "First reply about cats")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 509 (list (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationLength (raw-value conv1)))))) 2)
    (define turn2 (thsl-src! "tests/agent-feature-tests.tesl" 510 (list (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (converse (raw-value conv1) "What did I just ask about?")))))
    (define conv2 (thsl-src! "tests/agent-feature-tests.tesl" 511 (list (cons 'turn2 turn2) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value turn2))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 512 (list (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value (turnReply (raw-value turn2)))))))) "Second reply still about cats")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 513 (list (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationLength (raw-value conv2)))))) 4)
    (define history (thsl-src! "tests/agent-feature-tests.tesl" 514 (list (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationJson (raw-value conv2))))))
    (check-true (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 515 (list (cons 'history history) (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value history) "Tell me about cats")))))
    (check-true (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 516 (list (cons 'history history) (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value history) "First reply about cats")))))
    (check-true (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 517 (list (cons 'history history) (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value history) "What did I just ask about?")))))
    )
  )

  (test-case "newConversation starts empty (length 0)"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 521 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "x"))) (raw-value "x") (raw-value 32)) (list)))))
    (define conv0 (thsl-src! "tests/agent-feature-tests.tesl" 522 (list (cons 'agent agent)) (lambda () (raw-value (newConversation (raw-value agent))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 523 (list (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationLength (raw-value conv0)))))) 0)
    )
  )

  (test-case "one converse turn records exactly two entries"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 527 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "reply"))) (raw-value "x") (raw-value 64)) (list)))))
    (define conv0 (thsl-src! "tests/agent-feature-tests.tesl" 528 (list (cons 'agent agent)) (lambda () (raw-value (newConversation (raw-value agent))))))
    (define turn1 (thsl-src! "tests/agent-feature-tests.tesl" 529 (list (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (converse (raw-value conv0) "question")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 530 (list (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationLength (raw-value (turnConversation (raw-value turn1)))))))) 2)
    )
  )

  (test-case "conversationLength grows by two each turn"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 534 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "r1" "r2" "r3"))) (raw-value "x") (raw-value 64)) (list)))))
    (define c0 (thsl-src! "tests/agent-feature-tests.tesl" 535 (list (cons 'agent agent)) (lambda () (raw-value (newConversation (raw-value agent))))))
    (define c1 (thsl-src! "tests/agent-feature-tests.tesl" 536 (list (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value (converse (raw-value c0) "q1")))))))
    (define c2 (thsl-src! "tests/agent-feature-tests.tesl" 537 (list (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value (converse (raw-value c1) "q2")))))))
    (define c3 (thsl-src! "tests/agent-feature-tests.tesl" 538 (list (cons 'c2 c2) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value (converse (raw-value c2) "q3")))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 539 (list (cons 'c3 c3) (cons 'c2 c2) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (conversationLength (raw-value c1)))))) 2)
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 540 (list (cons 'c3 c3) (cons 'c2 c2) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (conversationLength (raw-value c2)))))) 4)
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 541 (list (cons 'c3 c3) (cons 'c2 c2) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (conversationLength (raw-value c3)))))) 6)
    )
  )

  (test-case "turnReply text matches the scripted reply for that turn"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 545 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "alpha" "beta"))) (raw-value "x") (raw-value 64)) (list)))))
    (define c0 (thsl-src! "tests/agent-feature-tests.tesl" 546 (list (cons 'agent agent)) (lambda () (raw-value (newConversation (raw-value agent))))))
    (define t1 (thsl-src! "tests/agent-feature-tests.tesl" 547 (list (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (converse (raw-value c0) "one")))))
    (define t2 (thsl-src! "tests/agent-feature-tests.tesl" 548 (list (cons 't1 t1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (converse (raw-value (turnConversation (raw-value t1))) "two")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 549 (list (cons 't2 t2) (cons 't1 t1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value (turnReply (raw-value t1)))))))) "alpha")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 550 (list (cons 't2 t2) (cons 't1 t1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value (turnReply (raw-value t2)))))))) "beta")
    )
  )

  (test-case "conversationJson contains every user prompt across turns"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 554 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "r1" "r2"))) (raw-value "x") (raw-value 64)) (list)))))
    (define c0 (thsl-src! "tests/agent-feature-tests.tesl" 555 (list (cons 'agent agent)) (lambda () (raw-value (newConversation (raw-value agent))))))
    (define c1 (thsl-src! "tests/agent-feature-tests.tesl" 556 (list (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value (converse (raw-value c0) "first ask")))))))
    (define c2 (thsl-src! "tests/agent-feature-tests.tesl" 557 (list (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value (converse (raw-value c1) "second ask")))))))
    (define j (thsl-src! "tests/agent-feature-tests.tesl" 558 (list (cons 'c2 c2) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (conversationJson (raw-value c2))))))
    (check-true (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 559 (list (cons 'j j) (cons 'c2 c2) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value j) "first ask")))))
    (check-true (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 560 (list (cons 'j j) (cons 'c2 c2) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value j) "second ask")))))
    )
  )

  (test-case "conversationJson contains every assistant reply across turns"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 564 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "reply one" "reply two"))) (raw-value "x") (raw-value 64)) (list)))))
    (define c0 (thsl-src! "tests/agent-feature-tests.tesl" 565 (list (cons 'agent agent)) (lambda () (raw-value (newConversation (raw-value agent))))))
    (define c1 (thsl-src! "tests/agent-feature-tests.tesl" 566 (list (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value (converse (raw-value c0) "q1")))))))
    (define c2 (thsl-src! "tests/agent-feature-tests.tesl" 567 (list (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value (converse (raw-value c1) "q2")))))))
    (define j (thsl-src! "tests/agent-feature-tests.tesl" 568 (list (cons 'c2 c2) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (conversationJson (raw-value c2))))))
    (check-true (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 569 (list (cons 'j j) (cons 'c2 c2) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value j) "reply one")))))
    (check-true (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 570 (list (cons 'j j) (cons 'c2 c2) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value j) "reply two")))))
    )
  )

  (test-case "history is accumulated, not reset, on the second turn"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 574 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "A" "B"))) (raw-value "x") (raw-value 64)) (list)))))
    (define c0 (thsl-src! "tests/agent-feature-tests.tesl" 575 (list (cons 'agent agent)) (lambda () (raw-value (newConversation (raw-value agent))))))
    (define c1 (thsl-src! "tests/agent-feature-tests.tesl" 576 (list (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value (converse (raw-value c0) "keep me")))))))
    (define c2 (thsl-src! "tests/agent-feature-tests.tesl" 577 (list (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value (converse (raw-value c1) "and me")))))))
    (check-true (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 579 (list (cons 'c2 c2) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value (conversationJson (raw-value c2))) "keep me")))))
    )
  )

  (test-case "conversationFrom restores a serialized thread and continues it"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 587 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "Reply one" "Reply two"))) (raw-value "x") (raw-value 64)) (list)))))
    (define conv0 (thsl-src! "tests/agent-feature-tests.tesl" 588 (list (cons 'agent agent)) (lambda () (raw-value (newConversation (raw-value agent))))))
    (define conv1 (thsl-src! "tests/agent-feature-tests.tesl" 589 (list (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value (converse (raw-value conv0) "first question")))))))
    (define saved (thsl-src! "tests/agent-feature-tests.tesl" 590 (list (cons 'conv1 conv1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationJson (raw-value conv1))))))
    (define reloaded (thsl-src! "tests/agent-feature-tests.tesl" 591 (list (cons 'saved saved) (cons 'conv1 conv1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationFrom (raw-value agent) (raw-value saved))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 592 (list (cons 'reloaded reloaded) (cons 'saved saved) (cons 'conv1 conv1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationLength (raw-value reloaded)))))) 2)
    (define turn2 (thsl-src! "tests/agent-feature-tests.tesl" 593 (list (cons 'reloaded reloaded) (cons 'saved saved) (cons 'conv1 conv1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (converse (raw-value reloaded) "second question")))))
    (define conv2 (thsl-src! "tests/agent-feature-tests.tesl" 594 (list (cons 'turn2 turn2) (cons 'reloaded reloaded) (cons 'saved saved) (cons 'conv1 conv1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value turn2))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 595 (list (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'reloaded reloaded) (cons 'saved saved) (cons 'conv1 conv1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value (turnReply (raw-value turn2)))))))) "Reply two")
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 596 (list (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'reloaded reloaded) (cons 'saved saved) (cons 'conv1 conv1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationLength (raw-value conv2)))))) 4)
    (define history2 (thsl-src! "tests/agent-feature-tests.tesl" 597 (list (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'reloaded reloaded) (cons 'saved saved) (cons 'conv1 conv1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationJson (raw-value conv2))))))
    (check-true (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 598 (list (cons 'history2 history2) (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'reloaded reloaded) (cons 'saved saved) (cons 'conv1 conv1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value history2) "first question")))))
    (check-true (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 599 (list (cons 'history2 history2) (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'reloaded reloaded) (cons 'saved saved) (cons 'conv1 conv1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value history2) "Reply one")))))
    )
  )

  (test-case "conversationFrom round-trips the length exactly"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 603 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "r1" "r2"))) (raw-value "x") (raw-value 64)) (list)))))
    (define c0 (thsl-src! "tests/agent-feature-tests.tesl" 604 (list (cons 'agent agent)) (lambda () (raw-value (newConversation (raw-value agent))))))
    (define c1 (thsl-src! "tests/agent-feature-tests.tesl" 605 (list (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value (converse (raw-value c0) "q1")))))))
    (define c2 (thsl-src! "tests/agent-feature-tests.tesl" 606 (list (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value (converse (raw-value c1) "q2")))))))
    (define saved (thsl-src! "tests/agent-feature-tests.tesl" 607 (list (cons 'c2 c2) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (conversationJson (raw-value c2))))))
    (define reloaded (thsl-src! "tests/agent-feature-tests.tesl" 608 (list (cons 'saved saved) (cons 'c2 c2) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (conversationFrom (raw-value agent) (raw-value saved))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 609 (list (cons 'reloaded reloaded) (cons 'saved saved) (cons 'c2 c2) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (conversationLength (raw-value reloaded)))))) (raw-value (conversationLength (raw-value c2))))
    )
  )

  (test-case "conversationFrom preserves the serialized prompts and replies"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 613 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "only reply"))) (raw-value "x") (raw-value 64)) (list)))))
    (define c0 (thsl-src! "tests/agent-feature-tests.tesl" 614 (list (cons 'agent agent)) (lambda () (raw-value (newConversation (raw-value agent))))))
    (define c1 (thsl-src! "tests/agent-feature-tests.tesl" 615 (list (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value (converse (raw-value c0) "only question")))))))
    (define reloaded (thsl-src! "tests/agent-feature-tests.tesl" 616 (list (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (conversationFrom (raw-value agent) (raw-value (conversationJson (raw-value c1))))))))
    (define j (thsl-src! "tests/agent-feature-tests.tesl" 617 (list (cons 'reloaded reloaded) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (raw-value (conversationJson (raw-value reloaded))))))
    (check-true (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 618 (list (cons 'j j) (cons 'reloaded reloaded) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value j) "only question")))))
    (check-true (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 619 (list (cons 'j j) (cons 'reloaded reloaded) (cons 'c1 c1) (cons 'c0 c0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value j) "only reply")))))
    )
  )

  (test-case "conversationFrom on an empty thread yields length 0"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 623 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "x"))) (raw-value "x") (raw-value 32)) (list)))))
    (define empty (thsl-src! "tests/agent-feature-tests.tesl" 624 (list (cons 'agent agent)) (lambda () (raw-value (conversationJson (raw-value (newConversation (raw-value agent))))))))
    (define reloaded (thsl-src! "tests/agent-feature-tests.tesl" 625 (list (cons 'empty empty) (cons 'agent agent)) (lambda () (raw-value (conversationFrom (raw-value agent) (raw-value empty))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 626 (list (cons 'reloaded reloaded) (cons 'empty empty) (cons 'agent agent)) (lambda () (raw-value (conversationLength (raw-value reloaded)))))) 0)
    )
  )

  (test-case "capability flows: ask under supportBot"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 635 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "cap ok"))) (raw-value "x") (raw-value 32)) (list)))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 636 (list (cons 'agent agent)) (lambda () (raw-value (ask (raw-value agent) "hi"))))) "cap ok")
    )
  )

  (test-case "capability flows: askReply under supportBot"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 640 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "cap reply"))) (raw-value "x") (raw-value 32)) (list)))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 641 (list (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value (askReply (raw-value agent) "hi"))))))) "cap reply")
    )
  )

  (test-case "capability flows: askWith under supportBot"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 645 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "unused"))) (raw-value "x") (raw-value 32)) (list)))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 646 (list (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value (askWith (raw-value agent) "hi" (raw-value (mockProvider (list "byok ok")))))))))) "byok ok")
    )
  )

  (test-case "capability flows: askFor under supportBot"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 650 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "{\"label\":\"ok\"}"))) (raw-value "x") (raw-value 32)) (list)))))
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 651 (list (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime (raw-value (askFor (raw-value agent) "hi" decodeSentiment 2)) 'label)))) "ok")
    )
  )

  (test-case "capability flows: converse under supportBot"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 655 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "cap converse"))) (raw-value "x") (raw-value 32)) (list)))))
    (define turn (thsl-src! "tests/agent-feature-tests.tesl" 656 (list (cons 'agent agent)) (lambda () (raw-value (converse (raw-value (newConversation (raw-value agent))) "hi")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 657 (list (cons 'turn turn) (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value (turnReply (raw-value turn)))))))) "cap converse")
    )
  )

  (test-case "decodeAs standalone decodes a JSON string to a typed value"
    (with-capabilities (supportBot)
    (define s (thsl-src! "tests/agent-feature-tests.tesl" 665 (list) (lambda () (decodeSummary "{\"title\":\"direct\",\"score\":9}"))))
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 666 (list (cons 's s)) (lambda () (raw-value (tesl-dot/runtime s 'title)))) "direct")
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 667 (list (cons 's s)) (lambda () (raw-value (tesl-dot/runtime s 'score)))) 9)
    )
  )

  (test-case "tool loop then a separate structured-output ask compose"
    (with-capabilities (supportBot)
    (define weatherTool (thsl-src! "tests/agent-feature-tests.tesl" 671 (list) (lambda () (raw-value (tool "get_weather" "weather" "{}" validateWeather dispatchWeather)))))
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 672 (list (cons 'weatherTool weatherTool)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list (raw-value (toolUseStep "get_weather" "c1" "{\"city\":\"Paris\"}")) (raw-value (textStep "checked"))))) (raw-value "x") (raw-value 256)) (list weatherTool)))))
    (define reply (thsl-src! "tests/agent-feature-tests.tesl" 673 (list (cons 'agent agent) (cons 'weatherTool weatherTool)) (lambda () (raw-value (askReply (raw-value agent) "weather")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 674 (list (cons 'reply reply) (cons 'agent agent) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyToolCalls (raw-value reply)))))) 1)
    (define s (thsl-src! "tests/agent-feature-tests.tesl" 675 (list (cons 'reply reply) (cons 'agent agent) (cons 'weatherTool weatherTool)) (lambda () (classify "ok"))))
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 676 (list (cons 's s) (cons 'reply reply) (cons 'agent agent) (cons 'weatherTool weatherTool)) (lambda () (raw-value (tesl-dot/runtime s 'label)))) "positive")
    )
  )

  (test-case "converse reply feeds a downstream structured decode of the same shape"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 680 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "{\"label\":\"happy\"}"))) (raw-value "x") (raw-value 64)) (list)))))
    (define turn (thsl-src! "tests/agent-feature-tests.tesl" 681 (list (cons 'agent agent)) (lambda () (raw-value (converse (raw-value (newConversation (raw-value agent))) "classify mood")))))
    (define txt (thsl-src! "tests/agent-feature-tests.tesl" 682 (list (cons 'turn turn) (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value (turnReply (raw-value turn))))))))
    (define s (thsl-src! "tests/agent-feature-tests.tesl" 683 (list (cons 'txt txt) (cons 'turn turn) (cons 'agent agent)) (lambda () (decodeSentiment txt))))
    (check-equal? (thsl-src! "tests/agent-feature-tests.tesl" 684 (list (cons 's s) (cons 'txt txt) (cons 'turn turn) (cons 'agent agent)) (lambda () (raw-value (tesl-dot/runtime s 'label)))) "happy")
    )
  )

  (test-case "a listed tool the model never calls leaves the reply unchanged"
    (with-capabilities (supportBot)
    (define weatherTool (thsl-src! "tests/agent-feature-tests.tesl" 688 (list) (lambda () (raw-value (tool "get_weather" "weather" "{}" validateWeather dispatchWeather)))))
    (define agent (thsl-src! "tests/agent-feature-tests.tesl" 689 (list (cons 'weatherTool weatherTool)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockToolProvider (list (raw-value (textStep "no call"))))) (raw-value "x") (raw-value 64)) (list weatherTool)))))
    (check-equal? (raw-value (thsl-src! "tests/agent-feature-tests.tesl" 690 (list (cons 'agent agent) (cons 'weatherTool weatherTool)) (lambda () (raw-value (replyText (raw-value (askReply (raw-value agent) "hi"))))))) "no call")
    )
  )

)
