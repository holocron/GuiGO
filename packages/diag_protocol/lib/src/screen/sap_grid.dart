/// OO-ALV grid controls (`SAPGUI.GridViewCtrl.1`, CL_GUI_ALV_GRID — the
/// SE16 Data Browser hit list, …): the field catalog and the cells the
/// server pushes through the DataProvider in the control's creation flush,
/// assembled into rows for rendering (read side only).
///
/// Wire shape (real SAP GUI for Windows, a recorded session
/// srv[17], SE16 T001 F8; reference client twin a recorded session): the grid
/// wave creates the control (`CreateControl(121, SAPGUI.GridViewCtrl.1, …)`)
/// and then hands it, each as an X-R3TABLE DataProvider push bound by role:
/// * `InfoTable` — the field catalog, one 904-byte line per column
/// (line i = column id i): field name C(30) at offset 0, the header
/// text C(120) in the 4th field, the output length (chars) in the 5th,
/// a second C(120) text (tooltip) in the 9th;
/// * `DataTableOnDemand` — the cell packets: 448-byte cells `I colid,
/// I row, I style, C text[384], …` (colid -1 = the row-id cell), its
/// `LineCount` = rows x (columns + 1);
/// * `RowIDNumericOnDemand` — the row ids, its `LineCount` = the rows;
/// * ColPosID / SelectedCols / SelectedRows — empty descriptors here.
/// Pairing is by the bindings' kernel shell ([dpPushBindings]).
library;

import 'dart:collection';
import 'dart:typed_data';

import '../cfw/context_menu.dart' show SapMenuEntry;
import '../cfw/control_toolbar.dart';
import '../cfw/dp_cache.dart';
import '../cfw/flush_call.dart';
import '../cfw/html_viewer.dart' show SapToolbarButton;
import 'sap_tree.dart';

/// One ALV grid as delivered so far.
class SapGridModel {
  SapGridModel({
    required this.shell,
    List<String>? columns,
    List<String>? titles,
    List<int>? widths,
    List<List<String>>? rows,
    this.totalRows,
    List<int>? columnIds,
    List<String>? rowIds,
    Map<String, int>? handles,
    Map<int, List<String>>? loadedRows,
    Map<int, String>? loadedRowIds,
    this.firstVisibleRow = 1,
    this.lineCount,
    this.optPacket,
    Map<int, Map<String, String>>? modifiedCells,
    Set<String>? hotspotColumns,
    Map<int, Set<String>>? hotspotCells,
    Map<int, Map<String, bool>>? checkboxCells,
    this.selectionMode,
    List<SapToolbarButton>? toolbar,
    Map<String, List<SapMenuEntry>>? toolbarMenus,
  }) : columns = columns ?? [],
       toolbar = toolbar ?? [],
       toolbarMenus = toolbarMenus ?? {},
       hotspotColumns = hotspotColumns ?? {},
       hotspotCells = hotspotCells ?? {},
       checkboxCells = checkboxCells ?? {},
       modifiedCells = modifiedCells ?? {},
       titles = titles ?? [],
       widths = widths ?? [],
       rows = rows ?? [],
       columnIds = columnIds ?? [],
       rowIds = rowIds ?? [],
       handles = handles ?? {},
       loadedRows = loadedRows ?? _byLine(rows),
       loadedRowIds = loadedRowIds ?? _byLine(rowIds);

  static Map<int, T> _byLine<T>(List<T>? l) => {
    for (var i = 0; i < (l?.length ?? 0); i++) i + 1: l![i],
  };

  /// The control's kernel shell id (`121`).
  String shell;

  /// Field names in display order (`MANDT`, `BUKRS`, …).
  List<String> columns;

  /// Column headings from the InfoTable (the fieldcat header text the
  /// server chose — SE16 sends the field name or the field label per the
  /// user's settings); '' where the wire carries none.
  List<String> titles;

  /// Display widths in characters (the fieldcat output length), empty when
  /// the wire did not say.
  List<int> widths;

  /// Rows delivered so far, row i = rows[i] (= grid line i + 1); a row is
  /// listed only once all of its cells arrived.
  List<List<String>> rows;

  /// The grid's total row count when the server states it (the row-id
  /// provider's LineCount), else null. More than [rows].length means the
  /// rest is still on the server (on-demand fetch).
  int? totalRows;

  /// The numeric column id of each column (the InfoTable's 18th field —
  /// the id the ColPosID / SelectedCols channels and M_COLID_TO_FIELDNAME
  /// key on: SM12's CLIENT is position 2 but id 3, a recorded session
  /// srv[24]); the 1-based position where the catalog carries none.
  List<int> columnIds;

  /// The row-id cell text of each row in [rows] (the packets' colid -1
  /// cell: `' ' * 23 + '0000000001'`), '' where none arrived.
  List<String> rowIds;

  /// The grid's DataProvider handles by role (`SelectedRowsOnDemand` ->
  /// 15, …) from the creation flush's `Handle` / AssignDataObjToShell.
  Map<String, int> handles;

