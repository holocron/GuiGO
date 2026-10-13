part of 'sap_session.dart';

// SAP GUI WINDOWS on one logon — the DIAG MODE table (a port of the reference client's
//, its raw_transport mode byte / close handling and
// raw_settle's mode-control frame classes).
//
// Wire contract (a recorded session, the real Windows GUI; the same
// bytes in the Java reference client trace a recorded session):
// * a DIAG message's header byte 0 is its MODE (= window). Each mode has
// its OWN dialog-step counter (a new mode starts again at Step 1: raw
// srv[12] mode 1 step 1 after mode 0 stood at 15) and its own CFW shell
// namespace (shells 101–105 are created again in every window: srv[12]
// repeats the logon's srv[5] Easy Access build);
// * a mode is born with its first STEP-BEARING message in a mode byte the
// table does not hold. The 8-byte `0m 0c 00 00 00 01 00 00` header-only
// frame is the EOP|NOP turn end of the mode that asked (raw srv[11]
// after the `/O0` of gui[5]), NOT a create marker (reference client
// raw_settle._is_turn_end_frame);
// * a mode ends with the 8-byte `0m 09 00 00 00 01 00 00` (EOP|EOS) frame
// (raw srv[28] after gui[18] `/i`; reference client raw_settle._frame_closes_mode);
// * the number the user sees ("(n)") rides only the 16/12/10 window title
// `SAP R/3 (n) SID`; numbers are not reused while the logon lives
// (mode 1 = (2) closed, the next window is mode 2 = (3): srv[41]).
//
// Frontend (SAP GUI for Java 8.10, GuiConnection.mSessionMultiplexers): ONE
// socket reader + ONE writer, one multiplexer per window. GuiGo keeps the
// same split: everything a window owns lives on its [_WindowState] (screen,
// step, staged values, paint mirror, layout / imode scope, every shell- and
// url-keyed control cache); the socket, the logon and the trace are shared.

/// Who opened a window of the logon.
enum SapWindowOrigin {
  /// The logon's first window (DIAG mode 0).
  logon,

  /// Opened by the client's own window command — `/o<tcode>`, `/o0`
  /// (the Windows GUI's *Créer session*: a recorded session raw gui[5]
  /// `/O0`), Ctrl+N. It inherits the client's geometry and owes no
  /// mode-entry round (reference client mode_table.client_opened).
  client,

  /// Opened by the SERVER inside an action — a menu function starting a
  /// new window (Système > Données utilisateur: a recorded session raw
  /// srv[40], mode 2), an editor / log viewer a transaction opens
  /// (a recorded session raw srv[1539] mode 1, srv[1578] mode 2),
  /// the debugger.
  server,
}

/// One SAP GUI window of the logon (a DIAG mode), as [SapSession.windows]
/// reports it. A snapshot: read [SapSession.windows] again after an action.
class SapWindow {
  const SapWindow({
    required this.mode,
    required this.number,
    required this.title,
    required this.program,
    required this.dynpro,
    required this.origin,
    required this.closed,
    required this.active,
    required this.step,
  });

  /// The DIAG mode byte (frame header byte 0) — the window's identity on
  /// the wire and the key [SapSession.selectWindow] takes.
  final int mode;

  /// The window number the title shows (`SAP R/3 (n) SID`), else mode + 1
  /// (the kernel numbers windows from 1 in creation order). Display only:
  /// the server is not bound to it (a recorded session raw
  /// srv[1581] titles mode 2 `(1)` like mode 0) — key on [mode].
  final int number;

  /// The 16/12/10 window title (`SAP R/3 (2) the test system`), '' before one painted.
  final String title;

  /// The program / dynpro the window shows (its active screen).
  final String? program;
  final String? dynpro;

  final SapWindowOrigin origin;

  /// The server ended the window (`0m 09` close frame).
  final bool closed;

  /// The window the session's single-window API ([SapSession.screen],
  /// [SapSession.press], …) currently addresses.
  final bool active;

  /// The window's own dialog step.
  final int step;

  @override
  String toString() =>
      'SapWindow(mode $mode, ($number) $program/$dynpro, '
      '${origin.name}${closed ? ', closed' : ''}${active ? ', active' : ''}, '
      'step $step)';
}

