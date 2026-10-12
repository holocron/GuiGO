part of 'sap_session.dart';

/// The HTML viewer side of a [SapSession] (html_viewer.dart): the pages
/// the server pushed to its viewers, which viewer shows which page, and the
/// CFW modal dialogs (the F1 Performance Assistant) they may live in.
///
/// Oracle: the reference client's live the test system F1 on SE16 DATABROWSE-TABLENAME
/// (a recorded session): step 23 creates dialog 117
/// ("Performance Assistant") -> splitter 118 -> cells 119 (toolbar 123) /
/// 120 (SAP.HTMLControl.1 121); step 41 pushes the page under
/// `SAPHTMLP://htmlviewer.sap.com/<prefix>/HTML000001.htm` and calls
/// `ShowData('HTML000001.htm')` on the viewer's handle.
extension SapSessionHtml on SapSession {
  _HtmlState get _htmlState => _htmlStates[_w] ??= _HtmlState();

  /// Fold one complete (chunk-assembled) flush call: its viewer pushes and
  /// its load verbs.
  void _foldHtmlCall(Uint8List value, FlushCall call, int closingStep) {
    final st = _htmlState;
    try {
      for (final p in htmlPushesOf(value)) {
        st.pushes.remove(p.url); // re-pushed: newest last
        st.pushes[p.url] = p;
      }
      // the newest pages only (every F1 / viewer load pushes a new url)
      if (st.pushes.length > _HtmlState.maxPages) {
        for (final u in st.pushes.keys
            .take(st.pushes.length - _HtmlState.maxPages)
            .toList()) {
          st.pushes.remove(u);
        }
      }
      final loads = [
        for (var i = 1; i <= call.verbs.length; i++)
          if (isHtmlLoadVerb(call.verbs[i - 1])) i,
      ];
      final buttons = call.verbs.any(
        (v) =>
            v == 'AddButton' ||
            v == 'SetButtonState' ||
            v == 'DeleteAllButtons' ||
            v.startsWith('CreateControl'),
      );
      if (loads.isEmpty && !buttons) return;
      final meta = verbMeta(call);
      final rowShell = <String, String>{};
      for (var i = 1; i <= call.verbs.length; i++) {
        if (!call.verbs[i - 1].startsWith('CreateControl')) continue;
        final sh = (verbNamedArgs(call, i)['#1'] ?? '').trim();
        final res = i <= meta.length ? (meta[i - 1].result ?? '').trim() : '';
        if (res.isNotEmpty && _isShellId(sh)) rowShell[res] = sh;
      }
      if (buttons) _foldToolbarButtons(call, meta, rowShell);
      for (final i in loads) {
        final m = i <= meta.length ? meta[i - 1] : null;
        final shell = _viewerShellOf(
          rowShell[m?.obj.trim() ?? ''],
          m?.objValue.trim() ?? '',
        );
        if (shell == null) continue;
        final args = verbArgs(call, i);
        final ref = args
            .map((a) => a.$2.trim())
            .firstWhere((v) => v.isNotEmpty, orElse: () => '');
        if (ref.isEmpty) continue;
        st.shown[shell] = (call.verbs[i - 1], ref, closingStep);
        _trace('html viewer $shell: ${call.verbs[i - 1]}($ref)');
      }
    } catch (e) {
      _noteIngestFailure('html fold', e);
    }
  }

  // --- actions (Windows; cfw_dialog_actions.dart) --------------------------

  /// The typed-but-unsent values go first, as their own Enter round, so the
  /// gesture is built on the step that round leaves.
  Future<void> _flushStagedFirst() async {
    if (stagedFields.isNotEmpty) {
      await _act(_stagedRound(), consumesStaged: true);
    }
  }

