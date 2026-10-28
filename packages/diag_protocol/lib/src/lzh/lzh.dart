/// SAP-LZH (CsObject) codec.
///
/// Wire format: 8-byte header `<LE u32 uncompressed length><alg byte
/// (version<<4 | 2)> <1f 9d> <special>` followed by the body: a 2-bit
/// noise-count field, that many skipped bits, then an RFC-1951 raw DEFLATE
/// bitstream (LSB-first) — decoded against a 16K window pre-initialised to
/// zeros.
///
/// Three layers, mirroring the reference Python engine:
/// * fast path: zlib raw inflate over the bit-shifted body (zero preset
/// dictionary emulates SAP's pre-zeroed window; an empty-block prefix keeps
/// STORED blocks byte-aligned),
/// * reference decoder: pure-Dart LZH decode (window-fixed + STORED blocks)
/// used as the fallback, self-verify oracle and partial-recovery path,
/// * compressor: zlib raw DEFLATE (16K window, dynamic Huffman as the real
/// GUI emits it, fixed Huffman as the first fallback) shifted behind the
/// 5-bit noise prefix, plus an 8-zero footer the kernel reads past the
/// final block for look-ahead; no back-reference past [lzhMaxDistance]
/// (an 8K window re-encode otherwise); falls back to a literal
/// fixed-Huffman block when the self-verify fails (STORED-block
/// alignment hazard).
library;

import 'dart:typed_data';

import 'zlib_ffi.dart';

const int csHeaderLen = 8;
const int csAlgOff = 4;
const int csAlgLzh = 2;
const int lzhNoiseLenBits = 2;
const int _lzhNoiseMask = 3;

/// Mobile-sane ceiling on any decoded CsObject: output past it fails the
/// decode (zip-bomb guard), and a declared-bound decode whose declared
/// length exceeds it is refused before a byte is allocated. Real DIAG
/// payloads stay far below.
const int csMaxDecodedLength = 64 << 20;

/// The per-object output bound of a NOT declared-bound (cell/stream)
/// decode: [csMaxCellExpansion] x its header's declared length, never
/// under [csMinCellLimit] (and never over the decode's maxOutput).
const int csMaxCellExpansion = 16;
const int csMinCellLimit = 1 << 20;

/// The output limit of one decode. A DIAG frame's CsObject must inflate to
/// exactly its declared length ([declaredBound]: capped at `declared + 1`,
/// so an overrun shows as a length mismatch, never as a silently truncated
/// "complete" body). A cell/stream object is NOT declared-bound: the kernel
/// emits cell objects that legitimately inflate past their header length
/// (7.5% of the 73K corpus objects, up to 8.6x), and their readers keep the
/// whole output — those are capped at [maxOutput] only. Null: a
/// declared-bound decode whose declared length is over [maxOutput].
int? _outputLimit(int declared, bool declaredBound, int maxOutput) {
  if (!declaredBound) {
    // the per-object amplification bound: legitimate cell objects inflate
    // up to ~8.6x their header length, so 16x (never under 1 MB) keeps
    // every one while a crafted max-expansion stream (~1032x) with a small
    // header stops long before [maxOutput]
    final ratio = declared * csMaxCellExpansion;
    final bound = ratio > csMinCellLimit ? ratio : csMinCellLimit;
    return bound < maxOutput ? bound : maxOutput;
  }
  if (declared > maxOutput) return null;
  return declared + 1;
}

/// Initial output capacity: the declared length when the input can produce
/// it (one allocation for every valid stream), else the input's maximal
/// expansion — a hostile declared length cannot force a large allocation
/// out of a small input; the buffer still grows up to [limit] on demand.
int _initialCapacity(int limit, int expansionBound) {
  final c = expansionBound < (1 << 16) ? (1 << 16) : expansionBound;
  return c < limit ? c : limit;
}

/// DEFLATE's maximal expansion: a 258-byte match per 2 bits (1-bit length
/// and distance codes) — 1032 output bytes per input byte.
int _deflateBound(int inputLen) => inputLen * 1032 + 258;

/// The 32K all-zero preset dictionary: SAP's LZH decodes back-references that
/// reach before the output start against a zero-initialised window; a raw
/// deflate zdict IS the pre-start window.
final Uint8List zeroWindowDict = Uint8List(1 << 15);

class CsHeader {
  const CsHeader(this.declaredLen, this.noiseCount);
  final int declaredLen;
  final int noiseCount;
}

/// Parse the LZH CsObject header at `comp[0]`; null when not an LZH CsObject.
CsHeader? parseCsHeader(Uint8List comp) {
  if (comp.length <= csHeaderLen) return null;
  final b = comp.buffer.asByteData(comp.offsetInBytes, comp.lengthInBytes);
  if (comp[5] != 0x1f || comp[6] != 0x9d) return null;
  if (comp[csAlgOff] & 0x0f != csAlgLzh) return null;
  return CsHeader(
      b.getUint32(0, Endian.little), comp[csHeaderLen] & _lzhNoiseMask);
}

// ---------------------------------------------------------------------------
// LSB-first bit packing (deflate bit order, RFC 1951 §3.1.1)
// ---------------------------------------------------------------------------

/// A byte/bit packer. `put` takes ≤ 57 bits per call (Dart ints are 64-bit);
/// longer sequences are built from several puts. [takeBytes] flushes the
/// trailing partial byte; [drainBytes]/[carry] extract whole bytes while
/// keeping < 8 bits for chunked streams.
class BitWriter {
  int _acc = 0;
  int _n = 0;
  final BytesBuilder _out = BytesBuilder();

  void put(int value, int nbits) {
    if (nbits <= 0) return;
    _acc |= (value & ((1 << nbits) - 1)) << _n;
    _n += nbits;
    while (_n >= 8) {
      _out.addByte(_acc & 0xff);
      _acc >>= 8;
      _n -= 8;
    }
  }

  /// A Huffman code — packed MSB-first.
  void putHuff(int code, int nbits) {
    var rev = 0;
    for (var i = 0; i < nbits; i++) {
      rev = (rev << 1) | (code & 1);
      code >>= 1;
    }
    put(rev, nbits);
  }

  /// Whole bytes emitted so far; keeps the sub-byte carry.
  Uint8List drainBytes() => _out.takeBytes();

  int get carry => _acc;
  int get carryBits => _n;

  Uint8List takeBytes() {
    if (_n > 0) {
      _out.addByte(_acc & 0xff);
      _acc = 0;
      _n = 0;
    }
    return _out.takeBytes();
  }
}

// ---------------------------------------------------------------------------
// Empty-block prefix (keeps SAP's byte grid for STORED blocks under zlib)
// ---------------------------------------------------------------------------
// nF fixed (10 bits) + nD dynamic (99 bits) blocks with BFINAL=0 reach every
// residue P mod 8 with nF ≤ 7, nD ≤ 1; P ≡ shift (mod 8) restores SAP's byte
// grid after dropping the noise bits.

void _putEmptyFixed(BitWriter b) {
  b
    ..put(0, 1) // BFINAL
    ..put(1, 2) // BTYPE = 01
    ..putHuff(0, 7); // end-of-block (256): fixed code 0000000
}

