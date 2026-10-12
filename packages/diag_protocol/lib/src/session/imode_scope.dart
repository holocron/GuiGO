import 'dart:typed_data';

import '../framing/diag_frame.dart';

/// The ABAP internal-mode (imode) scope of CFW controls — a port of the
/// reference client's (d888b68), the delIMode half.
///
/// The frontend keeps one control manager per internal mode
/// (SAP GUI 8.10 platinr3S.jar `GuiSession.newIMode / curIMode /
/// delIMode`, one `GuiCtlMgr` per imode uuid; a recorded session
/// a recorded session Finding 2): when an imode
/// ends, `delIMode` -> `GuiCtlMgr.cleanUp` destroys every shell of that
/// manager LOCALLY (`DestroyWindow(shellId)` — no verb on the wire). The
/// server announces the live imodes on every frame in ST_R3INFO:
/// `16/6/10 IMODENUMBER` (u16, the index of THIS frame's imode) and
/// `16/6/31 IMODEUUIDS2` (count byte + N x (16-byte uuid + 1 flag byte)).
/// A uuid that leaves the list is a `delIMode`: every shell whose NEWEST
/// creation rode it is dead.
///
/// Leaving a transaction with `/n` is such an end: the real SAP GUI capture
/// a recorded session (ST22 hit list -> `/nSM51`)
/// paints ST22 in imode B (srv[14..19], list `A | B`, index 1, grid shells
/// 118 / 119 created at step 25) and the `/nSM51` reply's first frame
/// (srv[20], step 30) lists `A | C` — B is gone, its shells die, and the
/// same frame's flush re-creates 118 / 119 in C. The kernel sends no
/// DestroyWindow for them anywhere in the capture.
///
/// Per DIAG window (the frame header's mode byte: an external mode is
/// another GuiSession with its own imode set). Inert while the wire never
/// carries 16/6/31: nothing is ever reported gone.
///
/// FOREIGN-SYSTEM frames (the reference client's D2 clock fix,
/// observe_frame / clock_step, d888b68): a transaction that performs a
/// cross-system RFC logon (/SDF/TRCHECK, SE39's split compare, STMS on a
/// virtual system) has the RFC TARGET paint its own SAPMSYST/0029 logon
/// and progress-indicator frames over the SAME connection, mode and window
/// — with that system's 16/6/2 DBNAME / 16/6/3 CPUNAME, its own Step
/// counter from 1 and an extra imode uuid appended to the home list
/// (a recorded session recv/62326731d295 SAPMSYST_1: the test system
/// `the application server`, step 1, IMODEUUIDS2 A | B | C under the test system's A | B; the
/// same shape in a recorded session SAPMSYST_1 frame 2, the test system, and
/// a recorded session SAPMSYST_1, the test system). Such a frame is
/// [lastFrameForeign]: it moves neither the live list nor the current
/// imode (its IMODENUMBER 0 indexes the HOME list's A — read as a home
/// frame, the Easy Access menu would be "current" on the remote logon
/// paint). The home system is latched from the first frame naming one
/// ([home], shared by every window of the logon). The other shape — a
/// remote logon opening a NEW WINDOW (DIAG mode) that lives on the target
/// (SM59 *Connexion à distance*) — is no relay: that window's frames are
/// its own ([own], the reference client DECODE's per-mode home recipe).
class IModeScope {
  IModeScope({HomeSystem? home}) : home = home ?? HomeSystem();

  /// The logon's own system (one instance per logon, shared by its
  /// windows).
  final HomeSystem home;

  final Map<int, _WindowIModes> _windows = {};
  int _mode = 0;

  /// step -> the imode uuid its frame rode (the creation stamp source)
  final Map<int, String> _atStep = {};

  /// shell -> the imode uuid of its NEWEST creation
  final Map<String, String> _shellIMode = {};

  /// The current imode uuid of the active window, null when unknown.
  String? get current => _windows[_mode]?.current;

  /// The live imode uuids of the active window, in server order.
  List<String> get live => List.unmodifiable(_windows[_mode]?.live ?? []);

  /// The imode [shell]'s newest creation rode, null when unknown.
  String? imodeOf(String shell) => _shellIMode[shell.trim()];

  /// Whether the last frame [observe] read was relayed from ANOTHER system
  /// (see the class doc): the session's step clock does not follow it.
  bool lastFrameForeign = false;

