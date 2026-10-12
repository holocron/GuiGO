/// CFW CONTROL TOOLBARS — the button rows a control carries beside the
/// dynpro's own application toolbar: the OO-ALV grid's built-in toolbar
/// (GridView.ocx, CL_GUI_ALV_GRID) and the standalone toolbar control
/// (`SAP.Toolbar.1`, CL_GUI_TOOLBAR — the SE80 browser toolbar, the ALV
/// tree's toolbar, ME21N's document overview).
///
/// Wire shapes, every one from a REAL SAP GUI for Windows capture:
///
/// * The ALV grid's buttons are no control of their own: the grid's
/// creation flush hands the GridView a `ToolBarButtonsTable2` X-R3TABLE
/// (`AssignProperty2(…, r3TableAutoObj, <grid>, ToolBarButtonsTable2)`)
/// whose FORMAT declares the ABAP `stb_button` row — FUNCTION C70 | ICON
/// C30 | QUICKINFO C30 | BUTN_TYPE I | DISABLED C1 | TEXT C40 | CHECKED
/// C1 (a recorded session srv[116], SM12's lock list 127: `&SORT_ASC`
/// `@3E@` "Trier - Ordre croissant" 0 …, `&MB_FILTER` type 1, `&MB_EXPORT`
/// type 2, `&&SEP28` type 3 disabled, `DETAILS` `@16@`). A menu button's
/// entries ride a `SetToolBarMenuStatic(<fcode>, <menu>)` on the grid
/// object in the same queue (the X-SAPCTXMENU push of
/// cfw/context_menu.dart: `&MB_VARIANT` -> `&COL0` "Modifier mise en
/// forme...", `&LOAD`, `&SAVE`, `&MAINTAIN`), or — a menu the
/// application builds on demand — come back as `SetToolBarMenu(<menu>,
/// x, y)` in the answer to the dropdown event (a recorded session
/// srv[95], /IWFND/ERROR_LOG grid 123 `REQUEST_DATA`).
/// * The grid's toolbar events (GridView.ocx): a button press is
/// `%_GC <grid> 10` PARAM 0 = the fcode (a recorded session gui[95]
/// SM12 `DETAILS`; a type-1 button's body too: a recorded session
/// gui[237] `&MB_FILTER`); a menu button WITHOUT a static menu opens with
/// `%_GC <grid> 11` PARAMs fcode, x, y (a recorded session gui[85]
/// `REQUEST_DATA` 585 596); an entry of either menu is `%_GC <grid> 14`
/// PARAM 0 = the entry's fcode (gui[87] `REQUEST_HEADER`; a STATIC menu's
/// entry goes out at once, its menu is never asked for: a recorded session
/// aif gui[231] `&FILTER` of the static `&MB_FILTER`).
/// * The standalone toolbar gets its buttons by `AddButton(fcode, icon,
/// enabled, type, text, quickinfo, checked)` verbs (html_viewer.dart
/// [SapToolbarButton]), a static menu by `SetStaticCtxMenu(fcode,
/// <menu>)`, an on-demand one by `TrackContextMenu(<menu>, x, y)` in the
/// answer to dropDownClicked; its events are functionSelected = 1 (a
/// button, or a menu entry: PARAM 0 = the entry's fcode verbatim) and
/// dropDownClicked = 2 (fcode, x, y) — a recorded session
/// gui[1] `%_GC 126 2` SELECT 1940 263, srv[9] the TrackContextMenu
/// push, gui[7] `%_GC 126 1` `005056AE…NEW:REQ_QUERY`.
///
/// Button types (stb_button BUTN_TYPE = SapToolBar NWButtonType): 0 button,
/// 1 split menu button (the body fires the function, the arrow opens the
/// menu), 2 menu button (the whole button opens the menu), 3 separator,
/// 4 radio button, 5 check (toggle) button.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../screen/sap_tree.dart' show decodeNamedDpTable;
import 'context_menu.dart';
import 'dp_cache.dart';
import 'flush_call.dart';
import 'html_viewer.dart' show SapToolbarButton;

/// stb_button BUTN_TYPE values.
const int toolbarButtonPlain = 0;
const int toolbarButtonSplitMenu = 1;
const int toolbarButtonMenu = 2;
const int toolbarButtonSeparator = 3;
const int toolbarButtonRadio = 4;
const int toolbarButtonToggle = 5;

/// GridView.ocx toolbar events: a button press, a menu button pressed (its
/// menu asked for), a menu entry chosen.
const int gridEventToolbarButton = 10;
const int gridEventToolbarMenuButton = 11;
const int gridEventToolbarMenuItem = 14;

/// SAP.Toolbar.1 events: functionSelected (a button or a menu entry),
/// dropDownClicked (a menu button's menu asked for).
const int toolbarEventFunctionSelected = 1;
const int toolbarEventDropDownClicked = 2;

/// The DataProvider roles of a grid's toolbar push (the FORMAT-declared
/// table and its fixed-record predecessor).
const Set<String> gridToolbarRoles = {'ToolBarButtonsTable2', 'ToolBarButtons'};

