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
/// 1e763853b826: `SAPMSSY0/0120` "File d'attente d'import : système the test system",
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
/// bytes 3..4), no vkey; the round's OK event the cursorless list CHL
/// `00 0b` over zeros, the empty 16/9/10, no okcode, no 16/15/1, no item
/// 17 (a recorded session gui[70..74], real Windows GUI, SAPMSSY0/0120
/// popup list of 40 lines / 27 visible: `56 00 00 00 02` … `05`, `0e` —
/// answered by 16/12/2 first 1, 2, 3, 4, 13; a recorded session
/// gui[42] / [43] `… 02`, `… 01`). The Java GUI's own VSCROLL rounds
/// carry the target the same way (a recorded session g[16] / g[18]
/// `04 00 00 00 a9` → first 168, `… 01` → 0; a recorded session
/// _java gui[80] `04 00 00 07 d3` — the high byte in eventid3);
/// * Page Up / Page Down / Ctrl+Page Up / Ctrl+Page Down: the function
/// key round (SES 0x50, eventid1 = vkey 81 / 82 / 80 / 83) in the same
/// cursorless list envelope (a recorded session gui[27]:
/// `50 52`, CHL `00 0b`, 16/9/10) — the server moves the page itself.
///
/// The envelope by window (the corpus' cursorless Windows list rounds):
/// a MAIN-window list round carries the window's 16/12/8 after the CHL
/// (a recorded session gui[8], a recorded session gui[25]);
/// a POPUP list round none, and the popup's 16/4/36 window rect right after
/// the SES on the first round of a run — a scroll repeated on the same list
/// carries none (bwadapterjoin gui[70] with it, gui[71..74] without;
/// f4_modes_ctrl gui[42] / gui[43]).
///
/// No real Windows GUI capture scrolls a MAIN-window list (every sample
/// above is a popup list): the main-window shape is composed from the
/// main-window list key rounds, the 16/12/8 the only difference. A target
/// past 65 535 has no recorded spelling (eventid2 is never set): it is
/// clamped to 65 535.
library;

import 'dart:math' as math;
import 'dart:typed_data';

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
/// row too: SAPMSSY0's rows 0 and 2 above the the test system queue's box).
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

/// The real SAP GUI for Windows' cursorless round on a classic list, from
/// the SES [ses] on: STEP, SES, (a popup's [windowRect] 16/4/36), the
/// codepage, the identity atoms, the list OK event `00 0b` over zeros, a
/// main window's 16/12/8 [windowPx], the empty 16/9/10, EOM.
List<Uint8List> _windowsListRound(ActionContext ctx, Uint8List ses,
    {required Uint8List windowPx, bool windowRect = false}) {
  final modal = ctx.modalNo != 0;
  return [
    stepItem(ctx.step),
    Uint8List.fromList([itemSes, ...ses]),
    if (modal && windowRect) buildApplItem(4, 36, winIdentity36),
    buildApplItem(6, 35, winCodepageValue),
    for (final (sid, value) in winIdentity) buildApplItem(4, sid, value),
    Uint8List.fromList([itemChl, 0x00, 0x0b, ...Uint8List(20)]),
    if (!modal) buildApplItem(12, 8, windowPx),
    buildApplItem(9, 10, Uint8List(0)), // no focus
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

/// A paging key ([listScrollVkeys]) on the list of the window [ctx]
/// mirrors: the function-key round in the cursorless list envelope.
List<Uint8List> windowsListKeyItems(ActionContext ctx, int vkey,
        {required Uint8List windowPx, bool windowRect = false}) =>
    _windowsListRound(
      ctx,
      windowsListSes(ctx, eventarray: winSesEventarray[1]!, vkey: vkey),
      windowPx: windowPx,
      windowRect: windowRect,
    );