const _clOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

void _putEmptyDynamic(BitWriter b) {
  b
    ..put(0, 1)
    ..put(2, 2)
    ..put(0, 5) // HLIT 0 -> 257 codes
    ..put(0, 5) // HDIST 0 -> 1 code
    ..put(14, 4); // HCLEN 14 -> 18 code-length codes
  const clCode = {0: 0, 1: 1, 17: 2, 18: 3};
  for (final sym in _clOrder.take(18)) {
    b.put(clCode.containsKey(sym) ? 2 : 0, 3);
  }
  b
    ..putHuff(clCode[18]!, 2)
    ..put(138 - 11, 7) // 138 zeros (lit 0..137)
    ..putHuff(clCode[18]!, 2)
    ..put(108 - 11, 7) // 108 zeros (lit 138..245)
    ..putHuff(clCode[17]!, 2)
    ..put(10 - 3, 3) // 10 zeros (lit 246..255)
    ..putHuff(clCode[1]!, 2) // lit/len 256: length 1
    ..putHuff(clCode[0]!, 2) // distance code 0: unused
    ..putHuff(0, 1); // end-of-block
}

class _Prefix {
  const _Prefix(this.totalBits, this.headBytes, this.tailValue, this.tailBits);
  final int totalBits;
  final Uint8List headBytes; // whole bytes of the prefix
  final int tailValue; // < 8 trailing bits
  final int tailBits;
}

final Map<int, _Prefix> _prefixForShift = _buildPrefixTable();

Map<int, _Prefix> _buildPrefixTable() {
  final table = <int, _Prefix>{};
  for (final nDyn in [0, 1]) {
    for (var nFix = 0; nFix < 8; nFix++) {
      final b = BitWriter();
      for (var i = 0; i < nDyn; i++) {
        _putEmptyDynamic(b);
      }
      for (var i = 0; i < nFix; i++) {
        _putEmptyFixed(b);
      }
      final r = b.carryBits; // total bits mod 8
      final totalBits = b._out.length * 8 + b.carryBits;
      final prev = table[r];
      if (prev == null || totalBits < prev.totalBits) {
        table[r] = _Prefix(
            totalBits, b.drainBytes(), b.carry, b.carryBits);
      }
    }
  }
  assert(table.length == 8, 'every residue 0..7 must be reachable');
  return table;
}

// ---------------------------------------------------------------------------
// Fast path: zlib raw inflate over the shifted body
// ---------------------------------------------------------------------------

/// Incremental zlib inflate of one CsObject LZH stream fed in chunks — the
/// first chunk starts with the 8-byte header. A stream split at an arbitrary
/// DIAG frame boundary inflates in one pass.
///
/// Output is capped at [maxOutput] and, with [declaredBound], at
/// `declared + 1` (see [_outputLimit]); crossing the cap fails the stream.
class LzhInflater {
  LzhInflater(Uint8List head,
      {bool declaredBound = false, int maxOutput = csMaxDecodedLength}) {
    final hdr = parseCsHeader(head);
    if (hdr == null) throw ArgumentError('not an LZH CsObject header');
    declared = hdr.declaredLen;
    _shift = lzhNoiseLenBits + hdr.noiseCount;
    final limit = _outputLimit(declared, declaredBound, maxOutput);
    if (limit == null) {
      failed = true;
      error = 'declared length $declared exceeds the $maxOutput-byte cap';
      _out = _ByteBuf(0, 0);
      return;
    }
    _out = _ByteBuf(
        _initialCapacity(
            declared + 1 < limit ? declared + 1 : limit, _deflateBound(head.length)),
        limit);
    // pooled: a reset context, not a fresh one + 32 KB dictionary copy per
    // object (every frame and every `03 05` cell; audit #9 / P-06)
    _inf = RawInflate.pooled(windowBits: -15, dictionary: zeroWindowDict);
    _feed(Uint8List.sublistView(head, csHeaderLen));
  }

  RawInflate? _inf;
  late final int _shift;
  bool _first = true;
  late final _ByteBuf _out;

  int declared = 0;
  bool failed = false;
  String? error;

  bool get eof => _inf?.finished ?? _eofAtDispose;
  bool _eofAtDispose = false;
  bool get cleanTruncation => !failed && !eof;

  /// The bytes decoded so far — a COPY: decoding goes on into the same
  /// buffer, whose bytes [result] hands out, so a view of it would let a
  /// caller's write show up in the final result.
  Uint8List partial() => Uint8List.fromList(_out.toBytes());

  void feed(Uint8List chunk) => _feed(chunk);

  void _feed(Uint8List chunk) {
    final inf = _inf;
    if (inf == null || failed || inf.finished || chunk.isEmpty) return;
    if (_first) {
      _first = false;
      // drop the 2..5 head bits (noise count + noise) and put P ≡ shift
      // (mod 8) bits of empty deflate blocks in front: the prefix tail is
      // exactly `shift` bits, so it replaces the dropped head bits in the
      // first body byte and every later byte keeps SAP's byte grid (STORED
      // alignment) — no per-byte bit repacking
      final p = _prefixForShift[_shift]!;
      assert(p.tailBits == _shift);
      final lead = Uint8List(1)
        ..[0] = (p.tailValue | (chunk[0] & (0xff << _shift))) & 0xff;
      _push([p.headBytes, lead, Uint8List.sublistView(chunk, 1)]);
    } else {
      _push([chunk]);
    }
  }

  void _push(List<Uint8List> parts) {
    final inf = _inf!;
    inf.pushParts(parts, _out.tryAdd);
    if (inf.failed) {
      failed = true;
      error = inf.error;
    }
  }

  /// The decoded bytes; null when the stream failed or did not reach its
  /// final block.
  Uint8List? result() {
    if (failed || !eof) return null;
    return _out.toBytes();
  }

  /// Hands the native inflater back to the pool: feeding stops, [eof] keeps
  /// its last answer.
  void dispose() {
    final inf = _inf;
    if (inf == null) return;
    _eofAtDispose = inf.finished;
    _inf = null;
    inf.release();
  }
}

/// One-shot: the decompressed bytes of the complete LZH CsObject at comp[0],
/// or null when the header is not LZH, zlib is unavailable or refuses the
/// stream, the output crosses its cap ([maxOutput]; `declared + 1` with
/// [declaredBound]), or the stream does not reach its final block.
Uint8List? lzhInflate(Uint8List comp,
    {bool declaredBound = false, int maxOutput = csMaxDecodedLength}) {
  if (!zlibAvailable) return null;
  LzhInflater? inf;
  try {
    inf = LzhInflater(comp, declaredBound: declaredBound, maxOutput: maxOutput);
    return inf.result();
  } on OutOfMemoryError {
    // not a refused stream: the callers' reference-decoder fallback would
    // only repeat the allocation — surface it instead
    rethrow;
  } catch (_) {
    return null;
  } finally {
    inf?.dispose();
  }
}

// ---------------------------------------------------------------------------
// Growable byte buffer for the reference decoder
// ---------------------------------------------------------------------------

