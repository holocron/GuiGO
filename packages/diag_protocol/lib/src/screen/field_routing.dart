/// The container plane a value write into a NESTED dynpro field travels —
/// a field on a tabstrip page (SXMB_MONI's RSSYSTDB/1000 page 0500), in a
/// CALL-SUBSCREEN chain, … — mirrored from the server's own declaration of
/// the paint (reference client engine/diag_container_tree.ContainerTree
/// .field_routing_split + raw_fields._nested_write_spec / _wrap_nested_items).
///
/// The server declares every container as a GROUP: a 16/10/1 OPEN, then the
/// group's legs (16/10/3 DESC, 16/10/8 CLOSE, 16/10/9 tabstrip PAGE, the
/// terminal 16/10/4 / 16/10/5 …, every one `level, top u16, left u16, cols
/// u16, rows u16`), its 16/10/6 NAMEs, and — right after a page leg — the
/// page's own 16/12/6 geometry. A field's atoms follow the group of the
/// container they live in. A write of such a field addressed like a main-
/// dynpro one (a bare 16/10/1 + a depth-1 16/9/11 `[area]`) is refused
/// "Données de saisie d'interface erronées : FOCUS DATA" (00 123) and the
/// kernel tears the transaction down; the reference client's accepted write
/// (a recorded session gui step 27) replays:
///
/// the tabstrip's group (its OPEN re-spelled as the window ROOT open,
/// its legs verbatim) + the tabstrip tree-names 16/9/15 in its SELECTED-
/// page echo form, the field's own group the same way, the page's
/// 16/12/6, the value atom, and a 16/9/11 whose container path is the
/// group's level bytes (`02 … 01 02` for RCVRPRTY — the server's own
/// repaint focus `03 … 01 02 00` without its trailing 0 area level).
library;

import 'dart:typed_data';

import 'table_controls.dart' show TcPlaneItem;

/// A field's write plane, resolved from its paint ([RoutingFrame.routingFor]).
class FieldRouting {
  FieldRouting({
    required this.pre,
    required this.path,
    this.scroll,
    this.rowOffset = 0,
    this.colOffset = 0,
  });

  /// The routing cluster sent in place of the flat 16/10/1, in wire order:
  /// 16/10 legs (each OPEN = the window root open) and the tabstrip 16/9/15
  /// echo (id 9, sid 15).
  final List<TcPlaneItem> pre;

  /// The field page's own 16/12/6, sent right before the value atom (null
  /// when the paint declares none).
  final Uint8List? scroll;

  /// The 16/9/11 container path (depth = its length).
  final List<int> path;

  /// The container chain's screen offset — the Java GUI's OK-event cursor
  /// rides it; a Windows field submit sends a 0/0 cursor.
  final int rowOffset;
  final int colOffset;
}

/// One declared container group of a paint frame.
class RoutingGroup {
  RoutingGroup(this.index);

  /// The group's position in its frame (declaration order).
  final int index;

  /// The group's legs as painted: the 16/10/1 OPEN and every 16/10/<sid>
  /// but the names (id 10), a 16/12/6 declared after a page leg (id 12).
  final List<TcPlaneItem> legs = [];
  String? name;

  Iterable<TcPlaneItem> get containerLegs => legs.where((l) => l.id == 10);

  /// The sid of the group's last leg after its OPEN (1 = a bare root).
  int get terminalSid {
    final l = containerLegs.where((l) => l.sid != 1);
    return l.isEmpty ? 1 : l.last.sid;
  }
}

/// The container declaration of ONE paint frame, folded item by item:
/// [open] / [leg] / [name] for the 16/10 items, [geometry] for every
/// 16/12/6, [window] for the 16/12/7, [treeNamesItem] for a tabstrip
/// 18/9/15. [routingFor] resolves a field's plane once the frame is done.
class RoutingFrame {
  final List<RoutingGroup> groups = [];
  RoutingGroup? get current => groups.isEmpty ? null : groups.last;
  final List<Uint8List> _geoms = [];
  Uint8List? _window;
  RoutingGroup? _treeNamesGroup;
  Uint8List? _treeNames;

  void open(Uint8List v) {
    _changed();
    groups.add(RoutingGroup(groups.length)..legs.add(TcPlaneItem(10, 1, v)));
  }

  void leg(int sid, Uint8List v) {
    _changed();
    current?.legs.add(TcPlaneItem(10, sid, v));
  }

  void name(String n) {
    _changed();
    final g = current;
    if (g != null && n.isNotEmpty) g.name ??= n;
  }

