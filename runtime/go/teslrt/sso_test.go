package teslrt

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The PURE layer is where the account-takeover-class bugs live, so it is the half with the
// tests. Each case below is a rule from `dsl/sso.rkt` stated as an assertion.

func TestPkceChallengeIsS256OfTheVerifier(t *testing.T) {
	// RFC 7636 Appendix B's worked example.
	verifier := "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	want := "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
	if got := pkceChallenge(verifier); got != want {
		t.Errorf("challenge: got %s, want %s", got, want)
	}
}

// Naive concatenation lets ("https://a", "x|https://b") collide with ("https://a|x",
// "https://b"). The length prefix is what makes the encoding injective.
func TestSubjectKeyIsInjectiveAcrossIssuers(t *testing.T) {
	left := ssoSubjectKey("https://a", "x|https://b")
	right := ssoSubjectKey("https://a|x", "https://b")
	if left == right {
		t.Error("two different (issuer, subject) pairs produced the same key")
	}
	// Determinism, through a NAMED first result: comparing the two calls inline is a
	// staticcheck finding (SA4000, identical expressions either side of `!=`), which it cannot
	// see past because it does not know the function is pure.
	issuer, subject := "https://a", "x"
	first := ssoSubjectKey(issuer, subject)
	if again := ssoSubjectKey(issuer, subject); again != first {
		t.Error("the same pair produced two keys")
	}
	if strings.Contains(ssoSubjectKey("https://a", "ada@example.com"), "@") {
		t.Error("the key carries the subject in the clear")
	}
}

// "verified" is reachable ONLY with a positive signal AND an address: a provider that emits
// no email_verified can never produce one.
func TestEmailClaimNeedsAPositiveSignal(t *testing.T) {
	cases := []struct {
		email    string
		signal   bool
		wantTag  string
		wantMail string
	}{
		{"", true, emailNone, ""},
		{"   ", true, emailNone, ""},
		{"ada@example.com", true, emailVerified, "ada@example.com"},
		{" ada@example.com ", true, emailVerified, "ada@example.com"},
		{"ada@example.com", false, emailUnverified, "ada@example.com"},
	}
	for _, one := range cases {
		tag, mail := emailClaim(one.email, one.signal)
		if tag != one.wantTag || mail != one.wantMail {
			t.Errorf("emailClaim(%q, %v): got (%s, %q), want (%s, %q)",
				one.email, one.signal, tag, mail, one.wantTag, one.wantMail)
		}
	}
}

func TestEmailDomainAllowListRequiresVerification(t *testing.T) {
	allowed := []string{"Example.COM "}
	if !emailDomainAllowed(emailVerified, "ada@example.com", nil) {
		t.Error("an empty allow-list is no restriction")
	}
	if !emailDomainAllowed(emailVerified, "ada@EXAMPLE.com.", allowed) {
		t.Error("the trailing-dot FQDN form should canonicalise to the same domain")
	}
	// Restricting by an address the provider never verified is the takeover in disguise.
	if emailDomainAllowed(emailUnverified, "ada@example.com", allowed) {
		t.Error("an unverified address passed a domain allow-list")
	}
	if emailDomainAllowed(emailNone, "", allowed) {
		t.Error("an absent address passed a domain allow-list")
	}
	if emailDomainAllowed(emailVerified, "ada@other.example", allowed) {
		t.Error("a domain outside the list was allowed")
	}
	// A Cyrillic 'а' is a DIFFERENT domain, and fail-closed is the right answer.
	if emailDomainAllowed(emailVerified, "ada@exаmple.com", allowed) {
		t.Error("a homoglyph domain was allowed")
	}
}

func TestHostedDomainAbsentClaimIsARefusal(t *testing.T) {
	if !hostedDomainAllowed("", nil) {
		t.Error("an empty allow-list is no restriction")
	}
	if hostedDomainAllowed("", []string{"example.com"}) {
		t.Error("an absent hd claim passed a non-empty allow-list")
	}
	if !hostedDomainAllowed("EXAMPLE.com.", []string{"example.com"}) {
		t.Error("hd should be compared canonically")
	}
}

