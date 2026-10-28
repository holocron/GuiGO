part of 'sap_session.dart';

/// The Office documents of a [SapSession] (DOI, doi.dart): what each live
/// `SAP.DocumentContainerControl.1` holds — the SO10 / SMARTFORMS SAPscript
/// Word editor's RTF, a SAPRDEMO spreadsheet, the SFP Designer's XDP — and
/// the container's OnCloseDocument when the user leaves an in-place one.
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
  List<SapOfficeDocument> get officeWindows => _officeWindowsIn(null);

  /// [officeWindows] judged against [drawn], the base window's composed
  /// regions a view already holds (SapSession.baseComposition) — the
  /// getter composes them itself, and only when a created document needs
  /// the verdict.
  List<SapOfficeDocument> officeWindowsIn(List<ScreenRegion> drawn) =>
      _officeWindowsIn(drawn);

  List<SapOfficeDocument> _officeWindowsIn(List<ScreenRegion>? composed) {
    final st = _officeDoi;
    final gone = _dismissedOfficeWindows[st] ??= <Document>{};
    // the shells the window's panes draw — read lazily: a session that
    // never opened a document (the common one) composes nothing here, and
    // a view passes the regions it composed already
    Set<String>? drawn;
    final out = <SapOfficeDocument>[];
    for (final (sh, doc) in st.createdDocs.reversed) {
      if (!doc.outOfPlace || doc.closed || gone.contains(doc)) continue;
      // a pane of this window shows it (the chart demo's container)
      final held = identical(st.containers[sh]?['current'], doc);
      if (held) {
        drawn ??= {
          for (final r in composed ?? regions)
            if (r.shell != null) r.shell!,
        };
        if (drawn.contains(sh) && _onScreen(sh) && _shellVisible(sh)) {
          continue;
        }
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

  /// The user ENTERED the in-place document [shell] shows (tapped into its
  /// pane): nothing goes on the wire — a click or a selection in the real
  /// GUI's in-place Word sends nothing (a recorded session
  /// redo DECODE §3) — but the document now owes its OnCloseDocument
  /// ([officeCloseDocumentEvent]) to the user's next round, which leaves it
  /// ([_leaveOfficeDocuments]): the real GUI's event round came right
  /// before the SAP action each time (editor_selection_redo gui[41] then
  /// `/nex`; text_html gui[15] then Save; connect_su53 gui[956] / [1234]
  /// then F3; alv_excel_inplace gui[156] then a tree click). A document
  /// never entered owes nothing (a recorded session: ten
  /// text nodes left by tree clicks, no event). Only an in-place document
  /// of a container that registered event 2, once per opened document, on
  /// a Windows connection — and never the SFP Designer's (below).
  /// Returns whether the document now owes its event to the next round.
  bool officeDocumentEntered(String shell) {
    if (answerDialect != GuiDialect.windows) return false;
    final sh = shell.trim();
    final st = _officeDoi;
    if (_closeEventDocument(st, sh) == null) return false;
    st.entered
      ..remove(sh)
      ..add(sh);
    _trace('office document $sh entered: its OnCloseDocument goes before '
        'the next round');
    return true;
  }

  /// The former first-touch entry, kept for tool/sfp_popup_trace.dart: it
  /// only ENTERS the document now ([officeDocumentEntered]) and sends
  /// nothing (empty) — the event rides the next round, as the real GUI's.
  Future<List<Uint8List>> officeDocumentActivated(String shell) async {
    officeDocumentEntered(shell);
    return const [];
  }

  /// The open document of container [sh] whose OnCloseDocument is still
  /// owed and would be raised on leaving it, else null.
  Document? _closeEventDocument(DoiState st, String sh) {
    if (!st.closeEventPending.contains(sh)) return null;
    final doc = st.containers[sh]?['current'];
    // an Office window's document closes with the window, not by leaving
    // a pane (a recorded session gui[19]: the user closed Excel)
    if (doc is! Document || doc.closed || doc.outOfPlace) return null;
    // the SFP Designer's document never raises it: its container's event
    // 2 makes SFP close its side (CloseDocument + ReleaseDocument), and
    // the next pai_layout calls has_changed on the dead proxy — rc_failed,
    // forced CHANGED, the FPUIFB 051 Information modal ('Impossible de
    // sauvegarder modifications de mise en forme en mode affich.!'),
    // live-proven on the test system (tool/sfp_popup_trace.dart). No SFP capture
    // records the event (a recorded session: "none from the
    // Designer itself before /nex"), and the user's clicks there go to
    // the Adobe window — so the general rule does not cover it.
    if (doc.cls.toLowerCase().startsWith('pdfxmldesigner.')) return null;
    if (!(st.registeredEvents[sh]?.contains(officeCloseDocumentEvent) ??
        false)) {
      return null;
    }
    if (!officeDocuments.containsKey(sh)) return null;
    return doc;
  }

  /// Whether a user round leaves an entered document ([SapSession._act]).
  bool get _officeLeaveOwed => _officeDoi.entered.isNotEmpty;

  /// The user's round leaves the in-place documents they entered: each
  /// one's OnCloseDocument goes out first, as its own round — `%_GC
  /// <shell> 2`, PARAMs = [doiCloseEventParams] (1, 1, 1 for the SAPscript
  /// text), the event shell holding the focus (`16/9/18`), the 16/15/1
  /// source of the custom control it sits in, and the realized size
  /// (120 / 300) of each container up its chain the server did not size
  /// itself — the real SAP GUI for Windows' gui[41] of a recorded session
  /// editor_selection_redo (SO10's Word editor 118, container 117 `120` /
  /// `300`) and gui[15] of a recorded session. The server answers it
  /// (SO10: FreeObject of the two proxies, then the repaint; SMARTFORMS:
  /// the Word editor's teardown) before the user's round goes out. The
  /// typed values stay staged for that round ([_act] built it from them).
  Future<void> _leaveOfficeDocuments() async {
    final st = _officeDoi;
    final left = st.entered.toList();
    st.entered.clear();
    for (final sh in left) {
      final doc = _closeEventDocument(st, sh);
      if (doc == null) continue;
      st.closeEventPending.remove(sh);
      final typed = List.of(_staged);
      final typedOn = _stagedScreen;
      _staged.clear();
      _stagedScreen = null;
      try {
        await _sendCloseEvent(sh, doc);
      } finally {
        if (_staged.isEmpty && typed.isNotEmpty) {
          _staged.addAll(typed);
          _stagedScreen = typedOn;
        }
      }
    }
  }

  Future<List<Uint8List>> _sendCloseEvent(String sh, Document doc) {
    final params = doiCloseEventParams(doc);
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
    _trace('office document $sh left: %_GC $sh $officeCloseDocumentEvent '
        '(${params.join(', ')})');
    return _act(
      cfwEventItems(
        ctx,
        shell: sh,
        eventId: officeCloseDocumentEvent,
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
