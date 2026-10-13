part of 'sap_session.dart';

/// The SAP GUI for Windows F4 value-help dialog on a [SapSession] — the
/// `SAP.TABControl.1` a Windows-dialect server hosts for a dictionary /
/// internal-table F4 instead of the SAPLSDH4 hit-list dynpro (model:
/// screen/sap_value_help.dart; frames: value_help_actions.dart). The F4
/// itself is the ordinary key ([press] 4, or [gridCellValueHelp] in an
/// editable grid cell); the dialog it opens is read from
/// [valueHelpDialogs] and driven with [searchValueHelp],
/// [selectValueHelpPage], [pickValueHelpRow] and [closeValueHelp]. After
/// a pick or a close the server tears the control down (`destroyTab`,
/// `DestroyWindow`) and repaints the calling screen with the value in its
/// field — the frontend sends nothing else (a recorded session: gui[33]
/// the pick, srv[40] / [41] the teardown answered, srv[42] SAPMS01GNEW/0010
/// with Utilisateur = 114399-REP); in a grid cell
/// the value arrives as a DeltaTableModified push the session adopts
/// (sap_session_grid_edit.dart).
extension SapSessionValueHelp on SapSession {
  _ValueHelpState get _vh => _valueHelpStates[_w] ??= _ValueHelpState();

  /// Every open value-help dialog of the session, newest first: a
  /// SAP.TABControl.1 whose model arrived, not torn down, created over the
  /// current base program (a `/n` leaves the dialog behind without a
  /// teardown — the reference client's tabctl_abandoned rule).
  List<SapValueHelpDialog> get valueHelpDialogs =>
      _vh.tracker.dialogs(isLive: _onScreen, base: _valueHelpBase);

  /// The newest open value-help dialog, null when none is open.
  SapValueHelpDialog? get valueHelpDialog {
    final all = valueHelpDialogs;
    return all.isEmpty ? null : all.first;
  }

  /// The frontend's user token the control stamps into every uploaded
  /// restriction (SHLPNAME) and every pick (PID 3): the real Windows GUI
  /// sends its OS user name (`Hugo` across every capture). Defaults to this
  /// process's OS user, else `GuiGo`; at most 30 characters (SHLPNAME C30).
  String get frontendUserToken => _vh.userToken ??= _osUserToken();
  set frontendUserToken(String v) =>
      _vh.userToken = v.length > 30 ? v.substring(0, 30) : v;

  /// Run the search of [dialog]'s page [page] (default: its active page)
  /// with [restrictions] — field (the input's item id, its FIELDNAME or
  /// its label) -> value; `*` / `+` make a pattern (CP), an empty value
  /// CLEARS a pre-filled input, an input not named keeps its displayed
  /// default. Sends EVENTID 2 [page, 1001, 1, X] (a recorded session
  /// gui[25]) and answers the server's select-options pull with the
  /// DDSHSELOPTEX rows ([valueHelpSelectOptions], gui[28]); the hit list
  /// arrives as the dialog's new [SapValueHelpDialog.resultRows] (no rows
  /// when nothing matched — the restriction page stays, prefilled srv
  /// 52-53). Throws [ArgumentError] when a restriction names no field of
  /// the page, [StateError] on a result-only dialog (nothing to search).
  Future<List<Uint8List>> searchValueHelp(
    SapValueHelpDialog dialog, {
    Map<String, String> restrictions = const {},
    String? page,
  }) {
    _needWindowsValueHelp();
    final p = _valueHelpPage(dialog, page);
    final rows = valueHelpSelectOptions(p, restrictions, frontendUserToken);
    _vh.armed[dialog.shell] = rows;
    if (page != null && page != dialog.activePageId) {
      _vh.tracker.activatePage(dialog.shell, p.id);
    }
    _trace(
      'value help ${dialog.shell} search (page ${p.id}): '
      '${rows.join(', ')}',
    );
    return _valueHelpEvent(
      dialog,
      valueHelpEventItem,
      valueHelpSearchParams(p.id),
    );
  }

  /// Activate restriction page [pageId] of [dialog] (its tabs): EVENTID 8
  /// [TABCTRL, page] (a recorded session gui[64], raw 65: ME23N's PO
  /// F4, pages 11 / 15 / 16 / 13). A later [searchValueHelp] runs on it.
  Future<List<Uint8List>> selectValueHelpPage(
    SapValueHelpDialog dialog,
    String pageId,
  ) {
    _needWindowsValueHelp();
    final p = _valueHelpPage(dialog, pageId);
    _vh.tracker.activatePage(dialog.shell, p.id);
    return _valueHelpEvent(dialog, valueHelpEventPage, valueHelpPageParams(p));
  }

  /// Pick hit-list row [row] (1-based, [SapValueHelpDialog.resultRows]
  /// index + 1; [SapValueHelpDialog.rowOf] finds a key): EVENTID 4 [row, 1,
  /// key, user token, 0, 1] (a recorded session gui[33]: row 45 =
  /// 114399-REP; a result-only list sends no key, a recorded session
  /// G48). The server writes the value into the calling field (its repaint)
  /// or grid cell (the adopted DeltaTableModified) and tears the dialog
  /// down.
  Future<List<Uint8List>> pickValueHelpRow(SapValueHelpDialog dialog, int row) {
    _needWindowsValueHelp();
    if (row < 1 || row > dialog.resultRows.length) {
      throw RangeError(
        'row $row is not in the hit list of value help ${dialog.shell} '
        '(1..${dialog.resultRows.length})',
      );
    }
    final key = dialog.resultOnly ? null : dialog.keyOf(row);
    _trace(
      'value help ${dialog.shell} pick row $row '
      '(${dialog.keyField ?? 'key'} = $key)',
    );
    return _valueHelpEvent(
      dialog,
      valueHelpEventPick,
      valueHelpPickParams(row, key, frontendUserToken),
    );
  }

