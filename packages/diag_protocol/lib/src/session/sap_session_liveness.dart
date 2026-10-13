part of 'sap_session.dart';

/// The ceilings the transport holds a peer to (audit 2026-10-13 R-01, R-02,
/// R-04, R-12). The NI deframer bounds ONE frame (64 MB); these bound what
/// a peer can make the client buffer or read in aggregate. A breach is a
/// broken or hostile peer, never a real kernel: the transport is dropped
/// and the session fails visibly ([NiProtocolException], [SapSession.closed]).
class TransportLimits {
  const TransportLimits({
    this.turnFrames = 16384,
    this.turnBytes = 256 << 20,
    this.inboxFrames = 16384,
    this.inboxBytes = 128 << 20,
    this.parkedFramesPerWindow = 256,
    this.parkedBytes = 64 << 20,
    this.treeDecodedBytes = 64 << 20,
    this.watchdogPeriod = const Duration(seconds: 15),
    this.silentPingIntervals = 3,
    this.minPingInterval = const Duration(seconds: 10),
  });

  /// NI payloads / bytes one receive turn may read before it ends — a peer
  /// that keeps sending frames that never end the turn (no EOM, no paint)
  /// would otherwise grow the turn without bound.
  final int turnFrames;
  final int turnBytes;

  /// Payloads / bytes the socket listener may buffer unread (an idle
  /// session reads nothing between actions).
  final int inboxFrames;
  final int inboxBytes;

  /// Frames one background window may hold parked (the oldest out first:
  /// the window is then marked [SapWindow.suspect]), and the parked bytes of
  /// all windows together (a breach drops the transport).
  final int parkedFramesPerWindow;
  final int parkedBytes;

  /// The decoded size a window's retained tree tables may reach; a push
  /// past it is refused (counted as an ingest failure), the tree kept.
  final int treeDecodedBytes;

  /// How often the idle watchdog looks, and how many of the server's own
  /// NI_PING intervals of silence declare the connection lost. The
  /// interval is LEARNED from the pings the server sends (the real GUI
  /// never pings: zero client NI_PINGs over the recording corpus; the
  /// SAProuter / dispatcher pings an idle GUI every 200 s on
  /// a recorded session) — a server that never pinged is never declared
  /// silent. A ping arriving sooner than [minPingInterval] after other
  /// traffic says nothing about the idle cadence and is not learned.
  final Duration watchdogPeriod;
  final int silentPingIntervals;
  final Duration minPingInterval;
}

/// The connection went silent past what the server's own NI_PING cadence
/// allows — a half-open socket (a NAT mapping expired, a network handover):
/// no FIN or reset ever arrives, so the socket alone would stay "open".
class ConnectionLostError implements Exception {
  ConnectionLostError(this.message);
  final String message;

  @override
  String toString() => 'ConnectionLostError: $message';
}

/// The session's transport guards: socket teardown, NI_PONG, the inbox
/// ceiling, the idle watchdog and the liveness probe.
extension SapSessionLiveness on SapSession {
  /// Whether the logon still looks alive: [SessionState.ready], not
  /// closed by the peer, and not silent past the server's own ping cadence
  /// (a silent one is dropped now: [closed] fires). [grace] first lets the
  /// socket deliver what queued while the app was suspended (the pings a
  /// backgrounded app could not read) — the probe sends NOTHING (the real
  /// GUI never pings the server).
  /// A server that has not pinged yet gives no cadence to judge silence
  /// by: the probe then only reads the state (and waits no [grace]).
  Future<bool> probeLiveness({
    Duration grace = const Duration(milliseconds: 500),
  }) async {
    bool dead() =>
        state != SessionState.ready || closedByPeer || _sockError != null;
    if (dead()) return false;
    if (_pingGap == null) return true;
    if (grace > Duration.zero) await Future<void>.delayed(grace);
    if (dead()) return false;
    if (_silentTooLong()) {
      _abortTransport(ConnectionLostError(_silenceMessage()));
      return false;
    }
    return true;
  }

