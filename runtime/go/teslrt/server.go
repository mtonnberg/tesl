package teslrt

import (
	"net/http"
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

type Server struct {
	Routes   []Route
	Handlers map[string]HandlerFunc
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
		rejection, isRejection := recovered.(RequestRejection)
		if !isRejection {
			panic(recovered)
		}
		response = Fail(rejection.Status, rejection.Message)
	}()
	return handler(scope, request)
}

func (server Server) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	pathMatched := false
	for _, route := range server.Routes {
		if !pathMatches(route.Path, request.URL.Path) {
			continue
		}
		pathMatched = true
		if route.Method != request.Method {
			continue
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
	if pathMatched {
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
	// Cookies attach to 2xx responses only, matching dsl/web.rkt: a handler that sets a
	// cookie and then fails mints no session.
	if scope != nil && response.Status >= 200 && response.Status < 300 {
		for _, cookie := range scope.CookieHeaders() {
			writer.Header().Add("Set-Cookie", cookie)
		}
	}
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(response.Status)
	_, _ = writer.Write([]byte(EncodeJSONValue(response.Body)))
}