/// Output buffer with a hard [limit]: an append that would cross it fills
/// up to the limit and then fails, so an overrun always shows as
/// `length == limit` (never a silently truncated "complete" output). Bytes
/// past [length] are never written, so they are zero.
class _ByteBuf {
  _ByteBuf(int initial, this.limit) : _buf = Uint8List(initial);

  final int limit;
  Uint8List _buf;
  int length = 0;

  /// Grow to hold [extra] more bytes; false when that crosses [limit].
  bool _room(int extra) {
    final need = length + extra;
    if (need > limit) return false;
    if (need > _buf.length) {
      var cap = _buf.length < 1024 ? 1024 : _buf.length;
      while (cap < need) {
        cap *= 2;
      }
      if (cap > limit) cap = limit;
      _buf = Uint8List(cap)..setRange(0, length, _buf);
    }
    return true;
  }

  static LzhDecodeException _overflow() =>
      LzhDecodeException('output exceeds declared length');

  void addByte(int v) {
    if (!_room(1)) throw _overflow();
    _buf[length++] = v;
  }

  void addBytes(Uint8List data, [int start = 0, int? end]) {
    if (!tryAdd(data, start, end)) throw _overflow();
  }

  /// [addBytes] that reports the overrun instead of throwing.
  bool tryAdd(Uint8List data, [int start = 0, int? end]) {
    final e = end ?? data.length;
    var n = e - start;
    final over = length + n > limit;
    if (over) n = limit - length;
    _room(n);
    _buf.setRange(length, length + n, data, start);
    length += n;
    return !over;
  }

  /// [n] zero bytes (the pre-zeroed window).
  void addZeros(int n) {
    final over = length + n > limit;
    if (over) n = limit - length;
    _room(n);
    length += n; // never-written bytes are zero
    if (over) throw _overflow();
  }

  /// LZ77 copy of [n] bytes starting [st] (≥ 0): a forward byte copy, so an
  /// overlapping match replicates its period.
  void copyBack(int st, int n) {
    final over = length + n > limit;
    if (over) n = limit - length;
    _room(n);
    final b = _buf;
    final d = length;
    if (d - st >= n) {
      b.setRange(d, d + n, b, st);
    } else {
      for (var i = 0; i < n; i++) {
        b[d + i] = b[st + i];
      }
    }
    length += n;
    if (over) throw _overflow();
  }

  int operator [](int i) => _buf[i];

  /// The bytes so far: a view of the private buffer (or the buffer
  /// itself), or an exact copy when growth left much slack (a view would
  /// pin it). Only for the FINAL bytes — a mid-stream reader copies
  /// ([LzhInflater.partial]): the buffer is shared with what follows.
  Uint8List toBytes() {
    if (length == _buf.length) return _buf;
    if (_buf.length - length > (length >> 3) + 4096) {
      return Uint8List.fromList(Uint8List.sublistView(_buf, 0, length));
    }
    return Uint8List.sublistView(_buf, 0, length);
  }
}

// ---------------------------------------------------------------------------
// Reference decoder: pure-Dart LZH (window-fixed + STORED blocks)
// ---------------------------------------------------------------------------

class LzhDecodeException implements Exception {
  LzhDecodeException(this.message);
  final String message;
  @override
  String toString() => 'LzhDecodeException: $message';
}

class _BitReader {
  _BitReader(this.data);
  final Uint8List data;
  int pos = 0;
  int bits = 0;
  int bitsCount = 0;

  int _readByte() {
    if (pos >= data.length) {
      throw LzhDecodeException('unexpected end of compressed data');
    }
    return data[pos++];
  }

  int peekBits(int nbits) {
    while (bitsCount < nbits) {
      bits |= _readByte() << bitsCount;
      bitsCount += 8;
    }
    return bits & ((1 << nbits) - 1);
  }

  int readBits(int nbits) {
    final v = peekBits(nbits);
    bits >>= nbits;
    bitsCount -= nbits;
    return v;
  }

  /// Byte-align: discard the remaining bits of the current partial byte.
  void align() {
    bits = 0;
    bitsCount = 0;
  }
}

class _HuffNode {
  _HuffNode(this.value);
  final int value;
  int code = -1;
  int codeLength = 0;
}

class _HuffTree {
  _HuffTree(this.nodes) {
    _buildLookup();
  }

  final List<_HuffNode> nodes;
  late final Uint8List _lengthLookup;
  late final List<Map<int, _HuffNode>> _nodeLookup;
  late final int maxBits;

  _HuffNode? node(int value) =>
      value >= 0 && value < nodes.length ? nodes[value] : null;

  void _buildLookup() {
    var mb = 0;
    for (final n in nodes) {
      if (n.codeLength > mb) mb = n.codeLength;
    }
    maxBits = mb;
    _lengthLookup = Uint8List(1 << mb);
    _nodeLookup = List.filled(mb + 1, const {});
    for (var cl = 1; cl <= mb; cl++) {
      _nodeLookup[cl] = {};
    }
    for (final n in nodes) {
      final cl = n.codeLength;
      if (cl <= 0) continue;
      _nodeLookup[cl][n.code] = n;
      final ext = 1 << (mb - cl);
      for (var i = 0; i < ext; i++) {
        _lengthLookup[n.code | (i << cl)] = cl;
      }
    }
  }

  _HuffNode _lookupCode(int code, [int? codeLength]) {
    var cl = code < _lengthLookup.length ? _lengthLookup[code] : 0;
    if (codeLength != null) {
      cl = cl < codeLength ? cl : codeLength;
    }
    if (cl == 0) throw const _NoNode();
    final n = _nodeLookup[cl][code & ((1 << cl) - 1)];
    if (n == null) throw const _NoNode();
    return n;
  }

  _HuffNode readCode(_BitReader r) {
    final raw = r.peekBits(maxBits);
    _HuffNode n;
    try {
      n = _lookupCode(raw);
    } on _NoNode {
      throw LzhDecodeException(
          'bad huffman tree: no node for code 0x${raw.toRadixString(16)}');
    }
    r.readBits(n.codeLength);
    return n;
  }

  _HuffNode readCodeTwoStaged(_BitReader r, int firstStageLen) {
    if (firstStageLen >= maxBits) return readCode(r);
    final first = r.peekBits(firstStageLen);
    _HuffNode? n;
    try {
      n = _lookupCode(first, firstStageLen);
    } on _NoNode {
      n = null;
    }
    if (n == null) return readCode(r); // readCode skips its own bits
    r.readBits(n.codeLength);
    return n;
  }

  static int _reverseInt(int value, int length) {
    var rev = 0;
    for (var i = 0; i < length; i++) {
      rev = (rev << 1) | (value & 1);
      value >>= 1;
    }
    return rev;
  }

  static _HuffTree fromDistribution(List<int> dist) {
    final nodes = <_HuffNode>[
      for (var i = 0; i < dist.length; i++) _HuffNode(i)..codeLength = dist[i]
    ];
    _generateNodeCodes(nodes);
    return _HuffTree(nodes);
  }

