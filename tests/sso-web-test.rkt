#lang racket/base

;;; Phase 3 — the runtime-owned SSO routes in dsl/web.rkt (roadmap/next/
;;; ensure_sso_works.md).  Proves the two things the Tesl handler surface cannot
;;; do and that the spec puts in the runtime: a 303 redirect and a Set-Cookie on
;;; a redirect, wired into dispatch.  A full login -> callback -> session flow is
;;; driven through the outbound-HTTP stub (plain OAuth2, no network).

(require rackunit
         racket/string
         json
         web-server/http/response-structs
         web-server/http/request-structs
         (only-in "../dsl/capability.rkt" with-capabilities)
         (only-in "../tesl/http-client.rkt" httpClient)
         (only-in "../tesl/private/http-stub.rkt" current-outbound-http-hook)
         (only-in "../tesl/logging.rkt" set-telemetry-log-sink!)
         (only-in "../dsl/web.rkt"
                  dsl-request make-sso-route
                  find-sso-match handle-sso-request
                  sso-cookie-line sso-redirect-response sso-failure-response
                  ;; OQ11: `publicOrigin fromEnv "VAR"` boot read + shared validity rule.
                  valid-public-origin? public-origin-from-env))

(define KEY (make-bytes 32 7))

(define (gh-conn)
  (hasheq 'kind 'oauth2 'client-id "cid" 'client-secret "csec"
          'scopes '("user:email")
          'authorize-url "https://gh.example/authorize"
          'token-url "https://gh.example/token"
          'userinfo-url "https://gh.example/user"
          'subject-field "id" 'email-field "email"
          'email-verified-field #f 'name-field "name"
          'allowed-email-domains '() 'allowed-hosted-domains '()))

