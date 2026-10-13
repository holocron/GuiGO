/// The EMULATED GUI PROFILE: what GuiGo says about its front end on a
/// Windows-dialect logon, defined once.
///
/// GuiGo speaks the SAP GUI for Windows dialect (the kernel keys its
/// control dialect on it: ActiveX ProgIDs, OCX_SUPPORT …), so the GUI
/// release / patch level it announces are the emulated Windows GUI's
/// ([emulatedGuiRelease] / [emulatedGuiPatchLevel], frontend_profile.dart
/// winIdentity). The facts about the DEVICE are its own, though: the
/// operating system it runs on ([EmulatedGuiProfile.osVersion], from the
/// host platform — [EmulatedGuiProfile.host]) and its display
/// ([EmulatedGuiProfile.displayPx], when the app knows it). The browser is
/// a generic name ([genericBrowserVersion]) and Office the emulated GUI's
/// ([emulatedOfficeVersion]; GuiGo will grow its own Office support).
///
/// The recording PC's own values — what every reference capture carries —
/// are [EmulatedGuiProfile.recordedWindowsGui]: tests that pin real-GUI
/// bytes pass it explicitly.
library;

import 'dart:io' show Platform;
import 'dart:typed_data';

import '../cfw/html_viewer.dart' show HtmlBrowserControl;
import '../screen/screen_layout.dart' show metricX2, metricY2;

/// 16/04/09: the SAP GUI release the session emulates (8.00).
const String emulatedGuiRelease = '800';

/// 16/04/29: the emulated SAP GUI's patch level.
const String emulatedGuiPatchLevel = '18';

/// 16/04/32 BROWSER_VERSION a GuiGo logon announces: a generic name in the
/// shape the SAP GUI for Windows sends (`IE <version>` — the reference
/// GUI's `IE 9.11.22621.0`, the registry version of IE 11), naming no
/// particular build.
const String genericBrowserVersion = 'IE 11.0';

/// 16/04/33 OFFICE_VERSION: the reference GUI's `Office 16`, kept as is.
const String emulatedOfficeVersion = 'Office 16';

/// The longest 16/04/31 GUI_OS_VERSION text a logon sends (the reference
/// GUI's is 21 characters; a host's raw version string can run long).
const int maxOsVersionLength = 40;

/// The emulated GUI's DATAMANAGER METRICS constants (`<METRICS X3 X2 X1
/// X0 Y3 Y2 Y1 Y0>`): X3 / Y3 are the window (cols x [metricsCellX],
/// rows x [metricsCellY]); the rest the same in every capture of the SAP
/// GUI for Windows. They are NOT the 16/04/04 FONTMETRIC (22 x 7 px on the
/// same frames — a recorded session raw gui[8], whose METRICS say 8 x
/// 29), so they are not derived from it. (The same cell the layout converts
/// docking extents by: screen_layout.dart [metricX2] / [metricY2].)
const int metricsCellX = metricX2, metricsCellY = metricY2;
const int metricsX1 = 8, metricsX0 = 283, metricsY1 = 17, metricsY0 = 283;

/// The `<METRICS …/>` element for a [rows] x [cols] window, cell
/// [cellX] x [cellY] ([metricsCellX] / [metricsCellY] unless named).
String metricsElement(
  int rows,
  int cols, {
  int cellX = metricsCellX,
  int cellY = metricsCellY,
}) =>
    '<METRICS id="metrics" X3="${cols * cellX}" X2="$cellX" '
    'X1="$metricsX1" X0="$metricsX0" Y3="${rows * cellY}" Y2="$cellY" '
    'Y1="$metricsY1" Y0="$metricsY0"/>';

/// What a Windows-dialect logon says about its front end (the logon-only
/// 16/04/31 / 32 / 33 / 37 atoms — [logonIdentity]) and the display it
/// reports ([displayPx]).
class EmulatedGuiProfile {
  const EmulatedGuiProfile({
    required this.osVersion,
    this.browserVersion = genericBrowserVersion,
    this.officeVersion = emulatedOfficeVersion,
    this.displayPx,
    this.htmlBrowser = HtmlBrowserControl.internetExplorer,
  });

  /// The profile of a device running [operatingSystem] (dart:io
  /// `Platform.operatingSystem`: `ios`, `android`, `macos` …) at
  /// [operatingSystemVersion] (`Platform.operatingSystemVersion`), with
  /// its display of [displayPx] (height, width px) when known.
  factory EmulatedGuiProfile.forPlatform(
    String operatingSystem,
    String operatingSystemVersion, {
    (int, int)? displayPx,
  }) =>
      EmulatedGuiProfile(
        osVersion: clientOsVersion(operatingSystem, operatingSystemVersion),
        displayPx: displayPx,
      );

