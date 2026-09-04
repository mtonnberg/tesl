package teslrt

import "testing"

func TestIPForbiddenReasonNamesTheRange(t *testing.T) {
	cases := []struct {
		address string
		reason  string
	}{
		{"8.8.8.8", ""},
		{"2606:4700::1111", ""},
		{"127.0.0.1", "loopback 127.0.0.0/8"},
		{"127.99.1.2", "loopback 127.0.0.0/8"},
		{"::1", "IPv6 loopback ::1"},
		{"0.0.0.0", "0.0.0.0/8 (this network)"},
		{"::", "unspecified ::"},
		{"169.254.169.254", "link-local 169.254.0.0/16"},
		{"fe80::1", "IPv6 link-local fe80::/10"},
		{"10.1.2.3", "private 10.0.0.0/8"},
		{"172.16.0.1", "private 172.16.0.0/12"},
		{"172.31.255.255", "private 172.16.0.0/12"},
		{"192.168.1.1", "private 192.168.0.0/16"},
		{"fc00::1", "IPv6 unique-local fc00::/7"},
		{"fd12:3456::1", "IPv6 unique-local fc00::/7"},
		{"100.64.0.1", "CGNAT 100.64.0.0/10"},
		{"224.0.0.1", "multicast/reserved >= 224.0.0.0"},
		{"ff02::1", "IPv6 multicast ff00::/8"},
		{"100::1", "discard-only 100::/64"},
		{"2001:db8::1", "documentation 2001:db8::/32"},
		// 172.15 and 172.32 are OUTSIDE the /12, and a classifier that tested only the first
		// octet would refuse them.
		{"172.15.0.1", ""},
		{"172.32.0.1", ""},
	}
	for _, testCase := range cases {
		if got := IPForbiddenReason(testCase.address); got != testCase.reason {
			t.Fatalf("IPForbiddenReason(%q) = %q, want %q", testCase.address, got, testCase.reason)
		}
	}
}

func TestIPForbiddenReasonRefusesIPv6SpecialUseBlocksAtEgress(t *testing.T) {
	for _, address := range []string{"100::1", "2001:db8::1"} {
		if got := SsrfEgressRefusal(address); got == "" {
			t.Errorf("SsrfEgressRefusal(%q) allowed a special-use address", address)
		}
	}
}

// The IPv4-mapped and IPv4-compatible IPv6 spellings are the classic bypass: they reach the
// same host as the dotted quad, so they must classify as the dotted quad.
func TestIPForbiddenReasonFoldsEmbeddedIPv4(t *testing.T) {
	cases := map[string]string{
		"::ffff:127.0.0.1":       "loopback 127.0.0.0/8",
		"::ffff:7f00:1":          "loopback 127.0.0.0/8",
		"::ffff:169.254.169.254": "link-local 169.254.0.0/16",
		"::7f00:1":               "loopback 127.0.0.0/8",
		"::ffff:8.8.8.8":         "",
		"fe80::1%eth0":           "IPv6 link-local fe80::/10",
	}
	for address, want := range cases {
		if got := IPForbiddenReason(address); got != want {
			t.Fatalf("IPForbiddenReason(%q) = %q, want %q", address, got, want)
		}
	}
}

// Anything unparseable is REFUSED, not allowed: the natural string-check shape would let an
// unrecognized spelling fall through to the allow path.
func TestIPForbiddenReasonFailsClosed(t *testing.T) {
	for _, address := range []string{"", "not-an-address", "999.999.999.999", "example.com",
		"2130706433", "0x7f.0.0.1"} {
		if got := IPForbiddenReason(address); got != "unrecognized address form (fail-closed)" {
			t.Fatalf("IPForbiddenReason(%q) = %q, want the fail-closed reason", address, got)
		}
	}
}

func TestHostLoopback(t *testing.T) {
	for _, host := range []string{"localhost", "LOCALHOST", "api.localhost", "127.0.0.1",
		"127.1.2.3", "::1", "[::1]", "::ffff:127.0.0.1"} {
		if !HostLoopback(host) {
			t.Fatalf("HostLoopback(%q) = false, want true", host)
		}
	}
	for _, host := range []string{"example.com", "8.8.8.8", "localhost.evil.com", ""} {
		if HostLoopback(host) {
			t.Fatalf("HostLoopback(%q) = true, want false", host)
		}
	}
}

// Loopback is the one private range local development legitimately dials, so it is allowed
// in a non-deployed build and refused in a deployed one unless opted back in.
func TestSsrfEgressRefusalOnLoopbackFollowsTheDeployedFlag(t *testing.T) {
	if got := SsrfEgressRefusal("127.0.0.1"); got != "" {
		t.Fatalf("undeployed loopback egress refused: %q", got)
	}
	t.Setenv("TESL_DEPLOYED", "1")
	if got := SsrfEgressRefusal("127.0.0.1"); got != "loopback 127.0.0.0/8" {
		t.Fatalf("deployed loopback egress = %q, want the loopback refusal", got)
	}
	// Every OTHER private range stays refused in both builds — the flag is about loopback only.
	if got := SsrfEgressRefusal("169.254.169.254"); got != "link-local 169.254.0.0/16" {
		t.Fatalf("deployed metadata egress = %q, want the link-local refusal", got)
	}
	t.Setenv("TESL_HTTP_ALLOW_LOOPBACK_EGRESS", "true")
	if got := SsrfEgressRefusal("127.0.0.1"); got != "" {
		t.Fatalf("opted-in loopback egress refused: %q", got)
	}
	if got := SsrfEgressRefusal("10.0.0.1"); got != "private 10.0.0.0/8" {
		t.Fatalf("opting in to loopback also allowed RFC1918: %q", got)
	}
}

