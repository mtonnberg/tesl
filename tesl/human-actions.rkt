#lang racket

;;; ── humanActions: endpoints the AGENT may NOT perform, surfaced to the human ──
;;;
;;; `humanActions MyServer user` (Tesl surface) lowers to
;;;
;;;   (human-actions "MyServer" (list (list "name" "description" "schema") …))
;;;
;;; and returns a List of Tool values — one INERT tool per endpoint of the
;;; server's api that the agent is NOT allowed to call on `user`'s behalf: the
;;; complement of `serverTools`.  An endpoint is a human action iff the user
;;; variable's declared proof annotation does NOT cover its auth predicates, so
;;; `serverTools` and `humanActions` partition the server's endpoints (disjoint,
;;; complete) at the same call site.
;;;
;;; The tool is INERT by construction — this is the whole security property:
;;;
;;;   * It takes the server NAME (a string), never the server value, so it has
;;;     NO access to the server's route-specs or handler closures.  There is no
;;;     in-process path from a `human-action-request` back to a call.  Contrast
;;;     `server-tools.rkt`, whose dispatch captures `route-spec-handler` and
;;;     applies it; this module deliberately cannot.
;;;   * dispatch builds a descriptor and returns it as the tool_result — it does
;;;     not, and cannot, execute the endpoint.  The agent gains no authority: an
;;;     excluded endpoint is absent from the agent's `serverTools` set, and its
;;;     `requires` capabilities are never delegated into the loop.
;;;   * The human's browser resolves the descriptor's `action` tag to the real
;;;     endpoint URL from GENERATED client code (keyed on the tag, never trusted
;;;     from the wire) and performs the call under the human's OWN session; the
;;;     endpoint re-checks auth server-side.  So the agent can only choose WHICH
;;;     excluded action to request and prefill its args — it can never fabricate
;;;     an action, relabel it, redirect it, or perform it.
;;;
;;; A `handle` correlates the request to its result so the human's completed
;;; action can re-enter the agent loop as a fresh turn ("resume-after"): the
;;; developer appends the {action, handle, result} to the persisted conversation
;;; and runs another `converse`.  The runtime does not suspend the turn.

(require (only-in "../dsl/private/evidence.rkt" raw-value)
         (only-in "agent.rkt" tool)
         (only-in racket/random crypto-random-bytes)
         (only-in file/sha1 bytes->hex-string)
         json)

(provide human-actions)

;; An unguessable correlation handle for one human-action request.
(define (fresh-handle)
  (bytes->hex-string (crypto-random-bytes 16)))

;; Light validator: the model's prefill args must be a well-formed JSON object.
;; This is NOT the authority on the arguments — the human confirms them in the
;; browser and the real endpoint re-validates + re-authorizes server-side.  We
;; only ensure the prefill is well-formed so it can be displayed cleanly.
(define (make-inert-validator)
  (lambda (args-json)
    (define j
      (with-handlers ([exn:fail?
                       (lambda (e)
                         (raise-user-error 'humanAction
                                           "arguments were not valid JSON: ~a"
                                           (exn-message e)))])
        (string->jsexpr (raw-value args-json))))
    (unless (hash? j)
      (raise-user-error 'humanAction
                        "expected a JSON object of arguments, got ~e" j))
    j))

;; Inert dispatch: build the `human-action-request` descriptor.  No server
;; routes, no handler, no capability delegation — only the compile-time action
;; identity, the model's (advisory) prefill, and a fresh correlation handle.
(define (make-inert-dispatch server-name action-name)
  (lambda (args)
    (jsexpr->string
     (hash 'kind "human-action-request"
           'server server-name
           'action action-name
           'args args
           'handle (fresh-handle)))))

;; human-actions : server-name-string
;;               × (listof (list name description schema))
;;               -> (listof Tool)
;; One inert tool per EXCLUDED endpoint (the compile-time complement of
;; `serverTools`, already filtered by the checker's per-call-site proof
;; decision).  Deliberately takes the server NAME, not the server value.
(define (human-actions server-name metadata)
  (define sname (raw-value server-name))
  (for/list ([row (in-list (raw-value metadata))])
    (define name (car row))
    (define description (cadr row))
    (define schema (caddr row))
    (tool name
          (string-append
           description
           "  (You cannot perform this action yourself. Calling this tool asks"
           " the human to perform it via a button in their app; you will be told"
           " the result in a later turn.)")
          schema
          (make-inert-validator)
          (make-inert-dispatch sname name))))
