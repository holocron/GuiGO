part of 'sap_session.dart';

/// The calendar control on a [SapSession] — the `SAP.CalendarControl.1`
/// (sapcalen.ocx) a server hosts in a popup for F4 on a date (DATS) field
/// (model: screen/sap_calendar.dart; frames: calendar_actions.dart). The
/// F4 itself is the ordinary key ([valueHelp] / [press] 4); the calendar it
/// opens is read from [calendars] / [calendarFor], its region from
/// [modalRegions] (kind 'calendar', the popup's custom-control area), and
/// a day is picked with [pickCalendarDate]. The server then tears the
/// control down (DestroyWindow on the calendar and its container) and
/// repaints the calling screen with the date in the field — the frontend
/// sends nothing else (a recorded session gui[6] the pick, srv[6] the
/// teardown answered by gui[7], srv[7] RM06ENDR_ALV/1000 with S_BEDAT-LOW
/// = 01.09.2026).
///
/// No calendar control is ever invented client-side: when the server
/// answers F4 on a date field with something else (a dynpro popup, a
/// message, nothing), that is what the session shows ([fieldShowsDate]
/// tells a caller the field held a date).
extension SapSessionCalendar on SapSession {
  _CalendarState get _cal => _calendarStates[_w] ??= _CalendarState();

  /// Every open calendar control of the session, newest first: created
  /// over the current base program, not torn down, on screen.
  List<SapCalendarModel> get calendars =>
      _cal.tracker.calendars(isLive: _onScreen, base: _calendarBase);

  /// The open calendar on [shell], null when none is.
  SapCalendarModel? calendarFor(String shell) {
    for (final c in calendars) {
      if (c.shell == shell.trim()) return c;
    }
    return null;
  }

