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
  (only-in tesl/tesl/either Either Left Right [Either.isLeft tesl_import_Either_isLeft] [Either.map tesl_import_Either_map] [Either.andThen tesl_import_Either_andThen])
  (only-in tesl/tesl/dict Dict [Dict.empty tesl_import_Dict_empty] [Dict.singleton tesl_import_Dict_singleton] [Dict.insert tesl_import_Dict_insert] [Dict.remove tesl_import_Dict_remove] [Dict.lookup tesl_import_Dict_lookup] [Dict.requireKey tesl_import_Dict_requireKey] [Dict.get tesl_import_Dict_get] [Dict.member tesl_import_Dict_member] [Dict.size tesl_import_Dict_size] [Dict.union tesl_import_Dict_union] [Dict.fromList tesl_import_Dict_fromList] [Dict.filterCheckValues tesl_import_Dict_filterCheckValues] [Dict.filterCheckKeys tesl_import_Dict_filterCheckKeys])
  (only-in tesl/tesl/set Set [Set.empty tesl_import_Set_empty] [Set.insert tesl_import_Set_insert] [Set.member tesl_import_Set_member] [Set.size tesl_import_Set_size] [Set.isEmpty tesl_import_Set_isEmpty] [Set.toList tesl_import_Set_toList] [Set.fromList tesl_import_Set_fromList] [Set.union tesl_import_Set_union] [Set.intersection tesl_import_Set_intersection] [Set.difference tesl_import_Set_difference])
  (only-in tesl/tesl/string [String.toInt tesl_import_String_toInt] [String.isEmpty tesl_import_String_isEmpty])
  (only-in tesl/tesl/list [List.foldl tesl_import_List_foldl])
  (only-in tesl/tesl/tuple Tuple2)
)


(provide parseAge lookupUser rolePermissions uniqueRoles countByStatus getVerifiedScores getByValidKeys parseAge-signature lookupUser-signature rolePermissions-signature countByStatus-signature getVerifiedScores-signature getByValidKeys-signature uniqueRoles-signature)

(define IsNonEmpty 'IsNonEmpty)
(define IsPositiveScore 'IsPositiveScore)

(define/pow
  (parseAge [raw : String])
  #:returns (Either String Integer)
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 104 (list (cons 'raw *raw)) (lambda () (if (tesl_import_String_isEmpty *raw) (raw-value (raw-value (Left "age cannot be empty"))) (let ([tesl_case_0 (raw-value (tesl_import_String_toInt *raw))]) (cond [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Nothing)) (raw-value (raw-value (Left "age must be a number")))] [(and (adt-value? *tesl_case_0) (eq? (adt-value-variant *tesl_case_0) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl_case_0) 'value)]) (if (< *n 0) (raw-value (raw-value (Left "age cannot be negative"))) (if (> *n 150) (raw-value (raw-value (Left "age seems unrealistic"))) (raw-value (raw-value (Right *n))))))]))))))

