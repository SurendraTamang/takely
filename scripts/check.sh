#!/usr/bin/env bash
# Local quality gate: lint, test, build. Run before every commit.
set -euo pipefail
cd "$(dirname "$0")/.."

paths=()
for p in App Packages/TakelyKit/Sources Packages/TakelyKit/Tests Packages/TakelyPro/Sources Packages/TakelyPro/Tests; do
    [[ -d "$p" ]] && paths+=("$p")
done
if ((${#paths[@]})); then
    echo "==> swift-format lint"
    xcrun swift-format lint --strict -r "${paths[@]}"
fi

# Tests write temp bundles under one folder; clear it each run.
rm -rf "${TMPDIR:-/tmp}/takely-tests"

echo "==> swift test"
# Serial: parallel suites that encode/decode video can exhaust hardware video sessions ("Cannot Decode").
swift test --package-path Packages/TakelyKit --quiet --no-parallel
if [[ -d Packages/TakelyPro ]]; then
    swift test --package-path Packages/TakelyPro --quiet --no-parallel
fi

if [[ -f project.yml ]]; then
    echo "==> xcodebuild"
    xcodegen generate --quiet
    xcodebuild -project Takely.xcodeproj -scheme Takely -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath build build -quiet
fi
echo "==> all checks passed"
