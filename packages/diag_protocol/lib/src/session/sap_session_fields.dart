part of 'sap_session.dart';

/// A field value typed but not yet sent ([SapSessionFields.stageField]).
class StagedField {
  StagedField(this.field, this.text);
  final ScreenField field;
  final String text;

  /// A secret's value never reaches a trace: an invisible (password) input,
  /// or a logon screen's BCODE / password field by name.
  bool get secret =>
      field.invisible ||
      RegExp(
        r'BCODE|PASSW|PWD',
        caseSensitive: false,
      ).hasMatch(field.name ?? '');

  @override
  String toString() =>
      'StagedField(${field.name}=${secret ? '<hidden>' : text.trimRight()})';
}

/// A classic-list INPUT cell typed or ticked but not yet sent
/// ([SapSessionFields.stageListCell]): the cell's buffer line and column,
/// its width and the value — a checkbox's `X` / blank.
class StagedListCell {
  StagedListCell(this.line, this.col, this.width, this.text);
  final int line;
  final int col;
  final int width;
  final String text;

  /// The wire write: the user's raw text blank-padded to the cell width
  /// (the whole buffer cell is rewritten).
  (int, int, String) get write => (line, col, text.padRight(width));

  @override
  String toString() => 'StagedListCell($line,$col="$text")';
}

/// Deferred field values and value help (reference client engine/deferred_fill +
/// reference_fields.flush_deferred_fills, raw_help.f4, raw_listpick.list_pick).
///
/// Typing is pure client state, as in the real GUI (platinr3S.jar
/// GuiSession.processValueChangeEvent: no event list, no wire): a staged
/// value rides the NEXT action's frame — Enter / a function key ([press]),
/// an okcode or a dynpro pushbutton ([okcode]), another field's [fill],
/// F4 ([valueHelp]) — every staged field in ONE PAI, one segment per
/// container plane, the focus on the last field edited ([fieldRoundItems]).
/// Any other action (a control event, a radio, a table cell, a list pick)
/// first sends the staged values as ONE Enter round — the reference client's
/// deferred_fill rule for actions whose merged frame no capture pins.
/// Staged values never outlive their screen: a paint of the dynpro or a
/// change of program / dynpro / window level drops them (an input the
/// kernel cannot bind on another screen is a "FOCUS DATA" teardown); a
/// `/n…` command leaves the screen and drops them unsent.
extension SapSessionFields on SapSession {
  /// The values typed but not yet sent, oldest first (the last one is the
  /// cursor field of the round that carries them).
  List<StagedField> get stagedFields => List.unmodifiable(_staged);

  /// Type [text] into input [f] of the active window WITHOUT a round trip:
  /// the value rides the next action. Typing the same field again replaces
  /// its value and makes it the cursor field.
  void stageField(ScreenField f, String text) {
    final m = screen;
    if (m == null || !m.fields.contains(f)) {
      throw ArgumentError('${f.name} is not a field of the active window');
    }
    if (f.kind != FieldKind.input || f.isProtected) {
      throw ArgumentError('${f.name} is not an input field');
    }
    _staged.removeWhere((s) => _sameField(s.field, f));
    _staged.add(StagedField(f, text));
    _stagedScreen = _screenIdentity(m);
  }

  /// Forget the staged value of [f] (the user reverted the edit).
  void unstageField(ScreenField f) {
    _staged.removeWhere((s) => _sameField(s.field, f));
    if (_staged.isEmpty) _stagedScreen = null;
  }

