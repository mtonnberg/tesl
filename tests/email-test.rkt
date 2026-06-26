#lang racket

;;; email-test.rkt — Racket runtime tests for the Tesl Email runtime.
;;;
;;; Tests the in-memory fallback (no PostgreSQL required, no real SMTP) for:
;;;   - send-email! stores pending email in in-memory store
;;;   - Multiple emails can be enqueued
;;;   - email-spec struct accessors
;;;   - define-email macro
;;;   - Capability checking
;;;   - In-memory store contents
;;;   - Email fields (to, subject, text, html)

(require rackunit
         (only-in "../tesl/email.rkt"
                  email
                  define-email
                  send-email!
                  email-spec
                  email-spec-name
                  email-spec-smtp-host
                  email-spec-smtp-port
                  email-spec-smtp-username
                  email-spec-smtp-tls
                  email-spec-store)
         (only-in "../dsl/capability.rkt"
                  define-capability
                  with-capabilities))

;; ── Test email configurations ─────────────────────────────────────────────────

(define-email TestEmail
  #:smtp-host "smtp.example.com"
  #:smtp-port 587
  #:smtp-username "test@example.com"
  #:smtp-password "secret"
  #:smtp-tls #t)

(define-email NoTlsEmail
  #:smtp-host "mail.example.com"
  #:smtp-port 25
  #:smtp-username "noreply@example.com"
  #:smtp-password "pass"
  #:smtp-tls #f)

(define-email FullEmail
  #:smtp-host "smtp.sendgrid.com"
  #:smtp-port 465
  #:smtp-username "apikey"
  #:smtp-password "SG.test"
  #:smtp-tls #t)

;; ── Helper ────────────────────────────────────────────────────────────────────

(define (run-with-email thunk)
  (with-capabilities (email)
    (thunk)))

(define (get-store email-s)
  (unbox (email-spec-store email-s)))

(define (clear-store! email-s)
  (set-box! (email-spec-store email-s) '()))

;; ── Tests ──────────────────────────────────────────────────────────────────────

;; 1. send-email! stores email in memory (no text/html)
(test-case "send-email! stores email in in-memory store"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (send-email! TestEmail #:to "user@example.com" #:subject "Hello" #:text #f #:html #f)
     (check-equal? (length (get-store TestEmail)) 1))))

;; 2. Stored email has correct to address
(test-case "stored email has correct to field"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (send-email! TestEmail #:to "alice@example.com" #:subject "Test" #:text #f #:html #f)
     (define entry (car (get-store TestEmail)))
     (check-equal? (hash-ref entry 'to) "alice@example.com"))))

;; 3. Stored email has correct subject
(test-case "stored email has correct subject field"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (send-email! TestEmail #:to "bob@example.com" #:subject "Welcome!" #:text #f #:html #f)
     (define entry (car (get-store TestEmail)))
     (check-equal? (hash-ref entry 'subject) "Welcome!"))))

;; 4. Stored email has correct text body
(test-case "stored email has text body"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (send-email! TestEmail #:to "user@example.com" #:subject "Hi"
                  #:text "Hello world" #:html #f)
     (define entry (car (get-store TestEmail)))
     (check-equal? (hash-ref entry 'text) "Hello world"))))

;; 5. Stored email has correct html body
(test-case "stored email has html body"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (send-email! TestEmail #:to "user@example.com" #:subject "Hi"
                  #:text #f #:html "<h1>Hello</h1>")
     (define entry (car (get-store TestEmail)))
     (check-equal? (hash-ref entry 'html) "<h1>Hello</h1>"))))

;; 6. Stored email has both text and html
(test-case "stored email can have both text and html"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (send-email! TestEmail #:to "user@example.com" #:subject "Hi"
                  #:text "Plain" #:html "<p>Plain</p>")
     (define entry (car (get-store TestEmail)))
     (check-equal? (hash-ref entry 'text) "Plain")
     (check-equal? (hash-ref entry 'html) "<p>Plain</p>"))))

;; 7. Stored email initial status is 'pending
(test-case "stored email starts with pending status"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (send-email! TestEmail #:to "user@example.com" #:subject "Hi" #:text #f #:html #f)
     (define entry (car (get-store TestEmail)))
     (check-equal? (hash-ref entry 'status) 'pending))))

;; 8. Stored email initial attempts is 0
(test-case "stored email starts with 0 attempts"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (send-email! TestEmail #:to "user@example.com" #:subject "Hi" #:text #f #:html #f)
     (define entry (car (get-store TestEmail)))
     (check-equal? (hash-ref entry 'attempts) 0))))

;; 9. Multiple emails are all stored
(test-case "multiple send-email! calls all stored"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (send-email! TestEmail #:to "a@example.com" #:subject "A" #:text #f #:html #f)
     (send-email! TestEmail #:to "b@example.com" #:subject "B" #:text #f #:html #f)
     (send-email! TestEmail #:to "c@example.com" #:subject "C" #:text #f #:html #f)
     (check-equal? (length (get-store TestEmail)) 3))))

;; 10. Emails preserved in insertion order
(test-case "emails stored in insertion order"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (send-email! TestEmail #:to "first@example.com" #:subject "First" #:text #f #:html #f)
     (send-email! TestEmail #:to "second@example.com" #:subject "Second" #:text #f #:html #f)
     (define entries (get-store TestEmail))
     (check-equal? (hash-ref (car entries) 'to) "first@example.com")
     (check-equal? (hash-ref (cadr entries) 'to) "second@example.com"))))

;; 11. email-spec-name returns the email name
(test-case "email-spec-name returns symbol"
  (check-equal? (email-spec-name TestEmail) 'TestEmail))

;; 12. email-spec-smtp-host returns host
(test-case "email-spec-smtp-host returns configured host"
  (check-equal? (email-spec-smtp-host TestEmail) "smtp.example.com"))

;; 13. email-spec-smtp-port returns port
(test-case "email-spec-smtp-port returns configured port"
  (check-equal? (email-spec-smtp-port TestEmail) 587))

;; 14. email-spec-smtp-tls returns tls flag
(test-case "email-spec-smtp-tls returns #t for TLS"
  (check-true (email-spec-smtp-tls TestEmail)))

;; 15. NoTlsEmail has tls=false
(test-case "email-spec-smtp-tls returns #f when tls disabled"
  (check-false (email-spec-smtp-tls NoTlsEmail)))

;; 16. NoTlsEmail port 25
(test-case "NoTlsEmail has port 25"
  (check-equal? (email-spec-smtp-port NoTlsEmail) 25))

;; 17. FullEmail port 465
(test-case "FullEmail has port 465"
  (check-equal? (email-spec-smtp-port FullEmail) 465))

;; 18. Store is initially empty
(test-case "store is empty after creation"
  (define fresh-email
    (email-spec 'FreshEmail #f "host" 587 "user" "pass" #t (box '())))
  (check-equal? (length (unbox (email-spec-store fresh-email))) 0))

;; 19. Different email configs have separate stores
(test-case "different email instances have separate stores"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (clear-store! NoTlsEmail)
     (send-email! TestEmail #:to "a@example.com" #:subject "A" #:text #f #:html #f)
     (check-equal? (length (get-store TestEmail)) 1)
     (check-equal? (length (get-store NoTlsEmail)) 0))))

;; 20. send-email! with #f text stores #f
(test-case "send-email! with no text stores #f"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (send-email! TestEmail #:to "user@example.com" #:subject "Hi" #:text #f #:html #f)
     (define entry (car (get-store TestEmail)))
     (check-false (hash-ref entry 'text)))))

;; 21. send-email! with #f html stores #f
(test-case "send-email! with no html stores #f"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (send-email! TestEmail #:to "user@example.com" #:subject "Hi" #:text #f #:html #f)
     (define entry (car (get-store TestEmail)))
     (check-false (hash-ref entry 'html)))))

;; 22. Capability check — send fails without capability
(test-case "send-email! fails without email capability"
  (check-exn exn:fail?
    (lambda ()
      (send-email! TestEmail #:to "user@example.com" #:subject "Hi" #:text #f #:html #f))))

;; 23. FullEmail uses SendGrid host
(test-case "FullEmail uses SendGrid SMTP host"
  (check-equal? (email-spec-smtp-host FullEmail) "smtp.sendgrid.com"))

;; 24. FullEmail username
(test-case "FullEmail username is apikey"
  (check-equal? (email-spec-smtp-username FullEmail) "apikey"))

;; 25. send-email! result is void (no return value expected)
(test-case "send-email! returns (void)"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (define result
       (send-email! TestEmail #:to "user@example.com" #:subject "Test"
                    #:text #f #:html #f))
     (check-true (void? result)))))

;; 26. No text/html email has all optional fields as #f
(test-case "minimal email has #f text and html"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (send-email! TestEmail #:to "user@example.com" #:subject "Minimal" #:text #f #:html #f)
     (define entry (car (get-store TestEmail)))
     (check-false (hash-ref entry 'text))
     (check-false (hash-ref entry 'html)))))

;; 27. String values stored as strings
(test-case "all string fields stored as strings"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (send-email! TestEmail #:to "user@example.com" #:subject "Subject"
                  #:text "Text" #:html "<html>")
     (define entry (car (get-store TestEmail)))
     (check-pred string? (hash-ref entry 'to))
     (check-pred string? (hash-ref entry 'subject))
     (check-pred string? (hash-ref entry 'text))
     (check-pred string? (hash-ref entry 'html)))))

;; 28. email-spec? predicate
(test-case "email-spec? is true for email-spec structs"
  (check-true (email-spec? TestEmail)))

;; 29. email-spec? is false for non-email-spec values
(test-case "email-spec? is false for plain values"
  (check-false (email-spec? "not-an-email-spec")))

;; 30. email capability is defined
(test-case "email capability is available"
  (check-true (procedure? email)))

;; 31. Clearing store removes all entries
(test-case "clear-store! removes all entries"
  (run-with-email
   (lambda ()
     (send-email! TestEmail #:to "a@example.com" #:subject "A" #:text #f #:html #f)
     (send-email! TestEmail #:to "b@example.com" #:subject "B" #:text #f #:html #f)
     (clear-store! TestEmail)
     (check-equal? (length (get-store TestEmail)) 0))))

;; 32. Long subject string stored correctly
(test-case "long subject stored correctly"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (define long-subject (make-string 200 #\A))
     (send-email! TestEmail #:to "user@example.com" #:subject long-subject #:text #f #:html #f)
     (define entry (car (get-store TestEmail)))
     (check-equal? (hash-ref entry 'subject) long-subject))))

;; 33. Unicode in email addresses
(test-case "unicode in to address stored correctly"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (send-email! TestEmail #:to "ñoño@example.com" #:subject "Hi" #:text #f #:html #f)
     (define entry (car (get-store TestEmail)))
     (check-equal? (hash-ref entry 'to) "ñoño@example.com"))))

;; 34. Multiline HTML body stored correctly
(test-case "multiline HTML body stored correctly"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (define html "<html>\n<body>\n<h1>Hello</h1>\n</body>\n</html>")
     (send-email! TestEmail #:to "user@example.com" #:subject "HTML"
                  #:text #f #:html html)
     (define entry (car (get-store TestEmail)))
     (check-equal? (hash-ref entry 'html) html))))

;; 35. send-email! with both bodies, correct fields
(test-case "send-email! with both text and html has both fields"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (send-email! TestEmail #:to "user@example.com" #:subject "Multi"
                  #:text "Plain text" #:html "<p>HTML</p>")
     (define entry (car (get-store TestEmail)))
     (check-equal? (hash-ref entry 'text) "Plain text")
     (check-equal? (hash-ref entry 'html) "<p>HTML</p>")
     (check-equal? (hash-ref entry 'to) "user@example.com")
     (check-equal? (hash-ref entry 'subject) "Multi"))))

;; 36. Multiple emails to different recipients
(test-case "each email has its own recipient"
  (run-with-email
   (lambda ()
     (clear-store! TestEmail)
     (for ([i (in-range 10)])
       (send-email! TestEmail
                    #:to (~a "user" i "@example.com")
                    #:subject (~a "Subject " i)
                    #:text #f #:html #f))
     (define entries (get-store TestEmail))
     (check-equal? (length entries) 10)
     (for ([i (in-range 10)]
           [entry (in-list entries)])
       (check-equal? (hash-ref entry 'to) (~a "user" i "@example.com"))))))

;; 37. email-spec-name is a symbol
(test-case "email-spec-name returns symbol not string"
  (check-pred symbol? (email-spec-name TestEmail)))

;; 38. Store is a box
(test-case "email-spec-store returns a box"
  (check-pred box? (email-spec-store TestEmail)))

;; 39. Host returned by email-spec-smtp-host is a string
(test-case "email-spec-smtp-host returns string"
  (check-pred string? (email-spec-smtp-host TestEmail)))

;; 40. Port is an integer
(test-case "email-spec-smtp-port returns integer"
  (check-pred exact-integer? (email-spec-smtp-port TestEmail)))
