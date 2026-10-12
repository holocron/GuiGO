part of 'sap_session.dart';

/// The MENU BAR of a [SapSession] (SAP GUI's Menu / Edit / Goto / … /
/// System / Help): the painted bar ([ScreenModel.menuBar], 18/11/1), its
/// dropdowns ([ScreenModel.menuTree], 18/11/2 — delivered because the
/// logon's support bitmap sets FULL_MENU and clears SUPPBIT_WAN, the real
/// Windows GUI's non-low-speed connect; a recorded session),
/// and the click of an entry, sent as the real GUI sends it
/// (menu_actions.dart).
extension SapSessionMenu on SapSession {
  /// The entries one level under [parent] (a menu-bar header's path `[5]`,
  /// a submenu's `[5, 3]`) on the current screen, separators included.
  List<MenuEntry> menuChildrenOf(List<int> parent) =>
      menuChildren(screen?.menuTree ?? const [], parent);

  /// Fire the dropdown entry [entry] of the current screen's menu bar.
  /// [cursor] = the field of the current screen holding the user's focus
  /// (null: the okcode field, or the CFW control the paint focused) —
  /// see [selectMenuPath].
  Future<List<Uint8List>> selectMenu(
    MenuEntry entry, {
    ScreenField? cursor,
    int caret = 0,
  }) => selectMenuPath(entry.path, cursor: cursor, caret: caret);

  /// Fire the menu entry at position [path] (`[5, 11]` = the fifth menu's
  /// eleventh entry) — the real GUI's menu click: by POSITION, whatever
  /// function key the PF-status binds to the entry (menu_actions.dart).
  ///
  /// Refused before anything is sent (reference client diag_reference.menu_select): a
  /// menu-bar header (depth 1) or a submenu (an entry with children — the
  /// real GUI opens it client-side, firing it wedges the screen), a
  /// separator, and an entry the PF-status deactivated (greyed,
  /// flag_TERM_SEL clear — the kernel would only answer "function code
  /// cannot be selected"). A path the painted tree does not hold (the
  /// dropdowns withheld) is sent as given.
  ///
  /// Système > Nouvelle fenêtre GUI (vkey 74) clicked is a position round
  /// like every entry, NOT the `/O0` command (a recorded session
  /// session raw gui[5] `41 05 01`; the `/O0` of a recorded session raw
  /// gui[5] is the KEYBOARD route): the window the server opens (mode 1) is
  /// noted as the client's own. Fermer fenêtre GUI is the same position
  /// round (raw gui[8] `41 05 02`, answered `01 09`).
  ///
  /// The Windows round follows the focus (windowsMenuSelectItems): on an
  /// ABAP list window the list round (its painted list cursor); with
  /// [cursor] — the input / output field the user's focus is in, [caret]
  /// the offset inside it — OK `00 05` and that field's 16/9/11
  /// (a recorded session gui[312]); else the paint's CFW control
  /// focus (`16/9/18`, OK `00 03` on a SAP Graphics control), else the
  /// okcode field's empty 16/9/10. The Java round ignores [cursor] (its
  /// cursor'd menu click is not built).
  ///
  /// Typed-but-unsent values RIDE the Windows menu round itself — no
  /// Enter first, one PAI ([_stagedMenuRound], a recorded session
  /// raw gui[9]): the field round's 16/10/1 + 16/9/2 changed-field atoms +
  /// the 16/9/11 caret at the end of the last typed text, under the menu
  /// SES. Unrecorded combinations keep the older rule: on Java, and for
  /// typed table-control cells on Windows, the values go first as their
  /// own Enter round and the click is built on the step and paint it
  /// leaves; when that Enter leaves the screen the position was picked on
  /// (another program / dynpro / window level), stops on an error / abort
  /// message, or repaints a status where the position names another
  /// entry, the click is NOT sent ([StateError]); on a screen it kept,
  /// [cursor] is stale and the round names the screen's current cursor.
  ///
  /// The cursor is resolved against the screen the round goes out from
  /// ([_menuFocus]): [cursor] only when that field is painted on it, else
  /// the screen's CURRENT dynpro cursor ([ActionContext.paintedFocus]: the
  /// paint's 16/9/11, or the client's since — the field the real GUI's
  /// caret is in), else the paint's control focus / no focus. A stale
  /// 16/9/11 naming a cell the screen does not hold is answered "FOCUS
  /// DATA" (00 123) and the kernel ends the transaction.
  Future<List<Uint8List>> selectMenuPath(
    List<int> path, {
    ScreenField? cursor,
    int caret = 0,
  }) async {
    final p = [
      for (final x in path)
        if (x != 0) x,
    ];
    if (p.length < 2) {
      throw ArgumentError.value(
        path,
        'path',
        'a menu-bar header opens its menu, it is no entry to fire',
      );
    }
    final tree = screen?.menuTree ?? const <MenuEntry>[];
    MenuEntry? entry;
    for (final e in tree) {
      final ep = e.path;
      if (ep.length == p.length &&
          Iterable<int>.generate(p.length).every((i) => ep[i] == p[i])) {
        entry = e;
        break;
      }
    }
    final where = '${entry == null ? '' : '"${entry.text}" '}(${p.join('>')})';
    if (entry != null) {
      if (entry.separator) {
        throw ArgumentError.value(path, 'path', 'a separator, not an entry');
      }
      if (entry.submenu ||
          menuChildren(tree, p, separators: false).isNotEmpty) {
        throw ArgumentError.value(
          path,
          'path',
          'menu entry $where opens a submenu, it is no entry to fire',
        );
      }
      if (!entry.active) {
        throw StateError(
          'menu entry $where is inactive in this status (greyed): not sent',
        );
      }
    }
    final windows = answerDialect == GuiDialect.windows;
    // Système > Nouvelle fenêtre GUI (vkey 74) clicked: the position round
    // like every entry — the window it opens is the client's own
    if (entry?.vkey == newWindowVkey) _noteModeCommand(vkey: newWindowVkey);
    if (windows && _staged.isNotEmpty && !_stagedHasCells) {
      // the typed values ride the menu round itself — ONE PAI, no Enter
      // first (a recorded session raw gui[9])
      return _stagedMenuRound(p, entry, cursor);
    }
    // the typed values first: the click is built on the step they leave
    // (Java, and table-control cells on Windows: no capture pins a menu
    // round carrying either)
    final picked = screen;
    var flushed = false;
    if (_stagedHasCells) {
      await _sendStagedCellsFirst();
      flushed = true;
    }
    if (_staged.isNotEmpty) {
      await _act(_stagedRound(), consumesStaged: true);
      flushed = true;
    }
    if (flushed) {
      _menuStillPickable(picked, p, entry, where);
      // the GUI's caret is where that round's reply left it: the screen's
      // current cursor ([_menuFocus]), not the field the pick began in
      cursor = null;
      caret = 0;
    }
    if (!windows) {
      _trace('menu ${p.join('>')} ${entry?.text ?? '(not painted)'}');
      return _act(menuSelectItems(ctx, p));
    }
    final c = ctx;
    final control = c.paintedControlFocus;
    final focus = c.paintedList ? null : _menuFocus(cursor, caret);
    _trace('menu ${p.join('>')} ${entry?.text ?? '(not painted)'}'
        '${focus == null ? '' : ' cursor ${_hexOf(focus)}'}');
    return _act(
      windowsMenuSelectItems(
        c,
        p,
        list: c.paintedList,
        listCursor: c.paintedListCursor,
        cursor: focus,
        graphicsFocus: control != null &&
            _ea.createdControls.any(
                (x) => x.handle == control && isSapGraphicsClass(x.cls)),
        // a staged grid cell click rides it ([_act] merges its item 17)
        gridCellCurrent: gridSelections.values.any((g) =>
            g.pending && (g.currentRow != null || g.currentColumn != null)),
      ),
      dialectReady: true,
    );
  }

