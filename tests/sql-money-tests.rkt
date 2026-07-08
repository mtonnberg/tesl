#lang racket

;;; Two-column Money storage — Memory-backend behaviour + the sql.rkt seams
;;; that do not need a live PostgreSQL (DDL strings, decode, collisions).
;;;
;;; A `Money` field maps to `<col>_minor BIGINT NOT NULL` +
;;; `<col>_currency TEXT NOT NULL` on PostgreSQL; the Memory backend stores
;;; the tesl-money struct directly in the row.  Parity is BEHAVIOURAL — both
;;; backends share one decision table:
;;;   where ==      → matches on (minor, currency) both
;;;   where < <= > >= → runtime-rejected (currencies differ)
;;;   selectSum     → empty → error; mixed currencies → error; else Money
;;;   selectMax/Min → runtime-rejected
;;;   groupBy key   → runtime-rejected
;;; The PostgreSQL side of the same table lives in tests/sql-money-pg-test.rkt.

(require rackunit
         "../dsl/capability.rkt"
         "../dsl/check.rkt"
         "../dsl/sql.rkt"
         "../dsl/types.rkt"
         "../dsl/private/money-core.rkt"
         "../dsl/private/currency-data.rkt")

(define (usd n) (tesl-money n (tesl-currency-of "USD")))
(define (eur n) (tesl-money n (tesl-currency-of "EUR")))

(define current-product-rows (make-parameter (make-hash)))

(define-entity Product
  #:source (lambda () (current-product-rows))
  #:table products
  #:primary-key id
  [Id id : String]
  [Sku sku : String]
  [Price price : Money])

(define price-field (entity-field-ref Product 'price))
(define id-field (entity-field-ref Product 'id))
(define sku-field (entity-field-ref Product 'sku))

(define (reset-rows!)
  (current-product-rows (make-hash)))

(define (seed-widgets+gadget!)
  ;; p1/p2 share a currency (USD); p3 is EUR with the SAME minor units as p1,
  ;; so `==` must discriminate on the currency column, not just the amount.
  (insert-one! Product (hash 'id "p1" 'sku "widget" 'price (usd 1999)))
  (insert-one! Product (hash 'id "p2" 'sku "widget" 'price (usd 2500)))
  (insert-one! Product (hash 'id "p3" 'sku "gadget" 'price (eur 1999))))

(define (select-price id)
  (hash-ref (raw-value (select-one (from Product) (where (==. id-field id)))) 'price))

;; ── DDL strings (the PG column shapes, testable without a database) ─────────

(check-equal? (field-column-definitions-sql price-field)
              (list "\"price_minor\" BIGINT NOT NULL"
                    "\"price_currency\" TEXT NOT NULL")
              "a Money field expands to the two derived column definitions")

(check-equal? (field-column-definitions-sql sku-field)
              (list "\"sku\" TEXT NOT NULL")
              "a non-Money field still expands to exactly one definition")

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"TWO columns" (exn-message e))))
 (lambda () (column-definition-sql price-field))
 "the single-column DDL helper refuses a Money field")

;; ── Derived-column collision is rejected before any DDL ─────────────────────

(define-entity CollidingProduct
  #:source (make-hash)
  #:table colliding_products
  #:primary-key id
  [Id id : String]
  [Price price : Money]
  ;; camel->snake turns priceMinor into price_minor — exactly the derived
  ;; column the Money field claims.
  [PriceMinor priceMinor : Integer])

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"already declares a column named price_minor" (exn-message e))))
 (lambda () (check-money-column-collisions! CollidingProduct))
 "a field whose column collides with <money>_minor is rejected")

(check-not-exn
 (lambda () (check-money-column-collisions! Product))
 "no collision on a well-formed Money entity")

;; ── WHERE-clause construction guards (backend-independent) ──────────────────

(for ([make-pred (in-list (list <. <=. >. >=.))])
  (check-exn
   (lambda (e) (and (exn:fail:user? e)
                    (regexp-match? #rx"Money columns do not support ordered comparison in where clauses" (exn-message e))))
   (lambda () (make-pred price-field (usd 1)))
   "ordered comparison on a Money column is runtime-rejected"))

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"ORDER BY" (exn-message e))))
 (lambda () (order-by price-field 'asc))
 "ORDER BY a Money column is runtime-rejected")

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"Money cannot be a groupBy key" (exn-message e))))
 (lambda () (sql-group-key 'field 0 price-field))
 "a Money bucket key is runtime-rejected")

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"Money cannot be a groupBy key" (exn-message e))))
 (lambda () (group-by price-field))
 "a Money plain groupBy field is runtime-rejected")

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"not supported on Money columns" (exn-message e))))
 (lambda () (in?. price-field (list (usd 1))))
 "IN on a Money column is runtime-rejected")

