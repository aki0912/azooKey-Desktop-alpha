"""Run the existing Swift detector and pinned Converter without launching an IME."""
import os
from pathlib import Path
import platform
import subprocess
import tempfile

from pipeline_io import ROOT, digest, encoded, read, require


def validate_in_swift(rows, originals):
    requests = []
    for row in rows:
        pairs = []
        record = row["record"]
        if row["augmentation"] == "roman_variant":
            original = originals[row["original_id"]]
            for left, right in zip(original["spans"], record["spans"]):
                if left["label"] == "JA_ROMAN":
                    a = original["raw"][left["start"]:left["end"]]
                    b = record["raw"][right["start"]:right["end"]]
                    if a != b:
                        pairs.append(dict(original=a, variant=b))
        requests.append(dict(raw=record["raw"], roman_pairs=pairs))
    work = ROOT / "build/auto-mixed"
    work.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="training-validation-", dir=work) as temporary:
        request, response = Path(temporary) / "request.json", Path(temporary) / "response.json"
        request.write_bytes(encoded(dict(rows=requests)))
        environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work / "clang-cache"),
                           SWIFTPM_MODULECACHE_OVERRIDE=str(work / "swift-cache"),
                           AUTO_MIXED_TRAINING_REQUEST=str(request), AUTO_MIXED_TRAINING_RESPONSE=str(response))
        command = ["swift", "test", "--package-path", "Core", "--scratch-path", str(work / "core"),
                   "--cache-path", str(work / "cache"), "--disable-sandbox", "--filter", "AutoMixedTrainingBridgeTests"]
        if platform.system() == "Darwin":
            command += ["--build-system", "native"]
        # Diagnostics go to an isolated build log; test assertions never interpolate input text.
        with (work / "training-swift-validation.log").open("wb") as log:
            result = subprocess.run(command, cwd=ROOT, env=environment, stdout=log, stderr=log, timeout=240)
        require(result.returncode == 0 and response.is_file(), "Swift input validation failed; see build log")
        payload = read(response)
        require(payload["request_sha256"] == digest(request.read_bytes()), "Swift validation response mismatch")
        require(len(payload["protections"]) == len(rows), "Swift validation row count mismatch")
        for row, mask in zip(rows, payload["protections"]):
            require(len(mask) == len(row["record"]["raw"]) and set(mask) <= {"inferred", "raw", "literal", "gap"},
                    "invalid Swift protection mask")
            row["protections"] = mask
