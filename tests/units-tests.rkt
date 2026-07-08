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
  (only-in tesl/tesl/prelude Bool List)
  (only-in tesl/tesl/float Float)
  (only-in tesl/tesl/units [Length.meters tesl_import_Length_meters] [Length.kilometers tesl_import_Length_kilometers] [Length.feet tesl_import_Length_feet] [Length.inMeters tesl_import_Length_inMeters] [Length.inKilometers tesl_import_Length_inKilometers] [Length.inFeet tesl_import_Length_inFeet] [Duration.seconds tesl_import_Duration_seconds] [Duration.minutes tesl_import_Duration_minutes] [Duration.inSeconds tesl_import_Duration_inSeconds] [Speed.metersPerSecond tesl_import_Speed_metersPerSecond] [Speed.kilometersPerHour tesl_import_Speed_kilometersPerHour] [Speed.inMetersPerSecond tesl_import_Speed_inMetersPerSecond] [Speed.inKilometersPerHour tesl_import_Speed_inKilometersPerHour] [Acceleration.metersPerSecondSquared tesl_import_Acceleration_metersPerSecondSquared] [Area.squareMeters tesl_import_Area_squareMeters] [Area.inSquareMeters tesl_import_Area_inSquareMeters] [Volume.liters tesl_import_Volume_liters] [Volume.inCubicMeters tesl_import_Volume_inCubicMeters] [Volume.inLiters tesl_import_Volume_inLiters] [Temperature.celsius tesl_import_Temperature_celsius] [Temperature.kelvin tesl_import_Temperature_kelvin] [Temperature.inKelvin tesl_import_Temperature_inKelvin] [Temperature.inFahrenheit tesl_import_Temperature_inFahrenheit] [Frequency.inHertz tesl_import_Frequency_inHertz] [Units.mul tesl_import_Units_mul] [Units.div tesl_import_Units_div] [Units.square tesl_import_Units_square] [Units.sqrt tesl_import_Units_sqrt] [Units.abs tesl_import_Units_abs] [Units.negate tesl_import_Units_negate] [Units.min tesl_import_Units_min] [Units.max tesl_import_Units_max] [Units.sum tesl_import_Units_sum] [Units.requireNonZero tesl_import_Units_requireNonZero])
)


(provide )

(define/pow
  (launchSpeed)
  #:returns Real
  (thsl-src! "tests/units-tests.tesl" 66 (list) (lambda () (* (raw-value (tesl_import_Acceleration_metersPerSecondSquared 2.5)) (raw-value (tesl_import_Duration_seconds 4.))))))

