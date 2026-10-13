/// The live DIAG session: NI socket, strict request→reply turn discipline,
/// the login bootstrap ladder (fixture replay + wall), and dynpro actions.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../codepages.dart' show wireDecode, wireText;
import '../framing/client_request_stream.dart';
import '../framing/diag_frame.dart';
import '../framing/envelope.dart';
import '../items/dynt_atom.dart' show attrInvisible;
import '../ni/ni_frame.dart';
import '../ni/saprouter.dart';
import '../cfw/client_table_pull.dart';
import '../cfw/context_menu.dart';
import '../cfw/control_toolbar.dart';
import '../cfw/doi.dart';
import '../cfw/dp_cache.dart' show DpCache;
import '../cfw/dragdrop_service.dart';
import '../cfw/ea_responder.dart';
import '../cfw/flush_call.dart';
import '../cfw/frontend_rfc.dart';
import '../cfw/reply_container.dart' show constPrefix;
import '../cfw/html_viewer.dart';
import '../cfw/stream_paint.dart';
import '../cfw/text_editor.dart';
import '../cfw/tree_header_names.dart';
import '../screen/sap_calendar.dart';
import '../screen/sap_canvas.dart';
import '../screen/sap_chart.dart';
import '../screen/grid_rows.dart';
import '../screen/sap_grid.dart';
import '../screen/sap_netplan.dart';
import '../screen/sap_picture.dart';
import '../screen/sap_tree.dart';
import '../screen/sap_value_help.dart';
import '../screen/screen_layout.dart';
import '../screen/screen_model.dart';
import '../screen/type_ahead.dart';
import '../snc/snc_context.dart';
import 'frontend_profile.dart';
import 'layout_round.dart';
import 'resize_round.dart';
import '../snc/snc_frame.dart';
import 'actions.dart';
import 'answered_calls.dart';
import 'calendar_actions.dart';
import 'canvas_actions.dart';
import 'context_menu_actions.dart';
import 'menu_actions.dart';
import 'cfw_dialog_actions.dart';
import 'editor_actions.dart';
import 'frames.dart';
import 'grid_edit_actions.dart';
import 'grid_rows_request.dart';
import 'grid_selection.dart';
import 'imode_scope.dart';
import 'login.dart';
import 'logon_frames.dart';
import 'table_cell.dart';
import 'trace_ring.dart';
import 'type_ahead_actions.dart';
import 'value_help_actions.dart';

part 'sap_session_calendar.dart';
part 'sap_session_canvas.dart';
part 'sap_session_cfw_fields.dart';
part 'sap_session_context_menu.dart';
part 'sap_session_editor.dart';
part 'sap_session_field_type_ahead.dart';
part 'sap_session_fields.dart';
part 'sap_session_grid.dart';
part 'sap_session_grid_edit.dart';
part 'sap_session_grid_rows.dart';
part 'sap_session_html.dart';
part 'sap_session_layout.dart';
part 'sap_session_menu.dart';
part 'sap_session_picture.dart';
part 'sap_session_remote_logon.dart';
part 'sap_session_request_stream.dart';
part 'sap_session_resize.dart';
part 'sap_session_toolbar.dart';
part 'sap_session_tree.dart';
part 'sap_session_value_help.dart';
part 'sap_session_windows.dart';

class SapSystem {
  SapSystem({
    required this.name,
    required this.host,
    this.port = 3200,
    this.routerString = '',
    this.client = '100',
    this.user = '',
    this.language = 'EN',
  });

  String name;
  String host;
  int port;
  String routerString;
  String client;
  String user;
  String language;
}

enum SessionState { disconnected, connecting, loggingIn, ready, failed, closed }

/// The session was [SapSession.close]d: what an action, receive or logon
/// still in flight (or started after) fails with.
class SessionClosedError extends StateError {
  SessionClosedError() : super('session closed');
}

/// The SNC context failed on a received frame (a DATA_MIC frame failed its
/// integrity check, [SncContext.error]): the protected connection cannot be
/// trusted, so the logon ends at once with that error — the frame was
/// skipped silently and the action hung to its 30 s receive timeout.
class SncFailedError extends StateError {
  SncFailedError(String reason) : super('SNC failed: $reason');
}

/// A receive turn that timed out after PART of it arrived: [frames] were
/// folded into the screen model (and emitted on [SapSession.turns]) before
/// this was thrown — the caller sees the turn is incomplete instead of a
/// bare timeout. A [TimeoutException], so existing timeout handling holds.
class PartialTurnTimeout extends TimeoutException {
  PartialTurnTimeout(this.frames, Duration? duration)
      : super(
            'the server turn is incomplete: ${frames.length} frame(s) '
            'arrived (folded), then no reply',
            duration);

  final List<Uint8List> frames;
}

/// One DIAG logon over one TCP socket. The logon opens with the connect
/// frame and the credential submit built from their protocol fields
/// (logon_frames.dart — or, for an offline replay, a recorded handshake's
/// two frames patched with the credentials), then answers the Easy Access
/// ladder live (raw_bootstrap port); later turns are driven by [press],
/// [okcode] and [fill].
final RegExp _controlOkcode = RegExp(r'^%_G[CS] (\d+) ');

class SapSession {
  SapSession({
    required this.system,
    this.fixtureFrames,
    required String password,
    this.terminal = defaultLogonTerminal,
    int screenRows = 40,
    int screenCols = 146,
    bool sizedWindow = false,
    this.endOtherSessions = false,
    this.snc,
    this.onWall,
    this.answerDialect = GuiDialect.windows,
  })  : _password = password,
        _screenRows = screenRows,
        _screenCols = screenCols {
    // the logon's first window, DIAG mode 0 (sap_session_windows.dart)
    _modes.w = _modes.open[0] = _WindowState(0, SapWindowOrigin.logon,
        screenRows: screenRows, screenCols: screenCols);
    // the client's own window (an app that knows its screen): every round
    // reports the pixels of THIS window (sap_session_resize.dart)
    if (sizedWindow) _w.ctx.sizeWindow(screenRows, screenCols);
  }

  /// The logon's windows, one per DIAG mode (sap_session_windows.dart);
  /// every per-window field below reads the active one ([_w]).
  final _WindowTable _modes = _WindowTable();
  _WindowState get _w => _modes.w;

  /// Whether a SERVER-caused close of the active window is answered with
  /// the parent-mode resume round (SES event 47) when the parent did not
  /// repaint unasked. The real Java GUI sends it (a recorded session
  /// gui[69]); the real Windows GUI never does (a recorded session
  /// raw srv[1557] / srv[1592]: the next client frame is the user's own
  /// action in the parent) — so on by default for the Java dialect only.
  late bool resumeRoundAfterServerClose = answerDialect == GuiDialect.java;

  /// The dialect the OLE answers' _RESULT types are keyed on. The live
  /// session connects as the Windows GUI (buildConnectFrame), so Windows;
  /// an offline replay of a Java-GUI capture passes [GuiDialect.java].
  final GuiDialect answerDialect;

  final SapSystem system;
  /// A RECORDED logon handshake (frames 0 = connect, 1 = credential
  /// submit) to patch instead of building the two frames — the offline
  /// replays ([replayLogin]) of captures recorded on that handshake. Null
  /// (a live logon): [buildConnectFrame] / [buildLogonFrame].
  final List<Uint8List>? fixtureFrames;

  /// The terminal name the connect frame presents (the DP head's 15-byte
  /// `terminal`, what SM04 lists for this front end).
  final String terminal;

  /// The logon password: read once, into the credential submit, then
  /// dropped — the session keeps no reference for its lifetime (nor after
  /// a failed connect / [close]).
  String? _password;

  /// The SAP window's size in character cells (rows x cols) — what the logon
  /// reports (SES dims, METRICS) and every round's window pixels / METRICS /
  /// SCROLL_INFOS2 follow; changed at runtime by [resizeWindow]. 40 x 146
  /// unless the constructor names another.
  int get screenRows => _screenRows;
  int get screenCols => _screenCols;
  int _screenRows;
  int _screenCols;
  final bool endOtherSessions;

  /// SNC (Kerberos) protection; null = plain DIAG.
  final SncConfig? snc;

  /// Invoked when the multi-logon wall appears during logon. The bootstrap
  /// pauses until the future resolves; null (default) auto-answers with
  /// [endOtherSessions].
  final Future<WallOption> Function(WallInfo wall)? onWall;

  Socket? _sock;
  StreamSubscription<Uint8List>? _sockSub;
  final NiDeframer _deframer = NiDeframer();
  // a Socket can be listened to only once: one subscription for the whole
  // session deframes into [_inbox], and every receive reads from there
  final Queue<Uint8List> _inbox = Queue();
  Completer<void>? _wake;
  Object? _sockError;
  SncContext? _sncCtx;
  final _framesController = StreamController<List<Uint8List>>.broadcast();
  SessionState state = SessionState.disconnected;
  String? lastError;

  /// The last moment bytes crossed the socket either way — the idle gap
  /// a server-side close is measured against.
  DateTime? _lastWire;
  final _closedController = StreamController<String>.broadcast();

  /// Fires once when the SERVER closes the socket (the kernel's idle
  /// auto-logout, rdisp/gui_auto_logout — the test system tears a logon down after
  /// ~5 min of silence — or a teardown the last action provoked), with
  /// the diagnosis; [close] never fires it. A log-off ([loggedOff]: the
  /// server's end of conversation) fires it at the EOC frame.
  Stream<String> get closed => _closedController.stream;

  /// Whether the server ended this logon (vs. our own [close]).
  bool closedByPeer = false;

  /// Whether the server LOGGED THE SESSION OFF: it sent the end of the
  /// conversation (`00 0a …` EOP|EOC, [modeControlEndsConversation]) — the
  /// `=YES` of Système > Fin de session, a `/nex` — and closes the socket.
  /// A clean end ([closedByPeer] too, [state] [SessionState.closed]), not a
  /// connection lost: nothing to reconnect.
  bool loggedOff = false;

  String _peerClosedMessage() {
    if (loggedOff) return 'logged off — the server ended the session';
    final last = _lastWire;
    final gap = last == null ? null : DateTime.now().difference(last);
    if (gap != null && gap.inSeconds >= 60) {
      return 'the server closed the connection after ${gap.inSeconds}s '
          'without activity — the kernel\'s idle auto-logout '
          '(rdisp/gui_auto_logout); log on again';
    }
    return 'the server closed the connection'
        '${gap == null ? '' : ' ${gap.inSeconds}s after the last exchange'}'
        '${serverError == null ? '' : ' — the server said: $serverError'}'
        '${_oversizeSent == null ? '' : ' — $_oversizeSent'}';
  }

  /// The text of the last ERROR frame (header err_no != 0) the server sent
  /// — the kernel's own message before it tears a session down (shown in
  /// the trace and in the closed message). Null: none this logon.
  String? serverError;

  /// Set when a client frame went out whose body exceeds the kernel's
  /// request buffer ([kernelRequestBodyMax]): the reason a following
  /// server close is most likely about.
  String? _oversizeSent;

  /// Trace and remember the server's error text of [frame], if it is one.
  void _noteServerError(Uint8List frame) {
    final info = diagErrorInfo(frame);
    if (info == null) return;
    serverError = info.isEmpty ? 'error ${frame[3]}' : info;
    _trace('server error frame (err_no ${frame[3]}): "$serverError"');
  }

  void _notifyClosed() {
    if (closedByPeer) return;
    closedByPeer = true;
    if (state != SessionState.closed) {
      state = loggedOff ? SessionState.closed : SessionState.failed;
    }
    lastError = loggedOff ? null : _sockError?.toString();
    if (!_closedController.isClosed) {
      _closedController.add(_peerClosedMessage());
    }
  }

  /// The dialog-step counter. The SERVER owns it: every client frame echoes
  /// the last server-observed step UNCHANGED — never incremented client-side
  /// (a recorded session, a recorded session timeline, a recorded session
  /// stms_wingui; the engine's _observe_received/send_msg). An ahead step
  /// makes the kernel silently discard the frame: the wall answer sent as
  /// paint-step+1 never got a reply and the logon died on timeout.
  /// [_fold] syncs it from every server frame carrying 4/38; several client
  /// frames may share one step (the the test system ack train: six receipts all at 13).
  /// Per window: each DIAG mode counts its own (a recorded session raw
  /// srv[12]: mode 1 starts at step 1 while mode 0 stands at 15).
  int get step => _w.step;
  set step(int v) => _w.step = v;

  /// The active window's screen.
  ScreenModel? get screen => _w.screen;
  set screen(ScreenModel? v) => _w.screen = v;

  /// The last non-modal paint — the window a modal dialog covers.
  ScreenModel? get baseScreen => _w.baseScreen;
  set baseScreen(ScreenModel? v) => _w.baseScreen = v;
  ActionContext get ctx => _w.ctx;
  set ctx(ActionContext v) => _w.ctx = v;

  /// Every completed receive turn's frames (decompressed payloads).
  Stream<List<Uint8List>> get turns => _framesController.stream;

  /// Open the socket (through the SAProuter route, when the system names
  /// one), negotiate SNC when configured, and log on. On ANY failure the
  /// socket, its listener and the deframer are torn down before the error
  /// propagates (the server-side logon dies with the socket) and the
  /// password reference is dropped.
  Future<void> connect({Duration timeout = const Duration(seconds: 10)}) =>
      _exclusive('the logon', () => _connect(timeout));

