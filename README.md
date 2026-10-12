# GuiGo — a mobile SAP GUI client for iPad, iPhone and Android

GuiGo is a Flutter application that speaks the SAP **DIAG** protocol directly
to an SAP application server: no SAP GUI installation, no intermediary
service. The protocol stack is pure Dart and lives in its own package, so it
can be reused outside the app.

## What it does

- Logs on to an SAP system (client, user, language), handles the multi-logon
  dialog, and keeps the session alive.
- Renders classic dynpro screens on the SAP character grid: input fields,
  checkboxes, radio buttons, tabstrips, subscreens, table controls, classic
  lists, popups.
- Hosts the common SAP GUI controls: ALV grid (scrolling, selection, sort,
  filter, double-click, value help), trees, the ABAP source editor,
  the HTML viewer, charts, network graphs and the designer canvas, docking and
  splitter containers.
- Value help (F4) including the Windows-style value-help dialog, field help
  (F1), context menus, several windows (DIAG modes) on one logon, internal
  sessions, and logons to another system relayed over RFC.

## Layout

```
packages/diag_protocol/   pure-Dart DIAG stack (no Flutter imports)
  lib/src/ni/             NI framing
  lib/src/lzh/            SAP LZH / LZC codecs
  lib/src/framing/        DIAG header, item walk, frame (de)compression
  lib/src/items/          DYNT atom parser
  lib/src/screen/         screen model, layout composition, controls' models
  lib/src/cfw/            control framework: automation queue, data providers
  lib/src/session/        live session: logon, actions, windows, controls
apps/guigo/               the Flutter app
  lib/features/connections/   system list, secure password storage
  lib/features/session/       session screen and control widgets
```

## Building

```
flutter pub get
flutter analyze
flutter run            # on a connected device or simulator
```

iOS needs Xcode; Android needs the Android SDK.

## Security

- System definitions (host, port, client, user) are stored in the app's
  preferences; they contain no secrets.
- Passwords are optional. When stored, they live in the platform secure store
  (iOS Keychain, device-only; Android encrypted preferences) and are released
  after Face ID / Touch ID / fingerprint when the device has biometrics
  enrolled.
- **The connection is not encrypted.** DIAG traffic, including the logon,
  travels compressed but in clear text. Connect through a VPN or a secured
  network path.

See [SECURITY.md](SECURITY.md) to report a vulnerability and
[POLICY.md](POLICY.md) for what may be contributed to this repository.

## Disclaimer

GuiGo is an independent project. It is not affiliated with, endorsed by or
supported by SAP SE. SAP, SAP GUI and other SAP product names are trademarks of
SAP SE. Use GuiGo only with systems you are authorised to access.

## License

Copyright © 2026 the GuiGo author. All rights reserved. No license is granted;
the source is published for reading only.
