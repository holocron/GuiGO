part of 'sap_session.dart';

/// A client answer over the kernel's request buffer ([kernelRequestBodyMax]
/// — ST11 dev_w9 `ThUncompressReq … max output len 29992`, the session
/// deleted past it) goes out as the real GUI's request stream
/// (client_request_stream.dart; a recorded session
/// gui[22..27] / srv[24..28]): `16/8/4` chunks of 29 928 B, each sent only
/// after the server's `16/8/5` receipt of the one before, then the `16/8/1`
/// tail. The receipts belong to the stream: read here, they advance the
/// step and are never folded as a screen turn.
extension _SapSessionRequestStream on SapSession {
  /// Stream [payload] (a client frame, mode byte set) when its body is
  /// over the buffer and it carries a `16/8/1` reply; false (nothing sent)
  /// when it does not stream.
  Future<bool> _sendRequestStream(Uint8List payload) async {
    final dec = decompressFrame(payload);
    if (dec == null || dec.partial != null) return false;
    final plan = planRequestStream(dec.body);
    if (plan == null) return false;
    final compress = payload[7] == 1;
    final n = plan.chunks.length;
    _trace('client reply body ${dec.body.length} B > the kernel request '
        'buffer $kernelRequestBodyMax B: streaming $n sid-4 chunk(s) of '
        '$requestChunkSize B + a ${plan.tail.length}-B sid-1 tail');
    var at = plan.firstStep ?? step;
    for (var k = 0; k < n; k++) {
      await _sendWire(clientFrame(plan.chunkItems(k, at),
          mode: payload[0], compress: compress));
      at = await _awaitChunkAck(k, n, at);
    }
    final tail = clientFrame(plan.tailItems(at), compress: compress);
    // the tail keeps the original frame's header (mode, flags)
    tail.setRange(0, 7, payload);
    await _sendWire(tail);
    return true;
  }

  /// Read the server's `16/8/5` receipt of chunk [k] of [n] and return the
  /// step it advanced to ([at] when it names none). Anything else ends the
  /// stream: the frame goes back to the inbox for the next receive and the
  /// stream is abandoned, never half-guessed.
  Future<int> _awaitChunkAck(int k, int n, int at) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      final Uint8List payload;
      try {
        payload = await _nextPayload(deadline);
      } on TimeoutException {
        throw TimeoutException(
            'request stream: no 16/8/5 receipt for chunk ${k + 1}/$n');
      }
      if (_isNiPing(payload)) {
        _sock?.add(niPongFrame);
        continue;
      }
      var frame = payload;
      if (_sncCtx != null) {
        final plain = _sncUnwrap(_sncCtx!, payload);
        if (plain == null) continue; // a non-data frame
        frame = plain;
      }
      final ackAt = chunkAckStep(frame);
      if (ackAt == null) {
        _inbox.addFirst(payload);
        final err = diagErrorInfo(frame);
        throw StateError('request stream: the server answered chunk '
            '${k + 1}/$n with a frame that is no 16/8/5 receipt'
            '${err == null ? '' : ' (server error "$err")'}; '
            'the stream is abandoned');
      }
      if (ackAt < 0) return at;
      step = ackAt;
      if (!_w.onRelay) _w.homeStep = ackAt;
      return ackAt;
    }
  }
}
