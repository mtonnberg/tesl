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
  (prefix-in __tmoney_ (only-in tesl/tesl/money tesl-currency-of tesl-money-rate-div tesl-money-rate-mul tesl-money-rate-scale))
  (only-in tesl/tesl/prelude Int String Bool)
  (only-in tesl/tesl/money [MoneyRate.perHour tesl_import_MoneyRate_perHour] [MoneyRate.perKilogram tesl_import_MoneyRate_perKilogram] [MoneyRate.display tesl_import_MoneyRate_display] [MoneyRate.currency tesl_import_MoneyRate_currency] [Money.usd tesl_import_Money_usd] [Money.jpy tesl_import_Money_jpy] [Money.sek tesl_import_Money_sek] [Money.fromMinorUnits tesl_import_Money_fromMinorUnits] [Money.minorUnits tesl_import_Money_minorUnits] [Money.currency tesl_import_Money_currency] [Money.display tesl_import_Money_display] [Money.scale tesl_import_Money_scale] [Money.scaleBy tesl_import_Money_scaleBy] [Money.negate tesl_import_Money_negate] [Money.abs tesl_import_Money_abs] [Money.isZero tesl_import_Money_isZero] [Money.isNegative tesl_import_Money_isNegative] [Money.add tesl_import_Money_add] [Money.subtract tesl_import_Money_subtract] [Money.compare tesl_import_Money_compare] [Money.requireSameCurrency tesl_import_Money_requireSameCurrency] [Money.requireNonNegative tesl_import_Money_requireNonNegative] [Money.requireRateFor tesl_import_Money_requireRateFor] [Money.convert tesl_import_Money_convert] [Money.convertChecked tesl_import_Money_convertChecked] [Currency.code tesl_import_Currency_code] [Currency.minorDigits tesl_import_Currency_minorDigits] [ExchangeRate.make tesl_import_ExchangeRate_make])
  (only-in tesl/tesl/result Result Ok Err)
  (only-in tesl/tesl/time PosixMillis [Time.secondsToPosix tesl_import_Time_secondsToPosix])
  (only-in tesl/tesl/float Float)
  (only-in tesl/tesl/units [Duration.hours tesl_import_Duration_hours] [Duration.minutes tesl_import_Duration_minutes] [Mass.kilograms tesl_import_Mass_kilograms] [Units.requireNonZero tesl_import_Units_requireNonZero])
)


(provide )

(define/pow
  (total [a : Money] [b : Money])
  #:returns Money
  (thsl-src! "tests/money-tests.tesl" 68 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl-checked-0 (tesl_import_Money_requireSameCurrency a b)]) (let ([sb tesl-checked-0]) (raw-value (tesl_import_Money_add *a sb)))))))

(define/pow
  (difference [a : Money] [b : Money])
  #:returns Money
  (thsl-src! "tests/money-tests.tesl" 72 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl-checked-1 (tesl_import_Money_requireSameCurrency a b)]) (let ([sb tesl-checked-1]) (raw-value (tesl_import_Money_subtract *a sb)))))))

(define/pow
  (ordering [a : Money] [b : Money])
  #:returns Integer
  (thsl-src! "tests/money-tests.tesl" 76 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl-checked-2 (tesl_import_Money_requireSameCurrency a b)]) (let ([sb tesl-checked-2]) (raw-value (tesl_import_Money_compare *a sb)))))))

(define/pow
  (convertStrict [r : ExchangeRate] [m : Money])
  #:returns Money
  (thsl-src! "tests/money-tests.tesl" 81 (list (cons 'r *r) (cons 'm *m)) (lambda () (let/check ([tesl-checked-3 (tesl_import_Money_requireRateFor r m)]) (let ([mc tesl-checked-3]) (raw-value (tesl_import_Money_convertChecked *r mc)))))))