  /// The profile of the host this code runs on ([EmulatedGuiProfile
  /// .forPlatform] of dart:io's [Platform]) — the package's default.
  factory EmulatedGuiProfile.host({(int, int)? displayPx}) =>
      EmulatedGuiProfile.forPlatform(
        Platform.operatingSystem,
        Platform.operatingSystemVersion,
        displayPx: displayPx,
      );

  /// The reference SAP GUI for Windows' own values (the recording PC:
  /// a recorded session gui[1], a recorded session
  /// gui[1], a recorded session gui[3] — the same bytes in
  /// all three). For tests pinning real-GUI bytes and A/B probes only.
  static const EmulatedGuiProfile recordedWindowsGui = EmulatedGuiProfile(
    osVersion: 'Windows 10.0 (22631) ',
    browserVersion: 'IE 9.11.22621.0',
  );

  /// 16/04/31 GUI_OS_VERSION.
  final String osVersion;

  /// 16/04/32 BROWSER_VERSION.
  final String browserVersion;

  /// 16/04/33 OFFICE_VERSION.
  final String officeVersion;

  /// The browser control the emulated GUI's HTML viewer hosts — what a
  /// `SAPEVENT:` form submit reports ([HtmlBrowserControl]: IE `Frame0` /
  /// `sapevent:A1F1`, Edge no frame / `SAPEVENT:A1F1`). Internet Explorer
  /// by default: the GUI GuiGo emulates is 8.00 ([emulatedGuiRelease]) and
  /// announces an IE browser ([genericBrowserVersion]); a replay of an 8.10
  /// capture (its Edge control) names [HtmlBrowserControl.edge].
  final HtmlBrowserControl htmlBrowser;

  /// The device's display (height, width px, the units of the window
  /// figures a round reports), or null: the session then reports the
  /// reference GUI's (ActionContext's defaults).
  final (int, int)? displayPx;

  /// The `16/04/*` atoms the SAP GUI for Windows sends ONCE, in the first
  /// round of the logon (frontend_profile.dart, logon_frames.dart
  /// logonItems), in wire order: 16/04/31 GUI_OS_VERSION, 16/04/32
  /// BROWSER_VERSION, 16/04/33 OFFICE_VERSION, 16/04/37 GUI_TYPE (`0001`).
  List<(int, Uint8List)> get logonIdentity => [
        (31, _latin1(osVersion)),
        (32, _latin1(browserVersion)),
        (33, _latin1(officeVersion)),
        (37, Uint8List.fromList(const [0x00, 0x01])),
      ];

  @override
  String toString() => 'EmulatedGuiProfile($osVersion / $browserVersion / '
      '$officeVersion${displayPx == null ? '' : ' / display $displayPx'}'
      '${htmlBrowser == HtmlBrowserControl.edge ? ' / Edge' : ''})';
}

Uint8List _latin1(String s) =>
    Uint8List.fromList([for (final c in s.codeUnits) c & 0xff]);

/// The 16/04/31 text for [operatingSystem] at [operatingSystemVersion]
/// (dart:io's spellings): `<OS> <version>` in the SAP GUI for Windows'
/// shape (`Windows 10.0 (22631)`) — iOS' `Version 18.1 (Build 22B83)`
/// becomes `iOS 18.1 (22B83)`; printable ASCII only, at most
/// [maxOsVersionLength] characters.
String clientOsVersion(String operatingSystem, String operatingSystemVersion) {
  final name = switch (operatingSystem.toLowerCase()) {
    'ios' => 'iOS',
    'android' => 'Android',
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    'fuchsia' => 'Fuchsia',
    final other => other.isEmpty ? 'Unknown' : other,
  };
  final version = operatingSystemVersion
      .replaceFirst(_clientOsVersionRx, '')
      .replaceAll(_clientOsVersionRx2, '(')
      .replaceAll(_clientOsVersionRx3, '')
      .replaceAll(_whitespaceRunRx, ' ')
      .trim();
  final text = version.isEmpty ? name : '$name $version';
  return text.length <= maxOsVersionLength
      ? text
      : text.substring(0, maxOsVersionLength).trimRight();
}

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call (audit #7 / zcode P-12).
final RegExp _clientOsVersionRx = RegExp(r'^Version\s+');
final RegExp _clientOsVersionRx2 = RegExp(r'\(Build\s+');
final RegExp _clientOsVersionRx3 = RegExp(r'[^\x20-\x7e]');
final RegExp _whitespaceRunRx = RegExp(r'\s+');
