/// Client-reply RFC_TR container synthesis (diag_reply_container port).
library;

import 'dart:typed_data';

import '../lzh/lzh.dart';
import 'rfc_cells.dart';

const String constCodepage = 'E';
const String constGuiBuild = '753';
/// The client address the reply descriptor names. Kept as the loopback on
/// purpose: real GUIs send it too (the reference client's a recorded session oracle
/// carries `0018 0009 "127.0.0.1"`; others carry the NIC address —
/// a recorded session gui[2] `an address`, a recorded session
/// `an address`), and the kernel does not re-validate it (reference client
/// diag_reply_container CONST_CLIENT_ADDR, its `reply_client_addr` knob the
/// A/B lever should a kernel ever check). [composeConstPrefix] takes
/// another address when one is needed.
const String constClientAddr = '127.0.0.1';

Uint8List _field(String value, int width) {
  final raw = value.length > width ? value.substring(0, width) : value.padRight(width);
  return Uint8List.fromList([for (final c in raw.codeUnits) c & 0xff]);
}

/// The 128-byte reply connection descriptor (client-side constant).
Uint8List composeConstPrefix(
    {String codepage = constCodepage,
    String guiBuild = constGuiBuild,
    String clientAddr = constClientAddr}) {
  final cp = codepad(codepage);
  final out = BytesBuilder(copy: false);
  out.add(Uint8List.fromList([
    ..._hex('01010008010101010401010001010103000400000e0b01030106000b040101'
        '000105010000002301060007000f'),
    ..._field(clientAddr, 15),
    ..._hex('00070018'),
  ]));
  final addr2 = codepad(clientAddr);
  out.add(_u16b(addr2.length));
  out.add(addr2);
  out.add(_hex('001800110001'));
  out.add(cp);
  out.add(_hex('001100130004'));
  out.add(_field(guiBuild, 4));
  out.add(_hex('001300120004'));
  out.add(_field(guiBuild, 4));
  out.add(_hex('001200060006'));
  out.add(codepad('SAPGUI'));
  out.add(_hex('0006001700000017050000000500'));
  final res = out.takeBytes();
  // 128 bytes with the constant address; another address (the session's
  // own, `an address` on a recorded session) sizes its 0018 token
  final want = 0x80 + codepad(clientAddr).length - codepad(constClientAddr).length;
  if (res.length != want) throw StateError('const prefix ${res.length}B != $want');
  return res;
}

Uint8List codepad(String s) => Uint8List.fromList(s.codeUnits);

