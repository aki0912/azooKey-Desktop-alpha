#!/bin/sh
# Python runs only in this test harness, never in the input method.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/auto-mixed
PYTHONDONTWRITEBYTECODE=1 python3 Tools/generate_auto_mixed_parity.py > build/auto-mixed/reference-parity.json
AUTO_MIXED_PARITY_PATH="$PWD/build/auto-mixed/reference-parity.json" \
    sh Tools/test_auto_mixed_core.sh "$@"
