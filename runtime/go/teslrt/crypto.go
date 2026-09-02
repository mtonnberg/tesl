package teslrt

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
)

// `Tesl.Crypto`: message authentication, digests and tokens.
//
// Every primitive here is Go's standard library, and each one is the same primitive the Racket
// runtime calls into libsodium for — HMAC-SHA256, SHA-256, SHA-512, the OS CSPRNG — so a value
// produced by one backend verifies on the other. What is NOT here is password storage
// (`hashPassword`/`checkPassword`/`needsRehash`): Racket uses libsodium's Argon2id, Go's
// standard library has no Argon2, and matching it means taking on
// `golang.org/x/crypto/argon2` — a dependency decision, not an implementation detail, since a
// PBKDF2 substitute would produce hashes the Racket side cannot verify. The emitter refuses
// those three by name until that is decided.
//
// The SHAPE of the surface is the security argument, and it is preserved exactly:
//
//	a Signature cannot be compared          — only `CheckSignature` consumes one, and it
//	                                          compares in constant time, so the classic
//	                                          timing-unsafe `==` on a MAC tag is unwritable;
//	a Secret cannot be printed              — it holds a SecretString, which redacts;
//	the transport forms are one-way pairs   — hex/base64 in and out, because a tag is public
//	                                          data that travels in a header.

// Secret is the stdlib's own secret: what `requireSecret` answers. It is a secret NEWTYPE
// like any a program declares, so it prints as "[redacted]", compares in constant time, and
// reaches an outbound header only through `HttpClient.bearer`/`secretHeader`.
type Secret struct {
	Value SecretString
}

// Signature is an opaque MAC tag, held as lowercase hex — the same representation the Racket
// runtime keeps, so a tag crossing between them is the same string.
type Signature struct {
	Value string
}

// RequireSecret is `requireSecret`: the environment value, or a trap. An unset variable is a
// configuration error, so it fails at the read rather than flowing on as an empty secret.
func RequireSecret(name string) Secret {
	value, present := os.LookupEnv(name)
	if !present || value == "" {
		panic(fmt.Sprintf("requireSecret: environment variable %s is not set (or is empty)", name))
	}
	return Secret{Value: MakeSecret(value)}
}

func hmacSha256Bytes(key, data string) []byte {
	mac := hmac.New(sha256.New, []byte(key))
	_, _ = mac.Write([]byte(data))
	return mac.Sum(nil)
}

// SignWith is `Crypto.signWith key payload`: HMAC-SHA256, configuration first and subject
// last, so `payload |> signWith key` reads correctly.
func SignWith(key Secret, payload string) Signature {
	return Signature{Value: hex.EncodeToString(hmacSha256Bytes(key.Value.Reveal(), payload))}
}

// CheckSignature is `Crypto.checkSignature key sig payload`. The constant-time compare lives
// in here, where it cannot be got wrong — which is why there is no `constantTimeEquals` on the
// surface at all. A malformed tag fails the verification cleanly rather than trapping: it
// arrived from a header, so it is untrusted input, not a program error.
func CheckSignature(key Secret, sig Signature, payload string) Check[string] {
	expected := hmacSha256Bytes(key.Value.Reveal(), payload)
	actual, err := hex.DecodeString(sig.Value)
	if err != nil || !hmac.Equal(expected, actual) {
		return Reject[string](401, "signature does not match")
	}
	return Accept(payload)
}

// SignatureHex is the transport form: a tag you produced, for a header or a body. A MAC tag is
// public data, so this is not an unwrap of a secret — but it DOES make
// `signatureHex a == signatureHex b` expressible, which is the timing-unsafe comparison, and
// that is what the SEC002 diagnostic is for.
func SignatureHex(sig Signature) string { return sig.Value }

// SignatureFromHex is the inbound half: a webhook's tag arrives as hex in a header. Parsing
// untrusted input is safe here — the result can still only be consumed by a verification.
func SignatureFromHex(text string) Signature { return Signature{Value: text} }

