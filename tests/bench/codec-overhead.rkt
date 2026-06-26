#lang racket
;; codec-overhead.rkt — per-request HTTP codec benchmark for the
;; compile_time_specialization wave (Wave 4).
;;
;; WHAT THIS MEASURES
;; ------------------
;; The real per-request JSON cost on the HTTP edge of a TESL server:
;;
;;   * ENCODE (response path): a record value (the `Note` record from
;;     example/learn/lesson16-complete-notes-api.tesl — 5 fields, mix of
;;     string + posix-millis primitives) -> jsexpr -> JSON bytes, exactly as
;;     `handler-result->response` / `prepare-json` / `runtime-value->jsexpr`
;;     drive it on every successful response.
;;
;;   * DECODE (request path): a JSON object -> validated record value via the
;;     emitted `tesl-codec-decode-*` function, exactly as `resolve-payload`
;;     drives it on every request body.
;;
;; The existing tests/bench/proof-overhead.rkt benches the *proof* primitives,
;; not HTTP codecs. This bench fills that gap so the specialization win is
;; measured honestly on the codec hot path.
;;
;; METHODOLOGY (mirrors proof-overhead.rkt)
;; ----------------------------------------
;; The per-type codec functions are introduced by the OCaml EMITTER (emit_codec
;; in compiler/lib/emit_racket.ml), not by a runtime macro, so — exactly like
;; proof-overhead drives build-executable-expansion's primitives directly — we
;; reproduce here the TWO encoder shapes the emitter can produce for the same
;; `Note` record and measure both on an identical input:
;;
;;   GENERIC  : the pre-specialization shape — every field goes through the
;;              runtime interpreter `tesl-codec-encode-field`, which `cond`s on
;;              the codec-spec kind and calls the codec's car indirectly.
;;   SPECIAL  : the post-specialization shape — primitive fields are inlined to
;;              a direct type-check, eliminating the per-field dispatch + the
;;              indirect codec call + the intermediate codec-spec test.
;;
;; Both produce byte-IDENTICAL jsexpr (asserted at startup). The delta is the
;; constant-factor win the wave targets. A `--check-equiv` mode asserts the two
;; encoders and the registry encoder all agree and exits.
;;
;; The DECODE side is measured with the emitted decoder against a VALID body and
;; (separately) reports the negative-branch latency on a malformed body, so any
;; decode specialization can be shown not to regress the error path.
;;
;; USAGE
;;   racket tests/bench/codec-overhead.rkt              # default 1e6 calls
;;   racket tests/bench/codec-overhead.rkt --iters 2000000
;;   racket tests/bench/codec-overhead.rkt --quick      # 1e5 calls (CI smoke)
;;   racket tests/bench/codec-overhead.rkt --check-equiv  # equivalence only

(require tesl/dsl/types
         tesl/dsl/private/check-runtime
         racket/cmdline
         racket/format
         json)

