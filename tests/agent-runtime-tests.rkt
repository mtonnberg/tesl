#lang racket

;;; ============================================================================
;;; Tesl.Agent — Layer-C RUNTIME tests (AI Tier-0).
;;; ============================================================================
;;;
;;; Deterministic, network-free runtime coverage of the agentic core that the
;;; .tesl surface compiles down to.  Three deterministic pillars, all driven by
;;; the mock providers (mockProvider / mockToolProvider), so there is NEVER an
;;; outbound HTTP call:
;;;
;;;   (1) A full mock AGENT LOOP end-to-end: a scripted tool_use turn flows
;;;       through arg VALIDATION → DISPATCH → a normalized tool_result → the
;;;       provider's next turn → final assistant reply.  Both the happy path
;;;       and the validation-failure path (a malformed-arg tool_use becomes an
;;;       is_error tool_result the model recovers from, NOT a raised exception).
;;;
;;;   (2) Conversation PERSISTENCE on a REAL (temporary) PostgreSQL: a multi-turn
;;;       thread's history (serialized by conversationJson, INCLUDING tool turns)
;;;       is stored in the developer's OWN entity, reloaded with conversationFrom,
;;;       and the reloaded thread feeds the NEXT turn.  Ambient TESL_POSTGRES_* is
;;;       unset (this dev shell sets them); skips cleanly when initdb/pg_ctl are
;;;       absent so the suite is green on machines without PostgreSQL tooling.
;;;
;;;   (3) agentRun PUBLISHING step events to a channel collected by a subscriber:
;;;       agentRun calls a developer publisher once per loop step; the publisher
;;;       writes to an async-channel; a subscriber drains it and we ASSERT THE
;;;       EXACT ORDER of events (each tool dispatch, then the final text).
;;;
;;; Capability gating is exercised throughout: every inference entry point is
;;; wrapped in (with-capabilities (aiProvider ...) ...), and a dedicated section
;;; proves that calling WITHOUT aiProvider raises (the Layer-C mirror of V001).

(require racket/async-channel
         json
         db
         rackunit
         "../dsl/capability.rkt"
         "../dsl/check.rkt"
         "../dsl/sql.rkt"
         "../dsl/types.rkt"
         "../tesl/agent.rkt"
         (only-in "../tesl/time.rkt" PosixMillis)
         "private/postgres-test-support.rkt")

;;; ── Shared deterministic fixtures ───────────────────────────────────────────

