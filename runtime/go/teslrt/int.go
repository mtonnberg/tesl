// Package teslrt contains the small, audited runtime core used by emitted Tesl
// programs.
package teslrt

import (
	"errors"
	"hash/fnv"
	"math"
	"math/big"
)

var (
	ErrDivisionByZero = errors.New("teslrt.Int: division by zero")
	ErrNegativePower  = errors.New("teslrt.Int: negative exponent")
	ErrInvalidFloat   = errors.New("teslrt.Int: NaN and infinity are not integers")
	ErrInvalidInt     = errors.New("teslrt.Int: invalid decimal integer")
)

// Int is Tesl's arbitrary-precision integer. The zero value is zero.
//
// big is non-nil exactly when the value is outside the int64 range. noCompare
// makes raw == and map[Int] compile errors; callers must use Equal and Key.
type Int struct {
	noCompare [0]func()
	small     int64
	big       *big.Int
}

// IntKey is the canonical, comparable key for an Int.
type IntKey string

func FromInt64(value int64) Int {
	return Int{small: value}
}

// ParseDecimal parses an optional sign followed by one or more decimal digits.
func ParseDecimal(value string) (Int, error) {
	if !validDecimal(value, true) {
		return Int{}, ErrInvalidInt
	}
	n, ok := new(big.Int).SetString(value, 10)
	if !ok {
		return Int{}, ErrInvalidInt
	}
	return fromBig(n), nil
}

func MustParseDecimal(value string) Int {
	n, err := ParseDecimal(value)
	if err != nil {
		panic(err)
	}
	return n
}

// FromFloat64 truncates toward zero, matching Tesl's Int.fromFloat semantics.
func FromFloat64(value float64) (Int, error) {
	if math.IsNaN(value) || math.IsInf(value, 0) {
		return Int{}, ErrInvalidFloat
	}
	n, _ := big.NewFloat(value).Int(nil)
	return fromBig(n), nil
}

func fromBig(value *big.Int) Int {
	if value == nil {
		return Int{}
	}
	if value.IsInt64() {
		return FromInt64(value.Int64())
	}
	return Int{big: new(big.Int).Set(value)}
}

// bigInt always returns a new value. No operation may mutate an Int operand.
func (n Int) bigInt() *big.Int {
	_ = n.noCompare
	if n.big == nil {
		return big.NewInt(n.small)
	}
	return new(big.Int).Set(n.big)
}

func validDecimal(value string, allowPlus bool) bool {
	if value == "" {
		return false
	}
	start := 0
	if value[0] == '-' || (allowPlus && value[0] == '+') {
		start = 1
	}
	if start == len(value) {
		return false
	}
	for i := start; i < len(value); i++ {
		if value[i] < '0' || value[i] > '9' {
			return false
		}
	}
	return true
}

func Add(left, right Int) Int {
	if left.big == nil && right.big == nil {
		if (right.small > 0 && left.small <= math.MaxInt64-right.small) ||
			(right.small < 0 && left.small >= math.MinInt64-right.small) ||
			right.small == 0 {
			return FromInt64(left.small + right.small)
		}
	}
	return fromBig(new(big.Int).Add(left.bigInt(), right.bigInt()))
}

func Sub(left, right Int) Int {
	if left.big == nil && right.big == nil {
		if (right.small > 0 && left.small >= math.MinInt64+right.small) ||
			(right.small < 0 && left.small <= math.MaxInt64+right.small) ||
			right.small == 0 {
			return FromInt64(left.small - right.small)
		}
	}
	return fromBig(new(big.Int).Sub(left.bigInt(), right.bigInt()))
}

func Mul(left, right Int) Int {
	if left.big == nil && right.big == nil {
		if left.small == 0 || right.small == 0 {
			return Int{}
		}
		if (left.small != math.MinInt64 || right.small != -1) &&
			(right.small != math.MinInt64 || left.small != -1) {
			product := left.small * right.small
			if product/right.small == left.small {
				return FromInt64(product)
			}
		}
	}
	return fromBig(new(big.Int).Mul(left.bigInt(), right.bigInt()))
}

func Neg(value Int) Int {
	if value.big == nil && value.small != math.MinInt64 {
		return FromInt64(-value.small)
	}
	return fromBig(new(big.Int).Neg(value.bigInt()))
}

func Abs(value Int) Int {
	if value.Sign() >= 0 {
		return value
	}
	return Neg(value)
}

// Quo truncates toward zero.
func Quo(dividend, divisor Int) (Int, error) {
	if divisor.IsZero() {
		return Int{}, ErrDivisionByZero
	}
	if dividend.big == nil && divisor.big == nil &&
		(dividend.small != math.MinInt64 || divisor.small != -1) {
		return FromInt64(dividend.small / divisor.small), nil
	}
	return fromBig(new(big.Int).Quo(dividend.bigInt(), divisor.bigInt())), nil
}

// MustQuo is used by emitted code after Tesl has proved the divisor non-zero.
// It still fails closed if compiler/runtime invariants drift.
func MustQuo(dividend, divisor Int) Int {
	value, err := Quo(dividend, divisor)
	if err != nil {
		panic(err)
	}
	return value
}

// Rem is the truncating remainder. A non-zero result has the dividend's sign.
func Rem(dividend, divisor Int) (Int, error) {
	if divisor.IsZero() {
		return Int{}, ErrDivisionByZero
	}
	if dividend.big == nil && divisor.big == nil {
		return FromInt64(dividend.small % divisor.small), nil
	}
	return fromBig(new(big.Int).Rem(dividend.bigInt(), divisor.bigInt())), nil
}

