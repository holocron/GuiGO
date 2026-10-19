/// Frame decode off the calling isolate: a long-lived worker isolate runs
/// [decompressFrame] and the item walk of a received DIAG frame and ships
/// the body and the walk's item offsets back as transferable typed data;
/// the result seeds the frame's decode memo ([seedFrameDecode]), so every
/// reader of the frame — the router, the fold, the answer builders — gets
/// the memo hit it gets today, with nothing on the UI isolate but a few
/// microseconds of view building per frame (audit #1 / zcode P-01).
///
/// The worker runs THIS package's own [decompressFrame] and walk on a copy
/// of the frame bytes: the seeded decode is byte for byte the inline one
/// for every input (a frame the worker cannot decode — it throws, the
/// isolate is gone — is simply not seeded, and its first reader decodes
/// it inline exactly as before). The zlib FFI state is per isolate: the
/// worker lazily opens its own inflater on its first frame.
///
/// Gating ([FrameDecodeOffload.ahead]): only a compressed frame (header
/// byte 7 = 1 with its CsObject magic) whose declared body is at least
/// [FrameDecodeOffload.minBodyBytes] goes to the worker; anything smaller
/// decodes inline as before, so a small turn pays no round trip. The
/// kernel cuts a server frame at its 29 992-byte request buffer (every
/// recorded server frame is ≤ 30 000 B on the wire), so a multi-MB paint
/// is a train of such frames: the worker decodes each one while the
/// socket delivers the next, and the session awaits each frame's decode in
/// frame order before any reader sees it.
///
/// Mode ([FrameDecodeOffload.mode]): [FrameDecodeMode.auto] offloads live
/// (socket) traffic only — an offline replay stays inline, deterministic;
/// [FrameDecodeMode.isolate] offloads every eligible frame, live or not
/// (tests force the worker path with it); [FrameDecodeMode.inline] never
/// offloads.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../lzh/zlib_ffi.dart' show RawInflate;
import 'diag_frame.dart';
import 'envelope.dart' show DiagItem, ItemWalk;

enum FrameDecodeMode {
  /// Offload eligible live frames (the default); offline replays inline.
  auto,

  /// Never offload: every frame decodes on its first reader's isolate.
  inline,

  /// Offload every eligible frame, live or replayed (tests, benchmarks).
  isolate,
}

abstract final class FrameDecodeOffload {
  /// Which frames go to the worker (see the library doc).
  static FrameDecodeMode mode = FrameDecodeMode.auto;

  /// The smallest declared (uncompressed) body the worker decodes; a
  /// smaller compressed frame decodes inline (a ~5 KB body inflates in a
  /// few µs — less than the isolate round trip). 0 offloads every
  /// compressed frame.
  static int minBodyBytes = 8 * 1024;

  /// Frames decoded by the worker and seeded into the memo.
  static int seeded = 0;

  /// Frames sent to the worker that came back unseeded (the worker failed,
  /// was unavailable, or a reader decoded the frame inline first).
  static int fallbacks = 0;

  static _Worker? _worker;
  static bool _unavailable = false;
  static final Expando<Future<void>> _pending = Expando(
    'frame decode in flight',
  );

  /// Start [frame]'s decode in the worker when it is eligible (see the
  /// gating rule above; [live] = it came off a socket, not a replay), or
  /// join the decode already in flight for it. Returns the future that
  /// completes once the memo holds the frame's decode or the worker gave
  /// it up (it never completes with an error) — null when nothing is in
  /// flight: the frame decodes inline on its first read, as it always did.
  static Future<void>? ahead(Uint8List frame, {bool live = true}) {
    final inFlight = _pending[frame];
    if (inFlight != null) return inFlight;
    if (mode == FrameDecodeMode.inline) return null;
    if (mode == FrameDecodeMode.auto && !live) return null;
    if (_unavailable) return null;
    if (!_eligible(frame) || isFrameDecoded(frame)) return null;
    final w = _worker ??= _Worker.start();
    final done = w.decode(frame).then((r) {
      _pending[frame] = null;
      var ok = false;
      try {
        ok = r != null && r.seed(frame);
      } catch (_) {
        // a reply that cannot be seeded: the frame decodes inline
      }
      if (ok) {
        seeded++;
      } else {
        fallbacks++;
      }
    });
    _pending[frame] = done;
    return done;
  }