/// The client's own window command an action carries (reference client
/// mode_table.note_client_command).
enum _ModeCommand { open, close }

/// A close of the LIVE window, settled once its turn was read.
class _ModeClose {
  _ModeClose(this.closed, this.parent, {required this.clientCaused});
  final _WindowState closed;
  final _WindowState parent;
  final bool clientCaused;

  /// A step-bearing frame of [parent] arrived after the close (reference client
  /// raw_transport `painted`: the parent repainted in the same batch).
  bool parentRepainted = false;
}

/// Everything ONE window owns (reference client mode_table CONTROL_ATTRS +
/// SCREEN_ATTRS). [SapSession]'s per-window fields read the active one.
class _WindowState {
  _WindowState(
    this.mode,
    this.origin, {
    required int screenRows,
    required int screenCols,
    this.parentMode,
  }) : ea = EaSession(screenRows: screenRows, screenCols: screenCols),
       ctx = ActionContext(screenRows: screenRows, screenCols: screenCols);

  final int mode;
  final SapWindowOrigin origin;

  /// The window live when this one was born — where its close lands
  /// (reference client raw_transport `_mode_return`).
  final int? parentMode;

  int? titleNumber;
  String windowTitle = '';

  /// The Windows GUI's first round in this window is still to be sent: it
  /// carries the FONTMETRIC / DISPLAY_SIZE / MAINAREA_SIZE atoms
  /// ([windowsFirstRoundItems]; a recorded session raw gui[8] / gui[29],
  /// a recorded session gui[1274] / gui[1297]). Every window born
  /// after the logon owes it; the logon's own window had its first round in
  /// the logon submit.
  bool firstRoundOwed = false;

  /// The window's last round went out from inside a popup (its SES modal
  /// level > 0) with the popup's 16/4/36 rect: the next main-window round
  /// carries the display size
  /// (SapSession._withAfterPopup, frontend_profile.windowsAfterPopupItems).
  bool popupRoundSent = false;
  int get number => titleNumber ?? mode + 1;

  /// Raw payloads the server sent this window while another one was
  /// addressed (reference client mode_table.park), delivered when it is selected or
  /// resumed.
  final List<Uint8List> queue = [];

  // --- screen state (SCREEN_ATTRS) ---
  int step = 0;

  /// The foreign-system step clock (reference client imode_scope.clock_step, D2):
  /// the last step of a frame from the logon's OWN system, and whether
  /// the window's latest step-bearing frame was relayed from another one
  /// (an RFC remote logon's SAPMSYST/0029 and progress frames carry the
  /// target's own Step counter from 1 — a recorded session
  /// recv/62326731d295 SAPMSYST_1 / _8: steps 1, 2, 4 … under the test system's 21).
  /// [step] stays the wire step (every reply echoes it); generation
  /// arithmetic runs on [SapSession.clockStep].
  int homeStep = 0;
  bool onRelay = false;
  SystemIdentity? relayedFrom;

  /// A multi-logon wall the relayed frames painted, kept for the user
  /// (sap_session_remote_logon.dart).
  WallInfo? relayedWall;
  ScreenModel? screen;
  ScreenModel? baseScreen;
  ActionContext ctx;
  final List<StagedField> staged = [];
  (String?, String?, int)? stagedScreen;

  /// Classic-list input cells typed / ticked but not yet sent and the
  /// screen they belong to ([SapSessionFields.stageListCell]).
  final List<StagedListCell> stagedListCells = [];
  (String?, String?, int)? listCellScreen;

  // --- control state (CONTROL_ATTRS): keyed by shell id / DP url ---
  final EaSession ea;
  final DoiState doi = DoiState();
  final Map<String, PropertySink> propertySinks = {};
  final Set<String> loadedSinks = {};
  final Map<String, List<String>> expandedKeys = {};

  /// tree shell -> its selected node keys (SelectionKeys read-backs)
  final Map<String, List<String>> selectionKeys = {};

