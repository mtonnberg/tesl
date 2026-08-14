package teslrt

import (
	"encoding/json"
	"math"
	"math/big"
	"reflect"
	"strings"
	"sync"
	"testing"
	"testing/quick"
	"unsafe"
)

func TestIntRepresentationContract(t *testing.T) {
	t.Parallel()

	if size := unsafe.Sizeof(Int{}); size != 16 {
		t.Fatalf("Int size = %d bytes, want 16", size)
	}
	if reflect.TypeOf(Int{}).Comparable() {
		t.Fatal("Int became Go-comparable; equality must route through Equal")
	}
}

func TestIntBoundariesAndCanonicalForm(t *testing.T) {
	t.Parallel()

	tests := []struct {
		input string
		want  string
		big   bool
	}{
		{"0", "0", false},
		{"-0", "0", false},
		{"+00042", "42", false},
		{"9223372036854775807", "9223372036854775807", false},
		{"-9223372036854775808", "-9223372036854775808", false},
		{"9223372036854775808", "9223372036854775808", true},
		{"-9223372036854775809", "-9223372036854775809", true},
		{"999999999999999999999999999999999999999", "999999999999999999999999999999999999999", true},
	}
	for _, test := range tests {
		test := test
		t.Run(test.input, func(t *testing.T) {
			got := MustParseDecimal(test.input)
			if got.String() != test.want {
				t.Fatalf("String() = %q, want %q", got.String(), test.want)
			}
			if (got.big != nil) != test.big {
				t.Fatalf("big presence = %v, want %v", got.big != nil, test.big)
			}
			assertCanonical(t, got)
		})
	}

	invalid := []string{"", "+", "-", " 1", "1 ", "1.0", "1e3", "4/2", "#x2a"}
	for _, input := range invalid {
		if _, err := ParseDecimal(input); err == nil {
			t.Errorf("ParseDecimal(%q) unexpectedly succeeded", input)
		}
	}
}

func TestIntSpillAndNormalize(t *testing.T) {
	t.Parallel()

	max := FromInt64(math.MaxInt64)
	min := FromInt64(math.MinInt64)
	one := FromInt64(1)

	maxPlusOne := Add(max, one)
	assertInt(t, maxPlusOne, "9223372036854775808")
	assertCanonical(t, maxPlusOne)
	assertInt(t, Sub(maxPlusOne, one), "9223372036854775807")
	assertCanonical(t, Sub(maxPlusOne, one))

	minMinusOne := Sub(min, one)
	assertInt(t, minMinusOne, "-9223372036854775809")
	assertInt(t, Neg(min), "9223372036854775808")
	assertInt(t, Abs(min), "9223372036854775808")

	quotient, err := Quo(min, FromInt64(-1))
	if err != nil {
		t.Fatal(err)
	}
	assertInt(t, quotient, "9223372036854775808")

	assertInt(t, Mul(max, FromInt64(2)), "18446744073709551614")
	assertInt(t, Mul(min, FromInt64(-1)), "9223372036854775808")
	assertInt(t, Mul(maxPlusOne, Int{}), "0")
	assertInt(t, Add(MustParseDecimal("-9223372036854775809"), one), "-9223372036854775808")
	assertInt(t, Sub(MustParseDecimal("-9223372036854775809"), FromInt64(-1)), "-9223372036854775808")

	for _, value := range []int64{math.MinInt64, math.MinInt64 + 1, -1, 0, 1, math.MaxInt64 - 1, math.MaxInt64} {
		assertCanonical(t, FromInt64(value))
	}
}

