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
  (only-in tesl/tesl/list [List.foldl tesl_import_List_foldl])
  (only-in tesl/tesl/float Float FloatNonZero [Float.requireNonZero tesl_import_Float_requireNonZero] [Float.add tesl_import_Float_add] [Float.sub tesl_import_Float_sub] [Float.mul tesl_import_Float_mul] [Float.div tesl_import_Float_div] [Float.abs tesl_import_Float_abs] [Float.min tesl_import_Float_min] [Float.max tesl_import_Float_max] [Float.clamp tesl_import_Float_clamp] [Float.sqrt tesl_import_Float_sqrt] [Float.pow tesl_import_Float_pow] [Float.ceil tesl_import_Float_ceil] [Float.floor tesl_import_Float_floor] [Float.round tesl_import_Float_round] [Float.toInt tesl_import_Float_toInt] [Float.toString tesl_import_Float_toString] [Float.parse tesl_import_Float_parse] [Float.isNaN tesl_import_Float_isNaN] [Float.isInfinite tesl_import_Float_isInfinite] [Float.isPositive tesl_import_Float_isPositive] [Float.isNegative tesl_import_Float_isNegative] [Float.isZero tesl_import_Float_isZero] [Float.sin tesl_import_Float_sin] [Float.cos tesl_import_Float_cos] [Float.infinity tesl_import_Float_infinity] [Float.nan tesl_import_Float_nan])
)


(provide circleArea hypotenuse clampUnit degreesToRadians safeAverage normalize roundToInt parsePrice isValidReading circleArea-signature hypotenuse-signature clampUnit-signature degreesToRadians-signature normalize-signature safeAverage-signature roundToInt-signature parsePrice-signature isValidReading-signature)

