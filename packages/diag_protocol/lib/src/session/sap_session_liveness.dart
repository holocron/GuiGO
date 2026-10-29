part of 'sap_session.dart';

/// The ceilings the transport holds a peer to.
/// The NI deframer bounds ONE frame (64 MB); these bound what
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
    this.dpCacheEntries = dpCacheMaxEntries,
    this.dpCacheBytes = 12 << 20,
    this.watchdogPeriod = const Duration(seconds: 15),
    this.silentPingIntervals = 3,
    this.minPingInterval = const Duration(seconds: 10),
    this.minSilence = const Duration(minutes: 5),
    this.silenceRecheck = const Duration(seconds: 2),
    this.writeDeadline = const Duration(seconds: 60),
    this.openWindows = 16,
    this.actionQueueDepth = 32,
    this.automationStreamBytes = 32 << 20,
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

  /// A window's DataProvider push cache caps ([EaSession.dpCache]): the
  /// entries unpinned pushes are held under, and the bytes every push is —
  /// its wire segment plus the decoded memos its readers pinned on it
  /// ([DpCache.decodedBytes]). The phone figure, per window (six open
  /// windows worst-case ~72 MB) — the package's own 32 MB default counted
  /// the segments alone. A push a reader finds evicted falls back to its
  /// call's own one-call cache. Read when a window is born: the logon's
  /// first window takes the defaults.
  final int dpCacheEntries;
  final int dpCacheBytes;

  /// How often the idle watchdog looks, and how many of the server's own
  /// NI_PING intervals of silence declare the connection lost. The
  /// interval is LEARNED from the pings the server sends (the real GUI
  /// never pings: zero client NI_PINGs over the recording corpus; the
  /// SAProuter / dispatcher pings an idle GUI every 200 s on
  /// a recorded session) — a server that never pinged is never declared
  /// silent. A ping arriving sooner than [minPingInterval] after other
  /// traffic says nothing about the idle cadence and is not learned; nor
  /// is one idle gap alone — two consecutive pings must agree (an
  /// unsolicited push shortly before a ping measured a "cadence" of
  /// seconds, and a ping read on resume after a suspension one of hours).
  final Duration watchdogPeriod;
  final int silentPingIntervals;
  final Duration minPingInterval;

  /// The least silence that declares the connection lost, whatever the
  /// learned cadence says.
  final Duration minSilence;

  /// How long a watchdog trip waits before it condemns the connection:
  /// a tick overdue after the app was suspended runs before the socket
  /// delivers what queued meanwhile.
  final Duration silenceRecheck;

  /// How long one socket flush may take before the peer is declared gone:
  /// a dispatcher that ACKs TCP but stops reading
  /// (a wedged work process, a hung relay) holds the write forever — no
  /// receive deadline can start on a request that never left, and `busy`
  /// disables the idle watchdog meanwhile. A real kernel drains a frame
  /// in milliseconds; a request-stream chunk is under 30 kB.
  final Duration writeDeadline;

  /// Windows the mode table holds open at once:
  /// every window owns a full per-window state (its DP cache, trees,
  /// grids, editors), and a stream cycling fresh mode bytes would retain
  /// one per byte. A real kernel caps a logon at six modes. Past the cap
  /// the OLDEST background window is retired — closed on the client side,
  /// its parked frames dropped — before the new one is born.
  final int openWindows;

  /// External calls that may wait behind the running action:
  /// a UI that enqueues per keystroke while the first
  /// action stalls (up to the 10-minute dialog step) would otherwise
  /// replay hundreds of stale rounds afterwards. A call past the depth is
  /// refused at once ([ActionQueueFullError]); a call made from inside the
  /// running action is never counted.
  final int actionQueueDepth;

  /// The bytes a window's chunked automation call may gather before its
  /// sid-0 closer ([AutomationStream.maxPendingBytes]):
  /// a kernel streaming chunks that never close would balloon the
  /// stream for the logon's life. Past it the stream is abandoned and
  /// counted as an answer failure.
  final int automationStreamBytes;
}

/// An external call was refused because [TransportLimits.actionQueueDepth]
/// calls already wait behind the running action.
class ActionQueueFullError extends StateError {
  ActionQueueFullError(super.message);
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
  /// backgrounded app could not read, the FIN / reset of a logon the
  /// server ended) — the probe sends NOTHING (the real GUI never pings the
  /// server). The grace is honoured whether or not a cadence was learned:
  /// a close queued during the suspension reaches the socket listener only
  /// through the event loop, never a synchronous look at the state — a
  /// probe answering alive at once on a server that never pinged showed
  /// the stale screen for a flicker before the close flipped it.
  /// A server that has not pinged yet gives no cadence to judge silence
  /// by: after the grace the probe then only reads the state.
  Future<bool> probeLiveness({
    Duration grace = const Duration(milliseconds: 500),
  }) async {
    bool dead() =>
        state != SessionState.ready || closedByPeer || _sockError != null;
    if (dead()) return false;
    if (grace > Duration.zero) await Future<void>.delayed(grace);
    if (dead()) return false;
    if (_pingGap == null) return true;
    // an action in flight (a 6–9 min report the server is still computing
    // on, probed on resume from the background): its own wait judges the
    // silence, as the idle watchdog leaves it to — the probe reports the
    // socket state only. The logon ladder is not
    // such an action: it runs under its own deadline, and a peer gone
    // silent under it is condemned here as before.
    if (busy && !_bootstrapping) return true;
    if (_silentTooLong()) {
      _abortTransport(ConnectionLostError(_silenceMessage()));
      return false;
    }
    return true;
  }

