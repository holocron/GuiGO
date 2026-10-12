/// Graphical designer canvases — the net-plan / join-designer canvas of
/// `SAP.BWAdapter.1` (wdbdadpt.ocx) and its `ICDATAFLOW.ICDataFlowCtrl.1`
/// (ICDataFlow.ocx) sibling: RSNPG_TEST_NETPLAN1 (SAPLRSNETGRAPHICTEST/0200),
/// the SQVI join designer (SAPLAQJD_CNTRL/0200), SQ02 InfoSet joins (read
/// side; the drag & drop / connect frames live in the session).
///
/// Wire shape (real SAP GUI for Windows — a recorded session
/// srv[5..8], a recorded session srv[7..10], a recorded session):
/// * the screen's creation wave creates BOTH controls in one container
/// (`CreateControl(122, ICDATAFLOW.ICDataFlowCtrl.1, …, 120)` and
/// `CreateControl(123, SAP.BWAdapter.1, …, 120)`); the ICDataFlow shell
/// registers the OCX events (`RegisterOcxEvent(122, 1048576)` = the link
/// commit `OnNewLinkCreated`), the BWAdapter shell only the drop
/// (`RegisterEvent(123, 15)`) and gets its drag & drop behaviour handle
/// by the property verb `DragDropHandle = 2`;
/// * the canvas content rides NAMED automation properties of the BWAdapter
/// object: each one a fresh `X-R3TABLE` DataProvider push bound by
/// `AssignProperty2(<dp>, 'r3TableAutoObj', <handle>, '<Property>')` —
/// `Tables` (one table's rows), `Meta` (that table's object records),
/// `LINKS` (one row per link), `Positions` (empty on every recorded
/// canvas). A table arrives as a `Tables` push immediately followed by
/// its `Meta` push.
///
/// The FORMAT descriptors name no columns (X-UNKNOWN), so every value is
/// reported positionally (`col_N` = the N-th FORMAT field, 0-based); the
/// meanings this reader relies on are pinned by the captures:
/// * Meta `col_0` = the table's object id, `col_1` = the row object id
/// (0 = the table's own records), `col_2` = the column index (0 = the
/// row/table record itself). The distinct non-zero `col_1` values, in
/// push order, number the paired `Tables` rows positionally (table 12:
/// ids 13..22 <-> its 10 rows). Pinned by the drop oracle: OBJID 15 (the
/// real GUI's target bag) is table 12's 3rd row `AGGRFILL | DTP_LOAD`,
/// and the connect oracle's PARAM1/PARAM2 3 / 46 / 15 are row ids of the
/// same id space, echoed back as LINKS `col_1`/`col_2`.
/// * the table header record (`col_1` = 0, `col_2` = 0): `col_12` = the
/// table's caption text (the label used here; the reference client's
/// canvas_nodes reads the same field as the table name), `col_13` = a
/// second text (the DDIC name on the recorded tables — `RSPCTYPESPROC`
/// beside table 1's long umlaut caption). `col_7..col_10` read as
/// x / y / width / height ONLY when non-zero — an inference, NOT pinned
/// by an oracle: the SQVI join designer pushes MARA at 50 / 50 / 250 /
/// 200 and MAKT at 307 / 7 / 250 / 200 (two tables, same box size,
/// distinct origins), while the net-plan test pushes zeros and then
/// calls `ArrangeShapes` (the control lays itself out). Unit unknown.
/// * LINKS `col_0` = link id, `col_1` = source object id, `col_2` =
/// destination object id (the connect oracle's delta row `63 | 3 | 15`
/// echoes PARAM1/PARAM2 exactly). LINKS pushes are UNIONed per canvas:
/// a link draw answers with a ONE-ROW delta (a recorded session
/// srv[14]), not a snapshot.
/// A `Tables`+`Meta` pair re-delivering a table id the canvas already holds
/// REPLACES that table (the reference client's complaint-netplan-table-regen-union).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../cfw/dp_cache.dart';
import '../cfw/flush_call.dart';
import '../cfw/rfc_cells.dart';
import '../lzh/lzh.dart';
import 'sap_tree.dart';

/// One node of a canvas: a table (`type == 'table'`) or one of its rows
/// (`type == 'row'`). [id] is the canvas object id — what a drop's OBJID,
/// a link's endpoints and [CanvasLink.from]/[CanvasLink.to] name.
class CanvasNode {
  CanvasNode({
    required this.id,
    required this.label,
    required this.type,
    this.parent,
    this.x,
    this.y,
    this.w,
    this.h,
    Map<String, String>? extra,
  }) : extra = extra ?? {};

