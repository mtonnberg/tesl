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
  (prefix-in __tmoney_ (only-in tesl/tesl/money tesl-currency-of))
  (only-in tesl/tesl/prelude Int String Bool)
  (only-in tesl/tesl/money [Money.usd tesl_import_Money_usd] [Money.jpy tesl_import_Money_jpy] [Money.sek tesl_import_Money_sek] [Money.fromMinorUnits tesl_import_Money_fromMinorUnits] [Money.minorUnits tesl_import_Money_minorUnits] [Money.currency tesl_import_Money_currency] [Money.display tesl_import_Money_display] [Money.scale tesl_import_Money_scale] [Money.scaleBy tesl_import_Money_scaleBy] [Money.negate tesl_import_Money_negate] [Money.abs tesl_import_Money_abs] [Money.isZero tesl_import_Money_isZero] [Money.isNegative tesl_import_Money_isNegative] [Money.add tesl_import_Money_add] [Money.subtract tesl_import_Money_subtract] [Money.compare tesl_import_Money_compare] [Money.requireSameCurrency tesl_import_Money_requireSameCurrency] [Money.requireNonNegative tesl_import_Money_requireNonNegative] [Money.requireRateFor tesl_import_Money_requireRateFor] [Money.convert tesl_import_Money_convert] [Money.convertChecked tesl_import_Money_convertChecked] [Currency.code tesl_import_Currency_code] [Currency.minorDigits tesl_import_Currency_minorDigits] [ExchangeRate.make tesl_import_ExchangeRate_make])
  (only-in tesl/tesl/result Result Ok Err)
  (only-in tesl/tesl/time PosixMillis [Time.secondsToPosix tesl_import_Time_secondsToPosix])
  (only-in tesl/tesl/float Float)
)


(provide )

(define/pow
  (total [a : Money] [b : Money])
  #:returns Money
  (thsl-src! "tests/money-tests.tesl" 55 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl-checked-0 (tesl_import_Money_requireSameCurrency a b)]) (let ([sb tesl-checked-0]) (raw-value (tesl_import_Money_add *a sb)))))))

(define/pow
  (difference [a : Money] [b : Money])
  #:returns Money
  (thsl-src! "tests/money-tests.tesl" 59 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl-checked-1 (tesl_import_Money_requireSameCurrency a b)]) (let ([sb tesl-checked-1]) (raw-value (tesl_import_Money_subtract *a sb)))))))

(define/pow
  (ordering [a : Money] [b : Money])
  #:returns Integer
  (thsl-src! "tests/money-tests.tesl" 63 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl-checked-2 (tesl_import_Money_requireSameCurrency a b)]) (let ([sb tesl-checked-2]) (raw-value (tesl_import_Money_compare *a sb)))))))

(define/pow
  (convertStrict [r : ExchangeRate] [m : Money])
  #:returns Money
  (thsl-src! "tests/money-tests.tesl" 68 (list (cons 'r *r) (cons 'm *m)) (lambda () (let/check ([tesl-checked-3 (tesl_import_Money_requireRateFor r m)]) (let ([mc tesl-checked-3]) (raw-value (tesl_import_Money_convertChecked *r mc)))))))

