package teslrt

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
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
// pass; what a program configures is the SINK, once, in the App `telemetry` field (or the legacy
// `initTelemetry` form).
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
	events            eventRing
	series            map[string]*MetricSeries
	// instrumentSeries counts the distinct attribute sets each instrument (kind + name) has
	// produced, which is what the cardinality cap is measured against.
	instrumentSeries map[string]int
	exporterStop     chan struct{}
}{service: "tesl", metricsEnabled: true, traceRatio: 1.0,
	series: map[string]*MetricSeries{}, instrumentSeries: map[string]int{}}

// ── Bounds ────────────────────────────────────────────────────────────────────
//
// Both stores are fed by request-derived data — a label built from a user id, an event per
// request — and both were unbounded. The spec's promises are the bounds implemented here:
//
//	maxMetricSeriesPerInstrument   "each instrument is capped at 2000 distinct attribute sets
//	                               — overflow folds into a single {otel.metric.overflow=true}
//	                               series", so a hostile label costs one extra series;
//	maxMetricSeriesTotal           caps request-derived instrument names across the process;
//	maxMetricNameBytes             prevents one name from retaining an arbitrarily large value;
//	maxMetricAttributeBytes        bounds the total attribute key/value data retained per sample;
//	maxTelemetryEvents             "events are buffered in a bounded queue (drop-oldest on
//	                               overflow) flushed by a background timer"; exported events
//	                               leave the buffer, and a drop is counted in the exporter's
//	                               own `tesl.telemetry.dropped` counter.
//
// A sample that is NaN or ±Inf is refused at the record path and counted under the same
// counter: encoding/json cannot represent it, and one such value used to make mustJSON answer
// nil — blanking the ENTIRE metrics export for the rest of the process.
const (
	maxMetricSeriesPerInstrument = 2000
	maxMetricSeriesTotal         = 10000
	maxMetricNameBytes           = 255
	maxMetricAttributeBytes      = 4096
	maxTelemetryEvents           = 10000
	telemetryDroppedMetric       = "tesl.telemetry.dropped"
	metricOverflowName           = "tesl.metric.overflow"
)

var metricOverflowAttributes = []Tuple2[string, string]{
	{Tuple2First: "otel.metric.overflow", Tuple2Second: "true"},
}

// eventRing is the bounded event buffer: a fixed-capacity ring that drops the OLDEST event
// when full. Every event carries a position in one monotonic sequence, so the exporter can
// snapshot the buffer, post it, and then remove exactly what it posted — events that arrived
// meanwhile keep their place, and an overflow that already discarded some of the snapshot
// does not make the drain discard newer ones in their stead.
type eventRing struct {
	items    []TelemetryEvent
	head     int   // index of the oldest item
	count    int   // items held
	firstSeq int64 // sequence number of the oldest item
	dropped  int64 // events discarded because the ring was full
}

func (ring *eventRing) push(event TelemetryEvent) {
	if ring.items == nil {
		ring.items = make([]TelemetryEvent, maxTelemetryEvents)
	}
	if ring.count == len(ring.items) {
		// Full: overwrite the oldest slot and advance past it.
		ring.items[ring.head] = event
		ring.head = (ring.head + 1) % len(ring.items)
		ring.firstSeq++
		ring.dropped++
		return
	}
	ring.items[(ring.head+ring.count)%len(ring.items)] = event
	ring.count++
}

// snapshot answers the events oldest-first and the sequence number just past the newest.
func (ring *eventRing) snapshot() ([]TelemetryEvent, int64) {
	out := make([]TelemetryEvent, 0, ring.count)
	for index := 0; index < ring.count; index++ {
		out = append(out, ring.items[(ring.head+index)%len(ring.items)])
	}
	return out, ring.firstSeq + int64(ring.count)
}

// dropBefore removes every event with a sequence number below `seq` — the ones a snapshot
// taken at `seq` contained and the exporter has since delivered.
func (ring *eventRing) dropBefore(seq int64) {
	remove := seq - ring.firstSeq
	if remove <= 0 {
		return
	}
	if remove > int64(ring.count) {
		remove = int64(ring.count)
	}
	for index := int64(0); index < remove; index++ {
		ring.items[(ring.head+int(index))%len(ring.items)] = TelemetryEvent{}
	}
	ring.head = (ring.head + int(remove)) % len(ring.items)
	ring.count -= int(remove)
	ring.firstSeq += remove
}

func (ring *eventRing) reset() {
	// The sequence moves past everything ever held, so a drain carrying a snapshot taken
	// before the reset removes nothing recorded after it.
	ring.firstSeq += int64(ring.count)
	// Cleared in place rather than set to nil: `snapshot`/`dropBefore` index the backing
	// array and the analyser cannot see that count==0 guards them; releasing the events is
	// what matters, and the array is reused by the next `record`.
	for index := range ring.items {
		ring.items[index] = TelemetryEvent{}
	}
	ring.head, ring.count = 0, 0
	ring.dropped = 0
}

func readCryptoRandom(value []byte) (int, error) {
	return rand.Read(value)
}

