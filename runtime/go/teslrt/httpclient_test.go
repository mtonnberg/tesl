package teslrt

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
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
