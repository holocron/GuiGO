/// DIAG frame: the 8-byte header plus the item stream (or a compressed
/// CsObject carrying it). Mirrors pysap's SAPDiag header layout.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../lzh/lzh.dart';
import 'decode_stats.dart';
import 'envelope.dart' show ItemWalk, walkItems;

const int diagHeaderLen = 8;

// com_flag bits (header byte 1)
const int comFlagTermGra = 0x80;
const int comFlagTermNnm = 0x40;
const int comFlagTermCas = 0x20;
const int comFlagTermIni = 0x10;
const int comFlagTermEop = 0x08;
const int comFlagTermNop = 0x04;
const int comFlagTermEoc = 0x02;
const int comFlagTermEos = 0x01;

class DiagFrameHeader {
  DiagFrameHeader(
      {required this.mode,
      required this.comFlag,
      required this.modeStat,
      required this.errNo,
      required this.msgType,
      required this.msgInfo,
      required this.msgRc,
      required this.compress});

  factory DiagFrameHeader.parse(Uint8List frame) {
    final bd = frame.buffer.asByteData(frame.offsetInBytes, 8);
    return DiagFrameHeader(
      mode: bd.getUint8(0),
      comFlag: bd.getUint8(1),
      modeStat: bd.getUint8(2),
      errNo: bd.getUint8(3),
      msgType: bd.getUint8(4),
      msgInfo: bd.getUint8(5),
      msgRc: bd.getUint8(6),
      compress: bd.getUint8(7),
    );
  }

  final int mode;
  final int comFlag;
  final int modeStat;
  final int errNo;
  final int msgType;
  final int msgInfo;
  final int msgRc;
  final int compress;

  bool get isModeControl =>
      compress == 0 && comFlag & comFlagTermEop != 0 && length == diagHeaderLen;

  int get length => diagHeaderLen;
}

class DecompressedFrame {
  DecompressedFrame(this.header, this.body, this.partial);
  final DiagFrameHeader header;

  /// The frame's item stream: the decompressed payload after the 8-byte
  /// header (and after the err_no info string when present — that case keeps
  /// the raw stream; callers that need items on an error frame handle it).
  final Uint8List body;

  /// Non-null when LZH decoding fell back to a partial buffer.
  final String? partial;

  /// The item walk of [body], built on its first read and shared by every
  /// later reader of this decode — with [decompressFrame]'s memo, ONE walk
  /// per frame however many readers a turn runs (audit #8). The item list
  /// is unmodifiable: it is shared.
  late final ItemWalk walk = _walkOnce();

  ItemWalk _walkOnce() {
    DecodeStats.frameWalks++;
    final w = walkItems(body);
    return ItemWalk(List.unmodifiable(w.items), w.trailing);
  }
}

/// The decode of every frame [decompressFrame] has seen, keyed on the frame
/// OBJECT (weakly: it dies with the frame). A received frame is read by a
/// dozen readers per turn — the turn-end test, the window router, the
/// fold, the imode and step readers, the DP snoop, the automation fold, the
/// trace — and each paid a full LZH inflate of it (audit #8); with the memo
/// the first reader decodes and every other one shares the result.
final Expando<DecompressedFrame> _decoded = Expando('decoded DIAG frame');

/// Decompress one DIAG frame (diag_dealdrive.decompress_frame port):
/// compress flag = header byte 7; the CsObject starts at byte 8 (declared
/// length u32 LE at 8..11, algorithm nibble at 12, magic at 13..14). The
/// zlib fast path is accepted only when it completes byte-exactly to the
/// declared length; otherwise the reference decoder runs (LZH) or the LZC
/// decoder (client frames).
///
/// Memoized per frame object: a frame's bytes are never changed once it is
/// read (every patch builds a new frame), so a second call on the same
/// [frame] returns the SAME [DecompressedFrame] — its [DecompressedFrame.
/// body] and [DecompressedFrame.walk] are shared and must not be mutated.
DecompressedFrame? decompressFrame(Uint8List frame) {
  if (frame.length < diagHeaderLen) return null;
  return _decoded[frame] ??= _decompress(frame);
}

