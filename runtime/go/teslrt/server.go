package teslrt

import (
	"fmt"
	"net/http"
	"os"
	"runtime/debug"
	"strings"
)

// The HTTP surface an emitted module exposes: the ROUTES an `api` declares, and the
// SERVER that binds each route's endpoint name to a handler.
//
// Emitted modules build these as ordinary values, so a Go author who sheds Tesl can read
// the routing table, call a handler directly, or mount the server on any net/http mux.
// Nothing here reaches into request-scoped globals: the per-request state a handler may
// touch (cookies) is created by the dispatcher and passed in explicitly.

type Route struct {
	Method   string
	Path     string
	Endpoint string
}

// HandlerFunc is one endpoint's implementation. The scope carries the response state the
// handler is allowed to write (see request.go); `Response` says what to send.
type HandlerFunc func(scope *RequestScope, request *http.Request) Response

type Response struct {
	Status int
	// Body is an already-encoded JSON value (map / slice / scalar), rendered by
	// EncodeJSONValue so object keys keep the sorted order Racket produces.
	Body any
}

// Fail builds the error body shape the Racket server sends:
// {"ok":false,"error":<message>,"details":[]}.
func Fail(status int, message string) Response {
	return Response{
		Status: status,
		Body: map[string]any{
			"ok":      false,
			"error":   message,
			"details": []any{},
		},
	}
}

// StreamFunc is an endpoint that STREAMS rather than answering once: an `sse` route. It takes
// the writer directly, because its response is written over the life of the connection instead
// of being built and then sent.
type StreamFunc func(writer http.ResponseWriter, request *http.Request)

type Server struct {
	Routes   []Route
	Handlers map[string]HandlerFunc
	// Streams holds the SSE endpoints, keyed like Handlers. A route resolves to one or the
	// other, never both: `sse` and the request/response methods are different declarations.
	Streams map[string]StreamFunc
	// The runtime-owned SSO routes an `sso "<seg>"` clause mints. They are matched BEFORE
	// the declared ones and they own their whole response — a 303 with cookies, not the JSON
	// envelope every handler answers in — so they cannot be expressed as a Handler.
	SsoRoutes []SsoRoute
}

// ServeHTTP dispatches by method and path. A path segment written `:name` in the route
// matches any single segment.
//
// The status choices mirror the Racket router: an unknown path is 404, and a known path
// with the wrong method is 405 — reporting 404 for a method mismatch would tell a client
// the resource does not exist when it does.
// callHandler runs one handler and converts a check rejection that escaped its body into
// the response that rejection describes. Any OTHER panic is left alone: a genuine bug must
// not be reported to the client as a validation failure.
func callHandler(handler HandlerFunc, scope *RequestScope, request *http.Request) (response Response) {
	defer func() {
		recovered := recover()
		if recovered == nil {
			return
		}
		if rejection, isRejection := recovered.(RequestRejection); isRejection {
			response = Fail(rejection.Status, rejection.Message)
			return
		}
		response = sanitizedTrap(recovered)
	}()
	return handler(scope, request)
}

// sanitizedTrap is what ANY other trap becomes: a 500 whose message is deliberately generic.
// The trap text never reaches the client: a trap message carries whatever the program was
// holding (a path, a key, a row), and an `auth` block is exactly where a malformed cookie can
// provoke one — so a client-triggerable trap must not become a client-readable disclosure. The
// detail is still available to the operator, on stderr.
func sanitizedTrap(recovered any) Response {
	fmt.Fprintf(os.Stderr, "tesl: handler trapped: %v\n%s", recovered, debug.Stack())
	return Fail(500, "Internal server error")
}

