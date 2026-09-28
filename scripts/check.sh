#!/usr/bin/env bash
# Local quality gate: lint, test, build. Run before every commit.
set -euo pipefail
cd "$(dirname "$0")/.."

paths=()
for p in App Packages/TakelyKit/Sources Packages/TakelyKit/Tests; do
    [[ -d "$p" ]] && paths+=("$p")
done
if ((${#paths[@]})); then
    echo "==> swift-format lint"
    xcrun swift-format lint --strict -r "${paths[@]}"
fi

# Tests write temp bundles under one folder; clear it each run.
rm -rf "${TMPDIR:-/tmp}/takely-tests"

echo "==> swift test"
swift test --package-path Packages/TakelyKit --quiet

if [[ -f project.yml ]]; then
    echo "==> xcodebuild"
    xcodegen generate --quiet
    xcodebuild -project Takely.xcodeproj -scheme Takely -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath build build -quiet
fi
echo "==> all checks passed"
