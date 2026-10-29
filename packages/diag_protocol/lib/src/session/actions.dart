/// Dynpro action envelopes — press / okcode / field writes in the Windows
/// dialect, assembled exactly like the engine's `_build_submit_full_items`
/// and grounded against a recorded session gui[0] (a real okcode frame).
library;

import 'dart:typed_data';

import '../cfw/datamanager_grammar.dart';
import '../codepages.dart';
import '../framing/envelope.dart';
import '../items/dynt_atom.dart';
import '../screen/screen_model.dart';
import 'frames.dart';
import 'table_cell.dart' show tcWindowsHeaderEcho;
import 'xml17_blob.dart';

/// One table-control group of a paint's SAP GUI for Windows container
/// echo ([ActionContext.paintedTableEcho]): the control's container [path]
/// and its echo [items].
typedef WindowsTableEcho = ({
  List<int> path,
  List<Uint8List> items,
  // the painted 18/9/14 the group's 16/9/14 echoes: a round rebuilds that
  // item from it under the user's column layout ([ActionContext.tcLayouts])
  Uint8List? header,
});

/// The column layout the USER gave a classic table control — its column
/// widths in characters (by column id: catalog order) and / or its display
/// order (the column ids 1..n by position). The SAP GUI for WINDOWS reports
/// it in the 16/9/14 echo of the next round, the server mirrors it in its
/// next 18/9/14 (a recorded session, table_cell.dart tcWindowsHeaderEcho).
class TcColumnLayout {
  const TcColumnLayout({this.widths, this.order});
  final List<int>? widths;
  final List<int>? order;
}


/// The recording Windows GUI's own client window (px): the 16/12/8 of
/// every real event round (table_cell.dart winEventWindowPx, the reference client's
/// frontend_profile._WIN_WINDOW_PX) — 38 x 268 cells of 22 x 7 plus 17 / 4
/// px of slack.
const int winEventWindowHeight = 853, winEventWindowWidth = 1880;

/// The live session context an action needs — mirrored from the latest
/// server paint (geometry) plus the tracked step/modal state.
class ActionContext {
  ActionContext({
    this.step = 0,
    this.areaRows = 26,
    this.areaCols = 146,
    this.scrV = 0,
    this.scrH = 0,
    this.modalNo = 0,
    this.winPxHeight = 0x307,
    this.winPxWidth = 0x550,
    this.os = 'Android',
    this.screenRows = 40,
    this.screenCols = 146,
    this.paintedFocus,
    Uint8List? echoedAreaSize,
  }) : echoedAreaSize = echoedAreaSize ?? _u16s([areaRows, 8, areaRows - 8, 8]);

  int step;

  /// The active dynpro's area rectangle — the server's AREASIZE (16/12/7:
  /// rows = int0, cols = int1; 45x272 on the test system's Windows profile, a popup's
  /// own rectangle while one is up), mirrored by [mirrorPaintGeometry].
  int areaRows;
  int areaCols;

  /// The server CHL's (16/5/1) bytes 10/11 — the pair the OK event echoes
  /// at b13/b16 and SCROLL_INFOS2 leads with on a field round.
  int scrV;
  int scrH;
  int modalNo;

  /// The popup nesting the last window-declaring paint shows: its 16/12/7
  /// window items beyond the main window's (0 on a main window, 2 for a
  /// value-help host popup over another popup — su53 gui[22], a recorded session
  /// nav_picks gui[48]), mirrored by [mirrorPaintGeometry]. A Windows round
  /// takes the larger of it and [modalNo] (reference client windows_control_event_
  /// round.modal_level).
  int paintedModalLevel = 0;

  /// The active popup's screen position (the server SES x_pos / y_pos —
  /// `04 01` for the SAPLALDB/3000 popup over SE16), echoed by a round that
  /// addresses the popup's table control (a recorded session
  /// gui[7] `… 01 31 07 …`, the reference client's _ses modal_pos). 0/0 on the main
  /// window.
  int modalX = 0;
  int modalY = 0;

  /// The client window's pixel size (16/12/8; the SES dims' low bytes on a
  /// Windows round): the engine's _OK_128 pair, 0x307 x 0x550.
  int winPxHeight;
  int winPxWidth;
  String os;

  /// The three ST_USER atoms the SAP GUI for WINDOWS adds to the FIRST
  /// round it sends in a window ([windowsFirstRoundItems]): 16/4/4
  /// FONTMETRIC (cell height, cell width, character height, character
  /// width — `0016 0007 0010 0007`, the 22 x 7 cell its DATAMANAGER
  /// METRICS report as Y2 / X2), 16/4/36 DISPLAY_SIZE and 16/4/40
  /// MAINAREA_SIZE (height, width px — `0419 0f01` = 1049 x 3841, the
  /// two-monitor desktop, and `03d8 0780` = 984 x 1920, the monitor's work
  /// area). Desktop facts of the recording PC, not of the window: the same
  /// bytes in every Windows capture whatever the 16/12/8 window (853 x 1880
  /// on a recorded session raw gui[8] / gui[29], 868 x 1882 on
  /// a recorded session gui[3]) — no paint carries them, so
  /// the real GUI's values are the defaults; an app that knows its display
  /// sets its own. (The names are the ST_USER sids of the Java GUI's
  /// libJPlatin64 and pysap; FONTMETRIC = sid 4, DISPLAY_SIZE = 0x24, the
  /// support bit MAINAREA_SIZE the 0x28 atom.)
  ({int cellHeight, int cellWidth, int charHeight, int charWidth})
      winFontMetric = (cellHeight: 22, cellWidth: 7, charHeight: 16, charWidth: 7);
  (int, int) winDisplayPx = (0x419, 0xf01);
  (int, int) winMainAreaPx = (0x3d8, 0x780);

  /// The 16/4/36 window rect (height, width px) a popup's key round and an
  /// owed modal control event carry (frontend_profile windowsWindowRect):
  /// the reference GUI's `0409 0781` ([recordedWindowRectPx]) unless the
  /// app reports its display ([reportDisplay]).
  (int, int) winWindowRectPx = recordedWindowRectPx;
  static const (int, int) recordedWindowRectPx = (0x409, 0x781);

  /// The device's display is [px] (height, width — EmulatedGuiProfile
  /// .displayPx): the DISPLAY_SIZE, MAINAREA_SIZE and window rect every
  /// round reports are its own instead of the reference GUI's desktop.
  void reportDisplay((int, int) px) {
    winDisplayPx = px;
    winMainAreaPx = px;
    winWindowRectPx = px;
  }

  /// The negotiated character screen (the logon's screen-size patch): the
  /// Windows okcode / key rounds spell SCROLL_INFOS2 with it.
  int screenRows;
  int screenCols;