  /// tree token (shell / handle) -> the HeaderNames table the server
  /// assigned it, the newest assignment of any tree, and the newest
  /// ItemEx/Hidden(0) declaration list (sap_session_tree.dart
  /// _noteHeaderNames)
  final Map<String, HeaderNamesTable> headerNames = {};
  HeaderNamesTable? lastHeaderNames;
  List<String> declaredHeaders = const [];

  /// header key -> the width in chars the server last declared for it
  /// (`ABAPWidth(<chars>, 0)` after its `ItemEx` / `HierarchyHeader`) —
  /// what a `WidthInChar` read answers (sap_session_tree.dart)
  final Map<String, int> headerWidths = {};
  final AutomationStream autoStream = AutomationStream();
  final StreamPaintAssembler streamPaints = StreamPaintAssembler();
  final AnsweredCalls answeredFlushes = AnsweredCalls();

  SapTreeModel? tree;
  final List<DpTable> treeTables = [];
  String? treeProgram;

  /// The internal mode [tree] was bound in, and the singular trees of the
  /// window's OTHER live imodes, hidden but kept (sap_session.dart
  /// _keepOrRestoreTree): imode -> (tree, its tables, its program).
  String? treeIMode;
  final Map<String, (SapTreeModel?, List<DpTable>, String?)> keptTrees = {};
  bool treeUnbound = false;

  /// The DP cache's arrival counter ([DpCache.seq]) the tree fold has read
  /// up to — a counter, not an index: the bounded cache evicts.
  int dpSeen = 0;
  bool bindTreeAfterFold = false;

  final Map<String, SapGridAssembler> gridAsm = {};
  final List<_GridSlot> grids = [];
  final Set<String> gridsPending = {};
  String? gridBaseKey;

  final SapChartTracker chartTracker = SapChartTracker();
  final List<_ChartSlot> charts = [];
  final Set<String> chartsPending = {};
  String? chartBaseKey;

  final SapNetPlanTracker netPlans = SapNetPlanTracker();

  /// the picture controls' urls, display modes and pushed pictures
  final SapPictureTracker pictureTracker = SapPictureTracker();

  SapWindow snapshot({required bool active, bool closed = false}) => SapWindow(
    mode: mode,
    number: number,
    title: windowTitle,
    program: screen?.program,
    dynpro: screen?.dynpro,
    origin: origin,
    closed: closed,
    active: active,
    step: step,
  );
}

/// The session's mode table: the open windows, the live one, the one the
/// per-window state is read from ([w] — the live window, except while a
/// frame of another window is folded / answered).
class _WindowTable {
  final Map<int, _WindowState> open = {};

  /// The logon's own system (imode_scope.dart [HomeSystem]), latched from
  /// its first frame naming one — shared by every window.
  final HomeSystem home = HomeSystem();
  final List<SapWindow> closed = [];
  late _WindowState w;
  int liveMode = 0;
  _WindowState get live => open[liveMode] ?? w;

  /// The window command noted for the next action / carried by the
  /// running one.
  _ModeCommand? pendingCommand;
  _ModeCommand? actionCommand;

  /// The live window closed in the turn just read; settled by the action.
  _ModeClose? close;

  /// After a close of the live window the next step-bearing frame of any
  /// open window continues the conversation (never parked).
  bool followNext = false;

  /// The window each received frame was routed to.
  final Expando<_WindowState> frameWindow = Expando('frameWindow');

  final changes = StreamController<List<SapWindow>>.broadcast();
  String? signature;

  /// Every 8-byte mode-control frame seen (hex), newest last.
  final List<String> controlLog = [];
}

/// A bare 8-byte DIAG header from the server — a mode-management frame
/// (reference client raw_transport._note_mode_control, a recorded session raw
/// srv[11] / [28] / [39] / [108] / [109]): uncompressed, com_flag EOP set,
/// no items. NI_PING / NI_PONG (`NI_P…\0`, also 8 bytes, 0x49 has the EOP
/// bit) are NOT one.
bool isModeControlFrame(Uint8List f) {
  if (f.length != diagHeaderLen || f[7] != 0) return false;
  if (f[1] & comFlagTermEop == 0) return false;
  return !(f[0] == 0x4e && f[1] == 0x49 && f[2] == 0x5f); // "NI_"
}

