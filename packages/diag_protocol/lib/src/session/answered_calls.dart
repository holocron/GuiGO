/// The calls a window already answered, keyed EXACTLY: a re-read turn must
/// not answer one call twice, and two different calls must never share a
/// key — a shared key silently skips an owed answer and the kernel, blocked
/// in OLE_FLUSH_CALL / the front-end RFC, hangs the session. The key was
/// `Object.hash(step, length, Object.hashAll(value))`: a 30-bit hash, so two
/// same-length calls at one step collided after ~2^15 distinct values.
///
/// A key is the kind, the step and the value ITSELF: two keys are equal
/// only when their bytes are (a cheap sampled fingerprint picks the hash
/// bucket, a full compare decides). A kept key holds the call's own bytes:
/// they are immutable by the decode memo's contract (decompressFrame's
/// bodies are never mutated; foldAutomationFrame hands out the item's own
/// view) and a call joined across chunk frames owns a fresh buffer — only
/// a small view that pins a much larger body is copied, which frees that
/// body. The kept bytes are bounded by [AnsweredCalls.maxRetainedBytes]
/// and [AnsweredCalls.max]: past either the OLDEST keys are forgotten
/// outright (only the recent keys can recur: a re-read turn's), the newest
/// always kept so an immediate re-read of an oversize call is still
/// caught. A pure-Dart SHA-256 once stood in for the shed bytes (~16 MB/s
/// on the UI isolate: every large flush past the budget froze the app for
/// 100+ ms — audit perf1 answered-calls); forgetting can only re-answer a
/// long-past call, never conflate two.
library;

import 'dart:collection';
import 'dart:typed_data';

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

  /// The value: the call's own immutable bytes (a copy when the view
  /// pinned a much larger buffer — [AnsweredCalls.add]).
  Uint8List _bytes;

  /// The bytes this key keeps alive: its value's whole buffer.
  int get _pinnedBytes => _bytes.buffer.lengthInBytes;

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
    return _sameBytes(_bytes, other._bytes);
  }

  @override
  String toString() => 'AnsweredCallKey($kind, $step, $length B)';
}

class AnsweredCalls {
  /// Mobile defaults: re-reads come from the same turn or the next one,
  /// so a few hundred recent keys and a few MB of their bytes suffice.
  AnsweredCalls({this.max = 256, this.maxRetainedBytes = 4 << 20});

  /// Only the recent keys can recur (a re-read turn): the oldest past
  /// [max] are dropped.
  final int max;

  /// The value bytes the kept keys hold at most (each key counted by the
  /// buffer it pins); past it the oldest keys are dropped, the newest
  /// always kept.
  final int maxRetainedBytes;

  final LinkedHashSet<AnsweredCallKey> _keys = LinkedHashSet();
  int _retainedBytes = 0;

  int get length => _keys.length;

  /// The bytes the kept keys pin.
  int get retainedBytes => _retainedBytes;

  /// The key of the [kind] call [value] closed at [step]. O(1): the value
  /// is never copied here.
  static AnsweredCallKey keyOf(String kind, int step, Uint8List value) =>
      AnsweredCallKey._(kind, step, value);

  bool contains(AnsweredCallKey key) => _keys.contains(key);

  /// Records [key]; false when it was already recorded.
  bool add(AnsweredCallKey key) {
    if (_keys.contains(key)) return false;
    // the value is immutable (the decode memo's contract): kept as it is —
    // unless it is a small view into a buffer many times its size (an
    // item of a large decoded frame), which a copy frees
    final b = key._bytes;
    if (b.buffer.lengthInBytes > 2 * b.length) {
      key._bytes = Uint8List.fromList(b);
    }
    _keys.add(key);
    _retainedBytes += key._pinnedBytes;
    // past either cap the oldest go, the newest stays
    while (_keys.length > 1 &&
        (_keys.length > max || _retainedBytes > maxRetainedBytes)) {
      final k = _keys.first;
      _keys.remove(k);
      _retainedBytes -= k._pinnedBytes;
    }
    return true;
  }

  void clear() {
    _keys.clear();
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
