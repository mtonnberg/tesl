package teslrt

import "testing"

func TestStringBase64UrlRoundTrips(t *testing.T) {
	for _, row := range []struct{ in, want string }{
		{"", ""},
		{"f", "Zg"},
		{"fo", "Zm8"},
		{"foo", "Zm9v"},
		{"page=2&after=42", "cGFnZT0yJmFmdGVyPTQy"},
		{"\xfb\xff", "77-9"}, // a run of invalid UTF-8 is encoded as one U+FFFD
		{"雪だるま😀", "6Zuq44Gg44KL44G-8J-YgA"},
	} {
		got := StringToBase64Url(row.in)
		if got != row.want {
			t.Errorf("StringToBase64Url(%q) = %q, want %q", row.in, got, row.want)
		}
		parsed := StringParseBase64Url(got)
		if !parsed.IsSomething() {
			t.Errorf("StringParseBase64Url(%q) rejected the encoder's own output", got)
		}
		if row.in != "\xfb\xff" {
			if back := StringFromBase64Url(got); back != row.in {
				t.Errorf("StringFromBase64Url(%q) = %q, want %q", got, back, row.in)
			}
		}
	}
}

func TestStringParseBase64UrlRejectsNonCanonical(t *testing.T) {
	for _, raw := range []string{
		"Zg==",   // padding
		"Zm8=",   // padding
		"Zh",     // non-zero trailing bits ("Zg" is canonical)
		"Z",      // impossible length
		"a+b/",   // standard alphabet
		"Zm9v\n", // Go's decoder skips newlines; canonical text has none
		"Zm\r9v", // likewise carriage returns
		"Zm9v ",  // whitespace
		"_w",     // decodes to 0xff: not UTF-8
		"wCg",    // 0xc0 0x28: invalid UTF-8 sequence
	} {
		if StringParseBase64Url(raw).IsSomething() {
			t.Errorf("StringParseBase64Url(%q) accepted a non-canonical or non-UTF-8 encoding", raw)
		}
	}
}

func TestStringHexRoundTrips(t *testing.T) {
	for _, row := range []struct{ in, want string }{
		{"", ""},
		{"A", "41"},
		{"hi!", "686921"},
		{"é", "c3a9"},
		{"😀", "f09f9880"},
	} {
		got := StringToHex(row.in)
		if got != row.want {
			t.Errorf("StringToHex(%q) = %q, want %q", row.in, got, row.want)
		}
		if !StringParseHex(got).IsSomething() {
			t.Errorf("StringParseHex(%q) rejected the encoder's own output", got)
		}
		if back := StringFromHex(got); back != row.in {
			t.Errorf("StringFromHex(%q) = %q, want %q", got, back, row.in)
		}
	}
	if got := StringToHex("\xff"); got != "efbfbd" {
		t.Errorf("StringToHex of invalid UTF-8 = %q, want the U+FFFD encoding efbfbd", got)
	}
}

func TestStringParseHexRejectsNonCanonical(t *testing.T) {
	for _, raw := range []string{
		"C3A9", // uppercase: decodable, but not the canonical spelling
		"c3A9",
		"4",    // odd length
		"zz",   // not hex
		"0x41", // prefix
		"ff",   // not UTF-8
		" 41",
	} {
		if StringParseHex(raw).IsSomething() {
			t.Errorf("StringParseHex(%q) accepted a non-canonical or non-UTF-8 encoding", raw)
		}
	}
}

func TestStringDecodersPanicOnUnprovenInput(t *testing.T) {
	for name, decode := range map[string]func(string) string{
		"StringFromBase64Url": StringFromBase64Url,
		"StringFromHex":       StringFromHex,
	} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("%s accepted input no proof could have produced", name)
				}
			}()
			decode("!!")
		}()
	}
}
