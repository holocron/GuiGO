/// The 18/11/<sid> MNUENTRY packets: the menu bar (sid 1), the dropdown
/// tree (sid 2), the application toolbar (sid 3) and the function keys
/// (sid 4). Port of pysap SAPDiagMenuEntry / SAPDiagMenuEntries as the
/// reference client reads them ( `_menu_entry`,
/// `menu_entry_active`).
library;

import 'dart:typed_data';

import '../codepages.dart';

/// One painted menu / toolbar / function-key entry.
class MenuEntry {
  MenuEntry({
    required this.position,
    required this.vkey,
    this.fcode = '',
    this.text = '',
    this.tooltip = '',
    this.accel = '',
    this.separator = false,
    this.submenu = false,
    this.active = true,
  });

  /// The entry's position path (pysap position_1..4): the toolbar slot, or
  /// the menu path (top-level index, item, sub-item, …).
  final List<int> position;

  /// The virtual key the entry fires (pysap virtual_key; return_code_1
  /// mirrors it). Press it with `pressItems(ctx, vkey)`.
  final int vkey;

  /// pysap function_code_1..6 (usually empty — entries fire by vkey).
  final String fcode;

  /// The label. Toolbar entries are often a bare icon code (`@15@`); the
  /// readable name is then in [tooltip].
  final String text;

  /// pysap `info`: the quick-info text (the toolbar button's tooltip).
  final String tooltip;

  /// pysap `accelerator` (e.g. `Ctrl+F1`), often empty.
  final String accel;

  /// flag_TERM_SEP: a separator (toolbar gap / menu rule), not an action.
  final bool separator;

  /// flag_TERM_MEN: opens a submenu.
  final bool submenu;

  /// flag_TERM_SEL: the function is selectable in the current PF-status.
  /// A clear bit is a GREYED entry the real GUI never fires (the kernel
  /// answers such a press "Le code de fonction ne peut pas être
  /// sélectionné") — reference client screen_util.menu_entry_active.
  final bool active;

  /// The entry's menu path: its non-zero positions (`an address` -> `[5, 3,
  /// 4]`), the levels a menu-position click names (reference client
  /// diag_reference._resolve_menu_entry: depth = the count of non-zero
  /// positions).
  List<int> get path => [
    for (final p in position)
      if (p != 0) p,
  ];

  @override
  String toString() =>
      'MenuEntry(vkey $vkey, ${text.isEmpty ? '' : '"$text" '}'
      '${tooltip.isEmpty ? '' : '[$tooltip] '}'
      '${active ? '' : 'greyed '}${separator ? 'sep ' : ''}'
      '${submenu ? 'submenu ' : ''}pos ${position.join('.')})';
}

/// The virtual key of a menu entry bound to no function key (pysap
/// virtual_key 100 — the reference client's former `F100`): it fires by position only.
const int menuNoKey = 100;

/// The entries of the dropdown [tree] (18/11/2) one level under [parent] —
/// a menu-bar header's path (`[5]`) or a submenu's (`[5, 3]`) — in paint
/// order (reference client diag_reference._menu_children). Separators are kept when
/// [separators] (a menu draws them as rules); textless non-separator
/// entries never are. An entry with children is a SUBMENU the real GUI
/// opens client-side, never one it fires.
List<MenuEntry> menuChildren(
  List<MenuEntry> tree,
  List<int> parent, {
  bool separators = true,
}) {
  final depth = parent.length;
  if (depth == 0 || depth >= 4) return const [];
  bool under(MenuEntry e) {
    final p = e.position;
    // a hand-built entry may carry fewer than the wire's four levels: the
    // missing ones are 0 (never a RangeError)
    int at(int i) => i < p.length ? p[i] : 0;
    for (var i = 0; i < depth; i++) {
      if (at(i) != parent[i]) return false;
    }
    if (at(depth) == 0) return false;
    for (var i = depth + 1; i < 4; i++) {
      if (at(i) != 0) return false;
    }
    return true;
  }

  return [
    for (final e in tree)
      if (under(e) && (e.separator ? separators : e.text.isNotEmpty)) e,
  ];
}

// pysap SAPDiagMenuEntry flag bits (the byte after position_1..4)
const int _flagSel = 0x02; // flag_TERM_SEL
const int _flagMen = 0x04; // flag_TERM_MEN
const int _flagSep = 0x08; // flag_TERM_SEP

/// The fixed head of one entry: length u16 BE, position_1..4, flags,
/// virtual_key, return_code_1..6, function_code_1..6.
const int _entryHead = 20;

/// Parse a SAPDiagMenuEntries value: a run of entries, each
/// `length u16 BE` (the WHOLE entry, head included) + the fixed fields +
/// three NUL-terminated strings (text, accelerator, info). The declared
/// length bounds each entry (pysap reads the strings unbounded and lets the
/// next entry start where they end — identical on well-formed packets).
List<MenuEntry> parseMenuEntries(Uint8List v) {
  final out = <MenuEntry>[];
  var off = 0;
  while (off + _entryHead <= v.length) {
    final len = (v[off] << 8) | v[off + 1];
    final end = len >= _entryHead && off + len <= v.length
        ? off + len
        : v.length;
    final flags = v[off + 6];
    final fcode = _zeroTrim(Uint8List.sublistView(v, off + 14, off + 20));
    var p = off + _entryHead;
    String next() {
      var q = p;
      while (q < end && v[q] != 0) {
        q++;
      }
      final s = wireDecode(Uint8List.sublistView(v, p, q)).trimRight();
      p = q < end ? q + 1 : end;
      return s;
    }

    final text = next();
    final accel = next();
    final info = next();
    out.add(
      MenuEntry(
        position: [v[off + 2], v[off + 3], v[off + 4], v[off + 5]],
        vkey: v[off + 7],
        fcode: fcode,
        text: text,
        accel: accel,
        tooltip: info,
        separator: flags & _flagSep != 0,
        submenu: flags & _flagMen != 0,
        active: flags & _flagSel != 0,
      ),
    );
    if (len < _entryHead) break; // undeclared length: one entry, no walk
    off += len;
  }
  return out;
}

String _zeroTrim(Uint8List b) {
  final bytes = [
    for (final x in b)
      if (x != 0) x,
  ];
  if (bytes.isEmpty) return '';
  return wireDecode(Uint8List.fromList(bytes)).trim();
}
