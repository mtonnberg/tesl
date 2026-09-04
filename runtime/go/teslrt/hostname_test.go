package teslrt

import (
	"fmt"
	"net/netip"
	"strings"
	"testing"
)

// A DIFFERENTIAL against `net/netip`, which is the point of this file rather than a substitute
// for it.
//
// `hostname.go` exists because `netip.ParseAddr` accepts the strict dotted quad and nothing else,
// while a resolver — and therefore curl, and therefore an attacker's URL — also accepts
// `2130706433`, `0x7f.0.0.1` and `127.1`, all of which are 127.0.0.1. A classifier built on the
// strict parser answers "public" for the loopback address.
//
// So the two parsers are SUPPOSED to disagree, and a test that demanded agreement would be
// arguing for the bug. What these tests pin is the SHAPE of the disagreement:
//
//   - where netip parses an address, we must agree on the address (no silent difference on the
//     spellings both understand);
//   - where netip refuses and we accept, the value must be an inet_aton spelling of the address
//     we claim — asserted by re-parsing our own normalisation with netip;
//   - a host we call a domain name must not be an address under EITHER parser.

// The inet_aton spellings a resolver accepts and `netip.ParseAddr` does not. Each is the address
// on the right; a classifier that reads them as names is the bypass this module closes.
var inetAtonSpellings = map[string]string{
	"2130706433":   "127.0.0.1", // 32-bit decimal
	"0x7f000001":   "127.0.0.1", // 32-bit hex
	"017700000001": "127.0.0.1", // 32-bit octal
	"127.1":        "127.0.0.1", // two parts: a.d
	"127.0.1":      "127.0.0.1", // three parts: a.b.d
	"0x7f.0.0.1":   "127.0.0.1", // mixed radix
	"0177.0.0.1":   "127.0.0.1", // octal octet
	"192.168.1":    "192.168.0.1",
	"10.1":         "10.0.0.1",
	"3232235777":   "192.168.1.1",
	"0x7f.1":       "127.0.0.1", // mixed radix, two parts
}

// Values that LOOK like an inet_aton spelling and are not: in the two-part form `a.d` the first
// part is one octet, so a 16-bit first part is not an address in any spelling, and five parts is
// not a form at all. What matters is that NO address-class decision is made from them — an
// over-eager parser that read them as addresses would classify by a value no resolver agrees with.
//
// Where they land instead differs by shape, and both answers are safe:
//   - one with a non-digit character in its final label (`0xa9fe.0x0001`) is a NAME, which sends
//     the caller down the resolve-and-pin path that decides the real address;
//   - one that is all digits at the end (`256.1`, `4294967296`) is INVALID, because RFC 3696 says
//     an all-numeric final label is never a name — so it is a malformed literal, not a host.
var notInetAtonSpellings = []string{"0xa9fe.0x0001", "256.1", "4294967296", "0x1.0x2.0x3.0x4.0x5"}

func TestInetAtonSpellingsAreAddressesNotNames(t *testing.T) {
	for spelling, want := range inetAtonSpellings {
		// The premise: netip refuses these. If a Go release starts accepting one, this test says
		// so, and the classifier can stop carrying that case itself.
		if _, err := netip.ParseAddr(spelling); err == nil {
			t.Errorf("netip now parses %q — the differential this file exists for has moved", spelling)
		}
		got, ok := NormalizeHost(spelling)
		if !ok {
			t.Errorf("NormalizeHost(%q) refused an address a resolver accepts", spelling)
			continue
		}
		if got != want {
			t.Errorf("NormalizeHost(%q) = %q, want %q", spelling, got, want)
			continue
		}
		// Our normalisation must be canonical: netip has to agree with the address we claim, or
		// one of us is wrong about what the string means.
		if _, err := netip.ParseAddr(got); err != nil {
			t.Errorf("NormalizeHost(%q) = %q, which netip does not parse: %v", spelling, got, err)
		}
	}
}

