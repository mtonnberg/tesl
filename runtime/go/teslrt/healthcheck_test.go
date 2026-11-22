package teslrt

import (
	"bytes"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

func healthcheckTarget(t *testing.T, status int) (string, int) {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/healthz" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.WriteHeader(status)
	}))
	t.Cleanup(server.Close)
	host, portText, err := net.SplitHostPort(strings.TrimPrefix(server.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	port, _ := strconv.Atoi(portText)
	return host, port
}

func TestHealthcheckCommandIsOnlyTheSubcommand(t *testing.T) {
	for _, args := range [][]string{nil, {"serve"}, {"--help"}} {
		if handled, _ := RunHealthcheckCommand(args, &bytes.Buffer{}, "127.0.0.1", 1, "/healthz"); handled {
			t.Fatalf("%v was taken as a healthcheck", args)
		}
	}
}

func TestHealthcheckCommandAnswersFromTheProbePath(t *testing.T) {
	host, port := healthcheckTarget(t, http.StatusOK)
	if handled, code := RunHealthcheckCommand([]string{"healthcheck"}, &bytes.Buffer{}, host, port, "/healthz"); !handled || code != 0 {
		t.Fatalf("healthy server: handled=%v code=%d", handled, code)
	}
	// An explicit port overrides the compiled-in one.
	if _, code := RunHealthcheckCommand([]string{"healthcheck", strconv.Itoa(port)}, &bytes.Buffer{}, host, 1, "/healthz"); code != 0 {
		t.Fatalf("explicit port: code=%d", code)
	}
}

func TestHealthcheckCommandFailsOnUnhealthyOrUnreachable(t *testing.T) {
	host, port := healthcheckTarget(t, http.StatusServiceUnavailable)
	var stderr bytes.Buffer
	if _, code := RunHealthcheckCommand([]string{"healthcheck"}, &stderr, host, port, "/healthz"); code != 1 || !strings.Contains(stderr.String(), "503") {
		t.Fatalf("503: code=%d stderr=%q", code, stderr.String())
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	closed := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	if _, code := RunHealthcheckCommand([]string{"healthcheck"}, &bytes.Buffer{}, "127.0.0.1", closed, "/healthz"); code != 1 {
		t.Fatalf("nothing listening: code=%d", code)
	}
	if _, code := RunHealthcheckCommand([]string{"healthcheck", "nope"}, &bytes.Buffer{}, host, port, "/healthz"); code != 2 {
		t.Fatalf("bad port argument: code=%d", code)
	}
}