func TestOidcClaimValidation(t *testing.T) {
	base := func() map[string]any {
		return map[string]any{
			"sub": "u-1", "iss": "https://idp.example", "aud": "client-1",
			"nonce": "n-1", "exp": float64(2000), "iat": float64(1000),
		}
	}
	rules := oidcClaimRules{
		issuer: "https://idp.example", clientID: "client-1", nonce: "n-1",
		now: 1500, leeway: 60,
	}
	if reason := validateOidcClaims(base(), rules); reason != "" {
		t.Fatalf("a valid token was refused: %s", reason)
	}
	refusals := []struct {
		name   string
		mutate func(map[string]any)
		want   string
	}{
		{"absent sub", func(c map[string]any) { delete(c, "sub") }, "subject (sub) absent or empty"},
		{"absent iss", func(c map[string]any) { delete(c, "iss") }, "issuer (iss) absent"},
		{"wrong iss", func(c map[string]any) { c["iss"] = "https://evil.example" },
			"iss does not match the configured issuer"},
		{"wrong aud", func(c map[string]any) { c["aud"] = "client-2" },
			"aud does not contain the client id"},
		{"azp mismatch", func(c map[string]any) { c["azp"] = "client-2" },
			"azp present and not the client id"},
		{"nonce mismatch", func(c map[string]any) { c["nonce"] = "n-2" },
			"nonce absent or mismatched"},
		{"expired", func(c map[string]any) { c["exp"] = float64(1000) },
			"token expired or exp absent/non-numeric"},
		{"absent iat", func(c map[string]any) { delete(c, "iat") }, "iat absent or non-numeric"},
		{"future iat", func(c map[string]any) { c["iat"] = float64(9000) },
			"iat is in the future beyond leeway"},
	}
	for _, one := range refusals {
		claims := base()
		one.mutate(claims)
		if got := validateOidcClaims(claims, rules); got != one.want {
			t.Errorf("%s: got %q, want %q", one.name, got, one.want)
		}
	}
	// An `aud` LIST containing the client id is valid; one without it is not.
	claims := base()
	claims["aud"] = []any{"other", "client-1"}
	if reason := validateOidcClaims(claims, rules); reason != "" {
		t.Errorf("an aud list containing the client id was refused: %s", reason)
	}
	// A token issued BEFORE the in-flight login started belongs to another login.
	stale := rules
	stale.flowStart = 1200
	if got := validateOidcClaims(base(), stale); got != "iat predates the in-flight login start" {
		t.Errorf("a stale token was accepted: %q", got)
	}
}

func TestTemplatedIssuerNeedsATenantAllowList(t *testing.T) {
	claims := map[string]any{
		"sub": "u-1", "iss": "https://login.example/tenant-a/v2.0", "aud": "client-1",
		"nonce": "n-1", "exp": float64(2000), "iat": float64(1000), "tid": "tenant-a",
	}
	rules := oidcClaimRules{
		issuer: "https://login.example/{tenantid}/v2.0", clientID: "client-1",
		nonce: "n-1", now: 1500, leeway: 60,
	}
	if got := validateOidcClaims(claims, rules); got != "templated issuer requires a non-empty allowedTenants" {
		t.Errorf("a templated issuer with no allow-list was accepted: %q", got)
	}
	rules.allowedTenants = []string{"tenant-a"}
	if reason := validateOidcClaims(claims, rules); reason != "" {
		t.Errorf("a valid tenant was refused: %s", reason)
	}
	claims["tid"] = "tenant-b"
	if got := validateOidcClaims(claims, rules); got != "tid not in allowedTenants" {
		t.Errorf("a tenant outside the list was accepted: %q", got)
	}
	// The tid is in the list but the issuer does not match its substitution: an attacker
	// controlling one tenant must not be able to present another's issuer.
	claims["tid"] = "tenant-a"
	claims["iss"] = "https://login.example/tenant-b/v2.0"
	if got := validateOidcClaims(claims, rules); got != "iss does not match the tenant-substituted issuer" {
		t.Errorf("a mismatched substituted issuer was accepted: %q", got)
	}
}

func TestAuthorizeUrlEncodesAndRefusesReservedNames(t *testing.T) {
	framework := []Tuple2[string, string]{
		{Tuple2First: "client_id", Tuple2Second: "id 1"},
		{Tuple2First: "state", Tuple2Second: "a&b=c"},
	}
	got := buildAuthorizeURL("https://idp.example/authorize", framework, nil)
	want := "https://idp.example/authorize?client_id=id+1&state=a%26b%3Dc"
	if got != want {
		t.Errorf("authorize url: got %s, want %s", got, want)
	}
	// An authorize URL that already carries a query gets `&`, not a second `?`.
	got = buildAuthorizeURL("https://idp.example/authorize?x=1", framework, nil)
	if !strings.HasPrefix(got, "https://idp.example/authorize?x=1&client_id=") {
		t.Errorf("an existing query was not extended: %s", got)
	}
	defer func() {
		if recover() == nil {
			t.Error("a reserved extra parameter was accepted")
		}
	}()
	buildAuthorizeURL("https://idp.example/authorize", framework,
		[]Tuple2[string, string]{{Tuple2First: "redirect_uri", Tuple2Second: "https://evil.example"}})
}

