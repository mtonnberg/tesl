package teslrt

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// millisDuration turns one of the millisecond knobs into a deadline.
func millisDuration(millis int) time.Duration {
	return time.Duration(millis) * time.Millisecond
}

// Outbound HTTP — the `Tesl.HttpClient` surface.
//
// The `httpClient` capability that gates every call here is a COMPILE-TIME grant, so
// nothing about it survives to run time; what does survive is the set of protections a
// call cannot opt out of:
//
//	CR/LF header guard    a `\r\n` in a header name or value would split the request and
//	                      inject arbitrary headers, so it is refused before anything is sent;
//	SSRF containment      the peer address actually connected to is judged (hostclass.go), so
//	                      a public name resolving to 169.254.169.254 or 127.0.0.1 is refused;
//	verified TLS          certificate chain AND hostname, with one loopback-only development
//	                      escape;
//	deadlines             a hung upstream fails the call rather than pinning the caller —
//	                      inside a worker that is the difference between a failed job (which
//	                      retries and dead-letters) and a job that never finishes;
//	a response-body cap   an unbounded read of a hostile response is a memory DoS.
//
// Trace-context propagation (`traceparent`/`tracestate` on every outbound call) is NOT here
// yet: it needs the telemetry slice, which has not been migrated. Its absence loses trace
// continuity across services; it takes nothing else away.
type HttpResponse struct {
	Status Int
	Body   string
	// Response headers in name order — one entry per value, so a repeated header
	// (`Set-Cookie`) keeps all of its values. Go's header map has no order of its own, so
	// sorting is what makes the list deterministic; Racket preserves wire order instead, and
	// a test that depends on either ordering is testing the transport, not the program.
	Headers []Tuple2[string, string]
}

// ── Deadlines ─────────────────────────────────────────────────────────────────
//
// Env vars rather than per-call arguments, matching the Racket runtime: a deadline is
// deployment tuning of the same kind as the response-body cap, and a per-call timeout would
// put an operational concern into all four public signatures.
//
//	TESL_HTTP_CONNECT_TIMEOUT_MS   10000   reaching the host
//	TESL_HTTP_TIMEOUT_MS           30000   the whole response (status + body)
//	TESL_HTTP_MAX_RESPONSE_BYTES   10 MiB  the most a response body may occupy

func httpConnectTimeoutMs() int { return envPositiveInt("TESL_HTTP_CONNECT_TIMEOUT_MS", 10000) }
func httpReadTimeoutMs() int    { return envPositiveInt("TESL_HTTP_TIMEOUT_MS", 30000) }

func httpMaxResponseBytes() int {
	return envPositiveInt("TESL_HTTP_MAX_RESPONSE_BYTES", 10*1024*1024)
}

// ── Header hygiene ────────────────────────────────────────────────────────────

// HttpHeaderFieldSafe reports whether a header name or value can go on the wire: a CR or LF
// would end the field and let the rest be read as further headers or a second request.
func HttpHeaderFieldSafe(field string) bool {
	return !strings.ContainsAny(field, "\r\n")
}

func requireHeaderFieldSafe(what, field string) string {
	if !HttpHeaderFieldSafe(field) {
		panic(fmt.Sprintf(
			"HttpClient: outbound %s contains a CR/LF newline — header injection rejected", what))
	}
	return field
}

// ── Secret-carrying headers ───────────────────────────────────────────────────
//
// `HttpClient.bearer k` and `HttpClient.secretHeader "X-Api-Key" k` are the sanctioned way
// a `secret` reaches the wire, replacing the `"Bearer " ++ key.value` that `secret` makes
// impossible. Their Tesl type is `Tuple2 String String`, so the value half IS a Go string —
// which means the plaintext cannot be what it holds, or `Tuple2.second (bearer k)` would
// hand a program the secret it is not allowed to see.
//
// So the value half is a HANDLE: unguessable text that names the plaintext in a
// process-local table. Every String operation on it sees the handle, printing it shows only
// "[redacted]", and this file is the one place that trades a handle back for the bytes that
// go on the socket. The handle carries a per-process random nonce because it is otherwise
// forgeable: a program that could construct the handle text from user input would make the
// client send OUR secret to an attacker's URL.
var (
	secretHeaderNonce = newSecretHeaderNonce()
	secretHeaderStore sync.Map // handle string -> plaintext string
	secretHeaderSeq   int64
	secretHeaderMutex sync.Mutex
)

