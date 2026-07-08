#lang racket

;;; Two-column Money storage — PostgreSQL side, on a REAL (temporary) cluster.
;;;
;;; A `Money` field maps to `<col>_minor BIGINT NOT NULL` + `<col>_currency
;;; TEXT NOT NULL`.  This test proves, through the actual runtime path
;;; (DDL/auto-migration, parameterized INSERT/UPDATE/SELECT, WHERE lowering,
;;; the SUM decision table):
;;;   - CREATE TABLE emits both derived columns (asserted via
;;;     information_schema) and NO single logical column;
;;;   - auto-migration adds BOTH columns when a Money field is added to an
;;;     existing (empty) table;
;;;   - insert/select roundtrip preserves minor units + currency;
;;;   - where == discriminates on the currency column too;
;;;   - selectSum matches the Memory backend on the SAME seeded data
;;;     (single-currency total, mixed-currency error, empty-set error);
;;;   - a corrupt stored currency code fails closed on decode.
;;;
;;; Skips cleanly when initdb/pg_ctl are absent.

(require rackunit
         db
         "../dsl/capability.rkt"
         "../dsl/check.rkt"
         "../dsl/sql.rkt"
         "../dsl/types.rkt"
         "../dsl/private/money-core.rkt"
         "../dsl/private/currency-data.rkt"
         "private/postgres-test-support.rkt")

(define (usd n) (tesl-money n (tesl-currency-of "USD")))
(define (eur n) (tesl-money n (tesl-currency-of "EUR")))

;; ONE entity serves both backends: with the postgres database-runtime
;; installed the queries hit PostgreSQL; with the runtime parameterized off
;; they fall back to the in-memory #:source — that is the parity seam.
(define memory-rows (make-hash))

(define-entity MoneyRow
  #:source (lambda () memory-rows)
  #:table money_rows
  #:primary-key id
  [Id id : String]
  [Sku sku : String]
  [Price price : Money])

;; Three-column MoneyRate storage, PG side: `<col>_minor BIGINT NOT NULL` +
;; `<col>_currency TEXT NOT NULL` + `<col>_per TEXT NOT NULL`.  Persistence
;; is a BOUNDARY (quantize on write, reconstruct + dimension-verify on read),
;; so Memory ≡ PG roundtrips exactly — asserted below on the same seeds.
(define rate-memory-rows (make-hash))

(define-entity RateRow
  #:source (lambda () rate-memory-rows)
  #:table rate_rows
  #:primary-key id
  [Id id : String]
  [Team team : String]
  [Hourly hourly : MoneyPerDuration])

;; Auto-migration pair: V1 creates the table without the Money field, V2
;; declares the SAME table with a Money field added.
(define-entity MigrateRowV1
  #:table migrate_rows
  #:primary-key id
  [Id id : String])

(define-entity MigrateRowV2
  #:table migrate_rows
  #:primary-key id
  [Id id : String]
  [Fee fee : Money])

