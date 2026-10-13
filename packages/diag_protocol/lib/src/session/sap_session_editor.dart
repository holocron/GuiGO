part of 'sap_session.dart';

/// The editor side of a [SapSession]: the ABAP editor / TextEdit controls
/// of the window on display with the source the server loaded into them
/// (text_editor.dart).
extension SapSessionEditor on SapSession {
  SapTextEditorTracker get _editorTracker =>
      _editorTrackers[_w] ??= SapTextEditorTracker();

  /// The editor controls of the window on display, the ones linked to the
  /// active popup first (when one is up), then those of the full-screen
  /// dynpro under it — match them to [regions] / [modalRegions] by
  /// [SapTextEditor.shell]. An editor shows on the dynpro its container is
  /// linked to (`LinkControl(117, SAPLS38E, 500)`), else on the screen the
  /// paint after its load named; a control the server destroyed is gone.
  /// SE38's editor outlives the screen: back on SAPLWBABAP/0100 it is not
  /// listed, and F7 on another program reloads the same shell.
  List<SapTextEditor> get editors {
    final s = screen;
    if (s == null || s.program == null) return const [];
    final t = _editorTracker;
    final out = <SapTextEditor>[];
    void addOn(ScreenModel? m) {
      if (m == null || m.program == null) return;
      for (final e in t.all) {
        // a destroyed editor, or one of another internal mode (hidden, its
        // body kept: SE39's compare panes under a nested screen)
        if (!_onScreen(e.shell) || !t.loaded.contains(e.shell)) continue;
        // linked to the main dynpro, or to a SUBSCREEN this paint hosts
        // (a 16/10/6 NAME naming it, [ScreenModel.hostedDynpros]): a
        // control lives on the dynpro its custom-control area belongs to,
        // and a subscreen's area is on screen wherever the subscreen is
        // painted — the ABAP Debugger's source tool is the subscreen
        // SAPLSTPDA_TOOL_EDITOR/0100 in the LEFT cell of RSTPDAMAIN/0100
        // (a recorded session s[27]). the reference client scopes editor
        // bodies by the current generation's area links only
        // (editor_push.current_area_links), never by the main dynpro.
        final on = t.screenOf(e.shell);
        if (on == null || !m.showsDynpro(on.$1, on.$2)) continue;
        if (!out.contains(e)) out.add(e);
      }
    }

    addOn(s);
    if (s.modalLevel > 0) addOn(baseScreen);
    return out;
  }

  bool _isLiveEditor(String shell) => !_ea.destroyedControls.contains(shell);

  /// Fold the editor verbs of one complete flush call.
  /// Fold a flush call into the editors; returns the shells it touched.
  Set<String> _ingestEditorCall(Uint8List value, [FlushCall? parsed]) {
    try {
      return _editorTracker.foldCall(
        value,
        shellOf: (h) => _ea.shellAlias[h],
        dpSegment: (url) => _ea.dpCache.byUrl[url],
        isLive: _isLiveEditor,
        parsed: parsed,
      );
    } catch (e) {
      _noteIngestFailure('editor ingest', e);
      return const {};
    }
  }

  /// The EXPORT_XML of a flush's answer that moved an ABAP editor's cached
  /// props by a METHOD: the real GUI reports the control's changed props
  /// in the answer itself — `SetSelectionPosInLine(136, 1)` answered with
  /// SelPosStartCol 1, SelPosEndLine 136, SelPosStartLine 136,
  /// SelPosEndCol 1 (a recorded session g[32]; the
  /// unchanged column left out: a recorded session g[27]), a
  /// document load with its LineCount (g[23] 6, g[30] 1212; debugger
  /// g[25] 28) — of the editors [touched] by the call. The view
  /// (First/LastVisibleLine) too once the control is realized (g[30]:
  /// LastVisibleLine 44 after the reload of an editor on screen — the
  /// view's capacity, [_editorLastVisible]); inside the creation wave the
  /// view rides the first round instead. Null when nothing changed or
  /// outside the Windows dialect. A call that registers cached props
  /// itself is answered with the registration's report
  /// ([_editorCreationAnswer]) when it creates an ABAP editor, else by the
  /// responder (null).
  Uint8List? _editorFlushReport(FlushCall call, Set<String> touched) {
    if (answerDialect != GuiDialect.windows) return null;
    if (call.cachedProps.isNotEmpty) return _editorCreationAnswer(call);
    if (touched.isEmpty) return null;
    final t = _editorTracker;
    final reg = _layoutState.registry;
    final reports = <ControlReport>[];
    final shells = touched.toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    for (final sh in shells) {
      final e = t[sh];
      if (e == null || e.kind != 'ab4' || !_isLiveEditor(sh)) continue;
      _resolveCentering(e, realized: _editorRealized(e));
      final registered = reg.cachedProps[sh];
      // the view only once the control is realized — its container's size
      // reported (a load inside the creation wave answers its LineCount
      // alone, the view rides the first round: g[23] / g[24], debugger
      // g[25] / g[26])
      final realized = _editorRealized(e);
      final props = [
        for (final (p, v) in _editorClientProps(e))
          if ((realized || _methodMovedProps.contains(p)) &&
              (registered == null || registered.contains(p)) &&
              e.serverProps[p] != v)
            (p, v),
      ];
      if (props.isEmpty) continue;
      _noteEditorFlushed(e, props);
      reports.add(ControlReport(sh, props: props));
    }
    if (reports.isEmpty) return null;
    _trace(
      'flush answer reports '
      '${[for (final r in reports) '${r.shell} ${r.props.map((p) => p.$1).join('/')}'].join(', ')}',
    );
    return wireText('${windowsControlsXml(reports)}\u0000');
  }

