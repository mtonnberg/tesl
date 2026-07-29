#lang racket

;; dap-value-tree-tests.rkt — the regression barrier for the debugger's value
;; lenses.
;;
;; THE BUG CLASS UNDER TEST
;; ------------------------
;; The Variables panel showed some values as an unexpandable one-line blob (the
;; "it's just a JSON string, not a value tree" symptom), and domain objects
;; (queues / caches / SSE channels) were expandable when the session LAUNCHED the
;; program but not when it ATTACHED to a running one.  Two independent roots:
;;
;;   R1  Expandability was decided by testing the OUTER Racket representation
;;       (`record-value?`, `list?`, `hash?`, `domain-object?`).  Tesl values
;;       routinely arrive WRAPPED — a proof-carrying binding is a `named-value`
;;       around the record, a `check`ed one a `check-ok`, a units/Money binding a
;;       `newtype-value` — and an ADT (`Ok(record)`, `Some([...])`) matched no
;;       branch at all.  safe-display unwrapped all of those; the expandability
;;       test did not.  So the value column showed inner structure while the
;;       tree claimed the value had no children.
;;
;;   R2  The attach + headless surfaces rendered a FLAT {name,value,type} row per
;;       local, discarding structure at the source, and the DAP attach path
;;       hardcoded `variablesReference: 0`.
;;
;; THE DESIGN FIX THIS TEST GUARDS
;; ------------------------------
;; dsl/debug/value-tree.rkt is now the ONLY answer to both "how does this value
;; display" and "what are its children", for all three surfaces.  The invariant
;; below is what makes R1 structurally unrepeatable:
;;
;;     COMPOSITE-IMPLIES-EXPANDABLE
;;     If value-display renders a value with inner structure (a record / ADT /
;;     tuple / list / hash rendering), value-children MUST return ≥1 child.
;;
;; It is deliberately stated across the two functions and measured from the
;; DISPLAY STRING, so it cannot be satisfied by teaching both sides the same
;; wrong answer — a new value kind that displays as composite but forgets to
;; enumerate children fails here instead of shipping as a blob.
;;
;; The second half pins R2: the EAGER wire tree (`value->node`, what attach and
;; headless stream) and the LAZY child walk (what DAP launch mode expands) agree
;; node-for-node on name / value / type / has-children.  Divergence between the
;; launch and attach panels is a test failure, not a support ticket.

(require rackunit
         racket/list
         racket/string
         json
         (only-in tesl/dsl/types
                  record-value adt-value newtype-value)
         (only-in tesl/dsl/private/evidence
                  named-value check-ok)
         tesl/dsl/debug/value-tree)

(printf "\n=== DAP value-tree: composite ⇒ expandable, launch ≡ attach ===\n\n")

;; ── Representative value corpus ───────────────────────────────────────────────
;;
;; Every shape a paused Tesl frame realistically binds.  The wrapped entries are
;; the ones that used to render as unexpandable blobs.

(define order-record
  (record-value 'Order 'order-identity (hash 'amount 4200 'currency "USD")))

(define nested-record
  (record-value 'Invoice 'invoice-identity (hash 'id 7 'order order-record)))

;; ADT with positional fields — `Ok(record)`.  Previously matched NO branch of
;; the expandability test, so the record inside was unreachable.
;; (The 4-argument adt-value form takes an explicit identity, so these fixtures
;; need no `define-adt` declaration.)
(define ok-adt (adt-value 'Result 'result-identity 'Ok (hash 'field-0 order-record)))

