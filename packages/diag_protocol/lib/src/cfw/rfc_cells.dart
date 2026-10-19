/// RFC_TR container `03 05` cells — the compressed SVARS/table columns
/// (diag_rfc port).
library;

import 'dart:typed_data';

import '../codepages.dart';
import '../lzh/lzh.dart';

const int cellSeg = 250;
const List<int> cellLead = [0x7b, 0x02, 0x00, 0xea];

/// The empty `03 06` token that closes a table column's LZH cell.
const List<int> cellTableClose = [0x03, 0x06, 0x00, 0x00, 0x03, 0x06];

class Cell0305 {
  Cell0305(this.openOff, this.endOff, this.bytes);
  final int openOff;
  final int endOff;

  /// concatenated segment bytes (the CELL: lead + u32 lzh-len + lzh + pad)
  final Uint8List bytes;
}

/// Every `03 05` cell in [b]: a cell opens with the tag + u16-length
/// segments, reframes `03 05 03 05` between segments, closes with a bare
/// `03 05`.
///
/// Linear: a candidate whose chain breaks is retried one byte on, and the
/// next candidate is often a reframe `03 05` of that same chain — whose
/// walk joins the broken one at a segment header it already read. The
/// chain from a given segment header has ONE outcome, so every header of a
/// broken chain is marked and a walk that reaches one fails at once (a
/// header of a WHOLE chain is never met again: the scan resumes past it).
List<Cell0305> find0305Cells(Uint8List b) {
  final cells = <Cell0305>[];
  final n = b.length;
  final bd = b.buffer.asByteData(b.offsetInBytes, b.lengthInBytes);
  Uint8List? broken; // segment-header offsets of chains that broke
  final heads = <int>[];
  var i = 0;
  while (i < n - 1) {
    i = _find(b, 0x03, 0x05, i);
    if (i < 0) break;
    var j = i + 2;
    final segs = BytesBuilder(copy: false);
    var ok = true;
    heads.clear();
    while (true) {
      if (j + 2 > n || (broken != null && broken[j] != 0)) {
        ok = false;
        break;
      }
      heads.add(j);
      final sl = bd.getUint16(j);
      if (j + 2 + sl > n) {
        ok = false;
        break;
      }
      segs.add(Uint8List.sublistView(b, j + 2, j + 2 + sl));
      j += 2 + sl;
      if (!_at(b, j, 0x03, 0x05)) {
        ok = false;
        break;
      }
      if (_at(b, j + 2, 0x03, 0x05)) {
        j += 4; // reframe -> next segment
        continue;
      }
      j += 2; // bare 03 05 -> cell close
      break;
    }
    if (ok) {
      cells.add(Cell0305(i, j, segs.takeBytes()));
      i = j;
    } else {
      broken ??= Uint8List(n);
      for (final h in heads) {
        broken[h] = 1;
      }
      i += 1;
    }
  }
  return cells;
}

bool _at(Uint8List b, int off, int a, int c) =>
    off + 1 < b.length && b[off] == a && b[off + 1] == c;

int _find(Uint8List b, int a, int c, int from) {
  for (var i = from; i + 1 < b.length; i++) {
    if (b[i] == a && b[i + 1] == c) return i;
  }
  return -1;
}

class ParsedCell {
  ParsedCell(this.lead6, this.lzh, this.padLen);
  final Uint8List lead6;
  final Uint8List lzh;
  final int padLen;
}

/// cell bytes -> (lead, lzh stream, pad length); null when malformed.
/// The lead is NOT validated: our writer emits `7b 02 00 ea`, the real
/// kernel's varies (`7b 02 c6 ea` on the test system) — only the u32 BE length at
/// [4:8] is structural (the engine's reader checks nothing either).
ParsedCell? parse0305Cell(Uint8List cell) {
  if (cell.length < 8) return null;
  final lzhLen = cell.buffer
      .asByteData(cell.offsetInBytes, cell.lengthInBytes)
      .getUint32(4);
  // a declared length a few bytes past the cell end is real kernel output
  // (the the test system Easy Access 88-verb queue's VARS cell: 995 declared, 992
  // present) — take what the cell holds, as the engine's slice does; a
  // null here dropped the VARS cell from the reply (SAPLOLEA SYSTEM_FAILURE)
  final end = 8 + lzhLen < cell.length ? 8 + lzhLen : cell.length;
  return ParsedCell(Uint8List.sublistView(cell, 0, 6),
      Uint8List.sublistView(cell, 8, end), cell.length - end);
}