  /// Bind the editors loaded without a linked container to the screen a
  /// paint names.
  void _foldEditors(List<Uint8List> frames) {
    final t = _editorTracker;
    if (t.all.isEmpty || !_paintsProgram(frames)) return;
    final s = screen;
    if (s?.program == null || s?.dynpro == null) return;
    if (t.unbound.isNotEmpty) t.bindUnbound(s!.program!, s.dynpro!);
    // the area each ABAP editor on screen was painted in: its view's size
    // while the control lives ([SapTextEditor.areaRows])
    for (final e in t.all) {
      if (e.kind != 'ab4' || !_isLiveEditor(e.shell)) continue;
      final g = _editorArea(e);
      if (g != null) e.areaRows = g.height;
    }
  }

  /// The dynpro custom-control area of the active (else base) screen the
  /// ABAP editor [e] lives in: the area its container (or a container up
  /// the parent chain) is LinkContainer'd into, else the area it was bound
  /// to by name ([SapTextEditor.container]); null when none is painted.
  ScreenContainer? _editorArea(SapTextEditor e) {
    final reg = _layoutState.registry;
    final seen = <String>{};
    var sh = reg.parents[e.shell];
    while (sh != null && seen.add(sh)) {
      final g = _linkedArea(sh);
      if (g != null) return g;
      sh = reg.parents[sh];
    }
    final name = e.container;
    if (name == null) return null;
    for (final m in [?screen, ?baseScreen]) {
      final g = _areaNamed(m, name);
      if (g != null) return g;
    }
    return null;
  }

  /// The custom-control area of the active (else base) screen container
  /// [shell] is LinkContainer'd into, null when none is painted.
  ScreenContainer? _linkedArea(String shell) {
    final reg = _layoutState.registry;
    for (final link in reg.areaLinks.entries) {
      if (link.value.$1 != shell) continue;
      for (final m in [?screen, ?baseScreen]) {
        final g = _areaNamed(m, link.key);
        if (g != null) return g;
      }
    }
    return null;
  }

  /// [m]'s container [name] (case-insensitive), null when it has none.
  static ScreenContainer? _areaNamed(ScreenModel m, String name) =>
      m.containers[name] ??
      m.containers.entries
          .where((x) => x.key.toUpperCase() == name.toUpperCase())
          .map((x) => x.value)
          .firstOrNull;

  /// How many lines the view of the ABAP editor [e] shows from its top:
  /// the app's view ([SapSession.editorViewLines]: its laid-out viewport,
  /// else the region it gives the editor), else the session's model of
  /// the real GUI's control — [editorVisibleLines] of its area's rows x
  /// the kernel's 22 px row at [ab4KernelLinePx] a line (the 37-row
  /// SAPLS38E/0500 EDITOR area: 814 px -> 44 lines, a recorded session
  /// breakpoint_scrolled g[30]); with no area painted yet, the window's
  /// rows less the title row.
  int _editorCapacity(SapTextEditor e) {
    final app = editorViewLines?.call(e.shell);
    if (app != null && app >= 1) return app;
    final rows = _editorArea(e)?.height ?? e.areaRows;
    if (rows == null || rows < 1) return screenRows - 1 < 1 ? 1 : screenRows - 1;
    return editorVisibleLines(
      (rows * ctx.kernelCell.height).toDouble(),
      ab4KernelLinePx,
    );
  }

  /// The scroll a `SetSelPosInLineCentered(l, …)` of [e] implies
  /// ([SapTextEditor.centerLine]), applied as the control's new first line
  /// (the view follows it: [SapTextEditor.firstVisibleLinePuts]): on a
  /// control not [realized] yet — no line on screen — the line itself
  /// (a recorded session g[41]: FirstVisibleLine = LastVisible
  /// Line = 9 in the creation answer); on a realized one the line in the
  /// middle of the view's capacity, never scrolled past the document's
  /// end (g[56]: line 29 of 54 in a 40-line view -> 10..49).
  void _resolveCentering(SapTextEditor e, {required bool realized}) {
    final l = e.centerLine;
    if (l == null) return;
    e.centerLine = null;
    var first = l;
    if (realized) {
      final cap = _editorCapacity(e);
      final n = e.lines.isEmpty ? 1 : e.lines.length;
      final maxFirst = n - cap + 1 < 1 ? 1 : n - cap + 1;
      first = (l - (cap - 1) ~/ 2).clamp(1, maxFirst);
    }
    e
      ..firstVisibleLine = first
      ..firstVisibleLinePuts += 1;
  }

