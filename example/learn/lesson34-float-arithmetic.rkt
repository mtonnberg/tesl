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
  (only-in tesl/tesl/float Float FloatNonZero [Float.requireNonZero tesl_import_Float_requireNonZero] [Float.add tesl_import_Float_add] [Float.sub tesl_import_Float_sub] [Float.mul tesl_import_Float_mul] [Float.div tesl_import_Float_div] [Float.abs tesl_import_Float_abs] [Float.min tesl_import_Float_min] [Float.max tesl_import_Float_max] [Float.clamp tesl_import_Float_clamp] [Float.sqrt tesl_import_Float_sqrt] [Float.requireNonNegative tesl_import_Float_requireNonNegative] [Float.pow tesl_import_Float_pow] [Float.ceil tesl_import_Float_ceil] [Float.floor tesl_import_Float_floor] [Float.round tesl_import_Float_round] [Float.toInt tesl_import_Float_toInt] [Float.toString tesl_import_Float_toString] [Float.parse tesl_import_Float_parse] [Float.isNaN tesl_import_Float_isNaN] [Float.isInfinite tesl_import_Float_isInfinite] [Float.isPositive tesl_import_Float_isPositive] [Float.isNegative tesl_import_Float_isNegative] [Float.isZero tesl_import_Float_isZero] [Float.sin tesl_import_Float_sin] [Float.cos tesl_import_Float_cos] [Float.infinity tesl_import_Float_infinity] [Float.nan tesl_import_Float_nan])
)


(provide rootOf circleArea hypotenuse clampUnit degreesToRadians safeAverage normalize roundToInt parsePrice isValidReading circleArea-signature rootOf-signature hypotenuse-signature clampUnit-signature degreesToRadians-signature normalize-signature safeAverage-signature roundToInt-signature parsePrice-signature isValidReading-signature)

