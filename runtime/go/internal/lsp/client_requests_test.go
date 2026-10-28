package lsp

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"reflect"
	"strings"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/protocol"
)

func TestClientResponseStrictEnvelope(t *testing.T) {
	for _, raw := range []string{
		`{"jsonrpc":"2.0","id":"one","result":null}`,
		`{"id":-2147483648,"result":{"applied":false},"jsonrpc":"2.0"}`,
		`{"jsonrpc":"2.0","id":"one","error":{"code":-32800,"message":"cancelled","data":{"why":"test"}}}`,
	} {
		if _, err := decodeClientResponse([]byte(raw)); err != nil {
			t.Errorf("valid response refused: %s: %v", raw, err)
		}
	}
	for _, raw := range []string{
		`null`, `[]`, `true`, `{`, `{} trailing`,
		`{"jsonrpc":"2.0","id":"one","result":null} {}`,
		`{"jsonrpc":"2.0","id":"one","result":null,}`,
		`{"jsonrpc":"2.0","id":"one","id":"two","result":null}`,
		`{"jsonrpc":"2.0","id":"one","result":null,"result":true}`,
		`{"jsonrpc":"2.0","id":"one","result":null,"method":"x"}`,
		`{"JSONRPC":"2.0","id":"one","result":null}`,
		`{"jsonrpc":"2.0","ID":"one","result":null}`,
		`{"jsonrpc":"2.0","id":"one","Result":null}`,
		`{"jsonrpc":"1.0","id":"one","result":null}`,
		`{"jsonrpc":null,"id":"one","result":null}`,
		`{"jsonrpc":"2.0","result":null}`,
		`{"jsonrpc":"2.0","id":null,"result":null}`,
		`{"jsonrpc":"2.0","id":true,"result":null}`,
		`{"jsonrpc":"2.0","id":1.1,"result":null}`,
		`{"jsonrpc":"2.0","id":2147483648,"result":null}`,
		`{"jsonrpc":"2.0","id":"one"}`,
		`{"jsonrpc":"2.0","id":"one","result":null,"error":null}`,
		`{"jsonrpc":"2.0","id":"one","error":null}`,
		`{"jsonrpc":"2.0","id":"one","error":{}}`,
		`{"jsonrpc":"2.0","id":"one","error":{"code":1,"code":2,"message":"no"}}`,
		`{"jsonrpc":"2.0","id":"one","error":{"code":1,"message":null}}`,
		`{"jsonrpc":"2.0","id":"one","error":{"code":null,"message":"no"}}`,
		`{"jsonrpc":"2.0","id":"one","error":{"code":1.5,"message":"no"}}`,
		`{"jsonrpc":"2.0","id":"one","error":{"code":1,"message":2}}`,
		"{\"jsonrpc\":\"2.0\",\"id\":\"one\",\"result\":\"\xff\"}",
	} {
		if response, err := decodeClientResponse([]byte(raw)); err == nil {
			t.Errorf("invalid response accepted: %s: %+v", raw, response)
		}
	}
}

func TestClientRequestsAreBoundedAndCompleteExactlyOnce(t *testing.T) {
	server := NewServer(nil)
	var output bytes.Buffer
	writer := protocol.NewWriter(&output)
	called := 0
	var next json.RawMessage
	id, err := server.sendClientRequest(writer, "workspace/applyEdit", map[string]any{"edit": map[string]any{}}, time.Minute, func(response protocol.Response, err error) error {
		called++
		if err != nil || string(response.Result) != `{"applied":true}` {
			t.Fatalf("reply corrupted: %+v %v", response, err)
		}
		var sendErr error
		next, sendErr = server.sendClientRequest(writer, "workspace/applyEdit", map[string]any{}, time.Minute, func(protocol.Response, error) error { called++; return nil })
		return sendErr
	})
	if err != nil {
		t.Fatal(err)
	}
	frame, err := protocol.NewReader(&output).Read()
	if err != nil {
		t.Fatal(err)
	}
	request, err := protocol.DecodeRequest(frame)
	if err != nil || request.Method != "workspace/applyEdit" || !bytes.Equal(request.ID, id) {
		t.Fatalf("bad outbound request: %s %v", frame, err)
	}
	for _, unrelated := range []string{`1`, `"unknown"`, `null`} {
		if err := server.finishClientRequest(protocol.Response{ID: json.RawMessage(unrelated)}); err != nil || called != 0 {
			t.Fatalf("unrelated response consumed request: %v", err)
		}
	}
	response := protocol.Response{ID: id, Result: json.RawMessage(`{"applied":true}`)}
	if err := server.finishClientRequest(response); err != nil || called != 1 || bytes.Equal(id, next) {
		t.Fatalf("reply/reentrant request failed: %v", err)
	}
	if err := server.finishClientRequest(response); err != nil || called != 1 {
		t.Fatal("duplicate response reran continuation")
	}
	if len(server.clientRequests) != 1 {
		t.Fatal("completed request retained")
	}
	for i := 1; i < maxClientRequests; i++ {
		if _, err := server.sendClientRequest(writer, "workspace/applyEdit", nil, time.Minute, func(protocol.Response, error) error { return nil }); err != nil {
			t.Fatal(err)
		}
	}
	before := output.Len()
	if _, err := server.sendClientRequest(writer, "workspace/applyEdit", nil, time.Minute, func(protocol.Response, error) error { return nil }); err == nil || output.Len() != before {
		t.Fatal("outbound request bound failed")
	}
}

