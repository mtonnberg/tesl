package teslrt

import (
	"fmt"
	"net/http"
	"strings"
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
func (scope *RequestScope) CookieHeaders() []string {
	if scope == nil {
		return nil
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
func ClearSessionCookie(scope *RequestScope) {
	scope.SetCookieHeader("Http.clearSessionCookie",
		fmt.Sprintf("%s=; %s; Max-Age=0", sessionCookieName, sessionCookieAttributes))
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

func stringKeyLess(left, right string) bool { return left < right }

// NewHttpRequest snapshots the request. Header names are lower-cased so a lookup does not
// depend on the casing a client happened to send; cookie names are left exactly as sent.
func NewHttpRequest(request *http.Request, body string) HttpRequest {
	headers := DictEmpty[string, string]()
	for name, values := range request.Header {
		if len(values) > 0 {
			headers = DictInsert(headers, strings.ToLower(name), values[0], stringKeyLess)
		}
	}
	cookies := DictEmpty[string, string]()
	for _, cookie := range request.Cookies() {
		cookies = DictInsert(cookies, cookie.Name, cookie.Value, stringKeyLess)
	}
	query := DictEmpty[string, string]()
	for name, values := range request.URL.Query() {
		if len(values) > 0 {
			query = DictInsert(query, name, values[0], stringKeyLess)
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
