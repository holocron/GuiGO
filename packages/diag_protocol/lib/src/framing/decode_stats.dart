/// Work counters of the receive path: how often a frame is really decoded,
/// its item list really walked, and an OLE_FLUSH_CALL really parsed. The
/// decode-once contract (audit #8) is that every reader of one frame in a
/// turn shares ONE decode and ONE walk ([decompressFrame] memoizes both on
/// the frame object), and that one completed flush call is parsed once for
/// all the side models it feeds. Tests and benchmarks read these; nothing
/// in the protocol depends on them.
library;

abstract final class DecodeStats {
  /// [decompressFrame] cache misses: a frame decoded (LZH / LZC inflated or
  /// its body sliced) for the first time.
  static int frameDecodes = 0;

  /// [DecompressedFrame.walk] builds: a frame body's item list walked.
  static int frameWalks = 0;

  /// `parseFlushCall` runs.
  static int flushParses = 0;

  static void reset() {
    frameDecodes = 0;
    frameWalks = 0;
    flushParses = 0;
  }
}