;; ── PG predicate lowering: == / != expand over BOTH columns ─────────────────

(let-values ([(fragment params next-index)
              (compile-predicate-sql (==. price-field (usd 1999)) 1)])
  (check-equal? fragment "(\"price_minor\" = $1 AND \"price_currency\" = $2)"
                "== on Money lowers to a conjunction over both columns")
  (check-equal? params (list 1999 "USD"))
  (check-equal? next-index 3))

(let-values ([(fragment params next-index)
              (compile-predicate-sql (!=. price-field (eur 5)) 4)])
  (check-equal? fragment "(\"price_minor\" <> $4 OR \"price_currency\" <> $5)"
                "!= on Money lowers to a disjunction over both columns")
  (check-equal? params (list 5 "EUR"))
  (check-equal? next-index 6))

;; ── Decode (the SELECT read path, fail-closed on corrupt data) ──────────────

(check-equal? (money-db-values->runtime-value price-field 100 "SEK")
              (tesl-money 100 (tesl-currency-of "SEK"))
              "two stored columns decode into one Money")

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"not a known ISO 4217 currency" (exn-message e))))
 (lambda () (money-db-values->runtime-value price-field 100 "ZZZ"))
 "an unknown stored currency code raises loudly on decode")

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"not an integer" (exn-message e))))
 (lambda () (money-db-values->runtime-value price-field 10.5 "USD"))
 "a non-integer stored minor value raises loudly on decode")

;; ── Memory backend behaviour ─────────────────────────────────────────────────

