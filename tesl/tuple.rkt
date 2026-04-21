#lang racket
(require "../dsl/types.rkt"
         (only-in "../dsl/private/evidence.rkt" raw-value))

(provide Tuple2 Tuple3
         Tuple2.first Tuple2.second
         Tuple3.first Tuple3.second Tuple3.third)

(define (tuple2-adt? value)
  (and (adt-value? value)
       (equal? (adt-value-type value) 'Tuple2)
       (eq? (adt-value-variant value) 'Tuple2)))

(define (tuple3-adt? value)
  (and (adt-value? value)
       (equal? (adt-value-type value) 'Tuple3)
       (eq? (adt-value-variant value) 'Tuple3)))

(define (tuple2-like? value)
  (or (tuple2-adt? value)
      (and (list? value) (= (length value) 2))))

(define (tuple3-like? value)
  (or (tuple3-adt? value)
      (and (list? value) (= (length value) 3))))

(define (Tuple2 first second)
  (adt-value 'Tuple2 'Tuple2 'Tuple2 (hash 'first first 'second second)))

(define (Tuple3 first second third)
  (adt-value 'Tuple3 'Tuple3 'Tuple3 (hash 'first first 'second second 'third third)))

(define (Tuple2.first t)
  (define value (raw-value t))
  (cond
    [(tuple2-adt? value)
     (hash-ref (adt-value-fields value) 'first)]
    [(and (list? value) (= (length value) 2))
     (first value)]
    [else
     (raise-user-error 'Tuple2.first "expected a Tuple2 value, got ~a" value)]))

(define (Tuple2.second t)
  (define value (raw-value t))
  (cond
    [(tuple2-adt? value)
     (hash-ref (adt-value-fields value) 'second)]
    [(and (list? value) (= (length value) 2))
     (second value)]
    [else
     (raise-user-error 'Tuple2.second "expected a Tuple2 value, got ~a" value)]))

(define (Tuple3.first t)
  (define value (raw-value t))
  (cond
    [(tuple3-adt? value)
     (hash-ref (adt-value-fields value) 'first)]
    [(and (list? value) (= (length value) 3))
     (first value)]
    [else
     (raise-user-error 'Tuple3.first "expected a Tuple3 value, got ~a" value)]))

(define (Tuple3.second t)
  (define value (raw-value t))
  (cond
    [(tuple3-adt? value)
     (hash-ref (adt-value-fields value) 'second)]
    [(and (list? value) (= (length value) 3))
     (second value)]
    [else
     (raise-user-error 'Tuple3.second "expected a Tuple3 value, got ~a" value)]))

(define (Tuple3.third t)
  (define value (raw-value t))
  (cond
    [(tuple3-adt? value)
     (hash-ref (adt-value-fields value) 'third)]
    [(and (list? value) (= (length value) 3))
     (third value)]
    [else
     (raise-user-error 'Tuple3.third "expected a Tuple3 value, got ~a" value)]))

(register-runtime-type/runtime! 'Tuple2 tuple2-like?)
(register-runtime-type/runtime! 'Tuple3 tuple3-like?)
