/// Minimal ASN.1 DER reader/writer — just the Kerberos/GSS subset.
///
/// The reader is bounds-checked: every length is validated against the
/// enclosing buffer before a byte is touched, so a truncated or hostile
/// TLV raises [FormatException] instead of a [RangeError] or a read past
/// the end of the buffer.
library;

import 'dart:typed_data';

/// The DER length octets for [n] (short form below 128, long form up to
/// four length bytes otherwise).
List<int> derLength(int n) {
  if (n < 0) throw ArgumentError.value(n, 'n', 'negative DER length');
  if (n < 0x80) return [n];
  if (n <= 0xff) return [0x81, n];
  if (n <= 0xffff) return [0x82, n >> 8, n & 0xff];
  if (n <= 0xffffff) return [0x83, n >> 16, (n >> 8) & 0xff, n & 0xff];
  if (n <= 0xffffffff) {
    return [0x84, n >> 24, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
  }
  throw ArgumentError.value(n, 'n', 'DER length too large');
}

/// A complete TLV: [tag], its DER length and [content].
Uint8List derTlv(int tag, List<int> content) {
  final len = derLength(content.length);
  final out = Uint8List(1 + len.length + content.length);
  out[0] = tag;
  out.setRange(1, 1 + len.length, len);
  out.setRange(1 + len.length, out.length, content);
  return out;
}

class DerWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  void raw(int tag, List<int> content) {
    _b.addByte(tag);
    _b.add(derLength(content.length));
    _b.add(content);
  }

  /// Already-encoded TLV bytes, appended verbatim.
  void encoded(List<int> tlv) => _b.add(tlv);

  void integer(int v) => raw(0x02, derIntBytes(v));

  void integerBytes(Uint8List b) => raw(0x02, b);

  /// A BIT STRING carrying a 32-bit flag word (Kerberos KDCOptions /
  /// APOptions / TicketFlags): no unused bits, four content bytes.
  void bitString32(int v) => raw(0x03, [
        0,
        (v >> 24) & 0xff,
        (v >> 16) & 0xff,
        (v >> 8) & 0xff,
        v & 0xff,
      ]);

  void oid(String dotted) {
    final parts = dotted.split('.').map(int.parse).toList();
    final body = <int>[parts[0] * 40 + parts[1]];
    for (final p in parts.skip(2)) {
      if (p < 0x80) {
        body.add(p);
      } else {
        final stack = <int>[];
        var v = p;
        while (v > 0) {
          stack.insert(0, v & 0x7f);
          v >>= 7;
        }
        for (var i = 0; i < stack.length - 1; i++) {
          body.add(stack[i] | 0x80);
        }
        body.add(stack.last);
      }
    }
    raw(0x06, body);
  }

  void octetString(List<int> b) => raw(0x04, b);
  void utf8String(String s) => raw(0x0c, s.codeUnits);
  void generalString(String s) => raw(0x1b, s.codeUnits);

  /// GeneralizedTime (Kerberos `KerberosTime`, `YYYYMMDDHHMMSSZ`).
  void generalizedTime(String s) => raw(0x18, s.codeUnits);

  /// SEQUENCE built by a nested writer.
  void seq(void Function(DerWriter) f) {
    final w = DerWriter();
    f(w);
    raw(0x30, w.bytes());
  }

  /// Context-specific constructed `[tagNum]` holding [content].
  void ctx(int tagNum, List<int> content) => raw(0xa0 + tagNum, content);

  /// Context-specific constructed `[tagNum]` built by a nested writer.
  void ctxSeq(int tagNum, void Function(DerWriter) f) {
    final w = DerWriter();
    f(w);
    raw(0xa0 + tagNum, w.bytes());
  }

  /// APPLICATION constructed `[tagNum]` built by a nested writer.
  void app(int tagNum, void Function(DerWriter) f) {
    final w = DerWriter();
    f(w);
    raw(0x60 + tagNum, w.bytes());
  }

  Uint8List bytes() => _b.takeBytes();
}

