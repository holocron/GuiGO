/// SVARS: the OLE_FLUSH_CALL variable-table columns (diag_svars port).
library;

import 'dart:convert';
import 'dart:math' show min;
import 'dart:typed_data';

import '../framing/decode_stats.dart';
import '../framing/envelope.dart' show indexOfBytes;
import '../lzh/lzh.dart';
import 'rfc_cells.dart';

const int paramsW = 44;
const int varsW = 337;
const int verbsW = 53;

final RegExp _fourDigits = RegExp(r'^\d{4}$');
final RegExp _valueRe = RegExp('<VALUE>(.*?)</VALUE>', dotAll: true);
final RegExp _charRefRe = RegExp(r'&#(\d+);');

class Rec {
  Rec(this.idx, this.raw);

  final int idx;
  final Uint8List raw;
  late final int width = raw.length;

  // clamped at both ends: a record cut short (a hostile / corrupt cell)
  // reads its missing fields as empty, never a RangeError out of the parse
  String _t(int start, int end) => start >= raw.length
      ? ''
      : String.fromCharCodes(raw, start, end < raw.length ? end : raw.length);

  // The fields are decoded once per record: a flush's PARAMS / VARS rows
  // are read by every side model of the call and a record's
  // bytes never change.
  late final String name =
      width == paramsW ? _t(8, 39).trimRight() : _t(0, 32).trimRight();

  late final String objid =
      width == paramsW ? _t(0, 4).trim() : _t(32, 41).trim();

  late final String type = _type();

  String _type() {
    if (width == paramsW) {
      final four = _t(0, 4);
      if (_fourDigits.hasMatch(four)) return _t(4, 7).trim();
      return _t(3, 7).trim();
    }
    return _t(41, 42).trim();
  }

  /// PARAMS: the VARS slot; VARS: the value cell.
  late final String slot =
      width == paramsW ? _t(39, 44).trim() : _t(42, width).trimRight();

  /// The value cell up to its first NUL — a view of [raw], no copy.
  Uint8List get valueBytes {
    if (raw.length <= 42) return Uint8List(0);
    for (var i = 42; i < raw.length; i++) {
      if (raw[i] == 0) return Uint8List.sublistView(raw, 42, i);
    }
    return Uint8List.sublistView(raw, 42);
  }

  /// [valueBytes] as text, trimmed (an argument value as the verb readers
  /// take it), decoded once — in the session codepage: UTF-8 on 4110, so
  /// an AddButton quickinfo reads `Entrées possibles`, not `EntrÃ©es
  /// possibles` (a recorded session srv[11] toolbar 151); a value that
  /// is no valid UTF-8 stays latin-1 (the reference client's ea_flushcall.arg_text).
  late final String valueText = _argText(valueBytes).trim();
}

String _argText(Uint8List b) {
  var ascii = true;
  for (final x in b) {
    if (x >= 0x80) {
      ascii = false;
      break;
    }
  }
  if (ascii) return String.fromCharCodes(b);
  try {
    return utf8.decode(b);
  } on FormatException {
    return String.fromCharCodes(b);
  }
}

/// Slice a decompressed SVARS blob into fixed-width records — none for a
/// non-positive [width] (a wire descriptor of 0 divided by zero, the flush
/// went unanswered).
List<Rec> parseSvars(Uint8List b, int width) {
  if (width <= 0) return const [];
  final n = b.length ~/ width;
  return [
    for (var i = 0; i < n; i++) Rec(i, Uint8List.sublistView(b, i * width, (i + 1) * width))
  ];
}

/// Stamp the concrete return type into a PARAMS _RESULT row IN PLACE.
void stampResultType(Uint8List rec, int t) {
  final four = String.fromCharCodes(rec, 0, 4);
  final ts = t.toString();
  if (_fourDigits.hasMatch(four)) {
    _padInto(rec, 4, 3, ts);
  } else {
    _padInto(rec, 3, 4, ' $ts');
  }
}

void _padInto(Uint8List rec, int off, int width, String s) {
  final padded = s.length >= width ? s.substring(0, width) : s.padRight(width);
  for (var i = 0; i < width; i++) {
    rec[off + i] = padded.codeUnitAt(i);
  }
}

class SvarsColumn {
  SvarsColumn(this.name, this.width, this.count, this.blob);
  final String? name;
  final int? width;
  final int? count;
  final Uint8List blob;
}

const int _geomBlock = 14;