func newSecretHeaderNonce() string {
	buffer := make([]byte, 16)
	if _, err := rand.Read(buffer); err != nil {
		panic("HttpClient: no source of randomness for secret headers: " + err.Error())
	}
	return hex.EncodeToString(buffer)
}

func secretHeaderHandle(plaintext string) string {
	secretHeaderMutex.Lock()
	secretHeaderSeq++
	sequence := secretHeaderSeq
	secretHeaderMutex.Unlock()
	handle := SecretRedaction + "\x00" + secretHeaderNonce + ":" + strconv.FormatInt(sequence, 10)
	secretHeaderStore.Store(handle, plaintext)
	return handle
}

// revealHeaderValue is THE unwrap point: a secret-header handle becomes plaintext here and
// nowhere else. Anything that is not a handle is already the value it looks like.
func revealHeaderValue(value string) string {
	if !strings.HasPrefix(value, SecretRedaction+"\x00") {
		return value
	}
	if plaintext, found := secretHeaderStore.Load(value); found {
		if text, ok := plaintext.(string); ok {
			return text
		}
	}
	// A handle shape from another process (or a forgery attempt) names no plaintext here.
	// Sending the handle text would leak nothing, but it would also silently authenticate as
	// nobody, so it fails instead.
	panic("HttpClient: this secret header value does not belong to this process")
}

// HttpSecretHeader is `HttpClient.secretHeader name k`.
func HttpSecretHeader(name string, secret SecretString) Tuple2[string, string] {
	return makeSecretHeader(name, secret, "")
}

// HttpBearer is `HttpClient.bearer k`: the Authorization header for a bearer token.
func HttpBearer(secret SecretString) Tuple2[string, string] {
	return makeSecretHeader("Authorization", secret, "Bearer ")
}

func makeSecretHeader(name string, secret SecretString, prefix string) Tuple2[string, string] {
	return Tuple2[string, string]{
		Tuple2First:  requireHeaderFieldSafe("header name", name),
		Tuple2Second: secretHeaderHandle(prefix + secret.Reveal()),
	}
}

// ── The four verbs ────────────────────────────────────────────────────────────

func HttpGet(target string, headers []Tuple2[string, string]) HttpResponse {
	return httpRequest("GET", target, headers, nil)
}

func HttpPost(target string, headers []Tuple2[string, string], body string) HttpResponse {
	return httpRequest("POST", target, headers, &body)
}

func HttpPut(target string, headers []Tuple2[string, string], body string) HttpResponse {
	return httpRequest("PUT", target, headers, &body)
}

func HttpDelete(target string, headers []Tuple2[string, string]) HttpResponse {
	return httpRequest("DELETE", target, headers, nil)
}

func httpRequest(method, target string, headers []Tuple2[string, string], body *string) HttpResponse {
	parsed := parseOutboundURL(target)
	// The header guard runs BEFORE the test double is consulted, so a stubbed call is still a
	// well-formed one and a header-injection bug cannot hide behind a stub.
	wire := outboundHeaders(headers)
	if answer, stubbed := httpStubAnswer(method, target, body); stubbed {
		return answer
	}
	return httpRequestNetwork(method, target, parsed, wire, body)
}

