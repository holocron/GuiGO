/// The Windows-dialect connect frame for a replayed logon: the built Windows
/// connect (logon_frames.dart) with a recorded frame's connection words
/// (frontend_profile.connect_frame port). Offsets pinned against the
/// engine's output: rq_id BE u16 at 39, terminal 16 B at 81, unused10 57 B
/// at 143..200. Also the Windows respelling of a recorded logon submit
/// (frontend_profile.patch_login_frame port).
library;

import 'dart:typed_data';

import '../cfw/flush_call.dart' show GuiDialect;
import '../codepages.dart';
import '../framing/diag_frame.dart';
import '../framing/envelope.dart';
import '../items/dynt_atom.dart';
import '../screen/field_routing.dart' show windowsTabstripState;
import 'actions.dart';
import 'frames.dart';
import 'grid_edit_actions.dart' show uiEventControlAt;
import 'gui_profile.dart';
import 'logon_frames.dart';

const int dpHeaderLen = 200;

Uint8List _hexBytes(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// The DIAG connect frame[0] a Windows-profile session presents for a
/// REPLAYED logon: the built Windows connect ([buildConnectFrame]) with the
/// recorded frame's connection words (rq_id, terminal, unused10) spliced
/// in, as the reference client's frontend_profile.connect_frame does with its
/// fixture. A live logon sends [buildConnectFrame] itself. [language]: the
/// connect's ST_USER 39 ([connectLanguage]).
Uint8List windowsConnectFrame(Uint8List fixtureFrame0,
    {String language = defaultLogonLanguage}) {
  final out = buildConnectFrame(dialect: GuiDialect.windows, language: language);
  if (fixtureFrame0.length < dpHeaderLen) return out;
  out.setRange(39, 41, fixtureFrame0.sublist(39, 41));
  out.setRange(81, 97, fixtureFrame0.sublist(81, 97));
  out.setRange(143, dpHeaderLen, fixtureFrame0.sublist(143, dpHeaderLen));
  return out;
}

/// The SES `eventarray` byte mapping Java → Windows: the Windows GUI never
/// sends the Java enum values (1 = FKEY, 2 = MENU); a key round is 0x50
/// (eventid1 = the vkey), a menu-position round 0x41. The kernel validates
/// the byte against the connect dialect and refuses the Java spelling on a
/// Windows connection (`invalid eventarray[0] data`, diaginp.c:891 → the
/// connection is dropped).
const Map<int, int> winSesEventarray = {0x01: 0x50, 0x02: 0x41};

/// The `16/06/35` codepage item VALUE of a Windows client frame: "4110" /
/// "utf-8" (the Java spelling is "4110" / "UTF8").
final Uint8List winCodepageValue = _hexBytes('0000100e0134313130007574662d3800');

/// The per-frame `16/04/*` identity atoms of a Windows client frame, in wire
/// order (the Java set is 16/04/43 OS + 16/04/44 + 16/04/25 + 16/04/04).
final List<(int, Uint8List)> winIdentity = [
  (9, wireText(emulatedGuiRelease)), // 16/04/09 "800"
  (29, wireText(emulatedGuiPatchLevel)), // 16/04/29 GUI patch level "18"
  (15, _hexBytes('0000005d')), // 16/04/15 (u32 93)
  (25, _hexBytes('0000')), // 16/04/25
];

/// The logon submit re-spelled for the Windows dialect (frontend_profile.
/// patch_login_frame port, applied AFTER the credential splice and the
/// screen-size patch — the engine's ladder order): every SES item's
/// eventarray byte mapped through [winSesEventarray], the 16/06/35 codepage
/// item re-spelled, the Java identity atoms (16/04/43, 44, 25, 4) replaced
/// once by [winIdentity], and the Java 16/12/8 window-px item dropped. Without
/// this, a windowsConnectFrame logon whose submit still carries the fixture's
/// Java `\x01` eventarray is refused and the connection closed.
Uint8List patchLoginFrameWindows(Uint8List rawFrame) {
  final plain = plainFrame(rawFrame);
  final walk = walkItems(Uint8List.sublistView(plain, diagHeaderLen));
  final out = <Uint8List>[];
  var identityDone = false;
  for (final it in walk.items) {
    if (it.type == itemSes) {
      // fixed-length item: 1 header byte, so value[0] rides at raw[1]
      final ses = Uint8List.fromList(it.itemBytes);
      if (ses.length > 1) ses[1] = winSesEventarray[ses[1]] ?? ses[1];
      out.add(ses);
    } else if (it.isAppl && it.id == 6 && it.sid == 35) {
      out.add(buildApplItem(6, 35, winCodepageValue));
    } else if (it.isAppl && it.id == 4 && const {43, 44, 25, 4}.contains(it.sid)) {
      if (!identityDone) {
        for (final (sid, value) in winIdentity) {
          out.add(buildApplItem(4, sid, value));
        }
        identityDone = true;
      }
    } else if (it.isAppl && it.id == 12 && it.sid == 8) {
      // dropped: the Windows GUI sends its own 16/12/8 on event rounds only
    } else {
      out.add(it.itemBytes);
    }
  }
  return clientFrame(out, mode: plain[0]);
}

/// The `16/04/36` window rect of a Windows client action frame (8 bytes,
/// height / width px u32 BE): [ActionContext.winWindowRectPx] — the
/// device's display when the app reports one (EmulatedGuiProfile
/// .displayPx), else the reference GUI's `0000 0409 0000 0781` (the
/// reference client's accepted value — a recorded session, its okcode
/// round). [ctx] null: the reference value.
Uint8List windowsWindowRect(ActionContext? ctx) {
  final (h, w) = ctx?.winWindowRectPx ?? ActionContext.recordedWindowRectPx;
  return (ByteData(8)
        ..setUint32(0, h)
        ..setUint32(4, w))
      .buffer
      .asUint8List();
}

/// The three window atoms of a Windows window's first round, in wire order:
/// 16/4/4 FONTMETRIC, 16/4/36 DISPLAY_SIZE, 16/4/40 MAINAREA_SIZE
/// ([ActionContext.winFontMetric] / [ActionContext.winDisplayPx] /
/// [ActionContext.winMainAreaPx]) — [windowsFirstRoundItems] places them in
/// a round, logonItems right after the logon submit's SES.
List<Uint8List> windowsFirstRoundAtoms(ActionContext ctx) {
  Uint8List pair(int a, int b) => (ByteData(8)
        ..setUint32(0, a)
        ..setUint32(4, b))
      .buffer
      .asUint8List();
  final f = ctx.winFontMetric;
  final font = (ByteData(8)
        ..setUint16(0, f.cellHeight)
        ..setUint16(2, f.cellWidth)
        ..setUint16(4, f.charHeight)
        ..setUint16(6, f.charWidth))
      .buffer
      .asUint8List();
  return [
    buildApplItem(4, 4, font),
    buildApplItem(4, 36, pair(ctx.winDisplayPx.$1, ctx.winDisplayPx.$2)),
    buildApplItem(4, 40, pair(ctx.winMainAreaPx.$1, ctx.winMainAreaPx.$2)),
  ];
}

// The `16/04/*` atoms the SAP GUI for Windows sends ONCE, in the first
// round of the logon (the logon submit — a recorded session
// gui[1], a recorded session gui[1]; a ticket logon's first SES
// round — a recorded session gui[3]), right before the
// [winIdentity] block — 16/04/31 GUI_OS_VERSION, 16/04/32
// BROWSER_VERSION, 16/04/33 OFFICE_VERSION, 16/04/37 GUI_TYPE — are the
// session's EmulatedGuiProfile.logonIdentity (gui_profile.dart; the
// recording PC's own: EmulatedGuiProfile.recordedWindowsGui).

/// The FIRST round the SAP GUI for WINDOWS sends in a window carries
/// 16/4/4 FONTMETRIC + 16/4/36 DISPLAY_SIZE + 16/4/40 MAINAREA_SIZE
/// ([ActionContext.winFontMetric] / [ActionContext.winDisplayPx] /
/// [ActionContext.winMainAreaPx]) — whoever opened the window, whatever the
/// round — and the next round none: a recorded session raw gui[8] (the
/// typed okcode `%_SEARCH_OKCODE su53`, the first round in client-opened
/// mode 1; raw gui[10] none) and raw gui[29] (F3, the first round in
/// server-opened mode 2; raw gui[37] none), a recorded session
/// gui[1274] (F3 in server mode 1; gui[1276] none) and gui[1297] (F6 in
/// server mode 2; gui[1300] none); the logon submit of mode 0 carries them
/// too (a recorded session gui[1]; GuiGo's field-built logon
/// does — logonItems — the fixture-patched logon of an offline replay
/// does not). Placement: right after the 16/12/4 of an okcode round
/// (gui[8], a recorded session gui[3]), else right after the
/// SES (gui[29], gui[1274], gui[1297]); a 16/4/36 the round already carries
/// (the modal okcode / key extra) is replaced — a first round's 16/4/36 is
/// the display's in every capture. [items]: a round in the Windows dialect.
List<Uint8List> windowsFirstRoundItems(
    List<Uint8List> items, ActionContext ctx) {
  final atoms = windowsFirstRoundAtoms(ctx);
  DiagItem? one(Uint8List raw) {
    final w = walkItems(raw).items;
    return w.length == 1 ? w.single : null;
  }

  var at = -1;
  for (var i = 0; i < items.length; i++) {
    final it = one(items[i]);
    if (it == null) continue;
    if (it.isAppl && it.id == 12 && it.sid == 4) {
      at = i + 1;
      break;
    }
    if (it.type == itemSes && at < 0) at = i + 1;
  }
  if (at < 0) return items;
  final out = <Uint8List>[];
  for (var i = 0; i < items.length; i++) {
    if (i == at) out.addAll(atoms);
    final it = one(items[i]);
    if (it != null && it.isAppl && it.id == 4 && const {4, 36, 40}.contains(it.sid)) {
      continue; // the round's own copy: the first round's replaces it
    }
    out.add(items[i]);
  }
  if (at >= items.length) out.addAll(atoms);
  return out;
}

/// The SES modal level of a round [items] (its first SES's modal_no byte),
/// null for a frame without an SES (an RFC / OLE reply, a chunk receipt).
int? windowsRoundModalLevel(List<Uint8List> items) {
  for (final raw in items) {
    final w = walkItems(raw).items;
    if (w.length == 1 && w.single.type == itemSes) {
      final v = w.single.value;
      return v.length > 7 ? v[7] : 0;
    }
  }
  return null;
}

/// The FIRST main-window round after a round sent from inside a popup (one
/// carrying the popup's 16/4/36 rect — SapSession._withAfterPopup)
/// carries 16/4/36 = the DISPLAY size ([ActionContext.winDisplayPx], `0000
/// 0419 0000 0f01`), placed as [windowsFirstRoundItems] places it — right
/// after the 16/12/4 of an okcode round, else right after the SES — and
/// replacing a 16/4/36 the round carries: a recorded session raw
/// gui[9] (menu round after the Statut popup), gui[11] (Enter after the
/// year popup), gui[20] (F3 after the En-tête popup) — and not gui[7] /
/// [14] / [17] / [21]; a recorded session raw gui[12] /
/// [17] (after the calendar's Cancel), a recorded session
/// buttons raw gui[41] (`/nex` after `=NO`). Corpus: 137 of the 150
/// Windows main-window rounds that follow a popup round carry it (2 a
/// `0419 0791` display, 11 none); of 979 that follow a main-window round
/// 947 carry none. Such a round carries no live METRICS item 17 either
/// (f4 raw gui[12] / [17]: 61 of the corpus' 62 function-key rounds after a
/// popup, against 58 of 342 after a main-window round): a METRICS-only
/// DATAMANAGER is dropped, control state rides as built (menu_focus raw
/// gui[20]). A window's first round ([windowsFirstRoundItems], its 16/4/40
/// present) already carries the display size: left as it is. [items]: a
/// main-window round in the Windows dialect.
List<Uint8List> windowsAfterPopupItems(
    List<Uint8List> items, ActionContext ctx) {
  Uint8List pair(int a, int b) => (ByteData(8)
        ..setUint32(0, a)
        ..setUint32(4, b))
      .buffer
      .asUint8List();
  final rect = buildApplItem(
      4, 36, pair(ctx.winDisplayPx.$1, ctx.winDisplayPx.$2));
  DiagItem? one(Uint8List raw) {
    final w = walkItems(raw).items;
    return w.length == 1 ? w.single : null;
  }

  if (items.any((raw) {
    final it = one(raw);
    return it != null && it.isAppl && it.id == 4 && it.sid == 40;
  })) {
    return items;
  }
  var at = -1;
  for (var i = 0; i < items.length; i++) {
    final it = one(items[i]);
    if (it == null) continue;
    if (it.isAppl && it.id == 12 && it.sid == 4) {
      at = i + 1;
      break;
    }
    if (it.type == itemSes && at < 0) at = i + 1;
  }
  if (at < 0) return items;
  final out = <Uint8List>[];
  for (var i = 0; i < items.length; i++) {
    if (i == at) out.add(rect);
    final it = one(items[i]);
    if (it != null && it.isAppl && it.id == 4 && it.sid == 36) continue;
    if (it != null && it.type == itemXmlBlob) {
      final xml = String.fromCharCodes(it.value);
      if (xml.contains('<METRICS') &&
          !xml.contains('<CONTROL') &&
          !xml.contains('<EVENT') &&
          !xml.contains('<TABLE')) {
        continue; // the live METRICS block: none after a popup
      }
    }
    out.add(items[i]);
  }
  if (at >= items.length) out.add(rect);
  return out;
}

/// The Windows GUI's 16/15/1 UI_EVENT_SOURCE of a CONTROL event round (a
/// `%_GC` tree event): byte-identical on a recorded session gui[13]
/// (SPRO tree, shell 120) and gui[33] (SM59 tree, shell 125) — not a
/// per-shell value.
final Uint8List winUiEventControl =
    _hexBytes('00000d000b000000000000000000010100000000000000000000000000000000');

/// The Java-form 16/15/1 UI_EVENT_SOURCE of a function key: flags 0x08
/// (function-key data valid), event type 7 FUNCTIONKEY, control type 10
/// DYNPRO, the key, no cursor (the engine's diag_construct
/// .ui_event_functionkey). A FIELD-SUBMIT round carries this form on the
/// Windows dialect too (the reference client's accepted SE16 fill at the test system,
/// a recorded session gui_fill_22: `08 0007 000a 00 …`).
Uint8List uiEventFunctionKeyJava(int vkey) {
  final v = Uint8List(16);
  v[0] = 0x08;
  v[2] = 0x07;
  v[4] = 0x0a;
  v[5] = vkey & 0xff;
  return v;
}

/// The Windows GUI's 16/15/1 of a function key pressed on the dynpro: flags
/// 0x0a, event type 7, control type 1, the key, the cursor row/col (u16 BE —
/// the 16/9/11 cursor's position), then the cursor's container chain: its
/// depth (u16) and path bytes — the client-form [cursor]
/// ([windowsClientCursor]) the round's 16/9/11 carries. A flat cursor
/// `01 … pp` gives `0001 pp` (gui_press_f3_23 `0a 0007 0001 03 000000 0001
/// 0022 0001 00`, a recorded session gui[7]); a nested one its whole chain
/// (a recorded session raw gui[29], F3 on SU3's tab page: 16/9/11 `02
/// 0001 0011 00000000 01 02` -> `… 0001 0011 0002 01 02`) — every Windows
/// key round of the corpus with a 16/9/11 (180 of 180). Without [cursor]
/// the flat form with the [modal] flag as its path byte (the engine's
/// frontend_profile.ui_event_functionkey). The Java form on a Windows key
/// round is answered with a silent re-paint.
Uint8List uiEventFunctionKeyWindows(int vkey,
    {int row = 0, int col = 0, bool modal = false, List<int>? cursor}) {
  final depth = cursor != null && cursor.length >= 10 ? cursor[0] : 0;
  final path = depth > 0 && cursor!.length >= 9 + depth
      ? cursor.sublist(9, 9 + depth)
      : <int>[modal ? 1 : 0];
  final v = Uint8List(15 + path.length);
  v[0] = 0x0a;
  v[2] = 0x07;
  v[4] = 0x01;
  v[5] = vkey & 0xff;
  final bd = v.buffer.asByteData();
  bd.setUint16(9, row & 0xffff);
  bd.setUint16(11, col & 0xffff);
  bd.setUint16(13, path.length);
  v.setRange(15, v.length, path);
  return v;
}

/// The Windows GUI's 16/15/1 of a mouse DOUBLE-CLICK on a dynpro element
/// in a popup: flags 0x02 (control position valid), event type 1 SELECT,
/// control type 1, no event data, the clicked cell (row / col u16 BE, the
/// 16/9/11 cursor's) and the cursor's container chain (u16 depth + path) —
/// a recorded session gui[19] (`02 0001 0001 00000000 0001 0000
/// 0001 01`, line 2 of the SAPMSSCF/1210 step loop on area 1) and
/// a recorded session gui[9] (`… 0001 0010 0001 00`).
Uint8List uiEventSelectWindows(List<int> cursor) {
  final depth = cursor.length >= 10 ? cursor[0] : 0;
  final path = depth > 0 && cursor.length >= 9 + depth
      ? cursor.sublist(9, 9 + depth)
      : const [0];
  final v = Uint8List(15 + path.length);
  v[0] = 0x02;
  v[2] = 0x01;
  v[4] = 0x01;
  if (cursor.length >= 5) v.setRange(9, 13, cursor.sublist(1, 5));
  v.buffer.asByteData().setUint16(13, path.length);
  v.setRange(15, v.length, path);
  return v;
}

/// A LIVE type-17 DATAMANAGER XML: the client's window METRICS computed
/// from the negotiated character screen (the engine's _live_xml — X3 =
/// cols x 8, Y3 = rows x 29 with the captures' constant cell metrics; the
/// reference client's 40x146 fill carries X3="1168" Y3="1160"). The fixture's frozen
/// CONTROLS copy is a different session's state.
Uint8List liveMetricsXml(int rows, int cols) => Uint8List.fromList(
    ('<?xml version="1.0" encoding="sap*"?><DATAMANAGER><COPY id="copy">'
            '<GUI id="gui">${metricsElement(rows, cols)}'
            '</GUI></COPY></DATAMANAGER>')
        .codeUnits);

/// The cursor a Windows key round echoes: the paint's own 16/9/11 in its
/// CLIENT form ([windowsClientCursor]: a nested cursor without the painted
/// trailing zero level — a recorded session raw srv[41] `03 0001 0011
/// 00000000 01 02 00` -> raw gui[29] `02 … 01 02`; never echoed in the
/// server form by any Windows round of the corpus), or the zero cursor
/// `01 00…` when the paint declared none (the engine's _current_cursor
/// fallback).
Uint8List _echoedFocus(ActionContext? ctx) {
  final painted = ctx?.paintedFocus;
  if (painted != null && painted.length >= 10) {
    return windowsClientCursor(painted);
  }
  return Uint8List(10)..[0] = 1;
}

/// SCROLL_INFOS2 spelled with one (rows, cols) pair throughout — the
/// engine's okcode / key template patched with the negotiated screen
/// (reference client gui_launch_17 / gui_press_f3_23: `00000028 00000092 …` = 40x146).
Uint8List _screenScrollInfos2(int rows, int cols) {
  final out = Uint8List(33);
  final bd = out.buffer.asByteData();
  bd.setUint32(0, rows);
  bd.setUint32(4, cols);
  bd.setUint32(8, rows);
  bd.setUint32(12, cols);
  bd.setUint32(24, rows);
  bd.setUint32(28, cols);
  out[32] = 1;
  return out;
}

/// An action round's items (press / okcode / fill / radio, built in the
/// fixture's Java spelling) re-spelled for a Windows connection, as the
/// engine's Windows profile sends them. Every round: SES eventarray mapped
/// through [winSesEventarray] and its DIM bytes = the window pixel pair's
/// low bytes, the 16/06/35 codepage item re-spelled, the Java identity atoms
/// (16/04/43, 44, 25, 4) replaced once by [winIdentity]. Then by kind:
///
/// * a typed OKCODE round (16/12/4, no value; reference client raw_okcode
/// ._windows_plain_command_items, edfd931 §2): the OK event `00 0b`
/// over zeros, 16/12/8 kept, the PAINTED 16/12/6
/// ([ActionContext.paintedGeometry]; the screen size without a paint),
/// the empty 16/9/10, no XML, NO 16/04/36 — a recorded session
/// gui[70] `su53`, a recorded session gui[7] `se38`; with a CFW
/// control focus ([ActionContext.paintedControlFocus]) the paint's
/// tabstrip echo after the 16/12/6 and `16/9/18 <shell>` in place of the
/// 16/9/10 (su53 gui[1118], a recorded session gui[30]);
/// from inside a MODAL the old shape — 16/04/36 after the okcode, `00
/// 05`, no 16/12/8 / 16/12/14, the popup's 16/12/6 (smartforms gui[33]).
/// A painted PUSHBUTTON's code is not a typed okcode: SapSession.okcode
/// sends [windowsPushbuttonItems] for it;
/// * a FIELD-SUBMIT round (an etype-130 value atom, flat or NESTED) as
/// the real SAP GUI for Windows spells it (reference client raw_fields
/// ._windows_write_items; oracles a recorded session
/// wingui g15 — a modal nested write — a recorded session gui[10]
/// and a recorded session gui[5]/[6] — main-window flat writes):
/// the OK event = its mode byte over ZEROS; the main 16/12/6 = the
/// paint's own ([ActionContext.paintedGeometry]) echoed verbatim; every
/// 16/10/1 container OPEN = nine zero bytes; 16/12/8 on a main window,
/// neither 16/12/8 nor the Java 16/12/14 in a modal; the LIVE metrics XML
/// on a main window, no item 17 in a modal; NESTED: each tabstrip-STATE
/// group of the routing (the cluster ending in a 16/9/15) moves AFTER
/// the atoms as its own [zero 16/10/1, legs, 16/9/15] segment, the
/// 16/9/15 in the Windows SHORT form ([windowsTabstripState]), right
/// before the event-source / focus tail. The 16/15/1: none on an Enter
/// (g15, FBV1 gui[10], wide gui[6]); a dynpro pushbutton's (OK mode
/// 0x0d) as built; on a function key the Windows-form key source aimed
/// at the focus cell (wide gui[5] F8 `0a 0007 0001 08 000000 0000 000d
/// 0001 00`, FBV1 gui[11] F11) — the reference client drops it there;
/// * a KEY round (a function key, no atom, no okcode; gui_press_f3_23): the
/// OK event's area bytes zeroed, 16/12/8 kept, the PAINTED 16/12/6 (the screen
/// size without a paint), and the Java DYNT_NOFOCUS replaced by the Windows-form 16/15/1
/// (the key + the cursor and its chain) and the echoed 16/9/11 cursor in
/// its client form ([_echoedFocus]), then the live metrics XML. With a
/// CFW CONTROL focus (the paint's trailing 16/9/18, no [cursor] aimed at
/// a field; reference client 52600c6): OK `00 0b` over zeros, 16/12/8, the PAINTED
/// 16/12/6, `16/9/18 <shell>` — no 16/15/1, no 16/9/11, no item 17
/// (a recorded session gui[37] / gui[42], F3 with the AbapEditor.1
/// shell 123 focused). With NO focus painted (the paint's 16/9/10,
/// [ActionContext.paintedNoFocus]) on a main window the same shape with
/// the empty 16/9/10 in the focus slot (a recorded session
/// gui[1297], F6 on srv[1581] `16/9/10`; 37 main-window key rounds of the
/// corpus after a 16/9/10 paint, all OK 0x0b + the painted 16/12/6, none
/// with a 16/15/1 or a METRICS item 17 — the reference client and GuiGo sent the
/// zero cursor). A NESTED cursor (client depth > 1) on a main window:
/// OK `00 0d` over zeros, the PAINTED 16/12/6 followed by the paint's
/// container echo the cursor lies in ([windowsCursorEcho]), the key
/// source and the client-form cursor (raw gui[29] on raw srv[41]: `10/1
/// 10/8 9/15` after the 16/12/6; every main-window key round of the
/// corpus with a depth > 1 cursor is OK 0x0d with the painted geometry).
/// reference client ff1e540 (complaint-key-round-popup-mode-and-echo+20261011-
/// 134734): EVERY key round carries the cursor-gated container echo
/// ([windowsCursorEcho]: the table-control groups only while the sent
/// cursor lies in them, the tabstrips always) right after its 16/12/6,
/// before the 16/15/1 / focus (744 of the corpus' 745 key rounds); a
/// MODAL key echoes the popup's own 16/12/6
/// ([ActionContext.paintedTopWindowGeometry]) and is OK 0x0d with a
/// nested cursor only when control state rides ([controlState]), else
/// 0x05; ENTER carries no 16/15/1 and, on a main window, item 17 only
/// for pending control state — or the METRICS block on the window's
/// first round ([firstRound]); a BARE F2 (no [cursor] aimed at a cell)
/// the same (reference client aee5865: a recorded session gui[304]; the
/// aimed TC pick a recorded session gui[10] keeps its
/// source). The popup key's 16/4/36 follows no rule the corpus settles:
/// left as built;
/// * a RADIO round (etype-129 atoms) rides the field-submit rules above
/// (reference client 7c4338e: the ONE Windows write builder): a radio element
/// event (its own fcode) re-spelled BUTTONPRESSED 0x09 -> STATECHANGED
/// 0x0b, a function key's source on control type 2, the main-plane
/// tabstrip segment synthesized from the paint
/// ([ActionContext.paintedTabstripEcho]) when it declares a tabstrip,
/// no 16/04/36 (a recorded session g13 / g32,
/// a recorded session gui[5]). The multi-logon wall answer
/// keeps its own captured envelope (login.dart).
///
/// A CONTROL EVENT round (`controlEvent: true` — a tree node expand, a
/// `%_GC` event with its DATAMANAGER XML) follows the real Windows GUI's
/// event frame instead (a recorded session gui[13]/[33], `%_GC 120 18`):
/// no 16/04/36 okcode extra, the Java EXPAND triple (16/04/36, 40, 42)
/// dropped, the 16/12/8 window-px item KEPT (the Windows GUI sends it on
/// event rounds), the 16/15/1 UI_EVENT_SOURCE of a control event at
/// [controlSourcePath] added before the 16/9/18 shell context — ONLY when
/// the caller names that path: the event shell sits in a LinkContainer'd
/// dynpro custom control the paint declares (SapSession._hostedSourcePath;
/// a recorded session gui[13] / [33] `0001 01`), none for a docked or
/// dialog-hosted control (workbench gui[105] / [107], smartforms gui[23] —
/// reference client 534a50c §3: 252 of the corpus' 253 rounds carrying a 16/15/1
/// name a painted custom control's path) — and the type-17 event XML
/// kept; then the generic Windows envelope [windowsControlEventEnvelope]
/// (edfd931): the window-state OK mode, the PAINTED 16/12/6 + the tabstrip
/// echo, the modal shape.
///
/// [doubleClick]: the key round is a mouse double-click on the element at
/// [cursor] (the choose key F2 aimed at it): no 16/15/1 on a main window,
/// the SELECT source ([uiEventSelectWindows]) in a popup.
///
/// [ctx] supplies the window pixel pair, the screen size and the painted
/// cursor; null keeps the engine defaults (40x146, 0x307 x 0x550, no cursor).
List<Uint8List> windowsActionItems(List<Uint8List> items,
    {bool controlEvent = false,
    List<int>? controlSourcePath,
    ActionContext? ctx,
    Uint8List? cursor,
    bool controlState = false,
    bool firstRound = false,
    bool doubleClick = false,
    bool graphicsFocus = false}) {
  // classify the round from what the Java builder put in it
  var hasOkcode = false, hasAtom = false, hasValueAtom = false, keyed = false;
  var hasEventSource = false; // a 16/15/1 built in (a button's)
  var vkey = 0;
  var elementKind = 1; // the focused element's UI-event control type
  for (final raw in items) {
    final walk = walkItems(raw);
    if (walk.items.length != 1) continue;
    final it = walk.items.single;
    if (it.type == itemSes && it.value.length >= 2) {
      keyed = it.value[0] == 0x50 || it.value[0] == 0x01;
      vkey = it.value[1];
    } else if (it.isAppl && it.id == 12 && it.sid == 4) {
      hasOkcode = true;
    } else if (it.isAppl && it.id == 15 && it.sid == 1) {
      hasEventSource = true;
    } else if (it.isAppl && it.id == 9 && it.sid == 2) {
      hasAtom = true;
      final atoms = parseDyntAtoms(Uint8List.fromList(it.value)).atoms;
      if (atoms.any((a) => a.etype == 130)) hasValueAtom = true;
      // a radio pick's etype-129 atoms ride the ONE Windows write builder
      // too (reference client 7c4338e: select_radio -> _windows_write_items
      // element_kind=2)
      if (atoms.any((a) => a.etype == 129)) {
        hasValueAtom = true;
        elementKind = 2;
      }
    }
  }
  final fieldRound = !controlEvent && hasValueAtom;
  final keyRound = !controlEvent && keyed && !hasOkcode && !hasAtom;
  // a typed okcode / menu function (no value, no event): reference client raw_okcode
  // ._windows_plain_command_items / windows_okcode_control_focus_items
  final okcodeRound = !controlEvent && hasOkcode && !fieldRound;
  final screenRows = ctx?.screenRows ?? 40;
  final screenCols = ctx?.screenCols ?? 146;
  final pxH = (ctx?.winPxHeight ?? 0x307) & 0xff;
  final pxW = (ctx?.winPxWidth ?? 0x550) & 0xff;
  final modal = (ctx?.modalNo ?? 0) != 0;
  // a CFW control holds the focus (the paint's trailing 16/9/18): a key /
  // typed okcode round names it in the focus slot (a recorded session
  // gui[37]/[42], su53 gui[1118]); a key AIMED at a field ([cursor]) keeps
  // its dynpro-cursor round
  final controlFocus = modal ? null : ctx?.paintedControlFocus;
  // a BARE key in a POPUP whose paint gave a CFW control the focus: the
  // same focus slot `16/9/18 <shell>`, no 16/15/1, no 16/9/11, OK 0x03
  // (a recorded session raw gui[10] / [15], F12 on the
  // SAP.CalendarControl.1 shell 118 / 123; a recorded session
  // options_buttons raw gui[30] F12 / gui[37] Shift+F2 on the 0651 option
  // grid 164 / 186; a recorded session gui[45]; su53 gui[810])
  final modalKeyControl =
      keyRound && modal && cursor == null ? ctx?.paintedControlFocus : null;
  final focusShell = controlFocus ?? modalKeyControl;
  final keyControl = keyRound && cursor == null && focusShell != null;
  final okcodeControl = okcodeRound && controlFocus != null;
  // the paint declared NO focus (its 16/9/10) on a main window: the key
  // round names none (su53 gui[1297])
  final keyNoFocus = keyRound &&
      !keyControl &&
      cursor == null &&
      !modal &&
      ctx != null &&
      ctx.paintedNoFocus &&
      ctx.paintedFocus == null;
  // the dynpro cursor a key round sends, in its client form
  final keyCursor = keyRound && !keyControl && !keyNoFocus
      ? (cursor != null ? windowsClientCursor(cursor) : _echoedFocus(ctx))
      : null;
  // a BARE key in a MODAL popup (no cursor aimed at a field): no 16/15/1,
  // no 16/12/8, no METRICS item 17 (a recorded session gui[22] F12 on
  // srv[34]; reference client raw_commands._windows_key_items `if modal`). Over the
  // corpus' 195 Windows modal key rounds none carries a 16/12/8.
  final keyModal = keyRound && modal;
  final keyModalBare = keyModal && cursor == null;
  // ENTER (vkey 0) is no function key: no 16/15/1 on any window (reference client
  // ff1e540: 209 of 209 Windows Enter rounds) and, on a main window, no
  // live METRICS item 17 — control state only when pending — except on the
  // window's FIRST round ([firstRound]), which keeps the METRICS block (7 of
  // 7 first-round Enters; 42 of the 68 main-window Enters carry no item 17:
  // a recorded session gui[66], a recorded session
  // gui[694], a recorded session gui[110])
  // A BARE F2 (vkey 2, the choose key — a double-click) on a main window
  // follows the same rule: no 16/15/1, item 17 as on Enter (reference client aee5865,
  // windows_key_round.no_event_source_key; complaint-windows-key-round-
  // residuals+20261011-150000 §3: 39 of the corpus' 40 main-window F2
  // rounds carry no event source — a recorded session gui[304] on
  // srv[329]; 29 no item 17, 7 pending control state, 4 the METRICS block).
  // The 40th is AIMED at a cell and keeps its source (a recorded session
  // f2pick_va03 gui[10], the TC line pick: `0a 0007 0010 …`) — a [cursor]
  // given here; GuiGo's TC cell keys ride tableCellItems' own source. No
  // other key splits: F3 keeps its source (78 of 83), F8 (37 of 71)
  // A MOUSE DOUBLE-CLICK ([doubleClick]: the choose key aimed at the
  // clicked cell — SAP GUI's double-click IS F2 with the cursor there) on a
  // MAIN window carries no source either (a recorded session
  // gui[22], the double-click on SAPMSSCF/1160's INFO1 line); in a POPUP it
  // carries the SELECT event at the clicked cell instead of the key's
  // (a recorded session gui[19] — double-click line 2 of the
  // 1210 popup: `02 0001 0001 00000000 0001 0000 0001 01`; the click + F2
  // of gui[22] none; a recorded session gui[9], the
  // double-click on SAPLSHL2/1700's output field: `… 0001 0010 0001 00`)
  final keyNoSource = keyRound &&
      (vkey == 0 ||
          (vkey == _chooseVkey &&
              (cursor == null || (doubleClick && !modal))));
  final keySelect = keyRound && doubleClick && modal && cursor != null;
  // a cursor NESTED in a container (client depth > 1) takes OK 0x0d over
  // zeros and the painted 16/12/6 — on a main window always (raw gui[29];
  // 35 + 36 main-window key rounds of the corpus with a depth > 1 cursor,
  // all 0x0d); in a POPUP only when the round carries control state (a
  // DATAMANAGER, [controlState]), else the plain 0x05 (reference client
  // windows_key_round.modal_nested_ok_mode, ff1e540: 30 of the corpus' 31
  // modal nested-cursor key rounds — 0x05 without item 17 on a recorded session
  // stms_wingui gui[22] / [31], se51_add_delete gui[43] / [53], subscreen_
  // radio_sameplane gui[15], tc_selector_popup_worklist gui[15],
  // wingui_session gui[25]; 0x0d with it on swdd_create gui[193] / [217] /
  // [219] / [234] / [236] / [238] / [242] / [267] / [280] / [282],
  // swdd_workflow gui[125], wda_context_create gui[62]; a recorded session
  // controls gui[41], a bare F12 at 0x0d with no item 17, does not fit).
  // It replaces "0x0d when aimed at the field" as the BARE-key rule, which
  // those bare 0x0d rounds contradicted; a key AIMED at a field ([cursor]
  // given: F4 / F1 on the field) keeps 0x0d as the reference client forces it — all 9
  // field-aimed nested popup keys of the corpus are 0x0d and none of the
  // 0x05 rounds above is aimed
  final keyNested = keyCursor != null &&
      keyCursor[0] > 1 &&
      (!modal || controlState || cursor != null);
  final keyBare = keyControl || keyNoFocus; // OK 0x0b, no source, no XML

  final out = <Uint8List>[];
  var identityDone = false;
  var mainGeometry = true; // the first 16/12/6 is the window's, later a page's
  for (final raw in items) {
    final walk = walkItems(raw);
    if (walk.items.length != 1) {
      out.add(raw);
      continue;
    }
    final it = walk.items.single;
    if (it.type == itemSes) {
      final ses = Uint8List.fromList(it.itemBytes);
      if (ses.length > 1) ses[1] = winSesEventarray[ses[1]] ?? ses[1];
      if (ses.length >= 17) {
        // DIM bytes = the window pixel pair's low bytes, not the char grid
        // (a recorded session; the reference client's rounds `07 50`)
        ses[15] = pxH;
        ses[16] = pxW;
        // from inside a POPUP: its position and its own pixel size
        // ([windowsModalSesDims])
        final popup =
            !controlEvent && ctx != null ? windowsModalSesDims(ctx) : null;
        if (modal && !controlEvent) {
          ses[9] = ctx!.modalX & 0xff;
          ses[10] = ctx.modalY & 0xff;
        }
        if (popup != null) {
          ses[15] = popup.$1;
          ses[16] = popup.$2;
        }
      }
      out.add(ses);
      // a popup's key round: the 16/4/36 window rect right after the SES
      // (menu_focus raw gui[8] / [10] / [18], f4 raw gui[10] / [15],
      // selection_options_buttons raw gui[30] / [37]: `0000 0409 0000
      // 0781`; 147 of the corpus' 179 Windows popup key rounds)
      if (keyModal) out.add(buildApplItem(4, 36, windowsWindowRect(ctx)));
    } else if (it.isAppl && it.id == 6 && it.sid == 35) {
      out.add(buildApplItem(6, 35, winCodepageValue));
    } else if (it.isAppl && it.id == 4 && const {43, 44, 25, 4}.contains(it.sid)) {
      if (!identityDone) {
        // an okcode round's extra (a field round with an okcode carries
        // none: the reference client's accepted SE38 `=SHOP` write, step 41)
        // A typed okcode carries it only from inside a MODAL popup
        // (a recorded session gui[33]); on a main window
        // the window rect rides only the first round after a logon /
        // resize (su53 gui[5] vs gui[70], gui[103] … — edfd931 §2)
        if (okcodeRound && modal) {
          out.add(buildApplItem(4, 36, windowsWindowRect(ctx)));
        }
        for (final (sid, value) in winIdentity) {
          out.add(buildApplItem(4, sid, value));
        }
        identityDone = true;
      }
    } else if (controlEvent &&
        it.isAppl &&
        it.id == 4 &&
        const {36, 40, 42}.contains(it.sid)) {
      // dropped: the Java GUI's EXPAND-only window-rect triple
    } else if (it.isAppl && it.id == 12 && it.sid == 8) {
      // the Windows GUI sends its window-px item on event, field and key
      // rounds; an okcode round (and the radio shape) carries none
      if (controlEvent ||
          (keyRound && !modal) ||
          ((fieldRound || okcodeRound) && !modal)) {
        out.add(raw);
      }
    } else if ((fieldRound || okcodeRound || keyModal) &&
        it.isAppl &&
        it.id == 12 &&
        it.sid == 14) {
      // a modal field write / typed okcode / key carries no window pixels
      // at all (g15, a recorded session gui[33], stms
      // gui[22], swdd gui[193])
    } else if (fieldRound && it.isAppl && it.id == 10 && it.sid == 1) {
      out.add(buildApplItem(10, 1, Uint8List(9))); // the zero OPEN
    } else if (controlEvent && it.isAppl && it.id == 9 && it.sid == 18) {
      if (controlSourcePath != null) {
        out.add(buildApplItem(15, 1, uiEventControlAt(controlSourcePath)));
      }
      out.add(raw);
    } else if (it.type == itemXmlBlob) {
      if (controlEvent) {
        out.add(raw); // an event round's XML IS the event
      } else if ((keyRound &&
              !keyBare &&
              !modal &&
              (!keyNoSource || firstRound)) ||
          (fieldRound && !modal)) {
        out.add(xmlBlobItem(liveMetricsXml(screenRows, screenCols)));
      }
      // a modal key round: item 17 only when control state is pending
      // (swdd gui[193]'s DATAMANAGER; SapSession merges a pending grid
      // state into any round)
      // a control-focus key round: item 17 only when control state is
      // pending (gui[37]/[42]: none)
      // an okcode / radio round: the Java GUI's DATAMANAGER copy dropped
    } else if (it.isAppl && it.id == 12 && it.sid == 6 && it.value.length >= 32) {
      if (fieldRound) {
        // the window's own geometry as painted (reference client painted_main_
        // geometry); a page's 16/12/6 inside the routing rides as built
        final painted = ctx?.paintedGeometry;
        out.add(mainGeometry && painted != null
            ? buildApplItem(12, 6, painted)
            : raw);
        mainGeometry = false;
      } else if (okcodeRound || keyBare || keyNested || keyModal) {
        // the PAINTED main geometry verbatim (su53 gui[70], workbench
        // gui[37], su53 gui[1297]; smartforms gui[33]); a MODAL key round
        // the popup's own — the first 16/12/6 after the paint's last
        // 16/12/7 (stms gui[22] `0016 0047`, reference client ff1e540)
        final fallback = _screenScrollInfos2(screenRows, screenCols);
        final top = keyModal ? ctx?.paintedTopWindowGeometry : null;
        out.add(buildApplItem(
            12,
            6,
            top != null
                ? Uint8List.fromList(top)
                : windowsPaintedGeometry(ctx, fallback)));
        if (okcodeControl) out.addAll(ctx!.paintedTabstripEcho);
        if (keyRound && ctx != null) {
          out.addAll(windowsCursorEcho(ctx, keyCursor));
        }
      } else if (hasOkcode || keyRound) {
        // a MAIN-window key round echoes the PAINTED main 16/12/6 whenever
        // the paint declares one (reference client windows_key_round
        // .main_window_geometry, 1db224f: 518 of 518 corpus key rounds;
        // a recorded session gui[2] F4 `0012 0076 … 0026 010c 01`); the
        // screen size only without one
        final screen = _screenScrollInfos2(screenRows, screenCols);
        out.add(buildApplItem(
            12,
            6,
            keyRound && !modal ? windowsPaintedGeometry(ctx, screen) : screen));
        // every key round carries the container echo ([windowsCursorEcho]
        // gated by the cursor it sends — reference client windows_key_round
        // .key_echo_items, ff1e540: a recorded session gui[20] F15 `16/10/1
        // 16/10/8 16/9/15 ADDR 00 ADDR 00` after the 16/12/6)
        if (keyRound && ctx != null) {
          out.addAll(windowsCursorEcho(ctx, keyCursor));
        }
      } else {
        // the radio shape: the area rows/cols lead where the Java spelling
        // carries the scroll pair
        final v = Uint8List.fromList(it.value);
        v.setRange(0, 8, v.sublist(8, 16));
        out.add(buildApplItem(12, 6, v));
      }
    } else if (it.isAppl && it.id == 5 && it.sid == 1 && it.value.length >= 22) {
      if (fieldRound) {
        // a FIELD submit: the mode byte over zeros — no cursor (it rides
        // the 16/9/11 focus), no area rectangle, no scroll (g15, FBV1
        // gui[10], wide gui[5]/[6]: `00 05 00…`); the round carries its
        // 16/9/11: the cursor half of the acked paint ([windowsOkMode]),
        // the builder's 0x05 / a pushbutton's 0x0d without one
        out.add(buildApplItem(
            5,
            1,
            Uint8List(it.value.length)
              ..[1] = windowsOkMode(ctx, cursor: true, fallback: it.value[1])));
      } else {
        final v = Uint8List.fromList(it.value);
        // the Windows GUI's okcode / key rounds are OK mode 0x05, never
        // the Java 0x0b (gui_launch_17, gui_press_f3_23 `00 05 …`); a
        // control event keeps its own mode (a recorded session gui[13])
        if (!controlEvent && v[1] == 0x0b) v[1] = 0x05;
        for (var k = 6; k < v.length; k++) {
          v[k] = 0; // area rectangle / flags: zero on Windows rounds
        }
        if (okcodeRound || keyBare) {
          // over zeros: 0x0b with the okcode-field / a control focus / no
          // focus (su53 gui[5]/[70], gui[1118], gui[1297], workbench
          // gui[37]), 0x05 from inside a modal (smartforms gui[33])
          v.fillRange(0, v.length, 0);
          // a BARE key with a SAP Graphics control focused ([graphicsFocus]:
          // NetPlanGraphics / BarChartGraphics) is 0x03 — every such
          // main-window key round of the corpus, 5 of 5 (reference client c12bba5;
          // a recorded session); not the control's own
          // %_GC event rounds, not a typed okcode (no capture)
          // With the acked paint's mode known all of these are its control
          // half ([windowsOkMode]: the 16/9/18 / empty 16/9/10 focus slot) —
          // the popup key on a control is 0x03 on a `01` paint and 0x0b on
          // a `09` one (the open discriminator above: alv gui[12], su53
          // gui[201] / [319] / [860] ack `09` paints; f4 raw gui[10] /
          // [15], selection_options_buttons raw gui[30] / [37] `01` ones —
          // reference client 7de3990). A typed okcode in a POPUP is the cursor half
          // when the popup painted a cursor: the real GUI's round names it
          // (smartforms gui[33]: `16/9/11` + 0x05 on srv[36]'s `01`) —
          // GuiGo's spells the okcode-field 16/9/10 (unsettled)
          final fallback = okcodeRound && modal
              ? winOkModePlain
              : keyControl && !okcodeRound && (graphicsFocus || modal)
                  // … and so is a bare key on a control in a POPUP
                  // ([modalKeyControl]: 8 of the corpus' 14 such rounds;
                  // 6 go out 0x0b — a recorded session gui[12], su53
                  // gui[201] / [319] / [860]: the discriminator is open)
                  ? winOkModeModal
                  : winOkModeControlFocus;
          // A round NAMING the control (a key / typed okcode with a
          // control focus — reference client nested_state_round.control_focus_ok_mode,
          // raw_okcode._command_items) takes the cursor half on a paint
          // that itself ended in a 16/9/11 ([windowsControlOkMode])
          v[1] = keyControl || okcodeControl
              ? windowsControlOkMode(ctx, fallback: fallback)
              : windowsOkMode(ctx,
                  cursor: okcodeRound && modal && ctx?.paintedFocus != null,
                  fallback: fallback);
        } else if (keyNested) {
          v.fillRange(0, v.length, 0);
          // raw gui[29] `00 0d 00…`; the cursor half of the acked paint
          v[1] = windowsOkMode(ctx, cursor: true, fallback: winOkModeNested);
        } else if (keyModal) {
          // a popup's key without control state: the plain mode over zeros
          // whatever the cursor depth (stms gui[22] `00 05`) — without a
          // paint mode; with one the cursor half (selection_options_buttons
          // raw gui[39] F12, depth-3 cursor: 0x0d on a `09` paint)
          v.fillRange(0, v.length, 0);
          v[1] = windowsOkMode(ctx, cursor: true, fallback: winOkModePlain);
        } else if (keyRound) {
          // a main-window key with a flat cursor: its cursor half
          v[1] = windowsOkMode(ctx, cursor: true, fallback: v[1]);
        }
        out.add(buildApplItem(5, 1, v));
      }
    } else if ((keyControl || okcodeControl) &&
        it.isAppl &&
        it.id == 9 &&
        it.sid == 10) {
      // the focus slot names the control: no 16/15/1, no 16/9/11
      out.add(buildApplItem(9, 18, wireText(focusShell!)));
    } else if (keyNoFocus && it.isAppl && it.id == 9 && it.sid == 10) {
      out.add(buildApplItem(9, 10, Uint8List(0))); // su53 gui[1297]
    } else if (keyRound && it.isAppl && it.id == 9 && it.sid == 10) {
      // [cursor] = a key aimed AT a field (F4 value help: the target's
      // cell, a recorded session gui[4]); else the painted cursor — both
      // in the client form, the key source carrying its chain
      final focus = keyCursor!;
      final bd = focus.buffer.asByteData(focus.offsetInBytes);
      if (keySelect) {
        out.add(buildApplItem(15, 1, uiEventSelectWindows(focus)));
      } else if (!keyModalBare && !keyNoSource) {
        out.add(buildApplItem(
            15,
            1,
            uiEventFunctionKeyWindows(vkey,
                row: bd.getUint16(1),
                col: bd.getUint16(3),
                modal: (ctx?.modalNo ?? 0) != 0,
                cursor: focus)));
      }
      out.add(buildApplItem(9, 11, focus));
    } else if (fieldRound && it.isAppl && it.id == 9 && it.sid == 11) {
      if (doubleClick) {
        // typed values + a double-click: the field round, in a popup with
        // the SELECT source at the focus (a recorded session
        // gui[224]: `1000` typed into KEY2-LOW of SAPICPS_/0100, then the
        // double-click that opened SAPLALDB/0651 — `02 0001 0001 00000000
        // 0002 0022 0001 00`); on a main window none
        if (modal) {
          out.add(buildApplItem(15, 1, uiEventSelectWindows(it.value)));
        }
      } else if (keyed && vkey != 0 && !hasEventSource) {
        out.add(buildApplItem(
            15, 1, _fieldKeySource(vkey, it.value, controlType: elementKind)));
      }
      out.add(raw);
    } else if (fieldRound &&
        it.isAppl &&
        it.id == 15 &&
        it.sid == 1 &&
        elementKind == 2 &&
        it.value.length >= 5 &&
        it.value[2] == 0x09 &&
        it.value[4] == 0x02) {
      // a radio's element event on Enter (its own fcode): the Windows GUI
      // spells BUTTONPRESSED 0x09 as STATECHANGED 0x0b, bytes otherwise
      // equal (a recorded session g13 / g32
      // `02 000b 0002 …`; the Java se39 gui[21] sends 0x09)
      out.add(buildApplItem(15, 1, Uint8List.fromList(it.value)..[2] = 0x0b));
    } else {
      out.add(raw);
    }
  }
  if (fieldRound) {
    return _withPaintedTabstripSegment(_tabstripStateAfterAtoms(out), ctx);
  }
  if (controlEvent && ctx != null) {
    return windowsControlEventEnvelope(out, ctx);
  }
  return out;
}

/// A main-plane Windows write on a paint declaring a TABSTRIP carries the
/// tabstrip-state segment the Java form never has, synthesized from the
/// paint ([ActionContext.paintedTabstripEcho]) after the atoms, before the
/// 16/15/1 / 16/9/11 tail (reference client raw_fields._painted_tabstrip_segment,
/// 7c4338e §3: g32 `16/10/1 zeros, 16/9/2 | 16/10/1 zeros, 16/10/3, 16/10/8,
/// 16/9/15 42 B | 16/15/1 | 16/9/11`; g13's paint declares none and its
/// round carries none). A round whose routing already moved a tabstrip
/// group after its atoms ([_tabstripStateAfterAtoms]) keeps that one.
List<Uint8List> _withPaintedTabstripSegment(
    List<Uint8List> items, ActionContext? ctx) {
  final echo = ctx?.paintedTabstripEcho ?? const <Uint8List>[];
  if (echo.isEmpty) return items;
  var tailAt = items.length;
  var lastAtom = -1;
  for (var i = 0; i < items.length; i++) {
    final w = walkItems(items[i]).items;
    if (w.length != 1) continue;
    final it = w.single;
    if (it.isAppl && it.id == 9 && it.sid == 15) return items; // has one
    // a NESTED write's planes are its routing's (only a main-plane write
    // takes the paint's segment — reference client 7c4338e §3)
    if (it.isAppl && it.id == 10 && it.sid != 1) return items;
    if (it.isAppl && it.id == 9 && it.sid == 2) lastAtom = i;
  }
  if (lastAtom < 0) return items;
  for (var i = lastAtom + 1; i < items.length; i++) {
    final w = walkItems(items[i]).items;
    if (w.length != 1) continue;
    final it = w.single;
    if ((it.isAppl &&
            ((it.id == 15 && it.sid == 1) || (it.id == 9 && it.sid == 11))) ||
        it.type == itemXmlBlob ||
        it.type == itemEom) {
      tailAt = i;
      break;
    }
  }
  return [...items.sublist(0, tailAt), ...echo, ...items.sublist(tailAt)];
}

/// The Windows 16/15/1 of a function key pressed with the cursor in a
/// field the round writes: flags 0x0a, event 7, control type 1, the key,
/// the focus cell (row / col u16 BE) and the focus container path (u16
/// count + bytes) of the 16/9/11 [focus] — a recorded session gui[5]
/// (F8 on SA38's program field: `0a 0007 0001 08 000000 0000 000d 0001
/// 00`, focus `01 0000 000d 00000014 00`), a recorded session
/// gui[11] (F11: `… 0b 000000 0004 0011 0001 00`); the nested-path form
/// is the reference client's nested_state_round.windows_fkey_event.
Uint8List _fieldKeySource(int vkey, List<int> focus, {int controlType = 1}) {
  final path = focus.length > 9 ? focus.sublist(9) : const [0];
  final out = Uint8List(15 + path.length);
  final bd = out.buffer.asByteData();
  out[0] = 0x0a;
  out[2] = 0x07;
  bd.setUint16(3, controlType); // 1 field, 2 radio (selscreen gui[5])
  out[5] = vkey & 0xff;
  if (focus.length >= 5) {
    out.setRange(9, 13, focus.sublist(1, 5)); // row u16, col u16
  }
  bd.setUint16(13, path.length);
  out.setRange(15, out.length, path);
  return out;
}

/// A Windows field write's tabstrip-STATE groups moved after the atoms
/// (reference client raw_fields._windows_write_items, NESTED): every routing group —
/// a run from a 16/10/1 OPEN to the next OPEN or atom — that carries a
/// 16/9/15 leaves its place before the atom and rides once, in the Windows
/// SHORT form, right before the event-source / focus tail (g15: `10/1 0,
/// 10/3, 10/8, 10/9, page 12/6, 9/2 | 10/1 0, 10/3, 10/8, 9/15 | 9/11`).
/// Every segment of a several-plane round gives its groups up the same
/// way (the reference client reorders the region before the FIRST atom only; the
/// real g32 carries the tabstrip state after the main plane's atoms too).
List<Uint8List> _tabstripStateAfterAtoms(List<Uint8List> items) {
  (int, int, int)? key(Uint8List raw) {
    final w = walkItems(raw).items;
    if (w.length != 1) return null;
    final it = w.single;
    return it.isAppl ? (16, it.id, it.sid) : (it.type, -1, -1);
  }

  final keys = [for (final raw in items) key(raw)];
  final geomAt = keys.indexOf((16, 12, 6));
  if (geomAt < 0) return items;
  var tailAt = items.length;
  for (var i = geomAt + 1; i < items.length; i++) {
    final k = keys[i];
    if (k == (16, 15, 1) ||
        k == (16, 9, 11) ||
        (k != null && (k.$1 == itemXmlBlob || k.$1 == itemEom))) {
      tailAt = i;
      break;
    }
  }
  final kept = <Uint8List>[];
  final moved = <List<Uint8List>>[];
  List<Uint8List>? group;
  void close() {
    final g = group;
    group = null;
    if (g == null) return;
    if (!g.any((raw) => key(raw) == (16, 9, 15))) {
      kept.addAll(g);
    } else if (!moved.any((m) => _sameItems(m, g))) {
      moved.add(g);
    }
  }

  for (var i = geomAt + 1; i < tailAt; i++) {
    final k = keys[i];
    if (k == (16, 10, 1)) {
      close();
      group = [items[i]];
    } else if (k == (16, 9, 2)) {
      close();
      kept.add(items[i]);
    } else if (group != null) {
      group!.add(items[i]);
    } else {
      kept.add(items[i]);
    }
  }
  close();
  if (moved.isEmpty) return items;
  return [
    ...items.sublist(0, geomAt + 1),
    ...kept,
    for (final g in moved)
      for (final raw in g)
        if (key(raw) == (16, 9, 15))
          buildApplItem(
            9,
            15,
            windowsTabstripState(
              Uint8List.fromList(walkItems(raw).items.single.value),
            ),
          )
        else
          raw,
    ...items.sublist(tailAt),
  ];
}

bool _sameItems(List<Uint8List> a, List<Uint8List> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].length != b[i].length) return false;
    for (var j = 0; j < a[i].length; j++) {
      if (a[i][j] != b[i][j]) return false;
    }
  }
  return true;
}