String? _nameBefore(Uint8List b, int end) {
  if (end < 6 || b[end - 2] != 0x03 || b[end - 1] != 0x01) return null;
  for (var ln = 0; ln < 256; ln++) {
    final start = end - 2 - ln - 4;
    if (start < 0) break;
    if (b[start] == 0x03 && b[start + 1] == 0x01 && b[start + 2] == 0x00 && b[start + 3] == ln) {
      return String.fromCharCodes(b, start + 4, start + 4 + ln);
    }
  }
  return null;
}

/// {colname: (recwidth, reccount, blob)} for every `03 05` cell, geometry
/// from the preceding `03 02` descriptor, blob LZH-decoded. A column named
/// in [except] is recorded with an EMPTY blob, never inflated — its
/// presence is all the caller reads (a DP push's RFC_QUEUE, multi-MB, is
/// inflated by the DP cache, not by every flush parse).
Map<String, SvarsColumn> rfcColumns(Uint8List rfc,
    {Set<String>? only, Set<String>? except}) {
  final out = <String, SvarsColumn>{};
  final bd = rfc.buffer.asByteData(rfc.offsetInBytes, rfc.lengthInBytes);
  for (final cell in find0305Cells(rfc)) {
    if (cell.bytes.length < 8) continue;
    int? w;
    int? c;
    final o = cell.openOff;
    if (o >= 12 && rfc[o - 2] == 0x03 && rfc[o - 1] == 0x02 &&
        rfc[o - 12] == 0x00 && rfc[o - 11] == 0x08) {
      w = bd.getUint32(o - 10);
      c = bd.getUint32(o - 6);
      // a zero width is no geometry (the readers fall back to the column's
      // known record width)
      if (w == 0) w = c = null;
    }
    String? name = w != null ? _nameBefore(rfc, o - _geomBlock) : null;
    name ??= _scanNameBack(rfc, o);
    if (only != null && !only.contains(name)) continue;
    if (except != null && except.contains(name)) {
      out.putIfAbsent(name ?? '', () => SvarsColumn(name, w, c, Uint8List(0)));
      continue;
    }
    // the u32 BE at [4:8] (parse0305Cell): a cell past 64 KB declares its
    // high half there — /AIF/IFMON's step-38 RFC_QUEUE (a recorded session
    // aif raw srv[25..32], the date navigator's 711 DayInfo pushes:
    // `00 01 45 04` = 83204 bytes) read as u16 0x4504 did not inflate and
    // every push of the call was lost
    final lzhLen = cell.bytes.buffer
        .asByteData(cell.bytes.offsetInBytes, cell.bytes.lengthInBytes)
        .getUint32(4);
    // the declared length can overrun the cell by a few bytes (the 88-verb
    // the test system Easy Access queue's VARS: 995 declared, 992 present) — read what
    // the cell holds, as the engine's slice `cell[8:8+lzh_len]` does;
    // skipping the cell lost VARS and the answer went out without it
    // (SAPLOLEA SYSTEM_FAILURE at the logon flush)
    final end = 8 + lzhLen < cell.bytes.length ? 8 + lzhLen : cell.bytes.length;
    DecodeStats.cellInflates++;
    final blob = lzhInflate(Uint8List.sublistView(cell.bytes, 8, end));
    if (blob == null) continue;
    // first cell with a given name wins (setdefault)
    final key = name ?? '';
    if (!out.containsKey(key)) {
      out[key] = SvarsColumn(name, w, c, blob);
    }
  }
  return out;
}

/// The column names an RFC_TR table region can be anchored on.
const List<String> _tableColumns = [
  'PARAMS', 'VARS', 'VERBS', 'RFC_QUEUE', 'XML_DATA_STREAM', 'ERROR_INFO',
  'IMPORT_XML', 'EXPORT_XML',
];

