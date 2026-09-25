#!/bin/sh
# Test the same pure Core sources without fetching or linking the Zenzai dependency.
# This is not a replacement for the repository's complete Core and IMK test suites.
set -eu
cd "$(dirname "$0")/.."
task_root="$PWD"
task_package="$task_root/build/auto-mixed/pure-package"
mkdir -p "$task_package/Sources" "$task_package/Tests"
ln -sfn "$task_root/Core/Sources/Core/AutoMixed" "$task_package/Sources/Core"
ln -sfn "$task_root/Core/Tests/CoreTests/AutoMixedTests" "$task_package/Tests/CoreTests"
cat > "$task_package/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "AutoMixedPureCoreTests",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "Core"),
        .testTarget(name: "CoreTests", dependencies: ["Core"])
    ]
)
SWIFT
export CLANG_MODULE_CACHE_PATH="$task_root/build/auto-mixed/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_root/build/auto-mixed/swift-cache"
swift test --package-path "$task_package" \
    --scratch-path "$task_root/build/auto-mixed/pure-build" \
    --cache-path "$task_root/build/auto-mixed/cache" --disable-sandbox "$@"
