part of 'sap_session.dart';

/// Server-driven CFW CONTEXT MENUS on a [SapSession] (reference client
/// / port): ask a tree or the
/// designer canvas for its context menu, read the menu the server pushed
/// (cfw/context_menu.dart), pick an entry (context_menu_actions.dart).
///
/// The menu is the server's: a right-click sends a REQUEST event and the
/// server answers with a SetContextMenu queue whose X-SAPCTXMENU push IS the
/// menu (a recorded session srv[47] for the tree request gui[36],
/// a recorded session srv[39] for the canvas pick gui[37]). The
/// menu lives until it is picked from ([pickContextMenu]), dismissed
/// ([dismissContextMenu]), any other action is sent, or the screen changes.
///
/// Covered: SapTree node / item / background menus (Windows
/// SAP.TableTreeControl.1 and the Java SapTree bean; the background one
/// Windows only), the OO-ALV grid's own right-click menu (GridView.ocx,
/// Windows) and the ICDataFlow designer canvas (Windows only). NOT covered
/// — no real-GUI capture records it: the tree HEADER request (41) and the
/// Java SapGrid's right-click.
extension SapSessionContextMenu on SapSession {
  _ContextMenuState get _ctxMenu => _ctxMenuStates[_w] ??= _ContextMenuState();

  /// The context menu the server pushed in answer to the last request, or
  /// null when none is open (never requested, picked, dismissed, superseded
  /// by another action or a screen change).
  SapContextMenu? get pendingContextMenu {
    final st = _ctxMenu;
    final shell = st.newest;
    return shell == null ? null : contextMenuFor(shell);
  }

  /// The open context menu of control [shell], or null.
  SapContextMenu? contextMenuFor(String shell) {
    final st = _ctxMenu;
    final m = st.menus[shell.trim()];
    if (m == null) return null;
    final s = screen;
    if (s == null || _screenIdentity(s) != st.screens[m.shell]) {
      st.menus.remove(m.shell);
      return null;
    }
    return m;
  }

  /// Close the open menu client-side (the user pressed Escape or clicked
  /// elsewhere). Sends nothing, as the real GUI: a recorded session
  /// gui[12] / [18] / [24] — three requests, each menu escaped — carry no
  /// frame between them but the flush answers.
  void dismissContextMenu() => _ctxMenu.clear();

  /// Right-click node [nodeKey] of tree [shell] (or, with [itemName], its
  /// item — the cell of that column of a column / list tree): the request
  /// `%_GC <tree> 36` PARAM 0 = the key, or `%_GC <tree> 26` PARAMs key,
  /// item, with the right-click's selection change flushed (see
  /// context_menu_actions.dart). The server's answer pushes the menu:
  /// [contextMenuFor] / [pendingContextMenu] afterwards (null when the
  /// server pushed none — some nodes have no menu).
  ///
  /// [nodeKey] is the tree's NODE_KEY (its own padded string, or the same
  /// key trimmed). Refused with a [StateError] (nothing sent) when the tree
  /// did not register the request event — the app should fall back to its
  /// own menu then. An ITEM-selection tree (it registered ABAPSelItemKey but
  /// not ABAPSelNodeKey — SEGW) asked without [itemName] sends the item
  /// request with the node's first item when it registered 26 (reference client
  /// tree_menu_request; a recorded session gui[35]
  /// `%_GC 127 26` key, `1`).
  Future<List<Uint8List>> requestTreeContextMenu(
    String shell,
    String nodeKey, {
    String? itemName,
  }) {
    final sh = shell.trim();
    final t = _canvasState.tracker;
    final reg = t.registeredEvents[sh] ?? const <int>{};
    final cached = t.cachedProps[sh] ?? const <String>[];
    final key = _ctxTreeKey(sh, nodeKey);
    var item = itemName;
    if (item == null &&
        reg.contains(treeEventRequestItemContextMenu) &&
        cached.contains(selItemKeyProp) &&
        !cached.contains(selNodeKeyProp)) {
      final items = trees[sh]?.nodes[key]?.items.keys;
      item = (items == null || items.isEmpty) ? '1' : items.first;
    }
    final ev = item == null
        ? treeEventRequestNodeContextMenu
        : treeEventRequestItemContextMenu;
    if (!reg.contains(ev)) {
      final has = [
        for (final e in const [
          treeEventRequestItemContextMenu,
          treeEventRequestNodeContextMenu,
          treeEventRequestHeaderContextMenu,
          treeEventRequestBackgroundContextMenu,
        ])
          if (reg.contains(e)) e,
      ];
      throw StateError(
        'tree $sh did not register the context-menu request event $ev '
        '(${ev == treeEventRequestItemContextMenu ? 'REQUESTITEMCONTEXTMENU' : 'REQUESTNODECONTEXTMENU'}'
        '; registered: ${(reg.toList()..sort())})'
        '${has.isEmpty ? '' : ' — it handles $has${has.contains(treeEventRequestItemContextMenu) && item == null ? ': pass itemName' : ''}'}'
        ' — nothing sent',
      );
    }
    final props = _ctxSelectionDelta(sh, key, item);
    final windows = answerDialect == GuiDialect.windows;
    final items = treeContextMenuRequestItems(
      ctx,
      shell: sh,
      nodeKey: key,
      itemName: item,
      controls: props.isEmpty ? const {} : {sh: props},
      sourcePath: windows ? _hostedSourcePath(sh) : null,
      windows: windows,
    );
    _ea.recordEvent(sh, {0: key, if (item != null) 1: item});
    return _ctxSend(items, (sh, key, item), flushed: (sh, props));
  }

