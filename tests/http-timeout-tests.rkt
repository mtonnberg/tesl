#lang racket

;;; Outbound-HTTP deadlines — tesl/http-client.rkt
;;; (roadmap/completed/outbound_http_timeout_and_test_double.md, item 1)
;;;
;;; Before this, `do-http-request` called `http-sendrecv` with no connect
;;; deadline and no read deadline, so a slow or hung upstream blocked the calling
;;; thread indefinitely: a request thread (holding a DB pool slot inside a
;;; `transaction`), or one of a queue's worker threads — which is worse, because
;;; the job never FAILS, so retry / backoff / dead-letter never run.
;;;
;;; These cases drive REAL loopback servers, because the deadline is precisely
;;; the thing a pure unit test cannot observe.  They differ from
;;; tests/httpclient-test.rkt (deliberately not gated in ci.sh) in that every
;;; server here ACCEPTS the connection: nothing depends on how the network
;;; filters a connect to a dead port.  If a listener cannot be bound at all the
;;; suite self-skips, matching ci.sh's optional-dependency convention.
;;;
;;; The deadlines are read fresh from the environment on every call, so each case
;;; sets its own short budget instead of waiting out the 30s default.

(require rackunit
         racket/tcp
         (only-in "../dsl/capability.rkt" with-capabilities)
         (only-in "../dsl/types.rkt" record-value-fields)
         (only-in "../tesl/tuple.rkt" Tuple2)
         (only-in "../tesl/http-client.rkt"
                  httpClient
                  HttpClient.get
                  http-post-stream
                  http-connect-timeout-ms
                  http-read-timeout-ms
                  http-stream-idle-timeout-ms))

;; ── Defaults are conservative but present ────────────────────────────────────

(test-case "every outbound phase has a default deadline"
  (parameterize ([current-environment-variables
                  (make-environment-variables)])
    (check-equal? (http-connect-timeout-ms) 10000)
    (check-equal? (http-read-timeout-ms) 30000)
    (check-equal? (http-stream-idle-timeout-ms) 60000)))

