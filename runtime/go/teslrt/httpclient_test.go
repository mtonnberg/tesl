package teslrt

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func noHeaders() []Tuple2[string, string] { return []Tuple2[string, string]{} }

func header(name, value string) Tuple2[string, string] {
	return Tuple2[string, string]{Tuple2First: name, Tuple2Second: value}
}

// A local httptest server IS loopback, which egress containment allows in a non-deployed
// build — so the whole client path (dial, egress judgement, request, capped body read) is
// exercised here rather than mocked.
func TestHttpGetReadsStatusBodyAndHeaders(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Accept"); got != "application/json" {
			t.Errorf("Accept header = %q, want application/json", got)
		}
		w.Header().Set("X-Answer", "42")
		w.WriteHeader(201)
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer upstream.Close()

	response := HttpGet(upstream.URL, []Tuple2[string, string]{header("Accept", "application/json")})
	if value, _ := response.Status.Int64(); value != 201 {
		t.Fatalf("status = %s, want 201", response.Status.String())
	}
	if response.Body != `{"ok":true}` {
		t.Fatalf("body = %q", response.Body)
	}
	found := false
	for _, pair := range response.Headers {
		if pair.Tuple2First == "X-Answer" && pair.Tuple2Second == "42" {
			found = true
		}
	}
	if !found {
		t.Fatalf("response headers %v do not carry X-Answer", response.Headers)
	}
}

func TestHttpClientPropagatesTraceparentWhenTracingEnabled(t *testing.T) {
	seen := make(chan string, 1)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen <- r.Header.Get("traceparent")
		w.WriteHeader(http.StatusNoContent)
	}))
	defer upstream.Close()
	_ = InitTelemetry("trace-test", "in-memory", false, true, true, 60000, 1.0)
	t.Cleanup(func() { _ = InitTelemetry("tesl", "in-memory", false, true, false, 60000, 1.0) })
	_ = HttpGet(upstream.URL, noHeaders())
	value := <-seen
	if len(value) != len("00-")+32+1+16+3 || !strings.HasPrefix(value, "00-") || !strings.HasSuffix(value, "-01") {
		t.Fatalf("traceparent = %q", value)
	}
}

func TestHttpPostPutDeleteSendMethodAndBody(t *testing.T) {
	var seenMethod, seenBody string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenMethod = r.Method
		raw := make([]byte, 256)
		count, _ := r.Body.Read(raw)
		seenBody = string(raw[:count])
		w.WriteHeader(204)
	}))
	defer upstream.Close()

	if _ = HttpPost(upstream.URL, noHeaders(), "posted"); seenMethod != "POST" || seenBody != "posted" {
		t.Fatalf("POST sent %s %q", seenMethod, seenBody)
	}
	if _ = HttpPut(upstream.URL, noHeaders(), "put"); seenMethod != "PUT" || seenBody != "put" {
		t.Fatalf("PUT sent %s %q", seenMethod, seenBody)
	}
	if _ = HttpDelete(upstream.URL, noHeaders()); seenMethod != "DELETE" {
		t.Fatalf("DELETE sent %s", seenMethod)
	}
}

// A CR or LF in a header field would end the field and let the rest be read as further
// headers or a second request, so it is refused before anything is sent.
func TestOutboundHeaderCRLFIsRejected(t *testing.T) {
	for _, bad := range []Tuple2[string, string]{
		header("X-Evil\r\nInjected", "value"),
		header("X-Evil", "value\r\nInjected: yes"),
		header("X-Evil", "value\nInjected: yes"),
	} {
		func() {
			defer func() {
				recovered := recover()
				if recovered == nil {
					t.Fatalf("header %v was accepted", bad)
				}
				if !strings.Contains(fmt.Sprint(recovered), "header injection rejected") {
					t.Fatalf("trap = %q", fmt.Sprint(recovered))
				}
			}()
			_ = HttpGet("http://127.0.0.1:1/", []Tuple2[string, string]{bad})
		}()
	}
}

func TestOutboundURLIsValidated(t *testing.T) {
	for _, target := range []string{"file:///etc/passwd", "ftp://example.com/x", "not a url",
		"http://", "://nope"} {
		func() {
			defer func() {
				if recover() == nil {
					t.Fatalf("URL %q was accepted", target)
				}
			}()
			_ = HttpGet(target, noHeaders())
		}()
	}
}