  /// [e]'s FirstVisibleLine: the view the app reported, else the server's
  /// put (or a centering's line) — once a paint laid the control out never
  /// scrolled past the document's end, as the view lays it out
  /// (a recorded session g[55]: the creation's 9 of a 28-line
  /// document in a 40-line view reports 1).
  int _editorFirstVisible(SapTextEditor e) {
    final reported = e.viewFirstLine;
    if (reported != null) return reported;
    final first = e.firstVisibleLine ?? 1;
    // laid out once a paint showed it (its area known), whatever the
    // server heard of its size yet
    final shown = e.areaRows != null || _editorArea(e) != null;
    if (first <= 1 || !shown) return first < 1 ? 1 : first;
    final n = e.lines.isEmpty ? 1 : e.lines.length;
    final maxFirst = n - _editorCapacity(e) + 1;
    return first.clamp(1, maxFirst < 1 ? 1 : maxFirst);
  }

  /// [e]'s LastVisibleLine with [first] on top: the view the app reported
  /// ([setEditorClientState]), else `first + capacity - 1`
  /// ([_editorCapacity]) capped by the document — 1 for an empty one.
  int _editorLastVisible(SapTextEditor e, int first) {
    final reported = e.viewLastLine;
    if (reported != null) return reported;
    if (e.lines.isEmpty) return 1;
    final last = first + _editorCapacity(e) - 1;
    return last.clamp(1, e.lines.length);
  }

  /// The answer to a Windows flush that CREATES an ABAP editor (its
  /// `RegisterCachedProp` wave), as sapab4edit.ocx answers it — the same
  /// on every Windows capture of the corpus, byte for byte up to the
  /// shells and the document (a recorded session
  /// g[10], a recorded session g[12] / g[41], a recorded session
  /// editor_selection g[13] / _redo g[6], a recorded session
  /// breakpoint_marker g[6], a recorded session g[6] /
  /// _s4d g[5], a recorded session g[27], a recorded session
  /// save g[20], a recorded session g[25], a recorded session
  /// g[15], a recorded session g[6]): the Windows spelling (` <CONTROLS>
  /// <CONTROL SHELLID ="…"> <PROPERTY VALUE ="…" NAME ="…"/>`), one
  /// CONTROL per registered shell in registration order (the container
  /// before its editor), the container's size props 0 (not realized yet),
  /// the editor's props in the OCX's own order ([ab4FlushOrder]) with the
  /// control's state after the wave — the caret (1/1, or the wave's
  /// SetSelectionPosInLine: debugger g[41] 9/1), FirstVisibleLine (1, or
  /// the wave's put: 9), LineCount (1 for the empty document, the lines a
  /// LoadDocFromDP of the same wave loaded: se80 g[27] 14, wda g[25] 2),
  /// LastVisibleLine = FirstVisibleLine (no line on screen yet),
  /// TextModified / Version 0 — then the `<BLOBS>` pull of the lexer data
  /// the wave's `LoadLexerDataFromUrl` names (the server pushes it next,
  /// srv[14..25]), and NO METRICS tail. Recorded as what the server holds
  /// ([SapTextEditor.serverProps]). Null for a call that creates no ABAP
  /// editor (the responder's answer).
  Uint8List? _editorCreationAnswer(FlushCall call) {
    final t = _editorTracker;
    final blocks = registeredControlValues(call);
    final eds = <String, SapTextEditor>{};
    for (final (sh, props) in blocks) {
      if (!props.any((p) => p.$1 == 'LineCount')) continue;
      final e = t[sh] ?? t[_ea.shellAlias[sh] ?? ''];
      if (e != null && e.kind == 'ab4') eds[sh] = e;
    }
    if (eds.isEmpty) return null;
    final out = <(String, List<(String, String)>)>[];
    for (final (sh, props) in blocks) {
      final e = eds[sh];
      if (e == null) {
        out.add((sh, props));
        continue;
      }
      _resolveCentering(e, realized: false);
      final first = e.firstVisibleLine ?? 1;
      final line = e.cursorLine ?? 1, col = e.cursorCol ?? 1;
      final state = <String, String>{
        'SelPosStartCol': '$col',
        'FirstVisibleLine': '$first',
        'LineCount': '${e.lines.isEmpty ? 1 : e.lines.length}',
        'SelPosEndLine': '${e.selEndLine ?? line}',
        // not realized: no line on screen below the first
        'LastVisibleLine': '$first',
        'TextModified': '0',
        'SelPosStartLine': '$line',
        'Version': '0',
        'SelPosEndCol': '${e.selEndCol ?? col}',
      };
      final registered = {for (final (p, _) in props) p};
      final values = [
        for (final p in ab4FlushOrder)
          if (registered.contains(p)) (p, state[p]!),
        // a prop the OCX order does not know: the responder's value, after
        for (final (p, v) in props)
          if (!ab4FlushOrder.contains(p)) (p, v),
      ];
      _noteEditorFlushed(e, values);
      out.add((sh, values));
    }
    final url = _lexerUrl(call);
    _trace(
      'editor creation answered: ${[for (final (sh, _) in out) sh].join(', ')}'
      '${url == null ? '' : ' + the lexer pull'}',
    );
    return wireText(
      '<?xml version="1.0" encoding="sap*"?><DATAMANAGER> <CONTROLS>'
      '${windowsControlBlocks(out)}</CONTROLS>'
      '${url == null ? '' : ' <BLOBS id="blobs">  <REQUEST id="0" URL ="$url"/></BLOBS>'}'
      '</DATAMANAGER>\u0000',
    );
  }