/// The INLINE `03 04` rows of one table column of an RFC_TR value, exactly
/// [width] bytes each (result_types._col port, the `raw` rows). A column is
/// anchored on its `03 01 <u16 len> NAME 03 01` descriptor and its data
/// region ends where the next column's anchor begins. A small table — the
/// PARAMS/VERBS of a one-verb query (the GetColumnWidth flush the Easy
/// Access tree answers when a transaction is launched, a recorded session
/// launch_reference srv step 19) — rides inline instead of an LZH `03 05` cell,
/// so [rfcColumns] (cells only) never sees it; empty when the column is
/// absent or cell-borne.
List<Uint8List> inlineColumnRows(Uint8List rfc, String name, int width) {
  final markers = <(String, int, int)>[]; // (name, dataStart, anchorStart)
  for (final n in _tableColumns) {
    final pat = Uint8List.fromList([0x03, 0x01, 0x00, n.length, ...n.codeUnits, 0x03, 0x01]);
    final i = _indexOf(rfc, pat);
    if (i >= 0) markers.add((n, i + pat.length, i));
  }
  markers.sort((a, b) => a.$3.compareTo(b.$3));
  final rows = <Uint8List>[];
  for (var k = 0; k < markers.length; k++) {
    if (markers[k].$1 != name) continue;
    final start = markers[k].$2;
    final end = k + 1 < markers.length ? markers[k + 1].$3 : rfc.length;
    final bd = rfc.buffer.asByteData(rfc.offsetInBytes, rfc.lengthInBytes);
    var i = start;
    while (i + 4 <= end) {
      if (rfc[i] != 0x03) {
        i++;
        continue;
      }
      final t = rfc[i + 1];
      if (t == 0x02) {
        // the column descriptor: `03 02 <u16 len> ... 03 02`
        i += 4 + bd.getUint16(i + 2) + 2;
      } else if (t == 0x04) {
        // an inline row: `03 04 <u16 len> ROW 03 04`
        final ln = bd.getUint16(i + 2);
        if (i + 4 + ln > rfc.length) break;
        if (ln == width) rows.add(Uint8List.sublistView(rfc, i + 4, i + 4 + ln));
        i += 4 + ln + 2;
      } else if (t == 0x05) {
        // a cell: skip its segments (cells are rfcColumns' business)
        var j = i + 2;
        var ok = true;
        while (true) {
          if (j + 2 > rfc.length) {
            ok = false;
            break;
          }
          final sl = bd.getUint16(j);
          if (j + 2 + sl > rfc.length) {
            ok = false;
            break;
          }
          j += 2 + sl;
          if (j + 2 > rfc.length || rfc[j] != 0x03 || rfc[j + 1] != 0x05) {
            ok = false;
            break;
          }
          if (j + 4 <= rfc.length && rfc[j + 2] == 0x03 && rfc[j + 3] == 0x05) {
            j += 4;
            continue;
          }
          j += 2;
          break;
        }
        i = ok ? j : i + 1;
      } else {
        i++;
      }
    }
    break;
  }
  return rows;
}

