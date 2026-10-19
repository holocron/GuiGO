/// Server-driven CFW CONTEXT MENUS: the `X-SAPCTXMENU` DataProvider push a
/// `SetContextMenu` verb binds to a control (reference client /
/// port; the record layout of diag_gos.MENU_*).
///
/// Wire shape of ONE menu (every recorded real-GUI answer, both dialects):
///
/// CreateObject(GuiDataProvider) -> <dp>
/// SetDataFromUrl(<dp>, APPLICATION, X-SAPCTXMENU, SAPR3://<guid>)
/// GetDataAsFormat(<dp>, APPLICATION, X-SAPCTXMENU) -> <data>
/// automationObject(<data>) -> <auto> (Java: `data(<data>)`)
/// FreeObject(<data>) / FreeObject(<dp>)
/// SetContextMenu(<GuiCtlMgr>, #1=<shell>, #2=<auto>, #3=0)
///
/// * Windows tree: a recorded session srv[47] / [51]
/// (SAP.TableTreeControl.1 154, answering gui[36] / [40] `%_GC 154 36`);
/// a recorded session srv[27] / [29], a recorded session
/// srv[20] / [41] / [49], a recorded session
/// srv[44] / [46] (column trees, answering `%_GC <tree> 26`);
/// a recorded session srv[16] (cascades + greyed entries);
/// * Java tree: a recorded session srv[141] (SapTree 245,
/// answering gui[122] `%_GC 245 26`; the verb is `data`, not
/// `automationObject`);
/// * canvas: a recorded session srv[39] / [56] (ICDataFlow 131,
/// answering the object picks gui[37] / [53] `%_GC 131 4194304`).
///
/// The OO-ALV grid (GridView.ocx) binds its menu on the GRID object
/// instead: `SetContextMenu(#1=<auto>)` run on the grid's handle, no shell
/// argument — a recorded session srv[20] / [22] / [26] (grid
/// 122, answering `%_GC 122 9`), a recorded session
/// srv[21] / [23] (no trailing SetProperty 290 there).
///
/// The push is a 204-byte record table in its DATAASC column (FORMAT
/// `I level | C1 flag | C70 fcode | C4 | C120 text | C1 | C1 | C1 | C1`):
///
/// [0..4) u32 LE nesting level (1 = top, 2 = item of the preceding
/// level-1 'C' header — a recorded session srv[16])
/// [4] flag: 'F' function, 'C' cascade (submenu) header, 'S'
/// separator (a recorded session srv[141])
/// [5..75) C70 fcode (empty on 'C' and 'S')
/// [75..79) C4 icon code (`@3T@` on a recorded session
/// srv[27]'s TRCOLLAPSE; blank elsewhere)
/// [79..199) C120 label (UTF-8 — `Créer`)
/// [199] 'X' = greyed (a recorded session srv[16]: the
/// create entries of an editor in display mode;
/// a recorded session srv[20] `&DELETE_FILTER`,
/// srv[26] `&SUMC`)
/// [201] 'X' = the DEFAULT entry, drawn bold (a recorded session
/// easyaccess_tree_ctxmenu srv[6] `XXEXPD`, srv[8] `XXEXEC`;
/// none in its background menu srv[10])
/// [202] accelerator letter (`Saut vers dictionnaire` -> 'S')
///
/// The wire fcode of an entry is its fcode COLUMN: the DECODE's "technical
/// key" `FF_TDEL` of a recorded session is flag 'F' + fcode
/// `F_TDEL`, and gui[39] sends `F_TDEL`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'control_toolbar.dart';
import 'dp_cache.dart';
import 'flush_call.dart';

/// The SetDataFromUrl FORMAT of a context-menu table push.
const String contextMenuFormat = 'X-SAPCTXMENU';

/// The verb that binds a menu push to a control (#1 = the shell).
const String setContextMenuVerb = 'SetContextMenu';

/// The X-SAPCTXMENU record width.
const int contextMenuRecordWidth = 204;

/// The deepest nesting a record may declare (a cascade in a cascade).
const int contextMenuMaxLevel = 4;

/// Which control dialect a menu belongs to — it decides how a pick is sent.
enum SapContextMenuKind {
  /// a SapTree (simple / column / list tree): the pick is `%_GS <tree> 14`
  tree,

  /// the ICDataFlow designer canvas: the pick is `%_GC <shell> 2`
  canvas,

  /// an OO-ALV grid toolbar menu button's menu (control_toolbar.dart):
  /// the pick is `%_GC <grid> 14`
  gridToolbar,

  /// a SAP.Toolbar.1 menu button's menu: the pick is `%_GC <toolbar> 1`
  toolbar,