;; --------------------------------------------------------------------------
;; CLI
;; --------------------------------------------------------------------------
(define iters (make-parameter 1000000))
(define trials (make-parameter 5))
(define check-equiv? (make-parameter #f))

(command-line
 #:program "codec-overhead"
 #:once-each
 [("--iters") n "Number of calls per trial (default 1e6)" (iters (string->number n))]
 [("--trials") n "Number of timed trials; median reported (default 5)" (trials (string->number n))]
 [("--quick") "Fast CI smoke: 1e5 calls, 3 trials" (iters 100000) (trials 3)]
 [("--check-equiv") "Assert encoder equivalence and exit (no timing)" (check-equiv? #t)])

;; --------------------------------------------------------------------------
;; The sample `Note` record value, built the way the runtime holds it on the
;; response path: a record-value whose fields are themselves raw primitives.
;; (createdAt is a posix-millis integer.)  The record type is declared exactly
;; as the emitter declares it (see lesson16-complete-notes-api.rkt).
;; --------------------------------------------------------------------------
;; All-primitive field record (the common shape primitive specialization
;; targets).  Fields are plain String/Int so the sample value holds raw
;; primitives — exactly the state the encoder receives once a handler builds a
;; record from raw values.  (Newtype-typed fields like NoteId/PosixMillis wrap
;; their contents and flow through runtime-value->jsexpr unwrapping, a separate
;; non-specialized path; createdAt still uses the posix-millis codec helper to
;; exercise that encoder.)
(define-record Note
  [id : String]
  [title : String]
  [content : String]
  [authorId : String]
  [createdAt : Int])

(define sample-note
  (Note #:id "note-abc-123"
        #:title "Buy milk and eggs"
        #:content "Remember to also grab bread on the way home from work."
        #:authorId "user-42"
        #:createdAt 1750000000000))

;; --------------------------------------------------------------------------
;; GENERIC encoder — the shape emitted BEFORE this wave (every field routed
;; through the tesl-codec-encode-field interpreter).  Kept byte-faithful to the
;; emit_codec output so the comparison is honest.
;; --------------------------------------------------------------------------
(define (encode-Note/generic _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'id        (tesl-codec-encode-field (raw-value (hash-ref _fields 'id)) tesl-json-string-codec)
        'title     (tesl-codec-encode-field (raw-value (hash-ref _fields 'title)) tesl-json-string-codec)
        'content   (tesl-codec-encode-field (raw-value (hash-ref _fields 'content)) tesl-json-string-codec)
        'authorId  (tesl-codec-encode-field (raw-value (hash-ref _fields 'authorId)) tesl-json-string-codec)
        'createdAt (tesl-codec-encode-field (raw-value (hash-ref _fields 'createdAt)) tesl-json-posix-millis-codec)))

;; --------------------------------------------------------------------------
;; SPECIAL encoder — the shape emitted AFTER this wave.  Primitive fields are
;; inlined to a direct type-check via the tesl-encode-prim-* helpers (which this
;; wave adds to dsl/types.rkt).  No per-field dispatch, no indirect codec call.
;; This mirrors emit_codec's specialized output exactly.
;; --------------------------------------------------------------------------
(define (encode-Note/special _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'id        (tesl-encode-prim-string (raw-value (hash-ref _fields 'id)))
        'title     (tesl-encode-prim-string (raw-value (hash-ref _fields 'title)))
        'content   (tesl-encode-prim-string (raw-value (hash-ref _fields 'content)))
        'authorId  (tesl-encode-prim-string (raw-value (hash-ref _fields 'authorId)))
        'createdAt (tesl-encode-prim-posix-millis (raw-value (hash-ref _fields 'createdAt)))))

;; --------------------------------------------------------------------------
;; NESTED scenario — a record `Envelope` with a field whose codec is a USER
;; TYPE (`Note`), i.e. a registry symbol.  This is where generic dispatch is
;; most expensive: tesl-codec-encode-field must `hash-ref type-codec-registry`
;; on EVERY field encode, then call the encoder indirectly.  Specialization
;; replaces that with a DIRECT call to the named encoder — no per-encode hash
;; lookup, no symbol-cond.  We register Note's encoder first so the generic
;; path can resolve it.
;; --------------------------------------------------------------------------
(define-record Envelope
  [meta : String]
  [note1 : Note]
  [note2 : Note])

(define sample-envelope
  (Envelope #:meta "envelope-v1" #:note1 sample-note #:note2 sample-note))

;; GENERIC nested: field codec-spec is the symbol 'Note → registry lookup + indirect call.
(define (encode-Envelope/generic _v)
  (define _raw _v)
  (define _fields (record-value-fields _raw))
  (hash 'meta  (tesl-codec-encode-field (raw-value (hash-ref _fields 'meta)) tesl-json-string-codec)
        'note1 (tesl-codec-encode-field (raw-value (hash-ref _fields 'note1)) 'Note)
        'note2 (tesl-codec-encode-field (raw-value (hash-ref _fields 'note2)) 'Note)))