  /// The Windows menu click at [p] carrying the staged field values: the
  /// field round the Enter would send — OK `00 05`, 16/12/8, 16/12/6, the
  /// 16/10/1 head, the CHANGED fields' 16/9/2 atoms, the 16/9/11 on the
  /// last field typed with its caret at the end of the text — under the
  /// menu SES (`41 <path>`), no okcode, no 16/15/1 (a recorded session
  /// focus raw gui[9]: BELNR typed, Saut > Premier poste; the server's
  /// fiscal-year popup srv[18] answers the typed number — the same PAI as
  /// the menu function). [cursor] = the field the user's caret is in: a
  /// staged one is made the round's cursor field, another painted field
  /// names the cursor (caret 0).
  Future<List<Uint8List>> _stagedMenuRound(
    List<int> p,
    MenuEntry? entry,
    ScreenField? cursor,
  ) {
    final i = cursor == null
        ? -1
        : _staged.indexWhere((s) => _sameField(s.field, cursor));
    if (i >= 0) _staged.add(_staged.removeAt(i)); // the caret's field last
    final at = cursor == null || i >= 0
        ? null
        : screen?.fields.where((f) => _sameField(f, cursor)).firstOrNull;
    final round = windowsActionItems(
      _stagedRound(
        cursor: at == null
            ? null
            : FieldCursor(
                at.wireRow,
                at.wireCol,
                area: at.area,
                routing: at.routing,
              ),
      ),
      ctx: ctx,
      controlState: gridSelections.values.any((g) => g.pending),
      firstRound: _w.firstRoundOwed,
    );
    _trace('menu ${p.join('>')} ${entry?.text ?? '(not painted)'} with the '
        'typed values: $_staged');
    return _act(
      windowsMenuRoundOf(round, p),
      dialectReady: true,
      consumesStaged: true,
    );
  }

