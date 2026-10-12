part of 'sap_session.dart';

/// Value help in an EDITABLE OO-ALV grid cell and the server-applied cell
/// values on a [SapSession] (frames and oracles: grid_edit_actions.dart).
/// [gridCellValueHelp] opens the cell's search help (the SAP.TABControl.1
/// dialog, [valueHelpDialogs]); the pick's value comes back as a
/// DeltaTableModified push the session adopts in its answer — the cell
/// shows it in [grids] at once ([SapGridModel.modifiedCells] marks it until
/// the server confirms) — and [commitGridEdits] sends the item commit.
/// Windows dialect only.
extension SapSessionGridEdit on SapSession {
  _GridEditState get _ge => _gridEditStates[_w] ??= _GridEditState();

  /// F4 on cell ([row], [columnId]) of grid [shell] (1-based line, the
  /// column's field name): the current cell moves there and the grid's
  /// current-cell / ENTER flush (EVENTID 17, no PARAM) asks the server for
  /// the field's value help — the real GUI's F4 in an ME51N item cell
  /// (a recorded session gui[7] / [45], a recorded session gui[12]).
  /// Only the CurrentCell* properties whose value moved since the grid's
  /// last flush ride the CONTROL block, beside both selection channels
  /// cleared; the OK-event mode follows the last paint's focus
  /// ([gridOkMode]). A selection staged on this grid is superseded by the
  /// move. Returns the server frames of the reply — the dialog is then in
  /// [valueHelpDialogs] (or, for a field without a dialog help, the
  /// server's own reaction).
  Future<List<Uint8List>> gridCellValueHelp(
    String shell,
    int row,
    String columnId,
  ) {
    final g = _editableGrid(shell);
    if (!g.isRowLoaded(row)) {
      throw RangeError('row $row is not a delivered line of grid $shell');
    }
    final pos = g.columns.indexOf(columnId) + 1;
    if (pos < 1) throw ArgumentError('grid $shell has no column $columnId');
    final cells = g.rowAt(row)!;
    final target = <String, String>{
      'CurrentCellCol': '$pos',
      'CurrentCellRow': '$row',
      'CurrentCellText': cells[pos - 1],
      'CurrentCellColID': columnId,
      'CurrentCellRowID': gridRowIdText(g, row),
      'CurrentCellRowIDNumeric': '${gridRowIdNumeric(g, row)}',
    };
    clearGridSelection(shell, unstage: true);
    final changed = _gridPropDelta(shell, g, target);
    final tables = [
      for (final role in const ['SelectedColsOnDemand', 'SelectedRowsOnDemand'])
        if (g.handles[role] case final h?) h,
    ]..sort();
    final xml = ocxDataManagerXml(
      tables: [for (final h in tables) ocxDataChanges(h, const [], clear: true)]
          .join(),
      eventShell: shell,
      eventId: gridEventEnter,
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
    // the click is now the grid's flushed current cell
    _gridSel.selections[shell] = GridSelection(
      shell,
      GridSelectionKind.cell,
      currentRow: row,
      currentColumn: columnId,
      pending: false,
    );
    _trace(
      'grid $shell F4 on row $row $columnId '
      '(${changed.map((p) => '${p.$1}=${p.$2}').join(', ')})',
    );
    return _act(
      gridEventItems(
        ctx,
        shell: shell,
        eventId: gridEventEnter,
        xml: xml,
        path: _hostedSourcePath(shell),
      ),
      controlEvent: true,
      dialectReady: true,
    );
  }

  /// The item commit of grid [shell]: `%_GC <shell> 19` with no PARAM and
  /// the grid's GENERIC (a recorded session gui[83], after the F4-picked
  /// values were adopted — the server then moves them into its outtab).
  Future<List<Uint8List>> commitGridEdits(String shell) {
    final g = _editableGrid(shell);
    final xml = ocxDataManagerXml(
      eventShell: shell,
      eventId: gridEventButtonClickRowCol,
      controls:
          [
            GridControlState(shell, generic: gridFirstVisible(g)),
            ..._gridGenericBlocks(skip: {shell}),
          ]..sort(
            (a, b) => (int.tryParse(a.shell) ?? 0).compareTo(
              int.tryParse(b.shell) ?? 0,
            ),
          ),
    );
    return _act(
      gridEventItems(
        ctx,
        shell: shell,
        eventId: gridEventButtonClickRowCol,
        xml: xml,
        path: _hostedSourcePath(shell),
      ),
      controlEvent: true,
      dialectReady: true,
    );
  }

  SapGridModel _editableGrid(String shell) {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError('grid cell edits are built for Windows only');
    }
    final g = grids[shell];
    if (g == null) throw ArgumentError('no live grid with shell $shell');
    return g;
  }

