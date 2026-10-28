#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen' >&2; exit 1; }
xcodegen generate
if [[ -z "${SIMULATOR_ID:-}" ]]; then
  SIMULATOR_ID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
items = [(runtime, device) for runtime, devices in json.load(sys.stdin)["devices"].items()
         if ".iOS-" in runtime for device in devices if device["name"].startswith("iPhone")]
items.sort(key=lambda item: (item[1]["state"] == "Booted", tuple(map(int, item[0].split("iOS-")[1].split("-")))), reverse=True)
if not items:
    sys.exit("No available iPhone simulator. Install an iOS runtime in Xcode.")
print(items[0][1]["udid"])
')
fi
exec xcodebuild -project Whereabouts.xcodeproj -scheme Whereabouts \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO "$@"
