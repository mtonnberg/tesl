package teslrt

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Activation: what `main` returning an `App { … }` becomes.
//
// The App record is not a runtime value — the compiler lowers it into the startup chain it
// describes (start each queue's workers, then serve), so what is left here are the two things
// that chain calls. Everything the App configures is therefore decided at compile time and read
// here as ordinary arguments.

// ServeOptions is what an `App` says about the HTTP surface. Grouped in a struct rather than
// passed positionally because most programs set only `Port`, and a five-argument call whose
// middle three are usually zero reads worse in the emitted code than a literal with named
// fields.
type ServeOptions struct {
	Port int
	// StaticDir serves files, with an index.html SPA fallback, when set.
	StaticDir string
	// MountPath scopes exactly the DECLARED api surface (`/api`), while static files, the SPA
	// fallback and the health probe keep answering on the raw path — the same split the Racket
	// runtime makes, and for its reason: the SPA is precisely the other thing sharing this
	// origin that the prefix exists to separate the API from.
	MountPath string
	// ListenAddress is the interface to bind, from the `listenAddress` server clause:
	// "127.0.0.1" for `Loopback` (the server sits behind a reverse proxy) and empty for
	// `AllInterfaces`. Empty binds every interface, which is Go's and Racket's default.
	ListenAddress string
}

// Serve runs the HTTP server until the process is asked to stop, then drains in-flight requests.
//
// Timeouts are set rather than left at Go's defaults (which are "none"): a server with no read
// timeout can be held open by a slow client indefinitely, which is the same class of problem the
// outbound deadlines close on the client side. `ReadHeaderTimeout` in particular is what stops a
// Slowloris-style hold.
// Answers Tesl's Unit (an empty struct) rather than nothing, so the emitted `main` can return it
// the way it returns any other statement's value — the same shape `EnqueueJob` and the cookie
// writers use.
func Serve(server Server, options ServeOptions) struct{} {
	port := options.Port
	if port == 0 {
		port = 8080
	}
	handler := server.handlerWith(options)
	httpServer := newHTTPServer(handler, bindAddress(options), serveWriteTimeout)
	// Graceful: an interrupt stops accepting and lets in-flight requests finish, so a deploy does
	// not answer a request with a truncated response.
	shutdown, stop := signal.NotifyContext(context.Background(),
		os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-shutdown.Done()
		drain, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(drain)
	}()
	announced := options.ListenAddress
	if announced == "" {
		announced = "localhost"
	}
	fmt.Fprintf(os.Stderr, "tesl: serving on http://%s:%d\n", announced, port)
	// main's generated debug scope lives for the server lifetime. Mark the
	// blocking lifecycle wait quiescent so a request breakpoint does not wait for
	// main to reach a checkpoint that cannot occur until the server exits.
	resumeDebugExecution := debugLifecycleQuiesce()
	err := httpServer.ListenAndServe()
	resumeDebugExecution()
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		panic("serve: " + err.Error())
	}
	return struct{}{}
}

// serveWriteTimeout is the per-response write deadline `Serve` installs. Go arms it ONCE per
// request, so it bounds a whole response — the right shape for a JSON answer and the wrong one
// for an `sse` stream that lives for the connection; the stream re-arms its own rolling deadline
// (see `sseWriteDeadline`) instead of inheriting this one.
const serveWriteTimeout = 60 * time.Second

// newHTTPServer is the ONE place the production `http.Server` is configured, so a test can run
// the same server with a shortened `writeTimeout` and meet exactly the deadlines a deployment
// does. An `httptest.Server` has no timeouts at all, which is how "WriteTimeout cuts every SSE
// stream at 60 s" stayed invisible to every api-test.
func newHTTPServer(handler http.Handler, address string, writeTimeout time.Duration) *http.Server {
	return &http.Server{
		Addr:              address,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       120 * time.Second,
	}
}

// bindAddress is where the listener goes: the `listenAddress` clause's interface and the port.
// Named because it is a RULE rather than a format string — an empty interface binds every one of
// them, which is the difference between a service a reverse proxy reaches and one the whole
// network reaches.
func bindAddress(options ServeOptions) string {
	port := options.Port
	if port == 0 {
		port = 8080
	}
	return fmt.Sprintf("%s:%d", options.ListenAddress, port)
}

