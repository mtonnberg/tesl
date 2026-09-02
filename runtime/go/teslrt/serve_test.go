package teslrt

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func mountedResponse(t *testing.T, server Server, options ServeOptions, path string) *http.Response {
	t.Helper()
	recorder := httptest.NewRecorder()
	server.handlerWith(options).ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
	return recorder.Result()
}

func responseText(t *testing.T, response *http.Response) string {
	t.Helper()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	return string(body)
}

func TestHandlerWithMountsOnlyTheDeclaredAPI(t *testing.T) {
	server := testServer()
	options := ServeOptions{MountPath: "/api"}

	mounted := mountedResponse(t, server, options, "/api/hello")
	if mounted.StatusCode != http.StatusOK || !strings.Contains(responseText(t, mounted), `"message":"hi"`) {
		t.Errorf("mounted API response = %d", mounted.StatusCode)
	}
	if got := mountedResponse(t, server, options, "/hello").StatusCode; got != http.StatusNotFound {
		t.Errorf("unmounted API status = %d, want 404", got)
	}
	if got := mountedResponse(t, server, options, "/api").StatusCode; got != http.StatusNotFound {
		t.Errorf("mount root status = %d, want 404", got)
	}
}

func TestHandlerWithMountUsesSegmentBoundaries(t *testing.T) {
	server := Server{
		Routes: []Route{{Method: http.MethodGet, Path: "/x/hello", Endpoint: "boundary"}},
		Handlers: map[string]HandlerFunc{"boundary": func(_ *RequestScope, _ *http.Request) Response {
			return Response{Status: http.StatusOK, Body: "wrong mount"}
		}},
	}
	if got := mountedResponse(t, server, ServeOptions{MountPath: "/api"}, "/apix/hello").StatusCode; got != http.StatusNotFound {
		t.Errorf("non-segment prefix status = %d, want 404", got)
	}
}

func TestHandlerWithComposesMountedAPIAndRawSPA(t *testing.T) {
	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, "index.html"), []byte("SPA-INDEX"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "asset.txt"), []byte("STATIC-ASSET"), 0o600); err != nil {
		t.Fatal(err)
	}
	server := testServer()
	options := ServeOptions{MountPath: "/api", StaticDir: directory}

	for _, testCase := range []struct {
		path, body string
	}{
		{"/", "SPA-INDEX"},
		{"/asset.txt", "STATIC-ASSET"},
		{"/client/route", "SPA-INDEX"},
		{"/hello", "SPA-INDEX"},
		{"/api/hello", `"message":"hi"`},
	} {
		response := mountedResponse(t, server, options, testCase.path)
		body := responseText(t, response)
		if response.StatusCode != http.StatusOK || !strings.Contains(body, testCase.body) {
			t.Errorf("GET %s = %d %q, want 200 containing %q", testCase.path, response.StatusCode, body, testCase.body)
		}
	}
}

func TestHandlerWithPreservesMountedHealthHostExemption(t *testing.T) {
	t.Cleanup(func() { SetPublicOriginValue(""); SetHealthProbePath("") })
	SetPublicOriginValue("https://app.example.test")
	SetHealthProbePath("/healthz")
	server := Server{
		Routes: []Route{
			{Method: http.MethodGet, Path: "/healthz", Endpoint: "health"},
			{Method: http.MethodGet, Path: "/hello", Endpoint: "hello"},
		},
		Handlers: map[string]HandlerFunc{
			"health": func(_ *RequestScope, _ *http.Request) Response { return Response{Status: 200, Body: "ok"} },
			"hello":  func(_ *RequestScope, _ *http.Request) Response { return Response{Status: 200, Body: "hello"} },
		},
	}
	handler := server.handlerWith(ServeOptions{MountPath: "/api"})
	request := func(path string) int {
		recorder := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.Host = "evil.example.test"
		handler.ServeHTTP(recorder, req)
		return recorder.Code
	}
	if got := request("/api/healthz"); got != http.StatusOK {
		t.Errorf("mounted health status = %d, want 200", got)
	}
	if got := request("/api/hello"); got != http.StatusMisdirectedRequest {
		t.Errorf("ordinary mounted API status = %d, want 421", got)
	}
}

