part of 'sap_session.dart';

/// Scrolling the active window's classic list past the page the server
/// painted (list_scroll.dart): the real SAP GUI for Windows' VSCROLL round
/// for a scroll-bar drag / wheel, its function-key round for the paging
/// keys. The server answers either with the whole list repainted at the new
/// first line (16/12/2 [ScreenModel.listWindow]). Every other key and a
/// typed code on a list window go out in the same envelope (select line,
/// block select, the pick), with the list cursor a click moved locally
/// ([SapSessionListCursor]).

/// The step of the last list round each session sent (the 16/4/38 it
/// carried): the next one is a RUN of the same list when it goes out at
/// that step + 1 — the server's repaint the only frame in between — and
/// then carries no popup window rect (a recorded session gui[70] with
/// the 16/4/36, gui[71..74] without). A main-window list round carries
/// none at all (a recorded session g13 .. g58).
final Expando<(int, int)> _listRoundAt = Expando('list round step');

/// The sessions whose window already sent a list RESIZE round: only the
/// first carries the 16/4/36 window rect (a recorded session
/// _scroll g60 with it, g61 / g62 without).
final Expando<bool> _listResized = Expando('list resize sent');

/// The keys a popup list round sends without its cursor: Back F3, Cancel
/// F12, Exit F15 (a recorded session gui[20] `50 0c`).
const Set<int> _popupCursorlessVkeys = {3, 12, 15};

extension _SapSessionListScroll on SapSession {
  /// The resize round of a window showing a classic list — null when the
  /// active window paints none (the dynpro resize round then).
  List<Uint8List>? _listResizeItems() {
    final m = screen;
    if (m == null || !ctx.paintedList || m.listWindow == null) return null;
    final first = _listResized[this] != true;
    _listResized[this] = true;
    return windowsListResizeItems(ctx,
        windowPx: windowsEventWindowPx(ctx), windowRect: first);
  }

  /// The active window's list page, refused (with the reason) when no
  /// paged classic list is on it.
  ListPage _pagedList() {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError('the list scroll is built for the Windows dialect');
    }
    final m = screen;
    final page = m == null ? null : listPageOf(m);
    if (page == null) {
      throw StateError('no classic list window (16/12/2) on this screen');
    }
    return page;
  }

  /// Whether the round about to go out continues a run of list rounds on
  /// the same window (see [_listRoundAt]); records this one.
  bool _listRoundRun() {
    final c = ctx;
    final last = _listRoundAt[this];
    _listRoundAt[this] = (c.step, c.modalNo);
    return last != null && last.$2 == c.modalNo && c.step == last.$1 + 1;
  }

  Future<List<Uint8List>> _scrollList(int firstLine) {
    final page = _pagedList();
    final target = page.clampFirst(firstLine);
    _trace('list scroll to line $target (page ${page.first}, '
        'total ${page.total})');
    final run = _listRoundRun();
    final c = ctx;
    var items = windowsListScrollItems(c, target,
        windowPx: windowsEventWindowPx(c), windowRect: !run && c.modalNo != 0);
    // typed / ticked list cells ride the round (the real GUI's touched set
    // rides the next round of the list, a recorded session
    // gui[10] — a key round; a scroll round carrying them is not recorded):
    // the list round with the cells and the cursor on the cell touched last,
    // the VSCROLL SES in place of the key's
    if (_w.stagedListCells.isNotEmpty) {
      final (writes, last) = _takeListCellWrites();
      if (writes.isNotEmpty && last != null) {
        final cells = listPickItems(c, last.$1, last.$2,
            vkey: 0, windowPx: windowsEventWindowPx(c), xml: null,
            writes: writes);
        items = [items[0], items[1], ...cells.sublist(2)];
      }
    }
    return _act(items, dialectReady: true);
  }

  /// A function key on a Windows list window: the list key round
  /// ([windowsListKeyItems]) — the paging keys, F9 select line, F6 block
  /// select, F2, F3, F12, whatever the list's status binds (a recorded session
  /// _mainwindow_list_rowsel_scroll g9 / g11 / g21 / g25 / g27 / g29 / g31,
  /// a recorded session gui[20] / [22] / [71]); null when the active window
  /// paints no list (the ordinary key round then). A paging key needs a
  /// paged list (a 16/12/2 window); a popup round carries its window rect
  /// on the first round of a run ([_listRoundAt]).
  Future<List<Uint8List>>? _listKey(int vkey) {
    if (answerDialect != GuiDialect.windows || !ctx.paintedList) return null;
    final m = screen;
    if (m == null) return null;
    if (listScrollVkeys.contains(vkey) && listPageOf(m) == null) return null;
    _trace('list key $vkey');
    _noteModeCommand(vkey: vkey); // Ctrl+N opens a window
    final run = _listRoundRun();
    final c = ctx;
    // a line key on a POPUP list (Sélectionner = F2 on the SAPMSSY0 popup
    // of SAPRDEMOWORD97INTEGRATION OPEN): the pick round with the list
    // cursor, as a double-click sends it (pickValue; reference client raw_listpick,
    // a recorded session step 53) — the cursorless
    // popup envelope below left the server no line to act on, it painted
    // the same popup again (live 2026-10-14). Back / Cancel / Exit and the
    // paging keys keep the recorded cursorless shape (a recorded session
    // gui[20], a recorded session gui[70..74]).
    final at = listCursor;
    if (c.modalNo != 0 &&
        at != null &&
        !_popupCursorlessVkeys.contains(vkey) &&
        !listScrollVkeys.contains(vkey)) {
      return _act(
        listPickItems(c, at.$1, at.$2,
            vkey: vkey,
            windowPx: windowsEventWindowPx(c),
            xml: liveMetricsXml(c.screenRows, c.screenCols),
            writes: _takeListCellWrites().$1),
        dialectReady: true,
      );
    }
    return _act(
      windowsListKeyItems(c, vkey,
          windowPx: windowsEventWindowPx(c), windowRect: !run && c.modalNo != 0),
      dialectReady: true,
    );
  }

  /// A typed function code on a Windows MAIN-window list: the list okcode
  /// round ([windowsListOkcodeItems], rowsel_scroll g33 `/nex`); null
  /// elsewhere (no capture types a code on a popup list).
  Future<List<Uint8List>>? _listOkcode(String cmd) {
    if (answerDialect != GuiDialect.windows ||
        !ctx.paintedList ||
        ctx.modalNo != 0 ||
        screen == null) {
      return null;
    }
    _trace('list okcode $cmd');
    _listRoundRun();
    final c = ctx;
    return _act(
      windowsListOkcodeItems(c, cmd, windowPx: windowsEventWindowPx(c)),
      dialectReady: true,
    );
  }
}

