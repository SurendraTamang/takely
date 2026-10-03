# Takely

A native macOS screen recorder for async video: record your screen with a camera bubble, system audio and your voice, trim it, and share a link in seconds. Pure Swift, on-device, no web runtime.

**Status:** alpha. It builds and its test suite passes, but many features haven't had much real-world use yet. Expect rough edges, and please [report what you find](../../issues).

## Features

**Recording**
- Display, window or area capture with system audio, microphone and a draggable camera bubble (circle, rounded, square)
- Live speaker-echo removal (WebRTC AEC3): record without headphones; the original microphone is kept too
- 3-2-1 countdown, pause/resume, restart, discard, a floating control bar
- Cursor highlight and click pulses; draw on screen while recording
- An invisible prompter (never recorded), "oops" retake back to your last pause, markers that become chapters
- Meeting detection: offers to record Zoom, Teams, FaceTime and Google Meet calls (asks first; tell participants)
- Crash-safe recovery, and it stops before the disk fills

**After recording**
- MP4 export (HEVC or H.264, 720p/1080p/native, 30/60 fps) with chapters, captions and title/summary metadata
- Blurred areas (secret keys, emails, card numbers — or anything you mark) and a review window
- Edits are non-destructive: cuts, trims and zooms rendered at export
- Share to your own bucket (Cloudflare R2, Amazon S3, Backblaze B2, any S3-compatible service): a player page with link previews and oEmbed, link copied when done

**Automation**
- `takely` command-line tool: `takely record start --no-countdown`, `takely record stop --json` (prints the video's path)
- Shortcuts and Siri actions; `takely://` links (x-callback-url; links ask before acting)

## Takely Pro

Takely is open core. Everything above is open source (AGPL-3.0). Some features are part of Takely Pro, which is proprietary and not in this repository: on-device transcription and captions, AI titles and summaries, the voice-following prompter and speaking coach, finding secrets on screen automatically, the editor with silence removal and auto-zoom, and Demo Mode (an agent that drives the Mac and narrates). The app builds and runs fully without it; Pro features are behind `#if canImport(TakelyPro)`.

## Privacy

Recordings stay on your Mac. Nothing is uploaded unless you set up sharing (Settings › Share), and then only to the bucket you configure, with keys kept in your Keychain. On-device features use Apple's frameworks (ScreenCaptureKit, Speech, Vision, Foundation Models); there's no telemetry.

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

Local builds are signed ad hoc, so macOS forgets permissions (Screen Recording, Accessibility) after each rebuild: Settings shows the switch on, but it belongs to the previous build. Run `tccutil reset ScreenCapture app.takely.Takely`, relaunch, and allow again. Signing with an Apple Development certificate (set `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` in `Config/Local.xcconfig`) avoids this.

The command-line tool is inside the app (`Takely.app/Contents/Helpers/takely`); Settings › Automation shows how to put it on your PATH.

## Development

Run `./scripts/check.sh` before committing: it lints with `swift-format`, runs the test suite (serially) and builds the app. See [CONTRIBUTING.md](CONTRIBUTING.md).

The engine is the `TakelyKit` Swift package (`Packages/TakelyKit`):

| Module | What it does |
|---|---|
| `ProjectKit` | Recording bundles (`.takely`): manifest, cursor, markers, transcript, edits, blurs, narration |
| `CaptureKit` | ScreenCaptureKit + AVAssetWriter capture, echo cancellation, silence detection |
| `RenderKit` | Export: composition, compositor (bubble, blurs, zoom, captions), chapters and captions tracks |
| `AppCore` | Recording controller, recovery, storage guard, automation commands, meeting detection |
| `ShareKit` | S3 Signature V4, multipart upload, the share page |
| `TakelyControl` | The CLI's socket protocol |

The app target in `App/` is the menu bar UI.

## License

Takely is licensed under the [GNU Affero General Public License v3.0](LICENSE). Third-party components and their licenses are listed in [NOTICE](NOTICE).
