part of 'sap_session.dart';

/// The designer-canvas side of a [SapSession]: the net-plan / join-designer
/// canvases of the current screen (read side, sap_canvas.dart) and the two
/// recorded gestures on them — a tree row dropped on the canvas and a
/// node -> node link draw (canvas_actions.dart, dragdrop_service.dart).
///
/// Clicks: a DOUBLE click on a table or row is ICDataFlow's
/// OnLeftButtonDblClk `%_GC <shell> 32` ([canvasDoubleClick]); a SINGLE
/// click is wire-silent on every recorded canvas ([canvasClick]).
///
/// Node MOVE: no real-GUI capture records one. ICDataFlow.ocx's event
/// table names `OnObjectMoved` (a recorded session DECODE §4) and
/// the control registers events 2, 32, 2048, 16384, 32768, 262144, 4194304,
/// 16777216 and 134217728 besides the link commit, but which of them a move
/// fires and with which PARAMs is not on any wire — so no moveCanvasNode.
extension SapSessionCanvas on SapSession {
  _CanvasState get _canvasState => _canvasStates[_w] ??= _CanvasState();

  String? _aliasOf(String owner) => _ea.shellAlias[owner];
  bool _isLiveShell(String shell) => !_ea.destroyedControls.contains(shell);

  /// The designer canvases of the current full-screen dynpro (under a
  /// popup: of the screen beneath it), in first-push order; empty when it
  /// holds none. Like a grid, a canvas's pushes ride the OLE queue its
  /// screen's PBO flushes BEFORE the paint, so a canvas binds to the dynpro
  /// the next paint names; later pushes (a link draw's LINKS delta, a
  /// table re-push) update it in place.
  List<SapCanvasModel> get canvases {
    final st = _canvasState;
    final s = (screen?.modalLevel ?? 0) > 0 ? baseScreen : screen;
    if (s == null || s.modalLevel > 0 || s.program == null) return const [];
    return [
      for (final e in st.bound.entries)
        if (e.value.$1 == s.program &&
            e.value.$2 == s.dynpro &&
            _onScreen(e.key))
          if (st.tracker.build(e.key, shellOf: _aliasOf, isLive: _isLiveShell)
              case final m?)
            m,
    ];
  }

