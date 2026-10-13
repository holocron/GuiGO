part of 'sap_session.dart';

/// Tree control actions on a SPECIFIC tree shell — a screen can host
/// several trees (the DBA cockpit's navigation tree beside an Easy Access
/// tree that is still alive), so the newest-tree default of
/// [SapSession.expandTreeNode] is not enough.
extension SapSessionTree on SapSession {
  /// Activate [nodeKey] of tree [shell] — SAP GUI's double-click on a node
  /// (a leaf opens its function). A COLUMN tree that registered EVENTID 22
  /// ITEMDBLCLICK gets the item event with the node's first item name, as
  /// the real GUI sends it on the DBA cockpit's navigation tree
  /// (a recorded session gui[19]: `%_GC 147 22`, PARAM0
  /// " 206", PARAM1 "Task"); a simple tree gets 25 NODEDBLCLICK, or 21
  /// SELCHANGE when only that one is registered (reference client raw_tree
  /// `pick_tree_event`, TREE_ACTIVATE_EVENTS = (25, 21)). The double-click
  /// selects what it hits: the tree's registered selection props that
  /// change ride the event ([_treeEventRound]).
  Future<List<Uint8List>> activateTreeNode(String shell, String nodeKey) {
    final reg = _canvasState.tracker.registeredEvents[shell] ?? const <int>{};
    // the double-click selects the node it hits: the tree's SelectionKeys
    // read-back reports it from now on
    noteTreeSelection(shell, nodeKey);
    String? item;
    int ev;
    if (reg.contains(22)) {
      ev = 22;
      final items = trees[shell]?.nodes[nodeKey]?.items.keys;
      item = (items == null || items.isEmpty) ? '1' : items.first;
    } else {
      ev = _pickTreeEvent(shell, const [treeEventNodeDoubleClick, 21]);
    }
    _ea.recordEvent(shell, {0: nodeKey, if (item != null) 1: item});
    return _act(
      _treeEventRound(shell, ev, nodeKey, itemName: item, selects: true),
      controlEvent: true,
    );
  }

  /// The event SAP GUI's double-click on a node of tree [shell] sends: 22
  /// ITEMDBLCLICK on a column tree that registered it, 25 NODEDBLCLICK on
  /// one that registered that — for a FOLDER as for a leaf (SE80's object
  /// root ` 1` opens the program: a recorded session gui[26];
  /// the folder ` 4` it had just expanded, gui[44]). Null when the tree's
  /// registration is known and holds neither: the front end then handles
  /// the double-click itself (a folder toggles), and nothing goes out.
  /// Nothing recorded for [shell] = 25, the activation family's default
  /// ([_pickTreeEvent]).
  int? treeDoubleClickEvent(String shell) {
    final reg = _canvasState.tracker.registeredEvents[shell];
    if (reg == null || reg.isEmpty) return treeEventNodeDoubleClick;
    if (reg.contains(22)) return 22;
    if (reg.contains(treeEventNodeDoubleClick)) return treeEventNodeDoubleClick;
    return null;
  }

  /// Whether tree [shell] registered 21 SELCHANGE: a click on a node is a
  /// server round then (the SM12 navigation tree's, `[15, 21, 40]`),
  /// otherwise a selection stays on the client until a round reads it.
  bool treeSelectionEventRegistered(String shell) =>
      _canvasState.tracker.registeredEvents[shell]?.contains(21) ?? false;

  /// A click on node [nodeKey] of tree [shell]: it becomes the tree's
  /// selection (the SelectionKeys read-back, [noteTreeSelection]); a tree
  /// that registered 21 SELCHANGE gets `%_GC <shell> 21` with the node key
  /// and its changed selection props, as [activateTreeNode] sends it for a
  /// tree that handles only that. Without 21 nothing goes out (an empty
  /// list).
  Future<List<Uint8List>> selectTreeNode(String shell, String nodeKey) async {
    noteTreeSelection(shell, nodeKey);
    if (!treeSelectionEventRegistered(shell)) return const [];
    _ea.recordEvent(shell, {0: nodeKey});
    return _act(
      _treeEventRound(shell, 21, nodeKey, selects: true),
      controlEvent: true,
    );
  }

  /// Node [nodeKey] is tree [shell]'s selection now (a click, a
  /// double-click): what the client answers when the server reads the
  /// tree's `SelectionKeys` back. The real GUI's SE80 tree refresh
  /// (a recorded session srv[149] / [153] -> gui[141] / [145]) reads
  /// ` 14`, the screen it had double-clicked (gui[107]); before any click
  /// the read-back is the empty table (gui[103]).
  void noteTreeSelection(String shell, String nodeKey) {
    _w.selectionKeys[shell] = [nodeKey];
  }