  /// EVERY whole row delivered so far by 1-based grid line — the creation
  /// push AND the windows fetched on demand ([SapSession.fetchGridRows]),
  /// sparse: line 226 may be loaded while 92..225 are not. [rows] is only
  /// its gap-free head (lines 1..n).
  Map<int, List<String>> loadedRows;

  /// The row-id cell text of each line in [loadedRows].
  Map<int, String> loadedRowIds;

  /// The grid's first visible row (1-based) as the client reports it in
  /// its first-visible GENERIC / FirstVisibleRow property: 1 until a
  /// scroll moves it or the server sets it (SetFirstVisibleRowIDNumeric).
  int firstVisibleRow;

  /// The DataTableOnDemand provider's `LineCount` — its CELLS, rows x
  /// (columns + the row-id cell); null when the wire did not say.
  int? lineCount;

  /// The DataTableOnDemand provider's `OptPacket` (the packet size in
  /// cells the server prefers per DATAREQUEST), null when unknown.
  int? optPacket;

  /// The cells the server set by a value help and the frontend adopted
  /// (the `DeltaTableModified` push — grid_edit_actions.dart), not yet
  /// confirmed by its `DeltaTable` push: 1-based line -> column field name
  /// -> value. The value is in [loadedRows] already; this marks it as an
  /// edit pending in the grid's ModifiedCells provider.
  Map<int, Map<String, String>> modifiedCells;

  /// The columns (field names) the catalog declares HOTSPOT: a single
  /// click on one of their cells fires the grid's hotspot click (EVENTID
  /// 2, grid_edit_actions.dart). The InfoTable's style field (the 7th)
  /// carries ALV's MC_STYLE_HOTSPOT bit 0x00200000 — a recorded session
  /// enjoy srv[164] (ME23N PO history grid 148): BELNR `3147776` =
  /// 0x00300800 against its siblings' `1050624` = 0x00100800
  /// (MC_STYLE_HOTSPOT_NO), and the real GUI fired `%_GC 148 2` on a
  /// BELNR cell (gui[133]); no column of the ST22 hit list
  /// (a recorded session srv[157]) or of SE16 (srv[15]) has it.
  Set<String> hotspotColumns;

  /// The CELLS the server styled HOTSPOT one by one, beyond
  /// [hotspotColumns]: 1-based line -> field names. A DataTableOnDemand
  /// cell's own style (its 3rd field) carries the same MC_STYLE_HOTSPOT
  /// bit 0x00200000 when the ALV's cell style table (LVC_S_STYL) sets it —
  /// the DBA cockpit's load history KPI grid 281 (a recorded session
  /// load_history srv[40..42]): column FLAG's catalog style 0x00121000
  /// has no hotspot, every FLAG cell does (0x00240000 checked / 0x00220000
  /// unchecked: the checkbox bits 0x00040000 / 0x00020000 beside it), and
  /// the real GUI fired `%_GC 281 2` on a FLAG cell (gui[30]).
  Map<int, Set<String>> hotspotCells;

  /// The CHECKBOX cells (1-based line -> field name -> checked): a cell
  /// style with the checkbox bit 0x00020000 (unchecked) or 0x00040000
  /// (checked) — a recorded session srv[40..42], the KPI
  /// grid's FLAG (0x00240000 + text `X` on the shown KPI, 0x00220000 + ''
  /// on the others) and the hosts grid's ACTIVE (0x00040000 / 0x00020000).
  Map<int, Map<String, bool>> checkboxCells;

  /// The cell's CurrentCellText as the OCX reports it: a checkbox cell's
  /// state `1` / `0` (a recorded session g[24]: `1` for the
  /// checked FLAG / ACTIVE cell of row 1; g[30]: `0` for the unchecked FLAG
  /// of row 2), any other cell its text; '' for an undelivered one.
  String currentCellText(int line, String column) {
    final box = checkboxCells[line]?[column];
    if (box != null) return box ? '1' : '0';
    final i = columns.indexOf(column);
    final r = rowAt(line);
    if (i < 0 || r == null) return '';
    return i < r.length ? r[i] : '';
  }

  /// Whether cell ([line], [column]) fires the hotspot click: its column
  /// or the cell itself is styled HOTSPOT.
  bool isHotspot(int line, String column) =>
      hotspotColumns.contains(column) ||
      (hotspotCells[line]?.contains(column) ?? false);

  /// How many of [rows] hold a non-blank cell (what the layout sizes the
  /// grid's pane by). Memoized per rows list and per row: a built model's
  /// rows never change, and a build after an on-demand fetch shares the
  /// untouched row lists ([SapGridAssembler.build]) — the layout's scan
  /// trimmed every cell of every row per composition (audit zcode P-03).
  int get nonEmptyRowCount => _nonEmptyRows[rows] ??= () {
        var n = 0;
        for (final r in rows) {
          if (_rowHasText[r] ??= r.any((c) => c.trim().isNotEmpty)) n++;
        }
        return n;
      }();

  /// Whether any cell of the grid is a hotspot.
  bool get hasHotspots =>
      hotspotColumns.isNotEmpty || hotspotCells.values.any((s) => s.isNotEmpty);

