import 'package:diag_protocol/diag_protocol.dart';

/// Whether [e], thrown by an action on [session], is a CLIENT-SIDE refusal
/// on a healthy logon — a stale tree node or window chip, a control of
/// another internal mode, an action the dialect does not model — that the
/// screen reports and redraws past, instead of failing the whole session
/// view (whose only exit is a full re-logon).
///
/// The session's own state is the arbiter: every transport or logon
/// failure leaves it [SessionState.failed] / [SessionState.closed] (the
/// socket lost, the server's close, a dropped transport, an abandoned
/// request stream) — a refusal leaves it [SessionState.ready]. A
/// [SessionClosedError] (the screen closed the logon) and a
/// [TimeoutException]-class wedge are never refusals.
bool isClientRefusal(Object e, SapSession? session) {
  if (session == null || e is SessionClosedError) return false;
  if (e is! StateError && e is! ArgumentError && e is! UnsupportedError) {
    return false;
  }
  return session.state == SessionState.ready && !session.closedByPeer;
}

/// The sentence a refusal snack bar shows: the refusal's own reason.
String refusalText(Object e) {
  final why = switch (e) {
    StateError(:final message) => message,
    ArgumentError(:final message) => '$message',
    UnsupportedError(:final message) => message ?? 'not supported',
    _ => '$e',
  };
  return 'Not done: $why';
}