  /// The user opened ([open]) or closed folder [nodeKey] of tree [shell]
  /// on the client (its children already there — no server round): what
  /// the `ExpandedKeys` read-back reports. The real GUI's answer is the
  /// tree's expansion as the user left it (a recorded session
  /// gui[143]: the root ` 1` and the ` 9` it expanded), so a folder
  /// folded again is not reported open. A key is held once, whatever its
  /// padding: the reference client's `1, 4, 4` (a node listed twice) aborted
  /// CL_COLUMN_TREE_MODEL with "Erreur interne dans Tree Model" (reference client
  /// ea_selectedrows.unique_node_keys).
  void noteTreeExpansion(String shell, String nodeKey, {required bool open}) {
    final keys = _expandedKeys[shell] ??= [];
    final k = nodeKey.trim();
    keys.removeWhere((x) => x.trim() == k);
    if (open) keys.add(nodeKey);
  }

  /// Ask tree [shell] for the children of folder [nodeKey] (EVENTID 18
  /// EXPANDNOCHILDREN, or 19 EXPAND when only that one is registered).
  Future<List<Uint8List>> expandTreeNodeOf(String shell, String nodeKey) {
    final ev = _pickTreeEvent(shell, const [treeEventExpandNoChildren, 19]);
    _ea.recordEvent(shell, {0: nodeKey});
    noteTreeExpansion(shell, nodeKey, open: true);
    return _act(_treeEventRound(shell, ev, nodeKey), controlEvent: true);
  }

  /// The items of tree event [eventId] on [shell] for [nodeKey] (and
  /// [itemName], an ITEM event's PARAM 1) in the connection's dialect —
  /// still to be re-spelled by [SapSession._act] (controlEvent: true).
  ///
  /// Java: [treeEventItems] as built (a recorded session). Windows: the
  /// same round with the DATAMANAGER the OCX writes — a recorded session
  /// chart_realgui gui[17] `%_GC 147 18` / gui[19] `%_GC 147 22`, the
  /// corpus' 400-odd Windows tree events: the OCX spelling (`<PARAM PID
  /// ="0" VALUE ="…"/>`, no line break after the declaration), then ONE
  /// CONTROLS section, its CONTROL blocks in ascending shell order: the
  /// first-visible GENERIC of every live grid that registered it (118 / 180
  /// beside the DBA cockpit's tree) and — on an activation ([selects]) —
  /// the tree's selection change: its REGISTERED selection props whose
  /// value the server does not hold yet (gui[19]: ABAPSelItemKey = the
  /// padded key, ABAPSelItemName "Task"; a recorded session gui[23]:
  /// the item name unchanged, the key alone; an unregistered PROPERTY dumps
  /// CNDP 008). The real GUI's event never went out without that block;
  /// GuiGo's did (2026-10-12 live `%_GC 148 22`, Java-spelled, no
  /// CONTROLS — the server dumped CNDP 008 in that round).
  List<Uint8List> _treeEventRound(
    String shell,
    int eventId,
    String nodeKey, {
    String? itemName,
    bool selects = false,
  }) {
    final items = treeEventItems(
      ctx,
      shell: shell,
      eventId: eventId,
      nodeKey: nodeKey,
      itemName: itemName,
    );
    if (answerDialect != GuiDialect.windows) return items;
    final selection = selects
        ? _ctxSelectionDelta(shell, nodeKey, itemName, activation: true)
        : const <(String, String)>[];
    final controls =
        [
          for (final g in _toolbarGenerics(shell))
            if (g.shell != shell) g,
          if (selection.isNotEmpty) GridControlState(shell, props: selection),
        ]..sort(
          (a, b) => (int.tryParse(a.shell) ?? 0).compareTo(
            int.tryParse(b.shell) ?? 0,
          ),
        );
    final xml = ocxDataManagerXml(
      eventShell: shell,
      eventId: eventId,
      eventParams: [nodeKey, ?itemName],
      controls: controls,
    );
    if (selection.isNotEmpty) {
      _ctxMenu.tracker.noteFlushed(shell, selection);
    }
    return [
      for (final raw in items)
        if (_isXmlItem(raw)) xmlBlobItem(wireText(xml)) else raw,
    ];
  }

  bool _isXmlItem(Uint8List raw) {
    final w = walkItems(raw).items;
    return w.length == 1 && w.single.type == itemXmlBlob;
  }

