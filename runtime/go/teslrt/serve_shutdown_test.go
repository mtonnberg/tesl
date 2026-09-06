package teslrt

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"sync"
	"testing"
	"time"
)

func TestServeShutdownJoinsActiveRequestBeforeReturning(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	entered, release, handlerDone := make(chan struct{}), make(chan struct{}), make(chan struct{})
	resume := sync.OnceFunc(func() { close(release) })
	defer resume()
	server := &http.Server{ReadHeaderTimeout: time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		close(entered)
		<-release
		_, _ = io.WriteString(w, "drained")
		close(handlerDone)
	})}
	t.Cleanup(func() { _ = server.Close() })
	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	acceptStopped, done := make(chan struct{}), make(chan error, 1)
	go func() {
		done <- serveHTTPUntilShutdown(ctx, server, func() error {
			err := server.Serve(listener)
			close(acceptStopped)
			return err
		}, 5*time.Second)
	}()
	response := make(chan error, 1)
	go func() {
		client := &http.Client{Timeout: 5 * time.Second}
		reply, err := client.Get("http://" + listener.Addr().String())
		if err == nil {
			_, err = io.ReadAll(reply.Body)
			_ = reply.Body.Close()
		}
		response <- err
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("request did not enter")
	}
	stop()
	select {
	case <-acceptStopped:
	case <-time.After(5 * time.Second):
		t.Fatal("listener did not stop")
	}
	select {
	case err := <-done:
		t.Fatalf("Serve returned while an active request still held its scope: %v", err)
	default:
	}
	resume()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	select {
	case <-handlerDone:
	default:
		t.Fatal("Serve returned before the handler completed")
	}
	if err := <-response; err != nil {
		t.Fatal(err)
	}
}

func TestServeListenFailureDoesNotWaitForSignal(t *testing.T) {
	failure := errors.New("listen refused")
	done := make(chan error, 1)
	go func() {
		done <- serveHTTPUntilShutdown(context.Background(), &http.Server{}, func() error { return failure }, time.Second)
	}()
	select {
	case err := <-done:
		if !errors.Is(err, failure) {
			t.Fatalf("listen failure lost: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("listen failure leaked the shutdown waiter")
	}
}

func TestServeShutdownTimeoutAndListenFailureJoinCanceledHandlers(t *testing.T) {
	for _, reason := range []string{"timeout", "listener failure"} {
		t.Run(reason, func(t *testing.T) {
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = listener.Close() })
			entered, release, handlerDone := make(chan struct{}), make(chan struct{}), make(chan struct{})
			resume := sync.OnceFunc(func() { close(release) })
			defer resume()
			server := &http.Server{ReadHeaderTimeout: time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				close(entered)
				<-release // Deliberately ignore request cancellation after socket close.
				_, _ = io.WriteString(w, "returned after cancellation")
				close(handlerDone)
			})}
			t.Cleanup(func() { _ = server.Close() })
			ctx, stop := context.WithCancel(context.Background())
			defer stop()
			done, response := make(chan error, 1), make(chan error, 1)
			go func() {
				done <- serveHTTPUntilShutdown(ctx, server, func() error { return server.Serve(listener) }, 20*time.Millisecond)
			}()
			go func() {
				client := &http.Client{Timeout: 5 * time.Second}
				reply, err := client.Get("http://" + listener.Addr().String())
				if err == nil {
					_, err = io.ReadAll(reply.Body)
					_ = reply.Body.Close()
				}
				response <- err
			}()
			select {
			case <-entered:
			case <-time.After(5 * time.Second):
				t.Fatal("request did not enter")
			}
			if reason == "timeout" {
				stop()
			} else if err := listener.Close(); err != nil {
				t.Fatal(err)
			}
			// Actual transport failure proves Close has followed the expired
			// graceful drain; elapsed time alone is not the safety observation.
			select {
			case err := <-response:
				if err == nil {
					t.Fatal("held response unexpectedly completed")
				}
			case <-time.After(5 * time.Second):
				t.Fatal("shutdown never closed the held response")
			}
			select {
			case err := <-done:
				t.Fatalf("scope returned before canceled handler joined: %v", err)
			default:
			}
			resume()
			select {
			case err := <-done:
				if !errors.Is(err, context.DeadlineExceeded) {
					t.Fatalf("graceful deadline failure lost: %v", err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("completed handler did not release its scope")
			}
			select {
			case <-handlerDone:
			default:
				t.Fatal("scope returned before handler completion")
			}
		})
	}
}