/// The SAP GUI for Windows PICK on a classic list line (an F4 hit list in
/// a popup, a report list): SES `0x50` + the key (F2 = pick) with the
/// window's modal level / position, the identity atoms, the type-9 OK
/// event (the pick mode 0x0d over zeros), the 16/12/8 window pixels, the
/// 16/12/13 list cursor `01 <line u16> <col u16>` and the live metrics XML
/// — no okcode, no 16/15/1, no focus (reference client raw_listpick.list_pick, the
/// Windows branch; its accepted SE38 F4 pick a recorded session
/// _reference_live step 53: `01 0005 0001` = buffer line 5, the hotspot past
/// the frame rail). Windows dialect directly (no re-spelling).
///
/// [writes] = the list INPUT cells typed since the paint (`WRITE … INPUT`,
/// `AS CHECKBOX`), `(line, col, text)` with the text padded to the cell
/// width: one SBA (SBA2 past col / line 255) + 16/12/11 pair per cell
/// BETWEEN the 16/12/8 and the 16/12/13 cursor, the cursor last — the real
/// Windows GUI's commit round (a recorded session gui[12] / [14]:
/// `9 · 16/12/8 · 11 (7,5) · 16/12/11 <"900717" + blanks to 40> ·
/// 16/12/13 01 0007 0005`, SAPfewdp.dll CSapControl::Serialize then
/// Serialize_List_Focus). A null [xml] sends no item 17 (that round has
/// none: the metrics rode the window's first list round).
List<Uint8List> listPickItems(ActionContext ctx, int line, int col,
    {int vkey = 2,
    required Uint8List windowPx,
    required Uint8List? xml,
    List<(int, int, String)> writes = const []}) {
  final ses = Uint8List(16);
  ses[0] = 0x50;
  ses[1] = vkey & 0xff;
  ses[7] = ctx.modalNo & 0xff;
  if (ctx.modalNo != 0) {
    ses[8] = ctx.modalX & 0xff;
    ses[9] = ctx.modalY & 0xff;
  }
  ses[14] = ctx.winPxHeight & 0xff;
  ses[15] = ctx.winPxWidth & 0xff;
  final ok = Uint8List(22)..[1] = 0x0d;
  return [
    stepItem(ctx.step),
    Uint8List.fromList([itemSes, ...ses]),
    buildApplItem(6, 35, winCodepageValue),
    for (final (sid, value) in winIdentity) buildApplItem(4, sid, value),
    Uint8List.fromList([itemChl, ...ok]),
    buildApplItem(12, 8, windowPx),
    for (final (l, c, text) in writes) ...[
      if (l < 256 && c < 256)
        Uint8List.fromList([itemSba, l, c])
      else
        Uint8List.fromList(
            [itemSba2, l >> 8 & 0xff, l & 0xff, c >> 8 & 0xff, c & 0xff]),
      buildApplItem(12, 11, wireText(text)),
    ],
    buildApplItem(12, 13, Uint8List.fromList([
      1, line >> 8 & 0xff, line & 0xff, col >> 8 & 0xff, col & 0xff,
    ])),
    if (xml != null) xmlBlobItem(xml),
    eomBytes,
  ];
}

