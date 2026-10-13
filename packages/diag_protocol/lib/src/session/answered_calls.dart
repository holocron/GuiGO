/// The calls a window already answered, keyed EXACTLY: a re-read turn must
/// not answer one call twice, and two different calls must never share a
/// key — a shared key silently skips an owed answer and the kernel, blocked
/// in OLE_FLUSH_CALL / the front-end RFC, hangs the session. The key was
/// `Object.hash(step, length, Object.hashAll(value))`: a 30-bit hash, so two
/// same-length calls at one step collided after ~2^15 distinct values. It is
/// now the kind, the step, the length and the value's SHA-256.
library;

import 'dart:collection';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

/// One answered call's exact identity (see [AnsweredCalls.keyOf]).
typedef AnsweredCallKey = (String kind, int step, int length, String digest);

class AnsweredCalls {
  AnsweredCalls({this.max = 1024});

  /// Only the recent keys can recur (a re-read turn): the oldest past
  /// [max] are dropped.
  final int max;

  final LinkedHashSet<AnsweredCallKey> _keys = LinkedHashSet();

  int get length => _keys.length;

  /// The key of the [kind] call [value] closed at [step].
  static AnsweredCallKey keyOf(String kind, int step, Uint8List value) =>
      (kind, step, value.length, _hex(SHA256Digest().process(value)));

  bool contains(AnsweredCallKey key) => _keys.contains(key);

  /// Records [key]; false when it was already recorded.
  bool add(AnsweredCallKey key) {
    if (!_keys.add(key)) return false;
    if (_keys.length > max) {
      _keys.removeAll(_keys.take(_keys.length - max).toList());
    }
    return true;
  }

  void clear() => _keys.clear();
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