(define/pow
  (pace [d : Real] [t : Real])
  #:returns Real
  (let ([tc (thsl-src! "tests/units-tests.tesl" 71 (list (cons 'd *d) (cons 't *t)) (lambda () (raw-value (tesl_import_Units_requireNonZero *t))))]) (thsl-src! "tests/units-tests.tesl" 72 (list (cons 'tc *tc) (cons 'd *d) (cons 't *t)) (lambda () (/ *d (raw-value tc))))))

(define/pow
  (lengthRatio [a : Real] [b : Real])
  #:returns Real
  (let ([bc (thsl-src! "tests/units-tests.tesl" 76 (list (cons 'a *a) (cons 'b *b)) (lambda () (raw-value (tesl_import_Units_requireNonZero *b))))]) (thsl-src! "tests/units-tests.tesl" 77 (list (cons 'bc *bc) (cons 'a *a) (cons 'b *b)) (lambda () (/ *a (raw-value bc))))))

(define/pow
  (frequencyOf [period : Real])
  #:returns Real
  (let ([pc (thsl-src! "tests/units-tests.tesl" 81 (list (cons 'period *period)) (lambda () (raw-value (tesl_import_Units_requireNonZero *period))))]) (thsl-src! "tests/units-tests.tesl" 82 (list (cons 'pc *pc) (cons 'period *period)) (lambda () (/ 1. (raw-value pc))))))

(define/pow
  (rectangleArea [w : Real] [h : Real])
  #:returns Real
  (thsl-src! "tests/units-tests.tesl" 85 (list (cons 'w *w) (cons 'h *h)) (lambda () (* *w *h))))

(define/pow
  (boxVolume [base : Real] [h : Real])
  #:returns Real
  (thsl-src! "tests/units-tests.tesl" 88 (list (cons 'base *base) (cons 'h *h)) (lambda () (* *base *h))))

(module+ test
  (require rackunit)
  (test-case "length constructors and accessors round-trip"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 93 (list) (lambda () (raw-value (tesl_import_Length_inFeet (raw-value (tesl_import_Length_feet 10.))))))) 10.)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 94 (list) (lambda () (raw-value (tesl_import_Length_inMeters (raw-value (tesl_import_Length_meters 42.))))))) 42.)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 95 (list) (lambda () (raw-value (tesl_import_Length_inMeters (raw-value (tesl_import_Length_kilometers 2.))))))) 2000.)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 96 (list) (lambda () (raw-value (tesl_import_Length_inKilometers (raw-value (tesl_import_Length_meters 500.))))))) 0.5)
    ))
  )

  (test-case "speed constructors and accessors round-trip (km/h)"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 100 (list) (lambda () (raw-value (tesl_import_Speed_inKilometersPerHour (raw-value (tesl_import_Speed_kilometersPerHour 90.))))))) 90.)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 101 (list) (lambda () (raw-value (tesl_import_Speed_inMetersPerSecond (raw-value (tesl_import_Speed_kilometersPerHour 90.))))))) 25.)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 102 (list) (lambda () (raw-value (tesl_import_Speed_inMetersPerSecond (raw-value (tesl_import_Speed_metersPerSecond 3.))))))) 3.)
    ))
  )

  (test-case "duration constructors convert to canonical seconds"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 106 (list) (lambda () (raw-value (tesl_import_Duration_inSeconds (raw-value (tesl_import_Duration_minutes 2.))))))) 120.)
    ))
  )

  (test-case "volume constructors convert to canonical cubic meters"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 110 (list) (lambda () (raw-value (tesl_import_Volume_inCubicMeters (raw-value (tesl_import_Volume_liters 1000.))))))) 1.)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 111 (list) (lambda () (raw-value (tesl_import_Volume_inLiters (raw-value (tesl_import_Volume_liters 1.5))))))) 1.5)
    ))
  )

  (test-case "acceleration times duration is a speed: 2.5 m/s^2 for 4 s is 10 m/s"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 117 (list) (lambda () (raw-value (tesl_import_Speed_inMetersPerSecond (raw-value (launchSpeed))))))) 10.)
    ))
  )

  (test-case "length times length is an area"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 121 (list) (lambda () (raw-value (tesl_import_Area_inSquareMeters (raw-value (rectangleArea (raw-value (tesl_import_Length_meters 3.)) (raw-value (tesl_import_Length_meters 4.))))))))) 12.)
    ))
  )

  (test-case "area times length is a volume"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 125 (list) (lambda () (raw-value (tesl_import_Volume_inCubicMeters (raw-value (boxVolume (raw-value (tesl_import_Area_squareMeters 6.)) (raw-value (tesl_import_Length_meters 2.))))))))) 12.)
    ))
  )

  (test-case "same-dimension addition and float scaling"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 129 (list) (lambda () (raw-value (tesl_import_Length_inMeters (+ (raw-value (tesl_import_Length_meters 1.5)) (raw-value (tesl_import_Length_meters 2.5)))))))) 4.)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 130 (list) (lambda () (raw-value (tesl_import_Length_inMeters (- (raw-value (tesl_import_Length_meters 5.)) (raw-value (tesl_import_Length_meters 1.5)))))))) 3.5)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 131 (list) (lambda () (raw-value (tesl_import_Length_inMeters (* 2. (raw-value (tesl_import_Length_meters 3.)))))))) 6.)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 132 (list) (lambda () (raw-value (tesl_import_Length_inMeters (/ (raw-value (tesl_import_Length_meters 6.)) 2.)))))) 3.)
    ))
  )

  (test-case "same-dimension comparison is numeric"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 136 (list) (lambda () (> (raw-value (tesl_import_Length_meters 2.)) (raw-value (tesl_import_Length_meters 1.)))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 137 (list) (lambda () (tesl-equal? (raw-value (tesl_import_Length_meters 1.)) (raw-value (tesl_import_Length_kilometers 0.001)))))) #t)
    ))
  )

  (test-case "division with Units.requireNonZero: 100 m over 20 s is 5 m/s"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 143 (list) (lambda () (raw-value (tesl_import_Speed_inMetersPerSecond (raw-value (pace (raw-value (tesl_import_Length_meters 100.)) (raw-value (tesl_import_Duration_seconds 20.))))))))) 5.)
    ))
  )

  (test-case "same-dimension division collapses to a plain Float ratio"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 147 (list) (lambda () (lengthRatio (raw-value (tesl_import_Length_meters 6.)) (raw-value (tesl_import_Length_meters 2.)))))) 3.)
    ))
  )

  (test-case "scalar over duration inverts the dimension into a frequency"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 151 (list) (lambda () (raw-value (tesl_import_Frequency_inHertz (raw-value (frequencyOf (raw-value (tesl_import_Duration_seconds 0.5))))))))) 2.)
    ))
  )

  (test-case "Units.mul and Units.div mirror the operators"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 157 (list) (lambda () (raw-value (tesl_import_Area_inSquareMeters (raw-value (tesl_import_Units_mul (raw-value (tesl_import_Length_meters 3.)) (raw-value (tesl_import_Length_meters 4.))))))))) 12.)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 158 (list) (lambda () (raw-value (tesl_import_Speed_inMetersPerSecond (raw-value (tesl_import_Units_div (raw-value (tesl_import_Length_meters 100.)) (raw-value (tesl_import_Duration_seconds 20.))))))))) 5.)
    ))
  )

  (test-case "Units.square of a length is an area; Units.sqrt of an area is a length"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 162 (list) (lambda () (raw-value (tesl_import_Area_inSquareMeters (raw-value (tesl_import_Units_square (raw-value (tesl_import_Length_meters 3.))))))))) 9.)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 163 (list) (lambda () (raw-value (tesl_import_Length_inMeters (raw-value (tesl_import_Units_sqrt (raw-value (tesl_import_Area_squareMeters 16.))))))))) 4.)
    ))
  )

  (test-case "Units.sum totals a list of same-dimension quantities"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 167 (list) (lambda () (raw-value (tesl_import_Length_inMeters (raw-value (tesl_import_Units_sum (list (raw-value (tesl_import_Length_meters 1.)) (raw-value (tesl_import_Length_meters 2.)) (raw-value (tesl_import_Length_meters 3.5)))))))))) 6.5)
    ))
  )

  (test-case "Units.abs, Units.negate, Units.min, Units.max"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 171 (list) (lambda () (raw-value (tesl_import_Length_inMeters (raw-value (tesl_import_Units_abs (raw-value (tesl_import_Units_negate (raw-value (tesl_import_Length_meters 5.))))))))))) 5.)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 172 (list) (lambda () (+ (raw-value (tesl_import_Length_inMeters (raw-value (tesl_import_Units_negate (raw-value (tesl_import_Length_meters 5.)))))) 5.)))) 0.)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 173 (list) (lambda () (raw-value (tesl_import_Length_inMeters (raw-value (tesl_import_Units_min (raw-value (tesl_import_Length_meters 1.)) (raw-value (tesl_import_Length_meters 2.))))))))) 1.)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 174 (list) (lambda () (raw-value (tesl_import_Length_inMeters (raw-value (tesl_import_Units_max (raw-value (tesl_import_Length_meters 1.)) (raw-value (tesl_import_Length_meters 2.))))))))) 2.)
    ))
  )

  (test-case "unary minus preserves the quantity's magnitude sign"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 178 (list) (lambda () (+ (raw-value (tesl_import_Speed_inMetersPerSecond (- (raw-value (tesl_import_Speed_metersPerSecond 3.))))) 3.)))) 0.)
    ))
  )

  (test-case "celsius is affine: 100 C is 373.15 K and 212 F"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 184 (list) (lambda () (raw-value (tesl_import_Temperature_inKelvin (raw-value (tesl_import_Temperature_celsius 100.))))))) 373.15)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 185 (list) (lambda () (raw-value (tesl_import_Temperature_inFahrenheit (raw-value (tesl_import_Temperature_celsius 100.))))))) 212.)
  (check-equal? (raw-value (thsl-src! "tests/units-tests.tesl" 186 (list) (lambda () (raw-value (tesl_import_Temperature_inKelvin (raw-value (tesl_import_Temperature_kelvin 0.))))))) 0.)
    ))
  )

)
