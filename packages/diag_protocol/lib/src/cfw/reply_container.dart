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
/// a recorded session gui[2] and a recorded session a private
/// `10.x.x.x` LAN address), and the kernel does not re-validate it (reference client
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
  // own, a `10.x.x.x` LAN address on a recorded session) sizes
  // its 0018 token
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

// ---------------------------------------------------------------------------
// The RFC_TR container's token tags (two bytes, `<a> <b>` — spelled here as
// the u16 `0xaabb`, the frontend_rfc.dart rfcTag* convention). The flush
// call's reply and the DP / DOI / stream / listbox answers are all this
// grammar (audit 2026-10-23 §6.6) — dp_cache.dart, doi.dart,
// stream_paint.dart, html_viewer.dart and listbox_valueset.dart read and
// write it through these names too.
// ---------------------------------------------------------------------------

/// `02 01` — a parameter's NAME (`EXPORT_XML`, `EXCEPT_DESCRIPT`, a DP
/// answer's IMPORTING scalars; frontend_rfc.dart's rfcTagParamName).
const int rfcTagParamName = 0x0201;

/// `02 03` — the parameter's VALUE following its name.
const int rfcTagParamValue = 0x0203;

/// `03 01` — a table column's NAME (`PARAMS`, `VARS`, `XML_DATA_STREAM`,
/// `VERBS`; a DP answer's `DATAASC` / `FORMAT` / `PROPS`).
const int rfcTagColumnName = 0x0301;

/// `03 02` — the column's descriptor (8 bytes: width u32, count u32).
const int rfcTagColumnDesc = 0x0302;

/// `03 04` — one inline table row (tables up to [tableInlineMax]).
const int rfcTagTableRow = 0x0304;

/// `03 05` — an LZH cell segment (rfc_cells.dart [wrap0305Cell]).
const int rfcTagTableCell = 0x0305;

/// `03 06` — the cell's close after its last segment.
const int rfcTagTableClose = 0x0306;

/// `02 13` — the end of a DP table's columns (the pull's / push's table
/// close that bounds the last column; dp_cache.dart, doi.dart).
const int rfcTagTableEnd = 0x0213;

/// `06 67` — the GUI-version trailer of a DP answer ([propsVersion]; the
/// same tag frontend_rfc.dart reads as rfcTagStats).
const int rfcTagVersionTrailer = 0x0667;

/// `3c 02` — the SVARS section's delimiter (empty, before and after
/// [rfcTagSvarsXml]).
const int rfcTagSvarsSection = 0x3c02;

/// `3c 05` — the SVARS XML the reply carries.
const int rfcTagSvarsXml = 0x3c05;

/// The two bytes of a u16 tag, for a byte-stream literal
/// (`...rfcTagBytes(rfcTagColumnName)`).
List<int> rfcTagBytes(int tag) => [tag >> 8, tag & 0xff];

/// A column-name token `03 01 <len u16> <name> 03 01` — the anchor a DP /
/// DOI column is found by and the header its answer is written with.
Uint8List rfcColumnNameToken(String name) {
  final n = name.codeUnits;
  return Uint8List.fromList([
    ...rfcTagBytes(rfcTagColumnName),
    (n.length >> 8) & 0xff, n.length & 0xff,
    ...n,
    ...rfcTagBytes(rfcTagColumnName),
  ]);
}

/// The u16 tag at [at] of [b] (`b[at] << 8 | b[at + 1]`), -1 past the end.
int rfcTagAt(Uint8List b, int at) =>
    at + 2 <= b.length ? (b[at] << 8) | b[at + 1] : -1;

/// One RFC reply token `<a> <b> <len u16> <data> <a> <b>` — the builder
/// every reply / answer shares. A token's length is a u16: [data] past 64 KB
/// throws instead of wrapping (a wrapped length desyncs the server's token
/// walk); a bigger payload rides LZH `03 05` cells ([tableColumn]).
Uint8List rfcToken(int a, int b, Uint8List data) {
  if (data.length > 0xffff) {
    throw ArgumentError.value(data.length, 'data.length',
        'RFC token $a/$b exceeds the u16 length');
  }
  final out = Uint8List(2 + 2 + data.length + 2);
  out[0] = a;
  out[1] = b;
  out.buffer.asByteData().setUint16(2, data.length);
  out.setRange(4, 4 + data.length, data);
  out[out.length - 2] = a;
  out[out.length - 1] = b;
  return out;
}

Uint8List _tok(int tag, Uint8List data) =>
    rfcToken(tag >> 8, tag & 0xff, data);

