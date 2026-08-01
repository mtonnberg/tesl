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
  (only-in tesl/tesl/prelude Bool String List)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/float Float [Float.abs tesl_import_Float_abs])
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/time [Time.secondsToPosix tesl_import_Time_secondsToPosix] [Time.posixToSeconds tesl_import_Time_posixToSeconds] [Time.add tesl_import_Time_add] [Time.diff tesl_import_Time_diff])
  (only-in tesl/tesl/units [Length.meters tesl_import_Length_meters] [Length.kilometers tesl_import_Length_kilometers] [Length.miles tesl_import_Length_miles] [Length.feet tesl_import_Length_feet] [Length.inMeters tesl_import_Length_inMeters] [Length.inKilometers tesl_import_Length_inKilometers] [Length.inFeet tesl_import_Length_inFeet] [Mass.kilograms tesl_import_Mass_kilograms] [Duration.seconds tesl_import_Duration_seconds] [Duration.minutes tesl_import_Duration_minutes] [Duration.hours tesl_import_Duration_hours] [Duration.inSeconds tesl_import_Duration_inSeconds] [Duration.inMinutes tesl_import_Duration_inMinutes] [Duration.toMillis tesl_import_Duration_toMillis] [Speed.metersPerSecond tesl_import_Speed_metersPerSecond] [Speed.kilometersPerHour tesl_import_Speed_kilometersPerHour] [Speed.inMetersPerSecond tesl_import_Speed_inMetersPerSecond] [Speed.inKilometersPerHour tesl_import_Speed_inKilometersPerHour] [Speed.inMilesPerHour tesl_import_Speed_inMilesPerHour] [Acceleration.metersPerSecondSquared tesl_import_Acceleration_metersPerSecondSquared] [Area.squareMeters tesl_import_Area_squareMeters] [Area.inSquareMeters tesl_import_Area_inSquareMeters] [Energy.inJoules tesl_import_Energy_inJoules] [Temperature.celsius tesl_import_Temperature_celsius] [Temperature.inFahrenheit tesl_import_Temperature_inFahrenheit] [Units.sqrt tesl_import_Units_sqrt] [Units.square tesl_import_Units_square] [Units.sum tesl_import_Units_sum] [Units.max tesl_import_Units_max] [Units.requireNonZero tesl_import_Units_requireNonZero])
)


(provide finalSpeed pace deliveryEta brakingDistance kineticEnergy lengthRatio rectangleArea sideFromArea longestLeg totalDistance approxEqual approxEqual-signature totalDistance-signature longestLeg-signature finalSpeed-signature kineticEnergy-signature rectangleArea-signature pace-signature deliveryEta-signature brakingDistance-signature lengthRatio-signature sideFromArea-signature)

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "example/learn/lesson72-units.tesl" '(366))
(define/pow
  (approxEqual [x : Real] [y : Real])
  #:returns Boolean
  (thsl-src! "example/learn/lesson72-units.tesl" 125 (list (cons 'x *x) (cons 'y *y)) (lambda () (tesl-lt? (raw-value (tesl_import_Float_abs (- *x *y))) 1e-06))))

(define-record Trip
  [distance : Real]
  [duration : Real]
)