  String id;

  /// A table: its header caption (Meta header `col_12`, else `col_13`).
  /// A row: the non-empty cells of its paired `Tables` row joined by
  /// ` | ` ('' when the row could not be paired).
  String label;
  String type;

  /// A row's table id (null for a table).
  String? parent;

  /// Table geometry from the Meta header `col_7..col_10` when non-zero
  /// (unpinned reading — see the library doc); null otherwise and for rows.
  double? x, y, w, h;

  /// The raw positional cells behind the node (`col_N` -> text), plus
  /// `row` (a row's 1-based position in its table) when paired.
  Map<String, String> extra;

  @override
  String toString() => 'CanvasNode($type $id "$label")';
}

/// The `Tables` column of row [n]'s first TEXT cell: the lowest `col_N`
/// that is neither empty nor an icon (`@3V@`) — 0 when the row has none
/// (a table). The SQ02 MEINS row (`col_2` MEINS, `col_3` its text) gives
/// 2, the column a recorded session gui[52]'s double click names.
int canvasTextColumn(CanvasNode n) {
  final cols = <int>[];
  for (final e in n.extra.entries) {
    final m = RegExp(r'^col_(\d+)$').firstMatch(e.key);
    final v = e.value.trim();
    if (m == null || v.isEmpty || RegExp(r'^@\w{2,4}@$').hasMatch(v)) {
      continue;
    }
    cols.add(int.parse(m.group(1)!));
  }
  if (n.type == 'table' || cols.isEmpty) return 0;
  cols.sort();
  return cols.first;
}

/// One link of a canvas (LINKS `col_0` / `col_1` / `col_2`).
class CanvasLink {
  CanvasLink({
    required this.id,
    required this.from,
    required this.to,
    Map<String, String>? extra,
  }) : extra = extra ?? {};

  String id;
  String from;
  String to;

  /// The remaining positional LINKS cells (`col_3`..), non-empty only.
  Map<String, String> extra;

  @override
  String toString() => 'CanvasLink($id: $from -> $to)';
}

/// One designer canvas as the server delivered it so far.
class SapCanvasModel {
  SapCanvasModel({
    required this.shell,
    required this.progId,
    List<CanvasNode>? nodes,
    List<CanvasLink>? links,
    this.eventShell,
    this.container,
  }) : nodes = nodes ?? [],
       links = links ?? [];

  /// The kernel shell owning the canvas content (the BWAdapter, `123`) —
  /// also the drop target of [SapSessionCanvas.dropOnCanvas].
  String shell;

  /// Its creation class (`SAP.BWAdapter.1`).
  String progId;

  /// Tables then their rows, in push order.
  List<CanvasNode> nodes;
  List<CanvasLink> links;

  /// The sibling shell that registered the link-commit event 1048576
  /// (the ICDataFlow control, `122`) — where a node->node link is drawn;
  /// null when none registered it.
  String? eventShell;

  /// The container the canvas was created in (CreateControl `#4`).
  String? container;

  CanvasNode? node(String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  @override
  String toString() =>
      'SapCanvasModel($shell $progId: ${nodes.length} nodes, '
      '${links.length} links)';
}

// ---------------------------------------------------------------------------
// Push decode
// ---------------------------------------------------------------------------

/// A canvas property push decoded by its own FORMAT descriptor: positional
/// columns, typed per field (`I` int32 LE, `s` int16 LE, text otherwise).
class CanvasPushTable {
  CanvasPushTable(this.types, this.rows);

  /// ABAP type letter per column (`C`, `s`, `I`, `N`, …).
  final List<String> types;
  final List<List<String>> rows;

