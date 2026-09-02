package teslrt

import (
	"testing"
	"time"
)

func at(seconds int64) PosixMillis {
	return PosixMillis{Value: FromInt64(seconds * 1000)}
}

func TestFormatTimeRendersISOInUTC(t *testing.T) {
	cases := []struct {
		seconds int64
		want    string
	}{
		{1699999999, "2023-11-14T22:13:19Z"},
		{0, "1970-01-01T00:00:00Z"},
		// Before the epoch, where a truncating division and a flooring one disagree.
		{-1, "1969-12-31T23:59:59Z"},
	}
	for _, testCase := range cases {
		got := FormatTime(at(testCase.seconds), "UTC", "%Y-%m-%dT%H:%M:%SZ")
		if got != testCase.want {
			t.Fatalf("FormatTime(%d) = %q, want %q", testCase.seconds, got, testCase.want)
		}
	}
}

// The IANA database is compiled in, so a named zone resolves the same wherever the binary
// runs — including a container with no /usr/share/zoneinfo, which is where the host-lookup
// version silently falls back to UTC.
func TestFormatTimeResolvesNamedZones(t *testing.T) {
	cases := map[string]string{
		"Europe/Stockholm": "2023-11-14 23:13:19",
		"America/New_York": "2023-11-14 17:13:19",
		"Asia/Tokyo":       "2023-11-15 07:13:19",
		"UTC":              "2023-11-14 22:13:19",
	}
	for zone, want := range cases {
		if got := FormatTime(at(1699999999), zone, "%Y-%m-%d %H:%M:%S"); got != want {
			t.Fatalf("FormatTime in %s = %q, want %q", zone, got, want)
		}
	}
}

// Summer time is a property of the INSTANT, not of the zone: the same zone answers a
// different offset in July and in November.
func TestFormatTimeOffsetFollowsDaylightSaving(t *testing.T) {
	if got := FormatTime(at(1699999999), "Europe/Stockholm", "%z"); got != "+0100" {
		t.Fatalf("November offset = %q, want +0100", got)
	}
	if got := FormatTime(at(1689999999), "Europe/Stockholm", "%z"); got != "+0200" {
		t.Fatalf("July offset = %q, want +0200", got)
	}
	if got := FormatTime(at(1699999999), "UTC", "%z"); got != "+0000" {
		t.Fatalf("UTC offset = %q, want +0000", got)
	}
	// A zone west of Greenwich signs the offset, and the minutes are not always zero.
	if got := FormatTime(at(1699999999), "Asia/Kolkata", "%z"); got != "+0530" {
		t.Fatalf("Kolkata offset = %q, want +0530", got)
	}
	if got := FormatTime(at(1699999999), "America/New_York", "%z"); got != "-0500" {
		t.Fatalf("New York offset = %q, want -0500", got)
	}
}

func TestFormatTimeZoneAbbreviation(t *testing.T) {
	if got := FormatTime(at(1699999999), "UTC", "%Z"); got != "UTC" {
		t.Fatalf("UTC abbreviation = %q", got)
	}
	if got := FormatTime(at(1699999999), "Europe/Stockholm", "%Z"); got != "CET" {
		t.Fatalf("Stockholm abbreviation = %q, want CET", got)
	}
}

// The millis come from the instant rather than from the parsed calendar, so a value that
// is not a whole second keeps its fraction.
func TestFormatTimeMilliseconds(t *testing.T) {
	instant := PosixMillis{Value: FromInt64(1699999999250)}
	if got := FormatTime(instant, "UTC", "%H:%M:%S.%3N"); got != "22:13:19.250" {
		t.Fatalf("with millis = %q", got)
	}
	if got := FormatTime(at(1699999999), "UTC", "%3N"); got != "000" {
		t.Fatalf("without millis = %q", got)
	}
}

// Everything outside the directive set is copied through, including an unknown directive:
// that is what the Racket implementation's regexp does, and a format string is user text.
func TestFormatTimePassesThroughEverythingElse(t *testing.T) {
	cases := map[string]string{
		"100%% sure":         "100% sure",
		"%Q":                 "%Q",
		"no directives here": "no directives here",
		"":                   "",
		// A trailing lone `%` has no directive after it and stays as it is.
		"ends with %": "ends with %",
	}
	for format, want := range cases {
		if got := FormatTime(at(0), "UTC", format); got != want {
			t.Fatalf("FormatTime(%q) = %q, want %q", format, got, want)
		}
	}
}

// An unknown zone is UTC rather than a trap. A format call is a display path, and a name
// that is not in the database is a configuration mistake the operator should see in the
// output rather than as a crashed request.
func TestFormatTimeUnknownZoneFallsBackToUTC(t *testing.T) {
	if got := FormatTime(at(1699999999), "Mars/Olympus_Mons", "%Y-%m-%dT%H:%M:%SZ"); got !=
		"2023-11-14T22:13:19Z" {
		t.Fatalf("unknown zone = %q", got)
	}
}

// The empty name and "local" mean the host's zone, matching Racket's `#f` case.
func TestFormatTimeLocalZone(t *testing.T) {
	want := time.UnixMilli(1699999999000).In(time.Local).Format("2006-01-02 15:04:05")
	for _, zone := range []string{"", "local"} {
		if got := FormatTime(at(1699999999), zone, "%Y-%m-%d %H:%M:%S"); got != want {
			t.Fatalf("zone %q = %q, want the host's %q", zone, got, want)
		}
	}
}