  /// The `SAPR3://` url of [call]'s `LoadLexerDataFromUrl` (the ABAP
  /// editor's syntax tables, pulled through the answer's BLOBS), null when
  /// it has none.
  static String? _lexerUrl(FlushCall call) {
    for (var i = 1; i <= call.verbs.length; i++) {
      if (call.verbs[i - 1] != 'LoadLexerDataFromUrl') continue;
      for (final (_, v) in verbArgs(call, i)) {
        final u = v.trim();
        if (u.startsWith('SAPR3://')) return u;
      }
    }
    return null;
  }

  /// Set or remove a session breakpoint on [line] (1-based) of [e]: the
  /// ABAP editor's "Définir/Supprimer point d'arrêt session" key
  /// (Ctrl+Shift+F12, vkey 48) typed in the editor with the caret on the
  /// line, as the real SAP GUI for Windows sends it
  /// (a recorded session g[38] / g[40],
  /// a recorded session g[33]): the bare key round with the
  /// focus IN the editor (16/9/18 <editor>, no okcode, no 16/15/1) and
  /// ONLY the cached props the server does not hold yet
  /// ([_editorDirtyControls]: the caret moved onto [line] — its column
  /// kept when the caret is on the line already, else 1 — a scrolled
  /// view, a container size the creation left owed); with the caret on the
  /// line the server put it on, no CONTROLS at all (g[38]). The server
  /// reads the line from the caret it holds and answers, in ONE flush,
  /// `RemoveAllMarker(24, 25, 26)`, `SetMarker(2, ",<line>")` /
  /// `RemoveMarker(2, ",<line>")`, `SetSavePoint(0)` — which update
  /// [SapTextEditor.breakpoints]. Works in display mode; session
  /// breakpoints are per user and per logon. (the reference client's older live
  /// round, a recorded session step 32, kept the
  /// dynpro field cursor and flushed the whole caret: the server took it
  /// too.)
  ///
  /// The KEYBOARD form; a click or tap in the editor's margin is
  /// [editorMarginClick].
  Future<List<Uint8List>> editorToggleBreakpoint(SapTextEditor e, int line) {
    _requireWindowsEditor(e);
    if (line < 1) throw RangeError.value(line, 'line', 'is 1-based');
    if (e.cursorLine != line || e.selEndLine != null) {
      _noteEditorCursor(e, line, e.cursorLine == line ? e.cursorCol ?? 1 : 1);
    }
    return _editorFocusKey(e, vkeySessionBreakpoint);
  }

  /// The key [vkey] typed with the focus IN the ABAP editor [e], its caret
  /// where it is ([editorFocusKeyItems]: the bare key round, 16/9/18
  /// <editor>, the props the server does not hold yet as its CONTROLS).
  Future<List<Uint8List>> _editorFocusKey(SapTextEditor e, int vkey) {
    final controls = _editorDirtyControls(e);
    _trace(
      'editor ${e.shell} key $vkey'
      '${controls.isEmpty ? '' : ' (+ ${controls.map((c) => c.$1).join('/')} props)'}',
    );
    _noteControlsFlushed(e, controls);
    return _act(
      editorFocusKeyItems(ctx, vkey, shell: e.shell, controls: controls),
      dialectReady: true,
    );
  }

  /// The ABAP editor a [vkey] press goes to as an editor-focused key round
  /// ([_editorFocusKey]), null for the plain key round: for the editor's
  /// own caret-keyed breakpoint functions — Ctrl+Shift+F12
  /// ([vkeySessionBreakpoint]) and the application toolbar's @VB@
  /// Ctrl+Shift+F9 ([vkeyExternalBreakpoint]), which act on the editor's
  /// caret — the editor the paint left the focus in, else the one live
  /// ABAP editor on screen (a recorded session
  /// g[20] / g[32] / g[35]: the @VB@ press is the bare key round, eventid1
  /// 45, no okcode, 16/9/18 = the editor, the caret / container props as
  /// its CONTROLS; the server picks the line and answers
  /// SetMarker(4, ",<line>")). Any other key keeps its own round — the
  /// editor's owed props ride it all the same ([_pendingEditorControls]).
  SapTextEditor? _editorKeyTarget(int vkey) {
    if (answerDialect != GuiDialect.windows) return null;
    if (vkey != vkeySessionBreakpoint && vkey != vkeyExternalBreakpoint) {
      return null;
    }
    final focused = _focusedEditor;
    if (focused != null) return focused;
    final ab4 = [
      for (final e in editors)
        if (e.kind == 'ab4' && _isLiveEditor(e.shell)) e,
    ];
    return ab4.length == 1 ? ab4.single : null;
  }

