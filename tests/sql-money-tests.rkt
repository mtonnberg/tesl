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
