part of 'sap_session.dart';

/// The window composition side of a [SapSession]: the control registry the
/// layout reads (screen_layout.dart — a port of the reference client screenshot
/// renderer's layout decisions), every live tree / grid by shell, and the
/// current base window's [regions].
extension SapSessionLayout on SapSession {
  _LayoutState get _layoutState =>
      _layoutStates[_w] ??= _LayoutState(_modes.home);

  /// A new window keeps the session's layout knobs ([layoutRoundEnabled],
  /// [dockFraction]); everything else of its layout starts fresh.
  void _inheritLayoutKnobs(_WindowState from, _WindowState to) {
    final f = _layoutStates[from];
    if (f == null) return;
    _layoutStates[to] = _LayoutState(_modes.home)
      ..layoutRoundEnabled = f.layoutRoundEnabled
      ..dockFraction = f.dockFraction;
  }

  int? get _actionStartStep => _layoutState.actionStartStep;
  set _actionStartStep(int? v) => _layoutState.actionStartStep = v;
  int? get _progSinceStep => _layoutState.progSinceStep;
  set _progSinceStep(int? v) => _layoutState.progSinceStep = v;

  bool _live(String shell) => !_ea.destroyedControls.contains(shell);

  /// Whether [shell] was created in a LIVE internal mode that is not the
  /// current one (imode_scope.dart [IModeScope.inOtherIMode], the jar's
  /// `checkShellIModeContext` false; reference client shell_in_other_imode): the
  /// control is HIDDEN but kept — its content, bindings and registry facts
  /// stay, and it is on screen again when its imode is current again. The
  /// real GUI's returns re-send nothing for it (a recorded session
  /// srv_to_gui_scrubbed: SIMG's IMG tree 120, imode F, hidden under the
  /// IMG activity's imode G at #24 and back at #33 with no CreateControl /
  /// R3Table / SetDataFromUrl; the Easy Access menu, imode D, under SPRO /
  /// SM59 / their nested ALV and back at #38 / #88).
  bool shellInOtherIMode(String shell) {
    final im = _layoutState.imodes;
    if (im.inOtherIMode(shell)) return true;
    final a = _ea.shellAlias[shell];
    return a != null && a != shell && im.inOtherIMode(a);
  }

  /// Live AND of the current internal mode: the controls the screen on
  /// display may show or address.
  bool _onScreen(String shell) => _live(shell) && !shellInOtherIMode(shell);

  /// The composition of the current base window (under a popup: of the
  /// screen beneath it) — the dynpro area, the docked panes and their
  /// hosted controls, the dynpro's custom-control regions with the reference client
  /// ladder rung each resolves to. Empty before the first paint.
  /// The base window's AREASIZE window (16/12/7: rows, cols) — the frame
  /// [regions] are laid out in; it stays put while screens change inside
  /// it. Null before the first paint that carries one.
  (int, int)? get windowExtent => _layoutState.window;

  List<ScreenRegion> get regions => _composeBase();

  /// Every sash of the splitters the current base window composes, free
  /// ones and fixed ones ([SplitterSash]: its line and the extents of the
  /// cells it divides, in window cells) — what the client draws a grip on
  /// and lets the user drag ([noteSplitterSash]).
  List<SplitterSash> get splitterSashes {
    final out = <SplitterSash>[];
    _composeBase(sashes: out);
    return out;
  }

  List<ScreenRegion> _composeBase({
    List<SplitterSash>? sashes,
    Map<String, CellRect>? boxes,
  }) {
    final s = (screen?.modalLevel ?? 0) > 0 ? baseScreen : screen;
    if (s == null || s.program == null) return const [];
    final st = _layoutState;
    final tables = [
      ..._layoutTables((_) => true),
      // a designer canvas is drawn in its splitter cell like a table (the
      // reference client's sapw_screenshot appends canvas_schematic_tables to
      // grid_tables). Without it the canvas container's R7 placeholder
      // named the ICDataFlow sibling (a recorded session srv[5]:
      // CreateControl 122 ICDATAFLOW + 123 SAP.BWAdapter.1 in cell 120) —
      // "control control, no content channel yet" — and the canvas, bound
      // to 123, was never drawn (live the test system RSNPG_TEST_NETPLAN1, shell 124).
      for (final c in canvases)
        LayoutTable(c.shell, c.nodes.length, canvas: true),
    ];
    final composed = composeScreen(
      st.registry,
      LayoutInputs(
        screen: s,
        window: st.window,
        area: st.area,
        tables: tables,
        chartShells: {for (final c in charts) c.shell},
        graphShells: {
          for (final g in netPlans)
            if (g.shell case final sh?) sh,
        },
        contentShells: st.contentShells,
        editorLines: _editorLines,
        htmlShells: _htmlShells,
        pictureShells: _pictureShells,
        calendarShells: _calendarShells,
        isLive: _onScreen,
        sinceStep: st.baseSinceStep ?? _progSinceStep,
        dockFraction: st.dockFraction,
        splitterHeld: st.sashHeld,
      ),
      sashes: sashes,
      boxesOut: boxes,
    );
    // then the CFW modal dialogs floating over it (the F1 Performance
    // Assistant's toolbar + HTML viewer; sap_session_html.dart)
    return [...composed, ..._cfwDialogRegions];
  }

