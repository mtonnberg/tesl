#lang racket/base

;;; value-tree.rkt — THE ONE structured-value renderer for every debug surface.
;;;
;;; ── Why this module exists ──────────────────────────────────────────────────
;;;
;;; Tesl has three debug surfaces that all show the paused frame's values:
;;;
;;;   1. dsl/debug/dap-server.rkt  LAUNCH mode — DAP Variables panel, lazily
;;;      expanded through `variablesReference` thunks.
;;;   2. dsl/debug/dap-server.rkt  ATTACH mode — the same panel, but fed from
;;;      values the debuggee process already rendered and streamed over the
;;;      control channel.
;;;   3. dsl/debug/headless-inspect.rkt — `tesl debug-inspect` / the MCP tool /
;;;      the control channel's `stopped` + `snapshot` JSON.
;;;
;;; Each of the three had grown its OWN notion of "what are this value's
;;; children" and "how does it display", and they had drifted apart:
;;;
;;;   • Attach mode and headless emitted a FLAT {name, value, type} row per
;;;     local, so every record / list / hash / queue arrived as one long string
;;;     and nothing in the panel could be expanded — the "it's just a JSON
;;;     string instead of a value tree" symptom, and the reason domain objects
;;;     (queues, caches, channels) were expandable in launch mode but not when
;;;     attached.
;;;   • Launch mode DID build a tree, but decided expandability by testing the
;;;     OUTER Racket representation: `record-value?`, `list?`, `hash?`,
;;;     `domain-object?`.  Tesl values routinely arrive wrapped — a proof-
;;;     carrying binding is a `named-value` around the record, a `check`ed one a
;;;     `check-ok`, a units/Money binding a `newtype-value` — and an ADT
;;;     (`Ok(record)`, `Some([...])`) matched no branch at all.  None of those
;;;     wrappers is `record-value?`, so those locals rendered as a composite
;;;     STRING in the value column while claiming to have no children.  Display
;;;     unwrapped; expansion did not.
;;;
;;; So the general defect was never "attach mode is flat" — it was that
;;; expandability was decided independently of, and inconsistently with,
;;; display.  This module makes that impossible to repeat: `value-children` and
;;; `value-display` are the only two answers, they unwrap identically, and
;;; `tests/dap-value-tree-tests.rkt` pins the invariant that ties them together:
;;;
;;;     If safe-display renders a value as a COMPOSITE (a record/ADT/tuple/list/
;;;     hash rendering, i.e. it has inner structure a human would want to drill
;;;     into), then value-children MUST return at least one child.
;;;
;;; A future value kind that displays as composite but forgets to enumerate its
;;; children fails that test rather than shipping as an unexpandable blob.
;;;
;;; ── The node shape ──────────────────────────────────────────────────────────
;;;
;;; `value->node` produces the wire form the flat surfaces stream:
;;;
;;;     {"name": "order", "value": "Order {…}", "type": "Order",
;;;      "children": [ …same shape… ],        ; absent when a leaf
;;;      "truncated": true}                   ; only when bounds clipped it
;;;
;;; It is BOUNDED (depth + breadth) because it crosses a socket: an unbounded
;;; eager walk of a live cache could be enormous, and a cyclic value would not
;;; terminate.  Launch mode does not use `value->node` — it stays lazy, walking
;;; `value-children` one level per `variables` request — but both paths share
;;; that one child enumeration, so they cannot disagree about what is
;;; expandable.  `tests/dap-value-tree-tests.rkt` asserts exactly that
;;; equivalence for a representative value set.

(require racket/list
         racket/string
         racket/format
         (only-in json string->jsexpr)
         (only-in "checkpoint.rkt" safe-display adt-field-keys-ordered)
         (only-in "../private/evidence.rkt"
                  named-value? named-value-value
                  check-ok? check-ok-value)
         (only-in "../types.rkt"
                  newtype-value? newtype-value-type-name newtype-value-value
                  record-value? record-value-type record-value-fields
                  adt-value? adt-value-type adt-value-variant adt-value-fields
                  secret-value? secret-header-value? secret-redaction-text)
         (only-in "domain-inspect.rkt"
                  domain-struct-name
                  domain-object?
                  domain-object-summary
                  domain-object-fields
                  domain-field-names
                  channel-connected-count
                  worker-pool-live))

(provide value-unwrap
         value-children
         value-display
         value-type
         composite-display?
         domain-child-label
         child-display
         value->node
         node-children
         node-leaf?
         DEFAULT-MAX-DEPTH
         DEFAULT-MAX-CHILDREN
         hash-summary
         hash-shape-label
         hash-display)