  static void _generateNodeCodes(List<_HuffNode> leafNodes) {
    final dist = <int>[];
    for (final n in leafNodes) {
      final cl = n.codeLength;
      if (cl <= 0) continue;
      while (dist.length <= cl) {
        dist.add(0);
      }
      dist[cl]++;
    }
    var available = 1;
    for (final count in dist) {
      available -= count;
      if (available < 0) {
        throw LzhDecodeException(
            'bad huffman tree: invalid code-length distribution');
      }
      available *= 2;
    }
    if (available > 0) {
      throw LzhDecodeException(
          'bad huffman tree: code-length distribution has unassigned codes');
    }
    final nextCodes = List<int>.filled(dist.length + 1, 0);
    var code = 0;
    for (var cl = 1; cl <= dist.length; cl++) {
      code = (code + (cl - 1 < dist.length ? dist[cl - 1] : 0)) << 1;
      nextCodes[cl] = code;
    }
    for (final n in leafNodes) {
      final cl = n.codeLength;
      if (cl <= 0) continue;
      n.code = _reverseInt(nextCodes[cl], cl);
      nextCodes[cl]++;
    }
  }
}

class _NoNode implements Exception {
  const _NoNode();
}

const int _lzhWindowSize = 0x4000;
const int _lzhMinMatch = 3;
const int _lzhMaxMatch = 258;
const int _lzhEndBlock = 256;
const int _lzhLitLast = 255;
const int _lzhLengthFirst = 257;

/// The longest back-reference distance SAP's LZH accepts: its 16K ring
/// window minus the encoder's look-ahead (MAX_MATCH + MIN_MATCH + 1 = 262),
/// = 16 122. pysapcompress (the RE of CsRComprLZH/CsRDecomprLZH) defines
/// `_LZH_MAX_DISTANCE = _LZH_WINDOW_SIZE - _LZH_MIN_LOOKAHEAD`; its encoder
/// never searches further back and its decoder raises "invalid match
/// distance" past it. A longer distance is resolved by the kernel against
/// the wrong ring bytes (the reference client's 32K-window cells decoded to garbage:
/// CONVT_NO_NUMBER in SAPLOLEA AC_FLUSH_CALL_INTERNAL, the test system). Every stream
/// [lzhCompress] emits stays at or under it.
const int lzhMaxDistance = _lzhWindowSize - (_lzhMaxMatch + _lzhMinMatch + 1);

const List<int> _lenExtra = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0, 99, 99
];
const List<int> _distExtra = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
];
const List<int> _bitlenExtra = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 7
];
const List<int> _bitlenRanking = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
];

class _LenDistMaps {
  _LenDistMaps() {
    lenLookup = Uint8List(259);
    lenStarts = List<int>.filled(29, 0);
    var length = _lzhMinMatch;
    for (var code = 0; code < 28; code++) {
      lenStarts[code] = length;
      final count = 1 << _lenExtra[code];
      for (var i = 0; i < count; i++) {
        lenLookup[length++] = code;
      }
    }
    lenLookup[_lzhMaxMatch] = 28; // length 258 gets its own code
    lenStarts[28] = _lzhMaxMatch;

    distLookup = Uint8List(_lzhWindowSize + 1);
    distStarts = List<int>.filled(30, 0);
    var dist = 1;
    for (var code = 0; code < 30; code++) {
      distStarts[code] = dist;
      final count = 1 << _distExtra[code];
      for (var i = 0; i < count; i++) {
        if (dist < distLookup.length) distLookup[dist] = code;
        dist++;
      }
    }
  }

  late final Uint8List lenLookup;
  late final List<int> lenStarts;
  late final Uint8List distLookup;
  late final List<int> distStarts;
}

final _LenDistMaps _maps = _LenDistMaps();

final List<_HuffNode> _staticLitlenNodes = [
  for (var c = 0; c < 144; c++) _HuffNode(c)..codeLength = 8,
  for (var c = 144; c < 256; c++) _HuffNode(c)..codeLength = 9,
  for (var c = 256; c < 280; c++) _HuffNode(c)..codeLength = 7,
  for (var c = 280; c < 288; c++) _HuffNode(c)..codeLength = 8,
];

final _HuffTree _staticLitlen = _buildStaticLitlen();

_HuffTree _buildStaticLitlen() {
  _HuffTree._generateNodeCodes(_staticLitlenNodes);
  return _HuffTree(_staticLitlenNodes);
}

// the static distance tree is deliberately INCOMPLETE (30 of 32 codes) —
// codes are assigned inline, never through the validating generator.
final _HuffTree _staticDist = _HuffTree([
  for (var c = 0; c < 30; c++)
    _HuffNode(c)
      ..codeLength = 5
      ..code = _HuffTree._reverseInt(c, 5),
]);

class LzhReferenceDecoder {
  LzhReferenceDecoder(this.data,
      {this.declaredBound = false,
      this.maxOutput = csMaxDecodedLength,
      this.maxDistance});

  final Uint8List data;

  /// Cap the output at `declared + 1` (a DIAG frame body), not only at
  /// [maxOutput] (see [_outputLimit]).
  final bool declaredBound;
  final int maxOutput;

  /// Reject (throw) a back-reference longer than this — [lzhMaxDistance]
  /// when checking what WE emit for the kernel ([lzhCompress]'s verify).
  /// Null (server streams): any distance resolves from the full history.
  final int? maxDistance;

  /// The longest back-reference distance decoded so far.
  int maxSeenDistance = 0;

  /// Output so far; an overrun of the cap fills to it, then fails.
  _ByteBuf out = _ByteBuf(0, 0);
  late final _BitReader _r;
  int decodedLength = 0;
  bool truncatedInput = false;

  /// Decode the whole CsObject. Throws [LzhDecodeException] on error; [out]
  /// then holds the partial output decoded so far.
  Uint8List decode() {
    _r = _BitReader(data);
    _readHead();
    final limit = _outputLimit(decodedLength, declaredBound, maxOutput);
    if (limit == null) {
      throw LzhDecodeException(
          'declared length $decodedLength exceeds the $maxOutput-byte cap');
    }
    out = _ByteBuf(
        _initialCapacity(decodedLength + 1 < limit ? decodedLength + 1 : limit,
            _deflateBound(data.length)),
        limit);
    while (true) {
      final lastBlock = _r.readBits(1);
      final blockType = _r.readBits(2);
      _decodeLog?.add('BLOCK t=$blockType last=$lastBlock pos=${_r.pos}');
      if (blockType == 0) {
        _readStoredBlock();
      } else if (blockType == 1) {
        _readBlockContent(_staticLitlen, _staticDist);
      } else if (blockType == 2) {
        _readDynamicBlock();
      } else {
        throw LzhDecodeException(
            'unknown block type 0x${blockType.toRadixString(16)}');
      }
      if (lastBlock == 1) break;
    }
    return out.toBytes();
  }

