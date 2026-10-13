/// Classic table-control (step-loop) cell writes in the SAP GUI for WINDOWS
/// dialect — the TABLE-plane round the reference client's Windows profile sends
/// (engine/tc_windows_rounds.cell_write_items + raw_tabline.
/// _windows_tc_plane_items + raw_tc_geometry._tc_windows_table_header /
/// _tc_windows_tree_names / _tc_cell_item), grounded on the real Windows
/// GUI's frames (a recorded session gui[319] Enter after typing in
/// a TC cell, gui[313] F4 in a TC cell; a recorded session
/// gui[813]) and pinned byte-for-byte against the reference client's two ACCEPTED
/// writes into SAPLALDB/3000 SINGLE at the test system (a recorded session
/// line 1 / line 2 — the tab counter went (1), (2)).
///
/// Item order: Step, SES (`50 <vkey>`, the popup's modal level + position,
/// the window-px DIM bytes), 16/4/36, the Windows codepage, the Windows
/// identity atoms, the OK event `00 0d` over zeros, 16/12/8 window pixels,
/// the window's painted 16/12/6, the control's container legs AS PAINTED
/// (root OPEN all-zero, a page's in-chain 16/12/6 kept), the 60-byte 16/9/14
/// TABLE_HEADER echo, the painted 16/12/2 control area, the 16/9/9 cell(s),
/// the tabstrip's legs + its Windows 16/9/15 echo, [the table-control
/// 16/15/1 on a function key — none on Enter], the 16/9/11 line focus at
/// offset 0, EOM. No 16/9/7 metrics, no DATAMANAGER XML: those are the Java
/// GUI's (a recorded session gui[3]/[4]).
library;

import 'dart:typed_data';

import '../codepages.dart';
import '../framing/envelope.dart';
import '../screen/screen_model.dart';
import 'actions.dart';
import 'frames.dart';
import 'frontend_profile.dart';

/// One cell of a table-control write: the 1-based VISIBLE line, the
/// 1-based column-catalog index (the selector column not counted — the
/// [ScreenField.tcColumn]) and the value. A [checkbox] cell is the
/// `0x68 <state>` kind (an `X` / non-blank value = on).
class TcCellWrite {
  const TcCellWrite(
    this.line,
    this.column,
    this.value, {
    this.checkbox = false,
  });
  final int line;
  final int column;
  final String value;
  final bool checkbox;
}

/// The Windows GUI's 16/12/8 client-window pixel item on an event round
/// (853 x 1880 twice — a recorded session gui[813], swdd gui[319],
/// the reference client's frontend_profile._WIN_WINDOW_PX).
final Uint8List winEventWindowPx = Uint8List.fromList([
  0,
  0,
  3,
  0x55,
  0,
  0,
  7,
  0x58,
  0,
  0,
  3,
  0x55,
  0,
  0,
  7,
  0x58,
]);

/// The 16/12/8 an event / cell round carries in [ctx]'s window: the
/// reference [winEventWindowPx] until the client set its window size
/// ([ActionContext.windowSized]), then the window's own pixels — one window,
/// whatever the round (the server lays the dynpro out from the last 16/12/8
/// it read).
Uint8List windowsEventWindowPx(ActionContext ctx) => ctx.windowSized
    ? ctx.windowAreaPx(ctx.winPxHeight, ctx.winPxWidth)
    : ctx.windowAreaPx(winEventWindowHeight, winEventWindowWidth);

/// The Windows UI_EVENT_SOURCE control type of a key pressed with the cursor
/// in a classic table control (a recorded session gui[10]).
const int winUiesControlTable = 0x10;

/// One 16/9/9 TABLE_ROW_DATA cell: `line u16, column u16, 0x65, text, 0x00`
/// (unpadded) or a checkbox `line u16, column u16, 0x68, 01|00`.
Uint8List tcCellBytes(TcCellWrite c) {
  final b = BytesBuilder(copy: false)
    ..add([
      c.line >> 8 & 0xff,
      c.line & 0xff,
      c.column >> 8 & 0xff,
      c.column & 0xff,
    ]);
  if (c.checkbox) {
    final v = c.value.trim().toUpperCase();
    final on =
        v.isNotEmpty && !const {'0', 'OFF', 'FALSE', 'NO', '-'}.contains(v);
    b.add([0x68, on ? 1 : 0]);
  } else {
    b
      ..addByte(0x65)
      ..add(wireText(c.value))
      ..addByte(0);
  }
  return b.takeBytes();
}

/// The 16/9/11 DYNT_FOCUS_1 of a table-control line: depth = len(path),
/// line u16, column u16, offset u32, the container path.
Uint8List tcFocusBytes(int line, int column, List<int> path, {int offset = 0}) {
  final p = path.isEmpty ? const [1] : path;
  final out = Uint8List(9 + p.length);
  final bd = out.buffer.asByteData();
  out[0] = p.length;
  bd.setUint16(1, line & 0xffff);
  bd.setUint16(3, column & 0xffff);
  bd.setUint32(5, offset);
  out.setRange(9, out.length, p);
  return out;
}