(test-case "each deadline is env-configurable like TESL_HTTP_MAX_RESPONSE_BYTES"
  (parameterize ([current-environment-variables
                  (make-environment-variables
                   #"TESL_HTTP_CONNECT_TIMEOUT_MS"     #"1234"
                   #"TESL_HTTP_TIMEOUT_MS"             #"2345"
                   #"TESL_HTTP_STREAM_IDLE_TIMEOUT_MS" #"3456")])
    (check-equal? (http-connect-timeout-ms) 1234)
    (check-equal? (http-read-timeout-ms) 2345)
    (check-equal? (http-stream-idle-timeout-ms) 3456))
  ;; A junk value falls back to the default rather than disabling the deadline.
  (parameterize ([current-environment-variables
                  (make-environment-variables #"TESL_HTTP_TIMEOUT_MS" #"nonsense")])
    (check-equal? (http-read-timeout-ms) 30000)))

;; ── Loopback harness ─────────────────────────────────────────────────────────

(define (can-listen?)
  (with-handlers ([exn:fail? (lambda (_e) #f)])
    (define l (tcp-listen 0 4 #t "127.0.0.1"))
    (tcp-close l)
    #t))

;; Run `proc` against a loopback server whose per-connection behaviour is
;; `handle`.  Everything is torn down before returning, so a stalled handler
;; thread cannot outlive its test.
(define (call-with-loopback-server handle proc)
  (define listener (tcp-listen 0 4 #t "127.0.0.1"))
  (define conns (box '()))
  (define accept-thread
    (thread
     (lambda ()
       (let loop ()
         (define-values (in out) (tcp-accept listener))
         (set-box! conns (cons (cons in out) (unbox conns)))
         (thread (lambda () (with-handlers ([(lambda (_) #t) void]) (handle in out))))
         (loop)))))
  (define-values (_h port _ph _pp) (tcp-addresses listener #t))
  (dynamic-wind
    void
    (lambda () (proc (format "http://127.0.0.1:~a/probe" port)))
    (lambda ()
      (kill-thread accept-thread)
      (for ([c (in-list (unbox conns))])
        (with-handlers ([(lambda (_) #t) void]) (close-input-port (car c)))
        (with-handlers ([(lambda (_) #t) void]) (close-output-port (cdr c))))
      (tcp-close listener))))

(define (drain-request-head! in)
  (let loop ()
    (define l (read-line in 'any))
    (unless (or (eof-object? l) (string=? l "")) (loop))))

;; Returns (cons elapsed-ms exn-or-#f) for a thunk expected to raise.
(define (timed-failure thunk)
  (define t0 (current-inexact-milliseconds))
  (define e
    (with-handlers ([exn:fail? values])
      (thunk)
      #f))
  (cons (- (current-inexact-milliseconds) t0) e))

(define deadline-ms 500)
;; Generous slack: the assertion that matters is "bounded", not "precise".
(define slack-ms 6000)

(define (check-deadline-honoured label outcome expect-rx)
  (define elapsed (car outcome))
  (define e (cdr outcome))
  (check-pred exn:fail:user? e
              (format "~a: expected a clean HttpClient error, got ~a" label
                      (if e (exn-message e) "no error at all")))
  (when (exn? e)
    (check-regexp-match expect-rx (exn-message e) )
    ;; The failure must be the DEADLINE, not a raw Racket exception leaking out.
    (check-regexp-match #rx"^HttpClient: " (exn-message e)))
  (check-true (< elapsed (+ deadline-ms slack-ms))
              (format "~a: took ~ams, deadline was ~ams" label (round elapsed) deadline-ms)))

(cond
  [(not (can-listen?))
   (displayln "Skipping outbound-HTTP deadline tests: cannot bind a loopback listener")]
  [else

   ;; ── A server that accepts and never responds ─────────────────────────────
   (test-case "a request to a server that never responds fails within the deadline"
     (parameterize ([current-environment-variables
                     (make-environment-variables
                      #"TESL_HTTP_TIMEOUT_MS" (string->bytes/utf-8 (number->string deadline-ms)))])
       (call-with-loopback-server
        (lambda (in out) (drain-request-head! in) (sleep 30))
        (lambda (url)
          (check-deadline-honoured
           "never-responds"
           (timed-failure (lambda () (with-capabilities (httpClient) (HttpClient.get url '()))))
           #rx"timed out after 500ms")))))

   ;; ── A server that sends headers then stalls mid-body ─────────────────────
   ;; The pre-fix code got past `http-sendrecv` here and then blocked forever in
   ;; the body read, so this case is NOT covered by the one above.
   (test-case "a server that stalls mid-body fails within the deadline"
     (parameterize ([current-environment-variables
                     (make-environment-variables
                      #"TESL_HTTP_TIMEOUT_MS" (string->bytes/utf-8 (number->string deadline-ms)))])
       (call-with-loopback-server
        (lambda (in out)
          (drain-request-head! in)
          (display "HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\npartial" out)
          (flush-output out)
          (sleep 30))
        (lambda (url)
          (check-deadline-honoured
           "stalls-mid-body"
           (timed-failure (lambda () (with-capabilities (httpClient) (HttpClient.get url '()))))
           #rx"timed out after 500ms")))))

   ;; ── A healthy server still works, with deadlines in force ────────────────
   (test-case "a responsive server is unaffected by the deadlines"
     (call-with-loopback-server
      (lambda (in out)
        (drain-request-head! in)
        (display "HTTP/1.1 201 Created\r\nContent-Length: 5\r\nX-Probe: yes\r\n\r\nhello" out)
        (flush-output out)
        (close-output-port out))
      (lambda (url)
        (with-capabilities (httpClient)
          (define fields (record-value-fields (HttpClient.get url '())))
          (check-equal? (hash-ref fields 'status) 201)
          (check-equal? (hash-ref fields 'body) "hello")
          (check-not-false (assoc "X-Probe" (hash-ref fields 'headers)))))))

   ;; ── A URL carrying a ?query reaches the network at all ───────────────────
   ;; `url-query` yields SYMBOL keys, and the query-string rebuild passed one
   ;; straight to `string-append` — so every outbound URL with a query string
   ;; raised a contract violation before this.
   (test-case "an outbound URL with a query string is not a contract violation"
     (call-with-loopback-server
      (lambda (in out)
        (define line (read-line in 'any))
        (drain-request-head! in)
        (display (format "HTTP/1.1 200 OK\r\nContent-Length: ~a\r\n\r\n~a"
                         (string-length line) line)
                 out)
        (flush-output out)
        (close-output-port out))
      (lambda (url)
        (with-capabilities (httpClient)
          (define fields (record-value-fields (HttpClient.get (string-append url "?since=1&q=x") '())))
          (check-equal? (hash-ref fields 'status) 200)
          (check-regexp-match #rx"since=1&q=x" (hash-ref fields 'body))))))

   ;; ── A Tesl `Tuple2` header actually reaches the wire ─────────────────────
   ;; A Tesl `List (Tuple2 String String)` arrives as a list of Tuple2 ADT
   ;; VALUES, not 2-element lists; the header split assumed the latter, so every
   ;; request with a custom header — the documented way to authenticate one —
   ;; raised a raw `regexp-match?: contract violation` before sending anything.
   (test-case "a Tuple2 header is sent, not a contract violation"
     (call-with-loopback-server
      (lambda (in out)
        (define head (open-output-string))
        (let loop ()
          (define l (read-line in 'any))
          (unless (or (eof-object? l) (string=? l ""))
            (displayln l head)
            (loop)))
        (define body (get-output-string head))
        (display (format "HTTP/1.1 200 OK\r\nContent-Length: ~a\r\n\r\n~a"
                         (string-length body) body)
                 out)
        (flush-output out)
        (close-output-port out))
      (lambda (url)
        (with-capabilities (httpClient)
          (define fields
            (record-value-fields
             (HttpClient.get url (list (Tuple2 "Authorization" "Bearer tok-1")
                                       ;; the 2-element-list shape still works
                                       (list "Accept" "application/json")))))
          (check-equal? (hash-ref fields 'status) 200)
          (check-regexp-match #rx"Authorization: Bearer tok-1" (hash-ref fields 'body))
          (check-regexp-match #rx"Accept: application/json" (hash-ref fields 'body))))))

   ;; ── The streaming variant gets an IDLE budget, not a total one ───────────
   (test-case "a streaming response survives a long-lived stream but fails when it goes idle"
     (parameterize ([current-environment-variables
                     (make-environment-variables
                      #"TESL_HTTP_STREAM_IDLE_TIMEOUT_MS"
                      (string->bytes/utf-8 (number->string deadline-ms)))])
       (call-with-loopback-server
        (lambda (in out)
          (drain-request-head! in)
          (display "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" out)
          (flush-output out)
          ;; Six events spread over well MORE than one idle budget: a total
          ;; deadline would kill this, an idle deadline must not.
          (for ([i (in-range 6)])
            (sleep (/ deadline-ms 2.0 1000.0))
            (display (format "data: event-~a\n\n" i) out)
            (flush-output out))
          (sleep 30))
        (lambda (url)
          (with-capabilities (httpClient)
            (define-values (status port) (http-post-stream url '() "{}"))
            (check-equal? status 200)
            ;; The stream outlives several idle budgets while it keeps producing.
            (for ([i (in-range 6)])
              (define l (read-line port 'any))
              (check-equal? l (format "data: event-~a" i))
              (check-equal? (read-line port 'any) ""))
            ;; …and then the upstream goes quiet.
            (check-deadline-honoured
             "stream-idle"
             (timed-failure
              (lambda ()
                (let loop ()
                  (define l (read-line port 'any))
                  (unless (eof-object? l) (loop)))))
             #rx"was idle for 500ms"))))))

   ;; ── The connect phase has its own, separate deadline ─────────────────────
   ;; A full-listen-backlog server accepts the TCP handshake at the kernel level
   ;; but never calls accept, so this exercises the connect phase specifically on
   ;; platforms where that stalls; where the kernel completes the handshake
   ;; anyway the READ deadline catches it.  Either way the call must return.
   (test-case "a connect that never completes is bounded too"
     (parameterize ([current-environment-variables
                     (make-environment-variables
                      #"TESL_HTTP_CONNECT_TIMEOUT_MS"
                      (string->bytes/utf-8 (number->string deadline-ms))
                      #"TESL_HTTP_TIMEOUT_MS"
                      (string->bytes/utf-8 (number->string deadline-ms)))])
       (define listener (tcp-listen 0 1 #t "127.0.0.1"))
       (define-values (_h port _ph _pp) (tcp-addresses listener #t))
       (dynamic-wind
         void
         (lambda ()
           (define outcome
             (timed-failure
              (lambda ()
                (with-capabilities (httpClient)
                  ;; Never accepted, so nothing is ever read back.
                  (HttpClient.get (format "http://127.0.0.1:~a/probe" port) '())))))
           (check-deadline-honoured "never-accepted" outcome #rx"timed out after 500ms"))
         (lambda () (tcp-close listener)))))])