// The cookie value is CLIENT-WRITABLE, so nothing inside it may be trusted before the MAC
// verifies — and the MAC is under a subkey DERIVED from the session key, never the key that
// signs the session itself.
func TestOauthCookieIsAuthenticated(t *testing.T) {
	key := "session-key-1"
	state := oauthState{Segment: "github", State: "s-1", Nonce: "n-1", Verifier: "v-1", Started: 100}
	sealed := oauthCookieSeal(state, key)
	opened, ok := oauthCookieOpen(sealed, "github", []string{key})
	if !ok || opened != state {
		t.Fatalf("a sealed cookie did not open: %v %v", opened, ok)
	}
	if _, ok := oauthCookieOpen(sealed, "github", []string{"another-key"}); ok {
		t.Error("a cookie opened under the wrong key")
	}
	// A cookie minted at one `sso` clause must not open at another's callback.
	if _, ok := oauthCookieOpen(sealed, "idp", []string{key}); ok {
		t.Error("a cookie opened at the wrong route segment")
	}
	// A key ROTATION must not break an in-flight login: the previous key still opens it.
	if _, ok := oauthCookieOpen(sealed, "github", []string{"new-key", key}); !ok {
		t.Error("the previous key did not open an in-flight cookie")
	}
	// A tampered payload fails the MAC, so its contents are never parsed.
	forged := oauthState{Segment: "github", State: "s-2", Nonce: "n-2", Verifier: "v-2"}
	payload, _ := json.Marshal(forged)
	// The tag half, taken from a slice whose length is CHECKED: indexing the split directly is
	// a nilaway finding, and the check states the cookie's shape rather than assuming it.
	sealedParts := strings.Split(sealed, ".")
	if len(sealedParts) != 2 {
		t.Fatalf("a sealed cookie is payload.tag, got %q", sealed)
	}
	tampered := base64.RawURLEncoding.EncodeToString(payload) + "." + sealedParts[1]
	if _, ok := oauthCookieOpen(tampered, "github", []string{key}); ok {
		t.Error("a tampered cookie opened")
	}
	for _, malformed := range []string{"", "onepart", "a.b.c", "a.!!!"} {
		if _, ok := oauthCookieOpen(malformed, "github", []string{key}); ok {
			t.Errorf("a malformed cookie opened: %q", malformed)
		}
	}
}

// The subkey is domain-separated from the session key: the value that MACs the in-flight
// cookie is never the value that signs the session JWT.
func TestOauthSubkeyIsNotTheSessionKey(t *testing.T) {
	if string(oauthSubkey("k")) == "k" {
		t.Error("the subkey is the raw session key")
	}
	if string(oauthSubkey("k")) == string(oauthSubkey("j")) {
		t.Error("two session keys derived one subkey")
	}
}

func TestStateIsSingleUse(t *testing.T) {
	SsoSpentStatesReset()
	t.Cleanup(SsoSpentStatesReset)
	if !stateSpend("s-1", 100) {
		t.Error("a fresh state was refused")
	}
	if stateSpend("s-1", 100) {
		t.Error("a replayed state was accepted")
	}
	if !stateSpend("s-2", 100) {
		t.Error("a second fresh state was refused")
	}
	// Expiry frees the value again: the set is a replay window, not a permanent ledger.
	if !stateSpend("s-1", 100+spentStateTTL+1) {
		t.Error("an expired state was not released")
	}
}

func TestSsrfPreflightRefusesLiteralPrivateAddresses(t *testing.T) {
	cases := map[string]bool{
		"https://example.com/x":    false,
		"https://127.0.0.1/x":      true,
		"https://10.0.0.1/x":       true,
		"https://169.254.169.254/": true,
		"https://[::1]/x":          true,
		"https://8.8.8.8/x":        false,
	}
	for target, forbidden := range cases {
		violation := urlSsrfViolation(target)
		if (violation != "") != forbidden {
			t.Errorf("%s: violation %q, forbidden %v", target, violation, forbidden)
		}
	}
}

