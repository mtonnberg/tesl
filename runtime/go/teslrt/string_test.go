package teslrt

import "testing"

// Tesl lengths and indices are CODE POINTS, because the Racket backend counts
// Racket chars. A byte-based implementation passes every ASCII test and is wrong the
// moment a program touches a non-ASCII string, so the unicode rows are the point of
// this file rather than an afterthought.
func TestStringLengthCountsCodePoints(t *testing.T) {
	for _, row := range []struct {
		in   string
		want int64
	}{
		{"", 0},
		{"abc", 3},
		{"雪", 1},
		{"雪だるま", 4},
		{"café", 4},
		{"é", 2}, // combining accent: two code points, one grapheme
		{"😀", 1},  // outside the BMP: 4 bytes, one code point
		{"a😀b", 3},
	} {
		got := StringLength(row.in)
		if !Equal(got, FromInt64(row.want)) {
			t.Errorf("StringLength(%q) = %s, want %d", row.in, got.String(), row.want)
		}
	}
}

func TestStringIndexOfIsACodePointIndex(t *testing.T) {
	for _, row := range []struct {
		s, sub  string
		want    int64
		present bool
	}{
		{"abc", "a", 0, true},
		{"abc", "c", 2, true},
		{"abc", "d", 0, false},
		{"abc", "", 0, true},
		{"雪だるま", "だ", 1, true}, // byte offset would be 3
		{"a😀b", "b", 2, true},  // byte offset would be 5
		{"😀😀", "😀", 0, true},
	} {
		got := StringIndexOf(row.s, row.sub)
		value, ok := got.Value()
		if ok != row.present {
			t.Errorf("StringIndexOf(%q, %q) present = %v, want %v", row.s, row.sub, ok, row.present)
			continue
		}
		if ok && !Equal(value, FromInt64(row.want)) {
			t.Errorf("StringIndexOf(%q, %q) = %s, want %d", row.s, row.sub, value.String(), row.want)
		}
	}
}

func TestStringSliceClampsAndCountsCodePoints(t *testing.T) {
	for _, row := range []struct {
		s          string
		start, end int64
		want       string
	}{
		{"abcdef", 1, 3, "bc"},
		{"abcdef", 0, 0, ""},
		{"abcdef", 4, 99, "ef"}, // end clamps to the length
		{"abcdef", -5, 2, "ab"}, // start clamps to zero
		{"abcdef", 4, 2, ""},    // inverted bounds collapse instead of panicking
		{"abcdef", 99, 99, ""},
		{"雪だるま", 1, 3, "だる"}, // code points, not bytes
		{"a😀b", 1, 2, "😀"},
	} {
		got := StringSlice(row.s, FromInt64(row.start), FromInt64(row.end))
		if got != row.want {
			t.Errorf("StringSlice(%q, %d, %d) = %q, want %q", row.s, row.start, row.end, got, row.want)
		}
	}
}

// An index beyond int64 must clamp by SIGN. Truncating the low 64 bits would turn a
// huge positive index into an arbitrary in-range one.
func TestStringSliceClampsHugeIndicesBySign(t *testing.T) {
	huge := MustParseDecimal("99999999999999999999999999")
	negative := Neg(huge)
	if got := StringSlice("abc", FromInt64(0), huge); got != "abc" {
		t.Errorf("slice to huge end = %q, want %q", got, "abc")
	}
	if got := StringSlice("abc", huge, huge); got != "" {
		t.Errorf("slice from huge start = %q, want empty", got)
	}
	if got := StringSlice("abc", negative, FromInt64(2)); got != "ab" {
		t.Errorf("slice from huge negative start = %q, want %q", got, "ab")
	}
}

func TestStringToIntAcceptsOnlyDecimalIntegers(t *testing.T) {
	for _, row := range []struct {
		in      string
		want    string
		present bool
	}{
		{"42", "42", true},
		{"-7", "-7", true},
		{"+5", "5", true},
		{"0", "0", true},
		{"170141183460469231731687303715884105728", "170141183460469231731687303715884105728", true},
		{"", "", false},
		{" 5", "", false},
		{"5 ", "", false},
		{"5.0", "", false},
		{"1e3", "", false},
		{"abc", "", false},
		// Racket's string->number would accept these; Tesl's surface does not.
		{"#x1A", "", false},
		{"1/1", "", false},
	} {
		got := StringToInt(row.in)
		value, ok := got.Value()
		if ok != row.present {
			t.Errorf("StringToInt(%q) present = %v, want %v", row.in, ok, row.present)
			continue
		}
		if ok && value.String() != row.want {
			t.Errorf("StringToInt(%q) = %s, want %s", row.in, value.String(), row.want)
		}
	}
}

