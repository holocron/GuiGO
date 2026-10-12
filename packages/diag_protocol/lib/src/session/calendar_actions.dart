/// Client frames of the calendar control (screen/sap_calendar.dart) in the
/// real SAP GUI for Windows spelling: the date pick.
///
/// a recorded session gui[6] (the test system, ME9F → F4 on S_BEDAT-LOW → the
/// "Calendrier" popup SAPLSCAC/0100, 01.09.2026 picked; post-trim index),
/// item for item:
///
/// 4/38 step 22 · SES `00…00 01 14 05 00…00 0f 26` (no event; modal
/// level 1, the popup at col 0x14 / row 5, the window pixels' low bytes)
/// · 6/35 · 12/4 `%_GC 116 3` · 4/36 `0000 0409 0000 0781` (the real
/// popup's window rect) · 4/9 4/29 4/15 4/25 · 5/1 `00 03` (modal) over
/// zeros · 12/6 = the popup's PAINTED geometry (`0c x 28 … 0c x 2a`) · NO
/// 12/8 · 15/1 `00 000d 000b 00 000000 0000 0000 0001 01 00…` (the
/// control-event source at the popup's custom-control area CONTAINER,
/// level `01` — the calendar's container 115 is LinkContainer'd there) ·
/// 16/9/18 `116` (the calendar holds the focus: srv[4] paints `16/9/18
/// 116`) · type 17 `<DATAMANAGER> <EVENTS> <EVENT SHELLID ="116"
/// EVENTID ="3"> <PARAM PID ="0" VALUE ="20260901"/> <PARAM PID ="1"
/// VALUE ="20260901"/> <PARAM PID ="2" VALUE ="0"/></EVENT></EVENTS>
/// <CONTROLS> <CONTROL SHELLID ="115"> <PROPERTY VALUE ="141" NAME
/// ="120"/> <PROPERTY VALUE ="327" NAME ="300"/></CONTROL></CONTROLS>
/// </DATAMANAGER>` (the container's registered cached sizes, in the
/// frontend's own METRICS) · EOM.
///
/// The same shape at gui[11] (`%_GC 121 3`, 15.09.2026 on S_BEDAT-HIGH) and
/// on the test system, a recorded session gui[45] / gui[59] (`%_GC 872 3`
/// 20260618, container 871 141 / 327). The 16/15/1 rides ONLY because the
/// container is linked into a PAINTED custom-control area (reference client 534a50c
/// §3, SapSession._hostedSourcePath): a docked calendar (the Java GUI's
/// AIF navigator 145 in container 129, a recorded session gui[51])
/// sends none.
library;

import 'dart:typed_data';

import '../screen/sap_calendar.dart';
import 'actions.dart';
import 'cfw_dialog_actions.dart';

/// The pick's PARAMs: [from, to, "0"] in YYYYMMDD — a single day sends it
/// twice (every oracle). Throws [ArgumentError] when [to] lies before
/// [from].
List<String> calendarPickParams(DateTime from, [DateTime? to]) {
  final end = to ?? from;
  final a = DateTime(from.year, from.month, from.day);
  final b = DateTime(end.year, end.month, end.day);
  if (b.isBefore(a)) {
    throw ArgumentError(
      'calendar range ends (${calendarWireDate(b)}) before it starts '
      '(${calendarWireDate(a)})',
    );
  }
  return [calendarWireDate(a), calendarWireDate(b), '0'];
}

/// The date pick on calendar [shell] (see the library doc): `%_GC <shell>
/// 3` in the generic Windows control-event envelope, the calendar holding
/// the focus (16/9/18), [sourcePath] the custom-control area its container
/// is linked into (null: no 16/15/1), [controls] the cached props reported
/// after the event (the container's 120 / 300).
List<Uint8List> calendarPickItems(
  ActionContext ctx, {
  required String shell,
  required DateTime from,
  DateTime? to,
  List<int>? sourcePath,
  Map<String, List<(String, String)>> controls = const {},
}) => cfwEventItems(
  ctx,
  shell: shell,
  eventId: calendarEventDateSelected,
  params: calendarPickParams(from, to),
  sourcePath: sourcePath,
  focusShell: shell,
  controls: controls,
);
