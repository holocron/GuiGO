import 'dart:async';
import 'dart:io';

import 'package:diag_protocol/diag_protocol.dart';

/// What the user reads for a failed logon or action — a sentence, not a
/// Dart class name — and the technical text (the exception's own
/// `toString`) for the trace area beneath it.
({String message, String detail}) describeError(Object e) {
  final detail = e.toString();
  final message = switch (e) {
    SessionClosedError() => 'The session was closed.',
    StateError(:final message) => _sentence(message),
    SocketException(:final osError, :final address, :final port) =>
      'Cannot reach the server'
          '${address == null ? '' : ' ${address.host}${port == null ? '' : ':$port'}'}'
          '${osError == null || osError.message.isEmpty ? '' : ' (${osError.message})'}.',
    TimeoutException(:final message) =>
      message == null || message.isEmpty
          ? 'The server did not answer in time.'
          : 'The server did not answer in time: ${_strip(message)}',
    SapRouterException(:final message) =>
      'The SAProuter refused the route: ${_strip(message)}',
    NiProtocolException() || LzhDecodeException() || FormatException() =>
      'The server sent data GuiGo cannot read; the connection was dropped.',
    HandshakeException() ||
    TlsException() => 'The secure connection could not be set up.',
    _ => _sentence(_strip(detail)),
  };
  return (message: message, detail: detail);
}

/// [s] without a leading `SomethingException: ` / `Bad state: ` prefix.
String _strip(String s) =>
    s.replaceFirst(RegExp(r'^(?:\w*(?:Exception|Error)|Bad state):\s*'), '');

/// [s] as a sentence: upper-case first letter, a closing full stop.
String _sentence(String s) {
  final t = s.trim();
  if (t.isEmpty) return 'Something went wrong.';
  final head = t[0].toUpperCase() + t.substring(1);
  return RegExp(r'[.!?…]$').hasMatch(head) ? head : '$head.';
}
