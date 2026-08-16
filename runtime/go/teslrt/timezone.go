package teslrt

import (
	"strconv"
	"strings"
	"time"
	// The IANA database, compiled in. Without it `time.LoadLocation` reads the host's
	// /usr/share/zoneinfo, so the same program formats "Europe/Stockholm" correctly on a
	// developer's laptop and falls back to UTC inside a scratch container — a wrong TIME
	// rather than an error. A self-contained binary is the point of this backend, and a
	// timestamp that silently shifts by an hour is exactly the class of bug that is found
	// in production rather than in a test.
	_ "time/tzdata"
)

// formatTime and the calendar surface.
//
// The format string is Tesl's own strftime-like vocabulary, not Go's reference-layout one:
// the two backends have to render a timestamp identically, and `%Y-%m-%d` is what the
// source says. The directives are exactly those `tesl/time.rkt` implements — anything else
// passes through as itself, which is what its regexp does.

// FormatTime renders an instant in a named zone.
//
// The zone is a STRING here rather than the TimeZone value the truncation family takes,
// because that is the surface: `formatTime ts "UTC" "%Y-%m-%d"`. An empty name or "local"
// means the host's zone, matching Racket's `#f` case; an unknown name falls back to UTC
// rather than trapping, which is also what Racket does when `TZ` names a zone the host has
// never heard of.
func FormatTime(instant PosixMillis, zone, format string) string {
	millis, exact := instant.Value.Int64()
	if !exact {
		panic("formatTime: the instant does not fit in a 64-bit millisecond count")
	}
	moment := time.UnixMilli(millis).In(formatLocation(zone))
	return renderTimeFormat(moment, millis, format)
}

func formatLocation(zone string) *time.Location {
	switch zone {
	case "", "local":
		return time.Local
	case "UTC", "utc":
		return time.UTC
	}
	if location, err := time.LoadLocation(zone); err == nil {
		return location
	}
	return time.UTC
}

// renderTimeFormat walks the format once, expanding the directives Tesl defines and copying
// everything else through. `%3N` is milliseconds, and it is read from the ORIGINAL count
// rather than from the parsed moment so a negative instant keeps Racket's `remainder`
// semantics (the sign of the dividend).
func renderTimeFormat(moment time.Time, millis int64, format string) string {
	var rendered strings.Builder
	for index := 0; index < len(format); index++ {
		if format[index] != '%' || index+1 >= len(format) {
			rendered.WriteByte(format[index])
			continue
		}
		// `%3N` is the one two-character directive.
		if strings.HasPrefix(format[index+1:], "3N") {
			rendered.WriteString(zeroPad(int(millis%1000), 3))
			index += 2
			continue
		}
		switch format[index+1] {
		case 'Y':
			rendered.WriteString(zeroPad(moment.Year(), 4))
		case 'm':
			rendered.WriteString(zeroPad(int(moment.Month()), 2))
		case 'd':
			rendered.WriteString(zeroPad(moment.Day(), 2))
		case 'H':
			rendered.WriteString(zeroPad(moment.Hour(), 2))
		case 'M':
			rendered.WriteString(zeroPad(moment.Minute(), 2))
		case 'S':
			rendered.WriteString(zeroPad(moment.Second(), 2))
		case 'z':
			rendered.WriteString(utcOffsetText(moment))
		case 'Z':
			name, _ := moment.Zone()
			rendered.WriteString(name)
		case '%':
			rendered.WriteByte('%')
		default:
			// An unknown directive is copied through as it was written, which is what
			// Racket's regexp does with anything outside its alternation.
			rendered.WriteByte('%')
			rendered.WriteByte(format[index+1])
		}
		index++
	}
	return rendered.String()
}

func zeroPad(value, width int) string {
	text := strconv.Itoa(value)
	if len(text) >= width {
		return text
	}
	return strings.Repeat("0", width-len(text)) + text
}

func utcOffsetText(moment time.Time) string {
	_, offset := moment.Zone()
	sign := "+"
	if offset < 0 {
		sign = "-"
		offset = -offset
	}
	return sign + zeroPad(offset/3600, 2) + zeroPad((offset%3600)/60, 2)
}