func TestHandlerWithKeepsSsoRawAndApiMounted(t *testing.T) {
	server := testServer()
	server.SsoRoutes = []SsoRoute{{
		Segment:    "idp",
		Connection: func() SsoConnection { panic("matched raw SSO route") },
	}}
	options := ServeOptions{MountPath: "/api"}

	for _, path := range []string{"/auth/idp/login", "/auth/idp/callback"} {
		if got := mountedResponse(t, server, options, path).StatusCode; got == http.StatusNotFound {
			t.Errorf("raw SSO path %s was not matched", path)
		}
	}
	if got := mountedResponse(t, server, options, "/api/auth/idp/login").StatusCode; got != http.StatusNotFound {
		t.Errorf("mounted SSO status = %d, want 404", got)
	}
	if got := mountedResponse(t, server, options, "/api/hello").StatusCode; got != http.StatusOK {
		t.Errorf("mounted API alongside SSO status = %d, want 200", got)
	}
}

func TestHandlerWithSsoPrecedesStaticFallback(t *testing.T) {
	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, "index.html"), []byte("SPA-INDEX"), 0o600); err != nil {
		t.Fatal(err)
	}
	server := testServer()
	server.SsoRoutes = []SsoRoute{{
		Segment:    "idp",
		Connection: func() SsoConnection { panic("matched raw SSO route") },
	}}
	response := mountedResponse(t, server, ServeOptions{StaticDir: directory}, "/auth/idp/login")
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("SSO route status = %d, want 401", response.StatusCode)
	}
	if body := responseText(t, response); strings.Contains(body, "SPA-INDEX") {
		t.Fatal("SSO route fell through to the static SPA")
	}
}

// The response-header floor. Each of these headers exists because `dsl/web.rkt` adds it to every
// response, and a Go-served deployment that carried none was a security regression the corpus
// could not see: no api-test asserts a header the program did not set.

func TestSecurityHeaderFloorOnJSON(t *testing.T) {
	t.Cleanup(func() { SetPublicOriginValue(""); SetContentSecurityPolicy("") })
	recorder := httptest.NewRecorder()
	writer := &hardenedWriter{ResponseWriter: recorder}
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(200)

	for name, want := range map[string]string{
		"X-Content-Type-Options": "nosniff",
		"Referrer-Policy":        "no-referrer",
		"X-Frame-Options":        "DENY",
		// A JSON API answers session-bearing data, so a shared cache must not keep it.
		"Cache-Control": "no-store",
	} {
		if got := recorder.Header().Get(name); got != want {
			t.Errorf("%s = %q, want %q", name, got, want)
		}
	}
	// A CSP is meaningful for a document only.
	if got := recorder.Header().Get("Content-Security-Policy"); got != "" {
		t.Errorf("a JSON response carries a CSP: %q", got)
	}
}

func TestSecurityHeaderFloorOnHTML(t *testing.T) {
	t.Cleanup(func() { SetContentSecurityPolicy("") })
	recorder := httptest.NewRecorder()
	writer := &hardenedWriter{ResponseWriter: recorder}
	writer.Header().Set("Content-Type", "text/html; charset=utf-8")
	writer.WriteHeader(200)

	if got := recorder.Header().Get("Content-Security-Policy"); got != "frame-ancestors 'none'" {
		t.Errorf("default CSP = %q", got)
	}
	// `no-store` is the JSON API's rule; a static asset stays cacheable, as on Racket.
	if got := recorder.Header().Get("Cache-Control"); got != "" {
		t.Errorf("an HTML response carries no-store: %q", got)
	}
}

// The clause WINS over the default, and a header the producer set wins over both: a handler that
// chose its own policy means it.
func TestContentSecurityPolicyPrecedence(t *testing.T) {
	t.Cleanup(func() { SetContentSecurityPolicy("") })
	SetContentSecurityPolicy("default-src 'self'")

	recorder := httptest.NewRecorder()
	writer := &hardenedWriter{ResponseWriter: recorder}
	writer.Header().Set("Content-Type", "text/html")
	writer.WriteHeader(200)
	if got := recorder.Header().Get("Content-Security-Policy"); got != "default-src 'self'" {
		t.Errorf("clause CSP = %q", got)
	}

	producer := httptest.NewRecorder()
	chosen := &hardenedWriter{ResponseWriter: producer}
	chosen.Header().Set("Content-Type", "text/html")
	chosen.Header().Set("Content-Security-Policy", "frame-ancestors https://example.test")
	chosen.WriteHeader(200)
	if got := producer.Header().Get("Content-Security-Policy"); got != "frame-ancestors https://example.test" {
		t.Errorf("a producer-set CSP was overridden: %q", got)
	}
}