  /// Whether [frame] would go to the worker under the size gate.
  static bool _eligible(Uint8List frame) {
    if (frame.length < diagHeaderLen + 7) return false;
    if (frame[7] != 1) return false;
    final magicAt = diagHeaderLen + 5;
    if (frame[magicAt] != 0x1f || frame[magicAt + 1] != 0x9d) return false;
    final declared = frame.buffer
        .asByteData(frame.offsetInBytes, frame.lengthInBytes)
        .getUint32(diagHeaderLen, Endian.little);
    return declared >= minBodyBytes;
  }

  /// Whether a worker isolate is running.
  static bool get running => _worker != null;

  /// Stop the worker (tests; an app shutting down). Frames in flight come
  /// back unseeded — their readers decode them inline. The next eligible
  /// frame starts a new worker; [unavailable] = true keeps it from doing so.
  static Future<void> shutdown({bool unavailable = false}) async {
    final w = _worker;
    _worker = null;
    _unavailable = unavailable;
    await w?.stop();
  }

  /// Forget a refused spawn and the counters (tests).
  static void resetForTest() {
    _unavailable = false;
    seeded = 0;
    fallbacks = 0;
  }

  static void _markUnavailable(_Worker w) {
    if (identical(_worker, w)) {
      _worker = null;
      _unavailable = true;
    }
  }
}

/// The decode the worker shipped back: the body, the walk as 7 ints per
/// item (type, id, sid, declared length, item start, header length, item
/// end — offsets into the body), the trailing start (-1: none) and the
/// partial-decode note.
class _Result {
  _Result(this.body, this.items, this.trailingAt, this.partial);
  final Uint8List body;
  final Int32List items;
  final int trailingAt;
  final String? partial;

  bool seed(Uint8List frame) {
    final b = body;
    final n = items.length ~/ _intsPerItem;
    final out = List<DiagItem>.generate(n, (k) {
      final o = k * _intsPerItem;
      final start = items[o + 4], h = items[o + 5], end = items[o + 6];
      return DiagItem(
        items[o],
        items[o + 1],
        items[o + 2],
        items[o + 3],
        Uint8List.sublistView(b, start + h, end),
        Uint8List.sublistView(b, start, end),
      );
    }, growable: false);
    final walk = ItemWalk(
      List.unmodifiable(out),
      trailingAt < 0 ? null : Uint8List.sublistView(b, trailingAt),
    );
    return seedFrameDecode(frame, b, partial, walk);
  }
}

const int _intsPerItem = 7;

/// The main isolate's end of the worker: requests go out in order and
/// carry an id; each reply completes its request (null = not decoded).
class _Worker {
  _Worker._() {
    _port.handler = _onMessage;
    _port.keepIsolateAlive = false; // idle: the worker keeps nothing alive
  }

  factory _Worker.start() {
    final w = _Worker._();
    unawaited(w._spawn());
    return w;
  }

  final RawReceivePort _port = RawReceivePort();
  final Map<int, Completer<_Result?>> _waiting = {};
  final List<(int, Uint8List)> _queued = [];
  SendPort? _send;
  Isolate? _isolate;
  int _next = 0;
  bool _dead = false;

  Future<void> _spawn() async {
    try {
      _isolate = await Isolate.spawn(
        _workerMain,
        _port.sendPort,
        debugName: 'diag frame decode',
        errorsAreFatal: false,
        onExit: _port.sendPort,
      );
      // stopped while it was starting: it never gets a port to drain on
      if (_dead) _isolate?.kill(priority: Isolate.immediate);
    } catch (_) {
      // no isolates here (or the spawn was refused): every frame inline
      _die(unavailable: true);
    }
  }

  Future<_Result?> decode(Uint8List frame) {
    if (_dead) return Future.value(null);
    final id = _next++;
    final c = Completer<_Result?>();
    _waiting[id] = c;
    _port.keepIsolateAlive = true;
    final s = _send;
    if (s == null) {
      // the worker is still starting: the frame waits for its port (a
      // received frame is never changed once read)
      _queued.add((id, frame));
    } else {
      _post(s, id, frame);
    }
    return c.future;
  }

