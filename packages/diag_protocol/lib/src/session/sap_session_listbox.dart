part of 'sap_session.dart';

/// The classic dynpro DROPDOWN LISTBOX (etype 126) on a [SapSession]: its
/// entries ([listboxValueSet]), the value-set request the SAP GUI for
/// Windows owes after a paint showing a listbox whose set it does not hold
/// ([_maybeValueSetRequest]) and the pick ([pickListbox]). Wire contract:
/// screen/listbox_valueset.dart (atom, push, cache) and frontend_profile
/// .dart ([windowsValueSetRequestItems], [windowsListboxPickItems]).
extension SapSessionListbox on SapSession {
  /// The value set of listbox [f] (its entries), null while the frontend
  /// holds none for its id — not pushed yet, or [f] is no listbox.
  ValueSet? listboxValueSet(ScreenField f) {
    final id = f.listbox?.id;
    if (id == null || id.isEmpty) return null;
    return _ea.valueSets[id];
  }

  /// The value set named [id] (a listbox atom's value-set id).
  ValueSet? valueSet(String id) => _ea.valueSets[id];

  /// The frontend holds the sets [ids] already: no request is owed for
  /// them ([ValueSetStore.assumeHeld] — a replay of a warm-cache GUI).
  void assumeValueSetsHeld(Iterable<String> ids) =>
      _ea.valueSets.assumeHeld(ids);

  /// The value-set request round, when the paint just settled shows
  /// listboxes whose sets the frontend does not hold (SAP GUI for Windows
  /// only — the Java GUI is pushed every set unasked, a recorded session
  /// java): `%_GS 0 1` with one BLOBS REQUEST per unheld id, in paint
  /// order, each id asked once (SAPfront.dll `AppendValuesetRequest: value
  /// set '%s' has been requested before.`) — what a recorded session
  /// cache2 gui[14] sends right after srv[17]. The server answers with the
  /// `application/x-sapvaluesets` pushes (folded at ingest into
  /// [EaSession.valueSets]) and a repaint. Whatever the window's mode: a
  /// PROTECTED (display) listbox is asked for too (a recorded session
  /// windows srv[33] attr e1 → gui[22]; cold_cache2 attr c1).
  Future<void> _maybeValueSetRequest({required bool painted}) async {
    void skip(String why) => _trace('value-set request skipped: $why');
    if (answerDialect != GuiDialect.windows) return;
    if (!painted) return;
    final s = screen;
    if (s == null) return;
    final ids = _ea.valueSets.missing([
      for (final f in s.fields)
        if (f.listbox case final lb?) lb.id,
    ]);
    if (ids.isEmpty) return;
    if (loggedOff) return skip('logged off');
    _ea.valueSets.requested.addAll(ids);
    _trace('value-set request sent for ${ids.join(', ')} (step $step)');
    // a screen with live controls reports their state beside the request
    // (a recorded session gui[26]: every grid's first-visible
    // GENERIC, the new LOAD_HISTORY_CONTAINER 261's realized 120 / 300) —
    // the docks' extents are the layout round's, reported there
    var controls = '';
    final dyn = regions.where((r) => r.kind == 'dynpro').firstOrNull;
    if (s.modalLevel == 0 && dyn != null) {
      final classes = _layoutState.registry.classes();
      final report = [
        for (final c in _controlsReport(s, dyn.rect, _layoutState.window))
          if (!(classes[c.shell] ?? '').toUpperCase().contains('DOCKING')) c,
      ];
      if (report.isNotEmpty) {
        final x = windowsControlsXml(report);
        final at = x.indexOf('<DATAMANAGER>') + '<DATAMANAGER>'.length;
        controls = x.substring(at, x.lastIndexOf('</DATAMANAGER>'));
      }
    }
    final items = _withFirstRound(
      windowsValueSetRequestItems(ctx, ids, controls: controls),
    );
    await _send(clientFrame(items));
    // the reply: the push(es), then the repaint — within one deadline, not
    // per turn: 60 turns of 10 s each held the session 10 minutes
    final until = DateTime.now().add(const Duration(minutes: 2));
    for (var i = 0; i < 60; i++) {
      final left = until.difference(DateTime.now());
      if (left <= Duration.zero) break;
      final turn = Duration(seconds: i == 0 ? (offlineReplay ? 2 : 30) : 10);
      final List<Uint8List> got;
      try {
        got = await recvTurn(timeout: turn < left ? turn : left);
      } on TimeoutException {
        if (i == 0) _trace('value-set request: no reply');
        break;
      }
      final sent = await _driveAutomation(got);
      if (sent == 0 && _paintsScreen(got)) break;
    }
    await _drainPending();
  }

