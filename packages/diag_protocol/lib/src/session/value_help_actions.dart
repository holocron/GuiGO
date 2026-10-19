/// Client frames of the SAP.TABControl.1 value-help dialog (WDTMCTRL.OCX,
/// screen/sap_value_help.dart) in the real SAP GUI for Windows spelling,
/// and the frontend's answer to the search's select-options pull.
///
/// * every dialog gesture is the control's event round `%_GC <shell>
/// <eventId>`: 4/38, the SES (modal level + popup position), 6/35,
/// 12/4, the identity atoms 4/9 4/29 4/15 4/25, the OK event MODE 0x03
/// over zeros, the painted 16/12/6 of the window the dialog sits on,
/// 16/9/18 = the dialog's shell (the focus is the control), the type-17
/// EVENTS XML — then a CONTROLS block with the GENERIC of every live
/// grid that registered the first-visible channel — and EOM. No 16/12/8,
/// no 16/15/1 event source (a recorded session gui[25] / [33],
/// scrubbed — raw 26 / 34 —, a recorded session gui[13] / [20] / [51] /
/// [58], a recorded session gui[18] / [38]); the PARAMs:
/// - search = EVENTID 2 [page, 1001, 1, X] (f4_modes gui[25]);
/// - close = EVENTID 2 [page, 1002, 1, X] (prefilled gui[18],
/// a recorded session gui[19]);
/// - pick = EVENTID 4 [row, 1, key, user token, 0, 1] (f4_modes
/// gui[33]: row 45 = 114399-REP; a result-only hit list sends no PID
/// 2 — a recorded session G48);
/// - page = EVENTID 8 [TABCTRL, page] (a recorded session
/// gui[64], raw 65: `1`, `11`), no CONTROLS block on that capture.
/// That enjoy run sends OK mode 0x0b on EVERY event of its dialog —
/// the search and the pick included — where the five other captures
/// (two systems, three dates) send 0x03; its paints are stream-form, so
/// the focus item that might explain it is not readable at the top
/// level. The rounds here take the acked paint's control half
/// ([windowsOkMode]: 0x03 on the `01` paints of the five, 0x0b on a
/// `09` one), 0x03 without a paint mode ([valueHelpEventItems]).
/// The 16/04/36 window rect rides after the 12/4 by the generic modal
/// rule ([windowsModalWindowRectOwed], reference client 867e1d7 §1): the dialog on
/// a REAL popup carries it (f4_modes gui[25] / [33] on SAPMS01GNEW/0010,
/// enjoy gui[64]: `0000 0409 0000 0781`), the level-1 1 x 1 popup
/// that only hosts the dialog none (me51n gui[13] / [20] / [51],
/// prefilled gui[18] / [38]); the host popup over another popup owes one
/// (a recorded session G48 — its value `0419 0f01` unsettled), and
/// so, unsettled, does the first host popup of a logon (me21n_collapsed
/// gui[19] `0419 0f01`; built without).
/// * the search's select options: the server pulls the data object
/// `getSelectOptions` filled (DP_GET_CLIENT_TABLE45A, FORMAT
/// DDSHSELOPTEX — f4_modes srv[34]); the frontend answers with one row
/// per non-empty input of the ACTIVE page (typed, or pre-filled and left
/// alone — prefilled gui[41] / [48]: `1801 I EQ FR` never touched; a
/// CLEARED pre-fill sends none, gui[55]), OPTION CP for a value with `*`
/// / `+`, else EQ, in item-id order, then the max-hits row (the E item,
/// OPTION blank — f4_modes gui[28]: `Hugo / 1813 / I / '' / 500`).
/// SHLPNAME = the frontend's user token (the OS user name the Windows
/// GUI sends — `Hugo` on every capture), the same token as the pick's
/// PID 3. The envelope is the loaded-object answer: DATE `00000000`,
/// TIME `000000`, TOTALSIZE 0, the DATAASC at the request's record width
/// (573 B) and the request's FORMAT echoed, both as LZH cells, an empty
/// PROPS (gui[28]).
library;

import 'dart:math' show min;
import 'dart:typed_data';

import '../cfw/dp_cache.dart' show dpColumnCells;
import '../cfw/reply_container.dart' show buildDpAnswer, dpTableColumn;
import '../codepages.dart';
import '../framing/envelope.dart';
import '../lzh/lzh.dart';
import '../screen/sap_value_help.dart';
import 'actions.dart';
import 'cfw_dialog_actions.dart' show windowsEventSes;
import 'frames.dart';
import 'frontend_profile.dart';
import 'grid_selection.dart' show GridControlState, windowsGridControlsXml;

