/// Client frames of an EDITABLE OO-ALV grid's value help and of the
/// server-applied cell values the frontend adopts (GridView.ocx,
/// `SAPGUI.GridViewCtrl.1`), in the real SAP GUI for Windows spelling.
///
/// * F4 in a cell is NOT GridView's own F4 event (14): the OCX moves the
/// current cell and fires its current-cell / ENTER flush, EVENTID 17,
/// with no PARAM — the server opens the search help of the flushed
/// field (a recorded session gui[7] / [45], a recorded session
/// gui[12] / [32]; SapGridEncEventAdaptor: 14 F4, 17 Enter, 18
/// ModifyCell, 19 ButtonClickRowCol, 33 Modified). The round: 4/38,
/// SES, 6/35, 12/4 `%_GC <grid> 17`, 4/9 4/29 4/15 4/25, the OK event
/// MODE over zeros ([gridOkMode]: 0x0d with a field focused, 0x0b with
/// a control focused), 16/12/8 window pixels, the painted 16/12/6, the
/// 16/15/1 CONTROL event source carrying the grid's CONTAINER PATH (the
/// level bytes of the custom-control area's group in the paint — ME51N's
/// GRIDCONTROL nested in SUB0 / SUB2 / SUB2 / SUB1: `0005 01 03 02 01
/// 01`, 36 bytes; a root-level control `0001 01`, 32 bytes, a recorded session
/// wingui_trees gui[13]), 16/9/18 = the grid, the type-17 XML, EOM;
/// * its XML: `<TABLES>` the SelectedCols / SelectedRows CLEARS (ascending
/// handle), `<EVENTS>` the bare EVENT 17, `<CONTROLS>` the grid's
/// CHANGED CurrentCell* cached properties only — the OCX flushes a
/// property when its value moved since the last flush (prefilled
/// gui[12]: CurrentCellCol + CurrentCellColID only — row and text
/// unchanged; me51n gui[45]: all six for a new row, the text '' after
/// the adopted `1010`) — in the OCX's serialisation order, then its
/// GENERIC;
/// * the server's answer is the SAP.TABControl.1 hit list
/// (sap_value_help.dart); after the pick it writes the value into the
/// grid itself: a `DeltaTableModified` push (an X-R3TABLE in the
/// ModifiedCells format `row | sub row | column id | value | …`) and a
/// `GridModified` read in the same queue (me51n srv[30]). The real GUI
/// ADOPTS it as if typed — its answer's EXPORT_XML (gui[23]) carries the
/// ModifiedCells provider CLEARED and refilled, the DataTable cell
/// record UPDATED (`OP ="U"` at IDX (row - 1) x (columns + 1) +
/// position + 1), CurrentCellText = the value, GridModified 1 (each
/// only when it moved: gui[44] sends no GridModified, already 1),
/// GENERIC — and the read answers 1. The server then confirms with a
/// `DeltaTable` push (srv[31]); the answer (gui[24]) empties
/// ModifiedCells, echoes the DataTable update and reports GridModified
/// 0;
/// * the item commit is `%_GC <grid> 19` with no PARAM (me51n gui[83]);
/// * the cell DOUBLE-CLICK (`%_GC <grid> 3`) and the HOTSPOT click (`%_GC
/// <grid> 2`) ride the same envelope with the cell's five PARAMs, the
/// moved CurrentCell* properties and the selection channels — the row
/// inserted on a SelectionMode 1 grid (a recorded session gui[112] /
/// [127], the ST22 hit list; a recorded session gui[133], ME23N
/// BELNR; see [gridEventDoubleClick]).
///
/// An `<IT>` record with more cells than a selection insert is written in
/// the OCX's own attribute order (gui[23] / [25]: `C9 C4 IDX C17 C5 C16 C6
/// C15 C7 C14 C13 C1 C12 C2 C11 C3 OP C10 C8` — the 9-cell ModifiedCells
/// and the 17-cell DataTable records are both this order with the absent
/// cells left out; a two-cell insert `IDX C1 C2 OP` is too).
library;

import 'dart:typed_data';

import '../codepages.dart';
import '../framing/envelope.dart';
import 'actions.dart';
import 'cfw_dialog_actions.dart' show windowsEventSes;
import 'frames.dart';
import 'frontend_profile.dart';
import '../screen/sap_grid.dart';
import 'grid_selection.dart'
    show
        GridControlState,
        GridDataChange,
        gridRowIdNumeric,
        gridRowIdText,
        windowsDataChangesXml,
        windowsGridControlsXml;

