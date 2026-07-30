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
  (only-in tesl/tesl/prelude Bool String)
  (only-in tesl/tesl/string [String.length tesl_import_String_length])
  (only-in tesl/tesl/maybe Maybe Something Nothing)
  (only-in tesl/tesl/random random)
  (only-in tesl/tesl/db dbRead dbWrite)
  (only-in tesl/tesl/crypto PasswordHash HashFor PasswordVerified [Crypto.hashPassword tesl_import_Crypto_hashPassword] [Crypto.checkPassword tesl_import_Crypto_checkPassword] [Crypto.needsRehash tesl_import_Crypto_needsRehash] [Crypto.randomToken tesl_import_Crypto_randomToken] [Crypto.fingerprint tesl_import_Crypto_fingerprint])
)


(provide registerAccount sessionFor passwordHashFor changePassword logIn needsStrongerHash freshResetToken resetTokenLookupKey registerAccount-signature passwordHashFor-signature changePassword-signature sessionFor-signature logIn-signature needsStrongerHash-signature freshResetToken-signature resetTokenLookupKey-signature)

;; Debugger: the lines whose statement is a READ-ONLY query.  The pause on
;; those happens AFTER the statement, so the SQL lens can show the exact
;; statement that ran (erased with the checkpoints in a release build).
(register-sql-read-lines! "example/learn/lesson64-password-storage.tesl" '(158 159))
(define-capability accountWrite (implies dbWrite random))

(define-secret-newtype Password String)

(define-entity Account
  #:source (make-hash)
  #:table accounts
  #:primary-key id
  [Id id : String]
  [Email email : String]
  [PasswordHash passwordHash : PasswordHash]
)

(define-database Accounts
  #:backend memory
  #:entities Account)

(define/pow
  (registerAccount [id : String] [email : String] [password : Password])
  #:capabilities [accountWrite]
  #:returns Boolean
  (let ([hash (thsl-src! "example/learn/lesson64-password-storage.tesl" 108 (list (cons 'id *id) (cons 'email *email) (cons 'password *password)) (lambda () (raw-value (tesl_import_Crypto_hashPassword *password))))]) (thsl-src! "example/learn/lesson64-password-storage.tesl" 109 (list (cons 'hash *hash) (cons 'id *id) (cons 'email *email) (cons 'password *password)) (lambda () (call-with-database Accounts (lambda () (let ([_ (insert-one! Account (tesl-hash 'id id 'email email 'passwordHash hash))]) #t)))))))

(define/pow
  (passwordHashFor [email : String])
  #:capabilities [dbRead]
  #:returns (Maybe PasswordHash)
  (thsl-src! "example/learn/lesson64-password-storage.tesl" 158 (list (cons 'email *email)) (lambda () (call-with-database Accounts (lambda () (let ([found (let ([tesl_match (select-one (from Account) (where (==. (entity-field-ref Account 'email) email)))]) (if tesl_match (Something tesl_match) Nothing))]) (let ([tesl-case-0 (raw-value found)]) (cond [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Nothing)) (thsl-src! "example/learn/lesson64-password-storage.tesl" 161 (list) (lambda () (raw-value Nothing)))] [(and (adt-value? *tesl-case-0) (eq? (adt-value-variant *tesl-case-0) 'Something)) (let ([acct (hash-ref (adt-value-fields *tesl-case-0) 'value)]) (thsl-src! "example/learn/lesson64-password-storage.tesl" 162 (list (cons 'acct acct)) (lambda () (raw-value (raw-value (Something (tesl-dot/runtime acct 'passwordHash 'Account)))))))]))))))))

(define/pow
  (storeNewPassword [email : String] [newPassword : Password] [hash : PasswordHash ::: (HashFor newPassword)])
  #:capabilities [dbWrite]
  #:returns Boolean
  (thsl-src! "example/learn/lesson64-password-storage.tesl" 189 (list (cons 'email *email) (cons 'newPassword *newPassword) (cons 'hash *hash)) (lambda () (call-with-database Accounts (lambda () (let ([_ (void (update-many! (from Account) (tesl-hash (entity-field-ref Account 'passwordHash) hash) (where (==. (entity-field-ref Account 'email) email))))]) #t))))))

(define/pow
  (changePassword [email : String] [oldPassword : Password] [newPassword : Password])
  #:capabilities [accountWrite dbRead]
  #:returns Boolean
  (thsl-src! "example/learn/lesson64-password-storage.tesl" 200 (list (cons 'email *email) (cons 'oldPassword *oldPassword) (cons 'newPassword *newPassword)) (lambda () (let ([stored (passwordHashFor email)]) (let/check ([tesl-checked-1 (tesl_import_Crypto_checkPassword stored oldPassword)]) (let ([_verified tesl-checked-1]) (let ([hash (raw-value (tesl_import_Crypto_hashPassword *newPassword))]) (raw-value (storeNewPassword email newPassword hash)))))))))

(define/pow
  (sessionFor [email : String] [verified : (Maybe PasswordHash) ::: (PasswordVerified verified)])
  #:returns String
  (thsl-src! "example/learn/lesson64-password-storage.tesl" 237 (list (cons 'email *email) (cons 'verified *verified)) (lambda () *email)))

(define/pow
  (logIn [email : String] [submitted : Password])
  #:capabilities [dbRead]
  #:returns String
  (thsl-src! "example/learn/lesson64-password-storage.tesl" 240 (list (cons 'email *email) (cons 'submitted *submitted)) (lambda () (let ([stored (passwordHashFor email)]) (let/check ([tesl-checked-2 (tesl_import_Crypto_checkPassword stored submitted)]) (let ([verified tesl-checked-2]) (raw-value (sessionFor email verified))))))))

(define/pow
  (needsStrongerHash [email : String])
  #:capabilities [dbRead]
  #:returns Boolean
  (thsl-src-control! "example/learn/lesson64-password-storage.tesl" 270 (list (cons 'email *email)) (lambda () (let ([tesl-case-3 (raw-value (passwordHashFor email))]) (cond [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Nothing)) (thsl-src! "example/learn/lesson64-password-storage.tesl" 271 (list) (lambda () (raw-value #f)))] [(and (adt-value? *tesl-case-3) (eq? (adt-value-variant *tesl-case-3) 'Something)) (let ([hash (hash-ref (adt-value-fields *tesl-case-3) 'value)]) (thsl-src! "example/learn/lesson64-password-storage.tesl" 272 (list (cons 'hash hash)) (lambda () (raw-value (raw-value (tesl_import_Crypto_needsRehash *hash))))))])))))

(define/pow
  (freshResetToken)
  #:capabilities [accountWrite]
  #:returns String
  (thsl-src! "example/learn/lesson64-password-storage.tesl" 287 (list) (lambda () (raw-value (tesl_import_Crypto_randomToken)))))

(define/pow
  (resetTokenLookupKey [token : String])
  #:returns String
  (thsl-src! "example/learn/lesson64-password-storage.tesl" 290 (list (cons 'token *token)) (lambda () (raw-value (tesl_import_Crypto_fingerprint *token)))))

(module+ test
  (require rackunit)
  (test-case "a registered password verifies"
    (call-with-fresh-memory-db (list Accounts) (lambda ()
    (with-capabilities (accountWrite dbRead)
    (define tesl-ignored-4 (thsl-src! "example/learn/lesson64-password-storage.tesl" 305 (list) (lambda () (registerAccount "u1" "ada@example.com" (Password "correct horse battery staple")))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson64-password-storage.tesl" 306 (list) (lambda () (logIn "ada@example.com" (Password "correct horse battery staple"))))) "ada@example.com")
    )
    ))
  )

  (test-case "a hash minted with the current parameters does not need rehashing"
    (call-with-fresh-memory-db (list Accounts) (lambda ()
    (with-capabilities (accountWrite dbRead)
    (define tesl-ignored-5 (thsl-src! "example/learn/lesson64-password-storage.tesl" 310 (list) (lambda () (registerAccount "u2" "grace@example.com" (Password "hopper")))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson64-password-storage.tesl" 311 (list) (lambda () (needsStrongerHash "grace@example.com")))) #f)
    )
    ))
  )

  (test-case "an unknown email reports no stored hash and needs no rehash"
    (call-with-fresh-memory-db (list Accounts) (lambda ()
    (with-capabilities (dbRead)
    (check-equal? (raw-value (thsl-src! "example/learn/lesson64-password-storage.tesl" 315 (list) (lambda () (needsStrongerHash "nobody@example.com")))) #f)
    )
    ))
  )

  (test-case "change-password stores a hash of the NEW password"
    (call-with-fresh-memory-db (list Accounts) (lambda ()
    (with-capabilities (accountWrite dbRead)
    (define tesl-ignored-6 (thsl-src! "example/learn/lesson64-password-storage.tesl" 319 (list) (lambda () (registerAccount "u3" "linus@example.com" (Password "old-one")))))
    (define tesl-ignored-7 (thsl-src! "example/learn/lesson64-password-storage.tesl" 320 (list) (lambda () (changePassword "linus@example.com" (Password "old-one") (Password "new-one")))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson64-password-storage.tesl" 323 (list) (lambda () (logIn "linus@example.com" (Password "new-one"))))) "linus@example.com")
    )
    ))
  )

  (test-case "a reset token is unguessable, URL-safe, and stored only as a fingerprint"
    (call-with-fresh-memory-db (list Accounts) (lambda ()
    (with-capabilities (accountWrite)
    (define token (thsl-src! "example/learn/lesson64-password-storage.tesl" 327 (list) (lambda () (freshResetToken))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson64-password-storage.tesl" 329 (list (cons 'token token)) (lambda () (tesl_import_String_length (raw-value token))))) 43)
    (check-equal? (raw-value (thsl-src! "example/learn/lesson64-password-storage.tesl" 330 (list (cons 'token token)) (lambda () (resetTokenLookupKey token)))) (raw-value (tesl_import_Crypto_fingerprint (raw-value token))))
    (define another (thsl-src! "example/learn/lesson64-password-storage.tesl" 332 (list (cons 'token token)) (lambda () (freshResetToken))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson64-password-storage.tesl" 333 (list (cons 'another another) (cons 'token token)) (lambda () (tesl-equal? (raw-value token) (raw-value another))))) #f)
    )
    ))
  )

)