(define (route)
  (make-sso-route #:segment "github" #:connection gh-conn
                  #:on-identity (lambda (id) (hash-ref id 'subject))
                  #:mint-session (lambda (subj) (string-append "TOKEN-" subj))
                  #:session-key-bytes KEY
                  #:public-origin "https://app.example" #:after-login "/home"))

(define (mk-req method path #:query [query (hash)] #:cookies [cookies (hash)])
  (dsl-request method path (hash) #"" cookies query #f))

(define (hdr resp name)
  (for/or ([h (in-list (response-headers resp))])
    (and (string-ci=? (bytes->string/utf-8 (header-field h)) name)
         (bytes->string/utf-8 (header-value h)))))

;;; ── Route matching ────────────────────────────────────────────────────────────
(test-case "find-sso-match matches /auth/<seg>/login and /callback, else #f"
  (define rs (list (route)))
  (check-equal? (cdr (find-sso-match rs (mk-req "GET" '("auth" "github" "login")))) 'login)
  (check-equal? (cdr (find-sso-match rs (mk-req "GET" '("auth" "github" "callback")))) 'callback)
  (check-false (find-sso-match rs (mk-req "GET" '("auth" "gh" "login"))))      ; wrong segment
  (check-false (find-sso-match rs (mk-req "GET" '("auth" "github" "logout")))) ; wrong verb
  (check-false (find-sso-match rs (mk-req "GET" '("health")))))

;;; ── The cookie + redirect primitives (blockers 1 & 2) ──────────────────────────
(test-case "sso-cookie-line is a __Host- cookie: Path=/, Secure, HttpOnly, SameSite=Lax"
  (define c (sso-cookie-line "__Host-oauth" "abc" #:max-age 600))
  (check-true (regexp-match? #rx"^__Host-oauth=abc" c))
  (check-true (regexp-match? #rx"Path=/" c))
  (check-true (regexp-match? #rx"Secure" c))
  (check-true (regexp-match? #rx"HttpOnly" c))
  (check-true (regexp-match? #rx"SameSite=Lax" c))
  (check-true (regexp-match? #rx"Max-Age=600" c)))

(test-case "sso-redirect-response is a 303 with Location, no-store and Set-Cookie"
  (define r (sso-redirect-response "https://x/y" (list (sso-cookie-line "__Host-oauth" "v"))))
  (check-equal? (response-code r) 303)
  (check-equal? (hdr r "Location") "https://x/y")
  (check-equal? (hdr r "Cache-Control") "no-store")
  (check-true (regexp-match? #rx"^__Host-oauth=v" (hdr r "Set-Cookie"))))

;;; ── login: 303 to the authorize URL + a sealed __Host-oauth cookie ─────────────
(test-case "login redirects to the authorize URL (S256) and sets __Host-oauth"
  (define resp (handle-sso-request (cons (route) 'login) (mk-req "GET" '("auth" "github" "login"))))
  (check-equal? (response-code resp) 303)
  (define loc (hdr resp "Location"))
  (check-true (regexp-match? #rx"^https://gh[.]example/authorize[?]" loc))
  (check-true (regexp-match? #rx"code_challenge_method=S256" loc))
  (check-true (regexp-match? #rx"redirect_uri=https%3A%2F%2Fapp[.]example%2Fauth%2Fgithub%2Fcallback" loc))
  (define sc (hdr resp "Set-Cookie"))
  (check-true (regexp-match? #rx"^__Host-oauth=" sc))
  (check-true (regexp-match? #rx"HttpOnly" sc)))

;;; ── callback failure paths (fail-closed, clears __Host-oauth) ──────────────────
(test-case "a callback with no cookie / no code is a 401 that clears __Host-oauth"
  (define resp (handle-sso-request (cons (route) 'callback)
                                   (mk-req "GET" '("auth" "github" "callback")
                                           #:query (hash "code" "c"))))  ; no cookie
  (check-equal? (response-code resp) 401)
  (check-true (regexp-match? #rx"__Host-oauth=; .*Max-Age=0" (hdr resp "Set-Cookie"))))

;;; ── full login -> callback -> session (plain OAuth2, stubbed HTTP) ─────────────
(define (with-hook dispatch thunk)
  (parameterize ([current-outbound-http-hook
                  (lambda (mode method url headers body) (dispatch method url body))])
    (with-capabilities (httpClient) (thunk))))
(define (answer body) (hasheq 'status 200 'body body 'headers '()))

(test-case "callback exchanges the code, builds the identity, and sets __Host-session"
  (define r (route))
  ;; 1. login to get a real sealed cookie + its state.
  (define login-resp (handle-sso-request (cons r 'login) (mk-req "GET" '("auth" "github" "login"))))
  (define loc (hdr login-resp "Location"))
  (define state (cadr (regexp-match #rx"[?&]state=([^&]+)" loc)))
  (define cookie-val (car (string-split (hdr login-resp "Set-Cookie") ";")))
  (define oauth-cookie (cadr (regexp-match #rx"^__Host-oauth=(.+)$" cookie-val)))
  ;; 2. callback with the provider's code + the same state + the cookie.
  (with-hook
   (lambda (method url body)
     (cond
       [(regexp-match? #rx"/token" url) (answer (jsexpr->string (hasheq 'access_token "at")))]
       [(regexp-match? #rx"/user" url)  (answer (jsexpr->string (hasheq 'id 4242 'email "o@x.example")))]
       [else #f]))
   (lambda ()
     (define resp
       (handle-sso-request (cons r 'callback)
                           (mk-req "GET" '("auth" "github" "callback")
                                   #:query (hash "code" "the-code" "state" state)
                                   #:cookies (hash "__Host-oauth" oauth-cookie))
                           ;; serve supplies main's granted caps here; the SSO
                           ;; flow needs httpClient for the token/userinfo fetch.
                           #:capabilities (list httpClient)))
     (check-equal? (response-code resp) 303)
     (check-equal? (hdr resp "Location") "/home")
     (define sc (hdr resp "Set-Cookie"))
     ;; subject is the GitHub id (4242), stringified; mint-session prefixes TOKEN-.
     (check-true (regexp-match? #rx"^__Host-session=TOKEN-4242" sc))
     (check-true (regexp-match? #rx"HttpOnly" sc)))))

;; Risk 21/65: the auth-event audit log — a structured event on success AND
;; every denial, carrying provenance + client address but NEVER a code/token.
(define (capture-auth-events thunk)
  (define events (box '()))
  (set-telemetry-log-sink!
   (lambda (category message attrs)
     (set-box! events (cons (list category message attrs) (unbox events)))))
  (dynamic-wind void thunk (lambda () (set-telemetry-log-sink! #f)))
  (reverse (unbox events)))

(define (auth-events evs) (filter (lambda (e) (equal? (car e) "AUTH")) evs))
(define (attr e k) (let ([p (assq k (caddr e))]) (and p (cdr p))))
(define (no-secret-leak? evs needles)
  (for/and ([e (in-list evs)])
    (for/and ([kv (in-list (caddr e))])
      (define v (format "~a" (cdr kv)))
      (for/and ([n (in-list needles)]) (not (regexp-match? (regexp-quote n) v))))))

(test-case "a successful callback emits an AUTH success event, without the code or token"
  (define r (route))
  (define login-resp (handle-sso-request (cons r 'login) (mk-req "GET" '("auth" "github" "login"))))
  (define loc (hdr login-resp "Location"))
  (define state (cadr (regexp-match #rx"[?&]state=([^&]+)" loc)))
  (define cookie-val (car (string-split (hdr login-resp "Set-Cookie") ";")))
  (define oauth-cookie (cadr (regexp-match #rx"^__Host-oauth=(.+)$" cookie-val)))
  (define evs
    (capture-auth-events
     (lambda ()
       (with-hook
        (lambda (method url body)
          (cond
            [(regexp-match? #rx"/token" url) (answer (jsexpr->string (hasheq 'access_token "at")))]
            [(regexp-match? #rx"/user"  url) (answer (jsexpr->string (hasheq 'id 4242 'email "o@x.example")))]
            [else #f]))
        (lambda ()
          (handle-sso-request (cons r 'callback)
                              (mk-req "GET" '("auth" "github" "callback")
                                      #:query (hash "code" "the-code" "state" state)
                                      #:cookies (hash "__Host-oauth" oauth-cookie))
                              #:capabilities (list httpClient)))))))
  (define as (auth-events evs))
  (check-equal? (length as) 1 "exactly one auth event")
  (check-equal? (attr (car as) 'auth.outcome) "success")
  (check-equal? (attr (car as) 'auth.provider) "github")
  (check-equal? (attr (car as) 'auth.subject) "4242")
  (check-true (no-secret-leak? as (list "the-code" "TOKEN-4242" oauth-cookie))
              "the audit event must not carry the code, the session token, or the oauth cookie"))

(test-case "a callback with no code / cookie emits an AUTH denied event"
  (define evs
    (capture-auth-events
     (lambda ()
       (handle-sso-request (cons (route) 'callback)
                           (mk-req "GET" '("auth" "github" "callback"))))))
  (define as (auth-events evs))
  (check-equal? (length as) 1)
  (check-equal? (attr (car as) 'auth.outcome) "denied")
  (check-equal? (attr (car as) 'auth.provider) "github"))

;; OQ11: the `publicOrigin fromEnv "VAR"` clause — the shared validity rule and
;; the boot-time env read (fail-closed on a missing/invalid value).  The rule
;; mirrors the compiler's `valid_public_origin` so both origin sources are
;; validated identically.
(test-case "valid-public-origin? accepts https and http-loopback, rejects the rest"
  (check-true  (valid-public-origin? "https://app.example.com"))
  (check-true  (valid-public-origin? "https://app.example.com/"))
  (check-true  (valid-public-origin? "http://localhost:8080"))
  (check-false (valid-public-origin? "app.example.com"))      ; no scheme
  (check-false (valid-public-origin? "https://a/b/c"))        ; a path
  (check-false (valid-public-origin? "https://a?x=1"))        ; a query
  (check-false (valid-public-origin? "https://a#f"))          ; a fragment
  (check-false (valid-public-origin? "http://evil.com")))     ; http, not loopback

(test-case "public-origin-from-env reads + validates at boot, fail-closed"
  (define var "TESL_TEST_PUBLIC_ORIGIN")
  ;; unset => error
  (environment-variables-set! (current-environment-variables) (string->bytes/utf-8 var) #f)
  (check-exn exn:fail? (lambda () (public-origin-from-env var)))
  ;; invalid => error
  (putenv var "not-an-origin")
  (check-exn exn:fail? (lambda () (public-origin-from-env var)))
  ;; valid => the trimmed origin string
  (putenv var "  https://app.example.com  ")
  (check-equal? (public-origin-from-env var) "https://app.example.com"))
