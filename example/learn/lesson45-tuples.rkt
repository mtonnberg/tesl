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
  (only-in tesl/tesl/tuple Tuple2 Tuple3 [Tuple2.first tesl_import_Tuple2_first] [Tuple2.second tesl_import_Tuple2_second] [Tuple3.first tesl_import_Tuple3_first] [Tuple3.second tesl_import_Tuple3_second] [Tuple3.third tesl_import_Tuple3_third])
  (only-in tesl/tesl/list [List.zip tesl_import_List_zip] [List.map tesl_import_List_map])
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
)


(provide makePoint pointX pointY makeRGB rgbRed rgbGreen rgbBlue swap addPoints describePoint describeRGB taggedLengths pairFirsts classifyPair makePoint-signature pointX-signature pointY-signature swap-signature addPoints-signature describePoint-signature makeRGB-signature rgbRed-signature rgbGreen-signature rgbBlue-signature describeRGB-signature taggedLengths-signature pairFirsts-signature classifyPair-signature)

(define/pow
  (makePoint [x : Integer] [y : Integer])
  #:returns (Tuple2 Integer Integer)
  (thsl-src! "example/learn/lesson45-tuples.tesl" 68 (list (cons 'x *x) (cons 'y *y)) (lambda () (raw-value (Tuple2 *x *y)))))

