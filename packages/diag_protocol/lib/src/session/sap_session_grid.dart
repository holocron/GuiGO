part of 'sap_session.dart';

/// Grid selection staging on a [SapSession] (see grid_selection.dart for
/// the wire shapes and their oracles): a click on an OO-ALV grid is held
/// client-side and rides the NEXT client frame — whatever action that is
/// ([press], [okcode], a dynpro button, [fill], a control event) — merged
/// into its DATAMANAGER XML, exactly as GridView.ocx flushes it. Windows
/// dialect only (the Java SapGrid spelling is not built).
extension SapSessionGrid on SapSession {
  _GridSelState get _gridSel => _gridSelStates[_w] ??= _GridSelState();

  /// Every live grid's client-side selection by shell: what is staged
  /// ([GridSelection.pending], not yet sent) and what the last frames
  /// carried (kept until the grid's content is re-pushed or it is
  /// destroyed — the server-side ALV reset its selection then too).
  Map<String, GridSelection> get gridSelections => {
    for (final e in _gridSel.selections.entries)
      if (_live(e.key)) e.key: e.value,
  };

  /// Select [rows] (1-based grid lines) of grid [shell] — the row-selector
  /// click (Ctrl-click for several): the SelectedRows channel cleared and
  /// refilled with the rows' ids, the SelectedCols channel cleared, the
  /// current cell on the last row. Pinned: the DATACHANGES against
  /// a recorded session gui[377] (Windows), the property set
  /// against a recorded session gui[22] (Java GUI) in the OCX order.
  void selectGridRows(String shell, List<int> rows) {
    final g = _stageable(shell);
    for (final r in rows) {
      if (!g.isRowLoaded(r)) {
        throw RangeError(
          'row $r is not a delivered line of grid $shell '
          '(${g.loadedRows.length} loaded; fetchGridRows first)',
        );
      }
    }
    // the current column stays where an earlier click left it (its cell
    // text is the CurrentCellText, flpcm gui[22]: column ID kept)
    final col = _gridSel.selections[shell]?.currentColumn;
    _gridSel.selections[shell] = rows.isEmpty
        ? GridSelection(shell, GridSelectionKind.none)
        : GridSelection(
            shell,
            GridSelectionKind.rows,
            rows: List.unmodifiable(rows),
            currentRow: rows.last,
            currentColumn: col,
          );
  }

  /// Make cell ([row], [columnId]) of grid [shell] current — the plain
  /// cell click: the six CurrentCell* props, both selection channels
  /// CLEARED. Pinned against a recorded session gui[18].
  void setGridCurrentCell(String shell, int row, String columnId) {
    final g = _stageable(shell);
    if (!g.isRowLoaded(row)) {
      throw RangeError('row $row is not a delivered line of grid $shell');
    }
    if (!g.columns.contains(columnId)) {
      throw ArgumentError('grid $shell has no column $columnId');
    }
    _gridSel.selections[shell] = GridSelection(
      shell,
      GridSelectionKind.cell,
      currentRow: row,
      currentColumn: columnId,
    );
  }

  /// Select columns [columnIds] (field names) of grid [shell] — the
  /// column-header click (Ctrl-click for several). INFERRED, not pinned
  /// against a Windows capture: the SelectedCols insert `C1 = <column id>`
  /// and the header-click property set are a recorded session gui[19]'s
  /// (Java GUI), spelled as the OCX spells its inserts; see
  /// grid_selection.dart.
  void selectGridColumns(String shell, List<String> columnIds) {
    final g = _stageable(shell);
    for (final c in columnIds) {
      if (!g.columns.contains(c)) {
        throw ArgumentError('grid $shell has no column $c');
      }
    }
    _gridSel.selections[shell] = columnIds.isEmpty
        ? GridSelection(shell, GridSelectionKind.none)
        : GridSelection(
            shell,
            GridSelectionKind.columns,
            columns: List.unmodifiable(columnIds),
            currentRow: 0,
            currentColumn: columnIds.last,
          );
  }