  Future<void> _connect(Duration timeout) async {
    if (state == SessionState.closed) throw SessionClosedError();
    state = SessionState.connecting;
    try {
      final route = parseRouteString(system.routerString);
      final first = route.isEmpty ? null : route.first;
      // the first hop's /S/ is a port number or an SAP service name
      // (sapdp00, sapgw00 …): resolved here, or refused with the reason
      final port = first == null ? system.port : resolveServicePort(first.port);
      _sock = await Socket.connect(first?.host ?? system.host, port,
          timeout: timeout)
        ..setOption(SocketOption.tcpNoDelay, true);
      _lastWire = DateTime.now();
      _sockSub = _sock!.listen((data) {
        _lastWire = DateTime.now();
        // NI_PING is answered the moment it arrives, also while the session
        // sits idle between actions: the real GUI's reader thread pongs at
        // once (a recorded session srv[104] / [105] -> gui[77] / [78]);
        // a ping left in the inbox until the next action let the SAProuter
        // tear an idle session down (reference client: idle receive-only read)
        // a fatal NI framing error (a zero-length or oversized announce)
        // ends the logon visibly instead of jamming the stream
        List<Uint8List> payloads;
        try {
          payloads = _deframer.feed(data);
        } on NiProtocolException catch (e) {
          _inbox.addAll(e.framesBefore);
          _sockError ??= e;
          _sock?.destroy();
          _notifyClosed();
          _wakeReader();
          return;
        }
        for (final payload in payloads) {
          if (_isNiPing(payload)) {
            _sock?.add(niPongFrame);
            _trace('NI_PING answered (NI_PONG)');
            continue;
          }
          _inbox.add(payload);
        }
        _wakeReader();
      }, onError: (Object e) {
        _sockError ??= e;
        _wakeReader();
      }, onDone: () {
        if (state == SessionState.closed) return; // our own close
        // an end of conversation no read reached yet is still a log-off
        if (!_bootstrapping &&
            _sncCtx == null &&
            _inbox.any(modeControlEndsConversation)) {
          _endOfConversation();
          _wakeReader();
          return;
        }
        _sockError ??= StateError(_peerClosedMessage());
        _notifyClosed();
        _wakeReader();
      });
      if (route.isNotEmpty) {
        await _openRoute(
            [...route, RouteHop(system.host, system.port.toString())]);
      }
      if (snc != null) {
        await _sncNegotiate();
      }
      state = SessionState.loggingIn;
      await _bootstrapGuarded();
      state = SessionState.ready;
    } catch (e) {
      if (state != SessionState.closed) state = SessionState.failed;
      lastError = e.toString();
      _password = null;
      await _dropTransport();
      rethrow;
    }
  }

  /// Tear the transport down: the listener, the socket (destroyed — no
  /// half-open logon left on the server), the deframer's buffered bytes
  /// and the undelivered inbox.
  Future<void> _dropTransport() async {
    final sub = _sockSub;
    final sock = _sock;
    _sockSub = null;
    _sock = null;
    _sncCtx = null;
    try {
      await sub?.cancel();
    } catch (_) {}
    sock?.destroy();
    _deframer.reset();
    _inbox.clear();
  }

  // --- transport -----------------------------------------------------------

  /// Ask the SAProuter we are connected to for a route through [hops]; on
  /// NI_PONG the socket carries plain NI traffic to the target from here on.
  Future<void> _openRoute(List<RouteHop> hops) async {
    _sock!.add(niFrame(buildRouteRequest(hops)));
    await _sock!.flush();
    final replies = await _recvRaw();
    checkRouteReply(replies.first);
  }


  /// The SNC handshake: INIT_REQ carrying the Kerberos AP-REQ, the server's
  /// INIT/ACCEPT reply completes the context, then every DIAG frame rides
  /// wrapped (DATA_MIC / DATA_WRAP).
  Future<void> _sncNegotiate() async {
    final ctx = SncContext(snc!);
    final token = await ctx.initiate();
    final initReq = SncFrame(
      frameType: sncInitReq,
      mechId: snc!.mechId,
      token: token,
      data: Uint8List(0),
    ).serialize();
    _sock!.add(niFrame(initReq));
    await _sock!.flush();
    // read the server's reply frames until the context completes
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (ctx.state != SncState.established &&
        DateTime.now().isBefore(deadline)) {
      final payloads = await _recvRaw();
      for (final payload in payloads) {
        if (payload.length < sncBaseHeaderLen) continue;
        final f = SncFrame.parse(payload);
        if (f == null) continue;
        if (f.frameType == sncInit || f.frameType == sncAccept) {
          final next = ctx.accept(f.token);
          if (next.isNotEmpty) {
            _sock!.add(niFrame(SncFrame(
              frameType: f.frameType == sncInit ? sncInitAck : sncAcceptAck,
              mechId: snc!.mechId,
              token: next,
              data: Uint8List(0),
            ).serialize()));
            await _sock!.flush();
          }
        } else if (f.frameType == sncAcceptFailed || f.frameType == sncRejected) {
          throw StateError('SNC rejected: ${ctx.error ?? 'frame ${f.frameType}'}');
        }
      }
    }
    if (ctx.state != SncState.established) {
      throw StateError('SNC negotiation did not complete');
    }
    _sncCtx = ctx;
  }

  /// [payload] unwrapped by [ctx]; null = no DIAG frame to read (a
  /// non-data SNC frame). A frame that FAILS the context ([SncState.failed]:
  /// its integrity check) ends the logon now with [SncContext.error] —
  /// [SncFailedError] thrown, [closed] fired with it, the socket destroyed.
  Uint8List? _sncUnwrap(SncContext ctx, Uint8List payload) {
    final plain = ctx.unwrapFrame(payload);
    if (plain != null || ctx.state != SncState.failed) return plain;
    final e = SncFailedError(ctx.error ?? 'the SNC context failed');
    _trace(e.message);
    _sockError ??= e;
    if (state != SessionState.closed) state = SessionState.failed;
    lastError = e.toString();
    if (!closedByPeer) {
      closedByPeer = true; // the onDone of the socket destroyed below
      if (!_closedController.isClosed) _closedController.add(e.message);
    }
    _sock?.destroy();
    _wakeReader();
    throw e;
  }

  /// Test hook: run the session over an established SNC context [ctx]
  /// (built with [SncContext.sncForTest]) without a KDC handshake.
  void sncForTest(SncContext ctx) => _sncCtx = ctx;

  void _wakeReader() {
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  /// The next NI payload off the socket, waiting until [deadline].
  Future<Uint8List> _nextPayload(DateTime deadline) async {
    // a [close] ends every read at once, buffered frames or not
    if (state == SessionState.closed) throw SessionClosedError();
    while (_inbox.isEmpty) {
      if (_sockError != null) throw _sockError!;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw TimeoutException('no reply from server');
      }
      _wake = Completer<void>();
      await _wake!.future.timeout(left, onTimeout: () {});
      if (state == SessionState.closed) throw SessionClosedError();
    }
    return _inbox.removeFirst();
  }

  /// Raw NI payloads: the next one plus whatever else is already buffered
  /// (used by the SNC handshake and the SAProuter route request).
  Future<List<Uint8List>> _recvRaw() async {
    if (_sock == null) throw StateError('session not connected');
    final first = await _nextPayload(
        DateTime.now().add(const Duration(seconds: 5)));
    final out = [first, ..._inbox];
    _inbox.clear();
    return out;
  }

  Future<void> _send(Uint8List payload) async {
    // every DIAG frame goes out in the mode of the window it addresses
    // (reference client raw_transport send_msg: SAPDiag(mode=self.mode); a recorded session
    // wingui_session raw gui[6] header `01 …` in window (2))
    if (_w.mode != 0 && payload.length >= diagHeaderLen && payload[0] == 0) {
      payload = Uint8List.fromList(payload)..[0] = _w.mode;
    }
    final body = clientBodyLength(payload);
    // a reply over the kernel's request buffer goes out as the real GUI's
    // sid-4 request stream (sap_session_request_stream.dart)
    if (body > kernelRequestBodyMax && await _sendRequestStream(payload)) {
      return;
    }
    if (payload.length > diagHeaderLen &&
        payload[7] == 1 &&
        body > kernelRequestBodyMax) {
      _oversizeSent = 'a $body-B client frame exceeded the kernel\'s '
          '$kernelRequestBodyMax-B request buffer (ThUncompressReq refuses it)';
      _trace('WARNING $_oversizeSent');
    }
    await _sendWire(payload);
  }

  /// [payload] onto the wire as it is (offline: into [sentFrames]).
  Future<void> _sendWire(Uint8List payload) async {
    if (offlineReplay) {
      sentFrames.add(payload); // offline capture replay (tools/tests)
      return;
    }
    final s = _sock;
    if (s == null) {
      throw state == SessionState.closed
          ? SessionClosedError()
          : StateError('session not connected');
    }
    if (_sncCtx != null) {
      payload = _sncCtx!.wrapFrame(payload);
    }
    s.add(niFrame(payload));
    await s.flush();
    _lastWire = DateTime.now();
  }

  /// Send one client [frame] through the transport path every action's
  /// frames take (the window's mode byte, the request stream of an answer
  /// over the kernel's request buffer, SNC) — tools/tests.
  Future<void> sendClientFrame(Uint8List frame) =>
      _exclusive('a send', () => _send(frame));

  /// Offline capture replay (tools/tests): every client frame lands in
  /// [sentFrames] instead of a socket, and [replayLogin] drives the whole
  /// bootstrap ladder over an already-captured server stream.
  bool offlineReplay = false;

  /// The client frames an offline replay sent, in order (raw DIAG payloads).
  final List<Uint8List> sentFrames = [];

  /// Typed values not yet sent and the screen they were typed on
  /// (sap_session_fields.dart).
  List<StagedField> get _staged => _w.staged;
  (String?, String?, int)? get _stagedScreen => _w.stagedScreen;
  set _stagedScreen((String?, String?, int)? v) => _w.stagedScreen = v;

  /// Drive the login bootstrap over [serverFrames] with no socket: the two
  /// fixture frames go out into [sentFrames], the turns are read from the
  /// fed stream (everything pre-buffered; the recv loops consume at their
  /// own pace and simply idle out at the end of the stream).
  Future<void> replayLogin(List<Uint8List> serverFrames) =>
      _exclusive('the logon', () async {
        if (_sock != null) throw StateError('replayLogin needs no socket');
        offlineReplay = true;
        _inbox.addAll(serverFrames);
        await _bootstrapGuarded();
      });

  /// Offline capture replay (tools/tests): queue [serverFrames] as if the
  /// socket had delivered them, so a later action ([okcode], [press], …)
  /// reads its turns from the capture — the whole launch exchange (the
  /// server's OLE query, our answer, the paint) replays without a logon.
  void feedFrames(List<Uint8List> serverFrames) {
    if (!offlineReplay) throw StateError('feedFrames needs replayLogin first');
    _inbox.addAll(serverFrames);
    _wakeReader();
  }

  /// Receive until the server's turn ends (a paint or a mode-control frame).
  /// On timeout, frames already read are still folded (never dropped) before
  /// the exception propagates.
  Future<List<Uint8List>> recvTurn(
          {Duration timeout = const Duration(seconds: 30)}) =>
      _exclusive('a receive', () => _recvTurn(timeout));

  Future<List<Uint8List>> _recvTurn(Duration timeout) async {
    if (state == SessionState.closed) throw SessionClosedError();
    if (_sock == null && !offlineReplay) {
      throw StateError('session not connected');
    }
    final deadline = DateTime.now().add(timeout);
    final out = <Uint8List>[];
    try {
      while (true) {
        final payload = await _nextPayload(deadline);
        // NI_PING first: its 8 bytes (`NI_PING\0`, 0x49 has the EOP bit)
        // read as a mode-control frame and went unanswered
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
        _noteServerError(frame);
        // a DIAG mode-management frame (a window's turn end / close / the
        // end of the conversation — sap_session_windows.dart): classified,
        // kept in the turn, and it ends it
        if (isModeControlFrame(frame)) {
          _noteModeControl(frame);
          _modes.frameWindow[frame] = _modes.live;
          out.add(frame);
          if (modeControlEndsTurn(frame)) break;
          continue;
        }
        // the window this frame belongs to (null: parked on another one)
        final win = _routeFrame(payload, frame);
        if (win == null) {
          if (_turnComplete(payload)) break;
          continue;
        }
        // a completed stream-form paint follows its carrier as a plain
        // frame of its own (stream_paint.dart): the screen readers fold it
        final mats = _inWindow(win, () => _streamPaints.materialize([frame]));
        for (final m in mats) {
          _modes.frameWindow[m] = win;
        }
        _noteCarrierTitles(win, mats); // the stream paint's 16/12/10
        out.addAll(mats);
        if (_turnComplete(payload)) break;
      }
    } on TimeoutException catch (e) {
      if (out.isEmpty) rethrow;
      // the part that arrived is folded (never dropped) — and the caller
      // is TOLD the turn is incomplete, with the frames
      _foldTurn(out);
      _emitTurn(out);
      partialTurnTimeouts++;
      _trace('turn timed out after ${out.length} frame(s): folded partial');
      throw PartialTurnTimeout(out, e.duration);
    }
    _foldTurn(out);
    _emitTurn(out);
    return out;
  }

  void _emitTurn(List<Uint8List> frames) {
    if (!_framesController.isClosed) _framesController.add(frames);
  }

  /// Fold a turn into the window(s) its frames were routed to.
  void _foldTurn(List<Uint8List> out) {
    for (final (win, run) in _runsByWindow(out)) {
      _inWindow(win, () {
        _fold(run);
        _bindTree();
      });
    }
    _notifyWindows();
  }

  bool _isNiPing(Uint8List payload) {
    if (payload.length < 8) return false;
    for (var i = 0; i < 8; i++) {
      if (payload[i] != niPing[i]) return false;
    }
    return true;
  }

  bool _turnComplete(Uint8List payload) {
    if (payload.length < diagHeaderLen) return false;
    final dec = decompressFrame(payload);
    if (dec == null) return true;
    if (dec.header.errNo != 0) return true;
    final walk = dec.walk;
    // a paint ends with the item list ending in EOM after DyntAtom content,
    // or the frame carries no EOM at all (system frames) — treat any frame
    // carrying DYNT atoms or ST_R3INFO paint items as a turn end
    for (final it in walk.items) {
      if (it.isAppl && (it.id == applStR3Info || it.id == applDynt)) {
        return true;
      }
      if (it.isEom) return true;
    }
    return false;
  }