/// Minimal two's-complement DER INTEGER content for [v].
List<int> derIntBytes(int v) {
  final out = <int>[];
  var x = v;
  while (true) {
    final byte = x & 0xff;
    out.insert(0, byte);
    x >>= 8; // arithmetic shift keeps the sign
    final signBit = byte & 0x80;
    if ((x == 0 && signBit == 0) || (x == -1 && signBit != 0)) break;
  }
  return out;
}

/// Decode DER INTEGER content as a signed value (Kerberos Int32 / UInt32
/// and Microseconds all fit; longer encodings are rejected).
int derIntValue(Uint8List c) {
  if (c.isEmpty) throw const FormatException('DER: empty INTEGER');
  if (c.length > 8) throw const FormatException('DER: INTEGER too long');
  var v = (c[0] & 0x80) != 0 ? -1 : 0;
  for (final b in c) {
    v = (v << 8) | b;
  }
  return v;
}

class DerReader {
  DerReader(this.b, [this.off = 0, int? end]) : end = end ?? b.length {
    if (off < 0 || this.end > b.length || off > this.end) {
      throw const FormatException('DER: reader window outside the buffer');
    }
  }

  final Uint8List b;
  int off;
  final int end;

  bool get atEnd => off >= end;

  /// The next TLV as (tag, content bytes); advances the reader. Throws
  /// [FormatException] on any truncation, indefinite length, an oversized
  /// length field or a high-tag-number tag.
  (int, Uint8List) next() {
    if (end - off < 2) throw const FormatException('DER underrun');
    final tag = b[off];
    if (tag & 0x1f == 0x1f) {
      throw const FormatException('DER: high-tag-number form unsupported');
    }
    var len = b[off + 1];
    var hdr = 2;
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      if (n == 0) {
        throw const FormatException('DER: indefinite length not allowed');
      }
      if (n > 4) throw const FormatException('DER: length field too long');
      if (end - off < 2 + n) {
        throw const FormatException('DER: truncated length field');
      }
      len = 0;
      for (var i = 0; i < n; i++) {
        len = (len << 8) | b[off + 2 + i];
      }
      hdr = 2 + n;
    }
    if (len > end - off - hdr) {
      throw const FormatException('DER: content runs past the buffer');
    }
    final content = Uint8List.sublistView(b, off + hdr, off + hdr + len);
    off += hdr + len;
    return (tag, content);
  }

  /// The next TLV, which must carry [tag].
  Uint8List expect(int tag) {
    final (t, c) = next();
    if (t != tag) {
      throw FormatException('DER: expected tag 0x${tag.toRadixString(16)}, '
          'got 0x${t.toRadixString(16)}');
    }
    return c;
  }

  /// All TLVs in this reader's window (the caller holds inner content).
  List<(int, Uint8List)> children() {
    final out = <(int, Uint8List)>[];
    while (!atEnd) {
      out.add(next());
    }
    return out;
  }

  /// Read the window's bytes as a signed big-endian INTEGER value (the
  /// caller holds the content of an INTEGER TLV).
  int nextInt() {
    final v = derIntValue(Uint8List.sublistView(b, off, end));
    off = end;
    return v;
  }

  /// The remaining bytes (not a TLV).
  Uint8List nextOctets() => Uint8List.sublistView(b, off, end);

  String nextString() => String.fromCharCodes(nextOctets());
}

/// The children of a context-tagged SEQUENCE body as a map tag-number →
/// content (`[n]` explicit tags, the Kerberos record shape). Duplicate
/// tags keep the first.
Map<int, Uint8List> derFields(Uint8List seqContent) {
  final out = <int, Uint8List>{};
  for (final (t, c) in DerReader(seqContent).children()) {
    if (t & 0xe0 == 0xa0) out.putIfAbsent(t & 0x1f, () => c);
  }
  return out;
}

Uint8List u8(List<int> l) => Uint8List.fromList(l);
