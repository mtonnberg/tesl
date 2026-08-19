package teslrt

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

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
