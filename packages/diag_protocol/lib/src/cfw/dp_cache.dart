/// DataProvider push cache: snoops DP_PUT_CLIENT_TABLE pushes nested in an
/// OLE call's RFC_QUEUE so later DP_GETs (and the DOI range model) read live
/// data (DealDataManager + ea_dpput + gridread_push ports).
library;

import 'dart:collection';
import 'dart:typed_data';

import '../framing/diag_frame.dart';
import '../framing/envelope.dart';
import '../lzh/lzh.dart';
import 'rfc_cells.dart';
import 'svars.dart';

const List<String> dpContentColumns = ['DATAASC', 'DATABIN'];

class DpPush {
  DpPush(this.url, this.seg);
  final String url;
  final Uint8List seg;
}

/// The default bounds of a SESSION's push cache ([EaSession.dpCache]): the
/// entry count unpinned pushes are held under, and the byte ceiling every
/// push — pinned ones included — is held under (the reference client's
/// diag_dealdrive _DP_CACHE_MAX / _DP_PIN_MAX_BYTES, its 54 GB SWDD runaway
/// guard). Pushes are multi-MB on ALV / chart / editor screens: an
/// unbounded cache grows for the logon's whole life.
const int dpCacheMaxEntries = 256;
const int dpCacheMaxBytes = 32 << 20;

class DpCache {
  /// A cache bounded by [maxEntries] / [maxBytes] (null = unbounded: the
  /// one-call decode caches `DpCache..ingestValue(rfc)` hold one call's
  /// pushes and die with it).
  DpCache({
    this.maxEntries,
    this.maxBytes,
    this.retain,
    this.onPut,
    this.onEvict,
  });

  final Map<String, Uint8List> byUrl = {};

  /// The cached urls in first-arrival order (a re-push keeps its place).
  final List<String> order = [];

  final int? maxEntries;
  final int? maxBytes;

  /// The retention verdict of a cached url (reference client session_push_retention):
  /// true = it feeds a LIVE control (never evicted by the entry cap, only
  /// past [maxBytes]); false = it feeds a control torn down (evicted
  /// first); null = unbound / unknown. Null callback = plain LRU.
  bool? Function(String url)? retain;

  /// Called for every push stored (new or re-pushed url).
  void Function(String url)? onPut;

  /// Called for every url evicted ([evict], the caps).
  void Function(String url)? onEvict;

  int _bytes = 0;

  /// Urls by last write, oldest first: the eviction order.
  final LinkedHashSet<String> _recency = LinkedHashSet<String>();

  /// Arrival sequence: [seq] counts stored CONTENT — a new url, or a
  /// re-push of a cached url with different bytes; [addedSince] reads them.
  int _seq = 0;
  final Map<String, int> _seqOf = {};

  /// The urls the latest [ingestFrame] / [ingestValue] stored: never
  /// evicted by that ingest's own sweep (their binding is recorded after
  /// the snoop — the reference client's `_fresh`).
  Set<String> lastIngested = const {};

  /// Bytes held over every cached segment.
  int get bytes => _bytes;

  /// The arrival counter: one more per new url stored and per re-push of
  /// a cached url whose bytes changed (a tree refreshed under its stable
  /// DESURL); a byte-identical re-push (a re-read frame) is no arrival.
  int get seq => _seq;

  /// The urls whose current content arrived after counter [since] ([seq]
  /// read earlier) — new urls and changed re-pushes — in arrival order,
  /// still cached ones only.
  List<String> addedSince(int since) {
    final out = [
      for (final u in order)
        if ((_seqOf[u] ?? 0) > since) u,
    ];
    if (out.length > 1) out.sort((a, b) => _seqOf[a]!.compareTo(_seqOf[b]!));
    return out;
  }

  /// Snoop the DP pushes of one received frame (ingest_frame port): every
  /// RFC_TR value's RFC_QUEUE rows → joined queue elements → DP_PUT segments
  /// keyed by their DESURL.
  int ingestFrame(Uint8List frame) {
    var n = 0;
    final dec = decompressFrame(frame);
    if (dec == null) {
      lastIngested = const {};
      return 0;
    }
    final fresh = <String>{};
    for (final it in dec.walk.items) {
      if (!it.isAppl || it.id != applRfcTr) continue;
      n += _ingest(it.value, fresh);
    }
    lastIngested = fresh;
    _sweep(fresh);
    return n;
  }