  /// an OO-ALV grid's own right-click menu (ContextMenu event 9): the pick
  /// is `%_GC <grid> 13` (ContextMenuSelected)
  grid,

  /// a control GuiGo has no recorded pick for (nothing can be sent)
  other,
}

/// One record of a pushed context menu.
class SapMenuEntry {
  SapMenuEntry({
    required this.level,
    required this.flag,
    required this.fcode,
    required this.text,
    required this.accel,
    required this.enabled,
    this.icon = '',
    this.isDefault = false,
  });

  /// 1 = top level, 2 = an item of the level-1 submenu header before it, …
  final int level;

  /// The raw record flag: 'F' function, 'C' submenu header, 'S' separator.
  final String flag;

  /// The function code a pick sends (empty on headers and separators).
  final String fcode;

  /// The visible label.
  final String text;

  /// The accelerator letter the server declared ('' when none).
  final String accel;

  /// The SAP icon code of the entry (`@3T@`; '' when none).
  final String icon;

  /// False for a GREYED entry (record byte 199 = 'X'): the real GUI cannot
  /// choose it.
  final bool enabled;

  /// The DEFAULT entry (record byte 201 = 'X'): the real GUI draws it bold
  /// — what a double-click on the node runs.
  final bool isDefault;

  /// The submenu header this entry belongs to (null at the top level).
  SapMenuEntry? parent;

  /// The entries of a submenu header, in push order.
  final List<SapMenuEntry> children = [];

  bool get isSeparator => flag == 'S' && fcode.isEmpty && text.isEmpty;
  bool get isSubmenu => flag == 'C' && fcode.isEmpty;

  /// A function the user can pick (an fcode, not greyed).
  bool get isSelectable => fcode.isNotEmpty && enabled;

  /// `Créer > Noeuds` — the header path down to this entry.
  String get path => parent == null ? text : '${parent!.path} > $text';

  @override
  String toString() => isSeparator
      ? 'SapMenuEntry(---)'
      : 'SapMenuEntry($level ${isSubmenu ? '$text >' : '$fcode "$text"'}'
            '${enabled ? '' : ' greyed'}${isDefault ? ' default' : ''})';
}

/// The menu the server pushed for one control, decoded.
class SapContextMenu {
  SapContextMenu({
    required this.shell,
    required this.kind,
    required this.entries,
    required this.url,
    this.targetKey,
    this.itemName,
    this.step,
  });

  /// The control the menu belongs to (the SetContextMenu #1 shell).
  final String shell;

  /// How a pick is sent ([SapContextMenuKind]).
  final SapContextMenuKind kind;

  /// Every record in push order — functions, submenu headers and separators.
  final List<SapMenuEntry> entries;

  /// The SAPR3 url of the X-SAPCTXMENU push.
  final String url;

  /// What the request named: the tree node key, or the canvas object id;
  /// null when the menu followed no request this session sent.
  final String? targetKey;

  /// The tree item (column) an ITEM request named.
  final String? itemName;

  /// The server step of the flush that carried the menu.
  final int? step;

  /// The top-level entries (submenu headers hold their items in
  /// [SapMenuEntry.children]).
  List<SapMenuEntry> get topLevel => [
    for (final e in entries)
      if (e.parent == null) e,
  ];

  /// The function entry with [fcode], or null.
  SapMenuEntry? entry(String fcode) {
    for (final e in entries) {
      if (e.fcode.isNotEmpty && e.fcode == fcode) return e;
    }
    return null;
  }

  @override
  String toString() =>
      'SapContextMenu($shell ${kind.name}${targetKey == null ? '' : ' on "$targetKey"'}: '
      '${entries.where((e) => !e.isSeparator).map((e) => e.isSubmenu ? '${e.text} >' : e.fcode).join(', ')})';
}

String _text(Uint8List b) {
  var end = b.length;
  while (end > 0 && (b[end - 1] == 0x20 || b[end - 1] == 0)) {
    end--;
  }
  final raw = Uint8List.sublistView(b, 0, end);
  try {
    return utf8.decode(raw).trim();
  } on FormatException {
    return latin1.decode(raw).trim();
  }
}

bool _blank(Uint8List b) => b.every((x) => x == 0x20 || x == 0);

