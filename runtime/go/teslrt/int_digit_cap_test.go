package teslrt

import (
	"errors"
	"strings"
	"testing"
	"time"
)

// Every Int-from-text path shares one digit bound (whitebox campaign, 2026-09-02): the JSON
// cap alone left `IntegerSegment` (path captures) and `String.toInt` on the quadratic
// big.Int parse, and a 900 000-digit path segment cost ~1.7 s of CPU per request.
func TestDecimalDigitCapCoversEveryParsePath(t *testing.T) {
	huge := strings.Repeat("9", 900000)
	deadline := 20 * time.Millisecond

	started := time.Now()
	if _, err := ParseDecimal(huge); !errors.Is(err, ErrIntTooLong) {
		t.Fatalf("ParseDecimal(900k digits) = %v, want ErrIntTooLong", err)
	}
	if _, err := ParseDecimal("-" + huge); !errors.Is(err, ErrIntTooLong) {
		t.Fatal("a negative oversized literal must be refused by length too")
	}
	if elapsed := time.Since(started); elapsed > deadline {
		t.Fatalf("ParseDecimal took %v; the bound must be decided before SetString", elapsed)
	}

	started = time.Now()
	rejected := IntegerSegment(huge)
	if rejected.OK() || rejected.Status() != 400 {
		t.Fatalf("IntegerSegment(900k digits) = %+v, want 400", rejected)
	}
	if len(rejected.Message()) > 200 {
		t.Fatalf("the 400 echoes the segment (%d bytes)", len(rejected.Message()))
	}
	if elapsed := time.Since(started); elapsed > deadline {
		t.Fatalf("IntegerSegment took %v", elapsed)
	}

	started = time.Now()
	if got := StringToInt(huge); got.IsSomething() {
		t.Fatal("String.toInt of 900k digits must be Nothing")
	}
	if elapsed := time.Since(started); elapsed > deadline {
		t.Fatalf("StringToInt took %v", elapsed)
	}

	if !validJSONInteger(huge) == false {
		t.Fatal("validJSONInteger accepted an oversized literal")
	}

	// At the bound the value still parses exactly.
	atBound := strings.Repeat("7", maxDecimalDigits)
	parsed, err := ParseDecimal(atBound)
	if err != nil || parsed.String() != atBound {
		t.Fatalf("a %d-digit literal must parse: %v", maxDecimalDigits, err)
	}
	if _, err := ParseDecimal("-" + atBound); err != nil {
		t.Fatalf("a signed %d-digit literal must parse: %v", maxDecimalDigits, err)
	}
}
