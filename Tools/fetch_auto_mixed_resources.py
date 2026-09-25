#!/usr/bin/env python3
"""Fetch only the runtime assets pinned by the project's gitlinks, never training data."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "build/auto-mixed/runtime-resources"
ASSETS = [
    ("zenz-v3.2-small-gguf", "c67e03e07d215c869f591b274c1631170d3e11fe", "ggml-model-Q5_K_M.gguf", 73871936,
     "29c223d4c23327b80fd13ebb5ab2555057a46317997d5da391584ffbef0db673"),
    ("base_n5_lm", "160a305a89c033ac53a674baeac4470cf531a71b", "lm_c_abc.marisa", 20680344,
     "ab9cfb9b4231b1187934109776339001a9cb089a9d0fa8ed160c79508c8783a3"),
    ("base_n5_lm", "160a305a89c033ac53a674baeac4470cf531a71b", "lm_r_xbx.marisa", 3585808,
     "f9594d23e2f15a8e6d51811f15b23e23bfc7cefd24b8b1c06f3f0366ce5bf555"),
    ("base_n5_lm", "160a305a89c033ac53a674baeac4470cf531a71b", "lm_u_abx.marisa", 9820096,
     "6656bb6bea01f75a2156009b7b104adbd6bf897cff47635fd907215f2bc727e9"),
    ("base_n5_lm", "160a305a89c033ac53a674baeac4470cf531a71b", "lm_u_xbc.marisa", 10551760,
     "69f43384dc45fd16f45e19cbdf242e67f5f8433168dadfe2012abb7657d38041"),
]


def verify(path, size, checksum):
    if path.stat().st_size != size:
        raise ValueError(f"Size mismatch: {path.name}")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != checksum:
        raise ValueError(f"SHA256 mismatch: {path.name}; existing files are not replaced")


def main():
    DESTINATION.mkdir(parents=True, exist_ok=True)
    receipt = []
    for repository, revision, name, size, checksum in ASSETS:
        url = f"https://huggingface.co/Miwa-Keita/{repository}/resolve/{revision}/{name}"
        target = DESTINATION / name
        if target.exists():
            verify(target, size, checksum)
        else:
            with tempfile.NamedTemporaryFile(dir=DESTINATION, suffix=".part") as temporary:
                subprocess.run(["curl", "--fail", "--location", "--retry", "2", "--max-time", "180",
                                "--silent", "--show-error", "--output", temporary.name, url], check=True)
                verify(Path(temporary.name), size, checksum)
                # Link refuses to overwrite a concurrently created destination.
                target.hardlink_to(temporary.name)
        print(f"Verified {name} ({size} bytes)", flush=True)
        receipt.append(dict(url=url, revision=revision, filename=name, bytes=size, sha256=checksum))
    (DESTINATION / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
