package teslrt

import "testing"

func instant(millis int64) PosixMillis { return PosixMillis{Value: FromInt64(millis)} }

func truncAt(t *testing.T, unit string, zone TimeZone, millis int64) int64 {
	t.Helper()
	got, exact := TimeTrunc(unit, zone, instant(millis)).Value.Int64()
	if !exact {
		t.Fatalf("%s bucket does not fit in an int64", unit)
	}
	return got
}

// 2026-03-01T10:00:00Z, the instant the corpus seeds with.
const march1 = 1772359200000

func TestTruncUtcBuckets(t *testing.T) {
	utc := UtcZone()
	cases := []struct {
		unit string
		want int64
	}{
		{"Hour", 1772359200000},  // 2026-03-01T10:00:00Z, already on the hour
		{"Day", 1772323200000},   // 2026-03-01T00:00:00Z
		{"Week", 1771804800000},  // 2026-03-01 is a Sunday; its ISO week starts Monday 2026-02-23
		{"Month", 1772323200000}, // 2026-03-01T00:00:00Z
		{"Year", 1767225600000},  // 2026-01-01T00:00:00Z
	}
	for _, one := range cases {
		if got := truncAt(t, one.unit, utc, march1); got != one.want {
			t.Errorf("%s: got %d, want %d", one.unit, got, one.want)
		}
	}
}

// The week bucket must be a MONDAY in every case, which is the property the
// three-day epoch shift exists to give.
func TestTruncWeekLandsOnMonday(t *testing.T) {
	utc := UtcZone()
	for day := int64(-800); day < 800; day++ {
		start := truncAt(t, "Week", utc, day*msPerDay+13*msPerHour)
		// Epoch day 0 is a Thursday, so a Monday is 4 days later modulo 7.
		if days := floorDiv(start, msPerDay); floorDiv(days-4, 7)*7+4 != days {
			t.Fatalf("week bucket for day %d is not a Monday (%d)", day, days)
		}
		if start%msPerDay != 0 {
			t.Fatalf("week bucket for day %d is not midnight", day)
		}
	}
}

// Before 1970 the arithmetic is where a truncating division puts an instant in the
// wrong bucket: -1 ms is 1969-12-31, not 1970-01-01.
func TestTruncBeforeTheEpochFloors(t *testing.T) {
	utc := UtcZone()
	if got := truncAt(t, "Day", utc, -1); got != -msPerDay {
		t.Errorf("day before the epoch: got %d, want %d", got, -msPerDay)
	}
	if got := truncAt(t, "Year", utc, -1); got != -365*msPerDay {
		t.Errorf("year before the epoch: got %d, want %d", got, -365*msPerDay)
	}
	// 1969-07-20T20:17:00Z, the Apollo 11 landing: the month bucket is 1969-07-01.
	landing := int64(-14182980000)
	want := int64(-15897600000) // 1969-07-01T00:00:00Z
	if got := truncAt(t, "Month", utc, landing); got != want {
		t.Errorf("month before the epoch: got %d, want %d", got, want)
	}
}

// A fixed offset does not know about summer time — that is why it is its own
// constructor — so its buckets shift by exactly the offset, always.
func TestTruncFixedOffset(t *testing.T) {
	plusOne := FixedOffsetZone(FromInt64(60))
	// 2026-03-01T00:00:00+01:00 is 2026-02-28T23:00:00Z.
	if got := truncAt(t, "Day", plusOne, march1); got != 1772319600000 {
		t.Errorf("fixed +60 day bucket: got %d, want %d", got, 1772319600000)
	}
	minusFive := FixedOffsetZone(FromInt64(-300))
	// 2026-03-01T00:00:00-05:00 is 2026-03-01T05:00:00Z.
	if got := truncAt(t, "Day", minusFive, march1); got != 1772341200000 {
		t.Errorf("fixed -300 day bucket: got %d, want %d", got, 1772341200000)
	}
}

// A named zone resolves its offset PER INSTANT, so the same zone value buckets
// correctly on both sides of a DST transition — and the bucket that STRADDLES the
// transition still starts at the true local midnight, which is the whole reason the
// offset is re-resolved at the candidate.
func TestTruncNamedZoneAcrossDst(t *testing.T) {
	stockholm := NamedZone("Europe/Stockholm")
	// Winter: 2026-01-15T12:00:00Z, local midnight is 2026-01-14T23:00:00Z (UTC+1).
	if got := truncAt(t, "Day", stockholm, 1768478400000); got != 1768431600000 {
		t.Errorf("winter day bucket: got %d, want %d", got, 1768431600000)
	}
	// Summer: 2026-07-15T12:00:00Z, local midnight is 2026-07-14T22:00:00Z (UTC+2).
	if got := truncAt(t, "Day", stockholm, 1784116800000); got != 1784066400000 {
		t.Errorf("summer day bucket: got %d, want %d", got, 1784066400000)
	}
	// The spring-forward day itself: 2026-03-29, clocks go +1 at 02:00 local. An
	// instant that afternoon still buckets to 2026-03-28T23:00:00Z, local midnight.
	afternoon := int64(1774792800000) // 2026-03-29T14:00:00Z
	if got := truncAt(t, "Day", stockholm, afternoon); got != 1774738800000 {
		t.Errorf("spring-forward day bucket: got %d, want %d", got, 1774738800000)
	}
}

func TestZoneOffsetIsPerInstant(t *testing.T) {
	stockholm := NamedZone("Europe/Stockholm")
	winter, _ := TimeOffsetAt(stockholm, instant(1768478400000)).Int64()
	summer, _ := TimeOffsetAt(stockholm, instant(1784116800000)).Int64()
	if winter != 60 || summer != 120 {
		t.Errorf("Stockholm offsets: winter %d, summer %d; want 60 and 120", winter, summer)
	}
	utc, _ := TimeOffsetAt(UtcZone(), instant(march1)).Int64()
	if utc != 0 {
		t.Errorf("UTC offset: got %d, want 0", utc)
	}
	fixed, _ := TimeOffsetAt(FixedOffsetZone(FromInt64(-330)), instant(march1)).Int64()
	if fixed != -330 {
		t.Errorf("fixed offset: got %d, want -330", fixed)
	}
}

// The zero value is UTC rather than a nil location, so a TimeZone that was never
// constructed still answers rather than panicking.
func TestZeroZoneIsUtc(t *testing.T) {
	var zone TimeZone
	if got := TzOffsetMinutes(zone, march1); got != 0 {
		t.Errorf("zero zone offset: got %d, want 0", got)
	}
}

func TestCivilRoundTrip(t *testing.T) {
	for day := int64(-100000); day < 100000; day += 37 {
		year, month, dayOfMonth := civilFromDays(day)
		if back := daysFromCivil(year, month, dayOfMonth); back != day {
			t.Fatalf("day %d round-tripped to %d (%d-%d-%d)", day, back, year, month, dayOfMonth)
		}
	}
}