  /// The idle interval the server pings at, learned from its NI_PINGs
  /// (null: it has not pinged yet).
  Duration? get serverPingInterval => _pingGap;

  /// Test hook: the server's idle ping cadence as if learned ([gap]), and
  /// the last wire traffic at [lastWire] — the silence judgement of
  /// [probeLiveness] driven without a peer.
  void pingCadenceForTest(Duration gap, {DateTime? lastWire}) {
    _pingGap = gap;
    _pingSample = gap;
    _lastWire = lastWire ?? DateTime.now();
  }

  /// Parked frames dropped over all windows ([TransportLimits.
  /// parkedFramesPerWindow]); a window that lost any is [SapWindow.suspect].
  int get parkedFramesDropped => _parkedDropped;

  /// Background windows retired to make room for a newborn one
  /// ([TransportLimits.openWindows]).
  int get windowsRetired => _windowsRetired;

  /// The bytes of the unread inbox as the ceiling counts them
  /// ([TransportLimits.inboxBytes]; a requeued frame counts again).
  int get bufferedInboxBytes => _inboxBytes;

  /// Flush [s] within [TransportLimits.writeDeadline]:
  /// a peer that stops reading holds the flush forever — it is
  /// declared gone like a silent one ([ConnectionLostError], the transport
  /// dropped, [closed] fired). [bytes] names the write in the message.
  Future<void> _flushWithin(Socket s, int bytes) async {
    final limit = limits.writeDeadline;
    final flushed = s.flush();
    try {
      await flushed.timeout(limit);
    } on TimeoutException {
      final e = ConnectionLostError(
        'the server stopped reading: a $bytes-B frame was not accepted in '
        '${limit.inSeconds}s — the dispatcher or the network path to it '
        'is wedged; log on again',
      );
      _abortTransport(e);
      throw e;
    }
  }

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

  /// [payload] goes back to the FRONT of the inbox, to be read again (a
  /// hand-back's parked frames, a request stream's non-receipt, the frames
  /// behind a route's NI_PONG): counted again — [_inboxTaken] counted it
  /// out when it was first read, and a re-add that did not re-count left
  /// the ceiling soft after every hand-back. No
  /// ceiling check here: the frames were buffered within it once, and the
  /// next listener add judges the total.
  void _inboxRequeue(Uint8List payload) {
    _inbox.addFirst(payload);
    _inboxBytes += payload.length;
  }

  /// A server NI_PING arrived [idle] after the previous wire traffic: the
  /// cadence is learned (or re-learned) when it agrees with the previous
  /// idle ping's gap within a quarter, the longer of the two kept.
  void _notePing(Duration? idle) {
    if (idle == null || idle < limits.minPingInterval) return;
    final prev = _pingSample;
    _pingSample = idle;
    if (prev == null) return;
    final (lo, hi) = prev < idle ? (prev, idle) : (idle, prev);
    if (lo * 4 >= hi * 3) _pingGap = hi;
  }

  /// The silence past which the connection is lost (null: no cadence).
  Duration? get _silenceLimit {
    final gap = _pingGap;
    if (gap == null) return null;
    final n = gap * limits.silentPingIntervals;
    return n < limits.minSilence ? limits.minSilence : n;
  }

