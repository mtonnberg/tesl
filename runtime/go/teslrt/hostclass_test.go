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
