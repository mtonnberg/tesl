#lang racket

;;; Tesl.Url — parse a URL into its components (GitHub #68).
;;;
;;; The point of this module is that an application never has to compute "what
;;; is the host of this URL" with `String.indexOf` and `String.slice` again.
;;; Every application that validated an outbound URL by hand wrote the same
;;; recipe — cut at the first `/`, fall back to `:` — and every one of them
;;; shipped the same bugs: `https://localhost:6379/hook` compares as the host
;;; `localhost:6379` (so no forbidden-host list matches it), `LOCALHOST` and
;;; `localhost.` compare as different hosts from `localhost`, and
;;; `https://2130706433/hook` is the loopback address written so that no string
;;; check recognizes it.
;;;
;;; So `Url.parse` is total and canonical: it either refuses the string outright
;;; or hands back components that are already normalized —
;;; {!Url.host} is lowercased, trailing-dot stripped, unbracketed, and any IP
;;; literal is in canonical form no matter how it was spelled.  The port is a
;;; separate field, so it can never ride along inside the host.  Classification
;;; of the resulting host (loopback / private / link-local / …) is `Tesl.Net`.
;;;
;;; Pure module: no capability.  See dsl/private/url-parse.rkt for the parse
;;; rules and for why non-authority URLs (`mailto:`) are refused.
;;;
;;; SCOPE.  This is the SHALLOW half of outbound-URL safety, and it is not the
;;; whole control: a syntactically fine hostname can still resolve to
;;; 127.0.0.1 or 169.254.169.254.  Refusing that is the HTTP client's
;;; resolve-then-pin behaviour (issue #48), which is always on for
;;; `Tesl.HttpClient` and needs nothing from the application.

(require "../dsl/check.rkt"
         "../dsl/types.rkt"
         "../dsl/private/url-parse.rkt")

(provide
 ;; type-name symbol (mirrors Money/Dict: the imported type name is a value)
 Url
 ;; parse + accessors
 Url.parse
 Url.scheme
 Url.host
 Url.port
 Url.effectivePort
 Url.path
 Url.query
 Url.fragment
 Url.userInfo
 Url.toString)

;; Unwrap a (possibly proof-bearing, possibly newtype-wrapped) value to a plain
;; Racket string — same convention as tesl/string.rkt and tesl/regex.rkt.
(define (raw-str s)
  (define v (raw-value s))
  (if (newtype-value? v) (newtype-value-value v) v))

(define Url 'Url)

(define (as-url who u)
  (define v (raw-value u))
  (unless (tesl-url? v)
    (raise-user-error who "expected a Url (from Url.parse), got ~e" v))
  v)

(define (maybe-of v) (if v (Something v) Nothing))

;; String -> Maybe Url
(define (Url.parse s)
  (maybe-of (parse-url (raw-str s))))

(define (Url.scheme u)       (tesl-url-scheme (as-url 'Url.scheme u)))
(define (Url.host u)         (tesl-url-host (as-url 'Url.host u)))
(define (Url.path u)         (tesl-url-path (as-url 'Url.path u)))
(define (Url.toString u)     (url->string (as-url 'Url.toString u)))

;; Maybe Int — the port only when it was WRITTEN in the URL.
(define (Url.port u)         (maybe-of (tesl-url-port (as-url 'Url.port u))))

;; Maybe Int — the written port, or the scheme's default (http 80, https 443,
;; ws 80, wss 443, ftp 21).  Nothing for a scheme with no registered default.
(define (Url.effectivePort u)
  (maybe-of (url-effective-port (as-url 'Url.effectivePort u))))

;; Maybe String — present but possibly empty when the delimiter was written
;; (`?` / `#`), Nothing when it was not.  The distinction is load-bearing for
;; re-serialization, which is why it is a Maybe and not a String.
(define (Url.query u)        (maybe-of (tesl-url-query (as-url 'Url.query u))))
(define (Url.fragment u)     (maybe-of (tesl-url-fragment (as-url 'Url.fragment u))))

;; Maybe String — everything before the LAST `@` of the authority.  Exposed, not
;; dropped: `https://trusted.example.com@127.0.0.1/` puts a trusted-looking name
;; in the credentials slot, and a check that reads the URL as text sees it as
;; the host.  A guard that refuses any URL with userinfo present is one line.
(define (Url.userInfo u)     (maybe-of (tesl-url-userinfo (as-url 'Url.userInfo u))))
