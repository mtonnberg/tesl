#lang racket

;; dap-headless-persistent-smoke.rkt — proves the persistent NDJSON server mode
;; of the headless inspector (`tesl debug-inspect <file> --break-at N --continue
;; --mode program`), which previously had ZERO test coverage.
;;
;; THE MODE UNDER TEST (headless-inspect.rkt, persistent branch)
;; -------------------------------------------------------------
;; With `--continue` + `--mode program` the inspector emits one NDJSON
;; `session-started` line, then streams a `stopped` snapshot the instant each
;; breakpoint fires, resuming after each, and emits an `exited` line when (and
;; only when) the program terminates.  This is the agent's long-session form:
;; many requests / many breakpoint hits against one process.
;;
;; WHAT THIS TEST DOES
;; -------------------
;; Writes a debuggee module at test time whose `main` submodule loops N times
;; through a real thsl-src! checkpoint (TESL_DEBUG is set by
;; run-headless-inspect BEFORE the dynamic-require, so the macro expands to the
;; live checkpoint — the exact production path), runs the persistent mode with
;; the inspector's real entry function, and asserts the NDJSON stream shape:
;;   session-started · stopped ×N (with locals, in order) · exited.

(require rackunit
         json
         (only-in tesl/dsl/debug/headless-inspect
                  run-headless-inspect
                  bp-spec))

(define workdir
  (build-path (find-system-path 'temp-dir)
              (format "tesl-persistent-smoke-~a" (current-milliseconds))))
(make-directory* workdir)

;; The debuggee: three iterations, one checkpoint per iteration at "line 4".
(define src-path "persistent-smoke.tesl")
(define prog (build-path workdir "persistent-smoke.rkt"))
(call-with-output-file prog #:exists 'replace
  (lambda (o)
    (display
     (string-append
      "#lang racket\n"
      "(require tesl/dsl/debug/checkpoint)\n"
      "(module+ main\n"
      "  (for ([i (in-range 3)])\n"
      "    (thsl-src! \"" src-path "\" 4 (list (cons 'i i)) (lambda () (void)))))\n")
     o)))

;; Capture the inspector's NDJSON stream: run-headless-inspect snapshots
;; (current-output-port) as its real-out at call time.
(define stream (open-output-string))
(define-values (result _real-out)
  (parameterize ([current-output-port stream])
    (run-headless-inspect (path->string prog) src-path
                          (list (bp-spec 4 #f #f))
                          "program" #:continue? #t)))

(check-equal? result 'streamed "persistent mode reports it streamed directly")

(define lines
  (filter non-empty-string?
          (map string-trim (string-split (get-output-string stream) "\n"))))
(define msgs (map string->jsexpr lines))

(check-true (>= (length msgs) 5)
            (format "expected ≥5 NDJSON lines, got ~a: ~a" (length msgs) lines))

(test-case "first line is session-started with the requested breakpoints"
  (define m (first msgs))
  (check-equal? (hash-ref m 'event) "session-started")
  (check-equal? (map (lambda (b) (hash-ref b 'line)) (hash-ref m 'breakpoints))
                '(4)))

(test-case "exactly three stopped snapshots, in iteration order, with locals"
  (define stops (filter (lambda (m) (equal? (hash-ref m 'event #f) "stopped")) msgs))
  (check-equal? (length stops) 3)
  (for ([m (in-list stops)] [expect-i (in-naturals)])
    (check-true (hash-ref m 'stopped))
    (check-equal? (hash-ref (hash-ref m 'source) 'line) 4)
    (define i-local
      (for/or ([l (in-list (hash-ref m 'locals '()))])
        (and (equal? (hash-ref l 'name #f) "i") (hash-ref l 'value #f))))
    (check-equal? i-local (number->string expect-i))))

(test-case "final line is exited (the program terminated)"
  (check-equal? (hash-ref (last msgs) 'event) "exited"))
