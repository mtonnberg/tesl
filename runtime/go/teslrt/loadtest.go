package teslrt

import (
	"math"
	"sort"
	"testing"
	"time"
)

// The load-test harness: an OPEN-MODEL scheduler, so latency measures what a client would see.
//
// Every rule here is copied from `dsl/load-test.rkt` deliberately, because the point of having it
// on both backends is that the two sets of numbers are comparable:
//
//	requests are sent at a FIXED arrival rate regardless of how long the last one took, and
//	latency is measured from the SCHEDULED send time — a closed model (send, wait, send) hides
//	exactly the queueing a load test exists to find, which is coordinated omission;
//	warm-up runs until p99 is steady (CV < 5% across three consecutive 2-second windows) or 30
//	seconds pass, and warm-up requests are NOT measured — otherwise the first JIT/allocation
//	costs land in the p99 the assertion reads;
//	percentiles are taken from the sorted sample by index (floor(p*n)), which is the same
//	estimator, so a p99 here and a p99 there mean the same thing;
//	the report is the same six lines, so a diff of two runs is a diff of the numbers.
//
// One request at a time, from one goroutine: the Racket harness is single-threaded, and matching
// that is what makes the comparison about the RUNTIME rather than about how each harness spreads
// work over cores.
const (
	warmupWindow      = 2 * time.Second
	warmupCVThreshold = 0.05
	warmupConsecutive = 3
	warmupMax         = 30 * time.Second
)

// LoadTestResult is the sample a run produced, in milliseconds.
type LoadTestResult struct {
	Latencies  []float64
	Errors     int
	Total      int
	DurationS  float64
	Throughput float64
	ErrorRate  float64
}

// RunLoadTest drives `request` at `rate` requests per second for `duration` seconds and reports
// the sample. `request` answers the response status (an error is reported as 0), so the harness
// can count a 4xx/5xx as an error without knowing anything about the program.
func RunLoadTest(rate int, durationSeconds int, request func() int) LoadTestResult {
	if rate < 1 {
		rate = 1
	}
	interval := time.Duration(float64(time.Second) / float64(rate))
	result := LoadTestResult{}

	// One request, measured from the time it was SCHEDULED to be sent.
	send := func(scheduled time.Time) float64 {
		status := request()
		latency := float64(time.Since(scheduled).Nanoseconds()) / 1e6
		result.Total++
		if status == 0 || status >= 400 {
			result.Errors++
		}
		return latency
	}

	// ── Warm-up: not measured ──────────────────────────────────────────────
	warmupStart := time.Now()
	windowStart := time.Now()
	window := []float64{}
	recent := []float64{}
	scheduled := time.Now()
	for time.Since(warmupStart) < warmupMax {
		window = append(window, send(scheduled))
		if time.Since(windowStart) >= warmupWindow {
			recent = append(recent, percentileOf(window, 0.99))
			if len(recent) > warmupConsecutive {
				recent = recent[len(recent)-warmupConsecutive:]
			}
			if len(recent) == warmupConsecutive &&
				coefficientOfVariation(recent) < warmupCVThreshold {
				break
			}
			window = window[:0]
			windowStart = time.Now()
		}
		scheduled = scheduled.Add(interval)
		if wait := time.Until(scheduled); wait > 0 {
			time.Sleep(wait)
		}
	}

	// ── Measurement ────────────────────────────────────────────────────────
	result.Total = 0
	result.Errors = 0
	measureStart := time.Now()
	measureEnd := measureStart.Add(time.Duration(durationSeconds) * time.Second)
	scheduled = time.Now()
	for time.Now().Before(measureEnd) {
		result.Latencies = append(result.Latencies, send(scheduled))
		scheduled = scheduled.Add(interval)
		if wait := time.Until(scheduled); wait > 0 {
			time.Sleep(wait)
		}
	}
	result.DurationS = time.Since(measureStart).Seconds()
	if result.DurationS > 0 {
		result.Throughput = float64(len(result.Latencies)) / result.DurationS
	}
	if result.Total > 0 {
		result.ErrorRate = float64(result.Errors) / float64(result.Total)
	}
	return result
}

