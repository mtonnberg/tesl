#lang racket
;; proof-overhead.rkt — benchmark for the TESL "zero-cost proofs" item
;; (roadmap A / Wave 0, agent ZC-HARNESS).
;;
;; WHAT THIS MEASURES
;; ------------------
;; A proof-heavy hot path: a `fn` with THREE proof-annotated parameters, called
;; ~10^6 times.  The surface program is tests/bench/proof_hot.tesl; its `fn`
;; declaration `(hotPath [a : Integer ::: (Bounded a)] …)` is a macro CALL whose
;; expansion (build-executable-expansion in dsl/web.rkt) emits the runtime cost
;; sites.  Because the cost is introduced by macro expansion (not by emitted
;; text), the only faithful, revision-stable way to benchmark it is to drive the
;; underlying DSL primitives this benchmark requires from tesl/dsl directly:
;;
;;     net ON  (today's "safety net"):  per call, per proof param —
;;        runtime-bind+evidence     -> allocates named-value + runtime-binding
;;        validate-runtime-argument -> facts-of / type check / env lookups
;;     then a six-way parameterize (name/proof/evidence/type envs + check
;;     default/input facts) installed around the body.
;;
;;     net OFF (the zero-cost erasure the DSL macros now always emit):
;;        proof-annotated params bind via tesl-establish-param-proof (exactly ONE
;;        allocation so detachFact/decompose still work); proof-FREE params bind
;;        the raw value (ZERO allocations); no validate-runtime-argument, no
;;        parameterize.
;;
;; Two rows are printed: {net-off, net-on}.  BOTH rows are produced in one
;; process by exercising the two code paths directly, so the table shows the
;; delta between today's erased expansion (net-off) and the historical runtime
;; safety net (net-on).  We benchmark the primitives, not a recompiled module,
;; so the numbers are stable across compiler revisions.  (The compiled
;; proof_hot.tesl is exercised once as a smoke check that the surface program
;; and the measured primitives agree.)
;;
;; METRICS
;; -------
;;   ns/call    — wall time per call (median of repeated trials).
;;   bytes/call — heap bytes allocated per call.  Measured via
;;                current-memory-use deltas bracketed by collect-garbage, the
;;                accurate live-allocation counter on Racket CS 8.18.  We ALSO
;;                read vector-set-performance-stats! (GC count/time + its
;;                cumulative byte counter) and print them, per the harness spec;
;;                note that on CS its byte counter (slot 11) only advances at GC
;;                flushes and under-counts retained nursery objects, so ns/call
;;                bytes/call use current-memory-use as the authoritative source.
;;
;; USAGE
;;   racket tests/bench/proof-overhead.rkt              # default 1e6 calls
;;   racket tests/bench/proof-overhead.rkt --iters 2000000
;;   racket tests/bench/proof-overhead.rkt --quick      # 1e5 calls (CI smoke)
;;
;; Exit code is always 0 (a benchmark, not a gate) unless --check-threshold is
;; passed, in which case the ON-mode bytes/call must stay under
;; --max-on-bytes (default: no check) — wiring for the Verification step 5
;; "ON-mode bytes/call under the committed threshold" gate, OFF by default so
;; the harness never fails before ZC-SWITCH lands.

;; check-runtime.rkt re-provides the evidence-layer bindings we use (named-value,
;; raw-value, facts-of, …) with its environment-aware versions, so we require it
;; alone — pulling evidence.rkt too would collide on those shadowed names.
(require tesl/dsl/private/check-runtime
         racket/cmdline
         racket/format
         racket/runtime-path)

;; --------------------------------------------------------------------------
;; CLI
;; --------------------------------------------------------------------------
(define iters (make-parameter 1000000))
(define trials (make-parameter 5))
(define check-threshold? (make-parameter #f))
(define max-on-bytes (make-parameter +inf.0))
(define run-smoke? (make-parameter #t))

(command-line
 #:program "proof-overhead"
 #:once-each
 [("--iters") n "Number of calls per trial (default 1e6)"
  (iters (string->number n))]
 [("--trials") n "Number of timed trials; median reported (default 5)"
  (trials (string->number n))]
 [("--quick") "Fast CI smoke: 1e5 calls, 3 trials"
  (iters 100000) (trials 3)]
 [("--check-threshold") "Fail (exit 1) if ON-mode bytes/call exceeds --max-on-bytes"
  (check-threshold? #t)]
 [("--max-on-bytes") b "Threshold for --check-threshold (bytes/call)"
  (max-on-bytes (string->number b))]
 [("--no-smoke") "Skip the compiled proof_hot.tesl smoke check"
  (run-smoke? #f)])

;; --------------------------------------------------------------------------
;; Allocation measurement.  current-memory-use bracketed by collect-garbage is
;; the accurate live counter on Racket CS.  We retain results so the optimizer
;; cannot drop the work and so allocations survive the measurement window.
;; --------------------------------------------------------------------------
(define sink #f)
(define (keep! v) (set! sink v) v)

(define (perf-stats-snapshot)
  ;; Global performance stats vector.  Indices used:
  ;;   5  -> number of garbage collections
  ;;   6  -> total GC time (ms)            (CS: peak/major counters vary)
  ;;  11  -> cumulative bytes allocated (advances at GC flushes only)
  (define v (make-vector 12 0))
  (vector-set-performance-stats! v)
  v)

;; --------------------------------------------------------------------------
;; The two code paths, faithful to build-executable-expansion for a 3-param fn.
;; Each takes three raw integers, runs the param-binding machinery the macro
;; would emit, and RETURNS the proof object(s) it allocated.  Returning the
;; allocation (rather than just the summed int) is what lets the harness retain
;; it and read genuine bytes/call from the live-heap delta (see bench-one).
;; --------------------------------------------------------------------------

;; NET ON — today's safety net: wrap + validate + 6-way parameterize.
;; Returns the three named-value evidence structs (the allocation under audit).
(define (call/net-on a b c)
  (let-values ([(ev-a bd-a) (runtime-bind+evidence 'a a)]
               [(ev-b bd-b) (runtime-bind+evidence 'b b)]
               [(ev-c bd-c) (runtime-bind+evidence 'c c)])
    (let* ([bds  (list bd-a bd-b bd-c)]
           [evs  (list ev-a ev-b ev-c)]
           [nenv (extend-name-env (hash) '(a b c) bds)])
      (validate-runtime-argument 'hotPath 'a 'a ev-a "Integer" #f nenv (hash))
      (validate-runtime-argument 'hotPath 'b 'b ev-b "Integer" #f nenv (hash))
      (validate-runtime-argument 'hotPath 'c 'c ev-c "Integer" #f nenv (hash))
      (parameterize ([current-name-env     nenv]
                     [current-proof-env    (extend-proof-env (hash) bds)]
                     [current-evidence-env (extend-evidence-env (hash) evs)]
                     [current-type-env     (extend-type-env (hash) bds
                                                            (list "Integer" "Integer" "Integer"))])
        ;; force the body work; return the evidence triple so it is retained
        (let ([_ (+ (raw-value ev-a) (raw-value ev-b) (raw-value ev-c))])
          evs)))))

;; NET OFF — future erasure for PROOF-ANNOTATED params: one allocation each via
;; tesl-establish-param-proof (so detachFact/decompose still resolve), no
;; validate, no parameterize.  Returns the three established proofs.
(define (call/net-off a b c)
  (let ([pa (tesl-establish-param-proof 'a a '(Bounded a))]
        [pb (tesl-establish-param-proof 'b b '(Bounded b))]
        [pc (tesl-establish-param-proof 'c c '(Bounded c))])
    (let ([_ (+ (raw-value pa) (raw-value pb) (raw-value pc))])
      (list pa pb pc))))

;; NET OFF (proof-FREE params) — the pure zero-allocation lower bound: the
;; erased path for params with no proof annotation binds the raw value, so the
;; whole call is just the body.  Returns the int (a fixnum; no heap alloc).
(define (call/net-off-proof-free a b c)
  (+ a b c))

;; --------------------------------------------------------------------------
;; Timing harness.  Returns (values label ns/call bytes/call gc-count gc-ms).
;;
;; bytes/call: each call's result is RETAINED in a pre-sized vector, so after
;; the loop the live-heap growth (current-memory-use delta, bracketed by
;; collect-garbage) equals total bytes allocated by the measured work.  This is
;; the reliable allocation instrument on Racket CS 8.18 — its
;; vector-set-performance-stats! byte counter only advances at GC flushes and
;; reads 0 for transient/retained nursery objects (verified), so we use it only
;; for GC count/time, not bytes.  ns/call: median wall-clock over `trials`.
;; --------------------------------------------------------------------------
(define (bench-one label f n trials*)
  ;; warm up (JIT, parameter cells, first expansion)
  (for ([i (in-range (min n 10000))]) (keep! (f i (+ i 1) (+ i 2))))
  (define ns-samples '())
  (define bytes-samples '())
  (for ([_ (in-range trials*)])
    (define buf (make-vector n #f))
    (collect-garbage) (collect-garbage) (collect-garbage)
    (define mem0 (current-memory-use))
    (define t0 (current-inexact-milliseconds))
    (for ([i (in-range n)]) (vector-set! buf i (f i (+ i 1) (+ i 2))))
    (define t1 (current-inexact-milliseconds))
    ;; read live heap with buf still referenced => retained == allocated
    (define mem1 (current-memory-use))
    (set! ns-samples (cons (/ (* (- t1 t0) 1e6) n) ns-samples))
    (set! bytes-samples (cons (max 0 (/ (- mem1 mem0) n)) bytes-samples))
    (keep! (vector-ref buf (sub1 n)))) ; keep buf alive past the reading
  (define (median xs)
    (define s (sort xs <))
    (list-ref s (quotient (length s) 2)))
  ;; one extra pass to report GC count/time via perf-stats
  (collect-garbage) (collect-garbage)
  (define p0 (perf-stats-snapshot))
  (for ([i (in-range n)]) (keep! (f i (+ i 1) (+ i 2))))
  (define p1 (perf-stats-snapshot))
  (values label
          (median ns-samples)
          (median bytes-samples)
          (- (vector-ref p1 5) (vector-ref p0 5))
          (- (vector-ref p1 6) (vector-ref p0 6))))

;; --------------------------------------------------------------------------
;; Optional smoke check: run the compiled proof_hot.tesl test submodule so the
;; surface program and the measured primitives stay in agreement.
;; --------------------------------------------------------------------------
(define-runtime-path proof-hot-rkt "proof_hot.rkt")
(define (smoke-check)
  (when (and (run-smoke?) (file-exists? proof-hot-rkt))
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (eprintf "  smoke: proof_hot.tesl test submodule FAILED: ~a\n"
                                (exn-message e)))])
      (parameterize ([current-namespace (make-base-namespace)]
                     [current-output-port (open-output-nowhere)])
        (dynamic-require `(submod (file ,(path->string proof-hot-rkt)) test) #f))
      (printf "  smoke: proof_hot.tesl test submodule OK (surface program matches)\n"))))

;; --------------------------------------------------------------------------
;; Run + print the table.
;; --------------------------------------------------------------------------
(define (fmt-ns x)    (~r x #:precision '(= 1) #:min-width 10))
(define (fmt-bytes x) (~r x #:precision '(= 1) #:min-width 11))
(define (fmt-int x)   (~r x #:precision 0 #:min-width 7))

(define (run)
  (printf "\n")
  (printf "════════════════════════════════════════════════════════════════════════\n")
  (printf "  TESL proof-overhead benchmark — proof-heavy hot path (fn, 3 proof params)\n")
  (printf "════════════════════════════════════════════════════════════════════════\n")
  (printf "  calls/trial : ~a    trials : ~a\n" (iters) (trials))
  (printf "  racket       : ~a\n" (version))
  (printf "\n")
  (smoke-check)
  (printf "\n")

  (define-values (l1 ns1 b1 gc1 gcms1)
    (bench-one "net-off (proof-free, 0-alloc ref)" call/net-off-proof-free (iters) (trials)))
  (define-values (l2 ns2 b2 gc2 gcms2)
    (bench-one "net-off (proof-annotated, erased)" call/net-off (iters) (trials)))
  (define-values (l3 ns3 b3 gc3 gcms3)
    (bench-one "net-on  (today's safety net)"      call/net-on (iters) (trials)))

  (printf "  ~a  ~a  ~a  ~a  ~a\n"
          (~a "mode" #:min-width 36)
          (~a "ns/call" #:min-width 10 #:align 'right)
          (~a "bytes/call" #:min-width 11 #:align 'right)
          (~a "GCs" #:min-width 7 #:align 'right)
          (~a "gc(ms)" #:min-width 7 #:align 'right))
  (printf "  ~a  ~a  ~a  ~a  ~a\n"
          (make-string 36 #\─) (make-string 10 #\─) (make-string 11 #\─)
          (make-string 7 #\─) (make-string 7 #\─))
  (define (row l ns b gc gcms)
    (printf "  ~a  ~a  ~a  ~a  ~a\n"
            (~a l #:min-width 36) (fmt-ns ns) (fmt-bytes b) (fmt-int gc) (fmt-int gcms)))
  (row l1 ns1 b1 gc1 gcms1)
  (row l2 ns2 b2 gc2 gcms2)
  (row l3 ns3 b3 gc3 gcms3)
  (printf "\n")

  ;; Delta summary (net-on is the baseline being erased).
  (define (pct from to) (if (zero? from) 0.0 (* 100.0 (/ (- from to) from))))
  (printf "  Erasure target (net-on → net-off, proof-annotated):\n")
  (printf "    ns/call    : ~a → ~a   (~a% lower)\n"
          (fmt-ns ns3) (fmt-ns ns2) (~r (pct ns3 ns2) #:precision '(= 1)))
  (printf "    bytes/call : ~a → ~a   (~a% lower)\n"
          (fmt-bytes b3) (fmt-bytes b2) (~r (pct b3 b2) #:precision '(= 1)))
  (when (and (= ns2 ns3) (= b2 b3))
    (printf "    (identical — expected until ZC-SWITCH wires the erasure; harness is ready)\n"))
  (printf "\n")
  (printf "════════════════════════════════════════════════════════════════════════\n")
  (printf "\n")

  (when (check-threshold?)
    (cond
      [(<= b3 (max-on-bytes))
       (printf "  threshold OK: net-on bytes/call ~a <= ~a\n" (fmt-bytes b3) (max-on-bytes))]
      [else
       (eprintf "  THRESHOLD FAIL: net-on bytes/call ~a > ~a\n" (fmt-bytes b3) (max-on-bytes))
       (exit 1)]))
  (void sink))

(run)
