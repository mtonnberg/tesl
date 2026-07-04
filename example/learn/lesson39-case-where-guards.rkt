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
  (only-in tesl/tesl/prelude Int String)
)


(provide Shape Circle Rectangle Triangle Priority Task Deadline Labeled Label Empty areaCategory describeShape classifyByPriority processLabeled scoreGrade rateLabeled areaCategory-signature describeShape-signature classifyByPriority-signature processLabeled-signature scoreGrade-signature rateLabeled-signature)

(define-adt Shape
  [Circle [radius : Integer]]
  [Rectangle [width : Integer] [height : Integer]]
  [Triangle [base : Integer] [height : Integer]]
)

(define/pow
  (areaCategory [s : Shape])
  #:returns String
  (thsl-src-control! "example/learn/lesson39-case-where-guards.tesl" 56 (list (cons 's *s)) (lambda () (let ([tesl-case-0 *s]) (cond [(and (and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl-case-0) 'radius)]) (> *r 50))) (let ([r (hash-ref (adt-value-fields *tesl-case-0) 'radius)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 57 (list (cons 'r r)) (lambda () (raw-value "huge circle"))))] [(and (and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl-case-0) 'radius)]) (> *r 20))) (let ([r (hash-ref (adt-value-fields *tesl-case-0) 'radius)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 58 (list (cons 'r r)) (lambda () (raw-value "large circle"))))] [(and (and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl-case-0) 'radius)]) (> *r 5))) (let ([r (hash-ref (adt-value-fields *tesl-case-0) 'radius)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 59 (list (cons 'r r)) (lambda () (raw-value "medium circle"))))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Circle)) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 60 (list) (lambda () (raw-value "small circle")))] [(and (and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Rectangle)) (let ([w (hash-ref (adt-value-fields *tesl-case-0) 'width)]) (let ([h (hash-ref (adt-value-fields *tesl-case-0) 'height)]) (tesl-equal? *w *h)))) (let ([w (hash-ref (adt-value-fields *tesl-case-0) 'width)]) (let ([h (hash-ref (adt-value-fields *tesl-case-0) 'height)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 61 (list (cons 'w w) (cons 'h h)) (lambda () (raw-value "square")))))] [(and (and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Rectangle)) (let ([w (hash-ref (adt-value-fields *tesl-case-0) 'width)]) (let ([h (hash-ref (adt-value-fields *tesl-case-0) 'height)]) (and (> *w 30) (> *h 30))))) (let ([w (hash-ref (adt-value-fields *tesl-case-0) 'width)]) (let ([h (hash-ref (adt-value-fields *tesl-case-0) 'height)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 62 (list (cons 'w w) (cons 'h h)) (lambda () (raw-value "large rectangle")))))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Rectangle)) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 63 (list) (lambda () (raw-value "small rectangle")))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Triangle)) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 64 (list) (lambda () (raw-value "triangle")))])))))