func (server Server) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	// The two request-level refusals the Racket runtime applies to every request (serve.go):
	// a cross-site state-changing request, and a Host that is not this deployment's. Checked
	// here rather than in `Serve` so an api-test — which drives this method directly — exercises
	// them too.
	if refusal, refused := requestRefusal(request); refused {
		writeResponse(writer, nil, refusal)
		return
	}
	// The SSO routes are matched FIRST. `/auth/<seg>/login` is runtime-owned, and a declared
	// route that happened to share the path would otherwise shadow a login — the same
	// precedence dsl/web.rkt gives them.
	if route, kind, matched := findSsoMatch(server.SsoRoutes, request.URL.Path); matched {
		// ANY method, as dsl/web.rkt's matcher does. Narrowing this to GET would be the
		// safer-looking choice and the wrong one: it decides which PROGRAMS run rather than
		// only what they answer, and a POST to a login path would then reach a declared
		// handler here while being shadowed there.
		handleSsoRequest(route, kind, writer, request)
		return
	}
	// The methods declared for a path that matched, for the `Allow` header a 405 MUST carry
	// (RFC 9110 §15.5.6) — the answer to "wrong method" is useless without the right ones.
	var allowed []string
	for _, route := range server.Routes {
		if !pathMatches(route.Path, request.URL.Path) {
			continue
		}
		allowed = append(allowed, route.Method)
		if route.Method != request.Method {
			continue
		}
		if stream, streams := server.Streams[route.Endpoint]; streams {
			// A stream owns its own response: status, headers and body are written by the
			// handler over the life of the connection, so nothing is wrapped around it here.
			stream(writer, request)
			return
		}
		handler, found := server.Handlers[route.Endpoint]
		if !found {
			writeResponse(writer, nil, Fail(500, "endpoint "+route.Endpoint+" has no handler"))
			return
		}
		scope := NewRequestScope()
		writeResponse(writer, scope, callHandler(handler, scope, request))
		return
	}
	if len(allowed) > 0 {
		writer.Header().Set("Allow", strings.Join(allowed, ", "))
		writeResponse(writer, nil, Fail(405, "method not allowed"))
		return
	}
	writeResponse(writer, nil, Fail(404, "not found"))
}

func pathMatches(pattern, path string) bool {
	patternParts := strings.Split(strings.Trim(pattern, "/"), "/")
	pathParts := strings.Split(strings.Trim(path, "/"), "/")
	if len(patternParts) != len(pathParts) {
		return false
	}
	for index, part := range patternParts {
		if strings.HasPrefix(part, ":") {
			if pathParts[index] == "" {
				return false
			}
			continue
		}
		if part != pathParts[index] {
			return false
		}
	}
	return true
}

// PathParam reads the segment a `:name` placeholder matched.
func PathParam(pattern, path, name string) (string, bool) {
	patternParts := strings.Split(strings.Trim(pattern, "/"), "/")
	pathParts := strings.Split(strings.Trim(path, "/"), "/")
	if len(patternParts) != len(pathParts) {
		return "", false
	}
	for index, part := range patternParts {
		if part == ":"+name {
			return pathParts[index], true
		}
	}
	return "", false
}

func writeResponse(writer http.ResponseWriter, scope *RequestScope, response Response) {
	// The body is encoded BEFORE the status is chosen, because encoding can trap — a Float that
	// overflowed to +Inf has no JSON spelling — and the handler's `callHandler` recover is
	// already behind us by now. Left to net/http the trap would close the connection with a
	// stack on stderr and no response; here it becomes the same sanitized 500 every other trap
	// is, and a 500 attaches no cookie, so the status is decided before the cookie loop.
	body, encoded := encodeResponseBody(response.Body)
	if !encoded {
		response = Fail(500, "Internal server error")
		body = EncodeJSONValue(response.Body)
	}
	// Cookies attach to 2xx responses only, matching dsl/web.rkt: a handler that sets a
	// cookie and then fails mints no session.
	if scope != nil && response.Status >= 200 && response.Status < 300 {
		for _, cookie := range scope.CookieHeaders() {
			writer.Header().Add("Set-Cookie", cookie)
		}
	}
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(response.Status)
	_, _ = writer.Write([]byte(body))
}

// encodeResponseBody renders a response body, reporting a trap as `false` after logging it
// the way `callHandler` logs a handler trap — the encoder is the last program-controlled step
// before the bytes leave, and its failure is the program's, not the client's.
func encodeResponseBody(value any) (body string, encoded bool) {
	defer func() {
		if recovered := recover(); recovered != nil {
			_ = sanitizedTrap(recovered)
			body, encoded = "", false
		}
	}()
	return EncodeJSONValue(value), true
}

// IntegerSegment parses a path capture declared with `intCodec`.
//
// A 400 rather than a 404: the route MATCHED — the shape of the path is right — and what is
// wrong is the value in it, which is a client error the caller can act on. That is the
// status `dsl/web.rkt`'s `integer-segment` answers, and the message is its text.
//
// Racket accepts anything its `string->number` reads as an integer, which includes `1e3`
// and `#x10`. This reads decimal digits with an optional sign and nothing else: a path
// segment is a URL component, and a route that answers to `/tasks/1e3` as well as
// `/tasks/1000` is two names for one resource.
func IntegerSegment(segment string) Check[Int] {
	value, err := ParseDecimal(segment)
	if err != nil {
		// The echoed segment is bounded: a client that sent a megabyte of digits does not get
		// a megabyte back, and an operator log line stays a line.
		shown := segment
		if len(shown) > 64 {
			shown = shown[:64] + "…"
		}
		return Reject[Int](400, "Expected an integer path segment, got "+shown)
	}
	return Accept(value)
}
