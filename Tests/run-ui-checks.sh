#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
device="${1:-}"
if [[ -z "$device" ]]; then
    device="$(xcrun simctl list devices available -j | ruby -rjson -e '
        devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
        phone = devices.find { |d| d.fetch("name").start_with?("iPhone") }
        abort "No available iPhone simulator. Install an iOS simulator runtime in Xcode." unless phone
        puts phone.fetch("udid")')"
fi
output="${PATCO_UI_OUTPUT:-$(mktemp -d /tmp/patco-ui-results.XXXXXX)}"
mkdir -p "$output"
print "UI test results: $output/JourneyUITests.xcresult"
xcodebuild -project NextPATCOTrain.xcodeproj -scheme NextPATCOTrain \
    -configuration Debug -destination "id=$device" \
    -derivedDataPath "${PATCO_UI_BUILD:-$output/Build}" \
    -resultBundlePath "$output/JourneyUITests.xcresult" \
    -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
