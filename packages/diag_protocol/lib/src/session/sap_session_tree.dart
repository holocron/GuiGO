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
  ///
  /// [itemName] = the column the double-click hit on a column tree (its
  /// cell, not the node text): the ITEMDBLCLICK names it (the real GUI's
  /// `%_GC 134 22` PARAM1 `&Hierarchy` on the node text,
  /// a recorded session raw gui[145]).
  Future<List<Uint8List>> activateTreeNode(
    String shell,
    String nodeKey, {
    String? itemName,
  }) {
    final reg = _canvasState.tracker.registeredEvents[shell] ?? const <int>{};
    // the double-click selects the node it hits: the tree's SelectionKeys
    // read-back reports it from now on
    noteTreeSelection(shell, nodeKey);
    String? item;
    int ev;
    if (reg.contains(treeEventItemDoubleClick)) {
      ev = treeEventItemDoubleClick;
      final items = trees[shell]?.nodes[nodeKey]?.items.keys;
      item = itemName ??
          ((items == null || items.isEmpty) ? '1' : items.first);
    } else {
      ev = _pickTreeEvent(
          shell, const [treeEventNodeDoubleClick, treeEventSelectionChange]);
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
    if (reg.contains(treeEventItemDoubleClick)) return treeEventItemDoubleClick;
    if (reg.contains(treeEventNodeDoubleClick)) return treeEventNodeDoubleClick;
    return null;
  }

  /// Whether tree [shell] registered 21 SELCHANGE: a click on a node is a
  /// server round then (the SM12 navigation tree's, `[15, 21, 40]`),
  /// otherwise a selection stays on the client until a round reads it.
  bool treeSelectionEventRegistered(String shell) =>
      _canvasState.tracker.registeredEvents[shell]
          ?.contains(treeEventSelectionChange) ??
      false;

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
      _treeEventRound(shell, treeEventSelectionChange, nodeKey, selects: true),
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
    final ev = _pickTreeEvent(
        shell, const [treeEventExpandNoChildren, treeEventExpand]);
    _ea.recordEvent(shell, {0: nodeKey});
    noteTreeExpansion(shell, nodeKey, open: true);
    return _act(_treeEventRound(shell, ev, nodeKey), controlEvent: true);
  }

  /// SAP GUI's double-click on node [nodeKey] of tree [shell], as the
  /// WDTTREE.OCX fires it (a recorded session): on a
  /// FOLDER whose children are still on the server (EXPANDER, none pushed)
  /// first 18 ExpandNoChildren — its answer the tree fill adding the
  /// children (srv[70]) — THEN, once that round is answered, the node
  /// double-click [activateTreeNode] on the same key (gui[61] `%_GC 152 18`
  /// PID0 `6` + the tree's changed TopNodeKey, gui[63] `%_GC 152 25` PID0
  /// `6`, answered RemoveAllMarker + SetSavePoint only); the node ends
  /// expanded and selected (the read-backs gui[67] ExpandedKeys `{1, 4, 5,
  /// 6, 8}`, gui[69] SelectionKeys `{6}`). A leaf, or a folder whose
  /// children are pushed, gets the double-click alone (gui[41] / [45] /
  /// [51] / [57]). A tree that registered no double-click event
  /// ([treeDoubleClickEvent] null) gets the expansion only. Returns both
  /// rounds' frames.
  ///
  /// [itemName]: the column tree cell the double-click hit
  /// ([activateTreeNode]).
  Future<List<Uint8List>> doubleClickTreeNode(
    String shell,
    String nodeKey, {
    String? itemName,
  }) async {
    final node = trees[shell]?.nodes[nodeKey];
    final unloaded = node != null && node.children.isEmpty && node.expander;
    final out = <Uint8List>[];
    if (unloaded) out.addAll(await expandTreeNodeOf(shell, nodeKey));
    if (treeDoubleClickEvent(shell) == null) return out;
    out.addAll(await activateTreeNode(shell, nodeKey, itemName: itemName));
    return out;
  }

  /// The event a click on item [itemName] of node [nodeKey] of column tree
  /// [shell] sends — the item's own, by its CLASS ([SapTreeItem]), when the
  /// tree registered it: 35 LINKCLICK on a link item (the /AIF/IFMON count
  /// cells: a recorded session raw gui[116] `%_GC 136 35` on the root
  /// ` 1`, item `C 22`), 29 BUTTONCLICK on a button item
  /// (reference client raw_tree TREE_EVENT_PARAMS: both (node key, item name)). Null
  /// for a text item, a disabled one, or an event the tree did not
  /// register: the click then only selects ([selectTreeNode]).
  int? treeItemClickEvent(String shell, String nodeKey, String itemName) {
    final cell = trees[shell]?.nodes[nodeKey]?.cells[itemName];
    if (cell == null || cell.disabled) return null;
    final reg = _canvasState.tracker.registeredEvents[shell] ?? const <int>{};
    final ev = switch (cell.itemClass) {
      SapTreeItem.classLink => treeEventLinkClick,
      SapTreeItem.classButton => treeEventButtonClick,
      _ => null,
    };
    return ev != null && reg.contains(ev) ? ev : null;
  }

  /// A click on item [itemName] of node [nodeKey] of column tree [shell]
  /// (a cell): the item's event ([treeItemClickEvent]) — `%_GC <shell>
  /// <35|29>`, PARAM0 the node key, PARAM1 the item name, and the cell
  /// selection it makes in the tree's CONTROL block (its registered
  /// ABAPSelItemKey / ABAPSelItemName that changed: raw gui[116]
  /// `ABAPSelItemKey = 1`, `ABAPSelItemName = C 22`).
  /// An item with no event of its own selects the node ([selectTreeNode]).
  Future<List<Uint8List>> clickTreeItem(
    String shell,
    String nodeKey,
    String itemName,
  ) {
    final ev = treeItemClickEvent(shell, nodeKey, itemName);
    if (ev == null) return selectTreeNode(shell, nodeKey);
    noteTreeSelection(shell, nodeKey);
    _ea.recordEvent(shell, {0: nodeKey, 1: itemName});
    return _act(
      _treeEventRound(shell, ev, nodeKey, itemName: itemName, selects: true),
      controlEvent: true,
    );
  }

  /// The column layout of column tree [shell] — its hierarchy column and
  /// item columns as the server declared them ([foldTreeColumns]: the
  /// `Structures` / `Headers` collections, the HeaderNames display order),
  /// null for a tree with no item column (a simple tree, the Easy Access
  /// menu).
  SapTreeColumns? treeColumns(String shell) {
    final f = _treeColumnsOf[_w];
    if (f == null) return null;
    final c = f[shell] ?? f[_ea.shellAlias[shell] ?? ''];
    if (c == null || c.isEmpty) return null;
    return c;
  }

  /// The heading of tree [shell]'s header strip — a tree with NO item
  /// column whose header the server switched on (`WithHeader(1)`: the
  /// CL_GUI_COLUMN_TREE trees of GFW_DEMO_HIER3, hierarchy item `HD`, the
  /// real GUI's blank grey strip over each: a recorded session
  /// srv[28] verb 111, the heading re-put '' at srv[29] verb 20) — else
  /// null (a column tree draws its header row itself, [treeColumns]; a
  /// simple tree has none).
  String? treeHeaderStrip(String shell) {
    final f = _treeColumnsOf[_w];
    if (f == null) return null;
    final c = f[shell] ?? f[_ea.shellAlias[shell] ?? ''];
    if (c == null || !c.isEmpty) return null;
    if (!c.withHeaderDeclared || !c.withHeader) return null;
    return c.hierarchy.heading.trim();
  }

  /// The tree a column declaration / HeaderNames assignment addresses by
  /// [token]: a tree shell, the shell a handle the session minted stands
  /// for — else (a handle the session never minted: a replayed recording
  /// keeps the recording client's, `28` for 136 in a recorded session)
  /// the ONE column tree the window declared; null for another control's.
  String? _columnTreeOf(String token, Map<String, String> kinds) {
    final t = token.trim();
    if (t.isEmpty) return null;
    if (kinds[t] == 'tree') return t;
    final a = _ea.shellAlias[t];
    if (a != null) return kinds[a] == 'tree' ? a : null;
    if (kinds.containsKey(t)) return null;
    final known = [
      for (final k in (_treeColumnsOf[_w] ?? const {}).keys)
        if (kinds[k] == 'tree' || !kinds.containsKey(k)) k,
    ];
    return known.length == 1 ? known.single : null;
  }

  /// Fold [call]'s column declarations ([foldTreeColumns]) and its
  /// HeaderNames assignments ([headerNamesAssignments], their display
  /// order) into the window's column trees.
  void _foldTreeColumnCall(
    FlushCall call,
    List<HeaderNamesAssignment> assigned,
  ) {
    Map<String, String>? kinds;
    Map<String, String> kindsNow() => kinds ??= _layoutState.registry.kinds();
    final f = _treeColumnsOf[_w] ??= {};
    foldTreeColumns(
      call,
      columnsOf: (t) => f[t] ??= SapTreeColumns(),
      treeOf: (token) => _columnTreeOf(token, kindsNow()),
    );
    for (final a in assigned) {
      if (a.table.isEmpty) continue;
      final t = f.containsKey(a.target)
          ? a.target
          : _columnTreeOf(a.target, kindsNow());
      if (t == null) continue;
      (f[t] ??= SapTreeColumns()).headerNames = a.table.names;
    }
  }

  /// The user's view of tree [shell] shows node [nodeKey] as its first row
  /// (the app's scroll position): the tree's `TopNodeKey` cached property.
  /// Sends nothing; the next event of the tree flushes it when the server
  /// does not hold it yet (a recorded session gui[61]:
  /// `TopNodeKey = 15` with the 18 after the user scrolled).
  void noteTreeTopNode(String shell, String nodeKey) {
    _treeTops[shell] = nodeKey;
  }

  Map<String, String> get _treeTops => _treeTopNodes[_w] ??= {};

  /// The first node tree [shell]'s view shows: the one the app reported
  /// ([noteTreeTopNode]) while the tree holds it, else its first shown root
  /// (an unscrolled tree — the real GUI's report after the fill, gui[18]
  /// ` 1`); null when the session holds no node of it.
  String? _treeTopNodeKey(String shell) {
    final t = trees[shell];
    if (t == null) return null;
    final r = _treeTops[shell];
    if (r != null && t.nodes.containsKey(r)) return r;
    for (final n in t.roots) {
      if (!n.hidden) return n.key;
    }
    return null;
  }

  /// The tree's `TopNodeKey` when it registered the cached property and
  /// the server does not hold the view's first node yet, else null.
  (String, String)? _treeTopNodeDelta(String shell) {
    final cached = _canvasState.tracker.cachedProps[shell];
    if (cached == null || !cached.contains(topNodeKeyProp)) return null;
    final top = _treeTopNodeKey(shell);
    if (top == null || top.trim().isEmpty) return null;
    final ch = _ctxMenu.tracker.changed(shell, [(topNodeKeyProp, top)]);
    return ch.isEmpty ? null : ch.single;
  }

  /// The tree `TopNodeKey` reports of a flush that FILLS trees (an
  /// AddR3Table / AddItemTable / UpdateR3Table queue): the OCX reports the
  /// registered cached property that changed in the flush's answer — the
  /// first node of the freshly filled tree (a recorded session
  /// dblclick gui[18] step 41: 152 `TopNodeKey = 1`; gui[4] step
  /// 16: the Easy Access tree 105 `Favo`); an expansion that keeps the top
  /// reports nothing (gui[40]). Recorded as what the server holds, so the
  /// next event does not flush it again (gui[39]: no TopNodeKey). A queue
  /// that registers the property reports it itself (the responder's
  /// registration report: gui[15] `TopNodeKey ""`).
  List<ControlReport> _treeTopNodeReports(FlushCall call) {
    if (answerDialect != GuiDialect.windows) return const [];
    if (!call.verbs.any(_treeFillVerbs.contains)) return const [];
    final cachedAll = _canvasState.tracker.cachedProps;
    final puts = _topNodePutsOf(call);
    final out = <ControlReport>[];
    for (final sh in {...trees.keys, ...puts.keys}) {
      if (call.cachedProps.contains((sh, topNodeKeyProp))) continue;
      if (!(cachedAll[sh]?.contains(topNodeKeyProp) ?? false)) continue;
      final put = puts[sh];
      final d = put != null
          ? (topNodeKeyProp, put)
          : _treeTopNodeDelta(sh);
      if (d == null) continue;
      _ctxMenu.tracker.noteFlushed(sh, [d]);
      out.add(ControlReport(sh, props: [d]));
    }
    return out;
  }

  /// The trees [call] scrolls itself — a `TopNodeKey(=<key>)` property put
  /// on the tree, in the queue that fills it (CL_TREE_CONTROL_BASE
  /// set_top_node: GFW_DEMO_HIER3's trees, a recorded session
  /// srv[29] verb 49 `TopNodeKey(=N1)` on 137, srv[30] / srv[31] verb 40
  /// on 141 / 146) -> the key. The OCX reports it back in that very
  /// answer as the changed cached prop (g[22] 137 `N1`, g[23] 141 `N1`,
  /// g[24] 146 `N1`) and the view shows it first ([noteTreeTopNode]). The
  /// tree is the put's object: its shell, the handle's alias, else the tree
  /// the call fills through that handle ([_treeFilledBy]) — never a guess
  /// among the screen's trees (the push binding of HIER3 is folded with
  /// the frame, after this answer).
  Map<String, String> _topNodePutsOf(FlushCall call) {
    if (!call.verbs.contains(topNodeKeyProp)) return const {};
    final meta = verbMeta(call);
    final kinds = _layoutState.registry.kinds();
    final created = <String, String>{
      for (var i = 1; i <= call.verbs.length && i <= meta.length; i++)
        if (call.verbs[i - 1].startsWith('CreateControl') &&
            (meta[i - 1].result?.trim() ?? '').isNotEmpty)
          meta[i - 1].result!.trim(): (verbNamedArgs(call, i)['#1'] ?? '')
              .trim(),
    };
    final out = <String, String>{};
    for (var i = 1; i <= call.verbs.length && i <= meta.length; i++) {
      if (call.verbs[i - 1] != topNodeKeyProp) continue;
      final m = meta[i - 1];
      if ((m.result?.trim() ?? '').isNotEmpty) continue; // a read
      String? value;
      for (final (n, v) in verbArgs(call, i)) {
        if (n.trim().startsWith('_')) continue;
        value = v;
        break;
      }
      if (value == null || value.trim().isEmpty) continue;
      final tok = m.objValue.trim();
      String? sh;
      if (tok.isEmpty) {
        sh = created[m.obj.trim()];
      } else if (kinds[tok] == 'tree') {
        sh = tok;
      } else if (_ea.shellAlias[tok] case final a?
          when kinds[a] == 'tree') {
        sh = a;
      }
      sh ??= _treeFilledBy(call, tok);
      if (sh == null || sh.isEmpty) continue;
      out[sh] = value;
      noteTreeTopNode(sh, value);
    }
    return out;
  }

  /// The tree shell a control / object token of a tree property verb
  /// names (`AssignProperty2(…, 43, 'ExpandedKeys')`): the shell itself,
  /// the responder's alias of the handle, else — the handle unknown, as in
  /// a replayed recording that keeps the recording client's handles — the
  /// screen's ONE tree (none guessed among several).
  String? _treeShellOfToken(String token) {
    final t = token.trim();
    final ts = trees;
    if (ts.containsKey(t)) return t;
    final a = _ea.shellAlias[t];
    if (a != null && ts.containsKey(a)) return a;
    // a tree control whose nodes this very flush pushes: the fill's
    // tables are folded with the frame, after its answer (SE80's object
    // list, a recorded session srv[14]: AddR3Table on 43, then
    // AssignProperty2(47, data, 43, ExpandedKeys) — the root `1` open)
    if (a != null && _layoutState.registry.kinds()[a] == 'tree') return a;
    if (a != null && _isShellId(a)) return null; // another control's
    return ts.length == 1 ? ts.keys.single : null;
  }

  /// Fold the server's own expansion of tree nodes: `AssignProperty2(<dp>,
  /// 'data', <tree>, 'ExpandedKeys')` with the node-key table it pushed —
  /// the root `1` of SE80's object list at its fill (a recorded session
  /// subnode_dblclick srv[26]), each expanded folder after its children
  /// (srv[48] `4`, …). The OCX then holds those nodes open: the
  /// `ExpandedKeys` read-back lists them with the user's own (gui[21]
  /// `{1}` before any click, gui[67] `{1, 4, 5, 6, 8}`).
  void _foldTreeKeyPushes(FlushCall call, Uint8List value) {
    // a fill in a queue that REGISTERS cached props is answered by the
    // registration report (the responder's, [_editorFlushReport] returns
    // early): the filled trees' changed TopNodeKey rides it — the one
    // registered in this queue with the first node, not "" (the
    // responder's default), one registered before when it moved. The real
    // GUI's creation answers of the DBA cockpit's navigation tree report
    // " 1009-", then " 100" (a recorded session
    // realgui; tree_event_windows_xml_test). A queue registering nothing
    // reports through [_treeTopNodeReports].
    if (answerDialect == GuiDialect.windows &&
        call.cachedProps.isNotEmpty &&
        call.verbs.any(_treeFillVerbs.contains)) {
      final cachedAll = _canvasState.tracker.cachedProps;
      final puts = _topNodePutsOf(call);
      for (final sh in {...trees.keys, ...puts.keys}) {
        final here = call.cachedProps.contains((sh, topNodeKeyProp));
        if (!here && !(cachedAll[sh]?.contains(topNodeKeyProp) ?? false)) {
          continue;
        }
        // the node the same queue selected (`ABAPSelNodeKey(=…)`): the OCX
        // scrolls it into view of the not yet laid out control — the real
        // GUI's answer to a recorded session srv[14] (gui[7]) reports
        // TopNodeKey HDEFAULTS, the server's selection, and its next event
        // the first node FORMNAME (gui[12]); else the first node
        final sel = _selectionPutOf(call, sh);
        final top = puts[sh] ?? sel ?? _treeTopNodeKey(sh);
        if (top == null || top.trim().isEmpty) continue;
        // (the server's own put is reported back whatever it held: the
        // tracker took the put for the server's value)
        if (!here) {
          if (!puts.containsKey(sh) &&
              _ctxMenu.tracker.changed(sh, [(topNodeKeyProp, top)]).isEmpty) {
            continue;
          }
          call.cachedProps.add((sh, topNodeKeyProp));
        }
        call.setProps[(sh, topNodeKeyProp)] = top;
        _ctxMenu.tracker.noteFlushed(sh, [(topNodeKeyProp, top)]);
      }
    }
    _foldTreeExpansionVerbs(call);
    if (!call.verbs.contains('AssignProperty2')) return;
    DpCache? own;
    for (final b in dpPushBindings(call)) {
      if (b.role != expandedKeysProp || b.attach != null) continue;
      final sh = b.shell ??
          _treeShellOfToken(b.owner ?? '') ??
          _treeFilledBy(call, b.owner ?? '');
      if (sh == null) continue;
      final nodes = trees[sh]?.nodes ?? const <String, SapTreeNode>{};
      for (final u in b.urls) {
        final seg =
            (own ??= DpCache()..ingestValue(value)).byUrl[u] ??
            _ea.dpCache.byUrl[u];
        if (seg == null) continue;
        for (final k in nodeKeyTableKeys(seg)) {
          // the tree's own NODE_KEY spelling (the table pads to 12)
          final key = nodes.containsKey(k)
              ? k
              : nodes.keys.firstWhere(
                  (n) => n.trim() == k.trim(),
                  orElse: () => k,
                );
          noteTreeExpansion(sh, key, open: true);
        }
      }
    }
  }

  /// The tree the same [call] fills through object [owner] — its
  /// `AddR3Table` / `AddItemTable` pushes on that token, whose tables the
  /// layout fold bound to their shell (or, unbound, the newest live tree
  /// the session holds them under, as [trees] does) — for a handle the
  /// session never minted (a replay keeps the recording client's: SE80's
  /// `43` in a recorded session srv[14]). Null when the call fills no
  /// tree through it.
  ///
  /// An EMPTY [owner] (a verb whose object row the parse could not read —
  /// the /AIF/IFMON launch batch's `ABAPExpandNodes(1, 1-)`, a recorded session
  /// wingui_s4b_aif srv[220] verb 978) is the tree the call fills at all.
  String? _treeFilledBy(FlushCall call, String owner) {
    final o = owner.trim();
    final st = _layoutState;
    var fills = false;
    for (final b in dpPushBindings(call)) {
      if (b.attach == null) continue;
      if (o.isNotEmpty && b.owner?.trim() != o) continue;
      if (b.role != 'R3Table' && b.role != 'ItemTable') continue;
      fills = true;
      for (final u in b.urls) {
        final sh = st.treeUrlShell[u];
        if (sh != null) return sh;
      }
    }
    if (!fills) return null;
    for (final c in _ea.createdControls.reversed) {
      if (controlKind(c.cls) == 'tree' && _onScreen(c.handle)) return c.handle;
    }
    return null;
  }

  /// Fold the server's own expansion VERBS of tree nodes — what the OCX
  /// then holds open (the `ExpandedKeys` read-back reports it, the view
  /// draws it): `ABAPExpandNodes(<key>, <level>)` (CL_TREE_CONTROL_BASE
  /// expand_node / expand_nodes; the DBA cockpit's navigation tree opens
  /// its "Statut actuel" `100` alone — a recorded session
  /// srv[21] verb 168, a recorded session srv[24] — after
  /// the step-32 read-back answered empty; the Easy Access menu `Favo` and
  /// `Root`; a re-entered cockpit screen restores the user's folders,
  /// srv[84] / srv[116], level `1-`), `ABAPExpandAll` (every node the tree
  /// holds children of: a recorded session srv[25]),
  /// `ABAPCollapseSubTree(<key>)` (the node and its subtree) and
  /// `ABAPCollapseAll`. A folder the server did not expand is closed —
  /// the four EXPANDER folders beside `100` (Performance, Configuration,
  /// Jobs, Diagnostic) wait for their 18 EXPANDNOCHILDREN. The verb's
  /// object is the tree's handle ([_treeShellOfToken]).
  void _foldTreeExpansionVerbs(FlushCall call) {
    const verbs = {
      'ABAPExpandNodes',
      'ABAPExpandAll',
      'ABAPCollapseSubTree',
      'ABAPCollapseAll',
    };
    if (!call.verbs.any(verbs.contains)) return;
    final meta = verbMeta(call);
    for (var i = 1; i <= call.verbs.length && i <= meta.length; i++) {
      final verb = call.verbs[i - 1];
      if (!verbs.contains(verb)) continue;
      final tok = meta[i - 1].objValue;
      final sh = (tok.trim().isEmpty ? null : _treeShellOfToken(tok)) ??
          _treeFilledBy(call, tok);
      if (sh == null) continue;
      final tree = trees[sh];
      String own(String k) {
        final nodes = tree?.nodes;
        if (nodes == null || nodes.containsKey(k)) return k;
        for (final n in nodes.keys) {
          if (n.trim() == k.trim()) return n;
        }
        return k;
      }

      final key = (verbNamedArgs(call, i)['#1'] ?? '').trim();
      switch (verb) {
        case 'ABAPExpandNodes':
          if (key.isEmpty) break;
          noteTreeExpansion(sh, own(key), open: true);
          // a level count n > 1 (expand_node level_count: the levels shown
          // below the node — 0 / 1 the node's own children, `1-` the
          // cockpit's restore of single folders) opens the loaded folders
          // n - 1 levels further down
          final level = int.tryParse(
                (verbNamedArgs(call, i)['#2'] ?? '').trim(),
              ) ??
              0;
          void open(SapTreeNode m, int depth) {
            if (depth >= level) return;
            for (final c in m.children) {
              if (c.children.isEmpty) continue;
              noteTreeExpansion(sh, c.key, open: true);
              open(c, depth + 1);
            }
          }

          final n = tree?.nodes[own(key)];
          if (n != null && level > 1) open(n, 1);
        case 'ABAPExpandAll':
          for (final n in tree?.nodes.values ?? const <SapTreeNode>[]) {
            if (n.children.isNotEmpty) noteTreeExpansion(sh, n.key, open: true);
          }
        case 'ABAPCollapseSubTree':
          final n = tree?.nodes[own(key)];
          void close(SapTreeNode m) {
            noteTreeExpansion(sh, m.key, open: false);
            m.children.forEach(close);
          }

          if (n != null) {
            close(n);
          } else if (key.isNotEmpty) {
            noteTreeExpansion(sh, key, open: false);
          }
        case 'ABAPCollapseAll':
          _expandedKeys[sh]?.clear();
      }
    }
  }

  /// The keys of tree [shell] the session holds expanded — the server's
  /// expansion ([_foldTreeExpansionVerbs], its `ExpandedKeys` pushes) and
  /// the user's own opens and closes ([noteTreeExpansion]) — each in the
  /// tree's own NODE_KEY spelling where the tree holds it. Empty for a tree
  /// nothing expanded: a folder is open only when the server or the user
  /// opened it (an EXPANDER folder is closed until its 18 brings the
  /// children).
  Set<String> treeExpandedKeys(String shell) {
    final keys = _expandedKeys[shell];
    if (keys == null || keys.isEmpty) return const {};
    final nodes = trees[shell]?.nodes ?? const <String, SapTreeNode>{};
    final byTrim = <String, String>{
      for (final k in nodes.keys) k.trim(): k,
    };
    return {
      for (final k in keys) nodes.containsKey(k) ? k : (byTrim[k.trim()] ?? k),
    };
  }

  /// The node of tree [shell] [call] selects by a property put
  /// `ABAPSelNodeKey(=<key>)` (a recorded session srv[14] verb 127
  /// `HDEFAULTS`) — the last one naming a node the tree holds; null when
  /// it puts none.
  String? _selectionPutOf(FlushCall call, String shell) {
    final nodes = trees[shell]?.nodes;
    if (nodes == null || nodes.isEmpty) return null;
    String? out;
    for (var i = 1; i <= call.verbs.length; i++) {
      if (call.verbs[i - 1] != selNodeKeyProp) continue;
      for (final (n, v) in verbArgs(call, i)) {
        if (n.trim().startsWith('_')) continue;
        if (nodes.containsKey(v)) {
          out = v;
        } else {
          for (final k in nodes.keys) {
            if (k.trim() == v.trim() && v.trim().isNotEmpty) out = k;
          }
        }
      }
    }
    return out;
  }

  /// [keys] of tree [shell] in the tree's display order (a pre-order walk
  /// of its roots) — the order the OCX reads its `ExpandedKeys` /
  /// `SelectionKeys` back in (a recorded session gui[67]
  /// `1, 4, 5, 6, 8` for the expansions 1, 4, 5, 8, 6); keys the tree does
  /// not hold are dropped.
  List<String> _inTreeOrder(String shell, List<String> keys) {
    final t = trees[shell];
    if (t == null || t.nodes.isEmpty) return keys;
    // (a key the server's verb named unpadded — `ABAPExpandNodes(100, 0)`
    // — is the tree's own ` 100`)
    final want = {for (final k in keys) k.trim()};
    final out = <String>[];
    void walk(SapTreeNode n) {
      if (want.contains(n.key.trim())) out.add(n.key);
      for (final c in n.children) {
        walk(c);
      }
    }

    for (final r in t.roots) {
      walk(r);
    }
    return out;
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
    final picked = selects
        ? _ctxSelectionDelta(shell, nodeKey, itemName, activation: true)
        : const <(String, String)>[];
    // the view's first node when the server does not hold it (the tree
    // scrolled: a recorded session gui[61] `%_GC 152 18`
    // + 152 {TopNodeKey = 15}); between the item key and the item name,
    // the OCX's order of the ITEM request's selection (sfp gui[12])
    final top = _treeTopNodeDelta(shell);
    final at = picked.indexWhere((p) => p.$1 == selItemNameProp);
    final selection = top == null
        ? picked
        : at < 0
        ? [...picked, top]
        : [...picked.sublist(0, at), top, ...picked.sublist(at)];
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

  static const Set<String> _treeFillVerbs = {
    'AddR3Table',
    'AddItemTable',
    'UpdateR3Table',
  };

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
    var assigned = const <HeaderNamesAssignment>[];
    if (call.verbs.contains('AssignProperty2')) {
      DpCache? own;
      Uint8List? segment(String url) =>
          (own ??= DpCache()..ingestValue(value)).byUrl[url] ??
          _ea.dpCache.byUrl[url];
      assigned = headerNamesAssignments(call, segment);
      for (final a in assigned) {
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
    _foldTreeColumnCall(call, assigned);
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

/// Per window: column tree -> its columns ([SapSessionTree.treeColumns]).
final Expando<Map<String, SapTreeColumns>> _treeColumnsOf = Expando(
  'treeColumns',
);

/// Per window: tree shell -> the first node the user's view shows
/// ([SapSessionTree.noteTreeTopNode]).
final Expando<Map<String, String>> _treeTopNodes = Expando('treeTopNodes');