  void _readHead() {
    if (data.length < csHeaderLen) {
      throw LzhDecodeException('header truncated');
    }
    for (var i = 0; i < csHeaderLen; i++) {
      _r.readBits(8);
    }
    if (data[csAlgOff] & 0x0f != csAlgLzh) {
      throw LzhDecodeException('unknown algorithm: expected LZH');
    }
    final noise = _r.readBits(lzhNoiseLenBits);
    if (noise > 0) _r.readBits(noise);
    decodedLength = data.buffer
        .asByteData(data.offsetInBytes, data.lengthInBytes)
        .getUint32(0, Endian.little);
  }

  void _readStoredBlock() {
    _r.align();
    final length = _r._readByte() | (_r._readByte() << 8);
    final nlen = _r._readByte() | (_r._readByte() << 8);
    if ((length ^ 0xffff) != nlen) {
      throw LzhDecodeException('stored block LEN/NLEN mismatch $length/$nlen');
    }
    if (_r.pos + length > _r.data.length) {
      truncatedInput = true;
      throw LzhDecodeException('unexpected end of compressed data');
    }
    out.addBytes(_r.data, _r.pos, _r.pos + length);
    _r.pos += length;
  }

  void _readDynamicBlock() {
    final litlenCount = 257 + _r.readBits(5);
    final distCount = 1 + _r.readBits(5);
    final bitlenCount = 4 + _r.readBits(4);
    if (litlenCount > 286) {
      throw LzhDecodeException('invalid litlen code count $litlenCount');
    }
    if (distCount > 30) {
      throw LzhDecodeException('invalid dist code count $distCount');
    }
    final bitlenDist = List<int>.filled(19, 0);
    for (var i = 0; i < bitlenCount; i++) {
      bitlenDist[_bitlenRanking[i]] = _r.readBits(3);
    }
    final bitlenTree = _HuffTree.fromDistribution(bitlenDist);
    final litlenCl = _readEncodedLengths(bitlenTree, litlenCount);
    _decodeLog?.add('DYN litlen=$litlenCount dist=$distCount bl=$bitlenCount');
    final litlenTree = _HuffTree.fromDistribution(litlenCl);
    final distCl = _readEncodedLengths(bitlenTree, distCount);
    final distTree = _HuffTree.fromDistribution(distCl);
    _readBlockContent(litlenTree, distTree);
  }

  List<int> _readEncodedLengths(_HuffTree bitlenTree, int count) {
    final codes = <int>[];
    var lastlen = -1;
    while (codes.length < count) {
      final blCode = bitlenTree.readCode(_r).value;
      if (blCode < 16) {
        codes.add(blCode);
        lastlen = blCode;
      } else if (blCode == 16) {
        final rep = 3 + _r.readBits(_bitlenExtra[16]);
        if (rep > count - codes.length) {
          throw LzhDecodeException('repeat code overflows expected code count');
        }
        codes.addAll(List<int>.filled(rep, lastlen < 0 ? 0 : lastlen));
      } else if (blCode == 17) {
        final rep = 3 + _r.readBits(_bitlenExtra[17]);
        if (rep > count - codes.length) {
          throw LzhDecodeException('repeat code overflows expected code count');
        }
        codes.addAll(List<int>.filled(rep, 0));
        lastlen = 0;
      } else if (blCode == 18) {
        final rep = 11 + _r.readBits(_bitlenExtra[18]);
        if (rep > count - codes.length) {
          throw LzhDecodeException('repeat code overflows expected code count');
        }
        codes.addAll(List<int>.filled(rep, 0));
        lastlen = 0;
      } else {
        throw LzhDecodeException('unknown bitlen code $blCode');
      }
    }
    return codes;
  }

  void _readBlockContent(_HuffTree lit, _HuffTree dist) {
    final eob = lit.node(_lzhEndBlock)!;
    if (eob.codeLength == 0) {
      throw LzhDecodeException('litlen tree has no end-of-block code');
    }
    while (true) {
      final v = lit.readCodeTwoStaged(_r, eob.codeLength).value;
      if (v <= _lzhLitLast) {
        out.addByte(v);
        continue;
      }
      if (v == _lzhEndBlock) break;

      final lc = v - _lzhLengthFirst;
      if (lc >= 29) {
        // fixed-Huffman symbols 286/287 are reserved
        throw LzhDecodeException('invalid length code $v');
      }
      final length = _maps.lenStarts[lc] + _r.readBits(_lenExtra[lc]);
      if (length > _lzhMaxMatch) {
        throw LzhDecodeException('invalid match length $length');
      }
      final dc = dist.readCode(_r).value;
      final distance = _maps.distStarts[dc] + _r.readBits(_distExtra[dc]);
      if (distance > maxSeenDistance) {
        maxSeenDistance = distance;
        final cap = maxDistance;
        if (cap != null && distance > cap) {
          throw LzhDecodeException(
              'match distance $distance exceeds the SAP LZH maximum $cap '
              'at output ${out.length}');
        }
      }
      final st = out.length - distance;
      // SAP LZH decodes against a window pre-initialised to zeros: a back-
      // reference reaching before the output start legitimately copies zeros.
      _lzCopy(out, st, distance, length);
    }
  }
}

List<String>? _decodeLog;

/// Debug: the static litlen tree as "sym:code/len" strings.
List<String> debugStaticLitlen() => [
      for (final n in _staticLitlenNodes)
        '${n.value}:${n.code}/${n.codeLength}'
    ];

/// Debug hook: decode with command logging (length/distance per output pos).
List<String> debugLogCommands(Uint8List data) {
  _decodeLog = <String>[];
  final d = LzhReferenceDecoder(data);
  try {
    d.decode();
  } catch (_) {}
  final log = _decodeLog!;
  _decodeLog = null;
  return log;
}

void _lzCopy(_ByteBuf ob, int st, int distance, int length) {
  if (_decodeLog != null) {
    _decodeLog!.add('${ob.length}:L=$length/D=$distance');
  }
  if (st < 0) {
    final nz = -st < length ? -st : length;
    ob.addZeros(nz);
    length -= nz;
    if (length <= 0) return;
    st = 0; // len(ob) - distance == 0 now
  }
  ob.copyBack(st, length);
}

/// Reference decode with partial-on-error: returns (output, error?) where
/// output holds everything decoded before the failure.
/// [maxDistance] (e.g. [lzhMaxDistance]) fails a back-reference past it.
(Uint8List, String?) lzhReferenceDecodePartial(Uint8List comp,
    {bool declaredBound = false,
    int maxOutput = csMaxDecodedLength,
    int? maxDistance}) {
  final d = LzhReferenceDecoder(comp,
      declaredBound: declaredBound,
      maxOutput: maxOutput,
      maxDistance: maxDistance);
  try {
    return (d.decode(), null);
  } on LzhDecodeException catch (e) {
    return (d.out.toBytes(), e.message);
  }
}

/// The longest back-reference distance in the SAP-LZH stream [comp] (0: no
/// match), or null when it does not decode.
int? lzhMaxMatchDistance(Uint8List comp) {
  final d = LzhReferenceDecoder(comp);
  try {
    d.decode();
  } on LzhDecodeException {
    return null;
  }
  return d.maxSeenDistance;
}

