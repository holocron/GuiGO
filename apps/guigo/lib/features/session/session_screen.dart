import 'dart:math' as math;
import 'dart:async';

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/connections.dart';
import '../../core/open_lock_icon.dart';
import '../../core/password_dialog.dart';
import '../../core/sap_icons.dart';
import 'dynpro_view.dart';
import 'frame_coalescer.dart';
import 'sap_calendar_view.dart';
import 'sap_canvas_layout.dart';
import 'sap_chart_view.dart';
import 'sap_control_toolbar.dart';
import 'sap_graph_view.dart';
import 'sap_grid_view.dart';
import 'sap_html_view.dart';
import 'sap_value_help_view.dart';
import 'sap_window_size.dart';
import 'sap_source_view.dart';
import 'sap_menu_bar.dart';
import 'sap_toolbar.dart';
import 'screen_composer.dart';
import 'sap_tree_view.dart';
import 'modal_window.dart';

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

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen>
    with WidgetsBindingObserver {
  SapSession? _session;
  ScreenModel? _screen;
  String? _error;

  /// An action (or the logon) is running. A notifier, not screen state: it
  /// rebuilds the regions that draw it (the keys, the spinner, the body's
  /// inputs), not the whole Scaffold.
  final ValueNotifier<bool> _busyN = ValueNotifier(false);
  bool get _busy => _busyN.value;
  set _busy(bool v) {
    if (_busyN.value == v) return;
    _busyN.value = v;
    _gen++;
    _ui.ping(); // the modal dialog draws it too
    _scheduleModalSync();
  }

  /// A server turn (or a window switch) to draw: fired at most once per
  /// frame, so a burst of turns between two frames rebuilds once.
  final FrameCoalescedTick _turnTick = FrameCoalescedTick();
  SapSession? _tickFrom;

  /// The regions of the screen (title, command row, body, status / keys)
  /// rebuild on a turn or a busy change; the Scaffold around them only on
  /// a change of the logon itself (connected, failed, the wall).
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
    if (!closed && idle < widget.idleLimit) return;
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

  Future<void> _connect() async {
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
      if (mounted) {
        setState(() => _error = e.toString());
      }
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
        );
    // (a session from the factory learns it here: before the logon this
    // only sets the size the logon reports — no round)
    session.resizeWindow(rows, cols);
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
  /// the stored one behind the biometric gate, else typed (null when the
  /// user cancels).
  Future<(String?, bool)> _gatePassword() async {
    final stored = await _args.store.readPassword(_args.entry.id);
    if (stored == null || stored.isEmpty) {
      return (await _promptPassword(), false);
    }
    try {
      // with no Face ID / Touch ID enrolled (a simulator, an iPad without
      // biometrics) there is no gate to pass: the stored password is used —
      // the Keychain itself only releases it while the device is unlocked
      // (KeychainAccessibility.unlocked_this_device)
      final enrolled = await _localAuth.getAvailableBiometrics();
      if (enrolled.isEmpty) return (stored, true);
      final ok = await _localAuth.authenticate(
        localizedReason: 'Unlock the stored password for ${_args.entry.name}',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
      if (ok) return (stored, true);
    } catch (_) {
      // no biometrics enrolled / unavailable — fall through to manual entry
    }
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

  Future<void> _run(Future<void> Function() fn) async {
    if (_busy || _session == null) return;
    _busy = true;
    try {
      await fn();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      _lastActivity = DateTime.now();
      if (mounted) _busy = false;
    }
  }

  /// A part of the screen drawn from the session's state: rebuilt on a
  /// turn or a busy change, alone.
  Widget _region(WidgetBuilder builder) =>
      ListenableBuilder(listenable: _regionTick, builder: (c, _) => builder(c));

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
    final mq = MediaQuery.maybeOf(context);
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
    return DynproZoomScope(
      widest: _widestCols,
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
            title: _region((_) {
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
              _region(
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
                keyboard: MediaQuery.viewInsetsOf(this.context).bottom,
              );
              return _region((_) {
                SessionScreen.debugBodyBuilds++;
                final m = _screen;
                return _error != null
                    ? _errorView()
                    : m == null
                    ? _connectingView()
                    : _withPlaintextBanner(
                        _withRemoteLogonBanner(_sessionStack(m)),
                      );
              });
            },
          ),
          bottomNavigationBar: _region((_) => _statusAndKeys(_screen)),
        ),
      ),
    );
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
      final panes = [
        for (final r in _onePerShell(regions))
          ?_regionPane(base, r, modalActive),
      ];
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
                    busy: _busy || modalActive,
                    dragShell: _session?.treeShell,
                    onRunTcode: (tcode) =>
                        _run(() async => _session!.okcode('/n$tcode')),
                    onExpand: (key) =>
                        _run(() async => _session!.expandTreeNode(key)),
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
            busy: _busy || modalActive,
            onRunTcode: (tcode) =>
                _run(() async => _session!.okcode('/n$tcode')),
            onExpand: (key) => _run(() async => _session!.expandTreeNode(key)),
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
            onListCell: _stageListCell,
            onDoubleClick: _doubleClick,
            model: base,
            busy: _busy || modalActive,
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
    final panes = [
      for (final r in _onePerShell(regions)) ?_regionPane(popup, r, false),
    ];
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
      onHotspotTap:
          grid.hotspotColumns.isNotEmpty &&
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
      rowAt: (i) => grid.rowAt(i + 1),
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
      busy: _busy,
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

  /// The largest extent the composed window reached in the current
  /// transaction (by program): the scale holds while the user moves between
  /// its screens (ST04's tree picks swap the detail panes), and a new
  /// transaction fits its own window again.
  String? _extentProgram;
  (int?, int?)? _extentWindow;
  Size? _extentMax;

  Size? _stableExtent(String? program, List<ComposedPane> panes) {
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
        v.controlToolbars.containsKey(shell);
  }

  /// One region of a composed window as a pane, by the reference client's rung:
  /// R1 the dynpro grid, R2 a hosted tree / table, R5 a gauge from its
  /// paired field, a chart / network graph / canvas by its shell, R7 (no
  /// content delivered yet) a dashed placeholder with the reference client's legend.
  /// Null for a region that paints nothing.
  ComposedPane? _regionPane(ScreenModel base, ScreenRegion r, bool modal) {
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
          onListCell: _stageListCell,
          onDoubleClick: _doubleClick,
          model: base,
          busy: _busy || modal,
          cell: cell,
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
      if (calendar != null) {
        // the date picker the server hosts for F4 on a date field (the
        // "Calendrier" popup's CONTAINER): a native month grid; a tapped
        // day is the control's date-selected event, the server then
        // closes the popup and fills the field
        content = SapCalendarView(
          key: ValueKey('calendar-${calendar.shell}'),
          calendar: calendar,
          busy: _busy,
          onPick: (day) =>
              _run(() async => _session!.pickCalendarDate(calendar, day)),
        );
      } else if (editor.isNotEmpty) {
        // the ABAP editor control (SE38 / SE80): the source with its
        // breakpoints; a gutter tap toggles one (the session-breakpoint
        // key with the editor cursor), a double tap navigates, the long
        // press offers the where-used list
        final e = editor.first;
        content = SapSourceView(
          key: ValueKey('editor-${e.shell}'),
          lines: e.lines,
          breakpoints: e.breakpoints,
          currentLine: e.cursorLine,
          firstVisibleLine: e.firstVisibleLine,
          onToggleBreakpoint: (line) =>
              _run(() async => _session!.editorToggleBreakpoint(e, line)),
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
          onCaret: (line, col) => _session?.setEditorClientState(
            e,
            caretLine: line,
            caretCol: col,
          ),
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
          busy: _busy || modal,
          // a canvas beside the tree (the BW network graphic, RSNPG_TEST_
          // NETPLAN1) takes its rows as drops
          dragShell: (view?.canvases ?? const <SapCanvasModel>[]).isEmpty
              ? null
              : shell,
          onRunTcode: (tcode) => _run(() async => _session!.okcode('/n$tcode')),
          onExpand: (key) =>
              _run(() async => _session!.expandTreeNodeOf(shell, key)),
          onActivate: (key) =>
              _run(() async => _session!.activateTreeNode(shell, key)),
          onContextMenu: (key, at) => _treeMenu(shell, key, at),
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
      } else if (view?.controlToolbars[shell]?.kind ==
          SapControlToolbarKind.standalone) {
        // a SAP.Toolbar.1 in its own box (the ALV tree's, ME21N's
        // document overview): its button row
        content = _controlToolbar(shell);
      }
    }
    if (content != null) {
      final c = content;
      return ComposedPane(
        cells: cells,
        // a pane shorter than its control's chrome (a 3-row bottom dock on
        // a small window) is cut off at its edge, as SAP GUI's is
        builder: (context, cell) => ClipRect(
          child: LayoutBuilder(
            builder: (context, cons) => cons.maxHeight >= _minPaneHeight
                ? c
                : SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: SizedBox(height: _minPaneHeight, child: c),
                  ),
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
      final onPressed = _busy || !b.enabled || tb == null
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
        child: text.isEmpty && glyph != null
            ? IconButton(
                onPressed: onPressed,
                icon: glyph,
                isSelected: b.checked,
              )
            : TextButton.icon(
                onPressed: onPressed,
                icon: glyph,
                label: Text(text.isNotEmpty ? text : b.code),
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
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: _busy
                          ? null
                          : () => _run(
                              () async => _session!.closeCfwDialog(dialog),
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
            child: SapHtmlView(
              html: d.content,
              onLink: _busy
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
              onFormButton: _busy
                  ? null
                  : (id) => _run(() async => _session!.htmlFormButton(d, id)),
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
  /// * a tap selects (outlined): wire-silent on every recorded canvas, and
  /// where the canvas registered OnObjectSelected (RSNPG_TEST_NETPLAN1)
  /// its PARAMs are on no capture, so the selection stays the client's;
  /// * a long press released on the node, or a secondary click, is the
  /// right-click `%_GC <shell> 4194304` and its menu;
  /// * a tree row dropped on a canvas row is the CFW drop (the server then
  /// reads the drag&drop service).
  /// Node moves stay off: no recorded GUI shows how a move reaches the
  /// server.
  Widget _canvasView(SapCanvasModel c) {
    final (nodes, edges) = canvasGraph(
      c,
      tableFill: Theme.of(context).colorScheme.surfaceContainerHigh,
    );
    return SapGraphView(
      key: ValueKey('canvas-${c.shell}'),
      busy: _busy,
      nodes: nodes,
      edges: edges,
      // links join rows (a recorded session: 3 -> 15, 46 -> 15);
      // a drag on a table's header pans
      canLinkFrom: (n) => n.type == 'row',
      onTapNode: (n) {
        try {
          _session?.canvasClick(c, n.id);
        } on UnsupportedError {
          // OnObjectSelected registered but unrecorded: select locally
        } on ArgumentError {
          // a node the model no longer holds (a repaint is on its way)
        }
      },
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
  /// node double-click (the event the real GUI raises on every click).
  Widget _netPlanView(SapNetPlanModel g) {
    return SapGraphView(
      key: ValueKey('netplan-${g.shell ?? g.title}'),
      title: g.title,
      busy: _busy,
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
    } on Object catch (_) {
      // a field the session cannot stage (protected, Java dialect): it
      // still goes out on Enter
    }
  }

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

  /// A classic list line tapped: the list's pick (F2 on its hotspot).
  Future<void> _listPick(ListLine line) =>
      _run(() async => _session!.pickValue(line));

  /// A list input cell changed (a checkbox ticked): staged, it rides the
  /// list's next key round (F2 on a line, a function key).
  void _stageListCell(ListLine line, ListSegment cell, String text) {
    try {
      _session?.stageListCell(line, cell, text);
    } on ArgumentError catch (e) {
      debugPrint('list cell not staged: $e'); // the list was repainted
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

  /// SAP GUI's command field: a transaction code is at most 20
  /// characters, with its `/n` / `/o` prefix 22 — the field is sized for
  /// that (input is not cut: SY-UCOMM takes longer function codes).
  final TextEditingController _okcodeCtrl = TextEditingController();

  /// SAP GUI's green check beside the command field: the command typed,
  /// else plain Enter.
  void _submitOkcode() {
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
            child: TextField(
              controller: _okcodeCtrl,
              onSubmitted: (_) => _submitOkcode(),
              maxLength: 70,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(fontFamily: 'Menlo', fontSize: 15),
              decoration: const InputDecoration(
                hintText: '/nSE16',
                prefixIcon: Icon(Icons.terminal),
                isDense: true,
                counterText: '',
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
          if (msg.isNotEmpty)
            Container(
              width: double.infinity,
              color: Colors.blueGrey.shade900,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(msg, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    );
  }

  /// ICON_EXECUTE_OBJECT (`@15@`) in the bundled SAP icon font.
  static const _sapExecuteIcon = IconData(0xE004, fontFamily: 'SapIcons');

  /// The status bar's system values, as SAP GUI's dropdown lists them.
  static const _statusInfoLabels = {
    'system': 'Système',
    'client': 'Mandant',
    'user': 'Utilisateur',
    'program': 'Programme',
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

  Widget _errorView() {
    // The session's trace log (last steps of the handshake) — the one line
    // that names where a live logon diverged.
    final trace = _trace ?? _connectLog.value;
    final tail = trace.length <= 6 ? trace : trace.sublist(trace.length - 6);
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
                        busy: _busy,
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
                // during the wall wait the active model IS the wall popup
                final modalModel = wallWait != null
                    ? (m.modalLevel > 0
                          ? m
                          : (_session?.baseScreen?.modalLevel == 0 ? m : m))
                    : m;
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
                    ? _composedModal(modalModel)
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
                  onListCell: !wallPrompt ? _stageListCell : null,
                  onDoubleClick: !wallPrompt ? _doubleClick : null,
                  model: modalModel,
                  content: composedModal?.$1,
                  contentWidth: composedModal?.$2,
                  busy: wallWait != null ? false : _busy,
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

  /// The composed base window / popup: a composition walks the whole
  /// control registry (audit #15), so once per generation, not per build.
  late final List<ScreenRegion> regions = session.regions;
  late final List<ScreenRegion> modalRegions = session.modalRegions;
}
