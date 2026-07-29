#lang racket

;;; Tesl.Int32 (NT-07) runtime edge cases — the inputs a Tesl-level test cannot
;;; conveniently reach, and the api-test request-path normalization from GitHub
;;; issue #45.
;;;
;;; The typed surface and the range rule are covered by
;;; compiler/test/test_int32_surface.ml (checker) and
;;; example/int32-boundary.tesl (end to end).  What is left here is the
;;; boundary-value behaviour of the runtime itself:
;;;   * every operation that CAN leave [-2^31, 2^31) answers Nothing at the exact
;;;     edge, and never wraps;
;;;   * `pow` bounds the exponent BEFORE `expt`, so an absurd exponent answers
;;;     Nothing instead of allocating a multi-gigabyte bignum to reach the same
;;;     answer;
;;;   * NaN / infinity convert to Nothing rather than crashing;
;;;   * a request path normalizes identically whether it arrives pre-split
;;;     (literal) or whole (computed), and a non-path value fails LOUD.

(require rackunit
         (only-in tesl/dsl/types Something? Nothing? Something-value)
         (only-in tesl/dsl/test-support api-test-path->segments+query)
         tesl/tesl/int32
         (prefix-in int: tesl/tesl/int))

(define INT32-MIN -2147483648)
(define INT32-MAX 2147483647)

(define (some? v) (Something? v))
(define (none? v) (Nothing? v))
(define (val v) (Something-value v))

;; ── The bounds are exactly the 32-bit range ─────────────────────────────────

(check-equal? Int32.minValue INT32-MIN)
(check-equal? Int32.maxValue INT32-MAX)

(check-true (some? (Int32.fromInt INT32-MIN)))
(check-true (some? (Int32.fromInt INT32-MAX)))
(check-true (none? (Int32.fromInt (add1 INT32-MAX))))
(check-true (none? (Int32.fromInt (sub1 INT32-MIN))))
;; A value beyond 2^53 (not JS-safe) is out of range like any other.
(check-true (none? (Int32.fromInt 9007199254740993)))

;; ── Saturating narrowing is total ───────────────────────────────────────────

(check-equal? (Int32.fromIntClamped 9007199254740993) INT32-MAX)
(check-equal? (Int32.fromIntClamped -9007199254740993) INT32-MIN)
(check-equal? (Int32.fromIntClamped 7) 7)
(check-equal? (Int32.fromIntClamped INT32-MAX) INT32-MAX)

;; ── Overflow answers Nothing at the exact edge (never wraps) ────────────────

(check-equal? (val (Int32.add INT32-MAX 0)) INT32-MAX)
(check-true (none? (Int32.add INT32-MAX 1)))
(check-true (none? (Int32.subtract INT32-MIN 1)))
(check-equal? (val (Int32.subtract 10 4)) 6)
(check-true (none? (Int32.multiply 65536 65536)))         ; 2^32
(check-equal? (val (Int32.multiply 46340 46340)) 2147395600)

;; negate/abs overflow on exactly one input: minValue has no positive twin.
(check-true (none? (Int32.negate INT32-MIN)))
(check-true (none? (Int32.abs INT32-MIN)))
(check-equal? (val (Int32.negate INT32-MAX)) (- INT32-MAX))
(check-equal? (val (Int32.abs -5)) 5)

;; ── pow bounds the exponent BEFORE computing ────────────────────────────────
;; |base| > 1 leaves the range within 31 doublings, so a huge exponent is
;; Nothing immediately — computing 2^2000000000 first would exhaust memory to
;; reach the same answer.
(check-true (none? (Int32.pow 2 2000000000)))
(check-true (none? (Int32.pow 2 31)))                     ; 2^31 = maxValue + 1
(check-equal? (val (Int32.pow 2 30)) 1073741824)
(check-equal? (val (Int32.pow 1 999999999)) 1)            ; |base| <= 1 never grows
(check-equal? (val (Int32.pow -1 999999999)) -1)
(check-equal? (val (Int32.pow 0 999999999)) 0)
(check-true (none? (Int32.pow 2 -1)))                     ; no integer power

;; Int.pow's negative exponent used to return the RATIONAL 1/2 while its
;; declared type is Int; it now fails loudly.
(check-exn exn:fail? (lambda () (int:Int.pow 2 -1)))
(check-equal? (int:Int.pow 2 10) 1024)

