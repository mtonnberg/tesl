#lang racket

;;; Server-Sent Events (SSE) support for Tesl.
;;;
;;; SSE replaces the WebSocket server: events flow server→client over standard
;;; HTTP, on the SAME port as the API server.  No nginx WebSocket proxy config
;;; or separate port is needed.  Clients use the browser's native EventSource API.
;;;
;;; Protocol:
;;;   Content-Type: text/event-stream
;;;   Each event:   data: <json>\n\n
;;;   Heartbeat:    : heartbeat\n\n   (keeps connection alive through proxies)
;;;
;;; This module provides make-sse-connection-handler, which returns a procedure
;;; (output-port? -> void?) suitable for response/output.

(require "queue.rkt"
         (only-in "../dsl/types.rkt" runtime-value->jsexpr)
         (only-in "../tesl/logging.rkt" tesl-log-active? tesl-log!)
         json
         racket/format)

(provide make-sse-connection-handler)

;; Returns a procedure (output-port? -> void?) that:
;;   1. Registers a listener on channel-spec for the given key.
;;   2. Streams SSE events until the client disconnects.
;;   3. Sends a : heartbeat comment every 10 s to keep the connection alive.
;;   4. Removes the listener on disconnect.
(define (make-sse-connection-handler channel-spec channel-key)
  (lambda (out)
    ;; Set up an async event queue for this connection.
    (define event-ch (make-channel))

    ;; Listener callback: non-blocking put into the event channel.
    ;; Uses sync/timeout so the delivery thread never blocks on a dead connection
    ;; (i.e. one whose SSE loop has already exited but cleanup hasn't run yet).
    (define (on-event evt)
      (sync/timeout 1 (channel-put-evt event-ch evt)))

    ;; Register listener.
    (define listeners (channel-spec-listeners channel-spec))
    (hash-set! listeners channel-key
               (cons on-event (hash-ref listeners channel-key '())))

    (when (tesl-log-active?)
      (tesl-log! "SSE" (format "connect ~a(~a)"
                                (channel-spec-name channel-spec) channel-key)))

    ;; Send an immediate comment so the browser fires onopen without waiting
    ;; for the first heartbeat timeout.  With HTTP chunked encoding (the default
    ;; when connection-close? is #f) the browser only fires onopen after
    ;; receiving the first body chunk; this ensures that happens instantly.
    (with-handlers ([exn? void])
      (write-bytes #": ok\n\n" out)
      (flush-output out))

    ;; SSE event loop.  Ends when a write fails (client disconnect).
    (let loop ()
      (define evt (sync/timeout 10 event-ch))
      (define ok?
        (with-handlers ([exn? (lambda (_) #f)])
          (cond
            ;; Timeout → send heartbeat comment (browsers need this to detect drops)
            [(not evt)
             (write-bytes #": heartbeat\n\n" out)
             (flush-output out)
             #t]
            ;; Real event → encode as SSE data line
            [else
             (define payload (runtime-value->jsexpr evt))
             (define json-str
               (jsexpr->string
                (hash 'channel (symbol->string (channel-spec-name channel-spec))
                      'payload payload)))
             (write-bytes (string->bytes/utf-8 (format "data: ~a\n\n" json-str)) out)
             (flush-output out)
             #t])))
      (when ok? (loop)))

    ;; Cleanup: remove our listener callback.
    (define current (hash-ref listeners channel-key '()))
    (hash-set! listeners channel-key (remove on-event current))

    (when (tesl-log-active?)
      (tesl-log! "SSE" (format "disconnect ~a(~a)"
                                (channel-spec-name channel-spec) channel-key)))))