  /// A click in the MARGIN of [line] (1-based) of the ABAP editor [e] —
  /// with or without a breakpoint dot on it: the OCX event BorderClick
  /// `%_GC <editor> 18` (line, ctrl, shift) the real SAP GUI for Windows
  /// sends (a recorded session g[26] / g[29]; reference client 5f8e054
  /// raw_source.editor_border_click), with ONLY the cached props that
  /// changed since the client last flushed them ([_editorDirtyControls]):
  /// after the editor's creation its container's realized 120 / 300 and
  /// the editor's LastVisibleLine (g[26]), after a scroll the view lines,
  /// otherwise nothing (g[29]). The server toggles the SESSION breakpoint
  /// of the statement holding the line and answers SetMarker(2, ",<l>") /
  /// RemoveMarker(2, ",<l>") — [SapTextEditor.breakpoints] follows that
  /// answer, nothing is assumed here. Never the external breakpoint
  /// (Ctrl+Shift+F9, [vkeyExternalBreakpoint]: the toolbar's own button).
  Future<List<Uint8List>> editorMarginClick(
    SapTextEditor e,
    int line, {
    bool ctrl = false,
    bool shift = false,
  }) {
    _requireWindowsEditor(e);
    if (e.kind != 'ab4') {
      throw UnsupportedError(
        'a margin click is the ABAP editor\'s BorderClick; '
        '${e.shell} is a ${e.kind} control',
      );
    }
    if (line < 1) throw RangeError.value(line, 'line', 'is 1-based');
    final controls = _editorDirtyControls(e);
    _trace(
      'editor ${e.shell} margin click line $line (BorderClick'
      '${ctrl ? ', ctrl' : ''}${shift ? ', shift' : ''})',
    );
    _ea.recordEvent(
      e.shell,
      borderClickParams(line, ctrl: ctrl, shift: shift),
    );
    _noteControlsFlushed(e, controls);
    return _act(
      editorBorderClickItems(
        ctx,
        shell: e.shell,
        line: line,
        ctrl: ctrl,
        shift: shift,
        controls: controls,
        path: _editorSourcePath(e.shell),
      ),
      controlEvent: true,
      dialectReady: true,
    );
  }

  /// The client values of [e]'s view / caret / line-count cached props, in
  /// the OCX's flush order (a recorded session gui[21],
  /// a recorded session g[55]; the whole order with LineCount,
  /// TextModified and Version: a recorded session
  /// g[10], the creation's answer).
  List<(String, String)> _editorClientProps(SapTextEditor e) {
    final first = _editorFirstVisible(e);
    final last = _editorLastVisible(e, first);
    final line = e.cursorLine ?? 1, col = e.cursorCol ?? 1;
    return [
      ('SelPosStartCol', '$col'),
      ('FirstVisibleLine', '$first'),
      ('LineCount', '${e.lines.isEmpty ? 1 : e.lines.length}'),
      ('SelPosEndLine', '${e.selEndLine ?? line}'),
      ('LastVisibleLine', '$last'),
      ('SelPosStartLine', '$line'),
      ('SelPosEndCol', '${e.selEndCol ?? col}'),
    ];
  }

  /// The CONTROLS a round on [e] owes: per shell, ascending, the cached
  /// props whose client value the server does not hold yet — the realized
  /// size (120 / 300) of each area-linked container on [e]'s parent chain
  /// the server did not set itself ([ControlRegistry.flushedSizes]), and
  /// [e]'s own view / caret props that differ from
  /// [SapTextEditor.serverProps]. Empty when nothing changed.
  List<(String, List<(String, String)>)> _editorDirtyControls(
    SapTextEditor e,
  ) {
    final reg = _layoutState.registry;
    final out = <String, List<(String, String)>>{};
    _areaSizes(reg.parents[e.shell]).forEach((sh, values) {
      final done = reg.flushedSizes[sh] ?? const <String, String>{};
      final dirty = [
        for (final (p, v) in values)
          if (done[p] != v) (p, v),
      ];
      if (dirty.isNotEmpty) out[sh] = dirty;
    });
    final registered = reg.cachedProps[e.shell];
    final own = [
      for (final (p, v) in _editorClientProps(e))
        if ((registered == null || registered.contains(p)) &&
            e.serverProps[p] != v)
          (p, v),
    ];
    if (own.isNotEmpty) out[e.shell] = own;
    final shells = out.keys.toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    return [for (final sh in shells) (sh, out[sh]!)];
  }

  /// The realized size props (120 / 300, the session's METRICS:
  /// [areaContainerPx]) of every shell from [start] up its parent chain
  /// that registered them as cached props, the server did not set itself
  /// and is LinkContainer'd into a custom-control area of the active (else
  /// base) screen.
  Map<String, List<(String, String)>> _areaSizes(String? start) {
    final reg = _layoutState.registry;
    final out = <String, List<(String, String)>>{};
    final seen = <String>{};
    var sh = start;
    while (sh != null && seen.add(sh)) {
      final props = reg.cachedProps[sh];
      if (props != null && _onScreen(sh)) {
        final g = _linkedArea(sh);
        if (g != null) {
          final set = reg.props[sh] ?? const <String, String>{};
          final values = <(String, String)>[
            for (final p in props)
              if ((p == '120' || p == '300') && !set.containsKey(p))
                (p, areaContainerPx(g, p)!),
          ];
          if (values.isNotEmpty) out[sh] = values;
        }
      }
      sh = reg.parents[sh];
    }
    return out;
  }

  /// Whether [e]'s control is realized as far as the server knows: every
  /// container up its parent chain that registered its size props (120 /
  /// 300) and was not sized by the server has reported them — until then
  /// the editor's view props are the first round's (the layout delta).
  bool _editorRealized(SapTextEditor e) {
    final reg = _layoutState.registry;
    final seen = <String>{};
    var sh = reg.parents[e.shell];
    while (sh != null && seen.add(sh)) {
      final props = reg.cachedProps[sh] ?? const <String>[];
      final set = reg.props[sh] ?? const <String, String>{};
      final done = reg.flushedSizes[sh] ?? const <String, String>{};
      for (final p in props) {
        if ((p == '120' || p == '300') &&
            !set.containsKey(p) &&
            !done.containsKey(p)) {
          return false;
        }
      }
      sh = reg.parents[sh];
    }
    return true;
  }