func TestIntDivisionRemainderAndModuloSigns(t *testing.T) {
	t.Parallel()

	tests := []struct {
		a, b         int64
		quo, rem     string
		mathematical string
	}{
		{7, 3, "2", "1", "1"},
		{-7, 3, "-2", "-1", "2"},
		{7, -3, "-2", "1", "-2"},
		{-7, -3, "2", "-1", "-1"},
	}
	for _, test := range tests {
		a, b := FromInt64(test.a), FromInt64(test.b)
		quo, err := Quo(a, b)
		if err != nil {
			t.Fatal(err)
		}
		rem, err := Rem(a, b)
		if err != nil {
			t.Fatal(err)
		}
		mod, err := Mod(a, b)
		if err != nil {
			t.Fatal(err)
		}
		assertInt(t, quo, test.quo)
		assertInt(t, rem, test.rem)
		assertInt(t, mod, test.mathematical)
		assertInt(t, Add(Mul(quo, b), rem), a.String())
	}

	if _, err := Quo(FromInt64(1), Int{}); err != ErrDivisionByZero {
		t.Fatalf("Quo zero error = %v", err)
	}
	if _, err := Rem(FromInt64(1), Int{}); err != ErrDivisionByZero {
		t.Fatalf("Rem zero error = %v", err)
	}
}

func TestIntLibraryOperations(t *testing.T) {
	t.Parallel()

	assertInt(t, GCD(FromInt64(-54), FromInt64(24)), "6")
	assertInt(t, GCD(Int{}, Int{}), "0")
	assertInt(t, LCM(FromInt64(-21), FromInt64(6)), "42")
	assertInt(t, LCM(Int{}, FromInt64(6)), "0")

	power, err := Pow(FromInt64(-2), FromInt64(10))
	if err != nil {
		t.Fatal(err)
	}
	assertInt(t, power, "1024")
	if _, err := Pow(FromInt64(2), FromInt64(-1)); err != ErrNegativePower {
		t.Fatalf("negative Pow error = %v", err)
	}

	if got := MustParseDecimal("-100000000000000000000").Digits(); got != 21 {
		t.Fatalf("Digits() = %d, want 21", got)
	}
	if got := (Int{}).Digits(); got != 1 {
		t.Fatalf("zero Digits() = %d, want 1", got)
	}
	if !FromInt64(-4).IsEven() || !FromInt64(-3).IsOdd() {
		t.Fatal("negative parity mismatch")
	}
	assertInt(t, Clamp(FromInt64(20), FromInt64(0), FromInt64(10)), "10")
}

func TestIntFloatConversions(t *testing.T) {
	t.Parallel()

	value, err := FromFloat64(-42.9)
	if err != nil {
		t.Fatal(err)
	}
	assertInt(t, value, "-42")
	if _, err := FromFloat64(math.NaN()); err != ErrInvalidFloat {
		t.Fatalf("NaN error = %v", err)
	}
	if _, err := FromFloat64(math.Inf(1)); err != ErrInvalidFloat {
		t.Fatalf("Inf error = %v", err)
	}
	if !math.IsInf(MustParseDecimal(strings.Repeat("9", 400)).Float64(), 1) {
		t.Fatal("huge Int did not convert to +Inf")
	}
}

func TestIntJSONKeyHashAndImmutability(t *testing.T) {
	t.Parallel()

	original := MustParseDecimal("123456789012345678901234567890")
	copyOfOriginal := original
	result := Add(original, FromInt64(10))
	assertInt(t, original, "123456789012345678901234567890")
	assertInt(t, copyOfOriginal, "123456789012345678901234567890")
	assertInt(t, result, "123456789012345678901234567900")

	encoded, err := json.Marshal(original)
	if err != nil {
		t.Fatal(err)
	}
	if string(encoded) != original.String() {
		t.Fatalf("JSON = %s, want %s", encoded, original.String())
	}
	var decoded Int
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if !Equal(original, decoded) {
		t.Fatalf("JSON round trip = %s, want %s", decoded.String(), original.String())
	}
	for _, invalid := range []string{`"1"`, `1.0`, `1e3`, `01`, `+1`, `null`} {
		if err := json.Unmarshal([]byte(invalid), &decoded); err == nil {
			t.Errorf("json.Unmarshal(%s) unexpectedly succeeded", invalid)
		}
	}

	viaSpill := Sub(Add(FromInt64(math.MaxInt64), FromInt64(1)), FromInt64(1))
	if viaSpill.Key() != FromInt64(math.MaxInt64).Key() {
		t.Fatal("equal integers produced different keys")
	}
	if viaSpill.Hash64() != FromInt64(math.MaxInt64).Hash64() {
		t.Fatal("equal integers produced different hashes")
	}
	values := map[IntKey]string{original.Key(): "found"}
	if values[decoded.Key()] != "found" {
		t.Fatal("canonical map key lookup failed")
	}
}