  /// The composition of the active MODAL window (a popup: the ALV "Tri" /
  /// "Filtre" dialogs, …) in POPUP-relative cells — the same frame its
  /// [ScreenModel] fields use: its dynpro region (the popup's own 16/12/7
  /// pair), then its custom-control regions with the grids / trees its
  /// containers host (CONTAINER2_SORT -> 131 -> grid 132, …), the same
  /// [ScreenRegion] kinds and rungs as [regions]. Only the controls the
  /// popup's own generation created take part (minted at or after the
  /// action that opened it — the covered window's docks and grids stay in
  /// [regions]). Empty without a popup.
  List<ScreenRegion> get modalRegions {
    final s = screen;
    if (s == null || s.modalLevel == 0 || s.program == null) return const [];
    final st = _layoutState;
    final since = st.modalSinceStep;
    if (since == null) return const [];
    final born = {for (final c in st.registry.created) c.shell: c.step};
    bool mine(String sh) => _onScreen(sh) && (born[sh] ?? -1) >= since;
    return composeScreen(
      st.registry,
      LayoutInputs(
        screen: s,
        window: st.modalWindow,
        area: st.modalArea,
        tables: _layoutTables(mine),
        contentShells: st.contentShells.where(mine).toSet(),
        editorLines: {
          for (final e in _editorLines.entries)
            if (mine(e.key)) e.key: e.value,
        },
        htmlShells: _htmlShells.where(mine).toSet(),
        pictureShells: _pictureShells.where(mine).toSet(),
        calendarShells: _calendarShells.where(mine).toSet(),
        isLive: mine,
        sinceStep: since,
        splitterHeld: st.sashHeld,
      ),
    );
  }

  List<LayoutTable> _layoutTables(bool Function(String shell) keep) => [
    for (final e in trees.entries)
      if (keep(e.key)) LayoutTable(e.key, _visibleNodes(e.value), tree: true),
    for (final e in grids.entries)
      if (keep(e.key))
        LayoutTable(e.key, e.value.nonEmptyRowCount),
  ];

  /// After a fold: the step the BASE window's program generation began at
  /// (a popup opening and closing over the same program keeps it — the
  /// ALV grid linked at step 22 must outlive the "Tri" dialog) and the
  /// step the active popup's generation began at.
  void _noteGenerations() {
    final st = _layoutState;
    final b = baseScreen;
    if (b?.program != null && b!.program != st.baseProgram) {
      st
        ..baseProgram = b.program
        ..baseSinceStep = _actionStartStep ?? clockStep;
    }
    final s = screen;
    final key = s != null && s.modalLevel > 0
        ? '${s.modalLevel}:${s.program}/${s.dynpro}'
        : null;
    if (key != null && key != st.modalKey) {
      st.modalSinceStep = _actionStartStep ?? clockStep;
    }
    st.modalKey = key;
  }

  /// Every live tree control's content by shell (the DBA cockpit's
  /// navigation tree beside the dynpro, the Easy Access menu, …). A push
  /// carrying a root node starts that tree afresh; a root-less push (a
  /// folder expansion's children) extends it. [tree] keeps its meaning.
  /// Only the current internal mode's trees are listed ([shellInOtherIMode]).
  Map<String, SapTreeModel> get trees {
    final st = _layoutState;
    final byShell = <String, List<DpTable>>{};
    String? fallback;
    for (final c in _ea.createdControls.reversed) {
      if (controlKind(c.cls) == 'tree' && _live(c.handle)) {
        fallback = c.handle;
        break;
      }
    }
    for (final (url, t) in st.treeTables) {
      final sh = st.treeUrlShell[url] ?? fallback;
      if (sh == null) continue;
      final list = byShell[sh] ??= [];
      // (an update push names nodes the tree holds: no new tree —
      // isTreeUpdateTable)
      final isNodes = t.columns.contains('RELATKEY') && !isTreeUpdateTable(t);
      if (isNodes && t.rows.any((r) => (r['RELATKEY'] ?? '').isEmpty)) {
        list.removeWhere(
          (x) => x.columns.contains('RELATKEY') && !isTreeUpdateTable(x),
        );
      }
      list.add(t);
    }
    // a tree of another live internal mode is hidden, its content kept
    // (the Easy Access menu under a transaction, back on its return)
    final memo = st.treeModels;
    memo.removeWhere((sh, _) => !byShell.containsKey(sh));
    return {
      for (final e in byShell.entries)
        if (_onScreen(e.key)) e.key: _treeModelOf(memo, e.key, e.value),
    };
  }

  /// The model of [shell]'s [tables] — rebuilt only when its tables changed
  /// (the same decoded tables give the same tree; audit #15: every read of
  /// [trees] re-applied every push of every tree).
  SapTreeModel _treeModelOf(
    Map<String, (List<DpTable>, SapTreeModel)> memo,
    String shell,
    List<DpTable> tables,
  ) {
    final hit = memo[shell];
    if (hit != null && _sameTables(hit.$1, tables)) return hit.$2;
    final m = _treeOf(tables);
    memo[shell] = (tables, m);
    return m;
  }

  /// Every live grid control's content by shell, docked panes and
  /// containers included ([grid] stays the full-screen dynpro's grid);
  /// a grid of another live internal mode is hidden, its rows kept.
  Map<String, SapGridModel> get grids => {
    for (final e in _gridAsm.entries)
      if (_onScreen(e.key)) e.key: e.value.build(),
  };

  /// Whether [shell]'s CreateControl parent chain reaches a docking
  /// container (a docked pane's content: the ST04 message grid).
  bool _inDockingPane(String shell) {
    final reg = _layoutState.registry;
    final classes = reg.classes();
    var sh = shell;
    for (var i = 0; i < 16; i++) {
      if ((classes[sh] ?? '').toUpperCase().contains('DOCKING')) return true;
      final p = reg.parents[sh];
      if (p == null) return false;
      sh = p;
    }
    return false;
  }

