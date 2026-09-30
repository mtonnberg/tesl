package teslrt

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

// Tesl's SSO runtime — OIDC and plain OAuth2. A port of `dsl/sso.rkt`, and it keeps that
// module's split: a PURE layer of deterministic security helpers (here) and an ORCHESTRATION
// layer that drives the HTTP client (sso_flow.go). The account-takeover-class bugs live in
// the pure layer, which is why it is the half with no I/O in it at all.
//
// The third-party identity is exchanged ONCE, at the callback, for Tesl's own
// `__Host-session` cookie, so every existing session and proof surface is untouched.

// ── PKCE (RFC 7636), S256 only ───────────────────────────────────────────────
// challenge = BASE64URL(SHA256(ASCII(verifier))). `plain` is never produced, and a provider
// that does not advertise S256 is refused upstream.
func pkceChallenge(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

// ── SsoSubjectKey: an INJECTIVE derivation of (issuer, subject) ──────────────
// Naive concatenation lets ("https://a", "x|https://b") collide with ("https://a|x",
// "https://b"). Each component is length-prefixed with an 8-byte big-endian length before
// hashing, so the encoding is injective and a cross-issuer collision is impossible. The
// result is opaque hex with no email inside it, so a schema cannot key a user on an address.
func ssoSubjectKey(issuer, subject string) string {
	prefixed := func(text string) []byte {
		raw := []byte(text)
		out := make([]byte, 8, 8+len(raw))
		binary.BigEndian.PutUint64(out, uint64(len(raw)))
		return append(out, raw...)
	}
	sum := sha256.Sum256(append(prefixed(issuer), prefixed(subject)...))
	return hex.EncodeToString(sum[:])
}

// ── EmailClaim: verified-ness is a CONSTRUCTOR, not a sibling boolean ────────
// "verified" is reachable ONLY with a positive verification signal and a non-empty address,
// so a provider that emits no `email_verified` (Entra) can never yield it — the nOAuth
// containment expressed as a rule rather than as a comment.
const (
	emailNone       = "none"
	emailUnverified = "unverified"
	emailVerified   = "verified"
)

func emailClaim(email string, verifiedSignal bool) (string, string) {
	trimmed := strings.TrimSpace(email)
	switch {
	case trimmed == "":
		return emailNone, ""
	case verifiedSignal:
		return emailVerified, trimmed
	default:
		return emailUnverified, trimmed
	}
}

// ── Domain restriction (runtime-enforced, verified-email only) ───────────────
// Case-insensitive over trimmed domains, with the FQDN root canonicalised
// (`example.com.` is `example.com`) so a trailing-dot form cannot slip past an allow-list
// written without one. Both the incoming domain AND every allow-list entry go through this,
// so a homoglyph label is correctly a DIFFERENT domain and is refused fail-closed. Full
// IDNA/punycode folding is a documented gap, and it is the safe direction: a legitimate IDN
// written in the other form is a false negative, never a false accept.
var trailingDots = regexp.MustCompile(`\.+$`)

func normalizeDomain(domain string) string {
	return trailingDots.ReplaceAllString(strings.ToLower(strings.TrimSpace(domain)), "")
}

func emailDomainOf(email string) string {
	at := strings.LastIndex(email, "@")
	if at < 0 || at == len(email)-1 {
		return ""
	}
	return normalizeDomain(email[at+1:])
}

// An EMPTY allow-list is no restriction. A non-empty one requires the address to be
// VERIFIED and its domain a member: restricting by an address the provider never verified is
// the same takeover in disguise.
func emailDomainAllowed(tag, email string, allowed []string) bool {
	if len(allowed) == 0 {
		return true
	}
	if tag != emailVerified {
		return false
	}
	domain := emailDomainOf(email)
	for _, each := range allowed {
		if normalizeDomain(each) == domain {
			return true
		}
	}
	return false
}

// Empty is no restriction. Non-empty requires the `hd` claim to be PRESENT and a member: an
// absent claim is a refusal, not a pass.
func hostedDomainAllowed(hostedDomain string, allowed []string) bool {
	if len(allowed) == 0 {
		return true
	}
	if strings.TrimSpace(hostedDomain) == "" {
		return false
	}
	normalized := normalizeDomain(hostedDomain)
	for _, each := range allowed {
		if normalizeDomain(each) == normalized {
			return true
		}
	}
	return false
}

// ── OIDC claim validation (fail-closed) ──────────────────────────────────────
// Answers "" on success or a short reason on failure. Signature verification is a SEPARATE
// step: this is "what login does this token belong to", not "who wrote it".
var tenantTemplate = regexp.MustCompile(`\{tenantid\}`)

func issuerIsTemplate(issuer string) bool { return tenantTemplate.MatchString(issuer) }

func audienceContains(audience any, clientID string) bool {
	switch value := audience.(type) {
	case string:
		return value == clientID
	case []any:
		for _, each := range value {
			if text, isText := each.(string); isText && text == clientID {
				return true
			}
		}
	}
	return false
}

type oidcClaimRules struct {
	issuer         string
	clientID       string
	nonce          string
	now            int64
	leeway         int64
	flowStart      int64
	allowedTenants []string
}

func validateOidcClaims(claims map[string]any, rules oidcClaimRules) string {
	text := func(key string) string {
		value, _ := claims[key].(string)
		return value
	}
	subject, issuer, tenant := text("sub"), text("iss"), text("tid")
	switch {
	case subject == "":
		return "subject (sub) absent or empty"
	case claims["iss"] == nil || issuer == "":
		return "issuer (iss) absent"
	}
	if issuerIsTemplate(rules.issuer) || len(rules.allowedTenants) > 0 {
		if len(rules.allowedTenants) == 0 {
			return "templated issuer requires a non-empty allowedTenants"
		}
		member := false
		for _, allowed := range rules.allowedTenants {
			if allowed == tenant {
				member = true
			}
		}
		if tenant == "" || !member {
			return "tid not in allowedTenants"
		}
		if issuer != tenantTemplate.ReplaceAllLiteralString(rules.issuer, tenant) {
			return "iss does not match the tenant-substituted issuer"
		}
	} else if issuer != rules.issuer {
		return "iss does not match the configured issuer"
	}
	return validateOidcRest(claims, rules)
}

func validateOidcRest(claims map[string]any, rules oidcClaimRules) string {
	if !audienceContains(claims["aud"], rules.clientID) {
		return "aud does not contain the client id"
	}
	if authorized, present := claims["azp"].(string); present && authorized != rules.clientID {
		return "azp present and not the client id"
	}
	nonce, hasNonce := claims["nonce"].(string)
	if !hasNonce || rules.nonce == "" ||
		!hmac.Equal([]byte(nonce), []byte(rules.nonce)) {
		return "nonce absent or mismatched"
	}
	expires, hasExpiry := jsonNumber(claims["exp"])
	if !hasExpiry || rules.now > expires+rules.leeway {
		return "token expired or exp absent/non-numeric"
	}
	issuedAt, hasIssuedAt := jsonNumber(claims["iat"])
	if !hasIssuedAt {
		return "iat absent or non-numeric"
	}
	if issuedAt > rules.now+rules.leeway {
		return "iat is in the future beyond leeway"
	}
	if rules.flowStart > 0 && issuedAt < rules.flowStart-rules.leeway {
		return "iat predates the in-flight login start"
	}
	return ""
}

// jsonNumber reads a JSON number however it was decoded: `json.Number` when the decoder was
// asked to keep precision (which is how ParseJSON reads a body), float64 otherwise.
func jsonNumber(value any) (int64, bool) {
	switch number := value.(type) {
	case json.Number:
		parsed, err := number.Int64()
		if err != nil {
			asFloat, floatErr := number.Float64()
			return int64(asFloat), floatErr == nil
		}
		return parsed, true
	case float64:
		return int64(number), true
	case int64:
		return number, true
	}
	return 0, false
}

// ── The authorize URL: reserved names refused, everything percent-encoded ────
var reservedAuthorizeParams = []string{
	"client_id", "redirect_uri", "response_type", "scope", "state", "nonce",
	"code_challenge", "code_challenge_method", "code_verifier", "client_secret",
	"grant_type", "code",
}

// The first reserved name an extra-params list sets, or "".
func extraParamsReservedViolation(extra []Tuple2[string, string]) string {
	for _, pair := range extra {
		for _, reserved := range reservedAuthorizeParams {
			if pair.Tuple2First == reserved {
				return pair.Tuple2First
			}
		}
	}
	return ""
}

// framework is the flow's own parameters; extra is the app's `extraAuthorizeParams`. Both
// the key and the value are percent-encoded, so no value can smuggle an `&` or an `=`.
func buildAuthorizeURL(authorizeURL string, framework, extra []Tuple2[string, string]) string {
	if bad := extraParamsReservedViolation(extra); bad != "" {
		panic("sso: extraAuthorizeParams may not set the reserved name " + bad)
	}
	parts := make([]string, 0, len(framework)+len(extra))
	for _, pair := range append(append([]Tuple2[string, string]{}, framework...), extra...) {
		parts = append(parts,
			url.QueryEscape(pair.Tuple2First)+"="+url.QueryEscape(pair.Tuple2Second))
	}
	separator := "?"
	if strings.Contains(authorizeURL, "?") {
		separator = "&"
	}
	return authorizeURL + separator + strings.Join(parts, "&")
}

// ── The `__Host-oauth` cookie: integrity-protected in-flight state ───────────
// The cookie value is CLIENT-WRITABLE (HttpOnly stops reading, not choosing), so the nonce,
// the PKCE verifier, the start time and the route segment are authenticated under a subkey
// DERIVED from the session key with domain separation — an HMAC used as a one-block KDF,
// never the raw key that signs the session JWT. Verification runs against [current,
// previous] so a key rotation does not break an in-flight login. NOTHING inside is trusted
// before the MAC verifies.
const oauthCookieKdfContext = "tesl/sso __Host-oauth v1"

func oauthSubkey(sessionKey string) []byte {
	mac := hmac.New(sha256.New, []byte(sessionKey))
	mac.Write([]byte(oauthCookieKdfContext))
	return mac.Sum(nil)
}

// oauthState is what the cookie carries between the login redirect and the callback.
type oauthState struct {
	Segment  string `json:"seg"`
	State    string `json:"state"`
	Nonce    string `json:"nonce"`
	Verifier string `json:"v"`
	Started  int64  `json:"ts"`
}

func oauthCookieSeal(fields oauthState, sessionKey string) string {
	payload, err := json.Marshal(fields)
	if err != nil {
		panic("sso: the in-flight login state does not encode")
	}
	encoded := base64.RawURLEncoding.EncodeToString(payload)
	mac := hmac.New(sha256.New, oauthSubkey(sessionKey))
	mac.Write([]byte(encoded))
	return encoded + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// oauthCookieOpen verifies and opens the cookie. `segment` is the CALLBACK's own route
// segment: a cookie minted at one `sso` clause must not open at another's callback.
func oauthCookieOpen(cookie, segment string, sessionKeys []string) (oauthState, bool) {
	var empty oauthState
	parts := strings.Split(cookie, ".")
	if len(parts) != 2 {
		return empty, false
	}
	encoded, presentedMac := parts[0], parts[1]
	given, err := base64.RawURLEncoding.DecodeString(presentedMac)
	if err != nil {
		return empty, false
	}
	verified := false
	for _, key := range sessionKeys {
		if key == "" {
			continue
		}
		mac := hmac.New(sha256.New, oauthSubkey(key))
		mac.Write([]byte(encoded))
		if hmac.Equal(mac.Sum(nil), given) {
			verified = true
		}
	}
	if !verified {
		return empty, false
	}
	// The MAC verified: only NOW is the payload parsed and its segment checked.
	payload, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return empty, false
	}
	var fields oauthState
	if json.Unmarshal(payload, &fields) != nil {
		return empty, false
	}
	if fields.Segment != segment {
		return empty, false
	}
	return fields, true
}

// ── Provider defaults, as data ───────────────────────────────────────────────
// Minimal scopes BY RULE, not by preference: a defaults table is exactly where an over-broad
// scope silently becomes every app's default. Widening is the app's explicit record update.

// SsoConnection is a configured identity provider. It is OPAQUE on the Tesl side — built by
// `Sso.defaults` or `Sso.oidc`, narrowed by the allow-list builders, and read by nothing —
// so a program cannot assemble one whose endpoints skipped the rules below.
type SsoConnection struct {
	Kind          string // "oidc" | "oauth2"
	Issuer        string
	AuthorizeURL  string
	TokenURL      string
	UserinfoURL   string
	EmailsURL     string
	JwksURL       string
	EndSessionURL string
	SigningAlgs   []string
	ClientID      string
	ClientSecret  Secret
	Scopes        []string

	SubjectField       string
	EmailField         string
	EmailVerifiedField string
	NameField          string

	AllowedEmailDomains  []string
	AllowedHostedDomains []string
	AllowedTenants       []string
}

// SsoDefaults is `Sso.defaults <Provider> clientId clientSecret`.
func SsoDefaults(provider, clientID string, clientSecret Secret) SsoConnection {
	switch provider {
	case "Google":
		return SsoConnection{
			Kind: "oidc", Issuer: "https://accounts.google.com",
			ClientID: clientID, ClientSecret: clientSecret,
			Scopes: []string{"openid", "email", "profile"},
		}
	case "GitHub":
		// #nosec G101 -- These are PUBLIC endpoint URLs, not credentials. The rule matches
		// any constant string assigned to a field whose name contains "token", and the
		// OAuth2 spec's name for the exchange endpoint is the token endpoint. The two
		// credential fields beside them take their values from the caller.
		return SsoConnection{
			Kind:         "oauth2",
			AuthorizeURL: "https://github.com/login/oauth/authorize",
			TokenURL:     "https://github.com/login/oauth/access_token",
			UserinfoURL:  "https://api.github.com/user",
			// A SECOND call for the primary verified address: GitHub's profile email is
			// public and may be unverified, and only a verified one may be trusted.
			EmailsURL: "https://api.github.com/user/emails",
			ClientID:  clientID, ClientSecret: clientSecret,
			Scopes:       []string{"user:email"},
			SubjectField: "id", EmailField: "email", NameField: "name",
		}
	case "Discord":
		// #nosec G101 -- A public endpoint URL, as above.
		return SsoConnection{
			Kind:         "oauth2",
			AuthorizeURL: "https://discord.com/api/oauth2/authorize",
			TokenURL:     "https://discord.com/api/oauth2/token",
			UserinfoURL:  "https://discord.com/api/users/@me",
			ClientID:     clientID, ClientSecret: clientSecret,
			Scopes:       []string{"identify", "email"},
			SubjectField: "id", EmailField: "email",
			EmailVerifiedField: "verified", NameField: "username",
		}
	default:
		panic("Sso.defaults: unknown provider: " + provider)
	}
}

// SsoOidc is a generic OIDC connection by ISSUER URL — a self-hosted Keycloak or dex, Okta,
// Auth0, a single-tenant Entra. The blessed providers above bake real endpoints; this one
// discovers them from the issuer's /.well-known/openid-configuration, so the same signature
// and claim trust argument applies.
func SsoOidc(issuer, clientID string, clientSecret Secret) SsoConnection {
	return SsoConnection{
		Kind: "oidc", Issuer: issuer,
		ClientID: clientID, ClientSecret: clientSecret,
		Scopes: []string{"openid", "email", "profile"},
	}
}

// The allow-list builders answer a NARROWED copy, which is what makes them chainable and
// what keeps a connection immutable once a login is using it.
func SsoAllowedEmailDomains(conn SsoConnection, domains []string) SsoConnection {
	conn.AllowedEmailDomains = append([]string{}, domains...)
	return conn
}

func SsoAllowedHostedDomains(conn SsoConnection, domains []string) SsoConnection {
	conn.AllowedHostedDomains = append([]string{}, domains...)
	return conn
}

func SsoAllowedTenants(conn SsoConnection, tenants []string) SsoConnection {
	conn.AllowedTenants = append([]string{}, tenants...)
	return conn
}

// For the plain-OAuth2 family there is no issuer claim, so the identity key's issuer is
// SYNTHESISED from the scheme and host of the userinfo URL — stable across a route-segment
// rename and across an in-path API version bump.
func synthesizeIssuer(userinfoURL string) string {
	parsed, err := url.Parse(userinfoURL)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return userinfoURL
	}
	return parsed.Scheme + "://" + parsed.Host
}