  /// The client SET its window size ([sizeWindow]; SapSession.resizeWindow):
  /// the window pixels every round reports ([winPxHeight] / [winPxWidth],
  /// the event rounds' [windowsEventWindowPx] too) are derived from
  /// [screenRows] x [screenCols] instead of the reference captures'
  /// constants (775 x 1360 on the okcode / key rounds, 853 x 1880 on the
  /// event / cell rounds — two windows the kernel lays out as 36 x 194 and
  /// 40 x 268, whichever round came last). False = those constants (every
  /// pinned frame).
  bool windowSized = false;

  /// The character cell (height, width px) the KERNEL divides this window's
  /// 16/12/8 pixels by to lay the dynpro out (its 16/12/7 AREASIZE =
  /// floor(px / cell)): the cell the window's 16/4/4 FONTMETRIC declared
  /// ([winFontMetric], the reference client's frontend_profile.cell_px) — 22 x 7, and
  /// EVERY Windows window of GuiGo declares it: the logon window in the
  /// logon submit (logon_frames.dart logonItems, as the real GUI's —
  /// a recorded session gui[1]), a later window in its first
  /// round ([windowsFirstRoundItems]). Grounded on windows that declared
  /// 22 x 7: the reference client's live probe (a recorded session, its logon
  /// submit carrying the 16/4/4; one consistent 853 x 1880 window on every
  /// round, SES dims `55 58`) got 16/12/7 38 x 268 = floor(853 / 22) x
  /// floor(1880 / 7) on SAPLWBABAP and SAPLS38E; the real GUI's
  /// a recorded session 659 x 1568 -> 29 x 224 and
  /// a recorded session 868 x 1882 -> 39 x 268. (GuiGo's
  /// former 21-px cell was inferred from the reference client's MIXED windows — 853 x
  /// 1880 on event rounds, 775 x 1360 on okcode rounds — while GuiGo's
  /// logon declared no FONTMETRIC; what a window that never sends one gets
  /// is not recorded.) Before any window report the kernel assumes
  /// 45 x 272; after the logon's Easy Access paint 42 x 272 (the probe's
  /// SAPMSYST / SAPLSMTR_NAVIGATION paints).
  ({int height, int width}) get kernelCell =>
      (height: winFontMetric.cellHeight, width: winFontMetric.cellWidth);

  /// The sub-cell slack of the reference window (height, width px): the
  /// recording GUI's 853 x 1880 = 38 x 22 + 17, 268 x 7 + 4 — what
  /// [sizeWindow] adds to whole cells, as the reference client's
  /// frontend_profile.window_px_for_cells does (default_window_px mod cell).
  ({int height, int width}) get windowSlack => (
    height: winEventWindowHeight % kernelCell.height,
    width: winEventWindowWidth % kernelCell.width,
  );

  /// The cells (rows, cols) the DOCKED panes take from the main window: the
  /// last main-window paint's 16/12/7 window pair less its area pair, while
  /// a docking container is shown (the session sets it,
  /// sap_session_layout.dart); (0, 0) without docks. The Windows GUI
  /// reports its realized dynpro AREA in the second 16/12/8 pair of every
  /// main-window round — the window less the docked panes, whose pixel
  /// extents stay put when the window changes (a recorded session
  /// history: 597 x 1161 / 498 x 839 on every round of the load history
  /// screen, the resize round g[28] 762 x 1510 / 663 x 1188 — the same 99 /
  /// 322 px for the bottom message dock and the left navigation dock — and
  /// the server lays the dynpro out from that area, srv[48] 16/12/7 34 x
  /// 215 / 30 x 169; the reference client's docked_layout.area_px_geometry). Without
  /// docks the pair is the window twice (every undocked capture).
  (int, int) dockedCells = (0, 0);

  /// The 16/12/8 value for a window of [h] x [w] px: the window, then the
  /// dynpro area — the window less [dockedCells] in [kernelCell]s (the
  /// window twice without docks, and always in a popup's 16/12/14).
  Uint8List windowAreaPx(int h, int w) {
    var ah = h, aw = w;
    if (modalNo == 0) {
      final (dr, dc) = dockedCells;
      final dh = dr * kernelCell.height, dw = dc * kernelCell.width;
      if (dr > 0 && dh < h) ah = h - dh;
      if (dc > 0 && dw < w) aw = w - dw;
    }
    final out = Uint8List(16);
    out.buffer.asByteData()
      ..setUint32(0, h)
      ..setUint32(4, w)
      ..setUint32(8, ah)
      ..setUint32(12, aw);
    return out;
  }

  /// The top window's last paint lays out a STEP LOOP or table control
  /// (16/10/4 CONTAINER_LOOP / 16/10/5): its line count follows the window
  /// the client reports (a recorded session: the loop's 16/10/4
  /// height = the window rows - 14), so a resize is its own round there.
  bool paintedLoop = false;

  /// Set the client window to [rows] x [cols] character cells: the
  /// negotiated screen ([screenRows] / [screenCols]: METRICS, SCROLL_INFOS2)
  /// and the window pixels the kernel lays out from — [kernelCell] times
  /// the cells plus the reference window's slack ([windowSlack]: px =
  /// rows x 22 + 17, cols x 7 + 4, the reference client's window_px_for_cells), so the
  /// kernel's floor division lands on [rows] x [cols] and 38 x 268 is the
  /// recorded 853 x 1880 window itself.
  void sizeWindow(int rows, int cols) {
    screenRows = rows;
    screenCols = cols;
    winPxHeight = rows * kernelCell.height + windowSlack.height;
    winPxWidth = cols * kernelCell.width + windowSlack.width;
    windowSized = true;
  }

  /// The screen's current DYNPRO cursor — its 16/9/11 value verbatim
  /// (`01 rrrr cccc 00000000 pp`): the last paint that DECLARED a focus set
  /// it, or the client placed it since (F1 on a field, [SapSession
  /// .fieldHelp]). Only a paint declaring a focus moves it (reference client 867e1d7
  /// §4, client_focus.observe_frame): a painted 16/9/11 replaces it, a
  /// 16/9/10 or a painted CONTROL focus (a non-dialog 16/9/18) clears it, a
  /// focus-less repaint keeps it ([mirrorPaintGeometry]). A Windows key
  /// round echoes it (the engine's _current_cursor).
  Uint8List? paintedFocus;

  /// The last paint that declared a focus declared NONE — its empty
  /// 16/9/10 (a recorded session srv[1581]); false after a 16/9/11
  /// / control 16/9/18 or a cursor the client placed. A Windows key round
  /// then names no cursor ([windowsActionItems]: su53 gui[1297]), where a
  /// screen nothing is known of keeps the zero cursor.
  bool paintedNoFocus = false;

  /// The window level ([paintedFocus], [paintedControlFocus] and
  /// [paintedNoFocus] belong to (0 = the main window): the modal level of
  /// the last window-declaring paint ([mirrorPaintGeometry]).
  int focusLevel = 0;

  /// The screen the focus state belongs to (the session's (program,
  /// dynpro, modal level) identity), null when unknown.
  Object? focusScreen;