// --------------------------------------------------------------------------
// The Windows WINDOW-STATE envelope (reference client edfd931 / 52600c6 / ce595f2 /
// 7c4338e): every Windows round derives its OK-event mode, its 16/12/6 and
// its container echo from the window the round goes out of — never from the
// event id or a program name.

/// 16/5/1 mode of a Windows round sent from inside a MODAL popup
/// (a recorded session gui[205] `%_GC 136 2`, su53 gui[22]/[87]/[95]
/// /[226], alv gui[33]: `00 03` over zeros).
const int winOkModeModal = 0x03;

/// 16/5/1 mode with the focus in a FLAT dynpro field (a painted 16/9/11 of
/// depth 1, no table-control flag) on a paint that declares no named
/// container group — su53 gui[271] `%_GC 124 1`, alv gui[53] `%_GC 119 3`,
/// a recorded session gui[119].
const int winOkModePlain = 0x05;

/// 16/5/1 mode with a CFW control holding the focus (the paint's trailing
/// 16/9/18) or no focus at all (a recorded session gui[32]/[37]/[42]
/// /[75]/[82]/[105], su53 gui[5]/[70]/[1118]).
const int winOkModeControlFocus = 0x0b;

/// 16/5/1 mode with a NESTED (depth > 1) or table-control-line (trailing
/// flag byte set) dynpro cursor (alv gui[93] `%_GC 127 7`, su53 gui[372]
/// `%_GC 140 1`), with a flat cursor on a paint that declares a named
/// container group (a recorded session gui[36] — see
/// [windowsWindowStateOkMode]), and of a dynpro pushbutton click
/// (enjoy gui[124]).
const int winOkModeNested = 0x0d;

