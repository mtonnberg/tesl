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
  (only-in tesl/tesl/prelude Int String Bool List Unit)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/tuple Tuple2 [Tuple2.first tesl_import_Tuple2_first] [Tuple2.second tesl_import_Tuple2_second])
  (only-in tesl/tesl/list [List.head tesl_import_List_head] [List.filter tesl_import_List_filter] [List.any tesl_import_List_any])
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.contains tesl_import_String_contains])
  (only-in tesl/tesl/http-client httpClient HttpResponse [HttpClient.get tesl_import_HttpClient_get] [HttpClient.post tesl_import_HttpClient_post] [HttpClient.put tesl_import_HttpClient_put] [HttpClient.delete tesl_import_HttpClient_delete])
)


(provide isSuccess getStatusClass buildAuthHeader fetchAndExtractBody isOkStatus classifyStatus headersToDict hasJsonContent extractFirstHeader emptyHeadersFetch postWithBody putWithBody deleteResource buildGetHeaders responseIsOk isSuccess-signature getStatusClass-signature buildAuthHeader-signature fetchAndExtractBody-signature isOkStatus-signature classifyStatus-signature hasJsonContent-signature extractFirstHeader-signature headersToDict-signature emptyHeadersFetch-signature postWithBody-signature putWithBody-signature deleteResource-signature buildGetHeaders-signature responseIsOk-signature)

(define-capability webService (implies httpClient))

