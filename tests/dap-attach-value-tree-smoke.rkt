#lang racket

;; dap-attach-value-tree-smoke.rkt — the ATTACH-mode half of the value-lens fix,
;; tested at the seam where it actually broke: the control channel's wire JSON.
;;
;; WHAT WAS WRONG
;; --------------
;; With `tesl run --debug` + a DAP attach session, the debuggee is a SEPARATE
;; process, so the adapter cannot walk live values — it renders whatever the
;; control channel streams in its `stopped` event.  That event used to carry one
;; FLAT {name, value, type} row per local, and the adapter's attach path
;; hardcoded `variablesReference: 0`.  Consequences the user sees:
;;
;;   • a record / list / hash local shows as a single long string with no expand
;;     arrow — "just a JSON string instead of an expandable value tree";
;;   • queues, caches and SSE channels are expandable when the session LAUNCHED
;;     the program but flat when it ATTACHED to one — the same panel behaving
;;     differently depending on how you started.
;;
;; WHAT THIS TEST PINS
;; -------------------
;; The wire JSON (headless-inspect's locals->json / domain->json, which is exactly
;; what control-channel.rkt streams) carries a NESTED `children` tree, survives a
;; real JSON round-trip, and reaches the leaves a user needs.  Together with
;; tests/dap-value-tree-tests.rkt (which pins that the streamed tree equals the
;; tree launch mode builds) and the dap-server.rkt in-module tests (which pin that
;; a node with children becomes an expandable variable), the attach and launch
;; panels cannot silently diverge again.

(require rackunit
         racket/string
         json
         "../tesl/queue.rkt"
         "../tesl/cache.rkt"
         (only-in "../dsl/capability.rkt" define-capability)
         (only-in "../dsl/private/domain-registry.rkt" domain-registry-clear!)
         (only-in "../dsl/types.rkt" record-value adt-value)
         (only-in "../dsl/debug/headless-inspect.rkt" locals->json domain->json))

(printf "\n=== attach wire JSON: structured locals + domain survive the wire ===\n\n")

(domain-registry-clear!)

;; ── Fixtures: a paused frame's locals, as checkpoint.rkt hands them over ──────
;; `locals` is an association list of (symbol . raw-value).

(define order
  (record-value 'Order 'order-identity (hash 'amount 4200 'currency "USD")))

(define invoice
  (record-value 'Invoice 'invoice-identity (hash 'id 7 'order order)))

