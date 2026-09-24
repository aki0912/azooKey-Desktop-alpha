"""Collect only the opt-in MixedDiagnostics category; never enable input-text logging."""
import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--last", default="10m")
    parser.add_argument("--output", type=Path, default=Path("build/auto-mixed/diagnostics-events.jsonl"))
    args = parser.parse_args()
    result = subprocess.run([
        "/usr/bin/log", "show", "--style", "ndjson", "--last", args.last,
        "--predicate", 'subsystem == "dev.azookey.inputmethod.azooKeyMixed" AND category == "MixedDiagnostics"',
    ], check=True, text=True, capture_output=True)
    events = []
    for line in result.stdout.splitlines():
        try:
            item = json.loads(line)
            message = json.loads(item.get("eventMessage", ""))
        except (ValueError, TypeError):
            continue
        if message.get("schema") != 1 or not isinstance(message.get("fields"), dict):
            continue
        events.append({"timestamp": item.get("timestamp"), "pid": item.get("processID"), **message})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("".join(json.dumps(event, ensure_ascii=False) + "\n" for event in events))
    print(f"Collected {len(events)} state-only events to {args.output}")
    counts = {}
    for event in events:
        counts[event["event"]] = counts.get(event["event"], 0) + 1
    print(json.dumps(counts, sort_keys=True))


if __name__ == "__main__":
    main()
