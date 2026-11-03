package tooling

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Action metadata must have one unambiguous interpretation before it reaches an
// editor. In particular, repeated actionClass/needsConfirmation fields cannot
// be interpreted differently by a validator and its subsequent consumer.
func validateDiagnosticWire(payload []byte) error {
	if !utf8.Valid(payload) {
		return errors.New("diagnostic JSON must be UTF-8")
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	var walk func(int) error
	walk = func(depth int) error {
		if depth > 64 {
			return errors.New("diagnostic JSON exceeds nesting limit")
		}
		token, err := decoder.Token()
		if err != nil {
			return err
		}
		switch token {
		case json.Delim('{'):
			seen := map[string]bool{}
			for decoder.More() {
				key, err := decoder.Token()
				if err != nil {
					return err
				}
				name, ok := key.(string)
				// encoding/json matches struct fields using Unicode simple
				// folding. Exact-key validation must not admit a second spelling
				// which the consumer would decode into the same field.
				folded := strings.Map(func(r rune) rune {
					minimum := r
					for next := unicode.SimpleFold(r); next != r; next = unicode.SimpleFold(next) {
						if next < minimum {
							minimum = next
						}
					}
					return minimum
				}, name)
				if !ok || seen[folded] {
					return errors.New("diagnostic JSON has a duplicate or invalid object key")
				}
				seen[folded] = true
				if err := walk(depth + 1); err != nil {
					return err
				}
			}
		case json.Delim('['):
			for decoder.More() {
				if err := walk(depth + 1); err != nil {
					return err
				}
			}
		default:
			return nil
		}
		_, err = decoder.Token()
		return err
	}
	if err := walk(0); err != nil {
		return err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return errors.New("diagnostic JSON contains trailing data")
	}
	return nil
}