  void _noteTreeTable(String url, DpTable t) {
    final st = _layoutState;
    st.treeTables.add((url, t));
    if (st.imodes.current case final u?) st.treeUrlIMode[url] = u;
  }

  /// The ABAP internal modes of the main window ([IModeScope]): the live
  /// uuids (server order) and the current one — empty / null before a
  /// frame carried 16/6/31.
  List<String> get liveIModes => _layoutState.imodes.live;
  String? get currentIMode => _layoutState.imodes.current;

  /// The logon's own system (16/6/2 DBNAME, 16/6/3 CPUNAME, 16/6/12
  /// CLIENT of its first frame naming one); null before that frame.
  SystemIdentity? get homeSystem => _modes.home.identity;

  /// The system the active window's latest frames were RELAYED from — an
  /// RFC target painting its remote logon / progress frames over this
  /// connection (imode_scope.dart) — null on the logon's own frames.
  SystemIdentity? get relayedSystem => _w.onRelay ? _w.relayedFrom : null;

  /// The step generation arithmetic runs on (reference client imode_scope
  /// .clock_step): the wire [step], except while the active window sits on
  /// frames relayed from another system — then the last HOME step. Replies
  /// still echo [step].
  int get clockStep => _w.onRelay ? _w.homeStep : step;

  /// Per step-bearing frame (after [step] took its value): advance the
  /// home clock, or hold it on a relayed frame.
  void _noteClock(Uint8List f) {
    final w = _w;
    final relay = _relayFrames[f];
    if (relay == null) {
      if (w.onRelay) {
        _trace(
          'home system again at step $step (relay from '
          '${w.relayedFrom} ended; the step clock resumes)',
        );
      }
      w
        ..homeStep = step
        ..onRelay = false
        ..relayedFrom = null
        ..relayedWall = null;
    } else {
      if (!w.onRelay || w.relayedFrom?.sid != relay.sid) {
        _trace(
          'frame relayed from $relay at its step $step: the step '
          'clock stays at home step ${w.homeStep}',
        );
      }
      w
        ..onRelay = true
        ..relayedFrom = relay;
    }
    _frameClock[f] = clockStep;
  }

  /// The home-clock step [f] was folded at, else [wire].
  int _clockOf(Uint8List f, int wire) => _frameClock[f] ?? wire;

  /// Per received frame, before anything else folds it: the imode facts.
  /// A uuid that leaves IMODEUUIDS2 is the frontend's `delIMode`
  /// (imode_scope.dart): every control its generation created dies here,
  /// locally — the real GUI gets no DestroyWindow for them. Leaving a
  /// transaction (`/n`) ends its imode(s), so its docks, trees, grids and
  /// dock requests go with it (reference client imode_scope.del_imodes, d888b68).
  void _observeIModes(List<Uint8List> frames) {
    final st = _layoutState;
    for (final f in frames) {
      // a materialized stream paint nests the paint's own imode list / step
      if (isStreamCarrier(f)) continue;
      final gone = st.imodes.observe(f);
      if (st.imodes.lastFrameForeign) {
        _relayFrames[f] = st.imodes.relayedFrom!;
        continue;
      }
      // a frame of a window living on ANOTHER system (a remote-logon
      // window): its own clock and imodes, but not this logon's wall
      if (st.imodes.elsewhere case final sys?) _remoteWindowFrames[f] = sys;
      if (gone.isEmpty) continue;
      final dead = st.imodes.takeShellsOf(gone);
      // a tree push that rode the dead imode is no tree content anymore
      // (reference client del_imodes drops the tree memo)
      final urls = {
        for (final e in st.treeUrlIMode.entries)
          if (gone.contains(e.value)) e.key,
        for (final e in st.treeUrlShell.entries)
          if (dead.contains(e.value)) e.key,
      };
      st.treeTables.removeWhere((t) => urls.contains(t.$1));
      urls
        ..forEach(st.treeUrlShell.remove)
        ..forEach(st.treeUrlIMode.remove);
      _ea.dpCache.evict(urls); // the pushes die with their imode
      if (dead.isEmpty) continue;
      for (final sh in dead) {
        _ea.destroyedControls.add(sh);
        _forgetShellState(sh);
        // its tree columns, held sashes and splitter record too
        _purgeShellContent(sh);
        if (_ea.shellAlias[sh] case final a? when a != sh) {
          _ea.destroyedControls.add(a);
        }
        _gridAsm.remove(sh);
      }
      // …and so do the cached pushes of its controls; the registries stay
      // bounded (audit #12)
      _ea
        ..evictDeadPushes()
        ..capControlRegistry();
      st.contentShells.removeAll(dead);
      st.registry.forget(dead);
      // the docks the last layout round reported are gone with them
      st.reportedDocks = null;
      int n(String sh) => int.tryParse(sh) ?? 0;
      final sorted = dead.toList()..sort((a, b) => n(a).compareTo(n(b)));
      _trace(
        'imode ${[for (final u in gone) u.substring(0, 8)].join(', ')} '
        'ended (delIMode): shells ${sorted.join(' ')} destroyed',
      );
    }
  }

  /// Whether the session sends the Windows GUI's `%_GS 0 3` layout round
  /// after a paint whose waves docked or resized a container (default on;
  /// see [_maybeLayoutRound]).
  bool get layoutRoundEnabled => _layoutState.layoutRoundEnabled;

