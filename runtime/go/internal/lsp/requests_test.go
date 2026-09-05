package lsp

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/tooling"
)

type requestCompiler struct {
	started     chan struct{}
	canceled    chan struct{}
	queries     atomic.Int32
	lateSuccess bool
}

func (compiler *requestCompiler) answer(ctx context.Context, flag, source string) ([]byte, tooling.Result, error) {
	if compiler.queries.Add(1) == 1 {
		close(compiler.started)
		<-ctx.Done()
		close(compiler.canceled)
		if !compiler.lateSuccess {
			return nil, tooling.Result{}, ctx.Err()
		}
	}
	switch flag {
	case "--completions-json":
		return []byte(`{"version":1,"completions":[{"label":"UnsafeLateEdit","detail":"type","kind":"type"}]}`), tooling.Result{}, nil
	case "--doc-json":
		return []byte(`{"version":1,"entries":[]}`), tooling.Result{}, nil
	case "--fmt":
		return []byte("formatted"), tooling.Result{}, nil
	default:
		value, err := json.Marshal(map[string]any{"version": 1, "type_at": map[string]any{
			"type": source, "file": "/tmp/module.tesl", "line": 0, "col": 0, "end_line": 0, "end_col": 1,
		}})
		return value, tooling.Result{}, err
	}
}

func (compiler *requestCompiler) QuerySourceJSON(ctx context.Context, flag, _, source string, _ ...string) ([]byte, tooling.Result, error) {
	return compiler.answer(ctx, flag, source)
}

func (compiler *requestCompiler) QueryJSON(ctx context.Context, args ...string) (json.RawMessage, tooling.Result, error) {
	return compiler.answer(ctx, args[0], "")
}

func (compiler *requestCompiler) FormatSource(ctx context.Context, _, source string) ([]byte, tooling.Result, error) {
	return compiler.answer(ctx, "--fmt", source)
}

type requestConnection struct {
	writer    *protocol.Writer
	responses chan protocol.Response
	status    chan int
	uri       string
}

func newRequestConnection(t *testing.T, compiler Compiler) *requestConnection {
	t.Helper()
	input, send := io.Pipe()
	receive, output := io.Pipe()
	ctx, cancel := context.WithCancel(context.Background())
	server := NewServer(compiler)
	path := filepath.Join(t.TempDir(), "module.tesl")
	uri := protocol.PathToURI(path)
	server.documents[uri] = document{URI: uri, Path: path, Version: 1, Text: "old"}
	connection := &requestConnection{writer: protocol.NewWriter(send), responses: make(chan protocol.Response, 64), status: make(chan int, 1), uri: uri}
	readerDone, serverDone := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(serverDone)
		connection.status <- server.Run(ctx, input, output)
		_ = output.Close()
	}()
	go func() {
		defer close(readerDone)
		defer close(connection.responses)
		reader := protocol.NewReader(receive)
		for {
			message, err := reader.Read()
			if err != nil {
				return
			}
			var notification protocol.Request
			if json.Unmarshal(message, &notification) == nil && notification.Method != "" {
				continue
			}
			response, err := protocol.DecodeResponse(message)
			if err != nil {
				t.Errorf("invalid response: %v", err)
				return
			}
			connection.responses <- response
		}
	}()
	t.Cleanup(func() {
		cancel()
		_ = send.Close()
		_ = receive.Close()
		awaitSignal(t, serverDone, "server shutdown")
		awaitSignal(t, readerDone, "response reader shutdown")
	})
	return connection
}

func awaitSignal(t *testing.T, signal <-chan struct{}, label string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(3 * time.Second):
		t.Fatalf("timed out waiting for %s", label)
	}
}

func (connection *requestConnection) send(t *testing.T, id, method string, params any) {
	t.Helper()
	raw, err := json.Marshal(params)
	if err != nil {
		t.Fatal(err)
	}
	if err := connection.writer.WriteJSON(protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(id), Method: method, Params: raw}); err != nil {
		t.Fatal(err)
	}
}

func (connection *requestConnection) position() map[string]any {
	return map[string]any{"textDocument": map[string]string{"uri": connection.uri}, "position": protocol.Position{}}
}

