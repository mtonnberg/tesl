#lang racket

;; debug-test.rkt — Tests for dsl/debug/checkpoint.rkt (Phase 2)
;;
;; Covers:
;;   1. debug-enabled? parameter behavior
;;   2. breakpoints hash management
;;   3. thsl-src! function behavior (debug disabled) — 4-arg signature
;;   4. thsl-src! function behavior (debug enabled, no matching breakpoint)
;;   5. thsl-src! function behavior (debug enabled, matching breakpoint)
;;   6. Event structure verification (includes 'locals key)
;;   7. Concurrency / threading behavior
;;   8. thsl-src MACRO form (passes empty locals)
;;   9. thsl-display-value unwrapping behavior
;;  10. Locals capture in stopped events
;;  11. step-into-next? box behavior
;;  12. step-next-file box behavior
;;  13. handle-variables / infer-type-string coverage (via thsl-display-value)

(require rackunit
         racket/set
         racket/match
         "../dsl/debug/checkpoint.rkt"
         "../dsl/private/evidence.rkt"
         "../dsl/types.rkt")

;; ── Define a newtype for thsl-display-value tests ──────────────────────────
;; newtype-value struct constructor is not re-exported, so we use define-newtype
;; to create test values that wrap integers.
(define-newtype TestNewtype Integer)

;; ── Helper: run thunk in a new thread with a pump thread ──────────────────
;; Pump thread reads from event-ch, invokes callback, then puts on paused-ch.
(define (with-pump-thread callback thunk)
  (let* ([result-box (box #f)]
         [pump
          (thread
           (lambda ()
             (let ([evt (sync/timeout 2.0 event-ch)])
               (when evt
                 (callback evt)
                 (channel-put paused-ch 'continue)))))]
         [prog
          (thread
           (lambda ()
             (set-box! result-box (thunk))))])
    (thread-wait prog)
    (thread-wait pump)
    (unbox result-box)))

;; Helper: run program in thread, drain N events then resume each.
(define (drain-and-resume-n n thunk [resume-cmd 'continue])
  (let* ([events (box '())]
         [prog (thread thunk)])
    (for ([_ (in-range n)])
      (let ([evt (sync/timeout 2.0 event-ch)])
        (set-box! events (cons evt (unbox events)))
        (when evt (channel-put paused-ch resume-cmd))))
    (thread-wait prog)
    (reverse (unbox events))))

;; ── Helper ───────────────────────────────────────────────────────────────────

(define (check-equal/named name actual expected)
  (check-equal? actual expected
                (string-append name ": expected " (format "~v" expected)
                               ", got " (format "~v" actual))))

;; Reset step boxes before each test that manipulates them
(define (reset-step-boxes!)
  (set-box! step-into-next? #f)
  (set-box! step-next-file #f))

;; ── 1. debug-enabled? parameter ──────────────────────────────────────────────

(test-case "debug-enabled? defaults to false"
  (check-false (debug-enabled?) "default should be #f"))

(test-case "debug-enabled? can be parameterized to true"
  (parameterize ([debug-enabled? #t])
    (check-true (debug-enabled?) "should be #t inside parameterize")))

(test-case "debug-enabled? restores after parameterize"
  (parameterize ([debug-enabled? #t])
    (check-true (debug-enabled?)))
  (check-false (debug-enabled?) "should restore to #f after parameterize"))

(test-case "debug-enabled? nested parameterize"
  (parameterize ([debug-enabled? #t])
    (parameterize ([debug-enabled? #f])
      (check-false (debug-enabled?) "inner #f"))
    (check-true (debug-enabled?) "restored to outer #t")))

;; ── 2. breakpoints hash management ───────────────────────────────────────────

(test-case "breakpoints starts as mutable hash"
  (check-true (hash? breakpoints))
  (check-false (immutable? breakpoints)))

(test-case "breakpoints: hash-set! stores seteq"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "testfile.tesl" (seteq 1 2 3))
  (check-true (hash-has-key? breakpoints "testfile.tesl"))
  (check-true (set-member? (hash-ref breakpoints "testfile.tesl") 1))
  (check-true (set-member? (hash-ref breakpoints "testfile.tesl") 3))
  (hash-clear! breakpoints))

(test-case "breakpoints: set-member? works"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "foo.tesl" (seteq 10 20 30))
  (check-true  (set-member? (hash-ref breakpoints "foo.tesl" (seteq)) 10))
  (check-true  (set-member? (hash-ref breakpoints "foo.tesl" (seteq)) 20))
  (check-false (set-member? (hash-ref breakpoints "foo.tesl" (seteq)) 99))
  (hash-clear! breakpoints))

(test-case "breakpoints: missing file returns empty set"
  (hash-clear! breakpoints)
  (let ([s (hash-ref breakpoints "nonexistent.tesl" (seteq))])
    (check-equal? s (seteq) "missing file gives empty seteq")))

(test-case "breakpoints: replace file breakpoints (second set! replaces first)"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "replace.tesl" (seteq 1 2 3))
  (hash-set! breakpoints "replace.tesl" (seteq 5 6))
  (check-false (set-member? (hash-ref breakpoints "replace.tesl" (seteq)) 1)
               "old breakpoints replaced")
  (check-true  (set-member? (hash-ref breakpoints "replace.tesl" (seteq)) 5))
  (check-true  (set-member? (hash-ref breakpoints "replace.tesl" (seteq)) 6))
  (hash-clear! breakpoints))

(test-case "breakpoints: clearing a single file with empty set stops it firing"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "cleared.tesl" (seteq 5))
  ;; Replace with empty set — effectively clears that file
  (hash-set! breakpoints "cleared.tesl" (seteq))
  (let ([result #f])
    (thread-wait
     (thread
      (lambda ()
        (parameterize ([debug-enabled? #t])
          (set! result (thsl-src! "cleared.tesl" 5 (list) (lambda () 42)))))))
    (check-equal? result 42 "no breakpoint fires after clearing with empty set"))
  (hash-clear! breakpoints))

;; ── 3. thsl-src! when debug-enabled? = #f ─────────────────────────────────
;; Phase 2: thsl-src! now takes 4 args: file line locals thunk

(test-case "thsl-src!: returns thunk result when debug disabled"
  (hash-clear! breakpoints)
  (check-equal? (thsl-src! "any.tesl" 42 (list) (lambda () (+ 1 2))) 3))

(test-case "thsl-src!: returns string when debug disabled"
  (check-equal? (thsl-src! "any.tesl" 1 (list) (lambda () "hello")) "hello"))

(test-case "thsl-src!: returns #f when debug disabled (falsy result)"
  (check-false (thsl-src! "any.tesl" 1 (list) (lambda () #f))))

(test-case "thsl-src!: returns #t when debug disabled"
  (check-true (thsl-src! "any.tesl" 1 (list) (lambda () #t))))

(test-case "thsl-src!: returns empty list when debug disabled"
  (check-equal? (thsl-src! "any.tesl" 1 (list) (lambda () '())) '()))

(test-case "thsl-src!: returns list when debug disabled"
  (check-equal? (thsl-src! "f.tesl" 5 (list) (lambda () (list 1 2 3))) '(1 2 3)))

(test-case "thsl-src!: thunk evaluated exactly once when debug disabled"
  (let ([counter 0])
    (thsl-src! "x.tesl" 1 (list) (lambda () (set! counter (+ counter 1))))
    (check-equal? counter 1)))

(test-case "thsl-src!: exception propagates when debug disabled"
  (check-exn exn:fail?
             (lambda ()
               (thsl-src! "any.tesl" 1 (list) (lambda () (error "boom"))))))

(test-case "thsl-src!: locals ignored when debug disabled"
  ;; locals list is irrelevant when debug is off — should still return correctly
  (let ([locals (list (cons 'x 42) (cons 'y "hello"))])
    (check-equal? (thsl-src! "any.tesl" 1 locals (lambda () 99)) 99)))

(test-case "thsl-src!: no channel activity when debug disabled"
  ;; If channel-put were called, this would hang on a subsequent channel-get.
  (hash-set! breakpoints "with-bp.tesl" (seteq 10))
  (let ([result (thsl-src! "with-bp.tesl" 10 (list) (lambda () 99))])
    (check-equal? result 99 "should return without blocking even if breakpoint set"))
  (hash-clear! breakpoints))

;; ── 4. thsl-src! when debug enabled but no matching breakpoint ───────────────

(test-case "thsl-src!: no pause when file has no breakpoints"
  (hash-clear! breakpoints)
  (let ([result #f])
    (thread-wait
     (thread
      (lambda ()
        (parameterize ([debug-enabled? #t])
          (set! result (thsl-src! "nobreaks.tesl" 10 (list) (lambda () (+ 2 3))))))))
    (check-equal? result 5 "should return 5 without pausing")))

(test-case "thsl-src!: no pause when line not in breakpoints"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "partial.tesl" (seteq 5 15))
  (let ([result #f])
    (thread-wait
     (thread
      (lambda ()
        (parameterize ([debug-enabled? #t])
          (set! result (thsl-src! "partial.tesl" 99 (list) (lambda () (* 6 7))))))))
    (check-equal? result 42 "line 99 has no breakpoint, should not pause"))
  (hash-clear! breakpoints))

(test-case "thsl-src!: no pause for wrong file even if line matches"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "right.tesl" (seteq 5))
  (let ([result #f])
    (thread-wait
     (thread
      (lambda ()
        (parameterize ([debug-enabled? #t])
          (set! result (thsl-src! "wrong.tesl" 5 (list) (lambda () 88)))))))
    (check-equal? result 88 "wrong file should not pause"))
  (hash-clear! breakpoints))

;; ── 5. thsl-src! when debug enabled and breakpoint matches ───────────────────

(test-case "thsl-src!: pauses at breakpoint and resumes on channel-put"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "bp.tesl" (seteq 3))
  (let ([result #f])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  (set! result (thsl-src! "bp.tesl" 3 (list) (lambda () 100))))))])
      (let ([evt (sync/timeout 2.0 event-ch)])
        (when evt (channel-put paused-ch 'continue)))
      (thread-wait t))
    (check-equal? result 100 "should return 100 after resume"))
  (hash-clear! breakpoints))

(test-case "thsl-src!: returns correct value after resume"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "ret.tesl" (seteq 1))
  (let ([result #f])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  (set! result (thsl-src! "ret.tesl" 1 (list) (lambda () (* 3 4)))))))])
      (let ([evt (sync/timeout 2.0 event-ch)])
        (when evt (channel-put paused-ch 'continue)))
      (thread-wait t))
    (check-equal? result 12 "should return 12"))
  (hash-clear! breakpoints))

(test-case "thsl-src!: line 1 fires for matching file"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "line1fire.tesl" (seteq 1))
  (let ([result #f])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  (set! result (thsl-src! "line1fire.tesl" 1 (list) (lambda () 'line1-result))))))])
      (let ([evt (sync/timeout 2.0 event-ch)])
        (when evt (channel-put paused-ch 'continue)))
      (thread-wait t))
    (check-equal? result 'line1-result "should return 'line1-result"))
  (hash-clear! breakpoints))

;; ── 6. Event structure (Phase 2: includes 'locals key) ───────────────────────

(test-case "event: has all required keys including locals"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "allkeys.tesl" (seteq 1))
  (let ([event #f])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  (thsl-src! "allkeys.tesl" 1 (list) (lambda () 'done)))))])
      (set! event (sync/timeout 2.0 event-ch))
      (when event (channel-put paused-ch 'continue))
      (thread-wait t))
    (when (hash? event)
      (check-true (hash-has-key? event 'event)  "event key present")
      (check-true (hash-has-key? event 'file)   "file key present")
      (check-true (hash-has-key? event 'line)   "line key present")
      (check-true (hash-has-key? event 'reason) "reason key present")
      (check-true (hash-has-key? event 'locals) "locals key present (Phase 2)")))
  (hash-clear! breakpoints))

(test-case "event: reason is 'breakpoint' for bp-match"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "reason.tesl" (seteq 7))
  (let ([event #f])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  (thsl-src! "reason.tesl" 7 (list) (lambda () 'done)))))])
      (set! event (sync/timeout 2.0 event-ch))
      (when event (channel-put paused-ch 'continue))
      (thread-wait t))
    (when (hash? event)
      (check-equal? (hash-ref event 'reason #f) "breakpoint")))
  (hash-clear! breakpoints))

(test-case "event: file matches the exact string passed to thsl-src!"
  (hash-clear! breakpoints)
  (let ([file-path "/some/path/to/program.tesl"])
    (hash-set! breakpoints file-path (seteq 99))
    (let ([event #f])
      (let ([t (thread
                (lambda ()
                  (parameterize ([debug-enabled? #t])
                    (thsl-src! file-path 99 (list) (lambda () 'done)))))])
        (set! event (sync/timeout 2.0 event-ch))
        (when event (channel-put paused-ch 'continue))
        (thread-wait t))
      (when (hash? event)
        (check-equal? (hash-ref event 'file) file-path
                      "file in event should match exactly"))))
  (hash-clear! breakpoints))

(test-case "event: line number matches the line passed to thsl-src!"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "intline.tesl" (seteq 42))
  (let ([event #f])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  (thsl-src! "intline.tesl" 42 (list) (lambda () 'done)))))])
      (set! event (sync/timeout 2.0 event-ch))
      (when event (channel-put paused-ch 'continue))
      (thread-wait t))
    (when (hash? event)
      (check-equal? (hash-ref event 'line #f) 42 "line should be 42")))
  (hash-clear! breakpoints))

;; ── 7. Concurrency / threading ────────────────────────────────────────────────

(test-case "concurrency: event-ch and paused-ch are channels"
  (check-true (channel? event-ch))
  (check-true (channel? paused-ch)))

(test-case "concurrency: step-into-next? and step-next-file are boxes"
  (check-true (box? step-into-next?))
  (check-true (box? step-next-file)))

(test-case "concurrency: blocking works correctly with actual threads"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "conc.tesl" (seteq 5))
  (let ([reached-after (box #f)])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  (thsl-src! "conc.tesl" 5 (list) (lambda () 'mid))
                  (set-box! reached-after #t))))])
      (let ([evt (sync/timeout 2.0 event-ch)])
        (check-false (unbox reached-after) "thread should be blocked before resume")
        (when evt (channel-put paused-ch 'continue)))
      (thread-wait t)
      (check-true (unbox reached-after) "thread should have continued after resume")))
  (hash-clear! breakpoints))

(test-case "concurrency: multiple pauses in sequence each complete correctly"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "seq.tesl" (seteq 1 2 3))
  (let ([results (box '())])
    (define (add! sym) (set-box! results (cons sym (unbox results))))
    (define t
      (thread
       (lambda ()
         (parameterize ([debug-enabled? #t])
           (thsl-src! "seq.tesl" 1 (list) (lambda () (add! 'a)))
           (thsl-src! "seq.tesl" 2 (list) (lambda () (add! 'b)))
           (thsl-src! "seq.tesl" 3 (list) (lambda () (add! 'c)))))))
    (for ([_ (in-range 3)])
      (let ([evt (sync/timeout 2.0 event-ch)])
        (when evt (channel-put paused-ch 'continue))))
    (thread-wait t)
    (check-equal? (reverse (unbox results)) '(a b c)
                  "all three stops should complete in order"))
  (hash-clear! breakpoints))

;; ── 8. thsl-src MACRO ────────────────────────────────────────────────────────

(test-case "thsl-src macro: returns expr value when debug disabled"
  (let ([result (thsl-src "any.tesl" 42 (+ 1 2))])
    (check-equal? result 3 "should return 3")))

(test-case "thsl-src macro: returns string when debug disabled"
  (let ([result (thsl-src "any.tesl" 1 "hello")])
    (check-equal? result "hello")))

(test-case "thsl-src macro: pauses at breakpoint with matching file/line"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "mac.tesl" (seteq 5))
  (let ([result #f])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  (set! result (thsl-src "mac.tesl" 5 (+ 1 2))))))])
      (let ([evt (sync/timeout 2.0 event-ch)])
        (when evt (channel-put paused-ch 'continue)))
      (thread-wait t))
    (check-equal? result 3 "macro should pause and then return 3"))
  (hash-clear! breakpoints))

(test-case "thsl-src macro: sends empty locals list in event"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "mac2.tesl" (seteq 7))
  (let ([event #f])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  (thsl-src "mac2.tesl" 7 'done))))])
      (set! event (sync/timeout 2.0 event-ch))
      (when event (channel-put paused-ch 'continue))
      (thread-wait t))
    (when (hash? event)
      (check-equal? (hash-ref event 'locals '()) '()
                    "thsl-src macro sends empty locals")))
  (hash-clear! breakpoints))

;; ── 9. thsl-display-value unwrapping ─────────────────────────────────────────

(test-case "thsl-display-value: plain integer — ~v representation"
  (check-equal? (thsl-display-value 42) "42"))

(test-case "thsl-display-value: plain string — ~v representation"
  (check-equal? (thsl-display-value "hello") "\"hello\""))

(test-case "thsl-display-value: #t — ~v representation"
  (check-equal? (thsl-display-value #t) "#t"))

(test-case "thsl-display-value: #f — ~v representation"
  (check-equal? (thsl-display-value #f) "#f"))

(test-case "thsl-display-value: empty list shown as []"
  (check-equal? (thsl-display-value '()) "[]"))

(test-case "thsl-display-value: plain list shown as [...]"
  (check-equal? (thsl-display-value '(1 2 3)) "[1, 2, 3]"))

(test-case "thsl-display-value: named-value without facts — unwrapped inner value"
  (let ([nv (named-value 'x 99 '() (hash))])
    (check-equal? (thsl-display-value nv) "99")))

(test-case "thsl-display-value: named-value with detached-proof fact — shows annotation"
  (let* ([proof-fact '(IsPositive x)]
         [dp (detached-proof proof-fact (hash))]
         [nv (named-value 'x 99 (list dp) (hash))])
    (let ([result (thsl-display-value nv)])
      (check-true (string-contains? result "99") "should contain inner value")
      (check-true (string-contains? result "(IsPositive x)") "should contain proof fact"))))

(test-case "thsl-display-value: named-value with non-detached-proof fact — no annotation"
  (let* ([plain-fact '(SomeFact x)]  ; not a detached-proof
         [nv (named-value 'x 42 (list plain-fact) (hash))])
    ;; Non-detached-proof facts are filtered out in format-proof-list
    (check-equal? (thsl-display-value nv) "42")))

(test-case "thsl-display-value: check-ok unwrapped to inner value"
  (let ([ok (check-ok 42 '() (hash))])
    (check-equal? (thsl-display-value ok) "42")))

(test-case "thsl-display-value: newtype-value shown as (TypeName value)"
  (let ([nv (TestNewtype 55)])
    (let ([result (thsl-display-value nv)])
      (check-true (string-contains? result "55") "should contain inner value")
      (check-true (string-contains? result "TestNewtype") "should contain type name"))))

(test-case "thsl-display-value: symbol passed through with ~v"
  (check-equal? (thsl-display-value 'foo) "'foo"))

(test-case "thsl-display-value: number zero passed through"
  (check-equal? (thsl-display-value 0) "0"))

(test-case "thsl-display-value: list of integers rendered correctly"
  (check-equal? (thsl-display-value '(1 2 3)) "[1, 2, 3]"))

;; ── 10. Locals capture in stopped events ─────────────────────────────────────

(test-case "locals: empty list sent when no locals"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "locals0.tesl" (seteq 1))
  (let ([event #f])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  (thsl-src! "locals0.tesl" 1 '() (lambda () 'done)))))])
      (set! event (sync/timeout 2.0 event-ch))
      (when event (channel-put paused-ch 'continue))
      (thread-wait t))
    (check-equal? (hash-ref event 'locals '()) '()
                  "empty locals list in event"))
  (hash-clear! breakpoints))

(test-case "locals: single local appears in event"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "locals1.tesl" (seteq 5))
  (let ([event #f]
        [my-x 42])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  (thsl-src! "locals1.tesl" 5
                             (list (cons 'x my-x))
                             (lambda () 'done)))))])
      (set! event (sync/timeout 2.0 event-ch))
      (when event (channel-put paused-ch 'continue))
      (thread-wait t))
    (let ([locals (hash-ref event 'locals '())])
      (check-equal? (length locals) 1 "should have 1 local")
      (check-equal? (car (car locals)) 'x "name should be 'x")
      (check-equal? (cdr (car locals)) 42 "value should be 42")))
  (hash-clear! breakpoints))

(test-case "locals: multiple locals appear in event in order"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "locals2.tesl" (seteq 10))
  (let ([event #f]
        [a 1] [b "hello"] [c #t])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  (thsl-src! "locals2.tesl" 10
                             (list (cons 'a a) (cons 'b b) (cons 'c c))
                             (lambda () 'done)))))])
      (set! event (sync/timeout 2.0 event-ch))
      (when event (channel-put paused-ch 'continue))
      (thread-wait t))
    (let ([locals (hash-ref event 'locals '())])
      (check-equal? (length locals) 3 "should have 3 locals")
      (check-equal? (cdr (assq 'a locals)) 1     "a should be 1")
      (check-equal? (cdr (assq 'b locals)) "hello" "b should be 'hello'")
      (check-equal? (cdr (assq 'c locals)) #t    "c should be #t")))
  (hash-clear! breakpoints))

(test-case "locals: named-value in locals preserved as-is in event"
  (hash-clear! breakpoints)
  (hash-set! breakpoints "locals3.tesl" (seteq 1))
  (let ([event #f]
        [nv (named-value 'n 99 '() (hash))])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  (thsl-src! "locals3.tesl" 1
                             (list (cons 'n nv))
                             (lambda () 'done)))))])
      (set! event (sync/timeout 2.0 event-ch))
      (when event (channel-put paused-ch 'continue))
      (thread-wait t))
    (let* ([locals (hash-ref event 'locals '())]
           [n-val (cdr (assq 'n locals))])
      (check-true (named-value? n-val) "value in locals should still be named-value")
      (check-equal? (named-value-value n-val) 99 "inner value should be 99")))
  (hash-clear! breakpoints))

;; ── 11. step-into-next? box behavior ─────────────────────────────────────────

(test-case "step-into-next?: initially #f"
  (check-false (unbox step-into-next?) "step-into-next? should default to #f"))

(test-case "step-into-next?: when #t, fires at next thsl-src! regardless of breakpoints"
  (hash-clear! breakpoints)
  (reset-step-boxes!)
  (set-box! step-into-next? #t)
  (let ([event #f])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  (thsl-src! "any.tesl" 99 (list) (lambda () 'done)))))])
      (set! event (sync/timeout 2.0 event-ch))
      (when event (channel-put paused-ch 'continue))
      (thread-wait t))
    (check-true (hash? event) "event should have fired despite no breakpoint")
    (check-equal? (hash-ref event 'reason #f) "step" "reason should be 'step'"))
  (hash-clear! breakpoints)
  (reset-step-boxes!))

(test-case "step-into-next?: reset to #f after firing"
  (hash-clear! breakpoints)
  (reset-step-boxes!)
  (set-box! step-into-next? #t)
  (let ([events '()])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  ;; First call: step-into-next? is #t, should fire
                  (thsl-src! "file.tesl" 1 (list) (lambda () 'first))
                  ;; Second call: step-into-next? should be #f now (not step-over either),
                  ;; and no breakpoint — should NOT fire
                  (thsl-src! "file.tesl" 2 (list) (lambda () 'second)))))])
      ;; First event
      (let ([evt1 (sync/timeout 2.0 event-ch)])
        (when evt1
          (set! events (cons evt1 events))
          (channel-put paused-ch 'continue)))
      ;; Second call should NOT fire — no event within timeout
      (let ([evt2 (sync/timeout 0.2 event-ch)])
        (when evt2
          (set! events (cons evt2 events))
          (channel-put paused-ch 'continue)))
      (thread-wait t))
    (check-equal? (length events) 1 "only the first call should fire"))
  (hash-clear! breakpoints)
  (reset-step-boxes!))

(test-case "step-into-next?: resume with 'step-in re-arms the box"
  (hash-clear! breakpoints)
  (reset-step-boxes!)
  (hash-set! breakpoints "rearmed.tesl" (seteq 1))
  (let ([events '()])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  ;; Breakpoint at line 1
                  (thsl-src! "rearmed.tesl" 1 (list) (lambda () 'a))
                  ;; After step-in resume, step-into-next? = #t, so line 2 fires
                  (thsl-src! "rearmed.tesl" 2 (list) (lambda () 'b))
                  ;; After continue resume, nothing fires
                  (thsl-src! "rearmed.tesl" 3 (list) (lambda () 'c)))))])
      ;; Event 1: bp at line 1, resume with 'step-in
      (let ([evt1 (sync/timeout 2.0 event-ch)])
        (when evt1
          (set! events (cons evt1 events))
          (channel-put paused-ch 'step-in)))
      ;; Event 2: step fires at line 2, resume with 'continue
      (let ([evt2 (sync/timeout 2.0 event-ch)])
        (when evt2
          (set! events (cons evt2 events))
          (channel-put paused-ch 'continue)))
      ;; Line 3 should not fire
      (let ([evt3 (sync/timeout 0.2 event-ch)])
        (when evt3
          (set! events (cons evt3 events))
          (channel-put paused-ch 'continue)))
      (thread-wait t))
    (check-equal? (length events) 2 "exactly 2 events: bp + step")
    (when (>= (length events) 2)
      (check-equal? (hash-ref (second events) 'line #f) 1 "first event at line 1")
      (check-equal? (hash-ref (first events) 'line #f) 2 "second event at line 2")))
  (hash-clear! breakpoints)
  (reset-step-boxes!))

;; ── 12. step-next-file box behavior ──────────────────────────────────────────

(test-case "step-next-file: initially #f"
  (check-false (unbox step-next-file) "step-next-file should default to #f"))

(test-case "step-next-file: fires when file matches"
  (hash-clear! breakpoints)
  (reset-step-boxes!)
  (set-box! step-next-file "over.tesl")
  (let ([event #f])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  (thsl-src! "over.tesl" 5 (list) (lambda () 'done)))))])
      (set! event (sync/timeout 2.0 event-ch))
      (when event (channel-put paused-ch 'continue))
      (thread-wait t))
    (check-true (hash? event) "should have fired (file matches step-next-file)")
    (check-equal? (hash-ref event 'reason #f) "step" "reason should be 'step'"))
  (hash-clear! breakpoints)
  (reset-step-boxes!))

(test-case "step-next-file: does NOT fire when file does not match"
  (hash-clear! breakpoints)
  (reset-step-boxes!)
  (set-box! step-next-file "over.tesl")
  (let ([event #f])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  ;; Different file — should not fire step-over
                  (thsl-src! "other.tesl" 5 (list) (lambda () 'done)))))])
      (set! event (sync/timeout 0.2 event-ch))
      (thread-wait t))
    ;; step-next-file was "over.tesl" but we called with "other.tesl"
    ;; The box still has "over.tesl" since no stop occurred
    (check-false event "should NOT fire — file does not match step-next-file"))
  (hash-clear! breakpoints)
  (reset-step-boxes!))

(test-case "step-next-file: reset to #f after firing"
  (hash-clear! breakpoints)
  (reset-step-boxes!)
  (set-box! step-next-file "step.tesl")
  (let ([events '()])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  ;; First call at "step.tesl" — fires step-over
                  (thsl-src! "step.tesl" 1 (list) (lambda () 'a))
                  ;; Second call — step-next-file should be #f, no breakpoint — does NOT fire
                  (thsl-src! "step.tesl" 2 (list) (lambda () 'b)))))])
      (let ([evt1 (sync/timeout 2.0 event-ch)])
        (when evt1
          (set! events (cons evt1 events))
          (channel-put paused-ch 'continue)))
      (let ([evt2 (sync/timeout 0.2 event-ch)])
        (when evt2
          (set! events (cons evt2 events))
          (channel-put paused-ch 'continue)))
      (thread-wait t))
    (check-equal? (length events) 1 "only the first step-over should fire"))
  (hash-clear! breakpoints)
  (reset-step-boxes!))

(test-case "step-next-file: resume with 'step-over sets step-next-file to current file"
  (hash-clear! breakpoints)
  (reset-step-boxes!)
  (hash-set! breakpoints "stepover.tesl" (seteq 1))
  (let ([events '()])
    (let ([t (thread
              (lambda ()
                (parameterize ([debug-enabled? #t])
                  (thsl-src! "stepover.tesl" 1 (list) (lambda () 'a))
                  ;; resume with 'step-over should set step-next-file="stepover.tesl"
                  (thsl-src! "stepover.tesl" 2 (list) (lambda () 'b))
                  ;; After 'continue, nothing fires
                  (thsl-src! "stepover.tesl" 3 (list) (lambda () 'c)))))])
      ;; Event at line 1 (breakpoint), resume with 'step-over
      (let ([evt1 (sync/timeout 2.0 event-ch)])
        (when evt1
          (set! events (cons evt1 events))
          (channel-put paused-ch 'step-over)))
      ;; Event at line 2 (step-over fires), resume with 'continue
      (let ([evt2 (sync/timeout 2.0 event-ch)])
        (when evt2
          (set! events (cons evt2 events))
          (channel-put paused-ch 'continue)))
      ;; Line 3 should not fire
      (let ([evt3 (sync/timeout 0.2 event-ch)])
        (when evt3
          (set! events (cons evt3 events))
          (channel-put paused-ch 'continue)))
      (thread-wait t))
    (check-equal? (length events) 2 "bp + step-over = 2 events"))
  (hash-clear! breakpoints)
  (reset-step-boxes!))

;; ── 13. Provide exports ────────────────────────────────────────────────────────

(test-case "all expected bindings are provided"
  (check-true (parameter? debug-enabled?))
  (check-true (hash? breakpoints))
  (check-true (channel? event-ch))
  (check-true (channel? paused-ch))
  (check-true (box? step-into-next?))
  (check-true (box? step-next-file)))

(test-case "thsl-src! is a procedure"
  (check-true (procedure? thsl-src!)))

(test-case "thsl-display-value is a procedure"
  (check-true (procedure? thsl-display-value)))
