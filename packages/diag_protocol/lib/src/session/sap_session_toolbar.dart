part of 'sap_session.dart';

/// CFW CONTROL TOOLBARS on a [SapSession] (cfw/control_toolbar.dart for
/// the wire shapes and their real-GUI oracles): the OO-ALV grid's built-in
/// toolbar ([SapGridModel.toolbar]) and the standalone SAP.Toolbar.1
/// control (AddButton / ButtonGroupData), their buttons pressed and their
/// menu buttons' menus opened — a static menu at once, without a server
/// round, an on-demand one by the dropdown event, the server answering
/// with the menu ([pendingContextMenu]); an entry is chosen with
/// [pickContextMenu]. Windows dialect only.
extension SapSessionToolbar on SapSession {
  _ToolbarState get _tbState => _toolbarStates[_w] ??= _ToolbarState();

  /// The control toolbars of the current screen by the shell their events
  /// go to: every live grid's built-in toolbar ([SapControlToolbarKind.
  /// grid], keyed by the grid shell) and every live, shown SAP.Toolbar.1
  /// control with buttons ([SapControlToolbarKind.standalone]).
  Map<String, SapControlToolbar> get controlToolbars {
    final out = <String, SapControlToolbar>{};
    grids.forEach((sh, g) {
      if (g.toolbar.isEmpty) return;
      out[sh] = SapControlToolbar(
        shell: sh,
        kind: SapControlToolbarKind.grid,
        buttons: g.toolbar,
        staticMenus: g.toolbarMenus,
      );
    });
    final kinds = _layoutState.registry.kinds();
    _htmlState.toolbars.forEach((sh, buttons) {
      if (buttons.isEmpty || kinds[sh] != 'toolbar') return;
      if (!_onScreen(sh) || !_shellVisible(sh)) return;
      out[sh] = SapControlToolbar(
        shell: sh,
        kind: SapControlToolbarKind.standalone,
        buttons: List.unmodifiable(buttons),
        staticMenus: Map.unmodifiable(_tbState.staticMenus[sh] ?? const {}),
      );
    });
    return out;
  }

  /// The control toolbar whose events go to [shell], or null.
  SapControlToolbar? controlToolbarOf(String shell) =>
      controlToolbars[shell.trim()];

  /// Press button [fcode] of the toolbar of [shell] — a plain button, a
  /// check button, the BODY of a split menu button (type 1): on a grid
  /// `%_GC <grid> 10` PARAM 0 = [fcode] (a recorded session gui[95] SM12
  /// `DETAILS`; a recorded session gui[237] the split `&MB_FILTER`),
  /// on a standalone toolbar `%_GC <toolbar> 1` ([cfwToolbarButton]). A
  /// selection staged on a grid rides the same frame (the real GUI's
  /// cached-property flush with the next event). Refused, nothing sent:
  /// an unknown, disabled or separator button ([ArgumentError]), a menu-
  /// only button (type 2: [toolbarDropdown] opens it), a grid that did
  /// not register the event ([StateError]).
  Future<List<Uint8List>> toolbarButton(String shell, String fcode) async {
    _windowsOnly('a control toolbar button');
    final tb = _toolbarFor(shell);
    final b = _buttonOf(tb, fcode);
    if (b.type == toolbarButtonMenu) {
      throw ArgumentError(
        '${b.code} of toolbar ${tb.shell} is a menu button: its press opens '
        'the menu (toolbarDropdown) — nothing sent',
      );
    }
    if (tb.kind == SapControlToolbarKind.standalone) {
      return cfwToolbarButton(tb.shell, b.code);
    }
    _requireGridEvent(tb.shell, gridEventToolbarButton);
    await _flushStagedFirst();
    _trace('grid ${tb.shell} toolbar button ${b.code}');
    return _act(
      _gridToolbarEventItems(tb.shell, gridEventToolbarButton, [b.code]),
      controlEvent: true,
      dialectReady: true,
    );
  }

