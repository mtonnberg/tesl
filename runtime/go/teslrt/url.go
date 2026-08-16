package teslrt

import (
	"strconv"
	"strings"
)

// `Tesl.Url` — an authority-based URL, parsed strictly.
//
// A rule-for-rule port of `dsl/private/url-parse.rkt`, NOT a wrapper over `net/url`, and the
// difference is the point: `net/url` is lenient by design (it is a transport concern), while
// every rule here exists because a permissive reading of one of them is a bypass —
//
//	control characters, spaces and BACKSLASHES are refused ANYWHERE, because a backslash is
//	a path separator to some clients and an ordinary character to others;
//	USERINFO is everything before the LAST `@`, which is what browsers and curl do — taking
//	the first `@` instead is itself the bypass (`https://a@trusted.example.com@127.0.0.1/`);
//	an UNBRACKETED IPv6 literal is refused rather than guessed at, because it is
//	indistinguishable from a bad port;
//	a PORT must be 1-5 decimal digits in [1,65535] — an unparseable one fails the URL rather
//	than being dropped, since "no port" and "a port I could not read" are different facts.
//
// The Url value is OPAQUE on the Tesl side: Url.parse is the only way in, so a program
// cannot hand-build one whose host never went through NormalizeHost.

// Url is the parsed value. Host is CANONICAL (see NormalizeHost) and never empty; Path
// always starts with `/`. Port, Query, Fragment and UserInfo carry "was it written" as well
// as the value, which is load-bearing for re-serialisation: `?` with nothing after it is not
// the same URL as no `?` at all.
type Url struct {
	Scheme      string
	UserInfo    string
	HasUserInfo bool
	Host        string
	Port        Int
	HasPort     bool
	Path        string
	Query       string
	HasQuery    bool
	Fragment    string
	HasFragment bool
}

func urlSchemeChar(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || asciiDigit(c) ||
		c == '+' || c == '-' || c == '.'
}

func urlControlOrSpace(c byte) bool { return c <= ' ' || c == 0x7f }

func schemeDefaultPort(scheme string) (int, bool) {
	switch scheme {
	case "http", "ws":
		return 80, true
	case "https", "wss":
		return 443, true
	case "ftp":
		return 21, true
	default:
		return 0, false
	}
}

// UrlParse is the only way to make a Url.
func UrlParse(raw string) Maybe[Url] {
	if len(raw) == 0 {
		return Nothing[Url]()
	}
	for index := 0; index < len(raw); index++ {
		if urlControlOrSpace(raw[index]) || raw[index] == '\\' {
			return Nothing[Url]()
		}
	}
	colon := strings.IndexByte(raw, ':')
	if colon <= 0 {
		return Nothing[Url]()
	}
	first := raw[0] | 0x20
	if first < 'a' || first > 'z' {
		return Nothing[Url]()
	}
	for index := 0; index < colon; index++ {
		if !urlSchemeChar(raw[index]) {
			return Nothing[Url]()
		}
	}
	scheme := strings.ToLower(raw[:colon])
	rest := raw[colon+1:]
	if !strings.HasPrefix(rest, "//") {
		return Nothing[Url]()
	}
	return urlAfterSlashes(scheme, rest[2:])
}

func urlAfterSlashes(scheme, text string) Maybe[Url] {
	stop := strings.IndexAny(text, "/?#")
	authority, remainder := text, ""
	if stop >= 0 {
		authority, remainder = text[:stop], text[stop:]
	}
	if len(authority) == 0 {
		return Nothing[Url]()
	}
	userInfo, hasUserInfo, hostPort, ok := splitUserInfo(authority)
	if !ok {
		return Nothing[Url]()
	}
	host, port, hasPort, ok := splitHostPort(hostPort)
	if !ok {
		return Nothing[Url]()
	}
	canonical, ok := NormalizeHost(host)
	if !ok {
		return Nothing[Url]()
	}
	path, query, hasQuery, fragment, hasFragment := splitRemainder(remainder)
	return Something(Url{
		Scheme: scheme, UserInfo: userInfo, HasUserInfo: hasUserInfo,
		Host: canonical, Port: FromInt64(int64(port)), HasPort: hasPort,
		Path: path, Query: query, HasQuery: hasQuery,
		Fragment: fragment, HasFragment: hasFragment,
	})
}

// splitUserInfo cuts at the LAST `@`. Browsers and curl do the same, and taking the first
// `@` is itself a bypass: `https://a@trusted.example.com@127.0.0.1/` puts a trusted-looking
// name in the credentials slot and the real host after it.
func splitUserInfo(authority string) (string, bool, string, bool) {
	at := strings.LastIndexByte(authority, '@')
	switch {
	case at < 0:
		return "", false, authority, true
	case at == len(authority)-1:
		// `user@` with no host at all.
		return "", false, "", false
	default:
		return authority[:at], true, authority[at+1:], true
	}
}