// --------------------------------------------------------------------------
// The OK-event mode of a client round = the ACKNOWLEDGED paint's own 16/5/1
// mode byte plus the round's focus half (reference client, 4e82af2 /
// 7de3990; complaint-java-okmode-depth1-confirmed+20261012-120300,
// complaint-popup-control-focus-okmode+20261012-125640). The round is
// paired with its paint by the 16/4/38 step; the paint's byte is
// [ActionContext.paintOkMode] (0x08 = the screen holds CFW controls, 0x01
// the server's base bit):
//
// client mode = paint | 0x04 the round's focus is a dynpro cursor
// (16/9/11)
// = paint | 0x02 a CFW control (16/9/18) or no focus (the
// empty 16/9/10)
// SAP GUI for Windows: | 0x01 as well — 01 -> 05 / 03, 09 -> 0d / 0b,
// 00 -> 05, 08 -> 0d / 0b
//
// the reference client's corpus scan (every recording
// with a gui/srv pair): Java 1116 / 1118, Windows 1971 / 2028 — its cursor
// rounds 945 / 947 (the former depth / table-line inference 786 / 947), the
// popup control rounds 80 x (01 -> 03) and 171 x (09 -> 0b); Windows
// 2018 / 2028 with the cursor-paint refinement ([windowsControlOkMode]: a
// 16/9/18 round on a paint that itself ended in a 16/9/11 takes the cursor
// half; reference client 5025506 — Java keeps the plain rule). GuiGo's own fixtures:
// ok_mode_corpus_test.dart (Windows 187 / 187 refined). The former constants
// ([winOkModeModal], [winOkModePlain], [winOkModeControlFocus],
// [winOkModeNested]) are each builder's FALLBACK, used only while no paint
// mode is known.