  /// The focus of every window UNDER the active popup, by level: a popup is
  /// its own window and the one beneath keeps its focus — parked when the
  /// popup paints over it, restored when that window repaints after the
  /// popup stack closed (reference client client_focus._set / _restore_under,
  /// 0f19cd8; a recorded session gui[23] sends gui[10]'s
  /// cursor across the value-help popups srv[13..27]).
  final Map<int, ({Uint8List? focus, String? control, bool noFocus, Object? screen})>
      parkedFocus = {};

  /// The CFW control the server's last paint put the focus on (its
  /// trailing 16/9/18 `<shell>` — the grid after a value help closed,
  /// a recorded session srv[43]), null when it focused a dynpro field (a
  /// 16/9/11, srv[13]) or nothing (16/9/10). A Windows control-event round
  /// spells its OK-event mode from it (grid_edit_actions.dart).
  String? paintedControlFocus;

  /// The active window's MAIN 16/12/6 as the last paint declared it (the
  /// first 16/12/6 of the top window: a popup's own after its 16/12/7) —
  /// a Windows field write echoes it verbatim (reference client
  /// nested_state_round.painted_main_geometry; a recorded session
  /// sameplane_wingui g15 = srv #18's `16 x 48 … 16 x 4a`). Null before a
  /// paint declared one.
  Uint8List? paintedGeometry;

  /// The TOP window's own 16/12/6 as the last window-declaring paint
  /// declared it: the FIRST 16/12/6 after the paint's LAST 16/12/7 window
  /// item, whatever follows it (reference client windows_key_round.top_window_geometry,
  /// ff1e540) — a Windows key round in a MODAL echoes it: a recorded session
  /// gui[22] `0016 0047` on srv[34], not the GS_SYSTEMATTRIBUTES page
  /// subscreen's `000e 003b` painted after it; 233 of the reference client corpus' 236
  /// modal key rounds (the paint's last 16/12/6: 176). Null when that paint
  /// declares none after its window item ([mirrorPaintGeometry]); the key
  /// round then echoes [paintedGeometry].
  Uint8List? paintedTopWindowGeometry;

  /// The TABLE-CONTROL groups of the SAP GUI for WINDOWS container echo of
  /// the active window's paint (frontend_profile.dart [windowsPaintEcho]):
  /// per table control its container [WindowsTableEcho.path] (the level
  /// byte of every routing leg under the root, 16/10/9 page legs included)
  /// and its echo items `[16/10/1 zeros, legs, 16/10/5, 16/9/14 60-byte,
  /// 16/12/2]`. The Windows GUI echoes a group only while the dynpro
  /// cursor it sends lies INSIDE that table control
  /// ([windowsCursorInTable]; a recorded session gui[124] yes,
  /// a recorded session gui[23] no — the same TC_1211).
  List<WindowsTableEcho> paintedTableEcho = const [];

  /// The column layouts the USER gave this window's classic table controls
  /// ([TcColumnLayout] by [tcHeaderKey]): every Windows round's 16/9/14
  /// echo carries one in the full header form while the server's latest
  /// 18/9/14 differs from it ([tcWindowsHeaderEcho]); an entry the server
  /// has mirrored is dropped (SapSession.noteTableColumnLayout).
  final Map<String, TcColumnLayout> tcLayouts = {};

  /// Every echo-eligible group of the paint, ungated: [paintedTableEcho]'s
  /// items, then [paintedTabstripEcho].
  List<Uint8List> get paintedEcho => [
        for (final t in paintedTableEcho) ...tableEchoItems(t),
        ...paintedTabstripEcho,
      ];

  /// [t]'s echo items as THIS round sends them: its 16/9/14 the full
  /// header while the user's column layout ([tcLayouts]) differs from the
  /// painted one, else the short form it was built with.
  List<Uint8List> tableEchoItems(WindowsTableEcho t) {
    final h = t.header;
    if (h == null || tcLayouts.isEmpty) return t.items;
    final echo = tcWindowsHeaderEcho(h, tcLayouts);
    if (echo == null) return t.items;
    return [
      for (final it in t.items)
        if (it.length >= 3 && it[0] == itemAppl && it[1] == 9 && it[2] == 14)
          buildApplItem(9, 14, echo)
        else
          it,
    ];
  }

  /// The TABSTRIP-STATE groups of the paint's Windows container echo —
  /// `[16/10/1 zeros, legs, 16/10/8, 16/9/15 short]` per tabstrip: echoed
  /// whatever the cursor (a Windows pushbutton round after the cursor's
  /// table control, a control event / typed okcode with a control focus /
  /// main-plane write on its own: reference client windows_control_event_round
  /// .tabstrip_echo_tuples; a recorded session gui[75] / gui[82]).
  List<Uint8List> paintedTabstripEcho = const [];

  /// The TOP window of the last window-declaring paint declares a NAMED
  /// container group (a 16/10/6 name leg: a subscreen, custom-control or
  /// tabstrip area), mirrored by [mirrorPaintGeometry]. A Windows control
  /// event with a FLAT dynpro cursor on such a screen goes out with OK
  /// mode 0x0d, not 0x05 ([windowsWindowStateOkMode]; reference client
  /// windows_control_event_round.paint_declares_named_container, 534a50c).
  bool paintedNamedContainer = false;

  /// The TOP window of the last window-declaring paint is an ABAP LIST: its
  /// OK event rides the type-9 CHL item instead of a 16/5/1 (the list
  /// paints of a recorded session srv[35], a recorded session srv[26],
  /// a recorded session srv[17]), mirrored by
  /// [mirrorPaintGeometry]. A Windows menu round on it is the list round
  /// (menu_actions.dart windowsMenuSelectItems).
  bool paintedList = false;

  /// The list cursor that paint declared (its 16/12/13 `01 <line u16>
  /// <col u16>`, se51 srv[35] `01 0002 0001`); null when none — the server
  /// drops it once the cursor's line left the window, and the next
  /// main-window list round then goes out cursorless (CHL 0b, 16/9/10:
  /// a recorded session g23). A click on a list
  /// line moves it locally, no frame ([SapSessionListCursor.setListCursor]);
  /// the next paint sets it again.
  Uint8List? paintedListCursor;

  /// The SES imode byte (10: the internal mode the screen runs in) of the
  /// last window-declaring paint, mirrored by [mirrorPaintGeometry].
  int paintedImode = 0;

  /// That paint is a MAIN-window list opened in a deeper internal mode
  /// than the paint before it (its SES imode byte higher): the first list
  /// round after it carries the client's METRICS item 17 (list_scroll.dart
  /// [windowsListKeyItems]) — a recorded session gui[12]
  /// (F3) / gui[15] (`/nex`) after the SE38 F8 lists srv[15] / srv[19]
  /// (imode 1 -> 2), a recorded session gui[8] (1 -> 2),
  /// a recorded session gui[10] (1 -> 3),
  /// a recorded session / a recorded session
  /// gui[8] / gui[4] (0 -> 1) — whatever the round before carried and the
  /// step gap; none when the list stays in its mode (every STMS list:
  /// a recorded session g9, a recorded session
  /// gui[38], a recorded session gui[8] / gui[10],
  /// a recorded session gui[10]; the list -> list repaints) or goes
  /// back to a shallower one (gral_graphics srv[35], 2 -> 1), nor on a
  /// popup list (40+ modal SAPMSSY0/0120 paints). Cleared by the round
  /// that sends it and by the next window paint.
  bool listMetricsOwed = false;

