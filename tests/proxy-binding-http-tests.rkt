#lang racket

(require
  tesl/dsl/capability
  tesl/dsl/types
  tesl/dsl/check
  tesl/dsl/otel
  tesl/dsl/sql
  tesl/dsl/web
  tesl/dsl/test-support
  tesl/dsl/debug/checkpoint
  tesl/tesl/private/runtime
  tesl/tesl/queue
  tesl/tesl/sse
  (only-in tesl/tesl/prelude Bool String)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/dict [Dict.lookup tesl_import_Dict_lookup])
  (only-in tesl/tesl/http HttpRequest)
  (only-in tesl/tesl/crypto Secret)
  (only-in tesl/tesl/proxy ProxyBound [Proxy.verifyBinding tesl_import_Proxy_verifyBinding])
  (only-in tesl/tesl/api-test statusOk)
)


(provide EdgeServer)

(define EdgeRequest 'EdgeRequest)

(define/pow
  (makeSecret [s : String])
  #:returns Secret
  (thsl-src! "tests/proxy-binding-http-tests.tesl" 48 (list (cons 's *s)) (lambda () (raw-value (Secret *s)))))

(define/pow
  (proxySecret)
  #:returns Secret
  (thsl-src! "tests/proxy-binding-http-tests.tesl" 51 (list) (lambda () (raw-value (makeSecret "proxy-binding-http-tests-shared-secret")))))

(define-record Internal
  [released : String]
)

(define (tesl-codec-encode-Internal _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'released (tesl-encode-prim-string (raw-value (hash-ref _fields 'released)))
  ))
(register-type-codec! 'Internal tesl-codec-encode-Internal (list ))

(define-record Public
  [alive : Boolean]
)

(define (tesl-codec-encode-Public _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'alive (tesl-encode-prim-bool (raw-value (hash-ref _fields 'alive)))
  ))