/// The mode-CLOSE notification `0m 09 …`: EOP|EOS in a mode > 0, neither
/// EOC nor NOP (reference client raw_settle._frame_closes_mode; a recorded session
/// raw srv[28] `01 09`, a recorded session raw srv[1557] `01 09` /
/// srv[1592] `02 09`).
bool modeControlCloses(Uint8List f) =>
    isModeControlFrame(f) &&
    f[0] != 0 &&
    f[1] & comFlagTermEos != 0 &&
    f[1] & (comFlagTermEoc | comFlagTermNop) == 0;

/// Whether a mode-control frame ends the server's turn: the EOP|NOP turn
/// end of the mode that asked (`00 0c`, `01 0c` after every debugger paint
/// — reference client raw_settle._is_turn_end_frame), a close (EOS) or the end of the
/// conversation (EOC `00 0a`, the logoff: a recorded session raw
/// srv[109]).
bool modeControlEndsTurn(Uint8List f) =>
    isModeControlFrame(f) &&
    f[1] & (comFlagTermNop | comFlagTermEos | comFlagTermEoc) != 0;

/// The END OF CONVERSATION `00 0a 00 00 00 01 00 00` (EOP|EOC): the
/// server logged the session off — the `=YES` of Système > Fin de session
/// (a recorded session raw srv[20]), a `/nex`
/// (a recorded session raw srv[33], a recorded session
/// raw srv[44]). The server closes the socket right after it; the real
/// GUI sends nothing more.
bool modeControlEndsConversation(Uint8List f) =>
    isModeControlFrame(f) && f[1] & comFlagTermEoc != 0;

final RegExp _windowNumberRx = RegExp(r'\((\d{1,3})\)');

/// (step, 16/12/10 window title) of a server frame; step null for a frame
/// that carries none (header-only, NI text frames).
(int?, String?) _stepAndTitle(Uint8List frame) {
  if (frame.length <= diagHeaderLen) return (null, null);
  final dec = decompressFrame(frame);
  if (dec == null) return (null, null);
  int? step;
  String? title;
  for (final it in dec.walk.items) {
    if (!it.isAppl) continue;
    if (it.id == 4 && it.sid == 38 && it.value.length >= 4 && step == null) {
      step = ByteData.sublistView(it.value).getUint32(0);
    } else if (it.id == 12 && it.sid == 10 && it.value.isNotEmpty) {
      title = wireDecode(it.value).trim();
    }
  }
  return (step, title);
}

/// The parent-mode RESUME round the real JAVA GUI sends after the server
/// closed the mode it was in: the parent window's key envelope at the
/// parent's last step with SES eventarray 1 / eventid 47 and the function
/// key 47 UI event source, no OKCODE item (a recorded session gui[69]
/// `01 2f …` mode 0 step 106 after srv[66] `01 09`; reference client raw_transport
/// _mode_return_items). [windows] respells it for a Windows connection
/// (SES `50 2f`, the reference client's WIN_SES_EVENTARRAY) — a shape no real Windows
/// GUI capture shows: the Windows GUI sends no resume round
/// ([SapSession.resumeRoundAfterServerClose]).
List<Uint8List> modeReturnItems(ActionContext ctx, {bool windows = false}) {
  final base = pressItems(ctx, 47);
  if (windows) return windowsActionItems(base, ctx: ctx);
  final out = <Uint8List>[];
  for (final raw in base) {
    final walk = walkItems(raw);
    final it = walk.items.length == 1 ? walk.items.single : null;
    if (it != null && it.type == itemSes && it.value.length >= 2) {
      final v = Uint8List.fromList(it.value);
      v[0] = 0x01; // the Java FKEY event family (gui[69] `01 2f`)
      out.add(Uint8List.fromList([itemSes, ...v]));
    } else if (it != null && it.isAppl && it.id == 9 && it.sid == 10) {
      out.add(buildApplItem(15, 1, uiEventFunctionKey(47)));
      out.add(raw);
    } else {
      out.add(raw);
    }
  }
  return out;
}

extension SapSessionWindows on SapSession {
  // --- public API -------------------------------------------------------------