  /// A list round carrying the owed METRICS was BUILT: [listMetricsOwed]
  /// clears once that round is on the wire (SapSession._sendWire), not at
  /// build time — a round built and never sent leaves it owed.
  bool listMetricsSending = false;

  /// The ACKNOWLEDGED paint's own OK-event mode: byte 1 of the last server
  /// 16/5/1 this window received (`01` plain, `09` with CFW controls — the
  /// 0x08 bit; a popup's own when one is up: a frame painting a popup over
  /// its parent carries the parent's part first, so the last 16/5/1 is the
  /// TOP window's), mirrored by [mirrorPaintGeometry]. Every client round's
  /// own 16/5/1 mode derives from it ([windowsOkMode] / [javaOkMode]: the
  /// paint's mode | the round's focus half — reference client,
  /// complaint-java-okmode-depth1-confirmed+20261012-120300 /
  /// complaint-popup-control-focus-okmode+20261012-125640). Null before a
  /// paint declared one and on an ABAP LIST window (its OK event rides the
  /// type-9 CHL item, no 16/5/1): the builders' constants then decide.
  int? paintOkMode;

  /// The ACKNOWLEDGED paint's own LAST focus item is a dynpro cursor
  /// (16/9/11) — read over the whole frame that carried [paintOkMode], its
  /// 16/9/11 and 16/9/18 items only (the empty 16/9/10 does not count),
  /// mirrored by [mirrorPaintGeometry] together with [paintOkMode] (reference client
  /// engine/ok_mode.paint_focus, 5025506). A Windows round naming a CFW
  /// control (16/9/18) on such a paint takes the CURSOR half
  /// ([windowsControlOkMode]); false while the paint ends in a 16/9/18 or
  /// declares no focus.
  bool paintCursorFocus = false;

  /// The server paint's own 16/4/4 area-size bytes, echoed verbatim.
  Uint8List echoedAreaSize;

  /// 16/4/4 area size item value (echoed from the server paint).
  Uint8List get areaSizeItem => echoedAreaSize;
}

/// The 16/9/11 a round SENDS is the screen's cursor from then on
/// (reference client raw_transport send_msg -> client_focus.note, 81ed12f): a key
/// aimed at a field (F4, SapSession.valueHelp), a staged field
/// round, a cell write — the next round echoes it until a paint moves it
/// (a recorded session gui[10] F4 at SUPERFIELD col 0x31
/// -> gui[23] `=MEV4000BUTTON` sends that cursor, not the painted col 0).
/// A zero cell (`01 0000 0000 …`) places nothing.
void noteClientFocus(ActionContext ctx, List<Uint8List> items) {
  for (final raw in items) {
    final w = walkItems(raw).items;
    if (w.length != 1) continue;
    final it = w.single;
    if (!it.isAppl || it.id != 9 || it.sid != 11 || it.value.length < 10) {
      continue;
    }
    if (it.value.sublist(1, 5).every((b) => b == 0)) return;
    ctx
      ..paintedFocus = Uint8List.fromList(it.value)
      ..paintedControlFocus = null
      ..paintedNoFocus = false;
    return;
  }
}

Uint8List _u16s(List<int> vals) {
  final out = Uint8List(vals.length * 2);
  final bd = out.buffer.asByteData();
  for (var i = 0; i < vals.length; i++) {
    bd.setUint16(i * 2, vals[i] & 0xffff);
  }
  return out;
}

/// SES value: eventarray 0x50 (Windows FKEY spelling) with the vkey, or 0x41
/// for menu; dims = the window pixel pair's low bytes (Windows dialect).
Uint8List _ses(int eventarray, {int eventid1 = 0, int dimRow = 0, int dimCol = 0, int modalNo = 0}) {
  final v = Uint8List(16);
  v[0] = eventarray;
  v[1] = eventid1;
  v[5] = 0;
  v[7] = modalNo; // modal_no
  v[14] = dimRow;
  v[15] = dimCol;
  return v;
}

/// 16/5/1 OK-event, 22 bytes: b1 mode (0x05 field-submit / 0x0d element-click
/// / 0x0b plain Enter), b4/b5 cursor row/col, b6-11 dynpro-area rectangle
/// (b7 = the constant modification flag 0x29), b13/b16 scroll.
Uint8List _okEvent(ActionContext ctx,
    {int mode = 0x0b, int cursorRow = 0, int cursorCol = 0}) {
  final ok = Uint8List(22);
  ok[1] = mode;
  ok[4] = cursorRow & 0xff;
  ok[5] = cursorCol & 0xff;
  ok[6] = ctx.areaRows & 0xff;
  ok[7] = 0x29;
  ok[8] = ctx.areaCols & 0xff;
  ok[9] = ctx.areaCols & 0xff;
  ok[10] = ctx.areaRows & 0xff;
  ok[11] = ctx.areaCols & 0xff;
  ok[13] = ctx.scrV & 0xff;
  ok[16] = ctx.scrH & 0xff;
  return ok;
}

/// 16/12/6 SCROLL_INFOS2: scroll pair, area rectangle twice, trailing 0x01.
Uint8List _scrollInfos2(ActionContext ctx) {
  final out = Uint8List(33);
  final bd = out.buffer.asByteData();
  bd.setUint32(0, ctx.scrV & 0xff);
  bd.setUint32(4, ctx.scrH & 0xff);
  bd.setUint32(8, ctx.areaRows & 0xff);
  bd.setUint32(12, ctx.areaCols & 0xff);
  bd.setUint32(16, 0);
  bd.setUint32(20, 0);
  bd.setUint32(24, ctx.areaRows & 0xff);
  bd.setUint32(28, ctx.areaCols & 0xff);
  out[32] = 1;
  return out;
}

/// 16/12/8 (main window: the window, then the dynpro area —
/// [ActionContext.windowAreaPx]) / 16/12/14 (while modal) pixel geometry.
Uint8List _winPx(ActionContext ctx) =>
    ctx.windowAreaPx(ctx.winPxHeight, ctx.winPxWidth);

List<Uint8List> _commonTail(ActionContext ctx) {
  return [
    buildApplItem(4, 43, wireText(ctx.os)), // identity: OS
    buildApplItem(4, 44, wireText('MF')), // identity: GUI type
    buildApplItem(4, 25, Uint8List(2)),
    buildApplItem(4, 4, ctx.areaSizeItem),
  ];
}