/// The Windows client 16/9/14 echo of a painted 18/9/14 TABLE_HEADER: its
/// 60-byte fixed prefix with only [2:17], [19:22] and [31:42] kept (every
/// array offset and the selection trailer zeroed; the reference client's
/// _tc_windows_table_header, byte-exact on the Windows oracles). Null when
/// the painted header is shorter than 60 bytes.
Uint8List? tcWindowsTableHeader(Uint8List header) {
  const n = 60;
  if (header.length < n) return null;
  final out = Uint8List(n);
  out[1] = n;
  for (final (a, b) in const [(2, 17), (19, 22), (31, 42)]) {
    out.setRange(a, b, header.sublist(a, b));
  }
  return out;
}

/// The Windows client 16/9/15 echo of a painted tabstrip tree-names item:
/// the 16-byte prefix verbatim, ten zero state bytes, the string offsets
/// (0, the data start, the data start + the second string) and two
/// strings — the painted SECOND string when the server filled it, else the
/// FIRST page name of the 18/9/16 [pages] descriptor, else the active page;
/// then the active page (reference client _tc_windows_tree_names). Null when the
/// painted bytes do not parse.
Uint8List? tcWindowsTreeNames(Uint8List painted, [Uint8List? pages]) {
  const prefix = 16, words = 10, strings = 3;
  const offsAt = prefix + words, dataAt = offsAt + 2 * strings;
  final p = painted;
  if (p.length <= dataAt) return null;
  int u16(int o) => (p[o] << 8) | p[o + 1];
  final offs = [for (var i = 0; i < strings; i++) u16(offsAt + 2 * i)];
  final last = offs.last;
  int nul(int from, int to) {
    for (var i = from; i < to; i++) {
      if (p[i] == 0) return i;
    }
    return -1;
  }

  if (!(dataAt <= last && last < p.length)) return null;
  final pageEnd = nul(last, p.length);
  if (pageEnd < 0) return null;
  final page = p.sublist(last, pageEnd + 1);
  Uint8List build(List<int> second) {
    final b = BytesBuilder(copy: false)
      ..add(p.sublist(0, prefix))
      ..add(Uint8List(words))
      ..add([0, 0, dataAt >> 8, dataAt & 0xff])
      ..add([(dataAt + second.length) >> 8, (dataAt + second.length) & 0xff])
      ..add(second)
      ..add(page);
    return b.takeBytes();
  }

  final second = offs[1];
  if (dataAt <= second && second < last) {
    final e = nul(second, last);
    if (e > second) return build(p.sublist(second, e + 1));
  }
  var first = page;
  if (pages != null) {
    final m = _pageNameRx
        .firstMatch(String.fromCharCodes(pages));
    if (m != null) first = Uint8List.fromList([...m.group(1)!.codeUnits, 0]);
  }
  return build(first);
}

/// The Windows 16/15/1 UI_EVENT_SOURCE of a function key pressed in a
/// table-control cell: flags 0x0a, event 7, control type 0x10, four zero
/// bytes, the focus line/column, the path length (u16) and the path
/// (a recorded session gui[313] `0a0007 0010 00000000 0001 0004
/// 0003 010201`).
Uint8List tcUiEventSource(int line, int column, List<int> path) {
  final out = Uint8List(15 + path.length);
  final bd = out.buffer.asByteData();
  out[0] = 0x0a;
  out[2] = 0x07;
  bd.setUint16(3, winUiesControlTable);
  bd.setUint16(9, line & 0xffff);
  bd.setUint16(11, column & 0xffff);
  bd.setUint16(13, path.length);
  out.setRange(15, out.length, path);
  return out;
}

