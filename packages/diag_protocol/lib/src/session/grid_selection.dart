/// OO-ALV grid SELECTION staging — the client state SAP GUI for Windows'
/// GridView.ocx (`SAPGUI.GridViewCtrl.1`, the DATAMANAGER of the OCX)
/// keeps for a click on a grid and flushes with the NEXT frame the client
/// sends (a key, a dynpro button, an okcode, a control event). A click is
/// never a round trip of its own: the real GUI folds it into that frame's
/// type-17 DATAMANAGER XML as
///
/// * `<TABLES>` DATACHANGES on the grid's own selection DataProviders —
/// the `SelectedColsOnDemand` (one INT4 column, ABAP `LVC_S_COL2-COL_ID`)
/// and `SelectedRowsOnDemand` (two INT4 columns, `LVC_S_ROID` row id +
/// sub row id) handles the creation flush minted (`Handle =N`,
/// AssignDataObjToShell N <shell>, AssignProperty2 <role>): a CLEAR
/// (`<IT IDX ="0" OP ="C"/>`) then one INSERT per selected entry;
/// * `<CONTROLS>` the grid's changed CurrentCell* cached properties in the
/// OCX's own order (Col, Row, Text, ColID, RowID, RowIDNumeric) and its
/// first-visible GENERIC, beside a GENERIC block for every other live
/// grid, in ascending shell order.
///
/// The kernel's CL_GUI_ALV_GRID_BASE reads the selection from those server
/// copies when its DP mode is on-demand (GET_SELECTED_COLUMNS_BASE: `loop
/// at M_SELECTED_COLS` -> M_COLID_TO_FIELDNAME by COL_ID; the test system source).
///
/// Oracles (real SAP GUI for Windows unless noted):
/// * CELL click — a recorded session gui[18] (`%_GC 186 10`):
/// SelectedCols CLEAR (H22) + SelectedRows CLEAR (H24); CONTROL 186 the
/// six CurrentCell* props + GENERIC; siblings 118 / 180 / 206 GENERIC;
/// * ROW select — a recorded session gui[377] (`%_GC 627 3`):
/// SelectedCols CLEAR (H169), SelectedRows CLEAR + `<IT IDX ="1" C1 ="4"
/// C2 ="0" OP ="I"/>` (H171); the row-selector property set (Row, Text,
/// RowID, RowIDNumeric — no column) is a recorded session gui[22]'s
/// (Java GUI) in the OCX order;
/// * the same state riding an OKCODE frame — a recorded session
/// gui[36] (`/nex`: TABLES + CONTROLS, the XML item last before EOM);
/// * COLUMN select — INFERRED, no Windows capture yet: the header click's
/// property set and the SelectedCols insert `C1 = <column id>` are
/// a recorded session gui[19]'s (Java GUI, `%_GC 127 7`:
/// CurrentCellRow 0, RowID '', `<IT OP="I" C1="5" IDX="1"/>`, no C2 —
/// the provider is one INT4 column, its OptPacket 65536 against the
/// two-column providers' 32768 in the live the test system creation flush), spelled
/// as the OCX spells a one-column insert (`<IT IDX ="1" C1 ="5" OP
/// ="I"/>`, by analogy with gui[377]'s two-column one).
library;

import 'dart:typed_data';

import '../codepages.dart';
import '../framing/envelope.dart';
import '../screen/sap_grid.dart';
import 'actions.dart';

/// What a staged grid selection selects.
enum GridSelectionKind {
  /// a CELL click: the current cell moves, the selection is cleared
  cell,

  /// a row-selector click (Ctrl-click for several rows)
  rows,

  /// a column-header click — the SelectedCols insert is INFERRED (see the
  /// library doc), not pinned against a Windows capture
  columns,

  /// a deselect: both selection channels cleared, no current-cell change
  none,
}

/// One grid's client-side selection, as the frontend holds it.
class GridSelection {
  const GridSelection(
    this.shell,
    this.kind, {
    this.rows = const [],
    this.columns = const [],
    this.currentRow,
    this.currentColumn,
    this.pending = true,
  });

  /// The grid control's kernel shell id.
  final String shell;
  final GridSelectionKind kind;

  /// The selected rows: 1-based grid lines (= SapGridModel.rows index + 1).
  final List<int> rows;

  /// The selected columns' field names (SapGridModel.columns).
  final List<String> columns;

  /// The current cell after the click: its 1-based line (0 = the header)
  /// and its column field name (null = unchanged).
  final int? currentRow;
  final String? currentColumn;

  /// True until the state rode a client frame to the server.
  final bool pending;

  GridSelection flushed() => GridSelection(
    shell,
    kind,
    rows: rows,
    columns: columns,
    currentRow: currentRow,
    currentColumn: currentColumn,
    pending: false,
  );

