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

/// CL_TREE_CONTROL_BASE relationship constants (the RELATSHIP column).
const int relatFirstSibling = 1;
const int relatLastSibling = 2;
const int relatPrevSibling = 3;
const int relatNextSibling = 4;
const int relatFirstChild = 5;
const int relatLastChild = 6;

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

  /// the other item texts (column trees: ITEM_NAME -> TEXT), item '1' first
  final Map<String, String> items = {};
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
  /// set texts. Unknown tables are ignored. Returns whether it applied.
  bool apply(DpTable t) {
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
      }
      return true;
    }
    return false;
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
      ..disabled = r['DISABLED'] == 'X';
    if (existing != null) return; // a re-push updates flags, keeps placement
    nodes[key] = n;

    final relKey = r['RELATKEY'] ?? '';
    final rel = int.tryParse(r['RELATSHIP'] ?? '') ?? relatLastChild;
    final relNode = relKey.isEmpty ? null : nodes[relKey];
    if (relNode == null) {
      roots.add(n);
      return;
    }
    switch (rel) {
      case relatFirstChild:
        n.parentKey = relNode.key;
        relNode.children.insert(0, n);
        relNode.expander = false;
      case relatLastChild:
        n.parentKey = relNode.key;
        relNode.children.add(n);
        relNode.expander = false;
      default:
        // sibling relations: same parent as the related node
        n.parentKey = relNode.parentKey;
        final list = relNode.parentKey == null
            ? roots
            : nodes[relNode.parentKey]!.children;
        final at = list.indexOf(relNode);
        switch (rel) {
          case relatFirstSibling:
            list.insert(0, n);
          case relatPrevSibling:
            list.insert(at < 0 ? 0 : at, n);
          case relatNextSibling:
            list.insert(at < 0 ? list.length : at + 1, n);
          default: // relatLastSibling and unknown
            list.add(n);
        }
    }
  }
}
