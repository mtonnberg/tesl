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
  (only-in tesl/tesl/prelude Int String Bool)
  (only-in tesl/tesl/tuple Tuple2 [Tuple2.first tesl_import_Tuple2_first] [Tuple2.second tesl_import_Tuple2_second])
  (only-in tesl/tesl/string [String.concat tesl_import_String_concat] [String.contains tesl_import_String_contains])
  (only-in tesl/tesl/http-client httpClient HttpResponse [HttpClient.get tesl_import_HttpClient_get] [HttpClient.post tesl_import_HttpClient_post])
  (only-in tesl/tesl/api-test stubHttp stubHttpFailure stubHttpTimeout httpCalled httpCallCount httpLastBody)
)


(provide fetchJson fetchWithBearer postJson classifyStatusCode isSuccessCode buildBearerHeader isSuccessCode-signature classifyStatusCode-signature buildBearerHeader-signature fetchJson-signature fetchWithBearer-signature postJson-signature)

(define-capability webClient (implies httpClient))

(define/pow
  (isSuccessCode [code : Integer])
  #:returns Boolean
  (thsl-src! "example/learn/lesson58-httpclient.tesl" 76 (list (cons 'code *code)) (lambda () (and (>= *code 200) (< *code 300)))))

(define/pow
  (classifyStatusCode [code : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson58-httpclient.tesl" 81 (list (cons 'code *code)) (lambda () (if (and (>= *code 200) (< *code 300)) (raw-value "success") (if (and (>= *code 400) (< *code 500)) (raw-value "client-error") (if (>= *code 500) (raw-value "server-error") (raw-value "redirect-or-info")))))))

(define/pow
  (buildBearerHeader [token : String])
  #:returns (Tuple2 String String)
  (thsl-src! "example/learn/lesson58-httpclient.tesl" 93 (list (cons 'token *token)) (lambda () (raw-value (Tuple2 "Authorization" (raw-value (tesl_import_String_concat "Bearer " *token)))))))

(define-handler
  (fetchJson [url : String])
  #:capabilities [webClient]
  #:returns HttpResponse
  (thsl-src! "example/learn/lesson58-httpclient.tesl" 107 (list (cons 'url *url)) (lambda () (raw-value (tesl_import_HttpClient_get *url (list))))))

(define-handler
  (fetchWithBearer [url : String] [token : String])
  #:capabilities [webClient]
  #:returns HttpResponse
  (let ([authHeader (thsl-src! "example/learn/lesson58-httpclient.tesl" 113 (list (cons 'url *url) (cons 'token *token)) (lambda () (buildBearerHeader token)))]) (let ([acceptHeader (thsl-src! "example/learn/lesson58-httpclient.tesl" 114 (list (cons 'authHeader *authHeader) (cons 'url *url) (cons 'token *token)) (lambda () (raw-value (Tuple2 "Accept" "application/json"))))]) (thsl-src! "example/learn/lesson58-httpclient.tesl" 115 (list (cons 'acceptHeader *acceptHeader) (cons 'authHeader *authHeader) (cons 'url *url) (cons 'token *token)) (lambda () (raw-value (tesl_import_HttpClient_get *url (list *authHeader *acceptHeader))))))))

(define-handler
  (postJson [url : String] [jsonBody : String] [token : String])
  #:capabilities [webClient]
  #:returns HttpResponse
  (let ([authHeader (thsl-src! "example/learn/lesson58-httpclient.tesl" 121 (list (cons 'url *url) (cons 'jsonBody *jsonBody) (cons 'token *token)) (lambda () (buildBearerHeader token)))]) (let ([contentType (thsl-src! "example/learn/lesson58-httpclient.tesl" 122 (list (cons 'authHeader *authHeader) (cons 'url *url) (cons 'jsonBody *jsonBody) (cons 'token *token)) (lambda () (raw-value (Tuple2 "Content-Type" "application/json"))))]) (thsl-src! "example/learn/lesson58-httpclient.tesl" 123 (list (cons 'contentType *contentType) (cons 'authHeader *authHeader) (cons 'url *url) (cons 'jsonBody *jsonBody) (cons 'token *token)) (lambda () (raw-value (tesl_import_HttpClient_post *url (list *authHeader *contentType) *jsonBody)))))))

(module+ test
  (require rackunit)
  (test-case "classifyStatusCode: 200-series are success"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 198 (list) (lambda () (classifyStatusCode 200)))) "success")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 199 (list) (lambda () (classifyStatusCode 201)))) "success")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 200 (list) (lambda () (classifyStatusCode 204)))) "success")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 201 (list) (lambda () (classifyStatusCode 299)))) "success")
    ))
  )

  (test-case "classifyStatusCode: 4xx are client-error"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 205 (list) (lambda () (classifyStatusCode 400)))) "client-error")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 206 (list) (lambda () (classifyStatusCode 404)))) "client-error")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 207 (list) (lambda () (classifyStatusCode 422)))) "client-error")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 208 (list) (lambda () (classifyStatusCode 429)))) "client-error")
    ))
  )

  (test-case "classifyStatusCode: 5xx are server-error"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 212 (list) (lambda () (classifyStatusCode 500)))) "server-error")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 213 (list) (lambda () (classifyStatusCode 502)))) "server-error")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 214 (list) (lambda () (classifyStatusCode 503)))) "server-error")
    ))
  )

  (test-case "classifyStatusCode: redirects and info"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 218 (list) (lambda () (classifyStatusCode 301)))) "redirect-or-info")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 219 (list) (lambda () (classifyStatusCode 302)))) "redirect-or-info")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 220 (list) (lambda () (classifyStatusCode 100)))) "redirect-or-info")
    ))
  )

  (test-case "isSuccessCode identifies 2xx"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 224 (list) (lambda () (isSuccessCode 200)))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 225 (list) (lambda () (isSuccessCode 201)))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 226 (list) (lambda () (isSuccessCode 204)))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 227 (list) (lambda () (isSuccessCode 399)))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 228 (list) (lambda () (isSuccessCode 404)))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 229 (list) (lambda () (isSuccessCode 500)))) #f)
    ))
  )

  (test-case "buildBearerHeader creates correct Authorization header"
    (call-with-fresh-memory-db '() (lambda ()
  (define h (thsl-src! "example/learn/lesson58-httpclient.tesl" 233 (list) (lambda () (buildBearerHeader "mytoken123"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 234 (list (cons 'h h)) (lambda () (raw-value (tesl_import_Tuple2_first (raw-value h)))))) "Authorization")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 235 (list (cons 'h h)) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value h)))))) "Bearer mytoken123")
    ))
  )

  (test-case "buildBearerHeader with API key token"
    (call-with-fresh-memory-db '() (lambda ()
  (define h (thsl-src! "example/learn/lesson58-httpclient.tesl" 239 (list) (lambda () (buildBearerHeader "sk-abc123xyz"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 240 (list (cons 'h h)) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value h)))))) "Bearer sk-abc123xyz")
    ))
  )

  (test-case "fetchJson returns the upstream response"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "GET" "https://api.example.com/rates" 200 "{\"usd\": 110}"))
    (define resp (thsl-src! "example/learn/lesson58-httpclient.tesl" 251 (list) (lambda () (fetchJson "https://api.example.com/rates"))))
    (check-equal? (thsl-src! "example/learn/lesson58-httpclient.tesl" 252 (list (cons 'resp resp)) (lambda () (raw-value (tesl-dot/runtime resp 'status)))) 200)
    (check-equal? (thsl-src! "example/learn/lesson58-httpclient.tesl" 253 (list (cons 'resp resp)) (lambda () (raw-value (tesl-dot/runtime resp 'body)))) "{\"usd\": 110}")
    (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 254 (list (cons 'resp resp)) (lambda () (isSuccessCode (raw-value (tesl-dot/runtime resp 'status)))))) #t)
    (check-true (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 255 (list (cons 'resp resp)) (lambda () (raw-value (httpCalled "GET" "https://api.example.com/rates"))))))
    )
    ))
  )

  (test-case "postJson sends the body it was given"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "POST" "https://api.example.com/events" 202 "{\"accepted\": True}"))
    (define resp (thsl-src! "example/learn/lesson58-httpclient.tesl" 260 (list) (lambda () (postJson "https://api.example.com/events" "{\"kind\": \"signup\"}" "sk-abc123"))))
    (check-equal? (thsl-src! "example/learn/lesson58-httpclient.tesl" 261 (list (cons 'resp resp)) (lambda () (raw-value (tesl-dot/runtime resp 'status)))) 202)
    (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 262 (list (cons 'resp resp)) (lambda () (raw-value (httpLastBody "POST" "https://api.example.com/events"))))) "{\"kind\": \"signup\"}")
    (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 263 (list (cons 'resp resp)) (lambda () (raw-value (httpCallCount "POST" "https://api.example.com/events"))))) 1)
    )
    ))
  )

  (test-case "the upstream-500 branch is reachable"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "GET" "https://api.example.com/rates" 500 "upstream exploded"))
    (define resp (thsl-src! "example/learn/lesson58-httpclient.tesl" 268 (list) (lambda () (fetchJson "https://api.example.com/rates"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 269 (list (cons 'resp resp)) (lambda () (classifyStatusCode (raw-value (tesl-dot/runtime resp 'status)))))) "server-error")
    (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 270 (list (cons 'resp resp)) (lambda () (isSuccessCode (raw-value (tesl-dot/runtime resp 'status)))))) #f)
    )
    ))
  )

  (test-case "the malformed-body branch is reachable"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "GET" "https://api.example.com/rates" 200 "<html>not json</html>"))
    (define resp (thsl-src! "example/learn/lesson58-httpclient.tesl" 275 (list) (lambda () (fetchJson "https://api.example.com/rates"))))
    (check-equal? (thsl-src! "example/learn/lesson58-httpclient.tesl" 276 (list (cons 'resp resp)) (lambda () (raw-value (tesl-dot/runtime resp 'status)))) 200)
    (check-true (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 277 (list (cons 'resp resp)) (lambda () (tesl_import_String_contains (raw-value (tesl-dot/runtime resp 'body)) "not json")))))
    )
    ))
  )

  (test-case "a hung upstream fails the call instead of hanging it"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttpTimeout "GET" "https://api.example.com/slow"))
    (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson58-httpclient.tesl" 282 (list) (lambda ()
                            (fetchJson "https://api.example.com/slow"))))])
      (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                  "expected failure: fetchJson \"https://api.example.com/slow\""))
    )
    ))
  )

  (test-case "a refused connection fails the call"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttpFailure "GET" "https://api.example.com/down" "connection refused"))
    (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson58-httpclient.tesl" 287 (list) (lambda ()
                            (fetchJson "https://api.example.com/down"))))])
      (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                  "expected failure: fetchJson \"https://api.example.com/down\""))
    )
    ))
  )

  (test-case "fetchWithBearer authenticates and reads the answer"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "GET" "https://api.example.com/me" 200 "{\"id\": \"u-1\"}"))
    (define resp (thsl-src! "example/learn/lesson58-httpclient.tesl" 292 (list) (lambda () (fetchWithBearer "https://api.example.com/me" "sk-abc123"))))
    (check-equal? (thsl-src! "example/learn/lesson58-httpclient.tesl" 293 (list (cons 'resp resp)) (lambda () (raw-value (tesl-dot/runtime resp 'status)))) 200)
    (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 294 (list (cons 'resp resp)) (lambda () (raw-value (httpCallCount "GET" "https://api.example.com/me"))))) 1)
    )
    ))
  )

)
