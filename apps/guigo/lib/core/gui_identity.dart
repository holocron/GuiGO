import 'dart:io' show Platform;

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/widgets.dart';

/// The device's display (height, width in logical px — the unit the
/// session's window figures are in), or null when no view is attached.
(int, int)? deviceDisplayPx(BuildContext context) {
  final view = View.maybeOf(context);
  if (view == null) return null;
  final display = view.display;
  if (display.devicePixelRatio <= 0) return null;
  final size = display.size / display.devicePixelRatio;
  if (size.isEmpty) return null;
  return (size.height.round(), size.width.round());
}

/// What this device's logons say about their front end
/// (diag_protocol's EmulatedGuiProfile): the real platform and version it
/// runs on, the generic browser, the emulated Office, and its display.
EmulatedGuiProfile deviceGuiProfile(BuildContext context) =>
    EmulatedGuiProfile.forPlatform(
      Platform.operatingSystem,
      Platform.operatingSystemVersion,
      displayPx: deviceDisplayPx(context),
    );
