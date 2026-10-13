import 'dart:math' as math;
import 'dart:async';

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/action_errors.dart';
import '../../core/connections.dart';
import '../../core/error_text.dart';
import '../../core/open_lock_icon.dart';
import '../../core/password_dialog.dart';
import '../../core/password_gate.dart';
import '../../core/sap_icons.dart';
import 'browser_platform.dart';
import 'dynpro_view.dart';
import 'frame_coalescer.dart';
import 'sap_calendar_view.dart';
import 'sap_date_navigator_view.dart';
import 'sap_canvas_layout.dart';
import 'sap_chart_view.dart';
import 'sap_combo_box_view.dart';
import 'sap_control_toolbar.dart';
import 'sap_graph_view.dart';
import 'sap_grid_view.dart';
import 'sap_html_view.dart';
import 'sap_office_view.dart';
import 'sap_picture_view.dart';
import 'sap_value_help_view.dart';
import 'sap_window_size.dart';
import 'sap_source_view.dart';
import 'sap_menu_bar.dart';
import 'sap_toolbar.dart';
import 'screen_composer.dart';
import 'session_busy.dart';
import 'sap_tree_view.dart';
import 'splitter_sash_grip.dart';
import 'modal_window.dart';
import 'type_ahead.dart';

class SessionArgs {
  SessionArgs(this.entry, this.store);
  final ConnectionEntry entry;
  final ConnectionStore store;
}

/// Builds the session of one logon attempt (tests pass a fake; the app
/// the real [SapSession]).
typedef SessionFactory = SapSession Function(
  SapSystem system,
  String password,
  Future<WallOption> Function(WallInfo wall) onWall,
);