  bool _silentTooLong() {
    final limit = _silenceLimit, last = _lastWire;
    if (limit == null || last == null) return false;
    return DateTime.now().difference(last) > limit;
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
      // a running action checks silence in its own wait (sap_session.dart)
      if (state != SessionState.ready || busy || _sock == null) return;
      if (!_silentTooLong()) return;
      // condemned only if still silent once the socket had its turn
      Timer(limits.silenceRecheck, () {
        if (state != SessionState.ready || busy || _sock == null) return;
        if (_silentTooLong()) {
          _abortTransport(ConnectionLostError(_silenceMessage()));
        }
      });
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

  /// Room in the mode table for a window about to be born
  /// ([TransportLimits.openWindows]): while the table
  /// is full, the OLDEST background window (birth order; never the live
  /// one, the newborn's parent) is retired — closed on the client side
  /// like a `0m 09` of a background window, its parked frames dropped,
  /// its state let go. A later frame in its mode byte is a new window.
  /// Real kernels hold ~6 modes: a real logon never gets here.
  void _retireForBirth() {
    final l = limits;
    while (_modes.open.length >= l.openWindows) {
      _WindowState? oldest;
      for (final w in _modes.open.values) {
        if (w.mode != _modes.liveMode) {
          oldest = w;
          break;
        }
      }
      if (oldest == null) return; // only the live window: nothing to retire
      _modes.open.remove(oldest.mode);
      _modes.closed.add(oldest.snapshot(active: false, closed: true));
      _modes.closedCount++;
      if (_modes.closed.length > _WindowTable.maxClosedKept) {
        _modes.closed.removeAt(0);
      }
      final parked = oldest.queue.length;
      oldest.queue.clear();
      _parkedDropped += parked;
      _windowsRetired++;
      lastFailure =
          'window (${oldest.number}) (DIAG mode ${oldest.mode}) retired: '
          '${l.openWindows} windows open already'
          '${parked == 0 ? '' : ', $parked parked frame(s) dropped'}';
      _trace('[mode] $lastFailure');
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

  /// Before [call]'s models fold it: every control instance it ENDS
  /// (DestroyWindow) or REPLACES (a CreateControl of a shell id the kernel
  /// handed out before) takes its content with it. A kernel shell id is
  /// reused for whatever control comes next — of any class, in any
  /// transaction — and the content models are keyed by shell, so the old
  /// instance's state resurfaced on the new one once the id was live
  /// again. a recorded session (one real SAP GUI for Windows logon):
  /// SM59's connection-test grid 146 ("Action | Résultat", srv[57]) is
  /// DestroyWindow'd at srv[66]; SE80 (srv[144]) re-creates 146 as the
  /// container of its object-name field — and the dock drew the dead grid
  /// over the name field and the tree toolbar (the live iPad's
  /// "Propriété | Valeur" header in SE80's dock, 2026-10-13). Likewise a
  /// sash the user dragged in an earlier splitter of that id re-laid the
  /// new splitter's cells, and an old column tree's headings stayed on
  /// the shell.
  void _forgetPriorInstances(FlushCall call) {
    Set<String>? urls;
    for (var i = 1; i <= call.verbs.length; i++) {
      final verb = call.verbs[i - 1];
      final create = verb.startsWith('CreateControl');
      if (!create && verb != 'DestroyWindow') continue;
      final a = verbNamedArgs(call, i);
      final sh = (a['#1'] ?? '').trim();
      if (!_digitsOnlyRx.hasMatch(sh)) continue;
      // the pushes this call binds (a DP url may be reused for the new
      // instance's content, decoded before the call folds)
      urls ??= {
        for (var j = 1; j <= call.verbs.length; j++)
          if (call.verbs[j - 1] == 'SetDataFromUrl')
            (verbNamedArgs(call, j)['#3'] ?? '').trim(),
      };
      _purgeShellContent(
        sh,
        cls: create ? (a['#2'] ?? '').trim() : null,
        keepUrls: urls,
      );
    }
  }

  /// Drop the content control [sh]'s previous instance left: [cls] is the
  /// class of the control now created on it (null: the shell ended). A
  /// model of the new control's own kind is left to that model's fold (a
  /// re-created grid / tree / editor / picture re-binds its new pushes,
  /// each fold's "a reused shell id is a new control" rule); every other
  /// kind's goes. Always dropped: the tree columns and HeaderNames-derived
  /// layout (re-declared by the new tree's own call, folded after this),
  /// the splitter sashes the user held, and a splitter record of a shell
  /// that is no splitter any more.
  void _purgeShellContent(
    String sh, {
    String? cls,
    Set<String> keepUrls = const {},
  }) {
    final kind = cls == null ? null : controlKind(cls);
    final st = _layoutState;
    final w = _w;
    bool mine(String k) => k == sh || _ea.shellAlias[k] == sh;
    _treeColumnsOf[w]?.removeWhere((k, _) => mine(k));
    // the user's drag was over the OLD splitter's cells
    st.sashHeld.removeWhere((k, _) => k.$1 == sh);
    st.sashDragged.remove(sh);
    if (cls == null || !cls.contains('Splitter')) {
      st.registry.splitters.remove(sh);
    }
    if (kind != 'grid') {
      _gridAsm.remove(sh);
      if (kind == null) {
        for (final g in _grids) {
          if (g.shell == sh) g.model = null;
        }
      } else {
        _grids.removeWhere((g) => g.shell == sh);
        _gridsPending.remove(sh);
      }
    }
    if (kind != 'tree') {
      final urls = [
        for (final e in st.treeUrlShell.entries)
          if (e.value == sh && !keepUrls.contains(e.key)) e.key,
      ];
      if (urls.isNotEmpty) {
        st.treeTables.removeWhere((t) => urls.contains(t.$1));
        urls
          ..forEach(st.treeUrlShell.remove)
          ..forEach(st.treeUrlIMode.remove);
      }
      st.treeModels.remove(sh);
    }
    if (kind != 'html') _htmlState.shown.remove(sh);
    if (kind != 'editor') _editorTracker.loaded.remove(sh);
    if (kind != 'image') _pictureTracker.urlOf.remove(sh);
  }
}
