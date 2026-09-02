package teslrt

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"testing"
)

// es256Token mints an ID token signed by a fresh P-256 key and the one-key JWKS that verifies
// it — enough for the encoding rules below, which are about the SEGMENTS rather than the
// claims.
func es256Token(t *testing.T) (string, jwkSet) {
	t.Helper()
	private, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("key generation: %v", err)
	}
	encode := base64.RawURLEncoding.EncodeToString
	header := encode([]byte(`{"alg":"ES256","kid":"k1"}`))
	payload := encode([]byte(`{"sub":"u"}`))
	digest := sha256.Sum256([]byte(header + "." + payload))
	r, s, err := ecdsa.Sign(rand.Reader, private, digest[:])
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	// A JWS ES256 signature is r||s at 32 bytes each, fixed width.
	signature := append(r.FillBytes(make([]byte, 32)), s.FillBytes(make([]byte, 32))...)
	// The public point as the uncompressed encoding 0x04||X||Y (65 bytes), read through
	// crypto/ecdh rather than the deprecated big.Int coordinates.
	ecdhKey, err := private.PublicKey.ECDH()
	if err != nil {
		t.Fatalf("public key: %v", err)
	}
	point := ecdhKey.Bytes()
	set := jwkSet{Keys: []jwkKey{{
		Kid: "k1", Kty: "EC", Crv: "P-256",
		X: encode(point[1:33]),
		Y: encode(point[33:65]),
	}}}
	return header + "." + payload + "." + encode(signature), set
}

// nonCanonicalLastChar re-spells a base64url segment so that a lenient decoder reads the SAME
// bytes while the text differs: the final character carries padding bits that a canonical
// encoder leaves zero, and setting one of them changes nothing but the spelling.
func nonCanonicalLastChar(t *testing.T, segment string) string {
	t.Helper()
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	last := segment[len(segment)-1]
	index := 0
	for index < len(alphabet) && alphabet[index] != last {
		index++
	}
	if index == len(alphabet) || index&1 != 0 {
		t.Fatalf("segment %q does not end in a canonical character with a free padding bit", segment)
	}
	respelled := segment[:len(segment)-1] + string(alphabet[index|1])
	// The premise of the test: without Strict, the two spellings decode to the same bytes.
	lenient, err := base64.RawURLEncoding.DecodeString(respelled)
	if err != nil {
		t.Fatalf("the re-spelled segment is not even leniently decodable: %v", err)
	}
	canonical, _ := base64.RawURLEncoding.DecodeString(segment)
	if string(lenient) != string(canonical) {
		t.Fatal("the re-spelled segment decodes to different bytes; the test premise is wrong")
	}
	return respelled
}

// One signature, one spelling. A verifier that accepted the non-canonical re-encoding would
// give every token a second text that a denylist or an audit key does not recognise.
func TestJwsRefusesANonCanonicalSignatureEncoding(t *testing.T) {
	token, set := es256Token(t)
	if reason := verifyJws(token, set, []string{"ES256"}); reason != "" {
		t.Fatalf("the canonical token did not verify: %s", reason)
	}
	dot := len(token) - 1
	for token[dot] != '.' {
		dot--
	}
	respelled := token[:dot+1] + nonCanonicalLastChar(t, token[dot+1:])
	if reason := verifyJws(respelled, set, []string{"ES256"}); reason != "malformed signature" {
		t.Fatalf("the non-canonical spelling answered %q, want \"malformed signature\"", reason)
	}
	if _, ok := base64URLBytes(respelled[dot+1:]); ok {
		t.Fatal("base64URLBytes accepted a segment with a non-zero padding bit")
	}
	// Trailing `=` padding stays tolerated — that is a different, harmless deviation.
	if _, ok := base64URLBytes("AA=="); !ok {
		t.Fatal("padded base64url stopped decoding")
	}
}
