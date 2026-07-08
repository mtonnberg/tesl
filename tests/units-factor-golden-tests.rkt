#lang racket

;;; First-Class Units — GOLDEN conversion-factor oracle (audit gap: the
;;; factors in tesl/units.rkt were previously exercised only against
;;; themselves — a mistyped factor would round-trip "correctly" and pass).
;;;
;;; ORACLE INDEPENDENCE: every expected value below is HAND-WRITTEN from the
;;; unit's physical/legal definition (SI brochure, the 1959 international
;;; yard-and-pound agreement, the 1929 nautical mile, the thermochemical
;;; calorie, 550 ft·lbf/s mechanical horsepower, the 231 in³ US gallon) —
;;; NOT read out of tesl/units.rkt, which would be circular.  If a factor in
;;; units.rkt drifts, this file fails.
;;;
;;; Shape: a constructor converts value-in-unit → SI-canonical Float, so
;;; (ctor 1.0) must equal the canonical-units-per-unit factor EXACTLY (one
;;; IEEE multiply by the factor double); the accessor is the inverse, so
;;; (accessor factor) must be exactly 1.0 (x/x).  The 2.5-roundtrip uses a
;;; small epsilon: multiply-then-divide is not guaranteed exact for every
;;; non-dyadic factor.

(require rackunit
         "../tesl/units.rkt"
         (only-in "../dsl/private/money-core.rkt" rate-label-table))

