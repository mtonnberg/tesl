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
  (only-in tesl/tesl/prelude Bool Int String List)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/string [String.concat tesl_import_String_concat] [String.fromInt tesl_import_String_fromInt] [String.join tesl_import_String_join] [String.length tesl_import_String_length] [String.padLeft tesl_import_String_padLeft] [String.slice tesl_import_String_slice] [String.toInt tesl_import_String_toInt])
  (only-in tesl/tesl/list [List.map tesl_import_List_map] [List.range tesl_import_List_range])
  (only-in tesl/tesl/time PosixMillis TimeZone [Time.offsetAt tesl_import_Time_offsetAt] [Time.secondsToPosix tesl_import_Time_secondsToPosix] addMs diffMs)
)


(provide CivilDate IsoWeek Month January February March April May June July August September October November December Weekday Monday Tuesday Wednesday Thursday Friday Saturday Sunday IsDayOfMonth IsMonthNumber IsDayOfYear IsWeekNumber IsWeekdayNumber IsMonthLength DayOfMonth SameCalendar checkDayOfMonth sameCalendar fromParts fromChecked fromDayNumber fromInstant fromIso startOfDay endOfDay dayNumber zone year month day weekday dayOfYear isoWeekOf isoWeek weekYear weekNumber monthNumber monthFromNumber weekdayNumber addDays diffDays addMonths startOfMonth endOfMonth startOfWeek startOfYear daysInMonth isLeapYear datesBetween isBefore toIso isoWeekLabel checkDayOfMonth-signature sameCalendar-signature fromDayNumber-signature fromParts-signature fromChecked-signature fromInstant-signature startOfDay-signature endOfDay-signature dayNumber-signature zone-signature year-signature month-signature day-signature weekday-signature dayOfYear-signature monthNumber-signature monthFromNumber-signature weekdayNumber-signature isoWeekOf-signature isoWeek-signature weekYear-signature weekNumber-signature addDays-signature diffDays-signature isBefore-signature addMonths-signature startOfMonth-signature endOfMonth-signature startOfWeek-signature startOfYear-signature daysInMonth-signature isLeapYear-signature datesBetween-signature toIso-signature fromIso-signature isoWeekLabel-signature)

