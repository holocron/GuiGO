/// One-pass facts of a received frame's item walk, memoized on the frame
/// object the way its decode and walk are ([decompressFrame]): the
/// session's side folds (grids, charts, NetPlans, canvases, the tree
/// binder, the editor) each asked "does this turn name a program?" and
/// every action round "does it paint?" by re-scanning every item of every
/// frame — per frame, per fold, per round. A
/// frame's items never change once walked, so one scan answers them all.
library;

import 'dart:typed_data';

import 'diag_frame.dart';
import 'envelope.dart';

/// What one frame's items say (see [frameFacts]).
final class FrameFacts {
  const FrameFacts._(this.namesProgram, this.paintsScreen);

  /// The frame carries the program name (ST_R3INFO 16/6/13): a screen's
  /// paint names its program.
  final bool namesProgram;

  /// The frame paints a screen: a program name or any DYNT (16/9/*) item.
  final bool paintsScreen;
}

final Expando<FrameFacts> _facts = Expando('frame facts');

/// The [FrameFacts] of [frame], null when it does not decode.
FrameFacts? frameFacts(Uint8List frame) {
  final memo = _facts[frame];
  if (memo != null) return memo;
  final dec = decompressFrame(frame);
  if (dec == null) return null;
  var program = false, screen = false;
  for (final it in dec.walk.items) {
    if (!it.isAppl) continue;
    if (it.id == applStR3Info && it.sid == 13) {
      program = true;
      screen = true;
      break;
    }
    if (it.id == applDynt) screen = true;
  }
  return _facts[frame] = FrameFacts._(program, screen);
}
