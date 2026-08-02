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
;;; THE RANGES LIVE IN ONE PLACE.  Parsing and range classification are
;;; dsl/private/host-classify.rkt, which is also what the `Tesl.Net` stdlib
;;; surface reads (GitHub #68).  That is deliberate: an application checking a
;;; user-supplied URL with `Net.isForbiddenHost` and the runtime refusing to
;;; dial the address that URL resolves to must agree about what "private" means,
;;; and the way to guarantee that is for them to share the table rather than
;;; each keep a copy.  What stays HERE is the policy on top of the class: the
;;; verdict, and the human-readable reason naming the range.
;;;
;;; FAIL CLOSED.  Anything that is not a recognizable public address is refused,
;;; including a string this module cannot parse at all.

(require (only-in "host-classify.rkt"
                  classify-address
                  normalize-address
                  parse-ipv4-strict))

(provide ip-address-forbidden?
         ip-forbidden-reason
         parse-ipv4
         normalize-ip)

;; Parse a dotted-quad IPv4 string to a list of 4 octets, or #f.
(define (parse-ipv4 s) (parse-ipv4-strict s))

;; Collapse the forms that alias an address into a single canonical string, so a
;; classifier reasoning about IPv4 ranges also catches the IPv6-mapped/compat
;; spellings of those same addresses (the classic bypass).
;;   ::ffff:127.0.0.1  ->  127.0.0.1     (IPv4-mapped)
;;   ::ffff:7f00:1     ->  127.0.0.1     (IPv4-mapped, hex form)
;;   0:0:...:127.0.0.1 ->  127.0.0.1     (IPv4-compatible, deprecated)
;;   fe80::1%eth0      ->  fe80::1       (zone id dropped)
;; A string that is not an address at all comes back unchanged, so this stays a
;; total function usable in a log line; the VERDICT never consults it.
(define (normalize-ip s) (or (normalize-address s) s))

;; The reason an address is forbidden, or #f if it is allowed to be dialed.
;; Anything that is not a public, routable address fails CLOSED — an
;; unparseable/unknown form is refused, not allowed.
(define (ip-forbidden-reason addr0)
  (define-values (cls canon) (classify-address addr0))
  (define v4? (and canon (parse-ipv4-strict canon) #t))
  (case cls
    [(public-ip)   #f]
    [(loopback)    (if v4? "loopback 127.0.0.0/8" "IPv6 loopback ::1")]
    [(unspecified) (if v4? "0.0.0.0/8 (this network)" "unspecified ::")]
    [(link-local)  (if v4? "link-local 169.254.0.0/16" "IPv6 link-local fe80::/10")]
    [(private)     (if v4? (rfc1918-label canon) "IPv6 unique-local fc00::/7")]
    [(cgnat)       "CGNAT 100.64.0.0/10"]
    [(multicast)   (if v4? "multicast/reserved >= 224.0.0.0" "IPv6 multicast ff00::/8")]
    [else          "unrecognized address form (fail-closed)"]))

;; Name the specific RFC1918 block, so the refusal message is actionable.
(define (rfc1918-label canon)
  (define a (car (parse-ipv4-strict canon)))
  (cond
    [(= a 10)  "private 10.0.0.0/8"]
    [(= a 172) "private 172.16.0.0/12"]
    [else      "private 192.168.0.0/16"]))

(define (ip-address-forbidden? addr)
  (and (ip-forbidden-reason addr) #t))