  int ingestValue(Uint8List rfc) {
    final fresh = <String>{};
    final n = _ingest(rfc, fresh);
    lastIngested = fresh;
    _sweep(fresh);
    return n;
  }

  /// [ingestValue] for a value the fold COMPLETED (a call joined across
  /// chunk frames — its per-frame parts were partial RFCs the frame ingest
  /// could not read): stores what it carries, without claiming
  /// [lastIngested] — the frame-level ingest's fresh set stays the
  /// binding pass's.
  int ingestJoined(Uint8List rfc) {
    final fresh = <String>{};
    final n = _ingest(rfc, fresh);
    _sweep(fresh);
    return n;
  }

  /// Whether [rfc] is one COMPLETE DP push (a DESURL decodes from it) —
  /// as opposed to the head chunk of a push the server streams across
  /// frames, whose queue may name a url its content columns have not
  /// reached yet ([foldAutomationFrame]'s head rule).
  bool isCompletePush(Uint8List rfc) => _pushesOf(rfc).isNotEmpty;

  int _ingest(Uint8List rfc, Set<String> fresh) {
    var n = 0;
    for (final (url, seg) in _pushesOf(rfc)) {
      _put(url, seg);
      fresh.add(url);
      n++;
    }
    return n;
  }

  void _put(String url, Uint8List seg) {
    final old = byUrl[url];
    if (old == null) {
      order.add(url);
      _seqOf[url] = ++_seq;
    } else {
      _bytes -= old.length;
      // a re-push keeps its place in [order] (first arrival) but is a new
      // arrival when its content changed: the fold re-decodes it
      if (!_sameBytes(old, seg)) _seqOf[url] = ++_seq;
    }
    byUrl[url] = seg;
    _bytes += seg.length;
    _recency
      ..remove(url)
      ..add(url);
    onPut?.call(url);
  }

  /// Store one push segment directly (as an ingest of that push alone).
  void put(String url, Uint8List seg) {
    _put(url, seg);
    lastIngested = {url};
    _sweep(lastIngested);
  }

  /// Drop [urls] from the cache (a torn-down control's pushes, an ended
  /// internal mode's); returns how many were cached.
  int evict(Iterable<String> urls) {
    final drop = urls.where(byUrl.containsKey).toSet();
    _drop(drop);
    return drop.length;
  }

  /// Drop every cached url [test] accepts, except [keep].
  int evictWhere(
    bool Function(String url) test, {
    Set<String> keep = const {},
  }) =>
      evict([
        for (final u in order)
          if (!keep.contains(u) && test(u)) u,
      ]);

  void _drop(Set<String> drop) {
    if (drop.isEmpty) return;
    order.removeWhere(drop.contains);
    for (final u in drop) {
      final seg = byUrl.remove(u);
      if (seg != null) _bytes -= seg.length;
      _recency.remove(u);
      _seqOf.remove(u);
      onEvict?.call(u);
    }
  }

