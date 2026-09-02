package teslrt

import (
	"encoding/json"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func testServer() Server {
	return Server{
		Routes: []Route{
			{Method: "GET", Path: "/hello", Endpoint: "hello"},
			{Method: "POST", Path: "/hello", Endpoint: "shout"},
			{Method: "GET", Path: "/items/:id", Endpoint: "item"},
			{Method: "GET", Path: "/boom", Endpoint: "boom"},
		},
		Handlers: map[string]HandlerFunc{
			"hello": func(scope *RequestScope, _ *http.Request) Response {
				_ = ClearSessionCookie(scope)
				return Response{Status: 200, Body: map[string]any{"message": "hi"}}
			},
			"shout": func(_ *RequestScope, _ *http.Request) Response {
				return Response{Status: 200, Body: map[string]any{"message": "HI"}}
			},
			"item": func(_ *RequestScope, request *http.Request) Response {
				id, _ := PathParam("/items/:id", request.URL.Path, "id")
				return Response{Status: 200, Body: map[string]any{"id": id}}
			},
			"boom": func(scope *RequestScope, _ *http.Request) Response {
				// A handler that sets a cookie and then fails mints no session.
				_ = ClearSessionCookie(scope)
				return Fail(400, "nope")
			},
		},
	}
}

func serve(t *testing.T, method, path string) *http.Response {
	t.Helper()
	recorder := httptest.NewRecorder()
	testServer().ServeHTTP(recorder, httptest.NewRequest(method, path, nil))
	return recorder.Result()
}

func TestServerDispatch(t *testing.T) {
	response := serve(t, "GET", "/hello")
	if response.StatusCode != 200 {
		t.Fatalf("status = %d", response.StatusCode)
	}
	body, _ := io.ReadAll(response.Body)
	if string(body) != `{"message":"hi"}` {
		t.Errorf("body = %s", body)
	}
	if got := response.Header.Get("Content-Type"); got != "application/json" {
		t.Errorf("content type = %q", got)
	}
	if got := response.Header.Get("Set-Cookie"); got == "" {
		t.Error("a 2xx response must carry the handler's cookies")
	}

	body, _ = io.ReadAll(serve(t, "POST", "/hello").Body)
	if string(body) != `{"message":"HI"}` {
		t.Errorf("post body = %s", body)
	}

	body, _ = io.ReadAll(serve(t, "GET", "/items/42").Body)
	if string(body) != `{"id":"42"}` {
		t.Errorf("capture body = %s", body)
	}
}

func TestServerStatusChoices(t *testing.T) {
	// Unknown path is 404; known path with the wrong method is 405 — reporting 404 there
	// would tell a client the resource does not exist when it does.
	if got := serve(t, "GET", "/missing").StatusCode; got != 404 {
		t.Errorf("unknown path = %d, want 404", got)
	}
	if got := serve(t, "DELETE", "/hello").StatusCode; got != 405 {
		t.Errorf("wrong method = %d, want 405", got)
	}
	if got := serve(t, "GET", "/items/42/extra").StatusCode; got != 404 {
		t.Errorf("over-long path = %d, want 404", got)
	}
}

func TestServerFailureShape(t *testing.T) {
	response := serve(t, "GET", "/boom")
	if response.StatusCode != 400 {
		t.Fatalf("status = %d", response.StatusCode)
	}
	body, _ := io.ReadAll(response.Body)
	var decoded map[string]any
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Fatalf("body %s: %v", body, err)
	}
	if decoded["ok"] != false || decoded["error"] != "nope" {
		t.Errorf("error body = %s", body)
	}
	// Cookies attach to 2xx only: a handler that fails mints no session.
	if got := response.Header.Get("Set-Cookie"); got != "" {
		t.Errorf("a failure must not set cookies, got %q", got)
	}
}

// A handler whose Float overflowed answers a sanitized 500, not a 200 whose body is `+Inf`
// (review M3). The encode happens in writeResponse, AFTER callHandler's recover, so the trap
// has to be caught there — left to net/http it would close the connection with no response.
func TestServerNonFiniteFloatAnswersSanitized500(t *testing.T) {
	server := Server{
		Routes: []Route{{Method: "GET", Path: "/stat", Endpoint: "stat"}},
		Handlers: map[string]HandlerFunc{
			"stat": func(scope *RequestScope, _ *http.Request) Response {
				// A cookie set on the way: a 500 must not carry it.
				_ = ClearSessionCookie(scope)
				return Response{Status: 200, Body: map[string]any{"label": "overflow", "value": math.Inf(1)}}
			},
		},
	}
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, httptest.NewRequest("GET", "/stat", nil))
	response := recorder.Result()
	body, _ := io.ReadAll(response.Body)
	if response.StatusCode != 500 {
		t.Fatalf("status = %d, body %s", response.StatusCode, body)
	}
	var decoded map[string]any
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Fatalf("500 body is not JSON: %v (%s)", err, body)
	}
	if decoded["error"] != "Internal server error" || strings.Contains(string(body), "Inf") {
		t.Errorf("500 body = %s, want the sanitized envelope", body)
	}
	if response.Header.Get("Content-Type") != "application/json" {
		t.Errorf("Content-Type = %q", response.Header.Get("Content-Type"))
	}
	if len(response.Header.Values("Set-Cookie")) != 0 {
		t.Error("a 500 must not carry the handler's cookies")
	}
}

// RFC 9110 §15.5.6: a 405 MUST list the methods the path does accept.
func TestServer405CarriesAllow(t *testing.T) {
	response := serve(t, "PUT", "/hello")
	if response.StatusCode != 405 {
		t.Fatalf("status = %d", response.StatusCode)
	}
	if got := response.Header.Get("Allow"); got != "GET, POST" {
		t.Errorf("Allow = %q, want %q", got, "GET, POST")
	}
	if got := serve(t, "DELETE", "/items/7").Header.Get("Allow"); got != "GET" {
		t.Errorf("Allow for a single-method path = %q, want GET", got)
	}
	if got := serve(t, "GET", "/nowhere"); got.StatusCode != 404 || got.Header.Get("Allow") != "" {
		t.Errorf("a 404 carries no Allow: %d %q", got.StatusCode, got.Header.Get("Allow"))
	}
}