// ---------------------------------------------------------------------------
// LZC decoder (unix-compress-style LZW; client frames use it)
// ---------------------------------------------------------------------------

/// Decompress an LZC CsObject (algorithm id 1). Ports pysapcompress's
/// `_LZCDecompress.decompress(compat_mode=True)`: chunk-based 9..limit-bit
/// codes, multi-block reset on code 256, end-of-input tolerated.
/// Returns (output, error?) — output holds the partial on error.
///
/// Codes are read straight from the input bytes at a bit cursor (a chunk is
/// up to 16 bytes, more than one 64-bit reservoir can hold). The output is
/// capped at the declared length; a declared length above [maxOutput] is
/// refused without allocating.
(Uint8List, String?) lzcDecompress(Uint8List data,
    {int maxOutput = csMaxDecodedLength}) {
  if (data.length < csHeaderLen) return (Uint8List(0), 'header truncated');
  final bd = data.buffer.asByteData(data.offsetInBytes, data.lengthInBytes);
  final declaredLen = bd.getUint32(0, Endian.little);
  final algId = data[4] & 0x0f;
  if (algId != 1) return (Uint8List(0), 'unknown algorithm: expected LZC');
  final blockMode = data[7] >> 7;
  final codeLengthLimit = data[7] & 0x1f;
  if (codeLengthLimit < 9 || codeLengthLimit > 16) {
    return (Uint8List(0), 'invalid header: code_length_limit out of range');
  }
  if (declaredLen > maxOutput) {
    return (
      Uint8List(0),
      'declared length $declaredLen exceeds the $maxOutput-byte cap'
    );
  }
  final codeLimit = 1 << codeLengthLimit;
  final firstSequenceCode = blockMode == 1 ? 257 : 256;

  var codeLength = 9;
  var maxCode = (1 << codeLength) - 1;
  var nextFreeCode = firstSequenceCode;

  void setCodeLength(int v) {
    codeLength = v;
    maxCode = v == codeLengthLimit ? codeLimit : (1 << v) - 1;
  }

  // m codes yield at most 1 + 2 + … + m bytes (a code extends its
  // predecessor by one byte)
  final m = (data.length - csHeaderLen) * 8 ~/ 9;
  final out = _ByteBuf(_initialCapacity(declaredLen, m * (m + 1) ~/ 2),
      declaredLen);
  // code table: base (-1 = undefined), appended byte, chain index
  final cBase = Int32List(codeLimit)..fillRange(0, codeLimit, -1);
  final cNext = Uint8List(codeLimit);
  final cChain = Int32List(codeLimit);
  final chainBuf = Uint8List(codeLimit);

  // the current chunk is data bits [bitPos, chunkEnd)
  var pos = csHeaderLen;
  var bitPos = pos * 8;
  var chunkEnd = bitPos;

  int? readCode() {
    if (chunkEnd - bitPos < codeLength || nextFreeCode > maxCode) {
      if (nextFreeCode > maxCode) setCodeLength(codeLength + 1);
      final left = data.length - pos;
      final readSize = codeLength < left ? codeLength : left;
      if (readSize == 0) return null;
      // a fresh chunk of exactly readSize bytes; the old chunk's unread
      // bits are padding
      bitPos = pos * 8;
      pos += readSize;
      chunkEnd = pos * 8;
    }
    if (chunkEnd - bitPos < codeLength) return null;
    // LSB-first: ≤ 16 bits starting at any bit offset span ≤ 3 bytes
    var i = bitPos >> 3;
    final sh = bitPos & 7;
    var v = data[i] >> sh;
    var got = 8 - sh;
    while (got < codeLength) {
      v |= data[++i] << got;
      got += 8;
    }
    bitPos += codeLength;
    return v & ((1 << codeLength) - 1);
  }

  void startNewBlock() {
    nextFreeCode = firstSequenceCode;
    setCodeLength(9);
    bitPos = chunkEnd; // the END_BLOCK chunk's tail is padding
  }

  int chainOf(int code) => code > 255 && cBase[code] >= 0 ? cChain[code] : 0;

  int? prevCode;
  var prevCi = 0; // chain index of prevCode's definition (0: a literal)
  try {
    while (out.length < declaredLen) {
      final code = readCode();
      if (code == null) break; // compat: end of input
      if (blockMode == 1 && code == 256) {
        startNewBlock();
        prevCode = null;
        prevCi = 0;
        continue;
      }
      if (code >= codeLimit) throw LzhDecodeException('unknown code $code');

      var chainLength = 0;
      if (code == prevCode) {
        chainLength = prevCi + 1;
      } else if (code < nextFreeCode) {
        var resolve = code;
        while (resolve > 255) {
          final base = cBase[resolve];
          if (resolve >= nextFreeCode || base < 0) {
            throw LzhDecodeException('unknown code $resolve');
          }
          chainBuf[cChain[resolve]] = cNext[resolve];
          chainLength++;
          resolve = base;
        }
        chainBuf[0] = resolve;
        chainLength++;
      } else if (code == nextFreeCode && prevCode != null) {
        chainBuf[prevCi + 1] = chainBuf[0];
        chainLength = prevCi + 2;
      } else {
        throw LzhDecodeException('unknown code $code');
      }

      out.addBytes(chainBuf, 0, chainLength);

      if (prevCode != null && nextFreeCode < codeLimit) {
        cBase[nextFreeCode] = prevCode;
        cNext[nextFreeCode] = chainBuf[0];
        cChain[nextFreeCode] = prevCi + 1;
        nextFreeCode++;
      }
      prevCode = code;
      prevCi = chainOf(code);
    }
  } on LzhDecodeException catch (e) {
    return (out.toBytes(), e.message);
  }
  return (out.toBytes(), null);
}

// ---------------------------------------------------------------------------
// Compressor (kernel-valid SAP-LZH via zlib raw DEFLATE)
// ---------------------------------------------------------------------------

Uint8List _sapsHeader(int rawLen) {
  final out = Uint8List(8);
  out.buffer.asByteData().setUint32(0, rawLen, Endian.little);
  out[4] = 0x12; // version 1 << 4 | alg 2
  out[5] = 0x1f;
  out[6] = 0x9d;
  out[7] = 0x02; // special: compression level 2
  return out;
}

/// The raw-deflate body shifted 5 bits behind the noise prefix
/// (count=3 + 3 skipped bits), as the kernel's compressor writes it, plus
/// [footer] zero bytes.
Uint8List _noiseShiftDeflate(Uint8List body, int rawlen, {int footer = 0}) {
  final n = body.length;
  // 5 + 8n bits -> n + 1 bytes
  final out = Uint8List(csHeaderLen + n + 1 + footer)
    ..setRange(0, csHeaderLen, _sapsHeader(rawlen));
  var carry = 0x1f; // the 5 noise bits
  for (var i = 0; i < n; i++) {
    final b = body[i];
    out[csHeaderLen + i] = (carry | (b << 5)) & 0xff;
    carry = b >> 3;
  }
  out[csHeaderLen + n] = carry;
  return out;
}