  /// F4 on input [f]: the SAP GUI for Windows function-key round with the
  /// cursor ON the field (reference client raw_help._f4_windows_items, grounded on
  /// a recorded session gui[4]; the reference client's accepted SE38 F4,
  /// a recorded session step 50: `0a 0007 0001 04 …
  /// 0002 000e 0001 00` + 16/9/11 `01 0002 000e 00000000 00`). With staged
  /// values the F4 rides their field round instead (the real GUI's typed-
  /// pattern-then-F4 frame), the focus on [f]. The help arrives as a popup
  /// — a classic hit list ([ScreenModel.listLines] → [pickValue]), a
  /// restriction dynpro (fill its fields, Enter) — or an F4 control.
  Future<List<Uint8List>> valueHelp(ScreenField f) async {
    if (_stagedHasCells) {
      // F4 in a cell over typed cells of its control: one table-plane
      // round (a recorded session gui[313])
      final cells = f.tableControl == null
          ? null
          : _stagedCellKeyRound(4, cursor: f);
      if (cells != null) {
        return _act(cells, dialectReady: true, consumesStaged: true);
      }
      await _sendStagedCellsFirst();
    }
    if (_staged.isNotEmpty) {
      final i = _staged.indexWhere((s) => _sameField(s.field, f));
      if (i >= 0) _staged.add(_staged.removeAt(i)); // F4's field last
      return _act(
        _stagedRound(
          vkey: 4,
          cursor: i >= 0
              ? null
              : FieldCursor(
                  f.wireRow,
                  f.wireCol,
                  area: f.area,
                  routing: f.routing,
                ),
        ),
        consumesStaged: true,
      );
    }
    if (answerDialect != GuiDialect.windows) return press(4);
    final path = f.routing?.path ?? [f.area & 0xff];
    final focus = Uint8List(9 + path.length);
    focus[0] = path.length;
    final bd = focus.buffer.asByteData();
    bd.setUint16(1, f.wireRow);
    bd.setUint16(3, f.wireCol);
    focus.setRange(9, focus.length, path);
    return _act(
      windowsActionItems(
        pressItems(ctx, 4),
        ctx: ctx,
        cursor: focus,
        // a staged grid state rides it ([_act]): a popup's nested F4 is
        // then OK 0x0d (a recorded session gui[193])
        controlState: gridSelections.values.any((g) => g.pending),
      ),
      dialectReady: true,
    );
  }

  // --- classic list input cells (WRITE … INPUT, WRITE … AS CHECKBOX) -------
  //
  // A list input cell is an SFE run without the protected bit
  // ([ListSegment.input]); typing into it is client state (the Java GUI's
  // GuiListContainer.startEditor / stopEditor -> setupFromEditor, the
  // pending value fireValueChanges flushes into the next key round). The
  // value rides the NEXT list key round of the window — F2 on a line
  // ([pickValue]), a function key ([press]) — as SBA + 16/12/11 pairs before
  // the 16/12/13 cursor (a recorded session gui[12] / [14], the
  // real Windows GUI typing into SAPLSNF2/0120 and pressing F3 / F8).
  //
  // A checkbox tick / untick is the same wire-silent 1-cell write of `X` /
  // blank (a recorded session gui[10], confirmed by _run2
  // gui[8]: tick row 4, tick row 6, untick row 4, then the `Liste globale`
  // toolbar key Ctrl+F8 = `SBA 04 02` `16/12/11 20`, `SBA 06 02` `16/12/11
  // 58`, `16/12/13 01 0004 0002`): every cell the user TOUCHED goes once,
  // with its FINAL value — the tick-then-untick cell too, although it is
  // back to its painted blank —, in ascending buffer order, the cursor on
  // the LAST cell touched; the untouched cells are not sent. The server's
  // repaint after such a list function arrives as 16/8/4 + 16/8/6 slices of
  // ONE list stream, joined by the stream reader (stream_paint.dart).

  /// The list cells typed / ticked but not yet sent, oldest first.
  List<StagedListCell> get stagedListCells =>
      List.unmodifiable(_w.stagedListCells);

