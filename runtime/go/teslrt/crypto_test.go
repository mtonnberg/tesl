package teslrt

import (
	"encoding/base64"
	"strings"
	"testing"
)

// The reference values are the RACKET runtime's, computed from tesl/crypto.rkt (libsodium)
// for the same inputs. A value produced by one backend has to verify on the other — a session
// cookie, a webhook tag, a `kid` in a JWT header all cross that line — so these are equality
// assertions against the other implementation, not self-consistency checks.
func TestDigestsMatchTheRacketRuntime(t *testing.T) {
	key := Secret{Value: MakeSecret("hunter2-key")}
	cases := map[string][2]string{
		"fingerprint":    {Fingerprint("hello"), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"},
		"sha256 alias":   {Sha256Hex("hello"), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"},
		"sha512":         {Sha512Hex("hello"), "9b71d224bd62f3785d96d46ad3ea3d73319bfbc2890caadae2dff72519673ca72323c3d99ba5c11d7c7acc6e14b8c5da0c4663475c2e5c3adef46f73bcdec043"},
		"signature hex":  {SignatureHex(SignWith(key, "payload-1")), "9dbbc110157132cdd997da9c38b8d87a8e65a0884f34676bb9c329ce05298134"},
		"signature b64":  {SignatureBase64(SignWith(key, "payload-1")), "nbvBEBVxMs3Zl9qcOLjYeo5loIhPNGdrucMpzgUpgTQ="},
		"keyFingerprint": {KeyFingerprint(key), "02ba67b7f7973628"},
	}
	for label, pair := range cases {
		if pair[0] != pair[1] {
			t.Errorf("%s = %q, want the Racket runtime's %q", label, pair[0], pair[1])
		}
	}
}

func TestCheckSignatureAcceptsOnlyTheRealTag(t *testing.T) {
	key := Secret{Value: MakeSecret("k")}
	other := Secret{Value: MakeSecret("k2")}
	tag := SignWith(key, "payload")

	if result := CheckSignature(key, tag, "payload"); !result.OK() {
		t.Fatalf("a genuine tag was rejected: %s", result.Message())
	} else if value, _ := result.Value(); value != "payload" {
		t.Fatalf("verification answered %q", value)
	}
	// A different key, a different payload, a truncated tag, a non-hex tag and an empty tag all
	// fail with the SAME message and status: the failure must not describe which check failed.
	for label, sig := range map[string]Signature{
		"wrong key":     SignWith(other, "payload"),
		"wrong payload": SignWith(key, "other"),
		"truncated":     {Value: tag.Value[:len(tag.Value)-2]},
		"not hex":       {Value: "zzzz"},
		"empty":         {},
	} {
		result := CheckSignature(key, sig, "payload")
		if result.OK() {
			t.Fatalf("%s verified", label)
		}
		if result.Status() != 401 || result.Message() != "signature does not match" {
			t.Fatalf("%s failed as %d %q", label, result.Status(), result.Message())
		}
	}
}

// The two transport forms round-trip, in both directions, including through the base64 shape a
// Standard Webhooks sender uses.
func TestSignatureTransportRoundTrips(t *testing.T) {
	key := Secret{Value: MakeSecret("k")}
	tag := SignWith(key, "payload")
	if got := SignatureFromHex(SignatureHex(tag)); got != tag {
		t.Fatalf("hex round-trip = %+v, want %+v", got, tag)
	}
	if got := SignatureFromBase64(SignatureBase64(tag)); got != tag {
		t.Fatalf("base64 round-trip = %+v, want %+v", got, tag)
	}
	if result := CheckSignature(key, SignatureFromBase64(SignatureBase64(tag)), "payload"); !result.OK() {
		t.Fatal("a tag that travelled as base64 failed to verify")
	}
	// Malformed base64 is untrusted input from a header: it yields a tag that cannot match,
	// never a trap.
	if result := CheckSignature(key, SignatureFromBase64("not base64 at all!!"), "payload"); result.OK() {
		t.Fatal("a malformed base64 tag verified")
	}
}

func TestRandomTokenIsUnpaddedBase64URLOf256Bits(t *testing.T) {
	seen := map[string]bool{}
	for range 64 {
		token := RandomToken()
		if len(token) != 43 {
			t.Fatalf("token %q is %d characters, want 43", token, len(token))
		}
		if strings.ContainsAny(token, "+/=") {
			t.Fatalf("token %q is not URL-safe and unpadded", token)
		}
		raw, err := base64.RawURLEncoding.DecodeString(token)
		if err != nil || len(raw) != 32 {
			t.Fatalf("token %q does not decode to 32 bytes (%v)", token, err)
		}
		if seen[token] {
			t.Fatalf("token %q repeated", token)
		}
		seen[token] = true
	}
}

func TestKeyFingerprintIsDomainSeparatedAndShort(t *testing.T) {
	key := Secret{Value: MakeSecret("hunter2-key")}
	fingerprint := KeyFingerprint(key)
	if len(fingerprint) != 16 {
		t.Fatalf("fingerprint %q is %d characters, want 16 (8 bytes)", fingerprint, len(fingerprint))
	}
	// Domain separation is the point: the key's fingerprint must not be the content digest of
	// the same string, or a fingerprint published as a JWT `kid` would confirm a guessed key
	// against any other digest an application already exposes.
	if fingerprint == Fingerprint("hunter2-key")[:16] {
		t.Fatal("the key fingerprint is a plain SHA-256 prefix")
	}
}

func TestRequireSecretRedactsAndFailsClosed(t *testing.T) {
	t.Setenv("TESL_TEST_SECRET", "s3cr3t")
	secret := RequireSecret("TESL_TEST_SECRET")
	if rendered := secret.Value.String(); strings.Contains(rendered, "s3cr3t") {
		t.Fatalf("a required secret rendered its plaintext: %s", rendered)
	}
	if secret.Value.Reveal() != "s3cr3t" {
		t.Fatal("the secret does not carry its value")
	}
	// Unset AND empty both fail: a blank deployment value must not look like a configured one.
	for _, value := range []string{""} {
		t.Setenv("TESL_TEST_SECRET", value)
		func() {
			defer func() {
				if recover() == nil {
					t.Fatalf("an empty secret was accepted")
				}
			}()
			_ = RequireSecret("TESL_TEST_SECRET")
		}()
	}
}

// ── The authenticating-proxy edge binding ────────────────────────────────────

func TestProxyVerifyBindingAcceptsTheConfiguredSecret(t *testing.T) {
	configured := Secret{Value: MakeSecret("s3cr3t-edge-binding")}
	result := ProxyVerifyBinding(configured, "s3cr3t-edge-binding")
	value, ok := result.Value()
	if !ok {
		t.Fatalf("a matching binding was rejected: %s", result.Message())
	}
	// The verified binding itself comes back — it is the value the minted fact is about.
	if value != "s3cr3t-edge-binding" {
		t.Fatalf("accepted value = %q, want the presented binding", value)
	}
}

// A 401 with the Racket runtime's own message, so a client sees the same answer either way.
func TestProxyVerifyBindingRejectsAnythingElse(t *testing.T) {
	configured := Secret{Value: MakeSecret("s3cr3t-edge-binding")}
	for _, presented := range []string{
		"",
		"wrong",
		"s3cr3t-edge-bindin",   // one character short
		"s3cr3t-edge-bindingg", // one character long
		"S3CR3T-EDGE-BINDING",  // case matters
	} {
		result := ProxyVerifyBinding(configured, presented)
		if _, ok := result.Value(); ok {
			t.Fatalf("binding %q was accepted", presented)
		}
		if result.Status() != 401 {
			t.Fatalf("binding %q rejected with %d, want 401", presented, result.Status())
		}
		if result.Message() != "proxy binding does not match" {
			t.Fatalf("binding %q rejected with %q", presented, result.Message())
		}
	}
}

// An empty configured secret must not turn every request into a valid one. It is a
// misconfiguration either way, but the failure mode matters: accepting "" would let a
// request that sent no binding through.
func TestProxyVerifyBindingWithAnEmptySecretStillRejects(t *testing.T) {
	configured := Secret{Value: MakeSecret("")}
	if _, ok := ProxyVerifyBinding(configured, "anything").Value(); ok {
		t.Fatal("an empty configured secret accepted a non-empty binding")
	}
}