// ── Single-use `state`, honestly scoped (per process) ────────────────────────
// A bounded, TTL'd set of spent `state` values makes a second presentation fail WITHIN a
// process. Across processes the guarantee is the provider's single-use `code` plus the PKCE
// binding — this is not a cluster-wide claim. Bounded so it cannot become a
// memory-amplification primitive.
const (
	spentStateMax = 10000
	spentStateTTL = 600
)

var (
	spentStateMutex sync.Mutex
	spentStates     = map[string]int64{}
)

// stateSpend answers true when `state` was newly spent (accept) and false when it was
// already spent (a replay).
func stateSpend(state string, now int64) bool {
	spentStateMutex.Lock()
	defer spentStateMutex.Unlock()
	for key, expiry := range spentStates {
		if expiry < now {
			delete(spentStates, key)
		}
	}
	if _, spent := spentStates[state]; spent {
		return false
	}
	if len(spentStates) >= spentStateMax {
		// Drop the whole set rather than grow unbounded: the provider's single-use `code`
		// still holds, so this fails closed to a fresh flow rather than to a leak.
		spentStates = map[string]int64{}
	}
	spentStates[state] = now + spentStateTTL
	return true
}

// SsoSpentStatesReset is the test-only escape hatch: one process running many cases against
// the same fixed `state` literals has to clear this between them. A real server never calls
// it, which is why it takes no argument and says so in its name.
func SsoSpentStatesReset() { //nolint:unused // the emitted per-test reset calls it
	spentStateMutex.Lock()
	defer spentStateMutex.Unlock()
	spentStates = map[string]int64{}
}