/// Whether [frame] already has its decode in the [decompressFrame] memo.
bool isFrameDecoded(Uint8List frame) => _decoded[frame] != null;

/// Seed the [decompressFrame] memo of [frame] with a decode made elsewhere
/// — the frame decode worker (decode_worker.dart) ran this file's own
/// [decompressFrame] and [DecompressedFrame.walk] over a copy of [frame]
/// in another isolate and shipped [body], [partial] and [walk] back. A
/// frame already decoded keeps its decode (the first decode wins; readers
/// may hold it): returns false then. The work is counted in [DecodeStats]
/// as the decode and the walk it is.
bool seedFrameDecode(
    Uint8List frame, Uint8List body, String? partial, ItemWalk walk) {
  if (frame.length < diagHeaderLen || _decoded[frame] != null) return false;
  DecodeStats.frameDecodes++;
  DecodeStats.frameWalks++;
  _decoded[frame] =
      _SeededFrame(DiagFrameHeader.parse(frame), body, partial, walk);
  return true;
}

/// A decode the worker made: its walk arrives built (and frozen).
class _SeededFrame extends DecompressedFrame {
  _SeededFrame(super.header, super.body, super.partial, this._seeded);

  final ItemWalk _seeded;

  @override
  ItemWalk get walk => _seeded;
}

DecompressedFrame _decompress(Uint8List frame) {
  DecodeStats.frameDecodes++;
  final h = DiagFrameHeader.parse(frame);
  if (h.compress == 0) {
    return DecompressedFrame(h, Uint8List.sublistView(frame, diagHeaderLen), null);
  }
  if (h.compress != 1) {
    // SNC/encrypted — not supported.
    return DecompressedFrame(
        h, Uint8List.sublistView(frame, diagHeaderLen), 'unsupported-compress-${h.compress}');
  }
  final magicAt = diagHeaderLen + 5;
  if (frame.length <= magicAt + 1 || frame[magicAt] != 0x1f || frame[magicAt + 1] != 0x9d) {
    // header says compressed but no CsObject where the structure puts it
    return DecompressedFrame(
        h, Uint8List.sublistView(frame, diagHeaderLen), 'no-csobject');
  }
  final bd = frame.buffer
      .asByteData(frame.offsetInBytes, frame.lengthInBytes);
  final declared = bd.getUint32(diagHeaderLen, Endian.little);
  final cs = Uint8List.sublistView(frame, diagHeaderLen);
  final alg = frame[diagHeaderLen + 4] & 0x0f;
  if (alg == 2) {
    // a frame body inflates to exactly its declared length: both decoders
    // are capped at declared + 1 (and the 64 MB ceiling), so a hostile
    // header cannot make a frame allocate past what it claims
    final out = lzhInflate(cs, declaredBound: true);
    if (out != null && out.length == declared) {
      return DecompressedFrame(h, out, null);
    }
    final (partial, err) = lzhReferenceDecodePartial(cs, declaredBound: true);
    if (partial.length == declared) {
      return DecompressedFrame(h, partial, null);
    }
    return DecompressedFrame(h, partial, err ?? 'TruncatedClean');
  }
  if (alg == 1) {
    final (out, err) = lzcDecompress(cs);
    if (err == null && out.length == declared) {
      return DecompressedFrame(h, out, null);
    }
    return DecompressedFrame(h, out, err ?? 'lzc-length-mismatch');
  }
  return DecompressedFrame(h, Uint8List(0), 'unknown-alg-$alg');
}

/// Rebuild [frame] with compress=0 and the decompressed payload — the shape
/// the item reference client consumes.
Uint8List? rebuildUncompressed(Uint8List frame) {
  final d = decompressFrame(frame);
  if (d == null || d.partial != null) return null;
  final out = Uint8List(diagHeaderLen + d.body.length);
  out.setRange(0, diagHeaderLen, Uint8List.sublistView(frame, 0, diagHeaderLen));
  out[7] = 0; // compress off
  out.setRange(diagHeaderLen, out.length, d.body);
  return out;
}

