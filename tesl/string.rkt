#lang racket

(require racket/string
         "../dsl/check.rkt"
         "../dsl/types.rkt"
         (only-in "../dsl/private/evidence.rkt" detached-proof check-ok check-fail)
         (only-in "../dsl/private/check-runtime.rkt" attach))

;; Polyfill: find first occurrence index of `sub` in `s`, or #f
(define (string-search s sub)
  (define positions (regexp-match-positions (regexp-quote sub) s))
  (and positions (caar positions)))

;; ── Proof predicate names exported for documentation / annotation use ──────
;; These symbols can be used in Tesl type annotations:
;;   s ::: IsTrimmed s        (string has no leading/trailing whitespace)
;;   s ::: IsUpperCase s      (string is entirely uppercase)
;;   s ::: IsLowerCase s      (string is entirely lowercase)
;;   n ::: IsNonNegative n    (length/count is always >= 0)
;;   s ::: IsNonEmpty s       (string is non-empty; from String.requireNonEmpty)
(provide
 IsTrimmed IsUpperCase IsLowerCase IsNonNegative IsNonEmpty
 String.length
 String.isEmpty
 String.startsWith
 String.endsWith
 String.contains
 String.toUpper
 String.toLower
 String.trim
 String.trimLeft
 String.trimRight
 String.split
 String.join
 String.replace
 String.slice
 String.concat
 String.repeat
 String.reverse
 String.toInt
 String.toFloat
 String.fromInt
 String.fromFloat
 String.lines
 String.words
 String.padLeft
 String.padRight
 String.dropPrefix
 String.dropSuffix
 String.indexOf)

