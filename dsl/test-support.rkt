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
                  queue-spec-store))

(provide call-with-fresh-memory-db
         call-with-api-test-subscriptions
         dispatch-api-test-request
         api-test-field-access-ref
         api-test-string-fragment
         api-test-path-fragment
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
  (dynamic-wind
    reset!
    thunk
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
  (api-test-response
   (dispatch-request
    server
    (make-request method path #:headers final-headers #:body request-body #:query query)
    #:capabilities capabilities)))

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

(define (api-test-subscribe sse-routes path
                            #:cookie [cookie #f]
                            #:headers [headers (hash)]
                            #:name [name #f])
  (define normalized-headers (normalize-api-test-headers headers))
  (define final-headers
    (if cookie
        (hash-set normalized-headers "cookie" (api-test-cookie->header cookie))
        normalized-headers))
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
  ;; Issue #17: 4th element is the key-index, 5th the list of (index . validator)
  ;; for every declared capture check — see emit_sse_route / handle-sse-request.
  ;; Enforce them here too so the api-test path matches the production path.
  (define key-index (and (>= (length route) 4) (fourth route)))
  (define captures  (if (>= (length route) 5) (fifth route) '()))
  (define key-str   (and key-index (list-ref path key-index)))
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
