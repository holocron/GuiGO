/// Client frames of a MENU-BAR click (the 18/11/1 bar, its 18/11/2
/// dropdowns): the real SAP GUI fires a menu entry BY POSITION, never by
/// its function key or a function code — the entries carry no fcode on the
/// wire (reference client memory menu-item-fire-by-position; raw_okcode
/// `_menu_select_items`).
///
/// The real GUI's frame is its typed-okcode envelope WITHOUT the 16/12/4
/// OK_CODE item, the SES naming the path: eventid1..4 = the levels, whatever
/// the depth, the eventarray byte = the MENU event (Java 0x02, Windows 0x41
/// — frontend_profile.winSesEventarray). Even an entry the PF-status binds
/// to a function key goes by position: a recorded session
/// gui[10] / [15] / [20] (`Editeur graphique` vkey 9, `Version précédente`
/// vkey 30, `Version suivante` vkey 31), a recorded session gui[18] (`Statut
/// de liste…` vkey 41), a recorded session gui[34] (vkey 30), the Java
/// a recorded session gui[36] (`Définition de méthode` vkey 6).
///
/// * SAP GUI for WINDOWS (a recorded session raw gui[23] Système >
/// Statut… `41 05 0b`, raw gui[25] Aide > Options… `41 06 07`, raw
/// gui[27] Système > Valeurs utilisateur > Données utilisateur `41 05 03
/// 04`; a recorded session gui[1310], a recorded session
/// gui[29], a recorded session gui[130]): the Windows typed-okcode
/// round item for item — OK `00 0b` over zeros, 16/12/8, the PAINTED
/// 16/12/6, the empty 16/9/10 (or `16/9/18 <shell>` and the tabstrip
/// echo with a CFW control focus) — and NO 16/15/1 UI_EVENT_SOURCE: none
/// of the corpus' 15 Windows menu rounds carries one;
/// * SAP GUI for JAVA (a recorded session gui[11] / [26] Aide > Options…,
/// a recorded session gui[7] / [21]): the Java okcode envelope with the
/// 16/15/1 menu source (valid_menu_pos, BUTTONPRESSED on MENUBUTTON, the
/// four position bytes) right before the focus item.
///
/// Every entry is a position click, Système > Nouvelle fenêtre GUI (vkey
/// 74) included: the MOUSE click on it is the position round `41 05 01`
/// (a recorded session raw gui[5]); the `/O0` typed okcode
/// of a recorded session raw gui[5] is the keyboard route (Ctrl-+).
/// Typed-but-unsent field values ride the Windows menu round itself
/// ([windowsMenuRoundOf] over the field round; a recorded session
/// raw gui[9]).
library;

import 'dart:typed_data';

import '../framing/envelope.dart';
import 'actions.dart';
import 'frontend_profile.dart';

/// The deepest menu path the click can name: the UI_EVENT_SOURCE carries
/// four position bytes, the SES four of its five event ids (reference client
/// raw_commands._MENU_MAX_DEPTH).
const int menuMaxDepth = 4;

/// The SES eventarray of a menu-position click in the Java spelling (the
/// Windows GUI's 0x41 is [winSesEventarray] of it). The same for every
/// depth: `eventarray = depth` is what the kernel silently drops
/// (a recorded session gui[7] `02 04 06 02`, reference client c815c52).
const int menuSesEventarray = 0x02;

/// The function key of Système > Nouvelle fenêtre GUI (Créer session,
/// Ctrl+N): its click is a position round like any entry, the window the
/// server opens the client's own (SapSession.selectMenuPath).
const int newWindowVkey = 74;

List<int> _checkedPath(List<int> path) {
  final p = [
    for (final x in path)
      if (x != 0) x,
  ];
  if (p.isEmpty) {
    throw ArgumentError.value(path, 'path', 'an empty menu position path');
  }
  if (p.length > menuMaxDepth) {
    throw ArgumentError.value(
      path,
      'path',
      'a depth-${p.length} path exceeds the $menuMaxDepth position bytes '
          'a menu click carries',
    );
  }
  if (p.any((x) => x > 0xff)) {
    throw ArgumentError.value(path, 'path', 'a position over 255');
  }
  return p;
}

