// Package dap contains the wire-level Debug Adapter Protocol primitives.
package dap

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync/atomic"

	"tesl.dev/runtime/go/internal/protocol"
)

type Message interface {
	dapMessage()
}

type Request struct {
	Seq       int             `json:"seq"`
	Type      string          `json:"type"`
	Command   string          `json:"command"`
	Arguments json.RawMessage `json:"arguments,omitempty"`
}

func (Request) dapMessage() {}

type Response struct {
	Seq        int             `json:"seq"`
	Type       string          `json:"type"`
	RequestSeq int             `json:"request_seq"`
	Success    bool            `json:"success"`
	Command    string          `json:"command"`
	Message    string          `json:"message,omitempty"`
	Body       json.RawMessage `json:"body,omitempty"`
}

func (Response) dapMessage() {}

type Event struct {
	Seq   int             `json:"seq"`
	Type  string          `json:"type"`
	Event string          `json:"event"`
	Body  json.RawMessage `json:"body,omitempty"`
}

func (Event) dapMessage() {}

type envelope struct {
	Seq        int             `json:"seq"`
	Type       string          `json:"type"`
	Command    string          `json:"command"`
	RequestSeq int             `json:"request_seq"`
	Success    bool            `json:"success"`
	Event      string          `json:"event"`
	Arguments  json.RawMessage `json:"arguments"`
	Message    string          `json:"message"`
	Body       json.RawMessage `json:"body"`
}

func DecodeMessage(data []byte) (Message, error) {
	var value envelope
	decoder := json.NewDecoder(bytes.NewReader(data))
	if err := decoder.Decode(&value); err != nil {
		return nil, fmt.Errorf("dap: decode message: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return nil, errors.New("dap: trailing JSON value")
		}
		return nil, fmt.Errorf("dap: trailing JSON: %w", err)
	}
	if value.Type == "" {
		return nil, errors.New("dap: message type is empty")
	}
	switch value.Type {
	case "request":
		if value.Command == "" {
			return nil, errors.New("dap: request command is empty")
		}
		return Request{Seq: value.Seq, Type: value.Type, Command: value.Command, Arguments: value.Arguments}, nil
	case "response":
		if value.Command == "" {
			return nil, errors.New("dap: response command is empty")
		}
		return Response{
			Seq: value.Seq, Type: value.Type, RequestSeq: value.RequestSeq,
			Success: value.Success, Command: value.Command, Message: value.Message, Body: value.Body,
		}, nil
	case "event":
		if value.Event == "" {
			return nil, errors.New("dap: event name is empty")
		}
		return Event{Seq: value.Seq, Type: value.Type, Event: value.Event, Body: value.Body}, nil
	default:
		return nil, fmt.Errorf("dap: unsupported message type %q", value.Type)
	}
}

func Read(reader *protocol.Reader) (Message, error) {
	data, err := reader.Read()
	if err != nil {
		return nil, err
	}
	return DecodeMessage(data)
}

func Write(writer *protocol.Writer, message Message) error {
	data, err := json.Marshal(message)
	if err != nil {
		return fmt.Errorf("dap: encode message: %w", err)
	}
	return writer.Write(data)
}

type Session struct {
	nextSequence atomic.Int64
}

func NewSession() *Session {
	session := &Session{}
	session.nextSequence.Store(1)
	return session
}

func (session *Session) NextSequence() int {
	return int(session.nextSequence.Add(1) - 1)
}

func (session *Session) Response(request Request, success bool, body any, message string) (Response, error) {
	encoded, err := json.Marshal(body)
	if err != nil {
		return Response{}, fmt.Errorf("dap: encode response body: %w", err)
	}
	return Response{
		Seq: session.NextSequence(), Type: "response", RequestSeq: request.Seq,
		Success: success, Command: request.Command, Message: message, Body: encoded,
	}, nil
}

func (session *Session) Event(name string, body any) (Event, error) {
	encoded, err := json.Marshal(body)
	if err != nil {
		return Event{}, fmt.Errorf("dap: encode event body: %w", err)
	}
	return Event{Seq: session.NextSequence(), Type: "event", Event: name, Body: encoded}, nil
}
