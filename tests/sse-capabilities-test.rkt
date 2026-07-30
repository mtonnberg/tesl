#lang racket
;;; sse-capabilities-test.rkt
;;;
;;; Regression for the SSE-path fixes of the session-cookie adversarial review
;;; (F6 and F9, 2026-07-30).
;;;
;;; F6 — the SSE path never parameterized `current-capabilities`. Only
;;; `dispatch-request`/`invoke-handler` did, so an `auth` block or a `capture`
;;; check reached from a subscribe ran with the EMPTY ambient set: any `requires`
;;; row (the common case — a session lookup that reads the DB) failed
;;; `call-with-declared-capabilities`'s subset assertion with "Missing
;;; capabilities" and 500'd the subscribe. It also made the cookie scope that
;;; `handle-sse-request` establishes unreachable, since `Http.setSessionCookie`
;;; in an SSE auth could never run to write into it.
;;;
;;; F9 — an SSE 200 carried `Set-Cookie` beside `Access-Control-Allow-Origin: *`.
;;; A browser resolves that contradiction itself (a wildcard ACAO is rejected for
;;; a credentialed request), but the response should not state it. The wildcard
;;; now yields when the response carries a cookie.
;;;
;;; These drive `handle-sse-request` directly: `serve` reaches it through
;;; `serve/servlet`, which a unit test cannot exercise without opening a port.

(require rackunit
         rackunit/text-ui
         (only-in web-server/http/response-structs response-headers response-code)
         (only-in web-server/http/request-structs header-field header-value)
         (only-in "../dsl/capability.rkt"
                  define-capability current-capabilities require-capabilities!)
         (only-in "../dsl/response-cookies.rkt"
                  current-response-cookies response-cookie-set!)
         (only-in "../tesl/queue.rkt" define-channel)
         (only-in "../dsl/web.rkt" handle-sse-request make-request))

;; A capability an SSE `auth` block might legitimately declare (`kanelDbRead` in
;; the shipped example is exactly this shape).
(define-capability sseTestCap)

(define-channel SseTestChannel)

(define (header-value-for resp name)
  (for/first ([h (in-list (response-headers resp))]
              #:when (equal? (header-field h) name))
    (header-value h)))

;; route shape: (pattern auth-fn channel key-index captures) — see
;; emit_sse_route / handle-sse-request. #f in a pattern is a `:param` slot.
(define (route-with auth-fn)
  (list (list "events" #f) auth-fn SseTestChannel 1 '()))

(define req (make-request "GET" (list "events" "room-1")))

;; ── F6: an auth block with a `requires` row runs on the SSE path ─────────────

(define-test-suite sse-capability-tests

  (test-case "SSE auth may use the capabilities the server was granted"
    ;; The auth function asserts its declared capability exactly as an emitted
    ;; Tesl `auth … requires [c]` does (via call-with-declared-capabilities).
    ;; Before the fix this raised "Missing capabilities" — a 500 on every
    ;; subscribe behind a DB-reading session lookup.
    (define ran? #f)
    (define (auth-fn r)
      (require-capabilities! (list sseTestCap))
      (set! ran? #t)
      'ok)
    (define resp (handle-sse-request (route-with auth-fn) req
                                     #:capabilities (list sseTestCap)))
    (check-true ran? "the auth block must run to completion")
    (check-equal? (response-code resp) 200 "and the stream must open"))

  (test-case "MUTATION GUARD: with no grant it still fails, and fails closed"
    ;; The other side of the fix: capabilities are wired FROM `serve`'s grant,
    ;; not conjured. A server that never declared the capability must still be
    ;; refused — otherwise the test above would pass for the wrong reason.
    (define (auth-fn r)
      (require-capabilities! (list sseTestCap))
      'ok)
    (check-exn
     #px"Missing capabilities"
     (lambda () (handle-sse-request (route-with auth-fn) req #:capabilities '()))))

  (test-case "SSE capture checks also run under the granted capabilities"
    ;; Same gap, second consumer: `capture k: T ::: P k via someCapturer` runs on
    ;; this path too, and a capturer that reads the DB carries a `requires` row.
    (define checked? #f)
    (define (capture-fn seg)
      (require-capabilities! (list sseTestCap))
      (set! checked? #t)
      seg)
    (define route (list (list "events" #f) #f SseTestChannel 1
                        (list (cons 1 capture-fn))))
    (handle-sse-request route req #:capabilities (list sseTestCap))
    (check-true checked? "the declared capture check must run"))

  ;; ── F6/F9: the cookie scope is reachable, and the wildcard yields to it ─────

  (test-case "a cookie written by an SSE auth reaches the response"
    ;; The scope `handle-sse-request` establishes was dead code while auth could
    ;; not run a capability-gated writer. Assert it end-to-end.
    (define (auth-fn r)
      (require-capabilities! (list sseTestCap))
      (response-cookie-set! 'test-auth
                            "__Host-session=abc; Path=/; HttpOnly; Secure; SameSite=Lax")
      'ok)
    (define resp (handle-sse-request (route-with auth-fn) req
                                     #:capabilities (list sseTestCap)))
    (check-equal? (header-value-for resp #"Set-Cookie")
                  #"__Host-session=abc; Path=/; HttpOnly; Secure; SameSite=Lax")
    ;; F9: no "any origin may read this" beside a session cookie.
    (check-false (header-value-for resp #"Access-Control-Allow-Origin")
                 "a credentialed SSE response must not carry a wildcard ACAO"))

  (test-case "an ordinary subscribe keeps the wildcard ACAO it always had"
    ;; F9 is a subtraction that must not become a blanket removal: the
    ;; uncredentialed EventSource case is unchanged.
    (define resp (handle-sse-request (route-with #f) req #:capabilities '()))
    (check-equal? (header-value-for resp #"Access-Control-Allow-Origin") #"*")
    (check-false (header-value-for resp #"Set-Cookie")))

  (test-case "the request-scoped cookie accumulator does not leak past the request"
    ;; Per-request scoping, the same property `dispatch-request` holds: the
    ;; parameterize extent ends with the subscribe, so the next request on this
    ;; thread starts with no live scope (#f = a loud error, not a silent drop).
    (define (auth-fn r)
      (response-cookie-set! 'test-auth "__Host-session=xyz; Path=/")
      'ok)
    (handle-sse-request (route-with auth-fn) req #:capabilities '())
    (check-false (current-response-cookies)
                 "no live cookie scope may survive the subscribe")
    (check-equal? (current-capabilities) '()
                  "and no capability grant may survive it either")))

(module+ main
  (void (run-tests sse-capability-tests)))

(module+ test
  (require rackunit/text-ui)
  (void (run-tests sse-capability-tests)))