  /// The CONTROL blocks the ABAP editors on screen owe the server — the
  /// props the user changed client-side (a caret, a selection, a scroll:
  /// the app's [setEditorClientState]) or a creation left owed (the
  /// container's realized size, the view), per shell ascending — for a
  /// round of ANY kind about to go out ([built], Windows spelling): the
  /// real GUI sends nothing for a click, a selection or a scroll and
  /// folds the LAST state into the first later round, whatever it is (a
  /// key: a recorded session g[24]; a type-ahead
  /// `%_SEARCH_OKCODE`: a recorded session gui[27] — Select
  /// All (1,1)-(6,28) — and a recorded session gui[20];
  /// another control's event: the editor's own event 12, gui[25] / [26]).
  /// Recorded as flushed. A shell the round names already (an editor
  /// action's own CONTROL block) is left to it. Null when nothing is owed.
  String? _pendingEditorControls(List<Uint8List> built) {
    if (answerDialect != GuiDialect.windows) return null;
    final eds = [
      for (final e in editors)
        if (e.kind == 'ab4' && _isLiveEditor(e.shell)) e,
    ];
    if (eds.isEmpty) return null;
    final named = <String>{};
    for (final raw in built) {
      final walk = walkItems(raw);
      if (walk.items.length != 1 || walk.items.single.type != itemXmlBlob) {
        continue;
      }
      final x = wireDecode(Uint8List.fromList(walk.items.single.value));
      for (final m in RegExp(r'<CONTROL SHELLID\s*="([^"]*)"').allMatches(x)) {
        named.add(m[1]!);
      }
    }
    final out = <String, List<(String, String)>>{};
    for (final e in eds) {
      final owed = [
        for (final c in _editorDirtyControls(e))
          if (!named.contains(c.$1) && !out.containsKey(c.$1)) c,
      ];
      if (owed.isEmpty) continue;
      _noteControlsFlushed(e, owed);
      for (final (sh, props) in owed) {
        out[sh] = props;
      }
    }
    if (out.isEmpty) return null;
    final shells = out.keys.toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    _trace('editor props ride the round: ${shells.join(', ')}');
    return windowsControlBlocks([for (final sh in shells) (sh, out[sh]!)]);
  }

  /// Record [controls] as flushed: the server holds those values now.
  void _noteControlsFlushed(
    SapTextEditor e,
    List<(String, List<(String, String)>)> controls,
  ) {
    final reg = _layoutState.registry;
    for (final (sh, props) in controls) {
      if (sh == e.shell) {
        _noteEditorFlushed(e, props);
      } else {
        final done = reg.flushedSizes[sh] ??= {};
        for (final (p, v) in props) {
          done[p] = v;
        }
      }
    }
  }

  /// Record the editor props a round flushed (or a read-back answered):
  /// the server holds them now ([SapTextEditor.serverProps]).
  void _noteEditorFlushed(SapTextEditor e, List<(String, String)> props) {
    for (final (p, v) in props) {
      if (ab4InitialCachedProps.containsKey(p)) e.serverProps[p] = v;
    }
  }

  /// The where-used list (Ctrl+Shift+F3, vkey 39) of the token at ([line],
  /// [col]) of [e]: the key round with the focus in the editor and its
  /// cursor flushed (editor_actions.dart). The same key with the dynpro
  /// field cursor lists the PROGRAM's where-used instead.
  Future<List<Uint8List>> editorWhereUsed(SapTextEditor e, int line, int col) =>
      _editorKey(e, vkeyWhereUsed, line, col, EditorKeyFocus.editor);

  /// F1 on the token at ([line], [col]) of [e] with the focus INSIDE the
  /// editor: the ABAP editor's own control event 3 (`%_GC <editor> 3`,
  /// the caret under `<CONTROLS>`, the editor's container path in the
  /// 16/15/1 — editor_actions.dart [editorHelpItems], a recorded session
  /// workbench gui[75]), NOT the help-on-field key round of [fieldHelp].
  /// The server answers with SendCompletionCommand on the editor and opens
  /// the Performance Assistant (a SAPGUI.DIALOGCTRL.1 dialog: [cfwDialogs]
  /// / [htmlDocuments]) for the keyword under the caret. Windows dialect
  /// only. [press] routes F1 here by itself when the paint left the focus
  /// in a live editor (its trailing 16/9/18), at the editor's last known
  /// cursor.
  Future<List<Uint8List>> editorHelp(SapTextEditor e, int line, int col) {
    _requireWindowsEditor(e);
    _noteEditorCursor(e, line, col);
    _ea.recordEvent(e.shell, const {});
    final props = editorCursorProps(
      line,
      col,
      firstVisibleLine: e.viewFirstLine ?? e.firstVisibleLine ?? 1,
    );
    _noteEditorFlushed(e, props);
    return _act(
      editorHelpItems(
        ctx,
        shell: e.shell,
        props: props,
        path: _editorSourcePath(e.shell),
      ),
      controlEvent: true,
      dialectReady: true,
    );
  }