  /// Open the menu of menu button [fcode] (type 1's arrow, type 2's whole
  /// button) of the toolbar of [shell]. A STATIC menu (SetToolBarMenuStatic
  /// / SetStaticCtxMenu) opens at once — nothing is sent, the real GUI
  /// tracks it locally (a recorded session: no frame before gui[231]'s
  /// pick). Otherwise the dropdown event asks the server — on a grid `%_GC
  /// <grid> 11` PARAMs fcode, [x], [y] (a recorded session gui[85]
  /// `REQUEST_DATA` 585 596), on a standalone toolbar `%_GC <toolbar> 2`
  /// (a recorded session gui[1] `SELECT` 1940 263); [x] / [y]
  /// are the button's screen position, which the server only echoes back
  /// to place the popup. Either way the menu is [pendingContextMenu]
  /// afterwards (null when the server pushed none); its entry goes out
  /// with [pickContextMenu]. Returns the frames of the server's answer
  /// (empty for a static menu).
  Future<List<Uint8List>> toolbarDropdown(
    String shell,
    String fcode, {
    int x = 0,
    int y = 0,
  }) async {
    _windowsOnly('a control toolbar menu');
    final tb = _toolbarFor(shell);
    final b = _buttonOf(tb, fcode, unknownType: toolbarButtonMenu);
    if (!b.hasMenu) {
      throw ArgumentError(
        '${b.code} of toolbar ${tb.shell} is no menu button (type ${b.type})'
        ' — nothing sent',
      );
    }
    final grid = tb.kind == SapControlToolbarKind.grid;
    final kind = grid
        ? SapContextMenuKind.gridToolbar
        : SapContextMenuKind.toolbar;
    final entries = tb.staticMenus[b.code];
    if (entries != null && entries.isNotEmpty) {
      final st = _ctxMenu..clear();
      st.menus[tb.shell] = SapContextMenu(
        shell: tb.shell,
        kind: kind,
        entries: entries,
        url: '',
        targetKey: b.code,
        step: step,
      );
      final s = screen;
      if (s != null) st.screens[tb.shell] = _screenIdentity(s);
      st.newest = tb.shell;
      _trace('toolbar ${tb.shell} static menu ${b.code} opened locally');
      return const [];
    }
    if (grid) _requireGridEvent(tb.shell, gridEventToolbarMenuButton);
    await _flushStagedFirst();
    final params = [b.code, '$x', '$y'];
    _ea.recordEvent(tb.shell, {for (final (i, p) in params.indexed) i: p});
    final List<Uint8List> items;
    if (grid) {
      items = _gridToolbarEventItems(
        tb.shell,
        gridEventToolbarMenuButton,
        params,
        record: false,
      );
    } else {
      items = cfwEventItems(
        ctx,
        shell: tb.shell,
        eventId: toolbarEventDropDownClicked,
        params: params,
        sourcePath: _hostedSourcePath(tb.shell),
      );
    }
    return _ctxSend(items, (tb.shell, b.code, null));
  }

  // --- internals ----------------------------------------------------------

  SapControlToolbar _toolbarFor(String shell) {
    final sh = shell.trim();
    final tb = controlToolbarOf(sh);
    if (tb != null) return tb;
    // a live SAP.Toolbar.1 whose buttons the session could not tie to it
    // (AddButton on an object token it never minted — an offline replay
    // of another client's wire): its events are still the toolbar's
    if (_layoutState.registry.kinds()[sh] == 'toolbar' &&
        _onScreen(sh) &&
        _shellVisible(sh)) {
      return SapControlToolbar(
        shell: sh,
        kind: SapControlToolbarKind.standalone,
        buttons: const [],
      );
    }
    throw ArgumentError('no control toolbar on shell $shell — nothing sent');
  }

  SapToolbarButton _buttonOf(
    SapControlToolbar tb,
    String fcode, {
    int unknownType = toolbarButtonPlain,
  }) {
    if (tb.buttons.isEmpty) {
      _trace('toolbar ${tb.shell}: buttons unknown, $fcode sent as given');
      return SapToolbarButton(code: fcode.trim(), type: unknownType);
    }
    final b = tb.button(fcode.trim());
    if (b == null) {
      throw ArgumentError(
        '"$fcode" is no button of toolbar ${tb.shell} '
        '(${tb.buttons.where((x) => !x.separator).map((x) => x.code).join(', ')})'
        ' — nothing sent',
      );
    }
    if (!b.enabled) {
      throw ArgumentError(
        '${b.code} of toolbar ${tb.shell} is disabled — nothing sent',
      );
    }
    return b;
  }

