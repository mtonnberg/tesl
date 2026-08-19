package teslrt

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
)

// RequestScope is the per-request state the Racket runtime keeps in a `parameterize`
// scope: the cookies a handler has recorded on the response being built.
//
// Capabilities are deliberately NOT here. Every capability site in the AST carries a
// STATIC list of names — `requires [...]`, `withCapabilities [...]`, `serve`, `workers` —
// so the granted set at any point is known at compile time and the checker already
// verifies each call against it. A runtime check would compare two compile-time constants.
// Keeping one would also force this scope through every capability-gated function, which
// is exactly the blast radius the call-graph threading exists to avoid. Racket checks at
// runtime because its capability set is a dynamic parameter; that mechanism is also what
// broke capability delegation at deferred tool execution ("passes test, fails live"), a
// failure mode a compile-time-only design does not have.
//
// This type exists because Go has no goroutine-local storage. A Racket parameter is
// thread-local and every request is served on its own thread, so a handler deep in a call
// chain can call `Http.clearSessionCookie` and the runtime knows which response it belongs
// to. In Go the scope has to be passed explicitly — and the emitter passes it ONLY to the
// functions whose call graph actually reaches a scope-using leaf, so ordinary pure
// functions keep their plain signatures and the emitted code still reads like Go someone
// would write.
//
// A nil scope means "no live HTTP response", which is exactly the Racket condition that
// raises: startup code, `main`, and queue workers have no response to attach a cookie to.
type RequestScope struct {
	// Full `Set-Cookie` header values, in send order.
	cookies []string
}

func NewRequestScope() *RequestScope {
	return &RequestScope{}
}

// SetCookieHeader records one complete `Set-Cookie` value. LAST CALL WINS PER COOKIE
// NAME, and send order is otherwise preserved — the same rule dsl/response-cookies.rkt
// states, so `setSessionCookie` followed by `clearSessionCookie` emits exactly one
// `Set-Cookie` for that name rather than two contradictory ones.
func (scope *RequestScope) SetCookieHeader(who, value string) {
	if scope == nil {
		panic(who + ": no HTTP response to attach a cookie to.\n" +
			"  it is only callable while serving an HTTP request — from a handler body, an\n" +
			"  `auth` block, or an SSE subscribe.  Startup, `main` and queue-worker code have\n" +
			"  no HTTP response.")
	}
	name := value
	if index := strings.IndexByte(value, '='); index >= 0 {
		name = value[:index]
	}
	for index, existing := range scope.cookies {
		existingName := existing
		if at := strings.IndexByte(existing, '='); at >= 0 {
			existingName = existing[:at]
		}
		if existingName == name {
			scope.cookies[index] = value
			return
		}
	}
	scope.cookies = append(scope.cookies, value)
}

// CookieHeaders hands back a copy, so a caller cannot reach the scope's own storage.
//
// An EMPTY slice rather than nil for "no scope": callers range over or index the result, and
// nilaway is right that a nil return travelling into a slice operation is a nil-panic waiting
// for the one caller who forgets to check.
func (scope *RequestScope) CookieHeaders() []string {
	if scope == nil {
		return []string{}
	}
	out := make([]string, len(scope.cookies))
	copy(out, scope.cookies)
	return out
}

// The session cookie's shape is fixed by tesl/http.rkt and must match byte for byte:
// the name is `__Host-`-prefixed (so the browser enforces Secure + host-only + Path=/),
// and SameSite=Lax rather than Strict so following an ordinary link back into the app
// arrives authenticated.
const (
	sessionCookieName       = "__Host-session"
	sessionCookieAttributes = "Path=/; HttpOnly; Secure; SameSite=Lax"
)

// ClearSessionCookie is the logout half: same cookie, same attributes, empty value and
// `Max-Age=0`, which is how a browser is told to drop it. It removes the BROWSER's copy
// and does not invalidate the token — the same documented limitation Racket carries.
// Returns Tesl's Unit (an empty struct), so the emitted code can use it in value
// position the way a Tesl expression of type Unit is used.
func ClearSessionCookie(scope *RequestScope) struct{} {
	scope.SetCookieHeader("Http.clearSessionCookie",
		fmt.Sprintf("%s=; %s; Max-Age=0", sessionCookieName, sessionCookieAttributes))
	return struct{}{}
}