;; ADT with named fields.
(define named-adt
  (adt-value 'Shape 'shape-identity 'Circle (hash 'radius 3 'centre "origin")))

;; Nullary variant — correctly a LEAF (nothing to drill into).
(define nothing-adt (adt-value 'Maybe 'maybe-identity 'Nothing (hash)))

;; Tuple sugar — `(1, "a")`.
(define tuple2
  (adt-value 'Tuple2 'tuple2-identity 'Tuple2 (hash 'first 1 'second "a")))

;; A queue JOB entry exactly as define-queue stores it.
(define job-entry (hash 'status 'pending 'payload order-record 'attempts 0))

;; The wrappers.  Each wraps a COMPOSITE, so each must stay expandable.
;; named-value is (name value facts bindings); check-ok is (value facts bindings).
(define proof-record   (named-value 'order order-record (list 'ValidOrder) (hash)))
(define checked-record (check-ok order-record (list 'Checked) (hash)))
(define money-newtype  (newtype-value 'Money order-record))
(define proof-list     (named-value 'xs (list 1 2 3) (list 'NonEmpty) (hash)))

(define CORPUS
  (list (cons "record"                order-record)
        (cons "nested record"         nested-record)
        (cons "positional ADT"        ok-adt)
        (cons "named ADT"             named-adt)
        (cons "tuple"                 tuple2)
        (cons "raw hash (queue job)"  job-entry)
        (cons "list"                  (list 1 2 3))
        (cons "list of records"       (list order-record order-record))
        (cons "named-value record"    proof-record)
        (cons "check-ok record"       checked-record)
        (cons "newtype record"        money-newtype)
        (cons "named-value list"      proof-list)))

(define LEAF-CORPUS
  (list (cons "int"              42)
        (cons "string"           "hello")
        (cons "bool"             #t)
        (cons "nullary variant"  nothing-adt)
        (cons "empty hash"       (hash))
        (cons "empty list"       '())
        (cons "string with commas" "a, b, c")))

;; ── 1. THE INVARIANT ──────────────────────────────────────────────────────────

(printf "── composite ⇒ expandable ──\n")

;; THE INVARIANT, stated over EVERY shape (structured and scalar alike): if the
;; display string shows inner structure, children must exist.  It is one-
;; directional on purpose — a value may legitimately display as a friendly
;; summary with no brackets (a queue job renders "job — pending") and still be
;; expandable.  What must never happen is the converse: structure visible in the
;; value column with nothing behind the expand arrow.
(test-case "COMPOSITE-IMPLIES-EXPANDABLE: bracketed display ⇒ ≥1 child"
  (for ([entry (in-list (append CORPUS LEAF-CORPUS))])
    (define label (car entry))
    (define v     (cdr entry))
    (define shown (value-display v))
    (when (composite-display? v)
      (check-true (pair? (value-children v))
                  (format "~a: displays as composite ~s but enumerates NO children — this is exactly the unexpandable-blob bug"
                          label shown)))))

(test-case "every structured value in the corpus is expandable"
  (for ([entry (in-list CORPUS)])
    (define label (car entry))
    (define v     (cdr entry))
    (check-true (pair? (value-children v))
                (format "~a: renders as ~s but has no children"
                        label (value-display v)))))

(test-case "scalars and empty composites stay leaves (no dead expand arrow)"
  (for ([entry (in-list LEAF-CORPUS)])
    (define label (car entry))
    (define v     (cdr entry))
    (check-true (null? (value-children v))
                (format "~a: must have no children, got ~a"
                        label (length (value-children v))))))

;; The specific wrapper regressions, called out by name so a failure says which.

(test-case "a PROOF-CARRYING record is expandable (named-value unwrapped)"
  (define kids (value-children proof-record))
  (check-equal? (sort (map car kids) string<?) '("amount" "currency")))

(test-case "a CHECKED record is expandable (check-ok unwrapped)"
  (check-equal? (sort (map car (value-children checked-record)) string<?)
                '("amount" "currency")))

(test-case "a NEWTYPE-wrapped record is expandable (Money(record) drills in)"
  (check-equal? (sort (map car (value-children money-newtype)) string<?)
                '("amount" "currency"))
  ;; …while the value column still shows the newtype name, not the bare record.
  (check-true (string-contains? (value-display money-newtype) "Money")
              "newtype name stays in the value column"))

(test-case "an ADT payload is expandable — Ok(record) drills to the record"
  (define kids (value-children ok-adt))
  (check-equal? (map car kids) '("[0]") "positional ADT field labelled by index")
  (define inner (cdr (first kids)))
  (check-equal? (sort (map car (value-children inner)) string<?)
                '("amount" "currency")
                "and the record inside the ADT drills on into its fields"))

(test-case "a named-field ADT expands under its field names"
  (check-equal? (sort (map car (value-children named-adt)) string<?)
                '("centre" "radius")))

(test-case "tuple children are index-labelled in display order"
  (check-equal? (map car (value-children tuple2)) '("[0]" "[1]"))
  (check-equal? (cdr (first (value-children tuple2))) 1))

;; ── 2. Display / expansion ordering agree ─────────────────────────────────────

(printf "── display order ≡ child order ──\n")

(test-case "ADT child order matches the order safe-display prints the fields"
  ;; safe-display prints `Circle {centre: origin, radius: 3}`; the expanded
  ;; children must appear in that same order, not hash order.
  (define shown (value-display named-adt))
  (define kid-names (map car (value-children named-adt)))
  (define positions (for/list ([n (in-list kid-names)])
                      (let ([m (regexp-match-positions (regexp (regexp-quote n)) shown)])
                        (if m (caar m) -1))))
  (check-equal? positions (sort positions <)
                (format "child order ~a must follow display order in ~s" kid-names shown)))

(test-case "record children are key-sorted (deterministic panel across runs)"
  (check-equal? (map car (value-children order-record)) '("amount" "currency")))

;; ── 3. Wire tree ≡ lazy walk (launch mode ≡ attach mode) ─────────────────────

(printf "── launch (lazy) ≡ attach (wire tree) ──\n")

;; The lazy walk DAP launch mode performs: expand one level per `variables`
;; request, using the same value-children / child-display the wire tree uses.
(define (lazy-walk name v depth)
  (define kids (if (<= depth 0) '() (value-children v)))
  (list (list (~a name) (value-display v) (value-type v) (pair? (value-children v)))
        (for/list ([kv (in-list kids)])
          (lazy-walk-child v (car kv) (cdr kv) (sub1 depth)))))

(define (lazy-walk-child parent name v depth)
  (define kids (if (<= depth 0) '() (value-children v)))
  (list (list (~a name) (child-display parent name v) (value-type v)
              (pair? (value-children v)))
        (for/list ([kv (in-list kids)])
          (lazy-walk-child v (car kv) (cdr kv) (sub1 depth)))))

;; The same walk read back out of the eager wire node.
(define (node-walk n)
  (list (list (hash-ref n 'name) (hash-ref n 'value) (hash-ref n 'type)
              (or (pair? (node-children n)) (hash-ref n 'truncated #f)))
        (for/list ([c (in-list (node-children n))]) (node-walk c))))

(test-case "the streamed tree and the lazily-expanded tree are identical"
  (for ([entry (in-list (append CORPUS LEAF-CORPUS))])
    (define label (car entry))
    (define v     (cdr entry))
    (define wire  (value->node label v #:max-depth 6))
    (check-equal? (node-walk wire) (lazy-walk label v 6)
                  (format "~a: attach-mode tree must equal launch-mode tree" label))))

;; ── 4. Wire-tree bounds are honest ───────────────────────────────────────────

(printf "── bounded wire tree ──\n")

(test-case "depth-clipped nodes are MARKED truncated, not silently flattened"
  (define n (value->node "invoice" nested-record #:max-depth 1))
  (define order-child
    (for/or ([c (in-list (node-children n))])
      (and (equal? (hash-ref c 'name) "order") c)))
  (check-true (and order-child #t) "the nested record is present as a child")
  (check-true (hash-ref order-child 'truncated #f)
              "clipped at the depth bound → must say so rather than look like a leaf")
  (check-true (null? (node-children order-child))))

(test-case "breadth-clipped nodes are MARKED truncated"
  (define big (for/list ([i (in-range 50)]) i))
  (define n (value->node "big" big #:max-children 10))
  (check-equal? (length (node-children n)) 10)
  (check-true (hash-ref n 'truncated #f) "clipping 50 → 10 must be reported"))

(test-case "an unclipped tree carries NO truncated marker"
  (define n (value->node "order" order-record #:max-depth 6))
  (check-false (hash-ref n 'truncated #f))
  (check-equal? (length (node-children n)) 2))

(test-case "value->node output is JSON-serialisable (it crosses a socket)"
  (for ([entry (in-list CORPUS)])
    (check-not-exn
     (lambda () (jsexpr->string (value->node (car entry) (cdr entry))))
     (format "~a must serialise" (car entry)))))

;; ── 4b. JSON-document strings are drillable ──────────────────────────────────
;;
;; Tesl stores ADTs and structured job payloads as JSON TEXT, so a paused frame
;; (and especially a bound SQL param) can legitimately hold a value that is a
;; string yet is really a document.  The value column rightly shows the raw text;
;; leaving it a LEAF meant the only thing anyone wants from it — what is inside —
;; required copying it into an editor.

(printf "── JSON strings ──\n")

(test-case "a JSON OBJECT string expands to its keys"
  (define s "{\"amount\":4200,\"currency\":\"USD\"}")
  (check-equal? (map car (value-children s)) '("amount" "currency"))
  (check-equal? (cdr (first (value-children s))) 4200))

(test-case "a JSON ARRAY string expands to indexed elements"
  (check-equal? (map car (value-children "[1,2,3]")) '("[0]" "[1]" "[2]")))

(test-case "nested JSON drills all the way down"
  (define s "{\"job\":{\"status\":\"pending\",\"attempts\":0}}")
  (define job (cdr (first (value-children s))))
  (check-equal? (sort (map car (value-children job)) string<?)
                '("attempts" "status")))

(test-case "the value column still shows the raw text, not a re-rendering"
  (define s "{\"a\":1}")
  (check-true (string-contains? (value-display s) "{\"a\":1}")
              "the string is shown as the string it is"))

(test-case "ORDINARY strings are untouched — no spurious expand arrow"
  (for ([s (in-list (list "hello"
                          "not json { at all"
                          "42"
                          "true"
                          "null"
                          ""
                          "  "
                          ;; looks like a brace but is not parseable JSON
                          "{oops"
                          ;; a JSON scalar: expanding would just repeat itself
                          "\"quoted\""))])
    (check-true (null? (value-children s))
                (format "~s must stay a leaf" s))))

(test-case "empty JSON containers are leaves (nothing to show)"
  (check-true (null? (value-children "{}")))
  (check-true (null? (value-children "[]"))))

(test-case "an absurdly large JSON string is not parsed to render one row"
  (define big (string-append "{\"k\":\"" (make-string 300000 #\x) "\"}"))
  (check-true (null? (value-children big))
              "past the length cap we decline rather than parse a huge blob"))

;; ── 5. Hash value-column rendering ───────────────────────────────────────────
;;
;; A raw hash (a select row, a queue store entry, a cache value) must read as a
;; compact human summary in the value column and NEVER as a `#hash(...)` dump —
;; while staying expandable to the full key set.  (Moved here with the code from
;; dap-server.rkt, so launch and attach are both covered by one suite.)

(printf "── hash value column ──\n")

(test-case "a job hash reads as a compact summary, not a raw #hash dump"
  (define s (value-display job-entry))
  (check-false (regexp-match? #rx"#hash" s) "no raw #hash blob")
  (check-true (string-contains? s "pending") "status surfaced in the summary line"))

(test-case "an email-shaped hash gets a friendly to/subject/status label"
  (define email (hash 'to "a@x" 'subject "Welcome" 'body "hi" 'status 'sent))
  (define s (hash-display email))
  (check-true (string-contains? s "a@x") "recipient surfaced")
  (check-true (string-contains? s "Welcome") "subject surfaced")
  (check-true (string-contains? s "sent") "status surfaced"))

(test-case "a wide hash truncates its inline summary but stays fully expandable"
  (define big (hash 'a 1 'b 2 'c 3 'd 4 'e 5))
  (define s (hash-summary big))
  (check-true (string-contains? s "…") "the inline preview is truncated")
  (check-false (regexp-match? #rx"#hash" s) "no raw blob")
  (check-equal? (length (value-children big)) 5
                "…and every key is still reachable by expanding"))

(test-case "hash-summary / hash-display never raise"
  (check-not-exn (lambda () (hash-summary (hash 'k (hash)))))
  (check-not-exn (lambda () (hash-display (hash)))))

;; ── 6. Never-raise contract ──────────────────────────────────────────────────

(printf "── fail-open on hostile values ──\n")

(test-case "the renderers never raise, whatever they are handed"
  (define hostile
    (list (box '()) (box (list 1 2)) (hash 'k (hash)) (vector 1 2 3)
          (lambda (x) x) (make-hash) 'sym 3.5 +inf.0))
  (for ([v (in-list hostile)])
    (check-not-exn (lambda () (value-display v)))
    (check-not-exn (lambda () (value-type v)))
    (check-not-exn (lambda () (value-children v)))
    (check-not-exn (lambda () (composite-display? v)))
    (check-not-exn (lambda () (value->node "h" v)))))

(test-case "a CYCLIC value cannot hang the eager wire walk"
  ;; The depth bound is what makes this safe — without it a cycle would spin
  ;; forever inside the debuggee while a client waited on the stop event.
  (define h (make-hash))
  (hash-set! h 'self h)
  (hash-set! h 'n 1)
  (check-not-exn (lambda () (value->node "cyclic" h #:max-depth 4))))

(printf "\n=== value-tree tests done ===\n")
