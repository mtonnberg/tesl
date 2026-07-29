#lang racket

;; attach-client.rkt — command-line client for the live attach control channel
;; (dsl/debug/control-channel.rkt).  Backs the `tesl debug-attach` verb:
;;
;;   tesl debug-attach [--project DIR | --socket PATH | --port N]
;;                     [--break-at FILE:LINE]... [--when EXPR] [--hit SPEC]
;;                     [--once | --snapshot | --ping | --detach]
;;                     [--timeout-ms N]
;;
;; MODES
;;   default    NDJSON bridge: optional initial arming, then stdin lines are
;;              forwarded to the channel and every reply/event is printed to
;;              stdout — one JSON object per line.  For agents and scripts.
;;   --once     Arm the requested breakpoints, wait for the FIRST stopped
;;              event, print it, resume the server (continue) and detach.
;;              The agent curl loop with zero relaunches:
;;                tesl debug-attach --break-at app.tesl:42 --once &
;;                curl localhost:8080/api/thing
;;   --snapshot Connect, print one snapshot (paused state, locals, domain,
;;              SQL), detach.
;;   --ping     Connect, print the ping reply, detach.  Liveness probe.
;;   --detach   Connect and immediately detach — clears every armed
;;              breakpoint and resumes a parked thread (recovery hatch).
;;
;; The endpoint is resolved from --socket / --port, else from
;; <project>/.tesl-stuff/debug.sock then debug.port, where <project> is
;; --project or the nearest ancestor of CWD with tesl.toml.
;;
;; EXIT CODES: 0 ok · 1 protocol/usage error · 2 no debug endpoint found
;;             3 timed out waiting (--once with --timeout-ms)

(require json
         racket/tcp
         (only-in racket/unix-socket unix-socket-connect))

(define (fail! code msg)
  (eprintf "tesl debug-attach: ~a\n" msg)
  (exit code))

;; ── Endpoint resolution ───────────────────────────────────────────────────────

