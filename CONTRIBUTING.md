# Contributing

Bug reports, hardware reports and pull requests are welcome. Reports from Macs other than the M3 Pro test machine help the most, because sensor keys change between chips.

## Development

```sh
swift build
scripts/test.sh
./scripts/build.sh          # builds build/Coolant.app
```

The app, helper and CLI all build with the Xcode Command Line Tools. Keep it that way. SwiftUI's `@State` is a macro whose plugin ships only with full Xcode, so use the `@Local` wrapper in `Sources/Coolant/Local.swift`.

| Path | Contents |
| --- | --- |
| `Sources/CSMC` | C calls into AppleSMC and the HID temperature services |
| `Sources/CoolantCore` | Sensors, models, Autopilot, curves, triggers, helper protocol |
| `Sources/coolantd` | Root helper |
| `Sources/coolantctl` | Diagnostic CLI |
| `Sources/Coolant` | Menu bar app |

Control logic belongs in `CoolantCore` with tests.

## Rules for fan and helper changes

- The helper must stay small. Anything that widens what it accepts needs a clear reason and a security note in the pull request.
- Every path that takes manual control needs a path back to automatic.
- A claim about sensors or fan behaviour needs a measurement from a named machine. Include the model and macOS version.
- Do not ask testers to run sustained full CPU and GPU load on a machine with a known heat or smell problem.

## Pull requests

Keep each one to a single change, and make sure CI passes. Say what you tested, and on which Mac.

By contributing you agree your work is licensed under the [MIT License](LICENSE). This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
