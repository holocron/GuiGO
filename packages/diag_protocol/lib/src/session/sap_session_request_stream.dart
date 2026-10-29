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
  ///
  /// The chunks are planned from [body], the uncompressed item stream
  /// ([clientFrameBody]) when the sender has it, else from [payload]
  /// inflated once here.
  Future<bool> _sendRequestStream(Uint8List payload, {Uint8List? body}) async {
    // nothing to plan under the buffer: no inflate
    if (clientBodyLength(payload) <= kernelRequestBodyMax) return false;
    final header = Uint8List.sublistView(payload, 0, diagHeaderLen);
    if (body != null) return _sendRequestStreamBody(body, header);
    final dec = decompressFrame(payload);
    if (dec == null || dec.partial != null) return false;
    return _sendRequestStreamBody(dec.body, header);
  }

  /// [_sendRequestStream] over the uncompressed item stream [body] of a
  /// client frame whose 8-byte header is [header] (mode byte set; byte 7
  /// says whether the chunks go out compressed). Byte-identical to
  /// streaming the frame built from them: the chunks are cut from the same
  /// item values, and only the chunk frames are ever compressed.
  Future<bool> _sendRequestStreamBody(Uint8List body, Uint8List header) async {
    final plan = planRequestStream(body);
    if (plan == null) return false;
    final compress = header[7] == 1;
    final n = plan.chunks.length;
    _trace('client reply body ${body.length} B > the kernel request '
        'buffer $kernelRequestBodyMax B: streaming $n sid-4 chunk(s) of '
        '$requestChunkSize B + a ${plan.tail.length}-B sid-1 tail');
    var at = plan.firstStep ?? step;
    try {
      for (var k = 0; k < n; k++) {
        await _sendWire(clientFrame(plan.chunkItems(k, at),
            mode: header[0], compress: compress));
        at = await _awaitChunkAck(k, n, at);
      }
      final tail = clientFrame(plan.tailItems(at), compress: compress);
      // the tail keeps the original frame's header (mode, flags)
      tail.setRange(0, 7, header);
      await _sendWire(tail);
    } on _StreamAnsweredOtherwise {
      // the server answered a chunk with something else (a paint, its error
      // frame): it is not waiting for the rest — the frame was put back for
      // the next receive and the session stays as the server left it
      rethrow;
    } on SessionClosedError {
      rethrow;
    } catch (e) {
      // no receipt (or the socket failed) after a chunk went out: the
      // kernel may be left waiting for the rest — every later action would
      // time out on a session that looks ready; it is failed now, visibly
      // ([closed] fires, the app offers the reconnect)
      _abortTransport(StateError('the client request stream was abandoned '
          'mid-way ($e)'));
      rethrow;
    }
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
        _pong();
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
        _inboxRequeue(payload); // counted again
        final err = diagErrorInfo(frame);
        throw _StreamAnsweredOtherwise('request stream: the server answered '
            'chunk ${k + 1}/$n with a frame that is no 16/8/5 receipt'
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

/// A chunk of the request stream answered by a frame that is no receipt
/// (left in the inbox for the next receive). A [StateError], as before.
class _StreamAnsweredOtherwise extends StateError {
  _StreamAnsweredOtherwise(super.message);
}
