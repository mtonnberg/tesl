package teslrt

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"strings"
)

// RS256/ES256 JWS signature verification for OIDC ID tokens — VERIFY only, no signing.
//
// A port of `dsl/private/jws-verify.rkt`. That module builds a SubjectPublicKeyInfo DER by
// hand and hands it to libcrypto; Go's standard library takes the key components directly,
// so the DER encoder has no counterpart here. Every REFUSAL does, and the refusals are the
// product: alg:none, an HMAC alg on an ID token (sign-with-the-public-key), an alg outside
// the pinned set, key material NOMINATED by the token header (jwk/jku/x5u/x5c) or a `crit`
// header, a five-segment JWE, an RSA modulus below 2048 bits, and an unknown `kid`.
//
// Fail-closed everywhere: every path that is not a verified signature answers a reason.

// nominatedHeaderKeys let a TOKEN choose the key it is verified against, which is the
// oldest JWS bypass there is. Their mere presence is a refusal — not "ignored".
var nominatedHeaderKeys = []string{"jwk", "jku", "x5u", "x5c", "crit"}

// base64URLBytes decodes a JWS segment or a JWK component. Strict for the same reason
// jwt.go's decoder is: a signature must have ONE spelling, so a token string cannot be
// re-encoded into an equivalent that a text-keyed control does not recognise.
func base64URLBytes(text string) ([]byte, bool) {
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(strings.TrimRight(text, "="))
	if err != nil {
		return nil, false
	}
	return decoded, true
}

// jwkKey is one JSON Web Key, in the shape the fields are read from.
type jwkKey struct {
	Kid string `json:"kid"`
	Kty string `json:"kty"`
	Crv string `json:"crv"`
	N   string `json:"n"`
	E   string `json:"e"`
	X   string `json:"x"`
	Y   string `json:"y"`
}

type jwkSet struct {
	Keys []jwkKey `json:"keys"`
}

// selectJwk picks the key the token names. With no `kid`, a set of exactly ONE key is
// usable and a larger one is not: guessing which of several signed a token is how a
// verifier ends up accepting the wrong signer.
func selectJwk(set jwkSet, kid string) (jwkKey, bool) {
	if kid != "" {
		for _, key := range set.Keys {
			if key.Kid == kid {
				return key, true
			}
		}
		return jwkKey{}, false
	}
	if len(set.Keys) == 1 {
		return set.Keys[0], true
	}
	return jwkKey{}, false
}

// verifyJws answers "" on a valid signature, or a short reason. `pinned` is the set of algs
// the caller will accept, already intersected with what this implements.
func verifyJws(token string, set jwkSet, pinned []string) string {
	parts := strings.Split(token, ".")
	switch {
	case len(parts) == 5:
		return "a JWE (five-segment) token is not accepted"
	case len(parts) != 3:
		return "malformed JWS"
	}
	rawHeader, ok := base64URLBytes(parts[0])
	if !ok {
		return "unparseable JWS header"
	}
	var header map[string]any
	if json.Unmarshal(rawHeader, &header) != nil {
		return "unparseable JWS header"
	}
	for _, nominated := range nominatedHeaderKeys {
		if _, present := header[nominated]; present {
			return "token header nominates its own key (jwk/jku/x5u/x5c/crit) — refused"
		}
	}
	alg, _ := header["alg"].(string)
	kid, _ := header["kid"].(string)
	switch {
	case alg == "":
		return "alg absent"
	case strings.EqualFold(alg, "none"):
		return "alg:none refused"
	case strings.HasPrefix(strings.ToUpper(alg), "HS"):
		return "HMAC alg on an ID token refused"
	}
	permitted := false
	for _, each := range pinned {
		if each == alg {
			permitted = true
		}
	}
	if !permitted {
		return "alg not in the pinned set"
	}
	key, found := selectJwk(set, kid)
	if !found {
		return "no JWKS key matches the token kid"
	}
	if alg == "RS256" && key.Kty != "RSA" {
		return "RS256 requires an RSA key"
	}
	if alg == "ES256" && key.Kty != "EC" {
		return "ES256 requires an EC key"
	}
	signature, ok := base64URLBytes(parts[2])
	if !ok {
		return "malformed signature"
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if alg == "RS256" {
		return verifyRS256(key, digest[:], signature)
	}
	return verifyES256(key, digest[:], signature)
}

func verifyRS256(key jwkKey, digest, signature []byte) string {
	modulus, okN := base64URLBytes(key.N)
	exponent, okE := base64URLBytes(key.E)
	if !okN || !okE || len(modulus) == 0 || len(exponent) == 0 {
		return "unparseable RSA key"
	}
	// The modulus bound is on its SIGNIFICANT bits: a leading zero byte is DER padding, not
	// key material, and counting it would let a 2040-bit key pass as 2048.
	trimmed := modulus
	for len(trimmed) > 1 && trimmed[0] == 0 {
		trimmed = trimmed[1:]
	}
	if len(trimmed)*8 < 2048 {
		return "RSA modulus below 2048 bits"
	}
	public := &rsa.PublicKey{
		N: new(big.Int).SetBytes(modulus),
		E: int(new(big.Int).SetBytes(exponent).Int64()),
	}
	if rsa.VerifyPKCS1v15(public, crypto.SHA256, digest, signature) != nil {
		return "signature verification failed"
	}
	return ""
}

func verifyES256(key jwkKey, digest, signature []byte) string {
	if key.Crv != "P-256" {
		return "unsupported EC curve"
	}
	x, okX := base64URLBytes(key.X)
	y, okY := base64URLBytes(key.Y)
	if !okX || !okY {
		return "unparseable EC key"
	}
	// A JWS ES256 signature is the raw r||s pair, 32 bytes each — not the DER
	// ECDSA-Sig-Value an ASN.1 verifier expects, which is why it is split rather than parsed.
	if len(signature) != 64 {
		return "malformed signature"
	}
	public := &ecdsa.PublicKey{
		Curve: elliptic.P256(),
		X:     new(big.Int).SetBytes(x),
		Y:     new(big.Int).SetBytes(y),
	}
	r := new(big.Int).SetBytes(signature[:32])
	s := new(big.Int).SetBytes(signature[32:])
	if !ecdsa.Verify(public, digest, r, s) {
		return "signature verification failed"
	}
	return ""
}