// handlerWith wraps the router with the static-file surface an App may declare. The API routes
// are reached under `MountPath`; everything else the runtime owns answers on the raw path.
func (server Server) handlerWith(options ServeOptions) http.Handler {
	mount := strings.Trim(options.MountPath, "/")
	static := options.StaticDir
	return http.HandlerFunc(func(raw http.ResponseWriter, request *http.Request) {
		// Every response — API, static file and SPA fallback alike — carries the security header
		// floor, which is where `dsl/web.rkt` puts it (`harden-servlet` wraps the servlet, after
		// the two direct-response paths were found carrying none).
		writer := &hardenedWriter{ResponseWriter: raw}
		// Runtime-owned SSO routes must win over the static SPA fallback. Without
		// this check, /auth/<segment>/login serves index.html and the browser never
		// reaches the provider's login form.
		if _, _, matched := findSsoMatch(server.SsoRoutes, request.URL.Path); matched {
			server.ServeHTTP(writer, request)
			return
		}
		routed := request
		if mount != "" {
			requestPath := strings.TrimPrefix(request.URL.Path, "/")
			// SSO paths belong to the runtime, not the declared API, so they stay raw.
			if _, _, matched := findSsoMatch(server.SsoRoutes, request.URL.Path); matched {
				server.ServeHTTP(writer, request)
				return
			}
			if requestPath != mount && !strings.HasPrefix(requestPath, mount+"/") {
				// Not under the mount prefix: only the static surface can answer it.
				if static != "" && serveStatic(writer, request, static) {
					return
				}
				writeResponse(writer, nil, Fail(404, "not found"))
				return
			}
			trimmed := strings.TrimPrefix(requestPath, mount)
			routed = request.Clone(request.Context())
			if trimmed == "" {
				trimmed = "/"
			}
			if !strings.HasPrefix(trimmed, "/") {
				trimmed = "/" + trimmed
			}
			routed.URL.Path = trimmed
			// UNDER the mount prefix the declared API is the only surface. The prefix exists to
			// separate the API from the SPA sharing the origin, so a mounted path the API does
			// not declare is an API miss and gets the API's JSON 404 (or 405) — not index.html
			// with a 200, which is what a client that mistyped `/api/task` would otherwise be
			// told to parse as JSON.
			//
			// The runtime-owned SSO routes are excluded: they answer on the RAW path (matched
			// above) and are not part of the declared API, so `/api/auth/<seg>/login` is a miss
			// rather than a second door to the login flow.
			if _, _, matched := findSsoMatch(server.SsoRoutes, routed.URL.Path); matched {
				writeResponse(writer, nil, Fail(404, "not found"))
				return
			}
			server.ServeHTTP(writer, routed)
			return
		}
		if server.declaredRouteExists(routed) {
			server.ServeHTTP(writer, routed)
			return
		}
		if static != "" && serveStatic(writer, request, static) {
			return
		}
		server.ServeHTTP(writer, routed)
	})
}

// declaredRouteExists reports whether the declared API has this path — used to decide between
// the mounted API and static surfaces without accidentally mounting runtime-owned SSO routes.
func (server Server) declaredRouteExists(request *http.Request) bool {
	for _, route := range server.Routes {
		if pathMatches(route.Path, request.URL.Path) {
			return true
		}
	}
	return false
}

