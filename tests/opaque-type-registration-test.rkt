#lang racket/base

;;; SYSTEMIC invariant (not SSO-specific) — closes the class of bug the SSO
;;; end-to-end test surfaced.
;;;
;;; The runtime type-check for a `define/pow` return/param is FAIL-CLOSED
;;; (dsl/types.rkt `runtime-type-satisfied?`): a type whose name resolves to NO
;;; runtime predicate is REJECTED.  So every opaque/nominal stdlib type that can
;;; appear in a checked position MUST resolve a runtime predicate, or a Tesl fn
;;; declaring `-> T` 500s at runtime.
;;;
;;; `define-newtype` (Secret, PasswordHash, Signature, JwtToken, PosixMillis, …)
;;; AUTO-registers a predicate, so those are safe for free.  A stdlib opaque type
;;; that is NOT a newtype — a bare `TCon` whose runtime value is a plain hash or
;;; string — has NO auto-registration and must call
;;; `register-runtime-type/runtime!` explicitly.  The Tesl.Sso types
;;; (SsoConnection / SsoIdentity / SsoSubjectKey) were the FIRST such non-newtype
;;; opaque types, and shipped without predicates: a `-> SsoConnection` fn
;;; compiled and `raco make`-loaded but rejected its own return at runtime — only
;;; caught once a compiled program actually ran (e2e/sso).
;;;
;;; This test pins the invariant so the class cannot regress: any opaque nominal
;;; stdlib type added without a resolvable predicate fails HERE, not in prod.

(require rackunit
         (only-in "../dsl/types.rkt" runtime-type-predicate)
         ;; requiring the owning modules runs their registrations (explicit for
         ;; the SSO types, define-newtype-auto for the crypto/jwt ones).
         (only-in "../tesl/sso.rkt" Sso.defaults)
         (only-in "../tesl/crypto.rkt" Secret)
         (only-in "../tesl/jwt.rkt" jwt))

(define (resolves? name) (and (runtime-type-predicate name) #t))

;; The at-risk class: opaque stdlib types that are NOT newtypes, so nothing
;; auto-registers a predicate.  (Source of truth: Stdlib_config_names.sso_opaque_types.)
(test-case "non-newtype opaque stdlib types resolve a runtime predicate"
  (for ([t (in-list '(SsoConnection SsoIdentity SsoSubjectKey))])
    (check-true (resolves? t)
                (format "~a resolves no runtime predicate: a `-> ~a` fn will be rejected \
fail-closed at runtime.  Add (register-runtime-type/runtime! '~a <pred>) in its \
owning stdlib module." t t t))))

;; Controls: the newtype opaque types are covered automatically by define-newtype.
(test-case "newtype opaque stdlib types resolve too (auto-registered)"
  (for ([t (in-list '(Secret PasswordHash Signature JwtToken))])
    (check-true (resolves? t) (format "~a must resolve a runtime predicate" t))))