  /// Type [text] into the list input [cell] of [line] (a checkbox: `X` or
  /// blank) WITHOUT a round trip: the value rides the next list key round.
  void stageListCell(ListLine line, ListSegment cell, String text) {
    final m = screen;
    if (m == null ||
        !m.listPaint.any((l) => l.line == line.line) ||
        !line.segments.contains(cell)) {
      throw ArgumentError('list line ${line.line} is not painted');
    }
    if (!cell.input) {
      throw ArgumentError(
          'list cell ${line.line},${cell.col} is not an input cell');
    }
    if (text.length > cell.width) {
      throw ArgumentError('"$text" exceeds the cell width ${cell.width}');
    }
    final staged = _w.stagedListCells;
    // one entry per TOUCHED cell, its final value, the last touch last — a
    // cell back at its painted value is still sent (the real GUI keeps a
    // touched set, not a diff: a recorded session gui[10])
    staged.removeWhere((c) => c.line == line.line && c.col == cell.col);
    staged.add(StagedListCell(line.line, cell.col, cell.width, text));
    _w.listCellScreen = _screenIdentity(m);
  }

  /// The list round's cell writes, consumed — the staged cells when they
  /// were typed on the active screen (else none: dropped), in ascending
  /// buffer order (line, then column) — and the cell touched last, the
  /// round's list cursor (a recorded session gui[10]).
  (List<(int, int, String)>, (int, int)?) _takeListCellWrites() {
    final staged = _w.stagedListCells;
    if (staged.isEmpty) return (const <(int, int, String)>[], null);
    final m = screen;
    final here = m != null && _screenIdentity(m) == _w.listCellScreen;
    final writes = here
        ? ([for (final c in staged) c.write]
            ..sort((a, b) =>
                a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2)))
        : const <(int, int, String)>[];
    final last = here ? (staged.last.line, staged.last.col) : null;
    if (writes.isEmpty) _trace('staged list cells dropped: $staged');
    staged.clear();
    _w.listCellScreen = null;
    return (writes, last);
  }

  /// A function key on a list with staged input cells: the Windows list
  /// key round carrying them, the cursor on the cell touched last
  /// (a recorded session gui[12]: F3 commits the typed cell in ONE
  /// round, no item 17; a recorded session gui[10]: the
  /// toolbar's Ctrl+F8 over three toggles of two checkboxes); null without
  /// staged cells (the ordinary key round).
  Future<List<Uint8List>>? _listCellKeyRound(int vkey) {
    if (_w.stagedListCells.isEmpty ||
        answerDialect != GuiDialect.windows) {
      return null;
    }
    final (writes, last) = _takeListCellWrites();
    if (writes.isEmpty || last == null) return null;
    final (line, col) = last; // the cursor on the cell touched last
    return _act(
      listPickItems(ctx, line, col,
          vkey: vkey, windowPx: windowsEventWindowPx(ctx), xml: null,
          writes: writes),
      dialectReady: true,
    );
  }

  /// Pick [line] of the active window's classic list — an F4 hit list
  /// popup (SAPLSEUA's "Programmes rech." / SAPMSSY0 0120) or a report
  /// list — with F2 ([vkey]) and the list cursor on the line's hotspot
  /// column (reference client raw_listpick.list_pick, its Windows branch; pinned on
  /// the accepted SE38 F4 pick, a recorded session
  /// step 53). The server closes the popup and paints the picked value
  /// into the field F4 was pressed on.
  Future<List<Uint8List>> pickValue(ListLine line, {int vkey = 2}) {
    final m = screen;
    if (m == null || !m.listLines.any((l) => l.line == line.line)) {
      throw ArgumentError('list line ${line.line} is not painted');
    }
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError('the list pick is built for the Windows dialect');
    }
    return _act(
      listPickItems(
        ctx,
        line.line,
        line.hotspotCol,
        vkey: vkey,
        windowPx: windowsEventWindowPx(ctx),
        xml: liveMetricsXml(ctx.screenRows, ctx.screenCols),
        writes: _takeListCellWrites().$1,
      ),
      dialectReady: true,
    );
  }

  /// The same F2 pick on any classic list — a report list's line
  /// selection (AT LINE-SELECTION / PICK, the reference client's list_pick default
  /// and its Windows oracle a recorded session gui raw[133], SA38 RSPARAM),
  /// the SAPMSSY0/0120 popup body; [vkey] 9 / 7 / 8 for a list whose
  /// status binds the line action to another key.
  Future<List<Uint8List>> pickListLine(ListLine line, {int vkey = 2}) =>
      pickValue(line, vkey: vkey);

  // --- double-click: the choose key on an element -------------------------
  //
  // SAP GUI has no "double-click" event on a dynpro element: a mouse
  // double-click moves the cursor to the element (client side, no frame)
  // and presses the CHOOSE key F2 there — one key round with the cursor on
  // the element (a recorded session gui[19] / gui[22], the double-
  // click and the click + F2 on a step-loop line: the same key, the same
  // cursor). What the application does with it is the status' F2 function:
  // "Options de sélection" on a selection screen (SAPLSETB/1000), "Gestion
  // des options de sélection" in SAPLALDB/3000 — both open SAPLALDB/0651
  // (live the test system, a recorded session gui_03 / gui_17), a line pick
  // in a hit list, a drill in a report.

  /// The key a mouse double-click sends: always the choose key F2. The
  /// popups' statuses do not tell the one recorded Enter double-click
  /// (a recorded session gui[7], SES `50 00` on a line of
  /// SAPLF004/1000's GJTABCONTROL) from the F2 ones: SAPLF004/1000 (TCTRL)
  /// and SAPMSSCF/1210 (PICK, F2 double-click gui[19]) paint the same
  /// `F2 Sélectionner` function key.
  static const int doubleClickVkey = 2;

  /// Double-click element [f] of the active window — an input field (a
  /// protected one too: an icon field, an output-only value), a
  /// table-control cell ([ScreenField.tableControl] — the
  /// cursor on its visible line and column): the choose key
  /// ([doubleClickVkey]) with the cursor on the element, in the real GUI's
  /// double-click form ([windowsActionItems] `doubleClick`: no key source
  /// on a main window, the SELECT source in a popup; a cell's round in its
  /// control's TABLE plane without a key source — a recorded session
  /// nested_button gui[26]). [caret] = the character the click landed on
  /// (the 16/9/11 offset).
  ///
  /// Typed values ride the round as they ride any key: the staged fields
  /// in one field round, the focus on [f] ([valueHelp]'s rule); the staged
  /// cells of [f]'s table control in its TABLE-plane round (the cells in
  /// one 16/9/9, the cursor on [f]); anything else goes first as its own
  /// Enter round.
  ///
  /// A pushbutton's double-click is its click (the first click fires it):
  /// its function code. A selection screen's option icon (`%_<SELOPT>_%_APP
  /// _%-OPTI_PUSH`, the icon in front of LOW once a value is set) aims at
  /// its select-option's LOW field ([selectOptionValueField]): the cursor on
  /// the icon itself is answered "Positionnez le curseur sur un critère de
  /// sélection" (live the test system, a recorded session gui_02 / srv_03).
  Future<List<Uint8List>> doubleClick(ScreenField f, {int caret = 0}) async {
    final m = screen;
    if (m == null || !m.fields.contains(f)) {
      throw ArgumentError('${f.name} is not an element of the active window');
    }
    if (f.kind == FieldKind.pushbutton) {
      final fc = (f.fcode ?? '').trim();
      if (fc.isNotEmpty) return okcode(fc);
    }
    if (f.tableControl == null &&
        (f.kind == FieldKind.label || f.kind == FieldKind.output)) {
      // the cursor on a keyword / text atom: the kernel tore SE71 down with
      // "FOCUS DATA" (00 123) for the reference client's cursor on the 1210 popup's
      // header LABEL (a recorded session DECODE, complaint-se71
      // +20261002-123510); every recorded double-click lands on a field
      // atom (etype 130, protected or not) or a table-control cell
      throw ArgumentError(
        '${f.name ?? 'a text'} takes no cursor: only a field '
        'or a table-control cell answers a double-click',
      );
    }
    final target = selectOptionValueField(m, f) ?? f;
    if (!identical(target, f)) caret = 0;
    final vkey = doubleClickVkey;
    if (target.tableControl != null) {
      return _cellDoubleClick(target, vkey);
    }
    if (_stagedHasCells) await _sendStagedCellsFirst();
    if (_staged.isNotEmpty) {
      final i = _staged.indexWhere((s) => _sameField(s.field, target));
      if (i >= 0) _staged.add(_staged.removeAt(i)); // the clicked field last
      final round = _stagedRound(
        vkey: vkey,
        cursor: i >= 0
            ? null
            : FieldCursor(
                target.wireRow,
                target.wireCol,
                area: target.area,
                routing: target.routing,
              ),
      );
      if (answerDialect != GuiDialect.windows) {
        return _act(round, consumesStaged: true);
      }
      return _act(
        windowsActionItems(
          round,
          ctx: ctx,
          controlState: gridSelections.values.any((g) => g.pending),
          firstRound: _w.firstRoundOwed,
          doubleClick: true,
        ),
        dialectReady: true,
        consumesStaged: true,
      );
    }
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError(
        'the double-click round is built for the Windows dialect',
      );
    }
    return _act(
      windowsActionItems(
        pressItems(ctx, vkey),
        ctx: ctx,
        cursor: elementCursorBytes(target, caret: caret),
        controlState: gridSelections.values.any((g) => g.pending),
        firstRound: _w.firstRoundOwed,
        doubleClick: true,
      ),
      dialectReady: true,
    );
  }

  /// The double-click on table-control cell [cell]: the choose key in the
  /// control's TABLE plane, the cursor on the cell, no key source; this
  /// control's typed cells ride it.
  Future<List<Uint8List>> _cellDoubleClick(ScreenField cell, int vkey) async {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError(
        'table-control rounds are built for the Windows dialect only',
      );
    }
    final name = cell.tableControl!;
    if (_stagedHasCells) {
      final merged = _stagedCellRound(
        name,
        vkey: vkey,
        cursor: cell,
        keySource: false,
      );
      if (merged != null) {
        return _act(merged, dialectReady: true, consumesStaged: true);
      }
      await _sendStagedCellsFirst();
    }
    if (_staged.isNotEmpty) await _act(_stagedRound(), consumesStaged: true);
    final tc = screen?.tableControls.where((t) => t.name == name).firstOrNull;
    if (tc == null) {
      throw StateError('table control $name is not painted on this screen');
    }
    return _act(
      tableCellItems(
        ctx,
        tc,
        const [],
        cursorLine: cell.tcLine!,
        cursorColumn: cell.tcColumn!,
        vkey: vkey,
        keySource: false,
      ),
      dialectReady: true,
    );
  }

  /// Click PUSHBUTTON cell [cell] of a table control (the option button
  /// `=SI01` of SAPLALDB/3000's SINGLE, the "O." column): its function
  /// code in the control's TABLE plane, the cursor on the cell
  /// ([tableCellItems] `okcode` — the round the test system accepted on SAPLALDB/3000,
  /// a recorded session gui_08: it opened SAPLALDB/0651). The
  /// control's typed cells ride it in its 16/9/9; anything else goes first.
  Future<List<Uint8List>> pressCellButton(ScreenField cell) async {
    final name = cell.tableControl;
    final fc = (cell.fcode ?? '').trim();
    if (name == null || cell.kind != FieldKind.pushbutton || fc.isEmpty) {
      throw ArgumentError('${cell.name} is no pushbutton cell of a control');
    }
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError(
        'table-control rounds are built for the Windows dialect only',
      );
    }
    if (_stagedHasCells) {
      final merged = _stagedCellRound(name, cursor: cell, okcode: fc);
      if (merged != null) {
        return _act(merged, dialectReady: true, consumesStaged: true);
      }
      await _sendStagedCellsFirst();
    }
    if (_staged.isNotEmpty) await _act(_stagedRound(), consumesStaged: true);
    final tc = screen?.tableControls.where((t) => t.name == name).firstOrNull;
    if (tc == null) {
      throw StateError('table control $name is not painted on this screen');
    }
    return _act(
      tableCellItems(
        ctx,
        tc,
        const [],
        cursorLine: cell.tcLine!,
        cursorColumn: cell.tcColumn!,
        okcode: fc,
      ),
      dialectReady: true,
    );
  }

  /// The painted table-control PUSHBUTTON cell whose function code is
  /// [cmd] (`=SI01`), null when none or several carry it.
  ScreenField? _paintedCellButton(String cmd) {
    final want = cmd.trim().replaceFirst(RegExp('^='), '').toUpperCase();
    if (want.isEmpty) return null;
    final hits = [
      for (final f in screen?.fields ?? const <ScreenField>[])
        if (f.kind == FieldKind.pushbutton &&
            f.tableControl != null &&
            (f.fcode ?? '')
                    .trim()
                    .replaceFirst(RegExp('^='), '')
                    .toUpperCase() ==
                want)
          f,
    ];
    return hits.length == 1 ? hits.single : null;
  }

  /// The staged values (+ [extra], replacing a staged value of its field)
  /// as one field round (Java spelling; [_act] re-spells it).
  List<Uint8List> _stagedRound({
    int vkey = 0,
    String? okcode,
    (int, int, List<int>)? button,
    FieldCursor? cursor,
    StagedField? extra,
  }) {
    final all = [
      for (final s in _staged)
        if (extra == null || !_sameField(s.field, extra.field)) s,
      if (extra != null) extra,
    ];
    return fieldRoundItems(
      ctx,
      [for (final s in all) _writeOf(s)],
      vkey: vkey,
      okcode: okcode,
      button: button,
      cursor: cursor,
    );
  }

  FieldWrite _writeOf(StagedField s) {
    final f = s.field;
    // a secret's value atom always carries the INVISIBLE attribute (0x02):
    // the painted byte already does on every logon paint (0020; the 0029
    // remote logon RSYST-BCODE paints 0x62 — a recorded session
    // SAPMSYST_1 frame 2, a recorded session SAPMSYST_1), and
    // the reference client's remote-logon submit forces it (remote_login.build_submit
    // `pl["RSYST-BCODE"]["invisible"] = True`)
    final attr = s.secret ? f.attr | attrInvisible : f.attr;
    return FieldWrite(
      f.wireRow,
      f.wireCol,
      s.text,
      area: f.area,
      block: f.block,
      group: f.group,
      mx: f.maxnrchars > 0 ? f.maxnrchars : null,
      mlen: f.mlen > 0 ? f.mlen : null,
      attr: attr,
      routing: f.routing,
    );
  }

  // --- staged table-control cells (Windows) ---------------------------------
  //
  // A table-control cell has no screen atom: the SAP GUI for Windows sends
  // a typed cell in the control's TABLE plane — its legs, the 16/9/14
  // header echo, the 16/12/2 control area, the 16/9/9 cell(s), the line
  // focus — never as a 16/9/2 field atom (the test system answered a staged
  // SAPLALDB/3000 cell pair + F8 sent as 16/9/2 atoms with "FOCUS DATA",
  // T100 00 123, and tore the transaction down — live 2026-10-11 19:45).
  // A key pressed over typed cells is ONE table-plane round with the
  // table-control 16/15/1 at the cursor cell (a recorded session
  // gui[313]: a typed EVCTRL cell + F4; gui[319]: + Enter).

  /// Whether a staged value is a table-control cell of a Windows session.
  bool get _stagedHasCells =>
      answerDialect == GuiDialect.windows &&
      _staged.any((s) => s.field.tableControl != null);

  /// The staged values as ONE table-plane round of [tc] when every staged
  /// value is a cell of it (+ [extra] cells, replacing a staged value of
  /// their cell), the cursor on [cursor] (default: the last cell edited),
  /// committed with [vkey]; null when the staged set holds anything else
  /// (a screen field, another control's cell).
  List<Uint8List>? _stagedCellRound(
    String tc, {
    int vkey = 0,
    ScreenField? cursor,
    List<(ScreenField, String)> extra = const [],
    bool keySource = true,
    String? okcode,
  }) {
    if (_staged.any((s) => s.field.tableControl != tc)) return null;
    final info = screen?.tableControls.where((t) => t.name == tc).firstOrNull;
    if (info == null) return null;
    final cells = [
      for (final s in _staged)
        if (!extra.any((e) => _sameField(e.$1, s.field))) (s.field, s.text),
      ...extra,
    ];
    if (cells.isEmpty) return null;
    final at = cursor ?? cells.last.$1;
    if (at.tableControl != tc) return null;
    return tableCellItems(
      ctx,
      info,
      [for (final (f, v) in cells) _cellWrite(info, f, v)],
      cursorLine: at.tcLine!,
      cursorColumn: at.tcColumn!,
      vkey: vkey,
      keySource: keySource,
      okcode: okcode,
    );
  }

  /// The table-plane round of a key [vkey] over the staged values when
  /// they are cells of one table control (the cursor on the last cell
  /// edited, or [cursor]); null otherwise.
  List<Uint8List>? _stagedCellKeyRound(int vkey, {ScreenField? cursor}) {
    if (!_stagedHasCells) return null;
    final tc = cursor?.tableControl ?? _staged.last.field.tableControl;
    if (tc == null) return null;
    return _stagedCellRound(tc, vkey: vkey, cursor: cursor);
  }

  /// Send the staged table-control cells ahead of an action whose frame
  /// cannot carry them (an okcode, a screen field's write, a mixed staged
  /// set): one Enter table-plane round per control — the reference client's
  /// deferred_fill rule for a merged frame no capture pins. The staged
  /// screen fields are kept for the action when the answer repaints the
  /// same program / dynpro / window level (re-bound to the new paint's
  /// fields), else dropped as any staged value is on a screen change.
  Future<void> _sendStagedCellsFirst() async {
    while (_stagedHasCells) {
      final identity = _stagedScreen;
      final tc = _staged
          .firstWhere((s) => s.field.tableControl != null)
          .field
          .tableControl!;
      final rest = [
        for (final s in _staged)
          if (s.field.tableControl != tc) s,
      ];
      _staged.removeWhere((s) => s.field.tableControl != tc);
      final items = _stagedCellRound(tc);
      if (items == null) {
        // the control is no longer painted: its cells cannot be bound
        _trace('staged cells of $tc dropped (control not painted)');
        _staged
          ..clear()
          ..addAll(rest);
        if (_staged.isEmpty) _stagedScreen = null;
        continue;
      }
      _trace('staged cells of $tc sent first as an Enter round');
      await _act(items, dialectReady: true, consumesStaged: true);
      final m = screen;
      if (rest.isEmpty || m == null || _screenIdentity(m) != identity) {
        if (rest.isNotEmpty) _trace('staged fields dropped (screen left)');
        continue;
      }
      for (final s in rest) {
        final f = m.fields.where((f) => _sameField(f, s.field)).firstOrNull;
        if (f != null && f.kind == FieldKind.input && !f.isProtected) {
          _staged.add(StagedField(f, s.text));
        } else {
          _trace('staged field ${s.field.name} dropped (not repainted)');
        }
      }
      _stagedScreen = _staged.isEmpty ? null : _screenIdentity(m);
    }
  }

  /// The painted pushbutton [cmd] (`=FCODE`) fires, as (row, col, path).
  (int, int, List<int>)? _paintedButton(String cmd) =>
      paintedPushbutton(screen, cmd);

  void _dropStaged(String why) {
    if (_staged.isEmpty) return;
    _trace('staged fields dropped ($why): $_staged');
    _staged.clear();
    _stagedScreen = null;
  }
}