Uint8List _hex(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Uint8List _u16b(int v) {
  final o = Uint8List(2);
  o.buffer.asByteData().setUint16(0, v);
  return o;
}

final Uint8List constPrefix = composeConstPrefix();
final Uint8List spaces256 = Uint8List(256)..fillRange(0, 256, 0x20);
const Set<String> dropColumns = {'RFC_QUEUE', 'ERROR_INFO', 'VERBS', 'IMPORT_XML'};
const List<int> rfcTerm = [0xff, 0xff, 0x00, 0x00, 0xff, 0xff];
const int tableInlineMax = cellSeg; // <= 250 B -> inline 03 04 rows

Uint8List _tok(List<int> tag, Uint8List data) {
  final out = Uint8List(2 + 2 + data.length + 2);
  out[0] = tag[0];
  out[1] = tag[1];
  out.buffer.asByteData().setUint16(2, data.length);
  out.setRange(4, 4 + data.length, data);
  out[out.length - 2] = tag[0];
  out[out.length - 1] = tag[1];
  return out;
}

/// The body of one reply table column after its `03 02` dims: inline `03 04`
/// rows when the table fits one segment, else one LZH `03 05` cell + `03 06`.
Uint8List tableColumn(List<Uint8List> rows, {int? width}) {
  if (rows.isEmpty) return Uint8List(0);
  final total = rows.fold(0, (a, r) => a + r.length);
  if (total <= tableInlineMax) {
    final out = BytesBuilder(copy: false);
    for (final r in rows) {
      out.add(_tok([0x03, 0x04], r));
    }
    return out.takeBytes();
  }
  final w = width ?? rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
  final body = Uint8List(w * rows.length);
  var off = 0;
  for (final r in rows) {
    final cut = r.length > w ? w : r.length;
    body.setRange(off, off + cut, Uint8List.sublistView(r, 0, cut));
    off += w;
  }
  return Uint8List.fromList([
    ...wrap0305Cell(lzhCompress(body)),
    ..._tok([0x03, 0x06], Uint8List(0)),
  ]);
}

class CallColumn {
  CallColumn(this.name, this.desc, this.cellLzh, this.rows);
  final String name;
  final Uint8List? desc; // the 03 02 descriptor bytes
  final Uint8List? cellLzh;
  final List<Uint8List>? rows;
}

/// Ordered columns named PARAMS / VARS / VERBS / XML_DATA_STREAM in the CALL.
List<CallColumn> parseCallColumns(Uint8List callRfc) {
  final b = callRfc;
  final bd = b.buffer.asByteData(b.offsetInBytes, b.lengthInBytes);
  final cellAt = <int, Cell0305>{};
  for (final c in find0305Cells(b)) {
    cellAt[c.openOff] = c;
  }
  final cols = <CallColumn>[];
  const want = {'PARAMS', 'VARS', 'XML_DATA_STREAM', 'VERBS'};
  var i = 0;
  final n = b.length;
  while (i < n - 4) {
    if (b[i] == 0x03 && b[i + 1] == 0x01) {
      final ln = bd.getUint16(i + 2);
      if (i + 4 + ln + 2 <= n) {
        final name = String.fromCharCodes(b, i + 4, i + 4 + ln);
        if (b[i + 4 + ln] == 0x03 && b[i + 5 + ln] == 0x01 && want.contains(name)) {
          var j = i + 6 + ln;
          Uint8List? desc;
          if (j + 4 <= n && b[j] == 0x03 && b[j + 1] == 0x02) {
            final dl = bd.getUint16(j + 2);
            desc = Uint8List.sublistView(b, j + 4, j + 4 + dl);
            j += 6 + dl;
          }
          // a BARE `03 02` (no length word) can sit between the desc and
          // the content — the the test system-class call dialect (prd's omits it);
          // without the skip the cell never attaches and the reply drops
          // the column's table
          while (j + 2 <= n &&
              b[j] == 0x03 &&
              b[j + 1] == 0x02 &&
              (j + 4 > n ||
                  (b[j + 2] == 0x03 &&
                      (b[j + 3] == 0x04 || b[j + 3] == 0x05)))) {
            j += 2;
          }
          Uint8List? cellLzh;
          List<Uint8List>? rows;
          final cell = cellAt[j];
          if (cell != null) {
            final p = parse0305Cell(cell.bytes);
            cellLzh = p?.lzh;
          } else if (j + 4 <= n && b[j] == 0x03 && b[j + 1] == 0x04) {
            rows = [];
            while (j + 4 <= n && b[j] == 0x03 && b[j + 1] == 0x04) {
              final rl = bd.getUint16(j + 2);
              rows.add(Uint8List.sublistView(b, j + 4, j + 4 + rl));
              j += 6 + rl;
            }
          }
          cols.add(CallColumn(name, desc, cellLzh, rows));
        }
      }
    }
    i += 1;
  }
  return cols;
}

/// Default PARAMS plaintext transform: input rows -> a single space,
/// _RESULT rows passed through.
List<Uint8List> transformParamsRows(List<Uint8List> rows) {
  return [
    for (final r in rows)
      r.length >= 39 &&
              String.fromCharCodes(r, 8, 39).trim().startsWith('_RESULT')
          ? r
          : Uint8List.fromList([0x20])
  ];
}

/// Build the client-reply RFC_TR container for an OLE_FLUSH_CALL
/// (build_reply port).
Uint8List buildReply(
  Uint8List callRfc,
  Uint8List replySvarsLzh, {
  List<Uint8List> auxCells = const [],
  Uint8List? controlXml,
  List<Uint8List>? paramsRows,
  Uint8List? svarsXml,
  List<Uint8List>? paramsInline,
  Uint8List? prefix,
}) {
  final cols = parseCallColumns(callRfc);
  final out = BytesBuilder(copy: false)..add(prefix ?? constPrefix);
  if (svarsXml != null) {
    out.add(_tok([0x3c, 0x02], Uint8List(0)));
    out.add(_tok([0x3c, 0x05], svarsXml));
    out.add(_tok([0x3c, 0x02], Uint8List(0)));
  }
  if (controlXml != null) {
    out.add(_tok([0x02, 0x01], codepad('EXPORT_XML')));
    out.add(_tok([0x02, 0x03], controlXml));
  }
  out.add(_tok([0x02, 0x01], codepad('EXCEPT_DESCRIPT')));
  out.add(_tok([0x02, 0x03], spaces256));

  final drop = {...dropColumns};
  if (controlXml != null) drop.add('XML_DATA_STREAM');
  // cells attach by COLUMN NAME, never queue order: the call's columns can
  // carry PARAMS and VARS as cells in either order (the prd full-build
  // queue is PARAMS-first) — a swapped assignment puts the VARS table under
  // PARAMS and the kernel rejects the reply (SAPLOLEA SYSTEM_FAILURE)
  final cellByName = <String, Uint8List>{};
  if (replySvarsLzh.isNotEmpty) cellByName['VARS'] = replySvarsLzh;
  final cellq = <Uint8List>[...auxCells]; // extra cells, in order
  for (final col in cols) {
    if (drop.contains(col.name)) continue;
    out.add(_tok([0x03, 0x01], codepad(col.name)));
    out.add(_tok([0x03, 0x02], col.desc ?? Uint8List(0)));
    if (col.name == 'PARAMS' && paramsInline != null) {
      for (final r in paramsInline) {
        out.add(_tok([0x03, 0x04], r));
      }
      continue;
    }
    if (col.cellLzh != null) {
      final lzh = cellByName.remove(col.name) ??
          (cellq.isNotEmpty ? cellq.removeAt(0) : col.cellLzh!);
      out.add(wrap0305Cell(lzh));
      out.add(_tok([0x03, 0x06], Uint8List(0)));
    } else if (col.rows != null) {
      final rowsSource = paramsRows ?? transformParamsRows(col.rows!);
      for (final r in rowsSource) {
        out.add(_tok([0x03, 0x04], r));
      }
    }
  }
  out.add(Uint8List.fromList(rfcTerm));
  return out.takeBytes();
}

// ---------------------------------------------------------------------------
// DP_GET_CLIENT_TABLE45A answer envelope (build_dp_answer port)
// ---------------------------------------------------------------------------

/// One DATAASC/FORMAT/PROPS table column region for a DP answer.
Uint8List dpTableColumn(String name, int width, int count, Uint8List cell) {
  // 03 01 name | 03 02 <desc 8B: width u32, count u32> | 03 05 cell | 03 06
  final desc = Uint8List(8);
  desc.buffer.asByteData().setUint32(0, width);
  desc.buffer.asByteData().setUint32(4, count);
  return Uint8List.fromList([
    ..._tok([0x03, 0x01], codepad(name)),
    ..._tok([0x03, 0x02], desc),
    ...wrap0305Cell(cell),
    ..._tok([0x03, 0x06], Uint8List(0)),
  ]);
}

/// One RFC scalar in the DP container wire shape: `02 01 <len> NAME 02 01 /
/// 02 03 <len> VALUE 02 03` — the encoding the server's own DP_PUT uses.
Uint8List dpScalarPair(String name, String value) {
  final n = codepad(name);
  final v = codepad(value);
  return Uint8List.fromList([
    0x02, 0x01, ..._u16b(n.length), ...n, 0x02, 0x01,
    0x02, 0x03, ..._u16b(v.length), ...v, 0x02, 0x03,
  ]);
}

const List<String> dpgetImporting = [
  'TYPE', 'SUBTYPE', 'DATE', 'TIME', 'DESCRIPTION', 'TOTALSIZE', 'PLATTFORM'
];

/// The advertised GUI version (753.0) as the LE double of the 06 67 trailer.
final Uint8List propsVersion = () {
  final o = Uint8List(8);
  ByteData.view(o.buffer).setFloat64(0, 753.0, Endian.little);
  return o;
}();

/// The DP answer: CONST_PREFIX + the IMPORTING scalars + the caller's table
/// region + the 06 67 GUI-version trailer + the RFC terminator.
Uint8List buildDpAnswer(
    {required Map<String, String> scalars,
    required Uint8List tableRegion,
    List<(String, String)> extraScalars = const [],
    bool trailer = true,
    Uint8List? prefix}) {
  final out = BytesBuilder(copy: false)..add(prefix ?? constPrefix);
  for (final name in dpgetImporting) {
    final v = scalars[name];
    if (v == null) continue;
    out.add(dpScalarPair(name, v));
  }
  for (final (name, value) in extraScalars) {
    out.add(dpScalarPair(name, value));
  }
  out.add(tableRegion);
  if (trailer) {
    out.add(_tok([0x06, 0x67], propsVersion));
  }
  out.add(Uint8List.fromList(rfcTerm));
  return out.takeBytes();
}

/// Table rows laid out by a request's own X-UNKNOWN FORMAT (the field-name
/// slot is the column INDEX '1', '2', …): fixed-width records.
Uint8List rowsByIndex(List<Map<String, String>> rows, List<(String, int)> fields) {
  final w = fields.fold(0, (a, f) => a + f.$2);
  final out = Uint8List(w * rows.length);
  var r = 0;
  for (final row in rows) {
    var off = r * w;
    for (final (name, len) in fields) {
      var v = row[name] ?? '';
      if (v.length > len) v = v.substring(0, len);
      for (var i = 0; i < v.length; i++) {
        out[off + i] = v.codeUnitAt(i) & 0xff;
      }
      off += len;
    }
    r++;
  }
  return out;
}