func TestClientRequestsUnknownOutcomesAndInvalidSends(t *testing.T) {
	server := NewServer(nil)
	writer := protocol.NewWriter(io.Discard)
	var outcomes []error
	callback := func(_ protocol.Response, err error) error { outcomes = append(outcomes, err); return nil }
	id, err := server.sendClientRequest(writer, "workspace/applyEdit", nil, time.Second, callback)
	if err != nil {
		t.Fatal(err)
	}
	if err := server.expireClientRequests(time.Now().Add(time.Minute)); err != nil || len(outcomes) != 1 || !errors.Is(outcomes[0], errClientReplyTimeout) {
		t.Fatalf("timeout lost uncertain outcome: %v %v", outcomes, err)
	}
	if err := server.finishClientRequest(protocol.Response{ID: id, Result: json.RawMessage(`true`)}); err != nil || len(outcomes) != 1 {
		t.Fatal("late reply after timeout reran continuation")
	}
	if _, err := server.sendClientRequest(writer, "workspace/applyEdit", nil, time.Second, callback); err != nil {
		t.Fatal(err)
	}
	server.closeClientRequests()
	server.closeClientRequests()
	if len(outcomes) != 2 || !errors.Is(outcomes[1], errClientDisconnected) || len(server.clientRequests) != 0 {
		t.Fatalf("disconnect did not release pending request: %v", outcomes)
	}
	if _, err := server.sendClientRequest(writer, "workspace/applyEdit", nil, time.Second, callback); !errors.Is(err, errClientDisconnected) {
		t.Fatal("closed session sent another request")
	}
	for _, test := range []struct {
		method  string
		params  any
		timeout time.Duration
	}{
		{"", nil, time.Second}, {"x", nil, 0}, {"x", nil, time.Hour},
		{"x", make(chan int), time.Second}, {"x", 1, time.Second}, {"x", "scalar", time.Second},
		{"x", strings.Repeat("x", protocol.DefaultMaxMessageBytes/2), time.Second},
	} {
		server := NewServer(nil)
		var output bytes.Buffer
		if _, err := server.sendClientRequest(protocol.NewWriter(&output), test.method, test.params, test.timeout, callback); err == nil || len(server.clientRequests) != 0 || output.Len() != 0 {
			t.Fatalf("invalid outbound request was sent: %s", test.method)
		}
	}
	server = NewServer(nil)
	server.nextClientRequestID = math.MaxUint64
	if _, err := server.sendClientRequest(writer, "x", nil, time.Second, callback); err == nil {
		t.Fatal("request id wrapped")
	}
}

type failedClientRequestWriter struct{}

