/// OO-ALV grid rows ON DEMAND — the client frame SAP GUI for Windows'
/// GridView.ocx sends when a scroll brings rows into view that its
/// on-demand DataTable does not hold: the DATAMANAGER system action
/// `%_GS 0 1` with a `<DATAREQUEST HANDLE NLINES FIRSTLINE/>` on the
/// grid's DataTableOnDemand provider (FIRSTLINE / NLINES address the
/// provider's LINES = CELLS: row r starts at line (r - 1) x (columns + 1)
/// + 1, its row-id cell), riding the frame's `<TABLES>` beside any staged
/// DATACHANGES, and every live grid's first-visible GENERIC (plus the
/// scrolled grid's changed FirstVisibleRow / FirstVisibleRowID cached
/// properties) under `<CONTROLS>`.
///
/// Oracles (a recorded session, real SAP GUI for Windows, the test system):
/// * gui[74] — the bare form (AL11 file grid 140 re-created by the server
/// at first visible row 288): items 4/38, SES, 6/35, 12/4 `%_GS 0 1`,
/// 4/9, 4/29, 4/15, 4/25, 5/1 (mode 0x0b), 12/8, 12/6, 9/18 `140`,
/// type-17 XML, EOM — the control-event envelope without its 16/15/1;
/// XML `<TABLES> <DATAREQUEST HANDLE ="17" NLINES ="929" FIRSTLINE
/// ="2033"/></TABLES> <CONTROLS> <CONTROL SHELLID ="122"> <GENERIC
/// FVCID ="1" FVRID ="1" FVRIDS ="0"/></CONTROL> <CONTROL SHELLID
/// ="140"> <GENERIC FVCID ="1" FVRID ="288" FVRIDS ="0"/></CONTROL>`;
/// * gui[68] — a user scroll to the bottom of the same grid: CONTROL 140
/// adds `FirstVisibleRow` 288 and `FirstVisibleRowID` '' (row 288 not
/// loaded yet) between the CurrentCell* properties a staged click
/// added (Col, Row, FirstVisibleRow, FirstVisibleRowID, ColID, RowID,
/// RowIDNumeric);
/// * gui[146] — SMW0 grid 123: FirstVisibleRowID of a LOADED row is its
/// row-id text (`' ' * 23 + '0000000085'`); the staged ColPosID
/// DATACHANGES ride before the DATAREQUEST in the same `<TABLES>`.
library;

import 'dart:typed_data';

import '../codepages.dart';
import '../framing/envelope.dart';
import 'actions.dart';
import 'frontend_profile.dart';
import 'grid_selection.dart';

/// GridView.ocx's cached-property flush order with the first-visible pair
/// (a recorded session gui[68], gui[146]).
const List<String> gridViewScrollPropOrder = [
  'CurrentCellCol',
  'CurrentCellRow',
  'CurrentCellText',
  'FirstVisibleRow',
  'FirstVisibleRowID',
  'CurrentCellColID',
  'CurrentCellRowID',
  'CurrentCellRowIDNumeric',
];

/// The DATAREQUEST element in the OCX's spelling (without the TABLES tag).
String windowsDataRequestXml(int handle, int firstLine, int nLines) =>
    '  <DATAREQUEST HANDLE ="$handle" NLINES ="$nLines" '
    'FIRSTLINE ="$firstLine"/>';

/// The provider line span of grid rows [firstRow]..[lastRow] (1-based) at
/// [cellsPerRow] cells per row, clamped to the provider's [lineCount]:
/// (FIRSTLINE, NLINES).
(int, int) gridRowsLineSpan(
  int firstRow,
  int lastRow,
  int cellsPerRow, {
  int? lineCount,
}) {
  final first = (firstRow - 1) * cellsPerRow + 1;
  var n = (lastRow - firstRow + 1) * cellsPerRow;
  if (lineCount != null && first + n - 1 > lineCount) {
    n = lineCount - first + 1;
  }
  return (first, n < 0 ? 0 : n);
}

/// The grid rows a DATAREQUEST line span [firstLine] + [nLines] covers
/// WHOLE at [cellsPerRow] cells per row, as (first row, last row) — empty
/// (first > last) when it covers none. The real GUI's spans need not be
/// row-aligned (a recorded session gui[74]: 2033 + 929 at 9 cells per row
/// starts inside row 226; rows 227..329 are whole).
(int, int) gridRowsCoveredBy(int firstLine, int nLines, int cellsPerRow) {
  // the first row whose row-id line (r - 1) x stride + 1 is >= firstLine
  final first = (firstLine - 1 + cellsPerRow - 1) ~/ cellsPerRow + 1;
  final last = (firstLine + nLines - 1) ~/ cellsPerRow;
  return (first, last);
}

/// The Windows client frame items of a grid DATAREQUEST round: [xml] (a
/// whole DATAMANAGER document, [windowsGridStateXml]) under the control
/// envelope of the scrolled grid [shell] (16/9/18), without the 16/15/1
/// UI event source a control EVENT carries — a recorded session gui[74].
List<Uint8List> gridDataRequestItems(
  ActionContext ctx, {
  required String shell,
  required String xml,
}) {
  final win = windowsActionItems(
    okcodeItems(ctx, '%_GS 0 1'),
    controlEvent: true,
    ctx: ctx,
  );
  final out = <Uint8List>[];
  for (final raw in win) {
    final walk = walkItems(raw);
    final it = walk.items.length == 1 ? walk.items.single : null;
    if (it != null && it.isAppl && it.id == 9 && it.sid == 10) {
      out.add(buildApplItem(9, 18, wireText(shell)));
    } else if (it != null && it.isAppl && it.id == 15 && it.sid == 1) {
      continue; // a DATAREQUEST is a system action, not a control event
    } else if (it != null && it.type == itemXmlBlob) {
      out.add(xmlBlobItem(wireText(xml)));
    } else {
      out.add(raw);
    }
  }
  return out;
}

/// The whole DATAMANAGER document of a grid DATAREQUEST round: [changes]
/// (staged DATACHANGES) then the DATAREQUEST under `<TABLES>`, [controls]
/// under `<CONTROLS>`.
String gridDataRequestXml({
  required int handle,
  required int firstLine,
  required int nLines,
  List<GridDataChange> changes = const [],
  List<GridControlState> controls = const [],
}) => windowsGridStateXml(
  windowsDataChangesXml(changes) +
      windowsDataRequestXml(handle, firstLine, nLines),
  windowsGridControlsXml(controls),
);
