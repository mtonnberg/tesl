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
  (prefix-in __ttz_ (only-in tesl/tesl/time tesl-tz-utc tesl-tz-fixed tesl-tz-named))
  (only-in tesl/tesl/prelude Bool Int String List)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/list [List.length tesl_import_List_length] [List.map tesl_import_List_map])
  (only-in tesl/tesl/time PosixMillis TimeZone [Time.secondsToPosix tesl_import_Time_secondsToPosix] [Time.truncDay tesl_import_Time_truncDay] [Time.posixToSeconds tesl_import_Time_posixToSeconds] [Time.offsetAt tesl_import_Time_offsetAt] addMs diffMs)
  (only-in tesl/tesl/civil-time CivilDate IsoWeek Month January February March April May June July August September October November December Weekday Monday Tuesday Wednesday Thursday Friday Saturday Sunday IsDayOfMonth [CivilTime.fromParts tesl_import_CivilTime_fromParts] [CivilTime.fromDayNumber tesl_import_CivilTime_fromDayNumber] [CivilTime.fromInstant tesl_import_CivilTime_fromInstant] [CivilTime.fromIso tesl_import_CivilTime_fromIso] [CivilTime.startOfDay tesl_import_CivilTime_startOfDay] [CivilTime.endOfDay tesl_import_CivilTime_endOfDay] [CivilTime.dayNumber tesl_import_CivilTime_dayNumber] [CivilTime.year tesl_import_CivilTime_year] [CivilTime.month tesl_import_CivilTime_month] [CivilTime.day tesl_import_CivilTime_day] [CivilTime.weekday tesl_import_CivilTime_weekday] [CivilTime.dayOfYear tesl_import_CivilTime_dayOfYear] [CivilTime.monthNumber tesl_import_CivilTime_monthNumber] [CivilTime.weekdayNumber tesl_import_CivilTime_weekdayNumber] [CivilTime.isoWeekOf tesl_import_CivilTime_isoWeekOf] [CivilTime.weekYear tesl_import_CivilTime_weekYear] [CivilTime.weekNumber tesl_import_CivilTime_weekNumber] [CivilTime.isoWeekLabel tesl_import_CivilTime_isoWeekLabel] [CivilTime.addDays tesl_import_CivilTime_addDays] [CivilTime.diffDays tesl_import_CivilTime_diffDays] [CivilTime.addMonths tesl_import_CivilTime_addMonths] [CivilTime.startOfMonth tesl_import_CivilTime_startOfMonth] [CivilTime.endOfMonth tesl_import_CivilTime_endOfMonth] [CivilTime.startOfWeek tesl_import_CivilTime_startOfWeek] [CivilTime.daysInMonth tesl_import_CivilTime_daysInMonth] [CivilTime.isLeapYear tesl_import_CivilTime_isLeapYear] [CivilTime.datesBetween tesl_import_CivilTime_datesBetween] [CivilTime.toIso tesl_import_CivilTime_toIso] [CivilTime.sameCalendar tesl_import_CivilTime_sameCalendar])
)


(provide )