  /// Right-click the empty BACKGROUND of tree [shell] (below its last node):
  /// `%_GC <tree> 42`, no PARAM, the selection cleared — the OCX deselects
  /// when the click hits no node, so the registered selection props the
  /// server holds non-empty go out "" (none on a tree that keeps its
  /// selection). Pinned on a recorded session gui[7]
  /// (`ABAPSelNodeKey=""` after gui[5] selected `F00031`); the server
  /// answers with the background menu (srv[10]). Refused with a
  /// [StateError], nothing sent, when the tree did not register 42 — the
  /// real GUI sends nothing then (a recorded session). Windows
  /// only.
  Future<List<Uint8List>> requestTreeBackgroundContextMenu(String shell) {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError(
        'the tree background menu is built for the Windows dialect only',
      );
    }
    final sh = shell.trim();
    final reg = _canvasState.tracker.registeredEvents[sh] ?? const <int>{};
    if (!reg.contains(treeEventRequestBackgroundContextMenu)) {
      throw StateError(
        'tree $sh did not register the context-menu request event '
        '$treeEventRequestBackgroundContextMenu (REQUESTBACKGROUNDCONTEXT'
        'MENU; registered: ${(reg.toList()..sort())}) — nothing sent',
      );
    }
    final st = _ctxMenu;
    final cached = _canvasState.tracker.cachedProps[sh];
    final props = st.tracker.selectionKept.contains(sh) || cached == null
        ? const <(String, String)>[]
        : st.tracker.changed(sh, [
            for (final p in cached)
              if (treeSelectionProps.contains(p)) (p, ''),
          ]);
    _ea.recordEvent(sh, const {});
    return _ctxSend(
      treeBackgroundContextMenuRequestItems(
        ctx,
        shell: sh,
        controls: props.isEmpty ? const {} : {sh: props},
        sourcePath: _hostedSourcePath(sh),
      ),
      (sh, '', null),
      flushed: (sh, props),
    );
  }

  /// Right-click OO-ALV grid [shell]: a data cell ([row] >= 1 and
  /// [columnId]), a column HEADER ([columnId], [row] null or 0) or a ROW
  /// SELECTOR ([row], no [columnId]). The request is `%_GC <grid> 9` with
  /// NO PARAM — which cell / column / row the menu is for rides only the
  /// same DATAMANAGER, as GridView.ocx flushes it (a recorded session
  /// context_menu):
  ///
  /// * cell (gui[12]): the moved CurrentCell* props, SelectedCols and
  /// SelectedRows cleared;
  /// * header (gui[18]): CurrentCellRow 0, RowID "", RowIDNumeric 0 and
  /// the column, SelectedCols cleared + `C1 = <column id>` inserted,
  /// SelectedRows cleared;
  /// * row selector (gui[24]): CurrentCellCol 0, Text "", ColID "",
  /// SelectedCols cleared, SelectedRows cleared + the row inserted.
  ///
  /// Changed props only, in the OCX order. The real GUI fires event 9
  /// TWICE per right-click — two separate rounds, the second without the
  /// delta (gui[14] / [20] / [26]), each answered by an identical menu push
  /// (srv[22] = srv[20]); GuiGo sends it once. The server's answer pushes
  /// the menu ([pendingContextMenu], kind [SapContextMenuKind.grid]; an
  /// entry goes out with [pickContextMenu]). Refused, nothing sent: a grid
  /// that did not register 9 ([StateError]), an unknown column or an
  /// undelivered row ([ArgumentError] / [RangeError]). Windows only.
  Future<List<Uint8List>> requestGridContextMenu(
    String shell, {
    int? row,
    String? columnId,
  }) {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError(
        'the grid context menu is built for the Windows dialect only',
      );
    }
    final sh = shell.trim();
    final g = grids[sh];
    if (g == null) throw ArgumentError('no live grid with shell $shell');
    final header = columnId != null && (row == null || row == 0);
    final selector = columnId == null && row != null && row >= 1;
    if (!header && !selector && (row == null || row < 1)) {
      throw ArgumentError(
        'a grid right-click names a cell (row, columnId), a header '
        '(columnId) or a row selector (row) — nothing sent',
      );
    }
    if (columnId != null && !g.columns.contains(columnId)) {
      throw ArgumentError('grid $sh has no column $columnId — nothing sent');
    }
    if (!header && !g.isRowLoaded(row!)) {
      throw RangeError('row $row is not a delivered line of grid $sh');
    }
    _requireGridEvent(sh, gridEventContextMenu);
    final pos = columnId == null ? 0 : g.columns.indexOf(columnId) + 1;
    String cellText() {
      final cells = g.rowAt(row!) ?? const <String>[];
      return pos >= 1 && pos <= cells.length ? cells[pos - 1] : '';
    }

    final target = <String, String>{
      'CurrentCellCol': '$pos',
      if (header) ...{
        'CurrentCellRow': '0',
        'CurrentCellText': '',
        'CurrentCellColID': columnId,
        'CurrentCellRowID': '',
        'CurrentCellRowIDNumeric': '0',
      } else ...{
        'CurrentCellRow': '$row',
        'CurrentCellText': selector ? '' : cellText(),
        'CurrentCellColID': columnId ?? '',
        'CurrentCellRowID': gridRowIdText(g, row!),
        'CurrentCellRowIDNumeric': '${gridRowIdNumeric(g, row)}',
      },
    };
    // the right-click's own state supersedes a selection staged on it
    clearGridSelection(sh, unstage: true);
    final changed = _gridPropDelta(sh, g, target);
    final hc = g.handles['SelectedColsOnDemand'];
    final hr = g.handles['SelectedRowsOnDemand'];
    final colId = header
        ? '${pos - 1 < g.columnIds.length ? g.columnIds[pos - 1] : pos}'
        : '';
    final tables = windowsDataChangesXml([
      if (hc != null)
        GridDataChange(hc, [
          if (header) [colId],
        ]),
      if (hr != null)
        GridDataChange(hr, [
          if (selector) ['${gridRowIdNumeric(g, row)}', '0'],
        ]),
    ]);
    final xml = ocxDataManagerXml(
      tables: tables,
      eventShell: sh,
      eventId: gridEventContextMenu,
      controls:
          [
            GridControlState(sh, props: changed, generic: gridFirstVisible(g)),
            ..._gridGenericBlocks(skip: {sh}),
          ]..sort(
            (a, b) => (int.tryParse(a.shell) ?? 0).compareTo(
              int.tryParse(b.shell) ?? 0,
            ),
          ),
    );
    _noteGridProps(sh, changed);
    _gridSel.selections[sh] = header
        ? GridSelection(
            sh,
            GridSelectionKind.columns,
            columns: [columnId],
            currentRow: 0,
            currentColumn: columnId,
            pending: false,
          )
        : selector
        ? GridSelection(
            sh,
            GridSelectionKind.rows,
            rows: [row],
            currentRow: row,
            pending: false,
          )
        : GridSelection(
            sh,
            GridSelectionKind.cell,
            currentRow: row,
            currentColumn: columnId,
            pending: false,
          );
    _ea.recordEvent(sh, const {});
    _trace(
      'grid $sh context menu on ${header ? 'header' : 'row $row'}'
      '${columnId == null ? '' : ' $columnId'} '
      '(${changed.map((p) => '${p.$1}=${p.$2}').join(', ')})',
    );
    return _ctxSend(
      gridEventItems(
        ctx,
        shell: sh,
        eventId: gridEventContextMenu,
        xml: xml,
        path: _hostedSourcePath(sh),
      ),
      (sh, columnId ?? '', row == null ? null : '$row'),
    );
  }

  /// Right-click object [objectId] of designer canvas [canvas] (a node id
  /// — `CanvasNode.id`, the MARA header `1` of a recorded session
  /// gui[37] — or a link id, `CanvasLink.id`, gui[53] `313`): the object
  /// pick `%_GC <canvas> 4194304` PARAM 0 = the id on the ICDataFlow shell
  /// that registered it. The menu of THAT object is pushed in answer
  /// (srv[39] table header {DDIC, F_TDEL}, srv[56] link {LOJOIN, F_LDEL}).
  /// Windows only. Refused (StateError / ArgumentError, nothing sent) when
  /// no shell of the canvas registered the pick, or [objectId] is none of
  /// its objects.
  Future<List<Uint8List>> requestCanvasContextMenu(
    SapCanvasModel canvas,
    String objectId,
  ) {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError(
        'canvas context menus are built for the Windows dialect only',
      );
    }
    final shell = _ctxCanvasShell(canvas);
    final id = objectId.trim();
    final known =
        canvas.node(id) != null || canvas.links.any((l) => l.id.trim() == id);
    if (id.isEmpty || !known) {
      throw ArgumentError(
        '"$objectId" is no object id of canvas ${canvas.shell} '
        '(a node or link id) — refused, nothing sent',
      );
    }
    _ea.recordEvent(shell, {0: id});
    return _ctxSend(
      canvasContextMenuRequestItems(
        ctx,
        shell: shell,
        objectId: id,
        sourcePath: _hostedSourcePath(shell),
      ),
      (shell, id, null),
    );
  }

  /// Choose the entry [fcode] of the open menu [m]: a tree's `%_GS <tree>
  /// 14` PARAM 0 = the fcode, a canvas's `%_GC <canvas> 2` PARAMs `0`, the
  /// fcode. Refused (nothing sent) with a [StateError] when [m] is no
  /// longer open or the control did not register the pick event, with an
  /// [ArgumentError] when [fcode] is not a selectable entry of [m] (a
  /// submenu header, a separator, a greyed entry — the real GUI cannot send
  /// those; a recorded session gui[49] sends the LEAF
  /// `CT_NEW_NODE`, never its `Créer` header).
  ///
  /// The server answers like any function code: a status message, a popup
  /// or a repaint (a recorded session srv[46]: `F_TDEL` refused
  /// with AQQIS_CNTRL 009 on the status bar).
  Future<List<Uint8List>> pickContextMenu(SapContextMenu m, String fcode) {
    final open = contextMenuFor(m.shell);
    if (open == null || !identical(open, m)) {
      throw StateError(
        'the context menu of ${m.shell} is no longer open (picked, '
        'dismissed or superseded) — nothing sent',
      );
    }
    final e = m.entry(fcode.trim());
    if (e == null || !e.isSelectable) {
      final why = e == null
          ? 'not an entry'
          : (e.isSubmenu ? 'a submenu header' : 'greyed (disabled)');
      throw ArgumentError(
        '"$fcode" is $why of the menu pushed for ${m.shell} '
        '(${m.entries.where((x) => x.isSelectable).map((x) => x.fcode).join(', ')})'
        ' — nothing sent',
      );
    }
    final reg = _canvasState.tracker.registeredEvents[m.shell] ?? const <int>{};
    final windows = answerDialect == GuiDialect.windows;
    final List<Uint8List> items;
    switch (m.kind) {
      case SapContextMenuKind.tree:
        if (!reg.contains(contextMenuFunctionEvent)) {
          throw StateError(
            'tree ${m.shell} did not register the context-menu function '
            'event $contextMenuFunctionEvent (registered: '
            '${reg.toList()..sort()}) — nothing sent',
          );
        }
        items = treeContextMenuPickItems(
          ctx,
          shell: m.shell,
          fcode: e.fcode,
          sourcePath: windows ? _hostedSourcePath(m.shell) : null,
          windows: windows,
        );
      case SapContextMenuKind.canvas:
        if (!windows) {
          throw UnsupportedError(
            'canvas context menus are built for the Windows dialect only',
          );
        }
        if (!reg.contains(canvasContextMenuSelectEvent)) {
          throw StateError(
            'canvas ${m.shell} did not register CONTEXTMENUSEL '
            '($canvasContextMenuSelectEvent; registered: '
            '${reg.toList()..sort()}) — nothing sent',
          );
        }
        items = canvasContextMenuPickItems(
          ctx,
          shell: m.shell,
          fcode: e.fcode,
          sourcePath: _hostedSourcePath(m.shell),
        );
      case SapContextMenuKind.grid:
        // the grid's own menu: ContextMenuSelected `%_GC <grid> 13` PARAM
        // 0 = the fcode, the grid's GENERIC only — no CurrentCell* / no
        // DATACHANGES (a recorded session gui[16] / [22])
        _requireGridEvent(m.shell, gridEventContextMenuSelected);
        items = _gridToolbarEventItems(
          m.shell,
          gridEventContextMenuSelected,
          [e.fcode],
          record: false,
        );
      case SapContextMenuKind.gridToolbar:
        // a grid toolbar menu's entry: `%_GC <grid> 14` PARAM 0 = its fcode
        // (a recorded session gui[87]; a static menu's entry the
        // same, a recorded session gui[231]) — sap_session_toolbar.dart
        _requireGridEvent(m.shell, gridEventToolbarMenuItem);
        items = _gridToolbarEventItems(
          m.shell,
          gridEventToolbarMenuItem,
          [e.fcode],
          record: false,
        );
      case SapContextMenuKind.toolbar:
        // a SAP.Toolbar.1 menu's entry: functionSelected `%_GC <toolbar> 1`
        // PARAM 0 = the entry's fcode verbatim (a recorded session
        // wingui gui[7])
        if (!windows) {
          throw UnsupportedError(
            'toolbar menus are built for the Windows dialect only',
          );
        }
        items = cfwToolbarButtonItems(
          ctx,
          toolbarShell: m.shell,
          code: e.fcode,
          sourcePath: _hostedSourcePath(m.shell),
        );
      case SapContextMenuKind.other:
        throw StateError(
          'no recorded pick event for the menu of ${m.shell} '
          '(${_canvasState.tracker.controls[m.shell]?.cls ?? 'unknown class'}) '
          '— nothing sent',
        );
    }
    _ea.recordEvent(
      m.shell,
      m.kind == SapContextMenuKind.canvas
          ? {0: canvasContextMenuSelectPid0, 1: e.fcode}
          : {0: e.fcode},
    );
    return _ctxSend(items, null);
  }

  // --- internals --------------------------------------------------------

  /// Send a context-menu round as the session's own: the open menus close
  /// (a request opens the next), [request] names what the answer's push
  /// belongs to, [flushed] the selection props the round carried.
  Future<List<Uint8List>> _ctxSend(
    List<Uint8List> items,
    (String, String, String?)? request, {
    (String, List<(String, String)>)? flushed,
  }) async {
    final st = _ctxMenu;
    st.clear();
    st.request = request;
    if (flushed != null && flushed.$2.isNotEmpty) {
      st.tracker.noteFlushed(flushed.$1, flushed.$2);
    }
    st.ownRound = true;
    try {
      return await _act(items, controlEvent: true, dialectReady: true);
    } finally {
      st.ownRound = false;
      st.request = null;
    }
  }

  /// The tree's own NODE_KEY wire string for [key] (the padded form when
  /// only the trimmed one was given).
  String _ctxTreeKey(String shell, String key) {
    final nodes = trees[shell]?.nodes;
    if (nodes == null || nodes.containsKey(key)) return key;
    final m = nodes.keys.where((k) => k.trim() == key.trim()).toList();
    return m.length == 1 ? m.single : key;
  }

  /// The selection change a right-click on ([key], [item]) flushes: the
  /// props of the selection the tree REGISTERED (an unregistered PROPERTY
  /// dumps CNDP 008) whose value the server does not hold already — none
  /// when the tree keeps its selection (DisableSelChngOnCxtMenuReq).
  List<(String, String)> _ctxSelectionDelta(
    String shell,
    String key,
    String? item,
  ) {
    final st = _ctxMenu;
    if (st.tracker.selectionKept.contains(shell)) return const [];
    final cached = _canvasState.tracker.cachedProps[shell];
    if (cached == null) return const [];
    // an ITEM request on a tree that registered BOTH selection channels:
    // the right-click selects the (node, item) CELL, which clears the node
    // selection — ABAPSelNodeKey "", ABAPSelItemKey, TopNodeKey (registered
    // and known), ABAPSelItemName, in the OCX flush order (not the
    // registration order NodeKey, TopNodeKey, ItemKey, ItemName):
    // a recorded session gui[12] `%_GC 122 26` (` 2` / `2`,
    // TopNodeKey FORMNAME), gui[33] / [41] (TopNodeKey unchanged: none),
    // a recorded session gui[23]; changed values only —
    // smartforms gui[25] repeats the request with none (reference client 534a50c §1,
    // raw_canvas_menu._item_request_selection)
    if (item != null &&
        cached.contains(selNodeKeyProp) &&
        cached.contains(selItemKeyProp) &&
        cached.contains(selItemNameProp)) {
      final top = cached.contains(topNodeKeyProp) ? _ctxTopNodeKey(shell) : null;
      return st.tracker.changed(shell, [
        (selNodeKeyProp, ''),
        (selItemKeyProp, key),
        if (top != null && top.isNotEmpty) (topNodeKeyProp, top),
        (selItemNameProp, item),
      ]);
    }
    final want = item == null
        ? [(selNodeKeyProp, key), (selItemKeyProp, ''), (selItemNameProp, '')]
        : [
            (selNodeKeyProp, ''),
            (selItemKeyProp, key),
            (selItemNameProp, item),
          ];
    // registration order: the OCX writes the props in the order the tree
    // registered them (smartforms gui[23] / sfp gui[12]: ABAPSelNodeKey,
    // ABAPSelItemKey, ABAPSelItemName after RegisterCachedProp NodeKey,
    // TopNodeKey, ItemKey, ItemName)
    final props = [
      for (final p in cached)
        for (final w in want)
          if (w.$1 == p) w,
    ];
    return st.tracker.changed(shell, props);
  }

  /// The first displayed node of tree [shell] (jar getTopNodeKey on an
  /// unscrolled tree): its first root in display order, the key verbatim;
  /// null when the session holds no node of it (reference client ea_treeorder
  /// .tree_top_node_keys — nothing guessed).
  String? _ctxTopNodeKey(String shell) {
    final roots = trees[shell]?.roots;
    return (roots == null || roots.isEmpty) ? null : roots.first.key;
  }

  /// The canvas shell that registered the object pick.
  String _ctxCanvasShell(SapCanvasModel c) {
    final t = _canvasState.tracker;
    for (final sh in [?c.eventShell, c.shell]) {
      if (t.registeredEvents[sh]?.contains(canvasObjectPickEvent) ?? false) {
        return sh;
      }
    }
    throw StateError(
      'canvas ${c.shell}: no shell registered the object pick '
      '$canvasObjectPickEvent (the right-click) — nothing sent',
    );
  }

  SapContextMenuKind _ctxKindOf(String shell) {
    final t = _canvasState.tracker;
    final reg = t.registeredEvents[shell] ?? const <int>{};
    final cls = (t.controls[shell]?.cls ?? '').toUpperCase();
    if (reg.contains(treeEventRequestNodeContextMenu) ||
        reg.contains(treeEventRequestItemContextMenu) ||
        reg.contains(treeEventRequestHeaderContextMenu) ||
        reg.contains(treeEventRequestBackgroundContextMenu) ||
        cls.contains('TREE')) {
      return SapContextMenuKind.tree;
    }
    if (reg.contains(canvasObjectPickEvent) || cls.contains('ICDATAFLOW')) {
      return SapContextMenuKind.canvas;
    }
    if (grids.containsKey(shell) || cls.contains('GRIDVIEW')) {
      return SapContextMenuKind.grid;
    }
    return SapContextMenuKind.other;
  }

  // --- hooks (sap_session.dart) -------------------------------------------

  /// Fold one complete flush call's context-menu facts: bind the menus its
  /// SetContextMenu verbs push.
  void _ingestContextMenuCall(Uint8List value, [FlushCall? parsed]) {
    try {
      final st = _ctxMenu;
      final bound = st.tracker.foldCall(
        value,
        // a toolbar menu verb runs on the grid object by its server token
        // (sap_session_toolbar.dart)
        shellOf: (h) => _ea.shellAlias[h] ?? _gridShellOfOwner(h),
        trackShell: st.request?.$1,
        segment: (url) => _ea.dpCache.byUrl[url],
        step: step,
        parsed: parsed,
      );
      final s = screen;
      for (final sh in bound) {
        final p = st.tracker.pushes[sh]!;
        final req = st.request;
        final mine = req != null && req.$1 == sh;
        st.menus[sh] = SapContextMenu(
          shell: sh,
          kind: switch (p.verb) {
            gridTrackMenuVerb => SapContextMenuKind.gridToolbar,
            toolbarTrackMenuVerb => SapContextMenuKind.toolbar,
            _ => _ctxKindOf(sh),
          },
          entries: p.entries,
          url: p.url,
          targetKey: mine ? req.$2 : null,
          itemName: mine ? req.$3 : null,
          step: p.step,
        );
        if (s != null) st.screens[sh] = _screenIdentity(s);
        st.newest = sh;
      }
    } catch (e) {
      _noteIngestFailure('context menu ingest', e);
    }
  }

  /// An action round goes out: one this extension did not send closes the
  /// open menus (the real GUI's popup closes on any other input).
  void _noteContextMenuRound() {
    final st = _ctxMenu;
    if (!st.ownRound) st.clear();
  }
}

final Expando<_ContextMenuState> _ctxMenuStates = Expando('contextMenuState');

class _ContextMenuState {
  final ContextMenuTracker tracker = ContextMenuTracker();

  /// shell -> the open menu
  final Map<String, SapContextMenu> menus = {};

  /// shell -> the screen the menu was pushed on
  final Map<String, (String?, String?, int)> screens = {};

  /// the shell of the newest menu
  String? newest;

  /// the request being sent: (shell, node key / object id, item)
  (String, String, String?)? request;

  /// a round of this extension is being sent
  bool ownRound = false;

  void clear() {
    menus.clear();
    screens.clear();
    newest = null;
  }
}