// The response-body cap bounds what a hostile upstream can make the process allocate.
func TestResponseBodyCapIsEnforced(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(strings.Repeat("x", 4096)))
	}))
	defer upstream.Close()
	t.Setenv("TESL_HTTP_MAX_RESPONSE_BYTES", "512")
	defer func() {
		recovered := recover()
		if recovered == nil {
			t.Fatal("an oversized response body was accepted")
		}
		if !strings.Contains(fmt.Sprint(recovered), "exceeds the 512-byte cap") {
			t.Fatalf("trap = %q", fmt.Sprint(recovered))
		}
	}()
	_ = HttpGet(upstream.URL, noHeaders())
}

// A refused connection is a clean HttpClient failure, never a raw Go error escaping into the
// program: inside a worker that is what turns into a failed job.
func TestUnreachableUpstreamTrapsCleanly(t *testing.T) {
	defer func() {
		recovered := recover()
		if recovered == nil {
			t.Fatal("a refused connection did not trap")
		}
		if !strings.HasPrefix(fmt.Sprint(recovered), "HttpClient: HTTP GET to ") {
			t.Fatalf("trap = %q", fmt.Sprint(recovered))
		}
	}()
	// Port 1 on loopback: nothing listens, and egress to loopback is allowed, so the failure
	// is the connection's rather than the guard's.
	_ = HttpGet("http://127.0.0.1:1/", noHeaders())
}

// Egress containment judges the address CONNECTED TO. In a deployed build loopback is
// refused, which is the only forbidden range a unit test can dial without a network.
func TestSsrfContainmentRefusesTheDial(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(200)
	}))
	defer upstream.Close()
	t.Setenv("TESL_DEPLOYED", "1")
	defer func() {
		recovered := recover()
		if recovered == nil {
			t.Fatal("a deployed build dialed loopback")
		}
		if !strings.Contains(fmt.Sprint(recovered), "SSRF: refused egress to") {
			t.Fatalf("trap = %q", fmt.Sprint(recovered))
		}
	}()
	_ = HttpGet(upstream.URL, noHeaders())
}

// `HttpClient.bearer` is the sanctioned way a secret reaches the wire. What the program can
// see is a redacted handle; what the socket gets is the plaintext.
func TestBearerHeaderHidesThePlaintextButSendsIt(t *testing.T) {
	var seen string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = r.Header.Get("Authorization")
		w.WriteHeader(200)
	}))
	defer upstream.Close()

	authorization := HttpBearer(MakeSecret("sk-live-secret"))
	if authorization.Tuple2First != "Authorization" {
		t.Fatalf("header name = %q", authorization.Tuple2First)
	}
	if strings.Contains(authorization.Tuple2Second, "sk-live-secret") {
		t.Fatalf("the header value carries the plaintext: %q", authorization.Tuple2Second)
	}
	if !strings.HasPrefix(authorization.Tuple2Second, SecretRedaction) {
		t.Fatalf("the header value does not read as redacted: %q", authorization.Tuple2Second)
	}
	_ = HttpGet(upstream.URL, []Tuple2[string, string]{authorization})
	if seen != "Bearer sk-live-secret" {
		t.Fatalf("Authorization on the wire = %q", seen)
	}
}

func TestSecretHeaderCarriesTheSecretUnderItsOwnName(t *testing.T) {
	var seen string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = r.Header.Get("X-Api-Key")
		w.WriteHeader(200)
	}))
	defer upstream.Close()
	_ = HttpGet(upstream.URL, []Tuple2[string, string]{
		HttpSecretHeader("X-Api-Key", MakeSecret("k-123")),
	})
	if seen != "k-123" {
		t.Fatalf("X-Api-Key on the wire = %q", seen)
	}
}

// A handle is unguessable, so a program cannot manufacture one from user input and make the
// client send OUR secret somewhere else. A forged-looking one names no plaintext and fails.
func TestForgedSecretHeaderHandleFails(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("a forged secret-header handle was accepted")
		}
	}()
	_ = HttpGet("http://127.0.0.1:1/",
		[]Tuple2[string, string]{header("Authorization", SecretRedaction+"\x00forged:1")})
}

// A real deadline must produce the message the STUB produces, or a test written against
// `stubHttpTimeout` would describe something production never logs.
func TestTimeoutMessageMatchesTheStubsWording(t *testing.T) {
	blocked := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		<-blocked
		w.WriteHeader(200)
	}))
	defer func() { close(blocked); upstream.Close() }()
	t.Setenv("TESL_HTTP_TIMEOUT_MS", "60")
	defer func() {
		recovered := recover()
		if recovered == nil {
			t.Fatal("a hung upstream did not trap")
		}
		want := "HttpClient: HTTP GET to " + upstream.URL + " timed out after 60ms"
		if fmt.Sprint(recovered) != want {
			t.Fatalf("trap = %q, want %q", fmt.Sprint(recovered), want)
		}
	}()
	_ = HttpGet(upstream.URL, noHeaders())
}

