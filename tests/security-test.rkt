#lang racket

;;; Security-hardening regression suite.
;;;
;;; One adversarial case per hardened class, asserting safe behaviour (the
;;; SQL-INJ-* precedent generalised).  These pin the unit-testable core of the
;;; runtime fixes landed under roadmap/completed/security_hardening_runtime_fixes:
;;;
;;;   F1  static-file path traversal       (dsl/web.rkt static-path-segments-safe?)
;;;   F4  JSON nesting-depth DoS            (dsl/types.rkt jsexpr->typed-value)
;;;   F5  predictable prefixed ids          (tesl/private/runtime.rkt)
;;;   F6  email header CRLF injection       (tesl/email.rkt)
;;;   F9  outbound HTTP header CRLF injection (tesl/http-client.rkt)
;;;   A3  env-read empty-ambient fail-open   (tesl/env.rkt ensure-env-capability!)
;;;
;;; Loaded by tests/internal-all.rkt (run under compile-examples.sh / ci.sh).

(require rackunit
         racket/string
         (only-in "../dsl/web.rkt"
                  static-path-segments-safe? static-path-segment-safe?)
         (only-in "../tesl/email.rkt" email-header-field-safe?)
         (only-in "../tesl/http-client.rkt" http-header-field-safe?)
         (only-in "../tesl/private/runtime.rkt" tesl-generate-prefixed-id)
         (only-in "../dsl/types.rkt" jsexpr->typed-value)
         (only-in "../tesl/env.rkt"
                  env envInt envString requireEnv envRead with-env-bootstrap)
         (only-in "../dsl/capability.rkt" current-capabilities))

(provide security-suite)

;; Build an n-deep `Dict String (Dict String (… Int))` type-datum + matching
;; nested object so jsexpr->typed-value recurses exactly n levels (dict VALUE
;; decode goes through the depth-counted wrapper; nested Lists decode structurally
;; without that recursion, so a dict is the right DoS vector to exercise).
(define (nested-dict-type n) (if (zero? n) 'Int (list 'Dict 'String (nested-dict-type (sub1 n)))))
(define (nested-dict-val  n) (if (zero? n) 5 (hash 'k (nested-dict-val (sub1 n)))))

(define security-suite
  (test-suite
   "security-hardening regression"

   ;; ── F1: static-file path traversal ──────────────────────────────────────
   (test-case "F1 ordinary static path segments are served"
     (check-true (static-path-segments-safe? '("index.html")))
     (check-true (static-path-segments-safe? '("css" "site.css")))
     (check-true (static-path-segments-safe? '("img" "logo.png")))
     ;; an ordinary name with a space is fine (not a separator/traversal token)
     (check-true (static-path-segments-safe? '("a file.txt")))
     (check-true (static-path-segments-safe? '())))   ; -> index.html

   (test-case "F1 traversal / separator segments are rejected (fail closed)"
     (check-false (static-path-segments-safe? '("..")))
     (check-false (static-path-segments-safe? '(".." "..")))
     (check-false (static-path-segments-safe? '("assets" ".." ".." "etc" "passwd")))
     (check-false (static-path-segments-safe? '(".")))
     (check-false (static-path-segment-safe? "a/b"))      ; embedded separator
     (check-false (static-path-segment-safe? "a\\b"))     ; backslash separator
     (check-false (static-path-segment-safe? "..")))

   ;; ── F4: JSON nesting-depth DoS ───────────────────────────────────────────
   (test-case "F4 shallow JSON decodes; deeply-nested JSON is rejected"
     ;; shallow (well under the 64-level cap) decodes without error
     (check-not-exn (lambda () (jsexpr->typed-value (nested-dict-type 8) (nested-dict-val 8) 'sec)))
     ;; deep (far past the cap) is rejected rather than exhausting the stack
     (check-exn #px"nesting too deep"
                (lambda () (jsexpr->typed-value (nested-dict-type 300) (nested-dict-val 300) 'sec))))

   ;; ── F5: unguessable prefixed ids (CSPRNG) ────────────────────────────────
   (test-case "F5 prefixed ids are unique, high-entropy hex, prefix preserved"
     (define ids (for/list ([_ (in-range 3000)]) (tesl-generate-prefixed-id "usr")))
     (check-equal? (length (remove-duplicates ids)) 3000 "all ids unique")
     (for ([id (in-list ids)])
       ;; prefix kept; 16 CSPRNG bytes -> 32 lowercase-hex chars; no seconds field
       (check-true (regexp-match? #px"^usr-[0-9a-f]{32}$" id)
                   (format "id ~s should be prefix + 32 hex" id))))

   (test-case "F5 two ids in quick succession differ in the random part"
     ;; the old impl was prefix-<current-seconds>-<random<=1e6>, so two calls in
     ;; the same second shared the seconds field and had only ~1e6 possibilities.
     (check-not-equal? (tesl-generate-prefixed-id "x") (tesl-generate-prefixed-id "x")))

   ;; ── F6: email header CRLF injection ──────────────────────────────────────
   (test-case "F6 email header fields reject CR/LF (header injection)"
     (check-true  (email-header-field-safe? "Welcome to the service"))
     (check-true  (email-header-field-safe? "user@example.com"))
     (check-false (email-header-field-safe? "Subject\r\nBcc: victim@evil.com"))
     (check-false (email-header-field-safe? "x\nInjected: 1"))
     (check-false (email-header-field-safe? "x\rInjected: 1")))

   ;; ── F9: outbound HTTP header CRLF injection ──────────────────────────────
   (test-case "F9 outbound HTTP header fields reject CR/LF (request splitting)"
     (check-true  (http-header-field-safe? "Bearer abc.def.ghi"))
     (check-true  (http-header-field-safe? "application/json"))
     (check-false (http-header-field-safe? "val\r\nHost: attacker.example"))
     (check-false (http-header-field-safe? "x\ny")))

   ;; ── A3: env read fails CLOSED under empty ambient ────────────────────────
   ;; The previous guard skipped the assertion whenever `current-capabilities`
   ;; was empty ('()) — a fail-open using ambient emptiness as a bootstrap proxy.
   ;; Now every env read asserts envRead UNCONDITIONALLY except inside the
   ;; explicit emitter-set `with-env-bootstrap` marker.
   (test-case "A3 env read with no envRead grant raises (fail-open closed)"
     (putenv "A3_SECRET" "leaked")
     ;; default ambient is empty '(): each accessor must now raise, not read.
     (check-exn exn:fail? (lambda () (requireEnv "A3_SECRET")))
     (check-exn exn:fail? (lambda () (env "A3_SECRET")))
     (check-exn exn:fail? (lambda () (envInt "A3_SECRET" 0)))
     (check-exn exn:fail? (lambda () (envString "A3_SECRET" "d"))))

   (test-case "A3 bootstrap-wrapped env read still loads (agent/config startup)"
     ;; the one-time module-load provider read the emitter wraps must succeed.
     (putenv "A3_SECRET" "leaked")
     (check-equal? (with-env-bootstrap (requireEnv "A3_SECRET")) "leaked"))

   (test-case "A3 env read with envRead grant succeeds"
     ;; a genuine grant (as established by main's with-capabilities /
     ;; serve's dispatch parameterize) lets the read through at runtime.
     (putenv "A3_SECRET" "leaked")
     (check-equal?
      (parameterize ([current-capabilities (list envRead)]) (requireEnv "A3_SECRET"))
      "leaked"))))

;; Allow standalone execution: `racket tests/security-test.rkt`
(module+ main
  (require rackunit/text-ui)
  (exit (if (zero? (run-tests security-suite)) 0 1)))
