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
///
/// DYNT atoms (audit 2026-10-23 P-1): the worker also parses the atom list
/// of every 18/9/2 and 18/9/16 item of the frame ([parseDyntAtoms]) and
/// ships the parse as flat ints plus a string table; [_Result.seed]
/// rebuilds the [DyntAtom]s as views into the seeded body and memoizes
/// them per [DiagItem], so the fold ([dyntAtomsOf]) finds them parsed and
/// runs no atom parse on the UI isolate for a worker-decoded frame. An
/// inline-decoded frame (small, replayed, worker gone) parses its atoms
/// inline as before.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../items/dynt_atom.dart';
import '../lzh/zlib_ffi.dart' show RawInflate;
import 'diag_frame.dart';
import 'envelope.dart' show DiagItem, ItemWalk, applDynt;

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

  /// DYNT atom items (18/9/2, 18/9/16) whose parsed atoms the worker
  /// shipped and [dyntAtomsOf] handed out without parsing (audit
  /// 2026-10-23 P-1).
  static int atomItemsSeeded = 0;

  /// DYNT atom items [dyntAtomsOf] parsed inline on the caller's isolate
  /// (an inline-decoded frame, or an item the worker could not parse).
  static int atomItemsInline = 0;

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
    atomItemsSeeded = 0;
    atomItemsInline = 0;
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
/// end — offsets into the body), the trailing start (-1: none), the
/// partial-decode note, and the DYNT atom parse of the frame's 18/9/2 and
/// 18/9/16 items ([_AtomsWire]; null when the frame has none).
class _Result {
  _Result(this.body, this.items, this.trailingAt, this.partial, this.atoms);
  final Uint8List body;
  final Int32List items;
  final int trailingAt;
  final String? partial;
  final _AtomsWire? atoms;

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
    if (!seedFrameDecode(frame, b, partial, walk)) return false;
    final a = atoms;
    if (a != null) {
      try {
        a.seed(out, b);
      } catch (_) {
        // an atom record that cannot be rebuilt: those items parse inline
      }
    }
    return true;
  }
}

/// The parsed DYNT atoms of a frame on the wire between the isolates
/// (audit 2026-10-23 P-1): one record of [_intsPerAtomItem] ints per atom
/// item (its index in the walk, its first atom's record, its atom count,
/// its unparsed trailing span — body offsets, -1 none), [_intsPerAtom] ints
/// per atom (every scalar field of [DyntAtom], its own-bytes and value
/// spans as body offsets, and each text as an index into [strings], -1
/// null), and the string table. Rebuilding an atom from its record is a
/// field copy and two views: no byte scan, no UTF-8 decode.
class _AtomsWire {
  _AtomsWire(this.itemRecs, this.atomInts, this.strings);
  final Int32List itemRecs;
  final Int32List atomInts;
  final List<String> strings;

