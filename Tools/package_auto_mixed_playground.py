#!/usr/bin/env python3
"""Package a local development app. Linked runtime assets stay inside this checkout."""
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    binary_dir = root / "build/auto-mixed/core/release"
    model = Path(sys.argv[1]).resolve()
    resources = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None
    app = root / "build/auto-mixed/AutoMixedPlayground.app"
    macos = app / "Contents/MacOS"
    assets = app / "Contents/Resources"
    macos.mkdir(parents=True, exist_ok=True)
    assets.mkdir(parents=True, exist_ok=True)
    def copy_atomically(source, target):
        with tempfile.NamedTemporaryFile(dir=target.parent) as temporary:
            shutil.copy2(source, temporary.name)
            # Replace the directory entry without overwriting a running executable's inode.
            target_link = target.with_suffix(".new")
            if target_link.exists():
                raise ValueError(f"Unfinished package output exists: {target_link.name}")
            target_link.hardlink_to(temporary.name)
            target_link.replace(target)

    copy_atomically(binary_dir / "AutoMixedPlayground", macos / "AutoMixedPlayground")
    copy_atomically(model, assets / "language-model.json")

    def link(source, target):
        if target.is_symlink():
            target.unlink()
        elif target.exists():
            raise ValueError(f"Refusing to replace an unrelated file: {target.name}")
        target.symlink_to(source.resolve(), target_is_directory=source.is_dir())

    link(binary_dir / "llama.framework", macos / "llama.framework")
    for bundle in binary_dir.glob("*.bundle"):
        link(bundle, app / bundle.name)
    model_link = assets / "ggml-model-Q5_K_M.gguf"
    if resources:
        if not (resources / model_link.name).is_file():
            raise ValueError("GGUF resource is missing")
        for source in [resources / model_link.name, *resources.glob("lm_*.marisa")]:
            link(source, assets / source.name)
    elif model_link.is_symlink():
        model_link.unlink()
    with (app / "Contents/Info.plist").open("wb") as destination:
        plistlib.dump(dict(CFBundleExecutable="AutoMixedPlayground", CFBundleIdentifier="dev.azookey.AutoMixedPlayground",
                          CFBundleName="AutoMixedPlayground", CFBundleDisplayName="日英混在入力 · 試用版",
                          CFBundlePackageType="APPL", CFBundleVersion="1", CFBundleShortVersionString="0.1",
                          LSMinimumSystemVersion="13.0", NSHighResolutionCapable=True,
                          NSPrincipalClass="NSApplication", NSQuitAlwaysKeepsWindows=False), destination)
    print("Created build/auto-mixed/AutoMixedPlayground.app")


if __name__ == "__main__":
    main()