  void geometry(Uint8List v) {
    _changed();
    _geoms.add(v);
    // a page's geometry, in-chain: right after the group's 16/10/9 leg
    final legs = current?.containerLegs;
    if (legs != null && legs.isNotEmpty && legs.last.sid == 9) {
      current!.legs.add(TcPlaneItem(12, 6, v));
    }
  }

  void window(Uint8List v) {
    _changed();
    _window = v;
  }

  void treeNamesItem(Uint8List v) {
    _changed();
    _treeNames = v;
    _treeNamesGroup = current;
  }

  // The frame-level facts every field's [routingFor] reads — the root
  // open, the fallback scroll geometry (an O(geometries²) distinct scan),
  // each group's layer base — derived once per frame state, not once per
  // field (audit #15); any fold into the frame drops them.
  bool _rootKnown = false;
  Uint8List? _root;
  bool _scrollKnown = false;
  Uint8List? _lastDistinct;
  final Map<int, int> _layerBases = {};

  void _changed() {
    _rootKnown = false;
    _root = null;
    _scrollKnown = false;
    _lastDistinct = null;
    _layerBases.clear();
  }

  Uint8List? get _rootOnce {
    if (!_rootKnown) {
      _root = rootOpen;
      _rootKnown = true;
    }
    return _root;
  }

  /// The frame's last distinct 16/12/6 geometry when it paints several.
  Uint8List? get _fallbackScroll {
    if (!_scrollKnown) {
      final distinct = <Uint8List>[];
      for (final v in _geoms) {
        if (!distinct.any((d) => _same(d, v))) distinct.add(v);
      }
      _lastDistinct = distinct.length > 1 ? distinct.last : null;
      _scrollKnown = true;
    }
    return _lastDistinct;
  }

  /// The synthesized 16/10/1 root open: six zero bytes, the window root's
  /// handle (u16 LE) and kind — the "handle"/"kind" words of the paint's
  /// 16/12/6 geometry no routing leg references (reference client ContainerTree
  /// steps 2 / 2c / 2d: those words ARE the geometry's cols / rows — 40 x
  /// 268 on RSSYSTDB/1000 gives `000000000000 0c01 28`). Null when the
  /// paint declares no root geometry.
  Uint8List? get rootOpen {
    final referenced = <int>{};
    for (final g in groups) {
      for (final l in g.containerLegs) {
        if (l.sid != 1 && l.value.length >= 8) {
          referenced.add(l.value[6] | l.value[7] << 8);
        }
      }
    }
    final geoms = <(int, int)>[];
    for (final v in _geoms) {
      if (v.length < 32) continue;
      final bd = ByteData.sublistView(v);
      geoms.add((bd.getUint32(24), bd.getUint32(28) & 0xffff));
    }
    (int, int)? root;
    for (final g in geoms) {
      if (!referenced.contains(g.$2)) {
        root = g;
        break;
      }
    }
    final w = _window;
    if (root == null && w != null && w.length >= 16) {
      final bd = ByteData.sublistView(w);
      final win = (bd.getUint32(8), bd.getUint32(12) & 0xffff);
      if (geoms.contains(win)) root = win;
    }
    if (root == null) {
      final kinds = {
        for (final g in geoms)
          if (g.$1 == 0x1a) g,
      };
      if (kinds.length == 1) root = kinds.single;
    }
    if (root == null) return null;
    return Uint8List(9)
      ..[6] = root.$2 & 0xff
      ..[7] = root.$2 >> 8
      ..[8] = root.$1 & 0xff;
  }

