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
  (only-in tesl/tesl/db dbRead dbWrite)
)


(provide findOrderWithCustomer findOrdersByCustomerCountry cheapOrdersByCountry findOrderItemsByOrderId findOrderWithCustomer-signature findOrdersByCustomerCountry-signature cheapOrdersByCountry-signature findOrderItemsByOrderId-signature)

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" '(1 117 118 127 128 137 138 148 149))
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
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 117 (list (cons 'customerId *customerId)) (lambda () (call-with-database JoinDatabase (lambda () (select-many (from Order) (where (==. (entity-field-ref Order 'customerId) customerId)) (inner-join Customer (entity-field-ref Order 'customerId) (entity-field-ref Customer 'id))))))))

(define/pow
  (findOrdersByCustomerCountry [country : String])
  #:capabilities [dbRead]
  #:returns (List Order)
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 127 (list (cons 'country *country)) (lambda () (call-with-database JoinDatabase (lambda () (select-many (from Order) (where (==. (entity-field-ref Order 'status) "shipped")) (inner-join Customer (entity-field-ref Order 'customerId) (entity-field-ref Customer 'id))))))))

(define/pow
  (cheapOrdersByCountry [n : Integer])
  #:capabilities [dbRead]
  #:returns (List Order)
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 137 (list (cons 'n *n)) (lambda () (call-with-database JoinDatabase (lambda () (select-many (from Order) (inner-join Customer (entity-field-ref Order 'customerId) (entity-field-ref Customer 'id)) (order-by (entity-field-ref Order 'amount) 'asc) (limit 10)))))))

(define/pow
  (findOrderItemsByOrderId [orderId : String])
  #:capabilities [dbRead]
  #:returns (List OrderItem)
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 148 (list (cons 'orderId *orderId)) (lambda () (call-with-database JoinDatabase (lambda () (select-many (from OrderItem) (where (==. (entity-field-ref OrderItem 'orderId) orderId)) (inner-join Order (entity-field-ref OrderItem 'orderId) (entity-field-ref Order 'id))))))))

(module+ test
  (require rackunit)
  (test-case "innerJoin filters out orders with no matching customer"
    (call-with-fresh-memory-db (list JoinDatabase) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-0 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 160 (list) (lambda () (insert-one! Customer (tesl-hash 'id "c1" 'name "Alice" 'country "SE")))))
    (define tesl-ignored-1 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 161 (list) (lambda () (insert-one! Order (tesl-hash 'id "o1" 'customerId "c1" 'amount 50 'status "new")))))
    (define tesl-ignored-2 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 163 (list) (lambda () (insert-one! Order (tesl-hash 'id "o2" 'customerId "no-such-customer" 'amount 100 'status "new")))))
    (define results (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 165 (list) (lambda () (findOrderWithCustomer "c1"))))
    (check-not-equal? (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 166 (list (cons 'results results)) (lambda () results)) (list))
    )
    ))
  )

  (test-case "innerJoin returns only orders for the given customer"
    (call-with-fresh-memory-db (list JoinDatabase) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-3 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 171 (list) (lambda () (insert-one! Customer (tesl-hash 'id "c2" 'name "Bob" 'country "US")))))
    (define tesl-ignored-4 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 172 (list) (lambda () (insert-one! Customer (tesl-hash 'id "c3" 'name "Carol" 'country "UK")))))
    (define tesl-ignored-5 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 173 (list) (lambda () (insert-one! Order (tesl-hash 'id "o3" 'customerId "c2" 'amount 200 'status "shipped")))))
    (define tesl-ignored-6 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 174 (list) (lambda () (insert-one! Order (tesl-hash 'id "o4" 'customerId "c3" 'amount 300 'status "shipped")))))
    (define results (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 176 (list) (lambda () (findOrderWithCustomer "c2"))))
    (check-not-equal? (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 177 (list (cons 'results results)) (lambda () results)) (list))
    )
    ))
  )

  (test-case "cheapOrdersByCountry returns results when orders with customers exist"
    (call-with-fresh-memory-db (list JoinDatabase) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-7 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 182 (list) (lambda () (insert-one! Customer (tesl-hash 'id "c4" 'name "Dave" 'country "DE")))))
    (define tesl-ignored-8 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 183 (list) (lambda () (insert-one! Order (tesl-hash 'id "o5" 'customerId "c4" 'amount 10 'status "new")))))
    (define tesl-ignored-9 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 184 (list) (lambda () (insert-one! Order (tesl-hash 'id "o6" 'customerId "c4" 'amount 20 'status "new")))))
    (define results (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 186 (list) (lambda () (cheapOrdersByCountry 5))))
    (check-not-equal? (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 187 (list (cons 'results results)) (lambda () results)) (list))
    )
    ))
  )

  (test-case "findOrderItemsByOrderId uses innerJoin to filter items"
    (call-with-fresh-memory-db (list JoinDatabase) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-10 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 192 (list) (lambda () (insert-one! Customer (tesl-hash 'id "c5" 'name "Eve" 'country "FR")))))
    (define tesl-ignored-11 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 193 (list) (lambda () (insert-one! Order (tesl-hash 'id "o7" 'customerId "c5" 'amount 75 'status "processing")))))
    (define tesl-ignored-12 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 194 (list) (lambda () (insert-one! OrderItem (tesl-hash 'id "i1" 'orderId "o7" 'productName "Widget" 'quantity 3)))))
    (define tesl-ignored-13 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 196 (list) (lambda () (insert-one! OrderItem (tesl-hash 'id "i2" 'orderId "ghost-order" 'productName "Gadget" 'quantity 1)))))
    (define items (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 198 (list) (lambda () (findOrderItemsByOrderId "o7"))))
    (check-not-equal? (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 199 (list (cons 'items items)) (lambda () items)) (list))
    )
    ))
  )

  (test-case "innerJoin with no matching customer returns empty list"
    (call-with-fresh-memory-db (list JoinDatabase) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-14 (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 205 (list) (lambda () (insert-one! Order (tesl-hash 'id "orphan1" 'customerId "missing-customer" 'amount 999 'status "new")))))
    (define results (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 207 (list) (lambda () (findOrderWithCustomer "missing-customer"))))
    (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson48-sql-inner-join.tesl" 208 (list (cons 'results results)) (lambda () results))) (list))
    )
    ))
  )

)