  /// Deselect everything on grid [shell] (both channels cleared with the
  /// next frame), or drop a staged-but-unsent selection when [unstage].
  void clearGridSelection(String shell, {bool unstage = false}) {
    if (unstage) {
      _gridSel.selections.remove(shell);
      return;
    }
    _stageable(shell);
    _gridSel.selections[shell] = GridSelection(shell, GridSelectionKind.none);
  }

  SapGridModel _stageable(String shell) {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError(
        'grid selection staging is built for the Windows dialect only',
      );
    }
    final g = grids[shell];
    if (g == null) throw ArgumentError('no live grid with shell $shell');
    return g;
  }

  /// The pending state's inner DATACHANGES / CONTROL blocks, null when
  /// nothing is staged. Every other live grid that registered
  /// FirstVisibleRow reports its GENERIC beside it (ascending shell order,
  /// a recorded session gui[18] 118 / 180 / 206).
  (String, String)? _pendingGridXml() {
    final pending = {
      for (final e in gridSelections.entries)
        if (e.value.pending) e.key: e.value,
    };
    if (pending.isEmpty) return null;
    final all = grids;
    final reg = _layoutState.registry;
    final tables = <GridDataChange>[];
    final blocks = <GridControlState>[];
    var any = false;
    final shells = all.keys.toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    for (final sh in shells) {
      final g = all[sh]!;
      final sel = pending[sh];
      final (List<GridDataChange>, GridControlState)? flush;
      try {
        flush = sel == null ? null : gridSelectionFlush(g, sel);
      } on ArgumentError catch (e) {
        // the grid was re-pushed under the staged click (a column gone)
        _trace('grid selection on $sh dropped: $e');
        _gridSel.selections.remove(sh);
        continue;
      }
      if (flush != null) {
        any = true;
        tables.addAll(flush.$1);
        blocks.add(flush.$2);
        // the grid's flushed cell state, for the next value help's delta
        // (sap_session_grid_edit.dart)
        _noteGridProps(sh, flush.$2.props);
      } else if (reg.cachedProps[sh]?.contains('FirstVisibleRow') ?? false) {
        blocks.add(GridControlState(sh, generic: gridFirstVisible(g)));
      }
    }
    if (!any) return null;
    return (windowsDataChangesXml(tables), windowsGridControlsXml(blocks));
  }

  /// The staged state rode a frame: keep it as the shown selection.
  void _gridStateFlushed() {
    final s = _gridSel.selections;
    for (final k in s.keys.toList()) {
      if (s[k]!.pending) s[k] = s[k]!.flushed();
    }
  }

  /// A grid's content was re-pushed (sort, filter, refresh): a selection
  /// already sent no longer names the same rows; a staged one is kept.
  void _gridContentChanged(String shell) {
    final s = _gridSel.selections[shell];
    if (s != null && !s.pending) _gridSel.selections.remove(shell);
  }
}

/// The grid clicks that ARE events (grid_edit_actions.dart): the
/// double-click on a cell — what opens a dump from the ST22 hit list, a
/// record from SE16, a directory in AL11 — and the hotspot click on a
/// hotspot cell. Unlike a plain click ([setGridCurrentCell]) the OCX fires
/// them at once: `%_GC <grid> 3|2` with the cell's five PARAMs, the
/// CurrentCell* properties that moved and the selection channels in the
/// same DATAMANAGER. Windows dialect only.
extension SapSessionGridClick on SapSession {
  /// Double-click cell ([row], [columnId]) of grid [shell] (1-based line,
  /// the column's field name) — EVENTID 3. Pinned on a recorded session
  /// gui[112] (ST22 119, row 1 UNAME: CurrentCellCol / Text / ColID only,
  /// row 1 being the creation default; SelectedCols H12 cleared,
  /// SelectedRows H14 cleared + row 1 inserted) and gui[127] (the
  /// re-created hit list, row 4: all six properties, H17 / H19).
  Future<List<Uint8List>> gridDoubleClick(
    String shell,
    int row,
    String columnId,
  ) => _gridCellEvent(shell, row, columnId, gridEventDoubleClick);

