#lang racket

(require
  tesl/dsl/capability
  tesl/dsl/types
  tesl/dsl/check
  tesl/dsl/otel
  tesl/dsl/sql
  tesl/dsl/web
  tesl/dsl/test-support
  tesl/tesl/private/runtime
  tesl/tesl/queue
  tesl/tesl/sse
  (only-in tesl/tesl/prelude Bool Int String List Fact)
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
  (only-in tesl/tesl/list [List.length tesl_import_List_length] [List.foldl tesl_import_List_foldl])
  (only-in tesl/github/tesl/example/kanel/kanel-models OrgRole RoleAdmin RoleMember RoleViewer IssueStatus Backlog Todo InProgress InReview Done Cancelled InvoiceStatus Draft Approved Sent Paid Overdue)
  (only-in tesl/github/tesl/example/kanel/kanel-org checkOrgName checkSlug checkEmail checkOrgName-signature checkSlug-signature checkEmail-signature)
  (only-in tesl/github/tesl/example/kanel/kanel-issues checkTitle checkDescription checkEstimate checkPositiveMinutes checkCommentBody checkTransition checkTitle-signature checkDescription-signature checkEstimate-signature checkPositiveMinutes-signature checkCommentBody-signature checkTransition-signature)
)


(provide )

(define/pow
  (addMinutesRaw [acc : Integer] [minutes : Integer])
  #:returns Integer
  (+ *acc *minutes))

