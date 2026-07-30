#lang racket/base

;;; #51 (issue): request.clientAddress + the trustedProxies edge declaration.
;;;
;;; The rule, fail-closed:
;;;   • no declaration  ⇒ the socket peer (X-Forwarded-For ignored, unspoofable)
;;;   • declaration     ⇒ the rightmost-untrusted hop of [XFF…, socket-peer];
;;;     a prepended (spoofed) XFF entry is to the LEFT and is never reached.

(require rackunit
         racket/promise
         (only-in net/url string->url)
         (only-in web-server/http/request-structs request)
         (only-in "../dsl/web.rkt"
                  dsl-request current-trusted-proxies client-address-of))

;; A dsl-request with an optional X-Forwarded-For header and an optional socket
;; peer (the raw Racket request's client-ip).
(define (req-with #:xff [xff #f] #:peer [peer #f])
  (define headers (if xff (hash "x-forwarded-for" xff) (hash)))
  (define raw
    (and peer (request #"GET" (string->url "http://localhost/")
                       '() (delay '()) #f "127.0.0.1" 80 peer)))
  (dsl-request "GET" '() headers #"" (hash) (hash) raw))

(test-case "no declaration ⇒ the socket peer, and X-Forwarded-For is ignored"
  (parameterize ([current-trusted-proxies '()])
    (check-equal? (client-address-of (req-with #:xff "1.2.3.4" #:peer "203.0.113.9"))
                  "203.0.113.9")))

(test-case "one declared proxy ⇒ the client is the XFF entry left of the proxy"
  (parameterize ([current-trusted-proxies '("10.0.0.1")])
    (check-equal? (client-address-of (req-with #:xff "203.0.113.9" #:peer "10.0.0.1"))
                  "203.0.113.9")))

(test-case "multiple declared proxies are all skipped from the right"
  (parameterize ([current-trusted-proxies '("10.0.0.1" "10.0.0.2")])
    (check-equal? (client-address-of
                   (req-with #:xff "203.0.113.9, 10.0.0.1" #:peer "10.0.0.2"))
                  "203.0.113.9")))

(test-case "spoof resistance: a direct connection's prepended XFF is ignored"
  ;; attacker connects directly (peer is NOT a declared proxy) and spoofs XFF.
  (parameterize ([current-trusted-proxies '("10.0.0.1")])
    (check-equal? (client-address-of (req-with #:xff "203.0.113.9" #:peer "9.9.9.9"))
                  "9.9.9.9")))

(test-case "fail-closed: a declaration with no untrusted hop is refused, not guessed"
  (parameterize ([current-trusted-proxies '("10.0.0.1")])
    (check-exn exn:fail?
               (lambda () (client-address-of (req-with #:xff "" #:peer #f))))))
