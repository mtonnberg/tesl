#lang racket/base

;;; W3C Trace Context for Tesl — ids, `traceparent` parse/format, and the
;;; ambient span context every signal reads.
;;;
;;; This module is the Phase-A core of
;;; roadmap/completed/otel_trace_support.md: it carries NO net code, exports NO
;;; spans, and knows nothing about OTLP.  Its whole job
;;; is that a Tesl app is a citizen in someone else's trace — an inbound
;;; `traceparent` is parsed, carried as an ambient context, stamped onto every
;;; log record (dsl/otel.rkt) and injected onto every outbound HTTP call
;;; (tesl/http-client.rkt).  dsl/traces.rkt (span export) sits ON TOP of this.
;;;
;;; IDS ARE CRYPTO-RANDOM.  `request.id` (dsl/web.rkt) uses `(random 1000000)`,
;;; which is seeded identically per replica — fine for a human-readable handle,
;;; NOT fine for a 16-byte identifier that must be globally unique across every
;;; process talking to the same collector.  `crypto-random-bytes` is the source
;;; here, and the all-zero id W3C forbids is regenerated rather than emitted.
;;;
;;; NEVER RAISES.  A malformed / hostile inbound header is not an error: parse
;;; returns #f and the caller starts a fresh trace.  A header is attacker-
;;; controlled input, so `parse-traceparent` is total over arbitrary strings.
;;;
;;; Dependency direction: requires only racket/*, so dsl/otel.rkt, dsl/traces.rkt,
;;; dsl/web.rkt, dsl/sql.rkt, tesl/http-client.rkt and tesl/queue.rkt can all
;;; require it with no cycle.

(require racket/random
         (only-in racket/string string-trim string-split))

(provide (struct-out trace-ctx)
         current-trace-ctx
         new-trace-id
         new-span-id
         parse-traceparent
         format-traceparent
         valid-tracestate?
         trace-context-attributes
         current-traceparent-header
         current-tracestate-header
         make-root-trace-ctx
         sampled-by-ratio?
         trace-sample-ratio
         set-trace-sample-ratio!
         call-with-trace-ctx
         call-with-child-span-id)

;; trace-id  : 32 lowercase hex chars (16 bytes), never all-zero
;; span-id   : 16 lowercase hex chars (8 bytes), the CURRENT span — a child span
;;             rebinds it (call-with-child-span-id) so a log emitted inside the
;;             child is attributed to the child, not to the request root
;; sampled?  : the W3C `sampled` flag — the ONE bit that decides recording, and
;;             the bit propagated downstream
;; tracestate: the raw inbound `tracestate` header (string) or #f, passed through
;;             UNMODIFIED (we add no vendor entry of our own)
;; remote-parent? : #t iff `span-id` names a span that exists SOMEWHERE ELSE (the
;;             caller's span, from an inbound `traceparent`).  #f means we minted
;;             it locally and never exported it.  dsl/traces.rkt needs the
;;             distinction: a root SERVER span may only claim a `parentSpanId`
;;             that really exists, or the collector renders a trace whose root
;;             points at a span nobody ever sent.
(struct trace-ctx (trace-id span-id sampled? tracestate remote-parent?) #:transparent)

;; The ambient context.  #f means "no trace in scope" — every reader must treat
;; that as "add nothing", so a non-HTTP entry point (a script, a test) behaves
;; exactly as it did before traces existed.
(define current-trace-ctx (make-parameter #f))

;; ── Ids ──────────────────────────────────────────────────────────────────────

(define hex-digits "0123456789abcdef")

(define (bytes->hex bs)
  (define out (make-string (* 2 (bytes-length bs))))
  (for ([b (in-bytes bs)] [i (in-naturals)])
    (string-set! out (* 2 i) (string-ref hex-digits (quotient b 16)))
    (string-set! out (add1 (* 2 i)) (string-ref hex-digits (remainder b 16))))
  out)

;; W3C: an all-zero id is invalid.  The odds are astronomically small, but a
;; "can't happen" that produces an id every collector DROPS is worth one loop.
(define (random-id n-bytes)
  (let loop ()
    (define bs (crypto-random-bytes n-bytes))
    (if (for/and ([b (in-bytes bs)]) (zero? b))
        (loop)
        (bytes->hex bs))))

(define (new-trace-id) (random-id 16))
(define (new-span-id) (random-id 8))

;; ── traceparent parse / format ────────────────────────────────────────────────

(define (lower-hex-string? s len)
  (and (string? s)
       (= (string-length s) len)
       (for/and ([c (in-string s)])
         (or (char<=? #\0 c #\9) (char<=? #\a c #\f)))))

(define (all-zero-hex? s)
  (for/and ([c (in-string s)]) (char=? c #\0)))

;; Parse a `traceparent` header value into a trace-ctx, or #f if it is not a
;; usable W3C trace context.  Total over arbitrary strings — never raises.
;;
;;   00-<32 hex trace-id>-<16 hex parent-span-id>-<2 hex flags>
;;
;; Rules taken straight from the W3C recommendation:
;;   - version "ff" is invalid; an UNKNOWN future version is accepted by parsing
;;     the first four fields and ignoring any extra ones (that is the spec's
;;     forward-compatibility rule, and dropping it would make us the service
;;     that breaks every trace once a version 01 exists);
;;   - version 00 must have EXACTLY four fields;
;;   - ids must be lowercase hex of the exact length and not all-zero;
;;   - the low bit of `flags` is `sampled`.
;;
;; The parsed span-id is the CALLER's span, which becomes our parent: the
;; returned ctx carries it so the caller can either use it as the parent of a
;; fresh child (span export) or carry it as-is (Phase A, no spans).
(define (parse-traceparent header)
  (and (string? header)
       (let* ([trimmed (string-trim header)]
              [parts (string-split trimmed "-" #:trim? #f)])
         (and (>= (length parts) 4)
              (let ([version (list-ref parts 0)]
                    [trace-id (list-ref parts 1)]
                    [span-id (list-ref parts 2)]
                    [flags (list-ref parts 3)])
                (and (lower-hex-string? version 2)
                     (not (string=? version "ff"))
                     ;; version 00 is exactly four fields; later versions may add more
                     (or (not (string=? version "00")) (= (length parts) 4))
                     (lower-hex-string? trace-id 32)
                     (not (all-zero-hex? trace-id))
                     (lower-hex-string? span-id 16)
                     (not (all-zero-hex? span-id))
                     (lower-hex-string? flags 2)
                     (trace-ctx trace-id
                                span-id
                                (odd? (string->number flags 16))
                                #f
                                ;; the span-id we just parsed is the CALLER's
                                #t)))))))

;; Render a ctx as a version-00 `traceparent`.  The span-id emitted is the
;; CURRENT span, so a downstream service becomes its child.
(define (format-traceparent ctx)
  (string-append "00-"
                 (trace-ctx-trace-id ctx) "-"
                 (trace-ctx-span-id ctx) "-"
                 (if (trace-ctx-sampled? ctx) "01" "00")))

;; `tracestate` is passed through unmodified, but it still goes onto an outbound
;; header, so it gets the same shape gate the outbound header guard would want:
;; printable ASCII, no CR/LF, and bounded length (W3C: 512 chars).  A value that
;; fails this is dropped, never sanitized — half a tracestate is worse than none.
(define (valid-tracestate? s)
  (and (string? s)
       (> (string-length s) 0)
       (<= (string-length s) 512)
       (for/and ([c (in-string s)])
         (and (char<=? #\space c) (char<=? c #\~)))))

;; ── Sampling ─────────────────────────────────────────────────────────────────

;; The head-sampling ratio (`traceRatio` on initTelemetry).  A box, not a
;; parameter, so every request/worker thread observes the same value regardless of
;; parameterization — the same reason the log sink and the metrics flag are boxes.
;; Out-of-range or non-real values clamp to 1.0 rather than raising: this is
;; deployment configuration on the emit path, and the emit path never raises.
(define trace-ratio-box (box 1.0))

(define (trace-sample-ratio) (unbox trace-ratio-box))

(define (set-trace-sample-ratio! ratio)
  (set-box! trace-ratio-box
            (cond
              [(not (real? ratio)) 1.0]
              [(< ratio 0.0) 0.0]
              [(> ratio 1.0) 1.0]
              [else (exact->inexact ratio)])))

;; Head sampling, PARENT-RESPECTING: an inbound decision is never second-guessed
;; (that is what keeps a distributed trace whole), so the ratio only decides for
;; a trace that STARTS here.  ratio <= 0 never samples, >= 1 always does.
(define (sampled-by-ratio? ratio)
  (cond
    [(not (real? ratio)) #t]
    [(<= ratio 0.0) #f]
    [(>= ratio 1.0) #t]
    [else
     ;; One crypto-random byte pair is plenty of resolution for a head ratio and
     ;; keeps the decision independent of `random`'s per-replica seed.
     (define bs (crypto-random-bytes 2))
     (< (/ (+ (* 256 (bytes-ref bs 0)) (bytes-ref bs 1)) 65536.0) ratio)]))

;; Build the request-root context.  `inbound-traceparent` / `inbound-tracestate`
;; are the raw header values (or #f).  With a usable inbound parent we CONTINUE
;; that trace (its id, its sampled bit, its tracestate); otherwise we mint a new
;; trace and take the sampling decision here.
;;
;; `span-id`: for a continued trace the caller's span-id is our parent.  When
;; spans are exported the caller replaces it with a fresh child id; with export
;; off, carrying the parent's id is exactly right — our logs then hang off the
;; caller's span in the trace UI instead of off a span nobody ever sent.
;;
;; The `sampled` bit is a PROPAGATION decision, NOT "will we export a span".  It
;; is deliberately independent of `traces True`: a Tesl app with span export off
;; that stamped every outbound `traceparent` with flags 00 would tell every
;; parent-respecting service downstream to drop the trace too — it would silence
;; other teams' tracing by being in the path.  So the ratio decides (default 1.0
;; ⇒ sampled), and whether WE record is a separate question, asked by
;; dsl/traces.rkt against `traces-active?`.  Setting `traceRatio` below 1.0 does
;; suppress the sampled bit downstream as well, which is what consistent head
;; sampling means.
(define (make-root-trace-ctx #:traceparent [inbound-traceparent #f]
                             #:tracestate [inbound-tracestate #f]
                             #:ratio [ratio 1.0])
  (define parsed (parse-traceparent inbound-traceparent))
  (cond
    [parsed
     (trace-ctx (trace-ctx-trace-id parsed)
                (trace-ctx-span-id parsed)
                (trace-ctx-sampled? parsed)
                (and (valid-tracestate? inbound-tracestate) inbound-tracestate)
                #t)]
    [else
     (trace-ctx (new-trace-id)
                (new-span-id)
                (sampled-by-ratio? ratio)
                #f
                #f)]))

;; ── Ambient context helpers ──────────────────────────────────────────────────

(define (call-with-trace-ctx ctx thunk)
  (parameterize ([current-trace-ctx ctx]) (thunk)))

;; Run `thunk` with the ambient context's CURRENT span replaced by `span-id`.
;; `parameterize` nests with the call stack and is inherited by child threads, so
;; this gives span-context semantics in-process with no explicit plumbing — the
;; property the metrics wave already relies on for `current-telemetry-context`.
;;
;; The new span-id is one WE minted, so remote-parent? clears: anything nested
;; inside may claim it as a parent.
(define (call-with-child-span-id span-id thunk)
  (define ctx (current-trace-ctx))
  (if ctx
      (parameterize ([current-trace-ctx
                      (trace-ctx (trace-ctx-trace-id ctx)
                                 span-id
                                 (trace-ctx-sampled? ctx)
                                 (trace-ctx-tracestate ctx)
                                 #f)])
        (thunk))
      (thunk)))

;; The log-correlation attributes.  '() with no ambient trace, so a process that
;; never sees an HTTP request emits byte-identical telemetry to before.
(define (trace-context-attributes)
  (define ctx (current-trace-ctx))
  (if ctx
      (list (cons 'trace.id (trace-ctx-trace-id ctx))
            (cons 'span.id (trace-ctx-span-id ctx))
            (cons 'trace.sampled (trace-ctx-sampled? ctx)))
      '()))

;; The outbound header values for the ambient context (#f when there is none, or
;; when there is no tracestate to forward).
(define (current-traceparent-header)
  (define ctx (current-trace-ctx))
  (and ctx (format-traceparent ctx)))

(define (current-tracestate-header)
  (define ctx (current-trace-ctx))
  (and ctx
       (let ([ts (trace-ctx-tracestate ctx)])
         (and (valid-tracestate? ts) ts))))