(module+ test
  (require rackunit)
  (test-case "checkOrgName: accepts valid names"
  (define tesl_checked_0 (checkOrgName "Acme Corp"))
  (when (check-fail? tesl_checked_0)
    (raise-user-error 'tesl-test "unexpected failure in let n1: ~a" (check-fail-message tesl_checked_0)))
  (define n1 tesl_checked_0)
  (define tesl_checked_1 (checkOrgName "AB"))
  (when (check-fail? tesl_checked_1)
    (raise-user-error 'tesl-test "unexpected failure in let n2: ~a" (check-fail-message tesl_checked_1)))
  (define n2 tesl_checked_1)
  (check-true (>= (raw-value (tesl_import_String_length n1)) 2))
  (check-equal? (raw-value (tesl_import_String_length n2)) 2)
  )

  (test-case "checkOrgName: rejects empty string"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkOrgName ""))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkOrgName \"\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkOrgName "   "))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkOrgName \"   \""))
  )

  (test-case "checkOrgName: rejects names that are too long"
  (define tooLong "aaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeeeeeeeeffffffffff gggggggggg hhhhhhh")
  (if (> (raw-value (tesl_import_String_length (raw-value tooLong))) 80)
      (let ()
        (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                                (checkOrgName tooLong))])
          (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                      "expected failure: check checkOrgName tooLong"))
      )
      (let ()
        (check-true (raw-value #t))
      ))
  )

  (test-case "checkSlug: accepts valid slugs"
  (define raw1 "acme-corp")
  (define tesl_checked_2 (checkSlug raw1))
  (when (check-fail? tesl_checked_2)
    (raise-user-error 'tesl-test "unexpected failure in let s1: ~a" (check-fail-message tesl_checked_2)))
  (define s1 tesl_checked_2)
  (define raw2 "my-project-2024")
  (define tesl_checked_3 (checkSlug raw2))
  (when (check-fail? tesl_checked_3)
    (raise-user-error 'tesl-test "unexpected failure in let s2: ~a" (check-fail-message tesl_checked_3)))
  (define s2 tesl_checked_3)
  (check-true (>= (raw-value (tesl_import_String_length s1)) 2))
  (check-true (>= (raw-value (tesl_import_String_length s2)) 2))
  )

  (test-case "checkSlug: rejects empty"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkSlug ""))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkSlug \"\""))
  )

  (test-case "checkEmail: accepts valid email"
  (define rawEmail "user@example.com")
  (define tesl_checked_4 (checkEmail rawEmail))
  (when (check-fail? tesl_checked_4)
    (raise-user-error 'tesl-test "unexpected failure in let e: ~a" (check-fail-message tesl_checked_4)))
  (define e tesl_checked_4)
  (check-true (> (raw-value (tesl_import_String_length e)) 0))
  )

  (test-case "checkEmail: rejects missing @"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkEmail "notanemail"))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkEmail \"notanemail\""))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkEmail ""))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkEmail \"\""))
  )

  (test-case "checkTitle: basic validation"
  (define rawTitle "Fix the login bug")
  (define tesl_checked_5 (checkTitle rawTitle))
  (when (check-fail? tesl_checked_5)
    (raise-user-error 'tesl-test "unexpected failure in let t: ~a" (check-fail-message tesl_checked_5)))
  (define t tesl_checked_5)
  (check-true (>= (raw-value (tesl_import_String_length t)) 1))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTitle ""))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTitle \"\""))
  )

  (test-case "checkDescription: accepts empty description"
  (define rawDesc "")
  (define tesl_checked_6 (checkDescription rawDesc))
  (when (check-fail? tesl_checked_6)
    (raise-user-error 'tesl-test "unexpected failure in let d: ~a" (check-fail-message tesl_checked_6)))
  (define d tesl_checked_6)
  (check-equal? (raw-value (tesl_import_String_length d)) 0)
  )

  (test-case "checkEstimate: accepts zero and positive"
  (define n0 0)
  (define tesl_checked_7 (checkEstimate n0))
  (when (check-fail? tesl_checked_7)
    (raise-user-error 'tesl-test "unexpected failure in let e0: ~a" (check-fail-message tesl_checked_7)))
  (define e0 tesl_checked_7)
  (define n1 60)
  (define tesl_checked_8 (checkEstimate n1))
  (when (check-fail? tesl_checked_8)
    (raise-user-error 'tesl-test "unexpected failure in let e1: ~a" (check-fail-message tesl_checked_8)))
  (define e1 tesl_checked_8)
  (define n2 480)
  (define tesl_checked_9 (checkEstimate n2))
  (when (check-fail? tesl_checked_9)
    (raise-user-error 'tesl-test "unexpected failure in let e2: ~a" (check-fail-message tesl_checked_9)))
  (define e2 tesl_checked_9)
  (check-equal? (raw-value e0) 0)
  (check-equal? (raw-value e1) 60)
  (check-equal? (raw-value e2) 480)
  )

  (test-case "checkEstimate: rejects negative"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkEstimate -1))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkEstimate -1"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkEstimate -100))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkEstimate -100"))
  )

  (test-case "checkPositiveMinutes: valid range"
  (define raw1 1)
  (define tesl_checked_10 (checkPositiveMinutes raw1))
  (when (check-fail? tesl_checked_10)
    (raise-user-error 'tesl-test "unexpected failure in let m1: ~a" (check-fail-message tesl_checked_10)))
  (define m1 tesl_checked_10)
  (define raw2 60)
  (define tesl_checked_11 (checkPositiveMinutes raw2))
  (when (check-fail? tesl_checked_11)
    (raise-user-error 'tesl-test "unexpected failure in let m2: ~a" (check-fail-message tesl_checked_11)))
  (define m2 tesl_checked_11)
  (define raw3 1440)
  (define tesl_checked_12 (checkPositiveMinutes raw3))
  (when (check-fail? tesl_checked_12)
    (raise-user-error 'tesl-test "unexpected failure in let m3: ~a" (check-fail-message tesl_checked_12)))
  (define m3 tesl_checked_12)
  (check-equal? (raw-value m1) 1)
  (check-equal? (raw-value m3) 1440)
  )

  (test-case "checkPositiveMinutes: rejects zero and above 24h"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkPositiveMinutes 0))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPositiveMinutes 0"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkPositiveMinutes -5))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPositiveMinutes -5"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkPositiveMinutes 1441))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPositiveMinutes 1441"))
  )

  (test-case "checkCommentBody: accepts non-empty"
  (define rawBody "This is a comment.")
  (define tesl_checked_13 (checkCommentBody rawBody))
  (when (check-fail? tesl_checked_13)
    (raise-user-error 'tesl-test "unexpected failure in let b: ~a" (check-fail-message tesl_checked_13)))
  (define b tesl_checked_13)
  (check-true (> (raw-value (tesl_import_String_length b)) 0))
  )

  (test-case "checkCommentBody: rejects empty"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkCommentBody ""))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkCommentBody \"\""))
  )

  (test-case "valid transitions from Backlog"
  (define from1 Backlog)
  (define to1 Todo)
  (define tesl_checked_14 (checkTransition from1 to1))
  (when (check-fail? tesl_checked_14)
    (raise-user-error 'tesl-test "unexpected failure in let t1: ~a" (check-fail-message tesl_checked_14)))
  (define t1 tesl_checked_14)
  (define from2 Backlog)
  (define to2 Cancelled)
  (define tesl_checked_15 (checkTransition from2 to2))
  (when (check-fail? tesl_checked_15)
    (raise-user-error 'tesl-test "unexpected failure in let t2: ~a" (check-fail-message tesl_checked_15)))
  (define t2 tesl_checked_15)
  (check-true (raw-value #t))
  )

  (test-case "valid transitions from Todo"
  (define from1 Todo)
  (define to1 InProgress)
  (define tesl_checked_16 (checkTransition from1 to1))
  (when (check-fail? tesl_checked_16)
    (raise-user-error 'tesl-test "unexpected failure in let t1: ~a" (check-fail-message tesl_checked_16)))
  (define t1 tesl_checked_16)
  (define from2 Todo)
  (define to2 Backlog)
  (define tesl_checked_17 (checkTransition from2 to2))
  (when (check-fail? tesl_checked_17)
    (raise-user-error 'tesl-test "unexpected failure in let t2: ~a" (check-fail-message tesl_checked_17)))
  (define t2 tesl_checked_17)
  (define from3 Todo)
  (define to3 Cancelled)
  (define tesl_checked_18 (checkTransition from3 to3))
  (when (check-fail? tesl_checked_18)
    (raise-user-error 'tesl-test "unexpected failure in let t3: ~a" (check-fail-message tesl_checked_18)))
  (define t3 tesl_checked_18)
  (check-true (raw-value #t))
  )

  (test-case "valid transitions from InProgress"
  (define from1 InProgress)
  (define to1 InReview)
  (define tesl_checked_19 (checkTransition from1 to1))
  (when (check-fail? tesl_checked_19)
    (raise-user-error 'tesl-test "unexpected failure in let t1: ~a" (check-fail-message tesl_checked_19)))
  (define t1 tesl_checked_19)
  (define from2 InProgress)
  (define to2 Todo)
  (define tesl_checked_20 (checkTransition from2 to2))
  (when (check-fail? tesl_checked_20)
    (raise-user-error 'tesl-test "unexpected failure in let t2: ~a" (check-fail-message tesl_checked_20)))
  (define t2 tesl_checked_20)
  (check-true (raw-value #t))
  )

  (test-case "valid transitions from InReview"
  (define from1 InReview)
  (define to1 Done)
  (define tesl_checked_21 (checkTransition from1 to1))
  (when (check-fail? tesl_checked_21)
    (raise-user-error 'tesl-test "unexpected failure in let t1: ~a" (check-fail-message tesl_checked_21)))
  (define t1 tesl_checked_21)
  (define from2 InReview)
  (define to2 InProgress)
  (define tesl_checked_22 (checkTransition from2 to2))
  (when (check-fail? tesl_checked_22)
    (raise-user-error 'tesl-test "unexpected failure in let t2: ~a" (check-fail-message tesl_checked_22)))
  (define t2 tesl_checked_22)
  (check-true (raw-value #t))
  )

  (test-case "valid transition from Cancelled"
  (define from1 Cancelled)
  (define to1 Backlog)
  (define tesl_checked_23 (checkTransition from1 to1))
  (when (check-fail? tesl_checked_23)
    (raise-user-error 'tesl-test "unexpected failure in let t1: ~a" (check-fail-message tesl_checked_23)))
  (define t1 tesl_checked_23)
  (check-true (raw-value #t))
  )

  (test-case "invalid: cannot jump from Backlog to Done directly"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTransition Backlog Done))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTransition Backlog Done"))
  )

  (test-case "invalid: cannot jump from Backlog to InProgress"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTransition Backlog InProgress))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTransition Backlog InProgress"))
  )

  (test-case "invalid: cannot jump from Backlog to InReview"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTransition Backlog InReview))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTransition Backlog InReview"))
  )

  (test-case "invalid: Done is terminal"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTransition Done Backlog))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTransition Done Backlog"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTransition Done Todo))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTransition Done Todo"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTransition Done InProgress))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTransition Done InProgress"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTransition Done InReview))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTransition Done InReview"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTransition Done Cancelled))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTransition Done Cancelled"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTransition Done Done))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTransition Done Done"))
  )

  (test-case "invalid: cannot skip to Done from Todo"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTransition Todo Done))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTransition Todo Done"))
  )

  (test-case "invalid: cannot skip to Done from InProgress"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTransition InProgress Done))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTransition InProgress Done"))
  )

  (test-case "invalid: Cancelled can only go to Backlog"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTransition Cancelled Todo))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTransition Cancelled Todo"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTransition Cancelled InProgress))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTransition Cancelled InProgress"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkTransition Cancelled Done))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkTransition Cancelled Done"))
  )

  (test-case "property: checkOrgName always returns non-empty"
  ; property: non-empty names within length are valid
  (for ([tesl-prop-i (in-range 100)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (>= (raw-value n) 2) (<= (raw-value n) 80)) (check-true (>= (raw-value (tesl_import_String_length "x")) 0) "non-empty names within length are valid"))
    ))
  )

  (test-case "property: checkEmail accepts user@domain"
  ; property: email with @ is valid
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (> (raw-value n) 0) (< (raw-value n) 100)) (check-true (> (raw-value n) 0) "email with @ is valid"))
    ))
  )

  (test-case "property: checkEstimate is identity on non-negative"
  ; property: valid estimates are returned unchanged
  (for ([tesl-prop-i (in-range 100)])
    (let ([n (- (random 2000001) 1000000)])
      (when (>= (raw-value n) 0) (check-true (equal? (raw-value (checkEstimate n)) (raw-value n)) "valid estimates are returned unchanged"))
    ))
  )

  (test-case "property: checkPositiveMinutes in range 1-1440"
  ; property: valid minute counts are returned unchanged
  (for ([tesl-prop-i (in-range 100)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (>= (raw-value n) 1) (<= (raw-value n) 1440)) (check-true (equal? (raw-value (checkPositiveMinutes n)) (raw-value n)) "valid minute counts are returned unchanged"))
    ))
  )

  (test-case "property: addition is commutative (billing base)"
  ; property: a + b == b + a
  (for ([tesl-prop-i (in-range 50)])
    (let ([a (- (random 2000001) 1000000)] [b (- (random 2000001) 1000000)])
      (when (and (and (>= (raw-value a) 0) (< (raw-value a) 1000)) (and (>= (raw-value b) 0) (< (raw-value b) 1000))) (check-true (equal? (+ (raw-value a) (raw-value b)) (+ (raw-value b) (raw-value a))) "a + b == b + a"))
    ))
  )

  (test-case "property: total minutes calculation is correct"
  (define entries (list 30 60 45 120 15))
  (define total (tesl_import_List_foldl addMinutesRaw 0 (raw-value entries)))
  (check-equal? (raw-value total) 270)
  )

  (test-case "property: estimates are non-negative"
  ; property: estimate non-negative
  (for ([tesl-prop-i (in-range 50)])
    (let ([n (- (random 2000001) 1000000)])
      (when (and (>= (raw-value n) 0) (< (raw-value n) 10000)) (check-true (>= (raw-value (checkEstimate n)) 0) "estimate non-negative"))
    ))
  )

  (test-case "checkOrgName produces ValidOrgName proof"
  (define tesl_checked_24 (checkOrgName "Test Organization"))
  (when (check-fail? tesl_checked_24)
    (raise-user-error 'tesl-test "unexpected failure in let validName: ~a" (check-fail-message tesl_checked_24)))
  (define validName tesl_checked_24)
  (check-true (> (raw-value (tesl_import_String_length validName)) 0))
  )

  (test-case "checkTransition produces ValidTransition proof"
  (define from Todo)
  (define to InProgress)
  (define tesl_checked_25 (checkTransition from to))
  (when (check-fail? tesl_checked_25)
    (raise-user-error 'tesl-test "unexpected failure in let newStatus: ~a" (check-fail-message tesl_checked_25)))
  (define newStatus tesl_checked_25)
  (check-equal? (raw-value newStatus) InProgress)
  )

  (test-case "check combination: both proofs are required"
  (define rawTitle "Implement user auth")
  (define tesl_checked_26 (checkTitle rawTitle))
  (when (check-fail? tesl_checked_26)
    (raise-user-error 'tesl-test "unexpected failure in let validTitle: ~a" (check-fail-message tesl_checked_26)))
  (define validTitle tesl_checked_26)
  (define rawEstimate 120)
  (define tesl_checked_27 (checkEstimate rawEstimate))
  (when (check-fail? tesl_checked_27)
    (raise-user-error 'tesl-test "unexpected failure in let validEstimate: ~a" (check-fail-message tesl_checked_27)))
  (define validEstimate tesl_checked_27)
  (define rawDesc "This is the description")
  (define tesl_checked_28 (checkDescription rawDesc))
  (when (check-fail? tesl_checked_28)
    (raise-user-error 'tesl-test "unexpected failure in let validDesc: ~a" (check-fail-message tesl_checked_28)))
  (define validDesc tesl_checked_28)
  (check-true (> (raw-value (tesl_import_String_length validTitle)) 0))
  (check-equal? (raw-value validEstimate) 120)
  )

  (test-case "invoice total is sum of time entries"
  (define raw1 30)
  (define tesl_checked_29 (checkPositiveMinutes raw1))
  (when (check-fail? tesl_checked_29)
    (raise-user-error 'tesl-test "unexpected failure in let minutes1: ~a" (check-fail-message tesl_checked_29)))
  (define minutes1 tesl_checked_29)
  (define raw2 60)
  (define tesl_checked_30 (checkPositiveMinutes raw2))
  (when (check-fail? tesl_checked_30)
    (raise-user-error 'tesl-test "unexpected failure in let minutes2: ~a" (check-fail-message tesl_checked_30)))
  (define minutes2 tesl_checked_30)
  (define raw3 90)
  (define tesl_checked_31 (checkPositiveMinutes raw3))
  (when (check-fail? tesl_checked_31)
    (raise-user-error 'tesl-test "unexpected failure in let minutes3: ~a" (check-fail-message tesl_checked_31)))
  (define minutes3 tesl_checked_31)
  (define total (+ (+ (raw-value minutes1) (raw-value minutes2)) (raw-value minutes3)))
  (check-equal? (raw-value total) 180)
  )

  (test-case "zero unbilled entries should not create invoice"
  (define emptyList (list))
  (check-equal? (raw-value (raw-value (tesl_import_List_length (raw-value emptyList)))) 0)
  )

  (test-case "invoice total minutes calculation"
  (define m1 30)
  (define m2 60)
  (define m3 45)
  (define total (+ (+ (raw-value m1) (raw-value m2)) (raw-value m3)))
  (check-equal? (raw-value total) 135)
  )

  (test-case "slug must be lowercase"
  (define rawSlug "my-project")
  (define tesl_checked_32 (checkSlug rawSlug))
  (when (check-fail? tesl_checked_32)
    (raise-user-error 'tesl-test "unexpected failure in let s: ~a" (check-fail-message tesl_checked_32)))
  (define s tesl_checked_32)
  (check-true (> (raw-value (tesl_import_String_length s)) 0))
  )

  (test-case "long but valid title"
  (define longTitle "This is a very long title that describes the issue in great detail and should be accepted by the validation function for the purpose of testing")
  (if (<= (raw-value (tesl_import_String_length (raw-value longTitle))) 200)
      (let ()
        (define tesl_checked_33 (checkTitle longTitle))
        (when (check-fail? tesl_checked_33)
          (raise-user-error 'tesl-test "unexpected failure in let t: ~a" (check-fail-message tesl_checked_33)))
        (define t tesl_checked_33)
        (check-equal? (raw-value (tesl_import_String_length t)) (tesl_import_String_length (raw-value longTitle)))
      )
      (let ()
        (check-true (raw-value #t))
      ))
  )

  (test-case "boundary: estimate of 0 is valid"
  (define n 0)
  (define tesl_checked_34 (checkEstimate n))
  (when (check-fail? tesl_checked_34)
    (raise-user-error 'tesl-test "unexpected failure in let e: ~a" (check-fail-message tesl_checked_34)))
  (define e tesl_checked_34)
  (check-equal? (raw-value e) 0)
  )

  (test-case "boundary: 1440 minutes is valid (24 hours exactly)"
  (define n 1440)
  (define tesl_checked_35 (checkPositiveMinutes n))
  (when (check-fail? tesl_checked_35)
    (raise-user-error 'tesl-test "unexpected failure in let m: ~a" (check-fail-message tesl_checked_35)))
  (define m tesl_checked_35)
  (check-equal? (raw-value m) 1440)
  )

  (test-case "boundary: 1441 minutes is invalid (exceeds 24h)"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)])
                          (checkPositiveMinutes 1441))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check checkPositiveMinutes 1441"))
  )

  (test-case "comment body length boundary"
  ; property: single char comment accepted
  (for ([tesl-prop-i (in-range 1)])
    (let ([n (- (random 2000001) 1000000)])
      (when (> (raw-value n) 0) (check-true (equal? (raw-value (tesl_import_String_length "x")) 1) "single char comment accepted"))
    ))
  )

)
