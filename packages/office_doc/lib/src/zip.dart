/// A small ZIP reader / writer for OOXML packages (.docx / .xlsx).
///
/// Reading walks the central directory and inflates each entry with
/// `dart:io`'s raw-deflate decoder, chunk by chunk under a byte cap, so a
/// pushed document cannot balloon into gigabytes (a zip bomb stops at the
/// cap with a [ZipException]). Writing produces a plain deflated
/// (or stored) archive, no ZIP64, no encryption.
library;

import 'dart:convert';
import 'dart:io' show ZLibDecoder, ZLibEncoder;
import 'dart:typed_data';

class ZipException implements Exception {
  ZipException(this.message);
  final String message;
  @override
  String toString() => 'ZipException: $message';
}

/// Whether [bytes] start with a local file header (`PK\x03\x04`).
bool looksLikeZip(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x50 &&
    bytes[1] == 0x4b &&
    bytes[2] == 0x03 &&
    bytes[3] == 0x04;

class ZipEntry {
  ZipEntry._(
    this.name,
    this._archive,
    this._method,
    this._dataOffset,
    this.compressedSize,
    this.size,
    this.crc32,
  );

  final String name;
  final ZipReader _archive;
  final int _method;
  final int _dataOffset;
  final int compressedSize;

  /// The uncompressed size the directory declares.
  final int size;
  final int crc32;

  Uint8List? _content;

  /// The entry's bytes (inflated on first use, bounded by the reader's cap).
  Uint8List get content => _content ??= _archive._inflate(this);
}

class ZipReader {
  /// Reads the archive's directory. [maxEntryBytes] bounds one entry's
  /// inflated size, [maxTotalBytes] all entries inflated through this
  /// reader together.
  ZipReader(
    this.bytes, {
    this.maxEntryBytes = 64 << 20,
    this.maxTotalBytes = 256 << 20,
    this.maxEntries = 4096,
  }) {
    _readDirectory();
  }

  final Uint8List bytes;
  final int maxEntryBytes;
  final int maxTotalBytes;
  final int maxEntries;
  int _inflated = 0;

  final Map<String, ZipEntry> entries = {};

  ZipEntry? operator [](String name) => entries[name];

  /// The entry's bytes, or null when the archive has no such entry.
  Uint8List? read(String name) => entries[name]?.content;

  /// The entry as UTF-8 text (BOM dropped), or null.
  String? readText(String name) {
    final b = read(name);
    if (b == null) return null;
    final s = utf8.decode(b, allowMalformed: true);
    return s.startsWith('\u{feff}') ? s.substring(1) : s;
  }

  int _u16(int o) => bytes[o] | (bytes[o + 1] << 8);
  int _u32(int o) =>
      bytes[o] |
      (bytes[o + 1] << 8) |
      (bytes[o + 2] << 16) |
      (bytes[o + 3] << 24);

  void _readDirectory() {
    final n = bytes.length;
    if (n < 22) throw ZipException('too short for a zip archive');
    // the end-of-central-directory record: within the last 64 KiB + 22
    var eocd = -1;
    final stop = n - 22 - 0xffff < 0 ? 0 : n - 22 - 0xffff;
    for (var i = n - 22; i >= stop; i--) {
      if (bytes[i] == 0x50 &&
          bytes[i + 1] == 0x4b &&
          bytes[i + 2] == 0x05 &&
          bytes[i + 3] == 0x06) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw ZipException('no end of central directory');
    final count = _u16(eocd + 10);
    var off = _u32(eocd + 16);
    if (count > maxEntries) throw ZipException('too many entries ($count)');
    for (var k = 0; k < count; k++) {
      if (off + 46 > n || _u32(off) != 0x02014b50) {
        throw ZipException('bad central directory entry $k');
      }
      final method = _u16(off + 10);
      final crc = _u32(off + 16);
      final csize = _u32(off + 20);
      final usize = _u32(off + 24);
      final nameLen = _u16(off + 28);
      final extraLen = _u16(off + 30);
      final commentLen = _u16(off + 32);
      final local = _u32(off + 42);
      if (off + 46 + nameLen > n) throw ZipException('bad entry name');
      final name = utf8.decode(
        bytes.sublist(off + 46, off + 46 + nameLen),
        allowMalformed: true,
      );
      off += 46 + nameLen + extraLen + commentLen;
      if (local + 30 > n || _u32(local) != 0x04034b50) {
        throw ZipException('bad local header for $name');
      }
      final data = local + 30 + _u16(local + 26) + _u16(local + 28);
      if (data + csize > n) throw ZipException('truncated entry $name');
      if (name.endsWith('/')) continue; // a directory
      entries[name] = ZipEntry._(name, this, method, data, csize, usize, crc);
    }
  }

  Uint8List _inflate(ZipEntry e) {
    final raw = Uint8List.sublistView(
      bytes,
      e._dataOffset,
      e._dataOffset + e.compressedSize,
    );
    Uint8List out;
    if (e._method == 0) {
      out = Uint8List.fromList(raw);
    } else if (e._method == 8) {
      final cap = maxEntryBytes < maxTotalBytes - _inflated
          ? maxEntryBytes
          : maxTotalBytes - _inflated;
      final sink = _CappedSink(cap, e.name);
      final conv = ZLibDecoder(raw: true).startChunkedConversion(sink);
      const step = 64 << 10;
      for (var i = 0; i < raw.length; i += step) {
        conv.add(
          Uint8List.sublistView(
            raw,
            i,
            i + step > raw.length ? raw.length : i + step,
          ),
        );
      }
      conv.close();
      out = sink.takeBytes();
    } else {
      throw ZipException('unsupported compression ${e._method} for ${e.name}');
    }
    _inflated += out.length;
    if (_inflated > maxTotalBytes) throw ZipException('archive too large');
    return out;
  }
}

class _CappedSink implements Sink<List<int>> {
  _CappedSink(this.cap, this.name);
  final int cap;
  final String name;
  final BytesBuilder _b = BytesBuilder(copy: true);

  @override
  void add(List<int> data) {
    if (_b.length + data.length > cap) {
      throw ZipException('$name inflates past $cap bytes');
    }
    _b.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _b.takeBytes();
}

/// Builds a zip archive in memory.
class ZipWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);
  final BytesBuilder _dir = BytesBuilder(copy: false);
  int _count = 0;

  /// The DOS date/time stamped on every entry (default 1980-01-01 00:00,
  /// so equal input gives equal bytes).
  int dosTime = 0;
  int dosDate = (0 << 9) | (1 << 5) | 1;

  void addText(String name, String text, {bool deflate = true}) =>
      addBytes(name, Uint8List.fromList(utf8.encode(text)), deflate: deflate);

  void addBytes(String name, Uint8List data, {bool deflate = true}) {
    final nameBytes = utf8.encode(name);
    final crc = crc32(data);
    final body = deflate
        ? Uint8List.fromList(ZLibEncoder(raw: true, level: 6).convert(data))
        : data;
    final method = deflate ? 8 : 0;
    final offset = _out.length;
    final flags = 0x0800; // UTF-8 names
    _out.add(_le32(0x04034b50));
    _out.add(_le16(20));
    _out.add(_le16(flags));
    _out.add(_le16(method));
    _out.add(_le16(dosTime));
    _out.add(_le16(dosDate));
    _out.add(_le32(crc));
    _out.add(_le32(body.length));
    _out.add(_le32(data.length));
    _out.add(_le16(nameBytes.length));
    _out.add(_le16(0));
    _out.add(nameBytes);
    _out.add(body);

    _dir.add(_le32(0x02014b50));
    _dir.add(_le16(20)); // made by: MS-DOS / v2.0
    _dir.add(_le16(20));
    _dir.add(_le16(flags));
    _dir.add(_le16(method));
    _dir.add(_le16(dosTime));
    _dir.add(_le16(dosDate));
    _dir.add(_le32(crc));
    _dir.add(_le32(body.length));
    _dir.add(_le32(data.length));
    _dir.add(_le16(nameBytes.length));
    _dir.add(_le16(0)); // extra
    _dir.add(_le16(0)); // comment
    _dir.add(_le16(0)); // disk
    _dir.add(_le16(0)); // internal attributes
    _dir.add(_le32(0)); // external attributes
    _dir.add(_le32(offset));
    _dir.add(nameBytes);
    _count++;
  }

  Uint8List finish() {
    final dirOffset = _out.length;
    final dir = _dir.takeBytes();
    _out.add(dir);
    _out.add(_le32(0x06054b50));
    _out.add(_le16(0));
    _out.add(_le16(0));
    _out.add(_le16(_count));
    _out.add(_le16(_count));
    _out.add(_le32(dir.length));
    _out.add(_le32(dirOffset));
    _out.add(_le16(0));
    return _out.takeBytes();
  }

  static Uint8List _le16(int v) =>
      Uint8List.fromList([v & 0xff, (v >> 8) & 0xff]);
  static Uint8List _le32(int v) => Uint8List.fromList([
    v & 0xff,
    (v >> 8) & 0xff,
    (v >> 16) & 0xff,
    (v >> 24) & 0xff,
  ]);
}

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

/// The zip / PNG CRC-32 of [data].
int crc32(List<int> data) {
  var c = 0xffffffff;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return (c ^ 0xffffffff) & 0xffffffff;
}