  /// The first of [family] the tree registered (RegisterEvent verbs seen
  /// on the wire), else the family's first when nothing was recorded.
  int _pickTreeEvent(String shell, List<int> family) {
    final reg = _canvasState.tracker.registeredEvents[shell];
    if (reg == null || reg.isEmpty) return family.first;
    for (final e in family) {
      if (reg.contains(e)) return e;
    }
    return family.first;
  }

  /// Fold the HeaderNames tables [call] assigns to column trees
  /// (tree_header_names.dart): the newest non-empty assignment per tree —
  /// keyed by the token the call names it with and its shell alias — and
  /// of any tree, plus the newest ItemEx/Hidden(0) declaration list (the
  /// fallback of a tree never assigned one). An EMPTY assignment (the Java
  /// pull flush's `HeaderNames2`, a recorded session srv[41])
  /// changes nothing. The table's DP_PUT is the call's own nested push
  /// (the launch batch's, joined across its chunks), else the session's
  /// cached one.
  void _noteHeaderNames(FlushCall call, Uint8List value) {
    if (call.verbs.contains('AssignProperty2')) {
      DpCache? own;
      Uint8List? segment(String url) =>
          (own ??= DpCache()..ingestValue(value)).byUrl[url] ??
          _ea.dpCache.byUrl[url];
      for (final a in headerNamesAssignments(call, segment)) {
        if (a.table.isEmpty) continue;
        final keys = {a.target, ?_ea.shellAlias[a.target]}..remove('');
        for (final k in keys) {
          _w.headerNames[k] = a.table;
        }
        _w.lastHeaderNames = a.table;
        _trace('tree ${a.target.isEmpty ? '?' : a.target}: ${a.prop} := '
            '${a.table.rows.length} names x ${a.table.width}');
      }
    }
    if (call.verbs.contains('ItemEx')) {
      final declared = declaredVisibleHeaders(call);
      if (declared.isNotEmpty) _w.declaredHeaders = declared;
    }
    if (call.verbs.contains('ABAPWidth')) {
      _w.headerWidths.addAll(declaredHeaderWidths(call));
    }
  }

  /// The answers to [call]'s `WidthInChar` reads of tree headers (VARS
  /// result row -> value): the width the server last declared for the
  /// header the nearest preceding `ItemEx` / `HierarchyHeader` addresses,
  /// else 10 (the reference client's ea_frontend_answers._header_width_value). The
  /// real GUI answers exactly that: after BT_SELECTDT the ALV tree reads
  /// all 15 header widths (a recorded session raw srv[42], step 57)
  /// and raw gui[35] returns 10 / 11 / 10 / 15 x 7 / 50 / 50 / 6 / 30 /
  /// 60 — the ABAPWidths of the launch batch's LAST declaration of each
  /// (`C 8`: 46 at verb 317, then 10 at 780) — which the server
  /// re-declares (raw srv[47]). GuiGo answered 0: zero-width columns.
  Map<int, Uint8List> _treeHeaderPropAnswers(FlushCall call) {
    final out = <int, Uint8List>{};
    if (!call.verbs.contains('WidthInChar')) return out;
    final meta = verbMeta(call);
    String? cur;
    for (var i = 1; i <= call.verbs.length && i <= meta.length; i++) {
      final verb = call.verbs[i - 1];
      if (verb == 'ItemEx') {
        final n = (verbNamedArgs(call, i)['#1'] ?? '').trim();
        cur = n.isEmpty ? null : n;
      } else if (verb == 'HierarchyHeader') {
        cur = 'HierarchyHeader';
      } else if (verb == 'WidthInChar') {
        final res = int.tryParse(meta[i - 1].result?.trim() ?? '');
        if (res == null || res < 1) continue;
        final w = cur == null ? null : _w.headerWidths[cur];
        out[res - 1] = Uint8List.fromList('${w ?? 10}'.codeUnits);
      }
    }
    return out;
  }

  /// The HeaderNames table a read-back of tree [source] (the handle or
  /// shell the pull's AssignProperty2 names) returns: the one assigned to
  /// it (by token or shell alias — the read names the tree by the handle
  /// the client minted, `28` for shell 136 in a recorded session), else
  /// the newest assigned to any tree (the reference client's single-table model),
  /// else the declared visible headers; null when the session saw none.
  HeaderNamesTable? _headerNamesOf(String source) {
    final s = source.trim();
    final t = _w.headerNames[s] ??
        _w.headerNames[_ea.shellAlias[s] ?? ''] ??
        _w.lastHeaderNames;
    if (t != null) return t;
    if (_w.declaredHeaders.isEmpty) return null;
    return HeaderNamesTable.ofNames(_w.declaredHeaders);
  }
}