String _attr(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// The DATAMANAGER XML of a value-help event, in the OCX's spelling
/// (f4_modes gui[25]: `<EVENT SHELLID ="134" EVENTID ="2"> <PARAM PID
/// ="0" VALUE ="10"/>…</EVENT></EVENTS> <CONTROLS> <CONTROL SHELLID
/// ="125"> <GENERIC FVCID ="3" FVRID ="0" FVRIDS ="0"/></CONTROL>
/// </CONTROLS></DATAMANAGER>`). [params] = PID -> value, written in PID
/// order (a missing PID is left out); [controls] = the CONTROLS blocks.
String valueHelpEventXml(
  String shell,
  int eventId,
  Map<int, String> params, {
  List<GridControlState> controls = const [],
}) {
  final b = StringBuffer(
    '<?xml version="1.0" encoding="sap*"?><DATAMANAGER> <EVENTS>  '
    '<EVENT SHELLID ="${_attr(shell)}" EVENTID ="$eventId"',
  );
  if (params.isEmpty) {
    b.write('/>');
  } else {
    b.write('>');
    for (final pid in params.keys.toList()..sort()) {
      b.write('   <PARAM PID ="$pid" VALUE ="${_attr(params[pid]!)}"/>');
    }
    b.write('</EVENT>');
  }
  b.write('</EVENTS>');
  if (controls.isNotEmpty) {
    b.write(' <CONTROLS>${windowsGridControlsXml(controls)}</CONTROLS>');
  }
  b.write('</DATAMANAGER>');
  return b.toString();
}

/// The geometry a value-help round echoes when no paint declared one: the
/// one-cell window of the control-only SAPLWDTM/0100 (me51n srv[49] `1, 1,
/// 1, 1, 0, 0, 5, 5, 1`).
final Uint8List _dummyPopupGeometry = () {
  final v = Uint8List(33);
  final bd = ByteData.sublistView(v);
  for (final (i, x) in [(0, 1), (4, 1), (8, 1), (12, 1), (24, 5), (28, 5)]) {
    bd.setUint32(i, x);
  }
  v[32] = 1;
  return v;
}();

/// The OK-event mode of a value-help round (f4_modes gui[25] `00 03 …`).
const int valueHelpOkMode = 0x03;

/// A value-help event round on [shell] (see the library doc).
List<Uint8List> valueHelpEventItems(
  ActionContext ctx, {
  required String shell,
  required int eventId,
  required Map<int, String> params,
  List<GridControlState> controls = const [],
  int? okMode,
}) {
  // the dialog's 16/9/18: the control half of the acked paint
  // ([windowsOkMode]) — 0x03 on the `01` popup paints of every 0x03 round
  // above (f4_modes gui[25] on srv[31], me51n_f4 gui[13] on srv[19],
  // f4_prefilled gui[18] on srv[25]); enjoy's 0x0b rounds ack
  // stream-form paints (their 16/5/1 inside the 16/8/4, not paired by the
  // reference client's scan) — a `09` there gives 0x0b; [valueHelpOkMode] without a
  // paint mode
  final mode = okMode ??
      windowsOkMode(ctx, cursor: false, fallback: valueHelpOkMode);
  final geometry = ctx.paintedGeometry ?? _dummyPopupGeometry;
  return [
    stepItem(ctx.step),
    windowsEventSes(ctx),
    buildApplItem(6, 35, winCodepageValue),
    buildApplItem(12, 4, wireText(cfwGenericEventOkcode(shell, eventId))),
    if (windowsModalWindowRectOwed(ctx, geometry: geometry))
      buildApplItem(4, 36, windowsWindowRect(ctx)),
    for (final (sid, value) in winIdentity) buildApplItem(4, sid, value),
    buildApplItem(5, 1, Uint8List(22)..[1] = mode),
    buildApplItem(12, 6, geometry),
    buildApplItem(9, 18, wireText(shell)),
    xmlBlobItem(
      wireText(valueHelpEventXml(shell, eventId, params, controls: controls)),
    ),
    eomBytes,
  ];
}

/// The search on [page]: EVENTID 2 [page, 1001, 1, X].
Map<int, String> valueHelpSearchParams(String page) => {
  0: page,
  1: valueHelpItemSearch,
  2: '1',
  3: 'X',
};

/// The close without a pick: EVENTID 2 [page, 1002, 1, X].
Map<int, String> valueHelpCloseParams(String page) => {
  0: page,
  1: valueHelpItemClose,
  2: '1',
  3: 'X',
};

/// The pick of hit-list row [row] (1-based): EVENTID 4 [row, 1, key, user
/// token, 0, 1]; [key] null (a result-only list) leaves PID 2 out.
Map<int, String> valueHelpPickParams(int row, String? key, String token) => {
  0: '$row',
  1: '1',
  if (key != null) 2: key,
  3: token,
  4: '0',
  5: '1',
};

/// The page activation: EVENTID 8 [TABCTRL, page].
Map<int, String> valueHelpPageParams(SapValueHelpPage page) => {
  0: page.tabControl.isEmpty ? '1' : page.tabControl,
  1: page.id,
};

/// The DDSHSELOPTEX rows a search on [page] uploads (see the library doc).
/// [restrictions] = field (item id, FIELDNAME or label) -> value; an empty
/// value CLEARS a pre-filled input. Throws [ArgumentError] naming the
/// page's fields when a key names none.
List<SapValueHelpSelectOption> valueHelpSelectOptions(
  SapValueHelpPage page,
  Map<String, String> restrictions,
  String token,
) {
  SapValueHelpSelectOption row(String id, String value) =>
      SapValueHelpSelectOption(
        name: token,
        field: id,
        option: value.contains('*') || value.contains('+') ? 'CP' : 'EQ',
        low: value,
      );
  final rows = <SapValueHelpSelectOption>[];
  final mentioned = <String>{};
  for (final e in restrictions.entries) {
    final f = page.field(e.key);
    if (f == null) {
      final have = [for (final x in page.fields) '${x.fieldName} [${x.id}]'];
      throw ArgumentError(
        'value-help page ${page.id} has no restriction field ${e.key}; '
        'fields: ${have.isEmpty ? 'none' : have.join(', ')}',
      );
    }
    mentioned.add(f.id);
    if (e.value.trim().isEmpty) continue; // cleared: no row (gui[55])
    rows.add(row(f.id, e.value));
  }
  for (final f in page.fields) {
    if (mentioned.contains(f.id) || f.text.trim().isEmpty) continue;
    rows.add(row(f.id, f.text)); // the displayed pre-fill (gui[48])
  }
  int order(String id) => int.tryParse(id) ?? 1 << 30;
  rows.sort((a, b) => order(a.field).compareTo(order(b.field)));
  final mh = page.maxHits;
  if (mh != null && mh.id.isNotEmpty) {
    rows.add(SapValueHelpSelectOption(name: token, field: mh.id, low: mh.text));
  }
  return rows;
}

/// The widest select-options record [valueHelpSelectOptionsAnswer] lays
/// out (DDSHSELOPTEX is 573 B): a wire FORMAT past it is hostile.
const int maxSelectOptionsRecord = 1 << 16;

/// The frontend's answer to the select-options pull [request] (a
/// DP_GET_CLIENT_TABLE45A RFC value): [rows] laid out by the request's own
/// FORMAT (DDSHSELOPTEX: SHLPNAME C30, SHLPFIELD C30, SIGN C1, OPTION C2,
/// LOW C255, HIGH C255 — blank-padded), see the library doc.
Uint8List valueHelpSelectOptionsAnswer(
  Uint8List request,
  List<SapValueHelpSelectOption> rows,
) {
  final (_, (fw, fn), fcells) = dpColumnCells(request, 'FORMAT');
  final fmt = BytesBuilder(copy: false);
  for (final c in fcells) {
    fmt.add(c);
  }
  var format = fmt.takeBytes();
  if (fw > 0 && fn > 0 && format.length > fw * fn) {
    format = Uint8List.sublistView(format, 0, fw * fn);
  }
  final fields = <(String, int, int)>[]; // name, offset, length
  var end = 0;
  for (var o = 0; o + 80 <= format.length; o += 80) {
    final name = String.fromCharCodes(format, o + 30, o + 60).trim();
    final bd = ByteData.sublistView(format, o + 60, o + 80);
    final off = bd.getUint32(4, Endian.little);
    final len = bd.getUint32(8, Endian.little);
    fields.add((name, off, len));
    if (off + len > end) end = off + len;
  }
  final (_, (dw, _), _) = dpColumnCells(request, 'DATAASC');
  // clamped: [end] sums wire u32s — a hostile FORMAT asked for gigabytes
  // per row (audit 2026-10-17 P0-7); the real record is 573 B
  final width = min(dw > 0 ? dw : end, maxSelectOptionsRecord);
  final data = Uint8List(width * rows.length)
    ..fillRange(0, width * rows.length, 0x20);
  for (var r = 0; r < rows.length; r++) {
    final row = rows[r];
    final values = {
      'SHLPNAME': row.name,
      'SHLPFIELD': row.field,
      'SIGN': row.sign,
      'OPTION': row.option,
      'LOW': row.low,
      'HIGH': row.high,
    };
    for (final (name, off, len) in fields) {
      final b = wireText(values[name] ?? '');
      final n = b.length < len ? b.length : len;
      if (r * width + off + n > data.length) continue;
      data.setRange(r * width + off, r * width + off + n, b);
    }
  }
  final props = BytesBuilder(copy: false)
    ..add([0x03, 0x01, 0x00, 0x05, ...'PROPS'.codeUnits, 0x03, 0x01])
    ..add([0x03, 0x02, 0x00, 0x08, 0, 0, 0, 80, 0, 0, 0, 0, 0x03, 0x02]);
  final table = BytesBuilder(copy: false)
    ..add(dpTableColumn('DATAASC', width, rows.length, lzhCompress(data)))
    ..add(dpTableColumn('FORMAT', 80, format.length ~/ 80, lzhCompress(format)))
    ..add(props.takeBytes());
  return buildDpAnswer(
    scalars: {
      'TYPE': 'APPLICATION',
      'SUBTYPE': 'X-R3TABLE',
      'DATE': '00000000',
      'TIME': '000000',
      'DESCRIPTION': '',
      'TOTALSIZE': '\u0000\u0000\u0000\u0000',
      'PLATTFORM': '',
    },
    tableRegion: table.takeBytes(),
  );
}
