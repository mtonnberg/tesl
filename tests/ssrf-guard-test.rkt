#lang racket/base

;;; Phase 1 down-payment (roadmap/next/ensure_sso_works.md, Risk 47 + Phase 5
;;; attack list): SSRF containment classifies a RESOLVED address, refusing every
;;; non-public range and every IPv4-mapped spelling of one, and fails closed on
;;; anything it cannot recognize.

(require rackunit
         (only-in "../dsl/private/ssrf-guard.rkt"
                  ip-address-forbidden? ip-forbidden-reason normalize-ip parse-ipv4))

(define (forbidden? a) (ip-address-forbidden? a))

;;; ── The metadata endpoint and loopback (the headline SSRF payoffs) ───────────

(test-case "cloud metadata + loopback + private ranges are refused"
  (check-true (forbidden? "169.254.169.254") "AWS/GCP metadata")
  (check-true (forbidden? "127.0.0.1"))
  (check-true (forbidden? "127.5.6.7"))
  (check-true (forbidden? "0.0.0.0"))
  (check-true (forbidden? "10.0.0.1"))
  (check-true (forbidden? "10.255.255.255"))
  (check-true (forbidden? "172.16.0.1"))
  (check-true (forbidden? "172.31.255.255"))
  (check-true (forbidden? "192.168.1.1"))
  (check-true (forbidden? "100.64.0.1") "CGNAT")
  (check-true (forbidden? "224.0.0.1") "multicast"))

(test-case "genuinely public addresses are allowed"
  (check-false (forbidden? "8.8.8.8"))
  (check-false (forbidden? "1.1.1.1"))
  (check-false (forbidden? "140.82.121.3") "github.com-ish")
  (check-false (forbidden? "172.15.0.1") "just below the 172.16/12 block")
  (check-false (forbidden? "172.32.0.1") "just above the 172.16/12 block")
  (check-false (forbidden? "100.63.255.255") "just below CGNAT")
  (check-false (forbidden? "100.128.0.1") "just above CGNAT"))

;;; ── IPv4-mapped / compat IPv6 spellings of a forbidden address (the bypass) ──

(test-case "IPv4-mapped and compat forms of loopback/metadata are refused"
  (check-true (forbidden? "::ffff:127.0.0.1") "IPv4-mapped loopback (dotted)")
  (check-true (forbidden? "::ffff:169.254.169.254") "IPv4-mapped metadata")
  (check-true (forbidden? "::ffff:7f00:0001") "IPv4-mapped loopback (hex)")
  (check-true (forbidden? "::127.0.0.1") "IPv4-compat loopback")
  (check-equal? (normalize-ip "::ffff:7f00:0001") "127.0.0.1")
  (check-equal? (normalize-ip "::ffff:127.0.0.1") "127.0.0.1"))

;;; ── IPv6 ranges ──────────────────────────────────────────────────────────────

(test-case "IPv6 loopback / link-local / unique-local / multicast are refused"
  (check-true (forbidden? "::1"))
  (check-true (forbidden? "fe80::1") "link-local")
  (check-true (forbidden? "FE80::1") "link-local, uppercase")
  (check-true (forbidden? "fc00::1") "unique-local")
  (check-true (forbidden? "fd12:3456::1") "unique-local")
  (check-true (forbidden? "ff02::1") "multicast")
  (check-true (forbidden? "fe80::1%eth0") "zone id stripped then refused"))

(test-case "a public IPv6 is allowed"
  (check-false (forbidden? "2606:4700:4700::1111") "cloudflare DNS"))

;;; ── Fail closed on garbage ───────────────────────────────────────────────────

(test-case "unrecognized / malformed forms fail closed (refused)"
  (check-true (forbidden? "not-an-ip"))
  (check-true (forbidden? "999.999.999.999") "out-of-range octets")
  (check-true (forbidden? "") )
  (check-false (parse-ipv4 "999.1.1.1"))
  (check-not-false (parse-ipv4 "8.8.8.8")))

(test-case "ip-forbidden-reason names the range"
  (check-regexp-match #rx"metadata|link-local" (ip-forbidden-reason "169.254.169.254"))
  (check-regexp-match #rx"loopback" (ip-forbidden-reason "127.0.0.1"))
  (check-false (ip-forbidden-reason "8.8.8.8")))
