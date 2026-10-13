/// Scrolling a classic ABAP list beyond the page the server painted.
///
/// The server sends a classic list (SAPMSSY0/0120: a report, an STMS
/// import queue, an F4 hit list) ONE PAGE at a time: the fixed page heading
/// rows, then `visible` body lines starting at the list's current first
/// line. The page's extent rides every list paint twice:
///
/// * 16/12/2 SCROLL_INFOS, 6 x u32: total lines, total columns, visible
/// lines, visible columns, the CURRENT first body line (0-based), 0
/// ([ScreenModel.listWindow]); and
/// * the server's type-9 CHL item: byte 6 = visible lines, bytes 12..13 =
/// total lines (u16, saturating at 0x7fff), bytes 14..15 = the first
/// line — the same figures (365 of the corpus' 366 list paints agree,
/// the one exception a 144 565-line list whose CHL saturated).
///
/// The buffer rows of a list paint are WINDOW rows: the heading rows first,
/// then the body, whatever the first line (a recorded session trace
/// 1e763853b826: `SAPMSSY0/0120` "File d'attente d'import : système <SID>",
/// 16/12/2 `204 / 243 / 50 / 243 / first`, buffer rows 0..5 the heading,
/// rows 6..55 the requests `first + 1 .. first + 50` for first 0, 50, 154).
///
/// The real SAP GUI for WINDOWS scrolls such a list by asking the server for
/// the page — two rounds, both answered by a full repaint of the list with
/// the new first line in its 16/12/2:
///
/// * the scroll bar / mouse wheel: the VSCROLL event — SES eventarray
/// 0x56 (`V`; the Java GUI's eventarray 4, kernel enum 4 = VSCROLL) with
/// the NEW FIRST LINE, 1-based, as a u16 in eventid3..eventid4 (SES
/// bytes 3..4), no vkey, no okcode, no 16/15/1, no item 17
/// (a recorded session g13 `56 00 00 00 af` — the
/// scroll bar dragged to the bottom, ONE round on release, answered by
/// first 174 = 220 - 46 — and g15..g53, the wheel: one round PER LINE,
/// targets 174 .. 155 answered by first 173 .. 154, target - 1 in all 21
/// rounds; a recorded session gui[70..74], real Windows GUI, SAPMSSY0/0120
/// popup list of 40 lines / 27 visible: `56 00 00 00 02` … `05`, `0e` —
/// answered by 16/12/2 first 1, 2, 3, 4, 13; a recorded session
/// gui[42] / [43] `… 02`, `… 01`). The Java GUI's own VSCROLL rounds
/// carry the target the same way (a recorded session g[16] / g[18]
/// `04 00 00 00 a9` → first 168, `… 01` → 0; a recorded session
/// _java gui[80] `04 00 00 07 d3` — the high byte in eventid3);
/// * Page Up / Page Down / Ctrl+Page Up / Ctrl+Page Down: the function
/// key round (SES 0x50, eventid1 = vkey 81 / 82 / 80 / 83) in the same
/// envelope (mainwindow_list_scroll g55 `50 52`, g56 `50 51`, g58 `50 53`;
/// a recorded session gui[27] in a popup) — the server
/// moves the page itself, and Page Down does NOT stop at the last full
/// page: from first 154 of 220 (46 visible) it answers first 200 with a
/// 20-line page (16/12/2 visible 20), Ctrl+Page Down first 174;
/// * a RESIZE of the window over the list ([windowsListResizeItems]): SES
/// 0x52 with the new pixels in 16/12/8 (mainwindow_list_scroll g60..g62),
/// answered by the page laid out for the new window at the SAME first
/// line (174: visible 17 / 7 / 30).
///
/// The envelope by window:
/// * a MAIN-window list round: the list OK event CHL `00 0d` over zeros,
/// the window's 16/12/8 (h, w, h, w px) and the list cursor 16/12/13 —
/// the one the last paint set, or where a click moved it since (a click
/// sends no frame: a recorded session g21
/// carries the Ctrl+clicked `[28, 92]`) — no 16/9/10, no 16/4/36, not
/// even on the first scroll round (mainwindow_list_scroll g13 .. g58,
/// `01 0001 0001` after every repaint there). The server keeps the
/// cursor on its line as the page moves (rowsel_scroll: row 31, 30 … 27
/// while first goes 0 .. 4); once the line leaves the window the paint
/// drops the 16/12/13 (its CHL `0b`, an empty 16/9/10) and the next
/// round is cursorless: CHL `00 0b`, the 16/12/8, the empty 16/9/10
/// (rowsel_scroll g23). The first RESIZE round carries the 16/4/36
/// window rect after the SES (g60), the next ones none (g61 / g62);
/// * a POPUP list round: the cursorless CHL `00 0b` over zeros, the empty
/// 16/9/10, no 16/12/8, and the popup's 16/4/36 window rect right after
/// the SES on the first round of a run — a scroll repeated on the same
/// list carries none (bwadapterjoin gui[70] with it, gui[71..74]
/// without; f4_modes_ctrl gui[42] / gui[43]).
///
/// A target past 65 535 has no recorded spelling (eventid2 is never set):
/// it is clamped to 65 535.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../codepages.dart';
import '../framing/envelope.dart';
import '../screen/screen_model.dart';
import 'actions.dart';
import 'frames.dart';
import 'frontend_profile.dart';

