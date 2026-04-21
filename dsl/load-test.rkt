#lang racket/base
;;; Load-test runtime for Tesl
;;; Implements open-model (rate-based) load testing with HDR-style histogram
;;; and optional baseline comparison.

(require racket/match
         racket/list
         racket/format
         racket/math
         json
         "test-support.rkt")

(provide run-load-test
         load-test-assert
         load-test-regression)

;; ── Histogram (simplified HDR-style) ──────────────────────────────────────
;; Uses a sorted vector of latencies for percentile computation.
;; For in-process load tests this is accurate and simple.

(struct histogram (latencies) #:mutable)

(define (make-histogram)
  (histogram '()))

(define (histogram-record! h latency-ms)
  (set-histogram-latencies! h (cons latency-ms (histogram-latencies h))))

(define (histogram-count h)
  (length (histogram-latencies h)))

(define (histogram-sorted h)
  (sort (histogram-latencies h) <))

(define (histogram-percentile h p)
  (define sorted (histogram-sorted h))
  (define n (length sorted))
  (cond
    [(= n 0) +inf.0]
    [else
     (define idx (min (sub1 n) (exact-floor (* p n))))
     (list-ref sorted idx)]))

(define (histogram-p50 h) (histogram-percentile h 0.50))
(define (histogram-p95 h) (histogram-percentile h 0.95))
(define (histogram-p99 h) (histogram-percentile h 0.99))
(define (histogram-p999 h) (histogram-percentile h 0.999))

(define (histogram-min h)
  (define lats (histogram-latencies h))
  (if (null? lats) +inf.0 (apply min lats)))

(define (histogram-max h)
  (define lats (histogram-latencies h))
  (if (null? lats) 0.0 (apply max lats)))

;; ── Assertion structures ──────────────────────────────────────────────────

(struct load-test-assert (metric op threshold) #:transparent)
(struct load-test-regression (metric ratio) #:transparent)

;; ── Steady-state detection ────────────────────────────────────────────────
;; Warm-up ends when p99 CV < 5% for 3 consecutive 2-second windows,
;; or after 30 seconds max.

(define WARMUP-WINDOW-SECS 2)
(define WARMUP-CV-THRESHOLD 0.05)
(define WARMUP-CONSECUTIVE 3)
(define WARMUP-MAX-SECS 30)

(define (coefficient-of-variation values)
  (cond
    [(< (length values) 2) 1.0]
    [else
     (define mean (/ (apply + values) (length values)))
     (cond
       [(<= mean 0) 1.0]
       [else
        (define variance
          (/ (apply + (map (λ (v) (expt (- v mean) 2)) values))
             (sub1 (length values))))
        (/ (sqrt variance) mean)])]))

;; ── Open-model scheduler ─────────────────────────────────────────────────
;; Sends requests at a fixed arrival rate regardless of response time.
;; Latency is measured from scheduled send time (prevents coordinated omission).

(define (run-load-test server rate-rps duration-secs request-thunk
                       #:baseline [baseline #f]
                       #:assertions [assertions '()])
  (define interval-ms (/ 1000.0 rate-rps))
  (define hist (make-histogram))
  (define error-count (box 0))
  (define total-count (box 0))

  ;; ── Warm-up phase ─────────────────────────────────────────────────────
  (define warmup-start (current-inexact-milliseconds))
  (define warmup-window-latencies '())
  (define warmup-window-start (current-inexact-milliseconds))
  ;; Stores p99 latency for each completed window (most recent first).
  ;; Warmup ends when CV of the last WARMUP-CONSECUTIVE window-p99s < threshold.
  (define warmup-window-p99s '())
  (define warmup-done? #f)

  (define (do-single-request! scheduled-time-ms)
    (define actual-start (current-inexact-milliseconds))
    (define response
      (with-handlers ([exn:fail?
                       (λ (e)
                         (set-box! error-count (add1 (unbox error-count)))
                         #f)])
        (request-thunk)))
    (define end-time (current-inexact-milliseconds))
    ;; Latency from scheduled time (coordinated-omission aware)
    (define latency (- end-time scheduled-time-ms))
    (set-box! total-count (add1 (unbox total-count)))
    ;; Check for HTTP errors (status >= 400)
    (when (and response (hash? response))
      (define status (hash-ref response 'status 200))
      (when (>= status 400)
        (set-box! error-count (add1 (unbox error-count)))))
    latency)

  ;; Warm-up loop
  (let warmup-loop ([scheduled (current-inexact-milliseconds)])
    (define elapsed-s (/ (- (current-inexact-milliseconds) warmup-start) 1000.0))
    (cond
      [(or warmup-done? (>= elapsed-s WARMUP-MAX-SECS))
       (void)]  ; warm-up complete
      [else
       (define latency (do-single-request! scheduled))
       (set! warmup-window-latencies (cons latency warmup-window-latencies))
       ;; Check window
       (define window-elapsed
         (/ (- (current-inexact-milliseconds) warmup-window-start) 1000.0))
       (when (>= window-elapsed WARMUP-WINDOW-SECS)
         ;; Compute p99 for this window and add it to the rolling list.
         (define window-p99
           (let* ([sorted (sort warmup-window-latencies <)]
                  [n      (length sorted)])
             (if (= n 0) +inf.0
                 (list-ref sorted (min (sub1 n) (exact-floor (* 0.99 n)))))))
         (set! warmup-window-p99s
               (let ([updated (cons window-p99 warmup-window-p99s)])
                 (if (> (length updated) WARMUP-CONSECUTIVE)
                     (take updated WARMUP-CONSECUTIVE)
                     updated)))
         ;; Check CV across the last WARMUP-CONSECUTIVE window-p99 values.
         (when (= (length warmup-window-p99s) WARMUP-CONSECUTIVE)
           (define cv (coefficient-of-variation warmup-window-p99s))
           (when (< cv WARMUP-CV-THRESHOLD)
             (set! warmup-done? #t)))
         (set! warmup-window-latencies '())
         (set! warmup-window-start (current-inexact-milliseconds)))
       ;; Next request
       (define next-scheduled (+ scheduled interval-ms))
       (define now (current-inexact-milliseconds))
       (when (> next-scheduled now)
         (sleep (/ (- next-scheduled now) 1000.0)))
       (warmup-loop next-scheduled)]))

  ;; ── Measurement phase ─────────────────────────────────────────────────
  (define measure-start (current-inexact-milliseconds))
  (define measure-end (+ measure-start (* duration-secs 1000.0)))

  (let measure-loop ([scheduled (current-inexact-milliseconds)])
    (cond
      [(>= (current-inexact-milliseconds) measure-end) (void)]
      [else
       (define latency (do-single-request! scheduled))
       (histogram-record! hist latency)
       (define next-scheduled (+ scheduled interval-ms))
       (define now (current-inexact-milliseconds))
       (when (> next-scheduled now)
         (sleep (/ (- next-scheduled now) 1000.0)))
       (measure-loop next-scheduled)]))

  ;; ── Report ────────────────────────────────────────────────────────────
  (define total (unbox total-count))
  (define errors (unbox error-count))
  (define actual-duration-s
    (/ (- (current-inexact-milliseconds) measure-start) 1000.0))
  (define actual-throughput (if (> actual-duration-s 0) (/ (histogram-count hist) actual-duration-s) 0))
  (define error-rate (if (> total 0) (/ (exact->inexact errors) total) 0.0))

  (printf "  Load test results (~a requests in ~as):\n"
          (histogram-count hist)
          (~r actual-duration-s #:precision '(= 1)))
  (printf "    p50:  ~ams  p95: ~ams  p99: ~ams  p99.9: ~ams\n"
          (~r (histogram-p50 hist) #:precision '(= 1))
          (~r (histogram-p95 hist) #:precision '(= 1))
          (~r (histogram-p99 hist) #:precision '(= 1))
          (~r (histogram-p999 hist) #:precision '(= 1)))
  (printf "    min: ~ams  max: ~ams  throughput: ~arps  errors: ~a%\n"
          (~r (histogram-min hist) #:precision '(= 1))
          (~r (histogram-max hist) #:precision '(= 1))
          (~r actual-throughput #:precision '(= 1))
          (~r (* error-rate 100) #:precision '(= 2)))
  (printf "    (measurements include in-process harness overhead)\n")

  ;; ── Evaluate assertions ───────────────────────────────────────────────
  (define (get-metric-value metric)
    (match metric
      ['p50 (histogram-p50 hist)]
      ['p95 (histogram-p95 hist)]
      ['p99 (histogram-p99 hist)]
      ['p99.9 (histogram-p999 hist)]
      ['error-rate error-rate]
      ['throughput actual-throughput]))

  (define (eval-op op actual threshold)
    (match op
      ['< (< actual threshold)]
      ['<= (<= actual threshold)]
      ['> (> actual threshold)]
      ['>= (>= actual threshold)]))

  (for ([a (in-list assertions)])
    (match a
      [(struct load-test-assert (metric op threshold))
       (define actual (get-metric-value metric))
       (define passed? (eval-op op actual threshold))
       (unless passed?
         (error 'load-test
                "assertion failed: ~a ~a ~a (actual: ~a)"
                metric op threshold (~r actual #:precision '(= 2))))]
      [(struct load-test-regression (metric ratio))
       ;; Baseline comparison deferred if no baseline file exists
       (when baseline
         (printf "    (baseline regression check for ~a with ratio ~a — baseline comparison not yet stored)\n"
                 metric ratio))]))

  ;; ── Baseline storage ──────────────────────────────────────────────────
  (when baseline
    (printf "    (baseline \"~a\" — in-process baselines; store/compare deferred)\n"
            baseline)))