  int get width => types.length;
}

/// Decode one X-R3TABLE push segment positionally. Null when the push
/// carries no FORMAT descriptor (a re-read push with nothing to describe).
CanvasPushTable? decodeCanvasPush(Uint8List seg) {
  final (fw, fn, fcells) = _columnCells(seg, 'FORMAT');
  var fmt = _join(fcells);
  if (fw > 0 && fw != _fmtRecord) return null;
  var n = fn > 0 ? fn : fmt.length ~/ _fmtRecord;
  if (n <= 0) return null;
  if (fmt.length < n * _fmtRecord) {
    // the last record's trailing blanks may be cut off the cell
    if (fmt.length <= (n - 1) * _fmtRecord) return null;
    final padded = Uint8List(n * _fmtRecord)..setRange(0, fmt.length, fmt);
    fmt = padded;
  }
  final bd = fmt.buffer.asByteData(fmt.offsetInBytes, fmt.lengthInBytes);
  final cols = <(int, int, int)>[]; // offset, length, type
  for (var i = 0; i < n; i++) {
    final o = i * _fmtRecord;
    cols.add((
      bd.getUint32(o + 64, Endian.little),
      bd.getUint32(o + 68, Endian.little),
      bd.getUint32(o + 76, Endian.little),
    ));
  }
  final types = [for (final c in cols) String.fromCharCode(c.$3 & 0xff)];
  final (dw, dn, dcells) = _columnCells(seg, 'DATAASC');
  final rows = <List<String>>[];
  if (dw > 0 && dn > 0) {
    // inline `03 04` rows arrive with their trailing blanks cut (a
    // 3-row x 40 push carried cells of 1 / 10 / 40 bytes): one cell per
    // row, each padded back to the row width
    final perRow = dcells.length == dn && dcells.every((c) => c.length <= dw);
    final data = perRow
        ? _join([
            for (final c in dcells)
              Uint8List(dw)
                ..setRange(0, c.length, c)
                ..fillRange(c.length, dw, 0x20),
          ])
        : _join(dcells);
    for (var r = 0; r < dn && r * dw < data.length; r++) {
      final end = (r + 1) * dw > data.length ? data.length : (r + 1) * dw;
      final rec = Uint8List.sublistView(data, r * dw, end);
      rows.add([for (final c in cols) _field(rec, c.$1, c.$2, c.$3)]);
    }
  }
  return CanvasPushTable(types, rows);
}

const int _fmtRecord = 80;

/// (width, count, cells) of a DP column. An LZH `03 05` column is read
/// from its own cell framing: dp_cache's [dpColumnCells] bounds the
/// column at the first `02 13` / `03 01 00` byte pair, which can occur
/// INSIDE the compressed stream (a recorded session srv[10] /
/// srv[18]: the LINKS and Tables FORMAT cells came back empty).
(int, int, List<Uint8List>) _columnCells(Uint8List seg, String name) {
  final anchor = [0x03, 0x01, 0x00, name.length, ...name.codeUnits, 0x03, 0x01];
  final at = _indexOf(seg, anchor);
  if (at >= 0) {
    final ds = at + anchor.length;
    final bd = seg.buffer.asByteData(seg.offsetInBytes, seg.lengthInBytes);
    if (ds + 12 <= seg.length &&
        seg[ds] == 0x03 &&
        seg[ds + 1] == 0x02 &&
        bd.getUint16(ds + 2) == 8) {
      final w = bd.getUint32(ds + 4), n = bd.getUint32(ds + 8);
      for (var k = ds + 12; k < ds + 20 && k + 1 < seg.length; k++) {
        if (seg[k] == 0x03 && seg[k + 1] == 0x04) break; // inline rows
        if (seg[k] != 0x03 || seg[k + 1] != 0x05) continue;
        final cells = find0305Cells(Uint8List.sublistView(seg, k));
        if (cells.isEmpty || cells.first.openOff != 0) break;
        final p = parse0305Cell(cells.first.bytes);
        final blob = p == null ? null : lzhInflate(p.lzh);
        if (blob != null) return (w, n, [blob]);
        break;
      }
    }
  }
  final (_, (w, n), cells) = dpColumnCells(seg, name);
  return (w, n, cells);
}

int _indexOf(Uint8List b, List<int> needle) {
  for (var i = 0; i + needle.length <= b.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (b[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

String _field(Uint8List rec, int offset, int length, int type) {
  if (offset >= rec.length) return '';
  final end = offset + length > rec.length ? rec.length : offset + length;
  final raw = Uint8List.sublistView(rec, offset, end);
  final bd = raw.buffer.asByteData(raw.offsetInBytes, raw.lengthInBytes);
  switch (type) {
    case 0x49: // 'I'
      return raw.length >= 4 ? bd.getInt32(0, Endian.little).toString() : '';
    case 0x73: // 's'
      return raw.length >= 2 ? bd.getInt16(0, Endian.little).toString() : '';
    default:
      var k = raw.length;
      while (k > 0 && (raw[k - 1] == 0 || raw[k - 1] == 0x20)) {
        k--;
      }
      return utf8.decode(
        Uint8List.sublistView(raw, 0, k),
        allowMalformed: true,
      );
  }
}

Uint8List _join(List<Uint8List> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

// ---------------------------------------------------------------------------
// Drag & drop behaviour registry (X-SAPDDBEHAV)
// ---------------------------------------------------------------------------

/// One flavor record of an `X-SAPDDBEHAV` behaviour push: the behaviour
/// [handle] (a tree row's DRAGDROPID, a control's `DragDropHandle`), the
/// [flavor] name, and whether the handle is a drag source / a drop target
/// for it (a recorded session srv[5]: handle 1 `Files` drag,
/// srv[7]: handle 2 `Files` drop).
class DdBehaviour {
  DdBehaviour(this.handle, this.flavor, this.drag, this.drop);
  final int handle;
  final String flavor;
  final bool drag;
  final bool drop;

  @override
  String toString() =>
      'DdBehaviour($handle $flavor${drag ? ' drag' : ''}${drop ? ' drop' : ''})';
}

/// Flavor records of one behaviour push: `u32 LE handle, u32 LE 0x20,
/// C40 flavor, C1 drag 'X', C1 drop 'X', 2 x NUL` (the reference client's
/// ea_dragdrop._BEHAVIOUR_REC), scanned over the push's content cells.
List<DdBehaviour> parseDdBehaviours(Uint8List seg) {
  final out = <DdBehaviour>[];
  final blobs = [
    ..._columnCells(seg, 'DATAASC').$3,
    ..._columnCells(seg, 'DATABIN').$3,
  ];
  for (final b in blobs) {
    for (var i = 0; i + 52 <= b.length; i++) {
      if (b[i] == 0 ||
          b[i + 1] != 0 ||
          b[i + 2] != 0 ||
          b[i + 3] != 0 ||
          b[i + 4] != 0x20 ||
          b[i + 5] != 0 ||
          b[i + 6] != 0 ||
          b[i + 7] != 0) {
        continue;
      }
      var printable = true;
      for (var k = 8; k < 48; k++) {
        if (b[i + k] < 0x20 || b[i + k] > 0x7e) {
          printable = false;
          break;
        }
      }
      final dg = b[i + 48], dp = b[i + 49];
      if (!printable ||
          (dg != 0x20 && dg != 0x58) ||
          (dp != 0x20 && dp != 0x58) ||
          b[i + 50] != 0 ||
          b[i + 51] != 0) {
        continue;
      }
      final flavor = String.fromCharCodes(b, i + 8, i + 48).trim();
      if (flavor.isEmpty) continue;
      out.add(DdBehaviour(b[i], flavor, dg == 0x58, dp == 0x58));
      i += 51;
    }
  }
  return out;
}

/// The flavors a drop carries: the source handle's DRAG flavors the target
/// handle accepts as DROP flavors, in source order (null handle = any).
List<String> dropFlavors(
  Iterable<DdBehaviour> records, {
  int? sourceHandle,
  int? targetHandle,
}) {
  final drag = [
    for (final r in records)
      if (r.drag && (sourceHandle == null || r.handle == sourceHandle))
        r.flavor,
  ];
  final drop = {
    for (final r in records)
      if (r.drop && (targetHandle == null || r.handle == targetHandle))
        r.flavor,
  };
  final out = <String>[];
  for (final f in drag) {
    if (drop.contains(f) && !out.contains(f)) out.add(f);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Tracker
// ---------------------------------------------------------------------------

/// The creation facts of one control.
class CanvasControl {
  CanvasControl(this.shell, this.cls, this.parent, this.seq);
  final String shell;
  final String cls;
  final String? parent;
  final int seq;
}

class _Push {
  _Push(this.role, this.owner, this.shell, this.url, this.seq, this.table);
  final String role;
  final String? owner;
  final String? shell;
  final String url;
  final int seq;
  final CanvasPushTable? table;
}

/// The property names a canvas's content rides on (the r3TableAutoObj set).
const Set<String> canvasRoles = {'Tables', 'Meta', 'LINKS', 'Positions'};

/// The link-commit event of the ICDataFlow control (`OnNewLinkCreated`,
/// a recorded session gui[8]/[11]).
const int canvasConnectEvent = 1048576;

/// The CFW drag & drop GuiService event (`%_GS <target> 15`).
const int canvasDropEvent = 15;

bool isCanvasDataClass(String cls) => cls.toLowerCase().contains('bwadapter');

/// Session-side fold of everything a canvas drop / connect needs, from the
/// complete OLE_FLUSH_CALL values the server sends: the control registry
/// (class, parent container), registered events and cached props per
/// shell, the canvas property pushes, the tree rows' DRAGDROPIDs, the
/// X-SAPDDBEHAV behaviour registry and the `DragDropHandle` property verbs.
/// Owner handles are kept as sent and resolved at read time (the session's
/// alias map is only complete once the creating queue was answered).
class SapCanvasTracker {
  final Map<String, CanvasControl> controls = {};
  final Map<String, Set<int>> registeredEvents = {};
  final Map<String, List<String>> cachedProps = {};

  /// handle -> its flavor records (a later declaration replaces a handle:
  /// the session-wide GuiServiceDragDrop registry).
  final Map<int, List<DdBehaviour>> behaviours = {};

  /// owner handle -> the `DragDropHandle` the server set on it
  final Map<String, int> dragDropHandles = {};

  /// tree owner handle (or shell) -> NODE_KEY -> DRAGDROPID
  final Map<String, Map<String, String>> treeDragIds = {};

  final List<_Push> _pushes = [];
  int _seq = 0;

  /// Fold one complete OLE_FLUSH_CALL RFC value. Returns whether it carried
  /// a canvas property push. [parsed] = [rfc] already parsed.
  bool foldCall(Uint8List rfc, {FlushCall? parsed}) {
    final FlushCall call;
    try {
      call = parsed ?? parseFlushCall(rfc);
    } catch (_) {
      return false;
    }
    if (call.verbs.isEmpty) return false;
    final meta = verbMeta(call);
    DpCache? cache;
    DpCache cacheOf() => cache ??= (DpCache()..ingestValue(rfc));
    for (var i = 1; i <= call.verbs.length; i++) {
      final verb = call.verbs[i - 1];
      if (verb.startsWith('CreateControl')) {
        final a = verbNamedArgs(call, i);
        final shell = (a['#1'] ?? '').trim();
        if (!_digits(shell)) continue;
        final parent = (a['#4'] ?? '').trim();
        controls[shell] = CanvasControl(
          shell,
          (a['#2'] ?? '').trim(),
          parent.isEmpty ? null : parent,
          _seq++,
        );
        // a reused shell id is a new control: its old facts are gone
        registeredEvents.remove(shell);
        cachedProps.remove(shell);
      } else if (verb == 'UnRegisterEvent') {
        final a = verbNamedArgs(call, i);
        final ev = int.tryParse((a['#2'] ?? '').trim());
        if (ev != null) registeredEvents[(a['#1'] ?? '').trim()]?.remove(ev);
      } else if (verb == 'DragDropHandle') {
        final owner = meta[i - 1].objValue.trim();
        for (final (_, v) in verbArgs(call, i)) {
          final h = int.tryParse(v.trim());
          if (h != null && owner.isNotEmpty) {
            dragDropHandles[owner] = h;
            break;
          }
        }
      } else if (verb == 'SetDataFromUrl') {
        final a = verbNamedArgs(call, i);
        if ((a['#2'] ?? '').trim() != 'X-SAPDDBEHAV') continue;
        final seg = cacheOf().byUrl[(a['#3'] ?? '').trim()];
        if (seg == null) continue;
        final byHandle = <int, List<DdBehaviour>>{};
        for (final r in parseDdBehaviours(seg)) {
          (byHandle[r.handle] ??= []).add(r);
        }
        behaviours.addAll(byHandle);
      }
    }
    // the parser's own registration reads (RegisterEvent / RegisterOcxEvent,
    // RegisterCachedProp) — in queue order, after a CreateControl reset
    for (final (shell, ev) in call.registeredEvents) {
      (registeredEvents[shell] ??= {}).add(ev);
    }
    for (final (shell, prop) in call.cachedProps) {
      final l = cachedProps[shell] ??= [];
      if (!l.contains(prop)) l.add(prop);
    }
    var touched = false;
    for (final b in dpPushBindings(call)) {
      final role = b.role;
      if (role == null || b.urls.isEmpty) continue;
      if (canvasRoles.contains(role) && b.attach == null) {
        for (final u in b.urls) {
          final seg = cacheOf().byUrl[u];
          _pushes.add(
            _Push(
              role,
              b.owner?.trim(),
              b.shell?.trim(),
              u,
              _seq++,
              seg == null ? null : decodeCanvasPush(seg),
            ),
          );
          touched = true;
        }
      } else if (role == 'R3Table' || role == 'R3TABLE') {
        final key = (b.shell ?? b.owner ?? '').trim();
        if (key.isEmpty) continue;
        for (final u in b.urls) {
          final seg = cacheOf().byUrl[u];
          if (seg == null) continue;
          final t = decodeNamedDpTable(seg);
          if (t == null || !t.columns.contains('NODE_KEY')) continue;
          final ids = treeDragIds[key] ??= {};
          for (final r in t.rows) {
            final k = r['NODE_KEY'] ?? '';
            if (k.trim().isEmpty) continue;
            ids[k] = (r['DRAGDROPID'] ?? '').trim();
          }
        }
      }
    }
    return touched;
  }

  /// The kernel shell a push / verb owner names: the alias map's shell or
  /// the token itself when that is a control of [want] class; else (a
  /// replayed recording keeps the recording client's handles) the newest
  /// live control of that class.
  String? resolveOwner(
    String? owner,
    String? explicitShell, {
    String? Function(String owner)? shellOf,
    bool Function(String shell)? isLive,
    bool Function(String cls) want = isCanvasDataClass,
  }) {
    final cands = [
      explicitShell,
      if (owner != null && owner.isNotEmpty) ...[shellOf?.call(owner), owner],
    ];
    for (final c in cands) {
      if (c == null) continue;
      final ctl = controls[c];
      if (ctl != null && want(ctl.cls)) return c;
    }
    final byAge = controls.values.toList()
      ..sort((a, b) => b.seq.compareTo(a.seq));
    for (final c in byAge) {
      if (want(c.cls) && (isLive?.call(c.shell) ?? true)) return c.shell;
    }
    return null;
  }

  /// Shells holding canvas pushes, in first-push order.
  List<String> canvasShells({
    String? Function(String owner)? shellOf,
    bool Function(String shell)? isLive,
  }) {
    final out = <String>[];
    for (final p in _pushes) {
      final s = resolveOwner(
        p.owner,
        p.shell,
        shellOf: shellOf,
        isLive: isLive,
      );
      if (s != null && !out.contains(s) && (isLive?.call(s) ?? true)) {
        out.add(s);
      }
    }
    return out;
  }

  /// The shell that registered the link-commit event for canvas [shell]: a
  /// registrant created in the same container first, else the only one.
  String? connectShellFor(String shell, {bool Function(String)? isLive}) {
    final regs = [
      for (final e in registeredEvents.entries)
        if (e.value.contains(canvasConnectEvent) &&
            (isLive?.call(e.key) ?? true))
          e.key,
    ];
    final parent = controls[shell]?.parent;
    if (parent != null) {
      final sib = regs.where((s) => controls[s]?.parent == parent).toList();
      if (sib.length == 1) return sib.single;
    }
    return regs.length == 1 ? regs.single : null;
  }

  /// The behaviour handle the server set on control [shell] via the
  /// `DragDropHandle` property verb.
  int? dragDropHandleOf(
    String shell, {
    String? Function(String owner)? shellOf,
    bool Function(String shell)? isLive,
  }) {
    final cls = controls[shell]?.cls ?? '';
    for (final e in dragDropHandles.entries) {
      final s = resolveOwner(
        e.key,
        null,
        shellOf: shellOf,
        isLive: isLive,
        want: (c) => c == cls,
      );
      if (s == shell) return e.value;
    }
    return null;
  }

  /// The tree rows (NODE_KEY -> DRAGDROPID) pushed for tree [shell].
  Map<String, String> treeRowsOf(
    String shell, {
    String? Function(String owner)? shellOf,
  }) {
    final out = <String, String>{};
    for (final e in treeDragIds.entries) {
      final s = shellOf?.call(e.key) ?? e.key;
      if (s == shell || e.key == shell) out.addAll(e.value);
    }
    return out;
  }

  /// Every tree row known regardless of owner (a replayed recording whose
  /// owner handles do not resolve).
  Map<String, String> get allTreeRows => {
    for (final m in treeDragIds.values) ...m,
  };

  /// The canvas of [shell] as delivered so far, null when no push of it
  /// was seen.
  SapCanvasModel? build(
    String shell, {
    String? Function(String owner)? shellOf,
    bool Function(String shell)? isLive,
  }) {
    final mine = [
      for (final p in _pushes)
        if (resolveOwner(p.owner, p.shell, shellOf: shellOf, isLive: isLive) ==
            shell)
          p,
    ]..sort((a, b) => a.seq.compareTo(b.seq));
    if (mine.isEmpty) return null;

    // Tables + Meta pairs; the newest pair per table id wins
    final pairs = <String, (_Push meta, _Push? tables)>{};
    _Push? pending;
    for (final p in mine) {
      if (p.role == 'Tables') {
        pending = p;
      } else if (p.role == 'Meta') {
        final tables = pending;
        pending = null;
        final tid = _metaTableId(p.table);
        if (tid == null) continue;
        pairs.remove(tid); // re-insert at the newest position
        pairs[tid] = (p, tables);
      }
    }
    final ordered = pairs.entries.toList()
      ..sort((a, b) => a.value.$1.seq.compareTo(b.value.$1.seq));
    final tables = <CanvasNode>[];
    final rows = <CanvasNode>[];
    for (final e in ordered) {
      final (meta, tpush) = e.value;
      final (t, r) = _nodesOf(e.key, meta.table!, tpush?.table);
      tables.add(t);
      rows.addAll(r);
    }

    final links = <String, CanvasLink>{};
    for (final p in mine) {
      if (p.role != 'LINKS') continue;
      for (final row in p.table?.rows ?? const <List<String>>[]) {
        if (row.length < 3 || !_digits(row[0])) continue;
        links[row[0]] = CanvasLink(
          id: row[0],
          from: row[1],
          to: row[2],
          extra: {
            for (var c = 3; c < row.length; c++)
              if (row[c].isNotEmpty) 'col_$c': row[c],
          },
        );
      }
    }
    return SapCanvasModel(
      shell: shell,
      progId: controls[shell]?.cls ?? '',
      nodes: [...tables, ...rows],
      links: links.values.toList(),
      eventShell: connectShellFor(shell, isLive: isLive),
      container: controls[shell]?.parent,
    );
  }
}

String? _metaTableId(CanvasPushTable? t) {
  if (t == null) return null;
  for (final r in t.rows) {
    if (r.length >= 3 && _digits(r[0]) && _digits(r[1]) && r[0] != '0') {
      return r[0];
    }
  }
  return null;
}

(CanvasNode, List<CanvasNode>) _nodesOf(
  String tid,
  CanvasPushTable meta,
  CanvasPushTable? tablesPush,
) {
  List<String>? header;
  final ids = <String>[];
  for (final r in meta.rows) {
    if (r.length < 3 || r[0] != tid || !_digits(r[1])) continue;
    if (r[1] == '0') {
      if (r[2] == '0') header ??= r;
    } else if (!ids.contains(r[1])) {
      ids.add(r[1]);
    }
  }
  String cell(int i) => header != null && i < header.length ? header[i] : '';
  final caption = cell(12).isNotEmpty ? cell(12) : cell(13);
  double? num(int i) {
    final v = int.tryParse(cell(i));
    return v == null ? null : v.toDouble();
  }

  final geo = [num(7), num(8), num(9), num(10)];
  final placed = geo.every((v) => v != null) && geo.any((v) => v != 0);
  final table = CanvasNode(
    id: tid,
    label: caption,
    type: 'table',
    x: placed ? geo[0] : null,
    y: placed ? geo[1] : null,
    w: placed ? geo[2] : null,
    h: placed ? geo[3] : null,
    extra: {
      if (header != null)
        for (var c = 3; c < header.length; c++)
          if (header[c].isNotEmpty && header[c] != '0') 'col_$c': header[c],
    },
  );
  final trows = tablesPush?.rows ?? const <List<String>>[];
  final paired = ids.isNotEmpty && trows.length == ids.length;
  final rows = <CanvasNode>[
    for (var k = 0; k < ids.length; k++)
      CanvasNode(
        id: ids[k],
        label: paired ? trows[k].where((c) => c.isNotEmpty).join(' | ') : '',
        type: 'row',
        parent: tid,
        extra: paired
            ? {
                'row': '${k + 1}',
                for (var c = 0; c < trows[k].length; c++)
                  if (trows[k][c].isNotEmpty) 'col_$c': trows[k][c],
              }
            : {},
      ),
  ];
  return (table, rows);
}

bool _digits(String? s) => s != null && RegExp(r'^\d+$').hasMatch(s.trim());
