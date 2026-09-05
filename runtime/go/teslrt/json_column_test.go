package teslrt

import (
	"strconv"
	"testing"

	"github.com/jackc/pgx/v5/pgtype"
)

// Exercise pgx's real scan plans in both wire formats. A **[]byte carrier
// collapses JSON null into SQL NULL; a []byte must preserve the distinction.
func TestNullableJSONColumnPreservesSQLNullAndJSONNull(t *testing.T) {
	for _, oid := range []uint32{pgtype.JSONOID, pgtype.JSONBOID} {
		for _, format := range []int16{pgtype.TextFormatCode, pgtype.BinaryFormatCode} {
			t.Run(strconv.Itoa(int(oid))+"/"+strconv.Itoa(int(format)), func(t *testing.T) {
				var carrier []byte
				plan := pgtype.NewMap().PlanScan(oid, format, &carrier)
				if plan == nil {
					t.Fatal("JSON scan plan missing")
				}
				for _, raw := range [][]byte{[]byte(`{"text":"kept"}`), nil, []byte(`null`), []byte(` null `)} {
					wire := raw
					if raw != nil && oid == pgtype.JSONBOID && format == pgtype.BinaryFormatCode {
						wire = append([]byte{1}, raw...)
					}
					if err := plan.Scan(wire, &carrier); err != nil {
						t.Fatal(err)
					}
					calls := 0
					value := MaybeOfJSONColumn(carrier, func(data []byte) string {
						calls++
						return string(data)
					})
					got, present := value.Value()
					if raw == nil {
						if present || calls != 0 {
							t.Fatal("SQL NULL was decoded")
						}
					} else if !present || calls != 1 || got != string(raw) {
						t.Fatalf("JSON bytes bypassed decoder: %q -> %q, present=%v, calls=%d", raw, got, present, calls)
					}
				}
			})
		}
	}
}

func TestRecordColumnCheckedDecodeAndLegacyWrapping(t *testing.T) {
	decode := func(raw any) Check[Int] {
		n, err := DecodeIntField(raw, "n")
		if err != nil {
			return RejectShape[Int](err.Error())
		}
		if n.Sign() <= 0 {
			return Reject[Int](422, "not positive")
		}
		return Accept(n)
	}
	const good = `{"n":123456789012345678901234567890}`
	for _, raw := range []string{good, strconv.Quote(good)} {
		if got := MustDecodeColumnJSON([]byte(raw), decode); got.String() != "123456789012345678901234567890" {
			t.Fatalf("lost precision: %s", got)
		}
	}
	for _, raw := range []string{
		`null`, `[]`, `{}`, `{"n":0}`, `{"n":-1}`, `{"n":1.5}`, `{"n":"3"}`,
		`{"n":`, good + ` {}`, strconv.Quote(strconv.Quote(good)),
	} {
		t.Run(raw, func(t *testing.T) {
			mustPanic(t, "record column", func() { MustDecodeColumnJSON([]byte(raw), decode) })
		})
	}
}