  @override
  String toString() =>
      'GridSelection($shell ${kind.name} rows=$rows cols=$columns '
      'current=$currentRow/$currentColumn${pending ? ' pending' : ''})';
}

/// One DATACHANGES block: a CLEAR, then one INSERT per entry (its cells
/// C1..Cn in table-column order).
class GridDataChange {
  const GridDataChange(this.handle, [this.inserts = const []]);
  final int handle;
  final List<List<String>> inserts;
}

/// One CONTROL block: changed cached properties (name, value) in send
/// order, then the first-visible GENERIC (col, row) when given.
class GridControlState {
  const GridControlState(this.shell, {this.props = const [], this.generic});
  final String shell;
  final List<(String, String)> props;
  final (int, int)? generic;
}

/// GridView.ocx's CurrentCell* flush order (a recorded session
/// gui[18], a recorded session gui[377], a recorded session gui[45]).
const List<String> gridViewCurrentCellOrder = [
  'CurrentCellCol',
  'CurrentCellRow',
  'CurrentCellText',
  'CurrentCellColID',
  'CurrentCellRowID',
  'CurrentCellRowIDNumeric',
];

String _attr(String v) => v
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// The DATACHANGES blocks in the OCX's spelling (` <DATACHANGES HANDLE
/// ="22"> <IT IDX ="0" OP ="C"/></DATACHANGES>`), without the TABLES tag.
String windowsDataChangesXml(List<GridDataChange> changes) {
  final b = StringBuffer();
  for (final c in changes) {
    b.write('  <DATACHANGES HANDLE ="${c.handle}">   <IT IDX ="0" OP ="C"/>');
    for (var i = 0; i < c.inserts.length; i++) {
      b.write('   <IT IDX ="${i + 1}"');
      final cells = c.inserts[i];
      for (var k = 0; k < cells.length; k++) {
        b.write(' C${k + 1} ="${_attr(cells[k])}"');
      }
      b.write(' OP ="I"/>');
    }
    b.write('</DATACHANGES>');
  }
  return b.toString();
}

/// The CONTROL blocks in the OCX's spelling (` <CONTROL SHELLID ="186">
/// <PROPERTY VALUE ="7" NAME ="CurrentCellCol"/> <GENERIC FVCID ="1"
/// FVRID ="1" FVRIDS ="0"/></CONTROL>`), without the CONTROLS tag.
String windowsGridControlsXml(List<GridControlState> controls) {
  final b = StringBuffer();
  for (final c in controls) {
    b.write('  <CONTROL SHELLID ="${c.shell}">');
    for (final (name, value) in c.props) {
      b.write('   <PROPERTY VALUE ="${_attr(value)}" NAME ="${_attr(name)}"/>');
    }
    if (c.generic case (final col, final row)) {
      b.write('   <GENERIC FVCID ="$col" FVRID ="$row" FVRIDS ="0"/>');
    }
    b.write('</CONTROL>');
  }
  return b.toString();
}

/// A whole Windows DATAMANAGER document carrying [tables] / [controls]
/// (the inner blocks of [windowsDataChangesXml] / [windowsGridControlsXml]).
String windowsGridStateXml(String tables, String controls) {
  final b = StringBuffer('<?xml version="1.0" encoding="sap*"?><DATAMANAGER>');
  if (tables.isNotEmpty) b.write(' <TABLES>$tables</TABLES>');
  if (controls.isNotEmpty) b.write(' <CONTROLS>$controls</CONTROLS>');
  b.write('</DATAMANAGER>');
  return b.toString();
}

/// The row-id cell text of grid line [line] — the packets' own id cell,
/// else the padded `' ' * 23 + '%010d'` every SE16 / DB13 grid serves.
String gridRowIdText(SapGridModel g, int line) {
  final id = g.loadedRowIds[line];
  if (id != null && id.isNotEmpty) return id;
  return '${' ' * 23}${'$line'.padLeft(10, '0')}';
}

/// The numeric row id of grid line [line] (the id text's digits, else the
/// line itself).
int gridRowIdNumeric(SapGridModel g, int line) =>
    int.tryParse(gridRowIdText(g, line).trim()) ?? line;

/// The first-visible GENERIC a grid reports: (1, its first visible row)
/// with rows, (0, 0) without (a recorded session gui[15]
/// 118 / 180; a scrolled grid its row, a recorded session gui[74] 140
/// `FVRID ="288"`).
(int, int) gridFirstVisible(SapGridModel g) =>
    g.loadedRows.isNotEmpty ? (1, g.firstVisibleRow) : (0, 0);

