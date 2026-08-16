package teslrt

import (
	"strconv"
	"sync"
	"time"
)

// Calendar truncation, and the `TimeZone` value the buckets are taken in.
//
// A rule-for-rule port of `dsl/private/time-trunc.rkt`, which is deliberately dependency-free
// there for the same reason it is self-contained here: THREE consumers have to agree about
// where a bucket starts — the `Tesl.Time` surface functions, the query DSL's Memory backend,
// and the PostgreSQL expressions the emitter generates — and they agree by calling one
// engine rather than by three implementations happening to match.
//
// All arithmetic is exact integer arithmetic with FLOOR division, which is what makes a
// pre-1970 instant bucket correctly; Go's `/` truncates toward zero, so it is never used on
// a value that can be negative. Month and year truncation go through Howard Hinnant's
// public-domain civil_from_days / days_from_civil. A week is the ISO week (Monday start).
// Proleptic Gregorian, no leap seconds — the civil calendar, like elm/time.

const (
	msPerHour = 3600000
	msPerDay  = 86400000
	msPerWeek = 604800000
)

// TimeZone is Tesl's `TimeZone`: UTC, a fixed offset in minutes east of UTC, or one of the
// baked IANA zones. It carries the zone NAME rather than a `*time.Location`, so it stays
// comparable — two values are the same zone when they name the same zone — and so its ZERO
// value is UTC rather than a nil pointer waiting to be dereferenced.
type TimeZone struct {
	Name          string
	OffsetMinutes int
	Fixed         bool
}

// UtcZone is `Utc`.
func UtcZone() TimeZone { return TimeZone{} }

// FixedOffsetZone is `FixedOffset minutes` — minutes EAST of UTC, so Stockholm in winter is
// 60 and New York in winter is -300. A fixed offset is not a zone: it does not know about
// summer time, which is exactly why it is a separate constructor.
func FixedOffsetZone(minutes Int) TimeZone {
	value, exact := minutes.Int64()
	if !exact {
		panic("FixedOffset: the offset does not fit in a minute count")
	}
	return TimeZone{OffsetMinutes: int(value), Fixed: true}
}

var (
	zoneCacheMutex sync.Mutex
	zoneCache      = map[string]*time.Location{}
)

// NamedZone is one of the baked IANA zones. The name comes from the compiler's zone
// catalogue (`compiler/lib/tz_zones.ml`), so it is one of a fixed set rather than a string a
// program composed — there is no zone-name typo to make at run time. The database is
// compiled into the binary (see timezone.go), so a lookup cannot fail for a host that has no
// /usr/share/zoneinfo; it panics rather than falling back to UTC if it ever does, because a
// timestamp that silently shifts by an hour is the bug this whole module exists to prevent.
func NamedZone(name string) TimeZone {
	if _, err := zoneLocation(name); err != nil {
		panic("TimeZone: " + name + " is not in the embedded zone database: " + err.Error())
	}
	return TimeZone{Name: name}
}

func zoneLocation(name string) (*time.Location, error) {
	zoneCacheMutex.Lock()
	cached, found := zoneCache[name]
	zoneCacheMutex.Unlock()
	if found {
		return cached, nil
	}
	location, err := time.LoadLocation(name)
	if err != nil {
		return nil, err
	}
	zoneCacheMutex.Lock()
	zoneCache[name] = location
	zoneCacheMutex.Unlock()
	return location, nil
}

// TzOffsetMinutes is the offset of a zone AT AN INSTANT, in minutes east of UTC. Per
// instant, not per zone: a named zone is DST-correct without the program tracking summer and
// winter time, which is the whole reason a `TimeZone` is not an offset.
func TzOffsetMinutes(zone TimeZone, millis int64) int {
	switch {
	case zone.Fixed:
		return zone.OffsetMinutes
	case zone.Name == "":
		return 0
	default:
		location, err := zoneLocation(zone.Name)
		if err != nil {
			panic("TimeZone: " + zone.Name + " is not in the embedded zone database")
		}
		_, offsetSeconds := time.UnixMilli(millis).In(location).Zone()
		// Floor rather than truncate: an offset is a whole number of minutes in practice,
		// but several zones carried a sub-minute offset before 1900.
		return int(floorDiv(int64(offsetSeconds), 60))
	}
}

// TimeOffsetAt is the `Time.offsetAt` surface: the zone's offset at an instant, in minutes.
func TimeOffsetAt(zone TimeZone, at PosixMillis) Int {
	return FromInt64(int64(TzOffsetMinutes(zone, posixInt64(at, "Time.offsetAt"))))
}