  void _fold(List<Uint8List> frames) {
    // header-only frames (the 8-byte `00 0c …` no-op that ends the server's
    // turn after a stream-form paint, a recorded session
    // srv[12]) carry no items: folded alone, they read as an empty repaint
    // and wiped the fields the paint just delivered
    if (frames.every((f) => f.length <= diagHeaderLen)) return;
    _observeIModes(frames); // a delIMode kills its controls first
    _ingestTrees(frames);
    final before = screen?.program;
    final identityBefore = screen == null ? null : _screenIdentity(screen!);
    final fold = foldWindows(baseScreen, screen, frames);
    screen = fold.active;
    if (screen?.program != null && screen?.program != before) {
      // the step the new screen generation began at: the action that
      // opened it, not the paint that named it (reference client _prog_since_step)
      _progSinceStep = _actionStartStep ?? clockStep;
      // the new program's own creation wave was folded under the program
      // before it (the PBO flush precedes the paint that names it): it is
      // this program's (reference client ea_facts.retag_generation, run from
      // raw_transport._observe_received with the D2 `since`)
      if (before != null && _actionStartStep != null) {
        _layoutState.registry
            .retag(before, screen!.program!, since: _progSinceStep!);
      }
    }
    _mirrorAreaPairs(frames);
    baseScreen = fold.coveredBase ?? (screen!.modalLevel == 0 ? screen : baseScreen);
    _noteGenerations();
    // mirror geometry into the action context
    for (final f in frames) {
      // a materialized stream paint nests the paint's own (stale) step
      if (isStreamCarrier(f)) continue;
      final dec = decompressFrame(f);
      if (dec == null) continue;
      for (final it in dec.walk.items) {
        if (it.isAppl && it.id == 4 && it.sid == 38 && it.value.length >= 4) {
          step = it.value.buffer
              .asByteData(it.value.offsetInBytes, 4)
              .getUint32(0);
          _noteClock(f);
        }
      }
    }
    // a 16/9/18 naming a CFW DIALOG box (SAPGUI.DIALOGCTRL.1 — the F1
    // Performance Assistant) is no window control focus: the real GUI's
    // next round keeps the dynpro cursor (a recorded session srv[134]
    // `16/9/18 "118"` -> gui[119] `%_GC 124 1`: OK 0x05 + the 16/9/11) —
    // keyed on the creation class, never the program
    final focusBefore = ctx.paintedFocus;
    // a torn-down shell is no focus either — one destroyed in this very turn
    // too (the responder records the turn's control facts after this fold)
    final tornDown = shellsTornDownIn(frames);
    mirrorPaintGeometry(ctx, frames,
        isDialogShell: isCfwDialogShell,
        isDeadShell: (s) =>
            tornDown.contains(s) || _ea.destroyedControls.contains(s),
        screen: screen == null ? null : _screenIdentity(screen!));
    // a cursor belongs to its screen: a paint of ANOTHER program / dynpro /
    // window level that declares no focus of its own drops the client's
    // (the reference client's imode_scope cursor reset on a screen change; a
    // focus-less repaint of the SAME screen keeps it, text_html gui[119])
    if (identityBefore != null &&
        screen != null &&
        _screenIdentity(screen!) != identityBefore &&
        identical(ctx.paintedFocus, focusBefore)) {
      ctx.paintedFocus = null;
    }
    ctx.step = step;
    // staged values never outlive their screen: a dynpro paint or another
    // program / dynpro / window level drops them
    final m = screen;
    if (_staged.isNotEmpty &&
        (m == null ||
            _screenIdentity(m) != _stagedScreen ||
            framesPaintDynpro(frames))) {
      _dropStaged('the screen was repainted');
    }
    // so do typed list cells: every list (SAPMSSY0/0120 hosts them all)
    // repaints its runs
    if (_w.stagedListCells.isNotEmpty &&
        (m == null ||
            _screenIdentity(m) != _w.listCellScreen ||
            framesPaintDynpro(frames))) {
      _trace('staged list cells dropped: ${_w.stagedListCells}');
      _w.stagedListCells.clear();
      _w.listCellScreen = null;
    }
    _foldGrids(frames);
    _foldCharts(frames);
    _foldNetPlans(frames);
    _foldCanvases(frames);
    _foldEditors(frames);
  }

  // --- bootstrap ladder ------------------------------------------------------

  /// One line per logon step / action turn, for diagnosing a handshake
  /// that diverges — the newest [traceCapacity] lines (a ring: a long
  /// session no longer grows it without bound).
  final List<String> traceLog = TraceRing(traceCapacity);

  /// How many lines [traceLog] keeps.
  static const int traceCapacity = 2000;

  /// Where trace lines go besides [traceLog]. By default they are printed
  /// (`[diag] …`) in debug / JIT runs and NOT in a product (release)
  /// build: a line names systems, users and server messages, and a
  /// release `print` lands in logcat / NSLog. Null = [traceLog] only.
  static void Function(String line)? tracePrinter =
      _productBuild ? null : _printTrace;

  static const bool _productBuild = bool.fromEnvironment('dart.vm.product');

  static void _printTrace(String line) => print('[diag] $line');

  void _trace(String what) {
    final m = screen;
    final line = '$what: tcode=${m?.tcode} program=${m?.program} '
        'modal=${m?.modalLevel} base=${baseScreen?.program} '
        'msg(${m?.messageSeverity})="${m?.message}"';
    traceLog.add(line);
    tracePrinter?.call(line);
  }

  // --- survived failures (audit #13) ------------------------------------------

  /// Owed answers (OLE flush calls) that could not be parsed or built and so
  /// went UNANSWERED — the kernel then waits in OLE_FLUSH_CALL and the next
  /// action times out; that timeout names [lastFailure].
  int answerFailures = 0;

  /// Model folds / ingests that threw (a grid, chart, tree, html, layout …
  /// model may be incomplete). An answer they fed still went out, with the
  /// responder's defaults for what the model would have supplied.
  int ingestFailures = 0;

  /// Receive turns that timed out after part of the turn had arrived (the
  /// part was folded and returned — [PartialTurnTimeout]).
  int partialTurnTimeouts = 0;

  /// The latest answer / ingest failure, `<where>: <error>`.
  String? lastFailure;

  void _noteAnswerFailure(String where, Object e) {
    answerFailures++;
    lastFailure = '$where: $e';
    _trace('ANSWER FAILED — $where: $e');
  }

  void _noteIngestFailure(String where, Object e) {
    ingestFailures++;
    lastFailure = '$where: $e';
    _trace('$where failed: $e');
  }

  /// The side-model ingests whose fold FAILS on a call that does not
  /// parse, in [_driveAutomationIn]'s order: grid, chart, NetPlan, context
  /// menu, editor ([_ingestCanvasCall]'s tracker drops it silently).
  static const List<String> _sideModelsFailingUnparsed = [
    'grid ingest',
    'chart ingest',
    'netplan ingest',
    'context menu ingest',
    'editor ingest',
  ];

  /// [f], with a throw counted as an ingest failure (null returned).
  T? _guarded<T>(String where, T Function() f) {
    try {
      return f();
    } catch (e) {
      _noteIngestFailure(where, e);
      return null;
    }
  }

  /// [_bootstrap] with [_bootstrapping] set: an end of conversation the
  /// logon ladder reads is not a log-off of a logged-on session.
  Future<void> _bootstrapGuarded() async {
    _bootstrapping = true;
    try {
      await _bootstrap();
    } finally {
      _bootstrapping = false;
    }
  }

  bool _bootstrapping = false;

  Future<void> _bootstrap() async {
    final fixture = fixtureFrames;
    if (fixture != null && fixture.length < 2) {
      throw StateError('login fixture too short (need connect + logon frames)');
    }
    // GUI[0]: the connect/capability frame — the WINDOWS GUI's (the kernel
    // refuses the Windows wall/EA envelopes from a non-Windows connect)
    await _send(fixture == null
        ? buildConnectFrame(dialect: GuiDialect.windows, terminal: terminal)
        : windowsConnectFrame(fixture[0]));
    await recvTurn();
    _trace('connect reply');
    // GUI[1]: credential submit
    final password = _password;
    if (password == null) {
      throw StateError('the logon password was already used: a session '
          'logs on once (open a new one)');
    }
    _password = null; // the submit below is its only use
    final Uint8List login;
    if (fixture == null) {
      login = buildLogonFrame(
          client: system.client,
          user: system.user,
          password: password,
          language: system.language,
          screenRows: screenRows,
          screenCols: screenCols,
          window: ctx);
    } else {
      var patched = patchLoginFrame(fixture[1],
          client: system.client,
          user: system.user,
          pw: password,
          language: system.language);
      patched = patchScreenSize(patched, screenRows, screenCols);
      // Windows dialect, LAST (engine ladder order)
      login = patchLoginFrameWindows(patched);
    }
    await _send(login);
    final reply = [...await recvTurn()];
    await _driveAutomation(reply);
    _trace('credentials reply');
    // the turn heuristic can end on an early SAPMSYST frame, leaving the
    // multi-logon popup for the next turn — keep reading while we are still
    // on the logon program and have seen neither a wall nor an error.
    // EVERY consumed turn must also drive the automation queue: the turns
    // here can be the RFC chunk train of the Easy Access setup (sid-4
    // chunks pacing on empty receipts, capture's gui[3..8] shape) — read
    // without answering, the server waits forever for the next ack and
    // everything downstream (wall, Easy Access paint) stalls into timeouts.
    var contTurns = 0;
    while (!readWall(reply).isWall &&
        (screen?.isKernelLogon ?? false) &&
        (screen?.messageSeverity ?? 0) < 3 &&
        contTurns < 60) {
      final List<Uint8List> got;
      final bool partial;
      try {
        (got, partial) = await _recvTurnPart(const Duration(seconds: 5));
      } on TimeoutException {
        break;
      }
      reply.addAll(got);
      contTurns++;
      _trace('credentials reply (cont.)');
      await _driveAutomation(got);
      if (partial) break;
    }
    // still on the logon dynpro with an error/warning: SAP refused the logon
    // (wrong password, locked user, bad client…) — say so instead of
    // replaying the Easy Access answers into a silent server
    final m = screen;
    if (m != null && m.isKernelLogonTcode && m.messageSeverity >= 3) {
      throw StateError('logon refused: ${m.message}');
    }

    // multi-logon wall — answered wherever in the bootstrap it appears
    await _answerWallIfPresent(reply);

    // Easy Access: answer the LIVE automation queue — sid-4 chunk acks and
    // every OLE_FLUSH_CALL through the responder (the engine's general
    // path; the replayed canned answers only fit the recorded system).
    // Settling requires a paint OFF the logon program: the multi-logon wall
    // paints as SAPMSYST across SPLIT turns (the header/title frame first,
    // the radio atoms frame after — the turn heuristic ends on the
    // ST_R3INFO-carrying header), so breaking on "program != null" alone
    // leaves the wall unread and unanswered (the stuck empty "Info licence
    // …" screen with nothing to press).
    final wallScan = <Uint8List>[]; // reunites the wall's split turns
    bool settled() => screen?.program != null && !screen!.isKernelLogon;
    var idle = 0;
    for (var i = 0; i < 120 && !settled(); i++) {
      final List<Uint8List> got;
      final bool partial;
      try {
        (got, partial) = await _recvTurnPart(const Duration(seconds: 5));
      } on TimeoutException {
        idle++;
        if (idle >= 3) break;
        continue;
      }
      // a partial turn is answered like any other, and counts as idle
      idle = partial ? idle + 1 : 0;
      wallScan.addAll(got);
      if (wallScan.length > 16) {
        wallScan.removeRange(0, wallScan.length - 16);
      }
      await _answerWallIfPresent(wallScan);
      // answer the turn's queue FIRST: the turn carrying the Easy Access
      // paint can also carry its last OLE queue (after a multi-logon wall
      // the 88-verb flush and the paint arrive together); breaking on the
      // paint before answering left the server waiting inside
      // OLE_FLUSH_CALL and every later action timed out
      final sent = await _driveAutomation(got);
      _trace('automation turn $i (sent $sent)');
      if (settled() && sent == 0) break;
    }
    await _drainPending(); // fold paint continuations still buffered
    if (screen?.program == null) {
      throw StateError(
          'login did not settle: no Easy Access paint after the automation '
          'queue (see trace log)');
    }
  }

  /// Fold whatever frames are still buffered, answering walls and driving
  /// the automation queue. The turn heuristic can end a turn MID-PAINT (on
  /// a popup's header frame), leaving the atoms frame for the next read —
  /// unread, it renders as an empty screen; and unread automation chunks
  /// stall the server (it paces the stream on our receipts), so every
  /// drained turn is also acked.
  Future<void> _drainPending() async {
    for (var i = 0; i < 40 && _inbox.isNotEmpty; i++) {
      final List<Uint8List> got;
      final bool partial;
      try {
        (got, partial) = await _recvTurnPart(const Duration(seconds: 2));
      } on TimeoutException {
        break;
      }
      await _answerWallIfPresent(got);
      await _driveAutomation(got); // acks elicit more frames — keep pumping
      if (partial) break;
    }
  }

  /// [recvTurn], except that a timeout ending a PARTIAL turn returns the
  /// part (already folded and on [turns]) with `true`, for the caller to
  /// answer like any turn — its owed answers must not be lost with it. A
  /// timeout with nothing read still throws.
  Future<(List<Uint8List>, bool)> _recvTurnPart(Duration timeout) async {
    try {
      return (await recvTurn(timeout: timeout), false);
    } on PartialTurnTimeout catch (e) {
      return (e.frames, true);
    }
  }

  /// Answer the automation items a turn carried, PER FRAME (the chunked-call
  /// choreography): one empty 16/8/4 receipt per sid-4 chunk stamped with the
  /// CHUNK frame's own step, and the completed call — assembled across its
  /// chunks when the kernel streams it (the 740 logon full-build queue: a
  /// ~30 kB head + continuation + sid-0 closer; unanswered or wrongly
  /// stamped, it is the SAPLOLEA SYSTEM_FAILURE logon dump) — answered
  /// through the responder with the closing frame's step and the DOI model
  /// folded in.
  /// Returns the number of frames sent (receipts + answers).
  Future<int> _driveAutomation(List<Uint8List> frames) async {
    // each window's frames are answered in THAT window — its mode byte, its
    // own step, its controls (a recorded session raw gui[6]/[7]: the
    // mode-1 creation wave answered in mode 1 at steps 1 / 7 while mode 0
    // stood at 15; sap_session_windows.dart)
    var sent = 0;
    for (final (win, run) in _runsByWindow(frames)) {
      _modes.w = win;
      try {
        sent += await _driveAutomationIn(run);
      } finally {
        _modes.w = _modes.live;
      }
    }
    return sent;
  }

