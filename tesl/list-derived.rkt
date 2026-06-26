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
  (only-in tesl/tesl/prelude Int Bool List)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/tuple Tuple2)
  (only-in tesl/tesl/list-prim [ListPrim.head tesl_import_ListPrim_head] [ListPrim.tail tesl_import_ListPrim_tail] [ListPrim.append tesl_import_ListPrim_append])
)


(provide map filter foldl foldr length isEmpty head tail concat append reverse unique take drop zip range repeat any all find sum maximum minimum concatMap member contains map-signature filter-signature concatMap-signature reverse-signature unique-signature zip-signature length-signature isEmpty-signature head-signature tail-signature any-signature all-signature find-signature member-signature contains-signature sum-signature maximum-signature minimum-signature append-signature concat-signature range-signature repeat-signature foldl-signature foldr-signature take-signature drop-signature)

(define/pow
  (map [f : (-> a b)] [xs : (List a)])
  #:returns (List b)
  (thsl-src! "tesl/list.tesl" 77 (list (cons 'f *f) (cons 'xs *xs)) (lambda () (let ([tesl_case_0 (raw-value (tesl_import_ListPrim_head *xs))]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (raw-value (list))] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([first (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (let ([tesl_case_1 (raw-value (tesl_import_ListPrim_tail *xs))]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Nothing)) (raw-value (list (f *first)))] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Something)) (let ([rest (hash-ref (adt-value-fields *tesl_case_1) 'value)]) (raw-value (raw-value (tesl_import_ListPrim_append (list (f *first)) (raw-value (map f *rest))))))])))])))))

(define/pow
  (filter [pred : (-> a Boolean)] [xs : (List a)])
  #:returns (List a)
  (thsl-src! "tesl/list.tesl" 85 (list (cons 'pred *pred) (cons 'xs *xs)) (lambda () (let ([tesl_case_2 (raw-value (tesl_import_ListPrim_head *xs))]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Nothing)) (raw-value (list))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Something)) (let ([first (hash-ref (adt-value-fields *tesl_case_2) 'value)]) (let ([tesl_case_3 (raw-value (tesl_import_ListPrim_tail *xs))]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Nothing)) (if (pred *first) (raw-value (list *first)) (raw-value (list)))] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Something)) (let ([rest (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (if (pred *first) (raw-value (raw-value (tesl_import_ListPrim_append (list *first) (raw-value (filter pred *rest))))) (raw-value (filter pred *rest))))])))])))))

(define/pow
  (concatMap [f : (-> a (List b))] [xs : (List a)])
  #:returns (List b)
  (thsl-src! "tesl/list.tesl" 101 (list (cons 'f *f) (cons 'xs *xs)) (lambda () (raw-value (concat (map f xs))))))

(define/pow
  (reverse [xs : (List a)])
  #:returns (List a)
  (thsl-src! "tesl/list.tesl" 104 (list (cons 'xs *xs)) (lambda () (let ([tesl_case_4 (raw-value (tesl_import_ListPrim_head *xs))]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Nothing)) (raw-value (list))] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Something)) (let ([first (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (let ([tesl_case_5 (raw-value (tesl_import_ListPrim_tail *xs))]) (cond [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Nothing)) (raw-value (list *first))] [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Something)) (let ([rest (hash-ref (adt-value-fields *tesl_case_5) 'value)]) (raw-value (raw-value (tesl_import_ListPrim_append (raw-value (reverse *rest)) (list *first)))))])))])))))

(define/pow
  (unique [xs : (List a)])
  #:returns (List a)
  (thsl-src! "tesl/list.tesl" 112 (list (cons 'xs *xs)) (lambda () *xs)))

(define/pow
  (zip [xs : (List a)] [ys : (List b)])
  #:returns (List (Tuple2 a b))
  (thsl-src! "tesl/list.tesl" 115 (list (cons 'xs *xs) (cons 'ys *ys)) (lambda () (let ([tesl_case_6 (raw-value (head xs))]) (cond [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Nothing)) (raw-value (list))] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Something)) (let ([x (hash-ref (adt-value-fields *tesl_case_6) 'value)]) (let ([tesl_case_7 (raw-value (head ys))]) (cond [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Nothing)) (raw-value (list))] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Something)) (let ([y (hash-ref (adt-value-fields *tesl_case_7) 'value)]) (raw-value (list (Tuple2 *x *y))))])))])))))

