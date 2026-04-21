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
  (let ([tesl_case_0 *c]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Red)) (raw-value "red")] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Green)) (raw-value "green")] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Blue)) (raw-value "blue")])))

(define/pow
  (isWeekend [d : Weekday])
  #:returns Boolean
  (let ([tesl_case_1 *d]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Sat)) (raw-value #t)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Sun)) (raw-value #t)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Mon)) (raw-value #f)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Tue)) (raw-value #f)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Wed)) (raw-value #f)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Thu)) (raw-value #f)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Fri)) (raw-value #f)])))

(define/pow
  (opposite [d : Direction])
  #:returns Direction
  (let ([tesl_case_2 *d]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'North)) (raw-value South)] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'South)) (raw-value North)] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'East)) (raw-value West)] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'West)) (raw-value East)])))

(define/pow
  (safeDivide [a : Integer] [b : Integer])
  #:returns (Maybe Integer)
  (if (equal? *b 0) (raw-value Nothing) (let/check ([tesl_checked_3 (tesl_import_Int_nonZero b)]) (let ([safe tesl_checked_3]) (raw-value (raw-value (Something (tesl_import_Int_divide *a safe))))))))

(define-adt Shape
  [Circle [radius : Integer]]
  [Rectangle [width : Integer] [height : Integer]]
  [Point]
)

(define/pow
  (area [s : Shape])
  #:returns Integer
  (let ([tesl_case_4 *s]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Circle)) (let ([radius (hash-ref (adt-value-fields *tesl_case_4) 'radius)]) (raw-value (* *radius *radius)))] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Rectangle)) (let ([width (hash-ref (adt-value-fields *tesl_case_4) 'width)]) (let ([height (hash-ref (adt-value-fields *tesl_case_4) 'height)]) (raw-value (* *width *height))))] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Point)) (raw-value 0)])))

(define/pow
  (describe [s : Shape])
  #:returns String
  (let ([tesl_case_5 *s]) (cond [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Circle)) (let ([radius (hash-ref (adt-value-fields *tesl_case_5) 'radius)]) (raw-value (format "circle with radius ~a" (tesl-display-val *radius))))] [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Rectangle)) (let ([width (hash-ref (adt-value-fields *tesl_case_5) 'width)]) (let ([height (hash-ref (adt-value-fields *tesl_case_5) 'height)]) (raw-value (format "rectangle ~a\u00d7~a" (tesl-display-val *width) (tesl-display-val *height)))))] [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Point)) (raw-value "a point")])))

(define-adt MyMaybe
  [MyNothing]
  [MyJust [value : Integer]]
)

(define/pow
  (myFromDefault [m : MyMaybe] [default : Integer])
  #:returns Integer
  (let ([tesl_case_6 *m]) (cond [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'MyNothing)) *default] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'MyJust)) (let ([value (hash-ref (adt-value-fields *tesl_case_6) 'value)]) *value)])))

(define-adt ApiResponse
  [Success [body : String]]
  [NotFound]
  [Unauthorized]
  [ServerError [message : String]]
)

(define/pow
  (statusCode [r : ApiResponse])
  #:returns Integer
  (let ([tesl_case_7 *r]) (cond [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Success)) (raw-value 200)] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'NotFound)) (raw-value 404)] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Unauthorized)) (raw-value 401)] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'ServerError)) (raw-value 500)])))

(define/pow
  (case_fallbacks_1 [r : ApiResponse])
  #:returns String
  (let ([tesl_case_8 *r]) (cond [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Success)) (raw-value "This will be the result for all three of Success, NotFound and Unauthorized")] [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'NotFound)) (raw-value "This will be the result for all three of Success, NotFound and Unauthorized")] [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Unauthorized)) (raw-value "This will be the result for all three of Success, NotFound and Unauthorized")] [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'ServerError)) (raw-value "Result for ServerError")])))

(define/pow
  (case_fallbacks_2 [r : ApiResponse])
  #:returns String
  (let ([tesl_case_9 *r]) (cond [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Success)) (raw-value "This will be the result for Success and Unauthorized")] [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Unauthorized)) (raw-value "This will be the result for Success and Unauthorized")] [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'NotFound)) (raw-value "Result for NotGound and ServerError")] [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'ServerError)) (raw-value "Result for NotGound and ServerError")])))

(define/pow
  (case_fallbacks_3 [r : ApiResponse])
  #:returns String
  (let ([tesl_case_10 *r]) (cond [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'NotFound)) (raw-value "This will be the result for NotFound and Unauthorized")] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Unauthorized)) (raw-value "This will be the result for NotFound and Unauthorized")] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Success)) (let ([x (hash-ref (adt-value-fields *tesl_case_10) 'body)]) *x)] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'ServerError)) (let ([x (hash-ref (adt-value-fields *tesl_case_10) 'message)]) *x)])))

(define/pow
  (responseBody [r : ApiResponse])
  #:returns String
  (let ([tesl_case_11 *r]) (cond [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Success)) (let ([body (hash-ref (adt-value-fields *tesl_case_11) 'body)]) *body)] [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'NotFound)) (raw-value "not found")] [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Unauthorized)) (raw-value "unauthorized")] [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'ServerError)) (let ([message (hash-ref (adt-value-fields *tesl_case_11) 'message)]) (raw-value (format "error: ~a" (tesl-display-val *message))))])))

(module+ test
  (require rackunit)
  (test-case "colorName"
  (check-equal? (raw-value (colorName Red)) "red")
  (check-equal? (raw-value (colorName Green)) "green")
  (check-equal? (raw-value (colorName Blue)) "blue")
  )

  (test-case "isWeekend"
  (check-true (raw-value (isWeekend Sat)))
  (check-true (raw-value (isWeekend Sun)))
  (check-equal? (raw-value (isWeekend Mon)) #f)
  (check-equal? (raw-value (isWeekend Fri)) #f)
  )

  (test-case "opposite"
  (check-equal? (raw-value (opposite North)) South)
  (check-equal? (raw-value (opposite South)) North)
  (check-equal? (raw-value (opposite East)) West)
  (check-equal? (raw-value (opposite West)) East)
  )

  (test-case "safeDivide"
  (check-equal? (raw-value (safeDivide 10 2)) (raw-value (Something 5)))
  (check-equal? (raw-value (safeDivide 7 0)) Nothing)
  (check-equal? (raw-value (safeDivide 0 5)) (raw-value (Something 0)))
  )

  (test-case "Shape area"
  (check-equal? (raw-value (area (Circle 5))) 25)
  (check-equal? (raw-value (area (Rectangle 3 4))) 12)
  (check-equal? (raw-value (area Point)) 0)
  )

  (test-case "MyMaybe"
  (check-equal? (raw-value (myFromDefault MyNothing 99)) 99)
  (check-equal? (raw-value (myFromDefault (MyJust 7) 99)) 7)
  )

  (test-case "statusCode"
  (check-equal? (raw-value (statusCode (Success "ok"))) 200)
  (check-equal? (raw-value (statusCode NotFound)) 404)
  (check-equal? (raw-value (statusCode Unauthorized)) 401)
  (check-equal? (raw-value (statusCode (ServerError "oops"))) 500)
  )

)
