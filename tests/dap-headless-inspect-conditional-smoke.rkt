#lang racket

;; dap-headless-inspect-conditional-smoke.rkt — END-TO-END proof that an AI agent
;; can SET ITS OWN breakpoints with full control via `tesl debug-inspect`:
;; arbitrary line, MULTIPLE breakpoints, CONDITIONAL breakpoints, and HIT-COUNT
;; breakpoints. Unlike the (synthesised) assembly smoke, this runs the REAL
;; compiled CLI on a real lesson and asserts the breakpoint gating actually works.
;;
;; Fixture: example/learn/lesson61-step-debugging.tesl. Its `describeScore`
;; (line 100, `if score >= 90 ...`) is invoked by `computeGrade` in three tests
;; with scores 95, 85, then 75 — so a breakpoint inside it is hit three times with
;; different `score` values, which is exactly what conditional/hit-count gating
;; needs to be demonstrated against.

(require rackunit json racket/system racket/runtime-path)

(define-runtime-path here ".")
(define repo (simplify-path (build-path here "..")))
(define tesl-bin (build-path repo "compiler" "_build" "default" "bin" "main.exe"))
(define lesson (build-path repo "example" "learn" "lesson61-step-debugging.tesl"))

(putenv "TESL_REPO_ROOT" (path->string repo))

;; Run `tesl debug-inspect <lesson> --mode test <args...>` and parse the JSON dump.
(define (inspect . args)
  (define out (open-output-string))
  (parameterize ([current-output-port out] [current-error-port (open-output-string)])
    (apply system* tesl-bin "debug-inspect" (path->string lesson) "--mode" "test" args))
  (string->jsexpr (get-output-string out)))

(define (local-value result name)
  (for/or ([l (in-list (hash-ref result 'locals '()))])
    (and (equal? (hash-ref l 'name #f) name) (hash-ref l 'value #f))))

(cond
  [(not (file-exists? tesl-bin))
   (printf "SKIP: compiler not built at ~a\n" tesl-bin)]
  [else
   (test-case "agent sets an UNCONDITIONAL breakpoint — stops at the FIRST hit (score 95)"
     (define r (inspect "--break-at" "100"))
     (check-true (hash-ref r 'stopped) "breakpoint hit")
     (check-equal? (hash-ref (hash-ref r 'source) 'line) 100)
     (check-equal? (local-value r "score") "95" "first describeScore call is score 95"))

   (test-case "agent sets a CONDITIONAL breakpoint — fires ONLY when score == 75 (skips 95, 85)"
     (define r (inspect "--break-at" "100: score == 75"))
     (check-true (hash-ref r 'stopped) "conditional breakpoint eventually fires")
     (check-equal? (local-value r "score") "75"
                   "stopped at the score==75 call, not the earlier 95/85 calls")
     (check-equal? (hash-ref (hash-ref r 'breakpoint) 'condition) "score == 75"
                   "the firing breakpoint reports its condition"))

   (test-case "agent sets a HIT-COUNT breakpoint — fires on the 3rd execution (score 75)"
     (define r (inspect "--break-at" "100: ==3"))
     (check-true (hash-ref r 'stopped))
     (check-equal? (local-value r "score") "75" "3rd describeScore call is score 75")
     (check-equal? (hash-ref (hash-ref r 'breakpoint) 'hit) "==3"))

   (test-case "agent sets MULTIPLE breakpoints — stops at one of them and reports which"
     (define r (inspect "--break-at" "100,115"))
     (check-true (hash-ref r 'stopped))
     (define bp-line (hash-ref (hash-ref r 'breakpoint) 'line))
     (check-true (or (= bp-line 100) (= bp-line 115))
                 "stopped at one of the requested breakpoints")
     (check-equal? (hash-ref (hash-ref r 'source) 'line) bp-line
                   "source line matches the firing breakpoint"))

   (test-case "no breakpoint matches → stopped=false with a reason (fail-open, never hangs)"
     (define r (inspect "--break-at" "100: score == 999999"))
     (check-false (hash-ref r 'stopped))
     (check-true (string? (hash-ref r 'reason)) "carries a reason when nothing fires"))])

(module+ main (void))
