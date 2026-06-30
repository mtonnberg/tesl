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
  (only-in tesl/tesl/prelude String Bool Int)
  (only-in tesl/tesl/uuid IsUuid [UUID.validate tesl_import_UUID_validate])
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.slice tesl_import_String_slice])
)


(provide validateId describeUuid uuidLength hasVersionDigit checkUuidFormat validateId-signature uuidLength-signature hasVersionDigit-signature describeUuid-signature checkUuidFormat-signature)

(define/pow
  (validateId [s : String])
  #:returns String
  (thsl-src! "example/learn/lesson56-uuid.tesl" 87 (list (cons 's *s)) (lambda () (raw-value (tesl_import_UUID_validate *s)))))

(define/pow
  (uuidLength [s : String])
  #:returns Integer
  (thsl-src! "example/learn/lesson56-uuid.tesl" 96 (list (cons 's *s)) (lambda () (raw-value (tesl_import_String_length *s)))))

(define/pow
  (hasVersionDigit [s : String] [expected : String])
  #:returns Boolean
  (thsl-src! "example/learn/lesson56-uuid.tesl" 103 (list (cons 's *s) (cons 'expected *expected)) (lambda () (equal? (raw-value (tesl_import_String_slice *s 14 15)) *expected))))

(define/pow
  (describeUuid [s : String])
  #:returns String
  (let ([version (thsl-src! "example/learn/lesson56-uuid.tesl" 107 (list (cons 's *s)) (lambda () (raw-value (tesl_import_String_slice *s 14 15))))]) (thsl-src! "example/learn/lesson56-uuid.tesl" 108 (list (cons 'version *version) (cons 's *s)) (lambda () (if (equal? (raw-value version) "4") (raw-value "UUID v4 (random)") (if (equal? (raw-value version) "7") (raw-value "UUID v7 (time-ordered)") (raw-value "UUID (unknown version)")))))))

(define/pow
  (checkUuidFormat [s : String])
  #:returns Boolean
  (thsl-src! "example/learn/lesson56-uuid.tesl" 117 (list (cons 's *s)) (lambda () (equal? (raw-value (tesl_import_String_length *s)) 36))))

(module+ test
  (require rackunit)
  (test-case "UUID.validate accepts a valid v4 UUID"
  (define id (thsl-src! "example/learn/lesson56-uuid.tesl" 182 (list) (lambda () "a8098c1a-f86e-4f11-8d1c-6e9e14b9d8e2")))
  (define result (thsl-src! "example/learn/lesson56-uuid.tesl" 183 (list (cons 'id id)) (lambda () (validateId id))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 184 (list (cons 'result result) (cons 'id id)) (lambda () result))) id)
  )

  (test-case "UUID.validate accepts a valid v7 UUID"
  (define id (thsl-src! "example/learn/lesson56-uuid.tesl" 188 (list) (lambda () "018e7a30-a1b2-7c3d-8e4f-123456789abc")))
  (define result (thsl-src! "example/learn/lesson56-uuid.tesl" 189 (list (cons 'id id)) (lambda () (validateId id))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 190 (list (cons 'result result) (cons 'id id)) (lambda () result))) id)
  )

  (test-case "UUID.validate accepts all-zeros UUID"
  (define id (thsl-src! "example/learn/lesson56-uuid.tesl" 194 (list) (lambda () "00000000-0000-0000-0000-000000000000")))
  (define result (thsl-src! "example/learn/lesson56-uuid.tesl" 195 (list (cons 'id id)) (lambda () (validateId id))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 196 (list (cons 'result result) (cons 'id id)) (lambda () (tesl_import_String_length (raw-value result))))) 36)
  )

  (test-case "UUID.validate accepts uppercase hex UUID"
  (define id (thsl-src! "example/learn/lesson56-uuid.tesl" 200 (list) (lambda () "A8098C1A-F86E-4F11-8D1C-6E9E14B9D8E2")))
  (define result (thsl-src! "example/learn/lesson56-uuid.tesl" 201 (list (cons 'id id)) (lambda () (validateId id))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 202 (list (cons 'result result) (cons 'id id)) (lambda () (tesl_import_String_length (raw-value result))))) 36)
  )

  (test-case "UUID.validate rejects plain string"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson56-uuid.tesl" 206 (list) (lambda ()
                          ((validateId "not-a-uuid") (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (validateId \"not-a-uuid\") (list)"))
  )

  (test-case "UUID.validate rejects empty string"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson56-uuid.tesl" 210 (list) (lambda ()
                          ((validateId "") (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (validateId \"\") (list)"))
  )

  (test-case "UUID.validate rejects too-short UUID"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson56-uuid.tesl" 214 (list) (lambda ()
                          ((validateId "a8098c1a-f86e-4f11-8d1c") (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (validateId \"a8098c1a-f86e-4f11-8d1c\") (list)"))
  )

  (test-case "UUID.validate rejects UUID with extra characters"
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson56-uuid.tesl" 218 (list) (lambda ()
                          ((validateId "a8098c1a-f86e-4f11-8d1c-6e9e14b9d8e2-extra") (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (validateId \"a8098c1a-f86e-4f11-8d1c-6e9e14b9d8e2-extra\") (list)"))
  )

  (test-case "uuidLength of any UUID is 36"
  (define v4 (thsl-src! "example/learn/lesson56-uuid.tesl" 222 (list) (lambda () "550e8400-e29b-41d4-a716-446655440000")))
  (define v7 (thsl-src! "example/learn/lesson56-uuid.tesl" 223 (list (cons 'v4 v4)) (lambda () "018e7a30-a1b2-7c3d-8e4f-123456789abc")))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 224 (list (cons 'v7 v7) (cons 'v4 v4)) (lambda () (uuidLength v4)))) 36)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 225 (list (cons 'v7 v7) (cons 'v4 v4)) (lambda () (uuidLength v7)))) 36)
  )

  (test-case "hasVersionDigit detects v4 at position 14"
  (define v4 (thsl-src! "example/learn/lesson56-uuid.tesl" 229 (list) (lambda () "550e8400-e29b-41d4-a716-446655440000")))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 230 (list (cons 'v4 v4)) (lambda () (hasVersionDigit v4 "4")))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 231 (list (cons 'v4 v4)) (lambda () (hasVersionDigit v4 "7")))) #f)
  )

  (test-case "hasVersionDigit detects v7 at position 14"
  (define v7 (thsl-src! "example/learn/lesson56-uuid.tesl" 235 (list) (lambda () "018e7a30-a1b2-7c3d-8e4f-123456789abc")))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 236 (list (cons 'v7 v7)) (lambda () (hasVersionDigit v7 "7")))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 237 (list (cons 'v7 v7)) (lambda () (hasVersionDigit v7 "4")))) #f)
  )

  (test-case "describeUuid recognizes v4"
  (define v4 (thsl-src! "example/learn/lesson56-uuid.tesl" 241 (list) (lambda () "550e8400-e29b-41d4-a716-446655440000")))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 242 (list (cons 'v4 v4)) (lambda () (describeUuid v4)))) "UUID v4 (random)")
  )

  (test-case "describeUuid recognizes v7"
  (define v7 (thsl-src! "example/learn/lesson56-uuid.tesl" 246 (list) (lambda () "018e7a30-a1b2-7c3d-8e4f-123456789abc")))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 247 (list (cons 'v7 v7)) (lambda () (describeUuid v7)))) "UUID v7 (time-ordered)")
  )

  (test-case "checkUuidFormat accepts 36-char UUID"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 251 (list) (lambda () (checkUuidFormat "550e8400-e29b-41d4-a716-446655440000")))) #t)
  )

  (test-case "checkUuidFormat rejects short string"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 255 (list) (lambda () (checkUuidFormat "550e8400-e29b-41d4")))) #f)
  )

  (test-case "UUID hyphens are at correct positions"
  (define v4 (thsl-src! "example/learn/lesson56-uuid.tesl" 259 (list) (lambda () "550e8400-e29b-41d4-a716-446655440000")))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 260 (list (cons 'v4 v4)) (lambda () (raw-value (tesl_import_String_slice (raw-value v4) 8 9))))) "-")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 261 (list (cons 'v4 v4)) (lambda () (raw-value (tesl_import_String_slice (raw-value v4) 13 14))))) "-")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 262 (list (cons 'v4 v4)) (lambda () (raw-value (tesl_import_String_slice (raw-value v4) 18 19))))) "-")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 263 (list (cons 'v4 v4)) (lambda () (raw-value (tesl_import_String_slice (raw-value v4) 23 24))))) "-")
  )

)
