#lang racket/base

;;; Tesl SSO runtime — OIDC + plain-OAuth2 (roadmap/next/ensure_sso_works.md,
;;; Phases 1 & 2).  All SSO logic is confined here and to runtime-owned endpoints;
;;; the third-party identity is exchanged ONCE, at the callback, for Tesl's own
;;; `__Host-session` cookie, so every existing session/proof surface is untouched.
;;;
;;; This module is split into a PURE layer (deterministic security helpers,
;;; exhaustively unit-testable with no network) and an ORCHESTRATION layer that
;;; drives HttpClient (stubbable via current-outbound-http-hook).  The pure layer
;;; is where the account-takeover-class bugs live, so it is the most heavily
;;; tested.

(require racket/string
         racket/list
         json
         (only-in file/sha1 bytes->hex-string)
         (only-in net/url string->url url-scheme url-host)
         (only-in net/uri-codec uri-encode)
         (only-in "../tesl/crypto.rkt"
                  sha256-bytes hmac-sha256-bytes base64url-encode
                  crypto-constant-time-equal?)
         (only-in "private/ssrf-guard.rkt" ip-forbidden-reason ip-address-forbidden?)
         (only-in net/base64 base64-encode)
         (only-in "../tesl/http-client.rkt" httpClient HttpClient.get HttpClient.post)
         (only-in "../tesl/tuple.rkt" Tuple2)
         (only-in "../dsl/types.rkt" record-value-fields newtype-value? newtype-value-value)
         (only-in "private/jws-verify.rkt" verify-jws))

(provide ;; PKCE
         pkce-challenge
         ;; identity key + email/domain rules
         sso-subject-key
         email-claim
         normalize-domain email-domain
         email-domain-allowed? hosted-domain-allowed?
         ;; OIDC claim validation
         validate-oidc-claims
         ;; authorize URL
         reserved-authorize-params
         extra-params-reserved-violation
         build-authorize-url
         ;; __Host-oauth cookie
         oauth-cookie-seal oauth-cookie-open
         ;; provider defaults + issuer synthesis
         sso-defaults sso-oidc synthesize-issuer
         ;; single-use state
         make-spent-state-set state-spend!
         ;; SSRF preflight
         url-ssrf-violation
         ;; JWKS cache + rotation refetch (Risk 27) — reset + accessor for tests
         jwks-cache-reset! jwks-for
         ;; orchestration (Layer 2)
         sso-begin-login sso-handle-callback
         ;; positional wrappers so dsl/web.rkt can dynamic-require them without
         ;; keyword-apply (and without a compile-time require cycle through
         ;; http-client -> traces -> web).
         sso-begin-login* sso-handle-callback*)

;;; ── PKCE (RFC 7636), S256 only ────────────────────────────────────────────────
;; challenge = BASE64URL(SHA256(ASCII(verifier))).  `plain` is never produced,
;; and a provider that does not advertise S256 is refused upstream (orchestration).
(define (pkce-challenge verifier)
  (base64url-encode (sha256-bytes (string->bytes/utf-8 verifier))))

