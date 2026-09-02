package teslrt

import (
	"fmt"
	"math/big"
	"strings"
	"testing"
)

// Every expectation here was READ OFF the Racket runtime (tesl/money.rkt) rather than derived
// from the Go code: money is where the two backends must land on the same cent, and a rounding
// rule that "looks right" is exactly the kind of thing that differs by one in the tail.

func usd() Currency { return Currency{Code: "USD", MinorDigits: 2} }
func jpy() Currency { return Currency{Code: "JPY", MinorDigits: 0} }
func sek() Currency { return Currency{Code: "SEK", MinorDigits: 2} }

func money(currency Currency, minor int64) Money {
	return Money{MinorUnits: FromInt64(minor), Currency: currency}
}

func minor(t *testing.T, amount Money) int64 {
	t.Helper()
	value, exact := amount.MinorUnits.Int64()
	if !exact {
		t.Fatalf("minor units %s do not fit an int64", amount.MinorUnits.String())
	}
	return value
}

func TestMoneyScaleIsExact(t *testing.T) {
	// An integer scale never rounds: quantity × unit price is exact by construction.
	if got := minor(t, MoneyScale(money(usd(), 1999), FromInt64(3))); got != 5997 {
		t.Fatalf("1999 × 3 = %d", got)
	}
	if got := minor(t, MoneyScale(money(usd(), -250), FromInt64(4))); got != -1000 {
		t.Fatalf("-250 × 4 = %d", got)
	}
}

// The tie cases are the point: half-even sends .5 to the EVEN neighbour, in both directions,
// which is what keeps a long series of roundings from drifting upward.
func TestMoneyScaleByRoundsHalfEven(t *testing.T) {
	for _, want := range []struct {
		minorUnits int64
		factor     float64
		expected   int64
	}{
		{1000, 1.055, 1055}, // 1055 exactly — no tie
		{1050, 0.5, 525},
		{1150, 0.5, 575},
		{1005, 0.5, 502},   // 502.5 → 502, the even side
		{1015, 0.5, 508},   // 507.5 → 508, the even side
		{-1005, 0.5, -502}, // ties break the same way below zero
		{-1015, 0.5, -508},
		{333, 0.1, 33}, // 33.3 → 33
	} {
		got := minor(t, MoneyScaleBy(money(usd(), want.minorUnits), want.factor))
		if got != want.expected {
			t.Fatalf("%d × %v = %d, Racket says %d", want.minorUnits, want.factor, got, want.expected)
		}
	}
}

// A float factor is exactified DECIMAL-FAITHFULLY. With the binary value instead, 1000 × 0.9155
// is 915.4999… and rounds DOWN — a silent one-cent difference from Racket on every such rate.
func TestExchangeRateIsDecimalFaithful(t *testing.T) {
	rate := ExchangeRateMake(usd(), sek(), 0.9155, PosixMillis{Value: FromInt64(0)})
	if got := minor(t, MoneyConvertChecked(rate, money(usd(), 1000))); got != 916 {
		t.Fatalf("1000 USD at 0.9155 = %d, Racket says 916", got)
	}
	// And the stored rate is exact: 0.9155 is 1831/2000, not the float just under it.
	if rate.Rate.Cmp(big.NewRat(1831, 2000)) != 0 {
		t.Fatalf("the rate was stored as %s", rate.Rate.RatString())
	}
}

// Converting between currencies with different scales shifts by the DIGIT difference: JPY has
// no minor digits and USD has two, so the cents are not lost in either direction.
func TestConversionShiftsByMinorDigits(t *testing.T) {
	toYen := ExchangeRateMake(usd(), jpy(), 150.25, PosixMillis{Value: FromInt64(0)})
	if got := minor(t, MoneyConvertChecked(toYen, money(usd(), 1000))); got != 1502 {
		t.Fatalf("$10.00 at 150.25 = %d yen, Racket says 1502", got)
	}
	toDollars := ExchangeRateMake(jpy(), usd(), 0.0066, PosixMillis{Value: FromInt64(0)})
	if got := minor(t, MoneyConvertChecked(toDollars, money(jpy(), 1000))); got != 660 {
		t.Fatalf("¥1000 at 0.0066 = %d cents, Racket says 660", got)
	}
}

