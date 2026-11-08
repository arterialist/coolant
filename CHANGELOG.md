# Changelog

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- A constant RPM fan returns to macOS after 3 readings in a row with no CPU or GPU temperature, because the failsafe cannot protect it without one.

## [0.2.0] - 2026-11-08

### Changed

- New interface with a sidebar and Liquid Glass on macOS 26 and later. Earlier systems use standard materials.

### Fixed

- The notch panel now sits above the menu bar. A panel setting had reset its window level.
- A second copy of the app now exits instead of competing for the helper.

## [0.1.1] - 2026-11-08

### Added

- App icon, drawn by `scripts/make-icon.swift`.

## [0.1.0] - 2026-11-08

### Added

- Menu bar app with per-fan automatic, full, constant and temperature curve control.
- Saved presets and temperature triggers.
- Autopilot mode.
- Notch notifications.
- Root helper that returns fans to automatic on disconnect, and a diagnostic CLI.

[Unreleased]: https://github.com/arterialist/coolant/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/arterialist/coolant/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/arterialist/coolant/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/arterialist/coolant/releases/tag/v0.1.0
