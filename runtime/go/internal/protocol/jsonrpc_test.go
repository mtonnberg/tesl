package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestJSONRPCRequestAndResponseValidation(t *testing.T) {
	request, err := DecodeRequest([]byte(`{"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{}}`))
	if err != nil || request.Method != "textDocument/hover" {
		t.Fatalf("DecodeRequest() = %#v, %v", request, err)
	}
	response, err := NewResultResponse(request.ID, map[string]string{"ok": "yes"})
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeResponse(encoded); err != nil {
		t.Fatalf("DecodeResponse() error = %v", err)
	}
	if _, err := DecodeRequest([]byte(`{"jsonrpc":"2.0","method":"x","params":1}`)); err == nil {
		t.Fatal("DecodeRequest() accepted scalar params")
	}
	if _, err := DecodeRequest([]byte(`{"jsonrpc":"2.0","method":"x"} trailing`)); err == nil {
		t.Fatal("DecodeRequest() accepted trailing JSON")
	}
}

func TestJSONRPCErrorResponseIncludesData(t *testing.T) {
	response, err := NewErrorResponse(json.RawMessage(`"id"`), -32600, "bad request", map[string]bool{"retry": false})
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(response)
	if !strings.Contains(string(encoded), `"retry":false`) {
		t.Fatalf("error response = %s", encoded)
	}
	if _, err := DecodeResponse(encoded); err != nil {
		t.Fatalf("DecodeResponse() error = %v", err)
	}
}
