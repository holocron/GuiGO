/// The EA (automation) responder: answers live OLE_FLUSH_CALL queues the
/// server sends (ea_core port, DOI-relevant subset) — handle minting,
/// result stamps, the DATAMANAGER control XML and the reply container.
library;

import 'dart:collection';
import 'dart:typed_data';

import '../codepages.dart';
import '../framing/diag_frame.dart';
import '../framing/envelope.dart';
import '../lzh/lzh.dart';
import '../screen/listbox_valueset.dart' show ValueSetStore, isValueSetPush;
import '../screen/sap_barchart.dart' show barChartCuaCodeAnswer;
import '../screen/sap_calendar.dart'
    show calendarHeldInterval, calendarIntervalAnswer;
import '../session/gui_profile.dart' show metricsElement;
import 'browser_launch.dart'
    show shellExecuteAnswer, shellExecuteVerbs, verbArgText;
import 'datamanager_grammar.dart';
import 'dp_cache.dart';
import 'dragdrop_service.dart';
import 'flush_call.dart';
import 'frontend_features.dart';
import 'frontend_files.dart';
import 'frontend_registry.dart'
    show infoCtrlPathAnswer, registryReadAnswer, registryReadVerbs;
import 'frontend_rfc.dart';
import 'reply_container.dart';
import 'text_editor.dart' show textEditInitialCachedProps;
import 'stream_paint.dart';
import 'svars.dart';

class CreatedControl {
  CreatedControl(this.generation, this.stamp, this.handle, this.cls);
  final int generation;
  final String stamp;
  final String handle;
  final String cls;
}

/// Session-side responder state the mint loop and the DOI model share.
class EaSession {
  EaSession({
    this.handleBase = 40000,
    this.screenRows = 26,
    this.screenCols = 170,
    this.dpCacheEntries = dpCacheMaxEntries,
    this.dpCacheBytes = dpCacheMaxBytes,
  }) {
    dpCache
      ..retain = _pushRetention
      ..onPut = _pushStored
      ..onEvict = _pushEvicted;
  }

  /// The push cache's caps ([DpCache.maxEntries] / [DpCache.maxBytes]: the
  /// segments and their decoded memos together) — the session's
  /// TransportLimits for a window, the package defaults for a replay.
  final int dpCacheEntries;
  final int dpCacheBytes;

  int handleBase;
  /// The LIVE dialog step, synced from the session's folded counter before
  /// every drive (answers echo it unchanged — the server owns the counter);
  /// 20 is the offline-replay default when no session drives the responder.
  int step = 20;
  int screenRows;
  int screenCols;
  int modalNo = 0;

  /// GetContainer answers key a container id by the OWNER object the
  /// container is fetched from (first-seen order 2k+1, '1' for the first) —
  /// collapsing owners to one id collides split containers (OBJHOLE2).
  final Map<String, String> containerIds = {};

  /// Container ids minted so far (the next is `2 * n + 1`) — counted apart
  /// from [containerIds] so a capped-out owner never re-mints a live id.
  int containerIdsMinted = 0;

  final List<CreatedControl> createdControls = [];
  final Set<String> destroyedControls = {};

  /// The PARAM values of the last `%_GC` control event sent per shell
  /// (the engine's diag_event_channel): a later OLE GetEventParam(shell,
  /// pid) reads one back — unanswered, the result defaults to an object
  /// handle and SAPLOLEA dumps (GET_USER_TAG / UC_OBJECTS_NOT_CONVERTIBLE).
  final Map<String, Map<int, String>> eventParams = {};

  void recordEvent(String shell, Map<int, String> params) {
    final key = shell.trim();
    eventParams
      ..remove(key) // newest last: the cap drops the least recent shell
      ..[key] = Map.of(params);
    _capOldest(eventParams, maxEventShells);
  }

  /// The recorded event parameter, or null when none was sent.
  String? eventParam(String shell, String pid) {
    final n = int.tryParse(pid.trim());
    if (n == null) return null;
    return eventParams[shell.trim()]?[n];
  }
  final Map<String, String> shellAlias = {}; // server shell <-> reference client mint

  /// The files the server had this frontend write / open
  /// (frontend_files.dart: SecureSaveDataToUrl to `file://`, DeleteFile,
  /// ShellExecute).
  final FrontendFileStore frontendFiles = FrontendFileStore();
  late final DpCache dpCache =
      DpCache(maxEntries: dpCacheEntries, maxBytes: dpCacheBytes);
  final Map<String, DpPushBinding> dpUrlOwner = {}; // url -> binding

  /// DP push url -> the kernel shell it feeds ([noteDpBindings], from the
  /// answered calls' DataProvider bindings — [dpPushBindings]): the
  /// retention verdict of [dpCache] and the pushes [evictDeadPushes] drops.
  final Map<String, String> dpUrlShell = {};

  // --- bounds (no map grows for the logon's whole life) ---------

  /// The caps the session's registries are held under, oldest out first
  /// (the [frontendRfcLog] pattern). Generous: a long session holds far
  /// fewer live controls; only the dead history is trimmed.
  static const int maxCreatedControls = 1024;
  static const int maxDestroyedControls = 2048;
  static const int maxEventShells = 256;
  static const int maxShellAliases = 2048;
  static const int maxContainerIds = 512;
  static const int maxUrlBindings = 1024;

  bool? _pushRetention(String url) {
    final b = dpUrlOwner[url];
    final sh = dpUrlShell[url] ??
        b?.shell ??
        (b?.owner == null ? null : shellAlias[b!.owner!]);
    if (sh == null) return null;
    return !destroyedControls.contains(sh);
  }

  void _pushStored(String url) {
    // a re-push to a url bound to a torn-down control is the url's NEW
    // content (the kernel reuses SAPR3:// urls): the stale binding goes
    final sh = dpUrlShell[url];
    if (sh != null && destroyedControls.contains(sh)) dpUrlShell.remove(url);
    // a listbox value set is folded AT INGEST: it outlives the url cache's
    // sweep of unbound pushes (reference client screen_valueset.push_observer)
    final seg = dpCache.byUrl[url];
    if (seg != null && isValueSetPush(seg)) valueSets.ingest(seg);
  }

  /// The classic dynpro listboxes' value sets pushed to this session
  /// (`application/x-sapvaluesets`), backed by the cross-session cache
  /// (screen/listbox_valueset.dart). One store per connection: every
  /// window of a logon shares its first window's (sap_session_windows.dart).
  ValueSetStore valueSets = ValueSetStore();

  void _pushEvicted(String url) {
    dpUrlShell.remove(url);
    dpUrlOwner.remove(url);
  }

  /// Record which shell each DataProvider push of [call] feeds.
  void noteDpBindings(FlushCall call) {
    for (final b in dpPushBindings(call)) {
      final sh = b.shell ?? (b.owner == null ? null : shellAlias[b.owner!]);
      if (sh == null) continue;
      for (final u in b.urls) {
        dpUrlShell
          ..remove(u)
          ..[u] = sh.trim();
      }
    }
    _capOldest(dpUrlShell, maxUrlBindings);
    _capOldest(dpUrlOwner, maxUrlBindings);
  }

  /// Drop the cached pushes of controls torn down (destroyTab /
  /// DestroyWindow / an ended internal mode) — except the latest ingest's
  /// own ([DpCache.lastIngested]: a reused url's new content whose binding
  /// is recorded after the snoop). Returns the number dropped.
  int evictDeadPushes() {
    final n = dpCache.evictWhere(
        (u) => _pushRetention(u) == false,
        keep: dpCache.lastIngested);
    // the round's decodes count now ([DpCache.decodedBytes]), not from the
    // next push
    dpCache.sweep();
    return n;
  }