/// The SES eventarray byte of the VSCROLL event on a Windows connection
/// (the Java spelling is [javaSesVScroll]).
const int winSesVScroll = 0x56;

/// The kernel's (and the Java GUI's) SES eventarray value of VSCROLL.
const int javaSesVScroll = 0x04;

/// The paging keys of a classic list: Ctrl+Page Up (first page), Page Up,
/// Page Down, Ctrl+Page Down (last page).
const int vkeyFirstPage = 80,
    vkeyPageUp = 81,
    vkeyPageDown = 82,
    vkeyLastPage = 83;

/// [vkeyFirstPage] .. [vkeyLastPage].
const Set<int> listScrollVkeys = {
  vkeyFirstPage,
  vkeyPageUp,
  vkeyPageDown,
  vkeyLastPage,
};

/// The highest target line the VSCROLL SES can spell (eventid3..4).
const int listScrollMaxLine = 0xffff;

/// The page of a classic list the server painted: the list's extent
/// ([total] body lines), the page ([visible] lines from [first], 0-based)
/// and how the painted buffer rows split into the fixed heading
/// ([headerRows]: buffer rows 0 .. headerRows-1) and the body ([received]
/// lines: buffer row headerRows + k = list line first + k).
class ListPage {
  const ListPage({
    required this.total,
    required this.visible,
    required this.first,
    required this.headerRows,
    required this.received,
  });

  final int total;
  final int visible;
  final int first;
  final int headerRows;
  final int received;

  /// The list is longer than its page: the server pages it.
  bool get scrolls => total > visible;

  /// The highest first line a page can start at.
  int get maxFirst => math.max(0, total - visible);

  /// The list line (0-based) buffer row [row] shows; null for a heading row.
  int? lineOfRow(int row) => row < headerRows ? null : first + row - headerRows;

  /// The buffer row list line [line] (0-based) is painted at; null when the
  /// page does not hold it.
  int? rowOfLine(int line) => line < first || line >= first + received
      ? null
      : headerRows + line - first;

  /// [line] clamped to a valid first line.
  int clampFirst(int line) => line.clamp(0, maxFirst);

  @override
  String toString() =>
      'ListPage($first+$received of $total, visible $visible, '
      'heading $headerRows)';
}

/// The page [m]'s classic list shows, from its 16/12/2 ([ScreenModel
/// .listWindow]) and its painted rows; null without a list window. The
/// body is the LAST rows of the paint (min(visible, total - first) of
/// them), the rows above it the page heading (the server paints a blank
/// row too: SAPMSSY0's rows 0 and 2 above the queue's box).
ListPage? listPageOf(ScreenModel m) {
  final w = m.listWindow;
  if (w == null || w.length < 5 || m.listPaint.isEmpty) return null;
  final total = w[0], visible = w[2], first = w[4];
  if (visible <= 0) return null;
  final rows = m.listPaint.last.line + 1;
  var received = math.max(0, math.min(visible, total - first));
  var header = rows - received;
  if (header < 0) {
    header = 0;
    received = rows;
  }
  return ListPage(
    total: total,
    visible: visible,
    first: first,
    headerRows: header,
    received: received,
  );
}