// serveStatic answers a GET from the static directory, falling back to index.html so a
// single-page app's client-side routes load. Reports whether it answered.
//
// Three rules keep this from becoming an arbitrary-file read, and they are checked in the order
// a request meets them:
//
//   - The path is cleaned and checked LEXICALLY to be inside the directory: `..` segments and
//     absolute paths are the textbook traversal, and an encoded one has been decoded by the
//     time it is here.
//   - A segment beginning with `.` is never served. A static directory is usually a build
//     output, and build outputs carry `.env`, `.git/config`, editor backups — files that are
//     next to the SPA rather than part of it. (`.well-known/` falls under this too; it is a
//     deliberate trade, since nothing here can tell it from `.git/`.)
//   - Symlinks are RESOLVED — on the candidate AND on the root — and containment is re-checked
//     on the resolved paths. `pnpm` and nix both link build inputs from outside the tree, and
//     `http.ServeFile` follows a link wherever it points; resolving the root as well means a
//     root that is itself a symlink (a `current -> release-N` deploy) still contains its files.
//
// A dotfile path is not served AND does not fall back to index.html: it reaches the router's
// own 404, because answering the SPA for `/.env` would be a 200 that says nothing was wrong. A
// symlink that leaves the root is treated as a file that is not there — its target is never
// read, and the path gets whatever any unknown path gets (the SPA index, or the 404).
func serveStatic(writer http.ResponseWriter, request *http.Request, directory string) bool {
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		return false
	}
	root, err := resolvedStaticRoot(directory)
	if err != nil {
		return false
	}
	relative := strings.TrimPrefix(path.Clean("/"+request.URL.Path), "/")
	if hasDotSegment(relative) {
		return false
	}
	if relative == "" {
		relative = "index.html"
	}
	if file := containedStaticFile(root, relative); file != "" {
		http.ServeFile(writer, request, file)
		return true
	}
	// The SPA fallback: an unknown path serves index.html, so client-side routing works on a
	// cold load. Only when there IS an index.html — otherwise the router's own 404 is the honest
	// answer.
	if file := containedStaticFile(root, "index.html"); file != "" {
		http.ServeFile(writer, request, file)
		return true
	}
	return false
}

// resolvedStaticRoot is the static directory with every symlink followed, so that the
// containment check below compares resolved paths on both sides.
func resolvedStaticRoot(directory string) (string, error) {
	absolute, err := filepath.Abs(directory)
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(absolute)
}

// hasDotSegment reports whether any segment of a cleaned, root-relative path begins with `.`.
func hasDotSegment(relative string) bool {
	for _, segment := range strings.Split(relative, "/") {
		if strings.HasPrefix(segment, ".") {
			return true
		}
	}
	return false
}

// containedStaticFile is the regular file `relative` names inside `root`, as its resolved path,
// or "" when there is no such file — including when the path exists but resolves through a
// symlink to somewhere outside the root, which is treated exactly like a file that is not there.
func containedStaticFile(root, relative string) string {
	separator := string(os.PathSeparator)
	candidate := filepath.Join(root, filepath.FromSlash(relative))
	if !strings.HasPrefix(candidate, root+separator) {
		return ""
	}
	resolved, err := filepath.EvalSymlinks(candidate)
	if err != nil {
		return ""
	}
	if !strings.HasPrefix(resolved, root+separator) {
		return ""
	}
	info, err := os.Stat(resolved)
	if err != nil || info.IsDir() {
		return ""
	}
	return resolved
}

// ── Request-level guards ──────────────────────────────────────────────────────
//
// Two refusals the Racket runtime applies to every request, mirrored here so a program does not
// lose them by changing backend. Both are cheap and neither is configurable per route.

var publicOriginOnce sync.Once
var publicOrigin string

// The `publicOrigin` server clause, when the program declares one. It TAKES PRECEDENCE over
// the environment variable: the clause is compile-time validated and the variable is not,
// and a deployment that declared its origin should not answer as another because a stray
// variable disagreed. The same precedence the Racket parameter has.
var (
	publicOriginMutex    sync.RWMutex
	publicOriginOverride string
)

// PublicOrigin is the declared origin, else `TESL_PUBLIC_ORIGIN`: the origin this deployment
// answers as. Never derived from a request — a Host header is exactly what it guards.
func PublicOrigin() string {
	publicOriginMutex.RLock()
	declared := publicOriginOverride
	publicOriginMutex.RUnlock()
	if declared != "" {
		return declared
	}
	publicOriginOnce.Do(func() {
		publicOrigin = strings.TrimSpace(os.Getenv("TESL_PUBLIC_ORIGIN"))
	})
	return publicOrigin
}

