#lang racket

;;; Stage 2 runtime-half suite (roadmap/next/ensure_sso_works.md):
;;; SessionPolicy (TTL / absolute cap), session-key rotation, and revocation at
;;; the renewal boundary — the parts of §Session policy / §Session key rotation /
;;; §Revocation at the renewal boundary that are independent of SSO and land in
;;; tesl/jwt.rkt ahead of the server-clause surface.

(require rackunit
         json
         net/base64
         racket/string
         ffi/unsafe ffi/unsafe/define openssl/libcrypto
         (file "../tesl/jwt.rkt")
         (only-in (file "../tesl/crypto.rkt") Secret)
         (file "../tesl/time.rkt")
         (file "../dsl/capability.rkt")
         (only-in (file "../dsl/private/evidence.rkt") check-fail? check-fail-status))

(define-ffi-definer define-libcrypto-t libcrypto)
(define-libcrypto-t EVP_sha256 (_fun -> _pointer))
(define-libcrypto-t HMAC
  (_fun _pointer _bytes _int _bytes _int _bytes (_ptr o _uint) -> _pointer))

(define (with-jwt thunk) (with-capabilities (jwt time) (thunk)))
(define (ok? x) (not (check-fail? x)))  ; a non-fail JWT.renew/verify result

;; Forge a token with a chosen header-less-`kid` header, chosen claims (incl. a
;; chosen `iat`) and a chosen HMAC key — verify recomputes over the token's own
;; header.payload, so a no-`kid` header verifies fine.
(define (b64url bstr)
  (regexp-replace* #rx"=+$"
   (string-replace (string-replace (bytes->string/utf-8 (base64-encode bstr #"")) "+" "-") "/" "_")
   ""))
(define (hmac-sha256 key-str data-str)
  (define out (make-bytes 32))
  (define key (string->bytes/utf-8 key-str))
  (define data (string->bytes/utf-8 data-str))
  (HMAC (EVP_sha256) key (bytes-length key) data (bytes-length data) out)
  out)
(define (forge claims key-str)
  (define hb (b64url (string->bytes/utf-8 "{\"alg\":\"HS256\",\"typ\":\"JWT\"}")))
  (define pb (b64url (string->bytes/utf-8 (jsexpr->string claims))))
  (define si (string-append hb "." pb))
  (JwtToken (string-append si "." (b64url (hmac-sha256 key-str si)))))

(define now (current-seconds))
(define KA (Secret "key-alpha"))
(define KB (Secret "key-beta"))

;;; ── SessionPolicy ─────────────────────────────────────────────────────────────

(test-case "default policy is StandardSession: 1h renewable / 12h absolute"
  (check-equal? (policy-ttl-seconds) 3600)
  (check-equal? (policy-absolute-max-seconds) (* 12 3600)))

(test-case "ShortSession is 15min renewable / 8h absolute — cap NOT a TTL multiple"
  (parameterize ([current-session-policy short-session])
    (check-equal? (policy-ttl-seconds) 900)
    (check-equal? (policy-absolute-max-seconds) (* 8 3600))
    ;; The whole point: the cap is named per policy, not derived as (* 12 ttl).
    (check-not-equal? (policy-absolute-max-seconds) (* 12 (policy-ttl-seconds)))))

(test-case "JWT.sign stamps exp from the ACTIVE policy's TTL"
  (define std (with-jwt (lambda () (JWT.sign (hasheq 'sub "u") KA))))
  (define std-exp (hash-ref (with-jwt (lambda () (JWT.verify std KA))) "exp"))
  (check-true (and (>= std-exp (+ now 3590)) (<= std-exp (+ now 3610))))
  (parameterize ([current-session-policy short-session])
    (define sh (with-jwt (lambda () (JWT.sign (hasheq 'sub "u") KA))))
    (define sh-exp (hash-ref (with-jwt (lambda () (JWT.verify sh KA))) "exp"))
    (check-true (and (>= sh-exp (+ now 890)) (<= sh-exp (+ now 910)))
                "ShortSession exp is ~15 minutes ahead")))

(test-case "renewal cap is the active policy's, not a TTL multiple"
  ;; A token ~9h old: past ShortSession's 8h cap, within StandardSession's 12h.
  (define old-tok (forge (hasheq 'sub "u" 'iat (- now (* 9 3600)) 'exp (+ now 60)) "key-alpha"))
  (check-true (ok? (with-jwt (lambda () (JWT.renew old-tok KA))))
              "9h-old token renewable under StandardSession (12h cap)")
  (parameterize ([current-session-policy short-session])
    (check-true (check-fail? (with-jwt (lambda () (JWT.renew old-tok KA))))
                "same token refused under ShortSession (8h cap)")))

;;; ── Session-key rotation ──────────────────────────────────────────────────────

(test-case "a token verifies under current OR previous key; neither ⇒ fail"
  (define tok-a (with-jwt (lambda () (JWT.sign (hasheq 'sub "u") KA))))
  ;; current = KA
  (check-true (hash? (with-jwt (lambda () (JWT.verify tok-a KA)))))
  ;; rotated: current = KB, previous = KA ⇒ still accepted
  (parameterize ([current-previous-session-key KA])
    (check-true (hash? (with-jwt (lambda () (JWT.verify tok-a KB))))
                "old token accepted via the previous-key slot"))
  ;; current = KB, no previous ⇒ rejected
  (check-true (check-fail? (with-jwt (lambda () (JWT.verify tok-a KB))))
              "old token rejected once the previous slot is empty")
  ;; a token under a key in NEITHER slot ⇒ rejected
  (define tok-c (forge (hasheq 'sub "u" 'iat now 'exp (+ now 3600)) "key-gamma"))
  (parameterize ([current-previous-session-key KA])
    (check-true (check-fail? (with-jwt (lambda () (JWT.verify tok-c KB)))))))

(test-case "renewal re-signs under the CURRENT key, draining the previous slot"
  (define tok-a (with-jwt (lambda () (JWT.sign (hasheq 'sub "u") KA))))
  (define renewed
    (parameterize ([current-previous-session-key KA])
      (with-jwt (lambda () (JWT.renew tok-a KB)))))
  (check-true (ok? renewed))
  ;; The renewed token verifies under the CURRENT key alone (no previous set).
  (check-true (hash? (with-jwt (lambda () (JWT.verify renewed KB))))
              "renewed token is on the current key")
  (check-true (check-fail? (with-jwt (lambda () (JWT.verify renewed KA))))
              "renewed token is NOT on the old key"))

;;; ── Revocation at the renewal boundary ────────────────────────────────────────

(test-case "absent hook ⇒ renewal behaves exactly as today"
  (define tok (with-jwt (lambda () (JWT.sign (hasheq 'sub "u") KA))))
  (check-true (ok? (with-jwt (lambda () (JWT.renew tok KA))))))

(test-case "hook returning #t denies the renewal (fail-closed)"
  (define tok (with-jwt (lambda () (JWT.sign (hasheq 'sub "u1") KA))))
  (parameterize ([current-session-revoked-hook (lambda (sub iat) (string=? sub "u1"))])
    (define r (with-jwt (lambda () (JWT.renew tok KA))))
    (check-true (check-fail? r))
    (check-equal? (check-fail-status r) 401)))

(test-case "a raising hook also denies (fail-closed)"
  (define tok (with-jwt (lambda () (JWT.sign (hasheq 'sub "u1") KA))))
  (parameterize ([current-session-revoked-hook (lambda (sub iat) (error "db down"))])
    (check-true (check-fail? (with-jwt (lambda () (JWT.renew tok KA)))))))

(test-case "revoke-before-issuedAt: an older token denied while a newer renews"
  (define old-tok (forge (hasheq 'sub "u1" 'iat (- now 100) 'exp (+ now 3600)) "key-alpha"))
  (define new-tok (forge (hasheq 'sub "u1" 'iat now         'exp (+ now 3600)) "key-alpha"))
  (define cutoff (- now 50)) ; "log out everything issued before cutoff"
  (parameterize ([current-session-revoked-hook (lambda (sub iat) (< iat cutoff))])
    (check-true (check-fail? (with-jwt (lambda () (JWT.renew old-tok KA))))
                "token issued before the cutoff is denied")
    (check-true (ok? (with-jwt (lambda () (JWT.renew new-tok KA))))
                "token issued at/after the cutoff renews")))

(test-case "the hook is consulted at RENEW only, never at VERIFY"
  (define tok (with-jwt (lambda () (JWT.sign (hasheq 'sub "u1") KA))))
  (define calls (box 0))
  (parameterize ([current-session-revoked-hook
                  (lambda (sub iat) (set-box! calls (add1 (unbox calls))) #f)])
    (with-jwt (lambda () (JWT.verify tok KA)))
    (check-equal? (unbox calls) 0 "verify must not read the revocation hook")
    (with-jwt (lambda () (JWT.renew tok KA)))
    (check-equal? (unbox calls) 1 "renew consults the hook exactly once")))
