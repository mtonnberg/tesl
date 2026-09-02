package teslrt

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// notDeployed clears TESL_DEPLOYED for the test: the runtime checks PRESENCE, so an empty
// value still counts as deployed. t.Setenv registers the restore; Unsetenv removes it.
func notDeployed(t *testing.T) {
	t.Helper()
	t.Setenv("TESL_DEPLOYED", "")
	_ = os.Unsetenv("TESL_DEPLOYED")
}

// Outbound TLS verification had no test after the migration: the Racket suite
// `tests/http-tls-tests.rkt` (six cases) was deleted and nothing in httpclient_test.go
// mentioned TLS, so `outboundTLSConfig` and the `TESL_HTTP_TLS_INSECURE_DEV` escape were
// untested code on the security boundary (language review 2026-09-02, H9). These are the
// cases that suite pinned, on the Go client.
//
// httptest.NewTLSServer presents a self-signed certificate for 127.0.0.1 — exactly the
// peer a developer's local service presents, and exactly the peer a production client must
// refuse.

func expectTrap(t *testing.T, wantSubstring string, run func()) {
	t.Helper()
	defer func() {
		recovered := recover()
		if recovered == nil {
			t.Fatalf("expected a trap containing %q, got none", wantSubstring)
		}
		if !strings.Contains(fmt.Sprint(recovered), wantSubstring) {
			t.Fatalf("trap = %q, want it to contain %q", fmt.Sprint(recovered), wantSubstring)
		}
	}()
	run()
}

// The default: a self-signed certificate is refused even on loopback. This is the whole
// guarantee — nothing about "it is only localhost" weakens chain verification.
func TestOutboundTLSRefusesASelfSignedCertificateByDefault(t *testing.T) {
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(200)
	}))
	defer upstream.Close()
	t.Setenv("TESL_HTTP_TLS_INSECURE_DEV", "")
	notDeployed(t)
	expectTrap(t, "HttpClient: HTTP GET to ", func() { _ = HttpGet(upstream.URL, noHeaders()) })
}

// The one escape: TESL_HTTP_TLS_INSECURE_DEV, not deployed, loopback host — the developer's
// self-signed local service is reachable. Every one of the three conditions is necessary;
// the next two tests remove one each.
func TestOutboundTLSDevEscapeAllowsLoopbackSelfSigned(t *testing.T) {
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(204)
	}))
	defer upstream.Close()
	t.Setenv("TESL_HTTP_TLS_INSECURE_DEV", "1")
	notDeployed(t)
	response := HttpGet(upstream.URL, noHeaders())
	if got, _ := response.Status.Int64(); got != 204 {
		t.Fatalf("status = %d, want 204 through the dev escape", got)
	}
}

// Deployed: the escape is inert even when the variable is set. Egress containment refuses
// loopback in a deployed build before TLS is reached, so the guarantee is asserted at the
// unit that decides it — `tlsInsecureDevEscape` — rather than through a dial.
func TestOutboundTLSDevEscapeIsInertWhenDeployed(t *testing.T) {
	t.Setenv("TESL_HTTP_TLS_INSECURE_DEV", "1")
	t.Setenv("TESL_DEPLOYED", "1")
	if tlsInsecureDevEscape("127.0.0.1") {
		t.Fatal("TESL_HTTP_TLS_INSECURE_DEV weakened TLS verification in a deployed build")
	}
	if outboundTLSConfig("127.0.0.1").InsecureSkipVerify {
		t.Fatal("deployed build produced an InsecureSkipVerify transport")
	}
}

// Not loopback: the escape does not apply to a routable host, whatever the variable says.
func TestOutboundTLSDevEscapeIsLoopbackOnly(t *testing.T) {
	t.Setenv("TESL_HTTP_TLS_INSECURE_DEV", "1")
	notDeployed(t)
	for _, host := range []string{"example.com", "10.0.0.5", "internal.corp"} {
		if tlsInsecureDevEscape(host) {
			t.Fatalf("dev escape engaged for non-loopback host %q", host)
		}
		if outboundTLSConfig(host).InsecureSkipVerify {
			t.Fatalf("InsecureSkipVerify set for non-loopback host %q", host)
		}
	}
}

// The floor: TLS 1.2 or better, with verification, whenever the escape is not engaged.
func TestOutboundTLSConfigFloor(t *testing.T) {
	t.Setenv("TESL_HTTP_TLS_INSECURE_DEV", "")
	config := outboundTLSConfig("example.com")
	if config.InsecureSkipVerify {
		t.Fatal("verification is off by default")
	}
	if config.MinVersion < 0x0303 { // tls.VersionTLS12
		t.Fatalf("MinVersion = %#x, want at least TLS 1.2", config.MinVersion)
	}
}
