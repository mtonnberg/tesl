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
  (only-in tesl/tesl/prelude Bool Int String Unit)
  (only-in tesl/tesl/api-test statusOk)
  (only-in tesl/tesl/email EmailBody TextBody HtmlBody RichBody)
)


(provide MainServer)

(define/pow
  (mkBody [name : String])
  #:returns EmailBody
  (thsl-src! "tests/emit-incidentals-regressions.tesl" 31 (list (cons 'name *name)) (lambda () (raw-value (RichBody (format "hi ~a" (tesl-display-val *name)) (format "<b>hi ~a</b>" (tesl-display-val *name)))))))

(define/pow
  (mkText [s : String])
  #:returns EmailBody
  (thsl-src! "tests/emit-incidentals-regressions.tesl" 34 (list (cons 's *s)) (lambda () (raw-value (TextBody *s)))))

(define/pow
  (bodyKind [b : EmailBody])
  #:returns String
  (thsl-src-control! "tests/emit-incidentals-regressions.tesl" 37 (list (cons 'b *b)) (lambda () (let ([tesl-case-0 *b]) (cond [(and (pair? *tesl-case-0) (eq? (car *tesl-case-0) 'TextBody)) (let ([t (list-ref *tesl-case-0 1)]) (thsl-src! "tests/emit-incidentals-regressions.tesl" 38 (list (cons 't t)) (lambda () (raw-value "text"))))] [(and (pair? *tesl-case-0) (eq? (car *tesl-case-0) 'HtmlBody)) (let ([h (list-ref *tesl-case-0 1)]) (thsl-src! "tests/emit-incidentals-regressions.tesl" 39 (list (cons 'h h)) (lambda () (raw-value "html"))))] [(and (pair? *tesl-case-0) (eq? (car *tesl-case-0) 'RichBody)) (let ([t (list-ref *tesl-case-0 1)]) (let ([h (list-ref *tesl-case-0 2)]) (thsl-src! "tests/emit-incidentals-regressions.tesl" 40 (list (cons 't t) (cons 'h h)) (lambda () (raw-value "rich")))))])))))

(define/pow
  (addN [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "tests/emit-incidentals-regressions.tesl" 53 (list (cons 'a *a) (cons 'b *b)) (lambda () (+ *a *b))))

(define/pow
  (applyTwice [f : (-> Integer Integer)] [n : Integer])
  #:returns Integer
  (thsl-src! "tests/emit-incidentals-regressions.tesl" 56 (list (cons 'f *f) (cons 'n *n)) (lambda () (raw-value (f (f n))))))

(define-newtype UserId String)

(define-record User
  [id : UserId]
  [name : String]
)

(define (tesl-codec-encode-User _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'id (tesl-encode-prim-string (raw-value (hash-ref _fields 'id)))
        'name (tesl-encode-prim-string (raw-value (hash-ref _fields 'name)))
  ))
(define (tesl-codec-decode-User-0 _j)
  (define _f_id (UserId (tesl-decode-prim-field _j "id" tesl-decode-prim-string)))
  (define _f_name (tesl-decode-prim-field _j "name" tesl-decode-prim-string))
  (record-value 'User (hash 'id _f_id 'name _f_name)))
(register-type-codec! 'User tesl-codec-encode-User (list tesl-codec-decode-User-0))

(define-newtype AcctId String)

(define-record Acct
  [id : AcctId]
  [name : String]
)

(define (tesl-codec-encode-Acct _v)
  (define _raw
    (let loop ([v _v])
      (cond [(named-value? v) (loop (named-value-value v))]
            [(check-ok? v) (loop (check-ok-value v))]
            [else v])))
  (define _fields (record-value-fields _raw))
  (hash 'id (tesl-codec-encode-field (raw-value (hash-ref _fields 'id)) 'AcctId)
        'name (tesl-encode-prim-string (raw-value (hash-ref _fields 'name)))
  ))
(define (tesl-codec-decode-Acct-0 _j)
  (define _f_id (AcctId (tesl-decode-prim-field _j "id" tesl-decode-prim-string)))
  (define _f_name (tesl-decode-prim-field _j "name" tesl-decode-prim-string))
  (record-value 'Acct (hash 'id _f_id 'name _f_name)))
(register-type-codec! 'Acct tesl-codec-encode-Acct (list tesl-codec-decode-Acct-0))

(define-handler
  (getUser [uid : String])
  #:returns User
  (let ([typed (thsl-src! "tests/emit-incidentals-regressions.tesl" 110 (list (cons 'uid *uid)) (lambda () (raw-value (UserId *uid))))]) (thsl-src! "tests/emit-incidentals-regressions.tesl" 111 (list (cons 'typed *typed) (cons 'uid *uid)) (lambda () (User #:id *typed #:name (format "user-~a" (tesl-display-val (raw-value typed.value))))))))

(define-handler
  (echoUser [body : User])
  #:returns User
  (thsl-src! "tests/emit-incidentals-regressions.tesl" 114 (list (cons 'body *body)) (lambda () (tesl-record-update *body (hash 'id (raw-value (raw-value (UserId "echoed"))))))))

(define-handler
  (getAcct [aid : String])
  #:returns Acct
  (let ([typed (thsl-src! "tests/emit-incidentals-regressions.tesl" 117 (list (cons 'aid *aid)) (lambda () (raw-value (AcctId *aid))))]) (thsl-src! "tests/emit-incidentals-regressions.tesl" 118 (list (cons 'typed *typed) (cons 'aid *aid)) (lambda () (Acct #:id *typed #:name (format "acct-~a" (tesl-display-val (raw-value typed.value))))))))

(define-handler
  (echoAcct [body : Acct])
  #:returns Acct
  (thsl-src! "tests/emit-incidentals-regressions.tesl" 121 (list (cons 'body *body)) (lambda () (tesl-record-update *body (hash 'id (raw-value (raw-value (AcctId "echoed"))))))))

(define-capture uidCapture
  [uid : String]
  #:parser string-segment)

(define MainServer-sse-routes '())
(define-api MainApi
  [getUser :
    "users"
    :> (Capture uidCapture [uid : String])
    :> (Get JSON User)
    ]
  [echoUser :
    "users"
    :> "echo"
    :> (ReqBody JSON [body : User])
    :> (Post JSON User)
    ]
  [getAcct :
    "accts"
    :> (Capture uidCapture [uid : String])
    :> (Get JSON Acct)
    ]
  [echoAcct :
    "accts"
    :> "echo"
    :> (ReqBody JSON [body : Acct])
    :> (Post JSON Acct)
    ]
)

(define-server MainServer
  #:api MainApi
  [getUser getUser]
  [echoUser echoUser]
  [getAcct getAcct]
  [echoAcct echoAcct]
)

(module+ test
  (require rackunit)
  (test-case "newtype field encodes transparently (stringCodec spelling)"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (dispatch-api-test-request MainServer 'get (list "users" "u-9") #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref r 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref r 'body) 'id)) "u-9")
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref r 'body) 'name)) "user-u-9")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "newtype field decodes + re-encodes (stringCodec spelling)"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (dispatch-api-test-request MainServer 'post (list "users" "echo") #:headers (hash) #:body (hash (string->symbol "id") "ignored" (string->symbol "name") "bob") #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref r 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref r 'body) 'id)) "echoed")
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref r 'body) 'name)) "bob")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "newtype field encodes transparently (with_codec TypeName spelling)"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (dispatch-api-test-request MainServer 'get (list "accts" "a-1") #:headers (hash) #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref r 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref r 'body) 'id)) "a-1")
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref r 'body) 'name)) "acct-a-1")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "newtype field decodes + re-encodes (with_codec TypeName spelling)"
    (call-with-fresh-memory-db '()
      (lambda ()
        (call-with-api-test-subscriptions
          (lambda ()
            (define r (dispatch-api-test-request MainServer 'post (list "accts" "echo") #:headers (hash) #:body (hash (string->symbol "id") "ignored" (string->symbol "name") "eve") #:capabilities '()))
            (check-true (raw-value (statusOk (raw-value (api-test-field-access-ref r 'status)))))
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref r 'body) 'id)) "echoed")
            (check-equal? (raw-value (api-test-field-access-ref (api-test-field-access-ref r 'body) 'name)) "eve")
          ))
      ))
  )
)

(module+ test
  (require rackunit)
  (test-case "fn returning EmailBody satisfies its declared return type"
    (call-with-fresh-memory-db '() (lambda ()
  (define b (thsl-src! "tests/emit-incidentals-regressions.tesl" 43 (list) (lambda () (mkBody "x"))))
  (check-equal? (raw-value (thsl-src! "tests/emit-incidentals-regressions.tesl" 44 (list (cons 'b b)) (lambda () (bodyKind b)))) "rich")
  (define t (thsl-src! "tests/emit-incidentals-regressions.tesl" 45 (list (cons 'b b)) (lambda () (mkText "plain"))))
  (check-equal? (raw-value (thsl-src! "tests/emit-incidentals-regressions.tesl" 46 (list (cons 't t) (cons 'b b)) (lambda () (bodyKind t)))) "text")
  (check-equal? (raw-value (thsl-src! "tests/emit-incidentals-regressions.tesl" 47 (list (cons 't t) (cons 'b b)) (lambda () (bodyKind (HtmlBody "<i>h</i>"))))) "html")
    ))
  )

  (test-case "partial application in argument position"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/emit-incidentals-regressions.tesl" 59 (list) (lambda () (applyTwice (lambda (tesl-p-1-0) (addN 3 tesl-p-1-0)) 1)))) 7)
    ))
  )

  (test-case "named partial application still works"
    (call-with-fresh-memory-db '() (lambda ()
  (define addTen (thsl-src! "tests/emit-incidentals-regressions.tesl" 63 (list) (lambda () (lambda (tesl-p-2-0) (addN 10 tesl-p-2-0)))))
  (check-equal? (raw-value (thsl-src! "tests/emit-incidentals-regressions.tesl" 64 (list (cons 'addTen addTen)) (lambda () (addTen 5)))) 15)
    ))
  )

)