  void _post(SendPort s, int id, Uint8List frame) {
    try {
      s.send([id, frame]);
    } catch (_) {
      _settle(id, null);
    }
  }

  void _onMessage(Object? msg) {
    if (msg is SendPort) {
      _send = msg;
      for (final (id, f) in _queued) {
        _post(msg, id, f);
      }
      _queued.clear();
      return;
    }
    if (msg is List && msg.length == 5 && msg[0] is int) {
      final id = msg[0] as int;
      final body = msg[1];
      final items = msg[2];
      if (body is TransferableTypedData && items is TransferableTypedData) {
        _Result? r;
        try {
          r = _Result(
            body.materialize().asUint8List(),
            items.materialize().asInt32List(),
            msg[3] as int,
            msg[4] as String?,
          );
        } catch (_) {
          r = null;
        }
        _settle(id, r);
      } else {
        _settle(id, null);
      }
      return;
    }
    if (msg is List && msg.length == 1 && msg[0] is int) {
      _settle(msg[0] as int, null); // the worker could not decode it
      return;
    }
    // onExit (null) or anything unexpected: the worker is gone
    _die(unavailable: !_stopping);
  }

  void _settle(int id, _Result? r) {
    final c = _waiting.remove(id);
    if (c != null && !c.isCompleted) c.complete(r);
    if (_waiting.isEmpty) _port.keepIsolateAlive = false;
  }

  bool _stopping = false;

  void _die({required bool unavailable}) {
    if (_dead) return;
    _dead = true;
    for (final c in _waiting.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _waiting.clear();
    _queued.clear();
    _port.close();
    final iso = _isolate, s = _send;
    if (s == null) {
      iso?.kill(priority: Isolate.immediate);
    } else {
      // the worker frees its pooled native inflaters (native memory its
      // death does not return) and exits on its own once its port closes;
      // the kill is the backstop for one that never gets to the message
      // (a worker already gone drops it)
      try {
        s.send(_drainMessage);
      } catch (_) {}
      Timer(_drainGrace, () => iso?.kill(priority: Isolate.immediate));
    }
    if (unavailable) FrameDecodeOffload._markUnavailable(this);
  }

  Future<void> stop() async {
    _stopping = true;
    _die(unavailable: false);
  }
}

/// The message that ends the worker: drain its inflater pool, close its
/// port (the isolate then exits), after the frames sent before it.
const String _drainMessage = 'drain';

/// How long a stopped worker gets to drain before it is killed.
const Duration _drainGrace = Duration(seconds: 2);

/// The worker isolate: decode each frame with the package's own memoized
/// decoder (its memo dies with the worker's copy) and reply in order.
void _workerMain(SendPort reply) {
  final inbox = RawReceivePort();
  inbox.handler = (Object? msg) {
    if (msg == _drainMessage) {
      RawInflate.drainPool();
      inbox.close();
      return;
    }
    if (msg is! List || msg.length != 2) return;
    final id = msg[0] as int;
    final frame = msg[1] as Uint8List;
    try {
      final dec = decompressFrame(frame);
      if (dec == null) {
        reply.send([id]);
        return;
      }
      final body = dec.body;
      final walk = dec.walk;
      final ints = Int32List(walk.items.length * _intsPerItem);
      var o = 0;
      for (final it in walk.items) {
        final start = it.itemBytes.offsetInBytes - body.offsetInBytes;
        ints[o] = it.type;
        ints[o + 1] = it.id;
        ints[o + 2] = it.sid;
        ints[o + 3] = it.declaredLen;
        ints[o + 4] = start;
        ints[o + 5] = it.value.offsetInBytes - it.itemBytes.offsetInBytes;
        ints[o + 6] = start + it.itemBytes.length;
        o += _intsPerItem;
      }
      final t = walk.trailing;
      reply.send([
        id,
        TransferableTypedData.fromList([body]),
        TransferableTypedData.fromList([ints]),
        t == null ? -1 : t.offsetInBytes - body.offsetInBytes,
        dec.partial,
      ]);
    } catch (_) {
      reply.send([id]);
    }
  };
  reply.send(inbox.sendPort);
}