  /// The idle interval the server pings at, learned from its NI_PINGs
  /// (null: it has not pinged yet).
  Duration? get serverPingInterval => _pingGap;

  /// Parked frames dropped over all windows ([TransportLimits.
  /// parkedFramesPerWindow]); a window that lost any is [SapWindow.suspect].
  int get parkedFramesDropped => _parkedDropped;

  /// Destroy the socket and forget it: nothing writes to a destroyed
  /// socket afterwards (a pong, a send), every later use sees no socket.
  void _destroySocket() {
    final s = _sock;
    _sock = null;
    s?.destroy();
  }

  /// Answer an NI_PING. The socket may be gone (destroyed by a failure
  /// in the same burst): an add on it throws inside the stream callback.
  void _pong() {
    final s = _sock;
    if (s == null) return;
    try {
      s.add(niPongFrame);
    } catch (e) {
      _trace('NI_PONG not sent: $e');
    }
  }

  /// End the transport for [e] (a breached ceiling, a silent peer, an
  /// abandoned request stream): the socket destroyed, the reader woken
  /// with [e], [closed] fired.
  void _abortTransport(Object e) {
    _sockError ??= e;
    _trace('transport dropped: $e');
    _inbox.clear();
    _inboxBytes = 0;
    _stopWatchdog();
    _destroySocket();
    _notifyClosed();
    _wakeReader();
  }

  /// [payload] the listener buffered: true (transport dropped) when the
  /// unread inbox crosses its ceiling.
  bool _inboxOverflow(Uint8List payload) {
    _inboxBytes += payload.length;
    final l = limits;
    if (_inbox.length <= l.inboxFrames && _inboxBytes <= l.inboxBytes) {
      return false;
    }
    _abortTransport(
      NiProtocolException(
        'the server buffered ${_inbox.length} unread frame(s) '
        '($_inboxBytes B) past the client\'s ceiling '
        '(${l.inboxFrames} frames / ${l.inboxBytes} B)',
      ),
    );
    return true;
  }

  /// [payload] was read off the inbox.
  void _inboxTaken(Uint8List payload) {
    _inboxBytes -= payload.length;
    if (_inboxBytes < 0 || _inbox.isEmpty) _inboxBytes = 0;
  }

  /// A server NI_PING arrived [idle] after the previous wire traffic.
  void _notePing(Duration? idle) {
    if (idle == null || idle < limits.minPingInterval) return;
    _pingGap = idle;
  }

  bool _silentTooLong() {
    final gap = _pingGap, last = _lastWire;
    if (gap == null || last == null) return false;
    return DateTime.now().difference(last) > gap * limits.silentPingIntervals;
  }

  String _silenceMessage() {
    final last = _lastWire;
    final silent = last == null ? 0 : DateTime.now().difference(last).inSeconds;
    return 'the connection went silent: nothing arrived for ${silent}s '
        'although the server pings an idle connection every '
        '${_pingGap!.inSeconds}s — the network path to the server is gone; '
        'log on again';
  }

  /// Start the idle watchdog of a ready logon.
  void _startWatchdog() {
    _stopWatchdog();
    if (offlineReplay) return;
    _watchdog = Timer.periodic(limits.watchdogPeriod, (_) {
      // an action's own receive deadline covers a running one
      if (state != SessionState.ready || busy || _sock == null) return;
      if (_silentTooLong()) {
        _abortTransport(ConnectionLostError(_silenceMessage()));
      }
    });
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }
}

