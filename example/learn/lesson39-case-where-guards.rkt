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
  (let ([tesl_case_0 *s]) (cond [(and (and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl_case_0) 'radius)]) (> *r 50))) (let ([r (hash-ref (adt-value-fields *tesl_case_0) 'radius)]) (raw-value "huge circle"))] [(and (and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl_case_0) 'radius)]) (> *r 20))) (let ([r (hash-ref (adt-value-fields *tesl_case_0) 'radius)]) (raw-value "large circle"))] [(and (and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl_case_0) 'radius)]) (> *r 5))) (let ([r (hash-ref (adt-value-fields *tesl_case_0) 'radius)]) (raw-value "medium circle"))] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Circle)) (raw-value "small circle")] [(and (and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Rectangle)) (let ([w (hash-ref (adt-value-fields *tesl_case_0) 'width)]) (let ([h (hash-ref (adt-value-fields *tesl_case_0) 'height)]) (equal? *w *h)))) (let ([w (hash-ref (adt-value-fields *tesl_case_0) 'width)]) (let ([h (hash-ref (adt-value-fields *tesl_case_0) 'height)]) (raw-value "square")))] [(and (and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Rectangle)) (let ([w (hash-ref (adt-value-fields *tesl_case_0) 'width)]) (let ([h (hash-ref (adt-value-fields *tesl_case_0) 'height)]) (and (> *w 30) (> *h 30))))) (let ([w (hash-ref (adt-value-fields *tesl_case_0) 'width)]) (let ([h (hash-ref (adt-value-fields *tesl_case_0) 'height)]) (raw-value "large rectangle")))] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Rectangle)) (raw-value "small rectangle")] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Triangle)) (raw-value "triangle")])))

(define/pow
  (describeShape [s : Shape])
  #:returns String
  (let ([tesl_case_1 *s]) (cond [(and (and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl_case_1) 'radius)]) (equal? *r 0))) (let ([r (hash-ref (adt-value-fields *tesl_case_1) 'radius)]) (raw-value "degenerate circle (point)"))] [(and (and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl_case_1) 'radius)]) (> *r 100))) (let ([r (hash-ref (adt-value-fields *tesl_case_1) 'radius)]) (raw-value (format "enormous circle (r=~a)" (tesl-display-val *r))))] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Circle)) (let ([r (hash-ref (adt-value-fields *tesl_case_1) 'radius)]) (raw-value (format "circle with radius ~a" (tesl-display-val *r))))] [(and (and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Rectangle)) (let ([w (hash-ref (adt-value-fields *tesl_case_1) 'width)]) (let ([h (hash-ref (adt-value-fields *tesl_case_1) 'height)]) (equal? *w *h)))) (let ([w (hash-ref (adt-value-fields *tesl_case_1) 'width)]) (let ([h (hash-ref (adt-value-fields *tesl_case_1) 'height)]) (raw-value (format "square with side ~a" (tesl-display-val *w)))))] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Rectangle)) (let ([w (hash-ref (adt-value-fields *tesl_case_1) 'width)]) (let ([h (hash-ref (adt-value-fields *tesl_case_1) 'height)]) (raw-value (format "rectangle ~ax~a" (tesl-display-val *w) (tesl-display-val *h)))))] [(and (and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Triangle)) (let ([b (hash-ref (adt-value-fields *tesl_case_1) 'base)]) (let ([h (hash-ref (adt-value-fields *tesl_case_1) 'height)]) (equal? *b *h)))) (let ([b (hash-ref (adt-value-fields *tesl_case_1) 'base)]) (let ([h (hash-ref (adt-value-fields *tesl_case_1) 'height)]) (raw-value "isosceles triangle")))] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Triangle)) (raw-value "triangle")])))

(define-adt Priority
  [Task [label : String] [urgency : Integer]]
  [Deadline [label : String] [days : Integer]]
)

(define/pow
  (classifyByPriority [p : Priority])
  #:returns String
  (let ([tesl_case_2 *p]) (cond [(and (and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Task)) (let ([label (hash-ref (adt-value-fields *tesl_case_2) 'label)]) (let ([urgency (hash-ref (adt-value-fields *tesl_case_2) 'urgency)]) (and (equal? *label "critical") (> *urgency 8))))) (let ([label (hash-ref (adt-value-fields *tesl_case_2) 'label)]) (let ([urgency (hash-ref (adt-value-fields *tesl_case_2) 'urgency)]) (raw-value "drop-everything")))] [(and (and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Task)) (let ([label (hash-ref (adt-value-fields *tesl_case_2) 'label)]) (let ([urgency (hash-ref (adt-value-fields *tesl_case_2) 'urgency)]) (> *urgency 8)))) (let ([label (hash-ref (adt-value-fields *tesl_case_2) 'label)]) (let ([urgency (hash-ref (adt-value-fields *tesl_case_2) 'urgency)]) (raw-value "urgent")))] [(and (and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Task)) (let ([label (hash-ref (adt-value-fields *tesl_case_2) 'label)]) (let ([urgency (hash-ref (adt-value-fields *tesl_case_2) 'urgency)]) (> *urgency 4)))) (let ([label (hash-ref (adt-value-fields *tesl_case_2) 'label)]) (let ([urgency (hash-ref (adt-value-fields *tesl_case_2) 'urgency)]) (raw-value "normal")))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Task)) (raw-value "low")] [(and (and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Deadline)) (let ([label (hash-ref (adt-value-fields *tesl_case_2) 'label)]) (let ([days (hash-ref (adt-value-fields *tesl_case_2) 'days)]) (equal? *days 0)))) (let ([label (hash-ref (adt-value-fields *tesl_case_2) 'label)]) (let ([days (hash-ref (adt-value-fields *tesl_case_2) 'days)]) (raw-value "due today")))] [(and (and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Deadline)) (let ([label (hash-ref (adt-value-fields *tesl_case_2) 'label)]) (let ([days (hash-ref (adt-value-fields *tesl_case_2) 'days)]) (< *days 0)))) (let ([label (hash-ref (adt-value-fields *tesl_case_2) 'label)]) (let ([days (hash-ref (adt-value-fields *tesl_case_2) 'days)]) (raw-value "overdue")))] [(and (and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Deadline)) (let ([label (hash-ref (adt-value-fields *tesl_case_2) 'label)]) (let ([days (hash-ref (adt-value-fields *tesl_case_2) 'days)]) (<= *days 3)))) (let ([label (hash-ref (adt-value-fields *tesl_case_2) 'label)]) (let ([days (hash-ref (adt-value-fields *tesl_case_2) 'days)]) (raw-value "soon")))] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Deadline)) (raw-value "future")])))