  /// Pick [from] (through [to] for a range; default the single day) on
  /// calendar [c]: `%_GC <shell> 3` with PARAMs [from, to, "0"] in
  /// YYYYMMDD, in the generic Windows control-event envelope — the real
  /// GUI's pick item for item (a recorded session gui[6]: the modal
  /// SES, 16/4/36 after the okcode, OK mode 03, the popup's painted
  /// 16/12/6, the 16/15/1 control source at the custom-control area the
  /// calendar's container is linked into — only then, reference client 534a50c §3 —
  /// `16/9/18 <calendar>`, the EVENTS + the container's cached 120 / 300).
  /// The server writes the date into the calling field and closes the
  /// popup. Throws [UnsupportedError] off the Windows dialect, [StateError]
  /// when [c] is no longer open, [ArgumentError] for a range ending before
  /// it starts.
  Future<List<Uint8List>> pickCalendarDate(
    SapCalendarModel c,
    DateTime from, [
    DateTime? to,
  ]) async {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError(
        'the calendar pick is built in the SAP GUI for Windows spelling '
        '(the Java GUI\'s pick is not built)',
      );
    }
    if (calendarFor(c.shell) == null) {
      throw StateError('calendar ${c.shell} is not open');
    }
    final params = calendarPickParams(from, to); // validates the range
    await _flushStagedFirst();
    _ea.recordEvent(c.shell, {
      for (var i = 0; i < params.length; i++) i: params[i],
    });
    _trace('calendar ${c.shell} pick ${params[0]}..${params[1]}');
    return _act(
      calendarPickItems(
        ctx,
        shell: c.shell,
        from: from,
        to: to,
        sourcePath: _calendarSourcePath(c.shell),
        controls: _calendarControls(c),
      ),
      dialectReady: true,
    );
  }

  /// The program the calendars of this moment open over.
  String? get _calendarBase =>
      ((screen?.modalLevel ?? 0) > 0 ? baseScreen : screen)?.program;

  /// Fold the calendar verbs and pushes of one answered flush call; returns
  /// the call's calendar `_RESULT` answers by VARS row — the interval the
  /// control holds for each InitViewers / CalcInterval, the real GUI's
  /// answer ([calendarHeldInterval], in the session's [answerDialect]: the
  /// Windows OCX and the Java jar hold different intervals). A blank
  /// answer is what the server cannot read as a date: it aborts the
  /// transaction (the test system ME2N F4 on an empty S_BEDAT-LOW, 2026-10-11:
  /// SAPMSDYP "DATE_FROM possède la valeur non valide").
  Map<int, Uint8List> _foldCalendarCall(
    FlushCall call,
    Uint8List value, {
    int step = 0,
  }) {
    try {
      final t = _cal.tracker;
      t.foldCall(
        call,
        value,
        shellOf: (t) => _ea.shellAlias[t],
        base: _calendarBase,
        dialect: answerDialect,
        step: step,
      );
      return {
        for (final e in t.answers.entries)
          e.key: Uint8List.fromList(e.value.codeUnits),
      };
    } catch (e) {
      _noteIngestFailure('calendar ingest', e);
      return const {};
    }
  }

  /// The calendar shells the composition draws as a month grid.
  Set<String> get _calendarShells => {for (final c in calendars) c.shell};

  /// The 16/15/1 path of a pick on [shell]: the custom-control area of the
  /// ACTIVE window its container is linked into — the popup's own
  /// CONTAINER (a recorded session srv[4]: SAPLSCAC/0100 declares it
  /// at level 1; gui[6] `0001 01`) — else the base screen's
  /// ([_hostedSourcePath]); null for a docked / dialog-hosted calendar.
  List<int>? _calendarSourcePath(String shell) {
    final s = screen;
    if (s != null && s.modalLevel > 0) {
      final p = _areaPathOf(shell, s);
      if (p != null) return p;
    }
    return _hostedSourcePath(shell);
  }

  /// The [ScreenModel.controlPaths] entry of the area [shell] (or its
  /// nearest CreateControl ancestor) was LinkContainer'd into on [s].
  List<int>? _areaPathOf(String shell, ScreenModel s) {
    final reg = _layoutState.registry;
    var sh = shell.trim();
    final seen = <String>{};
    while (seen.add(sh)) {
      for (final e in reg.areaLinks.entries) {
        if (e.value.$1 != sh) continue;
        final area = e.key.trim().toUpperCase();
        for (final g in s.controlPaths.entries) {
          if (g.key.trim().toUpperCase() == area && g.value.isNotEmpty) {
            return g.value;
          }
        }
      }
      final parent = reg.parents[sh];
      if (parent == null) break;
      sh = parent;
    }
    return null;
  }

  /// The CONTROLS block of a pick: every shell on the calendar's container
  /// chain that registered the cached sizes 120 / 300 (RegisterCachedProp,
  /// a recorded session srv[1] on 115) the server did not set itself,
  /// linked into a custom-control area of the active (else base) screen —
  /// its size in the session's METRICS ([areaContainerPx]). The real GUI
  /// reports 115 `120 = 141, 300 = 327` beside the event (gui[6]).
  Map<String, List<(String, String)>> _calendarControls(SapCalendarModel c) {
    final reg = _layoutState.registry;
    final out = <String, List<(String, String)>>{};
    final screens = [?screen, ?baseScreen];
    var sh = c.shell;
    final seen = <String>{};
    while (seen.add(sh)) {
      final props = reg.cachedProps[sh];
      if (props != null) {
        ScreenContainer? g;
        for (final e in reg.areaLinks.entries) {
          if (e.value.$1 != sh) continue;
          for (final s in screens) {
            g =
                s.containers[e.key] ??
                s.containers.entries
                    .where((x) => x.key.toUpperCase() == e.key)
                    .map((x) => x.value)
                    .firstOrNull;
            if (g != null) break;
          }
          if (g != null) break;
        }
        if (g != null) {
          final set = reg.props[sh] ?? const <String, String>{};
          final values = <(String, String)>[
            for (final p in props)
              if ((p == propControlHeight || p == propControlWidth) && !set.containsKey(p))
                (p, areaContainerPx(g, p)!),
          ];
          if (values.isNotEmpty) out[sh] = values;
        }
      }
      final parent = reg.parents[sh];
      if (parent == null) break;
      sh = parent;
    }
    return out;
  }
}

class _CalendarState {
  final SapCalendarTracker tracker = SapCalendarTracker();
}

final Expando<_CalendarState> _calendarStates = Expando('calendarState');
