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
  (only-in tesl/tesl/list [List.foldl tesl_import_List_foldl])
  (only-in tesl/tesl/float Float FloatNonZero [Float.requireNonZero tesl_import_Float_requireNonZero] [Float.add tesl_import_Float_add] [Float.sub tesl_import_Float_sub] [Float.mul tesl_import_Float_mul] [Float.div tesl_import_Float_div] [Float.abs tesl_import_Float_abs] [Float.min tesl_import_Float_min] [Float.max tesl_import_Float_max] [Float.clamp tesl_import_Float_clamp] [Float.sqrt tesl_import_Float_sqrt] [Float.pow tesl_import_Float_pow] [Float.ceil tesl_import_Float_ceil] [Float.floor tesl_import_Float_floor] [Float.round tesl_import_Float_round] [Float.toInt tesl_import_Float_toInt] [Float.toString tesl_import_Float_toString] [Float.parse tesl_import_Float_parse] [Float.isNaN tesl_import_Float_isNaN] [Float.isInfinite tesl_import_Float_isInfinite] [Float.isPositive tesl_import_Float_isPositive] [Float.isNegative tesl_import_Float_isNegative] [Float.isZero tesl_import_Float_isZero] [Float.sin tesl_import_Float_sin] [Float.cos tesl_import_Float_cos] [Float.infinity tesl_import_Float_infinity] [Float.nan tesl_import_Float_nan])
)


(provide circleArea hypotenuse clampUnit degreesToRadians safeAverage normalize roundToInt parsePrice isValidReading circleArea-signature hypotenuse-signature clampUnit-signature degreesToRadians-signature normalize-signature safeAverage-signature roundToInt-signature parsePrice-signature isValidReading-signature)

(define/pow
  (circleArea [radius : Real])
  #:returns Real
  (let ([pi 3.14159265359]) (* (* (raw-value pi) *radius) *radius)))

(define/pow
  (hypotenuse [a : Real] [b : Real])
  #:returns Real
  (raw-value (tesl_import_Float_sqrt (+ (* *a *a) (* *b *b)))))

(define/pow
  (clampUnit [x : Real])
  #:returns Real
  (raw-value (tesl_import_Float_clamp *x 0. 1.)))

(define/pow
  (degreesToRadians [degrees : Real])
  #:returns Real
  (let ([pi 3.14159265359]) (quotient (* *degrees (raw-value pi)) 180.)))

(define/pow
  (sumFloats [xs : (List Real)])
  #:returns Real
  (raw-value (tesl_import_List_foldl tesl_import_Float_add 0. *xs)))

(define/pow
  (normalize [value : Real] [lo : Real] [hi : Real])
  #:returns Real
  (let ([range (raw-value (tesl_import_Float_sub *hi *lo))]) (let/check ([tesl_checked_0 (tesl_import_Float_requireNonZero range)]) (let ([safeRange tesl_checked_0]) (raw-value (tesl_import_Float_div (raw-value (tesl_import_Float_sub *value *lo)) safeRange))))))

(define/pow
  (safeAverage [a : Real] [b : Real] [count : Real])
  #:returns (Maybe Real)
  (if (raw-value (tesl_import_Float_isZero *count)) (raw-value Nothing) (let/check ([tesl_checked_1 (tesl_import_Float_requireNonZero count)]) (let ([checkedCount tesl_checked_1]) (raw-value (raw-value (Something (raw-value (tesl_import_Float_div (+ *a *b) checkedCount)))))))))

(define/pow
  (roundToInt [x : Real])
  #:returns Integer
  (raw-value (tesl_import_Float_round *x)))

(define/pow
  (parsePrice [s : String])
  #:returns (Maybe Real)
  (raw-value (tesl_import_Float_parse *s)))

