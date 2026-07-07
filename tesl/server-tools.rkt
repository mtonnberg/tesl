#lang racket

;;; ── serverTools: server endpoints as agent tools ─────────────────────────────
;;;
;;; `serverTools MyServer user` (Tesl surface) lowers to
;;;
;;;   (server-tools MyServer user (list (list "name" "description" "schema") …))
;;;
;;; and returns a List of Tool values — one per INCLUDED endpoint of the
;;; server's api — each partially applied with the proof-carrying authenticated
;;; `user` value, so the agent acts strictly on the user's behalf: the tools ARE
;;; the same handler functions the HTTP API dispatches to, called with the same
;;; user value; every ownership/authorization check in the handler bodies runs
;;; unchanged.
;;;
;;; The metadata list is COMPILE-TIME output: the checker decides per call site
;;; which endpoints are included (an endpoint is present iff the user variable's
;;; declared proof annotation covers the endpoint's auth predicates — an
;;; `Authenticated && Admin` user gets the admin-gated endpoints, a plain
;;; `Authenticated` user does not), and the emitter derives each tool's
;;; name/description/JSON-schema. This module supplies the RUNTIME half:
;;;
;;;   validator — reuses the endpoint's OWN boundary pipeline pieces
;;;               (capture parser → via-check → proof attach; body codec decode
;;;               → via-check → proof attach), so a tool argument can never be
;;;               validated more weakly than the HTTP boundary;
;;;   dispatch  — applies the bound handler positionally (user first when the
;;;               endpoint has an auth line), validates the returned shape like
;;;               the HTTP dispatcher, and encodes the result through the same
;;;               JSON path an HTTP response uses.  A `fail status "msg"` from
;;;               the handler comes back as a check-fail → the agent loop turns
;;;               it into an is_error tool_result and keeps going (the agent
;;;               analogue of the HTTP error response); a runtime exception is
;;;               contained the same way (HTTP-500 parity) instead of killing
;;;               the loop.

(require (only-in "../dsl/web.rkt"
                  apply-checker-to-value
                  instantiate-binder-proof
                  prepare-json
                  validate-handler-return)
         (only-in "../dsl/types.rkt" current-agent-posix-enrichment?)
         (only-in "../dsl/types.rkt"
                  auth-spec-binder auth-spec-proof
                  capture-spec? capture-spec-name capture-spec-proof
                  capture-spec-parser capture-spec-checker
                  payload-spec? payload-spec-name payload-spec-type
                  payload-spec-proof payload-spec-wire-type payload-spec-decoder
                  payload-spec-checker
                  route-spec-operation route-spec-auth route-spec-segments
                  route-spec-handler route-spec-response-encoder
                  server-spec? server-spec-name server-spec-routes
                  jsexpr->typed-value/result
                  runtime-type-satisfied?)
         (only-in "../dsl/private/check-runtime.rkt"
                  attach ensure-named named-value?
                  check-fail check-fail? check-fail-message check-fail-status)
         (only-in "../dsl/private/evidence.rkt" raw-value)
         (only-in "../dsl/capability.rkt" call-with-delegated-capabilities)
         (only-in "agent.rkt" tool)
         json)

(provide server-tools)

;; A model-supplied argument value → the raw path-segment string the endpoint's
;; capture parser expects (captures are checker-enforced agent prims).
(define (jsexpr->segment-string who key v)
  (cond
    [(string? v) v]
    [(exact-integer? v) (number->string v)]
    [(real? v) (number->string v)]
    [(boolean? v) (if v "true" "false")]
    [else (raise-user-error who "argument ~a must be a JSON scalar, got ~e" key v)]))