  /// The share of the window width a lone left/right docking pane takes
  /// when the server's first paint lays out only a provisional area: the
  /// pane WE draw, reported in the layout round so the server re-lays out
  /// to it. Default = the operator's remembered sash of
  /// a recorded session gui[15] (16/12/8: area 1141 of a
  /// 1880 px window -> dock 739 / 1880; the same extent its CONTROLS report
  /// gives as 135 300 = 845 of a 2163-unit window). null = a fresh profile:
  /// the dock realizes the server's latest request (1360 / 8 px per col).
  double? get dockFraction => _layoutState.dockFraction;
  set dockFraction(double? v) => _layoutState.dockFraction = v;
  set layoutRoundEnabled(bool v) => _layoutState.layoutRoundEnabled = v;

  /// The docking container (`SAPGUI.DOCKINGCTRL`) whose subtree [shell]
  /// lies in — [shell] itself when it is one — or null: the pane of a
  /// composed window a dock-edge drag resizes ([resizeDock]).
  String? dockOf(String shell) {
    final reg = _layoutState.registry;
    final classes = reg.classes();
    final seen = <String>{};
    String? sh = shell;
    while (sh != null && seen.add(sh)) {
      if ((classes[sh] ?? '').toUpperCase().contains('DOCKING')) return sh;
      sh = reg.parents[sh];
    }
    return null;
  }

  /// [SapSession.resizeDock]
  Future<bool> _resizeDock(String dock, double cols) async {
    final st = _layoutState;
    final w = st.window, a = st.area;
    final side = st.registry.props[dock]?[propDockSide];
    if (w == null || a == null || w.$2 <= 1) {
      _trace('dock $dock resize ignored: no AREASIZE painted');
      return false;
    }
    if (side != '1' && side != '2') {
      _trace('dock $dock resize ignored: not a left / right dock');
      return false;
    }
    final c = cols.round().clamp(1, w.$2 - 1);
    // once per paint: the same extent again before the server answered
    // (its step unchanged) owes nothing new
    final mark = '$dock:$c@$step';
    if (st.draggedRound == mark) {
      _trace('dock $dock resize: already reported at step $step');
      return false;
    }
    st
      ..dockFraction = c / w.$2
      ..reportedDocks = null; // the realized extent changed: owed again
    st.registry.draggedDelta[dock] = w.$2 - a.$2;
    // the dynpro area every later round reports (16/12/8) is the window
    // less the dragged pane until the server re-lays out (the reference client's
    // docked_layout.realized_area_px: the user's drag wins on its axis)
    final sideDocks = [
      for (final d in _shownDocks())
        if (st.registry.props[d]?[propDockSide] case '1' || '2') d,
    ];
    if (sideDocks.length == 1 && sideDocks.single == dock) {
      ctx.dockedCells = (ctx.dockedCells.$1, c);
    }
    _trace('dock $dock dragged to $c of ${w.$2} cols');
    String? refusal() {
      if (answerDialect != GuiDialect.windows) return 'not Windows';
      if (state != SessionState.ready && !offlineReplay) {
        return 'the logon is not live (${state.name})';
      }
      final s = screen;
      if (s == null || s.program == null) return 'no screen painted';
      if (s.modalLevel > 0 || ctx.modalNo != 0) return 'a popup is up';
      if (_staged.isNotEmpty) return 'typed values are staged';
      return null;
    }

    if (busy) {
      _trace('dock round owed to the next paint: an action is running');
      return false;
    }
    if (refusal() case final why?) {
      _trace('dock round owed to the next paint: $why');
      return false;
    }
    return _exclusive('dock resize', () async {
      if (refusal() case final why?) {
        _trace('dock round owed to the next paint: $why');
        return false;
      }
      st.reportedDocks = null;
      await _maybeLayoutRound();
      // the round stamps the docks it reported
      if (st.reportedDocks == null) return false;
      st.draggedRound = mark;
      return true;
    });
  }