;; ── Linear units: (name constructor accessor hand-oracle-factor) ───────────
;; Factor = SI-canonical units per ONE named unit, from the definition.
(define linear-units
  (list
   ;; Length (canonical: meters)
   (list "Length.meters"        |Length.meters|        |Length.inMeters|        1.0)
   (list "Length.kilometers"    |Length.kilometers|    |Length.inKilometers|    1000.0)
   (list "Length.centimeters"   |Length.centimeters|   |Length.inCentimeters|   0.01)
   (list "Length.millimeters"   |Length.millimeters|   |Length.inMillimeters|   0.001)
   ;; international mile (1959): exactly 1609.344 m
   (list "Length.miles"         |Length.miles|         |Length.inMiles|         1609.344)
   ;; international foot (1959): exactly 0.3048 m
   (list "Length.feet"          |Length.feet|          |Length.inFeet|          0.3048)
   ;; international inch: exactly 25.4 mm
   (list "Length.inches"        |Length.inches|        |Length.inInches|        0.0254)
   ;; international yard: exactly 0.9144 m
   (list "Length.yards"         |Length.yards|         |Length.inYards|         0.9144)
   ;; nautical mile (1929 Monaco): exactly 1852 m
   (list "Length.nauticalMiles" |Length.nauticalMiles| |Length.inNauticalMiles| 1852.0)
   ;; Mass (canonical: kilograms)
   (list "Mass.kilograms"  |Mass.kilograms|  |Mass.inKilograms|  1.0)
   (list "Mass.grams"      |Mass.grams|      |Mass.inGrams|      0.001)
   (list "Mass.milligrams" |Mass.milligrams| |Mass.inMilligrams| 0.000001)
   (list "Mass.tonnes"     |Mass.tonnes|     |Mass.inTonnes|     1000.0)
   ;; avoirdupois pound (1959): exactly 0.45359237 kg
   (list "Mass.pounds"     |Mass.pounds|     |Mass.inPounds|     0.45359237)
   ;; avoirdupois ounce: exactly 1/16 lb = 0.45359237/16 = 0.028349523125 kg
   (list "Mass.ounces"     |Mass.ounces|     |Mass.inOunces|     0.028349523125)
   ;; Duration (canonical: seconds)
   (list "Duration.seconds"      |Duration.seconds|      |Duration.inSeconds|      1.0)
   (list "Duration.milliseconds" |Duration.milliseconds| |Duration.inMilliseconds| 0.001)
   (list "Duration.minutes"      |Duration.minutes|      |Duration.inMinutes|      60.0)
   (list "Duration.hours"        |Duration.hours|        |Duration.inHours|        3600.0)
   (list "Duration.days"         |Duration.days|         |Duration.inDays|         86400.0)
   ;; Speed (canonical: m/s)
   (list "Speed.metersPerSecond"   |Speed.metersPerSecond|   |Speed.inMetersPerSecond|   1.0)
   ;; 1 km/h = 1000 m / 3600 s
   (list "Speed.kilometersPerHour" |Speed.kilometersPerHour| |Speed.inKilometersPerHour| (/ 1000.0 3600.0))
   ;; 1 mph = 1609.344 m / 3600 s = exactly 0.44704 m/s
   (list "Speed.milesPerHour"      |Speed.milesPerHour|      |Speed.inMilesPerHour|      0.44704)
   ;; 1 knot = 1852 m / 3600 s ≈ 0.51444…
   (list "Speed.knots"             |Speed.knots|             |Speed.inKnots|             (/ 1852.0 3600.0))
   ;; Acceleration (canonical: m/s²)
   (list "Acceleration.metersPerSecondSquared"
         |Acceleration.metersPerSecondSquared| |Acceleration.inMetersPerSecondSquared| 1.0)
   ;; Area (canonical: m²)
   (list "Area.squareMeters"     |Area.squareMeters|     |Area.inSquareMeters|     1.0)
   (list "Area.squareKilometers" |Area.squareKilometers| |Area.inSquareKilometers| 1000000.0)
   ;; hectare: 100 m × 100 m
   (list "Area.hectares"         |Area.hectares|         |Area.inHectares|         10000.0)
   ;; 1 ft² = 0.3048² = exactly 0.09290304 m²
   (list "Area.squareFeet"       |Area.squareFeet|       |Area.inSquareFeet|       0.09290304)
   ;; 1 acre = 43560 ft² = 43560 × 0.09290304 = exactly 4046.8564224 m²
   (list "Area.acres"            |Area.acres|            |Area.inAcres|            4046.8564224)
   ;; Volume (canonical: m³)
   (list "Volume.cubicMeters" |Volume.cubicMeters| |Volume.inCubicMeters| 1.0)
   (list "Volume.liters"      |Volume.liters|      |Volume.inLiters|      0.001)
   (list "Volume.milliliters" |Volume.milliliters| |Volume.inMilliliters| 0.000001)
   ;; US gallon: 231 in³ = 231 × 0.0254³ = exactly 0.003785411784 m³
   (list "Volume.gallons"     |Volume.gallons|     |Volume.inGallons|     0.003785411784)
   ;; Force (canonical: newtons)
   (list "Force.newtons" |Force.newtons| |Force.inNewtons| 1.0)
   ;; Energy (canonical: joules)
   (list "Energy.joules"        |Energy.joules|        |Energy.inJoules|        1.0)
   (list "Energy.kilojoules"    |Energy.kilojoules|    |Energy.inKilojoules|    1000.0)
   ;; 1 kWh = 1000 W × 3600 s
   (list "Energy.kilowattHours" |Energy.kilowattHours| |Energy.inKilowattHours| 3600000.0)
   ;; thermochemical calorie: exactly 4.184 J
   (list "Energy.calories"      |Energy.calories|      |Energy.inCalories|      4.184)
   ;; Power (canonical: watts)
   (list "Power.watts"      |Power.watts|      |Power.inWatts|      1.0)
   (list "Power.kilowatts"  |Power.kilowatts|  |Power.inKilowatts| 1000.0)
   ;; mechanical horsepower: 550 ft·lbf/s = 550 × 0.3048 × 0.45359237 × 9.80665
   ;; (independent derivation as an exact rational, then one float rounding)
   (list "Power.horsepower" |Power.horsepower| |Power.inHorsepower|
         (exact->inexact (* 550 3048/10000 45359237/100000000 980665/100000)))
   ;; Frequency (canonical: hertz)
   (list "Frequency.hertz"     |Frequency.hertz|     |Frequency.inHertz|     1.0)
   (list "Frequency.kilohertz" |Frequency.kilohertz| |Frequency.inKilohertz| 1000.0)
   ;; Pressure (canonical: pascals)
   (list "Pressure.pascals"     |Pressure.pascals|     |Pressure.inPascals|     1.0)
   (list "Pressure.kilopascals" |Pressure.kilopascals| |Pressure.inKilopascals| 1000.0)
   ;; 1 bar = exactly 100 kPa
   (list "Pressure.bar"         |Pressure.bar|         |Pressure.inBar|         100000.0)))

