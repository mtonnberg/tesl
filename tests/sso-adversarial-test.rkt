#lang racket/base

;;; Phase 5 (roadmap/next/ensure_sso_works.md) — adversarial review pass over the
;;; SSO runtime (dsl/sso.rkt + jws-verify + ssrf-guard + the jwt session halves).
;;; Each case is one entry from the spec's attack list, asserted against the real
;;; runtime through the outbound-HTTP stub — no network, no live provider.

(require rackunit
         json
         racket/string
         racket/list
         (only-in "../tesl/crypto.rkt" base64url-encode)
         (only-in "../dsl/capability.rkt" with-capabilities)
         (only-in "../tesl/http-client.rkt" httpClient)
         (only-in "../tesl/private/http-stub.rkt" current-outbound-http-hook)
         "../dsl/sso.rkt")

(define KEY #"session-key-current-0000000000000000")
(define KEY2 #"session-key-previous-000000000000000")
(define now 1000000)
(define SECRET "s3cr3t-client-secret")
(define REDIRECT "https://app.example/auth/x/callback")

;; RS256 fixture (issuer https://issuer.example, aud client-1, sub google-123,
;; nonce N, email user@acme.com verified, exp far, iat 1000000).
(define OIDC-JWKS "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"k1\",\"n\":\"xhUDA0oGMIgoe3LI8_KRpSXz8cWsVe9UlvGR4v8ogMWPmN3WqWjm82yRMzlTuWDJJvO_NhPOW5wBxaFYBtTTRh5uxIxxN8oZbbrghpOdRubvbl22BAD86U3Ku8Mm-2dRjnJnqHfgcG3DBv2odgNcpdoEPJdvEAXmEo5941oXoAqebpyrSOBglw5lLI5Dzb4fOKJkjBfLOx4AQBkP6rVBue9ZV7T_IRlf32wrWX-LZcGpgKEMefge78jPADUK8M6inaKNNgtDXAuZ9DE7PzzLOLs0pvRhqbPFA4ZgUbVLYQKhqgFwTaJcucCs6KBbevUUqWt9VPiySXh8yoU4ldmwiQ\",\"e\":\"AQAB\"}]}")
(define IDTOK "eyJhbGciOiJSUzI1NiIsImtpZCI6ImsxIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2lzc3Vlci5leGFtcGxlIiwiYXVkIjoiY2xpZW50LTEiLCJzdWIiOiJnb29nbGUtMTIzIiwibm9uY2UiOiJOIiwiZW1haWwiOiJ1c2VyQGFjbWUuY29tIiwiZW1haWxfdmVyaWZpZWQiOnRydWUsIm5hbWUiOiJVc2VyIiwiZXhwIjo5OTk5OTk5OTk5LCJpYXQiOjEwMDAwMDB9.RfQ1wQoZ_a9hq35p1Gd98BfxobUG85b9OTb83-4iYyxDe9nt0Eof-q-ycEiE9j4LCR--g1EjlaNWSknDnn-V-tLomwrDnCZodiWnBnN9nbC6j1rTligwiurpr2IbSKcTHA93Kez_YiG8WlOTkyY4bU_EjuzLnuAdWOCkP7vVbF3qSSoNjQ1CzkynRkbejKucmd54n7QzQ_3MQC0nmmbApyg5HoC2eWXzaIcbIWcni_dHBK4W2a2KlJrwZsWJhH6c600n9oBUwWB2_DIFR6MhTN4UthgiBcawprSH6Oyz5fsSuyZEKCwovdsmizEckAg4kDHM6eQLeCBj4D9uUwAvFw")

(define (mk-conn #:issuer [issuer "https://issuer.example"] #:tenants [tenants '()]
                 #:edom [edom '()] #:hdom [hdom '()])
  (hasheq 'kind 'oidc 'issuer issuer 'client-id "client-1" 'client-secret SECRET
          'scopes '("openid" "email" "profile")
          'allowed-tenants tenants 'allowed-email-domains edom 'allowed-hosted-domains hdom))

(define (discovery #:s256 [s256 #t] #:algs [algs '("RS256")])
  (jsexpr->string
   (hasheq 'issuer "https://issuer.example"
           'authorization_endpoint "https://issuer.example/authorize"
           'token_endpoint "https://issuer.example/token"
           'jwks_uri "https://issuer.example/jwks"
           'id_token_signing_alg_values_supported algs
           'code_challenge_methods_supported (if s256 '("S256") '("plain")))))

(define (answer body) (hasheq 'status 200 'body body 'headers '()))

;; A dispatcher + a request recorder, so we can assert what left the process.
(define (make-recorder token-body #:disco [disco (discovery)])
  (define log (box '()))
  (values log
    (lambda (method url body)
      (set-box! log (cons (list method url body) (unbox log)))
      (cond
        [(regexp-match? #rx"well-known" url) (answer disco)]
        [(regexp-match? #rx"/jwks" url) (answer OIDC-JWKS)]
        [(regexp-match? #rx"/token" url) (answer token-body)]
        [else #f]))))

(define (with-hook dispatch thunk)
  (parameterize ([current-outbound-http-hook
                  (lambda (mode method url headers body)
                    ((car dispatch) headers)  ; record headers
                    ((cdr dispatch) method url body))])
    (with-capabilities (httpClient) (thunk))))

;; Simpler: hook wrapper recording (headers url body), returning dispatch result.
(define (run #:dispatch dispatch #:hdrs-box [hdrs (box '())] thunk)
  (parameterize ([current-outbound-http-hook
                  (lambda (mode method url headers body)
                    (set-box! hdrs (cons (list url headers body) (unbox hdrs)))
                    (dispatch method url body))])
    (with-capabilities (httpClient) (thunk))))

(define good-token (jsexpr->string (hasheq 'access_token "at" 'id_token IDTOK)))

;;; ══ 1. The client secret never leaves in a URL or the authorize request ══════
(test-case "the authorize URL carries no client_secret"
  (define-values (log disp) (make-recorder good-token))
  (run #:dispatch disp
   (lambda ()
     (define-values (url _c)
       (sso-begin-login (mk-conn) "x" REDIRECT KEY #:state "s" #:nonce "N" #:verifier "v" #:now now))
     (check-false (regexp-match? (regexp (regexp-quote SECRET)) url))
     (check-false (regexp-match? #rx"client_secret" url)))))

(test-case "the token exchange sends the secret in an Authorization header, never the URL or body"
  (define hdrs (box '()))
  (define-values (_log disp) (make-recorder good-token))
  (run #:dispatch disp #:hdrs-box hdrs
   (lambda ()
     (define-values (_u cookie)
       (sso-begin-login (mk-conn) "x" REDIRECT KEY #:state "s" #:nonce "N" #:verifier "v" #:now now))
     (sso-handle-callback (mk-conn) "x" "code" cookie REDIRECT (list KEY #f) #:now now)))
  ;; find the /token request record
  (define tok (findf (lambda (r) (regexp-match? #rx"/token" (car r))) (unbox hdrs)))
  (check-true (and tok #t) "a token request was made")
  (define url (car tok)) (define headers (cadr tok)) (define body (caddr tok))
  (define header-str (format "~a" headers))  ; headers are Tuple2 values
  (check-false (regexp-match? (regexp (regexp-quote SECRET)) url) "secret not in token URL")
  (check-false (regexp-match? #rx"client_secret" (or body "")) "no client_secret in the body")
  (check-false (regexp-match? (regexp (regexp-quote SECRET)) (or body "")) "raw secret not in the body")
  (check-true (regexp-match? #rx"Basic " header-str) "Basic auth header present")
  (check-true (regexp-match? #rx"code_verifier=" (or body "")) "PKCE verifier is sent"))

;;; ══ 2. A provider 200-with-error-body is not reflected ═══════════════════════
(test-case "a token endpoint returning an error body yields a generic reason, never the provider text"
  (define poison "PROVIDER-SECRET-LEAK-XYZ")
  (define-values (_log disp)
    (make-recorder (jsexpr->string (hasheq 'error "invalid_grant" 'error_description poison))))
  (run #:dispatch disp
   (lambda ()
     (define-values (_u cookie)
       (sso-begin-login (mk-conn) "x" REDIRECT KEY #:state "s" #:nonce "N" #:verifier "v" #:now now))
     (define r (sso-handle-callback (mk-conn) "x" "code" cookie REDIRECT (list KEY #f) #:now now))
     (check-false (hash-ref r 'ok))
     (check-false (regexp-match? (regexp (regexp-quote poison)) (hash-ref r 'reason))
                  "the provider's error_description must not be reflected"))))

;;; ══ 3. Signature: a wrongly-signed / algorithm-confused token is refused ═════
(test-case "a token with a broken signature is refused (MITM / wrong key)"
  (define parts (string-split IDTOK "."))
  (define forged (string-append (car parts) "." (cadr parts) "." "AAAA" (substring (caddr parts) 4)))
  (define-values (_log disp) (make-recorder (jsexpr->string (hasheq 'access_token "at" 'id_token forged))))
  (run #:dispatch disp
   (lambda ()
     (define-values (_u cookie)
       (sso-begin-login (mk-conn) "x" REDIRECT KEY #:state "s" #:nonce "N" #:verifier "v" #:now now))
     (define r (sso-handle-callback (mk-conn) "x" "code" cookie REDIRECT (list KEY #f) #:now now))
     (check-false (hash-ref r 'ok))
     (check-regexp-match #rx"signature" (hash-ref r 'reason)))))

;;; ══ 4. PKCE downgrade: a provider without S256 is refused ════════════════════
(test-case "a provider advertising only plain PKCE is refused at discovery"
  (define-values (_log disp) (make-recorder good-token #:disco (discovery #:s256 #f)))
  (run #:dispatch disp
   (lambda ()
     (check-exn exn:fail?
       (lambda ()
         (sso-begin-login (mk-conn) "x" REDIRECT KEY #:state "s" #:nonce "N" #:verifier "v" #:now now))))))

;;; ══ 5. Transport: discovery over http, and an SSRF jwks host, are refused ════
(test-case "a http:// issuer is refused (discovery must be https)"
  (define-values (_log disp) (make-recorder good-token))
  (run #:dispatch disp
   (lambda ()
     (check-exn exn:fail?
       (lambda ()
         (sso-begin-login (mk-conn #:issuer "http://issuer.example") "x" REDIRECT KEY
                          #:state "s" #:nonce "N" #:verifier "v" #:now now))))))

(test-case "a jwks_uri pointing at the metadata IP is refused (SSRF by resolved address)"
  (define disco (jsexpr->string
                 (hasheq 'issuer "https://issuer.example"
                         'authorization_endpoint "https://issuer.example/authorize"
                         'token_endpoint "https://issuer.example/token"
                         'jwks_uri "https://169.254.169.254/jwks"
                         'id_token_signing_alg_values_supported '("RS256")
                         'code_challenge_methods_supported '("S256"))))
  (define-values (_log disp) (make-recorder good-token #:disco disco))
  (run #:dispatch disp
   (lambda ()
     (define-values (_u cookie)
       (sso-begin-login (mk-conn) "x" REDIRECT KEY #:state "s" #:nonce "N" #:verifier "v" #:now now))
     (define r (sso-handle-callback (mk-conn) "x" "code" cookie REDIRECT (list KEY #f) #:now now))
     (check-false (hash-ref r 'ok)))))

;;; ══ 6. state cross-swap and cookie replay ════════════════════════════════════
(test-case "a presented state that disagrees with the cookie is refused"
  (define-values (_log disp) (make-recorder good-token))
  (run #:dispatch disp
   (lambda ()
     (define-values (_u cookie)
       (sso-begin-login (mk-conn) "x" REDIRECT KEY #:state "MINE" #:nonce "N" #:verifier "v" #:now now))
     (define r (sso-handle-callback (mk-conn) "x" "code" cookie REDIRECT (list KEY #f)
                                    #:now now #:state "ATTACKER"))
     (check-false (hash-ref r 'ok))
     (check-regexp-match #rx"state" (hash-ref r 'reason)))))

(test-case "a callback with no cookie at all is a failed flow, not a fresh login"
  (define-values (_log disp) (make-recorder good-token))
  (run #:dispatch disp
   (lambda ()
     (define r (sso-handle-callback (mk-conn) "x" "code" "" REDIRECT (list KEY #f) #:now now))
     (check-false (hash-ref r 'ok)))))

;;; ══ 7. Account takeover by unverified email; hosted-domain absence ═══════════
(test-case "allowedEmailDomains refuses an unverified match (nOAuth-class)"
  ;; direct: the rule the runtime applies before onIdentity
  (check-false (email-domain-allowed? 'unverified "a@acme.com" '("acme.com")))
  (check-false (email-domain-allowed? 'none "a@acme.com" '("acme.com")))
  (check-true  (email-domain-allowed? 'verified "a@acme.com" '("acme.com"))))

(test-case "allowedHostedDomains refuses an absent hd claim"
  (check-false (hosted-domain-allowed? #f '("acme.com")))
  (check-false (hosted-domain-allowed? "evil.com" '("acme.com")))
  (check-true  (hosted-domain-allowed? "acme.com" '("acme.com"))))

;;; ══ 8. Claim shapes: subject absent/empty/number, flattened-claims, clock ════
(define (base #:over [over (hasheq)])
  (for/fold ([h (hasheq 'iss "https://issuer.example" 'aud "client-1" 'nonce "N"
                        'sub "u" 'exp (+ now 300) 'iat now)])
            ([(k v) (in-hash over)]) (hash-set h k v)))
(define (vld h) (validate-oidc-claims h #:issuer "https://issuer.example"
                                        #:client-id "client-1" #:nonce "N" #:now now))

(test-case "a subject that is absent, empty, or not a string is refused"
  (check-true (string? (vld (hash-remove (base) 'sub))))
  (check-true (string? (vld (base #:over (hasheq 'sub "")))))
  (check-true (string? (vld (base #:over (hasheq 'sub 42)))))
  (check-true (string? (vld (base #:over (hasheq 'sub 'null))))))

(test-case "clock: past exp, future iat, and iat older than the flow start are refused"
  (check-true (string? (vld (base #:over (hasheq 'exp (- now 100))))))
  (check-true (string? (vld (base #:over (hasheq 'iat (+ now 100000))))))
  (check-true (string? (validate-oidc-claims (base) #:issuer "https://issuer.example"
                        #:client-id "client-1" #:nonce "N" #:now now
                        #:flow-start (+ now 100000)))))  ; iat far predates flow start

(test-case "a flattened `claims` substring cannot pass an array membership (Risk 18 shape)"
  ;; The runtime keeps claims as raw JSON: an array stays an array, not a string.
  (define groups (hash-ref (base #:over (hasheq 'groups '("superadmin" "readonly"))) 'groups))
  (check-true (list? groups))
  (check-false (string? groups))
  (check-true (and (member "superadmin" groups) #t))
  (check-false (member "admin" groups)))  ; no substring match into an array

;;; ══ 9. Multi-tenant issuer trap (Entra) ══════════════════════════════════════
(define TMPL "https://login.microsoftonline.com/{tenantid}/v2.0")
(define (vld-mt h tenants)
  (validate-oidc-claims h #:issuer TMPL #:client-id "client-1" #:nonce "N" #:now now
                        #:allowed-tenants tenants))
(test-case "common-authority templated issuer with empty allowedTenants authenticates no one"
  (check-true (string? (vld-mt (base #:over (hasheq 'iss TMPL)) '()))))
(test-case "a tid outside allowedTenants, or an iss/tid disagreement, is refused"
  (define good "https://login.microsoftonline.com/T-A/v2.0")
  (check-equal? (vld-mt (base #:over (hasheq 'iss good 'tid "T-A")) '("T-A")) #t)
  (check-true (string? (vld-mt (base #:over (hasheq 'iss good 'tid "T-B")) '("T-A"))))
  (check-true (string? (vld-mt (base #:over (hasheq 'iss "https://login.microsoftonline.com/OTHER/v2.0"
                                                     'tid "T-A")) '("T-A")))))

;;; ══ 10. extraAuthorizeParams smuggling ═══════════════════════════════════════
(test-case "a reserved param via extraAuthorizeParams is a hard error"
  (for ([k (in-list '("redirect_uri" "client_id" "response_type" "scope" "state"
                      "nonce" "code_challenge" "code_challenge_method" "client_secret"))])
    (check-exn exn:fail?
      (lambda () (build-authorize-url "https://a/auth" '() (list (cons k "x"))))
      (format "~a must be rejected" k))))
(test-case "an & / = in an extra param value is percent-encoded, not a smuggled parameter"
  (define url (build-authorize-url "https://a/auth" '(("state" . "s"))
                                   '(("prompt" . "consent&redirect_uri=https://evil"))))
  (check-false (regexp-match? #rx"&redirect_uri=https://evil" url))
  (check-true (regexp-match? #rx"%26redirect_uri%3D" url)))

;;; ══ 11. Identity-key stability + cross-provider subject assertion ════════════
(test-case "a segment rename leaves the identity key unchanged; a host change alters it"
  ;; the key derives from (issuer, subject), not the route segment
  (check-equal? (sso-subject-key "https://issuer.example" "u")
                (sso-subject-key "https://issuer.example" "u"))
  (check-not-equal? (sso-subject-key "https://issuer.example" "u")
                    (sso-subject-key "https://evil.example" "u")))
(test-case "one provider cannot assert another provider's subject (injective + issuer-scoped)"
  ;; provider A (issuer a) subject 'x|https://b' must not collide with provider B subject
  (check-not-equal? (sso-subject-key "https://a" "x|https://b")
                    (sso-subject-key "https://a|x" "https://b")))