/// The 16-byte 16/15/1 UI_EVENT_SOURCE of a Java menu click at [path]:
/// valid_menu_pos 01, event type BUTTONPRESSED 0x0009, control type
/// MENUBUTTON 0x0004, the four position bytes (zero-padded), then zero
/// control row / col / container count — a recorded session gui[11]
/// `01 0009 0004 06070000 00000000000000` (reference client _menu_event_bytes).
Uint8List menuEventSource(List<int> path) {
  final p = _checkedPath(path);
  final out = Uint8List(16);
  out[0] = 0x01;
  out[2] = 0x09;
  out[4] = 0x04;
  for (var i = 0; i < p.length; i++) {
    out[5 + i] = p[i];
  }
  return out;
}

/// [items] with the SES naming the menu click at [path]: [eventarray] and
/// eventid1..N = the levels; every other SES byte (modal_no, dims) as built.
List<Uint8List> _withMenuSes(
  List<Uint8List> items,
  List<int> path,
  int eventarray,
) {
  return [for (final raw in items) _menuSes(raw, path, eventarray) ?? raw];
}

Uint8List? _menuSes(Uint8List raw, List<int> path, int eventarray) {
  if (raw.isEmpty || raw[0] != itemSes || raw.length < 17) return null;
  final ses = Uint8List.fromList(raw);
  // item byte 0 is the type: the SES value rides at raw[1..16]
  ses[1] = eventarray;
  for (var i = 0; i < 4; i++) {
    ses[2 + i] = i < path.length ? path[i] : 0;
  }
  return ses;
}

bool _isItem(Uint8List raw, int id, int sid) {
  final walk = walkItems(raw);
  if (walk.items.length != 1) return false;
  final it = walk.items.single;
  return it.isAppl && it.id == id && it.sid == sid;
}

/// A menu click at [path] in the JAVA spelling (the reference client's
/// `_menu_select_items`): [okcodeItems] without its 16/12/4, the SES
/// eventarray [menuSesEventarray] with the path as its event ids, and the
/// menu [menuEventSource] right before the 16/9/10 focus item
/// (a recorded session gui[11]: `… 5/1 12/8 12/6 15/1 9/10 t17`).
List<Uint8List> menuSelectItems(ActionContext ctx, List<int> path) {
  final p = _checkedPath(path);
  final out = <Uint8List>[];
  for (final raw in okcodeItems(ctx, '')) {
    if (_isItem(raw, 12, 4)) continue; // the position IS the command
    if (_isItem(raw, 9, 10)) {
      out.add(buildApplItem(15, 1, menuEventSource(p)));
    }
    out.add(raw);
  }
  return _withMenuSes(out, p, menuSesEventarray);
}