func TestNonSpellingsAreRefused(t *testing.T) {
	for _, text := range notInetAtonSpellings {
		// The property that matters: none of these is read as an ADDRESS, so no range table ever
		// sees a value the resolver would disagree with.
		if NetIsIPLiteral(text) {
			t.Errorf("NetIsIPLiteral(%q) = true; it is not an address in any spelling", text)
		}
		// Every member is named rather than left to a `default`: the `exhaustive` linter is what
		// makes "did you handle link-local?" a question the build answers, and this switch is
		// precisely about which classes are acceptable answers.
		switch got := ClassifyHost(text).Tag; got {
		case HostClassDomainName, HostClassInvalid:
			// Both are safe answers — see the note on the corpus above.
		case HostClassLoopback, HostClassPrivate, HostClassLinkLocal, HostClassCgnat,
			HostClassMulticast, HostClassUnspecified, HostClassPublic:
			t.Errorf("ClassifyHost(%q) = %v; want a name or invalid, never an address class",
				text, got)
		}
	}
}

// A loopback address in ANY spelling classifies as loopback. This is the assertion the SSRF guard
// actually depends on: `Net.isLoopback "2130706433"` answering false would be the whole bypass.
func TestLoopbackInEverySpelling(t *testing.T) {
	for spelling, want := range inetAtonSpellings {
		if !strings.HasPrefix(want, "127.") {
			continue
		}
		if !NetIsLoopback(spelling) {
			t.Errorf("NetIsLoopback(%q) = false; it is %s", spelling, want)
		}
	}
}

func TestForbiddenHostRefusesSpecialUseAddresses(t *testing.T) {
	for _, host := range []string{
		"192.0.2.1", "198.18.0.1", "198.51.100.1", "203.0.113.1",
		"[100::1]", "[2001:db8::1]",
	} {
		if !NetIsForbiddenHost(host) {
			t.Errorf("NetIsForbiddenHost(%q) = false for a special-use address", host)
		}
	}
	for _, host := range []string{"8.8.8.8", "[2606:4700:4700::1111]"} {
		if NetIsForbiddenHost(host) {
			t.Errorf("NetIsForbiddenHost(%q) = true for a public address", host)
		}
	}
}

// Where BOTH parsers accept a literal, they must mean the same address — including the IPv6
// spellings where a hand-rolled parser is most likely to drift (`::`, embedded IPv4, leading
// zeros, upper case).
func TestAgreesWithNetipOnCanonicalLiterals(t *testing.T) {
	for _, literal := range []string{
		"0.0.0.0", "127.0.0.1", "255.255.255.255", "10.0.0.1", "169.254.1.1",
		"100.64.0.1", "224.0.0.1", "8.8.8.8", "192.168.0.255",
		"::", "::1", "fe80::1", "fc00::1", "ff02::1", "2001:db8::1",
		"2001:0db8:0000:0000:0000:0000:0000:0001", "2001:DB8::1",
		"::ffff:127.0.0.1", "::ffff:8.8.8.8",
	} {
		parsed, err := netip.ParseAddr(literal)
		if err != nil {
			t.Fatalf("the corpus entry %q is not an address: %v", literal, err)
		}
		host := literal
		if parsed.Is6() {
			// A bare IPv6 literal is only a HOST when bracketed — an unbracketed one collides
			// with the port delimiter, which is why the URL grammar requires the brackets.
			host = "[" + literal + "]"
		}
		normalized, ok := NormalizeHost(host)
		if !ok {
			t.Errorf("NormalizeHost(%q) refused an address netip parses", host)
			continue
		}
		ours, err := netip.ParseAddr(normalized)
		if err != nil {
			t.Errorf("NormalizeHost(%q) = %q, which netip does not parse: %v", host, normalized, err)
			continue
		}
		// Compared as ADDRESSES rather than as text: both sides may spell the same value
		// differently (`::ffff:127.0.0.1` folds to the IPv4 form here, deliberately), and it is
		// the value that the range tables read.
		if ours.Unmap() != parsed.Unmap() {
			t.Errorf("NormalizeHost(%q) = %q (%v), netip reads the literal as %v",
				host, normalized, ours, parsed)
		}
	}
}