class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    this.sessionFactory,
    this.idleLimit = const Duration(minutes: 5),
  });

  /// The logon attempt's session; null = a real [SapSession].
  @visibleForTesting
  final SessionFactory? sessionFactory;

  /// Back from the background, a session silent this long is taken for
  /// lost (the kernel's idle auto-logout — the test system ends a logon after ~5 min —
  /// or a socket the OS dropped while the app was suspended).
  final Duration idleLimit;

  /// How often the whole screen / its body region were built (tests read
  /// them: a server turn rebuilds the regions, not the Scaffold).
  @visibleForTesting
  static int debugScaffoldBuilds = 0;
  @visibleForTesting
  static int debugBodyBuilds = 0;

  /// How many frames drew server turns (a burst between two frames: one).
  @visibleForTesting
  static int debugTurnFrames = 0;

  /// The session body (below the command row, above the status / key bar):
  /// the region whose size is the SAP window GuiGo reports.
  static const Key bodyKey = ValueKey('session-body');

  /// The status bar's message line (always laid out, one line high).
  static const Key messageLineKey = ValueKey('session-message-line');

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen>
    with WidgetsBindingObserver {
  SapSession? _session;
  ScreenModel? _screen;
  String? _error;

  /// An action (or the logon) is running. A notifier, not screen state: it
  /// rebuilds the leaves that draw it (the keys, the spinner, the body's
  /// inputs — [SessionBusy], [_busyLeaf]), not the body or the Scaffold.
  /// Busy changes nothing the session holds: no new generation ([_gen]);
  /// an action's END is drawn with the turn it usually ends on (the
  /// coalesced tick: one body build per action) — and alone after an
  /// action that changed the session without a turn.
  final ValueNotifier<bool> _busyN = ValueNotifier(false);
  bool get _busy => _busyN.value;
  set _busy(bool v) {
    if (_busyN.value == v) return;
    _busyN.value = v;
    if (!v) _turnTick.mark();
    _scheduleModalSync();
  }

  /// The modal dialog's busy ([SessionBusy] over the dialog route): the
  /// session's, except on the multi-logon wall — the logon runs (busy),
  /// yet the wall's choices are the user's to make.
  _DerivedFlag? _modalBusyN;
  _DerivedFlag get _modalBusy => _modalBusyN ??= _DerivedFlag(
    () => _busy && _wallCompleter == null,
    [_busyN, _ui],
  );

  /// A server turn (or a window switch) to draw: fired at most once per
  /// frame, so a burst of turns between two frames rebuilds once.
  final FrameCoalescedTick _turnTick = FrameCoalescedTick();
  SapSession? _tickFrom;

  /// The regions of the screen (title, command row, body, status / keys)
  /// rebuild on a turn or a busy change; the Scaffold around them only on
  /// a change of the logon itself (connected, failed, the wall). The body
  /// and the title rebuild on a turn alone ([_turnRegion]).
  late final Listenable _regionTick = Listenable.merge([_turnTick, _busyN]);

  /// Bumped on every change the screen draws: the per-build snapshot of
  /// the session's controls is valid for one generation.
  int _gen = 0;

  /// The zoom (widest grid per program) of THIS logon's screens, shared by
  /// its main window and its modal dialogs.
  final Map<String, int> _widestCols = {};

  /// The last moment the logon showed life (a server turn, an action, the
  /// connect) — what a resume from the background is measured against.
  DateTime _lastActivity = DateTime.now();
  DateTime? _backgroundSince;

  /// The session was found dead on a resume: the error view offers to
  /// reconnect.
  bool _lost = false;

  /// The trace log of the latest logon attempt (its last lines name where
  /// a failed logon diverged).
  List<String>? _trace;
  int _traceLen = -1;
  String? _traceLast;

  /// The user dismissed the unencrypted-connection notice for this
  /// connection (stored: shown once per connection).
  bool _plaintextSeen = false;
  late SessionArgs _args;
  bool _started = false;
  final _localAuth = LocalAuthentication();
  SapIconAtlas? _icons;

  /// The multi-logon wall awaiting a user choice (the bootstrap is paused
  /// on the completer); the generic modal renders it over the base window.
  final ValueNotifier<List<String>> _connectLog = ValueNotifier([]);
  Timer? _logTimer;

  /// The session body's size as last laid out (below the command row,
  /// above the status / key bar): the SAP window GuiGo reports
  /// ([sapWindowCells]) — at the logon, and again (debounced) when the body
  /// changes size: a rotation, a split-view resize.
  Size? _bodySize;
  Timer? _resizeTimer;

  /// How long the body must hold a new size before the server hears of it
  /// (a rotation animates through many sizes; a split-view drag too).
  static const Duration _resizeDebounce = Duration(milliseconds: 300);
  Completer<WallOption>? _wallCompleter;
  WallInfo? _wall;

  /// The wall option row the user selected in the dialog (the wall paints
  /// one option pre-selected; the ✓ action confirms this selection).
  int? _wallSelectionRow;

  /// The modal dynpro dialog route — a REAL modal: full-screen barrier,
  /// nothing behind it tappable, popped when the paint leaves modal state.
  DialogRoute<void>? _modalRoute;

  /// Notifies the dialog route's content (it lives above this screen in
  /// the navigator, so it cannot see our setState).
  final _UiPulse _ui = _UiPulse();

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _gen++;
    _ui.ping();
    _scheduleModalSync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // route arguments aren't reachable from initState, so connect here once
    if (_started) return;
    _started = true;
    _args = ModalRoute.of(context)!.settings.arguments as SessionArgs;
    _plaintextSeen = _args.store.plaintextNoticeSeen(_args.entry.id);
    _connect();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _turnTick.addListener(_onTurnFrame);
    SapIconAtlas.load().then((a) {
      if (mounted) setState(() => _icons = a);
    });
  }

  /// A turn of the current logon arrived: drawn on the next frame.
  void _markTurn(SapSession session) {
    _tickFrom = session;
    _lastActivity = DateTime.now();
    _turnTick.mark();
  }

  /// The frame's tick (before its build): the screen to draw is the
  /// session's latest; the regions listening to the tick rebuild with it.
  void _onTurnFrame() {
    if (!mounted) return;
    SessionScreen.debugTurnFrames++;
    final s = _tickFrom;
    if (s != null && _current(s)) _screen = s.screen;
    _gen++;
    _ui.ping();
    _scheduleModalSync();
  }

  bool _current(SapSession s) =>
      identical(_attempt, s) || identical(_session, s);

  /// Close [s] without letting its close fail the screen.
  Future<void> _closeQuietly(SapSession s) async {
    try {
      await s.close();
    } catch (_) {
      // already closed / the socket already gone
    }
  }

  /// The trace's last lines into [_connectLog] when they changed (not a
  /// copy of the whole log on every tick).
  void _pollTrace() {
    final log = _trace;
    if (log == null || log.isEmpty || !mounted) return;
    if (log.length == _traceLen && identical(log.last, _traceLast)) return;
    _traceLen = log.length;
    _traceLast = log.last;
    _connectLog.value = log.sublist(math.max(0, log.length - 6));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _backgroundSince ??= DateTime.now();
      case AppLifecycleState.resumed:
        final since = _backgroundSince;
        _backgroundSince = null;
        if (since != null) _checkAfterBackground();
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  /// Back from the background: a session whose socket closed meanwhile, or
  /// that stayed silent past [SessionScreen.idleLimit] (the app is
  /// suspended in the background: nothing kept the logon alive, the kernel
  /// or the OS has most likely ended it), is shown lost — never presented
  /// as a live screen that would only fail on the next key.
  void _checkAfterBackground() {
    final s = _session;
    if (!mounted || s == null || _error != null) return;
    final closed =
        s.closedByPeer ||
        s.state == SessionState.closed ||
        s.state == SessionState.failed;
    final idle = DateTime.now().difference(_lastActivity);
    if (!closed && idle < widget.idleLimit) {
      // within the idle limit: still probed — a socket that died silently
      // while suspended (NAT expiry, a network change) would only fail the
      // next key after its full timeout (the probe sends nothing)
      s.probeLiveness().then((alive) {
        if (alive || !mounted || !identical(_session, s)) return;
        _closeQuietly(s);
        setState(() {
          _lost = true;
          // the session's own close may have said why already
          _error ??= 'Session lost — reconnect. The connection did not '
              'survive the time GuiGo was in the background.';
        });
      });
      return;
    }
    // a silent logon the server may still hold is closed, so a reconnect
    // does not leave it behind
    _closeQuietly(s);
    setState(() {
      _lost = true;
      _error = closed
          ? 'Session lost — reconnect. The connection closed while GuiGo '
                'was in the background.'
          : 'Session lost — reconnect. No activity for '
                '${idle.inMinutes} min while GuiGo was in the background; '
                'the server has most likely ended the logon.';
    });
  }

  /// One logon at a time: a double-tapped Retry / Reconnect must not start
  /// a second logon beside the first (stacked password dialogs, two logons
  /// on the server).
  bool _connecting = false;

  Future<void> _connect() async {
    if (_connecting) return;
    _connecting = true;
    try {
      await _connectOnce();
    } finally {
      _connecting = false;
    }
  }

  Future<void> _connectOnce() async {
    // a retry / reconnect: the previous logon (a failed attempt, a lost or
    // closed session) is closed first — never left live on the server
    final previous = {?_attempt, ?_session};
    _attempt = null;
    _logTimer?.cancel();
    setState(() {
      _session = null;
      _screen = null;
      _lost = false;
      _busy = true;
      _error = null;
      _widestCols.clear();
    });
    for (final s in previous) {
      _closeQuietly(s);
    }
    _logTimer = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => _pollTrace(),
    );
    SapSession? session;
    try {
      // biometric gate before reading the stored password
      var (pw, fromStore) = await _gatePassword();
      if (!mounted) return; // left before the logon began
      String? refused;
      while (true) {
        if (pw == null) throw StateError(refused ?? 'logon cancelled');
        final attempt = session = _attempt = _newSession(pw);
        try {
          await attempt.connect();
          break;
        } on StateError catch (e) {
          if (!e.message.startsWith('logon refused')) rethrow;
          // SAP refused the password (changed / expired / mistyped): ask
          // again — one try per password, the user decides each retry
          if (identical(_attempt, attempt)) _attempt = null;
          session = null; // its close is no error of the screen's
          await attempt.close();
          if (!mounted) return;
          refused = e.message;
          pw = await _promptPassword(
            rejected: e.message.replaceFirst('logon refused: ', ''),
          );
          if (!mounted) return;
          fromStore = false;
        }
      }
      final live = session;
      // the screen was left (or a retry dropped this attempt) while the
      // logon ran: the logon is nobody's — closed, not abandoned live
      if (!mounted || !identical(_attempt, live)) {
        await _closeQuietly(live);
        return;
      }
      // a typed password SAP accepted is the current one: with "Store
      // password" on, it replaces whatever the store held
      if (!fromStore && _args.entry.storePassword && pw.isNotEmpty) {
        await _args.store.savePassword(_args.entry.id, pw);
      }
      if (!mounted || !identical(_attempt, live)) {
        await _closeQuietly(live);
        return;
      }
      _lastActivity = DateTime.now();
      setState(() {
        _session = live;
        _attempt = null;
        _screen = live.screen;
      });
      // the body may have changed size while the logon ran (a rotation)
      _scheduleResize();
    } catch (e) {
      // the failed attempt's socket and logon go with it
      final failed = session;
      if (failed != null) {
        if (identical(_attempt, failed)) _attempt = null;
        await _closeQuietly(failed);
      }
      if (mounted) setState(() => _fail(e));
    } finally {
      // the connect log was the logon's: no timer outlives it
      _logTimer?.cancel();
      _logTimer = null;
      if (mounted) {
        _pollTrace();
        setState(() => _busy = false);
      }
    }
  }

  /// A logon that can still take a key (not failed, not closed).
  bool get _live => _session != null && _error == null;

  /// The session of the logon attempt in progress (its events reach the
  /// screen; a refused attempt's do not).
  SapSession? _attempt;

  /// A session for one logon attempt, wired to the screen.
  SapSession _newSession(String password) {
    // the connect + logon frames are built from protocol fields
    // (diag_protocol logon_frames.dart); no recorded handshake ships
    Future<WallOption> onWall(WallInfo wall) {
      // the connection's choice: continue without ending the other
      // sessions (OPT2) when the dialog offers it
      if (_args.entry.keepOtherSessions &&
          wallRowFor(wall, WallOption.keepOthers) != null) {
        return Future.value(WallOption.keepOthers);
      }
      final c = Completer<WallOption>();
      if (mounted) {
        setState(() {
          _wallCompleter = c;
          _wall = wall;
        });
      }
      return c.future;
    }

    final system = _args.entry.toSystem();
    // the window the logon reports: this screen's body in SAP cells
    final (rows, cols) = sapWindowCells(_bodySize ?? _estimatedBodySize());
    final session =
        widget.sessionFactory?.call(system, password, onWall) ??
        SapSession(
          system: system,
          password: password,
          onWall: onWall,
          screenRows: rows,
          screenCols: cols,
          sizedWindow: true,
          // the recorded identity until a live A/B: the device profile's
          // logon drew 'invalid gui data' from the test system (2026-10-13)
          guiProfile: EmulatedGuiProfile.recordedWindowsGui,
        );
    // (a session from the factory learns it here: before the logon this
    // only sets the size the logon reports — no round)
    session.resizeWindow(rows, cols);
    // the ABAP editor's view capacity: what the session's LastVisibleLine
    // of a (re)loaded document is computed from before the view shows it
    session.editorViewLines = (shell) =>
        _editorViewLines[shell] ?? _editorRegionLines[shell];
    _trace = session.traceLog;
    _traceLen = -1;
    _traceLast = null;
    // every turn (and a window opened / closed / switched — DIAG modes:
    // the switcher and the active window's screen) is drawn on the next
    // frame, a burst of them once
    session.turns.listen((_) {
      if (mounted && _current(session)) _markTurn(session);
    });
    session.windowsChanged.listen((_) {
      if (mounted && _current(session)) _markTurn(session);
    });
    // the server opens a url in the web browser (a Web Dynpro / Fiori
    // start, a detached help page, an archived document): handed to the
    // platform as it arrives, signed on when the server armed SSO — the
    // session already answered the call and never waits on it
    session.browserLaunches.listen((launch) async {
      if (!mounted || !_current(session)) return;
      final why = await BrowserPlatform.openOrExplain(launch);
      if (why == null || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(why)),
      );
    });
    // the server's own close (idle auto-logout): surface it at once,
    // not on the next action
    session.closed.listen((why) {
      if (!mounted || !_current(session)) return;
      // a log-off (Système > Fin de session, /nex: the server's end of
      // conversation) is the end of the logon, not a lost connection: the
      // windows close, as on SAP GUI — nothing to reconnect
      if (session.loggedOff) {
        _closeModalRoute();
        Navigator.of(context).maybePop();
        return;
      }
      setState(() => _error = why);
    });
    return session;
  }

  /// The password for this logon and whether it came from the store:
  /// the stored one as [releaseStoredPassword] releases it (read only
  /// after Face ID / Touch ID / fingerprint when enrolled; used directly
  /// when none is), else typed (null when the user cancels).
  Future<(String?, bool)> _gatePassword() async {
    final store = _args.store;
    final id = _args.entry.id;
    final stored = await releaseStoredPassword(
      hasStored: () => store.hasPassword(id),
      biometricsEnrolled: () async =>
          (await _localAuth.getAvailableBiometrics()).isNotEmpty,
      authenticate: () => _localAuth.authenticate(
        localizedReason: 'Unlock the stored password for ${_args.entry.name}',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      ),
      read: () => store.readPassword(id),
    );
    if (stored != null) return (stored, true);
    return (await _promptPassword(), false);
  }

  /// Ask for the SAP password; [rejected] is SAP's message when the last
  /// one was refused. Null when the user cancels.
  Future<String?> _promptPassword({String? rejected}) {
    final why = rejected?.trim();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (c) => PasswordDialog(
        title: 'Logon to ${_args.entry.name}',
        error: why == null
            ? null
            : (why.isEmpty ? 'The password was refused.' : why),
        note: _args.entry.storePassword
            ? 'Stored securely once the logon succeeds.'
            : null,
        okLabel: 'Log on',
        submitOnEnter: true,
      ),
    );
  }

  /// Activate [key] of the screen's tree (the full-screen Easy Access
  /// tree, a tree beside a canvas): its node double-click event (a folder
  /// whose children are on the server: 18, then 25 —
  /// SapSessionTree.doubleClickTreeNode).
  Future<void> _activateScreenTreeNode(String key) => _run(() async {
    final sh = _session!.treeShell;
    if (sh == null) throw StateError('no tree control on this screen');
    await _session!.doubleClickTreeNode(sh, key);
  });

  /// The first row the view of tree [shell] shows: its TopNodeKey.
  void _treeTopNode(String? shell, String key) {
    if (shell != null) _session?.noteTreeTopNode(shell, key);
  }

  /// Whether tree [shell] handles a double-click (registered 25 / 22):
  /// the tree view then sends it for a folder too instead of toggling.
  bool _treeHandlesDoubleClick(String? shell) =>
      shell == null || _session?.treeDoubleClickEvent(shell) != null;

  /// A tap selected [key] of tree [shell]: the tree's selection (its
  /// SelectionKeys read-back), a 21 SELCHANGE round when it registered one.
  void _selectTreeNode(String? shell, String key) {
    final s = _session;
    if (s == null || shell == null) return;
    if (s.treeSelectionEventRegistered(shell)) {
      _run(() async => s.selectTreeNode(shell, key));
    } else {
      s.noteTreeSelection(shell, key);
    }
  }

  /// The folders tree [shell] holds open: the server's expansion and the
  /// user's toggles (SapSessionTree.treeExpandedKeys) — nothing else
  /// opens by default.
  Set<String>? _treeExpandedKeys(String? shell) =>
      shell == null ? null : _session?.treeExpandedKeys(shell);

  /// Folder [key] of tree [shell] was opened / closed on the client.
  void _toggledTreeNode(String? shell, String key, bool open) {
    if (shell != null) _session?.noteTreeExpansion(shell, key, open: open);
  }

  Future<void> _run(Future<void> Function() fn) async {
    if (_busy || _session == null) return;
    _busy = true;
    try {
      await fn();
    } catch (e) {
      if (mounted) _actionFailed(e);
    } finally {
      _lastActivity = DateTime.now();
      if (mounted) _busy = false;
    }
  }

  /// A part of the screen drawn from the session's state: rebuilt on a
  /// turn or a busy change, alone.
  Widget _region(WidgetBuilder builder) =>
      ListenableBuilder(listenable: _regionTick, builder: (c, _) => builder(c));

  /// A region that draws no busy state of its own (the body: its leaves
  /// read it through [SessionBusy]): rebuilt on a turn alone.
  Widget _turnRegion(WidgetBuilder builder) =>
      ListenableBuilder(listenable: _turnTick, builder: (c, _) => builder(c));

  /// A leaf of a [_turnRegion] that draws the busy state (a button's
  /// enablement): it alone rebuilds when busy flips.
  Widget _busyLeaf(Widget Function(bool busy) builder) =>
      ValueListenableBuilder<bool>(
        valueListenable: _busyN,
        builder: (_, busy, _) => builder(busy),
      );

  /// The on-screen keyboard's height over the screen (the Scaffold strips
  /// it from its body's MediaQuery), read without depending on it: the
  /// keyboard's slide re-lays the body out (its constraints shrink), and
  /// only that layout reads it — not a rebuild of the whole screen per
  /// animation frame.
  double _keyboardInset() =>
      context
          .getInheritedWidgetOfExactType<MediaQuery>()
          ?.data
          .viewInsets
          .bottom ??
      0;

  /// The body region of the current build: the body's LayoutBuilder hands
  /// the same widget to every layout of one build (the keyboard's slide
  /// lays it out per frame), so a layout alone rebuilds nothing below.
  Widget? _bodyRegion;

  /// The body was laid out at [size]: a new size reaches the server
  /// [_resizeDebounce] after it settles ([_applyWindowSize]).
  void _noteBodySize(Size size, {double keyboard = 0}) {
    if (!size.width.isFinite || !size.height.isFinite) return;
    // the on-screen keyboard shrinks the body, not the SAP window: keep the
    // height measured without it (a keyboard up for a field resized SM04's
    // grid to the half screen above it, and every toggle repainted)
    if (keyboard > 0 && _bodySize != null) {
      size = Size(size.width, _bodySize!.height);
    }
    if (_bodySize == size) return;
    _bodySize = size;
    _scheduleResize();
  }

  void _scheduleResize() {
    _resizeTimer?.cancel();
    _resizeTimer = Timer(_resizeDebounce, _applyWindowSize);
  }

  /// The body's size before it was ever laid out (the logon may start
  /// first): the screen less the app bar with its command row, the status /
  /// key bar and the system insets.
  Size _estimatedBodySize() {
    // read, not depended on: a dependency taken here (outside build)
    // rebuilt the whole screen on every MediaQuery change — each frame of
    // the keyboard's slide
    final mq = context.getInheritedWidgetOfExactType<MediaQuery>()?.data;
    if (mq == null) return Size.zero;
    const statusAndKeys = 56.0;
    return Size(
      mq.size.width - mq.padding.horizontal,
      mq.size.height -
          mq.padding.vertical -
          kToolbarHeight -
          48 - // the command row (the app bar's bottom)
          statusAndKeys,
    );
  }

  /// Tell the live session the window's new size ([SapSession
  /// .resizeWindow]: the resize round on a screen whose layout follows the
  /// window, else the size rides the next round). Only on a live logon
  /// between actions — while one runs it waits for the next quiet moment;
  /// an unchanged size sends nothing.
  Future<void> _applyWindowSize() async {
    final s = _session;
    final size = _bodySize;
    if (!mounted || s == null || size == null || !_live) return;
    if (s.state != SessionState.ready) return;
    final (rows, cols) = sapWindowCells(size);
    if (rows == s.screenRows && cols == s.screenCols && s.ctx.windowSized) {
      return;
    }
    if (_busy || s.busy) {
      _scheduleResize(); // after the running action
      return;
    }
    _busy = true;
    try {
      await s.resizeWindow(rows, cols);
    } catch (_) {
      // a resize the server did not answer is no failure of the screen: the
      // size rides the next round anyway
    } finally {
      if (mounted) _busy = false;
    }
    if (mounted && _current(s)) setState(() => _screen = s.screen);
  }

  @override
  Widget build(BuildContext context) {
    SessionScreen.debugScaffoldBuilds++;
    _bodyRegion = null;
    _refreshTypeAhead();
    final body = DynproZoomScope(
      widest: _widestCols,
      child: SessionBusy(
        busy: _busyN,
        child: PopScope(
        // the edge-swipe back is SAP's Back (F3) too while a session is live
        canPop: !_live,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _live && !_busy && _keyActive(3)) {
            _run(() async => _session!.press(3));
          }
        },
        child: Scaffold(
          appBar: AppBar(
            // SAP GUI's Back (F3), not the app's navigation: leaving the
            // session is the log-off button on the right (without a live
            // session — an error, a closed logon — it leaves the screen)
            // a live session's Back is the command row's (SAP GUI's standard
            // toolbar); the app's own arrow only closes a failed / closed logon
            automaticallyImplyLeading: false,
            // a live session's leading slot is SAP GUI's menu bar (Menu /
            // Edit / … / System / Help) behind one button: the bar of the
            // screen on top (a popup paints none)
            leading: _live
                ? _region((_) {
                    final m = _screen;
                    // a popup blocks the window's menus, as in SAP GUI
                    final modal = (m?.modalLevel ?? 0) > 0;
                    return SapMenuButton(
                      bar: modal ? const [] : m?.menuBar ?? const [],
                      tree: m?.menuTree ?? const [],
                      busy: _busy,
                      onSelect: (e) => _run(() async {
                        final s = _session!;
                        // the menu round names the field the focus is in,
                        // as SAP GUI's does (a field of THIS screen only)
                        final focus = _focus;
                        await s.selectMenu(
                          e,
                          cursor: focus != null && identical(focus.$1, s.screen)
                              ? focus.$2
                              : null,
                        );
                      }),
                    );
                  })
                : IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
            title: _turnRegion((_) {
              final m = _screen;
              final title = m?.title.isEmpty ?? true
                  ? '${_args.entry.name} — ${m?.tcode ?? _args.entry.client}'
                  : m!.title;
              return Text(title, overflow: TextOverflow.ellipsis);
            }),
            actions: [
              _region((_) => _windowSwitcher() ?? const SizedBox.shrink()),
              ValueListenableBuilder<bool>(
                valueListenable: _busyN,
                builder: (_, busy, _) => busy
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              // the system and its application server (SAP GUI's status
              // field, its dropdown choice kept), beside the lock
              _turnRegion(
                (_) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: _systemInfo(_session?.baseScreen ?? _screen),
                ),
              ),
              const SizedBox(width: 8),
              if (_plaintext)
                IconButton(
                  // a wide-OPEN lock in warning orange: Material's
                  // lock_open reads as closed at this size
                  icon: const OpenLockIcon(color: Colors.orange),
                  tooltip: 'Not encrypted',
                  onPressed: _showPlaintextNotice,
                ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(48),
              child: _region((_) => _commandBar()),
            ),
          ),
          body: LayoutBuilder(
            key: SessionScreen.bodyKey,
            builder: (context, cons) {
              _noteBodySize(
                cons.biggest,
                // the screen's own context: the Scaffold strips the
                // keyboard inset from its body's MediaQuery
                keyboard: _keyboardInset(),
              );
              // the keyboard does not squeeze the screen: it keeps the
              // height it had without it (so the composer's scale, and
              // every element's width, stay) and scrolls under the
              // keyboard instead — a focused field scrolls itself into
              // view. One widget shape with or without the keyboard, so
              // the focused field is not remounted when it comes up.
              final keyboardUp = _keyboardInset() > 0;
              final full = _bodySize?.height ?? cons.maxHeight;
              final height = keyboardUp && full > cons.maxHeight
                  ? full
                  : cons.maxHeight;
              return SingleChildScrollView(
                child: SizedBox(
                  width: cons.maxWidth,
                  height: height,
                  child: _bodyRegion ??= _turnRegion((_) {
                    SessionScreen.debugBodyBuilds++;
                    final m = _screen;
                    return _error != null
                        ? _errorView()
                        : m == null
                        ? _connectingView()
                        : _withPlaintextBanner(
                            _withRemoteLogonBanner(_sessionStack(m)),
                          );
                  }),
                ),
              );
            },
          ),
          bottomNavigationBar: _region((_) => _statusAndKeys(_screen)),
        ),
        ),
      ),
    );
    return _withTypeAhead(context, body);
  }

  /// No SNC on this logon: the DIAG stream — the logon included — travels
  /// compressed, not encrypted (SECURITY.md, README).
  bool get _plaintext => (_session ?? _attempt)?.snc == null;

  static const _plaintextText =
      'This connection is not encrypted: the DIAG stream — your logon '
      'included — travels compressed but in clear text. Use a VPN or '
      'another secured network path to reach the SAP system.';

  void _showPlaintextNotice() {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const OpenLockIcon(),
        title: const Text('Unencrypted connection'),
        content: const Text(_plaintextText),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// The unencrypted-connection notice over the first logon of a
  /// connection, until the user dismisses it (the app-bar icon keeps it
  /// one tap away).
  Widget _withPlaintextBanner(Widget body) {
    if (!_plaintext || _plaintextSeen) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MaterialBanner(
          leading: const OpenLockIcon(),
          content: const Text(_plaintextText),
          actions: [
            TextButton(
              onPressed: () {
                setState(() => _plaintextSeen = true);
                _args.store.markPlaintextNoticeSeen(_args.entry.id);
              },
              child: const Text('Got it'),
            ),
          ],
        ),
        Expanded(child: body),
      ],
    );
  }

  /// A REMOTE logon on screen — a transaction's cross-system RFC logon
  /// relayed from its target (SapSession.remoteLogon: SAPMSYST/0029 naming
  /// another system than this logon's): say whose logon it is and who asks.
  /// The USER types the target's credentials into the painted fields;
  /// GuiGo never fills or stores them.
  Widget _withRemoteLogonBanner(Widget body) {
    final s = _session;
    final r = s?.remoteLogon;
    if (s == null || r == null) return body;
    final home = s.homeSystem?.sid ?? _args.entry.name;
    final scheme = Theme.of(context).colorScheme;
    final host = r.host.isEmpty ? '' : ' (${r.host})';
    final client = r.client.isEmpty ? '' : ' client ${r.client}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: scheme.tertiaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.swap_horiz, color: scheme.onTertiaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Logon to ${r.sysid}$host$client requested by $home',
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(color: scheme.onTertiaryContainer),
                      ),
                      Text(
                        'Enter the ${r.sysid} credentials yourself — GuiGo '
                        'does not fill or store them.',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: scheme.onTertiaryContainer),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: body),
      ],
    );
  }

  /// The logon's windows (one per DIAG mode — `/o<tcode>`, *Créer
  /// session*, a window the server opened) as a segmented row in the app
  /// bar, shown only while more than one is open; picking one makes it the
  /// session's active window (nothing goes on the wire).
  Widget? _windowSwitcher() {
    final s = _session;
    final wins = s?.windows ?? const <SapWindow>[];
    if (s == null || wins.length < 2) return null;
    // the server may title two windows alike (`(1)`): name them apart
    final dup = wins.map((w) => w.number).toSet().length < wins.length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SegmentedButton<int>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: [
          for (final w in wins)
            ButtonSegment<int>(
              value: w.mode,
              label: Text(
                dup ? '(${w.number}) ${w.program ?? ''}' : '(${w.number})',
              ),
              tooltip: [
                if (w.title.isNotEmpty) w.title else 'Window ${w.number}',
                ?w.program,
              ].join(' — '),
            ),
        ],
        selected: {s.activeMode},
        onSelectionChanged: _busy
            ? null
            : (sel) => _run(() async {
                await s.selectWindow(sel.single);
                if (mounted) setState(() => _screen = s.screen);
                if (mounted && s.activeWindow.suspect) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(
                      content: Text(
                        'This window missed server updates while in the '
                        'background; if it does not respond, close it.',
                      ),
                    ),
                  );
                }
              }),
      ),
    );
  }

  /// The base window behind whatever modal dialog is open. The modal
  /// itself is a dialog ROUTE above this screen — a real modal with a
  /// full-screen barrier; while it is open this body renders the covered
  /// base window, inert.
  Widget _sessionStack(ScreenModel m) {
    final modalActive = m.modalLevel > 0 || _wallCompleter != null;
    final base = m.modalLevel > 0 ? (_session?.baseScreen ?? m) : m;
    // a screen built around a tree control (the Easy Access menu) shows the
    // tree; its dynpro carries no fields of its own
    // a composed window (docking panes, splitter cells, hosted controls
    // around the dynpro — DB50/0100): drawn the way the reference client's renderer
    // carves it, every region at its window cells
    final view = _session == null ? null : _viewOf(_session!);
    final regions = view?.regions ?? const <ScreenRegion>[];
    // composed only when a region beside the dynpro draws something: the
    // Easy Access window is a field-less dynpro plus an IMAGE_CONTAINER
    // whose hosted tree the layout does not bind (R9 "no hosted shell
    // known") — that screen stays the full-screen tree below
    final content = [
      for (final r in regions)
        if (r.kind != 'dynpro' &&
            (r.gauge != null || (r.shell != null && _hasContent(r.shell!))))
          r,
    ];
    // a list whose dynpro paints nothing but its one grid (SE16's result,
    // SAPLSLVC_FULLSCREEN) is the full-screen grid below: SAP GUI fills the
    // window with it, whatever box the container was painted at
    final soleGrid =
        content.length == 1 &&
        content.single.kind == 'grid' &&
        base.fields.every(
          (f) =>
              (f.kind == FieldKind.output || f.kind == FieldKind.label) &&
              f.text.trim().isEmpty,
        );
    final composed = content.isNotEmpty && !soleGrid;
    if (composed) {
      final panes = _composedPanes(base, regions, modalActive);
      return IgnorePointer(
        ignoring: modalActive,
        child: Opacity(
          opacity: modalActive ? 0.6 : 1.0,
          child: SapIconAtlasStrip(
            atlas: _icons,
            child: ScreenComposer(
              resizeKey: base.program,
              fixedSashes: [
                for (final r in regions)
                  if (r.kind == 'sash')
                    Rect.fromLTWH(
                      r.rect.col,
                      r.rect.row,
                      r.rect.cols,
                      r.rect.rows,
                    ),
              ],
              window: _stableExtent(base.program, panes),
              // the session's own window: its rows end at the body's bottom
              fillHeight: true,
              panes: panes,
              onDockResize: _dockResized,
            ),
          ),
        ),
      );
    }
    // a full-screen ALV grid (the SE16 result list) shows the grid; its
    // dynpro paints nothing but blank padding
    final grid = _session?.grid;
    final paintsNothing = base.fields.every(
      (f) =>
          (f.kind == FieldKind.output || f.kind == FieldKind.label) &&
          f.text.trim().isEmpty,
    );
    if (grid != null && paintsNothing) {
      return IgnorePointer(
        ignoring: modalActive,
        child: Opacity(
          opacity: modalActive ? 0.6 : 1.0,
          child: _gridView(grid, menu: true),
        ),
      );
    }
    // a designer canvas screen (the BW network planner: a document tree
    // beside the canvas): the tree's rows drag onto the canvas
    final canvases = view?.canvases ?? const <SapCanvasModel>[];
    if (canvases.isNotEmpty && paintsNothing) {
      final tree = _session?.tree;
      return IgnorePointer(
        ignoring: modalActive,
        child: Opacity(
          opacity: modalActive ? 0.6 : 1.0,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (tree != null && !tree.isEmpty)
                SizedBox(
                  width: 280,
                  child: SapTreeView(
                    tree: tree,
                    busy: modalActive,
                    dragShell: _session?.treeShell,
                    onRunTcode: (tcode) =>
                        _run(() async => _session!.okcode('/n$tcode')),
                    onExpand: (key) =>
                        _run(() async => _session!.expandTreeNode(key)),
                    onActivate: _activateScreenTreeNode,
                    handlesDoubleClick: _treeHandlesDoubleClick(
                      _session?.treeShell,
                    ),
                    onSelect: (key) =>
                        _selectTreeNode(_session?.treeShell, key),
                    onToggle: (key, open) =>
                        _toggledTreeNode(_session?.treeShell, key, open),
                    onTopNode: (key) => _treeTopNode(_session?.treeShell, key),
                    expandedKeys: _treeExpandedKeys(_session?.treeShell),
                    onContextMenu: (key, at) {
                      final sh = _session?.treeShell;
                      if (sh != null) _treeMenu(sh, key, at);
                    },
                  ),
                ),
              if (tree != null && !tree.isEmpty)
                const VerticalDivider(width: 1),
              Expanded(child: _canvasView(canvases.first)),
            ],
          ),
        ),
      );
    }
    // a dynpro that is only a network graph (STMS transport routes): the
    // graph is the screen
    final graphs = view?.netPlans ?? const <SapNetPlanModel>[];
    if (graphs.isNotEmpty && paintsNothing) {
      return IgnorePointer(
        ignoring: modalActive,
        child: Opacity(
          opacity: modalActive ? 0.6 : 1.0,
          child: _netPlanView(graphs.first),
        ),
      );
    }
    final tree = _session?.tree;
    if (tree != null && !tree.isEmpty && base.fields.isEmpty) {
      return IgnorePointer(
        ignoring: modalActive,
        child: Opacity(
          opacity: modalActive ? 0.6 : 1.0,
          child: SapTreeView(
            tree: tree,
            busy: modalActive,
            onRunTcode: (tcode) =>
                _run(() async => _session!.okcode('/n$tcode')),
            onExpand: (key) => _run(() async => _session!.expandTreeNode(key)),
            // the Easy Access double-click: `%_GC 105 25` + ABAPSelNodeKey
            // (a recorded session gui[39]), never a typed /n<tcode>
            onActivate: _activateScreenTreeNode,
            handlesDoubleClick: _treeHandlesDoubleClick(_session?.treeShell),
            onSelect: (key) => _selectTreeNode(_session?.treeShell, key),
            onToggle: (key, open) =>
                _toggledTreeNode(_session?.treeShell, key, open),
            onTopNode: (key) => _treeTopNode(_session?.treeShell, key),
            expandedKeys: _treeExpandedKeys(_session?.treeShell),
            onContextMenu: (key, at) {
              final sh = _session?.treeShell;
              if (sh != null) _treeMenu(sh, key, at);
            },
          ),
        ),
      );
    }
    return IgnorePointer(
      ignoring: modalActive,
      child: Opacity(
        opacity: modalActive ? 0.6 : 1.0,
        child: SapIconAtlasStrip(
          atlas: _icons,
          child: DynproView(
            onEdit: _stageEdit,
            onValueHelp: _valueHelp,
            onFocusField: _focusField,
            onContextMenu: _screenMenu,
            onListPick: _listPick,
            onListCursor: _placeListCursor,
            onListCell: _stageListCell,
            onListScroll: _listScroll,
            onDoubleClick: _doubleClick,
            model: base,
            busy: modalActive,
            controls: _hostedControls(),
            onFill: _fillField,
            onPress: (vkey) => _run(() async => _session!.press(vkey)),
            onOkcode: (cmd) => _run(() async => _session!.okcode(cmd)),
            onRadio: (group, chosen) =>
                _run(() async => _session!.selectRadio(group, chosen)),
          ),
        ),
      ),
    );
  }

  /// The composed body of a popup with hosted controls and its width, or
  /// null when the popup is a plain dynpro.
  (Widget, double)? _composedModal(ScreenModel popup) {
    final regions = _session == null
        ? const <ScreenRegion>[]
        : _viewOf(_session!).modalRegions;
    final hosts = regions.any(
      (r) => r.kind != 'dynpro' && r.shell != null && _hasContent(r.shell!),
    );
    if (!hosts) return null;
    final panes = _composedPanes(popup, regions, false);
    final extent = ScreenComposer.extentOf(panes);
    const cw = 10.0;
    final size = Size(
      extent.width * cw,
      extent.height * cw * ScreenComposer.cellAspect,
    );
    return (
      SizedBox.fromSize(
        size: size,
        child: SapIconAtlasStrip(
          atlas: _icons,
          child: ScreenComposer(
            panes: panes,
            fixedSashes: [
              for (final r in regions)
                if (r.kind == 'sash')
                  Rect.fromLTWH(
                    r.rect.col,
                    r.rect.row,
                    r.rect.cols,
                    r.rect.rows,
                  ),
            ],
          ),
        ),
      ),
      size.width,
    );
  }

  /// An ALV grid with its selection wired to the session: a header tap
  /// selects columns, a row-number tap rows — staged, they ride the next
  /// frame as the real GUI's GridView.ocx sends them (SelectedCols /
  /// SelectedRows DATACHANGES). [menu] adds the header menu acting through
  /// the ALV standard keys of a main-window grid: Ctrl+F4 sort ascending
  /// (vkey 28), Ctrl+Shift+F4 descending (40), Ctrl+F5 filter (29).
  Widget _gridView(SapGridModel grid, {bool menu = false}) {
    void stage(void Function(SapSession s) f) {
      final s = _session;
      if (s == null) return;
      try {
        f(s);
      } on UnsupportedError catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Selection not sent: ${e.message}')),
        );
      } on RangeError catch (_) {
        // a line the grid has not delivered: nothing to stage
      }
    }

    final view = SapGridView(
      key: ValueKey('grid-${grid.shell}'),
      columns: grid.columns,
      titles: grid.titles,
      widths: grid.widths,
      rows: grid.rows,
      totalRows: grid.totalRows,
      onColumnsSelected: (ids) =>
          stage((s) => s.selectGridColumns(grid.shell, ids)),
      onCellValueHelp: (line, col) =>
          _run(() async => _session!.gridCellValueHelp(grid.shell, line, col)),
      // the double-click on a cell (ST22 opens the dump, SE16 the record):
      // `%_GC <grid> 3`, only on a grid that registered it
      onCellDoubleTap:
          _session?.gridHandlesEvent(grid.shell, gridEventDoubleClick) ?? false
          ? (line, col) =>
                _run(() => _session!.gridDoubleClick(grid.shell, line, col))
          : null,
      // a hotspot cell's single tap: `%_GC <grid> 2`
      hotspotColumns: grid.hotspotColumns,
      hotspotCells: grid.hotspotCells,
      onHotspotTap:
          grid.hasHotspots &&
              (_session?.gridHandlesEvent(grid.shell, gridEventHotspotClick) ??
                  false)
          ? (line, col) =>
                _run(() => _session!.gridHotspotClick(grid.shell, line, col))
          : null,
      modifiedCells: grid.modifiedCells,
      onRowsSelected: (rows) =>
          stage((s) => s.selectGridRows(grid.shell, rows)),
      // the rows past the pushed block: fetched as they scroll into view,
      // the way the real GUI's DATAREQUEST asks for them
      rowCount: grid.totalRows ?? grid.rows.length,
      // one closure per grid model, so the view's `identical` re-push
      // guard only fires when the rows really changed (a new model)
      rowAt: gridRowAt(grid),
      onNeedRows: (line, top) async {
        if (_busy || _session == null) return false; // asked again shortly
        await _run(() async {
          try {
            await _session!.fetchGridRows(
              grid.shell,
              line,
              firstVisibleRow: top,
            );
          } on StateError {
            // no on-demand provider: the grid holds all it will get
          } on RangeError {
            // past the grid's end
          }
        });
        return true;
      },
      onColumnAction: !menu
          ? null
          : (action, _) {
              final vkey = switch (action) {
                'sortAsc' => 28,
                'sortDesc' => 40,
                _ => 29,
              };
              _run(() async => _session!.press(vkey));
            },
    );
    // the grid's own toolbar above it, as GridView.ocx draws it
    final toolbar = _controlToolbar(grid.shell);
    if (toolbar == null) return view;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        toolbar,
        Expanded(child: view),
      ],
    );
  }

  /// The CFW control toolbar whose events go to [shell] (a grid's own, a
  /// SAP.Toolbar.1 — sap_control_toolbar.dart), null when it has none: a
  /// press is the toolbar's function event, a menu button opens the
  /// server's menu through [_controlMenu] (a static one with no round).
  Widget? _controlToolbar(String shell) {
    final s = _session;
    if (s == null) return null;
    final tb = _viewOf(s).controlToolbars[shell];
    if (tb == null || tb.buttons.every((b) => b.separator)) return null;
    return SapControlToolbarView(
      key: ValueKey('ctb-$shell'),
      buttons: tb.buttons,
      icons: _icons,
      onPressed: (fcode) =>
          _run(() async => _session!.toolbarButton(shell, fcode)),
      onDropdown: (fcode, at) => _controlMenu(
        shell,
        at,
        () => _session!.toolbarDropdown(
          shell,
          fcode,
          x: at.dx.round(),
          y: at.dy.round(),
        ),
      ),
    );
  }

  /// The composed window's extent: the SAP window the server laid the
  /// screen out in (the paint's 16/12/7 window pair) — the scale holds
  /// while the user moves between its screens (ST04's tree picks swap the
  /// detail panes) and follows the server when it lays the window out
  /// anew (a rotation's resize round). Without a pair: the largest extent
  /// the panes reached in the current transaction (by program).
  ///
  /// The largest-extent rule alone kept a window the server had since laid
  /// out SMALLER: after the resize round of a rotation (the reset keyed on
  /// GuiGo's own size ran on the build before the server's repaint, with
  /// the old, wider panes) every pane of the new layout was drawn in the
  /// old width — the live iPad ST04 load history ended its grids at ~79 %
  /// and its message strip at ~72 % of the body.
  String? _extentProgram;
  (int?, int?)? _extentWindow;
  Size? _extentMax;

  Size? _stableExtent(String? program, List<ComposedPane> panes) {
    final painted = _session?.windowExtent;
    if (painted != null && painted.$1 > 0 && painted.$2 > 0) {
      _extentMax = null; // a pair-less screen later starts over
      return Size(painted.$2.toDouble(), painted.$1.toDouble());
    }
    final e = ScreenComposer.extentOf(panes);
    // a new window size (a rotation) lays the screen out anew: the zoom
    // starts over from it
    final window = (_session?.screenRows, _session?.screenCols);
    if (program != _extentProgram ||
        _extentMax == null ||
        window != _extentWindow) {
      _extentProgram = program;
      _extentWindow = window;
      _extentMax = e;
    } else {
      _extentMax = Size(
        math.max(_extentMax!.width, e.width),
        math.max(_extentMax!.height, e.height),
      );
    }
    return _extentMax;
  }

  /// The least height a control pane lays out at; a shorter pane clips it.
  static const double _minPaneHeight = 72;

  /// ABAP editor shell -> the lines its laid-out SapSourceView shows
  /// ([SapSourceView.onViewLines]), and -> the lines the pane the composer
  /// gives it would show ([SapSourceView.linesFitting] of its height): the
  /// session's [SapSession.editorViewLines], the view's own count first.
  final Map<String, int> _editorViewLines = {};
  final Map<String, int> _editorRegionLines = {};

  /// The height a control toolbar's button row is drawn at (its 30-px
  /// buttons and the scroll bar's 6-px strip).
  static const double _controlRowHeight = 36;

  /// A control row [c] in its pane ([cons]): laid out in the pane's own
  /// height, a [scaled] one (a toolbar's buttons) drawn at
  /// [_controlRowHeight] and scaled down to a pane shorter than that. Laid
  /// out in the [_minPaneHeight] and clipped like the other panes, a
  /// one-cell row showed only the top edge of its controls: SE80's dock
  /// (live iPad landscape, 68 rows: ~16-px rows) drew its toolbars as
  /// empty boxes and a bare blue bar — each button stretched to the 72 px,
  /// its icon and text centered below the cut — and its combo box / input
  /// field row as nothing.
  ///
  /// A toolbar row at least [_compactRowHeight] tall lays its buttons out
  /// AT its height ([ControlRowExtent]: icon and label sized to it) — the
  /// natural 36-px row scaled into a one-cell row drew /AIF/IFMON's ALV
  /// tree toolbar ("Synthèse des messages", "Dernier transfert", …) at
  /// under half size across a pane with room to spare; only a row shorter
  /// than that is the compact row scaled down.
  static Widget _controlRow(
    Widget c,
    BoxConstraints cons, {
    required bool scaled,
  }) {
    final h = cons.maxHeight, w = cons.maxWidth;
    if (!scaled ||
        !h.isFinite ||
        !w.isFinite ||
        h <= 0 ||
        h >= _controlRowHeight) {
      return c;
    }
    if (h >= _compactRowHeight) return ControlRowExtent(height: h, child: c);
    final k = h / _compactRowHeight;
    return FittedBox(
      fit: BoxFit.contain,
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: w / k,
        height: _compactRowHeight,
        child: ControlRowExtent(height: _compactRowHeight, child: c),
      ),
    );
  }

  /// The least height a toolbar row lays its buttons out at (a shorter
  /// one is scaled down from it).
  static const double _compactRowHeight = 14;

  /// One region per control shell: the layout can name a hosted control
  /// both at its container and at its own box (ST04's INI-file tree drew
  /// twice, a row apart); the smallest box is the control's own.
  List<ScreenRegion> _onePerShell(List<ScreenRegion> regions) {
    final best = <String, ScreenRegion>{};
    for (final r in regions) {
      final sh = r.shell;
      if (sh == null || !_hasContent(sh)) continue;
      final b = best[sh];
      if (b == null || r.rect.rows * r.rect.cols < b.rect.rows * b.rect.cols) {
        best[sh] = r;
      }
    }
    return [
      for (final r in regions)
        if (r.shell == null ||
            !best.containsKey(r.shell) ||
            identical(best[r.shell], r))
          r,
    ];
  }

  /// The session's controls as one build sees them: the session builds
  /// its models on every read (every tree, every grid …), and a composed
  /// window asks for each shell twice — read once per generation of the
  /// screen ([_gen]: a turn, a busy change, a setState).
  _SessionView? _view;

  _SessionView _viewOf(SapSession s) {
    final v = _view;
    if (v != null && v.gen == _gen && identical(v.session, s)) return v;
    return _view = _SessionView(s, _gen);
  }

  /// Whether the session holds drawable content for a control shell.
  bool _hasContent(String shell) {
    final s = _session;
    if (s == null) return false;
    final v = _viewOf(s);
    final tree = v.trees[shell];
    return (tree != null && !tree.isEmpty) ||
        v.htmlDocuments.any((d) => d.shell == shell && d.html.isNotEmpty) ||
        v.editors.any((e) => e.shell == shell) ||
        v.grids.containsKey(shell) ||
        v.charts.any((c) => c.shell == shell) ||
        v.netPlans.any((g) => g.shell == shell) ||
        v.canvases.any((c) => c.shell == shell) ||
        s.calendarFor(shell) != null ||
        v.drawnPictures.contains(shell) ||
        v.controlToolbars.containsKey(shell) ||
        s.officeDocuments.containsKey(shell);
  }

  /// The panes of a composed window: every region at its window cells —
  /// except the regions lying ON the dynpro (its custom-control areas: the
  /// DB50 overview's bars, a chart, the grids of a splitter in one), which
  /// are drawn on the dynpro's own canvas at their dynpro cells. As panes
  /// of their own they stayed at their window cells when a sash drag moved
  /// the dynpro pane (the live ST04 overview: the memory bars overflowing
  /// the "Mémoire" box with the sash right, inside the disk box with it
  /// left), and their cells widened the window when they reached past the
  /// dynpro's area.
  List<ComposedPane> _composedPanes(
    ScreenModel base,
    List<ScreenRegion> regions,
    bool modal,
  ) {
    final all = _onePerShell(regions);
    final dyn = all.where((r) => r.kind == 'dynpro').firstOrNull?.rect;
    bool onDynpro(ScreenRegion r) {
      if (dyn == null || r.kind == 'dynpro' || r.kind == 'sash') return false;
      const e = 0.01;
      final c = r.rect;
      return c.row >= dyn.row - e &&
          c.col >= dyn.col - e &&
          c.row + c.rows <= dyn.row + dyn.rows + e &&
          c.col + c.cols <= dyn.col + dyn.cols + e;
    }

    final nested = <(Rect, String?, ComposedPane)>[
      for (final r in all)
        if (onDynpro(r))
          if (_regionPane(base, r, modal) case final p?)
            (
              Rect.fromLTWH(
                r.rect.col - dyn!.col,
                r.rect.row - dyn.row,
                r.rect.cols,
                r.rect.rows,
              ),
              r.container ?? r.shell,
              p,
            ),
    ];
    final s = _session;
    // the free sashes of the splitters drawn ON the dynpro (their cells
    // are overlays there, not composer panes): a grip each, the drag the
    // client's own (SplitterSashGrip, SapSession.noteSplitterSash)
    final sashes = dyn == null || s == null || modal
        ? const <SplitterSash>[]
        : [
            for (final sh in _viewOf(s).sashes)
              if (!sh.fixed &&
                  sh.line.row >= dyn.row - 0.01 &&
                  sh.line.col >= dyn.col - 0.01 &&
                  sh.line.row + sh.line.rows <= dyn.row + dyn.rows + 0.01 &&
                  sh.line.col + sh.line.cols <= dyn.col + dyn.cols + 0.01 &&
                  (sh.rows ? sh.line.cols : sh.line.rows) > 0)
                sh,
          ];
    return [
      for (final r in all)
        if (!onDynpro(r))
          if (_regionPane(
                base,
                r,
                modal,
                nested: nested,
                sashes: sashes,
                origin: dyn == null ? Offset.zero : Offset(dyn.col, dyn.row),
              )
              case final p?)
            r.kind == 'dynpro' || s == null
                ? p
                : p.withDock(
                    s.dockOf(r.shell ?? '') ?? s.dockOf(r.container ?? ''),
                  ),
    ];
  }

  /// The user dragged sash [sh] of a splitter drawn on the dynpro: its
  /// cells now span [extents]. The session holds the layout (its regions
  /// re-lay out at once) and reports the resized cells with the next round
  /// ([SapSession.noteSplitterSash]); nothing is sent now.
  void _sashMoved(SplitterSash sh, List<int> extents) {
    final s = _session;
    if (!mounted || s == null) return;
    s.noteSplitterSash(sh.splitter, rows: sh.rows, extents: extents);
    setState(() {});
  }

  /// The user dragged the edge of docking container [dock] to [cols]
  /// window cells ([ScreenComposer.onDockResize]): the session realizes the
  /// new extent at once (its regions follow) and reports it in the layout
  /// round, now or with the next paint ([SapSession.resizeDock]); the
  /// server then lays the dynpro area out to it.
  Future<void> _dockResized(String dock, double cols) async {
    final s = _session;
    if (!mounted || s == null) return;
    final wasBusy = _busy;
    if (!wasBusy) _busy = true;
    final round = s.resizeDock(dock, cols); // the regions follow at once
    setState(() {});
    try {
      await round;
    } catch (_) {
      // a round the server did not answer: the extent rides the next one
    } finally {
      if (mounted && !wasBusy) _busy = false;
    }
    if (mounted && _current(s)) setState(() => _screen = s.screen);
  }

  /// One region of a composed window as a pane, by the reference client's rung:
  /// R1 the dynpro grid, R2 a hosted tree / table, R5 a gauge from its
  /// paired field, a chart / network graph / canvas by its shell, R7 (no
  /// content delivered yet) a dashed placeholder with the reference client's legend.
  /// Null for a region that paints nothing.
  ///
  /// The dynpro's pane draws [nested] — the regions on it, at their dynpro
  /// cells — on its canvas ([_composedPanes]).
  ComposedPane? _regionPane(
    ScreenModel base,
    ScreenRegion r,
    bool modal, {
    List<(Rect, String?, ComposedPane)> nested = const [],
    List<SplitterSash> sashes = const [],
    Offset origin = Offset.zero,
  }) {
    if (r.kind == 'sash') return null; // a fixed divider: nothing to draw
    final cells = Rect.fromLTWH(
      r.rect.col,
      r.rect.row,
      r.rect.cols,
      r.rect.rows,
    );
    if (r.kind == 'dynpro') {
      return ComposedPane(
        cells: cells,
        main: true,
        builder: (context, cell) => DynproView(
          onEdit: _stageEdit,
          onValueHelp: _valueHelp,
          onFocusField: _focusField,
          onContextMenu: _screenMenu,
          onListPick: _listPick,
          onListCursor: _placeListCursor,
          onListCell: _stageListCell,
          onListScroll: _listScroll,
          onDoubleClick: _doubleClick,
          model: base,
          busy: modal,
          cell: cell,
          overlays: [
            for (final (cells, id, p) in nested)
              DynproOverlay(
                cells,
                id: id,
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      width: 0.5,
                    ),
                  ),
                  child: p.builder(context, cell),
                ),
              ),
            for (final sh in sashes)
              DynproOverlay(
                SplitterSashGrip.cellsOf(sh, origin),
                id: 'sash-${sh.splitter}-${sh.rows ? 'r' : 'c'}${sh.index}',
                minPoints: const Size.square(SplitterSashGrip.hitPoints),
                const SizedBox.shrink(),
                builder: (canvasCell) => SplitterSashGrip(
                  key: ValueKey(
                    'sash-${sh.splitter}-${sh.rows ? 'r' : 'c'}${sh.index}',
                  ),
                  sash: sh,
                  cell: canvasCell,
                  onMoved: (extents) => _sashMoved(sh, extents),
                ),
              ),
          ],
          onFill: _fillField,
          onPress: (vkey) => _run(() async => _session!.press(vkey)),
          onOkcode: (cmd) => _run(() async => _session!.okcode(cmd)),
          onRadio: (group, chosen) =>
              _run(() async => _session!.selectRadio(group, chosen)),
        ),
      );
    }
    final gauge = r.gauge;
    if (gauge != null) {
      return ComposedPane(
        cells: cells,
        builder: (context, cell) => Padding(
          padding: EdgeInsets.symmetric(vertical: cell.height * 0.15),
          child: SapGauge(fraction: gauge, text: r.gaugeText ?? ''),
        ),
      );
    }
    final shell = r.shell;
    Widget? content;
    String? editorShell; // the ABAP editor the pane shows
    // the generation's snapshot ([_viewOf]): every pane of a composed
    // window read every model afresh — each read rebuilds every tree and
    // grid of the session (audit #15)
    final view = _session == null ? null : _viewOf(_session!);
    if (shell != null) {
      final tree = view?.trees[shell];
      final grid = view?.grids[shell];
      final chart = (view?.charts ?? const <SapChartModel>[]).where(
        (c) => c.shell == shell,
      );
      final graph = (view?.netPlans ?? const <SapNetPlanModel>[]).where(
        (g) => g.shell == shell,
      );
      final canvas = (view?.canvases ?? const <SapCanvasModel>[]).where(
        (c) => c.shell == shell,
      );
      final html = (view?.htmlDocuments ?? const <SapHtmlDocument>[]).where(
        (d) => d.shell == shell && d.html.isNotEmpty,
      );
      final editor = (view?.editors ?? const <SapTextEditor>[]).where(
        (e) => e.shell == shell,
      );
      final calendar = _session?.calendarFor(shell);
      // a DOI container's document (SO10's Word editor, a SAPRDEMO sheet)
      final office = _session?.officeDocuments[shell];
      if (calendar != null && calendar.horizontal) {
        // a date navigator (/AIF/IFMON's lower-left pane): the months side
        // by side in week columns; a tapped day / week / month is the
        // control's date-selected event with its interval
        content = SapDateNavigatorView(
          key: ValueKey('navigator-${calendar.shell}'),
          calendar: calendar,
          onPick: (from, to) => _run(
            () async => _session!.pickCalendarDate(calendar, from, to),
          ),
        );
      } else if (calendar != null) {
        // the date picker the server hosts for F4 on a date field (the
        // "Calendrier" popup's CONTAINER): a native month grid; a tapped
        // day is the control's date-selected event, the server then
        // closes the popup and fills the field
        content = SapCalendarView(
          key: ValueKey('calendar-${calendar.shell}'),
          calendar: calendar,
          onPick: (day) =>
              _run(() async => _session!.pickCalendarDate(calendar, day)),
        );
      } else if (editor.isNotEmpty) {
        // the ABAP editor control (SE38 / SE80): the source with its
        // breakpoints (the server's markers: a dot comes and goes with its
        // SetMarker / RemoveMarker answer, never optimistically); a tap in
        // the gutter — on a dot or not — is the editor's margin click
        // (BorderClick: the server sets or removes the SESSION
        // breakpoint), Ctrl+Shift+F12 the same toggle by key; a double
        // tap navigates, the long press offers the where-used list. The
        // external breakpoint is the toolbar's own button (Ctrl+Shift+F9),
        // never a gutter gesture.
        final e = editor.first;
        final ab4 = e.kind == 'ab4';
        if (ab4) editorShell = e.shell;
        content = SapSourceView(
          key: ValueKey('editor-${e.shell}'),
          lines: e.lines,
          breakpoints: e.breakpoints,
          otherBreakpoints: e.otherBreakpoints,
          externalBreakpoints: e.externalBreakpoints,
          currentLine: e.cursorLine,
          firstVisibleLine: e.firstVisibleLine,
          scrollSerial: e.firstVisibleLinePuts,
          onToggleBreakpoint: !ab4
              ? null
              : (line) =>
                    _run(() async => _session!.editorMarginClick(e, line)),
          onBreakpointKey: !ab4
              ? null
              : (line) => _run(
                  () async => _session!.editorToggleBreakpoint(e, line),
                ),
          onNavigate: (line, col) =>
              _run(() async => _session!.editorNavigate(e, line, col)),
          onWhereUsed: (line, col) =>
              _run(() async => _session!.editorWhereUsed(e, line, col)),
          // the control's client state the server reads back after a
          // double-click / where-used: the lines on screen, the caret
          onViewport: (first, last) => _session?.setEditorClientState(
            e,
            firstVisibleLine: first,
            lastVisibleLine: last,
          ),
          onViewLines: (n) => _editorViewLines[e.shell] = n,
          onCaret: (line, col) => _session?.setEditorClientState(
            e,
            caretLine: line,
            caretCol: col,
          ),
          // a selection: SelPosStart* .. SelPosEnd* (end column exclusive)
          onSelection: (sl, sc, el, ec) => _session?.setEditorClientState(
            e,
            caretLine: sl,
            caretCol: sc,
            selEndLine: el,
            selEndCol: ec,
          ),
        );
      } else if (office != null) {
        // read-only (sap_office_view.dart); the first touch is the
        // container's activation event, as in SAP GUI's in-place Word
        content = SapOfficeView(
          key: ValueKey('office-$shell'),
          document: office,
          onActivate: () =>
              _run(() async => _session!.officeDocumentActivated(shell)),
        );
      } else if (html.isNotEmpty) {
        // an HTML viewer (the F1 Performance Assistant, a help page): its
        // document as text, under its CFW dialog's title when it has one
        final d = html.first;
        content = _htmlPane(d);
      } else if (tree != null && !tree.isEmpty) {
        // a tree in a composed window: its events go to ITS shell (the
        // DBA cockpit's navigation tree shares the window with the still
        // live Easy Access tree)
        content = SapTreeView(
          tree: tree,
          busy: modal,
          // a canvas beside the tree (the BW network graphic, RSNPG_TEST_
          // NETPLAN1) takes its rows as drops
          dragShell: (view?.canvases ?? const <SapCanvasModel>[]).isEmpty
              ? null
              : shell,
          onRunTcode: (tcode) => _run(() async => _session!.okcode('/n$tcode')),
          onExpand: (key) =>
              _run(() async => _session!.expandTreeNodeOf(shell, key)),
          onActivate: (key) =>
              _run(() async => _session!.doubleClickTreeNode(shell, key)),
          handlesDoubleClick: _treeHandlesDoubleClick(shell),
          onSelect: (key) => _selectTreeNode(shell, key),
          onToggle: (key, open) => _toggledTreeNode(shell, key, open),
          onTopNode: (key) => _treeTopNode(shell, key),
          expandedKeys: _treeExpandedKeys(shell),
          onContextMenu: (key, at) => _treeMenu(shell, key, at),
          // a column tree (the ALV tree of /AIF/IFMON): its header row and
          // item columns, their widths in the pane's cells; a link /
          // button cell's click, a cell's double-click with its column
          columns: _session?.treeColumns(shell),
          paneCols: cells.width.round(),
          icons: _icons,
          onItemClick: (key, item) =>
              _run(() async => _session!.clickTreeItem(shell, key, item)),
          onItemActivate: (key, item) => _run(
            () async =>
                _session!.doubleClickTreeNode(shell, key, itemName: item),
          ),
        );
      } else if (grid != null) {
        content = _gridView(grid, menu: base.modalLevel == 0);
      } else if (chart.isNotEmpty) {
        final c = chart.first;
        content = SapChartView(
          type: c.chartType,
          title: c.title,
          categories: c.categories,
          series: [
            for (final s in c.series) ChartSeriesData(s.label, s.values),
          ],
        );
      } else if (graph.isNotEmpty) {
        content = _netPlanView(graph.first);
      } else if (canvas.isNotEmpty) {
        content = _canvasView(canvas.first);
      } else if ((view?.drawnPictures.contains(shell) ?? false) &&
          view?.pictures[shell] != null) {
        final pic = view!.pictures[shell]!;
        // a picture control (the STMS landscape picture): the bytes the
        // server pushed, scaled by its display mode
        content = SapPictureView(key: ValueKey('picture-$shell'), picture: pic);
      } else if (cfwFieldControlView(
            _session,
            shell,
            busy: modal,
            run: _run,
            icons: _icons,
          )
          case final w?) {
        // a CFW combo box / input field (SE80's object-list type and
        // object name, sap_combo_box_view.dart)
        content = w;
      } else if (view?.controlToolbars[shell]?.kind ==
          SapControlToolbarKind.standalone) {
        // a SAP.Toolbar.1 in its own box (the ALV tree's, ME21N's
        // document overview): its button row
        content = _controlToolbar(shell);
      }
    }
    if (content != null) {
      final c = content;
      // a control ROW: a toolbar's buttons ('TB'), a combo box / input
      // field ('CF')
      final controlRow = r.rung == 'TB' || r.rung == 'CF';
      return ComposedPane(
        cells: cells,
        // a control row keeps its height when a row divider moves
        // (ScreenComposer: the divider moves it along)
        rigidRows: controlRow,
        // a pane shorter than its control's chrome (a 3-row bottom dock on
        // a small window) is cut off at its edge, as SAP GUI's is — but a
        // control row is drawn in its own height (_controlRow)
        builder: (context, cell) => ClipRect(
          child: LayoutBuilder(
            builder: (context, cons) {
              // the ABAP editor's region, before its view lays out
              if (editorShell != null && cons.maxHeight.isFinite) {
                _editorRegionLines[editorShell] = SapSourceView.linesFitting(
                  math.max(cons.maxHeight, _minPaneHeight),
                );
              }
              return controlRow
                ? _controlRow(c, cons, scaled: r.rung == 'TB')
                : cons.maxHeight >= _minPaneHeight
                ? c
                : SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: SizedBox(height: _minPaneHeight, child: c),
                  );
            },
          ),
        ),
      );
    }
    if (r.rung == 'R1') return null; // a docked pane that paints nothing
    // an area whose splitter cells draw its content (their own regions):
    // the area itself paints nothing (reference client render_regions._rung_cells)
    if (r.rung == 'R2' && shell == null) return null;
    // a grid the creation wave minted with no field catalog yet: SAP GUI
    // shows the empty grid control, not a legend (SM12's lists before
    // their first push)
    if (r.rung == 'R7' && r.kind == 'grid') {
      return ComposedPane(cells: cells, builder: (_, _) => const _BlankGrid());
    }
    // content not delivered (yet): the reference client's dashed box and legend
    return ComposedPane(
      cells: cells,
      builder: (context, cell) => _Placeholder(text: r.reason),
    );
  }

  /// Each viewer's shown page ([SapHtmlDocument.content]) by shell, with
  /// the page, parts and url it was spliced from: the session mints a new
  /// document every generation around the same pushed page, and its
  /// frame splicing (regexes over the page) ran anew each time — the view
  /// then compared the whole new string with the last.
  final Map<String, (String, Map<String, Uint8List>, String, String)>
  _htmlContent = {};

  String _htmlContentOf(SapHtmlDocument d) {
    final m = _htmlContent[d.shell];
    if (m != null &&
        identical(m.$1, d.html) &&
        identical(m.$2, d.parts) &&
        m.$3 == d.url) {
      return m.$4;
    }
    if (_htmlContent.length >= 32) _htmlContent.clear(); // a bound
    final c = d.content;
    _htmlContent[d.shell] = (d.html, d.parts, d.url, c);
    return c;
  }

  /// An HTML viewer's document under its CFW dialog's caption, toolbar
  /// (the Performance Assistant's BACK / FORW / TECH / PRINT …) and close
  /// button; a link tap is the viewer's SAPEVENT.
  Widget _htmlPane(SapHtmlDocument d) {
    final theme = Theme.of(context);
    final dialog = d.dialog == null
        ? null
        : (_session?.cfwDialogs ?? const <SapCfwDialog>[])
              .where((x) => x.shell == d.dialog)
              .firstOrNull;
    final tb = dialog?.toolbar;
    final buttons = [
      for (final b in dialog?.buttons ?? const <SapToolbarButton>[])
        if (!b.separator && b.code != 'CLOSE') b,
    ];
    Widget button(SapToolbarButton b) {
      final token = SapIconAtlas.tokenRx.firstMatch(b.icon);
      final cp = token != null ? _icons?.codepoint(token.group(1)!) : null;
      final text = b.text.trim();
      final tip = b.tooltip.trim().isNotEmpty ? b.tooltip.trim() : b.code;
      VoidCallback? onPressed(bool busy) => busy || !b.enabled || tb == null
          ? null
          : () => _run(() async => _session!.cfwToolbarButton(tb, b.code));
      final glyph = cp != null
          ? Text(
              String.fromCharCode(cp),
              style: const TextStyle(fontFamily: 'SapIcons', fontSize: 18),
            )
          : null;
      return Tooltip(
        message: tip,
        child: _busyLeaf(
          (busy) => text.isEmpty && glyph != null
              ? IconButton(
                  onPressed: onPressed(busy),
                  icon: glyph,
                  isSelected: b.checked,
                )
              : TextButton.icon(
                  onPressed: onPressed(busy),
                  icon: glyph,
                  label: Text(text.isNotEmpty ? text : b.code),
                ),
        ),
      );
    }

    final title = (d.dialogTitle ?? dialog?.title ?? '').trim();
    return Material(
      elevation: d.dialog != null ? 6 : 0,
      color: theme.colorScheme.surfaceContainerHigh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title.isNotEmpty || dialog != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  if (dialog != null)
                    _busyLeaf(
                      (busy) => IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close),
                        onPressed: busy
                            ? null
                            : () => _run(
                                () async => _session!.closeCfwDialog(dialog),
                              ),
                      ),
                    ),
                ],
              ),
            ),
          if (buttons.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(children: [for (final b in buttons) button(b)]),
            ),
          Expanded(
            // the page as its frames show it (a dynamic document's
            // HTML000002 frameset over its content page, SBWP's template)
            child: _busyLeaf(
              (busy) => SapHtmlView(
              html: _htmlContentOf(d),
              onLink: busy
                  ? null
                  : (href) {
                      // only a SAPEVENT goes to the server; a local link
                      // (another pushed page, http) has no DIAG round
                      if (!href.toLowerCase().startsWith('sapevent:')) {
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          SnackBar(content: Text('Link not followed: $href')),
                        );
                        return;
                      }
                      _run(() async => _session!.htmlLink(d, href));
                    },
              // a form button posts what was typed into the page's inputs;
              // Enter in an input is the page's own submit
              onFormSubmit: busy
                  ? null
                  : (id, values) => _run(
                      () async =>
                          _session!.htmlFormButton(d, id, values: values),
                    ),
              onFormEnter: busy
                  ? null
                  : (input, values) => _run(
                      () async =>
                          _session!.htmlFormEnter(d, input, values: values),
                    ),
              // the buttons' images: the files pushed beside the page
              parts: d.parts,
              baseUrl: d.url,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A designer canvas: tables with their rows. The gestures, each the real
  /// SAP GUI for Windows' (diag_protocol canvas_actions.dart):
  /// * a drag from a row onto another row (or a long press, then the drag)
  /// draws a link — ICDataFlow's OnNewLinkCreated `%_GC <shell> 1048576`
  /// (a recorded session gui[8] / [11]); a drag from anywhere
  /// else pans the canvas;
  /// * a double tap on a table or row is its OnLeftButtonDblClk
  /// `%_GC <shell> 32` (a recorded session gui[51] / [52]);
  /// * a tap selects (outlined): where the canvas announced
  /// OnObjectSelected (RSNPG_TEST_NETPLAN1) it is event 134217728 with
  /// the TABLE (a row's too) `(id, 0)`, a tap on the empty canvas
  /// `(-1, -1)` (a recorded session gui[8] / [14]);
  /// wire-silent on the SQVI / SQ02 canvases;
  /// * a drag on a table (its header, its frame) moves it, its rows and
  /// their links following — the real GUI sends only the mouse-down's
  /// select, the move is wire-silent (same capture, gui[24]) and stays
  /// the view's until the server places the table anew;
  /// * a long press released on the node, or a secondary click, is the
  /// right-click `%_GC <shell> 4194304` and its menu;
  /// * a tree row dropped on a canvas row is the CFW drop (the server then
  /// reads the drag&drop service).
  Widget _canvasView(SapCanvasModel c) {
    void select(String? id) {
      if (id != null && c.node(id) == null) return; // a repaint is on its way
      _run(() async => _session!.canvasClick(c, id));
    }

    final (nodes, edges) = canvasGraph(
      c,
      tableFill: Theme.of(context).colorScheme.surfaceContainerHigh,
    );
    return SapGraphView(
      key: ValueKey('canvas-${c.shell}'),
      nodes: nodes,
      edges: edges,
      // links join rows (a recorded session: 3 -> 15, 46 -> 15);
      // a drag on a table moves it
      canLinkFrom: (n) => n.type == 'row',
      canMove: (n) => n.type == 'table',
      onMoveStart: (n) => select(n.id),
      onTapNode: (n) => select(n.id),
      onTapEmpty: () => select(null),
      onDoubleTapNode: (n, at) {
        if (c.node(n.id) == null) return;
        _run(
          () async => _session!.canvasDoubleClick(
            c,
            n.id,
            x: at.dx.round(),
            y: at.dy.round(),
          ),
        );
      },
      onContextMenu: (n, at) => _controlMenu(
        c.shell,
        at,
        () => _session!.requestCanvasContextMenu(c, n.id),
      ),
      onConnect: (a, b) {
        final from = c.node(a.id), to = c.node(b.id);
        if (from == null || to == null) return;
        _run(() async => _session!.connectCanvasNodes(c, from, to));
      },
      onExternalDrop: (drag, at, onto) {
        if (onto == null || c.node(onto.id) == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Drop the row onto a table row of the canvas'),
            ),
          );
          return;
        }
        _run(
          () async => _session!.dropOnCanvas(
            sourceShell: drag.shell,
            sourceKey: drag.nodeKey,
            targetShell: c.shell,
            targetObjId: onto.id,
            x: at.dx.round(),
            y: at.dy.round(),
          ),
        );
      },
    );
  }

  /// A NetPlan / JNet network graph: the server's layout raster where it
  /// placed the nodes, its highlight colours; a node tap is the control's
  /// node double-click (the event the real GUI raises on every click). A
  /// drag moves a node on the view only: no capture shows a JNet move on
  /// the wire.
  Widget _netPlanView(SapNetPlanModel g) {
    return SapGraphView(
      key: ValueKey('netplan-${g.shell ?? g.title}'),
      title: g.title,
      nodes: [
        for (final n in g.nodes)
          GraphNode(
            id: n.id,
            label: n.caption,
            type: n.type,
            col: n.col,
            row: n.row,
            fill: jnetColor(g.fillColor(n)),
            border: jnetColor(g.lineColor(n)),
          ),
      ],
      edges: [for (final e in g.edges) GraphEdge(e.from, e.to, label: e.label)],
      canMove: (_) => true,
      onTapNode: g.shell == null
          ? null // an inline graph has no control to raise the event on
          : (n) {
              final node = g.node(n.id);
              if (node != null) {
                _run(() async => _session!.selectNetPlanNode(g, node));
              }
            },
    );
  }

  /// The screen's hosted controls, keyed by their container (a chart's
  /// custom control area); one without a known container gets its own key
  /// and renders below the screen.
  Map<String, Widget> _hostedControls() {
    final out = <String, Widget>{};
    final view = _session == null ? null : _viewOf(_session!);
    for (final c in view?.canvases ?? const <SapCanvasModel>[]) {
      out[c.container ?? 'canvas:${c.shell}'] = _canvasView(c);
    }
    for (final g in view?.netPlans ?? const <SapNetPlanModel>[]) {
      out[g.container ?? 'netplan:${g.shell ?? g.title}'] = _netPlanView(g);
    }
    for (final c in view?.charts ?? const <SapChartModel>[]) {
      out[c.container ?? 'chart:${c.shell}'] = SapChartView(
        key: ValueKey('chart-${c.shell}'),
        type: c.chartType,
        title: c.title,
        categories: c.categories,
        series: [for (final s in c.series) ChartSeriesData(s.label, s.values)],
      );
    }
    return out;
  }

  /// A typed (not yet submitted) value: staged in the session, it rides
  /// the next action — F7, a toolbar button, Enter — as SAP GUI's PAI
  /// carries every changed field.
  void _stageEdit(ScreenField f, String text) {
    try {
      _session?.stageField(f, text);
      if (_stageRefused == f.name) _stageRefused = null;
    } on ArgumentError catch (e) {
      // the session refused the value (the field is protected now, or the
      // screen it was typed on is gone): it would be lost silently — said
      // once per field, never with the typed text
      if (_stageRefused == f.name || !mounted) return;
      _stageRefused = f.name;
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Not kept: ${e.message}')));
    }
  }

  /// The field whose last typed value the session refused ([_stageEdit]).
  String? _stageRefused;

  /// F4 on a field with value help: the hit list / restriction dialog
  /// comes back as a popup. F4 on a field showing a date that brings no
  /// calendar control (the server answered with a dynpro popup, a message
  /// or nothing) is reported — no client-side picker stands in for the
  /// server's.
  Future<void> _valueHelp(ScreenField f) async {
    await _run(() async => _session!.valueHelp(f));
    final s = _session;
    if (!mounted || s == null || _error != null) return;
    if (fieldShowsDate(f) && s.calendars.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'F4 on ${f.name ?? 'the date field'}: the server opened no '
            'calendar control',
          ),
        ),
      );
    }
  }

  /// A tree row's context menu: the server's menu for that node.
  Future<void> _treeMenu(String shell, String nodeKey, Offset at) =>
      _controlMenu(
        shell,
        at,
        () => _session!.requestTreeContextMenu(shell, nodeKey),
      );

  /// A CFW control's context menu: [request] asks the server (the right
  /// click's event), the menu it pushes is shown at [at], and the entry
  /// picked goes back as the control's function event; dismissing sends
  /// nothing. A control that registered no menu event says so.
  Future<void> _controlMenu(
    String shell,
    Offset at,
    Future<List<Uint8List>> Function() request,
  ) async {
    final s = _session;
    if (s == null || _busy) return;
    String? refused;
    await _run(() async {
      try {
        await request();
      } on StateError catch (e) {
        refused = e.message;
      } on ArgumentError catch (e) {
        refused = '${e.message}';
      } on UnsupportedError catch (e) {
        refused = e.message ?? 'not supported';
      }
    });
    if (!mounted) return;
    final menu = s.contextMenuFor(shell) ?? s.pendingContextMenu;
    if (menu == null || menu.entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            refused != null
                ? 'No context menu here ($refused)'
                : 'The server sent no context menu',
          ),
        ),
      );
      return;
    }
    String label(SapMenuEntry e) {
      final t = e.text.replaceAll(SapIconAtlas.tokenRx, '').trim();
      return t.isNotEmpty ? t : e.fcode;
    }

    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        for (final e in menu.entries)
          if (e.isSeparator)
            const PopupMenuDivider()
          else if (e.isSubmenu)
            PopupMenuItem<String>(
              enabled: false,
              height: 32,
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16.0 * (e.level - 1).clamp(0, 6),
                ),
                child: Text(
                  label(e),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            )
          else
            PopupMenuItem<String>(
              value: e.isSelectable ? e.fcode : null,
              enabled: e.isSelectable,
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16.0 * (e.level - 1).clamp(0, 6),
                ),
                child: Row(
                  children: [
                    Expanded(
                      // the server's DEFAULT entry (record byte 201) is
                      // drawn bold, as SAP GUI draws it
                      child: Text(
                        label(e),
                        overflow: TextOverflow.ellipsis,
                        style: e.isDefault
                            ? const TextStyle(fontWeight: FontWeight.bold)
                            : null,
                      ),
                    ),
                    if (e.accel.trim().isNotEmpty)
                      Text(
                        e.accel.trim(),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
      ],
    );
    if (picked == null) {
      s.dismissContextMenu();
      return;
    }
    await _run(() async => s.pickContextMenu(menu, picked));
  }

  /// SAP GUI's context menu on a screen: the field's help and value help
  /// when it was opened on an input, then the screen's function keys (the
  /// GUI status's 18/11/4 list — what the Windows GUI shows on a right
  /// click; picking one is pressing that key, nothing else goes out).
  Future<void> _screenMenu(Offset at, ScreenField? f) async {
    final s = _session;
    final m = s?.screen;
    if (s == null || m == null || _busy) return;
    final keys = [
      for (final e in (m.functionKeys.isNotEmpty ? m.functionKeys : m.toolbar))
        if (!e.separator && e.vkey >= 0) e,
    ];
    String label(MenuEntry e) {
      final t = e.text.replaceAll(SapIconAtlas.tokenRx, '').trim();
      return t.isNotEmpty ? t : e.tooltip.trim();
    }

    final input = f != null && f.kind == FieldKind.input;
    final picked = await showMenu<Future<void> Function()>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        if (input) ...[
          PopupMenuItem(
            value: () => s.fieldHelp(f),
            child: const ListTile(
              dense: true,
              leading: Icon(Icons.help_outline),
              title: Text('Help'),
              trailing: Text('F1'),
            ),
          ),
          if (f.hasF4 && !f.isProtected)
            PopupMenuItem(
              value: () => s.valueHelp(f),
              child: const ListTile(
                dense: true,
                leading: Icon(Icons.manage_search),
                title: Text('Value help'),
                trailing: Text('F4'),
              ),
            ),
          if (keys.isNotEmpty) const PopupMenuDivider(),
        ],
        for (final e in keys)
          if (label(e).isNotEmpty)
            PopupMenuItem(
              enabled: e.active,
              value: () => s.press(e.vkey),
              child: ListTile(
                dense: true,
                title: Text(label(e), overflow: TextOverflow.ellipsis),
                trailing: Text(vkeyName(e.vkey) ?? ''),
              ),
            ),
      ],
    );
    if (picked == null) return;
    await _run(() async => picked());
  }

  /// The input that last took the focus, on the screen it was painted on:
  /// F1 asks help for it, as SAP GUI's F1 asks for the field under the
  /// cursor.
  (ScreenModel, ScreenField)? _focus;

  void _focusField(ScreenField f) {
    final m = _session?.screen;
    if (m != null) _focus = (m, f);
  }

  /// F1: field help on the focused input of the current screen, else the
  /// plain key.
  Future<void> _help() async {
    final s = _session!;
    final focus = _focus;
    if (focus != null && identical(focus.$1, s.screen)) {
      await s.fieldHelp(focus.$2);
    } else {
      await s.press(1);
    }
  }

  /// A classic list line double-tapped: the list's pick (F2) at the tapped
  /// column — the cursor [_placeListCursor] put there (a main-window list:
  /// the list key round; a popup hit list: [SapSession.pickValue]).
  Future<void> _listPick(ListLine line) => _run(() async {
    final s = _session!;
    final at = s.listCursor;
    await s.pickListAt(
        line, at != null && at.$1 == line.line ? at.$2 : line.hotspotCol);
  });

  /// A tap on a classic list line: the list cursor moves there, no round
  /// (the next list round carries it).
  void _placeListCursor(int row, int col) =>
      _session?.setListCursor(row, col);

  /// A paged classic list scrolled past its page: the server's page at
  /// [firstLine] (the real GUI's VSCROLL round; never while busy — [_run]).
  Future<void> _listScroll(int firstLine) =>
      _run(() async => _session!.scrollList(firstLine));

  /// A list input cell changed (a checkbox ticked): staged, it rides the
  /// list's next key round (F2 on a line, a function key).
  void _stageListCell(ListLine line, ListSegment cell, String text) {
    try {
      _session?.stageListCell(line, cell, text);
    } on ArgumentError catch (e) {
      // the list was repainted. Debug builds only, and the reason only —
      // never the typed value
      assert(() {
        debugPrint('list cell not staged: ${e.message}');
        return true;
      }());
    }
  }

  /// SAP GUI's double-click on a dynpro element: the choose key (F2) with
  /// the cursor on it (the selection-option maintenance popup on a
  /// select-option's value, a pick in a list-like dynpro).
  Future<void> _doubleClick(ScreenField f) =>
      _run(() async => _session!.doubleClick(f));

  /// Submit one field's typed value at the kernel's own cell.
  Future<void> _fillField(ScreenField f, String text) async {
    if (f.tableControl != null) {
      // a table-control cell has no screen atom: the step-loop cell
      // submit addresses it by (control, line, column)
      await _run(() async => _session!.submitCell(f, text));
      return;
    }
    // the container tells two subscreens' inputs on the same local cell
    // apart, so a tabstrip-page field gets its routing (no FOCUS DATA)
    await _run(
      () async => _session!.fill(
        f.wireRow,
        f.wireCol,
        text,
        area: f.area,
        mx: f.maxnrchars,
        mlen: f.mlen,
        attr: f.attr,
        container: f.container,
      ),
    );
  }

  ScreenField? _selectedWallField(ScreenModel m) {
    final radios = m.fields.where((f) => f.kind == FieldKind.radio).toList();
    if (radios.isEmpty) return null;
    if (_wallSelectionRow != null) {
      for (final f in radios) {
        if (f.row == _wallSelectionRow) return f;
      }
    }
    final painted = radios.where((f) => f.on).toList();
    return painted.isNotEmpty ? painted.first : radios.first;
  }

  /// ✓ confirms the selected radio (mapped to its option row); ✗ cancels
  /// the logon when the wall offers the terminate option. [answer] gets
  /// the choice: the bootstrap's wall completer, or — for a wall RELAYED
  /// from a remote logon's target — [SapSession.answerRelayedWall].
  List<Widget> _wallActions(
    WallInfo wall,
    void Function(WallOption) answer, {
    String cancelTooltip = 'Cancel logon',
  }) {
    WallOption selectionFor(int row) {
      for (final e in wall.nameToRow.entries) {
        if (e.value == row) {
          if (e.key.contains('OPT1')) return WallOption.endOthers;
          if (e.key.contains('OPT2')) return WallOption.keepOthers;
          if (e.key.contains('OPT3')) return WallOption.cancelLogon;
        }
      }
      return WallOption.keepOthers;
    }

    final row =
        _wallSelectionRow ??
        (wall.rowToOption.entries
                .where((e) => e.value.$2)
                .map((e) => e.key)
                .toList()
              ..sort())
            .firstOrNull;
    final canConfirm = row != null;
    return [
      if (wallRowFor(wall, WallOption.cancelLogon) != null)
        IconButton.filledTonal(
          tooltip: cancelTooltip,
          onPressed: () => answer(WallOption.cancelLogon),
          icon: const Icon(Icons.close),
        ),
      FilledButton.icon(
        onPressed: canConfirm ? () => answer(selectionFor(row)) : null,
        icon: const Icon(Icons.check),
        label: const Text('Confirm'),
      ),
    ];
  }

  /// The user's answer to a multi-logon wall relayed from a remote logon's
  /// target: the target's question, never auto-answered as this logon's.
  void _answerRelayedWall(WallOption option) {
    setState(() => _wallSelectionRow = null);
    _run(() async {
      await _session!.answerRelayedWall(option);
      if (mounted) setState(() => _screen = _session!.screen);
    });
  }

  void _answerWall(Completer<WallOption> completer, WallOption option) {
    if (!completer.isCompleted) completer.complete(option);
    setState(() {
      _wallCompleter = null;
      _wall = null;
    });
  }

  Widget _connectingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          ValueListenableBuilder(
            valueListenable: _connectLog,
            builder: (c, lines, _) {
              final log = (lines as List).cast<String>();
              final tail = log.length <= 4 ? log : log.sublist(log.length - 4);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final l in tail)
                    Text(
                      l,
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// The app root's input history plus this logon's server type-ahead:
  /// the `%_SEARCH <text>` round of a field the server armed
  /// ([ScreenField.typeAhead], SapSession.fieldTypeAhead).
  Widget _withTypeAhead(BuildContext context, Widget child) {
    final base = TypeAheadScope.maybeOf(context);
    if (base == null) return child;
    return TypeAheadScope(
      config: base.copyWith(server: _fieldTypeAhead),
      child: child,
    );
  }

  /// One provider pair per logon (a stable identity: the scope does not
  /// notify on every build); none on the Java dialect (no Java type-ahead
  /// round is recorded).
  void _refreshTypeAhead() {
    final s = _session;
    if (identical(_typeAheadSession, s)) return;
    _typeAheadSession = s;
    final win = s != null && s.answerDialect == GuiDialect.windows;
    _fieldTypeAhead = win
        ? ServerTypeAheadProvider((f, t) => s.fieldTypeAhead(f, t))
        : null;
    _commandTypeAhead =
        win ? CommandFieldTypeAheadProvider(s.commandFieldTypeAhead) : null;
  }

  SapSession? _typeAheadSession;
  TypeAheadProvider? _fieldTypeAhead;
  TypeAheadProvider? _commandTypeAhead;

  /// SAP GUI's command field: a transaction code is at most 20
  /// characters, with its `/n` / `/o` prefix 22 — the field is sized for
  /// that (input is not cut: SY-UCOMM takes longer function codes).
  final TextEditingController _okcodeCtrl = TextEditingController();

  /// SAP GUI's green check beside the command field: the command typed,
  /// else plain Enter.
  void _submitOkcode() {
    // declined while an action runs: the typed command stays in the field
    if (_busy || _session == null) return;
    final v = _okcodeCtrl.text;
    _okcodeCtrl.clear();
    if (v.trim().isEmpty) {
      _run(() async => _session!.press(0));
      return;
    }
    _run(() async => _session!.okcode(v));
  }

  Widget _commandBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          // SAP GUI's Enter button sits left of the command field
          IconButton.filledTonal(
            tooltip: 'Enter (runs the command when one is typed)',
            icon: const Icon(Icons.check),
            onPressed: _busy || _session == null ? null : _submitOkcode,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 300,
            child: TypeAheadInput(
              config: TypeAheadScope.maybeOf(context)
                  ?.copyWith(server: _commandTypeAhead),
              model: _screen ?? ScreenModel(),
              field: commandFieldOf(),
              controller: _okcodeCtrl,
              builder: (context, onChanged, onSubmitted) => TextField(
              controller: _okcodeCtrl,
              onChanged: onChanged,
              onSubmitted: (v) {
                onSubmitted(v);
                _submitOkcode();
              },
              maxLength: 70,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(fontFamily: 'Menlo', fontSize: 15),
              decoration: const InputDecoration(
                hintText: '/n<tcode>',
                prefixIcon: Icon(Icons.terminal),
                isDense: true,
                counterText: '',
              ),
            ),
            ),
          ),
          const SizedBox(width: 8),
          // SAP GUI's standard toolbar beside the command field: Save,
          // Back, Exit, Cancel, Find, Help, Execute — one icon size, one
          // button width, no gaps between them (greyed when the GUI status
          // does not define the key)
          _navBtn(Icons.save_outlined, 'Save (Ctrl+S)', 11, null),
          _navBtn(Icons.arrow_back, 'Back (F3)', 3, Colors.green),
          _navBtn(Icons.arrow_upward, 'Exit (Shift+F3)', 15, Colors.amber),
          _navBtn(Icons.close, 'Cancel (F12)', 12, Colors.redAccent),
          _navBtn(Icons.search, 'Find (Ctrl+F)', 71, null),
          _toolBtn(
            const Icon(Icons.help_outline, size: _toolIcon),
            'Help (F1)',
            _busy || _session == null ? null : () => _run(_help),
          ),
          // SAP's own Execute icon (ICON_EXECUTE_OBJECT, @15@): green when
          // F8 is active (the font's hairline glyph read as greyed in the
          // theme's icon colour), lowered onto the row's icon line (the
          // glyph sits high in its em)
          Builder(
            builder: (context) {
              final on = !_busy && _session != null && _keyActive(8);
              return _toolBtn(
                Transform.translate(
                  offset: const Offset(0, 2),
                  child: Icon(
                    _sapExecuteIcon,
                    size: _toolIcon,
                    color: on ? Colors.greenAccent : null,
                  ),
                ),
                'Execute (F8)',
                on ? () => _run(() async => _session!.press(8)) : null,
              );
            },
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _statusAndKeys(ScreenModel? m) {
    final msg = m?.message ?? '';
    // the main window's application toolbar (a popup carries its own in
    // its button area)
    final base = _session?.baseScreen ?? m;
    final toolbar = base == null || base.modalLevel > 0
        ? const <MenuEntry>[]
        : base.toolbar.where((e) => !e.separator).toList();
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (toolbar.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SapIconAtlasStrip(
                atlas: _icons,
                child: Builder(
                  builder: (context) => SapToolbar(
                    entries: toolbar,
                    icons: _icons,
                    busy: _busy || _session == null,
                    onPress: (vkey) => _run(() async => _session!.press(vkey)),
                  ),
                ),
              ),
            ),
          // the message line is always there, one line high, as SAP GUI's
          // status bar is: a message that came and went (or wrapped to a
          // second line) changed the body's height, and every change was
          // a new SAP window size — a resize round per message (live the test system
          // /AIF/IFMON 2026-10-13: 66 <-> 68 rows as "Basculer sélection
          // de dates …" appeared and cleared)
          Container(
            key: SessionScreen.messageLineKey,
            width: double.infinity,
            color: msg.isEmpty ? null : Colors.blueGrey.shade900,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              msg,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              // one strut line whatever the text: an empty line, or a
              // fallback font's taller glyphs, keep the bar's height
              strutStyle: StrutStyle.fromTextStyle(
                DefaultTextStyle.of(context).style,
                forceStrutHeight: true,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// ICON_EXECUTE_OBJECT (`@15@`) in the bundled SAP icon font.
  static const _sapExecuteIcon = IconData(0xE004, fontFamily: 'SapIcons');

  /// The status bar's system values, as SAP GUI's dropdown lists them
  /// (GuiGo's own labels, in English like the rest of its chrome).
  static const _statusInfoLabels = {
    'system': 'System',
    'client': 'Client',
    'user': 'User',
    'program': 'Program',
    'tcode': 'Transaction',
  };

  String _statusInfoValue(String key, ScreenModel? m) {
    final e = _args.entry;
    return switch (key) {
      'system' => m?.systemId ?? e.name,
      'client' => m?.client ?? e.client,
      'user' => e.user.toUpperCase(),
      'program' => m?.program ?? '',
      'tcode' => m?.tcode ?? '',
      _ => '',
    }.trim();
  }

  /// The status bar's right end: the chosen system value with its
  /// dropdown (the choice is kept), then the application server.
  List<Widget> _systemInfo(ScreenModel? m) {
    final chosen = _args.store.statusInfo;
    final host = m?.appServer?.trim() ?? '';
    final sep = Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: Colors.white24,
    );
    return [
      sep,
      PopupMenuButton<String>(
        tooltip: 'Choose what the status bar shows',
        initialValue: chosen,
        // wide enough for a 40-character program name
        constraints: const BoxConstraints(minWidth: 320, maxWidth: 460),
        onSelected: (k) async {
          await _args.store.setStatusInfo(k);
          if (mounted) setState(() {});
        },
        itemBuilder: (_) => [
          for (final e in _statusInfoLabels.entries)
            CheckedPopupMenuItem<String>(
              value: e.key,
              checked: e.key == chosen,
              child: Row(
                children: [
                  Text(e.value, softWrap: false),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Text(
                      _statusInfoValue(e.key, m),
                      textAlign: TextAlign.right,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'Menlo'),
                    ),
                  ),
                ],
              ),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _statusInfoValue(chosen, m),
                style: const TextStyle(fontFamily: 'Menlo'),
              ),
              const Icon(Icons.arrow_drop_down, size: 20),
            ],
          ),
        ),
      ),
      if (host.isNotEmpty) ...[
        sep,
        Text(host, style: const TextStyle(fontFamily: 'Menlo')),
      ],
    ];
  }

  /// A standard-toolbar navigation key in the command row (SAP GUI's
  /// green / yellow / red arrows).
  Widget _navBtn(IconData icon, String tooltip, int vkey, Color? color) {
    final on = !_busy && _session != null && _keyActive(vkey);
    return _toolBtn(
      Icon(icon, size: _toolIcon, color: on ? color : null),
      tooltip,
      on ? () => _run(() async => _session!.press(vkey)) : null,
    );
  }

  /// The command row's icon size and button width: every standard-toolbar
  /// button the same, evenly spaced.
  static const double _toolIcon = 24;
  static const double _toolWidth = 48;

  Widget _toolBtn(Widget icon, String tooltip, VoidCallback? onPressed) =>
      IconButton(
        tooltip: tooltip,
        icon: icon,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(
          width: _toolWidth,
          height: _toolWidth,
        ),
        onPressed: onPressed,
      );

  /// Whether the GUI status of the screen on top (a popup's own) assigns
  /// key [vkey] and has it active — SAP GUI greys the standard toolbar's
  /// Back / Cancel / Save … the status does not define (STMS: no F3). A
  /// screen that painted no function-key list (18/11/4) keeps every key.
  bool _keyActive(int vkey) {
    final m = _session?.screen;
    if (m == null || m.functionKeys.isEmpty) return true;
    return m.functionKeys.any(
      (e) => !e.separator && e.vkey == vkey && e.active,
    );
  }

  /// The technical text of the failure [_error] reads for (the
  /// exception's own text), shown in the trace area under it.
  ({String message, String detail})? _errorText;

  /// An action failed with [e]. A client-side refusal on a healthy logon
  /// (nothing sent: a stale node / chip, a control of another imode) is a
  /// snack bar and a redraw from the session's current screen
  /// ([isClientRefusal]); the in-flight action of a session this screen
  /// already declared lost does not replace that message with "closed";
  /// anything else fails the session view.
  void _actionFailed(Object e) {
    final s = _session;
    if (e is SessionClosedError && _error != null) return;
    if (isClientRefusal(e, s)) {
      setState(() => _screen = s!.screen);
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(refusalText(e))));
      return;
    }
    setState(() => _fail(e));
  }

  /// Show [e] as the error: a readable sentence, its technical text kept
  /// for the trace area.
  void _fail(Object e) {
    final t = describeError(e);
    _errorText = t;
    _error = t.message;
  }

  Widget _errorView() {
    // The session's trace log (last steps of the handshake) — the one line
    // that names where a live logon diverged.
    final trace = _trace ?? _connectLog.value;
    final last = trace.length <= 6 ? trace : trace.sublist(trace.length - 6);
    // the failure's technical text heads it (only for the error shown)
    final t = _errorText;
    final tail = [
      if (t != null && t.message == _error && t.detail != t.message) t.detail,
      ...last,
    ];
    // scrolls: a long trace tail must never push the Retry button off
    // the screen (it overflowed under the ST04 timeout)
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
            const SizedBox(height: 12),
            Text(_error ?? '', textAlign: TextAlign.center),
            if (tail.isNotEmpty) ...[
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final line in tail)
                        SelectableText(
                          line,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            if (_plaintext) ...[
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.zero,
                child: const ListTile(
                  leading: OpenLockIcon(),
                  title: Text('Unencrypted connection'),
                  subtitle: Text(_plaintextText),
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _connect,
              child: Text(_lost ? 'Reconnect' : 'Retry'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _closeModalRoute(deferred: true);
    _logTimer?.cancel();
    _resizeTimer?.cancel();
    // leaving mid-connect, or on the multi-logon wall: the logon in
    // progress is cancelled and closed with the established one — never
    // abandoned live on the server (its in-flight connect, when it
    // completes, finds the screen gone and closes it too)
    final wall = _wallCompleter;
    if (wall != null && !wall.isCompleted) {
      wall.complete(WallOption.cancelLogon);
    }
    for (final s in {?_attempt, ?_session}) {
      _closeQuietly(s);
    }
    _turnTick.removeListener(_onTurnFrame);
    _turnTick.dispose();
    _modalBusyN?.dispose();
    _ui.dispose();
    _busyN.dispose();
    _connectLog.dispose();
    _okcodeCtrl.dispose();
    super.dispose();
  }

  // ---- modal dialog route ---------------------------------------------------

  /// Push/pop the modal dialog to match the paint. Runs post-frame so it is
  /// safe from any setState origin.
  void _scheduleModalSync() {
    if (_modalSyncScheduled) return; // one sync per frame, however many calls
    _modalSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _modalSyncScheduled = false;
      _syncModalRoute();
    });
  }

  bool _modalSyncScheduled = false;

  void _syncModalRoute() {
    if (!mounted) return;
    final wallWait = _wallCompleter != null;
    final modalActive =
        (_screen != null && _screen!.modalLevel > 0) ||
        wallWait ||
        _session?.valueHelpDialog != null;
    if (modalActive && _error == null && _modalRoute == null) {
      _modalRoute = DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black54,
        barrierLabel: 'Modal window',
        builder: (dialogContext) => DynproZoomScope(
          widest: _widestCols,
          child: SessionBusy(
          busy: _modalBusy,
          child: PopScope(
            canPop: false,
            child: AnimatedBuilder(
              animation: _ui,
              builder: (dialogCtx, _) {
                final m = _screen;
                final wallWait = _wallCompleter;
                if (m == null) return const SizedBox.shrink();
                // the Windows F4 value-help control (SAP.TABControl.1) the
                // server hosts over the field's popup: drawn instead of it
                final help = wallWait == null
                    ? _session?.valueHelpDialog
                    : null;
                if (help != null) {
                  final size = MediaQuery.sizeOf(dialogCtx);
                  return Center(
                    child: SizedBox(
                      width: (size.width - 32).clamp(280.0, 900.0),
                      height: (size.height * 0.85).clamp(320.0, 900.0),
                      child: SapValueHelpView(
                        key: ValueKey('f4-${help.shell}'),
                        dialog: help,
                        onSearch: (page, restrictions) => _run(
                          () async => _session!.searchValueHelp(
                            help,
                            restrictions: restrictions,
                            page: page,
                          ),
                        ),
                        onPage: (page) => _run(
                          () async => _session!.selectValueHelpPage(help, page),
                        ),
                        onPick: (row) => _run(
                          () async => _session!.pickValueHelpRow(help, row),
                        ),
                        onClose: () =>
                            _run(() async => _session!.closeValueHelp(help)),
                      ),
                    ),
                  );
                }
                // the window draws the active screen [m] — during the wall
                // wait that IS the wall popup (the session's turn painted
                // it), so no separate model is picked
                // a popup hosting grids / trees in its containers (the ALV
                // sort and filter dialogs): its regions composed at a fixed
                // 10 x 20 pt cell, the dynpro's buttons between the grids
                // a multi-logon wall RELAYED from a remote logon's target:
                // the user answers it (the session never does)
                final relayedWall = wallWait == null
                    ? _session?.relayedWall
                    : null;
                final wallPrompt = wallWait != null || relayedWall != null;
                final composedModal = !wallPrompt
                    ? _composedModal(m)
                    : null;
                final wallSel = wallPrompt && m.modalLevel > 0
                    ? _selectedWallField(m)
                    : null;
                final window = ModalDynproWindow(
                  onEdit: !wallPrompt ? _stageEdit : null,
                  onValueHelp: !wallPrompt ? _valueHelp : null,
                  onFocusField: _focusField,
                  onContextMenu: _screenMenu,
                  onListPick: !wallPrompt ? _listPick : null,
                  onListCursor: !wallPrompt ? _placeListCursor : null,
                  onListCell: !wallPrompt ? _stageListCell : null,
                  onListScroll: !wallPrompt ? _listScroll : null,
                  onDoubleClick: !wallPrompt ? _doubleClick : null,
                  model: m,
                  content: composedModal?.$1,
                  contentWidth: composedModal?.$2,
                  busy: false, // the dialog's SessionBusy scope
                  onFill: _fillField,
                  onPress: (vkey) => _run(() async => _session!.press(vkey)),
                  onOkcode: (cmd) => _run(() async => _session!.okcode(cmd)),
                  onRadio: wallPrompt
                      ? null // the wall answer is composed on confirm
                      : (group, chosen) => _run(
                          () async => _session!.selectRadio(group, chosen),
                        ),
                  radioSelection: wallSel,
                  onRadioTap: wallPrompt
                      ? (group, chosen) => setState(() {
                          _wallSelectionRow = chosen.row;
                        })
                      : null,
                  extraActions: wallWait != null && _wall != null
                      ? _wallActions(_wall!, (o) => _answerWall(wallWait, o))
                      : relayedWall != null
                      ? _wallActions(
                          relayedWall,
                          _answerRelayedWall,
                          cancelTooltip: 'Cancel the remote logon',
                        )
                      : const [],
                );
                final relayedFrom = _session?.relayedSystem?.sid;
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: SingleChildScrollView(
                      child: relayedWall == null
                          ? window
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Material(
                                  color: Theme.of(dialogCtx)
                                      .colorScheme
                                      .tertiaryContainer,
                                  borderRadius: BorderRadius.circular(8),
                                  child: Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Text(
                                      'Asked by ${relayedFrom ?? 'the remote '
                                              'system'} about your logon there '
                                      '(requested by '
                                      '${_session?.homeSystem?.sid ?? _args.entry.name}) '
                                      '— choose yourself.',
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                window,
                              ],
                            ),
                    ),
                  ),
                );
              },
            ),
          ),
          ),
        ),
      );
      Navigator.of(context).push(_modalRoute!);
    } else if ((!modalActive || _error != null) && _modalRoute != null) {
      _closeModalRoute();
    }
  }

  /// Remove the modal dialog route. From [dispose] ([deferred]) the
  /// navigator is not looked up through the dying context: the route is
  /// removed after the frame, unless its navigator went too (the whole app
  /// torn down).
  void _closeModalRoute({bool deferred = false}) {
    final route = _modalRoute;
    _modalRoute = null;
    if (route == null) return;
    void remove() {
      final nav = route.navigator;
      if (nav != null && nav.mounted && route.isActive) nav.removeRoute(route);
    }

    if (deferred) {
      WidgetsBinding.instance.addPostFrameCallback((_) => remove());
    } else if (mounted) {
      remove();
    }
  }
}