;; Proof predicate name symbols
(define IsTrimmed     'IsTrimmed)
(define IsUpperCase   'IsUpperCase)
(define IsLowerCase   'IsLowerCase)
(define IsNonNegative 'IsNonNegative)
(define IsNonEmpty    'IsNonEmpty)

;; Helper: unwrap a (possibly proof-bearing) value to a plain Racket string
(define (raw-str s)
  (define v (raw-value s))
  (if (newtype-value? v) (newtype-value-value v) v))

;; Helper: attach a proof predicate (symbol) to a value, returning a named-value
(define (attach-proof-to pred-name value)
  (define nv (ensure-named pred-name value))
  (define subj (named-value-name nv))
  (attach nv (list (detached-proof `(,pred-name ,subj) (hash subj value)))))

;; ── Pure functions (return plain Racket values) ──────────────────────────────

;; String.length — returns plain Int (use String.length result in comparisons directly)
;; Note: length is always non-negative by definition — proof via Int.nonZero is not needed here
(define (String.length s)
  (string-length (raw-str s)))

(define (String.isEmpty s)
  (string=? (raw-str s) ""))

;; (string-prefix? full-string prefix) — racket/string convention
(define (String.startsWith s prefix)
  (string-prefix? (raw-str s) (raw-str prefix)))

(define (String.endsWith s suffix)
  (string-suffix? (raw-str s) (raw-str suffix)))

(define (String.contains s sub)
  ;; string-search returns index or #f
  (and (string-search (raw-str s) (raw-str sub)) #t))

(define (String.split s sep)
  (define raw-s (raw-str s))
  (if (string=? raw-s "")
      (list "")
      (string-split raw-s (raw-str sep) #:trim? #f)))

(define (String.join strs sep)
  (string-join (map raw-str strs) (raw-str sep)))

(define (String.replace s from to)
  (string-replace (raw-str s) (raw-str from) (raw-str to)))

;; Zero-based slice; clamps indices to valid range
(define (String.slice s start end)
  (define raw (raw-str s))
  (define len (string-length raw))
  (define lo (max 0 (min (raw-value start) len)))
  (define hi (max lo (min (raw-value end) len)))
  (substring raw lo hi))

(define (String.concat s1 s2)
  (string-append (raw-str s1) (raw-str s2)))

(define (String.repeat s n)
  (apply string-append (make-list (raw-value n) (raw-str s))))

(define (String.reverse s)
  (list->string (reverse (string->list (raw-str s)))))

;; Returns Something(n) if parseable as integer, Nothing otherwise
(define (String.toInt s)
  (define n (string->number (raw-str s)))
  (if (and n (exact-integer? n))
      (Something n)
      Nothing))

;; Returns Something(f) if parseable as float, Nothing otherwise
(define (String.toFloat s)
  (define n (string->number (raw-str s)))
  (if (and n (real? n))
      (Something (exact->inexact n))
      Nothing))

(define (String.fromInt n)
  (number->string (raw-value n)))

(define (String.fromFloat f)
  (number->string (exact->inexact (raw-value f))))

(define (String.lines s)
  (string-split (raw-str s) "\n" #:trim? #f))

(define (String.words s)
  (string-split (raw-str s)))

;; Pad string on the left to at least `width` chars using `padChar`
(define (String.padLeft s width padChar)
  (define raw (raw-str s))
  (define len (string-length raw))
  (define w   (raw-value width))
  (define ch  (if (string? padChar) (string-ref padChar 0) (raw-value padChar)))
  (if (>= len w) raw (string-append (make-string (- w len) ch) raw)))

;; Pad string on the right
(define (String.padRight s width padChar)
  (define raw (raw-str s))
  (define len (string-length raw))
  (define w   (raw-value width))
  (define ch  (if (string? padChar) (string-ref padChar 0) (raw-value padChar)))
  (if (>= len w) raw (string-append raw (make-string (- w len) ch))))

;; Remove prefix if present; otherwise return original
(define (String.dropPrefix s prefix)
  (define raw (raw-str s))
  (define pre (raw-str prefix))
  (if (string-prefix? raw pre)
      (substring raw (string-length pre))
      raw))

;; Remove suffix if present; otherwise return original
(define (String.dropSuffix s suffix)
  (define raw (raw-str s))
  (define suf (raw-str suffix))
  (if (string-suffix? raw suf)
      (substring raw 0 (- (string-length raw) (string-length suf)))
      raw))

;; Returns Something(index) of first occurrence of sub in s, or Nothing
(define (String.indexOf s sub)
  (define pos (string-search (raw-str s) (raw-str sub)))
  (if pos (Something pos) Nothing))

;; ── Check function: requires non-empty ───────────────────────────────────────
;; String.requireNonEmpty — check function returning s ::: IsNonEmpty s
;; Use with `check`:
;;   let name = check String.requireNonEmpty(rawName)
(provide String.requireNonEmpty)
(define (String.requireNonEmpty s)
  (define v (raw-str s))
  (if (not (string=? v ""))
      (let* ([nv   (attach-proof-to 'IsNonEmpty v)]
             [subj (named-value-name nv)]
             [fact `(IsNonEmpty ,subj)])
        (check-ok nv (list fact) (hash subj v)))
      (check-fail "expected a non-empty string" 400 #f)))

;; ── Proof-bearing functions (return named-value with proof attached) ─────────
;;
;; The returned value is a named-value carrying a GDP proof fact so that
;; callers can annotate parameters `s ::: IsTrimmed s` and the runtime
;; proof check will pass when String.trim is the source.

;; String.trim — returns trimmed string ::: IsTrimmed result
(define (String.trim s)
  (define trimmed (string-trim (raw-str s)))
  (attach-proof-to 'IsTrimmed trimmed))

;; String.trimLeft — trims only leading whitespace
(define (String.trimLeft s)
  (define trimmed (string-trim (raw-str s) #px"^\\s+"))
  (attach-proof-to 'IsTrimmed trimmed))

;; String.trimRight — trims only trailing whitespace
(define (String.trimRight s)
  (define trimmed (string-trim (raw-str s) #px"\\s+$" #:left? #f))
  (attach-proof-to 'IsTrimmed trimmed))

;; String.toUpper — returns uppercase string ::: IsUpperCase result
(define (String.toUpper s)
  (attach-proof-to 'IsUpperCase (string-upcase (raw-str s))))

;; String.toLower — returns lowercase string ::: IsLowerCase result
(define (String.toLower s)
  (attach-proof-to 'IsLowerCase (string-downcase (raw-str s))))
