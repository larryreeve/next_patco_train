#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$(mktemp -d /tmp/patco-checks.XXXXXX)"
trap 'rm -rf "$build_root"' EXIT
cd "$repo_root"

for test in Tests/*Check.swift; do
    name="${test:t:r}"
    sources=(NextPATCOTrain/PATCOModels.swift)
    if [[ "$name" == SavedRoutesCheck ]]; then
        sources+=(NextPATCOTrain/SavedRouteStore.swift)
    fi
    if [[ "$name" == UXRecoveryCheck ]]; then
        sources+=(NextPATCOTrain/PATCOAlertProvider.swift NextPATCOTrain/SavedRouteStore.swift)
    fi
    if [[ "$name" == LocationProviderCheck || "$name" == AppLocationIntegrationCheck ]]; then
        sources+=(NextPATCOTrain/LocationProvider.swift Tests/Support/LocationTestDoubles.swift)
    fi
    if [[ "$name" == SpecialScheduleParsingCheck ]]; then
        sources+=(NextPATCOTrain/PATCOSpecialScheduleProvider.swift)
    fi
    xcrun swiftc -module-cache-path "$build_root/module-cache" "${sources[@]}" "$test" -o "$build_root/$name"
    "$build_root/$name"
done