;; SPECIAL nested: primitive inlined; nested user type → DIRECT named-encoder call.
(define (encode-Envelope/special _v)
  (define _raw _v)
  (define _fields (record-value-fields _raw))
  (hash 'meta  (tesl-encode-prim-string (raw-value (hash-ref _fields 'meta)))
        'note1 (encode-Note/special (raw-value (hash-ref _fields 'note1)))
        'note2 (encode-Note/special (raw-value (hash-ref _fields 'note2)))))

;; --------------------------------------------------------------------------
;; DECODE side — measure the request-body decode hot path and prove a candidate
;; primitive decode specialization stays error-text identical on negatives.
;;
;; A plain (no-via) decoder for a 5-primitive-field record, in the two shapes:
;;   GENERIC : each field via tesl-codec-decode-field (lookup + missing-check +
;;             codec-spec cond + indirect (cdr codec-spec) call).
;;   SPECIAL : field lookup + missing-check inlined, then a DIRECT
;;             tesl-decode-prim-* call.  The missing-field error MUST stay
;;             byte-identical (it is — both paths use the same raise-user-error
;;             text), which the negative assertions below verify.
;; --------------------------------------------------------------------------
(define sample-json
  (hash "id" "note-abc-123"
        "title" "Buy milk and eggs"
        "content" "Remember to also grab bread on the way home from work."
        "authorId" "user-42"
        "createdAt" 1750000000000))

(define (decode-Note/generic _j)
  (define _f_id        (tesl-codec-decode-field _j "id" tesl-json-string-codec))
  (define _f_title     (tesl-codec-decode-field _j "title" tesl-json-string-codec))
  (define _f_content   (tesl-codec-decode-field _j "content" tesl-json-string-codec))
  (define _f_authorId  (tesl-codec-decode-field _j "authorId" tesl-json-string-codec))
  (define _f_createdAt (tesl-codec-decode-field _j "createdAt" tesl-json-posix-millis-codec))
  (record-value 'Note (hash 'id _f_id 'title _f_title 'content _f_content
                            'authorId _f_authorId 'createdAt _f_createdAt)))

