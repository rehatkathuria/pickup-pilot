#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/work/clang-cache"
mkdir -p work outputs
swift test --disable-sandbox --build-system native --scratch-path work/build-native --enable-code-coverage "$@" 2>&1 | tee work/latest-test.log
# A native test helper can terminate early with exit zero; require Swift Testing's full completion summary as well as the process exit status.
/usr/bin/grep -Eq "Test run with [0-9]+ tests.*passed" work/latest-test.log
python3 scripts/coverage-report.py
