package teslrt

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"
)

// The two RUNTIME-OWNED routes an `sso "<seg>"` server clause mints: /auth/<seg>/login and
// /auth/<seg>/callback. They are not handlers a program writes, and that is the point — the
// OAuth2/OIDC dance is the runtime's, and what reaches app code is one already-verified
// identity at `onIdentity`.
//
// The shapes here are the ones `dsl/web.rkt` produces, because a test written against one
// backend has to pass on the other: a 303 with Location and Cache-Control: no-store, the
// `__Host-` cookie attributes, and a FIXED failure page that never carries the provider's
// text.

// SsoRoute is one `sso` clause, as the emitted server hands it over. The connection and the
// session key are THUNKS: both read the environment, which a test sets per case, and reading
// them at boot would freeze the first value a process ever saw.
type SsoRoute struct {
	Segment      string
	Connection   func() SsoConnection
	OnIdentity   func(SsoIdentity) string
	SessionKey   func() Secret
	PublicOrigin string
	AfterLogin   string
}

// SetPublicOriginValue is the `publicOrigin` clause, applied at boot. It takes precedence
// over TESL_PUBLIC_ORIGIN, exactly as the Racket parameter does — the clause is compile-time
// validated and the env var is not.
func SetPublicOriginValue(origin string) {
	publicOriginMutex.Lock()
	defer publicOriginMutex.Unlock()
	publicOriginOverride = strings.TrimSpace(origin)
}

const ssoOauthCookieName = "__Host-oauth"

// The in-flight cookie lives ten minutes: long enough for a human to finish a login at the
// provider, short enough that a captured one is not a standing key.
const ssoOauthCookieMaxAge = 600

// ssoRandomToken is a fresh 256-bit value for a `state`, a `nonce` or a PKCE verifier.
func ssoRandomToken() string {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		panic("sso: the system random source is unavailable")
	}
	return base64.RawURLEncoding.EncodeToString(raw)
}

// A `__Host-` cookie line: Path=/ plus Secure plus HttpOnly plus SameSite=Lax. Lax rather
// than Strict so the top-level callback navigation still carries the cookie. No Domain — the
// `__Host-` prefix forbids one, which is the guarantee the prefix buys.
func ssoCookieLine(name, value string, maxAge int) string {
	line := name + "=" + value + "; Path=/; HttpOnly; Secure; SameSite=Lax"
	if maxAge >= 0 {
		line += fmt.Sprintf("; Max-Age=%d", maxAge)
	}
	return line
}

// The redirect the Tesl surface cannot build: 303 plus Location plus no-store plus any
// number of Set-Cookie lines.
func ssoRedirect(writer http.ResponseWriter, location string, cookies []string) {
	for _, cookie := range cookies {
		writer.Header().Add("Set-Cookie", cookie)
	}
	writer.Header().Set("Location", location)
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("Content-Type", "text/plain; charset=utf-8")
	writer.WriteHeader(http.StatusSeeOther)
	_, _ = writer.Write(nil)
}

// A failed flow renders a FIXED page and clears the in-flight cookie — never a JSON error
// body, never a fallthrough to another route, and never the provider's own text.
func ssoFailure(writer http.ResponseWriter) {
	writer.Header().Add("Set-Cookie", ssoCookieLine(ssoOauthCookieName, "", 0))
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("Content-Type", "text/html; charset=utf-8")
	writer.WriteHeader(http.StatusUnauthorized)
	_, _ = writer.Write([]byte("<!doctype html><meta charset=\"utf-8\">" +
		"<title>Sign-in failed</title><p>Sign-in could not be completed. Please try again."))
}

// findSsoMatch resolves /auth/<seg>/login|callback to its route.
func findSsoMatch(routes []SsoRoute, path string) (SsoRoute, string, bool) {
	segments := strings.Split(strings.Trim(path, "/"), "/")
	if len(segments) != 3 || segments[0] != "auth" {
		return SsoRoute{}, "", false
	}
	kind := segments[2]
	if kind != "login" && kind != "callback" {
		return SsoRoute{}, "", false
	}
	for _, route := range routes {
		if route.Segment == segments[1] {
			return route, kind, true
		}
	}
	return SsoRoute{}, "", false
}

