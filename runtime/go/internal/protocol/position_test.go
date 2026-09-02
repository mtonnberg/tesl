package protocol

import (
	"strings"
	"testing"
)

func TestUTF16RoundTripWithAstralAndCombiningCharacters(t *testing.T) {
	line := "a😀é"
	for column := 0; column <= 5; column++ {
		offset := UTF16ToByteOffset(line, column)
		if got := ByteToUTF16Column(line, offset); got > column {
			t.Fatalf("column %d -> offset %d -> column %d", column, offset, got)
		}
	}
	if got := UTF16ToByteOffset(line, 3); got != len("a😀") {
		t.Fatalf("middle of surrogate pair mapped to byte %d", got)
	}
	if got := UTF16ToByteOffset(line, 99); got != len(line) {
		t.Fatalf("clamped column offset = %d", got)
	}
}

func TestLineIndexHandlesCRLFAndClampsColumns(t *testing.T) {
	index := NewLineIndex("one\r\n😀two\nlast")
	if index.LineCount() != 3 {
		t.Fatalf("LineCount() = %d", index.LineCount())
	}
	offset, err := index.Offset(Position{Line: 1, Character: 2})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := offset, len("one\r\n😀"); got != want {
		t.Fatalf("Offset() = %d, want %d", got, want)
	}
	position, err := index.Position(offset)
	if err != nil {
		t.Fatal(err)
	}
	if position != (Position{Line: 1, Character: 2}) {
		t.Fatalf("Position() = %#v", position)
	}
	if _, err := index.Offset(Position{Line: 8, Character: 0}); err == nil {
		t.Fatal("Offset() accepted invalid line")
	}
}

func FuzzUTF16PositionsNeverPanic(f *testing.F) {
	f.Add("a😀e\u0301\r\nlast")
	f.Add("")
	// The former worst case (2048 empty lines): must stay well under a second.
	f.Add(strings.Repeat("\n", 4096))
	f.Fuzz(func(t *testing.T, source string) {
		if len(source) > 4096 {
			t.Skip()
		}
		index := NewLineIndex(source)
		// Bound the work per input: every line is probed at every UTF-16 column it has plus
		// two past its end (the clamp), and the length is computed once per line — the
		// previous shape recomputed the whole document's length per column, which made an
		// all-newline 4 KiB input take tens of seconds and time the fuzz worker out.
		for line := 0; line < index.LineCount(); line++ {
			lineStart, err := index.Offset(Position{Line: line, Character: 0})
			if err != nil {
				t.Fatal(err)
			}
			lineEnd := len(source)
			if line+1 < index.LineCount() {
				if lineEnd, err = index.Offset(Position{Line: line + 1, Character: 0}); err != nil {
					t.Fatal(err)
				}
			}
			columns := UTF16Length(source[lineStart:lineEnd]) + 2
			for column := 0; column < columns; column++ {
				offset, err := index.Offset(Position{Line: line, Character: column})
				if err != nil {
					t.Fatal(err)
				}
				if offset < 0 || offset > len(source) {
					t.Fatalf("offset %d outside source length %d", offset, len(source))
				}
			}
		}
	})
}