(define/pow
  (describeShape [s : Shape])
  #:returns String
  (thsl-src-control! "example/learn/lesson39-case-where-guards.tesl" 68 (list (cons 's *s)) (lambda () (let ([tesl-case-1 *s]) (cond [(and (and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl-case-1) 'radius)]) (tesl-equal? *r 0))) (let ([r (hash-ref (adt-value-fields *tesl-case-1) 'radius)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 69 (list (cons 'r r)) (lambda () (raw-value "degenerate circle (point)"))))] [(and (and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl-case-1) 'radius)]) (> *r 100))) (let ([r (hash-ref (adt-value-fields *tesl-case-1) 'radius)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 70 (list (cons 'r r)) (lambda () (raw-value (format "enormous circle (r=~a)" (tesl-display-val *r))))))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl-case-1) 'radius)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 71 (list (cons 'r r)) (lambda () (raw-value (format "circle with radius ~a" (tesl-display-val *r))))))] [(and (and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Rectangle)) (let ([w (hash-ref (adt-value-fields *tesl-case-1) 'width)]) (let ([h (hash-ref (adt-value-fields *tesl-case-1) 'height)]) (tesl-equal? *w *h)))) (let ([w (hash-ref (adt-value-fields *tesl-case-1) 'width)]) (let ([h (hash-ref (adt-value-fields *tesl-case-1) 'height)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 72 (list (cons 'w w) (cons 'h h)) (lambda () (raw-value (format "square with side ~a" (tesl-display-val *w)))))))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Rectangle)) (let ([w (hash-ref (adt-value-fields *tesl-case-1) 'width)]) (let ([h (hash-ref (adt-value-fields *tesl-case-1) 'height)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 73 (list (cons 'w w) (cons 'h h)) (lambda () (raw-value (format "rectangle ~ax~a" (tesl-display-val *w) (tesl-display-val *h)))))))] [(and (and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Triangle)) (let ([b (hash-ref (adt-value-fields *tesl-case-1) 'base)]) (let ([h (hash-ref (adt-value-fields *tesl-case-1) 'height)]) (tesl-equal? *b *h)))) (let ([b (hash-ref (adt-value-fields *tesl-case-1) 'base)]) (let ([h (hash-ref (adt-value-fields *tesl-case-1) 'height)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 74 (list (cons 'b b) (cons 'h h)) (lambda () (raw-value "isosceles triangle")))))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Triangle)) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 75 (list) (lambda () (raw-value "triangle")))])))))

(define-adt Priority
  [Task [label : String] [urgency : Integer]]
  [Deadline [label : String] [days : Integer]]
)

(define/pow
  (classifyByPriority [p : Priority])
  #:returns String
  (thsl-src-control! "example/learn/lesson39-case-where-guards.tesl" 88 (list (cons 'p *p)) (lambda () (let ([tesl-case-2 *p]) (cond [(and (and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Task)) (let ([label (hash-ref (adt-value-fields *tesl-case-2) 'label)]) (let ([urgency (hash-ref (adt-value-fields *tesl-case-2) 'urgency)]) (and (tesl-equal? *label "critical") (> *urgency 8))))) (let ([label (hash-ref (adt-value-fields *tesl-case-2) 'label)]) (let ([urgency (hash-ref (adt-value-fields *tesl-case-2) 'urgency)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 89 (list (cons 'label label) (cons 'urgency urgency)) (lambda () (raw-value "drop-everything")))))] [(and (and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Task)) (let ([label (hash-ref (adt-value-fields *tesl-case-2) 'label)]) (let ([urgency (hash-ref (adt-value-fields *tesl-case-2) 'urgency)]) (> *urgency 8)))) (let ([label (hash-ref (adt-value-fields *tesl-case-2) 'label)]) (let ([urgency (hash-ref (adt-value-fields *tesl-case-2) 'urgency)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 90 (list (cons 'label label) (cons 'urgency urgency)) (lambda () (raw-value "urgent")))))] [(and (and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Task)) (let ([label (hash-ref (adt-value-fields *tesl-case-2) 'label)]) (let ([urgency (hash-ref (adt-value-fields *tesl-case-2) 'urgency)]) (> *urgency 4)))) (let ([label (hash-ref (adt-value-fields *tesl-case-2) 'label)]) (let ([urgency (hash-ref (adt-value-fields *tesl-case-2) 'urgency)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 91 (list (cons 'label label) (cons 'urgency urgency)) (lambda () (raw-value "normal")))))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Task)) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 92 (list) (lambda () (raw-value "low")))] [(and (and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Deadline)) (let ([label (hash-ref (adt-value-fields *tesl-case-2) 'label)]) (let ([days (hash-ref (adt-value-fields *tesl-case-2) 'days)]) (tesl-equal? *days 0)))) (let ([label (hash-ref (adt-value-fields *tesl-case-2) 'label)]) (let ([days (hash-ref (adt-value-fields *tesl-case-2) 'days)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 93 (list (cons 'label label) (cons 'days days)) (lambda () (raw-value "due today")))))] [(and (and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Deadline)) (let ([label (hash-ref (adt-value-fields *tesl-case-2) 'label)]) (let ([days (hash-ref (adt-value-fields *tesl-case-2) 'days)]) (< *days 0)))) (let ([label (hash-ref (adt-value-fields *tesl-case-2) 'label)]) (let ([days (hash-ref (adt-value-fields *tesl-case-2) 'days)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 94 (list (cons 'label label) (cons 'days days)) (lambda () (raw-value "overdue")))))] [(and (and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Deadline)) (let ([label (hash-ref (adt-value-fields *tesl-case-2) 'label)]) (let ([days (hash-ref (adt-value-fields *tesl-case-2) 'days)]) (<= *days 3)))) (let ([label (hash-ref (adt-value-fields *tesl-case-2) 'label)]) (let ([days (hash-ref (adt-value-fields *tesl-case-2) 'days)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 95 (list (cons 'label label) (cons 'days days)) (lambda () (raw-value "soon")))))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Deadline)) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 96 (list) (lambda () (raw-value "future")))])))))

(define-adt (Labeled a)
  [Label [tag : String] [value : a]]
  [Empty]
)

(define/pow
  (processLabeled [x : (Labeled Integer)])
  #:returns String
  (thsl-src-control! "example/learn/lesson39-case-where-guards.tesl" 109 (list (cons 'x *x)) (lambda () (let ([tesl-case-3 *x]) (cond [(and (and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Label)) (let ([tag (hash-ref (adt-value-fields *tesl-case-3) 'tag)]) (let ([value (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (and (tesl-equal? *tag "vip") (> *value 50))))) (let ([tag (hash-ref (adt-value-fields *tesl-case-3) 'tag)]) (let ([value (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 110 (list (cons 'tag tag) (cons 'value value)) (lambda () (raw-value (format "VIP high-value: ~a" (tesl-display-val *value)))))))] [(and (and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Label)) (let ([tag (hash-ref (adt-value-fields *tesl-case-3) 'tag)]) (let ([value (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (tesl-equal? *tag "vip")))) (let ([tag (hash-ref (adt-value-fields *tesl-case-3) 'tag)]) (let ([value (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 111 (list (cons 'tag tag) (cons 'value value)) (lambda () (raw-value (format "VIP: ~a" (tesl-display-val *value)))))))] [(and (and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Label)) (let ([value (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (> *value 50))) (let ([value (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 112 (list (cons 'value value)) (lambda () (raw-value (format "high-value: ~a" (tesl-display-val *value))))))] [(and (and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Label)) (let ([value (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (> *value 0))) (let ([value (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 113 (list (cons 'value value)) (lambda () (raw-value (format "positive: ~a" (tesl-display-val *value))))))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Label)) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 114 (list) (lambda () (raw-value "zero or negative")))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Empty)) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 115 (list) (lambda () (raw-value "empty")))])))))

(define/pow
  (scoreGrade [n : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 124 (list (cons 'n *n)) (lambda () (if (< *n 0) (raw-value "invalid") (if (> *n 100) (raw-value "invalid") (if (>= *n 90) (raw-value "A") (if (>= *n 80) (raw-value "B") (if (>= *n 70) (raw-value "C") (if (>= *n 60) (raw-value "D") (raw-value "F"))))))))))

(define/pow
  (rateLabeled [x : (Labeled String)])
  #:returns String
  (thsl-src-control! "example/learn/lesson39-case-where-guards.tesl" 141 (list (cons 'x *x)) (lambda () (let ([tesl-case-4 *x]) (cond [(and (and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Label)) (let ([tag (hash-ref (adt-value-fields *tesl-case-4) 'tag)]) (let ([value (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (and (tesl-equal? *tag "premium") (tesl-equal? *value "gold"))))) (let ([tag (hash-ref (adt-value-fields *tesl-case-4) 'tag)]) (let ([value (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 142 (list (cons 'tag tag) (cons 'value value)) (lambda () (raw-value "premium gold")))))] [(and (and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Label)) (let ([tag (hash-ref (adt-value-fields *tesl-case-4) 'tag)]) (let ([value (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (tesl-equal? *tag "premium")))) (let ([tag (hash-ref (adt-value-fields *tesl-case-4) 'tag)]) (let ([value (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 143 (list (cons 'tag tag) (cons 'value value)) (lambda () (raw-value (format "premium: ~a" (tesl-display-val *value)))))))] [(and (and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Label)) (let ([value (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (tesl-equal? *value ""))) (let ([value (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 144 (list (cons 'value value)) (lambda () (raw-value "empty value"))))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Label)) (let ([value (hash-ref (adt-value-fields *tesl-case-4) 'value)]) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 145 (list (cons 'value value)) (lambda () (raw-value (format "standard: ~a" (tesl-display-val *value))))))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'Empty)) (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 146 (list) (lambda () (raw-value "nothing")))])))))

(module+ test
  (require rackunit)
  (test-case "areaCategory circles"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 213 (list) (lambda () (areaCategory (Circle 60))))) "huge circle")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 214 (list) (lambda () (areaCategory (Circle 25))))) "large circle")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 215 (list) (lambda () (areaCategory (Circle 10))))) "medium circle")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 216 (list) (lambda () (areaCategory (Circle 3))))) "small circle")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 217 (list) (lambda () (areaCategory (Circle 0))))) "small circle")
    ))
  )

  (test-case "areaCategory rectangles"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 221 (list) (lambda () (areaCategory (Rectangle 5 5))))) "square")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 222 (list) (lambda () (areaCategory (Rectangle 40 40))))) "square")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 223 (list) (lambda () (areaCategory (Rectangle 35 32))))) "large rectangle")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 224 (list) (lambda () (areaCategory (Rectangle 10 20))))) "small rectangle")
    ))
  )

  (test-case "areaCategory triangles"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 228 (list) (lambda () (areaCategory (Triangle 3 4))))) "triangle")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 229 (list) (lambda () (areaCategory (Triangle 5 5))))) "triangle")
    ))
  )

  (test-case "describeShape"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 233 (list) (lambda () (describeShape (Circle 0))))) "degenerate circle (point)")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 234 (list) (lambda () (describeShape (Circle 200))))) "enormous circle (r=200)")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 235 (list) (lambda () (describeShape (Circle 5))))) "circle with radius 5")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 236 (list) (lambda () (describeShape (Rectangle 7 7))))) "square with side 7")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 237 (list) (lambda () (describeShape (Rectangle 4 9))))) "rectangle 4x9")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 238 (list) (lambda () (describeShape (Triangle 6 6))))) "isosceles triangle")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 239 (list) (lambda () (describeShape (Triangle 3 4))))) "triangle")
    ))
  )

  (test-case "classifyByPriority tasks"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 243 (list) (lambda () (classifyByPriority (Task "critical" 9))))) "drop-everything")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 244 (list) (lambda () (classifyByPriority (Task "critical" 5))))) "normal")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 245 (list) (lambda () (classifyByPriority (Task "blocker" 9))))) "urgent")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 246 (list) (lambda () (classifyByPriority (Task "feature" 6))))) "normal")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 247 (list) (lambda () (classifyByPriority (Task "chore" 2))))) "low")
    ))
  )

  (test-case "classifyByPriority deadlines"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 251 (list) (lambda () (classifyByPriority (Deadline "report" 0))))) "due today")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 252 (list) (lambda () (classifyByPriority (Deadline "invoice" -2))))) "overdue")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 253 (list) (lambda () (classifyByPriority (Deadline "meeting" 2))))) "soon")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 254 (list) (lambda () (classifyByPriority (Deadline "review" 10))))) "future")
    ))
  )

  (test-case "processLabeled integers"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 258 (list) (lambda () (processLabeled (Label "vip" 99))))) "VIP high-value: 99")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 259 (list) (lambda () (processLabeled (Label "vip" 10))))) "VIP: 10")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 260 (list) (lambda () (processLabeled (Label "other" 75))))) "high-value: 75")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 261 (list) (lambda () (processLabeled (Label "other" 3))))) "positive: 3")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 262 (list) (lambda () (processLabeled (Label "other" 0))))) "zero or negative")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 263 (list) (lambda () (processLabeled Empty)))) "empty")
    ))
  )

  (test-case "rateLabeled strings"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 267 (list) (lambda () (rateLabeled (Label "premium" "gold"))))) "premium gold")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 268 (list) (lambda () (rateLabeled (Label "premium" "silver"))))) "premium: silver")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 269 (list) (lambda () (rateLabeled (Label "basic" ""))))) "empty value")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 270 (list) (lambda () (rateLabeled (Label "basic" "hello"))))) "standard: hello")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 271 (list) (lambda () (rateLabeled Empty)))) "nothing")
    ))
  )

  (test-case "scoreGrade"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 275 (list) (lambda () (scoreGrade 95)))) "A")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 276 (list) (lambda () (scoreGrade 85)))) "B")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 277 (list) (lambda () (scoreGrade 75)))) "C")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 278 (list) (lambda () (scoreGrade 65)))) "D")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 279 (list) (lambda () (scoreGrade 55)))) "F")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 280 (list) (lambda () (scoreGrade -1)))) "invalid")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson39-case-where-guards.tesl" 281 (list) (lambda () (scoreGrade 101)))) "invalid")
    ))
  )

)
