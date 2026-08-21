package teslrt

import (
	"context"
	"errors"
	"fmt"
	"net/http"
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
	address := bindAddress(options)
	httpServer := &http.Server{
		Addr:              address,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
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
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		panic("serve: " + err.Error())
	}
	return struct{}{}
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
		}
		if server.declaredRouteExists(routed) {
			server.ServeHTTP(writer, routed)
			return
		}
		if static != "" && serveStatic(writer, request, static) {
			return
		}
		if mount != "" {
			writeResponse(writer, nil, Fail(404, "not found"))
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
// The path is resolved and then CHECKED to be inside the directory: `..` segments and absolute
// paths are how a static handler becomes an arbitrary-file read, and the check is on the
// resolved path rather than on the request text so an encoded traversal cannot slip past.
func serveStatic(writer http.ResponseWriter, request *http.Request, directory string) bool {
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		return false
	}
	root, err := filepath.Abs(directory)
	if err != nil {
		return false
	}
	relative := strings.TrimPrefix(path.Clean("/"+request.URL.Path), "/")
	if relative == "" {
		relative = "index.html"
	}
	candidate := filepath.Join(root, filepath.FromSlash(relative))
	if !strings.HasPrefix(candidate, root+string(os.PathSeparator)) && candidate != root {
		return false
	}
	if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
		http.ServeFile(writer, request, candidate)
		return true
	}
	// The SPA fallback: an unknown path serves index.html, so client-side routing works on a
	// cold load. Only when there IS an index.html — otherwise the router's own 404 is the honest
	// answer.
	index := filepath.Join(root, "index.html")
	if info, err := os.Stat(index); err == nil && !info.IsDir() {
		http.ServeFile(writer, request, index)
		return true
	}
	return false
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
// as HTML. Precedence matches `dsl/web.rkt` — the clause, then `TESL_CSP`, then a non-breaking
// `frame-ancestors 'none'` (it constrains framing, not script or style sources, so it cannot
// break a single-page app). A response that sets its own policy keeps it.
var (
	contentSecurityPolicyMutex sync.RWMutex
	contentSecurityPolicy      string
)

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
		return declared
	}
	if fromEnv := strings.TrimSpace(os.Getenv("TESL_CSP")); fromEnv != "" {
		return fromEnv
	}
	return "frame-ancestors 'none'"
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
		if strings.EqualFold(strings.TrimSpace(request.Header.Get("Sec-Fetch-Site")), "cross-site") {
			return Fail(403, "cross-site request refused"), true
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
