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
  (only-in tesl/tesl/prelude Bool String List)
  (only-in tesl/tesl/list [List.length tesl_import_List_length])
  (only-in tesl/tesl/string [String.contains tesl_import_String_contains])
  (only-in tesl/tesl/queue FromQueue deadJobs queueRead queueWrite)
  (only-in tesl/tesl/http-client httpClient HttpResponse [HttpClient.get tesl_import_HttpClient_get] [HttpClient.post tesl_import_HttpClient_post])
  (only-in tesl/tesl/api-test statusOk JobResult JobOk JobFailed processNextJob pendingJobCount expectJobFailed stubHttp stubHttpFailure stubHttpTimeout httpCalled httpCallCount httpLastBody)
)


(provide )

(define-capability webClient (implies httpClient))

(define/pow
  (fetchRates [url : String])
  #:capabilities [webClient]
  #:returns HttpResponse
  (thsl-src! "tests/http-stub-tests.tesl" 65 (list (cons 'url *url)) (lambda () (raw-value (tesl_import_HttpClient_get *url (list))))))

(define/pow
  (pushRates [url : String] [payload : String])
  #:capabilities [webClient]
  #:returns HttpResponse
  (thsl-src! "tests/http-stub-tests.tesl" 69 (list (cons 'url *url) (cons 'payload *payload)) (lambda () (raw-value (tesl_import_HttpClient_post *url (list) *payload)))))

(define-database SyncDb
  #:backend memory
  #:schema httpstubsync
  #:entities )

(define-record SyncJob
  [tag : String]
)

(define-queue SyncQueue
  #:database SyncDb
  #:job-types (SyncJob)
  #:max-attempts 2
  #:backoff fixed
  #:initial-delay 1)

(define/pow
  (syncWorker [job : SyncJob ::: (FromQueue (Id == jobId) job)])
  #:capabilities [queueRead webClient]
  #:returns SyncJob
  (let ([_resp (thsl-src! "tests/http-stub-tests.tesl" 232 (list (cons 'job *job)) (lambda () (fetchRates "https://upstream.test/sync")))]) (thsl-src! "tests/http-stub-tests.tesl" 233 (list (cons '_resp *_resp) (cons 'job *job)) (lambda () *job))))

(define-record SyncRequest
  [tag : String]
)

(define (tesl-codec-encode-SyncRequest _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'tag (tesl-encode-prim-string (raw-value (hash-ref _fields 'tag)))
  ))
(define (tesl-codec-decode-SyncRequest-0 _j)
  (define _f_tag (tesl-decode-prim-field _j "tag" tesl-decode-prim-string))
  (record-value 'SyncRequest (tesl-hash 'tag _f_tag)))
(register-type-codec! 'SyncRequest tesl-codec-encode-SyncRequest (list tesl-codec-decode-SyncRequest-0))

(define-handler
  (startSync [req : SyncRequest])
  #:capabilities [queueWrite]
  #:returns String
  (let ([_ (thsl-src! "tests/http-stub-tests.tesl" 252 (list (cons 'req *req)) (lambda () (enqueue! SyncQueue (SyncJob #:tag (raw-value req.tag)))))]) (thsl-src! "tests/http-stub-tests.tesl" 253 (list (cons 'req *req)) (lambda () "queued"))))

(define SyncServer-sse-routes '())
(define-api SyncApi
  [startSync :
    "sync"
    :> (ReqBody JSON [req : SyncRequest])
    :> (Post JSON String)
    ]
)

(define-server SyncServer
  #:api SyncApi
  [startSync startSync]
)

(module+ test
  (require rackunit)
  (test-case "STUB-15: upstream timeout in a worker fails the job then dead-letters"
    (call-with-fresh-memory-db (list SyncDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (queueRead queueWrite webClient)
              (thsl-src! "tests/http-stub-tests.tesl" 266 (list) (lambda () (stubHttpTimeout "GET" "https://upstream.test/sync")))
              (define queued (thsl-src! "tests/http-stub-tests.tesl" 268 (list) (lambda () (dispatch-api-test-request SyncServer 'post (list "sync") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "tag") "nightly") #:capabilities (list queueRead queueWrite webClient)))))
              (check-true (raw-value (thsl-src! "tests/http-stub-tests.tesl" 269 (list (cons 'queued queued)) (lambda () (statusOk (raw-value (api-test-field-access-ref queued 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 270 (list (cons 'queued queued)) (lambda () (pendingJobCount SyncQueue)))) 1)
              (define first (thsl-src! "tests/http-stub-tests.tesl" 274 (list (cons 'queued queued)) (lambda () (processNextJob SyncQueue))))
              (define firstError (thsl-src! "tests/http-stub-tests.tesl" 275 (list (cons 'first first) (cons 'queued queued)) (lambda () (expectJobFailed (raw-value first)))))
              (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 276 (list (cons 'firstError firstError) (cons 'first first) (cons 'queued queued)) (lambda () (pendingJobCount SyncQueue)))) 1)
              (define second (thsl-src! "tests/http-stub-tests.tesl" 279 (list (cons 'firstError firstError) (cons 'first first) (cons 'queued queued)) (lambda () (processNextJob SyncQueue))))
              (define secondError (thsl-src! "tests/http-stub-tests.tesl" 280 (list (cons 'second second) (cons 'firstError firstError) (cons 'first first) (cons 'queued queued)) (lambda () (expectJobFailed (raw-value second)))))
              (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 281 (list (cons 'secondError secondError) (cons 'second second) (cons 'firstError firstError) (cons 'first first) (cons 'queued queued)) (lambda () (pendingJobCount SyncQueue)))) 0)
              (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 282 (list (cons 'secondError secondError) (cons 'second second) (cons 'firstError firstError) (cons 'first first) (cons 'queued queued)) (lambda () (tesl_import_List_length (deadJobs SyncQueue))))) 1)
              (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 285 (list (cons 'secondError secondError) (cons 'second second) (cons 'firstError firstError) (cons 'first first) (cons 'queued queued)) (lambda () (httpCallCount "GET" "https://upstream.test/sync")))) 2)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "STUB-16: the same worker succeeds when the upstream answers"
    (call-with-fresh-memory-db (list SyncDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (queueRead queueWrite webClient)
              (thsl-src! "tests/http-stub-tests.tesl" 289 (list) (lambda () (stubHttp "GET" "https://upstream.test/sync" 200 "ok")))
              (define queued (thsl-src! "tests/http-stub-tests.tesl" 291 (list) (lambda () (dispatch-api-test-request SyncServer 'post (list "sync") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "tag") "nightly") #:capabilities (list queueRead queueWrite webClient)))))
              (check-true (raw-value (thsl-src! "tests/http-stub-tests.tesl" 292 (list (cons 'queued queued)) (lambda () (statusOk (raw-value (api-test-field-access-ref queued 'status)))))))
              (define done (thsl-src! "tests/http-stub-tests.tesl" 294 (list (cons 'queued queued)) (lambda () (processNextJob SyncQueue))))
              (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 295 (list (cons 'done done) (cons 'queued queued)) (lambda () (pendingJobCount SyncQueue)))) 0)
              (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 296 (list (cons 'done done) (cons 'queued queued)) (lambda () (tesl_import_List_length (deadJobs SyncQueue))))) 0)
              (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 297 (list (cons 'done done) (cons 'queued queued)) (lambda () (httpCallCount "GET" "https://upstream.test/sync")))) 1)
            )
          ))
      ))
  )
)

(define SyncQueueWorkers
  (list (cons SyncQueue syncWorker)))
(register-api-test-workers! (list (list SyncQueue 'SyncJob syncWorker)))

(module+ test
  (require rackunit)
  (test-case "STUB-01: a canned response answers without touching the network"
    (call-with-fresh-memory-db (list SyncDb) (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "GET" "https://rates.test/v1" 200 "{\"usd\": 110}"))
    (define r (thsl-src! "tests/http-stub-tests.tesl" 75 (list) (lambda () (fetchRates "https://rates.test/v1"))))
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 76 (list (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r 'status)))) 200)
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 77 (list (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r 'body)))) "{\"usd\": 110}")
    )
    ))
  )

  (test-case "STUB-02: the method is part of the match"
    (call-with-fresh-memory-db (list SyncDb) (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "GET" "https://rates.test/v1" 200 "get-answer"))
    (raw-value (stubHttp "POST" "https://rates.test/v1" 201 "post-answer"))
    (define g (thsl-src! "tests/http-stub-tests.tesl" 83 (list) (lambda () (fetchRates "https://rates.test/v1"))))
    (define p (thsl-src! "tests/http-stub-tests.tesl" 84 (list (cons 'g g)) (lambda () (pushRates "https://rates.test/v1" "payload"))))
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 85 (list (cons 'p p) (cons 'g g)) (lambda () (raw-value (tesl-dot/runtime g 'body)))) "get-answer")
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 86 (list (cons 'p p) (cons 'g g)) (lambda () (raw-value (tesl-dot/runtime p 'body)))) "post-answer")
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 87 (list (cons 'p p) (cons 'g g)) (lambda () (raw-value (tesl-dot/runtime p 'status)))) 201)
    )
    ))
  )

  (test-case "STUB-03: a trailing * matches a URL prefix"
    (call-with-fresh-memory-db (list SyncDb) (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "*" "https://rates.test/*" 200 "wildcard"))
    (define a (thsl-src! "tests/http-stub-tests.tesl" 92 (list) (lambda () (fetchRates "https://rates.test/v1"))))
    (define b (thsl-src! "tests/http-stub-tests.tesl" 93 (list (cons 'a a)) (lambda () (fetchRates "https://rates.test/v2?since=1"))))
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 94 (list (cons 'b b) (cons 'a a)) (lambda () (raw-value (tesl-dot/runtime a 'body)))) "wildcard")
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 95 (list (cons 'b b) (cons 'a a)) (lambda () (raw-value (tesl-dot/runtime b 'body)))) "wildcard")
    )
    ))
  )

  (test-case "STUB-04: the first declared match wins, so a specific stub beats a catch-all"
    (call-with-fresh-memory-db (list SyncDb) (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "GET" "https://rates.test/v1" 200 "specific"))
    (raw-value (stubHttp "*" "*" 500 "catch-all"))
    (define a (thsl-src! "tests/http-stub-tests.tesl" 101 (list) (lambda () (fetchRates "https://rates.test/v1"))))
    (define b (thsl-src! "tests/http-stub-tests.tesl" 102 (list (cons 'a a)) (lambda () (fetchRates "https://rates.test/other"))))
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 103 (list (cons 'b b) (cons 'a a)) (lambda () (raw-value (tesl-dot/runtime a 'body)))) "specific")
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 104 (list (cons 'b b) (cons 'a a)) (lambda () (raw-value (tesl-dot/runtime b 'status)))) 500)
    )
    ))
  )

  (test-case "STUB-05: re-stubbing the same method+url replaces the earlier rule"
    (call-with-fresh-memory-db (list SyncDb) (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "GET" "https://rates.test/v1" 200 "first"))
    (raw-value (stubHttp "GET" "https://rates.test/v1" 200 "second"))
    (define r (thsl-src! "tests/http-stub-tests.tesl" 110 (list) (lambda () (fetchRates "https://rates.test/v1"))))
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 111 (list (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r 'body)))) "second")
    )
    ))
  )

  (test-case "STUB-06: an upstream 500 is reachable"
    (call-with-fresh-memory-db (list SyncDb) (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "GET" "https://rates.test/v1" 500 "upstream exploded"))
    (define r (thsl-src! "tests/http-stub-tests.tesl" 118 (list) (lambda () (fetchRates "https://rates.test/v1"))))
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 119 (list (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r 'status)))) 500)
    )
    ))
  )

  (test-case "STUB-07: malformed JSON is reachable"
    (call-with-fresh-memory-db (list SyncDb) (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "GET" "https://rates.test/v1" 200 "not json at all {"))
    (define r (thsl-src! "tests/http-stub-tests.tesl" 124 (list) (lambda () (fetchRates "https://rates.test/v1"))))
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 125 (list (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r 'status)))) 200)
    (check-true (raw-value (thsl-src! "tests/http-stub-tests.tesl" 126 (list (cons 'r r)) (lambda () (tesl_import_String_contains (raw-value (tesl-dot/runtime r 'body)) "not json")))))
    )
    ))
  )

  (test-case "STUB-08: a connection failure is reachable"
    (call-with-fresh-memory-db (list SyncDb) (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttpFailure "GET" "https://rates.test/v1" "connection refused"))
    (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/http-stub-tests.tesl" 131 (list) (lambda ()
                            (fetchRates "https://rates.test/v1"))))])
      (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                  "expected failure: fetchRates \"https://rates.test/v1\""))
    )
    ))
  )

  (test-case "STUB-09: a timeout is reachable"
    (call-with-fresh-memory-db (list SyncDb) (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttpTimeout "GET" "https://rates.test/v1"))
    (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/http-stub-tests.tesl" 136 (list) (lambda ()
                            (fetchRates "https://rates.test/v1"))))])
      (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                  "expected failure: fetchRates \"https://rates.test/v1\""))
    )
    ))
  )

  (test-case "STUB-10: an unstubbed call fails loudly instead of reaching the network"
    (call-with-fresh-memory-db (list SyncDb) (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "GET" "https://rates.test/v1" 200 "ok"))
    (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/http-stub-tests.tesl" 141 (list) (lambda ()
                            (fetchRates "https://elsewhere.test/v1"))))])
      (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                  "expected failure: fetchRates \"https://elsewhere.test/v1\""))
    )
    ))
  )

  (test-case "STUB-11: httpCalled / httpCallCount observe the outbound calls"
    (call-with-fresh-memory-db (list SyncDb) (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "*" "*" 200 "ok"))
    (define a (thsl-src! "tests/http-stub-tests.tesl" 148 (list) (lambda () (fetchRates "https://rates.test/v1"))))
    (define b (thsl-src! "tests/http-stub-tests.tesl" 149 (list (cons 'a a)) (lambda () (fetchRates "https://rates.test/v1"))))
    (define c (thsl-src! "tests/http-stub-tests.tesl" 150 (list (cons 'b b) (cons 'a a)) (lambda () (pushRates "https://rates.test/log" "hello"))))
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 151 (list (cons 'c c) (cons 'b b) (cons 'a a)) (lambda () (raw-value (tesl-dot/runtime a 'status)))) 200)
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 152 (list (cons 'c c) (cons 'b b) (cons 'a a)) (lambda () (raw-value (tesl-dot/runtime b 'status)))) 200)
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 153 (list (cons 'c c) (cons 'b b) (cons 'a a)) (lambda () (raw-value (tesl-dot/runtime c 'status)))) 200)
    (check-true (raw-value (thsl-src! "tests/http-stub-tests.tesl" 154 (list (cons 'c c) (cons 'b b) (cons 'a a)) (lambda () (raw-value (httpCalled "GET" "https://rates.test/v1"))))))
    (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 155 (list (cons 'c c) (cons 'b b) (cons 'a a)) (lambda () (raw-value (httpCallCount "GET" "https://rates.test/v1"))))) 2)
    (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 156 (list (cons 'c c) (cons 'b b) (cons 'a a)) (lambda () (raw-value (httpCallCount "POST" "https://rates.test/log"))))) 1)
    (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 157 (list (cons 'c c) (cons 'b b) (cons 'a a)) (lambda () (raw-value (httpCallCount "GET" "https://rates.test/log"))))) 0)
    (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 158 (list (cons 'c c) (cons 'b b) (cons 'a a)) (lambda () (raw-value (httpCallCount "*" "*"))))) 3)
    )
    ))
  )

  (test-case "STUB-12: httpLastBody shows what was actually sent"
    (call-with-fresh-memory-db (list SyncDb) (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "POST" "https://rates.test/log" 202 "queued"))
    (define r (thsl-src! "tests/http-stub-tests.tesl" 163 (list) (lambda () (pushRates "https://rates.test/log" "{\"event\": \"sync\"}"))))
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 164 (list (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r 'status)))) 202)
    (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 165 (list (cons 'r r)) (lambda () (raw-value (httpLastBody "POST" "https://rates.test/log"))))) "{\"event\": \"sync\"}")
    )
    ))
  )

  (test-case "STUB-12b: a let-bound (not literal) url works everywhere"
    (call-with-fresh-memory-db (list SyncDb) (lambda ()
    (with-capabilities (webClient)
    (define target (thsl-src! "tests/http-stub-tests.tesl" 169 (list) (lambda () "https://rates.test/computed")))
    (raw-value (stubHttp "GET" (raw-value target) 200 "computed"))
    (define r (thsl-src! "tests/http-stub-tests.tesl" 171 (list (cons 'target target)) (lambda () (fetchRates target))))
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 172 (list (cons 'r r) (cons 'target target)) (lambda () (raw-value (tesl-dot/runtime r 'body)))) "computed")
    (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 173 (list (cons 'r r) (cons 'target target)) (lambda () (raw-value (httpCallCount "GET" (raw-value target)))))) 1)
    )
    ))
  )

  (test-case "STUB-13: an unmatched call is still recorded before it fails"
    (call-with-fresh-memory-db (list SyncDb) (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "GET" "https://rates.test/v1" 200 "ok"))
    (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/http-stub-tests.tesl" 178 (list) (lambda ()
                            (fetchRates "https://elsewhere.test/v1"))))])
      (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                  "expected failure: fetchRates \"https://elsewhere.test/v1\""))
    (check-true (raw-value (thsl-src! "tests/http-stub-tests.tesl" 179 (list) (lambda () (raw-value (httpCalled "GET" "https://elsewhere.test/v1"))))))
    )
    ))
  )

  (test-case "STUB-14a: declares a stub and makes a call"
    (call-with-fresh-memory-db (list SyncDb) (lambda ()
    (with-capabilities (webClient)
    (raw-value (stubHttp "GET" "https://leak.test/v1" 200 "from 14a"))
    (define r (thsl-src! "tests/http-stub-tests.tesl" 186 (list) (lambda () (fetchRates "https://leak.test/v1"))))
    (check-equal? (thsl-src! "tests/http-stub-tests.tesl" 187 (list (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r 'body)))) "from 14a")
    (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 188 (list (cons 'r r)) (lambda () (raw-value (httpCallCount "*" "*"))))) 1)
    )
    ))
  )

  (test-case "STUB-14b: sees neither 14a's stub nor its call log"
    (call-with-fresh-memory-db (list SyncDb) (lambda ()
    (with-capabilities (webClient)
    (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 192 (list) (lambda () (raw-value (httpCallCount "*" "*"))))) 0)
    (check-equal? (raw-value (thsl-src! "tests/http-stub-tests.tesl" 193 (list) (lambda () (raw-value (httpCalled "GET" "https://leak.test/v1"))))) #f)
    (raw-value (stubHttp "GET" "https://other.test/v1" 200 "ok"))
    (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/http-stub-tests.tesl" 198 (list) (lambda ()
                            (fetchRates "https://leak.test/v1"))))])
      (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                  "expected failure: fetchRates \"https://leak.test/v1\""))
    )
    ))
  )

)
