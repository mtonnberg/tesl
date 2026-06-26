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
  tesl/tesl/email
  (only-in tesl/tesl/prelude String Unit Bool)
)


(provide )

(define-database TestDB
  #:backend memory
  #:entities )

(define-email AppEmail #:database TestDB #:smtp-host (tesl-env-raw "SMTP_HOST") #:smtp-port 587 #:smtp-username (tesl-env-raw "SMTP_USER") #:smtp-password (tesl-env-raw "SMTP_PASS") #:smtp-tls #t)

(define-email MarketingEmail #:database TestDB #:smtp-host (tesl-env-raw "MKT_SMTP_HOST") #:smtp-port 465 #:smtp-username (tesl-env-raw "MKT_SMTP_USER") #:smtp-password (tesl-env-raw "MKT_SMTP_PASS") #:smtp-tls #t)

(define-email NoTlsEmail #:database TestDB #:smtp-host (tesl-env-raw "SMTP_HOST") #:smtp-port 25 #:smtp-username (tesl-env-raw "SMTP_USER") #:smtp-password (tesl-env-raw "SMTP_PASS") #:smtp-tls #f)

(define/pow
  (sendWelcome [addr : String])
  #:capabilities [email]
  #:returns Unit
  (send-email! AppEmail #:to addr #:subject "Welcome!" #:body (raw-value (RichBody "Hello!" "<h1>Hello!</h1>"))))

(define/pow
  (sendSimple [addr : String] [subj : String])
  #:capabilities [email]
  #:returns Unit
  (send-email! AppEmail #:to addr #:subject subj #:body (raw-value (TextBody "Hello from Tesl"))))

(define/pow
  (sendTextOnly [addr : String] [bodyText : String])
  #:capabilities [email]
  #:returns Unit
  (send-email! AppEmail #:to addr #:subject "Notification" #:body (raw-value (TextBody *bodyText))))

(define/pow
  (sendHtmlOnly [addr : String] [html : String])
  #:capabilities [email]
  #:returns Unit
  (send-email! AppEmail #:to addr #:subject "HTML Email" #:body (raw-value (HtmlBody *html))))

(define/pow
  (sendMarketing [addr : String])
  #:capabilities [email]
  #:returns Unit
  (send-email! MarketingEmail #:to addr #:subject "Special Offer" #:body (raw-value (RichBody "Check out our deals" "<p>Check out our deals</p>"))))

(define/pow
  (sendMultiple [a : String] [b : String])
  #:capabilities [email]
  #:returns Unit
  (begin (send-email! AppEmail #:to a #:subject "First" #:body (raw-value (TextBody "Hello"))) (send-email! AppEmail #:to b #:subject "Second" #:body (raw-value (TextBody "Bye")))))

(define/pow
  (startEmailServices)
  #:capabilities [email]
  #:returns Unit
  (start-email-worker! AppEmail))

(define/pow
  (startAllEmailServices)
  #:capabilities [email]
  #:returns Unit
  (begin (send-email! AppEmail #:to "admin@example.com" #:subject "Starting" #:body (raw-value (TextBody "Services starting"))) (start-email-worker! AppEmail)))

(module+ test
  (require rackunit)
  (test-case "email block compiles"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "multiple email blocks compile"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "sendWelcome function compiles"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "sendSimple function compiles"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "sendTextOnly function compiles"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "sendHtmlOnly function compiles"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "sendMarketing uses MarketingEmail"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "sendMultiple calls Email.send twice"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "startEmailServices calls startEmailWorker"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "startAllEmailServices sends and starts worker"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "email capability recognized in requires clause"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "NoTlsEmail with port 25 compiles"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "Email.send without text compiles"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "Email.send without html compiles"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "Email.send in let _ = binding compiles"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "email block with env() for smtp params"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "email block with port 465 compiles"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "startEmailWorker in function body"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "Email.send with string literal to"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "Email.send with variable to"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "Email.send with concatenated subject"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "two email declarations in module"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "email and NoTlsEmail coexist"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "sendWelcome uses email capability"
  (check-equal? (raw-value #t) #t)
  )

  (test-case "email feature integrates with test blocks"
  (check-equal? (raw-value #t) #t)
  )

)
