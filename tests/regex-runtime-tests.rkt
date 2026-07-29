#lang racket

;;; Tesl.Regex runtime — the properties a Tesl-level test cannot express.
;;;
;;; The compile-time contract (pattern literals, VREGEX001-4) is covered by
;;; compiler/test/test_regex_surface.ml, and the happy-path semantics by
;;; example/learn/lesson75-regex-validation.tesl.  What is left, and what lives
;;; here, is the runtime's LAST LINE OF DEFENCE — reachable only by calling the
;;; runtime module directly, exactly as a program that bypassed the compiler
;;; would:
;;;
;;;   * the ReDoS BOUND.  A pathological pattern against hostile input must not
;;;     hang the process.  The compiler rejects `(a+)+` (VREGEX003), so the only
;;;     way to prove the runtime bound works is to hand it one here.
;;;   * the input-size bound.
;;;   * a pattern that does not compile fails loudly and cleanly.
;;;   * the capture-group shape `Regex.captures` promises.

(require rackunit
         rackunit/text-ui
         (only-in "../dsl/types.rkt" Something? Nothing? Something-value)
         "../tesl/regex.rkt")

(define (maybe->list m) (if (Something? m) (Something-value m) 'nothing))

(define regex-tests
  (test-suite
   "Tesl.Regex runtime"

   ;; ── The ReDoS bound (the reason this file exists) ───────────────────────
   ;;
   ;; `^(a+)+$` against 40 a's and a trailing `!` is the textbook exponential
   ;; backtracking case: Racket's matcher would explore 2^40 splits.  With a
   ;; 200 ms budget the call must come back as a clean error in roughly that
   ;; time — not in 2^40 steps, and not by wedging the process.
   (test-case "a pathological pattern against hostile input is bounded"
     (define hostile (string-append (make-string 40 #\a) "!"))
     (putenv "TESL_REGEX_TIMEOUT_MS" "200")
     (define t0 (current-inexact-milliseconds))
     (define raised
       (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
         (Regex.matches "^(a+)+$" hostile)
         #f))
     (define elapsed (- (current-inexact-milliseconds) t0))
     (putenv "TESL_REGEX_TIMEOUT_MS" "1000")
     (check-true (string? raised)
                 "the pathological match should have hit the deadline")
     (when (string? raised)
       (check-true (regexp-match? #rx"exceeded the 200 ms budget" raised)
                   (format "unexpected error message: ~a" raised)))
     ;; Generous ceiling: the point is "bounded", not "fast".  Without the
     ;; deadline this call does not return in the lifetime of the test run.
     (check-true (< elapsed 5000.0)
                 (format "took ~a ms — the deadline did not fire" elapsed)))

   ;; A safe pattern of the same shape must NOT be slowed down by the guard.
   (test-case "a well-behaved match is not affected by the deadline"
     (define big (make-string 20000 #\a))
     (check-true (Regex.matches "^[a-z]+$" big)))

   ;; ── The input bound ─────────────────────────────────────────────────────
   (test-case "an oversized input is refused with a clean error"
     (putenv "TESL_REGEX_MAX_INPUT_BYTES" "100")
     (define msg
       (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
         (Regex.matches "^[a-z]+$" (make-string 200 #\a))
         #f))
     (putenv "TESL_REGEX_MAX_INPUT_BYTES" "1048576")
     (check-true (and (string? msg)
                      (regexp-match? #rx"exceeds the 100-character" msg))
                 (format "expected an input-limit error, got: ~a" msg)))

   ;; ── A pattern that does not compile fails loudly ────────────────────────
   (test-case "an uncompilable pattern raises a clean Regex error"
     (define msg
       (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
         (Regex.matches "[a-z" "abc")
         #f))
     (check-true (and (string? msg) (regexp-match? #rx"invalid regex pattern" msg))
                 (format "expected an invalid-pattern error, got: ~a" msg)))

   ;; ── Semantics ───────────────────────────────────────────────────────────
   (test-case "matches is unanchored unless the pattern anchors itself"
     (check-true  (Regex.matches "[0-9]+" "abc123"))
     (check-false (Regex.matches "^[0-9]+$" "abc123"))
     (check-true  (Regex.matches "^[0-9]+$" "123")))

   (test-case "find returns the first match, findAll every match"
     (check-equal? (maybe->list (Regex.find "[0-9]+" "a12b345")) "12")
     (check-true   (Nothing? (Regex.find "[0-9]+" "abc")))
     (check-equal? (Regex.findAll "[0-9]+" "a12b345") (list "12" "345"))
     (check-equal? (Regex.findAll "[0-9]+" "abc") '()))

   (test-case "captures excludes the whole match and is total"
     (check-equal? (maybe->list (Regex.captures "^([a-z]+)@([a-z]+)$" "bob@ex"))
                   (list "bob" "ex"))
     ;; No capture groups → an empty list, not Nothing: the match succeeded.
     (check-equal? (maybe->list (Regex.captures "^[a-z]+$" "bob")) '())
     (check-true   (Nothing? (Regex.captures "^([a-z]+)$" "123")))
     ;; Every element is a String — the compile-time participation rule
     ;; (VREGEX004) is what lets the type say `List String`.
     (check-true (andmap string?
                         (maybe->list (Regex.captures "^([a-z]+)-([0-9]+)$" "ab-12")))))

   (test-case "replace rewrites every match and inserts the text literally"
     (check-equal? (Regex.replace "[0-9]" "a1b2c3" "#") "a#b#c#")
     (check-equal? (Regex.replace "[0-9]+" "x99y" "") "xy")
     ;; `\1`, `$1` and `&` in the replacement are ordinary characters: a
     ;; replacement built from user data can never become a substitution
     ;; directive.
     (check-equal? (Regex.replace "b" "abc" "\\1") "a\\1c")
     (check-equal? (Regex.replace "b" "abc" "&") "a&c")
     (check-equal? (Regex.replace "([a-z])" "ab" "$1") "$1$1"))

   (test-case "split behaves like String.split on a pattern"
     (check-equal? (Regex.split "," "a,b,c") (list "a" "b" "c"))
     (check-equal? (Regex.split "[,;]" "a,b;c") (list "a" "b" "c"))
     (check-equal? (Regex.split "," "a,,b") (list "a" "" "b"))
     (check-equal? (Regex.split "," "abc") (list "abc")))

   ;; ── Compiled patterns are memoised ──────────────────────────────────────
   (test-case "the same pattern string compiles once"
     (check-eq? (tesl-regex-compile "^[a-z]+$") (tesl-regex-compile "^[a-z]+$")))

   (test-case "the timeout is env-configurable"
     (putenv "TESL_REGEX_TIMEOUT_MS" "250")
     (check-equal? (tesl-regex-timeout-ms) 250)
     (putenv "TESL_REGEX_TIMEOUT_MS" "1000")
     (check-equal? (tesl-regex-timeout-ms) 1000))))

(module+ test
  (define failures (run-tests regex-tests))
  (when (> failures 0) (error 'regex-runtime-tests "~a failure(s)" failures)))