;; Local copy of dsl/types.rkt's (private) jsexpr-object-ref so the bench's
;; specialized decode mirrors the runtime lookup exactly.
(define (bench-jsexpr-object-ref object key [default #f])
  (cond
    [(and (hash? object) (hash-has-key? object key)) (hash-ref object key)]
    [(and (hash? object) (symbol? key) (hash-has-key? object (symbol->string key)))
     (hash-ref object (symbol->string key))]
    [(and (hash? object) (string? key) (hash-has-key? object (string->symbol key)))
     (hash-ref object (string->symbol key))]
    [else default]))

;; The candidate specialized primitive field-decode: inline the lookup +
;; missing-check (byte-identical raise) then a direct prim-decode call.
(define (decode-prim-field _j key prim)
  (define raw (bench-jsexpr-object-ref _j key 'TESL-MISSING))
  (when (eq? raw 'TESL-MISSING)
    (raise-user-error 'codec "required field \"~a\" not found in JSON" key))
  (prim raw))

(define (decode-Note/special _j)
  (define _f_id        (decode-prim-field _j "id" tesl-decode-prim-string))
  (define _f_title     (decode-prim-field _j "title" tesl-decode-prim-string))
  (define _f_content   (decode-prim-field _j "content" tesl-decode-prim-string))
  (define _f_authorId  (decode-prim-field _j "authorId" tesl-decode-prim-string))
  (define _f_createdAt (decode-prim-field _j "createdAt" tesl-decode-prim-posix-millis))
  (record-value 'Note (hash 'id _f_id 'title _f_title 'content _f_content
                            'authorId _f_authorId 'createdAt _f_createdAt)))

;; Negative inputs that must raise byte-identical messages on BOTH paths.
(define negative-jsons
  (list (cons "missing-required-field"
              (hash "id" "x" "title" "t" "content" "c" "authorId" "a"))      ; no createdAt
        (cons "wrong-type-string"
              (hash "id" 42 "title" "t" "content" "c" "authorId" "a" "createdAt" 5))
        (cons "wrong-type-int"
              (hash "id" "x" "title" "t" "content" "c" "authorId" "a" "createdAt" "no"))))

(define (capture-error f j)
  (with-handlers ([exn:fail? (lambda (e) (exn-message e))]) (f j) 'NO-ERROR))

(define (assert-decode-equiv!)
  ;; positive
  (let ([g (decode-Note/generic sample-json)]
        [s (decode-Note/special sample-json)])
    (unless (equal? g s)
      (error 'codec-bench "decode positive MISMATCH:\n  ~s\n  ~s" g s)))
  ;; every negative branch — error text must be byte-identical
  (for ([nv (in-list negative-jsons)])
    (define eg (capture-error decode-Note/generic (cdr nv)))
    (define es (capture-error decode-Note/special (cdr nv)))
    (unless (equal? eg es)
      (error 'codec-bench
             "decode NEGATIVE error-text MISMATCH on ~a:\n  generic : ~s\n  special : ~s"
             (car nv) eg es))
    (when (eq? eg 'NO-ERROR)
      (error 'codec-bench "decode negative ~a unexpectedly succeeded" (car nv))))
  (printf "  decoder equivalence OK (positive identical; ~a negative branches byte-identical error text)\n"
          (length negative-jsons)))

;; --------------------------------------------------------------------------
;; Equivalence: the two encoders, the registered runtime encoder, and the
;; round-trip through json bytes must all agree.
;; --------------------------------------------------------------------------
(define (assert-equiv!)
  ;; Register the SPECIAL Note encoder so the generic envelope path (registry
  ;; symbol 'Note) and the special path (direct call) resolve the SAME encoder.
  (register-type-codec! 'Note encode-Note/special '())
  ;; Envelope nested equivalence
  (let ([eg (encode-Envelope/generic sample-envelope)]
        [es (encode-Envelope/special sample-envelope)])
    (unless (equal? eg es)
      (error 'codec-bench "nested generic vs special MISMATCH:\n  ~s\n  ~s" eg es))
    (unless (equal? (jsexpr->bytes eg) (jsexpr->bytes es))
      (error 'codec-bench "nested JSON byte mismatch")))
  (define g (encode-Note/generic sample-note))
  (define s (encode-Note/special sample-note))
  (define r (runtime-value->jsexpr sample-note))     ; goes via registry
  (unless (equal? g s)
    (error 'codec-bench "generic vs special encoder MISMATCH:\n  generic: ~s\n  special: ~s" g s))
  (unless (equal? g r)
    (error 'codec-bench "generic vs registry encoder MISMATCH:\n  generic: ~s\n  registry: ~s" g r))
  ;; full bytes round trip must be identical
  (unless (equal? (jsexpr->bytes g) (jsexpr->bytes s))
    (error 'codec-bench "JSON byte mismatch"))
  (printf "  encoder equivalence OK (generic == special == registry, byte-identical JSON)\n")
  (printf "  sample JSON: ~a\n" (bytes->string/utf-8 (jsexpr->bytes s))))

;; --------------------------------------------------------------------------
;; Timing harness (same instrument as proof-overhead.rkt: retained results +
;; live-heap delta for bytes/call, median wall time for ns/call).
;; --------------------------------------------------------------------------
(define sink #f)
(define (keep! v) (set! sink v) v)

(define (bench-one label f n trials* [input sample-note])
  (for ([i (in-range (min n 10000))]) (keep! (f input)))
  (define ns-samples '())
  (define bytes-samples '())
  (for ([_ (in-range trials*)])
    (define buf (make-vector n #f))
    (collect-garbage) (collect-garbage) (collect-garbage)
    (define mem0 (current-memory-use))
    (define t0 (current-inexact-milliseconds))
    (for ([i (in-range n)]) (vector-set! buf i (f input)))
    (define t1 (current-inexact-milliseconds))
    (define mem1 (current-memory-use))
    (set! ns-samples (cons (/ (* (- t1 t0) 1e6) n) ns-samples))
    (set! bytes-samples (cons (max 0 (/ (- mem1 mem0) n)) bytes-samples))
    (keep! (vector-ref buf (sub1 n))))
  (define (median xs) (list-ref (sort xs <) (quotient (length xs) 2)))
  (values label (median ns-samples) (median bytes-samples)))

;; --------------------------------------------------------------------------
(define (fmt-ns x)    (~r x #:precision '(= 1) #:min-width 10))
(define (fmt-bytes x) (~r x #:precision '(= 1) #:min-width 11))

(define (run)
  (printf "\n")
  (printf "════════════════════════════════════════════════════════════════════════\n")
  (printf "  TESL codec-overhead benchmark — per-request HTTP JSON encode (record, 5 fields)\n")
  (printf "════════════════════════════════════════════════════════════════════════\n")
  (printf "  racket : ~a\n\n" (version))
  (assert-equiv!)
  (assert-decode-equiv!)
  (when (check-equiv?) (exit 0))
  (printf "\n")
  (define-values (lg nsg bg)
    (bench-one "FLAT    generic (encode-field per field)" encode-Note/generic (iters) (trials)))
  (define-values (ls nss bs)
    (bench-one "FLAT    special (inlined primitives)"     encode-Note/special (iters) (trials)))
  (define-values (lng nsng bng)
    (bench-one "NESTED  generic (registry lookup/field)"  encode-Envelope/generic (iters) (trials) sample-envelope))
  (define-values (lns nsns bns)
    (bench-one "NESTED  special (direct named-encoder)"   encode-Envelope/special (iters) (trials) sample-envelope))
  (define-values (ldg nsdg bdg)
    (bench-one "DECODE  generic (decode-field per field)" decode-Note/generic (iters) (trials) sample-json))
  (define-values (lds nsds bds2)
    (bench-one "DECODE  special (inlined prim decode)"    decode-Note/special (iters) (trials) sample-json))
  (printf "  ~a  ~a  ~a\n"
          (~a "mode" #:min-width 44)
          (~a "ns/call" #:min-width 10 #:align 'right)
          (~a "bytes/call" #:min-width 11 #:align 'right))
  (printf "  ~a  ~a  ~a\n" (make-string 44 #\─) (make-string 10 #\─) (make-string 11 #\─))
  (define (row l ns b) (printf "  ~a  ~a  ~a\n" (~a l #:min-width 44) (fmt-ns ns) (fmt-bytes b)))
  (row lg nsg bg) (row ls nss bs) (row lng nsng bng) (row lns nsns bns)
  (row ldg nsdg bdg) (row lds nsds bds2)
  (printf "\n")
  (define (pct from to) (if (zero? from) 0.0 (* 100.0 (/ (- from to) from))))
  (printf "  Specialization win (generic → special):\n")
  (printf "    FLAT   enc ns/call : ~a → ~a   (~a% lower)\n"
          (fmt-ns nsg) (fmt-ns nss) (~r (pct nsg nss) #:precision '(= 1)))
  (printf "    NESTED enc ns/call : ~a → ~a   (~a% lower)\n"
          (fmt-ns nsng) (fmt-ns nsns) (~r (pct nsng nsns) #:precision '(= 1)))
  (printf "    DECODE     ns/call : ~a → ~a   (~a% lower)\n"
          (fmt-ns nsdg) (fmt-ns nsds) (~r (pct nsdg nsds) #:precision '(= 1)))
  (printf "\n")
  (printf "  NOTE: on Racket CS 8.18 these deltas sit WITHIN run-to-run noise (±~~5%).\n")
  (printf "  The thin tesl-codec-encode-field / tesl-codec-decode-field dispatch JITs\n")
  (printf "  away; the dominant per-call cost is the shared hash / hash-ref / raw-value /\n")
  (printf "  jsexpr allocation (the inherent O(fields) output the wave does NOT target).\n")
  (printf "  The specialization's value is structural — one fewer indirection layer and a\n")
  (printf "  tiny bytes/call drop — proven byte-behaviour-identical above, not a wall-clock\n")
  (printf "  win.  This bench is the honest Phase-0 instrument + a regression guard.\n")
  (printf "════════════════════════════════════════════════════════════════════════\n\n")
  (void sink))

(run)
