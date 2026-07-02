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


(provide sendWelcomeEmail sendPasswordReset sendNotification sendHtmlNewsletter sendWelcomeEmail-signature sendPasswordReset-signature sendNotification-signature sendHtmlNewsletter-signature)

(define-database AppDB
  #:backend postgres
  #:database (tesl-env-raw "LESSON60_DB")
  #:user (tesl-env-raw "TESL_POSTGRES_USER")
  #:password (tesl-env-raw "TESL_POSTGRES_PASSWORD")
  #:server (tesl-env-raw "TESL_POSTGRES_HOST")
  #:port (tesl-env-int-raw "TESL_POSTGRES_PORT" 5432)
  #:schema lesson60
  #:entities )

(define-email AppEmail #:database AppDB #:smtp-host (tesl-env-raw "SMTP_HOST") #:smtp-port 587 #:smtp-username (tesl-env-raw "SMTP_USER") #:smtp-password (tesl-env-raw "SMTP_PASS") #:smtp-tls #t)

(define/pow
  (sendWelcomeEmail [recipientAddr : String] [firstName : String])
  #:capabilities [email]
  #:returns Unit
  (thsl-src! "example/learn/lesson60-email.tesl" 105 (list (cons 'recipientAddr *recipientAddr) (cons 'firstName *firstName)) (lambda () (send-email! AppEmail #:to recipientAddr #:subject "Welcome to our service!" #:body (raw-value (RichBody (format "Hello ~a, welcome! We're glad to have you." (tesl-display-val *firstName)) (format "<h1>Welcome, ~a!</h1><p>Great to have you with us.</p>" (tesl-display-val *firstName))))))))

(define/pow
  (sendPasswordReset [recipientAddr : String] [resetLink : String])
  #:capabilities [email]
  #:returns Unit
  (thsl-src! "example/learn/lesson60-email.tesl" 114 (list (cons 'recipientAddr *recipientAddr) (cons 'resetLink *resetLink)) (lambda () (send-email! AppEmail #:to recipientAddr #:subject "Password Reset Request" #:body (raw-value (RichBody (format "Click this link to reset your password: ~a" (tesl-display-val *resetLink)) (format "<p>Click <a href=\"~a\">here</a> to reset your password. Link expires in 30 minutes.</p>" (tesl-display-val *resetLink))))))))

(define/pow
  (sendNotification [addr : String] [message : String])
  #:capabilities [email]
  #:returns Unit
  (thsl-src! "example/learn/lesson60-email.tesl" 123 (list (cons 'addr *addr) (cons 'message *message)) (lambda () (send-email! AppEmail #:to addr #:subject "Notification" #:body (raw-value (TextBody *message))))))

(define/pow
  (sendHtmlNewsletter [addr : String] [htmlContent : String])
  #:capabilities [email]
  #:returns Unit
  (thsl-src! "example/learn/lesson60-email.tesl" 132 (list (cons 'addr *addr) (cons 'htmlContent *htmlContent)) (lambda () (send-email! AppEmail #:to addr #:subject "Monthly Newsletter" #:body (raw-value (HtmlBody *htmlContent))))))

(define/pow
  (startEmailDelivery)
  #:capabilities [email]
  #:returns Unit
  (thsl-src! "example/learn/lesson60-email.tesl" 257 (list) (lambda () (start-email-worker! AppEmail))))

(module+ test
  (require rackunit)
  (test-case "sendWelcomeEmail compiles and runs without error"
    (with-capabilities (email)
    (define tesl_ignored_0 (thsl-src! "example/learn/lesson60-email.tesl" 214 (list) (lambda () (sendWelcomeEmail "alice@example.com" "Alice"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson60-email.tesl" 215 (list) (lambda () #t))) #t)
    )
  )

  (test-case "sendPasswordReset compiles and runs without error"
    (with-capabilities (email)
    (define tesl_ignored_1 (thsl-src! "example/learn/lesson60-email.tesl" 219 (list) (lambda () (sendPasswordReset "bob@example.com" "https://example.com/reset?token=abc123"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson60-email.tesl" 220 (list) (lambda () #t))) #t)
    )
  )

  (test-case "sendNotification with plain text"
    (with-capabilities (email)
    (define tesl_ignored_2 (thsl-src! "example/learn/lesson60-email.tesl" 224 (list) (lambda () (sendNotification "ops@example.com" "Deployment completed successfully."))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson60-email.tesl" 225 (list) (lambda () #t))) #t)
    )
  )

  (test-case "sendHtmlNewsletter with HTML content"
    (with-capabilities (email)
    (define tesl_ignored_3 (thsl-src! "example/learn/lesson60-email.tesl" 229 (list) (lambda () (sendHtmlNewsletter "newsletter@example.com" "<h1>June Update</h1><p>Here's what's new.</p>"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson60-email.tesl" 230 (list) (lambda () #t))) #t)
    )
  )

  (test-case "multiple emails can be queued in sequence"
    (with-capabilities (email)
    (define tesl_ignored_4 (thsl-src! "example/learn/lesson60-email.tesl" 234 (list) (lambda () (sendWelcomeEmail "user1@example.com" "User1"))))
    (define tesl_ignored_5 (thsl-src! "example/learn/lesson60-email.tesl" 235 (list) (lambda () (sendWelcomeEmail "user2@example.com" "User2"))))
    (define tesl_ignored_6 (thsl-src! "example/learn/lesson60-email.tesl" 236 (list) (lambda () (sendWelcomeEmail "user3@example.com" "User3"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson60-email.tesl" 237 (list) (lambda () #t))) #t)
    )
  )

  (test-case "email with special characters in body"
    (with-capabilities (email)
    (define tesl_ignored_7 (thsl-src! "example/learn/lesson60-email.tesl" 241 (list) (lambda () (sendNotification "test@example.com" "Reset link: https://example.com/reset?token=abc&user=1"))))
    (check-equal? (raw-value (thsl-src! "example/learn/lesson60-email.tesl" 242 (list) (lambda () #t))) #t)
    )
  )

  (test-case "startEmailWorker function compiles"
  (check-equal? (raw-value (thsl-src! "example/learn/lesson60-email.tesl" 260 (list) (lambda () #t))) #t)
  )

)