// The `healthProbePath` server clause: the ONE path exempt from Host validation, because a load
// balancer probes host-blind. Exempt from THAT check only — the cross-site guard still applies,
// and a probe is a GET so it never meets it.
var (
	healthProbeMutex sync.RWMutex
	healthProbePath  string
)

// SetHealthProbePath is the clause, applied at boot.
func SetHealthProbePath(path string) {
	healthProbeMutex.Lock()
	defer healthProbeMutex.Unlock()
	healthProbePath = path
}

func healthProbeExempt(path string) bool {
	healthProbeMutex.RLock()
	defer healthProbeMutex.RUnlock()
	return healthProbePath != "" && path == healthProbePath
}

// The `contentSecurityPolicy` server clause: the default CSP for responses this runtime serves
// as HTML. A deployment may replace it with a policy that passes the compiler's CSP baseline;
// the environment fallback is checked here too because it is deployment input. Unsafe policies
// fail closed to this baseline rather than weakening every HTML response.
var (
	contentSecurityPolicyMutex sync.RWMutex
	contentSecurityPolicy      string
)

const defaultContentSecurityPolicy = "default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; font-src 'self'; media-src 'self'; worker-src 'self'; manifest-src 'self'; frame-src 'none'"

// SetContentSecurityPolicy is the clause, applied at boot.
func SetContentSecurityPolicy(policy string) {
	contentSecurityPolicyMutex.Lock()
	defer contentSecurityPolicyMutex.Unlock()
	contentSecurityPolicy = strings.TrimSpace(policy)
}

func htmlContentSecurityPolicy() string {
	contentSecurityPolicyMutex.RLock()
	declared := contentSecurityPolicy
	contentSecurityPolicyMutex.RUnlock()
	if declared != "" {
		if secureContentSecurityPolicy(declared) {
			return declared
		}
		return defaultContentSecurityPolicy
	}
	if fromEnv := strings.TrimSpace(os.Getenv("TESL_CSP")); fromEnv != "" {
		if secureContentSecurityPolicy(fromEnv) {
			return fromEnv
		}
	}
	return defaultContentSecurityPolicy
}

// secureContentSecurityPolicy is deliberately a small fail-closed parser, not a complete CSP
// grammar. It checks the properties Tesl promises: required isolation directives are present and
// no source wildcard, inline execution, eval, or unrestricted data/blob scheme is admitted.
func secureContentSecurityPolicy(policy string) bool {
	required := map[string]bool{
		"default-src": false, "base-uri": false, "object-src": false,
		"frame-ancestors": false, "form-action": false, "script-src": false,
		"style-src": false,
	}
	for _, rawDirective := range strings.Split(policy, ";") {
		fields := strings.Fields(rawDirective)
		if len(fields) == 0 {
			continue
		}
		name := strings.ToLower(fields[0])
		if _, present := required[name]; present {
			required[name] = true
		}
		for _, source := range fields[1:] {
			switch strings.ToLower(source) {
			case "*", "'unsafe-inline'", "'unsafe-eval'", "data:", "blob:", "http:", "https:":
				return false
			}
		}
	}
	for _, present := range required {
		if !present {
			return false
		}
	}
	return true
}

// hstsHeaderValue is set ONLY from the CONFIGURED public origin, never from the request: a Host
// header is untrusted and absent behind a proxy, and HSTS is close to irreversible once a
// browser has seen it. One year, no includeSubDomains and no preload — Tesl cannot see the
// subdomain topology. Suppressed for a loopback dev origin.
func hstsHeaderValue() string {
	origin := strings.ToLower(PublicOrigin())
	if !strings.HasPrefix(origin, "https://") {
		return ""
	}
	host := hostOf(origin)
	if host == "localhost" || host == "[::1]" || strings.HasPrefix(host, "127.") {
		return ""
	}
	return "max-age=31536000"
}

