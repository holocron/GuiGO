/// SAP tree controls (Easy Access menu, SapTree / TableTreeControl): the
/// node and item tables the server pushes through the DataProvider
/// (DP_PUT_CLIENT_TABLE45A rows in an OLE call's RFC_QUEUE), decoded into a
/// node tree for rendering.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../cfw/dp_cache.dart';

/// One DP table decoded by its own FORMAT descriptor, with real column names.
class DpTable {
  DpTable(this.name, this.columns, this.rows,
      {this.lengths = const [], this.types = const []});

  /// The DDIC structure the FORMAT names (`TREEV_NODE`, `SBJTREEITM`, …).
  final String name;
  final List<String> columns;
  final List<Map<String, String>> rows;

  /// Per column (same order as [columns], empty when unknown): the field's
  /// byte length and ABAP type letter code (`C` 67, `I` 73, …) from FORMAT.
  final List<int> lengths;
  final List<int> types;
}

/// Decode a DP push whose FORMAT names its structure and columns (80-byte
/// descriptor records: structure name [0:30], column [30:60], then LE u32
/// index / offset / length / – / ABAP type letter). Types: `C` (67) text,
/// `I` (73) 4-byte LE integer, `s` (115) 2-byte LE integer, `N` (78)
/// numeric text; anything else is read as text. Null when the push carries
/// no named FORMAT or no DATAASC rows.
DpTable? decodeNamedDpTable(Uint8List seg) {
  final (_, (fw, fn), fcells) = dpColumnCells(seg, 'FORMAT');
  final fmt = _join(fcells);
  if (fw != _fmtRecord || fn <= 0 || fmt.length < fw * fn) return null;
  final bd = fmt.buffer.asByteData(fmt.offsetInBytes, fmt.lengthInBytes);
  String? table;
  final cols = <_Col>[];
  for (var i = 0; i < fn; i++) {
    final o = i * fw;
    final structure = _ascii(fmt, o, o + 30);
    final column = _ascii(fmt, o + 30, o + 60);
    if (column.isEmpty) return null;
    table ??= structure;
    cols.add(_Col(column, bd.getUint32(o + 64, Endian.little),
        bd.getUint32(o + 68, Endian.little), bd.getUint32(o + 76, Endian.little)));
  }
  if (table == null || table.isEmpty) return null;

  final names = [for (final c in cols) c.name];
  final lengths = [for (final c in cols) c.length];
  final types = [for (final c in cols) c.type];
  final (_, (dw, dn), dcells) = dpColumnCells(seg, 'DATAASC');
  final data = _join(dcells);
  if (dw <= 0 || dn <= 0) {
    return DpTable(table, names, const [], lengths: lengths, types: types);
  }
  final rows = <Map<String, String>>[];
  for (var r = 0; r < dn && (r + 1) * dw <= data.length; r++) {
    final rec = Uint8List.sublistView(data, r * dw, (r + 1) * dw);
    rows.add({
      for (final c in cols) c.name: _field(rec, c),
    });
  }
  return DpTable(table, names, rows, lengths: lengths, types: types);
}

const int _fmtRecord = 80;

class _Col {
  _Col(this.name, this.offset, this.length, this.type);
  final String name;
  final int offset;
  final int length;
  final int type;
}

String _field(Uint8List rec, _Col c) {
  final end = c.offset + c.length;
  if (c.offset >= rec.length) return '';
  final raw = Uint8List.sublistView(rec, c.offset, end > rec.length ? rec.length : end);
  final bd = raw.buffer.asByteData(raw.offsetInBytes, raw.lengthInBytes);
  switch (c.type) {
    case 0x49: // 'I'
      return raw.length >= 4 ? bd.getInt32(0, Endian.little).toString() : '';
    case 0x73: // 's'
      return raw.length >= 2 ? bd.getInt16(0, Endian.little).toString() : '';
    default:
      var n = raw.length;
      while (n > 0 && (raw[n - 1] == 0 || raw[n - 1] == 0x20)) {
        n--;
      }
      return utf8.decode(Uint8List.sublistView(raw, 0, n), allowMalformed: true);
  }
}

