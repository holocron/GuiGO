/// Thin dart:ffi binding to the system zlib — the LZH fast path needs raw inflate
/// with a preset dictionary and end-of-stream detection, which dart:io's codec API
/// does not expose. libz is a public library on every target (iOS, Android, macOS).
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../framing/decode_stats.dart';

// zlib stream constants (zlib.h).
const int zOk = 0;
const int zStreamEnd = 1;
const int zNeedDict = 2;
const int zErrno = -1;
const int zStreamError = -2;
const int zDataError = -3;
const int zMemError = -4;
const int zBufError = -5;
const int zNoFlush = 0;
const int zFinish = 4;

const int zDefaultStrategy = 0;
const int zFixed = 4;

/// z_stream for LP64 platforms (every supported target: arm64 iOS/Android,
/// x86_64 Android emulator, arm64 macOS). `uLong` is 8 bytes there.
final class ZStream extends Struct {
  external Pointer<Uint8> nextIn; // 0
  @Uint32()
  external int availIn; // 8
  @Uint32()
  // ignore: unused_field
  external int _pad0; // 12
  @Uint64()
  external int totalIn; // 16
  external Pointer<Uint8> nextOut; // 24
  @Uint32()
  external int availOut; // 32
  @Uint32()
  // ignore: unused_field
  external int _pad1; // 36
  @Uint64()
  external int totalOut; // 40
  external Pointer<Utf8> msg; // 48
  external Pointer<Void> state; // 56
  external Pointer<Void> zalloc; // 64 (NULL -> zlib's default allocator)
  external Pointer<Void> zfree; // 72
  external Pointer<Void> opaque; // 80
  @Uint32()
  external int dataType; // 88
  @Uint32()
  // ignore: unused_field
  external int _pad2; // 92
  @Uint64()
  external int adler; // 96
  @Uint64()
  external int reserved; // 104
}

typedef _inflateInit2Native = Int32 Function(
    Pointer<ZStream>, Int32, Pointer<Utf8>, Uint32);
typedef _inflateInit2Dart = int Function(
    Pointer<ZStream>, int, Pointer<Utf8>, int);
typedef _inflateSetDictionaryNative = Int32 Function(
    Pointer<ZStream>, Pointer<Uint8>, Uint32);
typedef _inflateSetDictionaryDart = int Function(
    Pointer<ZStream>, Pointer<Uint8>, int);
typedef _inflateNative = Int32 Function(Pointer<ZStream>, Int32);
typedef _inflateDart = int Function(Pointer<ZStream>, int);
typedef _deflateInit2Native = Int32 Function(
    Pointer<ZStream>, Int32, Int32, Int32, Int32, Int32, Pointer<Utf8>, Uint32);
typedef _deflateInit2Dart = int Function(
    Pointer<ZStream>, int, int, int, int, int, Pointer<Utf8>, int);
typedef _deflateNative = Int32 Function(Pointer<ZStream>, Int32);
typedef _deflateDart = int Function(Pointer<ZStream>, int);

final class _ZlibLib {
  final DynamicLibrary lib;
  late final Pointer<Utf8> version;
  late final int sizeofStream = sizeOf<ZStream>();

  late final _inflateInit2Dart inflateInit2_;
  late final _inflateSetDictionaryDart inflateSetDictionary;
  late final _inflateDart inflate;
  late final int Function(Pointer<ZStream>) inflateEnd;
  late final int Function(Pointer<ZStream>) inflateReset;
  late final _deflateInit2Dart deflateInit2_;
  late final _deflateDart deflate;
  late final int Function(Pointer<ZStream>) deflateEnd;
  late final Pointer<Utf8> Function() zlibVersion;