  /// The real Windows GUI reports the layout it realized for a docked
  /// screen in its own `%_GS 0 3` round right after the paint
  /// (a recorded session gui[15], step 37 after the
  /// DB50/0100 paint srv[23]); the server answers the queue it owes
  /// (srv[24], RegisterEvent) and repaints with the AREASIZE re-laid out
  /// to the reported area (srv[25]: 34 x 163 of 38 x 268). Sent once per
  /// change of the docking containers' requested extents, on the main
  /// window, Windows dialect only. The reported extents are what [regions]
  /// draws: a dock realizes the server's latest request (the fresh-profile
  /// rule, screen_layout._dockedBoxes), the area is the rest of the window,
  /// scaled to the same 16/12/8 window pixels every other round carries.
  ///
  /// Owed only after a wave that [painted] (reference client raw_settle
  /// ._emit_render_trigger, Windows profile, 37e6240) and only when the area
  /// we draw departs from the painted one — after a paint whose area
  /// already reflects the docks' latest requests nothing is sent
  /// (a recorded session: the next client frame is the
  /// user's own F4), and no Java "control-ready" trigger frame either (the
  /// session has none).
  Future<void> _maybeLayoutRound({bool painted = true}) async {
    final st = _layoutState;
    void skip(String why) => _trace('layout round skipped: $why');
    if (!st.layoutRoundEnabled) return skip('disabled');
    if (answerDialect != GuiDialect.windows) return skip('not Windows');
    if (!painted) return skip('the wave has not painted');
    final s = screen;
    final scroll = st.scrollInfos2;
    if (s == null || s.program == null) return skip('no paint');
    if (s.modalLevel > 0) return skip('a popup is up');
    if (scroll == null) return skip('no SCROLL_INFOS2 painted');
    final reg = st.registry;
    final docks = _shownDocks();
    if (docks.isEmpty) {
      st.reportedDocks = null; // the docks a round reported are gone
      return skip('no docking container shown');
    }
    final sig = [
      for (final d in docks)
        [
          d,
          for (final p in const [propDockSide, propControlWidth, propControlHeight, propVisible])
            reg.props[d]?[p] ?? '',
        ].join(':'),
    ].join(';');
    if (sig == st.reportedDocks) {
      return skip('already reported for these dock requests ($sig)');
    }

    // owed only when the area we draw is not the server's AREASIZE area:
    // the DB50 overview paints a provisional 34 x 262 (6 cols = the dock's
    // first request, 50 px) — the real GUI reports (gui[15]); the netplan
    // test's paint already lays out area 243 = 268 - 200 / 8 and the real
    // GUI sends no round (a recorded session srv[11] -> gui[8])
    final regs = regions;
    final dyn = regs.where((r) => r.kind == 'dynpro').firstOrNull;
    final a = st.area;
    if (dyn == null || a == null) return skip('no AREASIZE painted');
    if (dyn.rect.rows == a.$1 && dyn.rect.cols == a.$2) {
      return skip(
        'the server area ${a.$1}x${a.$2} is the one we draw (docks $sig)',
      );
    }
    st.reportedDocks = sig;
    final w0 = st.window;
    if (w0 != null) {
      // the pair at the report: a later different one is the re-layout
      for (final d in docks) {
        final side = reg.props[d]?[propDockSide];
        if (side == '1' || side == '2') reg.reportedDelta[d] = w0.$2 - a.$2;
      }
    }
    final winPx = (ctx.winPxHeight, ctx.winPxWidth);
    var areaPx = winPx;
    final w = st.window;
    if (w != null && w.$1 > 0 && w.$2 > 0) {
      areaPx = (
        (winPx.$1 * dyn.rect.rows / w.$1).round(),
        (winPx.$2 * dyn.rect.cols / w.$2).round(),
      );
      // a pane we realize by dockFraction: area = window px - dock px
      final f = st.dockFraction;
      if (f != null && w.$2 - dyn.rect.cols == (f * w.$2).round()) {
        areaPx = (areaPx.$1, winPx.$2 - (winPx.$2 * f).round());
      }
    }
    final xml = windowsControlsXml(_controlsReport(s, dyn.rect, w));
    _trace(
      'layout round sent: window ${winPx.$1}x${winPx.$2} px, area '
      '${areaPx.$1}x${areaPx.$2} px (${dyn.rect.rows.toInt()}x'
      '${dyn.rect.cols.toInt()} cells; the server painted '
      '${a.$1}x${a.$2} of ${w0?.$1}x${w0?.$2}), docks $sig, step $step',
    );
    var items = windowsLayoutRoundItems(
      ctx,
      windowPx: winPx,
      areaPx: areaPx,
      scrollInfos2: scroll,
      xml: xml,
    );
    // the first round in a new window carries the window atoms, whatever
    // the round (sap_session_windows.dart _WindowState.firstRoundOwed)
    items = _withFirstRound(items);
    await _send(clientFrame(items));
    // the reply: the queue the round releases, then the re-laid-out paint
    for (var i = 0; i < 60; i++) {
      final List<Uint8List> got;
      try {
        got = await recvTurn(
          timeout: Duration(seconds: i == 0 ? (offlineReplay ? 2 : 30) : 10),
        );
      } on TimeoutException {
        if (i == 0) _trace('layout round: no reply');
        break;
      }
      final sent = await _driveAutomation(got);
      if (sent == 0 && _paintsScreen(got)) break;
    }
    await _drainPending();
  }

  /// The docking containers shown on the current screen, in creation
  /// order. A HIDDEN dock (SetProperty 290 = 0, ControlRegistry.hidden)
  /// takes no window space and owes no report: SM12's server-administration
  /// dock 130 (a recorded session srv[114]) — the real GUI sends no
  /// `%_GS 0 3` after the paint (srv[115]); it is reported, under its
  /// `…:1` signature, once the toolbar button shows it.
  List<String> _shownDocks() {
    final reg = _layoutState.registry;
    final latest = <String, String>{};
    for (final c in reg.created) {
      latest[c.shell] = c.cls;
    }
    return [
      for (final e in latest.entries)
        if (e.value.toUpperCase().contains('DOCKING') &&
            _onScreen(e.key) &&
            !reg.hidden(e.key))
          e.key,
    ];
  }

  /// The item-17 CONTROLS report a RESIZE round to [rows] x [cols] cells
  /// carries on a docked screen ([windowsResizeRoundItems]): the layout
  /// round's report ([_controlsReport]) for the new window, its area the
  /// window less the docked panes ([ActionContext.dockedCells]), cut to
  /// what the window change itself moved — the real GUI's g[28] of
  /// a recorded session: the docks' extents ALONG the window
  /// (bottom dock 117 `300`, left dock 135 `120`; a side dock keeps its
  /// width, a top / bottom one its height) and the grids' GENERIC. A
  /// dynpro-area container is not in it: it follows the server's re-layout
  /// and is reported with the next round (g[30]: 261 `120` / `300`). Null
  /// without a shown dock (the SE71 resize rounds carry no item 17) or
  /// nothing to report.
  String? _resizeControlsXml(int rows, int cols) {
    final s = screen;
    if (s == null || s.program == null || _shownDocks().isEmpty) return null;
    final (dr, dc) = ctx.dockedCells;
    final area = CellRect(
      0,
      0,
      (rows - dr < 1 ? 1 : rows - dr).toDouble(),
      (cols - dc < 1 ? 1 : cols - dc).toDouble(),
    );
    final reg = _layoutState.registry;
    final classes = reg.classes();
    final linked = {for (final l in reg.areaLinks.values) l.$1};
    final report = [
      for (final c in _controlsReport(s, area, (rows, cols)))
        if (ControlReport(
              c.shell,
              generic: c.generic,
              props: [
                for (final p in c.props)
                  if (!linked.contains(c.shell))
                    if ((classes[c.shell] ?? '').toUpperCase().contains(
                          'DOCKING',
                        ))
                      if (switch (reg.props[c.shell]?[propDockSide]) {
                        '1' || '2' => p.$1 == propControlHeight,
                        '3' || '4' => p.$1 == propControlWidth,
                        _ => false,
                      })
                        p,
              ],
            )
            case final r when r.generic != null || r.props.isNotEmpty)
          r,
    ];
    return report.isEmpty ? null : windowsControlsXml(report);
  }

