package teslrt

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
)

// `Tesl.Telemetry`: the ambient signals — a telemetry EVENT (`telemetry "name" { … }`) and the
// three metric instruments (`counter`, `histogram`, `gauge`).
//
// Ambient by design, and that is a language decision rather than an implementation shortcut: an
// observability call that needed a capability would either be threaded through every signature
// or be left out of the code that most needs it. So there is nothing to grant and nothing to
// pass; what a program configures is the SINK, once, in `main`.
//
// WHAT THIS RECORDS AND WHAT IT DOES NOT EXPORT. Events and metrics accumulate in process, and
// with `console True` they are written to stderr. OTLP export — the wire protocol, the batching
// exporter, the `/v1/metrics` endpoint, and the span tree the Racket runtime builds around every
// request and outbound call — is NOT here yet. That is a deliberate boundary rather than an
// oversight: the corpus configures `endpoint "in-memory"`, every assertion in it is that
// telemetry does not disturb the program's own answers, and an exporter that silently dropped
// spans would be worse than one that is honestly absent. A program that needs the wire today
// runs on the Racket backend.
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

// MetricSeries is one instrument at one attribute set.
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
}{service: "tesl", metricsEnabled: true, traceRatio: 1.0, series: map[string]*MetricSeries{}}

// InitTelemetry is `initTelemetry service … endpoint … console …`: it configures the sink, once,
// from `main`. Calling it twice replaces the configuration and clears what was recorded, which
// is what a fresh process would have.
func InitTelemetry(service, endpoint string, console, metrics, traces bool,
	metricsIntervalMs int, traceRatio float64) struct{} {
	telemetry.mutex.Lock()
	defer telemetry.mutex.Unlock()
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
		// Said once, at configuration time, rather than silently dropping every span and metric
		// for the lifetime of the process.
		fmt.Fprintf(os.Stderr,
			"tesl: telemetry endpoint %q is configured, but this runtime records in process only "+
				"— OTLP export is not implemented on the Go backend yet.\n", endpoint)
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
