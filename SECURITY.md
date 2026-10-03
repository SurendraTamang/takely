# Security Policy

## Reporting a vulnerability

Please report security issues privately using GitHub's private vulnerability reporting ("Report a vulnerability" on this repository's Security tab). Do not open a public issue.

Include what you found, how to reproduce it, and the impact you expect. You'll get an acknowledgement, and a fix or mitigation plan once the issue is confirmed.

## Scope

Takely records the screen, camera and microphone on your Mac. It uploads only when you set up sharing, and only to the S3-compatible bucket you configure (its keys are stored in the Keychain). In scope:

- Anything that could expose recordings, upload them without the user's action or setup, or send them anywhere but the configured bucket
- Bypassing macOS privacy permissions, or capturing content the user didn't choose
- The automation surfaces: the `takely` command-line tool's local socket (`~/Library/Application Support/Takely/control.sock`, owner-only), `takely://` links (which must ask before acting unless the user allowed them), Shortcuts actions
- Demo Mode or meeting detection acting without the user's consent
- Leaks of share keys, or of secrets that blurring should have hidden
