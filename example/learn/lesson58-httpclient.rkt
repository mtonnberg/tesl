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
  (only-in tesl/tesl/string [String.concat tesl_import_String_concat])
  (only-in tesl/tesl/http-client httpClient HttpResponse [HttpClient.get tesl_import_HttpClient_get] [HttpClient.post tesl_import_HttpClient_post])
)


(provide fetchJson fetchWithBearer postJson classifyStatusCode isSuccessCode buildBearerHeader isSuccessCode-signature classifyStatusCode-signature buildBearerHeader-signature fetchJson-signature fetchWithBearer-signature postJson-signature)

(define-capability webClient (implies httpClient))

(define/pow
  (isSuccessCode [code : Integer])
  #:returns Boolean
  (thsl-src! "example/learn/lesson58-httpclient.tesl" 66 (list (cons 'code *code)) (lambda () (and (>= *code 200) (< *code 300)))))

(define/pow
  (classifyStatusCode [code : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson58-httpclient.tesl" 71 (list (cons 'code *code)) (lambda () (if (and (>= *code 200) (< *code 300)) (raw-value "success") (if (and (>= *code 400) (< *code 500)) (raw-value "client-error") (if (>= *code 500) (raw-value "server-error") (raw-value "redirect-or-info")))))))

(define/pow
  (buildBearerHeader [token : String])
  #:returns (Tuple2 String String)
  (thsl-src! "example/learn/lesson58-httpclient.tesl" 83 (list (cons 'token *token)) (lambda () (raw-value (Tuple2 "Authorization" (raw-value (tesl_import_String_concat "Bearer " *token)))))))

(define-handler
  (fetchJson [url : String])
  #:capabilities [webClient]
  #:returns HttpResponse
  (thsl-src! "example/learn/lesson58-httpclient.tesl" 97 (list (cons 'url *url)) (lambda () (raw-value (tesl_import_HttpClient_get *url (list))))))

(define-handler
  (fetchWithBearer [url : String] [token : String])
  #:capabilities [webClient]
  #:returns HttpResponse
  (let ([authHeader (thsl-src! "example/learn/lesson58-httpclient.tesl" 103 (list (cons 'url *url) (cons 'token *token)) (lambda () (buildBearerHeader token)))]) (let ([acceptHeader (thsl-src! "example/learn/lesson58-httpclient.tesl" 104 (list (cons 'authHeader *authHeader) (cons 'url *url) (cons 'token *token)) (lambda () (raw-value (Tuple2 "Accept" "application/json"))))]) (thsl-src! "example/learn/lesson58-httpclient.tesl" 105 (list (cons 'acceptHeader *acceptHeader) (cons 'authHeader *authHeader) (cons 'url *url) (cons 'token *token)) (lambda () (raw-value (tesl_import_HttpClient_get *url (list *authHeader *acceptHeader))))))))

(define-handler
  (postJson [url : String] [jsonBody : String] [token : String])
  #:capabilities [webClient]
  #:returns HttpResponse
  (let ([authHeader (thsl-src! "example/learn/lesson58-httpclient.tesl" 111 (list (cons 'url *url) (cons 'jsonBody *jsonBody) (cons 'token *token)) (lambda () (buildBearerHeader token)))]) (let ([contentType (thsl-src! "example/learn/lesson58-httpclient.tesl" 112 (list (cons 'authHeader *authHeader) (cons 'url *url) (cons 'jsonBody *jsonBody) (cons 'token *token)) (lambda () (raw-value (Tuple2 "Content-Type" "application/json"))))]) (thsl-src! "example/learn/lesson58-httpclient.tesl" 113 (list (cons 'contentType *contentType) (cons 'authHeader *authHeader) (cons 'url *url) (cons 'jsonBody *jsonBody) (cons 'token *token)) (lambda () (raw-value (tesl_import_HttpClient_post *url (list *authHeader *contentType) *jsonBody)))))))

(module+ test
  (require rackunit)
  (test-case "classifyStatusCode: 200-series are success"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 154 (list) (lambda () (classifyStatusCode 200)))) "success")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 155 (list) (lambda () (classifyStatusCode 201)))) "success")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 156 (list) (lambda () (classifyStatusCode 204)))) "success")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 157 (list) (lambda () (classifyStatusCode 299)))) "success")
    ))
  )

  (test-case "classifyStatusCode: 4xx are client-error"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 161 (list) (lambda () (classifyStatusCode 400)))) "client-error")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 162 (list) (lambda () (classifyStatusCode 404)))) "client-error")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 163 (list) (lambda () (classifyStatusCode 422)))) "client-error")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 164 (list) (lambda () (classifyStatusCode 429)))) "client-error")
    ))
  )

  (test-case "classifyStatusCode: 5xx are server-error"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 168 (list) (lambda () (classifyStatusCode 500)))) "server-error")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 169 (list) (lambda () (classifyStatusCode 502)))) "server-error")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 170 (list) (lambda () (classifyStatusCode 503)))) "server-error")
    ))
  )

  (test-case "classifyStatusCode: redirects and info"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 174 (list) (lambda () (classifyStatusCode 301)))) "redirect-or-info")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 175 (list) (lambda () (classifyStatusCode 302)))) "redirect-or-info")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 176 (list) (lambda () (classifyStatusCode 100)))) "redirect-or-info")
    ))
  )

  (test-case "isSuccessCode identifies 2xx"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 180 (list) (lambda () (isSuccessCode 200)))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 181 (list) (lambda () (isSuccessCode 201)))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 182 (list) (lambda () (isSuccessCode 204)))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 183 (list) (lambda () (isSuccessCode 399)))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 184 (list) (lambda () (isSuccessCode 404)))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 185 (list) (lambda () (isSuccessCode 500)))) #f)
    ))
  )

  (test-case "buildBearerHeader creates correct Authorization header"
    (call-with-fresh-memory-db '() (lambda ()
  (define h (thsl-src! "example/learn/lesson58-httpclient.tesl" 189 (list) (lambda () (buildBearerHeader "mytoken123"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 190 (list (cons 'h h)) (lambda () (raw-value (tesl_import_Tuple2_first (raw-value h)))))) "Authorization")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 191 (list (cons 'h h)) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value h)))))) "Bearer mytoken123")
    ))
  )

  (test-case "buildBearerHeader with API key token"
    (call-with-fresh-memory-db '() (lambda ()
  (define h (thsl-src! "example/learn/lesson58-httpclient.tesl" 195 (list) (lambda () (buildBearerHeader "sk-abc123xyz"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson58-httpclient.tesl" 196 (list (cons 'h h)) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value h)))))) "Bearer sk-abc123xyz")
    ))
  )

)
