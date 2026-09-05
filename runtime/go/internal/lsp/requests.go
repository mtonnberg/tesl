package lsp

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"sync"

	"tesl.dev/runtime/go/internal/protocol"
)

const (
	requestCancelled   = -32800
	maxPendingMessages = 64
	maxPendingBytes    = 16 << 20
)

// Request handlers retain a single owner of document state. A separate reader
// can cancel active or queued queries without processing document changes out of
// order. Both queued bytes and outstanding request identities are bounded.
type requestStream struct {
	mu       sync.Mutex
	ctx      context.Context
	cancel   context.CancelFunc
	messages chan incomingRequest
	done     chan struct{}
	pending  map[string]*pendingRequest
	bytes    int
	failure  error
}

type pendingRequest struct {
	ctx            context.Context
	cancel         context.CancelFunc
	clientCanceled bool
}

type incomingRequest struct {
	request  protocol.Request
	pending  *pendingRequest
	key      string
	bytes    int
	err      error
	code     int
	terminal bool
}

// JSON string escapes do not change identity; the string "1" and integer 1 do.
func requestKey(id json.RawMessage) (string, bool) {
	id = bytes.TrimSpace(id)
	if len(id) == 0 || bytes.Equal(id, []byte("null")) {
		return "", false
	}
	var name string
	if json.Unmarshal(id, &name) == nil {
		return "s:" + name, true
	}
	var number int32
	if json.Unmarshal(id, &number) == nil {
		return "n:" + strconv.FormatInt(int64(number), 10), true
	}
	return "", false
}

func newRequestStream(ctx context.Context, input io.Reader) *requestStream {
	ctx, cancel := context.WithCancel(ctx)
	stream := &requestStream{ctx: ctx, cancel: cancel,
		messages: make(chan incomingRequest, maxPendingMessages), done: make(chan struct{}),
		pending: make(map[string]*pendingRequest)}
	go stream.read(input)
	return stream
}

func (stream *requestStream) read(input io.Reader) {
	defer close(stream.done)
	defer close(stream.messages)
	reader := protocol.NewReader(input)
	for stream.ctx.Err() == nil {
		message, err := reader.Read()
		if errors.Is(err, io.EOF) {
			return
		}
		if err != nil {
			stream.enqueue(incomingRequest{err: err, code: parseError, terminal: true})
			return
		}
		request, err := protocol.DecodeRequest(message)
		if err != nil {
			if !stream.enqueue(incomingRequest{err: err, code: invalidRequest, bytes: len(message)}) {
				return
			}
			continue
		}
		if request.Method == "$/cancelRequest" && len(request.ID) == 0 {
			stream.cancelRequest(request.Params)
			continue
		}
		item := incomingRequest{request: request, bytes: len(message)}
		if len(request.ID) != 0 {
			var valid bool
			item.key, valid = requestKey(request.ID)
			if !valid {
				item.err, item.code = errors.New("LSP request id must be a string or 32-bit integer"), invalidRequest
			} else {
				ctx, cancel := context.WithCancel(stream.ctx)
				item.pending = &pendingRequest{ctx: ctx, cancel: cancel}
			}
		}
		if !stream.enqueue(item) {
			if item.pending != nil {
				item.pending.cancel()
			}
			return
		}
		if request.Method == "exit" && len(request.ID) == 0 {
			return
		}
	}
}

func (stream *requestStream) enqueue(item incomingRequest) bool {
	stream.mu.Lock()
	defer stream.mu.Unlock()
	if stream.ctx.Err() != nil {
		return false
	}
	if item.pending != nil && stream.pending[item.key] != nil {
		stream.failure = errors.New("duplicate outstanding LSP request id")
	} else if item.bytes > maxPendingBytes-stream.bytes {
		stream.failure = errors.New("LSP pending message byte limit exceeded")
	} else {
		select {
		case stream.messages <- item:
			stream.bytes += item.bytes
			if item.pending != nil {
				stream.pending[item.key] = item.pending
			}
			return true
		default:
			stream.failure = errors.New("LSP pending message count limit exceeded")
		}
	}
	// Backpressure must not prevent a cancellation notification from being read.
	// Refuse an overloaded connection explicitly instead of growing the queue or
	// dropping a didChange and continuing with incorrect document contents.
	stream.cancel()
	return false
}

func (stream *requestStream) cancelRequest(raw json.RawMessage) {
	var params struct {
		ID json.RawMessage `json:"id"`
	}
	if json.Unmarshal(raw, &params) != nil {
		return
	}
	key, valid := requestKey(params.ID)
	if !valid {
		return
	}
	stream.mu.Lock()
	defer stream.mu.Unlock()
	if pending := stream.pending[key]; pending != nil {
		pending.clientCanceled = true
		pending.cancel()
	}
}

// Claim the response under the same lock as cancellation. A late cancellation
// cannot rewrite an already-claimed response or cancel a later reused id.
func (stream *requestStream) complete(id json.RawMessage) bool {
	if stream == nil {
		return false
	}
	key, valid := requestKey(id)
	if !valid {
		return false
	}
	stream.mu.Lock()
	defer stream.mu.Unlock()
	pending := stream.pending[key]
	if pending == nil {
		return false
	}
	delete(stream.pending, key)
	return pending.clientCanceled
}

func (stream *requestStream) finish(item incomingRequest) {
	stream.mu.Lock()
	defer stream.mu.Unlock()
	stream.bytes -= item.bytes
	if item.pending != nil {
		if stream.pending[item.key] == item.pending {
			delete(stream.pending, item.key)
		}
		item.pending.cancel()
	}
}

func (stream *requestStream) failed() error {
	stream.mu.Lock()
	defer stream.mu.Unlock()
	return stream.failure
}

func (stream *requestStream) close(input io.Reader) {
	stream.cancel()
	// Run owns its input for the session. Blocking input must implement Close so
	// exit/context cancellation can also release the reader goroutine (stdio does).
	if closer, ok := input.(io.Closer); ok {
		_ = closer.Close()
		<-stream.done
	}
}