;; A tool whose validator parses {"city": <string>} and rejects anything else.
;; dispatch echoes a deterministic "weather" string.  Returns a plain string so
;; the loop's ->result-string passes it through verbatim.
(define (weather-tool)
  (tool "get_weather"
        "Look up the weather for a city."
        "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}"
        ;; validator : args-json-string -> validated-value (or raises/check-fail)
        (lambda (args-json)
          (define j (string->jsexpr args-json))
          (define city (hash-ref j 'city (lambda () (error "missing city"))))
          (unless (string? city) (error "city must be a string"))
          city)
        ;; dispatch : validated-value -> result-string
        (lambda (city)
          (format "Weather in ~a: sunny, 21C" city))))

;; A second independent tool, to prove multiple tools dispatch in one turn and
;; results map back by call id.
(define (echo-tool)
  (tool "echo"
        "Echo a message back."
        "{\"type\":\"object\",\"properties\":{\"msg\":{\"type\":\"string\"}}}"
        (lambda (args-json)
          (define j (string->jsexpr args-json))
          (hash-ref j 'msg "(none)"))
        (lambda (msg) (format "echo: ~a" msg))))

;; An agent with both tools bound, driven by an explicit provider.
(define (tool-agent provider)
  (withTools (defineAgent provider "You are a deterministic test bot." 256)
             (list (weather-tool) (echo-tool))))

;;; Convenience: run a thunk WITH the AI capabilities granted.
(define-syntax-rule (with-ai body ...)
  (with-capabilities (aiProvider db-write db-read) body ...))

;;; ════════════════════════════════════════════════════════════════════════════
;;; PILLAR 1 — full mock agent loop end-to-end (tool_use → validated dispatch →
;;;            tool_result → final reply).  No PostgreSQL, no network.
;;; ════════════════════════════════════════════════════════════════════════════

(define mock-loop-tests
  (test-suite
   "mock agent loop end-to-end"

   ;; ── Happy path: one tool round-trip then a final answer. ──────────────────
   (test-case "single tool_use dispatched then final text"
     (define provider
       (mockToolProvider
        (list (toolUseStep "get_weather" "call-1" "{\"city\":\"Paris\"}")
              (textStep "It is sunny in Paris."))))
     (with-ai
       (define reply (askReply (tool-agent provider) "What's the weather in Paris?"))
       (check-equal? (replyText reply) "It is sunny in Paris.")
       ;; Exactly one tool was dispatched across the loop.
       (check-equal? (replyToolCalls reply) 1)
       ;; Two provider round-trips happened, so usage accumulated (2 in + 2 out).
       (check-true (> (replyTokens reply) 0))))

   ;; `ask` (the one-shot compat wrapper) returns just the final text.
   (test-case "ask one-shot returns final text after a tool round-trip"
     (define provider
       (mockToolProvider
        (list (toolUseStep "get_weather" "c1" "{\"city\":\"Berlin\"}")
              (textStep "Berlin: clear skies."))))
     (with-ai
       (check-equal? (ask (tool-agent provider) "weather?") "Berlin: clear skies.")))

   ;; ── Two tools dispatched in ONE assistant turn. ───────────────────────────
   (test-case "two tool_use blocks in one turn → two dispatches"
     (define provider
       (mockToolProvider
        ;; A single llm-response carrying two tool_use blocks is not expressible
        ;; via toolUseStep (one tool per step), so script two sequential rounds.
        (list (toolUseStep "get_weather" "w1" "{\"city\":\"Rome\"}")
              (toolUseStep "echo" "e1" "{\"msg\":\"hi\"}")
              (textStep "done"))))
     (with-ai
       (define reply (askReply (tool-agent provider) "do two things"))
       (check-equal? (replyText reply) "done")
       (check-equal? (replyToolCalls reply) 2)))

   ;; ── Validation FAILURE path: malformed args → is_error tool_result, NOT a
   ;;    raised exception; the model recovers and produces a final reply. ───────
   (test-case "malformed tool args become an is_error tool_result (no raise)"
     (define provider
       (mockToolProvider
        (list (toolUseStep "get_weather" "bad" "{\"city\":123}") ; city not a string
              (textStep "I could not read the city, please retry."))))
     (with-ai
       ;; The loop must NOT raise; it surfaces the error to the model and the
       ;; mock then ends the turn.
       (define reply (askReply (tool-agent provider) "weather of 123"))
       (check-equal? (replyText reply) "I could not read the city, please retry.")
       ;; One tool dispatch attempt counted even though it was rejected.
       (check-equal? (replyToolCalls reply) 1)))

   (test-case "missing required field → is_error tool_result, loop continues"
     (define provider
       (mockToolProvider
        (list (toolUseStep "get_weather" "miss" "{}")
              (textStep "no city given"))))
     (with-ai
       (check-equal? (replyText (askReply (tool-agent provider) "weather"))
                     "no city given")))

   ;; ── Unknown tool name → is_error tool_result (the model asked for a tool
   ;;    that is not registered). ────────────────────────────────────────────
   (test-case "unknown tool name → is_error tool_result, loop continues"
     (define provider
       (mockToolProvider
        (list (toolUseStep "nonexistent" "u1" "{}")
              (textStep "recovered from unknown tool"))))
     (with-ai
       (check-equal? (replyText (askReply (tool-agent provider) "use a missing tool"))
                     "recovered from unknown tool")))

   ;; ── Text-only providers (mockProvider) — no tools at all. ─────────────────
   (test-case "text-only mockProvider returns its single scripted reply"
     (with-ai
       (define agent (defineAgent (mockProvider (list "hello world")) "sys" 64))
       (check-equal? (ask agent "hi") "hello world")))

   (test-case "askReply on a text-only provider reports zero tool calls"
     (with-ai
       (define agent (defineAgent (mockProvider (list "plain")) "sys" 64))
       (define reply (askReply agent "hi"))
       (check-equal? (replyText reply) "plain")
       (check-equal? (replyToolCalls reply) 0)))

   ;; ── BYOK: askWith overrides the provider for this call only. ──────────────
   (test-case "askWith uses the override provider, not the agent's own"
     (with-ai
       (define base (defineAgent (mockProvider (list "agent-own")) "sys" 64))
       (define override (mockProvider (list "byok-reply")))
       (check-equal? (replyText (askWith base "hi" override)) "byok-reply")))

   ;; ── Multi-round tool loop: weather, then echo, then answer. ───────────────
   (test-case "three-round loop accumulates tool count and final text"
     (define provider
       (mockToolProvider
        (list (toolUseStep "get_weather" "a" "{\"city\":\"Oslo\"}")
              (toolUseStep "echo" "b" "{\"msg\":\"second\"}")
              (toolUseStep "get_weather" "c" "{\"city\":\"Lima\"}")
              (textStep "all done"))))
     (with-ai
       (define reply (askReply (tool-agent provider) "go"))
       (check-equal? (replyText reply) "all done")
       (check-equal? (replyToolCalls reply) 3)))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; PILLAR 1b — structured output (askFor) + decodeAs, deterministic.
;;; ════════════════════════════════════════════════════════════════════════════

;; A developer decoder that parses a JSON object {"answer": <int>} and returns
;; the int, raising on anything else (so askFor's retry loop is exercised).
(define (answer-decoder text)
  (define j (string->jsexpr text))
  (define a (hash-ref j 'answer (lambda () (error "no answer field"))))
  (unless (exact-integer? a) (error "answer must be an integer"))
  a)

(define structured-output-tests
  (test-suite
   "structured output (askFor)"

   (test-case "askFor decodes a valid first reply with no retries"
     (with-ai
       (define agent (defineAgent (mockProvider (list "{\"answer\": 42}")) "sys" 64))
       (check-equal? (askFor agent "give a number" answer-decoder 2) 42)))

   (test-case "askFor retries after an undecodable reply then succeeds"
     (with-ai
       ;; First reply is junk, second is valid → succeeds within the retry budget.
       (define agent (defineAgent (mockProvider (list "not json"
                                                      "{\"answer\": 7}"))
                                  "sys" 64))
       (check-equal? (askFor agent "give a number" answer-decoder 2) 7)))

   (test-case "askFor raises when retries are exhausted"
     (with-ai
       (define agent (defineAgent (mockProvider (list "nope" "still nope"))
                                  "sys" 64))
       ;; 1 retry → 2 attempts total, both fail → user-error raised.
       (check-exn exn:fail?
                  (lambda () (askFor agent "give a number" answer-decoder 1)))))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; PILLAR 2 — conversation: in-memory threading + JSON round-trip (no DB), and
;;;            the real-PostgreSQL persistence path (skips if tooling absent).
;;; ════════════════════════════════════════════════════════════════════════════

(define conversation-memory-tests
  (test-suite
   "conversation threading + JSON round-trip (in-memory)"

   (test-case "newConversation starts empty"
     (with-ai
       (define agent (defineAgent (mockProvider (list "x")) "sys" 64))
       (check-equal? (conversationLength (newConversation agent)) 0)))

   (test-case "one turn yields a user+assistant pair (length 2)"
     (with-ai
       (define agent (defineAgent (mockProvider (list "reply one")) "sys" 64))
       (define turn (converse (newConversation agent) "hello"))
       (check-equal? (replyText (turnReply turn)) "reply one")
       (check-equal? (conversationLength (turnConversation turn)) 2)))

   (test-case "second turn sees the first (history accumulates to 4)"
     (with-ai
       (define agent (defineAgent (mockProvider (list "r1" "r2")) "sys" 64))
       (define t1 (converse (newConversation agent) "first"))
       (define t2 (converse (turnConversation t1) "second"))
       (check-equal? (replyText (turnReply t2)) "r2")
       (check-equal? (conversationLength (turnConversation t2)) 4)))

   (test-case "conversationJson carries both prompt and reply text"
     (with-ai
       (define agent (defineAgent (mockProvider (list "the-answer")) "sys" 64))
       (define conv (turnConversation (converse (newConversation agent) "the-question")))
       (define j (conversationJson conv))
       (check-true (string-contains? j "the-question"))
       (check-true (string-contains? j "the-answer"))))

   (test-case "conversationFrom round-trips history exactly (length preserved)"
     (with-ai
       (define agent (defineAgent (mockProvider (list "a" "b")) "sys" 64))
       (define conv (turnConversation (converse (newConversation agent) "q1")))
       (define reloaded (conversationFrom agent (conversationJson conv)))
       (check-equal? (conversationLength reloaded) (conversationLength conv))
       ;; The reloaded thread continues: turn 2 sees turn 1.
       (define t2 (converse reloaded "q2"))
       (check-equal? (conversationLength (turnConversation t2)) 4)))

   (test-case "conversationFrom on a tool-using transcript preserves tool turns"
     (with-ai
       ;; Round-trip a transcript that INCLUDES tool_use/tool_result turns.
       (define provider
         (mockToolProvider
          (list (toolUseStep "get_weather" "k1" "{\"city\":\"Quito\"}")
                (textStep "Quito weather reported."))))
       (define conv (turnConversation (converse (newConversation (tool-agent provider))
                                                "weather in Quito")))
       (define j (conversationJson conv))
       ;; The tool name and the tool_result content survive serialization.
       (check-true (string-contains? j "get_weather"))
       (define reloaded (conversationFrom (tool-agent provider) j))
       (check-equal? (conversationLength reloaded) (conversationLength conv))))

   (test-case "conversationFrom rejects malformed JSON"
     (with-ai
       (define agent (defineAgent (mockProvider (list "x")) "sys" 64))
       (check-exn exn:fail?
                  (lambda () (conversationFrom agent "{not json")))))

   ;; #23: converseStreaming forwards per-token text deltas AS the reply is
   ;; generated (the mock provider synthesizes deltas), while the final whole-
   ;; reply step still fires for backward compatibility.
   (test-case "converseStreaming emits token deltas that reassemble the reply (#23)"
     (with-ai
       (define agent (defineAgent (mockProvider (list "Hello streaming world")) "sys" 64))
       (define events (box '()))
       (define turn (converseStreaming (newConversation agent) "hi"
                                       (lambda (e) (set-box! events (cons e (unbox events))))))
       (define evs (reverse (unbox events)))
       (define deltas (filter (lambda (e) (string-prefix? e "text-delta: ")) evs))
       (check-true (> (length deltas) 1) "more than one incremental token delta")
       (define joined
         (apply string-append
                (map (lambda (e) (substring e (string-length "text-delta: "))) deltas)))
       (check-equal? joined "Hello streaming world" "deltas reassemble the full reply")
       (check-not-false (member "text: Hello streaming world" evs)
                        "final whole-reply step still emitted")
       (check-equal? (replyText (turnReply turn)) "Hello streaming world")))

   ;; #23: TOOL USE is streamed to the consumer too — a "tool: <name>" event tells
   ;; the UI which tool is being used, BEFORE the streamed final answer.
   (test-case "converseStreaming streams tool-use events then the answer's deltas (#23)"
     (with-ai
       (define provider
         (mockToolProvider
          (list (toolUseStep "get_weather" "k1" "{\"city\":\"Oslo\"}")
                (textStep "Oslo is cold today."))))
       (define events (box '()))
       (define turn (converseStreaming (newConversation (tool-agent provider)) "weather in Oslo?"
                                       (lambda (e) (set-box! events (cons e (unbox events))))))
       (define evs (reverse (unbox events)))
       ;; the tool-use is visible in the stream, and names WHICH tool
       (check-not-false (member "tool: get_weather" evs) "tool-use event streamed")
       ;; the final answer streams incrementally
       (define deltas (filter (lambda (e) (string-prefix? e "text-delta: ")) evs))
       (check-true (> (length deltas) 1) "answer streamed as token deltas")
       ;; ordering: the tool event precedes the answer's text deltas
       (define tool-idx (index-of evs "tool: get_weather"))
       (define first-delta-idx
         (for/first ([e (in-list evs)] [i (in-naturals)]
                     #:when (string-prefix? e "text-delta: ")) i))
       (check-true (< tool-idx first-delta-idx) "tool event precedes the streamed answer")
       (check-equal? (replyText (turnReply turn)) "Oslo is cold today.")))))

;;; The developer's OWN entity for persisting a conversation thread (Pillar 2 DB).
(define-entity ConversationRow
  #:table conversation_rows
  #:primary-key id
  [Id id : String]
  [History history : String])

;; Runs against a fresh temp database `cfg`.  Builds a developer-owned DB, opens
;; it, and exercises store→reload→continue across the persistence boundary.
(define (run-conversation-persistence-tests cfg)
  (define host (hash-ref cfg 'host))
  (define port (hash-ref cfg 'port))
  (define db-name (hash-ref cfg 'database))
  (define user (hash-ref cfg 'user))

  (define-database ConvDb
    #:backend postgres
    #:database db-name
    #:user user
    #:server host
    #:port port
    #:schema agent_runtime_conv_test
    #:entities ConversationRow)

  (define agent
    (defineAgent (mockProvider (list "Reply about turn one"
                                     "Reply about turn two"
                                     "Reply about turn three"))
                 "You are a persistence-test bot."
                 128))

  (call-with-database
   ConvDb
   (lambda ()
     (with-ai

       ;; ── Turn 1: converse, then PERSIST the serialized history. ────────────
       (define turn1 (converse (newConversation agent) "first user question"))
       (define conv1 (turnConversation turn1))
       (check-equal? (replyText (turnReply turn1)) "Reply about turn one")
       (check-equal? (conversationLength conv1) 2)

       (insert-one! ConversationRow
                    (hash 'id "conv-1" 'history (conversationJson conv1)))

       ;; ── Reload from PG (a fresh process would do exactly this). ───────────
       (define row
         (select-one (from ConversationRow)
                     (where (==. (ConversationRow-id) "conv-1"))))
       (check-true (named-value? row))
       (define stored-history (hash-ref (raw-value row) 'history))
       (check-true (string-contains? stored-history "first user question"))
       (check-true (string-contains? stored-history "Reply about turn one"))

       ;; ── Continue the RELOADED thread — turn 2 must still see turn 1. ──────
       (define reloaded (conversationFrom agent stored-history))
       (check-equal? (conversationLength reloaded) 2)

       (define turn2 (converse reloaded "second user question"))
       (define conv2 (turnConversation turn2))
       (check-equal? (replyText (turnReply turn2)) "Reply about turn two")
       (check-equal? (conversationLength conv2) 4)

       ;; ── A SECOND round-trip: persist turn 2's state, reload, continue. ────
       (insert-one! ConversationRow
                    (hash 'id "conv-2" 'history (conversationJson conv2)))
       (define row2
         (select-one (from ConversationRow)
                     (where (==. (ConversationRow-id) "conv-2"))))
       (define stored2 (hash-ref (raw-value row2) 'history))
       (define reloaded2 (conversationFrom agent stored2))
       (check-equal? (conversationLength reloaded2) 4)

       (define turn3 (converse reloaded2 "third user question"))
       (define conv3 (turnConversation turn3))
       (check-equal? (replyText (turnReply turn3)) "Reply about turn three")
       (check-equal? (conversationLength conv3) 6)

       ;; The final transcript carries ALL THREE turns' content — proving the
       ;; reloaded history threaded forward across both store/reload boundaries.
       (define final-history (conversationJson conv3))
       (check-true (string-contains? final-history "first user question"))
       (check-true (string-contains? final-history "second user question"))
       (check-true (string-contains? final-history "third user question"))
       (check-true (string-contains? final-history "Reply about turn one"))
       (check-true (string-contains? final-history "Reply about turn three"))))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; PILLAR 2b — tool-transcript persistence on a REAL temp PostgreSQL.
;;; ════════════════════════════════════════════════════════════════════════════

(define-entity ToolConvRow
  #:table tool_conv_rows
  #:primary-key id
  [Id id : String]
  [History history : String])

(define (run-tool-transcript-persistence-tests cfg)
  (define-database ToolConvDb
    #:backend postgres
    #:database (hash-ref cfg 'database)
    #:user (hash-ref cfg 'user)
    #:server (hash-ref cfg 'host)
    #:port (hash-ref cfg 'port)
    #:schema agent_runtime_tool_test
    #:entities ToolConvRow)

  (define provider
    (mockToolProvider
     (list (toolUseStep "get_weather" "t1" "{\"city\":\"Cairo\"}")
           (textStep "Cairo: hot and dry.")
           (textStep "Following up on Cairo."))))
  (define agent (tool-agent provider))

  (call-with-database
   ToolConvDb
   (lambda ()
     (with-ai
       ;; Turn 1 drives a tool round-trip; the transcript now holds tool turns.
       (define t1 (converse (newConversation agent) "weather in Cairo"))
       (define c1 (turnConversation t1))
       (check-equal? (replyText (turnReply t1)) "Cairo: hot and dry.")
       ;; user + assistant(tool_use) + tool(result) + assistant(text) = 4.
       (check-equal? (conversationLength c1) 4)

       (insert-one! ToolConvRow
                    (hash 'id "tc-1" 'history (conversationJson c1)))
       (define row
         (select-one (from ToolConvRow)
                     (where (==. (ToolConvRow-id) "tc-1"))))
       (define stored (hash-ref (raw-value row) 'history))
       ;; The persisted history includes the tool name and tool_result content.
       (check-true (string-contains? stored "get_weather"))
       (check-true (string-contains? stored "Weather in Cairo"))

       ;; Reload and continue — turn 2 sees the full tool transcript.
       (define reloaded (conversationFrom agent stored))
       (check-equal? (conversationLength reloaded) 4)
       (define t2 (converse reloaded "anything else?"))
       (check-equal? (replyText (turnReply t2)) "Following up on Cairo.")
       (check-equal? (conversationLength (turnConversation t2)) 6)))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; PILLAR 3 — agentRun publishes step events to a channel; a subscriber drains
;;;            it and we assert the EXACT order.
;;; ════════════════════════════════════════════════════════════════════════════

;; Drain an async-channel into a list (non-blocking, until empty).
(define (drain-channel ch)
  (let loop ([acc '()])
    (define v (async-channel-try-get ch))
    (if v (loop (cons v acc)) (reverse acc))))

(define agentrun-publish-tests
  (test-suite
   "agentRun publishes step events to a channel (order asserted)"

   ;; ── Text-only run: a single "text: ..." event. ────────────────────────────
   (test-case "text-only agentRun publishes exactly the final text event"
     (with-ai
       (define ch (make-async-channel))
       (define agent (defineAgent (mockProvider (list "final answer")) "sys" 64))
       (define reply (agentRun agent "go" (lambda (s) (async-channel-put ch s))))
       (check-equal? (replyText reply) "final answer")
       (check-equal? (drain-channel ch) (list "text: final answer"))))

   ;; ── One tool round-trip: a "tool: ..." event PRECEDES the "text: ..." one. ─
   (test-case "tool run publishes tool event then final text event, in order"
     (with-ai
       (define ch (make-async-channel))
       (define provider
         (mockToolProvider
          (list (toolUseStep "get_weather" "r1" "{\"city\":\"Tokyo\"}")
                (textStep "Tokyo: rainy."))))
       (define reply (agentRun (tool-agent provider) "weather Tokyo"
                               (lambda (s) (async-channel-put ch s))))
       (check-equal? (replyText reply) "Tokyo: rainy.")
       ;; EXACT order: the tool dispatch event, then the final text event.
       (check-equal? (drain-channel ch)
                     (list "tool: get_weather" "text: Tokyo: rainy."))))

   ;; ── Multi-round: every tool event in order, final text last. ──────────────
   (test-case "multi-round agentRun publishes all tool events then final text"
     (with-ai
       (define ch (make-async-channel))
       (define provider
         (mockToolProvider
          (list (toolUseStep "get_weather" "a" "{\"city\":\"A\"}")
                (toolUseStep "echo" "b" "{\"msg\":\"m\"}")
                (toolUseStep "get_weather" "c" "{\"city\":\"C\"}")
                (textStep "complete"))))
       (define reply (agentRun (tool-agent provider) "go"
                               (lambda (s) (async-channel-put ch s))))
       (check-equal? (replyText reply) "complete")
       (check-equal? (drain-channel ch)
                     (list "tool: get_weather"
                           "tool: echo"
                           "tool: get_weather"
                           "text: complete"))))

   ;; ── A subscriber on a SEPARATE thread collects events as they arrive. ──────
   (test-case "a subscriber thread collects events live and sees them ordered"
     (with-ai
       (define ch (make-async-channel))
       (define collected '())
       (define done (make-semaphore 0))
       ;; Subscriber: block-read until it sees the terminating "text: ..." event.
       (define subscriber
         (thread
          (lambda ()
            (let loop ()
              (define ev (async-channel-get ch))
              (set! collected (cons ev collected))
              (if (string-prefix? ev "text: ")
                  (semaphore-post done)
                  (loop))))))
       (define provider
         (mockToolProvider
          (list (toolUseStep "echo" "e1" "{\"msg\":\"x\"}")
                (textStep "ok"))))
       (agentRun (tool-agent provider) "go" (lambda (s) (async-channel-put ch s)))
       (semaphore-wait done)
       (kill-thread subscriber)
       (check-equal? (reverse collected) (list "tool: echo" "text: ok"))))

   ;; ── The publisher's return value never affects the loop. ──────────────────
   (test-case "agentRun returns the AgentReply regardless of publisher result"
     (with-ai
       (define provider (mockProvider (list "reply")))
       (define agent (defineAgent provider "sys" 64))
       ;; Publisher returns a non-Unit value; loop must still complete.
       (define reply (agentRun agent "go" (lambda (s) 'ignored)))
       (check-equal? (replyText reply) "reply")))

   ;; ── The validation-failure path still publishes the tool step event. ──────
   (test-case "a rejected tool still publishes its tool event before final text"
     (with-ai
       (define ch (make-async-channel))
       (define provider
         (mockToolProvider
          (list (toolUseStep "get_weather" "bad" "{\"city\":999}")
                (textStep "could not look that up"))))
       (define reply (agentRun (tool-agent provider) "bad input"
                               (lambda (s) (async-channel-put ch s))))
       (check-equal? (replyText reply) "could not look that up")
       (check-equal? (drain-channel ch)
                     (list "tool: get_weather" "text: could not look that up"))))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; PILLAR 4 — capability gating (Layer-C mirror of compile-time V001): every
;;;            inference entry point requires aiProvider at runtime.
;;; ════════════════════════════════════════════════════════════════════════════

(define capability-gating-tests
  (test-suite
   "capability gating — inference requires aiProvider"

   ;; Constructing agents/tools/providers requires NO capability.
   (test-case "defineAgent/withTools/mockProvider need no capabilities"
     (define agent (tool-agent (mockProvider (list "x"))))
     (check-true (Agent agent)))

   (test-case "ask without aiProvider raises a capability error"
     (define agent (defineAgent (mockProvider (list "x")) "sys" 64))
     (check-exn exn:fail? (lambda () (ask agent "hi"))))

   (test-case "askReply without aiProvider raises"
     (define agent (defineAgent (mockProvider (list "x")) "sys" 64))
     (check-exn exn:fail? (lambda () (askReply agent "hi"))))

   (test-case "askWith without aiProvider raises"
     (define agent (defineAgent (mockProvider (list "x")) "sys" 64))
     (check-exn exn:fail? (lambda () (askWith agent "hi" (mockProvider (list "y"))))))

   (test-case "askFor without aiProvider raises"
     (define agent (defineAgent (mockProvider (list "{\"answer\":1}")) "sys" 64))
     (check-exn exn:fail? (lambda () (askFor agent "hi" answer-decoder 0))))

   (test-case "converse without aiProvider raises"
     (define agent (defineAgent (mockProvider (list "x")) "sys" 64))
     (check-exn exn:fail? (lambda () (converse (newConversation agent) "hi"))))

   (test-case "agentRun without aiProvider raises"
     (define agent (defineAgent (mockProvider (list "x")) "sys" 64))
     (check-exn exn:fail? (lambda () (agentRun agent "hi" (lambda (s) (void))))))

   ;; A capability set that LACKS aiProvider (db-write only) still rejects.
   (test-case "inference under db-write-only (no aiProvider) raises"
     (define agent (defineAgent (mockProvider (list "x")) "sys" 64))
     (check-exn exn:fail?
                (lambda ()
                  (with-capabilities (db-write) (ask agent "hi")))))

   ;; Granting aiProvider alone is sufficient for inference (it implies httpClient).
   (test-case "aiProvider alone is sufficient for ask"
     (define agent (defineAgent (mockProvider (list "ok")) "sys" 64))
     (check-equal? (with-capabilities (aiProvider) (ask agent "hi")) "ok"))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; PILLAR 5 — mock provider discipline + decodeAs registry path.
;;; ════════════════════════════════════════════════════════════════════════════

(define mock-discipline-tests
  (test-suite
   "mock provider discipline"

   ;; The mock raises if MORE provider round-trips happen than were scripted —
   ;; this catches a test-authoring bug (e.g. a tool loop that never terminates).
   (test-case "exhausting a mock provider raises (too few scripted replies)"
     (with-ai
       ;; A tool_use with NO terminating text step → loop asks again → exhausted.
       (define provider
         (mockToolProvider
          (list (toolUseStep "echo" "e1" "{\"msg\":\"x\"}"))))
       (check-exn exn:fail?
                  (lambda () (askReply (tool-agent provider) "go")))))

   (test-case "a fresh mock provider replays its FULL script independently"
     (with-ai
       ;; Two separate agents from two separate providers do not share state.
       (define a1 (defineAgent (mockProvider (list "one")) "sys" 64))
       (define a2 (defineAgent (mockProvider (list "two")) "sys" 64))
       (check-equal? (ask a1 "x") "one")
       (check-equal? (ask a2 "x") "two")))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; PILLAR 6 — issue #30: tool DISPATCH failure containment + capability
;;;            delegation.  A live agent turn runs under the caller's ambient
;;;            capability set, which need not include a wired tool fn's own
;;;            `requires` — before the fix, the fn's capability assertion (or
;;;            ANY raise in a dispatch body) killed the whole agent loop
;;;            instead of becoming an is_error tool_result the model can see
;;;            (the containment `serverTools` endpoint dispatch always had).
;;;            The emitter now also wraps every `asTool fn` dispatch in
;;;            (with-capabilities (<fn's requires>) …), delegating the
;;;            statically-charged construction-site authority to execution.
;;; ════════════════════════════════════════════════════════════════════════════

;; The capability a tool fn would declare via `requires [...]`.
(define-capability issue30-cap)

;; A provider that CAPTURES each request's messages so a test can inspect the
;; tool_result blocks the loop sent back to the model.
(define (capturing-provider steps captured-box)
  (define n 0)
  (lambda (request)
    (set-box! captured-box
              (append (unbox captured-box) (list (hash-ref request 'messages))))
    (begin0 (list-ref steps n) (set! n (add1 n)))))

;; dispatch raises a plain runtime error.
(define (boom-tool)
  (tool "boom" "always raises" "{\"type\":\"object\"}"
        (lambda (args-json) 'ok)
        (lambda (_) (error 'boom "kapow"))))

;; dispatch asserts a capability — the shape of a compiled `fn … requires [c]`
;; body — WITHOUT any delegation wrapper (the pre-fix emitted form).
(define (cap-asserting-tool)
  (tool "needs_cap" "asserts issue30-cap" "{\"type\":\"object\"}"
        (lambda (args-json) 'ok)
        (lambda (_)
          (call-with-declared-capabilities (list issue30-cap)
                                           (lambda () "held")))))

;; dispatch delegates the fn's declared capability exactly like the emitter's
;; post-fix `asTool` lowering: (with-capabilities (c) (apply fn _decoded)).
(define (delegating-tool)
  (tool "delegated" "grants issue30-cap around the assertion" "{\"type\":\"object\"}"
        (lambda (args-json) 'ok)
        (lambda (_)
          (with-capabilities (issue30-cap)
            (call-with-declared-capabilities (list issue30-cap)
                                             (lambda () "delegated-ok"))))))

(define (issue30-agent t provider)
  (withTools (defineAgent provider "sys" 64) (list t)))

;; The tool message of the SECOND provider request carries the tool_result the
;; loop produced for the first request's tool_use.
(define (second-request-tool-results captured-box)
  (define msgs (cadr (unbox captured-box)))
  (hash-ref (last msgs) 'content))

(define tool-dispatch-containment-tests
  (test-suite
   "issue #30 — dispatch containment + capability delegation"

   (test-case "a RAISING dispatch becomes an is_error tool_result; loop survives"
     (define captured (box '()))
     (define provider
       (capturing-provider
        (list (toolUseStep "boom" "c1" "{}") (textStep "survived"))
        captured))
     (with-capabilities (aiProvider)
       (define reply (askReply (issue30-agent (boom-tool) provider) "go"))
       (check-equal? (replyText reply) "survived")
       (check-equal? (replyToolCalls reply) 1))
     (define results (second-request-tool-results captured))
     (check-equal? (length results) 1)
     (check-true (hash-ref (car results) 'is-error))
     (check-regexp-match #rx"tool failed: .*kapow"
                         (hash-ref (car results) 'content)))

   ;; The exact live failure of issue #30: the tool fn's capability assertion
   ;; trips because the loop's ambient set lacks it.  Must be CONTAINED, not a
   ;; loop-killing raise.
   (test-case "a capability trap in dispatch is contained as is_error"
     (define captured (box '()))
     (define provider
       (capturing-provider
        (list (toolUseStep "needs_cap" "c1" "{}") (textStep "recovered"))
        captured))
     (with-capabilities (aiProvider)   ; ambient LACKS issue30-cap
       (define reply (askReply (issue30-agent (cap-asserting-tool) provider) "go"))
       (check-equal? (replyText reply) "recovered"))
     (define results (second-request-tool-results captured))
     (check-true (hash-ref (car results) 'is-error))
     (check-regexp-match #rx"Missing capabilities.*issue30-cap"
                         (hash-ref (car results) 'content)))

   ;; The runtime registry seam: a define/pow-family fn REGISTERS its declared
   ;; capability values on the procedure; the `tool` constructor delegates them
   ;; around the deferred call.  So a registered fn used as a manual `tool`
   ;; dispatch succeeds with no ambient grant — same guarantee as the emitted
   ;; asTool wrapper, for fns passed by reference.
   (test-case "a registered dispatch fn is delegated its declared caps by `tool`"
     (define (needs-cap-fn _)
       (call-with-declared-capabilities (list issue30-cap) (lambda () "held")))
     (register-procedure-capabilities! needs-cap-fn (list issue30-cap))
     (define captured (box '()))
     (define provider
       (capturing-provider
        (list (toolUseStep "registered" "c1" "{}") (textStep "fin"))
        captured))
     (define t (tool "registered" "registered fn" "{\"type\":\"object\"}"
                     (lambda (args-json) 'ok)
                     needs-cap-fn))
     (with-capabilities (aiProvider)   ; ambient LACKS issue30-cap
       (define reply (askReply (issue30-agent t provider) "go"))
       (check-equal? (replyText reply) "fin"))
     (define results (second-request-tool-results captured))
     (check-false (hash-ref (car results) 'is-error))
     (check-equal? (hash-ref (car results) 'content) "held"))

   ;; The post-fix emitted `asTool` dispatch shape: delegation makes the SAME
   ;; call succeed with no ambient grant — live turns behave like `tesl test`.
   (test-case "the delegating (emitted asTool) dispatch succeeds without ambient cap"
     (define captured (box '()))
     (define provider
       (capturing-provider
        (list (toolUseStep "delegated" "c1" "{}") (textStep "done"))
        captured))
     (with-capabilities (aiProvider)   ; ambient still LACKS issue30-cap
       (define reply (askReply (issue30-agent (delegating-tool) provider) "go"))
       (check-equal? (replyText reply) "done")
       (check-equal? (replyToolCalls reply) 1))
     (define results (second-request-tool-results captured))
     (check-false (hash-ref (car results) 'is-error))
     (check-equal? (hash-ref (car results) 'content) "delegated-ok"))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; PILLAR 7 — agent-facing PosixMillis enrichment (date-confusion class).
;;;            A bare epoch-millis integer in a tool result makes the model
;;;            hallucinate calendar dates.  At the agent boundary ONLY, a
;;;            PosixMillis renders as {epochMillis, iso}; the HTTP wire format
;;;            is untouched (parameter default #f).
;;; ════════════════════════════════════════════════════════════════════════════

;; A non-PosixMillis newtype control: enrichment must not touch it.
(define-newtype Pillar7Id String)

(define posix-enrichment-tests
  (test-suite
   "agent-facing PosixMillis enrichment"

   (test-case "HTTP default: PosixMillis encodes as the bare integer"
     (check-equal? (runtime-value->jsexpr (PosixMillis 1783804288000))
                   1783804288000))

   (test-case "agent boundary: PosixMillis encodes as {epochMillis, iso} (UTC)"
     (parameterize ([current-agent-posix-enrichment? #t])
       (check-equal? (runtime-value->jsexpr (PosixMillis 1783804288000))
                     (hash 'epochMillis 1783804288000
                           'iso "2026-07-11T21:11:28Z"))))

   (test-case "enrichment reaches nested values (list elements)"
     (parameterize ([current-agent-posix-enrichment? #t])
       (check-equal? (runtime-value->jsexpr (list (PosixMillis 0)))
                     (list (hash 'epochMillis 0 'iso "1970-01-01T00:00:00Z")))))

   (test-case "other newtypes still unwrap to their base value"
     (parameterize ([current-agent-posix-enrichment? #t])
       ;; PosixMillis is the ONLY enriched newtype; anything else unwraps.
       (check-equal? (runtime-value->jsexpr (Pillar7Id "abc")) "abc")))

   ;; asTool result path: a tool fn returning PosixMillis reaches the model as
   ;; the enriched JSON object string, not the struct's opaque print form.
   (test-case "tool dispatch returning PosixMillis yields enriched tool_result"
     (define captured (box '()))
     (define provider
       (capturing-provider
        (list (toolUseStep "now" "c1" "{}") (textStep "done"))
        captured))
     (define t (tool "now" "current time" "{\"type\":\"object\"}"
                     (lambda (args-json) 'ok)
                     (lambda (_) (PosixMillis 1783804288000))))
     (with-capabilities (aiProvider)
       (define reply (askReply (issue30-agent t provider) "when"))
       (check-equal? (replyText reply) "done"))
     (define results (second-request-tool-results captured))
     (check-false (hash-ref (car results) 'is-error))
     (check-equal? (string->jsexpr (hash-ref (car results) 'content))
                   (hasheq 'epochMillis 1783804288000
                           'iso "2026-07-11T21:11:28Z")))))

;;; ── Run order: pure-runtime suites first, then the DB-gated pillars. ─────────

(define (run-all)
  (run-tests mock-loop-tests)
  (run-tests structured-output-tests)
  (run-tests conversation-memory-tests)
  (run-tests agentrun-publish-tests)
  (run-tests capability-gating-tests)
  (run-tests mock-discipline-tests)
  (run-tests tool-dispatch-containment-tests)
  (run-tests posix-enrichment-tests)

  ;; DB-gated pillars: skip cleanly when PostgreSQL tooling is unavailable.
  (cond
    [(not (postgres-tooling-available?))
     (displayln "Skipping agent-runtime-tests.rkt PostgreSQL pillars because initdb/pg_ctl are not available")]
    [else
     (call-with-temporary-postgres run-conversation-persistence-tests)
     (call-with-temporary-postgres run-tool-transcript-persistence-tests)]))

(require rackunit/text-ui)
(run-all)
