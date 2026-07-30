#lang racket

;; ── Tesl.Http ────────────────────────────────────────────────────────────────
;;
;; The HTTP request/response surface a Tesl program can name.  Two halves:
;;
;;   READING the request  — `HttpRequest` (the opaque type name) and
;;                          `Http.sessionToken`.  Pure, ungated: request data is
;;                          not an effect.
;;   WRITING the response — `Http.setSessionCookie` / `Http.clearSessionCookie`,
;;                          gated by `cookieCap`.
;;
;; There is exactly ONE cookie in this module, it always carries a signed
;; `JwtToken`, and every attribute of it is fixed.  See
;; roadmap/completed/response_metadata_and_cookies.md for why there are no
;; options, no second cookie-writing function, and no general response-header
;; setter.  Briefly: a caller who can pass `SameSite=None` will.

(require (only-in "../dsl/capability.rkt" define-capability require-capabilities!)
         (only-in "../dsl/types.rkt" Something Nothing
                  newtype-value? newtype-value-value)
         (only-in "../dsl/private/check-runtime.rkt" raw-value)
         (only-in "../dsl/response-cookies.rkt" response-cookie-set!)
         (only-in "../dsl/web.rkt" dsl-request? dsl-request-cookies)
         ;; `JwtToken` is the wire value the writer demands and the reader
         ;; yields; `jwt-ttl-seconds` is the SINGLE SOURCE for the cookie's
         ;; Max-Age, so the cookie can never outlive the token inside it.
         (only-in "jwt.rkt" JwtToken jwt-ttl-seconds))

(provide HttpRequest
         cookieCap
         Http.setSessionCookie
         Http.clearSessionCookie
         Http.sessionToken
         ;; internal: the fixed name, exported for the test suites that assert
         ;; the full `Set-Cookie` line and for `Tesl.ApiTest`'s reader.
         session-cookie-name)

;; The opaque request type name (used by the checker's field-access machinery
;; and by `register-runtime-type/runtime!` in dsl/web.rkt).
(define HttpRequest 'HttpRequest)

;; ── Capability ───────────────────────────────────────────────────────────────
;; Writing a cookie is an effect on the response, so it is capability-gated —
;; the `emailCap` precedent.  READING `request.cookies` or calling
;; `Http.sessionToken` is not gated: it is pure request data.
(define-capability cookieCap)

;; ── The one cookie ───────────────────────────────────────────────────────────
;;
;; `__Host-` is not decoration.  The prefix makes the BROWSER itself refuse the
;; cookie unless it is `Secure`, `Path=/` and has no `Domain` — so a
;; plaintext-HTTP deployment on a non-localhost origin visibly fails to store a
;; session instead of quietly transmitting one in the clear.  "Session over
;; plaintext" is not a configuration.  Browsers exempt `http://localhost`, so
;; local development is unaffected, and api-tests/curl ignore attributes
;; entirely.
(define session-cookie-name "__Host-session")

;; SameSite=Lax (not Strict) so that following an ordinary link back into the
;; app arrives authenticated; combined with Tesl's 415 on non-JSON request
;; bodies and the absence of CORS headers on JSON routes, a cross-site form or
;; fetch cannot reach a state-changing handler.  The remaining obligation is the
;; one Tesl already teaches: GET handlers do not mutate.
(define session-cookie-attributes "Path=/; HttpOnly; Secure; SameSite=Lax")

;; A JWT is three base64url segments separated by dots — every character of it
;; is cookie-safe.  Validating that explicitly turns a hypothetical forged or
;; hand-built `JwtToken` into a loud error instead of a `Set-Cookie` header
;; injection (a `;` or a newline in the value would let the caller append
;; attributes, or a second header).  A well-typed program never reaches the
;; raise: the only source of a `JwtToken` is `JWT.sign`.
(define jwt-wire-rx #px"^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$")

(define (session-token-string who token)
  (define raw (raw-value token))
  (define s (if (newtype-value? raw) (newtype-value-value raw) raw))
  (unless (and (string? s) (regexp-match? jwt-wire-rx s))
    (error who
           (string-append
            "expected a JwtToken produced by `JWT.sign`, got ~s.\n"
            "  A session cookie must carry a signed token; this value is not a\n"
            "  well-formed JWT and will not be written to the response.")
           s))
  s)

;; NOTE on the unwrap order above: `raw-value` FIRST, then strip the newtype.
;; The reverse order is a bug this codebase has now hit three times — a
;; `named-value` wrapping a `JwtToken` falls through a leading `newtype-value?`
;; test, `raw-value` then removes only the `named-value`, and a `newtype-value`
;; reaches `string?` as #f.  See the long note at `tesl/jwt.rkt`'s
;; `jwt-raw-string` and `tesl/string.rkt`'s `raw-str`.

;; Http.setSessionCookie : JwtToken -> Unit   # requires [cookieCap]
;;
;; Records the session cookie on the response being built.  It attaches to 2xx
;; responses only (dsl/web.rkt decides that), so a handler that sets a cookie
;; and then `fail`s mints no session.  Within one request, the last call wins.
(define (Http.setSessionCookie token)
  (require-capabilities! (list cookieCap))
  (define value (session-token-string 'Http.setSessionCookie token))
  (response-cookie-set!
   'Http.setSessionCookie
   (format "~a=~a; ~a; Max-Age=~a"
           session-cookie-name value session-cookie-attributes jwt-ttl-seconds))
  (void))

;; Http.clearSessionCookie : () -> Unit   # requires [cookieCap]
;;
;; The logout half: the same cookie, same attributes, `Max-Age=0` and an empty
;; value, which is how a browser is told to drop it.
;;
;; Honest limitation, documented in the lesson: this removes the BROWSER's copy.
;; It does not invalidate the token — a captured token stays verifiable until
;; `exp`, bounded at one hour by the fixed TTL.  That is the trade a stateless,
;; horizontally-scalable session makes; server-side revocation needs a shared
;; store and is deliberately not built.
(define (Http.clearSessionCookie)
  (require-capabilities! (list cookieCap))
  (response-cookie-set!
   'Http.clearSessionCookie
   (format "~a=; ~a; Max-Age=0" session-cookie-name session-cookie-attributes))
  (void))

;; Http.sessionToken : HttpRequest -> Maybe JwtToken
;;
;; The reader, for symmetry — so the fixed cookie name is written down ONCE, in
;; this file, instead of being spelled out at every call site as
;; `Dict.lookup "__Host-session" request.cookies` where a typo is a permanent
;; 401.  Pure and ungated; `JWT.verify` is what sits between this and a fact.
(define (Http.sessionToken request)
  (define req (raw-value request))
  (unless (dsl-request? req)
    (error 'Http.sessionToken "expected an HttpRequest, got ~s" req))
  (define cookies (dsl-request-cookies req))
  (define value (and (hash? cookies) (hash-ref cookies session-cookie-name #f)))
  (if value (Something (JwtToken value)) Nothing))
