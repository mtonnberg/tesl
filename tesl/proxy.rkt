#lang racket/base

;;; Tesl.Proxy — the authenticating-proxy edge binding (Item A,
;;; roadmap/next/ensure_sso_works.md #50.2).
;;;
;;; `Proxy.verifyBinding` is CHECK-SHAPED: it constant-time compares a
;;; request-supplied proxy-binding header value against a configured shared
;;; Secret, and mints `ProxyBound presented` ONLY on a match.  Because the fact
;;; can be obtained ONLY through this verification (it is not in
;;; proof_discharge's stdlib_auto_preds), a header-trusting `auth` block reaches
;;; its trust decision by way of a real check against STORED MATERIAL — the
;;; #50.2 discriminator: this needs no network-topology claim, unlike a bare
;;; `X-Auth-User`-style header assertion.

(require (only-in "../tesl/crypto.rkt" attach-proof-to constant-time-bytes=? secret->bytes)
         (only-in "../dsl/private/evidence.rkt" named-value-name check-ok check-fail))

(provide ProxyBound Proxy.verifyBinding)

;; ProxyBound — the proof-layer fact (a plain symbol, like Crypto's Authentic;
;; the proof is erased at runtime).
(define ProxyBound 'ProxyBound)

;; Proxy.verifyBinding : Secret -> String -> <check result minting ProxyBound>
;; Constant-time so the comparison time never leaks how much of the secret a
;; caller guessed (the same discipline as Crypto.checkSignature).
(define (Proxy.verifyBinding config presented)
  (if (constant-time-bytes=? (secret->bytes config)
                             (string->bytes/utf-8 presented))
      (let* ([nv   (attach-proof-to 'ProxyBound presented)]
             [subj (named-value-name nv)]
             [fact `(ProxyBound ,subj)])
        (check-ok nv (list fact) (hash subj presented)))
      (check-fail "proxy binding does not match" 401 '())))