// TimeTrunc answers the BUCKET-START instant for the wall clock in a zone.
//
// A named zone follows PostgreSQL's two-step semantics exactly — the parity suite is the
// oracle: the instant becomes a local wall clock at the offset AT THAT INSTANT, the wall
// clock is truncated on the civil calendar, and the local bucket start becomes an instant
// again using the offset AT THE BUCKET START, re-resolved with one fixup iteration. That
// last step is what makes a bucket that straddles a DST transition still start at the true
// local midnight rather than an hour either side of it.
func TimeTrunc(unit string, zone TimeZone, at PosixMillis) PosixMillis {
	millis := posixInt64(at, "Time.trunc"+unit)
	first := TzOffsetMinutes(zone, millis)
	localStart := localTrunc(unit, millis+int64(first)*60000)
	named := !zone.Fixed && zone.Name != ""
	if !named {
		return PosixMillis{Value: FromInt64(localStart - int64(first)*60000)}
	}
	candidate := localStart - int64(first)*60000
	second := TzOffsetMinutes(zone, candidate)
	third := TzOffsetMinutes(zone, localStart-int64(second)*60000)
	return PosixMillis{Value: FromInt64(localStart - int64(third)*60000)}
}

func posixInt64(at PosixMillis, who string) int64 {
	millis, exact := at.Value.Int64()
	if !exact {
		panic(who + ": the instant does not fit in a 64-bit millisecond count")
	}
	return millis
}

// localTrunc truncates a LOCAL wall-clock millisecond count.
func localTrunc(unit string, local int64) int64 {
	switch unit {
	case "Hour":
		return floorTo(local, msPerHour)
	case "Day":
		return floorTo(local, msPerDay)
	case "Week":
		// The ISO week starts on Monday, and epoch day 0 (1970-01-01) is a Thursday, so
		// shifting by three days aligns Monday to a multiple of a week.
		return floorTo(local+3*msPerDay, msPerWeek) - 3*msPerDay
	case "Month":
		year, month, _ := civilFromDays(floorDiv(local, msPerDay))
		return daysFromCivil(year, month, 1) * msPerDay
	case "Year":
		year, _, _ := civilFromDays(floorDiv(local, msPerDay))
		return daysFromCivil(year, 1, 1) * msPerDay
	default:
		panic("Time.trunc: unknown unit " + strconv.Quote(unit))
	}
}

// floorDiv is division that rounds toward NEGATIVE INFINITY, which Go's `/` does not do. The
// difference is only visible before 1970, which is exactly where a truncating division puts
// an instant in the wrong bucket.
func floorDiv(value, by int64) int64 {
	quotient := value / by
	if value%by != 0 && (value < 0) != (by < 0) {
		quotient--
	}
	return quotient
}

func floorTo(value, unit int64) int64 { return floorDiv(value, unit) * unit }

// civilFromDays is Hinnant's civil_from_days: a day count since 1970-01-01 to a civil date.
func civilFromDays(days int64) (int64, int64, int64) {
	shifted := days + 719468
	era := floorDiv(shifted, 146097)
	dayOfEra := shifted - era*146097
	yearOfEra := (dayOfEra - dayOfEra/1460 + dayOfEra/36524 - dayOfEra/146096) / 365
	year := yearOfEra + era*400
	dayOfYear := dayOfEra - (365*yearOfEra + yearOfEra/4 - yearOfEra/100)
	monthPrime := (5*dayOfYear + 2) / 153
	day := dayOfYear - (153*monthPrime+2)/5 + 1
	month := monthPrime + 3
	if monthPrime >= 10 {
		month = monthPrime - 9
	}
	if month <= 2 {
		year++
	}
	return year, month, day
}

// daysFromCivil is Hinnant's days_from_civil: a civil date to a day count since 1970-01-01.
func daysFromCivil(year, month, day int64) int64 {
	shiftedYear := year
	if month <= 2 {
		shiftedYear--
	}
	era := floorDiv(shiftedYear, 400)
	yearOfEra := shiftedYear - era*400
	monthPrime := month - 3
	if month <= 2 {
		monthPrime = month + 9
	}
	dayOfYear := (153*monthPrime+2)/5 + day - 1
	dayOfEra := yearOfEra*365 + yearOfEra/4 - yearOfEra/100 + dayOfYear
	return era*146097 + dayOfEra - 719468
}

// The five surface functions. Each is one call rather than a `unit` string at the call
// site, so a typo is a Go compile error rather than a run-time panic — the emitter picks
// the wrapper from the Tesl name it already resolved.
func TimeTruncHour(zone TimeZone, at PosixMillis) PosixMillis {
	return TimeTrunc("Hour", zone, at)
}

func TimeTruncDay(zone TimeZone, at PosixMillis) PosixMillis {
	return TimeTrunc("Day", zone, at)
}

func TimeTruncWeek(zone TimeZone, at PosixMillis) PosixMillis {
	return TimeTrunc("Week", zone, at)
}

func TimeTruncMonth(zone TimeZone, at PosixMillis) PosixMillis {
	return TimeTrunc("Month", zone, at)
}

func TimeTruncYear(zone TimeZone, at PosixMillis) PosixMillis {
	return TimeTrunc("Year", zone, at)
}
