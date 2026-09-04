package protocol

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"sync"
	"testing"
)

type chunkReader struct {
	data  []byte
	chunk int
}

func (reader *chunkReader) Read(target []byte) (int, error) {
	if len(reader.data) == 0 {
		return 0, io.EOF
	}
	count := reader.chunk
	if count > len(reader.data) {
		count = len(reader.data)
	}
	copy(target, reader.data[:count])
	reader.data = reader.data[count:]
	return count, nil
}

func TestReaderHandlesFragmentedHeadersAndBodies(t *testing.T) {
	input := &chunkReader{data: []byte("Content-Length: 7\r\ncontent-type: application/json\r\n\r\n{\"x\":1}"), chunk: 1}
	message, err := NewReader(input).Read()
	if err != nil {
		t.Fatalf("Read() error = %v", err)
	}
	if string(message) != `{"x":1}` {
		t.Fatalf("Read() = %q", message)
	}
}

func TestReaderRejectsMalformedAndOversizedFrames(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  error
	}{
		{"missing length", "X-Test: yes\r\n\r\n{}", ErrMissingContentLength},
		{"duplicate length", "Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}", ErrDuplicateHeader},
		{"too large", "Content-Length: 3\r\n\r\n{}", ErrMessageTooLarge},
		{"invalid length", "Content-Length: nope\r\n\r\n{}", nil},
		{"negative length", "Content-Length: -1\r\n\r\n", nil},
		{"truncated header", "Content-Length: 2\r\n", io.ErrUnexpectedEOF},
		{"truncated body", "Content-Length: 4\r\n\r\n{}", io.ErrUnexpectedEOF},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reader := NewReader(bytes.NewBufferString(test.input))
			if test.name == "too large" {
				if err := reader.SetLimits(2, DefaultMaxHeaderBytes); err != nil {
					t.Fatal(err)
				}
			}
			_, err := reader.Read()
			if test.want == nil {
				if err == nil || !strings.Contains(err.Error(), "invalid Content-Length") {
					t.Fatalf("Read() error = %v, want invalid length", err)
				}
				return
			}
			if !errors.Is(err, test.want) {
				t.Fatalf("Read() error = %v, want %v", err, test.want)
			}
		})
	}
}

func TestWriterHandlesPartialWrites(t *testing.T) {
	var output bytes.Buffer
	if err := NewWriter(&partialWriter{output: &output, chunk: 2}).Write([]byte(`{"ok":true}`)); err != nil {
		t.Fatalf("Write() error = %v", err)
	}
	if got, want := output.String(), "Content-Length: 11\r\n\r\n{\"ok\":true}"; got != want {
		t.Fatalf("frame = %q, want %q", got, want)
	}
}

func TestWriterSerializesConcurrentFrames(t *testing.T) {
	var output bytes.Buffer
	writer := NewWriter(&output)
	var wait sync.WaitGroup
	for index := 0; index < 32; index++ {
		wait.Add(1)
		go func(index int) {
			defer wait.Done()
			if err := writer.WriteJSON(map[string]int{"index": index}); err != nil {
				t.Errorf("WriteJSON() error = %v", err)
			}
		}(index)
	}
	wait.Wait()
	reader := NewReader(&output)
	for index := 0; index < 32; index++ {
		if _, err := reader.Read(); err != nil {
			t.Fatalf("frame %d: %v", index, err)
		}
	}
}

func TestLineTransportUsesBoundedNewlineDelimitedJSON(t *testing.T) {
	var output bytes.Buffer
	writer := NewLineWriter(&partialWriter{output: &output, chunk: 2})
	if err := writer.WriteJSON(map[string]bool{"ok": true}); err != nil {
		t.Fatal(err)
	}
	if got, want := output.String(), "{\"ok\":true}\n"; got != want {
		t.Fatalf("line frame = %q, want %q", got, want)
	}
	message, err := NewLineReader(&output).Read()
	if err != nil || string(message) != `{"ok":true}` {
		t.Fatalf("Read() = %q, %v", message, err)
	}

	oversized := NewLineReader(strings.NewReader("1234\nnext\n"))
	if err := oversized.SetMaxMessageBytes(3); err != nil {
		t.Fatal(err)
	}
	if _, err := oversized.Read(); !errors.Is(err, ErrMessageTooLarge) {
		t.Fatalf("oversized Read() error = %v", err)
	}
}

func TestLineReaderRequiresTerminatingNewline(t *testing.T) {
	if _, err := NewLineReader(strings.NewReader(`{"id":1}`)).Read(); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("Read() error = %v, want unexpected EOF", err)
	}
}

func FuzzReaderAcceptsWriterFrames(f *testing.F) {
	f.Add([]byte(`{"jsonrpc":"2.0","method":"x"}`))
	f.Add([]byte{})
	f.Fuzz(func(t *testing.T, payload []byte) {
		if len(payload) > 1<<20 {
			t.Skip()
		}
		var output bytes.Buffer
		if err := NewWriter(&output).Write(payload); err != nil {
			t.Fatal(err)
		}
		got, err := NewReader(&output).Read()
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, payload) {
			t.Fatalf("round trip changed payload")
		}
	})
}

type partialWriter struct {
	output *bytes.Buffer
	chunk  int
}

func (writer *partialWriter) Write(data []byte) (int, error) {
	count := writer.chunk
	if count > len(data) {
		count = len(data)
	}
	_, _ = writer.output.Write(data[:count])
	return count, nil
}
