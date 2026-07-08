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
  (only-in tesl/tesl/float Float [Float.abs tesl_import_Float_abs])
  (only-in tesl/tesl/units [Length.meters tesl_import_Length_meters] [Length.kilometers tesl_import_Length_kilometers] [Length.feet tesl_import_Length_feet] [Length.inMeters tesl_import_Length_inMeters] [Length.inFeet tesl_import_Length_inFeet] [Duration.seconds tesl_import_Duration_seconds] [Duration.hours tesl_import_Duration_hours] [Duration.inMinutes tesl_import_Duration_inMinutes] [Speed.inMetersPerSecond tesl_import_Speed_inMetersPerSecond] [Speed.inKilometersPerHour tesl_import_Speed_inKilometersPerHour] [Acceleration.metersPerSecondSquared tesl_import_Acceleration_metersPerSecondSquared] [Area.squareMeters tesl_import_Area_squareMeters] [Area.inSquareMeters tesl_import_Area_inSquareMeters] [Temperature.celsius tesl_import_Temperature_celsius] [Temperature.inFahrenheit tesl_import_Temperature_inFahrenheit] [Units.sqrt tesl_import_Units_sqrt] [Units.requireNonZero tesl_import_Units_requireNonZero])
)


(provide finalSpeed pace lengthRatio rectangleArea sideFromArea approxEqual approxEqual-signature finalSpeed-signature pace-signature lengthRatio-signature rectangleArea-signature sideFromArea-signature)

(define/pow
  (approxEqual [x : Real] [y : Real])
  #:returns Boolean
  (thsl-src! "example/learn/lesson72-units.tesl" 69 (list (cons 'x *x) (cons 'y *y)) (lambda () (< (raw-value (tesl_import_Float_abs (- *x *y))) 1e-06))))

(define/pow
  (finalSpeed [a : Real] [t : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson72-units.tesl" 76 (list (cons 'a *a) (cons 't *t)) (lambda () (* *a *t))))

(define/pow
  (pace [d : Real] [t : Real])
  #:returns Real
  (let ([safe (thsl-src! "example/learn/lesson72-units.tesl" 84 (list (cons 'd *d) (cons 't *t)) (lambda () (raw-value (tesl_import_Units_requireNonZero *t))))]) (thsl-src! "example/learn/lesson72-units.tesl" 85 (list (cons 'safe *safe) (cons 'd *d) (cons 't *t)) (lambda () (/ *d (raw-value safe))))))

(define/pow
  (lengthRatio [a : Real] [b : Real])
  #:returns Real
  (let ([safe (thsl-src! "example/learn/lesson72-units.tesl" 91 (list (cons 'a *a) (cons 'b *b)) (lambda () (raw-value (tesl_import_Units_requireNonZero *b))))]) (thsl-src! "example/learn/lesson72-units.tesl" 92 (list (cons 'safe *safe) (cons 'a *a) (cons 'b *b)) (lambda () (/ *a (raw-value safe))))))

(define/pow
  (rectangleArea [w : Real] [h : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson72-units.tesl" 96 (list (cons 'w *w) (cons 'h *h)) (lambda () (* *w *h))))

(define/pow
  (sideFromArea [a : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson72-units.tesl" 102 (list (cons 'a *a)) (lambda () (raw-value (tesl_import_Units_sqrt *a)))))

(module+ test
  (require rackunit)
  (test-case "m/s\194\178 times s is m/s"
    (call-with-fresh-memory-db '() (lambda ()
  (define accel (thsl-src! "example/learn/lesson72-units.tesl" 120 (list) (lambda () (raw-value (tesl_import_Acceleration_metersPerSecondSquared 2.5)))))
  (define dt (thsl-src! "example/learn/lesson72-units.tesl" 121 (list (cons 'accel accel)) (lambda () (raw-value (tesl_import_Duration_seconds 4.)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 122 (list (cons 'dt dt) (cons 'accel accel)) (lambda () (raw-value (tesl_import_Speed_inMetersPerSecond (raw-value (finalSpeed accel dt))))))) 10.)
  (check-true (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 123 (list (cons 'dt dt) (cons 'accel accel)) (lambda () (approxEqual (raw-value (tesl_import_Speed_inKilometersPerHour (raw-value (finalSpeed accel dt)))) 36.)))))
    ))
  )

  (test-case "pace is distance over time, division proof-gated"
    (call-with-fresh-memory-db '() (lambda ()
  (define sprint (thsl-src! "example/learn/lesson72-units.tesl" 127 (list) (lambda () (pace (raw-value (tesl_import_Length_meters 100.)) (raw-value (tesl_import_Duration_seconds 8.))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 128 (list (cons 'sprint sprint)) (lambda () (raw-value (tesl_import_Speed_inMetersPerSecond (raw-value sprint)))))) 12.5)
    ))
  )

  (test-case "constructors convert into SI canonical, accessors convert out"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 132 (list) (lambda () (raw-value (tesl_import_Length_inMeters (raw-value (tesl_import_Length_kilometers 5.))))))) 5000.)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 133 (list) (lambda () (raw-value (tesl_import_Duration_inMinutes (raw-value (tesl_import_Duration_hours 2.))))))) 120.)
  (check-true (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 134 (list) (lambda () (approxEqual (raw-value (tesl_import_Length_inFeet (raw-value (tesl_import_Length_feet 100.)))) 100.)))))
    ))
  )

  (test-case "multiplying lengths gives an area, sqrt takes it back"
    (call-with-fresh-memory-db '() (lambda ()
  (define floor (thsl-src! "example/learn/lesson72-units.tesl" 138 (list) (lambda () (rectangleArea (raw-value (tesl_import_Length_meters 12.)) (raw-value (tesl_import_Length_meters 4.))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 139 (list (cons 'floor floor)) (lambda () (raw-value (tesl_import_Area_inSquareMeters (raw-value floor)))))) 48.)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 140 (list (cons 'floor floor)) (lambda () (raw-value (tesl_import_Length_inMeters (raw-value (sideFromArea (raw-value (tesl_import_Area_squareMeters 49.))))))))) 7.)
    ))
  )

  (test-case "scalars scale, same-dimension ratios collapse to Float"
    (call-with-fresh-memory-db '() (lambda ()
  (define doubled (thsl-src! "example/learn/lesson72-units.tesl" 144 (list) (lambda () (* 2. (raw-value (tesl_import_Length_meters 21.))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 145 (list (cons 'doubled doubled)) (lambda () (raw-value (tesl_import_Length_inMeters (raw-value doubled)))))) 42.)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 146 (list (cons 'doubled doubled)) (lambda () (lengthRatio (raw-value (tesl_import_Length_meters 6.)) (raw-value (tesl_import_Length_meters 3.)))))) 2.)
    ))
  )

  (test-case "temperature constructors are affine (offset), stored as kelvin"
    (call-with-fresh-memory-db '() (lambda ()
  (check-true (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 153 (list) (lambda () (approxEqual (raw-value (tesl_import_Temperature_inFahrenheit (raw-value (tesl_import_Temperature_celsius 100.)))) 212.)))))
    ))
  )

)
