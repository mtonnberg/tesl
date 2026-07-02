#lang racket

;;; Tesl.Agent — AI agent capability and inference (Tier-0, Wave 2a: agentic core).
;;;
;;; Builds on the foundation slice (mock provider + one-shot `ask`).  Wave 2a
;;; adds the AGENTIC CORE — real providers, a tool-calling loop, function-first
;;; typed structured output with bounded retry, and BYOK — while staying within
;;; the registration recipe (no parser/AST/emitter-shape changes).
;;;
;;; Wave 2b COMPLETES the core: multi-turn conversation, agentRun (a
;;; worker-backed long loop that publishes step events to a channel), and
;;; streaming — all COMPOSING existing primitives (the agentic loop, the
;;; entity/database the developer owns, and the channel/sse/subscribe path).
;;;
;;; ── Wave 2b surface (all function-first; no new grammar) ─────────────────────
;;;
;;;   Multi-turn conversation (the developer owns persistence):
;;;     Conversation, ConversationTurn   (opaque)
;;;     newConversation  : Agent -> Conversation        -- empty history
;;;     conversationFrom : Agent -> String -> Conversation
;;;                          -- restore from a JSON history string the developer
;;;                             previously persisted (via their OWN entity).
;;;     converse         : Conversation -> String -> ConversationTurn
;;;                          -- append the user turn, run the loop with ALL prior
;;;                             history threaded in, return reply + new conversation.
;;;     turnReply        : ConversationTurn -> AgentReply
;;;     turnConversation : ConversationTurn -> Conversation   -- carries history fwd
;;;     conversationJson : Conversation -> String  -- serialize history to persist
;;;     conversationLength : Conversation -> Int    -- message count (for asserts)
;;;
;;;   agentRun (worker-backed long loop + streaming via a publish callback):
;;;     agentRun : Agent -> String -> (String -> Unit) -> AgentReply
;;;                  -- run the (possibly multi-tool) loop to completion; for each
;;;                     step (a tool dispatch, then the final assistant text) call
;;;                     the publisher with a step-event String.  The developer's
;;;                     publisher closes over a `publish MyChannel(key) ...` so the
;;;                     SAME channel/sse/subscribe path streams the events.  DB is
;;;                     still acquired per tool-exec (never across a provider call).
;;;
;;; ── Surface (all function-first; Tesl forbids bare record literals) ──────────
;;;
;;;   Capability:  aiProvider  (implies httpClient — real providers do HTTP)
;;;   Types:       Agent, LlmProvider, AgentReply, Tool   (opaque)
;;;
;;;   Providers (LlmProvider constructors):
;;;     mockProvider     : List String -> LlmProvider
;;;     mockToolProvider : List ToolStep -> LlmProvider   (script tool-calls)
;;;     anthropic        : String -> String -> LlmProvider          (apiKey, model)
;;;     openai           : String -> String -> LlmProvider          (apiKey, model)
;;;     local            : String -> String -> LlmProvider          (endpoint, model)
;;;
;;;   Mock tool-call scripting helpers (build the script entries for
;;;   mockToolProvider — each is one provider round-trip):
;;;     toolUseStep   : String -> String -> String -> ToolStep
;;;                       (toolName, callId, argsJson)  → a tool_use turn
;;;     textStep      : String -> ToolStep             → a final text turn
;;;
;;;   Agent:
;;;     defineAgent : LlmProvider -> String -> Int -> Agent   (provider, system, maxTok)
;;;     withTools   : Agent -> List Tool -> Agent
;;;
;;;   Tool registration (positional — no records; `a` is the tool's validated
;;;   argument type, hidden inside the Tool value):
;;;     tool : String                 -- name
;;;         -> String                 -- description
;;;         -> String                 -- JSON-schema (a JSON string)
;;;         -> (String -> a)          -- VALIDATOR: model's args JSON -> typed value.
;;;                                      A malformed arg makes the validator raise
;;;                                      (or return a check-fail); the loop turns
;;;                                      that into a tool_result is_error and keeps
;;;                                      going — it is NOT an exception to the caller.
;;;         -> (a -> String)          -- DISPATCH: typed value -> tool_result text.
;;;                                      Dispatched with a DB connection acquired
;;;                                      per tool-exec, never held across a provider
;;;                                      call.
;;;         -> Tool
;;;
;;;   Inference:
;;;     ask         : Agent -> String -> String        -- one-shot text (compat)
;;;     askReply    : Agent -> String -> AgentReply     -- full tool-calling loop
;;;     askWith     : Agent -> String -> LlmProvider -> AgentReply  -- BYOK override
;;;     replyText      : AgentReply -> String
;;;     replyTokens    : AgentReply -> Int              -- input+output tokens
;;;     replyToolCalls : AgentReply -> Int              -- how many tools fired
;;;
;;;   Function-first typed structured output:
;;;     decodeAs : String -> String -> a   -- (typeName, json) -> proof-carrying
;;;                                           value via the SAME codec registry an
;;;                                           HTTP body decode uses.  Raises on
;;;                                           decode failure (so askFor can retry).
;;;     askFor   : Agent -> String -> (String -> a) -> Int -> a
;;;                  -- ask for a typed value.  `decoder` is the developer's
;;;                     String->a function (typically `fn(j: String) -> decodeAs "T" j`).
;;;                     On decode failure the error is appended to the next prompt
;;;                     and the model is re-asked, up to `maxRetries` extra times;
;;;                     exhausting retries fails like an HTTP body validation failure.
;;;
;;; Runtime value representations (opaque to Tesl surface):
;;;   LlmProvider — a Racket procedure (request-hash -> llm-response)
;;;   Agent       — an `agent` struct
;;;   AgentReply  — an `agent-reply` struct
;;;   Tool        — a `tool-spec` struct

