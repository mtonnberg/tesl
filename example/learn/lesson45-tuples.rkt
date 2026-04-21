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
  (only-in tesl/tesl/tuple Tuple2 Tuple3 [Tuple2.first tesl_import_Tuple2_first] [Tuple2.second tesl_import_Tuple2_second] [Tuple3.first tesl_import_Tuple3_first] [Tuple3.second tesl_import_Tuple3_second] [Tuple3.third tesl_import_Tuple3_third])
  (only-in tesl/tesl/list [List.zip tesl_import_List_zip] [List.map tesl_import_List_map])
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
)


(provide makePoint pointX pointY makeRGB rgbRed rgbGreen rgbBlue swap addPoints describePoint describeRGB taggedLengths pairFirsts classifyPair makePoint-signature pointX-signature pointY-signature swap-signature addPoints-signature describePoint-signature makeRGB-signature rgbRed-signature rgbGreen-signature rgbBlue-signature describeRGB-signature taggedLengths-signature pairFirsts-signature classifyPair-signature)

(define/pow
  (makePoint [x : Integer] [y : Integer])
  #:returns (Tuple2 Integer Integer)
  (raw-value (Tuple2 *x *y)))

(define/pow
  (pointX [p : (Tuple2 Integer Integer)])
  #:returns Integer
  (raw-value (tesl_import_Tuple2_first *p)))

(define/pow
  (pointY [p : (Tuple2 Integer Integer)])
  #:returns Integer
  (raw-value (tesl_import_Tuple2_second *p)))

(define/pow
  (swap [t : (Tuple2 Integer Integer)])
  #:returns (Tuple2 Integer Integer)
  (raw-value (Tuple2 (raw-value (tesl_import_Tuple2_second *t)) (raw-value (tesl_import_Tuple2_first *t)))))

(define/pow
  (addPoints [p : (Tuple2 Integer Integer)] [q : (Tuple2 Integer Integer)])
  #:returns (Tuple2 Integer Integer)
  (raw-value (Tuple2 (+ (raw-value (pointX p)) (raw-value (pointX q))) (+ (raw-value (pointY p)) (raw-value (pointY q))))))

(define/pow
  (describePoint [p : (Tuple2 Integer Integer)])
  #:returns String
  (let ([x (raw-value (tesl_import_Tuple2_first *p))]) (let ([y (raw-value (tesl_import_Tuple2_second *p))]) (format "(~a, ~a)" (tesl-display-val *x) (tesl-display-val *y)))))

(define/pow
  (makeRGB [r : Integer] [g : Integer] [b : Integer])
  #:returns (Tuple3 Integer Integer Integer)
  (raw-value (Tuple3 *r *g *b)))

(define/pow
  (rgbRed [c : (Tuple3 Integer Integer Integer)])
  #:returns Integer
  (raw-value (tesl_import_Tuple3_first *c)))

(define/pow
  (rgbGreen [c : (Tuple3 Integer Integer Integer)])
  #:returns Integer
  (raw-value (tesl_import_Tuple3_second *c)))

(define/pow
  (rgbBlue [c : (Tuple3 Integer Integer Integer)])
  #:returns Integer
  (raw-value (tesl_import_Tuple3_third *c)))

(define/pow
  (describeRGB [c : (Tuple3 Integer Integer Integer)])
  #:returns String
  (let ([r (rgbRed c)]) (let ([g (rgbGreen c)]) (let ([b (rgbBlue c)]) (format "rgb(~a, ~a, ~a)" (tesl-display-val *r) (tesl-display-val *g) (tesl-display-val *b))))))

