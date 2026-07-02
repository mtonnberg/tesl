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
  (only-in tesl/tesl/prelude Bool Int String)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/int [Int.nonZero tesl_import_Int_nonZero] [Int.divide tesl_import_Int_divide])
)


(provide Color Red Green Blue Weekday Mon Tue Wed Thu Fri Sat Sun Direction North South East West colorName isWeekend opposite safeDivide Shape Circle Rectangle Point MyMaybe MyNothing MyJust ApiResponse Success NotFound Unauthorized ServerError area describe myFromDefault statusCode responseBody colorName-signature isWeekend-signature opposite-signature safeDivide-signature area-signature describe-signature myFromDefault-signature statusCode-signature responseBody-signature)

(define-adt Color
  [Red]
  [Green]
  [Blue]
)

(define-adt Weekday
  [Mon]
  [Tue]
  [Wed]
  [Thu]
  [Fri]
  [Sat]
  [Sun]
)

(define-adt Direction
  [North]
  [South]
  [East]
  [West]
)

(define/pow
  (colorName [c : Color])
  #:returns String
  (thsl-src-control! "example/learn/lesson02-adts-and-pattern-matching.tesl" 64 (list (cons 'c *c)) (lambda () (let ([tesl-case-0 *c]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Red)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 65 (list) (lambda () (raw-value "red")))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Green)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 66 (list) (lambda () (raw-value "green")))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Blue)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 67 (list) (lambda () (raw-value "blue")))])))))

(define/pow
  (isWeekend [d : Weekday])
  #:returns Boolean
  (thsl-src-control! "example/learn/lesson02-adts-and-pattern-matching.tesl" 70 (list (cons 'd *d)) (lambda () (let ([tesl-case-1 *d]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Sat)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 71 (list) (lambda () (raw-value #t)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Sun)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 72 (list) (lambda () (raw-value #t)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Mon)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 73 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Tue)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 74 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Wed)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 75 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Thu)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 76 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Fri)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 77 (list) (lambda () (raw-value #f)))])))))

(define/pow
  (opposite [d : Direction])
  #:returns Direction
  (thsl-src-control! "example/learn/lesson02-adts-and-pattern-matching.tesl" 80 (list (cons 'd *d)) (lambda () (let ([tesl-case-2 *d]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'North)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 81 (list) (lambda () (raw-value South)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'South)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 82 (list) (lambda () (raw-value North)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'East)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 83 (list) (lambda () (raw-value West)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'West)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 84 (list) (lambda () (raw-value East)))])))))

(define/pow
  (safeDivide [a : Integer] [b : Integer])
  #:returns (Maybe Integer)
  (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 89 (list (cons 'a *a) (cons 'b *b)) (lambda () (if (equal? *b 0) (raw-value Nothing) (let/check ([tesl-checked-3 (tesl_import_Int_nonZero b)]) (let ([safe tesl-checked-3]) (raw-value (raw-value (Something (tesl_import_Int_divide *a safe))))))))))

(define-adt Shape
  [Circle [radius : Integer]]
  [Rectangle [width : Integer] [height : Integer]]
  [Point]
)

(define/pow
  (area [s : Shape])
  #:returns Integer
  (thsl-src-control! "example/learn/lesson02-adts-and-pattern-matching.tesl" 200 (list (cons 's *s)) (lambda () (let ([tesl-case-4 *s]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Circle)) (let ([radius (hash-ref (adt-value-fields *tesl-case-4) 'radius)]) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 201 (list (cons 'radius radius)) (lambda () (raw-value (* *radius *radius)))))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Rectangle)) (let ([width (hash-ref (adt-value-fields *tesl-case-4) 'width)]) (let ([height (hash-ref (adt-value-fields *tesl-case-4) 'height)]) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 202 (list (cons 'width width) (cons 'height height)) (lambda () (raw-value (* *width *height))))))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Point)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 203 (list) (lambda () (raw-value 0)))])))))

(define/pow
  (describe [s : Shape])
  #:returns String
  (thsl-src-control! "example/learn/lesson02-adts-and-pattern-matching.tesl" 206 (list (cons 's *s)) (lambda () (let ([tesl-case-5 *s]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Circle)) (let ([radius (hash-ref (adt-value-fields *tesl-case-5) 'radius)]) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 207 (list (cons 'radius radius)) (lambda () (raw-value (format "circle with radius ~a" (tesl-display-val *radius))))))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Rectangle)) (let ([width (hash-ref (adt-value-fields *tesl-case-5) 'width)]) (let ([height (hash-ref (adt-value-fields *tesl-case-5) 'height)]) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 208 (list (cons 'width width) (cons 'height height)) (lambda () (raw-value (format "rectangle ~a\u00d7~a" (tesl-display-val *width) (tesl-display-val *height)))))))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Point)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 209 (list) (lambda () (raw-value "a point")))])))))

(define-adt MyMaybe
  [MyNothing]
  [MyJust [value : Integer]]
)

(define/pow
  (myFromDefault [m : MyMaybe] [default : Integer])
  #:returns Integer
  (thsl-src-control! "example/learn/lesson02-adts-and-pattern-matching.tesl" 218 (list (cons 'm *m) (cons 'default *default)) (lambda () (let ([tesl-case-6 *m]) (cond [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'MyNothing)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 219 (list) (lambda () *default))] [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'MyJust)) (let ([value (hash-ref (adt-value-fields *tesl-case-6) 'value)]) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 220 (list (cons 'value value)) (lambda () *value)))])))))

(define-adt ApiResponse
  [Success [body : String]]
  [NotFound]
  [Unauthorized]
  [ServerError [message : String]]
)

(define/pow
  (statusCode [r : ApiResponse])
  #:returns Integer
  (thsl-src-control! "example/learn/lesson02-adts-and-pattern-matching.tesl" 230 (list (cons 'r *r)) (lambda () (let ([tesl-case-7 *r]) (cond [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Success)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 231 (list) (lambda () (raw-value 200)))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'NotFound)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 232 (list) (lambda () (raw-value 404)))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Unauthorized)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 233 (list) (lambda () (raw-value 401)))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'ServerError)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 234 (list) (lambda () (raw-value 500)))])))))

(define/pow
  (case_fallbacks_1 [r : ApiResponse])
  #:returns String
  (thsl-src-control! "example/learn/lesson02-adts-and-pattern-matching.tesl" 237 (list (cons 'r *r)) (lambda () (let ([tesl-case-8 *r]) (cond [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Success)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 240 (list) (lambda () (raw-value "This will be the result for all three of Success, NotFound and Unauthorized")))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'NotFound)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 240 (list) (lambda () (raw-value "This will be the result for all three of Success, NotFound and Unauthorized")))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Unauthorized)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 240 (list) (lambda () (raw-value "This will be the result for all three of Success, NotFound and Unauthorized")))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'ServerError)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 241 (list) (lambda () (raw-value "Result for ServerError")))])))))

(define/pow
  (case_fallbacks_2 [r : ApiResponse])
  #:returns String
  (thsl-src-control! "example/learn/lesson02-adts-and-pattern-matching.tesl" 244 (list (cons 'r *r)) (lambda () (let ([tesl-case-9 *r]) (cond [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Success)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 246 (list) (lambda () (raw-value "This will be the result for Success and Unauthorized")))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Unauthorized)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 246 (list) (lambda () (raw-value "This will be the result for Success and Unauthorized")))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'NotFound)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 248 (list) (lambda () (raw-value "Result for NotGound and ServerError")))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'ServerError)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 248 (list) (lambda () (raw-value "Result for NotGound and ServerError")))])))))

(define/pow
  (case_fallbacks_3 [r : ApiResponse])
  #:returns String
  (thsl-src-control! "example/learn/lesson02-adts-and-pattern-matching.tesl" 251 (list (cons 'r *r)) (lambda () (let ([tesl-case-10 *r]) (cond [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'NotFound)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 253 (list) (lambda () (raw-value "This will be the result for NotFound and Unauthorized")))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Unauthorized)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 253 (list) (lambda () (raw-value "This will be the result for NotFound and Unauthorized")))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Success)) (let ([x (hash-ref (adt-value-fields *tesl-case-10) 'body)]) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 255 (list (cons 'x x)) (lambda () *x)))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'ServerError)) (let ([x (hash-ref (adt-value-fields *tesl-case-10) 'message)]) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 255 (list (cons 'x x)) (lambda () *x)))])))))

(define/pow
  (responseBody [r : ApiResponse])
  #:returns String
  (thsl-src-control! "example/learn/lesson02-adts-and-pattern-matching.tesl" 258 (list (cons 'r *r)) (lambda () (let ([tesl-case-11 *r]) (cond [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Success)) (let ([body (hash-ref (adt-value-fields *tesl-case-11) 'body)]) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 259 (list (cons 'body body)) (lambda () *body)))] [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'NotFound)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 260 (list) (lambda () (raw-value "not found")))] [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Unauthorized)) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 261 (list) (lambda () (raw-value "unauthorized")))] [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'ServerError)) (let ([message (hash-ref (adt-value-fields *tesl-case-11) 'message)]) (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 262 (list (cons 'message message)) (lambda () (raw-value (format "error: ~a" (tesl-display-val *message))))))])))))

(module+ test
  (require rackunit)
  (test-case "colorName"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 96 (list) (lambda () (colorName Red)))) "red")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 97 (list) (lambda () (colorName Green)))) "green")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 98 (list) (lambda () (colorName Blue)))) "blue")
  )

  (test-case "isWeekend"
  (check-true (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 102 (list) (lambda () (isWeekend Sat)))))
  (check-true (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 103 (list) (lambda () (isWeekend Sun)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 104 (list) (lambda () (isWeekend Mon)))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 105 (list) (lambda () (isWeekend Fri)))) #f)
  )

  (test-case "opposite"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 109 (list) (lambda () (opposite North)))) South)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 110 (list) (lambda () (opposite South)))) North)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 111 (list) (lambda () (opposite East)))) West)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 112 (list) (lambda () (opposite West)))) East)
  )

  (test-case "safeDivide"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 116 (list) (lambda () (safeDivide 10 2)))) (raw-value (Something 5)))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 117 (list) (lambda () (safeDivide 7 0)))) Nothing)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 118 (list) (lambda () (safeDivide 0 5)))) (raw-value (Something 0)))
  )

  (test-case "Shape area"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 265 (list) (lambda () (area (Circle 5))))) 25)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 266 (list) (lambda () (area (Rectangle 3 4))))) 12)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 267 (list) (lambda () (area Point)))) 0)
  )

  (test-case "MyMaybe"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 271 (list) (lambda () (myFromDefault MyNothing 99)))) 99)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 272 (list) (lambda () (myFromDefault (MyJust 7) 99)))) 7)
  )

  (test-case "statusCode"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 276 (list) (lambda () (statusCode (Success "ok"))))) 200)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 277 (list) (lambda () (statusCode NotFound)))) 404)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 278 (list) (lambda () (statusCode Unauthorized)))) 401)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson02-adts-and-pattern-matching.tesl" 279 (list) (lambda () (statusCode (ServerError "oops"))))) 500)
  )

)