(define (project-root-of dir)
  (let loop ([d (path->complete-path dir)])
    (cond
      [(file-exists? (build-path d "tesl.toml")) d]
      [else
       (define parent (simplify-path (build-path d 'up) #f))
       (if (equal? parent d) #f (loop parent))])))

(define (resolve-endpoint project socket port)
  (cond
    [socket (cons 'unix socket)]
    [port   (cons 'tcp port)]
    [else
     (define root (or (and project (string->path project))
                      (project-root-of (current-directory))
                      (current-directory)))
     (define dir (build-path root ".tesl-stuff"))
     (define sock (build-path dir "debug.sock"))
     (define pfile (build-path dir "debug.port"))
     (cond
       [(file-exists? sock) (cons 'unix (path->string sock))]
       [(file-exists? pfile)
        (define p (string->number (string-trim (file->string pfile))))
        (if p (cons 'tcp p)
            (fail! 2 (format "unreadable port file: ~a" pfile)))]
       [else
        (fail! 2 (format "no debug endpoint under ~a — is the app running with `tesl run --debug`?" dir))])]))

(define (connect endpoint)
  (with-handlers ([exn:fail? (lambda (e)
                               (fail! 2 (format "cannot connect (~a) — is the app still running?"
                                                (exn-message e))))])
    (case (car endpoint)
      [(unix) (unix-socket-connect (cdr endpoint))]
      [(tcp)  (tcp-connect "127.0.0.1" (cdr endpoint))])))

;; ── Protocol helpers ──────────────────────────────────────────────────────────

(define (send! out obj)
  (write-string (jsexpr->string obj) out)
  (write-string "\n" out)
  (flush-output out))

(define (recv! in)
  (define line (read-line in 'any))
  (if (eof-object? line) eof
      (with-handlers ([exn:fail? (lambda (_e) (hasheq 'ok #f 'reason "unparseable line"))])
        (string->jsexpr line))))

(define (print-json obj)
  (write-string (jsexpr->string obj))
  (newline)
  (flush-output))

;; Wait for a message matching pred, printing NOTHING else (quiet) or
;; everything seen (verbose bridge handles its own printing).
(define (recv-until in pred #:deadline [deadline #f])
  (let loop ()
    (when (and deadline (> (current-inexact-milliseconds) deadline))
      (fail! 3 "timed out waiting for a stop"))
    (define m
      (if deadline
          (sync/timeout (max 0.05 (/ (- deadline (current-inexact-milliseconds)) 1000.0))
                        (handle-evt in (lambda (p) (recv! p))))
          (recv! in)))
    (cond
      [(not m) (loop)]                       ; sync timeout tick → re-check deadline
      [(eof-object? m) (fail! 1 "server closed the connection")]
      [(pred m) m]
      [else (loop)])))

;; ── Breakpoint spec parsing (FILE:LINE) ───────────────────────────────────────

(define (parse-break-at spec when-cond hit-cond)
  (define m (regexp-match #rx"^(.*):([0-9]+)$" spec))
  (unless m (fail! 1 (format "bad --break-at spec (want FILE:LINE): ~a" spec)))
  (define file (cadr m))
  (define line (string->number (caddr m)))
  (define bp (hasheq 'line line))
  (define bp+c (if when-cond (hash-set bp 'condition when-cond) bp))
  (define bp+h (if hit-cond (hash-set bp+c 'hit hit-cond) bp+c))
  (cons file bp+h))

(define (arm! in out specs)
  ;; Group by file: one set-breakpoints per file (a second send for the same
  ;; file REPLACES, so they must be batched).
  (define by-file (make-hash))
  (for ([s (in-list specs)])
    (hash-update! by-file (car s) (lambda (l) (cons (cdr s) l)) '()))
  (for ([(file bps) (in-hash by-file)])
    (send! out (hasheq 'cmd "set-breakpoints" 'file file 'breakpoints (reverse bps)))
    (define reply (recv-until in (lambda (m) (equal? (hash-ref m 'cmd #f) "set-breakpoints"))))
    (unless (hash-ref reply 'ok #f)
      (fail! 1 (format "arming failed: ~a" (hash-ref reply 'reason ""))))
    (print-json reply)))

;; ── Main ──────────────────────────────────────────────────────────────────────

(module+ main
  (define project #f) (define socket #f) (define port #f)
  (define break-specs '()) (define when-cond #f) (define hit-cond #f)
  (define mode 'bridge) (define timeout-ms #f)

  (command-line
   #:program "tesl debug-attach"
   #:once-each
   [("--project") DIR "Project root (default: nearest tesl.toml above CWD)"
    (set! project DIR)]
   [("--socket") PATH "Explicit unix socket path" (set! socket PATH)]
   [("--port") N "Explicit loopback TCP port"
    (set! port (or (string->number N) (fail! 1 "bad --port")))]
   [("--when") EXPR "Condition applied to every --break-at" (set! when-cond EXPR)]
   [("--hit") SPEC "Hit-condition applied to every --break-at (e.g. \">=3\", \"%2\")"
    (set! hit-cond SPEC)]
   [("--timeout-ms") N "--once: give up waiting for a stop after N ms"
    (set! timeout-ms (or (string->number N) (fail! 1 "bad --timeout-ms")))]
   [("--once") "Arm, print the first stop, resume, detach" (set! mode 'once)]
   [("--snapshot") "Print one snapshot and detach" (set! mode 'snapshot)]
   [("--ping") "Print the ping reply and detach" (set! mode 'ping)]
   [("--detach") "Disarm everything and resume (recovery)" (set! mode 'detach)]
   #:multi
   [("--break-at") SPEC "Breakpoint as FILE:LINE (repeatable)"
    (set! break-specs (cons SPEC break-specs))])

  (define specs
    (for/list ([s (in-list (reverse break-specs))])
      (parse-break-at s when-cond hit-cond)))

  (define-values (in out) (connect (resolve-endpoint project socket port)))
  ;; Consume the attached banner (or busy error).
  (define hello (recv! in))
  (when (eof-object? hello) (fail! 1 "server closed the connection immediately"))
  (when (equal? (hash-ref hello 'event #f) "error")
    (fail! 1 (format "server refused: ~a" (hash-ref hello 'reason ""))))
  (print-json hello)

  (define (finish-detach!)
    (send! out (hasheq 'cmd "detach"))
    (recv-until in (lambda (m) (equal? (hash-ref m 'cmd #f) "detach")))
    (exit 0))

  (case mode
    [(ping)
     (send! out (hasheq 'cmd "ping"))
     (print-json (recv-until in (lambda (m) (equal? (hash-ref m 'cmd #f) "ping"))))
     (finish-detach!)]
    [(snapshot)
     (send! out (hasheq 'cmd "snapshot"))
     (print-json (recv-until in (lambda (m) (equal? (hash-ref m 'cmd #f) "snapshot"))))
     (finish-detach!)]
    [(detach) (finish-detach!)]
    [(once)
     (when (null? specs) (fail! 1 "--once requires at least one --break-at"))
     (arm! in out specs)
     (define deadline (and timeout-ms (+ (current-inexact-milliseconds) timeout-ms)))
     (define stopped
       (recv-until in (lambda (m) (equal? (hash-ref m 'event #f) "stopped"))
                   #:deadline deadline))
     (print-json stopped)
     (send! out (hasheq 'cmd "continue"))
     (recv-until in (lambda (m) (equal? (hash-ref m 'cmd #f) "continue")))
     (finish-detach!)]
    [(bridge)
     (unless (null? specs) (arm! in out specs))
     ;; stdin → socket, socket → stdout, until either side closes.
     (define reader
       (thread (lambda ()
                 (let loop ()
                   (define m (recv! in))
                   (unless (eof-object? m)
                     (print-json m)
                     (loop))))))
     (let loop ()
       (define line (read-line (current-input-port) 'any))
       (cond
         [(eof-object? line)
          (send! out (hasheq 'cmd "detach"))
          (sleep 0.1)]
         [else
          (with-handlers ([exn:fail? (lambda (_e) (void))])
            (write-string line out) (write-string "\n" out) (flush-output out))
          (loop)]))
     (exit 0)]))