  Future<int> _driveAutomationIn(List<Uint8List> frames) async {
    var sent = 0;
    for (final f in frames) {
      // a materialized stream paint is for the screen parsers only (the
      // reference client never feeds it to the automation path: its glued stream is
      // an opaque 16/8/4 / 16/8/6 value of the RAW carrier, which already
      // got its receipt); its nested step is the paint's, 3 behind the
      // carrier's (reference client 727e286: me21n_collapsed srv[10] 38 -> 35)
      if (isStreamCarrier(f)) continue;
      _ea.dpCache.ingestFrame(f);
      recordControlFactsFromFrame(_ea, f);
      final folded = foldAutomationFrame(f, _autoStream, step);
      for (final chunkStep in folded.receiptSteps) {
        // the empty sid-4 receipt paces the next chunk (prd gui_002/003)
        await _send(clientFrame(
            [stepItem(chunkStep), buildApplItem(8, 4, Uint8List(0)), eomBytes],
            compress: false));
        sent++;
      }
      for (final (value, closingStep) in folded.calls) {
        // keyed with the closing step: the same queue on a later screen is
        // a new call and must be answered again (a skipped answer hangs it)
        // (an exact key: a collision would skip an owed answer)
        if (!String.fromCharCodes(value).contains('OLE_FLUSH_CALL')) continue;
        final key = AnsweredCalls.keyOf('flush', closingStep, value);
        if (!_answeredFlushes.add(key)) continue;
        // ONE parse of the call feeds every side model and the answer
        // (audit #8: it was parsed once per model, ~8x, each parse
        // re-inflating every cell); the models read nothing the answer
        // dialect changes (the _RESULT types). A call that does not parse
        // is NOT re-parsed by every model (each one's own parse failed on
        // it again: 7 parses of a hostile call): each model's failure is
        // counted as its failing fold counted it, in the same order.
        FlushCall? parsed;
        Object? parseError;
        try {
          parsed = parseFlushCall(value, dialect: answerDialect);
        } catch (e) {
          parseError = e;
        }
        if (parsed == null) {
          for (final where in _sideModelsFailingUnparsed) {
            _noteIngestFailure(where, parseError!);
          }
        } else {
          _ingestGridCall(value, parsed);
          _ingestChartCall(value, parsed);
          _ingestNetPlanCall(value, parsed);
          _ingestCanvasCall(value, parsed);
          _ingestContextMenuCall(value, parsed);
          _ingestEditorCall(value, parsed);
          _ingestPictureCall(parsed);
        }
        // the call is OWED an answer (the kernel blocks in OLE_FLUSH_CALL):
        // a model fold that throws degrades the answer to the responder's
        // defaults for what that model would have supplied — never skips
        // it; only a call that cannot be parsed or answered at all goes
        // unanswered, and that is counted and kept ([answerFailures])
        if (parsed == null) {
          _noteAnswerFailure(
              'flush call at step $closingStep unparseable, not answered',
              parseError!);
          continue;
        }
        final call = parsed;
        _guarded('flush sinks', () {
          _propertySinks.addAll(propertySinksOf(call));
          _loadedSinks.addAll(loadedObjectSinksOf(call));
          _ea.noteDpBindings(call);
        });
        _guarded('header names', () => _noteHeaderNames(call, value));
        // registry stamps run on the home clock (a relayed frame's
        // own step is another system's); the answer echoes closingStep
        final clock = _clockOf(f, closingStep);
        _guarded('layout fold', () => _foldLayoutCall(call, clock));
        _guarded('html fold', () => _foldHtmlCall(value, call, clock));
        _guarded('toolbar fold', () => _foldToolbarCall(value, call));
        _guarded('cfw field fold', () => _foldCfwFieldCall(value, call));
        _guarded('value help fold', () => _foldValueHelpCall(call, value));
        final calendarAnswers =
            _guarded('calendar fold', () => _foldCalendarCall(call, value));
        // a value help's result set into a grid cell: adopted in THIS
        // answer (sap_session_grid_edit.dart)
        final adoption =
            _guarded('grid delta adoption', () => _gridDeltaAdoption(call));
        final propStore = {
          ...?_guarded('doi fold', () => doiObserveCall(_ea, _doi, call)),
          ...?_guarded('editor props', () => _editorPropAnswers(call)),
          ...?_guarded('cfw field props', () => _cfwFieldPropAnswers(call)),
          ...?_guarded(
              'tree header props', () => _treeHeaderPropAnswers(call)),
          ...?adoption?.$2,
          ...?calendarAnswers,
        };
        _ea.step = closingStep; // the answer stamps the closing frame's step
        final List<Uint8List>? items;
        try {
          items = buildAnswer(_ea, call,
              propStore: propStore, exportXml: adoption?.$1);
        } catch (e) {
          _noteAnswerFailure(
              'flush answer at step $closingStep '
              '(${call.verbs.length} verbs) could not be built, not sent',
              e);
          continue;
        }
        _guarded('grid rows', () => _noteGridRows(value, call));
        if (items != null) {
          await _send(clientFrame(items));
          sent++;
          _guarded('doi answer', () => doiNoteAnswer(_doi, call));
          _trace('flush answered (${call.verbs.length} verbs, '
              'step $closingStep)');
        }
      }
      // a front-end RFC (`CALL FUNCTION … DESTINATION 'SAPGUI'`): a
      // synchronous one is answered in this window at the frame's step —
      // unanswered, the window hangs (a recorded session raw srv[40] ->
      // gui[28]); the sid-6 progress tick is read, never answered
      for (final (value, at, sid) in folded.frontendCalls) {
        final a = _answerFrontendRfc(value, at, sid);
        if (a != null) {
          await _send(a);
          sent++;
        }
      }
      // a NetPlan graph's stream read-back pull: the armed node-click
      // command, else the empty stream (unanswered, the server waits)
      for (final a in _netPlans.answerPullsOf(f, step)) {
        await _send(a);
        sent++;
      }
      // every other DP_GET pull (a control-property read-back, …)
      for (final a in _answerClientTablePulls(f)) {
        await _send(a);
        sent++;
      }
    }
    // a grid wave in the same turn as its screen's paint (already folded)
    if (_gridsPending.isNotEmpty && _paintsProgram(frames)) _bindPendingGrids();
    if (_chartsPending.isNotEmpty && _paintsProgram(frames)) {
      _bindPendingCharts();
    }
    _foldNetPlans(frames);
    _foldCanvases(frames); // a canvas wave in the same turn as its paint
    _foldEditors(frames);
    return sent;
  }

  /// One user action after the logon: send [items], then read the server's
  /// turns until the screen paints with nothing left to answer. A new screen
  /// built with controls (SM04's grid, …) first sends its OLE queue and
  /// waits for the answer before it paints — read without answering, both
  /// sides wait into a timeout. Every turn therefore drives the responder
  /// (chunk receipts, flush answers), exactly as the logon ladder does.
  Future<List<Uint8List>> _act(List<Uint8List> items,
          {bool controlEvent = false,
          bool dialectReady = false,
          bool consumesStaged = false}) =>
      _exclusive(
          'action',
          () => _actLocked(items,
              controlEvent: controlEvent,
              dialectReady: dialectReady,
              consumesStaged: consumesStaged));

  Future<List<Uint8List>> _actLocked(List<Uint8List> items,
      {bool controlEvent = false,
      bool dialectReady = false,
      bool consumesStaged = false}) async {
    // a control event addressed to a shell of another live internal mode
    // goes nowhere: the real GUI cannot fire it (its GuiCtlMgr holds only
    // the current imode's shells — reference client control_target.shell_is_current)
    final target = _controlEventShell(items);
    if (target != null && shellInOtherIMode(target)) {
      _modes.pendingCommand = null;
      throw StateError(
        'control $target was created in another internal mode '
        '(${_layoutState.imodes.imodeOf(target)?.substring(0, 8) ?? '?'}…, '
        'current ${currentIMode?.substring(0, 8)}…): it is not on this '
        'screen',
      );
    }
    // the window command this action carries, if any (/o…, /i…)
    final modeCommand = _modes.pendingCommand;
    _modes
      ..pendingCommand = null
      ..close = null; // a close read outside an action owes nothing now
    if (consumesStaged) {
      // the staged values ride these items (built from them already)
      _staged.clear();
      _stagedScreen = null;
    } else if (_staged.isNotEmpty) {
      // an action no field round carries: the typed values go first as
      // ONE Enter round (reference client deferred_fill), never lost, never late
      _trace('staged fields sent first as an Enter round: $_staged');
      // table-control cells go in their control's plane, never as atoms
      if (_stagedHasCells) await _sendStagedCellsFirst();
      if (_staged.isNotEmpty) await _act(_stagedRound(), consumesStaged: true);
    }
    // the action builders speak the fixture's Java spelling; a Windows
    // connection needs the Windows one or the server never paints
    // ([dialectReady]: the items are already in the connection's dialect)
    final respell = answerDialect == GuiDialect.windows && !dialectReady;
    // a staged grid click rides this frame (sap_session_grid.dart): the
    // control state a Windows key round's OK mode and item 17 depend on
    final staged = _pendingGridXml();
    var built = respell
        ? windowsActionItems(items,
            controlEvent: controlEvent,
            // the event shell's custom-control path, else no 16/15/1
            controlSourcePath: controlEvent && target != null
                ? _hostedSourcePath(target)
                : null,
            ctx: ctx,
            controlState: staged != null,
            firstRound: _w.firstRoundOwed,
            graphicsFocus: !controlEvent && _graphicsFocused())
        : items;
    // the first round in a window born after the logon carries the window
    // atoms (sap_session_windows.dart, frontend_profile.dart)
    built = _withFirstRound(built);
    built = _withAfterPopup(built);
    if (staged != null) built = withGridStateXml(built, staged.$1, staged.$2);
    // the Java GUI's OK mode = the acked paint's | the focus half the
    // round finally names (frontend_profile.withJavaOkMode); a Windows
    // round's builders decided it already (windowsOkMode)
    if (answerDialect == GuiDialect.java) built = withJavaOkMode(built, ctx);
    noteClientFocus(ctx, built);
    _noteContextMenuRound(); // another action closes an open context menu
    final frame = clientFrame(built);
    // the generation this action opens begins at its send — on the HOME
    // clock: an action sent on a relayed remote-logon paint (wire step 1)
    // is not "step 1" of this logon (reference client raw_transport send_msg, D2)
    _actionStartStep = clockStep;
    _modes.actionCommand = modeCommand;
    final failuresBefore = answerFailures;
    try {
      _trace('action send ${_itemIds(frame)}');
      await _send(frame);
      if (staged != null) _gridStateFlushed();
      final all = <Uint8List>[];
      for (var i = 0; i < 120; i++) {
        // an offline replay has every frame of the exchange queued already:
        // nothing left means the server's part is done (no idle wait)
        if (offlineReplay && all.isNotEmpty && _inbox.isEmpty) break;
        List<Uint8List> got;
        PartialTurnTimeout? part;
        try {
          got = await recvTurn(
              timeout: Duration(seconds: all.isEmpty ? 30 : 10));
        } on PartialTurnTimeout catch (e) {
          // the turn's part arrived, folded: its owed answers go out below
          part = e;
          got = e.frames;
        } on TimeoutException catch (e) {
          _throwIfAnswerOwed(failuresBefore, e);
          if (all.isNotEmpty) break; // the server finished; nothing more came
          rethrow;
        }
        final firstTurn = all.isEmpty;
        all.addAll(got);
        final sent = await _driveAutomation(got);
        final paints = _paintsScreen(got);
        _trace('action turn $i: ${got.length} frames, sent $sent, '
            'paints $paints${part == null ? '' : ' (partial: timed out)'} '
            '${[for (final f in got) _itemIds(f)].join(' || ')}');
        // the server logged the session off (EOC): the action is done,
        // nothing more is read or sent (sap_session_windows.dart)
        if (loggedOff) break;
        // the active window closed in this turn (sap_session_windows.dart):
        // the session stands on the surviving window; a resume round's
        // reply is read here, else whatever is still buffered
        final close = _modes.close;
        if (close != null) {
          _modes.close = null;
          all.addAll(await _settleModeClose(close));
          if (_inbox.isEmpty) break;
          continue;
        }
        if (part != null && sent == 0) {
          // nothing more is coming: a first turn cut short is the action's
          // failure, a later one ends it as before
          _throwIfAnswerOwed(failuresBefore, part);
          if (firstTurn) throw part;
          break;
        }
        if (sent == 0 && paints) break;
      }
      if (loggedOff) return all; // no layout round, no drain: it is over
      // the docked layout's own round, if owed — right after the paint,
      // before anything else is read (its reply re-lays the screen out); a
      // wave that painted nothing owes none (reference client raw_settle, 37e6240)
      await _maybeLayoutRound(painted: _paintsScreen(all));
      _splitRelayedWall(all); // a relayed wall is the user's to answer
      await _drainPending();
      final late = _modes.close; // a close the drain read
      if (late != null) {
        _modes.close = null;
        all.addAll(await _settleModeClose(late));
      }
      return all;
    } finally {
      // in-flight state never outlives its action, failed or not: a stale
      // command misattributes the next server-born window
      _modes.actionCommand = null;
    }
  }

  /// The server stopped answering after an owed answer of this action
  /// failed ([answerFailures] above [before]): the timeout names the cause.
  void _throwIfAnswerOwed(int before, TimeoutException e) {
    if (answerFailures <= before) return;
    throw TimeoutException(
        'no reply from server — it is waiting for an answer this session '
        'could not build: $lastFailure',
        e.duration);
  }

  // --- one action at a time ---------------------------------------------------

  static final Object _lockKey = Object();

  /// The tail of the action chain: the next action starts after it.
  Future<void> _actionTail = Future<void>.value();
  int _actionsQueued = 0;

  /// Whether an action (or the logon) is in flight or queued.
  bool get busy => _actionsQueued > 0;

  /// The window sizes [resizeWindow] accepts (cells): a dynpro is at most
  /// 255 columns wide, the SES dims are one byte each.
  static const int minWindowRows = 10, maxWindowRows = 200;
  static const int minWindowCols = 40, maxWindowCols = 255;

  /// The client window is now [rows] x [cols] character cells (clamped to
  /// [minWindowRows]..[maxWindowRows] / [minWindowCols]..[maxWindowCols]):
  /// every later round reports it (16/12/8 pixels in the kernel's cell, the
  /// SES dims, METRICS, SCROLL_INFOS2 — [ActionContext.sizeWindow]). Before
  /// the logon it is the size the logon reports. On a live, idle main
  /// window whose screen depends on the window size it sends the real GUI's
  /// RESIZE round ([windowsResizeRoundItems]) under the action lock and
  /// reads the server's re-laid-out screen; otherwise (a popup, typed values
  /// staged, an action running, a size-independent screen) the geometry
  /// rides the next round, as on the real GUI. Returns whether a round went
  /// out; an unchanged size sends nothing.
  Future<bool> resizeWindow(int rows, int cols) => _resizeWindow(rows, cols);

  /// The user dragged the edge of the left / right docking container
  /// [dock] to [cols] window cells (the units of [regions]). The real
  /// Windows GUI sends nothing at drag time; the drag surfaces as the
  /// `%_GS 0 3` layout round answering the paint it disagrees with
  /// (a recorded session KEY DECODE 1/2: ST04 gui[17]/gui[24], SE80
  /// gui[37], PPOME gui[58] — each one right after the drag, before the
  /// user's next action), carrying the realized area in 16/12/8 and the
  /// dock's realized `300` in CONTROLS; the server then repaints the area
  /// at cols = area px / cell (KEY DECODE 3). So the drag becomes the
  /// session's sash ([dockFraction]: it is also the remembered sash of
  /// later screens), the pane is ours to realize until the server's
  /// repaint moves the painted delta (then that delta is trusted again,
  /// [provisionalDockDelta]), and the round goes out now on an idle,
  /// live main window — else it is owed to the next paint (an action
  /// running, typed values staged, a popup up). Top / bottom docks (`120`)
  /// are not modelled. Returns whether a round went out.
  Future<bool> resizeDock(String dock, double cols) =>
      _resizeDock(dock, cols);