func parseOutboundURL(target string) *url.URL {
	parsed, err := url.Parse(target)
	if err != nil {
		panic(fmt.Sprintf("HttpClient: invalid URL %q: %s", target, err.Error()))
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		panic(fmt.Sprintf("HttpClient: invalid URL %q: expected an http or https scheme", target))
	}
	if parsed.Hostname() == "" {
		panic(fmt.Sprintf("HttpClient: invalid URL %q: could not parse host", target))
	}
	return parsed
}

// outboundHeaders checks every field and reveals the secret-carrying ones. A header list is
// ordered and may repeat a name, so it becomes an http.Header by APPENDING rather than
// setting — `Set` would drop all but the last of a repeated header.
func outboundHeaders(headers []Tuple2[string, string]) http.Header {
	wire := http.Header{}
	for _, header := range headers {
		name := requireHeaderFieldSafe("header name", header.Tuple2First)
		value := requireHeaderFieldSafe("header value", revealHeaderValue(header.Tuple2Second))
		wire[http.CanonicalHeaderKey(name)] = append(wire[http.CanonicalHeaderKey(name)], value)
	}
	return wire
}

func httpRequestNetwork(method, target string, parsed *url.URL, wire http.Header,
	body *string) HttpResponse {
	var reader io.Reader
	if body != nil {
		reader = strings.NewReader(*body)
	}
	request, err := http.NewRequest(method, target, reader)
	if err != nil {
		panic(fmt.Sprintf("HttpClient: HTTP %s to %s failed: %s", method, target, err.Error()))
	}
	request.Header = wire
	client := &http.Client{
		Transport: outboundTransport(parsed.Hostname()),
		Timeout:   millisDuration(httpReadTimeoutMs()),
		// A redirect is a fresh request to an attacker-influenced location, so it gets the
		// same egress and TLS treatment as the first one — which it does, because the
		// transport is shared. Nothing else is followed automatically beyond Go's default
		// limit of 10.
	}
	response, err := client.Do(request)
	if err != nil {
		panic(requestFailure(method, target, err))
	}
	if response == nil {
		// net/http never answers with neither a response nor an error; a transport that did
		// would make the reads below a nil dereference rather than a failed call.
		panic(fmt.Sprintf("HttpClient: HTTP %s to %s failed: no response", method, target))
	}
	defer func() { _ = response.Body.Close() }()
	limit := httpMaxResponseBytes()
	raw, err := io.ReadAll(io.LimitReader(response.Body, int64(limit)+1))
	if err != nil {
		panic(fmt.Sprintf("HttpClient: HTTP %s to %s failed: %s", method, target, err.Error()))
	}
	if len(raw) > limit {
		panic(fmt.Sprintf("HttpClient: response body exceeds the %d-byte cap", limit))
	}
	return HttpResponse{
		Status:  FromInt64(int64(response.StatusCode)),
		Body:    string(raw),
		Headers: responseHeaders(response.Header),
	}
}

// requestFailure turns a transport error into the message the Racket client raises for the
// same condition, because the test double's traps are written to match it byte for byte — a
// test that asserts on a timeout must describe what production logs.
//
// net/http wraps everything in a `Get "url": …` url.Error, so the reason is unwrapped first;
// otherwise every failure would read as a repeat of the URL.
func requestFailure(method, target string, err error) string {
	message := err.Error()
	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		message = urlErr.Err.Error()
	}
	// The egress refusal is raised by the dialer's Control hook, so it arrives buried in a
	// dial error. It is a REFUSAL, not a transport fault, and reads as one.
	if index := strings.Index(message, "SSRF: refused egress"); index >= 0 {
		return "HttpClient: " + message[index:]
	}
	if isTimeout(err) {
		// A deadline that expired during the DIAL is the connect deadline; anything later is
		// the response deadline. Racket names them separately for the same reason: they are
		// tuned by different env vars.
		if dialTimeout(err) {
			return fmt.Sprintf("HttpClient: connect to %s timed out after %dms",
				target, httpConnectTimeoutMs())
		}
		return fmt.Sprintf("HttpClient: HTTP %s to %s timed out after %dms",
			method, target, httpReadTimeoutMs())
	}
	return fmt.Sprintf("HttpClient: HTTP %s to %s failed: %s", method, target, message)
}