  /// The write plane of a field of atom [area] painted after [group], or
  /// null when the field sits on the window root (no container level — the
  /// flat write) or the paint gives no root to open the plane with.
  FieldRouting? routingFor(RoutingGroup? group, int area) {
    if (group == null) return null;
    final chain = [
      for (final l in group.containerLegs)
        if (const {3, 8, 9, 4, 5}.contains(l.sid) &&
            l.value.isNotEmpty &&
            l.value[0] != 0)
          l.value[0],
    ];
    if (chain.isEmpty) return null;
    final root = _rootOnce;
    if (root == null) return null;
    final path = [...chain, area & 0xff];
    // the real GUI's nested path carries no trailing 0 (area) level
    if (path.length > 1 && path.last == 0) path.removeLast();

    // the OK cursor offset: every DESC / CLOSE / PAGE placement for an
    // area-0 field (or a plane ending in a 16/10/16 subscreen), only the
    // DESC placements for a field on its own area plane
    final terminal = group.terminalSid;
    final sids = area == 0 || terminal == 16 ? const {3, 8, 9} : const {3};
    var roff = 0, coff = 0;
    for (final l in group.containerLegs) {
      if (sids.contains(l.sid) && l.value.length >= 5) {
        roff += l.value[1] << 8 | l.value[2];
        coff += l.value[3] << 8 | l.value[4];
      }
    }

    // the tabstrip's group wraps the field's (the field's group goes last,
    // innermost before the atom), within the field's own layer: the groups
    // from the last bare unnamed root before it
    final layerBase = _layerBases[group.index] ??= () {
      var base = 0;
      for (final g in groups) {
        if (g.index < group.index && g.name == null && g.terminalSid == 1) {
          base = g.index;
        }
      }
      return base;
    }();
    final tn = _treeNamesGroup;
    final order = [
      if (tn != null && tn != group && tn.index >= layerBase) tn,
      group,
    ];
    final pre = <TcPlaneItem>[];
    for (final g in order) {
      for (final l in g.containerLegs) {
        pre.add(l.sid == 1 ? TcPlaneItem(10, 1, root) : l);
      }
      final names = _treeNames;
      if (g == tn && names != null) {
        pre.add(TcPlaneItem(9, 15, tabstripSelectedEcho(names)));
      }
    }

    // the page's own 16/12/6 (declared after the group's page leg), else
    // the frame's last distinct geometry when it paints several
    Uint8List? scroll;
    final own = group.legs.where((l) => l.id == 12);
    if (own.isNotEmpty) {
      scroll = own.last.value;
    } else {
      scroll = _fallbackScroll;
    }
    return FieldRouting(
      pre: pre,
      path: path,
      scroll: scroll,
      rowOffset: roff,
      colOffset: coff,
    );
  }
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The 16/9/15 tabstrip tree-names item as the client echoes it on a field
/// write (reference client raw_fields._tabstrip_selected_echo): `… [28:30] 00 3f
/// [30:32] u16 L, name\0 prev\0 cur\0`. A first paint carries an EMPTY
/// `prev`; the write re-spells it `prev = cur` and grows L by cur's length
/// (RSSYSTDB/1000: `003f 0040 TABSTRIP_TABSTRIP…\0 \0 'STRD'\0` →
/// `003f 0046 …\0 'STRD'\0 'STRD'\0`). Anything else is echoed verbatim.
Uint8List tabstripSelectedEcho(Uint8List v) {
  if (v.length < 33 || v[28] != 0x00 || v[29] != 0x3f) return v;
  final parts = <List<int>>[[]];
  for (final b in v.sublist(32)) {
    if (b == 0) {
      parts.add([]);
    } else {
      parts.last.add(b);
    }
  }
  if (parts.length != 4 ||
      parts[3].isNotEmpty ||
      parts[0].isEmpty ||
      parts[1].isNotEmpty ||
      parts[2].isEmpty) {
    return v;
  }
  final cur = parts[2];
  final word = (v[30] << 8 | v[31]) + cur.length;
  if (word > 0xffff) return v;
  return Uint8List.fromList([
    ...v.sublist(0, 30),
    word >> 8,
    word & 0xff,
    ...parts[0],
    0,
    ...cur,
    0,
    ...cur,
    0,
  ]);
}

/// The SAP GUI for WINDOWS' 16/9/15 tabstrip state on a field write, from
/// the client echo ([tabstripSelectedEcho]): the server's [0:16] geometry
/// words, its per-tabstrip state words [16:28] ZEROED, [28:30] = the
/// server's [26:28] word, [30:32] = 32 + the first entry's length + its
/// NUL, then the page entries WITHOUT the 30-char tabstrip name (reference client
/// mode_envelope.windows_tree_names; a recorded session
/// wingui g15: `… 0020 0025 '0530' 00 '0570' 00`, 42 bytes, from the
/// paint's `… 0020 003f 0044 G_TABSTRIP… 00 '0530' 00 '0570' 00`). Echoed
/// verbatim when shorter than the name-carrying form.
Uint8List windowsTabstripState(Uint8List echo) {
  const entriesOff = 32 + 30 + 1; // past the tabstrip name and its NUL
  if (echo.length < entriesOff) return echo;
  final entries = echo.sublist(entriesOff);
  var first = entries.indexOf(0);
  if (first < 0) first = entries.length;
  final len = 32 + first + 1;
  return Uint8List.fromList([
    ...echo.sublist(0, 16),
    ...List.filled(12, 0),
    echo[26],
    echo[27],
    len >> 8 & 0xff,
    len & 0xff,
    ...entries,
  ]);
}
