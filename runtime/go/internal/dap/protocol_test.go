package dap

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"tesl.dev/runtime/go/internal/protocol"
)

func TestDecodeMessageVariants(t *testing.T) {
	message, err := DecodeMessage([]byte(`{"seq":7,"type":"request","command":"initialize","arguments":{"adapterID":"tesl"}}`))
	if err != nil {
		t.Fatal(err)
	}
	request, ok := message.(Request)
	if !ok || request.Seq != 7 || request.Command != "initialize" {
		t.Fatalf("message = %#v", message)
	}
	var arguments map[string]string
	if err := json.Unmarshal(request.Arguments, &arguments); err != nil || arguments["adapterID"] != "tesl" {
		t.Fatalf("arguments = %#v, error = %v", arguments, err)
	}

	message, err = DecodeMessage([]byte(`{"seq":8,"type":"response","request_seq":7,"success":true,"command":"initialize"}`))
	if err != nil {
		t.Fatal(err)
	}
	if response, ok := message.(Response); !ok || response.RequestSeq != 7 || !response.Success {
		t.Fatalf("response = %#v", message)
	}

	message, err = DecodeMessage([]byte(`{"seq":9,"type":"event","event":"initialized"}`))
	if err != nil {
		t.Fatal(err)
	}
	if event, ok := message.(Event); !ok || event.Event != "initialized" {
		t.Fatalf("event = %#v", message)
	}
}

func TestDecodeMessageRejectsInvalidShape(t *testing.T) {
	cases := []string{
		`{"seq":1,"type":"request"}`,
		`{"seq":1,"type":"event"}`,
		`{"seq":1,"type":"other"}`,
		`{"seq":1,"type":"event"} {"seq":2,"type":"event","event":"x"}`,
	}
	for _, input := range cases {
		if _, err := DecodeMessage([]byte(input)); err == nil {
			t.Errorf("DecodeMessage(%s) accepted invalid input", input)
		}
	}
}

func TestSessionSequencesAndFraming(t *testing.T) {
	session := NewSession()
	request := Request{Seq: 4, Type: "request", Command: "threads"}
	response, err := session.Response(request, true, map[string]bool{"ok": true}, "")
	if err != nil {
		t.Fatal(err)
	}
	event, err := session.Event("initialized", nil)
	if err != nil {
		t.Fatal(err)
	}
	if response.Seq != 1 || event.Seq != 2 {
		t.Fatalf("sequences = %d, %d", response.Seq, event.Seq)
	}

	var stream bytes.Buffer
	writer := protocol.NewWriter(&stream)
	if err := Write(writer, response); err != nil {
		t.Fatal(err)
	}
	if err := Write(writer, event); err != nil {
		t.Fatal(err)
	}
	reader := protocol.NewReader(strings.NewReader(stream.String()))
	first, err := Read(reader)
	if err != nil {
		t.Fatal(err)
	}
	second, err := Read(reader)
	if err != nil {
		t.Fatal(err)
	}
	if first.(Response).Command != "threads" || second.(Event).Event != "initialized" {
		t.Fatalf("messages = %#v, %#v", first, second)
	}
}