(define/pow
  (isValidReading [x : Real])
  #:returns Boolean
  (and (equal? (raw-value (tesl_import_Float_isNaN *x)) #f) (equal? (raw-value (tesl_import_Float_isInfinite *x)) #f)))

(module+ test
  (require rackunit)
  (test-case "circleArea"
  (check-equal? (raw-value (raw-value (tesl_import_Float_round (raw-value (circleArea 1.))))) 3)
  (check-equal? (raw-value (raw-value (tesl_import_Float_round (raw-value (circleArea 2.))))) 13)
  )

  (test-case "hypotenuse - classic 3-4-5 triangle"
  (check-equal? (raw-value (raw-value (tesl_import_Float_round (raw-value (hypotenuse 3. 4.))))) 5)
  (check-equal? (raw-value (raw-value (tesl_import_Float_round (raw-value (hypotenuse 5. 12.))))) 13)
  )

  (test-case "clampUnit"
  (check-equal? (raw-value (clampUnit 0.5)) 0.5)
  (check-equal? (raw-value (raw-value (tesl_import_Float_round (* (raw-value (clampUnit 1.5)) 10.)))) 10)
  (check-equal? (raw-value (clampUnit 0.)) 0.)
  )

  (test-case "sumFloats using Float.add as higher-order function"
  (check-equal? (raw-value (raw-value (tesl_import_Float_round (raw-value (sumFloats (list 1.5 2.5 3.)))))) 7)
  (check-equal? (raw-value (raw-value (tesl_import_Float_round (raw-value (sumFloats (list)))))) 0)
  )

  (test-case "safeAverage"
  (check-not-equal? (safeAverage 2. 4. 2.) Nothing)
  (check-equal? (raw-value (safeAverage 2. 4. 0.)) Nothing)
  )

  (test-case "Float.sqrt"
  (check-equal? (raw-value (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_sqrt 4.))))) 2)
  (check-equal? (raw-value (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_sqrt 9.))))) 3)
  (check-equal? (raw-value (raw-value (tesl_import_Float_round (* (raw-value (tesl_import_Float_sqrt 2.)) 100.)))) 141)
  )

  (test-case "Float.pow"
  (check-equal? (raw-value (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_pow 2. 10.))))) 1024)
  (check-equal? (raw-value (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_pow 3. 3.))))) 27)
  )

  (test-case "rounding"
  (check-equal? (raw-value (raw-value (tesl_import_Float_floor 2.9))) 2)
  (check-equal? (raw-value (raw-value (tesl_import_Float_ceil 2.1))) 3)
  (check-equal? (raw-value (raw-value (tesl_import_Float_toInt 3.9))) 3)
  (check-equal? (raw-value (raw-value (tesl_import_Float_toInt (- 3.9)))) -3)
  )

  (test-case "Float.parse"
  (check-not-equal? (raw-value (tesl_import_Float_parse "3.14")) Nothing)
  (check-not-equal? (raw-value (tesl_import_Float_parse "-1.5")) Nothing)
  (check-equal? (raw-value (raw-value (tesl_import_Float_parse "not-a-number"))) Nothing)
  (check-equal? (raw-value (raw-value (tesl_import_Float_parse ""))) Nothing)
  )

  (test-case "isValidReading"
  (check-equal? (raw-value (isValidReading 1.5)) #t)
  (check-equal? (raw-value (isValidReading tesl_import_Float_nan)) #f)
  (check-equal? (raw-value (isValidReading tesl_import_Float_infinity)) #f)
  (check-equal? (raw-value (isValidReading (- 1.))) #t)
  )

  (test-case "Float.isPositive / isNegative / isZero"
  (check-equal? (raw-value (raw-value (tesl_import_Float_isPositive 3.14))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_Float_isNegative (- 1.)))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_Float_isZero 0.))) #t)
  (check-equal? (raw-value (raw-value (tesl_import_Float_isZero 0.001))) #f)
  )

  (test-case "Float.abs / min / max"
  (check-equal? (raw-value (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_abs (- 2.5)))))) 2)
  (check-equal? (raw-value (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_abs (- 3.5)))))) 4)
  (check-equal? (raw-value (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_min 1. 2.))))) 1)
  (check-equal? (raw-value (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_max 1. 2.))))) 2)
  )

)
