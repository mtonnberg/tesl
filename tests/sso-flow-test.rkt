#lang racket/base

;;; Stage 2 — dsl/sso.rkt orchestration (roadmap/next/ensure_sso_works.md
;;; Phases 1 & 2), driven end-to-end through the outbound-HTTP stub hook: no
;;; network, no live provider.  Covers the OIDC and plain-OAuth2 happy paths and
;;; the security gates (nonce, issuer, SSRF, unverified-email domain restriction).

(require rackunit
         json
         racket/string
         (only-in "../tesl/crypto.rkt" base64url-encode)
         (only-in net/uri-codec uri-encode)
         (only-in "../dsl/capability.rkt" with-capabilities)
         (only-in "../tesl/http-client.rkt" httpClient)
         (only-in "../tesl/private/http-stub.rkt" current-outbound-http-hook)
         "../dsl/sso.rkt"
         (only-in "../tesl/sso.rkt" Sso.allowedEmailDomains Sso.logoutUrl))

(define KEY #"session-key-current-0000000000000000")
(define now 1000000)
(define REDIRECT "https://app.example/auth/x/callback")
(define OIDC-JWKS "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"k1\",\"n\":\"xhUDA0oGMIgoe3LI8_KRpSXz8cWsVe9UlvGR4v8ogMWPmN3WqWjm82yRMzlTuWDJJvO_NhPOW5wBxaFYBtTTRh5uxIxxN8oZbbrghpOdRubvbl22BAD86U3Ku8Mm-2dRjnJnqHfgcG3DBv2odgNcpdoEPJdvEAXmEo5941oXoAqebpyrSOBglw5lLI5Dzb4fOKJkjBfLOx4AQBkP6rVBue9ZV7T_IRlf32wrWX-LZcGpgKEMefge78jPADUK8M6inaKNNgtDXAuZ9DE7PzzLOLs0pvRhqbPFA4ZgUbVLYQKhqgFwTaJcucCs6KBbevUUqWt9VPiySXh8yoU4ldmwiQ\",\"e\":\"AQAB\"}]}")
(define OIDC-IDTOK "eyJhbGciOiJSUzI1NiIsImtpZCI6ImsxIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2lzc3Vlci5leGFtcGxlIiwiYXVkIjoiY2xpZW50LTEiLCJzdWIiOiJnb29nbGUtMTIzIiwibm9uY2UiOiJOIiwiZW1haWwiOiJ1c2VyQGFjbWUuY29tIiwiZW1haWxfdmVyaWZpZWQiOnRydWUsIm5hbWUiOiJVc2VyIiwiZXhwIjo5OTk5OTk5OTk5LCJpYXQiOjEwMDAwMDB9.RfQ1wQoZ_a9hq35p1Gd98BfxobUG85b9OTb83-4iYyxDe9nt0Eof-q-ycEiE9j4LCR--g1EjlaNWSknDnn-V-tLomwrDnCZodiWnBnN9nbC6j1rTligwiurpr2IbSKcTHA93Kez_YiG8WlOTkyY4bU_EjuzLnuAdWOCkP7vVbF3qSSoNjQ1CzkynRkbejKucmd54n7QzQ_3MQC0nmmbApyg5HoC2eWXzaIcbIWcni_dHBK4W2a2KlJrwZsWJhH6c600n9oBUwWB2_DIFR6MhTN4UthgiBcawprSH6Oyz5fsSuyZEKCwovdsmizEckAg4kDHM6eQLeCBj4D9uUwAvFw")

(define (mk-id-token payload)
  (string-append (base64url-encode #"{\"alg\":\"none\"}") "."
                 (base64url-encode (jsexpr->bytes payload)) "."
                 "unverified-signature"))

;; Install a dispatcher that answers by URL substring; returns the stub-hash shape.
(define (with-hook dispatch thunk)
  (parameterize ([current-outbound-http-hook
                  (lambda (mode method url headers body) (dispatch method url body))])
    (with-capabilities (httpClient) (thunk))))

(define (json-answer body) (hasheq 'status 200 'body body 'headers '()))

;;; ── OIDC happy path ───────────────────────────────────────────────────────────

(define oidc-conn
  (hasheq 'kind 'oidc 'issuer "https://issuer.example"
          'client-id "client-1" 'client-secret "sec"
          'scopes '("openid" "email" "profile")
          'allowed-tenants '() 'allowed-email-domains '() 'allowed-hosted-domains '()))

(define oidc-discovery
  (jsexpr->string
   (hasheq 'issuer "https://issuer.example"
           'authorization_endpoint "https://issuer.example/authorize"
           'token_endpoint "https://issuer.example/token"
           'jwks_uri "https://issuer.example/jwks"
           'id_token_signing_alg_values_supported '("RS256")
           'code_challenge_methods_supported '("S256"))))

(define (oidc-dispatch)
  (lambda (method url body)
    (cond
      [(regexp-match? #rx"well-known" url) (json-answer oidc-discovery)]
      [(regexp-match? #rx"/jwks" url) (json-answer OIDC-JWKS)]
      [(regexp-match? #rx"/token" url)
       (json-answer (jsexpr->string (hasheq 'access_token "at" 'id_token OIDC-IDTOK)))]
      [else #f])))

(test-case "OIDC: begin-login builds an S256 authorize URL + sealed cookie; callback yields a verified identity"
  (with-hook (oidc-dispatch)
    (lambda ()
      (define-values (url cookie)
        (sso-begin-login oidc-conn "x" REDIRECT KEY
                         #:state "the-state" #:nonce "N" #:verifier "the-verifier" #:now now))
      (check-true (regexp-match? #rx"code_challenge_method=S256" url))
      (check-true (regexp-match? #rx"nonce=N" url))
      (check-true (regexp-match? #rx"response_type=code" url))
      (define r (sso-handle-callback oidc-conn "x" "the-code" cookie REDIRECT (list KEY #f)
                                     #:now now #:state "the-state"))
      (check-true (hash-ref r 'ok))
      (define id (hash-ref r 'identity))
      (check-equal? (hash-ref id 'subject) "google-123")
      (check-equal? (hash-ref id 'issuer) "https://issuer.example")
      (check-equal? (hash-ref id 'email-tag) 'verified)
      (check-equal? (hash-ref id 'email) "user@acme.com")
      ;; opaque key, no email inside
      (check-true (regexp-match? #px"^[0-9a-f]{64}$" (hash-ref id 'key)))
      (check-false (regexp-match? #rx"acme" (hash-ref id 'key))))))

(test-case "OIDC: a mismatched nonce is refused (token minted for a different login)"
  (with-hook (oidc-dispatch)   ; the signed token carries nonce "N"
    (lambda ()
      (define-values (_url cookie)
        (sso-begin-login oidc-conn "x" REDIRECT KEY
                         #:state "s" #:nonce "different-nonce" #:verifier "v" #:now now))
      (define r (sso-handle-callback oidc-conn "x" "c" cookie REDIRECT (list KEY #f) #:now now))
      (check-false (hash-ref r 'ok))
      (check-regexp-match #rx"nonce" (hash-ref r 'reason)))))

(test-case "OIDC: discovery whose issuer disagrees is refused (never reflected)"
  (with-hook
   (lambda (method url body)
     (if (regexp-match? #rx"well-known" url)
         (json-answer (jsexpr->string (hasheq 'issuer "https://evil.example"
                                              'authorization_endpoint "https://issuer.example/authorize"
                                              'token_endpoint "https://issuer.example/token"
                                              'code_challenge_methods_supported '("S256"))))
         #f))
   (lambda ()
     ;; begin-login itself resolves discovery, so the mismatch is caught there.
     (check-exn exn:fail?
       (lambda ()
         (sso-begin-login oidc-conn "x" REDIRECT KEY
                          #:state "s" #:nonce "n" #:verifier "v" #:now now))))))

;;; ── plain OAuth2 happy path (GitHub-shaped) ──────────────────────────────────

(define gh-conn
  (hash-set*
   (sso-defaults 'GitHub "client-1" "sec")
   'authorize-url "https://gh.example/authorize"
   'token-url "https://gh.example/token"
   'userinfo-url "https://gh.example/user"
   'allowed-email-domains '() 'allowed-hosted-domains '()))

(define (gh-dispatch)
  (lambda (method url body)
    (cond
      [(regexp-match? #rx"/token" url) (json-answer (jsexpr->string (hasheq 'access_token "gho_x")))]
      [(regexp-match? #rx"/user" url)
       (json-answer (jsexpr->string (hasheq 'id 4242 'email "octo@github.example" 'name "Octo")))]
      [else #f])))

(test-case "OAuth2: userinfo yields an UNVERIFIED-email identity with a synthesized issuer"
  (with-hook (gh-dispatch)
    (lambda ()
      (define-values (url cookie)
        (sso-begin-login gh-conn "gh" REDIRECT KEY
                         #:state "s" #:nonce "n" #:verifier "v" #:now now))
      (check-false (regexp-match? #rx"nonce=" url))   ; no nonce for plain OAuth2
      (define r (sso-handle-callback gh-conn "gh" "c" cookie REDIRECT (list KEY #f) #:now now))
      (check-true (hash-ref r 'ok))
      (define id (hash-ref r 'identity))
      (check-equal? (hash-ref id 'subject) "4242")            ; numeric id stringified
      (check-equal? (hash-ref id 'issuer) "https://gh.example") ; synthesized from userinfo host
      (check-equal? (hash-ref id 'email-tag) 'unverified))))    ; GitHub /user email is unverified

(test-case "OAuth2: allowedEmailDomains refuses an unverified email even if the domain matches"
  (with-hook (gh-dispatch)
    (lambda ()
      (define conn (hash-set gh-conn 'allowed-email-domains '("github.example")))
      (define-values (_u cookie)
        (sso-begin-login conn "gh" REDIRECT KEY #:state "s" #:nonce "n" #:verifier "v" #:now now))
      (define r (sso-handle-callback conn "gh" "c" cookie REDIRECT (list KEY #f) #:now now))
      (check-false (hash-ref r 'ok))
      (check-regexp-match #rx"domain" (hash-ref r 'reason)))))

;; Risk 2: GitHub's /user email is public/unverified; the emails-url SECOND call
;; supplies the primary+verified address.
(define gh-emails-conn
  (hash-set gh-conn 'emails-url "https://gh.example/user/emails"))

(define (gh-emails-dispatch)
  (lambda (method url body)
    (cond
      [(regexp-match? #rx"/token" url) (json-answer (jsexpr->string (hasheq 'access_token "gho_x")))]
      [(regexp-match? #rx"/user/emails" url)
       (json-answer (jsexpr->string
                     (list (hasheq 'email "secondary@github.example" 'primary #f 'verified #t)
                           (hasheq 'email "unverified@github.example" 'primary #t 'verified #f)
                           (hasheq 'email "primary@corp.example" 'primary #t 'verified #t))))]
      [(regexp-match? #rx"/user" url)
       (json-answer (jsexpr->string (hasheq 'id 4242 'email "public@github.example" 'name "Octo")))]
      [else #f])))

(test-case "OAuth2 (GitHub): the emails-url second call yields the VERIFIED primary email"
  (with-hook (gh-emails-dispatch)
    (lambda ()
      (define-values (_u cookie)
        (sso-begin-login gh-emails-conn "gh" REDIRECT KEY #:state "s" #:nonce "n" #:verifier "v" #:now now))
      (define r (sso-handle-callback gh-emails-conn "gh" "c" cookie REDIRECT (list KEY #f) #:now now))
      (check-true (hash-ref r 'ok))
      (define id (hash-ref r 'identity))
      (check-equal? (hash-ref id 'email-tag) 'verified)         ; primary+verified, not the public /user email
      (check-equal? (hash-ref id 'email) "primary@corp.example"))))

(test-case "OAuth2 (GitHub): allowedEmailDomains now accepts a verified primary from emails-url"
  (with-hook (gh-emails-dispatch)
    (lambda ()
      (define conn (hash-set gh-emails-conn 'allowed-email-domains '("corp.example")))
      (define-values (_u cookie)
        (sso-begin-login conn "gh" REDIRECT KEY #:state "s" #:nonce "n" #:verifier "v" #:now now))
      (define r (sso-handle-callback conn "gh" "c" cookie REDIRECT (list KEY #f) #:now now))
      (check-true (hash-ref r 'ok) "a verified primary in the allow-listed domain is accepted")
      (check-equal? (hash-ref (hash-ref r 'identity) 'email) "primary@corp.example"))))

;;; ── SSRF gate at the token endpoint ───────────────────────────────────────────

(test-case "a token endpoint on a metadata IP is refused before any secret is sent"
  (with-hook (lambda (method url body) (json-answer "{}"))
    (lambda ()
      (define conn (hash-set* gh-conn 'token-url "https://169.254.169.254/token"))
      (define-values (_u cookie)
        (sso-begin-login conn "gh" REDIRECT KEY #:state "s" #:nonce "n" #:verifier "v" #:now now))
      (define r (sso-handle-callback conn "gh" "c" cookie REDIRECT (list KEY #f) #:now now))
      (check-false (hash-ref r 'ok)))))

;; Risk 27: the JWKS cache — a cached kid is reused with no second fetch, an
;; unknown kid within the rate window does NOT refetch (no amplification), and
;; after the window a rotation refetch happens exactly once.
(test-case "JWKS cache: cache hit, rate-limited unknown-kid, post-window refetch"
  (jwks-cache-reset!)
  (define fetches (box 0))
  (define JWKS (jsexpr->string (hasheq 'keys (list (hasheq 'kty "RSA" 'kid "k1" 'n "n" 'e "AQAB")))))
  (define url "https://issuer.example/jwks")
  (with-hook
   (lambda (method u body) (set-box! fetches (add1 (unbox fetches))) (json-answer JWKS))
   (lambda ()
     (define t0 1000)
     (jwks-for url "k1" t0)                 ; first: fetch + cache
     (check-equal? (unbox fetches) 1)
     (jwks-for url "k1" (+ t0 10))          ; same kid, within TTL: no fetch
     (check-equal? (unbox fetches) 1)
     (jwks-for url "k999" (+ t0 10))        ; unknown kid within the 60s window: no refetch
     (check-equal? (unbox fetches) 1)
     (jwks-for url "k999" (+ t0 60))        ; unknown kid after the window: exactly one refetch
     (check-equal? (unbox fetches) 2))))

;; Risk 17/53: the Sso.allowedEmailDomains BUILDER wires to the runtime
;; enforcement — a verified primary in the allow-list is accepted, out of it
;; refused.  Proves the surface sets the field build-identity reads.
(test-case "Sso.allowedEmailDomains builder is enforced end-to-end"
  (with-hook (gh-emails-dispatch)
    (lambda ()
      (define ok-conn (Sso.allowedEmailDomains gh-emails-conn (list "corp.example")))
      (define-values (_u1 c1)
        (sso-begin-login ok-conn "gh" REDIRECT KEY #:state "s" #:nonce "n" #:verifier "v" #:now now))
      (define r1 (sso-handle-callback ok-conn "gh" "c" c1 REDIRECT (list KEY #f) #:now now))
      (check-true (hash-ref r1 'ok) "verified primary primary@corp.example is in the allow-list")
      (define no-conn (Sso.allowedEmailDomains gh-emails-conn (list "other.example")))
      (define-values (_u2 c2)
        (sso-begin-login no-conn "gh" REDIRECT KEY #:state "s" #:nonce "n" #:verifier "v" #:now now))
      (define r2 (sso-handle-callback no-conn "gh" "c" c2 REDIRECT (list KEY #f) #:now now))
      (check-false (hash-ref r2 'ok) "the verified primary is not in a different allow-list")
      (check-regexp-match #rx"domain" (hash-ref r2 'reason)))))

;;; ── RP-initiated logout (issue #67) ──────────────────────────────────────────
;; The discovery document's own end_session_endpoint is captured and turned
;; into the full logout redirect, with client_id/post_logout_redirect_uri
;; percent-encoded onto it.  A provider that omits the field (or a
;; plain-OAuth2 connection, which has no discovery step at all) refuses
;; loudly rather than silently building a URL nobody can use.

(define oidc-discovery-with-logout
  (jsexpr->string
   (hasheq 'issuer "https://issuer.example"
           'authorization_endpoint "https://issuer.example/authorize"
           'token_endpoint "https://issuer.example/token"
           'jwks_uri "https://issuer.example/jwks"
           'end_session_endpoint "https://issuer.example/logout"
           'id_token_signing_alg_values_supported '("RS256")
           'code_challenge_methods_supported '("S256"))))

(define (logout-discovery-dispatch doc)
  (lambda (method url body)
    (cond
      [(regexp-match? #rx"well-known" url) (json-answer doc)]
      [else #f])))

(test-case "Sso.logoutUrl builds the RP-initiated logout redirect from discovery"
  (with-hook (logout-discovery-dispatch oidc-discovery-with-logout)
    (lambda ()
      (define url (Sso.logoutUrl oidc-conn "https://app.example/goodbye"))
      (check-true (regexp-match? #rx"^https://issuer[.]example/logout[?]" url))
      (check-true (regexp-match? #rx"client_id=client-1" url))
      (check-true (regexp-match?
                   (regexp (string-append "post_logout_redirect_uri="
                                          (uri-encode "https://app.example/goodbye")))
                   url)))))

(test-case "Sso.logoutUrl raises when the provider does not advertise end_session_endpoint"
  (with-hook (logout-discovery-dispatch oidc-discovery)  ; no end_session_endpoint field
    (lambda ()
      (check-exn exn:fail? (lambda () (Sso.logoutUrl oidc-conn "https://app.example/goodbye"))))))

(test-case "Sso.logoutUrl raises for a plain-OAuth2 connection (no discovery, no logout endpoint)"
  (check-exn exn:fail? (lambda () (Sso.logoutUrl gh-emails-conn "https://app.example/goodbye"))))
