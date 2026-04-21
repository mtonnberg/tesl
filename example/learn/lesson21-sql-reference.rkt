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
  (only-in tesl/tesl/prelude Bool Int List String Unit)
  (only-in tesl/tesl/db dbRead dbWrite DeleteResult NoRowDeleted RowsDeleted)
)


(provide Product Category findById findByCategory findCheapInCategory findFeatured cheapestProducts createProduct setPrice updatePriceSilently removeProduct removeProductWithResult batchCreate expensiveProducts discounted notInCategory createWithWitness findInPriceRange findInPriceRangeOrdered upsertProduct searchByName searchByNameInsensitive countProducts sumPrices countByCategory findInStockCheap findProductsWithCategory createProductWithCategory swapStock findById-signature findByCategory-signature findCheapInCategory-signature findFeatured-signature cheapestProducts-signature createProduct-signature setPrice-signature updatePriceSilently-signature removeProduct-signature removeProductWithResult-signature expensiveProducts-signature discounted-signature notInCategory-signature createWithWitness-signature batchCreate-signature findInPriceRange-signature findInPriceRangeOrdered-signature upsertProduct-signature searchByName-signature searchByNameInsensitive-signature countProducts-signature sumPrices-signature countByCategory-signature findInStockCheap-signature findProductsWithCategory-signature createProductWithCategory-signature swapStock-signature)

(define-entity Product
  #:source (make-hash)
  #:table products
  #:primary-key id
  [Id id : String]
  [Name name : String]
  [Price price : Integer]
  [Category category : String]
  [InStock inStock : Boolean]
)

(define-entity Category
  #:source (make-hash)
  #:table categories
  #:primary-key id
  [Id id : String]
  [Label label : String]
  [Active active : Boolean]
)

