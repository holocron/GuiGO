import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// A tick that fires at most once per frame however often it is marked: a
/// burst of server turns (ST04's auto-refresh, a CFW push train) between
/// two frames rebuilds the screen once, with the last turn's state.
///
/// [mark] schedules a transient frame callback (it runs before the frame's
/// build phase, so the listeners' state is current when the dirty widgets
/// rebuild in that same frame); the marks until then fold into it.
class FrameCoalescedTick extends ChangeNotifier
    implements ValueListenable<int> {
  FrameCoalescedTick();
  bool _scheduled = false;
  bool _disposed = false;
  int _ticks = 0;

  /// How many times the tick fired.
  @override
  int get value => _ticks;

  /// Whether a tick is waiting for the next frame.
  bool get pending => _scheduled;

  /// Ask for a tick on the next frame (no-op when one is already waiting).
  void mark() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _scheduled = false;
      if (_disposed) return;
      _ticks++;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
