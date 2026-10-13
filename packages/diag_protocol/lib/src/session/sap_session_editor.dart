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
  void _ingestEditorCall(Uint8List value, [FlushCall? parsed]) {
    try {
      _editorTracker.foldCall(
        value,
        shellOf: (h) => _ea.shellAlias[h],
        dpSegment: (url) => _ea.dpCache.byUrl[url],
        isLive: _isLiveEditor,
        parsed: parsed,
      );
    } catch (e) {
      _noteIngestFailure('editor ingest', e);
    }
  }

  /// Bind the editors loaded without a linked container to the screen a
  /// paint names.
  void _foldEditors(List<Uint8List> frames) {
    final t = _editorTracker;
    if (t.unbound.isEmpty || !_paintsProgram(frames)) return;
    final s = screen;
    if (s?.program == null || s?.dynpro == null) return;
    t.bindUnbound(s!.program!, s.dynpro!);
  }

  /// Set or remove a session breakpoint on [line] (1-based) of [e]: the
  /// ABAP editor's "Définir/Supprimer point d'arrêt session" key
  /// (Ctrl+Shift+F12, vkey 48) with the editor cursor on the line — the
  /// reference client's live round (a recorded session
  /// steps 32 / 35); the server toggles it and answers `SetMarker(2,
  /// ",<line>")` / `RemoveMarker(2, ",<line>")`, which update
  /// [SapTextEditor.breakpoints]. Works in display mode; session
  /// breakpoints are per user and per logon.
  Future<List<Uint8List>> editorToggleBreakpoint(SapTextEditor e, int line) =>
      _editorKey(e, vkeySessionBreakpoint, line, 1, EditorKeyFocus.dynpro);

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
    return _act(
      editorHelpItems(
        ctx,
        shell: e.shell,
        props: editorCursorProps(
          line,
          col,
          firstVisibleLine: e.viewFirstLine ?? e.firstVisibleLine ?? 1,
        ),
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
    out.addAll(
      await _act(
        editorDoubleClickItems(
          ctx,
          shell: e.shell,
          props: editorCursorProps(
            line,
            col,
            firstVisibleLine: scrolled ? view : null,
            lastVisibleLine: scrolled ? e.viewLastLine : null,
          ),
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
    return _act(
      editorKeyItems(
        ctx,
        vkey,
        shell: e.shell,
        props: editorCursorProps(
          line,
          col,
          firstVisibleLine: view ?? e.firstVisibleLine ?? 1,
          lastVisibleLine: scrolled ? e.viewLastLine : null,
        ),
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
      final first = e.viewFirstLine ?? e.firstVisibleLine ?? 1;
      final value = switch (verb) {
        'FirstVisibleLine' => first,
        'LastVisibleLine' =>
          e.viewLastLine ??
              (e.lines.isEmpty
                  ? 1
                  : (first + screenRows - 2).clamp(1, e.lines.length)),
        'SelPosStartLine' => line,
        'SelPosStartCol' => col,
        // the user's selection when the app reported one, else the
        // collapsed span on the cursor
        'SelPosEndLine' => e.selEndLine ?? line,
        'SelPosEndCol' => e.selEndCol ?? col,
        'LineCount' => e.lines.length,
        _ => 0, // TextModified, Version
      };
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

final Expando<SapTextEditorTracker> _editorTrackers = Expando('editorTracker');
