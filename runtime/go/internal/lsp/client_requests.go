package lsp

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"strconv"
	"time"
	"unicode/utf8"

	"tesl.dev/runtime/go/internal/protocol"
)

const maxClientRequests = 8

var (
	errClientReplyTimeout = errors.New("client reply timed out; request outcome is unknown")
	errClientDisconnected = errors.New("client disconnected; request outcome is unknown")
)

// Client requests are continuations owned by the session's main loop. A reply
// travels through the same bounded queue as document notifications, so an edit
// acknowledgement cannot overtake the didChange messages preceding it. Callers
// must return to the loop rather than synchronously waiting for their callback.
type clientRequest struct {
	deadline time.Time
	complete func(protocol.Response, error) error
}

func (server *Server) sendClientRequest(writer *protocol.Writer, method string, params any, timeout time.Duration, complete func(protocol.Response, error) error) (json.RawMessage, error) {
	if server.clientClosed || server.shutdown {
		return nil, errClientDisconnected
	}
	if method == "" || complete == nil || timeout <= 0 || timeout > time.Minute {
		return nil, fmt.Errorf("invalid client request")
	}
	if len(server.clientRequests) >= maxClientRequests || server.nextClientRequestID == math.MaxUint64 {
		return nil, fmt.Errorf("client request limit exceeded")
	}
	raw, err := json.Marshal(params)
	if err != nil {
		return nil, err
	}
	server.nextClientRequestID++
	id, _ := json.Marshal("tesl-client-" + strconv.FormatUint(server.nextClientRequestID, 10))
	request := protocol.Request{JSONRPC: "2.0", ID: id, Method: method, Params: raw}
	encoded, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	if len(encoded) > protocol.DefaultMaxMessageBytes/2 {
		return nil, fmt.Errorf("client request exceeds the editor message limit")
	}
	if _, err := protocol.DecodeRequest(encoded); err != nil {
		return nil, err
	}
	key, _ := requestKey(id)
	server.clientRequests[key] = clientRequest{deadline: time.Now().Add(timeout), complete: complete}
	if err := writer.WriteJSON(json.RawMessage(encoded)); err != nil {
		delete(server.clientRequests, key)
		// A partial transport write cannot establish whether the client acted.
		return nil, fmt.Errorf("client request write failed; outcome is unknown: %w", err)
	}
	return id, nil
}

func (server *Server) finishClientRequest(response protocol.Response) error {
	key, valid := requestKey(response.ID)
	if !valid {
		return nil
	}
	pending, exists := server.clientRequests[key]
	if !exists {
		return nil // Late, duplicate and unsolicited responses have no authority.
	}
	delete(server.clientRequests, key)
	if !time.Now().Before(pending.deadline) {
		return pending.complete(protocol.Response{}, errClientReplyTimeout)
	}
	return pending.complete(response, nil)
}

func (server *Server) clientRequestTimer() *time.Timer {
	var earliest time.Time
	for _, request := range server.clientRequests {
		if earliest.IsZero() || request.deadline.Before(earliest) {
			earliest = request.deadline
		}
	}
	if earliest.IsZero() {
		return nil
	}
	return time.NewTimer(time.Until(earliest))
}

func (server *Server) expireClientRequests(now time.Time) error {
	var expired []clientRequest
	for key, request := range server.clientRequests {
		if !now.Before(request.deadline) {
			expired = append(expired, request)
			delete(server.clientRequests, key)
		}
	}
	var failures []error
	for _, request := range expired {
		failures = append(failures, request.complete(protocol.Response{}, errClientReplyTimeout))
	}
	return errors.Join(failures...)
}

func (server *Server) closeClientRequests() {
	server.clientClosed = true
	pending := server.clientRequests
	server.clientRequests = make(map[string]clientRequest)
	for _, request := range pending {
		_ = request.complete(protocol.Response{}, errClientDisconnected)
	}
}

// Response envelopes are stricter than general diagnostic payloads: accepting a
// duplicate id or result could acknowledge a different edit than was requested.
// The result itself is opaque here; its operation-specific consumer validates it.
func clientResponseFields(raw []byte, allowed ...string) (map[string]json.RawMessage, error) {
	if !utf8.Valid(raw) {
		return nil, fmt.Errorf("client response is not UTF-8")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	start, err := decoder.Token()
	if err != nil || start != json.Delim('{') {
		return nil, fmt.Errorf("client response must be an object")
	}
	fields := make(map[string]json.RawMessage)
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		key, ok := token.(string)
		known := false
		for _, name := range allowed {
			known = known || key == name
		}
		if !ok || !known || fields[key] != nil {
			return nil, fmt.Errorf("invalid or duplicate client response field")
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return nil, err
		}
		fields[key] = value
	}
	if _, err := decoder.Token(); err != nil {
		return nil, err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, fmt.Errorf("trailing client response data")
	}
	return fields, nil
}

func decodeClientResponse(raw []byte) (protocol.Response, error) {
	fields, err := clientResponseFields(raw, "jsonrpc", "id", "result", "error")
	if err != nil {
		return protocol.Response{}, err
	}
	var version string
	if json.Unmarshal(fields["jsonrpc"], &version) != nil || version != "2.0" {
		return protocol.Response{}, fmt.Errorf("invalid client response version")
	}
	if _, valid := requestKey(fields["id"]); !valid {
		return protocol.Response{}, fmt.Errorf("invalid client response id")
	}
	result, hasResult := fields["result"]
	failure, hasError := fields["error"]
	if hasResult == hasError {
		return protocol.Response{}, fmt.Errorf("client response requires exactly one result or error")
	}
	response := protocol.Response{JSONRPC: version, ID: fields["id"], Result: result}
	if hasError {
		details, err := clientResponseFields(failure, "code", "message", "data")
		if err != nil {
			return protocol.Response{}, err
		}
		var code *int32
		var message *string
		if json.Unmarshal(details["code"], &code) != nil || code == nil || json.Unmarshal(details["message"], &message) != nil || message == nil {
			return protocol.Response{}, fmt.Errorf("invalid client response error")
		}
		response.Error = &protocol.Error{Code: int(*code), Message: *message, Data: details["data"]}
	}
	return response, nil
}
