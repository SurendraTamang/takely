# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Menu bar recorder: display capture with system audio, microphone and camera bubble; pause/resume; cursor highlight and click pulses; quality, frame-rate and codec presets.
- Recording bundles (`.takely`) with per-segment tracks and automatic MP4 export in Rec. 709.
- Global hotkeys (⌥⇧R, ⌥⇧P, ⌥⇧T), a status item panel that opens even when the icon is behind the notch.
- "Recording ready" notification with Copy and Reveal.
- Crash recovery on launch (Recover / Delete / Later), a quit confirmation while recording, and a silent save on logout/restart.
- Storage guard that refuses to start below 2 GB free and stops before the export can't fit.
- Settings (save folder, launch at login, defaults, shortcuts, permissions) and a first-launch welcome.
- Live speaker-echo removal (WebRTC AEC3) when recording system audio and the microphone together; the original microphone is kept in the recording as `micRaw`.