/// The SES item bytes: `<type 0x01><16-byte SES value>`. Dims carry the char
/// rows/cols — the spelling the reference client's verified frames use (the pixel-dims
/// variant seen in real-Windows-GUI resize captures is a live A/B question).
Uint8List _sesItem(ActionContext ctx, {int vkey = 0, bool withKey = true}) {
  final v = _ses(
    withKey ? 0x50 : 0x00, // Windows FKEY spelling / no key event
    eventid1: vkey,
    dimRow: ctx.areaRows & 0xff,
    dimCol: ctx.areaCols & 0xff,
    modalNo: ctx.modalNo,
  );
  return Uint8List.fromList([itemSes, ...v]);
}

/// [xml17BlobHex] decoded ONCE (it was re-parsed from hex on every
/// keypress round); [xmlBlobItem] copies it into each item, so the shared
/// bytes are never handed out.
final Uint8List _xml17 = () {
  final out = Uint8List(xml17BlobHex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(xml17BlobHex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}();

/// The item bytes of a type-17 item (len u32 BE prefix).
Uint8List xml17Item() => xmlBlobItem(_xml17);

/// A type-17 (DATAMANAGER XML) item carrying [value]. The ONE builder of
/// every item 17 a round sends: in debug and tests it holds [value] to the
/// server's DATAMANAGER grammar (cfw/datamanager_grammar.dart) — a malformed
/// document dumps CNDP 008 at CL_GUI_DATAMANAGER, so a builder or a merge
/// that produces one fails here, not on a live system.
Uint8List xmlBlobItem(Uint8List value) {
  assert(debugCheckDatamanager(value));
  final out = Uint8List(5 + value.length);
  out[0] = itemXmlBlob;
  out.buffer.asByteData().setUint32(1, value.length);
  out.setRange(5, out.length, value);
  return out;
}

/// SapTree CFW event ids (sapTreeS.jar SapTreeEncEventAdaptor): the lazy
/// folder open the Easy Access menu registers, and the node activation.
const int treeEventExpandNoChildren = 18;
const int treeEventNodeDoubleClick = 25;

/// The other SapTree node events a tree may register instead: 19 EXPAND
/// (a folder open when 18 is not registered), 21 SELCHANGE (a click on a
/// node), 22 ITEMDBLCLICK (a column tree's item double-click — PARAM1 the
/// item name).
const int treeEventExpand = 19;
const int treeEventSelectionChange = 21;
const int treeEventItemDoubleClick = 22;

/// A column tree's item events (SapTreeEncEventAdaptor; PARAM0 the node
/// key, PARAM1 the item name): a link item's click, a button item's.
const int treeEventLinkClick = 35;
const int treeEventButtonClick = 29;

/// The Java GUI's EXPAND-only 16/4/36 + 16/4/40 + 16/4/42 client-window
/// rects (the engine's capture-frozen gui[11] triple: outer frame 985x1376,
/// the window rect, viewport 905x1360). A Windows round carries none.
final Uint8List _treeExpand436 = Uint8List.fromList(
    [0x00, 0x00, 0x03, 0xd9, 0x00, 0x00, 0x05, 0x60]);
final Uint8List _treeExpand442 = Uint8List.fromList(
    [0x00, 0x00, 0x03, 0x89, 0x00, 0x00, 0x05, 0x50]);

String _xmlEsc(String v) => v
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// The DATAMANAGER XML of a tree control event — the real GUI's shape
/// (a recorded session gui[13] `%_GC 120 18`, the engine's
/// _tree_click_xml): EVENTS/EVENT with the node key as PARAM 0 (the
/// server's own NODE_KEY string, echoed verbatim) and, on an expand with a
/// known scroll state, CONTROLS/TopNodeKey. The container's client-geometry
/// CONTROL block the real GUI adds is optional (the responder proves it
/// with VALUE='0').
Uint8List treeEventXml({
  required String shell,
  required int eventId,
  required String nodeKey,
  String? itemName,
  String? topNodeKey,
}) {
  final b = StringBuffer()
    ..write('<?xml version="1.0" encoding="sap*"?>\n<DATAMANAGER>')
    ..write('<EVENTS><EVENT SHELLID="$shell" EVENTID="$eventId">')
    ..write('<PARAM VALUE="${_xmlEsc(nodeKey)}" PID="0"/>');
  if (itemName != null) {
    b.write('<PARAM VALUE="${_xmlEsc(itemName)}" PID="1"/>');
  }
  b.write('</EVENT></EVENTS>');
  if (eventId == treeEventExpandNoChildren && topNodeKey != null) {
    b
      ..write('<CONTROLS><CONTROL SHELLID="$shell">')
      ..write('<PROPERTY VALUE="${_xmlEsc(topNodeKey)}" NAME="TopNodeKey"/>')
      ..write('</CONTROL></CONTROLS>');
  }
  b.write('</DATAMANAGER>');
  return Uint8List.fromList(b.toString().codeUnits);
}

/// The OK code that dispatches CFW control event [eventId] of [shell]:
/// `%_GC <shell> <event id>`.
String cfwGenericEventOkcode(String shell, int eventId) =>
    '%_GC $shell $eventId';

/// A tree control event round (the engine's RawDiag.tree_click, oracle
/// a recorded session gui[11]/[14]): the okcode is `%_GC <shell> <eventId>`,
/// the node rides the type-17 XML, and 16/9/18 names the shell. In the
/// Java spelling; [windowsActionItems] with `controlEvent: true` re-spells
/// it as the Windows GUI sends it (a recorded session gui[13]).
List<Uint8List> treeEventItems(
  ActionContext ctx, {
  required String shell,
  required int eventId,
  required String nodeKey,
  String? itemName,
  String? topNodeKey,
}) {
  return [
    stepItem(ctx.step),
    _sesItem(ctx, withKey: false),
    okCodepageItem,
    buildApplItem(12, 4, wireText(cfwGenericEventOkcode(shell, eventId))),
    ..._commonTail(ctx),
    if (eventId == treeEventExpandNoChildren) ...[
      buildApplItem(4, 36, _treeExpand436),
      buildApplItem(4, 40, _winPx(ctx).sublist(0, 8)),
      buildApplItem(4, 42, _treeExpand442),
    ],
    buildApplItem(5, 1, _okEvent(ctx, mode: 0x0b)),
    buildApplItem(12, ctx.modalNo != 0 ? 14 : 8, _winPx(ctx)),
    buildApplItem(12, 6, _scrollInfos2(ctx)),
    buildApplItem(9, 18, wireText(shell)), // the event's shell context
    xmlBlobItem(treeEventXml(
        shell: shell,
        eventId: eventId,
        nodeKey: nodeKey,
        itemName: itemName,
        topNodeKey: topNodeKey)),
    eomBytes,
  ];
}

/// A plain function-key press (Enter = 0, F3 = 3, F8 = 8, …).
List<Uint8List> pressItems(ActionContext ctx, int vkey) {
  return [
    stepItem(ctx.step),
    _sesItem(ctx, vkey: vkey),
    okCodepageItem,
    ..._commonTail(ctx),
    buildApplItem(5, 1, _okEvent(ctx, mode: 0x0b)),
    buildApplItem(12, ctx.modalNo != 0 ? 14 : 8, _winPx(ctx)),
    buildApplItem(12, 6, _scrollInfos2(ctx)),
    buildApplItem(9, 10, Uint8List(0)), // DYNT_NOFOCUS
    xml17Item(),
    eomBytes,
  ];
}

/// An ok-code round (`/nXXXX`, `=FCODE`, …) — no key event in the SES.
List<Uint8List> okcodeItems(ActionContext ctx, String cmd) {
  return [
    stepItem(ctx.step),
    _sesItem(ctx, withKey: false),
    okCodepageItem,
    buildApplItem(12, 4, wireText(cmd)),
    ..._commonTail(ctx),
    buildApplItem(5, 1, _okEvent(ctx, mode: 0x0b)),
    buildApplItem(12, ctx.modalNo != 0 ? 14 : 8, _winPx(ctx)),
    buildApplItem(12, 6, _scrollInfos2(ctx)),
    buildApplItem(9, 10, Uint8List(0)),
    xml17Item(),
    eomBytes,
  ];
}

/// The etype-130 value-submit atom (value-only, no name).
Uint8List submitAtom(int row, int col, String text,
    {int area = 0,
    int block = 1,
    int group = 0,
    int dlg1 = 0,
    int dlg2 = 0,
    int? mx,
    int? mlen,
    bool yes3d = true,
    int? attr}) {
  final t = wireText(text);
  mx ??= text.isEmpty ? 1 : text.length;
  mlen ??= mx;
  if (t.length > 0xff) {
    throw ArgumentError('dynpro value of ${t.length} bytes exceeds 255');
  }
  return buildValueAtom130(
    area: area,
    block: block,
    group: group,
    row: row,
    col: col,
    text: text,
    dlg1: dlg1,
    dlg2: dlg2,
    attr: attr ?? (yes3d ? 0x40 : 0),
    mlen: mlen,
    maxnrchars: mx,
  );
}

/// A full field submit (value + Enter), the `_build_submit_full_items` shape.
///
/// [attr] = the painted atom's attribute byte, echoed on the value atom (the
/// reference client's accepted SE16 fill carries the field's own `0xc0`, COMBOSTYLE +
/// YES3D — a recorded session gui_fill_22); null = a bare YES3D.
/// [mx]/[mlen] = the painted maxnrchars / mlen (30/30 there); null = the
/// value length. The value is the frontend's: trailing blanks trimmed and
/// never empty — a cleared field is ONE SPACE (the engine's wire_value_text;
/// a dlen-0 atom the kernel silently ignores).
///
/// [routing] = the field's container plane ([ScreenField.routing]) when it
/// sits on a tabstrip page / in a nested subscreen chain: the flat 16/10/1
/// is replaced by the routing cluster, the page's 16/12/6 precedes the
/// atom and the 16/9/11 carries the container path (offset = the value's
/// CHARACTER count, the reference client's _nested_focus_bytes); the OK cursor
/// carries the chain's screen offset. Without it, such a field is refused
/// "FOCUS DATA" (SXMB_MONI RSSYSTDB/1000 RCVRPRTY,
/// a recorded session).
List<Uint8List> fillItems(ActionContext ctx, int row, int col, String rawText,
    {int area = 0,
    int block = 1,
    int group = 0,
    int? mx,
    int? mlen,
    int vkey = 0,
    int dlg1 = 0,
    int dlg2 = 0,
    int? attr,
    FieldRouting? routing}) {
  return fieldRoundItems(ctx, [
    FieldWrite(row, col, rawText,
        area: area,
        block: block,
        group: group,
        mx: mx,
        mlen: mlen,
        dlg1: dlg1,
        dlg2: dlg2,
        attr: attr,
        routing: routing),
  ], vkey: vkey);
}

/// One value of a field round: the field's WIRE cell, its painted sizes /
/// attribute / dlg flags and its container plane ([ScreenField.routing]).
/// [text] is the frontend's value: trailing blanks trimmed, a cleared field
/// ONE SPACE (see [fillItems]).
class FieldWrite {
  FieldWrite(this.row, this.col, String rawText,
      {this.area = 0,
      this.block = 1,
      this.group = 0,
      this.mx,
      this.mlen,
      this.dlg1 = 0,
      this.dlg2 = 0,
      this.attr,
      this.routing})
      : text = rawText.trimRight().isEmpty ? ' ' : rawText.trimRight(),
        checkbox = false,
        labelWidth = 0;

  /// The tick / untick of ONE dynpro checkbox (the TcCellWrite `checkbox`
  /// precedent of a table-control cell): its segment carries the etype-128
  /// value atom ([checkboxValueAtom]) in place of a text atom — [text] is
  /// the state `X` / blank, [labelWidth] and the dlg flags the PAINTED
  /// ones, echoed. A checkbox write contributes no characters to the
  /// round's focus offset nor to the OK cursor column (a recorded session
  /// gui[38]: 16/9/11 offset 0 on the ticked INPLACE).
  FieldWrite.checkbox(this.row, this.col, bool on,
      {this.area = 0,
      this.block = 1,
      this.group = 0,
      this.dlg1 = 0,
      this.dlg2 = 0,
      this.labelWidth = 0,
      this.routing})
      : text = on ? 'X' : ' ',
        checkbox = true,
        mx = null,
        mlen = null,
        attr = null;
  final int row, col, area, block, group, dlg1, dlg2;
  final int? mx, mlen, attr;
  final FieldRouting? routing;
  final String text;

  /// A checkbox tick ([FieldWrite.checkbox]) rather than a typed value.
  final bool checkbox;

  /// A checkbox's painted visible label length (its atom's bytes 14-15).
  final int labelWidth;

  /// The characters the round's focus / OK cursor advances past this
  /// write: a typed value's length, nothing for a checkbox.
  int get chars => checkbox ? 0 : text.length;

  /// The container plane's identity: writes of one plane share a segment.
  String get planeKey {
    final r = routing;
    if (r == null) return 'flat';
    final b = StringBuffer(r.path.join('.'));
    for (final l in r.pre) {
      b.write('|${l.id}/${l.sid}=${l.value.join(',')}');
    }
    return b.toString();
  }
}

/// The focus cell of a round whose cursor sits on a field it does not
/// write (F4 on an untouched field while other values ride along).
class FieldCursor {
  const FieldCursor(this.row, this.col, {this.area = 0, this.routing});
  final int row, col, area;
  final FieldRouting? routing;
}

/// The 16/15/1 UI_EVENT_SOURCE of a click on a dynpro PUSHBUTTON: `02 0009
/// 0007 00000000 00 [row u16 LE] [col u16 LE] [depth] [path]` (reference client
/// raw_fields._element_event_source; the reference client's accepted SE38 `=SHOP`
/// write, a recorded session step 41: `02 0009 0007
/// 0000000000 0b00 0000 01 00` — the button at (11, 0), path 00).
Uint8List buttonEventSource(int row, int col, List<int> path) {
  final p = path.isEmpty ? const [0] : path;
  return Uint8List.fromList([
    0x02, 0x00, 0x09, 0x00, 0x07, 0, 0, 0, 0, 0,
    row & 0xff, row >> 8 & 0xff, col & 0xff, col >> 8 & 0xff,
    p.length, ...p,
  ]);
}

/// The Java 16/15/1 of a click on a dynpro CHOICE element with a function
/// code: BUTTONPRESSED (0x09) on [controlType] — 2 RADIOBUTTON
/// ([radioElementKind]), 3 CHECKBUTTON ([checkboxElementKind]; pysap
/// SAPDiagUIEventSource control_type, the reference client's RADIO_ELEMENT_KIND /
/// CHECKBOX_ELEMENT_KIND) — at the element's cell and container [path]:
/// [buttonEventSource]'s layout (the Java oracle se39 gui[21]); the
/// Windows GUI sends STATECHANGED 0x0b (frontend_profile
/// .windowsActionItems).
Uint8List choiceEventSource(int row, int col, List<int> path,
        {required int controlType}) =>
    buttonEventSource(row, col, path)..[4] = controlType & 0xff;

/// The UI-event control type of a dynpro radio button (a recorded session
/// radio_wingui gui[5]) and of a checkbox (the radio's rule applied to its
/// twin: no Windows checkbox event capture exists — reference client raw_checkbox
/// CHECKBOX_ELEMENT_KIND).
const int radioElementKind = 2;
const int checkboxElementKind = 3;

/// The Java 16/15/1 of a click on a dynpro RADIO with a function code
/// ([choiceEventSource] on control type 2).
Uint8List radioEventSource(int row, int col, List<int> path) =>
    choiceEventSource(row, col, path, controlType: radioElementKind);

/// A FIELD ROUND — every changed field of the screen in ONE PAI with the
/// action that follows (the real GUI's one event list: GuiDataMgr
/// .fireValueChanges, reference client deferred_fill), in the reference client's
/// `_build_submit_full_items` / `fill_many` shape (Java spelling,
/// [windowsActionItems] re-spells it):
///
/// * the action: [vkey] (Enter = 0, F7, F4 …) in the SES and the 16/15/1
/// function-key source, or an [okcode] (16/12/4 right after the
/// codepage, no key in the SES) — with the painted [button] the code
/// belongs to, the OK event is the element-click mode 0x0d and the
/// 16/15/1 the button's ([buttonEventSource]);
/// * one SEGMENT per container plane — a flat main-dynpro 16/10/1, or a
/// field's routing cluster + its page 16/12/6 — each followed by ONE
/// 16/9/2 carrying all its atoms in write order (the real Windows GUI's
/// FBV1 Enter: three atoms of two visual blocks in one blob under one
/// 16/10/1, a recorded session gui 10; main + tabstrip planes in
/// one PAI = two segments, a recorded session);
/// the segment of the LAST write goes last;
/// * the 16/9/11 focus on the last write (offset = its value length, 0
/// for a checkbox tick) or on [cursor] (offset 0), the OK cursor after
/// it;
/// * [eventSource]: the 16/15/1 of a CHOICE element whose own function
/// code the round carries as [okcode] — a radio's / a checkbox's
/// ([choiceEventSource]), in a [button]'s place — the OK event stays
/// the field submit's 0x05 (a recorded session
/// g13 / g32).
List<Uint8List> fieldRoundItems(ActionContext ctx, List<FieldWrite> writes,
    {int vkey = 0,
    String? okcode,
    (int row, int col, List<int> path)? button,
    FieldCursor? cursor,
    Uint8List? eventSource}) {
  if (writes.isEmpty) throw ArgumentError('a field round needs a value');
  // segments by plane, first appearance, the last write's plane last
  final segs = <String, List<FieldWrite>>{};
  for (final w in writes) {
    (segs[w.planeKey] ??= []).add(w);
  }
  final lastKey = writes.last.planeKey;
  final order = [
    for (final k in segs.keys)
      if (k != lastKey) k,
    lastKey,
  ];

  // the focus: the last write, or the cursor field
  final focusRow = cursor?.row ?? writes.last.row;
  final focusCol = cursor?.col ?? writes.last.col;
  final focusRouting = cursor != null ? cursor.routing : writes.last.routing;
  final focusArea = cursor?.area ?? writes.last.area;
  final focusText =
      cursor != null || writes.last.checkbox ? '' : writes.last.text;
  final chars = focusText.length;
  final path = focusRouting?.path ?? [focusArea & 0xff];
  final focus = Uint8List(9 + path.length);
  final fbd = focus.buffer.asByteData();
  focus[0] = path.length; // depth
  fbd.setUint16(1, focusRow);
  fbd.setUint16(3, focusCol);
  // a routed field's offset counts characters, a flat one bytes
  fbd.setUint32(5, focusRouting != null ? chars : t_byteLen(focusText));
  focus.setRange(9, focus.length, path);
  final roff = focusRouting?.rowOffset ?? 0;
  final coff = focusRouting?.colOffset ?? 0;

  final c1010 = Uint8List(9);
  c1010[6] = ctx.areaCols & 0xff;
  c1010[8] = ctx.areaRows & 0xff;

  final keyed = okcode == null;
  return [
    stepItem(ctx.step),
    _sesItem(ctx, vkey: keyed ? vkey : 0, withKey: keyed),
    okCodepageItem,
    if (okcode != null) buildApplItem(12, 4, wireText(okcode)),
    ..._commonTail(ctx),
    buildApplItem(
        5,
        1,
        _okEvent(ctx,
            mode: button != null ? 0x0d : 0x05,
            cursorRow: (focusRow + roff) & 0xff,
            cursorCol: (focusCol + coff + chars) & 0xff)),
    buildApplItem(12, ctx.modalNo != 0 ? 14 : 8, _winPx(ctx)),
    buildApplItem(12, 6, _scrollInfos2(ctx)),
    for (final k in order) ..._segment(segs[k]!, c1010),
    // a keyed round's 16/15/1 is the re-spelling's (windowsActionItems)
    if (button != null)
      buildApplItem(15, 1, buttonEventSource(button.$1, button.$2, button.$3))
    else if (eventSource != null)
      buildApplItem(15, 1, eventSource),
    buildApplItem(9, 11, focus),
    xml17Item(),
    eomBytes,
  ];
}

/// One container segment of a field round: the plane's container items
/// and one 16/9/2 with every atom of the plane.
List<Uint8List> _segment(List<FieldWrite> ws, Uint8List c1010) {
  final routing = ws.first.routing;
  final atoms = BytesBuilder(copy: false);
  for (final w in ws) {
    atoms.add(fieldWriteAtom(w));
  }
  return [
    if (routing == null)
      buildApplItem(10, 1, c1010)
    else ...[
      for (final l in routing.pre) buildApplItem(l.id, l.sid, l.value),
      if (routing.scroll != null &&
          !(routing.pre.isNotEmpty &&
              routing.pre.last.id == 12 &&
              routing.pre.last.sid == 6))
        buildApplItem(12, 6, routing.scroll!),
    ],
    buildApplItem(9, 2, atoms.takeBytes()),
  ];
}

int t_byteLen(String text) => wireText(text).length;

/// The value atom of one field write: a typed value's etype-130 atom
/// ([submitAtom]; a scrollable field's dlg flag 4 when its maxnrchars
/// exceeds its mlen), a checkbox tick's etype-128 one
/// ([checkboxValueAtom] — a recorded session gui[38]: a listbox atom and
/// the INPLACE tick in ONE 16/9/2).
Uint8List fieldWriteAtom(FieldWrite w) {
  if (w.checkbox) {
    return checkboxValueAtom(w.area, w.block, w.group, w.row, w.col,
        w.text == 'X',
        labelWidth: w.labelWidth, dlg1: w.dlg1, dlg2: w.dlg2);
  }
  final dlg1 =
      (w.mx != null && w.mlen != null && w.mx! > w.mlen!) ? 4 : w.dlg1;
  return submitAtom(w.row, w.col, w.text,
      area: w.area,
      block: w.block,
      group: w.group,
      dlg1: dlg1,
      dlg2: w.dlg2,
      mx: w.mx,
      mlen: w.mlen,
      attr: w.attr);
}

/// A radio-group selection PAI: the etype-129 value atoms for the CHANGED
/// members of the group only — the pick turned on, the previously-on sibling
/// cleared — riding a full ENTER envelope, cursor on the chosen cell. The
/// caller filters the group down to its changed members; a member already off
/// is never sent (the kernel clears it itself; extra atoms are an invalid
/// delta the kernel rejects).
///
/// [fcode] = the radio group's own function code (a radio with an fcode
/// fires PAI on its click, `=TOGGLE` on SAPLSEWB_CONTROL/0400): the code
/// rides 16/12/4 and the round carries the radio's ELEMENT event, the Java
/// BUTTONPRESSED on RADIOBUTTON at the chosen cell ([radioEventSource]) —
/// the Windows re-spelling turns it into STATECHANGED
/// (a recorded session g13 / g32). [vkey] = the key
/// the pick rides (F8 on a selection screen, a recorded session
/// gui[5]); 0 = Enter.
List<Uint8List> radioSelectItems(
  ActionContext ctx,
  List<(int area, int block, int group, int row, int col, bool on, int labelWidth)> members, {
  int cursorRow = 0,
  int cursorCol = 0,
  int cursorArea = 0,
  String? fcode,
  int vkey = 0,
}) {
  final group = BytesBuilder(copy: false);
  for (final (area, block, grp, row, col, on, labelWidth) in members) {
    group.add(radioValueAtom(area, block, grp, row, col, on,
        labelWidth: labelWidth));
  }
  final focus = Uint8List(10);
  focus[0] = 1; // depth
  focus.buffer.asByteData().setUint16(1, cursorRow);
  focus.buffer.asByteData().setUint16(3, cursorCol);
  focus[9] = cursorArea & 0xff;

  final c1010 = Uint8List(9);
  c1010[6] = ctx.areaCols & 0xff;
  c1010[8] = ctx.areaRows & 0xff;

  return [
    stepItem(ctx.step),
    _sesItem(ctx, vkey: vkey, withKey: fcode == null),
    okCodepageItem,
    if (fcode != null) buildApplItem(12, 4, wireText(fcode)),
    ..._commonTail(ctx),
    buildApplItem(
        5,
        1,
        _okEvent(ctx, mode: 0x05, cursorRow: cursorRow, cursorCol: cursorCol)),
    buildApplItem(12, ctx.modalNo != 0 ? 14 : 8, _winPx(ctx)),
    buildApplItem(12, 6, _scrollInfos2(ctx)),
    buildApplItem(10, 1, c1010),
    buildApplItem(9, 2, group.takeBytes()),
    if (fcode != null)
      buildApplItem(
          15, 1, radioEventSource(cursorRow, cursorCol, [cursorArea & 0xff])),
    buildApplItem(9, 11, focus),
    xml17Item(),
    eomBytes,
  ];
}

/// A CHECKBOX tick / untick PAI — the radio pick's twin ([radioSelectItems])
/// on the ONE changed box: its etype-128 value atom ([write], a
/// [FieldWrite.checkbox]) rides the routed field-write envelope with the
/// typed values [staged] before it ([fieldRoundItems]: one 16/9/2 per plane,
/// the focus on the box at offset 0 — a recorded session gui[38], the real
/// Windows GUI's Enter over a listbox pick and the INPLACE tick). [fcode] =
/// the box's own function code when it has one (the click then fires PAI as
/// its element event: 16/12/4 + the CHECKBUTTON source, the radio's
/// `=TOGGLE` shape); [vkey] = the key the tick rides (0 = Enter).
List<Uint8List> checkboxSelectItems(
  ActionContext ctx,
  FieldWrite write, {
  List<FieldWrite> staged = const [],
  String? fcode,
  int vkey = 0,
}) {
  if (!write.checkbox) throw ArgumentError('a checkbox write is needed');
  return fieldRoundItems(
    ctx,
    [...staged, write],
    vkey: vkey,
    okcode: fcode,
    eventSource: fcode == null
        ? null
        : choiceEventSource(
            write.row, write.col, write.routing?.path ?? [write.area & 0xff],
            controlType: checkboxElementKind),
  );
}

/// The painted dynpro pushbutton of [screen] whose function code is [cmd]
/// (`=FCODE` or `FCODE`), as (wire row, wire col, container path) — the
/// path = the button's own container chain ([ScreenField.routing], e.g.
/// ME21N's `=MEV4002BUTTON` `01 04 01` on a recorded session srv
/// [152..153]), else its atom area. Null when no painted button carries
/// the code (a menu / toolbar function: a typed okcode). The first painted
/// button wins when several carry the code (table-control row buttons).
(int, int, List<int>)? paintedPushbutton(ScreenModel? screen, String cmd) {
  final want = cmd.trim().replaceFirst(_leadingEqualsRx, '').toUpperCase();
  if (want.isEmpty) return null;
  for (final f in screen?.fields ?? const <ScreenField>[]) {
    if (f.kind != FieldKind.pushbutton) continue;
    final fc = (f.fcode ?? '').trim().replaceFirst(_leadingEqualsRx, '');
    if (fc.toUpperCase() == want) {
      return (f.wireRow, f.wireCol, f.routing?.path ?? [f.area & 0xff]);
    }
  }
  return null;
}

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call.
final RegExp _leadingEqualsRx = RegExp('^=');
