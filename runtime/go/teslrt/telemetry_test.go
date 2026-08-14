package teslrt

import (
	"strings"
	"testing"
)

func attributes(pairs ...string) []Tuple2[string, string] {
	out := []Tuple2[string, string]{}
	for index := 0; index+1 < len(pairs); index += 2 {
		out = append(out, Tuple2[string, string]{Tuple2First: pairs[index],
			Tuple2Second: pairs[index+1]})
	}
	return out
}

// A telemetry event records what it was given and does not disturb anything — which is the
// property every telemetry assertion in the corpus makes.
func TestTelemetryRecordsEvents(t *testing.T) {
	ResetTelemetry()
	t.Cleanup(ResetTelemetry)
	_ = Telemetry("request.process", attributes("user.id", "u-1", "count", "3"))
	events := TelemetryEvents()
	if len(events) != 1 {
		t.Fatalf("recorded %d events, want 1", len(events))
	}
	if events[0].Message != "request.process" {
		t.Fatalf("message = %q", events[0].Message)
	}
	if len(events[0].Attributes) != 2 || events[0].Attributes[0].Tuple2Second != "u-1" {
		t.Fatalf("attributes = %v", events[0].Attributes)
	}
	if events[0].TimestampMs <= 0 {
		t.Fatal("the event carries no timestamp")
	}
}

// A counter is CUMULATIVE per attribute set, and the set is order-insensitive: `{a,b}` and
// `{b,a}` are one series, or a dashboard would show two half-populated lines.
func TestCounterIsCumulativePerAttributeSet(t *testing.T) {
	ResetTelemetry()
	t.Cleanup(ResetTelemetry)
	_ = Counter("signups", FromInt64(1), attributes("plan", "pro"))
	_ = Counter("signups", FromInt64(2), attributes("plan", "pro"))
	_ = Counter("signups", FromInt64(5), attributes("plan", "free"))
	_ = Counter("signups", FromInt64(1), attributes("b", "2", "a", "1"))
	_ = Counter("signups", FromInt64(1), attributes("a", "1", "b", "2"))

	series := MetricSeriesSnapshot()
	sums := map[string]float64{}
	for _, one := range series {
		key := ""
		for _, attribute := range one.Attributes {
			key += attribute.Tuple2First + "=" + attribute.Tuple2Second + ";"
		}
		sums[key] = one.Sum
	}
	if sums["plan=pro;"] != 3 {
		t.Fatalf("pro sum = %v, want 3 (cumulative)", sums["plan=pro;"])
	}
	if sums["plan=free;"] != 5 {
		t.Fatalf("free sum = %v", sums["plan=free;"])
	}
	// The two orderings landed in ONE series, whichever spelling names it.
	reordered := sums["b=2;a=1;"] + sums["a=1;b=2;"]
	if reordered != 2 {
		t.Fatalf("reordered attributes made %v, want one series summing to 2", reordered)
	}
}

func TestHistogramAndGaugeKeepDifferentShapes(t *testing.T) {
	ResetTelemetry()
	t.Cleanup(ResetTelemetry)
	_ = Histogram("latency", 10, attributes())
	_ = Histogram("latency", 30, attributes())
	_ = Gauge("queue.depth", 7, attributes())
	_ = Gauge("queue.depth", 2, attributes())

	for _, series := range MetricSeriesSnapshot() {
		switch series.Name {
		case "latency":
			// A distribution: count, sum and range — not the last value.
			if series.Count != 2 || series.Sum != 40 || series.Min != 10 || series.Max != 30 {
				t.Fatalf("histogram = %+v", series)
			}
		case "queue.depth":
			// A gauge is the LAST value: a depth of 2 replaces a depth of 7 rather than adding.
			if series.Last != 2 {
				t.Fatalf("gauge last = %v, want 2", series.Last)
			}
		}
	}
}

// Metrics can be turned off, and then nothing is recorded — the cheapest possible path for a
// program that configured `metrics False`.
func TestMetricsCanBeDisabled(t *testing.T) {
	ResetTelemetry()
	t.Cleanup(func() { _ = InitTelemetry("tesl", "in-memory", false, true, false, 60000, 1.0) })
	_ = InitTelemetry("bench", "in-memory", false, false, false, 60000, 1.0)
	_ = Counter("ignored", FromInt64(1), attributes())
	if series := MetricSeriesSnapshot(); len(series) != 0 {
		t.Fatalf("recorded %d series with metrics disabled", len(series))
	}
}

// A configured OTLP endpoint says so ONCE rather than silently dropping every signal.
func TestConfiguredEndpointIsAnnounced(t *testing.T) {
	ResetTelemetry()
	t.Cleanup(func() { _ = InitTelemetry("tesl", "in-memory", false, true, false, 60000, 1.0) })
	_ = InitTelemetry("bench", "https://collector.example/v1/logs", false, true, false, 60000, 1.0)
	// The announcement goes to stderr; what is asserted here is that the configuration took and
	// the signal still records in process.
	_ = Telemetry("still.recorded", attributes())
	events := TelemetryEvents()
	if len(events) != 1 || !strings.Contains(events[0].Endpoint, "collector.example") {
		t.Fatalf("events = %+v", events)
	}
}
