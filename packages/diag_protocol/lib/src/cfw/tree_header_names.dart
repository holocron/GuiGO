/// A column tree's `HeaderNames` property (SAP.TableTreeControl.1 /
/// sapTreeS.jar `SapTree.setHeaderNames(DPDataI)` / `getHeaderNames`):
/// the table of visible header keys, in display order, that the server
/// ASSIGNS to the tree and later reads back through a client-table pull.
///
/// The ALV tree (CL_ALV_TREE_BASE / CL_SALV_TREE) rebuilds its field
/// catalog from that read-back (GET_FRONTEND_FIELDCATALOG): every visible
/// catalog column must be among the rows, else `RAISE FAILED` — the
/// /AIF/IFMON `BT_SELECTDT` dump GuiGo hit on the test system (2026-10-13 00:36,
/// CL_ALV_TREE_BASE CM00D line 83) answering the pull with an empty table,
/// and the reference client's complaint-se51+20260904-093141 (a 32-name answer that
/// missed `C 32`).
///
/// The real GUI's contract (a recorded session, Windows OCX, and
/// a recorded session, the Java bean — both byte-identical in the
/// rows):
/// * the launch batch (scrubbed srv[18..20], step 32) adds 32 headers and
/// then assigns a 14-row x 12-char table — `CreateObject`,
/// `SetDataFromUrl(SAPR3://…)`, `GetDataAsFormat`,
/// `AssignProperty2(<data>, 'data', <tree>, 'HeaderNames')` — the tree
/// being the result row of the batch's own `CreateControl(136,
/// SAP.TableTreeControl.1)`; a later wave re-assigns it by handle
/// (srv[45]: `AssignProperty2(31, 'data', 28, 'HeaderNames')`);
/// * every read-back (`AssignProperty2(28, 'HeaderNames', 32, 'data')` +
/// `SaveDataToUrl`, then the DP_GET) returns exactly the last non-empty
/// assigned table (raw gui[34] / [37] / [48] / …, Java gui[45] …);
/// an EMPTY `HeaderNames2` assignment (the Java pull flush) changes
/// nothing;
/// * the rows go up as inline `03 04` cells with their trailing run of a
/// repeated byte cut to one ([collapseInlineRow]: `C 22` is sent
/// as the 11 bytes `C 2`).
library;

import 'dart:typed_data';

import '../lzh/lzh.dart';
import 'dp_cache.dart' show dpColumnCells;
import 'flush_call.dart';
import 'reply_container.dart' show buildDpAnswer, rfcToken, tableInlineMax;
import 'rfc_cells.dart' show wrap0305Cell;

/// The properties that hold a tree's header-name table.
const Set<String> headerNamesProps = {'HeaderNames', 'HeaderNames2'};

/// The data-object property an `AssignProperty2` moves a table through
/// (`data` on the OCX's GuiDataProvider path, `r3TableAutoObj` on the
/// Force/formats one).
const Set<String> _dataProps = {'data', 'r3TableAutoObj'};

/// One header-name table: [rows] at [width] bytes each (blank padded).
class HeaderNamesTable {
  HeaderNamesTable(this.width, List<Uint8List> rows)
    : rows = List.unmodifiable(rows);

  /// From [names], each blank padded to the widest one (the fallback of a
  /// tree whose table was never assigned).
  factory HeaderNamesTable.ofNames(List<String> names) {
    var w = 0;
    for (final n in names) {
      if (n.length > w) w = n.length;
    }
    return HeaderNamesTable(w, [
      for (final n in names)
        Uint8List.fromList([
          for (var i = 0; i < w; i++)
            i < n.length ? n.codeUnitAt(i) & 0xff : 0x20,
        ]),
    ]);
  }

  final int width;
  final List<Uint8List> rows;

  bool get isEmpty => rows.isEmpty;

  /// The header keys, trailing blanks cut.
  List<String> get names => [
    for (final r in rows) String.fromCharCodes(r).trimRight(),
  ];

  @override
  String toString() => 'HeaderNamesTable($width x ${rows.length}: $names)';
}

/// One `AssignProperty2(<data>, 'data', <target>, 'HeaderNames')` of a
/// call: [target] the tree as the call names it — a handle / shell token,
/// or the shell of the call's own `CreateControl` whose result row the
/// argument references — '' when unresolvable; [table] the assigned
/// table (empty for an empty assignment).
class HeaderNamesAssignment {
  const HeaderNamesAssignment(this.target, this.prop, this.table);
  final String target;
  final String prop;
  final HeaderNamesTable table;

