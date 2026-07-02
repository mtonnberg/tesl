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
  (only-in tesl/tesl/prelude Int String Bool)
  (only-in tesl/tesl/string [String.contains tesl_import_String_contains])
  (only-in tesl/tesl/agent aiProvider mockProvider Agent newConversation conversationFrom converse turnReply turnConversation conversationJson conversationLength replyText)
)


(provide )

(define-capability supportBot (implies aiProvider))

(module+ test
  (require rackunit)
  (test-case "converse threads turn 1 history into turn 2"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-conversation-tests.tesl" 37 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "First reply about cats" "Second reply still about cats"))) (raw-value "You are a helpful bot.") (raw-value 128)) (list)))))
    (define conv0 (thsl-src! "tests/agent-conversation-tests.tesl" 39 (list (cons 'agent agent)) (lambda () (raw-value (newConversation (raw-value agent))))))
    (define turn1 (thsl-src! "tests/agent-conversation-tests.tesl" 42 (list (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (converse (raw-value conv0) "Tell me about cats")))))
    (define conv1 (thsl-src! "tests/agent-conversation-tests.tesl" 43 (list (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value turn1))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-conversation-tests.tesl" 44 (list (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value (turnReply (raw-value turn1)))))))) "First reply about cats")
    (check-equal? (raw-value (thsl-src! "tests/agent-conversation-tests.tesl" 46 (list (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationLength (raw-value conv1)))))) 2)
    (define turn2 (thsl-src! "tests/agent-conversation-tests.tesl" 49 (list (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (converse (raw-value conv1) "What did I just ask about?")))))
    (define conv2 (thsl-src! "tests/agent-conversation-tests.tesl" 50 (list (cons 'turn2 turn2) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value turn2))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-conversation-tests.tesl" 51 (list (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value (turnReply (raw-value turn2)))))))) "Second reply still about cats")
    (check-equal? (raw-value (thsl-src! "tests/agent-conversation-tests.tesl" 53 (list (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationLength (raw-value conv2)))))) 4)
    (define history (thsl-src! "tests/agent-conversation-tests.tesl" 57 (list (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationJson (raw-value conv2))))))
    (check-true (raw-value (thsl-src! "tests/agent-conversation-tests.tesl" 58 (list (cons 'history history) (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value history) "Tell me about cats")))))
    (check-true (raw-value (thsl-src! "tests/agent-conversation-tests.tesl" 59 (list (cons 'history history) (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value history) "First reply about cats")))))
    (check-true (raw-value (thsl-src! "tests/agent-conversation-tests.tesl" 60 (list (cons 'history history) (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value history) "What did I just ask about?")))))
    )
  )

  (test-case "conversationFrom restores a serialized thread and continues it"
    (with-capabilities (supportBot)
    (define agent (thsl-src! "tests/agent-conversation-tests.tesl" 66 (list) (lambda () (__tart_withTools (__tart_defineAgent (raw-value (mockProvider (list "Reply one" "Reply two"))) (raw-value "x") (raw-value 64)) (list)))))
    (define conv0 (thsl-src! "tests/agent-conversation-tests.tesl" 68 (list (cons 'agent agent)) (lambda () (raw-value (newConversation (raw-value agent))))))
    (define turn1 (thsl-src! "tests/agent-conversation-tests.tesl" 69 (list (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (converse (raw-value conv0) "first question")))))
    (define conv1 (thsl-src! "tests/agent-conversation-tests.tesl" 70 (list (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value turn1))))))
    (define saved (thsl-src! "tests/agent-conversation-tests.tesl" 71 (list (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationJson (raw-value conv1))))))
    (define reloaded (thsl-src! "tests/agent-conversation-tests.tesl" 74 (list (cons 'saved saved) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationFrom (raw-value agent) (raw-value saved))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-conversation-tests.tesl" 75 (list (cons 'reloaded reloaded) (cons 'saved saved) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationLength (raw-value reloaded)))))) 2)
    (define turn2 (thsl-src! "tests/agent-conversation-tests.tesl" 78 (list (cons 'reloaded reloaded) (cons 'saved saved) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (converse (raw-value reloaded) "second question")))))
    (define conv2 (thsl-src! "tests/agent-conversation-tests.tesl" 79 (list (cons 'turn2 turn2) (cons 'reloaded reloaded) (cons 'saved saved) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (turnConversation (raw-value turn2))))))
    (check-equal? (raw-value (thsl-src! "tests/agent-conversation-tests.tesl" 80 (list (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'reloaded reloaded) (cons 'saved saved) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (replyText (raw-value (turnReply (raw-value turn2)))))))) "Reply two")
    (check-equal? (raw-value (thsl-src! "tests/agent-conversation-tests.tesl" 81 (list (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'reloaded reloaded) (cons 'saved saved) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationLength (raw-value conv2)))))) 4)
    (define history2 (thsl-src! "tests/agent-conversation-tests.tesl" 82 (list (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'reloaded reloaded) (cons 'saved saved) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (raw-value (conversationJson (raw-value conv2))))))
    (check-true (raw-value (thsl-src! "tests/agent-conversation-tests.tesl" 83 (list (cons 'history2 history2) (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'reloaded reloaded) (cons 'saved saved) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value history2) "first question")))))
    (check-true (raw-value (thsl-src! "tests/agent-conversation-tests.tesl" 84 (list (cons 'history2 history2) (cons 'conv2 conv2) (cons 'turn2 turn2) (cons 'reloaded reloaded) (cons 'saved saved) (cons 'conv1 conv1) (cons 'turn1 turn1) (cons 'conv0 conv0) (cons 'agent agent)) (lambda () (tesl_import_String_contains (raw-value history2) "Reply one")))))
    )
  )

)
