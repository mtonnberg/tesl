package teslrt

import (
	"encoding/json"
	"math/big"
	"testing"
)

func FuzzIntDecimalAndJSONRoundTrip(f *testing.F) {
	for _, seed := range []string{
		"0", "-0", "9223372036854775807", "9223372036854775808",
		"-9223372036854775808", "-9223372036854775809",
		"1234567890123456789012345678901234567890",
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, input string) {
		if len(input) > 512 {
			t.Skip()
		}
		value, err := ParseDecimal(input)
		if err != nil {
			return
		}
		assertCanonical(t, value)
		roundTrip, err := ParseDecimal(value.String())
		if err != nil || !Equal(value, roundTrip) {
			t.Fatalf("decimal round trip failed for %q", input)
		}
		encoded, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		var decoded Int
		if err := json.Unmarshal(encoded, &decoded); err != nil || !Equal(value, decoded) {
			t.Fatalf("JSON round trip failed for %q: %v", input, err)
		}
	})
}

func FuzzIntArithmeticAgainstBig(f *testing.F) {
	seeds := [][2]string{
		{"0", "1"},
		{"9223372036854775807", "1"},
		{"-9223372036854775808", "-1"},
		{"123456789012345678901234567890", "-98765432109876543210"},
	}
	for _, seed := range seeds {
		f.Add(seed[0], seed[1])
	}
	f.Fuzz(func(t *testing.T, leftText, rightText string) {
		if len(leftText) > 256 || len(rightText) > 256 {
			t.Skip()
		}
		left, leftErr := ParseDecimal(leftText)
		right, rightErr := ParseDecimal(rightText)
		if leftErr != nil || rightErr != nil {
			return
		}
		bigLeft, _ := new(big.Int).SetString(left.String(), 10)
		bigRight, _ := new(big.Int).SetString(right.String(), 10)

		assertMatchesBig(t, Add(left, right), new(big.Int).Add(bigLeft, bigRight))
		assertMatchesBig(t, Sub(left, right), new(big.Int).Sub(bigLeft, bigRight))
		assertMatchesBig(t, Mul(left, right), new(big.Int).Mul(bigLeft, bigRight))
		if !right.IsZero() {
			quotient, err := Quo(left, right)
			if err != nil {
				t.Fatal(err)
			}
			remainder, err := Rem(left, right)
			if err != nil {
				t.Fatal(err)
			}
			assertMatchesBig(t, quotient, new(big.Int).Quo(bigLeft, bigRight))
			assertMatchesBig(t, remainder, new(big.Int).Rem(bigLeft, bigRight))
		}
		// Pow: every accepted power matches math/big, and a refusal happens exactly when
		// bits(base)*exponent exceeds maxPowResultBits with |base| >= 2. An accepted result
		// is at most maxPowResultBits wide, so the oracle stays cheap.
		if right.Sign() >= 0 {
			power, err := Pow(left, right)
			bound := new(big.Int).Mul(big.NewInt(int64(bigLeft.BitLen())), bigRight)
			overBound := bigLeft.BitLen() > 1 && bound.Cmp(big.NewInt(maxPowResultBits)) > 0
			switch {
			case err == nil && overBound:
				t.Fatalf("Pow(%s, %s) computed a result past the bound", leftText, rightText)
			case err == ErrPowTooLarge && !overBound:
				t.Fatalf("Pow(%s, %s) refused a result within the bound", leftText, rightText)
			case err == nil:
				assertMatchesBig(t, power, new(big.Int).Exp(bigLeft, bigRight, nil))
			case err != ErrPowTooLarge:
				t.Fatal(err)
			}
		}
	})
}

func FuzzIntJSONInput(f *testing.F) {
	for _, seed := range []string{
		"0", "-1", "9223372036854775808", `"1"`, "1.0", "1e3", "01", "+1", "null", "", " ",
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, input string) {
		if len(input) > 512 {
			t.Skip()
		}
		var value Int
		err := json.Unmarshal([]byte(input), &value)
		if err != nil {
			return
		}
		assertCanonical(t, value)
		encoded, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		var roundTrip Int
		if err := json.Unmarshal(encoded, &roundTrip); err != nil || !Equal(value, roundTrip) {
			t.Fatalf("accepted JSON did not round trip: %q: %v", input, err)
		}
	})
}

func assertMatchesBig(t *testing.T, got Int, want *big.Int) {
	t.Helper()
	if got.String() != want.String() {
		t.Fatalf("got %s, want %s", got.String(), want.String())
	}
	assertCanonical(t, got)
}