bool _sameField(ScreenField a, ScreenField b) =>
    identical(a, b) ||
    (a.container == b.container &&
        a.area == b.area &&
        a.wireRow == b.wireRow &&
        a.wireCol == b.wireCol &&
        a.name == b.name);

(String?, String?, int) _screenIdentity(ScreenModel m) =>
    (m.program, m.dynpro, m.modalLevel);

/// A command that leaves the screen (`/n…`, `/o…`, `/i`, `/nex`): the
/// screen's typed values are abandoned, as `/n` abandons them in SAP GUI.
bool _leavesScreen(String cmd) => cmd.trimLeft().startsWith('/');

/// The 16/9/11 cursor of a key aimed at element [f] in its client form:
/// depth = the container path's length, the element's WIRE cell, the
/// [caret] offset, the path ([FieldRouting.path], else the atom's area) —
/// the cursor [SapSessionFields.valueHelp] aims F4 with.
///
/// A STEP-LOOP line's path names the loop once: its 16/10/4 level IS the
/// atoms' area plane (SAPMSSCF/1210 and /1160: the loop `01 …`, the lines
/// on area 1), and the real GUI's cursor on a line is `01 <line> 0000
/// <caret> 01` (a recorded session gui[19] / gui[22],
/// a recorded session gui[22]) where the write routing reads
/// `[1, 1]`.
Uint8List elementCursorBytes(ScreenField f, {int caret = 0}) {
  final path = _elementPath(f);
  final focus = Uint8List(9 + path.length);
  focus[0] = path.length;
  final bd = focus.buffer.asByteData();
  bd.setUint16(1, f.wireRow);
  bd.setUint16(3, f.wireCol);
  bd.setUint32(5, caret < 0 ? 0 : caret);
  focus.setRange(9, focus.length, path);
  return focus;
}

