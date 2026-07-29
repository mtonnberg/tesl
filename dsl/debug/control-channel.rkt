#lang racket

;; control-channel.rkt — live attach surface for a running Tesl debug process.
;;
;; A dev server started with `tesl run --debug` exports TESL_DEBUG=1 (so the
;; thsl-src! checkpoints survive expansion — see checkpoint.rkt's B5 note) and
;; TESL_DEBUG_CONTROL_DIR=<project>/.tesl-stuff.  checkpoint.rkt's bootstrap
;; then starts THIS module inside the app process.  It listens on a
;; loopback-only endpoint and lets a client (the DAP adapter's attach mode,
;; `tesl debug-attach`, or the MCP tool) arm/re-arm breakpoints, receive stop
;; events, inspect the paused frame, and resume — all WITHOUT relaunching the
;; server.  Detach leaves the process serving.
;;
;; ENDPOINT
;;   Preferred: a unix domain socket at  $TESL_DEBUG_CONTROL_DIR/debug.sock
;;   Fallback : loopback TCP on an ephemeral port, written (as decimal text)
;;              to $TESL_DEBUG_CONTROL_DIR/debug.port
;;   Clients resolve in that order.  Both are unreachable off-host by
;;   construction (unix socket file permissions / 127.0.0.1 bind); this is a
;;   dev-loop feature, not a production surface — see the roadmap item's
;;   Non-goals.
;;
;; WIRE PROTOCOL — newline-delimited JSON, one object per line, both ways.
;;   → {"cmd":"ping"}
;;   → {"cmd":"set-breakpoints","file":F,"breakpoints":[{"line":N,"condition"?,"hit"?}...]}
;;   → {"cmd":"clear-breakpoints"}            (all armed by this channel)
;;   → {"cmd":"clear-breakpoints","file":F}   (one file)
;;   → {"cmd":"list-breakpoints"}
;;   → {"cmd":"continue" | "step-in" | "step-over" | "step-out"}
;;   → {"cmd":"snapshot"}
;;   → {"cmd":"detach"}
;;   ← command replies: {"ok":true/false, "cmd":<echo>, ...}
;;   ← async events   : {"event":"stopped", file, line, reason, locals, domain, sql}
;;                      {"event":"resumed", "via":"client"|"auto"}
;;                      {"event":"detached"}
;;   Replies and events are interleaved on the same stream; clients discriminate
;;   on the presence of the "event" key.
;;
;; ONE CLIENT AT A TIME.  A second concurrent connection is answered with
;; {"event":"error","reason":"busy"} and closed.  Sequential re-attach after a
;; detach (or an abrupt disconnect, which is treated AS a detach: disarm all,
;; resume, keep serving) is fully supported.
;;
;; SAFETY WITH NO CLIENT.  The event pump below is the process's ONLY consumer
;; of checkpoint.rkt's event-ch in attach mode.  If a stop fires while no
;; client is connected (client died between arming and the hit), the pump
;; auto-resumes immediately so the server can never be wedged by an absent
;; listener.  TESL_DEBUG_PAUSE_TIMEOUT_MS (checkpoint.rkt) additionally bounds
;; a pause whose CONNECTED client stopped reading.
;;
;; DO NOT load this module in the same process as the DAP adapter's launch
;; mode or headless-inspect — event-ch has one-consumer semantics and each of
;; the three runs its own pump.  The env-var gate makes that structural:
;; only `tesl run --debug` sets TESL_DEBUG_CONTROL_DIR.

(require json
         racket/tcp
         (only-in racket/unix-socket
                  unix-socket-available?
                  unix-socket-listen
                  unix-socket-accept
                  unix-socket-close-listener)
         "checkpoint.rkt"
         (only-in "headless-inspect.rkt"
                  locals->json domain->json sql->json)
         (only-in "../private/domain-registry.rkt"
                  sql-capture-for-thread
                  most-recent-sql-capture))

(provide start-control-channel!
         stop-control-channel!
         control-endpoint
         ;; exposed for unit tests (protocol logic without a socket)
         dispatch-command)

;; ── State ─────────────────────────────────────────────────────────────────────

(define started? (box #f))
(define listener-custodian (box #f))
;; (cons 'unix path) | (cons 'tcp port) | #f — what start-control-channel! bound.
(define endpoint (box #f))
(define (control-endpoint) (unbox endpoint))

;; The single connected client's output port (or #f), plus a write lock so the
;; event pump and the command reader never interleave partial lines.
(define client-out (box #f))
(define write-sem (make-semaphore 1))

;; #t exactly while a checkpoint thread is parked (set by the pump on a stopped
;; event, cleared by resume). Guards paused-ch puts exactly like the DAP
;; adapter's `paused?` — the channel is unbuffered, so an unguarded put with no
;; parked thread would block forever.
(define paused? (box #f))
(define last-stopped (box #f))

;; Every breakpoint FILE KEY this channel armed (all spellings), so detach can
;; disarm precisely what attach armed and nothing else.
(define armed-key-strings (box (set)))

;; ── Helpers ───────────────────────────────────────────────────────────────────

(define (send-json! out obj)
  (with-handlers ([exn:fail? (lambda (_e) (void))])
    (call-with-semaphore write-sem
      (lambda ()
        (write-string (jsexpr->string obj) out)
        (write-string "\n" out)
        (flush-output out)))))

(define (send-to-client! obj)
  (let ([out (unbox client-out)])
    (when out (send-json! out obj))))

;; All the spellings a breakpoint file might be keyed under.  The emitter bakes
;; the compiler's INPUT path into thsl-src! verbatim, and the client may know
;; the file by a different but equivalent spelling — arm them all so a match
;; never fails on path spelling.  (`tesl run --debug` canonicalises the entry
;; to an absolute path before compiling, so the absolute spelling is the one
;; that fires in practice.)
(define (file-key-spellings f)
  (define keys (list f))
  (define keys+abs
    (with-handlers ([exn:fail? (lambda (_e) keys)])
      (cons (path->string (path->complete-path (string->path f))) keys)))
  (define keys+real
    (with-handlers ([(lambda (_) #t) (lambda (_e) keys+abs)])
      (cons (path->string (resolve-path (path->complete-path (string->path f))))
            keys+abs)))
  (remove-duplicates keys+real))

(define (resume-with! cmd via)
  (cond
    [(unbox paused?)
     (set-box! paused? #f)
     ;; Detached put, mirroring dap-server's resume!: never block the caller.
     (thread (lambda () (channel-put paused-ch cmd)))
     (send-to-client! (hasheq 'event "resumed" 'via via))
     #t]
    [else #f]))

(define (disarm-all!)
  (for ([k (in-set (unbox armed-key-strings))])
    (hash-remove! breakpoints k))
  (set-box! armed-key-strings (set)))

;; Detach semantics shared by the explicit command and an abrupt disconnect:
;; disarm everything this channel armed, resume a parked thread, drop the
;; debug-active override.  The server keeps serving; the listener keeps
;; accepting, so a later re-attach works.
(define (detach! #:notify? [notify? #t])
  (disarm-all!)
  (resume-with! 'continue "client")
  (when notify? (send-to-client! (hasheq 'event "detached")))
  (set-box! client-out #f)
  (set-debug-active! #f))

;; ── Snapshot rendering ────────────────────────────────────────────────────────

(define (paused-sql-capture)
  (with-handlers ([exn:fail? (lambda (_e) #f)])
    ;; Whether this capture is THIS line's statement or the previous one is
    ;; carried in the rendered JSON (sql->json's `this-line`), so the attach
    ;; surface labels it exactly like the launch surface does.
    (or (let ([t (current-paused-thread)]) (and t (sql-capture-for-thread t)))
        (most-recent-sql-capture))))

(define (stopped-event->json evt)
  (define locals (hash-ref evt 'locals '()))
  (hasheq 'event  "stopped"
          'file   (hash-ref evt 'file "")
          'line   (hash-ref evt 'line 0)
          'reason (hash-ref evt 'reason "breakpoint")
          'locals (locals->json locals)
          'domain (domain->json locals)
          'sql    (or (sql->json (paused-sql-capture)) 'null)))

(define (snapshot-json)
  (define evt (and (unbox paused?) (unbox last-stopped)))
  (define locals (if evt (hash-ref evt 'locals '()) '()))
  (hasheq 'ok     #t
          'cmd    "snapshot"
          'paused (and evt #t)
          'file   (if evt (hash-ref evt 'file "") 'null)
          'line   (if evt (hash-ref evt 'line 0) 'null)
          'locals (locals->json locals)
          'domain (domain->json locals)
          'sql    (if evt (or (sql->json (paused-sql-capture)) 'null) 'null)))

;; ── Command dispatch ──────────────────────────────────────────────────────────

(define (arm-breakpoints! file bps)
  (define recs
    (filter values
            (for/list ([o (in-list bps)] #:when (hash? o))
              (let ([line (hash-ref o 'line #f)]
                    [cnd  (let ([c (hash-ref o 'condition #f)])
                            (and (string? c) (non-empty-string? (string-trim c)) c))]
                    [hit  (let ([h (hash-ref o 'hit #f)])
                            (and (string? h) (non-empty-string? (string-trim h)) h))])
                (and (exact-positive-integer? line)
                     (make-bp-record line cnd hit))))))
  (define spellings (file-key-spellings file))
  (cond
    [(null? recs)
     (for ([k (in-list spellings)]) (hash-remove! breakpoints k))
     0]
    [else
     (for ([k (in-list spellings)])
       ;; Each spelling gets its OWN record list: hit counters must not be
       ;; shared between key spellings or a single execution pass would
       ;; double-count (only one spelling ever actually fires, but stay exact).
       (hash-set! breakpoints k
                  (map (lambda (r) (make-bp-record (bp-record-line r)
                                                   (bp-record-condition r)
                                                   (bp-record-hit-condition r)))
                       recs))
       (set-box! armed-key-strings (set-add (unbox armed-key-strings) k)))
     (length recs)]))

;; Pure-ish protocol dispatch: jsexpr command → jsexpr reply.  Socket-free so
;; the protocol is unit-testable; the reader loop below feeds it.
(define (dispatch-command msg)
  (define cmd (and (hash? msg) (hash-ref msg 'cmd #f)))
  (define (fail reason) (hasheq 'ok #f 'cmd (or cmd 'null) 'reason reason))
  (with-handlers ([exn:fail? (lambda (e) (fail (exn-message e)))])
    (case cmd
      [("ping")
       (hasheq 'ok #t 'cmd "ping" 'version 1 'paused (unbox paused?))]
      [("set-breakpoints")
       (define file (hash-ref msg 'file #f))
       (define bps  (hash-ref msg 'breakpoints '()))
       (cond
         [(not (string? file)) (fail "set-breakpoints requires a \"file\" string")]
         [(not (list? bps))    (fail "\"breakpoints\" must be an array")]
         [else
          (define n (arm-breakpoints! file bps))
          (hasheq 'ok #t 'cmd "set-breakpoints" 'file file 'armed n)])]
      [("clear-breakpoints")
       (define file (hash-ref msg 'file #f))
       (cond
         [(string? file)
          (for ([k (in-list (file-key-spellings file))]) (hash-remove! breakpoints k))
          (hasheq 'ok #t 'cmd "clear-breakpoints" 'file file)]
         [else
          (disarm-all!)
          (hasheq 'ok #t 'cmd "clear-breakpoints")])]
      [("list-breakpoints")
       (hasheq 'ok #t 'cmd "list-breakpoints"
               'breakpoints
               (for*/list ([(file entry) (in-hash breakpoints)]
                           [r (in-list (if (list? entry) entry '()))]
                           #:when (bp-record? r))
                 (let* ([b (hasheq 'file file 'line (bp-record-line r))]
                        [b (if (bp-record-condition r)
                               (hash-set b 'condition (bp-record-condition r)) b)]
                        [b (if (bp-record-hit-condition r)
                               (hash-set b 'hit (bp-record-hit-condition r)) b)])
                   b)))]
      [("continue" "step-in" "step-over" "step-out")
       (if (resume-with! (string->symbol cmd) "client")
           (hasheq 'ok #t 'cmd cmd)
           (fail "not paused"))]
      [("snapshot") (snapshot-json)]
      [("detach")
       (detach! #:notify? #f)
       (hasheq 'ok #t 'cmd "detach")]
      [else (fail (format "unknown cmd: ~a" cmd))])))

;; ── Event pump ────────────────────────────────────────────────────────────────
;; The one consumer of checkpoint.rkt's event-ch in an attach process.  Forwards
;; each stop to the connected client; with NO client connected the stop is
;; auto-resumed at once so an armed-but-abandoned breakpoint can never park a
;; request thread indefinitely.

(define (start-event-pump!)
  (thread
   (lambda ()
     (let loop ()
       (define evt (channel-get event-ch))
       (set-box! last-stopped evt)
       (set-box! paused? #t)
       (cond
         [(unbox client-out)
          (send-to-client! (stopped-event->json evt))]
         [else
          (resume-with! 'continue "auto")])
       (loop)))))

;; ── Listener / client loop ────────────────────────────────────────────────────

(define (client-loop in out)
  (cond
    [(unbox client-out)
     ;; Busy: exactly one client at a time.
     (send-json! out (hasheq 'event "error" 'reason "busy"))
     (with-handlers ([exn:fail? void]) (close-input-port in) (close-output-port out))]
    [else
     (set-box! client-out out)
     (set-debug-active! #t)
     (send-json! out (hasheq 'event "attached" 'version 1))
     ;; If the process is ALREADY paused (stop fired between clients), replay
     ;; the stop so the new client learns about the parked thread it now owns.
     (when (and (unbox paused?) (unbox last-stopped))
       (send-json! out (stopped-event->json (unbox last-stopped))))
     (let loop ()
       (define line (with-handlers ([exn:fail? (lambda (_e) eof)]) (read-line in 'any)))
       (cond
         [(eof-object? line)
          ;; Abrupt disconnect == detach: disarm, resume, keep serving.
          (detach! #:notify? #f)]
         [else
          (define msg
            (with-handlers ([exn:fail? (lambda (_e) #f)])
              (string->jsexpr line)))
          (define reply
            (if msg (dispatch-command msg)
                (hasheq 'ok #f 'reason "invalid json")))
          (send-json! out reply)
          ;; detach closes the session after its reply.
          (if (and (hash? msg) (equal? (hash-ref msg 'cmd #f) "detach"))
              (with-handlers ([exn:fail? void])
                (close-input-port in) (close-output-port out))
              (loop))]))]))

(define (accept-loop accept!)
  (let loop ()
    (define-values (in out)
      (with-handlers ([exn:fail? (lambda (_e) (values #f #f))])
        (accept!)))
    (when (and in out)
      ;; Serve each client on its own thread so a wedged client can never stop
      ;; the accept loop from answering (and rejecting) the next connection.
      (thread (lambda () (client-loop in out))))
    (when in (loop))))

;; Start the channel.  Idempotent; returns the endpoint (or #f on failure).
;; Never raises — an attach-surface failure must not take the app down.
(define (start-control-channel!)
  (cond
    [(unbox started?) (unbox endpoint)]
    [else
     (set-box! started? #t)
     (with-handlers ([(lambda (_) #t)
                      (lambda (e)
                        (eprintf "tesl-debug: control channel error: ~a\n"
                                 (if (exn? e) (exn-message e) e))
                        #f)])
       (define dir (getenv "TESL_DEBUG_CONTROL_DIR"))
       (unless (and dir (non-empty-string? dir))
         (error "TESL_DEBUG_CONTROL_DIR not set"))
       (make-directory* dir)
       (define cust (make-custodian))
       (set-box! listener-custodian cust)
       (parameterize ([current-custodian cust])
         (define sock-path (build-path dir "debug.sock"))
         (define port-path (build-path dir "debug.port"))
         ;; Fresh endpoint files: a stale socket from a dead process must not
         ;; block the bind; a stale port file must not misdirect a client.
         (with-handlers ([exn:fail? void]) (delete-file sock-path))
         (with-handlers ([exn:fail? void]) (delete-file port-path))
         (define-values (kind accept!)
           (with-handlers
               ([(lambda (_) #t)
                 ;; unix socket unavailable/failed → loopback TCP fallback.
                 (lambda (_e)
                   (define l (tcp-listen 0 4 #t "127.0.0.1"))
                   (define-values (_la port _ra _rp) (tcp-addresses l #t))
                   (call-with-output-file port-path #:exists 'replace
                     (lambda (o) (write-string (number->string port) o)))
                   (values (cons 'tcp port)
                           (lambda () (tcp-accept l))))])
             (unless unix-socket-available? (error "unix sockets unavailable"))
             (define l (unix-socket-listen sock-path 4))
             (values (cons 'unix (path->string sock-path))
                     (lambda () (unix-socket-accept l)))))
         (set-box! endpoint kind)
         (start-event-pump!)
         (thread (lambda () (accept-loop accept!)))
         ;; Best-effort endpoint-file cleanup when the process exits.
         (plumber-add-flush! (current-plumber)
                             (lambda (_h)
                               (with-handlers ([exn:fail? void]) (delete-file sock-path))
                               (with-handlers ([exn:fail? void]) (delete-file port-path))))
         kind))]))

;; Tear the channel down (tests): close listener + client, clear state.
(define (stop-control-channel!)
  (let ([cust (unbox listener-custodian)])
    (when cust (custodian-shutdown-all cust)))
  (disarm-all!)
  (set-box! client-out #f)
  (set-box! started? #f)
  (set-box! endpoint #f)
  (set-box! paused? #f)
  (set-debug-active! #f))
