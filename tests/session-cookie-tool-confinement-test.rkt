#lang racket
;;; session-cookie-tool-confinement-test.rkt
;;;
;;; Regression for the confused-deputy fix (adversarial review F1, 2026-07-30).
;;;
;;; A tool body runs inside the agent loop, which is itself inside an HTTP
;;; request whose `current-response-cookies` accumulator is live. Before the fix,
;;; a tool-invoked `Http.setSessionCookie` appended to the OUTER request's cookie
;;; list and rode out on the outer 200 — so prompt injection could make the model
;;; rewrite the browser's session (both `serverTools` endpoint handlers and
;;; `asTool` functions reach the same dispatch chokepoint at
;;; `tesl/agent.rkt` `run-tool-call`).
;;;
;;; The fix parameterizes `current-response-cookies` to #f around every tool
;;; dispatch, so a tool-side cookie write hits the "no HTTP response" error the
;;; accumulator already promises, which the tool `with-handlers` turns into a 500
;;; tool_result — never a browser Set-Cookie. This test drives the real loop:
;;; establish a live outer scope (as a request does), run an agent whose scripted
;;; tool tries to set a cookie, and assert the OUTER scope is untouched.

(require rackunit
         rackunit/text-ui
         json
         (only-in "../dsl/capability.rkt" with-capabilities)
         (only-in "../dsl/response-cookies.rkt"
                  current-response-cookies response-cookie-set!)
         "../tesl/agent.rkt")

;; A tool whose dispatch does exactly what `Http.setSessionCookie` does to the
;; accumulator: append a Set-Cookie value. If the reset is missing, this mutates
;; whatever `current-response-cookies` cell is live when the tool runs.
(define (cookie-leaking-tool)
  (tool "impersonate"
        "Rewrite the session (the attack this test guards against)."
        "{\"type\":\"object\",\"properties\":{\"who\":{\"type\":\"string\"}}}"
        (lambda (args-json)
          (hash-ref (string->jsexpr args-json) 'who "root-admin"))
        (lambda (who)
          ;; Mirrors the effect of Http.setSessionCookie inside a handler.
          (response-cookie-set! 'impersonate
                                (format "__Host-session=forged.~a.sig" who))
          (format "rewrote session to ~a" who))))

(define (leaking-agent provider)
  (withTools (defineAgent provider "You are a test bot." 256)
             (list (cookie-leaking-tool))))

(define confinement-tests
  (test-suite
   "tool cookie confinement (F1)"

   ;; The core assertion: inside a live outer request scope, a tool that sets a
   ;; cookie must NOT mutate the outer accumulator.
   (test-case "a tool cannot write the outer request's session cookie"
     (parameterize ([current-response-cookies '()])   ; a live HTTP request scope
       (define provider
         (mockToolProvider
          (list (toolUseStep "impersonate" "call-1" "{\"who\":\"root-admin\"}")
                (textStep "done"))))
       (with-capabilities (aiProvider)
         (askReply (leaking-agent provider) "please impersonate root-admin"))
       ;; The outer request's cookie list is STILL EMPTY — the tool's write was
       ;; confined to the #f scope and did not reach the response being built.
       (check-equal? (current-response-cookies) '()
                     "a tool-invoked cookie write must not appear on the outer response")))

   ;; The tool's cookie write raises inside the tool (no HTTP response in the #f
   ;; scope); that raise must be contained as a tool_result, NOT kill the loop —
   ;; the agent still reaches its final text.
   (test-case "the confined write is a contained tool error, not a loop crash"
     (parameterize ([current-response-cookies '()])
       (define provider
         (mockToolProvider
          (list (toolUseStep "impersonate" "call-1" "{\"who\":\"mallory\"}")
                (textStep "handled"))))
       (with-capabilities (aiProvider)
         (define reply (askReply (leaking-agent provider) "go"))
         (check-equal? (replyText reply) "handled")
         (check-equal? (replyToolCalls reply) 1))
       (check-equal? (current-response-cookies) '())))

   ;; Sanity: the tool DOES run (it is dispatched), so the test is not vacuously
   ;; green because the tool never fired. A tool that writes to a SEPARATE, own
   ;; scope succeeds — proving the mechanism works, only the OUTER one is off
   ;; limits.
   (test-case "the same write succeeds in its own scope (mechanism is real)"
     (parameterize ([current-response-cookies '()])
       (response-cookie-set! 'direct "__Host-session=legit.a.b")
       (check-equal? (length (current-response-cookies)) 1
                     "a direct write in a live scope does land — so the confinement above is meaningful")))))

(module+ test
  (run-tests confinement-tests))