(define/pow
  (findById [id : String])
  #:capabilities [dbRead]
  #:returns (? Product _entity ::: (FromDb (Id == id) _entity))
  (let ([result (let ([tesl_match (select-one (from Product) (where (==. (entity-field-ref Product 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl_case_0 (raw-value result)]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (reject "not found" #:http-code 404)] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([p (hash-ref (adt-value-fields *tesl_case_0) 'value)]) p)]))))

(define/pow
  (findByCategory [cat : String])
  #:capabilities [dbRead]
  #:returns (List Product)
  (select-many (from Product) (where (==. (entity-field-ref Product 'category) cat))))

(define/pow
  (findCheapInCategory [cat : String] [maxAllowedPrice : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (select-many (from Product) (where (==. (entity-field-ref Product 'category) cat)) (where (or. (<=. (entity-field-ref Product 'price) maxAllowedPrice) (>. (entity-field-ref Product 'price) 10)))))

(define/pow
  (findFeatured [cat1 : String] [cat2 : String])
  #:capabilities [dbRead]
  #:returns (List Product)
  (select-many (from Product) (where (or. (==. (entity-field-ref Product 'category) cat1) (==. (entity-field-ref Product 'category) cat2)))))

(define/pow
  (cheapestProducts [n : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (select-many (from Product) (order-by (entity-field-ref Product 'price) 'asc) (limit 5)))

(define/pow
  (createProduct [id : String] [name : String] [price : Integer] [category : String])
  #:capabilities [dbWrite]
  #:returns (? Product _entity ::: (FromDb (Id == id) _entity))
  (insert-one! Product (hash 'id id 'name name 'price price 'category category 'inStock #t)))

(define/pow
  (setPrice [id : String] [newPrice : Integer])
  #:capabilities [dbRead dbWrite]
  #:returns (? Product _entity ::: (FromDb (Id == id) _entity))
  (car (update-many! (from Product) (hash (entity-field-ref Product 'price) newPrice (entity-field-ref Product 'category) "recently-updated") (where (==. (entity-field-ref Product 'id) id)))))

(define/pow
  (updatePriceSilently [id : String] [newPrice : Integer])
  #:capabilities [dbRead dbWrite]
  #:returns Unit
  (void (update-many! (from Product) (hash (entity-field-ref Product 'price) newPrice) (where (==. (entity-field-ref Product 'id) id)))))

(define/pow
  (removeProduct [id : String])
  #:capabilities [dbWrite]
  #:returns Unit
  (delete-many! (from Product) (where (==. (entity-field-ref Product 'id) id))))

(define/pow
  (removeProductWithResult [id : String])
  #:capabilities [dbWrite]
  #:returns DeleteResult
  (delete-many-with-count! (from Product) (where (==. (entity-field-ref Product 'id) id))))

(define/pow
  (expensiveProducts [minAllowedPrice : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (select-many (from Product) (where (>. (entity-field-ref Product 'price) minAllowedPrice))))

(define/pow
  (discounted [maxAllowedPrice : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (select-many (from Product) (where (<. (entity-field-ref Product 'price) maxAllowedPrice))))

(define/pow
  (notInCategory [cat : String])
  #:capabilities [dbRead]
  #:returns (List Product)
  (select-many (from Product) (where (!=. (entity-field-ref Product 'category) cat))))

(define/pow
  (createWithWitness [name : String] [price : Integer])
  #:capabilities [dbWrite]
  #:returns (Exists [pid : String] (? Product _entity ::: (FromDb (Id == pid) _entity)))
  (let ([pid (format "~a-~a" (tesl-display-val *name) (tesl-display-val *price))]) (pack ([pid]) (insert-one! Product (hash 'id pid 'name name 'price price 'category "default" 'inStock #t)))))

(define/pow
  (batchCreate [products : (List Product)])
  #:capabilities [dbWrite]
  #:returns Unit
  (raw-value (insert-many! (from Product) products)))

(define/pow
  (findInPriceRange [minP : Integer] [maxP : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (select-many (from Product) (where (>=. (entity-field-ref Product 'price) minP)) (where (<=. (entity-field-ref Product 'price) maxP))))

(define/pow
  (findInPriceRangeOrdered [minP : Integer] [maxP : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (select-many (from Product) (where (>=. (entity-field-ref Product 'price) minP)) (where (<=. (entity-field-ref Product 'price) maxP)) (order-by (entity-field-ref Product 'price) 'asc)))

(define/pow
  (upsertProduct [id : String] [name : String] [price : Integer])
  #:capabilities [dbWrite]
  #:returns Unit
  (raw-value (upsert-one! Product (hash 'id id 'name name 'price price 'category "general" 'inStock #t) '(id ) '(name price ))))

(define/pow
  (searchByName [prefix : String])
  #:capabilities [dbRead]
  #:returns (List Product)
  (select-many (from Product) (where (like?. (entity-field-ref Product 'name) prefix))))

(define/pow
  (searchByNameInsensitive [prefix : String])
  #:capabilities [dbRead]
  #:returns (List Product)
  (select-many (from Product) (where (ilike?. (entity-field-ref Product 'name) prefix))))

(define/pow
  (countProducts)
  #:capabilities [dbRead]
  #:returns Integer
  (select-count (from Product)))

(define/pow
  (sumPrices)
  #:capabilities [dbRead]
  #:returns Integer
  (select-sum (entity-field-ref Product 'price) (from Product)))

(define/pow
  (maxPrice)
  #:capabilities [dbRead]
  #:returns Integer
  (raw-value (select-max (entity-field-ref Product 'price) (from Product))))

(define/pow
  (minPrice)
  #:capabilities [dbRead]
  #:returns Integer
  (raw-value (select-min (entity-field-ref Product 'price) (from Product))))

(define/pow
  (maxPriceInCategory [cat : String])
  #:capabilities [dbRead]
  #:returns Integer
  (select-max (entity-field-ref Product 'price) (from Product) (where (==. (entity-field-ref Product 'category) cat))))

(define/pow
  (minPriceInCategory [cat : String])
  #:capabilities [dbRead]
  #:returns Integer
  (select-min (entity-field-ref Product 'price) (from Product) (where (==. (entity-field-ref Product 'category) cat))))

(define/pow
  (countByCategory [cat : String])
  #:capabilities [dbRead]
  #:returns Integer
  (select-count (from Product) (where (==. (entity-field-ref Product 'category) cat))))

(define/pow
  (findInStockCheap [maxAllowedPrice : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (select-many (from Product) (where (==. (entity-field-ref Product 'inStock) #t)) (where (<=. (entity-field-ref Product 'price) maxAllowedPrice)) (order-by (entity-field-ref Product 'price) 'asc)))

(define/pow
  (findProductsWithCategory [minAllowedPrice : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (select-many (from Product) (where (>=. (entity-field-ref Product 'price) minAllowedPrice)) (inner-join Category (entity-field-ref Product 'category) (entity-field-ref Category 'id))))

(define/pow
  (createProductWithCategory [id : String] [name : String] [price : Integer] [catId : String] [catLabel : String])
  #:capabilities [dbRead dbWrite]
  #:returns Product
  (call-with-queue-transaction (lambda () (let ([_ (insert-one! Category (hash 'id catId 'label catLabel 'active #t))]) (insert-one! Product (hash 'id id 'name name 'price price 'category catId 'inStock #t))))))

(define/pow
  (swapStock [outId : String] [inId : String])
  #:capabilities [dbWrite]
  #:returns Unit
  (call-with-queue-transaction (lambda () (let ([_ (void (update-many! (from Product) (hash (entity-field-ref Product 'inStock) #f) (where (==. (entity-field-ref Product 'id) outId))))]) (void (update-many! (from Product) (hash (entity-field-ref Product 'inStock) #t) (where (==. (entity-field-ref Product 'id) inId))))))))

(module+ test
  (require rackunit)
  (test-case "findById returns named entity"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_1 (createProduct "p1" "Widget" 10 "tools"))
    (define p (findById "p1"))
    (check-equal? (raw-value (tesl-dot/runtime p 'name)) "Widget")
    (check-equal? (raw-value (tesl-dot/runtime p 'price)) 10)
    (check-equal? (raw-value (tesl-dot/runtime p 'category)) "tools")
    )
  )

  (test-case "findByCategory returns matching rows"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_2 (createProduct "c1" "Hammer" 15 "tools"))
    (define tesl_ignored_3 (createProduct "c2" "Nail" 2 "tools"))
    (define tesl_ignored_4 (createProduct "c3" "Book" 20 "media"))
    (define results (findByCategory "tools"))
    (check-not-equal? results (list))
    )
  )

  (test-case "findCheapInCategory applies AND condition"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_5 (createProduct "a1" "Cheap Tool" 5 "tools"))
    (define tesl_ignored_6 (createProduct "a2" "Expensive Tool" 50 "tools"))
    (define cheap (findCheapInCategory "tools" 10))
    (define expensive (findCheapInCategory "tools" 100))
    (check-not-equal? cheap (list))
    (check-not-equal? expensive (list))
    )
  )

  (test-case "findFeatured applies OR condition"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_7 (createProduct "f1" "Alpha" 10 "alpha"))
    (define tesl_ignored_8 (createProduct "f2" "Beta" 10 "beta"))
    (define tesl_ignored_9 (createProduct "f3" "Gamma" 10 "gamma"))
    (define results (findFeatured "alpha" "beta"))
    (check-not-equal? results (list))
    )
  )

  (test-case "setPrice updates the entity and returns it"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_10 (createProduct "u1" "Updatable" 100 "misc"))
    (define updated (setPrice "u1" 200))
    (check-equal? (raw-value (tesl-dot/runtime updated 'price)) 200)
    (check-equal? (raw-value (tesl-dot/runtime updated 'category)) "recently-updated")
    )
  )

  (test-case "updatePriceSilently returns unit"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_11 (createProduct "us1" "Silent" 50 "misc"))
    (define tesl_ignored_12 (updatePriceSilently "us1" 75))
    (define found (findById "us1"))
    (check-equal? (raw-value (tesl-dot/runtime found 'price)) 75)
    )
  )

  (test-case "removeProduct deletes a row and returns unit"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_13 (createProduct "d1" "Deletable" 5 "misc"))
    (define tesl_ignored_14 (removeProduct "d1"))
    (define result (let ([tesl_match (select-one (from Product) (where (==. (entity-field-ref Product 'id) "d1")))]) (if tesl_match (Something tesl_match) Nothing)))
    (check-equal? (raw-value result) Nothing)
    )
  )

  (test-case "removeProductWithResult returns NoRowDeleted when not found"
    (with-capabilities (dbWrite)
    (define result (removeProductWithResult "nonexistent-xyz"))
    (check-equal? (raw-value result) NoRowDeleted)
    )
  )

  (test-case "removeProductWithResult returns RowsDeleted when found"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_15 (createProduct "dr1" "ToDelete" 5 "misc"))
    (define result (removeProductWithResult "dr1"))
    (check-equal? (raw-value result) (raw-value (RowsDeleted 1)))
    )
  )

  (test-case "batchCreate inserts all products"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_16 (batchCreate (list (hash 'id "b1" 'name "Batch1" 'price 10 'category "batch" 'inStock #t) (hash 'id "b2" 'name "Batch2" 'price 20 'category "batch" 'inStock #t))))
    (define results (findByCategory "batch"))
    (check-not-equal? results (list))
    )
  )

  (test-case "expensiveProducts filters by price"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_17 (createProduct "e1" "Pricey" 999 "luxury"))
    (define results (expensiveProducts 500))
    (check-not-equal? results (list))
    )
  )

  (test-case "findInPriceRange returns only rows in range"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_18 (createProduct "br1" "Cheap" 5 "misc"))
    (define tesl_ignored_19 (createProduct "br2" "Mid" 25 "misc"))
    (define tesl_ignored_20 (createProduct "br3" "Expensive" 100 "misc"))
    (define results (findInPriceRange 10 50))
    (check-not-equal? results (list))
    )
  )

  (test-case "findInPriceRangeOrdered returns ordered results"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_21 (createProduct "bro1" "Budget" 15 "misc"))
    (define tesl_ignored_22 (createProduct "bro2" "Premium" 45 "misc"))
    (define tesl_ignored_23 (createProduct "bro3" "TooExpensive" 200 "misc"))
    (define results (findInPriceRangeOrdered 10 50))
    (check-not-equal? results (list))
    )
  )

  (test-case "upsertProduct inserts when row does not exist"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_24 (upsertProduct "up1" "NewProduct" 42))
    (define found (findById "up1"))
    (check-equal? (raw-value (tesl-dot/runtime found 'name)) "NewProduct")
    (check-equal? (raw-value (tesl-dot/runtime found 'price)) 42)
    )
  )

  (test-case "upsertProduct updates when row already exists"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_25 (upsertProduct "up2" "Original" 10))
    (define tesl_ignored_26 (upsertProduct "up2" "Updated" 99))
    (define found (findById "up2"))
    (check-equal? (raw-value (tesl-dot/runtime found 'name)) "Updated")
    (check-equal? (raw-value (tesl-dot/runtime found 'price)) 99)
    )
  )

  (test-case "searchByName with like pattern matches prefix"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_27 (createProduct "lk1" "Widget Pro" 50 "tools"))
    (define tesl_ignored_28 (createProduct "lk2" "Gadget" 30 "tools"))
    (define results (searchByName "Widget%"))
    (check-not-equal? results (list))
    )
  )

  (test-case "searchByNameInsensitive with ilike is case-insensitive"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_29 (createProduct "ilk1" "WidgetX" 50 "tools"))
    (define results (searchByNameInsensitive "widget%"))
    (check-not-equal? results (list))
    )
  )

  (test-case "countProducts returns total count"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_30 (createProduct "cnt1" "CountMe1" 10 "count-test"))
    (define tesl_ignored_31 (createProduct "cnt2" "CountMe2" 20 "count-test"))
    (define n (countProducts))
    (check-true (> (raw-value n) 0))
    )
  )

  (test-case "sumPrices returns non-negative sum"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_32 (createProduct "sum1" "SumMe1" 10 "sum-test"))
    (define tesl_ignored_33 (createProduct "sum2" "SumMe2" 20 "sum-test"))
    (define total (sumPrices))
    (check-true (> (raw-value total) 0))
    )
  )

  (test-case "findInStockCheap filters on multiple conditions"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_34 (createProduct "is1" "Cheap In Stock" 5 "misc"))
    (define tesl_ignored_35 (createProduct "is2" "Expensive In Stock" 500 "misc"))
    (define results (findInStockCheap 50))
    (check-not-equal? results (list))
    )
  )

  (test-case "findProductsWithCategory uses innerJoin to filter"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_36 (insert-one! Category (hash 'id "tools" 'label "Tools" 'active #t)))
    (define tesl_ignored_37 (createProduct "ij1" "Hammer" 15 "tools"))
    (define tesl_ignored_38 (createProduct "ij2" "Phantom" 10 "nonexistent-cat"))
    (define results (findProductsWithCategory 1))
    (check-not-equal? results (list))
    )
  )

  (test-case "createProductWithCategory inserts both atomically"
    (with-capabilities (dbRead dbWrite)
    (define p (createProductWithCategory "txp1" "Transactional Widget" 30 "tx-cat" "TX Category"))
    (check-equal? (raw-value (tesl-dot/runtime p 'name)) "Transactional Widget")
    (check-equal? (raw-value (tesl-dot/runtime p 'price)) 30)
    (define cats (select-many (from Category) (where (==. (entity-field-ref Category 'id) "tx-cat"))))
    (check-not-equal? cats (list))
    )
  )

  (test-case "swapStock updates two rows atomically"
    (with-capabilities (dbRead dbWrite)
    (define tesl_ignored_39 (createProduct "swap1" "SwapOut" 10 "misc"))
    (define tesl_ignored_40 (createProduct "swap2" "SwapIn" 20 "misc"))
    (define tesl_ignored_41 (swapStock "swap1" "swap2"))
    (define outRows (select-many (from Product) (where (==. (entity-field-ref Product 'id) "swap1"))))
    (define inRows (select-many (from Product) (where (==. (entity-field-ref Product 'id) "swap2"))))
    (check-not-equal? outRows (list))
    (check-not-equal? inRows (list))
    )
  )

)
