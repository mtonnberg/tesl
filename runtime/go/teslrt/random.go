package teslrt

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"math/big"
	"time"
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

// UUIDv7 is a time-ordered UUID: 48 bits of Unix milliseconds, then random bits, with the
// version and variant nibbles set (RFC 9562). The layout matches `uuid-v7-string` in
// tesl/private/uuid-gen.rkt byte for byte, so an id generated on either backend sorts and
// parses the same way.
//
// Time-ordered matters for the queue: a job id that is monotonic makes "oldest first"
// recoverable from the id alone, and a v4 id would not.
func UUIDv7() string {
	milliseconds := time.Now().UnixMilli()
	raw := make([]byte, 16)
	if _, err := rand.Read(raw[6:]); err != nil {
		panic("UUID.v7: no randomness available: " + err.Error())
	}
	// Masked, not just shifted: the truncation to a byte is the POINT (a 48-bit timestamp
	// spread over six bytes), and gosec's integer-overflow check is right to ask that it be
	// written explicitly rather than left to conversion.
	stamp := uint64(milliseconds)
	raw[0] = byte((stamp >> 40) & 0xff)
	raw[1] = byte((stamp >> 32) & 0xff)
	raw[2] = byte((stamp >> 24) & 0xff)
	raw[3] = byte((stamp >> 16) & 0xff)
	raw[4] = byte((stamp >> 8) & 0xff)
	raw[5] = byte(stamp & 0xff)
	raw[6] = 0x70 | (raw[6] & 0x0f)
	raw[8] = 0x80 | (raw[8] & 0x3f)
	return fmt.Sprintf("%x-%x-%x-%x-%x", raw[0:4], raw[4:6], raw[6:8], raw[8:10], raw[10:16])
}

// UUIDv4 is a RANDOM UUID: 122 random bits with the version and variant nibbles set
// (RFC 9562), the same layout `uuid-v4-string` writes in tesl/private/uuid-gen.rkt.
//
// Randomness comes from crypto/rand, not math/rand, for the reason every id in this file
// does: a UUID is routinely used as an unguessable handle, and a predictable one is a
// vulnerability rather than a collision.
func UUIDv4() string {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		panic("UUID.v4: no randomness available: " + err.Error())
	}
	raw[6] = 0x40 | (raw[6] & 0x0f)
	raw[8] = 0x80 | (raw[8] & 0x3f)
	return fmt.Sprintf("%x-%x-%x-%x-%x", raw[0:4], raw[4:6], raw[6:8], raw[8:10], raw[10:16])
}

// ValidUUID reports the 8-4-4-4-12 hex shape, in either case — the same set
// `uuid-regexp` accepts in tesl/uuid.rkt. It is written as a scan rather than as a regular
// expression so the runtime carries no regexp engine for one shape.
func ValidUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index := 0; index < len(value); index++ {
		character := value[index]
		switch index {
		case 8, 13, 18, 23:
			if character != '-' {
				return false
			}
		default:
			isDigit := character >= '0' && character <= '9'
			isLower := character >= 'a' && character <= 'f'
			isUpper := character >= 'A' && character <= 'F'
			if !isDigit && !isLower && !isUpper {
				return false
			}
		}
	}
	return true
}

// UUIDValidate is `UUID.validate`: a CHECK, so an invalid string is a 400 the request
// answers with rather than a trap. The proof it mints (`IsUuid`) erases, so what survives
// is the string it verified.
func UUIDValidate(value string) Check[string] {
	if !ValidUUID(value) {
		return Reject[string](400, "not a valid UUID")
	}
	return Accept(value)
}