(define price-field (entity-field-ref MoneyRow 'price))
(define id-field (entity-field-ref MoneyRow 'id))
(define sku-field (entity-field-ref MoneyRow 'sku))

(define hourly-field (entity-field-ref RateRow 'hourly))
(define rate-id-field (entity-field-ref RateRow 'id))

;; A hand-built rate: minor-per-label / factor = the exact per-canonical
;; rational (the MoneyRate.perHour shape).
(define (rate-of minor-per-label code label factor)
  (tesl-money-rate (/ minor-per-label factor) (tesl-currency-of code) factor label))
(define (usd/h m) (rate-of m "USD" "h" 3600))
(define (eur/h m) (rate-of m "EUR" "h" 3600))
(define (usd/day m) (rate-of m "USD" "day" 86400))

(define (seed-rates!)
  ;; r1/r2 share (minor, label) but differ in currency; r3 is the SAME price
  ;; as r1 (95000/h × 24) stored per "day" (equality is REPRESENTATIONAL);
  ;; r4's 500.5 minor/label exercises the half-even write quantization.
  (insert-one! RateRow (hash 'id "r1" 'team "core" 'hourly (usd/h 95000)))
  (insert-one! RateRow (hash 'id "r2" 'team "core" 'hourly (eur/h 95000)))
  (insert-one! RateRow (hash 'id "r3" 'team "ops" 'hourly (usd/day 2280000)))
  (insert-one! RateRow (hash 'id "r4" 'team "ops" 'hourly (rate-of 1001/2 "USD" "h" 3600))))

(define (select-hourly id)
  (hash-ref (raw-value (select-one (from RateRow) (where (==. rate-id-field id)))) 'hourly))

(define (seed-rows!)
  ;; p1/p2 share USD; p3 is EUR with the SAME minor units as p1 so == must
  ;; discriminate on the currency column.
  (insert-one! MoneyRow (hash 'id "p1" 'sku "widget" 'price (usd 1999)))
  (insert-one! MoneyRow (hash 'id "p2" 'sku "widget" 'price (usd 2500)))
  (insert-one! MoneyRow (hash 'id "p3" 'sku "gadget" 'price (eur 1999))))

(define (select-price id)
  (hash-ref (raw-value (select-one (from MoneyRow) (where (==. id-field id)))) 'price))

;; column_name → (data_type . is_nullable) for a table, straight from
;; information_schema (independent of sql.rkt's own metadata reader).
(define (table-columns conn schema table)
  (for/hash ([row (in-list (query-rows conn
                                       "select column_name, data_type, is_nullable
                                          from information_schema.columns
                                         where table_schema = $1 and table_name = $2"
                                       schema table))])
    (values (vector-ref row 0)
            (cons (vector-ref row 1) (vector-ref row 2)))))

(define (run-money-pg-tests cfg)
  (define host (hash-ref cfg 'host))
  (define port (hash-ref cfg 'port))
  (define db-name (hash-ref cfg 'database))
  (define user (hash-ref cfg 'user))

  (define-database MoneyDb
    #:backend postgres
    #:database db-name
    #:user user
    #:server host
    #:port port
    #:schema money_pg_tests
    #:entities MoneyRow RateRow)

  (call-with-database
   MoneyDb
   (lambda ()
     (define conn (database-runtime-connection (current-database-runtime)))
     (with-capabilities (db-read db-write)

       ;; ── DDL: both derived columns exist, the logical column does not ──
       (define columns (table-columns conn "money_pg_tests" "money_rows"))
       (check-equal? (hash-ref columns "price_minor" #f) (cons "bigint" "NO")
                     "price_minor is BIGINT NOT NULL")
       (check-equal? (hash-ref columns "price_currency" #f) (cons "text" "NO")
                     "price_currency is TEXT NOT NULL")
       (check-false (hash-has-key? columns "price")
                    "no single 'price' column is created")

       ;; ── roundtrip ──
       (seed-rows!)
       (check-equal? (select-price "p1") (usd 1999)
                     "insert+select roundtrip preserves minor units + currency")

       ;; ── where == / != discriminate on the currency column ──
       (check-equal? (map (lambda (r) (hash-ref (raw-value r) 'id))
                          (select-many (from MoneyRow)
                                       (where (==. price-field (usd 1999)))))
                     (list "p1")
                     "== matches the USD row only, not the EUR row with equal minor units")
       (check-equal? (length (select-many (from MoneyRow)
                                          (where (!=. price-field (usd 1999)))))
                     2
                     "!= excludes exactly the matching Money row")

       ;; ── ordered comparison is rejected on the PG path too ──
       (check-exn
        (lambda (e) (and (exn:fail:user? e)
                         (regexp-match? #rx"Money columns do not support ordered comparison in where clauses"
                                        (exn-message e))))
        (lambda () (select-many (from MoneyRow)
                                (where (>=. price-field (usd 1))))))

       ;; ── SUM decision table, and parity with the Memory backend on the
       ;;    SAME seeded data ──
       (define (sum-widget) (select-sum price-field (from MoneyRow)
                                        (where (==. sku-field "widget"))))
       (define (sum-all) (select-sum price-field (from MoneyRow)))
       (define (sum-none) (select-sum price-field (from MoneyRow)
                                      (where (==. sku-field "no-such-sku"))))

       (define pg-widget-sum (sum-widget))
       (check-equal? pg-widget-sum (usd 4499)
                     "PG single-currency sum adds minor units natively")
       (check-exn
        (lambda (e) (and (exn:fail:user? e)
                         (regexp-match? #rx"cannot sum Money across mixed currencies \\(found 2\\)"
                                        (exn-message e))))
        (lambda () (sum-all))
        "PG mixed-currency sum is rejected with the distinct count")
       (check-exn
        (lambda (e) (and (exn:fail:user? e)
                         (regexp-match? #rx"cannot sum Money over an empty row set"
                                        (exn-message e))))
        (lambda () (sum-none))
        "PG empty-set Money sum is rejected")

       ;; Memory backend, same data, same queries — identical outcomes.
       (parameterize ([current-database-runtime #f])
         (hash-clear! memory-rows)
         (seed-rows!)
         (check-equal? (sum-widget) pg-widget-sum
                       "Memory and PG agree on the single-currency sum")
         (check-exn
          (lambda (e) (and (exn:fail:user? e)
                           (regexp-match? #rx"cannot sum Money across mixed currencies \\(found 2\\)"
                                          (exn-message e))))
          (lambda () (sum-all))
          "Memory rejects the mixed-currency sum identically")
         (check-exn
          (lambda (e) (and (exn:fail:user? e)
                           (regexp-match? #rx"cannot sum Money over an empty row set"
                                          (exn-message e))))
          (lambda () (sum-none))
          "Memory rejects the empty-set sum identically"))

       ;; ── update ... set p.price = <money> writes both columns ──
       (update-many! (from MoneyRow)
                     (hash 'price (eur 4242))
                     (where (==. id-field "p1")))
       (check-equal? (select-price "p1") (eur 4242)
                     "update set replaces both derived columns")

       ;; ── corrupt stored currency code fails closed on decode ──
       (query-exec conn
                   "update money_pg_tests.money_rows set price_currency = 'ZZZ' where id = 'p3'")
       (check-exn
        (lambda (e) (and (exn:fail:user? e)
                         (regexp-match? #rx"not a known ISO 4217 currency" (exn-message e))))
        (lambda () (select-price "p3"))
        "an unknown stored currency code raises loudly on the PG read path")

       ;; ═══ Three-column MoneyRate storage ═══════════════════════════════

       ;; ── DDL: all three derived columns exist, the logical column does not ──
       (define rate-columns (table-columns conn "money_pg_tests" "rate_rows"))
       (check-equal? (hash-ref rate-columns "hourly_minor" #f) (cons "bigint" "NO")
                     "hourly_minor is BIGINT NOT NULL")
       (check-equal? (hash-ref rate-columns "hourly_currency" #f) (cons "text" "NO")
                     "hourly_currency is TEXT NOT NULL")
       (check-equal? (hash-ref rate-columns "hourly_per" #f) (cons "text" "NO")
                     "hourly_per is TEXT NOT NULL")
       (check-false (hash-has-key? rate-columns "hourly")
                    "no single 'hourly' column is created")

       ;; ── roundtrip: write quantizes (boundary), read reconstructs ──
       (seed-rates!)
       (let ([rate (select-hourly "r1")])
         (check-pred tesl-money-rate? rate)
         (let-values ([(minor code label) (tesl-money-rate-quantize rate)])
           (check-equal? (list minor code label) (list 95000 "USD" "h")
                         "PG roundtrip preserves the (minor, currency, per) triple")))
       ;; the half-even quantization physically reached the BIGINT column
       (check-equal? (query-value conn
                                  "select hourly_minor from money_pg_tests.rate_rows where id = 'r4'")
                     500
                     "500.5 minor/label was stored half-even as 500")

       ;; ── where == / != discriminate on ALL three columns ──
       (check-equal? (map (lambda (r) (hash-ref (raw-value r) 'id))
                          (select-many (from RateRow)
                                       (where (==. hourly-field (usd/h 95000)))))
                     (list "r1")
                     "== matches the same-triple row only (not the EUR row, and — representational equality — not the same price stored per day)")
       (check-equal? (length (select-many (from RateRow)
                                          (where (!=. hourly-field (usd/h 95000)))))
                     3
                     "!= excludes exactly the matching MoneyRate row")

       ;; ── rejections hold on the PG path too ──
       (check-exn
        (lambda (e) (and (exn:fail:user? e)
                         (regexp-match? #rx"MoneyRate columns do not support ordered comparison in where clauses"
                                        (exn-message e))))
        (lambda () (select-many (from RateRow)
                                (where (>=. hourly-field (usd/h 1))))))
       (check-exn
        (lambda (e) (and (exn:fail:user? e)
                         (regexp-match? #rx"selectSum over a MoneyRate column is not supported; aggregate the materialized Money instead"
                                        (exn-message e))))
        (lambda () (select-sum hourly-field (from RateRow))))

       ;; ── Memory ≡ PG: the SAME seeds reconstruct to equal? structs ──
       (let ([pg-rates (for/list ([id (in-list '("r1" "r2" "r3" "r4"))])
                         (select-hourly id))])
         (parameterize ([current-database-runtime #f])
           (hash-clear! rate-memory-rows)
           (seed-rates!)
           (for ([id (in-list '("r1" "r2" "r3" "r4"))]
                 [pg-rate (in-list pg-rates)])
             (check-equal? (select-hourly id) pg-rate
                           (format "Memory and PG agree on the stored rate for ~a" id)))))

       ;; ── update ... set r.hourly = <rate> writes all three columns ──
       (update-many! (from RateRow)
                     (hash 'hourly (eur/h 4242))
                     (where (==. rate-id-field "r1")))
       (check-equal? (select-hourly "r1") (eur/h 4242)
                     "update set replaces all three derived columns")

       ;; ── corrupt stored label fails closed on decode (wrong DIMENSION) ──
       (query-exec conn
                   "update money_pg_tests.rate_rows set hourly_per = 'kg' where id = 'r3'")
       (check-exn
        (lambda (e) (and (exn:fail:user? e)
                         (regexp-match? #rx"mass denominator.*expects a duration denominator"
                                        (exn-message e))))
        (lambda () (select-hourly "r3"))
        "a stored label of the wrong dimension raises loudly on the PG read path")
       (query-exec conn
                   "update money_pg_tests.rate_rows set hourly_per = 'zzz' where id = 'r4'")
       (check-exn
        (lambda (e) (and (exn:fail:user? e)
                         (regexp-match? #rx"unknown rate unit label" (exn-message e))))
        (lambda () (select-hourly "r4"))
        "an unknown stored label raises loudly on the PG read path"))))

  ;; ── auto-migration: adding a Money field adds BOTH columns ──
  (define-database MigrateDbV1
    #:backend postgres
    #:database db-name
    #:user user
    #:server host
    #:port port
    #:schema money_pg_tests
    #:entities MigrateRowV1)
  (define-database MigrateDbV2
    #:backend postgres
    #:database db-name
    #:user user
    #:server host
    #:port port
    #:schema money_pg_tests
    #:entities MigrateRowV2)

  ;; V1 creates the table without the Money field ...
  (call-with-database MigrateDbV1 (lambda () (void)))
  ;; ... V2 auto-migrates the existing (empty) table, adding both columns,
  ;; and the migrated table then serves a full roundtrip.
  (call-with-database
   MigrateDbV2
   (lambda ()
     (define conn (database-runtime-connection (current-database-runtime)))
     (define columns (table-columns conn "money_pg_tests" "migrate_rows"))
     (check-equal? (hash-ref columns "fee_minor" #f) (cons "bigint" "NO")
                   "migration added fee_minor BIGINT NOT NULL")
     (check-equal? (hash-ref columns "fee_currency" #f) (cons "text" "NO")
                   "migration added fee_currency TEXT NOT NULL")
     (with-capabilities (db-read db-write)
       (insert-one! MigrateRowV2 (hash 'id "m1" 'fee (usd 750)))
       (check-equal? (hash-ref (raw-value
                                (select-one (from MigrateRowV2)
                                            (where (==. (entity-field-ref MigrateRowV2 'id) "m1"))))
                               'fee)
                     (usd 750)
                     "the migrated Money field roundtrips")))))

(define (run-all)
  (if (not (postgres-tooling-available?))
      (displayln "Skipping sql-money-pg-test.rkt because initdb/pg_ctl are not available")
      (call-with-temporary-postgres run-money-pg-tests)))

(run-all)