// hardenedWriter adds the response-header floor at the moment the status is written, which is the
// first point where the Content-Type is known — the CSP applies to HTML and `no-store` to the
// JSON API, exactly as `dsl/web.rkt` splits them. A header the producer already set WINS: a
// handler that chose its own Referrer-Policy or CSP means it.
type hardenedWriter struct {
	http.ResponseWriter
	wroteHeader bool
}

func (writer *hardenedWriter) WriteHeader(status int) {
	if !writer.wroteHeader {
		writer.wroteHeader = true
		applySecurityHeaders(writer.Header())
	}
	writer.ResponseWriter.WriteHeader(status)
}

func (writer *hardenedWriter) Write(payload []byte) (int, error) {
	if !writer.wroteHeader {
		writer.WriteHeader(http.StatusOK)
	}
	return writer.ResponseWriter.Write(payload)
}

// Flush passes through so an SSE stream still streams: wrapping a writer without this turns
// every event into buffered output that arrives at the end.
func (writer *hardenedWriter) Flush() {
	if flusher, canFlush := writer.ResponseWriter.(http.Flusher); canFlush {
		flusher.Flush()
	}
}

// Unwrap is what lets `http.NewResponseController` reach the connection behind this wrapper.
// Without it `SetWriteDeadline` answers ErrNotSupported and the SSE stream cannot move the
// server's per-response write deadline — the connection is then cut at `serveWriteTimeout`.
func (writer *hardenedWriter) Unwrap() http.ResponseWriter {
	return writer.ResponseWriter
}

func applySecurityHeaders(header http.Header) {
	setIfAbsent := func(name, value string) {
		if value != "" && header.Get(name) == "" {
			header.Set(name, value)
		}
	}
	setIfAbsent("X-Content-Type-Options", "nosniff")
	setIfAbsent("Referrer-Policy", "no-referrer")
	setIfAbsent("X-Frame-Options", "DENY")
	setIfAbsent("Strict-Transport-Security", hstsHeaderValue())
	contentType := strings.ToLower(header.Get("Content-Type"))
	switch {
	case strings.Contains(contentType, "text/html"):
		// A CSP is meaningful for a document only, and the app cannot set one on HTML this
		// runtime serves (the static file and the SPA fallback are both ours).
		setIfAbsent("Content-Security-Policy", htmlContentSecurityPolicy())
	case strings.Contains(contentType, "application/json"):
		// The JSON API answers session-bearing data; a shared cache must not keep it.
		setIfAbsent("Cache-Control", "no-store")
	}
}

// requestRefusal is the guard pair: a cross-site state-changing request is refused (403), and a
// Host that does not match the configured public origin is refused (421). Answering the second
// with 421 rather than 404 is deliberate — it says "not this origin", which is what a
// misconfigured proxy needs to hear.
func requestRefusal(request *http.Request) (Response, bool) {
	switch request.Method {
	case http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch:
		if refusal, refused := crossSiteRefusal(request); refused {
			return refusal, true
		}
	}
	origin := PublicOrigin()
	if origin == "" || healthProbeExempt(request.URL.Path) {
		return Response{}, false
	}
	if hostOf(request.Host) == hostOf(origin) {
		return Response{}, false
	}
	return Fail(421, "Host does not match the configured public origin"), true
}

