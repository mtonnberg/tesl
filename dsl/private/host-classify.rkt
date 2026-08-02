#lang racket/base

;;; Host normalization + IP-literal classification — the shared core behind
;;; `Tesl.Net` (the .tesl surface, tesl/net.rkt), `Tesl.Url`'s host component
;;; (tesl/url.rkt) and the runtime SSRF decision (dsl/private/ssrf-guard.rkt).
;;;
;;; WHY THIS EXISTS (GitHub #68).  An application that validates an outbound URL
;;; before fetching it has to answer "what is the host, and is it an address I
;;; refuse to dial".  Both halves are string surgery with a well-known set of
;;; footguns, and hand-rolling them with `String.indexOf` gets them wrong in the
;;; same four ways every time:
;;;
;;;   port smuggling      `https://localhost:6379/hook` — cutting the authority
;;;                       at the first `/` leaves "localhost:6379", which equals
;;;                       none of the forbidden host spellings;
;;;   case               `https://LOCALHOST/hook` — hostnames are
;;;                       case-insensitive, `==` is not;
;;;   trailing dot       `https://localhost./hook` — a root-anchored FQDN
;;;                       resolves identically and compares differently;
;;;   alternate literals `https://2130706433/hook` (decimal 127.0.0.1) and
;;;                       `https://[::ffff:127.0.0.1]/hook` (IPv4-mapped) are
;;;                       both the loopback address spelled so that no
;;;                       string compare recognizes it.
;;;
;;; So normalization here is TOTAL and CANONICAL: every host that denotes an IP
;;; address — in any spelling a resolver would accept — comes out as the same
;;; canonical text, and everything else comes out as a lowercased, trailing-dot
;;; stripped DNS name or is rejected outright.  Classification then runs on the
;;; canonical form, never on the input.
;;;
;;; FAIL-CLOSED.  Anything this module cannot fully parse is `'invalid`, which
;;; every caller treats as "refuse", never as "not an address, therefore a
;;; name".  That is the opposite of the natural `String.indexOf` shape, where an
;;; unrecognized spelling silently falls through to the allow path.
;;;
;;; This module is deliberately pure and dependency-free so it can be unit
;;; tested exhaustively (tests/url-net-tests.rkt) and cannot drift from the
;;; ranges the specs name.

(require racket/string
         racket/list)

(provide normalize-host
         classify-host
         host-class->symbol
         normalize-address
         classify-address
         ipv4-octets-class
         ipv6-groups-class
         parse-ipv4-strict
         parse-ipv4-any
         parse-ipv6
         ipv6->string
         ipv4-literal?
         ipv6-literal?
         host-ipv4-mapped?)

;; ── Character predicates ────────────────────────────────────────────────────

(define (ascii-digit? c) (char<=? #\0 c #\9))

(define (hex-digit? c)
  (or (ascii-digit? c) (char<=? #\a c #\f) (char<=? #\A c #\F)))

;; A host label may hold letters, digits, `-` and `_`.  `_` is not legal in a
;; hostname per RFC 1123 but IS legal in the DNS names applications actually
;; look up (`_dmarc.example.com`), and rejecting it here would make
;; `Url.parse` refuse URLs that resolve.  Everything else — including `%`, so
;; percent-encoded host spellings can never smuggle a delimiter past us — is
;; refused.
(define (host-char? c)
  (or (char<=? #\a c #\z)
      (char<=? #\A c #\Z)
      (ascii-digit? c)
      (char=? c #\-)
      (char=? c #\_)))

;; ── IPv4 ────────────────────────────────────────────────────────────────────

;; Strict dotted quad: exactly four decimal octets in [0,255].  This is the
;; CANONICAL form; `parse-ipv4-any` covers the spellings a resolver also accepts.
;; Returns a list of four octets, or #f.
(define (parse-ipv4-strict s)
  (define parts (string-split s "." #:trim? #f))
  (and (= 4 (length parts))
       (let ([octets
              (for/list ([p (in-list parts)])
                (and (> (string-length p) 0)
                     (<= (string-length p) 3)
                     (for/and ([c (in-string p)]) (ascii-digit? c))
                     (let ([n (string->number p 10)])
                       (and n (<= 0 n 255) n))))])
         (and (andmap values octets) octets))))

;; One `inet_aton` part: 0x/0X = hex, leading 0 = octal, else decimal.
;; Returns the non-negative integer, or #f.
(define (parse-inet-part p)
  (define n (string-length p))
  (cond
    [(= n 0) #f]
    [(and (> n 2) (char=? (string-ref p 0) #\0)
          (memv (string-ref p 1) '(#\x #\X)))
     (define body (substring p 2))
     (and (for/and ([c (in-string body)]) (hex-digit? c))
          (string->number body 16))]
    [(and (> n 1) (char=? (string-ref p 0) #\0))
     (define body (substring p 1))
     (and (for/and ([c (in-string body)]) (char<=? #\0 c #\7))
          (string->number body 8))]
    [else
     (and (for/and ([c (in-string p)]) (ascii-digit? c))
          (string->number p 10))]))

;; Every IPv4 spelling `inet_aton` (and therefore curl, and therefore an
;; attacker's URL) accepts, reduced to four octets:
;;   a            32-bit    2130706433      -> 127.0.0.1
;;   a.b          b is 24-bit   127.1       -> 127.0.0.1
;;   a.b.c        c is 16-bit   127.0.1     -> 127.0.0.1
;;   a.b.c.d      four octets   0x7f.0.0.1  -> 127.0.0.1
;; Returns a list of four octets, or #f when the string is not wholly numeric
;; in this sense (i.e. it is a DNS name, or garbage).
(define (parse-ipv4-any s)
  (define parts (string-split s "." #:trim? #f))
  (define k (length parts))
  (and (<= 1 k 4)
       (let ([vals (map parse-inet-part parts)])
         (and (andmap values vals)
              (let* ([lead (take vals (sub1 k))]
                     [tail (last vals)]
                     [tail-bits (* 8 (- 4 (sub1 k)))])
                (and (andmap (lambda (v) (<= 0 v 255)) lead)
                     (< tail (arithmetic-shift 1 tail-bits))
                     (let ([n (+ (for/fold ([acc 0]) ([v (in-list lead)])
                                   (+ (arithmetic-shift acc 8) v))
                                 0)])
                       (define full
                         (+ (arithmetic-shift n tail-bits) tail))
                       (list (bitwise-and (arithmetic-shift full -24) 255)
                             (bitwise-and (arithmetic-shift full -16) 255)
                             (bitwise-and (arithmetic-shift full -8) 255)
                             (bitwise-and full 255)))))))))

(define (ipv4->string o)
  (string-join (map number->string o) "."))

;; ── IPv6 ────────────────────────────────────────────────────────────────────

;; Parse an IPv6 literal (WITHOUT surrounding brackets, WITHOUT a zone id) into
;; a list of eight 16-bit groups, or #f.  Handles `::` compression and the
;; embedded dotted-quad tail (`::ffff:127.0.0.1`).
(define (parse-ipv6 s0)
  (define s (string-downcase s0))
  (and (> (string-length s) 0)
       (not (regexp-match? #rx"[^0-9a-f:.]" s))
       (let* ([dbl (regexp-match-positions #rx"::" s)])
         (cond
           ;; more than one "::" is not a valid literal
           [(and dbl (regexp-match? #rx"::.*::" s)) #f]
           [dbl
            (define at (caar dbl))
            (define head (substring s 0 at))
            (define tail (substring s (+ at 2)))
            (define hg (if (string=? head "") '() (groups-of head)))
            (define tg (if (string=? tail "") '() (groups-of tail)))
            (and hg tg
                 (let ([fill (- 8 (length hg) (length tg))])
                   (and (>= fill 1)
                        (append hg (make-list fill 0) tg))))]
           [else
            (define g (groups-of s))
            (and g (= 8 (length g)) g)]))))

;; Split a colon-separated run into 16-bit groups; the LAST element may be a
;; dotted quad, which expands to two groups.  Returns #f on any bad group.
(define (groups-of run)
  (define parts (string-split run ":" #:trim? #f))
  (and (pair? parts)
       (not (ormap (lambda (p) (string=? p "")) parts))
       (let loop ([ps parts] [acc '()])
         (cond
           [(null? ps) (reverse acc)]
           [(string-contains? (car ps) ".")
            ;; only legal as the final element
            (and (null? (cdr ps))
                 (let ([o (parse-ipv4-strict (car ps))])
                   (and o
                        (reverse
                         (cons (+ (* 256 (caddr o)) (cadddr o))
                               (cons (+ (* 256 (car o)) (cadr o)) acc))))))]
           [else
            (define p (car ps))
            (and (<= 1 (string-length p) 4)
                 (for/and ([c (in-string p)]) (hex-digit? c))
                 (loop (cdr ps) (cons (string->number p 16) acc)))]))))

;; RFC 5952 text for eight groups: lowercase hex, no leading zeros, the LONGEST
;; run of >= 2 zero groups compressed to `::` (leftmost on a tie).
(define (ipv6->string g)
  (define-values (best-start best-len)
    (let loop ([i 0] [cur-start #f] [cur-len 0] [bs #f] [bl 0])
      (cond
        [(= i 8)
         (if (> cur-len bl) (values cur-start cur-len) (values bs bl))]
        [(zero? (list-ref g i))
         (define st (or cur-start i))
         (loop (add1 i) st (add1 cur-len) bs bl)]
        [else
         (if (> cur-len bl)
             (loop (add1 i) #f 0 cur-start cur-len)
             (loop (add1 i) #f 0 bs bl))])))
  (define compress? (and best-start (>= best-len 2)))
  (cond
    [(not compress?)
     (string-join (for/list ([x (in-list g)]) (number->string x 16)) ":")]
    [else
     (define head (for/list ([x (in-list g)] [i (in-naturals)]
                             #:when (< i best-start))
                    (number->string x 16)))
     (define tail (for/list ([x (in-list g)] [i (in-naturals)]
                             #:when (>= i (+ best-start best-len)))
                    (number->string x 16)))
     (string-append (string-join head ":") "::" (string-join tail ":"))]))

;; `::ffff:a.b.c.d` (IPv4-mapped) and the deprecated `::a.b.c.d` (IPv4-compat)
;; are the SAME address as `a.b.c.d` for every purpose a classifier cares about,
;; so they canonicalize to the dotted quad.  `::` and `::1` are their own
;; addresses and are NOT folded.
(define (ipv6-embedded-ipv4 g)
  (define (v4-of) (list (arithmetic-shift (list-ref g 6) -8)
                        (bitwise-and (list-ref g 6) 255)
                        (arithmetic-shift (list-ref g 7) -8)
                        (bitwise-and (list-ref g 7) 255)))
  (define zero-head? (for/and ([i (in-range 5)]) (zero? (list-ref g i))))
  (cond
    [(and zero-head? (= #xffff (list-ref g 5))) (v4-of)]
    ;; IPv4-compatible `::a.b.c.d`.  Requires a non-zero upper half so `::`,
    ;; `::1` and the other low IPv6 addresses stay IPv6 rather than folding into
    ;; the 0.0.0.0/8 block by accident.
    [(and zero-head? (zero? (list-ref g 5)) (not (zero? (list-ref g 6))))
     (v4-of)]
    [else #f]))

;; ── Range classification ────────────────────────────────────────────────────

;; The class of a dotted-quad address, as a symbol.  ONE table — the SSRF
;; runtime decision (dsl/private/ssrf-guard.rkt) reads it too, so the ranges a
;; `.tesl` app checks and the ranges the HTTP client refuses cannot diverge.
(define (ipv4-octets-class o)
  (define a (car o)) (define b (cadr o)) (define c (caddr o)) (define d (cadddr o))
  (cond
    [(= a 0)                        'unspecified]   ; 0.0.0.0/8 "this network"
    [(= a 127)                      'loopback]      ; 127.0.0.0/8
    [(= a 10)                       'private]       ; 10.0.0.0/8
    [(and (= a 169) (= b 254))      'link-local]    ; 169.254.0.0/16 (metadata)
    [(and (= a 172) (<= 16 b 31))   'private]       ; 172.16.0.0/12
    [(and (= a 192) (= b 168))      'private]       ; 192.168.0.0/16
    [(and (= a 100) (<= 64 b 127))  'cgnat]         ; 100.64.0.0/10
    [(>= a 224)                     'multicast]     ; 224.0.0.0/4 + reserved
    [else (void c) (void d)         'public-ip]))

;; The class of eight IPv6 groups.  Callers fold the IPv4-mapped/compat forms to
;; a dotted quad BEFORE getting here (see [normalize-host]), so this only sees
;; genuine IPv6 addresses.
(define (ipv6-groups-class g)
  (define g0 (car g))
  (cond
    [(andmap zero? g)                                     'unspecified]  ; ::
    [(and (andmap zero? (take g 7)) (= 1 (list-ref g 7))) 'loopback]     ; ::1
    [(= #xfe80 (bitwise-and g0 #xffc0))                   'link-local]   ; fe80::/10
    [(= #xfc00 (bitwise-and g0 #xfe00))                   'private]      ; fc00::/7 ULA
    [(= #xff00 (bitwise-and g0 #xff00))                   'multicast]    ; ff00::/8
    [else                                                 'public-ip]))

;; ── Address normalization (bare addresses, not URL hosts) ───────────────────

;; Canonicalize a BARE IP address — no brackets, an IPv6 zone id (`%eth0`)
;; tolerated and dropped.  Returns the canonical text, or #f when the string is
;; not an address at all.
;;
;; This is the entry point for a RESOLVED address (dsl/private/ssrf-guard.rkt);
;; [normalize-host] is the entry point for a URL host component, where an IPv6
;; literal must be bracketed and a zone id is refused.
(define (normalize-address raw)
  (and
   (string? raw)
   (> (string-length raw) 0)
   (let* ([s0 (string-downcase (string-trim raw))]
          [pct (let loop ([i 0])
                 (cond [(>= i (string-length s0)) #f]
                       [(char=? (string-ref s0 i) #\%) i]
                       [else (loop (add1 i))]))]
          [s (if pct (substring s0 0 pct) s0)])
     (cond
       [(string=? s "") #f]
       [(parse-ipv4-any s) => ipv4->string]
       [(parse-ipv6 s)
        => (lambda (g)
             (let ([v4 (ipv6-embedded-ipv4 g)])
               (if v4 (ipv4->string v4) (ipv6->string g))))]
       [else #f]))))

;; Class of a BARE address: one of the range symbols, or 'invalid when the
;; string is not an address this module recognizes.  Fail-closed by
;; construction — there is no "probably fine" answer.
(define (classify-address raw)
  (define a (normalize-address raw))
  (cond
    [(not a) (values 'invalid #f)]
    [(parse-ipv4-strict a) => (lambda (o) (values (ipv4-octets-class o) a))]
    [(parse-ipv6 a) => (lambda (g) (values (ipv6-groups-class g) a))]
    [else (values 'invalid #f)]))

;; ── Host normalization ──────────────────────────────────────────────────────

;; Canonicalize a URL host component.  Accepts the bracketed IPv6 form.
;; Returns the canonical host string, or #f when the input is not a host this
;; module will vouch for (which every caller treats as "refuse").
;;
;;   "LOCALHOST."            -> "localhost"
;;   "2130706433"            -> "127.0.0.1"
;;   "0x7f.0.0.1"            -> "127.0.0.1"
;;   "[::FFFF:127.0.0.1]"    -> "127.0.0.1"
;;   "[2606:4700::1111]"     -> "2606:4700::1111"
;;   "exa mple.com"          -> #f
(define (normalize-host raw)
  (and (string? raw)
       (let ([n (string-length raw)])
         (cond
           [(= n 0) #f]
           ;; Bracketed literal: IPv6 only, no zone id (a zone id is meaningless
           ;; off-host and is a classic parser-differential, so it is refused).
           [(char=? (string-ref raw 0) #\[)
            (and (char=? (string-ref raw (sub1 n)) #\])
                 (let* ([inner (substring raw 1 (sub1 n))]
                        [g (parse-ipv6 inner)])
                   (and g
                        (let ([v4 (ipv6-embedded-ipv4 g)])
                          (if v4 (ipv4->string v4) (ipv6->string g))))))]
           [(regexp-match? #rx"[]:/?#@\\\\%[]" raw) #f]
           [else
            (define lower (string-downcase raw))
            ;; strip ONE root-anchoring trailing dot; `a..` stays invalid below
            (define stripped
              (if (and (> (string-length lower) 1)
                       (char=? (string-ref lower (sub1 (string-length lower))) #\.))
                  (substring lower 0 (sub1 (string-length lower)))
                  lower))
            (cond
              [(string=? stripped "") #f]
              [(> (string-length stripped) 253) #f]
              ;; Numeric in any inet_aton spelling => it IS an address, not a name.
              [(parse-ipv4-any stripped) => ipv4->string]
              [else
               (define labels (string-split stripped "." #:trim? #f))
               (and (pair? labels)
                    (andmap (lambda (l)
                              (and (<= 1 (string-length l) 63)
                                   (for/and ([c (in-string l)]) (host-char? c))))
                            labels)
                    ;; An all-numeric final label is never a DNS name (RFC 3696):
                    ;; it is a MALFORMED address literal — `999.999.999.999`,
                    ;; `0xzz.1`, an out-of-range 32-bit decimal.  Falling through
                    ;; to 'domain-name here would be the fail-OPEN answer, since
                    ;; a caller reads 'domain-name as "not an address literal".
                    (not (for/and ([c (in-string (last labels))]) (ascii-digit? c)))
                    stripped)])]))))

;; ── The public classification ───────────────────────────────────────────────

;; Classify a raw URL host component.  Returns two values: the class symbol and
;; the canonical host (#f when the class is 'invalid).
;;
;; 'loopback 'private 'link-local 'cgnat 'multicast 'unspecified 'public-ip
;;   the host IS an address literal, in some spelling, of that range;
;; 'domain-name
;;   a syntactically valid DNS name that is NOT an address literal.  It may
;;   still RESOLVE to a forbidden address — deciding that needs a resolver and
;;   connect-pinning, which is the HTTP client's job (issue #48), not a string
;;   check's;
;; 'invalid
;;   not a host this module will vouch for.  Refuse.
;;
;; `localhost` (and any `*.localhost` name) is classified 'loopback: RFC 6761
;; reserves it and resolvers are required to map it to the loopback address, so
;; treating it as an ordinary name would be a bypass by definition.
(define (classify-host raw)
  (define h (normalize-host raw))
  (cond
    [(not h) (values 'invalid #f)]
    [(parse-ipv4-strict h) => (lambda (o) (values (ipv4-octets-class o) h))]
    [(parse-ipv6 h) => (lambda (g) (values (ipv6-groups-class g) h))]
    [(or (string=? h "localhost") (string-suffix? h ".localhost"))
     (values 'loopback h)]
    [else (values 'domain-name h)]))

(define (host-class->symbol raw)
  (define-values (cls _h) (classify-host raw))
  cls)

(define (ipv4-literal? h) (and (parse-ipv4-strict h) #t))
(define (ipv6-literal? h) (and (parse-ipv6 h) #t))

;; #t when the host was written as an IPv4-mapped / IPv4-compat IPv6 literal —
;; i.e. an IPv6 spelling that denotes an IPv4 address.  Reported separately
;; because it is the spelling most likely to be missed by a hand-written check.
(define (host-ipv4-mapped? raw)
  (define s (if (and (string? raw) (> (string-length raw) 1)
                     (char=? (string-ref raw 0) #\[)
                     (char=? (string-ref raw (sub1 (string-length raw))) #\]))
                (substring raw 1 (sub1 (string-length raw)))
                raw))
  (define g (and (string? s) (parse-ipv6 s)))
  (and g (ipv6-embedded-ipv4 g) #t))