  /// The item-17 CONTROLS report of the layout round: per shell (numeric
  /// order, as gui[15]) the first-visible cell of a grid that registered
  /// FirstVisibleRow (FVCID/FVRID 1/1 with rows, 0/0 without — gui[15]
  /// 118 / 180), and every registered size prop (120 height / 300 width)
  /// the server did NOT set itself (a fresh profile realizes a requested
  /// extent exactly and reports nothing for it — sameuser gui[44] dock 137
  /// reports 120 alone; gui[15]'s 135 300 = 845 is the operator's
  /// remembered sash, not a fresh value). Values in the session's own
  /// METRICS (X2 8 / Y2 29, the reference client's ea_controlxml model): a dynpro
  /// area container cols x 8 / rows x 13.64; a side dock's height its pane
  /// rows x 13 + 17; a top/bottom dock's width the window cols x 8.
  List<ControlReport> _controlsReport(
    ScreenModel s,
    CellRect area,
    (int, int)? window,
  ) {
    final reg = _layoutState.registry;
    final kinds = reg.kinds();
    final classes = reg.classes();
    final linked = <String, ScreenContainer>{};
    reg.areaLinks.forEach((name, link) {
      final g = s.containers[name];
      if (g != null && _onScreen(link.$1)) linked[link.$1] = g;
    });
    final out = <ControlReport>[];
    final shells = reg.cachedProps.keys.where(_onScreen).toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    for (final sh in shells) {
      final props = reg.cachedProps[sh]!;
      (int, int)? generic;
      if (kinds[sh] == 'grid' && props.contains('FirstVisibleRow')) {
        final rows = grids[sh]?.rows.length ?? 0;
        generic = rows > 0 ? (1, 1) : (0, 0);
      }
      final set = reg.props[sh] ?? const <String, String>{};
      final docking = (classes[sh] ?? '').toUpperCase().contains('DOCKING');
      // a hidden dock realizes no extent (see _maybeLayoutRound)
      if (docking && reg.hidden(sh) && generic == null) continue;
      final side = set[propDockSide];
      final values = <(String, String)>[];
      for (final p in props) {
        if (p != propControlHeight && p != propControlWidth) continue;
        // a side dock's width the server set but we realize differently
        // (dockFraction): reported, like gui[15]'s 135 300 = 845
        final f = _layoutState.dockFraction;
        if (docking && p == propControlWidth && (side == '1' || side == '2')) {
          if (f != null && window != null) {
            final v = (f * window.$2 * 8).round();
            if ('$v' != set[propControlWidth]) values.add((p, '$v'));
          }
          continue;
        }
        if (set.containsKey(p)) continue;
        String? v;
        final g = linked[sh];
        if (g != null) {
          v = areaContainerPx(g, p);
        } else if (docking && set[propVisible] != '0') {
          if ((side == '1' || side == '2') && p == propControlHeight) {
            v = '${area.rows.toInt() * 13 + 17}';
          } else if ((side == '3' || side == '4') && p == propControlWidth) {
            v = '${(window?.$2 ?? area.cols.toInt()) * 8}';
          }
        }
        if (v != null) values.add((p, v));
      }
      if (generic != null || values.isNotEmpty) {
        out.add(ControlReport(sh, generic: generic, props: values));
      }
    }
    return out;
  }

  /// The last AREASIZE (16/12/7) pairs of a turn: (window, area), per
  /// window level — a popup's paint carries its own pair (the "Tri"
  /// dialog: 16 x 79 under the grid's 40 x 268, live the test system step 35, its SES
  /// byte 7 = 1); the base pair and SCROLL_INFOS2 come from level 0.
  void _mirrorAreaPairs(List<Uint8List> frames) {
    final st = _layoutState;
    var level = 0;
    for (final f in frames) {
      final dec = decompressFrame(f);
      if (dec == null) continue;
      for (final it in dec.walk.items) {
        if (it.type == itemSes && it.value.length >= 8) level = it.value[7];
        if (!it.isAppl || it.id != 12) continue;
        final v = it.value;
        if (it.sid == 7 && v.length >= 16) {
          final bd = ByteData.sublistView(v);
          final w = (bd.getUint32(0), bd.getUint32(4));
          final a = (bd.getUint32(8), bd.getUint32(12));
          if (level == 0) {
            st
              ..window = w
              ..area = a;
            // the docked panes' cells: what every later main-window round
            // reports beside the window as the dynpro area (16/12/8)
            ctx.dockedCells = _shownDocks().isEmpty
                ? (0, 0)
                : (w.$1 > a.$1 ? w.$1 - a.$1 : 0, w.$2 > a.$2 ? w.$2 - a.$2 : 0);
          } else {
            st
              ..modalWindow = w
              ..modalArea = a;
          }
        } else if (it.sid == 6 && v.length >= 33 && level == 0) {
          st.scrollInfos2 = Uint8List.fromList(v);
        }
      }
    }
  }

