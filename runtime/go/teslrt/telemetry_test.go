package teslrt

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
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

func TestOTLPExporterPostsMetricsAndTraces(t *testing.T) {
	requests := make(chan struct {
		path string
		body map[string]any
	}, 10)
	collector := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Errorf("decode OTLP payload: %v", err)
			return
		}
		requests <- struct {
			path string
			body map[string]any
		}{request.URL.Path, body}
		writer.WriteHeader(http.StatusOK)
	}))
	defer collector.Close()
	_ = InitTelemetry("otlp-test", collector.URL, false, true, true, 5, 1.0)
	t.Cleanup(func() { _ = InitTelemetry("tesl", "in-memory", false, true, false, 60000, 1.0) })
	_ = Counter("requests", FromInt64(3), attributes("route", "/"))
	_ = Telemetry("request.finished", attributes("route", "/"))

	seen := map[string]map[string]any{}
	deadline := time.After(2 * time.Second)
	for len(seen) < 2 {
		select {
		case request := <-requests:
			seen[request.path] = request.body
		case <-deadline:
			t.Fatalf("received OTLP paths %v, want metrics and traces", seen)
		}
	}
	if _, ok := seen["/v1/metrics"]; !ok {
		t.Fatalf("metrics payload missing: %v", seen)
	}
	if _, ok := seen["/v1/traces"]; !ok {
		t.Fatalf("traces payload missing: %v", seen)
	}
}

// ── Bounds ────────────────────────────────────────────────────────────────────

func inMemoryTelemetry(t *testing.T, traces bool) {
	t.Helper()
	ResetTelemetry()
	_ = InitTelemetry("bounds", "in-memory", false, true, traces, 60000, 1.0)
	t.Cleanup(func() { _ = InitTelemetry("tesl", "in-memory", false, true, false, 60000, 1.0) })
}

// The spec: "each instrument is capped at 2000 distinct attribute sets — overflow folds into
// a single {otel.metric.overflow="true"} series". 50 000 user ids cost 2001 series, and the
// overflow series carries every sample the cap turned away.
func TestMetricCardinalityIsCappedWithAnOverflowSeries(t *testing.T) {
	inMemoryTelemetry(t, false)
	for i := 0; i < 50000; i++ {
		_ = Counter("http.requests", FromInt64(1), attributes("user", fmt.Sprint(i)))
	}
	_ = Counter("other", FromInt64(1), attributes()) // another instrument has its own cap
	series := MetricSeriesSnapshot()
	requests, overflow := 0, (*MetricSeries)(nil)
	for index := range series {
		if series[index].Name != "http.requests" {
			continue
		}
		requests++
		if len(series[index].Attributes) == 1 && series[index].Attributes[0].Tuple2First == "otel.metric.overflow" {
			overflow = &series[index]
		}
	}
	if requests != maxMetricSeriesPerInstrument+1 {
		t.Fatalf("%d series for the instrument, want %d", requests, maxMetricSeriesPerInstrument+1)
	}
	if overflow == nil || overflow.Count != 50000-maxMetricSeriesPerInstrument ||
		overflow.Attributes[0].Tuple2Second != "true" {
		t.Fatalf("overflow series = %+v", overflow)
	}
}

func TestDynamicMetricNamesAreGloballyBounded(t *testing.T) {
	inMemoryTelemetry(t, false)
	for i := 0; i < maxMetricSeriesTotal*2; i++ {
		_ = Counter(fmt.Sprintf("request.metric.%d", i), FromInt64(1), attributes())
	}
	_ = Counter("x"+strings.Repeat("y", maxMetricNameBytes), FromInt64(1), attributes())
	_ = Counter("large.attribute", FromInt64(1), attributes("key", strings.Repeat("v", maxMetricAttributeBytes)))

	series := MetricSeriesSnapshot()
	if len(series) > maxMetricSeriesTotal {
		t.Fatalf("retained %d series, want at most %d", len(series), maxMetricSeriesTotal)
	}
	if len(telemetry.instrumentSeries) > maxMetricSeriesTotal {
		t.Fatalf("retained %d instruments, want at most %d", len(telemetry.instrumentSeries), maxMetricSeriesTotal)
	}
	if !hasSeries(metricOverflowName, "otel.metric.overflow", "true", int64(maxMetricSeriesTotal+3)) {
		t.Fatalf("missing bounded overflow series in %+v", series)
	}
}