  void _windowsOnly(String what) {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError('$what is built for the Windows dialect');
    }
  }

  /// Click button [code] of the CFW toolbar [toolbarShell] (the F1
  /// Performance Assistant's TECH / PRINT / BACK / CLOSE …): `%_GC <tb> 1`,
  /// PARAM 0 = [code] (a recorded session gui[119], the real GUI's
  /// TECH: the server answers with the classic SAPLSHL2/1600 popup).
  Future<List<Uint8List>> cfwToolbarButton(
    String toolbarShell,
    String code,
  ) async {
    _windowsOnly('a CFW toolbar click');
    await _flushStagedFirst();
    _ea.recordEvent(toolbarShell, {0: code});
    return _act(
      cfwToolbarButtonItems(
        ctx,
        toolbarShell: toolbarShell,
        code: code,
        sourcePath: _hostedSourcePath(toolbarShell),
      ),
      dialectReady: true,
    );
  }

  /// Close CFW modal dialog [d]: its toolbar's CLOSE button when it has one
  /// (the real GUI's PA close, a recorded session gui[17]: `%_GC <toolbar> 1`
  /// CLOSE; the server then hides the dialog, SetProperty(dialog, 290, 0)),
  /// else the dialog's X — `%_GC <dialog> 8`, no PARAM (reference client
  /// raw_dialogs.dialog_close). The dialog leaves [cfwDialogs] /
  /// [htmlDocuments] at once, as the real GUI's window does, until the
  /// server shows it again.
  Future<List<Uint8List>> closeCfwDialog(SapCfwDialog d) async {
    _windowsOnly('a CFW dialog close');
    await _flushStagedFirst();
    final tb = d.toolbar;
    final List<Uint8List> items;
    if (tb != null && d.buttons.any((b) => b.code == 'CLOSE')) {
      _ea.recordEvent(tb, {0: 'CLOSE'});
      items = cfwToolbarButtonItems(ctx, toolbarShell: tb, code: 'CLOSE');
    } else {
      _ea.recordEvent(d.shell, const {});
      items = cfwDialogCloseItems(ctx, dialogShell: d.shell);
    }
    _htmlState.closed[d.shell] = clockStep;
    return _act(items, dialectReady: true);
  }

  /// Follow link [url] (`SAPEVENT:…`, as [SapHtmlDocument.links] spell it)
  /// in [doc]'s viewer: `%_GC <viewer> 1` with PID1 `0` and PID2 [url]
  /// only, PID0 = the anchor's own `target=` when it has one (the real SAP
  /// GUI for Windows, a recorded session raw gui[10];
  /// [htmlLinkItems]). The server then pulls the (empty) POST object —
  /// PostData, SaveDataToUrl, DP_GET, answered [htmlPostPullAnswer] — and
  /// answers: a documentation link with the linked page in the same viewer
  /// (a new ShowData), a dynamic document's link with its new screen.
  Future<List<Uint8List>> htmlLink(SapHtmlDocument doc, String url) async {
    _windowsOnly('an HTML viewer link');
    await _flushStagedFirst();
    final target =
        doc.links.where((l) => l.href == url).firstOrNull?.target ?? '';
    _ea.recordEvent(doc.shell, {0: target, 1: '0', 2: url});
    _htmlState.post = Uint8List(0); // a link posts no body
    return _act(
      htmlLinkItems(
        ctx,
        viewerShell: doc.shell,
        url: url,
        frame: target,
        sourcePath: _hostedSourcePath(doc.shell),
      ),
      dialectReady: true,
    );
  }

  /// Click button [button] (its DOM id `A1F2B3NAME:BT_SELECTDT`, or the
  /// SAP name after `NAME:`) of a `SAPEVENT:` form in [doc] (a dynamic
  /// document's form, [SapHtmlDocument.forms]): the browser's submit —
  /// `%_GC <viewer> 1` with (frame0, the POST length, `SAPEVENT:<form>`,
  /// 7 x '') and the POST body armed for the server's PostData pull (real
  /// GUI a recorded session gui[38] + gui[41]; reference client
  /// raw_dialogs.html_event). [values] overrides input values by field
  /// name or control id.
  Future<List<Uint8List>> htmlFormButton(
    SapHtmlDocument doc,
    String button, {
    Map<String, String> values = const {},
  }) async {
    _windowsOnly('an HTML form submit');
    SapHtmlForm? form;
    String? id;
    for (final f in doc.forms) {
      id = f.buttonOf(button);
      if (id != null) {
        form = f;
        break;
      }
    }
    if (form == null || id == null) {
      throw ArgumentError(
        'no SAPEVENT form of ${doc.url} has a button "$button"',
      );
    }
    await _flushStagedFirst();
    final body = form.postBytes(id, values: values);
    final url = 'SAPEVENT:${form.event}';
    _ea.recordEvent(doc.shell, {
      0: htmlTargetFrame,
      1: '${body.length}',
      2: url,
    });
    _htmlState.post = body;
    return _act(
      cfwEventItems(
        ctx,
        shell: doc.shell,
        eventId: htmlSapEvent,
        params: [
          htmlTargetFrame,
          '${body.length}',
          url,
          for (var i = 3; i < 10; i++) '',
        ],
        sourcePath: _hostedSourcePath(doc.shell),
      ),
      dialectReady: true,
    );
  }

  /// F1 on input / output field [f]: the SAP GUI for Windows help round
  /// with the cursor ON [f] (a recorded session gui[113]: event type
  /// 2 on a FIELD at its cell, 16/9/11 on the same cell; [caret] = the
  /// cursor offset inside the field, 1 in that capture). The help opens as
  /// the Performance Assistant ([cfwDialogs] / [htmlDocuments]) or the
  /// classic SAPMSSY0/0120 list popup, per the user's help setting. The
  /// Java dialect sends the Java GUI's F1 — the FUNCTIONKEY source and the
  /// cursor on the field (a recorded session gui[24], [fieldHelpItemsJava]).
  Future<List<Uint8List>> fieldHelp(ScreenField f, {int caret = 0}) async {
    if (answerDialect != GuiDialect.windows) {
      // typed values ride the key (the Java field round)
      if (stagedFields.isNotEmpty) return press(1);
      return _act(
        fieldHelpItemsJava(
          ctx,
          row: f.wireRow,
          col: f.wireCol,
          path: f.routing?.path ?? [f.area & 0xff],
          caret: caret,
        ),
      );
    }
    await _flushStagedFirst();
    final items = fieldHelpItems(
      ctx,
      row: f.wireRow,
      col: f.wireCol,
      path: f.routing?.path ?? [f.area & 0xff],
      caret: caret,
    );
    // the cursor stays on [f] (the next round echoes it — gui[119] after
    // the F1 of gui[113]) until a paint moves it
    for (final raw in items) {
      final it = walkItems(raw).items.firstOrNull;
      if (it != null && it.isAppl && it.id == 9 && it.sid == 11) {
        ctx.paintedFocus = Uint8List.fromList(it.value);
        ctx.paintedControlFocus = null; // the client moved the focus
        ctx.paintedNoFocus = false;
      }
    }
    return _act(items, dialectReady: true);
  }

  /// The POST body an [htmlLink] armed for the server's PostData pull
  /// (once), or null.
  Uint8List? _takeHtmlPost() {
    final b = _htmlState.post;
    _htmlState.post = null;
    return b;
  }

  /// Whether CFW dialog [shell] was closed by the client after [step].
  bool _closedSince(String shell, int step) =>
      (_htmlState.closed[shell] ?? -1) >= step;

  /// AddButton / SetButtonState of a CFW toolbar: the button list with its
  /// icon, texts and state. The toolbar is the CreateControl row of the
  /// same queue, else the handle's shell, else the toolbar that already
  /// has the button (an offline replay whose mints differ). A separator
  /// (type 3, no fcode) is kept in its place — the toolbar of the button
  /// before it (control_toolbar.dart); a toolbar created in this queue, or
  /// one whose `DeleteAllButtons` runs, starts empty.
  void _foldToolbarButtons(
    FlushCall call,
    List<VerbMeta> meta,
    Map<String, String> rowShell,
  ) {
    final st = _htmlState;
    final kinds = _layoutState.registry.kinds();
    String? toolbarOf(VerbMeta? m, String code) {
      bool tb(String? sh) => sh != null && kinds[sh] == 'toolbar';
      final r = rowShell[m?.obj.trim() ?? ''];
      if (tb(r)) return r;
      final h = m?.objValue.trim() ?? '';
      if (tb(h)) return h;
      if (tb(_ea.shellAlias[h])) return _ea.shellAlias[h];
      for (final e in st.toolbars.entries) {
        if (e.value.any((b) => b.code == code)) return e.key;
      }
      return null;
    }

    for (final sh in rowShell.values) {
      if (kinds[sh] == 'toolbar') st.toolbars.remove(sh);
    }
    String? last; // the toolbar of the queue's previous AddButton
    for (var i = 1; i <= call.verbs.length; i++) {
      final verb = call.verbs[i - 1];
      final m = i <= meta.length ? meta[i - 1] : null;
      if (verb == 'DeleteAllButtons') {
        final sh = toolbarOf(m, '\u0000');
        if (sh != null) st.toolbars.remove(sh);
        continue;
      }
      if (verb != 'AddButton' && verb != 'SetButtonState') continue;
      final a = {
        for (final e in verbNamedArgs(call, i).entries) e.key: e.value.trim(),
      };
      final code = a['#1'] ?? '';
      final separator = code.isEmpty && verb == 'AddButton' && a['#4'] == '3';
      if (code.isEmpty && !separator) continue;
      final String? sh;
      if (separator) {
        final r = rowShell[m?.obj.trim() ?? ''];
        final h = m?.objValue.trim() ?? '';
        sh = kinds[r] == 'toolbar'
            ? r
            : kinds[h] == 'toolbar'
            ? h
            : kinds[_ea.shellAlias[h]] == 'toolbar'
            ? _ea.shellAlias[h]
            : last;
      } else {
        sh = toolbarOf(m, code);
      }
      if (sh == null) continue;
      last = sh;
      final list = st.toolbars[sh] ??= [];
      if (verb == 'AddButton') {
        if (!separator) list.removeWhere((b) => b.code == code);
        list.add(
            SapToolbarButton(
              code: code,
              icon: a['#2'] ?? '',
              enabled: (a['#3'] ?? '1') != '0',
              type: int.tryParse(a['#4'] ?? '') ?? 0,
              text: a['#5'] ?? '',
              tooltip: a['#6'] ?? '',
              checked: (a['#7'] ?? '0') == '1',
            ),
          );
      } else {
        for (final b in list.where((b) => b.code == code)) {
          b
            ..enabled = (a['#2'] ?? '1') != '0'
            ..checked = (a['#3'] ?? '0') == '1';
        }
      }
    }
  }

  /// The viewer shell a load verb acts on: the CreateControl row of the
  /// same queue, else the handle's kernel shell (the responder's alias),
  /// else — a handle this session cannot map (an offline replay whose
  /// mints differ) — the newest live viewer.
  String? _viewerShellOf(String? rowShell, String handle) {
    final kinds = _layoutState.registry.kinds();
    bool viewer(String? sh) => sh != null && kinds[sh] == 'html' && _live(sh);
    if (viewer(rowShell)) return rowShell;
    if (viewer(handle)) return handle;
    final alias = _ea.shellAlias[handle];
    if (viewer(alias)) return alias;
    for (final c in _layoutState.registry.created.reversed) {
      if (viewer(c.shell)) return c.shell;
    }
    return null;
  }

  /// The pages the current screen's HTML viewers show — the base window's
  /// and the active popup's (a dynpro popup or a CFW modal dialog such as
  /// the F1 Performance Assistant), in the order they were shown. A viewer
  /// counts while it is live, not hidden (SetProperty 290 = 0 on it or a
  /// container above it) and its page was loaded since the current base
  /// program began (a dialog the server re-shows keeps its shell). A page
  /// fetched off-DIAG (an http url) is listed with an empty [html].
  List<SapHtmlDocument> get htmlDocuments {
    final st = _htmlState;
    if (st.shown.isEmpty) return const [];
    final reg = _layoutState.registry;
    final since = _layoutState.baseSinceStep ?? 0;
    final shells = st.shown.entries.toList()
      ..sort((a, b) => a.value.$3.compareTo(b.value.$3));
    final out = <_DocDraft>[];
    for (final e in shells) {
      final sh = e.key;
      final (verb, ref, at) = e.value;
      if (!_onScreen(sh) || at < since || !_shellVisible(sh)) continue;
      final dialog = _dialogOf(sh);
      if (dialog != null && _closedSince(dialog, at)) continue;
      out.add(
        _documentOf(sh, verb, ref, at)
          ..container = _containerNameOf(sh)
          ..dialog = dialog
          ..dialogTitle = dialog == null ? null : reg.props[dialog]?['60'],
      );
    }
    return [for (final d in out) d.build()];
  }

  _DocDraft _documentOf(String shell, String verb, String ref, int at) {
    final push = _pushFor(ref);
    final url = push?.url ?? ref;
    final parts = <String, Uint8List>{};
    final slash = url.lastIndexOf('/');
    if (push != null && slash > url.indexOf('://') + 2) {
      final dir = url.substring(0, slash + 1).toLowerCase();
      for (final p in _allPushes()) {
        if (p.url != url && p.url.toLowerCase().startsWith(dir)) {
          parts[p.url] = p.bytes;
        }
      }
    }
    return _DocDraft(
      shell,
      url,
      push == null ? '' : push.text,
      parts,
      verb,
      at,
    );
  }

  /// The push a load verb's argument names: its exact url, else the newest
  /// push whose url ends with `/<ref>` (ShowData names the document by its
  /// last path segment).
  HtmlPush? _pushFor(String ref) {
    final all = _allPushes().toList();
    for (final p in all.reversed) {
      if (p.url == ref) return p;
    }
    if (ref.contains('://')) return null;
    for (final p in all.reversed) {
      if (p.url.endsWith('/$ref')) return p;
    }
    // the url's case as the push spells it (SBWP: DESURL …/HTML000001.HTM)
    final lower = '/${ref.toLowerCase()}';
    for (final p in all.reversed) {
      if (p.url.toLowerCase().endsWith(lower)) return p;
    }
    return null;
  }

  /// The viewer pushes in arrival order: the ones folded from complete
  /// calls, then any standalone push the responder's cache caught.
  Iterable<HtmlPush> _allPushes() sync* {
    final st = _htmlState;
    final seen = <String>{};
    for (final p in st.pushes.values) {
      seen.add(p.url);
      yield p;
    }
    final cache = _ea.dpCache.byUrl;
    if (st.cacheMemo.length > cache.length) {
      // a memo pins its segment: one the cache evicted goes with it
      st.cacheMemo.removeWhere((u, m) => !identical(cache[u], m.$1));
    }
    for (final e in cache.entries) {
      if (seen.contains(e.key)) continue;
      // decoded once per cached segment (a grid push is never a page)
      final memo = st.cacheMemo[e.key];
      final HtmlPush? p;
      if (memo != null && identical(memo.$1, e.value)) {
        p = memo.$2;
      } else {
        final q = htmlPushOf(e.value);
        p = q != null && q.isHtml ? q : null;
        st.cacheMemo[e.key] = (e.value, p);
      }
      if (p != null) yield p;
    }
  }

  /// [shell] and every container above it are not hidden (290 = 0).
  bool _shellVisible(String shell) {
    final reg = _layoutState.registry;
    String? sh = shell;
    for (var i = 0; i < 16 && sh != null; i++) {
      if (reg.props[sh]?['290'] == '0') return false;
      sh = reg.parents[sh];
    }
    return true;
  }

  /// The CFW modal dialog (SAPGUI.DIALOGCTRL.1) above [shell], or null.
  String? _dialogOf(String shell) {
    final reg = _layoutState.registry;
    final classes = reg.classes();
    String? sh = reg.parents[shell];
    for (var i = 0; i < 16 && sh != null; i++) {
      if ((classes[sh] ?? '').toUpperCase().contains('DIALOGCTRL')) return sh;
      sh = reg.parents[sh];
    }
    return null;
  }

  /// The dynpro custom-control area a viewer's container chain is linked
  /// to, else its direct container shell.
  String? _containerNameOf(String shell) {
    final reg = _layoutState.registry;
    final byShell = <String, String>{
      for (final e in reg.areaLinks.entries) e.value.$1: e.key,
    };
    String? sh = reg.parents[shell];
    for (var i = 0; i < 16 && sh != null; i++) {
      if (byShell[sh] case final area?) return area;
      sh = reg.parents[sh];
    }
    return reg.parents[shell];
  }

  /// The viewer shells whose page arrived over DIAG (the R10 rung of the
  /// window composition).
  Set<String> get _htmlShells => {
    for (final d in htmlDocuments)
      if (d.delivered) d.shell,
  };

  /// The live, shown CFW modal dialogs of the session (the F1 Performance
  /// Assistant), newest last, each with the controls it hosts laid out in
  /// window cells: the dialog's pixel box (left 170 / top 270 / width 300
  /// / height 120) at the session's pixels per cell (the 16/12/8 window
  /// pixels over the screen cells), its splitter rows / columns by their
  /// SetRowHeight / SetColumnWidth (mode 0 = pixels, else shares).
  List<SapCfwDialog> get cfwDialogs {
    final reg = _layoutState.registry;
    final out = <SapCfwDialog>[];
    final seen = <String>{};
    for (final c in reg.created) {
      if (!c.cls.toUpperCase().contains('DIALOGCTRL')) continue;
      if (!seen.add(c.shell) || !_onScreen(c.shell)) continue;
      if (!_shellVisible(c.shell)) continue;
      // closed by the client: shown again only by a newer page in it
      final closedAt = _htmlState.closed[c.shell];
      if (closedAt != null &&
          !_htmlState.shown.entries.any(
            (e) => e.value.$3 > closedAt && _dialogOf(e.key) == c.shell,
          )) {
        continue;
      }
      final p = reg.props[c.shell] ?? const <String, String>{};
      final rowPx = ctx.winPxHeight / (screenRows == 0 ? 1 : screenRows);
      final colPx = ctx.winPxWidth / (screenCols == 0 ? 1 : screenCols);
      int px(String id) => int.tryParse((p[id] ?? '').trim()) ?? 0;
      var rows = (px('120') / rowPx).round();
      var cols = (px('300') / colPx).round();
      if (rows <= 0) rows = screenRows ~/ 2;
      if (cols <= 0) cols = screenCols ~/ 2;
      final top = (px('270') / rowPx).round().clamp(0, screenRows);
      final left = (px('170') / colPx).round().clamp(0, screenCols);
      final rect = CellRect(
        top.toDouble(),
        left.toDouble(),
        (rows < screenRows ? rows : screenRows).toDouble(),
        (cols < screenCols ? cols : screenCols).toDouble(),
      );
      final regions = <ScreenRegion>[];
      _layoutDialogBox(c.shell, rect, rowPx, colPx, regions, 0);
      final tb = regions
          .where((r) => r.rung == 'TB' && r.shell != null)
          .map((r) => r.shell!)
          .firstOrNull;
      out.add(
        SapCfwDialog(
          shell: c.shell,
          title: (p['60'] ?? '').trim(),
          rect: rect,
          regions: regions,
          toolbar: tb,
          buttons: tb == null
              ? const []
              : List.unmodifiable([
                  for (final b in _htmlState.toolbars[tb] ?? const [])
                    SapToolbarButton(
                      code: b.code,
                      icon: b.icon,
                      text: b.text,
                      tooltip: b.tooltip,
                      type: b.type,
                      enabled: b.enabled,
                      checked: b.checked,
                    ),
                ]),
        ),
      );
    }
    return out;
  }

  /// The regions of the CFW dialogs' controls (see [cfwDialogs]) — part of
  /// the window composition: [regions] lists them after the base window's.
  List<ScreenRegion> get _cfwDialogRegions => [
    for (final d in cfwDialogs) ...d.regions,
  ];

  /// Lay out the controls under [shell] inside [box]: a splitter's cells
  /// by its sashes, any other container's children over its whole box; a
  /// leaf control becomes a region.
  void _layoutDialogBox(
    String shell,
    CellRect box,
    double rowPx,
    double colPx,
    List<ScreenRegion> out,
    int depth,
  ) {
    if (depth > 12) return;
    final reg = _layoutState.registry;
    final kinds = reg.kinds();
    final children = [
      for (final e in reg.parents.entries)
        if (e.value == shell && _live(e.key) && _shellVisible(e.key)) e.key,
    ]..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    final sp = reg.splitters[shell];
    if (sp != null && sp.cells.isNotEmpty) {
      final rh = _sashes(sp.rows, sp.rowMode, sp.rowPct, box.rows, rowPx);
      final cw = _sashes(sp.cols, sp.colMode, sp.colPct, box.cols, colPx);
      for (final e in sp.cells.entries) {
        final (r, c) = e.key;
        if (r < 1 || c < 1 || r > rh.length || c > cw.length) continue;
        final top = rh.take(r - 1).fold<double>(0, (a, b) => a + b);
        final left = cw.take(c - 1).fold<double>(0, (a, b) => a + b);
        if (!_live(e.value)) continue;
        _layoutDialogBox(
          e.value,
          CellRect(box.row + top, box.col + left, rh[r - 1], cw[c - 1]),
          rowPx,
          colPx,
          out,
          depth + 1,
        );
      }
      return;
    }
    if (kinds[shell] case final k? when k != 'container' && depth > 0) {
      final html = k == 'html';
      final delivered = html && _htmlShells.contains(shell);
      final buttons = reg.toolbarButtons[shell]?.length ?? 0;
      final rung = switch (k) {
        'toolbar' => 'TB',
        'html' => delivered ? 'R10' : 'R7',
        'grid' || 'tree' => 'R2',
        _ => 'R9',
      };
      out.add(
        ScreenRegion(
          kind: k == 'toolbar' ? 'control' : (k == 'jnet' ? 'netplan' : k),
          shell: shell,
          container: reg.parents[shell],
          rect: box,
          rung: rung,
          reason: switch (rung) {
            'TB' =>
              'control toolbar, $buttons button(s) drawn in its box '
                  '(CFW dialog ${_dialogOf(shell)})',
            'R10' =>
              'HTML document delivered over DIAG (shell $shell, '
                  'CFW dialog ${_dialogOf(shell)})',
            'R7' => '$k control, no content channel yet (shell $shell)',
            _ =>
              '$k control in CFW dialog ${_dialogOf(shell)} '
                  '(shell $shell)',
          },
        ),
      );
      return;
    }
    for (final ch in children) {
      _layoutDialogBox(ch, box, rowPx, colPx, out, depth + 1);
    }
  }
}

