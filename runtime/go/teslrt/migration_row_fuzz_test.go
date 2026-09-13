package teslrt

import (
	"bytes"
	"encoding/hex"
	"strings"
	"testing"
)

// The companion embeds canonical bytes as hex. Exercise the binary framing
// directly so mutation reaches its length/count parser instead of spending most
// cases rejecting non-hex input. Framing must preserve arbitrary atom bytes;
// semantic document/identity validation happens at the enclosing reader.
func FuzzRowCanonicalFraming(f *testing.F) {
	for _, seed := range [][]byte{
		nil,
		[]byte("s0:"),
		[]byte("l0:"),
		[]byte("s3:abc"),
		[]byte("l2:s0:s3:abc"),
		[]byte("l2:l1:s1:xl0:"),
		{'s', '3', ':', 0, 0xff, ':'},
		[]byte("s01:x"),
		[]byte("l1:s0:trailing"),
		[]byte("l999999999999999999999999:"),
		[]byte("s999999999999999999999999:"),
		[]byte(strings.Repeat("l1:", 514) + "s0:"),
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		// Keep campaigns bounded independently of the production artifact budget.
		// Deep nesting and overflowing counts are represented by compact seeds.
		if len(raw) > 64*1024 {
			t.Skip()
		}
		node, decoded, err := pgReadRowCanonical(hex.EncodeToString(raw))
		if err != nil {
			return
		}
		if !bytes.Equal(decoded, raw) {
			t.Fatal("accepted canonical bytes changed during decoding")
		}
		if encoded := pgRowEncode(node); encoded != string(raw) {
			t.Fatalf("accepted noncanonical or incomplete framing: input %q, output %q", raw, encoded)
		}
		// The parsed representation must own its atoms; callers may reuse buffers.
		for i := range decoded {
			decoded[i] ^= 0xff
		}
		if pgRowEncode(node) != string(raw) {
			t.Fatal("decoded buffer mutation changed the canonical tree")
		}
	})
}