// splitHostPort reads `host[:port]`. An ambiguous shape or a malformed port fails the URL
// rather than answering "no port": the two are different facts and a caller that reads a
// missing port as the scheme's default would reach a different server.
func splitHostPort(hostPort string) (string, int, bool, bool) {
	if strings.HasPrefix(hostPort, "[") {
		close := strings.IndexByte(hostPort, ']')
		if close < 0 {
			return "", 0, false, false
		}
		host := hostPort[:close+1]
		tail := hostPort[close+1:]
		switch {
		case tail == "":
			return host, 0, false, true
		case strings.HasPrefix(tail, ":"):
			port, ok := parseUrlPort(tail[1:])
			if !ok {
				return "", 0, false, false
			}
			return host, port, true, true
		default:
			return "", 0, false, false
		}
	}
	parts := strings.Split(hostPort, ":")
	switch len(parts) {
	case 1:
		return parts[0], 0, false, true
	case 2:
		port, ok := parseUrlPort(parts[1])
		if !ok {
			return "", 0, false, false
		}
		return parts[0], port, true, true
	default:
		// More than one colon and no brackets: an unbracketed IPv6 literal is
		// indistinguishable from a bad port, so refuse rather than guess.
		return "", 0, false, false
	}
}

func parseUrlPort(text string) (int, bool) {
	if len(text) == 0 || len(text) > 5 {
		return 0, false
	}
	for index := 0; index < len(text); index++ {
		if !asciiDigit(text[index]) {
			return 0, false
		}
	}
	value, err := strconv.Atoi(text)
	if err != nil || value < 1 || value > 65535 {
		return 0, false
	}
	return value, true
}

// splitRemainder cuts what follows the authority into path / query / fragment. An empty path
// is `/`, which is the same resource.
func splitRemainder(remainder string) (string, string, bool, string, bool) {
	hash := strings.IndexByte(remainder, '#')
	before, fragment, hasFragment := remainder, "", false
	if hash >= 0 {
		before, fragment, hasFragment = remainder[:hash], remainder[hash+1:], true
	}
	question := strings.IndexByte(before, '?')
	path, query, hasQuery := before, "", false
	if question >= 0 {
		path, query, hasQuery = before[:question], before[question+1:], true
	}
	if path == "" {
		path = "/"
	}
	return path, query, hasQuery, fragment, hasFragment
}

func UrlScheme(url Url) string { return url.Scheme }
func UrlHost(url Url) string   { return url.Host }
func UrlPath(url Url) string   { return url.Path }

// UrlPort is the port only when it was WRITTEN.
func UrlPort(url Url) Maybe[Int] {
	if !url.HasPort {
		return Nothing[Int]()
	}
	return Something(url.Port)
}

// UrlEffectivePort is the written port, or the scheme's default. Nothing for a scheme with
// no registered default — a guess there would be a connection to somewhere unasked-for.
func UrlEffectivePort(url Url) Maybe[Int] {
	if url.HasPort {
		return Something(url.Port)
	}
	if port, known := schemeDefaultPort(url.Scheme); known {
		return Something(FromInt64(int64(port)))
	}
	return Nothing[Int]()
}

// UrlQuery and UrlFragment answer PRESENT-but-empty when the delimiter was written and
// Nothing when it was not. The distinction is load-bearing for re-serialisation, which is
// why they are a Maybe and not a String.
func UrlQuery(url Url) Maybe[string] {
	if !url.HasQuery {
		return Nothing[string]()
	}
	return Something(url.Query)
}

func UrlFragment(url Url) Maybe[string] {
	if !url.HasFragment {
		return Nothing[string]()
	}
	return Something(url.Fragment)
}

// UrlUserInfo is everything before the LAST `@` of the authority. Exposed rather than
// dropped: `https://trusted.example.com@127.0.0.1/` puts a trusted-looking name in the
// credentials slot, and a check that reads the URL as text sees it as the host. A guard that
// refuses any URL with userinfo present is then one line.
func UrlUserInfo(url Url) Maybe[string] {
	if !url.HasUserInfo {
		return Nothing[string]()
	}
	return Something(url.UserInfo)
}

// UrlToString rebuilds the URL from its canonical parts. It is not the input text: the
// scheme and host are canonicalised, and that is the point — what a check examined and what
// a caller then uses are the same string.
func UrlToString(url Url) string {
	var out strings.Builder
	out.WriteString(url.Scheme)
	out.WriteString("://")
	if url.HasUserInfo {
		out.WriteString(url.UserInfo)
		out.WriteByte('@')
	}
	// An IPv6 host goes back in brackets, which is where it came from.
	if strings.Contains(url.Host, ":") {
		out.WriteByte('[')
		out.WriteString(url.Host)
		out.WriteByte(']')
	} else {
		out.WriteString(url.Host)
	}
	if url.HasPort {
		out.WriteByte(':')
		out.WriteString(url.Port.String())
	}
	out.WriteString(url.Path)
	if url.HasQuery {
		out.WriteByte('?')
		out.WriteString(url.Query)
	}
	if url.HasFragment {
		out.WriteByte('#')
		out.WriteString(url.Fragment)
	}
	return out.String()
}
