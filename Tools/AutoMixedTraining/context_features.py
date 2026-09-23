"""v2 numerical reference; only authored fixtures may be emitted by the test harness.

No runtime context collection or training CLI is implemented here.
"""
import json
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "docs/auto-mixed-old/reference"))
from auto_mixed_reference import (  # noqa: E402
    anchored_features, check_scalar_text, stable_sigmoid, validate_record_set,
)

FEATURE_SPEC_VERSION = "anchored-context-v2"
CONTEXT_LIMIT = 30


def key(value):
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"))


def fold(char):
    return chr(ord(char) + 32) if "A" <= char <= "Z" else char


def shape(char):
    value = ord(char)
    if 65 <= value <= 90:
        return "upper"
    if 97 <= value <= 122:
        return "lower"
    if 48 <= value <= 57:
        return "digit"
    if value in (*range(9, 14), 32, 0x3000):
        return "space"
    if (33 <= value <= 47 or 58 <= value <= 64 or 91 <= value <= 96 or 123 <= value <= 126
            or value in (0x3001, 0x3002, 0xff01, 0xff1f)):
        return "punctuation"
    if any(lo <= value <= hi for lo, hi in (
        (0x3041, 0x3096), (0x30a1, 0x30fa), (0x30fc, 0x30fc), (0xff66, 0xff9f),
        (0x3400, 0x4dbf), (0x4e00, 0x9fff), (0xf900, 0xfaff), (0x20000, 0x323af),
    )):
        return "japanese"
    return "ascii_other" if value < 128 else "non_ascii"


def contextual_features(raw, position, left_context=None):
    """None means unavailable; empty string means a successful empty read."""
    features = anchored_features(raw, position)
    if left_context is None:
        return sorted(features + [key(["ctx", "availability", "unavailable"])])
    check_scalar_text(left_context)
    context = left_context[-CONTEXT_LIMIT:]
    extra = [["ctx", "availability", "available"]]
    for distance in range(1, CONTEXT_LIMIT + 1):
        char = context[-distance] if distance <= len(context) else None
        extra.append(["ctx", "char", -distance, ["CHAR", fold(char)] if char is not None else ["BOS"]])
        extra.append(["ctx", "shape", -distance, shape(char) if char is not None else "bos"])
    extra.append(["ctx", "boundary", shape(context[-1]) if context else "empty"])
    for length in range(2, 5):
        if len(context) >= length:
            extra.append(["ctx", "suffix", length, [fold(c) for c in context[-length:]]])
    end = len(context)
    while end and shape(context[end - 1]) == "space":
        end -= 1
    start = end
    while start and ("A" <= context[start - 1] <= "Z" or "a" <= context[start - 1] <= "z"):
        start -= 1
    if start < end:
        extra.append(["ctx", "word", [fold(c) for c in context[start:end]]])
    return sorted(features + [key(value) for value in extra])


def score(model, raw, position, left_context=None):
    if (model["schema_version"], model["feature_spec_version"]) != (2, FEATURE_SPEC_VERSION):
        raise ValueError("v2 requires its own model artifact")
    indices = {value: i for i, value in enumerate(model["vocabulary"])}
    active = sorted(indices[f] for f in contextual_features(raw, position, left_context) if f in indices)
    logit = model["intercept"]
    for index in active:
        logit += model["coefficients"][index]
    if not math.isfinite(logit):
        raise ValueError("nonfinite logit")
    probability = stable_sigmoid(model["calibration"]["a"] * logit + model["calibration"]["c"])
    return dict(active_indices=active, logit=logit, p_ja=probability)


def record_context(record):
    available = record.get("context_available", False)
    if not isinstance(available, bool):
        raise ValueError("availability must be a boolean")
    if available:
        context = record.get("left_context")
        if not isinstance(context, str):
            raise ValueError("available requires text, including an empty string")
        check_scalar_text(context)
        if len(context) > CONTEXT_LIMIT:
            raise ValueError("authored dataset context exceeds the scalar limit")
        return context
    if "left_context" in record:
        raise ValueError("unavailable must not carry text")
    return None


def validate_context_records(records):
    validate_record_set(records)
    for record in records:
        record_context(record)