(define/pow
  (requireDeposit [m : Money])
  #:returns Money
  (thsl-src! "tests/money-tests.tesl" 72 (list (cons 'm *m)) (lambda () (let/check ([tesl-checked-4 (tesl_import_Money_requireNonNegative m)]) (let ([nn tesl-checked-4]) (raw-value nn))))))

(define/pow
  (convertedMinor [r : ExchangeRate] [m : Money])
  #:returns Integer
  (thsl-src-control! "tests/money-tests.tesl" 77 (list (cons 'r *r) (cons 'm *m)) (lambda () (let ([tesl-case-5 (raw-value (tesl_import_Money_convert *r *m))]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Ok)) (let ([converted (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "tests/money-tests.tesl" 78 (list (cons 'converted converted)) (lambda () (raw-value (raw-value (tesl_import_Money_minorUnits *converted))))))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Err)) (thsl-src! "tests/money-tests.tesl" 79 (list) (lambda () (raw-value (- 0 1))))])))))

(define/pow
  (convertError [r : ExchangeRate] [m : Money])
  #:returns String
  (thsl-src-control! "tests/money-tests.tesl" 82 (list (cons 'r *r) (cons 'm *m)) (lambda () (let ([tesl-case-6 (raw-value (tesl_import_Money_convert *r *m))]) (cond [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Ok)) (thsl-src! "tests/money-tests.tesl" 83 (list) (lambda () (raw-value "no error")))] [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Err)) (let ([msg (hash-ref (adt-value-fields *tesl-case-6) 'error)]) (thsl-src! "tests/money-tests.tesl" 84 (list (cons 'msg msg)) (lambda () *msg)))])))))

(define/pow
  (usdToEur [rate : Real])
  #:returns ExchangeRate
  (thsl-src! "tests/money-tests.tesl" 87 (list (cons 'rate *rate)) (lambda () (raw-value (tesl_import_ExchangeRate_make (__tmoney_tesl-currency-of "USD") (__tmoney_tesl-currency-of "EUR") *rate (raw-value (tesl_import_Time_secondsToPosix 0)))))))

(module+ test
  (require rackunit)
  (test-case "display renders symbol-first currencies with minor digits"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 92 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_usd 1050))))))) "$10.50")
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 93 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_usd 1000))))))) "$10.00")
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 94 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_usd 5))))))) "$0.05")
    ))
  )

  (test-case "display renders zero-minor-digit currencies without a decimal point"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 98 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_jpy 1000))))))) "\u00a51000")
    ))
  )

  (test-case "display renders non-symbol currencies as amount-then-code"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 102 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_sek 1050))))))) "10.50 SEK")
    ))
  )

  (test-case "display renders negative amounts with a leading sign"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 106 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_negate (raw-value (tesl_import_Money_usd 1050))))))))) "-$10.50")
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 107 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_negate (raw-value (tesl_import_Money_sek 1050))))))))) "-10.50 SEK")
    ))
  )

  (test-case "minorUnits round-trips the constructor amount"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 113 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_usd 1050))))))) 1050)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 114 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_jpy 0))))))) 0)
    ))
  )

  (test-case "fromMinorUnits builds the same value as the per-currency constructor"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 118 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_fromMinorUnits (__tmoney_tesl-currency-of "EUR") 916))))))) 916)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 119 (list) (lambda () (raw-value (tesl_import_Currency_code (raw-value (tesl_import_Money_currency (raw-value (tesl_import_Money_fromMinorUnits (__tmoney_tesl-currency-of "EUR") 916))))))))) "EUR")
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 120 (list) (lambda () (raw-value (tesl_import_Currency_code (raw-value (tesl_import_Money_currency (raw-value (tesl_import_Money_usd 1))))))))) "USD")
    ))
  )

  (test-case "currency metadata: code and minor digits"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 124 (list) (lambda () (raw-value (tesl_import_Currency_code (raw-value (tesl_import_Money_currency (raw-value (tesl_import_Money_sek 100))))))))) "SEK")
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 125 (list) (lambda () (raw-value (tesl_import_Currency_minorDigits (raw-value (tesl_import_Money_currency (raw-value (tesl_import_Money_usd 100))))))))) 2)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 126 (list) (lambda () (raw-value (tesl_import_Currency_minorDigits (raw-value (tesl_import_Money_currency (raw-value (tesl_import_Money_jpy 100))))))))) 0)
    ))
  )

  (test-case "scale multiplies minor units by an exact integer"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 132 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_scale (raw-value (tesl_import_Money_usd 250)) 3))))))) 750)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 133 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_scale (raw-value (tesl_import_Money_usd 250)) 0))))))) 0)
    ))
  )

  (test-case "negate and abs flip and strip the sign"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 137 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_negate (raw-value (tesl_import_Money_usd 100))))))))) (- 0 100))
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 138 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_abs (raw-value (tesl_import_Money_negate (raw-value (tesl_import_Money_usd 100))))))))))) 100)
    ))
  )

  (test-case "isZero and isNegative observe the amount"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 142 (list) (lambda () (raw-value (tesl_import_Money_isZero (raw-value (tesl_import_Money_usd 0))))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 143 (list) (lambda () (raw-value (tesl_import_Money_isZero (raw-value (tesl_import_Money_usd 1))))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 144 (list) (lambda () (raw-value (tesl_import_Money_isNegative (raw-value (tesl_import_Money_negate (raw-value (tesl_import_Money_usd 1))))))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 145 (list) (lambda () (raw-value (tesl_import_Money_isNegative (raw-value (tesl_import_Money_usd 1))))))) #f)
    ))
  )

  (test-case "requireSameCurrency then add sums minor units"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 151 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (total (raw-value (tesl_import_Money_usd 1050)) (raw-value (tesl_import_Money_usd 250))))))))) 1300)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 152 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (total (raw-value (tesl_import_Money_usd 1050)) (raw-value (tesl_import_Money_usd 250))))))))) "$13.00")
    ))
  )

  (test-case "requireSameCurrency then subtract"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 156 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (difference (raw-value (tesl_import_Money_sek 500)) (raw-value (tesl_import_Money_sek 150))))))))) 350)
    ))
  )

  (test-case "requireSameCurrency then compare returns -1/0/1"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 160 (list) (lambda () (ordering (raw-value (tesl_import_Money_usd 100)) (raw-value (tesl_import_Money_usd 200)))))) (- 0 1))
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 161 (list) (lambda () (ordering (raw-value (tesl_import_Money_usd 200)) (raw-value (tesl_import_Money_usd 100)))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 162 (list) (lambda () (ordering (raw-value (tesl_import_Money_usd 100)) (raw-value (tesl_import_Money_usd 100)))))) 0)
    ))
  )

  (test-case "requireNonNegative passes a non-negative amount through"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 166 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (requireDeposit (raw-value (tesl_import_Money_usd 0))))))))) 0)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 167 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (requireDeposit (raw-value (tesl_import_Money_usd 750))))))))) 750)
    ))
  )

  (test-case "convert applies the rate exactly: 1000 USD-cents at 0.9155 is 916 EUR-cents"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 174 (list) (lambda () (convertedMinor (usdToEur 0.9155) (raw-value (tesl_import_Money_usd 1000)))))) 916)
    ))
  )

  (test-case "convert uses banker's rounding: half-cents round to the EVEN neighbor"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 179 (list) (lambda () (convertedMinor (usdToEur 0.5) (raw-value (tesl_import_Money_usd 915)))))) 458)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 181 (list) (lambda () (convertedMinor (usdToEur 0.5) (raw-value (tesl_import_Money_usd 925)))))) 462)
    ))
  )

  (test-case "convert with a mismatched amount currency is an Err"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 185 (list) (lambda () (convertError (usdToEur 0.5) (raw-value (tesl_import_Money_sek 100)))))) "exchange rate is FROM USD but amount is in SEK")
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 186 (list) (lambda () (convertedMinor (usdToEur 0.5) (raw-value (tesl_import_Money_sek 100)))))) (- 0 1))
    ))
  )

  (test-case "requireRateFor then convertChecked converts directly"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 190 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (convertStrict (usdToEur 0.9155) (raw-value (tesl_import_Money_usd 1000))))))))) 916)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 191 (list) (lambda () (raw-value (tesl_import_Currency_code (raw-value (tesl_import_Money_currency (raw-value (convertStrict (usdToEur 0.5) (raw-value (tesl_import_Money_usd 200))))))))))) "EUR")
    ))
  )

  (test-case "Money.scaleBy applies fractional factors with half-even rounding"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 196 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_scaleBy (raw-value (tesl_import_Money_usd 10000)) 1.055))))))) "$105.50")
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 198 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_scaleBy (raw-value (tesl_import_Money_usd 125)) 0.5))))))) 62)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 199 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_scaleBy (raw-value (tesl_import_Money_usd 135)) 0.5))))))) 68)
  (check-equal? (raw-value (thsl-src! "tests/money-tests.tesl" 201 (list) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (tesl_import_Money_scaleBy (raw-value (tesl_import_Money_usd 3)) 0.1))))))) 0)
    ))
  )

)
