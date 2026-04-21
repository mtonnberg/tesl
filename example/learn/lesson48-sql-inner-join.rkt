#lang racket

(require
  tesl/dsl/capability
  tesl/dsl/types
  tesl/dsl/check
  tesl/dsl/otel
  tesl/dsl/sql
  tesl/dsl/web
  tesl/dsl/test-support
  tesl/tesl/private/runtime
  tesl/tesl/queue
  tesl/tesl/sse
  (only-in tesl/tesl/prelude Bool Int String List)
  (only-in tesl/tesl/db dbRead dbWrite)
)


(provide findOrderWithCustomer findOrdersByCustomerCountry cheapOrdersByCountry findOrderItemsByOrderId findOrderWithCustomer-signature findOrdersByCustomerCountry-signature cheapOrdersByCountry-signature findOrderItemsByOrderId-signature)

(define-entity Customer
  #:source (make-hash)
  #:table customers
  #:primary-key id
  [Id id : String]
  [Name name : String]
  [Country country : String]
)

(define-entity Order
  #:source (make-hash)
  #:table orders
  #:primary-key id
  [Id id : String]
  [CustomerId customerId : String]
  [Amount amount : Integer]
  [Status status : String]
)

(define-entity OrderItem
  #:source (make-hash)
  #:table order_items
  #:primary-key id
  [Id id : String]
  [OrderId orderId : String]
  [ProductName productName : String]
  [Quantity quantity : Integer]
)

(define-database JoinDatabase
  #:backend memory
  #:entities Customer Order OrderItem)

(define/pow
  (findOrderWithCustomer [customerId : String])
  #:capabilities [dbRead]
  #:returns (List Order)
  (call-with-database JoinDatabase (lambda () (select-many (from Order) (where (==. (entity-field-ref Order 'customerId) customerId)) (inner-join Customer (entity-field-ref Order 'customerId) (entity-field-ref Customer 'id))))))

(define/pow
  (findOrdersByCustomerCountry [country : String])
  #:capabilities [dbRead]
  #:returns (List Order)
  (call-with-database JoinDatabase (lambda () (select-many (from Order) (where (==. (entity-field-ref Order 'status) "shipped")) (inner-join Customer (entity-field-ref Order 'customerId) (entity-field-ref Customer 'id))))))

(define/pow
  (cheapOrdersByCountry [n : Integer])
  #:capabilities [dbRead]
  #:returns (List Order)
  (call-with-database JoinDatabase (lambda () (select-many (from Order) (inner-join Customer (entity-field-ref Order 'customerId) (entity-field-ref Customer 'id)) (order-by (entity-field-ref Order 'amount) 'asc) (limit 10)))))

(define/pow
  (findOrderItemsByOrderId [orderId : String])
  #:capabilities [dbRead]
  #:returns (List OrderItem)
  (call-with-database JoinDatabase (lambda () (select-many (from OrderItem) (where (==. (entity-field-ref OrderItem 'orderId) orderId)) (inner-join Order (entity-field-ref OrderItem 'orderId) (entity-field-ref Order 'id))))))

(module+ test
  (require rackunit)
  (test-case "innerJoin filters out orders with no matching customer"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_0 (insert-one! Customer (hash 'id "c1" 'name "Alice" 'country "SE")))
    (define tesl_ignored_1 (insert-one! Order (hash 'id "o1" 'customerId "c1" 'amount 50 'status "new")))
    (define tesl_ignored_2 (insert-one! Order (hash 'id "o2" 'customerId "no-such-customer" 'amount 100 'status "new")))
    (define results (findOrderWithCustomer "c1"))
    (check-not-equal? results (list))
    )
  )

  (test-case "innerJoin returns only orders for the given customer"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_3 (insert-one! Customer (hash 'id "c2" 'name "Bob" 'country "US")))
    (define tesl_ignored_4 (insert-one! Customer (hash 'id "c3" 'name "Carol" 'country "UK")))
    (define tesl_ignored_5 (insert-one! Order (hash 'id "o3" 'customerId "c2" 'amount 200 'status "shipped")))
    (define tesl_ignored_6 (insert-one! Order (hash 'id "o4" 'customerId "c3" 'amount 300 'status "shipped")))
    (define results (findOrderWithCustomer "c2"))
    (check-not-equal? results (list))
    )
  )

  (test-case "cheapOrdersByCountry returns results when orders with customers exist"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_7 (insert-one! Customer (hash 'id "c4" 'name "Dave" 'country "DE")))
    (define tesl_ignored_8 (insert-one! Order (hash 'id "o5" 'customerId "c4" 'amount 10 'status "new")))
    (define tesl_ignored_9 (insert-one! Order (hash 'id "o6" 'customerId "c4" 'amount 20 'status "new")))
    (define results (cheapOrdersByCountry 5))
    (check-not-equal? results (list))
    )
  )

  (test-case "findOrderItemsByOrderId uses innerJoin to filter items"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_10 (insert-one! Customer (hash 'id "c5" 'name "Eve" 'country "FR")))
    (define tesl_ignored_11 (insert-one! Order (hash 'id "o7" 'customerId "c5" 'amount 75 'status "processing")))
    (define tesl_ignored_12 (insert-one! OrderItem (hash 'id "i1" 'orderId "o7" 'productName "Widget" 'quantity 3)))
    (define tesl_ignored_13 (insert-one! OrderItem (hash 'id "i2" 'orderId "ghost-order" 'productName "Gadget" 'quantity 1)))
    (define items (findOrderItemsByOrderId "o7"))
    (check-not-equal? items (list))
    )
  )

  (test-case "innerJoin with no matching customer returns empty list"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_14 (insert-one! Order (hash 'id "orphan1" 'customerId "missing-customer" 'amount 999 'status "new")))
    (define results (findOrderWithCustomer "missing-customer"))
    (check-equal? (raw-value results) (list))
    )
  )

)