  /// The OPEN windows of this logon (one per DIAG mode), by mode byte —
  /// the window's identity (the reference client's 847ec3a: handle = mode + 1); the
  /// title's "(n)" is display only and repeats (su53 titles server mode 2
  /// `(1)`, like mode 0). A logon that never opened a second window has
  /// exactly one (mode 0).
  List<SapWindow> get windows {
    final open = _modes.open.values.toList()
      ..sort((a, b) => a.mode.compareTo(b.mode));
    return [
      for (final w in open) w.snapshot(active: w.mode == _modes.liveMode),
    ];
  }

  /// Every window the logon had, the closed ones included (closed first, in
  /// closing order, then the open ones).
  List<SapWindow> get allWindows => [..._modes.closed, ...windows];

  /// The window the single-window API addresses.
  SapWindow get activeWindow => _modes.live.snapshot(
    active: true,
    closed: !_modes.open.containsKey(_modes.liveMode),
  );

  /// The DIAG mode of [activeWindow].
  int get activeMode => _modes.liveMode;

  /// Fires with [windows] whenever a window opens or closes, the active
  /// one changes, or a window's title / program changes.
  Stream<List<SapWindow>> get windowsChanged => _modes.changes.stream;

  /// Whether the active window was opened by the server (reference client
  /// mode_envelope.in_server_mode — keyed on the ORIGIN, never on "mode
  /// byte != 0"). The Windows dialect builds every window's rounds from
  /// that window's own paint either way (every in_server_mode branch of
  /// the reference client is `frontend != "windows"`): a recorded session
  /// raw gui[1297], the F6 in server-opened mode 2, is the ordinary key
  /// round stamped mode 2 at the window's step 6.
  bool get inServerMode => _modes.live.origin == SapWindowOrigin.server;

  /// Make the window of DIAG [mode] the active one: [screen], [step], the
  /// controls, the staged values and every action from here on are that
  /// window's (reference client mode_table.select). Frames the server sent it while
  /// another window was addressed are folded (and answered) now. Nothing
  /// goes on the wire for the switch itself.
  Future<void> selectWindow(int mode) =>
      _exclusive('a window switch', () => _selectWindow(mode));

  Future<void> _selectWindow(int mode) async {
    final win = _modes.open[mode];
    if (win == null) {
      throw ArgumentError(
        'no open window in DIAG mode $mode — open: '
        '${[for (final w in windows) 'mode ${w.mode} (${w.number})'].join(', ')}',
      );
    }
    if (mode == _modes.liveMode) return;
    _modes
      ..liveMode = mode
      ..w = win;
    _trace(
      '[mode] window (${win.number}) selected: DIAG mode $mode '
      'step ${win.step}',
    );
    await _deliverParked(win);
    _notifyWindows();
  }

  // --- wire rules ---------------------------------------------------------------

  /// Note the client's own window command an okcode / key carries (reference client
  /// mode_table.note_client_command; raw_okcode: `/o…`, `/i…` are plain
  /// okcodes on the wire — a recorded session raw gui[5] `/O0`,
  /// gui[18] `/i`).
  void _noteModeCommand({String? okcode, int? vkey}) {
    final t = okcode?.trim().toLowerCase();
    if (t != null && t.startsWith('/o')) {
      _modes.pendingCommand = _ModeCommand.open;
    } else if (t != null && RegExp(r'^/i\d*$').hasMatch(t)) {
      _modes.pendingCommand = _ModeCommand.close;
    } else if (vkey == 74) {
      // Ctrl+N (a recorded session: function key 74 opened mode 1)
      _modes.pendingCommand = _ModeCommand.open;
    }
  }

  /// Run [f] with the per-window state of [win]; the live window's after.
  T _inWindow<T>(_WindowState win, T Function() f) {
    _modes.w = win;
    try {
      return f();
    } finally {
      _modes.w = _modes.live;
    }
  }