// HSTS comes from the CONFIGURED origin and nowhere else: a request Host is untrusted and absent
// behind a proxy, and the header is close to irreversible once a browser has seen it.
func TestHstsOnlyFromConfiguredHttpsOrigin(t *testing.T) {
	t.Cleanup(func() { SetPublicOriginValue("") })
	for _, testCase := range []struct {
		origin string
		want   string
	}{
		{"https://app.example.test", "max-age=31536000"},
		{"http://app.example.test", ""},
		{"https://localhost:8443", ""},
		{"https://127.0.0.1:8443", ""},
		{"", ""},
	} {
		SetPublicOriginValue(testCase.origin)
		recorder := httptest.NewRecorder()
		writer := &hardenedWriter{ResponseWriter: recorder}
		writer.Header().Set("Content-Type", "application/json")
		writer.WriteHeader(200)
		if got := recorder.Header().Get("Strict-Transport-Security"); got != testCase.want {
			t.Errorf("origin %q: HSTS = %q, want %q", testCase.origin, got, testCase.want)
		}
	}
}

// The floor must not cost SSE its streaming: a wrapper without Flush turns every event into
// buffered output that arrives at the end.
func TestHardenedWriterPassesFlushThrough(t *testing.T) {
	recorder := httptest.NewRecorder()
	writer := &hardenedWriter{ResponseWriter: recorder}
	flusher, canFlush := any(writer).(http.Flusher)
	if !canFlush {
		t.Fatal("the hardened writer is not an http.Flusher")
	}
	if _, err := writer.Write([]byte("data: one\n\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	flusher.Flush()
	if !recorder.Flushed {
		t.Error("Flush did not reach the underlying writer")
	}
}

// Risk 50/60: a load balancer probes host-blind, so exactly one declared path is exempt from the
// Host check — and only from THAT check.
func TestHealthProbePathExemptFromHostCheck(t *testing.T) {
	t.Cleanup(func() { SetPublicOriginValue(""); SetHealthProbePath("") })
	SetPublicOriginValue("https://app.example.test")
	SetHealthProbePath("/healthz")

	probe := httptest.NewRequest("GET", "http://10.0.0.7/healthz", nil)
	if _, refused := requestRefusal(probe); refused {
		t.Error("the declared health probe path was refused")
	}
	other := httptest.NewRequest("GET", "http://10.0.0.7/orders", nil)
	refusal, refused := requestRefusal(other)
	if !refused || refusal.Status != 421 {
		t.Errorf("a mismatched Host on an ordinary path: refused=%v status=%d", refused, refusal.Status)
	}
	// The exemption is Host-only: the cross-site guard still applies to a state-changing method.
	crossSite := httptest.NewRequest("POST", "http://10.0.0.7/healthz", nil)
	crossSite.Header.Set("Sec-Fetch-Site", "cross-site")
	refusal, refused = requestRefusal(crossSite)
	if !refused || refusal.Status != 403 {
		t.Errorf("a cross-site POST to the probe path: refused=%v status=%d", refused, refusal.Status)
	}
}

// `listenAddress Loopback` is the difference between a service a reverse proxy reaches and one the
// whole network reaches. The clause has to arrive at the bind address.
func TestListenAddressReachesTheBindAddress(t *testing.T) {
	for _, testCase := range []struct {
		address string
		want    string
	}{
		{"127.0.0.1", "127.0.0.1:8080"},
		{"", ":8080"},
	} {
		options := ServeOptions{Port: 8080, ListenAddress: testCase.address}
		if got := bindAddress(options); got != testCase.want {
			t.Errorf("ListenAddress %q: bind %q, want %q", testCase.address, got, testCase.want)
		}
	}
}

// The body cap: the whole body is read into memory and parsed, so an uncapped read is a
// one-request memory exhaustion. Same default and same status as `dsl/web.rkt`.
func TestReadRequestBodyCap(t *testing.T) {
	t.Setenv("TESL_MAX_BODY_BYTES", "")
	limit := maxRequestBodyBytes()

	atLimit := httptest.NewRequest("POST", "/", strings.NewReader(strings.Repeat("x", limit)))
	body, status, _ := ReadRequestBody(atLimit)
	if status != 0 || len(body) != limit {
		t.Errorf("a body exactly at the cap: status=%d len=%d", status, len(body))
	}

	overLimit := httptest.NewRequest("POST", "/", strings.NewReader(strings.Repeat("x", limit+1)))
	_, status, message := ReadRequestBody(overLimit)
	if status != 413 || message != "Request body too large" {
		t.Errorf("a body over the cap: status=%d message=%q", status, message)
	}
}

// staticFixture builds a static root holding an index, a real asset, two dotfiles and two
// symlinks that leave the root — the shapes the review found served (M5).
func staticFixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	outside := t.TempDir()
	write := func(name, content string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(name), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(name, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(root, "index.html"), "<html>index</html>")
	write(filepath.Join(root, "asset.txt"), "STATIC-ASSET")
	write(filepath.Join(root, ".env"), "DB_PASSWORD=hunter2")
	write(filepath.Join(root, ".git", "config"), "[core]")
	write(filepath.Join(outside, "secret.txt"), "SECRET OUTSIDE ROOT")
	if err := os.Symlink(filepath.Join(outside, "secret.txt"), filepath.Join(root, "link.txt")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "linkdir")); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestServeStaticRefusesDotfilesAndSymlinksOutOfRoot(t *testing.T) {
	root := staticFixture(t)
	server := testServer()
	options := ServeOptions{StaticDir: root}
	// A dotfile path is refused outright: not the file, and not the SPA either — the router's
	// own JSON 404 is the honest answer for `/.env`.
	for _, refused := range []string{"/.env", "/.git/config", "/sub/.hidden"} {
		response := mountedResponse(t, server, options, refused)
		body := responseText(t, response)
		if strings.Contains(body, "hunter2") || strings.Contains(body, "[core]") {
			t.Errorf("GET %s served the file: %q", refused, body)
		}
		if response.StatusCode != http.StatusNotFound || !strings.Contains(response.Header.Get("Content-Type"), "application/json") {
			t.Errorf("GET %s = %d %s, want the JSON 404", refused, response.StatusCode, response.Header.Get("Content-Type"))
		}
	}
	// A symlink that resolves outside the root is treated as a file that is not there, which
	// under a SPA root means the index — what any unknown client-side route gets. The target's
	// contents never appear.
	for _, escaped := range []string{"/link.txt", "/linkdir/secret.txt"} {
		response := mountedResponse(t, server, options, escaped)
		body := responseText(t, response)
		if strings.Contains(body, "SECRET") {
			t.Errorf("GET %s followed the symlink out of the root: %q", escaped, body)
		}
		if response.StatusCode != http.StatusOK || body != "<html>index</html>" {
			t.Errorf("GET %s = %d %q, want the SPA index like any unknown path", escaped, response.StatusCode, body)
		}
	}
	// The ordinary surface is intact: a real file, the index and the SPA fallback.
	for path, want := range map[string]string{"/asset.txt": "STATIC-ASSET", "/": "<html>index</html>", "/client/route": "<html>index</html>"} {
		response := mountedResponse(t, server, options, path)
		if body := responseText(t, response); response.StatusCode != http.StatusOK || body != want {
			t.Errorf("GET %s = %d %q, want 200 %q", path, response.StatusCode, body, want)
		}
	}
}

// A root that is itself a symlink (a `current -> release-N` deploy) still contains its own
// files: containment is decided on RESOLVED paths on both sides.
func TestServeStaticResolvesASymlinkedRoot(t *testing.T) {
	root := staticFixture(t)
	linkedRoot := filepath.Join(t.TempDir(), "current")
	if err := os.Symlink(root, linkedRoot); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	response := mountedResponse(t, testServer(), ServeOptions{StaticDir: linkedRoot}, "/asset.txt")
	if body := responseText(t, response); response.StatusCode != http.StatusOK || body != "STATIC-ASSET" {
		t.Errorf("GET /asset.txt through a symlinked root = %d %q", response.StatusCode, body)
	}
	response = mountedResponse(t, testServer(), ServeOptions{StaticDir: linkedRoot}, "/link.txt")
	if body := responseText(t, response); strings.Contains(body, "SECRET") {
		t.Errorf("a symlink out of a symlinked root was served: %q", body)
	}
}

// Under the mount prefix the declared API is the only surface: a mistyped `/api/nothing` is the
// API's JSON 404, never index.html with a 200. Raw paths keep the SPA fallback.
func TestHandlerWithMountedMissAnswersJSON404(t *testing.T) {
	root := staticFixture(t)
	server := testServer()
	options := ServeOptions{MountPath: "/api", StaticDir: root}
	for _, path := range []string{"/api/nothing", "/api", "/api/"} {
		response := mountedResponse(t, server, options, path)
		body := responseText(t, response)
		if response.StatusCode != http.StatusNotFound || !strings.Contains(response.Header.Get("Content-Type"), "application/json") ||
			!strings.Contains(body, `"error":"not found"`) {
			t.Errorf("GET %s = %d %s %q, want the JSON 404", path, response.StatusCode, response.Header.Get("Content-Type"), body)
		}
	}
	// A wrong method under the mount is the API's 405, not the SPA.
	recorder := httptest.NewRecorder()
	server.handlerWith(options).ServeHTTP(recorder, httptest.NewRequest(http.MethodDelete, "/api/hello", nil))
	if recorder.Code != http.StatusMethodNotAllowed || recorder.Header().Get("Allow") == "" {
		t.Errorf("DELETE /api/hello = %d Allow=%q", recorder.Code, recorder.Header().Get("Allow"))
	}
	mounted := mountedResponse(t, server, options, "/api/hello")
	if body := responseText(t, mounted); mounted.StatusCode != http.StatusOK || !strings.Contains(body, `"message":"hi"`) {
		t.Errorf("GET /api/hello = %d %q", mounted.StatusCode, body)
	}
	spa := mountedResponse(t, server, options, "/client/route")
	if body := responseText(t, spa); spa.StatusCode != http.StatusOK || body != "<html>index</html>" {
		t.Errorf("raw SPA route = %d %q", spa.StatusCode, body)
	}
}

// The CSRF guard without Fetch Metadata (review M6): the initiator the request names — Origin,
// else Referer — is compared against the configured public origin's host.
func TestCrossSiteRefusalFallsBackToOriginAndReferer(t *testing.T) {
	t.Cleanup(func() { SetPublicOriginValue("") })
	SetPublicOriginValue("https://app.example.test")
	post := func(headers map[string]string) (Response, bool) {
		request := httptest.NewRequest(http.MethodPost, "https://app.example.test/orders", nil)
		for name, value := range headers {
			request.Header.Set(name, value)
		}
		return requestRefusal(request)
	}
	refuses := func(who string, headers map[string]string) {
		t.Helper()
		if refusal, refused := post(headers); !refused || refusal.Status != 403 {
			t.Errorf("%s: refused=%v status=%d, want 403", who, refused, refusal.Status)
		}
	}
	passes := func(who string, headers map[string]string) {
		t.Helper()
		if refusal, refused := post(headers); refused {
			t.Errorf("%s: refused with %d, want to pass", who, refusal.Status)
		}
	}
	refuses("Origin from another site", map[string]string{"Origin": "https://evil.example"})
	refuses("Referer from another site", map[string]string{"Referer": "https://evil.example/form"})
	refuses("opaque Origin", map[string]string{"Origin": "null"})
	refuses("explicit cross-site", map[string]string{"Sec-Fetch-Site": "cross-site", "Origin": "https://app.example.test"})
	passes("same-host Origin", map[string]string{"Origin": "https://app.example.test"})
	passes("same-host Origin on another port", map[string]string{"Origin": "https://app.example.test:8443"})
	passes("same-host Referer", map[string]string{"Referer": "https://app.example.test/page"})
	// Origin wins over Referer when both are present.
	passes("Origin over a stale Referer", map[string]string{"Origin": "https://app.example.test", "Referer": "https://evil.example/"})
	// A browser that sent Fetch Metadata has vouched for the request; the fallback is not consulted.
	passes("same-origin per the browser", map[string]string{"Sec-Fetch-Site": "same-origin"})
	// Neither header: curl and service clients look like this, and refusing them protects nothing.
	passes("no initiator headers", map[string]string{})

	// With NO public origin configured the initiator is ignored: the only other reference would be
	// the request's own Host, which nothing validates without a public origin, so the comparison
	// would be between two values the same client chose.
	SetPublicOriginValue("")
	passes("Origin ignored without a public origin", map[string]string{"Origin": "https://evil.example"})
	refuses("explicit cross-site still refused without a public origin", map[string]string{"Sec-Fetch-Site": "cross-site"})
}