(define/pow
  (pointX [p : (Tuple2 Integer Integer)])
  #:returns Integer
  (thsl-src! "example/learn/lesson45-tuples.tesl" 70 (list (cons 'p *p)) (lambda () (raw-value (tesl_import_Tuple2_first *p)))))

(define/pow
  (pointY [p : (Tuple2 Integer Integer)])
  #:returns Integer
  (thsl-src! "example/learn/lesson45-tuples.tesl" 71 (list (cons 'p *p)) (lambda () (raw-value (tesl_import_Tuple2_second *p)))))

(define/pow
  (swap [t : (Tuple2 Integer Integer)])
  #:returns (Tuple2 Integer Integer)
  (thsl-src! "example/learn/lesson45-tuples.tesl" 75 (list (cons 't *t)) (lambda () (raw-value (Tuple2 (raw-value (tesl_import_Tuple2_second *t)) (raw-value (tesl_import_Tuple2_first *t)))))))

(define/pow
  (addPoints [p : (Tuple2 Integer Integer)] [q : (Tuple2 Integer Integer)])
  #:returns (Tuple2 Integer Integer)
  (thsl-src! "example/learn/lesson45-tuples.tesl" 79 (list (cons 'p *p) (cons 'q *q)) (lambda () (raw-value (Tuple2 (+ (raw-value (pointX p)) (raw-value (pointX q))) (+ (raw-value (pointY p)) (raw-value (pointY q))))))))

(define/pow
  (describePoint [p : (Tuple2 Integer Integer)])
  #:returns String
  (let ([x (thsl-src! "example/learn/lesson45-tuples.tesl" 83 (list (cons 'p *p)) (lambda () (raw-value (tesl_import_Tuple2_first *p))))]) (let ([y (thsl-src! "example/learn/lesson45-tuples.tesl" 84 (list (cons 'x *x) (cons 'p *p)) (lambda () (raw-value (tesl_import_Tuple2_second *p))))]) (thsl-src! "example/learn/lesson45-tuples.tesl" 85 (list (cons 'y *y) (cons 'x *x) (cons 'p *p)) (lambda () (format "(~a, ~a)" (tesl-display-val *x) (tesl-display-val *y)))))))

(define/pow
  (makeRGB [r : Integer] [g : Integer] [b : Integer])
  #:returns (Tuple3 Integer Integer Integer)
  (thsl-src! "example/learn/lesson45-tuples.tesl" 91 (list (cons 'r *r) (cons 'g *g) (cons 'b *b)) (lambda () (raw-value (Tuple3 *r *g *b)))))

(define/pow
  (rgbRed [c : (Tuple3 Integer Integer Integer)])
  #:returns Integer
  (thsl-src! "example/learn/lesson45-tuples.tesl" 93 (list (cons 'c *c)) (lambda () (raw-value (tesl_import_Tuple3_first *c)))))

(define/pow
  (rgbGreen [c : (Tuple3 Integer Integer Integer)])
  #:returns Integer
  (thsl-src! "example/learn/lesson45-tuples.tesl" 94 (list (cons 'c *c)) (lambda () (raw-value (tesl_import_Tuple3_second *c)))))

(define/pow
  (rgbBlue [c : (Tuple3 Integer Integer Integer)])
  #:returns Integer
  (thsl-src! "example/learn/lesson45-tuples.tesl" 95 (list (cons 'c *c)) (lambda () (raw-value (tesl_import_Tuple3_third *c)))))

(define/pow
  (describeRGB [c : (Tuple3 Integer Integer Integer)])
  #:returns String
  (let ([r (thsl-src! "example/learn/lesson45-tuples.tesl" 99 (list (cons 'c *c)) (lambda () (rgbRed c)))]) (let ([g (thsl-src! "example/learn/lesson45-tuples.tesl" 100 (list (cons 'r *r) (cons 'c *c)) (lambda () (rgbGreen c)))]) (let ([b (thsl-src! "example/learn/lesson45-tuples.tesl" 101 (list (cons 'g *g) (cons 'r *r) (cons 'c *c)) (lambda () (rgbBlue c)))]) (thsl-src! "example/learn/lesson45-tuples.tesl" 102 (list (cons 'b *b) (cons 'g *g) (cons 'r *r) (cons 'c *c)) (lambda () (format "rgb(~a, ~a, ~a)" (tesl-display-val *r) (tesl-display-val *g) (tesl-display-val *b))))))))

(define/pow
  (taggedLengths [labels : (List String)] [values : (List String)])
  #:returns (List Integer)
  (let ([pairs (thsl-src! "example/learn/lesson45-tuples.tesl" 109 (list (cons 'labels *labels) (cons 'values *values)) (lambda () (raw-value (tesl_import_List_zip *labels *values))))]) (thsl-src! "example/learn/lesson45-tuples.tesl" 110 (list (cons 'pairs *pairs) (cons 'labels *labels) (cons 'values *values)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-0 [p : (Tuple2 String String)]) #:returns Integer (+ (raw-value (tesl_import_String_length (raw-value (tesl_import_Tuple2_first *p)))) (raw-value (tesl_import_String_length (raw-value (tesl_import_Tuple2_second *p)))))) tesl-lambda-0) (raw-value pairs)))))))

(define/pow
  (pairFirsts [xs : (List Integer)] [ys : (List Integer)])
  #:returns (List Integer)
  (let ([pairs (thsl-src! "example/learn/lesson45-tuples.tesl" 114 (list (cons 'xs *xs) (cons 'ys *ys)) (lambda () (raw-value (tesl_import_List_zip *xs *ys))))]) (thsl-src! "example/learn/lesson45-tuples.tesl" 115 (list (cons 'pairs *pairs) (cons 'xs *xs) (cons 'ys *ys)) (lambda () (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-1 [p : (Tuple2 Integer Integer)]) #:returns Integer (raw-value (tesl_import_Tuple2_first *p))) tesl-lambda-1) (raw-value pairs)))))))

(define/pow
  (classifyPair [t : (Tuple2 Integer Integer)])
  #:returns String
  (let ([x (thsl-src! "example/learn/lesson45-tuples.tesl" 121 (list (cons 't *t)) (lambda () (raw-value (tesl_import_Tuple2_first *t))))]) (let ([y (thsl-src! "example/learn/lesson45-tuples.tesl" 122 (list (cons 'x *x) (cons 't *t)) (lambda () (raw-value (tesl_import_Tuple2_second *t))))]) (thsl-src! "example/learn/lesson45-tuples.tesl" 123 (list (cons 'y *y) (cons 'x *x) (cons 't *t)) (lambda () (if (tesl-equal? (raw-value x) (raw-value y)) (raw-value "equal") (if (< (raw-value x) (raw-value y)) (raw-value "ascending") (raw-value "descending"))))))))

(module+ test
  (require rackunit)
  (test-case "makePoint / pointX / pointY"
    (call-with-fresh-memory-db '() (lambda ()
  (define p (thsl-src! "example/learn/lesson45-tuples.tesl" 194 (list) (lambda () (makePoint 3 4))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 195 (list (cons 'p p)) (lambda () (pointX p)))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 196 (list (cons 'p p)) (lambda () (pointY p)))) 4)
    ))
  )

  (test-case "swap reverses a 2-tuple"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "example/learn/lesson45-tuples.tesl" 200 (list) (lambda () (raw-value (Tuple2 10 20)))))
  (define s (thsl-src! "example/learn/lesson45-tuples.tesl" 201 (list (cons 't t)) (lambda () (swap t))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 202 (list (cons 's s) (cons 't t)) (lambda () (raw-value (tesl_import_Tuple2_first (raw-value s)))))) 20)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 203 (list (cons 's s) (cons 't t)) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value s)))))) 10)
    ))
  )

  (test-case "addPoints adds component-wise"
    (call-with-fresh-memory-db '() (lambda ()
  (define p (thsl-src! "example/learn/lesson45-tuples.tesl" 207 (list) (lambda () (makePoint 1 2))))
  (define q (thsl-src! "example/learn/lesson45-tuples.tesl" 208 (list (cons 'p p)) (lambda () (makePoint 3 4))))
  (define r (thsl-src! "example/learn/lesson45-tuples.tesl" 209 (list (cons 'q q) (cons 'p p)) (lambda () (addPoints p q))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 210 (list (cons 'r r) (cons 'q q) (cons 'p p)) (lambda () (pointX r)))) 4)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 211 (list (cons 'r r) (cons 'q q) (cons 'p p)) (lambda () (pointY r)))) 6)
    ))
  )

  (test-case "describePoint formats correctly"
    (call-with-fresh-memory-db '() (lambda ()
  (define p (thsl-src! "example/learn/lesson45-tuples.tesl" 215 (list) (lambda () (makePoint 7 9))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 216 (list (cons 'p p)) (lambda () (describePoint p)))) "(7, 9)")
    ))
  )

  (test-case "makeRGB / accessors"
    (call-with-fresh-memory-db '() (lambda ()
  (define c (thsl-src! "example/learn/lesson45-tuples.tesl" 220 (list) (lambda () (makeRGB 255 128 0))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 221 (list (cons 'c c)) (lambda () (rgbRed c)))) 255)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 222 (list (cons 'c c)) (lambda () (rgbGreen c)))) 128)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 223 (list (cons 'c c)) (lambda () (rgbBlue c)))) 0)
    ))
  )

  (test-case "describeRGB formats correctly"
    (call-with-fresh-memory-db '() (lambda ()
  (define c (thsl-src! "example/learn/lesson45-tuples.tesl" 227 (list) (lambda () (makeRGB 0 128 255))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 228 (list (cons 'c c)) (lambda () (describeRGB c)))) "rgb(0, 128, 255)")
    ))
  )

  (test-case "taggedLengths sums label and value lengths"
    (call-with-fresh-memory-db '() (lambda ()
  (define labels (thsl-src! "example/learn/lesson45-tuples.tesl" 232 (list) (lambda () (list "key" "id"))))
  (define values (thsl-src! "example/learn/lesson45-tuples.tesl" 233 (list (cons 'labels labels)) (lambda () (list "hello" "42"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 234 (list (cons 'values values) (cons 'labels labels)) (lambda () (taggedLengths labels values)))) (list 8 4))
    ))
  )

  (test-case "pairFirsts extracts first components"
    (call-with-fresh-memory-db '() (lambda ()
  (define xs (thsl-src! "example/learn/lesson45-tuples.tesl" 238 (list) (lambda () (list 1 2 3))))
  (define ys (thsl-src! "example/learn/lesson45-tuples.tesl" 239 (list (cons 'xs xs)) (lambda () (list 10 20 30))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 240 (list (cons 'ys ys) (cons 'xs xs)) (lambda () (pairFirsts xs ys)))) (list 1 2 3))
    ))
  )

  (test-case "classifyPair: equal"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "example/learn/lesson45-tuples.tesl" 244 (list) (lambda () (raw-value (Tuple2 5 5)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 245 (list (cons 't t)) (lambda () (classifyPair t)))) "equal")
    ))
  )

  (test-case "classifyPair: ascending"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "example/learn/lesson45-tuples.tesl" 249 (list) (lambda () (raw-value (Tuple2 3 7)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 250 (list (cons 't t)) (lambda () (classifyPair t)))) "ascending")
    ))
  )

  (test-case "classifyPair: descending"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "example/learn/lesson45-tuples.tesl" 254 (list) (lambda () (raw-value (Tuple2 9 2)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 255 (list (cons 't t)) (lambda () (classifyPair t)))) "descending")
    ))
  )

  (test-case "Tuple2.first and Tuple2.second on literal tuples"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "example/learn/lesson45-tuples.tesl" 259 (list) (lambda () (raw-value (Tuple2 42 99)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 260 (list (cons 't t)) (lambda () (raw-value (tesl_import_Tuple2_first (raw-value t)))))) 42)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 261 (list (cons 't t)) (lambda () (raw-value (tesl_import_Tuple2_second (raw-value t)))))) 99)
    ))
  )

  (test-case "Tuple3 accessors"
    (call-with-fresh-memory-db '() (lambda ()
  (define t (thsl-src! "example/learn/lesson45-tuples.tesl" 265 (list) (lambda () (raw-value (Tuple3 1 2 3)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 266 (list (cons 't t)) (lambda () (raw-value (tesl_import_Tuple3_first (raw-value t)))))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 267 (list (cons 't t)) (lambda () (raw-value (tesl_import_Tuple3_second (raw-value t)))))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson45-tuples.tesl" 268 (list (cons 't t)) (lambda () (raw-value (tesl_import_Tuple3_third (raw-value t)))))) 3)
    ))
  )

)