  /// Click hotspot cell ([row], [columnId]) of grid [shell] — EVENTID 2,
  /// the double-click's envelope with the hotspot id (a recorded session
  /// enjoy gui[133], ME23N PO history 148 BELNR row 1). [columnId] must be
  /// one of the grid's [SapGridModel.hotspotColumns].
  Future<List<Uint8List>> gridHotspotClick(
    String shell,
    int row,
    String columnId,
  ) {
    final g = grids[shell];
    if (g != null && !g.hotspotColumns.contains(columnId)) {
      throw ArgumentError('column $columnId of grid $shell is no hotspot');
    }
    return _gridCellEvent(shell, row, columnId, gridEventHotspotClick);
  }

  /// Whether grid [shell] registered EVENTID [eventId] — the OCX fires
  /// only registered events (GuiShell.fireCtlEventAllowed; the reference client's
  /// alv_drill gate). True when the session saw no registration for it.
  bool gridHandlesEvent(String shell, int eventId) {
    final reg = _canvasState.tracker.registeredEvents[shell];
    return reg == null || reg.isEmpty || reg.contains(eventId);
  }

  Future<List<Uint8List>> _gridCellEvent(
    String shell,
    int row,
    String columnId,
    int eventId,
  ) {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError('grid clicks are built for Windows only');
    }
    final g = grids[shell];
    if (g == null) throw ArgumentError('no live grid with shell $shell');
    if (!g.isRowLoaded(row)) {
      throw RangeError('row $row is not a delivered line of grid $shell');
    }
    final pos = g.columns.indexOf(columnId) + 1;
    if (pos < 1) throw ArgumentError('grid $shell has no column $columnId');
    if (!gridHandlesEvent(shell, eventId)) {
      final reg = _canvasState.tracker.registeredEvents[shell]!.toList()
        ..sort();
      throw StateError(
        'grid $shell did not register EVENTID $eventId (it handles $reg): '
        'SAP GUI does not fire it',
      );
    }
    final cells = g.rowAt(row)!;
    final target = <String, String>{
      'CurrentCellCol': '$pos',
      'CurrentCellRow': '$row',
      'CurrentCellText': pos <= cells.length ? cells[pos - 1] : '',
      'CurrentCellColID': columnId,
      'CurrentCellRowID': gridRowIdText(g, row),
      'CurrentCellRowIDNumeric': '${gridRowIdNumeric(g, row)}',
    };
    // the click's own state supersedes a selection staged on this grid
    // (reference client raw_drill._supersede_staged_mark)
    clearGridSelection(shell, unstage: true);
    final changed = _gridPropDelta(shell, g, target);
    final params = gridCellEventParams(g, row, columnId);
    final xml = ocxDataManagerXml(
      tables: gridClickTablesXml(g, row),
      eventShell: shell,
      eventId: eventId,
      eventParams: params,
      controls:
          [
            GridControlState(
              shell,
              props: changed,
              generic: gridFirstVisible(g),
            ),
            ..._gridGenericBlocks(skip: {shell}),
          ]..sort(
            (a, b) => (int.tryParse(a.shell) ?? 0).compareTo(
              int.tryParse(b.shell) ?? 0,
            ),
          ),
    );
    _noteGridProps(shell, changed);
    // the cell is the grid's flushed current cell (and its row the
    // selection, on a row-selecting grid)
    _gridSel.selections[shell] = gridClickSelectsRow(g)
        ? GridSelection(
            shell,
            GridSelectionKind.rows,
            rows: [row],
            currentRow: row,
            currentColumn: columnId,
            pending: false,
          )
        : GridSelection(
            shell,
            GridSelectionKind.cell,
            currentRow: row,
            currentColumn: columnId,
            pending: false,
          );
    _ea.recordEvent(shell, {
      for (final (i, p) in params.indexed) i: p,
    });
    _trace(
      'grid $shell event $eventId on row $row $columnId '
      '(${changed.map((p) => '${p.$1}=${p.$2}').join(', ')})',
    );
    return _act(
      gridEventItems(
        ctx,
        shell: shell,
        eventId: eventId,
        xml: xml,
        path: _hostedSourcePath(shell),
      ),
      controlEvent: true,
      dialectReady: true,
    );
  }
}

class _GridSelState {
  final Map<String, GridSelection> selections = {};
}

final Expando<_GridSelState> _gridSelStates = Expando('gridSelState');