  /// Route one received (unwrapped) DIAG frame to its window (reference client
  /// raw_transport._observe_received + mode_table.note_frame / follow /
  /// park): the mode is taken from STEP-BEARING frames only — a frame
  /// without a step (an NI text frame, …) stays with the live window. A
  /// new mode byte is a window born and followed; a known open window
  /// other than the live one gets the frame parked on its queue (null
  /// returned) — the conversation stays where the action addressed it.
  /// Keyed on the MODE BYTE alone, never on a step reset: a remote logon's
  /// frames relayed from its RFC target restart at Step 1 in the SAME mode
  /// and window (a recorded session SAPMSYST_1, mode 0 step 1
  /// under the test system's 21) — the step clock holds (imode_scope.dart), no window
  /// is born (foreign_step_clock_test.dart).
  _WindowState? _routeFrame(Uint8List payload, Uint8List frame) {
    final (step, title) = _stepAndTitle(frame);
    if (step == null || frame.length < diagHeaderLen) return _modes.live;
    final m = frame[0];
    var win = _modes.open[m];
    if (win == null) {
      win = _bornWindow(m, step);
    } else if (m != _modes.liveMode) {
      if (!_modes.followNext) {
        win.queue.add(payload);
        if (win.queue.length > 256) win.queue.removeAt(0);
        _trace(
          '[mode] frame of window (${win.number}) (DIAG mode $m, step '
          '$step) parked while window (${_modes.live.number}) is addressed',
        );
        return null;
      }
      _follow(win);
    }
    _modes.followNext = false;
    final close = _modes.close;
    if (close != null && identical(close.parent, win)) {
      close.parentRepainted = true;
    }
    if (title != null) _noteWindowTitle(win, title);
    return win;
  }

  /// [title] (a 16/12/10 window title) is [win]'s from now on, its "(n)"
  /// the window number it shows.
  void _noteWindowTitle(_WindowState win, String title) {
    win.windowTitle = title;
    final n = _windowNumberRx.firstMatch(title);
    if (n != null) win.titleNumber = int.parse(n.group(1)!);
  }

  /// A materialized STREAM paint ([isStreamCarrier]) titles its window: the
  /// 16/12/10 of a stream-form paint rides INSIDE the 16/8/4 + 16/8/6
  /// stream, so the wire frame [_routeFrame] reads carries none
  /// (a recorded session srv[27] + srv[28], the debugger window
  /// opened as DIAG mode 1: `ABAP Debugger(1) …`; a recorded session
  /// launch_reference_live's ME21N stream paint). Only the TITLE is read off
  /// the carrier — its nested step and imode list are the paint's own,
  /// stale (the step / clock / imode readers skip carriers).
  void _noteCarrierTitles(_WindowState win, List<Uint8List> frames) {
    for (final f in frames) {
      if (!isStreamCarrier(f)) continue;
      final (_, title) = _stepAndTitle(f);
      if (title != null) _noteWindowTitle(win, title);
    }
  }

  _WindowState _bornWindow(int mode, int step) {
    final parent = _modes.live;
    final origin = _modes.actionCommand == _ModeCommand.open
        ? SapWindowOrigin.client
        : SapWindowOrigin.server;
    final win = _WindowState(
      mode,
      origin,
      screenRows: screenRows,
      screenCols: screenCols,
      parentMode: _modes.liveMode,
    );
    // the client's own window facts carry over; the paint mirror does not
    win.ctx
      ..winPxHeight = parent.ctx.winPxHeight
      ..winPxWidth = parent.ctx.winPxWidth
      ..winFontMetric = parent.ctx.winFontMetric
      ..winDisplayPx = parent.ctx.winDisplayPx
      ..winMainAreaPx = parent.ctx.winMainAreaPx
      ..os = parent.ctx.os;
    if (parent.ctx.windowSized) {
      // the client's window size, in the kernel's 22 x 7 cell (the one
      // every Windows window is laid out in — ActionContext.kernelCell)
      win.ctx.sizeWindow(parent.ctx.screenRows, parent.ctx.screenCols);
    }
    win.firstRoundOwed = true;
    _inheritLayoutKnobs(parent, win);
    _modes.open[mode] = win;
    _trace(
      '[mode] window born: DIAG mode $mode (${origin.name}-opened, its '
      'own step counter from $step; parent mode ${_modes.liveMode})',
    );
    _follow(win);
    return win;
  }