(define/pow
  (taggedLengths [labels : (List String)] [values : (List String)])
  #:returns (List Integer)
  (let ([pairs (raw-value (tesl_import_List_zip *labels *values))]) (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-0 [p : (Tuple2 String String)]) #:returns Integer (+ (raw-value (tesl_import_String_length (raw-value (tesl_import_Tuple2_first *p)))) (raw-value (tesl_import_String_length (raw-value (tesl_import_Tuple2_second *p)))))) tesl-lambda-0) (raw-value pairs)))))

(define/pow
  (pairFirsts [xs : (List Integer)] [ys : (List Integer)])
  #:returns (List Integer)
  (let ([pairs (raw-value (tesl_import_List_zip *xs *ys))]) (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-1 [p : (Tuple2 Integer Integer)]) #:returns Integer (raw-value (tesl_import_Tuple2_first *p))) tesl-lambda-1) (raw-value pairs)))))

(define/pow
  (classifyPair [t : (Tuple2 Integer Integer)])
  #:returns String
  (let ([x (raw-value (tesl_import_Tuple2_first *t))]) (let ([y (raw-value (tesl_import_Tuple2_second *t))]) (if (equal? (raw-value x) (raw-value y)) (raw-value "equal") (if (< (raw-value x) (raw-value y)) (raw-value "ascending") (raw-value "descending"))))))

(module+ test
  (require rackunit)
  (test-case "makePoint / pointX / pointY"
  (define p (makePoint 3 4))
  (check-equal? (raw-value (pointX p)) 3)
  (check-equal? (raw-value (pointY p)) 4)
  )

  (test-case "swap reverses a 2-tuple"
  (define t (raw-value (Tuple2 10 20)))
  (define s (swap t))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_first (raw-value s)))) 20)
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_second (raw-value s)))) 10)
  )

  (test-case "addPoints adds component-wise"
  (define p (makePoint 1 2))
  (define q (makePoint 3 4))
  (define r (addPoints p q))
  (check-equal? (raw-value (pointX r)) 4)
  (check-equal? (raw-value (pointY r)) 6)
  )

  (test-case "describePoint formats correctly"
  (define p (makePoint 7 9))
  (check-equal? (raw-value (describePoint p)) "(7, 9)")
  )

  (test-case "makeRGB / accessors"
  (define c (makeRGB 255 128 0))
  (check-equal? (raw-value (rgbRed c)) 255)
  (check-equal? (raw-value (rgbGreen c)) 128)
  (check-equal? (raw-value (rgbBlue c)) 0)
  )

  (test-case "describeRGB formats correctly"
  (define c (makeRGB 0 128 255))
  (check-equal? (raw-value (describeRGB c)) "rgb(0, 128, 255)")
  )

  (test-case "taggedLengths sums label and value lengths"
  (define labels (list "key" "id"))
  (define values (list "hello" "42"))
  (check-equal? (raw-value (taggedLengths labels values)) (list 8 4))
  )

  (test-case "pairFirsts extracts first components"
  (define xs (list 1 2 3))
  (define ys (list 10 20 30))
  (check-equal? (raw-value (pairFirsts xs ys)) (list 1 2 3))
  )

  (test-case "classifyPair: equal"
  (define t (raw-value (Tuple2 5 5)))
  (check-equal? (raw-value (classifyPair t)) "equal")
  )

  (test-case "classifyPair: ascending"
  (define t (raw-value (Tuple2 3 7)))
  (check-equal? (raw-value (classifyPair t)) "ascending")
  )

  (test-case "classifyPair: descending"
  (define t (raw-value (Tuple2 9 2)))
  (check-equal? (raw-value (classifyPair t)) "descending")
  )

  (test-case "Tuple2.first and Tuple2.second on literal tuples"
  (define t (raw-value (Tuple2 42 99)))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_first (raw-value t)))) 42)
  (check-equal? (raw-value (raw-value (tesl_import_Tuple2_second (raw-value t)))) 99)
  )

  (test-case "Tuple3 accessors"
  (define t (raw-value (Tuple3 1 2 3)))
  (check-equal? (raw-value (raw-value (tesl_import_Tuple3_first (raw-value t)))) 1)
  (check-equal? (raw-value (raw-value (tesl_import_Tuple3_second (raw-value t)))) 2)
  (check-equal? (raw-value (raw-value (tesl_import_Tuple3_third (raw-value t)))) 3)
  )

)
