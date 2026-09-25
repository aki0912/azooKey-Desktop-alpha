"""Summarize numeric replay traces; compare display hashes without storing text."""
import argparse
import json
import math
from pathlib import Path


def quantiles(values):
    values = sorted(values)
    if not values:
        return None
    return {f"p{p}_ms": round(values[math.ceil(p / 100 * len(values)) - 1] / 1000, 3)
            for p in (50, 95, 99)}


def summarize(report):
    result = {"cold_ms": report["coldUS"] / 1000, "series": []}
    for length, rate in sorted({(s["length"], s["rate"]) for s in report["samples"]}):
        samples = [s for s in report["samples"] if (s["length"], s["rate"]) == (length, rate)]
        counters = {}
        for s in samples:
            for key, value in s["metrics"]["counts"].items():
                counters[key] = counters.get(key, 0) + value
        result["series"].append({"length": length, "keys_per_second": rate, "samples": len(samples),
            **{key: quantiles([s[key] for s in samples]) for key in ("serviceUS", "queueUS", "responseUS")},
            "phases": {phase: quantiles([s["metrics"]["microseconds"].get(phase, 0) for s in samples])
                       for phase in ("judgment", "classification", "roman", "conversion", "render")},
            "max_pending": max(s["pending"] for s in samples), "counters": counters,
            "drain_ms": report["drainUS"][f"{length}-{rate}"] / 1000})
    return result


def compare(reference, candidate):
    def indexed(report):
        return {(s["length"], s["rate"], s["index"]): s["displaySHA256"] for s in report["samples"]}
    a, b = indexed(reference), indexed(candidate)
    return {"shared_samples": len(a.keys() & b.keys()),
            "missing_samples": len(a.keys() - b.keys()), "extra_samples": len(b.keys() - a.keys()),
            "display_mismatches": [key for key in sorted(a.keys() & b.keys()) if a[key] != b[key]]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    reports = [json.loads(path.read_text()) for path in args.reports]
    result = {path.stem: summarize(report) for path, report in zip(args.reports, reports)}
    result["comparisons_to_first"] = {path.stem: compare(reports[0], report)
                                     for path, report in zip(args.reports[1:], reports[1:])}
    args.output.write_text(json.dumps(result, indent=2) + "\n")
