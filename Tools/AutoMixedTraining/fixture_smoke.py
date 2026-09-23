"""Exercise every CLI with fixture-only data; all artifacts stay in a new build directory."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

from pipeline_io import HERE, ROOT, read, require, write_new


def run(output):
    output = Path(output).resolve()
    require(not output.exists(), "smoke output already exists")
    output.mkdir(parents=True)
    cli = [sys.executable, str(HERE / "pipeline.py")]
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")

    def command(name, arguments):
        with (output / (name + ".log")).open("wb") as log:
            result = subprocess.run(arguments, cwd=ROOT, env=env, stdout=log, stderr=log)
        require(result.returncode == 0, "fixture smoke command failed: " + name)

    command("validate", cli + ["validate-data", "--manifest", str(HERE / "fixture_manifest.json")])
    dataset = output / "dataset.json"
    command("build", cli + ["build-dataset", "--manifest", str(HERE / "fixture_manifest.json"), "--output", str(dataset)])
    exported = []
    for version in ("anchored-char-v1", "anchored-context-v2"):
        folder = output / version
        config = read(HERE / "training_config.json")
        config["feature_spec_version"] = version
        write_new(folder / "config.json", config)
        fitted, calibrated = folder / "fitted.json", folder / "calibrated.json"
        command(version + "-train", cli + ["train", "--config", str(folder / "config.json"), "--data", str(dataset), "--output", str(fitted)])
        command(version + "-calibrate", cli + ["calibrate", "--model", str(fitted), "--data", str(dataset), "--output", str(calibrated)])
        command(version + "-export", cli + ["export", "--model", str(calibrated), "--output", str(folder / "export")])
        command(version + "-evaluate", cli + ["evaluate", "--model", str(calibrated), "--test", str(dataset), "--traces", "--output", str(folder / "evaluation.json")])
        require(read(folder / "export/model.json")["kind"] == "fixture", "fixture export lost its kind")
        require(read(folder / "evaluation.json")["evaluation_kind"] == "fixture_smoke_only", "fixture metrics mislabeled")
        exported.append(str(folder / "export"))
    env["AUTO_MIXED_TRAINING_DATASET"] = str(dataset)
    env["AUTO_MIXED_TRAINING_EXPORTS"] = ":".join(exported)
    command("python-tests", [sys.executable, "-m", "unittest", "discover", "-s", "Tools/AutoMixedTraining", "-p", "test_*.py", "-v"])
    command("swift-parity", ["sh", "Tools/test_auto_mixed_parity.sh"])
    print("Fixture-only CLI smoke, Python tests, and trained v1/v2 Swift parity passed. No model quality claim.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    run(arguments.output)
