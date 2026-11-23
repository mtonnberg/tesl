package teslrt

import (
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Tesl's String is Go's string, but Tesl's string INDICES AND LENGTHS ARE CODE
// POINTS, because the Racket backend's `string-length`, `substring`, and match
// positions all count Racket chars. Every function here that exposes a length or an
// index therefore converts, and none of them may use len() or a byte offset as a
// Tesl-visible number.
//
// Two deliberate, documented differences from the Racket backend, both cases where
// Go's behavior is the defensible one (see roadmap/next/migrate_to_golang.md):
//
//   - StringToInt accepts an optional sign followed by decimal digits, and nothing
//     else. Racket's `string->number` also accepts reader syntax — "#x1A" is 26,
//     "1/1" is the exact integer 1 — which is an implementation leak rather than a
//     language surface.
//   - StringTrim trims Unicode whitespace (Go's unicode.IsSpace), where Racket's
//     default `\s` is ASCII-only. Case mapping is Go's per-rune simple mapping, so
//     "ß" uppercases to "ß" rather than Racket's full-mapping "SS".
func StringLength(s string) Int {
	return FromInt64(int64(utf8.RuneCountInString(s)))
}

func StringIsEmpty(s string) bool {
	return s == ""
}

func StringStartsWith(s, prefix string) bool {
	return strings.HasPrefix(s, prefix)
}

func StringEndsWith(s, suffix string) bool {
	return strings.HasSuffix(s, suffix)
}

func StringContains(s, sub string) bool {
	return strings.Contains(s, sub)
}

func StringConcat(left, right string) string {
	return left + right
}

// StringReplace replaces every occurrence, matching Racket's string-replace.
func StringReplace(s, from, to string) string {
	return strings.ReplaceAll(s, from, to)
}

// StringSlice is a zero-based, code-point-indexed slice with both bounds clamped,
// so it is total: no index can panic and no bound can be inverted.
func StringSlice(s string, start, end Int) string {
	runes := []rune(s)
	length := int64(len(runes))
	lo := clampIndex(start, length)
	hi := clampIndex(end, length)
	if hi < lo {
		hi = lo
	}
	return string(runes[lo:hi])
}

// clampIndex pins an arbitrary-precision index into [0, length]. An Int outside
// int64 range clamps by sign rather than truncating, which a naive conversion
// would get exactly backwards.
func clampIndex(index Int, length int64) int64 {
	value, ok := index.Int64()
	if !ok {
		if index.Sign() < 0 {
			return 0
		}
		return length
	}
	if value < 0 {
		return 0
	}
	if value > length {
		return length
	}
	return value
}

func StringToUpper(s string) string {
	return strings.ToUpper(s)
}

func StringToLower(s string) string {
	return strings.ToLower(s)
}

func StringTrim(s string) string {
	return strings.TrimSpace(s)
}

func StringFromInt(value Int) string {
	return value.String()
}

// StringToInt parses an optional sign followed by decimal digits; anything else is
// Nothing. Arbitrary precision is preserved.
func StringToInt(s string) Maybe[Int] {
	value, err := ParseDecimal(s)
	if err != nil {
		return Nothing[Int]()
	}
	return Something(value)
}

// StringIndexOf reports the first occurrence as a CODE POINT index, not a byte
// offset — the two differ for any string with a multi-byte rune before the match.
func StringIndexOf(s, sub string) Maybe[Int] {
	offset := strings.Index(s, sub)
	if offset < 0 {
		return Nothing[Int]()
	}
	return Something(FromInt64(int64(utf8.RuneCountInString(s[:offset]))))
}

func StringDropPrefix(s, prefix string) string {
	return strings.TrimPrefix(s, prefix)
}

func StringDropSuffix(s, suffix string) string {
	return strings.TrimSuffix(s, suffix)
}

// StringPadLeft pads to a code-point width using the first rune of pad. A string
// already at or over the width is returned unchanged, never truncated.
func StringPadLeft(s string, width Int, pad string) string {
	fill, count := padding(s, width, pad)
	if count <= 0 {
		return s
	}
	return strings.Repeat(fill, count) + s
}

func StringPadRight(s string, width Int, pad string) string {
	fill, count := padding(s, width, pad)
	if count <= 0 {
		return s
	}
	return s + strings.Repeat(fill, count)
}

func padding(s string, width Int, pad string) (string, int) {
	fill, size := utf8.DecodeRuneInString(pad)
	if size == 0 {
		return "", 0
	}
	target, ok := width.Int64()
	if !ok {
		// A width beyond int64 cannot be materialised; treat it as no padding
		// rather than attempting an allocation that would kill the process.
		return string(fill), 0
	}
	current := int64(utf8.RuneCountInString(s))
	if target <= current {
		return string(fill), 0
	}
	return string(fill), int(target - current)
}

// maxRepeatBytes bounds the byte length of a String.repeat result. A denial-of-service
// bound, not a language limit: strings.Repeat only panics on int OVERFLOW, so a
// request-controlled count of, say, 2^40 would otherwise attempt a terabyte allocation and
// end the process with an uncatchable out-of-memory fatal rather than a recoverable trap.
const maxRepeatBytes = 64 << 20

// StringRepeat is total over the counts a program can mean: negative or beyond-int64 counts
// yield the empty string (mirroring `padding` above). A count whose result would exceed
// maxRepeatBytes is different — it is not a value the program could have wanted, and answering
// "" would be a silent wrong result — so it TRAPS, which `callHandler` turns into a sanitized
// 500 rather than the uncatchable out-of-memory the allocation would have been. The bound is
// decided from len(s) and the count BEFORE strings.Repeat runs; the division form cannot
// overflow.
func StringRepeat(s string, times Int) string {
	count, ok := times.Int64()
	if !ok || count <= 0 || s == "" {
		return ""
	}
	if count > int64(maxRepeatBytes)/int64(len(s)) {
		panic(fmt.Sprintf("String.repeat: the result would be %d × %d bytes, over the %d-byte bound",
			count, len(s), maxRepeatBytes))
	}
	return strings.Repeat(s, int(count))
}

// StringReverse reverses by code point, matching Racket's string->list round trip.
func StringReverse(s string) string {
	runes := []rune(s)
	for left, right := 0, len(runes)-1; left < right; left, right = left+1, right-1 {
		runes[left], runes[right] = runes[right], runes[left]
	}
	return string(runes)
}

// StringRequireNonEmpty is Tesl's `String.requireNonEmpty` check: the proof erases,
// the rejection does not.
func StringRequireNonEmpty(s string) Check[string] {
	if s == "" {
		return Reject[string](400, "expected a non-empty string")
	}
	return Accept(s)
}

// StringTrimLeft / StringTrimRight remove leading / trailing whitespace — the same whitespace
// `String.trim` removes from both ends.
func StringTrimLeft(s string) string  { return strings.TrimLeftFunc(s, unicode.IsSpace) }
func StringTrimRight(s string) string { return strings.TrimRightFunc(s, unicode.IsSpace) }

// StringWords splits on runs of whitespace and drops empty pieces.
func StringWords(s string) []string { return strings.Fields(s) }

// StringLines splits on newlines; a `\r\n` line ending counts as one newline, and a trailing
// newline does not produce an empty last line.
func StringLines(s string) []string {
	lines := []string{}
	if s == "" {
		return lines
	}
	for line := range strings.SplitSeq(strings.TrimSuffix(strings.ReplaceAll(s, "\r\n", "\n"), "\n"), "\n") {
		lines = append(lines, line)
	}
	return lines
}

// Reversible encodings. `IsBase64Url s` / `IsHex s` state that s is the CANONICAL
// encoding of the UTF-8 bytes of a string: base64url (RFC 4648 section 5 alphabet) with
// no padding, or lowercase hex. "Canonical" means exactly the text the encoder below
// produces, so each decoded string has exactly one proven encoding and two proven values
// are equal exactly when their decoded strings are.
//
// A Tesl String is Unicode text. A Go string can still carry invalid UTF-8 bytes (for
// example from an unvalidated HTTP source), so the encoders first replace each invalid
// run with U+FFFD: the result therefore always decodes to valid UTF-8, which is what
// the fact promises and what lets the decoders be total.

// StringToBase64Url is Tesl's `String.toBase64Url`.
func StringToBase64Url(s string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(strings.ToValidUTF8(s, "\uFFFD")))
}