  /// Hold the control registries under their caps: the oldest DEAD
  /// controls are forgotten first (registry entries superseded by a later
  /// CreateControl of the same id, then destroyed ones), never a live one
  /// unless the live history alone exceeds the cap.
  void capControlRegistry() {
    if (createdControls.length > maxCreatedControls) {
      final newest = <String, int>{};
      for (var i = 0; i < createdControls.length; i++) {
        newest[createdControls[i].handle] = i;
      }
      var excess = createdControls.length - maxCreatedControls;
      final drop = <int>{};
      for (var i = 0; i < createdControls.length && excess > 0; i++) {
        if (newest[createdControls[i].handle] != i) {
          drop.add(i);
          excess--;
        }
      }
      for (var i = 0; i < createdControls.length && excess > 0; i++) {
        if (!drop.contains(i) &&
            destroyedControls.contains(createdControls[i].handle)) {
          drop.add(i);
          excess--;
        }
      }
      for (var i = 0; i < createdControls.length && excess > 0; i++) {
        if (drop.add(i)) excess--;
      }
      var k = 0;
      createdControls.removeWhere((_) => drop.contains(k++));
    }
    if (destroyedControls.length > maxDestroyedControls) {
      // a dead id forgotten everywhere at once: nothing still names it
      final gone = destroyedControls
          .take(destroyedControls.length - maxDestroyedControls)
          .toSet();
      destroyedControls.removeAll(gone);
      createdControls.removeWhere((c) => gone.contains(c.handle));
      eventParams.removeWhere((k, _) => gone.contains(k));
      dpUrlShell.removeWhere((_, sh) => gone.contains(sh));
    }
    if (shellAlias.length > maxShellAliases) {
      final excess = shellAlias.length - maxShellAliases;
      for (final k in shellAlias.keys.take(excess).toList()) {
        final v = shellAlias.remove(k);
        if (v != null && shellAlias[v] == k) shellAlias.remove(v);
      }
    }
    _capOldest(containerIds, maxContainerIds);
  }

  // set by the DOI layer; when a pluggable automation model drives the
  // graph, the identity-cache echo stays off (mint-by-position)
  bool pluggableAutomation = false;

  /// Whether the session's first creation queue (the logon's Easy Access
  /// build) was answered — see [aliasesRoot].
  bool rootMinted = false;

  /// Windows handle reuse: the handles this session minted one by one
  /// (never the aliased logon root) and those of them a FreeObject
  /// released — the next creation takes the LOWEST released one, as the
  /// OCX does (a recorded session gui[114]: the Performance
  /// Assistant's toolbar CreateControl answers 16, freed by FreeObject #42
  /// from the CreateObject #38; gui[115] answers 18 / 19, freed at the end
  /// of the queue before).
  final Set<int> ownHandles = {};
  final SplayTreeSet<int> freedHandles = SplayTreeSet<int>();
}

/// The streamed-call assembly state between frames: consecutive non-empty
/// id-8/sid-4 chunk VALUES concatenate into one RFC stream that a later
/// sid-0 item closes (the 740 kernel's logon full-build queue: ~30 kB head
/// + 512 B continuation + sid-0 companion, a recorded session).
class AutomationStream {
  AutomationStream({this.maxPendingBytes = defaultMaxPendingBytes});

  /// The bytes a pending stream may gather before it is abandoned:
  /// sid-4 continuations accumulate until a sid-0/1
  /// closer, and a kernel that streams chunks which each end their own
  /// turn would grow the stream for the logon's life. The largest joined
  /// call of the corpora is well under a megabyte; a flush over the cap is
  /// no answerable call.
  static const int defaultMaxPendingBytes = 32 << 20;
  final int maxPendingBytes;

  /// Streams abandoned past [maxPendingBytes], and the latest one's
  /// account; [takeAbandoned] hands the account out once.
  int abandoned = 0;
  String? lastAbandoned;
  bool _abandonedUnreported = false;

  /// The chunks of a multi-frame call received so far, no closer yet —
  /// gathered, not re-joined per continuation (a 100-chunk call copied
  /// the whole stream 100 times).
  BytesBuilder? _pending;

  /// The call stream received so far (a copy), null when none is pending.
  Uint8List? get pending => _pending?.toBytes();

  bool get hasPending => _pending != null;

  void _start(Uint8List head) {
    _pending = BytesBuilder(copy: false)..add(head);
    _capPending(1);
  }

  void _append(Uint8List chunk) {
    _pending!.add(chunk);
    _capPending(2);
  }

  /// The pending stream past [maxPendingBytes] is dropped and counted; the
  /// chunks that follow are plain data until the next head, its closer a
  /// front-end call or nothing. [part]: 1 = the head itself was over.
  void _capPending(int part) {
    final n = _pending!.length;
    if (n <= maxPendingBytes) return;
    _pending = null;
    abandoned++;
    _abandonedUnreported = true;
    final where = part == 1 ? 'the head alone' : 'at a continuation';
    lastAbandoned = 'a chunked automation call grew to $n B without its '
        'closer (ceiling $maxPendingBytes B; $where): abandoned — the '
        'kernel\'s flush goes unanswered';
  }

  /// The account of a stream abandoned since the last call, once (null:
  /// none) — the session counts it as a failed answer.
  String? takeAbandoned() {
    if (!_abandonedUnreported) return null;
    _abandonedUnreported = false;
    return lastAbandoned;
  }

  /// The pending stream with [closer] appended; the stream is reset.
  Uint8List _close(Uint8List closer) {
    final b = _pending!..add(closer);
    _pending = null;
    return b.takeBytes();
  }

  /// The stream-form paint being received (stream_paint.dart).
  final PaintStreamState paint = PaintStreamState();
}

/// One server frame's automation decisions (login_gui_features.fold_frame +
/// frame_is_call_chunk ports).
class AutomationFrame {
  AutomationFrame(this.receiptSteps, this.calls,
      [this.frontendCalls = const [], this.joinedCalls = const {}]);
  final List<int> receiptSteps; // ≤1 entry: the chunk frame's own step
  final List<(Uint8List, int)> calls; // (completed RFC stream, closing step)

  /// The indices into [calls] of the calls JOINED across frames (a sid-4
  /// head, its raw continuations and the sid-0 companion that closed
  /// them) — the shape of a DataProvider push the frontend PULLED, e.g.
  /// the ABAP editor's LEXER_DATA after the creation answer's `<BLOBS>`
  /// request (a recorded session srv[35..46]), which
  /// parses to no verbs yet is owed the empty execution ack
  /// ([buildExecutionAck]).
  final Set<int> joinedCalls;

  /// The front-end RFC requests the frame carried (frontend_rfc.dart):
  /// (request, the frame's step, the item's sid) — a sid-0/1 one owes a
  /// reply at that step, a sid-6 progress tick none.
  final List<(Uint8List, int, int)> frontendCalls;
}

bool _hasParamsColumn(Uint8List value) {
  try {
    return rfcColumns(value, only: const {'PARAMS'}).containsKey('PARAMS');
  } catch (_) {
    return false; // mid-stream fragments parse no columns — same as the engine
  }
}

/// The PARAMS column descriptor of an RFC_TR table (`03 01 <u16 6> PARAMS
/// 03 01`), as text for [containsBytes].
final String _paramsDescriptor = String.fromCharCodes(
    [0x03, 0x01, 0x00, 0x06, ...'PARAMS'.codeUnits, 0x03, 0x01]);

/// Whether the sid-4 OLE_FLUSH_CALL value [v] DECLARES a PARAMS column it
/// may not hold whole: it opens an RFC_TR record ([isRfcHead]; a raw
/// continuation slice never does) and carries the PARAMS descriptor. With
/// a decoded PARAMS column, the HEAD rule of a multi-frame call when the
/// PARAMS LZH cell is longer than the head chunk itself, so no column
/// decodes from the head alone.
/// The /AIF/IFMON tree-data batch is such a head: a recorded session
/// srv[23] (raw srv[25]) step 38, 29 701 B, PARAMS cell opening at 812 and
/// running past the chunk; the real Windows GUI receipts it and its six
/// continuations (gui[17..23]) and answers the joined call after the sid-0
/// companion (gui[24]). Read as a data push, it went unreceipted and the
/// live the test system launch stalled. Every sid-4 OLE head in the corpora (627) opens
/// with the RFC_TR header and carries the descriptor; 28 decode no PARAMS.
bool _declaresParams(Uint8List v) =>
    isRfcHead(v) && containsBytes(v, _paramsDescriptor);

