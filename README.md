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

Sensor groups were picked by loading each chip and watching which keys moved. `Tp` and `Te` follow CPU load, `Tg` follows GPU load, and `TB0T` to `TB2T` match the battery gas gauge. CPU hottest matches the firmware key `TCMz` to within 0.02 C. Apple does not document these keys, so the absolute values cannot be checked against a reference.

Stopped fans refuse manual mode with SMC status 130 until they spin up, about 7 seconds on this machine. The app retries each tick and only reports failures that last over 20 seconds.

## Autopilot

Autopilot picks fan speed from whichever part needs cooling most. The hard limit is where the fans reach full speed.

| Part | Starts at | Full at | Why |
| --- | --- | --- | --- |
| CPU hottest | 65 C | 85 C | Wire and transistor wear follow an Arrhenius curve with temperature |
| GPU hottest | 60 C | 80 C | Same mechanism |
| Battery | 34 C, or room + 3 C, at most 38 C | Start + 6 C | Capacity fade speeds up with heat and high charge. A fan cannot cool below room air |
| SSD | 50 C | 70 C | NAND charge leaks faster when hot. Sources here are weaker |

macOS thermal pressure sets a floor of 40%, 85% and 100% for fair, serious and critical.

Readings count rises within seconds and falls over about 45 seconds. Fans rise at 10% of range per second and fall at 2%. Solder fatigue grows with roughly the square of each temperature swing, so a slow fall does more than a lower peak. When every part stays calm for 90 seconds, macOS takes the fans back and can stop them.

A trigger can add cooling under Autopilot but cannot reduce it.

## Safety

- The helper returns every fan to automatic if the app quits, crashes or misses heartbeats for 8 seconds, and when the helper itself stops.
- Fans return to automatic before sleep.
- While Coolant controls a fan, holding the failsafe temperature (105 C by default) for 3 readings in a row forces maximum speed.
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
