"""Emit fresh test-only results from the unchanged numerical reference; never train weights."""
import json
from pathlib import Path
import random
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "docs/auto-mixed/reference"))
from auto_mixed_reference import (  # noqa: E402
    FEATURE_SPEC_VERSION, LinearLanguageModel, anchored_features, viterbi,
)

model_json = json.loads((root / "docs/auto-mixed/fixtures/language_model_fixture.json").read_text())
model = LinearLanguageModel(model_json, allow_fixture=True)
golden = json.loads((root / "docs/auto-mixed/fixtures/feature_golden.json").read_text())
positions = [(v["raw"], v["index"]) for v in golden["vectors"]]
escaping = "".join(chr(i) for i in range(128)) + "ée\u0301👩‍💻\U0010ffff"
positions += [(escaping, i) for i in range(len(escaping))]
for raw in ["kyouhaSwiftdeAPIwotataku", "https://example.net/a?q=1", "kan'i", "👩‍💻 desu"]:
    for end in range(1, len(raw) + 1):
        prefix = raw[:end]  # Recompute BOS/EOS, never use the completed sentence's future.
        positions.append((prefix, end - 1))
scores = [dict(raw=raw, index=i, features=anchored_features(raw, i), **model.score(raw, i))
          for raw, i in positions]

rng = random.Random(20260924)
cases = [([.5] * n, penalty, [None] * n) for n in range(9) for penalty in (0, .4, 1.2)]
for _ in range(300):
    n = rng.randrange(0, 17)
    ps = [rng.choice([0, 1e-12, .05, .3, .5, .7, .95, 1 - 1e-12, 1]) for _ in range(n)]
    penalty = rng.choice([0, .4, .8, 1.2, 2.0])
    mask = [rng.choice([None, None, "RAW", "JA_ROMAN"]) for _ in range(n)]
    cases.append((ps, penalty, mask))
# Also decode model probabilities on complete fixture strings.
for raw in sorted({v["raw"] for v in golden["vectors"]}):
    ps = [model.score(raw, i)["p_ja"] for i in range(len(raw))]
    cases.append((ps, model_json["decoder"]["switch_penalty"], [None] * len(ps)))
decoders = [dict(probabilities=ps, switch_penalty=penalty, forced=mask,
                 path=viterbi(ps, penalty, mask)) for ps, penalty, mask in cases]
json.dump(dict(feature_spec_version=FEATURE_SPEC_VERSION, scores=scores, decoders=decoders),
          sys.stdout, ensure_ascii=True, allow_nan=False, separators=(",", ":"))
sys.stdout.write("\n")