// The class of a literal both parsers accept must match what netip's own predicates say. This is
// the range-table half: a wrong boundary in `ipv4OctetsClass` shows up here rather than in a
// program that trusted it.
func TestClassAgreesWithNetipPredicates(t *testing.T) {
	for _, literal := range []string{
		"127.0.0.1", "127.255.255.254", "10.0.0.1", "172.16.0.1", "172.31.255.254",
		"192.168.0.1", "169.254.0.1", "224.0.0.1", "239.255.255.255", "0.0.0.0",
		"8.8.8.8", "172.32.0.1", "11.0.0.1",
		"::1", "fe80::1", "fc00::1", "ff02::1", "::", "2001:db8::1",
	} {
		parsed, err := netip.ParseAddr(literal)
		if err != nil {
			t.Fatalf("the corpus entry %q is not an address: %v", literal, err)
		}
		host := literal
		if parsed.Is6() {
			host = "[" + literal + "]"
		}
		class := ClassifyHost(host).Tag
		switch {
		case parsed.IsLoopback():
			if class != HostClassLoopback {
				t.Errorf("%s: netip says loopback, we say %v", literal, class)
			}
		case parsed.IsUnspecified():
			if class != HostClassUnspecified {
				t.Errorf("%s: netip says unspecified, we say %v", literal, class)
			}
		case parsed.IsMulticast() || parsed.IsInterfaceLocalMulticast():
			if class != HostClassMulticast {
				t.Errorf("%s: netip says multicast, we say %v", literal, class)
			}
		case parsed.IsLinkLocalUnicast():
			if class != HostClassLinkLocal {
				t.Errorf("%s: netip says link-local, we say %v", literal, class)
			}
		case parsed.IsPrivate():
			// CGNAT (100.64/10) is not `IsPrivate` to netip and is its own class here, so only
			// the addresses netip calls private are checked against private.
			if class != HostClassPrivate {
				t.Errorf("%s: netip says private, we say %v", literal, class)
			}
		default:
			if class != HostClassPublic {
				t.Errorf("%s: netip says ordinary unicast, we say %v", literal, class)
			}
		}
	}
}

// ── The three deliberate divergences from netip ──────────────────────────────
//
// Each is a place where netip answers "ordinary unicast" and this classifier answers "internal",
// and in each case `dsl/private/host-classify.rkt` says the same thing in the same words. They are
// pinned here so that "make it agree with netip" cannot be mistaken for a fix.
//
//  1. 100.64.0.0/10 — carrier-grade NAT. netip has no predicate for it.
//  2. 0.0.0.0/8     — "this network". netip's IsUnspecified is only 0.0.0.0 exactly.
//  3. 224.0.0.0/4 + — multicast AND the reserved space above it, under one label. The Racket
//                     comment is literally `224.0.0.0/4 + reserved`; the label is a misnomer for
//                     240/4 and the CLASSIFICATION (not public) is the part that matters.

// 100.64.0.0/10 is carrier-grade NAT: netip has no predicate for it and calls it public, and this
// classifier gives it its own class BECAUSE an SSRF guard has to treat it as internal.
func TestCgnatIsItsOwnClassAgainstNetip(t *testing.T) {
	for _, literal := range []string{"100.64.0.0", "100.100.1.1", "100.127.255.255"} {
		parsed, err := netip.ParseAddr(literal)
		if err != nil {
			t.Fatalf("%q: %v", literal, err)
		}
		if parsed.IsPrivate() {
			t.Errorf("netip now calls %q private — the CGNAT class may be redundant", literal)
		}
		if got := ClassifyHost(literal).Tag; got != HostClassCgnat {
			t.Errorf("ClassifyHost(%q) = %v, want CGNAT", literal, got)
		}
	}
	// The boundaries: 100.63.x and 100.128.x are ordinary public space.
	for _, literal := range []string{"100.63.255.255", "100.128.0.0"} {
		if got := ClassifyHost(literal).Tag; got != HostClassPublic {
			t.Errorf("ClassifyHost(%q) = %v, want public", literal, got)
		}
	}
}