/// Fixed-Huffman literal codes, already bit-reversed for LSB-first packing:
/// 0..143 -> 8 bits (0x30 + v), 144..255 -> 9 bits (0x190 + v - 144).
final Uint16List _fixedLitRev = () {
  final t = Uint16List(256);
  for (var v = 0; v < 256; v++) {
    final (code, nbits) = v <= 143 ? (0x30 + v, 8) : (0x190 + (v - 144), 9);
    var rev = 0;
    var c = code;
    for (var i = 0; i < nbits; i++) {
      rev = (rev << 1) | (c & 1);
      c >>= 1;
    }
    t[v] = rev;
  }
  return t;
}();

/// A single RFC-1951 FIXED-Huffman block of pure literals + end-of-block —
/// bit-oriented throughout, so it survives the 5-bit noise shift for ANY
/// input (fallback when the self-verify rejects the zlib emission, and the
/// whole encoder when native zlib is unavailable).
Uint8List _fixedHuffmanLiteral(Uint8List data) {
  final w = BitWriter()
    ..put(1, 1) // BFINAL
    ..put(1, 2); // BTYPE = 01 (fixed)
  for (final v in data) {
    w.put(_fixedLitRev[v], v <= 143 ? 8 : 9);
  }
  w.putHuff(0, 7); // end-of-block
  return w.takeBytes();
}

/// Kernel-valid SAP-LZH of [data]: zlib raw deflate (16K window) behind the
/// noise prefix, with the literal fallback and the 8-zero footer the kernel
/// reads past the final block for look-ahead.
///
/// DYNAMIC Huffman first, as the real GUI's CsRComprLZH (gzip-1.2.4 trees.c
/// lineage) emits it: every `03 05` cell and every compressed frame body of
/// the real Windows GUI's /AIF/IFMON launch (a recorded session
/// gui[6]/gui[16]) is ONE BTYPE-2 block. Fixed Huffman (the reference client's
/// compress_deflate, `Z_FIXED`) codes a 258-byte match in 13+ bits, so the
/// long blank runs of a wide reply column cost 2-3x the real size: the
/// 4 264-verb step-38 answer's VARS cell (9 952 x 337 B) came out 28 500 B
/// against the real GUI's 11 500, the frame body 40 209 B — past the
/// kernel's 29 992-B request buffer, which refused it (`ThUncompressReq:
/// CsDecompr (rc 2, … max output len 29992)`, the test system dev_w9 2026-10-11) and
/// killed the session. A dynamic emission zlib could not keep free of
/// STORED blocks falls back to fixed Huffman, then to literals.
///
/// The self-verify round-trips the emission through the native zlib fast
/// path, which decodes on SAP's byte grid (the empty-block prefix), so it
/// rejects exactly the STORED-block misalignment the verify exists for; a
/// rejected emission is re-encoded (fixed Huffman, then literals). An
/// emission that is one Huffman block cannot hold one and ships unverified
/// ([_needsSelfVerify], audit 2026-10-23 P-3). Debug builds
/// (asserts on) also cross-check every accepted emission with the pure-Dart
/// reference decoder. Without native zlib the literal encoder is the whole
/// compressor, and its output is verified with the reference decoder — a
/// stream that does not round-trip is never returned.
///
/// No emitted back-reference is longer than [lzhMaxDistance] (16 122), the
/// kernel's limit. Stock zlib at windowBits -14 already stops there — its
/// `MAX_DIST(s) = w_size - MIN_LOOKAHEAD` is the same gzip-lineage
/// 16 384 - 262 as SAP's — but the linked libz is the platform's (Apple's,
/// Android's, zlib-ng), so the limit is checked, not assumed: an input
/// longer than [lzhMaxDistance] has its emission walked by the reference
/// decoder (a shorter one cannot hold such a distance: no preset dictionary,
/// so a match never reaches before the input start), and one that reaches
/// further is re-encoded with an 8K window (-13: 8 192 - 262), then the
/// fallbacks as above. The walk is per (level, window, strategy) ONCE per
/// isolate when the linked zlib is the encoder: [lzhDeflateKeepsSapDistance]
/// offers it matches at every distance past the limit, and a build that
/// takes none of them skips the per-payload walk (a pure-Dart bit-serial
/// decode of every >16 KB payload — every request-stream chunk, every
/// multi-MB VARS answer — on the UI isolate).
Uint8List lzhCompress(Uint8List data, {int level = 6}) {
  if (data.isEmpty) {
    // noise=0 + BFINAL=1 + BTYPE=00 -> byte 0x04, then empty stored block
    return Uint8List.fromList(
        [..._sapsHeader(0), 0x04, 0x00, 0x00, 0xff, 0xff]);
  }
  const footer = 8; // zero footer for kernel look-ahead
  if (zlibAvailable) {
    final deflate = lzhRawDeflateOverride ?? _nativeRawDeflate;
    for (final strategy in const [zDefaultStrategy, zFixed]) {
      for (final windowBits in const [-14, -13]) {
        final body =
            deflate(data, level: level, windowBits: windowBits, strategy: strategy);
        final stream = _noiseShiftDeflate(body, data.length, footer: footer);
        if (_needsSelfVerify(body)) {
          lzhSelfVerifies++;
          final fast = lzhInflate(stream, declaredBound: true);
          // misaligned STORED block: the next strategy, as with a 16K window
          if (fast == null || !_bytesEqual(fast, data)) break;
        }
        if (!_withinSapDistance(stream, data,
            level: level, windowBits: windowBits, strategy: strategy)) {
          continue;
        }
        return stream;
      }
    }
    return _noiseShiftDeflate(_fixedHuffmanLiteral(data), data.length,
        footer: footer);
  }
  final stream = _noiseShiftDeflate(_fixedHuffmanLiteral(data), data.length,
      footer: footer);
  if (!_referenceRoundTrips(stream, data)) {
    throw StateError('lzhCompress: the literal encoding does not round-trip');
  }
  return stream;
}

/// Whether the zlib emission [body] (raw deflate, before the noise shift)
/// must be round-tripped before it ships. The self-verify exists for ONE
/// failure: a STORED block, byte-aligned in [body], misaligned by the 5-bit
/// noise shift. A block's type sits in its header's bits 1..2, and the
/// header of the FIRST block is byte 0 of [body] — so an emission whose
/// first block is also its last (BFINAL, bit 0) and is Huffman-coded (BTYPE
/// 01 / 10) cannot hold a STORED block anywhere: it is shipped unverified,
/// trusting the deflater as every multi-block emission's verified bytes
/// trust it (audit 2026-10-23 P-3). An emission whose first block is not
/// final may hold a STORED block further on, which only a decode finds:
/// it is verified as before — the per-payload gate is not a per-encoder
/// verdict (an incompressible payload gets a STORED block from any level
/// and strategy), so a "verify once per (level, window, strategy)" would
/// ship a stream the kernel cannot inflate. [lzhVerifyEveryEmission]
/// forces the round-trip on every emission; debug builds (asserts on)
/// still cross-check every accepted emission with the reference decoder
/// ([_withinSapDistance]).
bool _needsSelfVerify(Uint8List body) =>
    lzhVerifyEveryEmission ||
    body.isEmpty ||
    (body[0] & 0x01) == 0 || // not the final block: more headers follow
    (body[0] & 0x06) == 0; // STORED (or reserved 11 == 6: never skipped)

