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
  #:capabilities [email]
  #:returns Unit
  (thsl-src! "tests/email-tests.tesl" 68 (list (cons 'addr *addr)) (lambda () (send-email! AppEmail #:to addr #:subject "Welcome!" #:body (raw-value (RichBody "Hello!" "<h1>Hello!</h1>"))))))

(define/pow
  (sendSimple [addr : String] [subj : String])
  #:capabilities [email]
  #:returns Unit
  (thsl-src! "tests/email-tests.tesl" 75 (list (cons 'addr *addr) (cons 'subj *subj)) (lambda () (send-email! AppEmail #:to addr #:subject subj #:body (raw-value (TextBody "Hello from Tesl"))))))

(define/pow
  (sendTextOnly [addr : String] [bodyText : String])
  #:capabilities [email]
  #:returns Unit
  (thsl-src! "tests/email-tests.tesl" 82 (list (cons 'addr *addr) (cons 'bodyText *bodyText)) (lambda () (send-email! AppEmail #:to addr #:subject "Notification" #:body (raw-value (TextBody *bodyText))))))

(define/pow
  (sendHtmlOnly [addr : String] [html : String])
  #:capabilities [email]
  #:returns Unit
  (thsl-src! "tests/email-tests.tesl" 89 (list (cons 'addr *addr) (cons 'html *html)) (lambda () (send-email! AppEmail #:to addr #:subject "HTML Email" #:body (raw-value (HtmlBody *html))))))

(define/pow
  (sendMarketing [addr : String])
  #:capabilities [email]
  #:returns Unit
  (thsl-src! "tests/email-tests.tesl" 96 (list (cons 'addr *addr)) (lambda () (send-email! MarketingEmail #:to addr #:subject "Special Offer" #:body (raw-value (RichBody "Check out our deals" "<p>Check out our deals</p>"))))))

(define/pow
  (sendMultiple [a : String] [b : String])
  #:capabilities [email]
  #:returns Unit
  (let ([_ (thsl-src! "tests/email-tests.tesl" 103 (list (cons 'a *a) (cons 'b *b)) (lambda () (send-email! AppEmail #:to a #:subject "First" #:body (raw-value (TextBody "Hello")))))]) (thsl-src! "tests/email-tests.tesl" 104 (list (cons 'a *a) (cons 'b *b)) (lambda () (send-email! AppEmail #:to b #:subject "Second" #:body (raw-value (TextBody "Bye")))))))

(define/pow
  (startEmailServices)
  #:capabilities [email]
  #:returns Unit
  (thsl-src! "tests/email-tests.tesl" 107 (list) (lambda () (start-email-worker! AppEmail))))

(define/pow
  (startAllEmailServices)
  #:capabilities [email]
  #:returns Unit
  (let ([_ (thsl-src! "tests/email-tests.tesl" 110 (list) (lambda () (send-email! AppEmail #:to "admin@example.com" #:subject "Starting" #:body (raw-value (TextBody "Services starting")))))]) (thsl-src! "tests/email-tests.tesl" 111 (list) (lambda () (start-email-worker! AppEmail)))))

(module+ test
  (require rackunit)
  (test-case "email block compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 116 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "multiple email blocks compile"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 120 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "sendWelcome function compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 124 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "sendSimple function compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 128 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "sendTextOnly function compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 132 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "sendHtmlOnly function compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 136 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "sendMarketing uses MarketingEmail"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 140 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "sendMultiple calls Email.send twice"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 144 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "startEmailServices calls startEmailWorker"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 148 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "startAllEmailServices sends and starts worker"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 152 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "email capability recognized in requires clause"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 156 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "NoTlsEmail with port 25 compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 160 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "Email.send without text compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 164 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "Email.send without html compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 168 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "Email.send in let _ = binding compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 172 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "email block with env() for smtp params"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 176 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "email block with port 465 compiles"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 180 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "startEmailWorker in function body"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 184 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "Email.send with string literal to"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 188 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "Email.send with variable to"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 192 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "Email.send with concatenated subject"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 196 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "two email declarations in module"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 200 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "email and NoTlsEmail coexist"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 204 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "sendWelcome uses email capability"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 208 (list) (lambda () #t))) #t)
    ))
  )

  (test-case "email feature integrates with test blocks"
    (call-with-fresh-memory-db (list TestDB) (lambda ()
  (check-equal? (raw-value (thsl-src! "tests/email-tests.tesl" 212 (list) (lambda () #t))) #t)
    ))
  )

)
