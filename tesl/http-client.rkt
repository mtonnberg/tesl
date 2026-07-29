#lang racket

;;; Tesl.HttpClient — outgoing HTTP request capability and functions.
;;;
;;; The `http-client` capability gates all outbound HTTP calls.
;;; Import it and list it in a capability's `implies` clause to opt in:
;;;
;;;   import Tesl.HttpClient exposing [http-client, HttpResponse,
;;;                                    HttpClient.get, HttpClient.post,
;;;                                    HttpClient.put, HttpClient.delete]
;;;   capability myService implies http-client

(require net/http-client
         net/url
         racket/port
         (only-in "../dsl/capability.rkt" define-capability require-capabilities!)
         (only-in "../dsl/types.rkt" define-record adt-value? adt-value-type adt-value-fields)
         (only-in "../dsl/private/evidence.rkt" raw-value)
         (only-in "private/http-stub.rkt" current-outbound-http-hook))

(provide httpClient
         HttpResponse
         HttpResponse?
         HttpClient.get
         HttpClient.post
         HttpClient.put
         HttpClient.delete
         ;; #23: streaming POST (SSE) for provider token streaming.
         http-post-stream
         ;; Security: outbound header CRLF guard (exported for the regression suite)
         http-header-field-safe?
         ;; Timeout knobs (exported for the regression suite — see the block below)
         http-connect-timeout-ms
         http-read-timeout-ms
         http-stream-idle-timeout-ms)

;;; A header name/value is safe iff it contains no CR or LF — either would split
;;; the outbound request and inject arbitrary headers / smuggle a request.  Pure
;;; predicate, exported for the security regression suite.
(define (http-header-field-safe? s)
  (not (regexp-match? #rx"[\r\n]" s)))

;;; The httpClient capability — required by all outgoing HTTP functions.
;;; Named httpClient (camelCase) so it is a valid Tesl identifier.
(define-capability httpClient)

;;; HttpResponse record: { status: Int, body: String, headers: List (Tuple2 String String) }
;;; At runtime, headers is a list of 2-element lists (Tesl Tuple2 representation).
(define-record HttpResponse
  [status  : Integer]
  [body    : String]
  [headers : List])

;;; --- Internal helpers ---

;;; Parse a URL string and return (values host port path-str use-ssl?).
;;; Raises a user-friendly error if the URL is invalid.
(define (parse-url-parts url-str)
  (define u
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (raise-user-error 'HttpClient
                                         "invalid URL ~s: ~a"
                                         url-str
                                         (exn-message e)))])
      (string->url url-str)))
  (define scheme (url-scheme u))
  (define use-ssl? (equal? scheme "https"))
  (define host (url-host u))
  (unless (and host (non-empty-string? host))
    (raise-user-error 'HttpClient
                      "invalid URL ~s: could not parse host"
                      url-str))
  (define port (or (url-port u)
                   (if use-ssl? 443 80)))
  ;; Reconstruct path+query string for http-sendrecv
  (define path-str
    (let* ([path-parts (url-path u)]
           [path-string (if (null? path-parts)
                            "/"
                            (string-append "/"
                              (string-join
                                (map path/param-path path-parts)
                                "/")))]
           [query (url-query u)]
           ;; `url-query` yields (symbol . value-or-#f) pairs, so the key needs
           ;; symbol->string: `string-append` on the raw symbol raised a contract
           ;; violation, i.e. EVERY outbound URL carrying a `?query` crashed
           ;; before it reached the network (found by tests/http-stub-tests.tesl).
           [query-str (if (null? query)
                          ""
                          (string-append "?"
                            (string-join
                              (map (lambda (p)
                                     (define k (if (symbol? (car p))
                                                   (symbol->string (car p))
                                                   (car p)))
                                     (if (cdr p)
                                         (string-append k "=" (cdr p))
                                         k))
                                   query)
                              "&")))])
      (string-append path-string query-str)))
  (values host port path-str use-ssl?))