// ── SSRF preflight ───────────────────────────────────────────────────────────
// A reason when the URL's host is a forbidden literal address, "" otherwise. A HOSTNAME
// passes through: the resolve-then-connect-pin step belongs to the HTTP client's socket
// integration, and the classifier both use is the same one.
func urlSsrfViolation(rawURL string) string {
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Host == "" {
		return "URL has no host"
	}
	host := parsed.Hostname()
	if !literalIP(host) {
		return ""
	}
	return IPForbiddenReason(host)
}

var (
	dottedQuad = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$`)
	bareIPv6   = regexp.MustCompile(`^[0-9a-fA-F:]+$`)
)

func literalIP(host string) bool {
	return dottedQuad.MatchString(host) || bareIPv6.MatchString(host)
}

// ── The identity handed to `onIdentity` ──────────────────────────────────────

// SsoIdentity is the verified third-party identity. Opaque on the Tesl side and read through
// the accessors below, so an app cannot reach a claim the rules above have not been applied
// to — the email in particular is present only in the form the provider VERIFIED.
type SsoIdentity struct {
	Key      string
	Issuer   string
	Provider string
	Subject  string
	Tenant   string
	EmailTag string
	Email    string
	Name     string
	Claims   map[string]any
}

// SsoSubjectKeyValue is the opaque identity key a schema keys a user on: a hash of
// (issuer, subject) with no email in it.
type SsoSubjectKeyValue struct {
	Value string
}

func SsoKeyText(key SsoSubjectKeyValue) string { return key.Value }

func SsoSubject(identity SsoIdentity) string { return identity.Key }

// SsoEmail answers the VERIFIED address only. An app cannot obtain an unverified one, so it
// cannot trust one by accident — which is the whole of the nOAuth containment.
func SsoEmail(identity SsoIdentity) Maybe[string] {
	if identity.EmailTag != emailVerified || identity.Email == "" {
		return Nothing[string]()
	}
	return Something(identity.Email)
}

func SsoTenant(identity SsoIdentity) Maybe[string] {
	if identity.Tenant == "" {
		return Nothing[string]()
	}
	return Something(identity.Tenant)
}

// SsoClaim reads one claim by name, as text. A claim that is absent, null or not a scalar is
// Nothing rather than a rendering of whatever it was.
func SsoClaim(identity SsoIdentity, name string) Maybe[string] {
	value, present := identity.Claims[name]
	if !present {
		return Nothing[string]()
	}
	switch typed := value.(type) {
	case string:
		return Something(typed)
	case bool:
		return Something(strconv.FormatBool(typed))
	case json.Number:
		return Something(typed.String())
	case float64:
		return Something(strconv.FormatFloat(typed, 'f', -1, 64))
	}
	return Nothing[string]()
}