  /// The GridView's `SelectionMode` property as the creation queue last
  /// set it (null when no queue set it): 1 on the grids whose cell click
  /// also selects the row — their double-click / hotspot click flushes a
  /// SelectedRows insert (grid_edit_actions.dart gridClickSelectsRow).
  int? selectionMode;

  /// The grid's built-in toolbar (its `ToolBarButtonsTable2` push, in
  /// display order, separators included — control_toolbar.dart); empty
  /// when the grid has none (the ALV's NO_TOOLBAR layout).
  List<SapToolbarButton> toolbar;

  /// fcode -> the static menu of a toolbar menu button (the grid's
  /// `SetToolBarMenuStatic` pushes: SM12's `&MB_VARIANT` -> `&COL0`,
  /// `&LOAD`, `&SAVE`, `&MAINTAIN`).
  Map<String, List<SapMenuEntry>> toolbarMenus;

  /// Whether grid line [line] (1-based) is loaded.
  bool isRowLoaded(int line) => loadedRows.containsKey(line);

  /// The cells of grid line [line], null while it is not loaded.
  List<String>? rowAt(int line) => loadedRows[line];

  /// The first line at or after [from] that is not loaded yet, null when
  /// every line up to [totalRows] is (or the total is unknown and nothing
  /// after the last loaded line is known to exist).
  int? nextUnloadedRow([int from = 1]) {
    final total = totalRows;
    if (total == null) return null;
    for (var l = from < 1 ? 1 : from; l <= total; l++) {
      if (!loadedRows.containsKey(l)) return l;
    }
    return null;
  }

  @override
  String toString() =>
      'SapGridModel($shell: ${columns.length} cols x ${loadedRows.length}'
      '${totalRows == null ? '' : '/$totalRows'} rows)';
}

final Expando<int> _nonEmptyRows = Expando('grid non-empty rows');
final Expando<bool> _rowHasText = Expando('grid row has text');

/// InfoTable line fields (0-based positions in its fixed 26-field FORMAT).
const int _infoName = 0;
const int _infoWidth = 4;
const int _infoStyle = 6;
const int _infoColId = 17;

/// The most rows one [SapGridAssembler.markRowsCovered] call marks.
const int maxCoveredSpan = 1 << 16;

/// ALV's MC_STYLE_HOTSPOT bit of the InfoTable style field (see
/// [SapGridModel.hotspotColumns]).
const int gridStyleHotspot = 0x00200000;

/// A DataTableOnDemand cell style's checkbox bits ([SapGridModel
/// .checkboxCells]): unchecked / checked.
const int gridStyleCheckbox = 0x00020000;
const int gridStyleCheckboxChecked = 0x00040000;
const int _minLabelWidth = 40; // the header-text fields are the C(120) ones

/// DataTableOnDemand cell fields (0-based positions in its 17-field FORMAT).
const int _cellCol = 0;
const int _cellRow = 1;
const int _cellText = 3;
const int _cellStyle = 2;

const int _typeC = 0x43;
const int _typeI = 0x49;

/// The grid state one shell accumulates across its pushes.
class SapGridAssembler {
  SapGridAssembler(this.shell);

  final String shell;
  final List<String> _names = [];
  final List<String> _titles = [];
  final List<int> _widths = [];
  final List<int> _colIds = [];
  final Set<String> _hotspots = {};

  /// See [SapGridModel.selectionMode].
  int? get selectionMode => _selectionMode;
  set selectionMode(int? v) {
    _selectionMode = v;
    _version++;
  }

  int? _selectionMode;

  /// The grid's toolbar buttons and static menus (see
  /// [SapGridModel.toolbar] / [SapGridModel.toolbarMenus]).
  List<SapToolbarButton> get toolbar => _toolbar;
  List<SapToolbarButton> _toolbar = const [];
  final Map<String, List<SapMenuEntry>> _toolbarMenus = {};

  /// A new toolbar push: its buttons replace the old ones; a static menu
  /// stays only while its button is still a menu button (the queue that
  /// re-pushes the toolbar hands the menus again — a recorded session
  /// srv[116] verbs 480 / 489..505).
  void setToolbar(List<SapToolbarButton> buttons) {
    _toolbar = List.unmodifiable(buttons);
    final menus = {for (final b in buttons) if (b.hasMenu) b.code};
    _toolbarMenus.removeWhere((k, _) => !menus.contains(k));
    _version++;
  }

  void setToolbarMenu(String fcode, List<SapMenuEntry> entries) {
    _toolbarMenus[fcode] = List.unmodifiable(entries);
    _version++;
  }

  /// The server object token the grid's pushes name it by (the
  /// AssignProperty2 owner `21` of SM12's lock list) — a later queue
  /// re-pushing its toolbar may name it by that alone.
  String? owner;

  /// Bumped by every change [build] reads ([handles] is compared by
  /// content): the built model is reused until the next one (audit #15 —
  /// [SapSession.grids] rebuilt every grid, sorting every line, per read).
  int _version = 0;
  SapGridModel? _built;
  int _builtVersion = -1;
  Map<String, int> _builtHandles = const {};

  /// DataProvider role -> handle (see [SapGridModel.handles])
  final Map<String, int> handles = {};

