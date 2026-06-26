#lang racket

;;; Tesl.Agent — AI agent capability and one-shot inference (Tier-0 slice).
;;;
;;; This is the FOUNDATION vertical slice for Tesl's AI support.  It proves the
;;; whole stdlib wiring end-to-end with the smallest possible feature surface:
;;;
;;;   * the `aiProvider` capability (implies `httpClient`, since real providers
;;;     will make outbound HTTP calls — gated the same way as Tesl.HttpClient).
;;;   * `mockProvider scripted-texts` — a deterministic LlmProvider for tests,
;;;     returning each scripted reply by call index, NO network.
;;;   * `defineAgent { provider, systemPrompt, maxTokens }` — builds an Agent
;;;     spec value (tools/database fields may be present but are unused here).
;;;   * `ask agent prompt` — one-shot: calls the agent's provider once and
;;;     returns the assistant's text as a String.  Requires `aiProvider`.
;;;
;;; NO tools, NO structured-output codec, NO streaming, NO real HTTP yet —
;;; those are later waves.  This file is hand-written Racket (it will grow an
;;; HTTP-backed agent loop) and therefore canNOT be a lifted .tesl module; it is
;;; registered in the compiler EXACTLY like Tesl.HttpClient (tesl/http-client.rkt).
;;;
;;; Surface usage:
;;;   import Tesl.Agent exposing [aiProvider, Agent, LlmProvider, AgentReply,
;;;                               mockProvider, defineAgent, ask]
;;;   capability supportBot implies aiProvider
;;;
;;; Runtime value representations (opaque to Tesl surface):
;;;   LlmProvider — a Racket procedure (request-hash -> llm-response)
;;;   Agent       — an `agent` struct
;;;   AgentReply  — an `agent-reply` struct (full reply incl. usage; later waves)

(require (only-in "../dsl/capability.rkt" define-capability require-capabilities!)
         (only-in "../dsl/private/evidence.rkt" raw-value)
         "agent-provider.rkt")

(provide aiProvider
         Agent
         LlmProvider
         AgentReply
         AgentReply?
         mockProvider
         defineAgent
         ask)

;;; The aiProvider capability — required by all inference functions.
;;; It IMPLIES httpClient because real providers perform outbound HTTP; granting
;;; aiProvider therefore also grants the network capability it builds on.
;;; (The httpClient capability value is re-exported through dsl/capability via
;;;  Tesl.HttpClient; we declare the implication structurally below.)
(require (only-in "http-client.rkt" httpClient))
(define-capability aiProvider (implies httpClient))

;;; ── Value types ─────────────────────────────────────────────────────────────

;;; An Agent spec.  `provider` is an LlmProvider procedure; `system` is the
;;; system prompt String; `max-tokens` is an Int.  `tools` / `db` exist for
;;; later waves and are unused this slice.
(struct agent (provider system max-tokens tools db) #:transparent)

;;; A normalized agent reply surfaced to Tesl as the `AgentReply` type.  This
;;; slice's `ask` returns the bare text String, but later waves return this
;;; richer value (text + usage + tool-calls).  Defined now so the type name is
;;; registered and stable.
(struct agent-reply (text usage) #:transparent)

;;; `Agent` / `LlmProvider` / `AgentReply` are exposed as opaque TYPE names on
;;; the Tesl surface.  Tesl type names that are imported but never used as a
;;; runtime constructor only need to be *bound* identifiers so the `(only-in
;;; ...)` require resolves.  We bind them to predicate/contract-ish stubs.
(define LlmProvider procedure?)
(define Agent agent?)
(define AgentReply agent-reply?)
(define AgentReply? agent-reply?)

;;; ── Constructors ────────────────────────────────────────────────────────────

;;; mockProvider : List String -> LlmProvider
;;; Wrap a list of scripted reply strings into a deterministic provider.
;;; This is the ONLY provider in this slice (no real network providers yet).
(define (mockProvider scripted-texts)
  (make-mock-provider (raw-value scripted-texts)))

;;; defineAgent : LlmProvider -> String -> Int -> Agent
;;; Build an Agent spec from a provider, a system prompt, and a max-tokens
;;; budget.  tools / db are reserved for later waves (default empty here).
(define (defineAgent provider system-prompt max-tokens)
  (define p (raw-value provider))
  (unless (procedure? p)
    (raise-user-error 'defineAgent
                      "first argument must be an LlmProvider, got ~e" p))
  (agent p
         (raw-value system-prompt)
         (raw-value max-tokens)
         '()
         #f))

;;; ── Inference ───────────────────────────────────────────────────────────────

;;; ask : Agent -> String -> String
;;; One-shot inference: send the system prompt + the user prompt to the agent's
;;; provider once, and return the assistant's text reply.  Requires aiProvider.
(define (ask the-agent prompt)
  (require-capabilities! (list aiProvider))
  (define a (raw-value the-agent))
  (unless (agent? a)
    (raise-user-error 'ask "first argument is not an Agent: ~e" a))
  (define request
    (hash 'system (agent-system a)
          'max-tokens (agent-max-tokens a)
          'messages (list (hash 'role "user" 'content (raw-value prompt)))))
  (define resp (call-provider (agent-provider a) request))
  (llm-response-text resp))
