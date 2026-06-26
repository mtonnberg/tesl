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
  (thsl-src! "tesl/either.tesl" 46 (list (cons 'x *x)) (lambda () (let ([tesl_case_0 *x]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Left)) (raw-value #t)] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Right)) (raw-value #f)])))))

(define/pow
  (isRight [x : (Either a b)])
  #:returns Boolean
  (thsl-src! "tesl/either.tesl" 51 (list (cons 'x *x)) (lambda () (let ([tesl_case_1 *x]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Left)) (raw-value #f)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Right)) (raw-value #t)])))))

(define/pow
  (fromLeft [x : (Either a b)])
  #:returns (Maybe a)
  (thsl-src! "tesl/either.tesl" 56 (list (cons 'x *x)) (lambda () (let ([tesl_case_2 *x]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Left)) (let ([v (hash-ref (adt-value-fields *tesl_case_2) 'value)]) (raw-value (raw-value (Something *v))))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Right)) (raw-value Nothing)])))))

(define/pow
  (fromRight [x : (Either a b)])
  #:returns (Maybe b)
  (thsl-src! "tesl/either.tesl" 61 (list (cons 'x *x)) (lambda () (let ([tesl_case_3 *x]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Left)) (raw-value Nothing)] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (raw-value (raw-value (Something *v))))])))))

(define/pow
  (map [f : (-> b c)] [x : (Either a b)])
  #:returns (Either a c)
  (thsl-src! "tesl/either.tesl" 66 (list (cons 'f *f) (cons 'x *x)) (lambda () (let ([tesl_case_4 *x]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Left)) (let ([e (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (raw-value (raw-value (Left *e))))] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (raw-value (raw-value (Right (f *v)))))])))))

(define/pow
  (mapLeft [f : (-> a c)] [x : (Either a b)])
  #:returns (Either c b)
  (thsl-src! "tesl/either.tesl" 71 (list (cons 'f *f) (cons 'x *x)) (lambda () (let ([tesl_case_5 *x]) (cond [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Left)) (let ([e (hash-ref (adt-value-fields *tesl_case_5) 'value)]) (raw-value (raw-value (Left (f *e)))))] [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl_case_5) 'value)]) (raw-value (raw-value (Right *v))))])))))

(define/pow
  (andThen [f : (-> b (Either a c))] [x : (Either a b)])
  #:returns (Either a c)
  (thsl-src! "tesl/either.tesl" 76 (list (cons 'f *f) (cons 'x *x)) (lambda () (let ([tesl_case_6 *x]) (cond [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Left)) (let ([e (hash-ref (adt-value-fields *tesl_case_6) 'value)]) (raw-value (raw-value (Left *e))))] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl_case_6) 'value)]) (raw-value (f *v)))])))))

(define/pow
  (withDefault [default : b] [x : (Either a b)])
  #:returns b
  (thsl-src! "tesl/either.tesl" 81 (list (cons 'default *default) (cons 'x *x)) (lambda () (let ([tesl_case_7 *x]) (cond [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Left)) *default] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl_case_7) 'value)]) *v)])))))

(define/pow
  (toMaybe [x : (Either a b)])
  #:returns (Maybe b)
  (thsl-src! "tesl/either.tesl" 86 (list (cons 'x *x)) (lambda () (let ([tesl_case_8 *x]) (cond [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Left)) (raw-value Nothing)] [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Right)) (let ([v (hash-ref (adt-value-fields *tesl_case_8) 'value)]) (raw-value (raw-value (Something *v))))])))))

(define/pow
  (fromMaybe [leftVal : a] [m : (Maybe b)])
  #:returns (Either a b)
  (thsl-src! "tesl/either.tesl" 91 (list (cons 'leftVal *leftVal) (cons 'm *m)) (lambda () (let ([tesl_case_9 *m]) (cond [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Nothing)) (raw-value (raw-value (Left *leftVal)))] [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl_case_9) 'value)]) (raw-value (raw-value (Right *v))))])))))