;; ── Bounds ────────────────────────────────────────────────────────────────────
;; Depth/breadth caps for the EAGER (`value->node`) walk only.  Deep enough that
;; a realistic queue-job → payload-record → field chain is fully visible, small
;; enough that one stop event stays a sane size on the wire.  A clipped node is
;; marked `truncated` so the client can say so instead of silently lying about
;; the value being complete.
(define DEFAULT-MAX-DEPTH 6)
(define DEFAULT-MAX-CHILDREN 200)

;; ── Unwrapping ────────────────────────────────────────────────────────────────

;; Strip the PROOF/EVIDENCE wrappers that carry no structure of their own, so
;; every downstream question ("what type is this", "what are its children") is
;; asked of the value a Tesl programmer actually wrote.  `newtype-value` is NOT
;; stripped here: its type name is meaningful in the value/type columns
;; (`Money(4200)`), so it is unwrapped only where we descend into children.
(define (value-unwrap v)
  (cond
    [(named-value? v) (value-unwrap (named-value-value v))]
    [(check-ok? v)    (value-unwrap (check-ok-value v))]
    [else v]))

;; Fully unwrap, newtypes included — used when enumerating children, where a
;; `Money(record)` must expand to the record's fields rather than dead-end.
(define (value-unwrap/newtype v)
  (let ([u (value-unwrap v)])
    (if (and (newtype-value? u) (not (secret-value? u)))
        (value-unwrap/newtype (newtype-value-value u))
        u)))
;; A SECRET newtype is deliberately NOT unwrapped above.  This is the subtle
;; one: `value-children` calls this, so descending into a secret would publish
;; its inner value as an expandable CHILD of the panel row — a child whose own
;; display is the plaintext, bypassing the display-side redaction entirely.
;; Stopping here makes a secret a leaf on the children side, which is the other
;; half of the composite⇒expandable invariant (see `composite-display?`).

;; ── Display ───────────────────────────────────────────────────────────────────

;; Compact, never-raising one-line summary of a raw hash, so a nested store
;; entry (a queue JOB {status, payload, attempts}, an email {to, subject, body,
;; status}, …) reads as e.g. `{status: pending, attempts: 0, …}` in the value
;; column INSTEAD of a raw `#hash(...)` dump — while still being expandable to
;; the full set of keys.  Any error falls back to safe-display, so this can
;; never break the panel.
(define HASH-SUMMARY-KEYS 3)       ; keys shown inline before the ellipsis
(define HASH-SUMMARY-VALUE-LEN 24) ; per-value truncation inside the summary

(define (truncate-str s n)
  (if (> (string-length s) n)
      (string-append (substring s 0 (max 0 (- n 1))) "…")
      s))