  @override
  String toString() => 'HeaderNamesAssignment($target.$prop, $table)';
}

/// The header-name tables [call] assigns, in call order. [segment] = the
/// DP_PUT segment pushed for a url (the call's own nested push, else the
/// session's cache); an assignment whose table cannot be read is skipped.
List<HeaderNamesAssignment> headerNamesAssignments(
  FlushCall call,
  Uint8List? Function(String url) segment,
) {
  final out = <HeaderNamesAssignment>[];
  final meta = verbMeta(call);
  // CreateControl result row -> the shell it requested (#1)
  final createdShell = <String, String>{};
  String? url;
  for (var i = 1; i <= call.verbs.length; i++) {
    final verb = call.verbs[i - 1];
    final a = verbNamedArgs(call, i);
    final m = meta[i - 1];
    if (verb.startsWith('CreateControl')) {
      final res = m.result?.trim() ?? '';
      final sh = (a['#1'] ?? '').trim();
      if (res.isNotEmpty && _digits.hasMatch(sh)) createdShell[res] = sh;
      continue;
    }
    if (verb == 'SetDataFromUrl') {
      final u = (a['#3'] ?? '').trim();
      if (u.startsWith('SAPR3://')) url = u;
      continue;
    }
    if (verb != 'AssignProperty2') continue;
    final prop = (a['#4'] ?? '').trim();
    if (!_dataProps.contains((a['#2'] ?? '').trim()) ||
        !headerNamesProps.contains(prop)) {
      continue;
    }
    final u = url;
    if (u == null) continue;
    final seg = segment(u);
    if (seg == null) continue;
    final table = headerNamesTableOf(seg);
    if (table == null) continue;
    var target = (a['#3'] ?? '').trim();
    if (target.isEmpty) {
      target = createdShell[(m.slots['#3'] ?? '').trim()] ?? '';
    }
    out.add(HeaderNamesAssignment(target, prop, table));
  }
  return out;
}

/// The table a DP_PUT [seg] carries in its DATAASC column, or null when
/// it has none. Inline `03 04` rows arrive with their trailing run cut
/// ([expandInlineRow] restores them); an LZH `03 05` cell holds the rows
/// back to back. All-blank rows are no header.
HeaderNamesTable? headerNamesTableOf(Uint8List seg) {
  final (name, (w, n), cells) = dpColumnCells(seg, 'DATAASC');
  if (name.isEmpty || w <= 0) return null;
  final rows = <Uint8List>[];
  final inline =
      cells.length == n && cells.every((c) => c.length <= w) && n > 0;
  if (inline) {
    for (final c in cells) {
      rows.add(expandInlineRow(c, w));
    }
  } else {
    final all = BytesBuilder(copy: false);
    for (final c in cells) {
      all.add(c);
    }
    final b = all.takeBytes();
    for (var off = 0; off + w <= b.length && rows.length < n; off += w) {
      rows.add(Uint8List.fromList(Uint8List.sublistView(b, off, off + w)));
    }
  }
  return HeaderNamesTable(w, [
    for (final r in rows)
      if (r.any((c) => c != 0x20 && c != 0)) r,
  ]);
}

/// The header keys the latest `ItemEx(<name>)` … `Hidden(0)` chains of
/// [call] declare visible, in call order (the reference client's note_header_items
/// fallback, for a tree whose table was never assigned); empty when the
/// call declares none.
List<String> declaredVisibleHeaders(FlushCall call) {
  final out = <String>[];
  String? cur;
  for (var i = 1; i <= call.verbs.length; i++) {
    final verb = call.verbs[i - 1];
    if (verb == 'ItemEx') {
      final n = (verbNamedArgs(call, i)['#1'] ?? '').trim();
      cur = n.isEmpty ? null : n;
    } else if (verb == 'Hidden' && cur != null) {
      final args = verbArgs(call, i);
      final h = args
          .map((a) => a.$2.trim())
          .firstWhere((v) => v == '0' || v == '1', orElse: () => '');
      if (h == '0' && !out.contains(cur)) out.add(cur);
      cur = null;
    }
  }
  return out;
}