// The unproven path answers an Err rather than trapping: the caller has to deal with a rate
// that does not apply to the amount.
func TestConvertRefusesAMismatchedRate(t *testing.T) {
	rate := ExchangeRateMake(usd(), sek(), 0.9155, PosixMillis{Value: FromInt64(0)})
	result := MoneyConvert(rate, money(jpy(), 1000))
	if result.IsOk() {
		t.Fatal("a JPY amount was converted with a USD rate")
	}
	if result.ErrValue != "exchange rate is FROM USD but amount is in JPY" {
		t.Fatalf("the error reads %q", result.ErrValue)
	}
	// The proof-gated path traps on the same input: reaching it means the proof was bypassed.
	defer func() {
		if recover() == nil {
			t.Fatal("convertChecked accepted a mismatched rate")
		}
	}()
	MoneyConvertChecked(rate, money(jpy(), 1000))
}

func TestMoneyDisplayFollowsTheCurrency(t *testing.T) {
	for _, want := range []struct {
		amount   Money
		expected string
	}{
		{money(usd(), 1000), "$10.00"},
		{money(jpy(), 1000), "¥1000"}, // no minor digits at all
		{money(sek(), 1050), "10.50 SEK"},
		{money(usd(), -1005), "-$10.05"}, // the sign goes in front of the symbol
		{money(usd(), 5), "$0.05"},       // the minor part is zero-padded
	} {
		if got := MoneyDisplay(want.amount); got != want.expected {
			t.Fatalf("%s %d displays as %q, Racket says %q",
				want.amount.Currency.Code, minor(t, want.amount), got, want.expected)
		}
	}
}

func TestSameCurrencyArithmetic(t *testing.T) {
	if got := minor(t, MoneyAdd(money(usd(), 1000), money(usd(), 250))); got != 1250 {
		t.Fatalf("1000 + 250 = %d", got)
	}
	if got := minor(t, MoneySubtract(money(usd(), 1000), money(usd(), 250))); got != 750 {
		t.Fatalf("1000 - 250 = %d", got)
	}
	if got, _ := MoneyCompare(money(usd(), 1000), money(usd(), 250)).Int64(); got != 1 {
		t.Fatalf("compare answered %d", got)
	}
	// Mixing currencies traps: the SameCurrency proof is what makes these total.
	defer func() {
		if recover() == nil {
			t.Fatal("USD and JPY were added")
		}
	}()
	MoneyAdd(money(usd(), 1000), money(jpy(), 1000))
}

func TestMoneyChecksMintTheirRefusals(t *testing.T) {
	if MoneyRequireNonNegative(money(usd(), -1)).OK() {
		t.Fatal("a negative amount passed requireNonNegative")
	}
	if !MoneyRequireNonNegative(money(usd(), 0)).OK() {
		t.Fatal("zero was refused as negative")
	}
	mixed := MoneyRequireSameCurrency(money(usd(), 1), money(jpy(), 1))
	if mixed.OK() || mixed.Status() != 400 {
		t.Fatalf("mismatched currencies answered %+v", mixed)
	}
	rate := ExchangeRateMake(usd(), sek(), 1.0, PosixMillis{Value: FromInt64(0)})
	if !MoneyRequireRateFor(rate, money(usd(), 1)).OK() {
		t.Fatal("a matching rate was refused")
	}
	if MoneyRequireRateFor(rate, money(jpy(), 1)).OK() {
		t.Fatal("a rate for another currency was accepted")
	}
}

func TestCurrencyFromCodeResolvesTheIsoTable(t *testing.T) {
	found := CurrencyFromCode("SEK")
	if !found.IsSomething() || found.SomethingValue.MinorDigits != 2 {
		t.Fatalf("SEK resolved to %+v", found)
	}
	// The digit count is per currency and load-bearing.
	yen := CurrencyFromCode("JPY")
	if !yen.IsSomething() || yen.SomethingValue.MinorDigits != 0 {
		t.Fatalf("JPY resolved to %+v", yen)
	}
	bahraini := CurrencyFromCode("BHD")
	if !bahraini.IsSomething() || bahraini.SomethingValue.MinorDigits != 3 {
		t.Fatalf("BHD resolved to %+v", bahraini)
	}
	if CurrencyFromCode("ZZZ").IsSomething() {
		t.Fatal("an unknown code resolved to a currency")
	}
}

