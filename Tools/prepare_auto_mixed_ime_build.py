"""Prepare experimental resources only inside this checkout's ignored build directory."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


RESOURCE_NAMES = {
    "ggml-model-Q5_K_M.gguf", "lm_c_abc.marisa", "lm_r_xbx.marisa",
    "lm_u_abx.marisa", "lm_u_xbc.marisa",
}


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def prepare(app, model, resources):
    build = Path(__file__).resolve().parents[1] / "build"
    app = app.resolve()
    destination = (app / "Contents/Resources").resolve()
    if not app.is_relative_to(build.resolve()) or not destination.is_relative_to(app):
        raise ValueError("Output must be an app inside this checkout's build directory")
    if app.suffix != ".app" or not (app / "Contents/Info.plist").is_file() or not destination.is_dir():
        raise ValueError("Build the app before preparing resources")
    if model.stat().st_size > 5 * 1024 * 1024:
        raise ValueError("Model exceeds runtime size limit")
    value = json.loads(model.read_text())
    if value.get("kind") != "production" or (value.get("schema_version"), value.get("feature_spec_version")) not in {
        (1, "anchored-char-v1"), (2, "anchored-context-v2"),
    }:
        raise ValueError("A trained runtime export is required; fixtures are forbidden")
    receipt = json.loads((resources / "receipt.json").read_text())
    if {entry["filename"] for entry in receipt} != RESOURCE_NAMES or len(receipt) != len(RESOURCE_NAMES):
        raise ValueError("Resource receipt must identify exactly the five runtime files")
    for entry in receipt:
        source = resources / entry["filename"]
        if source.stat().st_size != entry["bytes"] or sha256(source) != entry["sha256"]:
            raise ValueError("Runtime resource checksum mismatch")
    copies = [(model, "auto-mixed-model.json")] + [(resources / name, name) for name in sorted(RESOURCE_NAMES)]
    marker = destination / "auto-mixed-experiment.json"
    for name in [name for _, name in copies] + [marker.name]:
        if (destination / name).is_symlink():
            raise ValueError("Refusing to replace resource symlinks")
    # Validate every input before changing the build output. Enable only after copies finish.
    marker.unlink(missing_ok=True)
    for source, name in copies:
        target = destination / name
        if not target.exists() or sha256(source) != sha256(target):
            shutil.copyfile(source, target)
    model_hash = sha256(destination / "auto-mixed-model.json")
    marker.write_text(json.dumps({"enabled": True, "modelSHA256": model_hash}, indent=2) + "\n")
    print("Experimental build resources prepared. No installation, registration, signing, or app launch performed.")
    print("Model SHA-256:", model_hash)
    print("Resource preparation does not certify model quality, app isolation, or IMK behavior.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--resources", required=True, type=Path)
    args = parser.parse_args()
    prepare(args.app, args.model, args.resources)