func (route SsoRoute) redirectURI() string {
	origin := route.PublicOrigin
	if origin == "" {
		origin = PublicOrigin()
	}
	return strings.TrimRight(origin, "/") + "/auth/" + route.Segment + "/callback"
}

func (route SsoRoute) sessionKeyText() string {
	if route.SessionKey == nil {
		return ""
	}
	return route.SessionKey().Value.Reveal()
}

// sessionKeyCandidates is the [current, previous] pair the in-flight cookie is opened under —
// the SAME helper `JWT.verify` uses, so a `sessionPreviousKey` rotation that keeps existing
// sessions alive also keeps logins that were in flight when the key turned over. Opening
// under the current key only (the earlier shape) failed every such login with "invalid or
// missing login state": fail-closed, but an availability hole exactly during a rotation.
// No configured key answers one empty candidate, which `oauthCookieOpen` skips — fail closed.
func (route SsoRoute) sessionKeyCandidates() []string {
	if route.SessionKey == nil {
		return []string{""}
	}
	return sessionKeys(route.SessionKey())
}

// handleSsoRequest runs one runtime-owned route. A TRAP inside it is a failed sign-in, not a
// 500: the connection thunk reads the environment and `onIdentity` is app code, and neither
// may turn a login into a stack trace on the client.
func handleSsoRequest(route SsoRoute, kind string, writer http.ResponseWriter,
	request *http.Request) {
	defer func() {
		if recovered := recover(); recovered != nil {
			fmt.Fprintf(os.Stderr, "tesl: sso %s failed: %v\n", kind, recovered)
			ssoFailure(writer)
		}
	}()
	if kind == "login" {
		handleSsoLogin(route, writer)
		return
	}
	handleSsoCallback(route, writer, request)
}

func handleSsoLogin(route SsoRoute, writer http.ResponseWriter) {
	authorizeURL, cookie, err := ssoBeginLogin(route.Connection(), route.Segment,
		route.redirectURI(), route.sessionKeyText(),
		ssoRandomToken(), ssoRandomToken(), ssoRandomToken(), time.Now().Unix())
	if err != nil {
		fmt.Fprintf(os.Stderr, "tesl: sso login failed: %v\n", err)
		ssoFailure(writer)
		return
	}
	ssoRedirect(writer, authorizeURL,
		[]string{ssoCookieLine(ssoOauthCookieName, cookie, ssoOauthCookieMaxAge)})
}

func handleSsoCallback(route SsoRoute, writer http.ResponseWriter, request *http.Request) {
	code := request.URL.Query().Get("code")
	presentedState := request.URL.Query().Get("state")
	oauthCookie, err := request.Cookie(ssoOauthCookieName)
	if code == "" || err != nil || oauthCookie.Value == "" {
		fmt.Fprintf(os.Stderr,
			"tesl: sso callback denied (%s): missing authorization code or %s cookie\n",
			route.Segment, ssoOauthCookieName)
		ssoFailure(writer)
		return
	}
	outcome := ssoHandleCallback(route.Connection(), route.Segment, code, oauthCookie.Value,
		route.redirectURI(), route.sessionKeyCandidates(), time.Now().Unix(), presentedState)
	if !outcome.OK {
		// Fail closed to the fixed client page, and log the reason server-side: a silently
		// swallowed callback failure is undebuggable in production.
		fmt.Fprintf(os.Stderr, "tesl: sso callback rejected (%s): %s\n",
			route.Segment, outcome.Reason)
		ssoFailure(writer)
		return
	}
	subject := route.OnIdentity(outcome.Identity)
	token := JwtSign(DictInsert(DictEmpty[string, string](), "sub", subject, stringKeyLess),
		route.SessionKey())
	// The session cookie REPLACES any pre-existing one (session fixation). The in-flight
	// cookie is spent — its sealed verifier and nonce have no further use — so it is cleared
	// here exactly as the failure path clears it.
	ssoRedirect(writer, route.AfterLogin, []string{
		ssoCookieLine(sessionCookieName, token.Value, sessionPolicySeconds()),
		ssoCookieLine(ssoOauthCookieName, "", 0),
	})
}