func TestEnvPositiveIntRejectsNonPositiveAndUnparseable(t *testing.T) {
	if got := envPositiveInt("TESL_TEST_KNOB", 42); got != 42 {
		t.Fatalf("absent knob = %d, want the fallback", got)
	}
	for _, value := range []string{"", "0", "-5", "abc", "1.5"} {
		t.Setenv("TESL_TEST_KNOB", value)
		if got := envPositiveInt("TESL_TEST_KNOB", 42); got != 42 {
			t.Fatalf("knob %q = %d, want the fallback", value, got)
		}
	}
	t.Setenv("TESL_TEST_KNOB", " 250 ")
	if got := envPositiveInt("TESL_TEST_KNOB", 42); got != 250 {
		t.Fatalf("knob = %d, want 250", got)
	}
}

func TestEnvTruthyAcceptsTheFourSpellings(t *testing.T) {
	for _, value := range []string{"1", "true", "TRUE", " yes ", "on"} {
		t.Setenv("TESL_TEST_FLAG", value)
		if !envTruthy("TESL_TEST_FLAG") {
			t.Fatalf("envTruthy(%q) = false, want true", value)
		}
	}
	for _, value := range []string{"", "0", "false", "no", "off", "maybe"} {
		t.Setenv("TESL_TEST_FLAG", value)
		if envTruthy("TESL_TEST_FLAG") {
			t.Fatalf("envTruthy(%q) = true, want false", value)
		}
	}
}

// NAT64 and 6to4 spellings reach the IPv4 host they embed, through a translator or a tunnel.
// A classifier that judged them as native IPv6 called them all "public", so on a host with a
// NAT64 path `64:ff9b::a9fe:a9fe` reached the metadata service.
func TestIPForbiddenReasonFoldsNat64And6to4(t *testing.T) {
	cases := map[string]string{
		// NAT64 well-known prefix 64:ff9b::/96 — the IPv4 address is the last 32 bits.
		"64:ff9b::7f00:1":    "loopback 127.0.0.0/8",
		"64:ff9b::127.0.0.1": "loopback 127.0.0.0/8",
		"64:ff9b::a9fe:a9fe": "link-local 169.254.0.0/16",
		"64:ff9b::a00:1":     "private 10.0.0.0/8",
		"64:ff9b::c0a8:101":  "private 192.168.0.0/16",
		"64:ff9b::808:808":   "",
		"64:ff9b::":          "0.0.0.0/8 (this network)",
		// NAT64 local-use prefix 64:ff9b:1::/48 (RFC 8215), same layout.
		"64:ff9b:1::7f00:1":         "loopback 127.0.0.0/8",
		"64:ff9b:1:abcd::a9fe:a9fe": "link-local 169.254.0.0/16",
		"64:ff9b:1::808:808":        "",
		// 6to4 2002::/16 — the IPv4 address is bits 16..47.
		"2002:7f00:1::":     "loopback 127.0.0.0/8",
		"2002:a9fe:a9fe::1": "link-local 169.254.0.0/16",
		"2002:ac10:1::":     "private 172.16.0.0/12",
		"2002:808:808::":    "",
		// Neighbours that are NOT the prefixes stay native IPv6 (public).
		"64:ff9c::7f00:1":   "",
		"64:ff9b:2::7f00:1": "",
		"2003:7f00:1::":     "",
	}
	for address, want := range cases {
		if got := IPForbiddenReason(address); got != want {
			t.Errorf("IPForbiddenReason(%q) = %q, want %q", address, got, want)
		}
	}
}

// The IETF special-purpose IPv4 blocks are never routed on the public Internet, so a name
// resolving into one is misconfiguration or a probe for whatever answers there locally.
func TestIPForbiddenReasonRefusesIETFReservedBlocks(t *testing.T) {
	cases := map[string]string{
		"192.0.0.1":        "reserved 192.0.0.0/24 (IETF protocol assignments)",
		"192.0.0.170":      "reserved 192.0.0.0/24 (IETF protocol assignments)",
		"192.0.2.1":        "documentation 192.0.2.0/24 (TEST-NET-1)",
		"198.18.0.1":       "benchmarking 198.18.0.0/15",
		"198.19.255.255":   "benchmarking 198.18.0.0/15",
		"198.51.100.7":     "documentation 198.51.100.0/24 (TEST-NET-2)",
		"203.0.113.9":      "documentation 203.0.113.0/24 (TEST-NET-3)",
		"::ffff:192.0.2.1": "documentation 192.0.2.0/24 (TEST-NET-1)",
		"64:ff9b::c612:1":  "benchmarking 198.18.0.0/15",
		// The neighbouring /24s and /15s are ordinary public space.
		"192.0.1.1":    "",
		"192.0.3.1":    "",
		"198.17.255.1": "",
		"198.20.0.1":   "",
		"198.51.101.1": "",
		"203.0.112.1":  "",
		"203.0.114.1":  "",
	}
	for address, want := range cases {
		if got := IPForbiddenReason(address); got != want {
			t.Errorf("IPForbiddenReason(%q) = %q, want %q", address, got, want)
		}
	}
	// The egress verdict inherits the refusal — the reserved blocks are not the loopback
	// exception, so they stay refused in a non-deployed build too.
	if got := SsrfEgressRefusal("198.18.0.1"); got != "benchmarking 198.18.0.0/15" {
		t.Errorf("SsrfEgressRefusal(198.18.0.1) = %q", got)
	}
}