(define/pow
  (circleArea [radius : Real])
  #:returns Real
  (let ([pi (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 73 (list (cons 'radius *radius)) (lambda () 3.14159265358979))]) (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 74 (list (cons 'pi *pi) (cons 'radius *radius)) (lambda () (* (* (raw-value pi) *radius) *radius)))))

(define/pow
  (hypotenuse [a : Real] [b : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 78 (list (cons 'a *a) (cons 'b *b)) (lambda () (raw-value (tesl_import_Float_sqrt (+ (* *a *a) (* *b *b)))))))

(define/pow
  (clampUnit [x : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 82 (list (cons 'x *x)) (lambda () (raw-value (tesl_import_Float_clamp *x 0. 1.)))))

(define/pow
  (degreesToRadians [degrees : Real])
  #:returns Real
  (let ([pi (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 86 (list (cons 'degrees *degrees)) (lambda () 3.14159265358979))]) (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 87 (list (cons 'pi *pi) (cons 'degrees *degrees)) (lambda () (quotient (* *degrees (raw-value pi)) 180.)))))

(define/pow
  (sumFloats [xs : (List Real)])
  #:returns Real
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 94 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_foldl tesl_import_Float_add 0. *xs)))))

(define/pow
  (normalize [value : Real] [lo : Real] [hi : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 98 (list (cons 'value *value) (cons 'lo *lo) (cons 'hi *hi)) (lambda () (let ([range (raw-value (tesl_import_Float_sub *hi *lo))]) (let/check ([tesl-checked-0 (tesl_import_Float_requireNonZero range)]) (let ([safeRange tesl-checked-0]) (raw-value (tesl_import_Float_div (raw-value (tesl_import_Float_sub *value *lo)) safeRange))))))))

(define/pow
  (safeAverage [a : Real] [b : Real] [count : Real])
  #:returns (Maybe Real)
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 112 (list (cons 'a *a) (cons 'b *b) (cons 'count *count)) (lambda () (if (raw-value (tesl_import_Float_isZero *count)) (raw-value Nothing) (let/check ([tesl-checked-1 (tesl_import_Float_requireNonZero count)]) (let ([checkedCount tesl-checked-1]) (raw-value (raw-value (Something (raw-value (tesl_import_Float_div (+ *a *b) checkedCount)))))))))))

(define/pow
  (roundToInt [x : Real])
  #:returns Integer
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 122 (list (cons 'x *x)) (lambda () (raw-value (tesl_import_Float_round *x)))))

(define/pow
  (parsePrice [s : String])
  #:returns (Maybe Real)
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 126 (list (cons 's *s)) (lambda () (raw-value (tesl_import_Float_parse *s)))))

(define/pow
  (isValidReading [x : Real])
  #:returns Boolean
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 133 (list (cons 'x *x)) (lambda () (and (equal? (raw-value (tesl_import_Float_isNaN *x)) #f) (equal? (raw-value (tesl_import_Float_isInfinite *x)) #f)))))

(module+ test
  (require rackunit)
  (test-case "circleArea"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 139 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (circleArea 1.))))))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 141 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (circleArea 2.))))))) 13)
  )

  (test-case "hypotenuse - classic 3-4-5 triangle"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 145 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (hypotenuse 3. 4.))))))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 146 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (hypotenuse 5. 12.))))))) 13)
  )

  (test-case "clampUnit"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 150 (list) (lambda () (clampUnit 0.5)))) 0.5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 151 (list) (lambda () (raw-value (tesl_import_Float_round (* (raw-value (clampUnit 1.5)) 10.)))))) 10)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 152 (list) (lambda () (clampUnit 0.)))) 0.)
  )

  (test-case "sumFloats using Float.add as higher-order function"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 156 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (sumFloats (list 1.5 2.5 3.)))))))) 7)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 157 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (sumFloats (list)))))))) 0)
  )

  (test-case "safeAverage"
  (check-not-equal? (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 161 (list) (lambda () (safeAverage 2. 4. 2.))) Nothing)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 162 (list) (lambda () (safeAverage 2. 4. 0.)))) Nothing)
  )

  (test-case "Float.sqrt"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 166 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_sqrt 4.))))))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 167 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_sqrt 9.))))))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 168 (list) (lambda () (raw-value (tesl_import_Float_round (* (raw-value (tesl_import_Float_sqrt 2.)) 100.)))))) 141)
  )

  (test-case "Float.pow"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 172 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_pow 2. 10.))))))) 1024)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 173 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_pow 3. 3.))))))) 27)
  )

  (test-case "rounding"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 177 (list) (lambda () (raw-value (tesl_import_Float_floor 2.9))))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 178 (list) (lambda () (raw-value (tesl_import_Float_ceil 2.1))))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 179 (list) (lambda () (raw-value (tesl_import_Float_toInt 3.9))))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 180 (list) (lambda () (raw-value (tesl_import_Float_toInt (- 3.9)))))) -3)
  )

  (test-case "Float.parse"
  (check-not-equal? (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 184 (list) (lambda () (raw-value (tesl_import_Float_parse "3.14")))) Nothing)
  (check-not-equal? (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 185 (list) (lambda () (raw-value (tesl_import_Float_parse "-1.5")))) Nothing)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 186 (list) (lambda () (raw-value (tesl_import_Float_parse "not-a-number"))))) Nothing)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 187 (list) (lambda () (raw-value (tesl_import_Float_parse ""))))) Nothing)
  )

  (test-case "isValidReading"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 191 (list) (lambda () (isValidReading 1.5)))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 192 (list) (lambda () (isValidReading tesl_import_Float_nan)))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 193 (list) (lambda () (isValidReading tesl_import_Float_infinity)))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 194 (list) (lambda () (isValidReading (- 1.))))) #t)
  )

  (test-case "Float.isPositive / isNegative / isZero"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 198 (list) (lambda () (raw-value (tesl_import_Float_isPositive 3.14))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 199 (list) (lambda () (raw-value (tesl_import_Float_isNegative (- 1.)))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 200 (list) (lambda () (raw-value (tesl_import_Float_isZero 0.))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 201 (list) (lambda () (raw-value (tesl_import_Float_isZero 0.001))))) #f)
  )

  (test-case "Float.abs / min / max"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 205 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_abs (- 2.5)))))))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 206 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_abs (- 3.5)))))))) 4)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 207 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_min 1. 2.))))))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 208 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_max 1. 2.))))))) 2)
  )

)
