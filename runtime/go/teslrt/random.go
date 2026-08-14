package teslrt

import (
	"crypto/rand"
	"encoding/hex"
	"math/big"
)

// Randomness is an effect Tesl gates behind the `random` capability, which the checker
// enforces; nothing about that survives to run time.
//
// The source is crypto/rand rather than math/rand: a Tesl program cannot seed a generator
// (there is no such surface), so a predictable stream would be a security property nobody
// asked for, and gosec flags math/rand for exactly that reason.

// RandomInt is `randomInt lo hi`: a uniform draw from [lo, hi). The caller proves lo < hi —
// the range is a compile-time obligation on the inputs — so an empty range is a trap rather
// than a silent lo.
func RandomInt(low, high Int) Int {
	span := Sub(high, low)
	if Compare(span, FromInt64(1)) < 0 {
		panic("randomInt: the range is empty (high must be greater than low)")
	}
	offset, err := rand.Int(rand.Reader, span.bigInt())
	if err != nil {
		panic("randomInt: no randomness available: " + err.Error())
	}
	return Add(low, fromBig(offset))
}

// RandomFloat is `randomFloat()`: a uniform draw from [0, 1), a fresh value per call.
//
// It is built from 53 random bits divided by 2^53 — the number of bits a float64 can hold
// exactly — so every representable value in the range is reachable and none is favoured.
func RandomFloat() float64 {
	const bits = 1 << 53
	drawn, err := rand.Int(rand.Reader, big.NewInt(bits))
	if err != nil {
		panic("randomFloat: no randomness available: " + err.Error())
	}
	return float64(drawn.Int64()) / float64(bits)
}

// GeneratePrefixedId is `generatePrefixedId prefix`: `<prefix>-<32 hex chars>`, 16 CSPRNG
// bytes rendered as hex, matching `tesl-generate-prefixed-id`. An id is often used as a
// token, so it must be unguessable — the shape (prefix, dash, 32 hex digits) is part of the
// contract, since ids land in URLs and databases.
func GeneratePrefixedId(prefix string) string {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		panic("generateId: no randomness available: " + err.Error())
	}
	return prefix + "-" + hex.EncodeToString(raw)
}

// GenerateId is `generateId()`: the same value with an empty prefix, so it still begins
// with the dash — parity with Racket, which appends the separator unconditionally.
func GenerateId() string {
	return GeneratePrefixedId("")
}