;;; Split one outbound header into (values name value).
;;;
;;; A Tesl `List (Tuple2 String String)` reaches here as a list of `Tuple2`
;;; ADT VALUES (tesl/tuple.rkt), not 2-element lists — so the old
;;; `(if (list? h) (first h) h)` handed the whole struct to the CR/LF guard and
;;; every request with a custom header (the documented way to authenticate one,
;;; lesson58) died on a raw `regexp-match?: contract violation` instead of
;;; sending.  Both shapes are accepted here, mirroring `Tuple2.first`, and
;;; anything else is a clean HttpClient error rather than a Racket one.
(define (http-header-pair who h)
  (define v (raw-value h))
  (cond
    [(and (adt-value? v) (equal? (adt-value-type v) 'Tuple2))
     (define fs (adt-value-fields v))
     (values (raw-value (hash-ref fs 'first  "")) (raw-value (hash-ref fs 'second "")))]
    [(and (list? v) (= (length v) 2)) (values (raw-value (first v)) (raw-value (second v)))]
    [(and (pair? v) (not (list? v)))  (values (raw-value (car v)) (raw-value (cdr v)))]
    [(string? v) (values v "")]
    [else
     (raise-user-error who
                       "expected a header as Tuple2 String String, got ~a" v)]))

;;; Convert raw response headers from http-sendrecv into a list of Tuple2 String String.
;;; Each element is a 2-element list matching Tesl's Tuple2 runtime representation.
(define (parse-response-headers raw-headers)
  (for/list ([hdr (in-list raw-headers)])
    (define hdr-str (if (bytes? hdr) (bytes->string/utf-8 hdr) hdr))
    (define colon-idx
      (let loop ([i 0])
        (cond
          [(>= i (string-length hdr-str)) -1]
          [(char=? (string-ref hdr-str i) #\:) i]
          [else (loop (+ i 1))])))
    (if (>= colon-idx 0)
        (list (string-trim (substring hdr-str 0 colon-idx))
              (string-trim (substring hdr-str (+ colon-idx 1))))
        (list hdr-str ""))))

;;; --- Deadlines (item 1 of roadmap/completed/outbound_http_timeout_and_test_double.md) ---
;;;
;;; `http-sendrecv` has NO connect deadline and NO read deadline, so a slow or
;;; hung upstream pinned the calling thread forever: a request thread (holding a
;;; DB pool slot inside a `transaction`), or one of a queue's worker threads —
;;; which is worse, because the job never FAILS, so retry/backoff/dead-letter
;;; never get a chance to run.
;;;
;;; CONFIGURATION SURFACE — env vars, exactly like the existing
;;; TESL_HTTP_MAX_RESPONSE_BYTES cap next to it:
;;;
;;;   TESL_HTTP_CONNECT_TIMEOUT_MS        default 10000   TCP+TLS connect
;;;   TESL_HTTP_TIMEOUT_MS                default 30000   send + status + headers
;;;                                                       + the whole body
;;;   TESL_HTTP_STREAM_IDLE_TIMEOUT_MS    default 60000   SSE: max GAP between
;;;                                                       bytes, never a total
;;;
;;; Why env vars and not a per-call argument or a per-declaration clause: a
;;; per-call timeout would change all four public signatures (and their types,
;;; docs, and every call site) to express an operational concern; there is no
;;; `httpClient` config BLOCK to hang a per-declaration timeout on, so that
;;; option would need new grammar.  A deadline is deployment tuning of the same
;;; kind as the response-body cap, and the env var is the established idiom for
;;; it here.  It also keeps every emitted `.rkt` byte-identical.
;;;
;;; Read fresh on each call (not at module load) so a test — or an operator
;;; using `env`-style configuration — can set them without a restart.
(define (http-env-positive-int name default)
  (let ([v (getenv name)])
    (or (and v (let ([n (string->number v)]) (and (exact-positive-integer? n) n)))
        default)))

(define (http-connect-timeout-ms)
  (http-env-positive-int "TESL_HTTP_CONNECT_TIMEOUT_MS" 10000))

(define (http-read-timeout-ms)
  (http-env-positive-int "TESL_HTTP_TIMEOUT_MS" 30000))

(define (http-stream-idle-timeout-ms)
  (http-env-positive-int "TESL_HTTP_STREAM_IDLE_TIMEOUT_MS" 60000))

;;; Run `thunk` under a wall-clock deadline.
;;;
;;; Racket's TCP/TLS connect and its port reads have no timeout argument, so the
;;; deadline is imposed from the outside: the thunk runs in a child thread whose
;;; `current-custodian` is `cust`, so every socket it opens is OWNED by `cust`.
;;; On timeout we kill the thread AND shut the custodian down — without the
;;; custodian the killed thread would leak the half-open socket, which is how a
;;; "timeout" turns into a slower resource leak.  The caller shuts `cust` down on
;;; the success path too (see below), so a connection is never orphaned.
;;;
;;; A failure inside the thunk is re-raised in the CALLER's thread unchanged, so
;;; the existing `with-handlers` wrapping still shapes it.
(define (call-with-http-deadline cust timeout-ms what thunk)
  (define result  (box '()))
  (define failure (box #f))
  (define worker
    (parameterize ([current-custodian cust])
      (thread
       (lambda ()
         (with-handlers ([exn:fail? (lambda (e) (set-box! failure e))])
           (set-box! result (call-with-values thunk list)))))))
  (cond
    [(sync/timeout (/ timeout-ms 1000.0) worker)
     (let ([e (unbox failure)])
       (when e (raise e)))
     ;; The thread finished without an exn:fail AND without a result — it was
     ;; killed, or something non-exn:fail escaped.  Fail loudly rather than
     ;; returning zero values into the caller's define-values.
     (when (null? (unbox result))
       (raise-user-error 'HttpClient "~a was interrupted" what))
     (apply values (unbox result))]
    [else
     (kill-thread worker)
     (custodian-shutdown-all cust)
     (raise-user-error 'HttpClient "~a timed out after ~ams" what timeout-ms)]))

;;; Wrap a response body port so that a GAP of more than `idle-ms` between bytes
;;; fails the read.  An SSE stream is legitimately long-lived, so a TOTAL
;;; deadline is the wrong shape for it: what is broken is an upstream that has
;;; stopped producing, not one that is producing slowly for a long time.
;;;
;;; `make-input-port/read-to-peek` derives correct peeking (which `read-line …
;;; 'any` needs) from the single `read-in` below, so we only have to get the
;;; blocking read right.  Syncing on the raw port is unambiguous here: we need
;;; one byte, so "ready as an event" is exactly "a read will not block".
(define (idle-timeout-input-port raw-port idle-ms url-str release!)
  (define idle-secs (/ idle-ms 1000.0))
  (define (read-in bstr)
    (let loop ()
      (cond
        [(sync/timeout idle-secs raw-port)
         (define n (read-bytes-avail!* bstr raw-port))
         (if (eqv? n 0) (loop) n)]
        [else
         (release!)
         (raise-user-error 'HttpClient
                           "stream from ~a was idle for ~ams" url-str idle-ms)])))
  (make-input-port/read-to-peek
   (object-name raw-port)
   read-in
   #f
   (lambda () (release!))))

;;; --- Outbound test double (item 2) ---
;;;
;;; One `if` against the neutral seam in tesl/private/http-stub.rkt.  In a
;;; production build the hook is always #f — see that module's header for why the
;;; double itself cannot exist there.  The capability gate and the CR/LF header
;;; guard run BEFORE this, so a stubbed call is still a proven, well-formed call.
(define (http-stub-answer mode method url-str req-headers body-str)
  (define hook (current-outbound-http-hook))
  (and (procedure? hook)
       (hook mode method url-str req-headers body-str)))

(define (http-stub-status answer)
  (let ([s (hash-ref answer 'status 200)])
    (if (exact-integer? s) s 200)))

(define (http-stub-body answer)
  (let ([b (hash-ref answer 'body "")])
    (if (string? b) b (format "~a" b))))

;;; Core HTTP request function.
;;; method: string like "GET", "POST", etc.
;;; url-str: full URL string
;;; req-headers: list of Tuple2 String String (2-element lists)
;;; body-bytes: #f for no body, or a byte string
(define (do-http-request method url-str req-headers body-bytes)
  (require-capabilities! (list httpClient))
  (define-values (host port path-str use-ssl?) (parse-url-parts url-str))
  ;; Convert Tesl header list (2-element lists) to list of byte strings.
  ;; Reject CR/LF in any header name or value: a `\r\n` would split the outbound
  ;; request and inject arbitrary headers / smuggle a second request.
  (define (no-crlf field s)
    (unless (http-header-field-safe? s)
      (raise-user-error 'HttpClient
                        "outbound ~a contains a CR/LF newline — header injection rejected"
                        field))
    s)
  (define header-bytes
    (for/list ([h (in-list req-headers)])
      (define-values (name-str val-str) (http-header-pair 'HttpClient h))
      (string->bytes/utf-8
       (string-append (no-crlf "header name" name-str) ": "
                      (no-crlf "header value" val-str)))))
  (define stub
    (http-stub-answer 'unary method url-str req-headers
                      (and body-bytes (bytes->string/utf-8 body-bytes #\?))))
  (cond
    [stub
     (HttpResponse #:status  (http-stub-status stub)
                   #:body    (http-stub-body stub)
                   #:headers (hash-ref stub 'headers '()))]
    [else (do-http-request/network method url-str path-str host port use-ssl?
                                   header-bytes body-bytes)]))

(define (do-http-request/network method url-str path-str host port use-ssl?
                                 header-bytes body-bytes)
  ;; Cap the response body (DoS): port->bytes reads the entire upstream body with
  ;; no limit, so a large/hostile response can exhaust memory.  Read at most
  ;; max-response-bytes (TESL_HTTP_MAX_RESPONSE_BYTES, default 10 MiB) and reject
  ;; anything larger.
  (define max-response-bytes
    (let ([v (getenv "TESL_HTTP_MAX_RESPONSE_BYTES")])
      (or (and v (let ([n (string->number v)]) (and (exact-positive-integer? n) n)))
          (* 10 1024 1024))))
  (define connect-ms (http-connect-timeout-ms))
  (define read-ms    (http-read-timeout-ms))
  ;; `http-sendrecv` IS `http-conn-open` + `http-conn-sendrecv! #:close? #t`, so
  ;; splitting it here changes nothing about the request — it only gives the two
  ;; phases separate deadlines: one for reaching the host, one for the answer.
  (define cust (make-custodian))
  (dynamic-wind
    void
    (lambda ()
      (with-handlers
          (;; Already an HttpClient-shaped error (a deadline, the body cap, a
           ;; header rejection) — pass it through rather than nesting it inside
           ;; the generic "HTTP … failed" wrapper.
           [exn:fail:user? raise]
           [exn:fail?
            (lambda (e)
              (raise-user-error 'HttpClient
                                "HTTP ~a to ~a failed: ~a"
                                method url-str
                                (exn-message e)))])
        (define hc
          (call-with-http-deadline
           cust connect-ms (format "connect to ~a" url-str)
           (lambda () (http-conn-open host #:ssl? use-ssl? #:port port))))
        (call-with-http-deadline
         cust read-ms (format "HTTP ~a to ~a" method url-str)
         (lambda ()
           (define-values (status-line resp-headers resp-port)
             (http-conn-sendrecv! hc path-str
                                  #:method method
                                  #:headers header-bytes
                                  #:data (or body-bytes #"")
                                  #:close? #t))
           ;; Parse status code from the HTTP status line (e.g. "HTTP/1.1 200 OK")
           (define status-code
             (let* ([line (if (bytes? status-line)
                              (bytes->string/utf-8 status-line)
                              status-line)]
                    [parts (string-split line " ")])
               (if (>= (length parts) 2)
                   (or (string->number (second parts)) 0)
                   0)))
           (define body-bytes-resp
             (let ([bs (read-bytes (add1 max-response-bytes) resp-port)])
               (cond
                 [(eof-object? bs) #""]
                 [(> (bytes-length bs) max-response-bytes)
                  (raise-user-error 'HttpClient
                                    "response body exceeds the ~a-byte cap" max-response-bytes)]
                 [else bs])))
           (define body-str (bytes->string/utf-8 body-bytes-resp #\?))
           (define headers-list (parse-response-headers resp-headers))
           (HttpResponse #:status status-code
                         #:body body-str
                         #:headers headers-list)))))
    ;; The whole body is already in hand, so the connection has no further use —
    ;; releasing the custodian closes it on the success path as well as after a
    ;; deadline.
    (lambda () (custodian-shutdown-all cust))))

;;; #23: streaming POST for provider token streaming (Server-Sent Events).  Same
;;; capability gate and CR/LF header guard as [do-http-request], but returns the
;;; response body PORT so the caller can read SSE `data:` lines incrementally as
;;; the model generates, instead of buffering the whole completion.  Returns
;;; (values status-code input-port).  No DoS body cap here: SSE bodies are read
;;; and discarded line-by-line by the caller (the parser bounds accumulation), and
;;; the connection is caller-owned (closed when the parse ends).
;;;
;;; Deadlines: the connect phase gets the same TESL_HTTP_CONNECT_TIMEOUT_MS as a
;;; unary call, but the response gets an IDLE budget
;;; (TESL_HTTP_STREAM_IDLE_TIMEOUT_MS) rather than a total one — a healthy SSE
;;; stream is long-lived by design, so only a GAP means the upstream is gone.
(define (http-post-stream url-str req-headers body-str)
  (require-capabilities! (list httpClient))
  (define-values (host port path-str use-ssl?) (parse-url-parts url-str))
  (define (no-crlf field s)
    (unless (http-header-field-safe? s)
      (raise-user-error 'HttpClient
                        "outbound ~a contains a CR/LF newline — header injection rejected"
                        field))
    s)
  (define header-bytes
    (for/list ([h (in-list req-headers)])
      (define-values (name-str val-str) (http-header-pair 'HttpClient h))
      (string->bytes/utf-8
       (string-append (no-crlf "header name" name-str) ": "
                      (no-crlf "header value" val-str)))))
  (define stub (http-stub-answer 'stream "POST" url-str req-headers body-str))
  ;; Transparent gzip is the wrong trade for an SSE body: with the default
  ;; #:content-decode '(gzip) the request advertises gzip, the server
  ;; compresses the event stream, and the decoded bytes only surface when the
  ;; response COMPLETES — every delta arrives in one end-of-call burst
  ;; (issue #43).  Force identity so deltas arrive as they are generated.
  (define stream-header-bytes
    (if (for/or ([h (in-list header-bytes)])
          (regexp-match? #rx"(?i:^accept-encoding:)" h))
        header-bytes
        (cons #"Accept-Encoding: identity" header-bytes)))
  (cond
    [stub
     ;; A stubbed stream answers from memory: the canned body is the whole event
     ;; stream, so it is never idle and needs no deadline.
     (values (http-stub-status stub)
             (open-input-string (http-stub-body stub)))]
    [else
     (define connect-ms (http-connect-timeout-ms))
     (define idle-ms    (http-stream-idle-timeout-ms))
     (define cust (make-custodian))
     (define (release!) (custodian-shutdown-all cust))
     (define-values (status-line resp-port)
       ;; Nothing survives a failed open, so release the connection either way;
       ;; custodian-shutdown-all is idempotent, and the deadline guard has
       ;; already released on its own path.
       (with-handlers ([exn:fail:user? (lambda (e) (release!) (raise e))]
                       [exn:fail?
                        (lambda (e)
                          (release!)
                          (raise-user-error 'HttpClient
                                            "streaming POST to ~a failed: ~a"
                                            url-str (exn-message e)))])
         (define hc
           (call-with-http-deadline
            cust connect-ms (format "connect to ~a" url-str)
            (lambda () (http-conn-open host #:ssl? use-ssl? #:port port))))
         ;; The status line + headers must arrive within one idle budget; after
         ;; that the per-read idle timeout on the body port takes over.
         (call-with-http-deadline
          cust idle-ms (format "streaming POST to ~a" url-str)
          (lambda ()
            (define-values (sl _hdrs rp)
              (http-conn-sendrecv! hc path-str
                                   #:method "POST"
                                   #:headers stream-header-bytes
                                   #:data (string->bytes/utf-8 body-str)
                                   #:content-decode '()
                                   #:close? #t))
            (values sl rp)))))
     (define status-code
       (let* ([line (if (bytes? status-line) (bytes->string/utf-8 status-line) status-line)]
              [parts (string-split line " ")])
         (if (>= (length parts) 2) (or (string->number (second parts)) 0) 0)))
     ;; Closing the returned port releases the custodian, so the caller's existing
     ;; `close-input-port` in a dynamic-wind still frees the socket.
     (values status-code
             (idle-timeout-input-port resp-port idle-ms url-str release!))]))

;;; --- Public API ---

;;; HttpClient.get url headers -> HttpResponse
;;; Performs a GET request to url with the given headers.
;;; headers: List (Tuple2 String String)
(define (HttpClient.get url headers)
  (do-http-request "GET" url headers #f))

;;; HttpClient.post url headers body -> HttpResponse
;;; Performs a POST request to url with the given headers and body.
;;; headers: List (Tuple2 String String), body: String
(define (HttpClient.post url headers body)
  (define body-bytes (string->bytes/utf-8 body))
  (do-http-request "POST" url headers body-bytes))

;;; HttpClient.put url headers body -> HttpResponse
;;; Performs a PUT request to url with the given headers and body.
;;; headers: List (Tuple2 String String), body: String
(define (HttpClient.put url headers body)
  (define body-bytes (string->bytes/utf-8 body))
  (do-http-request "PUT" url headers body-bytes))

;;; HttpClient.delete url headers -> HttpResponse
;;; Performs a DELETE request to url with the given headers.
;;; headers: List (Tuple2 String String)
(define (HttpClient.delete url headers)
  (do-http-request "DELETE" url headers #f))
