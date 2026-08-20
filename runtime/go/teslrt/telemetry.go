package teslrt

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// `Tesl.Telemetry`: the ambient signals — a telemetry EVENT (`telemetry "name" { … }`) and the
// three metric instruments (`counter`, `histogram`, `gauge`).
//
// Ambient by design, and that is a language decision rather than an implementation shortcut: an
// observability call that needed a capability would either be threaded through every signature
// or be left out of the code that most needs it. So there is nothing to grant and nothing to
// pass; what a program configures is the SINK, once, in `main`.
//
// Events and metrics accumulate in process, and with `console True` they are written to stderr.
// A configured non-memory endpoint also receives standard-library-only OTLP/JSON batches from the
// asynchronous exporter; collector failures never break the application record path.
//
// The recorder is guarded by one mutex. Metrics are per (name, attribute-set), which is what
// makes a counter cumulative rather than per-call, and the attribute set is normalised to a
// sorted key so `{a=1,b=2}` and `{b=2,a=1}` are one series.
type TelemetryEvent struct {
	Service     string
	Endpoint    string
	Message     string
	Attributes  []Tuple2[string, string]
	TimestampMs int64
	TraceID     string
	SpanID      string
}

// MetricKind distinguishes the three instruments. A counter SUMS, a gauge keeps the LAST value,
// and a histogram keeps the shape of a distribution (count/sum/min/max) — not the bucket
// boundaries an OTLP histogram carries, which belong with the exporter.
type MetricKind int

const (
	MetricCounter MetricKind = iota
	MetricHistogram
	MetricGauge
)

// MetricSeries is one instrument at one attribute set. Histograms retain the aggregate shape used
// by the OTLP exporter; bucket boundaries are intentionally omitted because the Tesl surface does
// not expose a boundary argument.
type MetricSeries struct {
	Name       string
	Kind       MetricKind
	Attributes []Tuple2[string, string]
	Count      int64
	Sum        float64
	Last       float64
	Min        float64
	Max        float64
}

var telemetry = struct {
	mutex             sync.Mutex
	service           string
	endpoint          string
	console           bool
	metricsEnabled    bool
	tracesEnabled     bool
	traceRatio        float64
	metricsIntervalMs int
	events            []TelemetryEvent
	series            map[string]*MetricSeries
	exporterStop      chan struct{}
}{service: "tesl", metricsEnabled: true, traceRatio: 1.0, series: map[string]*MetricSeries{}}

func readCryptoRandom(value []byte) (int, error) {
	return rand.Read(value)
}

// InitTelemetry is `initTelemetry service … endpoint … console …`: it configures the sink, once,
// from `main`. Calling it twice replaces the configuration and clears what was recorded, which
// is what a fresh process would have.
func InitTelemetry(service, endpoint string, console, metrics, traces bool,
	metricsIntervalMs int, traceRatio float64) struct{} {
	telemetry.mutex.Lock()
	defer telemetry.mutex.Unlock()
	if telemetry.exporterStop != nil {
		close(telemetry.exporterStop)
		telemetry.exporterStop = nil
	}
	if service != "" {
		telemetry.service = service
	}
	telemetry.endpoint = endpoint
	telemetry.console = console
	telemetry.metricsEnabled = metrics
	telemetry.tracesEnabled = traces
	telemetry.metricsIntervalMs = metricsIntervalMs
	telemetry.traceRatio = traceRatio
	telemetry.events = nil
	telemetry.series = map[string]*MetricSeries{}
	if endpoint != "" && endpoint != "in-memory" {
		telemetry.exporterStop = make(chan struct{})
		go runTelemetryExporter(endpoint, metricsIntervalMs, telemetry.exporterStop)
	}
	return struct{}{}
}

// Telemetry is the `telemetry "name" { key = value }` block: one event, with its attributes
// already rendered to text by the emitter (which knows each field's type, and renders a `secret`
// as its redaction rather than its payload).
func Telemetry(message string, attributes []Tuple2[string, string]) struct{} {
	event := TelemetryEvent{
		Service:     telemetry.service,
		Endpoint:    telemetry.endpoint,
		Message:     message,
		Attributes:  attributes,
		TimestampMs: telemetryNowMillis(),
		TraceID:     telemetryID(16),
		SpanID:      telemetryID(8),
	}
	telemetry.mutex.Lock()
	telemetry.events = append(telemetry.events, event)
	console := telemetry.console
	telemetry.mutex.Unlock()
	if console {
		fmt.Fprintf(os.Stderr, "[telemetry] %s %s%s\n", event.Service, message,
			renderAttributes(attributes))
	}
	return struct{}{}
}