/// A menu click at [path] as the SAP GUI for WINDOWS sends it: the SES
/// eventarray 0x41 (the Windows spelling of [menuSesEventarray]) with the
/// path as its event ids, no 16/12/4 and no 16/15/1 — none of the corpus'
/// 15 Windows menu rounds carries either — and otherwise the window-state
/// round of WHERE THE FOCUS IS (reference client windows_menu_round, 6266859):
///
/// * the okcode field / no focus (the default): the Windows typed-okcode
/// round ([windowsActionItems] of [okcodeItems]) — OK `00 0b` over
/// zeros, 16/12/8, the PAINTED 16/12/6, the empty 16/9/10
/// (a recorded session raw gui[23] / [25] / [27], a recorded session
/// trees gui[130], a recorded session gui[76]);
/// * a CFW control holds the focus ([ActionContext.paintedControlFocus]):
/// the paint's tabstrip echo after the 16/12/6 and `16/9/18 <shell>` in
/// the focus slot, OK `00 0b` (a recorded session gui[1310] on
/// the Easy Access tree 105, gui[158] on the CONTAINERCTRL 119 with its
/// tabstrip echo, a recorded session gui[29] on the AbapEditor
/// 116) — `00 03` when that control is a SAP Graphics OCX
/// ([graphicsFocus]: SAPGUI.NetPlanGraphics.1 / BarChartGraphics.1, the
/// mode their own events carry — a recorded session
/// gui[15] / [20] on the route graph 117; the corpus' five key rounds
/// with such a focus are 0x03 too: a recorded session gui[20],
/// a recorded session gui[24] / [33], a recorded session
/// wingui gui[32] / [37]);
/// * a dynpro CURSOR the client placed in a field ([cursor], the 16/9/11
/// `[depth][row u16][col u16][caret u32][path]`, sent in its client form
/// [windowsClientCursor]): OK `00 05` over zeros (`00 0d` for a nested /
/// table-control cursor or on a paint declaring a named container — the
/// window-state rule [windowsWindowStateOkMode]), 16/12/8, the painted
/// 16/12/6, the cursor-gated container echo ([windowsCursorEcho]) and
/// the 16/9/11 — whatever control focus the paint declared
/// (a recorded session gui[312]: `00 05` + `01 0003 0019
/// 00000004 00` on srv[375], which painted the focus on control 122);
/// * an ABAP LIST window ([list]): no 16/5/1 and no 16/12/6 — the OK event
/// rides the type-9 CHL item, as on the list's own paint — then 16/12/8
/// and the list cursor 16/12/13 [listCursor] `01 <line u16> <col u16>`
/// with CHL mode `00 0d` (a recorded session gui[34] on srv[35]'s
/// painted `01 0002 0001`, gui[37]; a recorded session gui[18], a line
/// the user clicked); without a list cursor CHL `00 0b` and the empty
/// 16/9/10 (a recorded session gui[10] on srv[17]).
///
/// [gridCellCurrent]: a CFW grid holds a current cell the round's item 17
/// carries (the staged CurrentCell* / FVC state): OK `00 0d` whatever the
/// focus item — the flat painted 16/9/11 (a recorded session raw
/// gui[14] on srv[23], Saut > 3>9) or the grid's 16/9/18 (raw gui[17],
/// 3>1); the key round with that focus and no current cell stays `00 0b`
/// (raw gui[20] — on raw srv[30], a paint naming the grid; on a paint that
/// itself ended in a 16/9/11, such as raw gui[17]'s srv[26], the control
/// focus is the cursor half anyway: [windowsControlOkMode]). Which of the two focus items the GUI picks after a cell
/// click is not settled by the capture: the focus follows the rules above.
List<Uint8List> windowsMenuSelectItems(
  ActionContext ctx,
  List<int> path, {
  Uint8List? cursor,
  bool list = false,
  Uint8List? listCursor,
  bool graphicsFocus = false,
  bool gridCellCurrent = false,
}) {
  final p = _checkedPath(path);
  final control = ctx.paintedControlFocus;
  // the focus the round names instead of the painted control's
  final ownFocus = list || cursor != null;
  if (ownFocus) ctx.paintedControlFocus = null;
  final List<Uint8List> round;
  try {
    round = windowsActionItems(okcodeItems(ctx, ''), ctx: ctx);
  } finally {
    ctx.paintedControlFocus = control;
  }
  final client = cursor == null ? null : windowsClientCursor(cursor);
  final out = <Uint8List>[];
  for (final raw in round) {
    if (_isItem(raw, 12, 4)) continue; // the position IS the command
    if (_isItem(raw, 5, 1)) {
      final v = Uint8List.fromList(walkItems(raw).items.single.value);
      if (list) {
        v.fillRange(0, v.length, 0);
        v[1] = listCursor != null ? winOkModeNested : winOkModeControlFocus;
        out.add(Uint8List.fromList([itemChl, ...v]));
        continue;
      }
      // the okcode round's mode is already the acked paint's control half
      // ([windowsOkMode]); a cursor the round names is its cursor half —
      // the constants below decide only without a paint mode
      if (client != null) {
        v.fillRange(0, v.length, 0);
        v[1] = windowsOkMode(
          ctx,
          cursor: true,
          fallback: ctx.modalNo != 0
              ? winOkModeModal
              : windowsCursorIsNested(client) || ctx.paintedNamedContainer
              ? winOkModeNested
              : winOkModePlain,
        );
      } else if (graphicsFocus && control != null && ctx.modalNo == 0) {
        // the SAP Graphics family's 0x03 (stms_routeeditor_confirm gui[15]
        // / [20] on `01` paints); the cursor half on a paint that itself
        // ended in a 16/9/11 ([windowsControlOkMode] — reference client
        // nested_state_round.control_focus_ok_mode)
        v[1] = windowsControlOkMode(ctx, fallback: winOkModeModal);
      }
      // a grid's current cell (GridView.ocx's CurrentCell* in item 17) takes
      // the CURSOR half whatever the focus item — the flat 16/9/11 of
      // menu_focus raw gui[14] and the grid's 16/9/18 of raw gui[17], both
      // 0x0d (reference client windows_menu_round.cursor_ok_mode, 4e82af2); 0x0d
      // without a paint mode
      if (gridCellCurrent && ctx.modalNo == 0) {
        v[1] = windowsOkMode(ctx, cursor: true, fallback: winOkModeNested);
      }
      out.add(buildApplItem(5, 1, v));
      continue;
    }
    if (_isItem(raw, 12, 6)) {
      if (list) continue; // a list round names no dynpro geometry
      out.add(raw);
      if (client != null) out.addAll(windowsCursorEcho(ctx, client));
      continue;
    }
    if (_isItem(raw, 9, 10)) {
      if (client != null) {
        out.add(buildApplItem(9, 11, client));
      } else if (list && listCursor != null) {
        out.add(buildApplItem(12, 13, listCursor));
      } else {
        out.add(raw);
      }
      continue;
    }
    out.add(raw);
  }
  return _withMenuSes(out, p, winSesEventarray[menuSesEventarray]!);
}

