package teslrt

import (
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

// The SSO ORCHESTRATION layer: it drives the HTTP client, which is what makes it stubbable
// through the same hook an api-test's `stubHttp` installs.
//
// Every outbound leg is https-only and SSRF-preflighted, and it does not follow redirects:
// `fetch` asks the client for `redirectRefused`, so a 3xx from a provider is the leg's final
// answer and, being non-200, a failed leg. Following it would re-run the https and SSRF
// checks on a URL the provider chose — not the configured one — and would carry the
// client_secret_basic Authorization header along. A provider's own `error`/
// `error_description` text is NEVER reflected — a failure is a fixed reason of our own — and
// the client secret travels in the Authorization header (client_secret_basic), never in a URL.

// ssoOutcome is what the callback produced: an identity, or a fixed reason.
type ssoOutcome struct {
	OK       bool
	Reason   string
	Identity SsoIdentity
}

func ssoFail(reason string) ssoOutcome { return ssoOutcome{Reason: reason} }

// ssoError is the internal failure of one leg. It is converted to a fixed reason at the
// boundary, so a provider's response text cannot reach a caller through it.
type ssoError struct{ reason string }

func (err ssoError) Error() string { return err.reason }

func requireHTTPS(who, target string) error {
	if !strings.HasPrefix(target, "https://") {
		return ssoError{who + ": endpoint must be https"}
	}
	if violation := urlSsrfViolation(target); violation != "" {
		return ssoError{who + ": SSRF-forbidden host: " + violation}
	}
	return nil
}

// getJSON and postJSON are the two outbound shapes. A non-200 is a failure of the leg, not
// a body to inspect: the provider's error text is exactly what must not be reflected.
func getJSON(who, target string, headers []Tuple2[string, string]) (map[string]any, error) {
	body, err := fetch(who, "GET", target, headers, "")
	if err != nil {
		return nil, err
	}
	var parsed map[string]any
	if json.Unmarshal([]byte(body), &parsed) != nil {
		return nil, ssoError{who + ": response is not a JSON object"}
	}
	return parsed, nil
}

func getJSONArray(who, target string, headers []Tuple2[string, string]) ([]any, error) {
	body, err := fetch(who, "GET", target, headers, "")
	if err != nil {
		return nil, err
	}
	var parsed []any
	if json.Unmarshal([]byte(body), &parsed) != nil {
		return nil, ssoError{who + ": response is not a JSON array"}
	}
	return parsed, nil
}

func postJSON(who, target string, headers []Tuple2[string, string], body string) (map[string]any, error) {
	raw, err := fetch(who, "POST", target, headers, body)
	if err != nil {
		return nil, err
	}
	var parsed map[string]any
	if json.Unmarshal([]byte(raw), &parsed) != nil {
		return nil, ssoError{who + ": response is not a JSON object"}
	}
	return parsed, nil
}

func fetch(who, method, target string, headers []Tuple2[string, string], body string) (string, error) {
	if err := requireHTTPS(who, target); err != nil {
		return "", err
	}
	var bodyPointer *string
	if method == "POST" {
		bodyPointer = &body
	}
	// The same client path `HttpClient.get`/`post` take — same header guard, same api-test
	// stubs, same egress and TLS treatment — but with redirects REFUSED rather than followed.
	response := httpRequestPolicy(method, target, headers, bodyPointer, redirectRefused)
	status, _ := response.Status.Int64()
	if status != 200 {
		return "", ssoError{who + ": non-200 response"}
	}
	return response.Body, nil
}

func formEncode(pairs []Tuple2[string, string]) string {
	parts := make([]string, 0, len(pairs))
	for _, pair := range pairs {
		parts = append(parts,
			url.QueryEscape(pair.Tuple2First)+"="+url.QueryEscape(pair.Tuple2Second))
	}
	return strings.Join(parts, "&")
}

// basicAuth is the ONE place the client secret is unwrapped to its raw text: at the HTTP
// boundary, for client_secret_basic. Everywhere else the connection keeps the redacting
// `Secret`, so a log line or a formatted error cannot carry it.
func basicAuth(clientID string, clientSecret Secret) string {
	raw := clientID + ":" + clientSecret.Value.Reveal()
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(raw))
}

// ── OIDC discovery ───────────────────────────────────────────────────────────
// Fetch, validate, and answer the endpoints. The document's own issuer must equal the
// configured one exactly, EXCEPT for the templated multi-tenant case, which is accepted here
// and enforced at claim time by the tid-substitution rule. S256 must be advertised: a
// provider that does not do PKCE is not one this runtime will start a flow with.
var trailingSlashes = regexp.MustCompile(`/+$`)

