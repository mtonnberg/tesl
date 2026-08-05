#lang racket
;; ─────────────────────────────────────────────────────────────────────────────
;; Tesl.CivilTime — public runtime module (SHIM).
;;
;; There is no hand-written Racket calendar in here, and that is the point.  The
;; whole of `Tesl.CivilTime` is written in Tesl (`tesl/civil-time.tesl`) and
;; compiled at build time to `tesl/civil-time-derived.rkt`; this file only
;; re-exports those compiled bodies under the dotted `CivilTime.*` runtime names
;; the emitter calls, exactly as `tesl/either.rkt` does for `tesl/either.tesl`.
;;
;; Why it matters here more than usual: civil-date arithmetic is where off-by-one
;; bugs live (the March-based year shift, the two ISO week-year corrections, the
;; clamping month step), and a wrong answer shows up as one bad week per year
;; rather than as a crash.  Written in Tesl, that logic is type-checked, and its
;; range facts are minted by checks the language verifies — none of which a
;; hand-written Racket implementation would get.
;;
;; The types (CivilDate, IsoWeek, Month, Weekday) are declared in the Tesl source
;; too, so they arrive here from the derived module along with everything else;
;; there is no `-prim` leaf, because nothing in this module is irreducible.
;; ─────────────────────────────────────────────────────────────────────────────

(require (only-in "civil-time-derived.rkt"
                  ;; Types (the type-name values the emitter splices into type
                  ;; positions) — re-exported unrenamed, like Either/Url.
                  CivilDate IsoWeek Month Weekday
                  ;; Month / Weekday constructors: value constructors keep their
                  ;; bare names (a Tesl `case` matches on the variant tag).
                  January February March April May June
                  July August September October November December
                  Monday Tuesday Wednesday Thursday Friday Saturday Sunday
                  ;; Proof predicate names, used in Tesl annotations.
                  IsDayOfMonth IsMonthNumber IsDayOfYear
                  IsWeekNumber IsWeekdayNumber IsMonthLength
                  DayOfMonth SameCalendar
                  ;; Checks + functions, renamed to the dotted runtime names.
                  [checkDayOfMonth CivilTime.checkDayOfMonth]
                  [sameCalendar    CivilTime.sameCalendar]
                  [fromParts       CivilTime.fromParts]
                  [fromChecked     CivilTime.fromChecked]
                  [fromDayNumber   CivilTime.fromDayNumber]
                  [fromInstant     CivilTime.fromInstant]
                  [fromIso         CivilTime.fromIso]
                  [startOfDay      CivilTime.startOfDay]
                  [endOfDay        CivilTime.endOfDay]
                  [dayNumber       CivilTime.dayNumber]
                  [zone            CivilTime.zone]
                  [year            CivilTime.year]
                  [month           CivilTime.month]
                  [day             CivilTime.day]
                  [weekday         CivilTime.weekday]
                  [dayOfYear       CivilTime.dayOfYear]
                  [isoWeekOf       CivilTime.isoWeekOf]
                  [isoWeek         CivilTime.isoWeek]
                  [weekYear        CivilTime.weekYear]
                  [weekNumber      CivilTime.weekNumber]
                  [monthNumber     CivilTime.monthNumber]
                  [monthFromNumber CivilTime.monthFromNumber]
                  [weekdayNumber   CivilTime.weekdayNumber]
                  [addDays         CivilTime.addDays]
                  [diffDays        CivilTime.diffDays]
                  [addMonths       CivilTime.addMonths]
                  [startOfMonth    CivilTime.startOfMonth]
                  [endOfMonth      CivilTime.endOfMonth]
                  [startOfWeek     CivilTime.startOfWeek]
                  [startOfYear     CivilTime.startOfYear]
                  [daysInMonth     CivilTime.daysInMonth]
                  [isLeapYear      CivilTime.isLeapYear]
                  [datesBetween    CivilTime.datesBetween]
                  [isBefore        CivilTime.isBefore]
                  [toIso           CivilTime.toIso]
                  [isoWeekLabel    CivilTime.isoWeekLabel]))

(provide CivilDate IsoWeek Month Weekday
         January February March April May June
         July August September October November December
         Monday Tuesday Wednesday Thursday Friday Saturday Sunday
         IsDayOfMonth IsMonthNumber IsDayOfYear
         IsWeekNumber IsWeekdayNumber IsMonthLength
         DayOfMonth SameCalendar
         CivilTime.checkDayOfMonth CivilTime.sameCalendar
         CivilTime.fromParts CivilTime.fromChecked CivilTime.fromDayNumber
         CivilTime.fromInstant CivilTime.fromIso
         CivilTime.startOfDay CivilTime.endOfDay
         CivilTime.dayNumber CivilTime.zone CivilTime.year CivilTime.month
         CivilTime.day CivilTime.weekday CivilTime.dayOfYear
         CivilTime.isoWeekOf CivilTime.isoWeek CivilTime.weekYear
         CivilTime.weekNumber CivilTime.monthNumber CivilTime.monthFromNumber
         CivilTime.weekdayNumber
         CivilTime.addDays CivilTime.diffDays CivilTime.addMonths
         CivilTime.startOfMonth CivilTime.endOfMonth CivilTime.startOfWeek
         CivilTime.startOfYear CivilTime.daysInMonth CivilTime.isLeapYear
         CivilTime.datesBetween CivilTime.isBefore
         CivilTime.toIso CivilTime.isoWeekLabel)