/// One record, or null when it fails the record shape (a level outside
/// 1..[contextMenuMaxLevel], no flag letter, an unjustified C field, a
/// flag its fields contradict) — what keeps an arbitrary rowset from
/// reading as a menu. The C4 between fcode and label is the entry's ICON
/// (a recorded session srv[27] `@3T@`), never a filler a
/// shape test may require blank.
SapMenuEntry? _record(Uint8List rec) {
  if (rec.length < contextMenuRecordWidth) return null;
  final level = ByteData.sublistView(rec, 0, 4).getUint32(0, Endian.little);
  if (level < 1 || level > contextMenuMaxLevel) return null;
  final flag = String.fromCharCode(rec[4]);
  if (!_singleLetterRx.hasMatch(flag)) return null;
  final fc = Uint8List.sublistView(rec, 5, 75);
  final tx = Uint8List.sublistView(rec, 79, 199);
  final fcode = _blank(fc) ? '' : latin1.decode(fc).trimRight();
  final text = _blank(tx) ? '' : _text(tx);
  // a C field is left-justified
  if (fcode.isNotEmpty && (fc[0] == 0x20 || fc[0] == 0)) return null;
  if (text.isNotEmpty && (tx[0] == 0x20 || tx[0] == 0)) return null;
  if (flag == 'S' && fcode.isEmpty && text.isNotEmpty) return null;
  if (flag == 'C' && fcode.isEmpty && text.isEmpty) return null;
  if (flag != 'S' && flag != 'C' && fcode.isEmpty) return null;
  final accel = rec[202] == 0x20 || rec[202] == 0
      ? ''
      : String.fromCharCode(rec[202]);
  return SapMenuEntry(
    level: level,
    flag: flag,
    fcode: fcode,
    text: text,
    accel: accel,
    enabled: rec[199] != 0x58, // 'X' = greyed
    isDefault: rec[201] == 0x58, // 'X' = default (bold)
    icon: _blank(Uint8List.sublistView(rec, 75, 79))
        ? ''
        : latin1.decode(Uint8List.sublistView(rec, 75, 79)).trim(),
  );
}

/// The entries of an X-SAPCTXMENU DATAASC payload (whole 204-byte records),
/// with the cascade tree linked: a level-N record belongs to the nearest
/// preceding level-(N-1) 'C' header. [] unless EVERY record passes the
/// record shape, or when it holds no function at all.
List<SapMenuEntry> decodeContextMenuRecords(Uint8List data) {
  if (data.isEmpty || data.length % contextMenuRecordWidth != 0) {
    return const [];
  }
  final out = <SapMenuEntry>[];
  for (var k = 0; k < data.length ~/ contextMenuRecordWidth; k++) {
    final e = _record(
      Uint8List.sublistView(
        data,
        k * contextMenuRecordWidth,
        (k + 1) * contextMenuRecordWidth,
      ),
    );
    if (e == null) return const [];
    out.add(e);
  }
  if (!out.any((e) => e.fcode.isNotEmpty)) return const [];
  final heads = <int, SapMenuEntry>{};
  for (final e in out) {
    final p = e.level > 1 ? heads[e.level - 1] : null;
    if (p != null) {
      e.parent = p;
      p.children.add(e);
    }
    heads.removeWhere((lv, _) => lv >= e.level);
    if (e.isSubmenu) heads[e.level] = e;
  }
  return out;
}

/// The entries of ONE X-SAPCTXMENU push segment (a DpCache segment): its
/// DATAASC cells joined and cut to the declared `width x count`.
List<SapMenuEntry> decodeContextMenuPush(Uint8List seg) {
  final (_, (w, n), cells) = dpColumnCells(seg, 'DATAASC');
  if (cells.isEmpty) return const [];
  final b = BytesBuilder(copy: false);
  for (final c in cells) {
    b.add(c);
  }
  var data = b.takeBytes();
  if (w == contextMenuRecordWidth && n > 0 && data.length >= w * n) {
    data = Uint8List.sublistView(data, 0, w * n);
  }
  return decodeContextMenuRecords(data);
}

/// One SetContextMenu binding: the push the verb named for [shell].
class ContextMenuPush {
  ContextMenuPush(
    this.shell,
    this.url,
    this.entries,
    this.step, {
    this.verb = setContextMenuVerb,
  });
  final String shell;
  final String url;
  final List<SapMenuEntry> entries;
  final int? step;

  /// The verb that bound it: [setContextMenuVerb], or a toolbar's
  /// [gridTrackMenuVerb] / [toolbarTrackMenuVerb] (the menu a toolbar
  /// menu button's dropdown event asked for).
  final String verb;
}

/// The SapTree selection props a context-menu request flushes when changed
/// (sapTreeS.jar TreeMouseListener.selectPathForEvent; the OCX alike).
const String selNodeKeyProp = 'ABAPSelNodeKey';
const String selItemKeyProp = 'ABAPSelItemKey';
const String selItemNameProp = 'ABAPSelItemName';
const List<String> treeSelectionProps = [
  selNodeKeyProp,
  selItemKeyProp,
  selItemNameProp,
];