  /// The container path an EDITOR event's 16/15/1 carries: the custom
  /// control the editor was LinkContainer'd into ([_hostedSourcePath]),
  /// else — the editor only — the paint's ONE custom control when it
  /// declares exactly one (the SE38 editor screen: a recorded session
  /// gui[32] `01`; reference client windows_control_event_round.control_area_path
  /// without by_name_only, which 534a50c keeps for the editor alone); null
  /// when neither resolves (several custom controls and no name: nothing
  /// guessed, no 16/15/1).
  List<int>? _editorSourcePath(String shell) {
    final byName = _hostedSourcePath(shell);
    if (byName != null) return byName;
    final s = (screen?.modalLevel ?? 0) > 0 ? baseScreen : screen;
    final groups = s?.controlPaths.values.where((p) => p.isNotEmpty).toList();
    return (groups != null && groups.length == 1) ? groups.single : null;
  }

  /// The live editor the paint left the focus in (its trailing 16/9/18),
  /// or null.
  SapTextEditor? get _focusedEditor {
    final cf = ctx.paintedControlFocus;
    if (cf == null || answerDialect != GuiDialect.windows) return null;
    final e = _editorTracker[cf];
    if (e == null || e.kind != 'ab4' || !_isLiveEditor(cf)) return null;
    return e;
  }

  /// Double-click the token at ([line], [col]) of [e] — forward navigation:
  /// the server jumps to its definition (a FORM in the same source moves
  /// the cursor: `SetSelectionPosInLine` + `FirstVisibleLine`; another
  /// object opens its own screen). The ABAP editor sends its OCX line
  /// event 12 first, then the -601 double-click; a TextEdit the -601
  /// round alone. Returns both rounds' frames.
  Future<List<Uint8List>> editorNavigate(
    SapTextEditor e,
    int line,
    int col,
  ) async {
    _requireWindowsEditor(e);
    _noteEditorCursor(e, line, col);
    final out = <Uint8List>[];
    if (e.kind == 'ab4') {
      final text = line >= 1 && line <= e.lines.length ? e.lines[line - 1] : '';
      _ea.recordEvent(e.shell, ab4LineEventParams(text, line, col));
      out.addAll(
        await _act(
          ab4LineEventItems(
            ctx,
            shell: e.shell,
            lineText: text,
            line: line,
            col: col,
            path: _editorSourcePath(e.shell),
          ),
          controlEvent: true,
          dialectReady: true,
        ),
      );
    }
    _ea.recordEvent(e.shell, const {});
    // the view the user scrolled to rides the double-click's flush when it
    // is not where the server last put it (a recorded session
    // whereused gui[21]: FirstVisibleLine 184 / LastVisibleLine 227 beside
    // the caret; a recorded session gui[33]: 90 / 133)
    final view = e.viewFirstLine;
    final scrolled = view != null && view != (e.firstVisibleLine ?? 1);
    final props = editorCursorProps(
      line,
      col,
      firstVisibleLine: scrolled ? view : null,
      lastVisibleLine: scrolled ? e.viewLastLine : null,
    );
    _noteEditorFlushed(e, props);
    out.addAll(
      await _act(
        editorDoubleClickItems(
          ctx,
          shell: e.shell,
          props: props,
          path: _editorSourcePath(e.shell),
        ),
        controlEvent: true,
        dialectReady: true,
      ),
    );
    return out;
  }

  Future<List<Uint8List>> _editorKey(
    SapTextEditor e,
    int vkey,
    int line,
    int col,
    EditorKeyFocus focus,
  ) {
    _requireWindowsEditor(e);
    // the view the user scrolled to rides the key round as the control's
    // dirty props, FirstVisibleLine and LastVisibleLine both (the real
    // GUI's margin click flushes the props that changed, a recorded session
    // abap_debugger g[26] `LastVisibleLine 28`; a scrolled view both, as
    // gui[21] of a recorded session); unscrolled, the
    // reference client's FirstVisibleLine alone (a recorded session
    // reference_live step 32)
    final view = e.viewFirstLine;
    final scrolled = view != null && view != (e.firstVisibleLine ?? 1);
    _noteEditorCursor(e, line, col);
    final props = editorCursorProps(
      line,
      col,
      firstVisibleLine: view ?? e.firstVisibleLine ?? 1,
      lastVisibleLine: scrolled ? e.viewLastLine : null,
    );
    _noteEditorFlushed(e, props);
    return _act(
      editorKeyItems(
        ctx,
        vkey,
        shell: e.shell,
        props: props,
        focus: focus,
      ),
      dialectReady: true,
    );
  }

