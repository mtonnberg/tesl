#lang racket/base

;;; Phase 3 — the Tesl.Sso stdlib runtime surface (tesl/sso.rkt), the wrapper the
;;; `Sso.defaults` / `Sso.keyText` type rows resolve to.  (The seam test proves
;;; the names are provided; this proves they behave.)

(require rackunit
         (only-in "../tesl/sso.rkt" Sso.defaults Sso.keyText))

(test-case "Sso.defaults builds the right connection kind per provider"
  (check-equal? (hash-ref (Sso.defaults "github" "id" "sec") 'kind) 'oauth2)
  (check-equal? (hash-ref (Sso.defaults "discord" "id" "sec") 'kind) 'oauth2)
  (check-equal? (hash-ref (Sso.defaults "google" "id" "sec") 'kind) 'oidc))

(test-case "Sso.defaults is case-insensitive on the provider name"
  (check-equal? (hash-ref (Sso.defaults "GitHub" "id" "sec") 'kind) 'oauth2)
  (check-equal? (hash-ref (Sso.defaults "GOOGLE" "id" "sec") 'kind) 'oidc))

(test-case "Sso.defaults carries the client id/secret and minimal scopes"
  (define c (Sso.defaults "github" "my-id" "my-secret"))
  (check-equal? (hash-ref c 'client-id) "my-id")
  (check-equal? (hash-ref c 'client-secret) "my-secret")
  (check-equal? (hash-ref c 'scopes) '("user:email")))  ; minimal, not widened

(test-case "an unknown provider is a hard error, not a silent default"
  (check-exn exn:fail? (lambda () (Sso.defaults "facebook" "id" "sec")))
  (check-exn exn:fail? (lambda () (Sso.defaults "" "id" "sec"))))

(test-case "Sso.keyText renders the opaque key as its stored text"
  (check-equal? (Sso.keyText "abc123") "abc123"))
