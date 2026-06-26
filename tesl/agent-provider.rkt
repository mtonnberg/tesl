#lang racket

;;; Tesl.Agent provider substrate (Tier-0 foundation slice).
;;;
;;; This module defines the *normalized provider response shape* that every
;;; LLM provider (anthropic / openai / local / mock) must produce, plus a
;;; deterministic MOCK provider used for testing AI features without a
;;; network call.
;;;
;;; A "provider" here is a plain Racket procedure of one argument — a request
;;; hash — returning a `llm-response` struct.  Later waves will add real
;;; HTTP-backed providers that conform to the same procedure contract; the
;;; agent core (tesl/agent.rkt) only ever sees this normalized shape, so it is
;;; provider-agnostic.
;;;
;;; Nothing in this file is exposed to Tesl surface code directly; it is the
;;; internal substrate that tesl/agent.rkt builds on.  Keep it tiny.

(provide (struct-out llm-response)
         make-mock-provider
         call-provider)

;;; The normalized response shape produced by every provider.
;;;   text       : String  — the assistant's text reply
;;;   usage       : hash    — token accounting, e.g. (hash 'input N 'output M)
;;;   tool-calls : list    — STUB for later waves (always '() this slice)
;;; A provider may omit usage/tool-calls; constructors below default them.
(struct llm-response (text usage tool-calls) #:transparent)

;;; make-mock-provider : (listof (or/c string? llm-response?)) -> (-> any/c llm-response?)
;;;
;;; Returns a deterministic provider procedure.  Each call returns the next
;;; scripted response by call index (0, 1, 2, ...).  A scripted entry that is a
;;; bare string is wrapped into an `llm-response` with empty usage and no
;;; tool-calls; an entry that is already an `llm-response` is returned as-is.
;;;
;;; The provider closes over a mutable call counter so successive calls walk
;;; the script.  Calling past the end of the script raises a user error — that
;;; is a test-authoring bug (more calls than scripted responses), and surfacing
;;; it deterministically is more useful than silently repeating.
(define (make-mock-provider scripted-responses)
  (define script
    (for/list ([r (in-list scripted-responses)])
      (cond
        [(llm-response? r) r]
        [(string? r) (llm-response r (hash) '())]
        [else (raise-user-error
               'mockProvider
               "scripted response must be a String or llm-response, got ~e" r)])))
  (define total (length script))
  (define calls 0)
  (lambda (_request)
    (when (>= calls total)
      (raise-user-error
       'mockProvider
       "mock provider exhausted: ~a call(s) made but only ~a scripted response(s)"
       (add1 calls) total))
    (define resp (list-ref script calls))
    (set! calls (add1 calls))
    resp))

;;; call-provider : provider request -> llm-response
;;; Thin indirection so the agent core never invokes a provider procedure
;;; directly (gives later waves a single choke point for retries / telemetry).
(define (call-provider provider request)
  (define resp (provider request))
  (unless (llm-response? resp)
    (raise-user-error 'agent
                      "provider returned ~e, expected an llm-response" resp))
  resp)