  /// Run [body] as THE session action: actions never interleave on the
  /// inbox (two readers would race for frames and the single wake-up — the
  /// first one hung into its timeout). A call made while another runs —
  /// from outside it — is SERIALIZED: chained behind it, it starts when
  /// that one has finished. A call made from inside it (an action's own
  /// staged round, the bootstrap's turns) runs as part of it.
  Future<T> _exclusive<T>(String what, Future<T> Function() body) {
    if (identical(Zone.current[_lockKey], this)) return body();
    final before = _actionTail;
    final done = Completer<void>();
    _actionTail = done.future;
    _actionsQueued++;
    Future<T> run() async {
      try {
        await before;
        return await body();
      } finally {
        _actionsQueued--;
        done.complete();
      }
    }

    return runZoned(run, zoneValues: {_lockKey: this});
  }

  /// [items] as the round goes out in the live window: the FIRST round
  /// carrying an SES in a window born after the logon takes the window
  /// atoms ([windowsFirstRoundItems]: 16/4/4, 16/4/36, 16/4/40 after the
  /// 16/12/4, else after the SES) — a TRANSPORT rule, whatever round it is
  /// (reference client window_first_round.apply in send_msg, 847ec3a). A frame
  /// without an SES (an RFC / OLE reply, a chunk receipt) is no round and
  /// leaves it owed; a closed window takes its debt with it (a later window
  /// under the same mode byte is a new [_WindowState], born owing). Java:
  /// nothing.
  List<Uint8List> _withFirstRound(List<Uint8List> items) {
    if (answerDialect != GuiDialect.windows || !_w.firstRoundOwed) {
      return items;
    }
    final hasSes = items.any((raw) {
      final w = walkItems(raw).items;
      return w.length == 1 && w.single.type == itemSes;
    });
    if (!hasSes) return items;
    _w.firstRoundOwed = false;
    _trace('[mode] first round in window mode ${_w.mode}: FONTMETRIC + '
        'DISPLAY_SIZE + MAINAREA_SIZE');
    return windowsFirstRoundItems(items, ctx);
  }

  /// [items] as the round goes out after a round sent from inside a popup
  /// with its 16/4/36 window rect: the first main-window round carries
  /// 16/4/36 = the display size ([windowsAfterPopupItems]) — a TRANSPORT
  /// rule like [_withFirstRound], whatever round it is. After a popup round
  /// without a rect (the 1 x 1 control-host popup, [windowsModalWindowRect
  /// Owed]) none: 122 of the Windows corpus' 124 main-window rounds after a
  /// popup round with a rect carry it, a recorded session's 7 after its
  /// rect-less host popups none. A frame without an SES leaves the state as
  /// it is. Java: nothing.
  List<Uint8List> _withAfterPopup(List<Uint8List> items) {
    if (answerDialect != GuiDialect.windows) return items;
    final level = windowsRoundModalLevel(items);
    if (level == null) return items;
    final owed = _w.popupRoundSent && level == 0;
    _w.popupRoundSent = level > 0 &&
        items.any((raw) {
          final w = walkItems(raw).items;
          return w.length == 1 && w.single.isAppl && w.single.id == 4 &&
              w.single.sid == 36;
        });
    if (!owed) return items;
    _trace('[mode] first main-window round after a popup: DISPLAY_SIZE');
    return windowsAfterPopupItems(items, ctx);
  }

  /// The shell a `%_GC <shell> <event>` / `%_GS <shell> <event>` okcode
  /// (16/12/4) among [items] addresses; null for any other action (and for
  /// the `%_GS 0 …` session events, which address no control).
  String? _controlEventShell(List<Uint8List> items) {
    for (final raw in items) {
      for (final it in walkItems(raw).items) {
        if (!it.isAppl || it.id != 12 || it.sid != 4) continue;
        final m = _controlOkcode.firstMatch(wireDecode(it.value));
        if (m != null && m.group(1) != '0') return m.group(1);
      }
    }
    return null;
  }

  /// Whether the paint's control focus (16/9/18) is a SAP Graphics OCX
  /// (NetPlanGraphics / BarChartGraphics, [isSapGraphicsClass]): a bare
  /// key round then goes out OK 0x03 ([windowsActionItems]).
  bool _graphicsFocused() {
    final control = ctx.paintedControlFocus;
    if (control == null) return false;
    return _ea.createdControls
        .any((x) => x.handle == control && isSapGraphicsClass(x.cls));
  }

  /// The container path the 16/15/1 control-event source of a Windows
  /// event on [shell] carries: [shell] (or the CreateControl ancestor
  /// nearest it) was LinkContainer'd into a dynpro CUSTOM-CONTROL area the
  /// paint declares — that area's [ScreenModel.controlPaths] entry, BY NAME
  /// only. Null otherwise (a docked / dialog-hosted control, a link the
  /// paint names no group for): the round then carries NO 16/15/1. Never
  /// "the only custom control on the screen" and never a default `01`
  /// (reference client 534a50c §3, hosted_control_event_source: of the corpus' 581
  /// Windows `%_GC` / `%_GS` rounds 253 carry a 16/15/1 and 252 name a path
  /// equal to a painted custom control of the step-paired paint —
  /// a recorded session gui[36] `01` TREE_CONTAINER,
  /// a recorded session gui[26] `01 02 01`, a recorded session
  /// gui[12] `01 02 01 01`, a recorded session gui[37] `01`
  /// MAIN_CONTAINER; 200 rounds without one go out on a paint that declares
  /// a custom control for some OTHER shell — a recorded session
  /// pick gui[23], a recorded session gui[12], a recorded session
  /// delete_save_realgui gui[35], docked trees).
  List<int>? _hostedSourcePath(String shell) {
    final reg = _layoutState.registry;
    final s = (screen?.modalLevel ?? 0) > 0 ? baseScreen : screen;
    if (s == null || s.controlPaths.isEmpty) return null;
    var sh = shell.trim();
    final seen = <String>{};
    while (seen.add(sh)) {
      for (final e in reg.areaLinks.entries) {
        if (e.value.$1 != sh) continue;
        final area = e.key.trim().toUpperCase();
        for (final g in s.controlPaths.entries) {
          if (g.key.trim().toUpperCase() == area && g.value.isNotEmpty) {
            return g.value;
          }
        }
      }
      final parent = reg.parents[sh];
      if (parent == null) break;
      sh = parent;
    }
    return null;
  }

  /// Item ids of a frame with short values, for the trace.
  String _itemIds(Uint8List frame) {
    final dec = decompressFrame(frame);
    if (dec == null) return 'raw(${frame.length}B)';
    final parts = <String>[
      'err=${dec.header.errNo}',
      if (dec.header.errNo != 0) '"${diagErrorInfo(frame)}"',
    ];
    for (final it in dec.walk.items) {
      final tag = it.isAppl ? '${it.id}/${it.sid}' : (it.isEom ? 'eom' : 't${it.type}');
      final v = it.value;
      // a dynpro value blob (16/9/2 DyntAtom) is never printed: a short one
      // would show a typed value — a password among them (RSYST-BCODE)
      final atoms = it.isAppl && it.id == 9 && (it.sid == 2 || it.sid == 16);
      final txt = v.length <= 24 && !atoms
          ? '=${String.fromCharCodes(v.map((c) => c >= 32 && c < 127 ? c : 46))}'
          : '(${v.length})';
      parts.add('$tag$txt');
    }
    return parts.join(' ');
  }

  bool _paintsScreen(List<Uint8List> frames) {
    for (final f in frames) {
      final dec = decompressFrame(f);
      if (dec == null) continue;
      for (final it in dec.walk.items) {
        if (it.isAppl &&
            ((it.id == applStR3Info && it.sid == 13) || it.id == applDynt)) {
          return true;
        }
      }
    }
    return false;
  }

  /// SAPR3:// sink -> the control property a queue saved into it.
  Map<String, PropertySink> get _propertySinks => _w.propertySinks;

  /// SAPR3 sinks a loaded data object was re-saved under (the F1 help
  /// table — client_table_pull.loadedObjectSinksOf)
  Set<String> get _loadedSinks => _w.loadedSinks;

  /// tree shell -> node keys this session expanded (ExpandedKeys pulls)
  Map<String, List<String>> get _expandedKeys => _w.expandedKeys;

  /// The answers to the SAPLCNDP DP_GET_CLIENT_TABLE pulls [frame]
  /// carries that no specialised tracker owns (NetPlan stream sinks are
  /// answered by [SapNetPlanTracker]): the DOI model's, else a tree's
  /// node-key read-back, else the empty client table the real GUI sends
  /// for a data object it holds nothing in. The pull is synchronous —
  /// unanswered, the server waits forever (the ST04 launch stall at the
  /// nav tree's ExpandedKeys read-back, a recorded session
  /// srv[18] -> gui[10], stamped with the pull frame's own step).
  List<Uint8List> _answerClientTablePulls(Uint8List frame) {
    final dec = decompressFrame(frame);
    if (dec == null) return const [];
    var at = step;
    final out = <Uint8List>[];
    for (final it in dec.walk.items) {
      if (it.isAppl && it.id == 4 && it.sid == 38 && it.value.length >= 4) {
        at = it.value.buffer
            .asByteData(it.value.offsetInBytes, 4)
            .getUint32(0);
      }
      if (!it.isAppl || it.id != 8 || (it.sid != 0 && it.sid != 1)) continue;
      final v = Uint8List.fromList(it.value);
      if (!isClientTablePull(v)) continue;
      final url = clientTablePullUrl(v);
      if (url != null && _netPlans.hasSink(url)) continue;
      // a value-help search's select options (sap_session_value_help.dart)
      final selOpts = url == null ? null : _valueHelpPullAnswer(url, v);
      if (selOpts != null) {
        out.add(clientFrame(
            [stepItem(at), buildApplItem(8, 1, selOpts), eomBytes]));
        continue;
      }
      if (doiDocumentPullVerdict(_doi, v) == null) continue; // refused
      var rfc = doiAnswerPullRfc(_ea, _doi, v) ??
          doiAnswerDocumentPullRfc(_doi, v);
      final sink = rfc != null || url == null
          ? null
          : _propertySinks.remove(url);
      // a column tree's HeaderNames read-back: the table the server
      // assigned it (sap_session_tree.dart _noteHeaderNames) — an empty
      // answer is the ALV tree's GET_FRONTEND_FIELDCATALOG FAILED dump
      final header = sink != null && headerNamesProps.contains(sink.prop)
          ? _headerNamesOf(sink.source)
          : null;
      if (rfc == null && header != null) {
        rfc = headerNamesPullAnswer(
          header,
          windows: answerDialect == GuiDialect.windows,
        );
        _trace('client table pull answered ($url ${sink!.prop} of '
            '${sink.source}, ${header.rows.length} rows, step $at)');
      }
      if (rfc == null) {
        var keys = const <String>[];
        // a tree's node-key read-back: the expansion / selection the user
        // left on the client (sap_session_tree.dart noteTreeExpansion /
        // noteTreeSelection)
        final held = switch (sink?.prop) {
          'ExpandedKeys' => _expandedKeys,
          'SelectionKeys' => _w.selectionKeys,
          _ => null,
        };
        if (sink != null && held != null) {
          final shell = _ea.shellAlias[sink.source] ?? sink.source;
          keys = held[shell] ?? held[sink.source] ?? keys;
          // a node the tree no longer holds is neither open nor selected
          final nodes = trees[shell]?.nodes;
          if (nodes != null && nodes.isNotEmpty) {
            keys = [for (final k in keys) if (nodes.containsKey(k)) k];
          }
        }
        final loaded = sink == null && _loadedSinks.remove(url);
        // an HTML viewer's sapevent POST body (sap_session_html.dart)
        final post = loaded ? _takeHtmlPost() : null;
        rfc = post != null
            ? htmlPostPullAnswer(
                post,
                windows: answerDialect == GuiDialect.windows,
              )
            : loaded
            ? loadedObjectPullAnswer(v)
            : nodeKeyTableAnswer(keys);
        _trace('client table pull answered ($url ${sink?.prop}, '
            '${keys.length} rows, step $at${loaded ? ', loaded object' : ''}'
            '${post != null ? ', html post ${post.length} B' : ''})');
      }
      out.add(
          clientFrame([stepItem(at), buildApplItem(8, 1, rfc), eomBytes]));
    }
    return out;
  }

  /// The front-end RFC requests this logon received (frontend_rfc.dart),
  /// newest last, the sid-6 progress ticks included — what a heavy report
  /// reports (`SAPGUI_PROGRESS_INDICATOR` TEXT / PERCENTAGE) and what the
  /// kernel asked of the front end.
  final List<FrontendCall> frontendRfcLog = [];

  /// This host's name for the front-end RFC descriptor, read once per
  /// process (it was a syscall per answered front-end RFC); '' when the
  /// platform does not tell.
  static final String _localHost = () {
    try {
      return Platform.localHostname;
    } catch (_) {
      return '';
    }
  }();

  /// The client frame answering the front-end RFC [value] (16/8/[sid] of a
  /// frame at step [at]), or null when none is owed: a sid-6 progress tick
  /// is receive-only (a reply is RFCGUI_UNEXPECTED_DATA), a call already
  /// answered is not answered again. The reply rides 16/8/1 at the request
  /// frame's step, in the request's window (raw gui[28]: mode 2 step 1 for
  /// raw srv[40] mode 2 step 1) — [frontendRfcReply]: a bare success for
  /// SAPGUI_PROGRESS_INDICATOR / SAPGUI_SET_PROPERTY / RFC_PING, the RFCSI
  /// for RFC_SYSTEM_INFO, RFC_FUNCTION_NOT_FOUND for every other function.
  Uint8List? _answerFrontendRfc(Uint8List value, int at, int sid) {
    final call = parseFrontendCall(value);
    frontendRfcLog.add(call);
    if (frontendRfcLog.length > 200) frontendRfcLog.removeAt(0);
    final what = 'front-end RFC ${call.fname} from '
        '${call.context['caller']} (sid $sid, step $at)';
    if (!frontendReplyOwed(sid)) {
      _trace('$what "${call.params['TEXT'] ?? ''}": async, no reply');
      return null;
    }
    final key = AnsweredCalls.keyOf('frontend-rfc', at, value);
    if (!_answeredFlushes.add(key)) return null;
    final host = _localHost;
    // the Windows GUI's descriptor names its host (the 0008 token after
    // the 0018 address) and its reply frame ends with two EOM items
    // (a recorded session gui[10] / [11], a recorded session
    // gui[27]); the Java GUI's keeps its shape (a recorded session gui[22])
    final windows = answerDialect == GuiDialect.windows;
    final reply = frontendRfcReply(call,
        host: host, prefix: windows ? withHostToken(constPrefix, host) : null);
    final notFound = rfcTokens(reply).any((t) => t.$1 == rfcTagException);
    _trace('$what answered '
        '${notFound ? rfcFunctionNotFound : 'with a success'}');
    return clientFrame(frontendRfcReplyItems(at, reply, windows: windows));
  }

