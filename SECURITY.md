# Security policy

## Reporting

Report vulnerabilities through [GitHub private vulnerability reporting](https://github.com/arterialist/coolant/security/advisories/new). Please do not open a public issue.

Only the latest release is supported.

## What the root helper exposes

`coolantd` runs as root, so it is the part most worth attacking.

- It listens on `/var/run/com.arterialist.coolantd.sock`, mode `0600`, owned by the user who installed it. It also checks the peer's user ID on each connection.
- It accepts four commands: `ping`, `set`, `auto` and `resetAll`. Fan index and RPM are checked, and RPM is clamped to the SMC's reported range.
- It never takes a key name, a file path or a command from a client.

**Known limit.** Any process running as the installing user can connect and change fan speeds within the hardware's range. It cannot go beyond that range or gain root through the helper. Releases are ad-hoc signed, so the helper cannot verify the client by code signature.

Anything that lets a client run code as root, write an arbitrary SMC key, or reach the socket as another user is in scope.