/// The header widths [call] declares: header key -> the chars of the last
/// `ABAPWidth(<chars>, 0)` after its `ItemEx(<key>)` (or the
/// `HierarchyHeader`, keyed `HierarchyHeader`) — the launch batch's
/// `ItemEx('C 8')` … `ABAPWidth(46, 0)`, the re-declaration's
/// `ABAPWidth(10, 0)` (a recorded session raw srv[20..22] / [47]). The
/// first non-object argument is the width (a later wave may pass the tree
/// handle first — the reference client's _first_scalar_arg). A `Structures` /
/// `AddEx2` chain (the item columns, not the headers) addresses no header.
Map<String, int> declaredHeaderWidths(FlushCall call) {
  final out = <String, int>{};
  final meta = verbMeta(call);
  String? cur;
  for (var i = 1; i <= call.verbs.length && i <= meta.length; i++) {
    final verb = call.verbs[i - 1];
    if (verb == 'ItemEx') {
      final n = (verbNamedArgs(call, i)['#1'] ?? '').trim();
      cur = n.isEmpty ? null : n;
    } else if (verb == 'HierarchyHeader') {
      cur = 'HierarchyHeader';
    } else if (verb == 'Structures' || verb == 'AddEx2') {
      cur = null;
    } else if (verb == 'ABAPWidth' && cur != null) {
      final slots = meta[i - 1].slots;
      for (final name in ['#1', '#2', '#3']) {
        final r = int.tryParse(slots[name] ?? '');
        if (r == null || r < 1 || r > call.vars.length) continue;
        final v = call.vars[r - 1];
        if (v.type == 'O') continue;
        final w = int.tryParse(v.valueText.trim());
        if (w != null) out[cur] = w;
        break;
      }
    }
  }
  return out;
}

/// A row as the DP writers send an inline `03 04` cell: its trailing run
/// of one repeated byte cut to a single byte (every real-GUI upload of the
/// corpus — `C 22` -> `C 2` (a recorded session raw
/// gui[34]), `ORG_SHORT ` -> `ORG_SHORT ` (a recorded session),
/// a blank PARAMS row -> one blank, `<I 1>` + NULs -> `01 00`; the
/// kernel's own inline pushes the same: `20260824` + `<I 0>` ->
/// `20260824 00`).
Uint8List collapseInlineRow(Uint8List row) {
  var n = row.length;
  if (n < 2) return row;
  final last = row[n - 1];
  while (n > 1 && row[n - 2] == last) {
    n--;
  }
  return Uint8List.sublistView(row, 0, n);
}

/// The inverse of [collapseInlineRow]: [cell] padded to [width] with its
/// last byte (blanks for an empty cell).
Uint8List expandInlineRow(Uint8List cell, int width) {
  if (cell.length >= width) return Uint8List.fromList(cell);
  final pad = cell.isEmpty ? 0x20 : cell.last;
  return Uint8List(width)
    ..fillRange(0, width, pad)
    ..setRange(0, cell.length, cell);
}

/// The `octet-stream` FORMAT record of a one-column client table, field
/// length [length] at offset 0, type C — the real Windows GUI's
/// (a recorded session gui[101] node keys: 11; a recorded session
/// raw gui[34] header names: 12).
Uint8List octetStreamFormatRecord(int length) => Uint8List.fromList([
  ...'octet-stream'.codeUnits,
  ...List.filled(48, 0x20),
  1, 0, 0, 0, 0, 0, 0, 0,
  length & 0xff, (length >> 8) & 0xff, (length >> 16) & 0xff,
  (length >> 24) & 0xff,
  0, 0, 0, 0, 0x43, 0x20,
]);

/// The Java bean's FORMAT record of a property read-back with an unnamed
/// field (a recorded session gui[45]): `X-UNKNOWN` and the index
/// `1` NUL padded to 30 bytes each, `<I 1><I 0><I length><I 0>`, `C`, NUL.
Uint8List unknownFormatRecord(int length) {
  final b = Uint8List(78);
  b.setRange(0, 9, 'X-UNKNOWN'.codeUnits);
  b[30] = 0x31;
  final d = ByteData.sublistView(b, 60, 76)
    ..setUint32(0, 1, Endian.little)
    ..setUint32(4, 0, Endian.little)
    ..setUint32(8, length, Endian.little);
  d.setUint32(12, 0, Endian.little);
  b[76] = 0x43;
  return b;
}

