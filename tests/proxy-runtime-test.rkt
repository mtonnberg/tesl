#lang racket/base

;;; Item A (#50.2): Tesl.Proxy runtime — Proxy.verifyBinding mints ProxyBound on
;;; a constant-time match, and a check-fail (no fact) on a mismatch.

(require rackunit
         (only-in "../dsl/private/evidence.rkt" check-ok? check-fail? check-ok-facts)
         (only-in "../tesl/crypto.rkt" Secret)
         (only-in "../tesl/proxy.rkt" Proxy.verifyBinding))

(define secret "proxy-shared-secret-000000000000")

(test-case "a matching binding mints ProxyBound"
  (define r (Proxy.verifyBinding (Secret secret) secret))
  (check-true (check-ok? r) "the verification succeeds")
  (check-true
   (for/or ([f (in-list (check-ok-facts r))]) (and (pair? f) (eq? (car f) 'ProxyBound)))
   "the ok result carries a ProxyBound fact"))

(test-case "a mismatched binding is refused, with no fact"
  (define r (Proxy.verifyBinding (Secret secret) "not-the-secret"))
  (check-true (check-fail? r) "the verification fails closed"))

(test-case "an empty presented binding does not match a real secret"
  (check-true (check-fail? (Proxy.verifyBinding (Secret secret) ""))))