  /// The system the last relayed frame came from; null after a home frame.
  SystemIdentity? relayedFrom;

  /// `GuiSession.checkShellIModeContext` false (reference client imode_scope
  /// shell_in_other_imode): [shell]'s newest creation rode a LIVE imode
  /// that is not the current one — the control is neither shown nor
  /// destroyed, and it is on screen again once its imode is current
  /// again. False when either side is unknown (no 16/6/31 on the wire, a
  /// shell created before the first imode fact).
  bool inOtherIMode(String shell) {
    final cur = current;
    if (cur == null) return false;
    final u = _shellIMode[shell.trim()];
    return u != null && u != cur;
  }

  /// Every shell [inOtherIMode] hides right now.
  Set<String> get hiddenShells {
    final cur = current;
    if (cur == null) return const {};
    return {
      for (final e in _shellIMode.entries)
        if (e.value != cur) e.key,
    };
  }

  /// Fold one server frame's ST_R3INFO imode facts; returns the uuids that
  /// left the live list (each a `delIMode`), empty otherwise. A frame
  /// relayed from another system folds nothing ([lastFrameForeign]).
  List<String> observe(Uint8List frame) {
    lastFrameForeign = false;
    final dec = decompressFrame(frame);
    if (dec == null) return const [];
    int? idx, step;
    List<String>? uuids;
    String? db, cpu, client;
    for (final it in dec.walk.items) {
      if (!it.isAppl) continue;
      final v = it.value;
      if (it.id == 4 && it.sid == 38 && v.length >= 4) {
        step = ByteData.sublistView(v).getUint32(0);
      } else if (it.id == 6 && it.sid == 10 && v.length >= 2) {
        idx = (v[0] << 8) | v[1];
      } else if (it.id == 6 && it.sid == 31 && v.isNotEmpty) {
        uuids = [
          for (var i = 0; i < v[0] && 1 + (i + 1) * 17 <= v.length; i++)
            _hex(v, 1 + i * 17, 16),
        ];
      } else if (it.id == 6 && it.sid == 2) {
        db = _r3Text(v);
      } else if (it.id == 6 && it.sid == 3) {
        cpu = _r3Text(v);
      } else if (it.id == 6 && it.sid == 12) {
        client = _r3Text(v);
      }
    }
    final mode = dec.header.mode;
    if ((db ?? '').isNotEmpty || (cpu ?? '').isNotEmpty) {
      final sys = SystemIdentity(db ?? '', cpu ?? '', client ?? '');
      if (_isRelay(sys, mode, uuids)) {
        lastFrameForeign = true;
        relayedFrom = sys;
        return const [];
      }
      relayedFrom = null;
    }
    if (idx == null && uuids == null) return const [];
    _mode = mode;
    final w = _windows[_mode] ??= _WindowIModes();
    var gone = const <String>[];
    if (uuids != null) {
      gone = [
        for (final u in w.live)
          if (!uuids.contains(u)) u,
      ];
      w.live = uuids;
    }
    if (idx != null && idx < w.live.length) {
      w.current = w.live[idx];
      if (step != null) {
        _atStep[step] = w.current!;
        if (_atStep.length > 4096) {
          final old = _atStep.keys.toList()..sort();
          for (final k in old.take(1024)) {
            _atStep.remove(k);
          }
        }
      }
    }
    return gone;
  }

  /// The system THIS window lives on (the scope is per window): latched
  /// from the window's first frame naming one — the logon's own for the
  /// logon's window and the ones it opens, the RFC target's for a window
  /// a REMOTE LOGON opened in a new DIAG mode (SM59 *Connexion à
  /// distance*: a recorded session raw srv[29..42], every
  /// mode-1 frame the test system under the the test system logon, its own Step clock from 1).
  /// Null before that frame.
  SystemIdentity? own;

  /// [own] when it is ANOTHER system than the logon's (the remote-logon
  /// window), else null.
  SystemIdentity? get elsewhere {
    final o = own, h = home.identity;
    return o == null || h == null || h.sameSystem(o) ? null : o;
  }