  /// The server moved the conversation to [win] (reference client mode_table.follow).
  void _follow(_WindowState win) {
    if (win.mode == _modes.liveMode) return;
    _modes
      ..liveMode = win.mode
      ..w = win;
    _trace(
      '[mode] following the server into window (${win.number}) '
      '(DIAG mode ${win.mode})',
    );
  }

  /// Classify one 8-byte mode-control frame (reference client raw_transport
  /// _note_mode_control). A close drops the window (reference client
  /// mode_table.note_close); a close of the LIVE window lands the session on
  /// its parent — that window's own state, step and parked frames — and is
  /// settled by the action ([_settleModeClose]).
  void _noteModeControl(Uint8List f) {
    final hex = [for (final b in f) b.toRadixString(16).padLeft(2, '0')].join();
    _modes.controlLog.add(hex);
    if (_modes.controlLog.length > 64) _modes.controlLog.removeAt(0);
    _trace('[mode] mode-control frame $hex');
    if (modeControlEndsConversation(f)) {
      _endOfConversation();
      return;
    }
    if (!modeControlCloses(f)) return;
    final win = _modes.open.remove(f[0]);
    if (win == null) return;
    _modes.closed.add(win.snapshot(active: false, closed: true));
    win.queue.clear();
    if (win.mode != _modes.liveMode) {
      // another window than the live one (`/i<n>`): the live one continues
      _trace(
        '[mode] window (${win.number}) (DIAG mode ${win.mode}) closed; '
        'the live window continues',
      );
      return;
    }
    var parent = win.parentMode == null ? null : _modes.open[win.parentMode];
    if (parent == null && _modes.open.isNotEmpty) {
      final opens = _modes.open.values.toList()
        ..sort((a, b) => a.mode.compareTo(b.mode));
      parent = opens.first;
    }
    if (parent == null) return; // the last window: the logon is ending
    final clientCaused =
        _modes.actionCommand == _ModeCommand.close ||
        win.origin == SapWindowOrigin.client;
    _modes
      ..liveMode = parent.mode
      ..w = parent
      ..followNext = true
      ..close = _ModeClose(win, parent, clientCaused: clientCaused);
    _trace(
      '[mode] window (${win.number}) (DIAG mode ${win.mode}) closed by '
      'the ${clientCaused ? 'client' : 'server'} — landing on window '
      '(${parent.number}) (DIAG mode ${parent.mode}) at ITS step '
      '${parent.step} with its held screen',
    );
    // what the server sent the parent meanwhile is its continuation
    for (final p in parent.queue.reversed) {
      _inbox.addFirst(p);
    }
    parent.queue.clear();
  }

  /// The server ended the conversation ([modeControlEndsConversation]):
  /// the logon is over, cleanly — a log-off, not a failure, nothing to
  /// replay or reconnect. Like the real GUI nothing more is sent (no
  /// `/nex`, no NI close: a recorded session raw gui[10]
  /// `=YES` is the last client frame); [SapSession.closed] fires with the
  /// log-off, the session is [SessionState.closed] and its transport is
  /// let go (the server closes the socket right after).
  void _endOfConversation() {
    // the logon ladder's own end (an offline replay of a whole capture
    // reads its final log-off; a refused logon): the socket close reports
    // it, as before
    if (loggedOff || _bootstrapping) return;
    loggedOff = true;
    _trace('[mode] end of conversation (EOC): the server logged the '
        'session off — nothing more is sent');
    _notifyClosed();
    if (!offlineReplay) unawaited(_dropTransport());
  }

  /// Fold + answer the frames parked on [win] (now live).
  Future<void> _deliverParked(_WindowState win) async {
    if (win.queue.isEmpty) return;
    for (final p in win.queue.reversed) {
      _inbox.addFirst(p);
    }
    win.queue.clear();
    await _drainPending();
  }

