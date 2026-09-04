package teslrt

import (
	"bufio"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// These tests run the PRODUCTION http.Server — the one `Serve` builds, via `newHTTPServer` —
// rather than an httptest.Server, because an httptest.Server has no timeouts and so could never
// see the bug they guard: Go arms `WriteTimeout` once per request, for the whole response, and
// an `sse` route writes for the life of the connection.

// serveOnLoopback starts the production server on an ephemeral loopback port and answers its
// base URL. The server is closed when the test ends.
func serveOnLoopback(t *testing.T, handler http.Handler, writeTimeout time.Duration) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	httpServer := newHTTPServer(handler, listener.Addr().String(), writeTimeout)
	go func() { _ = httpServer.Serve(listener) }()
	t.Cleanup(func() { _ = httpServer.Close() })
	return "http://" + listener.Addr().String()
}

// openStream subscribes and consumes the opening comment; every later line arrives on `lines`,
// and the read error that ends the stream arrives on `ended`.
func openStream(t *testing.T, url string) (lines <-chan string, ended <-chan error) {
	t.Helper()
	response, err := http.Get(url) //nolint:noctx // the server is closed by the test
	if err != nil || response == nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(func() { _ = response.Body.Close() })
	if response.StatusCode != http.StatusOK {
		t.Fatalf("subscribe answered %d", response.StatusCode)
	}
	reader := bufio.NewReader(response.Body)
	line, err := reader.ReadString('\n')
	if err != nil || strings.TrimRight(line, "\r\n") != ": ok" {
		t.Fatalf("the stream opened with %q (%v)", line, err)
	}
	lineChannel := make(chan string, 64)
	endedChannel := make(chan error, 1)
	go func() {
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				endedChannel <- err
				return
			}
			lineChannel <- strings.TrimRight(line, "\r\n")
		}
	}()
	return lineChannel, endedChannel
}

func expectDataLine(t *testing.T, lines <-chan string, ended <-chan error, want string) {
	t.Helper()
	timeout := time.After(2 * time.Second)
	for {
		select {
		case line := <-lines:
			if strings.HasPrefix(line, "data: ") && strings.Contains(line, want) {
				return
			}
		case err := <-ended:
			t.Fatalf("the stream ended before %q arrived: %v", want, err)
		case <-timeout:
			t.Fatalf("no event containing %q arrived within 2s", want)
		}
	}
}

// The finding: with the production WriteTimeout the stream died at 60 s (the first heartbeat
// past the deadline failed), so every browser EventSource reconnected once a minute and lost the
// events published in between. Shortened to 1 s here: an event published AFTER the deadline
// must still arrive, and the stream must still be open well past it.
func TestSseStreamOutlivesTheServerWriteTimeout(t *testing.T) {
	channel := NewSseChannel("RunEvents")
	base := serveOnLoopback(t, streamServer(channel).handlerWith(ServeOptions{}), time.Second)
	start := time.Now()
	lines, ended := openStream(t, base+"/stream")
	waitForListeners(t, channel, "all", 1)

	time.Sleep(1500*time.Millisecond - time.Since(start))
	Publish(channel, "all", eventPayload("runId", "after-the-write-timeout"))
	expectDataLine(t, lines, ended, `"runId":"after-the-write-timeout"`)

	time.Sleep(2500*time.Millisecond - time.Since(start))
	select {
	case err := <-ended:
		t.Fatalf("the stream ended after %s: %v", time.Since(start).Round(100*time.Millisecond), err)
	default:
	}
	if got := channelListenerCount(channel, "all"); got != 1 {
		t.Fatalf("the listener was unregistered: %d listeners on the key", got)
	}
	// Still delivering, not merely still connected.
	Publish(channel, "all", eventPayload("runId", "still-streaming"))
	expectDataLine(t, lines, ended, `"runId":"still-streaming"`)
}

// The other half of what WriteTimeout bought: a client that stops reading must still be dropped,
// or a dead browser pins a goroutine, a listener and a 64-event buffer forever. The rolling
// per-write deadline is what does it — the server here keeps the PRODUCTION WriteTimeout, so the
// disconnect within seconds can only come from the stream's own deadline.
func TestSseStreamStillDropsAStalledClient(t *testing.T) {
	channel := NewSseChannel("RunEvents")
	server := Server{
		Routes:   []Route{{Method: "GET", Path: "/stream", Endpoint: "sse:/stream"}},
		Handlers: map[string]HandlerFunc{},
		Streams: map[string]StreamFunc{
			"sse:/stream": sseStream(channel, "all", 300*time.Millisecond),
		},
	}
	base := serveOnLoopback(t, server.handlerWith(ServeOptions{}), serveWriteTimeout)

	// A raw socket that sends the request and then never reads: the socket buffers fill, the
	// server's write blocks, and the deadline is the only thing that can end it.
	connection, err := net.Dial("tcp", strings.TrimPrefix(base, "http://"))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	if _, err := connection.Write([]byte("GET /stream HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n")); err != nil {
		t.Fatalf("request: %v", err)
	}
	waitForListeners(t, channel, "all", 1)

	// Enough data to fill both loopback socket buffers quickly; Publish drops rather than
	// blocks when the connection's buffer is full, so the loop never stalls the test itself.
	stop := make(chan struct{})
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		payload := eventPayload("bulk", strings.Repeat("x", 256<<10))
		for {
			select {
			case <-stop:
				return
			default:
				Publish(channel, "all", payload)
				time.Sleep(time.Millisecond)
			}
		}
	}()
	t.Cleanup(func() { close(stop); <-finished })

	start := time.Now()
	deadline := start.Add(4 * time.Second)
	for time.Now().Before(deadline) {
		if channelListenerCount(channel, "all") == 0 {
			t.Logf("stalled client dropped after %s", time.Since(start).Round(10*time.Millisecond))
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("a client that stopped reading was still registered after 4s")
}

// The response controller reaches the connection only through Unwrap; without it the stream's
// SetWriteDeadline is silently unsupported and the fix above is inert.
func TestHardenedWriterUnwrapsForTheResponseController(t *testing.T) {
	recorder := httptest.NewRecorder()
	writer := &hardenedWriter{ResponseWriter: recorder}
	unwrapper, ok := any(writer).(interface{ Unwrap() http.ResponseWriter })
	if !ok {
		t.Fatal("hardenedWriter has no Unwrap")
	}
	if unwrapper.Unwrap() != http.ResponseWriter(recorder) {
		t.Fatal("Unwrap does not answer the wrapped writer")
	}
}