/// The client OK mode a round acknowledging a paint of mode [paint] goes
/// out with: [paint] | 0x04 when the round's focus is a dynpro [cursor]
/// (16/9/11), else | 0x02 (a 16/9/18 control focus or none); the SAP GUI
/// for [windows] always sets the base bit 0x01 too.
int okModeOfPaint(int paint, {required bool cursor, required bool windows}) =>
    (paint & 0xff) | (windows ? 0x01 : 0) | (cursor ? 0x04 : 0x02);

/// THE Windows OK-mode decision: a round whose focus half is a dynpro
/// [cursor] (16/9/11) or not (16/9/18 / the empty 16/9/10 / none) goes out
/// [okModeOfPaint] of the acknowledged paint ([ActionContext.paintOkMode]);
/// [fallback] (the builder's former constant) when no paint is known. Every
/// Windows builder decides its 16/5/1 byte 1 through here at the point it
/// decides its focus item.
int windowsOkMode(ActionContext? ctx,
    {required bool cursor, required int fallback}) {
  final paint = ctx?.paintOkMode;
  return paint == null
      ? fallback
      : okModeOfPaint(paint, cursor: cursor, windows: true);
}

/// The Windows OK mode of a round whose focus slot names a CFW control
/// (16/9/18) or none (the empty 16/9/10) on the reference client's control-mode paths
/// (engine/ok_mode.win_control_mode — the generic control event outside a
/// popup, a key / typed okcode / menu round with a control focus): the
/// acked paint's control half ([windowsOkMode], `cursor: false`) — EXCEPT
/// when that paint's own last focus item is a dynpro cursor
/// ([ActionContext.paintCursorFocus]): then the CURSOR half (paint | 0x01 |
/// 0x04 — the Windows GUI keeps the cursor's mode bit while it names the
/// control; reference client 5025506, complaint-okmode-control-event-cursor-paint
/// +20261012-133909: 47 x 09 -> 0d — a recorded session gui[36],
/// a recorded session gui[7], a recorded session gui[14],
/// a recorded session gui[23] / [79] … — and a recorded session
/// gui[53] 01 -> 05). [cursorPaint] false keeps the control half: the MODAL
/// popup's generic control event and the popup pushbutton (su53 gui[87] /
/// [205], gui[867] `=OPT2` stay 0x0b on a cursor paint). Windows only —
/// the Java GUI names its focus faithfully ([javaOkMode]).
int windowsControlOkMode(ActionContext? ctx,
        {required int fallback, bool cursorPaint = true}) =>
    windowsOkMode(ctx,
        cursor: cursorPaint && (ctx?.paintCursorFocus ?? false),
        fallback: fallback);