// The egress refusal is raised inside the dialer, so it arrives buried in a dial error. It is
// a refusal rather than a transport fault, and must read as one.
func TestSsrfRefusalReadsAsARefusal(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(200)
	}))
	defer upstream.Close()
	t.Setenv("TESL_DEPLOYED", "1")
	defer func() {
		recovered := recover()
		if recovered == nil {
			t.Fatal("a deployed build dialed loopback")
		}
		if !strings.HasPrefix(fmt.Sprint(recovered), "HttpClient: SSRF: refused egress to ") {
			t.Fatalf("trap = %q", fmt.Sprint(recovered))
		}
		if !strings.HasSuffix(fmt.Sprint(recovered), "which is loopback 127.0.0.0/8") {
			t.Fatalf("trap = %q", fmt.Sprint(recovered))
		}
	}()
	_ = HttpGet(upstream.URL, noHeaders())
}

// ── Redirects ─────────────────────────────────────────────────────────────────

// redirectTo is a bare 3xx: Location plus status, without http.Redirect's request-relative
// URL resolution (these targets are absolute).
func redirectTo(w http.ResponseWriter, location string, status int) {
	w.Header().Set("Location", location)
	w.WriteHeader(status)
}

// A second loopback server standing in for "another host": it records whether anything
// reached it and what `X-Api-Key` it saw. Its URL is re-spelled with `localhost` so the
// redirect target differs from the first server in HOSTNAME, not only in port.
func otherHost(t *testing.T) (*httptest.Server, string, *atomic.Int32, *atomic.Value) {
	t.Helper()
	var hits atomic.Int32
	var apiKey atomic.Value
	apiKey.Store("")
	second := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		apiKey.Store(r.Header.Get("X-Api-Key"))
		w.WriteHeader(200)
	}))
	t.Cleanup(second.Close)
	return second, "http://localhost" + strings.TrimPrefix(second.URL, "http://127.0.0.1"), &hits, &apiKey
}

// Go strips `Authorization` and `Cookie` on a domain change but forwards every other header,
// so `HttpClient.secretHeader "X-Api-Key" k` followed a 302 to whatever host it named. The
// call now fails before the second host is dialled, and the key never leaves the origin it
// was attached for.
func TestRedirectWithSecretHeadersToAnotherHostIsRefused(t *testing.T) {
	_, otherURL, hits, apiKey := otherHost(t)
	first := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		redirectTo(w, otherURL+"/leak", http.StatusFound)
	}))
	defer first.Close()

	message := trapMessage(t, func() {
		_ = HttpGet(first.URL, []Tuple2[string, string]{
			HttpSecretHeader("X-Api-Key", MakeSecret("sk-live-apikey")),
			header("Accept", "application/json"),
		})
	})
	if !strings.HasPrefix(message, "HttpClient: refused redirect to "+otherURL+"/leak") ||
		!strings.Contains(message, "secret headers (X-Api-Key)") {
		t.Fatalf("trap = %q", message)
	}
	if strings.Contains(message, "sk-live-apikey") {
		t.Fatalf("the trap disclosed the secret: %q", message)
	}
	if hits.Load() != 0 || apiKey.Load() != "" {
		t.Fatalf("the other host was reached (%d hits) and saw X-Api-Key=%q", hits.Load(), apiKey.Load())
	}
}

// The same rule for `HttpClient.bearer`, and a POST: the method does not matter, the secret
// does.
func TestRedirectWithBearerToAnotherHostIsRefused(t *testing.T) {
	_, otherURL, hits, _ := otherHost(t)
	first := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		redirectTo(w, otherURL+"/", http.StatusTemporaryRedirect)
	}))
	defer first.Close()
	message := trapMessage(t, func() {
		_ = HttpPost(first.URL, []Tuple2[string, string]{HttpBearer(MakeSecret("tok"))}, "body")
	})
	if !strings.Contains(message, "refused redirect") || !strings.Contains(message, "(Authorization)") {
		t.Fatalf("trap = %q", message)
	}
	if hits.Load() != 0 {
		t.Fatal("the other host was reached")
	}
}