// percentileOf takes the value at floor(p*n) of the sorted sample — the same estimator the Racket
// harness uses, so the two report the same number for the same sample.
func percentileOf(latencies []float64, p float64) float64 {
	if len(latencies) == 0 {
		return math.Inf(1)
	}
	sorted := make([]float64, len(latencies))
	copy(sorted, latencies)
	sort.Float64s(sorted)
	index := int(math.Floor(p * float64(len(sorted))))
	if index >= len(sorted) {
		index = len(sorted) - 1
	}
	return sorted[index]
}

func coefficientOfVariation(values []float64) float64 {
	if len(values) < 2 {
		return 1.0
	}
	sum := 0.0
	for _, value := range values {
		sum += value
	}
	mean := sum / float64(len(values))
	if mean <= 0 {
		return 1.0
	}
	variance := 0.0
	for _, value := range values {
		variance += (value - mean) * (value - mean)
	}
	variance /= float64(len(values) - 1)
	return math.Sqrt(variance) / mean
}

// LoadTestMetric answers one of the metrics an `assert` names.
func (result LoadTestResult) LoadTestMetric(name string) float64 {
	switch name {
	case "p50":
		return percentileOf(result.Latencies, 0.50)
	case "p95":
		return percentileOf(result.Latencies, 0.95)
	case "p99":
		return percentileOf(result.Latencies, 0.99)
	case "p99.9":
		return percentileOf(result.Latencies, 0.999)
	case "errorRate":
		return result.ErrorRate
	case "throughput":
		return result.Throughput
	default:
		panic("load-test: unknown metric " + name)
	}
}

// ReportLoadTest prints the same six lines the Racket harness prints, so two runs diff cleanly.
// It goes to the test log rather than stdout because a load test IS a test here.
func ReportLoadTest(teslT *testing.T, result LoadTestResult) {
	teslT.Helper()
	teslT.Logf("  Load test results (%d requests in %.1fs):", len(result.Latencies),
		result.DurationS)
	teslT.Logf("    p50:  %.1fms  p95: %.1fms  p99: %.1fms  p99.9: %.1fms",
		result.LoadTestMetric("p50"), result.LoadTestMetric("p95"),
		result.LoadTestMetric("p99"), result.LoadTestMetric("p99.9"))
	minimum, maximum := math.Inf(1), 0.0
	for _, latency := range result.Latencies {
		minimum = math.Min(minimum, latency)
		maximum = math.Max(maximum, latency)
	}
	if len(result.Latencies) == 0 {
		minimum = 0
	}
	teslT.Logf("    min: %.1fms  max: %.1fms  throughput: %.1frps  errors: %.2f%%",
		minimum, maximum, result.Throughput, result.ErrorRate*100)
	teslT.Logf("    (measurements include in-process harness overhead)")
}

// AssertLoadTest fails the test when a metric misses its threshold, naming the actual value —
// which is the whole content of a load-test failure.
func AssertLoadTest(teslT *testing.T, result LoadTestResult, metric, operator string,
	threshold float64) {
	teslT.Helper()
	actual := result.LoadTestMetric(metric)
	passed := false
	switch operator {
	case "<":
		passed = actual < threshold
	case "<=":
		passed = actual <= threshold
	case ">":
		passed = actual > threshold
	case ">=":
		passed = actual >= threshold
	default:
		panic("load-test: unknown comparison " + operator)
	}
	if !passed {
		teslT.Fatalf("load-test: assertion failed: %s %s %g (actual: %.2f)",
			metric, operator, threshold, actual)
	}
}

// LoadTestStatus is what a request thunk answers: the status an api-test response carries, or 0
// when the request trapped. A trap is an error rather than a crash, because a load test that
// dies on the first 500 measures nothing.
func LoadTestStatus(response ApiResponse) int {
	status, exact := response.Status.Int64()
	if !exact {
		return 0
	}
	return int(status)
}
