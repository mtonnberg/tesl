package protocol

import (
	"errors"
	"sort"
	"unicode/utf8"
)

type Position struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

type Range struct {
	Start Position `json:"start"`
	End   Position `json:"end"`
}

// LineIndex maps LSP UTF-16 positions to byte offsets in one document. It
// keeps source bytes untouched, including CRLF, while treating CRLF as one line
// ending for LSP coordinates.
type LineIndex struct {
	source      string
	lineStarts  []int
	lineLengths []int
}

func NewLineIndex(source string) *LineIndex {
	index := &LineIndex{source: source}
	start := 0
	for start <= len(source) {
		end := start
		for end < len(source) && source[end] != '\n' {
			end++
		}
		length := end - start
		if length > 0 && source[start+length-1] == '\r' {
			length--
		}
		index.lineStarts = append(index.lineStarts, start)
		index.lineLengths = append(index.lineLengths, length)
		if end == len(source) {
			break
		}
		start = end + 1
	}
	if len(index.lineStarts) == 0 {
		index.lineStarts = []int{0}
		index.lineLengths = []int{0}
	}
	return index
}

func (index *LineIndex) LineCount() int {
	return len(index.lineStarts)
}

// PositionFromLineColumn converts a compiler source position, whose column is
// a UTF-8 byte offset, to an LSP UTF-16 position.
func (index *LineIndex) PositionFromLineColumn(line, column int) (Position, error) {
	if line < 0 || line >= len(index.lineStarts) || column < 0 {
		return Position{}, errors.New("protocol: source position outside document")
	}
	start := index.lineStarts[line]
	text := index.source[start : start+index.lineLengths[line]]
	if column > len(text) {
		column = len(text)
	}
	return Position{Line: line, Character: ByteToUTF16Column(text, column)}, nil
}

func (index *LineIndex) Offset(position Position) (int, error) {
	if position.Line < 0 || position.Line >= len(index.lineStarts) || position.Character < 0 {
		return 0, errors.New("protocol: position outside document")
	}
	start := index.lineStarts[position.Line]
	line := index.source[start : start+index.lineLengths[position.Line]]
	return start + UTF16ToByteOffset(line, position.Character), nil
}

func (index *LineIndex) Position(offset int) (Position, error) {
	if offset < 0 || offset > len(index.source) {
		return Position{}, errors.New("protocol: offset outside document")
	}
	line := sort.Search(len(index.lineStarts), func(line int) bool {
		return index.lineStarts[line] > offset
	}) - 1
	if line < 0 {
		line = 0
	}
	start := index.lineStarts[line]
	end := start + index.lineLengths[line]
	if offset > end {
		offset = end
	}
	return Position{Line: line, Character: ByteToUTF16Column(index.source[start:offset], len(index.source[start:offset]))}, nil
}

// UTF16ToByteOffset clamps a UTF-16 column to a valid UTF-8 boundary. A column
// in the middle of a surrogate pair maps to the start of that code point.
func UTF16ToByteOffset(line string, column int) int {
	if column <= 0 {
		return 0
	}
	units := 0
	for offset := 0; offset < len(line); {
		runeValue, width := utf8.DecodeRuneInString(line[offset:])
		if runeValue == utf8.RuneError && width == 0 {
			break
		}
		runeUnits := 1
		if runeValue > 0xffff {
			runeUnits = 2
		}
		if units+runeUnits > column {
			return offset
		}
		units += runeUnits
		offset += width
	}
	return len(line)
}

func ByteToUTF16Column(line string, offset int) int {
	if offset <= 0 {
		return 0
	}
	if offset > len(line) {
		offset = len(line)
	}
	units := 0
	for position := 0; position < offset; {
		runeValue, width := utf8.DecodeRuneInString(line[position:])
		if position+width > offset {
			break
		}
		if runeValue > 0xffff {
			units += 2
		} else {
			units++
		}
		position += width
	}
	return units
}

func UTF16Length(value string) int {
	units := 0
	for offset := 0; offset < len(value); {
		runeValue, width := utf8.DecodeRuneInString(value[offset:])
		if runeValue > 0xffff {
			units += 2
		} else {
			units++
		}
		offset += width
	}
	return units
}