/// A ChangeNotifier whose tick is public (notifyListeners is protected).
class _UiPulse extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// A flag [read] from other state, re-read when one of [sources] fires and
/// notifying only when it flips (a pulse that changes nothing it reads
/// rebuilds none of its dependents).
class _DerivedFlag extends ValueNotifier<bool> {
  _DerivedFlag(this._read, List<Listenable> sources)
    : _sources = Listenable.merge(sources),
      super(false) {
    value = _read();
    _sources.addListener(_check);
  }

  final bool Function() _read;
  final Listenable _sources;

  void _check() => value = _read();

  @override
  void dispose() {
    _sources.removeListener(_check);
    super.dispose();
  }
}

/// An empty grid control: its frame on the grid background, no rows, no
/// headers (no field catalog has reached it).
class _BlankGrid extends StatelessWidget {
  const _BlankGrid();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant, width: 0.6),
        color: scheme.surface,
      ),
    );
  }
}

/// A region whose content has not reached the client (the reference client's R7
/// dashed box): its legend, small, so the window still shows its shape.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant, width: 0.6),
        color: scheme.surfaceContainerLow.withValues(alpha: 0.4),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(2),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// The session's control models for one generation of the screen, each
/// read from the session at most once (lazily).
class _SessionView {
  _SessionView(this.session, this.gen);
  final SapSession session;
  final int gen;
  late final Map<String, SapTreeModel> trees = session.trees;
  late final Map<String, SapGridModel> grids = session.grids;
  late final List<SapHtmlDocument> htmlDocuments = session.htmlDocuments;
  late final List<SapTextEditor> editors = session.editors;
  late final List<SapChartModel> charts = session.charts;
  late final List<SapNetPlanModel> netPlans = session.netPlans;
  late final List<SapCanvasModel> canvases = session.canvases;
  late final Map<String, SapControlToolbar> controlToolbars =
      session.controlToolbars;
  late final Map<String, SapPicture> pictures = session.pictures;

  /// The pictures the composition draws (its R3 regions): a picture shell
  /// named by another rung (an R7 placeholder, the Easy Access
  /// IMAGE_CONTAINER beside its tree) is not drawn over that region.
  late final Set<String> drawnPictures = {
    for (final r in [...regions, ...modalRegions])
      if (r.rung == 'R3' && pictures.containsKey(r.shell)) r.shell!,
  };

  /// The composed base window / popup: a composition walks the whole
  /// control registry (audit #15), so once per generation, not per build.
  late final List<ScreenRegion> regions = session.regions;
  late final List<ScreenRegion> modalRegions = session.modalRegions;

  /// The base window's splitter sashes ([SapSession.splitterSashes]).
  late final List<SplitterSash> sashes = session.splitterSashes;
}

final _gridRowAts = Expando<List<String>? Function(int)>('gridRowAt');

/// [grid]'s 0-based row lookup for [SapGridView.rowAt] — the same closure
/// for the same model (the session builds a new [SapGridModel] whenever
/// its content changes, the same instance otherwise).
List<String>? Function(int) gridRowAt(SapGridModel grid) =>
    _gridRowAts[grid] ??= (i) => grid.rowAt(i + 1);