// SignatureBase64 is the base64 transport form (Standard Webhooks puts the tag in
// `webhook-signature: v1,<base64>`).
func SignatureBase64(sig Signature) string {
	raw, err := hex.DecodeString(sig.Value)
	if err != nil {
		// The tag came from `signatureFromHex` on untrusted input; re-encoding it is not the
		// place to fail, and an unparseable tag has no base64 form.
		return ""
	}
	return base64.StdEncoding.EncodeToString(raw)
}

// SignatureFromBase64 is the inbound half for a base64 tag. Malformed input yields a tag that
// cannot match any MAC, so the verification fails cleanly — the Racket side's decoder is
// lenient in the same direction (it never turns bad input into an error the program sees).
func SignatureFromBase64(text string) Signature {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(text))
	if err != nil {
		return Signature{}
	}
	return Signature{Value: hex.EncodeToString(raw)}
}

// Fingerprint is `Crypto.fingerprint`: a stable content digest for ETags, cache keys, dedup
// and idempotency keys. NOT for passwords — a fast digest of a password is exactly the mistake
// `hashPassword` exists to prevent.
func Fingerprint(content string) string {
	sum := sha256.Sum256([]byte(content))
	return hex.EncodeToString(sum[:])
}

// keyFingerprintLabel is hashed in so a key fingerprint can never coincide with
// `Fingerprint` of the same string. The trailing NUL is part of the label, as on the Racket
// side, so the two backends produce the same fingerprint for the same key.
var keyFingerprintLabel = []byte("tesl-key-fingerprint-v1\x00")

// KeyFingerprint answers "did I load the right key?" — a short identifier that is safe to log.
// Truncated to 8 bytes so it reads as an identifier rather than as something to compare
// cryptographically; it is NOT proof of key possession.
func KeyFingerprint(key Secret) string {
	sum := sha256.Sum256(append(append([]byte{}, keyFingerprintLabel...),
		[]byte(key.Value.Reveal())...))
	return hex.EncodeToString(sum[:8])
}

// RandomToken is 256 bits from the OS CSPRNG, base64url with no padding (43 characters).
// There is deliberately no length parameter: a caller who can pass 4 will.
func RandomToken() string {
	buffer := make([]byte, 32)
	if _, err := rand.Read(buffer); err != nil {
		panic("Crypto.randomToken: no source of randomness: " + err.Error())
	}
	return base64.RawURLEncoding.EncodeToString(buffer)
}

// The expert aliases: the friendly names above are the ones a newcomer can pick correctly, and
// these exist so someone who already knows what they want can say it.

func Sha256Hex(content string) string { return Fingerprint(content) }

func Sha512Hex(content string) string {
	sum := sha512.Sum512([]byte(content))
	return hex.EncodeToString(sum[:])
}

// ── The authenticating-proxy edge binding (`Tesl.Proxy`) ─────────────────────

// ProxyVerifyBinding compares a request-supplied proxy-binding header against the app's
// configured shared secret, in constant time, and accepts only on a match.
//
// The proof it mints on the Tesl side (`ProxyBound presented`) erases here like every
// other, but what the proof is worth does not: the fact can be obtained ONLY through this
// verification, so a function that demands it is reachable only by a value that was
// actually checked against stored material. That is the whole difference from trusting an
// `X-Auth-User`-style header, which asserts a network topology nothing verifies.
//
// Constant time for the reason Crypto.checkSignature is: a comparison that returns early
// tells a caller how much of the secret it guessed.
func ProxyVerifyBinding(configured Secret, presented string) Check[string] {
	if subtle.ConstantTimeCompare([]byte(configured.Value.Reveal()), []byte(presented)) == 1 {
		return Accept(presented)
	}
	// A 401, not a 403: the request has not proved who it is, which is what an unmatched
	// binding means — and it is the status the Racket runtime answers with.
	return Reject[string](401, "proxy binding does not match")
}
