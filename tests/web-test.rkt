#lang racket

(require json
         rackunit
         racket/runtime-path
         racket/string
         "../dsl/check.rkt"
         "../dsl/web.rkt"
         "../dsl/otel.rkt"
         "../example/document-api.rkt")

(define-runtime-path check-rkt "../dsl/check.rkt")
(define-runtime-path trusted-rkt "../dsl/trusted.rkt")
(define-runtime-path web-rkt "../dsl/web.rkt")
(define-runtime-path document-api-path "../example/document-api.rkt")

(define (module-private-value module-path symbol-name)
  (dynamic-require `(file ,(path->string module-path)) #f)
  (parameterize ([current-namespace (module->namespace `(file ,(path->string module-path)))])
    (namespace-variable-value
     symbol-name
     #t
     (lambda ()
       (error 'web-test "missing internal binding ~a in ~a" symbol-name module-path)))))

(define document-web-service (module-private-value document-api-path 'web-service))

(define (run-temp-module source [provided #f])
  (define temp-path (make-temporary-file "tesl-web-test-~a.rkt"))
  (call-with-output-file temp-path
    (lambda (out)
      (display source out))
    #:exists 'replace)
  (dynamic-wind
    void
    (lambda ()
      (dynamic-require temp-path provided))
    (lambda ()
      (when (file-exists? temp-path)
        (delete-file temp-path)))))

(define invalid-binding-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define-handler
  (bad-handler [taskId : Integer ::: (Positive taskIds)])
  #:returns Integer
  *taskId)
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define invalid-handler-accept-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define-handler
  (bad-handler [taskId : Integer ::: (Positive taskId)])
  #:returns Integer
  (accept (Positive taskId) #:value *taskId))
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define invalid-pow-accept-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define/pow
  (bad-pow [taskId : Integer ::: (Positive taskId)])
  #:returns Integer
  (accept (Positive taskId) #:value *taskId))
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define invalid-helper-accept-module
  (format "#lang racket
(require (file ~s))
(define (bad-helper taskId)
  (accept PositiveTask #:value taskId))
"
          (path->string check-rkt)))

(define invalid-handler-trusted-proof-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define-handler
  (bad-handler [taskId : Integer])
  #:returns Integer
  (attach-proof (ensure-named taskId *taskId)
                (trusted-proof (Positive taskId))))
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define invalid-helper-trusted-proof-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define (bad-helper taskId)
  (trusted-proof (Positive taskId)))
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define trusted-definition-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define-trusted
  (trusted-positive [value : Integer])
  #:returns [value : Integer ::: (Positive value)]
  (attach-proof (ensure-named value *value)
                (trusted-proof (Positive value))))
(define trusted-result
  (let ([result (trusted-positive 5)])
    (list (raw-value result)
          (detached-proof? (detach-proof result)))))
(provide trusted-result)
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define named-pack-return-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define-checker
  (positive [n : Integer])
  #:returns [n : Integer ::: (Positive n)]
  (if (> *n 0)
      (accept (Positive n) #:value *n)
      (reject \"not positive\" #:http-code 400)))
(define/pow
  (forward-positive-named [n : Integer ::: (Positive n)])
  #:returns (? Integer _entity ::: (Positive _entity))
  n)
(define results
  (let* ([checked (positive 5)]
         [forwarded (forward-positive-named checked)])
    (list (raw-value forwarded)
          (detached-proof? (detach-proof forwarded)))))
(provide results)
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define entry-validation-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define-checker
  (positive [taskId : Integer])
  #:returns [taskId : Integer ::: (Positive taskId)]
  (if (> *taskId 0)
      (accept (Positive taskId) #:value *taskId)
      (reject \"not positive\" #:http-code 400)))
(define/pow
  (typed-only [taskId : Integer])
  #:returns Integer
  0)
(define/pow
  (requires-positive [taskId : Integer ::: (Positive taskId)])
  #:returns [taskId : Integer ::: (Positive taskId)]
  taskId)
(define/pow
  (forward-positive [taskId : Integer ::: (Positive taskId)])
  #:returns Integer
  (requires-positive taskId))
(define/pow
  (detach-positive [taskId : Integer ::: (Positive taskId)])
  #:returns Integer
  (begin
    (detach-proof taskId (Positive taskId))
    *taskId))
(define-trusted
  (trusted-positive [taskId : Integer ::: (Positive taskId)])
  #:returns [taskId : Integer ::: (Positive taskId)]
  taskId)
(define exports
  (hash 'positive positive
        'typed-only typed-only
        'requires-positive requires-positive
        'forward-positive forward-positive
        'detach-positive detach-positive
        'trusted-positive trusted-positive))
(provide exports)
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define invalid-pow-adt-shape-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define/pow
  (bad-pow [taskId : Integer])
  #:returns (Maybe [cacheResult : Integer ::: (Positive taskId)])
  #t)
(provide bad-pow)
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define invalid-pow-adt-proof-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define/pow
  (bad-pow [taskId : Integer])
  #:returns (Maybe [cacheResult : Integer ::: (Positive taskId)])
  (Something 5))
(provide bad-pow)
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define custom-adt-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define-adt (CacheOutcome hit miss)
  [Hit hit]
  [Miss miss])
(define-trusted
  (trusted-cache [taskId : Integer])
  #:returns (CacheOutcome [cacheResult : Integer ::: (Positive taskId)] String)
  (Hit (attach-proof (ensure-named 'cacheResult 5)
                     (trusted-proof (Positive taskId)))))
(define custom-result
  (let ([result (trusted-cache 5)])
    (list (CacheOutcome? result)
          (Hit? result)
          (raw-value (Hit-hit result)))))
(provide custom-result)
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define invalid-public-trusted-module
  (format "#lang racket
(require (file ~s))
"
          (path->string trusted-rkt)))

(define invalid-public-detached-proof-module
  (format "#lang racket
(require (file ~s))
(detached-proof '(Positive taskId) (hash 'taskId 1))
"
          (path->string check-rkt)))

(define registered-capture-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define-checker
  (positive-check [value : Integer])
  #:returns [value : Integer ::: (Positive value)]
  (if (> *value 0)
      (accept (Positive value))
      (reject \"not positive\" #:http-code 400)))
(define-capture positive-int
  [value : Integer ::: (Positive value)]
  #:parser integer-segment
  #:check positive-check)
(define-handler
  (capture-handler [taskId : Integer ::: (Positive taskId)])
  #:returns Integer
  *taskId)
(define-api CaptureAPI
  [get-task :
    \"tasks\"
    :> (Capture positive-int [taskId : Integer ::: (Positive taskId)])
    :> (Get JSON Integer)])
(define-server CaptureServer
  #:api CaptureAPI
  [get-task capture-handler])
(provide CaptureServer)
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define invalid-capture-kind-binding-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define-checker
  (positive-check [value : Integer])
  #:returns [value : Integer ::: (Positive value)]
  (if (> *value 0)
      (accept (Positive value))
      (reject \"not positive\" #:http-code 400)))
(define-capture positive-int
  [value : Integer ::: (Positive value)]
  #:parser integer-segment
  #:check positive-check)
(define-api BadAPI
  [get-task :
    \"tasks\"
    :> (Capture positive-int [taskId : String ::: (Positive taskId)])
    :> (Get JSON String)])
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define invalid-q-return-handler-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define-handler
  (bad-return [taskId : Integer ::: (Positive taskId)])
  #:returns (? Integer taskId ::: (Positive taskId))
  *taskId)
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define invalid-q-return-api-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define (positive-check value) value)
(define-api BadAPI
  [get-task :
    \"tasks\"
    :> (Capture [taskId : Integer ::: (Positive taskId)]
                #:parser integer-segment
                #:check positive-check)
    :> (Get JSON
         (? Integer taskId ::: (Positive taskId)))])
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define alpha-equivalent-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define (pass-auth request) request)
(define (positive-check value) value)
(define-handler
  (alpha-handler
    [currentUser : User ::: (Authenticated currentUser)]
    [id : Integer ::: (Positive id)])
  #:returns (Task ::: (FromDb [Id == id]))
  *id)
(define-api AlphaAPI
  [get-task :
    (Auth [requestUser : User ::: (Authenticated requestUser)]
          #:via pass-auth)
    :> \"tasks\"
    :> (Capture [taskId : Integer ::: (Positive taskId)]
                #:parser integer-segment
                #:check positive-check)
    :> (Get JSON
         (Task ::: (FromDb [Id == taskId])))])
(define-server AlphaServer
  #:api AlphaAPI
  [get-task alpha-handler])
(provide AlphaServer)
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define mismatched-arguments-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define (pass-auth request) request)
(define (positive-check value) value)
(define-handler
  (bad-handler
    [currentUser : User ::: (Authenticated currentUser)]
    [id : Integer])
  #:returns (Task ::: (FromDb [Id == id]))
  *id)
(define-api BadAPI
  [get-task :
    (Auth [requestUser : User ::: (Authenticated requestUser)]
          #:via pass-auth)
    :> \"tasks\"
    :> (Capture [taskId : Integer ::: (Positive taskId)]
                #:parser integer-segment
                #:check positive-check)
    :> (Get JSON
         (Task ::: (FromDb [Id == taskId])))])
(define-server BadServer
  #:api BadAPI
  [get-task bad-handler])
(provide BadServer)
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define mismatched-return-module
  (format "#lang racket
(require (file ~s) (file ~s))
(define (pass-auth request) request)
(define (positive-check value) value)
(define-handler
  (bad-return-handler
    [currentUser : User ::: (Authenticated currentUser)]
    [id : Integer ::: (Positive id)])
  #:returns (Task ::: (FromCache [Id == id]))
  *id)
(define-api ReturnAPI
  [get-task :
    (Auth [requestUser : User ::: (Authenticated requestUser)]
          #:via pass-auth)
    :> \"tasks\"
    :> (Capture [taskId : Integer ::: (Positive taskId)]
                #:parser integer-segment
                #:check positive-check)
    :> (Get JSON
         (Task ::: (FromDb [Id == taskId])))])
(define-server ReturnServer
  #:api ReturnAPI
  [get-task bad-return-handler])
(provide ReturnServer)
"
          (path->string check-rkt)
          (path->string web-rkt)))

(define api-codec-module
  (format "#lang racket\n(require racket/string\n         (file ~s))\n(define-record CodecCreateTaskRequest\n  [title : String])\n(define-record CodecTaskMeta\n  [title : String]\n  [slug : String])\n(define-record CodecNewTask\n  [meta : CodecTaskMeta]\n  [audit : String])\n(define-record CodecTask\n  [id : String]\n  [meta : CodecTaskMeta]\n  [status : String]\n  [audit : String])\n(define-record CodecTaskResponse\n  [id : String]\n  [title : String]\n  [status : String])\n(define (slugify value)\n  (string-replace (string-downcase value) \" \" \"-\"))\n(define (decode-create-task payload)\n  (CodecNewTask #:meta (CodecTaskMeta #:title (field-access-ref payload 'title 'CodecCreateTaskRequest)\n                                      #:slug (slugify (field-access-ref payload 'title 'CodecCreateTaskRequest)))\n                #:audit \"decoded-from-wire\"))\n(define (encode-task task)\n  (CodecTaskResponse #:id (field-access-ref task 'id 'CodecTask)\n                     #:title (field-access-ref (field-access-ref task 'meta 'CodecTask) 'title 'CodecTaskMeta)\n                     #:status (field-access-ref task 'status 'CodecTask)))\n(define-handler\n  (create-task [newTask : CodecNewTask])\n  #:returns CodecTask\n  (CodecTask #:id \"task-1\"\n             #:meta (field-access-ref *newTask 'meta 'CodecNewTask)\n             #:status \"draft\"\n             #:audit (field-access-ref *newTask 'audit 'CodecNewTask)))\n(define-api CodecAPI\n  [create-task :\n    \"tasks\"\n    :> (ReqBody JSON [newTask : CodecNewTask] #:wire CodecCreateTaskRequest #:decoder decode-create-task)\n    :> (Response JSON CodecTaskResponse #:encoder encode-task)\n    :> (Post JSON CodecTask)])\n(define-server CodecServer\n  #:api CodecAPI\n  [create-task create-task])\n(define codec-artifacts (list CodecAPI CodecServer))\n(provide codec-artifacts)\n"
          (path->string web-rkt)))

(define bad-response-codec-module
  (format "#lang racket\n(require (file ~s))\n(define-record BrokenCodecTask\n  [id : String])\n(define-record BrokenCodecTaskResponse\n  [id : String])\n(define (encode-task _task)\n  \"not-a-task-response\")\n(define-handler\n  (get-task)\n  #:returns BrokenCodecTask\n  (BrokenCodecTask #:id \"task-1\"))\n(define-api BadCodecAPI\n  [get-task :\n    \"tasks\"\n    :> (Response JSON BrokenCodecTaskResponse #:encoder encode-task)\n    :> (Get JSON BrokenCodecTask)])\n(define-server BadCodecServer\n  #:api BadCodecAPI\n  [get-task get-task])\n(provide BadCodecServer)\n"
          (path->string web-rkt)))

(define (dispatch method path #:cookie [cookie #f] #:body [body #f])
  (dispatch-request
   DocumentServer
   (make-request method
                 path
                 #:headers (cond
                             [(and cookie body)
                              (hash "cookie" cookie
                                    "content-type" "application/json")]
                             [cookie
                              (hash "cookie" cookie)]
                             [body
                              (hash "content-type" "application/json")]
                             [else
                              (hash)])
                 #:body (if body (jsexpr->bytes body) #""))
   #:capabilities (list document-web-service)))

(seed-state!)
(define console-port (open-output-string))
(init-opentelemetry! #:service-name "document-api"
                     #:endpoint "test"
                     #:console? #t
                     #:console-port console-port)
(drain-telemetry!)

(check-true (Maybe? Nothing))
(check-true (Nothing? Nothing))
(let ([just-value (Something 5)])
  (check-true (Maybe? just-value))
  (check-true (Something? just-value))
  (check-equal? (Something-value just-value) 5))
(let ([ok-value (Ok 7)]
      [err-value (Err "boom")])
  (check-true (Result? ok-value))
  (check-true (Ok? ok-value))
  (check-equal? (Ok-value ok-value) 7)
  (check-true (Result? err-value))
  (check-true (Err? err-value))
  (check-equal? (Err-error err-value) "boom"))

(check-exn
 (lambda (exn)
   (and (exn:fail:syntax? exn)
        (regexp-match? #rx"taskIds" (exn-message exn))))
 (lambda ()
   (run-temp-module invalid-binding-module #f)))

(check-exn
 (lambda (exn)
   (and (exn:fail:syntax? exn)
        (regexp-match? #rx"only allowed inside define-checker and define-auther" (exn-message exn))))
 (lambda ()
   (run-temp-module invalid-handler-accept-module #f)))

(check-exn
 (lambda (exn)
   (and (exn:fail:syntax? exn)
        (regexp-match? #rx"only allowed inside define-checker and define-auther" (exn-message exn))))
 (lambda ()
   (run-temp-module invalid-pow-accept-module #f)))

(check-exn
 (lambda (exn)
   (and (exn:fail:syntax? exn)
        (regexp-match? #rx"only allowed inside define-checker and define-auther" (exn-message exn))))
 (lambda ()
   (run-temp-module invalid-helper-accept-module #f)))

(check-exn
 (lambda (exn)
   (and (exn:fail:syntax? exn)
        (regexp-match? #rx"only allowed inside define-trusted" (exn-message exn))))
 (lambda ()
   (run-temp-module invalid-handler-trusted-proof-module #f)))

(check-exn
 (lambda (exn)
   (and (exn:fail:syntax? exn)
        (regexp-match? #rx"only allowed inside define-trusted" (exn-message exn))))
 (lambda ()
   (run-temp-module invalid-helper-trusted-proof-module #f)))

(check-equal? (run-temp-module trusted-definition-module 'trusted-result)
              '(5 #t))
(check-equal? (run-temp-module named-pack-return-module 'results)
              '(5 #t))
(let* ([entry-exports (run-temp-module entry-validation-module 'exports)]
       [positive (hash-ref entry-exports 'positive)]
       [typed-only (hash-ref entry-exports 'typed-only)]
       [requires-positive (hash-ref entry-exports 'requires-positive)]
       [forward-positive (hash-ref entry-exports 'forward-positive)]
       [detach-positive (hash-ref entry-exports 'detach-positive)]
       [trusted-positive (hash-ref entry-exports 'trusted-positive)]
       [positive-value (positive 5)]
       [positive-pow-result (requires-positive positive-value)]
       [trusted-pow-result (trusted-positive positive-value)])
  ;; Entry type/proof re-validation for define/pow and define-trusted was
  ;; intentionally erased (zero-cost proofs); these guarantees now live in the
  ;; static checker, so there is no runtime exception to assert here anymore.
  ;; (Former check-exn blocks for `typed-only "oops"`, `requires-positive -1`,
  ;; and `trusted-positive -1` were removed as obsolete.)
  (check-equal? (raw-value positive-pow-result) 5)
  (check-true (detached-proof? (detach-proof positive-pow-result)))
  (check-equal? (raw-value (forward-positive positive-value)) 5)
  (check-equal? (detach-positive positive-value) 5)
  (check-equal? (raw-value trusted-pow-result) 5)
  (check-true (detached-proof? (detach-proof trusted-pow-result))))
(check-exn
 (lambda (exn)
   (and (exn:fail? exn)
        (regexp-match? #rx"declared ADT return" (exn-message exn))))
 (lambda ()
   ((run-temp-module invalid-pow-adt-shape-module 'bad-pow) 5)))
;; The runtime no longer re-checks declared return proofs (zero-cost proofs);
;; the former check-exn for invalid-pow-adt-proof-module ("declared return
;; proof") was removed as obsolete. The ADT *shape* return check above is still
;; enforced and remains asserted.
(check-equal? (run-temp-module custom-adt-module 'custom-result)
              '(#t #t 5))

(check-exn
 (lambda (exn)
   (and (exn:fail:user? exn)
        (regexp-match? #rx"internal-only module" (exn-message exn))))
 (lambda ()
   (run-temp-module invalid-public-trusted-module #f)))

(check-exn
 (lambda (exn)
   (and (exn:fail:syntax? exn)
        (regexp-match? #rx"detached-proof" (exn-message exn))))
 (lambda ()
   (run-temp-module invalid-public-detached-proof-module #f)))

(define registered-capture-server
  (run-temp-module registered-capture-module 'CaptureServer))

(check-exn
 (lambda (exn)
   (and (exn:fail:syntax? exn)
        (regexp-match? #rx"capture kind positive-int expects a binding compatible" (exn-message exn))))
 (lambda ()
   (run-temp-module invalid-capture-kind-binding-module #f)))

(let ([response (dispatch-request registered-capture-server
                                  (make-request 'GET '("tasks" "5"))
                                  #:capabilities '())])
  (check-equal? (dsl-response-status response) 200)
  (check-equal? (dsl-response-body response) 5))

(let ([response (dispatch-request registered-capture-server
                                  (make-request 'GET '("tasks" "0"))
                                  #:capabilities '())])
  (check-equal? (dsl-response-status response) 400)
  (check-equal? (hash-ref (dsl-response-body response) 'ok) #f))

(check-exn
 (lambda (exn)
   (and (exn:fail:user? exn)
        (regexp-match? #rx"declared capability value" (exn-message exn))))
 (lambda ()
   (dispatch-request DocumentServer
                     (make-request 'GET '("tasks" "1") #:headers (hash "cookie" "user=mikael"))
                     #:capabilities '(web-service))))

(check-not-exn
 (lambda ()
   (run-temp-module invalid-q-return-handler-module #f)))

(check-not-exn
 (lambda ()
   (run-temp-module invalid-q-return-api-module #f)))

(check-true (server-spec? (run-temp-module alpha-equivalent-module 'AlphaServer)))

(check-exn
 (lambda (exn)
   (and (exn:fail:user? exn)
        (regexp-match? #rx"argument types/proofs" (exn-message exn))))
 (lambda ()
   (run-temp-module mismatched-arguments-module 'BadServer)))

(check-exn
 (lambda (exn)
   (and (exn:fail:user? exn)
        (regexp-match? #rx"return type" (exn-message exn))))
 (lambda ()
   (run-temp-module mismatched-return-module 'ReturnServer)))

(check-true (api-spec? DocumentAPI))
(check-equal? (length (api-spec-endpoints DocumentAPI)) 3)
(check-equal? (api-endpoint-spec-method (first (api-spec-endpoints DocumentAPI))) 'POST)
(check-equal? (api-endpoint-spec-name (second (api-spec-endpoints DocumentAPI))) 'get-task)
(check-equal? (signature-spec-kind attempt-cache-signature) 'trusted)
(check-equal? (signature-spec-kind get-task-handler-signature) 'handler)
(check-equal? (type-datum-display (signature-spec-returns get-task-handler-signature))
              '(? Task _entity ::: (FromDb (Id == taskId) _entity)))
(check-equal? (type-datum-display (api-endpoint-spec-returns (second (api-spec-endpoints DocumentAPI))))
              '(? Task _entity ::: (FromDb (Id == taskId) _entity)))
(check-true (server-spec? DocumentServer))
(check-equal? (length (server-spec-routes DocumentServer)) 3)

(define codec-artifacts (run-temp-module api-codec-module 'codec-artifacts))
(define CodecAPI (first codec-artifacts))
(define CodecServer (second codec-artifacts))
(define codec-endpoint (first (api-spec-endpoints CodecAPI)))
(define codec-payload
  (for/first ([segment (in-list (api-endpoint-spec-segments codec-endpoint))]
              #:when (payload-spec? segment))
    segment))
(check-equal? (type-datum-display (payload-spec-wire-type codec-payload)) 'CodecCreateTaskRequest)
(check-equal? (type-datum-display (api-endpoint-spec-response-wire-type codec-endpoint)) 'CodecTaskResponse)
(let ([response (dispatch-request CodecServer
                                  (make-request 'POST '("tasks")
                                                #:headers (hash "content-type" "application/json")
                                                #:body (jsexpr->bytes (hash 'title "Ship codecs")))
                                  #:capabilities '())])
  (check-equal? (dsl-response-status response) 200)
  (check-equal? (hash-ref (dsl-response-body response) 'id) "task-1")
  (check-equal? (hash-ref (dsl-response-body response) 'title) "Ship codecs")
  (check-equal? (hash-ref (dsl-response-body response) 'status) "draft")
  (check-false (hash-has-key? (dsl-response-body response) 'meta))
  (check-false (hash-has-key? (dsl-response-body response) 'audit)))
(let ([response (dispatch-request CodecServer
                                  (make-request 'POST '("tasks")
                                                #:headers (hash "content-type" "application/json")
                                                #:body (jsexpr->bytes (hash)))
                                  #:capabilities '())])
  (check-equal? (dsl-response-status response) 400)
  (check-true (regexp-match? #rx"CodecCreateTaskRequest" (hash-ref (dsl-response-body response) 'error)))
  (check-true (regexp-match? #rx"title" (hash-ref (dsl-response-body response) 'error))))
(parameterize ([current-handler-error-port (open-output-nowhere)])
  (let ([response (dispatch-request (run-temp-module bad-response-codec-module 'BadCodecServer)
                                    (make-request 'GET '("tasks"))
                                    #:capabilities '())])
    (check-equal? (dsl-response-status response) 500)
    ;; Security hardening (web.rkt "A2"): handler-error detail is redacted from
    ;; the client body (only logged server-side / echoed under TESL_VERBOSE).
    ;; Assert the redaction contract instead of reading the leaked detail.
    (check-equal? (hash-ref (dsl-response-body response) 'details) '())
    (check-equal? (hash-ref (dsl-response-body response) 'error) "Internal server error")))

(seed-state!)
(let ([response (dispatch 'GET '("tasks" "1") #:cookie "user=mikael")])
  (check-equal? (dsl-response-status response) 200)
  (check-equal? (hash-ref (dsl-response-body response) 'title) "Pay invoices")
  (check-true (string-contains? (get-output-string console-port)
                                "\"message\":\"task.fetch\"")))

(seed-state!)
(let ([response (dispatch 'GET '("tasks" "2") #:cookie "user=mikael")])
  (check-equal? (dsl-response-status response) 403)
  (check-equal? (hash-ref (dsl-response-body response) 'ok) #f))

(seed-state!)
(let ([response (dispatch 'GET '("tasks" "0") #:cookie "user=mikael")])
  (check-equal? (dsl-response-status response) 400)
  (check-equal? (hash-ref (dsl-response-body response) 'ok) #f))

(seed-state!)
(let ([response (dispatch 'GET '("tasks" "1"))])
  (check-equal? (dsl-response-status response) 401))

(seed-state!)
(let ([response (dispatch 'GET '("tasks" "admin" "2") #:cookie "user=anna; role=admin")])
  (check-equal? (dsl-response-status response) 200)
  (check-equal? (hash-ref (dsl-response-body response) 'ownerId) "anna"))

(seed-state!)
(let ([response (dispatch 'GET '("tasks" "admin" "99") #:cookie "user=anna; role=admin")])
  (check-equal? (dsl-response-status response) 404)
  (check-equal? (hash-ref (dsl-response-body response) 'ok) #f))

(seed-state!)
(let ([response (dispatch 'POST
                         '("docs")
                         #:body (hash 'title "Quarterly roadmap"
                                      'body "Ship the DSL MVP"))])
  (check-equal? (dsl-response-status response) 200)
  (check-equal? (dsl-response-body response) "doc-1")
  (check-equal? (hash-ref (hash-ref (current-doc-store) "doc-1") 'title)
                "Quarterly roadmap")
  (check-true (string-contains? (get-output-string console-port)
                                "\"message\":\"publish-doc.start\"")))

(seed-state!)
(let ([response (dispatch 'POST
                         '("docs")
                         #:body (hash 'title "Tiny"
                                      'body "Nope"))])
  (check-equal? (dsl-response-status response) 400)
  (check-equal? (hash-ref (dsl-response-body response) 'ok) #f))

(define emitted-events (drain-telemetry!))
(check-false (null? emitted-events))
(check-equal? (telemetry-event-service-name (first emitted-events)) "document-api")

;; ── CONC-1: SSE per-key capture is enforced (fail-closed) ──────────────────
;; An `sse` endpoint's `capture key ::: P key via someCapturer` is lowered to a
;; `(sse-key-capture someCapturer)` validator (4th element of the SSE route).
;; The validator must reject an invalid channel key (rather than the check being
;; silently dropped, which let any authenticated user subscribe to any key — an
;; IDOR/BOLA gap).  This reconstructs the emitted checker/capturer forms and
;; exercises the validator directly.
(define conc1-sse-validate
  (run-temp-module
   (format "#lang racket
(require (file ~s) (file ~s))
(provide validate)
(define ValidRoomId 'ValidRoomId)
(define-checker
  (checkRoomId [id : String])
  #:returns [id : String ::: (ValidRoomId id)]
  (if (> (string-length *id) 0)
      (accept (ValidRoomId id) #:value *id)
      (reject \"invalid room id\" #:http-code 400)))
(define-capture roomIdCapture
  [roomId : String ::: (ValidRoomId roomId)]
  #:parser string-segment #:check checkRoomId)
(define validate (sse-key-capture roomIdCapture))
"
           (path->string check-rkt)
           (path->string web-rkt))
   'validate))
(check-false (check-fail? (conc1-sse-validate "room-1"))
             "CONC-1: a valid SSE channel key is accepted")
(check-true (check-fail? (conc1-sse-validate ""))
            "CONC-1: an invalid (empty) SSE channel key is rejected fail-closed")