(define-adt (Labeled a)
  [Label [tag : String] [value : a]]
  [Empty]
)

(define/pow
  (processLabeled [x : (Labeled Integer)])
  #:returns String
  (let ([tesl_case_3 *x]) (cond [(and (and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Label)) (let ([tag (hash-ref (adt-value-fields *tesl_case_3) 'tag)]) (let ([value (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (and (equal? *tag "vip") (> *value 50))))) (let ([tag (hash-ref (adt-value-fields *tesl_case_3) 'tag)]) (let ([value (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (raw-value (format "VIP high-value: ~a" (tesl-display-val *value)))))] [(and (and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Label)) (let ([tag (hash-ref (adt-value-fields *tesl_case_3) 'tag)]) (let ([value (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (equal? *tag "vip")))) (let ([tag (hash-ref (adt-value-fields *tesl_case_3) 'tag)]) (let ([value (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (raw-value (format "VIP: ~a" (tesl-display-val *value)))))] [(and (and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Label)) (let ([value (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (> *value 50))) (let ([value (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (raw-value (format "high-value: ~a" (tesl-display-val *value))))] [(and (and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Label)) (let ([value (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (> *value 0))) (let ([value (hash-ref (adt-value-fields *tesl_case_3) 'value)]) (raw-value (format "positive: ~a" (tesl-display-val *value))))] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Label)) (raw-value "zero or negative")] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Empty)) (raw-value "empty")])))

(define/pow
  (scoreGrade [n : Integer])
  #:returns String
  (if (< *n 0) (raw-value "invalid") (if (> *n 100) (raw-value "invalid") (if (>= *n 90) (raw-value "A") (if (>= *n 80) (raw-value "B") (if (>= *n 70) (raw-value "C") (if (>= *n 60) (raw-value "D") (raw-value "F"))))))))

(define/pow
  (rateLabeled [x : (Labeled String)])
  #:returns String
  (let ([tesl_case_4 *x]) (cond [(and (and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Label)) (let ([tag (hash-ref (adt-value-fields *tesl_case_4) 'tag)]) (let ([value (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (and (equal? *tag "premium") (equal? *value "gold"))))) (let ([tag (hash-ref (adt-value-fields *tesl_case_4) 'tag)]) (let ([value (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (raw-value "premium gold")))] [(and (and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Label)) (let ([tag (hash-ref (adt-value-fields *tesl_case_4) 'tag)]) (let ([value (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (equal? *tag "premium")))) (let ([tag (hash-ref (adt-value-fields *tesl_case_4) 'tag)]) (let ([value (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (raw-value (format "premium: ~a" (tesl-display-val *value)))))] [(and (and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Label)) (let ([value (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (equal? *value ""))) (let ([value (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (raw-value "empty value"))] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Label)) (let ([value (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (raw-value (format "standard: ~a" (tesl-display-val *value))))] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Empty)) (raw-value "nothing")])))

(module+ test
  (require rackunit)
  (test-case "areaCategory circles"
  (check-equal? (raw-value (areaCategory (Circle 60))) "huge circle")
  (check-equal? (raw-value (areaCategory (Circle 25))) "large circle")
  (check-equal? (raw-value (areaCategory (Circle 10))) "medium circle")
  (check-equal? (raw-value (areaCategory (Circle 3))) "small circle")
  (check-equal? (raw-value (areaCategory (Circle 0))) "small circle")
  )

  (test-case "areaCategory rectangles"
  (check-equal? (raw-value (areaCategory (Rectangle 5 5))) "square")
  (check-equal? (raw-value (areaCategory (Rectangle 40 40))) "square")
  (check-equal? (raw-value (areaCategory (Rectangle 35 32))) "large rectangle")
  (check-equal? (raw-value (areaCategory (Rectangle 10 20))) "small rectangle")
  )

  (test-case "areaCategory triangles"
  (check-equal? (raw-value (areaCategory (Triangle 3 4))) "triangle")
  (check-equal? (raw-value (areaCategory (Triangle 5 5))) "triangle")
  )

  (test-case "describeShape"
  (check-equal? (raw-value (describeShape (Circle 0))) "degenerate circle (point)")
  (check-equal? (raw-value (describeShape (Circle 200))) "enormous circle (r=200)")
  (check-equal? (raw-value (describeShape (Circle 5))) "circle with radius 5")
  (check-equal? (raw-value (describeShape (Rectangle 7 7))) "square with side 7")
  (check-equal? (raw-value (describeShape (Rectangle 4 9))) "rectangle 4x9")
  (check-equal? (raw-value (describeShape (Triangle 6 6))) "isosceles triangle")
  (check-equal? (raw-value (describeShape (Triangle 3 4))) "triangle")
  )

  (test-case "classifyByPriority tasks"
  (check-equal? (raw-value (classifyByPriority (Task "critical" 9))) "drop-everything")
  (check-equal? (raw-value (classifyByPriority (Task "critical" 5))) "normal")
  (check-equal? (raw-value (classifyByPriority (Task "blocker" 9))) "urgent")
  (check-equal? (raw-value (classifyByPriority (Task "feature" 6))) "normal")
  (check-equal? (raw-value (classifyByPriority (Task "chore" 2))) "low")
  )

  (test-case "classifyByPriority deadlines"
  (check-equal? (raw-value (classifyByPriority (Deadline "report" 0))) "due today")
  (check-equal? (raw-value (classifyByPriority (Deadline "invoice" -2))) "overdue")
  (check-equal? (raw-value (classifyByPriority (Deadline "meeting" 2))) "soon")
  (check-equal? (raw-value (classifyByPriority (Deadline "review" 10))) "future")
  )

  (test-case "processLabeled integers"
  (check-equal? (raw-value (processLabeled (Label "vip" 99))) "VIP high-value: 99")
  (check-equal? (raw-value (processLabeled (Label "vip" 10))) "VIP: 10")
  (check-equal? (raw-value (processLabeled (Label "other" 75))) "high-value: 75")
  (check-equal? (raw-value (processLabeled (Label "other" 3))) "positive: 3")
  (check-equal? (raw-value (processLabeled (Label "other" 0))) "zero or negative")
  (check-equal? (raw-value (processLabeled Empty)) "empty")
  )

  (test-case "rateLabeled strings"
  (check-equal? (raw-value (rateLabeled (Label "premium" "gold"))) "premium gold")
  (check-equal? (raw-value (rateLabeled (Label "premium" "silver"))) "premium: silver")
  (check-equal? (raw-value (rateLabeled (Label "basic" ""))) "empty value")
  (check-equal? (raw-value (rateLabeled (Label "basic" "hello"))) "standard: hello")
  (check-equal? (raw-value (rateLabeled Empty)) "nothing")
  )

  (test-case "scoreGrade"
  (check-equal? (raw-value (scoreGrade 95)) "A")
  (check-equal? (raw-value (scoreGrade 85)) "B")
  (check-equal? (raw-value (scoreGrade 75)) "C")
  (check-equal? (raw-value (scoreGrade 65)) "D")
  (check-equal? (raw-value (scoreGrade 55)) "F")
  (check-equal? (raw-value (scoreGrade -1)) "invalid")
  (check-equal? (raw-value (scoreGrade 101)) "invalid")
  )

)
