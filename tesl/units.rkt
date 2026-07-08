#lang racket

;;; Tesl.Units — dimensioned-quantity runtime (First-Class Units, phase 2/3).
;;;
;;; Quantities ERASE to plain Floats at runtime: the dimension lives only in
;;; the compiler's type layer (units_catalog.ml), so every function here is
;;; ordinary Float arithmetic.  Unit CONSTRUCTORS convert a value in the named
;;; unit to the SI-canonical magnitude (meters, kilograms, seconds, ...);
;;; ACCESSORS (`Length.inFeet`) convert back.  Conversion factors live ONLY in
;;; this file — the compiler types are factor-independent, and the stdlib
;;; binding-existence seam test pins every catalog name to a real provide here.
;;;
;;; The polymorphic dimension operations (Units.mul/div/square/sqrt/...) are
;;; dimension-checked at each application site by the checker; at runtime they
;;; are the obvious Float functions.
;;;
;;; Usage:
;;;   import Tesl.Units exposing [Length, Duration, Speed,
;;;                               Length.meters, Duration.seconds, Speed.inKilometersPerHour]
;;;   fn pace(d: Length, t: Duration) -> Speed = d / t

;; same require shape as tesl/float.rkt (whose FloatNonZero mint this clones)
(require "../dsl/types.rkt"
         "../dsl/check.rkt"
         (only-in "../dsl/private/evidence.rkt" detached-proof check-ok check-fail)
         (only-in "../dsl/private/check-runtime.rkt" attach))

;; unit constructor: value-in-unit -> SI-canonical Float
(define-syntax-rule (defunit name factor)
  (begin
    (define (name v) (* (exact->inexact (raw-value v)) factor))
    (provide name)))

;; unit accessor: SI-canonical quantity -> Float in the named unit
(define-syntax-rule (defaccessor name factor)
  (begin
    (define (name q) (/ (exact->inexact (raw-value q)) factor))
    (provide name)))

;; ── Length (canonical: meters) ──────────────────────────────────────────────
(defunit |Length.meters| 1.0)
(defunit |Length.kilometers| 1000.0)
(defunit |Length.centimeters| 0.01)
(defunit |Length.millimeters| 0.001)
(defunit |Length.miles| 1609.344)
(defunit |Length.feet| 0.3048)
(defunit |Length.inches| 0.0254)
(defunit |Length.yards| 0.9144)
(defunit |Length.nauticalMiles| 1852.0)
(defaccessor |Length.inMeters| 1.0)
(defaccessor |Length.inKilometers| 1000.0)
(defaccessor |Length.inCentimeters| 0.01)
(defaccessor |Length.inMillimeters| 0.001)
(defaccessor |Length.inMiles| 1609.344)
(defaccessor |Length.inFeet| 0.3048)
(defaccessor |Length.inInches| 0.0254)
(defaccessor |Length.inYards| 0.9144)
(defaccessor |Length.inNauticalMiles| 1852.0)

;; ── Mass (canonical: kilograms) ─────────────────────────────────────────────
(defunit |Mass.kilograms| 1.0)
(defunit |Mass.grams| 0.001)
(defunit |Mass.milligrams| 0.000001)
(defunit |Mass.tonnes| 1000.0)
(defunit |Mass.pounds| 0.45359237)
(defunit |Mass.ounces| 0.028349523125)
(defaccessor |Mass.inKilograms| 1.0)
(defaccessor |Mass.inGrams| 0.001)
(defaccessor |Mass.inMilligrams| 0.000001)
(defaccessor |Mass.inTonnes| 1000.0)
(defaccessor |Mass.inPounds| 0.45359237)
(defaccessor |Mass.inOunces| 0.028349523125)

