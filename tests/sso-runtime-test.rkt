#lang racket/base

;;; Stage 2 — dsl/sso.rkt pure security layer (roadmap/next/ensure_sso_works.md
;;; Phases 1 & 2).  These are the account-takeover-class decisions, so they are
;;; tested exhaustively and with the spec's own attack shapes.

(require rackunit
         (only-in "../tesl/crypto.rkt" sha256-bytes base64url-encode)
         (only-in file/sha1 bytes->hex-string)
         (only-in "../tesl/sso.rkt" Sso.email Sso.tenant Sso.claim)
         (only-in "../dsl/types.rkt" Something Nothing)
         "../dsl/sso.rkt")

(define KEY  #"session-key-current-0000000000000000")
(define KEY2 #"session-key-previous-000000000000000")
(define now 1000000)

;;; ── PKCE S256 ─────────────────────────────────────────────────────────────────
(test-case "pkce-challenge is BASE64URL(SHA256(verifier)) and url-safe"
  (define v "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
  (check-equal? (pkce-challenge v) (base64url-encode (sha256-bytes (string->bytes/utf-8 v))))
  (check-false (regexp-match? #rx"[+/=]" (pkce-challenge v))))

;;; ── SsoSubjectKey injectivity (the cross-issuer collision, Risk 59) ───────────
(test-case "subject key is injective across the (issuer, subject) split"
  (check-not-equal? (sso-subject-key "https://a" "x|https://b")
                    (sso-subject-key "https://a|x" "https://b"))
  ;; stable + opaque (hex, no email inside)
  (check-equal? (sso-subject-key "https://accounts.google.com" "123")
                (sso-subject-key "https://accounts.google.com" "123"))
  (check-true (regexp-match? #px"^[0-9a-f]{64}$" (sso-subject-key "i" "s"))))

;;; ── EmailClaim: VerifiedEmail needs a positive signal ─────────────────────────
(test-case "email-claim constructs VerifiedEmail only on a real boolean #t"
  (define-values (t1 _v1) (email-claim "a@x.com" #t))   (check-equal? t1 'verified)
  (define-values (t2 _v2) (email-claim "a@x.com" #f))   (check-equal? t2 'unverified)
  (define-values (t3 _v3) (email-claim "a@x.com" "true")) (check-equal? t3 'unverified) ; string, not bool
  (define-values (t4 _v4) (email-claim "a@x.com" 'null)) (check-equal? t4 'unverified)
  (define-values (t5 _v5) (email-claim "" #t))          (check-equal? t5 'none)
  (define-values (t6 _v6) (email-claim #f #t))          (check-equal? t6 'none))

;;; ── Domain restriction (VerifiedEmail-only, normalized) ───────────────────────
(test-case "allowedEmailDomains: empty ⇒ open; verified member ⇒ ok; else refused"
  (check-true  (email-domain-allowed? 'verified "a@ACME.com" '()))          ; empty = no restriction
  (check-true  (email-domain-allowed? 'verified "a@ACME.com" '("acme.com")));  case-insensitive
  (check-false (email-domain-allowed? 'unverified "a@acme.com" '("acme.com"))) ; unverified refused
  (check-false (email-domain-allowed? 'none "a@acme.com" '("acme.com")))
  (check-false (email-domain-allowed? 'verified "a@evil.com" '("acme.com")))
  ;; Risk 62: FQDN-root canonicalisation — a trailing dot on EITHER side matches.
  (check-true  (email-domain-allowed? 'verified "a@acme.com." '("acme.com")))
  (check-true  (email-domain-allowed? 'verified "a@acme.com" '("acme.com.")))
  ;; Risk 62: a homoglyph domain (Cyrillic а, U+0430) is a DIFFERENT domain,
  ;; refused fail-closed against an ASCII allow-list.
  (check-false (email-domain-allowed? 'verified "a@\u0430cme.com" '("acme.com"))))

(test-case "allowedHostedDomains: absent hd claim is a refusal, not a pass"
  (check-true  (hosted-domain-allowed? "acme.com" '()))
  (check-true  (hosted-domain-allowed? "ACME.com" '("acme.com")))
  (check-false (hosted-domain-allowed? #f '("acme.com")))
  (check-false (hosted-domain-allowed? "" '("acme.com")))
  (check-false (hosted-domain-allowed? "evil.com" '("acme.com")))
  (check-true  (hosted-domain-allowed? "acme.com." '("acme.com")))          ; trailing dot
  (check-false (hosted-domain-allowed? "\u0430cme.com" '("acme.com"))))     ; homoglyph refused

;;; ── OIDC claim validation ─────────────────────────────────────────────────────
(define (base-claims #:iss [iss "https://issuer"] #:aud [aud "client-1"]
                     #:nonce [nonce "N"] #:extra [extra (hasheq)])
  (for/fold ([h (hasheq 'iss iss 'aud aud 'nonce nonce 'sub "user-1"
                        'exp (+ now 300) 'iat now)])
            ([(k v) (in-hash extra)])
    (hash-set h k v)))

(define (validate h #:tenants [tenants '()] #:issuer [issuer "https://issuer"])
  (validate-oidc-claims h #:issuer issuer #:client-id "client-1"
                        #:nonce "N" #:now now #:allowed-tenants tenants))

(test-case "a well-formed ID token validates"
  (check-equal? (validate (base-claims)) #t))

(test-case "iss / aud / nonce / exp / iat failures are each caught"
  (check-true (string? (validate (base-claims #:iss "https://evil"))))
  (check-true (string? (validate (base-claims #:aud "someone-else"))))
  (check-true (string? (validate (base-claims #:nonce "WRONG"))))
  (check-true (string? (validate (hash-remove (base-claims) 'nonce))))
  (check-true (string? (validate (base-claims #:extra (hasheq 'exp (- now 300)))))) ; expired
  (check-true (string? (validate (base-claims #:extra (hasheq 'iat (+ now 100000)))))) ; future iat
  (check-true (string? (validate (hash-remove (base-claims) 'sub)))))               ; no subject

(test-case "aud as an array containing the client id is accepted; azp must match"
  (check-equal? (validate (base-claims #:aud (list "other" "client-1"))) #t)
  (check-true (string? (validate (base-claims #:extra (hasheq 'azp "not-us")))))
  (check-equal? (validate (base-claims #:extra (hasheq 'azp "client-1"))) #t))

;;; ── Entra multi-tenant issuer trap ────────────────────────────────────────────
(test-case "templated issuer with empty allowedTenants is refused"
  (define tmpl "https://login.microsoftonline.com/{tenantid}/v2.0")
  (check-true (string? (validate (base-claims #:iss tmpl) #:issuer tmpl #:tenants '())))
  ;; supplied tid must be in allowedTenants AND the iss must be the substituted form
  (define good-iss "https://login.microsoftonline.com/TENANT-A/v2.0")
  (check-equal?
   (validate (base-claims #:iss good-iss #:extra (hasheq 'tid "TENANT-A"))
             #:issuer tmpl #:tenants '("TENANT-A"))
   #t)
  (check-true (string?
   (validate (base-claims #:iss good-iss #:extra (hasheq 'tid "TENANT-B"))
             #:issuer tmpl #:tenants '("TENANT-A"))))          ; tid not allowed
  (check-true (string?
   (validate (base-claims #:iss "https://login.microsoftonline.com/OTHER/v2.0"
                          #:extra (hasheq 'tid "TENANT-A"))
             #:issuer tmpl #:tenants '("TENANT-A")))))         ; iss/tid disagree

;;; ── extraAuthorizeParams reserved-name rejection + encoding ───────────────────
(test-case "reserved authorize params are rejected; values are percent-encoded"
  (check-equal? (extra-params-reserved-violation '(("prompt" . "consent"))) #f)
  (check-equal? (extra-params-reserved-violation '(("redirect_uri" . "x"))) "redirect_uri")
  (check-exn exn:fail? (lambda () (build-authorize-url "https://a/auth" '() '(("state" . "x")))))
  (define url (build-authorize-url "https://a/auth"
                                   '(("scope" . "openid email") ("state" . "s&x"))
                                   '(("prompt" . "consent"))))
  (check-true (regexp-match? #rx"scope=openid%20email" url))
  (check-true (regexp-match? #rx"state=s%26x" url))     ; the & is encoded, cannot smuggle a param
  (check-true (regexp-match? #rx"[?]" url)))

;;; ── __Host-oauth cookie: integrity + rotation + segment binding ───────────────
(define (seal seg) (oauth-cookie-seal (hasheq 'seg seg 'nonce "N" 'v "verifier" 'ts now) KEY))

(test-case "a sealed cookie opens with the right key + segment"
  (define c (seal "github"))
  (define f (oauth-cookie-open c "github" (list KEY #f)))
  (check-true (hash? f))
  (check-equal? (hash-ref f 'nonce) "N"))

(test-case "a tampered payload, wrong segment, or wrong key all fail"
  (define c (seal "github"))
  ;; wrong segment (cookie minted at one clause, presented at another)
  (check-false (oauth-cookie-open c "google" (list KEY #f)))
  ;; wrong key
  (check-false (oauth-cookie-open c "github" (list KEY2 #f)))
  ;; tampered payload (flip a char in the b64 half)
  (define bad (string-append "x" (substring c 1)))
  (check-false (oauth-cookie-open bad "github" (list KEY #f)))
  ;; a hand-built cookie with a chosen nonce and no MAC key must not open
  (define forged (string-append (base64url-encode (jsexpr->bytes (hasheq 'seg "github" 'nonce "attacker"))) ".AAAA"))
  (check-false (oauth-cookie-open forged "github" (list KEY #f))))

(test-case "rotation overlap: a cookie under the previous key still opens"
  (define c (oauth-cookie-seal (hasheq 'seg "github" 'nonce "N") KEY2))
  (check-true (hash? (oauth-cookie-open c "github" (list KEY KEY2))))  ; current, previous
  (check-false (oauth-cookie-open c "github" (list KEY #f))))          ; previous slot empty

(require json (only-in "../tesl/crypto.rkt" base64url-encode))

;;; ── provider defaults + synthesized issuer ────────────────────────────────────
(test-case "sso-defaults: minimal scopes, right kind + fields per provider"
  (define g (sso-defaults 'Google "id" "sec"))
  (check-equal? (hash-ref g 'kind) 'oidc)
  (check-equal? (hash-ref g 'scopes) '("openid" "email" "profile"))
  (define gh (sso-defaults 'GitHub "id" "sec"))
  (check-equal? (hash-ref gh 'kind) 'oauth2)
  (check-equal? (hash-ref gh 'scopes) '("user:email"))
  (check-equal? (hash-ref gh 'email-verified-field) #f) ; /user email is unverified
  (define d (sso-defaults 'Discord "id" "sec"))
  (check-equal? (hash-ref d 'email-verified-field) "verified")
  (check-exn exn:fail? (lambda () (sso-defaults 'Facebook "id" "sec"))))

(test-case "synthesized issuer is scheme+host, stable across path/version drift"
  (check-equal? (synthesize-issuer "https://api.github.com/user") "https://api.github.com")
  (check-equal? (synthesize-issuer "https://discord.com/api/v10/users/@me") "https://discord.com")
  (check-equal? (synthesize-issuer "https://discord.com/api/v6/users/@me") "https://discord.com"))

;;; ── single-use state ──────────────────────────────────────────────────────────
(test-case "state is single-use within a process"
  (define s (make-spent-state-set))
  (check-true  (state-spend! s "abc" now))
  (check-false (state-spend! s "abc" now))       ; replay refused
  (check-true  (state-spend! s "def" now)))

;;; ── SSRF preflight on literal-IP hosts ────────────────────────────────────────
(test-case "url-ssrf-violation refuses literal-IP metadata/loopback hosts"
  (check-true (string? (url-ssrf-violation "https://169.254.169.254/latest/meta-data")))
  (check-true (string? (url-ssrf-violation "http://127.0.0.1/token")))
  (check-false (url-ssrf-violation "https://accounts.google.com/o/oauth2/token"))) ; hostname passes preflight

;; Risk 2/3/18/32: the typed-identity accessors.  Sso.email returns the VERIFIED
;; address ONLY (Nothing for unverified/none), so an app cannot trust one.
(test-case "Sso.email/tenant/claim: verified-only email, tenant, single claim"
  (define verified (hasheq 'subject "s" 'email-tag 'verified 'email "a@x.com"
                           'tenant "t1" 'claims (hasheq 'role "admin")))
  (define unverified (hasheq 'subject "s" 'email-tag 'unverified 'email "a@x.com" 'claims (hasheq)))
  (define none (hasheq 'subject "s" 'email-tag 'none 'claims (hasheq)))
  (check-equal? (Sso.email verified) (Something "a@x.com"))
  (check-equal? (Sso.email unverified) Nothing "an unverified email is never exposed")
  (check-equal? (Sso.email none) Nothing)
  (check-equal? (Sso.tenant verified) (Something "t1"))
  (check-equal? (Sso.tenant none) Nothing)
  (check-equal? (Sso.claim verified "role") (Something "admin"))
  (check-equal? (Sso.claim verified "missing") Nothing))
