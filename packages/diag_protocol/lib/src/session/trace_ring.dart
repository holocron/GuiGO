/// A fixed-capacity, append-only line log: the session's trace (audit #12 —
/// the trace grew for the logon's whole life).
library;

import 'dart:collection';

/// A [List] of the newest [capacity] lines, oldest first: [add] past the
/// capacity overwrites the oldest line (O(1), no shifting). Reads are the
/// whole List API (`where`, `last`, `List.of`, indexing); writes are [add],
/// [addAll] and [clear] only.
class TraceRing extends ListBase<String> {
  TraceRing(this.capacity) : assert(capacity > 0);

  final int capacity;
  final List<String> _buf = [];
  int _start = 0; // index in [_buf] of the oldest line once full

  /// Lines overwritten so far (dropped off the front).
  int dropped = 0;

  @override
  int get length => _buf.length;

  @override
  set length(int n) {
    if (n != 0) {
      throw UnsupportedError('a TraceRing can only be cleared');
    }
    _buf.clear();
    _start = 0;
  }

  @override
  String operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _buf[(_start + index) % _buf.length];
  }

  @override
  void operator []=(int index, String value) =>
      throw UnsupportedError('a TraceRing is append-only');

  @override
  void add(String element) {
    if (_buf.length < capacity) {
      _buf.add(element);
      return;
    }
    _buf[_start] = element;
    _start = (_start + 1) % capacity;
    dropped++;
  }

  @override
  void addAll(Iterable<String> iterable) {
    for (final l in iterable) {
      add(l);
    }
  }
}
