"""Run the actual IMK boundary unit tests without launching an installed IME test host."""
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
build = root / "build/auto-mixed"
harness = build / "thin-client-harness"
tests = harness / "Tests"
tests.mkdir(parents=True, exist_ok=True)
for source in ["azooKeyMacTests/ThinClientInputPipelineTests.swift", "azooKeyMacTests/AutoMixedIMEClientTests.swift",
               "azooKeyMac/InputController/AutoMixedIMEClient.swift", "azooKeyMac/InputController/ConverterServerClient.swift"]:
    target = tests / Path(source).name
    if target.is_symlink() and target.resolve() == root / source:
        continue
    if target.exists() or target.is_symlink():
        raise ValueError("Refusing to replace an unrelated harness file")
    target.symlink_to(root / source)
# Match the application's SWIFT_VERSION=5.0, while Core retains its own Swift 6 mode.
(harness / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ThinClientHarness", platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../../Core")], targets: [
        .testTarget(name: "ThinClientTests", dependencies: [.product(name: "Core", package: "Core")],
            path: "Tests", swiftSettings: [.interoperabilityMode(.Cxx), .swiftLanguageMode(.v5)])])
''')
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(build / "clang-cache"),
           SWIFTPM_MODULECACHE_OVERRIDE=str(build / "swift-cache"))
subprocess.run(["swift", "test", "--package-path", str(harness), "--scratch-path", str(build / "thin-client-build"),
                "--cache-path", str(build / "cache"), "--disable-sandbox", "--build-system", "native"],
               cwd=root, env=env, check=True)