  /// Close [dialog] without a pick (its Fermer / Close button): EVENTID 2
  /// [page, 1002, 1, X] (a recorded session gui[18],
  /// a recorded session gui[19]).
  Future<List<Uint8List>> closeValueHelp(SapValueHelpDialog dialog) {
    _needWindowsValueHelp();
    _vh.armed.remove(dialog.shell);
    final page = dialog.activePage?.id ?? '';
    return _valueHelpEvent(
      dialog,
      valueHelpEventItem,
      valueHelpCloseParams(page),
    );
  }

  void _needWindowsValueHelp() {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError(
        'the SAP.TABControl.1 value help is a Windows-dialect control',
      );
    }
  }

  SapValueHelpPage _valueHelpPage(SapValueHelpDialog d, String? page) {
    if (d.pages.isEmpty) {
      throw StateError(
        'value help ${d.shell} is a result-only hit list: nothing to search',
      );
    }
    if (page == null) return d.activePage!;
    for (final p in d.pages) {
      if (p.id == page) return p;
    }
    throw ArgumentError(
      'value help ${d.shell} has no page $page '
      '(pages: ${[for (final p in d.pages) p.id].join(', ')})',
    );
  }

  Future<List<Uint8List>> _valueHelpEvent(
    SapValueHelpDialog d,
    int eventId,
    Map<int, String> params,
  ) {
    _ea.recordEvent(d.shell, params);
    return _act(
      valueHelpEventItems(
        ctx,
        shell: d.shell,
        eventId: eventId,
        params: params,
        controls: _gridGenericBlocks(),
      ),
      controlEvent: true,
      dialectReady: true,
    );
  }

  /// The program the dialogs of this moment open over (the base screen's).
  String? get _valueHelpBase =>
      ((screen?.modalLevel ?? 0) > 0 ? baseScreen : screen)?.program;

  /// Fold the value-help verbs and pushes of one answered flush call.
  void _foldValueHelpCall(FlushCall call, Uint8List value) {
    try {
      _vh.tracker.foldCall(
        call,
        value,
        shellOf: (t) => _ea.shellAlias[t],
        base: _valueHelpBase,
      );
    } catch (e) {
      _noteIngestFailure('value help ingest', e);
    }
  }

  /// The answer to a client-table pull of a value-help select-options sink
  /// ([url], [request] = the pull's RFC value), null for any other sink.
  Uint8List? _valueHelpPullAnswer(String url, Uint8List request) {
    final shell = _vh.tracker.takeSelectOptionsSink(url);
    if (shell == null) return null;
    _loadedSinks.remove(url);
    _propertySinks.remove(url);
    var rows = _vh.armed.remove(shell);
    if (rows == null) {
      // a search the session did not arm (the server ran it itself): the
      // displayed defaults of the active page
      final d = _vh.tracker
          .dialogs()
          .where((x) => x.shell == shell)
          .firstOrNull;
      final p = d?.activePage;
      rows = p == null
          ? const <SapValueHelpSelectOption>[]
          : valueHelpSelectOptions(p, const {}, frontendUserToken);
    }
    _trace(
      'value help $shell select-options pull answered: '
      '${rows.join(', ')}',
    );
    return valueHelpSelectOptionsAnswer(request, rows);
  }

  /// The GENERIC block of every live grid that registered the first-
  /// visible channel, ascending shell — what every Windows event round
  /// reports beside its event (f4_modes gui[25]: SU53's grid 125; me51n
  /// gui[13]: 123). A grid with a staged selection is left out: its block
  /// rides the staged state ([withGridStateXml]). A live grid that never
  /// got content reports the empty `0 / 0` (a recorded session
  /// history g[17] / g[30]: the DB50 overview's grid 180 — cell (2, 1) of
  /// splitter 175, rows 100 / 0 — beside the load history's grids).
  List<GridControlState> _gridGenericBlocks({Set<String> skip = const {}}) {
    final all = grids;
    final reg = _layoutState.registry;
    final kinds = reg.kinds();
    final shells = {
      ...all.keys,
      for (final sh in reg.cachedProps.keys)
        if (kinds[sh] == 'grid' && _onScreen(sh)) sh,
    }.toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    return [
      for (final sh in shells)
        if (!skip.contains(sh) &&
            !(gridSelections[sh]?.pending ?? false) &&
            (reg.cachedProps[sh]?.contains('FirstVisibleRow') ?? false))
          GridControlState(
            sh,
            generic: all[sh] == null ? (0, 0) : gridFirstVisible(all[sh]!),
          ),
    ];
  }
}

String _osUserToken() {
  final env = Platform.environment;
  final u = (env['USERNAME'] ?? env['USER'] ?? '').trim();
  final t = u.isEmpty ? 'GuiGo' : u;
  return t.length > 30 ? t.substring(0, 30) : t;
}

class _ValueHelpState {
  final SapValueHelpTracker tracker = SapValueHelpTracker();

  /// dialog shell -> the select-option rows its next pull answers
  final Map<String, List<SapValueHelpSelectOption>> armed = {};
  String? userToken;
}

final Expando<_ValueHelpState> _valueHelpStates = Expando('valueHelpState');