(define DayOfMonth 'DayOfMonth)
(define IsDayOfMonth 'IsDayOfMonth)
(define IsDayOfYear 'IsDayOfYear)
(define IsMonthLength 'IsMonthLength)
(define IsMonthNumber 'IsMonthNumber)
(define IsWeekNumber 'IsWeekNumber)
(define IsWeekdayNumber 'IsWeekdayNumber)
(define SameCalendar 'SameCalendar)

(define-adt CivilDate
  [Civil [value : Integer] [value2 : TimeZone]]
)

(define-adt IsoWeek
  [Week [value : Integer] [value2 : Integer]]
)

(define-adt Month
  [January]
  [February]
  [March]
  [April]
  [May]
  [June]
  [July]
  [August]
  [September]
  [October]
  [November]
  [December]
)

(define-adt Weekday
  [Monday]
  [Tuesday]
  [Wednesday]
  [Thursday]
  [Friday]
  [Saturday]
  [Sunday]
)

(define-checker
  (asDayOfMonth [n : Integer])
  #:returns [n : Integer ::: (IsDayOfMonth n)]
  (thsl-src! "tesl/civil-time.tesl" 182 (list (cons 'n *n)) (lambda () (if (and (tesl-ge? *n 1) (tesl-le? *n 31)) (accept (IsDayOfMonth n) #:value *n) (reject "day of month out of range" #:http-code 500)))))

(define-checker
  (asMonthNumber [n : Integer])
  #:returns [n : Integer ::: (IsMonthNumber n)]
  (thsl-src! "tesl/civil-time.tesl" 188 (list (cons 'n *n)) (lambda () (if (and (tesl-ge? *n 1) (tesl-le? *n 12)) (accept (IsMonthNumber n) #:value *n) (reject "month number out of range" #:http-code 500)))))

(define-checker
  (asDayOfYear [n : Integer])
  #:returns [n : Integer ::: (IsDayOfYear n)]
  (thsl-src! "tesl/civil-time.tesl" 194 (list (cons 'n *n)) (lambda () (if (and (tesl-ge? *n 1) (tesl-le? *n 366)) (accept (IsDayOfYear n) #:value *n) (reject "day of year out of range" #:http-code 500)))))

(define-checker
  (asWeekNumber [n : Integer])
  #:returns [n : Integer ::: (IsWeekNumber n)]
  (thsl-src! "tesl/civil-time.tesl" 200 (list (cons 'n *n)) (lambda () (if (and (tesl-ge? *n 1) (tesl-le? *n 53)) (accept (IsWeekNumber n) #:value *n) (reject "ISO week number out of range" #:http-code 500)))))

(define-checker
  (asWeekdayNumber [n : Integer])
  #:returns [n : Integer ::: (IsWeekdayNumber n)]
  (thsl-src! "tesl/civil-time.tesl" 206 (list (cons 'n *n)) (lambda () (if (and (tesl-ge? *n 1) (tesl-le? *n 7)) (accept (IsWeekdayNumber n) #:value *n) (reject "weekday number out of range" #:http-code 500)))))

(define-checker
  (asMonthLength [n : Integer])
  #:returns [n : Integer ::: (IsMonthLength n)]
  (thsl-src! "tesl/civil-time.tesl" 212 (list (cons 'n *n)) (lambda () (if (and (tesl-ge? *n 28) (tesl-le? *n 31)) (accept (IsMonthLength n) #:value *n) (reject "month length out of range" #:http-code 500)))))

(define-checker
  (checkDayOfMonth [y : Integer] [m : Month] [d : Integer])
  #:returns [d : Integer ::: (DayOfMonth y m d)]
  (thsl-src! "tesl/civil-time.tesl" 223 (list (cons 'y *y) (cons 'm *m) (cons 'd *d)) (lambda () (if (and (tesl-ge? *d 1) (tesl-le? *d (raw-value (rawDaysInMonth y m)))) (accept (DayOfMonth y m d) #:value *d) (reject "no such day in that month" #:http-code 400)))))

(define/pow
  (zoneMatches [a : CivilDate] [b : CivilDate])
  #:returns Boolean
  (thsl-src! "tesl/civil-time.tesl" 232 (list (cons 'a *a) (cons 'b *b)) (lambda () (tesl-equal? (raw-value (zone a)) (raw-value (zone b))))))

(define-checker
  (sameCalendar [a : CivilDate] [b : CivilDate])
  #:returns [b : CivilDate ::: (SameCalendar a b)]
  (thsl-src! "tesl/civil-time.tesl" 235 (list (cons 'a *a) (cons 'b *b)) (lambda () (if (zoneMatches a b) (accept (SameCalendar a b) #:value *b) (reject "the two dates were read in different time zones" #:http-code 400)))))

(define/pow
  (floorDivDay [ms : Integer])
  #:returns Integer
  (let ([q (thsl-src! "tesl/civil-time.tesl" 247 (list (cons 'ms *ms)) (lambda () (quotient *ms 86400000)))]) (thsl-src! "tesl/civil-time.tesl" 248 (list (cons 'q *q) (cons 'ms *ms)) (lambda () (if (tesl-lt? (- *ms (* (raw-value q) 86400000)) 0) (raw-value (- (raw-value q) 1)) (raw-value q))))))

(define/pow
  (mod7 [n : Integer])
  #:returns Integer
  (let ([r (thsl-src! "tesl/civil-time.tesl" 254 (list (cons 'n *n)) (lambda () (remainder *n 7)))]) (thsl-src! "tesl/civil-time.tesl" 255 (list (cons 'r *r) (cons 'n *n)) (lambda () (if (tesl-lt? (raw-value r) 0) (raw-value (+ (raw-value r) 7)) (raw-value r))))))

(define/pow
  (marchYear [y : Integer] [monthNo : Integer])
  #:returns Integer
  (thsl-src! "tesl/civil-time.tesl" 266 (list (cons 'y *y) (cons 'monthNo *monthNo)) (lambda () (if (tesl-le? *monthNo 2) (raw-value (- *y 1)) *y))))

(define/pow
  (marchMonthIndex [monthNo : Integer])
  #:returns Integer
  (thsl-src! "tesl/civil-time.tesl" 272 (list (cons 'monthNo *monthNo)) (lambda () (if (tesl-gt? *monthNo 2) (raw-value (- *monthNo 3)) (raw-value (+ *monthNo 9))))))

(define/pow
  (dayFromYmd [y : Integer] [monthNo : Integer] [d : Integer])
  #:returns Integer
  (let ([my (thsl-src! "tesl/civil-time.tesl" 278 (list (cons 'y *y) (cons 'monthNo *monthNo) (cons 'd *d)) (lambda () (marchYear y monthNo)))]) (let ([era (thsl-src! "tesl/civil-time.tesl" 279 (list (cons 'my *my) (cons 'y *y) (cons 'monthNo *monthNo) (cons 'd *d)) (lambda () (quotient (raw-value my) 400)))]) (let ([yoe (thsl-src! "tesl/civil-time.tesl" 280 (list (cons 'era *era) (cons 'my *my) (cons 'y *y) (cons 'monthNo *monthNo) (cons 'd *d)) (lambda () (- (raw-value my) (* (raw-value era) 400))))]) (let ([mp (thsl-src! "tesl/civil-time.tesl" 281 (list (cons 'yoe *yoe) (cons 'era *era) (cons 'my *my) (cons 'y *y) (cons 'monthNo *monthNo) (cons 'd *d)) (lambda () (marchMonthIndex monthNo)))]) (let ([doy (thsl-src! "tesl/civil-time.tesl" 282 (list (cons 'mp *mp) (cons 'yoe *yoe) (cons 'era *era) (cons 'my *my) (cons 'y *y) (cons 'monthNo *monthNo) (cons 'd *d)) (lambda () (- (+ (quotient (+ (* 153 (raw-value mp)) 2) 5) *d) 1)))]) (let ([doe (thsl-src! "tesl/civil-time.tesl" 283 (list (cons 'doy *doy) (cons 'mp *mp) (cons 'yoe *yoe) (cons 'era *era) (cons 'my *my) (cons 'y *y) (cons 'monthNo *monthNo) (cons 'd *d)) (lambda () (+ (- (+ (* (raw-value yoe) 365) (quotient (raw-value yoe) 4)) (quotient (raw-value yoe) 100)) (raw-value doy))))]) (thsl-src! "tesl/civil-time.tesl" 284 (list (cons 'doe *doe) (cons 'doy *doy) (cons 'mp *mp) (cons 'yoe *yoe) (cons 'era *era) (cons 'my *my) (cons 'y *y) (cons 'monthNo *monthNo) (cons 'd *d)) (lambda () (- (+ (* (raw-value era) 146097) (raw-value doe)) 719468))))))))))

(define/pow
  (shiftedDay [n : Integer])
  #:returns Integer
  (thsl-src! "tesl/civil-time.tesl" 292 (list (cons 'n *n)) (lambda () (+ *n 719468))))

(define/pow
  (eraOf [n : Integer])
  #:returns Integer
  (thsl-src! "tesl/civil-time.tesl" 295 (list (cons 'n *n)) (lambda () (quotient (raw-value (shiftedDay n)) 146097))))

(define/pow
  (doeOf [n : Integer])
  #:returns Integer
  (thsl-src! "tesl/civil-time.tesl" 298 (list (cons 'n *n)) (lambda () (- (raw-value (shiftedDay n)) (* (raw-value (eraOf n)) 146097)))))

(define/pow
  (yoeOf [n : Integer])
  #:returns Integer
  (let ([doe (thsl-src! "tesl/civil-time.tesl" 301 (list (cons 'n *n)) (lambda () (doeOf n)))]) (thsl-src! "tesl/civil-time.tesl" 302 (list (cons 'doe *doe) (cons 'n *n)) (lambda () (quotient (- (+ (- (raw-value doe) (quotient (raw-value doe) 1460)) (quotient (raw-value doe) 36524)) (quotient (raw-value doe) 146096)) 365)))))

(define/pow
  (doyOf [n : Integer])
  #:returns Integer
  (let ([yoe (thsl-src! "tesl/civil-time.tesl" 305 (list (cons 'n *n)) (lambda () (yoeOf n)))]) (thsl-src! "tesl/civil-time.tesl" 306 (list (cons 'yoe *yoe) (cons 'n *n)) (lambda () (- (raw-value (doeOf n)) (- (+ (* 365 (raw-value yoe)) (quotient (raw-value yoe) 4)) (quotient (raw-value yoe) 100)))))))

(define/pow
  (mpOf [n : Integer])
  #:returns Integer
  (thsl-src! "tesl/civil-time.tesl" 309 (list (cons 'n *n)) (lambda () (quotient (+ (* 5 (raw-value (doyOf n))) 2) 153))))

(define/pow
  (rawDayOfMonth [n : Integer])
  #:returns Integer
  (thsl-src! "tesl/civil-time.tesl" 312 (list (cons 'n *n)) (lambda () (+ (- (raw-value (doyOf n)) (quotient (+ (* 153 (raw-value (mpOf n))) 2) 5)) 1))))

(define/pow
  (rawMonthNumber [n : Integer])
  #:returns Integer
  (let ([mp (thsl-src! "tesl/civil-time.tesl" 315 (list (cons 'n *n)) (lambda () (mpOf n)))]) (thsl-src! "tesl/civil-time.tesl" 316 (list (cons 'mp *mp) (cons 'n *n)) (lambda () (if (tesl-lt? (raw-value mp) 10) (raw-value (+ (raw-value mp) 3)) (raw-value (- (raw-value mp) 9)))))))

(define/pow
  (rawYear [n : Integer])
  #:returns Integer
  (let ([marchBased (thsl-src! "tesl/civil-time.tesl" 322 (list (cons 'n *n)) (lambda () (+ (raw-value (yoeOf n)) (* (raw-value (eraOf n)) 400))))]) (thsl-src! "tesl/civil-time.tesl" 323 (list (cons 'marchBased *marchBased) (cons 'n *n)) (lambda () (if (tesl-le? (raw-value (rawMonthNumber n)) 2) (raw-value (+ (raw-value marchBased) 1)) (raw-value marchBased))))))

(define/pow
  (rawMonthNumberOf [m : Month])
  #:returns Integer
  (thsl-src-control! "tesl/civil-time.tesl" 331 (list (cons 'm *m)) (lambda () (let ([tesl-case-0 *m]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'January)) (thsl-src! "tesl/civil-time.tesl" 332 (list) (lambda () (raw-value 1)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'February)) (thsl-src! "tesl/civil-time.tesl" 333 (list) (lambda () (raw-value 2)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'March)) (thsl-src! "tesl/civil-time.tesl" 334 (list) (lambda () (raw-value 3)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'April)) (thsl-src! "tesl/civil-time.tesl" 335 (list) (lambda () (raw-value 4)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'May)) (thsl-src! "tesl/civil-time.tesl" 336 (list) (lambda () (raw-value 5)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'June)) (thsl-src! "tesl/civil-time.tesl" 337 (list) (lambda () (raw-value 6)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'July)) (thsl-src! "tesl/civil-time.tesl" 338 (list) (lambda () (raw-value 7)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'August)) (thsl-src! "tesl/civil-time.tesl" 339 (list) (lambda () (raw-value 8)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'September)) (thsl-src! "tesl/civil-time.tesl" 340 (list) (lambda () (raw-value 9)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'October)) (thsl-src! "tesl/civil-time.tesl" 341 (list) (lambda () (raw-value 10)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'November)) (thsl-src! "tesl/civil-time.tesl" 342 (list) (lambda () (raw-value 11)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'December)) (thsl-src! "tesl/civil-time.tesl" 343 (list) (lambda () (raw-value 12)))])))))

(define/pow
  (monthOfNumber [n : Integer])
  #:returns Month
  (thsl-src-control! "tesl/civil-time.tesl" 349 (list (cons 'n *n)) (lambda () (let ([tesl-case-1 *n]) (cond [(= *tesl-case-1 1) (thsl-src! "tesl/civil-time.tesl" 350 (list) (lambda () (raw-value January)))] [(= *tesl-case-1 2) (thsl-src! "tesl/civil-time.tesl" 351 (list) (lambda () (raw-value February)))] [(= *tesl-case-1 3) (thsl-src! "tesl/civil-time.tesl" 352 (list) (lambda () (raw-value March)))] [(= *tesl-case-1 4) (thsl-src! "tesl/civil-time.tesl" 353 (list) (lambda () (raw-value April)))] [(= *tesl-case-1 5) (thsl-src! "tesl/civil-time.tesl" 354 (list) (lambda () (raw-value May)))] [(= *tesl-case-1 6) (thsl-src! "tesl/civil-time.tesl" 355 (list) (lambda () (raw-value June)))] [(= *tesl-case-1 7) (thsl-src! "tesl/civil-time.tesl" 356 (list) (lambda () (raw-value July)))] [(= *tesl-case-1 8) (thsl-src! "tesl/civil-time.tesl" 357 (list) (lambda () (raw-value August)))] [(= *tesl-case-1 9) (thsl-src! "tesl/civil-time.tesl" 358 (list) (lambda () (raw-value September)))] [(= *tesl-case-1 10) (thsl-src! "tesl/civil-time.tesl" 359 (list) (lambda () (raw-value October)))] [(= *tesl-case-1 11) (thsl-src! "tesl/civil-time.tesl" 360 (list) (lambda () (raw-value November)))] [#t (thsl-src! "tesl/civil-time.tesl" 361 (list) (lambda () (raw-value December)))])))))

(define/pow
  (rawWeekdayNumberOf [w : Weekday])
  #:returns Integer
  (thsl-src-control! "tesl/civil-time.tesl" 364 (list (cons 'w *w)) (lambda () (let ([tesl-case-2 *w]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Monday)) (thsl-src! "tesl/civil-time.tesl" 365 (list) (lambda () (raw-value 1)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Tuesday)) (thsl-src! "tesl/civil-time.tesl" 366 (list) (lambda () (raw-value 2)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Wednesday)) (thsl-src! "tesl/civil-time.tesl" 367 (list) (lambda () (raw-value 3)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Thursday)) (thsl-src! "tesl/civil-time.tesl" 368 (list) (lambda () (raw-value 4)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Friday)) (thsl-src! "tesl/civil-time.tesl" 369 (list) (lambda () (raw-value 5)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Saturday)) (thsl-src! "tesl/civil-time.tesl" 370 (list) (lambda () (raw-value 6)))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Sunday)) (thsl-src! "tesl/civil-time.tesl" 371 (list) (lambda () (raw-value 7)))])))))

(define/pow
  (weekdayOfNumber [n : Integer])
  #:returns Weekday
  (thsl-src-control! "tesl/civil-time.tesl" 374 (list (cons 'n *n)) (lambda () (let ([tesl-case-3 *n]) (cond [(= *tesl-case-3 1) (thsl-src! "tesl/civil-time.tesl" 375 (list) (lambda () (raw-value Monday)))] [(= *tesl-case-3 2) (thsl-src! "tesl/civil-time.tesl" 376 (list) (lambda () (raw-value Tuesday)))] [(= *tesl-case-3 3) (thsl-src! "tesl/civil-time.tesl" 377 (list) (lambda () (raw-value Wednesday)))] [(= *tesl-case-3 4) (thsl-src! "tesl/civil-time.tesl" 378 (list) (lambda () (raw-value Thursday)))] [(= *tesl-case-3 5) (thsl-src! "tesl/civil-time.tesl" 379 (list) (lambda () (raw-value Friday)))] [(= *tesl-case-3 6) (thsl-src! "tesl/civil-time.tesl" 380 (list) (lambda () (raw-value Saturday)))] [#t (thsl-src! "tesl/civil-time.tesl" 381 (list) (lambda () (raw-value Sunday)))])))))

(define/pow
  (rawWeekdayOfDay [n : Integer])
  #:returns Integer
  (thsl-src! "tesl/civil-time.tesl" 386 (list (cons 'n *n)) (lambda () (+ 1 (raw-value (mod7 (+ *n 3)))))))

(define/pow
  (rawIsLeapYear [y : Integer])
  #:returns Boolean
  (thsl-src! "tesl/civil-time.tesl" 389 (list (cons 'y *y)) (lambda () (and (tesl-equal? (remainder *y 4) 0) (or (not (tesl-equal? (remainder *y 100) 0)) (tesl-equal? (remainder *y 400) 0))))))

(define/pow
  (rawDaysInMonth [y : Integer] [m : Month])
  #:returns Integer
  (thsl-src-control! "tesl/civil-time.tesl" 392 (list (cons 'y *y) (cons 'm *m)) (lambda () (let ([tesl-case-4 *m]) (cond [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'January)) (thsl-src! "tesl/civil-time.tesl" 393 (list) (lambda () (raw-value 31)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'February)) (thsl-src! "tesl/civil-time.tesl" 395 (list) (lambda () (if (rawIsLeapYear y) (raw-value 29) (raw-value 28))))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'March)) (thsl-src! "tesl/civil-time.tesl" 399 (list) (lambda () (raw-value 31)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'April)) (thsl-src! "tesl/civil-time.tesl" 400 (list) (lambda () (raw-value 30)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'May)) (thsl-src! "tesl/civil-time.tesl" 401 (list) (lambda () (raw-value 31)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'June)) (thsl-src! "tesl/civil-time.tesl" 402 (list) (lambda () (raw-value 30)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'July)) (thsl-src! "tesl/civil-time.tesl" 403 (list) (lambda () (raw-value 31)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'August)) (thsl-src! "tesl/civil-time.tesl" 404 (list) (lambda () (raw-value 31)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'September)) (thsl-src! "tesl/civil-time.tesl" 405 (list) (lambda () (raw-value 30)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'October)) (thsl-src! "tesl/civil-time.tesl" 406 (list) (lambda () (raw-value 31)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'November)) (thsl-src! "tesl/civil-time.tesl" 407 (list) (lambda () (raw-value 30)))] [(and (adt-value? *tesl-case-4) (eq? (adt-value-variant *tesl-case-4) 'December)) (thsl-src! "tesl/civil-time.tesl" 408 (list) (lambda () (raw-value 31)))])))))

(define/pow
  (fromDayNumber [z : TimeZone] [n : Integer])
  #:returns CivilDate
  (thsl-src! "tesl/civil-time.tesl" 415 (list (cons 'z *z) (cons 'n *n)) (lambda () (raw-value (Civil *n *z)))))

(define/pow
  (fromParts [z : TimeZone] [y : Integer] [m : Month] [d : Integer])
  #:returns (Maybe CivilDate)
  (thsl-src! "tesl/civil-time.tesl" 421 (list (cons 'z *z) (cons 'y *y) (cons 'm *m) (cons 'd *d)) (lambda () (if (and (tesl-ge? *d 1) (tesl-le? *d (raw-value (rawDaysInMonth y m)))) (raw-value (raw-value (Something (Civil (dayFromYmd y (rawMonthNumberOf m) d) z)))) (raw-value Nothing)))))

(define/pow
  (fromChecked [z : TimeZone] [y : Integer] [m : Month] [d : Integer ::: (DayOfMonth y m d)])
  #:returns CivilDate
  (thsl-src! "tesl/civil-time.tesl" 429 (list (cons 'z *z) (cons 'y *y) (cons 'm *m) (cons 'd *d)) (lambda () (raw-value (Civil (dayFromYmd y (rawMonthNumberOf m) d) *z)))))

(define/pow
  (posixToMs [ts : PosixMillis])
  #:returns Integer
  (thsl-src! "tesl/civil-time.tesl" 434 (list (cons 'ts *ts)) (lambda () (diffMs (raw-value (tesl_import_Time_secondsToPosix 0)) *ts))))

(define/pow
  (fromInstant [z : TimeZone] [ts : PosixMillis])
  #:returns CivilDate
  (let ([localMs (thsl-src! "tesl/civil-time.tesl" 437 (list (cons 'z *z) (cons 'ts *ts)) (lambda () (+ (raw-value (posixToMs ts)) (* (raw-value (tesl_import_Time_offsetAt *z *ts)) 60000))))]) (thsl-src! "tesl/civil-time.tesl" 438 (list (cons 'localMs *localMs) (cons 'z *z) (cons 'ts *ts)) (lambda () (raw-value (Civil (floorDivDay localMs) *z))))))

(define/pow
  (msToPosix [ms : Integer])
  #:returns PosixMillis
  (thsl-src! "tesl/civil-time.tesl" 446 (list (cons 'ms *ms)) (lambda () (addMs (raw-value (tesl_import_Time_secondsToPosix 0)) *ms))))

(define/pow
  (startOfDay [d : CivilDate])
  #:returns PosixMillis
  (let ([z (thsl-src! "tesl/civil-time.tesl" 454 (list (cons 'd *d)) (lambda () (zone d)))]) (let ([localMs (thsl-src! "tesl/civil-time.tesl" 455 (list (cons 'z *z) (cons 'd *d)) (lambda () (* (raw-value (dayNumber d)) 86400000)))]) (let ([off1 (thsl-src! "tesl/civil-time.tesl" 456 (list (cons 'localMs *localMs) (cons 'z *z) (cons 'd *d)) (lambda () (raw-value (tesl_import_Time_offsetAt (raw-value z) (raw-value (msToPosix localMs))))))]) (let ([off2 (thsl-src! "tesl/civil-time.tesl" 457 (list (cons 'off1 *off1) (cons 'localMs *localMs) (cons 'z *z) (cons 'd *d)) (lambda () (raw-value (tesl_import_Time_offsetAt (raw-value z) (raw-value (msToPosix (- (raw-value localMs) (* (raw-value off1) 60000))))))))]) (let ([off3 (thsl-src! "tesl/civil-time.tesl" 458 (list (cons 'off2 *off2) (cons 'off1 *off1) (cons 'localMs *localMs) (cons 'z *z) (cons 'd *d)) (lambda () (raw-value (tesl_import_Time_offsetAt (raw-value z) (raw-value (msToPosix (- (raw-value localMs) (* (raw-value off2) 60000))))))))]) (thsl-src! "tesl/civil-time.tesl" 459 (list (cons 'off3 *off3) (cons 'off2 *off2) (cons 'off1 *off1) (cons 'localMs *localMs) (cons 'z *z) (cons 'd *d)) (lambda () (raw-value (msToPosix (- (raw-value localMs) (* (raw-value off3) 60000))))))))))))

(define/pow
  (endOfDay [d : CivilDate])
  #:returns PosixMillis
  (thsl-src! "tesl/civil-time.tesl" 466 (list (cons 'd *d)) (lambda () (raw-value (startOfDay (addDays d 1))))))

(define/pow
  (dayNumber [d : CivilDate])
  #:returns Integer
  (thsl-src-control! "tesl/civil-time.tesl" 471 (list (cons 'd *d)) (lambda () (let ([tesl-case-5 *d]) (cond [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Civil)) (let ([n (hash-ref (adt-value-fields *tesl-case-5) 'value)]) (thsl-src! "tesl/civil-time.tesl" 472 (list (cons 'n n)) (lambda () *n)))])))))

(define/pow
  (zone [d : CivilDate])
  #:returns TimeZone
  (thsl-src-control! "tesl/civil-time.tesl" 475 (list (cons 'd *d)) (lambda () (let ([tesl-case-6 *d]) (cond [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Civil)) (let ([z (hash-ref (adt-value-fields *tesl-case-6) 'value2)]) (thsl-src! "tesl/civil-time.tesl" 476 (list (cons 'z z)) (lambda () *z)))])))))

(define/pow
  (year [d : CivilDate])
  #:returns Integer
  (thsl-src! "tesl/civil-time.tesl" 479 (list (cons 'd *d)) (lambda () (raw-value (rawYear (dayNumber d))))))

(define/pow
  (month [d : CivilDate])
  #:returns Month
  (thsl-src! "tesl/civil-time.tesl" 482 (list (cons 'd *d)) (lambda () (raw-value (monthOfNumber (rawMonthNumber (dayNumber d)))))))

(define/pow
  (day [d : CivilDate])
  #:returns (? Integer _entity ::: (IsDayOfMonth _entity))
  (thsl-src! "tesl/civil-time.tesl" 487 (list (cons 'd *d)) (lambda () (asDayOfMonth (rawDayOfMonth (dayNumber d))))))

(define/pow
  (weekday [d : CivilDate])
  #:returns Weekday
  (thsl-src! "tesl/civil-time.tesl" 490 (list (cons 'd *d)) (lambda () (raw-value (weekdayOfNumber (rawWeekdayOfDay (dayNumber d)))))))

(define/pow
  (dayOfYear [d : CivilDate])
  #:returns (? Integer _entity ::: (IsDayOfYear _entity))
  (thsl-src! "tesl/civil-time.tesl" 493 (list (cons 'd *d)) (lambda () (asDayOfYear (+ (- (raw-value (dayNumber d)) (raw-value (dayFromYmd (year d) 1 1))) 1)))))

(define/pow
  (monthNumber [m : Month])
  #:returns (? Integer _entity ::: (IsMonthNumber _entity))
  (thsl-src! "tesl/civil-time.tesl" 496 (list (cons 'm *m)) (lambda () (asMonthNumber (rawMonthNumberOf m)))))

(define/pow
  (monthFromNumber [n : Integer])
  #:returns (Maybe Month)
  (thsl-src! "tesl/civil-time.tesl" 499 (list (cons 'n *n)) (lambda () (if (and (tesl-ge? *n 1) (tesl-le? *n 12)) (raw-value (raw-value (Something (monthOfNumber n)))) (raw-value Nothing)))))

(define/pow
  (weekdayNumber [w : Weekday])
  #:returns (? Integer _entity ::: (IsWeekdayNumber _entity))
  (thsl-src! "tesl/civil-time.tesl" 505 (list (cons 'w *w)) (lambda () (asWeekdayNumber (rawWeekdayNumberOf w)))))

(define/pow
  (isoThursday [n : Integer])
  #:returns Integer
  (thsl-src! "tesl/civil-time.tesl" 514 (list (cons 'n *n)) (lambda () (- (+ *n 4) (raw-value (rawWeekdayOfDay n))))))

(define/pow
  (rawWeekYear [n : Integer])
  #:returns Integer
  (thsl-src! "tesl/civil-time.tesl" 517 (list (cons 'n *n)) (lambda () (raw-value (rawYear (isoThursday n))))))

(define/pow
  (firstThursdayOf [y : Integer])
  #:returns Integer
  (let ([jan1 (thsl-src! "tesl/civil-time.tesl" 520 (list (cons 'y *y)) (lambda () (dayFromYmd y 1 1)))]) (thsl-src! "tesl/civil-time.tesl" 521 (list (cons 'jan1 *jan1) (cons 'y *y)) (lambda () (+ (raw-value jan1) (raw-value (mod7 (- 4 (raw-value (rawWeekdayOfDay jan1))))))))))

(define/pow
  (rawWeekNumber [n : Integer])
  #:returns Integer
  (thsl-src! "tesl/civil-time.tesl" 524 (list (cons 'n *n)) (lambda () (+ (quotient (- (raw-value (isoThursday n)) (raw-value (firstThursdayOf (rawWeekYear n)))) 7) 1))))

(define/pow
  (isoWeekOf [d : CivilDate])
  #:returns IsoWeek
  (let ([n (thsl-src! "tesl/civil-time.tesl" 527 (list (cons 'd *d)) (lambda () (dayNumber d)))]) (thsl-src! "tesl/civil-time.tesl" 528 (list (cons 'n *n) (cons 'd *d)) (lambda () (raw-value (Week (rawWeekYear n) (rawWeekNumber n)))))))

(define/pow
  (weeksInYear [y : Integer])
  #:returns Integer
  (thsl-src! "tesl/civil-time.tesl" 533 (list (cons 'y *y)) (lambda () (raw-value (rawWeekNumber (dayFromYmd y 12 28))))))

(define/pow
  (isoWeek [y : Integer] [w : Integer])
  #:returns (Maybe IsoWeek)
  (thsl-src! "tesl/civil-time.tesl" 536 (list (cons 'y *y) (cons 'w *w)) (lambda () (if (and (tesl-ge? *w 1) (tesl-le? *w (raw-value (weeksInYear y)))) (raw-value (raw-value (Something (Week y w)))) (raw-value Nothing)))))

(define/pow
  (weekYear [w : IsoWeek])
  #:returns Integer
  (thsl-src-control! "tesl/civil-time.tesl" 542 (list (cons 'w *w)) (lambda () (let ([tesl-case-7 *w]) (cond [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Week)) (let ([y (hash-ref (adt-value-fields *tesl-case-7) 'value)]) (thsl-src! "tesl/civil-time.tesl" 543 (list (cons 'y y)) (lambda () *y)))])))))

(define/pow
  (weekNumber [w : IsoWeek])
  #:returns (? Integer _entity ::: (IsWeekNumber _entity))
  (thsl-src! "tesl/civil-time.tesl" 546 (list (cons 'w *w)) (lambda () (asWeekNumber (rawWeekNumberOf w)))))

(define/pow
  (rawWeekNumberOf [w : IsoWeek])
  #:returns Integer
  (thsl-src-control! "tesl/civil-time.tesl" 549 (list (cons 'w *w)) (lambda () (let ([tesl-case-8 *w]) (cond [(and (adt-value? *tesl-case-8) (eq? (adt-value-variant *tesl-case-8) 'Week)) (let ([n (hash-ref (adt-value-fields *tesl-case-8) 'value2)]) (thsl-src! "tesl/civil-time.tesl" 550 (list (cons 'n n)) (lambda () *n)))])))))

(define/pow
  (addDays [d : CivilDate] [n : Integer])
  #:returns CivilDate
  (thsl-src! "tesl/civil-time.tesl" 556 (list (cons 'd *d) (cons 'n *n)) (lambda () (raw-value (Civil (+ (raw-value (dayNumber d)) *n) (zone d))))))

(define/pow
  (diffDays [a : CivilDate] [b : CivilDate ::: (SameCalendar a b)])
  #:returns Integer
  (thsl-src! "tesl/civil-time.tesl" 562 (list (cons 'a *a) (cons 'b *b)) (lambda () (- (raw-value (dayNumber a)) (raw-value (dayNumber b))))))

(define/pow
  (isBefore [a : CivilDate] [b : CivilDate ::: (SameCalendar a b)])
  #:returns Boolean
  (thsl-src! "tesl/civil-time.tesl" 565 (list (cons 'a *a) (cons 'b *b)) (lambda () (tesl-lt? (raw-value (dayNumber a)) (raw-value (dayNumber b))))))

(define/pow
  (addMonths [d : CivilDate] [n : Integer])
  #:returns CivilDate
  (let ([months (thsl-src! "tesl/civil-time.tesl" 572 (list (cons 'd *d) (cons 'n *n)) (lambda () (+ (- (+ (* (raw-value (year d)) 12) (raw-value (rawMonthNumber (dayNumber d)))) 1) *n)))]) (let ([newYear (thsl-src! "tesl/civil-time.tesl" 573 (list (cons 'months *months) (cons 'd *d) (cons 'n *n)) (lambda () (quotient (raw-value months) 12)))]) (let ([newMonthNo (thsl-src! "tesl/civil-time.tesl" 574 (list (cons 'newYear *newYear) (cons 'months *months) (cons 'd *d) (cons 'n *n)) (lambda () (+ (- (raw-value months) (* (raw-value newYear) 12)) 1)))]) (let ([newMonth (thsl-src! "tesl/civil-time.tesl" 575 (list (cons 'newMonthNo *newMonthNo) (cons 'newYear *newYear) (cons 'months *months) (cons 'd *d) (cons 'n *n)) (lambda () (monthOfNumber newMonthNo)))]) (let ([currentDay (thsl-src! "tesl/civil-time.tesl" 576 (list (cons 'newMonth *newMonth) (cons 'newMonthNo *newMonthNo) (cons 'newYear *newYear) (cons 'months *months) (cons 'd *d) (cons 'n *n)) (lambda () (rawDayOfMonth (dayNumber d))))]) (let ([lastInTarget (thsl-src! "tesl/civil-time.tesl" 577 (list (cons 'currentDay *currentDay) (cons 'newMonth *newMonth) (cons 'newMonthNo *newMonthNo) (cons 'newYear *newYear) (cons 'months *months) (cons 'd *d) (cons 'n *n)) (lambda () (rawDaysInMonth newYear newMonth)))]) (let ([clamped (thsl-src! "tesl/civil-time.tesl" 578 (list (cons 'lastInTarget *lastInTarget) (cons 'currentDay *currentDay) (cons 'newMonth *newMonth) (cons 'newMonthNo *newMonthNo) (cons 'newYear *newYear) (cons 'months *months) (cons 'd *d) (cons 'n *n)) (lambda () (if (tesl-le? (raw-value currentDay) (raw-value lastInTarget)) currentDay lastInTarget)))]) (thsl-src! "tesl/civil-time.tesl" 582 (list (cons 'clamped *clamped) (cons 'lastInTarget *lastInTarget) (cons 'currentDay *currentDay) (cons 'newMonth *newMonth) (cons 'newMonthNo *newMonthNo) (cons 'newYear *newYear) (cons 'months *months) (cons 'd *d) (cons 'n *n)) (lambda () (raw-value (Civil (dayFromYmd newYear newMonthNo clamped) (zone d)))))))))))))

(define/pow
  (startOfMonth [d : CivilDate])
  #:returns CivilDate
  (thsl-src! "tesl/civil-time.tesl" 585 (list (cons 'd *d)) (lambda () (raw-value (Civil (dayFromYmd (year d) (rawMonthNumber (dayNumber d)) 1) (zone d))))))

(define/pow
  (endOfMonth [d : CivilDate])
  #:returns CivilDate
  (let ([lastDay (thsl-src! "tesl/civil-time.tesl" 588 (list (cons 'd *d)) (lambda () (rawDaysInMonth (year d) (month d))))]) (thsl-src! "tesl/civil-time.tesl" 589 (list (cons 'lastDay *lastDay) (cons 'd *d)) (lambda () (raw-value (Civil (dayFromYmd (year d) (rawMonthNumber (dayNumber d)) lastDay) (zone d)))))))

(define/pow
  (startOfWeek [d : CivilDate])
  #:returns CivilDate
  (thsl-src! "tesl/civil-time.tesl" 593 (list (cons 'd *d)) (lambda () (raw-value (addDays d (- 1 (raw-value (rawWeekdayOfDay (dayNumber d)))))))))

(define/pow
  (startOfYear [d : CivilDate])
  #:returns CivilDate
  (thsl-src! "tesl/civil-time.tesl" 596 (list (cons 'd *d)) (lambda () (raw-value (Civil (dayFromYmd (year d) 1 1) (zone d))))))

(define/pow
  (daysInMonth [y : Integer] [m : Month])
  #:returns (? Integer _entity ::: (IsMonthLength _entity))
  (thsl-src! "tesl/civil-time.tesl" 599 (list (cons 'y *y) (cons 'm *m)) (lambda () (asMonthLength (rawDaysInMonth y m)))))

(define/pow
  (isLeapYear [y : Integer])
  #:returns Boolean
  (thsl-src! "tesl/civil-time.tesl" 602 (list (cons 'y *y)) (lambda () (raw-value (rawIsLeapYear y)))))

(define/pow
  (datesBetween [a : CivilDate] [b : CivilDate ::: (SameCalendar a b)])
  #:returns (List CivilDate)
  (let ([span (thsl-src! "tesl/civil-time.tesl" 607 (list (cons 'a *a) (cons 'b *b)) (lambda () (- (raw-value (dayNumber b)) (raw-value (dayNumber a)))))]) (thsl-src! "tesl/civil-time.tesl" 608 (list (cons 'span *span) (cons 'a *a) (cons 'b *b)) (lambda () (if (tesl-le? (raw-value span) 0) (raw-value (list)) (raw-value (tesl_import_List_map (let () (define/pow (tesl-lambda-9 [i : Integer]) #:returns Any (addDays a i)) tesl-lambda-9) (raw-value (tesl_import_List_range 0 (raw-value span))))))))))

(define/pow
  (pad [n : Integer] [width : Integer])
  #:returns String
  (thsl-src! "tesl/civil-time.tesl" 621 (list (cons 'n *n) (cons 'width *width)) (lambda () (raw-value (tesl_import_String_padLeft (raw-value (tesl_import_String_fromInt *n)) *width "0")))))

(define/pow
  (toIso [d : CivilDate])
  #:returns String
  (let ([ymd (thsl-src! "tesl/civil-time.tesl" 624 (list (cons 'd *d)) (lambda () (list (pad (year d) 4) (pad (rawMonthNumber (dayNumber d)) 2) (pad (rawDayOfMonth (dayNumber d)) 2))))]) (thsl-src! "tesl/civil-time.tesl" 625 (list (cons 'ymd *ymd) (cons 'd *d)) (lambda () (raw-value (tesl_import_String_join (raw-value ymd) "-"))))))

(define/pow
  (fromIso [z : TimeZone] [s : String])
  #:returns (Maybe CivilDate)
  (thsl-src! "tesl/civil-time.tesl" 630 (list (cons 'z *z) (cons 's *s)) (lambda () (if (and (tesl-equal? (raw-value (tesl_import_String_length *s)) 10) (tesl-equal? (raw-value (tesl_import_String_slice *s 4 5)) "-") (tesl-equal? (raw-value (tesl_import_String_slice *s 7 8)) "-")) (raw-value (fromIsoParts z (tesl_import_String_toInt (raw-value (tesl_import_String_slice *s 0 4))) (tesl_import_String_toInt (raw-value (tesl_import_String_slice *s 5 7))) (tesl_import_String_toInt (raw-value (tesl_import_String_slice *s 8 10))))) (raw-value Nothing)))))

(define/pow
  (fromIsoParts [z : TimeZone] [y : (Maybe Integer)] [m : (Maybe Integer)] [d : (Maybe Integer)])
  #:returns (Maybe CivilDate)
  (thsl-src-control! "tesl/civil-time.tesl" 636 (list (cons 'z *z) (cons 'y *y) (cons 'm *m) (cons 'd *d)) (lambda () (let ([tesl-case-10 *y]) (cond [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Nothing)) (thsl-src! "tesl/civil-time.tesl" 637 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-10) (eq? (adt-value-variant *tesl-case-10) 'Something)) (let ([yv (hash-ref (adt-value-fields *tesl-case-10) 'value)]) (thsl-src! "tesl/civil-time.tesl" 639 (list (cons 'yv yv)) (lambda () (let ([tesl-case-11 *m]) (cond [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Nothing)) (thsl-src! "tesl/civil-time.tesl" 640 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-11) (eq? (adt-value-variant *tesl-case-11) 'Something)) (let ([mv (hash-ref (adt-value-fields *tesl-case-11) 'value)]) (thsl-src! "tesl/civil-time.tesl" 642 (list (cons 'mv mv)) (lambda () (let ([tesl-case-12 *d]) (cond [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Nothing)) (thsl-src! "tesl/civil-time.tesl" 643 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Something)) (let ([dv (hash-ref (adt-value-fields *tesl-case-12) 'value)]) (thsl-src! "tesl/civil-time.tesl" 645 (list (cons 'dv dv)) (lambda () (let ([tesl-case-13 (raw-value (monthFromNumber *mv))]) (cond [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Nothing)) (thsl-src! "tesl/civil-time.tesl" 646 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Something)) (let ([month_ (hash-ref (adt-value-fields *tesl-case-13) 'value)]) (thsl-src! "tesl/civil-time.tesl" 647 (list (cons 'month_ month_)) (lambda () (raw-value (fromParts z *yv *month_ *dv)))))])))))])))))])))))])))))

(define/pow
  (isoWeekLabel [w : IsoWeek])
  #:returns String
  (thsl-src! "tesl/civil-time.tesl" 652 (list (cons 'w *w)) (lambda () (raw-value (tesl_import_String_concat (raw-value (pad (weekYear w) 4)) (raw-value (tesl_import_String_concat "-W" (raw-value (pad (rawWeekNumberOf w) 2)))))))))
