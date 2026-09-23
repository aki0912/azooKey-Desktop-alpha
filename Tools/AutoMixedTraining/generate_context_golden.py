"""Emit deterministic numerical fixtures from authored strings, never from app input.

The saved model contains artificial coefficients and always has kind=fixture.
"""
import json
from pathlib import Path
import sys

from context_features import FEATURE_SPEC_VERSION, contextual_features, score

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def vectors():
    contexts = [None, "", "I ", "明日", "これは ", "I", "é", "e\u0301", "👩‍💻", "。", "カナ　",
                "X" * 40 + "A👩‍💻e\u0301 ", ''.join(chr(i) for i in range(128)) + '\U0010ffff']
    for raw in ["made", "no", "to", "name", " made", "made in Japan", "ashitamade", "A/é👩‍💻"]:
        for context in contexts:
            for index in range(len(raw)):
                yield dict(raw=raw, index=index, left_context=context)
    for raw in ["made", "ashitamade", "made in Japan"]:
        for end in range(1, len(raw) + 1):
            yield dict(raw=raw[:end], index=end - 1, left_context="I ")
    # Every ASCII escape and script range endpoint is exercised as the immediate predecessor.
    boundaries = list(range(128)) + [0x3000, 0x3001, 0x3002, 0x3040, 0x3041, 0x3096, 0x3097,
        0x30a0, 0x30a1, 0x30fa, 0x30fb, 0x30fc, 0x30fd, 0xff65, 0xff66, 0xff9f, 0xffa0,
        0x33ff, 0x3400, 0x4dbf, 0x4dc0, 0x4dff, 0x4e00, 0x9fff, 0xa000, 0xf8ff,
        0xf900, 0xfaff, 0xfb00, 0x1ffff, 0x20000, 0x323af, 0x323b0, 0xff01, 0xff1f]
    for value in boundaries:
        yield dict(raw="made", index=0, left_context=chr(value))


def make_golden(compact=False):
    model = json.loads((FIXTURES / "language_model_v2_fixture.json").read_text())
    assert model["kind"] == "fixture"
    result = []
    for vector in vectors():
        raw, index, context = vector["raw"], vector["index"], vector["left_context"]
        result.append(dict(vector, features=contextual_features(raw, index, context),
                           **score(model, raw, index, context)))
    if compact:
        result = [result[i * (len(result) - 1) // 127] for i in range(128)]
    return dict(feature_spec_version=FEATURE_SPEC_VERSION, kind="fixture", vectors=result)


if __name__ == "__main__":
    json.dump(make_golden(compact="--golden" in sys.argv[1:]), sys.stdout,
              ensure_ascii=True, allow_nan=False, separators=(",", ":"))
    sys.stdout.write("\n")