/// The SapTree's first displayed node (jar getTopNodeKey). An ITEM request
/// on a tree that registered it flushes it with the selection when it
/// changed — a recorded session gui[12] `%_GC 122 26`: `TopNodeKey
/// FORMNAME` between ABAPSelItemKey and ABAPSelItemName, the server holding
/// gui[7]'s `HDEFAULTS` (reference client 534a50c §1). Tracked like the selection.
const String topNodeKeyProp = 'TopNodeKey';

/// The SapTree node-key tables the server reads back (AssignProperty2
/// `ExpandedKeys` / `SelectionKeys`): the folders open and the nodes
/// selected on the client.
const String expandedKeysProp = 'ExpandedKeys';
const String selectionKeysProp = 'SelectionKeys';
const List<String> _trackedTreeProps = [...treeSelectionProps, topNodeKeyProp];

/// The SapTree property that keeps the selection on a right-click (the
/// property-put verb `DisableSelChngOnCxtMenuReq(=1)` on the tree object —
/// a recorded session srv[16] verb 336, a recorded session
/// srv[14…16] verb 135, a recorded session verb 330).
const String disableSelChangeVerb = 'DisableSelChngOnCxtMenuReq';

/// The context-menu facts of the answered flush calls: the menu pushes per
/// shell, the trees that keep their selection on a right-click, and the
/// selection values the server last learned per tree (from this client's
/// flushes, its own `ABAPSelectNode` / `RemoveSelections` verbs and the
/// control state the responder reported).
class ContextMenuTracker {
  /// shell -> the newest menu pushed for it.
  final Map<String, ContextMenuPush> pushes = {};

  /// Trees whose `DisableSelChngOnCxtMenuReq` is set.
  final Set<String> selectionKept = {};

  /// shell -> prop -> the value the server holds for it.
  final Map<String, Map<String, String>> selection = {};