  /// row (1-based grid line) -> column id -> text
  final Map<int, Map<int, String>> _cells = {};

  /// row (1-based grid line) -> the column positions whose own cell style
  /// is HOTSPOT ([SapGridModel.hotspotCells])
  final Map<int, Set<int>> _hotspotCells = {};

  /// row -> column position -> checked ([SapGridModel.checkboxCells])
  final Map<int, Map<int, bool>> _checkboxCells = {};
  int? _rowCount;
  int? _cellCount;
  int _delivered = 0; // cell records folded in (row ids included)

  /// rows a DATAREQUEST reply covered whole: whole even where the provider
  /// omitted initial cells (see [markRowsCovered])
  final Set<int> _covered = {};

  /// The DataTableOnDemand provider's OptPacket (cells), when known.
  int? get optPacket => _optPacket;
  set optPacket(int? v) {
    _optPacket = v;
    _version++;
  }

  int? _optPacket;

  /// The DataTableOnDemand provider's FORMAT type codes (17 fields `I I I
  /// C … C …` on GridView — the cells a DataTable DATACHANGES record
  /// carries), empty until a push declared them.
  List<int> get cellTypes => _cellTypes;
  set cellTypes(List<int> v) {
    _cellTypes = v;
    _version++;
  }

  List<int> _cellTypes = const [];

  /// Cells set client-side (an adopted value help): line -> column
  /// position (1-based) -> value; see [SapGridModel.modifiedCells]. Changed
  /// through [setCellText] / [resetCells] only.
  final Map<int, Map<int, String>> pendingEdits = {};

  /// Set the text of cell ([line], [position]) — a value the frontend
  /// adopted ([pending]: still to be confirmed by the server) or the
  /// server's confirmation of it.
  void setCellText(int line, int position, String text, {bool pending = true}) {
    _version++;
    _dirtyRows.add(line);
    final cells = _cells[line] ??= {};
    if (!cells.containsKey(position)) _delivered++;
    cells[position] = text;
    if (pending) {
      (pendingEdits[line] ??= {})[position] = text;
    } else {
      pendingEdits[line]?.remove(position);
      if (pendingEdits[line]?.isEmpty ?? false) pendingEdits.remove(line);
    }
  }

  /// The first visible row the client reports (see
  /// [SapGridModel.firstVisibleRow]).
  int get firstVisibleRow => _firstVisibleRow;
  set firstVisibleRow(int v) {
    _firstVisibleRow = v;
    _version++;
    _scrollBumps++;
  }

  int _firstVisibleRow = 1;

  /// The [_version] bumps a scroll alone made: a build whose version moved
  /// by these only reuses the derived maps of the last one (audit
  /// 2026-10-17 N4).
  int _scrollBumps = 0;

  bool get hasCatalog => _names.isNotEmpty;

  /// The DataTable line stride: cells per row (the columns + the row-id
  /// cell) — LineCount / rows when both are known and divide, else the
  /// catalog width + 1; null without a catalog.
  int? get cellsPerRow {
    final cc = _cellCount, rc = _rowCount;
    if (cc != null && rc != null && rc > 0 && cc % rc == 0 && cc > 0) {
      return cc ~/ rc;
    }
    return _names.isEmpty ? null : _names.length + 1;
  }

  /// Bumped by every change of the grid's CONTENT (catalog, cells, counts)
  /// — not by its toolbar or selection mode: a toolbar re-push does not
  /// invalidate the rows a selection names.
  int get contentStamp => _contentStamp;
  int _contentStamp = 0;

  /// Drop every delivered cell (the grid's content was rebuilt: a new
  /// catalog, a new DataTableOnDemand provider after sort / filter).
  void resetCells() {
    _contentStamp++;
    _version++;
    _cells.clear();
    _allRowsDirty = true;
    _hotspotCells.clear();
    _checkboxCells.clear();
    _covered.clear();
    pendingEdits.clear();
    _delivered = 0;
  }

  /// Rows [first]..[last] (1-based) arrived whole in a DATAREQUEST reply
  /// whose line span covered them — a cell the provider omitted is ''.
  /// At most [maxCoveredSpan] rows from [first] are marked: the span is
  /// the request's, which a wire count drove to ~10^9 rows (audit
  /// 2026-10-17 P0-8).
  void markRowsCovered(int first, int last) {
    _version++;
    if (last - first >= maxCoveredSpan) last = first + maxCoveredSpan - 1;
    for (var r = first; r <= last; r++) {
      // a row only changes if it was not covered yet and holds cells
      if (_covered.add(r) && _cells.containsKey(r)) _dirtyRows.add(r);
    }
  }