  AutomationStream get _autoStream => _w.autoStream;
  StreamPaintAssembler get _streamPaints => _w.streamPaints;
  AnsweredCalls get _answeredFlushes => _w.answeredFlushes;

  /// The automation/DOI state the responder answers from (the XML metrics
  /// advertise THIS session's negotiated window, not the capture's).
  EaSession get _ea => _w.ea;
  DoiState get _doi => _w.doi;

  /// The multi-logon wall, answered wherever it paints during the
  /// bootstrap (right after the credentials, or mid Easy-Access ladder —
  /// the wall blocks the automation queue). The UI decides when [onWall]
  /// is set; else [endOtherSessions] answers automatically.
  Future<void> _answerWallIfPresent(List<Uint8List> frames) async {
    // a wall RELAYED from another system (a remote logon's target) is not
    // this logon's: it is kept for the user (sap_session_remote_logon.dart)
    final wall = readWall(_splitRelayedWall(frames));
    if (!wall.isWall || _wallHandled) return;
    var which =
        endOtherSessions ? WallOption.endOthers : WallOption.keepOthers;
    if (onWall != null) {
      which = await onWall!(wall).timeout(
          const Duration(minutes: 3), onTimeout: () => WallOption.keepOthers);
    }
    if (which == WallOption.cancelLogon) {
      final cancelRow = wallRowFor(wall, WallOption.cancelLogon);
      if (cancelRow != null) {
        await _send(
            clientFrame(_withFirstRound(windowsWallItems(step, wall, cancelRow))));
      }
      throw StateError('logon cancelled at the multi-logon wall');
    }
    final row =
        wallRowFor(wall, which) ?? chooseWallRow(wall, endOtherSessions: false);
    if (row == null) {
      throw StateError('system disallows multiple logons (no keep-others option)');
    }
    // step echoes the wall paint's own counter — the real GUI's answer
    // carries it unchanged (a recorded session gui raw[2])
    await _send(clientFrame(_withFirstRound(windowsWallItems(step, wall, row))));
    _wallHandled = true;
    final got = await recvTurn();
    await _driveAutomation(got);
    _trace('wall answered');
  }

  bool _wallHandled = false;


  // --- tree controls ---------------------------------------------------------

  /// The tree control of the current screen (the Easy Access menu, …): its
  /// node/item tables ride DataProvider pushes in the OLE queue the PBO
  /// flushes BEFORE the screen's paint, so a tree binds to the program the
  /// next paint names. A push carrying a root node (empty RELATKEY) starts a
  /// new tree; one without (a folder expansion's children) extends it.
  SapTreeModel? get tree =>
      _tree != null && _treeProgram != null && screen?.program == _treeProgram
          ? _tree
          : null;

  SapTreeModel? get _tree => _w.tree;
  set _tree(SapTreeModel? v) => _w.tree = v;
  List<DpTable> get _treeTables => _w.treeTables;
  String? get _treeProgram => _w.treeProgram;
  set _treeProgram(String? v) => _w.treeProgram = v;
  bool get _treeUnbound => _w.treeUnbound;
  set _treeUnbound(bool v) => _w.treeUnbound = v;
  int get _dpSeen => _w.dpSeen;
  set _dpSeen(int v) => _w.dpSeen = v;

  /// The singular [tree] is per INTERNAL MODE, hidden but kept: back in
  /// the imode it was bound in, it is the screen's tree again — the real
  /// GUI's return re-sends nothing for it (a recorded session
  /// srv_to_gui_scrubbed #38 / #88: Easy Access, imode D, after SPRO's IMG
  /// tree 120 and SM59's tree 125 replaced it in imodes F / H — no
  /// CreateControl, R3Table or SetDataFromUrl on the way back). A tree
  /// bound in an imode that is gone stays as it was (bound to a program
  /// no longer painted).
  void _keepOrRestoreTree({bool newTree = false}) {
    final w = _w;
    final cur = currentIMode;
    final mine = w.treeIMode;
    if (cur == null || mine == null || mine == cur) return;
    final kept = newTree ? null : w.keptTrees.remove(cur);
    if (!newTree && kept == null) return;
    if (liveIModes.contains(mine) && w.treeProgram != null) {
      w.keptTrees[mine] = (w.tree, List.of(w.treeTables), w.treeProgram);
    }
    w.keptTrees.removeWhere((u, _) => !liveIModes.contains(u));
    if (kept == null) return;
    w
      ..tree = kept.$1
      ..treeProgram = kept.$3
      ..treeIMode = cur
      ..treeUnbound = false
      ..bindTreeAfterFold = false;
    w.treeTables
      ..clear()
      ..addAll(kept.$2);
    _trace('tree of imode ${cur.substring(0, 8)} (${kept.$3}) on screen '
        'again');
  }

  void _ingestTrees(List<Uint8List> frames) {
    _keepOrRestoreTree();
    final dp = _ea.dpCache;
    for (final f in frames) {
      dp.ingestFrame(f);
    }
    var changed = false;
    // the pushes new since the last fold, by the cache's arrival counter
    // (an index into its order would shift under its eviction)
    final fresh = dp.addedSince(_dpSeen);
    _dpSeen = dp.seq;
    for (final url in fresh) {
      final t = decodeNamedDpTable(dp.byUrl[url]!);
      if (t == null) continue;
      final isNodes = t.columns.contains('RELATKEY');
      final isItems = t.columns.contains('ITEM_NAME');
      if (!isNodes && !isItems) continue;
      // an update push (isTreeUpdateTable: RELATKEY blank on every row)
      // changes nodes the tree holds — no new tree
      if (isNodes &&
          !isTreeUpdateTable(t) &&
          t.rows.any((r) => (r['RELATKEY'] ?? '').isEmpty)) {
        // a new tree, not an extension: one of another imode is kept
        if (!_treeUnbound) {
          _keepOrRestoreTree(newTree: true);
          _treeTables.clear();
        }
        _treeUnbound = true;
      }
      _treeTables.add(t);
      _noteTreeTable(url, t);
      changed = true;
    }
    if (changed) {
      final m = SapTreeModel();
      for (final t in _treeTables) {
        m.apply(t);
      }
      _tree = m;
    }
    // bind to the program the next paint names (the PBO flush precedes it)
    if (_treeUnbound && _paintsProgram(frames)) {
      _treeUnbound = false;
      _bindTreeAfterFold = true;
    }
  }

  bool get _bindTreeAfterFold => _w.bindTreeAfterFold;
  set _bindTreeAfterFold(bool v) => _w.bindTreeAfterFold = v;

  void _bindTree() {
    if (!_bindTreeAfterFold) return;
    // a popup painted over it (the multi-logon wall, a message) doesn't own
    // the tree: wait for the full-screen paint behind it
    if ((screen?.modalLevel ?? 0) > 0) return;
    _bindTreeAfterFold = false;
    _treeProgram = screen?.program;
    _w.treeIMode = currentIMode;
  }

  bool _paintsProgram(List<Uint8List> frames) {
    for (final f in frames) {
      final dec = decompressFrame(f);
      if (dec == null) continue;
      for (final it in dec.walk.items) {
        if (it.isAppl && it.id == applStR3Info && it.sid == 13) return true;
      }
    }
    return false;
  }

  // --- grid controls ---------------------------------------------------------

  /// The ALV grid of the current full-screen dynpro (SE16's Data Browser
  /// hit list, …), null when it holds none. While a popup is up this is the
  /// grid of the screen under it (a popup's own grid — the ALV "Details"
  /// dialog — is not reported). Like the tree, a grid's catalog and cells
  /// ride the OLE queue its screen's PBO flushes BEFORE the paint, so a
  /// grid binds to the dynpro the next paint names; it is dropped when the
  /// base screen changes program/dynpro or the server destroys the control.
  SapGridModel? get grid {
    final s = (screen?.modalLevel ?? 0) > 0 ? baseScreen : screen;
    if (s == null || s.modalLevel > 0 || s.program == null) return null;
    for (final g in _grids.reversed) {
      if (g.modal || g.program != s.program || g.dynpro != s.dynpro) continue;
      if (!_onScreen(g.shell)) continue; // destroyed, or of another imode
      if (_inDockingPane(g.shell)) continue; // pane content, see [grids]
      return g.model ??= _gridAsm[g.shell]?.build();
    }
    return null;
  }

  /// shell -> the grid content assembled from its pushes so far
  Map<String, SapGridAssembler> get _gridAsm => _w.gridAsm;

  /// grids bound to the dynpro they were painted on, oldest first
  List<_GridSlot> get _grids => _w.grids;

  /// shells whose pushes arrived but whose screen has not painted yet
  Set<String> get _gridsPending => _w.gridsPending;
  String? get _gridBaseKey => _w.gridBaseKey;
  set _gridBaseKey(String? v) => _w.gridBaseKey = v;

  /// Fold the grid pushes of one complete flush call (chunks already
  /// reassembled by [_driveAutomation]).
  void _ingestGridCall(Uint8List value, [FlushCall? parsed]) {
    final Set<String> touched;
    // a toolbar re-push (control_toolbar.dart) is no new content: the
    // selection stays, and an unbound grid is not bound by it
    final stamps = {
      for (final e in _gridAsm.entries) e.key: e.value.contentStamp,
    };
    try {
      touched = foldGridCall(value, _gridAsm,
          shellOf: (owner) => _ea.shellAlias[owner], parsed: parsed);
    } catch (e) {
      _noteIngestFailure('grid ingest', e);
      return;
    }
    for (final shell in touched) {
      final content = stamps[shell] != _gridAsm[shell]?.contentStamp;
      if (content) _gridContentChanged(shell);
      final bound = _grids.where((g) => g.shell == shell).toList();
      if (bound.isEmpty) {
        if (content) _gridsPending.add(shell);
      } else {
        for (final g in bound) {
          g.model = null; // a re-push on a live grid: rebuild on next read
        }
      }
    }
  }

  void _foldGrids(List<Uint8List> frames) {
    if (_gridsPending.isNotEmpty && _paintsProgram(frames)) _bindPendingGrids();
    // the full-screen dynpro changed: the old screen's grids are gone
    final base = (screen?.modalLevel ?? 0) > 0 ? baseScreen : screen;
    if (base == null || base.program == null) return;
    final key = '${base.program}/${base.dynpro}';
    if ((screen?.modalLevel ?? 0) == 0) _grids.removeWhere((g) => g.modal);
    if (key == _gridBaseKey) return;
    _gridBaseKey = key;
    // a grid of another live internal mode keeps its binding: hidden, not
    // gone — its screen is shown again when its imode is current again
    _grids.removeWhere((g) =>
        !g.modal &&
        (g.program != base.program || g.dynpro != base.dynpro) &&
        !shellInOtherIMode(g.shell));
  }

  /// Bind the pending grids to the screen just painted (a popup's paint
  /// binds them as popup grids).
  void _bindPendingGrids() {
    final s = screen;
    if (s == null || s.program == null) return;
    for (final shell in _gridsPending) {
      _grids.removeWhere((g) => g.shell == shell);
      _grids.add(_GridSlot(shell, s.program, s.dynpro, s.modalLevel > 0));
    }
    _gridsPending.clear();
  }

  // --- chart controls --------------------------------------------------------

  /// The Chart Engine charts of the current full-screen dynpro (ST04 →
  /// DB50/0219's DB size history, …) in creation order, empty when it holds
  /// none; under a popup, the charts of the screen beneath. Like a grid, a
  /// chart's data and customizing XML ride the OLE queue its screen's PBO
  /// flushes BEFORE the paint, so a chart binds to the dynpro the next
  /// paint names. The latest push per shell wins (a metric switch re-pushes
  /// the same shell); a chart is dropped when the base screen changes
  /// program/dynpro or the server destroys the control.
  List<SapChartModel> get charts {
    final s = (screen?.modalLevel ?? 0) > 0 ? baseScreen : screen;
    if (s == null || s.modalLevel > 0 || s.program == null) return const [];
    return [
      for (final c in _charts)
        if (!c.modal &&
            c.program == s.program &&
            c.dynpro == s.dynpro &&
            _onScreen(c.shell))
          if (c.model ??= _chartTracker.build(c.shell) case final m?) m,
    ];
  }

  SapChartTracker get _chartTracker => _w.chartTracker;

  /// charts bound to the dynpro they were painted on, oldest first
  List<_ChartSlot> get _charts => _w.charts;

  /// shells whose pushes arrived but whose screen has not painted yet
  Set<String> get _chartsPending => _w.chartsPending;
  String? get _chartBaseKey => _w.chartBaseKey;
  set _chartBaseKey(String? v) => _w.chartBaseKey = v;

  /// Fold the chart pushes of one complete flush call.
  void _ingestChartCall(Uint8List value, [FlushCall? parsed]) {
    final Set<String> touched;
    try {
      touched = _chartTracker.foldCall(value,
          shellOf: (owner) => _ea.shellAlias[owner],
          isLive: (shell) => !_ea.destroyedControls.contains(shell),
          parsed: parsed);
    } catch (e) {
      _noteIngestFailure('chart ingest', e);
      return;
    }
    for (final shell in touched) {
      final bound = _charts.where((c) => c.shell == shell).toList();
      if (bound.isEmpty) {
        _chartsPending.add(shell);
      } else {
        for (final c in bound) {
          c.model = null; // a re-push on a live chart: rebuild on next read
        }
      }
    }
  }

