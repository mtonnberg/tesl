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
  (only-in tesl/tesl/prelude Int String List)
  (only-in tesl/tesl/time PosixMillis [Time.secondsToPosix tesl_import_Time_secondsToPosix] [Time.posixToSeconds tesl_import_Time_posixToSeconds] [Time.truncHour tesl_import_Time_truncHour] [Time.truncDay tesl_import_Time_truncDay] [Time.truncWeek tesl_import_Time_truncWeek] [Time.truncMonth tesl_import_Time_truncMonth] [Time.truncYear tesl_import_Time_truncYear] [Time.offsetAt tesl_import_Time_offsetAt])
  (only-in tesl/tesl/tuple Tuple2 [Tuple2.first tesl_import_Tuple2_first] [Tuple2.second tesl_import_Tuple2_second])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/list [List.length tesl_import_List_length] [List.head tesl_import_List_head])
  (only-in tesl/tesl/db dbRead dbWrite)
)


(provide )

(define-entity Entry
  #:source (make-hash)
  #:table entries
  #:primary-key id
  [Id id : String]
  [OrgId orgId : String]
  [Minutes minutes : Integer]
  [StartedAt startedAt : PosixMillis]
)

(define-database GroupByTestDb
  #:backend memory
  #:schema sql_group_by_tests
  #:entities Entry)

(define/pow
  (seed)
  #:capabilities [dbWrite]
  #:returns Integer
  (let ([_ (thsl-src! "tests/sql-group-by-tests.tesl" 61 (list) (lambda () (insert-one! Entry (hash 'id "e1" 'orgId "acme" 'minutes 60 'startedAt (raw-value (tesl_import_Time_secondsToPosix 1772359200))))))]) (let ([_ (thsl-src! "tests/sql-group-by-tests.tesl" 62 (list (cons '_ *_)) (lambda () (insert-one! Entry (hash 'id "e2" 'orgId "acme" 'minutes 30 'startedAt (raw-value (tesl_import_Time_secondsToPosix 1772407800))))))]) (let ([_ (thsl-src! "tests/sql-group-by-tests.tesl" 63 (list (cons '_ *_) (cons '_ *_)) (lambda () (insert-one! Entry (hash 'id "e3" 'orgId "acme" 'minutes 45 'startedAt (raw-value (tesl_import_Time_secondsToPosix 1772413200))))))]) (let ([_ (thsl-src! "tests/sql-group-by-tests.tesl" 64 (list (cons '_ *_) (cons '_ *_) (cons '_ *_)) (lambda () (insert-one! Entry (hash 'id "e4" 'orgId "acme" 'minutes 15 'startedAt (raw-value (tesl_import_Time_secondsToPosix 1775003400))))))]) (let ([_ (thsl-src! "tests/sql-group-by-tests.tesl" 65 (list (cons '_ *_) (cons '_ *_) (cons '_ *_) (cons '_ *_)) (lambda () (insert-one! Entry (hash 'id "e5" 'orgId "other" 'minutes 999 'startedAt (raw-value (tesl_import_Time_secondsToPosix 1772359200))))))]) (thsl-src! "tests/sql-group-by-tests.tesl" 66 (list (cons '_ *_) (cons '_ *_) (cons '_ *_) (cons '_ *_) (cons '_ *_)) (lambda () 5))))))))

(define/pow
  (minutesPerDay [orgId : String] [tz : TimeZone])
  #:capabilities [dbRead]
  #:returns (List (Tuple2 PosixMillis Integer))
  (thsl-src! "" 1 (list (cons 'orgId *orgId) (cons 'tz *tz)) (lambda () (select-sum-by (sql-group-key 'day *tz (entity-field-ref Entry 'startedAt)) (entity-field-ref Entry 'minutes) (from Entry) (where (==. (entity-field-ref Entry 'orgId) orgId))))))

(define/pow
  (entriesPerMonth [orgId : String])
  #:capabilities [dbRead]
  #:returns (List (Tuple2 PosixMillis Integer))
  (thsl-src! "" 1 (list (cons 'orgId *orgId)) (lambda () (select-count-by (sql-group-key 'month (raw-value (__ttz_tesl-tz-utc)) (entity-field-ref Entry 'startedAt)) (from Entry) (where (==. (entity-field-ref Entry 'orgId) orgId))))))

(define/pow
  (perOrg)
  #:capabilities [dbRead]
  #:returns (List (Tuple2 String Integer))
  (thsl-src! "" 1 (list) (lambda () (select-count-by (sql-group-key 'field 0 (entity-field-ref Entry 'orgId)) (from Entry)))))

(define/pow
  (firstKeySeconds [rows : (List (Tuple2 PosixMillis Integer))])
  #:returns Integer
  (thsl-src-control! "tests/sql-group-by-tests.tesl" 86 (list (cons 'rows *rows)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_List_head *rows))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([row (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "tests/sql-group-by-tests.tesl" 87 (list (cons 'row row)) (lambda () (raw-value (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_Tuple2_first *row))))))))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "tests/sql-group-by-tests.tesl" 88 (list) (lambda () (raw-value (- 0 1))))])))))

