"""Numerical specification only; not an IME, a trained model, or a romanization engine.

Feature-spec v1 uses Python string indices as Unicode-scalar indices.
Unpaired surrogate code points are rejected. Swift must use unicodeScalars.
"""
from __future__ import annotations

import json
import math
from collections import Counter
from typing import Any, Iterable, Mapping, Sequence

FEATURE_SPEC_VERSION = "anchored-char-v1"
LABELS = ("RAW", "JA_ROMAN")


def check_scalar_text(text: str) -> None:
    if not isinstance(text, str):
        raise TypeError("text must be str")
    if any(0xD800 <= ord(c) <= 0xDFFF for c in text):
        raise ValueError("unpaired surrogate is not a Unicode scalar")


def utf8_sorted(values: Iterable[str]) -> list[str]:
    return sorted(values, key=lambda value: value.encode("utf-8"))


def _symbol(text: str, position: int) -> list[str]:
    if position < 0:
        return ["BOS"]
    if position >= len(text):
        return ["EOS"]
    c = text[position]
    if "A" <= c <= "Z":
        c = chr(ord(c) + 32)
    return ["CHAR", c]


def _shape(text: str, position: int) -> str:
    if position < 0:
        return "bos"
    if position >= len(text):
        return "eos"
    c = text[position]
    if "A" <= c <= "Z":
        return "upper"
    if "a" <= c <= "z":
        return "lower"
    if "0" <= c <= "9":
        return "digit"
    return "ascii_other" if ord(c) < 128 else "non_ascii"


def _key(parts: list[Any]) -> str:
    # JSON escaping disambiguates a literal "BOS" from the BOS sentinel.
    # Swift must match ASCII JSON escaping including lowercase hex escapes.
    return json.dumps(parts, ensure_ascii=True, separators=(",", ":"))


def anchored_features(text: str, index: int) -> list[str]:
    """Return the distinct feature keys for one Unicode scalar position."""
    check_scalar_text(text)
    if not 0 <= index < len(text):
        raise IndexError("index must address an existing Unicode scalar")
    keys: set[str] = set()
    for offset in range(-8, 9):
        keys.add(_key(["char", offset, _symbol(text, index + offset)]))
        keys.add(_key(["shape", offset, _shape(text, index + offset)]))
    for length in (2, 3, 4):
        for start in range(-4, 5):
            symbols = [_symbol(text, index + start + k) for k in range(length)]
            keys.add(_key(["ngram", length, start, symbols]))
    return utf8_sorted(keys)


def build_vocabulary(feature_rows: Iterable[Sequence[str]], limit: int = 32768) -> list[str]:
    """Train-only rows: rank by row-frequency, break ties in UTF-8 byte order."""
    if limit < 1:
        raise ValueError("limit must be positive")
    frequency: Counter[str] = Counter()
    for row in feature_rows:
        frequency.update(set(row))
    selected = sorted(frequency, key=lambda x: (-frequency[x], x.encode("utf-8")))[:limit]
    return utf8_sorted(selected)


def stable_sigmoid(value: float) -> float:
    if not math.isfinite(value):
        raise ValueError("logit must be finite")
    if value >= 0:
        return 1.0 / (1.0 + math.exp(-value))
    exp_value = math.exp(value)
    return exp_value / (1.0 + exp_value)


def validate_model(model: Mapping[str, Any], *, allow_fixture: bool = False) -> None:
    if model.get("schema_version") != 1:
        raise ValueError("unknown model schema version")
    if model.get("feature_spec_version") != FEATURE_SPEC_VERSION:
        raise ValueError("unknown feature specification")
    if model.get("positive_label") != "JA_ROMAN":
        raise ValueError("positive label must be JA_ROMAN")
    kind = model.get("kind")
    if kind != "production" and not (allow_fixture and kind == "fixture"):
        raise ValueError("production runtime rejects fixture models")
    vocab = model.get("vocabulary")
    weights = model.get("coefficients")
    if not isinstance(vocab, list) or not all(isinstance(v, str) for v in vocab):
        raise ValueError("vocabulary must be a string array")
    if len(vocab) != len(set(vocab)) or vocab != utf8_sorted(vocab):
        raise ValueError("vocabulary must be unique and UTF-8 sorted")
    if not isinstance(weights, list) or len(weights) != len(vocab):
        raise ValueError("one coefficient is required per vocabulary entry")
    if len(vocab) > 32768:
        raise ValueError("vocabulary exceeds v1 limit")
    calibration = model.get("calibration", {})
    numeric = weights + [model.get("intercept"), calibration.get("a"), calibration.get("c")]
    if any(isinstance(x, bool) or not isinstance(x, (int, float)) or not math.isfinite(x)
           for x in numeric):
        raise ValueError("coefficients, intercept, and calibration must be finite numbers")
    decoder = model.get("decoder", {})
    penalty = decoder.get("switch_penalty")
    if isinstance(penalty, bool) or not isinstance(penalty, (float, int)) or not math.isfinite(penalty) or penalty < 0:
        raise ValueError("invalid switching penalty")
    thresholds = model.get("thresholds", {})
    start, hold = thresholds.get("enter_ja"), thresholds.get("hold_ja")
    if any(isinstance(v, bool) or not isinstance(v, (float, int)) or not math.isfinite(v)
           for v in (start, hold)) or not 0 <= hold <= start <= 1:
        raise ValueError("expected 0 <= hold_ja <= enter_ja <= 1")


