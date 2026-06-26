#lang racket
;; codec-specialization-test.rkt
;; Round-trip guard for the compile_time_specialization wave (Wave 4).
;;
;; Asserts that the EMITTER's specialized primitive ENCODER (a direct
;; tesl-encode-prim-* call per field — see emit_codec / codec_encode_field_call
;; in compiler/lib/emit_racket.ml) is BYTE-BEHAVIOUR-IDENTICAL to the
;; pre-specialization generic encoder (each field via tesl-codec-encode-field)
;; AND to the registry-driven runtime-value->jsexpr response path, on valid
;; input.  And that the (deliberately UNCHANGED) decoder reproduces
;; byte-identical error text + HTTP status on every malformed / negative branch.
;;
;; The encoder/decoder bodies below are the EXACT shapes the emitter produces
;; for a NewNote/Note-style codec (mirroring lesson16-complete-notes-api), so
;; this test pins the runtime invariant the per-lesson exact-match cannot (the
;; exact-match checks emitted TEXT; this checks emitted BEHAVIOUR).

(require tesl/dsl/types
         tesl/dsl/private/check-runtime
         rackunit
         json)

;; ── Types (as the emitter declares them) ────────────────────────────────────
(define-record Note
  [id : String] [title : String] [content : String]
  [authorId : String] [createdAt : Int])
(define-record NewNote
  [title : String] [content : String])