  /// The grid's last flushed value of each cached property, seeded with
  /// what its creation flush reported (the reference client's grid_creation_flush:
  /// CurrentCellCol 1, CurrentCellColID the first column, row 1 and its
  /// first cell / ids when rows were served, else 0 / ''; GridModified 0).
  /// A content re-push on the same control (DeleteAllCells + a new
  /// DataTableOnDemand provider) resets it too: a recorded session srv[157]
  /// re-fills ST22's grid 119 (H13 -> H18) and the next double-click,
  /// gui[127], flushes all six CurrentCell* properties, the column and
  /// text included although they equal the previous click's.
  Map<String, String> _gridProps(String shell, SapGridModel g) {
    final gen =
        '${_ea.createdControls.where((c) => c.handle == shell).length}'
        '/${g.handles['DataTableOnDemand']}';
    final st = _ge.props[shell];
    if (st != null && st.$1 == gen) return st.$2;
    final rows = g.isRowLoaded(1);
    final first = rows ? g.rowAt(1)! : const <String>[];
    final seed = <String, String>{
      'CurrentCellCol': g.columns.isEmpty ? '0' : '1',
      'CurrentCellColID': g.columns.isEmpty ? '' : g.columns.first,
      'CurrentCellRow': rows ? '1' : '0',
      'CurrentCellText': first.isEmpty ? '' : first.first,
      'CurrentCellRowID': rows ? gridRowIdText(g, 1) : '',
      'CurrentCellRowIDNumeric': rows ? '${gridRowIdNumeric(g, 1)}' : '0',
      'GridModified': '0',
    };
    _ge.props[shell] = (gen, seed);
    return seed;
  }

  /// The [target] properties whose value moved since the last flush,
  /// registered ones only (an unregistered PROPERTY dumps CNDP 008), in
  /// the OCX order.
  List<(String, String)> _gridPropDelta(
    String shell,
    SapGridModel g,
    Map<String, String> target,
  ) {
    final last = _gridProps(shell, g);
    final reg = _layoutState.registry.cachedProps[shell];
    return [
      for (final n in gridViewPropOrder)
        if (target[n] case final v?)
          if (last[n] != v && (reg == null || reg.contains(n))) (n, v),
    ];
  }

  void _noteGridProps(String shell, List<(String, String)> props) {
    final g = grids[shell];
    if (g == null) return;
    final last = _gridProps(shell, g);
    for (final (n, v) in props) {
      last[n] = v;
    }
  }