/// Fold ONE server frame's automation items — the chunked-call reduction the
/// 740 logon queue needs, per frame:
/// - a sid-4 item carrying OLE_FLUSH_CALL + a PARAMS column is the HEAD of a
/// multi-frame call (pending stream opens); any other sid-4 while a stream
/// is pending is its raw CONTINUATION; other sid-4s are data pushes, not
/// call parts. sid-6 SAPGUI_PROGRESS ticks are receive-only — answering one
/// is an extra input at the flush's step ('invalid dialog step number') and
/// the kernel raises SYSTEM_FAILURE in SAPLOLEA.
/// - ONE empty 16/8/4 receipt per CHUNK frame (head or continuation, no
/// DP_GET), stamped with the CHUNK frame's own step, sent the moment the
/// frame is read — BEFORE the answer; the sid-0 companion closing a stream
/// and a self-contained call get NO receipt.
/// - a sid-0/1 item with OLE_FLUSH_CALL is a SELF-CONTAINED call (its
/// PARAMS/VERBS ride a 03 05 cell or inline 03 04 rows); one WITHOUT the
/// marker closes the pending stream (head+continuations+companion join
/// into ONE call).
/// - a sid-0/1 item that is no OLE call and closes no pending stream, and
/// any sid-6 item outside a stream paint, is a FRONT-END RFC when it names
/// a function ([isFrontendCall]; a recorded session raw srv[40]: the
/// sid-0 SAPGUI_PROGRESS_INDICATOR of a server-opened window).
/// The completed call is attributed to the frame that closed it — the answer
/// stamps THAT frame's step, never the drain-time counter (an answer at an
/// invalid dialog step is 'skip input, do not release screen' → the prd
/// logon dump; the capture's oracle exchange: receipt@11, receipt@11,
/// answer@11).
AutomationFrame foldAutomationFrame(
    Uint8List frame, AutomationStream stream, int fallbackStep) {
  var frameStep = fallbackStep;
  final receipts = <int>[];
  final calls = <(Uint8List, int)>[];
  final frontend = <(Uint8List, int, int)>[];
  final joined = <int>{};
  final dec = decompressFrame(frame);
  if (dec != null) {
    var chunkFrame = false;
    for (final it in dec.walk.items) {
      if (it.isAppl && it.id == 4 && it.sid == 38 && it.value.length >= 4) {
        frameStep = it.value.buffer
            .asByteData(it.value.offsetInBytes, 4)
            .getUint32(0);
      }
      if (!it.isAppl || it.id != 8 || it.value.isEmpty) continue;
      // the item's own view, not a copy: the decode is memoized on the frame
      // (immutable once walked), the stream builder copies when it joins,
      // and the frame's OLE item parse ([_itemCall], keyed on this object)
      // is the parse the answer reuses ([flushCallOf])
      final v = it.value;
      // a stream-form PAINT: its sid-4 head and raw sid-4 continuations are
      // receipted like call chunks, its sid-6 tail is not (stream_paint.dart;
      // unreceipted, the server never sends the next chunk — the live the test system
      // ME21N launch stalled at the SAPLMEGUI/0014 head)
      final ole = containsBytes(v, 'OLE_FLUSH_CALL');
      if (!ole && stream.paint.feed(it.sid, v) != PaintPart.none) {
        if (it.sid == 4) chunkFrame = true;
        continue;
      }
      if (it.sid == 4) {
        // the cheap byte scan first: every sid-4 OLE head of the corpora
        // declares PARAMS, and the column decode inflated EVERY `03 05`
        // cell of the value (a multi-MB VARS) for a yes it already gave
        if (ole && (_declaresParams(v) || _hasParamsColumn(v))) {
          stream._start(v); // head chunk of a multi-frame call
          chunkFrame = true;
        } else if (stream.hasPending) {
          stream._append(v);
          chunkFrame = true; // raw continuation slice
        } else if (!ole &&
            isRfcHead(v) &&
            containsBytes(v, 'DP_PUT_CLIENT_TABLE') &&
            !dpPushDecodes(v)) {
          // the HEAD of a DataProvider PUSH streamed on its own (no
          // OLE_FLUSH_CALL wrapper): the SFP Layout tab's XDP arrives so
          // on some kernels — a form layout too big for one frame,
          // chunked like a call, closed by its sid-0 companion. Joined
          // (and receipted per chunk) like one; the completed value's
          // pushes are cached by the drive loop. A COMPLETE one-frame
          // push stays a plain data push (its DESURL already decodes).
          stream._start(v);
          chunkFrame = true;
        }
        // else: a data push / DP_GET fetch — not a call part, no receipt
      } else if (it.sid == 0 || it.sid == 1) {
        if (ole) {
          // a self-contained call — keyed on the OLE marker alone, as the
          // engine does (flow_drive: a sid-0 WITHOUT the marker is the opaque
          // companion of a chunked call): a one-verb query carries its
          // PARAMS/VERBS as inline 03 04 rows, not a 03 05 cell, and gating on
          // the cell left the launch's GetColumnWidth flush unanswered — the
          // server then waits forever and the transaction never paints
          // (a recorded session srv step 19)
          calls.add((v, frameStep));
          stream._pending = null;
        } else if (stream.hasPending) {
          // the companion completes the chunked call
          joined.add(calls.length);
          calls.add((stream._close(v), frameStep));
        } else if (isFrontendCall(v, it.sid)) {
          frontend.add((v, frameStep, it.sid));
        }
      } else if (it.sid == 6 && !ole && isFrontendCall(v, 6)) {
        frontend.add((v, frameStep, 6)); // the async tick: never answered
      }
    }
    if (chunkFrame) receipts.add(frameStep);
  }
  return AutomationFrame(receipts, calls, frontend, joined);
}

/// The EMPTY execution ack of a flush the frontend executes without a
/// verb to answer: a call JOINED across frames ([AutomationFrame.joinedCalls])
/// that parses to no verbs and no result slots — the DataProvider push of
/// data the frontend pulled (the ABAP editor's LEXER_DATA, requested by the
/// creation answer's `<BLOBS>`), closed by the sid-0 XML_DATA_STREAM
/// companion. The real SAP GUI for Windows answers it with the call's
/// PARAMS / VARS / XML_DATA_STREAM columns echoed EMPTY (their `03 02`
/// dims, no rows) at the closing frame's step: a recorded session
/// subnode_dblclick gui[38] (step 57) after srv[35..46], then the server
/// paints the editor screen (srv[47] SAPLS38E/0500); unanswered, the server
/// keeps its turn open and the source never shows (the reference client's ea_core
/// queued-batch rule, a recorded session G39). The `06 67` frontend
/// statistics trailer of the real answer is live telemetry and is left
/// out, as the reference client leaves it out. Null when [call] is no such call.
List<Uint8List>? buildExecutionAck(EaSession session, FlushCall call) {
  if (call.verbs.isNotEmpty) return null;
  if (call.vars.any(
      (v) => v.name == '_RESULT' || v.name == '_RESULT_QUEUEONLY')) {
    return null;
  }
  if (!containsBytes(call.raw, 'XML_DATA_STREAM')) return null;
  final cols = parseCallColumns(call.raw);
  final out = BytesBuilder(copy: false)
    ..add(constPrefix)
    ..add(rfcToken(0x02, 0x01, codepad('EXCEPT_DESCRIPT')))
    ..add(rfcToken(0x02, 0x03, Uint8List(256)));
  final seen = <String>{};
  for (final name in const ['PARAMS', 'VARS', 'XML_DATA_STREAM']) {
    for (final c in cols) {
      if (c.name != name || !seen.add(name)) continue;
      // the column's width, no rows
      final dims = Uint8List(8);
      final d = c.desc;
      if (d != null && d.length >= 4) dims.setRange(0, 4, d);
      out
        ..add(rfcToken(0x03, 0x01, codepad(name)))
        ..add(rfcToken(0x03, 0x02, dims));
    }
  }
  out.add(Uint8List.fromList(rfcTerm));
  final reply = out.takeBytes();
  // 16/8/1 RFC reply + EOM (buildApplItem: a reply past the u16 length
  // throws instead of wrapping)
  return [_stepItem(session.step), buildApplItem(8, 1, reply), eomBytes];
}

