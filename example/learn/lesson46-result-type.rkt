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
  (only-in tesl/tesl/prelude Bool Int String)
  (only-in tesl/tesl/result Result Ok Err)
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/string [String.toInt tesl_import_String_toInt] [String.isEmpty tesl_import_String_isEmpty])
  (only-in tesl/tesl/int [Int.toString tesl_import_Int_toString] [Int.nonZero tesl_import_Int_nonZero] [Int.divide tesl_import_Int_divide])
)


(provide divide parseInt validateAge processAge fetchUser runPipeline UserError NotFound Forbidden InvalidInput safeDivideOrDefault okOrDefault isErr divide-signature safeDivideOrDefault-signature okOrDefault-signature isErr-signature parseInt-signature validateAge-signature processAge-signature fetchUser-signature runPipeline-signature)

(define/pow
  (divide [a : Integer] [b : Integer])
  #:returns (Result Integer String)
  (thsl-src! "example/learn/lesson46-result-type.tesl" 61 (list (cons 'a *a) (cons 'b *b)) (lambda () (if (equal? *b 0) (raw-value (raw-value (Err "division by zero"))) (let/check ([tesl_checked_0 (tesl_import_Int_nonZero b)]) (let ([safeb tesl_checked_0]) (raw-value (raw-value (Ok (tesl_import_Int_divide *a safeb))))))))))

