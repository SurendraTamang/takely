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
if [[ -d Packages/TakelyPro/Server/license ]] && command -v node >/dev/null; then
    echo "==> license server tests"
    (cd Packages/TakelyPro/Server/license && node --test --no-warnings)
fi

if [[ -f project.yml ]]; then
    echo "==> xcodebuild"
    # With Takely Pro when it's here (the private checkout), else the open-source app.
    if [[ -d Packages/TakelyPro ]]; then xcodegen generate --quiet --spec project.pro.yml; else xcodegen generate --quiet; fi
    xcodebuild -project Takely.xcodeproj -scheme Takely -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath build build -quiet
    # This build only checks that the app compiles. Left registered, it's one more Takely that macOS may tie a privacy
    # permission (Screen Recording…) to instead of the copy being tested: unregister it.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u build/Build/Products/Debug/Takely.app 2>/dev/null || true
fi
echo "==> all checks passed"