List<int> _elementPath(ScreenField f) {
  final r = f.routing;
  if (r == null) return [f.area & 0xff];
  final p = r.path;
  final last = r.pre.isEmpty ? null : r.pre.last;
  if (p.length >= 2 &&
      last != null &&
      last.id == 10 &&
      last.sid == 4 &&
      last.value.isNotEmpty &&
      last.value[0] == p.last &&
      p[p.length - 2] == p.last) {
    return p.sublist(0, p.length - 1);
  }
  return p;
}

final _optionIcon = RegExp(r'^%_(.+)_%_APP_%-OPTI_PUSH$');

/// Whether [f] is a selection screen's OPTION icon: the output
/// `%_<SELOPT>_%_APP_%-OPTI_PUSH` the server paints in front of a
/// select-option's LOW once it holds a value (`@28\QSélectionner : inclure
/// modèle@` after `1*` — a recorded session srv_02).
bool isSelectOptionIcon(ScreenField f) => _optionIcon.hasMatch(f.name ?? '');

/// The LOW input of the select-option whose option icon is [f]
/// ([isSelectOptionIcon]) on [m], null for any other element: the cell the
/// choose key acts on for the icon.
ScreenField? selectOptionValueField(ScreenModel m, ScreenField f) {
  final hit = _optionIcon.firstMatch(f.name ?? '');
  if (hit == null) return null;
  final low = '${hit.group(1)}-LOW';
  return m.fields
      .where((x) => x.name == low && x.container == f.container)
      .firstOrNull;
}