  void _foldCharts(List<Uint8List> frames) {
    if (_chartsPending.isNotEmpty && _paintsProgram(frames)) {
      _bindPendingCharts();
    }
    final base = (screen?.modalLevel ?? 0) > 0 ? baseScreen : screen;
    if (base == null || base.program == null) return;
    final key = '${base.program}/${base.dynpro}';
    if ((screen?.modalLevel ?? 0) == 0) _charts.removeWhere((c) => c.modal);
    if (key == _chartBaseKey) return;
    _chartBaseKey = key;
    // a chart of another live internal mode keeps its binding (see grids)
    _charts.removeWhere((c) =>
        !c.modal &&
        (c.program != base.program || c.dynpro != base.dynpro) &&
        !shellInOtherIMode(c.shell));
  }

  void _bindPendingCharts() {
    final s = screen;
    if (s == null || s.program == null) return;
    for (final shell in _chartsPending) {
      _charts.removeWhere((c) => c.shell == shell);
      _charts.add(_ChartSlot(shell, s.program, s.dynpro, s.modalLevel > 0));
    }
    _chartsPending.clear();
  }

  // --- network graphs (NetPlanGraphics / inline GRAPH) ------------------------

  /// The network graphs of the screen on display (STMS transport routes,
  /// the SWDD workflow, …): the NetPlanGraphics controls bound to the
  /// current dynpro (pushed in its PBO flush, so bound to the next paint
  /// that names a program, or straight to the dynpro its `LinkControl`
  /// names; under a popup the base screen's), then the graphs the paint
  /// itself carried inline ([ScreenModel.netPlans]).
  List<SapNetPlanModel> get netPlans {
    final s = screen;
    return [
      ..._netPlans.pushedOn(s, baseScreen, {
        ..._ea.destroyedControls,
        ..._layoutState.imodes.hiddenShells, // of another internal mode
      }),
      if (s != null && s.modalLevel > 0) ...?baseScreen?.netPlans,
      ...?s?.netPlans,
    ];
  }

  SapNetPlanTracker get _netPlans => _w.netPlans;

  void _ingestNetPlanCall(Uint8List value, [FlushCall? parsed]) {
    try {
      _netPlans.foldCall(value,
          shellOf: (owner) => _ea.shellAlias[owner],
          isLive: (shell) => !_ea.destroyedControls.contains(shell),
          parsed: parsed);
    } catch (e) {
      _noteIngestFailure('netplan ingest', e);
    }
  }

  void _foldNetPlans(List<Uint8List> frames) {
    if (_netPlans.hasUnbound && _paintsProgram(frames)) {
      _netPlans.bindUnbound(screen);
    }
  }

  /// Double-click [n] on the NetPlanGraphics control hosting [g] (STMS:
  /// opens the system / route; SWDD: the step): raises `%_GC <shell> 1`
  /// and answers the server's stream read-back with the node's command
  /// (a recorded session gui[12]/[14]). [area] = the hit area code the
  /// command ends with (`b`, the box text; see [netPlanNodeCommand]).
  Future<List<Uint8List>> selectNetPlanNode(SapNetPlanModel g, NetPlanNode n,
      {String area = 'b'}) {
    final shell = g.shell;
    if (shell == null) {
      throw StateError('an inline graph has no control to click');
    }
    _netPlans.queueCommand(shell, netPlanNodeCommand(n.id, area: area));
    _ea.recordEvent(shell, {0: '1'});
    return _act(
      netPlanEventItems(ctx,
          shell: shell, windows: answerDialect == GuiDialect.windows),
      controlEvent: true,
      dialectReady: true,
    );
  }

  // --- actions ----------------------------------------------------------------

  Future<List<Uint8List>> press(int vkey) async {
    // typed / ticked classic-list cells ride the list key round
    final listCells = _listCellKeyRound(vkey);
    if (listCells != null) return listCells;
    // typed cells of one table control ride the key in its TABLE plane
    // (a recorded session gui[313]); cells beside other typed
    // values go first as their own Enter round ([_sendStagedCellsFirst])
    final cells = _stagedCellKeyRound(vkey);
    if (cells == null && _stagedHasCells) await _sendStagedCellsFirst();
    _noteModeCommand(vkey: vkey); // Ctrl+N opens a window
    if (cells != null) {
      return _act(cells, dialectReady: true, consumesStaged: true);
    }
    // typed values ride the key (SE38: the program name + F7 in one PAI —
    // a recorded session step 20)
    if (_staged.isNotEmpty) {
      return _act(_stagedRound(vkey: vkey), consumesStaged: true);
    }
    // F1 with the focus inside the ABAP editor is the editor's own event 3
    // (a recorded session gui[75]; sap_session_editor.dart)
    final ed = vkey == 1 ? _focusedEditor : null;
    if (ed != null) {
      return editorHelp(ed, ed.cursorLine ?? 1, ed.cursorCol ?? 1);
    }
    return _act(pressItems(ctx, vkey));
  }

  /// Select a radio of a group (generic): sends only the CHANGED members of
  /// the group — the pick turned on and the previously-on sibling(s) cleared,
  /// in paint order — then Enter. A member already off is never sent: the
  /// kernel clears the rest itself, and extra explicit atoms are an invalid
  /// delta (DYNP_TOO_MANY_RADIOBUTTONS_ON; the engine's raw_radio rule and
  /// a recorded session gui[21] — 2 atoms of a 5-member group).
  ///
  /// [fcode] = the group's own function code when it has one (the click
  /// then fires PAI as its element event — radioSelectItems); [vkey] = the
  /// key the pick rides (Enter = 0).
  Future<List<Uint8List>> selectRadio(
      List<ScreenField> group, ScreenField chosen,
      {String? fcode, int vkey = 0}) async {
    final members = [
      for (final f in group)
        if (identical(f, chosen) || f.on)
          (
            f.area,
            f.block,
            f.group,
            f.wireRow, // the kernel's container-local cell
            f.wireCol,
            identical(f, chosen),
            f.text.length,
          ),
    ];
    return _act(radioSelectItems(ctx, members,
        cursorRow: chosen.wireRow,
        cursorCol: chosen.wireCol,
        cursorArea: chosen.area,
        fcode: fcode,
        vkey: vkey));
  }

  Future<List<Uint8List>> okcode(String cmd) async {
    // a table-control PUSHBUTTON cell's code is its click in the control's
    // TABLE plane (sap_session_fields.dart pressCellButton)
    final cellButton =
        answerDialect == GuiDialect.windows ? _paintedCellButton(cmd) : null;
    if (cellButton != null) return pressCellButton(cellButton);
    // no capture pins typed table-control cells riding a function code:
    // they go first as their control's Enter round (before the window
    // command is noted, which the next round would carry)
    if (_stagedHasCells && !_leavesScreen(cmd)) await _sendStagedCellsFirst();
    _noteModeCommand(okcode: cmd); // `/o…` opens, `/i…` closes a window
    if (_staged.isNotEmpty) {
      if (_leavesScreen(cmd)) {
        _dropStaged('okcode $cmd leaves the screen');
      } else {
        // the values ride the function code; a painted pushbutton's code
        // is its element click (the reference client's accepted SE38 `=SHOP`,
        // step 41)
        return _act(
            _stagedRound(okcode: cmd, button: _paintedButton(cmd)),
            consumesStaged: true);
      }
    }
    // a PAINTED dynpro pushbutton's code is its click, not a typed okcode:
    // the Windows GUI sends the button round (OK 0x0d, the container echo,
    // BUTTONPRESSED at the button's own path, the painted cursor —
    // a recorded session gui[124] `=MEV4002BUTTON`); the typed-okcode
    // spelling of `=MEV4001BUTTON` on ME21N got no reply (live the test system,
    // 2026-10-10 21:32)
    final button =
        answerDialect == GuiDialect.windows ? _paintedButton(cmd) : null;
    if (button != null) {
      return _act(
          windowsPushbuttonItems(ctx,
              fcode: cmd.trim(),
              row: button.$1,
              col: button.$2,
              path: button.$3,
              cursorOnButton: cursorOnPushbutton(screen, ctx.paintedFocus)),
          dialectReady: true);
    }
    return _act(okcodeItems(ctx, cmd));
  }

  /// Whether [shell] was created as a CFW DIALOG container
  /// (`SAPGUI.DIALOGCTRL.1` — the F1 Performance Assistant: a dialog box
  /// OUTSIDE the session window), by its creation class in the responder's
  /// registry (reference client nested_state_round.is_dialog_shell): a paint's
  /// `16/9/18 <dialog>` is no control focus.
  bool isCfwDialogShell(String shell) => _ea.createdControls.any(
      (c) => c.handle == shell && c.cls.toUpperCase().contains('DIALOGCTRL'));

  /// The kernel shell id of the live tree control: the newest CreateControl
  /// of a tree class in the responder's registry (the Easy Access menu's
  /// SapTree, minted in the logon queue — shell 105 on the test system) that the
  /// server has not destroyed. Null when the screen holds no tree.
  String? get treeShell {
    for (final c in _ea.createdControls.reversed) {
      if (!c.cls.toLowerCase().contains('tree')) continue;
      if (!_onScreen(c.handle)) continue; // destroyed, or another imode's
      return c.handle;
    }
    return null;
  }

  /// Open a tree folder whose children are still on the server (EXPANDER):
  /// fires the SapTree's EXPANDNOCHILDREN event (`%_GC <shell> 18`, the
  /// node key in the DATAMANAGER XML — the real GUI's a recorded session
  /// gui[13]); the ABAP handler pushes the children as root-less
  /// TREEV_NODE/*ITM tables that extend [tree]. [nodeKey] is the server's
  /// own NODE_KEY string (echoed verbatim — the jar round-trips keys
  /// untouched and servers disagree on padding).
  Future<List<Uint8List>> expandTreeNode(String nodeKey) async {
    final shell = treeShell;
    if (shell == null) {
      throw StateError('no tree control on this screen to expand');
    }
    _ea.recordEvent(shell, {0: nodeKey});
    noteTreeExpansion(shell, nodeKey, open: true);
    // the connection's spelling (Windows: the OCX DATAMANAGER, sap_session_
    // tree.dart)
    return _act(
      _treeEventRound(shell, treeEventExpandNoChildren, nodeKey),
      controlEvent: true,
    );
  }

  /// Write [text] into the field at ([row], [col]) and press Enter. [mx] /
  /// [mlen] / [attr] = the painted field's maxnrchars, mlen and attribute
  /// byte (a 0 length falls back to the value's own); see [fillItems].
  ///
  /// ([row], [col], [area]) = the field's WIRE cell ([ScreenField.wireRow]
  /// / [ScreenField.wireCol]); the painted input there supplies its
  /// container plane ([ScreenField.routing] — a tabstrip-page field is
  /// written through it, or the kernel answers "FOCUS DATA"). [container]
  /// ([ScreenField.container]) tells two containers' inputs on the same
  /// local cell apart.
  Future<List<Uint8List>> fill(int row, int col, String text,
      {int area = 0,
      int? mx,
      int? mlen,
      int? attr,
      String? container}) async {
    if (_stagedHasCells) await _sendStagedCellsFirst();
    final f = _paintedInput(row, col, area, container);
    if (_staged.isNotEmpty && f != null) {
      // the staged values lead, this field (re-typed or new) goes last
      return _act(_stagedRound(extra: StagedField(f, text)),
          consumesStaged: true);
    }
    return _act(fillItems(ctx, row, col, text,
        area: area,
        mx: (mx ?? 0) > 0 ? mx : null,
        mlen: (mlen ?? 0) > 0 ? mlen : null,
        attr: attr,
        routing: f?.routing));
  }

  /// The active window's painted input at wire cell ([row], [col]) of
  /// [area] (in [container] when given); null when none or ambiguous.
  ScreenField? _paintedInput(int row, int col, int area, String? container) {
    final hits = [
      for (final f in screen?.fields ?? const <ScreenField>[])
        if (f.kind == FieldKind.input &&
            f.tableControl == null &&
            f.wireRow == row &&
            f.wireCol == col &&
            f.area == area &&
            (container == null || f.container == container))
          f,
    ];
    return hits.length == 1 ? hits.single : null;
  }

  /// Type [value] into the table-control cell [cell] (a field of the
  /// current [screen] carrying [ScreenField.tableControl] / `tcLine` /
  /// `tcColumn`) and commit it with Enter (or [vkey]) — the classic
  /// step-loop cell write ([tableCellItems], the Windows GUI's TABLE-plane
  /// round). See [submitCells] for several cells in one round.
  Future<List<Uint8List>> submitCell(ScreenField cell, String value,
          {int vkey = 0}) =>
      submitCells([(cell, value)], vkey: vkey);

  /// Write several cells of ONE table control in a single round (the real
  /// GUI sends every pending cell edit in one 16/9/9), the cursor on
  /// [cursor] (default: the last cell), then Enter / [vkey]. A value is
  /// sent unpadded with its trailing blanks trimmed; a CLEARED cell is the
  /// column's width in blanks (a recorded session gui[319]: 32
  /// spaces into the 32-wide column). Windows dialect only — the Java
  /// GUI's write (16/9/7 metrics, Java OK event, XML) is not built.
  Future<List<Uint8List>> submitCells(List<(ScreenField, String)> cells,
      {ScreenField? cursor, int vkey = 0}) async {
    if (cells.isEmpty) throw ArgumentError('no cell to write');
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError(
          'table-control cell writes are built for the Windows dialect only');
    }
    final name = cells.first.$1.tableControl;
    if (name == null || cells.any((c) => c.$1.tableControl != name)) {
      throw ArgumentError('the cells must belong to one table control');
    }
    final at = cursor ?? cells.last.$1;
    if (_staged.isNotEmpty) {
      // the cells typed before ride this write when they are this
      // control's (the real GUI sends every pending cell edit in one
      // 16/9/9); anything else goes first as its own Enter round
      final merged = _stagedHasCells
          ? _stagedCellRound(name, vkey: vkey, cursor: at, extra: cells)
          : null;
      if (merged != null) {
        return _act(merged, dialectReady: true, consumesStaged: true);
      }
      if (_stagedHasCells) await _sendStagedCellsFirst();
      if (_staged.isNotEmpty) {
        await _act(_stagedRound(), consumesStaged: true);
      }
    }
    final tc = screen?.tableControls.where((t) => t.name == name).firstOrNull;
    if (tc == null) {
      throw StateError('table control $name is not painted on this screen');
    }
    final writes = [
      for (final (f, v) in cells) _cellWrite(tc, f, v),
    ];
    return _act(
      tableCellItems(ctx, tc, writes,
          cursorLine: at.tcLine!, cursorColumn: at.tcColumn!, vkey: vkey),
      dialectReady: true,
    );
  }

  TcCellWrite _cellWrite(TableControlInfo tc, ScreenField f, String value) {
    final line = f.tcLine, col = f.tcColumn;
    if (line == null || col == null) {
      throw ArgumentError('${f.name} is not a table-control cell');
    }
    if (f.kind == FieldKind.checkbox) {
      return TcCellWrite(line, col, value, checkbox: true);
    }
    var v = value.trimRight();
    if (v.isEmpty) {
      final w = col - 1 < tc.widths.length ? tc.widths[col - 1] : f.mlen;
      v = ' ' * (w > 0 ? w : 1);
    }
    return TcCellWrite(line, col, v);
  }

  /// End the logon. An action (or the logon itself) in flight is woken at
  /// once with a [SessionClosedError] — never left to its receive timeout.
  Future<void> close() async {
    state = SessionState.closed;
    _password = null;
    _sockError ??= SessionClosedError();
    _wakeReader();
    final sock = _sock;
    if (sock != null) {
      try {
        await sock.close().timeout(const Duration(seconds: 2));
      } catch (_) {} // a broken or unresponsive peer: destroyed below
    }
    await _dropTransport();
    await _framesController.close();
    await _modes.changes.close();
    await _closedController.close();
  }
}