;;; ── SsoSubjectKey: injective derivation of (issuer, subject) ──────────────────
;; Naive concatenation lets ("https://a", "x|https://b") collide with
;; ("https://a|x", "https://b").  Length-prefix each component (8-byte big-endian
;; length) before hashing, so the encoding is injective and a cross-issuer
;; collision is impossible.  The result is opaque hex — no email inside it, so a
;; schema cannot key a user on an email address.
(define (sso-subject-key issuer subject)
  (define (lp s)
    (define b (string->bytes/utf-8 s))
    (bytes-append (integer->integer-bytes (bytes-length b) 8 #f #t) b))
  (bytes->hex-string (sha256-bytes (bytes-append (lp issuer) (lp subject)))))

;;; ── EmailClaim: verified-ness is a constructor, not a sibling boolean ─────────
;; Returns 'verified / 'unverified / 'none.  `VerifiedEmail` is reachable ONLY
;; with a POSITIVE verification signal (a real boolean #t) AND a non-empty
;; address — so Entra (which emits no email_verified) can never yield 'verified,
;; which is the nOAuth containment expressed as a rule rather than a comment.
(define (email-claim email verified-signal)
  (cond
    [(or (not (string? email)) (string=? (string-trim email) "")) (values 'none #f)]
    [(eq? verified-signal #t) (values 'verified (string-trim email))]
    [else (values 'unverified (string-trim email))]))

;;; ── Domain restriction (runtime-enforced, VerifiedEmail-only) ─────────────────
;; Case-insensitive over trimmed domains, with the FQDN root canonicalised
;; (`example.com.` ≡ `example.com`) so a trailing-dot form cannot slip past an
;; allow-list written without one.  Both the incoming domain AND every
;; allow-list entry pass through this, so a homoglyph label (e.g. a Cyrillic
;; `а`) is correctly a DIFFERENT domain and is refused fail-closed.  (Full
;; IDNA/punycode A-label ↔ U-label folding is a documented gap — a Unicode
;; label and its punycode form are not yet unified; the security direction is
;; safe, only a legitimate IDN in the other form would be a false negative.)
(define (normalize-domain d)
  (and (string? d)
       (regexp-replace #rx"[.]+$" (string-downcase (string-trim d)) "")))

(define (email-domain email)
  (define m (regexp-match #rx"@([^@]+)$" (or email "")))
  (and m (normalize-domain (cadr m))))

;; Empty allow-list ⇒ no restriction.  Non-empty ⇒ the identity's email must be
;; VERIFIED and its domain a member; 'unverified / 'none are refused (restricting
;; by an address the provider never verified is Risk 2's takeover in disguise).
(define (email-domain-allowed? tag email allowed)
  (cond
    [(null? allowed) #t]
    [(not (eq? tag 'verified)) #f]
    [else (and (member (email-domain email) (map normalize-domain allowed)) #t)]))

;; Empty ⇒ no restriction.  Non-empty ⇒ the `hd` claim must be PRESENT and a
;; member; an absent claim is a refusal, not a pass.
(define (hosted-domain-allowed? hd allowed)
  (cond
    [(null? allowed) #t]
    [(not (and hd (string? hd) (not (string=? (string-trim hd) "")))) #f]
    [else (and (member (normalize-domain hd) (map normalize-domain allowed)) #t)]))

;;; ── OIDC claim validation (fail-closed) ───────────────────────────────────────
;; `claims` is a symbol-keyed jsexpr hash (as `string->jsexpr` returns).  Returns
;; #t on success, or a short reason string on failure.  Signature verification is
;; a SEPARATE step (Phase 2.5) — this is "what login does this token belong to",
;; not "who wrote it".
(define (claim claims k) (hash-ref claims k #f))

(define (aud-contains? aud client-id)
  (cond [(string? aud) (string=? aud client-id)]
        [(list? aud) (and (member client-id aud) #t)]
        [else #f]))

(define (issuer-template? iss) (regexp-match? #rx"[{]tenantid[}]" iss))

(define (validate-oidc-claims claims
                              #:issuer configured-issuer
                              #:client-id client-id
                              #:nonce expected-nonce
                              #:now now
                              #:leeway [leeway 60]
                              #:flow-start [flow-start #f]
                              #:allowed-tenants [allowed-tenants '()])
  (define iss (claim claims 'iss))
  (define aud (claim claims 'aud))
  (define azp (claim claims 'azp))
  (define nonce (claim claims 'nonce))
  (define exp (claim claims 'exp))
  (define iat (claim claims 'iat))
  (define sub (claim claims 'sub))
  (define tid (claim claims 'tid))
  (cond
    [(not (and (string? sub) (not (string=? sub "")))) "subject (sub) absent or empty"]
    [(not (string? iss)) "issuer (iss) absent"]
    ;; issuer: templated (multi-tenant) vs exact
    [(or (issuer-template? configured-issuer) (not (null? allowed-tenants)))
     (cond
       [(null? allowed-tenants) "templated issuer requires a non-empty allowedTenants"]
       [(not (and (string? tid) (member tid allowed-tenants))) "tid not in allowedTenants"]
       [(not (string=? iss (regexp-replace #rx"[{]tenantid[}]" configured-issuer tid)))
        "iss does not match the tenant-substituted issuer"]
       [else (validate-oidc-rest aud azp nonce exp iat client-id expected-nonce now leeway flow-start)])]
    [(not (string=? iss configured-issuer)) "iss does not match the configured issuer"]
    [else (validate-oidc-rest aud azp nonce exp iat client-id expected-nonce now leeway flow-start)]))

(define (validate-oidc-rest aud azp nonce exp iat client-id expected-nonce now leeway flow-start)
  (cond
    [(not (aud-contains? aud client-id)) "aud does not contain the client id"]
    [(and (string? azp) (not (string=? azp client-id))) "azp present and not the client id"]
    [(not (and (string? nonce) (string? expected-nonce)
               (crypto-constant-time-equal? nonce expected-nonce)))
     "nonce absent or mismatched"]
    [(not (and (real? exp) (<= now (+ exp leeway)))) "token expired or exp absent/non-numeric"]
    [(not (real? iat)) "iat absent or non-numeric"]
    [(> iat (+ now leeway)) "iat is in the future beyond leeway"]
    [(and flow-start (< iat (- flow-start leeway))) "iat predates the in-flight login start"]
    [else #t]))

;;; ── Authorize URL, with reserved-name rejection + percent-encoding ────────────
(define reserved-authorize-params
  '("client_id" "redirect_uri" "response_type" "scope" "state" "nonce"
    "code_challenge" "code_challenge_method" "code_verifier" "client_secret"
    "grant_type" "code"))

;; The first reserved name present in `extra` (an alist of string pairs), or #f.
(define (extra-params-reserved-violation extra)
  (for/or ([kv (in-list extra)])
    (and (member (car kv) reserved-authorize-params) (car kv))))

;; framework: alist of the flow's own params; extra: user's extraAuthorizeParams.
;; Both key and value are percent-encoded, so no value can smuggle an `&`/`=`.
(define (build-authorize-url authorize-url framework extra)
  (define bad (extra-params-reserved-violation extra))
  (when bad
    (error 'sso (string-append "extraAuthorizeParams may not set the reserved name " bad)))
  (define all (append framework extra))
  (define qs
    (string-join
     (for/list ([kv (in-list all)])
       (string-append (uri-encode (car kv)) "=" (uri-encode (cdr kv))))
     "&"))
  (string-append authorize-url (if (regexp-match? #rx"[?]" authorize-url) "&" "?") qs))

;;; ── The __Host-oauth cookie: integrity-protected in-flight state ──────────────
;; The cookie value is CLIENT-WRITABLE (HttpOnly stops reading, not choosing), so
;; the nonce / PKCE verifier / start-time / route-segment are authenticated under
;; a subkey DERIVED from the session key with domain separation (HMAC as a
;; one-block KDF — never the raw key that HMACs the session JWT, Risk 58).  Verify
;; runs against [current, previous] so a key rotation does not break in-flight
;; logins.  Nothing inside is trusted before the MAC verifies.
(define oauth-cookie-kdf-context #"tesl/sso __Host-oauth v1")

(define (oauth-subkey session-key-bytes)
  (hmac-sha256-bytes session-key-bytes oauth-cookie-kdf-context))

;; Constant-time byte-string equality (the crypto module's own equal takes
;; strings; MACs are raw bytes).
(define (ct-bytes=? a b)
  (and (= (bytes-length a) (bytes-length b))
       (= 0 (for/fold ([acc 0]) ([x (in-bytes a)] [y (in-bytes b)])
              (bitwise-ior acc (bitwise-xor x y))))))

;; fields: a jsexpr hash; MUST carry 'seg (route segment).  Returns "b64.mac".
(define (oauth-cookie-seal fields session-key-bytes)
  (define b64 (base64url-encode (jsexpr->bytes fields)))
  (define mac (base64url-encode
               (hmac-sha256-bytes (oauth-subkey session-key-bytes)
                                  (string->bytes/utf-8 b64))))
  (string-append b64 "." mac))

;; Verify + open.  segment: the callback's own route segment (a cookie minted at
;; one `sso` clause must not open at another's callback).  key-list: the current
;; and optional previous session-key bytes.  Returns the jsexpr hash or #f.
(define (oauth-cookie-open cookie segment key-list)
  (define parts (string-split cookie "."))
  (and (= (length parts) 2)
       (let ([b64 (car parts)] [mac (cadr parts)])
         (define given-mac
           (with-handlers ([exn:fail? (lambda (_) #f)])
             (base64url-decode-bytes mac)))
         (and given-mac
              (for/or ([k (in-list key-list)])
                (and k
                     (let ([expected (hmac-sha256-bytes (oauth-subkey k)
                                                        (string->bytes/utf-8 b64))])
                       (ct-bytes=? expected given-mac))))
              ;; MAC verified: only now is the payload parsed and its segment checked.
              (let ([fields (with-handlers ([exn:fail? (lambda (_) #f)])
                              (bytes->jsexpr (base64url-decode-bytes b64)))])
                (and (hash? fields)
                     (equal? (hash-ref fields 'seg #f) segment)
                     fields))))))

(define (base64url-decode-bytes s)
  ;; inverse of base64url-encode (no padding, url-safe alphabet)
  (define std (string-replace (string-replace s "-" "+") "_" "/"))
  (define padded (string-append std (make-string (modulo (- 4 (modulo (string-length std) 4)) 4) #\=)))
  (base64-decode-bytes padded))

;; local base64 decode without pulling net/base64's provide name conflicts
(require (only-in net/base64 base64-decode))
(define (base64-decode-bytes s) (base64-decode (string->bytes/utf-8 s)))

;;; ── Provider defaults (the TimeZone/Currency pattern, as data) ────────────────
;; Minimal scopes by rule, not preference: a defaults table is where over-broad
;; scope silently becomes every app's default.  Widening is the user's explicit
;; record update (orchestration layer / surface).
(define (sso-defaults provider client-id client-secret)
  (case provider
    [(Google)
     (hasheq 'kind 'oidc
             'issuer "https://accounts.google.com"
             'client-id client-id 'client-secret client-secret
             'scopes '("openid" "email" "profile"))]
    [(GitHub)
     (hasheq 'kind 'oauth2
             'authorize-url "https://github.com/login/oauth/authorize"
             'token-url "https://github.com/login/oauth/access_token"
             'userinfo-url "https://api.github.com/user"
             'emails-url "https://api.github.com/user/emails" ; second call for the verified primary
             'client-id client-id 'client-secret client-secret
             'scopes '("user:email")
             'subject-field "id" 'email-field "email"
             'email-verified-field #f 'name-field "name")]
    [(Discord)
     (hasheq 'kind 'oauth2
             'authorize-url "https://discord.com/api/oauth2/authorize"
             'token-url "https://discord.com/api/oauth2/token"
             'userinfo-url "https://discord.com/api/users/@me"
             'client-id client-id 'client-secret client-secret
             'scopes '("identify" "email")
             'subject-field "id" 'email-field "email"
             'email-verified-field "verified" 'name-field "username")]
    [else (error 'sso-defaults "unknown provider: ~a" provider)]))

;; Generic OIDC connection: any spec-compliant issuer (a self-hosted Keycloak or
;; dex, Okta, Auth0, single-tenant Entra, …) by its ISSUER URL.  The blessed
;; providers above bake real-world endpoints; this one discovers them from the
;; issuer's /.well-known/openid-configuration, so the SAME signature+claims trust
;; argument (§OIDC) applies.  The issuer still passes the SSRF preflight, so a
;; loopback issuer is refused unless the loud loopback dev escape is set.
(define (sso-oidc issuer client-id client-secret)
  (hasheq 'kind 'oidc
          'issuer issuer
          'client-id client-id 'client-secret client-secret
          'scopes '("openid" "email" "profile")))

;; For the plain-OAuth2 family there is no issuer claim, so the identity key's
;; issuer is SYNTHESISED from the scheme+host of the userinfo URL — stable across
;; a route-segment rename and across Discord's in-path API version bump.
(define (synthesize-issuer userinfo-url)
  (define u (string->url userinfo-url))
  (string-append (url-scheme u) "://" (url-host u)))

;;; ── Single-use `state`, honestly scoped (per-process) ─────────────────────────
;; A bounded, TTL'd set of spent `state` values makes a second presentation fail
;; WITHIN a process.  Across processes the guarantee is the provider's single-use
;; `code` + PKCE binding — this is not a cluster-wide claim.  Bounded so it cannot
;; become a memory-amplification primitive.
(struct spent-set (ht max ttl) #:mutable)
(define (make-spent-state-set #:max [m 10000] #:ttl-seconds [ttl 600])
  (spent-set (make-hash) m ttl))

;; Returns #t if `state` was newly spent (accept), #f if already spent (replay).
(define (state-spend! set state now)
  (define ht (spent-set-ht set))
  ;; evict expired
  (for ([(k exp) (in-hash ht)]) (when (< exp now) (hash-remove! ht k)))
  ;; bound: if full, refuse to grow (fail closed to a fresh flow, not a leak)
  (cond
    [(hash-has-key? ht state) #f]
    [(>= (hash-count ht) (spent-set-max set))
     ;; drop the whole set rather than grow unbounded; the provider `code`
     ;; single-use still holds.  A newly presented state is accepted once.
     (hash-clear! ht)
     (hash-set! ht state (+ now (spent-set-ttl set))) #t]
    [else (hash-set! ht state (+ now (spent-set-ttl set))) #t]))

;;; ── SSRF preflight ────────────────────────────────────────────────────────────
;; Returns a reason string if the URL's host is a forbidden literal IP, else #f.
;; A hostname is passed through here; the RESOLVE-then-connect-pin step (refuse if
;; ANY resolved address is forbidden, dial the checked address) is the http-client
;; socket integration and is tracked as remaining Phase-1 work — the classifier it
;; will call is dsl/private/ssrf-guard.rkt, already tested.
(define (url-ssrf-violation url-str)
  (define u (with-handlers ([exn:fail? (lambda (_) #f)]) (string->url url-str)))
  (define host (and u (url-host u)))
  (cond
    [(not host) "URL has no host"]
    [(literal-ip? host) (ip-forbidden-reason host)]
    [else #f]))

(define (literal-ip? host)
  (or (regexp-match? #rx"^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$" host)
      (regexp-match? #rx"^[0-9a-fA-F:]+$" host)   ; bare IPv6
      (regexp-match? #rx"^\\[.*\\]$" host)))       ; bracketed IPv6


;;; ════════════════════════════════════════════════════════════════════════════
;;;  Orchestration layer (drives HttpClient; stubbable via the http hook)
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; Every outbound leg is https-only, SSRF-preflighted, and does not follow
;; redirects (net/http-client returns a 30x rather than chasing it).  Provider
;; `error`/`error_description` strings are NEVER reflected — a failure is a fixed
;; reason string of our own.  The client secret travels in the Authorization
;; header (client_secret_basic), never in a URL.

(define (fail reason) (hasheq 'ok #f 'reason reason))
(define (ok identity) (hasheq 'ok #t 'identity identity))

(define (resp-fields resp) (record-value-fields resp))
(define (resp-status resp) (hash-ref (resp-fields resp) 'status 0))
(define (resp-body resp)   (hash-ref (resp-fields resp) 'body ""))

(define (require-https! who url)
  (unless (regexp-match? #rx"^https://" url) (error who "endpoint must be https"))
  (define v (url-ssrf-violation url))
  (when v (error who (string-append "SSRF-forbidden host: " v))))

(define (get-json who url headers)
  (require-https! who url)
  (define resp (HttpClient.get url headers))
  (unless (= 200 (resp-status resp)) (error who "non-200 response"))
  (string->jsexpr (resp-body resp)))

(define (post-json who url headers body)
  (require-https! who url)
  (define resp (HttpClient.post url headers body))
  (unless (= 200 (resp-status resp)) (error who "non-200 response"))
  (string->jsexpr (resp-body resp)))

(define (form-encode pairs)
  (string-join
   (for/list ([kv (in-list pairs)])
     (string-append (uri-encode (car kv)) "=" (uri-encode (cdr kv))))
   "&"))

(define (basic-auth client-id client-secret)
  ;; The secret arrives as a `Secret` newtype (from requireSecret) — unwrap it to
  ;; its raw string ONLY here, at the HTTP boundary (client_secret_basic), so the
  ;; connection hash keeps the redaction-protected Secret everywhere else.
  (define (raw v) (if (newtype-value? v) (newtype-value-value v) v))
  (string-append
   "Basic "
   (bytes->string/utf-8
    (base64-encode
     (string->bytes/utf-8 (string-append (raw client-id) ":" (raw client-secret))) #""))))

(define (jref h field) (hash-ref h (string->symbol field) #f))
(define (as-string v) (cond [(string? v) v] [(number? v) (number->string v)] [else #f]))

;; OIDC discovery: fetch + validate + return endpoints.  The document's own
;; issuer must equal the configured one exactly, EXCEPT for the templated
;; multi-tenant case, which is accepted here and enforced at claim time by the
;; tid+substitution rule (§Entra ID).  S256 must be advertised.
(define (oidc-discover issuer)
  (define base (regexp-replace #rx"/+$" issuer ""))
  (define disco-url (string-append base "/.well-known/openid-configuration"))
  (define doc (get-json 'sso-discovery disco-url '()))
  (define doc-iss (hash-ref doc 'issuer #f))
  (unless (or (equal? doc-iss issuer) (issuer-template? (or doc-iss "")))
    (error 'sso-discovery "discovery issuer does not match the configured issuer"))
  (define methods (hash-ref doc 'code_challenge_methods_supported '()))
  (unless (and (list? methods) (member "S256" methods))
    (error 'sso-discovery "provider does not advertise PKCE S256"))
  (hasheq 'kind 'oidc 'issuer issuer
          'authorize-url (hash-ref doc 'authorization_endpoint)
          'token-url     (hash-ref doc 'token_endpoint)
          'jwks-url      (hash-ref doc 'jwks_uri #f)
          'signing-algs  (let ([a (hash-ref doc 'id_token_signing_alg_values_supported '())])
                           (if (list? a) a '()))))

(define (resolve-endpoints conn)
  (case (hash-ref conn 'kind)
    [(oidc)   (oidc-discover (hash-ref conn 'issuer))]
    [(oauth2) conn]
    [else (error 'sso "unknown connection kind")]))

;; Start a login: resolve endpoints, mint state/nonce/verifier (supplied by the
;; caller so this stays deterministic-testable), build the authorize URL and the
;; sealed __Host-oauth cookie.  Returns (values authorize-url cookie-value).
(define (sso-begin-login conn segment redirect-uri session-key-bytes
                         #:state state #:nonce nonce #:verifier verifier #:now now
                         #:extra [extra '()])
  (define ep (resolve-endpoints conn))
  (define challenge (pkce-challenge verifier))
  (define scope (string-join (hash-ref conn 'scopes '("openid" "email" "profile")) " "))
  (define oidc? (eq? (hash-ref conn 'kind) 'oidc))
  (define framework
    (append
     (list (cons "client_id" (hash-ref conn 'client-id))
           (cons "redirect_uri" redirect-uri)
           (cons "response_type" "code")
           (cons "scope" scope)
           (cons "state" state)
           (cons "code_challenge" challenge)
           (cons "code_challenge_method" "S256"))
     (if oidc? (list (cons "nonce" nonce)) '())))
  (define authorize-url (build-authorize-url (hash-ref ep 'authorize-url) framework extra))
  (define cookie (oauth-cookie-seal
                  (hasheq 'seg segment 'state state 'nonce nonce 'v verifier 'ts now)
                  session-key-bytes))
  (values authorize-url cookie))

;; Handle the callback.  Returns (hash 'ok #t 'identity <SsoIdentity>) or
;; (hash 'ok #f 'reason <fixed string>).  `session-keys` is (list current-bytes
;; previous-bytes-or-#f).
(define (sso-handle-callback conn segment code cookie redirect-uri session-keys
                             #:now now #:state [presented-state #f])
  (define st (oauth-cookie-open cookie segment session-keys))
  (cond
    [(not st) (fail "invalid or missing login state")]
    [(and presented-state (not (equal? presented-state (hash-ref st 'state #f))))
     (fail "state mismatch")]
    [else
     (with-handlers ([exn:fail? (lambda (_e) (fail (format "sso callback failed: ~a" (exn-message _e))))])
       (define nonce (hash-ref st 'nonce #f))
       (define verifier (hash-ref st 'v #f))
       (define flow-start (hash-ref st 'ts #f))
       (define ep (resolve-endpoints conn))
       (define token-url (hash-ref ep 'token-url))
       (define tokens
         (post-json 'sso-token token-url
                    (list (Tuple2 "Authorization"
                                  (basic-auth (hash-ref conn 'client-id)
                                              (hash-ref conn 'client-secret)))
                          (Tuple2 "Content-Type" "application/x-www-form-urlencoded")
                          (Tuple2 "Accept" "application/json"))
                    (form-encode (list (cons "grant_type" "authorization_code")
                                       (cons "code" code)
                                       (cons "redirect_uri" redirect-uri)
                                       (cons "code_verifier" verifier)))))
       (case (hash-ref conn 'kind)
         [(oidc)   (finish-oidc conn segment ep tokens nonce flow-start now)]
         [(oauth2) (finish-oauth2 conn segment ep tokens)]
         [else (fail "unknown connection kind")]))]))

;;; ── JWKS cache + rotation refetch (Risk 27) ──────────────────────────────────
;; A bounded, TTL'd cache keyed by jwks_uri, so a normal login does NOT hit the
;; IdP's JWKS endpoint every time (a DoS-amplification vector).  A key ROTATION
;; (the token's kid is absent from the cached set) triggers exactly ONE refetch,
;; RATE-LIMITED per url, so an attacker presenting random kids cannot force
;; unbounded refetches.  Bounded in size so it cannot become a memory primitive.
(define jwks-cache-ttl 300)       ; a cached JWKS is reused for up to 5 min
(define jwks-refetch-window 60)   ; at most one unknown-kid refetch / min / url
(define jwks-cache-max 64)
(struct jwks-entry (jwks fetched-at last-refetch) #:mutable)
(define jwks-cache (make-hash))   ; jwks-url -> jwks-entry
(define (jwks-cache-reset!) (hash-clear! jwks-cache))

(define (id-token-kid id-token)
  (with-handlers ([exn:fail? (lambda (_e) #f)])
    (let ([parts (string-split id-token ".")])
      (and (pair? parts)
           (let ([hdr (bytes->jsexpr (base64url-decode-bytes (car parts)))])
             (and (hash? hdr) (hash-ref hdr 'kid #f)))))))

(define (jwks-has-kid? jwks kid)
  (define keys (let ([k (and (hash? jwks) (hash-ref jwks 'keys #f))]) (if (list? k) k '())))
  (cond
    [(not kid) (pair? keys)]            ; no kid ⇒ a single-key set is usable
    [else (for/or ([j (in-list keys)]) (and (hash? j) (equal? (hash-ref j 'kid #f) kid)))]))

;; The JWKS to verify a token with `kid` against, per the cache/rotation rules.
(define (jwks-for url kid now)
  (define e (hash-ref jwks-cache url #f))
  (define fresh? (and e (< (- now (jwks-entry-fetched-at e)) jwks-cache-ttl)))
  (cond
    ;; fresh entry that already has the kid — no network.
    [(and fresh? (jwks-has-kid? (jwks-entry-jwks e) kid)) (jwks-entry-jwks e)]
    ;; never cached, expired, or (unknown kid AND the per-url rate window has
    ;; elapsed) — refetch once and cache it.
    [(or (not e) (not fresh?)
         (>= (- now (jwks-entry-last-refetch e)) jwks-refetch-window))
     (define fresh (get-json 'sso-jwks url '()))
     (when (and (not (hash-has-key? jwks-cache url))
                (>= (hash-count jwks-cache) jwks-cache-max))
       (hash-clear! jwks-cache))
     (hash-set! jwks-cache url (jwks-entry fresh now now))
     fresh]
    ;; unknown kid but within the rate window — hand back the cached set; the
    ;; verifier fails "no key matches kid" fail-closed, with NO extra fetch.
    [else (jwks-entry-jwks e)]))

;; Risk 52 (OIDC Core §5.3.2 — the UserInfo `sub` MUST equal the ID Token
;; `sub`) is N/A BY DESIGN here: this path is id_token-AUTHORITATIVE and never
;; calls the UserInfo endpoint — the subject, email and every claim come from
;; the signature-verified id_token below, so there is no second `sub` that
;; could disagree.  (The plain-OAuth2 path uses UserInfo but has no id_token,
;; so the cross-check is likewise inapplicable.)  If a UserInfo fetch is ever
;; added to this path, it MUST assert its `sub` equals the id_token `sub`.
(define (finish-oidc conn segment ep tokens nonce flow-start now)
  (define id-token (hash-ref tokens 'id_token #f))
  (define jwks-url (and (string? id-token) (hash-ref ep 'jwks-url #f)))
  (define pinned (filter (lambda (a) (member a (hash-ref ep 'signing-algs '())))
                         '("RS256" "ES256")))
  (cond
    [(not (string? id-token)) (fail "no id_token in token response")]
    ;; Phase 2.5: verify the RS256/ES256 signature against the JWKS BEFORE any
    ;; claim is read.  alg is pinned from discovery ∩ what we implement, and a
    ;; verification failure is terminal — there is no §3.1.3.7 downgrade path.
    [(not jwks-url) (fail "discovery has no jwks_uri")]
    [(null? pinned) (fail "no supported id_token signing algorithm advertised")]
    [(not (eq? #t (verify-jws id-token (jwks-for jwks-url (id-token-kid id-token) now) #:algs pinned)))
     (fail "id_token signature verification failed")]
    [else
     (define parts (string-split id-token "."))
     (cond
       [(< (length parts) 2) (fail "malformed id_token")]
       [else
        (define claims (bytes->jsexpr (base64url-decode-bytes (cadr parts))))
        (define vr (validate-oidc-claims claims
                    #:issuer (hash-ref conn 'issuer)
                    #:client-id (hash-ref conn 'client-id)
                    #:nonce nonce #:now now #:flow-start flow-start
                    #:allowed-tenants (hash-ref conn 'allowed-tenants '())))
        (if (string? vr)
            (fail vr)
            (build-identity conn segment (hash-ref claims 'iss)
                            (as-string (hash-ref claims 'sub))
                            #:email (hash-ref claims 'email #f)
                            #:email-verified (hash-ref claims 'email_verified #f)
                            #:name (hash-ref claims 'name #f)
                            #:hd (hash-ref claims 'hd #f)
                            #:tid (hash-ref claims 'tid #f)
                            #:claims claims))])]))

;; Risk 2: a provider's userinfo email may be its PUBLIC profile email — null
;; or UNVERIFIED (GitHub is the canonical case).  When the connection declares
;; an `emails-url`, make that documented second call and take the PRIMARY +
;; VERIFIED address — the only email that domain restriction (VerifiedEmail-
;; only) may trust.  No primary+verified row ⇒ #f, so the caller falls back to
;; the unverified userinfo email rather than fabricate a verified one.
(define (verified-primary-email conn access)
  (define url (hash-ref conn 'emails-url #f))
  (and (string? url)
       (let ([rows (get-json 'sso-emails url
                             (list (Tuple2 "Authorization" (string-append "Bearer " access))
                                   (Tuple2 "Accept" "application/json")))])
         (and (list? rows)
              (for/or ([row (in-list rows)])
                (and (hash? row)
                     (eq? #t (jref row "primary"))
                     (eq? #t (jref row "verified"))
                     (as-string (jref row "email"))))))))

(define (finish-oauth2 conn segment ep tokens)
  (define access (hash-ref tokens 'access_token #f))
  (cond
    [(not (string? access)) (fail "no access_token in token response")]
    [else
     (define info (get-json 'sso-userinfo (hash-ref conn 'userinfo-url)
                            (list (Tuple2 "Authorization" (string-append "Bearer " access))
                                  (Tuple2 "Accept" "application/json"))))
     (define sub (as-string (jref info (hash-ref conn 'subject-field))))
     (cond
       [(not sub) (fail "no subject in userinfo")]
       [else
        (define iss (synthesize-issuer (hash-ref conn 'userinfo-url)))
        ;; Risk 2: prefer the primary+verified address from the emails-url
        ;; second call (GitHub); else the userinfo email, verified only if the
        ;; provider advertises a verified flag (e.g. Discord's `verified`).
        (define verified-primary (verified-primary-email conn access))
        (define userinfo-email (and (hash-ref conn 'email-field #f)
                                    (as-string (jref info (hash-ref conn 'email-field)))))
        (define evf (hash-ref conn 'email-verified-field #f))
        (define email (or verified-primary userinfo-email))
        (define everified (if verified-primary #t (and evf (eq? #t (jref info evf)) #t)))
        (define name (and (hash-ref conn 'name-field #f)
                          (as-string (jref info (hash-ref conn 'name-field)))))
        (build-identity conn segment iss sub
                        #:email email #:email-verified everified
                        #:name name #:hd #f #:tid #f #:claims info)])]))

;; Apply the runtime-enforced domain restrictions (before any app code sees the
;; identity), then assemble the SsoIdentity.
(define (build-identity conn segment issuer subject
                        #:email email #:email-verified email-verified
                        #:name name #:hd hd #:tid tid #:claims claims)
  (cond
    [(not (and (string? subject) (not (string=? subject "")))) (fail "empty subject")]
    [else
     (define-values (etag eval) (email-claim email email-verified))
     (cond
       [(not (email-domain-allowed? etag eval (hash-ref conn 'allowed-email-domains '())))
        (fail "email domain not allowed")]
       [(not (hosted-domain-allowed? hd (hash-ref conn 'allowed-hosted-domains '())))
        (fail "hosted domain not allowed")]
       [else
        (ok (hasheq 'key (sso-subject-key issuer subject)
                    'issuer issuer 'provider segment 'subject subject
                    'tenant tid
                    'email-tag etag 'email eval
                    'name name 'claims claims))])]))

;;; ── Positional wrappers for dsl/web.rkt (dynamic-require friendly) ────────────
(define (sso-begin-login* conn segment redirect-uri session-key-bytes
                          state nonce verifier now)
  (sso-begin-login conn segment redirect-uri session-key-bytes
                   #:state state #:nonce nonce #:verifier verifier #:now now))

(define (sso-handle-callback* conn segment code cookie redirect-uri session-keys
                              now presented-state)
  (sso-handle-callback conn segment code cookie redirect-uri session-keys
                       #:now now #:state presented-state))
