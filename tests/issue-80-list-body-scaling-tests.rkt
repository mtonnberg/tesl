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
  (only-in tesl/tesl/prelude String List)
  (only-in tesl/tesl/list [List.map tesl_import_List_map])
  (only-in tesl/tesl/api-test statusOk statusClientError)
)


(provide Issue80Server)

(define-record RefsRequest
  [refs : (List String)]
)

(define (tesl-codec-encode-RefsRequest _v)
  (error "toJson is forbidden for type RefsRequest: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-RefsRequest-0 _j)
  (define _f_refs (tesl-decode-prim-field _j "refs" (lambda (_v) (jsexpr->typed-value '(List String) _v))))
  (record-value 'RefsRequest (tesl-hash 'refs _f_refs)))
(register-type-codec! 'RefsRequest tesl-codec-encode-RefsRequest (list tesl-codec-decode-RefsRequest-0))

(define-record RefResult
  [text : String]
)

(define (tesl-codec-encode-RefResult _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (tesl-hash 'text (tesl-encode-prim-string (raw-value (hash-ref _fields 'text)))
  ))
(register-type-codec! 'RefResult tesl-codec-encode-RefResult (list ))

(define/pow
  (resolveOne [ref : String])
  #:returns RefResult
  (thsl-src! "tests/issue-80-list-body-scaling-tests.tesl" 50 (list (cons 'ref *ref)) (lambda () (RefResult #:text *ref))))

(define-handler
  (resolveRefs [body : RefsRequest])
  #:returns (List RefResult)
  (thsl-src! "tests/issue-80-list-body-scaling-tests.tesl" 53 (list (cons 'body *body)) (lambda () (tesl_import_List_map resolveOne (tesl-dot/runtime body 'refs 'RefsRequest)))))

(define Issue80Server-sse-routes '())
(define-api Issue80Api
  [resolveRefs :
    "api"
    :> "refs"
    :> (ReqBody JSON [body : RefsRequest])
    :> (Post JSON (List RefResult))
    ]
)

(define-server Issue80Server
  #:api Issue80Api
  [resolveRefs resolveRefs]
)

(module+ test
  (require rackunit)
  (test-case "list body decodes intact, in order, and element-typed"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define resp (thsl-src! "tests/issue-80-list-body-scaling-tests.tesl" 66 (list) (lambda () (dispatch-api-test-request Issue80Server 'post (list "api" "refs") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "refs") (list "alpha" "beta" "gamma")) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/issue-80-list-body-scaling-tests.tesl" 67 (list (cons 'resp resp)) (lambda () (statusOk (raw-value (api-test-field-access-ref resp 'status)))))))
            (check-equal? (raw-value (thsl-src! "tests/issue-80-list-body-scaling-tests.tesl" 68 (list (cons 'resp resp)) (lambda () (api-test-field-access-ref resp 'body)))) (list (tesl-hash 'text "alpha") (tesl-hash 'text "beta") (tesl-hash 'text "gamma")))
            (define bad (thsl-src! "tests/issue-80-list-body-scaling-tests.tesl" 74 (list (cons 'resp resp)) (lambda () (dispatch-api-test-request Issue80Server 'post (list "api" "refs") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "refs") (list "alpha" 42)) #:capabilities '()))))
            (check-true (raw-value (thsl-src! "tests/issue-80-list-body-scaling-tests.tesl" 75 (list (cons 'bad bad) (cons 'resp resp)) (lambda () (statusClientError (raw-value (api-test-field-access-ref bad 'status)))))))
          ))
      ))
  )
)

(module+ test
  (require rackunit tesl/dsl/load-test)
  (test-case "200-element List String body stays linear (issue #80)"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (run-load-test Issue80Server 20 3
              (lambda ()
                (dispatch-api-test-request Issue80Server 'post (list "api" "refs") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "refs") (list "ref-000" "ref-001" "ref-002" "ref-003" "ref-004" "ref-005" "ref-006" "ref-007" "ref-008" "ref-009" "ref-010" "ref-011" "ref-012" "ref-013" "ref-014" "ref-015" "ref-016" "ref-017" "ref-018" "ref-019" "ref-020" "ref-021" "ref-022" "ref-023" "ref-024" "ref-025" "ref-026" "ref-027" "ref-028" "ref-029" "ref-030" "ref-031" "ref-032" "ref-033" "ref-034" "ref-035" "ref-036" "ref-037" "ref-038" "ref-039" "ref-040" "ref-041" "ref-042" "ref-043" "ref-044" "ref-045" "ref-046" "ref-047" "ref-048" "ref-049" "ref-050" "ref-051" "ref-052" "ref-053" "ref-054" "ref-055" "ref-056" "ref-057" "ref-058" "ref-059" "ref-060" "ref-061" "ref-062" "ref-063" "ref-064" "ref-065" "ref-066" "ref-067" "ref-068" "ref-069" "ref-070" "ref-071" "ref-072" "ref-073" "ref-074" "ref-075" "ref-076" "ref-077" "ref-078" "ref-079" "ref-080" "ref-081" "ref-082" "ref-083" "ref-084" "ref-085" "ref-086" "ref-087" "ref-088" "ref-089" "ref-090" "ref-091" "ref-092" "ref-093" "ref-094" "ref-095" "ref-096" "ref-097" "ref-098" "ref-099" "ref-100" "ref-101" "ref-102" "ref-103" "ref-104" "ref-105" "ref-106" "ref-107" "ref-108" "ref-109" "ref-110" "ref-111" "ref-112" "ref-113" "ref-114" "ref-115" "ref-116" "ref-117" "ref-118" "ref-119" "ref-120" "ref-121" "ref-122" "ref-123" "ref-124" "ref-125" "ref-126" "ref-127" "ref-128" "ref-129" "ref-130" "ref-131" "ref-132" "ref-133" "ref-134" "ref-135" "ref-136" "ref-137" "ref-138" "ref-139" "ref-140" "ref-141" "ref-142" "ref-143" "ref-144" "ref-145" "ref-146" "ref-147" "ref-148" "ref-149" "ref-150" "ref-151" "ref-152" "ref-153" "ref-154" "ref-155" "ref-156" "ref-157" "ref-158" "ref-159" "ref-160" "ref-161" "ref-162" "ref-163" "ref-164" "ref-165" "ref-166" "ref-167" "ref-168" "ref-169" "ref-170" "ref-171" "ref-172" "ref-173" "ref-174" "ref-175" "ref-176" "ref-177" "ref-178" "ref-179" "ref-180" "ref-181" "ref-182" "ref-183" "ref-184" "ref-185" "ref-186" "ref-187" "ref-188" "ref-189" "ref-190" "ref-191" "ref-192" "ref-193" "ref-194" "ref-195" "ref-196" "ref-197" "ref-198" "ref-199")) #:capabilities '())
              )
              #:assertions (list (load-test-assert 'p99 '< 250) (load-test-assert 'error-rate '< 0.01))
            )
          ))
      ))
  )
)
