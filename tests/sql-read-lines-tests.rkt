#lang racket

;;; The runtime half of "show the SQL lens on the query LINE".
;;;
;;; A checkpoint pauses BEFORE its statement, so a breakpoint ON a query line
;;; stopped with nothing captured yet and the SQL scope was not advertised at
;;; all — with no way out when the query is the function's LAST statement.  The
;;; compiler now lists the lines whose statement is a READ-ONLY query
;;; (register-sql-read-lines!) and the runtime swaps those pauses to AFTER the
;;; statement.  Pinned here, with no database and no DAP client:
;;;
;;;   * the line table round-trips and is keyed per file;
;;;   * a read line runs its statement BEFORE the stop (so the capture exists),
;;;     and the statement's result reaches the reported locals;
;;;   * a non-listed line still stops BEFORE its statement (writes unchanged);
;;;   * `pause-shows-sql?` distinguishes "this line's statement" from "the last
;;;     statement that ran before this line", which is what lets every surface
;;;     label the lens instead of silently attributing a stale statement to the
;;;     line you are stopped on.
;;;
;;; The compiler-side table is pinned by compiler/test/test_sql_read_lines.ml.

(putenv "TESL_DEBUG" "1")

(require rackunit
         racket/async-channel
         (only-in tesl/dsl/debug/checkpoint
                  ;; the FUNCTION, not the expansion-gated macro: this test is
                  ;; compiled without TESL_DEBUG, where the macro erases to (void).
                  register-sql-read-lines!/runtime sql-read-line? pause-shows-sql?
                  thsl-src!/runtime breakpoints make-bp-record
                  set-debug-active! event-ch paused-ch))

(define FILE "/tmp/probe.tesl")
(define OTHER "/tmp/other.tesl")

;; ── The line table ──────────────────────────────────────────────────────────

(register-sql-read-lines!/runtime FILE '(12 30))

(check-true  (sql-read-line? FILE 12))
(check-true  (sql-read-line? FILE 30))
(check-false (sql-read-line? FILE 13) "a line that was not listed is not a read line")
(check-false (sql-read-line? OTHER 12)
             "the table is keyed per FILE: the same line number in another module is independent")

;; A non-integer / non-positive entry is ignored rather than poisoning the table.
(register-sql-read-lines!/runtime FILE (list "nope" 0 -3))
(check-false (sql-read-line? FILE 0))

;; ── Pause ordering ──────────────────────────────────────────────────────────
;; Drive a real checkpoint: arm a breakpoint, run thsl-src!/runtime in a thread,
;; and observe the ORDER of "statement ran" vs "stop reported".

(set-debug-active! #t)

(define (stop-at file line #:locals [locals '()] #:name [name #f])
  ;; Returns (values order stopped-event), where `order` is the sequence of marks
  ;; the run produced: 'ran when the statement body executed, 'stopped when the
  ;; checkpoint reported its stop.
  (hash-set! breakpoints file (list (make-bp-record line)))
  (define marks (box '()))
  (define (mark! m) (set-box! marks (cons m (unbox marks))))
  (define result (box #f))
  (define worker
    (thread
     (lambda ()
       (set-box! result
                 (thsl-src!/runtime file line locals
                                    (lambda () (mark! 'ran) 'the-value)
                                    name)))))
  (define evt (sync/timeout 5 event-ch))
  (mark! 'stopped)
  ;; Resume the parked statement and let it finish.
  (channel-put paused-ch 'continue)
  (unless (sync/timeout 5 worker) (error 'stop-at "worker never finished"))
  (hash-remove! breakpoints file)
  (values (reverse (unbox marks)) evt (unbox result)))

;; A READ line: the statement runs FIRST, then the stop is reported — which is
;; exactly why the SQL capture exists by the time the panel asks for it.
(let-values ([(order evt result) (stop-at FILE 12 #:name 'rows)])
  (check-equal? order '(ran stopped)
                "a read line runs its statement before reporting the stop")
  (check-true (hash? evt) "a stop was reported")
  (check-equal? (hash-ref evt 'line) 12)
  (check-equal? result 'the-value "the statement's value is returned unchanged")
  ;; The result is in the reported locals under the binding's name, so the frame
  ;; shows the rows the query returned.
  (check-equal? (assq 'rows (hash-ref evt 'locals))
                (cons 'rows 'the-value)
                "the statement's result reaches the paused frame's locals"))

;; A line that is NOT listed (any write, and every non-SQL statement): the stop
;; comes FIRST, so a breakpoint on a mutation still sees the world before it
;; changes.
(let-values ([(order evt _result) (stop-at FILE 13)])
  (check-equal? order '(stopped ran)
                "a non-read line reports its stop before running the statement")
  (check-equal? (hash-ref evt 'line) 13))

;; Locals passed by the emitter are preserved either way; only the read line adds
;; the statement's own result on top.
(let-values ([(_o evt _r) (stop-at FILE 13 #:locals (list (cons 'n 7)))])
  (check-equal? (hash-ref evt 'locals) (list (cons 'n 7))
                "a before-pause reports exactly the emitter's locals"))

;; ── The freshness flag every surface labels the lens with ────────────────────
;; While parked on a read line the capture belongs to THIS line; anywhere else it
;; is at best the previous statement.  Checked from inside the pause, which is
;; when the DAP / attach / headless surfaces read it.

(check-false (pause-shows-sql?) "false while nothing is parked")

(define (flag-while-paused-at line)
  (hash-set! breakpoints FILE (list (make-bp-record line)))
  (define seen (make-async-channel))
  (define worker
    (thread (lambda ()
              (thsl-src!/runtime FILE line '() (lambda () 'v) #f))))
  (sync/timeout 5 event-ch)
  ;; Read the flag exactly where a surface would: while the debuggee is parked.
  (async-channel-put seen (pause-shows-sql?))
  (channel-put paused-ch 'continue)
  (sync/timeout 5 worker)
  (hash-remove! breakpoints FILE)
  (sync seen))

(check-true  (flag-while-paused-at 12)
             "parked on a read line: the capture is this line's statement")
(check-false (flag-while-paused-at 13)
             "parked anywhere else: any capture is an earlier statement")
(check-false (pause-shows-sql?) "cleared again once the pause resumes")

(set-debug-active! #f)

(printf "sql-read-lines-tests: all checks passed\n")