(define/pow
  (safeDivideOrDefault [a : Integer] [b : Integer] [fallback : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson46-result-type.tesl" 69 (list (cons 'a *a) (cons 'b *b) (cons 'fallback *fallback)) (lambda () (let ([tesl_case_1 (raw-value (divide a b))]) (cond [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Ok)) (let ([n (hash-ref (adt-value-fields *tesl_case_1) 'value)]) *n)] [(and (adt-value? *tesl_case_1) (eq? (adt-value-variant *tesl_case_1) 'Err)) *fallback])))))

(define/pow
  (okOrDefault [r : (Result Integer String)] [default : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson46-result-type.tesl" 75 (list (cons 'r *r) (cons 'default *default)) (lambda () (let ([tesl_case_2 *r]) (cond [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Ok)) (let ([n (hash-ref (adt-value-fields *tesl_case_2) 'value)]) *n)] [(and (adt-value? *tesl_case_2) (eq? (adt-value-variant *tesl_case_2) 'Err)) *default])))))

(define/pow
  (isErr [r : (Result Integer String)])
  #:returns Boolean
  (thsl-src! "example/learn/lesson46-result-type.tesl" 81 (list (cons 'r *r)) (lambda () (let ([tesl_case_3 *r]) (cond [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Ok)) (raw-value #f)] [(and (adt-value? *tesl_case_3) (eq? (adt-value-variant *tesl_case_3) 'Err)) (raw-value #t)])))))

(define/pow
  (parseInt [raw : String])
  #:returns (Result Integer String)
  (thsl-src! "example/learn/lesson46-result-type.tesl" 89 (list (cons 'raw *raw)) (lambda () (if (tesl_import_String_isEmpty *raw) (raw-value (raw-value (Err "input is empty"))) (let ([tesl_case_4 (raw-value (tesl_import_String_toInt *raw))]) (cond [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Nothing)) (raw-value (raw-value (Err "not a valid integer")))] [(and (adt-value? *tesl_case_4) (eq? (adt-value-variant *tesl_case_4) 'Something)) (let ([n (hash-ref (adt-value-fields *tesl_case_4) 'value)]) (raw-value (raw-value (Ok *n))))]))))))

(define/pow
  (validateAge [n : Integer])
  #:returns (Result Integer String)
  (thsl-src! "example/learn/lesson46-result-type.tesl" 100 (list (cons 'n *n)) (lambda () (if (< *n 0) (raw-value (raw-value (Err "age cannot be negative"))) (if (> *n 150) (raw-value (raw-value (Err "age seems unrealistically large"))) (raw-value (raw-value (Ok *n))))))))

(define/pow
  (processAge [raw : String])
  #:returns (Result Integer String)
  (thsl-src! "example/learn/lesson46-result-type.tesl" 111 (list (cons 'raw *raw)) (lambda () (let ([tesl_case_5 (raw-value (parseInt raw))]) (cond [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Err)) (let ([e (hash-ref (adt-value-fields *tesl_case_5) 'error)]) (raw-value (raw-value (Err *e))))] [(and (adt-value? *tesl_case_5) (eq? (adt-value-variant *tesl_case_5) 'Ok)) (let ([n (hash-ref (adt-value-fields *tesl_case_5) 'value)]) (raw-value (validateAge *n)))])))))

(define-adt UserError
  [NotFound [id : String]]
  [Forbidden [user : String]]
  [InvalidInput [message : String]]
)

(define/pow
  (fetchUser [userId : String] [requestingUser : String])
  #:returns (Result String UserError)
  (thsl-src! "example/learn/lesson46-result-type.tesl" 124 (list (cons 'userId *userId) (cons 'requestingUser *requestingUser)) (lambda () (if (tesl_import_String_isEmpty *userId) (raw-value (raw-value (Err (InvalidInput "userId cannot be empty")))) (if (and (equal? *userId "admin") (not (equal? *requestingUser "admin"))) (raw-value (raw-value (Err (Forbidden requestingUser)))) (if (equal? *userId "ghost") (raw-value (raw-value (Err (NotFound userId)))) (raw-value (raw-value (Ok *userId)))))))))

(define/pow
  (describeError [err : UserError])
  #:returns String
  (thsl-src! "example/learn/lesson46-result-type.tesl" 136 (list (cons 'err *err)) (lambda () (let ([tesl_case_6 *err]) (cond [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'NotFound)) (let ([id (hash-ref (adt-value-fields *tesl_case_6) 'id)]) (raw-value (format "no user with id ~a" (tesl-display-val *id))))] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'Forbidden)) (let ([user (hash-ref (adt-value-fields *tesl_case_6) 'user)]) (raw-value (format "user ~a is not allowed to do this" (tesl-display-val *user))))] [(and (adt-value? *tesl_case_6) (eq? (adt-value-variant *tesl_case_6) 'InvalidInput)) (let ([msg (hash-ref (adt-value-fields *tesl_case_6) 'message)]) (raw-value (format "bad input: ~a" (tesl-display-val *msg))))])))))

(define/pow
  (runPipeline [rawAge : String] [rawId : String])
  #:returns (Result String String)
  (thsl-src! "example/learn/lesson46-result-type.tesl" 146 (list (cons 'rawAge *rawAge) (cons 'rawId *rawId)) (lambda () (let ([tesl_case_7 (raw-value (processAge rawAge))]) (cond [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Err)) (let ([e (hash-ref (adt-value-fields *tesl_case_7) 'error)]) (raw-value (raw-value (Err *e))))] [(and (adt-value? *tesl_case_7) (eq? (adt-value-variant *tesl_case_7) 'Ok)) (let ([age (hash-ref (adt-value-fields *tesl_case_7) 'value)]) (if (< *age 18) (raw-value (raw-value (Err "must be 18 or older"))) (if (tesl_import_String_isEmpty *rawId) (raw-value (raw-value (Err "id is required"))) (raw-value (raw-value (Ok (format "user ~a (age ~a) is valid" (tesl-display-val *rawId) (tesl-display-val (raw-value (tesl_import_Int_toString *age))))))))))])))))

(define/pow
  (okIntOrDefault [r : (Result Integer String)] [d : Integer])
  #:returns Integer
  (thsl-src! "example/learn/lesson46-result-type.tesl" 161 (list (cons 'r *r) (cons 'd *d)) (lambda () (let ([tesl_case_8 *r]) (cond [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Ok)) (let ([n (hash-ref (adt-value-fields *tesl_case_8) 'value)]) *n)] [(and (adt-value? *tesl_case_8) (eq? (adt-value-variant *tesl_case_8) 'Err)) *d])))))

(define/pow
  (errMsgOrEmpty [r : (Result Integer String)])
  #:returns String
  (thsl-src! "example/learn/lesson46-result-type.tesl" 166 (list (cons 'r *r)) (lambda () (let ([tesl_case_9 *r]) (cond [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Ok)) (raw-value "")] [(and (adt-value? *tesl_case_9) (eq? (adt-value-variant *tesl_case_9) 'Err)) (let ([e (hash-ref (adt-value-fields *tesl_case_9) 'error)]) *e)])))))

(define/pow
  (isOkResult [r : (Result Integer String)])
  #:returns Boolean
  (thsl-src! "example/learn/lesson46-result-type.tesl" 171 (list (cons 'r *r)) (lambda () (let ([tesl_case_10 *r]) (cond [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Ok)) (raw-value #t)] [(and (adt-value? *tesl_case_10) (eq? (adt-value-variant *tesl_case_10) 'Err)) (raw-value #f)])))))

(define/pow
  (isErrUserResult [r : (Result String UserError)])
  #:returns Boolean
  (thsl-src! "example/learn/lesson46-result-type.tesl" 176 (list (cons 'r *r)) (lambda () (let ([tesl_case_11 *r]) (cond [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Ok)) (raw-value #f)] [(and (adt-value? *tesl_case_11) (eq? (adt-value-variant *tesl_case_11) 'Err)) (raw-value #t)])))))

(define/pow
  (isErrStrResult [r : (Result String String)])
  #:returns Boolean
  (thsl-src! "example/learn/lesson46-result-type.tesl" 181 (list (cons 'r *r)) (lambda () (let ([tesl_case_12 *r]) (cond [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Ok)) (raw-value #f)] [(and (adt-value? *tesl_case_12) (eq? (adt-value-variant *tesl_case_12) 'Err)) (raw-value #t)])))))

(module+ test
  (require rackunit)
  (test-case "Ok carries the success value"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 186 (list) (lambda () (okIntOrDefault (divide 10 2) 0)))) 5)
  )

  (test-case "Err carries the failure description"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 190 (list) (lambda () (errMsgOrEmpty (divide 10 0))))) "division by zero")
  )

  (test-case "divide 10 by 2 is Ok"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 194 (list) (lambda () (isOkResult (divide 10 2))))) #t)
  )

  (test-case "divide by zero is Err"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 198 (list) (lambda () (isErr (divide 10 0))))) #t)
  )

  (test-case "parseInt succeeds on a valid number"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 202 (list) (lambda () (okIntOrDefault (parseInt "42") 0)))) 42)
  )

  (test-case "parseInt fails on empty string"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 206 (list) (lambda () (errMsgOrEmpty (parseInt ""))))) "input is empty")
  )

  (test-case "parseInt fails on non-numeric input"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 210 (list) (lambda () (isErr (parseInt "hello"))))) #t)
  )

  (test-case "validateAge rejects negatives"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 214 (list) (lambda () (isErr (validateAge -1))))) #t)
  )

  (test-case "validateAge rejects unrealistic values"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 218 (list) (lambda () (isErr (validateAge 200))))) #t)
  )

  (test-case "validateAge accepts a normal value"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 222 (list) (lambda () (okIntOrDefault (validateAge 30) 0)))) 30)
  )

  (test-case "processAge chains parse then validate"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 226 (list) (lambda () (okIntOrDefault (processAge "25") 0)))) 25)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 227 (list) (lambda () (isErr (processAge "abc"))))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 228 (list) (lambda () (isErr (processAge "-5"))))) #t)
  )

  (test-case "fetchUser ok returns the userId"
  (define r (thsl-src! "example/learn/lesson46-result-type.tesl" 232 (list) (lambda () (fetchUser "bob" "alice"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 233 (list (cons 'r r)) (lambda () (isErrUserResult r)))) #f)
  )

  (test-case "fetchUser empty userId is Err"
  (define r (thsl-src! "example/learn/lesson46-result-type.tesl" 237 (list) (lambda () (fetchUser "" "alice"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 238 (list (cons 'r r)) (lambda () (isErrUserResult r)))) #t)
  )

  (test-case "fetchUser ghost is Err (not found)"
  (define r (thsl-src! "example/learn/lesson46-result-type.tesl" 242 (list) (lambda () (fetchUser "ghost" "alice"))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 243 (list (cons 'r r)) (lambda () (isErrUserResult r)))) #t)
  )

  (test-case "safeDivideOrDefault uses fallback on error"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 247 (list) (lambda () (safeDivideOrDefault 10 0 99)))) 99)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 248 (list) (lambda () (safeDivideOrDefault 10 2 99)))) 5)
  )

  (test-case "runPipeline end-to-end success"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 252 (list) (lambda () (isErrStrResult (runPipeline "25" "alice"))))) #f)
  )

  (test-case "runPipeline fails on underage"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson46-result-type.tesl" 256 (list) (lambda () (isErrStrResult (runPipeline "15" "alice"))))) #t)
  )

)