func TestProviderDefaultsAreMinimal(t *testing.T) {
	github := SsoDefaults("GitHub", "id", MakeSecretValue("shh"))
	if github.Kind != "oauth2" || len(github.Scopes) != 1 || github.Scopes[0] != "user:email" {
		t.Errorf("GitHub defaults widened: %v", github.Scopes)
	}
	if github.EmailsURL == "" {
		t.Error("GitHub needs the second call for a verified primary address")
	}
	google := SsoDefaults("Google", "id", MakeSecretValue("shh"))
	if google.Kind != "oidc" || google.Issuer != "https://accounts.google.com" {
		t.Errorf("Google defaults: %v", google)
	}
	if synthesizeIssuer("https://api.github.com/user") != "https://api.github.com" {
		t.Error("the synthesised issuer should be scheme+host only")
	}
}

// MakeSecretValue is the test's own constructor for a Secret; the runtime's own is
// `RequireSecret`, which reads the environment.
func MakeSecretValue(text string) Secret { return Secret{Value: MakeSecret(text)} }

func TestIdentityAccessorsHideAnUnverifiedAddress(t *testing.T) {
	identity := SsoIdentity{
		Subject: "u-1", EmailTag: emailUnverified, Email: "ada@example.com",
		Claims: map[string]any{"name": "Ada", "count": json.Number("3")},
	}
	if _, present := SsoEmail(identity).Value(); present {
		t.Error("an unverified address was handed to the app")
	}
	identity.EmailTag = emailVerified
	if address, present := SsoEmail(identity).Value(); !present || address != "ada@example.com" {
		t.Error("a verified address was withheld")
	}
	if name, present := SsoClaim(identity, "name").Value(); !present || name != "Ada" {
		t.Error("a string claim did not read back")
	}
	if count, present := SsoClaim(identity, "count").Value(); !present || count != "3" {
		t.Error("a numeric claim did not render")
	}
	if _, present := SsoClaim(identity, "absent").Value(); present {
		t.Error("an absent claim answered")
	}
	if _, present := SsoTenant(identity).Value(); present {
		t.Error("an empty tenant answered")
	}
}

// ── The callback against a stubbed provider ──────────────────────────────────

// A plain-OAuth2 connection with both legs stubbed — the shape of a GitHub login without the
// network. The connection has NO nonce (oauth2 has none), so `state` is the only CSRF binding
// the flow has, which is what makes it the right shape for the state tests.
func stubbedOauth2Connection(t *testing.T) SsoConnection {
	t.Helper()
	withStubs(t)
	_ = StubHttp("POST", "https://idp.test/token", FromInt64(200), `{"access_token":"at-1"}`)
	_ = StubHttp("GET", "https://idp.test/userinfo", FromInt64(200), `{"id":424242,"login":"mallory"}`)
	SsoSpentStatesReset()
	t.Cleanup(SsoSpentStatesReset)
	return SsoConnection{
		Kind: "oauth2", TokenURL: "https://idp.test/token", UserinfoURL: "https://idp.test/userinfo",
		SubjectField: "id", ClientID: "cid", ClientSecret: testKey("cs"),
	}
}

// RFC 6749 §10.12: the client MUST verify `state`. It used to be verified only when PRESENT,
// which made the check optional to the attacker — start your own login, capture your `code`,
// send the victim (holding a legitimate cookie from a forced /login navigation) to
// `/callback?code=<yours>` with no `state`, and the victim is signed in as you. For an oauth2
// connection nothing else stands in the way, because there is no nonce.
func TestCallbackWithoutStateIsRefusedBeforeTheTokenLeg(t *testing.T) {
	conn := stubbedOauth2Connection(t)
	const redirectURI = "https://app.test/auth/idp/callback"
	// The VICTIM's cookie: a legitimate in-flight login on this browser.
	_, victimCookie, err := ssoBeginLogin(conn, "idp", redirectURI, "session-key",
		"victim-state", "victim-nonce", "victim-verifier", 1000)
	if err != nil {
		t.Fatalf("begin login: %v", err)
	}
	for _, presented := range []string{"", "attacker-state", "victim-stat", "victim-state "} {
		outcome := ssoHandleCallback(conn, "idp", "attacker-code", victimCookie, redirectURI,
			[]string{"session-key"}, 1001, presented)
		if outcome.OK {
			t.Fatalf("state=%q: the callback signed in subject %q", presented, outcome.Identity.Subject)
		}
		if outcome.Reason != "state mismatch" {
			t.Fatalf("state=%q: reason = %q, want \"state mismatch\"", presented, outcome.Reason)
		}
	}
	// Refused BEFORE the exchange: the attacker's code was never presented to the provider.
	if HttpCalled("POST", "https://idp.test/token") {
		t.Fatal("the token leg ran for a callback whose state did not verify")
	}
	// The matching state, on the same cookie, completes — so the refusals above were the
	// state's and not some other rule's.
	outcome := ssoHandleCallback(conn, "idp", "real-code", victimCookie, redirectURI,
		[]string{"session-key"}, 1001, "victim-state")
	if !outcome.OK || outcome.Identity.Subject != "424242" {
		t.Fatalf("the legitimate callback failed: %q", outcome.Reason)
	}
}