(with-capabilities (db-read db-write)

  ;; insert + select roundtrip preserves minor units AND currency
  (reset-rows!)
  (seed-widgets+gadget!)
  (let ([money (select-price "p1")])
    (check-pred tesl-money? money "roundtrip yields a tesl-money struct")
    (check-equal? (tesl-money-minor-units money) 1999)
    (check-equal? (tesl-currency-code (tesl-money-currency money)) "USD"))

  ;; where == matches on BOTH minor units and currency (p3 is EUR 1999)
  (let ([rows (select-many (from Product) (where (==. price-field (usd 1999))))])
    (check-equal? (map (lambda (r) (hash-ref (raw-value r) 'id)) rows)
                  (list "p1")
                  "== matches the USD row only, not the EUR row with equal minor units"))

  ;; != is the complement (unwrap-non-null passes tesl-money through untouched)
  (check-equal? (length (select-many (from Product) (where (!=. price-field (usd 1999)))))
                2
                "!= excludes exactly the matching Money row")

  ;; sum over a single currency
  (check-equal? (select-sum price-field (from Product) (where (==. sku-field "widget")))
                (usd 4499)
                "single-currency sum adds minor units and keeps the currency")

  ;; sum across mixed currencies raises
  (check-exn
   (lambda (e) (and (exn:fail:user? e)
                    (regexp-match? #rx"cannot sum Money across mixed currencies \\(found 2\\)" (exn-message e))))
   (lambda () (select-sum price-field (from Product)))
   "mixed-currency sum is rejected with the distinct count")

  ;; sum over an empty row set raises (no currency for the zero total)
  (check-exn
   (lambda (e) (and (exn:fail:user? e)
                    (regexp-match? #rx"cannot sum Money over an empty row set" (exn-message e))))
   (lambda () (select-sum price-field (from Product) (where (==. sku-field "no-such-sku"))))
   "empty-set Money sum is rejected")

  ;; selectMax / selectMin are runtime-rejected
  (check-exn
   (lambda (e) (and (exn:fail:user? e)
                    (regexp-match? #rx"Money columns do not support selectMax" (exn-message e))))
   (lambda () (select-max price-field (from Product))))
  (check-exn
   (lambda (e) (and (exn:fail:user? e)
                    (regexp-match? #rx"Money columns do not support selectMin" (exn-message e))))
   (lambda () (select-min price-field (from Product))))

  ;; selectSumBy over a Money column is runtime-rejected
  (check-exn
   (lambda (e) (and (exn:fail:user? e)
                    (regexp-match? #rx"selectSumBy over a Money column is not supported" (exn-message e))))
   (lambda () (select-sum-by (sql-group-key 'field 0 sku-field)
                             price-field
                             (from Product))))

  ;; update ... set p.price = <money>
  (update-many! (from Product)
                (hash 'price (eur 4242))
                (where (==. id-field "p1")))
  (check-equal? (select-price "p1") (eur 4242)
                "update set replaces the whole Money value")

  ;; a non-Money value bound to a Money field is rejected with a clear error
  (check-exn
   (lambda (e) (and (exn:fail:user? e)
                    (regexp-match? #rx"needs a Money value" (exn-message e))))
   (lambda () (insert-one! Product (hash 'id "bad" 'sku "widget" 'price 100)))
   "a bare integer cannot be stored into a Money field")
  (check-exn
   (lambda (e) (and (exn:fail:user? e)
                    (regexp-match? #rx"needs a Money value" (exn-message e))))
   (lambda () (update-many! (from Product)
                            (hash 'price "19.99 USD")
                            (where (==. id-field "p2"))))
   "a string cannot be stored into a Money field")

  ;; and a Money operand on a NON-Money column is equally rejected
  (check-exn
   exn:fail:user?
   (lambda () (select-many (from Product) (where (==. sku-field (usd 1)))))
   "a Money value bound to a String field is rejected"))

;; Maybe Money is fail-closed until its two-column NULL semantics exist.
(define-entity MaybePriceRow
  #:source (make-hash)
  #:table maybe_price_rows
  #:primary-key id
  [Id id : String]
  [Price price : (Maybe Money)])

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"Maybe Money fields are not supported yet" (exn-message e))))
 (lambda () (field-column-definitions-sql (entity-field-ref MaybePriceRow 'price)))
 "Maybe Money is rejected at the DDL seam")

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"Maybe Money fields are not supported yet" (exn-message e))))
 (lambda ()
   (with-capabilities (db-write)
     (insert-one! MaybePriceRow (hash 'id "m1" 'price (usd 1)))))
 "Maybe Money is rejected at the write seam")

;; ═════════════════════════════════════════════════════════════════════════════
;; Three-column MoneyRate storage — Memory-backend behaviour + the sql.rkt
;; seams that do not need a live PostgreSQL.
;;
;; A rate field (declared as one of the five MoneyPer* aliases) maps to
;; `<col>_minor BIGINT NOT NULL` + `<col>_currency TEXT NOT NULL` +
;; `<col>_per TEXT NOT NULL`.  Persistence is a BOUNDARY: the stored value is
;; the QUANTIZED shape (integer minor units per one `per` unit, half-even),
;; and the Memory backend stores the quantized-then-RECONSTRUCTED struct so
;; Memory ≡ PostgreSQL roundtrips exactly.  Equality is REPRESENTATIONAL:
;; the same price stored per "h" does not match itself stored per "day".
;; The PostgreSQL side of the same table lives in tests/sql-money-pg-test.rkt.

;; A hand-built rate: minor-per-label / factor = the exact per-canonical
;; rational (e.g. MoneyRate.perHour 950.00 USD ⇒ 95000 minor / 3600 s).
(define (rate-of minor-per-label code label factor)
  (tesl-money-rate (/ minor-per-label factor) (tesl-currency-of code) factor label))
(define (usd/h m) (rate-of m "USD" "h" 3600))
(define (eur/h m) (rate-of m "EUR" "h" 3600))
(define (usd/day m) (rate-of m "USD" "day" 86400))

(define current-job-rows (make-parameter (make-hash)))

(define-entity Job
  #:source (lambda () (current-job-rows))
  #:table jobs
  #:primary-key id
  [Id id : String]
  [Team team : String]
  [Hourly hourly : MoneyPerDuration])

(define hourly-field (entity-field-ref Job 'hourly))
(define job-id-field (entity-field-ref Job 'id))
(define team-field (entity-field-ref Job 'team))

(define (reset-job-rows!)
  (current-job-rows (make-hash)))

(define (select-hourly id)
  (hash-ref (raw-value (select-one (from Job) (where (==. job-id-field id)))) 'hourly))

;; ── DDL strings (the PG column shapes, testable without a database) ─────────

(check-equal? (field-column-definitions-sql hourly-field)
              (list "\"hourly_minor\" BIGINT NOT NULL"
                    "\"hourly_currency\" TEXT NOT NULL"
                    "\"hourly_per\" TEXT NOT NULL")
              "a MoneyRate field expands to the three derived column definitions")

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"THREE columns" (exn-message e))))
 (lambda () (column-definition-sql hourly-field))
 "the single-column DDL helper refuses a MoneyRate field")

;; All five denominator aliases are detected BY NAME (spot-check a second one).
(define-entity Freight
  #:source (make-hash)
  #:table freights
  #:primary-key id
  [Id id : String]
  [PerKg perKg : MoneyPerMass])

(check-equal? (field-column-definitions-sql (entity-field-ref Freight 'perKg))
              (list "\"per_kg_minor\" BIGINT NOT NULL"
                    "\"per_kg_currency\" TEXT NOT NULL"
                    "\"per_kg_per\" TEXT NOT NULL")
              "MoneyPerMass expands to the same three-column shape")

;; ── Derived-column collision is rejected before any DDL ─────────────────────

(define-entity CollidingJob
  #:source (make-hash)
  #:table colliding_jobs
  #:primary-key id
  [Id id : String]
  [Hourly hourly : MoneyPerDuration]
  ;; camel->snake turns hourlyPer into hourly_per — exactly the derived
  ;; column the MoneyRate field claims.
  [HourlyPer hourlyPer : String])

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"already declares a column named hourly_per" (exn-message e))))
 (lambda () (check-money-column-collisions! CollidingJob))
 "a field whose column collides with <rate>_per is rejected")

(check-not-exn
 (lambda () (check-money-column-collisions! Job))
 "no collision on a well-formed MoneyRate entity")

;; ── WHERE-clause construction guards (backend-independent) ──────────────────

(for ([make-pred (in-list (list <. <=. >. >=.))])
  (check-exn
   (lambda (e) (and (exn:fail:user? e)
                    (regexp-match? #rx"MoneyRate columns do not support ordered comparison in where clauses" (exn-message e))))
   (lambda () (make-pred hourly-field (usd/h 1)))
   "ordered comparison on a MoneyRate column is runtime-rejected"))

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"MoneyRate columns do not support ORDER BY" (exn-message e))))
 (lambda () (order-by hourly-field 'asc))
 "ORDER BY a MoneyRate column is runtime-rejected")

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"MoneyRate cannot be a groupBy key" (exn-message e))))
 (lambda () (sql-group-key 'field 0 hourly-field))
 "a MoneyRate bucket key is runtime-rejected")

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"MoneyRate cannot be a groupBy key" (exn-message e))))
 (lambda () (group-by hourly-field))
 "a MoneyRate plain groupBy field is runtime-rejected")

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"not supported on MoneyRate columns" (exn-message e))))
 (lambda () (in?. hourly-field (list (usd/h 1))))
 "IN on a MoneyRate column is runtime-rejected")

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"not supported on MoneyRate columns" (exn-message e))))
 (lambda () (like?. hourly-field "95%"))
 "LIKE on a MoneyRate column is runtime-rejected")

;; ── PG predicate lowering: == / != expand over all THREE columns ────────────

(let-values ([(fragment params next-index)
              (compile-predicate-sql (==. hourly-field (usd/h 95000)) 1)])
  (check-equal? fragment
                "(\"hourly_minor\" = $1 AND \"hourly_currency\" = $2 AND \"hourly_per\" = $3)"
                "== on MoneyRate lowers to a conjunction over all three columns")
  (check-equal? params (list 95000 "USD" "h"))
  (check-equal? next-index 4))

(let-values ([(fragment params next-index)
              (compile-predicate-sql (!=. hourly-field (eur/h 5)) 4)])
  (check-equal? fragment
                "(\"hourly_minor\" <> $4 OR \"hourly_currency\" <> $5 OR \"hourly_per\" <> $6)"
                "!= on MoneyRate lowers to a disjunction over all three columns")
  (check-equal? params (list 5 "EUR" "h"))
  (check-equal? next-index 7))

;; ── Decode (the SELECT read path, fail-closed on corrupt data) ──────────────

(check-equal? (money-rate-db-values->runtime-value hourly-field 95000 "USD" "h")
              (usd/h 95000)
              "three stored columns decode into one MoneyRate (exact per-canonical)")

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"unknown ISO 4217 currency code" (exn-message e))))
 (lambda () (money-rate-db-values->runtime-value hourly-field 100 "ZZZ" "h"))
 "an unknown stored currency code raises loudly on decode")

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"unknown rate unit label" (exn-message e))))
 (lambda () (money-rate-db-values->runtime-value hourly-field 100 "USD" "zzz"))
 "an unknown stored unit label raises loudly on decode")

;; wrong-dim read fails closed: a per-"kg" label stored in a MoneyPerDuration
;; column is corrupt data, not a unit conversion.
(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"mass denominator.*expects a duration denominator" (exn-message e))))
 (lambda () (money-rate-db-values->runtime-value hourly-field 100 "USD" "kg"))
 "a label whose dimension contradicts the declared alias raises on decode")

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"not an integer" (exn-message e))))
 (lambda () (money-rate-db-values->runtime-value hourly-field 10.5 "USD" "h"))
 "a non-integer stored minor value raises loudly on decode")

