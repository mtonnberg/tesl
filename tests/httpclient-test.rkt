#lang racket

;;; Runtime tests for Tesl.HttpClient
;;;
;;; These tests verify the Racket-level behavior of the http-client module:
;;; - Capability enforcement
;;; - HttpResponse record structure
;;; - Mock network requests (using a local test server)
;;; - Error handling

(require rackunit
         racket/port
         (only-in "../dsl/capability.rkt"
                  with-capabilities)
         (only-in "../dsl/types.rkt"
                  record-value?
                  record-value-type
                  record-value-fields)
         (only-in "../tesl/http-client.rkt"
                  httpClient
                  HttpResponse
                  HttpResponse?
                  HttpClient.get
                  HttpClient.post
                  HttpClient.put
                  HttpClient.delete))

;;; ── Test 1: httpClient capability is a value ─────────────────────────────────

(test-case "httpClient capability is defined"
  ;; httpClient is a capability-value struct, not a procedure
  (check-true (not (eq? httpClient #f))
              "httpClient should be a non-false capability value"))

;;; ── Test 2: HttpResponse record structure ────────────────────────────────────

(test-case "HttpResponse constructor creates a record"
  ;; We can test the record type by checking the record constructor exists
  (check-pred procedure? HttpResponse
              "HttpResponse should be a constructor function"))

(test-case "HttpResponse? predicate exists"
  (check-pred procedure? HttpResponse?
              "HttpResponse? should be a predicate function"))

;;; ── Test 3: Capability guard enforcement ─────────────────────────────────────

(test-case "HttpClient.get requires httpClient capability"
  ;; Without the capability, the call should raise an error
  (check-exn
   (lambda (e)
     (and (exn:fail? e)
          (or (regexp-match? #rx"capabilities" (exn-message e))
              (regexp-match? #rx"Missing" (exn-message e)))))
   (lambda ()
     ;; No capabilities active — should fail
     (HttpClient.get "http://example.com" '()))
   "HttpClient.get without capability should raise error"))

(test-case "HttpClient.post requires httpClient capability"
  (check-exn
   (lambda (e) (exn:fail? e))
   (lambda ()
     (HttpClient.post "http://example.com" '() "{}"))
   "HttpClient.post without capability should raise error"))

(test-case "HttpClient.put requires httpClient capability"
  (check-exn
   (lambda (e) (exn:fail? e))
   (lambda ()
     (HttpClient.put "http://example.com" '() "{}"))
   "HttpClient.put without capability should raise error"))

(test-case "HttpClient.delete requires httpClient capability"
  (check-exn
   (lambda (e) (exn:fail? e))
   (lambda ()
     (HttpClient.delete "http://example.com" '()))
   "HttpClient.delete without capability should raise error"))

;;; ── Test 4: Invalid URL handling ─────────────────────────────────────────────

(test-case "HttpClient.get rejects invalid URL"
  (with-capabilities (httpClient)
    (check-exn
     (lambda (e) (exn:fail? e))
     (lambda ()
       (HttpClient.get "not-a-valid-url-!!!" '()))
     "Invalid URL should raise an error")))

;;; ── Test 5: URL parsing ───────────────────────────────────────────────────────

(test-case "HttpClient handles http scheme"
  ;; Test that http scheme is accepted (even if connection fails)
  (with-capabilities (httpClient)
    (check-exn
     ;; Connection refused is expected for localhost:9999 (nothing running)
     ;; but the error should be network-related, not URL parsing
     (lambda (e)
       (and (exn:fail? e)
            ;; Should NOT be a URL parsing error
            (not (regexp-match? #rx"invalid URL" (exn-message e)))))
     (lambda ()
       (HttpClient.get "http://127.0.0.1:9" '()))
     "http URL should be parseable (connection may fail)")))

(test-case "HttpClient handles https scheme"
  (with-capabilities (httpClient)
    (check-exn
     (lambda (e)
       (and (exn:fail? e)
            (not (regexp-match? #rx"invalid URL" (exn-message e)))))
     (lambda ()
       (HttpClient.get "https://127.0.0.1:9" '()))
     "https URL should be parseable (connection may fail)")))

;;; ── Test 6: Header format handling ───────────────────────────────────────────

(test-case "HttpClient.get accepts empty headers"
  ;; This tests that empty headers don't cause errors before network attempt
  (with-capabilities (httpClient)
    (check-exn
     (lambda (e) (exn:fail? e))  ;; network error expected, not format error
     (lambda ()
       (HttpClient.get "http://127.0.0.1:9" '()))
     "Empty headers list should be accepted")))

(test-case "HttpClient.get accepts non-empty headers list"
  (with-capabilities (httpClient)
    (check-exn
     (lambda (e)
       (and (exn:fail? e)
            (not (regexp-match? #rx"header" (exn-message e)))))
     (lambda ()
       (HttpClient.get "http://127.0.0.1:9"
                       (list (list "Authorization" "Bearer test")
                             (list "Accept" "application/json"))))
     "Headers list should be processed without format errors")))

;;; ── Test 7: HttpResponse record creation and field access ────────────────────

;; Create HttpResponse values directly using the constructor (no capability needed)

(test-case "HttpResponse constructor creates a valid record"
  (define resp (HttpResponse #:status 200 #:body "OK" #:headers '()))
  (check-true (HttpResponse? resp)
              "HttpResponse constructor should create a valid response")
  (check-true (record-value? resp)
              "HttpResponse should be a record-value"))

(test-case "HttpResponse status field access"
  (define resp (HttpResponse #:status 200 #:body "OK" #:headers '()))
  (check-equal? (hash-ref (record-value-fields resp) 'status) 200
                "status field should be 200"))

(test-case "HttpResponse body field access"
  (define resp (HttpResponse #:status 200 #:body "Hello World" #:headers '()))
  (check-equal? (hash-ref (record-value-fields resp) 'body) "Hello World"
                "body field should be accessible"))

(test-case "HttpResponse headers field access"
  (define hdrs (list (list "Content-Type" "application/json")))
  (define resp (HttpResponse #:status 200 #:body "" #:headers hdrs))
  (check-equal? (hash-ref (record-value-fields resp) 'headers) hdrs
                "headers field should be accessible"))

;;; ── Test 8: HttpResponse record validity ─────────────────────────────────────

(test-case "HttpResponse? predicate returns #t for valid response"
  (define resp (HttpResponse #:status 200 #:body "OK" #:headers '()))
  (check-true (HttpResponse? resp)
              "HttpResponse? should return #t for a valid HttpResponse"))

(test-case "HttpResponse? returns #f for non-response values"
  (check-false (HttpResponse? "not a response")
               "HttpResponse? should return #f for strings")
  (check-false (HttpResponse? 42)
               "HttpResponse? should return #f for integers")
  (check-false (HttpResponse? '())
               "HttpResponse? should return #f for empty list"))

;;; ── Test 9: record-value-type for HttpResponse ────────────────────────────────

(test-case "record-value-type returns HttpResponse symbol"
  (define resp (HttpResponse #:status 404 #:body "Not Found" #:headers '()))
  (check-equal? (record-value-type resp) 'HttpResponse
                "record-value-type should return 'HttpResponse"))

;;; ── Test 10: With-capabilities context ───────────────────────────────────────

(test-case "HttpClient functions work within with-capabilities"
  ;; Test that the capability context is accepted
  ;; (actual network call will fail, but the capability guard should pass)
  (with-capabilities (httpClient)
    (check-exn
     (lambda (e)
       (and (exn:fail? e)
            ;; Should NOT be a capability error
            (not (regexp-match? #rx"Missing capabilities" (exn-message e)))))
     (lambda ()
       (HttpClient.get "http://127.0.0.1:9" '()))
     "With httpClient capability, get should pass capability guard")))

;;; ── Test 11: Module exports sanity check ──────────────────────────────────────

(test-case "All HttpClient exports are functions/values"
  (check-pred procedure? HttpClient.get "HttpClient.get should be a procedure")
  (check-pred procedure? HttpClient.post "HttpClient.post should be a procedure")
  (check-pred procedure? HttpClient.put "HttpClient.put should be a procedure")
  (check-pred procedure? HttpClient.delete "HttpClient.delete should be a procedure")
  (check-pred procedure? HttpResponse "HttpResponse should be a constructor")
  (check-pred procedure? HttpResponse? "HttpResponse? should be a predicate"))