;; ── Division: the one out-of-range quotient, and remainder is always in range ─

;; divide/modulo consume an IsNonZero proof, so a RAW divisor is refused by the
;; runtime backstop (in compiled Tesl the divisor carries evidence from
;; `check Int32.nonZero`).  The quotient math — including the single
;; out-of-range quotient minValue / -1 — is covered at the Tesl level in
;; example/int32-boundary.tesl, where the proof exists.
(check-exn exn:fail? (lambda () (Int32.divide 9 2)))
(check-exn exn:fail? (lambda () (Int32.modulo 9 2)))
(check-exn exn:fail? (lambda () (Int32.divide 1 0)))
(check-exn exn:fail? (lambda () (Int32.modulo 1 0)))

;; ── Float conversions: NaN and the infinities are out of range, not crashes ──

(check-true (none? (Int32.fromFloat +nan.0)))
(check-true (none? (Int32.fromFloat +inf.0)))
(check-true (none? (Int32.fromFloat -inf.0)))
(check-equal? (val (Int32.fromFloat 3.9)) 3)              ; truncates toward zero
(check-equal? (val (Int32.fromFloat -3.9)) -3)
(check-true (none? (Int32.fromFloat 1e30)))
;; Every Int32 is exactly representable as a double (32 bits < 53).
(check-equal? (Int32.toFloat INT32-MAX) 2147483647.0)
(check-equal? (Int32.toFloat INT32-MIN) -2147483648.0)

;; ── Parsing rejects both malformed input and out-of-range values ────────────

(check-equal? (val (Int32.parse "42")) 42)
(check-equal? (val (Int32.parse "-2147483648")) INT32-MIN)
(check-true (none? (Int32.parse "2147483648")))
(check-true (none? (Int32.parse "nope")))

;; ── Range-closed operations stay Int32-shaped (a bare integer, not a Maybe) ──

(check-equal? (Int32.min 3 9) 3)
(check-equal? (Int32.max 3 9) 9)
(check-equal? (Int32.clamp 99 0 10) 10)
(check-equal? (Int32.clamp -99 0 10) 0)
(check-equal? (Int32.clamp 5 0 10) 5)

;; ── Queries ─────────────────────────────────────────────────────────────────

(check-equal? (Int32.toString -7) "-7")
(check-equal? (Int32.sign -7) -1)
(check-equal? (Int32.sign 0) 0)
(check-equal? (Int32.sign 7) 1)
(check-equal? (Int32.digits -1234) 4)
(check-true (Int32.isNegative -1))
(check-true (Int32.isPositive 1))
(check-true (Int32.isZero 0))
(check-true (Int32.isEven 2))
(check-true (Int32.isOdd 3))

;; ── Issue #45: one path normalization for literal and computed paths ─────────

(define (segs v) (car (api-test-path->segments+query 'test v)))
(define (query v) (cdr (api-test-path->segments+query 'test v)))

;; A literal path arrives pre-split; a computed one arrives whole.  Same answer.
(check-equal? (segs (list "todos" "1")) '("todos" "1"))
(check-equal? (segs "/todos/1") '("todos" "1"))
(check-equal? (segs "todos/1") '("todos" "1"))
(check-equal? (segs "/todos/1/") '("todos" "1"))
(check-equal? (segs "/") '())
(check-equal? (segs "") '())

;; `?…` is lifted to the query string for a computed path too.
(check-equal? (segs "/search?q=foo") '("search"))
(check-equal? (query "/search?q=foo") "q=foo")
(check-equal? (query "/search") "")
(check-equal? (query "/search?") "")
(check-equal? (query "/search?a=1&b=2") "a=1&b=2")
;; A pre-split literal carries no inline query (the emitter already lifted it).
(check-equal? (query (list "search")) "")

;; A number as a path segment source is coerced, not rejected — a JSON id is as
;; often a number as a string.
(check-equal? (segs 42) '("42"))

;; Anything that is not a path fails LOUD, naming the value, instead of letting
;; a contract violation surface from inside the HTTP layer as
;; "assertion did not hold".
(check-exn exn:fail? (lambda () (segs (list 1 2 3))))
(check-exn exn:fail? (lambda () (segs (hash 'a 1))))
(check-exn exn:fail? (lambda () (segs #f)))

(printf "int32-runtime-tests: all checks passed\n")