  _ZlibLib._(this.lib) {
    zlibVersion = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
        'zlibVersion');
    version = zlibVersion();
    inflateInit2_ = lib
        .lookupFunction<_inflateInit2Native, _inflateInit2Dart>('inflateInit2_');
    inflateSetDictionary = lib.lookupFunction<_inflateSetDictionaryNative,
        _inflateSetDictionaryDart>('inflateSetDictionary');
    inflate = lib.lookupFunction<_inflateNative, _inflateDart>('inflate');
    inflateEnd =
        lib.lookupFunction<Int32 Function(Pointer<ZStream>), int Function(Pointer<ZStream>)>('inflateEnd');
    inflateReset =
        lib.lookupFunction<Int32 Function(Pointer<ZStream>), int Function(Pointer<ZStream>)>('inflateReset');
    deflateInit2_ = lib
        .lookupFunction<_deflateInit2Native, _deflateInit2Dart>('deflateInit2_');
    deflate = lib.lookupFunction<_deflateNative, _deflateDart>('deflate');
    deflateEnd =
        lib.lookupFunction<Int32 Function(Pointer<ZStream>), int Function(Pointer<ZStream>)>('deflateEnd');
  }

  static _ZlibLib? _instance;
  static StateError? _loadError;

  /// libz is linked into the app on iOS/macOS (DynamicLibrary.process finds it);
  /// Android exposes it as the public NDK library libz.so. A failed load is
  /// memoized: the probe runs once per process, not once per frame.
  static _ZlibLib get instance {
    if (_instance != null) return _instance!;
    if (_loadError != null) throw _loadError!;
    Object? firstError;
    for (final open in [
      () => DynamicLibrary.process(),
      () => DynamicLibrary.open('libz.so'),
      () => DynamicLibrary.open('libz.dylib'),
    ]) {
      try {
        final lib = open();
        lib.lookup('inflateInit2_'); // probe
        return _instance = _ZlibLib._(lib);
      } catch (e) {
        firstError ??= e;
      }
    }
    throw _loadError = StateError('zlib not available via FFI: $firstError');
  }

  static bool get available {
    if (_instance != null) return true;
    if (_loadError != null) return false;
    try {
      instance;
      return true;
    } on StateError {
      return false;
    }
  }
}

/// Whether native zlib loaded (probed once, memoized either way).
bool get zlibAvailable => _ZlibLib.available;

/// A raw-deflate inflater over native zlib, optionally primed with a preset
/// dictionary (the LZH zero window). Feed [push] chunks; [finished] reports
/// Z_STREAM_END; after a data error the object is unusable (matches zlib).
class RawInflate {
  final _ZlibLib _z;
  final Pointer<ZStream> _strm;
  final Pointer<Uint8> _outBuf;
  static const int _outCap = 1 << 16;
  bool _disposed = false;
  bool _finished = false;
  bool _failed = false;
  String? error;
  int totalOut = 0;

  // pooled inflaters only: the window bits and the dictionary a reset
  // re-primes with (its native copy, made once per dictionary)
  int _windowBits = -15;
  Uint8List? _dictionary;
  bool _pooled = false;
  bool _inPool = false;

  // the native input buffer [pushParts] copies into, kept across calls (a
  // pooled inflater serves every `03 05` cell and frame: no malloc + free
  // per push) and grown on demand up to [_keptInputCap]; a larger input
  // takes a one-off buffer, so an idle pooled inflater never pins MBs
  Pointer<Uint8> _inBuf = nullptr;
  int _inCap = 0;
  static const int _keptInputCap = 1 << 16;

  // the library resolves FIRST: an unavailable zlib throws before any
  // native allocation (nothing to leak)
  RawInflate({int windowBits = -15, Uint8List? dictionary})
      : _z = _ZlibLib.instance,
        _strm = calloc<ZStream>(),
        _outBuf = malloc<Uint8>(_outCap) {
    final z = _z;
    DecodeStats.inflaterInits++;
    _strm.ref
      ..nextIn = nullptr
      ..availIn = 0
      ..zalloc = nullptr
      ..zfree = nullptr
      ..opaque = nullptr;
    var ret = z.inflateInit2_(_strm, windowBits, z.version, z.sizeofStream);
    if (ret != zOk) {
      // nothing past a failed init: no dictionary on an unset stream
      _fail('inflateInit2_ -> $ret');
      return;
    }
    if (dictionary != null && dictionary.isNotEmpty) {
      final dict = malloc<Uint8>(dictionary.length)
        ..asTypedList(dictionary.length).setAll(0, dictionary);
      ret = z.inflateSetDictionary(_strm, dict, dictionary.length);
      malloc.free(dict);
      if (ret != zOk) _fail('inflateSetDictionary -> $ret');
    }
  }

  /// The idle pooled inflaters ([RawInflate.pooled] / [release]).
  static final List<RawInflate> _pool = [];

  /// How many idle inflaters the pool keeps (each holds a zlib state, its
  /// 32 KB window and the 64 KB output buffer).
  static const int poolCap = 4;

  /// The native copies of the dictionaries pooled inflaters are primed
  /// with, made once per dictionary object for the process (the LZH zero
  /// window: one 32 KB copy, not a malloc + copy + free per `03 05` cell).
  static final Map<Uint8List, Pointer<Uint8>> _nativeDicts = Map.identity();

