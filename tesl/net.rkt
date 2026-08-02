#lang racket

;;; Tesl.Net — classify a URL host (GitHub #68).
;;;
;;; `Tesl.Url` answers "what is the host".  This module answers the question an
;;; application asks next: "is that host an address I refuse to dial".  Doing it
;;; by hand is an exact-match list against `localhost` / `127.0.0.1` / `::1`,
;;; and that list is wrong in ways that do not need DNS or attacker
;;; infrastructure — the forbidden address is spelled out verbatim in the URL and
;;; the comparison simply does not recognize the spelling:
;;;
;;;   https://LOCALHOST/hook            case
;;;   https://localhost./hook           root-anchored FQDN
;;;   https://2130706433/hook           decimal-encoded 127.0.0.1
;;;   https://[::ffff:127.0.0.1]/hook   IPv4-mapped IPv6 literal
;;;
;;; So classification here runs on a CANONICALIZED host
;;; (dsl/private/host-classify.rkt): lowercased, trailing-dot stripped,
;;; unbracketed, and every `inet_aton` spelling of an IPv4 address (decimal,
;;; octal, hex, short forms) plus every IPv4-mapped/compat IPv6 spelling folded
;;; to one canonical dotted quad first.  The four bypasses above are then
;;; impossible by construction rather than by an ever-growing checklist.
;;;
;;; `Net.classifyHost` is the primitive to reach for: it returns a `HostClass`,
;;; and a `case` over it is exhaustive, so a range cannot be forgotten the way
;;; one more `||` in a chain of predicates can.  The predicates exist for the
;;; one-line checks.
;;;
;;; ONE RANGE TABLE.  dsl/private/host-classify.rkt is also what the outbound
;;; HTTP client's SSRF decision (dsl/private/ssrf-guard.rkt, issue #48) reads,
;;; so the ranges an application checks and the ranges the runtime refuses
;;; cannot drift apart.
;;;
;;; WHAT THIS IS NOT.  `DomainName` does NOT mean "safe": a name still resolves,
;;; and it can resolve to 127.0.0.1 or to the cloud metadata address.  Only
;;; resolve-then-pin closes that, it is not expressible in `.tesl`, and it is
;;; already always-on in `Tesl.HttpClient` (issue #48).  This module removes the
;;; class of bugs where the STRING check itself was wrong.
;;;
;;; Pure module: no capability.

(require "../dsl/check.rkt"
         "../dsl/types.rkt"
         "../dsl/private/host-classify.rkt")

(provide
 ;; the ADT (type-name symbol + constructors come from define-adt)
 HostClass
 HostClass?
 Loopback
 PrivateIp
 LinkLocal
 Cgnat
 Multicast
 Unspecified
 PublicIp
 DomainName
 InvalidHost
 Loopback? PrivateIp? LinkLocal? Cgnat? Multicast? Unspecified?
 PublicIp? DomainName? InvalidHost?
 ;; surface
 Net.classifyHost
 Net.normalizeHost
 Net.isLoopback
 Net.isPrivate
 Net.isLinkLocal
 Net.isCgnat
 Net.isMulticast
 Net.isIpLiteral
 Net.isIpv4Mapped
 Net.isForbiddenHost)

;; The classification of a host, one constructor per range.  Exhaustive by
;; construction — `case` over it is what stops a forgotten range.
;;
;;   Loopback      127.0.0.0/8, ::1, and the RFC 6761 `localhost` names
;;   PrivateIp     10/8, 172.16/12, 192.168/16, and IPv6 ULA fc00::/7
;;   LinkLocal     169.254.0.0/16 (the cloud metadata endpoint) and fe80::/10
;;   Cgnat         100.64.0.0/10
;;   Multicast     224.0.0.0/4 and above; ff00::/8
;;   Unspecified   0.0.0.0/8 and ::
;;   PublicIp      an address literal in none of the above
;;   DomainName    a valid DNS name — NOT an address, and NOT a safety verdict
;;   InvalidHost   not a host this runtime will vouch for.  Refuse it.
(define-adt (HostClass)
  [Loopback]
  [PrivateIp]
  [LinkLocal]
  [Cgnat]
  [Multicast]
  [Unspecified]
  [PublicIp]
  [DomainName]
  [InvalidHost])

;; Unwrap a (possibly proof-bearing, possibly newtype-wrapped) value to a plain
;; Racket string — same convention as tesl/string.rkt and tesl/regex.rkt.
(define (raw-str s)
  (define v (raw-value s))
  (if (newtype-value? v) (newtype-value-value v) v))

(define (class-of h) (host-class->symbol (raw-str h)))

;; String -> HostClass
(define (Net.classifyHost h)
  (case (class-of h)
    [(loopback)    Loopback]
    [(private)     PrivateIp]
    [(link-local)  LinkLocal]
    [(cgnat)       Cgnat]
    [(multicast)   Multicast]
    [(unspecified) Unspecified]
    [(public-ip)   PublicIp]
    [(domain-name) DomainName]
    ;; 'invalid, and any symbol a future range split might add: fail closed.
    [else          InvalidHost]))

;; String -> Maybe String — the canonical spelling of the host, or Nothing when
;; it is not a host this runtime will vouch for.  Compare and store THIS, never
;; the raw text: two spellings of one address canonicalize to one string.
(define (Net.normalizeHost h)
  (define n (normalize-host (raw-str h)))
  (if n (Something n) Nothing))

(define (Net.isLoopback h)   (eq? 'loopback   (class-of h)))
(define (Net.isPrivate h)    (eq? 'private    (class-of h)))
(define (Net.isLinkLocal h)  (eq? 'link-local (class-of h)))
(define (Net.isCgnat h)      (eq? 'cgnat      (class-of h)))
(define (Net.isMulticast h)  (eq? 'multicast  (class-of h)))

;; #t when the host IS an address literal in some spelling (as opposed to a DNS
;; name).  A `localhost` name is NOT a literal, but it IS `Net.isLoopback`.
(define (Net.isIpLiteral h)
  (define n (normalize-host (raw-str h)))
  (and n (or (ipv4-literal? n) (ipv6-literal? n))))

;; #t when the host was WRITTEN as an IPv4-mapped / IPv4-compat IPv6 literal
;; (`[::ffff:127.0.0.1]`) — the spelling a hand-written check misses most often.
(define (Net.isIpv4Mapped h)
  (host-ipv4-mapped? (raw-str h)))

;; The one-line outbound guard: #t for every host this runtime can already tell
;; is not a public destination — any non-public address literal in any spelling,
;; the `localhost` names, and anything unparseable (fail-closed).
;;
;; #f means only "the string check found nothing wrong".  A `DomainName` still
;; has to resolve somewhere, and judging THAT is resolve-then-pin in the HTTP
;; client (issue #48), not something a string can decide.
(define (Net.isForbiddenHost h)
  (case (class-of h)
    [(public-ip domain-name) #f]
    [else #t]))