func TestIntConcurrentCopiesStayImmutable(t *testing.T) {
	t.Parallel()

	original := MustParseDecimal("1234567890123456789012345678901234567890")
	const workers = 32
	var wait sync.WaitGroup
	wait.Add(workers)
	for worker := 0; worker < workers; worker++ {
		go func(offset int64) {
			defer wait.Done()
			for iteration := int64(0); iteration < 1000; iteration++ {
				copyOfOriginal := original
				result := Sub(Add(copyOfOriginal, FromInt64(offset+iteration)), FromInt64(offset+iteration))
				if !Equal(result, original) {
					t.Errorf("concurrent operation changed value: got %s", result.String())
					return
				}
			}
		}(int64(worker))
	}
	wait.Wait()
	assertInt(t, original, "1234567890123456789012345678901234567890")
}

func TestIntProperties(t *testing.T) {
	t.Parallel()

	check := func(name string, property any) {
		t.Helper()
		if err := quick.Check(property, &quick.Config{MaxCount: 2000}); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
	}

	check("add commutative", func(a, b int64) bool {
		return Equal(Add(FromInt64(a), FromInt64(b)), Add(FromInt64(b), FromInt64(a)))
	})
	check("mul commutative", func(a, b int64) bool {
		return Equal(Mul(FromInt64(a), FromInt64(b)), Mul(FromInt64(b), FromInt64(a)))
	})
	check("identities", func(a int64) bool {
		value := FromInt64(a)
		return Equal(Add(value, Int{}), value) && Equal(Mul(value, FromInt64(1)), value)
	})
	check("add associative", func(a, b, c int64) bool {
		aa, bb, cc := FromInt64(a), FromInt64(b), FromInt64(c)
		return Equal(Add(Add(aa, bb), cc), Add(aa, Add(bb, cc)))
	})
	check("mul associative and distributive", func(a, b, c int64) bool {
		aa, bb, cc := FromInt64(a), FromInt64(b), FromInt64(c)
		return Equal(Mul(Mul(aa, bb), cc), Mul(aa, Mul(bb, cc))) &&
			Equal(Mul(aa, Add(bb, cc)), Add(Mul(aa, bb), Mul(aa, cc)))
	})
	check("add inverse", func(a int64) bool {
		aa := FromInt64(a)
		return Add(aa, Neg(aa)).IsZero()
	})
	check("compare total order", func(a, b int64) bool {
		aa, bb := FromInt64(a), FromInt64(b)
		cmp := Compare(aa, bb)
		return cmp == -Compare(bb, aa) && (cmp < 0 || cmp == 0 || cmp > 0) &&
			(Equal(aa, bb) == (cmp == 0))
	})
	check("compare transitive", func(a, b, c int64) bool {
		aa, bb, cc := FromInt64(a), FromInt64(b), FromInt64(c)
		return Compare(aa, bb) > 0 || Compare(bb, cc) > 0 || Compare(aa, cc) <= 0
	})
	check("negation and abs", func(a int64) bool {
		value := FromInt64(a)
		return Equal(Neg(Neg(value)), value) && Abs(value).Sign() >= 0 &&
			Equal(Abs(value), Abs(Neg(value)))
	})
	check("quo-rem reconstruction", func(a, b int64) bool {
		if b == 0 {
			return true
		}
		aa, bb := FromInt64(a), FromInt64(b)
		q, qErr := Quo(aa, bb)
		r, rErr := Rem(aa, bb)
		return qErr == nil && rErr == nil && Equal(Add(Mul(q, bb), r), aa) &&
			(Abs(r).IsZero() || Compare(Abs(r), Abs(bb)) < 0)
	})
	check("math-big differential", func(a, b int64) bool {
		aa, bb := FromInt64(a), FromInt64(b)
		bigA, bigB := big.NewInt(a), big.NewInt(b)
		return Add(aa, bb).String() == new(big.Int).Add(bigA, bigB).String() &&
			Sub(aa, bb).String() == new(big.Int).Sub(bigA, bigB).String() &&
			Mul(aa, bb).String() == new(big.Int).Mul(bigA, bigB).String()
	})
}