func (connection *requestConnection) response(t *testing.T, id string, code int) protocol.Response {
	t.Helper()
	select {
	case response, ok := <-connection.responses:
		if !ok {
			t.Fatal("server closed before response")
		}
		if string(response.ID) != id {
			t.Fatalf("response id %s, want %s", response.ID, id)
		}
		if code == 0 && response.Error != nil {
			t.Fatalf("response error: %v", response.Error)
		}
		if code != 0 && (response.Error == nil || response.Error.Code != code || len(response.Result) != 0) {
			t.Fatalf("response %#v, want error %d without result/edits", response, code)
		}
		return response
	case <-time.After(3 * time.Second):
		t.Fatalf("request %s did not finish", id)
	}
	return protocol.Response{}
}

func TestServerCancelsActiveRequestsAndDiscardsLateResults(t *testing.T) {
	for _, method := range []string{"textDocument/hover", "textDocument/completion", "textDocument/formatting", "completionItem/resolve"} {
		for _, late := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/late=%v", method, late), func(t *testing.T) {
				compiler := &requestCompiler{started: make(chan struct{}), canceled: make(chan struct{}), lateSuccess: late}
				connection := newRequestConnection(t, compiler)
				params := connection.position()
				if method == "completionItem/resolve" {
					params = map[string]any{"label": "List.length"}
				}
				connection.send(t, `"query"`, method, params)
				awaitSignal(t, compiler.started, "compiler request")
				connection.send(t, "", "$/cancelRequest", map[string]string{"id": "query"})
				awaitSignal(t, compiler.canceled, "compiler cancellation")
				connection.response(t, `"query"`, requestCancelled)
				// Reusing a completed id is valid and must not inherit cancellation.
				connection.send(t, `"query"`, "textDocument/hover", connection.position())
				connection.response(t, `"query"`, 0)
				connection.send(t, "99", "shutdown", nil)
				connection.response(t, "99", 0)
				connection.send(t, "", "exit", nil)
				select {
				case status := <-connection.status:
					if status != 0 {
						t.Fatalf("exit status %d", status)
					}
				case <-time.After(3 * time.Second):
					t.Fatal("exit stalled")
				}
			})
		}
	}
}

func TestServerCancelsQueuedRequestWithoutCallingCompiler(t *testing.T) {
	compiler := &requestCompiler{started: make(chan struct{}), canceled: make(chan struct{})}
	connection := newRequestConnection(t, compiler)
	connection.send(t, "1", "textDocument/hover", connection.position())
	awaitSignal(t, compiler.started, "first query")
	connection.send(t, "2", "textDocument/completion", connection.position())
	connection.send(t, "", "$/cancelRequest", map[string]int{"id": 2})
	connection.send(t, "", "$/cancelRequest", map[string]int{"id": 1})
	connection.response(t, "1", requestCancelled)
	connection.response(t, "2", requestCancelled)
	if compiler.queries.Load() != 1 {
		t.Fatalf("canceled queued query ran: %d", compiler.queries.Load())
	}
}

func TestServerPreservesDocumentOrderAroundCancellation(t *testing.T) {
	compiler := &requestCompiler{started: make(chan struct{}), canceled: make(chan struct{})}
	connection := newRequestConnection(t, compiler)
	connection.send(t, "1", "textDocument/hover", connection.position())
	awaitSignal(t, compiler.started, "old source query")
	connection.send(t, "", "textDocument/didChange", map[string]any{
		"textDocument": map[string]any{"uri": connection.uri, "version": 2}, "contentChanges": []map[string]string{{"text": "new"}},
	})
	connection.send(t, "2", "textDocument/hover", connection.position())
	connection.send(t, "", "$/cancelRequest", map[string]int{"id": 1})
	connection.response(t, "1", requestCancelled)
	response := connection.response(t, "2", 0)
	var result struct {
		Contents struct {
			Value string `json:"value"`
		} `json:"contents"`
	}
	if json.Unmarshal(response.Result, &result) != nil || result.Contents.Value != "new" {
		t.Fatalf("hover used wrong source: %s", response.Result)
	}
}

func dormantStream(t *testing.T) *requestStream {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	return &requestStream{ctx: ctx, cancel: cancel, messages: make(chan incomingRequest, maxPendingMessages), pending: make(map[string]*pendingRequest)}
}

