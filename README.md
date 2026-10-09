# Takely

**The private screen recorder your AI agents can use safely.**

A native macOS screen recorder for async video: record your screen with a camera bubble, system audio and your voice, trim it, and share a link in seconds. Pure Swift, on-device, no web runtime — and an [MCP](https://modelcontextprotocol.io) server so AI agents can record, demo and share too, with you in charge.

## Our goal

AI agents now do real work on our computers: they write code, change apps and open pull requests. They need a way to
**show** what they did, and people need to **see** it before anything leaves their Mac. Takely's goal is to be the
screen recorder that people and their agents share, built on four promises:

1. **You're always in charge.** Recording is always visible. A demo plan runs only after you confirm it. Nothing is
   published until you've seen the preview and every word that goes with it, and "no" is final for the agent.
2. **What you approve is exactly what's sent.** An agent's share is a sealed copy, checked part by part as it uploads,
   with no text hidden inside the video file. Secrets found on screen block it until you've reviewed them.
3. **Everything stays yours.** Recording, transcription and AI run on your Mac. Videos go only to your own storage.
   No account, no Takely cloud, no tracking.
4. **It's open, so you can check.** The recorder, the agent server and every safety check above are open source
   (AGPL-3.0): these promises can be verified, not just trusted.

Without an agent, it's simply a fast, native recorder for async video.

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
- An MCP server for AI agents (Claude Code, Codex, Cursor…): record, check frames, share — see [AI agents](#ai-agents-mcp)

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

## AI agents (MCP)

Takely includes an [MCP](https://modelcontextprotocol.io) server, so AI agents such as Claude Code, Codex and Cursor
can record your screen, run narrated demos of native Mac apps, and share the video — for example as proof that a change
works, right in its pull request.

```sh
claude mcp add takely -- /Applications/Takely.app/Contents/Helpers/takely-mcp   # Claude Code
codex mcp add takely -- /Applications/Takely.app/Contents/Helpers/takely-mcp    # Codex
```

Cursor and other clients that take JSON (e.g. `~/.cursor/mcp.json`; VS Code's `.vscode/mcp.json` names the key
`"servers"`):

```json
{ "mcpServers": { "takely": { "command": "/Applications/Takely.app/Contents/Helpers/takely-mcp" } } }
```

Settings › Automation has these for wherever Takely is installed, with Copy buttons.

- **Tools:** `status`, `record_start` (a display, one app's window, camera/microphone on or off), `record_stop` (the
  video's path, length and title), `pause`, `resume`, `marker`, `run_demo` (a step-by-step plan, narrated; Takely Pro), `share`
  (a link to the video in your own bucket, plus Markdown with a clickable poster), `transcript`, `frames` (stills to check the video before sharing), `doctor`.
- **Prompt:** `pr_demo` — record a short narrated demo of a change and add it to the pull request.
- **Safety:** the server talks to Takely over the same private socket as the `takely` command (your user only), and
  `takely://` links can't do any of this.
  - You always see when Takely records; a demo plan is shown to you and runs only when you confirm.
  - Nothing is shared until you confirm it: you see a preview frame, the length, and every word published with it
    (title, summary, chapter names, captions). Declining is final for the agent.
  - What's uploaded is what you saw: a sealed private copy, checked part by part as it uploads, remuxed with no text
    inside the video file (no metadata, caption or chapter tracks).
  - Secrets found on screen (API keys, emails, card numbers) block an agent's share until you review the blurs; no
    sharing while a demo or recording runs; videos go only to your own storage.
- Everything runs on your Mac: recording, transcription, and AI titles and summaries (Apple Intelligence).

## Testing a local build

`scripts/release.sh 1.0.0 --local` makes a Release build of the app and a DMG in `dist/1.0.0-local/` for this Mac (no
Apple Developer Program needed). It launches the build once to check it starts.

macOS ties privacy permissions (Screen Recording, Camera, Microphone) to how an app is signed:

- With an **Apple Development** certificate in your keychain (free: sign in with your Apple ID in Xcode › Settings ›
  Accounts, then *Manage Certificates › +*), local builds are signed with it and keep their permissions across rebuilds.
- Without one, builds are signed ad hoc and each rebuild counts as a new app: grant Screen Recording again after every
  rebuild. If System Settings shows Takely switched on but recording still says it's off, reset it and grant it again:

  ```sh
  tccutil reset ScreenCapture app.takely.Takely
  ```

  Several copies of Takely on the Mac (old builds, Xcode's) can take the permission instead of the one you run. The
  local build registers itself as the one to use; `scripts/check.sh` unregisters its own test build.

## License

Takely is licensed under the [GNU Affero General Public License v3.0](LICENSE). Third-party components and their licenses are listed in [NOTICE](NOTICE).
