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
  (only-in tesl/tesl/prelude Bool Int String)
  (only-in tesl/tesl/result Result Ok Err)
  (only-in tesl/tesl/money [MoneyRate.perHour tesl_import_MoneyRate_perHour] [MoneyRate.display tesl_import_MoneyRate_display] [Money.usd tesl_import_Money_usd] [Money.sek tesl_import_Money_sek] [Money.fromMinorUnits tesl_import_Money_fromMinorUnits] [Money.minorUnits tesl_import_Money_minorUnits] [Money.display tesl_import_Money_display] [Money.scale tesl_import_Money_scale] [Money.add tesl_import_Money_add] [Money.requireSameCurrency tesl_import_Money_requireSameCurrency] [Money.requireRateFor tesl_import_Money_requireRateFor] [Money.convert tesl_import_Money_convert] [Money.convertChecked tesl_import_Money_convertChecked] [ExchangeRate.make tesl_import_ExchangeRate_make])
  (only-in tesl/tesl/time [Time.secondsToPosix tesl_import_Time_secondsToPosix])
  (only-in tesl/tesl/units [Duration.hours tesl_import_Duration_hours] [Duration.minutes tesl_import_Duration_minutes])
  (only-in tesl/tesl/db dbRead dbWrite)
)


(provide showPrice lineTotal addSameCurrency convertToDisplay convertChecked totalRevenue showPrice-signature lineTotal-signature addSameCurrency-signature convertToDisplay-signature convertChecked-signature totalRevenue-signature)