/// LZH-decompress the object at the first `1f 9d` in [stream] (dc port):
/// returns (output, partial-error). A false marker yields empty output.
(Uint8List, String?) dc(Uint8List stream) {
  final m = _findMagic(stream);
  if (m < 5) return (Uint8List(0), null);
  final cs = Uint8List.sublistView(stream, m - 5);
  final out = lzhInflate(cs);
  if (out != null) return (out, null);
  final hdr = parseCsHeader(cs);
  if (hdr == null) return (Uint8List(0), 'not-lzh');
  final (partial, err) = lzhReferenceDecodePartial(cs);
  return (partial, err ?? 'TruncatedClean');
}

int _findMagic(Uint8List stream) {
  for (var i = 0; i + 1 < stream.length; i++) {
    if (stream[i] == 0x1f && stream[i + 1] == 0x9d) return i;
  }
  return -1;
}

/// The largest uncompressed body of a COMPRESSED client frame the kernel
/// decompresses: its request buffer (`ThUncompressReq: CsDecompr (rc 2,
/// len 3430, read 3281, max output len 29992)`, the test system dev_w9 2026-10-11 —
/// GuiGo's 40 209-B /AIF/IFMON flush answer; the session died with
/// ERROR-CORE-INTERNAL_ERROR). The real GUI never exceeds it: its largest
/// frame body in the reference client corpus is 29 943 B (a recorded session
/// realgui, a file upload streamed as sid-4 chunks).
const int kernelRequestBodyMax = 29992;

/// The uncompressed body length of client [frame] — the declared CsObject
/// length of a compressed frame, the payload length of a plain one.
int clientBodyLength(Uint8List frame) {
  if (frame.length < diagHeaderLen) return 0;
  if (frame[7] == 1 && frame.length >= diagHeaderLen + 4) {
    return frame.buffer
        .asByteData(frame.offsetInBytes, frame.lengthInBytes)
        .getUint32(diagHeaderLen, Endian.little);
  }
  return frame.length - diagHeaderLen;
}

/// The server's message of an ERROR frame (header err_no != 0), else null:
/// the info string pysap's SAPDiag reads before the items (`info`,
/// terminated by 0x0c) — the kernel's error text converted to the logon
/// code page (the dev_w trace: "ThrtCodepageConvSysToFront … convert 176
/// bytes from 4103 to 4110", UTF-8; pysap's own default is UTF-16).
String? diagErrorInfo(Uint8List frame) {
  if (frame.length <= diagHeaderLen || frame[3] == 0) return null;
  final dec = decompressFrame(frame);
  if (dec == null) return null;
  final b = dec.body;
  var end = b.indexOf(0x0c);
  if (end < 0) end = b.length;
  final raw = Uint8List.sublistView(b, 0, end);
  if (raw.isEmpty) return '';
  // UTF-16LE when every other byte is NUL, else UTF-8 (lenient)
  var zeros = 0;
  for (var i = 1; i < raw.length; i += 2) {
    if (raw[i] == 0) zeros++;
  }
  String text;
  if (raw.length >= 2 && raw.length.isEven && zeros * 2 >= raw.length ~/ 2) {
    final bd = raw.buffer.asByteData(raw.offsetInBytes, raw.lengthInBytes);
    text = String.fromCharCodes([
      for (var i = 0; i + 1 < raw.length; i += 2) bd.getUint16(i, Endian.little),
    ]);
  } else {
    text = utf8.decode(raw, allowMalformed: true);
  }
  return text
      .replaceAll(_diagErrorInfoRx, ' ')
      .replaceAll(_whitespaceRunRx, ' ')
      .trim();
}

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call (audit #7 / zcode P-12).
final RegExp _diagErrorInfoRx = RegExp(r'[\x00-\x08\x0b-\x1f]');
final RegExp _whitespaceRunRx = RegExp(r'\s+');
