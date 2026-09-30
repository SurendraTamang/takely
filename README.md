# Takely

A native macOS screen recorder for async video: record your screen with a camera bubble, system audio and your voice, and share an MP4 in seconds. Pure Swift, on-device, no web runtime.

**Status:** early development, local builds only.

## Features

- Record a display with system audio, microphone and an optional camera bubble
- Removes speaker echo from the microphone live (WebRTC AEC3), so you can record without headphones
- Pause and resume; cursor highlight and click pulses
- 720p / 1080p / native, 30 or 60 fps, HEVC or H.264
- Global hotkeys: ⌥⇧R start/stop, ⌥⇧P pause/resume, ⌥⇧T open the panel (rebindable)
- "Recording ready" notification with Copy (paste the video anywhere) and Reveal
- Crash-safe: unfinished recordings are offered for recovery on the next launch
- Stops before the disk fills, keeping room to export

## Requirements

- macOS 26 or later, Apple silicon
- Xcode 26.3 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build

```bash
brew install xcodegen
xcodegen generate
open Takely.xcodeproj    # or build from the command line:
xcodebuild -project Takely.xcodeproj -scheme Takely -configuration Debug \
  -destination "platform=macOS,arch=arm64" -derivedDataPath build build
open build/Build/Products/Debug/Takely.app
```

Local builds are signed ad hoc, so macOS may ask for Screen Recording permission again after each rebuild. If it keeps failing, run `tccutil reset ScreenCapture app.takely.Takely` and relaunch.

## Development

Run `./scripts/check.sh` before committing: it lints with `swift-format`, runs the test suite (serially) and builds the app. See [CONTRIBUTING.md](CONTRIBUTING.md).

The engine lives in the `TakelyKit` Swift package (`Packages/TakelyKit`): `ProjectKit` (recording bundles), `CaptureKit` (ScreenCaptureKit + AVAssetWriter), `RenderKit` (export and compositing) and `AppCore` (recording controller, recovery, storage guard). The app target in `App/` is the menu bar UI.

## License

Takely is licensed under the [GNU Affero General Public License v3.0](LICENSE).
