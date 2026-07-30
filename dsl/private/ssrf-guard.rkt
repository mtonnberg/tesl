#lang racket/base

;;; SSRF containment by resolved address — Phase 1 (roadmap/next/ensure_sso_works.md,
;;; Risk 47), the reusable core.
;;;
;;; The SSO runtime fetches attacker-influenced URLs (an OIDC `issuer`, a
;;; `token`/`authorize`/`userinfo` endpoint, and — the dangerous one — a
;;; `jwks_uri` taken from a *discovery document*).  A hostname check is not
;;; enough: `evil.example.com` can resolve to `169.254.169.254` (cloud instance
;;; credentials) or `127.0.0.1`.  So containment is by the RESOLVED ADDRESS:
;;; resolve, refuse if ANY returned address is loopback / link-local /
;;; unique-local / RFC1918 / CGNAT / `0.0.0.0/8` (or an IPv4-mapped form of any
;;; of those), then connect to the address that was checked so a second
;;; resolution cannot rebind (that pinning step lives with the http-client
;;; integration; this module is the DECISION).
;;;
;;; This module is deliberately pure and dependency-free so it is unit-testable
;;; exhaustively and cannot drift from the ranges the spec names.

(provide ip-address-forbidden?
         ip-forbidden-reason
         parse-ipv4
         normalize-ip)

;; Parse a dotted-quad IPv4 string to a list of 4 octets, or #f.
(define (parse-ipv4 s)
  (define parts (regexp-match #rx"^([0-9]+)[.]([0-9]+)[.]([0-9]+)[.]([0-9]+)$" s))
  (and parts
       (let ([octets (map string->number (cdr parts))])
         (and (andmap (lambda (o) (and o (<= 0 o 255))) octets)
              octets))))

;; Collapse the forms that alias an address into a single canonical string, so a
;; classifier reasoning about IPv4 ranges also catches the IPv6-mapped/compat
;; spellings of those same addresses (the classic bypass).
;;   ::ffff:127.0.0.1  ->  127.0.0.1     (IPv4-mapped)
;;   ::ffff:7f00:1     ->  127.0.0.1     (IPv4-mapped, hex form)
;;   0:0:...:127.0.0.1 ->  127.0.0.1     (IPv4-compatible, deprecated)
(define (normalize-ip s0)
  (define s (string-downcase (string-trim* s0)))
  (cond
    ;; strip a zone id (fe80::1%eth0)
    [(regexp-match #rx"^([^%]+)%" s) => (lambda (m) (normalize-ip (cadr m)))]
    ;; ::ffff:a.b.c.d  or  ::a.b.c.d  (embedded dotted quad)
    [(regexp-match #rx"^::(ffff:)?([0-9]+[.][0-9]+[.][0-9]+[.][0-9]+)$" s)
     => (lambda (m) (caddr m))]
    ;; ::ffff:7f00:0001  (IPv4-mapped, hex) -> dotted quad
    [(regexp-match #px"^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$" s)
     => (lambda (m)
          (define hi (string->number (cadr m) 16))
          (define lo (string->number (caddr m) 16))
          (format "~a.~a.~a.~a"
                  (quotient hi 256) (remainder hi 256)
                  (quotient lo 256) (remainder lo 256)))]
    [else s]))

(define (string-trim* s)
  (regexp-replace #rx"[ \t\r\n]+$" (regexp-replace #rx"^[ \t\r\n]+" s "") ""))

;; The reason an address is forbidden, or #f if it is allowed to be dialed.
;; Anything that is not a public, routable address fails CLOSED — an
;; unparseable/unknown form is refused, not allowed.
(define (ip-forbidden-reason addr0)
  (define addr (normalize-ip addr0))
  (define v4 (parse-ipv4 addr))
  (cond
    [v4 (ipv4-forbidden-reason v4)]
    ;; A recognizable IPv6 is classified (reason or #f = allowed); only a token
    ;; that is NEITHER a dotted quad NOR a plausible IPv6 fails closed.
    [(ipv6-shaped? addr) (ipv6-forbidden-reason addr)]
    [else "unrecognized address form (fail-closed)"]))

;; Plausible IPv6: colon-separated hex (after normalization).  Requires a colon
;; so a bare hex word ("abc") is not mistaken for an address.
(define (ipv6-shaped? s)
  (and (regexp-match? #rx":" s)
       (regexp-match? #rx"^[0-9a-f:]+$" s)))

(define (ip-address-forbidden? addr)
  (and (ip-forbidden-reason addr) #t))

(define (ipv4-forbidden-reason o)
  (define a (car o)) (define b (cadr o)) (define c (caddr o)) (define d (cadddr o))
  (cond
    [(= a 0)   "0.0.0.0/8 (this network)"]
    [(= a 127) "loopback 127.0.0.0/8"]
    [(= a 10)  "private 10.0.0.0/8"]
    [(and (= a 169) (= b 254)) "link-local 169.254.0.0/16"]
    [(and (= a 172) (<= 16 b 31)) "private 172.16.0.0/12"]
    [(and (= a 192) (= b 168)) "private 192.168.0.0/16"]
    [(and (= a 100) (<= 64 b 127)) "CGNAT 100.64.0.0/10"]
    [(>= a 224) "multicast/reserved >= 224.0.0.0"]
    [else #f]))

(define (ipv6-forbidden-reason s)
  (cond
    [(string=? s "::1") "IPv6 loopback ::1"]
    [(string=? s "::")  "unspecified ::"]
    [(regexp-match? #rx"^fe[89ab]" s) "IPv6 link-local fe80::/10"]
    [(regexp-match? #rx"^f[cd]" s) "IPv6 unique-local fc00::/7"]
    [(regexp-match? #rx"^ff" s) "IPv6 multicast ff00::/8"]
    ;; a recognized global IPv6 is allowed.
    [else #f]))