  static Pointer<Uint8> _nativeDict(Uint8List d) =>
      _nativeDicts[d] ??= malloc<Uint8>(d.length)
        ..asTypedList(d.length).setAll(0, d);

  /// An inflater from the pool — a fresh one (as [RawInflate.new]) when none
  /// with the same [windowBits] and [dictionary] object is idle, else an idle
  /// one `inflateReset` and re-primed with [dictionary]: the same state as a
  /// fresh one (zlib's reset keeps only the allocations). Hand it back with
  /// [release]. [dictionary]'s bytes must not change while the process runs
  /// (its native copy is kept; the LZH zero window is constant).
  /// every frame and every `03 05` cell built a
  /// fresh context, 64 KB buffer and 32 KB dictionary copy.
  factory RawInflate.pooled({int windowBits = -15, Uint8List? dictionary}) {
    for (var i = _pool.length - 1; i >= 0; i--) {
      final p = _pool[i];
      if (p._windowBits != windowBits || !identical(p._dictionary, dictionary)) {
        continue;
      }
      _pool.removeAt(i);
      p._inPool = false;
      if (p._reset()) return p;
      p._destroy(); // a reset zlib refused: never handed out again
    }
    final inf = RawInflate._pooled(windowBits, dictionary);
    return inf;
  }

  RawInflate._pooled(int windowBits, Uint8List? dictionary)
      : _z = _ZlibLib.instance,
        _strm = calloc<ZStream>(),
        _outBuf = malloc<Uint8>(_outCap) {
    DecodeStats.inflaterInits++;
    _windowBits = windowBits;
    _dictionary = dictionary;
    _pooled = true;
    _strm.ref
      ..nextIn = nullptr
      ..availIn = 0
      ..zalloc = nullptr
      ..zfree = nullptr
      ..opaque = nullptr;
    final ret =
        _z.inflateInit2_(_strm, windowBits, _z.version, _z.sizeofStream);
    if (ret != zOk) {
      _fail('inflateInit2_ -> $ret');
      return;
    }
    _prime();
  }

  void _prime() {
    final d = _dictionary;
    if (d == null || d.isEmpty) return;
    final ret = _z.inflateSetDictionary(_strm, _nativeDict(d), d.length);
    if (ret != zOk) _fail('inflateSetDictionary -> $ret');
  }

  /// Back to the fresh state: false when zlib refuses the reset.
  bool _reset() {
    _finished = false;
    _failed = false;
    error = null;
    totalOut = 0;
    _strm.ref
      ..nextIn = nullptr
      ..availIn = 0;
    if (_z.inflateReset(_strm) != zOk) return false;
    _prime();
    return !_failed;
  }

  /// Free the idle pooled inflaters and the native dictionary copies (an
  /// isolate about to exit: what the pool holds is native memory the
  /// isolate's death does not return — at most [poolCap] inflaters of
  /// ~100 KB and one 32 KB dictionary per isolate). Inflaters in use are
  /// freed when released.
  static void drainPool() {
    for (final p in _pool) {
      p._inPool = false;
      p._destroy();
    }
    _pool.clear();
    for (final d in _nativeDicts.values) {
      malloc.free(d);
    }
    _nativeDicts.clear();
  }

  /// Done with a [RawInflate.pooled] inflater: back to the pool (or freed
  /// when the pool is full); the caller must not touch it again. A
  /// non-pooled inflater is simply disposed.
  void release() {
    if (_disposed || _inPool) return;
    if (!_pooled || _pool.length >= poolCap) {
      dispose();
      return;
    }
    _inPool = true;
    _pool.add(this);
  }

  bool get finished => _finished;
  bool get failed => _failed;

  void _fail(String msg) {
    _failed = true;
    error = msg;
  }

  /// Push [input]; decoded bytes are appended to [out]. Returns the zlib status.
  int push(Uint8List input, BytesBuilder out) => pushParts([input], (view) {
        out.add(view);
        return true;
      }, copyOut: true);