/// The SAP GUI for JAVA twin of [windowsOkMode]: the acknowledged paint's
/// mode | 0x04 with a 16/9/11, else | 0x02 — no base bit (paint 01 -> 05 /
/// 03, 09 -> 0d / 0b, 00 -> 04, 08 -> 0c / 0a; a recorded session
/// kept gui[11] / [14] / [16]); [fallback] without a paint.
int javaOkMode(ActionContext? ctx,
    {required bool cursor, required int fallback}) {
  final paint = ctx?.paintOkMode;
  return paint == null
      ? fallback
      : okModeOfPaint(paint, cursor: cursor, windows: false);
}

/// A Java-dialect round's [items] with its 16/5/1 mode byte decided by
/// [javaOkMode] from the focus item the round finally carries (a 16/9/11
/// = the cursor half; a 16/9/18 / 16/9/10 / none = the control half) — the
/// Java builders (actions.dart) speak one spelling for both dialects, so the
/// Java rule is applied where the round is complete (SapSession, Java
/// dialect only; the Windows re-spelling decides its own). Without a paint
/// mode the items are returned untouched.
List<Uint8List> withJavaOkMode(List<Uint8List> items, ActionContext ctx) {
  if (ctx.paintOkMode == null) return items;
  var cursor = false;
  int? okAt;
  for (var i = 0; i < items.length; i++) {
    final w = walkItems(items[i]).items;
    if (w.length != 1) continue;
    final it = w.single;
    if (!it.isAppl) continue;
    if (it.id == 9 && it.sid == 11) cursor = true;
    if (it.id == 5 && it.sid == 1 && it.value.length >= 2) okAt ??= i;
  }
  if (okAt == null) return items;
  final v = Uint8List.fromList(walkItems(items[okAt]).items.single.value);
  final mode = javaOkMode(ctx, cursor: cursor, fallback: v[1]);
  if (mode == v[1]) return items;
  v[1] = mode;
  return [...items]..[okAt] = buildApplItem(5, 1, v);
}

bool _isModal(ActionContext? ctx) => (ctx?.modalNo ?? 0) != 0;

/// Whether the 16/9/11 [cursor] names a cursor inside a container chain
/// (depth byte > 1) or on a table-control line (its last byte set) — the
/// reference client's _dynpro_cursor_is_nested.
bool windowsCursorIsNested(List<int>? cursor) =>
    cursor != null &&
    cursor.isNotEmpty &&
    (cursor[0] > 1 || (cursor.length >= 10 && cursor[9] != 0));

/// The OK-event mode of a generic Windows control-event round (`%_GC` /
/// `%_GS`) and of every other round that derives it from the WINDOW STATE
/// (reference client windows_control_event_round.generic_event_ok_mode): a modal
/// popup → [winOkModeModal]; a CFW control focus
/// ([ActionContext.paintedControlFocus]) or no focus at all →
/// [winOkModeControlFocus]; a nested / table-control-line cursor, or a flat
/// one on a paint declaring a named container → [winOkModeNested]; any
/// other flat painted cursor → [winOkModePlain].
///
/// "A control focus" is the paint's LAST focus item being a non-dialog
/// 16/9/18 (the mirror clears it on a later 16/9/11 / 16/9/10). The cursor
/// is the screen's CURRENT one ([ActionContext.paintedFocus]): the latest
/// paint that declared a focus, or the cursor the client placed since (F1 on
/// a field), kept across a focus-less repaint — reference client 867e1d7 §4,
/// client_focus.observe_frame / windows_control_event_round
/// .dynpro_cursor_focus (a recorded session gui[119]: OK 0x05 + the
/// F1's cursor after srv[134] painted only the dialog's 16/9/18).
///
/// A FLAT cursor is [winOkModeNested] too when the paint declares a NAMED
/// container group ([ActionContext.paintedNamedContainer], a 16/10/6) —
/// keyed on the paint, never on the event (reference client 534a50c,
/// paint_declares_named_container; its corpus scan of every Windows
/// `%_GC` / `%_GS` round on a main window whose step-paired paint ends in a
/// flat 16/9/11: 45 of 45 on a paint with a 16/10/6 went out 0x0d —
/// a recorded session gui[36] `%_GC 154 36` on srv[46],
/// a recorded session gui[26], a recorded session gui[12],
/// a recorded session gui[12] `%_GC 122 26` on srv[19], the
/// st04_custom_dialog / wda_* pushbuttons; the 0x05 rounds go out on a
/// paint without one: a recorded session gui[53] `%_GC 119 3` on srv[73],
/// a recorded session gui[271] `%_GC 124 1` on srv[320]).
///
/// With the acknowledged paint's mode known ([ActionContext.paintOkMode])
/// the window state only picks the focus HALF and [windowsOkMode] decides
/// (reference client windows_control_event_round.generic_event_ok_mode, 4e82af2 /
/// 7de3990): a popup, a control focus or no focus = the control half
/// (paint | 0x03), a dynpro cursor = the cursor half (paint | 0x05) — the
/// constants above are the no-paint fallback. The cursor half holds whatever
/// focus item the event round names: alv gui[53] `%_GC 119 3` carries
/// `16/9/18 "119"` on srv[73]'s `01` paint with a painted 16/9/11 and goes
/// out 0x05; the named-container 0x0d rounds (dwdm gui[36], sfp_painters
/// gui[12]) are `09` paints — 09 | 0x05 (ok_mode_corpus_test.dart). A
/// control focus or no focus outside a popup is [windowsControlOkMode]: the
/// cursor half too when the acked paint itself ended in a 16/9/11.
int windowsWindowStateOkMode(ActionContext ctx) {
  if (ctx.modalNo != 0) {
    // a MODAL popup keeps the control half on a cursor paint
    // ([windowsControlOkMode] `cursorPaint: false` — su53 gui[87] / [205])
    return windowsControlOkMode(ctx,
        fallback: winOkModeModal, cursorPaint: false);
  }
  if (ctx.paintedControlFocus != null) {
    return windowsControlOkMode(ctx, fallback: winOkModeControlFocus);
  }
  final c = ctx.paintedFocus;
  if (c == null) {
    return windowsControlOkMode(ctx, fallback: winOkModeControlFocus);
  }
  return windowsOkMode(ctx,
      cursor: true,
      fallback: windowsCursorIsNested(c) || ctx.paintedNamedContainer
          ? winOkModeNested
          : winOkModePlain);
}

/// The modal nesting level a Windows round goes out of: the SES's
/// [ActionContext.modalNo] or the popups the paint declares
/// ([ActionContext.paintedModalLevel]), whichever is larger (reference client
/// windows_control_event_round.modal_level). 0 on a main window.
int windowsModalLevel(ActionContext ctx) =>
    ctx.modalNo > ctx.paintedModalLevel ? ctx.modalNo : ctx.paintedModalLevel;

/// Whether the active popup is the 1-row x 1-col window the kernel opens
/// only to HOST a CFW dialog control (the SAP.TABControl.1 value help, the
/// F4 hit list): its painted main 16/12/6 ([geometry], else
/// [ActionContext.paintedGeometry]) is `00000001 00000001 …` —
/// a recorded session srv[19] / [26] / [60] (SAPLWDTM/0100), a recorded session
/// f4_prefilled; a real dynpro popup paints its own rows x cols
/// (a recorded session srv[215] `0002 0059`, a recorded session
/// gui[25] `0002 0059`). reference client windows_control_event_round
/// .is_control_host_popup.
bool windowsIsControlHostPopup(ActionContext ctx, {List<int>? geometry}) {
  final g = geometry ?? ctx.paintedGeometry;
  if (g == null || g.length < 8) return false;
  final bd = ByteData.sublistView(Uint8List.fromList(g.sublist(0, 8)));
  return bd.getUint32(0) == 1 && bd.getUint32(4) == 1;
}

/// The SES DIM bytes of a Windows round sent from inside a POPUP: the low
/// bytes of the popup's own pixel size, rows x 22 + 7 high and cols x 7
/// wide (the kernel cell, [ActionContext.kernelCell]) of the rows / cols
/// its painted 16/12/6 ends with ([ActionContext.paintedTopWindowGeometry]
/// — the server's popup SES dims): a recorded session raw gui[8] /
/// [10] / [18] (27 x 86 `59 5a`, 12 x 22 `0f 9a`, 18 x 70 `93 ea`),
/// a recorded session raw gui[10] (12 x 42 `0f 26`),
/// a recorded session raw gui[10] (4 x 46 `5f 42`),
/// a recorded session raw gui[30] / [39] / [40] —
/// 272 of the corpus' 300 Windows popup rounds carrying a 16/12/6 (8 more
/// match the height only, popups holding a list or a scrolled table
/// control; 20 are the 1 x 1 CONTROL-HOST popup, [windowsIsControlHostPopup],
/// which keeps the window's pair). Null on a main window and when no popup
/// geometry is known.
(int, int)? windowsModalSesDims(ActionContext ctx) {
  if (ctx.modalNo == 0) return null;
  final g = ctx.paintedTopWindowGeometry ?? ctx.paintedGeometry;
  if (g == null || g.length < 32) return null;
  if (windowsIsControlHostPopup(ctx, geometry: g)) return null;
  final bd = ByteData.sublistView(Uint8List.fromList(g));
  final rows = bd.getUint32(24), cols = bd.getUint32(28);
  final cell = ctx.kernelCell;
  return ((rows * cell.height + 7) & 0xff, (cols * cell.width) & 0xff);
}

/// Whether a MODAL control-event round carries the 16/4/36 window rect
/// right after the okcode (reference client 867e1d7 §1, windows_control_event_round
/// .modal_window_rect_owed — scanned over the corpus' 103 Windows modal
/// control events):
///
/// * a real dynpro popup → the rect (a recorded session gui[205],
/// a recorded session gui[25] / [33], a recorded session
/// gui[64]: `0000 0409 0000 0781` — 25 frames);
/// * the 1 x 1 CONTROL-HOST popup ([windowsIsControlHostPopup]) at modal
/// level 1 → NONE (a recorded session gui[13] / [20] / [51], f4_prefilled
/// x6, su53 gui[656] / [667] / [702] / [709], swdd, mime — 23 frames);
/// * that host popup nested over another popup (level >= 2,
/// [windowsModalLevel]) → a rect is owed (su53 gui[22], alv gui[33],
/// a recorded session gui[48]); its VALUE there is `0000 0419 0000
/// 0f01`, not the main window's — unsettled, [windowsWindowRect] is sent.
///
/// Unsettled, not guessed: the FIRST host popup of a logon carries that
/// `0419 0f01` rect too (a recorded session gui[19],
/// a recorded session gui[340]); a recorded session
/// gui[24] (a second event on a repaint of a real popup) carries none; some
/// clients never send a 16/4/36 at all (me51n_f4, mime, sfp_painters, the
/// radio captures — not even after the logon). [geometry] = the 16/12/6
/// the round echoes when it is not [ActionContext.paintedGeometry].
bool windowsModalWindowRectOwed(ActionContext ctx, {List<int>? geometry}) {
  if (!_isModal(ctx)) return false;
  return !(windowsIsControlHostPopup(ctx, geometry: geometry) &&
      windowsModalLevel(ctx) <= 1);
}

/// The 16/12/6 a Windows round echoes: the active window's PAINTED main
/// geometry ([ActionContext.paintedGeometry], the popup's own in a modal),
/// else [fallback].
Uint8List windowsPaintedGeometry(ActionContext? ctx, Uint8List fallback) =>
    ctx?.paintedGeometry != null
        ? Uint8List.fromList(ctx!.paintedGeometry!)
        : fallback;

/// The choose key (F2 — a double-click): its bare main-window round carries
/// no 16/15/1 ([windowsActionItems]; reference client windows_key_round._CHOOSE_VKEY).
const int _chooseVkey = 2;

const _routingSids = {1, 3, 5, 8, 9, 10, 13, 14};
const int _termTabstrip = 8, _termSplitter = 13, _termTc = 5, _sidPage = 9;
const int _treeNamesEntriesAt = 32 + 30 + 1; // prefix + 30-char name + NUL

/// One tab button of an 18/9/16 TABSTRIP PAGES descriptor
/// ([tabstripDescriptorPages]): its page [name] (`ATTRIBUTE`), function
/// code ([fcode], `=ATTRIBUTE`) and whether the paint DISPLAYS that page
/// ([active], the record's flag 0x40).
typedef TabstripPage = ({List<int> name, List<int> fcode, bool active});

// the 18/9/16 record layout (reference client diag_controlstate.TABPAGES_*)
const int _tabPagesFlagsAt = 2, _tabPagesActiveFlag = 0x40;
const int _tabPagesTypeAt = 4, _tabPagesTypeTab = 0x74, _tabPagesOffsAt = 16;

