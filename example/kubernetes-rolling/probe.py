#!/usr/bin/env python3
"""Sample rolling-update availability; SIGINT/SIGTERM writes the JSON report."""

import argparse
from datetime import datetime, timezone
from http.client import HTTPException
import json
import math
from pathlib import Path
import signal
import threading
import time
from urllib import error, parse, request
import uuid


def utc():
    return datetime.now(timezone.utc).isoformat()


def positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be finite and positive")
    return number


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # A redirect must not hide a failed endpoint sample.


def validate(kind, body):
    if kind == "health":
        value = json.loads(body)
        if (not isinstance(value, dict)
                or type(value.get("release")) is not int
                or type(value.get("notes")) is not int or value["notes"] < 0):
            raise ValueError("expected {release: integer, notes: nonnegative integer}")
        return value
    if kind == "notes":
        if body.strip() not in ('created', '"created"'):
            raise ValueError("expected created")
    elif json.loads(body) is not True:
        raise ValueError("expected true")


def sample(base, kind, identifier=None):
    path = "/health" if kind == "health" else f"/{kind}/{parse.quote(identifier, safe='')}"
    result = {"kind": kind, "path": path, "utc": utc(),
              "monotonic": time.monotonic(), "ok": False}
    if identifier is not None:
        result["id"] = identifier
    req = request.Request(base + path, method="GET" if kind == "health" else "POST",
                          data=None if kind == "health" else b"",
                          headers={"Connection": "close"})
    try:
        # Fresh opener/connection for every sample; no application retries.
        with request.build_opener(NoRedirect).open(req, timeout=3) as response:
            result["status"] = response.status
            body = response.read(65537)
            if len(body) > 65536:
                raise ValueError("response exceeds 64 KiB")
            value = validate(kind, body.decode("utf-8"))
            if kind == "health":
                result.update(value)
            result["ok"] = True
    except (OSError, ValueError, HTTPException, error.URLError) as exc:
        result["error"] = f"{type(exc).__name__}: {exc}"
        if isinstance(exc, error.HTTPError):
            result["status"] = exc.code
            exc.close()
    finally:
        result["latency_ms"] = (time.monotonic() - result["monotonic"]) * 1000
    return result


def summarize(samples):
    summary = {}
    for kind in ("health", "notes", "jobs"):
        rows = [s for s in samples if s["kind"] == kind]
        latencies = sorted(s["latency_ms"] for s in rows)
        summary[kind] = {
            "attempts": len(rows), "accepted": sum(s["ok"] for s in rows),
            "failures": sum(not s["ok"] for s in rows),
            "latency_ms": None if not rows else {
                "mean": sum(latencies) / len(rows),
                "p50": latencies[math.ceil(len(rows) * .50) - 1],
                "p95": latencies[math.ceil(len(rows) * .95) - 1],
                "max": latencies[-1]},
        }
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8080")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prefix", default=uuid.uuid4().hex)
    parser.add_argument("--interval", type=positive, default=.2)
    parser.add_argument("--write-interval", type=positive, default=1.)
    args = parser.parse_args()
    if not args.prefix or parse.urlsplit(args.url).scheme not in ("http", "https"):
        parser.error("a nonempty prefix and an http(s) URL are required")
    stop = threading.Event()
    received = []

    def shutdown(signum, frame):
        received.append(signal.Signals(signum).name)
        stop.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, shutdown)
    report = {"version": 1, "url": args.url, "prefix": args.prefix,
              "started_utc": utc(), "started_monotonic": time.monotonic(),
              "interval": args.interval, "write_interval": args.write_interval,
              "timeout_seconds": 3, "samples": []}
    print(f"Probing {args.url}; prefix={args.prefix}; stop with SIGINT/SIGTERM", flush=True)
    health_due = write_due = time.monotonic()
    sequence = 0
    while not stop.is_set():
        if time.monotonic() >= health_due:
            report["samples"].append(sample(args.url.rstrip("/"), "health"))
            health_due = time.monotonic() + args.interval
        if not stop.is_set() and time.monotonic() >= write_due:
            sequence += 1
            for kind in ("notes", "jobs"):
                if stop.is_set():
                    break
                identifier = f"{args.prefix}-{kind}-{sequence}"
                report["samples"].append(sample(args.url.rstrip("/"), kind, identifier))
            write_due = time.monotonic() + args.write_interval
        stop.wait(max(0, min(health_due, write_due) - time.monotonic()))
    samples = report["samples"]
    report.update(ended_utc=utc(), ended_monotonic=time.monotonic(), signals=received,
                  summary=summarize(samples), failures=[s for s in samples if not s["ok"]],
                  observed_releases=sorted({s["release"] for s in samples
                                            if s["kind"] == "health" and s["ok"]}),
                  accepted_ids={k: [s["id"] for s in samples if s["kind"] == k and s["ok"]]
                                for k in ("notes", "jobs")},
                  scope="Sampled requests only during this window; gaps are unobserved. "
                        "Acceptance does not prove persistence or delivery; verify separately.")
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(args.output), "summary": report["summary"],
                      "observed_releases": report["observed_releases"]}), flush=True)
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
