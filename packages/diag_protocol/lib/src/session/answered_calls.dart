/// The calls a window already answered, keyed EXACTLY: a re-read turn must
/// not answer one call twice, and two different calls must never share a
/// key — a shared key silently skips an owed answer and the kernel, blocked
/// in OLE_FLUSH_CALL / the front-end RFC, hangs the session. The key was
/// `Object.hash(step, length, Object.hashAll(value))`: a 30-bit hash, so two
/// same-length calls at one step collided after ~2^15 distinct values.
///
/// A key is the kind, the step and the value ITSELF: two keys are equal
/// only when their bytes are (a cheap sampled fingerprint picks the hash
/// bucket, a full compare decides). A pure-Dart SHA-256 of every answered
/// value (~16 MB/s: a 200 kB joined batch cost ~12 ms on the UI isolate,
/// audit zcode P-12) bought the same exactness. The kept values are copies,
/// bounded by [AnsweredCalls.maxRetainedBytes]: past it the oldest keys
/// keep the value's SHA-256 instead of its bytes (still exact).
library;

import 'dart:collection';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

/// One answered call's exact identity (see [AnsweredCalls.keyOf]).
final class AnsweredCallKey {
  AnsweredCallKey._(this.kind, this.step, Uint8List value)
      : length = value.length,
        _fingerprint = _sample(value),
        _bytes = value;

  final String kind;
  final int step;
  final int length;
  final int _fingerprint;

  /// The value (a copy once the key is kept), null once shed to [_digest].
  Uint8List? _bytes;
  String? _digest;

  String get _sha => _digest ??= _hex(SHA256Digest().process(_bytes!));

  /// Keep the value's digest only (the key stays exact).
  void _shed() {
    if (_bytes == null) return;
    _sha;
    _bytes = null;
  }

  @override
  int get hashCode => Object.hash(kind, step, length, _fingerprint);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AnsweredCallKey ||
        other.step != step ||
        other.length != length ||
        other._fingerprint != _fingerprint ||
        other.kind != kind) {
      return false;
    }
    final a = _bytes, b = other._bytes;
    if (a != null && b != null) return _sameBytes(a, b);
    return _sha == other._sha;
  }

  @override
  String toString() => 'AnsweredCallKey($kind, $step, $length B)';
}

class AnsweredCalls {
  AnsweredCalls({this.max = 1024, this.maxRetainedBytes = 16 << 20});

  /// Only the recent keys can recur (a re-read turn): the oldest past
  /// [max] are dropped.
  final int max;

  /// The value bytes the kept keys hold at most; past it the oldest keys
  /// are shed to their SHA-256.
  final int maxRetainedBytes;

  final LinkedHashSet<AnsweredCallKey> _keys = LinkedHashSet();
  final Queue<AnsweredCallKey> _retained = Queue();
  int _retainedBytes = 0;

  int get length => _keys.length;

  /// The key of the [kind] call [value] closed at [step]. O(1): the value
  /// is copied only when the key is kept ([add]).
  static AnsweredCallKey keyOf(String kind, int step, Uint8List value) =>
      AnsweredCallKey._(kind, step, value);

  bool contains(AnsweredCallKey key) => _keys.contains(key);

  /// Records [key]; false when it was already recorded.
  bool add(AnsweredCallKey key) {
    if (_keys.contains(key)) return false;
    // the kept key owns its bytes: the caller's buffer may be reused
    if (key._bytes case final b?) {
      key._bytes = Uint8List.fromList(b);
      _retained.add(key);
      _retainedBytes += b.length;
    }
    _keys.add(key);
    if (_keys.length > max) {
      final gone = _keys.take(_keys.length - max).toList();
      _keys.removeAll(gone);
      for (final k in gone) {
        if (k._bytes case final b?) {
          _retainedBytes -= b.length;
          k._bytes = null;
        }
      }
      _retained.removeWhere((k) => k._bytes == null);
    }
    while (_retainedBytes > maxRetainedBytes && _retained.isNotEmpty) {
      final k = _retained.removeFirst();
      final n = k._bytes?.length ?? 0;
      k._shed();
      _retainedBytes -= n;
    }
    return true;
  }

  void clear() {
    _keys.clear();
    _retained.clear();
    _retainedBytes = 0;
  }
}

/// A fingerprint of [v] from its length and up to 96 sampled bytes (the
/// head, the tail and an even stride): it only spreads the hash buckets —
/// equality is decided on the bytes.
int _sample(Uint8List v) {
  final n = v.length;
  var h = 0x811c9dc5 ^ n;
  void mix(int b) => h = ((h ^ b) * 0x01000193) & 0x7fffffff;
  if (n <= 96) {
    for (var i = 0; i < n; i++) {
      mix(v[i]);
    }
    return h;
  }
  for (var i = 0; i < 32; i++) {
    mix(v[i]);
    mix(v[n - 1 - i]);
  }
  final stride = n ~/ 33;
  for (var i = 1; i <= 32; i++) {
    mix(v[i * stride]);
  }
  return h;
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _hex(Uint8List d) {
  const digits = '0123456789abcdef';
  final out = StringBuffer();
  for (final b in d) {
    out
      ..writeCharCode(digits.codeUnitAt(b >> 4))
      ..writeCharCode(digits.codeUnitAt(b & 0xf));
  }
  return out.toString();
}
