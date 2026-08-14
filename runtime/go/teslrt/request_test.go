package teslrt

import (
	"net/http/httptest"
	"testing"
)

func TestRequestScopeCookies(t *testing.T) {
	scope := NewRequestScope()
	scope.SetCookieHeader("test", "a=1; Path=/")
	scope.SetCookieHeader("test", "b=2; Path=/")
	// Last write per NAME wins, send order otherwise preserved — the rule
	// dsl/response-cookies.rkt states, so set-then-clear emits ONE Set-Cookie.
	scope.SetCookieHeader("test", "a=; Max-Age=0")
	got := scope.CookieHeaders()
	if len(got) != 2 || got[0] != "a=; Max-Age=0" || got[1] != "b=2; Path=/" {
		t.Errorf("cookies = %v", got)
	}
	// The result is a copy: a caller cannot reach the scope's storage.
	got[0] = "mutated"
	if scope.CookieHeaders()[0] == "mutated" {
		t.Error("CookieHeaders must not alias the scope")
	}
}

func TestClearSessionCookieMatchesRacket(t *testing.T) {
	scope := NewRequestScope()
	_ = ClearSessionCookie(scope)
	got := scope.CookieHeaders()
	want := "__Host-session=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0"
	if len(got) != 1 || got[0] != want {
		t.Errorf("clear = %v want %q", got, want)
	}
}

// No live response scope is the Racket condition that raises: startup, `main` and queue
// workers have no response to attach a cookie to.
func TestNilScopePanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("a nil scope must panic rather than silently drop the cookie")
		}
	}()
	_ = ClearSessionCookie(nil)
}

// A repeated query key or header collapses to the LAST value, matching the Racket runtime's
// `for/hash` (which keeps the last binding). The natural Go spelling — `Query().Get` — answers
// the FIRST, so this is pinned rather than left to the standard library's preference.
func TestRepeatedQueryAndHeaderAreLastWins(t *testing.T) {
	raw := httptest.NewRequest("GET", "/search?q=first&q=second&other=beta", nil)
	raw.Header.Add("X-Trace", "one")
	raw.Header.Add("X-Trace", "two")
	request := NewHttpRequest(raw, "")

	lookup := func(where Dict[string, string], key string) Maybe[string] {
		return DictLookup(where, key, stringKeyLess)
	}
	expect := func(label string, got Maybe[string], want string) {
		t.Helper()
		value, found := got.Value()
		if !found || value != want {
			t.Fatalf("%s = %q (found %v), want %q", label, value, found, want)
		}
	}
	expect("q", lookup(request.QueryParameters, "q"), "second")
	expect("other", lookup(request.QueryParameters, "other"), "beta")
	expect("x-trace", lookup(request.Headers, "x-trace"), "two")
	// A bare `?k` is the empty string, not a missing key.
	bare := NewHttpRequest(httptest.NewRequest("GET", "/search?k", nil), "")
	expect("bare key", lookup(bare.QueryParameters, "k"), "")
}
