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
	address := fmt.Sprintf(":%d", port)
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
	fmt.Fprintf(os.Stderr, "tesl: serving on http://localhost:%d\n", port)
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		panic("serve: " + err.Error())
	}
	return struct{}{}
}

// handlerWith wraps the router with the static-file surface an App may declare. The API routes
// are reached under `MountPath`; everything else the runtime owns answers on the raw path.
func (server Server) handlerWith(options ServeOptions) http.Handler {
	mount := strings.Trim(options.MountPath, "/")
	static := options.StaticDir
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		routed := request
		if mount != "" {
			trimmed := strings.TrimPrefix(strings.TrimPrefix(request.URL.Path, "/"), mount)
			if !strings.HasPrefix(strings.TrimPrefix(request.URL.Path, "/"), mount) {
				// Not under the mount prefix: only the static surface can answer it.
				if static != "" && serveStatic(writer, request, static) {
					return
				}
				writeResponse(writer, nil, Fail(404, "not found"))
				return
			}
			routed = request.Clone(request.Context())
			if trimmed == "" {
				trimmed = "/"
			}
			if !strings.HasPrefix(trimmed, "/") {
				trimmed = "/" + trimmed
			}
			routed.URL.Path = trimmed
		}
		if server.routeExists(routed) {
			server.ServeHTTP(writer, routed)
			return
		}
		if static != "" && serveStatic(writer, request, static) {
			return
		}
		server.ServeHTTP(writer, routed)
	})
}

// routeExists reports whether the router has a route for this path at all — used to decide
// between the API surface and the static one WITHOUT letting the router answer 404 first.
func (server Server) routeExists(request *http.Request) bool {
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

// ── Queue workers ─────────────────────────────────────────────────────────────

// StartWorkers activates a queue's workers: `concurrency` goroutines, each claiming and running
// one job at a time. `dead` selects the dead-letter worker instead of the ordinary one.
//
// A worker that finds nothing sleeps briefly rather than spinning: the in-memory store has no
// condition variable to wait on, and a busy loop would burn a core per queue. The Racket runtime
// waits on a semaphore instead — same behaviour, one poll interval of latency on an idle queue.
func StartWorkers(queue *Queue, handler func(any) JobOutcome, concurrency int, dead bool) struct{} {
	if concurrency < 1 {
		concurrency = 1
	}
	for range concurrency {
		go func() {
			for {
				outcome := JobOutcome{}
				if dead {
					outcome = ProcessNextDeadJob(queue, handler)
				} else {
					outcome = ProcessNextJob(queue, handler)
				}
				if !outcome.Ran {
					time.Sleep(50 * time.Millisecond)
				}
			}
		}()
	}
	return struct{}{}
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
	if origin == "" {
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
