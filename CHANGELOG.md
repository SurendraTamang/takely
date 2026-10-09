# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- An MCP server for AI agents (`takely-mcp`, Claude Code, Codex, Cursor…): record, pause, markers, check frames, read the transcript, run a confirmed demo, share — and a `pr_demo` prompt for putting a demo of a change in its pull request. Long calls report progress.
- Agent shares ask the person first, showing a preview, the length and every word published; the upload is a sealed copy checked part by part, remuxed with no text inside the video; unreviewed secrets on screen block it.
- `takely doctor` (permissions, other copies of the app, disk space, Apple Intelligence) and `takely share`.
- A project page (`site/`, GitHub Pages) and a logo.
- Window and area capture, device pickers, countdown, a draggable camera bubble and a control bar.
- Prompter, oops-retake, markers as chapters, drawing on screen.
- Non-destructive edits (cuts, trims, zooms) rendered at export; blurred areas with a review window.
- Share to your own S3-compatible bucket (R2, S3, B2…) with a player page, link previews and oEmbed.
- Automation: the `takely` command-line tool, Shortcuts/Siri actions and `takely://` links.
- Meeting detection that offers to record calls.
- Menu bar recorder: display capture with system audio, microphone and camera bubble; pause/resume; cursor highlight and click pulses; quality, frame-rate and codec presets.
- Recording bundles (`.takely`) with per-segment tracks and automatic MP4 export in Rec. 709.
- Global hotkeys (⌥⇧R, ⌥⇧P, ⌥⇧T), a status item panel that opens even when the icon is behind the notch.
- "Recording ready" notification with Copy and Reveal.
- Crash recovery on launch (Recover / Delete / Later), a quit confirmation while recording, and a silent save on logout/restart.
- Storage guard that refuses to start below 2 GB free and stops before the export can't fit.
- Settings (save folder, launch at login, defaults, shortcuts, permissions) and a first-launch welcome.
- Live speaker-echo removal (WebRTC AEC3) when recording system audio and the microphone together; the original microphone is kept in the recording as `micRaw`.