func (failedClientRequestWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

func TestClientRequestWriteFailureDeadlineAndRemoteError(t *testing.T) {
	server := NewServer(nil)
	called := 0
	callback := func(protocol.Response, error) error { called++; return nil }
	if _, err := server.sendClientRequest(protocol.NewWriter(failedClientRequestWriter{}), "x", nil, time.Second, callback); !errors.Is(err, io.ErrClosedPipe) || len(server.clientRequests) != 0 || called != 0 {
		t.Fatalf("failed write retained request or called continuation: %v", err)
	}
	if _, err := server.sendClientRequest(protocol.NewWriter(io.Discard), "x", nil, time.Second, nil); err == nil {
		t.Fatal("nil continuation accepted")
	}
	var outcomes []error
	id, err := server.sendClientRequest(protocol.NewWriter(io.Discard), "x", nil, time.Minute, func(response protocol.Response, err error) error {
		outcomes = append(outcomes, err)
		if len(response.Result) != 0 || response.Error != nil {
			t.Fatal("late response presented as a certain outcome")
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	key, _ := requestKey(id)
	pending := server.clientRequests[key]
	pending.deadline = time.Now().Add(-time.Second)
	server.clientRequests[key] = pending
	if err := server.finishClientRequest(protocol.Response{ID: id, Result: json.RawMessage(`true`)}); err != nil || len(outcomes) != 1 || !errors.Is(outcomes[0], errClientReplyTimeout) {
		t.Fatalf("deadline was bypassed by queued reply: %v %v", outcomes, err)
	}
	remote, err := decodeClientResponse([]byte(`{"jsonrpc":"2.0","id":"one","error":{"code":-32603,"message":"edit failed","data":{"file":"app.tesl"}}}`))
	if err != nil {
		t.Fatal(err)
	}
	id, err = server.sendClientRequest(protocol.NewWriter(io.Discard), "x", nil, time.Minute, func(response protocol.Response, err error) error {
		if err != nil || !reflect.DeepEqual(response.Error, remote.Error) {
			t.Fatalf("remote error was swallowed: %+v %v", response, err)
		}
		return io.ErrUnexpectedEOF
	})
	if err != nil {
		t.Fatal(err)
	}
	remote.ID = id
	if err := server.finishClientRequest(remote); !errors.Is(err, io.ErrUnexpectedEOF) || len(server.clientRequests) != 0 {
		t.Fatal("continuation failure was swallowed or left request active")
	}
}

func TestClientRequestIdleDeadlineAndDisconnectThroughSession(t *testing.T) {
	for _, disconnect := range []bool{false, true} {
		input, send := io.Pipe()
		ctx, cancel := context.WithCancel(context.Background())
		server := NewServer(nil)
		finished := make(chan struct{})
		outcome := make(chan error, 1)
		timeout := 5 * time.Millisecond
		if disconnect {
			timeout = time.Minute
		}
		if _, err := server.sendClientRequest(protocol.NewWriter(io.Discard), "x", nil, timeout, func(_ protocol.Response, err error) error { outcome <- err; return nil }); err != nil {
			t.Fatal(err)
		}
		go func() { defer close(finished); server.Run(ctx, input, io.Discard) }()
		t.Cleanup(func() { cancel(); _ = send.Close(); awaitSignal(t, finished, "idle client session shutdown") })
		want := errClientReplyTimeout
		if disconnect {
			_ = send.Close()
			want = errClientDisconnected
		}
		select {
		case err := <-outcome:
			if !errors.Is(err, want) {
				t.Fatalf("wrong idle session outcome: %v, want %v", err, want)
			}
		case <-time.After(3 * time.Second):
			t.Fatal("idle session did not resolve pending client request")
		}
	}
}

func FuzzClientResponseEnvelopes(f *testing.F) {
	for _, seed := range []string{
		`{"jsonrpc":"2.0","id":"tesl-client-1","result":{"applied":true}}`,
		`{"jsonrpc":"2.0","id":"tesl-client-1","error":{"code":-32800,"message":"cancelled"}}`,
		`{"jsonrpc":"2.0","id":0,"result":null}`,
		`{"jsonrpc":"2.0","id":0,"id":1,"result":true}`,
	} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, raw []byte) {
		if len(raw) > 64<<10 {
			t.Skip()
		}
		response, err := decodeClientResponse(raw)
		if err != nil {
			return
		}
		if _, valid := requestKey(response.ID); !valid || (response.Error == nil) == (len(response.Result) == 0) {
			t.Fatal("accepted response lacks an identity or a unique result")
		}
		standard, err := protocol.DecodeResponse(raw)
		if err != nil || !reflect.DeepEqual(response, standard) {
			t.Fatalf("strict consumer disagrees with the wire response: %v", err)
		}
		encoded, err := json.Marshal(response)
		if err != nil {
			t.Fatal(err)
		}
		again, err := decodeClientResponse(encoded)
		beforeKey, _ := requestKey(response.ID)
		afterKey, _ := requestKey(again.ID)
		if err != nil || beforeKey != afterKey || (response.Error == nil) != (again.Error == nil) {
			t.Fatalf("response identity changed on serialization: %v", err)
		}
	})
}

func TestClientResponsesUseBoundedOrderedQueue(t *testing.T) {
	var input bytes.Buffer
	writer := protocol.NewWriter(&input)
	for i := 0; i <= maxPendingMessages; i++ {
		if err := writer.WriteJSON(protocol.Response{JSONRPC: "2.0", ID: json.RawMessage(`"unsolicited"`), Result: json.RawMessage(`null`)}); err != nil {
			t.Fatal(err)
		}
	}
	stream := newRequestStream(context.Background(), &input)
	awaitSignal(t, stream.done, "bounded response reader")
	defer stream.close(&input)
	if stream.failed() == nil || stream.ctx.Err() == nil || len(stream.messages) != maxPendingMessages {
		t.Fatal("unsolicited client responses bypassed the queue bound")
	}
	for item := range stream.messages {
		if item.response == nil || item.pending != nil || item.err != nil {
			t.Fatal("response was confused with a client request")
		}
		stream.finish(item)
	}
	if stream.bytes != 0 || len(stream.pending) != 0 {
		t.Fatal("response queue leaked accounting or incoming request identities")
	}
}

func TestMixedRequestResponseEnvelopeCannotCompleteClientRequest(t *testing.T) {
	var input bytes.Buffer
	if err := protocol.NewWriter(&input).WriteJSON(json.RawMessage(`{"jsonrpc":"2.0","id":"tesl-client-1","method":"initialized","result":{"applied":true}}`)); err != nil {
		t.Fatal(err)
	}
	stream := newRequestStream(context.Background(), &input)
	awaitSignal(t, stream.done, "mixed envelope reader")
	defer stream.close(&input)
	item := <-stream.messages
	if item.err == nil || item.code != invalidRequest || item.response != nil || item.pending != nil {
		t.Fatalf("ambiguous envelope admitted: %+v", item)
	}
	stream.finish(item)
}

func TestClientRepliesFollowDocumentNotificationsThroughSession(t *testing.T) {
	input, send := io.Pipe()
	receive, output := io.Pipe()
	ctx, cancel := context.WithCancel(context.Background())
	server := NewServer(&fakeCompiler{payload: []byte(`{"version":1,"diagnostics":[]}`)})
	path := testFilePath("app.tesl")
	uri := protocol.PathToURI(path)
	server.documents[uri] = document{URI: uri, Path: path, Version: 1, Text: "old"}
	finished := make(chan struct{})
	observed := make(chan document, 1)
	go func() {
		defer close(finished)
		writer := protocol.NewWriter(output)
		_, err := server.sendClientRequest(writer, "workspace/applyEdit", map[string]any{"label": "test edit"}, time.Minute, func(response protocol.Response, err error) error {
			if err == nil && string(response.Result) == `{"applied":true}` {
				observed <- server.documents[uri]
			}
			return nil
		})
		if err == nil {
			server.Run(ctx, input, output)
		}
		_ = output.Close()
	}()
	t.Cleanup(func() {
		cancel()
		_ = send.Close()
		_ = receive.Close()
		awaitSignal(t, finished, "client reply session shutdown")
	})
	reader := protocol.NewReader(receive)
	raw, err := reader.Read()
	if err != nil {
		t.Fatal(err)
	}
	request, err := protocol.DecodeRequest(raw)
	if err != nil || request.Method != "workspace/applyEdit" {
		t.Fatalf("outgoing edit missing: %s %v", raw, err)
	}
	// Drain diagnostic notifications and the ordinary request response, so the
	// same client/server transport is exercised in both directions concurrently.
	drained := make(chan struct{})
	ordinaryReply := make(chan json.RawMessage, 1)
	go func() {
		defer close(drained)
		for {
			raw, err := reader.Read()
			if err != nil {
				return
			}
			var response protocol.Response
			if json.Unmarshal(raw, &response) == nil && len(response.ID) != 0 {
				ordinaryReply <- response.ID
			}
		}
	}()
	t.Cleanup(func() { _ = receive.Close(); awaitSignal(t, drained, "client reply reader shutdown") })
	writer := protocol.NewWriter(send)
	change, _ := json.Marshal(map[string]any{"textDocument": map[string]any{"uri": uri, "version": 2}, "contentChanges": []any{map[string]string{"text": "new"}}})
	for _, message := range []any{
		// Request identifiers are scoped by direction. This incoming request
		// intentionally uses the same id as the pending server request.
		protocol.Request{JSONRPC: "2.0", ID: request.ID, Method: "initialize", Params: json.RawMessage(`{}`)},
		protocol.Request{JSONRPC: "2.0", Method: "textDocument/didChange", Params: change},
		protocol.Response{JSONRPC: "2.0", ID: request.ID, Result: json.RawMessage(`{"applied":true}`)},
	} {
		if err := writer.WriteJSON(message); err != nil {
			t.Fatal(err)
		}
	}
	select {
	case doc := <-observed:
		if doc.Version != 2 || doc.Text != "new" {
			t.Fatalf("edit acknowledgement overtook source change: %+v", doc)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("edit acknowledgement did not reach session continuation")
	}
	select {
	case id := <-ordinaryReply:
		if !bytes.Equal(id, request.ID) {
			t.Fatalf("wrong ordinary request reply: %s", id)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("direction-scoped request id collided")
	}
}
