part of 'sap_session.dart';

/// The classic Basis-Graphik conversation of an inline GRAPH item (APPL
/// 16/2/5 — SAPLGRAP/0100: GRAL NETZ_BO3 / GRCNETC2 / GRBUSG_3 F8, CNG9 F5 /
/// F6) on a Windows connection, as the real SAP GUI for Windows holds it
/// (a recorded session, a recorded session; every client step
/// the server's, echoed):
/// * NETZ_BO3 srv[16] (33) the graph's first chunk (kind `05`, 16 016 B,
/// no node yet), srv[17] (34) its last (kind `04`, 7 411 B) — read on
/// until complete ([_inlineGraphOpen]); a one-chunk graph is followed by
/// an empty last chunk `04` (GRCNETC2 srv[63]/[64], cng9 srv[32]/[33]);
/// * the graph is up: clicks inside it leave no wire trace (NETZ_BO3:
/// Noeud 2 selected, a node double-clicked, nothing sent);
/// * Back in the graph → g[13] (34) the graph's own message `INETZ` /
/// `CABCK` ([inlineGraphEventMessage]) — no dynpro key round; it cannot
/// be a post-paint handshake: its answer srv[18] (35) is the close
/// message (`G1 KNETZ`) and the program leaves the graph, which the
/// user was still looking at;
/// * → g[14] (35) the done reply `D E0` ([inlineGraphDoneMessage]), srv[19]
/// (36) an empty round, srv[20] (37) the selection screen;
/// * the business graphic (GRBUSG_3 srv[71]) exits with `D E3` alone
/// (g[55]), no close message.
extension _SapSessionGraph on SapSession {
  /// The active window's inline graph is still being transmitted: its
  /// continuation follows unasked, so the paint does not end the action.
  bool get _inlineGraphOpen {
    final g = screen?.inlineGraph;
    return g != null && !g.complete;
  }

  /// Back (F3) on a complete inline graph: the graph's own Back message,
  /// null when [vkey] is no such key here (every other key keeps its
  /// dynpro round — no recording shows the graph send another).
  Future<List<Uint8List>>? _inlineGraphKey(int vkey) {
    if (vkey != 3 || answerDialect != GuiDialect.windows) return null;
    final m = screen;
    final g = m?.inlineGraph;
    final iface = g?.interface;
    if (m == null || m.modalLevel != 0 || g == null || !g.complete) {
      return null;
    }
    if (iface == null) return null;
    // the business and statistics graphics' windows close with the done
    // reply `D E0` alone, no close message follows (classic_graphics
    // GRBUSG_2 (36) and GRSTAT_1 srv[21] (30) -> g[14] (30) -> the
    // selection screen srv[23]); never `CABCK`, which GET_STAT_PARAM reads
    // as a curve click `C<curve><index>`. gfw_demos GRBUSG_3's `D E3`
    // (g[55]) was that GUI FAILING to draw the graphic: srv[72] answers
    // "Err. n° 3 ds SAPGUI lors appel graphique" (GRAPH_RECEIVE A004) —
    // GuiGo draws it, so it closes cleanly. The network / cluster editors
    // close with `CABCK` (NETZ_BO3 g[13], GRCNETC2 g[50], cng9 gui[33])
    final message = iface == 'BUSG' || iface.startsWith('STAT')
        ? inlineGraphDoneMessage()
        : inlineGraphEventMessage(iface, 'ABCK');
    _trace('inline graph $iface: Back sent as the graph\'s own exit');
    return _exclusive('action', () async {
      // the empty last chunk (cng9 srv[33]) may still sit unread: its step
      // is the one the message echoes (gui[33] at 76, not the paint's 75)
      if (!g.receiving) await _drainPending();
      return _actLocked(windowsInlineGraphItems(ctx, message),
          dialectReady: true);
    });
  }

  /// Answer the GRAPH messages of [frames] that owe the client's reply:
  /// the close message's done reply (cng9 srv[34] → gui[34] at the
  /// message's own step), the profile service's request and close (xxl
  /// srv[21] → gui[14] `IPROF RC=1,`, srv[22] → gui[15] `D E0`,
  /// [inlineProfileReply] — unanswered, SAPLGRAP waits and XXL never
  /// reaches its popups). Returns the number of frames sent.
  Future<int> _answerInlineGraph(List<Uint8List> frames) async {
    if (answerDialect != GuiDialect.windows) return 0;
    final owed = <Uint8List>[];
    for (final f in frames) {
      final dec = decompressFrame(f);
      if (dec == null) continue;
      for (final it in dec.walk.items) {
        if (!it.isAppl || it.id != applGraph || it.sid != 5) continue;
        final v = it.value; // read, never kept
        final reply = inlineProfileReply(v) ??
            (inlineGraphReplyOwed(v) ? inlineGraphDoneMessage() : null);
        if (reply != null) owed.add(reply);
      }
    }
    for (final message in owed) {
      final frame = clientFrame(windowsInlineGraphItems(ctx, message));
      _trace('inline graph reply ${_frameTrace(frame)}');
      await _send(frame);
    }
    return owed.length;
  }
}