/// The answer to the DP_GET of a tree's HeaderNames read-back: [table]'s
/// rows as the real GUI uploads them.
///
/// Windows OCX (a recorded session raw gui[34], [37], [48], …): TYPE
/// `APPLICATION` / SUBTYPE `X-R3TABLE`, the client clock DATE (MM/DD/YY)
/// and 7-char TIME, TOTALSIZE = width x rows (little-endian u32), DATAASC
/// at the table's width, FORMAT one `octet-stream` C(width) record, PROPS
/// 80 x 0, the 06 67 trailer.
///
/// Java bean ([windows] false; a recorded session gui[45]): TYPE
/// `APPLICATION/X-R3TABLE`, blank DATE / TIME, TOTALSIZE 0, the bare
/// SEND_DATA_AS_STRING scalar, FORMAT one X-UNKNOWN record, no trailer.
///
/// The DATAASC rows: inline collapsed `03 04` cells ([collapseInlineRow])
/// while the table fits one segment ([tableInlineMax]), else one LZH
/// `03 05` cell + `03 06` (the writer's threshold; no capture holds a
/// header table that large).
Uint8List headerNamesPullAnswer(
  HeaderNamesTable table, {
  required bool windows,
  DateTime? now,
}) {
  final w = table.width <= 0 ? 1 : table.width;
  final n = table.rows.length;
  final data = BytesBuilder(copy: false)
    ..add(_tok(0x03, 0x01, Uint8List.fromList('DATAASC'.codeUnits)))
    ..add(_tok(0x03, 0x02, _dims(w, n)));
  if (n > 0 && w * n <= tableInlineMax) {
    for (final r in table.rows) {
      data.add(_tok(0x03, 0x04, collapseInlineRow(r)));
    }
  } else if (n > 0) {
    final body = Uint8List(w * n)..fillRange(0, w * n, 0x20);
    for (var i = 0; i < n; i++) {
      final r = table.rows[i];
      body.setRange(i * w, i * w + (r.length < w ? r.length : w), r);
    }
    data
      ..add(wrap0305Cell(lzhCompress(body)))
      ..add(_tok(0x03, 0x06, Uint8List(0)));
  }
  final fmt = windows ? octetStreamFormatRecord(w) : unknownFormatRecord(w);
  final region = BytesBuilder(copy: false)
    ..add(data.takeBytes())
    ..add(_tok(0x03, 0x01, Uint8List.fromList('FORMAT'.codeUnits)))
    ..add(_tok(0x03, 0x02, _dims(80, 1)))
    ..add(_tok(0x03, 0x04, fmt))
    ..add(_tok(0x03, 0x01, Uint8List.fromList('PROPS'.codeUnits)))
    ..add(_tok(0x03, 0x02, _dims(80, 0)));
  if (!windows) {
    return buildDpAnswer(
      scalars: const {
        'TYPE': 'APPLICATION/X-R3TABLE',
        'SUBTYPE': 'X-R3TABLE',
        'DATE': '',
        'TIME': '',
        'DESCRIPTION': '',
        'TOTALSIZE': '\x00\x00\x00\x00',
        'PLATTFORM': '',
      },
      extraScalars: const [('SEND_DATA_AS_STRING', '')],
      tableRegion: region.takeBytes(),
      trailer: false,
    );
  }
  final t = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final total = w * n;
  return buildDpAnswer(
    scalars: {
      'TYPE': 'APPLICATION',
      'SUBTYPE': 'X-R3TABLE',
      'DATE': '${two(t.month)}/${two(t.day)}/${two(t.year % 100)}',
      // 7 characters, the seconds' last digit cut (sic, as the GUI sends)
      'TIME': '${two(t.hour)}:${two(t.minute)}:${two(t.second)}'.substring(
        0,
        7,
      ),
      'DESCRIPTION': '',
      'TOTALSIZE': String.fromCharCodes([
        total & 0xff,
        (total >> 8) & 0xff,
        (total >> 16) & 0xff,
        (total >> 24) & 0xff,
      ]),
      'PLATTFORM': '',
    },
    tableRegion: region.takeBytes(),
  );
}

final RegExp _digits = RegExp(r'^\d+$');

Uint8List _dims(int w, int n) {
  final d = ByteData(8)
    ..setUint32(0, w)
    ..setUint32(4, n);
  return d.buffer.asUint8List();
}

Uint8List _tok(int a, int c, Uint8List data) => rfcToken(a, c, data);
