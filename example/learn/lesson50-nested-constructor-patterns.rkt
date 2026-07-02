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
  (only-in tesl/tesl/prelude Bool Int String List)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/string [String.fromInt tesl_import_String_fromInt])
  (only-in tesl/tesl/list [List.foldl tesl_import_List_foldl])
)


(provide Shape Circle ColoredCircle Wrapped Color RGB Expr Lit Neg Add describeShape evalExpr countSomethings describeResult describeShape-signature evalExpr-signature countSomethings-signature describeResult-signature)

(define-adt Shape
  [Circle [radius : Integer]]
  [ColoredCircle [color : String] [radius : Integer]]
  [Wrapped [inner : (Maybe Integer)]]
)

(define/pow
  (describeShape [s : Shape])
  #:returns String
  (thsl-src-control! "example/learn/lesson50-nested-constructor-patterns.tesl" 50 (list (cons 's *s)) (lambda () (let ([tesl-case-0 *s]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl-case-0) 'radius)]) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 51 (list (cons 'r r)) (lambda () (raw-value (format "circle r=~a" (tesl-display-val (tesl_import_String_fromInt *r)))))))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'ColoredCircle)) (let ([c (hash-ref (adt-value-fields *tesl-case-0) 'color)]) (let ([r (hash-ref (adt-value-fields *tesl-case-0) 'radius)]) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 52 (list (cons 'c c) (cons 'r r)) (lambda () (raw-value (format "~a circle r=~a" (tesl-display-val *c) (tesl-display-val (tesl_import_String_fromInt *r))))))))] [(and (and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Wrapped)) (let ([tesl-case-0_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-0) 'inner))]) (and (adt-value? *tesl-case-0_f0) (eq? (adt-value-variant *tesl-case-0_f0) 'Something)))) (let ([tesl-case-0_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-0) 'inner))]) (let ([n (hash-ref (adt-value-fields *tesl-case-0_f0) 'value)]) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 53 (list (cons 'n n)) (lambda () (raw-value (format "wrapped value: ~a" (tesl-display-val (tesl_import_String_fromInt *n))))))))] [(and (and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Wrapped)) (let ([tesl-case-0_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-0) 'inner))]) (and (adt-value? *tesl-case-0_f0) (eq? (adt-value-variant *tesl-case-0_f0) 'Nothing)))) (let ([tesl-case-0_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-0) 'inner))]) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 54 (list) (lambda () (raw-value "empty wrapper"))))])))))

(define-adt Expr
  [Lit [value : Integer]]
  [Neg [inner : Expr]]
  [Add [left : Expr] [right : Expr]]
)

(define/pow
  (evalExpr [e : Expr])
  #:returns Integer
  (thsl-src-control! "example/learn/lesson50-nested-constructor-patterns.tesl" 69 (list (cons 'e *e)) (lambda () (let ([tesl-case-1 *e]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Lit)) (let ([value (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 70 (list (cons 'value value)) (lambda () *value)))] [(and (and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Neg)) (let ([tesl-case-1_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-1) 'inner))]) (and (adt-value? *tesl-case-1_f0) (eq? (adt-value-variant *tesl-case-1_f0) 'Lit)))) (let ([tesl-case-1_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-1) 'inner))]) (let ([n (hash-ref (adt-value-fields *tesl-case-1_f0) 'value)]) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 71 (list (cons 'n n)) (lambda () (raw-value (- 0 *n))))))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Neg)) (let ([inner (hash-ref (adt-value-fields *tesl-case-1) 'inner)]) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 72 (list (cons 'inner inner)) (lambda () (raw-value (- 0 (raw-value (evalExpr *inner)))))))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Add)) (let ([left (hash-ref (adt-value-fields *tesl-case-1) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl-case-1) 'right)]) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 73 (list (cons 'left left) (cons 'right right)) (lambda () (raw-value (+ (raw-value (evalExpr *left)) (raw-value (evalExpr *right))))))))])))))

(define-adt Color
  [RGB [r : Integer] [g : Integer] [b : Integer]]
)

