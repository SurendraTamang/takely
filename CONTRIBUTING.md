# Contributing to Takely

Thanks for your interest! Takely is in alpha, so bug reports from real use are as valuable as code.

## Before you start

- Open an issue to discuss larger changes first.
- Security issues: see [SECURITY.md](SECURITY.md) — please don't open a public issue.

## Development

1. Install Xcode 26.3+ and `brew install xcodegen`.
2. `xcodegen generate`, then build (see the README).
3. Run `./scripts/check.sh` before every commit. It lints with `swift-format`, runs the tests, and builds the app.
4. Write a failing test first, then the code that makes it pass. Tests run serially: suites that encode video can exhaust hardware video sessions in parallel.

## Commits

- Use [Conventional Commits](https://www.conventionalcommits.org/): `feat(capture): …`, `fix(app): …`, `docs: …`.
- Keep subjects short (under about 60 characters) and in the imperative mood.

## Contributor License Agreement

Takely is licensed under AGPL-3.0 and is also offered under other terms (Takely Pro and commercial licenses). For that to be possible, contributors sign the [Contributor License Agreement](.github/CLA.md) once, before their first pull request is merged: you keep the copyright to your contribution and grant the project the right to distribute it under other licenses too.

Signing is a comment on your pull request: the CLA bot asks for it the first time, and you reply with the sentence it gives you. Your signature is recorded in this repository.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