(define/pow
  (dateOf [y : Integer] [m : Month] [d : Integer])
  #:returns CivilDate
  (thsl-src-control! "tests/civil-time-tests.tesl" 59 (list (cons 'y *y) (cons 'm *m) (cons 'd *d)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_CivilTime_fromParts (__ttz_tesl-tz-utc) *y *m *d))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([cd (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/civil-time-tests.tesl" 60 (list (cons 'cd cd)) (lambda () *cd)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/civil-time-tests.tesl" 61 (list) (lambda () (raw-value (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-utc) 0)))))])))))

(define/pow
  (isoOf [y : Integer] [m : Month] [d : Integer])
  #:returns String
  (thsl-src! "tests/civil-time-tests.tesl" 64 (list (cons 'y *y) (cons 'm *m) (cons 'd *d)) (lambda () (raw-value (tesl_import_CivilTime_toIso (raw-value (dateOf y m d)))))))

(define/pow
  (dayNumOf [y : Integer] [m : Month] [d : Integer])
  #:returns Integer
  (thsl-src! "tests/civil-time-tests.tesl" 67 (list (cons 'y *y) (cons 'm *m) (cons 'd *d)) (lambda () (raw-value (tesl_import_CivilTime_dayNumber (raw-value (dateOf y m d)))))))

(define/pow
  (weekLabelOf [y : Integer] [m : Month] [d : Integer])
  #:returns String
  (thsl-src! "tests/civil-time-tests.tesl" 70 (list (cons 'y *y) (cons 'm *m) (cons 'd *d)) (lambda () (raw-value (tesl_import_CivilTime_isoWeekLabel (raw-value (tesl_import_CivilTime_isoWeekOf (raw-value (dateOf y m d)))))))))

(define/pow
  (needsDayOfMonth [n : Integer ::: (IsDayOfMonth n)])
  #:returns Integer
  (thsl-src! "tests/civil-time-tests.tesl" 73 (list (cons 'n *n)) (lambda () *n)))

(define/pow
  (isoRoundTrip [n : Integer])
  #:returns String
  (thsl-src-control! "tests/civil-time-tests.tesl" 256 (list (cons 'n *n)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_CivilTime_fromIso (__ttz_tesl-tz-utc) (raw-value (tesl_import_CivilTime_toIso (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-utc) *n))))))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([d (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "tests/civil-time-tests.tesl" 257 (list (cons 'd d)) (lambda () (raw-value (raw-value (tesl_import_CivilTime_toIso *d))))))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "tests/civil-time-tests.tesl" 258 (list) (lambda () (raw-value "unparsable")))])))))

(define/pow
  (weekInRange [n : Integer])
  #:returns Boolean
  (let ([w (thsl-src! "tests/civil-time-tests.tesl" 267 (list (cons 'n *n)) (lambda () (raw-value (tesl_import_CivilTime_weekNumber (raw-value (tesl_import_CivilTime_isoWeekOf (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-utc) *n))))))))]) (thsl-src! "tests/civil-time-tests.tesl" 268 (list (cons 'w *w) (cons 'n *n)) (lambda () (and (tesl-ge? (raw-value w) 1) (tesl-le? (raw-value w) 53))))))

(define/pow
  (doyInRange [n : Integer])
  #:returns Boolean
  (let ([doy (thsl-src! "tests/civil-time-tests.tesl" 271 (list (cons 'n *n)) (lambda () (raw-value (tesl_import_CivilTime_dayOfYear (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-utc) *n))))))]) (thsl-src! "tests/civil-time-tests.tesl" 272 (list (cons 'doy *doy) (cons 'n *n)) (lambda () (and (tesl-ge? (raw-value doy) 1) (tesl-le? (raw-value doy) 366))))))

(define/pow
  (addDiffInverse [k : Integer])
  #:returns Boolean
  (thsl-src! "tests/civil-time-tests.tesl" 281 (list (cons 'k *k)) (lambda () (let ([a (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-utc) 20000))]) (let ([b (raw-value (tesl_import_CivilTime_addDays (raw-value a) *k))]) (let/check ([tesl-checked-2 (tesl_import_CivilTime_sameCalendar b a)]) (let ([aa tesl-checked-2]) (tesl-equal? (raw-value (tesl_import_CivilTime_diffDays (raw-value b) aa)) *k))))))))

(define/pow
  (stockholmDay [y : Integer] [m : Month] [d : Integer])
  #:returns CivilDate
  (thsl-src-control! "tests/civil-time-tests.tesl" 292 (list (cons 'y *y) (cons 'm *m) (cons 'd *d)) (lambda () (let ([tesl-case-3 (raw-value (tesl_import_CivilTime_fromParts (__ttz_tesl-tz-named "Europe/Stockholm") *y *m *d))]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([cd (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "tests/civil-time-tests.tesl" 293 (list (cons 'cd cd)) (lambda () *cd)))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "tests/civil-time-tests.tesl" 294 (list) (lambda () (raw-value (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-named "Europe/Stockholm") 0)))))])))))

(define/pow
  (dayLengthSeconds [d : CivilDate])
  #:returns Integer
  (thsl-src! "tests/civil-time-tests.tesl" 297 (list (cons 'd *d)) (lambda () (- (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_CivilTime_endOfDay *d)))) (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_CivilTime_startOfDay *d))))))))

(define/pow
  (diffAcrossZones)
  #:returns Integer
  (thsl-src! "tests/civil-time-tests.tesl" 332 (list) (lambda () (let ([inUtc (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-utc) 20000))]) (let ([inStockholm (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-named "Europe/Stockholm") 20000))]) (let/check ([tesl-checked-4 (tesl_import_CivilTime_sameCalendar inUtc inStockholm)]) (let ([bad tesl-checked-4]) (raw-value (tesl_import_CivilTime_diffDays (raw-value inUtc) bad)))))))))

(module+ test
  (require rackunit)
  (test-case "the epoch is day 0 = 1970-01-01"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 76 (list) (lambda () (dayNumOf 1970 January 1)))) 0)
  (define d (thsl-src! "tests/civil-time-tests.tesl" 77 (list) (lambda () (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-utc) 0)))))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 78 (list (cons 'd d)) (lambda () (raw-value (tesl_import_CivilTime_year (raw-value d)))))) 1970)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 79 (list (cons 'd d)) (lambda () (raw-value (tesl_import_CivilTime_monthNumber (raw-value (tesl_import_CivilTime_month (raw-value d)))))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 80 (list (cons 'd d)) (lambda () (raw-value (tesl_import_CivilTime_day (raw-value d)))))) 1)
    ))
  )

  (test-case "known dates round-trip through the day number"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 84 (list) (lambda () (dayNumOf 2021 January 1)))) 18628)
  (define d (thsl-src! "tests/civil-time-tests.tesl" 85 (list) (lambda () (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-utc) 18628)))))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 86 (list (cons 'd d)) (lambda () (raw-value (tesl_import_CivilTime_year (raw-value d)))))) 2021)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 87 (list (cons 'd d)) (lambda () (raw-value (tesl_import_CivilTime_monthNumber (raw-value (tesl_import_CivilTime_month (raw-value d)))))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 88 (list (cons 'd d)) (lambda () (raw-value (tesl_import_CivilTime_day (raw-value d)))))) 1)
  (define e (thsl-src! "tests/civil-time-tests.tesl" 89 (list (cons 'd d)) (lambda () (dateOf 2023 November 14))))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 90 (list (cons 'e e) (cons 'd d)) (lambda () (raw-value (tesl_import_CivilTime_year (raw-value e)))))) 2023)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 91 (list (cons 'e e) (cons 'd d)) (lambda () (raw-value (tesl_import_CivilTime_monthNumber (raw-value (tesl_import_CivilTime_month (raw-value e)))))))) 11)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 92 (list (cons 'e e) (cons 'd d)) (lambda () (raw-value (tesl_import_CivilTime_day (raw-value e)))))) 14)
    ))
  )

  (test-case "dates before the epoch are ordinary negative day numbers"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 96 (list) (lambda () (dayNumOf 1900 January 1)))) (- 0 25567))
  (define d (thsl-src! "tests/civil-time-tests.tesl" 97 (list) (lambda () (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-utc) (- 0 25567))))))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 98 (list (cons 'd d)) (lambda () (raw-value (tesl_import_CivilTime_year (raw-value d)))))) 1900)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 99 (list (cons 'd d)) (lambda () (raw-value (tesl_import_CivilTime_monthNumber (raw-value (tesl_import_CivilTime_month (raw-value d)))))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 100 (list (cons 'd d)) (lambda () (raw-value (tesl_import_CivilTime_day (raw-value d)))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 101 (list (cons 'd d)) (lambda () (isoOf 1900 February 28)))) "1900-02-28")
    ))
  )

  (test-case "leap years: 29 February exists in 2020 and the next day is 1 March"
    (call-with-fresh-memory-db '() (lambda ()
  (define feb29 (thsl-src! "tests/civil-time-tests.tesl" 105 (list) (lambda () (dateOf 2020 February 29))))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 106 (list (cons 'feb29 feb29)) (lambda () (raw-value (tesl_import_CivilTime_monthNumber (raw-value (tesl_import_CivilTime_month (raw-value feb29)))))))) 2)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 107 (list (cons 'feb29 feb29)) (lambda () (raw-value (tesl_import_CivilTime_day (raw-value feb29)))))) 29)
  (define next (thsl-src! "tests/civil-time-tests.tesl" 108 (list (cons 'feb29 feb29)) (lambda () (raw-value (tesl_import_CivilTime_addDays (raw-value feb29) 1)))))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 109 (list (cons 'next next) (cons 'feb29 feb29)) (lambda () (raw-value (tesl_import_CivilTime_monthNumber (raw-value (tesl_import_CivilTime_month (raw-value next)))))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 110 (list (cons 'next next) (cons 'feb29 feb29)) (lambda () (raw-value (tesl_import_CivilTime_day (raw-value next)))))) 1)
    ))
  )

  (test-case "century rules: 1900 is not a leap year, 2000 is"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 114 (list) (lambda () (raw-value (tesl_import_CivilTime_isLeapYear 1900))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 115 (list) (lambda () (raw-value (tesl_import_CivilTime_isLeapYear 2000))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 116 (list) (lambda () (raw-value (tesl_import_CivilTime_isLeapYear 2024))))) #t)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 117 (list) (lambda () (raw-value (tesl_import_CivilTime_isLeapYear 2026))))) #f)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 118 (list) (lambda () (- (raw-value (dayNumOf 1900 March 1)) (raw-value (dayNumOf 1900 February 28)))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 119 (list) (lambda () (- (raw-value (dayNumOf 2000 March 1)) (raw-value (dayNumOf 2000 February 29)))))) 1)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 120 (list) (lambda () (raw-value (tesl_import_CivilTime_daysInMonth 1900 February))))) 28)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 121 (list) (lambda () (raw-value (tesl_import_CivilTime_daysInMonth 2000 February))))) 29)
    ))
  )

  (test-case "month and year lengths come out right"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 125 (list) (lambda () (- (raw-value (dayNumOf 2026 February 1)) (raw-value (dayNumOf 2026 January 1)))))) 31)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 126 (list) (lambda () (- (raw-value (dayNumOf 2026 March 1)) (raw-value (dayNumOf 2026 February 1)))))) 28)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 127 (list) (lambda () (- (raw-value (dayNumOf 2027 January 1)) (raw-value (dayNumOf 2026 December 1)))))) 31)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 128 (list) (lambda () (- (raw-value (dayNumOf 2027 January 1)) (raw-value (dayNumOf 2026 January 1)))))) 365)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 129 (list) (lambda () (- (raw-value (dayNumOf 2021 January 1)) (raw-value (dayNumOf 2020 January 1)))))) 366)
    ))
  )

  (test-case "a date that does not exist has no value"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([*tesl-case-5 (raw-value 
    (raw-value (tesl_import_CivilTime_fromParts (__ttz_tesl-tz-utc) 2026 February 30)))]) (cond
    [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Something))
      (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 134 (list) (lambda () #f))) #t)
    ]
    [(and (adt-value? *tesl-case-5) (eq? (adt-value-variant *tesl-case-5) 'Nothing))
      (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 135 (list) (lambda () #t))) #t)
    ]
  ))
  (let ([*tesl-case-6 (raw-value 
    (raw-value (tesl_import_CivilTime_fromParts (__ttz_tesl-tz-utc) 2026 April 31)))]) (cond
    [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Something))
      (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 137 (list) (lambda () #f))) #t)
    ]
    [(and (adt-value? *tesl-case-6) (eq? (adt-value-variant *tesl-case-6) 'Nothing))
      (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 138 (list) (lambda () #t))) #t)
    ]
  ))
  (let ([*tesl-case-7 (raw-value 
    (raw-value (tesl_import_CivilTime_fromParts (__ttz_tesl-tz-utc) 2024 February 29)))]) (cond
    [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Something))
      (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 140 (list) (lambda () #t))) #t)
    ]
    [(and (adt-value? *tesl-case-7) (eq? (adt-value-variant *tesl-case-7) 'Nothing))
      (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 141 (list) (lambda () #f))) #t)
    ]
  ))
    ))
  )

  (test-case "weekday and day of year"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 145 (list) (lambda () (raw-value (tesl_import_CivilTime_weekdayNumber (raw-value (tesl_import_CivilTime_weekday (raw-value (dateOf 1970 January 1))))))))) 4)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 146 (list) (lambda () (raw-value (tesl_import_CivilTime_weekdayNumber (raw-value (tesl_import_CivilTime_weekday (raw-value (dateOf 2026 August 5))))))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 147 (list) (lambda () (raw-value (tesl_import_CivilTime_dayOfYear (raw-value (dateOf 2026 December 31))))))) 365)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 148 (list) (lambda () (raw-value (tesl_import_CivilTime_dayOfYear (raw-value (dateOf 2024 December 31))))))) 366)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 149 (list) (lambda () (raw-value (tesl_import_CivilTime_dayOfYear (raw-value (dateOf 2026 January 1))))))) 1)
    ))
  )

  (test-case "ISO week numbering follows the Thursday rule"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 155 (list) (lambda () (weekLabelOf 2026 August 5)))) "2026-W32")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 156 (list) (lambda () (weekLabelOf 2027 January 1)))) "2026-W53")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 157 (list) (lambda () (weekLabelOf 2021 January 1)))) "2020-W53")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 158 (list) (lambda () (weekLabelOf 2020 December 31)))) "2020-W53")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 159 (list) (lambda () (weekLabelOf 2026 January 1)))) "2026-W01")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 160 (list) (lambda () (weekLabelOf 2024 December 30)))) "2025-W01")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 161 (list) (lambda () (weekLabelOf 2004 January 1)))) "2004-W01")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 162 (list) (lambda () (weekLabelOf 2005 January 1)))) "2004-W53")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 163 (list) (lambda () (weekLabelOf 2005 January 3)))) "2005-W01")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 164 (list) (lambda () (weekLabelOf 2006 January 1)))) "2005-W52")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 165 (list) (lambda () (weekLabelOf 2007 December 31)))) "2008-W01")
    ))
  )

  (test-case "the week-year is separate from the calendar year"
    (call-with-fresh-memory-db '() (lambda ()
  (define w (thsl-src! "tests/civil-time-tests.tesl" 169 (list) (lambda () (raw-value (tesl_import_CivilTime_isoWeekOf (raw-value (dateOf 2027 January 1)))))))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 170 (list (cons 'w w)) (lambda () (raw-value (tesl_import_CivilTime_weekYear (raw-value w)))))) 2026)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 171 (list (cons 'w w)) (lambda () (raw-value (tesl_import_CivilTime_weekNumber (raw-value w)))))) 53)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 172 (list (cons 'w w)) (lambda () (raw-value (tesl_import_CivilTime_year (raw-value (dateOf 2027 January 1))))))) 2027)
    ))
  )

  (test-case "addMonths clamps the day of month"
    (call-with-fresh-memory-db '() (lambda ()
  (define jan31 (thsl-src! "tests/civil-time-tests.tesl" 176 (list) (lambda () (dateOf 2026 January 31))))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 177 (list (cons 'jan31 jan31)) (lambda () (raw-value (tesl_import_CivilTime_toIso (raw-value (tesl_import_CivilTime_addMonths (raw-value jan31) 1))))))) "2026-02-28")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 178 (list (cons 'jan31 jan31)) (lambda () (raw-value (tesl_import_CivilTime_toIso (raw-value (tesl_import_CivilTime_addMonths (raw-value (dateOf 2024 January 31)) 1))))))) "2024-02-29")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 179 (list (cons 'jan31 jan31)) (lambda () (raw-value (tesl_import_CivilTime_toIso (raw-value (tesl_import_CivilTime_addMonths (raw-value jan31) 12))))))) "2027-01-31")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 180 (list (cons 'jan31 jan31)) (lambda () (raw-value (tesl_import_CivilTime_toIso (raw-value (tesl_import_CivilTime_addMonths (raw-value jan31) (- 0 1)))))))) "2025-12-31")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 181 (list (cons 'jan31 jan31)) (lambda () (raw-value (tesl_import_CivilTime_toIso (raw-value (tesl_import_CivilTime_addMonths (raw-value (dateOf 2026 March 15)) 0))))))) "2026-03-15")
    ))
  )

  (test-case "month and week boundaries"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 185 (list) (lambda () (raw-value (tesl_import_CivilTime_toIso (raw-value (tesl_import_CivilTime_startOfMonth (raw-value (dateOf 2026 August 5))))))))) "2026-08-01")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 186 (list) (lambda () (raw-value (tesl_import_CivilTime_toIso (raw-value (tesl_import_CivilTime_endOfMonth (raw-value (dateOf 2026 February 5))))))))) "2026-02-28")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 187 (list) (lambda () (raw-value (tesl_import_CivilTime_toIso (raw-value (tesl_import_CivilTime_endOfMonth (raw-value (dateOf 2024 February 5))))))))) "2024-02-29")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 188 (list) (lambda () (raw-value (tesl_import_CivilTime_toIso (raw-value (tesl_import_CivilTime_startOfWeek (raw-value (dateOf 2026 August 5))))))))) "2026-08-03")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 189 (list) (lambda () (raw-value (tesl_import_CivilTime_toIso (raw-value (tesl_import_CivilTime_startOfWeek (raw-value (dateOf 2026 August 3))))))))) "2026-08-03")
    ))
  )

  (test-case "datesBetween is half-open"
    (call-with-fresh-memory-db '() (lambda ()
  (define a (thsl-src! "tests/civil-time-tests.tesl" 193 (list) (lambda () (dateOf 2026 August 1))))
  (define b (thsl-src! "tests/civil-time-tests.tesl" 194 (list (cons 'a a)) (lambda () (dateOf 2026 August 4))))
  (define tesl-checked-8 (tesl_import_CivilTime_sameCalendar a b))
  (when (check-fail? tesl-checked-8)
    (raise-user-error 'tesl-test "unexpected failure in let bb: ~a" (check-fail-message tesl-checked-8)))
  (define bb tesl-checked-8)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 196 (list (cons 'bb bb) (cons 'b b) (cons 'a a)) (lambda () (raw-value (tesl_import_List_length (raw-value (tesl_import_CivilTime_datesBetween (raw-value a) bb))))))) 3)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 197 (list (cons 'bb bb) (cons 'b b) (cons 'a a)) (lambda () (tesl_import_List_map tesl_import_CivilTime_toIso (raw-value (tesl_import_CivilTime_datesBetween (raw-value a) bb)))))) (list "2026-08-01" "2026-08-02" "2026-08-03"))
  (define tesl-checked-9 (tesl_import_CivilTime_sameCalendar a a))
  (when (check-fail? tesl-checked-9)
    (raise-user-error 'tesl-test "unexpected failure in let same: ~a" (check-fail-message tesl-checked-9)))
  (define same tesl-checked-9)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 199 (list (cons 'same same) (cons 'bb bb) (cons 'b b) (cons 'a a)) (lambda () (raw-value (tesl_import_List_length (raw-value (tesl_import_CivilTime_datesBetween (raw-value a) same))))))) 0)
    ))
  )

  (test-case "diffDays counts whole days and needs a shared calendar"
    (call-with-fresh-memory-db '() (lambda ()
  (define a (thsl-src! "tests/civil-time-tests.tesl" 203 (list) (lambda () (dateOf 2026 August 1))))
  (define b (thsl-src! "tests/civil-time-tests.tesl" 204 (list (cons 'a a)) (lambda () (dateOf 2026 August 31))))
  (define tesl-checked-10 (tesl_import_CivilTime_sameCalendar a b))
  (when (check-fail? tesl-checked-10)
    (raise-user-error 'tesl-test "unexpected failure in let bb: ~a" (check-fail-message tesl-checked-10)))
  (define bb tesl-checked-10)
  (define tesl-checked-11 (tesl_import_CivilTime_sameCalendar b a))
  (when (check-fail? tesl-checked-11)
    (raise-user-error 'tesl-test "unexpected failure in let aa: ~a" (check-fail-message tesl-checked-11)))
  (define aa tesl-checked-11)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 207 (list (cons 'aa aa) (cons 'bb bb) (cons 'b b) (cons 'a a)) (lambda () (raw-value (tesl_import_CivilTime_diffDays (raw-value b) aa))))) 30)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 208 (list (cons 'aa aa) (cons 'bb bb) (cons 'b b) (cons 'a a)) (lambda () (raw-value (tesl_import_CivilTime_diffDays (raw-value a) bb))))) (- 0 30))
    ))
  )

  (test-case "ISO strings round-trip without a zone"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 212 (list) (lambda () (isoOf 2026 August 5)))) "2026-08-05")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 213 (list) (lambda () (isoOf 2026 January 1)))) "2026-01-01")
  (let ([*tesl-case-12 (raw-value 
    (raw-value (tesl_import_CivilTime_fromIso (__ttz_tesl-tz-utc) "2026-08-05")))]) (cond
    [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Something))
      (let ([d (hash-ref (adt-value-fields *tesl-case-12) 'value)])
        (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 215 (list) (lambda () (raw-value (tesl_import_CivilTime_toIso (raw-value d)))))) "2026-08-05")
      )
    ]
    [(and (adt-value? *tesl-case-12) (eq? (adt-value-variant *tesl-case-12) 'Nothing))
      (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 216 (list) (lambda () #f))) #t)
    ]
  ))
  (let ([*tesl-case-13 (raw-value 
    (raw-value (tesl_import_CivilTime_fromIso (__ttz_tesl-tz-utc) "2026-02-30")))]) (cond
    [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Something))
      (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 218 (list) (lambda () #f))) #t)
    ]
    [(and (adt-value? *tesl-case-13) (eq? (adt-value-variant *tesl-case-13) 'Nothing))
      (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 219 (list) (lambda () #t))) #t)
    ]
  ))
  (let ([*tesl-case-14 (raw-value 
    (raw-value (tesl_import_CivilTime_fromIso (__ttz_tesl-tz-utc) "2026-8-5")))]) (cond
    [(and (adt-value? *tesl-case-14) (eq? (adt-value-variant *tesl-case-14) 'Something))
      (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 221 (list) (lambda () #f))) #t)
    ]
    [(and (adt-value? *tesl-case-14) (eq? (adt-value-variant *tesl-case-14) 'Nothing))
      (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 222 (list) (lambda () #t))) #t)
    ]
  ))
  (let ([*tesl-case-15 (raw-value 
    (raw-value (tesl_import_CivilTime_fromIso (__ttz_tesl-tz-utc) "not a date")))]) (cond
    [(and (adt-value? *tesl-case-15) (eq? (adt-value-variant *tesl-case-15) 'Something))
      (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 224 (list) (lambda () #f))) #t)
    ]
    [(and (adt-value? *tesl-case-15) (eq? (adt-value-variant *tesl-case-15) 'Nothing))
      (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 225 (list) (lambda () #t))) #t)
    ]
  ))
    ))
  )

  (test-case "an accessor's proof travels with the value"
    (call-with-fresh-memory-db '() (lambda ()
  (define d (thsl-src! "tests/civil-time-tests.tesl" 230 (list) (lambda () (dateOf 2026 August 5))))
  (define dd (thsl-src! "tests/civil-time-tests.tesl" 231 (list (cons 'd d)) (lambda () (raw-value (tesl_import_CivilTime_day (raw-value d))))))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 232 (list (cons 'dd dd) (cons 'd d)) (lambda () (needsDayOfMonth dd)))) 5)
    ))
  )

  (test-case "startOfDay agrees with Time.truncDay in UTC"
    (call-with-fresh-memory-db '() (lambda ()
  (define ts (thsl-src! "tests/civil-time-tests.tesl" 237 (list) (lambda () (raw-value (tesl_import_Time_secondsToPosix 1780000000)))))
  (define d (thsl-src! "tests/civil-time-tests.tesl" 238 (list (cons 'ts ts)) (lambda () (raw-value (tesl_import_CivilTime_fromInstant (__ttz_tesl-tz-utc) (raw-value ts))))))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 239 (list (cons 'd d) (cons 'ts ts)) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_CivilTime_startOfDay (raw-value d)))))))) (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_Time_truncDay (__ttz_tesl-tz-utc) (raw-value ts))))))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 240 (list (cons 'd d) (cons 'ts ts)) (lambda () (- (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_CivilTime_endOfDay (raw-value d))))) (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_CivilTime_startOfDay (raw-value d))))))))) 86400)
    ))
  )

  (test-case "property - the day number round-trips through the calendar parts"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: fromParts (year, month, day) recovers the day number
  (for ([tesl-prop-i (in-range 200)])
    (let ([n (- (tesl-prop-random 2000001) 1000000)])
      (when (and (tesl-gt? (raw-value n) (- 0 40000)) (tesl-lt? (raw-value n) 40000)) (check-true (tesl-equal? (raw-value (tesl_import_CivilTime_dayNumber (raw-value (dateOf (raw-value (tesl_import_CivilTime_year (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-utc) (raw-value n))))) (raw-value (tesl_import_CivilTime_month (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-utc) (raw-value n))))) (raw-value (tesl_import_CivilTime_day (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-utc) (raw-value n))))))))) (raw-value n)) "fromParts (year, month, day) recovers the day number"))
    ))
    ))
  )

  (test-case "property - toIso then fromIso is the identity"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: an ISO string parses back to the same date
  (for ([tesl-prop-i (in-range 200)])
    (let ([n (- (tesl-prop-random 2000001) 1000000)])
      (when (and (tesl-gt? (raw-value n) (- 0 40000)) (tesl-lt? (raw-value n) 40000)) (check-true (tesl-equal? (raw-value (tesl_import_CivilTime_toIso (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-utc) (raw-value n))))) (raw-value (isoRoundTrip n))) "an ISO string parses back to the same date"))
    ))
    ))
  )

  (test-case "property - ISO week and day-of-year stay in range"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: week 1..53 and day-of-year 1..366 for every day number
  (for ([tesl-prop-i (in-range 200)])
    (let ([n (- (tesl-prop-random 2000001) 1000000)])
      (when (and (tesl-gt? (raw-value n) (- 0 40000)) (tesl-lt? (raw-value n) 40000)) (check-true (and (raw-value (weekInRange n)) (raw-value (doyInRange n))) "week 1..53 and day-of-year 1..366 for every day number"))
    ))
    ))
  )

  (test-case "property - addDays and diffDays are inverse"
    (call-with-fresh-memory-db '() (lambda ()
  ; property: diffDays (addDays d k) d == k
  (for ([tesl-prop-i (in-range 200)])
    (let ([k (- (tesl-prop-random 2000001) 1000000)])
      (when (and (tesl-gt? (raw-value k) (- 0 5000)) (tesl-lt? (raw-value k) 5000)) (check-true (addDiffInverse k) "diffDays (addDays d k) d == k"))
    ))
    ))
  )

  (test-case "a civil day in a DST zone is 23 h or 25 h, and the bridge knows it"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 300 (list) (lambda () (dayLengthSeconds (stockholmDay 2026 March 29))))) (* 23 3600))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 301 (list) (lambda () (dayLengthSeconds (stockholmDay 2026 October 25))))) (* 25 3600))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 302 (list) (lambda () (dayLengthSeconds (stockholmDay 2026 August 5))))) (* 24 3600))
    ))
  )

  (test-case "startOfDay is local midnight, and agrees with Time.truncDay"
    (call-with-fresh-memory-db '() (lambda ()
  (define noonAfterSpringForward (thsl-src! "tests/civil-time-tests.tesl" 309 (list) (lambda () (addMs (raw-value (tesl_import_CivilTime_startOfDay (raw-value (stockholmDay 2026 March 29)))) (* 14 3600000)))))
  (define d (thsl-src! "tests/civil-time-tests.tesl" 310 (list (cons 'noonAfterSpringForward noonAfterSpringForward)) (lambda () (raw-value (tesl_import_CivilTime_fromInstant (__ttz_tesl-tz-named "Europe/Stockholm") (raw-value noonAfterSpringForward))))))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 311 (list (cons 'd d) (cons 'noonAfterSpringForward noonAfterSpringForward)) (lambda () (raw-value (tesl_import_CivilTime_toIso (raw-value d)))))) "2026-03-29")
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 312 (list (cons 'd d) (cons 'noonAfterSpringForward noonAfterSpringForward)) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_CivilTime_startOfDay (raw-value d)))))))) (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_Time_truncDay (__ttz_tesl-tz-named "Europe/Stockholm") (raw-value noonAfterSpringForward))))))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 313 (list (cons 'd d) (cons 'noonAfterSpringForward noonAfterSpringForward)) (lambda () (raw-value (tesl_import_Time_offsetAt (__ttz_tesl-tz-named "Europe/Stockholm") (raw-value (tesl_import_CivilTime_startOfDay (raw-value d)))))))) 60)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 314 (list (cons 'd d) (cons 'noonAfterSpringForward noonAfterSpringForward)) (lambda () (raw-value (tesl_import_Time_offsetAt (__ttz_tesl-tz-named "Europe/Stockholm") (raw-value (tesl_import_CivilTime_endOfDay (raw-value d)))))))) 120)
    ))
  )

  (test-case "millisecond day arithmetic is wrong exactly where addDays is right"
    (call-with-fresh-memory-db '() (lambda ()
  (define start (thsl-src! "tests/civil-time-tests.tesl" 321 (list) (lambda () (raw-value (tesl_import_CivilTime_startOfDay (raw-value (stockholmDay 2026 March 29)))))))
  (define msNextDay (thsl-src! "tests/civil-time-tests.tesl" 322 (list (cons 'start start)) (lambda () (addMs (raw-value start) 86400000))))
  (define civilNextDay (thsl-src! "tests/civil-time-tests.tesl" 323 (list (cons 'msNextDay msNextDay) (cons 'start start)) (lambda () (raw-value (tesl_import_CivilTime_startOfDay (raw-value (tesl_import_CivilTime_addDays (raw-value (stockholmDay 2026 March 29)) 1)))))))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 324 (list (cons 'civilNextDay civilNextDay) (cons 'msNextDay msNextDay) (cons 'start start)) (lambda () (- (raw-value (tesl_import_Time_posixToSeconds (raw-value msNextDay))) (raw-value (tesl_import_Time_posixToSeconds (raw-value civilNextDay))))))) 3600)
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 325 (list (cons 'civilNextDay civilNextDay) (cons 'msNextDay msNextDay) (cons 'start start)) (lambda () (raw-value (tesl_import_CivilTime_toIso (raw-value (tesl_import_CivilTime_fromInstant (__ttz_tesl-tz-named "Europe/Stockholm") (raw-value civilNextDay)))))))) "2026-03-30")
    ))
  )

  (test-case "two dates in different zones cannot be diffed"
    (call-with-fresh-memory-db '() (lambda ()
  (define inUtc (thsl-src! "tests/civil-time-tests.tesl" 338 (list) (lambda () (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-utc) 20000)))))
  (define inStockholm (thsl-src! "tests/civil-time-tests.tesl" 339 (list (cons 'inUtc inUtc)) (lambda () (raw-value (tesl_import_CivilTime_fromDayNumber (__ttz_tesl-tz-named "Europe/Stockholm") 20000)))))
  (check-equal? (raw-value (thsl-src! "tests/civil-time-tests.tesl" 340 (list (cons 'inStockholm inStockholm) (cons 'inUtc inUtc)) (lambda () (raw-value (tesl_import_CivilTime_dayNumber (raw-value inUtc)))))) (raw-value (tesl_import_CivilTime_dayNumber (raw-value inStockholm))))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "tests/civil-time-tests.tesl" 341 (list (cons 'inStockholm inStockholm) (cons 'inUtc inUtc)) (lambda ()
                          (diffAcrossZones (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: diffAcrossZones (list)"))
    ))
  )

)