(define/pow
  (validateAdult [age : Integer])
  #:returns (Either String Integer)
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 121 (list (cons 'age *age)) (lambda () (if (>= *age 18) (raw-value (raw-value (Right *age))) (raw-value (raw-value (Left "must be 18 or older")))))))

(define/pow
  (parseAdultAge [raw : String])
  #:returns (Either String Integer)
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 127 (list (cons 'raw *raw)) (lambda () (raw-value (tesl_import_Either_andThen validateAdult (raw-value (parseAge raw)))))))

(define/pow
  (toAgeCategory [age : Integer])
  #:returns String
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 131 (list (cons 'age *age)) (lambda () (if (< *age 18) (raw-value "minor") (if (< *age 65) (raw-value "adult") (raw-value "senior"))))))

(define/pow
  (ageCategory [raw : String])
  #:returns (Either String String)
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 140 (list (cons 'raw *raw)) (lambda () (raw-value (tesl_import_Either_map toAgeCategory (raw-value (parseAge raw)))))))

(define/pow
  (buildUserDb)
  #:returns (Dict String String)
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 146 (list) (lambda () (raw-value (tesl_import_Dict_fromList (list (Tuple2 "usr-1" "alice") (Tuple2 "usr-2" "bob") (Tuple2 "usr-3" "carol")))))))

(define/pow
  (lookupUser [userId : String])
  #:returns (Maybe String)
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 149 (list (cons 'userId *userId)) (lambda () (raw-value (tesl_import_Dict_lookup *userId (raw-value (buildUserDb)))))))

(define/pow
  (rolePermissions [role : String])
  #:returns (List String)
  (let ([perms (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 153 (list (cons 'role *role)) (lambda () (raw-value (tesl_import_Dict_fromList (list (Tuple2 "admin" "read,write,delete,manage") (Tuple2 "member" "read,write") (Tuple2 "guest" "read"))))))]) (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 154 (list (cons 'perms *perms) (cons 'role *role)) (lambda () (let ([tesl_case_1 (raw-value (tesl_import_Dict_lookup *role (raw-value perms)))]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Nothing)) (raw-value (list))] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Something)) (let ([p (hash-ref (adt-value-fields *tesl_case_1) 'value)]) (raw-value (list *p)))]))))))

(define/pow
  (currentCount [acc : (Dict String Integer)] [status : String])
  #:returns Integer
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 162 (list (cons 'acc *acc) (cons 'status *status)) (lambda () (let ([tesl_case_2 (raw-value (tesl_import_Dict_lookup *status *acc))]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Something)) (let ([value (hash-ref (adt-value-fields *tesl_case_2) 'value)]) *value)] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Nothing)) (raw-value 0)])))))

(define/pow
  (incrementCount [acc : (Dict String Integer)] [status : String])
  #:returns (Dict String Integer)
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 168 (list (cons 'acc *acc) (cons 'status *status)) (lambda () (raw-value (tesl_import_Dict_insert *status (+ (raw-value (currentCount acc status)) 1) *acc)))))

(define/pow
  (countByStatus [statuses : (List String)])
  #:returns (Dict String Integer)
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 172 (list (cons 'statuses *statuses)) (lambda () (raw-value (tesl_import_List_foldl incrementCount tesl_import_Dict_empty *statuses)))))

(define-checker
  (checkPositiveScore [n : Integer])
  #:returns [n : Integer ::: (IsPositiveScore n)]
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 186 (list (cons 'n *n)) (lambda () (if (> *n 0) (accept (IsPositiveScore n) #:value *n) (reject "score must be positive" #:http-code 400)))))

(define-checker
  (checkNonEmpty [s : String])
  #:returns [s : String ::: (IsNonEmpty s)]
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 192 (list (cons 's *s)) (lambda () (if (tesl_import_String_isEmpty *s) (reject "key must be non-empty" #:http-code 400) (accept (IsNonEmpty s) #:value *s)))))

(define/pow
  (getVerifiedScores [raw : (Dict String Integer)])
  #:returns (Dict String Integer)
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 203 (list (cons 'raw *raw)) (lambda () (raw-value (tesl_import_Dict_filterCheckValues checkPositiveScore *raw)))))

(define/pow
  (getByValidKeys [raw : (Dict String Integer)])
  #:returns (Dict String Integer)
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 209 (list (cons 'raw *raw)) (lambda () (raw-value (tesl_import_Dict_filterCheckKeys checkNonEmpty *raw)))))

(define/pow
  (addRole [acc : (Set String)] [role : String])
  #:returns (Set String)
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 215 (list (cons 'acc *acc) (cons 'role *role)) (lambda () (raw-value (tesl_import_Set_insert *role *acc)))))

(define/pow
  (uniqueRoles [userRoles : (List String)])
  #:returns (Set String)
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 219 (list (cons 'userRoles *userRoles)) (lambda () (raw-value (tesl_import_List_foldl addRole tesl_import_Set_empty *userRoles)))))

(define/pow
  (permissionsForRoles [roles : (Set String)])
  #:returns (Set String)
  (let ([allPerms (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 223 (list (cons 'roles *roles)) (lambda () (raw-value (tesl_import_Set_fromList (raw-value (tesl_import_Set_toList *roles))))))]) (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 224 (list (cons 'allPerms *allPerms) (cons 'roles *roles)) (lambda () (raw-value allPerms)))))

(define/pow
  (isLeft [e : (Either String Integer)])
  #:returns Boolean
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 312 (list (cons 'e *e)) (lambda () (raw-value (tesl_import_Either_isLeft *e)))))

(define/pow
  (isLeftStr [e : (Either String String)])
  #:returns Boolean
  (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 315 (list (cons 'e *e)) (lambda () (raw-value (tesl_import_Either_isLeft *e)))))

(module+ test
  (require rackunit)
  (test-case "either parseAge success"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 307 (list) (lambda () (parseAge "25")))) (raw-value (Right 25)))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 308 (list) (lambda () (parseAge "0")))) (raw-value (Right 0)))
  )

  (test-case "either parseAge errors"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 318 (list) (lambda () (isLeft (parseAge ""))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 319 (list) (lambda () (isLeft (parseAge "abc"))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 320 (list) (lambda () (isLeft (parseAge "-1"))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 321 (list) (lambda () (isLeft (parseAge "200"))))) #t)
  )

  (test-case "either andThen chain"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 325 (list) (lambda () (parseAdultAge "25")))) (raw-value (Right 25)))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 326 (list) (lambda () (isLeft (parseAdultAge "16"))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 327 (list) (lambda () (isLeft (parseAdultAge "abc"))))) #t)
  )

  (test-case "either map"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 331 (list) (lambda () (ageCategory "17")))) (raw-value (Right "minor")))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 332 (list) (lambda () (ageCategory "30")))) (raw-value (Right "adult")))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 333 (list) (lambda () (ageCategory "70")))) (raw-value (Right "senior")))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 334 (list) (lambda () (isLeftStr (ageCategory "abc"))))) #t)
  )

  (test-case "dict basics"
  (define d (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 338 (list) (lambda () (raw-value (tesl_import_Dict_fromList (list (Tuple2 "a" 1) (Tuple2 "b" 2) (Tuple2 "c" 3)))))))
  (define keyB (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 339 (list (cons 'd d)) (lambda () "b")))
  (define tesl_checked_3 (tesl_import_Dict_requireKey keyB d))
  (when (check-fail? tesl_checked_3)
    (raise-user-error 'tesl-test "unexpected failure in let checkedB: ~a" (check-fail-message tesl_checked_3)))
  (define checkedB tesl_checked_3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 341 (list (cons 'checkedB checkedB) (cons 'keyB keyB) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_size (raw-value d)))))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 342 (list (cons 'checkedB checkedB) (cons 'keyB keyB) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_lookup "a" (raw-value d)))))) (raw-value (Something 1)))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 343 (list (cons 'checkedB checkedB) (cons 'keyB keyB) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_lookup "z" (raw-value d)))))) Nothing)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 344 (list (cons 'checkedB checkedB) (cons 'keyB keyB) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_get (raw-value keyB) checkedB))))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 345 (list (cons 'checkedB checkedB) (cons 'keyB keyB) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_member "a" (raw-value d)))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 346 (list (cons 'checkedB checkedB) (cons 'keyB keyB) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_member "z" (raw-value d)))))) #f)
  )

  (test-case "dict insert and remove"
  (define d (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 350 (list) (lambda () (raw-value (tesl_import_Dict_singleton "x" 42)))))
  (define d2 (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 351 (list (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_insert "y" 99 (raw-value d))))))
  (define d3 (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 352 (list (cons 'd2 d2) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_remove "x" (raw-value d2))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 353 (list (cons 'd3 d3) (cons 'd2 d2) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_size (raw-value d2)))))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 354 (list (cons 'd3 d3) (cons 'd2 d2) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_size (raw-value d3)))))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 355 (list (cons 'd3 d3) (cons 'd2 d2) (cons 'd d)) (lambda () (raw-value (tesl_import_Dict_member "x" (raw-value d3)))))) #f)
  )

  (test-case "dict union"
  (define d1 (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 359 (list) (lambda () (raw-value (tesl_import_Dict_fromList (list (Tuple2 "a" 1) (Tuple2 "b" 2)))))))
  (define d2 (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 360 (list (cons 'd1 d1)) (lambda () (raw-value (tesl_import_Dict_fromList (list (Tuple2 "b" 99) (Tuple2 "c" 3)))))))
  (define u (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 361 (list (cons 'd2 d2) (cons 'd1 d1)) (lambda () (raw-value (tesl_import_Dict_union (raw-value d1) (raw-value d2))))))
  (define keyA (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 362 (list (cons 'u u) (cons 'd2 d2) (cons 'd1 d1)) (lambda () "a")))
  (define keyB (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 363 (list (cons 'keyA keyA) (cons 'u u) (cons 'd2 d2) (cons 'd1 d1)) (lambda () "b")))
  (define keyC (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 364 (list (cons 'keyB keyB) (cons 'keyA keyA) (cons 'u u) (cons 'd2 d2) (cons 'd1 d1)) (lambda () "c")))
  (define tesl_checked_4 (tesl_import_Dict_requireKey keyA u))
  (when (check-fail? tesl_checked_4)
    (raise-user-error 'tesl-test "unexpected failure in let checkedA: ~a" (check-fail-message tesl_checked_4)))
  (define checkedA tesl_checked_4)
  (define tesl_checked_5 (tesl_import_Dict_requireKey keyB u))
  (when (check-fail? tesl_checked_5)
    (raise-user-error 'tesl-test "unexpected failure in let checkedB: ~a" (check-fail-message tesl_checked_5)))
  (define checkedB tesl_checked_5)
  (define tesl_checked_6 (tesl_import_Dict_requireKey keyC u))
  (when (check-fail? tesl_checked_6)
    (raise-user-error 'tesl-test "unexpected failure in let checkedC: ~a" (check-fail-message tesl_checked_6)))
  (define checkedC tesl_checked_6)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 368 (list (cons 'checkedC checkedC) (cons 'checkedB checkedB) (cons 'checkedA checkedA) (cons 'keyC keyC) (cons 'keyB keyB) (cons 'keyA keyA) (cons 'u u) (cons 'd2 d2) (cons 'd1 d1)) (lambda () (raw-value (tesl_import_Dict_get (raw-value keyA) checkedA))))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 369 (list (cons 'checkedC checkedC) (cons 'checkedB checkedB) (cons 'checkedA checkedA) (cons 'keyC keyC) (cons 'keyB keyB) (cons 'keyA keyA) (cons 'u u) (cons 'd2 d2) (cons 'd1 d1)) (lambda () (raw-value (tesl_import_Dict_get (raw-value keyB) checkedB))))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 370 (list (cons 'checkedC checkedC) (cons 'checkedB checkedB) (cons 'checkedA checkedA) (cons 'keyC keyC) (cons 'keyB keyB) (cons 'keyA keyA) (cons 'u u) (cons 'd2 d2) (cons 'd1 d1)) (lambda () (raw-value (tesl_import_Dict_get (raw-value keyC) checkedC))))) 3)
  )

  (test-case "countByStatus"
  (define counts (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 374 (list) (lambda () (countByStatus (list "active" "inactive" "active" "pending")))))
  (define active (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 375 (list (cons 'counts counts)) (lambda () "active")))
  (define inactive (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 376 (list (cons 'active active) (cons 'counts counts)) (lambda () "inactive")))
  (define pending (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 377 (list (cons 'inactive inactive) (cons 'active active) (cons 'counts counts)) (lambda () "pending")))
  (define tesl_checked_7 (tesl_import_Dict_requireKey active counts))
  (when (check-fail? tesl_checked_7)
    (raise-user-error 'tesl-test "unexpected failure in let checkedActive: ~a" (check-fail-message tesl_checked_7)))
  (define checkedActive tesl_checked_7)
  (define tesl_checked_8 (tesl_import_Dict_requireKey inactive counts))
  (when (check-fail? tesl_checked_8)
    (raise-user-error 'tesl-test "unexpected failure in let checkedInactive: ~a" (check-fail-message tesl_checked_8)))
  (define checkedInactive tesl_checked_8)
  (define tesl_checked_9 (tesl_import_Dict_requireKey pending counts))
  (when (check-fail? tesl_checked_9)
    (raise-user-error 'tesl-test "unexpected failure in let checkedPending: ~a" (check-fail-message tesl_checked_9)))
  (define checkedPending tesl_checked_9)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 381 (list (cons 'checkedPending checkedPending) (cons 'checkedInactive checkedInactive) (cons 'checkedActive checkedActive) (cons 'pending pending) (cons 'inactive inactive) (cons 'active active) (cons 'counts counts)) (lambda () (raw-value (tesl_import_Dict_get (raw-value active) checkedActive))))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 382 (list (cons 'checkedPending checkedPending) (cons 'checkedInactive checkedInactive) (cons 'checkedActive checkedActive) (cons 'pending pending) (cons 'inactive inactive) (cons 'active active) (cons 'counts counts)) (lambda () (raw-value (tesl_import_Dict_get (raw-value inactive) checkedInactive))))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 383 (list (cons 'checkedPending checkedPending) (cons 'checkedInactive checkedInactive) (cons 'checkedActive checkedActive) (cons 'pending pending) (cons 'inactive inactive) (cons 'active active) (cons 'counts counts)) (lambda () (raw-value (tesl_import_Dict_get (raw-value pending) checkedPending))))) 1)
  )

  (test-case "ForAllValues \226\128\148 getVerifiedScores keeps only positive values"
  (define raw (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 387 (list) (lambda () (raw-value (tesl_import_Dict_fromList (list (Tuple2 "alice" 95) (Tuple2 "bob" 0) (Tuple2 "carol" -5) (Tuple2 "dave" 80)))))))
  (define scores (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 388 (list (cons 'raw raw)) (lambda () (getVerifiedScores raw))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 390 (list (cons 'scores scores) (cons 'raw raw)) (lambda () (raw-value (tesl_import_Dict_size (raw-value scores)))))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 391 (list (cons 'scores scores) (cons 'raw raw)) (lambda () (raw-value (tesl_import_Dict_member "alice" (raw-value scores)))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 392 (list (cons 'scores scores) (cons 'raw raw)) (lambda () (raw-value (tesl_import_Dict_member "bob" (raw-value scores)))))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 393 (list (cons 'scores scores) (cons 'raw raw)) (lambda () (raw-value (tesl_import_Dict_member "carol" (raw-value scores)))))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 394 (list (cons 'scores scores) (cons 'raw raw)) (lambda () (raw-value (tesl_import_Dict_member "dave" (raw-value scores)))))) #t)
  )

  (test-case "ForAllValues \226\128\148 empty input gives empty output"
  (define raw (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 398 (list) (lambda () (raw-value (tesl_import_Dict_fromList (list))))))
  (define scores (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 399 (list (cons 'raw raw)) (lambda () (getVerifiedScores raw))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 400 (list (cons 'scores scores) (cons 'raw raw)) (lambda () (raw-value (tesl_import_Dict_size (raw-value scores)))))) 0)
  )

  (test-case "ForAllKeys \226\128\148 getByValidKeys drops empty-string keys"
  (define raw (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 404 (list) (lambda () (raw-value (tesl_import_Dict_fromList (list (Tuple2 "" 1) (Tuple2 "x" 2) (Tuple2 "y" 3)))))))
  (define good (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 405 (list (cons 'raw raw)) (lambda () (getByValidKeys raw))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 407 (list (cons 'good good) (cons 'raw raw)) (lambda () (raw-value (tesl_import_Dict_size (raw-value good)))))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 408 (list (cons 'good good) (cons 'raw raw)) (lambda () (raw-value (tesl_import_Dict_member "x" (raw-value good)))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 409 (list (cons 'good good) (cons 'raw raw)) (lambda () (raw-value (tesl_import_Dict_member "y" (raw-value good)))))) #t)
  )

  (test-case "set basics"
  (define s (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 413 (list) (lambda () (raw-value (tesl_import_Set_fromList (list 1 2 3 2 1))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 414 (list (cons 's s)) (lambda () (raw-value (tesl_import_Set_size (raw-value s)))))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 415 (list (cons 's s)) (lambda () (raw-value (tesl_import_Set_member 1 (raw-value s)))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 416 (list (cons 's s)) (lambda () (raw-value (tesl_import_Set_member 9 (raw-value s)))))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 417 (list (cons 's s)) (lambda () (raw-value (tesl_import_Set_isEmpty (raw-value s)))))) #f)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 418 (list (cons 's s)) (lambda () (raw-value (tesl_import_Set_isEmpty tesl_import_Set_empty))))) #t)
  )

  (test-case "set operations"
  (define s1 (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 422 (list) (lambda () (raw-value (tesl_import_Set_fromList (list 1 2 3))))))
  (define s2 (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 423 (list (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_fromList (list 2 3 4))))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 424 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_size (raw-value (tesl_import_Set_union (raw-value s1) (raw-value s2)))))))) 4)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 425 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_size (raw-value (tesl_import_Set_intersection (raw-value s1) (raw-value s2)))))))) 2)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 426 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_size (raw-value (tesl_import_Set_difference (raw-value s1) (raw-value s2)))))))) 1)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 427 (list (cons 's2 s2) (cons 's1 s1)) (lambda () (raw-value (tesl_import_Set_member 1 (raw-value (tesl_import_Set_difference (raw-value s1) (raw-value s2)))))))) #t)
  )

  (test-case "uniqueRoles"
  (define roles (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 431 (list) (lambda () (uniqueRoles (list "admin" "member" "admin" "guest" "member")))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 432 (list (cons 'roles roles)) (lambda () (raw-value (tesl_import_Set_size (raw-value roles)))))) 3)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 433 (list (cons 'roles roles)) (lambda () (raw-value (tesl_import_Set_member "admin" (raw-value roles)))))) #t)
  )

  (test-case "lookupUser"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 437 (list) (lambda () (lookupUser "usr-1")))) (raw-value (Something "alice")))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson27-either-dict-set.tesl" 438 (list) (lambda () (lookupUser "usr-99")))) Nothing)
  )

)
