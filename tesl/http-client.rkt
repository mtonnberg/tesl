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
         (only-in "../dsl/types.rkt" define-record adt-value? adt-value-type adt-value-fields
                  ;; `secret` outbound headers: the ONE place a secret's plaintext
                  ;; is taken back out, inside trusted code, on its way to the socket.
                  secret-value? newtype-value? newtype-value-value
                  secret-header-value secret-header-value?
                  secret-header-value-plaintext
                  record-value-fields)
         ;; W3C trace context propagation + the Traces signal.  dsl/trace-context.rkt
         ;; requires only racket/*, and dsl/traces.rkt reaches this file by
         ;; `dynamic-require` (never a static require), so neither edge cycles.
         (only-in "../dsl/trace-context.rkt"
                  current-traceparent-header
                  current-tracestate-header)
         (only-in "../dsl/traces.rkt" with-span span-add-attributes! span-mark-error!)
         (only-in "../dsl/private/evidence.rkt" raw-value)
         ;; tesl/tuple.rkt requires only dsl/types.rkt + evidence.rkt, so there is
         ;; no cycle; `Tuple2` is the header pair every verb already accepts.
         (only-in "tuple.rkt" Tuple2)
         (only-in "private/http-stub.rkt" current-outbound-http-hook)
         ;; Phase -1 (roadmap/next/ensure_sso_works.md): a VERIFYING TLS client
         ;; context.  Racket's default `#:ssl? #t` authenticates NOTHING -- no
         ;; certificate chain and no hostname -- so every outbound HTTPS call was
         ;; MITM-able.  `ssl-secure-client-context` verifies both.
         (only-in openssl ssl-secure-client-context
                  ports->ssl-ports ssl-abandon-port)
         ;; #48 (issue): SSRF egress containment lives on the CLIENT so every
         ;; outbound call is contained, not just SSO.  The classifier judges a
         ;; RESOLVED address; the pin below connects and judges the peer we
         ;; actually reached, before any TLS handshake or request byte.
         (only-in "../dsl/private/ssrf-guard.rkt" ip-forbidden-reason))

(provide httpClient
         HttpResponse
         HttpResponse?
         HttpClient.get
         HttpClient.post
         HttpClient.put
         HttpClient.delete
         ;; Secret-accepting outbound header sinks (roadmap/completed/tesl_crypto.md's
         ;; secret-accepting-sinks table).
         HttpClient.bearer
         HttpClient.secretHeader
         ;; #23: streaming POST (SSE) for provider token streaming.
         http-post-stream
         ;; Security: outbound header CRLF guard (exported for the regression suite)
         http-header-field-safe?
         ;; Security: the single TLS development escape + loopback test, exported
         ;; for the Phase -1 regression suite.
         tls-insecure-dev-escape?
         host-loopback?
         ;; #48: SSRF egress decision (exported for the containment regression suite)
         ssrf-egress-refusal
         ssrf-allow-loopback?
         ssrf-pinned-http-conn-open
         ;; Timeout knobs (exported for the regression suite — see the block below)
         http-connect-timeout-ms
         http-read-timeout-ms
         http-stream-idle-timeout-ms)

;;; A header name/value is safe iff it contains no CR or LF — either would split
;;; the outbound request and inject arbitrary headers / smuggle a request.  Pure
;;; predicate, exported for the security regression suite.
(define (http-header-field-safe? s)
  (not (regexp-match? #rx"[\r\n]" s)))

;;; ── Phase -1: TLS peer authentication ────────────────────────────────────────
;;;
;;; Every outbound HTTPS call authenticates its peer's certificate chain AND
;;; hostname through a VERIFYING client context.  This closes a live defect: the
;;; previous bare `#:ssl? #t` used Racket's default client context, which checks
;;; neither, so any on-path attacker could impersonate any HTTPS host to a Tesl
;;; webhook, a payment call, an agent provider, or (later) an SSO exchange.
;;;
;;; This makes TLS *correct*, not *sufficient*: a host that trusts an
;;; interception middlebox's CA still validates that middlebox happily.  That is
;;; why SSO ID-token signatures are verified separately -- see
;;; roadmap/next/ensure_sso_works.md §The trust argument, honestly.
;;;
;;; `ssl-secure-client-context` loads the system trust store, so it is built once
;;; and shared; the context is immutable and safe to reuse across calls.
(define secure-client-context
  (let ([cached #f])
    (lambda ()
      (unless cached (set! cached (ssl-secure-client-context)))
      cached)))

;;; A host is loopback iff it can only be reached from this machine.  Used ONLY
;;; to bound the development escape below; the default secure path ignores it.
(define (host-loopback? host)
  (and (string? host)
       (let ([h (string-downcase host)])
         (or (string=? h "localhost")
             (string=? h "::1")
             (string=? h "[::1]")
             (regexp-match? #rx"^127[.][0-9.]+$" h)))))

;;; ── The SINGLE TLS development escape ─────────────────────────────────────────
;;;
;;; There is exactly ONE way to disable certificate verification, it is
;;; environment-level (never a per-call flag), and it engages ONLY for a loopback
;;; host -- so a developer can talk to a local service presenting a self-signed
;;; cert, and nothing else.  A ratchet test asserts no bare `#:ssl? #t` literal
;;; reappears in the tree, i.e. that no second opt-out is ever added.
;;;
;;; It refuses to engage for any routable host, and refuses in a deployed build
;;; (`TESL_DEPLOYED`); the build-artifact signal folds into this one development
;;; gate once the deploy target lands (ensure_sso_works.md, Phase -2/3).
(define tls-dev-active-warned? (box #f))
(define tls-dev-refused-warned? (box #f))
(define (tls-insecure-dev-requested?)
  (and (not (getenv "TESL_DEPLOYED"))
       (let ([v (getenv "TESL_HTTP_TLS_INSECURE_DEV")])
         (and v (and (member (string-downcase (string-trim v))
                             '("1" "true" "yes" "on"))
                     #t)))))
(define (tls-insecure-dev-escape? host)
  (cond
    [(not (tls-insecure-dev-requested?)) #f]
    [(host-loopback? host)
     (unless (unbox tls-dev-active-warned?)
       (set-box! tls-dev-active-warned? #t)
       (eprintf (string-append
                 "WARNING: TESL_HTTP_TLS_INSECURE_DEV active -- HTTPS certificate "
                 "verification is DISABLED for loopback hosts only. "
                 "Never enable this in production.\n")))
     #t]
    [else
     (unless (unbox tls-dev-refused-warned?)
       (set-box! tls-dev-refused-warned? #t)
       (eprintf (string-append
                 "WARNING: TESL_HTTP_TLS_INSECURE_DEV is set but host ~s is not "
                 "loopback -- TLS verification stays ON.\n")
                host))
     #f]))


;;; ── #48: SSRF egress containment (resolve + connect-pinned) ──────────────────
;;;
;;; The dangerous SSRF targets — cloud metadata (169.254.169.254), RFC1918,
;;; CGNAT, unique-local, link-local, 0.0.0.0/8 — are refused for EVERY outbound
;;; call by default, judged by the address we actually connected to (so a DNS
;;; record that resolves a public name to an internal address is caught).  There
;;; is exactly one resolution (tcp-connect), so there is no check->connect rebind
;;; gap, and the judgement happens before any TLS handshake or request byte.
;;;
;;; Loopback is the one range local development legitimately uses, so it is
;;; ALLOWED in a non-deployed build and DENIED in a deployed build
;;; (`TESL_DEPLOYED`) unless `TESL_HTTP_ALLOW_LOOPBACK_EGRESS` opts back in.
(define (ssrf-allow-loopback?)
  (cond
    [(not (getenv "TESL_DEPLOYED")) #t]
    [else (let ([v (getenv "TESL_HTTP_ALLOW_LOOPBACK_EGRESS")])
            (and v (and (member (string-downcase (string-trim v)) '("1" "true" "yes" "on")) #t)))]))

;; Refusal reason for a resolved/connected peer IP, or #f to allow.  Public
;; addresses are always allowed; loopback is allowed per `ssrf-allow-loopback?`;
;; every other private range is always refused.  Exported for the unit suite.
(define (ssrf-egress-refusal peer-ip)
  (define reason (ip-forbidden-reason peer-ip))
  (cond
    [(not reason) #f]
    [(and (host-loopback? peer-ip) (ssrf-allow-loopback?)) #f]
    [else reason]))

;; Resolve+connect atomically, judge the peer, then (for https) TLS-wrap with the
;; SAME verifying context + hostname as the direct path (so #47 is preserved) and
;; drive HTTP over the pinned ports via net/http-client's tunnel form.
(define (ssrf-pinned-http-conn-open host port use-ssl?)
  (define-values (raw-from raw-to) (tcp-connect host port))
  (with-handlers ([(lambda (_e) #t)
                   (lambda (e)
                     (when (input-port? raw-from) (close-input-port raw-from))
                     (when (output-port? raw-to) (close-output-port raw-to))
                     (raise e))])
    (define-values (_lh _lp peer-ip _rp) (tcp-addresses raw-to #t))
    (define reason (ssrf-egress-refusal peer-ip))
    (when reason
      (raise-user-error 'HttpClient
                        "SSRF: refused egress to ~a — it resolves to ~a, which is ~a"
                        host peer-ip reason))
    (define hc (http-conn))
    (cond
      [use-ssl?
       (define-values (sf st)
         (if (tls-insecure-dev-escape? host)
             (ports->ssl-ports raw-from raw-to #:mode 'connect #:close-original? #t)
             (ports->ssl-ports raw-from raw-to #:mode 'connect
                               #:context (secure-client-context)
                               #:hostname host #:close-original? #t)))
       (http-conn-open! hc host #:ssl? (list #t sf st ssl-abandon-port) #:port port)]
      [else
       (http-conn-open! hc host #:ssl? (list #f raw-from raw-to tcp-abandon-port) #:port port)])
    hc))

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
;;; THE unwrap point for a `secret` on its way onto the wire.
;;;
;;; `HttpClient.bearer` / `HttpClient.secretHeader` are typed as returning a
;;; `Tuple2 String String`, but the value half they actually build is a
;;; `secret-header-value` — not a string, so no String primitive can touch it,
;;; and it prints as "[redacted]" so nothing that renders it can leak it.  Here,
;;; in trusted code, one function turns it back into the plaintext bytes that go
;;; on the socket.  A plain `newtype-value` is unwrapped too (a secret column
;;; value handed to a header keeps working), and the CR/LF guard below still
;;; applies to the result — the guard is the reason this returns a string rather
;;; than deferring the coercion.
(define (header-field->string who v)
  (cond
    [(string? v) v]
    [(secret-header-value? v) (secret-header-value-plaintext v)]
    [(newtype-value? v) (header-field->string who (newtype-value-value v))]
    [else
     (raise-user-error who
                       "expected a header name/value as String, got ~a"
                       (if (secret-value? v) "a secret" v))]))

(define (http-header-pair who h)
  (define v (raw-value h))
  (define (fld x) (header-field->string who (raw-value x)))
  (cond
    [(and (adt-value? v) (equal? (adt-value-type v) 'Tuple2))
     (define fs (adt-value-fields v))
     (values (fld (hash-ref fs 'first  "")) (fld (hash-ref fs 'second "")))]
    [(and (list? v) (= (length v) 2)) (values (fld (first v)) (fld (second v)))]
    [(and (pair? v) (not (list? v)))  (values (fld (car v)) (fld (cdr v)))]
    [(string? v) (values v "")]
    [else
     (raise-user-error who
                       "expected a header as Tuple2 String String, got ~a" v)]))

;;; ── Secret-accepting header constructors ─────────────────────────────────────
;;;
;;; `HttpClient.secretHeader "X-Api-Key" k` and `HttpClient.bearer k` are the
;;; sanctioned way a secret reaches an outbound header, replacing the
;;; `("Authorization", "Bearer " ++ key.value)` that `secret` makes impossible.
;;; The returned pair is an ordinary Tuple2 ADT value (so it drops straight into
;;; the header list every verb already accepts); only its value half is the
;;; opaque `secret-header-value` wrapper.
(define (make-secret-header who name secret [prefix ""])
  (unless (string? name)
    (raise-user-error who "header name must be a String, got ~a" name))
  (define inner (raw-value secret))
  (define plain
    (cond
      [(newtype-value? inner) (newtype-value-value inner)]
      [(string? inner) inner]
      [else (raise-user-error who "expected a Secret, got ~a" inner)]))
  (unless (string? plain)
    (raise-user-error who "expected a Secret over String"))
  (Tuple2 name (secret-header-value (string-append prefix plain))))

(define (HttpClient.secretHeader name secret)
  (make-secret-header 'HttpClient.secretHeader name secret))

(define (HttpClient.bearer secret)
  (make-secret-header 'HttpClient.bearer "Authorization" secret "Bearer "))

;;; ── W3C trace context propagation (outbound) ─────────────────────────────────
;;;
;;; Before this, an outbound call sent ONLY caller-supplied headers, so calling
;;; another service BROKE the trace: the downstream span had no parent and the
;;; caller's trace showed a hole where our app was.  Every verb now carries
;;; `traceparent` (and the inbound `tracestate`, unmodified) from the ambient
;;; context — no new call sites, no signature change.
;;;
;;; A CALLER-SUPPLIED `traceparent` WINS and is never overwritten: a caller that
;;; is deliberately continuing some other trace (a replay tool, a test) means it,
;;; and silently rewriting a header the user set is the kind of surprise that
;;; makes propagation untrustworthy.  When the caller supplies one, we add neither
;;; header — `tracestate` belongs to the `traceparent` it travels with.
;;;
;;; The values are hex/ASCII-validated at their source (dsl/trace-context.rkt), and
;;; `http-header-field-safe?` is applied again here so an injected header can never
;;; be the thing that smuggles a CR/LF.  A value that fails is DROPPED, not
;;; sanitized: an unparseable trace context is worse than none.
(define (header-name-present? req-headers name)
  (for/or ([h (in-list req-headers)])
    (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
      (define-values (n _v) (http-header-pair 'HttpClient h))
      (string-ci=? n name))))

(define (headers-with-trace-context req-headers)
  (define tp (current-traceparent-header))
  (cond
    [(or (not tp)
         (not (http-header-field-safe? tp))
         (header-name-present? req-headers "traceparent"))
     req-headers]
    [else
     (define ts (current-tracestate-header))
     (append req-headers
             (list (list "traceparent" tp))
             (if (and ts (http-header-field-safe? ts))
                 (list (list "tracestate" ts))
                 '()))]))

;;; The response status of an HttpResponse record, for span attribution only.
(define (http-response-status-for-span resp)
  (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
    (define s (hash-ref (record-value-fields resp) 'status #f))
    (and (exact-integer? s) s)))

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
  ;; The CLIENT span brackets the whole call (stub or network), and the trace
  ;; headers are injected INSIDE it, so the downstream service's span becomes a
  ;; child of THIS span rather than of the request root.  Span name stays
  ;; low-cardinality — method + host, never the path, which carries ids.
  ;;
  ;; `url.path` is the path WITHOUT the query string: a query can carry a token or
  ;; an email, and a span is shared into dashboards far more freely than a
  ;; short-retention log line.
  (with-span (client-span
              (format "~a ~a" method host)
              'client
              (list (cons 'http.request.method method)
                    (cons 'server.address host)
                    (cons 'server.port port)
                    (cons 'url.path (car (regexp-split #rx"\\?" path-str)))))
  (define traced-headers (headers-with-trace-context req-headers))
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
    (for/list ([h (in-list traced-headers)])
      (define-values (name-str val-str) (http-header-pair 'HttpClient h))
      (string->bytes/utf-8
       (string-append (no-crlf "header name" name-str) ": "
                      (no-crlf "header value" val-str)))))
  (define stub
    (http-stub-answer 'unary method url-str traced-headers
                      (and body-bytes (bytes->string/utf-8 body-bytes #\?))))
  (define response
    (cond
      [stub
       (HttpResponse #:status  (http-stub-status stub)
                     #:body    (http-stub-body stub)
                     #:headers (hash-ref stub 'headers '()))]
      [else (do-http-request/network method url-str path-str host port use-ssl?
                                     header-bytes body-bytes)]))
  (when client-span
    (define status (http-response-status-for-span response))
    (when status
      (span-add-attributes! client-span (list (cons 'http.response.status_code status)))
      ;; A 4xx/5xx from the SERVER is an error of the call, per HTTP semconv for
      ;; client spans (unlike a server span, where 4xx is the client's fault).
      (when (>= status 400)
        (span-mark-error! client-span (format "HTTP ~a" status)))))
  response))

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
           (lambda () (ssrf-pinned-http-conn-open host port use-ssl?))))
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
(define (http-post-stream url-str req-headers-in body-str)
  (require-capabilities! (list httpClient))
  (define-values (host port path-str use-ssl?) (parse-url-parts url-str))
  ;; Trace context propagates on the streaming path too (a provider call is a
  ;; real outbound hop).  No CLIENT span here: this function RETURNS a port, so
  ;; the work it brackets ends long after it returns — a span closed at return
  ;; would report a duration of "time to first byte" while claiming to be the
  ;; call.  The provider-level span in tesl/agent-provider.rkt covers the whole
  ;; exchange instead.
  (define req-headers (headers-with-trace-context req-headers-in))
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
            (lambda () (ssrf-pinned-http-conn-open host port use-ssl?))))
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