  /// The user dragged the sashes of splitter [splitter] (its kernel
  /// shell): its rows ([rows]) or columns now span [extents] (one per row /
  /// column in order, any one unit — cells, pixels). A splitter sash is the
  /// client's own: the drag sends nothing (a recorded session KEY
  /// DECODE 1, 5), but the server's next size READ of that splitter
  /// (`GetRowHeight` / `GetColumnWidth`, /AIF/IFMON's every form submit)
  /// is answered with it — in the splitter's units, the values it holds
  /// rescaled ([splitterValuesFromExtents]) — until the server sets that
  /// axis again ([splitterSizeReads], a recorded session
  /// raw s43 / s64). Returns the values held, or null when the splitter is
  /// unknown or not a relative one (nothing held then).
  ///
  /// An ABSOLUTE axis (SetRowMode / SetColumnMode 0: pixels) holds the
  /// cells' extents in its pixels (a cell's [metricY2] / [metricX2] px —
  /// the composition's own conversion), its last row (column) left to take
  /// the rest unless the server declared it. The regions re-lay out from
  /// the held values at once ([regions]); the next client round carries
  /// the realized size (120 / 300) of every size-registered shell the
  /// drag resized ([_pendingSashControls]) and nothing else — no read-back,
  /// no sash event (a recorded session g[28] / g[30],
  /// a recorded session KEY DECODE 1).
  Map<int, double>? noteSplitterSash(
    String splitter, {
    required bool rows,
    required List<num> extents,
  }) {
    final st = _layoutState;
    final sp = splitter.trim();
    final f = st.registry.splitters[sp];
    if (f == null) return null;
    final axis = (sp, rows);
    final current = st.sashHeld[axis] ?? (rows ? f.rowPct : f.colPct);
    final v = splitterHeldValues(
      current,
      extents,
      absolute: (rows ? f.rowMode : f.colMode) == 0,
      rows: rows,
    );
    if (v == null) return null;
    st.sashHeld[axis] = v;
    st.sashDragged.add(sp);
    _trace('splitter $sp ${rows ? 'rows' : 'columns'} dragged: $v');
    return v;
  }

  /// The CONTROLS a round owes after a sash drag: per shell, ascending,
  /// the realized size (120 height / 300 width, the session's METRICS:
  /// cols x 8, rows x 13.64 — [areaContainerPx]) of every shell inside a
  /// dragged splitter that registered it as a cached prop, the server did
  /// not set itself and whose value differs from the one last flushed
  /// ([ControlRegistry.flushedSizes]) — the real GUI's dirty report
  /// (a recorded session (4) / (7): `CONTROLS 262 300=1799 only`).
  /// Splitter cells that registered nothing (/AIF/IFMON's, ST04's load
  /// history: a recorded session s[26] / s[40]) owe nothing.
  /// Null when nothing is owed; the drag is reported once.
  String? _pendingSashControls() {
    final st = _layoutState;
    if (st.sashDragged.isEmpty || answerDialect != GuiDialect.windows) {
      return null;
    }
    final dragged = Set.of(st.sashDragged);
    st.sashDragged.clear();
    final boxes = <String, CellRect>{};
    _composeBase(boxes: boxes);
    final out = splitterDragSizes(
      st.registry,
      boxes,
      dragged,
      isLive: _onScreen,
    );
    if (out.isEmpty) return null;
    _trace('sash drag: ${[for (final c in out) c.$1].join(', ')} resized');
    return windowsControlBlocks(out);
  }

  /// Fold one answered flush call into the layout registry and bind its
  /// tree pushes (AddR3Table / AddItemTable on a tree object) to the
  /// tree's shell by the url the preceding SetDataFromUrl named.
  ///
  /// Returns the call's splitter size-read answers by VARS row
  /// ([splitterSizeReads]: what the splitters held when the call arrived,
  /// its own earlier Set* verbs included) — the responder's prop store.
  Map<int, Uint8List> _foldLayoutCall(FlushCall call, int closingStep) {
    final st = _layoutState;
    final meta = verbMeta(call);
    final verbs = [
      for (var i = 1; i <= call.verbs.length; i++)
        LayoutVerb(
          call.verbs[i - 1],
          verbNamedArgs(call, i),
          i <= meta.length ? meta[i - 1].obj : '',
          i <= meta.length ? meta[i - 1].objValue : '',
          i <= meta.length ? (meta[i - 1].result ?? '') : '',
        ),
    ];
    final reads = splitterSizeReads(
      verbs,
      st.registry,
      shellOfHandle: (h) => _ea.shellAlias[h],
      held: st.sashHeld,
    );
    // the server's own set of a splitter axis is its new baseline: a drag
    // the client held there is over
    if (st.sashHeld.isNotEmpty) {
      for (final axis in splitterAxesSet(
        verbs,
        st.registry,
        shellOfHandle: (h) => _ea.shellAlias[h],
      )) {
        st.sashHeld.remove(axis);
      }
    }
    st.registry.foldCall(
      verbs,
      program: screen?.program,
      step: closingStep,
      shellOfHandle: (h) => _ea.shellAlias[h],
      isLive: _live,
    );
    // every creation is stamped with the imode its frame rode, and a
    // re-created shell id lives again — in wire order against the call's
    // own DestroyWindow verbs (the frame-level fold misses a chunked call)
    for (final v in verbs) {
      final sh = (v.args['#1'] ?? '').trim();
      if (!_digitsOnlyRx.hasMatch(sh)) continue;
      if (v.verb.startsWith('CreateControl')) {
        st.imodes.stamp(sh, step: closingStep);
        _ea.destroyedControls.remove(sh);
      } else if (v.verb == 'DestroyWindow') {
        _ea.destroyedControls.add(sh);
        _forgetShellState(sh);
      }
    }
    for (final b in dpPushBindings(call)) {
      if (b.shell case final sh?) st.contentShells.add(sh);
    }
    final rowShell = <String, String>{};
    for (final v in verbs) {
      final sh = (v.args['#1'] ?? '').trim();
      if (v.verb.startsWith('CreateControl') && v.result.isNotEmpty) {
        rowShell[v.result] = sh;
      }
    }
    final kinds = st.registry.kinds();
    String? url;
    for (final v in verbs) {
      if (v.verb == 'SetDataFromUrl') {
        final u = (v.args['#3'] ?? '').trim();
        if (u.startsWith('SAPR3://')) url = u;
      } else if (_treeTableVerb.hasMatch(v.verb) && url != null) {
        var sh = rowShell[v.obj.trim()];
        final h = v.objValue.trim();
        if (sh == null && h.isNotEmpty) {
          sh = kinds[h] == 'tree' ? h : _ea.shellAlias[h];
        }
        if (sh != null && kinds[sh] == 'tree') st.treeUrlShell[url] = sh;
        url = null;
      }
    }
    return {
      for (final e in reads.entries)
        e.key: Uint8List.fromList(e.value.codeUnits),
    };
  }
}