/// The verbs that hand a toolbar menu over: on the ALV grid object, the
/// static menu of a button and the menu opened in answer to event 11; on
/// the standalone toolbar, the same pair.
const String gridStaticMenuVerb = 'SetToolBarMenuStatic';
const String gridTrackMenuVerb = 'SetToolBarMenu';
const String toolbarStaticMenuVerb = 'SetStaticCtxMenu';
const String toolbarTrackMenuVerb = 'TrackContextMenu';

/// Which control a toolbar belongs to — it decides the events.
enum SapControlToolbarKind {
  /// the OO-ALV grid's built-in toolbar: events 10 / 11 / 14 on the grid
  grid,

  /// a SAP.Toolbar.1 control: events 1 / 2 on the toolbar
  standalone,
}

/// One control toolbar as the session holds it.
class SapControlToolbar {
  SapControlToolbar({
    required this.shell,
    required this.kind,
    required this.buttons,
    Map<String, List<SapMenuEntry>>? staticMenus,
  }) : staticMenus = staticMenus ?? const {};

  /// The shell the toolbar's events go to: the grid's for a grid toolbar,
  /// the toolbar control's own for a standalone one.
  final String shell;
  final SapControlToolbarKind kind;

  /// In display order, separators included.
  final List<SapToolbarButton> buttons;

  /// fcode -> the menu the server handed the button up front: shown
  /// without a server round, its entry is the pick event at once.
  final Map<String, List<SapMenuEntry>> staticMenus;

  SapToolbarButton? button(String fcode) {
    for (final b in buttons) {
      if (!b.separator && b.code == fcode) return b;
    }
    return null;
  }

  @override
  String toString() =>
      'SapControlToolbar($shell ${kind.name}: '
      '${buttons.where((b) => !b.separator).map((b) => b.code).join(' ')})';
}

String _text(Uint8List b) {
  var n = b.length;
  while (n > 0 && (b[n - 1] == 0x20 || b[n - 1] == 0)) {
    n--;
  }
  return utf8
      .decode(Uint8List.sublistView(b, 0, n), allowMalformed: true)
      .trim();
}

bool _validFcode(String f) =>
    f.isNotEmpty && !f.codeUnits.any((c) => c < 0x20 || c == 0x7f);

bool _validIcon(String i) =>
    i.isEmpty || (i.startsWith('@') && i.endsWith('@'));

/// The BUTN_TYPE of a cell: the int's high half when its low half is empty
/// (a 2-byte-shifted read gives 65536 for 1 — the reference client's
/// gridread_report._buttype), else the value.
int _buttonType(String v) {
  final n = int.tryParse(v.trim()) ?? 0;
  return n >= 65536 && n % 65536 == 0 ? n >> 16 : n;
}

/// The buttons of a grid's `ToolBarButtonsTable2` push segment, decoded by
/// its own FORMAT (7 positional columns `C C C I C C C`), in push order —
/// separators included (an unnamed separator has fcode ''). [] when the
/// segment is not such a table (self-validating: every non-separator row
/// a printable fcode, every icon blank or an `@..@` code).
List<SapToolbarButton> decodeToolbarButtonsPush(Uint8List seg) {
  final t = decodeNamedDpTable(seg);
  if (t != null && t.columns.length >= 6 && t.types.length >= 6) {
    const c = 0x43, i = 0x49;
    final ty = t.types;
    if (ty[0] != c || ty[1] != c || ty[2] != c || ty[3] != i) return const [];
    final k = t.columns;
    final out = <SapToolbarButton>[];
    for (final r in t.rows) {
      final code = (r[k[0]] ?? '').trim();
      final icon = (r[k[1]] ?? '').trim();
      final type = _buttonType(r[k[3]] ?? '');
      if (type != toolbarButtonSeparator && !_validFcode(code)) return const [];
      if (!_validIcon(icon)) return const [];
      out.add(
        SapToolbarButton(
          code: code,
          icon: icon,
          tooltip: (r[k[2]] ?? '').trim(),
          type: type,
          enabled: (r[k[4]] ?? '').trim().toUpperCase() != 'X',
          text: (r[k[5]] ?? '').replaceAll('\x00', '').trim(),
          checked: k.length > 6 && (r[k[6]] ?? '').trim().toUpperCase() == 'X',
        ),
      );
    }
    return out.any((b) => b.code.isNotEmpty) ? out : const [];
  }
  // the legacy fixed-record ToolBarButtons blob (no FORMAT): 180-byte
  // stb_button records in the DATAASC column (a recorded session
  // buttons: FUNCTION 0-69, ICON 70-99, QUICKINFO 100-129, BUTN_TYPE @132,
  // DISABLED @136, TEXT 137-176)
  final (_, _, cells) = dpColumnCells(seg, 'DATAASC');
  final b = BytesBuilder(copy: false);
  for (final c in cells) {
    b.add(c);
  }
  return decodeToolbarButtonRecords(b.takeBytes());
}