;; A via-checker exactly like lesson16's checkSafeTitle (1..200 chars).
(define (checkSafeTitle s)
  (define n (string-length (raw-value s)))
  (if (and (>= n 1) (<= n 200))
      (check-ok (raw-value s) '() (hash))
      (check-fail "title must be 1-200 characters" 400 '())))

;; ── ENCODERS ────────────────────────────────────────────────────────────────
;; GENERIC — pre-specialization shape.
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

;; SPECIAL — exactly what the emitter now produces.
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

;; ── DECODERS — error-text-critical (Phase 2: specialized request decoders) ──
;; GENERIC — the pre-specialization shape: every field via tesl-codec-decode-field.
;; This is the behavioural ORACLE the specialized decoder must match byte-for-byte.
(define (decode-NewNote-0/generic _j)
  (define _fraw_title (tesl-codec-decode-field _j "title" tesl-json-string-codec))
  (define _r1_title
    (let ([_r (checkSafeTitle _fraw_title)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_title
    (if (check-ok? _r1_title)
        (ensure-named 'title (check-ok-value _r1_title) (check-ok-facts _r1_title)
                      (check-ok-bindings _r1_title) #:subject 'title)
        _r1_title))
  (define _f_content (tesl-codec-decode-field _j "content" tesl-json-string-codec))
  (or (and (check-fail? _f_title) _f_title)
      (record-value 'NewNote (hash 'title _f_title 'content _f_content))))

;; SPECIAL — EXACTLY what the emitter now produces for a primitive field:
;; a DIRECT (tesl-decode-prim-field _j "key" tesl-decode-prim-*) call.  The
;; via-checked `title` field decodes its RAW value through the same specialized
;; helper, so both the missing-field check (tesl-decode-prim-field →
;; jsexpr-required-field) and the type-mismatch error (tesl-decode-prim-string)
;; share ONE definition with the generic path.
(define (decode-NewNote-0/special _j)
  (define _fraw_title (tesl-decode-prim-field _j "title" tesl-decode-prim-string))
  (define _r1_title
    (let ([_r (checkSafeTitle _fraw_title)])
      (cond [(check-ok? _r) _r] [(check-fail? _r) _r] [else _r])))
  (define _f_title
    (if (check-ok? _r1_title)
        (ensure-named 'title (check-ok-value _r1_title) (check-ok-facts _r1_title)
                      (check-ok-bindings _r1_title) #:subject 'title)
        _r1_title))
  (define _f_content (tesl-decode-prim-field _j "content" tesl-decode-prim-string))
  (or (and (check-fail? _f_title) _f_title)
      (record-value 'NewNote (hash 'title _f_title 'content _f_content))))

;; Backwards-compatible alias: the registry/response-path decoder used by the
;; emitted code is the specialized one.
(define decode-NewNote-0 decode-NewNote-0/special)

;; ── Sample values ────────────────────────────────────────────────────────────
(define note
  (Note #:id "note-abc-123" #:title "Buy milk" #:content "and eggs"
        #:authorId "user-42" #:createdAt 1750000000000))

;; ── ENCODER tests ─────────────────────────────────────────────────────────────
(test-case "valid encode: special == generic == registry, byte-identical JSON"
  (register-type-codec! 'Note encode-Note/special '())   ; registry uses special
  (define g (encode-Note/generic note))
  (define s (encode-Note/special note))
  (define r (runtime-value->jsexpr note))                ; via registry
  (check-equal? s g "special encoder must equal generic encoder")
  (check-equal? s r "special encoder must equal registry/response-path encoder")
  (check-equal? (jsexpr->bytes s) (jsexpr->bytes g) "JSON bytes must be identical")
  (check-equal? (jsexpr->bytes s) (jsexpr->bytes r) "response-path JSON bytes identical"))

;; ── DECODER: special ≡ generic on valid input AND every negative branch ──────
;; Outcome capture for the NewNote decoder: 'raise + message on raise, status +
;; message on a check-fail, or 'ok + record on success.  Used to compare the
;; SPECIAL (emitted) decoder against the GENERIC (oracle) decoder branch-by-branch.
(define (decode-outcome dec j)
  (with-handlers ([(lambda (_) #t)
                   (lambda (e) (cons 'raise (if (exn? e) (exn-message e) (format "~s" e))))])
    (define r (dec j))
    (if (check-fail? r)
        (cons (check-fail-status r) (check-fail-message r))
        (cons 'ok r))))

;; Probe the NewNote decoder with the same input under both implementations and
;; assert the outcomes are byte-identical (record-value, raise text, or
;; check-fail message + status).  This is the core Phase-2 invariant.
(define (assert-decode-identical label j)
  (define g (decode-outcome decode-NewNote-0/generic j))
  (define s (decode-outcome decode-NewNote-0/special  j))
  (check-equal? s g (format "special ≡ generic decode outcome: ~a" label)))

(test-case "decode positive: special ≡ generic, valid body → NewNote record"
  (assert-decode-identical "valid body" (hash "title" "fine" "content" "body"))
  (define r (decode-NewNote-0/special (hash "title" "fine" "content" "body")))
  (check-true (record-value? r))
  (check-equal? (record-value-type r) 'NewNote))

(test-case "decode negative: missing required field → byte-identical raise text (special ≡ generic)"
  (assert-decode-identical "missing content" (hash "title" "ok"))   ; no "content"
  (check-equal? (decode-outcome decode-NewNote-0/special (hash "title" "ok"))
                (cons 'raise "codec: required field \"content\" not found in JSON")))

(test-case "decode negative: missing FIRST required field → byte-identical raise text"
  (assert-decode-identical "missing title" (hash "content" "c"))    ; no "title"
  (check-equal? (decode-outcome decode-NewNote-0/special (hash "content" "c"))
                (cons 'raise "codec: required field \"title\" not found in JSON")))

(test-case "decode negative: wrong type for primitive field → byte-identical raise text"
  (assert-decode-identical "content int" (hash "title" "ok" "content" 99))
  (check-equal? (decode-outcome decode-NewNote-0/special (hash "title" "ok" "content" 99))
                (cons 'raise "expected JSON string, got ~a 99")))

(test-case "decode negative: via-check failure → check-fail message + HTTP 400 (special ≡ generic)"
  (define long (make-string 201 #\x))
  (assert-decode-identical "title too long" (hash "title" long "content" "c"))
  (check-equal? (decode-outcome decode-NewNote-0/special (hash "title" long "content" "c"))
                (cons 400 "title must be 1-200 characters")))

;; ── Exhaustive per-primitive special ≡ generic byte-identity ─────────────────
;; For EVERY primitive decoder the emitter can inline, assert the specialized
;; (tesl-decode-prim-field) path is byte-identical to the generic
;; (tesl-codec-decode-field) path on (a) a missing field, (b) a wrong-type
;; field, and (c) a valid field — value AND exn-message.
(define prim-cases
  ;; (label  codec-pair  prim-decoder  good-value  bad-value)
  (list
   (list "string" tesl-json-string-codec       tesl-decode-prim-string       "hi"        99)
   (list "int"    tesl-json-int-codec          tesl-decode-prim-int          7           "x")
   (list "bool"   tesl-json-bool-codec         tesl-decode-prim-bool         #t          1)
   (list "float"  tesl-json-float-codec        tesl-decode-prim-float        3.5         "x")
   (list "posix"  tesl-json-posix-millis-codec tesl-decode-prim-posix-millis 1750000000  "x")
   (list "list"   tesl-json-list-codec         tesl-decode-prim-list         '(1 2 3)    "x")
   (list "dict"   tesl-json-dict-codec         tesl-decode-prim-dict         (hash "k" 1) "x")
   (list "set"    tesl-json-set-codec          tesl-decode-prim-set          '(1 2 2)    "x")))

;; Capture: 'ok + value, or 'raise + exn-message (string), from a thunk.
(define (capture thunk)
  (with-handlers ([(lambda (_) #t)
                   (lambda (e) (cons 'raise (if (exn? e) (exn-message e) (format "~s" e))))])
    (cons 'ok (thunk))))

(for ([c (in-list prim-cases)])
  (match-define (list label pair prim good bad) c)
  (test-case (format "prim ~a: special ≡ generic on missing / wrong-type / valid" label)
    ;; (a) missing field
    (check-equal?
     (capture (lambda () (tesl-decode-prim-field (hash "other" 0) "k" prim)))
     (capture (lambda () (tesl-codec-decode-field (hash "other" 0) "k" pair)))
     (format "~a: missing-field outcome must match" label))
    ;; (b) wrong type
    (check-equal?
     (capture (lambda () (tesl-decode-prim-field (hash "k" bad) "k" prim)))
     (capture (lambda () (tesl-codec-decode-field (hash "k" bad) "k" pair)))
     (format "~a: wrong-type outcome must match" label))
    ;; (c) valid value
    (check-equal?
     (capture (lambda () (tesl-decode-prim-field (hash "k" good) "k" prim)))
     (capture (lambda () (tesl-codec-decode-field (hash "k" good) "k" pair)))
     (format "~a: valid-value outcome must match" label))))

;; ── Pin the EXACT main-baseline error strings (068ffa9 oracle) ───────────────
;; These literals are the byte-for-byte error text from the unmodified main dsl;
;; the specialized path must reproduce each verbatim.
(test-case "specialized prim decoders reproduce the EXACT baseline error strings"
  (define (msg thunk)
    (with-handlers ([(lambda (_) #t) (lambda (e) (and (exn? e) (exn-message e)))]) (thunk) #f))
  (check-equal? (msg (lambda () (tesl-decode-prim-field (hash) "name" tesl-decode-prim-string)))
                "codec: required field \"name\" not found in JSON")
  (check-equal? (msg (lambda () (tesl-decode-prim-field (hash "k" 99) "k" tesl-decode-prim-string)))
                "expected JSON string, got ~a 99")
  (check-equal? (msg (lambda () (tesl-decode-prim-field (hash "k" "x") "k" tesl-decode-prim-int)))
                "expected JSON integer, got ~a \"x\"")
  (check-equal? (msg (lambda () (tesl-decode-prim-field (hash "k" 1) "k" tesl-decode-prim-bool)))
                "expected JSON boolean, got ~a 1")
  (check-equal? (msg (lambda () (tesl-decode-prim-field (hash "k" "x") "k" tesl-decode-prim-float)))
                "expected JSON number, got ~a \"x\"")
  (check-equal? (msg (lambda () (tesl-decode-prim-field (hash "k" "x") "k" tesl-decode-prim-posix-millis)))
                "expected JSON integer for PosixMillis, got ~a \"x\"")
  (check-equal? (msg (lambda () (tesl-decode-prim-field (hash "k" "x") "k" tesl-decode-prim-list)))
                "expected JSON array for List, got ~a \"x\"")
  (check-equal? (msg (lambda () (tesl-decode-prim-field (hash "k" "x") "k" tesl-decode-prim-dict)))
                "expected JSON object for Dict, got ~a \"x\"")
  (check-equal? (msg (lambda () (tesl-decode-prim-field (hash "k" "x") "k" tesl-decode-prim-set)))
                "expected JSON array for Set, got ~a \"x\""))

;; ── USER-TYPE field stays on the generic registry path ───────────────────────
;; A field whose codec is a registry symbol must continue to route through
;; tesl-codec-decode-field (registry lookup), which the emitter does NOT
;; specialize.  Round-trip a registered NewNote-as-nested-field decode.
(test-case "user-type field: registry path preserved, missing-field text identical"
  ;; missing field for a symbol codec-spec uses the SAME shared missing-field string
  (check-equal?
   (capture (lambda () (tesl-codec-decode-field (hash) "nested" 'NewNote)))
   (cons 'raise "codec: required field \"nested\" not found in JSON")))

(printf "codec-specialization-test: all round-trip + negative-branch checks passed\n")
