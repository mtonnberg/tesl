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
  (only-in tesl/tesl/agent aiProvider Agent LlmProvider AgentReply mockProvider ask)
)


(provide askMock askMock-signature)

(define-capability supportBot (implies aiProvider))

(define/pow
  (askMock [prompt : String])
  #:capabilities [supportBot]
  #:returns String
  (let ([agent (thsl-src! "tests/agent-tests.tesl" 32 (list (cons 'prompt *prompt)) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "hello from mock"))) (raw-value "You are a test bot.") (raw-value 100)) (list))))]) (thsl-src! "tests/agent-tests.tesl" 33 (list (cons 'agent *agent) (cons 'prompt *prompt)) (lambda () (raw-value (ask (raw-value agent) *prompt))))))

(module+ test
  (require rackunit)
  (test-case "ask returns the mock provider's scripted reply"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-tests.tesl" 40 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "hello from mock"))) (raw-value "x") (raw-value 100)) (list)))))
    (define reply (thsl-src! "tests/agent-tests.tesl" 41 (list (cons 'agent agent)) (lambda () (raw-value (ask (raw-value agent) "hi")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-tests.tesl" 42 (list (cons 'reply reply) (cons 'agent agent)) (lambda () reply))) "hello from mock")
    )
    ))
  )

  (test-case "ask through a wrapper handler returns the scripted reply"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (supportBot)
    (check-equal? (raw-value (thsl-src! "tests/agent-tests.tesl" 46 (list) (lambda () (askMock "anything")))) "hello from mock")
    )
    ))
  )

  (test-case "successive asks walk the mock script by call index"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-tests.tesl" 50 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "first" "second"))) (raw-value "x") (raw-value 50)) (list)))))
    (define r1 (thsl-src! "tests/agent-tests.tesl" 51 (list (cons 'agent agent)) (lambda () (raw-value (ask (raw-value agent) "a")))))
    (define r2 (thsl-src! "tests/agent-tests.tesl" 52 (list (cons 'r1 r1) (cons 'agent agent)) (lambda () (raw-value (ask (raw-value agent) "b")))))
    (check-equal? (raw-value (thsl-src! "tests/agent-tests.tesl" 53 (list (cons 'r2 r2) (cons 'r1 r1) (cons 'agent agent)) (lambda () r1))) "first")
    (check-equal? (raw-value (thsl-src! "tests/agent-tests.tesl" 54 (list (cons 'r2 r2) (cons 'r1 r1) (cons 'agent agent)) (lambda () r2))) "second")
    )
    ))
  )

)
