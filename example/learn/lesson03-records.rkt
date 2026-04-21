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
  (* (tesl-dot/runtime r 'width) (tesl-dot/runtime r 'height)))

(define/pow
  (perimeter [r : Rectangle])
  #:returns Integer
  (* 2 (+ (tesl-dot/runtime r 'width) (tesl-dot/runtime r 'height))))

(define/pow
  (translate [p : Point] [dx : Integer] [dy : Integer])
  #:returns Point
  (Point #:x (+ (tesl-dot/runtime p 'x) *dx) #:y (+ (tesl-dot/runtime p 'y) *dy)))

(define/pow
  (scale [r : Rectangle] [factor : Integer])
  #:returns Rectangle
  (tesl-record-update *r (hash 'width (raw-value (* (tesl-dot/runtime r 'width) *factor)) 'height (raw-value (* (tesl-dot/runtime r 'height) *factor)))))

(define/pow
  (origin)
  #:returns Point
  (Point #:x 0 #:y 0))

(define/pow
  (setX [p : Point] [newX : Integer])
  #:returns Point
  (tesl-record-update *p (hash 'x *newX)))

(define/pow
  (moveOrigin [r : Rectangle] [dx : Integer] [dy : Integer])
  #:returns Rectangle
  (tesl-record-update *r (hash 'origin (raw-value (translate (tesl-dot/runtime r 'origin) dx dy)))))

(define/pow
  (resetOrigin [r : Rectangle])
  #:returns Rectangle
  (tesl-record-update *r (hash 'origin (raw-value (Point #:x 0 #:y 0)))))

(define/pow
  (flipDimensions [r : Rectangle])
  #:returns Rectangle
  (tesl-record-update *r (hash 'width (tesl-dot/runtime r 'height) 'height (tesl-dot/runtime r 'width))))

(module+ test
  (require rackunit)
  (test-case "area"
  (define rect (Rectangle #:origin (Point #:x 0 #:y 0) #:width 4 #:height 3))
  (check-equal? (raw-value (area rect)) 12)
  (define unit (Rectangle #:origin (Point #:x 0 #:y 0) #:width 1 #:height 1))
  (check-equal? (raw-value (area unit)) 1)
  )

  (test-case "perimeter"
  (define rect (Rectangle #:origin (Point #:x 0 #:y 0) #:width 4 #:height 3))
  (check-equal? (raw-value (perimeter rect)) 14)
  )

  (test-case "translate"
  (define p (Point #:x 1 #:y 2))
  (define moved (translate p 3 4))
  (check-equal? (raw-value (tesl-dot/runtime moved 'x)) 4)
  (check-equal? (raw-value (tesl-dot/runtime moved 'y)) 6)
  )

  (test-case "scale"
  (define rect (Rectangle #:origin (Point #:x 0 #:y 0) #:width 3 #:height 2))
  (define big (scale rect 4))
  (check-equal? (raw-value (tesl-dot/runtime big 'width)) 12)
  (check-equal? (raw-value (tesl-dot/runtime big 'height)) 8)
  (check-equal? (raw-value (tesl-dot/runtime (tesl-dot/runtime big 'origin) 'x)) 0)
  )

  (test-case "origin returns zero point"
  (define o (origin))
  (check-equal? (raw-value (tesl-dot/runtime o 'x)) 0)
  (check-equal? (raw-value (tesl-dot/runtime o 'y)) 0)
  )

  (test-case "setX changes only x"
  (define p (Point #:x 3 #:y 7))
  (define p2 (setX p 99))
  (check-equal? (raw-value (tesl-dot/runtime p2 'x)) 99)
  (check-equal? (raw-value (tesl-dot/runtime p2 'y)) 7)
  )

  (test-case "single field update leaves others intact"
  (define p (Point #:x 10 #:y 20))
  (define p2 (tesl-record-update (raw-value p) (hash 'y (raw-value 50))))
  (check-equal? (raw-value (tesl-dot/runtime p2 'x)) 10)
  (check-equal? (raw-value (tesl-dot/runtime p2 'y)) 50)
  )

  (test-case "update is non-destructive \226\128\148 original unchanged"
  (define p (Point #:x 1 #:y 2))
  (define _p2 (tesl-record-update (raw-value p) (hash 'x (raw-value 99))))
  (check-equal? (raw-value (tesl-dot/runtime p 'x)) 1)
  (check-equal? (raw-value (tesl-dot/runtime p 'y)) 2)
  )

  (test-case "multi-field update"
  (define r (Rectangle #:origin (Point #:x 0 #:y 0) #:width 10 #:height 5))
  (define r2 (tesl-record-update (raw-value r) (hash 'width (raw-value 20) 'height (raw-value 8))))
  (check-equal? (raw-value (tesl-dot/runtime r2 'width)) 20)
  (check-equal? (raw-value (tesl-dot/runtime r2 'height)) 8)
  (check-equal? (raw-value (tesl-dot/runtime (tesl-dot/runtime r2 'origin) 'x)) 0)
  )

  (test-case "chained updates"
  (define p (Point #:x 0 #:y 0))
  (define p1 (tesl-record-update (raw-value p) (hash 'x (raw-value 5))))
  (define p2 (tesl-record-update (raw-value p1) (hash 'y (raw-value 3))))
  (check-equal? (raw-value (tesl-dot/runtime p2 'x)) 5)
  (check-equal? (raw-value (tesl-dot/runtime p2 'y)) 3)
  )

  (test-case "moveOrigin"
  (define r (Rectangle #:origin (Point #:x 2 #:y 3) #:width 10 #:height 5))
  (define r2 (moveOrigin r 10 20))
  (check-equal? (raw-value (tesl-dot/runtime (tesl-dot/runtime r2 'origin) 'x)) 12)
  (check-equal? (raw-value (tesl-dot/runtime (tesl-dot/runtime r2 'origin) 'y)) 23)
  (check-equal? (raw-value (tesl-dot/runtime r2 'width)) 10)
  (check-equal? (raw-value (tesl-dot/runtime r2 'height)) 5)
  )

  (test-case "resetOrigin"
  (define r (Rectangle #:origin (Point #:x 7 #:y 9) #:width 4 #:height 4))
  (define r2 (resetOrigin r))
  (check-equal? (raw-value (tesl-dot/runtime (tesl-dot/runtime r2 'origin) 'x)) 0)
  (check-equal? (raw-value (tesl-dot/runtime (tesl-dot/runtime r2 'origin) 'y)) 0)
  (check-equal? (raw-value (tesl-dot/runtime r2 'width)) 4)
  )

  (test-case "flipDimensions"
  (define r (Rectangle #:origin (Point #:x 0 #:y 0) #:width 16 #:height 9))
  (define r2 (flipDimensions r))
  (check-equal? (raw-value (tesl-dot/runtime r2 'width)) 9)
  (check-equal? (raw-value (tesl-dot/runtime r2 'height)) 16)
  (define r3 (flipDimensions r2))
  (check-equal? (raw-value (tesl-dot/runtime r3 'width)) 16)
  (check-equal? (raw-value (tesl-dot/runtime r3 'height)) 9)
  )

  (test-case "update then access nested field"
  (define r (Rectangle #:origin (Point #:x 0 #:y 0) #:width 5 #:height 3))
  (define r2 (tesl-record-update (raw-value r) (hash 'origin (raw-value (Point #:x 10 #:y 20)))))
  (check-equal? (raw-value (tesl-dot/runtime (tesl-dot/runtime r2 'origin) 'x)) 10)
  (check-equal? (raw-value (tesl-dot/runtime (tesl-dot/runtime r2 'origin) 'y)) 20)
  )

)