// telemetryNowMillis is the event timestamp. An Int wider than int64 cannot be a wall clock, so
// the conversion is total here in a way it is not in general.
func telemetryNowMillis() int64 {
	millis, _ := NowMillis().Value.Int64()
	return millis
}

func renderAttributes(attributes []Tuple2[string, string]) string {
	if len(attributes) == 0 {
		return ""
	}
	parts := make([]string, 0, len(attributes))
	for _, attribute := range attributes {
		parts = append(parts, attribute.Tuple2First+"="+attribute.Tuple2Second)
	}
	return " {" + strings.Join(parts, ", ") + "}"
}

// seriesKey is the identity of a metric series: its name plus its attribute set, normalised so
// the same attributes in a different order are the same series.
func seriesKey(name string, kind MetricKind, attributes []Tuple2[string, string]) string {
	pairs := make([]string, 0, len(attributes))
	for _, attribute := range attributes {
		pairs = append(pairs, attribute.Tuple2First+"\x00"+attribute.Tuple2Second)
	}
	sort.Strings(pairs)
	return fmt.Sprintf("%d\x00%s\x00%s", kind, name, strings.Join(pairs, "\x01"))
}

func recordMetric(name string, kind MetricKind, value float64,
	attributes []Tuple2[string, string]) {
	telemetry.mutex.Lock()
	defer telemetry.mutex.Unlock()
	if !telemetry.metricsEnabled {
		return
	}
	key := seriesKey(name, kind, attributes)
	series, found := telemetry.series[key]
	if !found {
		series = &MetricSeries{Name: name, Kind: kind, Attributes: attributes,
			Min: value, Max: value}
		telemetry.series[key] = series
	}
	series.Count++
	series.Sum += value
	series.Last = value
	if value < series.Min {
		series.Min = value
	}
	if value > series.Max {
		series.Max = value
	}
}

// Counter is `counter "name" delta attrs`: CUMULATIVE, which is why the series is kept rather
// than the call. A negative delta is allowed for the same reason Racket allows it — the
// instrument records what the program says.
func Counter(name string, delta Int, attributes []Tuple2[string, string]) struct{} {
	recordMetric(name, MetricCounter, delta.Float64(), attributes)
	return struct{}{}
}

func Histogram(name string, value float64, attributes []Tuple2[string, string]) struct{} {
	recordMetric(name, MetricHistogram, value, attributes)
	return struct{}{}
}

func Gauge(name string, value float64, attributes []Tuple2[string, string]) struct{} {
	recordMetric(name, MetricGauge, value, attributes)
	return struct{}{}
}

// ── Inspection seams ──────────────────────────────────────────────────────────
//
// Not Tesl-surface names: they exist so the runtime's own tests can assert what was recorded,
// and so a program that has shed Tesl can read its own telemetry without an exporter.

func TelemetryEvents() []TelemetryEvent {
	telemetry.mutex.Lock()
	defer telemetry.mutex.Unlock()
	out := make([]TelemetryEvent, len(telemetry.events))
	copy(out, telemetry.events)
	return out
}

func telemetryTraceEnabled() bool {
	telemetry.mutex.Lock()
	defer telemetry.mutex.Unlock()
	return telemetry.tracesEnabled
}

// MetricSeriesSnapshot is every series, in a deterministic order (by name, then by key), so a
// test or a dump reads the same way twice.
func MetricSeriesSnapshot() []MetricSeries {
	telemetry.mutex.Lock()
	defer telemetry.mutex.Unlock()
	keys := make([]string, 0, len(telemetry.series))
	for key := range telemetry.series {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	out := make([]MetricSeries, 0, len(keys))
	for _, key := range keys {
		if series := telemetry.series[key]; series != nil {
			out = append(out, *series)
		}
	}
	sort.SliceStable(out, func(left, right int) bool { return out[left].Name < out[right].Name })
	return out
}

// ResetTelemetry clears what was recorded, for a test that asserts on it. The emitted per-test
// reset calls it for the same reason it truncates tables: one test block's signals must not be
// another's.
func ResetTelemetry() {
	telemetry.mutex.Lock()
	defer telemetry.mutex.Unlock()
	telemetry.events = nil
	telemetry.series = map[string]*MetricSeries{}
}

// MillisOf narrows a Tesl `Int` interval to the plain int the recorder keeps. An interval outside
// int64 is a configuration mistake rather than a duration, so it fails at configuration time.
func MillisOf(value Int) int {
	millis, exact := value.Int64()
	if !exact || millis < 0 {
		panic("initTelemetry: " + value.String() + " is not a millisecond interval")
	}
	return int(millis)
}

var otlpHTTPClient = &http.Client{Timeout: 2 * time.Second}

func telemetryID(size int) string {
	value := make([]byte, size)
	if _, err := cryptoRandRead(value); err != nil {
		return strings.Repeat("0", size*2)
	}
	return hex.EncodeToString(value)
}

var cryptoRandRead = func(value []byte) (int, error) { return readCryptoRandom(value) }

func runTelemetryExporter(endpoint string, intervalMs int, stop <-chan struct{}) {
	if intervalMs <= 0 {
		intervalMs = 60000
	}
	ticker := time.NewTicker(time.Duration(intervalMs) * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			exportTelemetry(endpoint)
		case <-stop:
			return
		}
	}
}