// HttpRequest is what an `auth` function and a handler see of the incoming request.
// It is a plain value built once per request by the dispatcher — the fields Tesl exposes,
// nothing more, so an ejecting author is not handed the whole net/http surface.
//
// The maps are teslrt.Dict values because that is what Tesl's `Dict.lookup` expects.
// A Dict is stored sorted by key, and these are built with plain string ordering, which is
// exactly the comparator the emitter passes at a `Dict.lookup` call site on String keys.
type HttpRequest struct {
	Method          string
	Path            string
	Cookies         Dict[string, string]
	Headers         Dict[string, string]
	QueryParameters Dict[string, string]
	Body            string
}

// ReadRequestBody reads a request body under the SAME cap `dsl/web.rkt` applies.
//
// The body is read whole into memory and parsed, so an unbounded one lets a client exhaust
// memory and CPU with a single request. The limit is `TESL_MAX_BODY_BYTES` when it names a
// positive number, else 1 MiB — generous for a typed JSON API, and the same default and variable
// the Racket runtime reads, so the two refuse the same requests.
//
// Answers the body plus a status and message: 0 means the body is usable, 413 that it exceeded
// the cap, 400 that the connection failed mid-read. The caller turns that into a rejection,
// because a runtime that wrote the response itself would bypass the handler's own error shape.
func ReadRequestBody(request *http.Request) ([]byte, int, string) {
	limit := maxRequestBodyBytes()
	// One byte OVER the cap distinguishes "exactly at the limit" from "too long" without reading
	// the rest of an arbitrarily large body.
	raw, err := io.ReadAll(io.LimitReader(request.Body, int64(limit)+1))
	if err != nil {
		return nil, 400, "Missing JSON payload"
	}
	if len(raw) > limit {
		return nil, 413, "Request body too large"
	}
	return raw, 0, ""
}

// CheckJSONPayload is the rest of `dsl/web.rkt`'s `parse-json-body`, for an endpoint that
// DECLARES a body: the content type must say JSON, and the body must not be empty.
//
// Emitted only where a payload is declared, which is where Racket applies it — an `auth` that
// verifies a MAC over the raw bytes reads the body of a request that may legitimately not be JSON
// at all.
//
// Answers a status and message, 0 for "usable", the same shape `ReadRequestBody` uses so the
// emitted handler has one refusal idiom rather than two.
func CheckJSONPayload(request *http.Request, body []byte) (int, string) {
	// `Contains` rather than an exact compare: a real content type carries parameters
	// (`application/json; charset=utf-8`), and this is the same substring test the Racket side
	// makes with `#rx"application/json"`.
	if !strings.Contains(strings.ToLower(request.Header.Get("Content-Type")), "application/json") {
		return 415, "Expected application/json payload"
	}
	if len(body) == 0 {
		return 400, "Missing JSON payload"
	}
	return 0, ""
}

func maxRequestBodyBytes() int {
	maxBodyOnce.Do(func() {
		maxBodyBytes = 1 << 20
		if declared, err := strconv.Atoi(strings.TrimSpace(os.Getenv("TESL_MAX_BODY_BYTES"))); err == nil && declared > 0 {
			maxBodyBytes = declared
		}
	})
	return maxBodyBytes
}

var (
	maxBodyOnce  sync.Once
	maxBodyBytes int
)

// NewHttpRequest snapshots the request. Header names are lower-cased so a lookup does not
// depend on the casing a client happened to send; cookie names are left exactly as sent.
//
// A REPEATED name — `?q=first&q=second`, or two `X-Forwarded-For` headers — collapses to the
// LAST value, because a Dict holds one value per key and that is the answer the Racket runtime
// gives: both its header and query hashes are built with `for/hash`, which keeps the last
// binding. Taking the first instead is the natural Go spelling (`Query().Get`) and the wrong
// one; `tests/query-parameters-tests.tesl` pins the rule.
func NewHttpRequest(request *http.Request, body string) HttpRequest {
	headers := DictEmpty[string, string]()
	for name, values := range request.Header {
		if len(values) > 0 {
			headers = DictInsert(headers, strings.ToLower(name), values[len(values)-1], stringKeyLess)
		}
	}
	cookies := DictEmpty[string, string]()
	for _, cookie := range request.Cookies() {
		cookies = DictInsert(cookies, cookie.Name, cookie.Value, stringKeyLess)
	}
	query := DictEmpty[string, string]()
	for name, values := range request.URL.Query() {
		if len(values) > 0 {
			query = DictInsert(query, name, values[len(values)-1], stringKeyLess)
		}
	}
	return HttpRequest{
		Method:          request.Method,
		Path:            request.URL.Path,
		Cookies:         cookies,
		Headers:         headers,
		QueryParameters: query,
		Body:            body,
	}
}