;; Resolve one capture argument exactly like the HTTP path pipeline
;; (web.rkt resolve-segments): parser → via-check → declared-proof attach.
(define (resolve-capture-arg spec v)
  (define name (capture-spec-name spec))
  (define parsed ((capture-spec-parser spec)
                  (jsexpr->segment-string 'tool name v)))
  (cond
    [(check-fail? parsed) parsed]
    [else
     (define bound (apply-checker-to-value name parsed (capture-spec-checker spec)))
     (cond
       [(check-fail? bound) bound]
       [(and (named-value? bound) (capture-spec-proof spec))
        (attach bound (list (instantiate-binder-proof name bound (capture-spec-proof spec))))]
       [else bound])]))

;; Resolve the body argument exactly like the HTTP body pipeline
;; (web.rkt resolve-payload), starting from an already-parsed jsexpr.
(define (resolve-payload-arg spec parsed)
  (define decoded
    (cond
      [(payload-spec-wire-type spec)
       (define wire-value
         (jsexpr->typed-value/result (payload-spec-wire-type spec) parsed 'ReqBody))
       (if (check-fail? wire-value)
           wire-value
           ((payload-spec-decoder spec) wire-value))]
      [else ((payload-spec-decoder spec) parsed)]))
  (cond
    [(check-fail? decoded) decoded]
    [else
     (unless (runtime-type-satisfied? (payload-spec-type spec) (raw-value decoded))
       (raise-user-error 'tool
                         "decoded tool argument does not satisfy declared body type ~a"
                         (payload-spec-type spec)))
     (define bound
       (apply-checker-to-value (payload-spec-name spec) decoded (payload-spec-checker spec)))
     (if (and (named-value? bound) (payload-spec-proof spec))
         (attach bound
                 (list (instantiate-binder-proof (payload-spec-name spec)
                                                 bound
                                                 (payload-spec-proof spec))))
         bound)]))

;; The endpoint's input-bearing segments, in handler argument order.
(define (input-specs route)
  (filter (lambda (s) (or (capture-spec? s) (payload-spec? s)))
          (route-spec-segments route)))

;; The user value, bound + carrying the endpoint's declared auth proof — the
;; runtime mirror of what `run-auth` produces after the auth fn verified the
;; request.  Attaching here is justified STATICALLY: the checker only includes
;; an endpoint when the user variable's declared (and itself checker-verified)
;; proof annotation covers the endpoint's auth predicates.
(define (bind-auth-user auth user)
  (define bound (ensure-named (auth-spec-binder auth) user))
  (if (auth-spec-proof auth)
      (attach bound
              (list (instantiate-binder-proof (auth-spec-binder auth)
                                              bound
                                              (auth-spec-proof auth))))
      bound))

(define (arg-key spec)
  (define n (if (capture-spec? spec) (capture-spec-name spec) (payload-spec-name spec)))
  (if (symbol? n) n (string->symbol (format "~a" n))))

(define (make-endpoint-validator route)
  (define specs (input-specs route))
  (lambda (args-json)
    (define j
      (with-handlers ([exn:fail?
                       (lambda (e)
                         (raise-user-error 'tool "arguments were not valid JSON: ~a"
                                           (exn-message e)))])
        (string->jsexpr (raw-value args-json))))
    (unless (hash? j)
      (raise-user-error 'tool "expected a JSON object of arguments, got ~e" j))
    ;; Resolve left-to-right; the FIRST failure is the tool's is_error message.
    (let loop ([specs specs] [acc '()])
      (cond
        [(null? specs) (reverse acc)]
        [else
         (define spec (car specs))
         (define key (arg-key spec))
         (define v (hash-ref j key
                             (lambda ()
                               (raise-user-error 'tool "missing required argument: ~a" key))))
         (define bound
           (if (capture-spec? spec)
               (resolve-capture-arg spec v)
               (resolve-payload-arg spec v)))
         (if (check-fail? bound)
             bound   ; loop turns a returned check-fail into is_error
             (loop (cdr specs) (cons bound acc)))]))))

(define (make-endpoint-dispatch route user)
  (define auth (route-spec-auth route))
  (lambda (arg-values)
    (with-handlers ([exn:fail?
                     ;; HTTP-500 parity: a handler exception becomes a failed
                     ;; tool_result (the loop reports it is_error), not a crash
                     ;; of the whole agent loop.
                     (lambda (e) (check-fail (exn-message e) 500 '()))])
      (define auth-value (and auth (bind-auth-user auth user)))
      (define auth-args (if auth-value (list auth-value) '()))
      ;; Issue #30 class: this tool executes inside the agent loop, whose
      ;; ambient capability set need not include the handler's `requires` —
      ;; e.g. on an UNMOUNTED server (a common pattern: a second agent-facing
      ;; server sharing handlers with the user-facing one) CAP-COMPOSE never
      ;; forces main's grant to cover them.  Delegate the handler's OWN
      ;; registered declared capabilities, statically charged to the
      ;; `serverTools` call site by the checker.
      (define handler (route-spec-handler route))
      (define result
        (validate-handler-return
         route auth-value arg-values
         (call-with-delegated-capabilities
          handler
          (lambda () (apply handler (append auth-args arg-values))))))
      (cond
        [(check-fail? result)
         ;; keep the HTTP status visible to the model in the is_error text
         (check-fail (format "~a (HTTP ~a)"
                             (check-fail-message result)
                             (check-fail-status result))
                     (check-fail-status result) '())]
        [else
         ;; Agent-facing PosixMillis enrichment (see types.rkt): a tool result
         ;; is read by the MODEL, so epoch-millis values are rendered as
         ;; {epochMillis, iso} objects instead of bare integers the model
         ;; would misread.  Enrichment happens in the generic encode walk; a
         ;; response with a user-written codec keeps its authored shape (the
         ;; encoder consumes the plain prepared jsexpr, same as HTTP).
         (define encoded
           (if (route-spec-response-encoder route)
               (let ([prepared (prepare-json result)])
                 (prepare-json ((route-spec-response-encoder route) prepared)))
               (parameterize ([current-agent-posix-enrichment? #t])
                 (prepare-json result))))
         (jsexpr->string encoded)]))))

;; server-tools : server-spec × user × (listof (list name description schema))
;;             -> (listof Tool)
;; Builds one Tool per metadata row, paired with the server route of the same
;; operation name.  Fail-closed: a metadata row without a matching route (or a
;; non-server first argument) is a hard error — it means compiler and runtime
;; disagree about the server's surface.
(define (server-tools server user metadata)
  (define s (raw-value server))
  (unless (server-spec? s)
    (raise-user-error 'serverTools
                      "first argument is not a server (define-server value), got ~e" s))
  (define routes (server-spec-routes s))
  (for/list ([row (in-list (raw-value metadata))])
    (define name (car row))
    (define description (cadr row))
    (define schema (caddr row))
    (define route
      (or (for/or ([r (in-list routes)])
            (and (equal? (format "~a" (route-spec-operation r)) name) r))
          (raise-user-error 'serverTools
                            "no endpoint named ~a on server ~a — compiler/runtime mismatch"
                            name (server-spec-name s))))
    (tool name description schema
          (make-endpoint-validator route)
          (make-endpoint-dispatch route user))))
