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
  (prefix-in __ttz_ (only-in tesl/tesl/time tesl-tz-utc tesl-tz-fixed tesl-tz-named))
  (only-in tesl/tesl/prelude Bool Int List String Unit)
  (only-in tesl/tesl/tuple Tuple2)
  (only-in tesl/tesl/list [List.length tesl_import_List_length])
  (only-in tesl/tesl/time PosixMillis [Time.secondsToPosix tesl_import_Time_secondsToPosix] [Time.truncDay tesl_import_Time_truncDay] [Time.truncWeek tesl_import_Time_truncWeek] [Time.truncMonth tesl_import_Time_truncMonth] [Time.offsetAt tesl_import_Time_offsetAt] TimeZone addMs)
  (only-in tesl/tesl/db dbRead dbWrite DeleteResult NoRowDeleted RowsDeleted)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
)


(provide Product Category findById findByCategory findCheapInCategory findFeatured cheapestProducts createProduct setPrice updatePriceSilently removeProduct removeProductWithResult batchCreate expensiveProducts discounted notInCategory createWithWitness findInPriceRange findInPriceRangeOrdered upsertProduct upsertProductByName searchByName searchByNameInsensitive countProducts sumPrices countByCategory findInStockCheap findProductsWithCategory createProductWithCategory swapStock findById-signature findByCategory-signature findCheapInCategory-signature findFeatured-signature cheapestProducts-signature createProduct-signature setPrice-signature updatePriceSilently-signature removeProduct-signature removeProductWithResult-signature expensiveProducts-signature discounted-signature notInCategory-signature createWithWitness-signature batchCreate-signature findInPriceRange-signature findInPriceRangeOrdered-signature upsertProduct-signature upsertProductByName-signature searchByName-signature searchByNameInsensitive-signature countProducts-signature sumPrices-signature countByCategory-signature findInStockCheap-signature findProductsWithCategory-signature createProductWithCategory-signature swapStock-signature)

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "example/learn/lesson21-sql-reference.tesl" '(1 214 223 230 236 243 293 296 299 326 330 363 367 379 382 388 391 394 398 419 423 457 464 476 483 487 492 504 622 687 743 753 754))
(define-entity Product
  #:source (make-hash)
  #:table products
  #:primary-key id
  #:indexes ((plain (category price) #f) (unique (name) #f) (plain (inStock) "products_in_stock_idx"))
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
  (let ([result (thsl-src! "example/learn/lesson21-sql-reference.tesl" 214 (list (cons 'id *id)) (lambda () (let ([tesl_match (select-one (from Product) (where (==. (entity-field-ref Product 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))) 'result)]) (thsl-src-control! "example/learn/lesson21-sql-reference.tesl" 215 (list (cons 'result *result) (cons 'id *id)) (lambda () (let ([tesl-case-0 (raw-value result)]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson21-sql-reference.tesl" 216 (list) (lambda () (reject "not found" #:http-code 404)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([p (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson21-sql-reference.tesl" 217 (list (cons 'p p)) (lambda () p)))]))))))

(define/pow
  (findByCategory [cat : String])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 223 (list (cons 'cat *cat)) (lambda () (select-many (from Product) (where (==. (entity-field-ref Product 'category) cat))))))

(define/pow
  (findCheapInCategory [cat : String] [maxAllowedPrice : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 230 (list (cons 'cat *cat) (cons 'maxAllowedPrice *maxAllowedPrice)) (lambda () (select-many (from Product) (where (==. (entity-field-ref Product 'category) cat)) (where (or. (<=. (entity-field-ref Product 'price) maxAllowedPrice) (>. (entity-field-ref Product 'price) 10)))))))

(define/pow
  (findFeatured [cat1 : String] [cat2 : String])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 236 (list (cons 'cat1 *cat1) (cons 'cat2 *cat2)) (lambda () (select-many (from Product) (where (or. (==. (entity-field-ref Product 'category) cat1) (==. (entity-field-ref Product 'category) cat2)))))))

(define/pow
  (cheapestProducts [n : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 243 (list (cons 'n *n)) (lambda () (select-many (from Product) (order-by (entity-field-ref Product 'price) 'asc) (limit 5)))))

(define/pow
  (createProduct [id : String] [name : String] [price : Integer] [category : String])
  #:capabilities [dbWrite]
  #:returns (? Product _entity ::: (FromDb (Id == id) _entity))
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 252 (list (cons 'id *id) (cons 'name *name) (cons 'price *price) (cons 'category *category)) (lambda () (insert-one! Product (tesl-hash 'id id 'name name 'price price 'category category 'inStock #t)))))

(define/pow
  (setPrice [id : String] [newPrice : Integer])
  #:capabilities [dbRead dbWrite]
  #:returns (? Product _entity ::: (FromDb (Id == id) _entity))
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 260 (list (cons 'id *id) (cons 'newPrice *newPrice)) (lambda () (car (update-many! (from Product) (tesl-hash (entity-field-ref Product 'price) newPrice (entity-field-ref Product 'category) "recently-updated") (where (==. (entity-field-ref Product 'id) id)))))))

(define/pow
  (updatePriceSilently [id : String] [newPrice : Integer])
  #:capabilities [dbRead dbWrite]
  #:returns Unit
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 271 (list (cons 'id *id) (cons 'newPrice *newPrice)) (lambda () (void (update-many! (from Product) (tesl-hash (entity-field-ref Product 'price) newPrice) (where (==. (entity-field-ref Product 'id) id)))))))

(define/pow
  (removeProduct [id : String])
  #:capabilities [dbWrite]
  #:returns Unit
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 279 (list (cons 'id *id)) (lambda () (delete-many! (from Product) (where (==. (entity-field-ref Product 'id) id))))))

(define/pow
  (removeProductWithResult [id : String])
  #:capabilities [dbWrite]
  #:returns DeleteResult
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 286 (list (cons 'id *id)) (lambda () (delete-many-with-count! (from Product) (where (==. (entity-field-ref Product 'id) id))))))

(define/pow
  (expensiveProducts [minAllowedPrice : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 293 (list (cons 'minAllowedPrice *minAllowedPrice)) (lambda () (select-many (from Product) (where (>. (entity-field-ref Product 'price) minAllowedPrice))))))

(define/pow
  (discounted [maxAllowedPrice : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 296 (list (cons 'maxAllowedPrice *maxAllowedPrice)) (lambda () (select-many (from Product) (where (<. (entity-field-ref Product 'price) maxAllowedPrice))))))

(define/pow
  (notInCategory [cat : String])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 299 (list (cons 'cat *cat)) (lambda () (select-many (from Product) (where (!=. (entity-field-ref Product 'category) cat))))))

(define/pow
  (createWithWitness [name : String] [price : Integer])
  #:capabilities [dbWrite]
  #:returns (Exists [pid : String] (? Product _entity ::: (FromDb (Id == pid) _entity)))
  (let ([pid (thsl-src! "example/learn/lesson21-sql-reference.tesl" 308 (list (cons 'name *name) (cons 'price *price)) (lambda () (format "~a-~a" (tesl-display-val *name) (tesl-display-val *price))))]) (thsl-src! "example/learn/lesson21-sql-reference.tesl" 309 (list (cons 'pid *pid) (cons 'name *name) (cons 'price *price)) (lambda () (pack ([pid]) (insert-one! Product (tesl-hash 'id pid 'name name 'price price 'category "default" 'inStock #t)))))))

(define/pow
  (batchCreate [products : (List Product)])
  #:capabilities [dbWrite]
  #:returns Unit
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 318 (list (cons 'products *products)) (lambda () (raw-value (insert-many! (from Product) products)))))

(define/pow
  (findInPriceRange [minP : Integer] [maxP : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 326 (list (cons 'minP *minP) (cons 'maxP *maxP)) (lambda () (select-many (from Product) (where (>=. (entity-field-ref Product 'price) minP)) (where (<=. (entity-field-ref Product 'price) maxP))))))

(define/pow
  (findInPriceRangeOrdered [minP : Integer] [maxP : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "" 1 (list (cons 'minP *minP) (cons 'maxP *maxP)) (lambda () (select-many (from Product) (where (>=. (entity-field-ref Product 'price) minP)) (where (<=. (entity-field-ref Product 'price) maxP)) (order-by (entity-field-ref Product 'price) 'asc)))))

(define/pow
  (upsertProduct [id : String] [name : String] [price : Integer])
  #:capabilities [dbWrite]
  #:returns Unit
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 346 (list (cons 'id *id) (cons 'name *name) (cons 'price *price)) (lambda () (raw-value (upsert-one! Product (tesl-hash 'id id 'name name 'price price 'category "general" 'inStock #t) '(id ) '(name price ))))))

(define/pow
  (upsertProductByName [id : String] [name : String] [price : Integer])
  #:capabilities [dbWrite]
  #:returns Unit
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 351 (list (cons 'id *id) (cons 'name *name) (cons 'price *price)) (lambda () (raw-value (upsert-one! Product (tesl-hash 'id id 'name name 'price price 'category "general" 'inStock #t) '(name ) '(price ))))))

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
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 379 (list) (lambda () (select-count (from Product)))))

(define/pow
  (sumPrices)
  #:capabilities [dbRead]
  #:returns Integer
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 382 (list) (lambda () (select-sum (entity-field-ref Product 'price) (from Product)))))

(define/pow
  (maxPrice)
  #:capabilities [dbRead]
  #:returns (Maybe Integer)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 388 (list) (lambda () (raw-value (select-max (entity-field-ref Product 'price) (from Product))))))

(define/pow
  (minPrice)
  #:capabilities [dbRead]
  #:returns (Maybe Integer)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 391 (list) (lambda () (raw-value (select-min (entity-field-ref Product 'price) (from Product))))))

(define/pow
  (maxPriceInCategory [cat : String])
  #:capabilities [dbRead]
  #:returns (Maybe Integer)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 395 (list (cons 'cat *cat)) (lambda () (select-max (entity-field-ref Product 'price) (from Product) (where (==. (entity-field-ref Product 'category) cat))))))

(define/pow
  (minPriceInCategory [cat : String])
  #:capabilities [dbRead]
  #:returns (Maybe Integer)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 399 (list (cons 'cat *cat)) (lambda () (select-min (entity-field-ref Product 'price) (from Product) (where (==. (entity-field-ref Product 'category) cat))))))

(define/pow
  (maxPriceOrZero)
  #:capabilities [dbRead]
  #:returns Integer
  (thsl-src-control! "example/learn/lesson21-sql-reference.tesl" 404 (list) (lambda () (let ([tesl-case-1 (raw-value (maxPrice))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "example/learn/lesson21-sql-reference.tesl" 405 (list) (lambda () (raw-value 0)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([price (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "example/learn/lesson21-sql-reference.tesl" 406 (list (cons 'price price)) (lambda () *price)))])))))

(define/pow
  (countPerCategory)
  #:capabilities [dbRead]
  #:returns (List (Tuple2 String Integer))
  (thsl-src! "" 1 (list) (lambda () (select-count-by (sql-group-key 'field 0 (entity-field-ref Product 'category)) (from Product)))))

(define/pow
  (stockValuePerCategory)
  #:capabilities [dbRead]
  #:returns (List (Tuple2 String Integer))
  (thsl-src! "" 1 (list) (lambda () (select-sum-by (sql-group-key 'field 0 (entity-field-ref Product 'category)) (entity-field-ref Product 'price) (from Product)))))

(define-entity TimeEntry
  #:source (make-hash)
  #:table time_entries
  #:primary-key id
  [Id id : String]
  [OrgId orgId : String]
  [Minutes minutes : Integer]
  [StartedAt startedAt : PosixMillis]
)

(define/pow
  (minutesPerDay [orgId : String] [zone : TimeZone])
  #:capabilities [dbRead]
  #:returns (List (Tuple2 PosixMillis Integer))
  (thsl-src! "" 1 (list (cons 'orgId *orgId) (cons 'zone *zone)) (lambda () (select-sum-by (sql-group-key 'day *zone (entity-field-ref TimeEntry 'startedAt)) (entity-field-ref TimeEntry 'minutes) (from TimeEntry) (where (==. (entity-field-ref TimeEntry 'orgId) orgId))))))

(define/pow
  (entriesPerMonth [orgId : String] [zone : TimeZone])
  #:capabilities [dbRead]
  #:returns (List (Tuple2 PosixMillis Integer))
  (thsl-src! "" 1 (list (cons 'orgId *orgId) (cons 'zone *zone)) (lambda () (select-count-by (sql-group-key 'month *zone (entity-field-ref TimeEntry 'startedAt)) (from TimeEntry) (where (==. (entity-field-ref TimeEntry 'orgId) orgId))))))

(define/pow
  (entriesOnDay [orgId : String] [zone : TimeZone] [anyInstantThatDay : PosixMillis])
  #:capabilities [dbRead]
  #:returns (List TimeEntry)
  (let ([dayStart (thsl-src! "example/learn/lesson21-sql-reference.tesl" 474 (list (cons 'orgId *orgId) (cons 'zone *zone) (cons 'anyInstantThatDay *anyInstantThatDay)) (lambda () (raw-value (tesl_import_Time_truncDay *zone *anyInstantThatDay))))]) (let ([dayEnd (thsl-src! "example/learn/lesson21-sql-reference.tesl" 475 (list (cons 'dayStart *dayStart) (cons 'orgId *orgId) (cons 'zone *zone) (cons 'anyInstantThatDay *anyInstantThatDay)) (lambda () (addMs (raw-value dayStart) 86400000)))]) (thsl-src! "example/learn/lesson21-sql-reference.tesl" 477 (list (cons 'dayEnd *dayEnd) (cons 'dayStart *dayStart) (cons 'orgId *orgId) (cons 'zone *zone) (cons 'anyInstantThatDay *anyInstantThatDay)) (lambda () (select-many (from TimeEntry) (where (==. (entity-field-ref TimeEntry 'orgId) orgId)) (where (>=. (entity-field-ref TimeEntry 'startedAt) dayStart)) (where (<. (entity-field-ref TimeEntry 'startedAt) dayEnd))))))))

(define/pow
  (minutesThisWeek [orgId : String] [zone : TimeZone] [now : PosixMillis])
  #:capabilities [dbRead]
  #:returns Integer
  (let ([weekStart (thsl-src! "example/learn/lesson21-sql-reference.tesl" 482 (list (cons 'orgId *orgId) (cons 'zone *zone) (cons 'now *now)) (lambda () (raw-value (tesl_import_Time_truncWeek *zone *now))))]) (thsl-src! "example/learn/lesson21-sql-reference.tesl" 484 (list (cons 'weekStart *weekStart) (cons 'orgId *orgId) (cons 'zone *zone) (cons 'now *now)) (lambda () (select-sum (entity-field-ref TimeEntry 'minutes) (from TimeEntry) (where (==. (entity-field-ref TimeEntry 'orgId) orgId)) (where (>=. (entity-field-ref TimeEntry 'startedAt) weekStart)))))))

(define/pow
  (countByCategory [cat : String])
  #:capabilities [dbRead]
  #:returns Integer
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 488 (list (cons 'cat *cat)) (lambda () (select-count (from Product) (where (==. (entity-field-ref Product 'category) cat))))))

(define/pow
  (findInStockCheap [maxAllowedPrice : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "" 1 (list (cons 'maxAllowedPrice *maxAllowedPrice)) (lambda () (select-many (from Product) (where (==. (entity-field-ref Product 'inStock) #t)) (where (<=. (entity-field-ref Product 'price) maxAllowedPrice)) (order-by (entity-field-ref Product 'price) 'asc)))))

(define/pow
  (findProductsWithCategory [minAllowedPrice : Integer])
  #:capabilities [dbRead]
  #:returns (List Product)
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 506 (list (cons 'minAllowedPrice *minAllowedPrice)) (lambda () (select-many (from Product) (where (>=. (entity-field-ref Product 'price) minAllowedPrice)) (inner-join Category (entity-field-ref Product 'category) (entity-field-ref Category 'id))))))

(define/pow
  (createProductWithCategory [id : String] [name : String] [price : Integer] [catId : String] [catLabel : String])
  #:capabilities [dbRead dbWrite]
  #:returns Product
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 535 (list (cons 'id *id) (cons 'name *name) (cons 'price *price) (cons 'catId *catId) (cons 'catLabel *catLabel)) (lambda () (call-with-queue-transaction (lambda () (let ([_ (insert-one! Category (tesl-hash 'id catId 'label catLabel 'active #t))]) (insert-one! Product (tesl-hash 'id id 'name name 'price price 'category catId 'inStock #t))))))))

(define/pow
  (swapStock [outId : String] [inId : String])
  #:capabilities [dbWrite]
  #:returns Unit
  (thsl-src! "example/learn/lesson21-sql-reference.tesl" 543 (list (cons 'outId *outId) (cons 'inId *inId)) (lambda () (call-with-queue-transaction (lambda () (let ([_ (void (update-many! (from Product) (tesl-hash (entity-field-ref Product 'inStock) #f) (where (==. (entity-field-ref Product 'id) outId))))]) (void (update-many! (from Product) (tesl-hash (entity-field-ref Product 'inStock) #t) (where (==. (entity-field-ref Product 'id) inId))))))))))

(define/pow
  (seedTimeEntries)
  #:capabilities [dbWrite]
  #:returns Integer
  (let ([_ (thsl-src! "example/learn/lesson21-sql-reference.tesl" 763 (list) (lambda () (insert-one! TimeEntry (tesl-hash 'id "te1" 'orgId "acme" 'minutes 60 'startedAt (raw-value (tesl_import_Time_secondsToPosix 1772359200))))))]) (let ([_ (thsl-src! "example/learn/lesson21-sql-reference.tesl" 764 (list (cons '_ *_)) (lambda () (insert-one! TimeEntry (tesl-hash 'id "te2" 'orgId "acme" 'minutes 30 'startedAt (raw-value (tesl_import_Time_secondsToPosix 1772407800))))))]) (let ([_ (thsl-src! "example/learn/lesson21-sql-reference.tesl" 765 (list (cons '_ *_) (cons '_ *_)) (lambda () (insert-one! TimeEntry (tesl-hash 'id "te3" 'orgId "acme" 'minutes 45 'startedAt (raw-value (tesl_import_Time_secondsToPosix 1772413200))))))]) (thsl-src! "example/learn/lesson21-sql-reference.tesl" 766 (list (cons '_ *_) (cons '_ *_) (cons '_ *_)) (lambda () 3))))))

(module+ test
  (require rackunit)
  (test-case "findById returns named entity"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-2 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 573 (list) (lambda () (createProduct "p1" "Widget" 10 "tools"))))
    (define p (thsl-src! "example/learn/lesson21-sql-reference.tesl" 574 (list) (lambda () (findById "p1"))))
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 575 (list (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p 'name 'Product)))) "Widget")
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 576 (list (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p 'price 'Product)))) 10)
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 577 (list (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p 'category 'Product)))) "tools")
    )
    ))
  )

  (test-case "findByCategory returns matching rows"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-3 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 581 (list) (lambda () (createProduct "c1" "Hammer" 15 "tools"))))
    (define tesl-ignored-4 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 582 (list) (lambda () (createProduct "c2" "Nail" 2 "tools"))))
    (define tesl-ignored-5 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 583 (list) (lambda () (createProduct "c3" "Book" 20 "media"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 584 (list) (lambda () (findByCategory "tools"))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 585 (list (cons 'results results)) (lambda () results)) (list))
    )
    ))
  )

  (test-case "findCheapInCategory applies AND condition"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-6 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 589 (list) (lambda () (createProduct "a1" "Cheap Tool" 5 "tools"))))
    (define tesl-ignored-7 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 590 (list) (lambda () (createProduct "a2" "Expensive Tool" 50 "tools"))))
    (define cheap (thsl-src! "example/learn/lesson21-sql-reference.tesl" 591 (list) (lambda () (findCheapInCategory "tools" 10))))
    (define expensive (thsl-src! "example/learn/lesson21-sql-reference.tesl" 592 (list (cons 'cheap cheap)) (lambda () (findCheapInCategory "tools" 100))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 593 (list (cons 'expensive expensive) (cons 'cheap cheap)) (lambda () cheap)) (list))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 594 (list (cons 'expensive expensive) (cons 'cheap cheap)) (lambda () expensive)) (list))
    )
    ))
  )

  (test-case "findFeatured applies OR condition"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-8 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 598 (list) (lambda () (createProduct "f1" "Alpha" 10 "alpha"))))
    (define tesl-ignored-9 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 599 (list) (lambda () (createProduct "f2" "Beta" 10 "beta"))))
    (define tesl-ignored-10 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 600 (list) (lambda () (createProduct "f3" "Gamma" 10 "gamma"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 601 (list) (lambda () (findFeatured "alpha" "beta"))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 602 (list (cons 'results results)) (lambda () results)) (list))
    )
    ))
  )

  (test-case "setPrice updates the entity and returns it"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-11 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 606 (list) (lambda () (createProduct "u1" "Updatable" 100 "misc"))))
    (define updated (thsl-src! "example/learn/lesson21-sql-reference.tesl" 607 (list) (lambda () (setPrice "u1" 200))))
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 608 (list (cons 'updated updated)) (lambda () (raw-value (tesl-dot/runtime updated 'price 'Product)))) 200)
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 609 (list (cons 'updated updated)) (lambda () (raw-value (tesl-dot/runtime updated 'category 'Product)))) "recently-updated")
    )
    ))
  )

  (test-case "updatePriceSilently returns unit"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-12 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 613 (list) (lambda () (createProduct "us1" "Silent" 50 "misc"))))
    (define tesl-ignored-13 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 614 (list) (lambda () (updatePriceSilently "us1" 75))))
    (define found (thsl-src! "example/learn/lesson21-sql-reference.tesl" 615 (list) (lambda () (findById "us1"))))
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 616 (list (cons 'found found)) (lambda () (raw-value (tesl-dot/runtime found 'price 'Product)))) 75)
    )
    ))
  )

  (test-case "removeProduct deletes a row and returns unit"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-14 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 620 (list) (lambda () (createProduct "d1" "Deletable" 5 "misc"))))
    (define tesl-ignored-15 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 621 (list) (lambda () (removeProduct "d1"))))
    (define result (thsl-src! "example/learn/lesson21-sql-reference.tesl" 622 (list) (lambda () (let ([tesl_match (select-one (from Product) (where (==. (entity-field-ref Product 'id) "d1")))]) (if tesl_match (Something tesl_match) Nothing)))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson21-sql-reference.tesl" 623 (list (cons 'result result)) (lambda () result))) Nothing)
    )
    ))
  )

  (test-case "removeProductWithResult returns NoRowDeleted when not found"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbWrite)
    (define result (thsl-src! "example/learn/lesson21-sql-reference.tesl" 627 (list) (lambda () (removeProductWithResult "nonexistent-xyz"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson21-sql-reference.tesl" 628 (list (cons 'result result)) (lambda () result))) NoRowDeleted)
    )
    ))
  )

  (test-case "removeProductWithResult returns RowsDeleted when found"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-16 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 632 (list) (lambda () (createProduct "dr1" "ToDelete" 5 "misc"))))
    (define result (thsl-src! "example/learn/lesson21-sql-reference.tesl" 633 (list) (lambda () (removeProductWithResult "dr1"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson21-sql-reference.tesl" 634 (list (cons 'result result)) (lambda () result))) (raw-value (RowsDeleted 1)))
    )
    ))
  )

  (test-case "batchCreate inserts all products"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-17 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 638 (list) (lambda () (batchCreate (list (tesl-hash 'id "b1" 'name "Batch1" 'price 10 'category "batch" 'inStock #t) (tesl-hash 'id "b2" 'name "Batch2" 'price 20 'category "batch" 'inStock #t))))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 639 (list) (lambda () (findByCategory "batch"))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 640 (list (cons 'results results)) (lambda () results)) (list))
    )
    ))
  )

  (test-case "expensiveProducts filters by price"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-18 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 644 (list) (lambda () (createProduct "e1" "Pricey" 999 "luxury"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 645 (list) (lambda () (expensiveProducts 500))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 646 (list (cons 'results results)) (lambda () results)) (list))
    )
    ))
  )

  (test-case "findInPriceRange returns only rows in range"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-19 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 650 (list) (lambda () (createProduct "br1" "Cheap" 5 "misc"))))
    (define tesl-ignored-20 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 651 (list) (lambda () (createProduct "br2" "Mid" 25 "misc"))))
    (define tesl-ignored-21 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 652 (list) (lambda () (createProduct "br3" "Expensive" 100 "misc"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 653 (list) (lambda () (findInPriceRange 10 50))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 654 (list (cons 'results results)) (lambda () results)) (list))
    )
    ))
  )

  (test-case "findInPriceRangeOrdered returns ordered results"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-22 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 658 (list) (lambda () (createProduct "bro1" "Budget" 15 "misc"))))
    (define tesl-ignored-23 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 659 (list) (lambda () (createProduct "bro2" "Premium" 45 "misc"))))
    (define tesl-ignored-24 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 660 (list) (lambda () (createProduct "bro3" "TooExpensive" 200 "misc"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 661 (list) (lambda () (findInPriceRangeOrdered 10 50))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 662 (list (cons 'results results)) (lambda () results)) (list))
    )
    ))
  )

  (test-case "upsertProduct inserts when row does not exist"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-25 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 666 (list) (lambda () (upsertProduct "up1" "NewProduct" 42))))
    (define found (thsl-src! "example/learn/lesson21-sql-reference.tesl" 667 (list) (lambda () (findById "up1"))))
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 668 (list (cons 'found found)) (lambda () (raw-value (tesl-dot/runtime found 'name 'Product)))) "NewProduct")
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 669 (list (cons 'found found)) (lambda () (raw-value (tesl-dot/runtime found 'price 'Product)))) 42)
    )
    ))
  )

  (test-case "upsertProduct updates when row already exists"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-26 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 673 (list) (lambda () (upsertProduct "up2" "Original" 10))))
    (define tesl-ignored-27 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 674 (list) (lambda () (upsertProduct "up2" "Updated" 99))))
    (define found (thsl-src! "example/learn/lesson21-sql-reference.tesl" 675 (list) (lambda () (findById "up2"))))
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 676 (list (cons 'found found)) (lambda () (raw-value (tesl-dot/runtime found 'name 'Product)))) "Updated")
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 677 (list (cons 'found found)) (lambda () (raw-value (tesl-dot/runtime found 'price 'Product)))) 99)
    )
    ))
  )

  (test-case "upsertProductByName conflicts on the unique index, not the primary key"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-28 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 681 (list) (lambda () (upsertProductByName "un1" "UniqueName" 10))))
    (define tesl-ignored-29 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 684 (list) (lambda () (upsertProductByName "un2" "UniqueName" 77))))
    (define found (thsl-src! "example/learn/lesson21-sql-reference.tesl" 685 (list) (lambda () (findById "un1"))))
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 686 (list (cons 'found found)) (lambda () (raw-value (tesl-dot/runtime found 'price 'Product)))) 77)
    (define byOther (thsl-src! "example/learn/lesson21-sql-reference.tesl" 687 (list (cons 'found found)) (lambda () (select-many (from Product) (where (==. (entity-field-ref Product 'id) "un2"))))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson21-sql-reference.tesl" 688 (list (cons 'byOther byOther) (cons 'found found)) (lambda () byOther))) (list))
    )
    ))
  )

  (test-case "searchByName with like pattern matches prefix"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-30 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 692 (list) (lambda () (createProduct "lk1" "Widget Pro" 50 "tools"))))
    (define tesl-ignored-31 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 693 (list) (lambda () (createProduct "lk2" "Gadget" 30 "tools"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 694 (list) (lambda () (searchByName "Widget%"))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 695 (list (cons 'results results)) (lambda () results)) (list))
    )
    ))
  )

  (test-case "searchByNameInsensitive with ilike is case-insensitive"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-32 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 699 (list) (lambda () (createProduct "ilk1" "WidgetX" 50 "tools"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 700 (list) (lambda () (searchByNameInsensitive "widget%"))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 701 (list (cons 'results results)) (lambda () results)) (list))
    )
    ))
  )

  (test-case "countProducts returns total count"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-33 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 705 (list) (lambda () (createProduct "cnt1" "CountMe1" 10 "count-test"))))
    (define tesl-ignored-34 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 706 (list) (lambda () (createProduct "cnt2" "CountMe2" 20 "count-test"))))
    (define n (thsl-src! "example/learn/lesson21-sql-reference.tesl" 707 (list) (lambda () (countProducts))))
    (check-true (thsl-src! "example/learn/lesson21-sql-reference.tesl" 708 (list (cons 'n n)) (lambda () (tesl-gt? (raw-value n) 0))))
    )
    ))
  )

  (test-case "sumPrices returns non-negative sum"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-35 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 712 (list) (lambda () (createProduct "sum1" "SumMe1" 10 "sum-test"))))
    (define tesl-ignored-36 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 713 (list) (lambda () (createProduct "sum2" "SumMe2" 20 "sum-test"))))
    (define total (thsl-src! "example/learn/lesson21-sql-reference.tesl" 714 (list) (lambda () (sumPrices))))
    (check-true (thsl-src! "example/learn/lesson21-sql-reference.tesl" 715 (list (cons 'total total)) (lambda () (tesl-gt? (raw-value total) 0))))
    )
    ))
  )

  (test-case "findInStockCheap filters on multiple conditions"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-37 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 719 (list) (lambda () (createProduct "is1" "Cheap In Stock" 5 "misc"))))
    (define tesl-ignored-38 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 720 (list) (lambda () (createProduct "is2" "Expensive In Stock" 500 "misc"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 721 (list) (lambda () (findInStockCheap 50))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 722 (list (cons 'results results)) (lambda () results)) (list))
    )
    ))
  )

  (test-case "findProductsWithCategory uses innerJoin to filter"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-39 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 726 (list) (lambda () (insert-one! Category (tesl-hash 'id "tools" 'label "Tools" 'active #t)))))
    (define tesl-ignored-40 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 731 (list) (lambda () (createProduct "ij1" "Claw Hammer" 15 "tools"))))
    (define tesl-ignored-41 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 733 (list) (lambda () (createProduct "ij2" "Phantom" 10 "nonexistent-cat"))))
    (define results (thsl-src! "example/learn/lesson21-sql-reference.tesl" 734 (list) (lambda () (findProductsWithCategory 1))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 735 (list (cons 'results results)) (lambda () results)) (list))
    )
    ))
  )

  (test-case "createProductWithCategory inserts both atomically"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define p (thsl-src! "example/learn/lesson21-sql-reference.tesl" 739 (list) (lambda () (createProductWithCategory "txp1" "Transactional Widget" 30 "tx-cat" "TX Category"))))
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 740 (list (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p 'name 'Product)))) "Transactional Widget")
    (check-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 741 (list (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p 'price 'Product)))) 30)
    (define cats (thsl-src! "example/learn/lesson21-sql-reference.tesl" 743 (list (cons 'p p)) (lambda () (select-many (from Category) (where (==. (entity-field-ref Category 'id) "tx-cat"))))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 744 (list (cons 'cats cats) (cons 'p p)) (lambda () cats)) (list))
    )
    ))
  )

  (test-case "swapStock updates two rows atomically"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-42 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 748 (list) (lambda () (createProduct "swap1" "SwapOut" 10 "misc"))))
    (define tesl-ignored-43 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 749 (list) (lambda () (createProduct "swap2" "SwapIn" 20 "misc"))))
    (define tesl-ignored-44 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 751 (list) (lambda () (swapStock "swap1" "swap2"))))
    (define outRows (thsl-src! "example/learn/lesson21-sql-reference.tesl" 753 (list) (lambda () (select-many (from Product) (where (==. (entity-field-ref Product 'id) "swap1"))))))
    (define inRows (thsl-src! "example/learn/lesson21-sql-reference.tesl" 754 (list (cons 'outRows outRows)) (lambda () (select-many (from Product) (where (==. (entity-field-ref Product 'id) "swap2"))))))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 755 (list (cons 'inRows inRows) (cons 'outRows outRows)) (lambda () outRows)) (list))
    (check-not-equal? (thsl-src! "example/learn/lesson21-sql-reference.tesl" 756 (list (cons 'inRows inRows) (cons 'outRows outRows)) (lambda () inRows)) (list))
    )
    ))
  )

  (test-case "per-day series: UTC buckets differ from Stockholm buckets"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-45 (thsl-src! "example/learn/lesson21-sql-reference.tesl" 769 (list) (lambda () (seedTimeEntries))))
    (define utcDays (thsl-src! "example/learn/lesson21-sql-reference.tesl" 771 (list) (lambda () (minutesPerDay "acme" (__ttz_tesl-tz-utc)))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson21-sql-reference.tesl" 772 (list (cons 'utcDays utcDays)) (lambda () (raw-value (tesl_import_List_length (raw-value utcDays)))))) 2)
    (define sthlmDays (thsl-src! "example/learn/lesson21-sql-reference.tesl" 775 (list (cons 'utcDays utcDays)) (lambda () (minutesPerDay "acme" (__ttz_tesl-tz-named "Europe/Stockholm")))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson21-sql-reference.tesl" 776 (list (cons 'sthlmDays sthlmDays) (cons 'utcDays utcDays)) (lambda () (raw-value (tesl_import_List_length (raw-value sthlmDays)))))) 2)
    )
    ))
  )

  (test-case "filter pattern: all rows for one Stockholm day"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (dbRead dbWrite)
    (insert-one! TimeEntry (tesl-hash 'id "te4" 'orgId "acme2" 'minutes 10 'startedAt (raw-value (tesl_import_Time_secondsToPosix 1772359200))))
    (insert-one! TimeEntry (tesl-hash 'id "te5" 'orgId "acme2" 'minutes 20 'startedAt (raw-value (tesl_import_Time_secondsToPosix 1772407800))))
    (define probe (thsl-src! "example/learn/lesson21-sql-reference.tesl" 783 (list) (lambda () (raw-value (tesl_import_Time_secondsToPosix 1772359200)))))
    (define rows (thsl-src! "example/learn/lesson21-sql-reference.tesl" 784 (list (cons 'probe probe)) (lambda () (entriesOnDay "acme2" (__ttz_tesl-tz-named "Europe/Stockholm") probe))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson21-sql-reference.tesl" 785 (list (cons 'rows rows) (cons 'probe probe)) (lambda () (raw-value (tesl_import_List_length (raw-value rows)))))) 1)
    )
    ))
  )

  (test-case "offsetAt is DST-correct per instant"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson21-sql-reference.tesl" 790 (list) (lambda () (raw-value (tesl_import_Time_offsetAt (__ttz_tesl-tz-named "Europe/Stockholm") (raw-value (tesl_import_Time_secondsToPosix 1767225600))))))) 60)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson21-sql-reference.tesl" 791 (list) (lambda () (raw-value (tesl_import_Time_offsetAt (__ttz_tesl-tz-named "Europe/Stockholm") (raw-value (tesl_import_Time_secondsToPosix 1750000000))))))) 120)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson21-sql-reference.tesl" 792 (list) (lambda () (raw-value (tesl_import_Time_offsetAt (__ttz_tesl-tz-fixed (raw-value 330)) (raw-value (tesl_import_Time_secondsToPosix 0))))))) 330)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson21-sql-reference.tesl" 793 (list) (lambda () (raw-value (tesl_import_Time_offsetAt (__ttz_tesl-tz-utc) (raw-value (tesl_import_Time_secondsToPosix 0))))))) 0)
    ))
  )

)
