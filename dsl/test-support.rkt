#lang racket

(require json
         net/uri-codec
         racket/async-channel
         (except-in racket/list group-by)
         racket/string
         (only-in web-server/http/request-structs header-field header-value)
         web-server/http/response-structs
         "check.rkt"
         "sql.rkt"
         "types.rkt"
         "web.rkt"
         (only-in "../tesl/queue.rkt"
                  channel-spec-listeners
                  channel-for-name
                  queue-spec-store)
         (only-in "../tesl/private/http-stub.rkt" current-outbound-http-hook)
         (only-in "../tesl/http-client.rkt"
                  http-read-timeout-ms
                  http-stream-idle-timeout-ms))

(provide call-with-fresh-memory-db
         ;; Outbound-HTTP test double (api-test / test / load-test scoped).
         api-test-stub-http!
         api-test-stub-http-failure!
         api-test-stub-http-timeout!
         api-test-http-call-count
         api-test-http-last-body
         call-with-api-test-subscriptions
         dispatch-api-test-request
         api-test-field-access-ref
         api-test-string-fragment
         api-test-path-fragment
         api-test-path->segments+query
         register-api-test-workers!
         register-api-test-dead-workers!
         lookup-api-test-workers
         lookup-api-test-dead-workers
         api-test-subscribe
         api-test-collect
         api-test-json-match?
         tesl-prop-random
         tesl-prop-gen-string
         tesl-prop-build-list)

