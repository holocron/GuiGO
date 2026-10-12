part of 'sap_session.dart';

/// The client window's SIZE at runtime ([SapSession.resizeWindow]): the
/// SAP GUI for Windows reports its window in pixels on every round
/// (16/12/8, the SES dims' low bytes) and the kernel lays each dynpro out
/// for it in character cells (16/12/7 AREASIZE = the pixels over its cell,
/// [ActionContext.kernelCell]) — a custom-control area with resizing (SE38's
/// editor container), a step loop, a table control, the docking panes grow
/// with the window. When the user resizes the window over such a screen
/// the real GUI sends the RESIZE round ([windowsResizeRoundItems]: SES
/// 0x52, no okcode — a recorded session gui[13]/[14]/[19],
/// a recorded session gui[2]/[4]) and the server lays the
/// screen out again; over a size-independent screen it sends NOTHING and
/// the new geometry rides the next round (a recorded session:
/// three resizes on the SE16 initial screen, zero frames, the next round's
/// 16/12/8 carries the new window).
extension _SapSessionResize on SapSession {
  /// The size of every open window of the logon follows the client's one
  /// window (the app draws them all in the same body).
  void _applyWindowSize(int rows, int cols) {
    _screenRows = rows;
    _screenCols = cols;
    for (final win in _modes.open.values) {
      win.ctx.sizeWindow(rows, cols);
      win.ea
        ..screenRows = rows
        ..screenCols = cols;
    }
  }

  /// Whether the active screen's server layout depends on the window size —
  /// what decides, like the real GUI, whether a resize is its own round: a
  /// custom-control area (the Easy Access tree, SE38's editor), a table
  /// control or step loop, a docking / splitter pane beside the dynpro.
  bool _layoutFollowsWindow(ScreenModel s) {
    if (ctx.paintedLoop) return true;
    if (s.controlPaths.isNotEmpty || s.tableControls.isNotEmpty) return true;
    if (s.containers.values.any(
      (c) => const {4, 5, 10, 13, 14}.contains(c.kind),
    )) {
      return true;
    }
    return regions.any((r) => r.kind != 'dynpro' && r.kind != 'sash');
  }

  /// Why a resize round cannot go out now (null = it can): the geometry
  /// then rides the next round, as on the real GUI over a size-independent
  /// screen.
  String? _resizeRoundRefusal() {
    if (answerDialect != GuiDialect.windows) {
      return 'the Java GUI\'s resize round is not modelled';
    }
    if (state != SessionState.ready && !offlineReplay) {
      return 'the logon is not live (${state.name})';
    }
    final s = screen;
    if (s == null || s.program == null) return 'no screen painted';
    // a popup owes the user its answer: a resize round on it ran the popup's
    // PAI on the reference client (complaint-flpcm+20260909-104249)
    if (s.modalLevel > 0 || ctx.modalNo != 0) return 'a popup is up';
    // typed values not yet sent would go first as an Enter round (PAI)
    if (_staged.isNotEmpty) return 'typed values are staged';
    if (!_layoutFollowsWindow(s)) {
      return '${s.program}/${s.dynpro} does not depend on the window size';
    }
    return null;
  }

  Future<bool> _resizeWindow(int rows, int cols) async {
    rows = rows.clamp(SapSession.minWindowRows, SapSession.maxWindowRows);
    cols = cols.clamp(SapSession.minWindowCols, SapSession.maxWindowCols);
    if (rows == _screenRows && cols == _screenCols && ctx.windowSized) {
      return false; // the window the server already has
    }
    _applyWindowSize(rows, cols);
    _trace(
      'window resized to $rows x $cols cells '
      '(${ctx.winPxHeight} x ${ctx.winPxWidth} px)',
    );
    // before the logon / while an action runs: the size rides the logon /
    // the next round (the running one read its geometry already)
    if (busy) {
      _trace('resize round deferred: an action is running');
      return false;
    }
    final why = _resizeRoundRefusal();
    if (why != null) {
      _trace('resize round skipped: $why');
      return false;
    }
    return _exclusive('resize', () async {
      // re-checked under the lock: the screen may have moved meanwhile
      final late = _resizeRoundRefusal();
      if (late != null) {
        _trace('resize round skipped: $late');
        return false;
      }
      var items = windowsResizeRoundItems(ctx);
      items = _withFirstRound(items);
      _trace('resize round sent: $rows x $cols cells, step $step');
      await _send(clientFrame(items));
      // the reply: an OLE flush when CFW containers follow the window
      // (st04 srv[10]), answered, then the screen laid out again (srv[11])
      final all = <Uint8List>[];
      for (var i = 0; i < 60; i++) {
        if (offlineReplay && all.isNotEmpty && _inbox.isEmpty) break;
        final List<Uint8List> got;
        try {
          got = await recvTurn(
            timeout: Duration(seconds: i == 0 ? (offlineReplay ? 2 : 15) : 10),
          );
        } on PartialTurnTimeout catch (e) {
          await _driveAutomation(e.frames);
          break;
        } on TimeoutException {
          if (i == 0) _trace('resize round: no reply');
          break;
        }
        all.addAll(got);
        final sent = await _driveAutomation(got);
        if (sent == 0 && _paintsScreen(got)) break;
      }
      await _maybeLayoutRound(painted: _paintsScreen(all));
      await _drainPending();
      return true;
    });
  }
}
