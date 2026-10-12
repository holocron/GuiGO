# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's
**private vulnerability reporting** on this repository (Security → Report a
vulnerability). Include what you found, how to reproduce it, and its impact.

Never include real credentials, system names or captured traffic from a
production system in a report.

## Known limitations

- The DIAG connection is **not encrypted**: traffic, including the logon,
  travels compressed but in clear text. Use a VPN or another secured network
  path to reach SAP systems.
- GuiGo talks only to the SAP system the user configures; it sends no data to
  any other service.
- Stored passwords are kept in the platform secure store (iOS Keychain,
  device-only; Android encrypted preferences).