func exportTelemetry(endpoint string) {
	metrics, traces := telemetryPayloads()
	if len(metrics) > 0 {
		postOTLP(endpointPath(endpoint, "/v1/metrics"), metrics)
	}
	if len(traces) > 0 {
		postOTLP(endpointPath(endpoint, "/v1/traces"), traces)
	}
}

func postOTLP(endpoint string, payload []byte) {
	request, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := otlpHTTPClient.Do(request)
	if err == nil && response != nil {
		_ = response.Body.Close()
	}
}

func endpointPath(endpoint, suffix string) string {
	return strings.TrimRight(endpoint, "/") + suffix
}

func telemetryPayloads() ([]byte, []byte) {
	telemetry.mutex.Lock()
	service := telemetry.service
	metricsEnabled := telemetry.metricsEnabled
	tracesEnabled := telemetry.tracesEnabled
	series := make([]MetricSeries, 0, len(telemetry.series))
	for _, value := range telemetry.series {
		series = append(series, *value)
	}
	events := append([]TelemetryEvent(nil), telemetry.events...)
	telemetry.mutex.Unlock()
	var metrics, traces []byte
	if metricsEnabled && len(series) > 0 {
		metrics = mustJSON(otlpMetrics(service, series))
	}
	if tracesEnabled && len(events) > 0 {
		traces = mustJSON(otlpTraces(service, events))
	}
	return metrics, traces
}

func resource(service string) map[string]any {
	return map[string]any{"attributes": []map[string]any{{
		"key": "service.name", "value": map[string]string{"stringValue": service},
	}}}
}

func otlpMetrics(service string, series []MetricSeries) map[string]any {
	metrics := make([]map[string]any, 0, len(series))
	now := fmt.Sprint(time.Now().UnixNano())
	for _, value := range series {
		point := map[string]any{"attributes": otlpAttributes(value.Attributes), "timeUnixNano": now}
		metric := map[string]any{"name": value.Name}
		switch value.Kind {
		case MetricCounter:
			point["asInt"] = fmt.Sprint(int64(value.Last))
			metric["sum"] = map[string]any{"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": []any{point}}
		case MetricGauge:
			point["asDouble"] = value.Last
			metric["gauge"] = map[string]any{"dataPoints": []any{point}}
		case MetricHistogram:
			point["count"] = fmt.Sprint(value.Count)
			point["sum"] = value.Sum
			metric["histogram"] = map[string]any{"aggregationTemporality": 2, "dataPoints": []any{point}}
		}
		metrics = append(metrics, metric)
	}
	return map[string]any{"resourceMetrics": []any{map[string]any{
		"resource": resource(service), "scopeMetrics": []any{map[string]any{"metrics": metrics}},
	}}}
}

func otlpTraces(service string, events []TelemetryEvent) map[string]any {
	spans := make([]map[string]any, 0, len(events))
	for _, event := range events {
		start := event.TimestampMs * 1_000_000
		spans = append(spans, map[string]any{
			"traceId": event.TraceID, "spanId": event.SpanID, "name": event.Message,
			"startTimeUnixNano": fmt.Sprint(start), "endTimeUnixNano": fmt.Sprint(start),
			"attributes": otlpAttributes(event.Attributes),
		})
	}
	return map[string]any{"resourceSpans": []any{map[string]any{
		"resource": resource(service), "scopeSpans": []any{map[string]any{"spans": spans}},
	}}}
}

func otlpAttributes(attributes []Tuple2[string, string]) []map[string]any {
	result := make([]map[string]any, 0, len(attributes))
	for _, attribute := range attributes {
		result = append(result, map[string]any{
			"key": attribute.Tuple2First, "value": map[string]string{"stringValue": attribute.Tuple2Second},
		})
	}
	return result
}

func mustJSON(value any) []byte {
	encoded, err := json.Marshal(value)
	if err != nil {
		return nil
	}
	return encoded
}
