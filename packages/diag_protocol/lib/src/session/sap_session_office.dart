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

  /// The session's Office WINDOWS, newest first: every document the server
  /// opened in Office's own window ([Document.outOfPlace]: open mode
  /// OPEN_MODE_EDIT -2) that no pane of the current window draws — XXL's
  /// spreadsheet (DWDM "Api test simple": XXL_FULL_API links its container
  /// to a `CONTAINER` area no screen paints). It outlives its container's
  /// ReleaseDocument / DestroyControl, as the real Excel window outlives
  /// the SAP control (XXL then asks the user to save the data there:
  /// SOFFICEINTEGRATION 233); a CloseDocument, or the user closing it
  /// ([dismissOfficeWindow]), ends it.
  List<SapOfficeDocument> get officeWindows {
    final st = _officeDoi;
    final gone = _dismissedOfficeWindows[st] ??= <Document>{};
    final drawn = {
      for (final r in regions)
        if (r.shell != null) r.shell!,
    };
    final out = <SapOfficeDocument>[];
    for (final (sh, doc) in st.createdDocs.reversed) {
      if (!doc.outOfPlace || doc.closed || gone.contains(doc)) continue;
      // a pane of this window shows it (the chart demo's container)
      final held = identical(st.containers[sh]?['current'], doc);
      if (held && drawn.contains(sh) && _onScreen(sh) && _shellVisible(sh)) {
        continue;
      }
      final w = officeDocumentOf(sh, doc);
      _officeWindowDoc[w] = doc;
      out.add(w);
    }
    return out;
  }

  /// The user closed Office window [window] (one of [officeWindows]):
  /// nothing goes on the wire — the server released the document already,
  /// or still holds it and closes it itself.
  void dismissOfficeWindow(SapOfficeDocument window) {
    final doc = _officeWindowDoc[window];
    if (doc == null) return;
    final gone = _dismissedOfficeWindows[_officeDoi] ??= <Document>{};
    gone.add(doc);
    // bounded like the documents themselves
    if (gone.length > DoiState.maxDocs) gone.remove(gone.first);
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
    // the SFP Designer's document is never "activated" back to SAP: its
    // container's event 2 propagates the DESIGNER's close (C_OI_
    // CONTAINER_CONTROL_PROXY's close semantics; SFP's handler closes its
    // side), and the next pai_layout then calls has_changed on the dead
    // proxy — rc_failed, forced CHANGED, the FPUIFB 051 Information modal
    // ('Impossible de sauvegarder modifications de mise en forme en mode
    // affich.!'). Live-proven on the test system (tool/sfp_popup_trace.dart): the
    // event round answers CloseDocument + ReleaseDocument and the modal
    // paint follows; without the event no has_changed round pops anything
    // (it answers a clean 0/0 on the tab switches). In the real GUI no
    // such round exists for the Designer — the clicks go to the Adobe
    // window, and no SFP capture records one.
    final current = st.containers[sh]?['current'];
    if (current is Document &&
        current.cls.toLowerCase().startsWith('pdfxmldesigner.')) {
      st.pendingActivation.remove(sh);
      return const [];
    }
    if (!(st.registeredEvents[sh]?.contains(officeActivationEvent) ?? false)) {
      st.pendingActivation.remove(sh);
      return const [];
    }
    if (!officeDocuments.containsKey(sh)) return const [];
    st.pendingActivation.remove(sh);
    await _flushStagedFirst();
    const params = ['1', '1', '1'];
    final byPid = {for (final (i, p) in params.indexed) i: p};
    _ea.recordEvent(sh, byPid);
    // event 2 is ON_CLOSE_DOCUMENT to the server: its has_changed 1 is what
    // the next CloseDocument answers, unless a save comes between
    // (doi.dart [Document.closeEventChanged])
    doiNoteCloseEvent(st, sh, byPid);
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

/// The opened-files stream of a session (see [SapSessionOffice
/// .frontendFileOpens]).
final Expando<StreamController<FrontendFile>> _fileOpenStreams =
    Expando('frontend file opens');

extension SapSessionFiles on SapSession {
  StreamController<FrontendFile> get _fileOpens =>
      _fileOpenStreams[this] ??= StreamController<FrontendFile>.broadcast();

  /// Every file the server wrote to this frontend and then OPENED
  /// (frontend_files.dart: `SecureSaveDataToUrl(…, file://<path>)` then
  /// `ShellExecute('OPEN', <path>)` — the ALV export "Calcul avec tableur"'s
  /// .xlsx, OAOR's downloaded document), in wire order: on SAP GUI for
  /// Windows the shell opens it in Excel / Word; the app hands it to the
  /// platform's viewer / share sheet. The call was already answered (t3
  /// `42`); a file nobody listens to is dropped. Broadcast.
  Stream<FrontendFile> get frontendFileOpens => _fileOpens.stream;

  void _publishFileOpens() {
    final opened = _ea.frontendFiles.takeOpened();
    if (opened.isEmpty) return;
    final c = _fileOpens;
    for (final f in opened) {
      _trace('frontend file opened: $f');
      if (!c.isClosed) c.add(f);
    }
  }

  Future<void> _closeFileOpens() async {
    _ea.frontendFiles.clear();
    final c = _fileOpenStreams[this];
    if (c != null && !c.isClosed) await c.close();
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

/// The Office windows the user closed, per session DOI state.
final Expando<Set<Document>> _dismissedOfficeWindows =
    Expando('dismissed office windows');

/// The document behind each [SapSessionOffice.officeWindows] entry.
final Expando<Document> _officeWindowDoc = Expando('office window document');
