#!/bin/sh
# Isolated process, no InputMethodKit registration or changes to the installed IME.
set -eu
cd "$(dirname "$0")/.."
task_root="$PWD"
task_model="${1:-build/auto-mixed/independent-thresholds-refined-20260924/export/model.json}"
if [ ! -r "$task_model" ]; then
    echo '学習済みmodel.jsonがありません。第1引数にモデルを指定してください。' >&2
    exit 1
fi
export CLANG_MODULE_CACHE_PATH="$task_root/build/auto-mixed/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_root/build/auto-mixed/swift-cache"
swift build --package-path Core --scratch-path "$task_root/build/auto-mixed/core" \
    --cache-path "$task_root/build/auto-mixed/cache" --disable-sandbox --build-system native \
    -c release --product AutoMixedPlayground
if [ "$#" -ge 2 ]; then
    python3 Tools/package_auto_mixed_playground.py "$task_model" "$2"
elif [ -r build/auto-mixed/runtime-resources/ggml-model-Q5_K_M.gguf ]; then
    python3 Tools/package_auto_mixed_playground.py "$task_model" build/auto-mixed/runtime-resources
else
    python3 Tools/package_auto_mixed_playground.py "$task_model"
fi
# Direct launch is verified on the development host; LaunchServices startup can stall in dyld.
exec "$task_root/build/auto-mixed/AutoMixedPlayground.app/Contents/MacOS/AutoMixedPlayground"
