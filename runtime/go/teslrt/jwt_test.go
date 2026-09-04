package teslrt

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"testing"
)

func testKey(text string) Secret { return Secret{Value: MakeSecret(text)} }

func claimsOf(pairs ...string) Dict[string, string] {
	claims := DictEmpty[string, string]()
	for index := 0; index+1 < len(pairs); index += 2 {
		claims = DictInsert(claims, pairs[index], pairs[index+1], stringKeyLess)
	}
	return claims
}

// segmentsOf splits a token and insists on the three parts, so the tests below index a slice
// whose length is checked rather than assumed.
func segmentsOf(t *testing.T, token string) (string, string, string) {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("token %q does not have three segments", token)
	}
	return parts[0], parts[1], parts[2]
}

func lookup(t *testing.T, claims Dict[string, string], name string) string {
	t.Helper()
	value, found := DictLookup(claims, name, stringKeyLess).Value()
	if !found {
		t.Fatalf("claim %q is missing from %v", name, claims)
	}
	return value
}

// A token built exactly as the RACKET runtime builds one (same header field order, same
// base64url, same HMAC-SHA256 over `header.payload`), with a far-future expiry so the assertion
// is not a time bomb. Verifying it here is the cross-backend property: a session cookie written
// by the Racket app is accepted by the Go app.
const racketMintedToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImI1MzAyZDJjYjM2Njg5OGYifQ" +
	".eyJzdWIiOiJ1c2VyLTEiLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6NDEwMjQ0NDgwMH0" +
	".5-5Ay7F5vE1nvZzO5MFH2PiPi0H1CM-RPVl2tvbVdbw"

func TestVerifiesATokenMintedByTheRacketRuntime(t *testing.T) {
	key := testKey("test-session-key")
	result := JwtVerify(JwtToken{Value: racketMintedToken}, key)
	if !result.OK() {
		t.Fatalf("a Racket-minted token did not verify: %s", result.Message())
	}
	claims, _ := result.Value()
	if got := lookup(t, claims, "sub"); got != "user-1" {
		t.Fatalf("sub = %q", got)
	}
	// The numeric claims are rendered as their JSON text, which is what `Dict String String`
	// promises — the same rule `JWT.decode` applies.
	if got := lookup(t, claims, "iat"); got != "1700000000" {
		t.Fatalf("iat = %q", got)
	}
	// And the `kid` in the header is this key's fingerprint, so the two backends agree on which
	// key a token was signed with.
	headerSegment, _, _ := segmentsOf(t, racketMintedToken)
	header, _ := base64.RawURLEncoding.DecodeString(headerSegment)
	if !strings.Contains(string(header), KeyFingerprint(key)) {
		t.Fatalf("header %s does not carry this key's fingerprint %s", header, KeyFingerprint(key))
	}
	// Another key does not verify it.
	if JwtVerify(JwtToken{Value: racketMintedToken}, testKey("other-key")).OK() {
		t.Fatal("a token verified under the wrong key")
	}
}

func TestSignAndVerifyRoundTrip(t *testing.T) {
	key := testKey("k")
	token := JwtSign(claimsOf("sub", "user-1", "role", "admin"), key)
	result := JwtVerify(token, key)
	if !result.OK() {
		t.Fatalf("a freshly signed token did not verify: %s", result.Message())
	}
	claims, _ := result.Value()
	if lookup(t, claims, "sub") != "user-1" || lookup(t, claims, "role") != "admin" {
		t.Fatalf("claims did not survive the round trip: %v", claims)
	}
	// `iat` and `exp` are stamped, in SECONDS, an hour apart.
	issued, expires := lookup(t, claims, "iat"), lookup(t, claims, "exp")
	var issuedAt, expiresAt int64
	if err := json.Unmarshal([]byte(issued), &issuedAt); err != nil {
		t.Fatalf("iat %q is not a number", issued)
	}
	if err := json.Unmarshal([]byte(expires), &expiresAt); err != nil {
		t.Fatalf("exp %q is not a number", expires)
	}
	if expiresAt-issuedAt != 3600 {
		t.Fatalf("exp - iat = %d, want 3600", expiresAt-issuedAt)
	}
}

// Expiry is not the caller's to set: someone who can choose an expiry can choose ten years.
func TestSignRefusesCallerSuppliedExpiryAndIssuedAt(t *testing.T) {
	for _, reserved := range []string{"exp", "iat"} {
		func() {
			defer func() {
				recovered := recover()
				if recovered == nil {
					t.Fatalf("a caller-supplied %s was accepted", reserved)
				}
				if !strings.Contains(fmt.Sprint(recovered), "is not yours to set") {
					t.Fatalf("refusal for %s was %v", reserved, recovered)
				}
			}()
			_ = JwtSign(claimsOf("sub", "u", reserved, "9999999999"), testKey("k"))
		}()
	}
}