(define (hash-summary h)
  (with-handlers ([(lambda (_) #t) (lambda (_) (safe-display h))])
    (define n (hash-count h))
    (cond
      [(zero? n) "{}"]
      [else
       ;; Stable ordering: sort keys by their printed form so the inline preview
       ;; is deterministic across runs (hash iteration order is unspecified).
       (define keys (sort (hash-keys h) string<? #:key ~a))
       (define shown (if (> n HASH-SUMMARY-KEYS) (take keys HASH-SUMMARY-KEYS) keys))
       (define parts
         (for/list ([k (in-list shown)])
           (define vs (truncate-str (safe-display (hash-ref h k)) HASH-SUMMARY-VALUE-LEN))
           (format "~a: ~a" (~a k) vs)))
       (string-append "{" (string-join parts ", ")
                      (if (> n HASH-SUMMARY-KEYS) ", …" "")
                      "}")])))

;; Friendlier label for a hash whose shape we recognise — only when CHEAP and
;; UNAMBIGUOUS (presence of the diagnostic keys), so we never special-case
;; fragilely.  Returns a short prefix or #f (fall back to hash-summary).
(define (hash-shape-label h)
  (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
    (cond
      ;; A queue JOB entry: id (optional) + status + attempts.
      [(and (hash-has-key? h 'status) (hash-has-key? h 'attempts))
       (define id (or (and (hash-has-key? h 'id) (hash-ref h 'id))
                      (and (hash-has-key? h 'job-id) (hash-ref h 'job-id)) #f))
       (if id
           (format "job ~a — ~a" (safe-display id) (~a (hash-ref h 'status)))
           (format "job — ~a" (~a (hash-ref h 'status))))]
      ;; An email outbox entry: to + subject + status.
      [(and (hash-has-key? h 'to) (hash-has-key? h 'subject) (hash-has-key? h 'status))
       (format "email → ~a — ~a [~a]"
               (~a (hash-ref h 'to))
               (truncate-str (~a (hash-ref h 'subject)) HASH-SUMMARY-VALUE-LEN)
               (~a (hash-ref h 'status)))]
      [else #f])))

;; Value-column display for a (non-empty) hash: a recognised-shape label when we
;; have one, otherwise the compact key summary.  Never raises.
(define (hash-display h)
  (or (hash-shape-label h) (hash-summary h)))

;; THE display string for any value in any debug surface.  A raw hash gets the
;; compact expandable summary (never a `#hash(...)` dump); a domain object gets
;; its live one-line summary; everything else defers to safe-display, which is
;; also what the value-tree tests measure "does this look composite" against.
(define (value-display v)
  (with-handlers ([(lambda (_) #t) (lambda (_) "<unprintable>")])
    (define u (value-unwrap v))
    (cond
      ;; A secret reads as exactly "[redacted]" — no wrapper, no length, no
      ;; prefix.  The TYPE column still says `Password` (see `value-type`), so
      ;; nothing about which value you are looking at is lost.  Paired with the
      ;; `composite-display?` clause below: a redacted secret must read as a
      ;; LEAF on both the display and the children side, and
      ;; tests/dap-value-tree-tests.rkt pins those two together.
      [(or (secret-value? u) (secret-header-value? u)) secret-redaction-text]
      [(domain-object? u) (domain-object-summary u)]
      ;; A worker thread reads as its liveness, not as `#<thread>`.  Stated at the
      ;; VALUE level (rather than as a special case of the worker-pool's `threads`
      ;; field) so it holds however deep the thread is reached from.
      [(thread? u) (if (thread-running? u) "running" "stopped")]
      ;; An SSE channel's listeners hash maps key → (listof callback), one callback
      ;; per CONNECTED CLIENT.  A list of callbacks is therefore a client count.
      [(and (list? u) (pair? u) (andmap procedure? u))
       (format "~a connected client(s)" (length u))]
      [(procedure? u) "<callback>"]
      [(and (hash? u) (positive? (hash-count u))) (hash-display u)]
      [else (safe-display v)])))

;; A human-readable type string, GDP-unwrapped.  Single definition — this was
;; previously copy-pasted in dap-server.rkt and headless-inspect.rkt.
(define (value-type v)
  (with-handlers ([(lambda (_) #t) (lambda (_) "")])
    (define u (value-unwrap v))
    (cond
      [(newtype-value? u)  (~a (newtype-value-type-name u))]
      [(record-value? u)   (~a (record-value-type u))]
      [(adt-value? u)      (~a (adt-value-type u))]
      [(domain-object? u)  (~a (domain-struct-name u))]
      [(string? u)         "String"]
      [(boolean? u)        "Bool"]
      [(integer? u)        "Int"]
      [(rational? u)       "Float"]
      [(list? u)           "List"]
      [(hash? u)           "Hash"]
      [else                ""])))

;; ── The composite invariant ───────────────────────────────────────────────────
;;
;; Does this value's DISPLAY string claim inner structure?  A record renders
;; `T {a: 1}`, an ADT `Ok(1)` / `Some {x: 2}`, a tuple `(1, 2)`, a list
;; `[1, 2]`, a hash `{k: v}` — all of which a user expects to expand.  Scalars
;; (`42`, `"hi"`, `True`, a nullary variant like `Nothing`) render with no such
;; brackets and are correctly leaves.
;;
;; This is deliberately computed from the DISPLAY STRING, not from the value's
;; type, because that is precisely the disagreement being ruled out: the test
;; that pairs this with `value-children` cannot be satisfied by teaching both
;; sides the same wrong answer.
(define (composite-display? v)
  (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
    ;; "[redacted]" carries a bracket, so the display-string heuristic below
    ;; would call a secret composite while `value-children` correctly reports a
    ;; leaf — the exact disagreement this invariant exists to rule out.  A
    ;; secret is a leaf, stated once, before the heuristic.
    (define u (value-unwrap v))
    (cond
     [(or (secret-value? u) (secret-header-value? u)) #f]
     [else (composite-display?/heuristic v)])))

(define (composite-display?/heuristic v)
  (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
    (define s (value-display v))
    (and (string? s)
         ;; Ignore brackets that are merely inside a string literal ("a, b"):
         ;; strip quoted spans first, then look for structure.
         (let ([bare (regexp-replace* #rx"\"[^\"]*\"" s "S")])
           (and (regexp-match? #rx"[{(\\[]" bare)
                ;; An EMPTY composite ({} / [] / ()) has nothing to expand.
                (not (regexp-match? #rx"^(\\{\\}|\\[\\]|\\(\\))$" (string-trim bare)))
                #t)))))

;; ── Child enumeration — the single source of truth ────────────────────────────
;;
;; Returns a list of (cons child-name-string child-raw-value) — the ONE answer to
;; "what can this value be expanded into", shared by the lazy DAP launch path and
;; the eager wire path.  '() means leaf.  Never raises: an unreadable value is a
;; leaf, not a crashed panel.
(define (value-children v)
  (with-handlers ([(lambda (_) #t) (lambda (_) '())])
    (define u (value-unwrap/newtype v))
    (cond
      ;; Domain runtime objects (queue / cache / SSE channel / email / workers)
      ;; get their named struct fields, with the live counts special-cased.
      [(domain-object? u) (domain-children u)]
      ;; A Tesl record: one child per field, key-sorted for a stable panel.
      [(record-value? u)
       (let ([fields (record-value-fields u)])
         (for/list ([k (in-list (sort (hash-keys fields) string<? #:key ~a))])
           (cons (~a k) (hash-ref fields k))))]
      ;; An ADT / tuple: children in the SAME order safe-display prints them
      ;; (shared via adt-field-keys-ordered).  Positional and tuple fields are
      ;; labelled by index so `Ok(record)` expands to `[0] → the record`.
      [(adt-value? u) (adt-children u)]
      ;; A list: indexed elements.
      [(and (list? u) (pair? u))
       (for/list ([el (in-list u)] [i (in-naturals)])
         (cons (format "[~a]" i) el))]
      ;; A raw hash (an entity ROW from select, a queue store, a cache store, a
      ;; job payload): key → value, key-sorted.  Recursing through here is what
      ;; makes a job's record payload drill on into its own fields.
      [(and (hash? u) (positive? (hash-count u)))
       (for/list ([k (in-list (sort (hash-keys u) string<? #:key ~a))])
         (cons (~a k) (hash-ref u k)))]
      ;; A box (worker threads, email outbox) — expand what it holds.
      [(box? u)
       (let ([inner (unbox u)])
         (if (or (and (list? inner) (pair? inner))
                 (and (hash? inner) (positive? (hash-count inner))))
             (value-children inner)
             '()))]
      ;; A string that IS a JSON document.  Tesl stores ADTs and structured job
      ;; payloads as JSON text (see dsl/sql.rkt's encoding and the queue store),
      ;; and a bound SQL param for an ADT arrives here as exactly that.  Such a
      ;; value is genuinely a string, so the value column rightly shows the raw
      ;; text — but leaving it a LEAF means the one thing a user wants from it
      ;; (what's inside) needs a text editor.  Parsed lazily and only when the
      ;; text is unambiguously a JSON object/array, so ordinary strings are
      ;; untouched.
      [(string? u) (json-string-children u)]
      [else '()])))

;; Children of a JSON-document string, or '() when it is not one.
;;
;; Guarded deliberately tightly: the trimmed text must OPEN with `{` or `[`, must
;; parse, and must parse to a non-empty object/array.  A JSON scalar ("42",
;; "true") is left alone — expanding it would add a level that shows the same
;; value again.  Bounded by a length cap so the debugger never parses a megabyte
;; blob to render one row.
(define JSON-CHILD-MAX-LENGTH 200000)

(define (json-string-children s)
  (with-handlers ([(lambda (_) #t) (lambda (_) '())])
    (define t (string-trim s))
    (cond
      [(> (string-length t) JSON-CHILD-MAX-LENGTH) '()]
      [(not (or (string-prefix? t "{") (string-prefix? t "["))) '()]
      [else
       (define parsed (string->jsexpr t))
       (cond
         [(and (hash? parsed) (positive? (hash-count parsed)))
          (for/list ([k (in-list (sort (hash-keys parsed) string<? #:key ~a))])
            (cons (~a k) (hash-ref parsed k)))]
         [(and (list? parsed) (pair? parsed))
          (for/list ([el (in-list parsed)] [i (in-naturals)])
            (cons (format "[~a]" i) el))]
         [else '()])])))

;; ADT children, ordered by the shared ordering function so the expanded tree
;; and the inline value string never disagree about field order.
(define (adt-children u)
  (define fields (adt-value-fields u))
  (define-values (layout keys) (adt-field-keys-ordered u))
  (case layout
    [(nullary) '()]
    ;; Tuple / positional: label by index — `(a, b)` expands to [0], [1].
    [(tuple positional)
     (for/list ([k (in-list keys)] [i (in-naturals)])
       (cons (format "[~a]" i) (hash-ref fields k)))]
    ;; Named variant fields keep their names.
    [else
     (for/list ([k (in-list keys)]) (cons (~a k) (hash-ref fields k)))]))

;; Children of a domain object: one entry per struct field under its display
;; name, with the three fields whose RAW value is meaningless to a human
;; (listeners callbacks, worker threads, a store hash) replaced by their live
;; count — while staying expandable into the detail.
;;
;; Represented as (name . value) pairs like every other child list; the DAP
;; layer turns the synthetic count labels into their display strings via
;; `domain-child-label` below.
(define (domain-children v)
  (define name (domain-struct-name v))
  (define fields (domain-object-fields v))
  (define field-names (domain-field-names name (length fields)))
  (for/list ([fn (in-list field-names)] [fv (in-list fields)])
    (cons fn fv)))

;; The display string for a domain object's field, given the owning struct kind
;; and the field name.  Live counts beat raw struct dumps: an SSE channel's
;; `listeners` reads "3 connected client(s)", a worker pool's `threads` reads
;; "2 live / 4 total", a store reads "{7 entries}".  Returns #f when the field
;; has no special rendering (caller falls back to value-display).
(define (domain-child-label struct-name field-name fv)
  (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
    (cond
      [(and (eq? struct-name 'channel-spec) (equal? field-name "listeners") (hash? fv))
       (format "~a connected client(s)" (channel-connected-count fv))]
      [(and (eq? struct-name 'worker-pool) (equal? field-name "threads"))
       (let ([ts (cond [(box? fv) (unbox fv)] [(list? fv) fv] [else '()])])
         (format "~a live / ~a total" (worker-pool-live fv) (length ts)))]
      [(hash? fv) (format "{~a entries}" (hash-count fv))]
      [(and (box? fv) (list? (unbox fv))) (format "[~a items]" (length (unbox fv)))]
      [else #f])))

;; The display string for ONE child of `parent`, named `field-name`.  This is
;; where a domain object's live-count labels are applied; every other child
;; falls through to the ordinary value-display.  Both the lazy DAP path and the
;; eager wire path call it, so a queue's `store` reads "{7 entries}" identically
;; whether the session launched the program or attached to it.
(define (child-display parent field-name child-val)
  (define pu (value-unwrap/newtype parent))
  (or (and (domain-object? pu)
           (domain-child-label (domain-struct-name pu) field-name child-val))
      (value-display child-val)))

;; ── Eager, bounded tree for the wire ──────────────────────────────────────────

;; Render (name . value) into the nested jsexpr node the flat surfaces stream.
;; `depth` counts DOWN; at 0 a value that still has children is emitted as a
;; leaf marked `truncated` so the client can distinguish "no children" from
;; "children not sent".
(define (value->node name v
                     #:max-depth [max-depth DEFAULT-MAX-DEPTH]
                     #:max-children [max-children DEFAULT-MAX-CHILDREN]
                     #:display [display-str #f])
  (with-handlers ([(lambda (_) #t)
                   (lambda (_) (hasheq 'name (~a name) 'value "<unprintable>" 'type ""))])
    (define kids (value-children v))
    (define base
      (hasheq 'name  (~a name)
              'value (or display-str (value-display v))
              'type  (value-type v)))
    (cond
      [(null? kids) base]
      [(<= max-depth 0) (hash-set base 'truncated #t)]
      [else
       (define clipped? (> (length kids) max-children))
       (define shown (if clipped? (take kids max-children) kids))
       (define child-nodes
         (for/list ([kv (in-list shown)])
           (value->node (car kv) (cdr kv)
                        #:max-depth (sub1 max-depth)
                        #:max-children max-children
                        ;; Live-count labels for a domain object's fields — the
                        ;; same strings the lazy DAP path shows.
                        #:display (child-display v (car kv) (cdr kv)))))
       (let ([h (hash-set base 'children child-nodes)])
         (if clipped? (hash-set h 'truncated #t) h))])))

;; Accessors for a node received off the wire (the DAP attach path walks these).
(define (node-children n)
  (if (and (hash? n) (list? (hash-ref n 'children '()))) (hash-ref n 'children '()) '()))
(define (node-leaf? n) (null? (node-children n)))
