/// The real GUI's client REQUEST STREAM: how a client answer larger than
/// the kernel's request buffer ([kernelRequestBodyMax]) goes out (reference client
/// ; a recorded session, Java
/// GUI, the 170 988-B attachment-content reply to SAPLCNDP's
/// DP_GET_CLIENT_TABLE45A pull):
///
/// * gui[22..26]: `16/4/38` Step + RFC_TR `16/8/4` carrying
/// [requestChunkSize] = 29 928 B of the reply + EOM — body 9 + 5 +
/// 29 928 + 1 = 29 943 B, LZH-compressed like every client frame;
/// * srv[24..28]: the server's receipt of each chunk — its session items,
/// the ADVANCED Step and an EMPTY `16/8/5`, uncompressed (333 B); the
/// next chunk (and the tail) echoes that step;
/// * gui[27]: the original envelope, its `16/8/1` reply item cut to the
/// 21 348-B TAIL (5 x 29 928 + 21 348 = 170 988).
///
/// The chunks are plain byte slices of the one reply value (no per-chunk
/// header); the kernel joins them in order. The client sends the next
/// chunk only after the receipt of the previous one (each chunk's step is
/// the one its receipt advanced to). Protocol-keyed: any client frame whose
/// body is over the buffer and carries a `16/8/1` reply streams.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'diag_frame.dart';
import 'envelope.dart';

/// a recorded session gui[22..26]: the RFC_TR payload of one
/// `16/8/4` request chunk.
const int requestChunkSize = 29928;

/// `16/8/1`: the reply (and the stream's tail frame).
const int rfcSidReply = 1;

/// `16/8/4`: one request chunk (client -> server).
const int rfcSidRequestChunk = 4;

/// `16/8/5`: the server's receipt of one request chunk.
const int rfcSidChunkAck = 5;

/// The split of one oversized client frame body into the real GUI's
/// stream: [chunks] go out as `16/8/4` frames, each awaiting its receipt,
/// then [tailItems] (the original envelope with the reply cut to [tail]).
class RequestStreamPlan {
  RequestStreamPlan._(this._items, this._replyAt, this.chunks, this.tail,
      this.firstStep);

  final List<DiagItem> _items;
  final int _replyAt;

  /// The `16/8/4` slices of the reply value, in order (each
  /// [requestChunkSize] bytes).
  final List<Uint8List> chunks;

  /// The rest of the reply value: the sid-1 tail (never empty).
  final Uint8List tail;

  /// The step of the original frame's `16/4/38` (null: it carries none) —
  /// the first chunk's step.
  final int? firstStep;

  /// The item stream of chunk [k] at [step]: Step + `16/8/4` + EOM
  /// (a recorded session gui[22..26], one EOM).
  List<Uint8List> chunkItems(int k, int step) => [
        _stepItem(step),
        buildApplItem(applRfcTr, rfcSidRequestChunk, chunks[k]),
        eomBytes,
      ];

  /// The tail frame's items at [step]: the original items with the reply
  /// replaced by the `16/8/1` APPL [tail] and every Step restamped to
  /// [step] (gui[27]: the step the last receipt advanced to).
  List<Uint8List> tailItems(int step) => [
        for (var i = 0; i < _items.length; i++)
          if (i == _replyAt)
            buildApplItem(applRfcTr, rfcSidReply, tail)
          else if (_isStep(_items[i]))
            _stepItem(step)
          else
            _items[i].itemBytes,
      ];
}

Uint8List _stepItem(int step) {
  final v = Uint8List(4)..buffer.asByteData().setUint32(0, step);
  return buildApplItem(applStUser, 38, v);
}

bool _isStep(DiagItem it) =>
    it.type == itemAppl && it.id == applStUser && it.sid == 38 &&
    it.value.length >= 4;

int _stepValue(DiagItem it) =>
    it.value.buffer.asByteData(it.value.offsetInBytes, 4).getUint32(0);

/// The stream plan of a client frame [body] (decompressed, after the
/// 8-byte header) over [kernelRequestBodyMax], or null when it does not
/// stream: no `16/8/1` reply item (APPL or APPL4), a truncated item walk,
/// or an envelope so large that even an empty tail would not fit. The tail
/// is at most [requestChunkSize] and small enough that the tail frame fits
/// the buffer with the envelope's other items.
RequestStreamPlan? planRequestStream(Uint8List body) {
  if (body.length <= kernelRequestBodyMax) return null;
  final walk = walkItems(body);
  if (walk.trailing != null) return null;
  final items = walk.items;
  final at = items.indexWhere(
      (it) => it.isAppl && it.id == applRfcTr && it.sid == rfcSidReply);
  if (at < 0) return null;
  final reply = items[at];
  if (reply.value.length != reply.declaredLen) return null; // cut short
  // the tail frame: the other items + a 5-byte APPL header + the tail
  final others = body.length - reply.itemBytes.length;
  final budget = math.min(requestChunkSize, kernelRequestBodyMax - others - 5);
  if (budget <= 0) return null;
  final value = reply.value;
  final chunks = <Uint8List>[];
  var off = 0;
  while (value.length - off > budget) {
    // a tail of at least one byte stays for the sid-1 frame
    final end = off + math.min<int>(requestChunkSize, value.length - off - 1);
    chunks.add(Uint8List.fromList(Uint8List.sublistView(value, off, end)));
    off = end;
  }
  final stepAt = items.indexWhere(_isStep);
  return RequestStreamPlan._(
      items,
      at,
      chunks,
      Uint8List.fromList(Uint8List.sublistView(value, off)),
      stepAt < 0 ? null : _stepValue(items[stepAt]));
}

/// The step of the server's chunk receipt [frame] (a server frame carrying
/// the `16/8/5`), or null when [frame] is no receipt. A receipt without a
/// Step reads as -1.
int? chunkAckStep(Uint8List frame) {
  final dec = decompressFrame(frame);
  if (dec == null || dec.partial != null) return null;
  var isAck = false;
  var at = -1;
  for (final it in dec.walk.items) {
    if (it.isAppl && it.id == applRfcTr && it.sid == rfcSidChunkAck) {
      isAck = true;
    } else if (_isStep(it)) {
      at = _stepValue(it);
    }
  }
  return isAck ? at : null;
}