/// A splitter axis in cells: mode 0 sizes are pixels, the rest of the box
/// goes to the cells without one (shared equally); mode 1 sizes are shares.
List<double> _sashes(
  int n0,
  int mode,
  Map<int, double> sizes,
  double total,
  double pxPerCell,
) {
  final n = n0 <= 0 ? 1 : n0;
  final out = List<double>.filled(n, -1);
  var used = 0.0;
  if (mode == 0) {
    for (var i = 1; i <= n; i++) {
      final px = sizes[i];
      if (px == null) continue;
      final cells = _atLeast1((px / pxPerCell).round()).toDouble();
      final room = total - used < 0 ? 0.0 : total - used;
      out[i - 1] = cells < room ? cells : room;
      used += out[i - 1];
    }
    final free = [
      for (var i = 0; i < n; i++)
        if (out[i] < 0) i,
    ];
    if (free.isEmpty && used < total) {
      out[n - 1] += total - used; // the last cell takes the rest
    }
    for (final i in free) {
      out[i] = ((total - used) / free.length).floorToDouble();
    }
    if (free.isNotEmpty) {
      final sum = out.fold<double>(0, (a, b) => a + b);
      out[free.last] += total - sum;
    }
  } else {
    final declared = [for (var i = 1; i <= n; i++) sizes[i] ?? 0];
    final s = declared.fold<double>(0, (a, b) => a + b);
    for (var i = 0; i < n; i++) {
      out[i] = (s <= 0 ? total / n : total * declared[i] / s).floorToDouble();
    }
    out[n - 1] += total - out.fold<double>(0, (a, b) => a + b);
  }
  return out;
}

