#lang racket

(require
  tesl/dsl/capability
  tesl/dsl/types
  tesl/dsl/check
  tesl/dsl/otel
  tesl/dsl/sql
  tesl/dsl/web
  tesl/dsl/test-support
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
  (let ([tesl_case_0 *s]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl_case_0) 'radius)]) (raw-value (format "circle r=~a" (tesl-display-val (tesl_import_String_fromInt *r)))))] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'ColoredCircle)) (let ([c (hash-ref (adt-value-fields *tesl_case_0) 'color)]) (let ([r (hash-ref (adt-value-fields *tesl_case_0) 'radius)]) (raw-value (format "~a circle r=~a" (tesl-display-val *c) (tesl-display-val (tesl_import_String_fromInt *r))))))] [(and (and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Wrapped)) (let ([tesl_case_0_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_0) 'inner))]) (and (adt-value? *tesl_case_0_f0) (eq? (adt-value-variant *tesl_case_0_f0) 'Something)))) (let ([tesl_case_0_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_0) 'inner))]) (let ([n (hash-ref (adt-value-fields *tesl_case_0_f0) 'value)]) (raw-value (format "wrapped value: ~a" (tesl-display-val (tesl_import_String_fromInt *n))))))] [(and (and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Wrapped)) (let ([tesl_case_0_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_0) 'inner))]) (and (adt-value? *tesl_case_0_f0) (eq? (adt-value-variant *tesl_case_0_f0) 'Nothing)))) (let ([tesl_case_0_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_0) 'inner))]) (raw-value "empty wrapper"))])))

(define-adt Expr
  [Lit [value : Integer]]
  [Neg [inner : Expr]]
  [Add [left : Expr] [right : Expr]]
)

(define/pow
  (evalExpr [e : Expr])
  #:returns Integer
  (let ([tesl_case_1 *e]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Lit)) (let ([value (hash-ref (adt-value-fields *tesl_case_1) 'value)]) *value)] [(and (and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Neg)) (let ([tesl_case_1_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_1) 'inner))]) (and (adt-value? *tesl_case_1_f0) (eq? (adt-value-variant *tesl_case_1_f0) 'Lit)))) (let ([tesl_case_1_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_1) 'inner))]) (let ([n (hash-ref (adt-value-fields *tesl_case_1_f0) 'value)]) (raw-value (- 0 *n))))] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Neg)) (let ([inner (hash-ref (adt-value-fields *tesl_case_1) 'inner)]) (raw-value (- 0 (raw-value (evalExpr *inner)))))] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Add)) (let ([left (hash-ref (adt-value-fields *tesl_case_1) 'left)]) (let ([right (hash-ref (adt-value-fields *tesl_case_1) 'right)]) (raw-value (+ (raw-value (evalExpr *left)) (raw-value (evalExpr *right))))))])))

(define-adt Color
  [RGB [r : Integer] [g : Integer] [b : Integer]]
)

