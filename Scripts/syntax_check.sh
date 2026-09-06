#!/usr/bin/env bash
# Linux-side syntax check for the NaviAI iOS sources.
#
# Linux cannot type-check SwiftUI/UIKit sources (no Apple SDK), but
# `swiftc -parse` validates full Swift syntax of every file, which catches
# broken/truncated/unbalanced code early without needing macOS or Xcode.
#
# Usage: Scripts/syntax_check.sh            (check all Swift files)
#        Scripts/syntax_check.sh path/file.swift   (check specific files)
set -uo pipefail
cd "$(dirname "$0")/.."

if command -v swiftc > /dev/null 2>&1; then
    SWIFTC=swiftc
elif [ -x /opt/swift/usr/bin/swiftc ]; then
    SWIFTC=/opt/swift/usr/bin/swiftc
else
    echo "error: swiftc not found (install a Swift toolchain or extract it to /opt/swift)" >&2
    exit 2
fi

tmp_err="$(mktemp)"
trap 'rm -f "$tmp_err"' EXIT

if [ $# -gt 0 ]; then
    files=("$@")
else
    mapfile -d '' files < <(find NaviAI -name '*.swift' -print0 | sort -z)
fi

echo "Checking ${#files[@]} Swift file(s) with $SWIFTC -parse ..."
fail=0
for f in "${files[@]}"; do
    if ! "$SWIFTC" -parse "$f" -o /dev/null 2> "$tmp_err"; then
        fail=$((fail + 1))
        echo "--- FAIL: $f"
        sed 's/^/    /' "$tmp_err"
    fi
done

if [ "$fail" -eq 0 ]; then
    echo "✅ All ${#files[@]} file(s) parsed successfully."
    exit 0
fi
echo "❌ $fail file(s) failed to parse."
exit 1
