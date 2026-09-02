// Package protocol contains the wire-level pieces shared by Tesl editor tools.
package protocol

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync"
)

const (
	// DefaultMaxMessageBytes prevents a malformed local client from making an
	// editor process allocate without bound.
	DefaultMaxMessageBytes = 8 << 20
	DefaultMaxHeaderBytes  = 16 << 10
)

var (
	ErrMissingContentLength = errors.New("protocol: missing Content-Length")
	ErrDuplicateHeader      = errors.New("protocol: duplicate header")
	ErrMessageTooLarge      = errors.New("protocol: message exceeds configured limit")
)

// Reader decodes Language Server Protocol / DAP style Content-Length frames.
// It deliberately accepts arbitrary fragmentation at the underlying reader.
type Reader struct {
	reader     *bufio.Reader
	maxMessage int
	maxHeader  int
}

func NewReader(reader io.Reader) *Reader {
	return &Reader{
		reader:     bufio.NewReader(reader),
		maxMessage: DefaultMaxMessageBytes,
		maxHeader:  DefaultMaxHeaderBytes,
	}
}

func (reader *Reader) SetLimits(maxMessageBytes, maxHeaderBytes int) error {
	if maxMessageBytes <= 0 || maxHeaderBytes <= 0 {
		return errors.New("protocol: limits must be positive")
	}
	reader.maxMessage = maxMessageBytes
	reader.maxHeader = maxHeaderBytes
	return nil
}

// Read returns one frame's JSON bytes. EOF before a complete frame is an
// io.ErrUnexpectedEOF so callers can distinguish clean shutdown from truncation.
func (reader *Reader) Read() ([]byte, error) {
	contentLength := -1
	for {
		line, err := reader.readHeaderLine()
		if err != nil {
			if errors.Is(err, io.EOF) {
				if contentLength < 0 {
					return nil, io.EOF
				}
				return nil, io.ErrUnexpectedEOF
			}
			return nil, err
		}
		if len(line) == 0 {
			break
		}
		separator := bytes.IndexByte(line, ':')
		if separator < 0 {
			return nil, fmt.Errorf("protocol: malformed header %q", line)
		}
		name := strings.ToLower(string(bytes.TrimSpace(line[:separator])))
		value := string(bytes.TrimSpace(line[separator+1:]))
		switch name {
		case "content-length":
			if contentLength >= 0 {
				return nil, ErrDuplicateHeader
			}
			length, parseErr := strconv.Atoi(value)
			if parseErr != nil || length < 0 {
				return nil, fmt.Errorf("protocol: invalid Content-Length %q", value)
			}
			if length > reader.maxMessage {
				return nil, ErrMessageTooLarge
			}
			contentLength = length
		}
	}

	if contentLength < 0 {
		return nil, ErrMissingContentLength
	}
	message := make([]byte, contentLength)
	if _, err := io.ReadFull(reader.reader, message); err != nil {
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			return nil, io.ErrUnexpectedEOF
		}
		return nil, err
	}
	return message, nil
}

func (reader *Reader) readHeaderLine() ([]byte, error) {
	var line []byte
	for {
		part, err := reader.reader.ReadSlice('\n')
		line = append(line, part...)
		if len(line) > reader.maxHeader {
			return nil, ErrMessageTooLarge
		}
		if err == nil {
			line = bytes.TrimSuffix(line, []byte{'\n'})
			line = bytes.TrimSuffix(line, []byte{'\r'})
			return line, nil
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if errors.Is(err, io.EOF) {
			if len(line) == 0 {
				return nil, io.EOF
			}
			return nil, io.ErrUnexpectedEOF
		}
		return nil, err
	}
}

// Writer encodes one complete frame per Write call. The mutex prevents two
// goroutines from interleaving headers and bodies on a shared stdio stream.
type Writer struct {
	writer     io.Writer
	maxMessage int
	mutex      sync.Mutex
}

func NewWriter(writer io.Writer) *Writer {
	return &Writer{writer: writer, maxMessage: DefaultMaxMessageBytes}
}

func (writer *Writer) SetMaxMessageBytes(maxMessageBytes int) error {
	if maxMessageBytes <= 0 {
		return errors.New("protocol: max message size must be positive")
	}
	writer.maxMessage = maxMessageBytes
	return nil
}

func (writer *Writer) Write(message []byte) error {
	if len(message) > writer.maxMessage {
		return ErrMessageTooLarge
	}
	frame := make([]byte, 0, len(message)+32)
	frame = append(frame, "Content-Length: "...)
	frame = strconv.AppendInt(frame, int64(len(message)), 10)
	frame = append(frame, '\r', '\n', '\r', '\n')
	frame = append(frame, message...)

	writer.mutex.Lock()
	defer writer.mutex.Unlock()
	return writeAll(writer.writer, frame)
}

func (writer *Writer) WriteJSON(value any) error {
	message, err := json.Marshal(value)
	if err != nil {
		return fmt.Errorf("protocol: encode JSON: %w", err)
	}
	return writer.Write(message)
}

func writeAll(writer io.Writer, data []byte) error {
	for len(data) > 0 {
		written, err := writer.Write(data)
		if written > 0 {
			data = data[written:]
		}
		if err != nil {
			return err
		}
		if written == 0 {
			return io.ErrShortWrite
		}
	}
	return nil
}
