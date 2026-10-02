#!/bin/zsh
# Builds both apps, installs Swiss Knife on the connected iPhone and the
# companion in /Applications, then starts the companion.
set -euo pipefail

cd "${0:A:h}/.."
build=".build"

xcodebuild -project SwissKnife.xcodeproj -scheme SwissKnife -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$build" -allowProvisioningUpdates -quiet build

devices=$(mktemp)
xcrun devicectl list devices --json-output "$devices" >/dev/null 2>&1 || true
device=$(python3 - "$devices" <<'PY'
import json, sys
try:
    found = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    found = []
ready = [d["identifier"] for d in found
         if d["hardwareProperties"].get("platform") == "iOS"
         and d["deviceProperties"].get("bootState") == "booted"
         and d["connectionProperties"].get("tunnelState") != "unavailable"]
print(ready[0] if ready else "")
PY
)
rm -f "$devices"
if [[ -n "$device" ]]; then
    xcrun devicectl device install app --device "$device" "$build/Build/Products/Release-iphoneos/SwissKnife.app"
else
    echo "No iPhone available, skipped installing on the phone." >&2
fi

xcodebuild -project SwissKnife.xcodeproj -scheme SwissKnifeMac -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$build" -allowProvisioningUpdates -quiet build

# The companion was called PhoneMouseHost before; that copy goes away.
pkill -x PhoneMouseHost || true
rm -rf /Applications/PhoneMouseHost.app
pkill -x "Swiss Knife" || true
ditto "$build/Build/Products/Release/Swiss Knife.app" "/Applications/Swiss Knife.app"
open "/Applications/Swiss Knife.app"