/// GridView.ocx event ids (SapGridEncEventAdaptor).
const int gridEventF4 = 14;
const int gridEventEnter = 17;
const int gridEventModifyCell = 18;
const int gridEventButtonClickRowCol = 19;
const int gridEventModified = 33;

/// The grid's CLICK family (sapGridS SapGrid fireClickRowCol /
/// fireDoubleClickRowCol; the reference client's drill_row / alv_drill):
/// 2 = the HOTSPOT click (a single click on a hotspot cell — a recorded session
/// wingui_s4b_enjoy gui[133] `%_GC 148 2`, ME23N PO history BELNR), 3 = the
/// DOUBLE-CLICK on a cell (a recorded session gui[112] `%_GC 119 3`, the
/// ST22 hit list opening a dump; gui[10] SE16, gui[53] SE16N, gui[63] /
/// [70] AL11, gui[127] ST22 again, gui[148] SMW0 — scrubbed numbering).
const int gridEventHotspotClick = 2;
const int gridEventDoubleClick = 3;

/// The five PARAMs a cell click / double-click carries (fireClickRowCol's
/// tuple): PID 0 the row-id cell text (`' ' * 23 + '0000000001'`), 1 the
/// column's field name, 2 the numeric row id, 3 the NUMERIC COLUMN ID
/// (the catalog's — not the position: ME23N's BELNR is position 3 =
/// CurrentCellCol 3 but id 4 = PID 3 `4`, a recorded session
/// gui[133] on the srv[164] catalog), 4 the row's sub id 0.
List<String> gridCellEventParams(SapGridModel g, int line, String columnId) {
  final i = g.columns.indexOf(columnId);
  if (i < 0) throw ArgumentError('grid ${g.shell} has no column $columnId');
  return [
    gridRowIdText(g, line),
    columnId,
    '${gridRowIdNumeric(g, line)}',
    '${i < g.columnIds.length ? g.columnIds[i] : i + 1}',
    '0',
  ];
}

/// Whether a click on a cell of [g] also SELECTS its row — the GridView's
/// `SelectionMode` 1: the double-click / hotspot click then flushes the
/// row into the SelectedRows provider (`<IT IDX ="1" C1 ="<row id>" C2
/// ="0" OP ="I"/>`). Pinned on every Windows click of the corpus: mode 1
/// inserts (a recorded session gui[112] / [127] ST22 119, gui[63] AL11
/// 122 and gui[70] 140 — srv[84] / [87] set 1; a recorded session
/// gui[133] ME23N 148 — srv[164] set 1), mode 0 or 3 does not (gui[10]
/// SE16 121 — srv[15] sets 1 then 0; gui[53] SE16N 119 — srv[72] sets
/// 1 then 3).
bool gridClickSelectsRow(SapGridModel g) => g.selectionMode == 1;

/// The `<TABLES>` blocks a click on grid line [line] of [g] flushes: the
/// SelectedCols CLEAR and the SelectedRows CLEAR (+ the row's insert when
/// [gridClickSelectsRow]), ascending by handle (gui[112]: H12 C, H14 C +
/// `C1 ="1" C2 ="0"`); a channel the creation flush named no handle for
/// is left out. The grid's owed ColPosID layout report that leads the
/// real GUI's TABLES on the FIRST frame after a grid's creation (gui[112]
/// H11, gui[10] H1, gui[133] H1 — absent from gui[127]) is the generic
/// per-creation layout flush of every client frame (the reference client's
/// ), not part of the click; it is not sent here.
String gridClickTablesXml(SapGridModel g, int line) {
  final hc = g.handles['SelectedColsOnDemand'];
  final hr = g.handles['SelectedRowsOnDemand'];
  final changes = <GridDataChange>[
    if (hc != null) GridDataChange(hc),
    if (hr != null)
      GridDataChange(hr, [
        if (gridClickSelectsRow(g)) ['${gridRowIdNumeric(g, line)}', '0'],
      ]),
  ]..sort((a, b) => a.handle.compareTo(b.handle));
  return windowsDataChangesXml(changes);
}