  /// Fold one complete OLE_FLUSH_CALL [value]; returns the shells a menu
  /// was bound to. [shellOf] maps a client object handle to its shell;
  /// [segment] looks a push segment up by url (the session's DP cache) when
  /// the call's own RFC_QUEUE does not carry it. [parsed] = [value]
  /// already parsed. [trackShell] = the toolbar / grid a dropdown request
  /// in flight names: the owner of a toolbar menu verb whose object token
  /// maps to no shell.
  List<String> foldCall(
    Uint8List value, {
    String? Function(String handle)? shellOf,
    Uint8List? Function(String url)? segment,
    int? step,
    FlushCall? parsed,
    String? trackShell,
  }) {
    final call = parsed ?? parseFlushCall(value);
    if (call.verbs.isEmpty) return const [];
    final meta = verbMeta(call);
    DpCache? own;
    final rowUrl = <String, String>{};
    final rowShell = <String, String>{};
    String? pendingMenuUrl, lastUrl;
    final bound = <String>[];

    String? objShell(int i) {
      final m = meta[i - 1];
      final byRow = rowShell[m.obj.trim()];
      if (byRow != null) return byRow;
      final h = m.objValue.trim();
      if (h.isEmpty) return null;
      return shellOf?.call(h);
    }

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
          lastUrl = u;
          if ((named['#2'] ?? '').trim() == contextMenuFormat) {
            pendingMenuUrl = u;
          }
        }
      } else if (verb == 'CreateControl' || verb == 'CreateControl2') {
        final sh = (named['#1'] ?? '').trim();
        if (res.isNotEmpty && _digitsOnlyRx.hasMatch(sh)) rowShell[res] = sh;
      } else if (verb == setContextMenuVerb) {
        var shell = (named['#1'] ?? '').trim();
        var slot = (m.slots['#2'] ?? '').trim();
        if (!_digitsOnlyRx.hasMatch(shell)) {
          // the grid form: run on the grid object, #1 = the menu object
          // (a recorded session srv[20] v7 on handle 15)
          shell = objShell(i) ?? trackShell ?? '';
          slot = (m.slots['#1'] ?? '').trim();
        }
        final url = rowUrl[slot] ?? pendingMenuUrl ?? lastUrl;
        if (_digitsOnlyRx.hasMatch(shell) && url != null) {
          var seg = segment?.call(url);
          if (seg == null) {
            own ??= DpCache()..ingestValue(value);
            seg = own.byUrl[url];
          }
          final entries = seg == null
              ? const <SapMenuEntry>[]
              : decodeContextMenuPush(seg);
          if (entries.isNotEmpty) {
            pushes[shell] = ContextMenuPush(shell, url, entries, step);
            bound.add(shell);
          }
        }
        pendingMenuUrl = lastUrl = null;
      } else if (verb == disableSelChangeVerb) {
        final sh = objShell(i);
        final args = verbArgs(call, i);
        final v = args.isEmpty ? '' : args.first.$2.trim().toUpperCase();
        if (sh != null) {
          if (v == '1' || v == 'X' || v == 'TRUE') {
            selectionKept.add(sh);
          } else {
            selectionKept.remove(sh);
          }
        }
      } else if (_trackedTreeProps.contains(verb)) {
        // a property PUT of the selection on the tree object
        // (a recorded session srv[16] verb 171 `ABAPSelNodeKey`)
        final sh = objShell(i);
        final args = verbArgs(call, i);
        if (sh != null && args.isNotEmpty) {
          (selection[sh] ??= {})[verb] = args.first.$2;
        }
      } else if (verb == 'ABAPSelectNode' || verb == 'RemoveSelections') {
        // the server parks the selection itself (a recorded session
        // delete_save_realgui srv[16] / [31] / [48]: RemoveSelections +
        // ABAPSelectNode(#1=key, #2=item)) — the reference client's
        // record_tree_selection_verbs
        final sh = objShell(i);
        if (sh != null) {
          final key = verb == 'ABAPSelectNode'
              ? (named['#1'] ?? '').trim()
              : '';
          final item = verb == 'ABAPSelectNode'
              ? (named['#2'] ?? '').trim()
              : '';
          selection[sh] = {
            selNodeKeyProp: key,
            selItemKeyProp: key,
            selItemNameProp: key.isEmpty ? '' : item,
          };
        }
      }
      // the result row of a verb run on a url-derived row derives from it
      // (GetDataAsFormat -> data, automationObject / data -> the menu
      // object SetContextMenu #2 names)
      // (a row a later block reuses for a fresh object forgets its url)
      if (res.isNotEmpty) {
        final u = rowUrl[obj];
        if (u != null) {
          rowUrl[res] = u;
        } else {
          rowUrl.remove(res);
        }
        if (verb != 'CreateControl' && verb != 'CreateControl2') {
          rowShell.remove(res);
        }
      }
    }
    // a toolbar menu button's menu, opened in answer to its dropdown event:
    // `SetToolBarMenu(<menu>, x, y)` on the grid object, `TrackContextMenu(
    // <menu>, x, y)` on the toolbar (control_toolbar.dart)
    for (final v in toolbarMenuVerbsOf(call)) {
      if (v.isStatic) continue;
      // [trackShell]: the control whose dropdown this answers, when the
      // verb's object token maps to no shell (an offline replay whose
      // mints differ)
      final sh = rowShell[v.objRow] ?? shellOf?.call(v.handle) ?? trackShell;
      if (sh == null || !_digitsOnlyRx.hasMatch(sh)) continue;
      var seg = segment?.call(v.url);
      if (seg == null) {
        own ??= DpCache()..ingestValue(value);
        seg = own.byUrl[v.url];
      }
      final entries = seg == null
          ? const <SapMenuEntry>[]
          : decodeContextMenuPush(seg);
      if (entries.isEmpty) continue;
      pushes[sh] = ContextMenuPush(sh, v.url, entries, step, verb: v.verb);
      bound.add(sh);
    }
    // what the answer reports for the registered / read props (the
    // responder's controlXml: the server's own SetProperty value, else the
    // empty default) is what the server holds next
    for (final (sh, prop) in call.cachedProps) {
      if (!_trackedTreeProps.contains(prop)) continue;
      (selection[sh] ??= {})[prop] = call.setProps[(sh, prop)] ?? '';
    }
    return bound;
  }

  /// Record the selection props a client event flushed for [shell].
  void noteFlushed(String shell, List<(String, String)> props) {
    final s = selection[shell] ??= {};
    for (final (n, v) in props) {
      s[n] = v;
    }
  }

  /// Of [props], the ones whose value differs from what the server holds
  /// for [shell] (an unknown value counts as ''), compared trimmed — the
  /// server's ABAPSelectNode names a padded key trimmed.
  List<(String, String)> changed(String shell, List<(String, String)> props) {
    final s = selection[shell] ?? const {};
    return [
      for (final (n, v) in props)
        if ((s[n] ?? '').trim() != v.trim()) (n, v),
    ];
  }
}

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call (audit #7 / zcode P-12).
final RegExp _singleLetterRx = RegExp(r'^[A-Za-z]$');
final RegExp _digitsOnlyRx = RegExp(r'^\d{1,9}$');
