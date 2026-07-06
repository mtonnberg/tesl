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
  (only-in tesl/tesl/prelude Int String List Bool)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/list [List.head tesl_import_List_head] [List.filter tesl_import_List_filter] [List.length tesl_import_List_length])
  (only-in tesl/tesl/int [Int.nonZero tesl_import_Int_nonZero] [Int.divide tesl_import_Int_divide])
  (only-in tesl/tesl/string [String.isEmpty tesl_import_String_isEmpty])
)


(provide safeHead safeDivideInt findUser firstActiveUser combineOptionals getUserName safeHead-signature safeDivideInt-signature findUser-signature firstActiveUser-signature combineOptionals-signature getUserName-signature)

(define-record User
  [id : Integer]
  [name : String]
  [active : Boolean]
)

(define/pow
  (safeHead [xs : (List Integer)])
  #:returns (Maybe Integer)
  (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 40 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_head *xs)))))

(define/pow
  (safeDivideInt [a : Integer] [b : Integer])
  #:returns (Maybe Integer)
  (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 44 (list (cons 'a *a) (cons 'b *b)) (lambda () (if (tesl-equal? *b 0) (raw-value Nothing) (let/check ([tesl-checked-0 (tesl_import_Int_nonZero b)]) (let ([checkedB tesl-checked-0]) (raw-value (raw-value (Something (tesl_import_Int_divide *a checkedB))))))))))

(define/pow
  (hasId [targetId : Integer] [u : User])
  #:returns Boolean
  (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 51 (list (cons 'targetId *targetId) (cons 'u *u)) (lambda () (tesl-equal? (tesl-dot/runtime u 'id 'User) *targetId))))

(define/pow
  (findUser [users : (List User)] [userId : Integer])
  #:returns (Maybe User)
  (let ([matching (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 54 (list (cons 'users *users) (cons 'userId *userId)) (lambda () (tesl_import_List_filter (raw-value (lambda (tesl-p-1-0) (hasId *userId tesl-p-1-0))) *users)))]) (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 55 (list (cons 'matching *matching) (cons 'users *users) (cons 'userId *userId)) (lambda () (raw-value (tesl_import_List_head (raw-value matching)))))))

(define/pow
  (isActive [u : User])
  #:returns Boolean
  (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 58 (list (cons 'u *u)) (lambda () (tesl-dot/runtime u 'active 'User))))

(define/pow
  (firstActiveUser [users : (List User)])
  #:returns (Maybe User)
  (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 61 (list (cons 'users *users)) (lambda () (raw-value (tesl_import_List_head (raw-value (tesl_import_List_filter isActive *users)))))))

(define/pow
  (addInts [a : Integer] [b : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 66 (list (cons 'a *a) (cons 'b *b)) (lambda () (+ *a *b))))

(define/pow
  (combineOptionals [ma : (Maybe Integer)] [mb : (Maybe Integer)])
  #:returns (Maybe Integer)
  (thsl-src-control! "example/learn/lesson23-maybe-and-optional-values.tesl" 69 (list (cons 'ma *ma) (cons 'mb *mb)) (lambda () (let ([tesl-case-2 *ma]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 70 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([a (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 72 (list (cons 'a a)) (lambda () (let ([tesl-case-3 *mb]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 73 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([b (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 74 (list (cons 'b b)) (lambda () (raw-value (raw-value (Something (addInts *a *b)))))))])))))])))))

(define/pow
  (getUserName [mu : (Maybe User)])
  #:returns String
  (thsl-src-control! "example/learn/lesson23-maybe-and-optional-values.tesl" 80 (list (cons 'mu *mu)) (lambda () (let ([tesl-case-4 *mu]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Something)) (let ([u (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 81 (list (cons 'u u)) (lambda () (raw-value (tesl-dot/runtime u 'name 'User)))))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Nothing)) (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 82 (list) (lambda () (raw-value "unknown")))])))))

(module+ test
  (require rackunit)
  (test-case "safeHead returns Nothing for empty list"
    (call-with-fresh-memory-db '() (lambda ()
  (define xs (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 108 (list) (lambda () (list))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 109 (list (cons 'xs xs)) (lambda () (safeHead xs)))) Nothing)
    ))
  )

  (test-case "safeDivideInt returns Nothing for zero divisor"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 113 (list) (lambda () (safeDivideInt 10 0)))) Nothing)
    ))
  )

  (test-case "safeDivideInt returns result for nonzero divisor"
    (call-with-fresh-memory-db '() (lambda ()
  (define result (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 117 (list) (lambda () (safeDivideInt 10 2))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 118 (list (cons 'result result)) (lambda () result))) (raw-value (Something 5)))
    ))
  )

  (test-case "combineOptionals returns Nothing if first is Nothing"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 122 (list) (lambda () (combineOptionals Nothing (raw-value (Something 5)))))) Nothing)
    ))
  )

  (test-case "combineOptionals returns Nothing if second is Nothing"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 126 (list) (lambda () (combineOptionals (raw-value (Something 3)) Nothing)))) Nothing)
    ))
  )

  (test-case "combineOptionals returns sum when both present"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 130 (list) (lambda () (combineOptionals (raw-value (Something 3)) (raw-value (Something 4)))))) (raw-value (Something 7)))
    ))
  )

  (test-case "getUserName returns fallback for Nothing"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson23-maybe-and-optional-values.tesl" 134 (list) (lambda () (getUserName Nothing)))) "unknown")
    ))
  )

)