/// Round-trip every zlib emission through the fast path before shipping
/// it, single-block ones included (the pre-P-3 behaviour) — a test knob.
bool lzhVerifyEveryEmission = false;

/// How many emissions [lzhCompress] round-tripped through the fast path
/// (a test counter: the single-block skip is observable).
int lzhSelfVerifies = 0;

bool _referenceRoundTrips(Uint8List stream, Uint8List data) {
  final (back, err) = lzhReferenceDecodePartial(stream,
      declaredBound: true, maxDistance: lzhMaxDistance);
  return err == null && _bytesEqual(back, data);
}

/// Whether the fast-path-verified [stream] of [data] keeps every
/// back-reference within [lzhMaxDistance]. Debug builds (asserts on) also
/// require the reference decoder to agree with the fast path.
bool _withinSapDistance(Uint8List stream, Uint8List data,
    {required int level, required int windowBits, required int strategy}) {
  // a distance is at most the match's output position (< data.length); a
  // probed-compliant native zlib never emits one past the limit
  if (data.length <= lzhMaxDistance ||
      (lzhRawDeflateOverride == null &&
          _nativeKeepsSapDistance(level, windowBits, strategy))) {
    assert(_referenceRoundTrips(stream, data),
        'lzhCompress: the zlib fast path accepted a stream the reference '
        'decoder rejects (${data.length} B)');
    return true;
  }
  final d = LzhReferenceDecoder(stream, declaredBound: true);
  final Uint8List back;
  try {
    back = d.decode();
  } on LzhDecodeException catch (e) {
    assert(false,
        'lzhCompress: the zlib fast path accepted a stream the reference '
        'decoder rejects (${data.length} B): ${e.message}');
    return false; // distances unchecked: never shipped
  }
  assert(_bytesEqual(back, data),
      'lzhCompress: the reference decoder disagrees with the fast path '
      '(${data.length} B)');
  return d.maxSeenDistance <= lzhMaxDistance;
}

/// The probe verdicts of the linked zlib, by [_probeKey] — one probe per
/// (level, window, strategy) per isolate.
final Map<int, bool> _nativeDistanceVerdicts = {};

int _probeKey(int level, int windowBits, int strategy) =>
    (level & 0xff) | ((windowBits & 0xff) << 8) | ((strategy & 0xff) << 16);

bool _nativeKeepsSapDistance(int level, int windowBits, int strategy) =>
    _nativeDistanceVerdicts[_probeKey(level, windowBits, strategy)] ??=
        lzhDeflateKeepsSapDistance(_nativeRawDeflate,
            level: level, windowBits: windowBits, strategy: strategy);

/// The probe input: [_probeSpan] distinct 29-byte runs, run `i` at
/// `61 i` and again at `61 i + lzhMaxDistance + 1 + i` — so its only long
/// match sits at a distance of exactly `lzhMaxDistance + 1 + i`, every
/// distance from 16 123 to 16 383 (the whole 16K window past the limit)
/// once. 64-symbol pseudo-random filler around them (8-bit codes in both
/// Huffman flavours, so zlib emits a coded block, never a STORED one the
/// noise shift would misalign) holds no other long match.
Uint8List _distanceProbeInput() {
  const run = 29, stride = 61;
  final n = lzhMaxDistance + 1 + stride * (_probeSpan - 1) + _probeSpan + run;
  final out = Uint8List(n);
  var x = 0x2545f491; // xorshift32: deterministic across platforms
  int next() {
    x ^= (x << 13) & 0xffffffff;
    x ^= x >> 17;
    x ^= (x << 5) & 0xffffffff;
    return x;
  }

  for (var i = 0; i < n; i++) {
    out[i] = 0x40 + (next() & 0x3f);
  }
  for (var i = 0; i < _probeSpan; i++) {
    final at = stride * i;
    out.setRange(at + lzhMaxDistance + 1 + i,
        at + lzhMaxDistance + 1 + i + run, out, at);
  }
  return out;
}

/// lzhMaxDistance + 1 .. 16 383: every distance a 16K window holds past it.
const int _probeSpan = _lzhWindowSize - 1 - lzhMaxDistance;

/// Whether [deflate] at ([level], [windowBits], [strategy]) keeps every
/// back-reference within [lzhMaxDistance] when the input offers long
/// matches ONLY past it, at each distance the 16K window could reach. False
/// (the per-payload walk stays on) when the probe stream is not a
/// reference-decodable round trip, so an undecided build is never trusted.
/// Exposed for the probe's own tests; [lzhCompress] caches the native verdict.
bool lzhDeflateKeepsSapDistance(
    Uint8List Function(Uint8List data,
            {required int level,
            required int windowBits,
            required int strategy})
        deflate,
    {int level = 6,
    int windowBits = -14,
    int strategy = zDefaultStrategy}) {
  final probe = _distanceProbeInput();
  final Uint8List stream;
  try {
    stream = _noiseShiftDeflate(
        deflate(probe,
            level: level, windowBits: windowBits, strategy: strategy),
        probe.length,
        footer: 8);
  } on Object {
    return false;
  }
  final d = LzhReferenceDecoder(stream, declaredBound: true);
  try {
    if (!_bytesEqual(d.decode(), probe)) return false;
  } on Object {
    return false;
  }
  return d.maxSeenDistance <= lzhMaxDistance;
}

/// The raw deflate [lzhCompress] runs; a test hook — e.g. a 32K-window
/// encoder standing in for a zlib build whose match finder reaches past
/// [lzhMaxDistance]. Null: native zlib ([rawDeflate]).
Uint8List Function(Uint8List data,
    {required int level,
    required int windowBits,
    required int strategy})? lzhRawDeflateOverride;

Uint8List _nativeRawDeflate(Uint8List data,
        {required int level, required int windowBits, required int strategy}) =>
    rawDeflate(data, level: level, windowBits: windowBits, strategy: strategy);

/// SAP-LZH of [data] as STORED deflate blocks — never compresses, always
/// valid; the carrying DIAG item must be APPL4 (4-byte length).
Uint8List lzhCompressStored(Uint8List data) {
  final out = BytesBuilder()..add(_sapsHeader(data.length));
  if (data.isEmpty) {
    out.addByte(0x01);
    out.add(Uint8List.fromList([0, 0, 0xff, 0xff]));
    return out.takeBytes();
  }
  var i = 0;
  final n = data.length;
  while (i < n) {
    final end = (i + 0xffff) < n ? i + 0xffff : n;
    final chunk = Uint8List.sublistView(data, i, end);
    i = end;
    out.addByte(i >= n ? 0x01 : 0x00);
    final len = Uint8List(4);
    len.buffer.asByteData().setUint16(0, chunk.length, Endian.little);
    len.buffer.asByteData().setUint16(2, chunk.length ^ 0xffff, Endian.little);
    out.add(len);
    out.add(chunk);
  }
  return out.takeBytes();
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
