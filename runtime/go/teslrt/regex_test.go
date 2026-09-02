package teslrt

import (
	"strings"
	"testing"
)

func TestRegexMatchesAnywhereUnlessAnchored(t *testing.T) {
	if !RegexMatches("cat", "the cat sat") {
		t.Fatal("an unanchored pattern should match anywhere")
	}
	if RegexMatches("^cat$", "the cat sat") {
		t.Fatal("an anchored pattern should need the whole string")
	}
	if !RegexMatches("^cat$", "cat") {
		t.Fatal("an anchored pattern should match the whole string")
	}
}

// Nothing and an EMPTY match are different answers, which a string-returning find cannot
// tell apart.
func TestRegexFindDistinguishesNothingFromAnEmptyMatch(t *testing.T) {
	if value, ok := RegexFind("[0-9]+", "abc 42 def").Value(); !ok || value != "42" {
		t.Fatalf("find = %q (%v)", value, ok)
	}
	if _, ok := RegexFind("[0-9]+", "abc").Value(); ok {
		t.Fatal("a pattern that does not match should answer Nothing")
	}
	value, ok := RegexFind("x*", "abc").Value()
	if !ok || value != "" {
		t.Fatalf("an empty match = %q (%v), want the empty string present", value, ok)
	}
}

// A list result is never nil: an empty answer is an empty list, which is what a Tesl `List`
// is.
func TestRegexFindAllAnswersEveryMatchAndNeverNil(t *testing.T) {
	got := RegexFindAll("[0-9]+", "a1 b22 c333")
	want := []string{"1", "22", "333"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("findAll = %v, want %v", got, want)
	}
	empty := RegexFindAll("[0-9]+", "abc")
	if empty == nil || len(empty) != 0 {
		t.Fatalf("no matches = %#v, want an empty list", empty)
	}
}

func TestRegexCapturesExcludesTheWholeMatch(t *testing.T) {
	groups, ok := RegexCaptures("([a-z]+)-([0-9]+)", "id: abc-42 rest").Value()
	if !ok {
		t.Fatal("expected a match")
	}
	if strings.Join(groups, ",") != "abc,42" {
		t.Fatalf("captures = %v, want the two groups without the whole match", groups)
	}
	// A pattern with no groups still answers Something on a match.
	none, ok := RegexCaptures("[0-9]+", "42").Value()
	if !ok || len(none) != 0 {
		t.Fatalf("no-group captures = %#v (%v), want an empty list present", none, ok)
	}
	if _, ok := RegexCaptures("([0-9]+)", "abc").Value(); ok {
		t.Fatal("no match should answer Nothing")
	}
}

// THE security property: the replacement is inserted literally, so a replacement built from
// user data cannot be reinterpreted as a substitution directive. Go's ReplaceAllString would
// expand `$1`; this must not.
func TestRegexReplaceInsertsTheReplacementLiterally(t *testing.T) {
	cases := []struct{ pattern, input, replacement, want string }{
		{"cat", "the cat sat", "dog", "the dog sat"},
		{"[0-9]+", "a1b22c", "#", "a#b#c"},
		// Group references are ordinary characters.
		{"([a-z])([0-9])", "a1", "$2$1", "$2$1"},
		{"([a-z])([0-9])", "a1", "\\1", "\\1"},
		{"([a-z])([0-9])", "a1", "&", "&"},
		{"([a-z])([0-9])", "a1", "${1}", "${1}"},
	}
	for _, testCase := range cases {
		got := RegexReplace(testCase.pattern, testCase.input, testCase.replacement)
		if got != testCase.want {
			t.Fatalf("replace(%q, %q, %q) = %q, want %q",
				testCase.pattern, testCase.input, testCase.replacement, got, testCase.want)
		}
	}
}

func TestRegexSplitKeepsTheEmptyPieces(t *testing.T) {
	cases := []struct {
		pattern, input string
		want           []string
	}{
		{",", "a,b,c", []string{"a", "b", "c"}},
		// Adjacent matches and matches at the ends produce empty strings, as String.split does.
		{",", ",a,,b,", []string{"", "a", "", "b", ""}},
		{",", "", []string{""}},
		{"[0-9]+", "a1b22c", []string{"a", "b", "c"}},
	}
	for _, testCase := range cases {
		got := RegexSplit(testCase.pattern, testCase.input)
		if strings.Join(got, "|") != strings.Join(testCase.want, "|") {
			t.Fatalf("split(%q, %q) = %#v, want %#v",
				testCase.pattern, testCase.input, got, testCase.want)
		}
	}
}

// A pattern that does not compile traps naming itself, rather than surfacing the engine's
// own error with no context.
func TestRegexCompileFailsLoudly(t *testing.T) {
	mustPanic(t, "Regex.matches: pattern \"[unclosed\" does not compile", func() {
		RegexMatches("[unclosed", "anything")
	})
}

// The INPUT bound is a memory guarantee and is kept; the wall-clock deadline is not, because
// RE2 runs in time linear in the input and cannot express what makes backtracking blow up.
func TestRegexInputIsBounded(t *testing.T) {
	t.Setenv("TESL_REGEX_MAX_INPUT_BYTES", "16")
	if RegexMatches("a", strings.Repeat("a", 16)) != true {
		t.Fatal("an input at the limit should be accepted")
	}
	mustPanic(t, "exceeds the 16 character regex input limit", func() {
		RegexMatches("a", strings.Repeat("a", 17))
	})
}

// The limit counts CHARACTERS, matching Racket's `string-length`, so the two backends agree
// on where the line is for a subject that is not pure ASCII.
func TestRegexInputLimitCountsCharacters(t *testing.T) {
	t.Setenv("TESL_REGEX_MAX_INPUT_BYTES", "4")
	// Four runes, twelve bytes.
	if !RegexMatches("開", "開発言語だ"[:0]+"開発言語") {
		t.Fatal("four characters should be accepted")
	}
	mustPanic(t, "input of 5 characters", func() { RegexMatches("開", "開発言語だ") })
}

// A pattern is compiled once and reused; the cache must not change what it answers.
func TestRegexCacheReturnsTheSamePattern(t *testing.T) {
	first := RegexCompile("Regex.matches", "[0-9]+")
	second := RegexCompile("Regex.matches", "[0-9]+")
	if first != second {
		t.Fatal("the same pattern should compile once")
	}
	if !first.MatchString("42") {
		t.Fatal("the cached pattern should still match")
	}
}

// The compile cache is an LRU of regexCacheCapacity entries: a stream of distinct patterns
// churns it without growing it, and the patterns in use stay hot.
func TestRegexCacheIsBounded(t *testing.T) {
	hot := RegexCompile("Regex.matches", "^hot-[a-z]+$")
	for i := 0; i < 4*regexCacheCapacity; i++ {
		RegexCompile("Regex.matches", "^distinct-"+strconvItoa(i)+"$")
		if i%16 == 0 {
			// Touched regularly, so it is never the least recently used.
			RegexCompile("Regex.matches", "^hot-[a-z]+$")
		}
	}
	if size := regexCacheSize(); size > regexCacheCapacity {
		t.Fatalf("cache holds %d patterns, want at most %d", size, regexCacheCapacity)
	}
	if again := RegexCompile("Regex.matches", "^hot-[a-z]+$"); again != hot {
		t.Fatal("the hot pattern was evicted")
	}
	if RegexCompile("Regex.matches", "^distinct-0$") == nil || !RegexMatches("^distinct-0$", "distinct-0") {
		t.Fatal("an evicted pattern must simply recompile")
	}
}