(define/pow
  (requireDeposit [m : Money])
  #:returns Money
  (thsl-src! "tests/money-tests.tesl" 85 (list (cons 'm *m)) (lambda () (let/check ([tesl-checked-4 (tesl_import_Money_requireNonNegative m)]) (let ([nn tesl-checked-4]) (raw-value nn))))))

(define/pow
  (convertedMinor [r : ExchangeRate] [m : Money])
  #:returns Integer
  (thsl-src-control! "tests/money-tests.tesl" 90 (list (cons 'r *r) (cons 'm *m)) (lambda () (let ([tesl-case-5 (raw-value (tesl_import_Money_convert *r *m))]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Ok)) (let ([converted (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "tests/money-tests.tesl" 91 (list (cons 'converted converted)) (lambda () (raw-value (raw-value (tesl_import_Money_minorUnits *converted))))))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Err)) (thsl-src! "tests/money-tests.tesl" 92 (list) (lambda () (raw-value (- 0 1))))])))))

(define/pow
  (convertError [r : ExchangeRate] [m : Money])
  #:returns String
  (thsl-src-control! "tests/money-tests.tesl" 95 (list (cons 'r *r) (cons 'm *m)) (lambda () (let ([tesl-case-6 (raw-value (tesl_import_Money_convert *r *m))]) (cond [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Ok)) (thsl-src! "tests/money-tests.tesl" 96 (list) (lambda () (raw-value "no error")))] [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Err)) (let ([msg (hash-ref (adt-value-fields *tesl-case-6) 'error)]) (thsl-src! "tests/money-tests.tesl" 97 (list (cons 'msg msg)) (lambda () *msg)))])))))

(define/pow
  (usdToEur [rate : Real])
  #:returns ExchangeRate
  (thsl-src! "tests/money-tests.tesl" 100 (list (cons 'rate *rate)) (lambda () (raw-value (tesl_import_ExchangeRate_make (__tmoney_tesl-currency-of "USD") (__tmoney_tesl-currency-of "EUR") *rate (raw-value (tesl_import_Time_secondsToPosix 0)))))))

(define/pow
  (hourlyInvoice [rate : MoneyRate] [worked : Real])
  #:returns Money
  (thsl-src! "tests/money-tests.tesl" 220 (list (cons 'rate *rate) (cons 'worked *worked)) (lambda () (__tmoney_tesl-money-rate-mul *rate *worked))))

(define/pow
  (effectiveRate [billed : Money] [worked : Real])
  #:returns MoneyRate
  (let ([safe (thsl-src! "tests/money-tests.tesl" 223 (list (cons 'billed *billed) (cons 'worked *worked)) (lambda () (raw-value (tesl_import_Units_requireNonZero *worked))))]) (thsl-src! "tests/money-tests.tesl" 224 (list (cons 'safe *safe) (cons 'billed *billed) (cons 'worked *worked)) (lambda () (__tmoney_tesl-money-rate-div *billed (raw-value safe) "s")))))

(module+ test
  (require rackunit)
  (test-case "display renders symbol-first currencies with minor digits"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 105 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_usd 1050))))))) "$10.50")
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 106 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_usd 1000))))))) "$10.00")
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 107 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_usd 5))))))) "$0.05")
    ))
  )

  (test-case "display renders zero-minor-digit currencies without a decimal point"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 111 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_jpy 1000))))))) "\u00a51000")
    ))
  )

  (test-case "display renders non-symbol currencies as amount-then-code"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 115 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_sek 1050))))))) "10.50 SEK")
    ))
  )

  (test-case "display renders negative amounts with a leading sign"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 119 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_negate (raw-value (tesl_import_Money_usd 1050))))))))) "-$10.50")
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 120 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_negate (raw-value (tesl_import_Money_sek 1050))))))))) "-10.50 SEK")
    ))
  )

  (test-case "minorUnits round-trips the constructor amount"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 126 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_usd 1050))))))) 1050)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 127 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_jpy 0))))))) 0)
    ))
  )

  (test-case "fromMinorUnits builds the same value as the per-currency constructor"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 131 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_fromMinorUnits (__tmoney_tesl-currency-of "EUR") 916))))))) 916)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 132 (list) (lambda () (raw-value (tesl_import_Currency_code (raw-value (tesl_import_Money_currency (raw-value (tesl_import_Money_fromMinorUnits (__tmoney_tesl-currency-of "EUR") 916))))))))) "EUR")
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 133 (list) (lambda () (raw-value (tesl_import_Currency_code (raw-value (tesl_import_Money_currency (raw-value (tesl_import_Money_usd 1))))))))) "USD")
    ))
  )

  (test-case "currency metadata: code and minor digits"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 137 (list) (lambda () (raw-value (tesl_import_Currency_code (raw-value (tesl_import_Money_currency (raw-value (tesl_import_Money_sek 100))))))))) "SEK")
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 138 (list) (lambda () (raw-value (tesl_import_Currency_minorDigits (raw-value (tesl_import_Money_currency (raw-value (tesl_import_Money_usd 100))))))))) 2)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 139 (list) (lambda () (raw-value (tesl_import_Currency_minorDigits (raw-value (tesl_import_Money_currency (raw-value (tesl_import_Money_jpy 100))))))))) 0)
    ))
  )

  (test-case "scale multiplies minor units by an exact integer"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 145 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_scale (raw-value (tesl_import_Money_usd 250)) 3))))))) 750)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 146 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_scale (raw-value (tesl_import_Money_usd 250)) 0))))))) 0)
    ))
  )

  (test-case "negate and abs flip and strip the sign"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 150 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_negate (raw-value (tesl_import_Money_usd 100))))))))) (- 0 100))
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 151 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_abs (raw-value (tesl_import_Money_negate (raw-value (tesl_import_Money_usd 100))))))))))) 100)
    ))
  )

  (test-case "isZero and isNegative observe the amount"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 155 (list) (lambda () (raw-value (tesl_import_Money_isZero (raw-value (tesl_import_Money_usd 0))))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 156 (list) (lambda () (raw-value (tesl_import_Money_isZero (raw-value (tesl_import_Money_usd 1))))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 157 (list) (lambda () (raw-value (tesl_import_Money_isNegative (raw-value (tesl_import_Money_negate (raw-value (tesl_import_Money_usd 1))))))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 158 (list) (lambda () (raw-value (tesl_import_Money_isNegative (raw-value (tesl_import_Money_usd 1))))))) #f)
    ))
  )

  (test-case "requireSameCurrency then add sums minor units"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 164 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (total (raw-value (tesl_import_Money_usd 1050)) (raw-value (tesl_import_Money_usd 250))))))))) 1300)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 165 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (total (raw-value (tesl_import_Money_usd 1050)) (raw-value (tesl_import_Money_usd 250))))))))) "$13.00")
    ))
  )

  (test-case "requireSameCurrency then subtract"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 169 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (difference (raw-value (tesl_import_Money_sek 500)) (raw-value (tesl_import_Money_sek 150))))))))) 350)
    ))
  )

  (test-case "requireSameCurrency then compare returns -1/0/1"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 173 (list) (lambda () (ordering (raw-value (tesl_import_Money_usd 100)) (raw-value (tesl_import_Money_usd 200)))))) (- 0 1))
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 174 (list) (lambda () (ordering (raw-value (tesl_import_Money_usd 200)) (raw-value (tesl_import_Money_usd 100)))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 175 (list) (lambda () (ordering (raw-value (tesl_import_Money_usd 100)) (raw-value (tesl_import_Money_usd 100)))))) 0)
    ))
  )

  (test-case "requireNonNegative passes a non-negative amount through"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 179 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (requireDeposit (raw-value (tesl_import_Money_usd 0))))))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 180 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (requireDeposit (raw-value (tesl_import_Money_usd 750))))))))) 750)
    ))
  )

  (test-case "convert applies the rate exactly: 1000 USD-cents at 0.9155 is 916 EUR-cents"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 187 (list) (lambda () (convertedMinor (usdToEur 0.9155) (raw-value (tesl_import_Money_usd 1000)))))) 916)
    ))
  )

  (test-case "convert uses banker's rounding: half-cents round to the EVEN neighbor"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 192 (list) (lambda () (convertedMinor (usdToEur 0.5) (raw-value (tesl_import_Money_usd 915)))))) 458)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 194 (list) (lambda () (convertedMinor (usdToEur 0.5) (raw-value (tesl_import_Money_usd 925)))))) 462)
    ))
  )

  (test-case "convert with a mismatched amount currency is an Err"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 198 (list) (lambda () (convertError (usdToEur 0.5) (raw-value (tesl_import_Money_sek 100)))))) "exchange rate is FROM USD but amount is in SEK")
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 199 (list) (lambda () (convertedMinor (usdToEur 0.5) (raw-value (tesl_import_Money_sek 100)))))) (- 0 1))
    ))
  )

  (test-case "requireRateFor then convertChecked converts directly"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 203 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (convertStrict (usdToEur 0.9155) (raw-value (tesl_import_Money_usd 1000))))))))) 916)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 204 (list) (lambda () (raw-value (tesl_import_Currency_code (raw-value (tesl_import_Money_currency (raw-value (convertStrict (usdToEur 0.5) (raw-value (tesl_import_Money_usd 200))))))))))) "EUR")
    ))
  )

  (test-case "Money.scaleBy applies fractional factors with half-even rounding"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 209 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_scaleBy (raw-value (tesl_import_Money_usd 10000)) 1.055))))))) "$105.50")
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 211 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_scaleBy (raw-value (tesl_import_Money_usd 125)) 0.5))))))) 62)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 212 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_scaleBy (raw-value (tesl_import_Money_usd 135)) 0.5))))))) 68)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 214 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_scaleBy (raw-value (tesl_import_Money_usd 3)) 0.1))))))) 0)
    ))
  )

  (test-case "consultant: 950 SEK/h for 1.5 h bills 1425 SEK"
    (call-with-fresh-memory-db '() (lambda ()
  (define hourly (thsl-src! "tests/money-tests.tesl" 227 (list) (lambda () (raw-value (tesl_import_MoneyRate_perHour (raw-value (tesl_import_Money_sek 95000)))))))
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 228 (list (cons 'hourly hourly)) (lambda () (raw-value (tesl_import_MoneyRate_display (raw-value hourly)))))) "950.00 SEK/h")
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 229 (list (cons 'hourly hourly)) (lambda () (raw-value (tesl_import_Money_display (raw-value (hourlyInvoice hourly (raw-value (tesl_import_Duration_hours 1.5))))))))) "1425.00 SEK")
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 230 (list (cons 'hourly hourly)) (lambda () (raw-value (tesl_import_Money_display (raw-value (hourlyInvoice hourly (raw-value (tesl_import_Duration_minutes 30.))))))))) "475.00 SEK")
    ))
  )

  (test-case "a rate built by division round-trips through multiplication"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "tests/money-tests.tesl" 234 (list) (lambda () (effectiveRate (raw-value (tesl_import_Money_sek 142500)) (raw-value (tesl_import_Duration_hours 1.5))))))
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 235 (list (cons 'r r)) (lambda () (raw-value (tesl_import_Money_minorUnits (__tmoney_tesl-money-rate-mul (raw-value r) (raw-value (tesl_import_Duration_hours 1.)))))))) 95000)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 236 (list (cons 'r r)) (lambda () (raw-value (tesl_import_Currency_code (raw-value (tesl_import_MoneyRate_currency (raw-value r)))))))) "SEK")
    ))
  )

  (test-case "bulk goods per kilogram, exact Float rescale"
    (call-with-fresh-memory-db '() (lambda ()
  (define perKg (thsl-src! "tests/money-tests.tesl" 240 (list) (lambda () (raw-value (tesl_import_MoneyRate_perKilogram (raw-value (tesl_import_Money_usd 250)))))))
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 241 (list (cons 'perKg perKg)) (lambda () (raw-value (tesl_import_Money_display (__tmoney_tesl-money-rate-mul (raw-value perKg) (raw-value (tesl_import_Mass_kilograms 12.)))))))) "$30.00")
  (define surcharged (thsl-src! "tests/money-tests.tesl" 242 (list (cons 'perKg perKg)) (lambda () (__tmoney_tesl-money-rate-scale (raw-value perKg) 1.1))))
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 243 (list (cons 'surcharged surcharged) (cons 'perKg perKg)) (lambda () (raw-value (tesl_import_Money_display (__tmoney_tesl-money-rate-mul (raw-value surcharged) (raw-value (tesl_import_Mass_kilograms 12.)))))))) "$33.00")
    ))
  )

)