func pendingItem(stream *requestStream, id string) incomingRequest {
	key, _ := requestKey(json.RawMessage(id))
	ctx, cancel := context.WithCancel(stream.ctx)
	return incomingRequest{key: key, pending: &pendingRequest{ctx: ctx, cancel: cancel}, bytes: 1}
}

func TestRequestCancellationIdentityAndLateNotifications(t *testing.T) {
	stream := dormantStream(t)
	first := pendingItem(stream, `"ab"`)
	if !stream.enqueue(first) {
		t.Fatal("enqueue failed")
	}
	for _, raw := range []string{`{}`, `null`, `{"id":null}`, `{"id":true}`, `{"id":1}`, `{"id":"unknown"}`} {
		stream.cancelRequest(json.RawMessage(raw))
		if first.pending.ctx.Err() != nil {
			t.Fatalf("unrelated cancellation %s affected request", raw)
		}
	}
	stream.cancelRequest(json.RawMessage(`{"id":"\u0061b"}`))
	if first.pending.ctx.Err() == nil || !stream.complete(json.RawMessage(`"ab"`)) {
		t.Fatal("escaped id did not cancel")
	}
	stream.cancelRequest(json.RawMessage(`{"id":"ab"}`))
	second := pendingItem(stream, `"ab"`)
	if !stream.enqueue(second) {
		t.Fatal("reuse failed")
	}
	stream.finish(first)
	if second.pending.ctx.Err() != nil || stream.complete(json.RawMessage(`"ab"`)) {
		t.Fatal("late cancel/old cleanup affected reused id")
	}
	stream.finish(second)
}

func TestRequestKeysRejectInvalidIDsAndDistinguishStrings(t *testing.T) {
	for _, raw := range []string{"", " null ", "{}", "[]", "true", "1.5", "2147483648", "-2147483649"} {
		if key, valid := requestKey(json.RawMessage(raw)); valid {
			t.Errorf("accepted %q as %q", raw, key)
		}
	}
	number, _ := requestKey(json.RawMessage(`1`))
	name, _ := requestKey(json.RawMessage(`"1"`))
	if number == name {
		t.Fatal("numeric/string ids collided")
	}
}

func TestRequestStreamBoundsCancelOwnedWork(t *testing.T) {
	for _, bound := range []string{"count", "bytes", "duplicate"} {
		t.Run(bound, func(t *testing.T) {
			stream := dormantStream(t)
			active := pendingItem(stream, "1")
			if !stream.enqueue(active) {
				t.Fatal("first enqueue")
			}
			var refused bool
			switch bound {
			case "count":
				for i := 1; i < maxPendingMessages; i++ {
					if !stream.enqueue(incomingRequest{bytes: 1}) {
						t.Fatal("premature limit")
					}
				}
				refused = !stream.enqueue(incomingRequest{bytes: 1})
			case "bytes":
				refused = !stream.enqueue(incomingRequest{bytes: maxPendingBytes})
			case "duplicate":
				refused = !stream.enqueue(active)
			}
			if !refused || stream.failed() == nil || active.pending.ctx.Err() == nil {
				t.Fatal("overload did not refuse/cancel explicitly")
			}
		})
	}
}

func TestCancellationRacesWithExactlyOneResponseClaim(t *testing.T) {
	stream := dormantStream(t)
	for i := 0; i < 100; i++ {
		item := pendingItem(stream, "1")
		if !stream.enqueue(item) {
			t.Fatal("enqueue")
		}
		<-stream.messages
		var group sync.WaitGroup
		group.Add(2)
		go func() { defer group.Done(); stream.cancelRequest(json.RawMessage(`{"id":1}`)) }()
		go func() { defer group.Done(); stream.complete(json.RawMessage(`1`)) }()
		group.Wait()
		if stream.complete(json.RawMessage(`1`)) {
			t.Fatal("second response claim observed cancellation")
		}
		stream.finish(item)
	}
}

func TestServerContextCancellationClosesBlockedInput(t *testing.T) {
	input, output := io.Pipe()
	defer func() { _ = output.Close() }()
	ctx, cancel := context.WithCancel(context.Background())
	server := NewServer(nil)
	finished := make(chan struct{})
	go func() { defer close(finished); server.Run(ctx, input, io.Discard) }()
	cancel()
	awaitSignal(t, finished, "cancellation with idle input")
	awaitSignal(t, server.requests.done, "input reader cleanup")
}
