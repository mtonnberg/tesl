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
  (only-in tesl/tesl/prelude String Unit)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/tuple Tuple2)
  (only-in tesl/tesl/env env envRead)
  (only-in tesl/tesl/string [String.join tesl_import_String_join])
  (only-in tesl/tesl/list [List.map tesl_import_List_map])
  (only-in tesl/tesl/id generatePrefixedId)
  (only-in tesl/tesl/random random)
  (only-in tesl/tesl/time nowMillis time PosixMillis)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/http-client httpClient HttpResponse [HttpClient.post tesl_import_HttpClient_post])
  (only-in tesl/tesl/queue FromQueue queueRead queueWrite)
  (only-in tesl/tesl/api-test statusOk JobResult JobOk JobFailed processNextJob pendingJobCount expectJobOk)
)


(provide Lesson74Server)

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "example/learn/lesson74-interop-patterns.tesl" '(148 187))
(define/pow
  (resolveUploadBucket)
  #:capabilities [envRead]
  #:returns String
  (thsl-src-control! "example/learn/lesson74-interop-patterns.tesl" 68 (list) (lambda () (let ([tesl-case-0 (raw-value (env "UPLOAD_BUCKET"))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 69 (list) (lambda () (raw-value "local-dev-bucket")))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([name (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 70 (list (cons 'name name)) (lambda () *name)))])))))

(define-entity Document
  #:source (make-hash)
  #:table documents
  #:primary-key id
  [Id id : String #:db-type text]
  [OwnerId ownerId : String #:db-type text]
  [Name name : String #:db-type text]
  [Body body : String #:db-type text]
  [CreatedAt createdAt : PosixMillis]
)

(define-database Lesson74Database
  #:backend postgres
  #:database "demo"
  #:user "demo"
  #:password "demo"
  #:server "localhost"
  #:port 5432
  #:schema lesson74
  #:entities Document)

(define-capability documentStore (implies dbRead dbWrite time random))

(define-record NewDocument
  [name : String]
  [body : String]
)

(define (tesl-codec-encode-NewDocument _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'name (tesl-encode-prim-string (raw-value (hash-ref _fields 'name)))
        'body (tesl-encode-prim-string (raw-value (hash-ref _fields 'body)))
  ))
(define (tesl-codec-decode-NewDocument-0 _j)
  (define _f_name (tesl-decode-prim-field _j "name" tesl-decode-prim-string))
  (define _f_body (tesl-decode-prim-field _j "body" tesl-decode-prim-string))
  (record-value 'NewDocument (hash 'name _f_name 'body _f_body)))
(register-type-codec! 'NewDocument tesl-codec-encode-NewDocument (list tesl-codec-decode-NewDocument-0))

(define-handler
  (importDocument [body : NewDocument])
  #:capabilities [documentStore]
  #:returns (Exists [docId : String] (? Document _entity ::: (FromDb (Id == docId) _entity)))
  (let ([docId (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 129 (list (cons 'body *body)) (lambda () (generatePrefixedId "doc")))]) (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 130 (list (cons 'docId *docId) (cons 'body *body)) (lambda () (pack ([docId]) (insert-one! Document (hash 'id docId 'ownerId "demo-user" 'name (raw-value body.name) 'body (raw-value body.body) 'createdAt (raw-value (nowMillis)))))))))

(define/pow
  (documentToCsvRow [doc : Document])
  #:returns String
  (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 145 (list (cons 'doc *doc)) (lambda () (string-append (string-append (tesl-dot/runtime doc 'id 'Document) ",") (tesl-dot/runtime doc 'name 'Document)))))

(define-handler
  (exportDocuments)
  #:capabilities [documentStore]
  #:returns String
  (let ([docs (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 148 (list) (lambda () (select-many (from Document) (where (==. (entity-field-ref Document 'ownerId) "demo-user")))) 'docs)]) (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 149 (list (cons 'docs *docs)) (lambda () (tesl_import_String_join (raw-value (tesl_import_List_map documentToCsvRow (raw-value docs))) "\n")))))

(define-record SummariseDocument
  [docId : String]
  [ownerId : String]
)

(define/pow
  (storeSummary [docId : String] [summary : String])
  #:capabilities [dbWrite]
  #:returns Unit
  (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 181 (list (cons 'docId *docId) (cons 'summary *summary)) (lambda () (void (update-many! (from Document) (hash (entity-field-ref Document 'name) summary) (where (==. (entity-field-ref Document 'id) docId)))))))

(define/pow
  (summariseDocument [job : SummariseDocument ::: (FromQueue (Id == jobId) job)])
  #:capabilities [documentStore queueRead]
  #:returns SummariseDocument
  (let ([existing (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 187 (list (cons 'job *job)) (lambda () (let ([tesl_match (select-one (from Document) (where (==. (entity-field-ref Document 'id) (raw-value job.docId))))]) (if tesl_match (Something tesl_match) Nothing))) 'existing)]) (thsl-src-control! "example/learn/lesson74-interop-patterns.tesl" 188 (list (cons 'existing *existing) (cons 'job *job)) (lambda () (let ([tesl-case-1 (raw-value existing)]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 189 (list) (lambda () job))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([doc (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 191 (list (cons 'doc doc)) (lambda () (let ([_ (storeSummary (raw-value job.docId) (string-append "summary: " (raw-value doc.name)))]) job))))]))))))

(define-handler
  (requestSummary [body : NewDocument])
  #:capabilities [documentStore queueWrite]
  #:returns String
  (let ([docId (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 199 (list (cons 'body *body)) (lambda () (generatePrefixedId "doc")))]) (let ([_stored (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 200 (list (cons 'docId *docId) (cons 'body *body)) (lambda () (insert-one! Document (hash 'id docId 'ownerId "demo-user" 'name (raw-value body.name) 'body (raw-value body.body) 'createdAt (raw-value (nowMillis))))))]) (let ([_ (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 207 (list (cons '_stored *_stored) (cons 'docId *docId) (cons 'body *body)) (lambda () (enqueue! Lesson74Queue (SummariseDocument #:docId *docId #:ownerId "demo-user"))))]) (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 208 (list (cons '_stored *_stored) (cons 'docId *docId) (cons 'body *body)) (lambda () "queued"))))))

(define-capability thumbnailer (implies httpClient))

(define/pow
  (renderThumbnail [bucket : String] [docId : String])
  #:capabilities [thumbnailer]
  #:returns HttpResponse
  (let ([url (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 235 (list (cons 'bucket *bucket) (cons 'docId *docId)) (lambda () (string-append "http://thumbnailer.internal/render/" *docId)))]) (let ([contentType (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 236 (list (cons 'url *url) (cons 'bucket *bucket) (cons 'docId *docId)) (lambda () (raw-value (Tuple2 "Content-Type" "application/json"))))]) (let ([payload (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 237 (list (cons 'contentType *contentType) (cons 'url *url) (cons 'bucket *bucket) (cons 'docId *docId)) (lambda () (string-append (string-append "{\"bucket\":\"" *bucket) "\"}")))]) (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 238 (list (cons 'payload *payload) (cons 'contentType *contentType) (cons 'url *url) (cons 'bucket *bucket) (cons 'docId *docId)) (lambda () (raw-value (tesl_import_HttpClient_post (raw-value url) (list *contentType) (raw-value payload)))))))))

(define-record ThumbnailJob
  [docId : String]
)

(define/pow
  (thumbnailWorker [job : ThumbnailJob ::: (FromQueue (Id == jobId) job)])
  #:capabilities [thumbnailer envRead queueRead]
  #:returns ThumbnailJob
  (let ([bucket (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 250 (list (cons 'job *job)) (lambda () (resolveUploadBucket)))]) (let ([response (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 251 (list (cons 'bucket *bucket) (cons 'job *job)) (lambda () (renderThumbnail bucket (raw-value job.docId))))]) (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 256 (list (cons 'response *response) (cons 'bucket *bucket) (cons 'job *job)) (lambda () (if (tesl-equal? (raw-value response.status) 200) *job (reject "thumbnail service returned an error" #:http-code 502)))))))

(define-queue Lesson74Queue
  #:database Lesson74Database
  #:job-types (SummariseDocument ThumbnailJob)
  #:max-attempts 3
  #:backoff exponential
  #:initial-delay 60)

(define Lesson74Server-sse-routes '())
(define-api Lesson74Api
  [importDocument :
    "documents"
    :> (ReqBody JSON [body : NewDocument])
    :> (Post JSON (Exists [docId : String] (? Document _entity ::: (FromDb (Id == docId) _entity))))
    ]
  [exportDocuments :
    "documents.csv"
    :> (Get JSON String)
    ]
  [requestSummary :
    "summaries"
    :> (ReqBody JSON [body : NewDocument])
    :> (Post JSON String)
    ]
)

(define-server Lesson74Server
  #:api Lesson74Api
  [importDocument importDocument]
  [exportDocuments exportDocuments]
  [requestSummary requestSummary]
)

(module+ test
  (require rackunit)
  (test-case "background work runs without a subprocess"
    (call-with-fresh-memory-db (list Lesson74Database)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (documentStore queueRead queueWrite)
              (define resp (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 308 (list) (lambda () (dispatch-api-test-request Lesson74Server 'post (list "summaries") #:headers (hash) #:body (hash (string->symbol "name") "report" (string->symbol "body") "hello") #:capabilities (list documentStore queueRead queueWrite)))))
              (check-true (raw-value (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 309 (list (cons 'resp resp)) (lambda () (statusOk (raw-value (api-test-field-access-ref resp 'status)))))))
              (check-equal? (raw-value (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 311 (list (cons 'resp resp)) (lambda () (pendingJobCount Lesson74Queue)))) 1)
              (define result (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 313 (list (cons 'resp resp)) (lambda () (processNextJob Lesson74Queue))))
              (define job (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 314 (list (cons 'result result) (cons 'resp resp)) (lambda () (expectJobOk (raw-value result)))))
              (check-equal? (raw-value (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 315 (list (cons 'job job) (cons 'result result) (cons 'resp resp)) (lambda () (api-test-field-access-ref job 'ownerId)))) "demo-user")
              (check-equal? (raw-value (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 316 (list (cons 'job job) (cons 'result result) (cons 'resp resp)) (lambda () (pendingJobCount Lesson74Queue)))) 0)
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "import and export need no filesystem"
    (call-with-fresh-memory-db (list Lesson74Database)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (documentStore)
              (define created (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 320 (list) (lambda () (dispatch-api-test-request Lesson74Server 'post (list "documents") #:headers (hash) #:body (hash (string->symbol "name") "notes.txt" (string->symbol "body") "content") #:capabilities (list documentStore)))))
              (check-true (raw-value (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 321 (list (cons 'created created)) (lambda () (statusOk (raw-value (api-test-field-access-ref created 'status)))))))
              (define exported (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 323 (list (cons 'created created)) (lambda () (dispatch-api-test-request Lesson74Server 'get (list "documents.csv") #:headers (hash) #:capabilities (list documentStore)))))
              (check-true (raw-value (thsl-src! "example/learn/lesson74-interop-patterns.tesl" 324 (list (cons 'exported exported) (cons 'created created)) (lambda () (statusOk (raw-value (api-test-field-access-ref exported 'status)))))))
            )
          ))
      ))
  )
)

(define Lesson74QueueWorkers
  (list (cons Lesson74Queue summariseDocument) (cons Lesson74Queue thumbnailWorker)))
(register-api-test-workers! (list (list Lesson74Queue 'SummariseDocument summariseDocument) (list Lesson74Queue 'ThumbnailJob thumbnailWorker)))