// Events are a bounded queue with drop-oldest overflow, and the drops are counted in the
// exporter's own metric.
func TestEventBufferDropsTheOldestAndCountsIt(t *testing.T) {
	inMemoryTelemetry(t, false)
	for i := 0; i < maxTelemetryEvents+5; i++ {
		_ = Telemetry(fmt.Sprintf("event.%d", i), attributes())
	}
	events := TelemetryEvents()
	if len(events) != maxTelemetryEvents || events[0].Message != "event.5" ||
		events[len(events)-1].Message != fmt.Sprintf("event.%d", maxTelemetryEvents+4) {
		t.Fatalf("held %d events, first %q", len(events), events[0].Message)
	}
	if TelemetryDroppedEvents() != 5 {
		t.Fatalf("dropped = %d, want 5", TelemetryDroppedEvents())
	}
	if !hasSeries(telemetryDroppedMetric, "reason", "event-buffer-full", 5) {
		t.Fatalf("no %s{reason=event-buffer-full}=5 series in %+v", telemetryDroppedMetric, MetricSeriesSnapshot())
	}
}

func hasSeries(name, key, value string, count int64) bool {
	for _, series := range MetricSeriesSnapshot() {
		if series.Name == name && len(series.Attributes) == 1 && series.Attributes[0].Tuple2First == key &&
			series.Attributes[0].Tuple2Second == value && series.Count == count {
			return true
		}
	}
	return false
}

// An event accepted by the collector leaves the buffer: it is exported once, not on every
// later tick until the process ends.
func TestExportedEventsAreDrainedNotReExported(t *testing.T) {
	var spansReceived, posts int64
	collector := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/traces" {
			writer.WriteHeader(http.StatusOK)
			return
		}
		var body struct {
			ResourceSpans []struct {
				ScopeSpans []struct {
					Spans []any `json:"spans"`
				} `json:"scopeSpans"`
			} `json:"resourceSpans"`
		}
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Errorf("decode: %v", err)
		}
		for _, resource := range body.ResourceSpans {
			for _, scope := range resource.ScopeSpans {
				atomic.AddInt64(&spansReceived, int64(len(scope.Spans)))
			}
		}
		atomic.AddInt64(&posts, 1)
		writer.WriteHeader(http.StatusOK)
	}))
	defer collector.Close()
	_ = InitTelemetry("drain", collector.URL, false, false, true, 5, 1.0)
	t.Cleanup(func() { _ = InitTelemetry("tesl", "in-memory", false, true, false, 60000, 1.0) })
	_ = Telemetry("once", attributes())
	_ = Telemetry("twice", attributes())
	deadline := time.Now().Add(2 * time.Second)
	for atomic.LoadInt64(&posts) < 1 && time.Now().Before(deadline) {
		time.Sleep(2 * time.Millisecond)
	}
	// Several more ticks pass; nothing new is recorded, so nothing more may arrive.
	time.Sleep(60 * time.Millisecond)
	if got := atomic.LoadInt64(&spansReceived); got != 2 {
		t.Fatalf("collector received %d spans over %d posts, want exactly 2", got, atomic.LoadInt64(&posts))
	}
	if left := TelemetryEvents(); len(left) != 0 {
		t.Fatalf("%d events still buffered after export", len(left))
	}
}

// A collector that refuses the batch keeps it for the next tick — bounded by the ring.
func TestEventsSurviveAFailedExport(t *testing.T) {
	inMemoryTelemetry(t, true)
	_ = Telemetry("kept", attributes())
	_, traces, through := telemetryPayloads()
	if len(traces) == 0 {
		t.Fatal("no traces payload")
	}
	// The exporter only drains after a 2xx; nothing was posted here, so nothing drains …
	if len(TelemetryEvents()) != 1 {
		t.Fatal("snapshotting must not drain")
	}
	// … and a delivered snapshot drains exactly what it held, keeping later arrivals.
	_ = Telemetry("later", attributes())
	telemetry.mutex.Lock()
	telemetry.events.dropBefore(through)
	telemetry.mutex.Unlock()
	if left := TelemetryEvents(); len(left) != 1 || left[0].Message != "later" {
		t.Fatalf("after draining the snapshot: %+v", left)
	}
}

// One NaN sample used to make mustJSON answer nil and blank the ENTIRE metrics export for the
// rest of the process. It is refused at the record path and counted instead.
func TestNonFiniteSampleIsSkippedNotBlankingTheExport(t *testing.T) {
	inMemoryTelemetry(t, false)
	_ = Counter("healthy", FromInt64(1), attributes())
	_ = Gauge("g", math.NaN(), attributes())
	_ = Histogram("h", math.Inf(1), attributes())
	_ = Gauge("g", 2.5, attributes())
	metrics, _, _ := telemetryPayloads()
	if len(metrics) == 0 || !strings.Contains(string(metrics), `"healthy"`) ||
		!strings.Contains(string(metrics), `"asDouble":2.5`) {
		t.Fatalf("metrics payload = %s", metrics)
	}
	if !hasSeries(telemetryDroppedMetric, "reason", "non-finite-sample", 2) {
		t.Fatalf("non-finite samples not counted: %+v", MetricSeriesSnapshot())
	}
	for _, series := range MetricSeriesSnapshot() {
		if series.Name == "h" {
			t.Fatalf("a histogram fed only Inf must have no series: %+v", series)
		}
	}
}
