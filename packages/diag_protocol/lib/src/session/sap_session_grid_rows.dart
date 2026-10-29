part of 'sap_session.dart';

/// OO-ALV grid rows on demand on a [SapSession] (see grid_rows_request.dart
/// for the client frame and screen/grid_rows.dart for the reply): an
/// on-demand grid is pushed with its first OptPacket of cells only; the
/// rest is fetched window by window as the user scrolls. Windows dialect
/// only (the Java SapGrid spelling is not built).
extension SapSessionGridRows on SapSession {
  _GridRowsState get _gridRows => _gridRowsStates[_w] ??= _GridRowsState();

  /// Fetch the rows of grid [shell] from line [fromRow] (1-based) — what
  /// GridView.ocx sends when a scroll brings unloaded rows into view: a
  /// `%_GS 0 1` round whose DATAMANAGER asks the grid's DataTableOnDemand
  /// provider for their line span (pinned against a recorded session
  /// gui[74]). The reply's cells are folded into the grid: read them with
  /// `grids[shell].loadedRows` / `rowAt` (sparse — [SapGridModel.rows]
  /// stays the gap-free head).
  ///
  /// The window is [count] rows (default: the provider's OptPacket in
  /// whole rows — the packet the server prefers — but at least
  /// 40 rows), clamped to the
  /// grid's total and trimmed to the rows not loaded yet — when every
  /// row of it is loaded nothing is sent and the result is empty. Pass
  /// [firstVisibleRow] (the grid's first visible row after the user's
  /// scroll) to report it as the real GUI does (the FirstVisibleRow /
  /// FirstVisibleRowID cached properties the grid registered, and its
  /// GENERIC — the server keeps it and restores it on a re-push).
  ///
  /// A grid selection staged on any grid rides this frame (as on every
  /// other client frame). Returns the server frames of the reply.
  Future<List<Uint8List>> fetchGridRows(
    String shell,
    int fromRow, {
    int? count,
    int? firstVisibleRow,
  }) async {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError(
        'grid row fetch is built for the Windows dialect only',
      );
    }
    final asm = _gridAsm[shell];
    if (asm == null || !_live(shell)) {
      throw ArgumentError('no live grid with shell $shell');
    }
    final g = asm.build();
    final handle = g.handles['DataTableOnDemand'];
    final total = g.totalRows;
    final stride = asm.cellsPerRow;
    if (handle == null || total == null || stride == null) {
      throw StateError(
        'grid $shell has no on-demand row provider (handle $handle, '
        '$total rows, stride $stride)',
      );
    }
    if (fromRow < 1 || fromRow > total) {
      throw RangeError('row $fromRow is not a line of grid $shell (1..$total)');
    }
    final opt = g.optPacket;
    // the OptPacket in whole rows, at least a screenful: a wide grid's
    // OptPacket is a few rows only (SE16 MARA 819 cells at 310 per row) —
    // the Java GUI asks 36 rows of SE16's 503-cell rows (a recorded session)
    final optRows = opt != null && opt > 0 ? -(-opt ~/ stride) : 0;
    // capped: the OptPacket is a wire number — a hostile one asked ~10^9
    // lines and marked them all covered
    var want = count ?? (optRows > _minFetchRows ? optRows : _minFetchRows);
    if (want > maxFetchRows) want = maxFetchRows;
    var last = fromRow + (want < 1 ? 1 : want) - 1;
    if (last > total) last = total;
    var first = fromRow;
    while (first <= last && g.isRowLoaded(first)) {
      first++;
    }
    while (last >= first && g.isRowLoaded(last)) {
      last--;
    }
    if (first > last) return const [];
    final (firstLine, nLines) = gridRowsLineSpan(
      first,
      last,
      stride,
      lineCount: g.lineCount,
    );

    // the first visible row moves with the scroll: its cached properties
    // (only those the grid registered — an unregistered PROPERTY dumps
    // CNDP 008) and, from now on, every GENERIC the grid reports
    final reg = _layoutState.registry;
    final registered = reg.cachedProps[shell] ?? const <String>[];
    final scrollProps = <String, String>{};
    if (firstVisibleRow != null && firstVisibleRow != asm.firstVisibleRow) {
      if (firstVisibleRow < 1 || firstVisibleRow > total) {
        throw RangeError('first visible row $firstVisibleRow of grid $shell');
      }
      asm.firstVisibleRow = firstVisibleRow;
      _invalidateGridModel(shell);
      if (registered.contains('FirstVisibleRow')) {
        scrollProps['FirstVisibleRow'] = '$firstVisibleRow';
      }
      if (registered.contains('FirstVisibleRowID')) {
        // the row's id text when loaded, '' when not (gui[68] 288)
        scrollProps['FirstVisibleRowID'] = g.isRowLoaded(firstVisibleRow)
            ? gridRowIdText(g, firstVisibleRow)
            : '';
      }
    }