// Divergence 2: the whole of 0.0.0.0/8 is unspecified here, where netip reserves that answer for
// 0.0.0.0 alone. 0.0.0.1 is not routable, so treating the range as internal is the safe reading
// and the one the Racket table takes ("0.0.0.0/8 \"this network\"").
func TestZeroNetworkIsUnspecifiedAcrossTheRange(t *testing.T) {
	for _, literal := range []string{"0.0.0.0", "0.0.0.1", "0.255.255.255", "0.1.2.3"} {
		parsed, err := netip.ParseAddr(literal)
		if err != nil {
			t.Fatalf("%q: %v", literal, err)
		}
		if literal != "0.0.0.0" && parsed.IsUnspecified() {
			t.Errorf("netip now calls %q unspecified — the divergence has moved", literal)
		}
		if got := ClassifyHost(literal).Tag; got != HostClassUnspecified {
			t.Errorf("ClassifyHost(%q) = %v, want unspecified", literal, got)
		}
	}
}

// Divergence 3: everything at or above 224 is one class. 224.0.0.0/4 really is multicast; 240/4 is
// reserved-for-future-use and shares the label. What a caller depends on is that neither is
// public, which is what this asserts — the label is documented as covering both.
func TestMulticastLabelCoversTheReservedSpaceAbove(t *testing.T) {
	for _, literal := range []string{"224.0.0.1", "239.255.255.255", "240.0.0.1", "255.255.255.254"} {
		if got := ClassifyHost(literal).Tag; got != HostClassMulticast {
			t.Errorf("ClassifyHost(%q) = %v, want the multicast-and-reserved class", literal, got)
		}
	}
	// 223.x is the last ordinary unicast space below the boundary.
	if got := ClassifyHost("223.255.255.255").Tag; got != HostClassPublic {
		t.Errorf("ClassifyHost(223.255.255.255) = %v, want public", got)
	}
}

// A host we call a DOMAIN NAME must not be an address under either parser — that is what the class
// means, and a malformed literal read as a name is the fail-open answer (a caller takes "domain
// name" to mean "not an address literal").
func TestDomainNamesAreNotAddressesUnderEitherParser(t *testing.T) {
	for _, host := range []string{
		"example.com", "a.b.c.example.com", "xn--bcher-kva.example", "_dmarc.example.com",
		"host-with-dash.example", "EXAMPLE.COM", "example.com.",
	} {
		normalized, ok := NormalizeHost(host)
		if !ok {
			t.Errorf("NormalizeHost(%q) refused an ordinary name", host)
			continue
		}
		if _, err := netip.ParseAddr(normalized); err == nil {
			t.Errorf("NormalizeHost(%q) = %q, which netip reads as an address", host, normalized)
		}
		if got := ClassifyHost(host).Tag; got != HostClassDomainName {
			t.Errorf("ClassifyHost(%q) = %v, want domain name", host, got)
		}
	}
	// RFC 6761: `localhost` and anything under it is LOOPBACK, not a name, because resolvers are
	// required to map it to the loopback address.
	for _, host := range []string{"localhost", "LOCALHOST", "api.localhost", "localhost."} {
		if got := ClassifyHost(host).Tag; got != HostClassLoopback {
			t.Errorf("ClassifyHost(%q) = %v, want loopback", host, got)
		}
	}
}

// A malformed address literal is INVALID, never a domain name. `999.999.999.999` has an
// all-numeric final label, which RFC 3696 says is not a name.
func TestMalformedLiteralsAreInvalidNotNames(t *testing.T) {
	for _, host := range []string{
		"999.999.999.999", "256.1.1.1", "1.2.3.4.5", "0xzz.1", "4294967296",
		"", ".", "..", "a..b",
		"127.0.0.1:80", "127.0.0.1/8", "ex%41mple.com", "[::1", "::1]",
		"[fe80::1%eth0]", "[127.0.0.1]", "a" + strings.Repeat("b", 63) + ".example",
	} {
		if normalized, ok := NormalizeHost(host); ok {
			if got := ClassifyHost(host).Tag; got == HostClassDomainName {
				t.Errorf("NormalizeHost(%q) = %q classified as a domain name", host, normalized)
			}
		}
		if got := ClassifyHost(host).Tag; got == HostClassPublic {
			t.Errorf("ClassifyHost(%q) = public, which is the fail-open answer", host)
		}
	}
}

