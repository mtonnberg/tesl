package teslrt

import "testing"

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