final RegExp _treeTableVerb = RegExp(
  r'^(?:Add|Update|Set|SetUpdate)(?:R3|Item)Table$',
);

bool _sameTables(List<DpTable> a, List<DpTable> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!identical(a[i], b[i])) return false;
  }
  return true;
}

int _visibleNodes(SapTreeModel m) =>
    m.nodes.values.where((n) => !n.hidden).length;

SapTreeModel _treeOf(List<DpTable> tables) {
  final m = SapTreeModel();
  for (final t in tables) {
    m.apply(t);
  }
  return m;
}

class _LayoutState {
  _LayoutState(HomeSystem home) : imodes = IModeScope(home: home);

  final ControlRegistry registry = ControlRegistry();

  /// the internal modes and each shell's (see _observeIModes)
  final IModeScope imodes;

  /// tree push url -> the imode it arrived in
  final Map<String, String> treeUrlIMode = {};

  /// (splitter, rows?) -> the values the user's sash drag left there, held
  /// until the server sets that axis again ([SapSessionLayout
  /// .noteSplitterSash])
  final Map<(String, bool), Map<int, double>> sashHeld = {};

  /// the splitters dragged since the last client round (its CONTROLS owe
  /// their resized shells' sizes — [SapSessionLayout._pendingSashControls])
  final Set<String> sashDragged = {};
  int? actionStartStep;
  int? progSinceStep;
  (int, int)? window;
  (int, int)? area;

  /// the active popup's AREASIZE pair (see _mirrorAreaPairs)
  (int, int)? modalWindow;
  (int, int)? modalArea;

  /// generation starts (see _noteGenerations)
  String? baseProgram;
  int? baseSinceStep;
  String? modalKey;
  int? modalSinceStep;
  final Set<String> contentShells = {};
  bool layoutRoundEnabled = true;
  double? dockFraction = 739 / 1880;

  /// the docking containers' requested extents last reported
  String? reportedDocks;

  /// `dock:cols@step` of the last dock drag a round reported
  /// ([SapSession.resizeDock])
  String? draggedRound;

  /// the last server SCROLL_INFOS2 (16/12/6) value, echoed by the round
  Uint8List? scrollInfos2;

  /// (dp url, decoded tree table) in arrival order
  final List<(String, DpTable)> treeTables = [];

  /// tree push url -> the tree shell its Add*Table verb named
  final Map<String, String> treeUrlShell = {};

  /// tree shell -> the tables its last built model was applied from, and
  /// that model ([SapSessionLayout.trees])
  final Map<String, (List<DpTable>, SapTreeModel)> treeModels = {};
}

final Expando<_LayoutState> _layoutStates = Expando('layoutState');

/// received frame -> the system it was relayed from (imode_scope.dart)
final Expando<SystemIdentity> _relayFrames = Expando('relayFrames');

/// Frames of a window that lives on another system than the logon's (the
/// SM59 remote-logon window, [IModeScope.elsewhere]) — not relays (their
/// step is the window's clock), but nothing this logon's wall answer reads.
final Expando<SystemIdentity> _remoteWindowFrames = Expando(
  'remoteWindowFrames',
);

/// received step-bearing frame -> the home-clock step it was folded at
final Expando<int> _frameClock = Expando('frameClock');

/// The cached size prop [prop] (120 height / 300 width) a container
/// LinkContainer'd into the dynpro custom-control area [g] reports, in the
/// session's own METRICS (X2 8 / Y2 29, the reference client's ea_controlxml model):
/// cols x 8, rows x 13.64 — the layout round's CONTROLS report and the
/// calendar pick's container block (a recorded session gui[6], where
/// the real GUI's own metrics give 141 / 327 for the 12 x 40 area). Null
/// for any other prop.
String? areaContainerPx(ScreenContainer g, String prop) => switch (prop) {
  propControlWidth => '${g.width * 8}',
  propControlHeight => '${(g.height * 13.64 + 0.5).floor()}',
  _ => null,
};

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call (audit #7 / zcode P-12).
final RegExp _digitsOnlyRx = RegExp(r'^\d+$');