  /// The grid fires only the events it registered (GuiShell.
  /// fireCtlEventAllowed); a grid whose registrations the session did not
  /// see is let through.
  void _requireGridEvent(String shell, int eventId) {
    if (!gridHandlesEvent(shell, eventId)) {
      final reg = _canvasState.tracker.registeredEvents[shell]!.toList()
        ..sort();
      throw StateError(
        'grid $shell did not register EVENTID $eventId (it handles $reg): '
        'SAP GUI does not fire it — nothing sent',
      );
    }
  }

  /// A grid toolbar event (10 / 11 / 14) with its PARAMs: the GridView's
  /// first-visible GENERIC beside every other grid's (a recorded session
  /// gui[95]: CONTROL 126..129, no property), and — when a selection is
  /// staged — the staged DATACHANGES / CONTROL blocks in its place,
  /// consumed by this frame.
  List<Uint8List> _gridToolbarEventItems(
    String shell,
    int eventId,
    List<String> params, {
    bool record = true,
  }) {
    final staged = _pendingGridXml();
    final String xml;
    if (staged != null) {
      final head = ocxDataManagerXml(
        tables: staged.$1,
        eventShell: shell,
        eventId: eventId,
        eventParams: params,
      );
      final e = head.lastIndexOf('</DATAMANAGER>');
      if (e < 0) {
        // no document close to splice before (never from the builder):
        // the staged state stays staged for the next round, never a
        // RangeError out of the action
        xml = head;
      } else {
        xml =
            '${head.substring(0, e)} <CONTROLS>${staged.$2}</CONTROLS>'
            '${head.substring(e)}';
        _gridStateFlushed(); // it rides this frame, not the next one
      }
    } else {
      xml = ocxDataManagerXml(
        eventShell: shell,
        eventId: eventId,
        eventParams: params,
        controls: _toolbarGenerics(shell),
      );
    }
    if (record) {
      _ea.recordEvent(shell, {for (final (i, p) in params.indexed) i: p});
    }
    return gridEventItems(
      ctx,
      shell: shell,
      eventId: eventId,
      xml: xml,
      path: _hostedSourcePath(shell),
    );
  }

  /// The first-visible GENERIC of every live GridView on the screen that
  /// registered the generic first-visible channel `FirstVisibleRowID`
  /// (the reference client's grid_first_visible.registers_generic), in shell order.
  /// a recorded session gui[95] (and gui[93]): CONTROL 126 (no field
  /// catalog: FVCID 0 FVRID 0), 127 (rows: 1 / its first visible row),
  /// 128 / 129 (a catalog, no rows: FVCID 1 FVRID 0) — the column half
  /// follows the catalog, the row half the rows (the reference client's
  /// windows_generic; a recorded session the same).
  List<GridControlState> _toolbarGenerics(String shell) {
    final reg = _layoutState.registry;
    final kinds = reg.kinds();
    final all = grids;
    final shells =
        <String>{
          if (all.containsKey(shell)) shell,
          for (final e in reg.cachedProps.entries)
            if (kinds[e.key] == 'grid' &&
                e.value.contains('FirstVisibleRowID') &&
                _onScreen(e.key) &&
                (e.key == shell || !(gridSelections[e.key]?.pending ?? false)))
              e.key,
        }.toList()..sort(
          (a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0),
        );
    return [
      for (final sh in shells)
        GridControlState(
          sh,
          generic: (
            (all[sh]?.columns.isNotEmpty ?? false) ? 1 : 0,
            (all[sh]?.loadedRows.isNotEmpty ?? false)
                ? all[sh]!.firstVisibleRow
                : 0,
          ),
        ),
    ];
  }

  /// The grid shell a server object token names (the owner its pushes
  /// carried — SetToolBarMenu runs on the grid object by that token).
  String? _gridShellOfOwner(String token) {
    for (final e in _gridAsm.entries) {
      if (e.value.owner == token) return e.key;
    }
    return null;
  }

  // --- fold (sap_session.dart flush loop) ----------------------------------