  /// Throws when the staged-values round that went out before a menu click
  /// left the screen [picked] the position [p] ([entry], [where]) was
  /// picked on, stopped on an error, or repainted a status that holds
  /// another entry there: the click is not sent.
  void _menuStillPickable(
    ScreenModel? picked,
    List<int> p,
    MenuEntry? entry,
    String where,
  ) {
    final now = screen;
    String why() {
      if (now == null) return 'no screen came back';
      if (picked != null &&
          _screenIdentity(now) != _screenIdentity(picked)) {
        return 'it opened ${now.program}/${now.dynpro}'
            '${now.modalLevel > 0 ? ' (a popup)' : ''}';
      }
      // an error / abort (4): PAI stopped before any function ran
      if (now.messageSeverity >= 4) return 'it stopped on "${now.message}"';
      if (entry == null) return '';
      MenuEntry? again;
      for (final e in now.menuTree) {
        if (e.path.length == p.length &&
            Iterable<int>.generate(p.length).every((i) => e.path[i] == p[i])) {
          again = e;
          break;
        }
      }
      if (again == null && now.menuTree.isEmpty) return ''; // not repainted
      if (again == null ||
          again.text != entry.text ||
          !again.active ||
          again.separator) {
        return 'its menu holds ${again == null ? 'no entry' : '"${again.text}"'}'
            ' at ${p.join('>')}';
      }
      return '';
    }

    final reason = why();
    if (reason.isEmpty) return;
    _trace('menu ${p.join('>')} not sent: the typed values went out first '
        'and $reason');
    throw StateError(
      'the typed values went out first (Enter) and $reason: menu entry '
      '$where was not sent — pick it again on this screen',
    );
  }

  /// The dynpro cursor (16/9/11 server form) a Windows menu round names —
  /// resolved against the screen it goes out from:
  ///
  /// * [f] (the field the user's focus is in, [caret] inside it) when the
  /// current screen paints it — by identity, else the same field
  /// (name, container, area, wire cell) of a repaint — spelled as the
  /// pinned rounds spell a cursor on that field type: a table-control
  /// cell `[depth][line u16][column u16][caret u32][control path]` (the
  /// table-plane rounds' [tcFocusBytes], reference client
  /// mode_envelope.tc_cursor_geometry), any other element its wire cell
  /// and container path ([elementCursorBytes]: the F4 / F1 cursor,
  /// a recorded session gui[4], a recorded session
  /// gui[10]; a step-loop line `01 <line> 0000 <caret> 01`,
  /// a recorded session gui[19]);
  /// * else the screen's CURRENT cursor ([ActionContext.paintedFocus],
  /// the latest paint's 16/9/11 or the cursor a round sent since), when
  /// it belongs to this window and no CFW control holds the focus — the
  /// real GUI's caret (every Windows menu round of the corpus names the
  /// focus the paint declared unless the user moved it: srv[1596] 9/18
  /// -> su53 gui[1310], stms srv[27] -> gui[20], picker srv[30] ->
  /// gui[29], the 16/9/10 paints -> the empty 16/9/10 of wingui_session
  /// gui[22] / [24] / [26], trees gui[130], st04 gui[76]);
  /// * else null: the paint's control focus or the no-focus round.
  Uint8List? _menuFocus(ScreenField? f, int caret) {
    final m = screen;
    if (m == null) return null;
    final here = f == null
        ? null
        : (m.fields.where((x) => identical(x, f)).firstOrNull ??
            m.fields.where((x) => _sameField(x, f)).firstOrNull);
    if (here != null) {
      final tcName = here.tableControl;
      if (tcName == null) return elementCursorBytes(here, caret: caret);
      final tc = m.tableControls.where((t) => t.name == tcName).firstOrNull;
      if (tc != null && here.tcLine != null && here.tcColumn != null) {
        return tcFocusBytes(here.tcLine!, here.tcColumn!, tc.focusPath,
            offset: caret < 0 ? 0 : caret);
      }
    }
    if (f != null) {
      _trace('menu cursor ${f.name} (${f.wireRow},${f.wireCol}) is not '
          'painted on ${m.program}/${m.dynpro}: dropped');
    }
    final pf = ctx.paintedFocus;
    if (ctx.paintedControlFocus != null ||
        pf == null ||
        pf.length < 10 ||
        pf.sublist(1, 5).every((b) => b == 0) ||
        ctx.focusLevel != m.modalLevel ||
        (ctx.focusScreen != null && ctx.focusScreen != _screenIdentity(m))) {
      return null;
    }
    return Uint8List.fromList(pf);
  }
}

String _hexOf(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