/// The flush pieces of [sel] on [g]: its selection DATACHANGES (the
/// SelectedCols then the SelectedRows provider — a channel whose handle
/// the creation flush did not name is left out) and its CONTROL block.
(List<GridDataChange>, GridControlState) gridSelectionFlush(
  SapGridModel g,
  GridSelection sel,
) {
  final hc = g.handles['SelectedColsOnDemand'];
  final hr = g.handles['SelectedRowsOnDemand'];
  int colIndex(String name) {
    final i = g.columns.indexOf(name);
    if (i < 0) throw ArgumentError('grid ${g.shell} has no column $name');
    return i;
  }

  String colId(String name) {
    final i = colIndex(name);
    return '${i < g.columnIds.length ? g.columnIds[i] : i + 1}';
  }

  String cellText(int line, String name) {
    final i = g.columns.indexOf(name);
    if (i < 0) return '';
    final r = g.rowAt(line);
    if (r == null) return '';
    return i < r.length ? r[i] : '';
  }

  final tables = <GridDataChange>[
    if (hc != null)
      GridDataChange(hc, [
        if (sel.kind == GridSelectionKind.columns)
          for (final c in sel.columns) [colId(c)],
      ]),
    if (hr != null)
      GridDataChange(hr, [
        if (sel.kind == GridSelectionKind.rows)
          for (final r in sel.rows) ['${gridRowIdNumeric(g, r)}', '0'],
      ]),
  ];
  final props = <String, String>{};
  final row = sel.currentRow;
  final col = sel.currentColumn;
  switch (sel.kind) {
    case GridSelectionKind.cell:
      props
        ..['CurrentCellCol'] = '${colIndex(col!) + 1}'
        ..['CurrentCellRow'] = '$row'
        ..['CurrentCellText'] = cellText(row!, col)
        ..['CurrentCellColID'] = col
        ..['CurrentCellRowID'] = gridRowIdText(g, row)
        ..['CurrentCellRowIDNumeric'] = '${gridRowIdNumeric(g, row)}';
    case GridSelectionKind.rows:
      props
        ..['CurrentCellRow'] = '$row'
        ..['CurrentCellText'] = col == null ? '' : cellText(row!, col)
        ..['CurrentCellRowID'] = gridRowIdText(g, row!)
        ..['CurrentCellRowIDNumeric'] = '${gridRowIdNumeric(g, row)}';
    case GridSelectionKind.columns:
      // the header click (a recorded session gui[19], Java GUI): row 0,
      // no row id, no text — INFERRED for the Windows OCX
      props
        ..['CurrentCellCol'] = '${colIndex(col!) + 1}'
        ..['CurrentCellRow'] = '0'
        ..['CurrentCellText'] = ''
        ..['CurrentCellColID'] = col
        ..['CurrentCellRowID'] = ''
        ..['CurrentCellRowIDNumeric'] = '0';
    case GridSelectionKind.none:
      break;
  }
  return (
    tables,
    GridControlState(
      g.shell,
      props: [
        for (final n in gridViewCurrentCellOrder)
          if (props[n] case final v?) (n, v),
      ],
      generic: gridFirstVisible(g),
    ),
  );
}

/// [items] (one client frame's items, Windows spelling) with the staged
/// grid state merged into its DATAMANAGER XML: the DATACHANGES right after
/// the `<DATAMANAGER>` tag, the CONTROL blocks into its CONTROLS (or a new
/// CONTROLS section before `</DATAMANAGER>`). A frame without an XML item
/// (an okcode round) gets one, last before EOM — a recorded session
/// gui[36].
List<Uint8List> withGridStateXml(
  List<Uint8List> items,
  String tables,
  String controls,
) {
  if (tables.isEmpty && controls.isEmpty) return items;
  final out = <Uint8List>[];
  var merged = false;
  for (final raw in items) {
    final walk = walkItems(raw);
    if (!merged &&
        walk.items.length == 1 &&
        walk.items.single.type == itemXmlBlob) {
      var x = wireDecode(Uint8List.fromList(walk.items.single.value));
      const open = '<DATAMANAGER>';
      final at = x.indexOf(open);
      if (at >= 0) {
        if (tables.isNotEmpty) {
          final p = at + open.length;
          x = '${x.substring(0, p)} <TABLES>$tables</TABLES>${x.substring(p)}';
        }
        if (controls.isNotEmpty) {
          final c = x.lastIndexOf('</CONTROLS>');
          if (c >= 0) {
            x = '${x.substring(0, c)}$controls${x.substring(c)}';
          } else {
            final e = x.lastIndexOf('</DATAMANAGER>');
            x =
                '${x.substring(0, e)} <CONTROLS>$controls</CONTROLS>'
                '${x.substring(e)}';
          }
        }
        out.add(xmlBlobItem(wireText(x)));
        merged = true;
        continue;
      }
    }
    out.add(raw);
  }
  if (merged) return out;
  final xml = xmlBlobItem(wireText(windowsGridStateXml(tables, controls)));
  final eom = out.lastIndexWhere((b) => b.length == 1 && b[0] == itemEom);
  if (eom < 0) return out..add(xml);
  return out..insert(eom, xml);
}