  /// A standalone toolbar's own verbs beyond AddButton / SetButtonState
  /// (sap_session_html.dart): its static menus (`SetStaticCtxMenu(fcode,
  /// <menu>)`), the `ButtonGroupData` push that hands it a button group
  /// (CL_GUI_TOOLBAR add_button_group — a recorded session)
  /// and `DeleteAllButtons`.
  void _foldToolbarCall(Uint8List value, FlushCall call) {
    final kinds = _layoutState.registry.kinds();
    final meta = verbMeta(call);
    final rowShell = <String, String>{};
    for (var i = 1; i <= call.verbs.length; i++) {
      if (!call.verbs[i - 1].startsWith('CreateControl')) continue;
      final sh = (verbNamedArgs(call, i)['#1'] ?? '').trim();
      final res = i <= meta.length ? (meta[i - 1].result ?? '').trim() : '';
      if (res.isNotEmpty && _isShellId(sh)) rowShell[res] = sh;
    }
    bool tb(String? sh) => sh != null && kinds[sh] == 'toolbar';
    String? toolbarOf(String row, String handle, [String? fcode]) {
      final r = rowShell[row];
      if (tb(r)) return r;
      if (tb(handle)) return handle;
      final a = _ea.shellAlias[handle];
      if (tb(a)) return a;
      if (fcode != null) {
        for (final e in _htmlState.toolbars.entries) {
          if (e.value.any((b) => b.code == fcode)) return e.key;
        }
      }
      return null;
    }

    final st = _tbState;
    // a re-created toolbar starts without menus
    for (final sh in rowShell.values) {
      if (tb(sh)) st.staticMenus.remove(sh);
    }
    for (var i = 1; i <= call.verbs.length; i++) {
      if (call.verbs[i - 1] != 'DeleteAllButtons') continue;
      final m = meta[i - 1];
      final sh = toolbarOf(m.obj.trim(), m.objValue.trim());
      // (the buttons themselves: sap_session_html.dart, in queue order)
      if (sh != null) st.staticMenus.remove(sh);
    }
    DpCache? own;
    for (final b in dpPushBindings(call)) {
      if (b.role != 'ButtonGroupData') continue;
      final s = b.shell?.trim() ?? '';
      final o = b.owner?.trim() ?? '';
      final sh = tb(s) ? s : toolbarOf('', o);
      if (sh == null) continue;
      for (final u in b.urls) {
        // the call's own pushes indexed ONCE (they were re-snooped per url
        // the session cache lacks)
        final seg = _ea.dpCache.byUrl[u] ??
            (own ??= DpCache()..ingestValue(value)).byUrl[u];
        if (seg == null) continue;
        final buttons = decodeToolbarButtonsPush(seg);
        if (buttons.isEmpty) continue;
        final list = _htmlState.toolbars[sh] ??= [];
        for (final nb in buttons) {
          if (nb.code.isNotEmpty) list.removeWhere((x) => x.code == nb.code);
          list.add(nb);
        }
        // the composition draws a toolbar in its box by the buttons the
        // layout registry holds (render_stacked.draw_toolbars), which only
        // AddButton fed: a toolbar filled by a button group alone took no
        // region and was never drawn — SE80's browser selection 133 and
        // its tree toolbar 154 in the Repository Browser dock
        // (a recorded session srv[10] / srv[12])
        final codes = _layoutState.registry.toolbarButtons[sh] ??= [];
        for (final nb in buttons) {
          if (nb.code.isNotEmpty && !codes.contains(nb.code)) {
            codes.add(nb.code);
          }
        }
        _trace('toolbar $sh: ButtonGroupData ${buttons.length} button(s)');
      }
    }
    for (final v in toolbarMenuVerbsOf(call)) {
      if (v.verb != toolbarStaticMenuVerb) continue;
      final fcode = v.fcode ?? '';
      if (fcode.isEmpty) continue;
      final sh = toolbarOf(v.objRow, v.handle, fcode);
      if (sh == null) continue;
      final entries = toolbarMenuEntries(
        v,
        value,
        segment: (u) => _ea.dpCache.byUrl[u],
      );
      if (entries.isEmpty) continue;
      (st.staticMenus[sh] ??= {})[fcode] = entries;
      _trace('toolbar $sh: static menu $fcode (${entries.length} entries)');
    }
  }
}

final Expando<_ToolbarState> _toolbarStates = Expando('toolbarState');

class _ToolbarState {
  /// standalone toolbar shell -> fcode -> its static menu
  final Map<String, Map<String, List<SapMenuEntry>>> staticMenus = {};
}