(define/pow
  (isSuccess [resp : HttpResponse])
  #:returns Boolean
  (thsl-src! "tests/httpclient-tests.tesl" 46 (list (cons 'resp *resp)) (lambda () (and (>= (raw-value resp.status) 200) (< (raw-value resp.status) 300)))))

(define/pow
  (getStatusClass [status : Integer])
  #:returns String
  (thsl-src! "tests/httpclient-tests.tesl" 50 (list (cons 'status *status)) (lambda () (if (and (>= *status 200) (< *status 300)) (raw-value "success") (if (and (>= *status 400) (< *status 500)) (raw-value "client-error") (if (>= *status 500) (raw-value "server-error") (raw-value "other")))))))

(define/pow
  (buildAuthHeader [token : String])
  #:returns (Tuple2 String String)
  (thsl-src! "tests/httpclient-tests.tesl" 61 (list (cons 'token *token)) (lambda () (raw-value (Tuple2 "Authorization" *token)))))

(define/pow
  (fetchAndExtractBody [resp : HttpResponse])
  #:returns String
  (thsl-src! "tests/httpclient-tests.tesl" 65 (list (cons 'resp *resp)) (lambda () (raw-value resp.body))))

(define/pow
  (isOkStatus [resp : HttpResponse])
  #:returns Boolean
  (thsl-src! "tests/httpclient-tests.tesl" 69 (list (cons 'resp *resp)) (lambda () (tesl-equal? (raw-value resp.status) 200))))

(define/pow
  (classifyStatus [resp : HttpResponse])
  #:returns String
  (thsl-src! "tests/httpclient-tests.tesl" 73 (list (cons 'resp *resp)) (lambda () (raw-value (getStatusClass (raw-value resp.status))))))

(define/pow
  (hasHeader [name : String] [headers : (List (Tuple2 String String))])
  #:returns Boolean
  (thsl-src! "tests/httpclient-tests.tesl" 77 (list (cons 'name *name) (cons 'headers *headers)) (lambda () (raw-value (tesl_import_List_any (let () (define/pow (tesl-lambda-0 [h : (Tuple2 String String)]) #:returns Boolean (tesl-equal? (raw-value (tesl_import_Tuple2_first *h)) *name)) tesl-lambda-0) *headers)))))

(define/pow
  (findHeader [name : String] [headers : (List (Tuple2 String String))])
  #:returns (Maybe (Tuple2 String String))
  (thsl-src! "tests/httpclient-tests.tesl" 81 (list (cons 'name *name) (cons 'headers *headers)) (lambda () (raw-value (tesl_import_List_head (raw-value (tesl_import_List_filter (let () (define/pow (tesl-lambda-1 [h : (Tuple2 String String)]) #:returns Boolean (tesl-equal? (raw-value (tesl_import_Tuple2_first *h)) *name)) tesl-lambda-1) *headers)))))))

(define/pow
  (hasJsonContent [headers : (List (Tuple2 String String))])
  #:returns Boolean
  (thsl-src! "tests/httpclient-tests.tesl" 85 (list (cons 'headers *headers)) (lambda () (raw-value (hasHeader "Content-Type" headers)))))

(define/pow
  (extractFirstHeader [headers : (List (Tuple2 String String))])
  #:returns (Maybe String)
  (thsl-src-control! "tests/httpclient-tests.tesl" 89 (list (cons 'headers *headers)) (lambda () (let ([tesl-case-2 (raw-value (tesl_import_List_head *headers))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([h (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "tests/httpclient-tests.tesl" 90 (list (cons 'h h)) (lambda () (raw-value (raw-value (Something (raw-value (tesl_import_Tuple2_first *h))))))))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "tests/httpclient-tests.tesl" 91 (list) (lambda () (raw-value Nothing)))])))))

(define/pow
  (headersToDict [resp : HttpResponse])
  #:returns (List (Tuple2 String String))
  (thsl-src! "tests/httpclient-tests.tesl" 95 (list (cons 'resp *resp)) (lambda () (raw-value resp.headers))))

(define-handler
  (emptyHeadersFetch [url : String])
  #:capabilities [webService]
  #:returns HttpResponse
  (thsl-src! "tests/httpclient-tests.tesl" 104 (list (cons 'url *url)) (lambda () (raw-value (tesl_import_HttpClient_get *url (list))))))

(define-handler
  (postWithBody [url : String] [body : String])
  #:capabilities [webService]
  #:returns HttpResponse
  (let ([headers (thsl-src! "tests/httpclient-tests.tesl" 109 (list (cons 'url *url) (cons 'body *body)) (lambda () (list (Tuple2 "Content-Type" "application/json"))))]) (thsl-src! "tests/httpclient-tests.tesl" 110 (list (cons 'headers *headers) (cons 'url *url) (cons 'body *body)) (lambda () (raw-value (tesl_import_HttpClient_post *url (raw-value headers) *body))))))

(define-handler
  (putWithBody [url : String] [id : String] [body : String])
  #:capabilities [webService]
  #:returns HttpResponse
  (let ([headers (thsl-src! "tests/httpclient-tests.tesl" 115 (list (cons 'url *url) (cons 'id *id) (cons 'body *body)) (lambda () (list (Tuple2 "Content-Type" "application/json"))))]) (thsl-src! "tests/httpclient-tests.tesl" 116 (list (cons 'headers *headers) (cons 'url *url) (cons 'id *id) (cons 'body *body)) (lambda () (raw-value (tesl_import_HttpClient_put *url (raw-value headers) *body))))))

(define-handler
  (deleteResource [url : String] [token : String])
  #:capabilities [webService]
  #:returns HttpResponse
  (let ([authHeader (thsl-src! "tests/httpclient-tests.tesl" 121 (list (cons 'url *url) (cons 'token *token)) (lambda () (raw-value (Tuple2 "Authorization" *token))))]) (thsl-src! "tests/httpclient-tests.tesl" 122 (list (cons 'authHeader *authHeader) (cons 'url *url) (cons 'token *token)) (lambda () (raw-value (tesl_import_HttpClient_delete *url (list *authHeader)))))))

(define-handler
  (buildGetHeaders [url : String] [token : String])
  #:capabilities [webService]
  #:returns HttpResponse
  (let ([authHeader (thsl-src! "tests/httpclient-tests.tesl" 127 (list (cons 'url *url) (cons 'token *token)) (lambda () (buildAuthHeader token)))]) (let ([acceptHeader (thsl-src! "tests/httpclient-tests.tesl" 128 (list (cons 'authHeader *authHeader) (cons 'url *url) (cons 'token *token)) (lambda () (raw-value (Tuple2 "Accept" "application/json"))))]) (thsl-src! "tests/httpclient-tests.tesl" 129 (list (cons 'acceptHeader *acceptHeader) (cons 'authHeader *authHeader) (cons 'url *url) (cons 'token *token)) (lambda () (raw-value (tesl_import_HttpClient_get *url (list *authHeader *acceptHeader))))))))

(define-handler
  (responseIsOk [url : String])
  #:capabilities [webService]
  #:returns Boolean
  (let ([resp (thsl-src! "tests/httpclient-tests.tesl" 134 (list (cons 'url *url)) (lambda () (raw-value (tesl_import_HttpClient_get *url (list)))))]) (thsl-src! "tests/httpclient-tests.tesl" 135 (list (cons 'resp *resp) (cons 'url *url)) (lambda () (isOkStatus resp)))))

(module+ test
  (require rackunit)
  (test-case "getStatusClass for success codes"
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 142 (list) (lambda () (getStatusClass 200)))) "success")
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 143 (list) (lambda () (getStatusClass 201)))) "success")
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 144 (list) (lambda () (getStatusClass 204)))) "success")
  )

  (test-case "getStatusClass for client error codes"
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 148 (list) (lambda () (getStatusClass 400)))) "client-error")
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 149 (list) (lambda () (getStatusClass 404)))) "client-error")
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 150 (list) (lambda () (getStatusClass 422)))) "client-error")
  )

  (test-case "getStatusClass for server error codes"
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 154 (list) (lambda () (getStatusClass 500)))) "server-error")
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 155 (list) (lambda () (getStatusClass 503)))) "server-error")
  )

  (test-case "getStatusClass for other codes"
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 159 (list) (lambda () (getStatusClass 100)))) "other")
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 160 (list) (lambda () (getStatusClass 301)))) "other")
  )

  (test-case "buildAuthHeader creates correct tuple"
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 164 (list) (lambda () (raw-value (tesl_import_Tuple2_first (raw-value (buildAuthHeader "Bearer abc"))))))) "Authorization")
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 165 (list) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value (buildAuthHeader "Bearer abc"))))))) "Bearer abc")
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 166 (list) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value (buildAuthHeader ""))))))) "")
  )

  (test-case "extractFirstHeader with empty list returns Nothing"
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 170 (list) (lambda () (extractFirstHeader (list))))) Nothing)
  )

  (test-case "extractFirstHeader with non-empty list returns Something"
  (define headers (thsl-src! "tests/httpclient-tests.tesl" 174 (list) (lambda () (list (Tuple2 "Content-Type" "application/json")))))
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 175 (list (cons 'headers headers)) (lambda () (extractFirstHeader headers)))) (raw-value (Something "Content-Type")))
  )

  (test-case "hasHeader returns correct results"
  (define headers (thsl-src! "tests/httpclient-tests.tesl" 179 (list) (lambda () (list (Tuple2 "Authorization" "Bearer token") (Tuple2 "Accept" "application/json")))))
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 180 (list (cons 'headers headers)) (lambda () (hasHeader "Authorization" headers)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 181 (list (cons 'headers headers)) (lambda () (hasHeader "Accept" headers)))) #t)
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 182 (list (cons 'headers headers)) (lambda () (hasHeader "X-Custom" headers)))) #f)
  )

  (test-case "hasHeader with empty headers is always False"
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 186 (list) (lambda () (hasHeader "Authorization" (list))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/httpclient-tests.tesl" 187 (list) (lambda () (hasHeader "Content-Type" (list))))) #f)
  )

)
