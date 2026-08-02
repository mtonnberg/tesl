#lang racket

(require json
         net/uri-codec
         net/url-structs
         racket/file
         racket/function
         racket/list
         racket/string
         racket/stxparam
         web-server/http/request-structs
         web-server/http/response-structs
         web-server/servlet-env
         "capability.rkt"
         "private/check-runtime.rkt"
         "private/proof-utils.rkt"
         (only-in "../tesl/logging.rkt"
                  tesl-verbose?
                  tesl-log-active?
                  tesl-log-http-request!
                  tesl-log-http-response!
                  tesl-log-auth-event!)
         (only-in "metrics.rkt"
                  metrics-active?
                  metric-histogram-record!
                  duration-histogram-boundaries)
         ;; W3C trace context + the Traces signal.  Both require nothing of ours
         ;; that could cycle back (see their headers).
         (only-in "trace-context.rkt"
                  make-root-trace-ctx
                  call-with-trace-ctx
                  trace-sample-ratio)
         (only-in "traces.rkt"
                  with-server-span
                  span-set-name!
                  span-add-attributes!
                  span-mark-error!)
         (only-in "../tesl/sse.rkt" make-sse-connection-handler)
         ;; The request-scoped Set-Cookie accumulator.  A deliberately tiny
         ;; module so that `tesl/http.rkt` (which WRITES it, gated by cookieCap)
         ;; and this file (which READS it when building a 2xx) need not require
         ;; each other.
         (only-in "response-cookies.rkt"
                  current-response-cookies
                  response-cookie-headers)
         (only-in "../tesl/queue.rkt"
                  channel-spec?
                  channel-spec-name
                  channel-spec-listeners
                  channel-for-name
                  start-pubsub-listen!)
         (only-in "../dsl/sql.rkt"
                  current-database-runtime
                  database-runtime-connection
                  database-runtime-database
                  database-spec-backend
                  database-schema-name
                  ;; issue #31: pool-lease timeout maps to 503, not 500
                  exn:fail:tesl:pool-timeout?)
         db
         (rename-in "private/trusted.rkt"
                    [trusted-proof trusted-proof/trusted])
         "otel.rkt"
         "types.rkt"
         (for-syntax racket/base
                     racket/list
                     racket/string
                     racket/syntax
                     syntax/parse
                     "types.rkt")
         (for-meta 2 racket/base
                     racket/list
                     racket/syntax
                     syntax/parse))

