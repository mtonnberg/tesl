#lang racket/base

;;; Tesl.Url / Tesl.Net runtime suite (GitHub #68).
;;;
;;; The `.tesl` half (tests/url-net-tests.tesl) pins the SURFACE — that a Tesl
;;; program gets the right answer for the four bypasses the issue names.  This
;;; file pins the things a surface test cannot reach and that are exactly where
;;; a re-implementation goes wrong:
;;;
;;;   * the full `inet_aton` spelling matrix (decimal / octal / hex / 1-, 2- and
;;;     3-part short forms), each of which is a distinct way to write 127.0.0.1;
;;;   * IPv6 parsing and RFC 5952 canonical output, including the compression
;;;     rules and the IPv4-mapped / IPv4-compat folds;
;;;   * the parser differentials the URL parser refuses rather than guesses
;;;     about (backslash, control characters, double `@`, unbracketed IPv6);
;;;   * RANGE-BOUNDARY exactness on both sides of every reserved block, because
;;;     an off-by-one in a CIDR mask is invisible to a spot check;
;;;   * AGREEMENT with dsl/private/ssrf-guard.rkt.  The application-level check
;;;     an app writes with `Net.isForbiddenHost` and the runtime refusal that
;;;     Tesl.HttpClient performs on the resolved address (issue #48) read the
;;;     same range table, and this suite is what keeps that true: if the two
;;;     ever disagree about an address, one of them is a bypass.

(require rackunit
         racket/list
         "../dsl/private/host-classify.rkt"
         "../dsl/private/url-parse.rkt"
         (only-in "../dsl/private/ssrf-guard.rkt" ip-address-forbidden?))

(define (cls h) (host-class->symbol h))
(define (norm h) (normalize-host h))

;;; ── Every spelling of 127.0.0.1 ─────────────────────────────────────────────

(test-case "the inet_aton spelling matrix all folds to one canonical address"
  (for ([s (in-list '("127.0.0.1"        ; dotted quad
                      "2130706433"       ; 32-bit decimal
                      "0x7f000001"       ; 32-bit hex
                      "017700000001"     ; 32-bit octal
                      "127.1"            ; a.b   (b is 24-bit)
                      "127.0.1"          ; a.b.c (c is 16-bit)
                      "0x7f.0.0.1"       ; per-part hex
                      "0177.0.0.1"       ; per-part octal
                      "127.000.000.001"  ; zero-padded octal-that-is-still-1
                      "[::ffff:127.0.0.1]"
                      "[::ffff:7f00:1]"
                      "[::7f00:1]"))])   ; deprecated IPv4-compatible
    (check-equal? (norm s) "127.0.0.1" (format "normalize ~a" s))
    (check-eq? (cls s) 'loopback (format "classify ~a" s))))

(test-case "an out-of-range or malformed numeric host is invalid, never a name"
  ;; The dangerous failure here is falling through to 'domain-name, which a
  ;; caller reads as "not an address literal".
  (for ([s (in-list '("999.999.999.999"
                      "256.0.0.1"
                      "4294967296"        ; 2^32, one past the 32-bit form
                      "0x1.0x2.0x3.0x4.5" ; five parts
                      "08.0.0.1"          ; 8 is not an octal digit
                      "127.0.0.1.1"))])
    (check-eq? (cls s) 'invalid (format "classify ~a" s))))

;;; ── IPv6 parsing and canonical form ─────────────────────────────────────────

(test-case "RFC 5952 canonical output"
  (check-equal? (norm "[2606:4700:4700:0000:0000:0000:0000:1111]") "2606:4700:4700::1111")
  (check-equal? (norm "[2001:0DB8:0000:0000:0001:0000:0000:0001]") "2001:db8::1:0:0:1")
  (check-equal? (norm "[::1]") "::1")
  (check-equal? (norm "[::]") "::")
  (check-equal? (norm "[0:0:0:0:0:0:0:1]") "::1"))

(test-case "malformed IPv6 is refused, not waved through as public"
  ;; ssrf-guard's old regexp-shaped check called anything colon-and-hex
  ;; "plausible IPv6" and then allowed it when no prefix matched.
  (for ([s (in-list '("[:::]" "[1::2::3]" "[12345::1]" "[::1" "::1]"
                      "[gg::1]" "[]" "[1:2:3:4:5:6:7]"))])
    (check-eq? (cls s) 'invalid (format "classify ~a" s)))
  ;; an unbracketed IPv6 literal is not a legal URL host
  (check-eq? (cls "::1") 'invalid)
  (check-eq? (cls "fe80::1") 'invalid))

(test-case "a zone id is refused in a URL host but dropped in a bare address"
  (check-eq? (cls "[fe80::1%eth0]") 'invalid)
  (check-equal? (normalize-address "fe80::1%eth0") "fe80::1"))

(test-case "IPv4-mapped is reported as such, and only for real embedded IPv4"
  (check-true  (host-ipv4-mapped? "[::ffff:127.0.0.1]"))
  (check-true  (host-ipv4-mapped? "[::ffff:7f00:1]"))
  (check-true  (host-ipv4-mapped? "[::7f00:1]"))
  (check-false (host-ipv4-mapped? "[::1]"))
  (check-false (host-ipv4-mapped? "[::]"))
  (check-false (host-ipv4-mapped? "127.0.0.1"))
  ;; `::2` is a low IPv6 address, NOT the IPv4-compat spelling of 0.0.0.2
  (check-false (host-ipv4-mapped? "[::2]")))

;;; ── Range boundaries ────────────────────────────────────────────────────────

(test-case "every reserved block is exact on both sides"
  (define cases
    '(;; inside                     outside
      ("10.0.0.0"       private     "9.255.255.255"   public-ip)
      ("10.255.255.255" private     "11.0.0.0"        public-ip)
      ("172.16.0.0"     private     "172.15.255.255"  public-ip)
      ("172.31.255.255" private     "172.32.0.0"      public-ip)
      ("192.168.0.0"    private     "192.167.255.255" public-ip)
      ("192.168.255.255" private    "192.169.0.0"     public-ip)
      ("100.64.0.0"     cgnat       "100.63.255.255"  public-ip)
      ("100.127.255.255" cgnat      "100.128.0.0"     public-ip)
      ("169.254.0.0"    link-local  "169.253.255.255" public-ip)
      ("169.254.255.255" link-local "169.255.0.0"     public-ip)
      ("127.255.255.255" loopback   "126.255.255.255" public-ip)
      ("0.255.255.255"  unspecified "1.0.0.0"         public-ip)
      ("224.0.0.0"      multicast   "223.255.255.255" public-ip)))
  (for ([row (in-list cases)])
    (check-eq? (cls (first row)) (second row) (format "inside ~a" (first row)))
    (check-eq? (cls (third row)) (fourth row) (format "outside ~a" (third row)))))

(test-case "IPv6 block boundaries"
  (check-eq? (cls "[fe80::]")   'link-local)
  (check-eq? (cls "[febf::1]")  'link-local)   ; last of fe80::/10
  (check-eq? (cls "[fec0::1]")  'public-ip)    ; just past it
  (check-eq? (cls "[fc00::1]")  'private)
  (check-eq? (cls "[fdff::1]")  'private)      ; last of fc00::/7
  (check-eq? (cls "[fe00::1]")  'public-ip)    ; just past it
  (check-eq? (cls "[ff00::]")   'multicast)
  (check-eq? (cls "[feff::1]")  'public-ip))

;;; ── Names ───────────────────────────────────────────────────────────────────

(test-case "RFC 6761 localhost names are loopback; ordinary names are not"
  (check-eq? (cls "localhost")         'loopback)
  (check-eq? (cls "LOCALHOST")         'loopback)
  (check-eq? (cls "localhost.")        'loopback)
  (check-eq? (cls "api.localhost")     'loopback)
  (check-eq? (cls "example.com")       'domain-name)
  (check-eq? (cls "localhost.evil.com") 'domain-name)  ; a SUFFIX, not the name
  (check-eq? (cls "notlocalhost")      'domain-name)
  (check-eq? (cls "_dmarc.example.com") 'domain-name))

(test-case "hosts that are not hosts"
  (for ([s (in-list '("" "exa mple.com" "a..b" ".example.com" "example.com.."
                      "loc%61lhost" "example.com/x" "user@example.com"
                      "example.com:80" "exam\tple.com"))])
    (check-eq? (cls s) 'invalid (format "classify ~s" s)))
  ;; exactly ONE root-anchoring dot is stripped; it is a legal FQDN spelling
  (check-equal? (norm "example.com.") "example.com")
  ;; 253 is the DNS limit; one over is refused
  (check-eq? (cls (string-append (make-string 63 #\a) "."
                                 (make-string 63 #\a) "."
                                 (make-string 63 #\a) "."
                                 (make-string 61 #\a)))
             'domain-name)
  (check-eq? (cls (make-string 300 #\a)) 'invalid))

;;; ── URL parsing: the differentials it refuses ───────────────────────────────

(define (host-of s)
  (define u (parse-url s))
  (and u (tesl-url-host u)))

(test-case "the host is the host, never host:port and never userinfo"
  (check-equal? (host-of "https://localhost:6379/hook") "localhost")
  (check-equal? (host-of "https://LOCALHOST./hook") "localhost")
  (check-equal? (host-of "https://user:pw@127.0.0.1:8080/x") "127.0.0.1")
  ;; the LAST `@` separates — taking the first is itself a bypass
  (check-equal? (host-of "https://a@trusted.example.com@127.0.0.1/") "127.0.0.1")
  (check-equal? (tesl-url-userinfo (parse-url "https://a@trusted.example.com@127.0.0.1/"))
                "a@trusted.example.com")
  ;; an `@` with nothing before it still REPORTS userinfo, so a guard shaped as
  ;; "refuse any URL carrying userinfo" fires on it too
  (check-equal? (tesl-url-userinfo (parse-url "https://@example.com/")) "")
  (check-equal? (host-of "https://@example.com/") "example.com"))

(test-case "URLs a second parser might read differently are refused"
  (for ([s (in-list '("https://example.com\\@localhost/"  ; browsers read \ as /
                      "https://exa mple.com/"
                      "https://example.com /"
                      "https://example.com\n/"
                      "https:/example.com/"               ; no authority
                      "https:example.com/"
                      "mailto:a@example.com"
                      "//example.com/"                    ; no scheme
                      "1https://example.com/"             ; scheme must start alpha
                      "https://user@/x"                   ; empty host after @
                      "https://"
                      "https://host:/p"                   ; empty port
                      "https://host:0/p"                  ; port 0
                      "https://host:65536/p"
                      "https://host:8o8/p"
                      "https://::1/p"                     ; unbracketed IPv6
                      "https://[::1/p"))])                ; unterminated bracket
    (check-false (parse-url s) (format "must refuse ~s" s))))

(test-case "components, defaults and round-trip"
  (define u (parse-url "HTTP://Example.COM/a/b?x=1&y=2#f"))
  (check-equal? (tesl-url-scheme u) "http")
  (check-equal? (tesl-url-host u) "example.com")
  (check-equal? (tesl-url-port u) #f)
  (check-equal? (url-effective-port u) 80)
  (check-equal? (tesl-url-path u) "/a/b")
  (check-equal? (tesl-url-query u) "x=1&y=2")
  (check-equal? (tesl-url-fragment u) "f")
  (check-equal? (url->string u) "http://example.com/a/b?x=1&y=2#f")
  ;; an empty query/fragment is PRESENT — the distinction survives round-trip
  (check-equal? (tesl-url-query (parse-url "https://h/p?")) "")
  (check-equal? (url->string (parse-url "https://h/p?")) "https://h/p?")
  (check-equal? (tesl-url-query (parse-url "https://h/p")) #f)
  ;; an IPv6 host re-brackets
  (check-equal? (url->string (parse-url "https://[2606:4700:4700:0:0:0:0:1111]:8443/p"))
                "https://[2606:4700:4700::1111]:8443/p")
  ;; a path-less URL gets "/"
  (check-equal? (tesl-url-path (parse-url "https://example.com")) "/")
  (check-equal? (url-effective-port (parse-url "ssh://example.com")) #f))

;;; ── Agreement with the runtime SSRF decision (issue #48) ────────────────────

(test-case "Net's classification and HttpClient's egress refusal cannot diverge"
  ;; Same table, so for every ADDRESS the app-level verdict and the runtime
  ;; verdict must be identical.  A disagreement in either direction is a bug:
  ;; app-allows/runtime-refuses is a confusing outage, and app-refuses/
  ;; runtime-allows means an app's guard is weaker than it looks.
  (define addresses
    '("127.0.0.1" "127.255.255.255" "10.0.0.1" "172.16.0.1" "172.15.0.1"
      "192.168.1.1" "169.254.169.254" "100.64.0.1" "100.63.255.255"
      "0.0.0.0" "224.0.0.1" "8.8.8.8" "1.1.1.1" "140.82.121.3"
      "::1" "::" "fe80::1" "fc00::1" "fd12:3456::1" "ff02::1"
      "2606:4700:4700::1111" "::ffff:127.0.0.1" "::ffff:169.254.169.254"))
  (for ([a (in-list addresses)])
    (define-values (klass _canon) (classify-address a))
    (define app-forbids? (not (eq? klass 'public-ip)))
    (check-equal? app-forbids? (ip-address-forbidden? a)
                  (format "verdict disagreement on ~a (class ~a)" a klass))))

(test-case "the runtime still fails closed on what it cannot parse"
  (for ([a (in-list '("not-an-ip" "" "999.999.999.999" "example.com"))])
    (check-true (ip-address-forbidden? a) (format "must refuse ~s" a))))