// Everything malformed is a 401, never a trap: the token arrives in a cookie, so
// `Cookie: session=garbage` must not be a client-triggerable 500.
func TestMalformedTokensAreRejectedNotTrapped(t *testing.T) {
	key := testKey("k")
	valid := JwtSign(claimsOf("sub", "u"), key).Value
	header, payload, signature := segmentsOf(t, valid)
	for label, token := range map[string]string{
		"empty":            "",
		"garbage":          "garbage",
		"two segments":     header + "." + payload,
		"four segments":    valid + ".extra",
		"bad signature":    header + "." + payload + ".AAAA",
		"non-base64 sig":   header + "." + payload + ".!!!!",
		"tampered payload": header + "." + base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"admin"}`)) + "." + signature,
	} {
		result := JwtVerify(JwtToken{Value: token}, key)
		if result.OK() {
			t.Fatalf("%s verified", label)
		}
		if result.Status() != 401 {
			t.Fatalf("%s failed as %d, want 401", label, result.Status())
		}
	}
}

// An UNREADABLE expiry means expired, not absent: skipping the check on a claim that cannot be
// read would accept the token forever.
func TestExpiryRules(t *testing.T) {
	key := testKey("k")
	mint := func(payload string) JwtToken {
		header := jwtHeader(key)
		body := base64.RawURLEncoding.EncodeToString([]byte(payload))
		signing := header + "." + body
		return JwtToken{Value: signing + "." + base64URL(jwtSignature("k", signing))}
	}
	// No `exp` at all: accepted (the claim is optional per RFC 7519, and Tesl always stamps one,
	// so this only admits a foreign token).
	if result := JwtVerify(mint(`{"sub":"u"}`), key); !result.OK() {
		t.Fatalf("a token without exp was rejected: %s", result.Message())
	}
	for label, payload := range map[string]string{
		"past":       `{"sub":"u","exp":1700000000}`,
		"string exp": `{"sub":"u","exp":"4102444800"}`,
		"null exp":   `{"sub":"u","exp":null}`,
		"array exp":  `{"sub":"u","exp":[4102444800]}`,
	} {
		result := JwtVerify(mint(payload), key)
		if result.OK() {
			t.Fatalf("%s was accepted", label)
		}
		if result.Status() != 401 {
			t.Fatalf("%s failed as %d", label, result.Status())
		}
	}
}

// Renewal preserves every claim and the ORIGINAL iat, and refuses once the session has lived its
// absolute maximum — the bound that keeps "a captured token is useful for a bounded time" true
// in a design with no server-side revocation.
func TestRenewSlidesTheWindowAndRefusesPastTheCap(t *testing.T) {
	key := testKey("k")
	token := JwtSign(claimsOf("sub", "user-1", "role", "admin"), key)
	renewed := JwtRenew(token, key)
	if !renewed.OK() {
		t.Fatalf("a fresh token could not be renewed: %s", renewed.Message())
	}
	next, _ := renewed.Value()
	claims, _ := JwtVerify(next, key).Value()
	if lookup(t, claims, "role") != "admin" {
		t.Fatal("renewal dropped a claim")
	}
	original, _ := JwtVerify(token, key).Value()
	if lookup(t, claims, "iat") != lookup(t, original, "iat") {
		t.Fatal("renewal did not preserve the original iat")
	}

	mint := func(payload string) JwtToken {
		signing := jwtHeader(key) + "." + base64.RawURLEncoding.EncodeToString([]byte(payload))
		return JwtToken{Value: signing + "." + base64URL(jwtSignature("k", signing))}
	}
	now := jwtNowSeconds()
	for label, payload := range map[string]string{
		"no iat":        `{"sub":"u","exp":4102444800}`,
		"iat in future": `{"sub":"u","iat":4102444800,"exp":4102444800}`,
		"past the cap":  `{"sub":"u","iat":1700000000,"exp":4102444800}`,
	} {
		result := JwtRenew(mint(payload), key)
		if result.OK() {
			t.Fatalf("%s was renewed", label)
		}
		if result.Status() != 401 {
			t.Fatalf("%s refused as %d", label, result.Status())
		}
	}
	// Just inside the cap still renews, so the refusal is the cap and not renewal itself.
	inside := mint(`{"sub":"u","iat":` + strconv.FormatInt(now-3600, 10) + `,"exp":4102444800}`)
	if result := JwtRenew(inside, key); !result.OK() {
		t.Fatalf("a token an hour old could not be renewed: %s", result.Message())
	}
}

// Key rotation: a token signed by the PREVIOUS key still verifies, which is what lets a leaked
// key be rotated without logging every user out. Clearing the slot is the kill switch.
func TestPreviousSessionKeyIsAcceptedUntilCleared(t *testing.T) {
	current, previous := testKey("new-key"), testKey("old-key")
	token := JwtSign(claimsOf("sub", "u"), previous)
	if JwtVerify(token, current).OK() {
		t.Fatal("a token signed by an unrelated key verified")
	}
	SetPreviousSessionKey(&previous)
	t.Cleanup(func() { SetPreviousSessionKey(nil) })
	if result := JwtVerify(token, current); !result.OK() {
		t.Fatalf("the rotation overlap did not accept the previous key: %s", result.Message())
	}
	// Renewal re-signs with the CURRENT key, so the slot drains on its own.
	renewed, _ := JwtRenew(token, current).Value()
	SetPreviousSessionKey(nil)
	if result := JwtVerify(renewed, current); !result.OK() {
		t.Fatalf("a renewed token was not signed with the current key: %s", result.Message())
	}
	if JwtVerify(token, current).OK() {
		t.Fatal("clearing the previous key did not stop accepting it")
	}
}

// `JWT.decode` reads without verifying — for choosing WHICH key to check a token with — so it
// mints no fact and must never be trusted.
func TestDecodeReadsWithoutVerifying(t *testing.T) {
	token := JwtSign(claimsOf("sub", "u", "iss", "them"), testKey("k"))
	claims := JwtDecode(token)
	if lookup(t, claims, "iss") != "them" {
		t.Fatal("decode did not read the claims")
	}
	// Even a token whose signature is nonsense decodes, which is the point.
	header, payload, _ := segmentsOf(t, token.Value)
	if got := JwtDecode(JwtToken{Value: header + "." + payload + ".AAAA"}); lookup(t, got, "sub") != "u" {
		t.Fatal("decode refused an unverified token")
	}
}

// ── The `sessionRevoked` hook and the `sessionPolicy` numbers ────────────────
//
// Both were declarations the Go backend accepted and then ignored: a revoked session kept
// renewing, and `ShortSession` shortened only the cookie while the token itself carried the
// standard hour against the standard twelve. Each test below fails if that returns.

func TestRenewalConsultsTheRevocationHook(t *testing.T) {
	t.Cleanup(func() { SetSessionRevokedHook(nil) })
	key := testKey("revocation-key")
	token := JwtSign(claimsOf("sub", "u1"), key)

	// No hook: today's behaviour, a renewal that succeeds.
	if renewed := JwtRenew(token, key); !renewed.OK() {
		t.Fatalf("renewal without a hook was refused: %s", renewed.Message())
	}

	var sawSubject string
	var sawIssuedAt int64
	SetSessionRevokedHook(func(subject string, issuedAt int64) bool {
		sawSubject, sawIssuedAt = subject, issuedAt
		return subject == "u1"
	})
	refused := JwtRenew(token, key)
	if refused.OK() {
		t.Error("a revoked session renewed")
	}
	if refused.Status() != 401 || refused.Message() != "Session cannot be renewed: session revoked" {
		t.Errorf("refusal = %d %q", refused.Status(), refused.Message())
	}
	// The hook is handed the claim and `iat` in SECONDS, which is what the emitted adapter
	// converts from — a hook given milliseconds would compare against the wrong epoch.
	if sawSubject != "u1" {
		t.Errorf("the hook saw subject %q", sawSubject)
	}
	if sawIssuedAt <= 0 || sawIssuedAt > jwtNowSeconds()+1 {
		t.Errorf("the hook saw iat %d, which is not epoch seconds", sawIssuedAt)
	}

	// A session the hook does not name still renews, so the check is per session rather than a
	// global off switch.
	other := JwtSign(claimsOf("sub", "u2"), key)
	if renewed := JwtRenew(other, key); !renewed.OK() {
		t.Errorf("an unrevoked session was refused: %s", renewed.Message())
	}
}

// FAIL CLOSED: a hook that panics — a failing dbRead, a nil map — denies the renewal. Allowing it
// would make an unavailable revocation store indistinguishable from an empty one.
func TestAPanickingRevocationHookDenies(t *testing.T) {
	t.Cleanup(func() { SetSessionRevokedHook(nil) })
	key := testKey("revocation-key")
	token := JwtSign(claimsOf("sub", "u1"), key)
	SetSessionRevokedHook(func(string, int64) bool { panic("db down") })
	if renewed := JwtRenew(token, key); renewed.OK() {
		t.Error("a renewal survived a panicking revocation hook")
	}
}

// `sessionPolicy ShortSession` is ONE choice with TWO numbers: the renewable window and the hard
// stop on a renewed session's total lifetime. Reading only the first leaves a short window
// guarding the same total exposure, which is not what the clause says.
func TestSessionPolicyDrivesTheTokenAndNotOnlyTheCookie(t *testing.T) {
	t.Cleanup(func() { SetSessionPolicy(jwtTTLSeconds) })
	key := testKey("policy-key")

	SetSessionPolicy(SessionPolicyTTL("StandardSession"))
	standard := JwtSign(claimsOf("sub", "u1"), key)
	if lifetime := tokenLifetime(t, standard); lifetime != jwtTTLSeconds {
		t.Errorf("StandardSession token lifetime = %d, want %d", lifetime, jwtTTLSeconds)
	}
	if got := sessionPolicyAbsoluteMaxSeconds(); got != jwtAbsoluteMaxSeconds {
		t.Errorf("StandardSession cap = %d, want %d", got, jwtAbsoluteMaxSeconds)
	}

	SetSessionPolicy(SessionPolicyTTL("ShortSession"))
	short := JwtSign(claimsOf("sub", "u1"), key)
	if lifetime := tokenLifetime(t, short); lifetime != jwtShortTTLSeconds {
		t.Errorf("ShortSession token lifetime = %d, want %d", lifetime, jwtShortTTLSeconds)
	}
	if got := sessionPolicyAbsoluteMaxSeconds(); got != jwtShortAbsoluteMaxSeconds {
		t.Errorf("ShortSession cap = %d, want %d", got, jwtShortAbsoluteMaxSeconds)
	}
}

// tokenLifetime is `exp - iat` out of a signed token's own payload.
func tokenLifetime(t *testing.T, token JwtToken) int64 {
	t.Helper()
	_, payload, _ := segmentsOf(t, token.Value)
	raw, ok := decodeBase64URL(payload)
	if !ok {
		t.Fatalf("payload %q is not base64url", payload)
	}
	var claims struct {
		IssuedAt  int64 `json:"iat"`
		ExpiresAt int64 `json:"exp"`
	}
	if err := json.Unmarshal(raw, &claims); err != nil {
		t.Fatalf("payload does not decode: %v", err)
	}
	return claims.ExpiresAt - claims.IssuedAt
}

// A signature has ONE spelling. Flipping a padding bit in the final base64url character
// changes the token TEXT while a lenient decoder still reads the same 32 bytes — so anything
// keyed on the string (a denylist, a dedup key, an audit trail) could be sidestepped by an
// equivalent spelling. Strict decoding refuses the re-spelling; the canonical token still
// verifies, and so does the padded spelling another implementation may emit.
func TestNonCanonicalSignatureEncodingIsRejected(t *testing.T) {
	key := testKey("canon-key")
	token := JwtSign(claimsOf("sub", "u"), key)
	if result := JwtVerify(token, key); !result.OK() {
		t.Fatalf("the canonical token did not verify: %s", result.Message())
	}
	header, payload, signature := segmentsOf(t, token.Value)
	respelled := JwtToken{Value: header + "." + payload + "." + nonCanonicalLastChar(t, signature)}
	if respelled.Value == token.Value {
		t.Fatal("the re-spelling did not change the token text")
	}
	if result := JwtVerify(respelled, key); result.OK() {
		t.Fatal("a non-canonical signature spelling verified: the token has two texts")
	} else if result.Message() != "Invalid JWT signature" {
		t.Fatalf("rejection = %q, want a signature rejection, not a trap or a format error", result.Message())
	}
	// The padded spelling is a harmless deviation and stays accepted.
	padded := JwtToken{Value: header + "." + payload + "." + signature + strings.Repeat("=", (4-len(signature)%4)%4)}
	if result := JwtVerify(padded, key); !result.OK() {
		t.Fatalf("a padded signature stopped verifying: %s", result.Message())
	}
	// And the payload decoder is strict the same way: `JWT.decode` refuses the re-spelling.
	if raw, ok := decodeBase64URL(nonCanonicalLastChar(t, signature)); ok {
		t.Fatalf("decodeBase64URL accepted a non-canonical spelling: %x", raw)
	}
}
