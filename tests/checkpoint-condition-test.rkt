#lang racket

;; checkpoint-condition-test.rkt — unit tests for conditional-breakpoint logic
;; added to dsl/debug/checkpoint.rkt (eval-bp-condition / eval-hit-condition /
;; bp-record machinery).  These exercise the safe expression evaluator that gates
;; conditional and hit-conditional breakpoints WITHOUT shelling into the OCaml
;; compiler or eval-ing arbitrary Racket.

(require rackunit
         racket/set
         "../dsl/debug/checkpoint.rkt")

;; A locals alist as produced by the emitter: (list (cons 'name raw-value) ...)
(define (locals . pairs) pairs)

;; ── eval-bp-condition: comparisons ────────────────────────────────────────────

(test-case "condition: numeric > true"
  (check-true (eval-bp-condition "x > 5" (locals (cons 'x 10)))))

(test-case "condition: numeric > false"
  (check-false (eval-bp-condition "x > 5" (locals (cons 'x 3)))))

(test-case "condition: >= boundary"
  (check-true (eval-bp-condition "x >= 5" (locals (cons 'x 5))))
  (check-false (eval-bp-condition "x >= 5" (locals (cons 'x 4)))))

(test-case "condition: <= and <"
  (check-true (eval-bp-condition "n <= 0" (locals (cons 'n 0))))
  (check-false (eval-bp-condition "n < 0" (locals (cons 'n 0)))))

(test-case "condition: equality numeric"
  (check-true (eval-bp-condition "x == 42" (locals (cons 'x 42))))
  (check-false (eval-bp-condition "x == 42" (locals (cons 'x 41)))))

(test-case "condition: inequality"
  (check-true (eval-bp-condition "x != 0" (locals (cons 'x 7))))
  (check-false (eval-bp-condition "x != 0" (locals (cons 'x 0)))))

(test-case "condition: string equality"
  (check-true (eval-bp-condition "name == \"alice\"" (locals (cons 'name "alice"))))
  (check-false (eval-bp-condition "name == \"alice\"" (locals (cons 'name "bob")))))

(test-case "condition: string inequality"
  (check-true (eval-bp-condition "name != \"alice\"" (locals (cons 'name "bob")))))

;; ── boolean operators ─────────────────────────────────────────────────────────

(test-case "condition: && both true"
  (check-true (eval-bp-condition "x > 0 && x < 10" (locals (cons 'x 5)))))

(test-case "condition: && one false"
  (check-false (eval-bp-condition "x > 0 && x < 10" (locals (cons 'x 50)))))

(test-case "condition: || short path"
  (check-true (eval-bp-condition "x < 0 || x > 100" (locals (cons 'x 200))))
  (check-false (eval-bp-condition "x < 0 || x > 100" (locals (cons 'x 50)))))

(test-case "condition: ! negation"
  (check-true (eval-bp-condition "!(x == 0)" (locals (cons 'x 1))))
  (check-false (eval-bp-condition "!(x == 0)" (locals (cons 'x 0)))))

;; ── arithmetic in conditions ──────────────────────────────────────────────────

(test-case "condition: arithmetic + comparison"
  (check-true (eval-bp-condition "x + 1 == 10" (locals (cons 'x 9)))))

(test-case "condition: modulo (even)"
  (check-true (eval-bp-condition "x % 2 == 0" (locals (cons 'x 4))))
  (check-false (eval-bp-condition "x % 2 == 0" (locals (cons 'x 5)))))

(test-case "condition: multiplication precedence"
  (check-true (eval-bp-condition "x * 2 + 1 == 7" (locals (cons 'x 3)))))

(test-case "condition: parens override precedence"
  (check-true (eval-bp-condition "x * (2 + 1) == 9" (locals (cons 'x 3)))))

;; ── multiple locals ───────────────────────────────────────────────────────────

(test-case "condition: two locals compared"
  (check-true (eval-bp-condition "a < b" (locals (cons 'a 1) (cons 'b 2))))
  (check-false (eval-bp-condition "a < b" (locals (cons 'a 5) (cons 'b 2)))))

;; ── GDP unwrapping: the evaluator must see through wrappers ────────────────────
;; We can't easily construct named-value here without the evidence module, but a
;; bare integer (the common erased case) must work — covered above.  Booleans:

(test-case "condition: bare boolean local truthy"
  (check-true (eval-bp-condition "flag" (locals (cons 'flag #t))))
  (check-false (eval-bp-condition "flag" (locals (cons 'flag #f)))))

(test-case "condition: literal true/false keywords"
  (check-true (eval-bp-condition "true" (locals)))
  (check-false (eval-bp-condition "false" (locals))))

;; ── fail-open semantics ───────────────────────────────────────────────────────

(test-case "condition: blank/absent → fire (no condition)"
  (check-true (eval-bp-condition #f (locals)))
  (check-true (eval-bp-condition "" (locals)))
  (check-true (eval-bp-condition "   " (locals))))

(test-case "condition: unbound identifier → fail open (#t)"
  (check-true (eval-bp-condition "nonexistent > 5" (locals (cons 'x 1)))))

(test-case "condition: garbage syntax → fail open (#t)"
  (check-true (eval-bp-condition ")(@#$" (locals)))
  (check-true (eval-bp-condition "x >" (locals (cons 'x 1)))))

;; ── eval-hit-condition ─────────────────────────────────────────────────────────

(test-case "hit: bare N means >= N"
  (check-false (eval-hit-condition "3" 1))
  (check-false (eval-hit-condition "3" 2))
  (check-true  (eval-hit-condition "3" 3))
  (check-true  (eval-hit-condition "3" 4)))

(test-case "hit: == N exact"
  (check-false (eval-hit-condition "== 2" 1))
  (check-true  (eval-hit-condition "== 2" 2))
  (check-false (eval-hit-condition "== 2" 3)))

(test-case "hit: > N"
  (check-false (eval-hit-condition "> 2" 2))
  (check-true  (eval-hit-condition "> 2" 3)))

(test-case "hit: <= N"
  (check-true  (eval-hit-condition "<= 2" 2))
  (check-false (eval-hit-condition "<= 2" 3)))

(test-case "hit: % N every Nth"
  (check-false (eval-hit-condition "% 3" 1))
  (check-false (eval-hit-condition "% 3" 2))
  (check-true  (eval-hit-condition "% 3" 3))
  (check-true  (eval-hit-condition "% 3" 6)))

(test-case "hit: blank/absent → fire"
  (check-true (eval-hit-condition #f 1))
  (check-true (eval-hit-condition "" 5)))

(test-case "hit: garbage → fail open (#t)"
  (check-true (eval-hit-condition "abc" 1)))

;; ── bp-record machinery ─────────────────────────────────────────────────────────

(test-case "bp-record: bare line has no condition/hitCondition"
  (define r (make-bp-record 10))
  (check-equal? (bp-record-line r) 10)
  (check-false (bp-record-condition r))
  (check-false (bp-record-hit-condition r))
  (check-equal? (unbox (bp-record-hit-count r)) 0))

(test-case "bp-record: blank condition normalised to #f"
  (define r (make-bp-record 10 "" "  "))
  (check-false (bp-record-condition r))
  (check-false (bp-record-hit-condition r)))

(test-case "bp-record: condition/hitCondition retained"
  (define r (make-bp-record 7 "x > 5" ">= 3"))
  (check-equal? (bp-record-condition r) "x > 5")
  (check-equal? (bp-record-hit-condition r) ">= 3"))

(test-case "file-breakpoint-lines: from record list"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "/f.tesl"
             (list (make-bp-record 5) (make-bp-record 10 "x > 0")))
  (define s (file-breakpoint-lines breakpoints "/f.tesl"))
  (check-true (set-member? s 5))
  (check-true (set-member? s 10))
  (check-false (set-member? s 99))
  (hash-clear! breakpoints))

(test-case "file-breakpoint-lines: tolerates legacy seteq"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "/legacy.tesl" (seteq 3 4))
  (define s (file-breakpoint-lines breakpoints "/legacy.tesl"))
  (check-true (set-member? s 3))
  (check-true (set-member? s 4))
  (hash-clear! breakpoints))

(test-case "file-breakpoint-lines: missing file → empty set"
  (hash-clear! breakpoints)
  (check-equal? (set-count (file-breakpoint-lines breakpoints "/nope.tesl")) 0))

(displayln "\nAll checkpoint conditional-breakpoint unit tests complete.")