/// The classic list's CURSOR: a click on a list line moves it and sends
/// nothing (a recorded session: the clicks before
/// g11 / g25 / g29 / g31 and the Ctrl+click before g21 are wire-silent —
/// the Ctrl+click selects nothing either); the next list round carries it
/// in its 16/12/13 ([windowsListKeyItems]), and the server's repaint sets
/// it again (moved with the page, or dropped once its line left the
/// window — [ScreenModel.listCursor]).
extension SapSessionListCursor on SapSession {
  /// The list cursor the next list round carries: (buffer row, column) —
  /// the last paint's, or where [setListCursor] moved it since; null when
  /// the window shows no list or the paint dropped it.
  (int, int)? get listCursor {
    final v = ctx.paintedList ? ctx.paintedListCursor : null;
    if (v == null || v.length < 5) return null;
    return (v[1] << 8 | v[2], v[3] << 8 | v[4]);
  }

  /// Move the active window's list cursor to buffer row [row] (a
  /// [ListLine.line]: the window row, the page heading included), column
  /// [col] — locally, no frame (a click on the real GUI). Ignored when the
  /// window paints no list.
  void setListCursor(int row, int col) {
    if (!ctx.paintedList) return;
    _trace('list cursor $row,$col (local)');
    ctx.paintedListCursor = listCursorValue(row, col);
  }

  /// A double-click on list line [line] at column [col]: the cursor moved
  /// there, then the choose key F2 ([vkey]) — on a Windows MAIN-window list
  /// the list key round with that cursor (rowsel_scroll g9: `50 02`, CHL
  /// 0d, 16/12/8, 16/12/13 `[7, 4]` where the user double-clicked, no item
  /// 17); elsewhere (a popup hit list, staged list cells) [pickValue].
  Future<List<Uint8List>> pickListAt(ListLine line, int col, {int vkey = 2}) {
    if (answerDialect == GuiDialect.windows &&
        ctx.paintedList &&
        ctx.modalNo == 0 &&
        _w.stagedListCells.isEmpty) {
      setListCursor(line.line, col);
      return press(vkey);
    }
    return pickValue(line, vkey: vkey);
  }
}
