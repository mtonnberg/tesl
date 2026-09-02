package teslrt

import (
	"net"
	"os"
	"strconv"
	"strings"
)

// Address-range classification — the decision behind SSRF egress containment.
//
// The dangerous SSRF targets (cloud metadata at 169.254.169.254, RFC1918, CGNAT,
// unique-local, link-local, 0.0.0.0/8) are refused for every outbound call, judged by the
// address actually CONNECTED TO rather than by the hostname: `evil.example.com` can resolve
// to 127.0.0.1 or to the metadata address, so a name check decides nothing.
//
// The range table is deliberately a copy of ONE Racket table
// (`dsl/private/host-classify.rkt`), including the refusal wording, because a `.tesl`
// application asking `Net.isForbiddenHost` and the runtime refusing to dial must agree
// about what "private" means. The counterpart to `Tesl.Net`'s full host normalization —
// the `inet_aton` spellings (`2130706433`, `0x7f.0.0.1`) and DNS-name syntax — is not here:
// this entry point judges an address a resolver already produced, and a spelling that
// cannot be parsed is refused rather than guessed at.
//
// FAIL CLOSED: anything not recognizable as a public, routable address is refused.
type addressClass int

const (
	classInvalid addressClass = iota
	classPublic
	classLoopback
	classUnspecified
	classLinkLocal
	classPrivate
	classCGNAT
	classMulticast
)

// classifyAddress parses a bare address (an IPv6 zone id is tolerated and dropped) and
// answers its class along with whether it denotes an IPv4 address. An IPv4-mapped or
// IPv4-compatible IPv6 spelling denotes the IPv4 address it embeds — that fold is the
// classic bypass, so it happens before classification, never after.
func classifyAddress(raw string) (addressClass, bool) {
	text := strings.ToLower(strings.TrimSpace(raw))
	if zone := strings.IndexByte(text, '%'); zone >= 0 {
		text = text[:zone]
	}
	address := net.ParseIP(text)
	if address == nil {
		return classInvalid, false
	}
	if v4 := embeddedIPv4(address); v4 != nil {
		return ipv4Class(v4), true
	}
	if v4 := address.To4(); v4 != nil {
		return ipv4Class(v4), true
	}
	return ipv6Class(address.To16()), false
}

// embeddedIPv4 answers the IPv4 address an IPv6 literal embeds, or nil.
//
// `net.IP.To4` already folds the IPv4-mapped form (`::ffff:a.b.c.d`). The deprecated
// IPv4-COMPATIBLE form (`::a.b.c.d`) it does not, and that form reaches the same host, so it
// is folded here. `::` and `::1` are their own addresses and are NOT folded — otherwise the
// IPv6 loopback would be classified through the 0.0.0.0/8 branch.
func embeddedIPv4(address net.IP) net.IP {
	full := address.To16()
	if full == nil || address.To4() != nil {
		return nil
	}
	for _, octet := range full[:12] {
		if octet != 0 {
			return nil
		}
	}
	if full[12] == 0 && full[13] == 0 {
		return nil
	}
	return net.IPv4(full[12], full[13], full[14], full[15]).To4()
}

func ipv4Class(v4 net.IP) addressClass {
	first, second := v4[0], v4[1]
	switch {
	case first == 0:
		return classUnspecified // 0.0.0.0/8 "this network"
	case first == 127:
		return classLoopback // 127.0.0.0/8
	case first == 10:
		return classPrivate // 10.0.0.0/8
	case first == 169 && second == 254:
		return classLinkLocal // 169.254.0.0/16 (cloud metadata)
	case first == 172 && second >= 16 && second <= 31:
		return classPrivate // 172.16.0.0/12
	case first == 192 && second == 168:
		return classPrivate // 192.168.0.0/16
	case first == 100 && second >= 64 && second <= 127:
		return classCGNAT // 100.64.0.0/10
	case first >= 224:
		return classMulticast // 224.0.0.0/4 and the reserved space above it
	default:
		return classPublic
	}
}

func ipv6Class(full net.IP) addressClass {
	if full == nil {
		return classInvalid
	}
	group0 := uint16(full[0])<<8 | uint16(full[1])
	switch {
	case full.Equal(net.IPv6unspecified):
		return classUnspecified // ::
	case full.Equal(net.IPv6loopback):
		return classLoopback // ::1
	case group0&0xffc0 == 0xfe80:
		return classLinkLocal // fe80::/10
	case group0&0xfe00 == 0xfc00:
		return classPrivate // fc00::/7 unique-local
	case group0&0xff00 == 0xff00:
		return classMulticast // ff00::/8
	default:
		return classPublic
	}
}