(define/pow
  (describeColorBrightness [c : Color])
  #:returns String
  (thsl-src-control! "example/learn/lesson50-nested-constructor-patterns.tesl" 83 (list (cons 'c *c)) (lambda () (let ([tesl-case-2 *c]) (cond [(and (and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'RGB)) (let ([tesl-case-2_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-2) 'r))]) (= *tesl-case-2_f0 255)) (let ([tesl-case-2_f1 (raw-value (hash-ref (adt-value-fields *tesl-case-2) 'g))]) (= *tesl-case-2_f1 255)) (let ([tesl-case-2_f2 (raw-value (hash-ref (adt-value-fields *tesl-case-2) 'b))]) (= *tesl-case-2_f2 255))) (let ([tesl-case-2_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-2) 'r))]) (let ([tesl-case-2_f1 (raw-value (hash-ref (adt-value-fields *tesl-case-2) 'g))]) (let ([tesl-case-2_f2 (raw-value (hash-ref (adt-value-fields *tesl-case-2) 'b))]) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 84 (list) (lambda () (raw-value "white"))))))] [(and (and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'RGB)) (let ([tesl-case-2_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-2) 'r))]) (= *tesl-case-2_f0 0)) (let ([tesl-case-2_f1 (raw-value (hash-ref (adt-value-fields *tesl-case-2) 'g))]) (= *tesl-case-2_f1 0)) (let ([tesl-case-2_f2 (raw-value (hash-ref (adt-value-fields *tesl-case-2) 'b))]) (= *tesl-case-2_f2 0))) (let ([tesl-case-2_f0 (raw-value (hash-ref (adt-value-fields *tesl-case-2) 'r))]) (let ([tesl-case-2_f1 (raw-value (hash-ref (adt-value-fields *tesl-case-2) 'g))]) (let ([tesl-case-2_f2 (raw-value (hash-ref (adt-value-fields *tesl-case-2) 'b))]) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 85 (list) (lambda () (raw-value "black"))))))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'RGB)) (let ([r (hash-ref (adt-value-fields *tesl-case-2) 'r)]) (let ([g (hash-ref (adt-value-fields *tesl-case-2) 'g)]) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 86 (list (cons 'r r) (cons 'g g)) (lambda () (raw-value (format "r=~a g=~a" (tesl-display-val (tesl_import_String_fromInt *r)) (tesl-display-val (tesl_import_String_fromInt *g))))))))])))))

(define/pow
  (countSomethings [xs : (List (Maybe Integer))])
  #:returns Integer
  (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 97 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-3 [acc : Integer] [x : (Maybe Integer)]) #:returns Integer (let ([tesl-case-4 *x]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Something)) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 99 (list) (lambda () (+ *acc 1)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Nothing)) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 100 (list) (lambda () acc))]))) tesl-lambda-3) 0 *xs)))))

(define-adt InnerResult
  [Success [value : Integer]]
  [Failure [message : String]]
)

(define/pow
  (describeResult [m : (Maybe InnerResult)])
  #:returns String
  (thsl-src-control! "example/learn/lesson50-nested-constructor-patterns.tesl" 112 (list (cons 'm *m)) (lambda () (let ([tesl-case-5 *m]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Nothing)) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 113 (list) (lambda () (raw-value "no result")))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Something)) (let ([inner (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 115 (list (cons 'inner inner)) (lambda () (let ([tesl-case-6 (raw-value inner)]) (cond [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Success)) (let ([value (hash-ref (adt-value-fields *tesl-case-6) 'value)]) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 116 (list (cons 'value value)) (lambda () (raw-value (format "success: ~a" (tesl-display-val (tesl_import_String_fromInt *value)))))))] [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Failure)) (let ([message (hash-ref (adt-value-fields *tesl-case-6) 'message)]) (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 117 (list (cons 'message message)) (lambda () (raw-value (format "failure: ~a" (tesl-display-val *message))))))])))))])))))

(module+ test
  (require rackunit)
  (test-case "describeShape"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 154 (list) (lambda () (describeShape (Circle 5))))) "circle r=5")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 155 (list) (lambda () (describeShape (ColoredCircle "red" 3))))) "red circle r=3")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 156 (list) (lambda () (describeShape (Wrapped (raw-value (Something 42))))))) "wrapped value: 42")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 157 (list) (lambda () (describeShape (Wrapped Nothing))))) "empty wrapper")
  )

  (test-case "evalExpr"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 161 (list) (lambda () (evalExpr (Lit 7))))) 7)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 162 (list) (lambda () (evalExpr (Neg (Lit 3)))))) -3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 163 (list) (lambda () (evalExpr (Neg (Add (Lit 1) (Lit 2))))))) -3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 164 (list) (lambda () (evalExpr (Add (Lit 1) (Lit 2)))))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 165 (list) (lambda () (evalExpr (Add (Neg (Lit 5)) (Lit 10)))))) 5)
  )

  (test-case "describeResult"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 169 (list) (lambda () (describeResult Nothing)))) "no result")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 170 (list) (lambda () (describeResult (raw-value (Something (Success 42))))))) "success: 42")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 171 (list) (lambda () (describeResult (raw-value (Something (Failure "oops"))))))) "failure: oops")
  )

  (test-case "countSomethings"
  (define xs (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 175 (list) (lambda () (list (raw-value (Something 1)) Nothing (raw-value (Something 2)) Nothing (raw-value (Something 3))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 176 (list (cons 'xs xs)) (lambda () (countSomethings xs)))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 177 (list (cons 'xs xs)) (lambda () (countSomethings (list Nothing Nothing))))) 0)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson50-nested-constructor-patterns.tesl" 178 (list (cons 'xs xs)) (lambda () (countSomethings (list))))) 0)
  )

)