(require (only-in "../dsl/capability.rkt" define-capability require-capabilities!)
         (only-in "../dsl/private/evidence.rkt" raw-value)
         (only-in "../dsl/types.rkt" tesl-type-codec-decode register-runtime-type/runtime!)
         (only-in "../dsl/check.rkt" check-fail? check-fail-message)
         json
         "agent-provider.rkt")

(provide aiProvider
         Agent
         LlmProvider
         AgentReply
         AgentReply?
         Tool
         ToolStep
         mockProvider
         mockToolProvider
         toolUseStep
         textStep
         anthropic
         openai
         mistral
         local
         defineAgent
         withTools
         tool
         ask
         askReply
         askWith
         replyText
         replyTokens
         replyToolCalls
         decodeAs
         askFor
         ;; Declarative `agent { tools: [fn...] }` lowering helper
         tesl-agent-decode-args
         ;; Wave 2b — conversation
         Conversation
         Conversation?
         ConversationTurn
         ConversationTurn?
         newConversation
         conversationFrom
         converse
         converseStreaming
         turnReply
         turnConversation
         conversationJson
         conversationLength
         ;; Wave 2b — worker-backed run + streaming
         agentRun)

;;; The aiProvider capability — required by all inference functions.  It IMPLIES
;;; httpClient because real providers perform outbound HTTP; granting aiProvider
;;; therefore also grants the network capability it builds on.
(require (only-in "http-client.rkt" httpClient))
(define-capability aiProvider (implies httpClient))

;;; ── Value types ─────────────────────────────────────────────────────────────

