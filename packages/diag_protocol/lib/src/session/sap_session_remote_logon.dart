part of 'sap_session.dart';

/// A REMOTE logon on a [SapSession] — the SAPMSYST/0029 dynpro an RFC
/// target paints over this connection when a transaction logs on to
/// another system (/SDF/TRCHECK, SE39's split compare, STMS on a virtual
/// system; reference client ). Its frames are RELAYED from the
/// target (imode_scope.dart: its own 16/6/2 / 16/6/3, its own Step counter
/// from 1, an extra imode uuid), so the session's step clock holds and the
/// home internal modes stay as they were.
///
/// The USER types the target's credentials into the painted RSYST-* inputs
/// ([SapSessionFields.stageField], then Enter): GuiGo never fills or keeps
/// them. The password input is painted INVISIBLE (attr 0x62) and its
/// staged value is masked in every trace ([StagedField.secret]); its value
/// atom echoes the INVISIBLE bit like the reference client's build_submit
/// (: `pl["RSYST-BCODE"]["invisible"] = True`).
///
/// The other shape (a recorded session, the real Windows
/// GUI: SM59 *Connexion à distance*, Ctrl+F7): the target's 0029 opens a
/// NEW WINDOW — DIAG mode 1, its own Step clock from 1, its own CFW shell
/// namespace (shells 101–108 again while the logon's 101–106 / 117–123
/// live) — that lives on the target (imode_scope.dart [IModeScope.own]):
/// its frames are no relays, their step is that window's clock. Its
/// submit carries only the MODIFIED atoms — what the user typed (RSYST-
/// MANDT + RSYST-BCODE in raw gui[21]; the prefilled RSYST-BNAME and the
/// untouched RSYST-LANGU are not sent) — which is what an Enter over the
/// staged values builds.
extension SapSessionRemoteLogon on SapSession {
  /// The secondary logon the active window shows, when it names ANOTHER
  /// system than this logon's own ([homeSystem]): (target system id,
  /// target host, the client the logon proposes). Null on every other
  /// screen — the initial logon, a logon screen echoing the session's own
  /// system id (reference client remote_login.detect `initial`).
  ({String sysid, String host, String client})? get remoteLogon {
    final r = screen?.remoteLogon;
    if (r == null) return null;
    final own = homeSystem?.sid ?? '';
    if (own.isNotEmpty && r.sysid.toLowerCase() == own.toLowerCase()) {
      return null;
    }
    return r;
  }

  /// A multi-logon wall RELAYED from another system (the RFC target's own
  /// "user already logged on" popup during a remote logon): it is the
  /// target's question, not this logon's — never auto-answered like the
  /// bootstrap's wall ([SapSession.endOtherSessions] / [SapSession.onWall]
  /// decide THIS logon only). Null unless the active window is on it;
  /// answer with [answerRelayedWall] (or its radios + Enter).
  WallInfo? get relayedWall {
    final w = _w;
    final remote = w.onRelay || _layoutState.imodes.elsewhere != null;
    if (!remote || !(screen?.isKernelLogon ?? false)) return null;
    return w.relayedWall;
  }

  /// Answer the [relayedWall] with [which], at the relayed frame's own step
  /// (the wall answer echoes the wall paint's step, a recorded session
  /// multilogon_b gui raw[2]). [WallOption.cancelLogon] cancels the REMOTE
  /// logon only.
  Future<List<Uint8List>> answerRelayedWall(WallOption which) {
    final wall = relayedWall;
    if (wall == null) {
      throw StateError('no multi-logon wall relayed from another system '
          'on this screen');
    }
    final row = wallRowFor(wall, which);
    if (row == null) {
      throw ArgumentError('the relayed wall offers no ${which.name} option');
    }
    _w.relayedWall = null;
    _trace('wall relayed from ${relayedSystem ?? '?'} answered by the user '
        '(${which.name}, step $step)');
    return _act(
        windowsWallItems(step, wall, row, windowRect: windowsWindowRect(ctx)),
        dialectReady: true);
  }

  /// Keep a multi-logon wall the RELAYED frames among [frames] paint for
  /// the user; returns the HOME frames (the ones a logon wall may be
  /// answered from).
  List<Uint8List> _splitRelayedWall(List<Uint8List> frames) {
    SystemIdentity? from(Uint8List f) =>
        _relayFrames[f] ?? _remoteWindowFrames[f];
    final relayed = [
      for (final f in frames)
        if (from(f) != null) f,
    ];
    if (relayed.isEmpty) return frames;
    final wall = readWall(relayed);
    if (wall.isWall && _w.relayedWall == null) {
      _w.relayedWall = wall;
      _trace('multi-logon wall relayed from ${from(relayed.last)}: '
          'left to the user, not answered as this logon\'s');
    }
    return [
      for (final f in frames)
        if (from(f) == null) f,
    ];
  }
}