/// The OK-event mode of a grid round follows the focus the last paint
/// set, not the event: 0x0d while a dynpro FIELD held it (a 16/9/11 —
/// the first F4 after ME51N painted, me51n gui[7] after srv[13],
/// prefilled gui[12] after srv[19]), 0x0b once the paint focused a CFW
/// control (a 16/9/18 — every round after a value help closed: me51n
/// gui[25] / [35] / [45] / [83], prefilled gui[22] / [32]; the reference client's
/// nested_state_round WIN_OK_MODE_NESTED / WIN_OK_MODE_CONTROL_FOCUS).
const int gridOkModeFieldFocus = 0x0d;
const int gridOkModeControlFocus = 0x0b;

/// The OK-event mode for a grid round after the paint [ctx] mirrors: the
/// generic Windows window-state mode ([windowsWindowStateOkMode], reference client
/// edfd931) — 0x0b with a control focus or none, 0x0d with a NESTED
/// field cursor (ME51N's, depth 5: me51n gui[7] after srv[13]), 0x05 with
/// a FLAT one (a recorded session gui[53] `%_GC 119 3`), 0x03 in a modal.
int gridOkMode(ActionContext ctx) => windowsWindowStateOkMode(ctx);

/// GridView.ocx's cached-property serialisation order (the reference client's
/// grid_creation_flush.GRIDVIEW_PROP_ORDER — identical on every creation
/// block of a recorded session / a recorded session; the
/// deltas of a recorded session gui[25] `CurrentCellCol, CurrentCellText,
/// GridModified, CurrentCellColID` and gui[45] keep it).
const List<String> gridViewPropOrder = [
  'RowsMoved',
  'CurrentCellCol',
  'CurrentCellRow',
  'FirstVisibleColID',
  'CurrentCellText',
  'FirstVisibleRow',
  'GridModified',
  'FirstVisibleRowID',
  'CurrentCellColID',
  'CurrentCellRowID',
  'CurrentCellRowIDNumeric',
  'CurrentCellRowIDSubNumeric',
];

/// The OCX's `<IT>` attribute order (see the library doc).
const List<String> _itOrder = [
  'C9', 'C4', 'IDX', 'C17', 'C5', 'C16', 'C6', 'C15', 'C7', 'C14', 'C13',
  'C1', 'C12', 'C2', 'C11', 'C3', 'OP', 'C10', 'C8',
];

String _attr(String v) => v
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// One `<IT>` record: [idx], [op] and the cells C1..Cn, in the OCX order
/// (cells past C17 — none on the captures — follow in index order).
String ocxItRecord(int idx, String op, List<String> cells) {
  final attrs = <String, String>{
    'IDX': '$idx',
    'OP': op,
    for (var i = 0; i < cells.length; i++) 'C${i + 1}': cells[i],
  };
  final names = [
    for (final n in _itOrder)
      if (attrs.containsKey(n)) n,
    for (var i = 18; i <= cells.length; i++) 'C$i',
  ];
  return '<IT ${[for (final n in names) '$n ="${_attr(attrs[n]!)}"'].join(' ')}/>';
}

/// One DATACHANGES block of an adoption: an optional CLEAR, then [records]
/// (already spelled by [ocxItRecord]).
String ocxDataChanges(int handle, List<String> records, {bool clear = false}) {
  final b = StringBuffer('  <DATACHANGES HANDLE ="$handle">');
  if (clear) b.write('   <IT IDX ="0" OP ="C"/>');
  for (final r in records) {
    b.write('   $r');
  }
  b.write('</DATACHANGES>');
  return b.toString();
}

/// A whole DATAMANAGER document in the OCX spelling: `<TABLES>` [tables]
/// (inner DATACHANGES blocks), `<EVENTS>` one EVENT when [eventShell] is
/// given — bare, or carrying [eventParams] as PID 0.. (`<EVENT SHELLID
/// ="119" EVENTID ="3"> <PARAM PID ="0" VALUE ="…"/>…</EVENT>`,
/// a recorded session gui[112]) — `<CONTROLS>` [controls]; the order of
/// gui[25] / [45].
String ocxDataManagerXml({
  String tables = '',
  String? eventShell,
  int? eventId,
  List<String> eventParams = const [],
  List<GridControlState> controls = const [],
}) {
  final b = StringBuffer('<?xml version="1.0" encoding="sap*"?><DATAMANAGER>');
  if (tables.isNotEmpty) b.write(' <TABLES>$tables</TABLES>');
  if (eventShell != null && eventParams.isEmpty) {
    b.write(
      ' <EVENTS>  <EVENT SHELLID ="${_attr(eventShell)}" '
      'EVENTID ="$eventId"/></EVENTS>',
    );
  } else if (eventShell != null) {
    b.write(
      ' <EVENTS>  <EVENT SHELLID ="${_attr(eventShell)}" '
      'EVENTID ="$eventId">',
    );
    for (var i = 0; i < eventParams.length; i++) {
      b.write('   <PARAM PID ="$i" VALUE ="${_attr(eventParams[i])}"/>');
    }
    b.write('</EVENT></EVENTS>');
  }
  if (controls.isNotEmpty) {
    b.write(' <CONTROLS>${windowsGridControlsXml(controls)}</CONTROLS>');
  }
  b.write('</DATAMANAGER>');
  return b.toString();
}