func assertInt(t *testing.T, got Int, want string) {
	t.Helper()
	if got.String() != want {
		t.Fatalf("Int = %s, want %s", got.String(), want)
	}
	assertCanonical(t, got)
}

func assertCanonical(t *testing.T, value Int) {
	t.Helper()
	if value.big == nil {
		return
	}
	if value.big.IsInt64() {
		t.Fatalf("non-canonical big Int %s fits int64", value.String())
	}
	if value.small != 0 {
		t.Fatalf("non-canonical big Int %s retains small=%d", value.String(), value.small)
	}
}

func TestIntChecksRejectWithTeslStatusAndMessage(t *testing.T) {
	for _, row := range []struct {
		name    string
		result  Check[Int]
		ok      bool
		message string
	}{
		{"nonZero(1)", IntNonZero(FromInt64(1)), true, ""},
		{"nonZero(0)", IntNonZero(Int{}), false, "expected a non-zero integer"},
		{"nonZero(-1)", IntNonZero(FromInt64(-1)), true, ""},
		{"nonNegative(0)", IntNonNegative(Int{}), true, ""},
		{"nonNegative(1)", IntNonNegative(FromInt64(1)), true, ""},
		{"nonNegative(-1)", IntNonNegative(FromInt64(-1)), false, "expected a non-negative integer"},
		{"nonNegative(-huge)", IntNonNegative(Neg(MustParseDecimal("99999999999999999999"))), false,
			"expected a non-negative integer"},
	} {
		if row.result.OK() != row.ok {
			t.Errorf("%s: OK = %v, want %v", row.name, row.result.OK(), row.ok)
			continue
		}
		if row.ok {
			continue
		}
		if row.result.Status() != 400 {
			t.Errorf("%s: status = %d, want 400", row.name, row.result.Status())
		}
		if row.result.Message() != row.message {
			t.Errorf("%s: message = %q, want %q", row.name, row.result.Message(), row.message)
		}
	}
}

func TestIntLeafWrappers(t *testing.T) {
	if got := IntSign(FromInt64(-7)); got.String() != "-1" {
		t.Errorf("IntSign(-7) = %s", got.String())
	}
	if got := IntSign(FromInt64(0)); got.String() != "0" {
		t.Errorf("IntSign(0) = %s", got.String())
	}
	if got := IntSign(FromInt64(9)); got.String() != "1" {
		t.Errorf("IntSign(9) = %s", got.String())
	}
	if !IntIsEven(FromInt64(-4)) || IntIsOdd(FromInt64(-4)) {
		t.Error("-4 is even")
	}
	if !IntIsOdd(FromInt64(-3)) || IntIsEven(FromInt64(-3)) {
		t.Error("-3 is odd")
	}
	if IntToString(FromInt64(-12)) != "-12" {
		t.Error("IntToString(-12)")
	}
	if got := Clamp(FromInt64(9), FromInt64(0), FromInt64(5)); got.String() != "5" {
		t.Errorf("Clamp(9, 0, 5) = %s", got.String())
	}
	if got := Clamp(FromInt64(-9), FromInt64(0), FromInt64(5)); got.String() != "0" {
		t.Errorf("Clamp(-9, 0, 5) = %s", got.String())
	}
	if got := MustPow(FromInt64(2), FromInt64(10)); got.String() != "1024" {
		t.Errorf("MustPow(2, 10) = %s", got.String())
	}
	if got := MustPow(FromInt64(5), FromInt64(0)); got.String() != "1" {
		t.Errorf("MustPow(5, 0) = %s", got.String())
	}
	// Racket's Int.pow rejects a negative exponent rather than returning a fraction.
	func() {
		defer func() {
			if recover() == nil {
				t.Error("a negative exponent must panic")
			}
		}()
		MustPow(FromInt64(2), FromInt64(-1))
	}()
}
