#lang racket

;;; Tesl.JWT — JSON Web Token support using HMAC-SHA256.
;;;
;;; Provides the nominal newtype JwtToken (a signed JWT string) plus JWT.sign,
;;; JWT.verify and JWT.decode.
;;;
;;; The SIGNING KEY is `Secret`, Tesl.Crypto's key-material type — there is ONE
;;; key type in the language.  A JWT-ONLY key newtype lived here until
;;; 2026-07-30 and was DELETED, not aliased: `Env.requireSecret` returns
;;; `Secret`, so with two types the shipped examples had to rewrap the signing key
;;; through a plain `String`, which defeats the redaction the secret types exist to
;;; guarantee.  `Env.requireSecret "…"` now feeds `JWT.sign` / `JWT.verify`
;;; directly and no `String` ever holds key material.
;;;
;;; The `jwt` capability gates all JWT operations; `JWT.sign` additionally needs
;;; `time`, because it stamps the expiry from the wall clock.
;;;
;;; Usage:
;;;   import Tesl.JWT    exposing [jwt, JwtToken,
;;;                                JWT.sign, JWT.verify, JWT.decode, Authentic]
;;;   import Tesl.Crypto exposing [Secret]
;;;   import Tesl.Env    exposing [envRead, requireSecret]
;;;
;;;   capability myAuth implies jwt, time
;;;
;;;   fn makeSession(userId: String, secret: Secret) requires [myAuth] -> JwtToken =
;;;     JWT.sign (Dict.singleton "sub" userId) secret
;;;
;;; ── EXPIRY IS NOT THE CALLER'S TO SET ────────────────────────────────────────
;;;
;;; `JWT.sign` stamps `exp` itself, one hour ahead, and there is no parameter for
;;; it.  That is deliberate and follows Tesl.Crypto's design rule: no mechanism
;;; reaches the application author, because every knob is a place where a
;;; non-expert makes a wrong call and gets a plausible-looking result.  A caller
;;; who can pass an expiry can pass ten years.
;;;
;;; One hour is the session-token number.  A JWT here IS a session token; for a
;;; long-lived credential (an API key, a machine token) the documented answer is
;;; `Crypto.randomToken` plus storing only its `Crypto.fingerprint`, which is
;;; revocable — an unexpiring bearer token is not.  Renewing a session means
;;; signing a new token, which is one call.
;;;
;;; A caller-supplied `exp` in the claims dict is an ERROR, not something to
;;; overwrite: silently winning an argument with the caller about which expiry
;;; applies is how a token ends up living longer than the code says it does.
;;;
;;; ── UNIT: `exp` IS EPOCH SECONDS (RFC 7519) ──────────────────────────────────
;;;
;;; `exp` is a NumericDate as RFC 7519 §4.1.4 defines it: seconds since the Unix
;;; epoch.  Both the mint side (JWT.sign) and the verify side agree, and both
;;; agree with every other JWT library, so a Tesl token interoperates.
;;;
;;; It was MILLISECONDS until 2026-07-29 — 1000x too large, which a foreign
;;; verifier would have read as valid for ~50,000 years (fail-open), and which
;;; made every foreign token look long expired to Tesl (fail-closed).  The fix is
;;; a clean break with no dual-unit tolerance: a heuristic that guesses the unit
;;; is exactly the kind of hedge that outlives its reason.  Tokens minted before
;;; the break have a far-future `exp` and will still verify until they are
;;; re-signed; tokens minted by a Tesl older than the break, against a newer
;;; verifier, are unaffected for the same reason.
;;;
;;; Note the internal asymmetry this leaves: Tesl's own clock type,
;;; `PosixMillis`, is milliseconds, so the conversion happens HERE (once, at the
;;; JWT boundary) rather than leaking a second time unit into Tesl.Time.
;;;
;;; See LANGUAGE-SPEC.md §21.2.

(require "../dsl/capability.rkt"
         "../dsl/check.rkt"
         "../dsl/types.rkt"
         "private/runtime.rkt"
         (only-in "time.rkt" time)
         ;; `Authentic` is Tesl.Crypto's proof predicate, RE-EXPORTED here rather
         ;; than redefined: JWT.verify mints it, so `import Tesl.JWT exposing
         ;; [Authentic]` has to resolve to a real provide (the stdlib
         ;; binding-existence seam test enforces that).  Re-exporting keeps ONE
         ;; binding, so a program that reaches the name through both modules sees
         ;; the same identifier instead of a require conflict.
         ;;
         ;; `Crypto.keyFingerprint` is used INTERNALLY (the `kid` header stamp)
         ;; and is deliberately NOT re-provided — nor is `Secret`.  Both belong
         ;; to Tesl.Crypto's export list, and duplicating them here would make
         ;; the same name reachable through two module rows, which is exactly the
         ;; drift the stdlib binding-existence seam test exists to prevent.
         (only-in "crypto.rkt" Authentic Crypto.keyFingerprint)
         (only-in "../dsl/private/evidence.rkt" check-fail)
         openssl/libcrypto
         ffi/unsafe
         ffi/unsafe/define
         openssl/sha1          ; for bytes->hex-string
         net/base64
         racket/string
         json)

