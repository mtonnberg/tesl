package teslrt

import (
	"strconv"
	"strings"
)

// Host classification for `Tesl.Net`, and the host half of `Tesl.Url`.
//
// This is a rule-for-rule port of `dsl/private/host-classify.rkt`, not a wrapper over Go's
// `net.ParseIP`, and the difference is the whole point: `net.ParseIP` accepts the strict
// dotted quad and NOTHING ELSE, while a resolver — and therefore curl, and therefore an
// attacker's URL — also accepts `2130706433`, `0x7f.0.0.1` and `127.1`, all of which are
// 127.0.0.1. A classifier that does not know those spellings answers "public" for the
// loopback address, which is the parser differential this module exists to close.
//
// Every range table below is the one `hostclass.go` already uses for a resolved address, so
// the ranges a `.tesl` program checks and the ranges the HTTP client refuses cannot diverge.

func asciiDigit(c byte) bool { return c >= '0' && c <= '9' }

func hexDigit(c byte) bool {
	return asciiDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// hostChar is what a DNS LABEL may hold. `_` is not legal in a hostname per RFC 1123 but IS
// legal in the names applications look up (`_dmarc.example.com`), and refusing it here would
// make Url.parse reject URLs that resolve. Everything else — `%` included, so a
// percent-encoded host can never smuggle a delimiter past this — is refused.
func hostChar(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || asciiDigit(c) ||
		c == '-' || c == '_'
}

// parseIPv4Strict reads the canonical dotted quad: exactly four decimal octets in [0,255].
// The four octets are an ARRAY rather than a slice, here and throughout: "exactly four" is
// the invariant every caller relies on when it indexes, and an array is where the compiler
// enforces it instead of a length check nobody re-reads.
func parseIPv4Strict(text string) ([4]int, bool) {
	var octets [4]int
	parts := strings.Split(text, ".")
	if len(parts) != 4 {
		return octets, false
	}
	for at, part := range parts {
		if len(part) == 0 || len(part) > 3 {
			return octets, false
		}
		for index := 0; index < len(part); index++ {
			if !asciiDigit(part[index]) {
				return octets, false
			}
		}
		value, err := strconv.Atoi(part)
		if err != nil || value < 0 || value > 255 {
			return octets, false
		}
		octets[at] = value
	}
	return octets, true
}

// parseInetPart reads one `inet_aton` component: `0x`/`0X` is hex, a leading `0` is octal,
// anything else is decimal.
func parseInetPart(part string) (uint64, bool) {
	switch {
	case len(part) == 0:
		return 0, false
	case len(part) > 2 && part[0] == '0' && (part[1] == 'x' || part[1] == 'X'):
		body := part[2:]
		for index := 0; index < len(body); index++ {
			if !hexDigit(body[index]) {
				return 0, false
			}
		}
		value, err := strconv.ParseUint(body, 16, 64)
		return value, err == nil
	case len(part) > 1 && part[0] == '0':
		body := part[1:]
		for index := 0; index < len(body); index++ {
			if body[index] < '0' || body[index] > '7' {
				return 0, false
			}
		}
		value, err := strconv.ParseUint(body, 8, 64)
		return value, err == nil
	default:
		for index := 0; index < len(part); index++ {
			if !asciiDigit(part[index]) {
				return 0, false
			}
		}
		value, err := strconv.ParseUint(part, 10, 64)
		return value, err == nil
	}
}

// parseIPv4Any reads every spelling inet_aton accepts, reduced to four octets:
//
//	a          32-bit    2130706433 -> 127.0.0.1
//	a.b        b 24-bit  127.1      -> 127.0.0.1
//	a.b.c      c 16-bit  127.0.1    -> 127.0.0.1
//	a.b.c.d    octets    0x7f.0.0.1 -> 127.0.0.1
//
// Not-an-address (a DNS name, or garbage) answers false.
func parseIPv4Any(text string) ([4]int, bool) {
	var octets [4]int
	parts := strings.Split(text, ".")
	if len(parts) < 1 || len(parts) > 4 {
		return octets, false
	}
	// Every part but the LAST is one octet; the last one carries whatever bits remain.
	var packed uint64
	tailBits := uint(8 * (4 - (len(parts) - 1)))
	for at, part := range parts {
		value, ok := parseInetPart(part)
		if !ok {
			return octets, false
		}
		if at == len(parts)-1 {
			if tailBits < 64 && value >= uint64(1)<<tailBits {
				return octets, false
			}
			packed = packed<<tailBits | value
			continue
		}
		if value > 255 {
			return octets, false
		}
		packed = packed<<8 | value
	}
	octets = [4]int{
		int(packed >> 24 & 255), int(packed >> 16 & 255),
		int(packed >> 8 & 255), int(packed & 255),
	}
	return octets, true
}

func ipv4Text(octets [4]int) string {
	parts := make([]string, 0, 4)
	for _, octet := range octets {
		parts = append(parts, strconv.Itoa(octet))
	}
	return strings.Join(parts, ".")
}

// parseIPv6 reads a literal WITHOUT brackets and WITHOUT a zone id into eight 16-bit groups.
// It handles `::` compression and the embedded dotted-quad tail (`::ffff:127.0.0.1`).
func parseIPv6(raw string) ([8]int, bool) {
	var full [8]int
	text := strings.ToLower(raw)
	if len(text) == 0 {
		return full, false
	}
	for index := 0; index < len(text); index++ {
		c := text[index]
		if !hexDigit(c) && c != ':' && c != '.' {
			return full, false
		}
	}
	at := strings.Index(text, "::")
	if at < 0 {
		groups, ok := ipv6GroupsOf(text)
		if !ok || len(groups) != 8 {
			return full, false
		}
		copy(full[:], groups)
		return full, true
	}
	// More than one `::` is not a literal.
	if strings.Contains(text[at+2:], "::") {
		return full, false
	}
	head, tail := text[:at], text[at+2:]
	headGroups := []int{}
	if head != "" {
		parsed, ok := ipv6GroupsOf(head)
		if !ok {
			return full, false
		}
		headGroups = parsed
	}
	tailGroups := []int{}
	if tail != "" {
		parsed, ok := ipv6GroupsOf(tail)
		if !ok {
			return full, false
		}
		tailGroups = parsed
	}
	// `::` stands for AT LEAST one zero group, so a run that already fills all eight is not
	// a literal — it is the same address written two ways, and only one of them is legal.
	if 8-len(headGroups)-len(tailGroups) < 1 {
		return full, false
	}
	copy(full[:], headGroups)
	copy(full[8-len(tailGroups):], tailGroups)
	return full, true
}

// ipv6GroupsOf splits a colon-separated run into 16-bit groups. The LAST element may be a
// dotted quad, which expands to two groups.
func ipv6GroupsOf(run string) ([]int, bool) {
	parts := strings.Split(run, ":")
	if len(parts) == 0 {
		return nil, false
	}
	groups := []int{}
	for index, part := range parts {
		if part == "" {
			return nil, false
		}
		if strings.Contains(part, ".") {
			// Only legal as the final element.
			if index != len(parts)-1 {
				return nil, false
			}
			octets, ok := parseIPv4Strict(part)
			if !ok {
				return nil, false
			}
			return append(groups, octets[0]<<8|octets[1], octets[2]<<8|octets[3]), true
		}
		if len(part) < 1 || len(part) > 4 {
			return nil, false
		}
		for at := 0; at < len(part); at++ {
			if !hexDigit(part[at]) {
				return nil, false
			}
		}
		value, err := strconv.ParseUint(part, 16, 32)
		if err != nil {
			return nil, false
		}
		groups = append(groups, int(value))
	}
	return groups, true
}

// ipv6Text writes RFC 5952 form: lowercase hex, no leading zeros, the LONGEST run of two or
// more zero groups compressed to `::` (leftmost on a tie).
func ipv6Text(groups [8]int) string {
	bestStart, bestLength := -1, 0
	runStart, runLength := -1, 0
	// The run is closed inside the loop when it ENDS and once more after it, rather than by
	// walking one index past the end: a sentinel iteration reads as an out-of-range index to
	// every reader, human and analyser alike.
	for index, group := range groups {
		if group == 0 {
			if runStart < 0 {
				runStart = index
			}
			runLength++
			continue
		}
		if runLength > bestLength {
			bestStart, bestLength = runStart, runLength
		}
		runStart, runLength = -1, 0
	}
	if runLength > bestLength {
		bestStart, bestLength = runStart, runLength
	}
	render := func(from, to int) string {
		parts := make([]string, 0, to-from)
		for index := from; index < to; index++ {
			parts = append(parts, strconv.FormatInt(int64(groups[index]), 16))
		}
		return strings.Join(parts, ":")
	}
	if bestStart < 0 || bestLength < 2 {
		return render(0, len(groups))
	}
	return render(0, bestStart) + "::" + render(bestStart+bestLength, len(groups))
}

// ipv6EmbeddedIPv4 folds `::ffff:a.b.c.d` (IPv4-mapped) and the deprecated `::a.b.c.d`
// (IPv4-compatible) to the dotted quad they denote — the same address for every purpose a
// classifier cares about, and the fold an attacker relies on being skipped. `::` and `::1`
// are their own addresses and are NOT folded, or the IPv6 loopback would land in 0.0.0.0/8.
func ipv6EmbeddedIPv4(groups [8]int) ([4]int, bool) {
	var octets [4]int
	zeroHead := true
	for index := 0; index < 5; index++ {
		if groups[index] != 0 {
			zeroHead = false
			break
		}
	}
	if !zeroHead {
		return octets, false
	}
	embedded := func() [4]int {
		return [4]int{groups[6] >> 8, groups[6] & 255, groups[7] >> 8, groups[7] & 255}
	}
	if groups[5] == 0xffff {
		return embedded(), true
	}
	if groups[5] == 0 && groups[6] != 0 {
		return embedded(), true
	}
	return octets, false
}

func ipv4OctetsClass(octets [4]int) addressClass {
	first, second := octets[0], octets[1]
	switch {
	case first == 0:
		return classUnspecified
	case first == 127:
		return classLoopback
	case first == 10:
		return classPrivate
	case first == 169 && second == 254:
		return classLinkLocal
	case first == 172 && second >= 16 && second <= 31:
		return classPrivate
	case first == 192 && second == 168:
		return classPrivate
	case first == 100 && second >= 64 && second <= 127:
		return classCGNAT
	case first >= 224:
		return classMulticast
	default:
		return classPublic
	}
}

func ipv6GroupsClass(groups [8]int) addressClass {
	allZero := true
	for _, group := range groups {
		if group != 0 {
			allZero = false
			break
		}
	}
	if allZero {
		return classUnspecified
	}
	loopback := groups[7] == 1
	for index := 0; index < 7; index++ {
		if groups[index] != 0 {
			loopback = false
			break
		}
	}
	if loopback {
		return classLoopback
	}
	switch first := groups[0]; {
	case first&0xffc0 == 0xfe80:
		return classLinkLocal
	case first&0xfe00 == 0xfc00:
		return classPrivate
	case first&0xff00 == 0xff00:
		return classMulticast
	default:
		return classPublic
	}
}

// NormalizeHost canonicalises a URL HOST COMPONENT — the bracketed IPv6 form included.
// Answers false when the input is not a host this module will vouch for, which every caller
// reads as "refuse".
//
//	"LOCALHOST."         -> "localhost"
//	"2130706433"         -> "127.0.0.1"
//	"0x7f.0.0.1"         -> "127.0.0.1"
//	"[::FFFF:127.0.0.1]" -> "127.0.0.1"
//	"[2606:4700::1111]"  -> "2606:4700::1111"
//	"exa mple.com"       -> refused
func NormalizeHost(raw string) (string, bool) {
	if len(raw) == 0 {
		return "", false
	}
	if raw[0] == '[' {
		// A bracketed literal is IPv6 only, and a zone id is refused: it is meaningless
		// off-host and is a classic parser differential.
		if raw[len(raw)-1] != ']' {
			return "", false
		}
		groups, ok := parseIPv6(raw[1 : len(raw)-1])
		if !ok {
			return "", false
		}
		if v4, folded := ipv6EmbeddedIPv4(groups); folded {
			return ipv4Text(v4), true
		}
		return ipv6Text(groups), true
	}
	if strings.ContainsAny(raw, "]:/?#@\\%[") {
		return "", false
	}
	lower := strings.ToLower(raw)
	// Strip ONE root-anchoring trailing dot; `a..` stays invalid below.
	stripped := lower
	if len(lower) > 1 && lower[len(lower)-1] == '.' {
		stripped = lower[:len(lower)-1]
	}
	if stripped == "" || len(stripped) > 253 {
		return "", false
	}
	// Numeric in ANY inet_aton spelling means it IS an address, not a name.
	if octets, ok := parseIPv4Any(stripped); ok {
		return ipv4Text(octets), true
	}
	// `last` is carried out of the loop rather than indexed afterwards: an empty label
	// already fails, so the final one is whatever the loop saw last, and a host with no
	// labels at all leaves it "" — which the all-digits test below reads as a refusal.
	last := ""
	for _, label := range strings.Split(stripped, ".") {
		if len(label) < 1 || len(label) > 63 {
			return "", false
		}
		for index := 0; index < len(label); index++ {
			if !hostChar(label[index]) {
				return "", false
			}
		}
		last = label
	}
	// An all-numeric FINAL label is never a DNS name (RFC 3696): it is a malformed address
	// literal — `999.999.999.999`, `0xzz.1`, an out-of-range 32-bit decimal. Answering
	// "domain name" there would be the fail-OPEN reading, since a caller takes that to mean
	// "not an address literal".
	allDigits := true
	for index := 0; index < len(last); index++ {
		if !asciiDigit(last[index]) {
			allDigits = false
			break
		}
	}
	if allDigits {
		return "", false
	}
	return stripped, true
}

// HostClass is the `Tesl.Net` classification, in the same flat tag struct every other ADT
// that crosses a module boundary uses. A program `case`s over it exhaustively, which is what
// makes "did you handle link-local?" a question the compiler answers.
type HostClass struct {
	Tag HostClassTag
}

// HostClassTag identifies which class a HostClass holds. An enum-like set, so the
// `exhaustive` linter can verify a switch over it.
type HostClassTag int

const (
	HostClassLoopback HostClassTag = iota
	HostClassPrivate
	HostClassLinkLocal
	HostClassCgnat
	HostClassMulticast
	HostClassUnspecified
	HostClassPublic
	HostClassDomainName
	HostClassInvalid
)

// ClassifyHost answers the class of a URL host component.
//
// A `localhost` name — and any `*.localhost` name — is LOOPBACK, not a domain name: RFC 6761
// reserves it and resolvers are required to map it to the loopback address, so treating it
// as an ordinary name would be a bypass by definition.
//
// A domain name may still RESOLVE to a forbidden address; deciding that needs a resolver and
// connect-pinning, which is the HTTP client's job rather than a string check's.
func ClassifyHost(raw string) HostClass {
	host, ok := NormalizeHost(raw)
	if !ok {
		return HostClass{Tag: HostClassInvalid}
	}
	if octets, ok := parseIPv4Strict(host); ok {
		return HostClass{Tag: hostClassTag(ipv4OctetsClass(octets))}
	}
	if groups, ok := parseIPv6(host); ok {
		return HostClass{Tag: hostClassTag(ipv6GroupsClass(groups))}
	}
	if host == "localhost" || strings.HasSuffix(host, ".localhost") {
		return HostClass{Tag: HostClassLoopback}
	}
	return HostClass{Tag: HostClassDomainName}
}

func hostClassTag(class addressClass) HostClassTag {
	switch class {
	case classLoopback:
		return HostClassLoopback
	case classPrivate:
		return HostClassPrivate
	case classLinkLocal:
		return HostClassLinkLocal
	case classCGNAT:
		return HostClassCgnat
	case classMulticast:
		return HostClassMulticast
	case classUnspecified:
		return HostClassUnspecified
	case classPublic:
		return HostClassPublic
	case classInvalid:
		return HostClassInvalid
	default:
		return HostClassInvalid
	}
}

// NormalizeHostMaybe is the `Tesl.Net` surface: the canonical host, or Nothing.
func NormalizeHostMaybe(raw string) Maybe[string] {
	if host, ok := NormalizeHost(raw); ok {
		return Something(host)
	}
	return Nothing[string]()
}

func NetIsLoopback(raw string) bool  { return ClassifyHost(raw).Tag == HostClassLoopback }
func NetIsPrivate(raw string) bool   { return ClassifyHost(raw).Tag == HostClassPrivate }
func NetIsLinkLocal(raw string) bool { return ClassifyHost(raw).Tag == HostClassLinkLocal }
func NetIsCgnat(raw string) bool     { return ClassifyHost(raw).Tag == HostClassCgnat }
func NetIsMulticast(raw string) bool { return ClassifyHost(raw).Tag == HostClassMulticast }

// NetIsIPLiteral reports whether the host IS an address literal in some spelling, as opposed
// to a DNS name. A `localhost` name is NOT a literal, though it IS loopback.
func NetIsIPLiteral(raw string) bool {
	host, ok := NormalizeHost(raw)
	if !ok {
		return false
	}
	if _, isV4 := parseIPv4Strict(host); isV4 {
		return true
	}
	_, isV6 := parseIPv6(host)
	return isV6
}

// NetIsIPv4Mapped reports whether the host was WRITTEN as an IPv4-mapped or IPv4-compatible
// IPv6 literal — the spelling a hand-written check misses most often.
func NetIsIPv4Mapped(raw string) bool {
	text := raw
	if len(text) > 1 && text[0] == '[' && text[len(text)-1] == ']' {
		text = text[1 : len(text)-1]
	}
	groups, ok := parseIPv6(text)
	if !ok {
		return false
	}
	_, folded := ipv6EmbeddedIPv4(groups)
	return folded
}

// NetIsForbiddenHost is the one-line outbound guard: true for every host this runtime can
// already tell is not a public destination — any non-public address literal in any spelling,
// the `localhost` names, and anything unparseable. Fail-closed by construction: there is no
// "probably fine" answer.
func NetIsForbiddenHost(raw string) bool {
	switch ClassifyHost(raw).Tag {
	case HostClassPublic, HostClassDomainName:
		return false
	case HostClassLoopback, HostClassPrivate, HostClassLinkLocal, HostClassCgnat,
		HostClassMulticast, HostClassUnspecified, HostClassInvalid:
		return true
	default:
		return true
	}
}
