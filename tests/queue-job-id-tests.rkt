#lang racket

;;; Queue job ids — GitHub #79.
;;;
;;; `tesl_jobs.id` is a PRIMARY KEY on a table that accumulates rows (undrained
;;; `pending` jobs, `dead` letters), and the insert happens inside the enqueuing
;;; request's transaction — so an id collision fails the CALLER's unrelated
;;; request with `duplicate key value violates unique constraint
;;; "tesl_jobs_pkey"`.
;;;
;;; The bug was `(symbol->string (gensym 'job))`.  Two properties matter, and
;;; only one of them is visible from inside a single process:
;;;
;;;   1. uniqueness WITHIN a process — gensym had this;
;;;   2. uniqueness ACROSS processes — gensym did NOT.  Its counter is a
;;;      process-local integer that restarts near the same low value in every
;;;      fresh process, so a restarted server replays ids that a previous run
;;;      already committed.  A single-process uniqueness test passes happily
;;;      while production collides after a few hundred accumulated rows.
;;;
;;; Test 3 is therefore the one that would have caught the bug: it mints ids in
;;; two COLD subprocesses and requires them to differ.

(require rackunit
         rackunit/text-ui
         racket/port
         racket/system
         racket/runtime-path
         (only-in "../tesl/queue.rkt" make-job-id))

(define-runtime-path repo-root "..")

;; UUID v7, lowercase, with the version nibble pinned to 7 and the RFC 4122
;; variant bits pinned to 10xx (`8`/`9`/`a`/`b`).
(define job-id-rx
  #px"^job-[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

(define (mint-id-in-fresh-process)
  (define queue-path
    (path->string (build-path (path->complete-path repo-root) "tesl" "queue.rkt")))
  (define out
    (with-output-to-string
      (lambda ()
        (unless (system* (find-executable-path "racket")
                         "-e"
                         (format "(require (file ~s)) (displayln (make-job-id))"
                                 queue-path))
          (error 'queue-job-id-tests "subprocess racket run failed")))))
  (string-trim out))

(define queue-job-id-tests
  (test-suite
   "queue job ids (#79)"

   (test-case "shape is job- + UUID v7"
     (for ([_ (in-range 50)])
       (define id (make-job-id))
       (check-regexp-match job-id-rx id
                           (format "job id ~a is not job- + UUID v7" id))
       ;; The old 5-digit gensym shape must never come back: ~90k values is a
       ;; ~50% chance of a collision by ~354 accumulated rows (birthday bound).
       (check-false (regexp-match? #px"^job[0-9]{1,8}$" id))))

   (test-case "10k ids in one process are unique"
     (define n 10000)
     (define ids (for/set ([_ (in-range n)]) (make-job-id)))
     (check-equal? (set-count ids) n "duplicate job id within one process"))

   (test-case "ids do not repeat across cold processes (the gensym bug)"
     (define a (mint-id-in-fresh-process))
     (define b (mint-id-in-fresh-process))
     (check-regexp-match job-id-rx a)
     (check-regexp-match job-id-rx b)
     (check-not-equal? a b
                       "two cold processes minted the SAME job id — a restarted
server would collide with rows a previous run committed"))

   (test-case "time-ordered: the v7 millisecond prefix is non-decreasing"
     ;; Not a strict-ordering claim (ids inside one millisecond are unordered) —
     ;; only that the 48-bit timestamp is really a clock, which is what makes the
     ;; `(queue_name, created_at)` dequeue index and the id agree on order.
     (define (ms-prefix id)
       (define hex (substring id 4 12))          ; strip "job-", take 8 hex chars
       (string->number hex 16))
     (define first-ms (ms-prefix (make-job-id)))
     (define later-ms (ms-prefix (make-job-id)))
     (check-true (>= later-ms first-ms))
     ;; A zero/absent timestamp would still satisfy >= — pin that it is a real
     ;; recent clock reading (upper 32 bits of Unix-millis are ~0x0195… in 2026).
     (check-true (> first-ms #x01900000)))))

(module+ main
  (void (run-tests queue-job-id-tests)))

(module+ test
  (void (run-tests queue-job-id-tests)))
