#lang racket

;;; Tesl.Regex — regular expressions over String.
;;;
;;; The pattern of every function here is argument 1 and is a STRING LITERAL
;;; checked by the compiler (compiler/lib/regex_lint.ml, codes VREGEX001-4):
;;; it must parse in Tesl's subset of `pregexp`, it may not be able to backtrack
;;; catastrophically, and each of its capture groups must participate in every
;;; successful match.  There is no dynamic-pattern entry point in the surface.
;;;
;;; This module is nevertheless written as if none of that were true, because it
;;; is the last line of defence (audit gap L6 — resource exhaustion):
;;;
;;;   * every match runs under a WALL-CLOCK DEADLINE in its own thread
;;;     (TESL_REGEX_TIMEOUT_MS, default 1000).  Racket's matcher backtracks, and
;;;     its threads are preemptible, so a pathological pattern that somehow
;;;     reached the runtime costs one bounded slice instead of the process;
;;;   * the input is bounded (TESL_REGEX_MAX_INPUT_BYTES, default 1 MiB);
;;;   * a pattern that does not compile raises a clean `raise-user-error` rather
;;;     than escaping as a raw Racket exception.
;;;
;;; Compiled patterns are memoised, so the per-call cost is a hash lookup.

(require racket/string
         "../dsl/check.rkt"
         "../dsl/types.rkt")

(provide
 Regex.matches
 Regex.find
 Regex.findAll
 Regex.captures
 Regex.replace
 Regex.split
 ;; exported for the runtime test suite (tests/regex-runtime-tests.rkt)
 tesl-regex-timeout-ms
 tesl-regex-compile)

;; ── Helpers ─────────────────────────────────────────────────────────────────

;; Unwrap a (possibly proof-bearing, possibly newtype-wrapped) value to a plain
;; Racket string — same convention as tesl/string.rkt.
(define (raw-str s)
  (define v (raw-value s))
  (if (newtype-value? v) (newtype-value-value v) v))

(define (env-nat name default)
  (define v (getenv name))
  (define n (and v (string->number v)))
  (if (and n (exact-integer? n) (> n 0)) n default))

;; Wall-clock budget for ONE match/replace/split, in milliseconds.
(define (tesl-regex-timeout-ms) (env-nat "TESL_REGEX_TIMEOUT_MS" 1000))

;; Upper bound on the subject string, in characters.
(define (tesl-regex-max-input) (env-nat "TESL_REGEX_MAX_INPUT_BYTES" 1048576))

;; ── Pattern compilation (memoised, fail-loud) ───────────────────────────────

(define pattern-cache (make-hash))

(define (tesl-regex-compile pat)
  (hash-ref!
   pattern-cache pat
   (lambda ()
     (with-handlers
         ([exn:fail?
           (lambda (e)
             (raise-user-error
              'Regex
              (string-append
               "invalid regex pattern " (format "~s" pat) ": "
               (exn-message e)
               "\n  (patterns are normally checked at compile time — see VREGEX001)")))])
       (pregexp pat)))))

;; ── Bounded execution ───────────────────────────────────────────────────────
;;
;; Run `thunk` in its own Racket thread and give it at most the configured
;; budget.  Racket's regexp engine is written in Racket and its threads are
;; preemptible, so killing the thread genuinely stops a runaway match (verified
;; by tests/regex-runtime-tests.rkt).

(define (with-regex-budget who pat thunk)
  (define slot (box '(none)))
  (define worker
    (thread
     (lambda ()
       (set-box! slot
                 (with-handlers ([(lambda (_) #t) (lambda (e) (list 'exn e))])
                   (list 'ok (thunk)))))))
  (define budget (tesl-regex-timeout-ms))
  (cond
    [(sync/timeout (/ budget 1000.0) worker)
     (define r (unbox slot))
     (case (car r)
       [(ok) (cadr r)]
       [(exn) (raise (cadr r))]
       [else (raise-user-error 'Regex "internal error: no result from matcher")])]
    [else
     (kill-thread worker)
     (raise-user-error
      who
      (string-append
       "regex evaluation exceeded the " (number->string budget)
       " ms budget for pattern " (format "~s" pat)
       "\n  (raise TESL_REGEX_TIMEOUT_MS, or simplify the pattern)"))]))

(define (checked-input who s)
  (define str (raw-str s))
  (unless (string? str)
    (raise-user-error who "expected a String input"))
  (define cap (tesl-regex-max-input))
  (when (> (string-length str) cap)
    (raise-user-error
     who
     (string-append
      "input of " (number->string (string-length str))
      " characters exceeds the " (number->string cap)
      "-character regex input limit"
      "\n  (raise TESL_REGEX_MAX_INPUT_BYTES if this is intentional)")))
  str)

(define (run who pat-arg input-arg thunk-of)
  (define pat (raw-str pat-arg))
  (unless (string? pat)
    (raise-user-error who "expected a String pattern"))
  (define rx (tesl-regex-compile pat))
  (define input (checked-input who input-arg))
  (with-regex-budget who pat (lambda () (thunk-of rx input))))

;; ── The surface ─────────────────────────────────────────────────────────────

;; Regex.matches(pattern, input) -> Bool
;; True when the pattern matches ANYWHERE in the input.  Anchor with ^ and $ to
;; require a whole-string match.
(define (Regex.matches pat input)
  (run 'Regex.matches pat input
       (lambda (rx s) (and (regexp-match? rx s) #t))))

;; Regex.find(pattern, input) -> Maybe String
;; The text of the first match, or Nothing.
(define (Regex.find pat input)
  (run 'Regex.find pat input
       (lambda (rx s)
         (define m (regexp-match rx s))
         (if m (Something (car m)) Nothing))))

;; Regex.findAll(pattern, input) -> List String
;; The text of every non-overlapping match, left to right.
(define (Regex.findAll pat input)
  (run 'Regex.findAll pat input
       (lambda (rx s) (regexp-match* rx s))))

;; Regex.captures(pattern, input) -> Maybe (List String)
;; The capture groups of the first match, in source order, EXCLUDING the whole
;; match (use Regex.find for that).  A pattern with no capture groups yields
;; `Something []` on a match.
;;
;; The list is `List String`, not `List (Maybe String)`, because the compiler
;; rejects patterns whose capture groups can fail to participate (VREGEX004);
;; the `(or g "")` below is therefore unreachable for a compiler-checked
;; pattern and exists only so this module is total on its own.
(define (Regex.captures pat input)
  (run 'Regex.captures pat input
       (lambda (rx s)
         (define m (regexp-match rx s))
         (if m (Something (map (lambda (g) (or g "")) (cdr m))) Nothing))))

;; Regex.replace(pattern, input, replacement) -> String
;; Replaces EVERY match.  The replacement is inserted LITERALLY — `\1`, `$1` and
;; `&` are ordinary characters, not group references — so a replacement built
;; from user data can never be reinterpreted as a substitution directive.
(define (Regex.replace pat input replacement)
  (define repl (raw-str replacement))
  (unless (string? repl)
    (raise-user-error 'Regex.replace "expected a String replacement"))
  (run 'Regex.replace pat input
       (lambda (rx s) (regexp-replace* rx s (regexp-replace-quote repl)))))

;; Regex.split(pattern, input) -> List String
;; Splits on every match of the pattern.  Adjacent matches and matches at the
;; ends produce empty strings, exactly like String.split.
(define (Regex.split pat input)
  (run 'Regex.split pat input
       (lambda (rx s) (regexp-split rx s))))