(define/pow
  (averageSpeed [t : Trip])
  #:returns Real
  (thsl-src! "example/learn/lesson72-units.tesl" 167 (list (cons 't *t)) (lambda () (let/check ([tesl-checked-0 (tesl_import_Units_requireNonZero (tesl-dot/runtime t 'duration 'Trip))]) (let ([safeDur tesl-checked-0]) (/ (raw-value (tesl-dot/runtime t 'distance 'Trip)) (raw-value safeDur)))))))

(define-adt Segment
  [Drive [dist : Real] [speed : Real]]
  [Rest [pause : Real]]
)

(define/pow
  (segmentTime [s : Segment])
  #:returns Real
  (thsl-src-control! "example/learn/lesson72-units.tesl" 175 (list (cons 's *s)) (lambda () (let ([tesl-case-1 *s]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Drive)) (let ([d (hash-ref (adt-value-fields *tesl-case-1) 'dist)]) (let ([v (hash-ref (adt-value-fields *tesl-case-1) 'speed)]) (thsl-src! "example/learn/lesson72-units.tesl" 177 (list (cons 'd d) (cons 'v v)) (lambda () (let/check ([tesl-checked-2 (tesl_import_Units_requireNonZero *v)]) (let ([safeV tesl-checked-2]) (raw-value (/ *d (raw-value safeV)))))))))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Rest)) (let ([p (hash-ref (adt-value-fields *tesl-case-1) 'pause)]) (thsl-src! "example/learn/lesson72-units.tesl" 179 (list (cons 'p p)) (lambda () *p)))])))))

(define/pow
  (totalDistance [legs : (List Real)])
  #:returns Real
  (thsl-src! "example/learn/lesson72-units.tesl" 219 (list (cons 'legs *legs)) (lambda () (raw-value (tesl_import_Units_sum *legs)))))

(define/pow
  (longestLeg [a : Real] [b : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson72-units.tesl" 222 (list (cons 'a *a) (cons 'b *b)) (lambda () (raw-value (tesl_import_Units_max *a *b)))))

(define/pow
  (finalSpeed [a : Real] [t : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson72-units.tesl" 243 (list (cons 'a *a) (cons 't *t)) (lambda () (* *a *t))))

(define/pow
  (kineticEnergy [m : Real] [v : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson72-units.tesl" 249 (list (cons 'm *m) (cons 'v *v)) (lambda () (* (* (* 0.5 *m) *v) *v))))

(define/pow
  (rectangleArea [w : Real] [h : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson72-units.tesl" 252 (list (cons 'w *w) (cons 'h *h)) (lambda () (* *w *h))))

(define/pow
  (pace [d : Real] [t : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson72-units.tesl" 284 (list (cons 'd *d) (cons 't *t)) (lambda () (let/check ([tesl-checked-3 (tesl_import_Units_requireNonZero t)]) (let ([safe tesl-checked-3]) (/ *d (raw-value safe)))))))

(define/pow
  (deliveryEta [remaining : Real] [avg : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson72-units.tesl" 290 (list (cons 'remaining *remaining) (cons 'avg *avg)) (lambda () (let/check ([tesl-checked-4 (tesl_import_Units_requireNonZero avg)]) (let ([safe tesl-checked-4]) (/ *remaining (raw-value safe)))))))

(define/pow
  (brakingDistance [v : Real] [a : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson72-units.tesl" 297 (list (cons 'v *v) (cons 'a *a)) (lambda () (let ([vSquared (* *v *v)]) (let ([twoA (* 2. *a)]) (let/check ([tesl-checked-5 (tesl_import_Units_requireNonZero twoA)]) (let ([safe tesl-checked-5]) (/ (raw-value vSquared) (raw-value safe)))))))))

(define/pow
  (lengthRatio [a : Real] [b : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson72-units.tesl" 304 (list (cons 'a *a) (cons 'b *b)) (lambda () (let/check ([tesl-checked-6 (tesl_import_Units_requireNonZero b)]) (let ([safe tesl-checked-6]) (/ *a (raw-value safe)))))))

(define/pow
  (sideFromArea [a : Real])
  #:returns Real
  (thsl-src! "example/learn/lesson72-units.tesl" 338 (list (cons 'a *a)) (lambda () (raw-value (tesl_import_Units_sqrt *a)))))

(define-entity Vehicle
  #:source (make-hash)
  #:table vehicles
  #:primary-key id
  [Id id : String]
  [TopSpeed topSpeed : Real]
)

(define-database Fleet
  #:backend memory
  #:entities Vehicle)

(module+ test
  (require rackunit)
  (test-case "one kilometer, three doors in, any door out"
    (call-with-fresh-memory-db (list Fleet) (lambda ()
  (define a (thsl-src! "example/learn/lesson72-units.tesl" 142 (list) (lambda () (raw-value (tesl_import_Length_kilometers 1.)))))
  (define b (thsl-src! "example/learn/lesson72-units.tesl" 143 (list (cons 'a a)) (lambda () (raw-value (tesl_import_Length_meters 1000.)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 144 (list (cons 'b b) (cons 'a a)) (lambda () (tesl-equal? (raw-value a) (raw-value b))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 145 (list (cons 'b b) (cons 'a a)) (lambda () (raw-value (tesl_import_Length_inMeters (raw-value a)))))) 1000.)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 146 (list (cons 'b b) (cons 'a a)) (lambda () (raw-value (tesl_import_Length_inKilometers (raw-value (tesl_import_Length_meters 2500.))))))) 2.5)
  (check-true (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 147 (list (cons 'b b) (cons 'a a)) (lambda () (approxEqual (raw-value (tesl_import_Length_inFeet (raw-value a))) 3280.839895)))))
  (check-true (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 148 (list (cons 'b b) (cons 'a a)) (lambda () (approxEqual (raw-value (tesl_import_Length_inMeters (raw-value (tesl_import_Length_miles 1.)))) 1609.344)))))
    ))
  )

  (test-case "a let annotation pins or verifies the dimension"
    (call-with-fresh-memory-db (list Fleet) (lambda ()
  (define top (thsl-src! "example/learn/lesson72-units.tesl" 182 (list) (lambda () (raw-value (tesl_import_Speed_kilometersPerHour 110.)))))
  (check-true (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 183 (list (cons 'top top)) (lambda () (approxEqual (raw-value (tesl_import_Speed_inKilometersPerHour (raw-value top))) 110.)))))
  (define w (thsl-src! "example/learn/lesson72-units.tesl" 184 (list (cons 'top top)) (lambda () (raw-value (tesl_import_Length_meters 12.)))))
  (define h (thsl-src! "example/learn/lesson72-units.tesl" 185 (list (cons 'w w) (cons 'top top)) (lambda () (raw-value (tesl_import_Length_meters 4.)))))
  (define a (thsl-src! "example/learn/lesson72-units.tesl" 186 (list (cons 'h h) (cons 'w w) (cons 'top top)) (lambda () (* (raw-value w) (raw-value h)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 187 (list (cons 'a a) (cons 'h h) (cons 'w w) (cons 'top top)) (lambda () (raw-value (tesl_import_Area_inSquareMeters (raw-value a)))))) 48.)
    ))
  )

  (test-case "records carry quantities; fields compute like any value"
    (call-with-fresh-memory-db (list Fleet) (lambda ()
  (define trip (thsl-src! "example/learn/lesson72-units.tesl" 191 (list) (lambda () (Trip #:distance (raw-value (tesl_import_Length_kilometers 30.)) #:duration (raw-value (tesl_import_Duration_hours 0.5))))))
  (check-true (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 192 (list (cons 'trip trip)) (lambda () (approxEqual (raw-value (tesl_import_Speed_inKilometersPerHour (raw-value (averageSpeed trip)))) 60.)))))
    ))
  )

  (test-case "ADT variants carry quantities through pattern matching"
    (call-with-fresh-memory-db (list Fleet) (lambda ()
  (define leg (thsl-src! "example/learn/lesson72-units.tesl" 196 (list) (lambda () (raw-value (Drive (raw-value (tesl_import_Length_meters 100.)) (raw-value (tesl_import_Speed_metersPerSecond 20.)))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 197 (list (cons 'leg leg)) (lambda () (raw-value (tesl_import_Duration_inSeconds (raw-value (segmentTime leg))))))) 5.)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 198 (list (cons 'leg leg)) (lambda () (raw-value (tesl_import_Duration_inSeconds (raw-value (segmentTime (Rest (raw-value (tesl_import_Duration_minutes 2.)))))))))) 120.)
    ))
  )

  (test-case "quantities as container type arguments"
    (call-with-fresh-memory-db (list Fleet) (lambda ()
  (define legs (thsl-src! "example/learn/lesson72-units.tesl" 202 (list) (lambda () (list (raw-value (tesl_import_Length_meters 400.)) (raw-value (tesl_import_Length_kilometers 0.6))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 203 (list (cons 'legs legs)) (lambda () (raw-value (tesl_import_Length_inMeters (raw-value (tesl_import_Units_sum (raw-value legs)))))))) 1000.)
  (define maybeTop (thsl-src! "example/learn/lesson72-units.tesl" 204 (list (cons 'legs legs)) (lambda () (raw-value (Something (raw-value (tesl_import_Speed_metersPerSecond 3.)))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 205 (list (cons 'maybeTop maybeTop) (cons 'legs legs)) (lambda () (let ([*tesl-case-7 (raw-value maybeTop)]) (cond [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Something)) (let ([v (hash-ref (adt-value-fields *tesl-case-7) 'value)]) (thsl-src! "example/learn/lesson72-units.tesl" 206 (list (cons 'v v)) (lambda () (tesl-equal? (raw-value (tesl_import_Speed_inMetersPerSecond (raw-value v))) 3.))))] [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Nothing)) (thsl-src! "example/learn/lesson72-units.tesl" 207 (list) (lambda () #f))]))))) #t)
    ))
  )

  (test-case "meters and feet add directly \226\128\148 both are canonical meters inside"
    (call-with-fresh-memory-db (list Fleet) (lambda ()
  (define mixed (thsl-src! "example/learn/lesson72-units.tesl" 225 (list) (lambda () (+ (raw-value (tesl_import_Length_meters 1.)) (raw-value (tesl_import_Length_feet 1.))))))
  (check-true (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 226 (list (cons 'mixed mixed)) (lambda () (approxEqual (raw-value (tesl_import_Length_inMeters (raw-value mixed))) 1.3048)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 227 (list (cons 'mixed mixed)) (lambda () (tesl-gt? (raw-value (tesl_import_Length_kilometers 1.)) (raw-value (tesl_import_Length_feet 3000.)))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 228 (list (cons 'mixed mixed)) (lambda () (raw-value (tesl_import_Length_inMeters (raw-value (totalDistance (list (raw-value (tesl_import_Length_meters 400.)) (raw-value (tesl_import_Length_kilometers 0.6)))))))))) 1000.)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 230 (list (cons 'mixed mixed)) (lambda () (raw-value (tesl_import_Length_inMeters (raw-value (longestLeg (raw-value (tesl_import_Length_meters 30.)) (raw-value (tesl_import_Length_feet 100.))))))))) 30.48)
    ))
  )

  (test-case "the algebra derives Speed, Energy, and Area"
    (call-with-fresh-memory-db (list Fleet) (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 255 (list) (lambda () (raw-value (tesl_import_Speed_inMetersPerSecond (raw-value (finalSpeed (raw-value (tesl_import_Acceleration_metersPerSecondSquared 2.5)) (raw-value (tesl_import_Duration_seconds 4.))))))))) 10.)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 258 (list) (lambda () (raw-value (tesl_import_Energy_inJoules (raw-value (kineticEnergy (raw-value (tesl_import_Mass_kilograms 1500.)) (raw-value (tesl_import_Speed_metersPerSecond 20.))))))))) 300000.)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 260 (list) (lambda () (raw-value (tesl_import_Area_inSquareMeters (raw-value (rectangleArea (raw-value (tesl_import_Length_meters 12.)) (raw-value (tesl_import_Length_meters 4.))))))))) 48.)
    ))
  )

  (test-case "division derives Speed and collapses ratios"
    (call-with-fresh-memory-db (list Fleet) (lambda ()
  (define sprint (thsl-src! "example/learn/lesson72-units.tesl" 308 (list) (lambda () (pace (raw-value (tesl_import_Length_meters 100.)) (raw-value (tesl_import_Duration_seconds 8.))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 309 (list (cons 'sprint sprint)) (lambda () (raw-value (tesl_import_Speed_inMetersPerSecond (raw-value sprint)))))) 12.5)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 310 (list (cons 'sprint sprint)) (lambda () (raw-value (tesl_import_Speed_inKilometersPerHour (raw-value sprint)))))) 45.)
  (check-true (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 311 (list (cons 'sprint sprint)) (lambda () (approxEqual (raw-value (tesl_import_Speed_inMilesPerHour (raw-value sprint))) 27.961704)))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 312 (list (cons 'sprint sprint)) (lambda () (lengthRatio (raw-value (tesl_import_Length_meters 6.)) (raw-value (tesl_import_Length_meters 3.)))))) 2.)
    ))
  )

  (test-case "delivery ETA: 30 km left at 60 km/h is 30 minutes"
    (call-with-fresh-memory-db (list Fleet) (lambda ()
  (define eta (thsl-src! "example/learn/lesson72-units.tesl" 317 (list) (lambda () (deliveryEta (raw-value (tesl_import_Length_kilometers 30.)) (raw-value (tesl_import_Speed_kilometersPerHour 60.))))))
  (check-true (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 318 (list (cons 'eta eta)) (lambda () (approxEqual (raw-value (tesl_import_Duration_inMinutes (raw-value eta))) 30.)))))
    ))
  )

  (test-case "braking distance: 30 m/s at 5 m/s\194\178 needs 90 m"
    (call-with-fresh-memory-db (list Fleet) (lambda ()
  (define d (thsl-src! "example/learn/lesson72-units.tesl" 322 (list) (lambda () (brakingDistance (raw-value (tesl_import_Speed_metersPerSecond 30.)) (raw-value (tesl_import_Acceleration_metersPerSecondSquared 5.))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 323 (list (cons 'd d)) (lambda () (raw-value (tesl_import_Length_inMeters (raw-value d)))))) 90.)
  (define dHighway (thsl-src! "example/learn/lesson72-units.tesl" 325 (list (cons 'd d)) (lambda () (brakingDistance (raw-value (tesl_import_Speed_kilometersPerHour 110.)) (raw-value (tesl_import_Acceleration_metersPerSecondSquared 5.))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 326 (list (cons 'dHighway dHighway) (cons 'd d)) (lambda () (tesl-lt? (raw-value dHighway) (raw-value (tesl_import_Length_meters 100.)))))) #t)
    ))
  )

  (test-case "sqrt of an area is a side length"
    (call-with-fresh-memory-db (list Fleet) (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 341 (list) (lambda () (raw-value (tesl_import_Length_inMeters (raw-value (sideFromArea (raw-value (tesl_import_Area_squareMeters 49.))))))))) 7.)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 342 (list) (lambda () (raw-value (tesl_import_Area_inSquareMeters (raw-value (tesl_import_Units_square (raw-value (tesl_import_Length_meters 9.))))))))) 81.)
    ))
  )

  (test-case "a Speed column stores canonical m/s and reads back typed"
    (call-with-fresh-memory-db (list Fleet) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-8 (thsl-src! "example/learn/lesson72-units.tesl" 365 (list) (lambda () (insert-one! Vehicle (tesl-hash 'id "v1" 'topSpeed (raw-value (tesl_import_Speed_kilometersPerHour 110.)))))))
    (define found (thsl-src! "example/learn/lesson72-units.tesl" 366 (list) (lambda () (let ([tesl_match (select-one (from Vehicle) (where (==. (entity-field-ref Vehicle 'id) "v1")))]) (if tesl_match (Something tesl_match) Nothing)))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 367 (list (cons 'found found)) (lambda () (let ([*tesl-case-9 (raw-value found)]) (cond [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Something)) (let ([v2 (hash-ref (adt-value-fields *tesl-case-9) 'value)]) (thsl-src! "example/learn/lesson72-units.tesl" 368 (list (cons 'v2 v2)) (lambda () (approxEqual (raw-value (tesl_import_Speed_inKilometersPerHour (raw-value (tesl-dot/runtime v2 'topSpeed 'Vehicle)))) 110.))))] [(and (adt-value? *tesl-case-9) (eq? (adt-value-variant *tesl-case-9) 'Nothing)) (thsl-src! "example/learn/lesson72-units.tesl" 369 (list) (lambda () #f))]))))) #t)
    )
    ))
  )

  (test-case "temperature is stored as kelvin; 100 \194\176C reads back as 212 \194\176F"
    (call-with-fresh-memory-db (list Fleet) (lambda ()
  (check-true (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 381 (list) (lambda () (approxEqual (raw-value (tesl_import_Temperature_inFahrenheit (raw-value (tesl_import_Temperature_celsius 100.)))) 212.)))))
    ))
  )

  (test-case "Time.add speaks Duration; Time.diff returns one"
    (call-with-fresh-memory-db (list Fleet) (lambda ()
  (define start (thsl-src! "example/learn/lesson72-units.tesl" 394 (list) (lambda () (raw-value (tesl_import_Time_secondsToPosix 1000)))))
  (define deadline (thsl-src! "example/learn/lesson72-units.tesl" 395 (list (cons 'start start)) (lambda () (raw-value (tesl_import_Time_add (raw-value start) (raw-value (tesl_import_Duration_hours 2.)))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 396 (list (cons 'deadline deadline) (cons 'start start)) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value deadline)))))) 8200)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 397 (list (cons 'deadline deadline) (cons 'start start)) (lambda () (raw-value (tesl_import_Duration_inSeconds (raw-value (tesl_import_Time_diff (raw-value start) (raw-value deadline)))))))) 7200.)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 398 (list (cons 'deadline deadline) (cons 'start start)) (lambda () (raw-value (tesl_import_Duration_inMinutes (raw-value (tesl_import_Time_diff (raw-value start) (raw-value deadline)))))))) 120.)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson72-units.tesl" 399 (list (cons 'deadline deadline) (cons 'start start)) (lambda () (raw-value (tesl_import_Duration_toMillis (raw-value (tesl_import_Duration_hours 2.))))))) 7200000)
    ))
  )

)