  /// Push the concatenation of [parts] (copied once into native memory);
  /// every decoded run is handed to [sink] as a view of the reusable native
  /// buffer, valid only during the call — the sink copies what it keeps.
  /// [sink] returning false aborts the stream (an output cap): the inflater
  /// fails with `output cap exceeded`. With [copyOut] the sink receives
  /// Dart-heap copies instead of native views.
  int pushParts(List<Uint8List> parts, bool Function(Uint8List view) sink,
      {bool copyOut = false}) {
    if (_finished || _failed) return zOk;
    var total = 0;
    for (final p in parts) {
      total += p.length;
    }
    if (total == 0) return zOk;
    final z = _z;
    final kept = total <= _keptInputCap;
    if (kept && _inCap < total) {
      if (_inCap > 0) malloc.free(_inBuf);
      var cap = 4096;
      while (cap < total) {
        cap <<= 1;
      }
      _inBuf = malloc<Uint8>(cap);
      _inCap = cap;
    }
    final inBuf = kept ? _inBuf : malloc<Uint8>(total);
    final inView = inBuf.asTypedList(total);
    var at = 0;
    for (final p in parts) {
      inView.setRange(at, at + p.length, p);
      at += p.length;
    }
    final outView = _outBuf.asTypedList(_outCap);
    _strm.ref
      ..nextIn = inBuf
      ..availIn = total;
    int status = zOk;
    try {
      while (true) {
        _strm.ref
          ..nextOut = _outBuf
          ..availOut = _outCap;
        status = z.inflate(_strm, zNoFlush);
        final produced = _outCap - _strm.ref.availOut;
        if (produced > 0) {
          final run = Uint8List.sublistView(outView, 0, produced);
          totalOut += produced;
          if (!sink(copyOut ? Uint8List.fromList(run) : run)) {
            _fail('output cap exceeded');
            break;
          }
        }
        if (status == zStreamEnd) {
          _finished = true;
          break;
        }
        if (status == zBufError) {
          // no progress possible: every input byte consumed while the last
          // run filled the output buffer exactly (a 64 KB boundary) — the
          // stream simply wants more input, it is not broken
          status = zOk;
          break;
        }
        if (status != zOk) {
          _fail(_strm.ref.msg == nullptr
              ? 'inflate -> $status'
              : _strm.ref.msg.toDartString());
          break;
        }
        if (_strm.ref.availIn == 0 && _strm.ref.availOut > 0) break;
      }
      return status;
    } finally {
      // zlib keeps no hold on the input past the call: the next push
      // re-points next_in (a stream that ended or failed takes none)
      if (!kept) malloc.free(inBuf);
    }
  }

  void dispose() {
    if (_disposed || _inPool) return;
    _destroy();
  }

  void _destroy() {
    if (_disposed) return;
    _disposed = true;
    _z.inflateEnd(_strm);
    calloc.free(_strm);
    malloc.free(_outBuf);
    if (_inCap > 0) {
      malloc.free(_inBuf);
      _inBuf = nullptr;
      _inCap = 0;
    }
  }
}

/// One-shot raw deflate (RFC 1951) with a 16 KB window — SAP's LZH window.
/// [strategy] defaults to fixed Huffman; the LZH compressor asks for
/// [zDefaultStrategy] (dynamic trees, the real GUI's block type) first.
Uint8List rawDeflate(Uint8List data,
    {int level = 6, int windowBits = -14, int strategy = zFixed}) {
  final z = _ZlibLib.instance;
  final strm = calloc<ZStream>();
  {
    strm.ref.zalloc = nullptr;
    strm.ref.zfree = nullptr;
    strm.ref.opaque = nullptr;
  }
  final out = BytesBuilder(copy: false); // each run is already a fresh copy
  final outBuf = malloc<Uint8>(1 << 16);
  final inBuf = malloc<Uint8>(data.length)
    ..asTypedList(data.length).setAll(0, data);
  try {
    var ret = z.deflateInit2_(strm, level, 8 /* Z_DEFLATED */, windowBits, 8,
        strategy, z.version, z.sizeofStream);
    if (ret != zOk) throw StateError('deflateInit2_ -> $ret');
    strm.ref
      ..nextIn = inBuf
      ..availIn = data.length;
    while (true) {
      strm.ref
        ..nextOut = outBuf
        ..availOut = 1 << 16;
      ret = z.deflate(strm, zFinish);
      final produced = (1 << 16) - strm.ref.availOut;
      if (produced > 0) {
        out.add(
            Uint8List.fromList(outBuf.asTypedList(produced)));
      }
      if (ret == zStreamEnd) break;
      if (ret != zOk) throw StateError('deflate -> $ret');
    }
    return out.takeBytes();
  } finally {
    z.deflateEnd(strm);
    calloc.free(strm);
    malloc.free(outBuf);
    malloc.free(inBuf);
  }
}