(define/pow
  (firstValue [rows : (List (Tuple2 PosixMillis Integer))])
  #:returns Integer
  (thsl-src-control! "tests/sql-group-by-tests.tesl" 91 (list (cons 'rows *rows)) (lambda () (let ([tesl-case-1 (raw-value (tesl_import_List_head *rows))]) (cond [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Something)) (let ([row (hash-ref (adt-value-fields *tesl-case-1) 'value)]) (thsl-src! "tests/sql-group-by-tests.tesl" 92 (list (cons 'row row)) (lambda () (raw-value (raw-value (tesl_import_Tuple2_second *row))))))] [(and (adt-value? *tesl-case-1) (eq? (adt-value-variant *tesl-case-1) 'Nothing)) (thsl-src! "tests/sql-group-by-tests.tesl" 93 (list) (lambda () (raw-value (- 0 1))))])))))

(define/pow
  (firstOrgKey [rows : (List (Tuple2 String Integer))])
  #:returns String
  (thsl-src-control! "tests/sql-group-by-tests.tesl" 96 (list (cons 'rows *rows)) (lambda () (let ([tesl-case-2 (raw-value (tesl_import_List_head *rows))]) (cond [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Something)) (let ([row (hash-ref (adt-value-fields *tesl-case-2) 'value)]) (thsl-src! "tests/sql-group-by-tests.tesl" 97 (list (cons 'row row)) (lambda () (raw-value (raw-value (tesl_import_Tuple2_first *row))))))] [(and (adt-value? *tesl-case-2) (eq? (adt-value-variant *tesl-case-2) 'Nothing)) (thsl-src! "tests/sql-group-by-tests.tesl" 98 (list) (lambda () (raw-value "<empty>")))])))))

(define/pow
  (firstOrgValue [rows : (List (Tuple2 String Integer))])
  #:returns Integer
  (thsl-src-control! "tests/sql-group-by-tests.tesl" 101 (list (cons 'rows *rows)) (lambda () (let ([tesl-case-3 (raw-value (tesl_import_List_head *rows))]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([row (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "tests/sql-group-by-tests.tesl" 102 (list (cons 'row row)) (lambda () (raw-value (raw-value (tesl_import_Tuple2_second *row))))))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "tests/sql-group-by-tests.tesl" 103 (list) (lambda () (raw-value (- 0 1))))])))))