  /// Encode the atom parse of every 18/9/2 / 18/9/16 item of [items]
  /// (views into [body]); null when there is none. An item whose parse
  /// throws is left out: its reader parses it inline, and throws there.
  static _AtomsWire? encode(List<DiagItem> items, Uint8List body) {
    final recs = <int>[];
    final ints = <int>[];
    final strings = <String>[];
    final index = <String, int>{};
    int str(String? s) {
      if (s == null) return -1;
      return index[s] ??= (strings..add(s)).length - 1;
    }

    final base = body.offsetInBytes;
    int at(Uint8List v) => v.offsetInBytes - base;
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      if (!_isAtomItem(it)) continue;
      final DyntAtomWalk w;
      try {
        w = parseDyntAtoms(it.value);
      } catch (_) {
        continue;
      }
      final t = w.trailing;
      recs.addAll([
        i,
        ints.length ~/ _intsPerAtom,
        w.atoms.length,
        t == null ? -1 : at(t),
        t == null ? -1 : at(t) + t.length,
      ]);
      for (final a in w.atoms) {
        final v = a.value;
        ints.addAll([
          a.atomLength, a.dlgFlag1, a.dlgFlag2, a.etype, a.area, a.block,
          a.group, a.row, a.col, a.attr,
          a.pushbuttonVLength, a.pushbuttonVHeight,
          a.pushbuttonFunctionCodeOffset, a.pushbuttonTextOffset,
          a.tabstripVLength, a.tabstripVHeight, a.tabstripPageId,
          a.tabstripFunctionCodeOffset, a.tabstripTextOffset,
          a.tabstripIdOffset,
          a.fieldFlag1, a.fieldDlen, a.fieldMlen, a.fieldMaxnrchars,
          a.frameDrows, a.frameDcols,
          a.radiobuttonButton, a.radiobuttonVisibleLabelLength,
          a.radiobuttonEventIdOff, a.radiobuttonEventIdLen,
          a.radiobuttonTextOff, a.radiobuttonTextLength,
          at(a.ownBytes), at(a.ownBytes) + a.ownBytes.length,
          v == null ? -1 : at(v), v == null ? -1 : at(v) + v.length,
          str(a.nameText), str(a.pushbuttonText),
          str(a.pushbuttonFunctionCode), str(a.tabstripText),
          str(a.tabstripFunctionCode), str(a.tabstripId), str(a.xmlpropText),
          str(a.fieldText), str(a.frameText), str(a.radiobuttonText),
        ]);
      }
    }
    if (recs.isEmpty) return null;
    return _AtomsWire(
      Int32List.fromList(recs),
      Int32List.fromList(ints),
      strings,
    );
  }

  /// Rebuild each recorded item's atoms as views into [body] and memoize
  /// them on the item ([_seededAtoms]).
  void seed(List<DiagItem> items, Uint8List body) {
    final recs = itemRecs, ints = atomInts, strs = strings;
    String? str(int k) => k < 0 ? null : strs[k];
    for (
      var r = 0;
      r + _intsPerAtomItem <= recs.length;
      r += _intsPerAtomItem
    ) {
      final it = items[recs[r]];
      final first = recs[r + 1], count = recs[r + 2];
      final ts = recs[r + 3], te = recs[r + 4];
      final atoms = List<DyntAtom>.generate(count, (k) {
        final o = (first + k) * _intsPerAtom;
        final a =
            DyntAtom(
                atomLength: ints[o],
                dlgFlag1: ints[o + 1],
                dlgFlag2: ints[o + 2],
                etype: ints[o + 3],
                area: ints[o + 4],
                block: ints[o + 5],
                group: ints[o + 6],
                row: ints[o + 7],
                col: ints[o + 8],
                attr: ints[o + 9],
              )
              ..pushbuttonVLength = ints[o + 10]
              ..pushbuttonVHeight = ints[o + 11]
              ..pushbuttonFunctionCodeOffset = ints[o + 12]
              ..pushbuttonTextOffset = ints[o + 13]
              ..tabstripVLength = ints[o + 14]
              ..tabstripVHeight = ints[o + 15]
              ..tabstripPageId = ints[o + 16]
              ..tabstripFunctionCodeOffset = ints[o + 17]
              ..tabstripTextOffset = ints[o + 18]
              ..tabstripIdOffset = ints[o + 19]
              ..fieldFlag1 = ints[o + 20]
              ..fieldDlen = ints[o + 21]
              ..fieldMlen = ints[o + 22]
              ..fieldMaxnrchars = ints[o + 23]
              ..frameDrows = ints[o + 24]
              ..frameDcols = ints[o + 25]
              ..radiobuttonButton = ints[o + 26]
              ..radiobuttonVisibleLabelLength = ints[o + 27]
              ..radiobuttonEventIdOff = ints[o + 28]
              ..radiobuttonEventIdLen = ints[o + 29]
              ..radiobuttonTextOff = ints[o + 30]
              ..radiobuttonTextLength = ints[o + 31]
              ..ownBytes = Uint8List.sublistView(
                body,
                ints[o + 32],
                ints[o + 33],
              )
              ..nameText = str(ints[o + 36])
              ..pushbuttonText = str(ints[o + 37])
              ..pushbuttonFunctionCode = str(ints[o + 38])
              ..tabstripText = str(ints[o + 39])
              ..tabstripFunctionCode = str(ints[o + 40])
              ..tabstripId = str(ints[o + 41])
              ..xmlpropText = str(ints[o + 42])
              ..fieldText = str(ints[o + 43])
              ..frameText = str(ints[o + 44])
              ..radiobuttonText = str(ints[o + 45]);
        final vs = ints[o + 34];
        if (vs >= 0) a.value = Uint8List.sublistView(body, vs, ints[o + 35]);
        return a;
      });
      _seededAtoms[it] = DyntAtomWalk(
        atoms,
        ts < 0 ? null : Uint8List.sublistView(body, ts, te),
      );
    }
  }
}

const int _intsPerAtomItem = 5;
const int _intsPerAtom = 46;

/// An item whose value is a DYNT atom list the fold parses: 18/9/2 (the
/// dynpro paint) or 18/9/16 (a tabstrip paint, APPL4).
bool _isAtomItem(DiagItem it) =>
    it.isAppl && it.id == applDynt && (it.sid == 2 || it.sid == 16);

/// The worker's atom parse per item of a seeded walk (the walk's items are
/// shared, so the memo lives exactly as long as the frame's decode).
final Expando<DyntAtomWalk> _seededAtoms = Expando('seeded DYNT atoms');

/// The DYNT atom parse of [it] (an 18/9/2 or 18/9/16 item): the one the
/// decode worker shipped with the frame when it decoded it, else
/// [parseDyntAtoms] run here — the same walk either way (audit 2026-10-23
/// P-1). The shipped walk is shared by every caller: do not mutate it.
DyntAtomWalk dyntAtomsOf(DiagItem it) {
  final seeded = _seededAtoms[it];
  if (seeded != null) {
    FrameDecodeOffload.atomItemsSeeded++;
    return seeded;
  }
  FrameDecodeOffload.atomItemsInline++;
  return parseDyntAtoms(it.value);
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
    if (msg is List && msg.length == 8 && msg[0] is int) {
      final id = msg[0] as int;
      final body = msg[1];
      final items = msg[2];
      if (body is TransferableTypedData && items is TransferableTypedData) {
        _Result? r;
        try {
          final recs = msg[5], ints = msg[6], strs = msg[7];
          r = _Result(
            body.materialize().asUint8List(),
            items.materialize().asInt32List(),
            msg[3] as int,
            msg[4] as String?,
            recs is TransferableTypedData &&
                    ints is TransferableTypedData &&
                    strs is List<String>
                ? _AtomsWire(
                    recs.materialize().asInt32List(),
                    ints.materialize().asInt32List(),
                    strs,
                  )
                : null,
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
      // the DYNT atom parse of the paint items, off the UI isolate too
      // (audit 2026-10-23 P-1)
      final atoms = _AtomsWire.encode(walk.items, body);
      reply.send([
        id,
        TransferableTypedData.fromList([body]),
        TransferableTypedData.fromList([ints]),
        t == null ? -1 : t.offsetInBytes - body.offsetInBytes,
        dec.partial,
        atoms == null ? null : TransferableTypedData.fromList([atoms.itemRecs]),
        atoms == null ? null : TransferableTypedData.fromList([atoms.atomInts]),
        atoms?.strings,
      ]);
    } catch (_) {
      reply.send([id]);
    }
  };
  reply.send(inbox.sendPort);
}
