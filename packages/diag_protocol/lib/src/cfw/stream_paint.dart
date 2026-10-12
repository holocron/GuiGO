/// Stream-form PAINTS: a screen whose whole DIAG item stream rides an RFC
/// value instead of the frame's own item list (diag_controlstate carrier B).
///
/// An EnjoySAP screen built through the control framework (ME21N's
/// SAPLMEGUI/0014, VA01's tabstrip pages, the ABAP Debugger) arrives as a
/// `16/8/4` RFC_TR item addressed to the GUI-side GUICORE_BLOB_DIAG_PARSER
/// whose `STREAM` parameter carries the nested item stream; a stream longer
/// than one 30 000-B NI chunk continues RAW in the next frames' `16/8/4`
/// values and ends in a `16/8/6` tail. The real GUI receipts every sid-4
/// chunk frame with an empty `16/8/4` (the server paces the next chunk on
/// it: a recorded session srv[10] -> gui[9]; the live the test system
/// ME21N launch a recorded session srv[5]/[6] 29 701 B
/// each -> one receipt each, srv[7] the 774-B sid-6 tail -> none) and then
/// paints the nested stream as if it were the frame itself.
///
/// The value-token head after the anchor is `02 03 <u16 len>` (0xFFFF
/// escape: `<u32 len>` follows); the glued stream is that many bytes plus
/// an 8-byte trailer (live srv[5..7]: 29 104 + 29 701 + 774 = 59 571 + 8).
library;

import 'dart:typed_data';

import '../framing/diag_frame.dart';

/// The bracketed TLV parameter name that introduces the nested stream.
const List<int> streamAnchor = [
  0x02, 0x01, 0x00, 0x06, // tag, u16 len 6
  0x53, 0x54, 0x52, 0x45, 0x41, 0x4d, // "STREAM"
  0x02, 0x01,
];

/// The fixed RFC_TR header every self-contained RFC value opens with
/// (diag_rfc FIXED_HEADER) — a raw continuation slice never does.
const List<int> _rfcHead = [0x01, 0x01, 0x00, 0x08, 0x01, 0x01, 0x01, 0x01];

int _indexOf(Uint8List hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// (start, declared length) of the nested stream behind an RFC value's
/// GUICORE_BLOB `STREAM` parameter, or null when the value carries none.
(int, int)? streamToken(Uint8List value) {
  final p = _indexOf(value, streamAnchor);
  if (p < 0) return null;
  var s = p + streamAnchor.length;
  if (value.length < s + 4 || value[s] != 0x02 || value[s + 1] != 0x03) {
    return null;
  }
  final bd = value.buffer.asByteData(value.offsetInBytes, value.length);
  var n = bd.getUint16(s + 2);
  s += 4;
  if (n == 0xffff) {
    if (value.length < s + 4) return null;
    n = bd.getUint32(s);
    s += 4;
  }
  return (s, n);
}

/// True when [value] opens with the RFC_TR fixed header (a call of its
/// own — a progress tick, a flush — never a paint's raw continuation).
bool isRfcHead(Uint8List value) {
  if (value.length < _rfcHead.length) return false;
  for (var i = 0; i < _rfcHead.length; i++) {
    if (value[i] != _rfcHead[i]) return false;
  }
  return true;
}

/// What one `16/8/<sid>` value is to the stream-paint reduction.
enum PaintPart {
  /// not part of a stream paint
  none,

  /// the anchored head (receipted when sid 4)
  head,

  /// a raw continuation slice (receipted when sid 4)
  continuation,
}

/// The cross-frame state of ONE stream paint being received: how many
/// stream bytes are still owed after the parts seen so far.
class PaintStreamState {
  int _left = 0;

  /// True while a paint's head arrived and its stream is not complete.
  bool get pending => _left > 0;

  /// Classify and account the value of a `16/8/<sid>` item ([sid] 4 or 6).
  PaintPart feed(int sid, Uint8List value) {
    if (sid != 4 && sid != 6) return PaintPart.none;
    final tok = sid == 4 ? streamToken(value) : null;
    if (tok != null) {
      _left = tok.$2 - (value.length - tok.$1);
      return PaintPart.head;
    }
    if (_left > 0 && value.isNotEmpty && !isRfcHead(value)) {
      _left -= value.length;
      return PaintPart.continuation;
    }
    return PaintPart.none;
  }
}

/// Glues stream paints across frames and materializes each completed one
/// as a plain (uncompressed) DIAG frame whose items are the nested stream
/// — the carrier-A form every screen reader already folds
/// (diag_controlstate.materialize_stream_paints).
class StreamPaintAssembler {
  final PaintStreamState _state = PaintStreamState();
  final BytesBuilder _buf = BytesBuilder(copy: true);
  int _need = 0;
  Uint8List? _header;

  /// True while a paint is partially received.
  bool get pending => _state.pending;

  /// [frames] with every stream paint they complete inserted, as its own
  /// frame, right after the frame that completed it.
  List<Uint8List> materialize(List<Uint8List> frames) {
    List<Uint8List>? out;
    for (var i = 0; i < frames.length; i++) {
      final painted = _feedFrame(frames[i]);
      if (painted.isEmpty && out == null) continue;
      out ??= frames.sublist(0, i);
      out
        ..add(frames[i])
        ..addAll(painted);
    }
    return out ?? frames;
  }

  List<Uint8List> _feedFrame(Uint8List frame) {
    final dec = decompressFrame(frame);
    if (dec == null) return const [];
    final done = <Uint8List>[];
    for (final it in dec.walk.items) {
      if (!it.isAppl || it.id != 8) continue;
      final v = Uint8List.fromList(it.value);
      switch (_state.feed(it.sid, v)) {
        case PaintPart.head:
          final tok = streamToken(v)!;
          _buf.clear();
          _need = tok.$2;
          _header = Uint8List.fromList(frame.sublist(0, diagHeaderLen));
          _buf.add(Uint8List.sublistView(v, tok.$1));
        case PaintPart.continuation:
          _buf.add(v);
        case PaintPart.none:
          continue;
      }
      if (_buf.length >= _need) {
        final stream = _buf.takeBytes();
        done.add(
          _carrierFrame(_header!, Uint8List.sublistView(stream, 0, _need)),
        );
        _need = 0;
      }
    }
    return done;
  }

  static Uint8List _carrierFrame(Uint8List header, Uint8List stream) {
    final out = Uint8List(diagHeaderLen + stream.length)
      ..setRange(0, diagHeaderLen, header)
      ..setRange(diagHeaderLen, diagHeaderLen + stream.length, stream);
    out[5] = 0; // msg_info: not compressed
    out[7] = 0; // compress = 0: the stream is the plain item list
    _carriers[out] = true;
    return out;
  }
}

final Expando<bool> _carriers = Expando('stream-paint carrier');

/// Whether [frame] is a materialized stream paint ([StreamPaintAssembler]),
/// not a frame off the wire. Its nested items are the PAINT's — the step
/// (4/38) and the imode list inside it are the ones the paint was built
/// with, not the turn's: the live the test system ME21N paint (a recorded session
/// reference_live srv[5..7], wire step 28) nests 4/38 = 25, and reading it as
/// the session step sent every later action at the stale step 25 — the
/// server answered none of them (the real GUI echoes the carrying frames'
/// step, a recorded session srv[10..11] step 38 -> gui[9]
/// / gui[10] at 38). Step, clock and imode readers skip it.
bool isStreamCarrier(Uint8List frame) => _carriers[frame] ?? false;