  /// Drop the tree row [sourceKey] of tree [sourceShell] on the canvas
  /// [targetShell], over the canvas object [targetObjId] at pixel ([x],
  /// [y]) of the control — as the real SAP GUI for Windows does it
  /// (a recorded session): the bare GuiService event
  /// `%_GS <target> 15` (`SHELLEVENT="X"`, no PARAM; the dragged-from tree
  /// is the focused shell), then the server's SAPGUIService.DragDrop.1 poll
  /// answered from the armed drop — flavors (the source row's DRAGDROPID
  /// drag flavors the canvas's `DragDropHandle` accepts, from the
  /// X-SAPDDBEHAV pushes), shells, Effect 2, the source bag (a
  /// multi-select tree: `NOITEM, MULTISEL, COUNT, KEY1`; a single-select
  /// one — it registered `ABAPSelNodeKey` — `KEY, NOITEM` with the key
  /// flushed in the event frame) and the target bag `OBJID, XPOS, YPOS`.
  /// The server answers with information popups (RSNPG_TEST_NETPLAN1:
  /// "Noeud … déplacé dans la table", then "Drop-complete pour noeud …") —
  /// no canvas re-push; the returned turn ends on the first popup.
  ///
  /// [sourceKey] is the tree's NODE_KEY (its own padded string, or the
  /// same key trimmed). [targetObjId] is required: every recorded canvas
  /// drop answers the object under the pointer, a drop on the empty canvas
  /// is not on any capture. Refused (nothing sent) when the target did not
  /// register the drop event or the object id is not one of the canvas's.
  Future<List<Uint8List>> dropOnCanvas({
    required String sourceShell,
    required String sourceKey,
    required String targetShell,
    String? targetObjId,
    required int x,
    required int y,
  }) async {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError(
        'canvas drag & drop is built for the Windows dialect only',
      );
    }
    final st = _canvasState;
    final t = st.tracker;
    final target = targetShell.trim(), source = sourceShell.trim();
    final regs = t.registeredEvents[target];
    if (regs != null && !regs.contains(canvasDropEvent)) {
      throw StateError(
        'shell $target did not register the drop event '
        '$canvasDropEvent (registered: ${regs.toList()..sort()}) — '
        'nothing sent',
      );
    }
    final targetCls = t.controls[target]?.cls ?? '';
    if (!isCanvasDataClass(targetCls)) {
      throw StateError(
        'shell $target is ${targetCls.isEmpty ? 'no control '
                  'of this session' : 'a $targetCls'}, not a designer canvas '
        '(SAP.BWAdapter.1) — nothing sent',
      );
    }
    final obj = targetObjId?.trim() ?? '';
    if (obj.isEmpty) {
      throw ArgumentError(
        'a canvas drop needs the canvas object it lands '
        'on (targetObjId) — a drop on the empty canvas is not recorded',
      );
    }
    final model = t.build(target, shellOf: _aliasOf, isLive: _isLiveShell);
    if (model != null && model.node(obj) == null) {
      throw ArgumentError(
        '$obj is not an object id of canvas $target — '
        'refused, nothing sent',
      );
    }
    // the dragged row's key in the tree's own wire form
    final rows = t.treeRowsOf(source, shellOf: _aliasOf);
    final known = rows.isEmpty ? t.allTreeRows : rows;
    var key = sourceKey;
    if (!known.containsKey(key)) {
      final m = known.keys.where((k) => k.trim() == sourceKey.trim()).toList();
      if (m.length == 1) key = m.single;
    }
    final srcHandle = int.tryParse(known[key] ?? '');
    final tgtHandle = t.dragDropHandleOf(
      target,
      shellOf: _aliasOf,
      isLive: _isLiveShell,
    );
    final flavors = dropFlavors(
      t.behaviours.values.expand((r) => r),
      sourceHandle: srcHandle,
      targetHandle: tgtHandle,
    );
    // single-select: the tree registered ABAPSelNodeKey (the reference client's
    // drag_drop rule); a tree that registered cached props without it is
    // multi-select (shell 116: TopNodeKey only)
    final cached = t.cachedProps[source];
    final single = cached == null || cached.contains('ABAPSelNodeKey');
    final controls = <String, List<(String, String)>>{
      if (single && cached != null) source: [('ABAPSelNodeKey', key)],
    };
    armDrop(
      _ea,
      PendingDrop(
        sourceShell: source,
        targetShell: target,
        flavors: flavors,
        sourceProps: treeSourceProps([key], multi: !single),
        targetProps: canvasTargetProps(obj, x, y),
        effect: canvasDropEffect,
      ),
    );
    try {
      return await _act(
        canvasDropItems(
          ctx,
          targetShell: target,
          sourceShell: source,
          controls: controls,
          sourcePath: _hostedSourcePath(target),
        ),
        dialectReady: true,
      );
    } finally {
      st.lastDrop = disarmDrop(_ea);
    }
  }

  /// What the server read off the last [dropOnCanvas] (flavors, bags…).
  PendingDrop? get lastCanvasDrop => _canvasState.lastDrop;

  /// Draw a link from canvas object [from] to [to] — the ICDataFlow
  /// `OnNewLinkCreated` commit as the real SAP GUI for Windows sends it
  /// (a recorded session gui[8]/[11]): ONE event `%_GC
  /// <c.eventShell> 1048576` with PARAMs `(2147483647, from.id, to.id)`,
  /// no drag & drop poll, no pixel. The server answers with an information
  /// popup ("Lien généré"); once it is dismissed, a LINKS push carrying the
  /// single new link (`63 | 3 | 15 | …`) arrives and [canvases] shows it.
  Future<List<Uint8List>> connectCanvasNodes(
    SapCanvasModel c,
    CanvasNode from,
    CanvasNode to,
  ) {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError(
        'canvas link draws are built for the Windows dialect only',
      );
    }
    final shell = c.eventShell;
    if (shell == null) {
      throw StateError(
        'canvas ${c.shell}: no shell registered the link '
        'event $canvasConnectEvent (OnNewLinkCreated) — nothing to draw on',
      );
    }
    for (final n in [from, to]) {
      if (c.node(n.id) == null) {
        throw ArgumentError(
          '${n.id} is not an object id of canvas '
          '${c.shell} — refused, nothing sent',
        );
      }
    }
    _ea.recordEvent(shell, {0: canvasNewLinkPlaceholder, 1: from.id, 2: to.id});
    return _act(
      canvasConnectItems(
        ctx,
        shell: shell,
        srcObjId: from.id,
        dstObjId: to.id,
        sourcePath: _hostedSourcePath(shell),
      ),
      dialectReady: true,
    );
  }

  /// Double-click object [objectId] of canvas [c] — a table (its header)
  /// or one of its rows — as the real SAP GUI for Windows does it
  /// (a recorded session gui[51] / [52], a recorded session
  /// gui[63]): ONE event `%_GC <shell> 32` (OnLeftButtonDblClk) on the
  /// ICDataFlow shell that registered it, PARAMs `(table, -1, -1, 2, x, y)`
  /// on a header, `(table, row, column, 3, x, y)` on a row; the canvas takes
  /// the focus (`9/18`). [column] = the clicked cell's `Tables` column
  /// (default: the row's first text cell — gui[52]'s MEINS field name is
  /// its column 2, after the key-icon column); [x] / [y] = the pointer in
  /// the control (pixels; no recorded handler reads them). The server
  /// answers as the program wants (SQ02: the field documentation; SQVI:
  /// the field-info popup; the header: nothing).
  ///
  /// Refused (nothing sent): a link ([canvasLinkDoubleClickEvent], on no
  /// capture) — UnsupportedError; no shell of the canvas registered 32 —
  /// StateError; an id that is none of the canvas's — ArgumentError.
  Future<List<Uint8List>> canvasDoubleClick(
    SapCanvasModel c,
    String objectId, {
    int? column,
    int x = 0,
    int y = 0,
  }) {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError(
        'canvas clicks are built for the Windows dialect only',
      );
    }
    final id = objectId.trim();
    final n = c.node(id);
    if (n == null) {
      if (c.links.any((l) => l.id.trim() == id)) {
        throw UnsupportedError(
          'a double click on link $id would be OnLinkLeftButtonDblClk '
          '($canvasLinkDoubleClickEvent) — its PARAMs are on no capture, '
          'nothing sent',
        );
      }
      throw ArgumentError(
        '"$objectId" is no object id of canvas ${c.shell} — refused, '
        'nothing sent',
      );
    }
    final shell = _canvasShellFor(c, canvasDoubleClickEvent);
    if (shell == null) {
      throw StateError(
        'canvas ${c.shell}: no shell registered the double click '
        '$canvasDoubleClickEvent (OnLeftButtonDblClk) — nothing sent',
      );
    }
    final isRow = n.type != 'table' && n.parent != null;
    final params = canvasDoubleClickParams(
      tableId: isRow ? n.parent! : n.id,
      rowId: isRow ? n.id : null,
      column: column ?? canvasTextColumn(n),
      x: x,
      y: y,
    );
    _ea.recordEvent(shell, {for (final (i, p) in params.indexed) i: p});
    return _act(
      canvasDoubleClickItems(
        ctx,
        shell: shell,
        params: params,
        sourcePath: _hostedSourcePath(shell),
      ),
      dialectReady: true,
    );
  }

  /// Single-click object [objectId] of canvas [c] (select it). On every
  /// recorded canvas this is wire-silent: the SQVI / SQ02 canvases
  /// register no selection event and none of their left clicks sends
  /// anything (a recorded session, a recorded session) — the
  /// returned list is then empty and nothing went out. A canvas whose
  /// shell registered OnObjectSelected ([canvasObjectSelectedEvent]:
  /// RSNPG_TEST_NETPLAN1's 122) would be told by the real GUI, with
  /// PARAMs no capture shows — refused with an UnsupportedError, nothing
  /// sent (the selection stays the client's).
  Future<List<Uint8List>> canvasClick(SapCanvasModel c, String objectId) {
    final id = objectId.trim();
    if (c.node(id) == null && !c.links.any((l) => l.id.trim() == id)) {
      throw ArgumentError(
        '"$objectId" is no object id of canvas ${c.shell} — refused, '
        'nothing sent',
      );
    }
    final shell = _canvasShellFor(c, canvasObjectSelectedEvent);
    if (shell != null) {
      throw UnsupportedError(
        'shell $shell registered OnObjectSelected '
        '($canvasObjectSelectedEvent) — its PARAMs are on no capture, '
        'nothing sent',
      );
    }
    return Future.value(const <Uint8List>[]);
  }

  /// The shell of canvas [c] (its ICDataFlow sibling first) that
  /// registered [eventId]; null when none did.
  String? _canvasShellFor(SapCanvasModel c, int eventId) {
    final t = _canvasState.tracker;
    for (final sh in [?c.eventShell, c.shell]) {
      if (t.registeredEvents[sh]?.contains(eventId) ?? false) return sh;
    }
    return null;
  }

  // --- hooks (sap_session.dart) ---------------------------------------------

  /// Fold one complete flush call's canvas facts.
  void _ingestCanvasCall(Uint8List value, [FlushCall? parsed]) {
    try {
      if (_canvasState.tracker.foldCall(value, parsed: parsed)) {
        _canvasState.dirty = true;
      }
    } catch (e) {
      _noteIngestFailure('canvas ingest', e);
    }
  }

  /// Bind canvases whose pushes arrived since the last paint to the screen
  /// a paint in [frames] names; forget them when the base dynpro changes.
  void _foldCanvases(List<Uint8List> frames) {
    final st = _canvasState;
    if (st.dirty && _paintsProgram(frames)) {
      final s = screen;
      if (s != null && s.program != null && s.modalLevel == 0) {
        st.dirty = false;
        for (final sh in st.tracker.canvasShells(
          shellOf: _aliasOf,
          isLive: _isLiveShell,
        )) {
          final b = st.bound[sh];
          if (b == null || b.$1 != s.program || b.$2 != s.dynpro) {
            st.bound[sh] = (s.program, s.dynpro);
          }
        }
      }
    }
    final base = (screen?.modalLevel ?? 0) > 0 ? baseScreen : screen;
    if (base == null || base.program == null) return;
    st.bound.removeWhere(
      (sh, b) => b.$1 != base.program || b.$2 != base.dynpro,
    );
  }
}

final Expando<_CanvasState> _canvasStates = Expando('canvasState');

class _CanvasState {
  final SapCanvasTracker tracker = SapCanvasTracker();

  /// canvas shell -> (program, dynpro) it was painted with
  final Map<String, (String?, String?)> bound = {};

  /// canvas pushes arrived that no paint bound yet
  bool dirty = false;
  PendingDrop? lastDrop;
}