;; A select row arrives as a raw hash, not a record struct.
(define row (hash 'id "todo-1" 'title "Ship it" 'done #f))

(define result-ok (adt-value 'Result 'result-identity 'Ok (hash 'field-0 order)))

(define LOCALS
  (list (cons 'invoice invoice)
        (cons 'row row)
        (cons 'outcome result-ok)
        (cons 'items (list order order))
        (cons 'count 3)
        ;; compiler-generated names must still be filtered out
        (cons 'tesl_tmp1 "internal")
        (cons '_ "ignored")))

;; ── Domain objects, registered exactly as an emitted program registers them ───

(define-queue AttachJobs
  #:job-types (AttachJob)
  #:max-attempts 3
  #:backoff exponential
  #:initial-delay 5)

(define-capability cacheCap_AttachCache)
(define-cache AttachCache #:default-ttl 60)

(hash-set! (queue-spec-store AttachJobs) "job-1"
           (hash 'payload order 'status 'pending 'attempts 0))
(hash-set! (cache-spec-store AttachCache) "k1" (vector "v1" #f))

;; ── Wire round-trip helper ───────────────────────────────────────────────────
;; Everything below is asserted on JSON that has actually been serialised and
;; re-parsed, so a shape that cannot cross a socket fails here.

(define (round-trip j) (string->jsexpr (jsexpr->string j)))

(define wire-locals (round-trip (locals->json LOCALS)))
(define wire-domain (round-trip (domain->json LOCALS)))

(define (find-node nodes name)
  (for/or ([n (in-list nodes)])
    (and (equal? (hash-ref n 'name #f) name) n)))

(define (kids n) (hash-ref n 'children '()))

(define (child-of n name) (find-node (kids n) name))

;; ── 1. Locals carry a real tree ──────────────────────────────────────────────

(printf "── locals ──\n")

(test-case "compiler-generated locals are still filtered out"
  (define names (map (lambda (n) (hash-ref n 'name)) wire-locals))
  (check-false (member "tesl_tmp1" names))
  (check-false (member "_" names))
  (check-not-false (member "invoice" names)))

(test-case "the {name,value,type} keys are unchanged (existing consumers keep working)"
  (define n (find-node wire-locals "count"))
  (check-equal? (hash-ref n 'name) "count")
  (check-equal? (hash-ref n 'value) "3")
  (check-equal? (hash-ref n 'type) "Int"))

(test-case "a scalar local carries NO children key (it is a leaf)"
  (check-equal? (kids (find-node wire-locals "count")) '()))

(test-case "a RECORD local streams its fields as children"
  (define n (find-node wire-locals "invoice"))
  (check-true (and n #t) "invoice present")
  (check-true (pair? (kids n))
              "a record must arrive WITH children — flat rows were the bug")
  (check-equal? (sort (map (lambda (c) (hash-ref c 'name)) (kids n)) string<?)
                '("id" "order")))

(test-case "nesting survives to the LEAVES, not just one level"
  ;; invoice → order → amount is the chain a user actually drills.
  (define amount
    (child-of (child-of (find-node wire-locals "invoice") "order") "amount"))
  (check-true (and amount #t) "invoice.order.amount reachable over the wire")
  (check-equal? (hash-ref amount 'value) "4200")
  (check-equal? (hash-ref amount 'type) "Int"))

(test-case "a raw select ROW streams its columns as children"
  (define n (find-node wire-locals "row"))
  (check-equal? (sort (map (lambda (c) (hash-ref c 'name)) (kids n)) string<?)
                '("done" "id" "title"))
  (check-equal? (hash-ref (child-of n "title") 'value "") "\"Ship it\""))

(test-case "an ADT local streams its payload — Ok(record) drills to the record"
  (define n (find-node wire-locals "outcome"))
  (check-true (pair? (kids n)) "an ADT payload must be reachable")
  (define inner (child-of n "[0]"))
  (check-true (and inner #t) "positional payload is index-labelled")
  (check-equal? (sort (map (lambda (c) (hash-ref c 'name)) (kids inner)) string<?)
                '("amount" "currency")))

(test-case "a LIST local streams indexed element children"
  (define n (find-node wire-locals "items"))
  (check-equal? (map (lambda (c) (hash-ref c 'name)) (kids n)) '("[0]" "[1]"))
  (check-true (pair? (kids (child-of n "[0]")))
              "and each element drills on into its own fields"))

;; ── 2. Domain objects carry a real tree ──────────────────────────────────────

(printf "── domain ──\n")

(test-case "the domain buckets still carry label / kind / summary"
  (define queues (hash-ref wire-domain 'queues))
  (check-equal? (length queues) 1)
  (define q (car queues))
  (check-true (string-contains? (hash-ref q 'summary) "AttachJobs"))
  (check-equal? (hash-ref q 'kind) "queue-spec"))

(test-case "a QUEUE streams expandable children (it was a bare summary line)"
  (define q (car (hash-ref wire-domain 'queues)))
  (check-true (pair? (kids q))
              "a queue must arrive WITH children so it expands when attached")
  (define names (map (lambda (c) (hash-ref c 'name)) (kids q)))
  (check-not-false (member "name" names))
  (check-not-false (member "store" names) "the live job store is reachable"))

(test-case "the queue's live JOB is reachable through the store, with its payload"
  (define q (car (hash-ref wire-domain 'queues)))
  (define store (child-of q "store"))
  (check-true (and store #t) "store child present")
  (check-true (string-contains? (hash-ref store 'value) "1 entries")
              "the store shows its live entry count")
  (define job (child-of store "job-1"))
  (check-true (and job #t) "the live job is a child of the store")
  ;; …and the job's record payload drills on into its fields.
  (define payload (child-of job "payload"))
  (check-true (and payload #t) "job payload present")
  (check-equal? (sort (map (lambda (c) (hash-ref c 'name)) (kids payload)) string<?)
                '("amount" "currency")))

(test-case "a CACHE streams expandable children too"
  (define c (car (hash-ref wire-domain 'caches)))
  (check-true (pair? (kids c)))
  (check-not-false (member "store" (map (lambda (k) (hash-ref k 'name)) (kids c)))))

;; ── 3. The wire stays bounded ────────────────────────────────────────────────

(printf "── bounded ──\n")

(test-case "a huge local is clipped and MARKED, never streamed whole"
  (define big (for/list ([i (in-range 1000)]) i))
  (define n (car (round-trip (locals->json (list (cons 'big big))
                                           #:max-children 25))))
  (check-equal? (length (kids n)) 25 "breadth bound applied")
  (check-true (hash-ref n 'truncated #f)
              "clipping must be reported, not silently pass as the whole value"))

(test-case "the whole stopped payload stays a sane size for one frame"
  ;; A guard against a future change quietly making every stop event enormous.
  (define bytes (string-length (jsexpr->string
                                (hasheq 'locals (locals->json LOCALS)
                                        'domain (domain->json LOCALS)))))
  (check-true (< bytes 200000)
              (format "one stop event should not be ~a bytes" bytes)))

(printf "\n=== attach wire JSON tests done ===\n")
