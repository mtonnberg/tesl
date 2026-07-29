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
  (only-in tesl/tesl/list [List.length tesl_import_List_length] [List.head tesl_import_List_head])
  (only-in tesl/tesl/regex [Regex.matches tesl_import_Regex_matches] [Regex.find tesl_import_Regex_find] [Regex.findAll tesl_import_Regex_findAll] [Regex.captures tesl_import_Regex_captures] [Regex.replace tesl_import_Regex_replace] [Regex.split tesl_import_Regex_split])
)


(provide ValidEmail ValidSlug requireEmail requireSlug deliverTo permalink emailDomain extractTicketIds redactDigits splitTags requireEmail-signature deliverTo-signature requireSlug-signature permalink-signature emailDomain-signature extractTicketIds-signature redactDigits-signature splitTags-signature)

(define ValidEmail 'ValidEmail)
(define ValidSlug 'ValidSlug)

(define-checker
  (requireEmail [raw : String])
  #:returns [raw : String ::: (ValidEmail raw)]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 58 (list (cons 'raw *raw)) (lambda () (if (raw-value (tesl_import_Regex_matches "^[^@ ]+@[^@ ]+[.][a-z]{2,}$" *raw)) (accept (ValidEmail raw) #:value *raw) (reject "not a valid email address" #:http-code 400)))))

(define/pow
  (deliverTo [address : String ::: (ValidEmail address)])
  #:returns String
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 66 (list (cons 'address *address)) (lambda () (format "queued mail for ~a" (tesl-display-val *address)))))

(define-checker
  (requireSlug [raw : String])
  #:returns [raw : String ::: (ValidSlug raw)]
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 71 (list (cons 'raw *raw)) (lambda () (if (raw-value (tesl_import_Regex_matches "^[a-z0-9]+(?:-[a-z0-9]+)*$" *raw)) (accept (ValidSlug raw) #:value *raw) (reject "a slug is lowercase words joined by single hyphens" #:http-code 400)))))

(define/pow
  (permalink [slug : String ::: (ValidSlug slug)])
  #:returns String
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 77 (list (cons 'slug *slug)) (lambda () (format "https://example.com/p/~a" (tesl-display-val *slug)))))

(define/pow
  (emailDomain [address : String ::: (ValidEmail address)])
  #:returns (Maybe String)
  (thsl-src-control! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 145 (list (cons 'address *address)) (lambda () (let ([tesl-case-0 (raw-value (tesl_import_Regex_captures "^[^@ ]+@([^@ ]+)$" *address))]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 146 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([parts (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 147 (list (cons 'parts parts)) (lambda () (raw-value (raw-value (tesl_import_List_head *parts))))))])))))

(define/pow
  (extractTicketIds [body : String])
  #:returns (List String)
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 155 (list (cons 'body *body)) (lambda () (raw-value (tesl_import_Regex_findAll "TESL-[0-9]+" *body)))))

(define/pow
  (redactDigits [s : String])
  #:returns String
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 162 (list (cons 's *s)) (lambda () (raw-value (tesl_import_Regex_replace "[0-9]" *s "#")))))

(define/pow
  (splitTags [s : String])
  #:returns (List String)
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 166 (list (cons 's *s)) (lambda () (raw-value (tesl_import_Regex_split "[,;] ?" *s)))))

(define/pow
  (hasThreeDigits [s : String])
  #:returns Boolean
  (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 186 (list (cons 's *s)) (lambda () (raw-value (tesl_import_Regex_matches "\\d{3}" *s)))))

(module+ test
  (require rackunit)
  (test-case "email validation mints a fact"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 193 (list) (lambda () "bob@example.com")))
  (define tesl-checked-1 (requireEmail raw))
  (when (check-fail? tesl-checked-1)
    (raise-user-error 'tesl-test "unexpected failure in let good: ~a" (check-fail-message tesl-checked-1)))
  (define good tesl-checked-1)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 195 (list (cons 'good good) (cons 'raw raw)) (lambda () (deliverTo good)))) "queued mail for bob@example.com")
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 196 (list (cons 'good good) (cons 'raw raw)) (lambda () (emailDomain good)))) (raw-value (Something "example.com")))
  (define noAt (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 199 (list (cons 'good good) (cons 'raw raw)) (lambda () "not-an-email")))
  (define noTld (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 200 (list (cons 'noAt noAt) (cons 'good good) (cons 'raw raw)) (lambda () "bob@example")))
  (define spaced (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 201 (list (cons 'noTld noTld) (cons 'noAt noAt) (cons 'good good) (cons 'raw raw)) (lambda () "bob @example.com")))
  (define noLocal (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 202 (list (cons 'spaced spaced) (cons 'noTld noTld) (cons 'noAt noAt) (cons 'good good) (cons 'raw raw)) (lambda () "@example.com")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 203 (list (cons 'noLocal noLocal) (cons 'spaced spaced) (cons 'noTld noTld) (cons 'noAt noAt) (cons 'good good) (cons 'raw raw)) (lambda ()
                          (requireEmail noAt))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check requireEmail noAt"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 204 (list (cons 'noLocal noLocal) (cons 'spaced spaced) (cons 'noTld noTld) (cons 'noAt noAt) (cons 'good good) (cons 'raw raw)) (lambda ()
                          (requireEmail noTld))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check requireEmail noTld"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 205 (list (cons 'noLocal noLocal) (cons 'spaced spaced) (cons 'noTld noTld) (cons 'noAt noAt) (cons 'good good) (cons 'raw raw)) (lambda ()
                          (requireEmail spaced))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check requireEmail spaced"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 206 (list (cons 'noLocal noLocal) (cons 'spaced spaced) (cons 'noTld noTld) (cons 'noAt noAt) (cons 'good good) (cons 'raw raw)) (lambda ()
                          (requireEmail noLocal))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check requireEmail noLocal"))
    ))
  )

  (test-case "slug validation mints a fact"
    (call-with-fresh-memory-db '() (lambda ()
  (define raw (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 210 (list) (lambda () "hello-world-2")))
  (define tesl-checked-2 (requireSlug raw))
  (when (check-fail? tesl-checked-2)
    (raise-user-error 'tesl-test "unexpected failure in let good: ~a" (check-fail-message tesl-checked-2)))
  (define good tesl-checked-2)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 212 (list (cons 'good good) (cons 'raw raw)) (lambda () (permalink good)))) "https://example.com/p/hello-world-2")
  (define upper (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 214 (list (cons 'good good) (cons 'raw raw)) (lambda () "Hello")))
  (define doubleHyphen (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 215 (list (cons 'upper upper) (cons 'good good) (cons 'raw raw)) (lambda () "hello--world")))
  (define leading (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 216 (list (cons 'doubleHyphen doubleHyphen) (cons 'upper upper) (cons 'good good) (cons 'raw raw)) (lambda () "-hello")))
  (define trailing (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 217 (list (cons 'leading leading) (cons 'doubleHyphen doubleHyphen) (cons 'upper upper) (cons 'good good) (cons 'raw raw)) (lambda () "hello-")))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 218 (list (cons 'trailing trailing) (cons 'leading leading) (cons 'doubleHyphen doubleHyphen) (cons 'upper upper) (cons 'good good) (cons 'raw raw)) (lambda ()
                          (requireSlug upper))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check requireSlug upper"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 219 (list (cons 'trailing trailing) (cons 'leading leading) (cons 'doubleHyphen doubleHyphen) (cons 'upper upper) (cons 'good good) (cons 'raw raw)) (lambda ()
                          (requireSlug doubleHyphen))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check requireSlug doubleHyphen"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 220 (list (cons 'trailing trailing) (cons 'leading leading) (cons 'doubleHyphen doubleHyphen) (cons 'upper upper) (cons 'good good) (cons 'raw raw)) (lambda ()
                          (requireSlug leading))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check requireSlug leading"))
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 221 (list (cons 'trailing trailing) (cons 'leading leading) (cons 'doubleHyphen doubleHyphen) (cons 'upper upper) (cons 'good good) (cons 'raw raw)) (lambda ()
                          (requireSlug trailing))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: check requireSlug trailing"))
    ))
  )

  (test-case "matches is unanchored unless you anchor it"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 225 (list) (lambda () (raw-value (tesl_import_Regex_matches "[0-9]+" "abc123"))))) #t)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 226 (list) (lambda () (raw-value (tesl_import_Regex_matches "^[0-9]+$" "abc123"))))) #f)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 227 (list) (lambda () (raw-value (tesl_import_Regex_matches "^[0-9]+$" "123"))))) #t)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 228 (list) (lambda () (hasThreeDigits "ab123")))) #t)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 229 (list) (lambda () (hasThreeDigits "ab12")))) #f)
    ))
  )

  (test-case "find, findAll, captures"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 233 (list) (lambda () (raw-value (tesl_import_Regex_find "[0-9]+" "a12b345"))))) (raw-value (Something "12")))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 234 (list) (lambda () (raw-value (tesl_import_Regex_find "[0-9]+" "abc"))))) Nothing)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 235 (list) (lambda () (extractTicketIds "see TESL-12 and TESL-345")))) (list "TESL-12" "TESL-345"))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 236 (list) (lambda () (raw-value (tesl_import_List_length (raw-value (extractTicketIds "nothing here"))))))) 0)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 237 (list) (lambda () (raw-value (tesl_import_Regex_captures "^([a-z]+)-([0-9]+)$" "ab-12"))))) (raw-value (Something (list "ab" "12"))))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 238 (list) (lambda () (raw-value (tesl_import_Regex_captures "^([a-z]+)-([0-9]+)$" "nope"))))) Nothing)
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 240 (list) (lambda () (raw-value (tesl_import_Regex_captures "^[a-z]+$" "ab"))))) (raw-value (Something (list))))
    ))
  )

  (test-case "replace and split"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 244 (list) (lambda () (redactDigits "card 4111 1111")))) "card #### ####")
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 245 (list) (lambda () (redactDigits "no digits")))) "no digits")
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 246 (list) (lambda () (splitTags "a, b;c")))) (list "a" "b" "c"))
  (check-equal? (raw-value (thsl-src! "/home/mikael/repos_wsl/tesl-github/tesl/example/learn/lesson75-regex-validation.tesl" 247 (list) (lambda () (splitTags "single")))) (list "single"))
    ))
  )

)
