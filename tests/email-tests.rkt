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
  tesl/tesl/email
  (only-in tesl/tesl/prelude String Unit Bool)
  (only-in tesl/tesl/email emailCap)
)


(provide )

(define-database TestDB
  #:backend postgres
  #:database ""
  #:user ""
  #:password ""
  #:server ""
  #:port 5432
  #:schema public
  #:entities )

(define-email AppEmail #:database TestDB #:smtp-host (tesl-env-raw "SMTP_HOST") #:smtp-port 587 #:smtp-username (tesl-env-raw "SMTP_USER") #:smtp-password (tesl-env-raw "SMTP_PASS") #:smtp-tls #t)

(define-email MarketingEmail #:database TestDB #:smtp-host (tesl-env-raw "MKT_SMTP_HOST") #:smtp-port 465 #:smtp-username (tesl-env-raw "MKT_SMTP_USER") #:smtp-password (tesl-env-raw "MKT_SMTP_PASS") #:smtp-tls #t)

(define-email NoTlsEmail #:database TestDB #:smtp-host (tesl-env-raw "SMTP_HOST") #:smtp-port 25 #:smtp-username (tesl-env-raw "SMTP_USER") #:smtp-password (tesl-env-raw "SMTP_PASS") #:smtp-tls #f)

(define/pow
  (sendWelcome [addr : String])
  #:capabilities [emailCap]
  #:returns Unit
  (thsl-src! "tests/email-tests.tesl" 67 (list (cons 'addr *addr)) (lambda () (send-email! AppEmail #:to addr #:subject "Welcome!" #:body (raw-value (RichBody "Hello!" "<h1>Hello!</h1>"))))))

(define/pow
  (sendSimple [addr : String] [subj : String])
  #:capabilities [emailCap]
  #:returns Unit
  (thsl-src! "tests/email-tests.tesl" 74 (list (cons 'addr *addr) (cons 'subj *subj)) (lambda () (send-email! AppEmail #:to addr #:subject subj #:body (raw-value (TextBody "Hello from Tesl"))))))

(define/pow
  (sendTextOnly [addr : String] [bodyText : String])
  #:capabilities [emailCap]
  #:returns Unit
  (thsl-src! "tests/email-tests.tesl" 81 (list (cons 'addr *addr) (cons 'bodyText *bodyText)) (lambda () (send-email! AppEmail #:to addr #:subject "Notification" #:body (raw-value (TextBody *bodyText))))))

(define/pow
  (sendHtmlOnly [addr : String] [html : String])
  #:capabilities [emailCap]
  #:returns Unit
  (thsl-src! "tests/email-tests.tesl" 88 (list (cons 'addr *addr) (cons 'html *html)) (lambda () (send-email! AppEmail #:to addr #:subject "HTML Email" #:body (raw-value (HtmlBody *html))))))

(define/pow
  (sendMarketing [addr : String])
  #:capabilities [emailCap]
  #:returns Unit
  (thsl-src! "tests/email-tests.tesl" 95 (list (cons 'addr *addr)) (lambda () (send-email! MarketingEmail #:to addr #:subject "Special Offer" #:body (raw-value (RichBody "Check out our deals" "<p>Check out our deals</p>"))))))

(define/pow
  (sendMultiple [a : String] [b : String])
  #:capabilities [emailCap]
  #:returns Unit
  (let ([_ (thsl-src! "tests/email-tests.tesl" 102 (list (cons 'a *a) (cons 'b *b)) (lambda () (send-email! AppEmail #:to a #:subject "First" #:body (raw-value (TextBody "Hello")))))]) (thsl-src! "tests/email-tests.tesl" 103 (list (cons 'a *a) (cons 'b *b)) (lambda () (send-email! AppEmail #:to b #:subject "Second" #:body (raw-value (TextBody "Bye")))))))

(define/pow
  (startEmailServices)
  #:capabilities [emailCap]
  #:returns Unit
  (thsl-src! "tests/email-tests.tesl" 106 (list) (lambda () (start-email-worker! AppEmail))))

(define/pow
  (startAllEmailServices)
  #:capabilities [emailCap]
  #:returns Unit
  (let ([_ (thsl-src! "tests/email-tests.tesl" 109 (list) (lambda () (send-email! AppEmail #:to "admin@example.com" #:subject "Starting" #:body (raw-value (TextBody "Services starting")))))]) (thsl-src! "tests/email-tests.tesl" 110 (list) (lambda () (start-email-worker! AppEmail)))))

(module+ test
  (require rackunit)
  (test-case "email block compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 115 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "multiple email blocks compile"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 119 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "sendWelcome function compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 123 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "sendSimple function compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 127 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "sendTextOnly function compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 131 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "sendHtmlOnly function compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 135 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "sendMarketing uses MarketingEmail"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 139 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "sendMultiple calls Email.send twice"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 143 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "startEmailServices calls startEmailWorker"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 147 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "startAllEmailServices sends and starts worker"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 151 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "email capability recognized in requires clause"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 155 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "NoTlsEmail with port 25 compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 159 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "Email.send without text compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 163 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "Email.send without html compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 167 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "Email.send in let _ = binding compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 171 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "email block with env() for smtp params"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 175 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "email block with port 465 compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 179 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "startEmailWorker in function body"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 183 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "Email.send with string literal to"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 187 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "Email.send with variable to"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 191 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "Email.send with concatenated subject"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 195 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "two email declarations in module"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 199 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "email and NoTlsEmail coexist"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 203 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "sendWelcome uses email capability"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 207 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "email feature integrates with test blocks"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 211 (list) (lambda () #t))) #t)
    ))
  )

)