(define/pow
  (describeColorBrightness [c : Color])
  #:returns String
  (let ([tesl_case_2 *c]) (cond [(and (and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'RGB)) (let ([tesl_case_2_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_2) 'r))]) (= *tesl_case_2_f0 255)) (let ([tesl_case_2_f1 (raw-value (hash-ref (adt-value-fields *tesl_case_2) 'g))]) (= *tesl_case_2_f1 255)) (let ([tesl_case_2_f2 (raw-value (hash-ref (adt-value-fields *tesl_case_2) 'b))]) (= *tesl_case_2_f2 255))) (let ([tesl_case_2_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_2) 'r))]) (let ([tesl_case_2_f1 (raw-value (hash-ref (adt-value-fields *tesl_case_2) 'g))]) (let ([tesl_case_2_f2 (raw-value (hash-ref (adt-value-fields *tesl_case_2) 'b))]) (raw-value "white"))))] [(and (and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'RGB)) (let ([tesl_case_2_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_2) 'r))]) (= *tesl_case_2_f0 0)) (let ([tesl_case_2_f1 (raw-value (hash-ref (adt-value-fields *tesl_case_2) 'g))]) (= *tesl_case_2_f1 0)) (let ([tesl_case_2_f2 (raw-value (hash-ref (adt-value-fields *tesl_case_2) 'b))]) (= *tesl_case_2_f2 0))) (let ([tesl_case_2_f0 (raw-value (hash-ref (adt-value-fields *tesl_case_2) 'r))]) (let ([tesl_case_2_f1 (raw-value (hash-ref (adt-value-fields *tesl_case_2) 'g))]) (let ([tesl_case_2_f2 (raw-value (hash-ref (adt-value-fields *tesl_case_2) 'b))]) (raw-value "black"))))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'RGB)) (let ([r (hash-ref (adt-value-fields *tesl_case_2) 'r)]) (let ([g (hash-ref (adt-value-fields *tesl_case_2) 'g)]) (raw-value (format "r=~a g=~a" (tesl-display-val (tesl_import_String_fromInt *r)) (tesl-display-val (tesl_import_String_fromInt *g))))))])))

(define/pow
  (countSomethings [xs : (List (Maybe Integer))])
  #:returns Integer
  (raw-value (tesl_import_List_foldl (let () (define/pow (tesl-lambda-3 [acc : Integer] [x : (Maybe Integer)]) #:returns Integer (let ([tesl_case_4 *x]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Something)) (+ *acc 1)] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Nothing)) acc]))) tesl-lambda-3) 0 *xs)))

(define-adt InnerResult
  [Success [value : Integer]]
  [Failure [message : String]]
)

(define/pow
  (describeResult [m : (Maybe InnerResult)])
  #:returns String
  (let ([tesl_case_5 *m]) (cond [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Nothing)) (raw-value "no result")] [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Something)) (let ([inner (hash-ref (adt-value-fields *tesl_case_5) 'value)]) (let ([tesl_case_6 (raw-value inner)]) (cond [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Success)) (let ([value (hash-ref (adt-value-fields *tesl_case_6) 'value)]) (raw-value (format "success: ~a" (tesl-display-val (tesl_import_String_fromInt *value)))))] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Failure)) (let ([message (hash-ref (adt-value-fields *tesl_case_6) 'message)]) (raw-value (format "failure: ~a" (tesl-display-val *message))))])))])))

(module+ test
  (require rackunit)
  (test-case "describeShape"
  (check-equal? (raw-value (describeShape (Circle 5))) "circle r=5")
  (check-equal? (raw-value (describeShape (ColoredCircle "red" 3))) "red circle r=3")
  (check-equal? (raw-value (describeShape (Wrapped (raw-value (Something 42))))) "wrapped value: 42")
  (check-equal? (raw-value (describeShape (Wrapped Nothing))) "empty wrapper")
  )

  (test-case "evalExpr"
  (check-equal? (raw-value (evalExpr (Lit 7))) 7)
  (check-equal? (raw-value (evalExpr (Neg (Lit 3)))) -3)
  (check-equal? (raw-value (evalExpr (Neg (Add (Lit 1) (Lit 2))))) -3)
  (check-equal? (raw-value (evalExpr (Add (Lit 1) (Lit 2)))) 3)
  (check-equal? (raw-value (evalExpr (Add (Neg (Lit 5)) (Lit 10)))) 5)
  )

  (test-case "describeResult"
  (check-equal? (raw-value (describeResult Nothing)) "no result")
  (check-equal? (raw-value (describeResult (raw-value (Something (Success 42))))) "success: 42")
  (check-equal? (raw-value (describeResult (raw-value (Something (Failure "oops"))))) "failure: oops")
  )

  (test-case "countSomethings"
  (define xs (list (raw-value (Something 1)) Nothing (raw-value (Something 2)) Nothing (raw-value (Something 3))))
  (check-equal? (raw-value (countSomethings xs)) 3)
  (check-equal? (raw-value (countSomethings (list Nothing Nothing))) 0)
  (check-equal? (raw-value (countSomethings (list))) 0)
  )

)