func oidcDiscover(conn SsoConnection) (SsoConnection, error) {
	base := trailingSlashes.ReplaceAllString(conn.Issuer, "")
	document, err := getJSON("sso-discovery", base+"/.well-known/openid-configuration", nil)
	if err != nil {
		return conn, err
	}
	documentIssuer, _ := document["issuer"].(string)
	if documentIssuer != conn.Issuer && !issuerIsTemplate(documentIssuer) {
		return conn, ssoError{"sso-discovery: discovery issuer does not match the configured issuer"}
	}
	methods, _ := document["code_challenge_methods_supported"].([]any)
	advertisesS256 := false
	for _, each := range methods {
		if text, isText := each.(string); isText && text == "S256" {
			advertisesS256 = true
		}
	}
	if !advertisesS256 {
		return conn, ssoError{"sso-discovery: provider does not advertise PKCE S256"}
	}
	resolved := conn
	resolved.AuthorizeURL, _ = document["authorization_endpoint"].(string)
	resolved.TokenURL, _ = document["token_endpoint"].(string)
	resolved.JwksURL, _ = document["jwks_uri"].(string)
	resolved.EndSessionURL, _ = document["end_session_endpoint"].(string)
	resolved.SigningAlgs = nil
	if algs, ok := document["id_token_signing_alg_values_supported"].([]any); ok {
		for _, each := range algs {
			if text, isText := each.(string); isText {
				resolved.SigningAlgs = append(resolved.SigningAlgs, text)
			}
		}
	}
	if resolved.AuthorizeURL == "" || resolved.TokenURL == "" {
		return conn, ssoError{"sso-discovery: discovery document is missing an endpoint"}
	}
	return resolved, nil
}

func resolveEndpoints(conn SsoConnection) (SsoConnection, error) {
	switch conn.Kind {
	case "oidc":
		return oidcDiscover(conn)
	case "oauth2":
		return conn, nil
	default:
		return conn, ssoError{"sso: unknown connection kind"}
	}
}

// ── Beginning a login ────────────────────────────────────────────────────────
// Resolve the endpoints, build the authorize URL and the sealed `__Host-oauth` cookie. The
// state, nonce and verifier are SUPPLIED by the caller rather than drawn here, which is what
// keeps this deterministic and therefore testable.
func ssoBeginLogin(conn SsoConnection, segment, redirectURI, sessionKey,
	state, nonce, verifier string, now int64) (string, string, error) {
	endpoints, err := resolveEndpoints(conn)
	if err != nil {
		return "", "", err
	}
	scopes := conn.Scopes
	if len(scopes) == 0 {
		scopes = []string{"openid", "email", "profile"}
	}
	framework := []Tuple2[string, string]{
		{Tuple2First: "client_id", Tuple2Second: conn.ClientID},
		{Tuple2First: "redirect_uri", Tuple2Second: redirectURI},
		{Tuple2First: "response_type", Tuple2Second: "code"},
		{Tuple2First: "scope", Tuple2Second: strings.Join(scopes, " ")},
		{Tuple2First: "state", Tuple2Second: state},
		{Tuple2First: "code_challenge", Tuple2Second: pkceChallenge(verifier)},
		{Tuple2First: "code_challenge_method", Tuple2Second: "S256"},
	}
	if conn.Kind == "oidc" {
		framework = append(framework, Tuple2[string, string]{
			Tuple2First: "nonce", Tuple2Second: nonce,
		})
	}
	authorizeURL := buildAuthorizeURL(endpoints.AuthorizeURL, framework, nil)
	cookie := oauthCookieSeal(oauthState{
		Segment: segment, State: state, Nonce: nonce, Verifier: verifier, Started: now,
	}, sessionKey)
	return authorizeURL, cookie, nil
}

// SsoLogoutURL is RP-initiated logout. It RE-DISCOVERS the issuer's endpoints, exactly as
// login and callback do — a connection carries no cached endpoint state, so a rotated
// end_session_endpoint is always honoured. A provider that advertises none answers "": the
// caller decides the fallback rather than being handed a guess.
func SsoLogoutURL(conn SsoConnection, postLogoutRedirectURI string) string {
	endpoints, err := resolveEndpoints(conn)
	if err != nil || endpoints.EndSessionURL == "" {
		return ""
	}
	return buildAuthorizeURL(endpoints.EndSessionURL, []Tuple2[string, string]{
		{Tuple2First: "client_id", Tuple2Second: conn.ClientID},
		{Tuple2First: "post_logout_redirect_uri", Tuple2Second: postLogoutRedirectURI},
	}, nil)
}