/// The Windows-dialect cell write of [cells] into table control [tc] (a
/// [ScreenModel.tableControls] entry of the CURRENT paint), cursor on
/// ([cursorLine], [cursorColumn]), committed with [vkey] (0 = Enter).
///
/// [cells] may be empty: a key on a cell with nothing typed (the
/// double-click on a cell — the choose key F2 with the cursor there,
/// [keySource] false: the real GUI's mouse double-click on a table-control
/// line carries no 16/15/1, a recorded session gui[26] —
/// or a pushbutton cell's click) sends no 16/9/9. [okcode] = the function
/// code of a PUSHBUTTON cell clicked at the cursor (the `=SI01` option
/// button of SAPLALDB/3000's SINGLE): SES `00 00`, the 16/12/4 after the
/// codepage, the 16/4/36 only in a popup, no 16/15/1 — the reference client's round
/// the the test system kernel accepted on SAPLALDB/3000 (a recorded session
/// gui_08, step 32: it opened the option popup SAPLALDB/0651). The real
/// Windows GUI's frame of a cell-button click is not recorded (the Java
/// GUI adds a BUTTONPRESSED / table-cell 16/15/1, a recorded session
/// gui[99] `=EACT`).
///
/// Built in the WINDOWS spelling directly — the caller must not pass the
/// result through [windowsActionItems]. Throws [StateError] when the paint
/// did not carry the control's TABLE-plane pieces (header, control area,
/// container group): a guessed plane is answered 'FOCUS DATA' and the
/// kernel tears the transaction down.
List<Uint8List> tableCellItems(
  ActionContext ctx,
  TableControlInfo tc,
  List<TcCellWrite> cells, {
  required int cursorLine,
  required int cursorColumn,
  int vkey = 0,
  bool keySource = true,
  String? okcode,
}) {
  final header = tc.headerRaw == null
      ? null
      : tcWindowsTableHeader(tc.headerRaw!);
  final area = tc.controlArea;
  final legs = tc.routing;
  if (header == null || area == null || legs.isEmpty) {
    throw StateError(
      'table control ${tc.name}: the paint carries no '
      'TABLE-plane (header ${tc.headerRaw?.length}, control area '
      '${area?.length}, ${legs.length} legs) — nothing to build the write '
      'from without guessing',
    );
  }
  final path = tc.focusPath;

  final ses = Uint8List(16);
  if (okcode == null) {
    ses[0] = winSesEventarray[0x01]!; // a function key (Enter = 0)
    ses[1] = vkey & 0xff;
  }
  ses[7] = ctx.modalNo & 0xff;
  if (ctx.modalNo != 0) {
    ses[8] = ctx.modalX & 0xff;
    ses[9] = ctx.modalY & 0xff;
  }
  ses[14] = ctx.winPxHeight & 0xff;
  ses[15] = ctx.winPxWidth & 0xff;

  // a table-control round: its 16/9/11 is the cursor half of the acked
  // paint ([windowsOkMode]); 0x0d without a paint mode
  final ok = Uint8List(22)
    ..[1] = windowsOkMode(ctx, cursor: true, fallback: 0x0d);

  final out = <Uint8List>[
    stepItem(ctx.step),
    Uint8List.fromList([itemSes, ...ses]),
    if (okcode == null) buildApplItem(4, 36, windowsWindowRect(ctx)),
    buildApplItem(6, 35, winCodepageValue),
    if (okcode != null) ...[
      buildApplItem(12, 4, wireText(okcode)),
      if (ctx.modalNo != 0) buildApplItem(4, 36, windowsWindowRect(ctx)),
    ],
    for (final (sid, value) in winIdentity) buildApplItem(4, sid, value),
    buildApplItem(5, 1, ok),
    buildApplItem(12, 8, windowsEventWindowPx(ctx)),
    buildApplItem(12, 6, tc.scrollGeometry ?? _charCellGeometry(ctx)),
    for (final l in legs) buildApplItem(l.id, l.sid, l.value),
    buildApplItem(9, 14, header),
    buildApplItem(12, 2, area),
    if (cells.isNotEmpty)
      buildApplItem(
        9,
        9,
        Uint8List.fromList([for (final c in cells) ...tcCellBytes(c)]),
      ),
  ];
  final tn = tc.treeNames == null
      ? null
      : tcWindowsTreeNames(tc.treeNames!, tc.tabPages);
  if (tn != null && tc.tabstripRouting.isNotEmpty) {
    for (final l in tc.tabstripRouting) {
      out.add(buildApplItem(l.id, l.sid, l.value));
    }
    out.add(buildApplItem(9, 15, tn));
  }
  if (vkey != 0 && keySource && okcode == null) {
    out.add(
      buildApplItem(15, 1, tcUiEventSource(cursorLine, cursorColumn, path)),
    );
  }
  out
    ..add(buildApplItem(9, 11, tcFocusBytes(cursorLine, cursorColumn, path)))
    ..add(eomBytes);
  return out;
}

/// The char-cell 16/12/6 of the negotiated screen (the reference client's
/// _ok_charcell_geom) — only for a paint whose header frame carried none.
Uint8List _charCellGeometry(ActionContext ctx) {
  final out = Uint8List(33);
  final bd = out.buffer.asByteData();
  final r = ctx.screenRows, c = ctx.screenCols;
  for (final (i, v) in [(0, r), (4, c), (8, r), (12, c), (24, r), (28, c)]) {
    bd.setUint32(i, v);
  }
  out[32] = 1;
  return out;
}

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call (audit #7 / zcode P-12).
final RegExp _pageNameRx = RegExp(r'([A-Z_][A-Z0-9_]{2,})\x00');