/// The list lines (0-based, [ListPage.lineOfRow]) [m]'s paint shows
/// SELECTED — painted in SFE colour 3 throughout ([ListLine.highlighted]):
/// read from every repaint afresh, the selection is the server's
/// (a recorded session: list line 25 at window
/// row 31, 30 … 27 while the page's first line goes 0 .. 4, gone at first
/// 44 / 57, back at row 14 on Page Up to first 17). Empty without a page.
Set<int> listSelectedLines(ScreenModel m) {
  final page = listPageOf(m);
  if (page == null) return const {};
  return {
    for (final l in m.listPaint)
      if (l.highlighted && page.lineOfRow(l.line) != null)
        page.lineOfRow(l.line)!,
  };
}

/// The SES of a Windows list round: [eventarray] with [vkey] in eventid1
/// and [line] (a u16) in eventid3..4, the window's modal level and popup
/// position, the window pixel pair's low bytes (a popup's own,
/// [windowsModalSesDims]).
Uint8List windowsListSes(ActionContext ctx,
    {required int eventarray, int vkey = 0, int? line}) {
  final ses = Uint8List(16);
  ses[0] = eventarray;
  ses[1] = vkey & 0xff;
  if (line != null) {
    ses[3] = line >> 8 & 0xff;
    ses[4] = line & 0xff;
  }
  ses[7] = ctx.modalNo & 0xff;
  if (ctx.modalNo != 0) {
    ses[8] = ctx.modalX & 0xff;
    ses[9] = ctx.modalY & 0xff;
  }
  final popup = windowsListPopupSesDims(ctx);
  ses[14] = popup?.$1 ?? ctx.winPxHeight & 0xff;
  ses[15] = popup?.$2 ?? ctx.winPxWidth & 0xff;
  return ses;
}

/// The SES dims of a round sent from a POPUP list: the popup's pixel pair
/// low bytes from its own 16/12/7 AREASIZE ([ActionContext.areaRows] x
/// [ActionContext.areaCols], the last 16/12/7 the paint declared) — a list
/// popup paints no 16/12/6 for [windowsModalSesDims] to read
/// (a recorded session srv[84]: 20 x 80 -> 20 x 22 + 7, 80 x 7 = `bf 30`,
/// gui[70..74]); a dynpro popup's as [windowsModalSesDims]; null on the
/// main window.
(int, int)? windowsListPopupSesDims(ActionContext ctx) {
  if (ctx.modalNo == 0) return null;
  if (ctx.paintedTopWindowGeometry != null) return windowsModalSesDims(ctx);
  final cell = ctx.kernelCell;
  return (
    (ctx.areaRows * cell.height + 7) & 0xff,
    (ctx.areaCols * cell.width) & 0xff,
  );
}

/// The list cursor `01 0001 0001` (line 1, column 1): what every repaint
/// of a recorded session sets (the cursor never moved).
final Uint8List listCursorHome = Uint8List.fromList([1, 0, 1, 0, 1]);

/// The real SAP GUI for Windows' round on a classic list, from the SES
/// [ses] on: STEP, SES, the [windowRect] 16/4/36, the codepage, an
/// [okcode]'s 16/12/4, the identity atoms, then by window — a MAIN window:
/// its list cursor ([ActionContext.paintedListCursor] — the last paint's
/// 16/12/13, or where a click put it since: [SapSession.setListCursor]):
/// * with one, the OK event CHL `00 0d` over zeros, the 16/12/8
/// [windowPx] and the 16/12/13 `01 <row u16> <col u16>`
/// (a recorded session g11 / g13..g21 / g25 /
/// g27..g33);
/// * without one — the server scrolled the cursor's line out of the
/// window, its paint dropped the 16/12/13 and declared CHL `0b` — CHL
/// `00 0b`, the 16/12/8 still, and the empty 16/9/10 in place of the
/// cursor (rowsel_scroll g23, the bar dragged after Page Down moved the
/// cursor's line off screen: no 16/12/13);
/// a POPUP: `00 0b` over zeros and the empty 16/9/10, no 16/12/8 — then,
/// on the first round after a main-window list opened in a deeper internal
/// mode ([ActionContext.listMetricsOwed]), the METRICS item 17
/// (a recorded session gui[12] / gui[15]), then EOM.
List<Uint8List> _windowsListRound(ActionContext ctx, Uint8List ses,
    {required Uint8List windowPx, bool windowRect = false, String? okcode}) {
  final modal = ctx.modalNo != 0;
  final cursor = ctx.paintedListCursor;
  final metrics = !modal && ctx.listMetricsOwed;
  // the first round after the paint only: cleared once it is SENT
  if (metrics) ctx.listMetricsSending = true;
  return [
    stepItem(ctx.step),
    Uint8List.fromList([itemSes, ...ses]),
    if (windowRect) buildApplItem(4, 36, windowsWindowRect(ctx)),
    buildApplItem(6, 35, winCodepageValue),
    if (okcode != null) buildApplItem(12, 4, wireText(okcode)),
    for (final (sid, value) in winIdentity) buildApplItem(4, sid, value),
    if (modal) ...[
      Uint8List.fromList([itemChl, 0x00, 0x0b, ...Uint8List(20)]),
      buildApplItem(9, 10, Uint8List(0)), // no focus
    ] else if (cursor != null) ...[
      Uint8List.fromList([itemChl, 0x00, 0x0d, ...Uint8List(20)]),
      buildApplItem(12, 8, windowPx),
      buildApplItem(12, 13, cursor),
    ] else ...[
      Uint8List.fromList([itemChl, 0x00, 0x0b, ...Uint8List(20)]),
      buildApplItem(12, 8, windowPx),
      buildApplItem(9, 10, Uint8List(0)), // no cursor on the window
    ],
    if (metrics) xmlBlobItem(liveMetricsXml(ctx.screenRows, ctx.screenCols)),
    eomBytes,
  ];
}

