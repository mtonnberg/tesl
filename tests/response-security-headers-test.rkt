#lang racket

;;; Phase -2 regression suite (roadmap/next/ensure_sso_works.md):
;;; the server-wide response security-header baseline.
;;;
;;; Covers: the header set is added to every response including the two paths
;;; that skipped it (static file + SPA-fallback HTML, both `response/full` with
;;; `'()` headers); a producer's own header is not overridden; HTML gets a CSP
;;; and JSON does not; HSTS derives from the configured public origin's scheme
;;; (never the request) and is suppressed for loopback.

(require rackunit
         web-server/http/response-structs
         web-server/http/request-structs
         (only-in "../dsl/web.rkt"
                  add-security-headers
                  security-response-headers
                  hsts-header-value
                  origin-loopback?
                  html-csp-value
                  current-content-security-policy))

(define (header-names resp)
  (map (lambda (h) (string-downcase (bytes->string/utf-8 (header-field h))))
       (response-headers resp)))

(define (hdr-val resp name)
  (for/or ([h (in-list (response-headers resp))])
    (and (string-ci=? (bytes->string/utf-8 (header-field h)) name)
         (bytes->string/utf-8 (header-value h)))))

;; Model the two bare paths: `response/full ... '()` with no headers at all.
(define (bare-html-response)
  (response/full 200 #"OK" (current-seconds) #"text/html; charset=utf-8" '()
                 (list #"<html></html>")))
(define (bare-json-response)
  (response/full 200 #"OK" (current-seconds) #"application/json" '()
                 (list #"{}")))

;;; ── The static / SPA-fallback HTML path now carries the header set ───────────

(test-case "HTML response gains nosniff, Referrer-Policy, X-Frame-Options and a CSP"
  (parameterize ([current-environment-variables (make-environment-variables)])
    (define r (add-security-headers (bare-html-response)))
    (define names (header-names r))
    (check-not-false (member "x-content-type-options" names) "nosniff on served HTML")
    (check-not-false (member "referrer-policy" names) "Referrer-Policy on served HTML")
    (check-not-false (member "x-frame-options" names) "X-Frame-Options on served HTML")
    (check-not-false (member "content-security-policy" names) "CSP on served HTML")
    (check-equal? (hdr-val r "Referrer-Policy") "no-referrer")
    (check-equal? (hdr-val r "X-Frame-Options") "DENY")))

(test-case "JSON response gets the header set but NO CSP"
  (parameterize ([current-environment-variables (make-environment-variables)])
    (define r (add-security-headers (bare-json-response)))
    (define names (header-names r))
    (check-not-false (member "referrer-policy" names))
    (check-false (member "content-security-policy" names)
                 "a JSON (non-document) response must not carry a CSP")))

;;; ── A producer's own header wins (no override) ───────────────────────────────

(test-case "add-security-headers does not override a header already set"
  (parameterize ([current-environment-variables (make-environment-variables)])
    (define custom
      (response/full 200 #"OK" (current-seconds) #"text/html"
                     (list (make-header #"Referrer-Policy" #"strict-origin"))
                     (list #"x")))
    (define r (add-security-headers custom))
    (check-equal? (hdr-val r "Referrer-Policy") "strict-origin"
                  "the producer's own Referrer-Policy must be preserved")
    ;; exactly one Referrer-Policy header
    (check-equal? (length (filter (lambda (n) (string=? n "referrer-policy"))
                                  (header-names r)))
                  1)))

;;; ── HSTS derives from the configured public origin, never the request ────────

(test-case "HSTS present only under an https public origin, absent for http/loopback/unset"
  (parameterize ([current-environment-variables (make-environment-variables)])
    (check-false (hsts-header-value) "unset public origin ⇒ no HSTS"))
  (parameterize ([current-environment-variables
                  (make-environment-variables #"TESL_PUBLIC_ORIGIN" #"https://app.example.com")])
    (check-equal? (hsts-header-value) #"max-age=31536000"))
  (parameterize ([current-environment-variables
                  (make-environment-variables #"TESL_PUBLIC_ORIGIN" #"http://app.example.com")])
    (check-false (hsts-header-value) "http origin ⇒ no HSTS"))
  (parameterize ([current-environment-variables
                  (make-environment-variables #"TESL_PUBLIC_ORIGIN" #"https://localhost:8080")])
    (check-false (hsts-header-value) "loopback dev origin ⇒ HSTS suppressed")))

(test-case "HSTS rides onto a response only under an https public origin"
  (parameterize ([current-environment-variables
                  (make-environment-variables #"TESL_PUBLIC_ORIGIN" #"https://app.example.com")])
    (check-not-false (member "strict-transport-security"
                        (header-names (add-security-headers (bare-html-response))))))
  (parameterize ([current-environment-variables (make-environment-variables)])
    (check-false (member "strict-transport-security"
                         (header-names (add-security-headers (bare-html-response)))))))

;;; ── CSP override + origin-loopback? classification ───────────────────────────

(test-case "TESL_CSP overrides the default HTML CSP"
  (parameterize ([current-environment-variables (make-environment-variables)])
    (check-equal? (html-csp-value) #"frame-ancestors 'none'"))
  (parameterize ([current-environment-variables
                  (make-environment-variables #"TESL_CSP" #"default-src 'self'")])
    (check-equal? (html-csp-value) #"default-src 'self'")))

(test-case "OQ17/#50.1: the contentSecurityPolicy clause sets the HTML CSP, over the env"
  (parameterize ([current-environment-variables (make-environment-variables)]
                 [current-content-security-policy "default-src 'self'; frame-ancestors 'none'"])
    (check-equal? (html-csp-value) #"default-src 'self'; frame-ancestors 'none'"))
  ;; the clause takes precedence over TESL_CSP
  (parameterize ([current-environment-variables
                  (make-environment-variables #"TESL_CSP" #"frame-ancestors 'none'")]
                 [current-content-security-policy "default-src 'self'"])
    (check-equal? (html-csp-value) #"default-src 'self'")))

(test-case "a handler-set CSP still wins per response, even with a server clause"
  (parameterize ([current-content-security-policy "default-src 'self'"])
    (define custom
      (response/full 200 #"OK" (current-seconds) #"text/html"
                     (list (make-header #"Content-Security-Policy" #"frame-ancestors https://host.example"))
                     (list #"<html></html>")))
    (define r (add-security-headers custom))
    (define csps
      (for/list ([h (in-list (response-headers r))]
                 #:when (equal? (header-field h) #"Content-Security-Policy"))
        (header-value h)))
    (check-equal? csps (list #"frame-ancestors https://host.example")
                  "the per-response CSP is preserved and not duplicated")))

(test-case "origin-loopback? classifies origins"
  (check-true  (origin-loopback? "https://localhost:3000"))
  (check-true  (origin-loopback? "http://127.0.0.1"))
  (check-true  (origin-loopback? "https://[::1]:8443"))
  (check-false (origin-loopback? "https://app.example.com")))

;;; ── Non-response values pass through ─────────────────────────────────────────

(test-case "non-response values are returned untouched"
  (check-equal? (add-security-headers 'route-not-found) 'route-not-found))