(provide jwt JwtToken JWT.sign JWT.verify JWT.renew JWT.decode
         ;; SSO server clause: mint a session cookie value (raw JWT) for a
         ;; subject, self-granting jwt+time.  NOT a Tesl-surface name.
         sso-session-cookie-value
         ;; re-exported from crypto.rkt — see the require note above
         Authentic
         ;; internal: `tesl/http.rkt` derives the session cookie's Max-Age from
         ;; this, so the cookie can never outlive the token it carries.  Single
         ;; source, one direction — jwt.rkt does not require http.rkt.  NOT a
         ;; Tesl-importable name (it is absent from Tesl.JWT's export list).
         jwt-ttl-seconds
         ;; internal: the hard stop on a renewed session's total lifetime.
         ;; Exported for the test suite, which asserts the bound rather than
         ;; restating the number.  Also NOT Tesl-importable.
         jwt-absolute-max-seconds
         ;; ── Session-policy / key-rotation / revocation runtime half (Stage 2,
         ;; ensure_sso_works.md).  Exported for the runtime-half test suite and
         ;; the Phase-3 server-clause wiring; NONE is a Tesl-surface name.
         (struct-out session-policy)
         standard-session short-session
         current-session-policy policy-ttl-seconds policy-absolute-max-seconds
         current-previous-session-key
         current-session-revoked-hook)

;; ── Capability ───────────────────────────────────────────────────────────────

(define-capability jwt)

;; ── Nominal newtypes ─────────────────────────────────────────────────────────

;; JwtToken wraps a String — the dot-separated JWT string "header.payload.sig"
(define-newtype JwtToken String)

;; There is NO key newtype here.  The HMAC-SHA256 signing key is `Secret`, from
;; tesl/crypto.rkt (`define-secret-newtype Secret String`), which is the single
;; key-material type in the language and already carries the redaction: every
;; rendering sink (telemetry, the three debugger surfaces, structured logging)
;; substitutes `secret-redaction-text` instead of printing it.

;; ── Argument normalisation: raw-value FIRST, then strip the newtype ──────────
;;
;; A stdlib function does not necessarily receive its argument as the value. The
;; GDP machinery may hand over the SUBJECT NAME (a bare symbol), which
;; `raw-value` resolves through `current-evidence-env`, and the argument may also
;; arrive wrapped in a `named-value` or a `check-ok`.
;;
;; The order matters and used to be wrong here: `(raw-value (if (newtype-value? x)
;; (newtype-value-value x) x))` tests for the wrapper BEFORE resolving, so a
;; named-value wrapping a JwtToken fell through the `if`, `raw-value` unwrapped
;; the named-value, and the result was still a `newtype-value` — which then hit
;; `string-split` as a contract violation. It stayed latent until `JWT.verify`
;; became check-shaped (the `Authentic` retrofit), because that changed how call
;; sites pass the argument. Identical to the bug fixed in `tesl/crypto.rkt`'s
;; `checkPassword`; `tesl/string.rkt`'s `raw-str` is the house idiom.
(define (jwt-raw-string v)
  (define r (raw-value v))
  (if (newtype-value? r) (newtype-value-value r) r))


;; ── HMAC-SHA256 via FFI (OpenSSL libcrypto) ──────────────────────────────────

(define-ffi-definer define-libcrypto libcrypto)

;; EVP_sha256() returns a pointer to the SHA256 message digest algorithm.
(define-libcrypto EVP_sha256
  (_fun -> _pointer))

;; HMAC(evp_md, key, key_len, data, data_len, md_out, md_len_out) -> _bytes
;; Returns a pointer to the HMAC output (same as md_out).
;; For SHA256 the output is always 32 bytes.
(define-libcrypto HMAC
  (_fun _pointer        ; const EVP_MD *evp_md
        _bytes          ; const void *key
        _int            ; int key_len
        _bytes          ; const unsigned char *data
        _int            ; int data_len
        _bytes          ; unsigned char *md  (must be pre-allocated, >= 32 bytes)
        (_ptr o _uint)  ; unsigned int *md_len  (written by HMAC; we ignore return)
        -> _pointer))

(define (hmac-sha256-bytes key-bytes data-bytes)
  (define sha256-md (EVP_sha256))
  (define out (make-bytes 32))
  (HMAC sha256-md key-bytes (bytes-length key-bytes)
        data-bytes (bytes-length data-bytes)
        out)
  out)

;; ── Base64url helpers (RFC 4648 §5 — no padding) ────────────────────────────

(define (base64url-encode bstr)
  ;; Standard base64 with padding, then transform to base64url without padding
  (define b64 (bytes->string/utf-8 (base64-encode bstr #"")))
  (define url (string-replace (string-replace b64 "+" "-") "/" "_"))
  ;; Strip all trailing '=' padding characters
  (regexp-replace* #rx"=+$" url ""))

(define (base64url-decode str)
  ;; Restore standard base64 padding and characters, then decode
  (define s (string-replace (string-replace str "-" "+") "_" "/"))
  ;; Add padding back
  (define padded
    (case (remainder (string-length s) 4)
      [(0) s]
      [(2) (string-append s "==")]
      [(3) (string-append s "=")]
      [else s]))
  (base64-decode (string->bytes/utf-8 padded)))

;; ── Internal JWT helpers ─────────────────────────────────────────────────────

;; Build the JOSE header for a given signing key, encoded as base64url:
;;
;;   {"alg":"HS256","typ":"JWT","kid":"<Crypto.keyFingerprint key>"}
;;
;; ── WHY `kid` IS STAMPED FROM DAY ONE ────────────────────────────────────────
;;
;; `kid` is the RFC 7515 §4.1.4 home for a key identifier, and it is DERIVED, not
;; chosen: `Crypto.keyFingerprint` is a domain-separated SHA-256 truncated to 16
;; hex characters, so it is safe to log, is not proof of key possession, and needs
;; no parameter — there is no knob here either.  It answers "which key verified
;; this / which key is this replica loaded with", which is the question a
;; multi-replica or multi-tenant deployment asks from its logs, and it makes key
;; rotation expressible later without a flag day.  Stamping is the part that is
;; expensive to retrofit; there is deliberately no accessor in v1.
;;
;; WHAT `kid` PUBLISHES, STATED EXPLICITLY.  It is a 64-bit function OF THE
;; SIGNING KEY, printed in every token, so "safe to log" is a trade and not a
;; free property.  Two consequences, both accepted:
;;
;;   * an OFFLINE KEY-GUESS ORACLE that needs no signed payload.  Confirming a
;;     candidate key costs ONE SHA-256 (cheaper than HMAC's two compressions),
;;     against 64 bits of target.  It does not weaken a key with real entropy —
;;     `Crypto.randomToken` gives 256 bits — but a GUESSABLE `SESSION_KEY`
;;     ("dev", "changeme", a short passphrase) is now cheaper to confirm than it
;;     was.  The mitigation is the one that already applied: the signing key is
;;     `Secret`, generated, never typed by hand.
;;   * KEY-SHARING LINKABILITY.  Two deployments emitting the same `kid`
;;     demonstrably share a signing key, to anyone holding one token from each.
;;     That is the same fact the identifier exists to make legible in one's own
;;     logs; it is simply legible to an outside observer too.
;;
;; Both are marginal against the operational answer `kid` gives ("which key is
;; this replica loaded with"), which is why the stamp stays — but neither is
;; discovered from the words "safe to log", so they are written down here.
;;
;; SAFE TODAY, IN BOTH DIRECTIONS.  `JWT.verify` never parses the header — it
;; recomputes the HMAC over `header.payload` VERBATIM — so a token minted before
;; this change (no `kid`), and a foreign token with any header at all, verify
;; exactly as before.  A `kid` mismatch is therefore not an error condition
;; anywhere in this module.
;;
;; The header is assembled by string append rather than through `jsexpr->string`
;; so the FIELD ORDER is fixed (alg, typ, kid) and stays stable across Racket
;; hash-iteration order; the fingerprint is 16 hex characters, so no JSON string
;; escaping can be needed.
(define (jwt-header-b64 key)
  (base64url-encode
   (string->bytes/utf-8
    (string-append "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\""
                   (Crypto.keyFingerprint key)
                   "\"}"))))

;; Normalize an arbitrary Tesl claims value into a SYMBOL-KEYED jsexpr hash —
;; the shape `jsexpr->string` wants, and the shape the `exp` guard below
;; inspects.  Note what is deliberately NOT done here: a newtype-value claim is
;; left wrapped, so `jsexpr->string` raises on it.  Unwrapping would be more
;; forgiving but would silently serialize a `Secret` (or any other
;; `define-secret-newtype`) into the payload in plaintext if one were ever
;; misplaced into the claims dict.  Fail loud instead.
(define (claims->jsexpr-hash who claims)
  (define raw (raw-value claims))
  (define h
    (cond
      [(hash? raw) raw]
      ;; Support association lists (Tesl dict internally may be an alist)
      [(list? raw)
       (for/hash ([pair (in-list raw)])
         (values (car pair) (raw-value (cdr pair))))]
      [else
       (raise-user-error who "JWT claims must be a hash/dict, got ~a" raw)]))
  ;; JSON object keys must be SYMBOLS for `jsexpr->string`, but Tesl Dict keys
  ;; are STRINGS — coerce them.  Unwrap any GDP-named values.
  (for/hash ([(k v) (in-hash h)])
    (values (if (string? k) (string->symbol k) k) (raw-value v))))

;; ── Expiry ───────────────────────────────────────────────────────────────────

;; The fixed session TTL, in SECONDS.  One hour.  Not a parameter, not
;; configurable, and not read from the environment — see the header note: every
;; knob here is a place where a non-expert makes a wrong call and gets a
;; plausible-looking result.  Renewing a session is one more `JWT.sign`.
(define jwt-ttl-seconds 3600)

;; ── The ABSOLUTE session lifetime (sliding renewal's hard stop) ──────────────
;;
;; `JWT.renew` slides the one-hour window forward while a session is in use, so
;; an active user is not logged out mid-task.  That reintroduces a risk the fixed
;; TTL had closed: a token captured off the wire can be presented to `JWT.renew`
;; just like a legitimate one, so WITHOUT a hard stop a stolen token would be
;; renewable forever.  Since Tesl deliberately has no server-side revocation
;; (see the header and LANGUAGE-SPEC §21.8), the bound has to come from the token
;; itself.
;;
;; So every token carries `iat` (issued-at, RFC 7519 §4.1.6), renewal PRESERVES
;; it, and renewal refuses once `now - iat` exceeds this constant.  The guarantee
;; that survives is the one the no-revocation decision rests on: **a captured
;; token is useful for at most this long after the ORIGINAL login**, no matter how
;; often it is renewed.
;;
;; Twelve renewals — expressed as a multiple of the TTL so the relationship is
;; visible rather than a second unrelated magic number.  Twelve hours covers any
;; single working day, which is the longest a browser session has a legitimate
;; reason to live; a credential that must outlive that is not a session, and the
;; documented answer for one is `Crypto.randomToken` plus a stored
;; `Crypto.fingerprint`, which is revocable.  Not a parameter, for the same
;; reason `exp` is not: a caller who can choose it will choose "never".
(define jwt-absolute-max-seconds (* 12 jwt-ttl-seconds))

;; ── Session policy (runtime half — roadmap/next/ensure_sso_works.md, Stage 2) ──
;;
;; The renewable TTL and the absolute cap are no longer two hardcoded constants:
;; they come from the ACTIVE `SessionPolicy`, a closed set of safe values (not a
;; free `Duration` a caller could set to 30 days).  The default is
;; `StandardSession` — 1h renewable / 12h absolute, today's EXACT behaviour, so
;; nothing changes for an existing program.  The absolute cap is named PER POLICY
;; rather than derived as `(* 12 ttl)`: applying the old multiplier to a 15-minute
;; TTL would silently yield a 3-hour cap (forced mid-workday reauth), which is a
;; bug, so `ShortSession` pairs 15min renewable with an 8h (workday) cap
;; deliberately.  Server-wide, not SSO-specific.  The active policy is read at
;; VERIFY/RENEW time, so lowering it shortens live sessions immediately (usable as
;; incident response); raising it never extends a session past its own iat+cap.
(struct session-policy (name ttl-seconds absolute-max-seconds) #:transparent)
(define standard-session
  (session-policy 'StandardSession jwt-ttl-seconds jwt-absolute-max-seconds)) ; 1h / 12h
(define short-session
  (session-policy 'ShortSession 900 (* 8 3600)))                              ; 15min / 8h
(define current-session-policy (make-parameter standard-session))
(define (policy-ttl-seconds) (session-policy-ttl-seconds (current-session-policy)))
(define (policy-absolute-max-seconds)
  (session-policy-absolute-max-seconds (current-session-policy)))

;; ── Session-key rotation (runtime half) ───────────────────────────────────────
;;
;; The optional PREVIOUS signing key.  `JWT.verify` accepts a token signed by
;; either the current key (its `secret` argument) or this one; `JWT.sign` /
;; renewal always use the current key, so the previous slot drains on its own
;; after one absolute cap.  This is the rotation overlap that lets a leaked
;; `SESSION_KEY` be rotated WITHOUT logging every user out, and emptying this slot
;; while rotating the current key is the global kill switch.  Default `#f` — no
;; previous key — so existing programs are unchanged.  A `Secret` or `#f`.
(define current-previous-session-key (make-parameter #f))

;; ── Revocation at the renewal boundary (runtime half) ─────────────────────────
;;
;; An OPTIONAL fail-closed check consulted ONLY when a session RENEWS — never on
;; the verify path, which stays byte-identical stateless.  It bounds revocation
;; latency to the renewable window (<=1h Standard, <=15min Short) at the cost of
;; one read per session per TTL.  The hook is `(subject iat-seconds) -> Bool`
;; (#t ⇒ revoked); a raising hook also denies (fail closed).  Default `#f` ⇒
;; today's behaviour.  (The Phase-3 server clause adapts the app's
;; `(String, PosixMillis) -> Bool` to this; iat is seconds at this layer.)
(define current-session-revoked-hook (make-parameter #f))
(define (session-revoked? subject iat)
  (define hook (current-session-revoked-hook))
  (and hook
       ;; Any error from the hook (a failing dbRead, a raise) denies the renewal.
       (with-handlers ([(lambda (_) #t) (lambda (_) #t)])
         (and (hook (or subject "") iat) #t))))

;; NOW in epoch SECONDS (RFC 7519 NumericDate).  Tesl's own clock type is
;; PosixMillis, so the ms→s conversion lives here, at the JWT boundary, once.
(define (jwt-now-seconds)
  (inexact->exact (floor (/ (current-inexact-milliseconds) 1000.0))))

;; The only tolerance granted to an `iat` that is AHEAD of this machine's clock.
;; One minute — enough for ordinary NTP drift between two replicas, small enough
;; that it cannot meaningfully extend a session (see `usable-iat?`).
(define jwt-max-clock-skew-seconds 60)

;; Is a decoded `iat` usable as the anchor of the absolute-lifetime cap?
;;
;; Strict on BOTH sides, and both sides are load-bearing:
;;
;;   * EXACT NON-NEGATIVE INTEGER, not `real?`.  `iat` is a NumericDate; a float
;;     is out of shape, and `1e300` (or `+inf.0`) makes `now - iat` hugely
;;     NEGATIVE, so the cap check passes forever and the value is PRESERVED
;;     across every renewal — an immortal session from one malformed claim.
;;     Rejecting the shape is cheaper than reasoning about which floats are safe.
;;   * NOT IN THE FUTURE beyond a minute of skew.  A future `iat` widens the cap
;;     by exactly its distance ahead (`now - iat` is smaller than the session's
;;     true age), so a fast-clocked replica — or a foreign minter sharing the
;;     HS256 secret — silently buys the token extra lifetime past the 12h stop.
;;
;; Neither is attacker-reachable while Tesl mints every token: `JWT.sign` stamps
;; `iat` from the clock and `reject-caller-supplied-iat!` is total.  Both become
;; reachable the moment a Tesl verifier shares a signing key with a foreign
;; minter, which is the point of the SSO work — hence the guard lands first.
(define (usable-iat? iat now)
  (and (exact-nonnegative-integer? iat)
       (<= iat (+ now jwt-max-clock-skew-seconds))))

;; MINT-SIDE GUARD.  `exp` is set by `JWT.sign` from the clock, so a caller
;; supplying one is rejected outright rather than silently overwritten:
;; overwriting would mean the code says one expiry and the token carries another,
;; and accepting it would hand the caller the knob the design deliberately
;; withholds.
;;
;; This RAISES rather than returning a check-fail.  A check-fail is the shape for
;; ATTACKER-supplied input (a token off the wire); the claims dict is the
;; program's OWN data on the way out, so it is a program bug, and the only place
;; it can be diagnosed at the right site is here — the dict may be assembled
;; dynamically, so no type catches every case.
(define (reject-caller-supplied-exp! who h)
  (when (hash-has-key? h 'exp)
    (raise-user-error
     who
     (string-append
      "expiry is not yours to set: the claims dict carries an `exp` (~s).\n"
      "  JWT.sign stamps `exp` itself, ~a seconds ahead, and there is no\n"
      "  parameter for it — a caller who can choose an expiry can choose ten\n"
      "  years.  Remove `exp` from the claims.\n"
      "  If you need a credential that outlives a session, a JWT is the wrong\n"
      "  tool: use `Crypto.randomToken` and store only its `Crypto.fingerprint`,\n"
      "  which you can revoke.")
     (hash-ref h 'exp)
     jwt-ttl-seconds)))

;; Same guard for `iat`, and it matters more than it looks.  `iat` is what bounds
;; the absolute session lifetime across renewals, so a caller who could set it
;; could set it to "now" on every renewal and defeat the hard stop entirely —
;; turning a sliding session back into an unbounded one.  It is stamped by
;; `JWT.sign` and PRESERVED by `JWT.renew`; nothing else may write it.
(define (reject-caller-supplied-iat! who h)
  (when (hash-has-key? h 'iat)
    (raise-user-error
     who
     (string-append
      "issued-at is not yours to set: the claims dict carries an `iat` (~s).\n"
      "  JWT.sign stamps `iat` itself from the clock, and JWT.renew preserves it\n"
      "  unchanged — it is what caps the total lifetime of a renewed session at\n"
      "  ~a seconds from the original login.  A caller who could set it could\n"
      "  reset it on every renewal and make the session immortal.\n"
      "  Remove `iat` from the claims.")
     (hash-ref h 'iat)
     jwt-absolute-max-seconds)))

(define (jsexpr-hash->json-bytes h)
  (string->bytes/utf-8 (jsexpr->string h)))

(define (compute-signature secret-bytes signing-input)
  (hmac-sha256-bytes secret-bytes (string->bytes/utf-8 signing-input)))

;; `string->jsexpr` decodes JSON object keys as SYMBOLS, but the Tesl Dict API
;; (Dict.lookup, Dict.member, …) keys by STRING. Re-key the decoded claims so a
;; verified/decoded payload behaves as a `Dict String v` on the Tesl surface.
(define (jwt-claims->string-keyed claims)
  (if (hash? claims)
      (for/hash ([(k v) (in-hash claims)])
        (values (if (symbol? k) (symbol->string k) k) v))
      claims))

;; Phase 0 (roadmap/next/ensure_sso_works.md, blocker 6): JWT.decode is typed
;; `Dict String String`, but a JWT payload is arbitrary JSON.  `aud`, `amr`,
;; `roles` and `groups` are frequently ARRAYS and `exp`/`iat`/`nbf` are NUMBERS,
;; so `string->jsexpr` returns Racket lists/numbers/booleans and the runtime
;; would hand the Tesl surface a value that is not a String -- the declared type
;; a lie, and (for an array) exactly the substring-matchable shape Risk 18 warns
;; about.  Rather than widen JWT.decode's type here, pin a DETERMINISTIC rule so
;; the type is honest: every claim value is rendered to its string form --
;;   * a JSON string   -> itself
;;   * a number/bool    -> its JSON text ("123", "true")
;;   * null             -> "null"
;;   * an array/object  -> its COMPACT JSON text (`["a","b"]`, `{"k":1}`)
;;
;; NOTE for authorization: a decoded array claim is JSON TEXT, which IS
;; substring-matchable -- do NOT branch on `String.contains` over it.  The typed,
;; per-claim `Dict String Json` that authorization should read is the SSO path's
;; `SsoIdentity.claims` (§Typed identity), not this general-purpose decoder.
;;
;; This coercion is applied ONLY at the JWT.decode surface boundary.  The
;; verify/renew path keeps raw jsexpr values on purpose: JWT.renew does integer
;; arithmetic on a numeric `iat` (`usable-iat?`, `iat + max`), which a stringified
;; claim would break.
(define (jwt-claim-value->string v)
  (cond
    [(string? v) v]
    [(boolean? v) (if v "true" "false")]
    [(eq? v 'null) "null"]
    [(number? v) (number->string v)]
    [else
     ;; array / object / anything else that came from string->jsexpr.
     (with-handlers ([exn:fail? (lambda (_) (format "~a" v))])
       (jsexpr->string v))]))

;; Render a decoded, string-keyed claims hash as an honest `Dict String String`.
(define (jwt-claims->tesl-dict claims)
  (unless (hash? claims)
    (raise-user-error 'JWT.decode
                      "malformed JWT payload: the claims must be a JSON object"))
  (for/hash ([(k v) (in-hash claims)])
    (values k (jwt-claim-value->string v))))

;; ── Public API ───────────────────────────────────────────────────────────────

;; Serialize an already-normalized, already-guarded jsexpr claims hash and HMAC it.
(define (sign-claims-hash h secret)
  (define secret-str (jwt-raw-string secret))
  (define secret-bytes (string->bytes/utf-8 secret-str))
  (define payload-b64
    (base64url-encode (jsexpr-hash->json-bytes h)))
  (define signing-input
    (string-append (jwt-header-b64 secret-str) "." payload-b64))
  (define sig-bytes
    (compute-signature secret-bytes signing-input))
  (define sig-b64 (base64url-encode sig-bytes))
  (JwtToken (string-append signing-input "." sig-b64)))

;; JWT.sign : Dict String String → Secret → JwtToken
;;
;; Creates a signed session JWT from a string-keyed, string-valued claims dict,
;; and stamps `exp` one hour ahead (epoch SECONDS, RFC 7519).  There is no way to
;; choose the expiry, and no way to opt out of having one — see the header.
;;
;; Requires `time` as well as `jwt`: it reads the wall clock, and a capability
;; marks an effect.
;;
;; Example:
;;   JWT.sign (Dict.singleton "sub" userId) secret
(define (JWT.sign claims secret)
  (require-capabilities! (list jwt time))
  (define h (claims->jsexpr-hash 'JWT.sign claims))
  (reject-caller-supplied-exp! 'JWT.sign h)
  (reject-caller-supplied-iat! 'JWT.sign h)
  (define now (jwt-now-seconds))
  ;; `iat` as well as `exp`: this is the ORIGINAL login time, and it is what
  ;; `JWT.renew` reads to cap the total lifetime of a renewed session.  Both are
  ;; epoch SECONDS (RFC 7519).
  (sign-claims-hash
   (hash-set (hash-set h 'iat now) 'exp (+ now (policy-ttl-seconds)))
   secret))

;; JWT.verify : JwtToken → Secret → Dict String String
;;
;; Verifies the JWT signature and checks expiry (`exp` claim, in epoch SECONDS
;; per RFC 7519 §4.1.4 — see the unit note in the module header).
;; Returns the claims hash on success, or a check-fail with HTTP 401.
;;
;; On success the claims carry an `Authentic` fact (Crypto Phase 2), so a
;; consumer can demand `Dict String String ::: Authentic claims` on a parameter
;; and "trusted a cookie without verifying it" stops compiling.
;;
;; Example:
;;   JWT.verify token secret
(define (JWT.verify token secret)
  (require-capabilities! (list jwt))
  (define token-str (jwt-raw-string token))
  (define secret-str (jwt-raw-string secret))
  (define parts (string-split token-str "."))
  ;; A STRUCTURALLY malformed token is a 401, not a raise.  The token comes off
  ;; the wire, so `Cookie: session=garbage` used to escape as an uncaught
  ;; `raise-user-error` — a client-triggerable 500 on every JWT-authenticated
  ;; endpoint, and an oracle that distinguishes "not a token" from "wrong
  ;; signature".  Every other rejection here is already `check-fail … 401`; this
  ;; one now agrees with them, and with `Crypto.signatureFromHex`, which parses
  ;; an inbound tag without ever raising, for the same reason.
  (if (not (= (length parts) 3))
      (check-fail "Invalid JWT format" 401 '())
      (let* ([header-b64  (list-ref parts 0)]
             [payload-b64 (list-ref parts 1)]
             [sig-b64     (list-ref parts 2)]
             ;; Re-derive signature
             [signing-input (string-append header-b64 "." payload-b64)]
             ;; A signature segment that is not valid base64url falls through to
             ;; the constant-time compare with an empty tag (which fails) rather
             ;; than raising out of the handler.
             [actual-sig
              (with-handlers ([exn:fail? (lambda (_) #"")])
                (base64url-decode sig-b64))]
             ;; Session-key rotation: accept the CURRENT key (this `secret`) or the
             ;; OPTIONAL previous key, so a rotation does not invalidate in-flight
             ;; sessions.  Each candidate gets its own constant-time comparison
             ;; (byte-by-byte, all bytes processed); the count of keys (1 or 2) is
             ;; not secret.  `kid` stays advisory.
             [candidate-secrets
              (filter values
                      (list secret-str
                            (let ([prev (current-previous-session-key)])
                              (and prev (jwt-raw-string prev)))))]
             [sig-ok?
              (for/or ([cand (in-list candidate-secrets)])
                (define expected
                  (compute-signature (string->bytes/utf-8 cand) signing-input))
                (and (= (bytes-length expected) (bytes-length actual-sig))
                     (= 0 (for/fold ([acc 0]) ([eb (in-bytes expected)]
                                               [ab (in-bytes actual-sig)])
                            (bitwise-ior acc (bitwise-xor eb ab))))))])
        (if (not sig-ok?)
            (check-fail "Invalid JWT signature" 401 '())
            ;; Decode payload
            (let* ([payload-bytes
                    (with-handlers ([exn:fail? (lambda (_) #"")])
                      (base64url-decode payload-b64))]
                   [claims
                    (with-handlers ([exn:fail? (lambda (_) #f)])
                      (string->jsexpr (bytes->string/utf-8 payload-bytes)))])
              (if (not claims)
                  (check-fail "Malformed JWT payload" 401 '())
                  ;; Check expiry.  `exp` is epoch SECONDS (RFC 7519 §4.1.4), the
                  ;; same unit every other JWT library uses and the same unit
                  ;; JWT.sign writes.
                  ;;
                  ;; A MISSING `exp` is accepted (no expiry claim, no expiry
                  ;; check).  Tesl cannot mint such a token — JWT.sign always
                  ;; stamps one — so this only admits a foreign token that omits
                  ;; `exp`, which is legal per the RFC (`exp` is OPTIONAL).
                  ;;
                  ;; A NON-NUMERIC `exp` is treated as EXPIRED, not as absent.
                  ;; Two reasons, and the second is the important one:
                  ;;   * `(< "1785355686959" now)` is a contract violation, which
                  ;;     escapes as an uncaught exception and becomes a 500 —
                  ;;     while every other rejection on this path is a 401.  A
                  ;;     well-formed token with a string `exp` is enough to
                  ;;     trigger it.
                  ;;   * skipping the check on an unparseable `exp` would be
                  ;;     FAIL-OPEN: a token whose expiry cannot be read would be
                  ;;     accepted forever.  Unreadable expiry must mean expired.
                  ;; Tesl can no longer mint one either — JWT.sign sets `exp`
                  ;; itself from the clock — so this branch now fires only on a
                  ;; foreign or hand-forged token.
                  (let* ([exp (and (hash? claims) (hash-ref claims 'exp #f))]
                         [now (jwt-now-seconds)]
                         [expired?
                          (cond
                            [(eq? exp #f) #f]           ; no exp claim: no expiry
                            [(real? exp) (< exp now)]
                            [else #t])])                ; unreadable: fail closed
                    (if expired?
                        (check-fail "JWT token has expired" 401 '())
                        (jwt-claims->string-keyed claims)))))))))

;; JWT.renew : JwtToken → Secret → JwtToken          (check-shaped)
;;
;; Slides the session window forward: verifies the token, then re-issues it with
;; a fresh one-hour `exp` and the ORIGINAL `iat` preserved.  Pair it with
;; `Http.setSessionCookie` and an active user is never logged out mid-task, while
;; an idle one still expires an hour after their last request.
;;
;;   let claims = check JWT.verify token key
;;   let _ = Http.setSessionCookie (check JWT.renew token key)
;;
;; WHY THIS EXISTS AS A FUNCTION.  Re-signing by hand is not merely tedious, it is
;; a trap: `JWT.verify`'s claims contain `exp` and `iat`, and `JWT.sign` REJECTS
;; both, so the author has to strip them — and an author who rebuilds the dict by
;; hand to do that silently drops any claim they forget (a `role`, a tenant id),
;; downgrading the session on every renewal.  One function that carries every
;; claim across is the only safe shape.
;;
;; WHY IT REFUSES.  Renewal is presented WITH the token, so an attacker holding a
;; captured token can renew it exactly as the legitimate holder can.  The hard
;; stop is therefore not a policy knob but the thing that preserves the property
;; the whole design rests on — that a captured token is useful for a bounded time
;; even though nothing can revoke it.  Three refusals, all 401 and all through the
;; same constant-time path as `JWT.verify`:
;;
;;   * the token does not verify, or has already expired — `JWT.verify`'s own
;;     rejection, returned unchanged;
;;   * the token carries no USABLE `iat` (absent, not an exact non-negative
;;     integer, or dated in the future beyond a minute of clock skew — see
;;     `usable-iat?`), so its total age cannot be bounded.  FAIL CLOSED: an
;;     unbounded-age token must not be renewable.  This also covers foreign
;;     tokens (`iat` is OPTIONAL per the RFC) and tokens Tesl minted before `iat`
;;     was stamped — those simply run out at their own `exp`, within the hour, so
;;     the case self-heals;
;;   * `now - iat` exceeds `jwt-absolute-max-seconds` — the session has lived its
;;     maximum and the user must authenticate again.
;;
;; Charges `time` as well as `jwt`: it reads the clock twice over (the age check
;; and the new expiry), and a capability marks an effect.
(define (JWT.renew token secret)
  (require-capabilities! (list jwt time))
  ;; Reuse JWT.verify WHOLE rather than re-deriving the checks: the signature
  ;; comparison, the malformed-token 401s and the expiry rule then cannot drift
  ;; between verifying and renewing.  It returns either a check-fail (propagated
  ;; verbatim) or the STRING-keyed claims.
  (define verified (JWT.verify token secret))
  (cond
    [(check-fail? verified) verified]
    [(not (hash? verified))
     ;; Defensive: JWT.verify's contract is check-fail-or-hash.  If that ever
     ;; changes, refuse rather than sign something unexamined.
     (check-fail "Session cannot be renewed" 401 '())]
    [else
     (define iat (hash-ref verified "iat" #f))
     (define now (jwt-now-seconds))
     (cond
       [(not (usable-iat? iat now))
        ;; ONE message for every unusable `iat` — absent, wrong shape, or ahead
        ;; of this clock.  Distinguishing them would tell a token holder how the
        ;; claim was rejected without telling the legitimate user anything they
        ;; can act on: in every case the answer is "log in again".
        (check-fail "Session cannot be renewed: no usable issued-at claim" 401 '())]
       [(> (- now iat) (policy-absolute-max-seconds))
        (check-fail "Session has reached its maximum lifetime" 401 '())]
       [(session-revoked? (hash-ref verified "sub" #f) iat)
        ;; Revocation at the renewal boundary: fail-closed, verify path untouched.
        ;; For an SSO user a denial is one silent redirect that re-applies the
        ;; IdP's own policy; the app owns the store, Tesl owns no session state.
        (check-fail "Session cannot be renewed: session revoked" 401 '())]
       [else
        ;; Carry EVERY claim across, replacing only `exp` and keeping `iat` as it
        ;; was.  Re-key to symbols, which is what the signing path serializes.
        (define renewed
          (for/hash ([(k v) (in-hash verified)]
                     #:unless (equal? k "exp"))
            (values (if (string? k) (string->symbol k) k) v)))
        ;; CLAMP the new expiry to the absolute deadline (`iat + max`), do not
        ;; grant a full fresh TTL unconditionally.  Without the `min`, a token
        ;; renewed just under the cap gets a whole extra hour of `exp` past the
        ;; deadline — the effective ceiling becomes `max + ttl` (13h), not `max`
        ;; (12h), contradicting the invariant this cap exists to hold ("useful
        ;; for at most `max` after the ORIGINAL login").  Near the cap the
        ;; renewed window therefore shrinks to zero rather than overshooting; a
        ;; fresh token (iat ≈ now) is unaffected, since `iat + max` is far past
        ;; `now + ttl`.
        (define deadline (+ iat (policy-absolute-max-seconds)))
        (sign-claims-hash
         (hash-set renewed 'exp (min (+ now (policy-ttl-seconds)) deadline))
         secret)])]))

;; JWT.decode : JwtToken → Dict String String
;;
;; Decodes the JWT payload WITHOUT verifying the signature.
;; Use this only when you have already verified the token or trust the source.
;;
;; Example:
;;   JWT.decode token
(define (JWT.decode token)
  (require-capabilities! (list jwt))
  (define token-str (jwt-raw-string token))
  (define parts (string-split token-str "."))
  (when (< (length parts) 2)
    (raise-user-error 'JWT.decode
                      "invalid JWT format: expected at least 2 dot-separated parts"))
  (define payload-b64 (list-ref parts 1))
  (define payload-bytes (base64url-decode payload-b64))
  (with-handlers ([exn:fail? (lambda (_)
                               (raise-user-error 'JWT.decode "malformed JWT payload"))])
    (jwt-claims->tesl-dict
     (jwt-claims->string-keyed
      (string->jsexpr (bytes->string/utf-8 payload-bytes))))))

;;; ── SSO session minting (Phase 3, roadmap/next/ensure_sso_works.md) ───────────
;; The `sso` server clause's callback exchanges the provider identity for one of
;; THESE — Tesl's own session JWT — exactly like every other login.  Self-grants
;; jwt+time so the runtime-owned callback (dsl/web.rkt) need not thread caps.
(define (sso-session-cookie-value secret subject)
  (with-capabilities (jwt time)
    (jwt-raw-string (JWT.sign (hash "sub" subject) secret))))
