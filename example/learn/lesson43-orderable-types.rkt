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
  (only-in tesl/tesl/prelude Bool Int List)
  (only-in tesl/tesl/float Float)
  (only-in tesl/tesl/time PosixMillis [Time.secondsToPosix tesl_import_Time_secondsToPosix])
)


(provide Score Rank Priority makeScore scoreToInt makeRank rankToInt makePriority priorityToInt clampScore higherRank moreUrgent sortedPair isAffordable createdBefore makeScore-signature scoreToInt-signature makeRank-signature rankToInt-signature makePriority-signature priorityToInt-signature clampScore-signature higherRank-signature moreUrgent-signature sortedPair-signature isAffordable-signature createdBefore-signature)

(define-newtype Score Integer)

(define-newtype Rank Score)

(define-newtype Priority Integer)

(define/pow
  (makeScore [n : Integer])
  #:returns Score
  (raw-value (Score *n)))

(define/pow
  (scoreToInt [s : Score])
  #:returns Integer
  (raw-value s.value))

(define/pow
  (makeRank [s : Score])
  #:returns Rank
  (raw-value (Rank *s)))

(define/pow
  (rankToInt [r : Rank])
  #:returns Integer
  (tesl-dot/runtime r.value 'value))

(define/pow
  (makePriority [n : Integer])
  #:returns Priority
  (raw-value (Priority *n)))

(define/pow
  (priorityToInt [p : Priority])
  #:returns Integer
  (raw-value p.value))

(define/pow
  (clampScore [value : Score] [lo : Score] [hi : Score])
  #:returns Score
  (if (<= (raw-value (scoreToInt value)) (raw-value (scoreToInt lo))) *lo (if (>= (raw-value (scoreToInt value)) (raw-value (scoreToInt hi))) *hi *value)))

(define/pow
  (higherRank [a : Rank] [b : Rank])
  #:returns Rank
  (if (> (raw-value (rankToInt a)) (raw-value (rankToInt b))) *a *b))

(define/pow
  (moreUrgent [a : Priority] [b : Priority])
  #:returns Priority
  (let ([aInt (raw-value a.value)]) (let ([bInt (raw-value b.value)]) (if (< (raw-value aInt) (raw-value bInt)) *a *b))))

(define/pow
  (sortedPair [a : Integer] [b : Integer])
  #:returns (List Integer)
  (if (<= *a *b) (raw-value (list *a *b)) (raw-value (list *b *a))))

(define/pow
  (isAffordable [price : Real] [budget : Real])
  #:returns Boolean
  (<= *price *budget))

(define/pow
  (createdBefore [t1 : PosixMillis] [t2 : PosixMillis])
  #:returns Boolean
  (< (raw-value t1.value) (raw-value t2.value)))

(module+ test
  (require rackunit)
  (test-case "clampScore: in range"
  (define lo (makeScore 0))
  (define hi (makeScore 100))
  (define mid (makeScore 50))
  (define s (clampScore mid lo hi))
  (check-equal? (raw-value (scoreToInt s)) 50)
  )

  (test-case "clampScore: below lo is clamped up"
  (define lo (makeScore 0))
  (define hi (makeScore 100))
  (define low (makeScore -10))
  (define s (clampScore low lo hi))
  (check-equal? (raw-value (scoreToInt s)) 0)
  )

  (test-case "clampScore: above hi is clamped down"
  (define lo (makeScore 0))
  (define hi (makeScore 100))
  (define over (makeScore 200))
  (define s (clampScore over lo hi))
  (check-equal? (raw-value (scoreToInt s)) 100)
  )

  (test-case "clampScore: at boundary values"
  (define lo (makeScore 5))
  (define hi (makeScore 10))
  (define atLo (makeScore 5))
  (define atHi (makeScore 10))
  (define sLo (clampScore atLo lo hi))
  (define sHi (clampScore atHi lo hi))
  (check-equal? (raw-value (scoreToInt sLo)) 5)
  (check-equal? (raw-value (scoreToInt sHi)) 10)
  )

  (test-case "higherRank: returns the greater rank"
  (define a (makeRank (makeScore 3)))
  (define b (makeRank (makeScore 7)))
  (define r1 (higherRank a b))
  (define r2 (higherRank b a))
  (check-equal? (raw-value (rankToInt r1)) 7)
  (check-equal? (raw-value (rankToInt r2)) 7)
  )

  (test-case "higherRank: tie returns first"
  (define a (makeRank (makeScore 5)))
  (define b (makeRank (makeScore 5)))
  (define r (higherRank a b))
  (check-equal? (raw-value (rankToInt r)) 5)
  )

  (test-case "moreUrgent: lower priority number wins"
  (define p1 (makePriority 1))
  (define p2 (makePriority 5))
  (define u1 (moreUrgent p1 p2))
  (define u2 (moreUrgent p2 p1))
  (check-equal? (raw-value (priorityToInt u1)) 1)
  (check-equal? (raw-value (priorityToInt u2)) 1)
  )

  (test-case "sortedPair: plain Int ordering"
  (check-equal? (raw-value (sortedPair 3 7)) (list 3 7))
  (check-equal? (raw-value (sortedPair 7 3)) (list 3 7))
  (check-equal? (raw-value (sortedPair 5 5)) (list 5 5))
  )

  (test-case "isAffordable: Float ordering"
  (check-equal? (raw-value (isAffordable 9.99 10.)) #t)
  (check-equal? (raw-value (isAffordable 10. 10.)) #t)
  (check-equal? (raw-value (isAffordable 10.01 10.)) #f)
  )

  (test-case "createdBefore: PosixMillis ordering"
  (define earlier (raw-value (tesl_import_Time_secondsToPosix 1000)))
  (define later (raw-value (tesl_import_Time_secondsToPosix 2000)))
  (check-equal? (raw-value (createdBefore earlier later)) #t)
  (check-equal? (raw-value (createdBefore later earlier)) #f)
  (check-equal? (raw-value (createdBefore earlier earlier)) #f)
  )

)