/// The tab buttons of an 18/9/16 TABSTRIP PAGES descriptor [vb], in paint
/// order (reference client diag_controlstate.tabstrip_descriptor_pages, ff1e540): a
/// run of records, each `u16 BE length` (the record's own size, the length
/// word included), a flags byte at [2] (0x40 = the page the paint DISPLAYS;
/// its 0x72 area record repeats the flag), the record type at [4] (0x74 = a
/// tab button, 0x72 = the page's subscreen area) and — on a tab button —
/// three u16 BE offsets into the record at [16:22]: the function code, the
/// tab text and the tab NAME, each NUL-terminated (a recorded session
/// srv[34] GS_SYSTEMATTRIBUTES: `0048 40 00 74 … 0033 0016 003e` =
/// `=ATTRIBUTE`, `Attributs système`, `ATTRIBUTE`). A record that does not
/// parse as a tab button is skipped; a value that is no record run (a
/// synthetic / truncated descriptor) gives the records read so far.
List<TabstripPage> tabstripDescriptorPages(List<int> vb) {
  final out = <TabstripPage>[];
  var i = 0;
  while (i + 2 <= vb.length) {
    final n = vb[i] << 8 | vb[i + 1];
    if (n < 3 || i + n > vb.length) break;
    final rec = vb.sublist(i, i + n);
    i += n;
    if (rec.length < _tabPagesOffsAt + 6 ||
        rec[_tabPagesTypeAt] != _tabPagesTypeTab) {
      continue;
    }
    List<int>? str(int k) {
      final at = _tabPagesOffsAt + 2 * k;
      final o = rec[at] << 8 | rec[at + 1];
      if (o < _tabPagesOffsAt + 6 || o >= rec.length) return null;
      final end = rec.indexOf(0, o);
      return end < 0 ? null : rec.sublist(o, end);
    }

    final name = str(2);
    if (name == null || name.isEmpty) continue;
    out.add((
      name: name,
      fcode: str(0) ?? const [],
      active: rec[_tabPagesFlagsAt] & _tabPagesActiveFlag != 0,
    ));
  }
  return out;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The client 16/9/15 for a tabstrip (reference client mode_envelope
/// .client_tree_names): the server's 18/9/15 with the ACTIVE page's name
/// filled into an empty first entry (the page leg's index, byte 4, into the
/// page names of the 18/9/16 [pages] descriptor — its tab-button records'
/// own names, [tabstripDescriptorPages]; the identifier-token scan only for
/// a descriptor that does not parse as records: it also matched the pages'
/// subscreen-area names, `SYSTEMATTRIBUTES` on a recorded session srv[34],
/// and shifted the index — reference client ff1e540), its [30:32] length grown by
/// that name; verbatim when the first entry is named or the page cannot be
/// named.
Uint8List clientTreeNames(Uint8List b, Uint8List pages, Uint8List pageLeg) {
  if (b.length <= _treeNamesEntriesAt || b[_treeNamesEntriesAt] != 0) return b;
  final names = <String>[
    for (final p in tabstripDescriptorPages(pages)) String.fromCharCodes(p.name),
  ];
  if (names.isEmpty) {
    for (final m in RegExp(r'([A-Z_][A-Z0-9_]{2,})\x00')
        .allMatches(String.fromCharCodes(pages))) {
      if (!names.contains(m.group(1))) names.add(m.group(1)!);
    }
  }
  final idx = pageLeg.length > 4 ? pageLeg[4] : 0;
  if (names.isEmpty || idx < 1 || idx > names.length) return b;
  final active = names[idx - 1].codeUnits;
  var rest = b.sublist(_treeNamesEntriesAt);
  if (rest.length >= 2 &&
      rest[0] == 0 &&
      rest[1] == 0 &&
      (rest.length < 3 || rest[2] == 0)) {
    rest = Uint8List.fromList([0, ...active, 0, ...rest.sublist(2)]);
  }
  final out = Uint8List.fromList(
      [...b.sublist(0, _treeNamesEntriesAt), ...active, ...rest]);
  final len = (b[30] << 8 | b[31]) + active.length;
  out[30] = len >> 8 & 0xff;
  out[31] = len & 0xff;
  return out;
}

/// The SAP GUI for WINDOWS 16/9/15 of a container ECHO from the painted
/// 18/9/15 [b] (reference client mode_envelope.windows_page_tree_names, ff1e540): the
/// page NAMES are the 18/9/16 [pages] descriptor's tab-button records'
/// ([tabstripDescriptorPages]) —
///
/// * an EMPTY painted first entry = the strip's FIRST page;
/// * the second entry = the painted one when it names a page of the strip,
/// else the page the descriptor flags as displayed (0x40), else the
/// first entry;
///
/// then the Windows short form ([windowsTreeNames]). a recorded session
/// srv[34] paints `00 ATTRIBUTES 00` (the GS_SYSTEMATTRIBUTES subscreen
/// area's name, no page of the strip) over pages ATTRIBUTE (displayed) /
/// LAYER / IMPTARGETS -> gui[22] `ATTRIBUTE 00 ATTRIBUTE 00`;
/// a recorded session srv[193] `00 DEF 00` over HEAD / DEF
/// (displayed) / F4V / REFF -> gui[156] `HEAD 00 DEF 00`. reference client corpus
/// (every Windows 16/9/15 echo whose paint is in the capture): 419 of 435
/// fit; the 16 that do not carry a painted non-empty first entry or a
/// SCROLLED strip — a recorded session g32 `0600`
/// (g14 `0530`) where this gives the strip's first page `0580`: the first
/// VISIBLE tab, a client tab-scroll state no wire item carries
/// (unsettled). A descriptor naming no page and a paint naming none fall
/// back to the page-leg index ([clientTreeNames]).
Uint8List windowsPageTreeNames(Uint8List b, Uint8List pages, Uint8List pageLeg) {
  if (b.length < _treeNamesEntriesAt) return windowsTreeNames(b);
  final entries = b.sublist(_treeNamesEntriesAt);
  int nul(int from) {
    final i = entries.indexOf(0, from);
    return i < 0 ? entries.length : i;
  }

  List<int> first = entries.sublist(0, nul(0));
  final secondAt = first.length + 1;
  List<int> second = secondAt <= entries.length
      ? entries.sublist(secondAt, nul(secondAt))
      : const <int>[];
  final strip = tabstripDescriptorPages(pages);
  final names = [for (final p in strip) p.name];
  final shown = strip.where((p) => p.active).map((p) => p.name).firstOrNull;
  if (first.isEmpty && second.isEmpty && names.isEmpty) {
    return windowsTreeNames(clientTreeNames(b, pages, pageLeg));
  }
  if (second.isNotEmpty &&
      names.isNotEmpty &&
      !names.any((n) => _sameBytes(n, second))) {
    second = const [];
  }
  if (first.isEmpty) first = names.isNotEmpty ? names.first : second;
  if (second.isEmpty) second = shown ?? first;
  return windowsTreeNames(Uint8List.fromList([
    ...b.sublist(0, _treeNamesEntriesAt),
    ...first,
    0,
    ...second,
    0,
  ]));
}

/// The SAP GUI for WINDOWS 16/9/15 for a tabstrip from the client form
/// [clientTreeNames] (reference client mode_envelope.windows_tree_names): the [0:16]
/// geometry words, [16:28] zero, [28:30] = the server's [26:28] word,
/// [30:32] = 32 + the first entry's length + its NUL, then the entries
/// without the 30-char name — an EMPTY first entry filled with the second
/// (a recorded session gui[124] `… 0020 0028 TABHDT1 00 TABHDT8 00`).
Uint8List windowsTreeNames(Uint8List b) {
  if (b.length < _treeNamesEntriesAt) return b;
  var entries = b.sublist(_treeNamesEntriesAt);
  int nul(List<int> v, int from) {
    final i = v.indexOf(0, from);
    return i < 0 ? v.length : i;
  }

  var first = entries.sublist(0, nul(entries, 0));
  if (first.isEmpty && entries.length > 1) {
    final second = entries.sublist(1, nul(entries, 1));
    if (second.isNotEmpty) {
      first = second;
      entries = Uint8List.fromList([...second, ...entries]);
    }
  }
  final len = 32 + first.length + 1;
  return Uint8List.fromList([
    ...b.sublist(0, 16),
    ...Uint8List(12),
    b[26],
    b[27],
    len >> 8 & 0xff,
    len & 0xff,
    ...entries,
  ]);
}

/// The Windows client 16/9/14 echo of a painted 18/9/14 TABLE_HEADER: its
/// 60-byte prefix with only [2:17], [19:22], [31:42] kept (reference client
/// raw_tc_geometry._tc_windows_table_header). Null below 60 bytes.
Uint8List? _windowsTableHeader(List<int> h) {
  const n = 60;
  if (h.length < n) return null;
  final out = Uint8List(n)..[1] = n;
  for (final (a, b) in const [(2, 17), (19, 22), (31, 42)]) {
    out.setRange(a, b, h.sublist(a, b));
  }
  return out;
}

/// The SAP GUI for WINDOWS container echo of a paint's TOP-window [items]
/// (reference client mode_envelope.dynpro_echo_tuples windows=True + windows_control_
/// event_round.tabstrip_echo_tuples), as item bytes:
///
/// * groups split at each 16/10/1; a group is echoed when its routing
/// (16/10 sids 1 3 5 8 9 10 13 14) ends in a TABSTRIP (16/10/8) or a
/// TABLE CONTROL (16/10/5); a group routed through a SPLITTER leg
/// (16/10/13) contributes nothing (a recorded session
/// gui[40]);
/// * a table-control group rides only while the round's cursor lies in
/// that control — the caller gates it ([windowsCursorInTable] over
/// `tables`): under a tabstrip PAGE leg too (su53 gui[156] echoes
/// SU53's page TC with the cursor on it, gui[893] not PA20's, the
/// cursor elsewhere);
/// * each echoed group = its routing legs as painted (the root OPEN all
/// zero) and its 16/12/6 items, then the descriptor: a tabstrip's
/// 18/9/15 as the Windows short 16/9/15 ([windowsPageTreeNames]), a
/// table control's 60-byte 16/9/14 and its
/// 18/12/2 as 16/12/2;
/// * the table-control groups ride FIRST whatever the paint order
/// (a recorded session gui[124]/[126]);
/// * then the tabstrips NESTED in another strip's page (their routing
/// runs through a 16/10/9 page leg), then the top-level strips — the
/// outer strip is painted first, the GUI echoes the inner one first
/// (reference client aee5865, complaint-windows-key-round-residuals+20261011-
/// 150000 §2: 12 of the 12 Windows rounds of the corpus echoing both
/// kinds, none after — a recorded session gui[41] on srv[42],
/// a recorded session gui[248] on srv[302], a recorded session
/// workbench gui[173]; combobox_su3 gui[12] and subscreen_radio_
/// sameplane gui[15] are atom segments of the write path, not echo).
///
/// `tables` = the table-control groups with their container paths (a
/// pushbutton round echoes those holding its cursor), `tabstrip` = the
/// tabstrip groups (echoed whatever the cursor), `all` = both, ungated.
({
  List<Uint8List> all,
  List<Uint8List> tabstrip,
  List<WindowsTableEcho> tables,
}) windowsPaintEcho(List<DiagItem> items) {
  final groups = <List<DiagItem>>[];
  for (final it in items) {
    if (it.type == itemAppl && it.id == 10 && it.sid == 1) {
      groups.add([it]);
    } else if (groups.isNotEmpty) {
      groups.last.add(it);
    }
  }
  bool is16(DiagItem it, int id, int sid) =>
      it.type == itemAppl && it.id == id && it.sid == sid;
  bool is18(DiagItem it, int id, int sid) =>
      it.type == itemAppl4 && it.id == id && it.sid == sid;
  final tc = <WindowsTableEcho>[];
  final pageTabs = <Uint8List>[]; // tabstrips nested in a page: first
  final tabs = <Uint8List>[];
  for (var gi = 0; gi < groups.length; gi++) {
    final grp = groups[gi];
    final routing = [
      for (final it in grp)
        if (it.type == itemAppl && it.id == 10 && _routingSids.contains(it.sid))
          it,
    ];
    if (routing.isEmpty) continue;
    if (routing.any((it) => it.sid == _termSplitter)) continue;
    final term = routing.last.sid;
    if (term != _termTabstrip && term != _termTc) continue;
    final body = <Uint8List>[
      for (final it in grp)
        if ((it.type == itemAppl &&
                it.id == 10 &&
                _routingSids.contains(it.sid)) ||
            is16(it, 12, 6))
          buildApplItem(it.id, it.sid, Uint8List.fromList(it.value)),
    ];
    if (term == _termTabstrip) {
      final tn = grp.where((it) => is18(it, 9, 15)).firstOrNull;
      if (tn != null) {
        final pages = grp.where((it) => is18(it, 9, 16)).firstOrNull;
        Uint8List? pageLeg;
        for (final g2 in groups.skip(gi + 1)) {
          pageLeg ??= g2
              .where((it) => is16(it, 10, _sidPage))
              .map((it) => Uint8List.fromList(it.value))
              .firstOrNull;
        }
        // the page names from the 18/9/16 tab-button records
        // ([windowsPageTreeNames], reference client ff1e540: stms srv[34] ->
        // gui[22] `ATTRIBUTE 00 ATTRIBUTE 00`, su53 srv[193] -> gui[156]
        // `HEAD 00 DEF 00`)
        body.add(buildApplItem(
            9,
            15,
            windowsPageTreeNames(
                Uint8List.fromList(tn.value),
                Uint8List.fromList(pages?.value ?? const []),
                pageLeg ?? Uint8List(0))));
      }
      (routing.any((it) => it.sid == _sidPage) ? pageTabs : tabs)
          .addAll(body);
    } else {
      final header = grp.where((it) => is18(it, 9, 14)).firstOrNull;
      final win = header == null ? null : _windowsTableHeader(header.value);
      if (win == null) continue; // no 60-byte header to echo
      body.add(buildApplItem(9, 14, win));
      final area = grp.where((it) => is18(it, 12, 2)).firstOrNull;
      if (area != null) {
        body.add(buildApplItem(12, 2, Uint8List.fromList(area.value)));
      }
      tc.add((path: windowsChainLevels(routing), items: body));
    }
  }
  return (
    all: [for (final t in tc) ...t.items, ...pageTabs, ...tabs],
    tabstrip: [...pageTabs, ...tabs],
    tables: tc,
  );
}

/// The level bytes of a container chain's [routing] legs — every non-root
/// leg (DESC 16/10/3, CLOSE 16/10/8, PAGE 16/10/9, the terminal 16/10/4 /
/// 16/10/5) with a nonzero level, in paint order: the path a cursor INSIDE
/// that container starts with (reference client nested_state_round.chain_levels, the
/// table-control echo gate of 0f19cd8); a splitter cell's 16/10/14 and the
/// container leg 16/10/10 count no level there.
List<int> windowsChainLevels(Iterable<DiagItem> routing) => [
      for (final it in routing)
        if (const {3, 4, 5, 8, 9}.contains(it.sid) &&
            it.value.isNotEmpty &&
            it.value[0] != 0)
          it.value[0],
    ];

/// The 16/9/11 cursor as the CLIENT sends it back: the server paints a
/// nested focus as its container chain + the field's area, `… 01 01 02
/// 00`; the real GUI drops a trailing zero level (depth − 1) and keeps a
/// flat depth-1 `00` — srv `04 0000 0000 00000000 01 01 02 00` (ME21N's
/// SUPERFIELD) -> `03 … 01 01 02` (a recorded session
/// gui[10] / gui[23]); su53 srv[849] `0b … 01 01 01 00` -> gui[735] `0a …
/// 01 01 01`; srv[1039] `02 … 01 00` -> gui[886] `01 … 01` (reference client
/// raw_fields._nested_write_spec: "every nested focus of every capture,
/// no counter-example"). A cursor whose length does not match its depth
/// is returned as is.
Uint8List windowsClientCursor(List<int> cursor) {
  final depth = cursor.isEmpty ? 0 : cursor[0];
  if (depth > 1 && cursor.length == 9 + depth && cursor.last == 0) {
    return Uint8List.fromList(cursor.sublist(0, cursor.length - 1))
      ..[0] = depth - 1;
  }
  return Uint8List.fromList(cursor);
}

/// Whether the (client-form, [windowsClientCursor]) 16/9/11 [cursor]
/// lies inside the table control at [tablePath]: its container path
/// (`[depth][row][col][offset u32][path]`) starts with the control's.
/// The SAP GUI for Windows echoes a table control's state only then —
/// over the corpus' Windows rounds on a painted TC: a recorded session
/// enjoy gui[124]/[126] (cursor `01 03 02 01 01` = TC_1211's chain:
/// echoed), a recorded session gui[23] (`01 01 02`, the
/// header: none), su53 gui[723]/[733] vs [735]/[736] (the same ME21N,
/// cursor on TC_1211 vs in the item detail), gui[156]/[186]/[580] (a TC
/// under a tabstrip page, cursor on it: echoed) vs gui[893]/[696] (cursor
/// elsewhere: none), a recorded session gui[67] vs gui[86].
bool windowsCursorInTable(List<int>? cursor, List<int> tablePath) {
  if (cursor == null || cursor.length < 9 || tablePath.isEmpty) return false;
  final depth = cursor[0];
  if (cursor.length < 9 + depth || depth < tablePath.length) return false;
  for (var i = 0; i < tablePath.length; i++) {
    if (cursor[9 + i] != tablePath[i]) return false;
  }
  return true;
}

/// The generic SAP GUI for WINDOWS control-event envelope (reference client
/// windows_control_event_round.reshape_generic_event_items, edfd931) laid
/// over a control-event round's [items] (already in the Windows dialect):
///
/// * 16/5/1 = the window-state mode over zeros ([windowsWindowStateOkMode],
/// or [okMode] when the caller knows better);
/// * the first 16/12/6 = the PAINTED geometry ([windowsPaintedGeometry];
/// the popup's own in a modal), followed by the paint's TABSTRIP echo
/// ([ActionContext.paintedTabstripEcho]: gui[75]/[82] on SE37's tab page;
/// nothing on a flat dynpro, gui[32]/[33]);
/// * on a main window 16/12/8 kept; in a MODAL no 16/12/8 (nor 16/12/14)
/// and the 16/4/36 window rect right after the okcode (gui[205]) — when
/// [windowsModalWindowRectOwed]: none on the level-1 1 x 1 popup that
/// only hosts a CFW dialog (a recorded session gui[13] / [20] / [51]).
List<Uint8List> windowsControlEventEnvelope(
    List<Uint8List> items, ActionContext ctx,
    {int? okMode}) {
  final modal = _isModal(ctx);
  final rectOwed = windowsModalWindowRectOwed(ctx);
  // the window state picks the focus half, the acked paint the mode
  final mode = okMode ?? windowsWindowStateOkMode(ctx);
  final out = <Uint8List>[];
  var geomDone = false;
  for (final raw in items) {
    final w = walkItems(raw).items;
    final it = w.length == 1 ? w.single : null;
    if (it == null || !it.isAppl) {
      out.add(raw);
    } else if (it.id == 5 && it.sid == 1) {
      out.add(buildApplItem(5, 1, Uint8List(it.value.length)..[1] = mode));
    } else if (it.id == 12 && it.sid == 4) {
      out.add(raw);
      if (rectOwed) out.add(buildApplItem(4, 36, windowsWindowRect(ctx)));
    } else if (it.id == 4 && it.sid == 36) {
      // re-placed after the okcode when owed; none on a main window
    } else if (it.id == 12 && (it.sid == 8 || it.sid == 14)) {
      if (!modal) out.add(buildApplItem(12, 8, Uint8List.fromList(it.value)));
    } else if (it.id == 12 && it.sid == 6 && !geomDone) {
      geomDone = true;
      out.add(buildApplItem(
          12, 6, windowsPaintedGeometry(ctx, Uint8List.fromList(it.value))));
      out.addAll(ctx.paintedTabstripEcho);
    } else {
      out.add(raw);
    }
  }
  return out;
}

Uint8List _winPxValue(ActionContext ctx) =>
    ctx.windowAreaPx(ctx.winPxHeight, ctx.winPxWidth);

Uint8List _winSesItem(ActionContext ctx, {int eventArray = 0, int vkey = 0}) {
  final ses = Uint8List(16);
  ses[0] = eventArray;
  ses[1] = vkey & 0xff;
  ses[7] = ctx.modalNo & 0xff;
  if (ctx.modalNo != 0) {
    ses[8] = ctx.modalX & 0xff;
    ses[9] = ctx.modalY & 0xff;
  }
  final popup = windowsModalSesDims(ctx); // a popup's own pixel size
  ses[14] = popup?.$1 ?? ctx.winPxHeight & 0xff;
  ses[15] = popup?.$2 ?? ctx.winPxWidth & 0xff;
  return Uint8List.fromList([itemSes, ...ses]);
}

/// The Windows container echo a round sending the dynpro [cursor] (client
/// form, [windowsClientCursor]; null = none / a control focus) carries —
/// a pushbutton round and every function-key round (reference client ff1e540):
/// the paint's table-control groups the cursor lies in
/// ([windowsCursorInTable]), then every tabstrip group
/// ([ActionContext.paintedTabstripEcho], the page-nested strips before the
/// top-level ones — [windowsPaintEcho]) — the table controls first
/// whatever the paint order (a recorded session gui[124]).
List<Uint8List> windowsCursorEcho(ActionContext ctx, List<int>? cursor) => [
      for (final t in ctx.paintedTableEcho)
        if (windowsCursorInTable(cursor, t.path)) ...t.items,
      ...ctx.paintedTabstripEcho,
    ];

/// The SAP GUI for WINDOWS click on a PAINTED dynpro pushbutton (reference client
/// nested_state_round.windows_nested_button_items / flat_pushbutton_round
/// .flat_pushbutton_items): step, SES (no event; the modal level /
/// position, the window pixels' low bytes), 16/6/35, 16/12/4 `=FCODE`, the
/// identity atoms, the OK event [winOkModeNested] over zeros, 16/12/8
/// window pixels, the PAINTED 16/12/6, the paint's Windows container echo
/// — the table-control groups that hold the cursor
/// ([ActionContext.paintedTableEcho] gated by [windowsCursorInTable]),
/// then every tabstrip group — the 16/15/1 BUTTONPRESSED source at the
/// button's OWN cell and container [path] ([buttonEventSource]), the
/// 16/9/11 of the CURRENT painted cursor in its client form
/// ([windowsClientCursor]; not the button's; none when the paint set
/// none), EOM — no DATAMANAGER. With a CFW control focus the OK mode is
/// [winOkModeControlFocus] and `16/9/18 <shell>` replaces the 16/9/11
/// (su53 gui[435]/[439] `=DETLPERSW`, gui[867] `=OPT2`).
///
/// Oracles: a recorded session gui[124] / gui[126] `=MEV4002BUTTON`
/// (ME21N's item-detail toggle inside SUB0/SUB1…, path `01 04 01`; srv
/// [152..153] / [154..157]; the cursor on TC_1211: its group echoed),
/// a recorded session gui[23] `=MEV4000BUTTON` (the test system's
/// collapsed ME21N: no tabstrip painted, the cursor in the header — NO
/// echo at all, and the 16/9/11 without the paint's trailing zero level),
/// a recorded session gui[17] `=P+` (the flat form: no echo,
/// path = the atom's area).
List<Uint8List> windowsPushbuttonItems(
  ActionContext ctx, {
  required String fcode,
  required int row,
  required int col,
  required List<int> path,
  bool cursorOnButton = false,
}) {
  final fc = fcode.startsWith('=') ? fcode : '=$fcode';
  final control = ctx.paintedControlFocus;
  final painted = ctx.paintedFocus;
  final cursor = painted == null ? null : windowsClientCursor(painted);
  final zero = cursor != null &&
      cursor.length >= 10 &&
      cursor[0] == 1 &&
      cursor.sublist(1).every((b) => b == 0);
  final modal = ctx.modalNo != 0;
  // in a POPUP whose painted cursor sits on a pushbutton ([cursorOnButton]
  // — SAPLSPO1's default button) the click names no dynpro cursor: the
  // empty 16/9/10 (system_menu_session raw gui[10] `=YES`, cursor painted
  // on Non; selection_options_buttons raw gui[40] `=NO`, cursor on Oui —
  // every one of the corpus' 20 popup clicks on such a paint)
  final noCursor = modal && control == null && cursorOnButton;
  final dynproCursor = control == null && !zero && !noCursor ? cursor : null;
  final echo = windowsCursorEcho(ctx, dynproCursor);
  // a POPUP's click without a dynpro cursor (a control focus or none) is
  // OK 0x03 (the reference client's WIN_OK_MODE_MODAL: 16 of the corpus' 25 such
  // clicks; 9 are 0x0b — a recorded session gui[858] / [867],
  // SPO1/0500 popups — the discriminator is open); no 16/12/8 there (33 of
  // 33 popup clicks), the popup's own 16/12/6 and the 16/4/36 window rect
  // after the okcode when owed ([windowsModalWindowRectOwed])
  // With the acked paint's mode known the click follows the round rule
  // ([windowsOkMode]): the cursor half with the 16/9/11 it sends (enjoy
  // gui[124] 0x0d on a `09` paint), else the control half — 0x03 on a `01`
  // popup paint, 0x0b on a `09` one (su53 gui[858] / [867]; reference client
  // 7de3990: 16 x 0x03 / 9 x 0x0b, every one by its paint)
  final okMode = windowsOkMode(ctx,
      cursor: dynproCursor != null,
      fallback: modal && dynproCursor == null
          ? winOkModeModal
          : control != null
              ? winOkModeControlFocus
              : winOkModeNested);
  final geometry = modal ? ctx.paintedTopWindowGeometry : null;
  return [
    stepItem(ctx.step),
    _winSesItem(ctx),
    buildApplItem(6, 35, winCodepageValue),
    buildApplItem(12, 4, wireText(fc)),
    if (windowsModalWindowRectOwed(ctx))
      buildApplItem(4, 36, windowsWindowRect(ctx)),
    for (final (sid, value) in winIdentity) buildApplItem(4, sid, value),
    buildApplItem(5, 1, Uint8List(22)..[1] = okMode),
    if (!modal) buildApplItem(12, 8, _winPxValue(ctx)),
    buildApplItem(12, 6,
        geometry != null
            ? Uint8List.fromList(geometry)
            : windowsPaintedGeometry(ctx, _screenScrollInfos2(ctx.screenRows, ctx.screenCols))),
    ...echo,
    buildApplItem(15, 1, buttonEventSource(row, col, path)),
    if (control != null)
      buildApplItem(9, 18, wireText(control))
    else if (dynproCursor != null)
      buildApplItem(9, 11, dynproCursor)
    else if (noCursor)
      buildApplItem(9, 10, Uint8List(0)),
    eomBytes,
  ];
}