// ── Handling the callback ────────────────────────────────────────────────────
func ssoHandleCallback(conn SsoConnection, segment, code, cookie, redirectURI string,
	sessionKeys []string, now int64, presentedState string) ssoOutcome {
	state, opened := oauthCookieOpen(cookie, segment, sessionKeys)
	if !opened {
		return ssoFail("invalid or missing login state")
	}
	// The `state` check is UNCONDITIONAL (RFC 6749 §10.12). It used to be skipped when the
	// parameter was absent, which made it optional to the attacker: start a login in your own
	// browser, capture your `code`, send the victim (who holds a legitimate cookie from a
	// forced `/login` navigation) to `/callback?code=<yours>` with no `state` — and the
	// victim is signed in as YOU (login CSRF / session planting). The sealed cookie and PKCE
	// bind the flow to the victim's browser, not to the victim's `code`; for an `oidc`
	// connection the id_token `nonce` still catches it, but a plain `oauth2` provider that
	// ignores PKCE has nothing else. Constant-time, so a byte-by-byte guess learns nothing.
	if presentedState == "" ||
		subtle.ConstantTimeCompare([]byte(presentedState), []byte(state.State)) != 1 {
		return ssoFail("state mismatch")
	}
	// Single-use `state`, honestly scoped to this process: a second presentation — a user
	// double-clicking reload on the callback, or an attacker replaying a captured one —
	// fails here instead of re-running the token exchange.
	if state.State != "" && !stateSpend(state.State, now) {
		return ssoFail("state already used")
	}
	endpoints, err := resolveEndpoints(conn)
	if err != nil {
		return ssoFail(fixedReason(err))
	}
	tokens, err := postJSON("sso-token", endpoints.TokenURL,
		[]Tuple2[string, string]{
			{Tuple2First: "Authorization", Tuple2Second: basicAuth(conn.ClientID, conn.ClientSecret)},
			{Tuple2First: "Content-Type", Tuple2Second: "application/x-www-form-urlencoded"},
			{Tuple2First: "Accept", Tuple2Second: "application/json"},
		},
		formEncode([]Tuple2[string, string]{
			{Tuple2First: "grant_type", Tuple2Second: "authorization_code"},
			{Tuple2First: "code", Tuple2Second: code},
			{Tuple2First: "redirect_uri", Tuple2Second: redirectURI},
			{Tuple2First: "code_verifier", Tuple2Second: state.Verifier},
		}))
	if err != nil {
		return ssoFail(fixedReason(err))
	}
	switch conn.Kind {
	case "oidc":
		return finishOidc(conn, segment, endpoints, tokens, state.Nonce, state.Started, now)
	case "oauth2":
		return finishOauth2(conn, segment, tokens)
	default:
		return ssoFail("unknown connection kind")
	}
}

// fixedReason keeps a leg's own words and nothing the provider wrote: every ssoError is
// composed here, and anything else becomes a single generic reason.
func fixedReason(err error) string {
	var known ssoError
	if errors.As(err, &known) {
		return known.reason
	}
	return "sso callback failed"
}

// ── The JWKS cache, and rotation refetch ─────────────────────────────────────
// A bounded, TTL'd cache keyed by jwks_uri, so an ordinary login does NOT hit the IdP's JWKS
// endpoint every time (a DoS-amplification vector). A key ROTATION — the token's kid is
// absent from the cached set — triggers exactly ONE refetch, RATE-LIMITED per url, so an
// attacker presenting random kids cannot force unbounded refetches. Bounded in size so it
// cannot become a memory primitive either.
const (
	jwksCacheTTL      = 300
	jwksRefetchWindow = 60
	jwksCacheMax      = 64
)

type jwksEntry struct {
	keys        jwkSet
	fetchedAt   int64
	lastRefetch int64
}

var (
	jwksCacheMutex sync.Mutex
	jwksCache      = map[string]jwksEntry{}
)

// JwksCacheReset is the test-only escape hatch, the same shape as the spent-state reset.
func JwksCacheReset() { //nolint:unused // the emitted per-test reset calls it
	jwksCacheMutex.Lock()
	defer jwksCacheMutex.Unlock()
	jwksCache = map[string]jwksEntry{}
}