/// The 16/15/1 UI event source of a control event on a control hosted at
/// container [path] (the level bytes of its custom-control area): flags 0,
/// event 13 (control event), control type 11 (custom control), no cell,
/// the path's u16 count and bytes, 16 zero bytes — me51n gui[45] `00 000d
/// 000b 00 000000 0000 0000 0005 0103020101 00…`; [path] `[1]` gives the
/// tree round's constant ([winUiEventControl], a recorded session
/// gui[13]).
Uint8List uiEventControlAt(List<int> path) {
  final out = Uint8List(15 + path.length + 16);
  out[2] = 0x0d;
  out[4] = 0x0b;
  ByteData.sublistView(out).setUint16(13, path.length);
  out.setRange(15, 15 + path.length, path);
  return out;
}

/// A grid control-event round `%_GC <shell> <eventId>` carrying [xml] (a
/// whole DATAMANAGER document) — see the library doc. [path] = the
/// container path of the dynpro custom control hosting the grid (the
/// 16/15/1 control-event source: a recorded session gui[45] `01 03 02 01
/// 01`, a recorded session gui[93] `02 01`); null = a grid no painted
/// custom control hosts (docked, dialog): no 16/15/1 (reference client 534a50c §3);
/// [okMode] the OK event's mode byte (default [gridOkMode]).
///
/// The focus item is the grid's 16/9/18 — the click moved the focus into
/// it (a recorded session gui[133], ME23N's BELNR hotspot after a
/// paint with a dynpro cursor) — except with [keepFocus]: a click on a
/// CHECKBOX cell leaves the focus where the paint put it and the round
/// carries that (a recorded session g[30]: `%_GC 281 2` on
/// a FLAG checkbox after srv[48]'s dynpro cursor sends that 16/9/11; the
/// grid holds the focus from the next round on, g[32] 16/9/18 `281`).
List<Uint8List> gridEventItems(
  ActionContext ctx, {
  required String shell,
  required int eventId,
  required String xml,
  List<int>? path,
  int? okMode,
  bool keepFocus = false,
}) {
  final geom = ctx.paintedGeometry;
  final control = keepFocus ? ctx.paintedControlFocus : shell;
  final painted = keepFocus && control == null ? ctx.paintedFocus : null;
  final cursor = painted == null ? null : windowsClientCursor(painted);
  // the generic Windows envelope (the tabstrip echo after the 16/12/6;
  // no 16/12/8 in a modal, the 16/4/36 after the okcode when owed —
  // windowsModalWindowRectOwed)
  return windowsControlEventEnvelope([
    stepItem(ctx.step),
    windowsEventSes(ctx),
    buildApplItem(6, 35, winCodepageValue),
    buildApplItem(12, 4, wireText(cfwGenericEventOkcode(shell, eventId))),
    for (final (sid, value) in winIdentity) buildApplItem(4, sid, value),
    buildApplItem(5, 1, Uint8List(22)..[1] = okMode ?? gridOkMode(ctx)),
    buildApplItem(
      12,
      ctx.modalNo != 0 ? 14 : 8,
      ctx.windowAreaPx(ctx.winPxHeight, ctx.winPxWidth),
    ),
    if (geom != null) buildApplItem(12, 6, geom),
    if (path != null) buildApplItem(15, 1, uiEventControlAt(path)),
    if (control != null)
      buildApplItem(9, 18, wireText(control))
    else if (cursor != null)
      buildApplItem(9, 11, cursor)
    else
      buildApplItem(9, 10, Uint8List(0)),
    xmlBlobItem(wireText(xml)),
    eomBytes,
  ], ctx, okMode: okMode ?? gridOkMode(ctx));
}
