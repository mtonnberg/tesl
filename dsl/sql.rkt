#lang racket

(require db
         json
         racket/list
         racket/match
         racket/string
         "capability.rkt"
         "private/check-runtime.rkt"
         "types.rkt"
         ;; SQL TRANSPARENCY (task #43): capture the EXACT parameterized statement +
         ;; ordered params + row count for the DAP "SQL" scope.  domain-registry is
         ;; dependency-free and already DEBUG-GATED (TESL_DEBUG); these calls are a
         ;; no-op in a release run, so there is zero release-path cost.
         (only-in "private/domain-registry.rkt"
                  sql-capture-pending!
                  sql-capture-executed!)
         (only-in "../tesl/logging.rkt"
                  tesl-log-active?
                  tesl-log-sql!)
         (only-in "metrics.rkt"
                  metrics-active?
                  metric-counter-add!
                  metric-histogram-record!
                  metric-gauge-set!
                  duration-histogram-boundaries)
         ;; Grouped aggregates (GitHub #29): rows are Tuple2 values, and the
         ;; Memory backend buckets through the SAME calendar engine the emitted
         ;; PostgreSQL expressions are tested against.
         (only-in "../tesl/tuple.rkt" Tuple2)
         (only-in "private/time-trunc.rkt"
                  tesl-time-trunc tesl-tz? tesl-tz-kind tesl-tz-payload)
         ;; Two-column Money storage: a `Money` field maps to `<col>_minor
         ;; BIGINT NOT NULL` + `<col>_currency TEXT NOT NULL` (native SUM over
         ;; minor units; the currency column makes mixed-currency aggregation
         ;; detectable and rejected).  Layering: sql.rkt requires ONLY the core
         ;; structs + baked ISO table — never tesl/money.rkt (surface module).
         (only-in "private/money-core.rkt"
                  tesl-money tesl-money? tesl-money-minor-units tesl-money-currency
                  tesl-currency-code tesl-currency-of
                  ;; Three-column MoneyRate storage: a rate field (declared as
                  ;; one of the five MoneyPer* denominator aliases) maps to
                  ;; `<col>_minor BIGINT NOT NULL` + `<col>_currency TEXT NOT
                  ;; NULL` + `<col>_per TEXT NOT NULL`.  Persistence is a
                  ;; BOUNDARY: quantize on write (half-even, the Money.convert
                  ;; stance), reconstruct + dimension-verify on read.
                  tesl-money-rate?
                  tesl-money-rate-quantize
                  tesl-money-rate-of-boundary
                  rate-alias-dim-table)
         ;; Instantiated for its side effect: populates tesl-currency-table so
         ;; tesl-currency-of resolves the baked ISO 4217 codes.
         (only-in "private/currency-data.rkt")
         (for-syntax racket/base
                     racket/list
                     racket/syntax
                     syntax/parse
                     "types.rkt"))

(provide define-entity
         define-database
         connect-database
         disconnect-database
         call-with-database
         ensure-database-ready!
         current-database-runtime
         db-read
         db-write
         entity-field-ref
         from
         where
         ==.
         !=.
         <.
         <=.
         >.
         >=.
         or.
         order-by
         limit
         offset
         null?.
         not-null?.
         in?.
         not-in?.
         like?.
         ilike?.
         group-by
         inner-join
         insert-one!
         insert-many!
         update-many!
         delete-many!
         delete-many-with-count!
         upsert-one!
         NoRowDeleted
         RowsDeleted
         select-one
         select-many
         select-count
         select-sum
         sql-group-key
         select-count-by
         select-sum-by
         select-max
         select-min
         row-field-ref
         (struct-out entity-spec)
         (struct-out field-spec)
         (struct-out from-clause)
         (struct-out where-clause)
         (struct-out eq-predicate)
         (struct-out comparison-predicate)
         (struct-out or-predicate)
         (struct-out order-clause)
         (struct-out limit-clause)
         (struct-out offset-clause)
         (struct-out null-predicate)
         (struct-out not-null-predicate)
         (struct-out in-predicate)
         (struct-out not-in-predicate)
         (struct-out like-predicate)
         (struct-out ilike-predicate)
         (struct-out group-by-clause)
         (struct-out inner-join-clause)
         (struct-out postgres-spec)
         (struct-out database-spec)
         (struct-out database-runtime)
         database-schema-name
         ;; Memory-database registry (test isolation): every `define-database
         ;; #:backend memory` registers its spec here so
         ;; call-with-fresh-memory-db (dsl/test-support.rkt) can reset the
         ;; stores of ALL live memory databases — including ones declared in
         ;; IMPORTED modules, which the emitter's per-module database list
         ;; cannot see (it harvests only the emitting module's own decls).
         register-memory-database!
         registered-memory-databases
         ;; Pool-lease waiting (issue #31): the timeout error is exported so the
         ;; HTTP layer can map it to 503 instead of a generic 500; the connector
         ;; builder is exported so the pool behaviour is testable without a live
         ;; PostgreSQL (tests/pg-pool-tests.rkt).
         (struct-out exn:fail:tesl:pool-timeout)
         make-pool-lease-connector
         pool-lease-timeout-ms
         ;; Exported for testing only — not part of public API
         identifier-value->string
         compile-predicate-sql
         compile-where-sql
         column-definition-sql
         field-db-type-annotation
         field-column-definitions-sql
         check-money-column-collisions!
         money-db-values->runtime-value
         money-rate-db-values->runtime-value)

(struct entity-spec (name source primary-key fields predicate table) #:transparent)
;; nullable? is #t for Maybe-typed fields — these map to NULL in PostgreSQL.
(struct field-spec (entity proof-name key type primary-key? column db-type nullable?) #:transparent)
(struct from-clause (entity) #:transparent)
(struct where-clause (predicate) #:transparent)
(struct eq-predicate (field operand) #:transparent)
(struct comparison-predicate (field operator operand) #:transparent)
(struct or-predicate (left right) #:transparent)
(struct order-clause (field direction) #:transparent)
(struct limit-clause (count) #:transparent)
(struct offset-clause (count) #:transparent)
(struct null-predicate (field) #:transparent)
(struct not-null-predicate (field) #:transparent)
(struct in-predicate (field values) #:transparent)
(struct not-in-predicate (field values) #:transparent)
(struct like-predicate (field pattern) #:transparent)
(struct ilike-predicate (field pattern) #:transparent)
(struct group-by-clause (fields) #:transparent)
(struct inner-join-clause (entity main-field join-field) #:transparent)
(struct postgres-spec (database user password server port socket max-connections max-idle-connections auto-migrate?) #:transparent)
(struct database-spec (name backend schema entities config) #:transparent)
(struct database-runtime (database connection) #:transparent)

;; ── Memory-database registry ─────────────────────────────────────────────────
;; Every memory-backend database-spec is recorded at creation (define-database's
;; memory arm calls register-memory-database!).  Rationale: test-block state
;; isolation (call-with-fresh-memory-db) must reset the entity stores of EVERY
;; live memory database, but the compiler can only emit a per-module reset list
;; from the decls it sees — a `database` block declared in an IMPORTED module is
;; invisible there, so its rows used to leak across test/api-test/load-test
;; blocks (matrix 2026-07: entity-db/isolation, test-blocks/server-x).  The
;; registry makes the reset registry-based instead of decl-based: the runtime
;; objects self-register at module instantiation, which by require-ordering
;; always happens before any test block runs.  Postgres databases never
;; register (their state is not process-local, resetting it is not our call).
;; eq?-keyed hash so re-registration of the same spec is idempotent.
(define memory-database-registry (make-hasheq))
(define (register-memory-database! spec)
  (hash-set! memory-database-registry spec #t)
  spec)
(define (registered-memory-databases)
  (hash-keys memory-database-registry))

(define current-database-runtime (make-parameter #f))

(define-capability db-read)
(define-capability db-write (implies db-read))

(define built-in-db-type-registry
  (hash 'Boolean 'boolean
        'Bytes 'bytea
        ;; NT-07: `Int` → NUMERIC (arbitrary precision, lossless for any magnitude).
        ;; This is the SINGLE mapping for a plain integer column: a bare `Int` field
        ;; AND a newtype-over-`Int` field both map to NUMERIC (see newtype-base->db-type).
        ;; `Int32` → integer/int4 (compact + JS-safe) is the opt-in 64-bit-safe width.
        ;; `PosixMillis` is the one deliberate BIGINT exception (entry below).
        'Integer 'numeric
        'Int32 'integer
        'Number 'double-precision
        'Real 'double-precision
        'String 'text
        ;; Note: PosixMillis → bigint is now handled via newtype-registry lookup
        ;; in default-field-db-type-annotation (type-ref keys, not plain symbols).
        ;; The entry below is kept for any direct plain-symbol lookups as a fallback.
        'PosixMillis 'bigint))

(define (camel->snake text)
  (define collapsed-acronyms
    (regexp-replace* #px"([A-Z]+)([A-Z][a-z])" text "\\1_\\2"))
  (define separated-words
    (regexp-replace* #px"([a-z0-9])([A-Z])" collapsed-acronyms "\\1_\\2"))
  (string-downcase separated-words))

(define (identifier-value->string value who)
  (define raw
    (cond
      [(symbol? value) (symbol->string value)]
      [(string? value) value]
      [else
       (raise-user-error who "expected an identifier symbol or string, got ~a" value)]))
  (unless (regexp-match? #px"^[A-Za-z_][A-Za-z0-9_]*$" raw)
    (raise-user-error who "expected a simple SQL identifier, got ~a" value))
  raw)

(define (quote-sql-identifier value who)
  (format "\"~a\"" (identifier-value->string value who)))

(define (default-table-name entity-name)
  (string->symbol (camel->snake (symbol->string entity-name))))

(define (default-column-name field-key)
  (string->symbol (camel->snake (symbol->string field-key))))

(define (entity-table-name entity)
  (or (entity-spec-table entity)
      (default-table-name (entity-spec-name entity))))

(define (field-column-name field)
  (or (field-spec-column field)
      (default-column-name (field-spec-key field))))

(define (database-schema-name database)
  (or (database-spec-schema database) "public"))

(define (qualified-table-name database entity)
  (format "~a.~a"
          (quote-sql-identifier (database-schema-name database) 'sql)
          (quote-sql-identifier (entity-table-name entity) 'sql)))

;; #t iff a type datum names an ADT — either a bare ADT name (`Status`) or a
;; parametric ADT application (`(Tree Int)`). Used both for a field's own type and
;; for the inner type of a `Maybe <ADT>` field so both map to JSONB consistently.
(define (adt-type-datum? type-datum)
  (or (adt-application-spec type-datum)
      (lookup-adt-spec type-datum #f)))

(define (field-adt-type? field)
  (adt-type-datum? (field-spec-type field)))

;; Extract the inner type of a Maybe X field type datum.
;; Returns the inner type if this is (list 'Maybe inner), #f otherwise.
(define (maybe-field-inner-type type-datum)
  (and (list? type-datum)
       (= (length type-datum) 2)
       (eq? (car type-datum) 'Maybe)
       (cadr type-datum)))

;; The name symbol of a newtype/type reference. A field's type datum is either a
;; bare symbol (`Counter`) or a prefab `type-ref` (`#s(type-ref <owner> Counter)`)
;; for a name imported from another module (e.g. `PosixMillis` from tesl/time.rkt).
;; `type-ref` is a #:prefab struct, so we can read its name via the prefab match
;; pattern without importing the struct definition from types.rkt.
(define (type-datum-name type-datum)
  (match type-datum
    [(? symbol?) type-datum]
    [`#s(type-ref ,_owner ,name) name]
    [_ #f]))

;; NT-07: resolve a newtype's BASE to its column type. `Int` is arbitrary-precision
;; (A9), so BOTH a bare `Int` field AND a newtype-over-`Int` field map to the SAME
;; column type — `NUMERIC` (lossless for any magnitude). A newtype over `Integer`
;; must NOT silently narrow to a 64-bit `BIGINT`: that would reopen the exact NT-07
;; silent-truncation hole for values > 2^63 (a user-defined `newtype Counter = Int`
;; is still arbitrary-precision). `PosixMillis` is the ONE deliberate BIGINT
;; exception — a distinct 64-bit millis-timestamp type, not an arbitrary `Int`, whose
;; BIGINT storage is contractual (LANGUAGE-SPEC §11.8, existing PG tables + the
;; auto-migration) — so it is special-cased BY NAME here. `type-datum` is the field's
;; declared type (symbol or `type-ref`), used only to detect that PosixMillis case.
;; Any other field wanting compact 64-bit storage uses `Int32` (int4) or `#:db-type`.
(define (newtype-base->db-type base type-datum)
  (and base
       (cond
         [(eq? base 'Integer)
          (if (eq? (type-datum-name type-datum) 'PosixMillis) 'bigint 'numeric)]
         [else (hash-ref built-in-db-type-registry base #f)])))

(define (default-field-db-type-annotation field)
  (define type-datum (field-spec-type field))
  ;; Maybe X field: derive db type from the inner X type
  (define inner-maybe (maybe-field-inner-type type-datum))
  (if inner-maybe
      (or (hash-ref built-in-db-type-registry inner-maybe #f)
          (newtype-base->db-type (hash-ref newtype-registry inner-maybe #f) inner-maybe)
          ;; `Maybe <ADT>` maps to a NULLABLE jsonb, mirroring a bare `<ADT>` → jsonb.
          ;; (nullable? is set separately from the type datum, so this is a plain
          ;; `jsonb` column that PostgreSQL leaves NULL-able by default.) Without this
          ;; a `Maybe <ADT>` field silently fell through to the `'text` default below,
          ;; producing a TEXT column inconsistent with the non-nullable ADT mapping.
          (and (adt-type-datum? inner-maybe) 'jsonb)
          'text)  ; fall back to text for unknown Maybe X
      (or ;; Direct match (e.g. 'String, 'Integer→numeric, 'Boolean with plain symbol keys)
          (hash-ref built-in-db-type-registry type-datum #f)
          ;; Newtype: base type → column type (Integer-based newtypes → NUMERIC, like Int;
          ;; PosixMillis is the named BIGINT exception, handled inside newtype-base->db-type).
          (newtype-base->db-type (hash-ref newtype-registry type-datum #f) type-datum)
          ;; ADT fields default to jsonb
          (and (field-adt-type? field) 'jsonb)
          #f)))

(define (field-db-type-annotation field)
  (or (field-spec-db-type field)
      (default-field-db-type-annotation field)
      (raise-user-error 'sql
                        "field ~a on entity ~a needs an explicit #:db-type for automatic PostgreSQL schema generation"
                        (field-spec-key field)
                        (field-spec-entity field))))

(define (db-type->sql-string db-type)
  (match db-type
    ['boolean "BOOLEAN"]
    ['bytea "BYTEA"]
    ['bigint "BIGINT"]
    ['integer "INTEGER"]
    ['numeric "NUMERIC"]   ; NT-07: Int → arbitrary-precision NUMERIC (lossless)
    ['text "TEXT"]
    ['double-precision "DOUBLE PRECISION"]
    [(? symbol?)
     (string-upcase (string-replace (symbol->string db-type) "-" " "))]
    [(? string?) db-type]
    [other
     (raise-user-error 'sql "unsupported PostgreSQL type annotation ~a" other)]))

(define (db-type->normalized-string db-type)
  (string-downcase (db-type->sql-string db-type)))

(define (column-definition-sql field)
  (when (money-field? field)
    (raise-user-error 'sql
                      "field ~a on entity ~a is a Money field and stores into TWO columns; use field-column-definitions-sql"
                      (field-spec-key field)
                      (field-spec-entity field)))
  (when (money-rate-field? field)
    (raise-user-error 'sql
                      "field ~a on entity ~a is a MoneyRate field and stores into THREE columns; use field-column-definitions-sql"
                      (field-spec-key field)
                      (field-spec-entity field)))
  (string-append
   (quote-sql-identifier (field-column-name field) 'sql)
   " "
   (db-type->sql-string (field-db-type-annotation field))
   (cond
     [(field-spec-primary-key? field) " PRIMARY KEY"]
     [(field-spec-nullable? field) ""]       ; NULL is the PostgreSQL default
     [else " NOT NULL"])))

;; ── Two-column Money storage ──────────────────────────────────────────────────
;;
;; A `Money` field (dsl/private/money-core.rkt: exact-integer minor units + an
;; ISO 4217 currency) maps to TWO PostgreSQL columns:
;;
;;   <column>_minor     BIGINT NOT NULL   -- exact minor units (cents/öre/yen)
;;   <column>_currency  TEXT   NOT NULL   -- ISO 4217 alpha code ("USD")
;;
;; chosen so SUM stays native SQL over the minor column while the currency
;; column makes cross-currency aggregation DETECTABLE (and rejected) instead
;; of silently summed.  The Memory backend keeps storing the tesl-money struct
;; directly in the row — parity with PostgreSQL is behavioural (the decision
;; tables below), not representational.  Money is matched BY NAME (exactly
;; like PosixMillis): the field's type datum is the symbol `Money` or a
;; type-ref carrying that name.

(define (money-type-datum? type-datum)
  (eq? (type-datum-name type-datum) 'Money))

(define (money-field? field)
  (money-type-datum? (field-spec-type field)))

;; `Maybe Money` would need NULL semantics spanning BOTH columns; fail closed
;; until that is designed rather than fall through to a single TEXT column.
(define (maybe-money-field? field)
  (define inner (maybe-field-inner-type (field-spec-type field)))
  (and inner (money-type-datum? inner) #t))

(define (money-related-field? field)
  (or (money-field? field) (maybe-money-field? field)))

(define (money-minor-column-string field who)
  (format "~a_minor" (identifier-value->string (field-column-name field) who)))

(define (money-currency-column-string field who)
  (format "~a_currency" (identifier-value->string (field-column-name field) who)))

;; The Money variants sql.rkt does NOT support (fail-closed, clear message):
;; Maybe Money, Money primary keys, and #:db-type overrides on a Money field.
(define (reject-unsupported-money-field! field who)
  (when (maybe-money-field? field)
    (raise-user-error who
                      "field ~a on entity ~a: Maybe Money fields are not supported yet (NULL semantics across the two Money columns are undefined)"
                      (field-spec-key field)
                      (field-spec-entity field)))
  (when (field-spec-primary-key? field)
    (raise-user-error who
                      "field ~a on entity ~a: a Money field cannot be the primary key"
                      (field-spec-key field)
                      (field-spec-entity field)))
  (when (field-spec-db-type field)
    (raise-user-error who
                      "field ~a on entity ~a: Money fields manage their own two-column storage (~a BIGINT + ~a TEXT); remove #:db-type"
                      (field-spec-key field)
                      (field-spec-entity field)
                      (money-minor-column-string field who)
                      (money-currency-column-string field who))))

;; One physical column an entity field expects on PostgreSQL (a Money field
;; expects two).  `type` is the normalized information_schema data_type string
;; the auto-migration compares against.
(struct expected-db-column (name definition type nullable? primary-key?) #:transparent)

(define (field-expected-db-columns field)
  (cond
    [(money-related-field? field)
     (reject-unsupported-money-field! field 'sql)
     (list (expected-db-column
            (money-minor-column-string field 'sql)
            (format "~a BIGINT NOT NULL"
                    (quote-sql-identifier (money-minor-column-string field 'sql) 'sql))
            "bigint" #f #f)
           (expected-db-column
            (money-currency-column-string field 'sql)
            (format "~a TEXT NOT NULL"
                    (quote-sql-identifier (money-currency-column-string field 'sql) 'sql))
            "text" #f #f))]
    [(money-rate-related-field? field)
     (reject-unsupported-money-rate-field! field 'sql)
     (list (expected-db-column
            (money-rate-minor-column-string field 'sql)
            (format "~a BIGINT NOT NULL"
                    (quote-sql-identifier (money-rate-minor-column-string field 'sql) 'sql))
            "bigint" #f #f)
           (expected-db-column
            (money-rate-currency-column-string field 'sql)
            (format "~a TEXT NOT NULL"
                    (quote-sql-identifier (money-rate-currency-column-string field 'sql) 'sql))
            "text" #f #f)
           (expected-db-column
            (money-rate-per-column-string field 'sql)
            (format "~a TEXT NOT NULL"
                    (quote-sql-identifier (money-rate-per-column-string field 'sql) 'sql))
            "text" #f #f))]
    [else
     (list (expected-db-column
            (identifier-value->string (field-column-name field) 'sql)
            (column-definition-sql field)
            (db-type->normalized-string (field-db-type-annotation field))
            (field-spec-nullable? field)
            (field-spec-primary-key? field)))]))

;; The CREATE TABLE / ALTER TABLE column definition(s) one field expands to —
;; two for a Money field, one for everything else.
(define (field-column-definitions-sql field)
  (map expected-db-column-definition (field-expected-db-columns field)))

;; A Money/MoneyRate field's derived column names must not collide with a
;; column another field already claims — creating/altering the table would
;; otherwise alias two fields onto one column.  Checked before any DDL runs.
(define (check-money-column-collisions! entity [who 'sql])
  (define fields (entity-spec-fields entity))
  (define base-columns
    (for/list ([f (in-list fields)])
      (identifier-value->string (field-column-name f) who)))
  (for ([f (in-list fields)]
        #:when (or (money-field? f) (money-rate-field? f)))
    (define kind (if (money-field? f) "Money" "MoneyRate"))
    (define derived-columns
      (if (money-field? f)
          (list (money-minor-column-string f who)
                (money-currency-column-string f who))
          (money-rate-column-strings f who)))
    (for ([derived (in-list derived-columns)])
      (when (member derived base-columns)
        (raise-user-error who
                          "entity ~a: ~a field ~a stores into derived columns ~a, but the entity already declares a column named ~a; rename one of the fields"
                          (entity-spec-name entity)
                          kind
                          (field-spec-key f)
                          (string-join derived-columns " and ")
                          derived)))))

;; SELECT/INSERT/RETURNING column list one field contributes (quoted names).
(define (field-select-column-sql-list field)
  (cond
    [(money-related-field? field)
     (reject-unsupported-money-field! field 'sql)
     (list (quote-sql-identifier (money-minor-column-string field 'sql) 'sql)
           (quote-sql-identifier (money-currency-column-string field 'sql) 'sql))]
    [(money-rate-related-field? field)
     (reject-unsupported-money-rate-field! field 'sql)
     (for/list ([col (in-list (money-rate-column-strings field 'sql))])
       (quote-sql-identifier col 'sql))]
    [else
     (list (quote-sql-identifier (field-column-name field) 'sql))]))

;; Reject a non-Money value bound for a Money field with a clear error.
(define (ensure-money-value field value who)
  (define raw (normalize-row-value value))
  (unless (tesl-money? raw)
    (raise-user-error who
                      "field ~a on entity ~a is a Money field and needs a Money value (e.g. (Money.usd 1999)), got ~e"
                      (field-spec-key field)
                      (field-spec-entity field)
                      value))
  raw)

;; Resolve a STORED currency code fail-closed: an unknown code is data
;; corruption (or a schema written by an incompatible build) and must surface
;; loudly, never decode into a half-formed Money.
(define (money-stored-currency field code who)
  (define currency (and (string? code) (tesl-currency-of code)))
  (unless currency
    (raise-user-error who
                      "field ~a on entity ~a: stored currency code ~e is not a known ISO 4217 currency — the ~a column holds corrupt data or was written by an incompatible schema"
                      (field-spec-key field)
                      (field-spec-entity field)
                      code
                      (money-currency-column-string field who)))
  currency)

;; Decode the two stored columns back into ONE tesl-money (fail-closed on a
;; malformed minor value or an unknown currency code).
(define (money-db-values->runtime-value field minor code [who 'sql])
  (define n
    (cond
      [(exact-integer? minor) minor]
      [(and (rational? minor)
            (exact-integer? (inexact->exact minor)))
       (inexact->exact minor)]
      [else #f]))
  (unless (exact-integer? n)
    (raise-user-error who
                      "field ~a on entity ~a: stored minor-units value ~e is not an integer — the ~a column holds corrupt data"
                      (field-spec-key field)
                      (field-spec-entity field)
                      minor
                      (money-minor-column-string field who)))
  (tesl-money n (money-stored-currency field code who)))

;; RUNTIME BACKSTOP (the compile-time forbid lives in the checker): ordered
;; operations over Money are meaningless across currencies, on BOTH backends —
;; raised at construction time so Memory and PostgreSQL agree exactly.
(define (reject-money-ordered-comparison! who field what)
  (when (money-related-field? field)
    (raise-user-error who
                      "field ~a on entity ~a: Money columns do not support ~a (currencies differ); compare Money.minorUnits explicitly after filtering by currency"
                      (field-spec-key field)
                      (field-spec-entity field)
                      what))
  ;; Same backstop for MoneyRate: ordering across currencies AND denominator
  ;; labels is meaningless (950/h vs 950/day are not comparable amounts).
  (when (money-rate-related-field? field)
    (raise-user-error who
                      "field ~a on entity ~a: MoneyRate columns do not support ~a (currencies and per-unit labels differ); aggregate the materialized Money instead"
                      (field-spec-key field)
                      (field-spec-entity field)
                      what)))

;; Predicates with no meaningful two-column Money lowering (fail-closed).
(define (reject-money-predicate! who field what)
  (when (money-related-field? field)
    (raise-user-error who
                      "field ~a on entity ~a: ~a is not supported on Money columns"
                      (field-spec-key field)
                      (field-spec-entity field)
                      what))
  (when (money-rate-related-field? field)
    (raise-user-error who
                      "field ~a on entity ~a: ~a is not supported on MoneyRate columns"
                      (field-spec-key field)
                      (field-spec-entity field)
                      what)))

;; selectSum over Money — ONE decision table for BOTH backends:
;;   0 distinct currencies (⇔ 0 matched rows; the columns are NOT NULL)
;;       → error: a zero total has no currency to carry (fail-closed);
;;   >1 distinct → error: summing across currencies is meaningless;
;;   exactly 1  → (tesl-money total currency).
(define (money-sum-result who field total distinct-count currency-thunk)
  (cond
    [(= distinct-count 0)
     (raise-user-error who
                       "field ~a on entity ~a: cannot sum Money over an empty row set (no currency for the zero total); guard with a count first"
                       (field-spec-key field)
                       (field-spec-entity field))]
    [(> distinct-count 1)
     (raise-user-error who
                       "field ~a on entity ~a: cannot sum Money across mixed currencies (found ~a); filter by currency first"
                       (field-spec-key field)
                       (field-spec-entity field)
                       distinct-count)]
    [else (tesl-money total (currency-thunk))]))

;; ── Three-column MoneyRate storage ────────────────────────────────────────────
;;
;; A MoneyRate field — declared as one of the five denominator aliases
;; (MoneyPerDuration / MoneyPerMass / MoneyPerLength / MoneyPerArea /
;; MoneyPerVolume, matched BY NAME exactly like Money) — maps to THREE
;; PostgreSQL columns:
;;
;;   <column>_minor     BIGINT NOT NULL   -- integer minor units per ONE per-unit
;;   <column>_currency  TEXT   NOT NULL   -- ISO 4217 alpha code ("USD")
;;   <column>_per       TEXT   NOT NULL   -- denominator unit label ("h", "kg")
;;
;; Persistence is a BOUNDARY: the stored value is the QUANTIZED shape —
;; integer minor units per one `per` unit, ONE half-even rounding, the same
;; one-rounding stance as Money.convert — on BOTH backends identically.  The
;; Memory backend stores the quantized-then-RECONSTRUCTED struct (not the
;; exact input), so Memory ≡ PostgreSQL roundtrips exactly.  The alias name
;; also fixes the field's denominator DIMENSION; both write and read verify
;; the label's dimension against it fail-closed (a per-"kg" label in a
;; MoneyPerDuration column is corrupt data, not a unit conversion).
;;
;; NOTE — equality is REPRESENTATIONAL: `==`/`!=` compare the stored
;; (minor, currency, per) triple, so a price stored as 950/h does NOT match
;; the same price stored per "day"; normalize to one label before comparing.

(define (money-rate-type-datum? type-datum)
  (and (hash-ref rate-alias-dim-table (type-datum-name type-datum) #f) #t))

(define (money-rate-field? field)
  (money-rate-type-datum? (field-spec-type field)))

;; `Maybe MoneyRate` would need NULL semantics spanning all THREE columns;
;; fail closed until that is designed (mirrors maybe-money-field?).
(define (maybe-money-rate-field? field)
  (define inner (maybe-field-inner-type (field-spec-type field)))
  (and inner (money-rate-type-datum? inner) #t))

(define (money-rate-related-field? field)
  (or (money-rate-field? field) (maybe-money-rate-field? field)))

;; The FIELD's declared denominator dimension ('duration for MoneyPerDuration,
;; 'mass for MoneyPerMass, …) — what the boundary verifies labels against.
(define (rate-field-expected-dim field)
  (define datum (field-spec-type field))
  (hash-ref rate-alias-dim-table
            (type-datum-name (or (maybe-field-inner-type datum) datum))
            #f))

(define (money-rate-minor-column-string field who)
  (format "~a_minor" (identifier-value->string (field-column-name field) who)))

(define (money-rate-currency-column-string field who)
  (format "~a_currency" (identifier-value->string (field-column-name field) who)))

(define (money-rate-per-column-string field who)
  (format "~a_per" (identifier-value->string (field-column-name field) who)))

(define (money-rate-column-strings field who)
  (list (money-rate-minor-column-string field who)
        (money-rate-currency-column-string field who)
        (money-rate-per-column-string field who)))

;; The MoneyRate variants sql.rkt does NOT support (fail-closed, clear
;; message): Maybe MoneyRate, MoneyRate primary keys, #:db-type overrides.
(define (reject-unsupported-money-rate-field! field who)
  (when (maybe-money-rate-field? field)
    (raise-user-error who
                      "field ~a on entity ~a: Maybe MoneyRate fields are not supported yet (NULL semantics across the three MoneyRate columns are undefined)"
                      (field-spec-key field)
                      (field-spec-entity field)))
  (when (field-spec-primary-key? field)
    (raise-user-error who
                      "field ~a on entity ~a: a MoneyRate field cannot be the primary key"
                      (field-spec-key field)
                      (field-spec-entity field)))
  (when (field-spec-db-type field)
    (raise-user-error who
                      "field ~a on entity ~a: MoneyRate fields manage their own three-column storage (~a BIGINT + ~a TEXT + ~a TEXT); remove #:db-type"
                      (field-spec-key field)
                      (field-spec-entity field)
                      (money-rate-minor-column-string field who)
                      (money-rate-currency-column-string field who)
                      (money-rate-per-column-string field who))))

;; Reject a non-MoneyRate value bound for a MoneyRate field with a clear error.
(define (ensure-money-rate-value field value who)
  (define raw (normalize-row-value value))
  (unless (tesl-money-rate? raw)
    (raise-user-error who
                      "field ~a on entity ~a is a MoneyRate field and needs a MoneyRate value (e.g. (MoneyRate.perHour money)), got ~e"
                      (field-spec-key field)
                      (field-spec-entity field)
                      value))
  raw)

;; of-boundary with the FIELD's declared dimension, re-raised with field
;; context — the ONE reconstruction/validation judgment both the write path
;; (quantize-then-reconstruct) and the read path (three stored columns) use,
;; so unknown code/label and dimension mismatch fail closed with the same
;; error on both backends.
(define (money-rate-of-boundary/field field minor code label who)
  (with-handlers ([exn:fail:user?
                   (lambda (e)
                     (raise-user-error who
                                       "field ~a on entity ~a: ~a"
                                       (field-spec-key field)
                                       (field-spec-entity field)
                                       (exn-message e)))])
    (tesl-money-rate-of-boundary minor code label (rate-field-expected-dim field))))

;; The write boundary: ensure struct → quantize (ONE half-even rounding) →
;; reconstruct-and-validate.  Returns the three ordered params (the PG shape)
;; AND the reconstructed struct (the Memory store value), so both backends
;; persist the identical quantized value.
(define (money-rate-boundary field value who)
  (define rate (ensure-money-rate-value field value who))
  (define-values (minor code label) (tesl-money-rate-quantize rate))
  (values minor code label
          (money-rate-of-boundary/field field minor code label who)))

;; Decode the three stored columns back into ONE tesl-money-rate (fail-closed
;; on a malformed minor value, an unknown currency code or unit label, or a
;; label whose dimension contradicts the field's declared alias).
(define (money-rate-db-values->runtime-value field minor code label [who 'sql])
  (define n
    (cond
      [(exact-integer? minor) minor]
      [(and (rational? minor)
            (exact-integer? (inexact->exact minor)))
       (inexact->exact minor)]
      [else #f]))
  (unless (exact-integer? n)
    (raise-user-error who
                      "field ~a on entity ~a: stored rate minor-units value ~e is not an integer — the ~a column holds corrupt data"
                      (field-spec-key field)
                      (field-spec-entity field)
                      minor
                      (money-rate-minor-column-string field who)))
  (unless (string? label)
    (raise-user-error who
                      "field ~a on entity ~a: stored rate unit label ~e is not a string — the ~a column holds corrupt data"
                      (field-spec-key field)
                      (field-spec-entity field)
                      label
                      (money-rate-per-column-string field who)))
  (money-rate-of-boundary/field field n code label who))

(define (normalize-row-source source)
  (define value (if (procedure? source) (source) source))
  (cond
    [(hash? value) (hash-values value)]
    [(list? value) value]
    [(vector? value) (vector->list value)]
    [else
     (raise-user-error 'sql "expected entity source to yield a hash, list, or vector of rows, got ~a" value)]))

(define (row-field-ref row field [default #f])
  (define unwrapped (raw-value row))
  (unless (hash? unwrapped)
    (raise-user-error 'sql "expected a hash row, got ~a" row))
  (define key (field-spec-key field))
  (cond
    [(hash-has-key? unwrapped key) (hash-ref unwrapped key)]
    [(hash-has-key? unwrapped (symbol->string key)) (hash-ref unwrapped (symbol->string key))]
    [else default]))

(define (operand-name+value operand)
  (cond
    [(named-value? operand)
     (values (named-value-name operand)
             (named-value-value operand)
             (named-value-bindings operand))]
    [(check-ok? operand)
     ;; Codec via-check results: unwrap to raw value + facts
     (values #f (check-ok-value operand) (check-ok-bindings operand))]
    [(and (symbol? operand)
          (hash-has-key? (current-proof-env) operand))
     (values operand
             (hash-ref (current-proof-env) operand)
             (hash operand (hash-ref (current-proof-env) operand)))]
    [else
     (values #f operand (hash))]))

(define (merge-binding-tables left right)
  (for/fold ([acc left]) ([(key value) (in-hash right)])
    (hash-set acc key value)))

(define (entity-row-matches-fields? fields value)
  (and
   (hash? value)
   (for/and ([field (in-list fields)])
     (let* ([present?
             (or (hash-has-key? value (field-spec-key field))
                 (hash-has-key? value (symbol->string (field-spec-key field))))]
            [field-input (and present? (row-field-ref value field))]
            [field-value (and present?
                              (let-values ([(_name raw-value _bindings)
                                            (operand-name+value field-input)])
                                raw-value))])
       (and present?
            (or
             ;; Money/MoneyRate fields match BY NAME (the structs may not be
             ;; registered as runtime types in this process).
             (and (money-field? field) (tesl-money? field-value))
             (and (money-rate-field? field) (tesl-money-rate? field-value))
             ;; Nullable fields accept Nothing or a typed Something
             (and (field-spec-nullable? field)
                  (or (Nothing? field-value)
                      (and (Something? field-value)
                           (runtime-type-satisfied?
                            (cadr (field-spec-type field))
                            (Something-value field-value)))))
             (runtime-type-satisfied? (field-spec-type field) field-value)))))))

(define (normalize-row-value value)
  (cond
    [(named-value? value) (raw-value value)]
    [else value]))

(define (resolve-field-value field input who)
  (define-values (operand-name raw-value operand-bindings)
    (operand-name+value input))
  (define field-type (field-spec-type field))
  (define inner-maybe (maybe-field-inner-type field-type))
  (define coerced-value
    (cond
      ;; Money field: matched BY NAME (like PosixMillis) so validation works
      ;; whether or not `Money` is registered as a runtime type, and a clear
      ;; Money-specific error beats the generic type mismatch.  Maybe Money is
      ;; rejected fail-closed inside the guard.
      [(money-related-field? field)
       (reject-unsupported-money-field! field who)
       (ensure-money-value field raw-value who)]
      ;; MoneyRate field: persistence is a BOUNDARY, so the coerced value is
      ;; the QUANTIZED-then-reconstructed struct (one half-even rounding) —
      ;; the Memory backend stores it and Memory `==`/`!=` compare it with
      ;; `equal?`, which is therefore the same REPRESENTATIONAL
      ;; (minor, currency, per) triple equality the PG columns implement.
      [(money-rate-related-field? field)
       (reject-unsupported-money-rate-field! field who)
       (let-values ([(_minor _code _label reconstructed)
                     (money-rate-boundary field raw-value who)])
         reconstructed)]
      ;; Nullable (Maybe T) field: accept Nothing, Something(v), or a plain inner value
      [inner-maybe
       (cond
         [(Nothing? raw-value)   raw-value]
         [(Something? raw-value) raw-value]
         ;; Auto-wrap a plain inner value as Something(v) so code can pass
         ;; a raw String where Maybe String is declared.
         [(runtime-type-satisfied? inner-maybe raw-value) (Something raw-value)]
         [else
          (raise-user-error who
                            "expected Nothing or Something for nullable field ~a on entity ~a (type ~a), got ~a"
                            (field-spec-key field)
                            (field-spec-entity field)
                            (type-datum-display field-type)
                            input)])]
      [(runtime-type-satisfied? field-type raw-value)
       raw-value]
      ;; Auto-coerce: if field type is a newtype and the raw value satisfies
      ;; the newtype's base type, wrap it automatically.  This allows Tesl
      ;; code to insert rows with plain primitive values (e.g. id: "mikael")
      ;; even when the field declares a newtype wrapper (e.g. id: UserId).
      [(let ([base (hash-ref newtype-registry field-type #f)])
         (and base (runtime-type-satisfied? base raw-value)))
       => (lambda (_)
            (jsexpr->typed-value field-type raw-value who))]
      [else
       (raise-user-error who
                         "expected a value satisfying field ~a on entity ~a to match type ~a, got ~a"
                         (field-spec-key field)
                         (field-spec-entity field)
                         (type-datum-display field-type)
                         input)]))
  (values operand-name coerced-value operand-bindings))

(define (normalize-entity-row entity value who)
  (define row (normalize-row-value value))
  (unless (hash? row)
    (raise-user-error who
                      "expected a row matching entity ~a, got ~a"
                      (entity-spec-name entity)
                      value))
  (define merged-bindings (hash))
  (define primary-key-name #f)
  (define normalized-row
    (for/hash ([field (in-list (entity-spec-fields entity))])
      (define input (row-field-ref row field '#:missing))
      (when (eq? input '#:missing)
        (raise-user-error who
                          "row for entity ~a is missing field ~a"
                          (entity-spec-name entity)
                          (field-spec-key field)))
      (define-values (operand-name raw-value operand-bindings)
        (resolve-field-value field input who))
      (when operand-name
        (set! merged-bindings (merge-binding-tables merged-bindings operand-bindings)))
      (when (and operand-name (field-spec-primary-key? field))
        (set! primary-key-name operand-name))
      (values (field-spec-key field) raw-value)))
  (values normalized-row primary-key-name merged-bindings))

(define (entity-primary-key-field entity)
  (or (for/first ([field (in-list (entity-spec-fields entity))]
                  #:when (field-spec-primary-key? field))
        field)
      (raise-user-error 'sql "entity ~a is missing a primary-key field" (entity-spec-name entity))))

;; Look up a field-spec from an entity-spec by its key symbol.
;; Used by generated WHERE/ORDER BY/SET clauses so that only the entity-spec
;; (not the individual field accessor functions) needs to be imported across
;; module boundaries.  E.g. (entity-field-ref KanelUser 'id) replaces (KanelUser-id).
(define (entity-field-ref entity field-key)
  (or (for/first ([field (in-list (entity-spec-fields entity))]
                  #:when (eq? (field-spec-key field) field-key))
        field)
      (raise-user-error 'entity-field-ref
                        "entity ~a has no field ~a"
                        (entity-spec-name entity)
                        field-key)))

(define (entity-primary-key-value entity row who)
  (define primary-key-field (entity-primary-key-field entity))
  (define value (row-field-ref row primary-key-field '#:missing))
  (when (eq? value '#:missing)
    (raise-user-error who
                      "row for entity ~a is missing the primary key field ~a"
                      (entity-spec-name entity)
                      (field-spec-key primary-key-field)))
  value)

(define ordered-comparison-operators '(< <= > >=))

(define (ordered-comparison-operator? operator)
  (member operator ordered-comparison-operators))

(define (query-predicate? value)
  (or (eq-predicate? value)
      (comparison-predicate? value)
      (or-predicate? value)
      (null-predicate? value)
      (not-null-predicate? value)
      (in-predicate? value)
      (not-in-predicate? value)
      (like-predicate? value)
      (ilike-predicate? value)))

(define (ensure-ordered-query-value! field value who operator role)
  ;; A NULL (Nothing / sql-null) is a legitimate ordered-comparison input: SQL 3VL
  ;; makes `col <op> NULL` (and an ordered comparison against a NULL column) UNKNOWN,
  ;; which the caller turns into "row excluded" — it is NOT a malformed value. Unwrap
  ;; a `Something(v)` (a non-NULL Maybe-field value) so the underlying number/string is
  ;; what gets range-checked; this also matches the Postgres path, where the operand is
  ;; unwrapped to its inner value before binding. Anything else (an ADT, a list, …) is
  ;; genuinely non-orderable and still errors.
  (unless (or (sql-null-value? value)
              (let ([inner (unwrap-non-null value)])
                (or (number? inner) (string? inner) (boolean? inner))))
    (raise-user-error who
                      "field ~a on entity ~a does not support ordered comparison ~a for ~a value ~a; expected a string, number or boolean"
                      (field-spec-key field)
                      (field-spec-entity field)
                      operator
                      role
                      value)))

(define (resolve-query-operand field operand who operator)
  (define-values (operand-name raw-value operand-bindings)
    (resolve-field-value field operand who))
  (when (ordered-comparison-operator? operator)
    (ensure-ordered-query-value! field raw-value who operator 'operand))
  (values operand-name raw-value operand-bindings))

(define (ordered-comparison-result field operator left right who)
  (ensure-ordered-query-value! field left who operator 'row)
  (cond
    [(and (number? left) (number? right))
     (case operator
       [(<) (< left right)]
       [(<=) (<= left right)]
       [(>) (> left right)]
       [(>=) (>= left right)]
       [else
        (raise-user-error who "unsupported ordered SQL predicate operator ~a" operator)])]
    [(and (string? left) (string? right))
     (case operator
       [(<) (string<? left right)]
       [(<=) (or (string<? left right) (string=? left right))]
       [(>) (string>? left right)]
       [(>=) (or (string>? left right) (string=? left right))]
       [else
        (raise-user-error who "unsupported ordered SQL predicate operator ~a" operator)])]
    ;; Bool ordering, PostgreSQL semantics: false < true.  PG orders boolean
    ;; columns (ORDER BY and ordered comparisons alike); before this arm the
    ;; Memory backend raised on `order t.done asc` over a Bool column that the
    ;; checker accepts and PG handles (2026-07-09 review, item 6).
    [(and (boolean? left) (boolean? right))
     (case operator
       [(<) (and (not left) right)]
       [(<=) (or (not left) right)]
       [(>) (and left (not right))]
       [(>=) (or left (not right))]
       [else
        (raise-user-error who "unsupported ordered SQL predicate operator ~a" operator)])]
    [else
     (raise-user-error who
                       "field ~a on entity ~a cannot compare row value ~a against operand ~a with operator ~a"
                       (field-spec-key field)
                       (field-spec-entity field)
                       left
                       right
                       operator)]))

;; --- In-memory backend NULL semantics: match PostgreSQL three-valued logic (3VL) ---
;;
;; In SQL a comparison with a NULL operand yields UNKNOWN, and a WHERE row is kept
;; only when its predicate is TRUE — UNKNOWN (like FALSE) excludes the row. Concretely
;; `col = x`, `col <> x`, `col < x`, `col IN (…)`, `col NOT IN (…)` are ALL UNKNOWN
;; (row excluded) when `col` (or the operand) is NULL — even `NULL = NULL`. Only the
;; explicit `IS NULL` / `IS NOT NULL` tests inspect NULL-ness and yield TRUE/FALSE.
;;
;; In the in-memory backend a SQL NULL is a `Nothing` (Maybe field) or `sql-null`.
;; Before these helpers, `equal?`/`<`/`member` compared NULLs directly, so the test
;; backend diverged from Postgres: `col <> x` and `NOT IN` matched NULL rows that
;; Postgres excludes, `NULL = NULL` matched, and ordered comparisons on a Maybe field
;; raised an error instead of excluding the row. These helpers close that gap so tests
;; on the in-memory backend are faithful to production Postgres.
(define (sql-null-value? v)
  (or (Nothing? v) (sql-null? v)))

;; Unwrap a `Something(v)` (a non-NULL Maybe-field value) AND a `newtype-value`
;; (e.g. PosixMillis over Int) to the underlying comparable base, so a query
;; operand/row-value can be matched against a bare value.  Leaves plain values
;; untouched.  GitHub #28: without the newtype strip, an ordered comparison
;; (`>= / <= / < / >`) on a newtype column/operand (PosixMillis, a Sku newtype,
;; …) reached `ensure-ordered-query-value!` still wrapped and raised "does not
;; support ordered comparison … expected a string or number" — while `==`
;; (eq-predicate, which skips the ordered check and compares via `equal?`)
;; happened to work, matching the reported ==-works / >=-traps behaviour.
(define (unwrap-non-null v)
  (cond
    [(Something? v) (unwrap-non-null (Something-value v))]
    [(newtype-value? v) (newtype-value-value v)]
    [else v]))

(define (predicate-matches-row? predicate row)
  (match predicate
    [(eq-predicate field operand)
     (define-values (_name operand-value _bindings)
       (resolve-query-operand field operand 'sql '==))
     (define row-value (row-field-ref row field))
     ;; 3VL: `col = x` is UNKNOWN (row excluded) if either side is NULL — incl. NULL = NULL.
     (and (not (sql-null-value? row-value))
          (not (sql-null-value? operand-value))
          (equal? (unwrap-non-null row-value) (unwrap-non-null operand-value)))]
    [(comparison-predicate field operator operand)
     ;; Belt-and-braces (constructors already reject): the Memory backend
     ;; refuses ordered Money comparison with the SAME error as PostgreSQL.
     (when (ordered-comparison-operator? operator)
       (reject-money-ordered-comparison! 'sql field "ordered comparison in where clauses"))
     (define-values (_name operand-value _bindings)
       (resolve-query-operand field operand 'sql operator))
     (define row-value (row-field-ref row field))
     ;; 3VL: `col <> x` and every ordered comparison is UNKNOWN (row excluded) when
     ;; either side is NULL. Only reach the actual comparison once both are non-NULL.
     (and (not (sql-null-value? row-value))
          (not (sql-null-value? operand-value))
          (let ([lhs (unwrap-non-null row-value)]
                [rhs (unwrap-non-null operand-value)])
            (case operator
              [(!=) (not (equal? lhs rhs))]
              [else
               (ordered-comparison-result field operator lhs rhs 'sql)])))]
    [(or-predicate left right)
     (or (predicate-matches-row? left row)
         (predicate-matches-row? right row))]
    [(null-predicate field)
     ;; `IS NULL` — the one place NULL-ness yields TRUE/FALSE (never UNKNOWN).
     (sql-null-value? (row-field-ref row field))]
    [(not-null-predicate field)
     (not (sql-null-value? (row-field-ref row field)))]
    [(in-predicate field values)
     (define row-value (row-field-ref row field))
     ;; 3VL: `NULL IN (…)` is UNKNOWN → row excluded (Postgres never returns TRUE here).
     (and (not (sql-null-value? row-value))
          (member (unwrap-non-null row-value) (map unwrap-non-null values))
          #t)]
    [(not-in-predicate field values)
     (define row-value (row-field-ref row field))
     ;; 3VL: `NULL NOT IN (…)` is UNKNOWN → row excluded. (A NULL *inside* the value
     ;; list can also make a non-matching row UNKNOWN in Postgres; the in-memory list
     ;; is a literal set of non-NULL operands, so that finer case does not arise here.)
     (and (not (sql-null-value? row-value))
          (not (member (unwrap-non-null row-value) (map unwrap-non-null values))))]
    [(like-predicate field pattern)
     (define-values (_name pattern-value _bindings) (operand-name+value pattern))
     ;; 3VL: `NULL LIKE p` is UNKNOWN → excluded. Unwrap a Something(v) from a Maybe
     ;; String field so the underlying string is what the pattern matches against.
     (define row-value (unwrap-non-null (row-field-ref row field)))
     (and (string? row-value)
          (regexp-match? (sql-pattern->regexp pattern-value #f) row-value))]
    [(ilike-predicate field pattern)
     (define-values (_name pattern-value _bindings) (operand-name+value pattern))
     (define row-value (unwrap-non-null (row-field-ref row field)))
     (and (string? row-value)
          (regexp-match? (sql-pattern->regexp pattern-value #t) row-value))]
    [_
     (raise-user-error 'sql "unsupported SQL predicate ~a" predicate)]))

(define (predicate-facts+bindings predicate entity-subject)
  (match predicate
    [(eq-predicate field operand)
     (define-values (operand-name _operand-value operand-bindings)
       (resolve-query-operand field operand 'sql '==))
     (if operand-name
         (values (list (list 'FromDb (list (field-spec-proof-name field) '== operand-name) entity-subject))
                 operand-bindings)
         (values '() operand-bindings))]
    [(comparison-predicate _field _operator _operand)
     (values '() (hash))]
    [(or-predicate _left _right)
     (values '() (hash))]
    [_
     (values '() (hash))]))

(define (attach-row entity row [facts '()] [bindings (hash)] #:entity-subject [entity-subject #f])
  (ensure-named (entity-spec-name entity) row facts bindings #:subject entity-subject))

(define (attach-query-proofs entity row predicates)
  (define entity-subject (gensym (entity-spec-name entity)))
  (define-values (facts bindings)
    (for/fold ([acc-facts '()]
               [acc-bindings (hash)])
              ([predicate (in-list predicates)])
      (define-values (extra-facts extra-bindings)
        (predicate-facts+bindings predicate entity-subject))
      (values (append acc-facts extra-facts)
              (merge-binding-tables acc-bindings extra-bindings))))
  (attach-row entity row facts bindings #:entity-subject entity-subject))

(define (attach-insert-proofs entity row primary-key-name bindings)
  (define entity-subject (gensym (entity-spec-name entity)))
  (define pk-proof-name (field-spec-proof-name (entity-primary-key-field entity)))
  (define facts
    (if primary-key-name
        (list (list 'FromDb (list pk-proof-name '== primary-key-name) entity-subject))
        '()))
  (attach-row entity row facts bindings #:entity-subject entity-subject))

(define (from entity)
  (unless (entity-spec? entity)
    (raise-user-error 'from "expected an entity-spec, got ~a" entity))
  (from-clause entity))

(define (where predicate)
  (unless (query-predicate? predicate)
    (raise-user-error 'where "expected a query predicate, got ~a" predicate))
  (where-clause predicate))

(define (make-comparison-predicate who operator field operand)
  (unless (field-spec? field)
    (raise-user-error who "expected a field reference, got ~a" field))
  ;; Money runtime backstop: <, <=, >, >= over a Money column are rejected on
  ;; BOTH backends at predicate-construction time (`!=` stays allowed — it is
  ;; an equality shape and lowers to the two-column expansion).
  (when (ordered-comparison-operator? operator)
    (reject-money-ordered-comparison! who field "ordered comparison in where clauses"))
  (comparison-predicate field operator operand))

(define (==. field operand)
  (unless (field-spec? field)
    (raise-user-error '==. "expected a field reference, got ~a" field))
  (eq-predicate field operand))

(define (!=. field operand)
  (make-comparison-predicate '!=. '!= field operand))

(define (<. field operand)
  (make-comparison-predicate '<. '< field operand))

(define (<=. field operand)
  (make-comparison-predicate '<=. '<= field operand))

(define (>. field operand)
  (make-comparison-predicate '>. '> field operand))

(define (>=. field operand)
  (make-comparison-predicate '>=. '>= field operand))

(define (or. left right)
  (unless (query-predicate? left)
    (raise-user-error 'or. "expected a query predicate, got ~a" left))
  (unless (query-predicate? right)
    (raise-user-error 'or. "expected a query predicate, got ~a" right))
  (or-predicate left right))

(define (order-by field direction)
  (unless (field-spec? field)
    (raise-user-error 'order-by "expected a field reference, got ~a" field))
  ;; Ordering by Money has the same cross-currency problem as ordered
  ;; comparison (and would reference a column that does not exist on PG).
  (reject-money-ordered-comparison! 'order-by field "ORDER BY")
  (unless (member direction '(asc desc))
    (raise-user-error 'order-by "direction must be 'asc or 'desc, got ~a" direction))
  (order-clause field direction))

(define (limit count)
  (unless (and (exact-integer? count) (>= count 0))
    (raise-user-error 'limit "expected a non-negative integer, got ~a" count))
  (limit-clause count))

(define (offset count)
  (unless (and (exact-integer? count) (>= count 0))
    (raise-user-error 'offset "expected a non-negative integer, got ~a" count))
  (offset-clause count))

(define (sql-pattern->regexp pattern case-insensitive?)
  (define escaped (regexp-replace* #px"[.^$*+?{}\\[\\]|()]" pattern "\\\\&"))
  (define wildcarded (string-replace (string-replace escaped "%" ".*") "_" "."))
  (if case-insensitive?
      (pregexp (string-append "(?i:^" wildcarded "$)"))
      (regexp (string-append "^" wildcarded "$"))))

(define (null?. field)
  (unless (field-spec? field)
    (raise-user-error 'null?. "expected a field reference, got ~a" field))
  (reject-money-predicate! 'null?. field "IS NULL")
  (null-predicate field))

(define (not-null?. field)
  (unless (field-spec? field)
    (raise-user-error 'not-null?. "expected a field reference, got ~a" field))
  (reject-money-predicate! 'not-null?. field "IS NOT NULL")
  (not-null-predicate field))

(define (in?. field values)
  (unless (field-spec? field)
    (raise-user-error 'in?. "expected a field reference, got ~a" field))
  (reject-money-predicate! 'in?. field "IN")
  (in-predicate field values))

(define (not-in?. field values)
  (unless (field-spec? field)
    (raise-user-error 'not-in?. "expected a field reference, got ~a" field))
  (reject-money-predicate! 'not-in?. field "NOT IN")
  (not-in-predicate field values))

(define (like?. field pattern)
  (unless (field-spec? field)
    (raise-user-error 'like?. "expected a field reference, got ~a" field))
  (reject-money-predicate! 'like?. field "LIKE")
  (like-predicate field pattern))

(define (ilike?. field pattern)
  (unless (field-spec? field)
    (raise-user-error 'ilike?. "expected a field reference, got ~a" field))
  (reject-money-predicate! 'ilike?. field "ILIKE")
  (ilike-predicate field pattern))

(define (group-by . fields)
  (for ([f (in-list fields)]
        #:when (field-spec? f))
    (when (or (money-field? f) (maybe-money-field? f))
      (raise-user-error 'group-by
                        "field ~a on entity ~a: Money cannot be a groupBy key"
                        (field-spec-key f)
                        (field-spec-entity f)))
    (when (money-rate-related-field? f)
      (raise-user-error 'group-by
                        "field ~a on entity ~a: MoneyRate cannot be a groupBy key"
                        (field-spec-key f)
                        (field-spec-entity f))))
  (group-by-clause fields))

(define (inner-join entity main-field join-field)
  (unless (entity-spec? entity)
    (raise-user-error 'inner-join "expected an entity, got ~a" entity))
  (unless (field-spec? main-field)
    (raise-user-error 'inner-join "expected a field reference for main-field, got ~a" main-field))
  (unless (field-spec? join-field)
    (raise-user-error 'inner-join "expected a field reference for join-field, got ~a" join-field))
  (inner-join-clause entity main-field join-field))

(define (query-inner-joins clauses)
  (for/list ([clause (in-list clauses)]
             #:when (inner-join-clause? clause))
    clause))

(define (query-predicates clauses)
  (for/list ([clause (in-list clauses)]
             #:when (where-clause? clause))
    (where-clause-predicate clause)))

(define (query-order clauses)
  (for/first ([clause (in-list clauses)]
              #:when (order-clause? clause))
    clause))

(define (query-limit clauses)
  (for/first ([clause (in-list clauses)]
              #:when (limit-clause? clause))
    clause))

(define (query-offset clauses)
  (for/first ([clause (in-list clauses)]
              #:when (offset-clause? clause))
    clause))

(define (query-group-by clauses)
  (for/first ([clause (in-list clauses)]
              #:when (group-by-clause? clause))
    clause))

(define (resolve-update-field entity key)
  (cond
    [(field-spec? key) key]
    [else
     (or (for/first ([candidate (in-list (entity-spec-fields entity))]
                     #:when (or (equal? (field-spec-key candidate) key)
                                (equal? (symbol->string (field-spec-key candidate)) key)
                                (equal? (field-column-name candidate) key)
                                (equal? (symbol->string (field-column-name candidate)) key)))
           candidate)
         (raise-user-error 'update-many!
                           "unknown field update target ~a for entity ~a"
                           key
                           (entity-spec-name entity)))]))

(define (normalize-update-spec entity updates)
  (unless (hash? updates)
    (raise-user-error 'update-many! "expected a hash of field updates, got ~a" updates))
  (define pairs
    (for/list ([(key value) (in-hash updates)])
      (define field (resolve-update-field entity key))
      (define-values (_name raw-value _bindings)
        (resolve-field-value field value 'update-many!))
      (cons field raw-value)))
  (when (null? pairs)
    (raise-user-error 'update-many! "expected at least one field update"))
  (for ([pair (in-list pairs)])
    (when (field-spec-primary-key? (car pair))
      (raise-user-error 'update-many! "updating primary keys is not supported yet")))
  pairs)

(define (entity-write-store entity who)
  (define source (entity-spec-source entity))
  (unless source
    (raise-user-error who
                      "entity ~a has no in-memory #:source and no matching database runtime"
                      (entity-spec-name entity)))
  (define store (if (procedure? source) (source) source))
  (unless (and (hash? store) (not (immutable? store)))
    (raise-user-error who
                      "entity ~a needs a mutable hash source for write operations, got ~a"
                      (entity-spec-name entity)
                      store))
  store)

(define (entity-read-source entity who)
  (define source (entity-spec-source entity))
  (unless source
    (raise-user-error who
                      "entity ~a has no in-memory #:source and no matching database runtime"
                      (entity-spec-name entity)))
  source)

(define (database-runtime-for-entity entity)
  (define runtime (current-database-runtime))
  (and (database-runtime? runtime)
       ;; Memory-backend databases use in-memory entity stores, not a real connection.
       (not (eq? (database-spec-backend (database-runtime-database runtime)) 'memory))
       (for/or ([managed-entity (in-list (database-spec-entities (database-runtime-database runtime)))])
         (eq? (entity-spec-name managed-entity)
              (entity-spec-name entity)))
       runtime))

(define (in-memory-select-many entity predicates)
  (for/list ([row (in-list (normalize-row-source (entity-read-source entity 'select-many)))]
             #:when (andmap (lambda (predicate)
                              (predicate-matches-row? predicate row))
                            predicates))
    (attach-query-proofs entity row predicates)))

;; ORDER BY on the Memory backend — parity with postgres-select-many, which
;; passes the order clause through to SQL.  Before this helper the in-memory
;; branch silently IGNORED `order p.field asc/desc` and returned rows in hash
;; order (silent wrong values).  Semantics mirror PostgreSQL:
;;   - stable sort (`sort` is stable) by the single order-clause field;
;;   - ASC places NULLs last, DESC places NULLs first (PG defaults);
;;   - newtype-wrapped values (PosixMillis, user newtypes — the GitHub #28
;;     class) and Something(v) Maybe values compare by their unwrapped base;
;;   - non-orderable values raise the same error as where-clause ordered
;;     comparisons (via ordered-comparison-result).
(define (in-memory-order-rows rows order)
  (if (not order)
      rows
      (let* ([field (order-clause-field order)]
             [asc?  (eq? (order-clause-direction order) 'asc)])
        (sort rows
              (lambda (a b)
                (define va (row-field-ref a field))
                (define vb (row-field-ref b field))
                (cond
                  ;; NULL placement: PG default is NULLS LAST for ASC,
                  ;; NULLS FIRST for DESC.  Two NULLs keep original order.
                  [(and (sql-null-value? va) (sql-null-value? vb)) #f]
                  [(sql-null-value? va) (not asc?)]
                  [(sql-null-value? vb) asc?]
                  [else
                   (let ([ua (unwrap-non-null va)]
                         [ub (unwrap-non-null vb)])
                     (if asc?
                         (ordered-comparison-result field '< ua ub 'order-by)
                         (ordered-comparison-result field '< ub ua 'order-by)))]))))))

;; Returns #t if the given row satisfies an inner join constraint.
;; We look up all rows in the join entity's in-memory store and check
;; whether any row has join-field equal to main-row's main-field value.
(define (in-memory-inner-join-matches? join-clause main-row)
  (define join-entity (inner-join-clause-entity join-clause))
  (define main-field (inner-join-clause-main-field join-clause))
  (define join-field (inner-join-clause-join-field join-clause))
  ;; main-row is a named-value from in-memory-select-many — unwrap to raw hash
  (define raw-main-row (raw-value main-row))
  (define main-val (hash-ref raw-main-row (field-spec-key main-field) #f))
  (define join-rows (normalize-row-source (entity-read-source join-entity 'select-many)))
  (for/or ([join-row (in-list join-rows)])
    (equal? (hash-ref join-row (field-spec-key join-field) #f) main-val)))

(define (in-memory-insert-one! entity value)
  (define-values (row primary-key-name bindings)
    (normalize-entity-row entity value 'insert-one!))
  (define store (entity-write-store entity 'insert-one!))
  (define primary-key-value (entity-primary-key-value entity row 'insert-one!))
  (when (hash-has-key? store primary-key-value)
    (raise-user-error 'insert-one!
                      "entity ~a already contains a row with primary key ~a"
                      (entity-spec-name entity)
                      primary-key-value))
  (hash-set! store primary-key-value row)
  (attach-insert-proofs entity row primary-key-name bindings))

(define (in-memory-upsert-one! entity value conflict-fields update-fields)
  ;; In-memory upsert: find existing row by conflict fields; if found update
  ;; the update-fields, otherwise insert the row.
  (define-values (row primary-key-name bindings)
    (normalize-entity-row entity value 'upsert-one!))
  (define store (entity-write-store entity 'upsert-one!))
  ;; Resolve field-spec objects for conflict/update field names
  (define (find-field fname)
    (for/first ([f (in-list (entity-spec-fields entity))]
                #:when (equal? (symbol->string (field-spec-key f)) fname))
      f))
  (define conflict-specs (filter-map find-field conflict-fields))
  ;; Find existing row that matches all conflict field values
  (define existing-key
    (for/first ([(key existing-row) (in-hash store)]
                #:when (for/and ([fspec (in-list conflict-specs)])
                         (equal? (hash-ref existing-row (field-spec-key fspec) #f)
                                 (hash-ref row (field-spec-key fspec) #f))))
      key))
  (if existing-key
      ;; Update: merge update-fields from new row into existing row
      (let* ([update-specs (filter-map find-field update-fields)]
             [updated-row
              (for/fold ([current (hash-ref store existing-key)])
                        ([fspec (in-list update-specs)])
                (hash-set current (field-spec-key fspec)
                          (hash-ref row (field-spec-key fspec))))])
        (hash-set! store existing-key updated-row)
        (attach-insert-proofs entity updated-row primary-key-name bindings))
      ;; Insert new row
      (let ([pk-value (entity-primary-key-value entity row 'upsert-one!)])
        (hash-set! store pk-value row)
        (attach-insert-proofs entity row primary-key-name bindings))))

(define (in-memory-update-many! entity updates predicates)
  (define update-pairs (normalize-update-spec entity updates))
  (define store (entity-write-store entity 'update-many!))
  (for/list ([(store-key row) (in-hash store)]
             #:when (andmap (lambda (predicate)
                              (predicate-matches-row? predicate row))
                            predicates))
    (define updated-row
      (for/fold ([current row]) ([pair (in-list update-pairs)])
        (hash-set current (field-spec-key (car pair)) (cdr pair))))
    (hash-set! store store-key updated-row)
    (attach-query-proofs entity updated-row predicates)))

(define (in-memory-delete-many! entity predicates)
  (define store (entity-write-store entity 'delete-many!))
  (for ([store-key (in-list (for/list ([(key row) (in-hash store)]
                                       #:when (andmap (lambda (predicate)
                                                        (predicate-matches-row? predicate row))
                                                      predicates))
                              key))])
    (hash-remove! store store-key))
  (void))

(define (in-memory-delete-many-with-count! entity predicates)
  (define store (entity-write-store entity 'delete-many-with-count!))
  (define keys-to-remove
    (for/list ([(key row) (in-hash store)]
               #:when (andmap (lambda (predicate) (predicate-matches-row? predicate row))
                              predicates))
      key))
  (for ([store-key (in-list keys-to-remove)])
    (hash-remove! store store-key))
  (define count (length keys-to-remove))
  (if (= count 0)
      NoRowDeleted
      (RowsDeleted count)))

(define (postgres-placeholder index)
  (format "$~a" index))

(define (comparison-operator->sql operator)
  (case operator
    [(==) "="]
    [(!=) "<>"]
    [(<) "<"]
    [(<=) "<="]
    [(>) ">"]
    [(>=) ">="]
    [else
     (raise-user-error 'sql "unsupported SQL predicate operator ~a" operator)]))

;; Money predicate lowering: `price == m` expands over BOTH columns —
;;   (price_minor = $n AND price_currency = $m)
;; and `price != m` to its negation shape
;;   (price_minor <> $n OR price_currency <> $m)
;; parenthesized so the fragments compose under the surrounding AND/OR.
(define (compile-money-equality-sql field operator money index)
  (define minor-col (quote-sql-identifier (money-minor-column-string field 'sql) 'sql))
  (define currency-col (quote-sql-identifier (money-currency-column-string field 'sql) 'sql))
  (define-values (op joiner)
    (if (eq? operator '==) (values "=" "AND") (values "<>" "OR")))
  (values (format "(~a ~a ~a ~a ~a ~a ~a)"
                  minor-col op (postgres-placeholder index)
                  joiner
                  currency-col op (postgres-placeholder (add1 index)))
          (list (tesl-money-minor-units money)
                (tesl-currency-code (tesl-money-currency money)))
          (+ index 2)))

;; MoneyRate predicate lowering: `hourly == r` expands over ALL THREE columns —
;;   (hourly_minor = $n AND hourly_currency = $n+1 AND hourly_per = $n+2)
;; and `hourly != r` to its negation shape (<> joined by OR), parenthesized so
;; the fragments compose under the surrounding AND/OR.  The operand is
;; quantized through the SAME write boundary as INSERT (one half-even
;; rounding + dimension check).  NOTE: this equality is REPRESENTATIONAL —
;; it compares the stored triple, so 950/h stored per "h" does NOT match the
;; same price stored per "day"; the Memory backend's `equal?` on the
;; reconstructed struct agrees exactly.
(define (compile-money-rate-equality-sql field operator value index)
  (define-values (minor code label _reconstructed)
    (money-rate-boundary field value 'sql))
  (define-values (op joiner)
    (if (eq? operator '==) (values "=" "AND") (values "<>" "OR")))
  (define fragments
    (for/list ([col (in-list (money-rate-column-strings field 'sql))]
               [i (in-naturals index)])
      (format "~a ~a ~a"
              (quote-sql-identifier col 'sql) op (postgres-placeholder i))))
  (values (format "(~a)" (string-join fragments (format " ~a " joiner)))
          (list minor code label)
          (+ index 3)))

(define (compile-predicate-sql predicate index)
  (match predicate
    [(eq-predicate field operand)
     (define-values (_name operand-value _bindings)
       (resolve-query-operand field operand 'sql '==))
     (cond
       [(money-field? field)
        (compile-money-equality-sql field '==
                                    (ensure-money-value field operand-value 'sql)
                                    index)]
       [(money-rate-field? field)
        (compile-money-rate-equality-sql field '== operand-value index)]
       [else
        (define encoded-value
          (field-runtime-value->db-value field operand-value 'sql))
        (values (format "~a ~a ~a"
                        (quote-sql-identifier (field-column-name field) 'sql)
                        (comparison-operator->sql '==)
                        (postgres-placeholder index))
                (list encoded-value)
                (add1 index))])]
    [(comparison-predicate field operator operand)
     ;; Belt-and-braces: the `<.`/`<=.`/`>.`/`>=.` constructors already reject
     ;; Money, but a directly constructed predicate must not slip through.
     (when (ordered-comparison-operator? operator)
       (reject-money-ordered-comparison! 'sql field "ordered comparison in where clauses"))
     (define-values (_name operand-value _bindings)
       (resolve-query-operand field operand 'sql operator))
     (cond
       [(money-field? field)
        ;; Only `!=` reaches here for Money (ordered rejected above).
        (compile-money-equality-sql field operator
                                    (ensure-money-value field operand-value 'sql)
                                    index)]
       [(money-rate-field? field)
        ;; Only `!=` reaches here for MoneyRate (ordered rejected above).
        (compile-money-rate-equality-sql field operator operand-value index)]
       [else
        (define encoded-value
          (field-runtime-value->db-value field operand-value 'sql))
        (values (format "~a ~a ~a"
                        (quote-sql-identifier (field-column-name field) 'sql)
                        (comparison-operator->sql operator)
                        (postgres-placeholder index))
                (list encoded-value)
                (add1 index))])]
    [(or-predicate left right)
     (define-values (sql-left params-left idx-left)
       (compile-predicate-sql left index))
     (define-values (sql-right params-right idx-right)
       (compile-predicate-sql right idx-left))
     (values (format "(~a OR ~a)" sql-left sql-right)
             (append params-left params-right)
             idx-right)]
    [(null-predicate field)
     (values (format "~a IS NULL" (quote-sql-identifier (field-column-name field) 'sql))
             '()
             index)]
    [(not-null-predicate field)
     (values (format "~a IS NOT NULL" (quote-sql-identifier (field-column-name field) 'sql))
             '()
             index)]
    [(in-predicate field vals)
     (define encoded-values
       (map (lambda (v) (field-runtime-value->db-value field v 'sql)) vals))
     (define placeholders
       (for/list ([_ (in-list vals)]
                  [i (in-range index (+ index (length vals)))])
         (postgres-placeholder i)))
     (values (format "~a IN (~a)"
                     (quote-sql-identifier (field-column-name field) 'sql)
                     (string-join placeholders ", "))
             encoded-values
             (+ index (length vals)))]
    [(not-in-predicate field vals)
     (define encoded-values
       (map (lambda (v) (field-runtime-value->db-value field v 'sql)) vals))
     (define placeholders
       (for/list ([_ (in-list vals)]
                  [i (in-range index (+ index (length vals)))])
         (postgres-placeholder i)))
     (values (format "~a NOT IN (~a)"
                     (quote-sql-identifier (field-column-name field) 'sql)
                     (string-join placeholders ", "))
             encoded-values
             (+ index (length vals)))]
    [(like-predicate field pattern)
     (define-values (_name pattern-value _bindings) (operand-name+value pattern))
     (values (format "~a LIKE ~a"
                     (quote-sql-identifier (field-column-name field) 'sql)
                     (postgres-placeholder index))
             (list pattern-value)
             (add1 index))]
    [(ilike-predicate field pattern)
     (define-values (_name pattern-value _bindings) (operand-name+value pattern))
     (values (format "~a ILIKE ~a"
                     (quote-sql-identifier (field-column-name field) 'sql)
                     (postgres-placeholder index))
             (list pattern-value)
             (add1 index))]
    [_
     (raise-user-error 'sql "unsupported SQL predicate ~a" predicate)]))

(define (compile-where-sql predicates [start-index 1])
  (define fragments '())
  (define params '())
  (define next-index start-index)
  (for ([predicate (in-list predicates)])
    (define-values (fragment fragment-params advanced-index)
      (compile-predicate-sql predicate next-index))
    (set! fragments (append fragments (list fragment)))
    (set! params (append params fragment-params))
    (set! next-index advanced-index))
  (values (if (null? fragments)
              ""
              (string-append " WHERE " (string-join fragments " AND ")))
          params
          next-index))

(define (entity-select-column-sql entity)
  (string-join
   (append-map field-select-column-sql-list (entity-spec-fields entity))
   ", "))

(define (field-db-value->runtime-value field value)
  ;; Handle nullable (Maybe X) fields: SQL NULL → Nothing, value → Something(inner-value)
  (define inner-maybe (maybe-field-inner-type (field-spec-type field)))
  (if inner-maybe
      (if (sql-null? value)
          Nothing
          ;; Construct a synthetic inner-field to reuse the existing conversion logic
          (let ([inner-field (field-spec (field-spec-entity field)
                                         (field-spec-proof-name field)
                                         (field-spec-key field)
                                         inner-maybe
                                         #f
                                         (field-spec-column field)
                                         (field-spec-db-type field)
                                         #f)])
            (Something (field-db-value->runtime-value inner-field value))))
      (cond
        ;; Money decodes from TWO columns — a single-value decode is a bug in
        ;; this file (some call path missed the two-column expansion).
        [(money-field? field)
         (raise-user-error 'sql
                           "internal error: Money field ~a on entity ~a reached the single-column decoder — Money decodes from two columns (bug in dsl/sql.rkt)"
                           (field-spec-key field)
                           (field-spec-entity field))]
        ;; MoneyRate decodes from THREE columns — same internal-error backstop.
        [(money-rate-field? field)
         (raise-user-error 'sql
                           "internal error: MoneyRate field ~a on entity ~a reached the single-column decoder — MoneyRate decodes from three columns (bug in dsl/sql.rkt)"
                           (field-spec-key field)
                           (field-spec-entity field))]
        [(field-adt-type? field)
         (jsexpr->typed-value (field-spec-type field)
                              (cond
                                [(bytes? value) (bytes->jsexpr value)]
                                [(string? value) (bytes->jsexpr (string->bytes/utf-8 value))]
                                [else value])
                              'sql)]
        ;; Newtype fields (e.g. UserId = String) — wrap the raw DB value in the newtype.
        [(hash-ref newtype-registry (field-spec-type field) #f)
         (jsexpr->typed-value (field-spec-type field) value 'sql)]
        [else value])))

(define (field-runtime-value->db-value field value [who 'sql])
  ;; Handle nullable (Maybe X) fields: Nothing → sql-null, Something(v) → inner value
  (define inner-maybe (maybe-field-inner-type (field-spec-type field)))
  (if inner-maybe
      (cond
        [(Nothing? value) sql-null]
        [(Something? value)
         (let ([inner-field (field-spec (field-spec-entity field)
                                        (field-spec-proof-name field)
                                        (field-spec-key field)
                                        inner-maybe
                                        #f
                                        (field-spec-column field)
                                        (field-spec-db-type field)
                                        #f)])
           (field-runtime-value->db-value inner-field (Something-value value) who))]
        [else
         ;; Allow raw inner value to be auto-wrapped as Something
         (let ([inner-field (field-spec (field-spec-entity field)
                                        (field-spec-proof-name field)
                                        (field-spec-key field)
                                        inner-maybe
                                        #f
                                        (field-spec-column field)
                                        (field-spec-db-type field)
                                        #f)])
           (field-runtime-value->db-value inner-field value who))])
      (begin
        ;; Money encodes to TWO params — a single-value encode is a bug in
        ;; this file (use field-db-param-values, which expands Money).
        (when (money-field? field)
          (raise-user-error who
                            "internal error: Money field ~a on entity ~a reached the single-column encoder — Money expands to two params (bug in dsl/sql.rkt)"
                            (field-spec-key field)
                            (field-spec-entity field)))
        (when (money-rate-field? field)
          (raise-user-error who
                            "internal error: MoneyRate field ~a on entity ~a reached the single-column encoder — MoneyRate expands to three params (bug in dsl/sql.rkt)"
                            (field-spec-key field)
                            (field-spec-entity field)))
        (unless (runtime-type-satisfied? (field-spec-type field) value)
          (raise-user-error who
                            "expected a value satisfying field ~a on entity ~a to match type ~a, got ~a"
                            (field-spec-key field)
                            (field-spec-entity field)
                            (type-datum-display (field-spec-type field))
                            value))
        (cond
          [(field-adt-type? field)
           (bytes->string/utf-8 (jsexpr->bytes (runtime-value->jsexpr value)))]
          ;; Unwrap newtypes to their base value for storage (e.g. UserId "mikael" → "mikael")
          [(newtype-value? value) (newtype-value-value value)]
          [else value]))))

;; The ordered SQL params ONE field value expands to: (minor currency-code)
;; for a Money field, (minor currency-code per-label) for a MoneyRate field,
;; a single encoded value for everything else.
(define (field-db-param-values field value who)
  (cond
    [(money-related-field? field)
     (reject-unsupported-money-field! field who)
     (define money (ensure-money-value field value who))
     (list (tesl-money-minor-units money)
           (tesl-currency-code (tesl-money-currency money)))]
    [(money-rate-related-field? field)
     (reject-unsupported-money-rate-field! field who)
     ;; Quantize at the persistence boundary (idempotent when the value came
     ;; through resolve-field-value, which already reconstructed it).
     (define-values (minor code label _reconstructed)
       (money-rate-boundary field value who))
     (list minor code label)]
    [else
     (list (field-runtime-value->db-value field value who))]))

(define (vector->entity-row entity row-vector)
  ;; A Money field consumes TWO adjacent slots of the result vector (its two
  ;; columns are always selected together, in minor/currency order); a
  ;; MoneyRate field consumes THREE (minor/currency/per order); every other
  ;; field consumes one — so the index is threaded, not (in-naturals).
  (define-values (row _next-index)
    (for/fold ([acc (hash)]
               [index 0])
              ([field (in-list (entity-spec-fields entity))])
      (cond
        [(money-field? field)
         (values (hash-set acc
                           (field-spec-key field)
                           (money-db-values->runtime-value field
                                                           (vector-ref row-vector index)
                                                           (vector-ref row-vector (add1 index))))
                 (+ index 2))]
        [(money-rate-field? field)
         (values (hash-set acc
                           (field-spec-key field)
                           (money-rate-db-values->runtime-value field
                                                                (vector-ref row-vector index)
                                                                (vector-ref row-vector (+ index 1))
                                                                (vector-ref row-vector (+ index 2))))
                 (+ index 3))]
        [else
         (values (hash-set acc
                           (field-spec-key field)
                           (field-db-value->runtime-value field
                                                          (vector-ref row-vector index)))
                 (add1 index))])))
  row)

(define (postgres-table-exists? runtime entity)
  (define database (database-runtime-database runtime))
  (query-value (database-runtime-connection runtime)
               "select exists (
                  select 1
                    from information_schema.tables
                   where table_schema = $1 and table_name = $2
                )"
               (identifier-value->string (database-schema-name database) 'sql)
               (identifier-value->string (entity-table-name entity) 'sql)))

(define (postgres-table-empty? runtime entity)
  (zero? (query-value (database-runtime-connection runtime)
                      (format "select count(*) from ~a" (qualified-table-name (database-runtime-database runtime) entity)))))

(define (postgres-column-metadata runtime entity)
  (for/hash ([row (in-list (query-rows (database-runtime-connection runtime)
                                       "select column_name, data_type, is_nullable
                                          from information_schema.columns
                                         where table_schema = $1 and table_name = $2
                                      order by ordinal_position"
                                       (identifier-value->string (database-schema-name (database-runtime-database runtime)) 'sql)
                                       (identifier-value->string (entity-table-name entity) 'sql)))])
    (values (vector-ref row 0)
            (hash 'data-type (string-downcase (vector-ref row 1))
                  'is-nullable (vector-ref row 2)))))

(define (postgres-primary-key-columns runtime entity)
  (for/list ([row (in-list (query-rows (database-runtime-connection runtime)
                                       "select kcu.column_name
                                          from information_schema.table_constraints tc
                                          join information_schema.key_column_usage kcu
                                            on tc.constraint_name = kcu.constraint_name
                                           and tc.table_schema = kcu.table_schema
                                           and tc.table_name = kcu.table_name
                                         where tc.table_schema = $1
                                           and tc.table_name = $2
                                           and tc.constraint_type = 'PRIMARY KEY'
                                      order by kcu.ordinal_position"
                                       (identifier-value->string (database-schema-name (database-runtime-database runtime)) 'sql)
                                       (identifier-value->string (entity-table-name entity) 'sql)))])
    (vector-ref row 0)))

(define (postgres-create-table! runtime entity)
  (check-money-column-collisions! entity 'sql)
  (query-exec (database-runtime-connection runtime)
              (format "create table if not exists ~a (~a)"
                      (qualified-table-name (database-runtime-database runtime) entity)
                      (string-join
                       (append-map field-column-definitions-sql
                                   (entity-spec-fields entity))
                       ", "))))

(define (postgres-ensure-entity! runtime entity)
  (check-money-column-collisions! entity 'sql)
  (cond
    [(not (postgres-table-exists? runtime entity))
     (postgres-create-table! runtime entity)]
    [else
     (define columns (postgres-column-metadata runtime entity))
     (define empty-table? (postgres-table-empty? runtime entity))
     ;; Walk the PHYSICAL columns each field expects (a Money field expects
     ;; two: <col>_minor BIGINT NOT NULL + <col>_currency TEXT NOT NULL), so
     ;; adding a Money field to an existing table migrates by adding both.
     (for* ([field (in-list (entity-spec-fields entity))]
            [expected (in-list (field-expected-db-columns field))])
       (define column-name (expected-db-column-name expected))
       (define maybe-column (hash-ref columns column-name #f))
       (cond
         [(not maybe-column)
          (cond
            [(not empty-table?)
             (raise-user-error 'sql
                               "automatic migration cannot add required column ~a to non-empty table ~a yet"
                               column-name
                               (entity-table-name entity))]
            [(expected-db-column-primary-key? expected)
             (raise-user-error 'sql
                               "automatic migration cannot add a missing primary-key column ~a to existing table ~a yet"
                               column-name
                               (entity-table-name entity))]
            [else
             (query-exec (database-runtime-connection runtime)
                         (format "alter table ~a add column ~a"
                                 (qualified-table-name (database-runtime-database runtime) entity)
                                 (expected-db-column-definition expected)))])]
         [else
          (define actual-type (hash-ref maybe-column 'data-type))
          (define expected-type (expected-db-column-type expected))
          (cond
            [(equal? actual-type expected-type) (void)]
            ;; NT-07: `Int` columns were BIGINT and now map to NUMERIC (arbitrary
            ;; precision). BIGINT→NUMERIC (and INTEGER→NUMERIC) is a LOSSLESS
            ;; widening, so auto-migrate the existing column in place rather than
            ;; failing — this is the migration the Int→NUMERIC change needs.
            [(and (equal? expected-type "numeric")
                  (member actual-type '("bigint" "integer")))
             (query-exec (database-runtime-connection runtime)
                         (format "alter table ~a alter column ~a type numeric"
                                 (qualified-table-name (database-runtime-database runtime) entity)
                                 column-name))]
            [else
             (raise-user-error 'sql
                               "automatic migration found incompatible type for ~a.~a: expected ~a, found ~a"
                               (entity-table-name entity)
                               column-name
                               expected-type
                               actual-type)])
          ;; Nullability check: DB column must match the entity declaration.
          ;; Nullable fields (Maybe types) expect "YES"; non-nullable fields expect "NO".
          (define db-is-nullable (not (equal? (hash-ref maybe-column 'is-nullable) "NO")))
          (define entity-expects-nullable (expected-db-column-nullable? expected))
          (when (and (not (expected-db-column-primary-key? expected))
                     (not entity-expects-nullable)
                     db-is-nullable)
            (raise-user-error 'sql
                              "automatic migration found nullable column ~a.~a but the entity declaration requires NOT NULL"
                              (entity-table-name entity)
                              column-name))
          (when (and (not (expected-db-column-primary-key? expected))
                     entity-expects-nullable
                     (not db-is-nullable))
            (raise-user-error 'sql
                              "automatic migration found NOT NULL column ~a.~a but the entity declaration is nullable (Maybe type); run: ALTER TABLE ~a ALTER COLUMN ~a DROP NOT NULL"
                              (entity-table-name entity)
                              column-name
                              (entity-table-name entity)
                              column-name))]))
     (define actual-primary-keys (postgres-primary-key-columns runtime entity))
     (define expected-primary-key
       (list (identifier-value->string (field-column-name (entity-primary-key-field entity)) 'sql)))
     (unless (equal? actual-primary-keys expected-primary-key)
       (raise-user-error 'sql
                         "automatic migration found incompatible primary key for table ~a: expected ~a, found ~a"
                         (entity-table-name entity)
                         expected-primary-key
                         actual-primary-keys))]))

(define (ensure-queue-tables! conn schema-str)
  ;; tesl_jobs: durable job store for queue workers (FOR UPDATE SKIP LOCKED)
  (query-exec conn
    (format "create table if not exists ~a.~a (
               id              text         primary key,
               queue_name      text         not null,
               payload         jsonb        not null,
               status          text         not null default 'pending',
               attempts        integer      not null default 0,
               created_at      timestamptz  not null default now(),
               locked_at       timestamptz,
               next_attempt_at timestamptz
             )"
            (format "\"~a\"" schema-str)
            (format "\"~a\"" "tesl_jobs")))
  (query-exec conn
    (format "create index if not exists tesl_jobs_dequeue_idx
               on ~a.~a (queue_name, created_at)
               where status = 'pending'"
            (format "\"~a\"" schema-str)
            (format "\"~a\"" "tesl_jobs")))
  ;; tesl_pubsub_outbox: transactional pub/sub event delivery (outbox pattern)
  (query-exec conn
    (format "create table if not exists ~a.~a (
               id           bigserial    primary key,
               channel_name text         not null,
               channel_key  text         not null,
               payload      jsonb        not null,
               created_at   timestamptz  not null default now()
             )"
            (format "\"~a\"" schema-str)
            (format "\"~a\"" "tesl_pubsub_outbox")))
  ;; tesl_cache: native key-value cache (UNLOGGED for performance — no WAL overhead)
  (query-exec conn
    (format "create unlogged table if not exists ~a.~a (
               key        text         primary key,
               value      jsonb        not null,
               expires_at timestamptz
             )"
            (format "\"~a\"" schema-str)
            (format "\"~a\"" "tesl_cache")))
  ;; tesl_email_outbox: transactional email delivery (outbox pattern, logged for durability)
  (query-exec conn
    (format "create table if not exists ~a.~a (
               id              bigserial    primary key,
               to_address      text         not null,
               subject         text         not null,
               text_body       text,
               html_body       text,
               status          text         not null default 'pending',
               attempts        integer      not null default 0,
               created_at      timestamptz  not null default now(),
               next_attempt_at timestamptz,
               updated_at      timestamptz  not null default now()
             )"
            (format "\"~a\"" schema-str)
            (format "\"~a\"" "tesl_email_outbox")))
  ;; Add updated_at to existing deployments that may not have it.
  (query-exec conn
    (format "alter table ~a.~a
               add column if not exists updated_at timestamptz not null default now()"
            (format "\"~a\"" schema-str)
            (format "\"~a\"" "tesl_email_outbox"))))

(define (ensure-database-ready! runtime)
  (unless (database-runtime? runtime)
    (raise-user-error 'ensure-database-ready! "expected a database-runtime, got ~a" runtime))
  (define database (database-runtime-database runtime))
  (match (database-spec-backend database)
    ['postgres
     (call-with-transaction
      (database-runtime-connection runtime)
      (lambda ()
        (query-exec (database-runtime-connection runtime)
                    (format "create schema if not exists ~a"
                            (quote-sql-identifier (database-schema-name database) 'sql)))
        (for ([entity (in-list (database-spec-entities database))])
          (postgres-ensure-entity! runtime entity))
        (ensure-queue-tables! (database-runtime-connection runtime)
                              (database-schema-name database))))]
    [other
     (raise-user-error 'ensure-database-ready! "unsupported database backend ~a" other)])
  runtime)

;; ── SQL transparency capture (task #43) ────────────────────────────────────────
;;
;; Each postgres-* operation records the EXACT parameterized statement + ordered
;; params it is about to run (sql-capture-pending!), runs it, then records the
;; post-exec row count (sql-capture-executed!).  Both calls are DEBUG-GATED and
;; FAIL-OPEN inside domain-registry, so this is a no-op in a release run and can
;; never disturb a query.  `capture-table-name` never raises.
(define (capture-table-name entity)
  (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
    ;; entity-table-name yields a SYMBOL (the unquoted table name); stringify it so
    ;; the capture's 'table field is the string the DAP "SQL" scope expects (the
    ;; capture store keeps only string tables, so a bare symbol would otherwise
    ;; drop to #f and the scope would show the table as "(unknown)").
    (define t (entity-table-name entity))
    (cond [(string? t) t] [(symbol? t) (symbol->string t)] [else #f])))

;; Capture + run + record-count, returning the query result unchanged.  `run`
;; is a 0-arg thunk that performs the actual `apply query-*`; `count-of` maps its
;; result to the executed row count (or #f).  Capture must never alter behaviour,
;; so the result flows through untouched and only the count is derived for display.
(define (with-sql-capture sql params table op run count-of)
  (sql-capture-pending! sql params table op)
  ;; Metrics: this wrapper is the single seam every postgres-* execution flows
  ;; through, so timing (run) here yields db.client.operation.duration for the
  ;; whole SQL surface with no per-call-site changes.  Attrs stay low-cardinality
  ;; (operation kind + table name — never statement text or params).
  (define metric-start (and (metrics-active?) (current-inexact-milliseconds)))
  (define result (run))
  (when metric-start
    (metric-histogram-record!
     "db.client.operation.duration"
     (/ (- (current-inexact-milliseconds) metric-start) 1000.0)
     (list (cons "db.operation.name" (~a op))
           (cons "tesl.table" (or table "unknown")))
     #:unit "s"
     #:boundaries duration-histogram-boundaries))
  (sql-capture-executed! (count-of result))
  result)

(define (postgres-select-many runtime entity predicates [order #f] [lim #f] [off #f] [grp #f] [joins '()])
  (define-values (where-sql params _next-index)
    (compile-where-sql predicates))
  (define order-sql
    (if order
        (format " ORDER BY ~a ~a"
                (quote-sql-identifier (field-column-name (order-clause-field order)) 'sql)
                (if (eq? (order-clause-direction order) 'asc) "ASC" "DESC"))
        ""))
  (define limit-sql
    (if lim (format " LIMIT ~a" (limit-clause-count lim)) ""))
  (define offset-sql
    (if off (format " OFFSET ~a" (offset-clause-count off)) ""))
  (define group-by-sql
    (if grp
        (format " GROUP BY ~a"
                (string-join
                 (for/list ([field (in-list (group-by-clause-fields grp))])
                   (quote-sql-identifier (field-column-name field) 'sql))
                 ", "))
        ""))
  ;; Build INNER JOIN fragments for each join clause
  (define join-sql
    (string-join
     (for/list ([j (in-list joins)])
       (define join-entity (inner-join-clause-entity j))
       (define main-field (inner-join-clause-main-field j))
       (define jfield (inner-join-clause-join-field j))
       (format " INNER JOIN ~a ON ~a.~a = ~a.~a"
               (qualified-table-name (database-runtime-database runtime) join-entity)
               (quote-sql-identifier (camel->snake (symbol->string (entity-spec-name entity))) 'sql)
               (quote-sql-identifier (field-column-name main-field) 'sql)
               (quote-sql-identifier (camel->snake (symbol->string (entity-spec-name join-entity))) 'sql)
               (quote-sql-identifier (field-column-name jfield) 'sql)))
     ""))
  (define sql
    (format "select ~a from ~a~a~a~a~a~a~a"
            (entity-select-column-sql entity)
            (qualified-table-name (database-runtime-database runtime) entity)
            join-sql
            where-sql
            group-by-sql
            order-sql
            limit-sql
            offset-sql))
  (when (tesl-log-active?) (tesl-log-sql! sql params))
  (define rows
    (with-sql-capture sql params (capture-table-name entity) 'select-many
      (lambda () (apply query-rows (database-runtime-connection runtime) sql params))
      (lambda (rs) (length rs))))
  (for/list ([row (in-list rows)])
    (attach-query-proofs entity (vector->entity-row entity row) predicates)))

(define (postgres-select-one runtime entity predicates [order #f])
  (define-values (where-sql params _next-index)
    (compile-where-sql predicates))
  (define order-sql
    (if order
        (format " ORDER BY ~a ~a"
                (quote-sql-identifier (field-column-name (order-clause-field order)) 'sql)
                (if (eq? (order-clause-direction order) 'asc) "ASC" "DESC"))
        ""))
  (define sql
    (format "select ~a from ~a~a~a limit 1"
            (entity-select-column-sql entity)
            (qualified-table-name (database-runtime-database runtime) entity)
            where-sql
            order-sql))
  (when (tesl-log-active?) (tesl-log-sql! sql params))
  (define row
    (with-sql-capture sql params (capture-table-name entity) 'select-one
      (lambda () (apply query-maybe-row (database-runtime-connection runtime) sql params))
      (lambda (r) (if r 1 0))))
  (and row
       (attach-query-proofs entity (vector->entity-row entity row) predicates)))

(define (postgres-insert-one! runtime entity value)
  (define-values (row primary-key-name bindings)
    (normalize-entity-row entity value 'insert-one!))
  (define fields (entity-spec-fields entity))
  ;; A Money field contributes TWO columns and TWO params (minor, currency).
  (define insert-columns (append-map field-select-column-sql-list fields))
  (define params
    (append* (for/list ([field (in-list fields)])
               (field-db-param-values field (row-field-ref row field) 'insert-one!))))
  (define sql
    (format "insert into ~a (~a) values (~a) returning ~a"
            (qualified-table-name (database-runtime-database runtime) entity)
            (string-join insert-columns ", ")
            (string-join
             (for/list ([index (in-range 1 (add1 (length params)))])
               (postgres-placeholder index))
             ", ")
            (entity-select-column-sql entity)))
  (when (tesl-log-active?) (tesl-log-sql! sql params))
  (define inserted
    (with-sql-capture sql params (capture-table-name entity) 'insert-one!
      (lambda () (apply query-row (database-runtime-connection runtime) sql params))
      (lambda (_r) 1)))
  (attach-insert-proofs
   entity
   (vector->entity-row entity inserted)
   primary-key-name
   bindings))

(define (postgres-upsert-one! runtime entity value conflict-fields update-fields)
  ;; INSERT ... ON CONFLICT (col1, col2) DO UPDATE SET col = EXCLUDED.col ...
  (define-values (row primary-key-name bindings)
    (normalize-entity-row entity value 'upsert-one!))
  (define fields (entity-spec-fields entity))
  (define (find-field fname)
    (for/first ([f (in-list fields)]
                #:when (equal? (symbol->string (field-spec-key f)) fname))
      f))
  (define conflict-cols
    (map (lambda (fname)
           (define f (find-field fname))
           ;; A Money conflict target would need a unique index over both
           ;; derived columns — not a meaningful conflict key; fail closed.
           (when (and f (money-related-field? f))
             (raise-user-error 'upsert-one!
                               "field ~a on entity ~a: Money fields cannot be upsert conflict keys"
                               (field-spec-key f)
                               (field-spec-entity f)))
           (when (and f (money-rate-related-field? f))
             (raise-user-error 'upsert-one!
                               "field ~a on entity ~a: MoneyRate fields cannot be upsert conflict keys"
                               (field-spec-key f)
                               (field-spec-entity f)))
           (quote-sql-identifier (field-column-name f) 'sql))
         conflict-fields))
  ;; A Money update target expands over BOTH derived columns.
  (define update-cols
    (append*
     (for/list ([fname (in-list update-fields)])
       (for/list ([col (in-list (field-select-column-sql-list (find-field fname)))])
         (format "~a = EXCLUDED.~a" col col)))))
  (define params
    (append* (for/list ([field (in-list fields)])
               (field-db-param-values field (row-field-ref row field) 'upsert-one!))))
  (define sql
    (format "insert into ~a (~a) values (~a) on conflict (~a) do update set ~a returning ~a"
            (qualified-table-name (database-runtime-database runtime) entity)
            (string-join (append-map field-select-column-sql-list fields) ", ")
            (string-join
             (for/list ([index (in-range 1 (add1 (length params)))])
               (postgres-placeholder index)) ", ")
            (string-join conflict-cols ", ")
            (string-join update-cols ", ")
            (entity-select-column-sql entity)))
  (when (tesl-log-active?) (tesl-log-sql! sql params))
  (define upserted
    (with-sql-capture sql params (capture-table-name entity) 'upsert-one!
      (lambda () (apply query-row (database-runtime-connection runtime) sql params))
      (lambda (_r) 1)))
  (attach-insert-proofs
   entity
   (vector->entity-row entity upserted)
   primary-key-name
   bindings))

(define (postgres-update-many! runtime entity updates predicates)
  (define update-pairs (normalize-update-spec entity updates))
  ;; `set p.price = <money>` expands over both derived columns, so the SET
  ;; column list and its params are flattened per field (Money → two of each)
  ;; and the WHERE placeholders start after ALL set params.
  (define set-columns
    (append-map (lambda (pair) (field-select-column-sql-list (car pair)))
                update-pairs))
  (define set-params
    (append* (for/list ([pair (in-list update-pairs)])
               (field-db-param-values (car pair) (cdr pair) 'update-many!))))
  (define-values (where-sql where-params _next-index)
    (compile-where-sql predicates (add1 (length set-params))))
  (define sql
    (format "update ~a set ~a~a returning ~a"
            (qualified-table-name (database-runtime-database runtime) entity)
            (string-join
             (for/list ([column (in-list set-columns)]
                        [index (in-naturals 1)])
               (format "~a = ~a" column (postgres-placeholder index)))
             ", ")
            where-sql
            (entity-select-column-sql entity)))
  (define params (append set-params where-params))
  (when (tesl-log-active?) (tesl-log-sql! sql params))
  (define rows
    (with-sql-capture sql params (capture-table-name entity) 'update-many!
      (lambda () (apply query-rows (database-runtime-connection runtime) sql params))
      (lambda (rs) (length rs))))
  (for/list ([row (in-list rows)])
    (attach-query-proofs entity (vector->entity-row entity row) predicates)))

(define (postgres-delete-many! runtime entity predicates)
  (define-values (where-sql params _next-index)
    (compile-where-sql predicates))
  (define sql
    (format "delete from ~a~a" (qualified-table-name (database-runtime-database runtime) entity) where-sql))
  (when (tesl-log-active?) (tesl-log-sql! sql params))
  ;; query-exec returns no row count in db-lib's simple form, so the count stays #f.
  (with-sql-capture sql params (capture-table-name entity) 'delete-many!
    (lambda () (apply query-exec (database-runtime-connection runtime) sql params))
    (lambda (_r) #f))
  (void))

(define (postgres-delete-many-with-count! runtime entity predicates)
  (define-values (where-sql params _next-index)
    (compile-where-sql predicates))
  (when (tesl-log-active?) (tesl-log-sql! (format "delete from ~a~a (with count)"
                                              (qualified-table-name (database-runtime-database runtime) entity)
                                              where-sql) params))
  ;; Capture the ACTUAL parameterized statement the driver runs (the counting CTE),
  ;; not the human-readable log line — the SQL scope must show exactly what executes.
  (define sql
    (format "with deleted as (
               delete from ~a~a
               returning 1
             )
             select count(*) from deleted"
            (qualified-table-name (database-runtime-database runtime) entity)
            where-sql))
  (define count
    (with-sql-capture sql params (capture-table-name entity) 'delete-many-with-count!
      (lambda () (apply query-value (database-runtime-connection runtime) sql params))
      (lambda (c) (and (exact-nonnegative-integer? c) c))))
  (if (= count 0)
      NoRowDeleted
      (RowsDeleted count)))

(define (select-many source . clauses)
  (require-capabilities! (list db-read))
  (unless (from-clause? source)
    (raise-user-error 'select-many "expected a from clause, got ~a" source))
  (define entity (from-clause-entity source))
  (define predicates (query-predicates clauses))
  (define order (query-order clauses))
  (define lim (query-limit clauses))
  (define off (query-offset clauses))
  (define grp (query-group-by clauses))
  (define joins (query-inner-joins clauses))
  (define runtime (database-runtime-for-entity entity))
  (if runtime
      (postgres-select-many runtime entity predicates order lim off grp joins)
      (let* ([results (in-memory-select-many entity predicates)]
             ;; Apply inner joins as filters
             [results (for/list ([row (in-list results)]
                                 #:when (for/and ([j (in-list joins)])
                                          (in-memory-inner-join-matches? j row)))
                        row)]
             ;; ORDER BY before OFFSET/LIMIT — SQL evaluation order.
             [results (in-memory-order-rows results order)]
             [after-offset (if off (list-tail results (min (offset-clause-count off) (length results))) results)])
        (if lim (take after-offset (min (limit-clause-count lim) (length after-offset))) after-offset))))

(define (select-one source . clauses)
  (require-capabilities! (list db-read))
  (unless (from-clause? source)
    (raise-user-error 'select-one "expected a from clause, got ~a" source))
  (define entity (from-clause-entity source))
  (define predicates (query-predicates clauses))
  (define order (query-order clauses))
  (define runtime (database-runtime-for-entity entity))
  (if runtime
      (postgres-select-one runtime entity predicates order)
      (let ([matches (in-memory-order-rows (in-memory-select-many entity predicates) order)])
        (and (pair? matches) (car matches)))))

;; COUNT(*) — returns an Int (exact number of matching rows).
;; In-memory fallback: length of the result list.
(define (select-count source . clauses)
  (require-capabilities! (list db-read))
  (unless (from-clause? source)
    (raise-user-error 'select-count "expected a from clause, got ~a" source))
  (define entity (from-clause-entity source))
  (define predicates (query-predicates clauses))
  (define runtime (database-runtime-for-entity entity))
  (if runtime
      (let ()
        (define-values (where-sql params _) (compile-where-sql predicates))
        (define sql
          (format "select count(*) from ~a~a"
                  (qualified-table-name (database-runtime-database runtime) entity)
                  where-sql))
        (when (tesl-log-active?) (tesl-log-sql! sql params))
        (define result
          (with-sql-capture sql params (capture-table-name entity) 'select-count
            (lambda () (apply query-value (database-runtime-connection runtime) sql params))
            (lambda (_r) 1)))   ; an aggregate returns one scalar row
        (if (integer? result) result (inexact->exact result)))
      (length (in-memory-select-many entity predicates))))

;; SUM(field) — returns an Int (sum of a numeric field, 0 if no rows match).
;; field-accessor: a thunk of the form  (lambda () (Entity-field-field))
;;   obtained at compile time as the field-constant accessor.
;; In-memory fallback: sum values from the in-memory result list.
(define (select-sum field-accessor source . clauses)
  (require-capabilities! (list db-read))
  (unless (from-clause? source)
    (raise-user-error 'select-sum "expected a from clause, got ~a" source))
  ;; Accept either a field-spec value (from entity-field-ref) or a thunk accessor
  (define field (if (field-spec? field-accessor) field-accessor (field-accessor)))
  (unless (field-spec? field)
    (raise-user-error 'select-sum "expected a field-spec from a field accessor, got ~a" field))
  (define entity (from-clause-entity source))
  (define predicates (query-predicates clauses))
  (define runtime (database-runtime-for-entity entity))
  (cond
    ;; Money: native SUM over minor units, guarded by the shared decision
    ;; table in money-sum-result (empty → error, mixed currencies → error,
    ;; single currency → Money) — identical on both backends.
    [(money-related-field? field)
     (reject-unsupported-money-field! field 'select-sum)
     (if runtime
         (postgres-money-select-sum runtime entity field predicates)
         (in-memory-money-select-sum entity field predicates))]
    ;; MoneyRate: summing rates mixes denominators (950/h + 950/day is not a
    ;; rate) on top of the mixed-currency problem — fail closed, BOTH backends.
    [(money-rate-related-field? field)
     (raise-user-error 'select-sum
                       "field ~a on entity ~a: selectSum over a MoneyRate column is not supported; aggregate the materialized Money instead"
                       (field-spec-key field)
                       (field-spec-entity field))]
    [runtime
     (define col (quote-sql-identifier (field-column-name field) 'sql))
     (define-values (where-sql params _) (compile-where-sql predicates))
     (define sql
       (format "select coalesce(sum(~a), 0) from ~a~a"
               col
               (qualified-table-name (database-runtime-database runtime) entity)
               where-sql))
     (when (tesl-log-active?) (tesl-log-sql! sql params))
     (define result
       (with-sql-capture sql params (capture-table-name entity) 'select-sum
         (lambda () (apply query-value (database-runtime-connection runtime) sql params))
         (lambda (_r) 1)))
     (if (integer? result) result (inexact->exact result))]
    [else
     (for/sum ([row (in-list (in-memory-select-many entity predicates))])
       (define v (row-field-ref row field 0))
       (if (number? v) (inexact->exact v) 0))]))

;; PostgreSQL Money SUM: one aggregate query fetches the minor-unit total, the
;; number of DISTINCT currencies and one witness code; the decision table then
;; decides.  COUNT(DISTINCT c) is 0 exactly when no row matched (the currency
;; column is NOT NULL), which is the empty case.
(define (postgres-money-select-sum runtime entity field predicates)
  (define minor-col (quote-sql-identifier (money-minor-column-string field 'sql) 'sql))
  (define currency-col (quote-sql-identifier (money-currency-column-string field 'sql) 'sql))
  (define-values (where-sql params _) (compile-where-sql predicates))
  (define sql
    (format "select coalesce(sum(~a), 0), count(distinct ~a), min(~a) from ~a~a"
            minor-col
            currency-col
            currency-col
            (qualified-table-name (database-runtime-database runtime) entity)
            where-sql))
  (when (tesl-log-active?) (tesl-log-sql! sql params))
  (define row
    (with-sql-capture sql params (capture-table-name entity) 'select-sum
      (lambda () (apply query-row (database-runtime-connection runtime) sql params))
      (lambda (_r) 1)))
  (define total
    (let ([v (vector-ref row 0)])
      (if (exact-integer? v) v (inexact->exact v))))
  (define distinct-count (vector-ref row 1))
  (define witness-code (vector-ref row 2))   ; sql-null when no rows matched
  (money-sum-result 'select-sum field total distinct-count
                    (lambda () (money-stored-currency field witness-code 'select-sum))))

;; Memory Money SUM: same decision table over the structs stored in the rows.
(define (in-memory-money-select-sum entity field predicates)
  (define monies
    (for/list ([row (in-list (in-memory-select-many entity predicates))])
      (define v (unwrap-non-null (row-field-ref row field #f)))
      (unless (tesl-money? v)
        (raise-user-error 'select-sum
                          "field ~a on entity ~a holds ~e where a Money value was expected"
                          (field-spec-key field)
                          (field-spec-entity field)
                          v))
      v))
  (define distinct-count
    (length (remove-duplicates
             (map (lambda (m) (tesl-currency-code (tesl-money-currency m))) monies))))
  (money-sum-result 'select-sum field
                    (for/sum ([m (in-list monies)]) (tesl-money-minor-units m))
                    distinct-count
                    (lambda () (tesl-money-currency (car monies)))))

;; MAX/MIN over the Memory backend, shared by select-max and select-min.
;; SQL aggregate semantics: NULL rows (a Maybe column's Nothing / sql-null)
;; are ignored; all-NULL (or no rows) yields NULL (#f here).  Comparison
;; happens on the UNWRAPPED base value — the GitHub #28 class: a newtype
;; column (PosixMillis, a user `type Code = Int`, …) stores newtype-value
;; structs, which Racket max/min reject with "expected: real?".  The stored
;; value itself (wrapper intact) is returned, exactly like a `select` row
;; field read, so the result still satisfies the declared newtype return type.
;; operator is '> for MAX, '< for MIN.
(define (in-memory-extreme who rows field operator)
  (define candidates
    (for*/list ([row (in-list rows)]
                [v (in-value (row-field-ref row field))]
                #:unless (or (not v) (sql-null-value? v)))
      v))
  (if (null? candidates)
      #f
      (for/fold ([best (car candidates)])
                ([v (in-list (cdr candidates))])
        (if (ordered-comparison-result field operator
                                       (unwrap-non-null v)
                                       (unwrap-non-null best)
                                       who)
            v
            best))))

;; MAX(field) — returns the maximum value of a numeric field (or #f if no rows).
(define (select-max field-accessor source . clauses)
  (require-capabilities! (list db-read))
  (unless (from-clause? source)
    (raise-user-error 'select-max "expected a from clause, got ~a" source))
  (define field (if (field-spec? field-accessor) field-accessor (field-accessor)))
  (unless (field-spec? field)
    (raise-user-error 'select-max "expected a field-spec from a field accessor, got ~a" field))
  ;; Money runtime backstop: MAX over mixed currencies is meaningless.
  (reject-money-ordered-comparison! 'select-max field "selectMax")
  (define entity (from-clause-entity source))
  (define predicates (query-predicates clauses))
  (define runtime (database-runtime-for-entity entity))
  (if runtime
      (let ()
        (define col (quote-sql-identifier (field-column-name field) 'sql))
        (define-values (where-sql params _) (compile-where-sql predicates))
        (define sql
          (format "select max(~a) from ~a~a"
                  col
                  (qualified-table-name (database-runtime-database runtime) entity)
                  where-sql))
        (when (tesl-log-active?) (tesl-log-sql! sql params))
        (define result
          (with-sql-capture sql params (capture-table-name entity) 'select-max
            (lambda () (apply query-value (database-runtime-connection runtime) sql params))
            (lambda (_r) 1)))
        (if (and result (integer? result)) (inexact->exact result) result))
      (in-memory-extreme 'select-max (in-memory-select-many entity predicates) field '>)))

;; MIN(field) — returns the minimum value of a numeric field (or #f if no rows).
(define (select-min field-accessor source . clauses)
  (require-capabilities! (list db-read))
  (unless (from-clause? source)
    (raise-user-error 'select-min "expected a from clause, got ~a" source))
  (define field (if (field-spec? field-accessor) field-accessor (field-accessor)))
  (unless (field-spec? field)
    (raise-user-error 'select-min "expected a field-spec from a field accessor, got ~a" field))
  ;; Money runtime backstop: MIN over mixed currencies is meaningless.
  (reject-money-ordered-comparison! 'select-min field "selectMin")
  (define entity (from-clause-entity source))
  (define predicates (query-predicates clauses))
  (define runtime (database-runtime-for-entity entity))
  (if runtime
      (let ()
        (define col (quote-sql-identifier (field-column-name field) 'sql))
        (define-values (where-sql params _) (compile-where-sql predicates))
        (define sql
          (format "select min(~a) from ~a~a"
                  col
                  (qualified-table-name (database-runtime-database runtime) entity)
                  where-sql))
        (when (tesl-log-active?) (tesl-log-sql! sql params))
        (define result
          (with-sql-capture sql params (capture-table-name entity) 'select-min
            (lambda () (apply query-value (database-runtime-connection runtime) sql params))
            (lambda (_r) 1)))
        (if (and result (integer? result)) (inexact->exact result) result))
      (in-memory-extreme 'select-min (in-memory-select-many entity predicates) field '<)))



;; ── Grouped aggregates + calendar bucket keys (GitHub #29) ───────────────────
;;
;; `selectCountBy` / `selectSumBy … groupBy <key>` return ONE ROW PER GROUP as a
;; List of `Tuple2 key aggregate`, ordered by key ascending.  The key is either
;; a plain column ('field) or a calendar bucket ('hour/'day/'week/'month/'year)
;; of a PosixMillis column at a fixed UTC offset in minutes.  On PostgreSQL the
;; bucket is computed server-side: hour/day/week as exact integer floor
;; arithmetic on the BIGINT millis column, month/year via date_trunc on the
;; UTC-shifted timestamp — both matching `tesl-time-trunc` (tesl/time.rkt), the
;; single semantic reference the Memory backend calls directly.

(struct sql-group-key-spec (unit tz field) #:transparent)

;; sql-group-key : unit-symbol × TimeZone (Tesl value; ignored for 'field) × field -> spec
(define (sql-group-key unit tz field-accessor)
  (define field (if (field-spec? field-accessor) field-accessor (field-accessor)))
  (unless (field-spec? field)
    (raise-user-error 'groupBy "expected a field reference, got ~a" field))
  ;; Money runtime backstop: a Money value is not a bucketable scalar (and on
  ;; PostgreSQL its logical column does not physically exist).
  (when (or (money-field? field) (maybe-money-field? field))
    (raise-user-error 'groupBy
                      "field ~a on entity ~a: Money cannot be a groupBy key"
                      (field-spec-key field)
                      (field-spec-entity field)))
  (when (money-rate-related-field? field)
    (raise-user-error 'groupBy
                      "field ~a on entity ~a: MoneyRate cannot be a groupBy key"
                      (field-spec-key field)
                      (field-spec-entity field)))
  (unless (memq unit '(field hour day week month year))
    (raise-user-error 'groupBy "unknown bucket unit: ~a" unit))
  (define zone
    (and (not (eq? unit 'field))
         (let ([v (raw-value tz)])
           (unless (tesl-tz? v)
             (raise-user-error 'groupBy
                               "Time.trunc* takes a TimeZone (Utc / FixedOffset n / a zone constructor), got ~e" v))
           v)))
  (sql-group-key-spec unit zone field))

;; The key's SQL expression (+ its params), given the next free $ index.
;;
;; Fixed-offset zones (Utc / FixedOffset): exact integer arithmetic on the
;; BIGINT millis column — hour/day/week as floor((col + off) / n) * n - off via
;; the sign-safe modulo `x - (((x % n) + n) % n)` (the week floor shifts by +3
;; days first: epoch day 0 = Thursday, ISO weeks start Monday); month/year via
;; date_trunc on the UTC-shifted timestamp.
;;
;; Named zones (the TimeZone zone constructors): PostgreSQL's own tzdata does
;; the DST-correct work — date_trunc('<unit>', ts AT TIME ZONE $z) AT TIME ZONE
;; $z — mirroring tesl-time-trunc's two-step semantics (the parity suite is the
;; oracle).  PG's date_trunc('week') is the ISO Monday week, same as the engine.
(define (group-key-sql key idx)
  (define col (quote-sql-identifier (field-column-name (sql-group-key-spec-field key)) 'sql))
  (define unit (sql-group-key-spec-unit key))
  (define tz (sql-group-key-spec-tz key))
  (define (fixed-sql off-min)
    (define off-ms (* off-min 60000))
    (define p (format "$~a" idx))
    (define (floor-mult x n) (format "(~a - (((~a % ~a) + ~a) % ~a))" x x n n n))
    (define x (format "(~a + ~a)" col p))
    (define text
      (case unit
        [(hour) (format "(~a - ~a)" (floor-mult x 3600000) p)]
        [(day)  (format "(~a - ~a)" (floor-mult x 86400000) p)]
        [(week)
         (define shifted (format "(~a + 259200000)" x))
         (format "((~a - 259200000) - ~a)" (floor-mult shifted 604800000) p)]
        [(month year)
         (format "((extract(epoch from date_trunc('~a', to_timestamp((~a)::double precision / 1000.0) at time zone 'UTC'))::bigint * 1000) - ~a)"
                 unit x p)]))
    (values text (list off-ms) (add1 idx)))
  (cond
    [(eq? unit 'field) (values col '() idx)]
    [(eq? (tesl-tz-kind tz) 'named)
     (define p (format "$~a" idx))
     (values
      (format "(extract(epoch from (date_trunc('~a', to_timestamp((~a)::double precision / 1000.0) at time zone ~a) at time zone ~a))::bigint * 1000)"
              unit col p p)
      (list (tesl-tz-payload tz))
      (add1 idx))]
    [(eq? (tesl-tz-kind tz) 'utc) (fixed-sql 0)]
    [else (fixed-sql (tesl-tz-payload tz))]))

;; Memory backend: the bucket value for one row, decoded through the SAME
;; field codec the PostgreSQL row path uses (so a PosixMillis bucket comes back
;; as a PosixMillis newtype on both backends).
(define (group-key-value key row)
  (define field (sql-group-key-spec-field key))
  (define v (row-field-ref row field #f))
  (case (sql-group-key-spec-unit key)
    [(field) v]
    [else
     (define ms
       (let loop ([x (unwrap-non-null v)])
         (if (newtype-value? x) (loop (newtype-value-value x)) x)))
     (unless (exact-integer? ms)
       (raise-user-error 'groupBy "Time.trunc* bucket needs a PosixMillis value, got ~e" v))
     (field-db-value->runtime-value
      field
      (tesl-time-trunc (sql-group-key-spec-unit key)
                       (sql-group-key-spec-tz key)
                       ms))]))

;; Deterministic key order (ascending), across the runtime key representations.
(define (group-key<? a b)
  (define (strip x)
    (let loop ([v (unwrap-non-null x)])
      (if (newtype-value? v) (loop (newtype-value-value v)) v)))
  (define x (strip a))
  (define y (strip b))
  (cond
    [(and (number? x) (number? y)) (< x y)]
    [(and (string? x) (string? y)) (string<? x y)]
    [(and (boolean? x) (boolean? y)) (and (not x) y)]
    [else (string<? (format "~a" x) (format "~a" y))]))

;; Shared Memory-backend grouping: bucket the matching rows, aggregate each
;; group with [agg-of], return sorted (Tuple2 key agg) rows.
(define (in-memory-grouped entity predicates key agg-of)
  (define groups (make-hash))
  (for ([row (in-list (in-memory-select-many entity predicates))])
    (hash-update! groups (group-key-value key row) (lambda (l) (cons row l)) '()))
  (for/list ([k (in-list (sort (hash-keys groups) group-key<?))])
    (Tuple2 k (agg-of (hash-ref groups k)))))

;; Shared PostgreSQL runner for both grouped forms: SELECT <key>, <agg> ...
;; GROUP BY 1 ORDER BY 1, decoding the key through the field codec.
(define (postgres-grouped runtime entity predicates key agg-sql op)
  (define-values (where-sql wparams next-idx) (compile-where-sql predicates))
  (define-values (key-sql kparams _next) (group-key-sql key next-idx))
  (define params (append wparams kparams))
  (define sql
    (format "select ~a, ~a from ~a~a group by 1 order by 1"
            key-sql agg-sql
            (qualified-table-name (database-runtime-database runtime) entity)
            where-sql))
  (when (tesl-log-active?) (tesl-log-sql! sql params))
  (define rows
    (with-sql-capture sql params (capture-table-name entity) op
      (lambda () (apply query-rows (database-runtime-connection runtime) sql params))
      (lambda (r) (length r))))
  (define kfield (sql-group-key-spec-field key))
  (for/list ([row (in-list rows)])
    (Tuple2 (field-db-value->runtime-value kfield (vector-ref row 0))
            (let ([v (vector-ref row 1)])
              (if (exact-integer? v) v (inexact->exact v))))))

;; COUNT(*) per group — List (Tuple2 key Int), ordered by key.
(define (select-count-by key source . clauses)
  (require-capabilities! (list db-read))
  (unless (sql-group-key-spec? key)
    (raise-user-error 'select-count-by "expected a groupBy key, got ~a" key))
  (unless (from-clause? source)
    (raise-user-error 'select-count-by "expected a from clause, got ~a" source))
  (define entity (from-clause-entity source))
  (define predicates (query-predicates clauses))
  (define runtime (database-runtime-for-entity entity))
  (if runtime
      (postgres-grouped runtime entity predicates key "count(*)" 'select-count-by)
      (in-memory-grouped entity predicates key length)))

;; SUM(field) per group — List (Tuple2 key V), ordered by key; empty groups
;; cannot occur (a group exists because rows matched).
(define (select-sum-by key field-accessor source . clauses)
  (require-capabilities! (list db-read))
  (unless (sql-group-key-spec? key)
    (raise-user-error 'select-sum-by "expected a groupBy key, got ~a" key))
  (define field (if (field-spec? field-accessor) field-accessor (field-accessor)))
  (unless (field-spec? field)
    (raise-user-error 'select-sum-by "expected a field-spec from a field accessor, got ~a" field))
  ;; Money runtime backstop: per-group Money sums need the same per-group
  ;; mixed-currency guard selectSum has; not implemented yet — fail closed.
  (when (or (money-field? field) (maybe-money-field? field))
    (raise-user-error 'select-sum-by
                      "field ~a on entity ~a: selectSumBy over a Money column is not supported; sum Money.minorUnits per group after filtering by currency"
                      (field-spec-key field)
                      (field-spec-entity field)))
  (when (money-rate-related-field? field)
    (raise-user-error 'select-sum-by
                      "field ~a on entity ~a: selectSumBy over a MoneyRate column is not supported; aggregate the materialized Money instead"
                      (field-spec-key field)
                      (field-spec-entity field)))
  (unless (from-clause? source)
    (raise-user-error 'select-sum-by "expected a from clause, got ~a" source))
  (define entity (from-clause-entity source))
  (define predicates (query-predicates clauses))
  (define runtime (database-runtime-for-entity entity))
  (if runtime
      (postgres-grouped runtime entity predicates key
                        (format "coalesce(sum(~a), 0)"
                                (quote-sql-identifier (field-column-name field) 'sql))
                        'select-sum-by)
      (in-memory-grouped entity predicates key
                         (lambda (rows)
                           (for/sum ([row (in-list rows)])
                             (define v (row-field-ref row field 0))
                             (if (number? v) (inexact->exact v) 0))))))

(define (insert-one! entity value)
  (require-capabilities! (list db-write))
  (unless (entity-spec? entity)
    (raise-user-error 'insert-one! "expected an entity-spec, got ~a" entity))
  (define runtime (database-runtime-for-entity entity))
  (if runtime
      (postgres-insert-one! runtime entity value)
      (in-memory-insert-one! entity value)))

(define (upsert-one! entity value conflict-fields update-fields)
  ;; `conflict-fields` and `update-fields` are Racket lists of strings naming fields.
  (require-capabilities! (list db-write))
  (unless (entity-spec? entity)
    (raise-user-error 'upsert-one! "expected an entity-spec, got ~a" entity))
  (define runtime (database-runtime-for-entity entity))
  (if runtime
      (postgres-upsert-one! runtime entity value
                             (map symbol->string conflict-fields)
                             (map symbol->string update-fields))
      (in-memory-upsert-one! entity value
                             (map symbol->string conflict-fields)
                             (map symbol->string update-fields))))

(define (insert-many! entity-or-source values)
  (require-capabilities! (list db-write))
  (define entity
    (cond
      [(entity-spec? entity-or-source) entity-or-source]
      [(from-clause? entity-or-source) (from-clause-entity entity-or-source)]
      [else (raise-user-error 'insert-many! "expected an entity-spec, got ~a" entity-or-source)]))
  (define raw-values (raw-value values))
  (unless (list? raw-values)
    (raise-user-error 'insert-many! "expected a list of entity values, got ~a" raw-values))
  (for ([value (in-list raw-values)])
    (insert-one! entity (raw-value value)))
  (void))

(define (update-many! source updates . clauses)
  (require-capabilities! (list db-write))
  (unless (from-clause? source)
    (raise-user-error 'update-many! "expected a from clause, got ~a" source))
  (define entity (from-clause-entity source))
  (define predicates (query-predicates clauses))
  (define runtime (database-runtime-for-entity entity))
  (if runtime
      (postgres-update-many! runtime entity updates predicates)
      (in-memory-update-many! entity updates predicates)))

(define (delete-many! source . clauses)
  (require-capabilities! (list db-write))
  (unless (from-clause? source)
    (raise-user-error 'delete-many! "expected a from clause, got ~a" source))
  (define entity (from-clause-entity source))
  (define predicates (query-predicates clauses))
  (define runtime (database-runtime-for-entity entity))
  (if runtime
      (postgres-delete-many! runtime entity predicates)
      (in-memory-delete-many! entity predicates)))

(define (delete-many-with-count! source . clauses)
  (require-capabilities! (list db-write))
  (unless (from-clause? source)
    (raise-user-error 'delete-many-with-count! "expected a from clause, got ~a" source))
  (define entity (from-clause-entity source))
  (define predicates (query-predicates clauses))
  (define runtime (database-runtime-for-entity entity))
  (if runtime
      (postgres-delete-many-with-count! runtime entity predicates)
      (in-memory-delete-many-with-count! entity predicates)))

;; ── Pool-lease waiting (issue #31) ───────────────────────────────────────────
;; Racket's `connection-pool-lease` raises "connection pool limit reached"
;; IMMEDIATELY when every slot is leased, so a short burst of concurrent
;; requests (a single page load can issue several) 500s instead of queueing for
;; the next freed connection.  The db library already has the right primitive:
;; leasing with `#:timeout` parks the request in the pool manager's lease
;; channel — the manager only accepts it once a slot is free — and calls
;; `#:fail` only after the bounded wait expires.  The timeout raises a
;; DISTINGUISHABLE exception (below) so the HTTP layer can answer 503 Service
;; Unavailable ("saturated, retry") instead of a generic 500 ("broken").
(struct exn:fail:tesl:pool-timeout exn:fail () #:transparent)

;; How long a lease waits for a freed connection before giving up.  10s is well
;; above any healthy query's latency but still bounded, so a genuinely wedged
;; pool surfaces as a clear error rather than hung requests.  Overridable via
;; TESL_PG_POOL_LEASE_TIMEOUT_MS (same env-knob pattern as TESL_MAX_BODY_BYTES).
(define pool-lease-timeout-ms
  (let ([v (getenv "TESL_PG_POOL_LEASE_TIMEOUT_MS")])
    (or (and v (string->number v)) 10000)))

;; Connector thunk for `virtual-connection`: leases from `pool`, waiting up to
;; `timeout-ms` for a slot.  virtual-connection calls this at most once per
;; thread (it maps thread → actual connection) and releases the lease when the
;; thread dies — the same lifecycle as passing the pool directly, minus the
;; fail-fast lease.  The explicit `thread-dead-evt` key reproduces the default
;; lease key; it is spelled out because `connection-pool-lease`'s contract
;; accepts only custodians/evts, not threads.
(define (make-pool-lease-connector pool db-name timeout-ms)
  (lambda ()
    ;; Metrics: lease-wait time is the saturation signal (a rising wait_time
    ;; histogram precedes the timeout cliff); the timeout counter is the cliff
    ;; itself (each increment is one 503 at the HTTP layer).
    (define metric-start (and (metrics-active?) (current-inexact-milliseconds)))
    (define (record-wait!)
      (when metric-start
        (metric-histogram-record!
         "db.client.connection.wait_time"
         (/ (- (current-inexact-milliseconds) metric-start) 1000.0)
         (list (cons "tesl.database" (~a db-name)))
         #:unit "s"
         #:boundaries duration-histogram-boundaries)))
    (define conn
      (connection-pool-lease
       pool
       (thread-dead-evt (current-thread))
       #:timeout (/ timeout-ms 1000.0)
       #:fail (lambda ()
                (record-wait!)
                (metric-counter-add! "db.client.connection.timeouts" 1
                                     (list (cons "tesl.database" (~a db-name))))
                (raise (exn:fail:tesl:pool-timeout
                        (format "database '~a': connection pool lease timed out after ~ams — every pooled connection stayed busy; raise `poolSize` in PostgresConfig (default 10) or investigate long-running queries"
                                db-name timeout-ms)
                        (current-continuation-marks))))))
    (record-wait!)
    conn))

(define (connect-database database #:migrate? [migrate? #f])
  (unless (database-spec? database)
    (raise-user-error 'connect-database "expected a database-spec, got ~a" database))
  ;; Unwrap a value that may be a Maybe (from env()) or a plain value.
  ;; Returns the inner value, or #f if Nothing/null.
  (define (unwrap-maybe v)
    (cond
      [(Nothing? v)   #f]
      [(Something? v) (Something-value v)]
      [else v]))
  (match (database-spec-backend database)
    ['postgres
     (define config (database-spec-config database))
     (define db-user     (unwrap-maybe (postgres-spec-user config)))
     (define db-database (unwrap-maybe (postgres-spec-database config)))
     ;; Fail fast with a clear message when required fields are missing rather
     ;; than letting #f propagate into postgresql-connect's contract check.
     (unless (string? db-user)
       (raise-user-error 'connect-database
         "database '~a': postgres user is ~a — check that the environment variable is set and exported"
         (database-spec-name database) db-user))
     (unless (string? db-database)
       (raise-user-error 'connect-database
         "database '~a': postgres database name is ~a — check that the environment variable is set and exported"
         (database-spec-name database) db-database))
     (define connector
       (lambda ()
         (postgresql-connect #:user     db-user
                             #:database db-database
                             #:password (unwrap-maybe (postgres-spec-password config))
                             #:server   (unwrap-maybe (postgres-spec-server config))
                             #:port     (unwrap-maybe (postgres-spec-port config))
                             #:socket   (unwrap-maybe (postgres-spec-socket config)))))
     ;; Issue #31: surface `poolSize` (via envInt) can carry a bad env value;
     ;; fail fast with the field name rather than via connection-pool's
     ;; opaque contract error.
     (define max-conns (unwrap-maybe (postgres-spec-max-connections config)))
     (unless (exact-positive-integer? max-conns)
       (raise-user-error 'connect-database
         "database '~a': poolSize must be a positive integer, got ~a"
         (database-spec-name database) max-conns))
     (define pool
       (connection-pool connector
                        #:max-connections max-conns
                        #:max-idle-connections (postgres-spec-max-idle-connections config)))
     ;; Metrics: pool capacity as a gauge, so wait_time/timeouts can be read
     ;; against the configured ceiling.  No-op if initTelemetry has not run yet
     ;; (metrics disabled); in the normal boot order main's initTelemetry
     ;; statement executes before the App boots the database.
     (metric-gauge-set! "db.client.connection.max" max-conns
                        (list (cons "tesl.database"
                                    (~a (database-spec-name database)))))
     ;; Issue #31: lease through the bounded-wait connector instead of handing
     ;; the pool to virtual-connection directly (which leases fail-fast).
     (define runtime
       (database-runtime database
                         (virtual-connection
                          (make-pool-lease-connector pool
                                                     (database-spec-name database)
                                                     pool-lease-timeout-ms))))
     (when (or migrate? (postgres-spec-auto-migrate? config))
       (ensure-database-ready! runtime))
     runtime]
    ['memory
     ;; In-memory backend: no real connection needed.
     (database-runtime database #f)]
    [other
     (raise-user-error 'connect-database "unsupported database backend ~a" other)]))

(define (disconnect-database runtime)
  (unless (database-runtime? runtime)
    (raise-user-error 'disconnect-database "expected a database-runtime, got ~a" runtime))
  ;; Memory-backend databases have no real connection (#f); skip disconnect.
  (define conn (database-runtime-connection runtime))
  (when (and conn (connected? conn))
    (disconnect conn))
  (void))

(define (call-with-database database thunk #:migrate? [migrate? #f])
  (unless (procedure? thunk)
    (raise-user-error 'call-with-database "expected a thunk procedure, got ~a" thunk))
  (define runtime (connect-database database #:migrate? migrate?))
  (dynamic-wind
    void
    (lambda ()
      (parameterize ([current-database-runtime runtime])
        (thunk)))
    (lambda ()
      (disconnect-database runtime))))

(begin-for-syntax
  (define-syntax-class sql-name
    (pattern name:id
             #:attr value #''name)
    (pattern name:str
             #:attr value #'name))

  (define-syntax-class entity-field
    (pattern [proof-name:id key:id (~datum :) type:expr
              (~optional (~seq #:column column:sql-name)
                         #:defaults ([column.value #'#f]))
              (~optional (~seq #:db-type db-type:sql-name)
                         #:defaults ([db-type.value #'#f]))]
             #:attr column-value (attribute column.value)
             #:attr db-type-value (attribute db-type.value))))

(define-syntax (define-entity stx)
  (syntax-parse stx
    [(_ entity-name:id
        (~optional (~seq #:source source-expr:expr)
                   #:defaults ([source-expr #'#f]))
        (~optional (~seq #:table table-name:sql-name)
                   #:defaults ([table-name.value #'#f]))
        #:primary-key primary-key:id
        field:entity-field ...+)
     (define field-key-symbols (map syntax-e (syntax->list #'(field.key ...))))
     (unless (member (syntax-e #'primary-key) field-key-symbols)
       (raise-syntax-error 'define-entity
                           (format "primary key ~a must match one of the declared field keys ~a"
                                   (syntax-e #'primary-key)
                                   field-key-symbols)
                           stx
                           #'primary-key))
     (define entity-type-datum (normalize-type-stx #'entity-name))
     (define field-type-datums
       (for/list ([field-type (in-list (syntax->list #'(field.type ...)))])
         (normalize-type-stx field-type)))
     (define field-const-ids
       (for/list ([field-key (in-list (syntax->list #'(field.key ...)))])
         (format-id field-key "~a-~a-field" (syntax-e #'entity-name) (syntax-e field-key))))
     (define field-accessor-ids
       (for/list ([field-key (in-list (syntax->list #'(field.key ...)))])
         (format-id field-key "~a-~a" (syntax-e #'entity-name) (syntax-e field-key))))
     (define predicate-id (format-id #'entity-name "~a?" (syntax-e #'entity-name)))
     (define field-nullable?-datums
       (for/list ([field-type-datum (in-list field-type-datums)])
         ;; nullable? = #t when the type datum is (list 'Maybe inner)
         (and (list? field-type-datum)
              (= (length field-type-datum) 2)
              (eq? (car field-type-datum) 'Maybe))))
     (with-syntax ([(field-const-id ...) field-const-ids]
                   [(field-accessor-id ...) field-accessor-ids]
                   [(field-type-datum ...) (for/list ([field-type-datum (in-list field-type-datums)])
                                             #`'#,field-type-datum)]
                   [(field-nullable?-datum ...) (for/list ([n? (in-list field-nullable?-datums)])
                                                  #`'#,n?)]
                   [entity-type-expr #`'#,entity-type-datum]
                   [predicate-id predicate-id])
       #'(begin
           (define field-const-id
             (field-spec 'entity-name
                         'field.proof-name
                         'field.key
                         field-type-datum
                         (eq? 'field.key 'primary-key)
                         field.column-value
                         field.db-type-value
                         field-nullable?-datum)) ...
           (define (field-accessor-id) field-const-id) ...
           (define (predicate-id value)
             (entity-row-matches-fields? (list field-const-id ...) value))
            (register-runtime-type! entity-type-expr predicate-id)
            (register-field-access! entity-type-expr
                                   '(field.key ...)
                                   (lambda (value field-name)
                                     (define raw (raw-value value))
                                     (cond
                                       [(eq? field-name 'field.key)
                                        (row-field-ref raw field-const-id)]
                                       ...)))
           (define entity-name
             (entity-spec 'entity-name
                          source-expr
                          'primary-key
                          (list field-const-id ...)
                          predicate-id
                          table-name.value))))]))

(define-syntax (define-database stx)
  (syntax-parse stx
    [(_ database-name:id
        #:backend (~datum postgres)
        ;; Issue #31: the connection keywords accept ANY order (~alt), not the
        ;; fixed sequence they historically required.  The compiler emits new
        ;; optional fields (e.g. surface `poolSize` → #:max-connections) in the
        ;; middle of the keyword run, and hand-written callers shouldn't have
        ;; to memorize an ordering either.  ~once keeps #:database/#:user
        ;; required; ~optional inside ~alt still means at-most-once.
        (~alt (~once (~seq #:database database-expr:expr))
              (~once (~seq #:user user-expr:expr))
              (~optional (~seq #:password password-expr:expr)
                         #:defaults ([password-expr #'#f]))
              (~optional (~seq #:server server-expr:expr)
                         #:defaults ([server-expr #'"127.0.0.1"]))
              (~optional (~seq #:port port-expr:expr)
                         #:defaults ([port-expr #'5432]))
              (~optional (~seq #:socket socket-expr:expr)
                         #:defaults ([socket-expr #'#f]))
              (~optional (~seq #:schema schema-name:sql-name)
                         #:defaults ([schema-name.value #'"public"]))
              (~optional (~seq #:max-connections max-connections-expr:expr)
                         #:defaults ([max-connections-expr #'10]))
              (~optional (~seq #:max-idle-connections max-idle-connections-expr:expr)
                         #:defaults ([max-idle-connections-expr #'10]))
              (~optional (~seq #:auto-migrate? auto-migrate-expr:expr)
                         #:defaults ([auto-migrate-expr #'#t])))
        ...
        #:entities entity:id ...)
     #'(define database-name
         (database-spec 'database-name
                        'postgres
                        schema-name.value
                        (list entity ...)
                        (postgres-spec database-expr
                                       user-expr
                                       password-expr
                                       server-expr
                                       port-expr
                                       socket-expr
                                       max-connections-expr
                                       max-idle-connections-expr
                                       auto-migrate-expr)))]
    ;; ── Memory backend (no connection params needed) ──────────────────────
    [(_ database-name:id
        #:backend (~datum memory)
        (~optional (~seq #:schema schema-name:sql-name)
                   #:defaults ([schema-name.value #'"public"]))
        #:entities entity:id ...)
     #'(define database-name
         (register-memory-database!
          (database-spec 'database-name
                         'memory
                         schema-name.value
                         (list entity ...)
                         #f)))]))
