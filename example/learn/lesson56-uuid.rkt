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
  (only-in tesl/tesl/uuid uuid IsUuid [UUID.v4 tesl_import_UUID_v4] [UUID.v7 tesl_import_UUID_v7] [UUID.validate tesl_import_UUID_validate])
  (only-in tesl/tesl/string [String.length tesl_import_String_length] [String.slice tesl_import_String_slice])
)


(provide validateId describeUuid uuidLength hasVersionDigit checkUuidFormat generateV4 generateV7 validateId-signature generateV4-signature generateV7-signature uuidLength-signature hasVersionDigit-signature describeUuid-signature checkUuidFormat-signature)

(define/pow
  (validateId [s : String])
  #:returns String
  (thsl-src! "example/learn/lesson56-uuid.tesl" 90 (list (cons 's *s)) (lambda () (raw-value (tesl_import_UUID_validate *s)))))

(define/pow
  (generateV4)
  #:capabilities [uuid]
  #:returns String
  (thsl-src! "example/learn/lesson56-uuid.tesl" 99 (list) (lambda () (raw-value (tesl_import_UUID_v4)))))

(define/pow
  (generateV7)
  #:capabilities [uuid]
  #:returns String
  (thsl-src! "example/learn/lesson56-uuid.tesl" 102 (list) (lambda () (raw-value (tesl_import_UUID_v7)))))

(define/pow
  (uuidLength [s : String])
  #:returns Integer
  (thsl-src! "example/learn/lesson56-uuid.tesl" 111 (list (cons 's *s)) (lambda () (raw-value (tesl_import_String_length *s)))))

(define/pow
  (hasVersionDigit [s : String] [expected : String])
  #:returns Boolean
  (thsl-src! "example/learn/lesson56-uuid.tesl" 118 (list (cons 's *s) (cons 'expected *expected)) (lambda () (tesl-equal? (raw-value (tesl_import_String_slice *s 14 15)) *expected))))

(define/pow
  (describeUuid [s : String])
  #:returns String
  (let ([version (thsl-src! "example/learn/lesson56-uuid.tesl" 122 (list (cons 's *s)) (lambda () (raw-value (tesl_import_String_slice *s 14 15))))]) (thsl-src! "example/learn/lesson56-uuid.tesl" 123 (list (cons 'version *version) (cons 's *s)) (lambda () (if (tesl-equal? (raw-value version) "4") (raw-value "UUID v4 (random)") (if (tesl-equal? (raw-value version) "7") (raw-value "UUID v7 (time-ordered)") (raw-value "UUID (unknown version)")))))))

(define/pow
  (checkUuidFormat [s : String])
  #:returns Boolean
  (thsl-src! "example/learn/lesson56-uuid.tesl" 132 (list (cons 's *s)) (lambda () (tesl-equal? (raw-value (tesl_import_String_length *s)) 36))))

(module+ test
  (require rackunit)
  (test-case "UUID.validate accepts a valid v4 UUID"
    (call-with-fresh-memory-db '() (lambda ()
  (define id (thsl-src! "example/learn/lesson56-uuid.tesl" 197 (list) (lambda () "a8098c1a-f86e-4f11-8d1c-6e9e14b9d8e2")))
  (define result (thsl-src! "example/learn/lesson56-uuid.tesl" 198 (list (cons 'id id)) (lambda () (validateId id))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 199 (list (cons 'result result) (cons 'id id)) (lambda () result))) id)
    ))
  )

  (test-case "UUID.validate accepts a valid v7 UUID"
    (call-with-fresh-memory-db '() (lambda ()
  (define id (thsl-src! "example/learn/lesson56-uuid.tesl" 203 (list) (lambda () "018e7a30-a1b2-7c3d-8e4f-123456789abc")))
  (define result (thsl-src! "example/learn/lesson56-uuid.tesl" 204 (list (cons 'id id)) (lambda () (validateId id))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 205 (list (cons 'result result) (cons 'id id)) (lambda () result))) id)
    ))
  )

  (test-case "UUID.validate accepts all-zeros UUID"
    (call-with-fresh-memory-db '() (lambda ()
  (define id (thsl-src! "example/learn/lesson56-uuid.tesl" 209 (list) (lambda () "00000000-0000-0000-0000-000000000000")))
  (define result (thsl-src! "example/learn/lesson56-uuid.tesl" 210 (list (cons 'id id)) (lambda () (validateId id))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 211 (list (cons 'result result) (cons 'id id)) (lambda () (tesl_import_String_length (raw-value result))))) 36)
    ))
  )

  (test-case "UUID.validate accepts uppercase hex UUID"
    (call-with-fresh-memory-db '() (lambda ()
  (define id (thsl-src! "example/learn/lesson56-uuid.tesl" 215 (list) (lambda () "A8098C1A-F86E-4F11-8D1C-6E9E14B9D8E2")))
  (define result (thsl-src! "example/learn/lesson56-uuid.tesl" 216 (list (cons 'id id)) (lambda () (validateId id))))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 217 (list (cons 'result result) (cons 'id id)) (lambda () (tesl_import_String_length (raw-value result))))) 36)
    ))
  )

  (test-case "UUID.validate rejects plain string"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson56-uuid.tesl" 221 (list) (lambda ()
                          ((validateId "not-a-uuid") (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (validateId \"not-a-uuid\") (list)"))
    ))
  )

  (test-case "UUID.validate rejects empty string"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson56-uuid.tesl" 225 (list) (lambda ()
                          ((validateId "") (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (validateId \"\") (list)"))
    ))
  )

  (test-case "UUID.validate rejects too-short UUID"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson56-uuid.tesl" 229 (list) (lambda ()
                          ((validateId "a8098c1a-f86e-4f11-8d1c") (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (validateId \"a8098c1a-f86e-4f11-8d1c\") (list)"))
    ))
  )

  (test-case "UUID.validate rejects UUID with extra characters"
    (call-with-fresh-memory-db '() (lambda ()
  (let ([tesl-ef-result (with-handlers ([exn:fail? (lambda (e) 'tesl-exception)]) (thsl-src! "example/learn/lesson56-uuid.tesl" 233 (list) (lambda ()
                          ((validateId "a8098c1a-f86e-4f11-8d1c-6e9e14b9d8e2-extra") (list)))))])
    (check-true (or (eq? tesl-ef-result 'tesl-exception) (check-fail? tesl-ef-result))
                "expected failure: (validateId \"a8098c1a-f86e-4f11-8d1c-6e9e14b9d8e2-extra\") (list)"))
    ))
  )

  (test-case "uuidLength of any UUID is 36"
    (call-with-fresh-memory-db '() (lambda ()
  (define v4 (thsl-src! "example/learn/lesson56-uuid.tesl" 237 (list) (lambda () "550e8400-e29b-41d4-a716-446655440000")))
  (define v7 (thsl-src! "example/learn/lesson56-uuid.tesl" 238 (list (cons 'v4 v4)) (lambda () "018e7a30-a1b2-7c3d-8e4f-123456789abc")))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 239 (list (cons 'v7 v7) (cons 'v4 v4)) (lambda () (uuidLength v4)))) 36)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 240 (list (cons 'v7 v7) (cons 'v4 v4)) (lambda () (uuidLength v7)))) 36)
    ))
  )

  (test-case "hasVersionDigit detects v4 at position 14"
    (call-with-fresh-memory-db '() (lambda ()
  (define v4 (thsl-src! "example/learn/lesson56-uuid.tesl" 244 (list) (lambda () "550e8400-e29b-41d4-a716-446655440000")))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 245 (list (cons 'v4 v4)) (lambda () (hasVersionDigit v4 "4")))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 246 (list (cons 'v4 v4)) (lambda () (hasVersionDigit v4 "7")))) #f)
    ))
  )

  (test-case "hasVersionDigit detects v7 at position 14"
    (call-with-fresh-memory-db '() (lambda ()
  (define v7 (thsl-src! "example/learn/lesson56-uuid.tesl" 250 (list) (lambda () "018e7a30-a1b2-7c3d-8e4f-123456789abc")))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 251 (list (cons 'v7 v7)) (lambda () (hasVersionDigit v7 "7")))) #t)
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 252 (list (cons 'v7 v7)) (lambda () (hasVersionDigit v7 "4")))) #f)
    ))
  )

  (test-case "describeUuid recognizes v4"
    (call-with-fresh-memory-db '() (lambda ()
  (define v4 (thsl-src! "example/learn/lesson56-uuid.tesl" 256 (list) (lambda () "550e8400-e29b-41d4-a716-446655440000")))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 257 (list (cons 'v4 v4)) (lambda () (describeUuid v4)))) "UUID v4 (random)")
    ))
  )

  (test-case "describeUuid recognizes v7"
    (call-with-fresh-memory-db '() (lambda ()
  (define v7 (thsl-src! "example/learn/lesson56-uuid.tesl" 261 (list) (lambda () "018e7a30-a1b2-7c3d-8e4f-123456789abc")))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 262 (list (cons 'v7 v7)) (lambda () (describeUuid v7)))) "UUID v7 (time-ordered)")
    ))
  )

  (test-case "checkUuidFormat accepts 36-char UUID"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 266 (list) (lambda () (checkUuidFormat "550e8400-e29b-41d4-a716-446655440000")))) #t)
    ))
  )

  (test-case "checkUuidFormat rejects short string"
    (call-with-fresh-memory-db '() (lambda ()
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 270 (list) (lambda () (checkUuidFormat "550e8400-e29b-41d4")))) #f)
    ))
  )

  (test-case "UUID hyphens are at correct positions"
    (call-with-fresh-memory-db '() (lambda ()
  (define v4 (thsl-src! "example/learn/lesson56-uuid.tesl" 274 (list) (lambda () "550e8400-e29b-41d4-a716-446655440000")))
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 275 (list (cons 'v4 v4)) (lambda () (raw-value (tesl_import_String_slice (raw-value v4) 8 9))))) "-")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 276 (list (cons 'v4 v4)) (lambda () (raw-value (tesl_import_String_slice (raw-value v4) 13 14))))) "-")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 277 (list (cons 'v4 v4)) (lambda () (raw-value (tesl_import_String_slice (raw-value v4) 18 19))))) "-")
  (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 278 (list (cons 'v4 v4)) (lambda () (raw-value (tesl_import_String_slice (raw-value v4) 23 24))))) "-")
    ))
  )

  (test-case "generateV4 produces a valid random UUID"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (uuid)
    (define id (thsl-src! "example/learn/lesson56-uuid.tesl" 285 (list) (lambda () (generateV4))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 286 (list (cons 'id id)) (lambda () (checkUuidFormat id)))) #t)
    (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 287 (list (cons 'id id)) (lambda () (uuidLength id)))) 36)
    (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 288 (list (cons 'id id)) (lambda () (describeUuid id)))) "UUID v4 (random)")
    )
    ))
  )

  (test-case "generateV7 produces a valid time-ordered UUID"
    (call-with-fresh-memory-db '() (lambda ()
    (with-capabilities (uuid)
    (define id (thsl-src! "example/learn/lesson56-uuid.tesl" 292 (list) (lambda () (generateV7))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 293 (list (cons 'id id)) (lambda () (checkUuidFormat id)))) #t)
    (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 294 (list (cons 'id id)) (lambda () (uuidLength id)))) 36)
    (check-equal? (raw-value (thsl-src! "example/learn/lesson56-uuid.tesl" 295 (list (cons 'id id)) (lambda () (describeUuid id)))) "UUID v7 (time-ordered)")
    )
    ))
  )

)
