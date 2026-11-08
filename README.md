# Coolant

Menu bar fan control for Apple Silicon MacBooks. It sets per-fan curves, saves presets, switches them on CPU, GPU or battery temperature, and reports changes in the notch.

Only tested on a MacBook Pro M3 Pro (`Mac15,7`) running macOS 27.2. The sensor grouping and write sequence come from measurements on that machine.

## How it works

Fan state lives in the System Management Controller, reached through the `AppleSMC` IOKit driver. Anyone can read it. Writing needs root.

| Key | Meaning |
| --- | --- |
| `FNum` | Fan count |
| `FnAc`, `FnMn`, `FnMx` | Current, minimum and maximum RPM |
| `Ftst` | Set to 1 to allow manual control |
| `FnMd` | 1 is manual, 0 is automatic |
| `FnTg` | Target RPM, little-endian float |

`coolantd` is a small root LaunchDaemon. It accepts newline-delimited JSON on a Unix socket that only the installing user can open, and all it can do is set a fan inside the SMC's min and max, or return it to automatic. The app runs the control loop every 2 seconds.

Sensor groups were picked by loading each chip and watching which keys moved. `Tp` and `Te` follow CPU load, `Tg` follows GPU load, and `TB0T` to `TB2T` match the battery gas gauge.

## Safety

- The helper returns every fan to automatic if the app quits, crashes or misses heartbeats for 8 seconds, and when the helper itself stops.
- Fans return to automatic before sleep.
- While Coolant controls a fan, reaching the failsafe temperature (100 C by default) forces maximum speed.
- A curve whose sensor disappears runs its fan at maximum.
- Coolant stops writing while Macs Fan Control is running, because two controllers would fight over the same keys.

## Build

Needs only the Command Line Tools.

```sh
./scripts/build.sh --install   # builds and copies to /Applications
scripts/test.sh                # logic tests
```

Open the app and press Install helper. Settings has Remove helper for undoing that.

`coolantctl status` prints fans and temperatures. `coolantctl hold <fan> <rpm> <seconds>` tests the helper from a terminal.