  /// Latch the home system on the first frame naming one. A frame of
  /// [own]'s system is the window's own (the remote-logon window's frames
  /// are not relays: they move its clock and its imodes). A frame of
  /// ANOTHER system is a relay when it rides the home window's imode stack
  /// — its IMODEUUIDS2 lists every live home imode (the RFC logon runs
  /// inside the home's current imode: A | B | C over A | B in all three
  /// recorded relays) — or when either side lists none. A frame of another
  /// system carrying none of the live home imodes is no relay: only an
  /// offline replay that stitches one system's logon to another system's
  /// transaction produces one (a real connection talks to ONE application
  /// server), and the latch follows it.
  bool _isRelay(SystemIdentity sys, int mode, List<String>? uuids) {
    final h = home.identity;
    if (h == null) {
      home.identity = own = sys;
      return false;
    }
    if (h.sameSystem(sys)) {
      // the logon's first frames may name the client only later
      if (h.client.isEmpty && sys.client.isNotEmpty) home.identity = sys;
      own ??= sys;
      return false;
    }
    final o = own ??= sys;
    if (o.sameSystem(sys)) return false;
    final homeLive = _windows[mode]?.live ?? const <String>[];
    if (uuids == null || homeLive.isEmpty || homeLive.every(uuids.contains)) {
      return true;
    }
    // a stitched replay: this IS the window's (and, on the logon's own
    // window, the logon's) system
    if (h.sameSystem(o)) home.identity = sys;
    own = sys;
    return false;
  }

  /// Stamp a creation of [shell] at [step] with the imode its frame rode
  /// (the current imode when that step was not seen).
  void stamp(String shell, {int? step}) {
    final u = (step != null ? _atStep[step] : null) ?? current;
    if (u != null) _shellIMode[shell.trim()] = u;
  }

  /// The shells whose newest creation rode one of [uuids] — what a
  /// `delIMode` of them destroys. Their stamps are dropped: a dead imode is
  /// never current again.
  Set<String> takeShellsOf(Iterable<String> uuids) {
    final gone = uuids.toSet();
    final dead = {
      for (final e in _shellIMode.entries)
        if (gone.contains(e.value)) e.key,
    };
    dead.forEach(_shellIMode.remove);
    return dead;
  }
}

/// The system a server frame comes from: ST_R3INFO 16/6/2 DBNAME (the
/// system id), 16/6/3 CPUNAME (the application server) and 16/6/12 CLIENT
/// (reference client diag_controlstate _R3INFO 2 / 3 / 12).
class SystemIdentity {
  const SystemIdentity(this.sid, this.host, [this.client = '']);

  /// The system id (DBNAME: `the test system`, `the test system`).
  final String sid;

  /// The application server (CPUNAME: `the application server`).
  final String host;

  /// The frame's client (`200`; `000` on a remote logon paint — nobody is
  /// logged on there yet).
  final String client;

  /// Same system and server; a side that names none matches anything
  /// (reference client imode_scope._is_foreign, inverted).
  bool sameSystem(SystemIdentity o) =>
      !((sid.isNotEmpty && o.sid.isNotEmpty && sid != o.sid) ||
          (host.isNotEmpty && o.host.isNotEmpty && host != o.host));

  @override
  String toString() =>
      '$sid ($host)${client.isEmpty ? '' : ' client $client'}';
}

/// The [SystemIdentity] one server frame names, null when it carries no
/// 16/6/2 / 16/6/3.
SystemIdentity? frameSystemOf(Uint8List frame) {
  final dec = decompressFrame(frame);
  if (dec == null) return null;
  String? db, cpu, client;
  for (final it in dec.walk.items) {
    if (!it.isAppl || it.id != 6) continue;
    if (it.sid == 2) db = _r3Text(it.value);
    if (it.sid == 3) cpu = _r3Text(it.value);
    if (it.sid == 12) client = _r3Text(it.value);
  }
  if ((db ?? '').isEmpty && (cpu ?? '').isEmpty) return null;
  return SystemIdentity(db ?? '', cpu ?? '', client ?? '');
}

/// The logon's own system, latched from its first frame naming one
/// ([IModeScope.observe]); one instance per logon, shared by its windows.
class HomeSystem {
  SystemIdentity? identity;
}

String _r3Text(Uint8List v) {
  var end = v.indexOf(0);
  if (end < 0) end = v.length;
  return String.fromCharCodes(Uint8List.sublistView(v, 0, end)).trim();
}

class _WindowIModes {
  String? current;
  List<String> live = const [];
}

String _hex(Uint8List v, int at, int n) {
  final b = StringBuffer();
  for (var i = at; i < at + n; i++) {
    b.write(v[i].toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}