  /// Fold the field catalog in. A new catalog is a new grid content: the
  /// cells delivered for the old one are dropped. False when [t] is not an
  /// InfoTable (first field not the C name column).
  bool applyInfoTable(DpTable t) {
    if (t.rows.isEmpty || t.columns.length <= _infoWidth) return false;
    if (t.types.isEmpty || t.types[_infoName] != _typeC) return false;
    _version++;
    _contentStamp++;
    final labelCols = [
      for (var i = _infoName + 1; i < t.columns.length; i++)
        if (t.types[i] == _typeC && t.lengths[i] >= _minLabelWidth)
          t.columns[i],
    ];
    final widthKey = t.types[_infoWidth] == _typeI
        ? t.columns[_infoWidth]
        : null;
    _names.clear();
    _titles.clear();
    _widths.clear();
    _colIds.clear();
    _hotspots.clear();
    resetCells();
    final styleKey = t.columns.length > _infoStyle &&
            t.types.length > _infoStyle &&
            t.types[_infoStyle] == _typeI
        ? t.columns[_infoStyle]
        : null;
    for (final r in t.rows) {
      final name = (r[t.columns[_infoName]] ?? '').trim();
      _names.add(name);
      final style = styleKey == null ? null : int.tryParse(r[styleKey] ?? '');
      if (style != null && (style & gridStyleHotspot) != 0) _hotspots.add(name);
      _titles.add(
        labelCols
            .map((c) => (r[c] ?? '').trim())
            .firstWhere((s) => s.isNotEmpty, orElse: () => ''),
      );
      if (widthKey != null) _widths.add(int.tryParse(r[widthKey] ?? '') ?? 0);
      final idKey = t.columns.length > _infoColId &&
              t.types.length > _infoColId &&
              t.types[_infoColId] == _typeI
          ? t.columns[_infoColId]
          : null;
      final id = idKey == null ? null : int.tryParse(r[idKey] ?? '');
      _colIds.add(id ?? _names.length);
    }
    return true;
  }

  /// Fold one DataTableOnDemand packet's cells in. False when [t] is not a
  /// cell packet. A cell carries its absolute row (DataTableLine row); one
  /// that names none (row 0) is placed by its line instead when the packet's
  /// [firstLine] (its InsertPacket start) is known: line = firstLine + its
  /// record index, row = (line - 1) ~/ [cellsPerRow] + 1.
  bool applyCellPacket(DpTable t, {int? firstLine}) {
    if (t.columns.length <= _cellText || t.types.length <= _cellText) {
      return false;
    }
    if (t.types[_cellCol] != _typeI ||
        t.types[_cellRow] != _typeI ||
        t.types[_cellText] != _typeC) {
      return false;
    }
    _version++;
    _contentStamp++;
    if (t.types.length > cellTypes.length) cellTypes = List.of(t.types);
    final colKey = t.columns[_cellCol];
    final rowKey = t.columns[_cellRow];
    final textKey = t.columns[_cellText];
    final styleKey = t.types[_cellStyle] == _typeI ? t.columns[_cellStyle] : null;
    final stride = cellsPerRow;
    for (var i = 0; i < t.rows.length; i++) {
      final r = t.rows[i];
      final col = int.tryParse(r[colKey] ?? '');
      var row = int.tryParse(r[rowKey] ?? '');
      if (row == 0 && firstLine != null && firstLine > 0 && stride != null) {
        row = (firstLine + i - 1) ~/ stride + 1;
      }
      if (col == null || row == null || row < 1) continue;
      _dirtyRows.add(row);
      final cells = _cells[row] ??= {};
      if (!cells.containsKey(col)) _delivered++;
      cells[col] = (r[textKey] ?? '').trimRight();
      if (col >= 1 && styleKey != null) {
        final style = int.tryParse((r[styleKey] ?? '').trim()) ?? 0;
        if ((style & gridStyleHotspot) != 0) {
          (_hotspotCells[row] ??= {}).add(col);
        } else {
          _hotspotCells[row]?.remove(col);
        }
        if ((style & gridStyleCheckboxChecked) != 0) {
          (_checkboxCells[row] ??= {})[col] = true;
        } else if ((style & gridStyleCheckbox) != 0) {
          (_checkboxCells[row] ??= {})[col] = false;
        } else {
          _checkboxCells[row]?.remove(col);
        }
      }
    }
    return true;
  }

  void setRowCount(int? n) {
    if (n != null && n >= 0) {
      _rowCount = n;
      _contentStamp++;
      _version++;
    }
  }

  void setCellCount(int? n) {
    if (n != null && n >= 0) {
      _cellCount = n;
      _contentStamp++;
      _version++;
    }
  }

  /// The grid as delivered so far — the SAME model while nothing it shows
  /// changed (readers never change a model).
  SapGridModel build() {
    final b = _built;
    if (b != null &&
        _builtVersion == _version &&
        _sameHandles(_builtHandles, handles)) {
      return b;
    }
    final m = _build();
    _built = m;
    _builtVersion = _version;
    _builtHandles = Map.of(handles);
    return m;
  }

