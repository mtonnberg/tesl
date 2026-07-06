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
  (only-in tesl/tesl/prelude Int)
)


(provide Point Rectangle area perimeter translate scale origin setX moveOrigin resetOrigin flipDimensions area-signature perimeter-signature translate-signature scale-signature origin-signature setX-signature moveOrigin-signature resetOrigin-signature flipDimensions-signature)

(define-record Point
  [x : Integer]
  [y : Integer]
)

(define-record Rectangle
  [origin : Point]
  [width : Integer]
  [height : Integer]
)

(define/pow
  (area [r : Rectangle])
  #:returns Integer
  (thsl-src! "example/learn/lesson03-records.tesl" 45 (list (cons 'r *r)) (lambda () (* (tesl-dot/runtime r 'width 'Rectangle) (tesl-dot/runtime r 'height 'Rectangle)))))

(define/pow
  (perimeter [r : Rectangle])
  #:returns Integer
  (thsl-src! "example/learn/lesson03-records.tesl" 49 (list (cons 'r *r)) (lambda () (* 2 (+ (tesl-dot/runtime r 'width 'Rectangle) (tesl-dot/runtime r 'height 'Rectangle))))))

(define/pow
  (translate [p : Point] [dx : Integer] [dy : Integer])
  #:returns Point
  (thsl-src! "example/learn/lesson03-records.tesl" 53 (list (cons 'p *p) (cons 'dx *dx) (cons 'dy *dy)) (lambda () (Point #:x (+ (tesl-dot/runtime p 'x 'Point) *dx) #:y (+ (tesl-dot/runtime p 'y 'Point) *dy)))))

(define/pow
  (scale [r : Rectangle] [factor : Integer])
  #:returns Rectangle
  (thsl-src! "example/learn/lesson03-records.tesl" 57 (list (cons 'r *r) (cons 'factor *factor)) (lambda () (tesl-record-update *r (hash 'width (raw-value (* (tesl-dot/runtime r 'width 'Rectangle) *factor)) 'height (raw-value (* (tesl-dot/runtime r 'height 'Rectangle) *factor)))))))

(define/pow
  (origin)
  #:returns Point
  (thsl-src! "example/learn/lesson03-records.tesl" 62 (list) (lambda () (Point #:x 0 #:y 0))))

(define/pow
  (setX [p : Point] [newX : Integer])
  #:returns Point
  (thsl-src! "example/learn/lesson03-records.tesl" 69 (list (cons 'p *p) (cons 'newX *newX)) (lambda () (tesl-record-update *p (hash 'x *newX)))))

(define/pow
  (moveOrigin [r : Rectangle] [dx : Integer] [dy : Integer])
  #:returns Rectangle
  (thsl-src! "example/learn/lesson03-records.tesl" 73 (list (cons 'r *r) (cons 'dx *dx) (cons 'dy *dy)) (lambda () (tesl-record-update *r (hash 'origin (raw-value (translate (tesl-dot/runtime r 'origin 'Rectangle) dx dy)))))))

(define/pow
  (resetOrigin [r : Rectangle])
  #:returns Rectangle
  (thsl-src! "example/learn/lesson03-records.tesl" 77 (list (cons 'r *r)) (lambda () (tesl-record-update *r (hash 'origin (raw-value (Point #:x 0 #:y 0)))))))

(define/pow
  (flipDimensions [r : Rectangle])
  #:returns Rectangle
  (thsl-src! "example/learn/lesson03-records.tesl" 81 (list (cons 'r *r)) (lambda () (tesl-record-update *r (hash 'width (tesl-dot/runtime r 'height) 'height (tesl-dot/runtime r 'width))))))

(module+ test
  (require rackunit)
  (test-case "area"
    (call-with-fresh-memory-db '() (lambda ()
  (define rect (thsl-src! "example/learn/lesson03-records.tesl" 84 (list) (lambda () (Rectangle #:origin (Point #:x 0 #:y 0) #:width 4 #:height 3))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson03-records.tesl" 85 (list (cons 'rect rect)) (lambda () (area rect)))) 12)
  (define unit (thsl-src! "example/learn/lesson03-records.tesl" 86 (list (cons 'rect rect)) (lambda () (Rectangle #:origin (Point #:x 0 #:y 0) #:width 1 #:height 1))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson03-records.tesl" 87 (list (cons 'unit unit) (cons 'rect rect)) (lambda () (area unit)))) 1)
    ))
  )

  (test-case "perimeter"
    (call-with-fresh-memory-db '() (lambda ()
  (define rect (thsl-src! "example/learn/lesson03-records.tesl" 91 (list) (lambda () (Rectangle #:origin (Point #:x 0 #:y 0) #:width 4 #:height 3))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson03-records.tesl" 92 (list (cons 'rect rect)) (lambda () (perimeter rect)))) 14)
    ))
  )

  (test-case "translate"
    (call-with-fresh-memory-db '() (lambda ()
  (define p (thsl-src! "example/learn/lesson03-records.tesl" 96 (list) (lambda () (Point #:x 1 #:y 2))))
  (define moved (thsl-src! "example/learn/lesson03-records.tesl" 97 (list (cons 'p p)) (lambda () (translate p 3 4))))
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 98 (list (cons 'moved moved) (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime moved 'x 'Point)))) 4)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 99 (list (cons 'moved moved) (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime moved 'y 'Point)))) 6)
    ))
  )

  (test-case "scale"
    (call-with-fresh-memory-db '() (lambda ()
  (define rect (thsl-src! "example/learn/lesson03-records.tesl" 103 (list) (lambda () (Rectangle #:origin (Point #:x 0 #:y 0) #:width 3 #:height 2))))
  (define big (thsl-src! "example/learn/lesson03-records.tesl" 104 (list (cons 'rect rect)) (lambda () (scale rect 4))))
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 105 (list (cons 'big big) (cons 'rect rect)) (lambda () (raw-value (tesl-dot/runtime big 'width 'Rectangle)))) 12)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 106 (list (cons 'big big) (cons 'rect rect)) (lambda () (raw-value (tesl-dot/runtime big 'height 'Rectangle)))) 8)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 107 (list (cons 'big big) (cons 'rect rect)) (lambda () (raw-value (tesl-dot/runtime (tesl-dot/runtime big 'origin 'Rectangle) 'x 'Point)))) 0)
    ))
  )

  (test-case "origin returns zero point"
    (call-with-fresh-memory-db '() (lambda ()
  (define o (thsl-src! "example/learn/lesson03-records.tesl" 111 (list) (lambda () (origin))))
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 112 (list (cons 'o o)) (lambda () (raw-value (tesl-dot/runtime o 'x 'Point)))) 0)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 113 (list (cons 'o o)) (lambda () (raw-value (tesl-dot/runtime o 'y 'Point)))) 0)
    ))
  )

  (test-case "setX changes only x"
    (call-with-fresh-memory-db '() (lambda ()
  (define p (thsl-src! "example/learn/lesson03-records.tesl" 119 (list) (lambda () (Point #:x 3 #:y 7))))
  (define p2 (thsl-src! "example/learn/lesson03-records.tesl" 120 (list (cons 'p p)) (lambda () (setX p 99))))
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 121 (list (cons 'p2 p2) (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p2 'x 'Point)))) 99)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 122 (list (cons 'p2 p2) (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p2 'y 'Point)))) 7)
    ))
  )

  (test-case "single field update leaves others intact"
    (call-with-fresh-memory-db '() (lambda ()
  (define p (thsl-src! "example/learn/lesson03-records.tesl" 126 (list) (lambda () (Point #:x 10 #:y 20))))
  (define p2 (thsl-src! "example/learn/lesson03-records.tesl" 127 (list (cons 'p p)) (lambda () (tesl-record-update (raw-value p) (hash 'y (raw-value 50))))))
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 128 (list (cons 'p2 p2) (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p2 'x 'Point)))) 10)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 129 (list (cons 'p2 p2) (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p2 'y 'Point)))) 50)
    ))
  )

  (test-case "update is non-destructive \226\128\148 original unchanged"
    (call-with-fresh-memory-db '() (lambda ()
  (define p (thsl-src! "example/learn/lesson03-records.tesl" 133 (list) (lambda () (Point #:x 1 #:y 2))))
  (define _p2 (thsl-src! "example/learn/lesson03-records.tesl" 134 (list (cons 'p p)) (lambda () (tesl-record-update (raw-value p) (hash 'x (raw-value 99))))))
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 135 (list (cons '_p2 _p2) (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p 'x 'Point)))) 1)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 136 (list (cons '_p2 _p2) (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p 'y 'Point)))) 2)
    ))
  )

  (test-case "multi-field update"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "example/learn/lesson03-records.tesl" 140 (list) (lambda () (Rectangle #:origin (Point #:x 0 #:y 0) #:width 10 #:height 5))))
  (define r2 (thsl-src! "example/learn/lesson03-records.tesl" 141 (list (cons 'r r)) (lambda () (tesl-record-update (raw-value r) (hash 'width (raw-value 20) 'height (raw-value 8))))))
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 142 (list (cons 'r2 r2) (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r2 'width 'Rectangle)))) 20)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 143 (list (cons 'r2 r2) (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r2 'height 'Rectangle)))) 8)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 144 (list (cons 'r2 r2) (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime (tesl-dot/runtime r2 'origin 'Rectangle) 'x 'Point)))) 0)
    ))
  )

  (test-case "chained updates"
    (call-with-fresh-memory-db '() (lambda ()
  (define p (thsl-src! "example/learn/lesson03-records.tesl" 148 (list) (lambda () (Point #:x 0 #:y 0))))
  (define p1 (thsl-src! "example/learn/lesson03-records.tesl" 149 (list (cons 'p p)) (lambda () (tesl-record-update (raw-value p) (hash 'x (raw-value 5))))))
  (define p2 (thsl-src! "example/learn/lesson03-records.tesl" 150 (list (cons 'p1 p1) (cons 'p p)) (lambda () (tesl-record-update (raw-value p1) (hash 'y (raw-value 3))))))
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 151 (list (cons 'p2 p2) (cons 'p1 p1) (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p2 'x 'Point)))) 5)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 152 (list (cons 'p2 p2) (cons 'p1 p1) (cons 'p p)) (lambda () (raw-value (tesl-dot/runtime p2 'y 'Point)))) 3)
    ))
  )

  (test-case "moveOrigin"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "example/learn/lesson03-records.tesl" 156 (list) (lambda () (Rectangle #:origin (Point #:x 2 #:y 3) #:width 10 #:height 5))))
  (define r2 (thsl-src! "example/learn/lesson03-records.tesl" 157 (list (cons 'r r)) (lambda () (moveOrigin r 10 20))))
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 158 (list (cons 'r2 r2) (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime (tesl-dot/runtime r2 'origin 'Rectangle) 'x 'Point)))) 12)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 159 (list (cons 'r2 r2) (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime (tesl-dot/runtime r2 'origin 'Rectangle) 'y 'Point)))) 23)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 160 (list (cons 'r2 r2) (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r2 'width 'Rectangle)))) 10)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 161 (list (cons 'r2 r2) (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r2 'height 'Rectangle)))) 5)
    ))
  )

  (test-case "resetOrigin"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "example/learn/lesson03-records.tesl" 165 (list) (lambda () (Rectangle #:origin (Point #:x 7 #:y 9) #:width 4 #:height 4))))
  (define r2 (thsl-src! "example/learn/lesson03-records.tesl" 166 (list (cons 'r r)) (lambda () (resetOrigin r))))
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 167 (list (cons 'r2 r2) (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime (tesl-dot/runtime r2 'origin 'Rectangle) 'x 'Point)))) 0)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 168 (list (cons 'r2 r2) (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime (tesl-dot/runtime r2 'origin 'Rectangle) 'y 'Point)))) 0)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 169 (list (cons 'r2 r2) (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r2 'width 'Rectangle)))) 4)
    ))
  )

  (test-case "flipDimensions"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "example/learn/lesson03-records.tesl" 173 (list) (lambda () (Rectangle #:origin (Point #:x 0 #:y 0) #:width 16 #:height 9))))
  (define r2 (thsl-src! "example/learn/lesson03-records.tesl" 174 (list (cons 'r r)) (lambda () (flipDimensions r))))
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 175 (list (cons 'r2 r2) (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r2 'width 'Rectangle)))) 9)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 176 (list (cons 'r2 r2) (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r2 'height 'Rectangle)))) 16)
  (define r3 (thsl-src! "example/learn/lesson03-records.tesl" 177 (list (cons 'r2 r2) (cons 'r r)) (lambda () (flipDimensions r2))))
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 178 (list (cons 'r3 r3) (cons 'r2 r2) (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r3 'width 'Rectangle)))) 16)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 179 (list (cons 'r3 r3) (cons 'r2 r2) (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime r3 'height 'Rectangle)))) 9)
    ))
  )

  (test-case "update then access nested field"
    (call-with-fresh-memory-db '() (lambda ()
  (define r (thsl-src! "example/learn/lesson03-records.tesl" 183 (list) (lambda () (Rectangle #:origin (Point #:x 0 #:y 0) #:width 5 #:height 3))))
  (define r2 (thsl-src! "example/learn/lesson03-records.tesl" 184 (list (cons 'r r)) (lambda () (tesl-record-update (raw-value r) (hash 'origin (raw-value (Point #:x 10 #:y 20)))))))
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 185 (list (cons 'r2 r2) (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime (tesl-dot/runtime r2 'origin 'Rectangle) 'x 'Point)))) 10)
  (check-equal? (thsl-src! "example/learn/lesson03-records.tesl" 186 (list (cons 'r2 r2) (cons 'r r)) (lambda () (raw-value (tesl-dot/runtime (tesl-dot/runtime r2 'origin 'Rectangle) 'y 'Point)))) 20)
    ))
  )

)