(define/pow
  (length [xs : (List a)])
  #:returns Integer
  (thsl-src! "tesl/list.tesl" 125 (list (cons 'xs *xs)) (lambda () (let ([tesl_case_8 (raw-value (tesl_import_ListPrim_head *xs))]) (cond [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Nothing)) (raw-value 0)] [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Something)) (let ([tesl_case_9 (raw-value (tesl_import_ListPrim_tail *xs))]) (cond [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Nothing)) (raw-value 1)] [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Something)) (let ([rest (hash-ref (adt-value-fields *tesl_case_9) 'value)]) (raw-value (+ 1 (raw-value (length *rest)))))]))])))))

(define/pow
  (isEmpty [xs : (List a)])
  #:returns Boolean
  (thsl-src! "tesl/list.tesl" 133 (list (cons 'xs *xs)) (lambda () (let ([tesl_case_10 (raw-value (head xs))]) (cond [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Nothing)) (raw-value #t)] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Something)) (raw-value #f)])))))

(define/pow
  (head [xs : (List a)])
  #:returns (Maybe a)
  (thsl-src! "tesl/list.tesl" 138 (list (cons 'xs *xs)) (lambda () (let ([tesl_case_11 (raw-value (tail xs))]) (cond [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Nothing)) (raw-value Nothing)] [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Something)) (raw-value Nothing)])))))

(define/pow
  (tail [xs : (List a)])
  #:returns (Maybe (List a))
  (thsl-src! "tesl/list.tesl" 143 (list (cons 'xs *xs)) (lambda () (let ([tesl_case_12 (raw-value (isEmpty xs))]) (cond [(eq? *tesl_case_12 #t) (raw-value Nothing)] [(eq? *tesl_case_12 #f) (raw-value (raw-value (Something *xs)))])))))

(define/pow
  (any [pred : (-> a Boolean)] [xs : (List a)])
  #:returns Boolean
  (thsl-src! "tesl/list.tesl" 148 (list (cons 'pred *pred) (cons 'xs *xs)) (lambda () (let ([tesl_case_13 (raw-value (tesl_import_ListPrim_head *xs))]) (cond [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Nothing)) (raw-value #f)] [(and (adt-value? *tesl_case_13) (eq? (adt-value-variant *tesl_case_13) 'Something)) (let ([first (hash-ref (adt-value-fields *tesl_case_13) 'value)]) (if (pred *first) (raw-value #t) (let ([tesl_case_14 (raw-value (tesl_import_ListPrim_tail *xs))]) (cond [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Nothing)) (raw-value #f)] [(and (adt-value? *tesl_case_14) (eq? (adt-value-variant *tesl_case_14) 'Something)) (let ([rest (hash-ref (adt-value-fields *tesl_case_14) 'value)]) (raw-value (any pred *rest)))]))))])))))

(define/pow
  (all [pred : (-> a Boolean)] [xs : (List a)])
  #:returns Boolean
  (thsl-src! "tesl/list.tesl" 159 (list (cons 'pred *pred) (cons 'xs *xs)) (lambda () (let ([tesl_case_15 (raw-value (tesl_import_ListPrim_head *xs))]) (cond [(and (adt-value? *tesl_case_15) (eq? (adt-value-variant *tesl_case_15) 'Nothing)) (raw-value #t)] [(and (adt-value? *tesl_case_15) (eq? (adt-value-variant *tesl_case_15) 'Something)) (let ([first (hash-ref (adt-value-fields *tesl_case_15) 'value)]) (if (pred *first) (let ([tesl_case_16 (raw-value (tesl_import_ListPrim_tail *xs))]) (cond [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'Nothing)) (raw-value #t)] [(and (adt-value? *tesl_case_16) (eq? (adt-value-variant *tesl_case_16) 'Something)) (let ([rest (hash-ref (adt-value-fields *tesl_case_16) 'value)]) (raw-value (all pred *rest)))])) (raw-value #f)))])))))

(define/pow
  (find [pred : (-> a Boolean)] [xs : (List a)])
  #:returns (Maybe a)
  (thsl-src! "tesl/list.tesl" 170 (list (cons 'pred *pred) (cons 'xs *xs)) (lambda () (let ([tesl_case_17 (raw-value (tesl_import_ListPrim_head *xs))]) (cond [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Nothing)) (raw-value Nothing)] [(and (adt-value? *tesl_case_17) (eq? (adt-value-variant *tesl_case_17) 'Something)) (let ([first (hash-ref (adt-value-fields *tesl_case_17) 'value)]) (if (pred *first) (raw-value (raw-value (Something *first))) (let ([tesl_case_18 (raw-value (tesl_import_ListPrim_tail *xs))]) (cond [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Nothing)) (raw-value Nothing)] [(and (adt-value? *tesl_case_18) (eq? (adt-value-variant *tesl_case_18) 'Something)) (let ([rest (hash-ref (adt-value-fields *tesl_case_18) 'value)]) (raw-value (find pred *rest)))]))))])))))

(define/pow
  (member [x : a] [xs : (List a)])
  #:returns Boolean
  (thsl-src! "tesl/list.tesl" 181 (list (cons 'x *x) (cons 'xs *xs)) (lambda () (let ([tesl_case_19 (raw-value (tesl_import_ListPrim_head *xs))]) (cond [(and (adt-value? *tesl_case_19) (eq? (adt-value-variant *tesl_case_19) 'Nothing)) (raw-value #f)] [(and (adt-value? *tesl_case_19) (eq? (adt-value-variant *tesl_case_19) 'Something)) (let ([first (hash-ref (adt-value-fields *tesl_case_19) 'value)]) (if (equal? *x *first) (raw-value #t) (let ([tesl_case_20 (raw-value (tesl_import_ListPrim_tail *xs))]) (cond [(and (adt-value? *tesl_case_20) (eq? (adt-value-variant *tesl_case_20) 'Nothing)) (raw-value #f)] [(and (adt-value? *tesl_case_20) (eq? (adt-value-variant *tesl_case_20) 'Something)) (let ([rest (hash-ref (adt-value-fields *tesl_case_20) 'value)]) (raw-value (member x *rest)))]))))])))))

(define/pow
  (contains [x : a] [xs : (List a)])
  #:returns Boolean
  (thsl-src! "tesl/list.tesl" 192 (list (cons 'x *x) (cons 'xs *xs)) (lambda () (raw-value (member x xs)))))

(define/pow
  (sum [xs : (List Integer)])
  #:returns Integer
  (thsl-src! "tesl/list.tesl" 195 (list (cons 'xs *xs)) (lambda () (let ([tesl_case_21 (raw-value (tesl_import_ListPrim_head *xs))]) (cond [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'Nothing)) (raw-value 0)] [(and (adt-value? *tesl_case_21) (eq? (adt-value-variant *tesl_case_21) 'Something)) (let ([first (hash-ref (adt-value-fields *tesl_case_21) 'value)]) (let ([tesl_case_22 (raw-value (tesl_import_ListPrim_tail *xs))]) (cond [(and (adt-value? *tesl_case_22) (eq? (adt-value-variant *tesl_case_22) 'Nothing)) *first] [(and (adt-value? *tesl_case_22) (eq? (adt-value-variant *tesl_case_22) 'Something)) (let ([rest (hash-ref (adt-value-fields *tesl_case_22) 'value)]) (raw-value (+ *first (raw-value (sum *rest)))))])))])))))

(define/pow
  (maximum [xs : (List a)])
  #:returns (Maybe a)
  (thsl-src! "tesl/list.tesl" 203 (list (cons 'xs *xs)) (lambda () (let ([tesl_case_23 (raw-value (tesl_import_ListPrim_head *xs))]) (cond [(and (adt-value? *tesl_case_23) (eq? (adt-value-variant *tesl_case_23) 'Nothing)) (raw-value Nothing)] [(and (adt-value? *tesl_case_23) (eq? (adt-value-variant *tesl_case_23) 'Something)) (let ([first (hash-ref (adt-value-fields *tesl_case_23) 'value)]) (let ([tesl_case_24 (raw-value (tesl_import_ListPrim_tail *xs))]) (cond [(and (adt-value? *tesl_case_24) (eq? (adt-value-variant *tesl_case_24) 'Nothing)) (raw-value (raw-value (Something *first)))] [(and (adt-value? *tesl_case_24) (eq? (adt-value-variant *tesl_case_24) 'Something)) (let ([rest (hash-ref (adt-value-fields *tesl_case_24) 'value)]) (let ([tesl_case_25 (raw-value (maximum *rest))]) (cond [(and (adt-value? *tesl_case_25) (eq? (adt-value-variant *tesl_case_25) 'Nothing)) (raw-value (raw-value (Something *first)))] [(and (adt-value? *tesl_case_25) (eq? (adt-value-variant *tesl_case_25) 'Something)) (let ([m (hash-ref (adt-value-fields *tesl_case_25) 'value)]) (if (> *first *m) (raw-value (raw-value (Something *first))) (raw-value (raw-value (Something *m)))))])))])))])))))

(define/pow
  (minimum [xs : (List a)])
  #:returns (Maybe a)
  (thsl-src! "tesl/list.tesl" 218 (list (cons 'xs *xs)) (lambda () (let ([tesl_case_26 (raw-value (tesl_import_ListPrim_head *xs))]) (cond [(and (adt-value? *tesl_case_26) (eq? (adt-value-variant *tesl_case_26) 'Nothing)) (raw-value Nothing)] [(and (adt-value? *tesl_case_26) (eq? (adt-value-variant *tesl_case_26) 'Something)) (let ([first (hash-ref (adt-value-fields *tesl_case_26) 'value)]) (let ([tesl_case_27 (raw-value (tesl_import_ListPrim_tail *xs))]) (cond [(and (adt-value? *tesl_case_27) (eq? (adt-value-variant *tesl_case_27) 'Nothing)) (raw-value (raw-value (Something *first)))] [(and (adt-value? *tesl_case_27) (eq? (adt-value-variant *tesl_case_27) 'Something)) (let ([rest (hash-ref (adt-value-fields *tesl_case_27) 'value)]) (let ([tesl_case_28 (raw-value (minimum *rest))]) (cond [(and (adt-value? *tesl_case_28) (eq? (adt-value-variant *tesl_case_28) 'Nothing)) (raw-value (raw-value (Something *first)))] [(and (adt-value? *tesl_case_28) (eq? (adt-value-variant *tesl_case_28) 'Something)) (let ([m (hash-ref (adt-value-fields *tesl_case_28) 'value)]) (if (< *first *m) (raw-value (raw-value (Something *first))) (raw-value (raw-value (Something *m)))))])))])))])))))

(define/pow
  (append [xs : (List a)] [ys : (List a)])
  #:returns (List a)
  (thsl-src! "tesl/list.tesl" 235 (list (cons 'xs *xs) (cons 'ys *ys)) (lambda () (raw-value (tesl_import_ListPrim_append *xs *ys)))))

(define/pow
  (concat [xss : (List (List a))])
  #:returns (List a)
  (thsl-src! "tesl/list.tesl" 238 (list (cons 'xss *xss)) (lambda () (let ([tesl_case_29 (raw-value (tesl_import_ListPrim_head *xss))]) (cond [(and (adt-value? *tesl_case_29) (eq? (adt-value-variant *tesl_case_29) 'Nothing)) (raw-value (list))] [(and (adt-value? *tesl_case_29) (eq? (adt-value-variant *tesl_case_29) 'Something)) (let ([first (hash-ref (adt-value-fields *tesl_case_29) 'value)]) (let ([tesl_case_30 (raw-value (tesl_import_ListPrim_tail *xss))]) (cond [(and (adt-value? *tesl_case_30) (eq? (adt-value-variant *tesl_case_30) 'Nothing)) *first] [(and (adt-value? *tesl_case_30) (eq? (adt-value-variant *tesl_case_30) 'Something)) (let ([rest (hash-ref (adt-value-fields *tesl_case_30) 'value)]) (raw-value (raw-value (tesl_import_ListPrim_append *first (raw-value (concat *rest))))))])))])))))

(define/pow
  (range [start : Integer] [end : Integer])
  #:returns (List Integer)
  (thsl-src! "tesl/list.tesl" 246 (list (cons 'start *start) (cons 'end *end)) (lambda () (if (< *start *end) (raw-value (list *start)) (raw-value (list))))))

(define/pow
  (repeat [x : a] [n : Integer])
  #:returns (List a)
  (thsl-src! "tesl/list.tesl" 252 (list (cons 'x *x) (cons 'n *n)) (lambda () (if (> *n 0) (raw-value (list *x)) (raw-value (list))))))

(define/pow
  (foldl [f : (-> b (-> a b))] [acc : b] [xs : (List a)])
  #:returns b
  (thsl-src! "tesl/list.tesl" 260 (list (cons 'f *f) (cons 'acc *acc) (cons 'xs *xs)) (lambda () (let ([tesl_case_31 (raw-value (tesl_import_ListPrim_head *xs))]) (cond [(and (adt-value? *tesl_case_31) (eq? (adt-value-variant *tesl_case_31) 'Nothing)) *acc] [(and (adt-value? *tesl_case_31) (eq? (adt-value-variant *tesl_case_31) 'Something)) (let ([first (hash-ref (adt-value-fields *tesl_case_31) 'value)]) (let ([tesl_case_32 (raw-value (tesl_import_ListPrim_tail *xs))]) (cond [(and (adt-value? *tesl_case_32) (eq? (adt-value-variant *tesl_case_32) 'Nothing)) (raw-value (f acc *first))] [(and (adt-value? *tesl_case_32) (eq? (adt-value-variant *tesl_case_32) 'Something)) (let ([rest (hash-ref (adt-value-fields *tesl_case_32) 'value)]) (raw-value (foldl f (f acc *first) *rest)))])))])))))

(define/pow
  (foldr [f : (-> a (-> b b))] [acc : b] [xs : (List a)])
  #:returns b
  (thsl-src! "tesl/list.tesl" 268 (list (cons 'f *f) (cons 'acc *acc) (cons 'xs *xs)) (lambda () (let ([tesl_case_33 (raw-value (tesl_import_ListPrim_head *xs))]) (cond [(and (adt-value? *tesl_case_33) (eq? (adt-value-variant *tesl_case_33) 'Nothing)) *acc] [(and (adt-value? *tesl_case_33) (eq? (adt-value-variant *tesl_case_33) 'Something)) (let ([first (hash-ref (adt-value-fields *tesl_case_33) 'value)]) (let ([tesl_case_34 (raw-value (tesl_import_ListPrim_tail *xs))]) (cond [(and (adt-value? *tesl_case_34) (eq? (adt-value-variant *tesl_case_34) 'Nothing)) (raw-value (f *first acc))] [(and (adt-value? *tesl_case_34) (eq? (adt-value-variant *tesl_case_34) 'Something)) (let ([rest (hash-ref (adt-value-fields *tesl_case_34) 'value)]) (raw-value (f *first (foldr f acc *rest))))])))])))))

(define/pow
  (take [n : Integer] [xs : (List a)])
  #:returns (List a)
  (thsl-src! "tesl/list.tesl" 278 (list (cons 'n *n) (cons 'xs *xs)) (lambda () (if (> *n 0) *xs (raw-value (list))))))

(define/pow
  (drop [n : Integer] [xs : (List a)])
  #:returns (List a)
  (thsl-src! "tesl/list.tesl" 284 (list (cons 'n *n) (cons 'xs *xs)) (lambda () (if (> *n 0) *xs *xs))))