func TestStringPadUsesCodePointWidths(t *testing.T) {
	if got := StringPadLeft("7", FromInt64(3), "0"); got != "007" {
		t.Errorf("PadLeft = %q, want 007", got)
	}
	if got := StringPadRight("7", FromInt64(3), "0"); got != "700" {
		t.Errorf("PadRight = %q, want 700", got)
	}
	// Already at or over the width: unchanged, never truncated.
	if got := StringPadLeft("1234", FromInt64(2), "0"); got != "1234" {
		t.Errorf("PadLeft over width = %q, want 1234", got)
	}
	// Width counts code points, and the pad is one rune even when multi-byte.
	if got := StringPadLeft("雪", FromInt64(3), "だ"); got != "だだ雪" {
		t.Errorf("PadLeft unicode = %q, want だだ雪", got)
	}
	// An empty pad cannot fill anything; the input must come back untouched.
	if got := StringPadLeft("7", FromInt64(5), ""); got != "7" {
		t.Errorf("PadLeft empty pad = %q, want 7", got)
	}
	// A width beyond int64 must not attempt an allocation.
	if got := StringPadLeft("7", MustParseDecimal("99999999999999999999"), "0"); got != "7" {
		t.Errorf("PadLeft huge width = %q, want 7", got)
	}
}

func TestStringRepeatIsTotal(t *testing.T) {
	if got := StringRepeat("ab", FromInt64(3)); got != "ababab" {
		t.Errorf("Repeat = %q", got)
	}
	for _, times := range []Int{FromInt64(0), FromInt64(-1), MustParseDecimal("99999999999999999999")} {
		if got := StringRepeat("ab", times); got != "" {
			t.Errorf("Repeat(%s) = %q, want empty", times.String(), got)
		}
	}
}

func TestStringReverseReversesCodePoints(t *testing.T) {
	for _, row := range []struct{ in, want string }{
		{"", ""},
		{"abc", "cba"},
		{"雪だるま", "まるだ雪"},
		{"a😀b", "b😀a"},
	} {
		if got := StringReverse(row.in); got != row.want {
			t.Errorf("StringReverse(%q) = %q, want %q", row.in, got, row.want)
		}
	}
}

func TestStringPrefixSuffixAndDrops(t *testing.T) {
	if !StringStartsWith("abc", "ab") || StringStartsWith("abc", "b") {
		t.Error("StartsWith")
	}
	if !StringEndsWith("abc", "bc") || StringEndsWith("abc", "b") {
		t.Error("EndsWith")
	}
	if got := StringDropPrefix("abc", "ab"); got != "c" {
		t.Errorf("DropPrefix = %q", got)
	}
	// A prefix that does not match leaves the string alone.
	if got := StringDropPrefix("abc", "zz"); got != "abc" {
		t.Errorf("DropPrefix miss = %q", got)
	}
	if got := StringDropSuffix("abc", "bc"); got != "a" {
		t.Errorf("DropSuffix = %q", got)
	}
	if got := StringDropSuffix("abc", "zz"); got != "abc" {
		t.Errorf("DropSuffix miss = %q", got)
	}
}

func TestStringTrimAndCase(t *testing.T) {
	if got := StringTrim("  a b \n\t"); got != "a b" {
		t.Errorf("Trim = %q", got)
	}
	if got := StringTrim(""); got != "" {
		t.Errorf("Trim empty = %q", got)
	}
	if got := StringToUpper("aBc"); got != "ABC" {
		t.Errorf("ToUpper = %q", got)
	}
	if got := StringToLower("AbC"); got != "abc" {
		t.Errorf("ToLower = %q", got)
	}
	// Documented divergence: Go's per-rune simple case mapping leaves ß alone,
	// where Racket's full mapping produces SS.
	if got := StringToUpper("ß"); got != "ß" {
		t.Errorf("ToUpper(ß) = %q, want ß (simple mapping)", got)
	}
}

// The check's rejection is observable behavior — status and message both.
func TestStringRequireNonEmpty(t *testing.T) {
	ok := StringRequireNonEmpty("a")
	value, present := ok.Value()
	if !present || value != "a" {
		t.Fatalf("accepted = %q, %v", value, present)
	}
	rejected := StringRequireNonEmpty("")
	if rejected.OK() {
		t.Fatal("empty string accepted")
	}
	if rejected.Status() != 400 {
		t.Errorf("status = %d, want 400", rejected.Status())
	}
	if rejected.Message() != "expected a non-empty string" {
		t.Errorf("message = %q", rejected.Message())
	}
}
