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
  (only-in tesl/tesl/prelude String)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/api-test statusOk statusClientError)
)


(provide WidgetServer)

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "tests/http-methods-tests.tesl" '(63))
(define-capture __inline_capturer_widgetId_1
  [widgetId : String]
  #:parser string-segment)

(define-capture __inline_capturer_widgetId_2
  [widgetId : String]
  #:parser string-segment)

(define-capture __inline_capturer_widgetId_3
  [widgetId : String]
  #:parser string-segment)

(define-capture __inline_capturer_widgetId_4
  [widgetId : String]
  #:parser string-segment)

(define-entity Widget
  #:source (make-hash)
  #:table widgets
  #:primary-key id
  [Id id : String]
  [Label label : String]
  [Tag tag : String]
)

(define-database WidgetDb
  #:backend memory
  #:schema widgets
  #:entities Widget)

(define-record WidgetBody
  [label : String]
)

(define (tesl-codec-encode-WidgetBody _v)
  (error "toJson is forbidden for type WidgetBody: this type cannot be JSON-encoded"))
(define (tesl-codec-decode-WidgetBody-0 _j)
  (define _f_label (tesl-decode-prim-field _j "label" tesl-decode-prim-string))
  (record-value 'WidgetBody (tesl-hash 'label _f_label)))
(register-type-codec! 'WidgetBody tesl-codec-encode-WidgetBody (list tesl-codec-decode-WidgetBody-0))

(define-handler
  (createWidget [body : WidgetBody])
  #:capabilities [dbRead dbWrite]
  #:returns String
  (let ([_ (thsl-src! "tests/http-methods-tests.tesl" 58 (list (cons 'body *body)) (lambda () (insert-one! Widget (tesl-hash 'id "w-new" 'label (tesl-dot/runtime body 'label 'WidgetBody) 'tag "post"))))]) (thsl-src! "tests/http-methods-tests.tesl" 59 (list (cons '_ *_) (cons 'body *body)) (lambda () "created"))))

(define-handler
  (readWidget [widgetId : String])
  #:capabilities [dbRead]
  #:returns String
  (thsl-src-control! "tests/http-methods-tests.tesl" 63 (list (cons 'widgetId *widgetId)) (lambda () (let ([tesl-case-0 (raw-value (let ([tesl_match (select-one (from Widget) (where (==. (entity-field-ref Widget 'id) widgetId)))]) (if tesl_match (Something tesl_match) Nothing)))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/http-methods-tests.tesl" 64 (list) (lambda () (reject "no such widget" #:http-code 404)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([w (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/http-methods-tests.tesl" 65 (list (cons 'w w)) (lambda () (string-append (string-append (raw-value (tesl-dot/runtime w 'label 'Widget)) "/") (raw-value (tesl-dot/runtime w 'tag 'Widget))))))])))))

(define-handler
  (replaceWidget [widgetId : String] [body : WidgetBody])
  #:capabilities [dbRead dbWrite]
  #:returns String
  (let ([_ (thsl-src! "tests/http-methods-tests.tesl" 69 (list (cons 'widgetId *widgetId) (cons 'body *body)) (lambda () (void (update-many! (from Widget) (tesl-hash (entity-field-ref Widget 'label) (tesl-dot/runtime body 'label)) (where (==. (entity-field-ref Widget 'id) widgetId))))))]) (let ([_ (thsl-src! "tests/http-methods-tests.tesl" 72 (list (cons '_ *_) (cons 'widgetId *widgetId) (cons 'body *body)) (lambda () (void (update-many! (from Widget) (tesl-hash (entity-field-ref Widget 'tag) "put") (where (==. (entity-field-ref Widget 'id) widgetId))))))]) (thsl-src! "tests/http-methods-tests.tesl" 75 (list (cons '_ *_) (cons '_ *_) (cons 'widgetId *widgetId) (cons 'body *body)) (lambda () "replaced")))))

(define-handler
  (amendWidget [widgetId : String] [body : WidgetBody])
  #:capabilities [dbRead dbWrite]
  #:returns String
  (let ([_ (thsl-src! "tests/http-methods-tests.tesl" 79 (list (cons 'widgetId *widgetId) (cons 'body *body)) (lambda () (void (update-many! (from Widget) (tesl-hash (entity-field-ref Widget 'label) (tesl-dot/runtime body 'label)) (where (==. (entity-field-ref Widget 'id) widgetId))))))]) (let ([_ (thsl-src! "tests/http-methods-tests.tesl" 82 (list (cons '_ *_) (cons 'widgetId *widgetId) (cons 'body *body)) (lambda () (void (update-many! (from Widget) (tesl-hash (entity-field-ref Widget 'tag) "patch") (where (==. (entity-field-ref Widget 'id) widgetId))))))]) (thsl-src! "tests/http-methods-tests.tesl" 85 (list (cons '_ *_) (cons '_ *_) (cons 'widgetId *widgetId) (cons 'body *body)) (lambda () "amended")))))

(define-handler
  (removeWidget [widgetId : String])
  #:capabilities [dbRead dbWrite]
  #:returns String
  (let ([_ (thsl-src! "tests/http-methods-tests.tesl" 89 (list (cons 'widgetId *widgetId)) (lambda () (delete-many! (from Widget) (where (==. (entity-field-ref Widget 'id) widgetId)))))]) (thsl-src! "tests/http-methods-tests.tesl" 90 (list (cons '_ *_) (cons 'widgetId *widgetId)) (lambda () "removed"))))

(define WidgetServer-sse-routes '())
(define-api WidgetApi
  [createWidget :
    "widgets"
    :> (ReqBody JSON [body : WidgetBody])
    :> (Post JSON String)
    ]
  [readWidget :
    "widgets"
    :> (Capture __inline_capturer_widgetId_1 [widgetId : String])
    :> (Get JSON String)
    ]
  [replaceWidget :
    "widgets"
    :> (Capture __inline_capturer_widgetId_2 [widgetId : String])
    :> (ReqBody JSON [body : WidgetBody])
    :> (Put JSON String)
    ]
  [amendWidget :
    "widgets"
    :> (Capture __inline_capturer_widgetId_3 [widgetId : String])
    :> (ReqBody JSON [body : WidgetBody])
    :> (Patch JSON String)
    ]
  [removeWidget :
    "widgets"
    :> (Capture __inline_capturer_widgetId_4 [widgetId : String])
    :> (Delete JSON String)
    ]
)

(define-server WidgetServer
  #:api WidgetApi
  [createWidget createWidget]
  [readWidget readWidget]
  [replaceWidget replaceWidget]
  [amendWidget amendWidget]
  [removeWidget removeWidget]
)

(module+ test
  (require rackunit)
  (test-case "POST reaches its handler and carries the body"
    (call-with-fresh-memory-db (list WidgetDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (define created (thsl-src! "tests/http-methods-tests.tesl" 128 (list) (lambda () (dispatch-api-test-request WidgetServer 'post (list "widgets") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "label") "first") #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/http-methods-tests.tesl" 129 (list (cons 'created created)) (lambda () (statusOk (raw-value (api-test-field-access-ref created 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/http-methods-tests.tesl" 130 (list (cons 'created created)) (lambda () (api-test-field-access-ref created 'body)))) "created")
              (define read (thsl-src! "tests/http-methods-tests.tesl" 131 (list (cons 'created created)) (lambda () (dispatch-api-test-request WidgetServer 'get (list "widgets" "w-new") #:headers (tesl-hash) #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/http-methods-tests.tesl" 132 (list (cons 'read read) (cons 'created created)) (lambda () (statusOk (raw-value (api-test-field-access-ref read 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/http-methods-tests.tesl" 133 (list (cons 'read read) (cons 'created created)) (lambda () (api-test-field-access-ref read 'body)))) "first/post")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "GET on a missing row is a client error, not a crash"
    (call-with-fresh-memory-db (list WidgetDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (define resp (thsl-src! "tests/http-methods-tests.tesl" 137 (list) (lambda () (dispatch-api-test-request WidgetServer 'get (list "widgets" "never-created") #:headers (tesl-hash) #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/http-methods-tests.tesl" 138 (list (cons 'resp resp)) (lambda () (statusClientError (raw-value (api-test-field-access-ref resp 'status)))))))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "PUT is routed, carries its body, and stamps its own verb"
    (call-with-fresh-memory-db (list WidgetDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (insert-one! Widget (tesl-hash 'id "w-put" 'label "before" 'tag "seed"))
              (define replaced (thsl-src! "tests/http-methods-tests.tesl" 145 (list) (lambda () (dispatch-api-test-request WidgetServer 'put (list "widgets" "w-put") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "label") "after-put") #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/http-methods-tests.tesl" 146 (list (cons 'replaced replaced)) (lambda () (statusOk (raw-value (api-test-field-access-ref replaced 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/http-methods-tests.tesl" 147 (list (cons 'replaced replaced)) (lambda () (api-test-field-access-ref replaced 'body)))) "replaced")
              (define read (thsl-src! "tests/http-methods-tests.tesl" 148 (list (cons 'replaced replaced)) (lambda () (dispatch-api-test-request WidgetServer 'get (list "widgets" "w-put") #:headers (tesl-hash) #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/http-methods-tests.tesl" 149 (list (cons 'read read) (cons 'replaced replaced)) (lambda () (api-test-field-access-ref read 'body)))) "after-put/put")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "PATCH is routed to its own handler, not to PUT's"
    (call-with-fresh-memory-db (list WidgetDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (insert-one! Widget (tesl-hash 'id "w-patch" 'label "before" 'tag "seed"))
              (define amended (thsl-src! "tests/http-methods-tests.tesl" 156 (list) (lambda () (dispatch-api-test-request WidgetServer 'patch (list "widgets" "w-patch") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "label") "after-patch") #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/http-methods-tests.tesl" 157 (list (cons 'amended amended)) (lambda () (statusOk (raw-value (api-test-field-access-ref amended 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/http-methods-tests.tesl" 158 (list (cons 'amended amended)) (lambda () (api-test-field-access-ref amended 'body)))) "amended")
              (define read (thsl-src! "tests/http-methods-tests.tesl" 159 (list (cons 'amended amended)) (lambda () (dispatch-api-test-request WidgetServer 'get (list "widgets" "w-patch") #:headers (tesl-hash) #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/http-methods-tests.tesl" 160 (list (cons 'read read) (cons 'amended amended)) (lambda () (api-test-field-access-ref read 'body)))) "after-patch/patch")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "DELETE is routed and the row is really gone afterwards"
    (call-with-fresh-memory-db (list WidgetDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (insert-one! Widget (tesl-hash 'id "w-del" 'label "doomed" 'tag "seed"))
              (define before (thsl-src! "tests/http-methods-tests.tesl" 167 (list) (lambda () (dispatch-api-test-request WidgetServer 'get (list "widgets" "w-del") #:headers (tesl-hash) #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/http-methods-tests.tesl" 168 (list (cons 'before before)) (lambda () (statusOk (raw-value (api-test-field-access-ref before 'status)))))))
              (define removed (thsl-src! "tests/http-methods-tests.tesl" 169 (list (cons 'before before)) (lambda () (dispatch-api-test-request WidgetServer 'delete (list "widgets" "w-del") #:headers (tesl-hash) #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/http-methods-tests.tesl" 170 (list (cons 'removed removed) (cons 'before before)) (lambda () (statusOk (raw-value (api-test-field-access-ref removed 'status)))))))
              (check-equal? (raw-value (thsl-src! "tests/http-methods-tests.tesl" 171 (list (cons 'removed removed) (cons 'before before)) (lambda () (api-test-field-access-ref removed 'body)))) "removed")
              (define after (thsl-src! "tests/http-methods-tests.tesl" 172 (list (cons 'removed removed) (cons 'before before)) (lambda () (dispatch-api-test-request WidgetServer 'get (list "widgets" "w-del") #:headers (tesl-hash) #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/http-methods-tests.tesl" 173 (list (cons 'after after) (cons 'removed removed) (cons 'before before)) (lambda () (statusClientError (raw-value (api-test-field-access-ref after 'status)))))))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "PUT then PATCH on one path land in different handlers"
    (call-with-fresh-memory-db (list WidgetDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (insert-one! Widget (tesl-hash 'id "w-seq" 'label "v0" 'tag "seed"))
              (define tesl-ignored-1 (thsl-src! "tests/http-methods-tests.tesl" 185 (list) (lambda () (dispatch-api-test-request WidgetServer 'put (list "widgets" "w-seq") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "label") "v1") #:capabilities (list dbRead dbWrite)))))
              (define afterPut (thsl-src! "tests/http-methods-tests.tesl" 186 (list) (lambda () (dispatch-api-test-request WidgetServer 'get (list "widgets" "w-seq") #:headers (tesl-hash) #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/http-methods-tests.tesl" 187 (list (cons 'afterPut afterPut)) (lambda () (api-test-field-access-ref afterPut 'body)))) "v1/put")
              (define tesl-ignored-2 (thsl-src! "tests/http-methods-tests.tesl" 188 (list (cons 'afterPut afterPut)) (lambda () (dispatch-api-test-request WidgetServer 'patch (list "widgets" "w-seq") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "label") "v2") #:capabilities (list dbRead dbWrite)))))
              (define afterPatch (thsl-src! "tests/http-methods-tests.tesl" 189 (list (cons 'afterPut afterPut)) (lambda () (dispatch-api-test-request WidgetServer 'get (list "widgets" "w-seq") #:headers (tesl-hash) #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/http-methods-tests.tesl" 190 (list (cons 'afterPatch afterPatch) (cons 'afterPut afterPut)) (lambda () (api-test-field-access-ref afterPatch 'body)))) "v2/patch")
              (define tesl-ignored-3 (thsl-src! "tests/http-methods-tests.tesl" 191 (list (cons 'afterPatch afterPatch) (cons 'afterPut afterPut)) (lambda () (dispatch-api-test-request WidgetServer 'put (list "widgets" "w-seq") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "label") "v3") #:capabilities (list dbRead dbWrite)))))
              (define afterPut2 (thsl-src! "tests/http-methods-tests.tesl" 192 (list (cons 'afterPatch afterPatch) (cons 'afterPut afterPut)) (lambda () (dispatch-api-test-request WidgetServer 'get (list "widgets" "w-seq") #:headers (tesl-hash) #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/http-methods-tests.tesl" 193 (list (cons 'afterPut2 afterPut2) (cons 'afterPatch afterPatch) (cons 'afterPut afterPut)) (lambda () (api-test-field-access-ref afterPut2 'body)))) "v3/put")
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "DELETE on a path that declares only POST is refused"
    (call-with-fresh-memory-db (list WidgetDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (define resp (thsl-src! "tests/http-methods-tests.tesl" 202 (list) (lambda () (dispatch-api-test-request WidgetServer 'delete (list "widgets") #:headers (tesl-hash) #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/http-methods-tests.tesl" 203 (list (cons 'resp resp)) (lambda () (statusClientError (raw-value (api-test-field-access-ref resp 'status)))))))
            )
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "POST on a path that declares no POST is refused"
    (call-with-fresh-memory-db (list WidgetDb)
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (with-capabilities (dbRead dbWrite)
              (insert-one! Widget (tesl-hash 'id "w-nopost" 'label "untouched" 'tag "seed"))
              (define resp (thsl-src! "tests/http-methods-tests.tesl" 210 (list) (lambda () (dispatch-api-test-request WidgetServer 'post (list "widgets" "w-nopost") #:headers (tesl-hash) #:body (tesl-hash (string->symbol "label") "should not apply") #:capabilities (list dbRead dbWrite)))))
              (check-true (raw-value (thsl-src! "tests/http-methods-tests.tesl" 211 (list (cons 'resp resp)) (lambda () (statusClientError (raw-value (api-test-field-access-ref resp 'status)))))))
              (define read (thsl-src! "tests/http-methods-tests.tesl" 212 (list (cons 'resp resp)) (lambda () (dispatch-api-test-request WidgetServer 'get (list "widgets" "w-nopost") #:headers (tesl-hash) #:capabilities (list dbRead dbWrite)))))
              (check-equal? (raw-value (thsl-src! "tests/http-methods-tests.tesl" 213 (list (cons 'read read) (cons 'resp resp)) (lambda () (api-test-field-access-ref read 'body)))) "untouched/seed")
            )
          ))
      ))
  )
)
