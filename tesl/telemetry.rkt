#lang racket

; Sentinel bindings — importing Tesl.Telemetry makes telemetry usage explicit.
; The telemetry statement is ambient (no capability required). These markers
; ensure the module origin is visible in imports for discoverability.
;
; counter/histogram/gauge are REAL runtime functions (the Metrics signal —
; roadmap opentelemetry_metrics), unlike the statement-form sentinels above
; them: the emitter lowers `counter "n" 1 [Tuple2 "k" v]` to a plain
; application of these bindings.  They are ambient like `telemetry` and never
; raise (the recorders in dsl/metrics.rkt swallow their own failures), so a
; malformed attribute can never take down the calling handler.

(require (only-in "../dsl/metrics.rkt"
                  metrics-active?
                  metric-counter-add!
                  metric-histogram-record!
                  metric-gauge-set!)
         (only-in "../dsl/private/evidence.rkt" raw-value)
         (only-in "../dsl/types.rkt" adt-value? adt-value-fields))

(provide telemetry initTelemetry
         counter histogram gauge)

(define telemetry 'telemetry)
(define initTelemetry 'initTelemetry)

;; Tesl attrs arrive as a List of Tuple2 values (adt-value with 'first/'second
;; fields; grouped-aggregate tuples may also be plain 2-lists).  Convert to the
;; (key . value) string pairs the metrics registry expects.  Anything
;; unrecognized is skipped rather than raised — same fail-soft contract as the
;; recorders themselves.
(define (attrs->pairs attrs)
  (for/list ([t (in-list (raw-value attrs))])
    (define v (raw-value t))
    (cond
      [(adt-value? v)
       (define fields (adt-value-fields v))
       (cons (~a (raw-value (hash-ref fields 'first "")))
             (~a (raw-value (hash-ref fields 'second ""))))]
      [(and (list? v) (= (length v) 2))
       (cons (~a (raw-value (first v))) (~a (raw-value (second v))))]
      [else (cons (~a v) "")])))

;; Gate FIRST, convert inside the handler: the metrics-off cost must be one
;; flag read (no attrs traversal/formatting), and a conversion failure must be
;; swallowed here — the recorders' own handlers cannot cover caller-side
;; argument evaluation.
(define (counter name value attrs)
  (when (metrics-active?)
    (with-handlers ([(lambda (_) #t) (lambda (_) (void))])
      (metric-counter-add! (raw-value name) (raw-value value)
                           (attrs->pairs attrs)))))

(define (histogram name value attrs)
  (when (metrics-active?)
    (with-handlers ([(lambda (_) #t) (lambda (_) (void))])
      (metric-histogram-record! (raw-value name)
                                (exact->inexact (raw-value value))
                                (attrs->pairs attrs)))))

(define (gauge name value attrs)
  (when (metrics-active?)
    (with-handlers ([(lambda (_) #t) (lambda (_) (void))])
      (metric-gauge-set! (raw-value name)
                         (exact->inexact (raw-value value))
                         (attrs->pairs attrs)))))
