# Contributing to Takely

Thanks for your interest! Takely is in early development.

## Before you start

- Open an issue to discuss larger changes first.
- Read the design spec in `docs/superpowers/specs/`.

## Development

1. Install Xcode 26.3+ and `brew install xcodegen`.
2. Run `./scripts/check.sh` before every commit. It lints with `swift-format`, runs the tests, and builds the app.
3. Write a failing test first, then the code that makes it pass.

## Commits

- Use [Conventional Commits](https://www.conventionalcommits.org/): `feat(capture): …`, `fix(app): …`, `docs: …`.
- Keep subjects short (under about 60 characters) and in the imperative mood.

## Licensing

Takely is licensed under AGPL-3.0. Contributors will be asked to sign a Contributor License Agreement (CLA) before their first pull request is merged, so the project can also offer commercial licenses. The CLA process will be published with the repository.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