/// The mint loop (ea_core._mint_object_handles port): for every type-9
/// _RESULT row, the handle the answer carries — the root alias for the
/// queue's root/container creations, a fresh mint in queue order otherwise.
class MintResult {
  MintResult(this.handles, this.mintTrace, this.controlMints,
      this.objectMints, this.handleBase);
  final Map<int, int> handles; // VARS row -> handle
  final List<(String, int, bool)> mintTrace; // (verb, handle, aliased)
  final List<(String, String)> controlMints; // (shell, CLSID)
  final List<(int, String)> objectMints; // (handle, class)
  final int handleBase;
}

String _clsOfVerb(FlushCall call, int oid) {
  // class = whichever #-named arg reads as a NAME (ProgID/bean/CLSID)
  final args = verbArgs(call, oid);
  for (final na in args) {
    final v = na.$2;
    if (v.isNotEmpty && v.contains(_letterRx)) return v;
  }
  return '';
}

MintResult mintObjectHandles(
  FlushCall call,
  Map<int, int> typesByVarsrow,
  int handleBaseInput,
  int rootVal,
  bool aliasRoot,
  Map<int, String> clsByVerb,
  Set<String> containerClasses, {
  EaSession? reuseFrom,
}) {
  final handles = <int, int>{};
  final firstSeen = <String>{};
  var mint = handleBaseInput;
  final mintByVerb = <int, int>{};
  final mintTrace = <(String, int, bool)>[];
  final controlMints = <(String, String)>[];
  final objectMints = <(int, String)>[];

  for (final p in call.params) {
    if (reuseFrom != null && p.name == '#1') {
      _noteFree(call, p, handles, reuseFrom);
    }
    if (p.name != '_RESULT' && p.name != '_RESULT_QUEUEONLY') continue;
    final s = p.slot.trim();
    if (!_isDigits(s)) continue;
    final vr = int.parse(s) - 1;
    if (vr < 0 || vr >= call.vars.length) continue;
    if ((typesByVarsrow[vr] ?? 9) != 9) continue;
    // a null reference (`O-1`) consumes no handle (bds_cold_cache gui[21])
    if (call.nullObjectRows.contains(vr)) continue;
    final oid = p.objid.trim();
    var verb = '';
    var oidNum = -1;
    if (_isDigits(oid)) {
      final i = int.parse(oid);
      oidNum = i;
      if (i >= 1 && i <= call.verbs.length) verb = call.verbs[i - 1];
    }
    final isRootCreation = verb == 'CreateControl2' ||
        ((verb == 'CreateObject' || verb == 'CreateControl') && !firstSeen.contains(verb)) ||
        (verb == 'CreateControl' && containerClasses.contains(clsByVerb[oidNum] ?? ''));
    if (aliasRoot && isRootCreation) {
      handles[vr] = rootVal;
      if (mint == rootVal) mint = rootVal + 1;
    } else if (reuseFrom != null && reuseFrom.freedHandles.isNotEmpty) {
      final h = reuseFrom.freedHandles.first;
      reuseFrom.freedHandles.remove(h);
      handles[vr] = h;
    } else {
      handles[vr] = mint;
      reuseFrom?.ownHandles.add(mint);
      mint += 1;
    }
    firstSeen.add(verb);
    mintTrace.add((verb, handles[vr]!, handles[vr] == rootVal));
    if ((verb.startsWith('CreateControl') || verb == 'CreateObject') && oidNum >= 1) {
      final cls = _clsOfVerb(call, oidNum);
      if (verb.startsWith('CreateControl')) {
        final args = {for (final a in verbArgs(call, oidNum)) a.$1: a.$2};
        var reqShell = '';
        final a1 = args['#1'] ?? '';
        if (_isDigits(a1.trim())) reqShell = a1.trim();
        if (reqShell.isEmpty && vr + 1 < call.vars.length) {
          reqShell = call.vars[vr + 1].slot.trim();
        }
        final shell = _isDigits(reqShell) ? reqShell : handles[vr].toString();
        controlMints.add((shell, cls));
        if (_isDigits(reqShell) && handles[vr].toString() != reqShell) {
          call.shellAliases.add((reqShell, handles[vr].toString()));
        }
      } else {
        objectMints.add((handles[vr]!, cls));
        if (_isDigits(oid)) mintByVerb[int.parse(oid)] = handles[vr]!;
      }
    }
    if (handles[vr]! > handleBaseInput) handleBaseInput = handles[vr]!;
  }
  var hb = handleBaseInput;
  if (mint > hb) hb = mint;
  return MintResult(handles, mintTrace, controlMints, objectMints, hb);
}

bool _isDigits(String? s) => s != null && _digitsOnlyRx.hasMatch(s);

/// A FreeObject's #1 releases the handle its VARS row carries: the one
/// this queue minted into that row so far, else the concrete handle the
/// server names — when this session minted it (Windows handle reuse).
void _noteFree(FlushCall call, Rec p, Map<int, int> handles, EaSession s) {
  final oid = p.objid.trim();
  if (!_isDigits(oid)) return;
  final i = int.parse(oid);
  if (i < 1 || i > call.verbs.length || call.verbs[i - 1] != 'FreeObject') {
    return;
  }
  final slot = p.slot.trim();
  if (!_isDigits(slot)) return;
  final vr = int.parse(slot) - 1;
  if (vr < 0 || vr >= call.vars.length) return;
  final h = handles[vr] ?? int.tryParse(call.vars[vr].slot.trim());
  if (h == null || !s.ownHandles.contains(h)) return;
  s.freedHandles.add(h);
  // a released handle names no control any more (the next object reuses it)
  final sh = s.shellAlias.remove('$h');
  if (sh != null && s.shellAlias[sh] == '$h') s.shellAlias.remove(sh);
}

/// Whether [call]'s root / container creations answer the session ROOT
/// handle (the Java GuiCtlMgr identity). The Windows OCX mints a distinct
/// handle per created object (the real GUI: a recorded session
/// gui[114], the F1 Performance Assistant queue: CreateObject 9, dialog
/// 10, splitter 12, cells 13 / 14, viewer 15; a recorded session
/// gui[2], the logon: 1, 2, 3, …; the reference client's ea_core
/// _dialect_alias_root), so a Windows queue aliases only while the logon's
/// first creation queue is answered — the reference client's live the test system logon answer
/// still aliases there (2026-10-10, send SAPMSYST_8: O40000 for the root,
/// containers 101 / 103 / 104), and every recorded Windows replay was
/// served against it.
bool aliasesRoot(EaSession session, FlushCall call) =>
    call.dialect != GuiDialect.windows || !session.rootMinted;

/// The DATAMANAGER control-state XML: EXACTLY the (shell, prop) pairs the
/// queue registered — one CONTROL block per shell in REVERSE first-
/// registration order (the registry walk), PROPERTY elements in
/// registration order — plus the window METRICS tail. An unregistered
/// PROPERTY dumps CNDP 008 at CL_GUI_DATAMANAGER's re-parse; a missing
/// registered one leaves it unreconciled. Values: the identity echo of the
/// server's own SetProperty where captured, else "0" for a numeric propId
/// (the server reads it back into a numeric field; "" dumps
/// CONVT_NO_NUMBER), else "" (ea_controlxml._control_xml port).
///
/// [leading]: CONTROL blocks of controls the queue did NOT register, written
/// first — an ABAP editor's props a method of the same queue moved: the
/// check of SE38 (Ctrl+F2) creates the error list (its docking container
/// and grid register their cached props) AND puts the editor's caret on
/// line 1, and the real GUI reports both in the one answer
/// (a recorded session s[38] -> g[31]: `119`
/// FirstVisibleLine 1, SelPosEndLine 1, LastVisibleLine 40,
/// SelPosStartLine 1, then `125`, `135`).
Uint8List controlXml(
  EaSession session,
  FlushCall call,
  List<(String, String)> cachedProps, {
  List<(String, List<(String, String)>)> leading = const [],
}) {
  final b = StringBuffer()
    ..write('<?xml version="1.0" encoding="sap*"?>\n<DATAMANAGER><CONTROLS>');
  for (final (shell, props) in [
    ...leading,
    ...registeredControlValues(call, cachedProps).reversed,
  ]) {
    b.write('<CONTROL SHELLID="${_xmlAttr(shell)}">');
    for (final (prop, value) in props) {
      b.write('<PROPERTY VALUE="${_xmlAttr(value)}" '
          'NAME="${_xmlAttr(prop)}"/>');
    }
    b.write('</CONTROL>');
  }
  b.write('</CONTROLS>');
  b.write('<COPY id="copy"><GUI id="gui">'
      '${metricsElement(session.screenRows, session.screenCols)}'
      '</GUI></COPY></DATAMANAGER>\u0000');
  return wireText(b.toString());
}