// StringParseBase64Url is Tesl's `String.parseBase64Url`: Something exactly when raw is
// the canonical encoding of valid UTF-8. Comparing against a re-encoding rejects every
// non-canonical spelling at once — `=` padding, the standard `+`/`/` alphabet, embedded
// newlines (which Go's decoder would otherwise skip), and non-zero trailing bits.
func StringParseBase64Url(raw string) Maybe[string] {
	decoded, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil || !utf8.Valid(decoded) || base64.RawURLEncoding.EncodeToString(decoded) != raw {
		return Nothing[string]()
	}
	return Something(raw)
}

// StringFromBase64Url is Tesl's `String.fromBase64Url`. Its argument carries
// IsBase64Url, which only the two functions above mint, so the failure branch is
// unreachable for checked code; it panics like other proof-total stdlib functions.
func StringFromBase64Url(s string) string {
	decoded, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil || !utf8.Valid(decoded) {
		panic("String.fromBase64Url: argument is not canonical base64url of UTF-8 text — " +
			"obtain it from String.toBase64Url or String.parseBase64Url")
	}
	return string(decoded)
}

// StringToHex is Tesl's `String.toHex`: lowercase hex of the UTF-8 bytes.
func StringToHex(s string) string {
	return hex.EncodeToString([]byte(strings.ToValidUTF8(s, "\uFFFD")))
}

// StringParseHex is Tesl's `String.parseHex`: Something exactly when raw is lowercase
// hex of valid UTF-8. Uppercase digits are rejected so the proven form stays canonical.
func StringParseHex(raw string) Maybe[string] {
	decoded, err := hex.DecodeString(raw)
	if err != nil || !utf8.Valid(decoded) || hex.EncodeToString(decoded) != raw {
		return Nothing[string]()
	}
	return Something(raw)
}

// StringFromHex is Tesl's `String.fromHex`; see StringFromBase64Url for the panic.
func StringFromHex(s string) string {
	decoded, err := hex.DecodeString(s)
	if err != nil || !utf8.Valid(decoded) {
		panic("String.fromHex: argument is not canonical hex of UTF-8 text — " +
			"obtain it from String.toHex or String.parseHex")
	}
	return string(decoded)
}
