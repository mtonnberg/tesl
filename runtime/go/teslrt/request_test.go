package teslrt

import "testing"

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
	ClearSessionCookie(scope)
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
	ClearSessionCookie(nil)
}