Uint8List _join(List<Uint8List> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

String _ascii(Uint8List b, int start, int end) =>
    String.fromCharCodes(b, start, end > b.length ? b.length : end).trim();

// ---------------------------------------------------------------------------
// Tree model
// ---------------------------------------------------------------------------

/// The RELATSHIP codes ON THE WIRE — the frontend's node relations
/// (sapTreeS.jar ABAPINodeRelations; NodeFactory.insertNode's tableswitch,
/// the reference client's ea_treeorder / raw_tree), not the ABAP class constants
/// (CL_TREE_CONTROL_BASE relat_first_sibling = 1 … relat_last_child = 6,
/// which the ABAP layer maps): 0 and 6 append the node to its RELATKEY's
/// children, 4 inserts it as their first; 1 / 2 / 3 / 5 place it beside
/// RELATKEY (last / next / previous / first sibling). Real SAP GUI for
/// Windows wire, SE80's object list (a recorded session srv[14],
/// a recorded session srv raw[107] / raw[117]): the object `1` with
/// RELATKEY blank, its first category `2` (RELATKEY 1, RELATSHIP 4 — its
/// first CHILD), the next categories RELATKEY 2 / 3 / 4 … RELATSHIP 2
/// (each the NEXT sibling of the one before), the expanded "Dynpros" `9`'s
/// screen `14` (RELATKEY 9, RELATSHIP 4). Read with the ABAP constants
/// (4 = next sibling, 5 = first child) SE80's tree was flat: every node a
/// root.
const int relatNone = 0;
const int relatLastSibling = 1;
const int relatNextSibling = 2;
const int relatPrevSibling = 3;
const int relatFirstChild = 4;
const int relatFirstSibling = 5;
const int relatLastChild = 6;

/// Whether [t] is a tree UPDATE push — `UpdateR3Table` / `UpdateItemTable`
/// (TREEV_UNOD / TREEV_UITM: the node / item columns plus their `U_*`
/// change flags): a change MASK over nodes the tree already holds, never
/// a rowset of its own (the reference client's gridread_ingest skips it). Its rows
/// carry no relation (RELATKEY blank, RELATSHIP 0): read as a node table
/// it looked like a NEW tree (a recorded session srv raw[117], the
/// expansion of SE80's "Dynpros" `9`: `UpdateR3Table` 9 with U_ALL = X,
/// then `AddR3Table` its screen `14`) — the object list was dropped and
/// `9` left alone, with no text (the live iPad's lone " 9").
bool isTreeUpdateTable(DpTable t) => t.columns.any((c) => c.startsWith('U_'));

/// One item of a tree node — a column tree's cell (LVC_S_ITEM / TREEV_ITEM
/// / STREEITM rows: NODE_KEY, ITEM_NAME, CLASS, T_IMAGE, TEXT, …). The
/// /AIF/IFMON overview's root (a recorded session raw srv[20]): item
/// `C 10` CLASS 0 with T_IMAGE `@0A\QFeu rouge ; stop ; erroné@`
/// (the status light), `C 20` CLASS 5 (a LINK: the real GUI's
/// click on it is LINKCLICK 35, raw gui[116]) with `@3Z\QTous les
/// messages@` and TEXT `420099`.
class SapTreeItem {
  SapTreeItem(this.name);

  /// The ITEM_NAME (the column it sits in; `&Hierarchy` for the node text).
  final String name;

  /// CLASS: the item's kind (CL_ITEM_TREE_CONTROL item_class_*): 2 text
  /// (0 on the ALV tree's wire: the default, text), 3 checkbox, 4 button,
  /// 5 link.
  int itemClass = 0;
  String text = '';

  /// T_IMAGE: an `@xx@` icon, optionally with its quick info (`\Q…`).
  String image = '';
  bool disabled = false;
  bool hidden = false;
  bool editable = false;

  /// CHOSEN: a checkbox item's state.
  bool chosen = false;
  int font = 0;
  int style = 0;
  int alignment = 0;

  /// TXTISQINFO: the text is the item's quick info, not drawn.
  bool textIsQuickInfo = false;

  static const int classText = 2;
  static const int classCheckbox = 3;
  static const int classButton = 4;
  static const int classLink = 5;

  bool get isLink => itemClass == classLink;
  bool get isButton => itemClass == classButton;
  bool get isCheckbox => itemClass == classCheckbox;

  /// The icon code of [image] (`3Z` of `@3Z\QTous les messages@`), null
  /// when it has none.
  String? get iconCode => iconCodeOf(image);

  /// The quick info [image] carries (`Tous les messages`), '' for none.
  String get quickInfo => iconQuickInfoOf(image);

  @override
  String toString() => 'SapTreeItem($name, class $itemClass, "$text", $image)';
}

final RegExp _iconRx = RegExp(r'^@([0-9A-Za-z]{1,2})(?:\\Q([^@]*))?@?');

/// The icon code of an `@xx@` / `@xx\Q<quick info>@` token, null for none.
String? iconCodeOf(String image) => _iconRx.firstMatch(image.trim())?.group(1);

/// The quick info of an `@xx\Q<quick info>@` token, '' for none.
String iconQuickInfoOf(String image) =>
    _iconRx.firstMatch(image.trim())?.group(2)?.trim() ?? '';

class SapTreeNode {
  SapTreeNode(this.key);

  final String key;
  String? parentKey;
  bool isFolder = false;

  /// the node has children on the server that were not pushed yet
  /// (EXPANDER = 'X'): expanding it needs a server round
  bool expander = false;
  bool hidden = false;
  bool disabled = false;
  String text = '';

  /// The node's icons (TREEV_NODE N_IMAGE / EXP_IMAGE: an `@xx@` code,
  /// '' for the front end's default folder / leaf image) and STYLE.
  String image = '';
  String expandedImage = '';
  int style = 0;

  /// the other item texts (column trees: ITEM_NAME -> TEXT), item '1' first
  final Map<String, String> items = {};

  /// The node's items in full (a column tree's cells: ITEM_NAME -> the
  /// item's class, text, icon, flags), in arrival order — [items] keeps
  /// their texts.
  final Map<String, SapTreeItem> cells = {};
  final List<SapTreeNode> children = [];

  bool get hasChildren => children.isNotEmpty || expander;

  @override
  String toString() => 'SapTreeNode($key, "$text", ${children.length} children)';
}

/// The node tree of one tree control, built from its TREEV_NODE /
/// SBJTREEITM (or other *ITM) pushes in arrival order.
class SapTreeModel {
  final Map<String, SapTreeNode> nodes = {};
  final List<SapTreeNode> roots = [];

  bool get isEmpty => nodes.isEmpty;

  /// Fold one decoded DP table in: node tables (a NODE_KEY + RELATKEY
  /// pair) add or update nodes; item tables (NODE_KEY + ITEM_NAME + TEXT)
  /// set texts; an update push ([isTreeUpdateTable]) changes the flagged
  /// fields of nodes already held. Unknown tables are ignored. Returns
  /// whether it applied.
  bool apply(DpTable t) {
    if (isTreeUpdateTable(t) && t.columns.contains('NODE_KEY')) {
      _applyUpdate(t);
      return true;
    }
    if (t.columns.contains('RELATKEY') && t.columns.contains('NODE_KEY')) {
      for (final r in t.rows) {
        _addNode(r);
      }
      return true;
    }
    if (t.columns.contains('ITEM_NAME') && t.columns.contains('TEXT')) {
      for (final r in t.rows) {
        final n = nodes[r['NODE_KEY'] ?? ''];
        if (n == null) continue;
        final item = r['ITEM_NAME'] ?? '';
        final text = r['TEXT'] ?? '';
        n.items[item] = text;
        if (item == '1' || n.text.isEmpty) n.text = text;
        final c = n.cells[item] ??= SapTreeItem(item);
        _setItem(c, r, (_) => true);
      }
      return true;
    }
    return false;
  }

  /// An `UpdateR3Table` / `UpdateItemTable` row changes what its `U_*`
  /// flags name (`U_ALL`: every field) of a node the tree holds; a row of
  /// an unknown node is dropped (the control has nothing to update).
  void _applyUpdate(DpTable t) {
    final items = t.columns.contains('ITEM_NAME');
    for (final r in t.rows) {
      final n = nodes[r['NODE_KEY'] ?? ''];
      if (n == null) continue;
      final all = r['U_ALL'] == 'X';
      bool changes(String flag) => all || r[flag] == 'X';
      if (items) {
        final item = r['ITEM_NAME'] ?? '';
        // the item's other flagged fields (its icon, its flags): an update
        // without U_TEXT changes them and keeps the text
        final cell = n.cells[item] ??= SapTreeItem(item);
        _setItem(cell, r, (f) => all || r[f] == 'X', text: false);
        if (!changes('U_TEXT') || !t.columns.contains('TEXT')) continue;
        final text = r['TEXT'] ?? '';
        final was = n.items[item];
        n.items[item] = text;
        cell.text = text;
        // the node's label is its first item's text (item '1', a column
        // tree's hierarchy column): follow it when it is that item
        if (item == '1' || n.text.isEmpty || n.text == was) n.text = text;
        continue;
      }
      if (changes('U_HIDDEN')) n.hidden = r['HIDDEN'] == 'X';
      if (changes('U_DISABLED')) n.disabled = r['DISABLED'] == 'X';
      if (changes('U_ISFOLDER')) n.isFolder = r['ISFOLDER'] == 'X';
      if (changes('U_EXPANDER')) n.expander = r['EXPANDER'] == 'X';
      if (changes('U_N_IMAGE') && r.containsKey('N_IMAGE')) {
        n.image = r['N_IMAGE'] ?? '';
      }
      // (the U_ flag's name is cut to 10 characters on the wire)
      if ((changes('U_EXP_IMAG') || changes('U_EXP_IMAGE')) &&
          r.containsKey('EXP_IMAGE')) {
        n.expandedImage = r['EXP_IMAGE'] ?? '';
      }
      if (changes('U_STYLE') && r.containsKey('STYLE')) {
        n.style = int.tryParse(r['STYLE'] ?? '') ?? 0;
      }
    }
  }

  /// The fields row [r] carries for item [c] — those [changes] (an update
  /// row's U_* flags; every field of an add) names; the TEXT only when
  /// [text]. CLASS has no update flag: an update keeps it.
  static void _setItem(
    SapTreeItem c,
    Map<String, String> r,
    bool Function(String flag) changes, {
    bool text = true,
  }) {
    bool flag(String f) => r[f] == 'X';
    int number(String f) => int.tryParse((r[f] ?? '').trim()) ?? 0;
    final add = !r.keys.any((k) => k.startsWith('U_'));
    if (add && r.containsKey('CLASS')) c.itemClass = number('CLASS');
    if (text && r.containsKey('TEXT')) c.text = r['TEXT'] ?? '';
    if (r.containsKey('T_IMAGE') && changes('U_T_IMAGE')) {
      c.image = r['T_IMAGE'] ?? '';
    }
    if (r.containsKey('DISABLED') && changes('U_DISABLED')) {
      c.disabled = flag('DISABLED');
    }
    if (r.containsKey('HIDDEN') && changes('U_HIDDEN')) c.hidden = flag('HIDDEN');
    if (r.containsKey('EDITABLE') && changes('U_EDITABLE')) {
      c.editable = flag('EDITABLE');
    }
    if (r.containsKey('CHOSEN') && changes('U_CHOSEN')) c.chosen = flag('CHOSEN');
    if (r.containsKey('FONT') && changes('U_FONT')) c.font = number('FONT');
    if (r.containsKey('STYLE') && changes('U_STYLE')) c.style = number('STYLE');
    // (U_ALIGNMEN: the flag's name cut to 10 characters)
    if (r.containsKey('ALIGNMENT') &&
        (changes('U_ALIGNMEN') || changes('U_ALIGNMENT'))) {
      c.alignment = number('ALIGNMENT');
    }
    if (add && r.containsKey('TXTISQINFO')) {
      c.textIsQuickInfo = flag('TXTISQINFO');
    }
  }

  void _addNode(Map<String, String> r) {
    final key = r['NODE_KEY'] ?? '';
    if (key.isEmpty) return;
    final existing = nodes[key];
    final n = existing ?? SapTreeNode(key);
    n
      ..isFolder = r['ISFOLDER'] == 'X'
      ..expander = r['EXPANDER'] == 'X'
      ..hidden = r['HIDDEN'] == 'X'
      ..disabled = r['DISABLED'] == 'X'
      ..image = r['N_IMAGE'] ?? ''
      ..expandedImage = r['EXP_IMAGE'] ?? ''
      ..style = int.tryParse(r['STYLE'] ?? '') ?? 0;
    if (existing != null) return; // a re-push updates flags, keeps placement
    nodes[key] = n;

    final relKey = r['RELATKEY'] ?? '';
    final rel = int.tryParse(r['RELATSHIP'] ?? '') ?? relatLastChild;
    final relNode = relKey.isEmpty ? null : nodes[relKey];
    if (relNode == null) {
      roots.add(n);
      _placed(roots, n, roots.length - 1);
      return;
    }
    switch (rel) {
      case relatFirstChild:
        n.parentKey = relNode.key;
        relNode.children.insert(0, n);
        relNode.expander = false;
        _placed(relNode.children, n, 0);
      case relatLastChild || relatNone:
        n.parentKey = relNode.key;
        relNode.children.add(n);
        relNode.expander = false;
        _placed(relNode.children, n, relNode.children.length - 1);
      default:
        // sibling relations: same parent as the related node
        n.parentKey = relNode.parentKey;
        final list = relNode.parentKey == null
            ? roots
            : nodes[relNode.parentKey]!.children;
        final at = _indexIn(list, relNode);
        final int to;
        switch (rel) {
          case relatFirstSibling:
            to = 0;
          case relatPrevSibling:
            to = at < 0 ? 0 : at;
          case relatNextSibling:
            to = at < 0 ? list.length : at + 1;
          default: // relatLastSibling and unknown
            to = list.length;
        }
        list.insert(to, n);
        _placed(list, n, to);
    }
  }

  // Where the last node was placed (its list and index; nothing moved it
  // since — every insertion re-records it). A sibling chain names the node
  // placed just before (SE80's categories: RELATKEY 2 / 3 / 4 …, NEXT
  // sibling): its index is known without a scan, where `indexOf` per node
  // made a k-sibling build O(k²) (audit #4).
  List<SapTreeNode>? _lastList;
  SapTreeNode? _lastNode;
  int _lastIndex = -1;

  void _placed(List<SapTreeNode> list, SapTreeNode n, int at) {
    _lastList = list;
    _lastNode = n;
    _lastIndex = at;
  }

  int _indexIn(List<SapTreeNode> list, SapTreeNode node) {
    if (identical(list, _lastList) &&
        identical(node, _lastNode) &&
        _lastIndex < list.length &&
        identical(list[_lastIndex], node)) {
      return _lastIndex;
    }
    return list.indexOf(node);
  }
}