  static bool _sameHandles(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  // The materialized whole rows, kept across builds (audit #3: every
  // build — a firstVisibleRow / DATAREQUEST hop — re-sorted every line and
  // copied every cell of every loaded row; an SE16-class grid a few
  // thousand rows in copied > 1 M cell references per 40-row scroll hop).
  // Only the lines a change touched ([_dirtyRows]) are re-materialized;
  // everything is when the row rule itself moved (a reset, a new catalog
  // width, the provider's every-cell-arrived verdict).
  final SplayTreeMap<int, List<String>> _rowCache = SplayTreeMap();
  final SplayTreeMap<int, String> _rowIdCache = SplayTreeMap();
  final Set<int> _dirtyRows = {};
  bool _allRowsDirty = true;
  bool _cacheComplete = false;
  int _cacheWidth = -1;

  /// The row maps / head lists of the last build, reused while no row
  /// changed (a model never changes once built, so sharing them is safe).
  (Map<int, List<String>>, Map<int, String>, List<List<String>>, List<String>)?
      _builtRows;

  /// Re-materialize line [line] into the row cache.
  void _materialize(int line, int n, bool complete) {
    final cells = _cells[line];
    if (n == 0 || cells == null) {
      _rowCache.remove(line);
      _rowIdCache.remove(line);
      return;
    }
    // a packet may end mid-row (OptPacket cells): a row shows once
    // whole — or once a DATAREQUEST reply covered its whole line span
    var whole = complete || _covered.contains(line);
    if (!whole) {
      whole = true;
      for (var c = 1; c <= n; c++) {
        if (!cells.containsKey(c)) {
          whole = false;
          break;
        }
      }
    }
    if (!whole) {
      _rowCache.remove(line);
      _rowIdCache.remove(line);
      return;
    }
    _rowCache[line] = [for (var c = 1; c <= n; c++) cells[c] ?? ''];
    _rowIdCache[line] = cells[-1] ?? '';
  }

  SapGridModel _build() {
    final n = _names.length;
    // every declared cell arrived (the provider omits initial cells — the
    // ST04 message grid: 5 records for a 13-column row): a gap is ''
    final complete = _cellCount != null && _delivered >= _cellCount!;
    var rowsChanged = _builtRows == null;
    if (_allRowsDirty || complete != _cacheComplete || n != _cacheWidth) {
      _rowCache.clear();
      _rowIdCache.clear();
      if (n > 0) {
        for (final line in _cells.keys) {
          _materialize(line, n, complete);
        }
      }
      rowsChanged = true;
    } else if (_dirtyRows.isNotEmpty) {
      for (final line in _dirtyRows) {
        _materialize(line, n, complete);
      }
      rowsChanged = true;
    }
    _dirtyRows.clear();
    _allRowsDirty = false;
    _cacheComplete = complete;
    _cacheWidth = n;
    if (rowsChanged) {
      // line order, as the sorted scan built them
      final loaded = Map<int, List<String>>.of(_rowCache);
      final loadedIds = Map<int, String>.of(_rowIdCache);
      // the gap-free head (lines 1..k) is what [SapGridModel.rows] lists
      final head = <List<String>>[];
      final headIds = <String>[];
      for (var line = 1; loaded.containsKey(line); line++) {
        head.add(loaded[line]!);
        headIds.add(loadedIds[line]!);
      }
      _builtRows = (loaded, loadedIds, head, headIds);
    }
    final (loaded, loadedIds, rows, rowIds) = _builtRows!;
    int? total = _rowCount;
    final cc = _cellCount;
    if (total == null && cc != null && n > 0 && cc % (n + 1) == 0) {
      total = cc ~/ (n + 1);
    }
    final key = _version - _scrollBumps;
    final prev = _built;
    final d = prev != null && _derivedKey == key && _sameHandles(prev.handles, handles)
        ? prev
        : null;
    _derivedKey = key;
    return SapGridModel(
      shell: shell,
      columns: d?.columns ?? List.of(_names),
      titles: d?.titles ?? List.of(_titles),
      widths: d?.widths ?? (_widths.length == n ? List.of(_widths) : []),
      rows: rows,
      totalRows: total,
      columnIds: d?.columnIds ?? List.of(_colIds),
      rowIds: rowIds,
      handles: d?.handles ?? Map.of(handles),
      loadedRows: loaded,
      loadedRowIds: loadedIds,
      firstVisibleRow: firstVisibleRow,
      lineCount: _cellCount,
      optPacket: optPacket,
      modifiedCells: d?.modifiedCells ?? {
        for (final e in pendingEdits.entries)
          e.key: {
            for (final c in e.value.entries)
              if (c.key >= 1 && c.key <= n) _names[c.key - 1]: c.value,
          },
      },
      hotspotColumns: d?.hotspotColumns ?? Set.of(_hotspots),
      hotspotCells: d?.hotspotCells ?? {
        for (final e in _hotspotCells.entries)
          if (e.value.any((c) => c >= 1 && c <= n))
            e.key: {
              for (final c in e.value)
                if (c >= 1 && c <= n) _names[c - 1],
            },
      },
      checkboxCells: d?.checkboxCells ?? {
        for (final e in _checkboxCells.entries)
          if (e.value.isNotEmpty)
            e.key: {
              for (final c in e.value.entries)
                if (c.key >= 1 && c.key <= n) _names[c.key - 1]: c.value,
            },
      },
      selectionMode: selectionMode,
      toolbar: _toolbar,
      toolbarMenus: d?.toolbarMenus ?? Map.unmodifiable(_toolbarMenus),
    );
  }

  int _derivedKey = -1;
}

/// Fold every grid push of one complete OLE_FLUSH_CALL RFC value into
/// [grids] (keyed by kernel shell, created on first sight). [shellOf]
/// resolves a binding that names its grid only by an owner token (a
/// control minted in an earlier flush). Returns the shells it touched.
/// [parsed] = [rfc] already parsed (the session parses a completed call
/// once for every side model it feeds).
Set<String> foldGridCall(
  Uint8List rfc,
  Map<String, SapGridAssembler> grids, {
  String? Function(String owner)? shellOf,
  FlushCall? parsed,
}) {
  final call = parsed ?? parseFlushCall(rfc);
  final modes = gridSelectionModeSets(call, shellOf: shellOf);
  final menuVerbs = [
    for (final v in toolbarMenuVerbsOf(call))
      if (v.verb == gridStaticMenuVerb) v,
  ];
  final bindings = [
    for (final b in dpPushBindings(call))
      if (_gridRoles.contains(b.role)) b,
  ];
  if (bindings.isEmpty &&
      (menuVerbs.isNotEmpty ||
          dpPushBindings(call).any((b) => gridToolbarRoles.contains(b.role)))) {
    // a queue re-pushing a grid's toolbar alone (no catalog in it)
    return _foldGridToolbars(rfc, call, grids, menuVerbs, shellOf, {}, modes);
  }
  if (bindings.isEmpty) {
    // a later queue setting the mode of a grid already read
    final touched = <String>{};
    for (final (shell, mode) in modes) {
      final g = grids[shell];
      if (g != null && g.selectionMode != mode) {
        g.selectionMode = mode;
        touched.add(shell);
      }
    }
    return touched;
  }
  final cache = DpCache()..ingestValue(rfc);
  final touched = <String>{};

  // an owner token another binding of the same queue names a shell for
  // (the ST04 message grid's re-pushed InfoTable: owner 12 only, its
  // DataTableOnDemand: owner 12 + shell 118)
  final ownerShell = <String, String>{
    for (final b in bindings)
      if ((b.owner?.trim() ?? '').isNotEmpty &&
          (b.shell?.trim() ?? '').isNotEmpty)
        b.owner!.trim(): b.shell!.trim(),
  };

  String? shellOfBinding(DpPushBinding b) {
    final s = b.shell?.trim();
    if (s != null && s.isNotEmpty) return s;
    final o = b.owner?.trim();
    if (o == null || o.isEmpty) return null;
    return shellOf?.call(o) ?? ownerShell[o] ?? _gridOfOwner(grids, o);
  }

  Iterable<DpTable> tablesOf(DpPushBinding b) sync* {
    for (final u in b.urls) {
      final seg = cache.byUrl[u];
      if (seg == null) continue;
      final t = decodeNamedDpTable(seg);
      if (t != null) yield t;
    }
  }

  // the catalog first: a new InfoTable resets its grid's cells, and the
  // cell packets of the same queue must land after it
  for (final b in bindings.where((b) => b.role == 'InfoTable')) {
    final shell = shellOfBinding(b);
    if (shell == null) continue;
    for (final t in tablesOf(b)) {
      if ((grids[shell] ??= SapGridAssembler(shell)).applyInfoTable(t)) {
        touched.add(shell);
      }
    }
  }
  for (final b in [
    for (final b in dpPushBindings(call))
      if (b.role != 'InfoTable' && b.role != null) b,
  ]) {
    final shell = shellOfBinding(b);
    if (shell == null) continue;
    final g = grids[shell];
    if (g == null) {
      continue; // a provider without a catalog is not a grid we read
    }
    final was = g.handles[b.role];
    if (b.handle case final h? when b.role != null) g.handles[b.role!] = h;
    switch (b.role) {
      case 'DataTableOnDemand':
        // a NEW provider (sort / filter / refresh re-push without a new
        // catalog) is new content: rows fetched from the old one are stale
        if (was != null && b.handle != null && was != b.handle) {
          g.resetCells();
        }
        g.setCellCount(b.lineCount);
        for (final t in tablesOf(b)) {
          g.applyCellPacket(t);
        }
        touched.add(shell);
      case 'RowIDNumericOnDemand':
        g.setRowCount(b.lineCount);
        touched.add(shell);
    }
  }
  for (final (shell, mode) in modes) {
    final g = grids[shell];
    if (g == null) continue;
    if (g.selectionMode != mode) touched.add(shell);
    g.selectionMode = mode;
  }
  // the owner tokens this queue tied to a grid
  ownerShell.forEach((o, sh) {
    if (grids[sh] != null) _noteOwner(grids, o, sh);
  });
  touched.addAll(
    _foldGridToolbars(rfc, call, grids, menuVerbs, shellOf, ownerShell, const [],
        cache: cache),
  );
  return touched;
}

/// The grid whose pushes last named [owner] (see [SapGridAssembler.owner]).
String? _gridOfOwner(Map<String, SapGridAssembler> grids, String owner) {
  for (final e in grids.entries) {
    if (e.value.owner == owner) return e.key;
  }
  return null;
}

void _noteOwner(Map<String, SapGridAssembler> grids, String owner, String shell) {
  for (final g in grids.values) {
    if (g.owner == owner && g.shell != shell) g.owner = null;
  }
  grids[shell]?.owner = owner;
}

/// Fold the toolbar pushes ([gridToolbarRoles]) and the static menus
/// ([gridStaticMenuVerb]) of [call] into the grids they name: by the
/// binding's shell, the owner token another binding of the queue ties to a
/// shell ([ownerShell]), the session's alias ([shellOf]) or the grid that
/// last carried the token. The static menu is a verb ON the grid object:
/// its VARS row is the grid's CreateControl result in a creation queue,
/// else its handle token is the owner. Returns the grids touched.
Set<String> _foldGridToolbars(
  Uint8List rfc,
  FlushCall call,
  Map<String, SapGridAssembler> grids,
  List<ToolbarMenuVerb> menuVerbs,
  String? Function(String owner)? shellOf,
  Map<String, String> ownerShell,
  List<(String, int)> modes, {
  DpCache? cache,
}) {
  final touched = <String>{};
  for (final (shell, mode) in modes) {
    final g = grids[shell];
    if (g != null && g.selectionMode != mode) {
      g.selectionMode = mode;
      touched.add(shell);
    }
  }
  final pushes = [
    for (final b in dpPushBindings(call))
      if (gridToolbarRoles.contains(b.role)) b,
  ];
  if (pushes.isEmpty && menuVerbs.isEmpty) return touched;
  final own = cache ?? (DpCache()..ingestValue(rfc));
  String? byOwner(String? token) {
    final o = token?.trim() ?? '';
    if (o.isEmpty) return null;
    final sh = ownerShell[o] ?? _gridOfOwner(grids, o) ?? shellOf?.call(o);
    return sh != null && grids[sh] != null ? sh : null;
  }

  for (final b in pushes) {
    final s = b.shell?.trim();
    final shell = (s != null && s.isNotEmpty && grids[s] != null)
        ? s
        : byOwner(b.owner);
    if (shell == null) continue;
    for (final u in b.urls) {
      final seg = own.byUrl[u];
      if (seg == null) continue;
      final buttons = decodeToolbarButtonsPush(seg);
      if (buttons.isEmpty) continue;
      grids[shell]!.setToolbar(buttons);
      if (b.owner case final o? when o.trim().isNotEmpty) {
        _noteOwner(grids, o.trim(), shell);
      }
      touched.add(shell);
    }
  }
  if (menuVerbs.isEmpty) return touched;
  final meta = verbMeta(call);
  final rowShell = <String, String>{};
  for (var i = 1; i <= call.verbs.length; i++) {
    if (!call.verbs[i - 1].startsWith('CreateControl')) continue;
    final sh = (verbNamedArgs(call, i)['#1'] ?? '').trim();
    final res = meta[i - 1].result?.trim() ?? '';
    if (sh.isNotEmpty && res.isNotEmpty) rowShell[res] = sh;
  }
  for (final v in menuVerbs) {
    final fcode = v.fcode;
    if (fcode == null || fcode.isEmpty) continue;
    final r = rowShell[v.objRow];
    final shell = (r != null && grids[r] != null) ? r : byOwner(v.handle);
    if (shell == null) continue;
    final entries = toolbarMenuEntries(v, rfc, own: own);
    if (entries.isEmpty) continue;
    grids[shell]!.setToolbarMenu(fcode, entries);
    touched.add(shell);
  }
  return touched;
}

/// The GridView `SelectionMode` property sets of one queue, in queue order:
/// (kernel shell, mode). The set is a property verb ON the grid object
/// (`S SelectionMode`, one unnamed argument), whose VARS row is the
/// CreateControl result of the same queue (a recorded session srv[15]:
/// CreateControl 121 GridViewCtrl -> row 102, `SelectionMode` on 102 set
/// 1 then 0) or the token of a grid minted earlier ([shellOf]).
List<(String, int)> gridSelectionModeSets(
  FlushCall call, {
  String? Function(String owner)? shellOf,
}) {
  final meta = verbMeta(call);
  final rowShell = <String, String>{};
  final out = <(String, int)>[];
  for (var i = 1; i <= call.verbs.length; i++) {
    final verb = call.verbs[i - 1];
    final m = meta[i - 1];
    if (verb.startsWith('CreateControl')) {
      final a = verbNamedArgs(call, i);
      final shell = (a['#1'] ?? '').trim();
      final res = m.result?.trim();
      if (shell.isNotEmpty && res != null && res.isNotEmpty) {
        rowShell[res] = shell;
      }
    } else if (verb == 'SelectionMode' &&
        i <= call.verbKinds.length &&
        call.verbKinds[i - 1] == 'S') {
      final args = verbArgs(call, i);
      final mode = args.isEmpty ? null : int.tryParse(args.first.$2.trim());
      final shell =
          rowShell[m.obj.trim()] ?? shellOf?.call(m.objValue.trim());
      if (mode != null && shell != null) out.add((shell, mode));
    }
  }
  return out;
}

const Set<String> _gridRoles = {
  'InfoTable',
  'DataTableOnDemand',
  'RowIDNumericOnDemand',
};