// Without secret headers a cross-host redirect is ordinary web behaviour and is followed;
// and WITH them a same-origin redirect is followed too, credential intact — the rule is about
// where a secret may travel, not about redirects as such.
func TestRedirectWithoutSecretsIsFollowedAndSameOriginKeepsThem(t *testing.T) {
	_, otherURL, hits, _ := otherHost(t)
	var seenAuthorization atomic.Value
	seenAuthorization.Store("")
	var origin *httptest.Server
	origin = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/away":
			redirectTo(w, otherURL+"/", http.StatusFound)
		case "/start":
			redirectTo(w, origin.URL+"/final", http.StatusFound)
		default:
			seenAuthorization.Store(r.Header.Get("Authorization"))
			_, _ = w.Write([]byte("final"))
		}
	}))
	defer origin.Close()

	if status, _ := HttpGet(origin.URL+"/away", noHeaders()).Status.Int64(); status != 200 || hits.Load() != 1 {
		t.Fatalf("a secret-free cross-host redirect was not followed: status %d, %d hits", status, hits.Load())
	}
	response := HttpGet(origin.URL+"/start", []Tuple2[string, string]{HttpBearer(MakeSecret("tok"))})
	if response.Body != "final" {
		t.Fatalf("a same-origin redirect was not followed: body %q", response.Body)
	}
	if seenAuthorization.Load() != "Bearer tok" {
		t.Fatalf("the credential did not survive a same-origin redirect: %q", seenAuthorization.Load())
	}
}

// Go never refuses a scheme downgrade on its own; a bearer token would travel in cleartext on
// the second hop. The TLS half runs against a self-signed httptest certificate, which is what
// the loopback-only development escape exists for.
func TestRedirectFromHttpsToHttpIsRefused(t *testing.T) {
	plain := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(200)
	}))
	defer plain.Close()
	var plainHits atomic.Int32
	plainCounting := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		plainHits.Add(1)
		w.WriteHeader(200)
	}))
	defer plainCounting.Close()
	secure := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		redirectTo(w, plainCounting.URL+"/downgraded", http.StatusFound)
	}))
	defer secure.Close()
	t.Setenv("TESL_HTTP_TLS_INSECURE_DEV", "1")

	message := trapMessage(t, func() { _ = HttpGet(secure.URL, noHeaders()) })
	if !strings.HasPrefix(message, "HttpClient: refused redirect from "+secure.URL) ||
		!strings.Contains(message, "not downgraded to http") {
		t.Fatalf("trap = %q", message)
	}
	if plainHits.Load() != 0 {
		t.Fatal("the http target of an https redirect was reached")
	}
	// Control: the escape itself works, so the refusal above was the policy's and not a
	// certificate failure.
	if status, _ := HttpGet(plain.URL, noHeaders()).Status.Int64(); status != 200 {
		t.Fatalf("plain control status = %d", status)
	}
}

// Five hops, not Go's ten: the sixth redirect is refused, and the message says so.
func TestRedirectsAreCappedAtFive(t *testing.T) {
	var hits atomic.Int32
	var loop *httptest.Server
	loop = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		redirectTo(w, loop.URL+r.URL.Path+"x", http.StatusFound)
	}))
	defer loop.Close()
	message := trapMessage(t, func() { _ = HttpGet(loop.URL+"/", noHeaders()) })
	if !strings.Contains(message, "refused redirect") || !strings.Contains(message, "more than 5 redirects") {
		t.Fatalf("trap = %q", message)
	}
	// The first request plus the five redirects that were followed.
	if hits.Load() != 6 {
		t.Fatalf("server saw %d requests, want 6", hits.Load())
	}
}

// The SSO legs' policy: a 3xx is the RESPONSE, not an instruction. The redirect target is
// never requested, and the caller sees the 3xx status to judge as a failed leg.
func TestRedirectRefusedPolicyHandsBackTheRedirectItself(t *testing.T) {
	_, otherURL, hits, _ := otherHost(t)
	first := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		redirectTo(w, otherURL+"/", http.StatusFound)
	}))
	defer first.Close()
	response := httpRequestPolicy("GET", first.URL, noHeaders(), nil, redirectRefused)
	if status, _ := response.Status.Int64(); status != 302 {
		t.Fatalf("status = %s, want the 302 itself", response.Status.String())
	}
	if hits.Load() != 0 {
		t.Fatal("the redirect target was requested under redirectRefused")
	}
}