(provide
 (all-from-out "types.rkt")
 tesl-dot/runtime
 define-handler
 define/pow
 define-trusted
 trusted-proof
 define-capture
 sse-key-capture
 apply-checker-to-value
 define-api
 define-server
 build-server-spec
 serve
 dispatch-request
 ;; The SSE request path, exported for tests/sse-capabilities-test.rkt (F6/F9):
 ;; `serve` reaches it through `serve/servlet`, which a unit test cannot drive
 ;; without opening a port.  Not a Tesl-surface name.
 handle-sse-request
 make-request
 request-header
 json-response
 error-response
 integer-segment
 int32-segment
 string-segment
 ;; Security: static-file path-traversal segment guard (exported for the suite)
 static-path-segments-safe?
 static-path-segment-safe?
 ;; Security: Phase -2 response security headers (exported for the regression
 ;; suite tests/response-security-headers-test.rkt).
 add-security-headers
 security-response-headers
 hsts-header-value
 origin-loopback?
 html-csp-value
 current-content-security-policy
 ;; Phase 3: the publicOrigin server clause sets this at boot.
 current-public-origin
 ;; Phase 3 (OQ11): `publicOrigin fromEnv "VAR"` reads + validates at boot.
 public-origin-from-env valid-public-origin?
 ;; Risk 50/60: the healthProbePath server clause sets this at boot.
 current-health-probe-path host-of
 ;; #51: client address + the trustedProxies edge declaration.
 current-trusted-proxies client-address-of
 ;; Phase 3: runtime-owned SSO routes (exported for the regression suite + the
 ;; emitted server's #:sso-routes).
 (struct-out sso-route) make-sso-route register-sso-routes! sso-routes-for-server
 ;; Phase 3: the listenAddress server clause sets the bind interface at boot.
 register-listen-address!
 find-sso-match handle-sso-request
 sso-redirect-response sso-cookie-line sso-failure-response
 (struct-out dsl-request)
 (struct-out dsl-response)
 current-handler-error-port
 tesl-establish-param-proof
 ;; serverTools (tesl/server-tools.rkt): the agent endpoint-tool builder reuses
 ;; the EXACT boundary pipeline pieces the HTTP dispatcher uses, so tool-arg
 ;; validation and result encoding can never diverge from the HTTP boundary.
 instantiate-binder-proof
 prepare-json
 validate-handler-return)

(struct dsl-request (method path headers body cookies query raw-request) #:transparent)

; Controls where handler runtime errors are logged.
; Defaults to current-error-port (production behaviour).
; Tests that intentionally dispatch to broken handlers can silence
; expected errors by parameterizing this to (open-output-nowhere).
(define current-handler-error-port (make-parameter #f))
(define (handler-error-port) (or (current-handler-error-port) (current-error-port)))

(define (parse-cookies-header cookie-header-str)
  (for*/hash ([raw-part  (in-list (string-split (or cookie-header-str "") ";"))]
              [part      (in-value (string-trim raw-part))]
              [m         (in-value (regexp-match #rx"^([^=]+)=(.*)" part))]
              #:when m)
    (values (string-trim (cadr m)) (caddr m))))

;; Query parameters → a Dict-shaped hash: String key -> String value, form-url
;; decoded, last-wins on repeated keys (for/hash keeps the last binding), keys
;; case-sensitive.  `query-alist->hash` consumes the parsed alist shape that BOTH
;; `(url-query u)` (production) and `form-urlencoded->alist` (api-test inline
;; `?...`) produce: (listof (cons symbol (or string #f))).  A bare `?k` (no `=`)
;; yields the empty string.
(define (query-alist->hash alist)
  (for/hash ([kv (in-list alist)])
    (values (symbol->string (car kv)) (or (cdr kv) ""))))
(define (parse-query-string qs)
  (query-alist->hash (form-urlencoded->alist (or qs ""))))

(struct dsl-response (status headers body) #:transparent)

(define-syntax-parameter trusted-proof
  (lambda (stx)
    (raise-syntax-error 'trusted-proof
                        "only allowed inside define-trusted; handlers, define/pow, and ordinary code must use checkers/authers or other sanctioned trusted boundaries"
                        stx)))

;; NOTE on begin-for-syntax duplication (issue 3.3):
;; This begin-for-syntax block shares structural helpers with
;; dsl/private/check-runtime.rkt (wrap-runtime-named-binding,
;; transform-body-expr, transform-body-sequence, and several
;; binding/name utilities).  See the matching comment in check-runtime.rkt
;; for a full analysis.  Summary of key divergences that make a shared
;; body-transform.rkt non-trivial:
;;  • transform-body-expr here leaves `accept`, `detach-proof`, and
;;    `attach-proof` as opaque pass-throughs; check-runtime.rkt's version
;;    recurses into them because checker/auther bodies use bare `accept`
;;    and need argument sub-expressions transformed.
;;  • validate-return-stx! here accepts an optional allow-qform? flag
;;    (for define-handler's `(? ...)` return syntax); check-runtime.rkt's
;;    version omits it.
;;  • This file has wrap-runtime-evidence-binding (checker argument binding
;;    variant), build-executable-expansion, and the define-api / Capture
;;    / Auth / ReqBody / Response infrastructure — none present in
;;    check-runtime.rkt's begin-for-syntax.
;; The duplication is intentional and load-bearing; keep both copies in sync.
(begin-for-syntax
  ;; ── Zero-cost proofs ───────────────────────────────────────────────────────
  ;; build-executable-expansion generates the ERASED expansion (no
  ;; runtime-bind+evidence / validate-runtime-argument / parameterize; *arg/arg
  ;; bound to the raw value, proof-annotated params keeping ONE allocation via
  ;; tesl-establish-param-proof).  A sound static checker makes the runtime proof
  ;; structs redundant; the debugger sources proof/type display from compile-time
  ;; type info (see check-runtime.rkt for the full rationale).

  (struct capture-kind-info (binding parser checker raw) #:transparent)

  (define-syntax-class typed-binding
    (pattern [name:id (~datum :) type:expr (~datum :::) proof:expr])
    (pattern [name:id (~datum :) type:expr]))

  (define (binding-canonical-form binding-stx)
    (define-values (canonical _env _next-index)
      (canonicalize-gdp-binding (normalize-type-binding-stx binding-stx)))
    canonical)

  (define (capture-kind-ref who kind-id)
    (define value (syntax-local-value kind-id (lambda () #f)))
    (unless (capture-kind-info? value)
      (raise-syntax-error who
                          (format "unknown capture kind ~a" (syntax-e kind-id))
                          kind-id))
    value)

  (define (capture-kind-binding-compatible? expected-binding-stx actual-binding-stx)
    (equal? (binding-canonical-form expected-binding-stx)
            (binding-canonical-form actual-binding-stx)))

  (define (star-id id)
    (format-id id "*~a" (syntax-e id)))

  (define (literal-id? stx sym)
    (and (identifier? stx)
         (eq? (syntax-e stx) sym)))

  (define (binding-parts binding-stx)
    (define parts (syntax->list binding-stx))
    (unless (and parts (or (= (length parts) 3) (= (length parts) 5)))
      (raise-syntax-error 'dsl "expected [name : Type] or [name : Type ::: Proof]" binding-stx))
    (define name-id (first parts))
    (unless (identifier? name-id)
      (raise-syntax-error 'dsl "binding name must be an identifier" binding-stx name-id))
    (unless (literal-id? (second parts) ':)
      (raise-syntax-error 'dsl "expected `:` in typed binding" binding-stx (second parts)))
    (define type-stx (third parts))
    (define proof-stx
      (cond
        [(= (length parts) 3) #f]
        [(literal-id? (fourth parts) ':::) (fifth parts)]
        [else
         (raise-syntax-error 'dsl
                             "expected `:::` before the proof expression"
                             binding-stx
                             (fourth parts))]))
    (values name-id type-stx proof-stx))

  (define (binding-name-id binding-stx)
    (define-values (name-id _type-stx _proof-stx) (binding-parts binding-stx))
    name-id)

  (define (binding-name-symbol binding-stx)
    (syntax-e (binding-name-id binding-stx)))

  (define (duplicate-names names)
    (reverse
     (for/fold ([seen '()] [duplicates '()] #:result duplicates)
               ([name (in-list names)])
       (cond
         [(member name seen)
          (values seen (if (member name duplicates) duplicates (cons name duplicates)))]
         [else
          (values (cons name seen) duplicates)]))))

  (define (report-duplicate-binding-names! who binding-stxs)
    (define duplicates (duplicate-names (map binding-name-symbol binding-stxs)))
    (when (pair? duplicates)
      (raise-syntax-error who
                          (format "duplicate binding name~a: ~a"
                                  (if (= (length duplicates) 1) "" "s")
                                  duplicates)
                          (car binding-stxs))))

  (define (report-unbound-names! who context-stx label missing)
    (when (pair? missing)
      (raise-syntax-error who
                          (format "unbound GDP name~a in ~a: ~a"
                                  (if (= (length missing) 1) "" "s")
                                  label
                                  missing)
                          context-stx)))

  (define (validate-binding-stx! who binding-stx outer-bound-names)
    (report-unbound-names! who
                           binding-stx
                           "typed binding"
                           (binding-unbound-names (syntax->datum binding-stx)
                                                  outer-bound-names))
    (binding-name-symbol binding-stx))

  (define (validate-binding-sequence! who binding-stxs [initial-bound-names '()] [all-bound-names #f])
    (report-duplicate-binding-names! who binding-stxs)
    (define visible-names
      (and all-bound-names
           (append initial-bound-names all-bound-names)))
    (for/fold ([bound-names initial-bound-names])
              ([binding-stx (in-list binding-stxs)])
      (define available-names (or visible-names bound-names))
      (append bound-names
              (list (validate-binding-stx! who binding-stx available-names)))))

  (define (return-uses-qform? datum)
    (define normalized (normalize-gdp-return datum))
    (define (scan current)
      (cond
        [(and (list? current)
              (pair? current)
              (eq? (first current) '?))
         #t]
        [(and (list? current)
              (pair? current)
              (eq? (first current) 'Exists)
              (>= (length current) 3))
         (scan (last current))]
        [else #f]))
    (scan normalized))

  (define (validate-return-stx! who return-stx bound-names [allow-qform? #f])
    (define return-datum (syntax->datum return-stx))
    (report-unbound-names! who
                           return-stx
                           "return annotation"
                           (return-unbound-names return-datum
                                                 bound-names))
    (when (and (not allow-qform?) (return-uses-qform? return-datum))
      (raise-syntax-error who
                          "q-form return syntax `(? ...)` is not allowed here; use `(Type ::: proof)` and existential witness bindings instead"
                          return-stx)))

  (define body-bound-names-key 'tesl-body-bound-names)

  (define (annotate-body-scope stx bound-names)
    (if bound-names
        (syntax-property stx body-bound-names-key bound-names)
        stx))

  (define (body-bound-names stx)
    (syntax-property stx body-bound-names-key))

  (define (extend-bound-names bound-names new-names)
    (if bound-names
        (append bound-names new-names)
        new-names))

  (define (dotted-identifier-parts id-stx)
    (and (identifier? id-stx)
         (let ([value (syntax-e id-stx)])
           (and (symbol? value)
                (let ([parts (string-split (symbol->string value) ".")])
                  (and (> (length parts) 1)
                       (andmap (lambda (part)
                                 (not (string=? part "")))
                               parts)
                       (map string->symbol parts)))))))

  (define (expand-dotted-identifier id-stx bound-names)
    (define parts (dotted-identifier-parts id-stx))
    (define base-id (datum->syntax id-stx (car parts) id-stx))
    (for/fold ([expanded (transform-body-expr base-id bound-names)])
              ([part (in-list (cdr parts))])
      #`(tesl-dot/runtime #,expanded '#,part)))

  (define (wrap-runtime-named-binding name-id expr-stx body-stx)
    (define star-name-id (star-id name-id))
    (define value-id (format-id name-id "~a-runtime-value" (syntax-e name-id)))
    (define evidence-id (format-id name-id "~a-runtime-evidence" (syntax-e name-id)))
    (define binding-id (format-id name-id "~a-runtime-binding" (syntax-e name-id)))
    (define type-id (format-id name-id "~a-runtime-type" (syntax-e name-id)))
    #`(let* ([#,value-id #,expr-stx]
             [#,type-id (value-field-access-type #,value-id)])
        (if (check-fail? #,value-id)
            (handle-check-fail-in-let #,value-id)
            (let-values ([(#,evidence-id #,binding-id)
                          (runtime-bind+evidence '#,(syntax-e name-id) #,value-id)])
              (parameterize ([current-name-env
                              (extend-name-env (current-name-env)
                                               '(#,(syntax-e name-id))
                                               (list #,binding-id))]
                             [current-proof-env
                              (extend-proof-env (current-proof-env)
                                                (list #,binding-id))]
                             [current-evidence-env
                              (extend-evidence-env (current-evidence-env)
                                                   (list #,evidence-id))]
                             [current-type-env
                              (extend-type-env (current-type-env)
                                               (list #,binding-id)
                                               (list #,type-id))])
                (let ([#,star-name-id (runtime-binding-raw #,binding-id)]
                      [#,name-id (if (or (named-value? #,value-id)
                                         (check-result? #,value-id)
                                         (runtime-binding? #,value-id)
                                         (detached-proof? #,value-id)
                                         (packed-witness? #,value-id)
                                         (packed-exists? #,value-id)
                                         (procedure? #,value-id)
                                         (boolean? #,value-id))
                                     #,value-id
                                     (runtime-binding-name #,binding-id))])
                  #,body-stx))))))

  (define (wrap-runtime-named-bindings name-ids expr-stxs body-stx)
    (for/fold ([expanded body-stx])
              ([name-id (in-list (reverse name-ids))]
               [expr-stx (in-list (reverse expr-stxs))])
      (wrap-runtime-named-binding name-id expr-stx expanded)))

  (define (transform-body-expr expr-stx [bound-names #f])
    (define (annotate stx)
      (annotate-body-scope stx bound-names))
    (annotate
     (syntax-parse expr-stx
       #:datum-literals (begin begin0 if lambda let let* let-values quote quasiquote quote-syntax
                               accept attach-proof detach-proof trusted-proof
                               pack unpack let-exists let/check if/check
                               define/pow define-trusted define-checker define-auther define-handler)
       [id:id
        #:when (dotted-identifier-parts #'id)
        (expand-dotted-identifier #'id bound-names)]
       [(quote _datum) expr-stx]
       [(quasiquote _datum) expr-stx]
       [(quote-syntax _datum) expr-stx]
       [(begin form:expr ...+)
        (transform-body-sequence (syntax->list #'(form ...)) bound-names)]
       [(begin0 first-form:expr rest-form:expr ...+)
        #`(begin0 #,(transform-body-expr #'first-form bound-names)
                  #,@(for/list ([item (in-list (syntax->list #'(rest-form ...)))])
                       (transform-body-expr item bound-names)))]
       [(if test-expr:expr then-expr:expr else-expr:expr)
        #`(if #,(transform-body-expr #'test-expr bound-names)
              #,(transform-body-expr #'then-expr bound-names)
              #,(transform-body-expr #'else-expr bound-names))]
       [(accept _ ...+)
        expr-stx]
       [(trusted-proof _ ...+)
        expr-stx]
       [(detach-proof _ ...+)
        expr-stx]
       [(attach-proof _ ...+)
        expr-stx]
       [(pack _ ...+)
        expr-stx]
       [(unpack _ ...+)
        expr-stx]
       [(let-exists _ ...+)
        expr-stx]
       [(let/check _ ...+)
        expr-stx]
       [(if/check _ ...+)
        expr-stx]
       ; Tesl definition forms handle their own body transformation — return opaque
       [(define/pow _ ...+) expr-stx]
       [(define-trusted _ ...+) expr-stx]
       [(define-checker _ ...+) expr-stx]
       [(define-auther _ ...+) expr-stx]
       [(define-handler _ ...+) expr-stx]
       [(lambda (arg:id ...) body:expr ...+)
        (define arg-names (map syntax-e (syntax->list #'(arg ...))))
        #`(lambda (arg ...)
            #,(wrap-runtime-named-bindings
               (syntax->list #'(arg ...))
               (syntax->list #'(arg ...))
               (transform-body-sequence (syntax->list #'(body ...))
                                        (extend-bound-names bound-names arg-names))))]
       [(lambda rest:id body:expr ...+)
        #`(lambda rest
            #,(wrap-runtime-named-binding
               #'rest
               #'rest
               (transform-body-sequence (syntax->list #'(body ...))
                                        (extend-bound-names bound-names (list (syntax-e #'rest))))))]
       [(lambda (arg:id ... . rest:id) body:expr ...+)
        (define arg-ids (append (syntax->list #'(arg ...)) (list #'rest)))
        (define arg-names (map syntax-e arg-ids))
        #`(lambda (arg ... . rest)
            #,(wrap-runtime-named-bindings
               arg-ids
               arg-ids
               (transform-body-sequence (syntax->list #'(body ...))
                                        (extend-bound-names bound-names arg-names))))]
       [(let ([name:id rhs:expr] ...) body:expr ...+)
        (define name-ids (syntax->list #'(name ...)))
        (define name-symbols (map syntax-e name-ids))
        (define temp-ids
          (for/list ([name-id (in-list name-ids)])
            (datum->syntax name-id (gensym (syntax-e name-id)))))
        (define transformed-rhss
          (for/list ([rhs-stx (in-list (syntax->list #'(rhs ...)))])
            (transform-body-expr rhs-stx bound-names)))
        (define wrapped-body
          (wrap-runtime-named-bindings
           name-ids
           temp-ids
           (transform-body-sequence (syntax->list #'(body ...))
                                    (extend-bound-names bound-names name-symbols))))
        (with-syntax ([(temp-id ...) temp-ids]
                      [(rhs-expr ...) transformed-rhss]
                      [wrapped-body-expr wrapped-body])
          #'(let ([temp-id rhs-expr] ...)
              wrapped-body-expr))]
       [(let* () body:expr ...+)
        (transform-body-sequence (syntax->list #'(body ...)) bound-names)]
       [(let* ([name:id rhs:expr] more-binding ...) body:expr ...+)
        (define temp-id (datum->syntax #'name (gensym (syntax-e #'name))))
        (define transformed-rhs (transform-body-expr #'rhs bound-names))
        (define transformed-rest
          (transform-body-expr #'(let* (more-binding ...) body ...)
                               (extend-bound-names bound-names (list (syntax-e #'name)))))
        (with-syntax ([temp-id temp-id]
                      [rhs-expr transformed-rhs]
                      [wrapped-body-expr
                       (wrap-runtime-named-binding #'name temp-id transformed-rest)])
          #'(let ([temp-id rhs-expr])
              wrapped-body-expr))]
       [(let-values ([(name:id ...+) rhs:expr] ...) body:expr ...+)
        (define name-groups
          (for/list ([group-stx (in-list (syntax->list #'((name ...) ...)))])
            (syntax->list group-stx)))
        (define flat-name-ids (append* name-groups))
        (define flat-name-symbols (map syntax-e flat-name-ids))
        (define temp-groups
          (for/list ([group (in-list name-groups)])
            (for/list ([name-id (in-list group)])
              (datum->syntax name-id (gensym (syntax-e name-id))))))
        (define value-clauses
          (for/list ([temp-group (in-list temp-groups)]
                     [rhs-stx (in-list (syntax->list #'(rhs ...)))])
            #`[(#,@temp-group) #,(transform-body-expr rhs-stx bound-names)]))
        (define wrapped-body
          (wrap-runtime-named-bindings
           flat-name-ids
           (append* temp-groups)
           (transform-body-sequence (syntax->list #'(body ...))
                                    (extend-bound-names bound-names flat-name-symbols))))
        (with-syntax ([(value-clause ...) value-clauses]
                      [wrapped-body-expr wrapped-body])
          #'(let-values (value-clause ...)
              wrapped-body-expr))]
       [_
        (define parts (syntax->list expr-stx))
        (if parts
            #`(#,@(for/list ([part (in-list parts)])
                    (transform-body-expr part bound-names)))
            expr-stx)])))

  (define (transform-body-sequence body-stxs [bound-names #f])
    (cond
      [(null? body-stxs) (annotate-body-scope #'(void) bound-names)]
      [else
       (define first-form (car body-stxs))
       (define rest-forms (cdr body-stxs))
       (syntax-parse first-form
         #:datum-literals (define)
         [(define local-name:id local-expr:expr)
          (wrap-runtime-named-binding #'local-name
                                      (transform-body-expr #'local-expr bound-names)
                                      (transform-body-sequence rest-forms
                                                               (extend-bound-names bound-names
                                                                   (list (syntax-e #'local-name)))))]
         [_
          (define transformed-first (transform-body-expr first-form bound-names))
          (if (null? rest-forms)
              transformed-first
              #`(begin #,transformed-first #,(transform-body-sequence rest-forms bound-names)))])]))

  (define (binding-type-datum binding-stx)
    (define-values (_name-id type-stx _proof-stx) (binding-parts binding-stx))
    (normalize-type-stx type-stx))

  (define (binding-proof-datum binding-stx)
    (define-values (_name-id _type-stx proof-stx) (binding-parts binding-stx))
    (and proof-stx (syntax->datum proof-stx)))

  (define (binding->arg-spec-expr binding-stx)
    (define type-datum (normalize-gdp-expr (binding-type-datum binding-stx)))
    (define proof-datum (and (binding-proof-datum binding-stx)
                             (normalize-gdp-expr (binding-proof-datum binding-stx))))
    #`(arg-spec '#,(binding-name-symbol binding-stx)
                '#,type-datum
                '#,proof-datum
                '#,(syntax->datum binding-stx)))

  (define (build-executable-expansion kind whole-stx name-id binding-stxs cap-stxs returns-stx body-stxs)
    (define who
      (case kind
        [(handler) 'define-handler]
        [(pow) 'define/pow]
        [(trusted) 'define-trusted]
        [else 'dsl]))
    (define arg-name-ids (map binding-name-id binding-stxs))
    (define arg-name-symbols (map binding-name-symbol binding-stxs))
    (define final-bound-names (validate-binding-sequence! who binding-stxs '() arg-name-symbols))
    (validate-return-stx! who returns-stx final-bound-names #t)
    (define star-ids (map star-id arg-name-ids))
    (define arg-spec-exprs (map binding->arg-spec-expr binding-stxs))
    (define arg-proof-datums
      (for/list ([binding-stx (in-list binding-stxs)])
        (define proof-datum (and (binding-proof-datum binding-stx)
                                 (normalize-gdp-expr (binding-proof-datum binding-stx))))
        proof-datum))
    (define signature-id (format-id name-id "~a-signature" (syntax-e name-id)))
    (define kind-id (datum->syntax whole-stx kind))
    (define returns-datum (normalize-type-return-stx returns-stx))
    (define returns-expr #`'#,returns-datum)
    (define raw-expr #`'#,(syntax->datum whole-stx))
    (define transformed-body (transform-body-sequence body-stxs final-bound-names))
    (define trusted-body
      (case kind
        [(trusted)
         #`(syntax-parameterize ([trusted-proof (make-rename-transformer #'trusted-proof/trusted)])
             #,transformed-body)]
        [else transformed-body]))
    ; For fn (pow) and trusted functions, wrap the body so that check-fail values
    ; escaping through plain let bindings (wrap-runtime-named-binding) raise an
    ; error immediately.  Explicit let/check propagation is intentional and is
    ; NOT affected because let/check returns check-fail directly, bypassing
    ; handle-check-fail-in-let.
    (define scoped-body
      (if (eq? kind 'handler)
          trusted-body
          (let ([fn-name (syntax-e name-id)])
            #`(parameterize ([current-let-check-fail-behavior
                              (lambda (cf)
                                (raise-user-error '#,fn-name "~a (HTTP ~a)"
                                                  (check-fail-message cf)
                                                  (check-fail-status cf)))])
                #,trusted-body))))
    ;; ── Erased param-binding clauses ────────────────────────────────────────────
    ;; For each parameter, bind *arg to the raw value (zero allocation) and arg to:
    ;;   • the SAME raw value when the param carries no proof annotation, or
    ;;   • a single named-value via tesl-establish-param-proof when it does, so
    ;;     detachFact / proof decomposition on `arg` still resolve the fact (1 alloc).
    ;; The proof datum is already expressed in terms of the public param name (e.g.
    ;; (ValidPort port)); we use that public name as the GDP subject so the fact and
    ;; its self-binding are internally consistent.  No runtime-bind+evidence, no
    ;; validate-runtime-argument, no parameterize — the static checker is the sole
    ;; guarantor that the proof held.
    (define all-bindings-id
      (format-id name-id "~a-erased-all-arg-bindings" (syntax-e name-id)))
    ;; D12: the bindings table is read ONLY by clause (3)'s
    ;; tesl-establish-param-proof calls, so a fully proof-free function must
    ;; not pay its (hash …) allocation on every call (§2a of the erased-proof
    ;; design: proof-free params are zero-alloc, byte-identical to the
    ;; unannotated form).
    (define any-arg-proof? (for/or ([p (in-list arg-proof-datums)]) (and p #t)))
    (define erased-arg-clauses
      (append
       ;; (1) bind every *arg to its raw value (zero alloc)
       (for/list ([arg-id (in-list arg-name-ids)] [star-arg (in-list star-ids)])
         #`[#,star-arg (raw-value #,arg-id)])
       ;; (2) one cross-parameter bindings table (public-name → raw value), so a proof
       ;;     on one param that references a sibling param (e.g. HasKey key dict —
       ;;     consumed at runtime by a proof-total stdlib like Dict.get) can resolve all
       ;;     its subjects.  Mirrors the non-erased path's all-arg-bindings.
       ;;     Emitted only when some param actually carries a runtime proof (D12).
       (if any-arg-proof?
           (list #`[#,all-bindings-id
                    (hash #,@(append* (for/list ([arg-id (in-list arg-name-ids)]
                                                 [star-arg (in-list star-ids)])
                                        (list #`'#,(syntax-e arg-id) star-arg))))])
           '())
       ;; (3) bind each arg: proof-annotated → 1-alloc named-value carrying the fact
       ;;     AND the full cross-param bindings; proof-free → the raw value.
       (for/list ([arg-id (in-list arg-name-ids)]
                  [star-arg (in-list star-ids)]
                  [proof-datum (in-list arg-proof-datums)])
         (if proof-datum
             #`[#,arg-id (tesl-establish-param-proof '#,(syntax-e arg-id)
                                                     #,star-arg
                                                     '#,proof-datum
                                                     #,all-bindings-id)]
             #`[#,arg-id #,star-arg]))))
    (with-syntax ([(arg-id ...) arg-name-ids]
                  [(arg-spec-expr ...) arg-spec-exprs]
                  [(erased-arg-clause ...) erased-arg-clauses]
                  [signature-id signature-id]
                  [name name-id]
                  [(cap-id ...) cap-stxs]
                  [kind-id kind-id]
                  [returns-expr returns-expr]
                  [raw-expr raw-expr]
                  [body-expr scoped-body])
      #`(begin
          (define signature-id
            (signature-spec 'kind-id
                            'name
                            (list arg-spec-expr ...)
                            '(cap-id ...)
                            returns-expr
                            raw-expr))
          ;; ── ERASED expansion (zero-cost: the static checker is the sole
          ;; guarantor of the declared proofs) ───────────────────────────────
          (define (name arg-id ...)
            (call-with-declared-capabilities
             (list cap-id ...)
             (lambda ()
               (let* (erased-arg-clause ...)
                 (let ([result body-expr])
                   (validate-signature-return signature-id result))))))
          ;; Issue #30: expose the declared capability VALUES on the procedure
          ;; so a deferred-execution boundary (agent tool dispatch, serverTools)
          ;; can delegate the statically-charged authority at execution time.
          #,@(if (null? cap-stxs)
                 '()
                 (list #'(register-procedure-capabilities! name (list cap-id ...)))))))

  (define (parse-auth-piece piece-stx outer-bound-names)
    (define parts (syntax->list piece-stx))
    (unless (and parts
                 (= (length parts) 4)
                 (literal-id? (first parts) 'Auth)
                 (equal? (syntax-e (third parts)) '#:via))
      (raise-syntax-error 'define-api "Auth must look like (Auth [user : Type ::: Proof] #:via auther)" piece-stx))
    (define binding-stx (second parts))
    (define binder-name (validate-binding-stx! 'define-api binding-stx outer-bound-names))
    (define via-stx (fourth parts))
    (define type-datum (normalize-gdp-expr (binding-type-datum binding-stx)))
    (define proof-datum (and (binding-proof-datum binding-stx)
                             (normalize-gdp-expr (binding-proof-datum binding-stx))))
    (values
     #`(auth-spec '#,(binding-name-symbol binding-stx)
                  '#,type-datum
                  '#,proof-datum
                  #,via-stx
                  '#,(syntax->datum piece-stx))
     binder-name))

  (define (parse-capture-piece piece-stx outer-bound-names)
    (define parts (syntax->list piece-stx))
    (unless (and parts
                 (pair? parts)
                 (literal-id? (first parts) 'Capture))
      (raise-syntax-error 'define-api
                          "Capture must look like either (Capture [x : Type ::: Proof] #:parser parser [#:check checker]) or (Capture capture-kind [x : Type ::: Proof])"
                          piece-stx))
    (define-values (binding-stx parser-stx checker-stx)
      (cond
        [(and (= (length parts) 3)
              (identifier? (second parts)))
         (define kind-id (second parts))
         (define binding-stx (third parts))
         (define kind-info (capture-kind-ref 'define-api kind-id))
         (define expected-binding-stx (capture-kind-info-binding kind-info))
         (unless (capture-kind-binding-compatible? expected-binding-stx binding-stx)
           (raise-syntax-error 'define-api
                               (format "capture kind ~a expects a binding compatible with ~a" (syntax-e kind-id) (syntax->datum expected-binding-stx))
                               piece-stx
                               binding-stx))
         (values binding-stx
                 (capture-kind-info-parser kind-info)
                 (capture-kind-info-checker kind-info))]
        [(and (or (= (length parts) 4) (= (length parts) 6))
              (equal? (syntax-e (third parts)) '#:parser))
         (define binding-stx (second parts))
         (define parser-stx (fourth parts))
         (define checker-stx
           (cond
             [(= (length parts) 4) #'#f]
             [(equal? (syntax-e (fifth parts)) '#:check) (sixth parts)]
             [else
              (raise-syntax-error 'define-api "expected #:check after the capture parser" piece-stx (fifth parts))]))
         (values binding-stx parser-stx checker-stx)]
        [else
         (raise-syntax-error 'define-api
                             "Capture must look like either (Capture [x : Type ::: Proof] #:parser parser [#:check checker]) or (Capture capture-kind [x : Type ::: Proof])"
                             piece-stx)]))
    (define binder-name (validate-binding-stx! 'define-api binding-stx outer-bound-names))
    (define type-datum (normalize-gdp-expr (binding-type-datum binding-stx)))
    (define proof-datum (and (binding-proof-datum binding-stx)
                             (normalize-gdp-expr (binding-proof-datum binding-stx))))
    (values
     #`(capture-spec '#,(binding-name-symbol binding-stx)
                     '#,type-datum
                     '#,proof-datum
                     #,parser-stx
                     #,checker-stx
                     '#,(syntax->datum piece-stx))
     binder-name))

  (define (parse-payload-piece piece-stx outer-bound-names)
    (define parts (syntax->list piece-stx))
    (unless (and parts (>= (length parts) 3) (literal-id? (first parts) 'ReqBody))
      (raise-syntax-error 'define-api "ReqBody must start with (ReqBody Format [name : Type])" piece-stx))
    (define format-stx (second parts))
    (define binding-stx (third parts))
    (define binder-name (validate-binding-stx! 'define-api binding-stx outer-bound-names))
    (define wire-type-stx #f)
    (define decoder-stx #f)
    (define checker-stx #'#f)
    (let loop ([remaining (drop parts 3)])
      (unless (null? remaining)
        (unless (>= (length remaining) 2)
          (raise-syntax-error 'define-api "ReqBody keywords must be followed by values" piece-stx))
        (define keyword-stx (first remaining))
        (define value-stx (second remaining))
        (cond
          [(equal? (syntax-e keyword-stx) '#:wire)
           (set! wire-type-stx value-stx)]
          [(equal? (syntax-e keyword-stx) '#:decoder)
           (set! decoder-stx value-stx)]
          [(equal? (syntax-e keyword-stx) '#:check)
           (set! checker-stx value-stx)]
          [else
           (raise-syntax-error 'define-api "unsupported ReqBody keyword" piece-stx keyword-stx)])
        (loop (drop remaining 2))))
    (define type-datum (normalize-gdp-expr (binding-type-datum binding-stx)))
    (define proof-datum (and (binding-proof-datum binding-stx)
                             (normalize-gdp-expr (binding-proof-datum binding-stx))))
    (define wire-type-datum
      (and wire-type-stx
           (normalize-gdp-expr (syntax->datum wire-type-stx))))
    (define effective-decoder-stx
      (cond
        [wire-type-stx
         (or decoder-stx #'identity)]
        [decoder-stx decoder-stx]
        [else
         #`(lambda (payload)
             (jsexpr->typed-value/result '#,type-datum payload 'ReqBody))]))
    (values
     #`(payload-spec '#,(binding-name-symbol binding-stx)
                     '#,type-datum
                     '#,proof-datum
                     '#,(syntax-e format-stx)
                     '#,wire-type-datum
                     #,effective-decoder-stx
                     #,checker-stx
                     '#,(syntax->datum piece-stx))
     binder-name))

  (define (parse-response-piece piece-stx)
    (define parts (syntax->list piece-stx))
    (unless (and parts (>= (length parts) 3) (literal-id? (first parts) 'Response) (identifier? (second parts)))
      (raise-syntax-error 'define-api "Response must look like (Response JSON WireType [#:encoder encoder]) or (Response JSON #:encoder encoder)" piece-stx))
    (define format-id (second parts))
    ;; Support (Response JSON #:encoder encoder) — encoder-only, no wire type
    (cond
      [(and (= (length parts) 4)
            (equal? (syntax-e (third parts)) '#:encoder))
       (values (syntax-e format-id) #f (fourth parts))]
      [else
       (define wire-type-stx (third parts))
       (define encoder-stx
         (cond
           [(= (length parts) 3) #'identity]
           [(equal? (syntax-e (fourth parts)) '#:encoder) (fifth parts)]
           [else
            (raise-syntax-error 'define-api "expected #:encoder after the response wire type" piece-stx (fourth parts))]))
       (values (syntax-e format-id)
               (normalize-type-stx wire-type-stx)
               encoder-stx)]))

  (define (parse-method-piece piece-stx)
    (define parts (syntax->list piece-stx))
    (unless (and parts (= (length parts) 3) (identifier? (first parts)) (identifier? (second parts)))
      (raise-syntax-error 'define-api "terminal API combinator must look like (Get JSON ReturnType)" piece-stx))
    (define method-id (first parts))
    (define format-id (second parts))
    (define return-stx (third parts))
    (define method-sym
      (case (syntax-e method-id)
        [(Get) 'GET]
        [(Post) 'POST]
        [(Put) 'PUT]
        [(Delete) 'DELETE]
        [(Patch) 'PATCH]
        [else
         (raise-syntax-error 'define-api "unsupported terminal method" piece-stx method-id)]))
    (values method-sym (syntax-e format-id) return-stx))

  (define (parse-endpoint endpoint-stx)
    (define parts (syntax->list endpoint-stx))
    (unless (and parts (>= (length parts) 3))
      (raise-syntax-error 'define-api "endpoint declaration is too short" endpoint-stx))
    (define name-id (first parts))
    (unless (literal-id? (second parts) ':)
      (raise-syntax-error 'define-api "endpoint declaration must start with `[name : ...]`" endpoint-stx))
    (define rest (drop parts 2))
    (define auth-expr #'#f)
    (define have-auth? #f)
    (define segments '())
    (define response-format-sym #f)
    (define response-wire-type-datum #f)
    (define response-encoder-expr #'#f)
    (define have-response? #f)
    (define bound-names '())
    (let loop ([remaining rest])
      (when (null? remaining)
        (raise-syntax-error 'define-api "endpoint declaration is missing a terminal method" endpoint-stx))
      (define piece (car remaining))
      (define tail (cdr remaining))
      (cond
        [(null? tail)
         (define-values (method-sym format-sym returns-stx) (parse-method-piece piece))
         (validate-return-stx! 'define-api returns-stx bound-names #t)
         (define returns-datum (normalize-type-return-stx returns-stx))
         (when (and have-response? (not (eq? response-format-sym format-sym)))
           (raise-syntax-error 'define-api
                               (format "Response format ~a does not match terminal method format ~a" response-format-sym format-sym)
                               endpoint-stx
                               piece))
         #`(api-endpoint-spec '#,(syntax-e name-id)
                              #,auth-expr
                              (list #,@(reverse segments))
                              '#,method-sym
                              '#,format-sym
                              '#,returns-datum
                              '#,response-wire-type-datum
                              #,response-encoder-expr
                              '#,(syntax->datum endpoint-stx))]
        [else
         (unless (literal-id? (car tail) ':>)
           (raise-syntax-error 'define-api "expected `:>` between API combinators" endpoint-stx (car tail)))
         (cond
           [(and (pair? (syntax->list piece))
                 (literal-id? (car (syntax->list piece)) 'Auth))
            (when have-auth?
              (raise-syntax-error 'define-api "only one Auth combinator is currently supported per endpoint" endpoint-stx piece))
            (define-values (parsed-auth binder-name)
              (parse-auth-piece piece bound-names))
            (set! auth-expr parsed-auth)
            (set! bound-names (append bound-names (list binder-name)))
            (set! have-auth? #t)]
           [(and (pair? (syntax->list piece))
                 (literal-id? (car (syntax->list piece)) 'Capture))
            (define-values (parsed-capture binder-name)
              (parse-capture-piece piece bound-names))
            (set! segments (cons parsed-capture segments))
            (set! bound-names (append bound-names (list binder-name)))]
           [(and (pair? (syntax->list piece))
                 (literal-id? (car (syntax->list piece)) 'ReqBody))
            (define-values (parsed-payload binder-name)
              (parse-payload-piece piece bound-names))
            (set! segments (cons parsed-payload segments))
            (set! bound-names (append bound-names (list binder-name)))]
           [(and (pair? (syntax->list piece))
                 (literal-id? (car (syntax->list piece)) 'Response))
            (when have-response?
              (raise-syntax-error 'define-api "only one Response combinator is currently supported per endpoint" endpoint-stx piece))
            (define-values (parsed-format-sym parsed-wire-type parsed-encoder)
              (parse-response-piece piece))
            (set! response-format-sym parsed-format-sym)
            (set! response-wire-type-datum parsed-wire-type)
            (set! response-encoder-expr parsed-encoder)
            (set! have-response? #t)]
           [(string? (syntax-e piece))
            (set! segments (cons piece segments))]
           [else
            (raise-syntax-error 'define-api "unsupported API combinator" endpoint-stx piece)])
         (loop (cdr tail))]))))

(define-syntax (define-handler stx)
  (syntax-parse stx
    [(_ (name:id arg:typed-binding ...) #:capabilities [cap:id ...] #:returns ret:expr body:expr ...+)
     (build-executable-expansion 'handler
                                 stx
                                 #'name
                                 (syntax->list #'(arg ...))
                                 (syntax->list #'(cap ...))
                                 #'ret
                                 (syntax->list #'(body ...)))]
    [(_ (name:id arg:typed-binding ...) #:returns ret:expr body:expr ...+)
     (build-executable-expansion 'handler
                                 stx
                                 #'name
                                 (syntax->list #'(arg ...))
                                 '()
                                 #'ret
                                 (syntax->list #'(body ...)))]))

(define-syntax (define/pow stx)
  (syntax-parse stx
    [(_ (name:id arg:typed-binding ...) #:capabilities [cap:id ...] #:returns ret:expr body:expr ...+)
     (build-executable-expansion 'pow
                                 stx
                                 #'name
                                 (syntax->list #'(arg ...))
                                 (syntax->list #'(cap ...))
                                 #'ret
                                 (syntax->list #'(body ...)))]
    [(_ (name:id arg:typed-binding ...) #:returns ret:expr body:expr ...+)
     (build-executable-expansion 'pow
                                 stx
                                 #'name
                                 (syntax->list #'(arg ...))
                                 '()
                                 #'ret
                                 (syntax->list #'(body ...)))]))

(define-syntax (define-trusted stx)
  (syntax-parse stx
    [(_ (name:id arg:typed-binding ...) #:capabilities [cap:id ...] #:returns ret:expr body:expr ...+)
     (build-executable-expansion 'trusted
                                 stx
                                 #'name
                                 (syntax->list #'(arg ...))
                                 (syntax->list #'(cap ...))
                                 #'ret
                                 (syntax->list #'(body ...)))]
    [(_ (name:id arg:typed-binding ...) #:returns ret:expr body:expr ...+)
     (build-executable-expansion 'trusted
                                 stx
                                 #'name
                                 (syntax->list #'(arg ...))
                                 '()
                                 #'ret
                                 (syntax->list #'(body ...)))]))

(define-syntax (define-capture stx)
  (syntax-parse stx
    [(_ name:id binding:typed-binding #:parser parser:expr #:check checker:expr)
     (validate-binding-stx! 'define-capture #'binding '())
     (define raw-datum (syntax->datum stx))
     #`(define-syntax name
         (capture-kind-info #'binding #'parser #'checker '#,raw-datum))]
    [(_ name:id binding:typed-binding #:parser parser:expr)
     (validate-binding-stx! 'define-capture #'binding '())
     (define raw-datum (syntax->datum stx))
     #`(define-syntax name
         (capture-kind-info #'binding #'parser #'#f '#,raw-datum))]))

;; CONC-1: resolve a capturer into a runtime channel-key validator.  An `sse`
;; endpoint that declares `capture key: T ::: P key via someCapturer` previously
;; had that capture SILENTLY DROPPED at codegen (the SSE route carried only
;; prefix/auth/channel), so any authenticated user could subscribe to ANY key —
;; an IDOR/BOLA gap.  The emitter now puts `(sse-key-capture someCapturer)` in
;; the SSE route; this macro mirrors the HTTP `Capture` path — it reads the
;; capturer's parser + checker (compile-time `capture-kind-info`) and expands to
;; a closure that parses the raw key segment and runs the checker, returning a
;; `check-fail` on rejection (which `handle-sse-request` raises → the check's
;; HTTP status) or the validated value on success.
(define-syntax (sse-key-capture stx)
  (syntax-parse stx
    [(_ cap:id)
     (define kind-info (capture-kind-ref 'sse-key-capture #'cap))
     (define keyname-sym (binding-name-symbol (capture-kind-info-binding kind-info)))
     (with-syntax ([parser  (capture-kind-info-parser kind-info)]
                   [checker (capture-kind-info-checker kind-info)])
       #`(lambda (key-str)
           (apply-checker-to-value '#,keyname-sym (parser key-str) checker)))]))

(define-syntax (define-api stx)
  (syntax-parse stx
    [(_ api-name:id endpoint:expr ...+)
     (with-syntax ([(endpoint-expr ...)
                    (for/list ([ep (in-list (syntax->list #'(endpoint ...)))])
                      (parse-endpoint ep))])
       #'(define api-name
           (api-spec 'api-name
                     (list endpoint-expr ...)
                     '#,(syntax->datum stx))))]))

(define (binding-datum name type proof)
  (if proof
      (list name ': type '::: proof)
      (list name ': type)))

(define (signature-arg-bindings signature)
  (for/list ([arg (in-list (signature-spec-args signature))])
    (binding-datum (arg-spec-name arg)
                   (arg-spec-type arg)
                   (arg-spec-proof arg))))

(define (endpoint-arg-bindings endpoint)
  (append
   (if (api-endpoint-spec-auth endpoint)
       (list (binding-datum (auth-spec-binder (api-endpoint-spec-auth endpoint))
                            (auth-spec-type (api-endpoint-spec-auth endpoint))
                            (auth-spec-proof (api-endpoint-spec-auth endpoint))))
       '())
   (for/list ([segment (in-list (api-endpoint-spec-segments endpoint))]
              #:when (or (capture-spec? segment)
                         (payload-spec? segment)))
     (cond
       [(capture-spec? segment)
        (binding-datum (capture-spec-name segment)
                       (capture-spec-type segment)
                       (capture-spec-proof segment))]
       [else
        (binding-datum (payload-spec-name segment)
                       (payload-spec-type segment)
                       (payload-spec-proof segment))]))))

(define (canonicalize-binding-list bindings)
  (for/fold ([acc '()]
             [env (hash)]
             [next-index 0])
            ([binding (in-list bindings)])
    (define-values (canonical-binding next-env next-item-index)
      (canonicalize-gdp-binding binding env next-index))
    (values (append acc (list canonical-binding))
            next-env
            next-item-index)))

(define (canonicalize-shape bindings returns)
  (define-values (canonical-bindings env next-index)
    (canonicalize-binding-list bindings))
  (define-values (canonical-returns _next-index)
    (canonicalize-gdp-return returns env next-index))
  (values canonical-bindings canonical-returns))

(define (ensure-handler-signature-matches-endpoint endpoint signature)
  (unless (signature-spec? signature)
    (raise-user-error 'define-server
                      (format "handler for endpoint ~a is missing a DSL signature"
                              (api-endpoint-spec-name endpoint))))
  (unless (memq (signature-spec-kind signature) '(handler pow))
    (raise-user-error 'define-server
                      (format "binding for endpoint ~a must use a handler-like DSL function, got ~a"
                              (api-endpoint-spec-name endpoint)
                              (signature-spec-kind signature))))
  (define expected-bindings (endpoint-arg-bindings endpoint))
  (define actual-bindings (signature-arg-bindings signature))
  (define-values (canonical-expected-bindings canonical-expected-returns)
    (canonicalize-shape expected-bindings (api-endpoint-spec-returns endpoint)))
  (define-values (canonical-actual-bindings canonical-actual-returns)
    (canonicalize-shape actual-bindings (signature-spec-returns signature)))
  (unless (equal? canonical-expected-bindings canonical-actual-bindings)
    (raise-user-error 'define-server
                      (format "handler ~a does not match endpoint ~a argument types/proofs; expected ~a but got ~a"
                              (signature-spec-name signature)
                              (api-endpoint-spec-name endpoint)
                              expected-bindings
                              actual-bindings)))
  (unless (equal? canonical-expected-returns canonical-actual-returns)
    (raise-user-error 'define-server
                      (format "handler ~a does not match endpoint ~a return type; expected ~a but got ~a"
                              (signature-spec-name signature)
                              (api-endpoint-spec-name endpoint)
                              (api-endpoint-spec-returns endpoint)
                              (signature-spec-returns signature)))))

(define-syntax (define-server stx)
  (syntax-parse stx
    [(_ server-name:id #:api api:expr [endpoint:id handler:id] ...+)
     (with-syntax ([(handler-signature ...)
                    (for/list ([handler-id (in-list (syntax->list #'(handler ...)))])
                      (format-id handler-id "~a-signature" (syntax-e handler-id)))])
       #'(define server-name
           (build-server-spec 'server-name
                              api
                              (list (list 'endpoint handler handler-signature) ...)
                              '#,(syntax->datum stx))))]))

(define (build-server-spec name api binding-list raw)
  (unless (api-spec? api)
    (raise-user-error 'define-server "expected an api-spec, got ~a" api))
  (define endpoint-table
    (for/hash ([endpoint (in-list (api-spec-endpoints api))])
      (values (api-endpoint-spec-name endpoint) endpoint)))
  (define binding-table (make-hash))
  (define signature-table (make-hash))
  (for ([entry (in-list binding-list)])
    (define key (first entry))
    (define handler (second entry))
    (define signature (third entry))
    (when (hash-has-key? binding-table key)
      (raise-user-error 'define-server (format "duplicate server binding for endpoint ~a" key)))
    (unless (hash-has-key? endpoint-table key)
      (raise-user-error 'define-server (format "endpoint ~a is not declared in API ~a" key (api-spec-name api))))
    (hash-set! binding-table key handler)
    (hash-set! signature-table key signature))
  (for ([endpoint (in-list (api-spec-endpoints api))])
    (unless (hash-has-key? binding-table (api-endpoint-spec-name endpoint))
      (raise-user-error 'define-server
                        (format "missing handler binding for endpoint ~a" (api-endpoint-spec-name endpoint)))))
  (define routes
    (for/list ([endpoint (in-list (api-spec-endpoints api))])
      (define handler (hash-ref binding-table (api-endpoint-spec-name endpoint)))
      (define signature (hash-ref signature-table (api-endpoint-spec-name endpoint)))
      (define expected-arity (endpoint-argument-count endpoint))
      (unless (procedure-arity-includes? handler expected-arity)
        (raise-user-error 'define-server
                          (format "handler for endpoint ~a does not accept ~a arguments"
                                  (api-endpoint-spec-name endpoint)
                                  expected-arity)))
      (ensure-handler-signature-matches-endpoint endpoint signature)
      (route-spec (api-endpoint-spec-name endpoint)
                  (api-endpoint-spec-method endpoint)
                  (api-endpoint-spec-format endpoint)
                  (api-endpoint-spec-auth endpoint)
                  (api-endpoint-spec-segments endpoint)
                  handler
                  (api-endpoint-spec-returns endpoint)
                  (api-endpoint-spec-response-wire-type endpoint)
                  (api-endpoint-spec-response-encoder endpoint))))
  (server-spec name api (hash-copy binding-table) routes raw))

(define (normalize-method method)
  (string-upcase
   (cond
     [(symbol? method) (symbol->string method)]
     [else method])))

(define (normalize-headers headers)
  (for/hash ([(key value) (in-hash headers)])
    (values
     (string-downcase
      (cond
        [(symbol? key) (symbol->string key)]
        [else key]))
     (cond
       [(bytes? value) (bytes->string/utf-8 value)]
       [else value]))))

(define (make-request method path #:headers [headers (hash)] #:body [body #""] #:query [query ""])
  (define normalized-headers (normalize-headers headers))
  (dsl-request (normalize-method method)
               (map ~a path)
               normalized-headers
               body
               (parse-cookies-header (hash-ref normalized-headers "cookie" #f))
               (parse-query-string query)
               #f))

(define (request-header req key [default #f])
  (hash-ref (dsl-request-headers req)
            (string-downcase
             (cond
               [(symbol? key) (symbol->string key)]
               [else key]))
            default))

(define (integer-segment segment)
  (define maybe-number (string->number segment))
  (if (and maybe-number (integer? maybe-number))
      maybe-number
      (check-fail (format "Expected an integer path segment, got ~a" segment) 400 '())))

;; Int32 path segment: an integer that also fits [-2^31, 2^31). Out-of-range is a
;; 400 (fail-closed) rather than a silently-wrapped value — same boundary as the
;; int32Codec JSON decoder (dsl/types.rkt).
(define (int32-segment segment)
  (define maybe-number (string->number segment))
  (cond
    [(not (and maybe-number (exact-integer? maybe-number)))
     (check-fail (format "Expected an integer path segment, got ~a" segment) 400 '())]
    [(not (and (>= maybe-number (- (expt 2 31))) (<= maybe-number (sub1 (expt 2 31)))))
     (check-fail (format "Expected an Int32 path segment (in [-2^31, 2^31)), got ~a" segment) 400 '())]
    [else maybe-number]))

(define (string-segment segment)
  segment)

;; Session cookies attach to 2xx responses ONLY.  `error-response` funnels every
;; 4xx/5xx through here too, so the status test below is what makes "a handler
;; that sets a cookie and then `fail`s mints no session" true — and it is true by
;; construction, at the single point where every `dsl-response` is built, rather
;; than by remembering to clear the accumulator on each error path.
(define (json-response body #:status [status 200] #:headers [headers '()])
  (define cookie-headers
    (if (and (>= status 200) (< status 300)) (response-cookie-headers) '()))
  (dsl-response status (append headers cookie-headers) (prepare-json body)))

(define (error-response status message #:details [details '()])
  (json-response (hash 'ok #f
                       'error message
                       'details details)
                 #:status status))

(define no-match (gensym 'no-match))

(define (request->dsl-request req)
  (define method (bytes->string/utf-8 (request-method req)))
  (define path
    (for/list ([part (in-list (url-path (request-uri req)))]
               #:when (string? (path/param-path part)))
      (path/param-path part)))
  (define headers
    (for/hash ([h (in-list (request-headers/raw req))])
      (values (string-downcase (bytes->string/utf-8 (header-field h)))
              (bytes->string/utf-8 (header-value h)))))
  (dsl-request (normalize-method method)
               path
               headers
               (or (request-post-data/raw req) #"")
               (parse-cookies-header (hash-ref headers "cookie" #f))
               (query-alist->hash (url-query (request-uri req)))
               req))

(define (instantiate-binder-proof binder bound proof-datum)
  (define instantiated
    (parameterize ([current-name-env (hash binder (named-value-name bound))])
      (instantiate-proof-template proof-datum)))
  (detached-proof instantiated
                  (restrict-bindings-to-fact (named-value-bindings bound) instantiated)))

(define (prepare-response-value value)
  (cond
    [(packed-exists? value) (prepare-response-value (packed-exists-body value))]
    [(check-ok? value) (prepare-response-value (check-ok-value value))]
    [(named-value? value) (prepare-response-value (named-value-value value))]
    [else value]))

(define (prepare-json value)
  (cond
    [(packed-exists? value) (prepare-json (packed-exists-body value))]
    [(check-ok? value) (prepare-json (check-ok-value value))]
    [(named-value? value) (prepare-json (named-value-value value))]
    [else (runtime-value->jsexpr value)]))

(define (dsl-response->http-response response)
  (response/full
   (dsl-response-status response)
   #f
   (current-seconds)
   APPLICATION/JSON-MIME-TYPE
   (append
    (list (make-header #"X-Content-Type-Options" #"nosniff")
          (make-header #"Cache-Control" #"no-store"))
    (dsl-response-headers response))
   (list (jsexpr->bytes (prepare-json (dsl-response-body response))))))

;; ── Phase -2 (roadmap/next/ensure_sso_works.md): server-wide response security
;; headers.  The tree emitted only `X-Content-Type-Options: nosniff`, and the
;; two response paths that serve the app's OWN HTML -- the static-file responder
;; and the SPA fallback -- passed `'()` headers, so a page load carried none.
;; `harden-servlet` (below) applies this set to EVERY response.
;;
;;   * Referrer-Policy: no-referrer   -- on every response; a session-bearing
;;     page (and the SSO callback's `code`) leaks onward without it.
;;   * X-Frame-Options: DENY          -- clickjacking floor.
;;   * X-Content-Type-Options: nosniff-- kept.
;;   * Strict-Transport-Security      -- ONLY when the configured public origin
;;     is https, NEVER derived from the request (which is untrusted and absent
;;     behind a proxy, Risk 44); max-age one year, no includeSubDomains and no
;;     preload by default (both near-irreversible, and Tesl cannot see the
;;     subdomain topology).  Suppressed for a loopback dev origin.
;;
;; The public origin's runtime source is `TESL_PUBLIC_ORIGIN` until the
;; `publicOrigin` server clause lands (compiler surface, Stage 2), at which point
;; the clause feeds this same value, compile-time validated.
;;
;; A Content-Security-Policy is added to responses Tesl serves as HTML (the SPA
;; fallback and static HTML), because the app cannot set a CSP on HTML the
;; runtime serves (Risk 45).  The DEFAULT is `frame-ancestors 'none'` -- a real
;; but non-breaking reduction (it constrains framing, not script/style sources,
;; so it cannot break an SPA); a full policy is opt-in via `TESL_CSP`, and the
;; final default value is Open Question 17, settled when the config surface
;; lands.  JSON responses get no CSP (meaningless for a non-document).
;; Phase 3: the `publicOrigin` server clause sets this parameter at boot; it
;; takes precedence over the TESL_PUBLIC_ORIGIN env var.  Either way the value is
;; the configured public origin — NEVER derived from a request (Risk 44).
(define current-public-origin (make-parameter #f))
(define (public-origin-value)
  (define (clean v)
    (and (string? v) (let ([t (string-trim v)]) (and (not (string=? t "")) t))))
  (or (clean (current-public-origin))
      (clean (getenv "TESL_PUBLIC_ORIGIN"))))

;; OQ11: the runtime rule for a public origin, mirroring the compiler's
;; `valid_public_origin` (validation_structural.ml) so the inline literal and
;; the `fromEnv` env read are validated identically: an absolute origin, scheme
;; `https` (or `http` only for a loopback host), with no path beyond an optional
;; trailing `/`, no query and no fragment.
(define (valid-public-origin? s)
  (and (string? s)
       (not (regexp-match? #rx"[?#]" s))
       (let ()
         (define (host+rest-ok? rest)
           (define slash
             (for/first ([c (in-string rest)] [i (in-naturals)] #:when (char=? c #\/)) i))
           (cond [(not slash) (> (string-length rest) 0)]
                 [else (and (> slash 0) (string=? (substring rest slash) "/"))]))
         (cond
           [(regexp-match? #rx"^https://" s) (host+rest-ok? (substring s 8))]
           [(regexp-match? #rx"^http://" s)
            (define rest (substring s 7))
            (define slash
              (for/first ([c (in-string rest)] [i (in-naturals)] #:when (char=? c #\/)) i))
            (define host (if slash (substring rest 0 slash) rest))
            (define host-noport (car (string-split (string-downcase host) ":")))
            (define loopback?
              (or (string=? host-noport "localhost")
                  (string=? host-noport "::1")
                  (regexp-match? #rx"^127[.]" host-noport)))
            (and loopback? (host+rest-ok? rest))]
           [else #f]))))

;; OQ11: read the public origin from an env var ONCE at boot, validate it with
;; the shared rule, and error fast (fail-closed) if it is missing or invalid.
;; Only the `publicOrigin fromEnv` clause calls this — NEVER a request path.
(define (public-origin-from-env var)
  (define raw (getenv var))
  (define v (and (string? raw) (let ([t (string-trim raw)]) (and (not (string=? t "")) t))))
  (unless v
    (error 'publicOrigin (format "environment variable ~a is not set" var)))
  (unless (valid-public-origin? v)
    (error 'publicOrigin
           (format "environment variable ~a = ~s is not an absolute https origin with no path/query/fragment" var v)))
  v)

;; Risk 50/60: the ONE health-probe path exempt from Host validation (a load
;; balancer probes without the app's Host).  #f = no exemption; set by the
;; `healthProbePath` server clause at boot.
(define current-health-probe-path (make-parameter #f))

;; The bare host of an origin or a `Host` header value: drop scheme://, path,
;; and :port (keeping a bracketed IPv6 literal), lower-cased.  Used only for
;; the Host-vs-publicOrigin domain comparison.
(define (host-of s0)
  (define s (regexp-replace #rx"^[a-zA-Z][a-zA-Z0-9+.-]*://" (or s0 "") ""))
  (define no-path (car (regexp-split #rx"/" s)))
  (define host
    (cond
      [(regexp-match #rx"^(\\[[^]]*\\])" no-path) => cadr]  ; [IPv6]
      [else (car (regexp-split #rx":" no-path))]))
  (string-downcase host))

(define (origin-loopback? origin)
  ;; host of scheme://host[:port]/... — loopback ⇒ suppress HSTS.  The host may
  ;; be a bracketed IPv6 literal (`[::1]`), so capture that shape too.
  (define m (regexp-match #px"^[a-zA-Z][a-zA-Z0-9+.-]*://(\\[[^]]+\\]|[^/:]+)" origin))
  (and m
       (let ([host (string-downcase (regexp-replace* #rx"[][]" (cadr m) ""))])
         (or (string=? host "localhost")
             (string=? host "::1")
             (regexp-match? #rx"^127[.][0-9.]+$" host)))))

(define (hsts-header-value)
  (define o (public-origin-value))
  (and o
       (regexp-match? #rx"^https://" (string-downcase o))
       (not (origin-loopback? o))
       #"max-age=31536000"))

;; OQ17 (#50.1): the CSP for HTML responses.  Precedence: the program's
;; `contentSecurityPolicy` server clause (typed, visible to a reviewer) >
;; the TESL_CSP env override > the safe non-breaking default
;; `frame-ancestors 'none'` (it constrains framing, not script/style sources,
;; so it cannot break an SPA).  A handler may still override PER RESPONSE by
;; setting its own Content-Security-Policy header (add-security-headers keeps
;; a producer-set value) — that is the per-route form.
(define current-content-security-policy (make-parameter #f))
(define (html-csp-value)
  (define clause (current-content-security-policy))
  (define env (getenv "TESL_CSP"))
  (cond
    [(and (string? clause) (not (string=? (string-trim clause) "")))
     (string->bytes/utf-8 (string-trim clause))]
    [(and env (not (string=? (string-trim env) ""))) (string->bytes/utf-8 (string-trim env))]
    [else #"frame-ancestors 'none'"]))

(define (security-response-headers html?)
  (append
   (list (make-header #"X-Content-Type-Options" #"nosniff")
         (make-header #"Referrer-Policy" #"no-referrer")
         (make-header #"X-Frame-Options" #"DENY"))
   (let ([hsts (hsts-header-value)])
     (if hsts (list (make-header #"Strict-Transport-Security" hsts)) '()))
   (if html?
       (list (make-header #"Content-Security-Policy" (html-csp-value)))
       '())))

;; Add the security header set to a response, without overriding any header the
;; producer already set (so a handler that chose its own Referrer-Policy or CSP
;; wins).  Non-response values pass through untouched.
(define (add-security-headers resp)
  (cond
    [(response? resp)
     (define existing
       (map (lambda (h) (string-downcase (bytes->string/utf-8 (header-field h))))
            (response-headers resp)))
     (define html?
       (let ([m (response-mime resp)])
         (and m (regexp-match? #rx"(?i:text/html)" (bytes->string/utf-8 m)))))
     (define to-add
       (for/list ([h (in-list (security-response-headers html?))]
                  #:unless (member (string-downcase (bytes->string/utf-8 (header-field h)))
                                   existing))
         h))
     (if (null? to-add)
         resp
         (struct-copy response resp
                      [headers (append to-add (response-headers resp))]))]
    [else resp]))

;; Wrap a servlet handler so every response it returns carries the security
;; header set -- including the static-file and SPA-fallback paths that build
;; their responses directly and would otherwise skip it.
(define (harden-servlet handler)
  (lambda (req) (add-security-headers (handler req))))

;; Request body size cap (DoS): the whole body is read into memory and parsed by
;; `bytes->jsexpr`; an unbounded body lets a client exhaust memory / CPU.  Reject
;; oversized bodies with 413 before parsing.  Configurable via TESL_MAX_BODY_BYTES
;; (bytes); default 1 MiB, which is generous for a typed JSON API.
(define max-body-bytes
  (let ([v (getenv "TESL_MAX_BODY_BYTES")])
    (or (and v (let ([n (string->number v)]) (and (exact-positive-integer? n) n)))
        (* 1 1024 1024))))

(define (parse-json-body req)
  (cond
    [(not (regexp-match? #rx"application/json" (or (request-header req "content-type" "") "")))
     (check-fail "Expected application/json payload" 415 '())]
    [(> (bytes-length (dsl-request-body req)) max-body-bytes)
     (check-fail "Request body too large" 413 '())]
    [(zero? (bytes-length (dsl-request-body req)))
     (check-fail "Missing JSON payload" 400 '())]
    [else
     (with-handlers ([exn:fail? (lambda (_)
                                  (check-fail "Malformed JSON payload" 400 '()))])
       (bytes->jsexpr (dsl-request-body req)))]))

(define (apply-checker-to-value name raw maybe-checker)
  (cond
    [(not maybe-checker)
     (ensure-named name raw)]
    [else
     (define result (maybe-checker (raw-value raw)))
     (cond
       [(check-fail? result) result]
       [(check-ok? result)
        (ensure-named name
                      (check-ok-value result)
                      (check-ok-facts result)
                      (check-ok-bindings result))]
       [(named-value? result)
        (ensure-named name result)]
       ;; allCheck returns Nothing (any element failed) or Something validated-list
       [(Nothing? result)
        (check-fail "request body element validation failed" 400 '())]
       [(Something? result)
        (ensure-named name (Something-value result))]
       ;; filterCheck returns a plain list — treat as a valid value directly
       [else
        (ensure-named name result)])]))

(define (run-auth auth req)
  (define result ((auth-spec-via auth) req))
  (define (attach-auth-proof bound)
    (if (auth-spec-proof auth)
        (attach bound
                (list (instantiate-binder-proof (auth-spec-binder auth)
                                                bound
                                                (auth-spec-proof auth))))
        bound))
  (cond
    [(check-fail? result) result]
    [(check-ok? result)
     (attach-auth-proof
      (ensure-named (auth-spec-binder auth)
                    (check-ok-value result)
                    (check-ok-facts result)
                    (check-ok-bindings result)))]
    [(named-value? result)
     (attach-auth-proof
      (ensure-named (auth-spec-binder auth) result))]
    [else
     (error 'auth "auther did not return a check result")]))

(define (resolve-payload spec req)
  (unless (eq? (payload-spec-format spec) 'JSON)
    (error 'route "only JSON request bodies are currently supported"))
  (define parsed (parse-json-body req))
  (cond
    [(check-fail? parsed) parsed]
    [else
     (with-handlers ([exn:fail? (lambda (exn)
                                  ;; Generic client message by default (don't leak
                                  ;; internal exn text on the decode/handler path);
                                  ;; full detail only under TESL_VERBOSE.
                                  (check-fail (if tesl-verbose?
                                                  (exn-message exn)
                                                  "Invalid request payload")
                                              400 '()))])
       (define decoded
         (cond
           [(payload-spec-wire-type spec)
            (define wire-value
              (jsexpr->typed-value/result (payload-spec-wire-type spec) parsed 'ReqBody))
            (if (check-fail? wire-value)
                wire-value
                ((payload-spec-decoder spec) wire-value))]
           [else
            ((payload-spec-decoder spec) parsed)]))
       (cond
         [(check-fail? decoded) decoded]
         [else
          (unless (runtime-type-satisfied? (payload-spec-type spec) (raw-value decoded))
            (raise-user-error 'ReqBody
                              "request decoder produced a value that does not satisfy declared body type ~a"
                              (payload-spec-type spec)))
          (define bound
            (apply-checker-to-value (payload-spec-name spec)
                                    decoded
                                    (payload-spec-checker spec)))
          (if (and (named-value? bound) (payload-spec-proof spec))
              (attach bound
                      (list (instantiate-binder-proof (payload-spec-name spec)
                                                      bound
                                                      (payload-spec-proof spec))))
              bound)]))]))

(define (resolve-segments segments req)
  (define path (dsl-request-path req))
  (let loop ([remaining segments]
             [path-left path]
             [args '()])
    (cond
      [(null? remaining)
       (if (null? path-left)
           (reverse args)
           no-match)]
      [else
       (define segment (car remaining))
       (cond
         [(string? segment)
          (if (and (pair? path-left)
                   (string=? segment (car path-left)))
              (loop (cdr remaining) (cdr path-left) args)
              no-match)]
         [(capture-spec? segment)
          (cond
            [(null? path-left) no-match]
            [else
             (define parsed ((capture-spec-parser segment) (car path-left)))
             (cond
               [(check-fail? parsed) no-match]
               [else
                (define bound
                  (apply-checker-to-value (capture-spec-name segment)
                                          parsed
                                          (capture-spec-checker segment)))
                (cond
                  [(check-fail? bound) bound]
                  [(and (named-value? bound) (capture-spec-proof segment))
                   (loop (cdr remaining)
                         (cdr path-left)
                         (cons (attach bound
                                       (list (instantiate-binder-proof (capture-spec-name segment)
                                                                       bound
                                                                       (capture-spec-proof segment))))
                               args))]
                  [else
                   (loop (cdr remaining)
                         (cdr path-left)
                         (cons bound args))])])])]
         [(payload-spec? segment)
          (define bound (resolve-payload segment req))
          (cond
            [(check-fail? bound)
             ;; If there are still unmatched path segments, this route can't
             ;; possibly match anyway — treat as no-match so the dispatcher
             ;; continues to the next candidate route.  Only propagate the
             ;; body-decoding error when the path was already fully consumed
             ;; (i.e. this really IS the intended route).
             (if (null? path-left) bound no-match)]
            [else
             (loop (cdr remaining) path-left (cons bound args))])]
         [else
          (error 'route "unsupported segment declaration: ~a" segment)])])))

;; proof-infix-operands is shared via private/proof-utils.rkt (see that file for
;; why this is the only one of the collision candidates safe to deduplicate;
;; normalize-typecheck-value stays duplicated here on purpose — it diverges).

(define (input-bearing-segments route)
  (for/list ([segment (in-list (route-spec-segments route))]
             #:when (or (capture-spec? segment)
                        (payload-spec? segment)))
    segment))

(define (extend-return-name-env base-env binder-name result)
  (cond
    [(hash-has-key? base-env binder-name) base-env]
    [(named-value? result)
     (define next-env (hash-copy base-env))
     (hash-set! next-env binder-name (named-value-name result))
     next-env]
    [(and (symbol? result)
          (or (hash-has-key? (current-evidence-env) result)
              (hash-has-key? (current-proof-env) result)))
     (define next-env (hash-copy base-env))
     (hash-set! next-env binder-name result)
     next-env]
    [(check-ok? result)
     (define maybe-name
       (or (for/first ([(key value) (in-hash (check-ok-bindings result))]
                       #:when (equal? value (check-ok-value result)))
             key)
           (and (= (hash-count (check-ok-bindings result)) 1)
                (car (hash-keys (check-ok-bindings result))))))
     (if maybe-name
         (let ([next-env (hash-copy base-env)])
           (hash-set! next-env binder-name maybe-name)
           next-env)
         base-env)]
    [else base-env]))

(define (route-return-name-env route auth-value segment-values)
  (define env (make-hash))
  (when (and (route-spec-auth route)
             (named-value? auth-value))
    (hash-set! env
               (auth-spec-binder (route-spec-auth route))
               (named-value-name auth-value)))
  (for ([segment (in-list (input-bearing-segments route))]
        [value (in-list segment-values)])
    (when (named-value? value)
      (hash-set! env
                 (cond
                   [(capture-spec? segment) (capture-spec-name segment)]
                   [else (payload-spec-name segment)])
                 (named-value-name value))))
  (hash-copy env))

(define (return-spec-expected-shape result normalized-return name-env)
  (match normalized-return
    [(list binder ': type)
     (values type #f (extend-return-name-env name-env binder result))]
    [(list binder ': type '::: proof)
     (values type proof (extend-return-name-env name-env binder result))]
    [(list '? type binder)
     (values type #f (extend-return-name-env name-env binder result))]
    [(list '? type binder '::: proof)
     (values type proof (extend-return-name-env name-env binder result))]
    [(list type '::: proof)
     (values type proof name-env)]
    [_
     (values normalized-return #f name-env)]))

(define (return-validation-error subject format-string . args)
  (error 'handler-return
         (apply format format-string (cons subject args))))

(define (binding-spec-name binding-spec)
  (match binding-spec
    [(list name ': _ ...)
     name]
    [_
     (error 'handler-return "invalid existential binding specification ~a" binding-spec)]))

(define (normalize-typecheck-value value)
  (cond
    [(and (symbol? value)
          (hash-has-key? (current-evidence-env) value))
     (normalize-typecheck-value (hash-ref (current-evidence-env) value))]
    [(named-value? value)
     (normalize-typecheck-value (named-value-value value))]
    [(check-ok? value)
     (normalize-typecheck-value (check-ok-value value))]
    [(runtime-binding? value)
     (normalize-typecheck-value (runtime-binding-raw value))]
    [(list? value)
     (map normalize-typecheck-value value)]
    [else value]))

(define (validate-type-expression subject result expected-type name-env)
  (define maybe-adt-spec (adt-application-spec expected-type))
  (cond
    [maybe-adt-spec
     (define-values (_validated _ignored-env)
       (validate-adt-return subject result expected-type name-env maybe-adt-spec))
     (void)]
    [else
     (unless (runtime-type-satisfied? expected-type (normalize-typecheck-value result))
       (return-validation-error subject
                                "~a returned a value that does not satisfy declared return type ~a"
                                expected-type))]))

(define (validate-flat-return subject result normalized-return name-env)
  (define-values (expected-type _expected-proof effective-name-env)
    (return-spec-expected-shape result normalized-return name-env))
  (validate-type-expression subject result expected-type effective-name-env)
  ;; The return PROOF re-check is erased: the static checker is the sole
  ;; guarantor of the returned proof.  The return TYPE check above, and the
  ;; existential-package SHAPE check in validate-exists-return, are NOT proof
  ;; re-validation and stay enabled.
  (values result effective-name-env))

(define (validate-exists-return subject result normalized-return name-env)
  (unless (packed-exists? result)
    (return-validation-error subject
                             "~a returned a value that does not satisfy declared existential return ~a; expected an explicitly packed value"
                             normalized-return))
  (define exists-items (rest normalized-return))
  (define exists-body (last exists-items))
  (define exists-bindings (drop-right exists-items 1))
  (define expected-names (map binding-spec-name exists-bindings))
  (define actual-witnesses (packed-exists-witnesses result))
  (define actual-names (map packed-witness-public-name actual-witnesses))
  (define missing-names
    (filter (lambda (name)
              (not (member name actual-names)))
            expected-names))
  (define extra-names
    (filter (lambda (name)
              (not (member name expected-names)))
            actual-names))
  (when (pair? missing-names)
    (return-validation-error subject
                             "~a returned an existential package missing witness name~a ~a for ~a"
                             (if (= (length missing-names) 1) "" "s")
                             missing-names
                             normalized-return))
  (when (pair? extra-names)
    (return-validation-error subject
                             "~a returned an existential package with unexpected witness name~a ~a for ~a"
                             (if (= (length extra-names) 1) "" "s")
                             extra-names
                             normalized-return))
  (define witness-table
    (for/hash ([witness (in-list actual-witnesses)])
      (values (packed-witness-public-name witness)
              (packed-witness-value witness))))
  (define effective-name-env (hash-copy name-env))
  (for ([binding-spec (in-list exists-bindings)])
    (define binder-name (binding-spec-name binding-spec))
    (define witness-value (hash-ref witness-table binder-name))
    (hash-set! effective-name-env binder-name (named-value-name witness-value))
    (define-values (_validated _next-env)
      (validate-flat-return subject witness-value binding-spec effective-name-env))
    (void))
  (define-values (_validated-body _body-env)
    (validate-return-value subject (packed-exists-body result) exists-body effective-name-env))
  (values result name-env))

(define (validate-adt-return subject result normalized-return name-env [adt-spec-value #f])
  (define spec (or adt-spec-value (adt-application-spec normalized-return)))
  (define type-name (adt-spec-name spec))
  (define type-args (rest normalized-return))
  (define type-params (adt-spec-parameters spec))
  (unless (= (length type-params) (length type-args))
    (return-validation-error subject
                             "~a used declared ADT return ~a with ~a parameter~a but ADT ~a expects ~a"
                             normalized-return
                             (length type-args)
                             (if (= (length type-args) 1) "" "s")
                             type-name
                             (length type-params)))
  (define raw-result (raw-value result))
  (unless (and (adt-value? raw-result)
               (eq? (adt-value-type raw-result) type-name))
    (return-validation-error subject
                             "~a returned a value that does not satisfy declared ADT return ~a"
                             normalized-return))
  (define variant-name (adt-value-variant raw-result))
  (define variant-spec
    (for/first ([candidate (in-list (adt-spec-variants spec))]
                #:when (eq? (adt-variant-spec-name candidate) variant-name))
      candidate))
  (unless variant-spec
    (return-validation-error subject
                             "~a returned a value using unknown variant ~a for ADT ~a"
                             variant-name
                             type-name))
  (define expected-fields (adt-variant-spec-fields variant-spec))
  (define actual-fields (adt-value-fields raw-result))
  (define expected-labels (map adt-field-spec-label expected-fields))
  (define actual-labels (hash-keys actual-fields))
  (define missing-labels
    (filter (lambda (label)
              (not (member label actual-labels)))
            expected-labels))
  (define extra-labels
    (filter (lambda (label)
              (not (member label expected-labels)))
            actual-labels))
  (when (pair? missing-labels)
    (return-validation-error subject
                             "~a returned variant ~a missing field label~a ~a for declared ADT return ~a"
                             variant-name
                             (if (= (length missing-labels) 1) "" "s")
                             missing-labels
                             normalized-return))
  (when (pair? extra-labels)
    (return-validation-error subject
                             "~a returned variant ~a with unexpected field label~a ~a for declared ADT return ~a"
                             variant-name
                             (if (= (length extra-labels) 1) "" "s")
                             extra-labels
                             normalized-return))
  (define param-env
    (for/hash ([type-param (in-list type-params)]
               [type-arg (in-list type-args)])
      (values type-param type-arg)))
  (define field-name-env (hash-copy name-env))
  (for ([field-spec (in-list expected-fields)])
    (define label (adt-field-spec-label field-spec))
    (define field-value (hash-ref actual-fields label))
    (define field-annotation
      (instantiate-adt-field-template (adt-field-spec-template field-spec) param-env))
    (define-values (_validated next-name-env)
      (validate-return-value subject field-value field-annotation field-name-env))
    (set! field-name-env next-name-env))
  (values result name-env))

(define (validate-return-value subject result normalized-return name-env)
  (cond
    [(and (list? normalized-return)
          (pair? normalized-return)
          (eq? (first normalized-return) 'Exists))
     (validate-exists-return subject result normalized-return name-env)]
    [(adt-application-spec normalized-return)
     => (lambda (spec)
          (validate-adt-return subject result normalized-return name-env spec))]
    [else
     (validate-flat-return subject result normalized-return name-env)]))

(define (signature-return-subject signature)
  (define kind-label
    (case (signature-spec-kind signature)
      [(handler) "define-handler"]
      [(pow) "define/pow"]
      [(trusted) "define-trusted"]
      [else "dsl"]))
  (format "~a ~a" kind-label (signature-spec-name signature)))

(define (validate-signature-return signature result)
  (cond
    [(dsl-response? result) result]
    [(check-fail? result) result]
    [else
     (define-values (validated _name-env)
       (validate-return-value (signature-return-subject signature)
                              result
                              (signature-spec-returns signature)
                              (hash-copy (current-name-env))))
     ;; Resolve bare gensym symbols before they escape the parameterize scope.
     ;; When a function returns a parameter variable directly (e.g. `fn id(x) = x`),
     ;; the body yields the gensym symbol for that param.  Outside the parameterize
     ;; the gensym is meaningless.  Resolve it to the named-value from evidence-env,
     ;; which preserves any attached proof facts while producing a usable value.
     (if (and (symbol? validated)
              (hash-has-key? (current-evidence-env) validated))
         (hash-ref (current-evidence-env) validated)
         validated)]))

(define (validate-handler-return route auth-value segment-values result)
  (cond
    [(or (dsl-response? result) (check-fail? result)) result]
    [else
     (define-values (validated _name-env)
       (validate-return-value (format "handler for endpoint ~a" (route-spec-operation route))
                              result
                              (route-spec-returns route)
                              (route-return-name-env route auth-value segment-values)))
     validated]))

(define (validate-encoded-response route result)
  (define wire-type (route-spec-response-wire-type route))
  (when wire-type
    (validate-type-expression (format "response encoder for endpoint ~a" (route-spec-operation route))
                              result
                              wire-type
                              (hash)))
  result)

;; A2 — Tesl-level failure rendering for runtime errors caught at the handler
;; boundary.  Classifies the raw backend message into one of the categories A2
;; targets (capability violation, runtime type / proof error, check reject) and
;; renders it naming the originating Tesl construct (the handler/operation).
;; Position resolution stays the OCaml `tesl-sourcemap render` step's job (this
;; runtime is deliberately position-agnostic); here we provide the construct +
;; category so the message is legible even without the source map, and richer
;; under TESL_VERBOSE.  Pure string building — no behavioural change.
(define (tesl-render-handler-failure operation method path msg)
  (define category
    (cond
      [(regexp-match? #rx"Missing capabilities|Capabilities not declared" msg) "capability violation"]
      [(regexp-match? #rx"does not satisfy declared proof" msg) "proof rejection"]
      [(regexp-match? #rx"does not satisfy declared type" msg) "runtime type error"]
      [(regexp-match? #rx"\\(HTTP [0-9]+\\)" msg) "check reject"]
      [else "runtime error"]))
  (define head
    (format "~a ~a: ~a in handler ~a" method path category operation))
  (if tesl-verbose?
      ;; Verbose: include the raw backend detail and a hint to resolve the Tesl
      ;; source position from the trace via `tesl-sourcemap render`.
      (format "~a\n    detail: ~a\n    (resolve .tesl position: tesl-sourcemap render <map> <trace>)"
              head msg)
      (format "~a — ~a" head msg)))

(define (handler-result->response route result)
  (cond
    [(dsl-response? result) result]
    [(check-fail? result)
     (error-response (check-fail-status result)
                     (check-fail-message result)
                     #:details (check-fail-details result))]
    [else
     (define prepared (prepare-response-value result))
     (define encoded
       (if (route-spec-response-encoder route)
           ((route-spec-response-encoder route) prepared)
           prepared))
     (cond
       [(dsl-response? encoded) encoded]
       [(check-fail? encoded)
        (error-response (check-fail-status encoded)
                        (check-fail-message encoded)
                        #:details (check-fail-details encoded))]
       [else
        (validate-encoded-response route encoded)
        (json-response encoded)])]))

(define (dispatch-request server req #:capabilities [capabilities '()])
  (unless (server-spec? server)
    (raise-user-error 'dispatch-request "expected a server-spec; define a server with define-server first"))
  (define checked-capabilities (expand-capabilities capabilities))
  (define request-id
    (format "req-~a-~a" (current-seconds) (random 1000000)))
  (define path-string
    (string-append "/" (string-join (dsl-request-path req) "/")))
  (define start-ms (and (or (tesl-log-active?) (metrics-active?))
                        (current-inexact-milliseconds)))
  (when (tesl-log-active?)
    (tesl-log-http-request! (dsl-request-method req) path-string))
  ;; Metrics: the route operation is only known once a route matches; the match
  ;; loop below records it here so the duration histogram gets a LOW-CARDINALITY
  ;; label (operation name, never the raw path — an ID-bearing path would mint a
  ;; new time series per request).
  (define matched-operation #f)

  ;; ── W3C trace context (roadmap/completed/otel_trace_support.md, Phase A) ────
  ;;
  ;; An inbound `traceparent` is the caller's trace, and dropping it is what makes
  ;; our app a HOLE in someone else's trace.  Parse it here — header names are
  ;; already lowercased by `dsl-request-headers` — and carry it as the ambient
  ;; context for the whole request, so every log record gains
  ;; trace.id/span.id/trace.sampled (dsl/otel.rkt appends them on emit) and every
  ;; outbound HTTP call continues the chain, with ZERO new call sites.
  ;;
  ;; `request.id` above is untouched: it appears in user-facing error output, it
  ;; is not 16 hex bytes, and redefining it is an explicit non-goal.  A trace id
  ;; is the machine join key; request.id stays the human handle.
  (define trace-root
    (make-root-trace-ctx #:traceparent (request-header req "traceparent")
                         #:tracestate (request-header req "tracestate")
                         #:ratio (trace-sample-ratio)))

  (define (dispatch-body)

    (define (route-context route auth-value)
      (append
       (list (cons 'request.id request-id)
             (cons 'http.method (dsl-request-method req))
             (cons 'http.path path-string)
             (cons 'operation (route-spec-operation route)))
       (if (and auth-value
                (named-value? auth-value)
                (hash? (named-value-value auth-value)))
           (let ([user-id (hash-ref (named-value-value auth-value) 'id #f)])
             (if user-id
                 (list (cons 'user.id user-id))
                 '()))
           '())))

    ;; Shared server-side failure log, used by both the handler-body arms and the
    ;; auth-path wrapper below, so an exception renders identically wherever it is
    ;; thrown.
    (define (log-route-failure route exn)
      (fprintf (handler-error-port) "~a\n"
               (tesl-render-handler-failure
                (route-spec-operation route)
                (dsl-request-method req)
                path-string
                (exn-message exn))))

    (define (invoke-handler route auth-value segment-values)
      (parameterize ([current-capabilities checked-capabilities]
                     [current-telemetry-events '()])
        (call-with-telemetry-context
         (route-context route auth-value)
         (lambda ()
           (with-handlers ([exn:fail:tesl:pool-timeout?
                            (lambda (exn)
                              ;; issue #31: a pool-lease timeout means the server is
                              ;; SATURATED, not broken — every pooled DB connection
                              ;; stayed busy for the whole bounded wait.  503 tells
                              ;; clients and load balancers "retry later", unlike the
                              ;; generic 500 below.  Same logging discipline: full
                              ;; message server-side, echoed to the client only under
                              ;; TESL_VERBOSE.
                              (fprintf (handler-error-port) "~a\n"
                                       (tesl-render-handler-failure
                                        (route-spec-operation route)
                                        (dsl-request-method req)
                                        (string-append "/" (string-join (dsl-request-path req) "/"))
                                        (exn-message exn)))
                              (error-response 503
                                              "Service unavailable: database connection pool exhausted"
                                              #:details (if tesl-verbose?
                                                            (list (exn-message exn))
                                                            '())))]
                           [exn:fail? (lambda (exn)
                                        ;; A2: render the failure at the originating Tesl
                                        ;; construct (the handler/operation), classified by
                                        ;; category, instead of an opaque "handler error".
                                        ;; Additive: the 500 response is unchanged; only the
                                        ;; logged diagnostic is upgraded (richer under
                                        ;; TESL_VERBOSE).
                                        (fprintf (handler-error-port) "~a\n"
                                                 (tesl-render-handler-failure
                                                  (route-spec-operation route)
                                                  (dsl-request-method req)
                                                  (string-append "/" (string-join (dsl-request-path req) "/"))
                                                  (exn-message exn)))
                                        ;; Do NOT leak the internal exception text to
                                        ;; the client by default — it can expose DB/SQL
                                        ;; fragments, file paths, internal identifiers.
                                        ;; The full message is always logged server-side
                                        ;; above; only echo it in the response under
                                        ;; TESL_VERBOSE (a dev aid).
                                        (error-response 500
                                                        "Internal server error"
                                                        #:details (if tesl-verbose?
                                                                      (list (exn-message exn))
                                                                      '())))])
             (handler-result->response
             route
             (validate-handler-return
               route
               auth-value
               segment-values
               (apply (route-spec-handler route)
                      (append (if auth-value (list auth-value) '())
                              segment-values)))))))))

    ;; Sentinel: no route in the table matched method+path.
    ;; Distinct from a handler-level 404 so the SPA fallback only fires for
    ;; genuine "no route" cases, not for handler-produced 404 errors.
    ;; `current-response-cookies` is scoped ONCE per request, around the whole
    ;; match/auth/handler sequence.  `Http.setSessionCookie` appends to it from
    ;; arbitrary depth and `json-response` — reached inside this same extent —
    ;; reads it back.  Scoping it here rather than inside `invoke-handler` means an
    ;; `auth` block can also write (its cookie rides the handler's 2xx), and
    ;; scoping it per request at all is what stops a cookie set by one request from
    ;; leaking onto the next one served by the same thread.  The `'route-not-found`
    ;; 404 built below is deliberately OUTSIDE the extent: nothing set a cookie
    ;; there, and `response-cookie-headers` returns '() with no live scope.
    ;;
    ;; The SERVER span (Phase B).  It brackets exactly what the request-duration
    ;; histogram times, so every child span — one per SQL statement, per outbound
    ;; call, per LLM call, per agent tool — hangs off it and the N+1 question
    ;; (which of the 40 queries in this slow request, and what called it) becomes
    ;; readable.  With `traces False` (the default) the macro reads one flag and
    ;; evaluates neither the name nor the attributes.
    ;;
    ;; The span NAME must stay low-cardinality (it is a grouping key in every
    ;; trace UI), so it starts as the bare method and is refined to
    ;; "METHOD operation" once the match loop knows the operation — never the raw
    ;; path, which carries ids.  The raw path goes on an ATTRIBUTE, where high
    ;; cardinality is free.
    (define response
      (with-server-span (server-span
                         (dsl-request-method req)
                         'server
                         (list (cons 'http.request.method (dsl-request-method req))
                               (cons 'url.path path-string)
                               (cons 'tesl.request.id request-id)))
        (define response-value
          (parameterize ([current-capabilities checked-capabilities]
                         [current-response-cookies '()])
            (let loop ([routes (server-spec-routes server)])
              (cond
                [(null? routes)
                 'route-not-found]
                [else
                 (define route (car routes))
                 (if (not (string=? (normalize-method (route-spec-method route))
                                    (dsl-request-method req)))
                     (loop (cdr routes))
                     ;; Check path segments BEFORE running auth so a non-matching
                     ;; path does not consume the request with a premature auth failure.
                     (let ([segment-values (resolve-segments (route-spec-segments route) req)])
                       (cond
                         [(eq? segment-values no-match)
                          (loop (cdr routes))]
                         [(check-fail? segment-values)
                          (set! matched-operation (route-spec-operation route))
                          (handler-result->response route segment-values)]
                         [else
                          (set! matched-operation (route-spec-operation route))
                          ;; F2 (2026-07-30): `run-auth` runs OUTSIDE `invoke-handler`'s
                          ;; `with-handlers`, so an exception thrown in an `auth` block
                          ;; used to escape to `serve/servlet`'s default responder — a
                          ;; 500 carrying the message, the full stack trace, and
                          ;; absolute source paths, contradicting the no-leak policy the
                          ;; handler body already follows.  Contain it here with the
                          ;; SAME discipline (full detail logged server-side; only a
                          ;; sanitized message to the client under TESL_VERBOSE), and
                          ;; the pool-timeout→503 parity too, since an auth block reads
                          ;; the DB.
                          (with-handlers
                            ([exn:fail:tesl:pool-timeout?
                              (lambda (exn)
                                (log-route-failure route exn)
                                (error-response
                                 503 "Service unavailable: database connection pool exhausted"
                                 #:details (if tesl-verbose? (list (exn-message exn)) '())))]
                             [exn:fail?
                              (lambda (exn)
                                (log-route-failure route exn)
                                (error-response
                                 500 "Internal server error"
                                 #:details (if tesl-verbose? (list (exn-message exn)) '())))])
                            (let ([auth-value (and (route-spec-auth route)
                                                  (run-auth (route-spec-auth route) req))])
                              (cond
                                [(check-fail? auth-value)
                                 (handler-result->response route auth-value)]
                                [else
                                 (invoke-handler route auth-value segment-values)])))])))]))))
      ;; Refine the span now that the match loop has run.  A 5xx marks the span
      ;; ERROR — the handler boundary already turned the exception into a
      ;; response, so this is the only place the failure is still visible.
      (when server-span
        (span-set-name! server-span
                        (if matched-operation
                            (format "~a ~a" (dsl-request-method req) matched-operation)
                            (dsl-request-method req)))
        (span-add-attributes!
         server-span
         (append (list (cons 'tesl.operation
                             (if matched-operation (~a matched-operation) "unmatched")))
                 (if (dsl-response? response-value)
                     (list (cons 'http.response.status_code
                                 (dsl-response-status response-value)))
                     '())))
        (when (and (dsl-response? response-value)
                   (>= (dsl-response-status response-value) 500))
          (span-mark-error! server-span
                            (format "HTTP ~a" (dsl-response-status response-value)))))
      response-value))
    (define final-response
      (if (eq? response 'route-not-found)
          (error-response 404 "Route not found")
          response))
    (when (tesl-log-active?)
      (define elapsed-ms
        (inexact->exact (round (- (current-inexact-milliseconds) start-ms))))
      (tesl-log-http-response! (dsl-request-method req) path-string
                                 (dsl-response-status final-response) elapsed-ms))
    ;; Metrics: matched requests only.  The 'route-not-found sentinel must NOT be
    ;; recorded here as a 404 — `serve` may resolve it to a 200 SPA index-html
    ;; fallback (the invariant documented below), and recording early would show
    ;; a permanent 404 storm for every healthy SPA page load.  serve records the
    ;; sentinel's RESOLVED outcome itself.
    (when (and (metrics-active?) start-ms (not (eq? response 'route-not-found)))
      (metric-histogram-record!
       "http.server.request.duration"
       (/ (- (current-inexact-milliseconds) start-ms) 1000.0)
       (list (cons "http.request.method" (dsl-request-method req))
             (cons "http.response.status_code"
                   (number->string (dsl-response-status final-response)))
             (cons "tesl.operation" (or matched-operation "unmatched")))
       #:unit "s"
       #:boundaries duration-histogram-boundaries))
    ;; Return the sentinel as-is so `serve` can distinguish "no route" from
    ;; a handler-level 404 (e.g. "user not found").  serve converts it to a
    ;; real response or the SPA fallback.
    response)

  ;; Risk 49/61: refuse a STATE-CHANGING request the browser labels an explicit
  ;; cross-site fetch (`Sec-Fetch-Site: cross-site`).  A token-free, per-route-free
  ;; CSRF defence: an ABSENT header allows (old browsers / non-browser clients),
  ;; and only the literal `cross-site` is refused — `same-origin`/`same-site`/`none`
  ;; all pass.  Safe (GET/HEAD/OPTIONS) methods are never refused.
  (define (sec-fetch-cross-site-refusal)
    (define method (string-upcase (dsl-request-method req)))
    (and (member method '("POST" "PUT" "DELETE" "PATCH"))
         (let ([sfs (request-header req "sec-fetch-site")])
           (and sfs (string=? (string-downcase (string-trim sfs)) "cross-site")))
         (error-response 403 "cross-site request refused")))
  ;; The whole request — match, auth, handler, response log, metrics — runs under
  ;; the ambient trace context.  `parameterize` (never an imperative set) is what
  ;; keeps a keep-alive connection thread from carrying one request's trace into
  ;; the next, and what makes the context inherited by any thread the handler
  ;; spawns.
  ;; Risk 50/60: when a publicOrigin is declared, the request `Host` must name
  ;; that origin's host — otherwise a Host-header attack could make the app
  ;; mint links/cookies for another origin.  Gated on publicOrigin being set
  ;; (clause or TESL_PUBLIC_ORIGIN), so a server without one is unaffected.
  ;; Exactly one declared health-probe path is exempt (LBs probe host-blind).
  (define (host-mismatch-refusal)
    (define origin (public-origin-value))
    (cond
      [(not origin) #f]
      [(and (current-health-probe-path)
            (string=? path-string (current-health-probe-path))) #f]
      [else
       (define got (host-of (or (request-header req "host") "")))
       (if (and (not (string=? got "")) (string=? got (host-of origin)))
           #f
           (error-response 421 "Host does not match the configured public origin"))]))
  (or (sec-fetch-cross-site-refusal)
      (host-mismatch-refusal)
      (call-with-trace-ctx trace-root dispatch-body)))

;; ── SSE route matching ───────────────────────────────────────────────────────
;;
;; Each SSE route is (list path-prefix-parts auth-fn channel-spec).
;; Example: (list '("events" "rooms") cookieAuth RoomMessages)
;;
;; Matches GET requests whose path starts with path-prefix-parts.
;; The first segment AFTER the prefix is used as the channel key.

;; Issue #17: match the FULL path pattern.  A pattern entry is either a literal
;; string (must match the request segment) or #f (a `:param` capture slot —
;; matches any single segment).  Exact length: /rooms/:roomId/events matches
;; ("rooms" "r1" "events") but not ("rooms" "r1") or ("rooms" "r1" "events" "x").
(define (find-sse-match sse-routes req)
  (and (string=? (dsl-request-method req) "GET")
       (let ([path (dsl-request-path req)])
         (for/or ([route (in-list sse-routes)])
           (define pattern (first route))
           (and (= (length path) (length pattern))
                (for/and ([seg (in-list pattern)] [p (in-list path)])
                  (or (not seg) (equal? seg p)))
                route)))))

;; Resolve an SSE route's channel slot to a live channel-spec.  The emitter
;; writes the channel two ways:
;;   - the DIRECT binding when the channel is declared in the emitting module
;;     (byte-identical to the historical output), or
;;   - the channel NAME as a quoted SYMBOL when it is declared in another
;;     module (the issue-#41 name-wired class).  The sse-routes list is a
;;     top-level define evaluated at module INSTANTIATION — a direct
;;     channel-for-name call there could run before the declaring module
;;     registers (when the declarer is the importing entrypoint), so the
;;     symbol is resolved LAZILY here, at consumption time (first subscribe /
;;     serve startup), when every require has long since instantiated.
(define (resolve-sse-channel ch)
  (if (symbol? ch) (channel-for-name ch) ch))

;; SSE bypasses `dsl-response` entirely (it returns a `response/output` stream),
;; so it needs its own cookie scope and its own append — otherwise a cookie set
;; before subscribing would be silently dropped.  The scope wraps the auth call
;; below, which is the only thing on this path that could write one.
;;
;; F6 (2026-07-30): `current-capabilities` is parameterized HERE too, not only in
;; `dispatch-request`/`invoke-handler`.  Without it the SSE path ran with the
;; EMPTY ambient set, so an `auth` block or a `capture` check carrying a
;; `requires` row — the common case, e.g. a session lookup that reads the DB —
;; failed `call-with-declared-capabilities`'s subset assertion with "Missing
;; capabilities" and 500'd every subscribe.  It also made the cookie scope above
;; unreachable, since `Http.setSessionCookie` in an SSE auth could never run.
;; Fail-closed but wrong: the SSE auth call is the same authority as the HTTP
;; one, so it gets the same set the HTTP path gets, from the same `serve` grant.
;;
;; The extent covers auth, the capture checks and the response construction — not
;; the streaming loop, which outlives this call by design (the handler thread
;; needs no Tesl capability; it only writes bytes to an already-open port).
(define (handle-sse-request route dsl-req #:capabilities [capabilities '()])
  (parameterize ([current-capabilities (expand-capabilities capabilities)]
                 [current-response-cookies '()])
    (handle-sse-request* route dsl-req)))

(define (handle-sse-request* route dsl-req)
  (define pattern    (first route))
  (define auth-fn    (second route))
  (define channel-s  (resolve-sse-channel (third route)))
  ;; Issue #17 / #54: 4th element is the key SLOT — an integer index (which
  ;; path segment carries the channel key), a string (a fixed literal every
  ;; connection keys on, e.g. `subscribe RunEvents("all")`), or #f (auth-only
  ;; no-key channel).  5th is the list of (index . validator) for EVERY
  ;; declared `:param` capture check.
  (define key-slot   (and (>= (length route) 4) (fourth route)))
  (define captures   (if (>= (length route) 5) (fifth route) '()))
  (define path       (dsl-request-path dsl-req))
  (define key-str
    (cond [(not key-slot) #f]
          [(string? key-slot) key-slot]
          [else (list-ref path key-slot)]))

  ;; Run auth if present — reject 401 if it fails
  (when auth-fn
    (define auth-result (auth-fn dsl-req))
    (when (check-fail? auth-result)
      ;; Raise the check-fail VALUE (not call it).  The previous `(raise
      ;; (auth-result))` applied the struct as a procedure — it has no
      ;; prop:procedure, so it raised "application: not a procedure", which the
      ;; check-fail? guard in `serve` does not catch, escaping as a 500 with a
      ;; stack trace.  Raising the value lets that guard render a clean 401.
      (raise auth-result)))

  ;; CONC-1 / issue #17: enforce EVERY declared path-capture check (e.g. `capture
  ;; roomId ::: ValidRoomId roomId via roomIdCapture`, and non-key captures such
  ;; as `capture orgId ::: IdSafe orgId`) BEFORE registering the listener.
  ;; Fail-closed: a rejected segment raises the check-fail, which `serve` renders
  ;; as the check's HTTP status — the same discipline as the HTTP route path and
  ;; the auth check above.  Previously these declared checks were silently dropped.
  (for ([cv (in-list captures)])
    (define checked ((cdr cv) (list-ref path (car cv))))
    (when (check-fail? checked)
      (raise checked)))

  ;; Release the pool connection — SSE loop holds the thread alive for minutes
  ;; but needs no DB access.  Without this each open SSE stream permanently
  ;; occupies a pool slot, exhausting the pool after ~10 concurrent connections.
  (define db-runtime (current-database-runtime))
  (when db-runtime
    (with-handlers ([exn:fail? void])
      (disconnect (database-runtime-connection db-runtime))))

  ;; Return an SSE streaming response via response/output
  (define handler (make-sse-connection-handler channel-s key-str))
  ;; F9 (2026-07-30): a session cookie and `Access-Control-Allow-Origin: *` do
  ;; not ship on the same response.  Not exploitable as it stood — a browser
  ;; rejects a wildcard ACAO for a credentialed request outright, and
  ;; `SameSite=Lax` withholds the cookie from an EventSource subresource anyway —
  ;; but "here is your session" beside "any origin may read this" is a
  ;; contradiction that only a browser's own rules were resolving.  The wildcard
  ;; is the one that yields: a subscribe that set a cookie is credentialed, so it
  ;; is same-origin traffic by construction and needs no CORS grant, while the
  ;; ordinary uncredentialed subscribe keeps the header it always had.
  (define cookie-headers (response-cookie-headers))
  (response/output
   #:code 200
   #:message #"OK"
   #:mime-type #"text/event-stream"
   #:headers (append
              (list (make-header #"Cache-Control" #"no-cache")
                    (make-header #"Connection"    #"keep-alive")
                    (make-header #"X-Accel-Buffering" #"no"))
              (if (null? cookie-headers)
                  (list (make-header #"Access-Control-Allow-Origin" #"*"))
                  '())
              cookie-headers)
   handler))

;; ── serve ─────────────────────────────────────────────────────────────────────

;; A static-file URL path segment is "safe" iff it is an ordinary file-name
;; component: never a `.`/`..` traversal token and containing no path separator.
;; This is the path-traversal defense for try-serve-static (blocks
;; `GET /../../etc/passwd`, which decodes to the segments ("..","..",...)).
;; Pure predicates, exported for the security regression suite.
(define (static-path-segment-safe? p)
  (and (not (string=? p ".."))
       (not (string=? p "."))
       (not (string-contains? p "/"))
       (not (string-contains? p "\\"))))
(define (static-path-segments-safe? parts)
  (for/and ([p (in-list parts)]) (static-path-segment-safe? p)))


;;; ── SSO runtime-owned routes (roadmap/next/ensure_sso_works.md, Phase 3) ──────
;;; The `sso "<seg>" …` server clause mints /auth/<seg>/login and
;;; /auth/<seg>/callback.  These are RUNTIME-owned: they do what a Tesl handler
;;; cannot — a 303 redirect (blocker 1) and a Set-Cookie on a non-2xx response
;;; (blocker 2) — so the session/proof surface never has to grow those holes.
;;; Session minting stays OUT of this module: the route carries a `mint-session`
;;; closure (emitted under the app's jwt/time capabilities) that turns a subject
;;; into a signed JwtToken string, so web.rkt touches neither JWT nor capabilities.
(require (only-in net/base64 base64-encode)
         (only-in racket/random crypto-random-bytes)
         racket/runtime-path)
;; dsl/sso.rkt and tesl/jwt.rkt are loaded LAZILY: a static require would cycle
;; (web -> sso/crypto -> http-client -> traces -> web).  dynamic-require defers
;; them to the first SSO request, long after every module has instantiated.
(define-runtime-path sso-module-path "sso.rkt")
(define-runtime-path jwt-module-path "../tesl/jwt.rkt")
(define dyn-fn-cache (make-hash))
(define (dyn-fn mod name)
  (hash-ref! dyn-fn-cache (cons mod name) (lambda () (dynamic-require mod name))))
(define (sso-fn name) (dyn-fn sso-module-path name))
;; base64url (no padding, url-safe) — local, so web.rkt need not statically
;; require crypto (which cycles back through http-client -> traces -> web).
(define (sso-b64url bstr)
  (regexp-replace* #rx"=+$"
   (string-replace (string-replace (bytes->string/utf-8 (base64-encode bstr #"")) "+" "-") "/" "_")
   ""))

;; A route: segment + a connection thunk (-> SsoConnection hash) + the app's
;; identity->subject mapping + a subject->JwtToken minter + the __Host-oauth MAC
;; key (bytes) + the public origin + the post-login landing path.
(struct sso-route (segment connection on-identity mint-session session-key-bytes
                   public-origin after-login) #:transparent)

(define (sso-route-key-bytes route)
  (let ([k (sso-route-session-key-bytes route)]) (if (procedure? k) (k) k)))

(define sso-routes-registry (make-hash))
;; The registry is keyed by server name.  The EMIT registers under a string
;; ("AppServer"), but `build-server-spec` stores the name as a SYMBOL ('AppServer)
;; and `serve` looks it up via `(server-spec-name server)` — so normalise both
;; sides to a string, or the lookup silently misses and no SSO routes mount.
(define (sso-registry-key n) (if (symbol? n) (symbol->string n) n))
(define (register-sso-routes! name routes)
  (hash-set! sso-routes-registry (sso-registry-key name) routes))

;; Read accessor for dsl/test-support.rkt's api-test dispatcher: the routes
;; registered for a server by name, or '() if it declares no `sso` clause. Keeps
;; the registry itself private; api-test matches against the SAME table `serve`
;; matches against, so /auth/<seg>/login|callback is reachable from an api-test
;; exactly like a real request reaches it.
(define (sso-routes-for-server name)
  (hash-ref sso-routes-registry (sso-registry-key name) '()))

;; Phase 3: the `listenAddress` server clause — the interface `serve` binds to.
;; #f = all interfaces (the default); "127.0.0.1" = loopback only (bind behind a
;; reverse proxy so the app is never directly reachable).  Registered as a
;; top-level side effect (like the SSO routes) so a server WITHOUT the clause
;; emits byte-identically; `serve` reads it by server name.
(define listen-address-registry (make-hash))
(define (register-listen-address! name ip) (hash-set! listen-address-registry (sso-registry-key name) ip))

(define (make-sso-route #:segment segment #:connection connection
                        #:on-identity on-identity #:mint-session mint-session
                        #:session-key-bytes session-key-bytes
                        #:public-origin public-origin #:after-login [after-login "/"])
  (sso-route segment connection on-identity mint-session session-key-bytes
             public-origin after-login))

(define (sso-rand-token) (sso-b64url (crypto-random-bytes 32)))
(define sso-oauth-cookie-max-age 600)

;; A __Host- cookie line: Path=/ + Secure + HttpOnly + SameSite=Lax (Lax, not
;; Strict, so the top-level callback navigation keeps the cookie).  No Domain —
;; the __Host- prefix forbids it, which is the point.
(define (sso-cookie-line name value #:max-age [max-age #f] #:same-site [same-site "Lax"])
  (string-append name "=" value "; Path=/; HttpOnly; Secure; SameSite=" same-site
                 (if max-age (format "; Max-Age=~a" max-age) "")))

;; The redirect the Tesl surface cannot build: 303 + Location + no-store + any
;; number of Set-Cookie lines.  harden-servlet layers Referrer-Policy:no-referrer.
(define (sso-redirect-response location cookie-lines)
  (response/full
   303 #"See Other" (current-seconds) #"text/plain; charset=utf-8"
   (append
    (list (make-header #"Location" (string->bytes/utf-8 location))
          (make-header #"Cache-Control" #"no-store"))
    (for/list ([c (in-list cookie-lines)])
      (make-header #"Set-Cookie" (string->bytes/utf-8 c))))
   (list #"")))

;; A failed flow renders a FIXED page and clears __Host-oauth — never a JSON
;; error body, never a fallthrough, never the provider's text (§What onIdentity
;; does when it says no).
(define (sso-failure-response)
  (response/full
   401 #"Unauthorized" (current-seconds) #"text/html; charset=utf-8"
   (list (make-header #"Cache-Control" #"no-store")
         (make-header #"Set-Cookie"
                      (string->bytes/utf-8
                       "__Host-oauth=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0")))
   (list #"<!doctype html><meta charset=\"utf-8\"><title>Sign-in failed</title><p>Sign-in could not be completed. Please try again.")))

;; /auth/<seg>/login|callback matcher -> (route . 'login|'callback) or #f.
(define (find-sso-match sso-routes dsl-req)
  (define path (dsl-request-path dsl-req))
  (and (= (length path) 3)
       (equal? (car path) "auth")
       (let ([kind (caddr path)])
         (and (or (equal? kind "login") (equal? kind "callback"))
              (for/or ([r (in-list sso-routes)])
                (and (equal? (sso-route-segment r) (cadr path))
                     (cons r (if (equal? kind "login") 'login 'callback))))))))

(define (handle-sso-request m dsl-req #:capabilities [capabilities '()])
  ;; The SSO callback path calls app code the RUNTIME owns the call to: the
  ;; connection thunk (envRead), onIdentity (whatever the app declared), and the
  ;; session minter.  Run them under the server's granted capability ambient,
  ;; exactly as `dispatch-request` does for ordinary handlers — the compile-time
  ;; check (validation_capabilities) guarantees these caps ⊆ main's grant.
  (parameterize ([current-capabilities (expand-capabilities capabilities)])
    (case (cdr m)
      [(login)    (handle-sso-login (car m) dsl-req)]
      [(callback) (handle-sso-callback (car m) dsl-req)]
      [else (sso-failure-response)])))

(define (handle-sso-login route dsl-req)
  (define seg (sso-route-segment route))
  (define conn ((sso-route-connection route)))
  (define redirect-uri
    (string-append (sso-route-public-origin route) "/auth/" seg "/callback"))
  (define-values (authorize-url cookie)
    ((sso-fn 'sso-begin-login*) conn seg redirect-uri (sso-route-key-bytes route)
                                (sso-rand-token) (sso-rand-token)
                                (sso-rand-token) (current-seconds)))
  (sso-redirect-response
   authorize-url
   (list (sso-cookie-line "__Host-oauth" cookie #:max-age sso-oauth-cookie-max-age))))

(define (handle-sso-callback route dsl-req)
  (define seg (sso-route-segment route))
  (define q (dsl-request-query dsl-req))
  (define code            (and (hash? q) (hash-ref q "code" #f)))
  (define presented-state (and (hash? q) (hash-ref q "state" #f)))
  (define cookies (dsl-request-cookies dsl-req))
  (define oauth-cookie (and (hash? cookies) (hash-ref cookies "__Host-oauth" #f)))
  (cond
    [(or (not (string? code)) (not (string? oauth-cookie)))
     (when (tesl-log-active?)
       (tesl-log-auth-event! #:outcome "denied" #:provider seg
                             #:client-address (client-address-of dsl-req)
                             #:reason "missing authorization code or __Host-oauth cookie"))
     (sso-failure-response)]
    [else
     (define conn ((sso-route-connection route)))
     (define redirect-uri
       (string-append (sso-route-public-origin route) "/auth/" seg "/callback"))
     (define result
       ;; Fail-closed to the FIXED client page, but log the reason server-side —
       ;; a silently-swallowed callback failure is undebuggable in production.
       (with-handlers ([exn:fail? (lambda (e)
                                    (fprintf (handler-error-port)
                                             "sso callback failed: ~a\n" (exn-message e))
                                    (hasheq 'ok #f))])
         ((sso-fn 'sso-handle-callback*) conn seg code oauth-cookie redirect-uri
                                         (list (sso-route-key-bytes route) #f)
                                         (current-seconds) presented-state)))
     (cond
       [(not (hash-ref result 'ok #f))
        (fprintf (handler-error-port) "sso callback rejected: ~a\n"
                 (hash-ref result 'reason "unknown"))
        (when (tesl-log-active?)
          (tesl-log-auth-event! #:outcome "denied" #:provider seg
                                #:client-address (client-address-of dsl-req)
                                #:reason (format "~a" (hash-ref result 'reason "unknown"))))
        (sso-failure-response)]
       [else
        (define identity (hash-ref result 'identity))
        (define subject ((sso-route-on-identity route) identity))
        (define token-value ((sso-route-mint-session route) subject))
        (when (tesl-log-active?)
          (define (str v) (if (string? v) v ""))
          (tesl-log-auth-event! #:outcome "success" #:provider seg
                                #:client-address (client-address-of dsl-req)
                                #:issuer (str (and (hash? identity) (hash-ref identity 'issuer #f)))
                                #:subject (str (and (hash? identity) (hash-ref identity 'subject #f)))
                                #:tenant (str (and (hash? identity) (hash-ref identity 'tenant #f)))))
        ;; The session cookie REPLACES any pre-existing one (session fixation);
        ;; __Host-session is HttpOnly/Secure/Path=/;SameSite=Lax, Max-Age bounded
        ;; by the active policy's renewable TTL. __Host-oauth is spent (its
        ;; sealed verifier/nonce/state has no further use) so it's cleared here
        ;; exactly as the failure path already clears it.
        (sso-redirect-response
         (sso-route-after-login route)
         (list (sso-cookie-line "__Host-session" token-value
                                #:max-age ((dyn-fn jwt-module-path (quote policy-ttl-seconds))))
               (sso-cookie-line "__Host-oauth" "" #:max-age 0)))])]))

(define (serve server
               #:port         [port 8080]
               #:capabilities [capabilities '()]
               #:sse-routes   [sse-routes '()]
               #:sso-routes   [sso-routes '()]
               #:static-dir   [static-dir #f])
  ;; Auto-start pub/sub LISTEN for SSE channels when PostgreSQL is active.
  ;; This replaces the old startWebSocket ... on PORT call.
  (when (pair? sse-routes)
    (define db-runtime (current-database-runtime))
    (when (and db-runtime
               (eq? (database-spec-backend (database-runtime-database db-runtime))
                    'postgres))
      (define schema (database-schema-name (database-runtime-database db-runtime)))
      (define channel-registry
        (for/hash ([route (in-list sse-routes)])
          (define ch (resolve-sse-channel (third route)))
          (values (channel-spec-name ch) ch)))
      (start-pubsub-listen! channel-registry db-runtime schema)))

  ;; Resolved absolute path to the static directory (or #f if none).
  (define static-dir-path
    (and static-dir (path->complete-path (string->path static-dir))))
  (define index-html-path
    (and static-dir-path (build-path static-dir-path "index.html")))

  ;; Guess MIME type from file extension.
  (define (path->mime-type p)
    (define s (path->string (file-name-from-path p)))
    (cond
      [(regexp-match? #rx"\\.html?$"  s) #"text/html; charset=utf-8"]
      [(regexp-match? #rx"\\.js$"     s) #"application/javascript"]
      [(regexp-match? #rx"\\.css$"    s) #"text/css"]
      [(regexp-match? #rx"\\.json$"   s) #"application/json"]
      [(regexp-match? #rx"\\.svg$"    s) #"image/svg+xml"]
      [(regexp-match? #rx"\\.png$"    s) #"image/png"]
      [(regexp-match? #rx"\\.ico$"    s) #"image/x-icon"]
      [else                              #"application/octet-stream"]))

  ;; Try to serve a static file for a GET request path.
  ;; Returns #f if the file doesn't exist.
  (define (try-serve-static dsl-req)
    (and static-dir-path
         (string=? (dsl-request-method dsl-req) "GET")
         (let* ([path-parts (dsl-request-path dsl-req)]
                ;; Path-traversal defense.  Each URL segment must be an ordinary
                ;; file-name component: never `..`/`.` and never containing a path
                ;; separator or NUL.  `GET /%2e%2e/%2e%2e/etc/passwd` decodes to the
                ;; segments ("..","..","etc","passwd"); rejecting `..` segments
                ;; stops `static-dir/../../etc/passwd` (unauthenticated arbitrary
                ;; file read).  This runs BEFORE auth/dispatch, so it must fail
                ;; closed.
                [safe? (static-path-segments-safe? path-parts)])
           (and safe?
                (let* ([rel-path (if (null? path-parts)
                                     "index.html"
                                     (apply build-path (map (lambda (p)
                                                              (if (string=? p "") "index.html" p))
                                                            path-parts)))]
                       [file-path (build-path static-dir-path rel-path)]
                       ;; Defense in depth: the resolved path must stay inside the
                       ;; static dir even after syntactic `..` collapse.
                       [base (path->string
                              (simplify-path (path->complete-path static-dir-path) #f))]
                       [resolved (path->string
                                  (simplify-path (path->complete-path file-path) #f))])
                  (and (string-prefix? resolved base)
                       (file-exists? file-path)
                       (response/full 200 #"OK" (current-seconds)
                                      (path->mime-type file-path) '()
                                      (list (file->bytes file-path)))))))))

  (serve/servlet
   (harden-servlet
    (lambda (req)
     (define dsl-req (request->dsl-request req))

     ;; 1. SSE routes (long-lived streaming responses)
     ;;
     ;; METRIC CONTRACT (pinned by tests/otlp-metrics-test.rkt tier 5): SSE
     ;; requests are deliberately EXCLUDED from http.server.request.duration.
     ;; They are long-lived streams — one open EventSource "lasts" minutes to
     ;; hours, so recording its lifetime would poison every percentile of a
     ;; histogram whose other samples are millisecond API calls.  The SSE
     ;; route table is matched here, BEFORE dispatch-request (the histogram's
     ;; only matched-request recording site), and neither handle-sse-request
     ;; nor stream teardown records it, so the exclusion holds on accept,
     ;; while streaming, and at disconnect.  SSE traffic has its own catalog
     ;; entries instead: tesl.sse.connections.active (per-channel gauge —
     ;; the "active requests" signal for streams) and
     ;; tesl.sse.events.sent/dropped (counters).  There is no separate
     ;; http.server.request counter in the catalog (the histogram's count
     ;; doubles as it), so excluding SSE here excludes it from request
     ;; counts too — by design: stream connects are connection-lifecycle
     ;; events, visible in the gauge, not request-shaped work.
     (define sse-match (find-sse-match sse-routes dsl-req))
     (define sso-match
       (find-sso-match
        (if (pair? sso-routes) sso-routes
            (hash-ref sso-routes-registry (sso-registry-key (server-spec-name server)) '()))
        dsl-req))
     (cond
       ;; 0. Runtime-owned SSO routes (/auth/<seg>/login|callback).  Runs the
       ;;    connection/onIdentity/mint-session app code under the server's caps.
       [sso-match (handle-sso-request sso-match dsl-req #:capabilities capabilities)]
       [sse-match
        (with-handlers ([check-fail? (lambda (f)
                                       (dsl-response->http-response
                                        (error-response (check-fail-status f)
                                                        (check-fail-message f))))])
          (handle-sse-request sse-match dsl-req #:capabilities capabilities))]

       ;; 2. Static files (exact match on disk)
       [(try-serve-static dsl-req) => (lambda (r) r)]

       ;; 3. API dispatch
       [else
        (define dispatch-start-ms (and (metrics-active?) (current-inexact-milliseconds)))
        (define result (dispatch-request server dsl-req #:capabilities capabilities))
        ;; Metrics for the 'route-not-found sentinel are recorded HERE, with the
        ;; RESOLVED status (200 SPA fallback vs real 404) — dispatch-request
        ;; deliberately skips the sentinel so healthy SPA page loads are not
        ;; exported as 404s.
        (define (record-unmatched! status)
          (when dispatch-start-ms
            (metric-histogram-record!
             "http.server.request.duration"
             (/ (- (current-inexact-milliseconds) dispatch-start-ms) 1000.0)
             (list (cons "http.request.method" (dsl-request-method dsl-req))
                   (cons "http.response.status_code" (number->string status))
                   (cons "tesl.operation"
                         (if (= status 404) "unmatched" "spa-fallback")))
             #:unit "s"
             #:boundaries duration-histogram-boundaries)))
        ;; 4. SPA fallback: only when no API route matched at all (not when a
        ;;    matched handler explicitly returned a 404 error such as "not found").
        (cond
          [(and (eq? result 'route-not-found)
                index-html-path
                (file-exists? index-html-path))
           (record-unmatched! 200)
           (response/full 200 #"OK" (current-seconds) #"text/html; charset=utf-8" '()
                          (list (file->bytes index-html-path)))]
          [else
           (when (eq? result 'route-not-found) (record-unmatched! 404))
           (dsl-response->http-response
            (if (eq? result 'route-not-found)
                (error-response 404 "Route not found")
                result))])]))
    )
   #:port port
   ;; F2 defense-in-depth (2026-07-30): the per-route wrappers in
   ;; `dispatch-request` contain handler AND auth exceptions, but ANY exception
   ;; that still escapes the servlet lambda must not fall to the web-server's
   ;; default `servlet-error-responder`, which answers 500 with the exception
   ;; message, the full stack trace, and absolute source paths.  Log it
   ;; server-side and answer a bare sanitized 500 in the same JSON shape as
   ;; `error-response`; echo the message only under TESL_VERBOSE.
   #:servlet-responder
   (lambda (url raised)
     (when (exn? raised)
       (fprintf (handler-error-port) "unhandled servlet error: ~a\n"
                (exn-message raised)))
     (response/full
      500 #"Internal Server Error" (current-seconds) APPLICATION/JSON-MIME-TYPE
      (list (make-header #"X-Content-Type-Options" #"nosniff")
            (make-header #"Cache-Control" #"no-store"))
      (list (jsexpr->bytes
             (hash 'ok #f
                   'error "Internal server error"
                   'details (if tesl-verbose?
                                (list (if (exn? raised)
                                          (exn-message raised)
                                          (format "~a" raised)))
                                '()))))))
   #:command-line? #t
   #:launch-browser? #f
   #:quit? #f
   #:banner? #t
   ;; Phase 3: bind to the interface the `listenAddress` clause registered for
   ;; this server (default #f = all interfaces, unchanged from before).
   #:listen-ip (hash-ref listen-address-registry (sso-registry-key (server-spec-name server)) #f)
   #:stateless? #t
   #:servlet-path "/"
   #:servlet-regexp #rx""
   #:connection-close? #f))

;; Register HttpRequest as a runtime type with field access for its fields.
;; This enables dot-access on HttpRequest values:
;;   request.cookies  → pre-parsed Dict of cookie key→value pairs
;;   request.headers  → Dict of header name→value (names lowercased)
;; (request.queryParameters is not yet exposed — see roadmap/next.)
;;; ── #51: client address + the trusted-proxy edge declaration ─────────────────
;;;
;;; `HttpRequest` cannot see who its client is when a reverse proxy (the
;;; documented nginx cluster) sits in front — the socket peer is the proxy.  The
;;; edge is DECLARED (`trustedProxies [...]`), never guessed, so the trust
;;; assumption is visible and an app that never declared one cannot consume a
;;; spoofable header.
;;;
;;;   • no declaration  ⇒ the socket peer (unspoofable; X-Forwarded-For ignored)
;;;   • declaration     ⇒ the RIGHTMOST-UNTRUSTED hop of [XFF…, socket-peer]:
;;;     walk from the right, skip declared proxies, stop at the first address
;;;     that is not one.  A prepended (spoofed) XFF entry sits to the LEFT of the
;;;     real chain and is never reached.
(define current-trusted-proxies (make-parameter '()))

(define (parse-forwarded-for raw)
  (if (or (not raw) (string=? (string-trim raw) ""))
      '()
      (filter (lambda (s) (not (string=? s "")))
              (map string-trim (string-split raw ",")))))

(define (trusted-proxy? addr trusted) (and (member (string-trim addr) trusted) #t))

(define (dsl-request-socket-peer req)
  (define raw (dsl-request-raw-request req))
  (and raw (with-handlers ([exn:fail? (lambda (_e) #f)]) (request-client-ip raw))))

;; The trustworthy client address, computed fail-closed (see the note above).
(define (client-address-of req)
  (define trusted (current-trusted-proxies))
  (define peer (dsl-request-socket-peer req))
  (cond
    [(null? trusted) (or peer "")]
    [else
     (define chain (append (parse-forwarded-for (request-header req "x-forwarded-for" ""))
                           (if peer (list peer) '())))
     (let loop ([rev (reverse chain)])
       (cond
         [(null? rev)
          (error 'clientAddress "trustedProxies declared but the forwarded chain has no untrusted hop")]
         [(trusted-proxy? (car rev) trusted) (loop (cdr rev))]
         [else (string-trim (car rev))]))]))

(register-runtime-type/runtime! 'HttpRequest dsl-request?)
(register-field-access! 'HttpRequest
                        '(cookies headers queryParameters clientAddress)
                        (lambda (value field-name)
                          (case field-name
                            [(headers) (dsl-request-headers value)]
                            [(queryParameters) (dsl-request-query value)]
                            [(clientAddress) (client-address-of value)]
                            [else      (dsl-request-cookies value)])))