// A leading or trailing `-` in a label is accepted by BOTH backends: `host-char?` in
// `dsl/private/host-classify.rkt` admits `-` anywhere, with no RFC 1123 position rule. So
// `-lead.example` normalises and classifies as a domain name on Racket and on Go alike. Pinned
// because it is shared laxity rather than a Go bug: a name that no resolver will resolve is still
// a name, and the SSRF guard's job is to decide addresses, not to validate spelling. If the rule
// is ever tightened, it has to be tightened in both places, and this test is where that shows up.
func TestLabelPositionRuleIsLaxOnBothBackends(t *testing.T) {
	for _, host := range []string{"-lead.example", "trail-.example", "host_.example.com"} {
		normalized, ok := NormalizeHost(host)
		if !ok {
			t.Errorf("NormalizeHost(%q) refused, which would be a divergence from Racket", host)
			continue
		}
		if normalized != strings.ToLower(host) {
			t.Errorf("NormalizeHost(%q) = %q", host, normalized)
		}
		if got := ClassifyHost(host).Tag; got != HostClassDomainName {
			t.Errorf("ClassifyHost(%q) = %v, want domain name", host, got)
		}
	}
}

// NormalizeHost is idempotent on NAMES and on IPv4 in every spelling. It is deliberately NOT on a
// bracketed IPv6 literal: the answer is the host COMPONENT (`::1`), and a bare IPv6 component is
// not a valid host string, so feeding the answer back in is refused. Pinned rather than fixed
// because every caller normalises once, and the alternative — answering `[::1]` — would hand the
// range tables a string they would have to unbracket again.
func TestNormalizeHostIsIdempotent(t *testing.T) {
	corpus := []string{"example.com.", "EXAMPLE.COM", "0x7f.0.0.1", "127.1", "2130706433",
		"[::ffff:127.0.0.1]", "api.LOCALHOST"}
	for _, host := range corpus {
		once, ok := NormalizeHost(host)
		if !ok {
			t.Fatalf("NormalizeHost(%q) refused", host)
		}
		twice, ok := NormalizeHost(once)
		if !ok {
			t.Errorf("NormalizeHost(%q) = %q, which does not normalise", host, once)
			continue
		}
		if once != twice {
			t.Errorf("NormalizeHost is not idempotent on %q: %q then %q", host, once, twice)
		}
	}
	// The documented asymmetry: an IPv6 answer is a component, not a host string.
	for _, host := range []string{"[::1]", "[2001:0DB8::0001]"} {
		once, ok := NormalizeHost(host)
		if !ok {
			t.Fatalf("NormalizeHost(%q) refused", host)
		}
		if _, ok := NormalizeHost(once); ok {
			t.Errorf("NormalizeHost(%q) = %q, which now re-normalises — update the note above",
				host, once)
		}
	}
}

// A generated sweep over every dotted-quad shape the octet boundaries care about, so the range
// tables are checked at their edges rather than at the handful of addresses a human would pick.
func TestOctetBoundarySweepAgainstNetip(t *testing.T) {
	interesting := []int{0, 1, 9, 10, 11, 63, 64, 100, 126, 127, 128, 168, 169, 172, 191, 192,
		223, 224, 239, 240, 254, 255}
	for _, first := range interesting {
		for _, second := range interesting {
			literal := fmt.Sprintf("%d.%d.0.1", first, second)
			parsed, err := netip.ParseAddr(literal)
			if err != nil {
				t.Fatalf("%q: %v", literal, err)
			}
			class := ClassifyHost(literal).Tag
			if class == HostClassInvalid || class == HostClassDomainName {
				t.Errorf("ClassifyHost(%q) = %v for a canonical dotted quad", literal, class)
				continue
			}
			// The one property worth a sweep: netip and this classifier must never disagree about
			// whether an address is reachable-on-the-internet or internal.
			netipInternal := parsed.IsLoopback() || parsed.IsPrivate() ||
				parsed.IsLinkLocalUnicast() || parsed.IsMulticast() || parsed.IsUnspecified()
			oursInternal := class != HostClassPublic
			// The three documented divergences are internal here and unicast to netip, each with
			// its own test above; anything ELSE that diverges is a finding.
			documented := class == HostClassCgnat ||
				class == HostClassUnspecified || class == HostClassMulticast
			if !netipInternal && oursInternal && !documented {
				t.Errorf("%s: netip says ordinary unicast, we say %v", literal, class)
			}
			if netipInternal && !oursInternal {
				t.Errorf("%s: netip says internal, we say public", literal)
			}
		}
	}
}
