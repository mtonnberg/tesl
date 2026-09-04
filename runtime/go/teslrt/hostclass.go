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
// unique-local, link-local, 0.0.0.0/8, and the IETF-reserved IPv4 blocks that are never
// routed on the public Internet) are refused for every outbound call, judged by the
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
	classReserved
)

// classifyAddress parses a bare address (an IPv6 zone id is tolerated and dropped) and
// answers its class along with whether it denotes an IPv4 address. An IPv6 spelling that
// EMBEDS an IPv4 address (mapped, compatible, NAT64, 6to4) denotes that IPv4 address — the
// fold is the classic bypass, so it happens before classification, never after.
func classifyAddress(raw string) (addressClass, bool) {
	class, v4 := classifyParsed(raw)
	return class, v4 != nil
}

// classifyParsed is classifyAddress plus the IPv4 address the verdict was reached on (nil
// for a native IPv6 address or an unparseable one), so the label functions below name the
// block the FOLDED address falls in rather than re-parsing the spelling.
func classifyParsed(raw string) (addressClass, net.IP) {
	text := strings.ToLower(strings.TrimSpace(raw))
	if zone := strings.IndexByte(text, '%'); zone >= 0 {
		text = text[:zone]
	}
	address := net.ParseIP(text)
	if address == nil {
		return classInvalid, nil
	}
	if v4 := embeddedIPv4(address); v4 != nil {
		return ipv4Class(v4), v4
	}
	if v4 := address.To4(); v4 != nil {
		return ipv4Class(v4), v4
	}
	return ipv6Class(address.To16()), nil
}

// embeddedIPv4 answers the IPv4 address an IPv6 literal embeds, or nil.
//
// `net.IP.To4` already folds the IPv4-mapped form (`::ffff:a.b.c.d`). The others reach the
// same IPv4 host through a translator or a tunnel, so a classifier that judged them as IPv6
// (all "public") would let `64:ff9b::a9fe:a9fe` reach the metadata service on any host with
// a NAT64 path:
//
//	::a.b.c.d            the deprecated IPv4-COMPATIBLE form (RFC 4291 §2.5.5.1);
//	64:ff9b::/96         the NAT64 well-known prefix (RFC 6052 §2.1), IPv4 in the last 32 bits;
//	64:ff9b:1::/48       the NAT64 local-use prefix (RFC 8215); translators carve /96s out of
//	                     it, so the last 32 bits are the IPv4 address there too;
//	2002::/16            6to4 (RFC 3056), IPv4 in bits 16..47.
//
// `::` and `::1` are their own addresses and are NOT folded — otherwise the IPv6 loopback
// would be classified through the 0.0.0.0/8 branch.
func embeddedIPv4(address net.IP) net.IP {
	full := address.To16()
	if full == nil || address.To4() != nil {
		return nil
	}
	switch {
	case full[0] == 0x20 && full[1] == 0x02:
		return net.IPv4(full[2], full[3], full[4], full[5]).To4()
	case prefixIs(full, 0x00, 0x64, 0xff, 0x9b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00),
		prefixIs(full, 0x00, 0x64, 0xff, 0x9b, 0x00, 0x01):
		return net.IPv4(full[12], full[13], full[14], full[15]).To4()
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

func prefixIs(full net.IP, prefix ...byte) bool {
	if len(full) < len(prefix) {
		return false
	}
	for index, octet := range prefix {
		if full[index] != octet {
			return false
		}
	}
	return true
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
	case reservedIPv4Label(v4) != "":
		// The IETF special-purpose blocks that are never routed publicly (RFC 6890). A name
		// resolving into one is either misconfiguration or a probe for what answers there
		// locally — 192.0.0.0/24 in particular is the IPv4 Service Continuity prefix some
		// CLAT/DS-Lite hosts bind on-box.
		return classReserved
	default:
		return classPublic
	}
}

// reservedIPv4Label names the IETF-reserved block an address falls in, or "" for none.
func reservedIPv4Label(v4 net.IP) string {
	if len(v4) < 4 {
		// classReserved is only ever paired with a folded IPv4, but the analyser cannot see
		// that pairing across the call, and a nil here must be "no label", not a panic.
		return ""
	}
	first, second, third := v4[0], v4[1], v4[2]
	switch {
	case first == 192 && second == 0 && third == 0:
		return "reserved 192.0.0.0/24 (IETF protocol assignments)"
	case first == 192 && second == 0 && third == 2:
		return "documentation 192.0.2.0/24 (TEST-NET-1)"
	case first == 198 && (second == 18 || second == 19):
		return "benchmarking 198.18.0.0/15"
	case first == 198 && second == 51 && third == 100:
		return "documentation 198.51.100.0/24 (TEST-NET-2)"
	case first == 203 && second == 0 && third == 113:
		return "documentation 203.0.113.0/24 (TEST-NET-3)"
	default:
		return ""
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
	case prefixIs(full, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00):
		return classReserved // 100::/64 discard-only (RFC 6666)
	case prefixIs(full, 0x20, 0x01, 0x0d, 0xb8):
		return classReserved // 2001:db8::/32 documentation (RFC 3849)
	default:
		return classPublic
	}
}

// IPForbiddenReason names the range that makes an address unsafe to dial, or "" when the
// address is public and routable. The wording matches the Racket runtime's, so a refusal
// reads the same on both backends.
func IPForbiddenReason(address string) string {
	class, v4 := classifyParsed(address)
	isIPv4 := v4 != nil
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
			return rfc1918Label(v4)
		}
		return "IPv6 unique-local fc00::/7"
	case classCGNAT:
		return "CGNAT 100.64.0.0/10"
	case classMulticast:
		if isIPv4 {
			return "multicast/reserved >= 224.0.0.0"
		}
		return "IPv6 multicast ff00::/8"
	case classReserved:
		if isIPv4 {
			if label := reservedIPv4Label(v4); label != "" {
				return label
			}
		} else {
			switch {
			case prefixIs(net.ParseIP(address).To16(), 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00):
				return "discard-only 100::/64"
			case prefixIs(net.ParseIP(address).To16(), 0x20, 0x01, 0x0d, 0xb8):
				return "documentation 2001:db8::/32"
			}
		}
		return "unrecognized address form (fail-closed)"
	case classInvalid:
		return "unrecognized address form (fail-closed)"
	}
	// Unreachable: every class is answered above. A class added later lands here, and refusing
	// is the only safe answer for a range whose policy nobody has decided yet.
	return "unrecognized address form (fail-closed)"
}

// rfc1918Label names the specific private block, so the refusal is actionable. It takes the
// FOLDED IPv4 address, so a NAT64 or 6to4 spelling of 10.0.0.1 is labelled as 10.0.0.0/8.
func rfc1918Label(v4 net.IP) string {
	if len(v4) != net.IPv4len {
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