/// The 180-byte `stb_button` records of a fixed-layout ToolBarButtons
/// blob, or [] when [data] is not one.
List<SapToolbarButton> decodeToolbarButtonRecords(Uint8List data) {
  const rec = 180;
  if (data.isEmpty || data.length % rec != 0) return const [];
  final out = <SapToolbarButton>[];
  for (var k = 0; k < data.length ~/ rec; k++) {
    final r = Uint8List.sublistView(data, k * rec, (k + 1) * rec);
    final code = latin1.decode(Uint8List.sublistView(r, 0, 70)).trim();
    final icon = latin1.decode(Uint8List.sublistView(r, 70, 100)).trim();
    final type = r[132];
    if (type != toolbarButtonSeparator && !_validFcode(code)) return const [];
    if (!_validIcon(icon)) return const [];
    out.add(
      SapToolbarButton(
        code: code,
        icon: icon,
        tooltip: _text(Uint8List.sublistView(r, 100, 130)),
        type: type,
        enabled: r[136] != 0x58,
        text: _text(Uint8List.sublistView(r, 137, 177)),
      ),
    );
  }
  return out.any((b) => b.code.isNotEmpty) ? out : const [];
}

/// One menu-handing verb of a queue ([gridStaticMenuVerb] …): the object
/// it runs on (its VARS row and that row's handle token), the button it
/// names (static menus), the menu's push url and the popup position the
/// server echoes (track menus).
class ToolbarMenuVerb {
  ToolbarMenuVerb({
    required this.verb,
    required this.objRow,
    required this.handle,
    required this.url,
    this.fcode,
    this.x,
    this.y,
  });

  final String verb;
  final String objRow;
  final String handle;
  final String url;
  final String? fcode;
  final String? x, y;

  bool get isStatic =>
      verb == gridStaticMenuVerb || verb == toolbarStaticMenuVerb;
  bool get onGrid => verb == gridStaticMenuVerb || verb == gridTrackMenuVerb;

  @override
  String toString() =>
      'ToolbarMenuVerb($verb on $handle${fcode == null ? '' : ' $fcode'} $url)';
}

const Set<String> _menuVerbs = {
  gridStaticMenuVerb,
  gridTrackMenuVerb,
  toolbarStaticMenuVerb,
  toolbarTrackMenuVerb,
};

/// The menu-handing verbs of [call] in queue order, each with the url of
/// the X-SAPCTXMENU push its menu argument derives from: the
/// `SetDataFromUrl` row the argument's VARS row descends from (through
/// GetDataAsFormat / automationObject results), else the queue's latest
/// X-SAPCTXMENU push before it (the chain the reference client's ea_facts.
/// record_control_toolbars follows).
List<ToolbarMenuVerb> toolbarMenuVerbsOf(FlushCall call) {
  if (!call.verbs.any(_menuVerbs.contains)) return const [];
  final meta = verbMeta(call);
  final rowUrl = <String, String>{};
  String? menuUrl;
  final out = <ToolbarMenuVerb>[];
  for (var i = 1; i <= call.verbs.length; i++) {
    final verb = call.verbs[i - 1];
    final m = meta[i - 1];
    final obj = m.obj.trim();
    final res = (m.result ?? '').trim();
    final named = verbNamedArgs(call, i);
    if (verb == 'SetDataFromUrl') {
      final u = (named['#3'] ?? '').trim();
      if (u.startsWith('SAPR3://')) {
        if (obj.isNotEmpty) rowUrl[obj] = u;
        if ((named['#2'] ?? '').trim() == contextMenuFormat) menuUrl = u;
      }
    } else if (_menuVerbs.contains(verb)) {
      final isStatic =
          verb == gridStaticMenuVerb || verb == toolbarStaticMenuVerb;
      final slot = isStatic ? '#2' : '#1';
      final url = rowUrl[(m.slots[slot] ?? '').trim()] ?? menuUrl;
      if (url != null) {
        out.add(
          ToolbarMenuVerb(
            verb: verb,
            objRow: obj,
            handle: m.objValue.trim(),
            url: url,
            fcode: isStatic ? (named['#1'] ?? '').trim() : null,
            x: isStatic ? null : (named['#2'] ?? '').trim(),
            y: isStatic ? null : (named['#3'] ?? '').trim(),
          ),
        );
      }
      menuUrl = null;
    }
    // a result row derived from a url row carries its url on
    if (res.isNotEmpty) {
      final u = rowUrl[obj];
      if (u != null) {
        rowUrl[res] = u;
      } else {
        rowUrl.remove(res);
      }
    }
  }
  return out;
}

/// The entries of the menu [v] hands over, decoded from [segment] (the
/// session's DP cache) or, failing that, from the call's own pushes.
List<SapMenuEntry> toolbarMenuEntries(
  ToolbarMenuVerb v,
  Uint8List callValue, {
  Uint8List? Function(String url)? segment,
  DpCache? own,
}) {
  var seg = segment?.call(v.url);
  seg ??= (own ?? (DpCache()..ingestValue(callValue))).byUrl[v.url];
  return seg == null ? const [] : decodeContextMenuPush(seg);
}
