# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Takely: a native macOS (26+, Apple silicon only) menu bar screen recorder in Swift 6 (strict concurrency), with a `takely` CLI and a `takely-mcp` MCP server so AI agents can record, demo and share. Open core: Takely Pro features live in a private `Packages/TakelyPro` package that is **not** in this repo; app code that uses them is behind `#if canImport(TakelyPro)` and must still build without it.

## Commands

Requires Xcode 26.3+ and `brew install xcodegen`. `Takely.xcodeproj`, `App/Info.plist` and `App/Takely.entitlements` are **generated** from `project.yml` — edit `project.yml`, never the generated files, then rerun `xcodegen generate`.

```bash
./scripts/check.sh            # quality gate (same as CI): swift-format lint --strict, tests (serial), xcodebuild
xcodegen generate             # regenerate the Xcode project
xcodebuild -project Takely.xcodeproj -scheme Takely -configuration Debug \
  -destination "platform=macOS,arch=arm64" -derivedDataPath build build
open build/Build/Products/Debug/Takely.app

xcrun swift-format lint --strict -r App Packages/TakelyKit/Sources Packages/TakelyKit/Tests
xcrun swift-format format -i -r <paths>    # fix formatting (.swift-format: 4 spaces, 140 cols)

# Tests (Swift Testing, not XCTest). Always --no-parallel: parallel suites that encode/decode
# video exhaust hardware video sessions ("Cannot Decode").
swift test --package-path Packages/TakelyKit --no-parallel
swift test --package-path Packages/TakelyKit --no-parallel --filter RenderKitTests          # one target
swift test --package-path Packages/TakelyKit --no-parallel --filter ExporterTests.concatenatesSegments   # one test

scripts/release.sh 1.0.0 --local   # local Release build + DMG in dist/1.0.0-local/
```

Tests write temp bundles under `$TMPDIR/takely-tests` (check.sh clears it). `Tests/TestSupport` provides synthetic sample buffers for capture/render tests.

Local builds are ad-hoc signed, so macOS drops Screen Recording permission on every rebuild: `tccutil reset ScreenCapture app.takely.Takely`, relaunch, re-grant. Or set `DEVELOPMENT_TEAM` / `CODE_SIGN_IDENTITY = Apple Development` in `Config/Local.xcconfig` (gitignored).

## Architecture

Engine is the `Packages/TakelyKit` SwiftPM package; `App/` is a thin SwiftUI/AppKit menu bar layer (`LSUIElement`) on top of it.

Module dependency graph (keep it this way):
- `ProjectKit` — no deps. The `.takely` package-directory format (`ProjectBundle`): manifest, segments, cursor, markers, transcript, non-destructive edits, blurs, narration. Each segment writes a sidecar *before* media so crashed segments are recoverable.
- `CaptureKit` → ProjectKit, `WebRTCAEC`. ScreenCaptureKit + camera sources → `FrameRouter` → `SegmentWriter` (one `.mov` per segment, one track per `TrackKind`). Echo cancellation via a prebuilt WebRTC AEC3 static xcframework in `Vendor/` (committed; only rebuild with `scripts/build-webrtc-apm.sh`).
- `RenderKit` → ProjectKit. Export: AVComposition + custom `TakelyCompositor` (camera bubble, blurs, zoom, captions), then `MovieFinisher` adds chapters/captions/metadata.
- `TakelyControl` — Foundation only (keeps the CLI small). `ControlRequest`/`ControlReply` JSON over a per-user Unix socket (`SocketServer`, one JSON line in/out, 0700 dir / 0600 socket, peer uid checked), plus `ControlURL` for `takely://` x-callback links.
- `AppCore` → ProjectKit, CaptureKit, RenderKit, TakelyControl. `RecordingController` is the single path every trigger (menu, hotkeys, quit, recovery, automation) uses to start/pause/stop, serialized by one busy guard. `AutomationCenter` funnels CLI, URL scheme and App Intents through one path. Also `RecoveryService`, `StorageGuard`, meeting detection, `PostProcessor`.
- `ShareKit` → ProjectKit. Hand-rolled SigV4 + multipart upload to the user's own S3-compatible bucket, plus the generated player page.
- `TakelyMCPKit` / `takely-mcp` → TakelyControl, ProjectKit, MCP swift-sdk. Stdio MCP server that talks to the running app over the **same control socket** as the CLI. `takely` executable is the CLI.

Testability seam: AppCore defines protocols (`RecordingSession`, `Exporting`, `RecordingFeedback`, `AutomationHost`) that the app implements with real ScreenCaptureKit/UI (e.g. `App/RecordingCoordinator.swift`, `App/Automation.swift`) and tests implement with fakes. Put logic in AppCore behind these protocols, not in `App/`.

Both `takely` and `takely-mcp` are built as separate XcodeGen `tool` targets and copied into `Takely.app/Contents/Helpers/` (not `Contents/MacOS`: case-insensitive FS would clash with the `Takely` executable).

## Safety invariants (agent/automation paths)

These are product promises, enforced in code — don't weaken them:
- `takely://` links are untrusted: callbacks never carry the video path/title and can't open files or pages; links ask before acting.
- Agent shares require user confirmation of preview frame, length and every published word; a decline is final for the agent. Uploaded file is a sealed copy, verified per part, remuxed with no metadata/caption/chapter tracks. Detected on-screen secrets block agent shares until blurs are reviewed. No sharing while recording/demo runs.
- Recording is always visible; demo plans run only after user confirmation. No telemetry; uploads only to the user's configured bucket (keys in Keychain).

## Other

- `site/` = GitHub Pages project page (deployed by `.github/workflows/pages.yml`); `Website/` = static Cloudflare Pages sales site (Paddle). Both are excluded from CI.
- Updates (Sparkle) and licensing are off unless the `TAKELY_*` xcconfig values are set (`Config/Takely.xcconfig`, overridden by `Local.xcconfig` or `release.sh`).
- New third-party deps need their license text in `Licenses/` (shown in Settings › Acknowledgements).
- Commits: Conventional Commits (`feat(capture): …`, `fix(app): …`), imperative, subject under ~60 chars. Contributing guide asks for test-first.
