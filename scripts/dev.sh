#!/bin/zsh
# Build/run/test Dexxer without opening Xcode.
# Usage: scripts/dev.sh [build|run|test|clean]
set -euo pipefail

# xcode-select points at CommandLineTools; use full Xcode for xcodebuild.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

ROOT="${0:A:h:h}"
PROJECT="$ROOT/Dexxer.xcodeproj"
SCHEME=Dexxer
# Build into Xcode's default DerivedData (not under Desktop: iCloud's extended
# attributes break codesign, and xcode-build-server indexes from there).
XCB=(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug -destination 'platform=macOS')

build() {
  "${XCB[@]}" build 2>&1 | tee /tmp/dexxer-build.log | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true
  grep -q "BUILD SUCCEEDED" /tmp/dexxer-build.log
}

app_path() {
  "${XCB[@]}" -showBuildSettings 2>/dev/null | awk -F' = ' '/ TARGET_BUILD_DIR =/{d=$2} / FULL_PRODUCT_NAME =/{n=$2} END{print d"/"n}'
}

case "${1:-build}" in
  build) build ;;
  run)
    build
    pkill -x Dexxer 2>/dev/null || true
    APP="$(app_path)"
    echo "Launching $APP (logs below, Ctrl-C to stop)"
    "$APP/Contents/MacOS/Dexxer"
    ;;
  test) "${XCB[@]}" test -only-testing:DexxerTests 2>&1 | grep -E "error:|Test [Cc]ase.*(passed|failed)|TEST (SUCCEEDED|FAILED)|Executed" ;;
  clean) "${XCB[@]}" clean >/dev/null && echo "Cleaned" ;;
  *) echo "Usage: $0 [build|run|test|clean]"; exit 1 ;;
esac
