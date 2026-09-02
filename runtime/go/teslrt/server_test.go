package teslrt

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
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
