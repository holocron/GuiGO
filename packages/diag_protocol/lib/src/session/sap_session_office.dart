part of 'sap_session.dart';

/// The Office documents of a [SapSession] (DOI, doi.dart): what each live
/// `SAP.DocumentContainerControl.1` holds — the SO10 / SMARTFORMS SAPscript
/// Word editor's RTF, a SAPRDEMO spreadsheet, the SFP Designer's XDP — and
/// the container's activation event.
extension SapSessionOffice on SapSession {
  DoiState get _officeDoi => _w.doi;

  /// Every live, shown DOI container's open document, by the container's
  /// shell (the `office` region's [ScreenRegion.shell]). A closed document
  /// (CloseDocument) and a destroyed container drop out; a container of
  /// another live internal mode is hidden, its document kept.
  Map<String, SapOfficeDocument> get officeDocuments {
    final out = <String, SapOfficeDocument>{};
    for (final e in _officeDoi.containers.entries) {
      final doc = e.value['current'];
      if (doc is! Document || doc.closed) continue;
      final sh = e.key;
      if (!_onScreen(sh) || !_shellVisible(sh)) continue;
      out[sh] = officeDocumentOf(sh, doc);
    }
    return out;
  }

  /// Raise the container's activation event for the document [shell]
  /// shows — when the user first works in it (taps into the document
  /// pane): `%_GC <shell> 2`, PARAMs 0..2 = 1, 1, 1, the event shell
  /// holding the focus (`16/9/18`), the 16/15/1 source of the custom
  /// control it sits in, and the realized size (120 / 300) of each
  /// container up its chain the server did not size itself — the real SAP
  /// GUI for Windows' gui[41] of a recorded session
  /// (SO10's Word editor 118, container 117 `120` / `300`) and gui[15] of
  /// a recorded session; a recorded session gui[19] (the chart 118)
  /// carries no size. Once per opened document, and only when the
  /// container registered event 2: the real GUI raised it on 3 of the 8
  /// recorded opens and went idle into `/nex` without it on the SMARTFORMS
  /// text node (a recorded session gui[47]), so it is
  /// never sent unprompted. Returns the frames of the server's answer
  /// (SO10: FreeObject of the two proxies, then the repaint); nothing is
  /// sent (empty) when no activation is owed for [shell].
  Future<List<Uint8List>> officeDocumentActivated(String shell) async {
    if (answerDialect != GuiDialect.windows) return const [];
    final sh = shell.trim();
    final st = _officeDoi;
    if (!st.pendingActivation.contains(sh)) return const [];
    if (!(st.registeredEvents[sh]?.contains(officeActivationEvent) ?? false)) {
      st.pendingActivation.remove(sh);
      return const [];
    }
    if (!officeDocuments.containsKey(sh)) return const [];
    st.pendingActivation.remove(sh);
    await _flushStagedFirst();
    const params = ['1', '1', '1'];
    _ea.recordEvent(sh, {for (final (i, p) in params.indexed) i: p});
    final reg = _layoutState.registry;
    final sizes = <String, List<(String, String)>>{};
    _areaSizes(reg.parents[sh]).forEach((c, values) {
      final done = reg.flushedSizes[c] ?? const <String, String>{};
      final dirty = [
        for (final (p, v) in values)
          if (done[p] != v) (p, v),
      ];
      if (dirty.isNotEmpty) sizes[c] = dirty;
    });
    final ordered = {
      for (final c
          in sizes.keys.toList()..sort(
            (a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0),
          ))
        c: sizes[c]!,
    };
    for (final MapEntry(key: c, value: props) in ordered.entries) {
      final done = reg.flushedSizes[c] ??= {};
      for (final (p, v) in props) {
        done[p] = v;
      }
    }
    _trace('office document $sh activated: %_GC $sh $officeActivationEvent');
    return _act(
      cfwEventItems(
        ctx,
        shell: sh,
        eventId: officeActivationEvent,
        params: params,
        sourcePath: _hostedSourcePath(sh),
        focusShell: sh,
        controls: ordered,
      ),
      controlEvent: true,
      dialectReady: true,
    );
  }
}

/// The screen's view of [doc], open in the DOI container [shell].
SapOfficeDocument officeDocumentOf(String shell, Document doc) =>
    SapOfficeDocument(
      shell: shell,
      progId: doc.cls,
      kind: doc.kind,
      format: doc.format,
      bytes: doc.sourceBytes,
      fileExtension: officeFileExtension(doc.cls, doc.format, doc.sourceBytes),
      readOnly: doc.readOnly,
      sheet: doc.kind == OfficeDocKind.excel ? doc : null,
      version: doc.version,
    );