;; ── Duration (canonical: seconds) ───────────────────────────────────────────
(defunit |Duration.seconds| 1.0)
(defunit |Duration.milliseconds| 0.001)
(defunit |Duration.minutes| 60.0)
(defunit |Duration.hours| 3600.0)
(defunit |Duration.days| 86400.0)
;; PosixMillis-delta bridge: exact-Int ms ⇄ typed Duration.  toMillis rounds
;; HALF-EVEN on the exact rational (the Money.convert rounding stance);
;; fromMillis is exact-in, Float-out.
(define (|Duration.toMillis| dur)
  (round (* (inexact->exact (exact->inexact (raw-value dur))) 1000)))
(define (|Duration.fromMillis| ms)
  (/ (exact->inexact (raw-value ms)) 1000.0))
(provide |Duration.toMillis| |Duration.fromMillis|)
(defaccessor |Duration.inSeconds| 1.0)
(defaccessor |Duration.inMilliseconds| 0.001)
(defaccessor |Duration.inMinutes| 60.0)
(defaccessor |Duration.inHours| 3600.0)
(defaccessor |Duration.inDays| 86400.0)

;; ── Speed (canonical: m/s) ──────────────────────────────────────────────────
(defunit |Speed.metersPerSecond| 1.0)
(defunit |Speed.kilometersPerHour| #i1000/3600)
(defunit |Speed.milesPerHour| 0.44704)
(defunit |Speed.knots| #i1852/3600)
(defaccessor |Speed.inMetersPerSecond| 1.0)
(defaccessor |Speed.inKilometersPerHour| #i1000/3600)
(defaccessor |Speed.inMilesPerHour| 0.44704)
(defaccessor |Speed.inKnots| #i1852/3600)

;; ── Acceleration (canonical: m/s^2) ─────────────────────────────────────────
(defunit |Acceleration.metersPerSecondSquared| 1.0)
(defaccessor |Acceleration.inMetersPerSecondSquared| 1.0)

;; ── Area (canonical: m^2) ───────────────────────────────────────────────────
(defunit |Area.squareMeters| 1.0)
(defunit |Area.squareKilometers| 1000000.0)
(defunit |Area.hectares| 10000.0)
(defunit |Area.squareFeet| 0.09290304)
(defunit |Area.acres| 4046.8564224)
(defaccessor |Area.inSquareMeters| 1.0)
(defaccessor |Area.inSquareKilometers| 1000000.0)
(defaccessor |Area.inHectares| 10000.0)
(defaccessor |Area.inSquareFeet| 0.09290304)
(defaccessor |Area.inAcres| 4046.8564224)

;; ── Volume (canonical: m^3) ─────────────────────────────────────────────────
(defunit |Volume.cubicMeters| 1.0)
(defunit |Volume.liters| 0.001)
(defunit |Volume.milliliters| 0.000001)
(defunit |Volume.gallons| 0.003785411784)
(defaccessor |Volume.inCubicMeters| 1.0)
(defaccessor |Volume.inLiters| 0.001)
(defaccessor |Volume.inMilliliters| 0.000001)
(defaccessor |Volume.inGallons| 0.003785411784)

;; ── Temperature (canonical: kelvin) ─────────────────────────────────────────
;; Celsius/Fahrenheit are AFFINE (offset) constructors — expressible because a
;; constructor is an arbitrary Float→Float; the resulting quantity is absolute
;; kelvin.  Note the physics caveat documented in the manual: adding two
;; absolute temperatures type-checks (same dimension) but is rarely meaningful.
(define (|Temperature.kelvin| v) (exact->inexact (raw-value v)))
(define (|Temperature.celsius| v) (+ (exact->inexact (raw-value v)) 273.15))
(define (|Temperature.fahrenheit| v)
  (+ (* (- (exact->inexact (raw-value v)) 32.0) #i5/9) 273.15))
(define (|Temperature.inKelvin| q) (exact->inexact (raw-value q)))
(define (|Temperature.inCelsius| q) (- (exact->inexact (raw-value q)) 273.15))
(define (|Temperature.inFahrenheit| q)
  (+ (* (- (exact->inexact (raw-value q)) 273.15) 1.8) 32.0))
(provide |Temperature.kelvin| |Temperature.celsius| |Temperature.fahrenheit|
         |Temperature.inKelvin| |Temperature.inCelsius| |Temperature.inFahrenheit|)

;; ── Force / Energy / Power / Frequency / Pressure ───────────────────────────
(defunit |Force.newtons| 1.0)
(defaccessor |Force.inNewtons| 1.0)
(defunit |Energy.joules| 1.0)
(defunit |Energy.kilojoules| 1000.0)
(defunit |Energy.kilowattHours| 3600000.0)
(defunit |Energy.calories| 4.184)
(defaccessor |Energy.inJoules| 1.0)
(defaccessor |Energy.inKilojoules| 1000.0)
(defaccessor |Energy.inKilowattHours| 3600000.0)
(defaccessor |Energy.inCalories| 4.184)
(defunit |Power.watts| 1.0)
(defunit |Power.kilowatts| 1000.0)
(defunit |Power.horsepower| 745.6998715822702)
(defaccessor |Power.inWatts| 1.0)
(defaccessor |Power.inKilowatts| 1000.0)
(defaccessor |Power.inHorsepower| 745.6998715822702)
(defunit |Frequency.hertz| 1.0)
(defunit |Frequency.kilohertz| 1000.0)
(defaccessor |Frequency.inHertz| 1.0)
(defaccessor |Frequency.inKilohertz| 1000.0)
(defunit |Pressure.pascals| 1.0)
(defunit |Pressure.kilopascals| 1000.0)
(defunit |Pressure.bar| 100000.0)
(defaccessor |Pressure.inPascals| 1.0)
(defaccessor |Pressure.inKilopascals| 1000.0)
(defaccessor |Pressure.inBar| 100000.0)

;; ── Polymorphic dimension operations (checker-typed per application site) ───
(define (|Units.mul| a b) (* (exact->inexact (raw-value a)) (exact->inexact (raw-value b))))
(define (|Units.div| a b) (/ (exact->inexact (raw-value a)) (exact->inexact (raw-value b))))
(define (|Units.square| a) (let ([x (exact->inexact (raw-value a))]) (* x x)))
(define (|Units.sqrt| a) (sqrt (exact->inexact (raw-value a))))
(define (|Units.abs| a) (abs (exact->inexact (raw-value a))))
(define (|Units.negate| a) (- (exact->inexact (raw-value a))))
(define (|Units.min| a b) (min (exact->inexact (raw-value a)) (exact->inexact (raw-value b))))
(define (|Units.max| a b) (max (exact->inexact (raw-value a)) (exact->inexact (raw-value b))))
(define (|Units.sum| xs) (for/fold ([acc 0.0]) ([x (in-list (raw-value xs))])
                           (+ acc (exact->inexact (raw-value x)))))
(provide |Units.mul| |Units.div| |Units.square| |Units.sqrt| |Units.abs|
         |Units.negate| |Units.min| |Units.max| |Units.sum|)

;; Units.requireNonZero — check function returning q ::: FloatNonZero q.
;; Quantities erase to Floats, so the SAME FloatNonZero predicate that guards
;; Float division guards quantity division (`d / t` demands a non-zero
;; divisor proof, exactly like every other `/`).  Clone of
;; Float.requireNonZero (tesl/float.rkt).
(define (|Units.requireNonZero| q)
  (define v (exact->inexact (raw-value q)))
  (if (not (zero? v))
      (let* ([nv   (ensure-named 'FloatNonZero v)]
             [subj (named-value-name nv)]
             [attached (attach nv (list (detached-proof `(FloatNonZero ,subj) (hash subj v))))]
             [fact `(FloatNonZero ,subj)])
        (check-ok attached (list fact) (hash subj v)))
      (check-fail "expected a non-zero quantity" 422 #f)))
(provide |Units.requireNonZero|)