  /// The adoption of the DeltaTableModified / DeltaTable pushes [call]
  /// carries: the answer's EXPORT_XML and the `GridModified` reads' values
  /// (VARS row -> value), null when the queue pushes none. Built inside
  /// the queue's own answer — never a separate DP reply — so the delta is
  /// adopted on the round the server waits on (the reference client answered such a
  /// queue from its DP cache first and lost the adoption:
  /// ).
  (Uint8List, Map<int, Uint8List>)? _gridDeltaAdoption(FlushCall call) {
    final bindings = [
      for (final b in dpPushBindings(call))
        if (b.role == 'DeltaTableModified' || b.role == 'DeltaTable') b,
    ];
    if (bindings.isEmpty || answerDialect != GuiDialect.windows) return null;
    final cache = DpCache()..ingestValue(call.raw);
    final tables = StringBuffer();
    final controls = <GridControlState>[];
    final modifiedShells = <String>{};
    for (final b in bindings) {
      final shell = _deltaShell(b);
      final asm = shell == null ? null : _gridAsm[shell];
      if (shell == null || asm == null) {
        _trace('grid delta ${b.role} (owner ${b.owner}) names no grid');
        continue;
      }
      final g = asm.build();
      final modH = g.handles['ModifiedCellsOnDemand'];
      final dtH = g.handles['DataTableOnDemand'];
      if (modH == null) continue;
      for (final u in b.urls) {
        final seg = cache.byUrl[u];
        final t = seg == null ? null : decodeNamedDpTable(seg);
        if (t == null || t.columns.length < 4) continue;
        final confirm = b.role == 'DeltaTable';
        final pending = _ge.modified[shell] ??= [];
        final updates = <String>[];
        String? lastValue;
        for (final r in t.rows) {
          final line = int.tryParse(r[t.columns[0]] ?? '');
          final sub = int.tryParse(r[t.columns[1]] ?? '') ?? 0;
          final colId = int.tryParse(r[t.columns[2]] ?? '');
          final value = r[t.columns[3]] ?? '';
          if (line == null || colId == null) continue;
          final idIdx = g.columnIds.indexOf(colId);
          final pos = idIdx >= 0 ? idIdx + 1 : colId;
          pending.removeWhere((c) => c.$1 == line && c.$3 == colId);
          if (!confirm) pending.add((line, sub, colId, value, t.types));
          asm.setCellText(line, pos, value, pending: !confirm);
          lastValue = value;
          if (dtH != null && asm.cellTypes.isNotEmpty) {
            final idx = (line - 1) * (g.columns.length + 1) + pos + 1;
            updates.add(
              ocxItRecord(idx, 'U', [
                for (var k = 0; k < asm.cellTypes.length; k++)
                  k == 0
                      ? '$pos'
                      : k == 3
                      ? value
                      : asm.cellTypes[k] == 0x43
                      ? ''
                      : '0',
              ]),
            );
          }
        }
        // the ModifiedCells provider = the edits still pending, refilled
        final inserts = [
          for (var i = 0; i < pending.length; i++)
            ocxItRecord(i + 1, 'I', _modifiedCells(pending[i])),
        ];
        tables.write(ocxDataChanges(modH, inserts, clear: true));
        if (dtH != null && updates.isNotEmpty) {
          tables.write(ocxDataChanges(dtH, updates));
        }
        // the moved properties only: gui[44] (the 1010 adoption) carries
        // no GridModified — it was 1 already from the typed quantity
        final sent = _gridPropDelta(shell, g, {
          if (!confirm && lastValue != null) 'CurrentCellText': lastValue,
          'GridModified': confirm ? '0' : '1',
        });
        _noteGridProps(shell, sent);
        controls.removeWhere((c) => c.shell == shell);
        controls.add(
          GridControlState(
            shell,
            props: sent,
            generic: gridFirstVisible(asm.build()),
          ),
        );
        if (!confirm) modifiedShells.add(shell);
        _invalidateGridModel(shell);
        _trace(
          'grid $shell ${b.role} ${confirm ? 'confirmed' : 'adopted'} '
          '${t.rows.length} cell(s)',
        );
      }
    }
    if (controls.isEmpty) return null;
    // the queue's own GridModified reads answer the adopted state
    final answers = <int, Uint8List>{};
    final meta = verbMeta(call);
    for (var i = 1; i <= call.verbs.length; i++) {
      if (call.verbs[i - 1] != 'GridModified') continue;
      final res = int.tryParse(meta[i - 1].result?.trim() ?? '');
      if (res == null || res < 1) continue;
      final sh = _shellOfGridToken(meta[i - 1].objValue.trim());
      final on = sh == null
          ? modifiedShells.isNotEmpty
          : modifiedShells.contains(sh);
      answers[res - 1] = Uint8List.fromList((on ? '1' : '0').codeUnits);
    }
    controls.sort(
      (a, b) =>
          (int.tryParse(a.shell) ?? 0).compareTo(int.tryParse(b.shell) ?? 0),
    );
    final xml = ocxDataManagerXml(
      tables: tables.toString(),
      controls: controls,
    );
    return (wireText('$xml\u0000'), answers);
  }

  /// The ModifiedCells record of a pending edit: C1 row, C2 sub row, C3
  /// column id, C4 value, every other cell zero / blank by the push's
  /// FORMAT (gui[23]: `1 0 7 900557 0 0 0 0 0`).
  List<String> _modifiedCells((int, int, int, String, List<int>) e) {
    final (line, sub, colId, value, types) = e;
    return [
      for (var k = 0; k < types.length; k++)
        switch (k) {
          0 => '$line',
          1 => '$sub',
          2 => '$colId',
          3 => value,
          _ => types[k] == 0x43 ? '' : '0',
        },
    ];
  }

  /// The grid a delta push targets: its binding's shell, the session alias
  /// of its owner token, else the one live grid with a ModifiedCells
  /// provider (a queue recorded from another frontend names that
  /// frontend's token — the reference client's FORMAT-matched fallback,
  /// ea_deltamodified._grid_by_modified_format, by the provider alone).
  String? _deltaShell(DpPushBinding b) {
    final s = b.shell?.trim();
    if (s != null && s.isNotEmpty && _gridAsm.containsKey(s)) return s;
    return _shellOfGridToken(b.owner?.trim() ?? '');
  }

  String? _shellOfGridToken(String token) {
    final a = _ea.shellAlias[token];
    if (a != null && _gridAsm.containsKey(a) && _live(a)) return a;
    if (_gridAsm.containsKey(token) && _live(token)) return token;
    final editable = [
      for (final e in _gridAsm.entries)
        if (_live(e.key) &&
            e.value.handles.containsKey('ModifiedCellsOnDemand'))
          e.key,
    ];
    return editable.length == 1 ? editable.single : null;
  }
}

class _GridEditState {
  /// shell -> (its creation count / DataTable provider, last flushed
  /// cached-property values)
  final Map<String, (String, Map<String, String>)> props = {};

  /// shell -> the adopted edits still pending (line, sub row, column id,
  /// value, the delta push's FORMAT types)
  final Map<String, List<(int, int, int, String, List<int>)>> modified = {};
}

final Expando<_GridEditState> _gridEditStates = Expando('gridEditState');