/// The VSCROLL round: scroll the list of the window [ctx] mirrors so its
/// page starts at [firstLine] (0-based) — the SES carries it 1-based.
List<Uint8List> windowsListScrollItems(ActionContext ctx, int firstLine,
        {required Uint8List windowPx, bool windowRect = false}) =>
    _windowsListRound(
      ctx,
      windowsListSes(ctx,
          eventarray: winSesVScroll,
          line: math.min(listScrollMaxLine, math.max(0, firstLine) + 1)),
      windowPx: windowPx,
      windowRect: windowRect,
    );

/// A function key [vkey] on the list of the window [ctx] mirrors — a
/// paging key ([listScrollVkeys]), select line F9, block select F6, the
/// pick F2, Back F3, Cancel F12, any key of the list's PF-status: SES
/// `50 <vkey>` in the list envelope ([_windowsListRound]), no okcode, no
/// 16/15/1, no 16/9/11, no selection item (a recorded session
/// _list_rowsel_scroll g9 `50 02` — a double-click, g11 / g25 `50 09`, g21
/// / g27 `50 52` / `50 51`, g29 / g31 `50 06` twice; a recorded session
/// gui[71] `50 03` and gui[22] `50 0c` on a main-window list, gui[20]
/// `50 0c` on a popup one). The line a key acts on is the one the cursor's
/// row names: the server answers with the list repainted, a selected line's
/// runs in SFE colour 3 ([ListLine.highlighted]).
List<Uint8List> windowsListKeyItems(ActionContext ctx, int vkey,
        {required Uint8List windowPx, bool windowRect = false}) =>
    _windowsListRound(
      ctx,
      windowsListSes(ctx, eventarray: winSesEventarray[1]!, vkey: vkey),
      windowPx: windowPx,
      windowRect: windowRect,
    );

/// A typed function code [okcode] (`/nex`, `=BACK`) on the list of the
/// window [ctx] mirrors: SES eventarray 0 (no key), the 16/12/4 after the
/// codepage, the list envelope ([_windowsListRound]) —
/// a recorded session g33 `/nex`: CHL 0d,
/// 16/12/8, the list cursor.
List<Uint8List> windowsListOkcodeItems(ActionContext ctx, String okcode,
        {required Uint8List windowPx, bool windowRect = false}) =>
    _windowsListRound(
      ctx,
      windowsListSes(ctx, eventarray: 0),
      windowPx: windowPx,
      windowRect: windowRect,
      okcode: okcode,
    );

/// The window resized over a classic list: the RESIZE round (SES 0x52, the
/// new window's pixel low bytes in the SES dims, its pixels in 16/12/8
/// [windowPx]) in the main-window list envelope — mainwindow_list_scroll
/// g60 (the first resize, [windowRect] the 16/4/36) / g61 / g62. The server
/// lays the page out for the new window at the same first line.
List<Uint8List> windowsListResizeItems(ActionContext ctx,
        {required Uint8List windowPx, bool windowRect = false}) =>
    _windowsListRound(
      ctx,
      windowsListSes(ctx, eventarray: 0x52),
      windowPx: windowPx,
      windowRect: windowRect,
    );