// crossSiteRefusal is the CSRF guard a state-changing method meets. It matters most for the
// cookies a PROGRAM sets and reads in its `auth` block: the runtime's own `__Host-session` is
// `SameSite=Lax`, but a program-defined cookie has whatever attributes the program gave it, and
// this guard is then the only thing between a form on another site and the handler.
//
// Two sources, in order of trust:
//
//   - `Sec-Fetch-Site`, when the browser sent one. `same-origin` passes, `cross-site`
//     is refused, `same-site` must also carry an exact matching Origin, and unknown
//     values fail closed.
//   - When it is ABSENT — an older browser (Safari before 16.4, Firefox before 90) or a
//     non-browser client — the initiator the request names itself: `Origin`, else `Referer`.
//     If one is present, its complete web origin must equal the configured public origin,
//     or the request URL's origin when none is configured. `Origin: null` is refused too.
//
// A request naming NEITHER passes: curl, a service client and a same-origin fetch that stripped
// the referrer all look like that, and refusing them would break every non-browser caller for no
// protection a browser needs. Comparing an initiator to the request Host is still useful when
// no public origin is configured: a browser cannot choose the target request's Host independently.
func crossSiteRefusal(request *http.Request) (Response, bool) {
	site := strings.ToLower(strings.TrimSpace(request.Header.Get("Sec-Fetch-Site")))
	switch site {
	case "cross-site":
		return Fail(403, "cross-site request refused"), true
	case "", "same-origin", "same-site", "none":
	default:
		return Fail(403, "request with unknown fetch metadata refused"), true
	}
	originHeader := strings.TrimSpace(request.Header.Get("Origin"))
	initiator := originHeader
	isReferer := false
	if initiator == "" {
		initiator = strings.TrimSpace(request.Header.Get("Referer"))
		isReferer = initiator != ""
	}
	if site == "same-site" && originHeader == "" {
		return Fail(403, "same-site request without an exact Origin refused"), true
	}
	if initiator == "" {
		return Response{}, false
	}
	expected, valid := requestPublicOrigin(request)
	if !valid {
		return Fail(403, "request origin is not configured or valid"), true
	}
	actual, valid := canonicalWebOrigin(initiator, isReferer)
	if !valid || actual != expected {
		return Fail(403, "cross-site request refused"), true
	}
	return Response{}, false
}

func requestPublicOrigin(request *http.Request) (string, bool) {
	// publicOrigin is the authenticated deployment statement for TLS terminated
	// upstream. Never infer the external scheme or host from Forwarded or
	// X-Forwarded-* headers: a direct client can supply those too.
	if configured := strings.TrimSpace(PublicOrigin()); configured != "" {
		return canonicalWebOrigin(configured, false)
	}
	scheme := strings.ToLower(request.URL.Scheme)
	if scheme == "" {
		if request.TLS != nil {
			scheme = "https"
		} else {
			scheme = "http"
		}
	}
	return canonicalWebOrigin(scheme+"://"+request.Host, false)
}

func canonicalWebOrigin(value string, allowPath bool) (string, bool) {
	parsed, err := url.Parse(strings.TrimSpace(value))
	if err != nil || parsed.User != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return "", false
	}
	if !allowPath && parsed.Path != "" && parsed.Path != "/" {
		return "", false
	}
	if !allowPath && (parsed.RawQuery != "" || parsed.Fragment != "") {
		return "", false
	}
	hostname := strings.ToLower(parsed.Hostname())
	if hostname == "" {
		return "", false
	}
	port := parsed.Port()
	if (parsed.Scheme == "http" && port == "80") || (parsed.Scheme == "https" && port == "443") {
		port = ""
	}
	host := hostname
	if strings.Contains(hostname, ":") {
		host = "[" + hostname + "]"
	}
	if port != "" {
		host = net.JoinHostPort(hostname, port)
	}
	return strings.ToLower(parsed.Scheme) + "://" + host, true
}

// hostOf takes the host out of either a bare Host header or a full origin, without its port: a
// deployment behind a proxy sees the port the proxy forwards to, not the public one.
func hostOf(value string) string {
	text := strings.TrimSpace(strings.ToLower(value))
	if index := strings.Index(text, "://"); index >= 0 {
		text = text[index+3:]
	}
	if index := strings.IndexAny(text, "/?#"); index >= 0 {
		text = text[:index]
	}
	if strings.HasPrefix(text, "[") {
		if end := strings.Index(text, "]"); end >= 0 {
			return text[:end+1]
		}
		return text
	}
	if index := strings.LastIndex(text, ":"); index >= 0 {
		return text[:index]
	}
	return text
}

// PortOf narrows a Tesl `Int` to a listening port. A port is a 16-bit number, so anything
// outside that range is a configuration error worth failing at startup rather than silently
// binding somewhere else.
func PortOf(value Int) int {
	port, exact := value.Int64()
	if !exact || port < 1 || port > 65535 {
		panic("serve: port " + value.String() + " is not a valid TCP port (1-65535)")
	}
	return int(port)
}