func MustRem(dividend, divisor Int) Int {
	value, err := Rem(dividend, divisor)
	if err != nil {
		panic(err)
	}
	return value
}

// Mod matches Racket modulo: a non-zero result has the divisor's sign.
func Mod(dividend, divisor Int) (Int, error) {
	remainder, err := Rem(dividend, divisor)
	if err != nil || remainder.IsZero() || remainder.Sign() == divisor.Sign() {
		return remainder, err
	}
	return Add(remainder, divisor), nil
}

func MustMod(dividend, divisor Int) Int {
	value, err := Mod(dividend, divisor)
	if err != nil {
		panic(err)
	}
	return value
}

func Pow(base, exponent Int) (Int, error) {
	if exponent.Sign() < 0 {
		return Int{}, ErrNegativePower
	}
	return fromBig(new(big.Int).Exp(base.bigInt(), exponent.bigInt(), nil)), nil
}

func GCD(left, right Int) Int {
	return fromBig(new(big.Int).GCD(nil, nil, left.bigInt(), right.bigInt()))
}

func LCM(left, right Int) Int {
	if left.IsZero() || right.IsZero() {
		return Int{}
	}
	gcd := GCD(left, right)
	quotient, err := Quo(Abs(left), gcd)
	if err != nil {
		panic("unreachable: non-zero gcd")
	}
	return Mul(quotient, Abs(right))
}

func Min(left, right Int) Int {
	if Compare(left, right) <= 0 {
		return left
	}
	return right
}

func Max(left, right Int) Int {
	if Compare(left, right) >= 0 {
		return left
	}
	return right
}

func Clamp(value, low, high Int) Int {
	return Max(low, Min(high, value))
}

func Compare(left, right Int) int {
	if left.big == nil && right.big == nil {
		switch {
		case left.small < right.small:
			return -1
		case left.small > right.small:
			return 1
		default:
			return 0
		}
	}
	return left.bigInt().Cmp(right.bigInt())
}

func Equal(left, right Int) bool {
	return Compare(left, right) == 0
}

func (n Int) Sign() int {
	if n.big != nil {
		return n.big.Sign()
	}
	switch {
	case n.small < 0:
		return -1
	case n.small > 0:
		return 1
	default:
		return 0
	}
}

func (n Int) IsZero() bool {
	return n.big == nil && n.small == 0
}

func (n Int) IsPositive() bool {
	return n.Sign() > 0
}

func (n Int) IsNegative() bool {
	return n.Sign() < 0
}

func (n Int) IsEven() bool {
	if n.big == nil {
		return n.small%2 == 0
	}
	return n.big.Bit(0) == 0
}

func (n Int) IsOdd() bool {
	return !n.IsEven()
}

func (n Int) Digits() int {
	text := n.String()
	if text[0] == '-' {
		return len(text) - 1
	}
	return len(text)
}

func (n Int) String() string {
	if n.big == nil {
		return big.NewInt(n.small).String()
	}
	return n.big.String()
}

func (n Int) Int64() (int64, bool) {
	if n.big != nil {
		return 0, false
	}
	return n.small, true
}

func (n Int) Float64() float64 {
	if n.big == nil {
		return float64(n.small)
	}
	value, _ := new(big.Float).SetInt(n.big).Float64()
	return value
}

func (n Int) Key() IntKey {
	return IntKey(n.String())
}

func (n Int) Hash64() uint64 {
	hash := fnv.New64a()
	_, _ = hash.Write([]byte(n.String()))
	return hash.Sum64()
}

func (n Int) MarshalJSON() ([]byte, error) {
	return []byte(n.String()), nil
}

func (n *Int) UnmarshalJSON(data []byte) error {
	text := string(data)
	if !validJSONInteger(text) {
		return ErrInvalidInt
	}
	value, err := ParseDecimal(text)
	if err != nil {
		return err
	}
	*n = value
	return nil
}

func validJSONInteger(value string) bool {
	if !validDecimal(value, false) {
		return false
	}
	start := 0
	if value[0] == '-' {
		start = 1
	}
	if value[start] == '0' && len(value)-start > 1 {
		return false
	}
	return true
}

// IntNonZero and IntNonNegative are Tesl's `Int.nonZero` / `Int.nonNegative`
// checks: the proof they mint erases, the rejection does not. The messages and the
// 400 status are observable behavior and match the Racket implementations.
func IntNonZero(value Int) Check[Int] {
	if value.IsZero() {
		return Reject[Int](400, "expected a non-zero integer")
	}
	return Accept(value)
}

func IntNonNegative(value Int) Check[Int] {
	if value.Sign() < 0 {
		return Reject[Int](400, "expected a non-negative integer")
	}
	return Accept(value)
}

// The Tesl.Int leaves the emitter calls as plain functions. Clamp, Pow, IsEven and IsOdd
// already exist above; these are the wrappers for what is otherwise only a method, plus
// the sign and power shapes Tesl's own signatures describe.

// IntSign is -1, 0 or 1, matching Int.sign in tesl/int.rkt.
func IntSign(value Int) Int {
	return FromInt64(int64(value.Sign()))
}

func IntIsEven(value Int) bool {
	return value.IsEven()
}

func IntIsOdd(value Int) bool {
	return value.IsOdd()
}

func IntToString(value Int) string {
	return value.String()
}

// MustPow raises rather than returning an error, matching Int.pow in tesl/int.rkt, which
// rejects a negative exponent outright: there is no integer result, and Float.pow is the
// function for a fractional one.
func MustPow(base, exponent Int) Int {
	result, err := Pow(base, exponent)
	if err != nil {
		panic("Int.pow: " + err.Error())
	}
	return result
}