func jwksHasKid(set jwkSet, kid string) bool {
	if kid == "" {
		return len(set.Keys) > 0
	}
	for _, key := range set.Keys {
		if key.Kid == kid {
			return true
		}
	}
	return false
}

func jwksFor(target, kid string, now int64) (jwkSet, error) {
	jwksCacheMutex.Lock()
	entry, cached := jwksCache[target]
	jwksCacheMutex.Unlock()
	fresh := cached && now-entry.fetchedAt < jwksCacheTTL
	if fresh && jwksHasKid(entry.keys, kid) {
		return entry.keys, nil
	}
	if cached && fresh && now-entry.lastRefetch < jwksRefetchWindow {
		// An unknown kid inside the rate window: hand back the cached set. The verifier then
		// fails "no key matches kid" fail-closed, with NO extra fetch.
		return entry.keys, nil
	}
	body, err := fetch("sso-jwks", "GET", target, nil, "")
	if err != nil {
		return jwkSet{}, err
	}
	var set jwkSet
	if json.Unmarshal([]byte(body), &set) != nil {
		return jwkSet{}, ssoError{"sso-jwks: response is not a JWKS"}
	}
	jwksCacheMutex.Lock()
	if _, present := jwksCache[target]; !present && len(jwksCache) >= jwksCacheMax {
		jwksCache = map[string]jwksEntry{}
	}
	jwksCache[target] = jwksEntry{keys: set, fetchedAt: now, lastRefetch: now}
	jwksCacheMutex.Unlock()
	return set, nil
}

func idTokenKid(idToken string) string {
	parts := strings.Split(idToken, ".")
	if len(parts) == 0 {
		return ""
	}
	raw, ok := base64URLBytes(parts[0])
	if !ok {
		return ""
	}
	var header map[string]any
	if json.Unmarshal(raw, &header) != nil {
		return ""
	}
	kid, _ := header["kid"].(string)
	return kid
}

// finishOidc is id_token-AUTHORITATIVE: the subject, the email and every claim come from the
// signature-verified token, and the UserInfo endpoint is never called. That is why the
// UserInfo-sub-must-equal-ID-token-sub cross-check has no counterpart here — there is no
// second `sub` that could disagree. If a UserInfo fetch is ever added to this path, it MUST
// assert that equality.
func finishOidc(conn SsoConnection, segment string, endpoints SsoConnection,
	tokens map[string]any, nonce string, flowStart, now int64) ssoOutcome {
	idToken, _ := tokens["id_token"].(string)
	if idToken == "" {
		return ssoFail("no id_token in token response")
	}
	if endpoints.JwksURL == "" {
		return ssoFail("discovery has no jwks_uri")
	}
	// The alg is pinned to discovery ∩ what this implements. A verification failure is
	// TERMINAL: there is no downgrade path.
	pinned := []string{}
	for _, advertised := range endpoints.SigningAlgs {
		if advertised == "RS256" || advertised == "ES256" {
			pinned = append(pinned, advertised)
		}
	}
	if len(pinned) == 0 {
		return ssoFail("no supported id_token signing algorithm advertised")
	}
	set, err := jwksFor(endpoints.JwksURL, idTokenKid(idToken), now)
	if err != nil {
		return ssoFail(fixedReason(err))
	}
	if reason := verifyJws(idToken, set, pinned); reason != "" {
		return ssoFail("id_token signature verification failed")
	}
	parts := strings.Split(idToken, ".")
	if len(parts) < 2 {
		return ssoFail("malformed id_token")
	}
	rawClaims, ok := base64URLBytes(parts[1])
	if !ok {
		return ssoFail("malformed id_token")
	}
	var claims map[string]any
	if json.Unmarshal(rawClaims, &claims) != nil {
		return ssoFail("malformed id_token")
	}
	reason := validateOidcClaims(claims, oidcClaimRules{
		issuer: conn.Issuer, clientID: conn.ClientID, nonce: nonce,
		now: now, leeway: 60, flowStart: flowStart,
		allowedTenants: conn.AllowedTenants,
	})
	if reason != "" {
		return ssoFail(reason)
	}
	issuer, _ := claims["iss"].(string)
	verified, _ := claims["email_verified"].(bool)
	return buildIdentity(conn, segment, issuer, ssoClaimText(claims["sub"]),
		ssoClaimText(claims["email"]), verified, ssoClaimText(claims["name"]),
		ssoClaimText(claims["hd"]), ssoClaimText(claims["tid"]), claims)
}