;; ── Memory backend behaviour ─────────────────────────────────────────────────

(with-capabilities (db-read db-write)

  ;; insert + select roundtrip preserves the (minor, currency, per) triple
  ;; exactly; the division-built per-canonical (95000/3600, a non-integer
  ;; rational) quantizes on write to integer minor units per label unit.
  (reset-job-rows!)
  ;; j1/j2 share (minor, label) but differ in currency; j3 is the SAME price
  ;; as j1 (95000/h × 24) stored per "day" — equality must be REPRESENTATIONAL.
  (insert-one! Job (hash 'id "j1" 'team "core" 'hourly (usd/h 95000)))
  (insert-one! Job (hash 'id "j2" 'team "core" 'hourly (eur/h 95000)))
  (insert-one! Job (hash 'id "j3" 'team "ops" 'hourly (usd/day 2280000)))
  (let ([rate (select-hourly "j1")])
    (check-pred tesl-money-rate? rate "roundtrip yields a tesl-money-rate struct")
    (let-values ([(minor code label) (tesl-money-rate-quantize rate)])
      (check-equal? minor 95000 "minor units per label unit survive exactly")
      (check-equal? code "USD")
      (check-equal? label "h"))
    (check-equal? (tesl-money-rate-per-canonical rate) 475/18
                  "the reconstructed per-canonical is the exact rational minor/factor"))

  ;; non-integer per-label values quantize HALF-EVEN on write, and the store
  ;; holds the quantized-then-reconstructed struct (not the exact input).
  (insert-one! Job (hash 'id "j4" 'team "ops" 'hourly (rate-of 1001/2 "USD" "h" 3600)))
  (insert-one! Job (hash 'id "j5" 'team "ops" 'hourly (rate-of 1003/2 "USD" "h" 3600)))
  (check-equal? (select-hourly "j4")
                (money-rate-db-values->runtime-value hourly-field 500 "USD" "h")
                "500.5 minor/label rounds half-even DOWN to 500 at the write boundary")
  (check-equal? (select-hourly "j5")
                (money-rate-db-values->runtime-value hourly-field 502 "USD" "h")
                "501.5 minor/label rounds half-even UP to 502 at the write boundary")

  ;; where == matches on the full triple: not the EUR row with equal
  ;; (minor, label), and — REPRESENTATIONAL equality — not the per-"day" row
  ;; carrying the same price either.
  (let ([rows (select-many (from Job) (where (==. hourly-field (usd/h 95000))))])
    (check-equal? (map (lambda (r) (hash-ref (raw-value r) 'id)) rows)
                  (list "j1")
                  "== matches the same-triple row only"))

  ;; the == operand passes through the SAME write boundary (quantizes before
  ;; comparing): 95000.4 minor/label → 95000.
  (let ([rows (select-many (from Job) (where (==. hourly-field (rate-of 950004/10 "USD" "h" 3600))))])
    (check-equal? (map (lambda (r) (hash-ref (raw-value r) 'id)) rows)
                  (list "j1")
                  "the == operand is quantized before comparison"))

  ;; != is the complement over the full triple
  (check-equal? (sort (map (lambda (r) (hash-ref (raw-value r) 'id))
                           (select-many (from Job) (where (!=. hourly-field (usd/h 95000)))))
                      string<?)
                (list "j2" "j3" "j4" "j5")
                "!= excludes exactly the matching MoneyRate row")

  ;; selectSum / selectMax / selectMin / selectSumBy are runtime-rejected
  (check-exn
   (lambda (e) (and (exn:fail:user? e)
                    (regexp-match? #rx"selectSum over a MoneyRate column is not supported; aggregate the materialized Money instead" (exn-message e))))
   (lambda () (select-sum hourly-field (from Job))))
  (check-exn
   (lambda (e) (and (exn:fail:user? e)
                    (regexp-match? #rx"MoneyRate columns do not support selectMax" (exn-message e))))
   (lambda () (select-max hourly-field (from Job))))
  (check-exn
   (lambda (e) (and (exn:fail:user? e)
                    (regexp-match? #rx"MoneyRate columns do not support selectMin" (exn-message e))))
   (lambda () (select-min hourly-field (from Job))))
  (check-exn
   (lambda (e) (and (exn:fail:user? e)
                    (regexp-match? #rx"selectSumBy over a MoneyRate column is not supported" (exn-message e))))
   (lambda () (select-sum-by (sql-group-key 'field 0 team-field)
                             hourly-field
                             (from Job))))

  ;; update ... set j.hourly = <rate>
  (update-many! (from Job)
                (hash 'hourly (eur/h 4242))
                (where (==. job-id-field "j1")))
  (check-equal? (select-hourly "j1") (eur/h 4242)
                "update set replaces the whole MoneyRate value")

  ;; a non-MoneyRate value bound to a MoneyRate field is rejected clearly
  (check-exn
   (lambda (e) (and (exn:fail:user? e)
                    (regexp-match? #rx"needs a MoneyRate value" (exn-message e))))
   (lambda () (insert-one! Job (hash 'id "bad" 'team "x" 'hourly 95000)))
   "a bare integer cannot be stored into a MoneyRate field")
  (check-exn
   (lambda (e) (and (exn:fail:user? e)
                    (regexp-match? #rx"needs a MoneyRate value" (exn-message e))))
   (lambda () (insert-one! Job (hash 'id "bad" 'team "x" 'hourly (usd 95000))))
   "a plain Money cannot be stored into a MoneyRate field")

  ;; a rate whose label dimension contradicts the field's declared alias is
  ;; rejected at the WRITE boundary (same judgment as the read path)
  (check-exn
   (lambda (e) (and (exn:fail:user? e)
                    (regexp-match? #rx"mass denominator.*expects a duration denominator" (exn-message e))))
   (lambda () (insert-one! Job (hash 'id "bad" 'team "x"
                                     'hourly (rate-of 100 "USD" "kg" 1))))
   "a per-kg rate cannot be written into a MoneyPerDuration field")

  ;; and a MoneyRate operand on a NON-rate column is equally rejected
  (check-exn
   exn:fail:user?
   (lambda () (select-many (from Job) (where (==. team-field (usd/h 1)))))
   "a MoneyRate value bound to a String field is rejected"))

;; ── Unsupported MoneyRate field shapes are fail-closed at the seams ──────────

;; Maybe MoneyRate is fail-closed until its three-column NULL semantics exist.
(define-entity MaybeRateRow
  #:source (make-hash)
  #:table maybe_rate_rows
  #:primary-key id
  [Id id : String]
  [Hourly hourly : (Maybe MoneyPerDuration)])

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"Maybe MoneyRate fields are not supported yet" (exn-message e))))
 (lambda () (field-column-definitions-sql (entity-field-ref MaybeRateRow 'hourly)))
 "Maybe MoneyRate is rejected at the DDL seam")

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"Maybe MoneyRate fields are not supported yet" (exn-message e))))
 (lambda ()
   (with-capabilities (db-write)
     (insert-one! MaybeRateRow (hash 'id "m1" 'hourly (usd/h 1)))))
 "Maybe MoneyRate is rejected at the write seam")

;; A MoneyRate primary key is rejected.
(define-entity RatePkRow
  #:source (make-hash)
  #:table rate_pk_rows
  #:primary-key hourly
  [Hourly hourly : MoneyPerDuration])

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"a MoneyRate field cannot be the primary key" (exn-message e))))
 (lambda () (field-column-definitions-sql (entity-field-ref RatePkRow 'hourly)))
 "a MoneyRate primary key is rejected at the DDL seam")

;; A #:db-type override on a MoneyRate field is rejected.
(define-entity DbTypeRateRow
  #:source (make-hash)
  #:table db_type_rate_rows
  #:primary-key id
  [Id id : String]
  [Hourly hourly : MoneyPerDuration #:db-type text])

(check-exn
 (lambda (e) (and (exn:fail:user? e)
                  (regexp-match? #rx"MoneyRate fields manage their own three-column storage" (exn-message e))))
 (lambda () (field-column-definitions-sql (entity-field-ref DbTypeRateRow 'hourly)))
 "a #:db-type override on a MoneyRate field is rejected")