  void _requireWindowsEditor(SapTextEditor e) {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError(
        'editor actions are built for the Windows '
        'dialect only',
      );
    }
    if (_editorTracker[e.shell] == null || !_isLiveEditor(e.shell)) {
      throw StateError('no live editor control ${e.shell}');
    }
  }

  /// Report the editor control's CLIENT state as the user's view shows it:
  /// the first / last line on screen (1-based, after the user's own
  /// scrolling) and, when given, the caret ([caretLine], [caretCol],
  /// 1-based). Sends nothing: the next editor round flushes it and the
  /// server's read-back (`FirstVisibleLine(_RESULT=)`, `SelPosStartLine`,
  /// `SelPosStartCol`, … on the editor handle — the SetSavePoint flush
  /// after a double-click or a where-used key, a recorded session
  /// token_whereused srv[25] / srv[29]) is answered from it, as the real
  /// GUI answers from the control's live state (gui[22]: 184 / 208 / 30
  /// after the user scrolled). A server `FirstVisibleLine(=n)` put resets
  /// the view (the control scrolled).
  ///
  /// A selection is the caret (its start) with [selEndLine] / [selEndCol]
  /// (1-based, the column after its last character), answering the
  /// `SelPosEndLine` / `SelPosEndCol` read-backs; a caret given without
  /// them collapses the selection (a plain tap).
  void setEditorClientState(
    SapTextEditor e, {
    int? firstVisibleLine,
    int? lastVisibleLine,
    int? caretLine,
    int? caretCol,
    int? selEndLine,
    int? selEndCol,
  }) {
    if (firstVisibleLine != null && firstVisibleLine >= 1) {
      e.viewFirstLine = firstVisibleLine;
    }
    if (lastVisibleLine != null && lastVisibleLine >= 1) {
      e.viewLastLine = lastVisibleLine;
    }
    if (caretLine != null && caretLine >= 1) e.cursorLine = caretLine;
    if (caretCol != null && caretCol >= 1) e.cursorCol = caretCol;
    if (caretLine != null || caretCol != null) {
      final span = selEndLine != null &&
          selEndLine >= 1 &&
          selEndCol != null &&
          selEndCol >= 1 &&
          (selEndLine, selEndCol) != (e.cursorLine, e.cursorCol);
      e
        ..selEndLine = span ? selEndLine : null
        ..selEndCol = span ? selEndCol : null;
    }
  }

  /// The cursor an editor action flushed: the server reads it back
  /// (`SelPosStartLine(_RESULT=)`, … — [_editorPropAnswers]).
  void _noteEditorCursor(SapTextEditor e, int line, int col) {
    e
      ..cursorLine = line
      ..cursorCol = col
      ..selEndLine = null
      ..selEndCol = null;
  }

  /// VARS row -> value of the editor property read-backs a flush call
  /// carries (`FirstVisibleLine(_RESULT=)`, `SelPosStartLine(_RESULT=)`,
  /// `SelPosStartCol(_RESULT=)` on the editor handle after a double-click,
  /// step 41 of a recorded session — the reference client
  /// answered 1 / 378 / 14, the cursor it flushed): the editor's last
  /// known state — the view the app reported ([setEditorClientState]),
  /// else the server's own put. Unanswered they read blank, and the server
  /// navigates from the wrong position.
  Map<int, Uint8List> _editorPropAnswers(FlushCall call) {
    final out = <int, Uint8List>{};
    if (call.verbs.isEmpty) return out;
    final t = _editorTracker;
    if (t.all.isEmpty) return out;
    final meta = verbMeta(call);
    for (var i = 1; i <= call.verbs.length; i++) {
      final verb = call.verbs[i - 1];
      if (!_editorGetters.contains(verb)) continue;
      final m = meta[i - 1];
      final res = int.tryParse(m.result?.trim() ?? '');
      if (res == null || res < 1) continue;
      if (verbArgs(call, i).any((a) => !a.$1.startsWith('_'))) continue;
      final sh = t.editorOfHandle(
        m.objValue,
        shellOf: (h) => _ea.shellAlias[h],
        isLive: _isLiveEditor,
      );
      final e = sh == null ? null : t[sh];
      if (e == null) continue;
      final line = e.cursorLine ?? 1, col = e.cursorCol ?? 1;
      // the user's view when the app reported one, else the server's put
      final first = _editorFirstVisible(e);
      final value = switch (verb) {
        'FirstVisibleLine' => first,
        'LastVisibleLine' => _editorLastVisible(e, first),
        'SelPosStartLine' => line,
        'SelPosStartCol' => col,
        // the user's selection when the app reported one, else the
        // collapsed span on the cursor
        'SelPosEndLine' => e.selEndLine ?? line,
        'SelPosEndCol' => e.selEndCol ?? col,
        'LineCount' => e.lines.length,
        _ => 0, // TextModified, Version
      };
      // the server holds the answered value now: no later flush owes it
      _noteEditorFlushed(e, [(verb, '$value')]);
      out[res - 1] = Uint8List.fromList('$value'.codeUnits);
    }
    return out;
  }

  /// shell -> line count of every live editor with a delivered body (the
  /// layout's R4 'editor body' rung).
  Map<String, int> get _editorLines => {
    for (final e in _editorTracker.all)
      if (_isLiveEditor(e.shell) && _editorTracker.loaded.contains(e.shell))
        e.shell: e.lines.length,
  };
}

/// The ABAP editor's cached-property getters the server reads back.
const Set<String> _editorGetters = {
  'FirstVisibleLine',
  'LastVisibleLine',
  'SelPosStartLine',
  'SelPosStartCol',
  'SelPosEndLine',
  'SelPosEndCol',
  'LineCount',
  'TextModified',
  'Version',
};

/// The ABAP editor's cached props a server METHOD moves on the client (the
/// caret by `SetSelectionPosInLine`, the line count by a document load):
/// what a flush's answer reports ([SapSessionEditor._editorFlushReport]).
const Set<String> _methodMovedProps = {
  'SelPosStartCol',
  'LineCount',
  'SelPosEndLine',
  'SelPosStartLine',
  'SelPosEndCol',
};

final Expando<SapTextEditorTracker> _editorTrackers = Expando('editorTracker');