/// TCP keep-alive on [s] with an idle time short enough to keep a NAT
/// mapping and to notice a dead peer while the session idles: the OS
/// probes are transport-level ACKs the SAP server never sees. Best effort —
/// an option the platform refuses is skipped.
void enableTcpKeepAlive(
  Socket s, {
  int idleSeconds = 60,
  int intervalSeconds = 20,
  int probes = 4,
}) {
  void set(int level, int option, int value) {
    try {
      s.setRawOption(RawSocketOption.fromInt(level, option, value));
    } catch (_) {
      // unsupported on this platform / socket
    }
  }

  final int soKeepAlive, tcpIdle, tcpInterval, tcpCount;
  if (Platform.isMacOS || Platform.isIOS) {
    // <sys/socket.h> SO_KEEPALIVE; <netinet/tcp.h> TCP_KEEPALIVE /
    // TCP_KEEPINTVL / TCP_KEEPCNT
    (soKeepAlive, tcpIdle, tcpInterval, tcpCount) = (0x8, 0x10, 0x101, 0x102);
  } else if (Platform.isLinux || Platform.isAndroid) {
    (soKeepAlive, tcpIdle, tcpInterval, tcpCount) = (9, 4, 5, 6);
  } else if (Platform.isWindows) {
    (soKeepAlive, tcpIdle, tcpInterval, tcpCount) = (8, 3, 17, 16);
  } else {
    return;
  }
  set(RawSocketOption.levelSocket, soKeepAlive, 1);
  set(RawSocketOption.levelTcp, tcpIdle, idleSeconds);
  set(RawSocketOption.levelTcp, tcpInterval, intervalSeconds);
  set(RawSocketOption.levelTcp, tcpCount, probes);
}

extension _SapSessionParked on SapSession {
  /// A frame was parked on background window [win]: past the per-window
  /// cap the oldest go and the window is marked [SapWindow.suspect] (its
  /// dropped frames may have carried a flush the kernel now waits on); the
  /// parked bytes of all windows past [TransportLimits.parkedBytes] drop
  /// the transport.
  void _parkedQueued(_WindowState win) {
    final l = limits;
    final over = win.queue.length - l.parkedFramesPerWindow;
    if (over > 0) {
      win.queue.removeRange(0, over);
      win.parkedDropped += over;
      _parkedDropped += over;
      lastFailure =
          'window (${win.number}): $over parked frame(s) dropped '
          '(over ${l.parkedFramesPerWindow} while in the background)';
      _trace('[mode] $lastFailure — the window is marked suspect');
    }
    var total = 0;
    for (final w in _modes.open.values) {
      for (final p in w.queue) {
        total += p.length;
      }
    }
    if (total > l.parkedBytes) {
      final e = NiProtocolException(
        'the background windows hold $total B of parked frames '
        '(ceiling ${l.parkedBytes} B)',
      );
      _abortTransport(e);
      throw e;
    }
  }

  /// Whether [t] still fits the window's retained tree tables
  /// ([TransportLimits.treeDecodedBytes]); a push past it is refused and
  /// counted, the tree kept as it is.
  bool _treeTableFits(DpTable t) {
    var total = _dpTableBytes(t);
    for (final k in _treeTables) {
      total += _dpTableBytes(k);
    }
    if (total <= limits.treeDecodedBytes) return true;
    _noteIngestFailure(
      'tree ingest',
      StateError(
        'a ${t.name} push of ${t.rows.length} row(s) would hold '
        '$total B of tree tables (ceiling ${limits.treeDecodedBytes} B): '
        'refused',
      ),
    );
    return false;
  }
}

/// The decoded size of [t]: its rows times the FORMAT's record width.
int _dpTableBytes(DpTable t) {
  var w = 0;
  for (final l in t.lengths) {
    w += l;
  }
  if (w <= 0) w = t.columns.length * 16;
  return t.rows.length * w;
}

extension _SapSessionShellPrune on SapSession {
  /// A control [sh] ended (its DestroyWindow, its imode's delIMode): what
  /// the session kept per shell goes with it — its imode stamp, the tree's
  /// expanded / selected keys, its HeaderNames table and its top node —
  /// so these maps never outgrow the live controls over a long session.
  /// Keys naming it by a handle aliasing it go too.
  void _forgetShellState(String sh) {
    _layoutState.imodes.forget(sh);
    final w = _w;
    bool mine(String k) => k == sh || _ea.shellAlias[k] == sh;
    w.expandedKeys.removeWhere((k, _) => mine(k));
    w.selectionKeys.removeWhere((k, _) => mine(k));
    w.headerNames.removeWhere((k, _) => mine(k));
    _treeTopNodes[w]?.removeWhere((k, _) => mine(k));
  }
}