func isTimeout(err error) bool {
	var timeout interface{ Timeout() bool }
	if errors.As(err, &timeout) && timeout.Timeout() {
		return true
	}
	return errors.Is(err, context.DeadlineExceeded)
}

func dialTimeout(err error) bool {
	var opErr *net.OpError
	if !errors.As(err, &opErr) || opErr == nil {
		return false
	}
	return opErr.Op == "dial" && opErr.Timeout()
}

func responseHeaders(header http.Header) []Tuple2[string, string] {
	headers := make([]Tuple2[string, string], 0, len(header))
	names := make([]string, 0, len(header))
	for name := range header {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		for _, value := range header[name] {
			headers = append(headers, Tuple2[string, string]{Tuple2First: name, Tuple2Second: value})
		}
	}
	return headers
}

// outboundTransport is built per call because both of its policies depend on the target
// host: the egress judgement is per connection, and the TLS development escape is
// loopback-only. Connection reuse is given up for that, which costs a handshake on a
// repeated call and buys a policy that cannot be inherited from an earlier, different one.
func outboundTransport(host string) *http.Transport {
	dialer := &net.Dialer{
		Timeout: millisDuration(httpConnectTimeoutMs()),
		// Control runs after resolution with the address that is ABOUT to be connected, and
		// the connect then uses that same address. There is therefore no check-then-rebind
		// gap: a DNS answer cannot be swapped for an internal address after being judged.
		Control: func(_network, address string, _conn syscall.RawConn) error {
			peer, _, err := net.SplitHostPort(address)
			if err != nil {
				return fmt.Errorf("SSRF: refused egress to an unparseable peer address %q", address)
			}
			if reason := SsrfEgressRefusal(peer); reason != "" {
				return fmt.Errorf("SSRF: refused egress to %s — it resolves to %s, which is %s",
					host, peer, reason)
			}
			return nil
		},
	}
	return &http.Transport{
		DialContext:       dialer.DialContext,
		TLSClientConfig:   outboundTLSConfig(host),
		ForceAttemptHTTP2: true,
		DisableKeepAlives: true,
	}
}

// outboundTLSConfig verifies the peer's certificate chain AND hostname — Go's default, kept
// explicit here because the one escape below is the only thing allowed to weaken it.
func outboundTLSConfig(host string) *tls.Config {
	if tlsInsecureDevEscape(host) {
		// #nosec G402 -- The single development escape, and the reason it is safe: it engages
		// only when TESL_HTTP_TLS_INSECURE_DEV is set, only in a build that is not
		// TESL_DEPLOYED, and only for a loopback host, so the peer is a service on this
		// machine. It exists so a developer can talk to a local service presenting a
		// self-signed certificate; for any routable host the branch is not taken.
		return &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: true}
	}
	return &tls.Config{MinVersion: tls.VersionTLS12}
}

var (
	tlsDevWarnActive  sync.Once
	tlsDevWarnRefused sync.Once
)

func tlsInsecureDevEscape(host string) bool {
	if envPresent("TESL_DEPLOYED") || !envTruthy("TESL_HTTP_TLS_INSECURE_DEV") {
		return false
	}
	if HostLoopback(host) {
		tlsDevWarnActive.Do(func() {
			fmt.Fprintln(os.Stderr, "WARNING: TESL_HTTP_TLS_INSECURE_DEV active -- HTTPS "+
				"certificate verification is DISABLED for loopback hosts only. "+
				"Never enable this in production.")
		})
		return true
	}
	tlsDevWarnRefused.Do(func() {
		fmt.Fprintf(os.Stderr, "WARNING: TESL_HTTP_TLS_INSECURE_DEV is set but host %q is "+
			"not loopback -- TLS verification stays ON.\n", host)
	})
	return false
}