/// The Windows round [round] (already in the Windows spelling — a field
/// round carrying typed values) re-addressed as the menu click at [path]:
/// its 16/12/4 and any 16/15/1 dropped (no Windows menu round carries
/// either), its SES eventarray 0x41 with the path as event ids; every other
/// item kept. a recorded session raw gui[9] (BELNR
/// typed, Saut > Premier poste) is the Enter field round of raw gui[11]'s
/// shape — OK `00 05`, 16/12/8, 16/12/6, 16/10/1, the changed field's
/// 16/9/2, the 16/9/11 with the caret at the end of the text — under SES
/// `41 03 02`.
List<Uint8List> windowsMenuRoundOf(List<Uint8List> round, List<int> path) {
  final p = _checkedPath(path);
  return _withMenuSes(
    [
      for (final raw in round)
        if (!_isItem(raw, 12, 4) && !_isItem(raw, 15, 1)) raw,
    ],
    p,
    winSesEventarray[menuSesEventarray]!,
  );
}

/// The 16/12/13 list cursor `01 <line u16> <col u16>` of a list round.
Uint8List listCursorValue(int line, int col) => Uint8List.fromList([
  1, line >> 8 & 0xff, line & 0xff, col >> 8 & 0xff, col & 0xff,
]);

/// Whether CFW class [cls] is one of the SAP Graphics OCXs (SAPnetz.OCX
/// SAPGUI.NetPlanGraphics.1, SAPbarc.OCX SAPGUI.BarChartGraphics.1): a
/// menu round with the focus on such a control goes out OK `00 03`
/// ([windowsMenuSelectItems]).
bool isSapGraphicsClass(String cls) => _isSapGraphicsClassRx.hasMatch(cls.trim());

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call (audit #7 / zcode P-12).
final RegExp _isSapGraphicsClassRx = RegExp(
  r'^SAPGUI\.(?:NetPlan|BarChart)Graphics\.\d+$',
  caseSensitive: false,
);
