#!/bin/bash
# Kaiju build loop -> build.log.  Run:  ./build.sh
cd "$(dirname "$0")"
LOG=build.log
: > "$LOG"

echo "=== Kaiju app build (xcodebuild, warm DerivedData) ===" >> "$LOG"
xcodebuild -project Kaiju.xcodeproj -scheme Kaiju -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -skipMacroValidation \
  build >> "$LOG" 2>&1
echo "[exit: $?]" >> "$LOG"

echo "" >> "$LOG"
echo "=== ERROR SUMMARY ===" >> "$LOG"
grep -E "error:" "$LOG" | sed 's|.*/Kaiju/||' | sort -u >> "$LOG"
echo "=== END SUMMARY ===" >> "$LOG"

echo "Done. errors: $(grep -c 'error:' "$LOG")"
