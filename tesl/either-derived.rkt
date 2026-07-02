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
  (only-in tesl/tesl/prelude Bool)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/either-prim Either Left Right)
)


(provide isLeft isRight fromLeft fromRight map mapLeft andThen withDefault toMaybe fromMaybe isLeft-signature isRight-signature fromLeft-signature fromRight-signature map-signature mapLeft-signature andThen-signature withDefault-signature toMaybe-signature fromMaybe-signature)

(define/pow
  (isLeft [x : (Either a b)])
  #:returns Boolean
  (thsl-src-control! "tesl/either.tesl" 46 (list (cons 'x *x)) (lambda () (let ([tesl-case-0 *x]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Left)) (thsl-src! "tesl/either.tesl" 47 (list) (lambda () (raw-value #t)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Right)) (thsl-src! "tesl/either.tesl" 48 (list) (lambda () (raw-value #f)))])))))

(define/pow
  (isRight [x : (Either a b)])
  #:returns Boolean
  (thsl-src-control! "tesl/either.tesl" 51 (list (cons 'x *x)) (lambda () (let ([tesl-case-1 *x]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Left)) (thsl-src! "tesl/either.tesl" 52 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Right)) (thsl-src! "tesl/either.tesl" 53 (list) (lambda () (raw-value #t)))])))))

(define/pow
  (fromLeft [x : (Either a b)])
  #:returns (Maybe a)
  (thsl-src-control! "tesl/either.tesl" 56 (list (cons 'x *x)) (lambda () (let ([tesl-case-2 *x]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Left)) (let ([v (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "tesl/either.tesl" 57 (list (cons 'v v)) (lambda () (raw-value (raw-value (Something *v))))))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Right)) (thsl-src! "tesl/either.tesl" 58 (list) (lambda () (raw-value Nothing)))])))))

(define/pow
  (fromRight [x : (Either a b)])
  #:returns (Maybe b)
  (thsl-src-control! "tesl/either.tesl" 61 (list (cons 'x *x)) (lambda () (let ([tesl-case-3 *x]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Left)) (thsl-src! "tesl/either.tesl" 62 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "tesl/either.tesl" 63 (list (cons 'v v)) (lambda () (raw-value (raw-value (Something *v))))))])))))

(define/pow
  (map [f : (-> b c)] [x : (Either a b)])
  #:returns (Either a c)
  (thsl-src-control! "tesl/either.tesl" 66 (list (cons 'f *f) (cons 'x *x)) (lambda () (let ([tesl-case-4 *x]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Left)) (let ([e (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "tesl/either.tesl" 67 (list (cons 'e e)) (lambda () (raw-value (raw-value (Left *e))))))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "tesl/either.tesl" 68 (list (cons 'v v)) (lambda () (raw-value (raw-value (Right (f *v)))))))])))))

(define/pow
  (mapLeft [f : (-> a c)] [x : (Either a b)])
  #:returns (Either c b)
  (thsl-src-control! "tesl/either.tesl" 71 (list (cons 'f *f) (cons 'x *x)) (lambda () (let ([tesl-case-5 *x]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Left)) (let ([e (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "tesl/either.tesl" 72 (list (cons 'e e)) (lambda () (raw-value (raw-value (Left (f *e)))))))] [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "tesl/either.tesl" 73 (list (cons 'v v)) (lambda () (raw-value (raw-value (Right *v))))))])))))

(define/pow
  (andThen [f : (-> b (Either a c))] [x : (Either a b)])
  #:returns (Either a c)
  (thsl-src-control! "tesl/either.tesl" 76 (list (cons 'f *f) (cons 'x *x)) (lambda () (let ([tesl-case-6 *x]) (cond [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Left)) (let ([e (hash-ref (adt-value-fields *tesl-case-6) 'value)]) (thsl-src! "tesl/either.tesl" 77 (list (cons 'e e)) (lambda () (raw-value (raw-value (Left *e))))))] [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl-case-6) 'value)]) (thsl-src! "tesl/either.tesl" 78 (list (cons 'v v)) (lambda () (raw-value (f *v)))))])))))

(define/pow
  (withDefault [default : b] [x : (Either a b)])
  #:returns b
  (thsl-src-control! "tesl/either.tesl" 81 (list (cons 'default *default) (cons 'x *x)) (lambda () (let ([tesl-case-7 *x]) (cond [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Left)) (thsl-src! "tesl/either.tesl" 82 (list) (lambda () *default))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl-case-7) 'value)]) (thsl-src! "tesl/either.tesl" 83 (list (cons 'v v)) (lambda () *v)))])))))

(define/pow
  (toMaybe [x : (Either a b)])
  #:returns (Maybe b)
  (thsl-src-control! "tesl/either.tesl" 86 (list (cons 'x *x)) (lambda () (let ([tesl-case-8 *x]) (cond [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Left)) (thsl-src! "tesl/either.tesl" 87 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl-case-8) 'value)]) (thsl-src! "tesl/either.tesl" 88 (list (cons 'v v)) (lambda () (raw-value (raw-value (Something *v))))))])))))

(define/pow
  (fromMaybe [leftVal : a] [m : (Maybe b)])
  #:returns (Either a b)
  (thsl-src-control! "tesl/either.tesl" 91 (list (cons 'leftVal *leftVal) (cons 'm *m)) (lambda () (let ([tesl-case-9 *m]) (cond [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Nothing)) (thsl-src! "tesl/either.tesl" 92 (list) (lambda () (raw-value (raw-value (Left *leftVal)))))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl-case-9) 'value)]) (thsl-src! "tesl/either.tesl" 93 (list (cons 'v v)) (lambda () (raw-value (raw-value (Right *v))))))])))))
