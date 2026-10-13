/// NI-layer framing: every message on the wire is `4-byte BE length + payload`.
library;

import 'dart:collection';
import 'dart:typed_data';

/// Largest NI payload the deframer accepts (64 MB): a larger announce is a
/// desynced or hostile stream, refused before anything is buffered for it.
const int niMaxFrameLength = 64 << 20;

/// A fatal NI framing error: the byte stream can no longer be split into
/// messages (zero-length or oversized announce). The connection is
/// unusable; the session must surface the error and close the socket.
class NiProtocolException implements Exception {
  NiProtocolException(this.message, {this.framesBefore = const []});
  final String message;

  /// Complete payloads deframed from the same feed before the fault, in
  /// order (delivered nowhere else).
  final List<Uint8List> framesBefore;

  @override
  String toString() => 'NiProtocolException: $message';
}

/// Incremental NI deframer over a byte stream.
///
/// Fed chunks are queued as-is with a read offset into the first; a payload
/// is copied out exactly once (into its own buffer) and only the unconsumed
/// tail of a chunk is ever retained (copied, so a caller may reuse its
/// buffers). A frame split over many TCP segments therefore costs O(n), not
/// a re-copy of the pending bytes per segment.
///
/// A zero-length announce or one above [maxFrameLength] throws
/// [NiProtocolException]; the deframer then stays failed and every later
/// [feed] rethrows — it never silently jams.
class NiDeframer {
  NiDeframer({this.maxFrameLength = niMaxFrameLength});

  final int maxFrameLength;
  final ListQueue<Uint8List> _chunks = ListQueue<Uint8List>();
  int _headOff = 0; // consumed bytes of _chunks.first
  int _buffered = 0; // unconsumed bytes over all chunks
  int _need = -1; // payload length of the frame in progress (header read)
  NiProtocolException? _fatal;

  /// Bytes received but not yet returned as payloads (excluding a consumed
  /// length header).
  int get buffered => _buffered;

  /// The fatal error, once the stream broke.
  NiProtocolException? get error => _fatal;

  /// Drop every buffered byte and the fatal state (the session's transport
  /// teardown: nothing of a dead connection is kept).
  void reset() {
    _chunks.clear();
    _headOff = 0;
    _buffered = 0;
    _need = -1;
    _fatal = null;
  }

  /// Feed raw socket bytes; returns complete NI payloads in order.
  List<Uint8List> feed(Uint8List data) {
    if (_fatal != null) throw _fatal!;
    final out = <Uint8List>[];
    if (data.isEmpty) return out;
    _chunks.add(data);
    _buffered += data.length;
    while (true) {
      if (_need < 0) {
        if (_buffered < 4) break;
        final len = _readU32();
        if (len == 0 || len > maxFrameLength) {
          _fatal = NiProtocolException(
              len == 0
                  ? 'zero-length NI announce'
                  : 'NI announce of $len bytes exceeds the '
                      '$maxFrameLength-byte limit',
              framesBefore: List.unmodifiable(out));
          _chunks.clear();
          _headOff = 0;
          _buffered = 0;
          throw _fatal!;
        }
        _need = len;
      }
      if (_buffered < _need) break;
      out.add(_take(_need));
      _need = -1;
    }
    // keep only a private copy of the caller's chunk tail
    if (_chunks.isNotEmpty && identical(_chunks.last, data)) {
      _chunks.removeLast();
      final from = _chunks.isEmpty ? _headOff : 0;
      _chunks.add(Uint8List.fromList(Uint8List.sublistView(data, from)));
      if (_chunks.length == 1) _headOff = 0;
    }
    return out;
  }

  int _readByte() {
    final c = _chunks.first;
    final v = c[_headOff++];
    _buffered--;
    if (_headOff == c.length) {
      _chunks.removeFirst();
      _headOff = 0;
    }
    return v;
  }

  int _readU32() =>
      (_readByte() << 24) | (_readByte() << 16) | (_readByte() << 8) | _readByte();

  Uint8List _take(int n) {
    final out = Uint8List(n);
    var at = 0;
    while (at < n) {
      final c = _chunks.first;
      final avail = c.length - _headOff;
      final k = avail < n - at ? avail : n - at;
      out.setRange(at, at + k, c, _headOff);
      at += k;
      _headOff += k;
      if (_headOff == c.length) {
        _chunks.removeFirst();
        _headOff = 0;
      }
    }
    _buffered -= n;
    return out;
  }
}

/// Frame [payload] as one NI message.
Uint8List niFrame(Uint8List payload) {
  final out = Uint8List(4 + payload.length);
  out.buffer.asByteData().setUint32(0, payload.length);
  out.setRange(4, out.length, payload);
  return out;
}

/// Split a whole recorded stream into NI payloads (diag_decode.ni port).
List<Uint8List> niSplit(Uint8List raw) {
  final out = <Uint8List>[];
  var i = 0;
  final bd = raw.buffer.asByteData(raw.offsetInBytes, raw.lengthInBytes);
  while (i + 4 <= raw.length) {
    final l = bd.getUint32(i);
    if (l == 0 || i + 4 + l > raw.length) break;
    out.add(Uint8List.sublistView(raw, i + 4, i + 4 + l));
    i += 4 + l;
  }
  return out;
}

/// NI-layer keepalive payloads.
const List<int> niPing = [0x4e, 0x49, 0x5f, 0x50, 0x49, 0x4e, 0x47, 0x00]; // "NI_PING\0"
const List<int> niPong = [0x4e, 0x49, 0x5f, 0x50, 0x4f, 0x4e, 0x47, 0x00]; // "NI_PONG\0"

/// The NI_PONG answer as its NI frame, built once (read-only): every
/// NI_PING is answered with these same 12 bytes.
final Uint8List niPongFrame =
    niFrame(Uint8List.fromList(niPong)).asUnmodifiableView();