/// Whether the dynpro [cursor] (a 16/9/11, `depth row col …`) sits on a
/// PUSHBUTTON of [screen] — its wire cell: a popup's default button
/// (SAPLSPO1/0100 paints the cursor on `Non` / `Oui`), whose click then
/// names no dynpro cursor (frontend_profile.windowsPushbuttonItems).
bool cursorOnPushbutton(ScreenModel? screen, List<int>? cursor) {
  if (screen == null || cursor == null || cursor.length < 5) return false;
  final row = cursor[1] << 8 | cursor[2], col = cursor[3] << 8 | cursor[4];
  return screen.fields.any((f) =>
      f.kind == FieldKind.pushbutton && f.wireRow == row && f.wireCol == col);
}

/// Mirror a server turn's paint geometry into the action context — the
/// engine's _server_screen_geometry / _painted_cursor, read from the frames
/// of the turn (the last value wins = the active window's):
///
/// * the dynpro area from AREASIZE 16/12/7 (rows = int0, cols = int1): the
/// source of the OK event's b6-11 rectangle, SCROLL_INFOS2 and the main
/// container's packed dims. the test system's Windows profile paints 45x272 for a
/// full-screen dynpro, 18x82 for the logon popup; an action built on a
/// stale or default rectangle is refused "FOCUS DATA" (00 123) and the
/// kernel tears the transaction down (the GuiGo SE16 table-name fill,
/// 2026-10-09 — the Windows-dialect server never sends the Java 16/4/4
/// this used to read);
/// * the scroll pair from the server CHL 16/5/1 bytes 10/11 (the OK event's
/// b13/b16, SCROLL_INFOS2's lead on a field round — 3/51 on SE16 0230);
/// * the Java 16/4/4 area-size echo when the paint carries one;
/// * the modal level and the popup position (x_pos / y_pos) from the SES;
/// * the focus — only a paint that DECLARES one moves it (reference client 867e1d7
/// §4, client_focus.observe_frame; the last focus item of the frame
/// decides): a painted 16/9/11 becomes the screen's cursor
/// ([ActionContext.paintedFocus]), replacing one the client placed
/// (a recorded session gui[9] row 3 col 22 -> srv[14] row 35
/// col 18 -> gui[10] sent the painted one); a 16/9/10 clears it; a
/// 16/9/18 names the focused CFW control
/// ([ActionContext.paintedControlFocus]) and DROPS the dynpro cursor
/// (a recorded session gui[56] row 0 col 22 -> srv[69] `16/9/18
/// "125"` -> gui[57] `%_GC 125 22`, OK 0x0b, no 16/9/11); a paint
/// declaring no focus keeps both (a recorded session srv[128] ->
/// srv[134] -> gui[119] still carries the F1's client cursor). A 16/9/18
/// naming a CFW DIALOG box ([isDialogShell]: SAPGUI.DIALOGCTRL.1, the F1
/// Performance Assistant — srv[134]'s `"118"`) is no focus at all and
/// changes nothing (reference client nested_state_round.is_dialog_shell, §2), and
/// so is one naming a shell already torn down ([isDeadShell]: destroyed
/// after its last CreateControl — a recorded session
/// srv[28..29] ends `16/9/18 "132"`, the SAP.TABControl.1 of the value
/// help closed at srv[25..26]; gui[23] still sends its dynpro cursor,
/// reference client nested_state_round.is_dead_shell, 0f19cd8). The focus items
/// read are the TOP window's (a frame painting a popup over its parent
/// carries the parent's part first). A POPUP is its own window: the
/// focus of the window under it is parked when the popup paints
/// ([ActionContext.parkedFocus]) and restored when that window repaints
/// after the popup stack closed — the same screen ([screen], the
/// session's identity of the painted screen), else dropped (collapsed
/// gui[23] sent gui[10]'s cursor across the F4 popups srv[13..27]; reference client
/// client_focus._set / _restore_under);
/// * the active window's main 16/12/6 ([ActionContext.paintedGeometry]):
/// the first 16/12/6 of the frame's TOP window — a frame painting a
/// popup over the window beneath carries two 16/12/7 items, and when the
/// last one is followed by container items the popup's part starts there
/// (reference client nested_state_round.top_window_items) — cleared by a paint
/// (a 16/12/7) that declares none;
/// * whether the top window is an ABAP list ([ActionContext.paintedList]:
/// its OK event is the type-9 CHL item) and its 16/12/13 list cursor
/// ([ActionContext.paintedListCursor]);
/// * the TOP window's own 16/12/6 ([ActionContext.paintedTopWindowGeometry],
/// a modal key round's): the first after the frame's LAST 16/12/7, with
/// or without containers after it (reference client windows_key_round
/// .top_window_geometry, ff1e540);
/// * the acknowledged paint's 16/5/1 mode ([ActionContext.paintOkMode])
/// and whether that frame's own last focus item is a 16/9/11
/// ([ActionContext.paintCursorFocus], reference client ok_mode.paint_focus).
void mirrorPaintGeometry(ActionContext ctx, Iterable<Uint8List> frames,
    {bool Function(String shell)? isDialogShell,
    bool Function(String shell)? isDeadShell,
    Object? screen}) {
  for (final f in frames) {
    final dec = decompressFrame(f);
    if (dec == null) continue;
    final all = dec.walk.items;
    final windows = [
      for (var i = 0; i < all.length; i++)
        if (all[i].isAppl && all[i].id == 12 && all[i].sid == 7) i,
    ];
    final top = windows.length >= 2 &&
            all.skip(windows.last).any((it) => it.isAppl && it.id == 10)
        ? windows.last
        : 0;
    final geom = all
        .skip(top)
        .where((it) => it.isAppl && it.id == 12 && it.sid == 6)
        .firstOrNull;
    if (geom != null) {
      ctx.paintedGeometry = Uint8List.fromList(geom.value);
    } else if (windows.isNotEmpty) {
      ctx.paintedGeometry = null;
    }
    if (windows.isNotEmpty) {
      // the top window's own: the first 16/12/6 after the LAST 16/12/7,
      // containers after it or not (reference client windows_key_round
      // .top_window_geometry; a recorded session srv[34] `0016 0047`)
      final own = all
          .skip(windows.last)
          .where((it) => it.isAppl && it.id == 12 && it.sid == 6)
          .firstOrNull;
      ctx.paintedTopWindowGeometry =
          own == null ? null : Uint8List.fromList(own.value);
    }
    if (windows.isNotEmpty) {
      // the window level this paint is of: its (last) SES modal byte
      var level = windows.length - 1;
      for (final it in all) {
        if (it.type == itemSes && it.value.length >= 10) level = it.value[7];
      }
      _parkOrRestoreFocus(ctx, level, screen);
      ctx.paintedModalLevel = windows.length - 1;
      // the Windows container echo of the top window (frontend_profile)
      final echo = windowsPaintEcho(all.skip(top).toList());
      ctx.paintedTableEcho = echo.tables;
      ctx.paintedTabstripEcho = echo.tabstrip;
      // a NAMED container group (16/10/6) in the top window's paint: the
      // flat-cursor control event's OK mode 0x0d (windowsWindowStateOkMode)
      ctx.paintedNamedContainer = all
          .skip(top)
          .any((it) => it.isAppl && it.id == 10 && it.sid == 6);
      // a step loop / table control (16/10/4 CONTAINER_LOOP, 16/10/5): its
      // line count follows the window (sap_session_resize.dart)
      ctx.paintedLoop = all.skip(top).any(
          (it) => it.isAppl && it.id == 10 && (it.sid == 4 || it.sid == 5));
      // an ABAP list window: the top part's last OK event is the type-9
      // CHL item, not a 16/5/1; its 16/12/13 is the list cursor
      var list = false;
      Uint8List? listCursor;
      for (final it in all.skip(top)) {
        if (it.type == itemChl) {
          list = true;
        } else if (it.isAppl && it.id == 5 && it.sid == 1) {
          list = false;
        } else if (it.isAppl && it.id == 12 && it.sid == 13) {
          listCursor = Uint8List.fromList(it.value);
        }
      }
      ctx
        ..paintedList = list
        ..paintedListCursor = list ? listCursor : null;
    }
    for (var i = 0; i < all.length; i++) {
      final it = all[i];
      if (!it.isAppl) {
        if (it.type == itemSes && it.value.length >= 10) {
          ctx.modalNo = it.value[7];
          ctx.modalX = ctx.modalNo != 0 ? it.value[8] : 0;
          ctx.modalY = ctx.modalNo != 0 ? it.value[9] : 0;
        } else if (it.type == itemChl) {
          // an ABAP list's OK event: no 16/5/1 mode to acknowledge
          ctx.paintOkMode = null;
        }
        continue;
      }
      final v = it.value;
      final bd = v.buffer.asByteData(v.offsetInBytes, v.lengthInBytes);
      if (it.id == 12 && it.sid == 7 && v.length >= 8) {
        ctx.areaRows = bd.getUint32(0);
        ctx.areaCols = bd.getUint32(4);
      } else if (it.id == 5 && it.sid == 1 && v.length >= 2) {
        // the paint's own OK mode: the next round's derives from it
        // (ActionContext.paintOkMode — the last one is the top window's)
        ctx.paintOkMode = v[1];
        if (v.length >= 12) {
          ctx.scrV = v[10];
          ctx.scrH = v[11];
        }
      } else if (it.id == 4 && it.sid == 4 && v.length >= 8) {
        ctx.echoedAreaSize = Uint8List.fromList(v.sublist(0, 8));
      } else if (it.id == 9 &&
          const {10, 11, 18}.contains(it.sid) &&
          i < top) {
        // the parent window's part of a popup paint: not the popup's focus
      } else if (it.id == 9 && it.sid == 11 && v.length >= 10) {
        ctx.paintedFocus = Uint8List.fromList(v);
        ctx.paintedControlFocus = null;
        ctx.paintedNoFocus = false;
      } else if (it.id == 9 && it.sid == 10) {
        ctx.paintedFocus = null;
        ctx.paintedControlFocus = null;
        ctx.paintedNoFocus = true;
      } else if (it.id == 9 && it.sid == 18 && v.isNotEmpty) {
        final shell = String.fromCharCodes(v).trim();
        // a dialog box outside the window, or a control already torn down,
        // is no focus: nothing moves
        if (isDialogShell?.call(shell) ?? false) continue;
        if (isDeadShell?.call(shell) ?? false) continue;
        // a control focus: the client / painted dynpro cursor is dropped
        // (the focus rides the next round as the 16/9/18)
        ctx.paintedControlFocus = shell;
        ctx.paintedFocus = null;
        ctx.paintedNoFocus = false;
      }
    }
    // the frame carrying the acked paint's 16/5/1: its own LAST focus item
    // over the whole frame, 16/9/11 or 16/9/18 (reference client ok_mode
    // ._paint_of_frames / paint_focus, 5025506 — ActionContext
    // .paintCursorFocus); a frame without a 16/5/1 keeps the paint's
    if (all.any((it) =>
        it.isAppl && it.id == 5 && it.sid == 1 && it.value.length >= 2)) {
      final last = all
          .where((it) =>
              it.isAppl && it.id == 9 && (it.sid == 11 || it.sid == 18))
          .lastOrNull;
      ctx.paintCursorFocus = last?.sid == 11;
    }
  }
}

/// A paint of window [level]: over the window the focus belongs to (a
/// popup) the focus is parked; back at a lower level (the popups above it
/// closed) that window's parked focus returns when it is the same [screen]
/// (both known), else none ([mirrorPaintGeometry]).
void _parkOrRestoreFocus(ActionContext ctx, int level, Object? screen) {
  final at = ctx.focusLevel;
  if (level > at) {
    ctx.parkedFocus[at] = (
      focus: ctx.paintedFocus,
      control: ctx.paintedControlFocus,
      noFocus: ctx.paintedNoFocus,
      screen: ctx.focusScreen,
    );
    ctx
      ..paintedFocus = null
      ..paintedControlFocus = null
      ..paintedNoFocus = false;
  } else if (level < at) {
    var back = ctx.parkedFocus.remove(level);
    ctx.parkedFocus.removeWhere((k, _) => k > level);
    if (back != null &&
        back.screen != null &&
        screen != null &&
        back.screen != screen) {
      back = null; // the popup led to another screen: its focus is gone
    }
    ctx
      ..paintedFocus = back?.focus
      ..paintedControlFocus = back?.control
      ..paintedNoFocus = back?.noFocus ?? false;
  }
  ctx.focusLevel = level;
  if (screen != null) ctx.focusScreen = screen;
}

/// Normalize a transaction code: strip /n /o command prefixes, keep
/// namespace slashes, upper-case (norm_tcode port).
String normTcode(String tcode) {
  var t = tcode.trim().toUpperCase();
  if (t.startsWith('/N') || t.startsWith('/O')) {
    final rest = t.substring(2);
    // a namespaced tcode (/IWFND/X) keeps its slash only with a command prefix
    t = rest;
  } else if (t.startsWith('/') && !t.contains('/', 1)) {
    t = t.substring(1); // stray command slash
  }
  return t;
}

/// A chart control bound to the dynpro its wave was painted with.
class _ChartSlot {
  _ChartSlot(this.shell, this.program, this.dynpro, this.modal);
  final String shell;
  final String? program;
  final String? dynpro;
  final bool modal;
  SapChartModel? model;
}

/// A grid control bound to the dynpro its wave was painted with.
class _GridSlot {
  _GridSlot(this.shell, this.program, this.dynpro, this.modal);
  final String shell;
  final String? program;
  final String? dynpro;
  final bool modal;
  SapGridModel? model;
}