;;; An Agent spec.  `provider` is an LlmProvider procedure; `system` is the
;;; system prompt; `max-tokens` an Int; `tools` a list of tool-spec; `db` the
;;; optional database handle used to acquire a connection per tool-exec.
(struct agent (provider system max-tokens tools db) #:transparent)

;;; A registered tool.  `validator` maps the model's args JSON string to a typed
;;; value (or raises / returns check-fail on malformed args).  `dispatch` maps
;;; that validated value to the tool_result text.
(struct tool-spec (name description schema validator dispatch) #:transparent)

;;; A normalized agent reply surfaced as `AgentReply`.
;;;   text       : String   — final assistant text
;;;   usage      : hash      — summed token accounting across the loop
;;;   tool-calls : Int       — number of tools dispatched during the loop
(struct agent-reply (text usage tool-calls) #:transparent)

;;; A multi-turn conversation: an agent bound to the accumulated message
;;; transcript (user/assistant/tool turns, normalized exactly like run-loop's
;;; `messages`).  Persistence is the DEVELOPER's job — `conversationJson` /
;;; `conversationFrom` round-trip the history through a String they store in
;;; their own entity; the agent runtime is NOT coupled to any user schema.
(struct conversation (agent messages) #:transparent)

;;; One turn's outcome: the reply plus the conversation advanced by this turn
;;; (so the developer threads it into the next `converse`).
(struct conv-turn (reply conversation) #:transparent)

;;; Opaque type-name bindings (only need to be bound identifiers for `(only-in
;;; ...)` to resolve).
(define LlmProvider procedure?)
(define Agent agent?)
(define AgentReply agent-reply?)
(define AgentReply? agent-reply?)
(define Tool tool-spec?)
(define Conversation conversation?)
(define Conversation? conversation?)
(define ConversationTurn conv-turn?)
(define ConversationTurn? conv-turn?)
;; ToolStep is the opaque type of a mock provider script entry (a tool_use or a
;; text turn).  At runtime these ARE normalized llm-response values; the type
;; only needs to be a bound identifier so the emitted (only-in ...) resolves.
(define ToolStep llm-response?)

;; S13-full: these opaque library types carry a hand-written Racket predicate
;; (the `TypeName?` binding above) but were never registered in the runtime
;; type registry.  Before S13-full's fail-closed flip that was invisible: a
;; type-ref with no registered predicate failed OPEN, so a `-> Conversation`
;; handler return was accepted by default.  With fail-closed live, an
;; UNREGISTERED concrete type-ref is rejected — so we must register each opaque
;; type's predicate here, exactly as `define-record`/`define-adt` do for their
;; types, so the runtime boundary check FINDS the predicate and accepts a
;; genuine value (and still rejects a mismatched one).  Registering under the
;; bare symbol is sufficient: `runtime-type-predicate` resolves a boundary
;; type-ref to its bare NAME before the registry lookup.
(register-runtime-type/runtime! 'LlmProvider procedure?)
(register-runtime-type/runtime! 'Agent agent?)
(register-runtime-type/runtime! 'AgentReply agent-reply?)
(register-runtime-type/runtime! 'Tool tool-spec?)
(register-runtime-type/runtime! 'Conversation conversation?)
(register-runtime-type/runtime! 'ConversationTurn conv-turn?)
(register-runtime-type/runtime! 'ToolStep llm-response?)

;;; ── Provider constructors ────────────────────────────────────────────────────

;;; mockProvider : List String -> LlmProvider — text-only scripted replies.
(define (mockProvider scripted-texts)
  (make-mock-provider (raw-value scripted-texts)))

;;; A mock "tool step" is either a tool_use turn or a final text turn, expressed
;;; as a normalized llm-response so make-mock-provider returns it verbatim.
;;; toolUseStep name callId argsJson  → an llm-response whose stop-reason is
;;;   'tool-use carrying one tool-call (args parsed from the JSON string).
(define (toolUseStep tool-name call-id args-json)
  (define args (string->jsexpr (raw-value args-json)))
  (llm-response "" (hash 'input 1 'output 1 'cache-read 0 'cache-write 0)
                (list (tool-call (raw-value call-id) (raw-value tool-name) args))
                'tool-use))

;;; textStep text → a final assistant text turn (end-turn, no tools).
(define (textStep text)
  (llm-response (raw-value text)
                (hash 'input 1 'output 1 'cache-read 0 'cache-write 0)
                '() 'end-turn))

;;; mockToolProvider : List ToolStep -> LlmProvider — deterministic provider
;;; that scripts a multi-round tool-calling sequence for tests, NO network.
(define (mockToolProvider steps)
  (make-mock-provider (raw-value steps)))

;;; Real providers — apiKey/endpoint + model, positional.
(define (anthropic api-key model)
  (make-anthropic-provider (raw-value api-key) (raw-value model)))
(define (openai api-key model)
  (make-openai-provider (raw-value api-key) (raw-value model)))
;; Mistral speaks the OpenAI chat-completions wire format (Bearer auth), so it
;; reuses the OpenAI provider pointed at Mistral's endpoint.
(define (mistral api-key model)
  (make-openai-provider (raw-value api-key) (raw-value model)
                        "https://api.mistral.ai/v1/chat/completions"))
(define (local endpoint model)
  (make-local-provider (raw-value endpoint) (raw-value model)))

;;; ── Agent constructors ────────────────────────────────────────────────────────

;;; defineAgent : LlmProvider -> String -> Int -> Agent
(define (defineAgent provider system-prompt max-tokens)
  (define p (raw-value provider))
  (unless (procedure? p)
    (raise-user-error 'defineAgent
                      "first argument must be an LlmProvider, got ~e" p))
  (agent p (raw-value system-prompt) (raw-value max-tokens) '() #f))

;;; tool : name description schema validator dispatch -> Tool
(define (tool name description schema validator dispatch)
  (define v (raw-value validator))
  (define d (raw-value dispatch))
  (unless (procedure? v)
    (raise-user-error 'tool "validator must be a function String -> a, got ~e" v))
  (unless (procedure? d)
    (raise-user-error 'tool "dispatch must be a function a -> String, got ~e" d))
  (tool-spec (raw-value name) (raw-value description) (raw-value schema) v d))

;;; tesl-agent-decode-args : args-json-string × (listof (cons key type-tag)) -> (listof value)
;;; The validator the declarative `agent { tools: [fn...] }` lowering installs for a
;;; tool: decode the model's tool-call arguments JSON into the tool function's
;;; positional parameters, type-checking each value against the parameter's base
;;; type.  A non-object payload, a missing field, or a type mismatch RAISES — the
;;; tool-call loop turns that into an is_error tool_result so the model can retry.
;;; Self-contained (only `json` + raw-value), so no codec-registry entry is needed
;;; for a primitive-typed tool parameter.
(define (tesl-agent-decode-args args-json specs)
  (define j
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (raise-user-error 'tool "arguments were not valid JSON: ~a"
                                         (exn-message e)))])
      (string->jsexpr (raw-value args-json))))
  (unless (hash? j)
    (raise-user-error 'tool "expected a JSON object of arguments, got ~e" j))
  (for/list ([s (in-list specs)])
    (define key (car s))
    (define tag (cdr s))
    (define v (hash-ref j (string->symbol key)
                        (lambda ()
                          (raise-user-error 'tool "missing required argument: ~a" key))))
    (case tag
      [(string) (if (string? v) v
                    (raise-user-error 'tool "argument ~a must be a string" key))]
      [(int)    (if (exact-integer? v) v
                    (raise-user-error 'tool "argument ~a must be an integer" key))]
      [(float)  (if (real? v) (exact->inexact v)
                    (raise-user-error 'tool "argument ~a must be a number" key))]
      [(bool)   (if (boolean? v) v
                    (raise-user-error 'tool "argument ~a must be a boolean" key))]
      [else     (raise-user-error 'tool "unsupported argument type for ~a" key)])))

;;; withTools : Agent -> List Tool -> Agent
(define (withTools the-agent tools)
  (define a (raw-value the-agent))
  (unless (agent? a)
    (raise-user-error 'withTools "first argument is not an Agent: ~e" a))
  (define ts (map raw-value (raw-value tools)))
  (for ([t (in-list ts)])
    (unless (tool-spec? t)
      (raise-user-error 'withTools "expected a Tool, got ~e" t)))
  (struct-copy agent a [tools ts]))

;;; ── Tool-call loop internals ──────────────────────────────────────────────────

;;; The tools, as provider tool-decls (name/description/parsed-schema jsexpr).
(define (agent-tool-decls a)
  (for/list ([t (in-list (agent-tools a))])
    (hash 'name (tool-spec-name t)
          'description (tool-spec-description t)
          'schema (with-handlers ([exn:fail? (lambda (_) (hash 'type "object"))])
                    (string->jsexpr (tool-spec-schema t))))))

(define (find-tool a name)
  (for/or ([t (in-list (agent-tools a))])
    (and (equal? (tool-spec-name t) name) t)))

;;; Acquire a DB connection JUST for this tool dispatch, releasing it before
;;; returning so the loop never holds a connection across a provider call.  In
;;; Tier-0 the agent's db is #f, so this is a passthrough; the boundary is in
;;; place for Wave 2b (when conversation/worker carry a real db handle), and the
;;; INVARIANT — connection acquired per tool-exec, never across `call-provider`
;;; — is structural here.
(define (with-tool-db a thunk)
  (define db (agent-db a))
  (if db
      (let ([cwdb (dynamic-require (collection-file-path "sql.rkt" "dsl")
                                   'call-with-database)])
        (cwdb db thunk))
      (thunk)))

;;; Run one tool call: validate args → on failure return an is_error tool_result
;;; (NOT an exception); on success dispatch (DB per exec) → success tool_result.
;;; Returns a normalized tool-result content block.
(define (run-tool-call a tc)
  (define name (tool-call-name tc))
  (define t (find-tool a name))
  (cond
    [(not t)
     (tool-result-block (tool-call-id tc)
                        (format "unknown tool: ~a" name) #t)]
    [else
     ;; Validate: the validator takes the args JSON *string*.  Any raise, or a
     ;; returned check-fail, is a malformed-arg → is_error tool_result.
     (define args-json (jsexpr->string (tool-call-args tc)))
     (define validated
       (with-handlers ([exn:fail? (lambda (e) (cons 'error (exn-message e)))])
         (define r ((tool-spec-validator t) args-json))
         (if (check-fail? r) (cons 'error (check-fail-message r)) (cons 'ok r))))
     (cond
       [(eq? (car validated) 'error)
        (tool-result-block (tool-call-id tc)
                           (format "invalid arguments: ~a" (cdr validated)) #t)]
       [else
        (define result
          (with-tool-db a (lambda () ((tool-spec-dispatch t) (cdr validated)))))
        ;; AGENT-4: a tool body that returns a `check-fail` (a domain validation
        ;; that did not hold — e.g. the `refundOrder confirmed:false` guard) must
        ;; be surfaced to the model as an is_error tool_result, NOT stringified
        ;; into a normal (success) result.  Otherwise the model is told the tool
        ;; succeeded and reports a fabricated outcome.
        (if (check-fail? result)
            (tool-result-block (tool-call-id tc)
                               (format "tool failed: ~a" (check-fail-message result)) #t)
            (tool-result-block (tool-call-id tc) (->result-string result) #f))])]))

(define (->result-string v)
  (define r (raw-value v))
  (if (string? r) r (format "~a" r)))

(define (tool-result-block id content is-error?)
  (hash 'kind 'tool-result 'id id 'content content 'is-error is-error?))

(define (assistant-block-of resp)
  ;; Reconstruct the assistant turn (text + tool_use blocks) for the transcript.
  (define text-blocks
    (if (> (string-length (llm-response-text resp)) 0)
        (list (hash 'kind 'text 'text (llm-response-text resp))) '()))
  (define tu-blocks
    (for/list ([tc (in-list (llm-response-tool-calls resp))])
      (hash 'kind 'tool-use 'id (tool-call-id tc)
            'name (tool-call-name tc) 'args (tool-call-args tc))))
  (append text-blocks tu-blocks))

(define (merge-usage acc u)
  (for/fold ([h acc]) ([k (in-list '(input output cache-read cache-write))])
    (hash-set h k (+ (hash-ref h k 0) (hash-ref u k 0)))))

;;; The agentic loop: provider → on tool_use, validate+dispatch each tool →
;;; append tool_results → loop until end-turn (or no tool calls).  Returns
;;; (values final-agent-reply full-message-transcript) — the transcript carries
;;; the user/assistant/tool turns so a conversation can thread it into the NEXT
;;; turn.  Provider is passed explicitly so BYOK reuses this.
;;;
;;; on-step : (or/c #f (String -> any))  — when non-#f, called once per loop
;;; step with a step-event String (a tool dispatch, then the final text).  This
;;; is how agentRun streams progress: the developer's callback publishes each
;;; event to a channel.  on-step never holds a DB connection.
(define (run-loop a provider initial-messages [on-step #f])
  (define max-iters 16) ; defensive bound against a runaway provider
  (define (step! s) (when on-step (on-step s)))
  (let loop ([messages initial-messages]
             [usage (hash 'input 0 'output 0 'cache-read 0 'cache-write 0)]
             [tool-count 0]
             [iters 0])
    (when (>= iters max-iters)
      (raise-user-error 'askReply "tool-calling loop exceeded ~a iterations" max-iters))
    (define request
      (hash 'system (agent-system a)
            'max-tokens (agent-max-tokens a)
            'messages messages
            'tools (agent-tool-decls a)))
    (define resp (call-provider provider request))
    (define usage* (merge-usage usage (llm-response-usage resp)))
    (define calls (llm-response-tool-calls resp))
    (cond
      [(null? calls)
       (define text (llm-response-text resp))
       (define messages*
         (if (> (string-length text) 0)
             (append messages
                     (list (hash 'role "assistant"
                                 'content (assistant-block-of resp))))
             messages))
       (step! (format "text: ~a" text))
       (values (agent-reply text usage* tool-count) messages*)]
      [else
       ;; Append the assistant turn, then a single tool message carrying every
       ;; tool_result.  Each tool runs with its own DB connection; NONE held
       ;; across the next call-provider above.
       (for ([tc (in-list calls)])
         (step! (format "tool: ~a" (tool-call-name tc))))
       (define results (map (lambda (tc) (run-tool-call a tc)) calls))
       (define messages*
         (append messages
                 (list (hash 'role "assistant" 'content (assistant-block-of resp))
                       (hash 'role "tool" 'content results))))
       (loop messages* usage* (+ tool-count (length calls)) (add1 iters))])))

;;; ── Inference entry points ─────────────────────────────────────────────────

;;; ask : Agent -> String -> String — one-shot text (compat).  Runs the full
;;; loop (so a tool-augmented agent still works) and returns the final text.
(define (ask the-agent prompt)
  (require-capabilities! (list aiProvider))
  (agent-reply-text (run-the-loop the-agent prompt #f)))

;;; askReply : Agent -> String -> AgentReply — full reply (text + usage + tools).
(define (askReply the-agent prompt)
  (require-capabilities! (list aiProvider))
  (run-the-loop the-agent prompt #f))

;;; askWith : Agent -> String -> LlmProvider -> AgentReply — BYOK.  Overrides the
;;; provider binding for THIS call only; capabilities are unchanged (still gated
;;; by aiProvider).
(define (askWith the-agent prompt provider)
  (require-capabilities! (list aiProvider))
  (run-the-loop the-agent prompt (raw-value provider)))

(define (run-the-loop the-agent prompt override-provider)
  (define-values (reply _transcript)
    (run-the-loop/transcript the-agent prompt override-provider '() #f))
  reply)

;;; Shared core: run the loop starting from `prior-messages` (the conversation
;;; transcript so far) plus this turn's user prompt; returns BOTH the reply and
;;; the FULL transcript (prior + this turn's user/assistant/tool turns).  This is
;;; the single place ask/askReply/askWith/converse/agentRun route through.
(define (run-the-loop/transcript the-agent prompt override-provider prior-messages on-step)
  (define a (raw-value the-agent))
  (unless (agent? a)
    (raise-user-error 'ask "first argument is not an Agent: ~e" a))
  (define provider (or override-provider (agent-provider a)))
  (unless (procedure? provider)
    (raise-user-error 'askWith "provider override must be an LlmProvider, got ~e" provider))
  (define initial
    (append prior-messages
            (list (hash 'role "user" 'content (raw-value prompt)))))
  (run-loop a provider initial on-step))

;;; AgentReply accessors.
(define (replyText r)
  (define rr (raw-value r))
  (unless (agent-reply? rr) (raise-user-error 'replyText "not an AgentReply: ~e" rr))
  (agent-reply-text rr))
(define (replyTokens r)
  (define rr (raw-value r))
  (define u (agent-reply-usage rr))
  (+ (hash-ref u 'input 0) (hash-ref u 'output 0)))
(define (replyToolCalls r)
  (agent-reply-tool-calls (raw-value r)))

;;; ── Function-first typed structured output ─────────────────────────────────

;;; decodeAs : String -> String -> a
;;; Decode a JSON string as a registered type, returning the SAME proof-carrying
;;; value an HTTP request-body decode produces (it goes through the identical
;;; `tesl-type-codec-decode` registry path).  Raises on decode failure so the
;;; `askFor` retry loop — and any direct caller — observes a failure uniformly.
(define (decodeAs type-name json-str)
  (define tn (string->symbol (raw-value type-name)))
  (define jsexpr
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (raise-user-error 'decodeAs "not valid JSON: ~a" (exn-message e)))])
      (string->jsexpr (raw-value json-str))))
  (define decoded (tesl-type-codec-decode tn jsexpr))
  (when (check-fail? decoded)
    (raise-user-error 'decodeAs "decoded value failed validation: ~a"
                      (check-fail-message decoded)))
  decoded)

;;; askFor : Agent -> String -> (String -> a) -> Int -> a
;;; Ask the model for a typed value.  Runs the loop; feeds the final text to the
;;; developer's `decoder` (String -> a).  On decode failure the error message is
;;; appended to a follow-up prompt and the model is re-asked, up to `max-retries`
;;; additional times.  Exhausting retries raises like an HTTP body validation
;;; failure (a user error).  A success yields the decoder's proof-carrying value.
(define (askFor the-agent prompt decoder max-retries)
  (require-capabilities! (list aiProvider))
  (define dec (raw-value decoder))
  (unless (procedure? dec)
    (raise-user-error 'askFor "decoder must be a function String -> a, got ~e" dec))
  (define retries (raw-value max-retries))
  (define base-prompt (raw-value prompt))
  (let attempt ([p base-prompt] [left retries])
    (define reply (askReply the-agent p))
    (define text (agent-reply-text reply))
    (define outcome
      (with-handlers ([exn:fail? (lambda (e) (cons 'error (exn-message e)))])
        (cons 'ok (dec text))))
    (cond
      [(eq? (car outcome) 'ok) (cdr outcome)]
      [(<= left 0)
       (raise-user-error 'askFor
                         "structured output did not decode after ~a retr~a: ~a"
                         retries (if (= retries 1) "y" "ies") (cdr outcome))]
      [else
       ;; Append the decode error to the next prompt and re-ask.
       (attempt (string-append
                 base-prompt
                 "\n\nYour previous reply could not be parsed: "
                 (cdr outcome)
                 "\nReturn ONLY valid JSON matching the requested shape.")
                (sub1 left))])))

;;; ── Multi-turn conversation ─────────────────────────────────────────────────
;;;
;;; A Conversation is an agent + the message transcript so far.  `converse` runs
;;; the loop with the WHOLE transcript threaded in, so turn N sees turns 1..N-1.
;;; The developer persists/loads the history themselves via conversationJson /
;;; conversationFrom (string round-trip) into their OWN entity — the runtime is
;;; not coupled to any user schema.

;;; newConversation : Agent -> Conversation — an empty (no-history) conversation.
(define (newConversation the-agent)
  (define a (raw-value the-agent))
  (unless (agent? a)
    (raise-user-error 'newConversation "first argument is not an Agent: ~e" a))
  (conversation a '()))

;;; converse : Conversation -> String -> ConversationTurn
;;; Threads the prior transcript in, runs the loop, returns the reply plus the
;;; conversation advanced by this turn (so the next converse sees this turn too).
;;; Gated by aiProvider (it contacts the provider).
(define (converse conv prompt)
  (require-capabilities! (list aiProvider))
  (define c (raw-value conv))
  (unless (conversation? c)
    (raise-user-error 'converse "first argument is not a Conversation: ~e" c))
  (define a (conversation-agent c))
  (define-values (reply transcript)
    (run-the-loop/transcript a prompt #f (conversation-messages c) #f))
  (conv-turn reply (conversation a transcript)))

;;; converseStreaming : Conversation -> String -> (String -> Unit) -> ConversationTurn
;;; Like converse, but calls `publish` once per loop step with a step-event String
;;; ("tool: <name>" as each tool is invoked, "text: <reply>" for the final assistant
;;; text), so a handler can stream the tool-use / thought process / reply over SSE
;;; while still threading the full conversation history into the turn.
(define (converseStreaming conv prompt publish)
  (require-capabilities! (list aiProvider))
  (define c (raw-value conv))
  (unless (conversation? c)
    (raise-user-error 'converseStreaming "first argument is not a Conversation: ~e" c))
  (define pub (raw-value publish))
  (unless (procedure? pub)
    (raise-user-error 'converseStreaming
                      "third argument must be a function String -> Unit, got ~e" pub))
  (define a (conversation-agent c))
  (define-values (reply transcript)
    (run-the-loop/transcript a prompt #f (conversation-messages c) (lambda (s) (pub s))))
  (conv-turn reply (conversation a transcript)))

;;; turnReply : ConversationTurn -> AgentReply
(define (turnReply t)
  (define tt (raw-value t))
  (unless (conv-turn? tt)
    (raise-user-error 'turnReply "not a ConversationTurn: ~e" tt))
  (conv-turn-reply tt))

;;; turnConversation : ConversationTurn -> Conversation — carries history forward.
(define (turnConversation t)
  (define tt (raw-value t))
  (unless (conv-turn? tt)
    (raise-user-error 'turnConversation "not a ConversationTurn: ~e" tt))
  (conv-turn-conversation tt))

;;; conversationLength : Conversation -> Int — number of messages in the
;;; transcript (for test assertions that history is threaded/persisted).
(define (conversationLength conv)
  (define c (raw-value conv))
  (unless (conversation? c)
    (raise-user-error 'conversationLength "not a Conversation: ~e" c))
  (length (conversation-messages c)))

;;; ── Conversation persistence (developer-owned) ──────────────────────────────
;;;
;;; conversationJson / conversationFrom round-trip the transcript through a
;;; String the developer stores in their own entity.  The transcript is a list
;;; of normalized message hashes with symbol keys; some values (the block 'kind
;;; tag) are symbols.  We tag symbol values as {"$sym": "..."} so the round-trip
;;; reproduces the EXACT runtime shape the loop consumes — including content
;;; blocks (tool_use args, tool_result is-error, etc.).

(define (encode-symbols v)
  (cond
    [(symbol? v) (hash '$sym (symbol->string v))]
    [(hash? v)
     (for/hash ([(k val) (in-hash v)])
       (values (if (symbol? k) (string->symbol (string-append "$k:" (symbol->string k))) k)
               (encode-symbols val)))]
    [(list? v) (map encode-symbols v)]
    [else v]))

(define (decode-symbols v)
  (cond
    [(and (hash? v) (= (hash-count v) 1) (hash-has-key? v '$sym))
     (string->symbol (hash-ref v '$sym))]
    [(hash? v)
     (for/hash ([(k val) (in-hash v)])
       (define ks (symbol->string k))
       (values (if (string-prefix? ks "$k:")
                   (string->symbol (substring ks 3))
                   k)
               (decode-symbols val)))]
    [(list? v) (map decode-symbols v)]
    [else v]))

;;; conversationJson : Conversation -> String
(define (conversationJson conv)
  (define c (raw-value conv))
  (unless (conversation? c)
    (raise-user-error 'conversationJson "not a Conversation: ~e" c))
  (jsexpr->string (encode-symbols (conversation-messages c))))

;;; conversationFrom : Agent -> String -> Conversation
;;; Restore a conversation's history from a String previously produced by
;;; conversationJson (and persisted by the developer).  Binds it to `the-agent`.
(define (conversationFrom the-agent json-str)
  (define a (raw-value the-agent))
  (unless (agent? a)
    (raise-user-error 'conversationFrom "first argument is not an Agent: ~e" a))
  (define raw (raw-value json-str))
  (define parsed
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (raise-user-error 'conversationFrom
                                         "history is not valid JSON: ~a" (exn-message e)))])
      (string->jsexpr raw)))
  (conversation a (decode-symbols parsed)))

;;; ── agentRun (worker-backed long loop + streaming) ───────────────────────────
;;;
;;; agentRun : Agent -> String -> (String -> Unit) -> AgentReply
;;; Run the agent loop to completion, calling `publisher` once per step with a
;;; step-event String.  Intended to be called from a `workers`/`queue` job body:
;;; the handler enqueues + returns; the worker runs agentRun and the publisher
;;; closure publishes each event to a channel, which a `subscribe` handler then
;;; streams over SSE.  DB connections are acquired per tool-exec inside the loop,
;;; never held across a provider call.  Gated by aiProvider.
(define (agentRun the-agent prompt publisher)
  (require-capabilities! (list aiProvider))
  (define pub (raw-value publisher))
  (unless (procedure? pub)
    (raise-user-error 'agentRun
                      "publisher must be a function String -> Unit, got ~e" pub))
  (define-values (reply _transcript)
    (run-the-loop/transcript the-agent prompt #f '()
                             (lambda (s) (pub s))))
  reply)
