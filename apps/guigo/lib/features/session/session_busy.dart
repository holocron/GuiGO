import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Whether the session is running an action (or the logon), for the
/// widgets that DRAW it — an inert button, an absorbing pointer over the
/// inputs (an input keeps its look, its focus and the keyboard) — and
/// nothing above them.
///
/// The session screen flips busy around every key press: threaded down as
/// a constructor flag it rebuilt the whole body (every dynpro field, every
/// grid and tree row) twice per action for a change only the leaves show.
/// Read through [of] a leaf rebuilds alone when busy flips; [peek] reads
/// it in a gesture handler without depending on it.
///
/// Outside any scope (a widget test building a view alone) busy is false:
/// the views OR it with their own `busy` flag.
class SessionBusy extends InheritedNotifier<ValueListenable<bool>> {
  const SessionBusy({
    super.key,
    required ValueListenable<bool> busy,
    required super.child,
  }) : super(notifier: busy);

  /// Busy now — [context] rebuilds when it flips.
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<SessionBusy>()
          ?.notifier
          ?.value ??
      false;

  /// The scope's notifier, without depending on it (a state that listens
  /// for the flip itself — a pager's check once an action is done).
  static ValueListenable<bool>? listenableOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SessionBusy>()?.notifier;

  /// Busy now, without depending on it (an event handler's check).
  static bool peek(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SessionBusy>()?.notifier?.value ??
      false;
}

/// A leaf drawn from the busy state: [builder] gets [busy] (the caller's
/// own flag) OR the scope's ([SessionBusy]); only this leaf rebuilds when
/// the scope's flips.
class BusyBuilder extends StatelessWidget {
  const BusyBuilder({super.key, this.busy = false, required this.builder});

  final bool busy;
  final Widget Function(BuildContext context, bool busy) builder;

  @override
  Widget build(BuildContext context) =>
      builder(context, busy || SessionBusy.of(context));
}