;; #12: the property-test generators are compiler-EMITTED into the USER module's
;; namespace, so any Racket builtin they name by a bare identifier can be shadowed
;; by a user binding of the same name — an `import Tesl.Random exposing [random]`
;; (rebinds `random` to the capability object), or a top-level `fn map`, `fn
;; format`, etc.  When that happens the generator draws a non-number / calls the
;; wrong function and a tautological property spuriously fails ("assertion did not
;; hold").  Route every shadowable primitive the generators use through helpers
;; defined HERE, where the names resolve to racket/base (bound via explicit rename
;; so nothing — not even a transitive require in this file — can shadow them).
;; `zero?`, `make-list`, `-`, `if` need no helper: they are not valid Tesl
;; identifiers, so no user binding can shadow them.
(require (only-in racket/base
                  [random tesl-builtin-random]
                  [format tesl-builtin-format]
                  [build-list tesl-builtin-build-list]))
(define (tesl-prop-random n) (tesl-builtin-random n))
(define (tesl-prop-gen-string) (tesl-builtin-format "s~a" (tesl-builtin-random 1000000)))
(define (tesl-prop-build-list n thunk)
  (tesl-builtin-build-list n (lambda (_) (thunk))))

(struct api-test-sse-stream (name event-channel backlog) #:transparent)

(define api-test-worker-registry (make-hasheq))
(define api-test-dead-worker-registry (make-hasheq))
(define current-api-test-cleanups (make-parameter #f))

(define (api-test-string-fragment value)
  (define raw (runtime-value->jsexpr value))
  (cond
    [(string? raw) raw]
    [(bytes? raw) (bytes->string/utf-8 raw)]
    [(symbol? raw) (symbol->string raw)]
    [else (~a raw)]))

;; A test's `cookie { "k": v, ... }` clause arrives here as a Dict (a Racket hash
;; of name->value). The HTTP layer, however, wants the Cookie *header* as a single
;; string ("k=v; k2=v2"): the request pipeline re-parses that header
;; (parse-cookies-header / tesl-request-cookie via string-split) back into
;; req.cookies with string keys. Setting the header to the raw hash makes those
;; string-split calls blow up ("expected string?, given #hash(...)"), so serialize
;; it. A ready-made string is passed through unchanged.
(define (api-test-cookie->header cookie)
  (cond
    [(string? cookie) cookie]
    [(hash? cookie)
     (string-join
      (for/list ([(k v) (in-hash cookie)])
        (string-append (if (symbol? k) (symbol->string k) (api-test-string-fragment k))
                       "="
                       (api-test-string-fragment v)))
      "; ")]
    [else (api-test-string-fragment cookie)]))

(define (api-test-path-fragment value)
  (uri-encode (api-test-string-fragment value)))

;; ── Request paths: literal or computed, one normalization (issue #45) ────────
;; The emitter pre-splits a STRING-LITERAL path into segments — `get "/todos/1"`
;; arrives here as `(list "todos" "1")` with its `?query` already lifted to
;; #:query.  Every other path expression (a `let`-bound string, a `++`
;; concatenation, an id read out of a previous response) cannot be split at
;; compile time, so it arrives as the whole path VALUE instead.  Both shapes are
;; normalized here to (segments . query), which is why
;;   let p = "/todos/1"   get p
;; is now the same request as the literal — previously the raw string reached
;; the HTTP layer and `map` failed with a contract violation, surfacing as a
;; bare "assertion did not hold" for the whole test body.
;;
;; A computed path is treated exactly like a literal one: split on "/", empty
;; segments dropped, `?…` lifted to the query string, no extra encoding (the
;; caller wrote the whole path).  Interpolated HOLES inside a literal stay
;; uri-encoded by [api-test-path-fragment] as before.
(define (api-test-path->segments+query who path)
  (define raw (runtime-value->jsexpr path))
  (cond
    ;; Already-split literal path.  The emitter only ever produces STRING
    ;; segments here (a literal fragment, or api-test-path-fragment's
    ;; uri-encoded hole), so a list of strings is accepted as segments — which
    ;; also makes a Tesl `List String` path work — while a list containing
    ;; anything else falls through to the error below instead of being routed
    ;; as `1/2/3`.
    [(and (list? raw) (andmap string? raw)) (cons raw "")]
    [(or (string? raw) (bytes? raw) (symbol? raw) (number? raw))
     (define s (api-test-string-fragment raw))
     (define m (regexp-match #rx"^([^?]*)[?]?(.*)$" s))
     (define path-part  (second m))
     (define query-part (third m))
     (cons (string-split path-part "/") query-part)]
    [else
     (raise-user-error
      who
      (string-append
       "request path must be a String (or an already-split segment list), got ~a."
       "\n  A path expression is allowed — `let p = \"/todos/1\"`, `\"/todos/\" ++ id`,"
       "\n  `\"/todos/{id}\"` — but it must evaluate to a string.")
      raw)]))

(define (api-test-field-access-ref value field-name)
  (define raw (runtime-value->jsexpr value))
  (define key
    (cond
      [(symbol? field-name) field-name]
      [(string? field-name) (string->symbol field-name)]
      [else
       (raise-user-error 'api-test-field-access-ref
                         "expected a field name symbol or string, got ~a"
                         field-name)]))
  (cond
    [(hash? raw)
     (cond
       [(hash-has-key? raw key) (hash-ref raw key)]
       [(hash-has-key? raw (symbol->string key)) (hash-ref raw (symbol->string key))]
       [else 'null])]
    [else
     (field-access-ref value key #f 'api-test-field-access-ref)]))

(define (clear-entity-store! entity)
  (define source (entity-spec-source entity))
  (when source
    (define store (if (procedure? source) (source) source))
    (when (and (hash? store) (not (immutable? store)))
      (hash-clear! store))))

(define (clear-api-test-queue! queue-s)
  (define store (queue-spec-store queue-s))
  (when (hash? store)
    (hash-clear! store)))

;; ── Outbound-HTTP test double ────────────────────────────────────────────────
;;
;; roadmap/completed/outbound_http_timeout_and_test_double.md, item 2.  Outbound
;; HTTP had no stubbing anywhere, so a handler or worker that calls an external
;; service had an untestable branch — and the branches you most want covered
;; (upstream 500, malformed JSON, a timeout) are exactly the ones a real upstream
;; will not produce on demand.
;;
;; SCOPING.  Everything here hangs off [current-http-stub-scope], a parameter
;; holding a struct created FRESH by [call-with-fresh-memory-db] — which wraps
;; every `test`, `api-test`, and `load-test` body.  There is no module-level
;; mutable registry: rules and the call log live in the scope value, so they
;; unwind with the test body and cannot leak into the next test.  Outside a test
;; body the parameter is #f and every entry point below raises.
;;
;; PRODUCTION.  This module is required only from a `(module+ test …)`
;; submodule, so a production `racket app.rkt` never instantiates it.  The only
;; thing production sees is the inert parameter in tesl/private/http-stub.rkt.

;; kind ∈ 'respond (payload = (cons status body)) | 'fail (payload = message)
;;      | 'timeout (payload = #f)
(struct http-stub-rule (method url kind payload) #:transparent)
;; `lock` guards the call log: a load-test drives its request thunk from several
;; threads at once, and an unguarded read-append-write would drop entries.
(struct http-stub-scope (rules calls lock) #:mutable #:transparent)

(define current-http-stub-scope (make-parameter #f))

(define (require-http-stub-scope who)
  (or (current-http-stub-scope)
      (raise-user-error
       who
       (string-append
        "outbound-HTTP stubs are only available inside a test body.\n"
        "  Call this from a `test`, `api-test`, or `load-test` block — the stub\n"
        "  scope is created per test so nothing leaks between them."))))

;; Method matching is case-insensitive; URL matching is exact.  `*` alone matches
;; anything, and a trailing `*` matches by prefix (which is how you cover a query
;; string or a path parameter).  Deliberately NOT a regex: a stub pattern is a
;; test fixture, and prefix + wildcard covers every case the lessons need without
;; putting a second pattern language in the surface.
(define (http-stub-pattern-matches? pattern value ci?)
  (define p (if ci? (string-downcase pattern) pattern))
  (define v (if ci? (string-downcase value) value))
  (define len (string-length p))
  (cond
    [(string=? p "*") #t]
    [(and (> len 0) (char=? (string-ref p (sub1 len)) #\*))
     (string-prefix? v (substring p 0 (sub1 len)))]
    [else (string=? p v)]))

(define (http-stub-rule-matches? rule method url)
  (and (http-stub-pattern-matches? (http-stub-rule-method rule) method #t)
       (http-stub-pattern-matches? (http-stub-rule-url rule) url #f)))

;; Rules are consulted in DECLARATION order (first match wins), so a specific
;; stub declared before a `"*"` catch-all keeps winning.  Re-declaring the exact
;; same (method, url) pattern REPLACES the earlier rule in place rather than
;; shadowing it, so a later line in the same test overrides an earlier one.
(define (add-http-stub-rule! who method url kind payload)
  (define scope (require-http-stub-scope who))
  (define fresh (http-stub-rule method url kind payload))
  (define existing (http-stub-scope-rules scope))
  (define replaced?
    (for/or ([r (in-list existing)])
      (and (string=? (http-stub-rule-method r) method)
           (string=? (http-stub-rule-url r) url))))
  (set-http-stub-scope-rules!
   scope
   (if replaced?
       (for/list ([r (in-list existing)])
         (if (and (string=? (http-stub-rule-method r) method)
                  (string=? (http-stub-rule-url r) url))
             fresh
             r))
       (append existing (list fresh))))
  (void))

(define (describe-http-stub-rules rules)
  (if (null? rules)
      "(none)"
      (string-join
       (for/list ([r (in-list rules)])
         (format "~a ~a -> ~a"
                 (http-stub-rule-method r)
                 (http-stub-rule-url r)
                 (case (http-stub-rule-kind r)
                   [(respond) (format "status ~a" (car (http-stub-rule-payload r)))]
                   [(fail)    (format "failure ~s" (http-stub-rule-payload r))]
                   [else      "timeout"])))
       "\n            ")))

;; The hook installed into tesl/http-client.rkt for the duration of one test.
;; Returning #f means "no stub is in force" — which is only possible when the
;; test declared NO stubs at all, so an existing test that really wants to reach
;; the network behaves exactly as before.  Once a test declares its first stub,
;; an unmatched call is a loud failure instead of a silent live request.
(define (http-stub-dispatch scope mode method url _headers body)
  (call-with-semaphore
   (http-stub-scope-lock scope)
   (lambda ()
     (set-http-stub-scope-calls!
      scope
      (append (http-stub-scope-calls scope)
              (list (vector (string-upcase method) url (or body "")))))))
  (define rules (http-stub-scope-rules scope))
  (cond
    [(null? rules) #f]
    [else
     (define rule
       (for/or ([r (in-list rules)]) (and (http-stub-rule-matches? r method url) r)))
     (cond
       [(not rule)
        (raise-user-error
         'HttpClient
         (string-append
          "no stub matches ~a ~a\n"
          "  This test declared outbound-HTTP stubs, so no call reaches the network.\n"
          "  declared: ~a\n"
          "  hint: add `stubHttp \"~a\" \"~a\" 200 \"…\"`, or widen a pattern with a trailing *.")
         (string-upcase method) url (describe-http-stub-rules rules)
         (string-upcase method) url)]
       [(eq? (http-stub-rule-kind rule) 'timeout)
        ;; Byte-for-byte the message the real deadline produces (see
        ;; do-http-request/network and http-post-stream), so a test written
        ;; against the stub matches what production logs.
        (if (eq? mode 'stream)
            (raise-user-error 'HttpClient "streaming POST to ~a timed out after ~ams"
                              url (http-stream-idle-timeout-ms))
            (raise-user-error 'HttpClient "HTTP ~a to ~a timed out after ~ams"
                              (string-upcase method) url (http-read-timeout-ms)))]
       [(eq? (http-stub-rule-kind rule) 'fail)
        (if (eq? mode 'stream)
            (raise-user-error 'HttpClient "streaming POST to ~a failed: ~a"
                              url (http-stub-rule-payload rule))
            (raise-user-error 'HttpClient "HTTP ~a to ~a failed: ~a"
                              (string-upcase method) url (http-stub-rule-payload rule)))]
       [else
        (hash 'status  (car (http-stub-rule-payload rule))
              'body    (cdr (http-stub-rule-payload rule))
              'headers '())])]))

(define (call-with-fresh-http-stubs thunk)
  (define scope (http-stub-scope '() '() (make-semaphore 1)))
  (parameterize ([current-http-stub-scope scope]
                 [current-outbound-http-hook
                  (lambda (mode method url headers body)
                    (http-stub-dispatch scope mode method url headers body))])
    (thunk)))

;; ── The Tesl.ApiTest-facing entry points ─────────────────────────────────────

(define (api-test-stub-http! method url status body)
  (unless (and (string? method) (string? url))
    (raise-user-error 'stubHttp "expected String method and String url, got ~a ~a" method url))
  (unless (exact-integer? status)
    (raise-user-error 'stubHttp "expected an Int status, got ~a" status))
  (unless (string? body)
    (raise-user-error 'stubHttp "expected a String body, got ~a" body))
  (add-http-stub-rule! 'stubHttp method url 'respond (cons status body)))

(define (api-test-stub-http-failure! method url message)
  (unless (and (string? method) (string? url) (string? message))
    (raise-user-error 'stubHttpFailure "expected String method, url, and message"))
  (add-http-stub-rule! 'stubHttpFailure method url 'fail message))

(define (api-test-stub-http-timeout! method url)
  (unless (and (string? method) (string? url))
    (raise-user-error 'stubHttpTimeout "expected String method and String url"))
  (add-http-stub-rule! 'stubHttpTimeout method url 'timeout #f))

(define (matching-http-calls who method url)
  (define scope (require-http-stub-scope who))
  (for/list ([c (in-list (http-stub-scope-calls scope))]
             #:when (and (http-stub-pattern-matches? method (vector-ref c 0) #t)
                         (http-stub-pattern-matches? url (vector-ref c 1) #f)))
    c))

(define (api-test-http-call-count method url)
  (length (matching-http-calls 'httpCallCount method url)))

(define (api-test-http-last-body method url)
  (define calls (matching-http-calls 'httpLastBody method url))
  (when (null? calls)
    (define scope (require-http-stub-scope 'httpLastBody))
    (raise-user-error
     'httpLastBody
     "no outbound ~a call matched ~s\n  calls made: ~a"
     method url
     (if (null? (http-stub-scope-calls scope))
         "(none)"
         (string-join (for/list ([c (in-list (http-stub-scope-calls scope))])
                        (format "~a ~a" (vector-ref c 0) (vector-ref c 1)))
                      ", "))))
  (vector-ref (last calls) 2))

(define (call-with-fresh-memory-db databases thunk)
  (unless (procedure? thunk)
    (raise-user-error 'call-with-fresh-memory-db "expected a thunk, got ~a" thunk))
  ;; Reset the union of (a) the databases the emitter listed — the emitting
  ;; module's own decls — and (b) every registered memory database
  ;; (dsl/sql.rkt).  (a) alone leaks state across test blocks whenever the
  ;; `database` block lives in an IMPORTED module: the emitter cannot see
  ;; imported decls here, so it emits '() and the previous block's rows
  ;; survive (matrix 2026-07: second api-test saw the first's seed — 200 vs
  ;; 404; load-test seed collided on a duplicate primary key).  The registry
  ;; is populated at module instantiation, which requires-order guarantees
  ;; happens before any test block runs, so (b) covers imported databases
  ;; without the emitter needing a require-bound name for them.  Postgres
  ;; databases never register, and clear-entity-store! only touches mutable
  ;; hash sources, so non-memory backends are untouched either way.
  (define db-list
    (remove-duplicates
     (append
      (cond
        [(null? databases) '()]
        [(list? databases) databases]
        [else (list databases)])
      (registered-memory-databases))
     eq?))
  (define (reset!)
    (for ([database (in-list db-list)])
      (for ([entity (in-list (database-spec-entities database))])
        (clear-entity-store! entity)))
    (for ([queue-s (in-list (remove-duplicates
                             (append (hash-keys api-test-worker-registry)
                                     (hash-keys api-test-dead-worker-registry))
                             eq?))])
      (clear-api-test-queue! queue-s)))
  ;; The outbound-HTTP stub scope rides along here rather than in
  ;; call-with-api-test-subscriptions because THIS wrapper is the one every
  ;; `test`, `api-test`, and `load-test` body already goes through — so plain
  ;; `test` blocks get the double too, and the emitter needs no change at all
  ;; (every committed .rkt snapshot stays byte-identical).
  (dynamic-wind
    reset!
    (lambda () (call-with-fresh-http-stubs thunk))
    reset!))

(define (call-with-api-test-subscriptions thunk)
  (unless (procedure? thunk)
    (raise-user-error 'call-with-api-test-subscriptions "expected a thunk, got ~a" thunk))
  (define cleanups (box '()))
  (dynamic-wind
    void
    (lambda ()
      (parameterize ([current-api-test-cleanups cleanups])
        (thunk)))
    (lambda ()
      (for ([cleanup (in-list (reverse (unbox cleanups)))])
        (with-handlers ([exn:fail? void])
          (cleanup))))))

(define (normalize-api-test-headers headers)
  (unless (hash? headers)
    (raise-user-error 'dispatch-api-test-request "expected a headers hash, got ~a" headers))
  (for/hash ([(key value) (in-hash headers)])
    (values (string-downcase (api-test-string-fragment key))
            (api-test-string-fragment value))))

(define (response-headers->hash headers)
  (for/hash ([h (in-list headers)])
    (values (string-downcase (bytes->string/utf-8 (header-field h)))
            (bytes->string/utf-8 (header-value h)))))

(define (api-test-response response)
  (hash 'status  (dsl-response-status response)
        'body    (dsl-response-body response)
        'headers (response-headers->hash (dsl-response-headers response))))

(define (dispatch-api-test-request server method path
                                   #:cookie [cookie #f]
                                   #:headers [headers (hash)]
                                   #:body [body #f]
                                   #:query [query ""]
                                   #:capabilities [capabilities '()])
  (define normalized-headers (normalize-api-test-headers headers))
  (define request-headers
    (cond
      [cookie (hash-set normalized-headers "cookie" (api-test-cookie->header cookie))]
      [else normalized-headers]))
  (define final-headers
    (if body
        (hash-set request-headers "content-type" "application/json")
        request-headers))
  (define request-body (if body (jsexpr->bytes body) #""))
  ;; A literal path arrives pre-split with its query already in #:query; a
  ;; computed one arrives whole, so its `?…` is lifted here (issue #45).
  (define normalized (api-test-path->segments+query 'dispatch-api-test-request path))
  (define path-segments (car normalized))
  (define final-query (if (equal? query "") (cdr normalized) query))
  ;; `dispatch-request` deliberately returns the 'route-not-found SENTINEL (so
  ;; `serve` can choose between a 404 and the SPA index fallback).  An api-test
  ;; has no static fallback, so resolve it the way serve's non-static branch
  ;; does — a real 404 response.  Passing the sentinel to api-test-response
  ;; raised `dsl-response-status: contract violation`, i.e. a request to a path
  ;; the server does not serve blew up the test body instead of reporting 404.
  (define result
    (dispatch-request
     server
     (make-request method path-segments
                   #:headers final-headers #:body request-body #:query final-query)
     #:capabilities capabilities))
  (api-test-response
   (if (eq? result 'route-not-found)
       (error-response 404 "Route not found")
       result)))

(define (register-api-test-worker-entries! registry entries)
  (define grouped (make-hasheq))
  (for ([entry (in-list entries)])
    (unless (and (list? entry) (= (length entry) 3))
      (raise-user-error 'register-api-test-worker-entries!
                        "expected (list queue job-type handler), got ~a"
                        entry))
    (define queue-s  (first entry))
    (define job-type (second entry))
    (define handler  (third entry))
    (hash-set! grouped queue-s
               (cons (cons job-type handler)
                     (hash-ref grouped queue-s '()))))
  (for ([(queue-s bindings) (in-hash grouped)])
    (hash-set! registry queue-s (reverse bindings)))
  (void))

(define (register-api-test-workers! entries)
  (register-api-test-worker-entries! api-test-worker-registry entries))

(define (register-api-test-dead-workers! entries)
  (register-api-test-worker-entries! api-test-dead-worker-registry entries))

(define (lookup-api-test-workers queue-s)
  (hash-ref api-test-worker-registry queue-s '()))

(define (lookup-api-test-dead-workers queue-s)
  (hash-ref api-test-dead-worker-registry queue-s '()))

;; Issue #17: mirror the production matcher (find-sse-match) — match the full
;; path pattern where #f is a `:param` wildcard, exact length.
(define (find-api-test-sse-route sse-routes path)
  (for/or ([route (in-list sse-routes)])
    (define pattern (first route))
    (and (= (length path) (length pattern))
         (for/and ([seg (in-list pattern)] [p (in-list path)])
           (or (not seg) (equal? seg p)))
         route)))

(define (api-test-subscribe sse-routes raw-path
                            #:cookie [cookie #f]
                            #:headers [headers (hash)]
                            #:name [name0 #f])
  (define normalized-headers (normalize-api-test-headers headers))
  (define final-headers
    (if cookie
        (hash-set normalized-headers "cookie" (api-test-cookie->header cookie))
        normalized-headers))
  ;; Same literal-or-computed path normalization as dispatch (issue #45): a
  ;; `let`-bound / concatenated subscribe path used to reach find-api-test-sse-route
  ;; as a bare string and fail its `length` on a non-list.
  (define path (car (api-test-path->segments+query 'subscribe raw-path)))
  ;; The emitter can only supply a #:name for a literal path (it passes "" for a
  ;; computed one), so an empty name is ABSENT — otherwise every "could not match
  ;; SSE route" message for a computed path named the empty string.
  (define name (if (equal? name0 "") #f name0))
  (define route (find-api-test-sse-route sse-routes path))
  (unless route
    (raise-user-error 'subscribe
                      "subscribe could not match SSE route ~a"
                      (or name path)))
  (define auth-fn   (second route))
  ;; The route's channel slot is either the live channel-spec (declared in the
  ;; emitting module) or its NAME as a symbol (declared in another module —
  ;; issue #41 class); resolve the symbol lazily via the process-wide registry,
  ;; mirroring resolve-sse-channel in dsl/web.rkt.
  (define channel-s (let ([ch (third route)])
                      (if (symbol? ch) (channel-for-name ch) ch)))
  ;; Issue #17 / #54: 4th element is the key SLOT — an integer index, a fixed
  ;; string literal (a broadcast-style channel, e.g. `subscribe
  ;; RunEvents("all")`), or #f (no key) — 5th the list of (index . validator)
  ;; for every declared capture check — see emit_sse_route / handle-sse-request.
  ;; Enforce them here too so the api-test path matches the production path.
  (define key-slot  (and (>= (length route) 4) (fourth route)))
  (define captures  (if (>= (length route) 5) (fifth route) '()))
  (define key-str
    (cond [(not key-slot) #f]
          [(string? key-slot) key-slot]
          [else (list-ref path key-slot)]))
  (define req       (make-request "GET" path #:headers final-headers))
  (when auth-fn
    (define auth-result (auth-fn req))
    (when (check-fail? auth-result)
      (raise-user-error 'subscribe
                        "subscribe failed for ~a: ~a"
                        (or name path)
                        (check-fail-message auth-result))))
  (for ([cv (in-list captures)])
    (define checked ((cdr cv) (list-ref path (car cv))))
    (when (check-fail? checked)
      (raise-user-error 'subscribe
                        "subscribe failed for ~a: ~a"
                        (or name path)
                        (check-fail-message checked))))
  (define event-channel (make-async-channel))
  (define backlog       (box '()))
  (define (on-event evt)
    (async-channel-put event-channel (box evt)))
  (define listeners (channel-spec-listeners channel-s))
  (hash-set! listeners key-str
             (cons on-event (hash-ref listeners key-str '())))
  (define (cleanup)
    (define current (hash-ref listeners key-str '()))
    (hash-set! listeners key-str (remove on-event current)))
  (define cleanups (current-api-test-cleanups))
  (when cleanups
    (set-box! cleanups (cons cleanup (unbox cleanups))))
  (api-test-sse-stream (or name (string-append "/" (string-join path "/")))
                       event-channel
                       backlog))

(define (api-test-normalize-json value)
  (define raw (runtime-value->jsexpr value))
  (cond
    [(hash? raw)
     (for/hash ([(key val) (in-hash raw)])
       (values (if (symbol? key) (symbol->string key) key)
               (api-test-normalize-json val)))]
    [(list? raw)
     (map api-test-normalize-json raw)]
    [(vector? raw)
     (map api-test-normalize-json (vector->list raw))]
    [else raw]))

(define (api-test-json-match? pattern value)
  (define normalized-pattern (api-test-normalize-json pattern))
  (define normalized-value   (api-test-normalize-json value))
  (cond
    [(hash? normalized-pattern)
     (and (hash? normalized-value)
          (for/and ([(key expected) (in-hash normalized-pattern)])
            (and (hash-has-key? normalized-value key)
                 (api-test-json-match? expected (hash-ref normalized-value key)))))]
    [(list? normalized-pattern)
     (and (list? normalized-value)
          (= (length normalized-pattern) (length normalized-value))
          (for/and ([expected (in-list normalized-pattern)]
                    [actual   (in-list normalized-value)])
            (api-test-json-match? expected actual)))]
    [else (equal? normalized-pattern normalized-value)]))

(define (api-test-format-json value)
  (with-handlers ([exn:fail? (lambda (_e) (~a value))])
    (jsexpr->string (api-test-normalize-json value))))

(define (api-test-duration->string timeout-ms)
  (cond
    [(and (integer? timeout-ms) (zero? (remainder timeout-ms 1000)))
     (format "~as" (/ timeout-ms 1000))]
    [else (format "~ams" timeout-ms)]))

(define (api-test-drain-stream! stream)
  (define event-channel (api-test-sse-stream-event-channel stream))
  (define backlog       (api-test-sse-stream-backlog stream))
  (let loop ([events (unbox backlog)])
    (define wrapped (async-channel-try-get event-channel))
    (if wrapped
        (loop (append events (list (unbox wrapped))))
        (begin
          (set-box! backlog events)
          events))))

(define (api-test-timeout-message stream timeout-ms description events)
  (string-append
   (format "collect: timed out after ~a waiting for ~a\n"
           (api-test-duration->string timeout-ms)
           description)
   (format "received ~a events on stream ~s\n"
           (length events)
           (api-test-sse-stream-name stream))
   "hint: did the action that produces events run successfully?"))

(define (api-test-collect stream #:count [count #f] #:until [until #f] #:timeout-ms [timeout-ms #f])
  (unless (api-test-sse-stream? stream)
    (raise-user-error 'collect "expected an SseStream, got ~a" stream))
  (when (and count (or (not (integer? count)) (< count 1)))
    (raise-user-error 'collect "count must be a positive Int, got ~a" count))
  (when (and (or count until) (not timeout-ms))
    (raise-user-error 'collect "collect with count or until requires timeout-ms"))
  (define effective-count (if (or count until) count 1))
  (define description
    (cond
      ((and until #t) (format "until ~a" (api-test-format-json until)))
      ((and effective-count #t) (format "count ~a" effective-count))
      (else "events within timeout")))
  (define start-ms (current-inexact-milliseconds))
  (define (finish-prefix! prefix-count)
    (define events (api-test-drain-stream! stream))
    (define prefix (take events prefix-count))
    (define suffix (drop events prefix-count))
    (set-box! (api-test-sse-stream-backlog stream) suffix)
    prefix)
  (define (finish-all!)
    (define events (api-test-drain-stream! stream))
    (set-box! (api-test-sse-stream-backlog stream) '())
    events)
  (define (timeout-error events)
    (raise-user-error 'collect
                      "~a"
                      (api-test-timeout-message stream timeout-ms description events)))
  (let loop ()
    (define events (api-test-drain-stream! stream))
    (define until-index
      (and until
           (for/or ((event (in-list events)) (idx (in-naturals)))
             (and (api-test-json-match? until event) idx))))
    (cond
      ((and until until-index)
       (finish-prefix! (add1 until-index)))
      ((and effective-count (>= (length events) effective-count))
       (finish-all!))
      (else
       (define remaining-ms
         (and timeout-ms
              (max 0 (- timeout-ms
                        (inexact->exact
                         (floor (- (current-inexact-milliseconds) start-ms)))))))
       (if (and timeout-ms (zero? remaining-ms))
           (if (and (not count) (not until))
               (finish-all!)
               (timeout-error events))
           (begin
             (sleep (if timeout-ms
                        (min 0.05 (/ (max remaining-ms 1) 1000.0))
                        0.05))
             (loop)))))))