// A 3xx from a provider is a failed leg: the redirect is never followed, so the https and
// SSRF preflight that judged the configured URL cannot be walked around by a Location header
// — and the client_secret_basic Authorization header goes nowhere the configuration did not
// name. `fetch` treats any non-200 as the leg's failure; the transport half (the 302 comes
// back as the response, the target is not requested) is pinned in httpclient_test.go.
func TestSsoLegTreatsARedirectAsAFailedLeg(t *testing.T) {
	withStubs(t)
	_ = StubHttp("GET", "https://idp.test/.well-known/openid-configuration", FromInt64(302), "")
	_, err := getJSON("sso-discovery", "https://idp.test/.well-known/openid-configuration", nil)
	if err == nil || err.Error() != "sso-discovery: non-200 response" {
		t.Fatalf("a redirecting leg answered %v, want the fixed non-200 reason", err)
	}
	_ = StubHttp("POST", "https://idp.test/token", FromInt64(301), `{"access_token":"never"}`)
	if _, err := postJSON("sso-token", "https://idp.test/token", nil, "grant_type=x"); err == nil ||
		err.Error() != "sso-token: non-200 response" {
		t.Fatalf("a redirecting token leg answered %v", err)
	}
}

// The runtime-owned callback route opens the in-flight cookie under [current, previous] —
// the same pair `JWT.verify` uses — so a login that was in flight when `sessionPreviousKey`
// rotation happened still completes. Opening under the current key only failed every such
// login with "invalid or missing login state".
func TestSsoCallbackOpensAnInFlightCookieSealedUnderThePreviousKey(t *testing.T) {
	conn := stubbedOauth2Connection(t)
	current, previous := testKey("rotated-in-key"), testKey("rotated-out-key")
	route := SsoRoute{
		Segment:      "idp",
		Connection:   func() SsoConnection { return conn },
		OnIdentity:   func(identity SsoIdentity) string { return "user:" + identity.Subject },
		SessionKey:   func() Secret { return current },
		PublicOrigin: "https://app.test",
		AfterLogin:   "/home",
	}
	callback := func(state string) *httptest.ResponseRecorder {
		// Sealed under the PREVIOUS key: the login began before the rotation.
		_, cookie, err := ssoBeginLogin(conn, "idp", route.redirectURI(), previous.Value.Reveal(),
			state, "n", "v", 1000)
		if err != nil {
			t.Fatalf("begin login: %v", err)
		}
		request := httptest.NewRequest(http.MethodGet, "/auth/idp/callback?code=c&state="+state, nil)
		request.AddCookie(&http.Cookie{Name: ssoOauthCookieName, Value: cookie})
		recorder := httptest.NewRecorder()
		handleSsoRequest(route, "callback", recorder, request)
		return recorder
	}

	// Without the overlap installed the cookie is foreign, and the flow fails closed.
	if got := callback("state-no-overlap").Code; got != http.StatusUnauthorized {
		t.Fatalf("a cookie under an unknown key completed the login: status %d", got)
	}
	SetPreviousSessionKey(&previous)
	t.Cleanup(func() { SetPreviousSessionKey(nil) })
	recorder := callback("state-with-overlap")
	if recorder.Code != http.StatusSeeOther || recorder.Header().Get("Location") != "/home" {
		t.Fatalf("the in-flight login did not complete after rotation: %d %q",
			recorder.Code, recorder.Header().Get("Location"))
	}
	// And the session it minted is signed with the CURRENT key — the rotation completed.
	sessionCookie := ""
	for _, line := range recorder.Header().Values("Set-Cookie") {
		if strings.HasPrefix(line, sessionCookieName+"=") {
			sessionCookie = strings.SplitN(strings.TrimPrefix(line, sessionCookieName+"="), ";", 2)[0]
		}
	}
	if sessionCookie == "" {
		t.Fatal("no session cookie was written")
	}
	SetPreviousSessionKey(nil)
	if result := JwtVerify(JwtToken{Value: sessionCookie}, current); !result.OK() {
		t.Fatalf("the minted session is not signed by the current key: %s", result.Message())
	}
}