(define/pow
  (showPrice)
  #:returns String
  (let ([price (thsl-src! "example/learn/lesson71-money.tesl" 72 (list) (lambda () (raw-value (tesl_import_Money_usd 1050))))]) (thsl-src! "example/learn/lesson71-money.tesl" 73 (list (cons 'price *price)) (lambda () (raw-value (tesl_import_Money_display (raw-value price)))))))

(define/pow
  (lineTotal [unitPrice : Money] [quantity : Integer])
  #:returns Money
  (thsl-src! "example/learn/lesson71-money.tesl" 79 (list (cons 'unitPrice *unitPrice) (cons 'quantity *quantity)) (lambda () (raw-value (tesl_import_Money_scale *unitPrice *quantity)))))

(define/pow
  (addSameCurrency [a : Money] [b : Money])
  #:returns Money
  (thsl-src! "example/learn/lesson71-money.tesl" 86 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl-checked-0 (tesl_import_Money_requireSameCurrency a b)]) (let ([proven tesl-checked-0]) (raw-value (tesl_import_Money_add *a proven)))))))

(define/pow
  (convertToDisplay [rate : ExchangeRate] [amount : Money])
  #:returns String
  (thsl-src-control! "example/learn/lesson71-money.tesl" 94 (list (cons 'rate *rate) (cons 'amount *amount)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_Money_convert *rate *amount))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Ok)) (let ([converted (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/learn/lesson71-money.tesl" 95 (list (cons 'converted converted)) (lambda () (raw-value (raw-value (tesl_import_Money_display *converted))))))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Err)) (let ([message (hash-ref (adt-value-fields *tesl-case-1) 'error)]) (thsl-src! "example/learn/lesson71-money.tesl" 96 (list (cons 'message message)) (lambda () *message)))])))))

(define/pow
  (convertChecked [rate : ExchangeRate] [amount : Money])
  #:returns Money
  (thsl-src! "example/learn/lesson71-money.tesl" 102 (list (cons 'rate *rate) (cons 'amount *amount)) (lambda () (let/check ([tesl-checked-2 (tesl_import_Money_requireRateFor rate amount)]) (let ([proven tesl-checked-2]) (raw-value (tesl_import_Money_convertChecked *rate proven)))))))

(define-entity OrderLine
  #:source (make-hash)
  #:table order_lines
  #:primary-key id
  [Id id : String]
  [Price price : Money]
  [Quantity quantity : Integer]
)

(define-database Shop
  #:backend memory
  #:entities OrderLine)

(define/pow
  (totalRevenue)
  #:capabilities [dbRead]
  #:returns Money
  (thsl-src! "example/learn/lesson71-money.tesl" 122 (list) (lambda () (call-with-database Shop (lambda () (select-sum (entity-field-ref OrderLine 'price) (from OrderLine)))))))

(define/pow
  (consultantInvoice [hourly : MoneyRate] [worked : Real])
  #:returns Money
  (thsl-src! "example/learn/lesson71-money.tesl" 179 (list (cons 'hourly *hourly) (cons 'worked *worked)) (lambda () (__tmoney_tesl-money-rate-mul *hourly *worked))))

(module+ test
  (require rackunit)
  (test-case "money is integer minor units with a currency-aware display"
    (call-with-fresh-memory-db (list Shop) (lambda ()
  (define price (thsl-src! "example/learn/lesson71-money.tesl" 129 (list) (lambda () (raw-value (tesl_import_Money_usd 1050)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson71-money.tesl" 130 (list (cons 'price price)) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value price)))))) 1050)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson71-money.tesl" 131 (list (cons 'price price)) (lambda () (raw-value (tesl_import_Money_display (raw-value price)))))) "$10.50")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson71-money.tesl" 132 (list (cons 'price price)) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_fromMinorUnits (__tmoney_tesl-currency-of "JPY") 1000))))))) "\u00a51000")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson71-money.tesl" 133 (list (cons 'price price)) (lambda () (raw-value (tesl_import_Money_display (raw-value (tesl_import_Money_sek 1050))))))) "10.50 SEK")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson71-money.tesl" 134 (list (cons 'price price)) (lambda () (showPrice)))) "$10.50")
    ))
  )

  (test-case "scale multiplies by an exact integer"
    (call-with-fresh-memory-db (list Shop) (lambda ()
  (define unitPrice (thsl-src! "example/learn/lesson71-money.tesl" 138 (list) (lambda () (raw-value (tesl_import_Money_usd 199)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson71-money.tesl" 139 (list (cons 'unitPrice unitPrice)) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (lineTotal unitPrice 3))))))) 597)
    ))
  )

  (test-case "add works once the SameCurrency proof is minted"
    (call-with-fresh-memory-db (list Shop) (lambda ()
  (define a (thsl-src! "example/learn/lesson71-money.tesl" 143 (list) (lambda () (raw-value (tesl_import_Money_usd 1000)))))
  (define b (thsl-src! "example/learn/lesson71-money.tesl" 144 (list (cons 'a a)) (lambda () (raw-value (tesl_import_Money_usd 250)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson71-money.tesl" 145 (list (cons 'b b) (cons 'a a)) (lambda () (raw-value (tesl_import_Money_display (raw-value (addSameCurrency a b))))))) "$12.50")
    ))
  )

  (test-case "convert applies a runtime rate with banker's rounding"
    (call-with-fresh-memory-db (list Shop) (lambda ()
  (define rate (thsl-src! "example/learn/lesson71-money.tesl" 150 (list) (lambda () (raw-value (tesl_import_ExchangeRate_make (__tmoney_tesl-currency-of "USD") (__tmoney_tesl-currency-of "EUR") 0.9155 (raw-value (tesl_import_Time_secondsToPosix 1751900000)))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson71-money.tesl" 151 (list (cons 'rate rate)) (lambda () (convertToDisplay rate (raw-value (tesl_import_Money_usd 1000)))))) "\u20ac9.16")
    ))
  )

  (test-case "convert is an Err when the rate does not match the amount"
    (call-with-fresh-memory-db (list Shop) (lambda ()
  (define eurRate (thsl-src! "example/learn/lesson71-money.tesl" 155 (list) (lambda () (raw-value (tesl_import_ExchangeRate_make (__tmoney_tesl-currency-of "EUR") (__tmoney_tesl-currency-of "USD") 1.0922 (raw-value (tesl_import_Time_secondsToPosix 1751900000)))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson71-money.tesl" 156 (list (cons 'eurRate eurRate)) (lambda () (convertToDisplay eurRate (raw-value (tesl_import_Money_usd 1000)))))) "exchange rate is FROM EUR but amount is in USD")
    ))
  )

  (test-case "convertChecked is total behind a RateFor proof"
    (call-with-fresh-memory-db (list Shop) (lambda ()
  (define rate (thsl-src! "example/learn/lesson71-money.tesl" 160 (list) (lambda () (raw-value (tesl_import_ExchangeRate_make (__tmoney_tesl-currency-of "USD") (__tmoney_tesl-currency-of "EUR") 0.9155 (raw-value (tesl_import_Time_secondsToPosix 1751900000)))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson71-money.tesl" 161 (list (cons 'rate rate)) (lambda () (raw-value (tesl_import_Money_minorUnits (raw-value (convertChecked rate (raw-value (tesl_import_Money_usd 1000))))))))) 916)
    ))
  )

  (test-case "a Money column round-trips and selectSum sums one currency"
    (call-with-fresh-memory-db (list Shop) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-3 (thsl-src! "example/learn/lesson71-money.tesl" 166 (list) (lambda () (insert-one! OrderLine (hash 'id "l1" 'price (raw-value (tesl_import_Money_usd 1050)) 'quantity 1)))))
    (define tesl-ignored-4 (thsl-src! "example/learn/lesson71-money.tesl" 167 (list) (lambda () (insert-one! OrderLine (hash 'id "l2" 'price (raw-value (tesl_import_Money_usd 500)) 'quantity 2)))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson71-money.tesl" 169 (list) (lambda () (raw-value (tesl_import_Money_display (raw-value (totalRevenue))))))) "$15.50")
    )
    ))
  )

  (test-case "950 SEK/h for 1.5 h bills 1425 SEK"
    (call-with-fresh-memory-db (list Shop) (lambda ()
  (define hourly (thsl-src! "example/learn/lesson71-money.tesl" 182 (list) (lambda () (raw-value (tesl_import_MoneyRate_perHour (raw-value (tesl_import_Money_sek 95000)))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson71-money.tesl" 183 (list (cons 'hourly hourly)) (lambda () (raw-value (tesl_import_MoneyRate_display (raw-value hourly)))))) "950.00 SEK/h")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson71-money.tesl" 184 (list (cons 'hourly hourly)) (lambda () (raw-value (tesl_import_Money_display (raw-value (consultantInvoice hourly (raw-value (tesl_import_Duration_hours 1.5))))))))) "1425.00 SEK")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson71-money.tesl" 185 (list (cons 'hourly hourly)) (lambda () (raw-value (tesl_import_Money_display (raw-value (consultantInvoice hourly (raw-value (tesl_import_Duration_minutes 30.))))))))) "475.00 SEK")
    ))
  )

)
