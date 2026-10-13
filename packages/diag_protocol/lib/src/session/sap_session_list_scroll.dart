part of 'sap_session.dart';

/// Scrolling the active window's classic list past the page the server
/// painted (list_scroll.dart): the real SAP GUI for Windows' VSCROLL round
/// for a scroll-bar drag / wheel, its function-key round for the paging
/// keys. The server answers either with the whole list repainted at the new
/// first line (16/12/2 [ScreenModel.listWindow]).

/// The step of the last list round each session sent (the 16/4/38 it
/// carried): the next one is a RUN of the same list when it goes out at
/// that step + 1 — the server's repaint the only frame in between — and
/// then carries no popup window rect (a recorded session gui[70] with
/// the 16/4/36, gui[71..74] without).
final Expando<(int, int)> _listRoundAt = Expando('list round step');

extension _SapSessionListScroll on SapSession {
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
        windowPx: windowsEventWindowPx(c), windowRect: !run);
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

  /// A paging key ([listScrollVkeys]) on a paged list: null when the
  /// active window paints none (the ordinary key round then).
  Future<List<Uint8List>>? _listPagingKey(int vkey) {
    if (!listScrollVkeys.contains(vkey) ||
        answerDialect != GuiDialect.windows) {
      return null;
    }
    final m = screen;
    if (m == null || !ctx.paintedList || listPageOf(m) == null) return null;
    _trace('list paging key $vkey');
    final run = _listRoundRun();
    final c = ctx;
    return _act(
      windowsListKeyItems(c, vkey,
          windowPx: windowsEventWindowPx(c), windowRect: !run),
      dialectReady: true,
    );
  }
}