  /// Settle a close of the live window ([_noteModeControl]); returns the
  /// frames a resume round's reply brought (empty when none was sent).
  ///
  /// * CLIENT-caused (`/i`, or the close of a client-opened window): the
  /// session stands on the surviving window exactly as it was and
  /// NOTHING is sent (reference client mode_table.resume_after_close; its trace
  /// a recorded session `/i` -> `01 09`, no round, the next
  /// key goes out at window 1's own step 19).
  /// * SERVER-caused: the parent's repaint may come unasked (reference client
  /// raw_transport 997-1003, a recorded session s[41] `01 09` then
  /// s[42] the parent repaint) — then nothing is sent; else the Java GUI
  /// resumes the parent with the SES-47 round ([modeReturnItems],
  /// a recorded session gui[69]) when
  /// [SapSession.resumeRoundAfterServerClose] is on. The real WINDOWS
  /// GUI sends none: a recorded session raw srv[1557] `01 09`
  /// (after the F15 of gui[1276] in server-opened mode 1) is followed by
  /// the user's own mode-0 click at the parent's step 2368 (gui[1277]),
  /// srv[1592] `02 09` by the user's F3 at mode 0's step 2400
  /// (gui[1305]).
  Future<List<Uint8List>> _settleModeClose(_ModeClose c) async {
    if (c.clientCaused) {
      _trace('[mode] client close: no resume round');
      return const [];
    }
    if (!resumeRoundAfterServerClose) {
      // nothing is awaited: no repaint, no DestroyWindow follows the
      // close — the surviving window resumes on its held state, its next
      // round is the user's own plain one (a recorded session
      // session raw srv[17] `01 09` -> gui[9], a mode-0 menu round at
      // mode 0's step 15; a recorded session raw srv[1557])
      _trace(
        '[mode] server close: the parent waits for input (no resume '
        'round on this dialect)',
      );
      return const [];
    }
    if (!offlineReplay) await _awaitBuffered(const Duration(seconds: 1));
    final parentPainted =
        c.parentRepainted ||
        _inbox.any((p) {
          if (p.length <= 12 || p[0] != c.parent.mode) return false;
          return _stepAndTitle(p).$1 != null;
        });
    if (parentPainted) {
      _trace('[mode] the parent repainted unasked: no resume round');
      return const [];
    }
    _trace(
      '[mode] resuming window (${c.parent.number}) at step '
      '${c.parent.step} (SES event 47)',
    );
    await _send(
      clientFrame(
        _withFirstRound(
          modeReturnItems(ctx, windows: answerDialect == GuiDialect.windows),
        ),
      ),
    );
    final out = <Uint8List>[];
    for (var i = 0; i < 40; i++) {
      if (offlineReplay && _inbox.isEmpty) break;
      final List<Uint8List> got;
      try {
        got = await recvTurn(timeout: const Duration(seconds: 10));
      } on TimeoutException {
        break;
      }
      out.addAll(got);
      final sent = await _driveAutomation(got);
      if (sent == 0 && _paintsScreen(got)) break;
    }
    return out;
  }

  /// Wait until a payload is buffered or [d] passed.
  Future<void> _awaitBuffered(Duration d) async {
    final deadline = DateTime.now().add(d);
    while (_inbox.isEmpty && _sockError == null) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return;
      _wake = Completer<void>();
      await _wake!.future.timeout(left, onTimeout: () {});
    }
  }

  /// [frames] split into consecutive runs of the window each was routed to.
  List<(_WindowState, List<Uint8List>)> _runsByWindow(List<Uint8List> frames) {
    final out = <(_WindowState, List<Uint8List>)>[];
    for (final f in frames) {
      final win = _modes.frameWindow[f] ?? _modes.w;
      if (out.isNotEmpty && identical(out.last.$1, win)) {
        out.last.$2.add(f);
      } else {
        out.add((win, [f]));
      }
    }
    return out;
  }

  /// Fire [windowsChanged] when the window list changed.
  void _notifyWindows() {
    final ws = windows;
    final sig = [
      _modes.liveMode,
      for (final w in ws)
        '${w.mode}/${w.number}/${w.title}/${w.program}/${w.dynpro}',
      _modes.closed.length,
    ].join('|');
    if (sig == _modes.signature) return;
    _modes.signature = sig;
    if (!_modes.changes.isClosed) _modes.changes.add(ws);
  }
}
