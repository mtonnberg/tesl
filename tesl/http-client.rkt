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
         (only-in "../dsl/types.rkt" define-record))

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
         http-header-field-safe?)

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
           [query-str (if (null? query)
                          ""
                          (string-append "?"
                            (string-join
                              (map (lambda (p)
                                     (if (cdr p)
                                         (string-append (car p) "=" (cdr p))
                                         (car p)))
                                   query)
                              "&")))])
      (string-append path-string query-str)))
  (values host port path-str use-ssl?))

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
      (define name-str (if (list? h) (first h) h))
      (define val-str  (if (list? h) (second h) ""))
      (string->bytes/utf-8
       (string-append (no-crlf "header name" name-str) ": "
                      (no-crlf "header value" val-str)))))
  (define-values (status-line resp-headers resp-port)
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (raise-user-error 'HttpClient
                                         "HTTP ~a to ~a failed: ~a"
                                         method url-str
                                         (exn-message e)))])
      (http-sendrecv host path-str
                     #:ssl? use-ssl?
                     #:port port
                     #:method method
                     #:headers header-bytes
                     #:data (or body-bytes #""))))
  ;; Parse status code from the HTTP status line (e.g. "HTTP/1.1 200 OK")
  (define status-code
    (let* ([line (if (bytes? status-line)
                     (bytes->string/utf-8 status-line)
                     status-line)]
           [parts (string-split line " ")])
      (if (>= (length parts) 2)
          (or (string->number (second parts)) 0)
          0)))
  ;; Cap the response body (DoS): port->bytes reads the entire upstream body with
  ;; no limit, so a large/hostile response can exhaust memory.  Read at most
  ;; max-response-bytes (TESL_HTTP_MAX_RESPONSE_BYTES, default 10 MiB) and reject
  ;; anything larger.
  (define max-response-bytes
    (let ([v (getenv "TESL_HTTP_MAX_RESPONSE_BYTES")])
      (or (and v (let ([n (string->number v)]) (and (exact-positive-integer? n) n)))
          (* 10 1024 1024))))
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
                #:headers headers-list))

;;; #23: streaming POST for provider token streaming (Server-Sent Events).  Same
;;; capability gate and CR/LF header guard as [do-http-request], but returns the
;;; response body PORT so the caller can read SSE `data:` lines incrementally as
;;; the model generates, instead of buffering the whole completion.  Returns
;;; (values status-code input-port).  No DoS body cap here: SSE bodies are read
;;; and discarded line-by-line by the caller (the parser bounds accumulation), and
;;; the connection is caller-owned (closed when the parse ends).
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
      (define name-str (if (list? h) (first h) h))
      (define val-str  (if (list? h) (second h) ""))
      (string->bytes/utf-8
       (string-append (no-crlf "header name" name-str) ": "
                      (no-crlf "header value" val-str)))))
  (define-values (status-line _resp-headers resp-port)
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (raise-user-error 'HttpClient
                                         "streaming POST to ~a failed: ~a"
                                         url-str (exn-message e)))])
      (http-sendrecv host path-str
                     #:ssl? use-ssl?
                     #:port port
                     #:method "POST"
                     #:headers header-bytes
                     #:data (string->bytes/utf-8 body-str))))
  (define status-code
    (let* ([line (if (bytes? status-line) (bytes->string/utf-8 status-line) status-line)]
           [parts (string-split line " ")])
      (if (>= (length parts) 2) (or (string->number (second parts)) 0) 0)))
  (values status-code resp-port))

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
