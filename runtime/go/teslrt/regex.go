package teslrt

import (
	"regexp"
	"strconv"
	"sync"
)

// `Tesl.Regex` — regular expressions over String.
//
// Every pattern is argument 1 and is a STRING LITERAL the compiler has already checked
// (`compiler/lib/regex_lint.ml`, VREGEX001-4): it must parse in Tesl's subset, it may not
// backtrack catastrophically, and each of its capture groups must participate in every
// successful match. This module is written as if none of that were true, because it is the
// last line of defence.
//
// ONE DELIBERATE DIFFERENCE FROM THE RACKET RUNTIME, and it is a strengthening: Racket's
// matcher backtracks, so it runs every match in its own thread under a wall-clock deadline
// (TESL_REGEX_TIMEOUT_MS) to bound a pathological pattern to one slice instead of the
// process. Go's regexp is RE2 — it runs in time linear in the length of the input and the
// pattern, and it cannot express the constructs that make backtracking blow up
// (backreferences, lookaround), which are the same constructs the compiler's lint already
// refuses. The bound the deadline existed to provide therefore holds by construction, and a
// timeout knob that can never fire would be a promise about scheduling rather than about
// work. The INPUT bound is kept: it is about memory, not backtracking.
//
// The other property worth naming is in Replace: the replacement is inserted LITERALLY.

// tesl-regex-max-input on the Racket side: an upper bound on the subject, in characters.
func regexMaxInput() int {
	return envPositiveInt("TESL_REGEX_MAX_INPUT_BYTES", 1048576)
}

var (
	regexCacheMutex sync.Mutex
	regexCache      = map[string]*regexp.Regexp{}
)

// RegexCompile compiles and memoises a pattern. A pattern that does not compile is a clean
// trap naming it, not a raw error from the engine.
func RegexCompile(who, pattern string) *regexp.Regexp {
	regexCacheMutex.Lock()
	compiled, cached := regexCache[pattern]
	regexCacheMutex.Unlock()
	if cached {
		return compiled
	}
	compiled, err := regexp.Compile(pattern)
	if err != nil {
		panic(who + ": pattern " + strconv.Quote(pattern) + " does not compile: " + err.Error())
	}
	regexCacheMutex.Lock()
	regexCache[pattern] = compiled
	regexCacheMutex.Unlock()
	return compiled
}

func regexSubject(who, input string) string {
	limit := regexMaxInput()
	// Characters, not bytes, matching the Racket runtime's `string-length` — the two agree
	// on where the line is for a subject that is not pure ASCII.
	if length := len([]rune(input)); length > limit {
		panic(who + ": input of " + strconv.Itoa(length) + " characters exceeds the " +
			strconv.Itoa(limit) + " character regex input limit" +
			"\n  (raise TESL_REGEX_MAX_INPUT_BYTES if this is intentional)")
	}
	return input
}

// RegexMatches reports whether the pattern matches ANYWHERE in the input. Anchor with ^ and
// $ to require a whole-string match.
func RegexMatches(pattern, input string) bool {
	return RegexCompile("Regex.matches", pattern).
		MatchString(regexSubject("Regex.matches", input))
}

// RegexFind answers the text of the first match. Nothing and an empty match are different
// answers, which is why the index form decides rather than the string form.
func RegexFind(pattern, input string) Maybe[string] {
	compiled := RegexCompile("Regex.find", pattern)
	subject := regexSubject("Regex.find", input)
	span := compiled.FindStringIndex(subject)
	if span == nil {
		return Nothing[string]()
	}
	return Something(subject[span[0]:span[1]])
}

// RegexFindAll answers every non-overlapping match, left to right.
func RegexFindAll(pattern, input string) []string {
	found := RegexCompile("Regex.findAll", pattern).
		FindAllString(regexSubject("Regex.findAll", input), -1)
	if found == nil {
		return []string{}
	}
	return found
}

// RegexCaptures answers the capture groups of the first match, in source order, EXCLUDING
// the whole match — use RegexFind for that. A pattern with no groups answers `Something []`
// on a match.
//
// The list is `List String` rather than `List (Maybe String)` because the compiler rejects
// patterns whose groups can fail to participate (VREGEX004); the empty string for a
// non-participating group is unreachable for a checked pattern and exists so this function
// is total on its own.
func RegexCaptures(pattern, input string) Maybe[[]string] {
	match := RegexCompile("Regex.captures", pattern).
		FindStringSubmatch(regexSubject("Regex.captures", input))
	if match == nil {
		return Nothing[[]string]()
	}
	groups := make([]string, 0, len(match)-1)
	groups = append(groups, match[1:]...)
	return Something(groups)
}

// RegexReplace replaces EVERY match. The replacement is inserted LITERALLY: `$1`, `\1` and
// `&` are ordinary characters, not group references, so a replacement built from user data
// can never be reinterpreted as a substitution directive. Go's ReplaceAllString DOES expand
// `$1`, which is why this is the Literal form and not that one.
func RegexReplace(pattern, input, replacement string) string {
	return RegexCompile("Regex.replace", pattern).
		ReplaceAllLiteralString(regexSubject("Regex.replace", input), replacement)
}

// RegexSplit splits on every match. Adjacent matches and matches at the ends produce empty
// strings, exactly as String.split does.
func RegexSplit(pattern, input string) []string {
	parts := RegexCompile("Regex.split", pattern).
		Split(regexSubject("Regex.split", input), -1)
	if parts == nil {
		return []string{}
	}
	return parts
}