class LinearLanguageModel:
    """Float64 reference scoring. Validation and vocabulary indexing happen once."""

    def __init__(self, model: Mapping[str, Any], *, allow_fixture: bool = False) -> None:
        validate_model(model, allow_fixture=allow_fixture)
        self._index = {key: i for i, key in enumerate(model["vocabulary"])}
        self._weights = list(model["coefficients"])
        self._intercept = float(model["intercept"])
        self._a = float(model["calibration"]["a"])
        self._c = float(model["calibration"]["c"])

    def score(self, text: str, position: int) -> dict[str, Any]:
        features = anchored_features(text, position)
        active = sorted(self._index[key] for key in features if key in self._index)
        # Deterministic vocabulary-index accumulation order; no unordered reduce.
        logit = self._intercept
        for index in active:
            logit += self._weights[index]
        probability = stable_sigmoid(self._a * logit + self._c)
        return {"active_indices": active, "logit": logit, "p_ja": probability}


def viterbi(probabilities: Sequence[float], switch_penalty: float = 1.2,
            forced: Sequence[str | None] | None = None) -> list[str]:
    """Decode ONE contiguous block. Caller resets at literal/gap positions.

    Ties: stay in the same state; then lower predecessor index. Final state RAW
    wins ties. Masked positions never receive the incompatible state.
    """
    if not math.isfinite(switch_penalty) or switch_penalty < 0:
        raise ValueError("switch_penalty must be finite and nonnegative")
    if any(not math.isfinite(p) or p < 0 or p > 1 for p in probabilities):
        raise ValueError("probabilities must be finite and within [0,1]")
    n = len(probabilities)
    mask = list(forced) if forced is not None else [None] * n
    if len(mask) != n or any(m not in (None, *LABELS) for m in mask):
        raise ValueError("invalid mask")
    if not n:
        return []
    back: list[list[int]] = []
    previous: list[float] = []
    for i, p in enumerate(probabilities):
        p = min(max(p, 1e-7), 1 - 1e-7)
        emission = [-math.log1p(-p), -math.log(p)]
        current = [math.inf, math.inf]
        parents = [0, 0]
        for state in (0, 1):
            if mask[i] is not None and mask[i] != LABELS[state]:
                continue
            if i == 0:
                current[state] = emission[state]
                parents[state] = state
            else:
                options = [(previous[prev] + (0 if prev == state else switch_penalty),
                            0 if prev == state else 1, prev) for prev in (0, 1)]
                cost, _, parent = min(options)
                current[state] = cost + emission[state]
                parents[state] = parent
        previous = current
        back.append(parents)
    state = min((previous[s], s) for s in (0, 1))[1]
    path = [state]
    for i in range(n - 1, 0, -1):
        state = back[i][state]
        path.append(state)
    return [LABELS[s] for s in reversed(path)]


def validate_span_record(record: Mapping[str, Any]) -> None:
    required = ("id", "group_id", "split", "raw", "spans", "category", "provenance")
    if any(k not in record for k in required):
        raise ValueError("missing required record field")
    raw = record["raw"]
    check_scalar_text(raw)
    if not raw or len(raw) > 256:
        raise ValueError("fixture raw length must be 1..256 scalars")
    if record["split"] not in ("train", "dev", "calibration", "test", "fixture"):
        raise ValueError("invalid split")
    cursor = 0
    for span in record["spans"]:
        start, end, label = span.get("start"), span.get("end"), span.get("label")
        if isinstance(start, bool) or isinstance(end, bool) or not isinstance(start, int) or not isinstance(end, int):
            raise ValueError("span offsets must be integers")
        if start != cursor or not start < end <= len(raw):
            raise ValueError("spans must be contiguous, nonempty and in range")
        if label not in ("RAW", "JA_ROMAN", "GAP", "LITERAL", "AMBIGUOUS"):
            raise ValueError("invalid label")
        if label == "GAP" and any(c != " " for c in raw[start:end]):
            raise ValueError("GAP is U+0020 in the initial contract")
        cursor = end
    if cursor != len(raw):
        raise ValueError("spans must cover the whole raw text")


def validate_record_set(records: Sequence[Mapping[str, Any]]) -> None:
    ids: set[str] = set()
    groups: dict[str, str] = {}
    for record in records:
        validate_span_record(record)
        if record["id"] in ids:
            raise ValueError("duplicate record id")
        ids.add(record["id"])
        group, split = record["group_id"], record["split"]
        if group in groups and groups[group] != split:
            raise ValueError("group leaks across splits")
        groups[group] = split