/// The (shell, prop) pairs [call] registered as cached props
/// ([cachedProps], default [FlushCall.cachedProps]) with their answer
/// values: one entry per shell in FIRST-registration order, its props in
/// registration order; each value the identity echo of the server's own
/// SetProperty where captured, else the type default ([_propDefault]).
/// [controlXml] writes them in reverse (the Java registry walk); the
/// Windows ABAP editor's creation answer in this order
/// (SapSessionEditor._editorCreationAnswer).
List<(String, List<(String, String)>)> registeredControlValues(
  FlushCall call, [
  List<(String, String)>? cachedProps,
]) {
  final order = <String>[];
  final byShell = <String, List<(String, String)>>{};
  final textEdits = _windowsTextEditsCreated(call);
  for (final (shell, prop) in cachedProps ?? call.cachedProps) {
    // a pair that names no cached prop of a shell — a blank / padded name,
    // a non-numeric shell, one already listed — is none the real GUI
    // echoes: CL_GUI_DATAMANAGER dumps CNDP 008 "balise act.: PROPERTY"
    // on it (datamanager_grammar.dart), in release builds too
    if (!_soundCachedProp(shell, prop) ||
        (byShell[shell]?.any((p) => p.$1 == prop) ?? false)) {
      continue;
    }
    final echoed = call.setProps[(shell, prop)];
    final initial =
        textEdits.contains(shell) ? textEditInitialCachedProps[prop] : null;
    byShell.putIfAbsent(shell, () {
      order.add(shell);
      return <(String, String)>[];
    }).add((prop, echoed ?? initial ?? _propDefault(prop, call.dialect)));
  }
  return [for (final sh in order) (sh, byShell[sh]!)];
}

/// The shells [call] creates as a Windows TextEdit (`CreateControl(<shell>,
/// SAPGUI.TextEditCtrl.1, …)`), empty outside the Windows dialect.
Set<String> _windowsTextEditsCreated(FlushCall call) {
  if (call.dialect != GuiDialect.windows) return const {};
  final out = <String>{};
  for (var i = 1; i <= call.verbs.length; i++) {
    if (!call.verbs[i - 1].startsWith('CreateControl')) continue;
    final a = verbNamedArgs(call, i);
    if ((a['#2'] ?? '').toUpperCase().contains('TEXTEDIT')) {
      out.add((a['#1'] ?? '').trim());
    }
  }
  return out;
}

bool _soundCachedProp(String shell, String prop) =>
    _digitsOnlyRx.hasMatch(shell) &&
    prop.isNotEmpty &&
    prop.trim() == prop &&
    !prop.contains(' ');

/// The answer value of a registered cached prop with no captured state:
/// numeric propIds (metrics 120/300, grid row/col ids) and numeric/boolean
/// getters (METHOD_TYPE 20/11) answer "0" — never "" — everything else "".
String _propDefault(String prop, GuiDialect? dialect) {
  final mt = methodTypeOf(prop, dialect);
  final numeric = _isDigits(prop) || (mt != null && _numericTypes.contains(mt));
  return numeric ? '0' : '';
}

/// integer / boolean VARIANTs answered with a numeric default (VT_I2, VT_I4,
/// VT_BOOL, VT_UI4, VT_I8)
const Set<int> _numericTypes = {2, 3, 11, 19, 20};