/// Serialize an LZH stream into a framed `03 05` cell (tag..tag inclusive).
Uint8List wrap0305Cell(Uint8List lzhBytes) {
  final content = BytesBuilder(copy: false)
    ..add(Uint8List.fromList(cellLead.sublist(0, 4)))
    ..add(_u32(lzhBytes.length))
    ..add(lzhBytes);
  var c = content.takeBytes();
  final nseg = (c.length + cellSeg - 1) ~/ cellSeg;
  final padded = Uint8List(nseg * cellSeg);
  padded.setRange(0, c.length, c);
  final out = BytesBuilder(copy: false)..add(_u16(0x0305));
  for (var i = 0; i < nseg; i++) {
    if (i > 0) {
      out.add(Uint8List.fromList([0x03, 0x05, 0x03, 0x05]));
    }
    final seg = Uint8List.sublistView(padded, i * cellSeg, (i + 1) * cellSeg);
    out.add(_u16(seg.length));
    out.add(seg);
  }
  out.add(_u16(0x0305));
  return out.takeBytes();
}

/// Flatten the `<03 05 03 05> <u16 len> <payload>` cell transport of an
/// object embedded at [start] (D.deframe port).
Uint8List deframeCellTransport(Uint8List b, int start) {
  final out = BytesBuilder(copy: false);
  var i = start;
  while (i < b.length) {
    var p = _find(b, 0x03, 0x05, i);
    // the reframe marker is 03 05 03 05
    if (p >= 0 && _at(b, p + 2, 0x03, 0x05)) {
      out.add(Uint8List.sublistView(b, i, p));
      if (p + 6 > b.length) {
        return out.takeBytes(); // truncated length word
      }
      final len = b.buffer
          .asByteData(b.offsetInBytes, b.lengthInBytes)
          .getUint16(p + 4);
      final payloadStart = p + 6;
      final payloadEnd = (payloadStart + len > b.length) ? b.length : payloadStart + len;
      out.add(Uint8List.sublistView(b, payloadStart, payloadEnd));
      i = payloadEnd;
      if (payloadStart + len > b.length) return out.takeBytes();
      continue;
    }
    out.add(Uint8List.sublistView(b, i));
    break;
  }
  return out.takeBytes();
}

/// Decompress the object at the first `1f 9d` anchored 5 bytes back, with
/// clean-truncation report (dc_eof port for cell objects).
(Uint8List, bool) dcObject(Uint8List framed) {
  final flat = deframeCellTransport(framed, 0);
  final m = _find(flat, 0x1f, 0x9d, 0);
  if (m < 5) return (Uint8List(0), false);
  final cs = Uint8List.sublistView(flat, m - 5);
  final out = lzhInflate(cs);
  if (out != null) return (out, false);
  final hdr = parseCsHeader(cs);
  if (hdr == null) return (Uint8List(0), false);
  final (partial, err) = lzhReferenceDecodePartial(cs);
  final truncated = err == 'unexpected end of compressed data' ||
      (err == null && partial.length != hdr.declaredLen);
  return (partial, truncated);
}

Uint8List _u16(int v) {
  final o = Uint8List(2);
  o.buffer.asByteData().setUint16(0, v);
  return o;
}

Uint8List _u32(int v) {
  final o = Uint8List(4);
  o.buffer.asByteData().setUint32(0, v);
  return o;
}

/// Convenience: decode a cell's SVARS blob (LZH → raw table bytes).
Uint8List? cellBlob(Cell0305 cell) {
  final p = parse0305Cell(cell.bytes);
  if (p == null) return null;
  return lzhInflate(p.lzh);
}

/// latin1 text helper for fixed-width record fields.
String recText(Uint8List raw, [int start = 0, int? end]) {
  final e = end ?? raw.length;
  return String.fromCharCodes(raw, start, e);
}

/// utf-8 re-read of a latin1-decoded value (ea_flushcall.arg_text): the wire
/// carries the session codepage (UTF-8 on 4110).
String argText(String v) {
  final s = v.trim();
  // encode each char ≤ 0xFF back to bytes, then decode UTF-8
  final bytes = Uint8List(s.length);
  var n = 0;
  for (final cu in s.codeUnits) {
    if (cu > 0xff) return s; // already decoded text
    bytes[n++] = cu;
  }
  return wireDecode(Uint8List.sublistView(bytes, 0, n));
}