/// The body of one reply table column after its `03 02` dims: inline `03 04`
/// rows when the table fits one segment, else one LZH `03 05` cell + `03 06`.
Uint8List tableColumn(List<Uint8List> rows, {int? width}) {
  if (rows.isEmpty) return Uint8List(0);
  final total = rows.fold(0, (a, r) => a + r.length);
  if (total <= tableInlineMax) {
    final out = BytesBuilder(copy: false);
    for (final r in rows) {
      out.add(_tok(rfcTagTableRow, r));
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
    ..._tok(rfcTagTableClose, Uint8List(0)),
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
    if (rfcTagAt(b, i) == rfcTagColumnName) {
      final ln = bd.getUint16(i + 2);
      if (i + 4 + ln + 2 <= n) {
        final name = String.fromCharCodes(b, i + 4, i + 4 + ln);
        if (rfcTagAt(b, i + 4 + ln) == rfcTagColumnName && want.contains(name)) {
          var j = i + 6 + ln;
          Uint8List? desc;
          if (j + 4 <= n && rfcTagAt(b, j) == rfcTagColumnDesc) {
            final dl = bd.getUint16(j + 2);
            // a wire length past the buffer is a truncated/hostile call:
            // skip this candidate rather than throw out of the reply build
            // (an unanswered flush blocks the kernel in OLE_FLUSH_CALL)
            if (j + 4 + dl > n) {
              i += 1;
              continue;
            }
            desc = Uint8List.sublistView(b, j + 4, j + 4 + dl);
            j += 6 + dl;
          }
          // a BARE `03 02` (no length word) can sit between the desc and
          // the content — the the test system-class call dialect (prd's omits it);
          // without the skip the cell never attaches and the reply drops
          // the column's table
          while (rfcTagAt(b, j) == rfcTagColumnDesc &&
              (j + 4 > n ||
                  rfcTagAt(b, j + 2) == rfcTagTableRow ||
                  rfcTagAt(b, j + 2) == rfcTagTableCell)) {
            j += 2;
          }
          Uint8List? cellLzh;
          List<Uint8List>? rows;
          final cell = cellAt[j];
          if (cell != null) {
            final p = parse0305Cell(cell.bytes);
            cellLzh = p?.lzh;
          } else if (j + 4 <= n && rfcTagAt(b, j) == rfcTagTableRow) {
            rows = [];
            while (j + 4 <= n && rfcTagAt(b, j) == rfcTagTableRow) {
              final rl = bd.getUint16(j + 2);
              if (j + 4 + rl > n) break;
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
    out.add(_tok(rfcTagSvarsSection, Uint8List(0)));
    out.add(_tok(rfcTagSvarsXml, svarsXml));
    out.add(_tok(rfcTagSvarsSection, Uint8List(0)));
  }
  if (controlXml != null) {
    out.add(_tok(rfcTagParamName, codepad('EXPORT_XML')));
    out.add(_tok(rfcTagParamValue, controlXml));
  }
  out.add(_tok(rfcTagParamName, codepad('EXCEPT_DESCRIPT')));
  out.add(_tok(rfcTagParamValue, spaces256));

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
    out.add(_tok(rfcTagColumnName, codepad(col.name)));
    out.add(_tok(rfcTagColumnDesc, col.desc ?? Uint8List(0)));
    if (col.name == 'PARAMS' && paramsInline != null) {
      for (final r in paramsInline) {
        out.add(_tok(rfcTagTableRow, r));
      }
      continue;
    }
    if (col.cellLzh != null) {
      final lzh = cellByName.remove(col.name) ??
          (cellq.isNotEmpty ? cellq.removeAt(0) : col.cellLzh!);
      out.add(wrap0305Cell(lzh));
      out.add(_tok(rfcTagTableClose, Uint8List(0)));
    } else if (col.rows != null) {
      final rowsSource = paramsRows ?? transformParamsRows(col.rows!);
      for (final r in rowsSource) {
        out.add(_tok(rfcTagTableRow, r));
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
    ..._tok(rfcTagColumnName, codepad(name)),
    ..._tok(rfcTagColumnDesc, desc),
    ...wrap0305Cell(cell),
    ..._tok(rfcTagTableClose, Uint8List(0)),
  ]);
}

/// One RFC scalar in the DP container wire shape: `02 01 <len> NAME 02 01 /
/// 02 03 <len> VALUE 02 03` — the encoding the server's own DP_PUT uses.
Uint8List dpScalarPair(String name, String value) {
  final n = codepad(name);
  final v = codepad(value);
  return Uint8List.fromList([
    ..._tok(rfcTagParamName, n),
    ..._tok(rfcTagParamValue, v),
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
    out.add(_tok(rfcTagVersionTrailer, propsVersion));
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