// SetSessionCookie is `Http.setSessionCookie`: the ONE blessed session transport. The name is
// `__Host-`-prefixed so the browser enforces Secure, host-only and Path=/, and the lifetime
// matches the token's own TTL — a cookie that outlived its token would only produce 401s.
//
// There is no name parameter and no attribute parameter: every option here is a way to get it
// wrong, and the fixed shape is what makes `Http.sessionToken` able to read it back.
func SetSessionCookie(scope *RequestScope, token JwtToken) struct{} {
	// The value must LOOK like a signed token — three non-empty base64url segments. A session
	// cookie carrying anything else is a misuse (writing an unverified cookie value straight
	// back, say), and writing it would mint a session out of attacker-supplied text. Racket
	// applies the same shape check for the same reason, and the trap is contained by the
	// router's sanitized 500 rather than reaching the client.
	if !looksLikeJWT(token.Value) {
		panic(fmt.Sprintf("Http.setSessionCookie: expected a JwtToken produced by `JWT.sign`, "+
			"got %q.\n  A session cookie must carry a signed token; this value is not a\n"+
			"  well-formed JWT and will not be written to the response.", token.Value))
	}
	scope.SetCookieHeader("Http.setSessionCookie",
		fmt.Sprintf("%s=%s; %s; Max-Age=%d",
			sessionCookieName, token.Value, sessionCookieAttributes, jwtTTLSeconds))
	return struct{}{}
}

// looksLikeJWT is the wire SHAPE only — `header.payload.signature`, base64url — never a
// verification. Deciding whether a token is authentic is `JWT.verify`'s job, and conflating the
// two here would be the more dangerous kind of check: one that looks like a guarantee.
func looksLikeJWT(value string) bool {
	segments := strings.Split(value, ".")
	if len(segments) != 3 {
		return false
	}
	for _, segment := range segments {
		if segment == "" {
			return false
		}
		for _, character := range segment {
			isBase64URL := (character >= 'A' && character <= 'Z') ||
				(character >= 'a' && character <= 'z') ||
				(character >= '0' && character <= '9') ||
				character == '_' || character == '-'
			if !isBase64URL {
				return false
			}
		}
	}
	return true
}

// SessionToken is `Http.sessionToken`: the reader, so the fixed cookie name is written down
// once rather than spelled out at every call site — where a typo is a permanent 401. It is pure
// and ungated; `JWT.verify` is what sits between this and a fact.
func SessionToken(request HttpRequest) Maybe[JwtToken] {
	value, found := DictLookup(request.Cookies, sessionCookieName, stringKeyLess).Value()
	if !found {
		return Nothing[JwtToken]()
	}
	return Something(JwtToken{Value: value})
}

// ResponseCookie is the api-test reader: the session cookie a response set, as a
// Cookie-header-ready `name=value` pair, so a round-trip test can feed it straight back. The
// ATTRIBUTES are stripped deliberately — assert those against the raw `set-cookie` header,
// which is the full line.
func ResponseCookie(response ApiResponse) Maybe[string] {
	line, found := DictLookup(response.Headers, "set-cookie", stringKeyLess).Value()
	if !found {
		return Nothing[string]()
	}
	// The pair is everything up to the first `;`. Indexed only after a length check: a split
	// result is a slice whose emptiness nothing here guarantees to a reader (or to nilaway).
	segments := strings.Split(line, ";")
	if len(segments) == 0 {
		return Nothing[string]()
	}
	pair := strings.TrimSpace(segments[0])
	if !strings.Contains(pair, "=") {
		return Nothing[string]()
	}
	return Something(pair)
}
