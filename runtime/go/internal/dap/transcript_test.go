package dap

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/teslrt"
)

type dapTranscript struct {
	Requests  []json.RawMessage `json:"requests"`
	Responses []struct {
		RequestSeq int    `json:"requestSeq"`
		Command    string `json:"command"`
		Success    bool   `json:"success"`
	} `json:"responses"`
}

func TestCoreDAPTranscript(t *testing.T) {
	_, testFile, _, _ := runtime.Caller(0)
	fixturePath := filepath.Clean(filepath.Join(filepath.Dir(testFile), "../../../../tests/protocol/dap-core.json"))
	fixture, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatal(err)
	}
	var transcript dapTranscript
	if err := json.Unmarshal(fixture, &transcript); err != nil {
		t.Fatal(err)
	}
	if len(transcript.Requests) != len(transcript.Responses) {
		t.Fatalf("fixture requests/responses = %d/%d", len(transcript.Requests), len(transcript.Responses))
	}

	var input bytes.Buffer
	writer := protocol.NewWriter(&input)
	for _, raw := range transcript.Requests {
		var request Request
		if err := json.Unmarshal(raw, &request); err != nil {
			t.Fatal(err)
		}
		if err := Write(writer, request); err != nil {
			t.Fatal(err)
		}
	}
	var output bytes.Buffer
	if err := NewServer(&input, &output, teslrt.NewDebugger()).Serve(); err != nil {
		t.Fatal(err)
	}
	reader := protocol.NewReader(&output)
	responseIndex := 0
	for responseIndex < len(transcript.Responses) {
		message, err := Read(reader)
		if err != nil {
			t.Fatalf("response %d: %v", responseIndex, err)
		}
		if _, ok := message.(Event); ok {
			continue
		}
		response, ok := message.(Response)
		if !ok {
			t.Fatalf("response %d = %#v, want DAP response", responseIndex, message)
		}
		expected := transcript.Responses[responseIndex]
		if response.RequestSeq != expected.RequestSeq || response.Command != expected.Command || response.Success != expected.Success {
			t.Fatalf("response %d = request %d/%s/%t, want %d/%s/%t", responseIndex,
				response.RequestSeq, response.Command, response.Success,
				expected.RequestSeq, expected.Command, expected.Success)
		}
		responseIndex++
	}
}