// verifiedPrimaryEmail makes the documented SECOND call for providers that have one
// (GitHub): a profile email may be public and unverified, and only the primary VERIFIED
// address may be trusted. No such row answers "", so the caller falls back to the
// unverified address rather than fabricating a verified one.
func verifiedPrimaryEmail(conn SsoConnection, accessToken string) string {
	if conn.EmailsURL == "" {
		return ""
	}
	rows, err := getJSONArray("sso-emails", conn.EmailsURL, []Tuple2[string, string]{
		{Tuple2First: "Authorization", Tuple2Second: "Bearer " + accessToken},
		{Tuple2First: "Accept", Tuple2Second: "application/json"},
	})
	if err != nil {
		return ""
	}
	for _, row := range rows {
		fields, isObject := row.(map[string]any)
		if !isObject {
			continue
		}
		primary, _ := fields["primary"].(bool)
		verified, _ := fields["verified"].(bool)
		if primary && verified {
			return ssoClaimText(fields["email"])
		}
	}
	return ""
}

func finishOauth2(conn SsoConnection, segment string, tokens map[string]any) ssoOutcome {
	accessToken, _ := tokens["access_token"].(string)
	if accessToken == "" {
		return ssoFail("no access_token in token response")
	}
	info, err := getJSON("sso-userinfo", conn.UserinfoURL, []Tuple2[string, string]{
		{Tuple2First: "Authorization", Tuple2Second: "Bearer " + accessToken},
		{Tuple2First: "Accept", Tuple2Second: "application/json"},
	})
	if err != nil {
		return ssoFail(fixedReason(err))
	}
	subject := ssoClaimText(info[conn.SubjectField])
	if subject == "" {
		return ssoFail("no subject in userinfo")
	}
	// Prefer the primary verified address from the second call; else the userinfo one,
	// verified only where the provider advertises a verified flag.
	primary := verifiedPrimaryEmail(conn, accessToken)
	email := primary
	verified := primary != ""
	if email == "" && conn.EmailField != "" {
		email = ssoClaimText(info[conn.EmailField])
		if conn.EmailVerifiedField != "" {
			flag, _ := info[conn.EmailVerifiedField].(bool)
			verified = flag
		}
	}
	name := ""
	if conn.NameField != "" {
		name = ssoClaimText(info[conn.NameField])
	}
	return buildIdentity(conn, segment, synthesizeIssuer(conn.UserinfoURL), subject,
		email, verified, name, "", "", info)
}

// ssoClaimText renders a scalar claim as the string an identity carries. A numeric subject
// (GitHub's `id`) is a number in JSON and a string here, which is what makes one subject
// type work for every provider. An absent or non-scalar claim is "", never a rendering of
// whatever it was — `claimText` in jwt.go answers "null" and JSON-encodes an object, which
// is right for a JWT claims dictionary and wrong for an identity field.
func ssoClaimText(value any) string {
	switch typed := value.(type) {
	case string:
		return typed
	case bool:
		return strconv.FormatBool(typed)
	case json.Number:
		return typed.String()
	case float64:
		if typed == float64(int64(typed)) {
			return strconv.FormatInt(int64(typed), 10)
		}
		return strconv.FormatFloat(typed, 'f', -1, 64)
	}
	return ""
}

// buildIdentity applies the runtime-enforced domain restrictions — BEFORE any app code sees
// the identity — and then assembles it.
func buildIdentity(conn SsoConnection, segment, issuer, subject, email string,
	emailVerified bool, name, hostedDomain, tenant string, claims map[string]any) ssoOutcome {
	if strings.TrimSpace(subject) == "" {
		return ssoFail("empty subject")
	}
	tag, address := emailClaim(email, emailVerified)
	if !emailDomainAllowed(tag, address, conn.AllowedEmailDomains) {
		return ssoFail("email domain not allowed")
	}
	if !hostedDomainAllowed(hostedDomain, conn.AllowedHostedDomains) {
		return ssoFail("hosted domain not allowed")
	}
	return ssoOutcome{OK: true, Identity: SsoIdentity{
		Key:      ssoSubjectKey(issuer, subject),
		Issuer:   issuer,
		Provider: segment,
		Subject:  subject,
		Tenant:   tenant,
		EmailTag: tag,
		Email:    address,
		Name:     name,
		Claims:   claims,
	}}
}