(register-type-codec! 'Public tesl-codec-encode-Public (list ))

(define/pow
  (internalOnly [bound : String ::: (ProxyBound bound)])
  #:returns String
  (thsl-src! "tests/proxy-binding-http-tests.tesl" 87 (list (cons 'bound *bound)) (lambda () "internal data released to a proxy-bound request")))

(define-auther
  (edgeAuth [request : HttpRequest])
  #:returns [marker : String ::: (EdgeRequest marker)]
  (thsl-src-control! "tests/proxy-binding-http-tests.tesl" 96 (list (cons 'request *request)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Dict_lookup "x-proxy-binding" (raw-value request.headers)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/proxy-binding-http-tests.tesl" 97 (list) (lambda () (reject "no proxy binding" #:http-code 401)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([presented (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/proxy-binding-http-tests.tesl" 99 (list (cons 'presented presented)) (lambda () (let/check ([tesl-checked-1 (tesl_import_Proxy_verifyBinding (proxySecret) presented)]) (let ([bound tesl-checked-1]) (let ([released (internalOnly bound)]) (accept (EdgeRequest released) #:value *released)))))))])))))

(define-handler
  (internalData [marker : String ::: (EdgeRequest marker)])
  #:returns Internal
  (thsl-src! "tests/proxy-binding-http-tests.tesl" 109 (list (cons 'marker *marker)) (lambda () (Internal #:released *marker))))

(define-handler
  (publicPing)
  #:returns Public
  (thsl-src! "tests/proxy-binding-http-tests.tesl" 114 (list) (lambda () (Public #:alive #t))))

(define EdgeServer-sse-routes '())
(define-api EdgeApi
  [internalData :
    (Auth [marker : String ::: (EdgeRequest marker)] #:via edgeAuth)
    :> "internal"
    :> (Get JSON Internal)
    ]
  [publicPing :
    "ping"
    :> (Get JSON Public)
    ]
)

(define-server EdgeServer
  #:api EdgeApi
  [internalData internalData]
  [publicPing publicPing]
)

(module+ test
  (require rackunit)
  (test-case "a matching binding reaches the ProxyBound-only work"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/proxy-binding-http-tests.tesl" 133 (list) (lambda () (dispatch-api-test-request EdgeServer 'get (list "internal") #:headers (tesl-hash (string->symbol "x-proxy-binding") "proxy-binding-http-tests-shared-secret") #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 134 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 135 (list (cons 'r r)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'released)))) "internal data released to a proxy-bound request")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "the unprotected route answers with no binding at all"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/proxy-binding-http-tests.tesl" 141 (list) (lambda () (dispatch-api-test-request EdgeServer 'get (list "ping") #:headers (tesl-hash) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 142 (list (cons 'r r)) (lambda () (statusOk (raw-value (api-test-field-access-ref r 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 143 (list (cons 'r r)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'alive)))) #t)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "no binding header is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/proxy-binding-http-tests.tesl" 149 (list) (lambda () (dispatch-api-test-request EdgeServer 'get (list "internal") #:headers (tesl-hash) #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 150 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "an empty binding header is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/proxy-binding-http-tests.tesl" 154 (list) (lambda () (dispatch-api-test-request EdgeServer 'get (list "internal") #:headers (tesl-hash (string->symbol "x-proxy-binding") "") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 155 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a wrong binding is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/proxy-binding-http-tests.tesl" 159 (list) (lambda () (dispatch-api-test-request EdgeServer 'get (list "internal") #:headers (tesl-hash (string->symbol "x-proxy-binding") "not-the-shared-secret") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 160 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a binding differing in one character is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/proxy-binding-http-tests.tesl" 166 (list) (lambda () (dispatch-api-test-request EdgeServer 'get (list "internal") #:headers (tesl-hash (string->symbol "x-proxy-binding") "proxy-binding-http-tests-shared-secreT") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 167 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a case-shifted binding is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/proxy-binding-http-tests.tesl" 171 (list) (lambda () (dispatch-api-test-request EdgeServer 'get (list "internal") #:headers (tesl-hash (string->symbol "x-proxy-binding") "PROXY-BINDING-HTTP-TESTS-SHARED-SECRET") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 172 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a prefix or an extension of the binding is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define short (thsl-src! "tests/proxy-binding-http-tests.tesl" 178 (list) (lambda () (dispatch-api-test-request EdgeServer 'get (list "internal") #:headers (tesl-hash (string->symbol "x-proxy-binding") "proxy-binding-http-tests-shared") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 179 (list (cons 'short short)) (lambda () (api-test-field-access-ref short 'status)))) 401)
            (define long (thsl-src! "tests/proxy-binding-http-tests.tesl" 180 (list (cons 'short short)) (lambda () (dispatch-api-test-request EdgeServer 'get (list "internal") #:headers (tesl-hash (string->symbol "x-proxy-binding") "proxy-binding-http-tests-shared-secret-and-more") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 181 (list (cons 'long long) (cons 'short short)) (lambda () (api-test-field-access-ref long 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a whitespace-padded binding is a 401"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define trailing (thsl-src! "tests/proxy-binding-http-tests.tesl" 186 (list) (lambda () (dispatch-api-test-request EdgeServer 'get (list "internal") #:headers (tesl-hash (string->symbol "x-proxy-binding") "proxy-binding-http-tests-shared-secret ") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 187 (list (cons 'trailing trailing)) (lambda () (api-test-field-access-ref trailing 'status)))) 401)
            (define leading (thsl-src! "tests/proxy-binding-http-tests.tesl" 188 (list (cons 'trailing trailing)) (lambda () (dispatch-api-test-request EdgeServer 'get (list "internal") #:headers (tesl-hash (string->symbol "x-proxy-binding") " proxy-binding-http-tests-shared-secret") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 189 (list (cons 'leading leading) (cons 'trailing trailing)) (lambda () (api-test-field-access-ref leading 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a refused binding is a 401, not a 500"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/proxy-binding-http-tests.tesl" 195 (list) (lambda () (dispatch-api-test-request EdgeServer 'get (list "internal") #:headers (tesl-hash (string->symbol "x-proxy-binding") "wrong") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 196 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
            (check-equal? (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 198 (list (cons 'r r)) (lambda () (api-test-field-access-ref (api-test-field-access-ref r 'body) 'error)))) "proxy binding does not match")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a session cookie is not a substitute for the binding"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (thsl-src! "tests/proxy-binding-http-tests.tesl" 204 (list) (lambda () (dispatch-api-test-request EdgeServer 'get (list "internal") #:cookie "__Host-session=anything" #:headers (tesl-hash) #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 205 (list (cons 'r r)) (lambda () (api-test-field-access-ref r 'status)))) 401)
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "a refused request leaves the next good one alone"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define bad (thsl-src! "tests/proxy-binding-http-tests.tesl" 209 (list) (lambda () (dispatch-api-test-request EdgeServer 'get (list "internal") #:headers (tesl-hash (string->symbol "x-proxy-binding") "wrong") #:capabilities '()))))
            (check-equal? (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 210 (list (cons 'bad bad)) (lambda () (api-test-field-access-ref bad 'status)))) 401)
            (define good (thsl-src! "tests/proxy-binding-http-tests.tesl" 211 (list (cons 'bad bad)) (lambda () (dispatch-api-test-request EdgeServer 'get (list "internal") #:headers (tesl-hash (string->symbol "x-proxy-binding") "proxy-binding-http-tests-shared-secret") #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 212 (list (cons 'good good) (cons 'bad bad)) (lambda () (statusOk (raw-value (api-test-field-access-ref good 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/proxy-binding-http-tests.tesl" 213 (list (cons 'good good) (cons 'bad bad)) (lambda () (api-test-field-access-ref (api-test-field-access-ref good 'body) 'released)))) "internal data released to a proxy-bound request")
          ))
      ))
  )
)