// A rate is money per SI-canonical unit; the label is what it DISPLAYS and quantizes per, so a
// per-hour rate stays a per-hour rate rather than collapsing to per-second.
func TestMoneyRatePerHour(t *testing.T) {
	rate := MoneyRateOf(money(sek(), 95000), big.NewRat(3600, 1), "h")
	if got := MoneyRateDisplay(rate); got != "950.00 SEK/h" {
		t.Fatalf("the rate displays as %q, Racket says \"950.00 SEK/h\"", got)
	}
	// 1.5 hours = 5400 canonical seconds; the ONE rounding happens here.
	if got := minor(t, MoneyRateMul(rate, 5400)); got != 142500 {
		t.Fatalf("1.5h at 950/h = %d, Racket says 142500", got)
	}
}

func TestMoneyRateScaleStaysExact(t *testing.T) {
	rate := MoneyRateOf(money(sek(), 95000), big.NewRat(3600, 1), "h")
	// A 10% uplift on a rate does not round — nothing rounds until an amount materialises.
	raised := MoneyRateScale(rate, 1.1)
	if got := MoneyRateDisplay(raised); got != "1045.00 SEK/h" {
		t.Fatalf("the raised rate displays as %q", got)
	}
}

func TestMoneyRateDivRefusesAZeroQuantity(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("a rate was built by dividing by zero")
		}
	}()
	MoneyRateDiv(money(usd(), 1000), 0, big.NewRat(3600, 1), "h")
}

// The rounding helper on its own, at the boundaries the money paths reach it with.
func TestRoundHalfEven(t *testing.T) {
	for _, want := range []struct {
		value    *big.Rat
		expected int64
	}{
		{big.NewRat(5, 2), 2},   // 2.5 → 2
		{big.NewRat(7, 2), 4},   // 3.5 → 4
		{big.NewRat(-5, 2), -2}, // -2.5 → -2
		{big.NewRat(-7, 2), -4},
		{big.NewRat(1, 3), 0},
		{big.NewRat(2, 3), 1},
		{big.NewRat(-2, 3), -1},
		{big.NewRat(4, 1), 4},
	} {
		if got := roundHalfEven(want.value).Int64(); got != want.expected {
			t.Fatalf("round(%s) = %d, want %d", want.value.RatString(), got, want.expected)
		}
	}
}

// The Money column sum: one pass, the currency adopted from the first matching row, and the
// two refusals Racket raises rather than an answer nobody can act on.
func TestTableSumMoney(t *testing.T) {
	table := NewTable[Money]()
	all := func(Money) bool { return true }
	itself := func(amount Money) Money { return amount }

	// An EMPTY set has no currency to carry its zero.
	func() {
		defer func() {
			recovered := recover()
			if recovered == nil {
				t.Fatal("an empty sum answered a total")
			}
			if !strings.Contains(fmt.Sprint(recovered), "empty row set") {
				t.Fatalf("the refusal reads %v", recovered)
			}
		}()
		TableSumMoney(table, all, itself, "Order", "price")
	}()

	TableInsert(table, "Order", money(usd(), 1000), func(Money, Money) bool { return false })
	TableInsert(table, "Order", money(usd(), 250), func(Money, Money) bool { return false })
	if got := minor(t, TableSumMoney(table, all, itself, "Order", "price")); got != 1250 {
		t.Fatalf("the total is %d", got)
	}

	// A MIXED set has no common total without a rate, and a rate is dated data a sum may not
	// invent.
	TableInsert(table, "Order", money(jpy(), 100), func(Money, Money) bool { return false })
	defer func() {
		recovered := recover()
		if recovered == nil {
			t.Fatal("USD and JPY were summed together")
		}
		if !strings.Contains(fmt.Sprint(recovered), "mixed currencies") {
			t.Fatalf("the refusal reads %v", recovered)
		}
	}()
	TableSumMoney(table, all, itself, "Order", "price")
}