int _atLeast1(int v) => v < 1 ? 1 : v;

bool _isShellId(String s) => s.isNotEmpty && int.tryParse(s) != null;

class _DocDraft {
  _DocDraft(this.shell, this.url, this.html, this.parts, this.verb, this.step);
  final String shell;
  final String url;
  final String html;
  final Map<String, Uint8List> parts;
  final String verb;
  final int step;
  String? container;
  String? dialog;
  String? dialogTitle;

  SapHtmlDocument build() => SapHtmlDocument(
    shell: shell,
    container: container,
    url: url,
    html: html,
    parts: parts,
    dialog: dialog,
    dialogTitle: dialogTitle?.trim(),
    verb: verb,
    step: step,
  );
}

class _HtmlState {
  /// How many viewer pages [pushes] keeps, oldest out first.
  static const int maxPages = 128;

  /// viewer pushes by url, in arrival order (a re-push moves to the end)
  final Map<String, HtmlPush> pushes = {};

  /// the sapevent POST body armed for the next PostData pull
  Uint8List? post;

  /// dialog shell -> the step the client closed it at
  final Map<String, int> closed = {};

  /// toolbar shell -> its buttons, AddButton order
  final Map<String, List<SapToolbarButton>> toolbars = {};

  /// viewer shell -> (load verb, its url / document argument, step)
  final Map<String, (String, String, int)> shown = {};

  /// responder-cache url -> (the segment decoded, its page or null)
  final Map<String, (Uint8List, HtmlPush?)> cacheMemo = {};
}

final Expando<_HtmlState> _htmlStates = Expando('htmlState');
