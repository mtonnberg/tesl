#lang racket

;; ── Request-scoped `Set-Cookie` accumulator ──────────────────────────────────
;;
;; The transport half of the session-cookie feature
;; (roadmap/completed/response_metadata_and_cookies.md).  It exists so that
;; `Http.setSessionCookie` — an ordinary capability-gated stdlib function in
;; `tesl/http.rkt` — can record an effect that the response builder in
;; `dsl/web.rkt` picks up, WITHOUT either module having to require the other.
;;
;; This module is deliberately tiny and knows nothing about cookies beyond
;; "a list of already-formatted `Set-Cookie` header VALUES, in send order".
;; Everything policy-shaped — the fixed `__Host-session` name, the fixed
;; attributes, the `Max-Age` taken from the JWT TTL — lives in `tesl/http.rkt`,
;; beside the capability that gates writing it.  Keeping only the parameter here
;; is what avoids a require cycle: `tesl/http.rkt` WRITES the accumulator and
;; `dsl/web.rkt` READS it.
;;
;; The parameter is a plain list, mutated with `(param (cons …))` inside the
;; `parameterize` extent — the same idiom `dsl/otel.rkt` uses for
;; `current-telemetry-events`, and it works for the same reason: `parameterize`
;; gives the current thread its own cell for the extent, so a write from
;; arbitrary depth in a handler body is still visible when
;; `handler-result->response` builds the response in that same extent.
;;
;; The default is `#f`, not `'()`, and that is load-bearing.  With a `'()`
;; default a write made OUTSIDE any request scope would mutate the global
;; default cell and leak into every subsequent request on the same thread.  `#f`
;; makes that case a loud error instead: a `Set-Cookie` with no response to ride
;; on is a bug, not something to silently drop.

(require (only-in web-server/http/request-structs make-header))

(provide current-response-cookies
         response-cookie-set!
         response-cookie-headers)

;; #f = no live HTTP response scope.  A list = the cookies recorded so far.
;; Callers establish a scope with `(parameterize ([current-response-cookies '()])
;; …)`; see `dispatch-request` and `handle-sse-request` in dsl/web.rkt.
(define current-response-cookies (make-parameter #f))

;; `value` is a complete `Set-Cookie` header value, e.g.
;; "__Host-session=eyJ…; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=3600".
;; `who` names the calling stdlib function, for the error message.
;;
;; Last call wins PER COOKIE NAME: a later write for the same name replaces the
;; earlier one, so `setSessionCookie` followed by `clearSessionCookie` (or the
;; reverse) emits exactly one `Set-Cookie` for that name rather than two
;; contradictory ones.  Send order is otherwise preserved.
(define (response-cookie-set! who value)
  (define current (current-response-cookies))
  (unless (list? current)
    (error who
           (string-append
            "no HTTP response to attach a cookie to.\n"
            "  `~a` is only callable while serving an HTTP request — from a handler\n"
            "  body, an `auth` block, or an SSE subscribe.  A handler invoked as an\n"
            "  agent tool has no HTTP response, and neither does startup, `main` or\n"
            "  queue-worker code.")
           who))
  (define name (set-cookie-name value))
  (current-response-cookies
   (append (filter (lambda (v) (not (string=? (set-cookie-name v) name))) current)
           (list value))))

;; The NAME part of a `Set-Cookie` value — everything before the first `=`.
(define (set-cookie-name v)
  (define i (or (for/first ([c (in-string v)]
                            [k (in-naturals)]
                            #:when (char=? c #\=))
                  k)
                (string-length v)))
  (substring v 0 i))

;; The recorded cookies as `header` structs, ready to append to a response's
;; header list.  `'()` when there is no live scope, so every call site can
;; append unconditionally.
(define (response-cookie-headers)
  (define current (current-response-cookies))
  (if (list? current)
      (for/list ([v (in-list current)])
        (make-header #"Set-Cookie" (string->bytes/utf-8 v)))
      '()))
