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
  (only-in tesl/tesl/db dbRead dbWrite)
)


(provide findBySku quantityForSku findBySku-signature quantityForSku-signature)

(define-newtype Sku String)

(define-entity Product
  #:source (make-hash)
  #:table products
  #:primary-key id
  [Id id : String]
  [Sku sku : Sku]
  [Quantity quantity : Integer]
)

(define-database Warehouse
  #:backend memory
  #:entities Product)

(define/pow
  (findBySku [rawSku : String])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson67-newtype-columns.tesl" 48 (list (cons 'rawSku *rawSku)) (lambda () (call-with-database Warehouse (lambda () (select-many (from Product) (where (==. (entity-field-ref Product 'sku) (raw-value (Sku *rawSku))))))))))

(define/pow
  (quantityForSku [rawSku : String])
  #:capabilities [dbRead]
  #:returns Integer
  (thsl-src! "example/learn/lesson67-newtype-columns.tesl" 57 (list (cons 'rawSku *rawSku)) (lambda () (call-with-database Warehouse (lambda () (let ([found (let ([tesl_match (select-one (from Product) (where (==. (entity-field-ref Product 'sku) (raw-value (Sku *rawSku)))))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl-case-0 (raw-value found)]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson67-newtype-columns.tesl" 60 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([p (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson67-newtype-columns.tesl" 61 (list (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p 'quantity)))))]))))))))

(module+ test
  (require rackunit)
  (test-case "insert constructs the newtype column and query finds it"
    (call-with-fresh-memory-db (list Warehouse) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-1 (thsl-src! "example/learn/lesson67-newtype-columns.tesl" 68 (list) (lambda () (insert-one! Product (hash 'id "p1" 'sku (raw-value (Sku "WIDGET-1")) 'quantity 10)))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson67-newtype-columns.tesl" 70 (list) (lambda () (quantityForSku "WIDGET-1")))) 10)
    )
    ))
  )

  (test-case "query by a non-existent Sku returns empty"
    (call-with-fresh-memory-db (list Warehouse) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-2 (thsl-src! "example/learn/lesson67-newtype-columns.tesl" 75 (list) (lambda () (insert-one! Product (hash 'id "p2" 'sku (raw-value (Sku "WIDGET-2")) 'quantity 5)))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson67-newtype-columns.tesl" 77 (list) (lambda () (findBySku "NO-SUCH-SKU")))) (list))
    )
    ))
  )

  (test-case "update ... set writes the newtype column, then query finds the new value"
    (call-with-fresh-memory-db (list Warehouse) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-3 (thsl-src! "example/learn/lesson67-newtype-columns.tesl" 82 (list) (lambda () (insert-one! Product (hash 'id "p3" 'sku (raw-value (Sku "OLD-SKU")) 'quantity 7)))))
    (void (update-many! (from Product) (hash (entity-field-ref Product 'sku) (raw-value (Sku "NEW-SKU")) (entity-field-ref Product 'quantity) 99) (where (==. (entity-field-ref Product 'id) "p3"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson67-newtype-columns.tesl" 90 (list) (lambda () (quantityForSku "NEW-SKU")))) 99)
    (check-equal? (raw-value (thsl-src! "example/learn/lesson67-newtype-columns.tesl" 91 (list) (lambda () (findBySku "OLD-SKU")))) (list))
    )
    ))
  )

)
