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
    #:entities MoneyRow)

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
        "an unknown stored currency code raises loudly on the PG read path"))))

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
