#lang racket/base

;;; #48 (issue): SSRF egress containment on Tesl.HttpClient.
;;;
;;; Two layers are proven here:
;;;   1. The pure decision `ssrf-egress-refusal` — cloud-metadata / RFC1918 /
;;;      CGNAT / unique-local / link-local / 0.0.0.0/8 are refused; public is
;;;      allowed; loopback follows the deploy-gated dev escape.
;;;   2. The end-to-end pin through `HttpClient.get`: it judges the address it
;;;      actually connected to and refuses BEFORE issuing the request.

(require rackunit
         racket/tcp
         racket/format
         (only-in "../dsl/capability.rkt" with-capabilities)
         (only-in "../tesl/http-client.rkt"
                  httpClient HttpClient.get HttpResponse?
                  ssrf-egress-refusal))

;;; ── 1. The pure decision ─────────────────────────────────────────────────────

(test-case "forbidden ranges are refused, public is allowed"
  (check-true  (string? (ssrf-egress-refusal "169.254.169.254")) "cloud metadata / link-local")
  (check-true  (string? (ssrf-egress-refusal "10.0.0.1"))        "RFC1918 10/8")
  (check-true  (string? (ssrf-egress-refusal "192.168.1.5"))     "RFC1918 192.168/16")
  (check-true  (string? (ssrf-egress-refusal "172.16.3.4"))      "RFC1918 172.16/12")
  (check-true  (string? (ssrf-egress-refusal "100.64.0.1"))      "CGNAT 100.64/10")
  (check-true  (string? (ssrf-egress-refusal "0.0.0.0"))         "0.0.0.0/8")
  (check-false (ssrf-egress-refusal "8.8.8.8")                   "a public address is allowed"))

(test-case "loopback egress: dev-allowed, deploy-denied, opt-in re-openable"
  (parameterize ([current-environment-variables (make-environment-variables)])
    (check-false (ssrf-egress-refusal "127.0.0.1") "non-deployed: loopback allowed")
    (check-false (ssrf-egress-refusal "::1")        "non-deployed: IPv6 loopback allowed"))
  (parameterize ([current-environment-variables
                  (make-environment-variables #"TESL_DEPLOYED" #"1")])
    (check-true (string? (ssrf-egress-refusal "127.0.0.1")) "deployed w/o opt-in: refused"))
  (parameterize ([current-environment-variables
                  (make-environment-variables #"TESL_DEPLOYED" #"1"
                                              #"TESL_HTTP_ALLOW_LOOPBACK_EGRESS" #"1")])
    (check-false (ssrf-egress-refusal "127.0.0.1") "deployed + opt-in: allowed")))

;;; ── 2. The end-to-end pin ────────────────────────────────────────────────────

;; A trivial local plain-HTTP responder on loopback.
(define (with-plain-http-server proc)
  (define listener (tcp-listen 0 4 #t "127.0.0.1"))
  (define-values (_lh port _rh _rp) (tcp-addresses listener #t))
  (define server
    (thread
     (lambda ()
       (let loop ()
         (with-handlers ([exn:fail? (lambda (_e) (void))])
           (define-values (in out) (tcp-accept listener))
           (with-handlers ([exn:fail? (lambda (_e) (void))])
             (read-line in)
             (write-string "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi" out)
             (flush-output out))
           (close-input-port in)
           (close-output-port out))
         (loop)))))
  (dynamic-wind
   void
   (lambda () (proc port))
   (lambda () (kill-thread server) (tcp-close listener))))

(test-case "the client pin refuses loopback egress in a deployed build, before the request"
  (with-plain-http-server
   (lambda (port)
     (parameterize ([current-environment-variables
                     (make-environment-variables #"TESL_DEPLOYED" #"1")])
       (with-capabilities (httpClient)
         (check-exn
          (lambda (e) (and (exn:fail? e) (regexp-match? #rx"SSRF" (exn-message e))))
          (lambda () (HttpClient.get (~a "http://127.0.0.1:" port "/") '()))
          "a deployed build must refuse loopback egress without the opt-in"))))))

(test-case "the client pin allows loopback egress with the opt-in"
  (with-plain-http-server
   (lambda (port)
     (parameterize ([current-environment-variables
                     (make-environment-variables #"TESL_DEPLOYED" #"1"
                                                 #"TESL_HTTP_ALLOW_LOOPBACK_EGRESS" #"1")])
       (with-capabilities (httpClient)
         (define resp (HttpClient.get (~a "http://127.0.0.1:" port "/") '()))
         (check-true (HttpResponse? resp) "the opt-in lets the request through"))))))