(for ([row (in-list linear-units)])
  (match-define (list name ctor accessor factor) row)
  ;; constructor: 1 unit → factor canonical units, EXACT ((* 1.0 f) = f)
  (check-equal? (ctor 1.0) factor (format "~a factor" name))
  ;; accessor is the inverse: factor canonical units → exactly 1 unit (x/x)
  (check-equal? (accessor factor) 1.0 (format "in~a inverse" name))
  ;; round-trip at a non-unit value (multiply-then-divide may be off 1 ulp
  ;; for non-dyadic factors, hence the epsilon)
  (check-= (accessor (ctor 2.5)) 2.5 1e-12 (format "~a round-trip" name)))

;; a sanity pin that the table above covers every constructor family
(check-equal? (length linear-units) 47 "the linear oracle table covers all rows")

;; ── Temperature: AFFINE constructors (canonical: kelvin) ────────────────────
;; K = C + 273.15;  K = (F − 32)·5/9 + 273.15.  All the fixed points below
;; were verified to be exact in binary double arithmetic.
(check-equal? (|Temperature.kelvin| 1.0) 1.0 "kelvin identity")
(check-equal? (|Temperature.celsius| 0.0) 273.15 "0 C = 273.15 K")
(check-equal? (|Temperature.celsius| 100.0) 373.15 "100 C = 373.15 K")
(check-equal? (|Temperature.fahrenheit| 32.0) 273.15 "32 F = 273.15 K")
(check-equal? (|Temperature.fahrenheit| 212.0) 373.15 "212 F = 373.15 K")
(check-equal? (|Temperature.inKelvin| 300.0) 300.0 "inKelvin identity")
(check-equal? (|Temperature.inCelsius| 273.15) 0.0 "273.15 K = 0 C")
(check-equal? (|Temperature.inCelsius| 373.15) 100.0 "373.15 K = 100 C")
(check-equal? (|Temperature.inFahrenheit| 273.15) 32.0 "273.15 K = 32 F")
(check-equal? (|Temperature.inFahrenheit| 373.15) 212.0 "373.15 K = 212 F")
;; -40 is the same in C and F
(check-= (|Temperature.inFahrenheit| (|Temperature.celsius| -40.0)) -40.0 1e-9
         "-40 C = -40 F")

;; ── Duration ⇄ millis bridge (exact-Int ms ⇄ typed Duration) ────────────────
(check-equal? (|Duration.toMillis| 1.5) 1500 "toMillis is ms, exact int")
(check-equal? (|Duration.fromMillis| 1500) 1.5 "fromMillis is seconds, float")

;; ── MoneyRate boundary labels (GitHub #38 wire/SQL quantization units) ──────
;; label → (canonical units per ONE label unit . denominator dimension).
;; Hand oracle: "h" is 3600 s, "day" 86400 s, "L" 1/1000 m³, the SI bases 1.
(check-equal? rate-label-table
              (hash "s"   (cons 1       'duration)
                    "h"   (cons 3600    'duration)
                    "day" (cons 86400   'duration)
                    "kg"  (cons 1       'mass)
                    "m"   (cons 1       'length)
                    "m^2" (cons 1       'area)
                    "m^3" (cons 1       'volume)
                    "L"   (cons 1/1000  'volume))
              "the 8 rate boundary labels, factors EXACT rationals")

(printf "units-factor-golden-tests: ~a linear units + temperature + rate labels pinned\n"
        (length linear-units))
