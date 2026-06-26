#lang racket

;; checkpoint.rkt — Step-debugger runtime for Tesl.
;;
;; This module provides:
;;   - debug-enabled? parameter (default #f)
;;   - breakpoints hash: file -> (seteq of 1-based line numbers)
;;   - event-ch / paused-ch channels for DAP server communication
;;   - step-into-next? box: when #t, pause at the very next thsl-src! call
;;   - step-next-file box: when set to a string, pause at next call in this file
;;   - thsl-src! / thsl-src macros: EXPANSION-TIME-GATED checkpoints (see B5 below)
;;   - thsl-src!/runtime function: (file line locals thunk) — Phase 2 with local capture
;;   - thsl-display-value: unwrap Tesl GDP wrappers for human display
;;
;; ── B5: one emission path, expansion-time debug gate ─────────────────────────
;; The OCaml emitter now ALWAYS emits the `(thsl-src! "file" line locals thunk)`
;; form — there is no `--debug` emitter fork.  `thsl-src!` (and the compat
;; `thsl-src`) are MACROS whose expansion is gated at raco-compile time,
;; mirroring the `zero-cost-proofs?` gate in dsl/private/check-runtime.rkt:
;;   • debug DISABLED (default) → the macro expands to the BARE expression (the
;;     thunk body), with ZERO residue: no checkpoint call, no locals list, no
;;     thunk allocation.  This is the release build — zero overhead.
;;   • debug ENABLED → the macro expands to a real (thsl-src!/runtime ...) call,
;;     which checks breakpoints / step flags against the debug-enabled? runtime
;;     parameter (set by the DAP server) before running the thunk.
;;
;; The gate is read at EXPANSION time (`tesl-debug-checkpoints?`, a for-syntax
;; predicate that consults TESL_DEBUG).  Reading it per-expansion (rather than
;; freezing it into this module's compiled form) means a debug session only has
;; to export TESL_DEBUG=1 in the process that compiles/loads the program — it
;; does not require recompiling this module.  The committed example .rkt
;; snapshots and the test corpus are compiled WITHOUT TESL_DEBUG, so they erase
;; to the bare expression and pay no checkpoint cost.

(require racket/set
         racket/string
         (only-in "../private/evidence.rkt"
                  named-value? named-value-value named-value-facts
                  check-ok? check-ok-value
                  detached-proof? detached-proof-fact)
         (only-in "../types.rkt"
                  newtype-value? newtype-value-type-name newtype-value-value
                  record-value? record-value-type record-value-fields
                  adt-value? adt-value-type adt-value-variant adt-value-fields)
         ;; STOP-THE-WORLD (task #42): the global registry lists every Tesl-spawned
         ;; background thread.  domain-registry.rkt is dependency-free (it requires
         ;; nothing from queue/cache/email/web), so this introduces no import cycle.
         (only-in "../private/domain-registry.rkt"
                  background-threads)
         (for-syntax racket/base
                     syntax/parse))

(provide
 debug-enabled?
 breakpoints
 event-ch
 paused-ch
 step-into-next?
 step-next-file
 thsl-src
 thsl-src!
 thsl-src!/runtime
 thsl-display-value
 safe-display
 format-proof-list
 ;; conditional-breakpoint support
 make-bp-record
 bp-record?
 bp-record-line
 bp-record-condition
 bp-record-hit-condition
 bp-record-hit-count
 file-breakpoint-lines
 eval-bp-condition
 eval-hit-condition
 ;; stop-the-world (task #42)
 stop-the-world-suspend!
 stop-the-world-resume!
 stop-the-world-suspended-count)

;; ── Parameters and state ─────────────────────────────────────────────────────

;; When #t, thsl-src checks for breakpoints before evaluating each expression.
(define debug-enabled? (make-parameter #f))

;; Maps filename (string) -> list of bp-record (see make-bp-record below).
;; Each record carries the 1-based line plus the optional DAP `condition` and
;; `hitCondition` expressions and a mutable hit counter.  A bare line breakpoint
;; is simply a record whose condition/hit-condition are both #f.
;;
;; Backward-compat note: code that only cares about *which lines* have a
;; breakpoint can use (file-breakpoint-lines breakpoints file) which returns a
;; seteq of line numbers regardless of whether the stored value is the new
;; record-list form or a legacy seteq (the DAP test harness still stores a bare
;; seteq via its own sim- handler — file-breakpoint-lines copes with both).
(define breakpoints (make-hash))

;; ── Breakpoint records ────────────────────────────────────────────────────────
;;
;; A bp-record bundles a line with its optional DAP condition / hitCondition and
;; a mutable hit counter.  `condition` and `hit-condition` are source strings (or
;; #f).  `hit-count` is a box of exact integer counting how many times execution
;; has reached this line (incremented BEFORE the condition gates, so hitCondition
;; semantics like ">= 3" mean "the 3rd time onward").
(struct bp-record (line condition hit-condition hit-count) #:transparent)

(define (make-bp-record line [condition #f] [hit-condition #f])
  (bp-record line
             (and (string? condition) (non-empty-string? (string-trim condition)) condition)
             (and (string? hit-condition) (non-empty-string? (string-trim hit-condition)) hit-condition)
             (box 0)))

;; Return a seteq of breakpoint line numbers for `file`, tolerating either the
;; new record-list representation or a legacy bare seteq (or absent → empty).
(define (file-breakpoint-lines bps file)
  (let ([entry (hash-ref bps file #f)])
    (cond
      [(not entry) (seteq)]
      [(set? entry) entry]                                  ; legacy seteq
      [(list? entry) (list->seteq (map bp-record-line entry))]
      [else (seteq)])))

;; Find the bp-record for `file`/`line` in the record-list representation, or #f
;; (also returns #f for the legacy seteq form, which carries no condition data).
(define (lookup-bp-record bps file line)
  (let ([entry (hash-ref bps file #f)])
    (and (list? entry)
         (for/or ([r (in-list entry)])
           (and (bp-record? r) (= (bp-record-line r) line) r)))))

;; Channel used to send events TO the DAP server.
;; Messages are hasheq with at least 'event, 'file, 'line, 'locals, 'reason keys.
(define event-ch (make-channel))

;; Channel used to receive resume commands FROM the DAP server.
;; DAP server puts a symbol ('continue, 'step-in, or 'step-over) when execution should resume.
(define paused-ch (make-channel))

;; step-into-next?: when #t, pause at the very next thsl-src! call
(define step-into-next? (box #f))

;; step-next-file: when set to a string, pause at next call in this file (step-over)
(define step-next-file (box #f))

;; ── Expansion-time debug gate ────────────────────────────────────────────────
;; for-syntax predicate consulted by the thsl-src! / thsl-src macros below.
;; TESL_DEBUG ∈ {1,true,yes,on} (case-insensitive) enables checkpoints; anything
;; else (including unset) erases them.  Mirrors the TESL_ZERO_COST_PROOFS gate.
(begin-for-syntax
  (define (tesl-debug-checkpoints?)
    (let ([v (getenv "TESL_DEBUG")])
      (and v
           (and (member (string-downcase v) '("1" "true" "yes" "on")) #t)))))

;; ── Conditional-breakpoint evaluation ─────────────────────────────────────────
;;
;; DAP conditional breakpoints let a user attach a boolean expression to a line;
;; the debugger only pauses when it evaluates truthy against the paused frame's
;; locals.  We do NOT shell back into the OCaml compiler nor `eval` arbitrary
;; Racket — instead we evaluate a small, safe expression grammar over the locals
;; alist.  This is deliberately bounded (see the task's "implement if bounded"
;; guidance): a misuse never compromises the runtime, and an unparseable/erroring
;; condition FAILS OPEN (treated as #t) so a breakpoint is never silently lost —
;; matching the "never regress diagnostics / reporting" invariant.
;;
;; Supported grammar (whitespace-insensitive):
;;   expr   := or
;;   or     := and ( "||" and )*
;;   and    := not ( "&&" not )*
;;   not    := "!" not | cmp
;;   cmp    := add ( ("=="|"!="|"<="|">="|"<"|">") add )?
;;   add    := mul ( ("+"|"-") mul )*
;;   mul    := atom ( ("*"|"/"|"%") atom )*
;;   atom   := number | string | "true" | "false" | ident | "(" expr ")"
;;
;; Identifiers resolve against the locals alist; values are GDP-unwrapped to
;; their raw payload (so `port > 1024` works even when `port` is a named-value /
;; check-ok / newtype wrapper).  Equality on strings/symbols uses equal?.

;; Unwrap GDP/proof wrappers down to a comparable raw scalar.
(define (bp-unwrap v)
  (cond
    [(named-value? v)   (bp-unwrap (named-value-value v))]
    [(check-ok? v)      (bp-unwrap (check-ok-value v))]
    [(newtype-value? v) (bp-unwrap (newtype-value-value v))]
    [else v]))

;; Tokenizer: turn a condition string into a list of tokens.  Tokens are either
;; symbols (for operators/identifiers/keywords) or (cons 'num n) / (cons 'str s).
;; Returns #f on a lexing error.
(define (bp-tokenize s)
  (define len (string-length s))
  (with-handlers ([exn:fail? (lambda (_e) #f)])
    (let loop ([i 0] [acc '()])
      (cond
        [(>= i len) (reverse acc)]
        [else
         (define c (string-ref s i))
         (cond
           [(char-whitespace? c) (loop (add1 i) acc)]
           ;; two-char operators
           [(and (< (add1 i) len)
                 (member (substring s i (+ i 2)) '("==" "!=" "<=" ">=" "&&" "||")))
            (loop (+ i 2) (cons (string->symbol (substring s i (+ i 2))) acc))]
           [(memv c '(#\< #\> #\! #\+ #\- #\* #\/ #\% #\( #\)))
            (loop (add1 i) (cons (string->symbol (string c)) acc))]
           ;; string literal
           [(char=? c #\")
            (let strloop ([j (add1 i)] [cs '()])
              (cond
                [(>= j len) (error "unterminated string")]
                [(char=? (string-ref s j) #\")
                 (loop (add1 j) (cons (cons 'str (list->string (reverse cs))) acc))]
                [else (strloop (add1 j) (cons (string-ref s j) cs))]))]
           ;; number (int or float)
           [(or (char-numeric? c) (and (char=? c #\.) (< (add1 i) len) (char-numeric? (string-ref s (add1 i)))))
            (let numloop ([j i] [cs '()])
              (if (and (< j len)
                       (let ([cc (string-ref s j)]) (or (char-numeric? cc) (char=? cc #\.))))
                  (numloop (add1 j) (cons (string-ref s j) cs))
                  (loop j (cons (cons 'num (string->number (list->string (reverse cs)))) acc))))]
           ;; identifier / keyword
           [(or (char-alphabetic? c) (char=? c #\_))
            (let idloop ([j i] [cs '()])
              (if (and (< j len)
                       (let ([cc (string-ref s j)])
                         (or (char-alphabetic? cc) (char-numeric? cc) (char=? cc #\_))))
                  (idloop (add1 j) (cons (string-ref s j) cs))
                  (loop j (cons (string->symbol (list->string (reverse cs))) acc))))]
           [else (error (format "unexpected char ~a" c))])]))))

;; Operator symbols built via string->symbol — NOT quoted literals.  The Racket
;; reader treats `||` as the EMPTY symbol (vertical bars delimit a symbol), so a
;; literal '|| would never eq? the tokenizer's (string->symbol "||").  Likewise
;; the parenthesis symbols are bar-quoted single chars here for clarity.
(define TOK-OR    (string->symbol "||"))
(define TOK-AND   (string->symbol "&&"))
(define TOK-LPAREN (string->symbol "("))
(define TOK-RPAREN (string->symbol ")"))
(define TOK-NOT   (string->symbol "!"))

;; Recursive-descent parser/evaluator over the token list, resolving identifiers
;; from `env` (a hash name-symbol -> raw value).  Returns the evaluated value.
;; Raises on parse/eval error (callers fail open).
(define (bp-parse-eval tokens env)
  (define toks (box tokens))
  (define (peek) (and (pair? (unbox toks)) (car (unbox toks))))
  (define (next!) (let ([t (car (unbox toks))]) (set-box! toks (cdr (unbox toks))) t))
  (define (expect! sym)
    (unless (eq? (peek) sym) (error (format "expected ~a" sym)))
    (next!))
  (define (truthy? v) (and v (not (eq? v 'false)) (not (equal? v #f))))

  (define (parse-or)
    (let loop ([acc (parse-and)])
      (if (eq? (peek) TOK-OR)
          (begin (next!) (loop (or (truthy? acc) (truthy? (parse-and)))))
          acc)))
  (define (parse-and)
    (let loop ([acc (parse-not)])
      (if (eq? (peek) TOK-AND)
          (begin (next!) (loop (and (truthy? acc) (truthy? (parse-not)))))
          acc)))
  (define (parse-not)
    (if (eq? (peek) TOK-NOT)
        (begin (next!) (not (truthy? (parse-not))))
        (parse-cmp)))
  (define (parse-cmp)
    (let ([l (parse-add)])
      (define op (peek))
      (if (memq op '(== != < > <= >=))
          (begin (next!)
            (let ([r (parse-add)])
              (case op
                [(==) (cmp-eq l r)]
                [(!=) (not (cmp-eq l r))]
                [(<)  (< l r)]
                [(>)  (> l r)]
                [(<=) (<= l r)]
                [(>=) (>= l r)])))
          l)))
  (define (parse-add)
    (let loop ([acc (parse-mul)])
      (case (peek)
        [(+) (next!) (loop (+ acc (parse-mul)))]
        [(-) (next!) (loop (- acc (parse-mul)))]
        [else acc])))
  (define (parse-mul)
    (let loop ([acc (parse-atom)])
      (case (peek)
        [(*) (next!) (loop (* acc (parse-atom)))]
        [(/) (next!) (loop (/ acc (parse-atom)))]
        [(%) (next!) (loop (modulo acc (parse-atom)))]
        [else acc])))
  (define (parse-atom)
    (define t (peek))
    (cond
      [(eq? t TOK-LPAREN) (next!) (let ([v (parse-or)]) (expect! TOK-RPAREN) v)]
      [(and (pair? t) (eq? (car t) 'num)) (next!) (cdr t)]
      [(and (pair? t) (eq? (car t) 'str)) (next!) (cdr t)]
      [(eq? t 'true)  (next!) #t]
      [(eq? t 'false) (next!) #f]
      [(symbol? t)    (next!)
       (if (hash-has-key? env t)
           (bp-unwrap (hash-ref env t))
           (error (format "unbound identifier ~a" t)))]
      [else (error "unexpected token")]))

  ;; equal? for cross-type-friendly comparison (string vs string, num vs num,
  ;; symbol vs string for enum-ish locals).
  (define (cmp-eq a b)
    (cond
      [(and (symbol? a) (string? b)) (string=? (symbol->string a) b)]
      [(and (string? a) (symbol? b)) (string=? a (symbol->string b))]
      [else (equal? a b)]))

  (let ([result (parse-or)])
    (unless (null? (unbox toks)) (error "trailing tokens"))
    result))

;; Build an env hash (name-symbol -> raw value) from a locals alist.
(define (locals->env locals)
  (for/hash ([pair (in-list locals)]
             #:when (and (pair? pair) (symbol? (car pair))))
    (values (car pair) (cdr pair))))

;; Evaluate a breakpoint `condition` string against `locals`.  Returns #t if the
;; breakpoint should fire.  No condition (#f / blank) → #t.  Any error → #t
;; (fail open) so a typo never silently disables a breakpoint.
(define (eval-bp-condition condition locals)
  (cond
    [(or (not condition) (not (string? condition))) #t]
    [(string=? (string-trim condition) "") #t]
    [else
     (with-handlers ([exn:fail? (lambda (_e) #t)])
       (define toks (bp-tokenize condition))
       (cond
         [(not toks) #t]
         [(null? toks) #t]
         [else
          (let ([v (bp-parse-eval toks (locals->env locals))])
            (and v (not (eq? v 'false)) (not (equal? v #f))))]))]))

;; Evaluate a DAP `hitCondition` against the current hit count.  A hitCondition
;; is a small spec: a bare number N means "fire on the Nth hit and after" (DAP
;; lets clients pick; we use >=N, the common VS Code behaviour), or an explicit
;; operator form like ">5", "==3", "<=10", "%2" (every 2nd hit).  hit-count is
;; the count INCLUDING the current hit (i.e. 1 on the first arrival).  No
;; hit-condition → #t.  Parse error → #t (fail open).
(define (eval-hit-condition hit-condition hit-count)
  (cond
    [(or (not hit-condition) (not (string? hit-condition))) #t]
    [(string=? (string-trim hit-condition) "") #t]
    [else
     (with-handlers ([exn:fail? (lambda (_e) #t)])
       (define s (string-trim hit-condition))
       (define m (regexp-match #px"^(==|>=|<=|>|<|%)?\\s*([0-9]+)$" s))
       (cond
         [(not m) #t]
         [else
          (define op (or (list-ref m 1) ">="))   ; bare N → >=N
          (define n  (string->number (list-ref m 2)))
          (case op
            [(">=") (>= hit-count n)]
            [(">")  (> hit-count n)]
            [("<=") (<= hit-count n)]
            [("<")  (< hit-count n)]
            [("==") (= hit-count n)]
            [("%")  (and (> n 0) (= 0 (modulo hit-count n)))]
            [else #t])]))]))

;; ── STOP-THE-WORLD: freeze background activity while paused (task #42) ─────────
;;
;; When a breakpoint (or step) pauses the debuggee, we FREEZE every other Tesl
;; background thread so the world the user is inspecting cannot change underfoot:
;; queue workers stop draining, the email/pubsub/cache pollers stop polling, timers
;; stop firing.  On resume we thaw exactly the set we froze.
;;
;; WHAT WE SUSPEND / WHAT WE NEVER SUSPEND
;; ---------------------------------------
;; We enumerate the global domain registry's 'threads list — which is populated
;; ONLY by the Tesl runtime's own spawn sites (queue.rkt / email.rkt / cache.rkt).
;; From that set we explicitly EXCLUDE:
;;   (a) (current-thread) — the thread hitting the breakpoint; it parks itself on
;;       paused-ch immediately after, so suspending it would deadlock the resume; and
;;   (b) the DAP adapter's own threads (its stdio server loop, the event pump, the
;;       debuggee runner, the resume helper).  Those are NOT Tesl background threads
;;       and never call register-background-thread!, so they are simply absent from
;;       the registry — the thread that must service `continue` can never be frozen.
;; We also skip any already-dead thread.
;;
;; RE-ENTRANCY: a stop while already stopped (nested checkpoint on the SAME thread)
;; only ever re-suspends the OTHER threads; the current thread is always excluded, so
;; nesting cannot self-deadlock.  The suspended set is recorded per-stop so resume
;; thaws precisely what this stop froze.
;;
;; CAVEATS (documented, by design):
;;   • This is suspend-not-time-freeze.  thread-suspend stops a thread from RUNNING,
;;     but WALL-CLOCK TIME KEEPS MOVING.  A timer/poller whose (sleep N) / deadline
;;     elapses while the debuggee is paused will therefore FIRE IMMEDIATELY on resume
;;     (it wakes to find its deadline already past).  True freezing of logical time
;;     would require a virtual clock injected into every sleep/alarm-evt — that is
;;     OUT OF SCOPE here and noted for a future "virtual clock" feature.
;;   • A thread blocked inside NATIVE I/O (an SMTP send, a blocking DB round-trip)
;;     suspends at the next safe point the Racket scheduler reaches, not necessarily
;;     instantly — best-effort, never forced mid-syscall.
;;   • FAIL-OPEN: any error enumerating/suspending threads is swallowed (logged to
;;     stderr only under TESL_DAP_LOG-style debugging) so a capture failure can never
;;     crash the debuggee or wedge the adapter — the breakpoint still fires.

;; The set of threads suspended for the CURRENT stop on THIS bp thread.  Stored in a
;; box on the parked thread's dynamic extent via a thread cell so concurrent stops on
;; different threads don't clobber each other's suspended set.
(define suspended-threads-cell (make-thread-cell '()))

;; How many threads the most recent suspend froze (diagnostic / test hook).
(define stop-the-world-last-count (box 0))
(define (stop-the-world-suspended-count) (unbox stop-the-world-last-count))

;; Suspend every registered Tesl background thread except the current one and any
;; already-dead thread.  Records the suspended set for the matching resume.  Returns
;; the suspended thread list.  Never raises (fail-open).
(define (stop-the-world-suspend!)
  (with-handlers ([exn:fail? (lambda (_e) '())])
    (define me (current-thread))
    (define to-suspend
      (for/list ([t (in-list (background-threads))]
                 #:when (and (thread? t)
                             (not (eq? t me))
                             (not (thread-dead? t))))
        t))
    ;; De-dup (a worker thread is registered once, but be defensive) and suspend.
    (define uniq
      (let loop ([ts to-suspend] [seen '()] [acc '()])
        (cond
          [(null? ts) (reverse acc)]
          [(memq (car ts) seen) (loop (cdr ts) seen acc)]
          [else (loop (cdr ts) (cons (car ts) seen) (cons (car ts) acc))])))
    (for ([t (in-list uniq)])
      (with-handlers ([exn:fail? void])
        (thread-suspend t)))
    (thread-cell-set! suspended-threads-cell uniq)
    (set-box! stop-the-world-last-count (length uniq))
    uniq))

;; Resume exactly the threads frozen by the matching stop-the-world-suspend! on this
;; thread, then clear the recorded set.  Never raises (fail-open).
(define (stop-the-world-resume!)
  (with-handlers ([exn:fail? (lambda (_e) (void))])
    (for ([t (in-list (thread-cell-ref suspended-threads-cell))])
      (with-handlers ([exn:fail? void])
        (when (and (thread? t) (not (thread-dead? t)))
          (thread-resume t))))
    (thread-cell-set! suspended-threads-cell '())))

;; ── thsl-src!/runtime function ───────────────────────────────────────────────

;; thsl-src!/runtime is the runtime checkpoint called by DEBUG builds.
;; Signature: (file line locals thunk)
;;   - locals is a list of (cons 'name value) pairs for the Variables panel
;; It checks breakpoints / step flags against the debug-enabled? parameter (set
;; by the DAP server) and, when a stop is warranted, blocks until the DAP server
;; resumes it.  Release builds never reach here — the thsl-src! macro erases the
;; call entirely (see below).
(define (thsl-src!/runtime file line locals thunk)
  (when (debug-enabled?)
    (let* ([line-hit?  (set-member? (file-breakpoint-lines breakpoints file) line)]
           ;; A line breakpoint fires only if its condition (if any) is truthy
           ;; against the current locals AND its hitCondition (if any) is met.
           ;; When the stored entry is the legacy seteq form (no records), there
           ;; is no condition/hitCondition, so a line hit fires unconditionally.
           [rec        (and line-hit? (lookup-bp-record breakpoints file line))]
           [bp-match?
            (and line-hit?
                 (cond
                   [(not rec) #t]   ; legacy seteq line, or unconditional record absent
                   [else
                    ;; DAP semantics: when both `condition` and `hitCondition` are
                    ;; present, the hit counter advances only on arrivals where the
                    ;; condition is satisfied — hitCondition then gates *those*
                    ;; hits.  So evaluate the condition first; only a satisfied
                    ;; condition increments the counter and consults hitCondition.
                    (and (eval-bp-condition (bp-record-condition rec) locals)
                         (let ([hc (add1 (unbox (bp-record-hit-count rec)))])
                           (set-box! (bp-record-hit-count rec) hc)
                           (eval-hit-condition (bp-record-hit-condition rec) hc)))]))]
           [step-in?   (unbox step-into-next?)]
           [step-over? (and (unbox step-next-file)
                            (equal? file (unbox step-next-file)))])
      (when (or bp-match? step-in? step-over?)
        ;; Reset step flags before pausing so they don't re-trigger immediately
        (set-box! step-into-next? #f)
        (set-box! step-next-file #f)
        ;; STOP-THE-WORLD: freeze all OTHER Tesl background threads BEFORE we report
        ;; the stop, so the queue depth / outbox / caches the user inspects cannot
        ;; change while paused.  Fail-open (never raises).  Resumed below when this
        ;; bp thread is released, which happens for continue / next / stepIn / stepOut
        ;; alike (every resume routes through paused-ch).
        (stop-the-world-suspend!)
        ;; Send stopped event with locals
        (channel-put event-ch
          (hasheq 'event  "stopped"
                  'file   file
                  'line   line
                  'locals locals
                  'reason (cond [bp-match? "breakpoint"]
                                [step-in?  "step"]
                                [else      "step"])))
        ;; Block until DAP sends a resume command, then interpret it
        (let ([cmd (channel-get paused-ch)])
          ;; Released: thaw exactly the threads this stop froze, BEFORE running on so
          ;; the program and its background workers proceed together.
          (stop-the-world-resume!)
          (cond
            [(eq? cmd 'step-in)
             (set-box! step-into-next? #t)]
            [(eq? cmd 'step-over)
             (set-box! step-next-file file)]
            [else
             ;; 'continue or any other symbol: no step flags set
             (void)])))))
  (thunk))

;; ── thsl-src! / thsl-src macros (expansion-time gated) ───────────────────────

;; thsl-src! is the form the emitter ALWAYS produces:
;;   (thsl-src! "file" line (list (cons 'x *x) ...) (lambda () expr))
;; • debug ON  → (thsl-src!/runtime "file" line (list ...) (lambda () expr))
;; • debug OFF → expr  (the bare thunk body — zero residue: no call, no locals
;;                      list, no closure allocation)
;; When the thunk is a literal `(lambda () body ...)` we splice `body ...`
;; directly so the erased form is the bare expression.  A non-literal thunk
;; (defensive fallback) erases to `(thunk)`.
(define-syntax (thsl-src! stx)
  (syntax-parse stx
    [(_ file:expr line:expr locals:expr thunk:expr)
     (if (tesl-debug-checkpoints?)
         #'(thsl-src!/runtime file line locals thunk)
         (syntax-parse #'thunk
           #:literals (lambda)
           [(lambda () body:expr ...+) #'(let () body ...)]
           [_ #'(thunk)]))]))

;; thsl-src macro: kept for compatibility — same gate, empty locals.  Accepts
;; both the (file line expr) compat shape and the 4-arg shape, routed through
;; thsl-src!.
(define-syntax (thsl-src stx)
  (syntax-parse stx
    [(_ file:expr line:expr expr:expr)
     #'(thsl-src! file line (list) (lambda () expr))]
    [(_ file:expr line:expr locals:expr thunk:expr)
     #'(thsl-src! file line locals thunk)]))

;; ── thsl-display-value ───────────────────────────────────────────────────────

;; Format a list of proof facts (detached-proof or other) into a display string.
(define (format-proof-list facts)
  (if (null? facts) ""
      (string-join
        (filter-map (lambda (f)
                      (cond
                        [(detached-proof? f)
                         (~a (detached-proof-fact f))]
                        [else #f]))
                    facts)
        ", ")))

;; safe-display: single function that unwraps GDP wrappers AND formats
;; for the VSCode Variables panel.  Returns a display string.
;;
;; Type rendering:
;;   String    → "hello"   (with quotes, to distinguish from numbers)
;;   Int/Float → 42        (no extra quotes)
;;   Bool      → True/False (Tesl capitalised)
;;   Symbol    → sym       (no Racket ' prefix)
;;   Record    → TypeName {field: val, ...}
;;   Newtype   → TypeName(val)
;;   ADT       → Variant or Variant(f0, f1) or Variant {field: val}
;;   Tuple     → (a, b, c)
;;   List      → [a, b, c]
;;   named-val → inner-val  [Proof1, Proof2]  (proof annotations appended, if any survive)
;;
;; NOTE on proofs: under unconditional erasure (zero-cost-proofs?) the runtime
;; values reaching this function carry NO proof facts — the [Proof, ...] suffix
;; below is therefore almost always empty.  The authoritative proof/type display
;; is overlaid by the DAP server from compile-time --local-bindings-json (see
;; overlay-binding-type in dap-server.rkt).  We keep the facts path for the rare
;; case a value is inspected with TESL_ZERO_COST_PROOFS=0.
(define (safe-display v)
  (cond
    ;; Unwrap GDP wrappers first
    [(named-value? v)
     (let* ([inner     (safe-display (named-value-value v))]
            [facts     (named-value-facts v)]
            [proof-str (format-proof-list facts)])
       (if (string=? proof-str "") inner
           (string-append inner "  [" proof-str "]")))]
    [(check-ok? v)      (safe-display (check-ok-value v))]
    ;; Format by Racket type
    [(newtype-value? v)
     (format "~a(~a)" (newtype-value-type-name v) (safe-display (newtype-value-value v)))]
    [(record-value? v)
     (let ([fields (record-value-fields v)])
       (string-append (~a (record-value-type v)) " {"
         (string-join
           (hash-map fields (lambda (k vv) (format "~a: ~a" k (safe-display vv))) #t)
           ", ")
         "}"))]
    [(adt-value? v)     (safe-display-adt v)]
    [(list? v)
     (string-append "[" (string-join (map safe-display v) ", ") "]")]
    [(string? v)  (format "\"~a\"" v)]       ; show strings with quotes
    [(boolean? v) (if v "True" "False")]     ; Tesl capitalised booleans
    [(symbol? v)  (~a v)]                    ; strip Racket ' prefix from gensyms
    [else         (~a v)]))                  ; integers, floats → plain number

;; Render an ADT value readably.  Variant constructors carry their fields in a
;; hash keyed by field name; positional ctors use synthetic field-0/field-1/…
;; keys, which we render as a tuple-like argument list, while named fields render
;; as a record-like body.  A nullary variant renders as just its name.
(define (safe-display-adt v)
  (define variant (~a (adt-value-variant v)))
  (define fields  (adt-value-fields v))
  (define keys    (hash-keys fields))
  (cond
    [(null? keys) variant]                              ; nullary: Nothing, True, …
    ;; Tuple sugar: type Tuple2/Tuple3/… → (a, b, …).  Tuple fields are named
    ;; 'first 'second 'third (see runtime-type-satisfied? in types.rkt).
    [(regexp-match? #rx"^Tuple[0-9]+$" (~a (adt-value-type v)))
     (let ([vals (map (lambda (k) (safe-display (hash-ref fields k)))
                      (sort keys tuple-key<?))])
       (string-append "(" (string-join vals ", ") ")"))]
    ;; Positional fields (field-0, field-1, …): Variant(v0, v1)
    [(andmap positional-key? keys)
     (let ([vals (map (lambda (k) (safe-display (hash-ref fields k)))
                      (sort keys positional<?))])
       (string-append variant "(" (string-join vals ", ") ")"))]
    ;; Named fields: Variant {name: val, …}
    [else
     (string-append variant " {"
       (string-join
         (hash-map fields (lambda (k vv) (format "~a: ~a" k (safe-display vv))) #t)
         ", ")
       "}")]))

(define (positional-key? k)
  (regexp-match? #rx"^(field-|_)?[0-9]+$" (~a k)))

;; Stable ordering for positional/tuple field keys by their trailing integer.
(define (positional<? a b)
  (define (idx k)
    (let ([m (regexp-match #rx"([0-9]+)$" (~a k))])
      (if m (string->number (cadr m)) 0)))
  (< (idx a) (idx b)))

;; Ordering for tuple fields named 'first 'second 'third 'fourth … (falls back
;; to symbol<? for any unrecognised key so the result is at least deterministic).
(define tuple-order
  '(first second third fourth fifth sixth seventh eighth ninth tenth))
(define (tuple-key<? a b)
  (define (idx k)
    (let ([p (index-of tuple-order k)])
      (or p 999)))
  (cond [(not (= (idx a) (idx b))) (< (idx a) (idx b))]
        [else (string<? (~a a) (~a b))]))

;; Kept for backward compatibility (used by thsl-src! diagnostic prints).
(define (thsl-display-value v) (safe-display v))
