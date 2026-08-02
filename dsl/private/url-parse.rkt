#lang racket/base

;;; URL parsing core for `Tesl.Url` (GitHub #68) — the struct plus the parser.
;;;
;;; Split out of tesl/url.rkt for the same reason money-core.rkt is split out of
;;; tesl/money.rkt: the surface module is the Tesl binding layer (unwrap, wrap in
;;; Maybe), and the logic underneath has to be unit-testable on its own.
;;;
;;; SCOPE, and why it is narrow.  This parses AUTHORITY-BASED URLs only —
;;; `scheme://host[:port][/path][?query][#fragment]`.  A URL with no `//`
;;; authority (`mailto:a@b`, `data:…`) has no host, and the entire reason this
;;; parser exists is so that "what is the host" is never a hand-rolled
;;; computation.  Returning a Url whose `host` is sometimes meaningless would
;;; reintroduce exactly the ambiguity it removes, so those parse to #f.
;;;
;;; FAIL-CLOSED throughout.  Every construct that two parsers might disagree
;;; about is refused rather than guessed:
;;;
;;;   * ASCII control characters, spaces and tabs anywhere (browsers strip some
;;;     of these; a checker that strips differently from the client that
;;;     eventually fetches is a parser differential);
;;;   * backslashes (browsers treat `\` as `/` in the authority — so
;;;     `https://example.com\@localhost/` is a host swap);
;;;   * a non-bracketed authority holding more than one `:` (an unbracketed
;;;     IPv6 literal is not decidable from a port);
;;;   * an empty port (`https://host:/p`), a port outside 1..65535, and any
;;;     host that {!Host-classify.normalize-host} will not vouch for.
;;;
;;; The userinfo slot is PARSED AND EXPOSED rather than dropped, because
;;; `https://trusted.example.com@127.0.0.1/` is the fifth member of the family
;;; of bypasses in #68: everything before the last `@` is credentials, and a
;;; check that eyeballs the string sees the trusted name.

(require racket/string
         "host-classify.rkt")

(provide (struct-out tesl-url)
         parse-url
         url->string
         url-effective-port
         scheme-default-port)

;; scheme   lowercased, no trailing `:`
;; userinfo the raw text before the last `@` of the authority, or #f
;; host     the CANONICAL host (see host-classify.rkt), never #f
;; port     exact integer in 1..65535, or #f when not written
;; path     always non-empty, always starts with `/`
;; query    text after `?` up to `#` (may be ""), or #f when no `?` was written
;; fragment text after the first `#` (may be ""), or #f when none was written
(struct tesl-url (scheme userinfo host port path query fragment) #:transparent)

(define (control-or-space? c)
  (or (char<=? c #\space) (char=? c #\rubout)))

(define (scheme-char? c)
  (or (char<=? #\a c #\z) (char<=? #\A c #\Z)
      (char<=? #\0 c #\9)
      (memv c '(#\+ #\- #\.))))

(define (scheme-default-port s)
  (cond
    [(string=? s "http")  80]
    [(string=? s "https") 443]
    [(string=? s "ws")    80]
    [(string=? s "wss")   443]
    [(string=? s "ftp")   21]
    [else #f]))

(define (url-effective-port u)
  (or (tesl-url-port u) (scheme-default-port (tesl-url-scheme u))))

;; Index of the first character of [s] at or after [from] that is in [chars].
(define (index-of-any s chars from)
  (let loop ([i from])
    (cond
      [(>= i (string-length s)) #f]
      [(memv (string-ref s i) chars) i]
      [else (loop (add1 i))])))

;; Parse an authority-based URL string into a [tesl-url], or #f.
(define (parse-url raw)
  (and
   (string? raw)
   (> (string-length raw) 0)
   ;; No control characters, spaces or backslashes ANYWHERE — see the header.
   (not (for/or ([c (in-string raw)])
          (or (control-or-space? c) (char=? c #\\))))
   (let ([colon (index-of-any raw '(#\:) 0)])
     (and colon
          (> colon 0)
          (char<=? #\a (char-downcase (string-ref raw 0)) #\z)
          (for/and ([c (in-string (substring raw 0 colon))]) (scheme-char? c))
          (let ([scheme (string-downcase (substring raw 0 colon))]
                [rest (substring raw (add1 colon))])
            (and (string-prefix? rest "//")
                 (parse-after-slashes scheme (substring rest 2))))))))

(define (parse-after-slashes scheme s)
  (define stop (index-of-any s '(#\/ #\? #\#) 0))
  (define authority (if stop (substring s 0 stop) s))
  (define remainder (if stop (substring s stop) ""))
  (and
   (> (string-length authority) 0)
   (let*-values ([(userinfo hostport) (split-userinfo authority)])
     (and
      hostport
      (let-values ([(host port ok?) (split-host-port hostport)])
        (and ok?
             (let ([canon (normalize-host host)])
               (and canon
                    (let-values ([(path query fragment) (split-remainder remainder)])
                      (tesl-url scheme userinfo canon port path query fragment))))))))))

;; Everything before the LAST `@` is userinfo — that is what browsers and curl
;; do, and taking the first `@` instead is itself a bypass
;; (`https://a@trusted.example.com@127.0.0.1/`).
(define (split-userinfo authority)
  (define at
    (let loop ([i (sub1 (string-length authority))])
      (cond
        [(< i 0) #f]
        [(char=? (string-ref authority i) #\@) i]
        [else (loop (sub1 i))])))
  (cond
    [(not at) (values #f authority)]
    [(= at (sub1 (string-length authority))) (values #f #f)]  ; `user@` with no host
    [else (values (substring authority 0 at) (substring authority (add1 at)))]))

;; Split `host[:port]`.  Returns (host port ok?) — `ok?` is #f when the shape is
;; ambiguous or the port is malformed, which the caller turns into a parse
;; failure rather than a silent "no port".
(define (split-host-port hp)
  (cond
    ;; bracketed IPv6 literal: `[...]` optionally followed by `:port`
    [(string-prefix? hp "[")
     (define close
       (let loop ([i 0])
         (cond
           [(>= i (string-length hp)) #f]
           [(char=? (string-ref hp i) #\]) i]
           [else (loop (add1 i))])))
     (cond
       [(not close) (values #f #f #f)]
       [else
        (define host (substring hp 0 (add1 close)))
        (define tail (substring hp (add1 close)))
        (cond
          [(string=? tail "") (values host #f #t)]
          [(string-prefix? tail ":")
           (define p (parse-port (substring tail 1)))
           (if p (values host p #t) (values #f #f #f))]
          [else (values #f #f #f)])])]
    [else
     (define parts (string-split hp ":" #:trim? #f))
     (cond
       [(= 1 (length parts)) (values (car parts) #f #t)]
       [(= 2 (length parts))
        (define p (parse-port (cadr parts)))
        (if p (values (car parts) p #t) (values #f #f #f))]
       ;; more than one colon and no brackets: an unbracketed IPv6 literal is
       ;; indistinguishable from a bad port, so refuse instead of guessing.
       [else (values #f #f #f)])]))

(define (parse-port s)
  (and (> (string-length s) 0)
       (<= (string-length s) 5)
       (for/and ([c (in-string s)]) (char<=? #\0 c #\9))
       (let ([n (string->number s 10)])
         (and n (<= 1 n 65535) n))))

;; Split what follows the authority into path / query / fragment.
(define (split-remainder r)
  (define hash (index-of-any r '(#\#) 0))
  (define before (if hash (substring r 0 hash) r))
  (define fragment (and hash (substring r (add1 hash))))
  (define q (index-of-any before '(#\?) 0))
  (define path0 (if q (substring before 0 q) before))
  (define query (and q (substring before (add1 q))))
  (values (if (string=? path0 "") "/" path0) query fragment))

;; Re-serialize a parsed URL from its CANONICAL parts.  Round-tripping through
;; this is what makes "the string I checked" and "the string I fetch" the same
;; string — the normalization is not advisory.
(define (url->string u)
  (define host (tesl-url-host u))
  (define bracketed (if (ipv6-literal? host) (string-append "[" host "]") host))
  (string-append
   (tesl-url-scheme u) "://"
   (let ([ui (tesl-url-userinfo u)]) (if ui (string-append ui "@") ""))
   bracketed
   (let ([p (tesl-url-port u)]) (if p (string-append ":" (number->string p)) ""))
   (tesl-url-path u)
   (let ([q (tesl-url-query u)]) (if q (string-append "?" q) ""))
   (let ([f (tesl-url-fragment u)]) (if f (string-append "#" f) ""))))