(module+ test
  (require rackunit)
  (test-case "truncDay/Month/Year at UTC on 2023-11-14T22:13:20Z"
    (call-with-fresh-memory-db (list GroupByTestDb) (lambda ()
  (define t (thsl-src! "tests/sql-group-by-tests.tesl" 108 (list) (lambda () (raw-value (tesl_import_Time_secondsToPosix 1700000000)))))
  (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 109 (list (cons 't t)) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_Time_truncHour (__ttz_tesl-tz-utc) (raw-value t)))))))) 1699999200)
  (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 110 (list (cons 't t)) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_Time_truncDay (__ttz_tesl-tz-utc) (raw-value t)))))))) 1699920000)
  (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 111 (list (cons 't t)) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_Time_truncMonth (__ttz_tesl-tz-utc) (raw-value t)))))))) 1698796800)
  (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 112 (list (cons 't t)) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_Time_truncYear (__ttz_tesl-tz-utc) (raw-value t)))))))) 1672531200)
    ))
  )

  (test-case "truncWeek is the Monday of the ISO week"
    (call-with-fresh-memory-db (list GroupByTestDb) (lambda ()
  (define t (thsl-src! "tests/sql-group-by-tests.tesl" 117 (list) (lambda () (raw-value (tesl_import_Time_secondsToPosix 1700000000)))))
  (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 118 (list (cons 't t)) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_Time_truncWeek (__ttz_tesl-tz-utc) (raw-value t)))))))) 1699833600)
  (define epoch (thsl-src! "tests/sql-group-by-tests.tesl" 120 (list (cons 't t)) (lambda () (raw-value (tesl_import_Time_secondsToPosix 0)))))
  (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 121 (list (cons 'epoch epoch) (cons 't t)) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_Time_truncWeek (__ttz_tesl-tz-utc) (raw-value epoch)))))))) (- 0 259200))
    ))
  )

  (test-case "a fixed offset rolls a late-evening instant into the next local day"
    (call-with-fresh-memory-db (list GroupByTestDb) (lambda ()
  (define lateEvening (thsl-src! "tests/sql-group-by-tests.tesl" 127 (list) (lambda () (raw-value (tesl_import_Time_secondsToPosix 1700004600)))))
  (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 128 (list (cons 'lateEvening lateEvening)) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_Time_truncDay (__ttz_tesl-tz-fixed (raw-value 120)) (raw-value lateEvening)))))))) 1699999200)
  (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 130 (list (cons 'lateEvening lateEvening)) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_Time_truncDay (__ttz_tesl-tz-utc) (raw-value lateEvening)))))))) 1699920000)
    ))
  )

  (test-case "zone constructors are DST-correct per instant (no summer-time bookkeeping)"
    (call-with-fresh-memory-db (list GroupByTestDb) (lambda ()
  (define winter (thsl-src! "tests/sql-group-by-tests.tesl" 136 (list) (lambda () (raw-value (tesl_import_Time_secondsToPosix 1767225600)))))
  (define summer (thsl-src! "tests/sql-group-by-tests.tesl" 137 (list (cons 'winter winter)) (lambda () (raw-value (tesl_import_Time_secondsToPosix 1750000000)))))
  (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 138 (list (cons 'summer summer) (cons 'winter winter)) (lambda () (raw-value (tesl_import_Time_offsetAt (__ttz_tesl-tz-named "Europe/Stockholm") (raw-value winter)))))) 60)
  (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 139 (list (cons 'summer summer) (cons 'winter winter)) (lambda () (raw-value (tesl_import_Time_offsetAt (__ttz_tesl-tz-named "Europe/Stockholm") (raw-value summer)))))) 120)
  (define early (thsl-src! "tests/sql-group-by-tests.tesl" 142 (list (cons 'summer summer) (cons 'winter winter)) (lambda () (raw-value (tesl_import_Time_secondsToPosix 1774744200)))))
  (define later (thsl-src! "tests/sql-group-by-tests.tesl" 143 (list (cons 'early early) (cons 'summer summer) (cons 'winter winter)) (lambda () (raw-value (tesl_import_Time_secondsToPosix 1774785600)))))
  (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 144 (list (cons 'later later) (cons 'early early) (cons 'summer summer) (cons 'winter winter)) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_Time_truncDay (__ttz_tesl-tz-named "Europe/Stockholm") (raw-value early)))))))) 1774738800)
  (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 145 (list (cons 'later later) (cons 'early early) (cons 'summer summer) (cons 'winter winter)) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_Time_truncDay (__ttz_tesl-tz-named "Europe/Stockholm") (raw-value later)))))))) 1774738800)
    ))
  )

  (test-case "leap day truncates to Feb 2020 / Jan 2020 / its own day"
    (call-with-fresh-memory-db (list GroupByTestDb) (lambda ()
  (define leap (thsl-src! "tests/sql-group-by-tests.tesl" 149 (list) (lambda () (raw-value (tesl_import_Time_secondsToPosix 1582934400)))))
  (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 150 (list (cons 'leap leap)) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_Time_truncDay (__ttz_tesl-tz-utc) (raw-value leap)))))))) 1582934400)
  (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 151 (list (cons 'leap leap)) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_Time_truncMonth (__ttz_tesl-tz-utc) (raw-value leap)))))))) 1580515200)
  (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 152 (list (cons 'leap leap)) (lambda () (raw-value (tesl_import_Time_posixToSeconds (raw-value (tesl_import_Time_truncYear (__ttz_tesl-tz-utc) (raw-value leap)))))))) 1577836800)
    ))
  )

  (test-case "selectSumBy day buckets: per-day sums, ordered, exact values"
    (call-with-fresh-memory-db (list GroupByTestDb) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-4 (thsl-src! "tests/sql-group-by-tests.tesl" 158 (list) (lambda () (seed))))
    (define days (thsl-src! "tests/sql-group-by-tests.tesl" 159 (list) (lambda () (minutesPerDay "acme" (__ttz_tesl-tz-utc)))))
    (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 160 (list (cons 'days days)) (lambda () (raw-value (tesl_import_List_length (raw-value days)))))) 3)
    (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 162 (list (cons 'days days)) (lambda () (firstKeySeconds days)))) 1772323200)
    (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 163 (list (cons 'days days)) (lambda () (firstValue days)))) 90)
    )
    ))
  )

  (test-case "selectCountBy month buckets: March has 3 acme entries, April 1"
    (call-with-fresh-memory-db (list GroupByTestDb) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-5 (thsl-src! "tests/sql-group-by-tests.tesl" 167 (list) (lambda () (seed))))
    (define months (thsl-src! "tests/sql-group-by-tests.tesl" 168 (list) (lambda () (entriesPerMonth "acme"))))
    (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 169 (list (cons 'months months)) (lambda () (raw-value (tesl_import_List_length (raw-value months)))))) 2)
    (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 170 (list (cons 'months months)) (lambda () (firstKeySeconds months)))) 1772323200)
    (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 171 (list (cons 'months months)) (lambda () (firstValue months)))) 3)
    )
    ))
  )

  (test-case "a zone offset moves a row across the day boundary"
    (call-with-fresh-memory-db (list GroupByTestDb) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-6 (thsl-src! "tests/sql-group-by-tests.tesl" 175 (list) (lambda () (seed))))
    (define days (thsl-src! "tests/sql-group-by-tests.tesl" 178 (list) (lambda () (minutesPerDay "acme" (__ttz_tesl-tz-fixed (raw-value 120))))))
    (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 179 (list (cons 'days days)) (lambda () (raw-value (tesl_import_List_length (raw-value days)))))) 3)
    (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 180 (list (cons 'days days)) (lambda () (firstValue days)))) 60)
    )
    ))
  )

  (test-case "plain-column group key counts per org"
    (call-with-fresh-memory-db (list GroupByTestDb) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-7 (thsl-src! "tests/sql-group-by-tests.tesl" 184 (list) (lambda () (seed))))
    (define orgs (thsl-src! "tests/sql-group-by-tests.tesl" 185 (list) (lambda () (perOrg))))
    (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 186 (list (cons 'orgs orgs)) (lambda () (raw-value (tesl_import_List_length (raw-value orgs)))))) 2)
    (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 188 (list (cons 'orgs orgs)) (lambda () (firstOrgKey orgs)))) "acme")
    (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 189 (list (cons 'orgs orgs)) (lambda () (firstOrgValue orgs)))) 4)
    )
    ))
  )

  (test-case "a zone-keyed grouped query buckets by the zone's wall clock"
    (call-with-fresh-memory-db (list GroupByTestDb) (lambda ()
    (with-capabilities (dbRead dbWrite)
    (define tesl-ignored-8 (thsl-src! "tests/sql-group-by-tests.tesl" 193 (list) (lambda () (seed))))
    (define days (thsl-src! "tests/sql-group-by-tests.tesl" 196 (list) (lambda () (minutesPerDay "acme" (__ttz_tesl-tz-named "Europe/Stockholm")))))
    (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 197 (list (cons 'days days)) (lambda () (raw-value (tesl_import_List_length (raw-value days)))))) 3)
    (check-equal? (raw-value (thsl-src! "tests/sql-group-by-tests.tesl" 198 (list (cons 'days days)) (lambda () (firstValue days)))) 60)
    )
    ))
  )

)