// IPForbiddenReason names the range that makes an address unsafe to dial, or "" when the
// address is public and routable. The wording matches the Racket runtime's, so a refusal
// reads the same on both backends.
func IPForbiddenReason(address string) string {
	class, isIPv4 := classifyAddress(address)
	switch class {
	case classPublic:
		return ""
	case classLoopback:
		if isIPv4 {
			return "loopback 127.0.0.0/8"
		}
		return "IPv6 loopback ::1"
	case classUnspecified:
		if isIPv4 {
			return "0.0.0.0/8 (this network)"
		}
		return "unspecified ::"
	case classLinkLocal:
		if isIPv4 {
			return "link-local 169.254.0.0/16"
		}
		return "IPv6 link-local fe80::/10"
	case classPrivate:
		if isIPv4 {
			return rfc1918Label(address)
		}
		return "IPv6 unique-local fc00::/7"
	case classCGNAT:
		return "CGNAT 100.64.0.0/10"
	case classMulticast:
		if isIPv4 {
			return "multicast/reserved >= 224.0.0.0"
		}
		return "IPv6 multicast ff00::/8"
	case classInvalid:
		return "unrecognized address form (fail-closed)"
	}
	// Unreachable: every class is answered above. A class added later lands here, and refusing
	// is the only safe answer for a range whose policy nobody has decided yet.
	return "unrecognized address form (fail-closed)"
}

// rfc1918Label names the specific private block, so the refusal is actionable.
func rfc1918Label(address string) string {
	parsed := net.ParseIP(strings.TrimSpace(strings.ToLower(address)))
	if parsed == nil {
		return "a private range"
	}
	v4 := embeddedIPv4(parsed)
	if v4 == nil {
		v4 = parsed.To4()
	}
	if v4 == nil {
		return "a private range"
	}
	switch v4[0] {
	case 10:
		return "private 10.0.0.0/8"
	case 172:
		return "private 172.16.0.0/12"
	default:
		return "private 192.168.0.0/16"
	}
}

// HostLoopback reports whether a HOST (not a resolved address) can only be reached from
// this machine. Used solely to bound the two development escapes below; the default secure
// path never consults it.
func HostLoopback(host string) bool {
	lowered := strings.ToLower(strings.TrimSpace(host))
	lowered = strings.TrimSuffix(strings.TrimPrefix(lowered, "["), "]")
	if lowered == "localhost" || strings.HasSuffix(lowered, ".localhost") {
		return true
	}
	class, _ := classifyAddress(lowered)
	return class == classLoopback
}

// SsrfAllowLoopback reports whether loopback egress is permitted: it is the one private
// range local development legitimately dials, so a non-deployed build allows it and a
// deployed build refuses unless TESL_HTTP_ALLOW_LOOPBACK_EGRESS opts back in.
func SsrfAllowLoopback() bool {
	if !envPresent("TESL_DEPLOYED") {
		return true
	}
	return envTruthy("TESL_HTTP_ALLOW_LOOPBACK_EGRESS")
}

// SsrfEgressRefusal is the egress verdict for a resolved peer address: "" to allow.
func SsrfEgressRefusal(peer string) string {
	reason := IPForbiddenReason(peer)
	switch {
	case reason == "":
		return ""
	case HostLoopback(peer) && SsrfAllowLoopback():
		return ""
	default:
		return reason
	}
}

// ── Runtime configuration knobs ───────────────────────────────────────────────
//
// These read the process environment for the RUNTIME's own tuning (deadlines, egress
// policy), which is a different question from Tesl's `env` surface in env.go: there an
// empty variable counts as unset, because a blank deployment value must not look like a
// configured one. Here presence is what a flag means, mirroring Racket's `getenv`.

func envPresent(name string) bool {
	_, present := os.LookupEnv(name)
	return present
}

// envTruthy accepts the same four spellings the Racket runtime does, so a deployment's
// existing value keeps its meaning across backends.
func envTruthy(name string) bool {
	value, present := os.LookupEnv(name)
	if !present {
		return false
	}
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

// envPositiveInt reads a positive-integer env knob, falling back to `fallback` for an
// absent, empty, or unparseable value. Read fresh per call, not at init: a test or an
// operator can retune a deadline without a restart.
func envPositiveInt(name string, fallback int) int {
	value, present := os.LookupEnv(name)
	if !present {
		return fallback
	}
	parsed, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || parsed <= 0 {
		return fallback
	}
	return parsed
}