String _xmlAttr(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Answer one OLE_FLUSH_CALL: returns the item bytes to send
/// ([Step, RFC_TR(16/8/1), EOM]) and updates [session]; null = no reply
/// (the empty-flush native rule). [exportXml] = the reply's EXPORT_XML
/// when the caller built it (a grid's adopted DeltaTableModified —
/// grid_edit_actions.dart), in place of the registered control state.
List<Uint8List>? buildAnswer(
  EaSession session,
  FlushCall call, {
  Map<int, Uint8List> propStore = const {},
  bool includeMetrics = true,
  String? svarsXml,
  Uint8List? exportXml,
}) {
  // an Office application's own automation (CreateObject('Word.Document'),
  // the ALV form letter's MS_WORD_OLE_FORMLETTER): refused, the whole
  // queue, with SAPLOLEA's error envelope — the real GUI's answer to a
  // ProgID it cannot create (a recorded session gui[13]); the ABAP gets
  // sy-subrc 2, never a handle to a Word that is not there
  // (frontend_files.dart)
  if (refusedAutomationVerb(call) != null) {
    return [
      _stepItem(session.step),
      buildApplItem(8, 1,
          buildFrontendExceptionReply(exception: oleCallMethodFailed)),
      eomBytes,
    ];
  }
  // a pending CFW drop: the SAPGUIService.DragDrop.1 poll reads it back
  final dropAnswers = dragDropAnswers(session, call);
  if (dropAnswers.isNotEmpty) propStore = {...propStore, ...dropAnswers};
  if (call.verbs.isEmpty) {
    final hasResult = call.vars.any(
        (v) => v.name == '_RESULT' || v.name == '_RESULT_QUEUEONLY');
    // a verb-less queue that still carries DataProvider pushes (an
    // RFC_QUEUE column) asks the frontend to load them and reply: the
    // real GUI answers the empty echo (a recorded session
    // srv[22] step 36 -> gui[14]); unanswered, the ST04 launch never paints
    if (!hasResult && !call.columns.containsKey('RFC_QUEUE')) return null;
    includeMetrics = false;
  }
  final cols = call.columns;

  // types by VARS row (shared-slot priority: object > numeric > other)
  final typesByVarsrow = <int, int>{};
  final verbByVarsrow = <int, String>{};
  final oidByVarsrow = <int, int>{}; // the verb's 1-based index
  final ownerByVarsrow = <int, String>{}; // GetContainer: the on-object token
  final ranks = <int, int>{};
  for (var pI = 0; pI < call.params.length; pI++) {
    final p = call.params[pI];
    if (p.name != '_RESULT' && p.name != '_RESULT_QUEUEONLY') continue;
    final s = p.slot.trim();
    if (!_isDigits(s)) continue;
    final vr = int.parse(s) - 1;
    if (vr < 0 || vr >= call.vars.length) continue;
    final t = call.resultTypes[pI] ?? 9;
    final oid = p.objid.trim();
    String? meth;
    var vidx = 0;
    if (_isDigits(oid)) {
      final i = int.parse(oid);
      if (i >= 1 && i <= call.verbs.length) {
        meth = call.verbs[i - 1];
        vidx = i;
      }
    }
    final mt = methodTypeOf(meth, call.dialect);
    final rank = (t == 9 && mt == 9)
        ? 3
        : (t == 20 || t == 11)
            ? 2
            : 1;
    if (!ranks.containsKey(vr) || rank > ranks[vr]!) {
      ranks[vr] = rank;
      typesByVarsrow[vr] = t;
      if (meth != null) {
        verbByVarsrow[vr] = meth;
        oidByVarsrow[vr] = vidx;
        if (meth == 'GetContainer') {
          ownerByVarsrow[vr] = call.verbCalls[vidx - 1].trim();
        }
      }
    }
  }

  // creation classes (container-class aliasing)
  final clsByVerb = <int, String>{};
  final containerClasses = <String>{};
  for (var i = 1; i <= call.verbs.length; i++) {
    if (call.verbs[i - 1] != 'CreateControl2' && call.verbs[i - 1] != 'CreateControl') continue;
    final cls = _clsOfVerb(call, i);
    if (cls.isEmpty) continue;
    clsByVerb[i] = cls;
    if (call.verbs[i - 1] == 'CreateControl2') containerClasses.add(cls);
  }
  if (containerClasses.isEmpty && call.verbs.isNotEmpty && clsByVerb.isNotEmpty) {
    // the first CreateControl's class is the root container
    for (var i = 1; i <= call.verbs.length; i++) {
      if (call.verbs[i - 1] == 'CreateControl') {
        final cls = clsByVerb[i] ?? '';
        if (cls.isNotEmpty) containerClasses.add(cls);
        break;
      }
    }
  }

  final rootVal = session.handleBase;
  final mint = mintObjectHandles(call, typesByVarsrow, session.handleBase,
      rootVal, aliasesRoot(session, call), clsByVerb, containerClasses,
      reuseFrom: aliasesRoot(session, call) ? null : session);
  if (mint.mintTrace.isNotEmpty) session.rootMinted = true;
  call.mintTrace = mint.mintTrace;
  call.resultHandles = mint.handles;
  noteDragDropMints(session, call); // poll B names these handles

  // GetGuiFeatures: the feature list rides the SVARS XML channel and the
  // result row carries the item index '1' (ea_frontend_features) — decided
  // BEFORE the VARS loop so over-long values rename their row
  if (svarsXml == null) {
    final hasFeatures = call.verbs.contains('GetGuiFeatures') ||
        call.verbs.contains('getGuiFeatures') ||
        containsBytes(call.raw, 'GetGuiFeatures');
    if (hasFeatures) {
      // each dialect declares its own GUI's feature document (the Windows
      // one carries sapinfocntl/platformex — ea_frontend_features)
      svarsXml = call.dialect == GuiDialect.windows
          ? guiFeaturesXmlWindows
          : guiFeaturesXml;
    }
  }

  // reply VARS: every _RESULT row gets a KIND + a value (ea_core's branch
  // order): prop-store echo first, then the blank-scalar rule for unmapped
  // object types, 'O'+handle for minted object results (kind byte 'O' even
  // on a blank-kind request row — GUI[2]-proven for the mapped minting
  // methods), the type-defaulted scalar otherwise. A value longer than the
  // row's value cell (the GetGuiFeatures XML) ships as the SVARS XML item
  // and the row RENAMES to _SRESULT with the item index — the real GUI's
  // rule (a recorded session gui[4]). Non-result rows are blanked /
  // object rows echoed by buildReplySvars itself.
  Uint8List? replyVarsLzh;
  var varsW = varsW_;
  if (cols.containsKey('VARS')) {
    final col = cols['VARS']!;
    varsW = col.width ?? varsW_;
    final outValues = <int, Object>{};
    final outKinds = <int, String>{};
    final renames = <int, String>{};
    for (var vr = 0; vr < call.vars.length; vr++) {
      final nm = call.vars[vr].name;
      if (nm != '_RESULT' && nm != '_RESULT_QUEUEONLY') continue;
      final t = typesByVarsrow[vr];
      if (t == null) continue; // no _RESULT param points here
      final kind = call.vars[vr].type;
      final vb = verbByVarsrow[vr];
      String value;
      if (call.nullObjectRows.contains(vr)) {
        // the null object reference: kind 'O', handle text -1 — the real
        // GUI's GetDocumentProxyInterface of a document it could not open
        // (a recorded session gui[21] row 20)
        outKinds[vr] = 'O';
        value = '-1';
      } else if (propStore.containsKey(vr) && kind != 'O') {
        value = String.fromCharCodes(propStore[vr]!);
      } else if (t == 9 && call.verbs.isNotEmpty && kind != 'O' &&
          (vb == null || !methodType.containsKey(vb) || kindFollowsRequest.contains(vb))) {
        // answered as a blank scalar, never 'O'+handle (the CONVT_NO_NUMBER
        // family) — PARAMS stamps this row 8
        value = '';
      } else if (t == 9 || kind == 'O') {
        outKinds[vr] = 'O';
        value = (mint.handles[vr] ?? mint.handleBase).toString();
      } else if (vb == 'GetGuiFeatures' || vb == 'getGuiFeatures') {
        value = svarsXml ?? guiFeaturesXml; // the over-long features XML
      } else if (vb == 'GetEventParam' && oidByVarsrow[vr] != null) {
        // #1 = the shell, #2 = the PID of the event we sent (blank when
        // unrecorded — never an object handle)
        final args = {for (final a in verbArgs(call, oidByVarsrow[vr]!)) a.$1: a.$2};
        value = session.eventParam(args['#1'] ?? '', args['#2'] ?? '') ?? '';
      } else if (vb == 'SaveDataToUrl' && oidByVarsrow[vr] != null) {
        // the URL the data object was saved under, echoed (VT_BSTR): the
        // real Windows GUI, a recorded session gui[115] (the F1
        // Performance Assistant's SaveDataToUrl(SAPR3://…4000) answers
        // that URL); a recorded session gui[13] (also SAP GUI for Windows —
        // reference client ba50b32) the same
        final args = {
          for (final a in verbArgs(call, oidByVarsrow[vr]!)) a.$1: a.$2,
        };
        value = (args['#3'] ?? '').trim();
      } else if (vb == 'PublishUrl' && oidByVarsrow[vr] != null) {
        // the client-cache probe: 'X' only when the EXACT url (its
        // ?Version= included) is held complete (a recorded session
        // picture_cold gui[2]: a wiped cache answers blank and the server
        // then pushes the picture; a recorded session gui[0], warm:
        // 'X' and no push); a BDS url rides as a `_SPARAMETER` (the SVARS
        // item, a recorded session srv[124]: the Word 97 demo's DEMOWORD97DOC)
        final url = verbArgText(call, oidByVarsrow[vr]!, '#1') ?? '';
        value = publishUrlAnswer(session, url.trim(), t);
      } else if ((vb == 'FileSaveDialogEx' || vb == 'fileSaveDialogEx') &&
          call.dialect == GuiDialect.windows &&
          oidByVarsrow[vr] != null &&
          fileSaveDialogExAnswer(call, oidByVarsrow[vr]!) != null) {
        // FILE_SAVE_DIALOG on the Windows OCX: `;<path>` — its rc field
        // EMPTY (a recorded session srv[105] -> gui[86]); the
        // server's proposed folder and name, no dialog (frontend_files.dart)
        value = fileSaveDialogExAnswer(call, oidByVarsrow[vr]!)!;
      } else if (shellExecuteVerbs.contains(vb) && oidByVarsrow[vr] != null) {
        // CL_GUI_FRONTEND_SERVICES=>EXECUTE: '42' (HINSTANCE > 32) when the
        // document is a web url handed to the browser — the real Windows
        // GUI's answer (a recorded session gui[91]); '0' (the ABAP's
        // "cannot start" failure) for a local file this device never held
        value = shellExecuteAnswer(call, oidByVarsrow[vr]!);
      } else if (vb == 'LoadCUACode' && oidByVarsrow[vr] != null) {
        // BARCHART_SET_FUNCTION_CODE: 1 = the bar chart OCX ran the code
        // itself (OZIN, a recorded session g[12]), 0 = the
        // program acts (XBO5 g[15], ODEL) — sap_barchart.dart
        value = barChartCuaCodeAnswer(
            verbArgText(call, oidByVarsrow[vr]!, '#1') ?? '');
      } else if (vb == 'GetPlatformEx' && call.dialect == GuiDialect.windows) {
        // SAPfront.dll's GET_PLATFORM enum: the real Windows GUI answers 14
        // (a recorded session gui[21], a recorded session)
        value = windowsPlatformExAnswer;
      } else if (registryReadVerbs.contains(vb) &&
          oidByVarsrow[vr] != null &&
          registryReadAnswer(call, oidByVarsrow[vr]!) != null) {
        // REGISTRY_GET_VALUE: the Office 16 install probes read what that
        // PC's registry holds (frontend_registry.dart: the ALV grid's
        // Excel / Word CurVer, XXL's ExcelWorksheet server); any other key
        // keeps the blank the recorded GUIs answer
        value = registryReadAnswer(call, oidByVarsrow[vr]!)!;
      } else if (vb != null && infoCtrlPathAnswer(vb, call.dialect) != null) {
        // the InfoCtrl's install / work folder (frontend_registry.dart:
        // xxl_excel_word_demos gui[13] / gui[11])
        value = infoCtrlPathAnswer(vb, call.dialect)!;
      } else {
        value = _scalarDefault(t, vb, session,
            owner: ownerByVarsrow[vr], dialect: call.dialect);
      }
      outKinds.putIfAbsent(vr, () => ' ');
      if (value.length > varsW - 42) {
        // over-long: rides the SVARS XML channel; the row names the item
        renames[vr] = '_SRESULT';
        value = '1';
      }
      outValues[vr] = value;
    }
    propStore.forEach((vr, v) {
      outValues.putIfAbsent(vr, () => String.fromCharCodes(v));
    });
    final reply = buildReplySvars(col.blob, outValues, varsW,
        kinds: outKinds, renames: renames);
    replyVarsLzh = lzhCompress(reply);
  }

  // reply PARAMS: per-row return-TYPE stamps — a blank-scalar row stamps
  // 8, never 9+blank: the kernel reads a 9 with no handle as an object it
  // cannot resolve, `OBJHOLE2` in the ABAP string the call imports
  // (SE38 activation's GetMarker -> CL_GUI_SOURCEEDIT=>GET_MARKER
  // CONVT_NO_NUMBER, the test system 2026-10-16)
  int resultStamp(int pI) {
    final p = call.params[pI];
    final s = p.slot.trim();
    final vr = _isDigits(s) ? int.parse(s) - 1 : -1;
    if (vr < 0 || vr >= call.vars.length) return call.resultTypes[pI] ?? 9;
    final t = typesByVarsrow[vr] ?? 9;
    final vbs = verbByVarsrow[vr];
    if (t == 9 && call.verbs.isNotEmpty &&
        call.vars[vr].type != 'O' &&
        (vbs == null || !methodType.containsKey(vbs) || kindFollowsRequest.contains(vbs)) &&
        !propStore.containsKey(vr)) {
      return 8;
    }
    return t;
  }

  List<Uint8List>? paramsInline;
  List<Uint8List>? paramsRows;
  final lzhs = <Uint8List>[];
  if (!cols.containsKey('PARAMS') && call.params.isNotEmpty) {
    // PARAMS arrived as INLINE 03 04 rows (a one-verb query): buildReply
    // would echo them UNstamped — re-stamp the _RESULT rows with the
    // concrete result types and blank the inputs, exactly like the cell
    // path (ea_core._inline_params_rows; the engine's /nSE16 answer at the test system,
    // a recorded session gui step 19)
    paramsRows = [];
    for (var pI = 0; pI < call.params.length; pI++) {
      final p = call.params[pI];
      if (p.name == '_RESULT' || p.name == '_RESULT_QUEUEONLY') {
        final rec = Uint8List.fromList(p.raw);
        stampResultType(rec, resultStamp(pI));
        paramsRows.add(rec);
      } else {
        paramsRows.add(Uint8List.fromList([0x20]));
      }
    }
  }
  if (cols.containsKey('PARAMS')) {
    final col = cols['PARAMS']!;
    // the PARAMS geometry the wire declares, else the known one (the parse
    // took the same width: flush_call's parseSvars)
    final pw = col.width ?? paramsW;
    final stamps = <int, Object>{};
    for (var pI = 0; pI < call.params.length; pI++) {
      final p = call.params[pI];
      if (p.name != '_RESULT' && p.name != '_RESULT_QUEUEONLY') continue;
      final s = p.slot.trim();
      if (!_isDigits(s)) continue;
      final vr = int.parse(s) - 1;
      if (vr < 0 || vr >= call.vars.length) continue;
      stamps[pI] = resultStamp(pI);
    }
    final praw = buildReplySvars(col.blob, stamps, pw);
    if (praw.length <= tableInlineMax) {
      paramsInline = [
        for (final r in _rowsOf(praw, pw))
          String.fromCharCodes(r).trim().isEmpty ? Uint8List.fromList([0x20]) : r
      ];
    } else {
      lzhs.add(lzhCompress(praw));
    }
  }

  // the control-state XML only when the queue reports shells
  Uint8List? xml = exportXml;
  if (xml == null && includeMetrics && call.cachedProps.isNotEmpty) {
    xml = controlXml(session, call, call.cachedProps);
  }
  // the answer's DATAMANAGER is parsed by the same CL_GUI_DATAMANAGER as a
  // round's item 17 (datamanager_grammar.dart): debug / tests hold it to
  // the grammar
  assert(xml == null || debugCheckDatamanager(xml, what: 'flush answer'));

  final reply = buildReply(
    call.raw,
    replyVarsLzh ?? Uint8List(0),
    auxCells: lzhs,
    controlXml: xml,
    paramsInline: paramsInline,
    paramsRows: paramsRows,
    svarsXml: svarsXml == null
        ? null
        : buildSvarsXmlWindows([svarsXml]),
  );

  session.handleBase = mint.handleBase;
  for (final (server, ours) in call.shellAliases) {
    session.shellAlias[server] = ours;
    session.shellAlias[ours] = server;
  }
  // the answer's Step item echoes the step of the frame that CLOSED the
  // call (the drive sets it; the offline default stays 20) — the server
  // owns the counter, and a divergent stamp makes SAPLOLEA raise
  // SYSTEM_FAILURE at the logon flush (the engine's step-ladder guard)
  // 16/8/1 RFC reply + EOM (buildApplItem: a reply past the u16 length
  // throws instead of wrapping)
  return [_stepItem(session.step), buildApplItem(8, 1, reply), eomBytes];
}

const int varsW_ = varsW;

/// The `GetPlatformEx` answer of the Windows dialect: SAPfront.dll's
/// GET_PLATFORM enum value the real SAP GUI for Windows answers
/// (a recorded session gui[21], a recorded session).
const String windowsPlatformExAnswer = '14';

/// The `GetColumnWidth` answer when no laid-out width is known: the
/// engine's ground-truthed default (ea_core; the Easy Access launch flush,
/// a recorded session srv step 19).
const String getColumnWidthAnswer = '31';

List<Uint8List> _rowsOf(Uint8List b, int w) {
  // a zero width spun forever
  if (w <= 0) return const [];
  return [
    for (var i = 0; i * w < b.length; i++)
      Uint8List.sublistView(b, i * w, (i + 1) * w > b.length ? b.length : (i + 1) * w)
  ];
}

/// The scalar answer for a non-object result row, by concrete VARIANT type
/// (ea_core's ground-truthed defaults): numeric rc/bool/index rows answer
/// '0' — a blank numeric is a stamp mismatch the kernel rejects; string
/// rows stay blank unless a strategy exists. GetContainer keys a container
/// id by the OWNER object (first-seen 2k+1, '1' for the first — the login
/// oracle's single container). KNOWN Windows-GUI dialect divergence (the
/// real Windows GUI — a recorded session — stamps
/// SetGrid/AddControl i2 with '-100', GetContainer i4 with its HWND and
/// a warm PublishUrl bstr 'X'; our Java-oracle shapes 20/'0' were accepted by
/// prd's kernel and stay until a live Windows-only system says otherwise).
String _scalarDefault(int t, String? verb, EaSession session,
    {String? owner, GuiDialect? dialect}) {
  switch (verb) {
    case 'GetColumnWidth':
      return getColumnWidthAnswer;
    case 'GetGuiFeatures':
      return '1'; // the SVARS XML item index (the row renames to _SRESULT)
    case 'URLPrefixLocal':
      return 'saphtml://htmlprfx${session.handleBase}/';
    case 'GetContainer':
      if (owner == null || owner.isEmpty) return '1';
      return session.containerIds.putIfAbsent(
          owner, () => '${2 * session.containerIdsMinted++ + 1}');
    case 'loadImageFromURL':
    case 'loadImageFromURLAsync':
    case 'LoadImageFromURL':
      return '1'; // the load outcome TRUE (jar SapImage.loadImageFromURL)
    case 'PublishUrl':
      // no url to probe: not cached ([publishUrlAnswer])
      return publishUrlAnswer(session, '', t);
    case 'InitViewers':
    case 'CalcInterval':
      // the date interval a calendar control holds, `<first>,<last>`
      // YYYYMMDD — never blank: the server reads it back as DayInfo's
      // DATE_FROM / DATE_TO and aborts on a blank one (SAPMSDYP, the test system ME2N
      // F4 on S_BEDAT-LOW, 2026-10-11). The session answers the real GUI's
      // interval around the calendar's own date (SapCalendarTracker, via
      // the prop store); this fallback holds the months around today, in
      // the call's dialect (Windows ±7 padded, Java ±5 unpadded)
      return calendarIntervalAnswer(calendarHeldInterval(DateTime.now(),
          dialect: dialect ?? GuiDialect.windows));
    default:
      return _numericTypes.contains(t) ? '0' : '';
  }
}

/// The answer to `PublishUrl(url, lifetime, mode)`, the DataProvider's
/// "do you hold this url?" probe: 'X' only when [session]'s push cache
/// holds [url] EXACTLY (its `?Version=` included) and complete; else the
/// dialect's false — a blank VT_BSTR on Windows ([t] 8: the real GUI on a
/// wiped cache, a recorded session gui[2] row 70; the server
/// then pushes the object and re-publishes it), VT_BOOL '0' on Java
/// (a recorded session; the Java true is unrecorded, so the
/// Java GUI always answers '0').
String publishUrlAnswer(EaSession session, String url, int t) {
  if (t != 8) return '0';
  if (url.isEmpty) return '';
  final seg = session.dpCache.byUrl[url];
  if (seg == null) return '';
  final c = dpPutContent(seg);
  // a string push (DATASTR) carries no table to measure: whole by itself
  return c == null || c.complete ? 'X' : '';
}

/// The 16/4/38 Step item (frames.dart stepItem, built here without the
/// session layer).
Uint8List _stepItem(int step) {
  final value = Uint8List(4);
  value.buffer.asByteData().setUint32(0, step);
  return buildApplItem(4, 38, value);
}

/// Drop the oldest (first-inserted) entries of [m] beyond [max].
void _capOldest(Map<Object?, Object?> m, int max) {
  if (m.length <= max) return;
  for (final k in m.keys.take(m.length - max).toList()) {
    m.remove(k);
  }
}

/// The dialect-less parse of one OLE item of a received frame, shared by
/// that frame's fact readers — [shellsTornDownIn] at the fold and
/// [recordControlFactsFromFrame] at the automation pass parsed every item
/// each. Keyed on the item value: the frame's shared walk
/// ([DecompressedFrame.walk]) hands both readers the same object. Readers
/// only: the answer parses its own call. An item that does not parse (a
/// corrupt / hostile call) is null to both, memoized as such: the readers
/// skip it — a throw here escaped the receive fold and killed the session;
/// the automation pass counts the call's failure ([SapSession]).
final Expando<Object> _itemCalls = Expando('frame OLE item call');

/// An item value whose parse failed, with the failure ([flushCallOf]
/// rethrows it).
final class _UnparseableItem {
  const _UnparseableItem(this.error);
  final Object error;
}

FlushCall? _itemCall(Uint8List value) {
  final memo = _itemCalls[value];
  if (memo != null) return memo is FlushCall ? memo : null;
  try {
    final call = parseFlushCall(value);
    _itemCalls[value] = call;
    return call;
  } catch (e) {
    _itemCalls[value] = _UnparseableItem(e);
    return null;
  }
}

/// The answer's parse of the completed call [value] with [dialect]:
/// `parseFlushCall(value, dialect: dialect)`, sharing the decode the frame's
/// readers already made of the same item object ([_itemCall] — a
/// self-contained call is the item's own value, [foldAutomationFrame]) via
/// [FlushCall.withDialect]; an item they found unparseable throws its parse
/// failure again. A value no reader parsed (a call joined across frames) is
/// parsed here.
FlushCall flushCallOf(Uint8List value, {GuiDialect? dialect}) {
  final memo = _itemCalls[value];
  if (memo is FlushCall) return memo.withDialect(dialect);
  if (memo is _UnparseableItem) throw memo.error;
  return parseFlushCall(value, dialect: dialect);
}

/// Record control facts from a frame's flushes (record_control_facts port,
/// creation subset): CreateControl verbs → the session's control registry.
void recordControlFactsFromFrame(EaSession session, Uint8List frame) {
  final dec = decompressFrame(frame);
  if (dec == null) return;
  for (final it in dec.walk.items) {
    if (!it.isAppl || it.id != 8) continue;
    if (!containsBytes(it.value, 'OLE_FLUSH_CALL')) continue;
    final call = _itemCall(it.value);
    if (call == null) continue;
    final meta = verbMeta(call);
    // the server's own teardown (ea_facts): destroyTab's object / DestroyWindow's
    // shell arg mark the control dead, together with its alias
    for (var d = 0; d < call.verbs.length; d++) {
      final vb = call.verbs[d];
      String? own;
      if (vb == 'destroyTab') {
        own = meta[d].objValue.trim();
      } else if (vb == 'DestroyWindow') {
        final args = verbArgs(call, d + 1);
        own = args.isNotEmpty ? args.first.$2.trim() : null;
      }
      if (own != null && _digitsOnlyRx.hasMatch(own)) {
        session.destroyedControls.add(own);
        final a = session.shellAlias[own];
        if (a != null) session.destroyedControls.add(a);
      }
    }
    final stamp = session.step.toString();
    for (var i = 1; i <= call.verbs.length; i++) {
      if (!call.verbs[i - 1].startsWith('CreateControl')) continue;
      final m = meta[i - 1];
      final args = {for (final a in verbArgs(call, i)) a.$1: a.$2};
      final a1 = (args['#1'] ?? '').trim();
      final cls = _clsOfVerb(call, i);
      final res = m.result?.trim() ?? '';
      var shell = a1;
      if (!_isDigits(shell) && _isDigits(res) && int.parse(res) > 0 && int.parse(res) <= call.vars.length) {
        shell = call.vars[int.parse(res) - 1].slot.trim();
      }
      if (!_isDigits(shell)) continue;
      session.createdControls
          .add(CreatedControl(0, stamp, shell, cls));
      session.shellAlias[shell] = shell;
      // the kernel reuses a destroyed control's shell id for a new control
      // (SE16's result grid is 121 again after F3 + F8): it lives again
      session.destroyedControls.remove(shell);
    }
  }
  // a torn-down control's DataProvider content dies with it (the real
  // GUI's GuiDataProvider is the control's), and the registries stay bounded
  session.evictDeadPushes();
  session.capControlRegistry();
}

/// The CFW shells [frames] tear down — a `destroyTab` object / a
/// `DestroyWindow` shell argument (the [recordControlFactsFromFrame] rule)
/// that no later CreateControl of the same id revives, in frame order.
/// The session reads it for a paint arriving in the SAME turn as the
/// teardown (the responder records the facts after the paint is folded).
Set<String> shellsTornDownIn(Iterable<Uint8List> frames) {
  final out = <String>{};
  for (final frame in frames) {
    final dec = decompressFrame(frame);
    if (dec == null) continue;
    for (final it in dec.walk.items) {
      if (!it.isAppl || it.id != 8) continue;
      if (!containsBytes(it.value, 'OLE_FLUSH_CALL')) continue;
      final call = _itemCall(it.value);
      if (call == null) continue;
      final meta = verbMeta(call);
      for (var d = 0; d < call.verbs.length; d++) {
        final vb = call.verbs[d];
        String? own;
        if (vb == 'destroyTab') {
          own = meta[d].objValue.trim();
        } else if (vb == 'DestroyWindow') {
          final args = verbArgs(call, d + 1);
          own = args.isNotEmpty ? args.first.$2.trim() : null;
        } else if (vb.startsWith('CreateControl')) {
          final args = {for (final a in verbArgs(call, d + 1)) a.$1: a.$2};
          out.remove((args['#1'] ?? '').trim());
        }
        if (own != null && _isDigits(own)) out.add(own);
      }
    }
  }
  return out;
}

// imports used indirectly
// ignore: unused_element
final _unusedImport = 0;

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call.
final RegExp _letterRx = RegExp(r'[A-Za-z]');
final RegExp _digitsOnlyRx = RegExp(r'^\d{1,9}$');
