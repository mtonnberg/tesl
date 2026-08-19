package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// Request is the common JSON-RPC 2.0 envelope used by LSP and MCP. A nil ID
// means notification; an explicit JSON null remains distinguishable in ID.
type Request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type Response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *Error          `json:"error,omitempty"`
}

type Error struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

func DecodeRequest(message []byte) (Request, error) {
	var request Request
	if err := decodeOne(message, &request); err != nil {
		return Request{}, fmt.Errorf("protocol: decode request: %w", err)
	}
	if request.JSONRPC != "2.0" {
		return Request{}, errors.New("protocol: request jsonrpc must be \"2.0\"")
	}
	if request.Method == "" {
		return Request{}, errors.New("protocol: request method is empty")
	}
	if len(request.Params) > 0 && !isObjectOrArrayOrNull(request.Params) {
		return Request{}, errors.New("protocol: request params must be an object or array")
	}
	return request, nil
}

func DecodeResponse(message []byte) (Response, error) {
	var response Response
	if err := decodeOne(message, &response); err != nil {
		return Response{}, fmt.Errorf("protocol: decode response: %w", err)
	}
	if response.JSONRPC != "2.0" {
		return Response{}, errors.New("protocol: response jsonrpc must be \"2.0\"")
	}
	if response.Error == nil && len(response.Result) == 0 {
		return Response{}, errors.New("protocol: response has neither result nor error")
	}
	if response.Error != nil && len(response.Result) > 0 {
		return Response{}, errors.New("protocol: response has both result and error")
	}
	return response, nil
}

func NewResultResponse(id json.RawMessage, result any) (Response, error) {
	encoded, err := json.Marshal(result)
	if err != nil {
		return Response{}, fmt.Errorf("protocol: encode result: %w", err)
	}
	return Response{JSONRPC: "2.0", ID: append(json.RawMessage(nil), id...), Result: encoded}, nil
}

func NewErrorResponse(id json.RawMessage, code int, message string, data any) (Response, error) {
	var encoded json.RawMessage
	if data != nil {
		var err error
		encoded, err = json.Marshal(data)
		if err != nil {
			return Response{}, fmt.Errorf("protocol: encode error data: %w", err)
		}
	}
	return Response{
		JSONRPC: "2.0",
		ID:      append(json.RawMessage(nil), id...),
		Error:   &Error{Code: code, Message: message, Data: encoded},
	}, nil
}

func decodeOne(message []byte, destination any) error {
	decoder := json.NewDecoder(bytes.NewReader(message))
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return errors.New("trailing JSON value")
		}
		return fmt.Errorf("trailing JSON: %w", err)
	}
	return nil
}

func isObjectOrArray(value []byte) bool {
	trimmed := bytes.TrimSpace(value)
	return len(trimmed) > 0 && (trimmed[0] == '{' || trimmed[0] == '[')
}

func isObjectOrArrayOrNull(value []byte) bool {
	trimmed := bytes.TrimSpace(value)
	return isObjectOrArray(trimmed) || bytes.Equal(trimmed, []byte("null"))
}