int _indexOf(Uint8List b, Uint8List pat) {
  for (var i = 0; i + pat.length <= b.length; i++) {
    var ok = true;
    for (var j = 0; j < pat.length; j++) {
      if (b[i + j] != pat[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

String? _scanNameBack(Uint8List b, int o) {
  final from = o - 256 > 0 ? o - 256 : 0;
  var j = o - 6;
  while (j >= from) {
    if (b[j] == 0x03 && b[j + 1] == 0x01 && b[j + 2] == 0x00) {
      final ln = b[j + 3];
      if (j + 4 + ln + 2 <= b.length &&
          b[j + 4 + ln] == 0x03 && b[j + 5 + ln] == 0x01) {
        return String.fromCharCodes(b, j + 4, j + 4 + ln);
      }
    }
    j -= 1;
  }
  return null;
}

/// Build the client-reply SVARS from the server-call SVARS (width-aware).
/// [kinds] optionally overrides each VARS row's kind byte (41) — 'O' for a
/// minted object handle, ' ' for a scalar — the request row's own kind is
/// NOT authoritative for the answer. [renames] overrides a row's NAME
/// field (an over-long value shipped as the SVARS XML item renames its row
/// `_SRESULT` with the item index as its value).
Uint8List buildReplySvars(Uint8List callsv, Map<int, Object> outValues, int width,
    {Map<int, String>? kinds, Map<int, String>? renames}) {
  final recs = parseSvars(callsv, width);
  final out = BytesBuilder(copy: false);
  // the value field of a VARS row: everything past the 42-B header — none
  // for a (hostile) narrower row, whose padRight/substring went negative
  // and left the flush unanswered
  final vw = width > 42 ? width - 42 : 0;
  for (final r in recs) {
    final isOut = r.name == '_RESULT' || r.name == '_RESULT_QUEUEONLY';
    if (width == paramsW) {
      if (isOut) {
        final rec = Uint8List.fromList(r.raw);
        stampResultType(rec, outValues[r.idx] is int ? outValues[r.idx] as int : 9);
        out.add(rec);
      } else {
        _blank(out, width); // one blanked (spaces) row, never two
      }
    } else {
      if (isOut) {
        final rec = Uint8List.fromList(r.raw);
        final kd = kinds?[r.idx];
        if (kd != null && kd.isNotEmpty && rec.length > 41) rec[41] = kd.codeUnitAt(0);
        final nm = renames?[r.idx];
        if (nm != null && nm.isNotEmpty) {
          final n = min(min(nm.length, 32), rec.length);
          rec.setRange(0, n, nm.codeUnits);
        }
        final val = outValues[r.idx];
        final s = val == null ? '' : val.toString();
        final padded = s.length >= vw ? s.substring(0, vw) : s.padRight(vw);
        for (var i = 0; i < vw; i++) {
          rec[42 + i] = padded.codeUnitAt(i);
        }
        out.add(rec);
      } else if (r.type == 'O') {
        out.add(r.raw); // object-handle row carried unchanged
      } else {
        _blank(out, width);
      }
    }
  }
  return out.takeBytes();
}

void _blank(BytesBuilder out, int width) {
  final b = Uint8List(width);
  b.fillRange(0, width, 0x20);
  out.add(b);
}

/// The long-string values a call ships in its SVARS XML column.
List<String> parseSvarsItems(Uint8List rfc) {
  // the first `<SVARS>` and the first `</SVARS>` after it bound the match
  // `<SVARS>(.*?)</SVARS>` finds (non-greedy, dotAll): only that region is stringified,
  // not the whole multi-MB call value per parse
  final open = indexOfBytes(rfc, '<SVARS>');
  if (open < 0) return [];
  final close = indexOfBytes(rfc, '</SVARS>', open + 7);
  if (close < 0) return [];
  final inner = String.fromCharCodes(rfc, open + 7, close);
  return [
    for (final v in _valueRe.allMatches(inner))
      _xmlUnescape(v.group(1) ?? '')
  ];
}

String _xmlUnescape(String s) => s
    .replaceAllMapped(_charRefRe, _xmlCharRef)
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&apos;', "'")
    .replaceAll('&quot;', '"')
    .replaceAll('&amp;', '&');

/// The character a decimal `&#N;` reference [m] (group 1: the digits)
/// names — the reference left as it stands when N is no code point: a
/// 25-digit or past-U+10FFFF reference threw out of the flush parse and
/// left the flush unanswered.
String _xmlCharRef(Match m) {
  final v = int.tryParse(m.group(1)!);
  return v != null && v <= 0x10FFFF ? String.fromCharCode(v) : m.group(0)!;
}

/// The RFC-queue ROW header the kernel opens every RFC_QUEUE row with
/// (`<24 hex id>SAPGUI` + element / part counters): 68 B, every 1 853-B
/// row, so it lands inside a DP push's 256-B chunk chain every 7 slots
/// (a recorded session raw srv[38]: gaps 324 after markers #7,
/// #14 … #35) — [queueElements] strips it BEFORE any chain is deframed.
const int queueRowHeader = 68;

/// Reassemble the SAPGUI queue ELEMENTS an RFC_QUEUE column carries
/// (queue_elements port).
List<Uint8List> queueElements(Uint8List blob, int width) {
  if (width <= queueRowHeader || blob.length < width) {
    return blob.isEmpty ? [] : [blob];
  }
  if (!isQueueRowHeader(blob)) {
    return [blob];
  }
  final parts = <String, Map<int, Uint8List>>{};
  final order = <String>[];
  for (var i = 0; i < blob.length; i += width) {
    final row = Uint8List.sublistView(blob, i, i + width > blob.length ? blob.length : i + width);
    if (row.length < queueRowHeader || !isQueueRowHeader(row)) {
      return [blob];
    }
    final id = String.fromCharCodes(row, 0, 24);
    final elem = String.fromCharCodes(row, 56, 64).trim();
    final key = '$id|$elem';
    final part = row.buffer
        .asByteData(row.offsetInBytes, row.lengthInBytes)
        .getUint32(64);
    parts.putIfAbsent(key, () {
      order.add(key);
      return {};
    })[part] = Uint8List.sublistView(row, queueRowHeader);
  }
  return [
    for (final k in order)
      _joinSorted(parts[k]!)
  ];
}

Uint8List _joinSorted(Map<int, Uint8List> parts) {
  var n = 0;
  for (final p in parts.values) {
    n += p.length;
  }
  final out = Uint8List(n);
  var off = 0;
  for (final k in parts.keys.toList()..sort()) {
    out.setRange(off, off + parts[k]!.length, parts[k]!);
    off += parts[k]!.length;
  }
  return out;
}

/// Whether [hdr] opens with a [queueRowHeader] (at least that long).
bool isQueueRowHeader(Uint8List hdr) {
  if (hdr.length < queueRowHeader) return false;
  for (var i = 0; i < 24; i++) {
    final c = hdr[i];
    if (!((c >= 48 && c <= 57) || (c >= 65 && c <= 70))) return false;
  }
  for (var i = 24; i < 30; i++) {
    if (hdr[i] != 'SAPGUI'.codeUnitAt(i - 24)) return false;
  }
  for (var i = 56; i < 64; i++) {
    final c = hdr[i];
    if (c < 48 || c > 57) return false;
  }
  return true;
}
