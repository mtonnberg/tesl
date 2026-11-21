package teslrt

import (
	"net/http"
	"testing"
)

// Since issue #45 an api-test path may be any String expression. `httptest.NewRequest` panics on
// one it cannot parse, and left alone that crashed the whole test binary with Go's message about
// a malformed HTTP version; the trap names the request instead.
func TestApiRequestNamesAMalformedPath(t *testing.T) {
	mustPanic(t, `cannot build the request GET "/tasks/a b"`, func() {
		ApiRequest(testServer(), "GET", "/tasks/a b", "", nil, nil)
	})
	mustPanic(t, "/items/%zz", func() {
		ApiRequest(testServer(), "GET", "/items/%zz", "", nil, nil)
	})
	// A well-formed path still dispatches.
	response := ApiRequest(testServer(), "GET", "/items/7", "", nil, nil)
	if !StatusOk(response.Status) || JsonAsString(JsonFieldOf(response.Body, "id")) != "7" {
		t.Errorf("GET /items/7 = %s %v", response.Status.String(), response.Body.JsonRaw())
	}
}

// a `publicOrigin` server refuses a Host naming another origin, and the harness
// sent none — so every api-test against such a server failed with 421 until each request
// carried a hand-written Host. A request with no Host now goes to the app's own origin; a
// test that writes its own Host keeps it, which is how the refusal itself is tested.
func TestApiRequestAddressesThePublicOrigin(t *testing.T) {
	SetPublicOriginValue("https://app.example.com:9443")
	defer SetPublicOriginValue("")
	server := Server{
		Routes: []Route{{Method: "GET", Path: "/host", Endpoint: "GET /host"}},
		Handlers: map[string]HandlerFunc{
			"GET /host": func(scope *RequestScope, request *http.Request) Response {
				return Response{Status: 200, Body: request.Host}
			},
		},
	}
	defaulted := ApiRequest(server, "GET", "/host", "", nil, nil)
	if !StatusOk(defaulted.Status) {
		t.Fatalf("a request with no Host was refused: %s %v", defaulted.Status.String(), defaulted.Body.JsonRaw())
	}
	if got := JsonAsString(defaulted.Body); got != "app.example.com:9443" {
		t.Fatalf("a request with no Host reached the server as %q", got)
	}
	foreign := ApiRequest(server, "GET", "/host", "", nil,
		[]Tuple2[string, string]{{Tuple2First: "Host", Tuple2Second: "evil.example.com"}})
	if foreign.Status.String() != "421" {
		t.Fatalf("an explicit foreign Host must still be refused, got %s", foreign.Status.String())
	}
}
