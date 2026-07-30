#lang racket/base

;;; Tesl.Sso — the stdlib surface for SSO (roadmap/next/ensure_sso_works.md,
;;; Phase 3).  A thin wrapper that exposes the flow runtime in dsl/sso.rkt under
;;; the dotted names the checker's Tesl.Sso module row imports.  The full `sso`
;;; server clause (route minting, onIdentity) is the remaining compiler-surface
;;; work; these are the "provider is a value" foundation it builds on.

(require (only-in "../dsl/sso.rkt" sso-defaults sso-oidc)
         (only-in "../dsl/types.rkt" register-runtime-type/runtime! Something Nothing))

;; Register runtime predicates for the opaque SSO types so a Tesl fn declaring
;; `-> SsoConnection` (etc.) passes the define/pow return-type check.  Without
;; these the connection hash a `-> SsoConnection` fn returns is rejected at
;; runtime, which the SSO end-to-end test (e2e/sso) is what surfaced.
(register-runtime-type/runtime! 'SsoConnection
  (lambda (v) (and (hash? v) (hash-has-key? v 'kind))))
(register-runtime-type/runtime! 'SsoIdentity
  (lambda (v) (and (hash? v) (hash-has-key? v 'subject))))
(register-runtime-type/runtime! 'SsoSubjectKey string?)

(provide Sso.defaults Sso.oidc Sso.keyText Sso.subject
         Sso.email Sso.tenant Sso.claim
         Sso.allowedEmailDomains Sso.allowedHostedDomains Sso.allowedTenants)

;; Sso.defaults : String -> String -> Secret -> SsoConnection
;; v1 takes the provider as a String name; the baked `SsoProvider` ADT lands with
;; the server clause.  The returned SsoConnection is opaque on the Tesl surface.
(define (Sso.defaults provider client-id client-secret)
  (define sym
    (cond
      [(string=? (string-downcase provider) "google")  'Google]
      [(string=? (string-downcase provider) "github")  'GitHub]
      [(string=? (string-downcase provider) "discord") 'Discord]
      [else (raise-user-error 'Sso.defaults
                              "unknown provider ~s (expected google, github or discord)" provider)]))
  (sso-defaults sym client-id client-secret))

;; Sso.oidc : String -> String -> Secret -> SsoConnection
;; A generic OpenID Connect connection by ISSUER URL (self-hosted Keycloak/dex,
;; Okta, Auth0, single-tenant Entra, …).  Discovers endpoints from the issuer;
;; same signature+claims trust argument as the blessed OIDC providers.
(define (Sso.oidc issuer client-id client-secret)
  (sso-oidc issuer client-id client-secret))

;; Sso.keyText : SsoSubjectKey -> String
;; The opaque identity key is already its hex text on the runtime side.
(define (Sso.keyText key) key)

;; Sso.subject : SsoIdentity -> String — the stable, issuer-scoped subject.
(define (Sso.subject identity) (hash-ref identity 'subject))

;; Typed-identity accessors (Risk 2/3/18/32).  Sso.email returns the VERIFIED
;; address ONLY — an app cannot obtain an unverified one, so it cannot trust it.
(define (Sso.email identity)
  (if (eq? (hash-ref identity 'email-tag #f) 'verified)
      (let ([e (hash-ref identity 'email #f)]) (if (string? e) (Something e) Nothing))
      Nothing))
(define (Sso.tenant identity)
  (let ([t (hash-ref identity 'tenant #f)])
    (if (and (string? t) (not (string=? t ""))) (Something t) Nothing)))
(define (Sso.claim identity name)
  (define claims (hash-ref identity 'claims (hash)))
  (define v (and (hash? claims) (hash-ref claims (string->symbol name) #f)))
  (if (string? v) (Something v) Nothing))

;; Domain-restriction builders (Risk 17/53): set the runtime-enforced allow-lists
;; on a connection.  The runtime (dsl/sso.rkt build-identity) already checks these
;; at the callback BEFORE onIdentity, VerifiedEmail-only; these just let a Tesl
;; program SET them.  Each is a pure record-update returning a new SsoConnection.
(define (Sso.allowedEmailDomains connection domains)
  (hash-set connection 'allowed-email-domains domains))
(define (Sso.allowedHostedDomains connection domains)
  (hash-set connection 'allowed-hosted-domains domains))
(define (Sso.allowedTenants connection tenants)
  (hash-set connection 'allowed-tenants tenants))