(define/pow
  (circleArea [radius : Real])
  #:returns Real
  (let ([pi (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 76 (list (cons 'radius *radius)) (lambda () 3.14159265358979))]) (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 77 (list (cons 'pi *pi) (cons 'radius *radius)) (lambda () (* (* (raw-value pi) *radius) *radius)))))

(define/pow
  (rootOf [x : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 86 (list (cons 'x *x)) (lambda () (let/check ([tesl-checked-0 (tesl_import_Float_requireNonNegative x)]) (let ([nonNegative tesl-checked-0]) (raw-value (tesl_import_Float_sqrt nonNegative)))))))

(define/pow
  (hypotenuse [a : Real] [b : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 90 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl-checked-1 (tesl_import_Float_requireNonNegative (+ (* *a *a) (* *b *b)))]) (let ([squares tesl-checked-1]) (raw-value (tesl_import_Float_sqrt squares)))))))

(define/pow
  (clampUnit [x : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 95 (list (cons 'x *x)) (lambda () (raw-value (tesl_import_Float_clamp *x 0. 1.)))))

(define/pow
  (degreesToRadians [degrees : Real])
  #:returns Real
  (let ([pi (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 99 (list (cons 'degrees *degrees)) (lambda () 3.14159265358979))]) (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 100 (list (cons 'pi *pi) (cons 'degrees *degrees)) (lambda () (/ (* *degrees (raw-value pi)) 180.)))))

(define/pow
  (sumFloats [xs : (List Real)])
  #:returns Real
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 107 (list (cons 'xs *xs)) (lambda () (raw-value (tesl_import_List_foldl tesl_import_Float_add 0. *xs)))))

(define/pow
  (normalize [value : Real] [lo : Real] [hi : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 111 (list (cons 'value *value) (cons 'lo *lo) (cons 'hi *hi)) (lambda () (let ([range (raw-value (tesl_import_Float_sub *hi *lo))]) (let/check ([tesl-checked-2 (tesl_import_Float_requireNonZero range)]) (let ([safeRange tesl-checked-2]) (raw-value (tesl_import_Float_div (raw-value (tesl_import_Float_sub *value *lo)) safeRange))))))))

(define/pow
  (safeAverage [a : Real] [b : Real] [count : Real])
  #:returns (Maybe Real)
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 125 (list (cons 'a *a) (cons 'b *b) (cons 'count *count)) (lambda () (if (raw-value (tesl_import_Float_isZero *count)) (raw-value Nothing) (let/check ([tesl-checked-3 (tesl_import_Float_requireNonZero count)]) (let ([checkedCount tesl-checked-3]) (raw-value (raw-value (Something (raw-value (tesl_import_Float_div (+ *a *b) checkedCount)))))))))))

(define/pow
  (roundToInt [x : Real])
  #:returns Integer
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 135 (list (cons 'x *x)) (lambda () (raw-value (tesl_import_Float_round *x)))))

(define/pow
  (parsePrice [s : String])
  #:returns (Maybe Real)
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 139 (list (cons 's *s)) (lambda () (raw-value (tesl_import_Float_parse *s)))))

(define/pow
  (isValidReading [x : Real])
  #:returns Boolean
  (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 146 (list (cons 'x *x)) (lambda () (and (tesl-equal? (raw-value (tesl_import_Float_isNaN *x)) #f) (tesl-equal? (raw-value (tesl_import_Float_isInfinite *x)) #f)))))

(module+ test
  (require rackunit)
  (test-case "circleArea"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 152 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (circleArea 1.))))))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 154 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (circleArea 2.))))))) 13)
    ))
  )

  (test-case "hypotenuse - classic 3-4-5 triangle"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 158 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (hypotenuse 3. 4.))))))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 159 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (hypotenuse 5. 12.))))))) 13)
    ))
  )

  (test-case "clampUnit"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 163 (list) (lambda () (clampUnit 0.5)))) 0.5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 164 (list) (lambda () (raw-value (tesl_import_Float_round (* (raw-value (clampUnit 1.5)) 10.)))))) 10)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 165 (list) (lambda () (clampUnit 0.)))) 0.)
    ))
  )

  (test-case "sumFloats using Float.add as higher-order function"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 169 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (sumFloats (list 1.5 2.5 3.)))))))) 7)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 170 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (sumFloats (list)))))))) 0)
    ))
  )

  (test-case "safeAverage"
    (call-with-fresh-memory-db '() (lambda ()
  (check-not-equal? (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 174 (list) (lambda () (safeAverage 2. 4. 2.))) Nothing)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 175 (list) (lambda () (safeAverage 2. 4. 0.)))) Nothing)
    ))
  )

  (test-case "Float.sqrt"
    (call-with-fresh-memory-db '() (lambda ()
  (define fourRaw (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 181 (list) (lambda () 4.)))
  (define tesl-checked-4 (tesl_import_Float_requireNonNegative fourRaw))
  (when (check-fail? tesl-checked-4)
    (raise-user-error 'tesl-test "unexpected failure in let four: ~a" (check-fail-message tesl-checked-4)))
  (define four tesl-checked-4)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 183 (list (cons 'four four) (cons 'fourRaw fourRaw)) (lambda () (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_sqrt four))))))) 2)
  (define nineRaw (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 184 (list (cons 'four four) (cons 'fourRaw fourRaw)) (lambda () 9.)))
  (define tesl-checked-5 (tesl_import_Float_requireNonNegative nineRaw))
  (when (check-fail? tesl-checked-5)
    (raise-user-error 'tesl-test "unexpected failure in let nine: ~a" (check-fail-message tesl-checked-5)))
  (define nine tesl-checked-5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 186 (list (cons 'nine nine) (cons 'nineRaw nineRaw) (cons 'four four) (cons 'fourRaw fourRaw)) (lambda () (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_sqrt nine))))))) 3)
  (define twoRaw (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 187 (list (cons 'nine nine) (cons 'nineRaw nineRaw) (cons 'four four) (cons 'fourRaw fourRaw)) (lambda () 2.)))
  (define tesl-checked-6 (tesl_import_Float_requireNonNegative twoRaw))
  (when (check-fail? tesl-checked-6)
    (raise-user-error 'tesl-test "unexpected failure in let two: ~a" (check-fail-message tesl-checked-6)))
  (define two tesl-checked-6)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 189 (list (cons 'two two) (cons 'twoRaw twoRaw) (cons 'nine nine) (cons 'nineRaw nineRaw) (cons 'four four) (cons 'fourRaw fourRaw)) (lambda () (raw-value (tesl_import_Float_round (* (raw-value (tesl_import_Float_sqrt two)) 100.)))))) 141)
  (define negative (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 191 (list (cons 'two two) (cons 'twoRaw twoRaw) (cons 'nine nine) (cons 'nineRaw nineRaw) (cons 'four four) (cons 'fourRaw fourRaw)) (lambda () (- 0. 1.))))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 192 (list (cons 'negative negative) (cons 'two two) (cons 'twoRaw twoRaw) (cons 'nine nine) (cons 'nineRaw nineRaw) (cons 'four four) (cons 'fourRaw fourRaw)) (lambda ()
                          (rootOf negative))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: rootOf negative"))
    ))
  )

  (test-case "Float.pow"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 196 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_pow 2. 10.))))))) 1024)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 197 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_pow 3. 3.))))))) 27)
    ))
  )

  (test-case "rounding"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 201 (list) (lambda () (raw-value (tesl_import_Float_floor 2.9))))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 202 (list) (lambda () (raw-value (tesl_import_Float_ceil 2.1))))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 203 (list) (lambda () (raw-value (tesl_import_Float_toInt 3.9))))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 204 (list) (lambda () (raw-value (tesl_import_Float_toInt (- 3.9)))))) -3)
    ))
  )

  (test-case "Float.parse"
    (call-with-fresh-memory-db '() (lambda ()
  (check-not-equal? (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 208 (list) (lambda () (raw-value (tesl_import_Float_parse "3.14")))) Nothing)
  (check-not-equal? (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 209 (list) (lambda () (raw-value (tesl_import_Float_parse "-1.5")))) Nothing)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 210 (list) (lambda () (raw-value (tesl_import_Float_parse "not-a-number"))))) Nothing)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 211 (list) (lambda () (raw-value (tesl_import_Float_parse ""))))) Nothing)
    ))
  )

  (test-case "isValidReading"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 215 (list) (lambda () (isValidReading 1.5)))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 216 (list) (lambda () (isValidReading tesl_import_Float_nan)))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 217 (list) (lambda () (isValidReading tesl_import_Float_infinity)))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 218 (list) (lambda () (isValidReading (- 1.))))) #t)
    ))
  )

  (test-case "Float.isPositive / isNegative / isZero"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 222 (list) (lambda () (raw-value (tesl_import_Float_isPositive 3.14))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 223 (list) (lambda () (raw-value (tesl_import_Float_isNegative (- 1.)))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 224 (list) (lambda () (raw-value (tesl_import_Float_isZero 0.))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 225 (list) (lambda () (raw-value (tesl_import_Float_isZero 0.001))))) #f)
    ))
  )

  (test-case "Float.abs / min / max"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 229 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_abs (- 2.5)))))))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 230 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_abs (- 3.5)))))))) 4)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 231 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_min 1. 2.))))))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson34-float-arithmetic.tesl" 232 (list) (lambda () (raw-value (tesl_import_Float_round (raw-value (tesl_import_Float_max 1. 2.))))))) 2)
    ))
  )

)
