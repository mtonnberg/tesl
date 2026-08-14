package teslrt

import (
	"crypto/hmac"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

// `Tesl.JWT`: the one blessed session token — HS256, in one fixed cookie, with no options.
//
// The signature is HMAC-SHA256 over `header.payload`, which is `Tesl.Crypto`'s primitive, so a
// token minted by either backend verifies on the other. Verification never PARSES the header:
// it recomputes the MAC over the received bytes verbatim, which is why a foreign token, or one
// minted before `kid` was stamped, verifies exactly the same.
//
// The rules below are the Racket runtime's, and several of them are fail-closed decisions worth
// keeping visible rather than re-deriving:
//
//	a structurally malformed token is a 401, never a trap — it comes off the wire, so
//	`Cookie: session=garbage` must not be a client-triggerable 500;
//	an unreadable `exp` means EXPIRED, not absent — skipping the check would accept such a
//	token forever;
//	a missing `exp` is accepted, because `exp` is OPTIONAL per RFC 7519 and Tesl cannot mint a
//	token without one, so this only admits a foreign token;
//	renewal refuses without a usable `iat`, because an unbounded-age token must not be
//	renewable — that bound is what makes "no server-side revocation" a defensible design.
type JwtToken struct {
	Value string
}

const (
	// The renewable window and the hard stop on a renewed session's total lifetime. The cap is
	// named rather than derived: applying a multiplier to a shorter TTL silently yields a cap
	// nobody chose.
	jwtTTLSeconds         = 3600
	jwtAbsoluteMaxSeconds = 12 * jwtTTLSeconds
	// The only tolerance granted to an `iat` ahead of this machine's clock: enough for ordinary
	// NTP drift between replicas, too small to meaningfully extend a session.
	jwtMaxClockSkewSeconds = 60
)

// The OPTIONAL previous signing key. Verification accepts a token signed by either the current
// key or this one, which is the overlap that lets a leaked key be rotated WITHOUT logging every
// user out; signing and renewal always use the current key, so the slot drains on its own.
var (
	previousSessionKeyMutex sync.RWMutex
	previousSessionKey      *Secret
)

// SetPreviousSessionKey installs (or, with nil, clears) the rotation overlap. Clearing it while
// rotating the current key is the global kill switch.
func SetPreviousSessionKey(key *Secret) {
	previousSessionKeyMutex.Lock()
	defer previousSessionKeyMutex.Unlock()
	previousSessionKey = key
}

func sessionKeys(current Secret) []string {
	previousSessionKeyMutex.RLock()
	defer previousSessionKeyMutex.RUnlock()
	keys := []string{current.Value.Reveal()}
	if previousSessionKey != nil {
		keys = append(keys, previousSessionKey.Value.Reveal())
	}
	return keys
}

func jwtNowSeconds() int64 { return time.Now().Unix() }

func base64URL(raw []byte) string { return base64.RawURLEncoding.EncodeToString(raw) }

// decodeBase64URL accepts the padded spelling too: a token arrives from another implementation,
// and padding is the commonest harmless deviation.
func decodeBase64URL(text string) ([]byte, bool) {
	if raw, err := base64.RawURLEncoding.DecodeString(text); err == nil {
		return raw, true
	}
	raw, err := base64.URLEncoding.DecodeString(text)
	return raw, err == nil
}

// jwtHeader is assembled by string append rather than by marshalling a map, so the field order
// is fixed (alg, typ, kid) and stable. `kid` is DERIVED from the key — a domain-separated,
// truncated digest that is safe to log and is not proof of key possession — so there is no knob
// here either, and no accessor: stamping is the part that is expensive to retrofit.
func jwtHeader(key Secret) string {
	return base64URL([]byte(`{"alg":"HS256","typ":"JWT","kid":"` + KeyFingerprint(key) + `"}`))
}

func jwtSignature(key, signingInput string) []byte {
	return hmacSha256Bytes(key, signingInput)
}

// jwtPayload renders the claims. Keys are sorted so a token is a function of its claims and not
// of map iteration order; `iat` and `exp` are NUMBERS, as RFC 7519 requires, while every claim a
// program supplies is a String.
func jwtPayload(claims Dict[string, string], issuedAt, expiresAt int64) string {
	var builder strings.Builder
	builder.WriteString("{")
	names := make([]string, 0, len(claims.Entries))
	for _, entry := range claims.Entries {
		names = append(names, entry.Key)
	}
	sort.Strings(names)
	for _, name := range names {
		value, _ := DictLookup(claims, name, stringKeyLess).Value()
		encoded, err := json.Marshal(value)
		if err != nil {
			panic("JWT.sign: a claim value could not be encoded: " + err.Error())
		}
		key, err := json.Marshal(name)
		if err != nil {
			panic("JWT.sign: a claim name could not be encoded: " + err.Error())
		}
		builder.Write(key)
		builder.WriteString(":")
		builder.Write(encoded)
		builder.WriteString(",")
	}
	fmt.Fprintf(&builder, `"iat":%d,"exp":%d}`, issuedAt, expiresAt)
	return base64URL([]byte(builder.String()))
}

// JwtSign is `JWT.sign`. It stamps BOTH `iat` and `exp` itself: `exp` because a caller who can
// choose an expiry can choose ten years, and `iat` because renewal reads it to bound the total
// lifetime of a session.
func JwtSign(claims Dict[string, string], key Secret) JwtToken {
	for _, reserved := range []string{"exp", "iat"} {
		if _, present := DictLookup(claims, reserved, stringKeyLess).Value(); present {
			panic(fmt.Sprintf(
				"JWT.sign: %s is not yours to set: JWT.sign stamps it itself, and there is no "+
					"parameter for it. Remove %s from the claims. If you need a credential that "+
					"outlives a session, a JWT is the wrong tool: use `Crypto.randomToken` and "+
					"store only its `Crypto.fingerprint`, which you can revoke.", reserved, reserved))
		}
	}
	now := jwtNowSeconds()
	return signClaims(claims, key, now, now+jwtTTLSeconds)
}

func signClaims(claims Dict[string, string], key Secret, issuedAt, expiresAt int64) JwtToken {
	signingInput := jwtHeader(key) + "." + jwtPayload(claims, issuedAt, expiresAt)
	return JwtToken{
		Value: signingInput + "." + base64URL(jwtSignature(key.Value.Reveal(), signingInput)),
	}
}

// verifiedClaims is the parsed payload of a token whose signature checked out.
type verifiedClaims struct {
	raw map[string]any
}

// verifyToken is the shared half of `JWT.verify` and `JWT.renew`, so the signature comparison,
// the malformed-token rejections and the expiry rule cannot drift between verifying and
// renewing.
func verifyToken(token JwtToken, key Secret) (verifiedClaims, Check[Dict[string, string]]) {
	parts := strings.Split(token.Value, ".")
	if len(parts) != 3 {
		return verifiedClaims{}, Reject[Dict[string, string]](401, "Invalid JWT format")
	}
	signingInput := parts[0] + "." + parts[1]
	// A signature segment that is not valid base64url falls through to the comparison with an
	// empty tag (which fails) rather than raising out of the handler.
	actual, _ := decodeBase64URL(parts[2])
	matched := false
	for _, candidate := range sessionKeys(key) {
		// Every candidate is compared in constant time; the NUMBER of keys (one or two) is not
		// secret.
		if hmac.Equal(jwtSignature(candidate, signingInput), actual) {
			matched = true
		}
	}
	if !matched {
		return verifiedClaims{}, Reject[Dict[string, string]](401, "Invalid JWT signature")
	}
	payload, ok := decodeBase64URL(parts[1])
	if !ok {
		return verifiedClaims{}, Reject[Dict[string, string]](401, "Malformed JWT payload")
	}
	decoded, err := ParseJSON(payload)
	if err != nil {
		return verifiedClaims{}, Reject[Dict[string, string]](401, "Malformed JWT payload")
	}
	claims, isObject := decoded.(map[string]any)
	if !isObject {
		return verifiedClaims{}, Reject[Dict[string, string]](401, "Malformed JWT payload")
	}
	if jwtExpired(claims) {
		return verifiedClaims{}, Reject[Dict[string, string]](401, "JWT token has expired")
	}
	return verifiedClaims{raw: claims}, Check[Dict[string, string]]{}
}

// jwtExpired reads `exp`. A MISSING claim means no expiry check (it is optional per the RFC and
// Tesl always stamps one, so this only admits a foreign token); an UNREADABLE one means expired,
// because skipping the check on a claim that cannot be read would accept the token forever.
func jwtExpired(claims map[string]any) bool {
	expiry, present := claims["exp"]
	if !present {
		return false
	}
	seconds, ok := jsonSeconds(expiry)
	if !ok {
		return true
	}
	return seconds < jwtNowSeconds()
}

func jsonSeconds(value any) (int64, bool) {
	number, ok := value.(json.Number)
	if !ok {
		return 0, false
	}
	if exact, err := number.Int64(); err == nil {
		return exact, true
	}
	// A non-integral or oversized numeric claim: read it as a float and floor it, so a token
	// written by an implementation that emits `1.7853556e9` is still judged rather than refused.
	if approximate, err := number.Float64(); err == nil {
		return int64(approximate), true
	}
	return 0, false
}

// claimText renders a claim value as a String, which is what `Dict String String` promises. The
// rule is `JWT.decode`'s, applied to verification too: a string is itself, a number or boolean
// is its JSON text, null is "null", and an array or object is its compact JSON text.
//
// A note for authorization: an array claim decodes to JSON TEXT, which IS substring-matchable —
// do not branch on `String.contains` over it.
func claimText(value any) string {
	switch typed := value.(type) {
	case nil:
		return "null"
	case string:
		return typed
	case bool:
		if typed {
			return "true"
		}
		return "false"
	case json.Number:
		return typed.String()
	default:
		encoded, err := json.Marshal(typed)
		if err != nil {
			return fmt.Sprint(typed)
		}
		return string(encoded)
	}
}

func claimsDict(claims map[string]any) Dict[string, string] {
	out := DictEmpty[string, string]()
	for name, value := range claims {
		out = DictInsert(out, name, claimText(value), stringKeyLess)
	}
	return out
}

// JwtVerify is `JWT.verify`: the claims of a token whose signature and expiry check out, or a
// 401. On success the claims carry an `Authentic` fact, which erases — what it buys is that
// "trusted a cookie without verifying it" stops compiling.
func JwtVerify(token JwtToken, key Secret) Check[Dict[string, string]] {
	verified, rejection := verifyToken(token, key)
	if verified.raw == nil {
		return rejection
	}
	return Accept(claimsDict(verified.raw))
}

// JwtDecode is `JWT.decode`: the claims WITHOUT verifying anything. It exists for reading a
// token you have not authenticated (an `iss` to decide which key to check it with, say), and
// its result must never be trusted — which is why it mints no fact.
func JwtDecode(token JwtToken) Dict[string, string] {
	parts := strings.Split(token.Value, ".")
	if len(parts) != 3 {
		panic("JWT.decode: malformed JWT: expected three dot-separated segments")
	}
	payload, ok := decodeBase64URL(parts[1])
	if !ok {
		panic("JWT.decode: malformed JWT payload: not base64url")
	}
	decoded, err := ParseJSON(payload)
	if err != nil {
		panic("JWT.decode: malformed JWT payload: " + err.Error())
	}
	claims, isObject := decoded.(map[string]any)
	if !isObject {
		panic("JWT.decode: malformed JWT payload: the claims must be a JSON object")
	}
	return claimsDict(claims)
}

// JwtRenew is `JWT.renew`: it slides the session window forward, preserving every claim and the
// ORIGINAL `iat`, so an active user is never logged out mid-task while an idle one still expires.
//
// It exists as a function because re-signing by hand is a trap: the verified claims contain
// `exp` and `iat`, `JWT.sign` refuses both, and an author who rebuilds the dict to strip them
// silently drops any claim they forget — downgrading the session on every renewal.
//
// It REFUSES when the token carries no usable `iat` (absent, not an exact non-negative integer,
// or dated in the future beyond the skew allowance), or when the session has lived its absolute
// maximum. Renewal is presented WITH the token, so a captured token can be renewed exactly as a
// legitimate one can; the hard stop is what keeps "a captured token is useful for a bounded
// time" true in a design with no server-side revocation.
func JwtRenew(token JwtToken, key Secret) Check[JwtToken] {
	verified, rejection := verifyToken(token, key)
	if verified.raw == nil {
		return Reject[JwtToken](rejection.Status(), rejection.Message())
	}
	now := jwtNowSeconds()
	issuedAt, usable := jsonSeconds(verified.raw["iat"])
	if !usable || issuedAt < 0 || issuedAt > now+jwtMaxClockSkewSeconds {
		return Reject[JwtToken](401, "Session cannot be renewed")
	}
	if now-issuedAt > jwtAbsoluteMaxSeconds {
		return Reject[JwtToken](401, "Session has reached its maximum lifetime")
	}
	// Every claim travels across except the two this function owns.
	carried := DictEmpty[string, string]()
	for name, value := range verified.raw {
		if name == "exp" || name == "iat" {
			continue
		}
		carried = DictInsert(carried, name, claimText(value), stringKeyLess)
	}
	return Accept(signClaims(carried, key, issuedAt, now+jwtTTLSeconds))
}

// JwtTokenText is the token as it travels — what a cookie writer puts on the wire.
func JwtTokenText(token JwtToken) string { return token.Value }