  /// Bound the cache (reference client DealDataManager._sweep): over [maxEntries]
  /// the victims are the least recently written pushes bound to a DEAD
  /// control, then the unbound ones — never one feeding a live control nor
  /// one of [fresh]; then everything but [fresh] is held under [maxBytes],
  /// least recently written first.
  void _sweep(Set<String> fresh) {
    final maxN = maxEntries;
    if (maxN != null && order.length > maxN) {
      var excess = order.length - maxN;
      final verdict = {
        for (final u in _recency)
          if (!fresh.contains(u)) u: retain?.call(u),
      };
      final drop = <String>{};
      for (final want in const [false, null]) {
        for (final e in verdict.entries) {
          if (excess == 0) break;
          if (e.value != want) continue;
          drop.add(e.key);
          excess--;
        }
      }
      _drop(drop);
    }
    final maxB = maxBytes;
    if (maxB != null && _bytes > maxB) {
      final drop = <String>{};
      var over = _bytes - maxB;
      for (final u in _recency) {
        if (over <= 0) break;
        if (fresh.contains(u)) continue;
        drop.add(u);
        over -= byUrl[u]!.length;
      }
      _drop(drop);
    }
  }
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The (DESURL, segment) pushes an RFC value's RFC_QUEUE carries, in queue
/// order — each url with the FIRST queue element naming it (the segment a
/// lookup of that url returns). Scanned once per value object: one
/// received frame is snooped by the fold's tree pass and by the automation
/// pass, and one completed call by every side model's own push cache
/// (audit #8) — each scan re-parsed the queue column once per url.
final Expando<List<(String, Uint8List)>> _pushes = Expando('DP pushes');

List<(String, Uint8List)> _pushesOf(Uint8List rfc) =>
    _pushes[rfc] ??= _scanPushes(rfc);

List<(String, Uint8List)> _scanPushes(Uint8List rfc) {
  final cols = rfcColumns(rfc, only: {'RFC_QUEUE'});
  final col = cols['RFC_QUEUE'];
  if (col == null) return const [];
  final width = col.width ?? 0;
  if (width <= 0 || col.blob.isEmpty) return const [];
  final named = <(String, Uint8List)>[];
  final first = <String, Uint8List>{};
  for (final elem in queueElements(col.blob, width)) {
    final u = _desurlOf(elem);
    if (u == null) continue;
    named.add((u, elem));
    first.putIfAbsent(u, () => elem);
  }
  return List.unmodifiable([for (final (u, _) in named) (u, first[u]!)]);
}

/// The DESURL a DP_PUT queue element names.
String? _desurlOf(Uint8List elem) {
  // plain-text 02 01/02 03 pairs after the 02 05 column list (or directly)
  var i = 0;
  while (i < elem.length - 4) {
    if (elem[i] == 0x02 && elem[i + 1] == 0x01) {
      final ln = elem.buffer
          .asByteData(elem.offsetInBytes, elem.lengthInBytes)
          .getUint16(i + 2);
      // a real name tag closes with its own `02 01`; a stray 02 01 in the
      // element's binary header (the Windows-dialect the test system Easy Access
      // pushes have one) would otherwise jump past DESURL by a bogus length
      if (i + 6 + ln > elem.length ||
          elem[i + 4 + ln] != 0x02 ||
          elem[i + 5 + ln] != 0x01) {
        i += 1;
        continue;
      }
      final name = String.fromCharCodes(elem, i + 4, i + 4 + ln);
      var j = i + 4 + ln + 2; // closing 02 01
      if (j + 4 <= elem.length &&
          elem[j] == 0x02 && elem[j + 1] == 0x03) {
        final vl = elem.buffer
            .asByteData(elem.offsetInBytes, elem.lengthInBytes)
            .getUint16(j + 2);
        if (name == 'DESURL' && j + 4 + vl <= elem.length) {
          return String.fromCharCodes(elem, j + 4, j + 4 + vl).trim();
        }
      }
      i = j;
      continue;
    }
    i += 1;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Push content + table decode
// ---------------------------------------------------------------------------

class DpContent {
  DpContent({
    required this.url,
    required this.content,
    required this.expected,
    this.column = '',
    this.complete = false,
  });
  final String url;
  final Uint8List content;
  final int expected;
  final String column;
  final bool complete;
}

/// The raw content a DP_PUT delivers for its DESURL (dp_put_content port):
/// the DATAASC/DATABIN column's LZH object, bounded by TOTALSIZE when set.
DpContent? dpPutContent(Uint8List seg) {
  final (name, dims, cells) = dpColumnCells(seg, 'DATAASC');
  var column = name;
  var blobs = cells;
  var (w, cnt) = dims;
  final totalsize = dpTotalSize(seg);
  if (blobs.isEmpty) {
    final b = dpColumnCells(seg, 'DATABIN');
    column = b.$1;
    blobs = b.$3;
    (w, cnt) = b.$2;
  }
  if (blobs.isEmpty) return null;
  final joined = _concat(blobs);
  final url = _scalarText(seg, 'DESURL') ?? '';
  final expected = totalsize > 0 ? totalsize : (w > 0 && cnt > 0 ? w * cnt : joined.length);
  return DpContent(
      url: url,
      content: joined,
      expected: expected,
      column: column,
      complete: joined.length == expected);
}

/// The push's TOTALSIZE scalar (u32 LE) — the content length when the
/// server fills it — else 0.
int dpTotalSize(Uint8List seg) {
  final ts = _scalarValue(seg, 'TOTALSIZE');
  if (ts == null || ts.length < 4) return 0;
  return ts.buffer
      .asByteData(ts.offsetInBytes, ts.lengthInBytes)
      .getUint32(0, Endian.little);
}

/// [w] x [n] table dims, or (0, 0) when their product passes the decode
/// cap ([csMaxDecodedLength]) — hostile u32 dims a table of that size
/// cannot have arrived with.
(int, int) _boundedDims(int w, int n) =>
    w > 0 && n > 0 && n > csMaxDecodedLength ~/ w ? (0, 0) : (w, n);

Uint8List _concat(List<Uint8List> parts) {
  var n = 0;
  for (final p in parts) {
    n += p.length;
  }
  final out = Uint8List(n);
  var off = 0;
  for (final p in parts) {
    out.setRange(off, off + p.length, p);
    off += p.length;
  }
  return out;
}

Uint8List? _scalarValue(Uint8List seg, String name) {
  var i = 0;
  while (i < seg.length - 4) {
    if (seg[i] == 0x02 && seg[i + 1] == 0x01) {
      final ln = seg.buffer
          .asByteData(seg.offsetInBytes, seg.lengthInBytes)
          .getUint16(i + 2);
      // a wire length past the segment is not a name tag (a truncated or
      // hostile push): skip it, as html_viewer's dpScalars does
      if (i + 4 + ln > seg.length) {
        i += 1;
        continue;
      }
      final nm = String.fromCharCodes(seg, i + 4, i + 4 + ln);
      final j = i + 4 + ln + 2;
      if (nm == name && j + 4 <= seg.length && seg[j] == 0x02 && seg[j + 1] == 0x03) {
        final vl = seg.buffer
            .asByteData(seg.offsetInBytes, seg.lengthInBytes)
            .getUint16(j + 2);
        if (j + 4 + vl <= seg.length) {
          return Uint8List.sublistView(seg, j + 4, j + 4 + vl);
        }
      }
    }
    i += 1;
  }
  return null;
}

String? _scalarText(Uint8List seg, String name) {
  final v = _scalarValue(seg, name);
  if (v == null) return null;
  return String.fromCharCodes(v).trim();
}

/// ((width, count), [cell bytes]) of a DP column — inline `03 04` rows or
/// LZH `03 05` cells alike (_dp_column_cells port).
(String, (int, int), List<Uint8List>) dpColumnCells(Uint8List seg, String name) {
  final anchor = Uint8List.fromList([
    0x03, 0x01,
    (name.length >> 8) & 0xff, name.length & 0xff,
    ...name.codeUnits,
    0x03, 0x01,
  ]);
  var i = _indexOf(seg, anchor, 0);
  if (i < 0) return ('', (0, 0), const []);
  final ds = i + anchor.length;
  final bd = seg.buffer.asByteData(seg.offsetInBytes, seg.lengthInBytes);
  var dims = (0, 0);
  var j = ds;
  if (ds + 4 <= seg.length && seg[ds] == 0x03 && seg[ds + 1] == 0x02 && bd.getUint16(ds + 2) >= 8) {
    // the dims record cut short (a truncated push) carries no dims; wire
    // u32 dims whose table no decode could produce (hostile) are dropped
    // too — every consumer multiplies them out to slice / pad by
    if (ds + 12 <= seg.length) {
      dims = _boundedDims(bd.getUint32(ds + 4), bd.getUint32(ds + 8));
    }
    j = ds + 4 + bd.getUint16(ds + 2);
  }
  // The column ends at the next column (`03 01 00`) or the table's close
  // (`02 13`) — looked for only BETWEEN cells: an LZH cell's own header
  // may hold those bytes (a recorded session srv[138], the ST22 hit list's
  // DataTableOnDemand: its 531-byte LZH length is `02 13`, which cut the
  // column before its cell and left the grid without rows).
  final cells = <Uint8List>[];
  while (j < seg.length) {
    if (_startsWith(seg, j, const [0x03, 0x01, 0x00]) ||
        _startsWith(seg, j, const [0x02, 0x13])) {
      break;
    }
    if (seg[j] == 0x03 && j + 1 < seg.length && seg[j + 1] == 0x04) {
      // a row whose length runs past the segment ends the column (a
      // truncated or hostile push): never a RangeError out of the fold
      if (j + 4 > seg.length) break;
      final rl = bd.getUint16(j + 2);
      if (j + 4 + rl > seg.length) break;
      cells.add(Uint8List.sublistView(seg, j + 4, j + 4 + rl));
      j += 6 + rl;
    } else if (seg[j] == 0x03 && j + 1 < seg.length && seg[j + 1] == 0x05) {
      // walk this cell's segments
      final cell = find0305Cells(Uint8List.sublistView(seg, j));
      if (cell.isEmpty || cell.first.openOff != 0) break;
      final c = cell.first;
      final p = parse0305Cell(c.bytes);
      if (p != null) {
        final blob = lzhInflate(p.lzh);
        if (blob != null) cells.add(blob);
      }
      j += c.endOff; // the cell's offsets are relative to its start
    } else {
      j += 1;
    }
  }
  return (name, dims, cells);
}

int _indexOf(Uint8List b, Uint8List needle, int from) {
  for (var i = from; i + needle.length <= b.length; i++) {
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

bool _startsWith(Uint8List b, int at, List<int> needle) {
  if (at + needle.length > b.length) return false;
  for (var j = 0; j < needle.length; j++) {
    if (b[at + j] != needle[j]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// FORMAT (CAT80) descriptor + rows
// ---------------------------------------------------------------------------

class FmtColumn {
  FmtColumn(this.index, this.offset, this.length, this.type, this.name);
  final int index;
  final int offset;
  final int length;
  final int type;
  final String name;
}

const int cat80 = 80;
const String xUnknown = 'X-UNKNOWN';

/// The 80-byte-per-record row descriptor → columns (placeholder_columns
/// port). Accepts when at least one X-UNKNOWN placeholder is present.
List<FmtColumn>? placeholderColumns(Uint8List dec) {
  if (dec.isEmpty || dec.length % cat80 != 0) return null;
  final bd = dec.buffer.asByteData(dec.offsetInBytes, dec.lengthInBytes);
  final cols = <FmtColumn>[];
  var placeholders = 0;
  for (var i = 0; i < dec.length ~/ cat80; i++) {
    final off = i * cat80;
    final n0 = _txt(dec, off, off + 30);
    final n1 = _txt(dec, off + 30, off + 60);
    String? real;
    for (final n in [n0, n1]) {
      if (n.isNotEmpty && n != xUnknown && !_digitsOnlyRx.hasMatch(n)) {
        real = n;
        break;
      }
    }
    if (n0 == xUnknown || n1 == xUnknown) placeholders++;
    cols.add(FmtColumn(bd.getUint32(off + 60, Endian.little),
        bd.getUint32(off + 64, Endian.little), bd.getUint32(off + 68, Endian.little),
        bd.getUint32(off + 76, Endian.little), real ?? 'col_$i'));
  }
  if (placeholders == 0) return null;
  // offsets must be the running sum of the prior lengths; else pack sequentially
  var run = 0;
  var coherent = true;
  for (final c in cols) {
    if (c.offset != run) {
      coherent = false;
      break;
    }
    run += c.length;
  }
  if (!coherent) {
    var o = 0;
    cols.map((c) {
      final f = o;
      o += c.length;
      return (c, f);
    }).toList();
    // rebuild with sequential offsets
    var off2 = 0;
    final fixed = <FmtColumn>[];
    for (final c in cols) {
      fixed.add(FmtColumn(c.index, off2, c.length, c.type, c.name));
      off2 += c.length;
    }
    return fixed;
  }
  return cols;
}

String _txt(Uint8List r, int start, int end) =>
    String.fromCharCodes(r, start, end > r.length ? r.length : end).trim();

/// Decode one record field per its type code (_decode_rs_field port).
String decodeRsField(Uint8List raw, int ftype) {
  if (raw.isEmpty) return '';
  if (ftype == 10 || ftype == 11) {
    // WCHAR / WSTRING -> UTF-16LE (code units gathered, one String built:
    // `out +=` per unit was O(n²); audit zcode P-15)
    final units = <int>[];
    for (var i = 0; i + 1 < raw.length; i += 2) {
      final cu = raw[i] | (raw[i + 1] << 8);
      if (cu == 0) break;
      units.add(cu);
    }
    return String.fromCharCodes(units).trimRight();
  }
  const intTypes = {1, 2, 3, 4, 8, 9, 13, 14};
  if (intTypes.contains(ftype)) {
    var v = 0;
    for (final b in raw) {
      v = (v << 8) | b;
    }
    return v.toString();
  }
  if (ftype == 6 || ftype == 7) {
    final o = Uint8List(ftype == 6 ? 4 : 8);
    o.setRange(0, raw.length < o.length ? raw.length : o.length, raw);
    final f = ftype == 6
        ? ByteData.view(o.buffer).getFloat32(0)
        : ByteData.view(o.buffer).getFloat64(0);
    return f.toString();
  }
  if (ftype == 15) {
    return raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
  // CHAR / DATE / TIME / STRING / unknown -> text, up to the first NUL
  // (sliced, not built char by char and transcoded back: audit P-15)
  var end = 0;
  var ascii = true;
  while (end < raw.length && raw[end] != 0) {
    if (raw[end] >= 0x80) ascii = false;
    end++;
  }
  if (ascii) return String.fromCharCodes(raw, 0, end).trimRight();
  // UTF-8 re-read with latin1 fallback
  return String.fromCharCodes(
          _utf8DecodeLenient(Uint8List.sublistView(raw, 0, end)))
      .trimRight();
}

List<int> _utf8DecodeLenient(Uint8List bytes) {
  // decode UTF-8; invalid sequences pass through as their raw bytes
  final out = <int>[];
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b < 0x80) {
      out.add(b);
      i++;
    } else if (b < 0xe0 && i + 1 < bytes.length && bytes[i + 1] & 0xc0 == 0x80) {
      out.add(((b & 0x1f) << 6) | (bytes[i + 1] & 0x3f));
      i += 2;
    } else if (b < 0xf0 && i + 2 < bytes.length && bytes[i + 1] & 0xc0 == 0x80 && bytes[i + 2] & 0xc0 == 0x80) {
      out.add(((b & 0x0f) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f));
      i += 3;
    } else {
      out.add(b);
      i++;
    }
  }
  return out;
}

/// A snooped DP push decoded by its own FORMAT descriptor:
/// (columns, rows) with rows ' | '-joined (push_table_by_format port).
(List<FmtColumn>?, List<String>) pushTableByFormat(Uint8List seg) {
  final (_, (fw, fn), fcells) = dpColumnCells(seg, 'FORMAT');
  var fmt = _concat(fcells);
  if (fw > 0 && fn > 0 && fmt.length >= fw * fn) {
    fmt = Uint8List.sublistView(fmt, 0, fw * fn);
  } else if (fw > 0 && fn > 0 && fw * (fn - 1) < fmt.length && fmt.length < fw * fn) {
    final padded = Uint8List(fw * fn);
    padded.setRange(0, fmt.length, fmt);
    fmt = padded;
  }
  final cols = fmt.isNotEmpty ? placeholderColumns(fmt) : null;
  if (cols == null || cols.isEmpty) return (null, const []);
  final (_, (dw, dn), dcells) = dpColumnCells(seg, 'DATAASC');
  var cells = dcells;
  if (dw > 0 && dn > 0 && cells.length == dn && cells.every((c) => c.length <= dw)) {
    var total = 0;
    for (final c in cells) {
      total += c.length;
    }
    if (total < dw * dn) {
      cells = [
        for (final c in cells)
          Uint8List.fromList([...c, ...List.filled(dw - c.length, 0x20)])
      ];
    }
  }
  var data = _concat(cells);
  if (dw > 0 && dn > 0 && data.length >= dw * dn) {
    data = Uint8List.sublistView(data, 0, dw * dn);
  }
  var rl = 0;
  for (final c in cols) {
    final extent = c.offset + c.length;
    if (extent > rl) rl = extent;
  }
  if (dw > 0 && dw >= rl) rl = dw;
  if (data.isEmpty || rl <= 0 || data.length % rl != 0) {
    return (cols, const []);
  }
  final rows = <String>[];
  for (var k = 0; k < data.length ~/ rl; k++) {
    final rec = Uint8List.sublistView(data, k * rl, (k + 1) * rl);
    rows.add([
      for (final c in cols)
        decodeRsField(
            Uint8List.sublistView(rec, c.offset, c.offset + c.length > rec.length ? rec.length : c.offset + c.length),
            c.type)
    ].join(' | '));
  }
  return (cols, rows);
}

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call (audit #7 / zcode P-12).
final RegExp _digitsOnlyRx = RegExp(r'^\d+$');

/// Whether [rfc] already decodes as one complete DP push (a DESURL with
/// its content columns fits in the value) — the head rule of a chunked
/// push stream ([foldAutomationFrame]): a head chunk names no complete
/// push yet, a one-frame push does.
bool dpPushDecodes(Uint8List rfc) => _pushesOf(rfc).isNotEmpty;
