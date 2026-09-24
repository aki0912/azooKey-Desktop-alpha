"""Build a local, side-by-side azooKey Mixed app. Does not install or register it."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
from prepare_auto_mixed_ime_build import prepare, sha256, RESOURCE_NAMES

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/auto-mixed"
OUTPUT = BUILD / "mixed-ime"
BUNDLE_ID = "dev.azookey.inputmethod.azooKeyMixed"
SERVICE = BUNDLE_ID + ".ConverterServer"


def run(*args, env=None):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, env=env, check=True)


def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value, sort_keys=False))


def profile_info():
    value = plistlib.loads((ROOT / "azooKeyMac/Info.plist").read_bytes())
    modes = value["ComponentInputModeDict"]["tsInputModeListKey"]
    for key, suffix in [("com.apple.inputmethod.Japanese", "Japanese"), ("com.apple.inputmethod.Roman", "Roman")]:
        modes[key]["TISInputSourceID"] = BUNDLE_ID + "." + suffix
    automatic = dict(modes["com.apple.inputmethod.Japanese"])
    for key in ["tsInputModeKeyEquivalentModifiersKey", "tsInputModeKeyEquivalentKey", "tsInputModeJISKeyboardShortcutKey"]:
        automatic.pop(key, None)
    automatic["TISInputSourceID"] = BUNDLE_ID + ".Automatic"
    automatic["tsInputModePrimaryInScriptKey"] = False
    for key in ["tsInputModePaletteIconFileKey", "tsInputModeAlternateMenuIconFileKey", "tsInputModeMenuIconFileKey", "tsInputMethodAlternateIconFileKey"]:
        automatic[key] = "auto.tiff"
    modes[BUNDLE_ID + ".Automatic"] = automatic
    value["ComponentInputModeDict"]["tsVisibleInputModeOrderedArrayKey"] = [BUNDLE_ID + ".Automatic", "com.apple.inputmethod.Japanese", "com.apple.inputmethod.Roman"]
    value["CFBundleDisplayName"] = "azooKey Mixed"
    value["CFBundleName"] = "azooKey Mixed"
    value["CFBundleLocalizations"] = ["ja", "en"]
    value["AzooKeyMixedLocalBuild"] = True
    return value


@contextmanager
def temporary_resources(resources):
    receipt = json.loads((resources / "receipt.json").read_text())
    if {item["filename"] for item in receipt} != RESOURCE_NAMES or len(receipt) != 5:
        raise ValueError("Expected the verified five-file resource receipt")
    created = []
    try:
        for item in receipt:
            source = resources / item["filename"]
            if source.stat().st_size != item["bytes"] or sha256(source) != item["sha256"]:
                raise ValueError("Resource checksum mismatch")
            subdirectory = "gguf" if source.suffix == ".gguf" else "base_n5_lm"
            target = ROOT / "azooKeyMac/Resources" / subdirectory / source.name
            if target.exists() or target.is_symlink():
                if not target.is_file() or sha256(target) != item["sha256"]:
                    raise ValueError("Existing source resource differs; refusing to replace it")
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(source)
                created.append((target, source))
        yield
    finally:
        for target, source in created:
            if target.is_symlink() and target.resolve() == source:
                target.unlink()


def sign_app(app):
    helper_root = app / "Contents/Helpers/ConverterServer"
    for bundle in helper_root.glob("*.bundle"):
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        info["CFBundleIdentifier"] = SERVICE + ".Resource." + bundle.stem.replace("_", "-")
        write_plist(bundle / "Info.plist", info)
        run("codesign", "--force", "--sign", "-", "--timestamp=none", bundle)
    run("codesign", "--force", "--sign", "-", "--timestamp=none", "--identifier", SERVICE, helper_root / "ConverterServer")
    for framework in (app / "Contents/Frameworks").glob("*.framework"):
        run("codesign", "--force", "--sign", "-", "--timestamp=none", framework)
    run("codesign", "--force", "--sign", "-", "--timestamp=none", "--entitlements", OUTPUT / "local.entitlements", app)
    run("codesign", "--verify", "--deep", "--strict", app)


def build(model, resources):
    model, resources = model.resolve(), resources.resolve()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    write_plist(OUTPUT / "Info.plist", profile_info())
    # No Developer ID / App Group provisioning is assumed for this local-only build.
    write_plist(OUTPUT / "local.entitlements", {})
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(BUILD / "clang-cache"),
               SWIFTPM_MODULECACHE_OVERRIDE=str(BUILD / "swift-cache"))
    run("swift", "build", "--package-path", "Core", "--scratch-path", BUILD / "core",
        "--cache-path", BUILD / "cache", "--disable-sandbox", "--build-system", "native", "--product", "ConverterServer", env=env)
    with temporary_resources(resources):
        run("xcodebuild", "build", "-project", "azooKeyMac.xcodeproj", "-scheme", "azooKeyMac",
            "-configuration", "Debug", "-destination", "platform=macOS,arch=arm64",
            "-derivedDataPath", BUILD / "mixed-derived", "-clonedSourcePackagesDirPath", BUILD / "xcode-packages",
            "-disableAutomaticPackageResolution", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
            "ENABLE_APP_SANDBOX=NO", "ENABLE_HARDENED_RUNTIME=NO", "ENABLE_DEBUG_DYLIB=NO", "ENABLE_PREVIEWS=NO",
            "AZOOKEY_APP_PRODUCT_NAME=azooKeyMixed", "AZOOKEY_APP_BUNDLE_IDENTIFIER=" + BUNDLE_ID,
            "AZOOKEY_APP_INFO_PLIST=" + str(OUTPUT / "Info.plist"),
            "AZOOKEY_PREBUILT_CONVERTER_SERVER_DIR=" + str(BUILD / "core/debug"), env=env)
    app = OUTPUT / "azooKeyMixed.app"
    if app.is_symlink():
        raise ValueError("Refusing to replace an app symlink")
    if app.exists():
        old = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if old.get("CFBundleIdentifier") != BUNDLE_ID:
            raise ValueError("Refusing to replace another app")
        shutil.rmtree(app)
    run("ditto", BUILD / "mixed-derived/Build/Products/Debug/azooKeyMixed.app", app)
    prepare(app, model, resources)
    for language in ["ja", "en"]:
        write_plist(app / "Contents/Resources" / (language + ".lproj") / "InfoPlist.strings", {
            "CFBundleName": "azooKey Mixed", "CFBundleDisplayName": "azooKey Mixed",
            "com.apple.inputmethod.Japanese": "azooKey Mixed（日本語）",
            "com.apple.inputmethod.Roman": "azooKey Mixed（英数）",
            BUNDLE_ID + ".Automatic": "azooKey Mixed（自動）",
        })
    run("swift", "Tools/generate_mixed_ime_icon.swift", app / "Contents/Resources/auto.tiff", env=env)
    sign_app(app)
    run("swiftc", "Tools/MixedIMEControl.swift", "-o", OUTPUT / "MixedIMEControl", env=env)
    print("Built build/auto-mixed/mixed-ime/azooKeyMixed.app (local ad-hoc signature; not notarized).")
    print("No installation, registration, or changes to the standard IME performed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, default=BUILD / "independent-thresholds-refined-20260924/export/model.json")
    parser.add_argument("--resources", type=Path, default=BUILD / "runtime-resources")
    args = parser.parse_args()
    build(args.model, args.resources)