// InitTelemetry is the runtime contract for App's TelemetryConfig lowering. It configures the
// sink once from the App `telemetry` field; the legacy `initTelemetry service … endpoint … console
// …` form uses the same call. Calling it twice replaces the configuration and clears what was
// recorded, which is what a fresh process would have.
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
	telemetry.events.reset()
	telemetry.series = map[string]*MetricSeries{}
	telemetry.instrumentSeries = map[string]int{}
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
	before := telemetry.events.dropped
	telemetry.events.push(event)
	if telemetry.events.dropped > before {
		recordMetricLocked(telemetryDroppedMetric, MetricCounter, 1,
			[]Tuple2[string, string]{{Tuple2First: "reason", Tuple2Second: "event-buffer-full"}})
	}
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
	if math.IsNaN(value) || math.IsInf(value, 0) {
		// Refused here rather than at export: a series that held one non-finite value could
		// never be encoded again, and the export dropped every OTHER series with it.
		recordMetricLocked(telemetryDroppedMetric, MetricCounter, 1,
			[]Tuple2[string, string]{{Tuple2First: "reason", Tuple2Second: "non-finite-sample"}})
		return
	}
	recordMetricLocked(name, kind, value, attributes)
}

// recordMetricLocked is the record path proper; the caller holds telemetry.mutex. A new
// attribute set past the instrument's cap lands in the instrument's single overflow series
// instead of a series of its own.
func recordMetricLocked(name string, kind MetricKind, value float64,
	attributes []Tuple2[string, string]) {
	attributeBytes, attributesTooLarge := 0, false
	for _, attribute := range attributes {
		for _, part := range [...]string{attribute.Tuple2First, attribute.Tuple2Second} {
			if len(part) > maxMetricAttributeBytes-attributeBytes {
				attributesTooLarge = true
				break
			}
			attributeBytes += len(part)
		}
		if attributesTooLarge {
			break
		}
	}
	if len(name) > maxMetricNameBytes || attributesTooLarge {
		name = metricOverflowName
		attributes = metricOverflowAttributes
	}
	key := seriesKey(name, kind, attributes)
	series, found := telemetry.series[key]
	// Reserve one entry for the shared overflow series. Without that reservation,
	// the first sample beyond the budget would create an additional entry and the
	// purported process-wide cap would actually be maxMetricSeriesTotal+1.
	if !found && len(telemetry.series) >= maxMetricSeriesTotal-1 {
		// Do not retain the caller's name after the process-wide budget is exhausted.
		name = metricOverflowName
		attributes = metricOverflowAttributes
		key = seriesKey(name, kind, attributes)
		series, found = telemetry.series[key]
	}
	if !found {
		instrument := fmt.Sprintf("%d\x00%s", kind, name)
		if telemetry.instrumentSeries[instrument] >= maxMetricSeriesPerInstrument {
			attributes = metricOverflowAttributes
			key = seriesKey(name, kind, attributes)
			series, found = telemetry.series[key]
		} else {
			telemetry.instrumentSeries[instrument]++
		}
	}
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
	events, _ := telemetry.events.snapshot()
	return events
}

// TelemetryDroppedEvents is how many events the bounded buffer discarded since the last
// reset — the number the `tesl.telemetry.dropped` counter also carries.
func TelemetryDroppedEvents() int64 {
	telemetry.mutex.Lock()
	defer telemetry.mutex.Unlock()
	return telemetry.events.dropped
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
	telemetry.events.reset()
	telemetry.series = map[string]*MetricSeries{}
	telemetry.instrumentSeries = map[string]int{}
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
			func() {
				defer func() {
					if trap := recover(); trap != nil {
						fmt.Fprintf(os.Stderr, "tesl: telemetry exporter recovered from a trap: %v\n", trap)
					}
				}()
				exportTelemetry(endpoint)
			}()
		case <-stop:
			return
		}
	}
}

// exportTelemetry posts one interval's snapshot. Metrics are CUMULATIVE and stay; events are
// a QUEUE — the ones the collector accepted leave the buffer, so an event is exported once,
// not on every later tick until the process ends (which is what an ever-growing slice did:
// unbounded memory and O(n²) egress). A failed post keeps them for the next tick, bounded by
// the ring.
func exportTelemetry(endpoint string) {
	metrics, traces, exportedThrough := telemetryPayloads()
	if len(metrics) > 0 {
		postOTLP(endpointPath(endpoint, "/v1/metrics"), metrics)
	}
	if len(traces) > 0 && postOTLP(endpointPath(endpoint, "/v1/traces"), traces) {
		telemetry.mutex.Lock()
		telemetry.events.dropBefore(exportedThrough)
		telemetry.mutex.Unlock()
	}
}

// postOTLP answers whether the collector ACCEPTED the batch: a 2xx. Anything else — no
// response, a 5xx, a 429 — is a failed delivery and the caller keeps what it tried to send.
func postOTLP(endpoint string, payload []byte) bool {
	request, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return false
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := otlpHTTPClient.Do(request)
	if err != nil || response == nil {
		return false
	}
	_ = response.Body.Close()
	return response.StatusCode >= 200 && response.StatusCode < 300
}

func endpointPath(endpoint, suffix string) string {
	return strings.TrimRight(endpoint, "/") + suffix
}

// telemetryPayloads renders the metrics and traces batches, and answers the event sequence
// the traces batch reaches — what exportTelemetry drains once that batch is delivered.
func telemetryPayloads() (metrics, traces []byte, exportedThrough int64) {
	telemetry.mutex.Lock()
	service := telemetry.service
	metricsEnabled := telemetry.metricsEnabled
	tracesEnabled := telemetry.tracesEnabled
	series := make([]MetricSeries, 0, len(telemetry.series))
	for _, value := range telemetry.series {
		series = append(series, *value)
	}
	events, exportedThrough := telemetry.events.snapshot()
	telemetry.mutex.Unlock()
	if metricsEnabled && len(series) > 0 {
		metrics = mustJSON(otlpMetrics(service, series))
	}
	if tracesEnabled && len(events) > 0 {
		traces = mustJSON(otlpTraces(service, events))
	}
	return metrics, traces, exportedThrough
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