    // every live grid's GENERIC beside it, ascending shell order (gui[74]
    // 122 then 140), merged with any staged selection
    final all = grids;
    final changes = <GridDataChange>[];
    final controls = <GridControlState>[];
    final shells = all.keys.toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    for (final sh in shells) {
      final m = all[sh]!;
      final sel = gridSelections[sh];
      (List<GridDataChange>, GridControlState)? flush;
      if (sel != null && sel.pending) {
        try {
          flush = gridSelectionFlush(m, sel);
        } on ArgumentError catch (e) {
          _trace('grid selection on $sh dropped: $e');
          clearGridSelection(sh, unstage: true);
        }
      }
      if (flush != null) changes.addAll(flush.$1);
      final isTarget = sh == shell;
      final registersFv =
          reg.cachedProps[sh]?.contains('FirstVisibleRow') ?? false;
      if (flush == null && !isTarget && !registersFv) continue;
      final props = <String, String>{
        for (final (n, v) in flush?.$2.props ?? const <(String, String)>[])
          n: v,
        if (isTarget) ...scrollProps,
      };
      controls.add(
        GridControlState(
          sh,
          props: [
            for (final n in gridViewScrollPropOrder)
              if (props[n] case final v?) (n, v),
          ],
          generic: gridFirstVisible(m),
        ),
      );
    }
    final xml = gridDataRequestXml(
      handle: handle,
      firstLine: firstLine,
      nLines: nLines,
      changes: changes,
      controls: controls,
    );
    _gridStateFlushed(); // the staged state rides THIS frame
    final st = _gridRows;
    final (cFirst, cLast) = gridRowsCoveredBy(firstLine, nLines, stride);
    st.inFlight = (shell, cFirst, cLast);
    _trace(
      'grid $shell DATAREQUEST rows $first..$last '
      '(lines $firstLine+$nLines, handle $handle)',
    );
    try {
      return await _act(
        gridDataRequestItems(ctx, shell: shell, xml: xml),
        dialectReady: true,
      );
    } finally {
      st.inFlight = null;
    }
  }

  /// The on-demand provider objects the session minted, by object handle
  /// (what a DATAREQUEST reply's InsertPacket names) -> grid and role.
  Map<String, GridProviderRef> get gridRowProviders =>
      Map.unmodifiable(_gridRows.providers);

  /// After a queue was answered: note the on-demand providers it created
  /// (object handle -> grid, from the answer's mints), the server's own
  /// first-visible rows and OptPackets, and fold any DATAREQUEST reply
  /// packets it inserts.
  void _noteGridRows(Uint8List value, FlushCall call) {
    final st = _gridRows;
    String? shellOf(String owner) => _ea.shellAlias[owner];
    try {
      for (final p in gridProviderObjects(call, shellOf: shellOf)) {
        final h = call.resultHandles[p.resultRow - 1];
        final shell = p.shell, role = p.role;
        if (h == null || shell == null || role == null) continue;
        st.providers['$h'] = (shell: shell, role: role);
        final g = _gridAsm[shell];
        if (g != null &&
            role == 'DataTableOnDemand' &&
            g.handles[role] == p.handle) {
          g.optPacket = p.optPacket;
        }
      }
      for (final (shell, row) in gridFirstVisibleSets(call, shellOf: shellOf)) {
        final g = _gridAsm[shell];
        if (g == null) continue;
        g.firstVisibleRow = row;
        _invalidateGridModel(shell);
      }
      final fl = st.inFlight;
      final touched = foldGridPacketCall(
        value,
        _gridAsm,
        providerOf: (o) => st.providers[o],
        parsed: call,
        fallbackShell: fl?.$1,
        covered: {if (fl != null) fl.$1: (fl.$2, fl.$3)},
      );
      for (final shell in touched) {
        _invalidateGridModel(shell);
      }
    } catch (e) {
      _noteIngestFailure('grid rows ingest', e);
    }
  }

  void _invalidateGridModel(String shell) {
    for (final g in _grids) {
      if (g.shell == shell) g.model = null;
    }
  }
}

/// The smallest default fetch window (rows).
const int _minFetchRows = 40;

/// The largest fetch window (rows) one DATAREQUEST asks, whatever the
/// OptPacket or the caller's count say.
const int maxFetchRows = 1000;

class _GridRowsState {
  /// provider object handle (our mint) -> its grid and role
  final Map<String, GridProviderRef> providers = {};

  /// the DATAREQUEST being answered: (shell, first row, last row)
  (String, int, int)? inFlight;
}

final Expando<_GridRowsState> _gridRowsStates = Expando('gridRowsState');
