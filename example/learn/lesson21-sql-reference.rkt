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
  (let ([result (thsl-src! "example/learn/lesson21-sql-reference.tesl" 180 (list (cons 'id *id)) (lambda () (let ([tesl_match (select-one (from Product) (where (==. (entity-field-ref Product 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))))]) (thsl-src-control! "example/learn/lesson21-sql-reference.tesl" 181 (list (cons 'result *result) (cons 'id *id)) (lambda () (let ([tesl-case-0 (raw-value result)]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson21-sql-reference.tesl" 182 (list) (lambda () (reject "not found" #:http-code 404)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([p (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson21-sql-reference.tesl" 183 (list (cons 'p p)) (lambda () p)))]))))))

(define/pow
  (findByCategory [cat : String])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 189 (list (cons 'cat *cat)) (lambda () (select-many (from Product) (where (==. (entity-field-ref Product 'category) cat))))))

(define/pow
  (findCheapInCategory [cat : String] [maxAllowedPrice : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 196 (list (cons 'cat *cat) (cons 'maxAllowedPrice *maxAllowedPrice)) (lambda () (select-many (from Product) (where (==. (entity-field-ref Product 'category) cat)) (where (or. (<=. (entity-field-ref Product 'price) maxAllowedPrice) (>. (entity-field-ref Product 'price) 10)))))))

(define/pow
  (findFeatured [cat1 : String] [cat2 : String])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 202 (list (cons 'cat1 *cat1) (cons 'cat2 *cat2)) (lambda () (select-many (from Product) (where (or. (==. (entity-field-ref Product 'category) cat1) (==. (entity-field-ref Product 'category) cat2)))))))

(define/pow
  (cheapestProducts [n : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 209 (list (cons 'n *n)) (lambda () (select-many (from Product) (order-by (entity-field-ref Product 'price) 'asc) (limit 5)))))

(define/pow
  (createProduct [id : String] [name : String] [price : Integer] [category : String])
  #:capabilities [dbWrite]
  #:returns (? Product _entity ::: (FromDb (Id == id) _entity))
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 218 (list (cons 'id *id) (cons 'name *name) (cons 'price *price) (cons 'category *category)) (lambda () (insert-one! Product (hash 'id id 'name name 'price price 'category category 'inStock #t)))))

(define/pow
  (setPrice [id : String] [newPrice : Integer])
  #:capabilities [dbRead dbWrite]
  #:returns (? Product _entity ::: (FromDb (Id == id) _entity))
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 226 (list (cons 'id *id) (cons 'newPrice *newPrice)) (lambda () (car (update-many! (from Product) (hash (entity-field-ref Product 'price) newPrice (entity-field-ref Product 'category) "recently-updated") (where (==. (entity-field-ref Product 'id) id)))))))

(define/pow
  (updatePriceSilently [id : String] [newPrice : Integer])
  #:capabilities [dbRead dbWrite]
  #:returns Unit
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 237 (list (cons 'id *id) (cons 'newPrice *newPrice)) (lambda () (void (update-many! (from Product) (hash (entity-field-ref Product 'price) newPrice) (where (==. (entity-field-ref Product 'id) id)))))))

(define/pow
  (removeProduct [id : String])
  #:capabilities [dbWrite]
  #:returns Unit
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 245 (list (cons 'id *id)) (lambda () (delete-many! (from Product) (where (==. (entity-field-ref Product 'id) id))))))

(define/pow
  (removeProductWithResult [id : String])
  #:capabilities [dbWrite]
  #:returns DeleteResult
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 252 (list (cons 'id *id)) (lambda () (delete-many-with-count! (from Product) (where (==. (entity-field-ref Product 'id) id))))))

(define/pow
  (expensiveProducts [minAllowedPrice : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 259 (list (cons 'minAllowedPrice *minAllowedPrice)) (lambda () (select-many (from Product) (where (>. (entity-field-ref Product 'price) minAllowedPrice))))))

(define/pow
  (discounted [maxAllowedPrice : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 262 (list (cons 'maxAllowedPrice *maxAllowedPrice)) (lambda () (select-many (from Product) (where (<. (entity-field-ref Product 'price) maxAllowedPrice))))))

(define/pow
  (notInCategory [cat : String])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 265 (list (cons 'cat *cat)) (lambda () (select-many (from Product) (where (!=. (entity-field-ref Product 'category) cat))))))

(define/pow
  (createWithWitness [name : String] [price : Integer])
  #:capabilities [dbWrite]
  #:returns (Exists [pid : String] (? Product _entity ::: (FromDb (Id == pid) _entity)))
  (let ([pid (thsl-src! "example/learn/lesson21-sql-reference.tesl" 274 (list (cons 'name *name) (cons 'price *price)) (lambda () (format "~a-~a" (tesl-display-val *name) (tesl-display-val *price))))]) (thsl-src! "example/learn/lesson21-sql-reference.tesl" 275 (list (cons 'pid *pid) (cons 'name *name) (cons 'price *price)) (lambda () (pack ([pid]) (insert-one! Product (hash 'id pid 'name name 'price price 'category "default" 'inStock #t)))))))

(define/pow
  (batchCreate [products : (List Product)])
  #:capabilities [dbWrite]
  #:returns Unit
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 284 (list (cons 'products *products)) (lambda () (raw-value (insert-many! (from Product) products)))))

(define/pow
  (findInPriceRange [minP : Integer] [maxP : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 292 (list (cons 'minP *minP) (cons 'maxP *maxP)) (lambda () (select-many (from Product) (where (>=. (entity-field-ref Product 'price) minP)) (where (<=. (entity-field-ref Product 'price) maxP))))))

(define/pow
  (findInPriceRangeOrdered [minP : Integer] [maxP : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "" 1 (list (cons 'minP *minP) (cons 'maxP *maxP)) (lambda () (select-many (from Product) (where (>=. (entity-field-ref Product 'price) minP)) (where (<=. (entity-field-ref Product 'price) maxP)) (order-by (entity-field-ref Product 'price) 'asc)))))

(define/pow
  (upsertProduct [id : String] [name : String] [price : Integer])
  #:capabilities [dbWrite]
  #:returns Unit
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 307 (list (cons 'id *id) (cons 'name *name) (cons 'price *price)) (lambda () (raw-value (upsert-one! Product (hash 'id id 'name name 'price price 'category "general" 'inStock #t) '(id ) '(name price ))))))

(define/pow
  (searchByName [prefix : String])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "" 1 (list (cons 'prefix *prefix)) (lambda () (select-many (from Product) (where (like?. (entity-field-ref Product 'name) prefix))))))

(define/pow
  (searchByNameInsensitive [prefix : String])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "" 1 (list (cons 'prefix *prefix)) (lambda () (select-many (from Product) (where (ilike?. (entity-field-ref Product 'name) prefix))))))

(define/pow
  (countProducts)
  #:capabilities [dbRead]
  #:returns Integer
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 335 (list) (lambda () (select-count (from Product)))))

(define/pow
  (sumPrices)
  #:capabilities [dbRead]
  #:returns Integer
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 338 (list) (lambda () (select-sum (entity-field-ref Product 'price) (from Product)))))

(define/pow
  (maxPrice)
  #:capabilities [dbRead]
  #:returns Integer
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 341 (list) (lambda () (raw-value (select-max (entity-field-ref Product 'price) (from Product))))))

(define/pow
  (minPrice)
  #:capabilities [dbRead]
  #:returns Integer
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 344 (list) (lambda () (raw-value (select-min (entity-field-ref Product 'price) (from Product))))))

(define/pow
  (maxPriceInCategory [cat : String])
  #:capabilities [dbRead]
  #:returns Integer
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 348 (list (cons 'cat *cat)) (lambda () (select-max (entity-field-ref Product 'price) (from Product) (where (==. (entity-field-ref Product 'category) cat))))))

(define/pow
  (minPriceInCategory [cat : String])
  #:capabilities [dbRead]
  #:returns Integer
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 352 (list (cons 'cat *cat)) (lambda () (select-min (entity-field-ref Product 'price) (from Product) (where (==. (entity-field-ref Product 'category) cat))))))

(define/pow
  (countByCategory [cat : String])
  #:capabilities [dbRead]
  #:returns Integer
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 361 (list (cons 'cat *cat)) (lambda () (select-count (from Product) (where (==. (entity-field-ref Product 'category) cat))))))

(define/pow
  (findInStockCheap [maxAllowedPrice : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "" 1 (list (cons 'maxAllowedPrice *maxAllowedPrice)) (lambda () (select-many (from Product) (where (==. (entity-field-ref Product 'inStock) #t)) (where (<=. (entity-field-ref Product 'price) maxAllowedPrice)) (order-by (entity-field-ref Product 'price) 'asc)))))

(define/pow
  (findProductsWithCategory [minAllowedPrice : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 379 (list (cons 'minAllowedPrice *minAllowedPrice)) (lambda () (select-many (from Product) (where (>=. (entity-field-ref Product 'price) minAllowedPrice)) (inner-join Category (entity-field-ref Product 'category) (entity-field-ref Category 'id))))))

(define/pow
  (createProductWithCategory [id : String] [name : String] [price : Integer] [catId : String] [catLabel : String])
  #:capabilities [dbRead dbWrite]
  #:returns Product
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 408 (list (cons 'id *id) (cons 'name *name) (cons 'price *price) (cons 'catId *catId) (cons 'catLabel *catLabel)) (lambda () (call-with-queue-transaction (lambda () (let ([_ (insert-one! Category (hash 'id catId 'label catLabel 'active #t))]) (insert-one! Product (hash 'id id 'name name 'price price 'category catId 'inStock #t))))))))

(define/pow
  (swapStock [outId : String] [inId : String])
  #:capabilities [dbWrite]
  #:returns Unit
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 416 (list (cons 'outId *outId) (cons 'inId *inId)) (lambda () (call-with-queue-transaction (lambda () (let ([_ (void (update-many! (from Product) (hash (entity-field-ref Product 'inStock) #f) (where (==. (entity-field-ref Product 'id) outId))))]) (void (update-many! (from Product) (hash (entity-field-ref Product 'inStock) #t) (where (==. (entity-field-ref Product 'id) inId))))))))))

(module+ test
  (require rackunit)
  (test-case "findById returns named entity"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-1 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 446 (list) (lambda () (createProduct "p1" "Widget" 10 "tools"))))
    (define p (thsl-src! "example/learn/lesson21-sql-reference.tesl" 447 (list) (lambda () (findById "p1"))))
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 448 (list (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p 'name)))) "Widget")
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 449 (list (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p 'price)))) 10)
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 450 (list (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p 'category)))) "tools")
    )
  )

  (test-case "findByCategory returns matching rows"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-2 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 454 (list) (lambda () (createProduct "c1" "Hammer" 15 "tools"))))
    (define tesl-ignored-3 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 455 (list) (lambda () (createProduct "c2" "Nail" 2 "tools"))))
    (define tesl-ignored-4 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 456 (list) (lambda () (createProduct "c3" "Book" 20 "media"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 457 (list) (lambda () (findByCategory "tools"))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 458 (list (cons 'results results)) (lambda () results)) (list))
    )
  )

  (test-case "findCheapInCategory applies AND condition"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-5 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 462 (list) (lambda () (createProduct "a1" "Cheap Tool" 5 "tools"))))
    (define tesl-ignored-6 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 463 (list) (lambda () (createProduct "a2" "Expensive Tool" 50 "tools"))))
    (define cheap (thsl-src! "example/learn/lesson21-sql-reference.tesl" 464 (list) (lambda () (findCheapInCategory "tools" 10))))
    (define expensive (thsl-src! "example/learn/lesson21-sql-reference.tesl" 465 (list (cons 'cheap cheap)) (lambda () (findCheapInCategory "tools" 100))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 466 (list (cons 'expensive expensive) (cons 'cheap cheap)) (lambda () cheap)) (list))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 467 (list (cons 'expensive expensive) (cons 'cheap cheap)) (lambda () expensive)) (list))
    )
  )

  (test-case "findFeatured applies OR condition"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-7 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 471 (list) (lambda () (createProduct "f1" "Alpha" 10 "alpha"))))
    (define tesl-ignored-8 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 472 (list) (lambda () (createProduct "f2" "Beta" 10 "beta"))))
    (define tesl-ignored-9 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 473 (list) (lambda () (createProduct "f3" "Gamma" 10 "gamma"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 474 (list) (lambda () (findFeatured "alpha" "beta"))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 475 (list (cons 'results results)) (lambda () results)) (list))
    )
  )

  (test-case "setPrice updates the entity and returns it"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-10 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 479 (list) (lambda () (createProduct "u1" "Updatable" 100 "misc"))))
    (define updated (thsl-src! "example/learn/lesson21-sql-reference.tesl" 480 (list) (lambda () (setPrice "u1" 200))))
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 481 (list (cons 'updated updated)) (lambda () (raw-value (tesl-dot/runtime updated 'price)))) 200)
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 482 (list (cons 'updated updated)) (lambda () (raw-value (tesl-dot/runtime updated 'category)))) "recently-updated")
    )
  )

  (test-case "updatePriceSilently returns unit"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-11 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 486 (list) (lambda () (createProduct "us1" "Silent" 50 "misc"))))
    (define tesl-ignored-12 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 487 (list) (lambda () (updatePriceSilently "us1" 75))))
    (define found (thsl-src! "example/learn/lesson21-sql-reference.tesl" 488 (list) (lambda () (findById "us1"))))
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 489 (list (cons 'found found)) (lambda () (raw-value (tesl-dot/runtime found 'price)))) 75)
    )
  )

  (test-case "removeProduct deletes a row and returns unit"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-13 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 493 (list) (lambda () (createProduct "d1" "Deletable" 5 "misc"))))
    (define tesl-ignored-14 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 494 (list) (lambda () (removeProduct "d1"))))
    (define result (thsl-src! "example/learn/lesson21-sql-reference.tesl" 495 (list) (lambda () (let ([tesl_match (select-one (from Product) (where (==. (entity-field-ref Product 'id) "d1")))]) (if tesl_match (Something tesl_match) Nothing)))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson21-sql-reference.tesl" 496 (list (cons 'result result)) (lambda () result))) Nothing)
    )
  )

  (test-case "removeProductWithResult returns NoRowDeleted when not found"
    (with-capabilities (dbWrite)
    (define result (thsl-src! "example/learn/lesson21-sql-reference.tesl" 500 (list) (lambda () (removeProductWithResult "nonexistent-xyz"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson21-sql-reference.tesl" 501 (list (cons 'result result)) (lambda () result))) NoRowDeleted)
    )
  )

  (test-case "removeProductWithResult returns RowsDeleted when found"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-15 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 505 (list) (lambda () (createProduct "dr1" "ToDelete" 5 "misc"))))
    (define result (thsl-src! "example/learn/lesson21-sql-reference.tesl" 506 (list) (lambda () (removeProductWithResult "dr1"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson21-sql-reference.tesl" 507 (list (cons 'result result)) (lambda () result))) (raw-value (RowsDeleted 1)))
    )
  )

  (test-case "batchCreate inserts all products"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-16 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 511 (list) (lambda () (batchCreate (list (hash 'id "b1" 'name "Batch1" 'price 10 'category "batch" 'inStock #t) (hash 'id "b2" 'name "Batch2" 'price 20 'category "batch" 'inStock #t))))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 512 (list) (lambda () (findByCategory "batch"))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 513 (list (cons 'results results)) (lambda () results)) (list))
    )
  )

  (test-case "expensiveProducts filters by price"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-17 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 517 (list) (lambda () (createProduct "e1" "Pricey" 999 "luxury"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 518 (list) (lambda () (expensiveProducts 500))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 519 (list (cons 'results results)) (lambda () results)) (list))
    )
  )

  (test-case "findInPriceRange returns only rows in range"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-18 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 523 (list) (lambda () (createProduct "br1" "Cheap" 5 "misc"))))
    (define tesl-ignored-19 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 524 (list) (lambda () (createProduct "br2" "Mid" 25 "misc"))))
    (define tesl-ignored-20 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 525 (list) (lambda () (createProduct "br3" "Expensive" 100 "misc"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 526 (list) (lambda () (findInPriceRange 10 50))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 527 (list (cons 'results results)) (lambda () results)) (list))
    )
  )

  (test-case "findInPriceRangeOrdered returns ordered results"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-21 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 531 (list) (lambda () (createProduct "bro1" "Budget" 15 "misc"))))
    (define tesl-ignored-22 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 532 (list) (lambda () (createProduct "bro2" "Premium" 45 "misc"))))
    (define tesl-ignored-23 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 533 (list) (lambda () (createProduct "bro3" "TooExpensive" 200 "misc"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 534 (list) (lambda () (findInPriceRangeOrdered 10 50))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 535 (list (cons 'results results)) (lambda () results)) (list))
    )
  )

  (test-case "upsertProduct inserts when row does not exist"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-24 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 539 (list) (lambda () (upsertProduct "up1" "NewProduct" 42))))
    (define found (thsl-src! "example/learn/lesson21-sql-reference.tesl" 540 (list) (lambda () (findById "up1"))))
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 541 (list (cons 'found found)) (lambda () (raw-value (tesl-dot/runtime found 'name)))) "NewProduct")
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 542 (list (cons 'found found)) (lambda () (raw-value (tesl-dot/runtime found 'price)))) 42)
    )
  )

  (test-case "upsertProduct updates when row already exists"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-25 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 546 (list) (lambda () (upsertProduct "up2" "Original" 10))))
    (define tesl-ignored-26 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 547 (list) (lambda () (upsertProduct "up2" "Updated" 99))))
    (define found (thsl-src! "example/learn/lesson21-sql-reference.tesl" 548 (list) (lambda () (findById "up2"))))
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 549 (list (cons 'found found)) (lambda () (raw-value (tesl-dot/runtime found 'name)))) "Updated")
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 550 (list (cons 'found found)) (lambda () (raw-value (tesl-dot/runtime found 'price)))) 99)
    )
  )

  (test-case "searchByName with like pattern matches prefix"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-27 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 554 (list) (lambda () (createProduct "lk1" "Widget Pro" 50 "tools"))))
    (define tesl-ignored-28 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 555 (list) (lambda () (createProduct "lk2" "Gadget" 30 "tools"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 556 (list) (lambda () (searchByName "Widget%"))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 557 (list (cons 'results results)) (lambda () results)) (list))
    )
  )

  (test-case "searchByNameInsensitive with ilike is case-insensitive"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-29 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 561 (list) (lambda () (createProduct "ilk1" "WidgetX" 50 "tools"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 562 (list) (lambda () (searchByNameInsensitive "widget%"))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 563 (list (cons 'results results)) (lambda () results)) (list))
    )
  )

  (test-case "countProducts returns total count"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-30 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 567 (list) (lambda () (createProduct "cnt1" "CountMe1" 10 "count-test"))))
    (define tesl-ignored-31 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 568 (list) (lambda () (createProduct "cnt2" "CountMe2" 20 "count-test"))))
    (define n (thsl-src! "example/learn/lesson21-sql-reference.tesl" 569 (list) (lambda () (countProducts))))
    (check-true (thsl-src! "example/learn/lesson21-sql-reference.tesl" 570 (list (cons 'n n)) (lambda () (> (raw-value n) 0))))
    )
  )

  (test-case "sumPrices returns non-negative sum"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-32 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 574 (list) (lambda () (createProduct "sum1" "SumMe1" 10 "sum-test"))))
    (define tesl-ignored-33 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 575 (list) (lambda () (createProduct "sum2" "SumMe2" 20 "sum-test"))))
    (define total (thsl-src! "example/learn/lesson21-sql-reference.tesl" 576 (list) (lambda () (sumPrices))))
    (check-true (thsl-src! "example/learn/lesson21-sql-reference.tesl" 577 (list (cons 'total total)) (lambda () (> (raw-value total) 0))))
    )
  )

  (test-case "findInStockCheap filters on multiple conditions"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-34 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 581 (list) (lambda () (createProduct "is1" "Cheap In Stock" 5 "misc"))))
    (define tesl-ignored-35 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 582 (list) (lambda () (createProduct "is2" "Expensive In Stock" 500 "misc"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 583 (list) (lambda () (findInStockCheap 50))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 584 (list (cons 'results results)) (lambda () results)) (list))
    )
  )

  (test-case "findProductsWithCategory uses innerJoin to filter"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-36 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 588 (list) (lambda () (insert-one! Category (hash 'id "tools" 'label "Tools" 'active #t)))))
    (define tesl-ignored-37 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 589 (list) (lambda () (createProduct "ij1" "Hammer" 15 "tools"))))
    (define tesl-ignored-38 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 591 (list) (lambda () (createProduct "ij2" "Phantom" 10 "nonexistent-cat"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 592 (list) (lambda () (findProductsWithCategory 1))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 593 (list (cons 'results results)) (lambda () results)) (list))
    )
  )

  (test-case "createProductWithCategory inserts both atomically"
    (with-capabilities (dbRead dbWrite)
    (define p (thsl-src! "example/learn/lesson21-sql-reference.tesl" 597 (list) (lambda () (createProductWithCategory "txp1" "Transactional Widget" 30 "tx-cat" "TX Category"))))
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 598 (list (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p 'name)))) "Transactional Widget")
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 599 (list (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p 'price)))) 30)
    (define cats (thsl-src! "example/learn/lesson21-sql-reference.tesl" 601 (list (cons 'p p)) (lambda () (select-many (from Category) (where (==. (entity-field-ref Category 'id) "tx-cat"))))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 602 (list (cons 'cats cats) (cons 'p p)) (lambda () cats)) (list))
    )
  )

  (test-case "swapStock updates two rows atomically"
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-39 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 606 (list) (lambda () (createProduct "swap1" "SwapOut" 10 "misc"))))
    (define tesl-ignored-40 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 607 (list) (lambda () (createProduct "swap2" "SwapIn" 20 "misc"))))
    (define tesl-ignored-41 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 609 (list) (lambda () (swapStock "swap1" "swap2"))))
    (define outRows (thsl-src! "example/learn/lesson21-sql-reference.tesl" 611 (list) (lambda () (select-many (from Product) (where (==. (entity-field-ref Product 'id) "swap1"))))))
    (define inRows (thsl-src! "example/learn/lesson21-sql-reference.tesl" 612 (list (cons 'outRows outRows)) (lambda () (select-many (from Product) (where (==. (entity-field-ref Product 'id) "swap2"))))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 613 (list (cons 'inRows inRows) (cons 'outRows outRows)) (lambda () outRows)) (list))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 614 (list (cons 'inRows inRows) (cons 'outRows outRows)) (lambda () inRows)) (list))
    )
  )

)