  /// Pick [key] in listbox [f] of the active window. A PROTECTED (display-
  /// mode) listbox refuses it locally, as the real GUI does (no frame —
  /// a recorded session: the D pick in display mode sent nothing): a
  /// [StateError]. A key outside the held entry list is refused too (the
  /// kernel would discard it): an [ArgumentError].
  ///
  /// A listbox whose atom carries a function code fires its own PAI (SAP
  /// GUI for Windows: [windowsListboxPickItems], a recorded session
  /// nodecreate_pick gui[35] — the fcode, the etype-121 KEY atom, the
  /// VALUECHANGED source, the cursor on the cell); values typed into
  /// fields of the same plane ride it. One without a function code holds
  /// the key until the next round, as a typed value does. The Java
  /// dialect (no pick oracle) stages the key and, with a function code,
  /// sends it as an okcode round.
  Future<List<Uint8List>> pickListbox(ScreenField f, String key) async {
    final m = screen;
    ScreenField? cur;
    if (m != null) {
      for (final x in m.fields) {
        if (_sameField(x, f)) {
          cur = x;
          break;
        }
      }
    }
    final lb = cur?.listbox;
    if (m == null || cur == null || lb == null) {
      throw ArgumentError('${f.name} is not a listbox of the active window');
    }
    if (cur.isProtected) {
      throw StateError('${f.name} is a display-only listbox');
    }
    final set = _ea.valueSets[lb.id];
    if (set != null && !set.hasKey(key)) {
      throw ArgumentError(
        '"$key" is no key of listbox ${f.name} '
        '(${set.entries.map((e) => e.key).join(', ')})',
      );
    }
    final k = key.trimRight();
    final fcode = lb.fcode;
    if (answerDialect != GuiDialect.windows || fcode.isEmpty) {
      _staged.removeWhere((s) => _sameField(s.field, cur!));
      _staged.add(StagedField(cur, k));
      _stagedScreen = _screenIdentity(m);
      if (fcode.isEmpty) return const [];
      return okcode(fcode);
    }
    // the plane's other typed values ride the pick's own 16/9/2 (the real
    // GUI's one PAI); anything else goes first as its own round (_act)
    final plane = _writeOf(StagedField(cur, k)).planeKey;
    final ride =
        !_stagedHasCells &&
        _staged.every(
          (s) => !_sameField(s.field, cur!) && _writeOf(s).planeKey == plane,
        );
    final atoms = BytesBuilder(copy: false);
    if (ride) {
      // typed values and staged ticks alike ([fieldWriteAtom])
      for (final s in _staged) {
        atoms.add(fieldWriteAtom(_writeOf(s)));
      }
    }
    atoms.add(
      listboxValueAtom(
        row: cur.wireRow,
        col: cur.wireCol,
        key: k,
        width: lb.keyLength > 0 ? lb.keyLength : k.length,
        area: cur.area,
        block: cur.block,
        group: cur.group,
      ),
    );
    _trace('listbox ${f.name} <- key "$k": its own PAI, okcode $fcode');
    return _act(
      windowsListboxPickItems(
        ctx,
        fcode: fcode,
        atoms: atoms.takeBytes(),
        row: cur.wireRow,
        col: cur.wireCol,
        area: cur.area,
        routing: cur.routing,
      ),
      dialectReady: true,
      consumesStaged: ride,
    );
  }
}
