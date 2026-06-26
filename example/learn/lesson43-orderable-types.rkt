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
  (thsl-src! "example/learn/lesson43-orderable-types.tesl" 70 (list (cons 'n *n)) (lambda () (raw-value (Score *n)))))

(define/pow
  (scoreToInt [s : Score])
  #:returns Integer
  (thsl-src! "example/learn/lesson43-orderable-types.tesl" 71 (list (cons 's *s)) (lambda () (raw-value s.value))))

(define/pow
  (makeRank [s : Score])
  #:returns Rank
  (thsl-src! "example/learn/lesson43-orderable-types.tesl" 73 (list (cons 's *s)) (lambda () (raw-value (Rank *s)))))

(define/pow
  (rankToInt [r : Rank])
  #:returns Integer
  (thsl-src! "example/learn/lesson43-orderable-types.tesl" 74 (list (cons 'r *r)) (lambda () (tesl-dot/runtime r.value 'value))))

(define/pow
  (makePriority [n : Integer])
  #:returns Priority
  (thsl-src! "example/learn/lesson43-orderable-types.tesl" 76 (list (cons 'n *n)) (lambda () (raw-value (Priority *n)))))

(define/pow
  (priorityToInt [p : Priority])
  #:returns Integer
  (thsl-src! "example/learn/lesson43-orderable-types.tesl" 77 (list (cons 'p *p)) (lambda () (raw-value p.value))))

(define/pow
  (clampScore [value : Score] [lo : Score] [hi : Score])
  #:returns Score
  (thsl-src! "example/learn/lesson43-orderable-types.tesl" 84 (list (cons 'value *value) (cons 'lo *lo) (cons 'hi *hi)) (lambda () (if (<= (raw-value (scoreToInt value)) (raw-value (scoreToInt lo))) *lo (if (>= (raw-value (scoreToInt value)) (raw-value (scoreToInt hi))) *hi *value)))))

(define/pow
  (higherRank [a : Rank] [b : Rank])
  #:returns Rank
  (thsl-src! "example/learn/lesson43-orderable-types.tesl" 95 (list (cons 'a *a) (cons 'b *b)) (lambda () (if (> (raw-value (rankToInt a)) (raw-value (rankToInt b))) *a *b))))

(define/pow
  (moreUrgent [a : Priority] [b : Priority])
  #:returns Priority
  (let ([aInt (thsl-src! "example/learn/lesson43-orderable-types.tesl" 103 (list (cons 'a *a) (cons 'b *b)) (lambda () (raw-value a.value)))]) (let ([bInt (thsl-src! "example/learn/lesson43-orderable-types.tesl" 104 (list (cons 'aInt *aInt) (cons 'a *a) (cons 'b *b)) (lambda () (raw-value b.value)))]) (thsl-src! "example/learn/lesson43-orderable-types.tesl" 105 (list (cons 'bInt *bInt) (cons 'aInt *aInt) (cons 'a *a) (cons 'b *b)) (lambda () (if (< (raw-value aInt) (raw-value bInt)) *a *b))))))

(define/pow
  (sortedPair [a : Integer] [b : Integer])
  #:returns (List Integer)
  (thsl-src! "example/learn/lesson43-orderable-types.tesl" 114 (list (cons 'a *a) (cons 'b *b)) (lambda () (if (<= *a *b) (raw-value (list *a *b)) (raw-value (list *b *a))))))

(define/pow
  (isAffordable [price : Real] [budget : Real])
  #:returns Boolean
  (thsl-src! "example/learn/lesson43-orderable-types.tesl" 121 (list (cons 'price *price) (cons 'budget *budget)) (lambda () (<= *price *budget))))

(define/pow
  (createdBefore [t1 : PosixMillis] [t2 : PosixMillis])
  #:returns Boolean
  (thsl-src! "example/learn/lesson43-orderable-types.tesl" 126 (list (cons 't1 *t1) (cons 't2 *t2)) (lambda () (< (raw-value t1.value) (raw-value t2.value)))))

(module+ test
  (require rackunit)
  (test-case "clampScore: in range"
  (define lo (thsl-src! "example/learn/lesson43-orderable-types.tesl" 193 (list) (lambda () (makeScore 0))))
  (define hi (thsl-src! "example/learn/lesson43-orderable-types.tesl" 194 (list (cons 'lo lo)) (lambda () (makeScore 100))))
  (define mid (thsl-src! "example/learn/lesson43-orderable-types.tesl" 195 (list (cons 'hi hi) (cons 'lo lo)) (lambda () (makeScore 50))))
  (define s (thsl-src! "example/learn/lesson43-orderable-types.tesl" 196 (list (cons 'mid mid) (cons 'hi hi) (cons 'lo lo)) (lambda () (clampScore mid lo hi))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 197 (list (cons 's s) (cons 'mid mid) (cons 'hi hi) (cons 'lo lo)) (lambda () (scoreToInt s)))) 50)
  )

  (test-case "clampScore: below lo is clamped up"
  (define lo (thsl-src! "example/learn/lesson43-orderable-types.tesl" 201 (list) (lambda () (makeScore 0))))
  (define hi (thsl-src! "example/learn/lesson43-orderable-types.tesl" 202 (list (cons 'lo lo)) (lambda () (makeScore 100))))
  (define low (thsl-src! "example/learn/lesson43-orderable-types.tesl" 203 (list (cons 'hi hi) (cons 'lo lo)) (lambda () (makeScore -10))))
  (define s (thsl-src! "example/learn/lesson43-orderable-types.tesl" 204 (list (cons 'low low) (cons 'hi hi) (cons 'lo lo)) (lambda () (clampScore low lo hi))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 205 (list (cons 's s) (cons 'low low) (cons 'hi hi) (cons 'lo lo)) (lambda () (scoreToInt s)))) 0)
  )

  (test-case "clampScore: above hi is clamped down"
  (define lo (thsl-src! "example/learn/lesson43-orderable-types.tesl" 209 (list) (lambda () (makeScore 0))))
  (define hi (thsl-src! "example/learn/lesson43-orderable-types.tesl" 210 (list (cons 'lo lo)) (lambda () (makeScore 100))))
  (define over (thsl-src! "example/learn/lesson43-orderable-types.tesl" 211 (list (cons 'hi hi) (cons 'lo lo)) (lambda () (makeScore 200))))
  (define s (thsl-src! "example/learn/lesson43-orderable-types.tesl" 212 (list (cons 'over over) (cons 'hi hi) (cons 'lo lo)) (lambda () (clampScore over lo hi))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 213 (list (cons 's s) (cons 'over over) (cons 'hi hi) (cons 'lo lo)) (lambda () (scoreToInt s)))) 100)
  )

  (test-case "clampScore: at boundary values"
  (define lo (thsl-src! "example/learn/lesson43-orderable-types.tesl" 217 (list) (lambda () (makeScore 5))))
  (define hi (thsl-src! "example/learn/lesson43-orderable-types.tesl" 218 (list (cons 'lo lo)) (lambda () (makeScore 10))))
  (define atLo (thsl-src! "example/learn/lesson43-orderable-types.tesl" 219 (list (cons 'hi hi) (cons 'lo lo)) (lambda () (makeScore 5))))
  (define atHi (thsl-src! "example/learn/lesson43-orderable-types.tesl" 220 (list (cons 'atLo atLo) (cons 'hi hi) (cons 'lo lo)) (lambda () (makeScore 10))))
  (define sLo (thsl-src! "example/learn/lesson43-orderable-types.tesl" 221 (list (cons 'atHi atHi) (cons 'atLo atLo) (cons 'hi hi) (cons 'lo lo)) (lambda () (clampScore atLo lo hi))))
  (define sHi (thsl-src! "example/learn/lesson43-orderable-types.tesl" 222 (list (cons 'sLo sLo) (cons 'atHi atHi) (cons 'atLo atLo) (cons 'hi hi) (cons 'lo lo)) (lambda () (clampScore atHi lo hi))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 223 (list (cons 'sHi sHi) (cons 'sLo sLo) (cons 'atHi atHi) (cons 'atLo atLo) (cons 'hi hi) (cons 'lo lo)) (lambda () (scoreToInt sLo)))) 5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 224 (list (cons 'sHi sHi) (cons 'sLo sLo) (cons 'atHi atHi) (cons 'atLo atLo) (cons 'hi hi) (cons 'lo lo)) (lambda () (scoreToInt sHi)))) 10)
  )

  (test-case "higherRank: returns the greater rank"
  (define a (thsl-src! "example/learn/lesson43-orderable-types.tesl" 228 (list) (lambda () (makeRank (makeScore 3)))))
  (define b (thsl-src! "example/learn/lesson43-orderable-types.tesl" 229 (list (cons 'a a)) (lambda () (makeRank (makeScore 7)))))
  (define r1 (thsl-src! "example/learn/lesson43-orderable-types.tesl" 230 (list (cons 'b b) (cons 'a a)) (lambda () (higherRank a b))))
  (define r2 (thsl-src! "example/learn/lesson43-orderable-types.tesl" 231 (list (cons 'r1 r1) (cons 'b b) (cons 'a a)) (lambda () (higherRank b a))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 232 (list (cons 'r2 r2) (cons 'r1 r1) (cons 'b b) (cons 'a a)) (lambda () (rankToInt r1)))) 7)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 233 (list (cons 'r2 r2) (cons 'r1 r1) (cons 'b b) (cons 'a a)) (lambda () (rankToInt r2)))) 7)
  )

  (test-case "higherRank: tie returns first"
  (define a (thsl-src! "example/learn/lesson43-orderable-types.tesl" 237 (list) (lambda () (makeRank (makeScore 5)))))
  (define b (thsl-src! "example/learn/lesson43-orderable-types.tesl" 238 (list (cons 'a a)) (lambda () (makeRank (makeScore 5)))))
  (define r (thsl-src! "example/learn/lesson43-orderable-types.tesl" 239 (list (cons 'b b) (cons 'a a)) (lambda () (higherRank a b))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 240 (list (cons 'r r) (cons 'b b) (cons 'a a)) (lambda () (rankToInt r)))) 5)
  )

  (test-case "moreUrgent: lower priority number wins"
  (define p1 (thsl-src! "example/learn/lesson43-orderable-types.tesl" 244 (list) (lambda () (makePriority 1))))
  (define p2 (thsl-src! "example/learn/lesson43-orderable-types.tesl" 245 (list (cons 'p1 p1)) (lambda () (makePriority 5))))
  (define u1 (thsl-src! "example/learn/lesson43-orderable-types.tesl" 246 (list (cons 'p2 p2) (cons 'p1 p1)) (lambda () (moreUrgent p1 p2))))
  (define u2 (thsl-src! "example/learn/lesson43-orderable-types.tesl" 247 (list (cons 'u1 u1) (cons 'p2 p2) (cons 'p1 p1)) (lambda () (moreUrgent p2 p1))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 248 (list (cons 'u2 u2) (cons 'u1 u1) (cons 'p2 p2) (cons 'p1 p1)) (lambda () (priorityToInt u1)))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 249 (list (cons 'u2 u2) (cons 'u1 u1) (cons 'p2 p2) (cons 'p1 p1)) (lambda () (priorityToInt u2)))) 1)
  )

  (test-case "sortedPair: plain Int ordering"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 253 (list) (lambda () (sortedPair 3 7)))) (list 3 7))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 254 (list) (lambda () (sortedPair 7 3)))) (list 3 7))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 255 (list) (lambda () (sortedPair 5 5)))) (list 5 5))
  )

  (test-case "isAffordable: Float ordering"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 259 (list) (lambda () (isAffordable 9.99 10.)))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 260 (list) (lambda () (isAffordable 10. 10.)))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 261 (list) (lambda () (isAffordable 10.01 10.)))) #f)
  )

  (test-case "createdBefore: PosixMillis ordering"
  (define earlier (thsl-src! "example/learn/lesson43-orderable-types.tesl" 265 (list) (lambda () (raw-value (tesl_import_Time_secondsToPosix 1000)))))
  (define later (thsl-src! "example/learn/lesson43-orderable-types.tesl" 266 (list (cons 'earlier earlier)) (lambda () (raw-value (tesl_import_Time_secondsToPosix 2000)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 267 (list (cons 'later later) (cons 'earlier earlier)) (lambda () (createdBefore earlier later)))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 268 (list (cons 'later later) (cons 'earlier earlier)) (lambda () (createdBefore later earlier)))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson43-orderable-types.tesl" 269 (list (cons 'later later) (cons 'earlier earlier)) (lambda () (createdBefore earlier earlier)))) #f)
  )

)
