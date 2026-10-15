/// Network-graph controls (`SAPGUI.NetPlanGraphics.1` = SAPnetz.OCX, CLSID
/// {733CAE93-3959-11D0-83AF-0000E81EEFA0} — the STMS transport routes, the
/// SWDD Workflow Builder's CC_NETZ, the GRAL NETZOCX1 demo) and the classic
/// inline Basis-Graphik GRAPH item (CNG9 / SAPLGRAP): the JNet legacy
/// `/$SECTION` graph stream decoded into nodes and edges (diag_jnet port),
/// plus the node double-click round (event + stream read-back).
///
/// Content arrives two ways:
/// * a DataProvider push: `CreateObject({799104C5-…})` →
/// `SetDataFromUrl(APPLICATION, sapbarc-stream, SAPR3://…)` →
/// `GetDataAsFormat` → `AssignProperty2(<dp>, '', <control handle>,
/// DATA)`; the SAPLCNDP DP_PUT_CLIENT_TABLE45A segment carries the
/// stream in its DATASTR scalar (a recorded session srv[20],
/// a recorded session srv[19], a recorded session srv[25]/[65]).
/// A full stream declares `/$GTYPE`; a later `/$BRACKET :1 … /$BRACKET
/// :0` push without one is a DELTA on the same control (the NETZOCX1
/// node edit re-pushes node 2's NVALS + a new title, srv[27]; STMS
/// re-pushes an empty bracket after every round);
/// * inline: an APPL item 16/2/5 (GRAPH / GRAPH RELEASE 5) in an ordinary
/// dynpro paint (a recorded session srv[32]/[36]): NUL-separated
/// tokens, a section header `T$NAME`, each field `C<value>`, decoded in
/// the codepage the paint's preceding 16/6/35 declared (1160 =
/// windows-1252 there). No control is created for it. A graph over
/// ~16 kB continues in the next frames' `04`-led items
/// ([InlineGraphStream]; a recorded session srv[38]/[39]).
///
/// Record arity (the stream's own grammar, verified on all four oracles):
/// /$NODES (id, format, highlight); /$NVALS (id, key, value) with key 0 =
/// label, 1 = type, 2 = step number; /$POS (id, col, row); /$LINES (line
/// id, from, to, format, highlight, anchor code EA/AA/EE/AE); /$LVALS (line
/// id, key, value); /$INODES (insertable-node type, format, highlight);
/// /$HLTS (id or blank continuation, attribute, value); a delta's /$DELETE
/// (kind `n` node / `l` line, id).
///
/// Node click (real SAP GUI for Windows, a recorded session gui[12]/[14],
/// a recorded session gui[14]/[16], a recorded session
/// gui[17]): the frontend only RAISES `%_GC <shell> 1` (EVENTID 1, PARAM 0
/// = "1"); the server then reads the control's command stream back —
/// `Force(APPLICATION, sapbarc-stream)` / `AssignProperty2(<handle>,
/// DATASTREAM, <dp>, stream)` / `SaveDataToUrl(…, SAPR3://<sink>)` and a
/// SAPLCNDP DP_GET_CLIENT_TABLE45A pull of that sink — and the frontend
/// answers DATASTR `CDBCL\nCn\nC<node id>\nCs\nCb\0` (TOTALSIZE = its
/// length). Every other round on such a screen pulls the stream too and is
/// answered with the EMPTY stream (DATASTR one NUL, TOTALSIZE 0 —
/// a recorded session gui[22], a recorded session gui[35]).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../cfw/dp_cache.dart';
import '../cfw/flush_call.dart';
import '../cfw/reply_container.dart' show buildDpAnswer;
import '../framing/diag_frame.dart';
import '../framing/envelope.dart';
import '../session/actions.dart';
import '../session/frames.dart';
import '../session/frontend_profile.dart';
import 'netplan_format.dart';
import 'screen_model.dart';

// ---------------------------------------------------------------------------
// The model
// ---------------------------------------------------------------------------

/// One node of a network graph.
class NetPlanNode {
  NetPlanNode({
    required this.id,
    this.type = '',
    this.step = '',
    this.label = '',
    this.col,
    this.row,
    this.format = '',
    this.highlight = '',
    Map<String, String>? values,
  }) : values = values ?? {};

  /// The node id the server keys it by (`<SID>`, `/DOMAIN/`, `0000000019`,
  /// `1`) — what [SapSession.selectNetPlanNode] sends back.
  String id;

  /// /$NVALS key 1: the node's type text (a workflow step type `MSEL`,
  /// `CASE`; a transport system id `<SID>`; NETZOCX1's first info text).
  String type;

  /// /$NVALS key 2: the step number (`000019` in SWDD; '' when absent).
  String step;

  /// /$NVALS key 0: the node's caption (`Noeud 3`, `System the test system`, a workflow
  /// step description); '' when the server sent none — show [type] then.
  String label;

  /// /$POS layout cell: column and row of the server's grid layout (see
  /// [SapNetPlanModel]); null when the stream carries no /$POS (STMS,
  /// NETZOCX1 — the control lays those out itself).
  int? col;
  int? row;

  /// The node's /$FMTS format id (box shape / text layout) and /$HLTS
  /// highlight id (colours, [SapNetPlanModel.highlights]); an NVALS `F` /
  /// `H` value overrides the /$NODES default.
  String format;
  String highlight;

  /// Every /$NVALS value of the node by key (`0`, `1`, `2`, `@` icon, `?`,
  /// `X`, `F`, `H`, `C` colour override, …).
  Map<String, String> values;

  /// The text a node box shows: the label, else the type.
  String get caption => label.isNotEmpty ? label : type;

  NetPlanNode _copy() => NetPlanNode(
    id: id,
    type: type,
    step: step,
    label: label,
    col: col,
    row: row,
    format: format,
    highlight: highlight,
    values: Map.of(values),
  );

  @override
  String toString() =>
      'NetPlanNode($id "$caption"${col == null ? '' : ' @$col,$row'})';
}

/// One directed link of a network graph.
class NetPlanEdge {
  NetPlanEdge({
    required this.from,
    required this.to,
    this.id = '',
    this.label = '',
    this.format = '',
    this.highlight = '',
    Map<String, String>? values,
  }) : values = values ?? {};

  String from;
  String to;

  /// The /$LINES line id (`C000000001`, `0000000018`); '' when unreadable.
  String id;

  /// /$LVALS key 0 of the line (`Livraison`, `Yes`); '' when none.
  String label;
  String format;
  String highlight;

  /// Every /$LVALS value of the line by key.
  Map<String, String> values;

  NetPlanEdge _copy() => NetPlanEdge(
    from: from,
    to: to,
    id: id,
    label: label,
    format: format,
    highlight: highlight,
    values: Map.of(values),
  );

  @override
  String toString() => 'NetPlanEdge($from -> $to)';
}

/// One network graph as last delivered.
///
/// Layout: when the stream carries /$POS, [NetPlanNode.col] / [row] are
/// cells of the server's layout raster — 1-based, origin top-left, col
/// grows rightwards, row downwards; units are raster cells, not pixels or
/// dynpro characters (the SWDD workflow puts its start node at col 3 row 1
/// and steps every 2 rows down to row 18). Without /$POS the frontend lays
/// the graph out itself (left-to-right along the edges).
class SapNetPlanModel {
  SapNetPlanModel({
    this.shell,
    this.container,
    this.title = '',
    this.gtype = '',
    List<String>? palette,
    List<NetPlanNode>? nodes,
    List<NetPlanEdge>? edges,
    Map<String, Map<String, String>>? highlights,
    NetPlanDecor? decor,
  }) : palette = palette ?? [],
       nodes = nodes ?? [],
       edges = edges ?? [],
       highlights = highlights ?? {},
       decor = decor ?? NetPlanDecor();

  /// The hosting NetPlanGraphics control's kernel shell (`119`); null for
  /// the inline GRAPH carrier.
  String? shell;

  /// The dynpro custom-container name hosting the control (a key of
  /// `ScreenModel.containers`), when the wire linked one; null for a
  /// control linked to the whole dynpro (`LinkControl`) or the inline one.
  String? container;

  String title;

  /// The /$GTYPE graph type (`N` = network).
  String gtype;

  /// The /$INODES insertable node types — the palette of node kinds the
  /// graph editor offers (SWDD: `FUNC`, `MAIL`, `IF`, …; NETZOCX1:
  /// `INODE1`…`INODE7`), in stream order.
  List<String> palette;

  List<NetPlanNode> nodes;
  List<NetPlanEdge> edges;

  /// The /$HLTS highlight (colour) sets by id: `h` = the box fill, `l` =
  /// the box line / border, `s` = shadow, plus `p` / `y` / `t` style codes
  /// (values are JNet colour names: `BLUE_3`, `DARKGREEN`, `GRAY_1`, …).
  Map<String, Map<String, String>> highlights;

  /// The graph's look: box formats, frames, boxes, legend, options
  /// (netplan_format.dart).
  NetPlanDecor decor;

  NetPlanNode? node(String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// The fill colour name of [n]'s highlight set (null when unknown).
  String? fillColor(NetPlanNode n) => highlights[n.highlight]?['h'];

  /// The border colour name of [n]'s highlight set (null when unknown).
  String? lineColor(NetPlanNode n) => highlights[n.highlight]?['l'];

  @override
  String toString() =>
      'SapNetPlanModel(${shell ?? 'inline'} "$title": ${nodes.length} nodes, '
      '${edges.length} edges)';
}

// ---------------------------------------------------------------------------
// The stream grammar
// ---------------------------------------------------------------------------

/// A node id: no whitespace, short (a reassembly-boundary artifact never
/// matches). STMS keys nodes `/DOMAIN/`, SWDD 10-digit numbers.
final RegExp _idRx = RegExp(r'^[^\s\x00-\x1f]{1,24}$');

/// A /$LINES record ends with its anchor-side code (E/A per end).
final RegExp _lineEndRx = RegExp(r'^[AE]{2}$');

/// {/$NAME: [field, …]} — the `:value` records of each section in order,
/// a recurring section's bodies concatenated.
typedef _Sections = Map<String, List<String>>;

/// Sections of the DataProvider-push lexer: `/$NAME` (or `/$NAME(args)`)
/// header lines, `:value` field lines (leading padding stripped).
_Sections _pushSections(String text) {
  final out = <String, List<String>>{};
  List<String>? cur;
  for (final ln in text.split('\n')) {
    final s = ln.trim();
    if (s.startsWith(r'/$')) {
      var name = s;
      final p = name.indexOf('(');
      if (p >= 0) name = name.substring(0, p);
      final sp = name.indexOf(' ');
      if (sp >= 0) name = name.substring(0, sp);
      cur = out.putIfAbsent(name, () => []);
    } else if (cur != null) {
      if (s.startsWith(':')) {
        cur.add(s.substring(1).trim());
      } else if (s.isNotEmpty) {
        cur.add(s); // a boundary artifact: kept so arity stays visible
      }
    }
  }
  return out;
}

/// Sections of the inline GRAPH-item lexer: NUL tokens, `T$NAME[ args]`
/// headers, `C<value>` fields; any other token (`$A`, `E`, `R`, the
/// `V3.4` / `BNETZ …` preamble) is framing and closes the open section.
_Sections _inlineSections(String text) {
  final out = <String, List<String>>{};
  List<String>? cur;
  for (final tok in text.split('\x00')) {
    if (tok.startsWith(r'T$')) {
      var name = tok.substring(2);
      final sp = name.indexOf(' ');
      if (sp >= 0) name = name.substring(0, sp);
      cur = out.putIfAbsent('/\$$name', () => []);
    } else if (cur != null && tok.startsWith('C')) {
      cur.add(tok.substring(1).trim());
    } else {
      cur = null;
    }
  }
  return out;
}

/// The DataProvider-push lexer ([_pushSections]), shared with the bar
/// chart's `sapbarc-stream` (sap_barchart.dart): `/$NAME` -> its `:` fields.
Map<String, List<String>> netPlanPushSections(String text) =>
    _pushSections(text);

/// The inline GRAPH-item lexer ([_inlineSections]), shared likewise.
Map<String, List<String>> netPlanInlineSections(String text) =>
    _inlineSections(text);

List<List<String>> _group(List<String>? f, int n) => [
  if (f != null)
    for (var i = 0; i + n <= f.length; i += n) f.sublist(i, i + n),
];

String _first(List<String>? f) =>
    (f ?? const <String>[]).firstWhere((s) => s.isNotEmpty, orElse: () => '');

/// The mutable graph state one control accumulates (full streams replace
/// it, delta brackets update it).
class _Graph {
  String title = '';
  String gtype = '';
  List<String> palette = [];
  final Map<String, NetPlanNode> nodes = {};
  final List<NetPlanEdge> edges = [];
  final Map<String, Map<String, String>> highlights = {};
  final NetPlanDecor decor = NetPlanDecor();

  bool get isEmpty => nodes.isEmpty && edges.isEmpty;

  /// Fold one stream's sections in: [full] (a /$GTYPE stream) resets first.
  void apply(_Sections s, {required bool full}) {
    decor.apply(s, full: full);
    if (full) {
      title = '';
      gtype = '';
      palette = [];
      nodes.clear();
      edges.clear();
      highlights.clear();
    }
    // a delta's removals come first (a recorded session srv[114]
    // deletes line 0000000021 and re-adds it rerouted): (kind, id) pairs,
    // kind `n` = node (its links go with it), `l` = line
    for (final r in _group(s[r'/$DELETE'], 2)) {
      final id = r[1];
      if (r[0] == 'n') {
        nodes.remove(id);
        edges.removeWhere((e) => e.from == id || e.to == id);
      } else if (r[0] == 'l') {
        edges.removeWhere((e) => e.id == id);
      }
    }
    final t = _first(s[r'/$TITLE']);
    if (t.isNotEmpty) title = t;
    final g = _first(s[r'/$GTYPE']);
    if (g.isNotEmpty) gtype = g;
    if (s.containsKey(r'/$INODES')) {
      palette = [
        for (final r in _group(s[r'/$INODES'], 3))
          if (r[0].isNotEmpty) r[0],
      ];
    }
    String? hl;
    for (final r in _group(s[r'/$HLTS'], 3)) {
      if (r[0].isNotEmpty) hl = r[0];
      if (hl == null || r[1].isEmpty) continue;
      (highlights[hl] ??= {})[r[1]] = r[2];
    }
    for (final r in _group(s[r'/$NODES'], 3)) {
      final id = r[0];
      if (!_idRx.hasMatch(id)) continue;
      final n = nodes[id] ??= NetPlanNode(id: id);
      if (r[1].isNotEmpty) n.format = r[1];
      if (r[2].isNotEmpty) n.highlight = r[2];
    }
    for (final r in _group(s[r'/$NVALS'], 3)) {
      final n = nodes[r[0]];
      if (n == null) continue;
      final key = r[1].trim();
      final v = r[2];
      n.values[key] = v;
      switch (key) {
        case '0':
          n.label = v;
        case '1':
          n.type = v;
        case '2':
          n.step = v;
        case 'F':
          if (v.isNotEmpty) n.format = v;
        case 'H':
          if (v.isNotEmpty) n.highlight = v;
      }
    }
    for (final r in _group(s[r'/$POS'], 3)) {
      final n = nodes[r[0]];
      if (n == null) continue;
      n.col = int.tryParse(r[1].trim());
      n.row = int.tryParse(r[2].trim());
    }
    _applyLines(s[r'/$LINES']);
    final byId = {
      for (final e in edges)
        if (e.id.isNotEmpty) e.id: e,
    };
    for (final r in _group(s[r'/$LVALS'], 3)) {
      final e = byId[r[0]];
      if (e == null) continue;
      final key = r[1].trim();
      e.values[key] = r[2];
      if (key == '0') e.label = r[2];
    }
  }

  void _applyLines(List<String>? lf) {
    if (lf == null || lf.isEmpty) return;
    final found = <NetPlanEdge>[];
    // the two DECLARED node ids before each anchor-code terminator are
    // (from, to): resilient to a contaminated line-id slot, and a format /
    // highlight ref between them is never read as an endpoint
    for (var i = 0; i < lf.length; i++) {
      if (!_lineEndRx.hasMatch(lf[i])) continue;
      final lo = i - 5 < 0 ? 0 : i - 5;
      final ids = [
        for (var k = lo; k < i; k++)
          if (nodes.containsKey(lf[k])) k,
      ];
      if (ids.length < 2) continue;
      final a = ids[ids.length - 2], b = ids[ids.length - 1];
      // the documented record (line id, from, to, fmt, hlt, end): the slots
      // around the endpoints when the window is aligned
      final aligned = a == i - 4 && b == i - 3;
      found.add(
        NetPlanEdge(
          from: lf[a],
          to: lf[b],
          id: aligned && _idRx.hasMatch(lf[i - 5]) ? lf[i - 5] : '',
          format: aligned ? lf[i - 2] : '',
          highlight: aligned ? lf[i - 1] : '',
        ),
      );
    }
    if (found.isEmpty) {
      // no anchor terminator at all (the inline hierarchy graph, CNG9
      // srv[36]: the records end in a blank slot): the fixed arity
      for (final r in _group(lf, 6)) {
        if (nodes.containsKey(r[1]) && nodes.containsKey(r[2])) {
          found.add(
            NetPlanEdge(
              from: r[1],
              to: r[2],
              id: _idRx.hasMatch(r[0]) ? r[0] : '',
              format: r[3],
              highlight: r[4],
            ),
          );
        }
      }
    }
    for (final e in found) {
      final dup = e.id.isNotEmpty
          ? edges.indexWhere((x) => x.id == e.id)
          : edges.indexWhere(
              (x) => x.id.isEmpty && x.from == e.from && x.to == e.to,
            );
      if (dup >= 0) {
        edges[dup] = e;
      } else {
        edges.add(e);
      }
    }
  }

  SapNetPlanModel model({String? shell, String? container}) => SapNetPlanModel(
    shell: shell,
    container: container,
    title: title,
    gtype: gtype,
    palette: List.of(palette),
    nodes: [for (final n in nodes.values) n._copy()],
    edges: [for (final e in edges) e._copy()],
    highlights: {for (final h in highlights.entries) h.key: Map.of(h.value)},
    decor: decor.copy(),
  );
}

final Uint8List _sectionMark = Uint8List.fromList(r'/$'.codeUnits);
final Uint8List _gtypeMark = Uint8List.fromList(r'/$GTYPE'.codeUnits);

int _indexOf(Uint8List b, List<int> needle, [int from = 0]) {
  outer:
  for (var i = from; i + needle.length <= b.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (b[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

int _lastIndexOf(Uint8List b, List<int> needle) {
  outer:
  for (var i = b.length - needle.length; i >= 0; i--) {
    for (var j = 0; j < needle.length; j++) {
      if (b[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// The `/$SECTION` stream itself out of a DataProvider push segment: from
/// the first `/$` header through the end of the last `:` record line — the
/// push's DP_PUT parameter block before it and its property block / cell
/// padding after it are not content. Empty when [seg] holds no stream.
Uint8List netPlanStreamBytes(Uint8List seg) {
  final start = _indexOf(seg, _sectionMark);
  if (start < 0) return Uint8List(0);
  final last = _lastIndexOf(seg, const [0x0a, 0x3a]); // "\n:"
  final end = last > start ? _indexOf(seg, const [0x0a], last + 1) : -1;
  return Uint8List.sublistView(seg, start, end > start ? end + 1 : seg.length);
}

String _decodeStream(Uint8List body) {
  try {
    return utf8.decode(body); // a Unicode system's stream is UTF-8
  } on FormatException {
    return latin1.decode(body);
  }
}

/// Parse a JNet `/$SECTION` stream (the DataProvider carrier; a whole DP
/// segment is fine — [netPlanStreamBytes] cuts it) into a graph, or null
/// when it holds no node and no edge. A stream without /$GTYPE is read as
/// a standalone graph here; [SapNetPlanTracker] folds it as a delta.
SapNetPlanModel? parseNetPlanStream(Uint8List bytes, {String? shell}) {
  final body = netPlanStreamBytes(bytes);
  if (body.isEmpty) return null;
  final g = _Graph()..apply(_pushSections(_decodeStream(body)), full: true);
  return g.isEmpty ? null : g.model(shell: shell);
}

/// True when [value] is the inline GRAPH carrier (its `T$GTYPE` header).
bool isInlineNetPlan(Uint8List value) =>
    _indexOf(value, '\x00T\$GTYPE\x00'.codeUnits) >= 0;

/// Parse the inline GRAPH-item carrier (APPL 16/2/5) decoded in SAP
/// [codepage] (the paint's preceding 16/6/35: `1160` windows-1252 on the
/// Windows oracle, `4110` UTF-8, `1100` latin-1), or null when [value] is
/// not a graph or carries no node and no edge.
SapNetPlanModel? parseNetPlanInline(
  Uint8List value, {
  String codepage = '1160',
}) {
  if (!isInlineNetPlan(value)) return null;
  final text = switch (codepage) {
    '4110' => utf8.decode(value, allowMalformed: true),
    '1160' => _cp1252(value),
    '1127' => _macRoman(value), // the Java GUI's (gral_netzocx1_java srv[38])
    _ => latin1.decode(value, allowInvalid: true),
  };
  final g = _Graph()..apply(_inlineSections(text), full: true);
  return g.isEmpty ? null : g.model();
}

/// The ceiling of one inline GRAPH transmission (its items joined): past
/// it no continuation is taken and the stream counts as complete.
const int maxInlineGraphBytes = 4 << 20;

/// The end of every inline GRAPH message: the `E` and `R` framing tokens
/// (a recorded session srv[32] `… T$BRACKET C0 E R`, srv[34] `… KNETZ E
/// R`; a recorded session srv[39] `… T$BRACKET C0 E R`).
const List<int> _inlineGraphEnd = [0x00, 0x45, 0x00, 0x52, 0x00];

/// The kind byte every inline GRAPH item leads with: `05` a chunk more
/// follow (a recorded session srv[16], NETZ_BO3's 16 016 B; cng9
/// srv[32] / GRCNETC2 srv[63], followed by an EMPTY last chunk `04` —
/// srv[33] / srv[64]), `04` the last (NETZ_BO3's continuation srv[17],
/// 7 411 B; GRBUSG_3's one-chunk business graph srv[71]; the close message
/// cng9 srv[34] / gfw_demos srv[18]).
const int _inlineGraphMore = 0x05, _inlineGraphLast = 0x04;

/// The version token right after the kind byte of a transmission's first
/// chunk (`05 '1V3.4'` / `04 '1V3.4'`, every inline graph of the corpus).
const List<int> _inlineGraphHead = [0x31, 0x56, 0x33, 0x2e, 0x34, 0x00];

/// Whether [value] is the FIRST chunk of an inline GRAPH transmission —
/// a network graph's (its `T$GTYPE`) or any other Basis graphic's (the
/// `1V3.4` head: GRBUSG_3's business graph `04 '1V3.4' … BBUSG`). The
/// frontend profile (INI) request rides the same head (`04 '1V3.4' 'LF'
/// 'BPROF'`, a recorded session srv[21]) and is NO
/// graphic: [isInlineProfileMessage].
bool isInlineGraphHead(Uint8List value) {
  if (isInlineNetPlan(value)) return true;
  if (value.length <= _inlineGraphHead.length) return false;
  for (var i = 0; i < _inlineGraphHead.length; i++) {
    if (value[i + 1] != _inlineGraphHead[i]) return false;
  }
  return !isInlineProfileMessage(value);
}

/// The 16/2/5 interface of the frontend profile (INI) service — XXL asks
/// `Lotus.ini` for a key through it (a recorded session
/// srv[21] `04 '1V3.4' 'LF' 'BPROF' 'D,' 'IPROF' 'D,' '13' '$V01'
/// 'CMODE = GET' 'CSTRINGS =Lotus.ini,Lotus Applications,Common Directory'
/// 'E' 'R'`, then srv[22] `04 'KPROF' 'E' 'R'`).
const String inlineProfileInterface = 'PROF';

/// Whether the 16/2/5 item [v] is a message of the profile service — its
/// `BPROF` / `IPROF` request or its `KPROF` close — never a graphic.
bool isInlineProfileMessage(Uint8List v) {
  for (final t in _inlineGraphPreamble(v, max: 8)) {
    if (t == 'B$inlineProfileInterface' ||
        t == 'I$inlineProfileInterface' ||
        t == 'K$inlineProfileInterface') {
      return true;
    }
  }
  return false;
}

/// The client's reply the profile message [v] owes, or null: the request
/// (`IPROF … CMODE = …`) is answered `00 06 'IPROF' 00 05 00 00 08 00 06
/// 'RC=1,' 00` — RC 1 = no such key (GuiGo holds no INI file; xxl gui[14],
/// the real GUI's own answer for the absent Lotus key), the close `KPROF`
/// with the done reply `D E0` (xxl gui[15]). Only `CMODE = GET` of an
/// absent key is recorded; a `PUT` gets the same refusal.
Uint8List? inlineProfileReply(Uint8List v) {
  if (!isInlineProfileMessage(v)) return null;
  final toks = _inlineGraphPreamble(v);
  if (toks.contains('I$inlineProfileInterface') &&
      toks.any((t) => t.startsWith('CMODE'))) {
    return inlineGraphMessage(inlineProfileInterface, 0x05, 'RC=1,');
  }
  if (toks.contains('K$inlineProfileInterface')) {
    return inlineGraphDoneMessage();
  }
  return null;
}

/// The classic Basis-Graphik conversation of an inline GRAPH item 16/2/5
/// (SAPLGRAP/0100): the transmission the paint opened ([open], a `T$GTYPE`
/// stream) and each continuation item the server sends after it until the
/// stream ends ([complete]). A graph over ~16 kB rides SEVERAL items, each
/// in its own frame: GRAL NETZOCX1 / NETZ_BO3 opens with 16 013 B that stop
/// inside /$FMTS — no node yet — and the /$NODES /$LINES … arrive in the
/// next frame's `04`-led item (a recorded session srv[38] →
/// srv[39], 7 nodes / 8 edges joined). Immutable: [extend] returns a new
/// stream, so a fold never edits the previous paint's.
final class InlineGraphStream {
  InlineGraphStream._(this._chunks, this.length, this.codepage,
      this.interface, this.complete,
      {this.receiving = false, SapNetPlanModel? parsed})
      : _parsed = parsed,
        _isParsed = parsed != null;

  /// The transmission [value] opens (null when it is not a graph's first
  /// item), decoded later in SAP [codepage] (the 16/6/35 before it).
  static InlineGraphStream? open(Uint8List value, String codepage) {
    if (!isInlineGraphHead(value)) return null;
    final v = value.length > maxInlineGraphBytes
        ? Uint8List.sublistView(value, 0, maxInlineGraphBytes)
        : value;
    return InlineGraphStream._(
        [v],
        v.length,
        codepage,
        inlineGraphInterface(v),
        v[0] == _inlineGraphLast || _ends([v]) || v.length != value.length,
        receiving: v[0] == _inlineGraphLast);
  }

  final List<Uint8List> _chunks;

  /// The bytes received so far.
  final int length;
  final String codepage;

  /// The graphic interface the stream names (its `I` token: `NETZ`, from
  /// `INETZ`) — what the client's own GRAPH messages name; null when none.
  final String? interface;

  /// What the stream is, by its [interface]: only [InlineGraphKind.network]
  /// is a network graph ([model]); the classic business / statistics
  /// graphics keep their joined [bytes] for a renderer of their own.
  InlineGraphKind get kind => inlineGraphKindOf(interface);

  /// The transmission ended (its `E R`), or reached [maxInlineGraphBytes].
  final bool complete;

  /// The transmission's LAST chunk (kind `04`) arrived — its content
  /// (NETZ_BO3 srv[17], GRBUSG_3 srv[71]) or empty after a one-chunk graph
  /// (cng9 srv[33], GRCNETC2 srv[64]): the graph waits for the user, its
  /// step is the current.
  final bool receiving;

  /// This stream continued by the GRAPH item [value]: null when [value] is
  /// no continuation (the stream already ended — then it is another message
  /// of the conversation — or [value] leads with no kind byte). The empty
  /// last chunk after a complete stream marks it [receiving].
  InlineGraphStream? extend(Uint8List value) {
    if (value.isEmpty) return null;
    final kind = value[0];
    if (kind != _inlineGraphLast && kind != _inlineGraphMore) return null;
    if (value.length == 1) {
      if (kind != _inlineGraphLast) return null;
      return complete && !receiving
          ? InlineGraphStream._(_chunks, length, codepage, interface, true,
              receiving: true, parsed: model)
          : null;
    }
    if (complete) return null;
    var part = Uint8List.sublistView(value, 1);
    final room = maxInlineGraphBytes - length;
    final capped = part.length >= room;
    if (capped) part = Uint8List.sublistView(part, 0, room);
    final chunks = [..._chunks, part];
    return InlineGraphStream._(chunks, length + part.length, codepage,
        interface, kind == _inlineGraphLast || capped || _ends(chunks),
        receiving: kind == _inlineGraphLast);
  }

  /// The whole transmission so far, joined.
  Uint8List get bytes {
    if (_chunks.length == 1) return _chunks.single;
    final b = BytesBuilder(copy: false);
    for (final c in _chunks) {
      b.add(c);
    }
    return b.takeBytes();
  }

  SapNetPlanModel? _parsed;
  bool _isParsed;

  /// The graph the stream holds so far ([parseNetPlanInline]), memoized.
  SapNetPlanModel? get model {
    if (!_isParsed) {
      _isParsed = true;
      _parsed = parseNetPlanInline(bytes, codepage: codepage);
    }
    return _parsed;
  }

  /// Whether [chunks] end with the `E R` tokens (split across them or not).
  static bool _ends(List<Uint8List> chunks) {
    var k = _inlineGraphEnd.length;
    for (var c = chunks.length - 1; c >= 0 && k > 0; c--) {
      final b = chunks[c];
      for (var i = b.length - 1; i >= 0 && k > 0; i--) {
        if (b[i] != _inlineGraphEnd[--k]) return false;
      }
    }
    return k == 0;
  }
}

/// The classic Basis graphic an inline GRAPH stream carries, by its
/// interface token (`I<interface>`): `NETZ` the network graph (GRAL
/// NETZ_BO3 / GRCNETC2, CNG9), `BUSG` the business graphic (GRBUSG_3),
/// `STAT` the statistics graphic (GRSTAT_1); anything else (or none)
/// [other]. The profile (INI) service `PROF` is no graphic and never
/// opens a stream ([isInlineProfileMessage]).
enum InlineGraphKind { network, business, statistics, other }

/// The [InlineGraphKind] of the stream naming [interface].
InlineGraphKind inlineGraphKindOf(String? interface) => switch (interface) {
      'NETZ' => InlineGraphKind.network,
      'BUSG' => InlineGraphKind.business,
      'STAT' => InlineGraphKind.statistics,
      _ => InlineGraphKind.other,
    };

/// The framing tokens of an inline GRAPH message: its NUL-separated tokens
/// up to the first `T$` section, the lead control byte stripped (`05 '1V3.4'`,
/// `04 'INETZ'`). At most [max] tokens.
List<String> _inlineGraphPreamble(Uint8List v, {int max = 32}) {
  final out = <String>[];
  var start = 0;
  while (start < v.length && v[start] < 0x20) {
    start++;
  }
  for (var i = start; i <= v.length && out.length < max; i++) {
    if (i < v.length && v[i] != 0) continue;
    final tok = String.fromCharCodes(Uint8List.sublistView(v, start, i));
    if (tok.startsWith(r'T$')) break;
    out.add(tok);
    start = i + 1;
  }
  return out;
}

/// The graphic interface an inline GRAPH message names — `NETZ` of its
/// `INETZ` token (cng9 srv[32] `… 'D,' 'INETZ' 'D,' '13' …`, srv[34]
/// `04 'INETZ' …`), or null.
String? inlineGraphInterface(Uint8List v) {
  for (final t in _inlineGraphPreamble(v)) {
    if (t.length > 1 && t.length <= 16 && t.startsWith('I')) {
      return t.substring(1);
    }
  }
  return null;
}

/// Whether the inline GRAPH message [v] owes the client's done reply
/// ([inlineGraphDoneMessage]): its preamble's `G1` — the close message
/// `04 'INETZ' 'D,' '13' '$V01' '$A' 'G1' 'KNETZ' 'E' 'R'` (cng9 srv[34],
/// answered by gui[34]); the graph data's `G0` (srv[32]) is answered by
/// nothing.
bool inlineGraphReplyOwed(Uint8List v) =>
    v.isNotEmpty &&
    !isInlineGraphHead(v) &&
    _inlineGraphPreamble(v).contains('G1');

/// Whether the inline GRAPH message [v] closes the graph window of
/// [interface]: its `K<interface>` token (`KNETZ`, cng9 srv[34] — the
/// server's answer to the graph's Back).
bool inlineGraphCloses(Uint8List v, String? interface) =>
    interface != null &&
    !isInlineGraphHead(v) &&
    _inlineGraphPreamble(v).contains('K$interface');

/// The client's GRAPH message reporting the graph window's function code
/// [code] (`ABCK`, the Back that leaves the graph) for [interface]: two
/// u16-length-prefixed NUL-terminated token groups around `01 00` —
/// `00 06 'INETZ' 00 01 00 00 08 00 06 'CABCK' 00` (a recorded session
/// gui[33] / gui[36], both graphs left the same way).
Uint8List inlineGraphEventMessage(String interface, String code) =>
    inlineGraphMessage(interface, 0x01, 'C$code');

/// A client GRAPH message for [interface]: the `I<interface>` group, the
/// block [kind] (`01` a function code, `05` the profile service's return
/// code — xxl gui[14] `… 'IPROF' 00 05 00 00 08 00 06 'RC=1,' 00`), then
/// [token] as one u16-length-prefixed group.
Uint8List inlineGraphMessage(String interface, int kind, String token) {
  final iface = latin1.encode('I$interface\x00');
  final fc = latin1.encode('$token\x00');
  return Uint8List.fromList([
    iface.length >> 8 & 0xff, iface.length & 0xff, ...iface,
    kind & 0xff, 0x00,
    (fc.length + 2) >> 8 & 0xff, (fc.length + 2) & 0xff,
    fc.length >> 8 & 0xff, fc.length & 0xff, ...fc,
  ]);
}

/// The client's done reply `00 05 'D' 00 'E<exit>' 00`: `E0` to a GRAPH
/// message that owes one ([inlineGraphReplyOwed]: cng9 gui[34] / gui[37],
/// gfw_demos NETZ_BO3 g[14], GRCNETC2 g[51]); `E3` the business graphic's
/// own exit (GRBUSG_3 g[55]).
Uint8List inlineGraphDoneMessage({int exit = 0}) => Uint8List.fromList(
    [0x00, 0x05, 0x44, 0x00, 0x45, 0x30 + exit % 10, 0x00]);

/// A Windows client GRAPH round carrying [message]: Step, an SES with no
/// event (the window pixels' low bytes), the 16/2/5 item, two EOMs — no
/// codepage, no OK event, no geometry (a recorded session gui[33] / [34]).
List<Uint8List> windowsInlineGraphItems(ActionContext ctx, Uint8List message) {
  final ses = Uint8List(16);
  ses[7] = ctx.modalNo & 0xff;
  ses[14] = ctx.winPxHeight & 0xff;
  ses[15] = ctx.winPxWidth & 0xff;
  return [
    stepItem(ctx.step),
    Uint8List.fromList([itemSes, ...ses]),
    buildApplItem(applGraph, 5, message),
    eomBytes,
    eomBytes,
  ];
}

/// The SAP codepage number a 16/6/35 codepage declaration names
/// (`00 00 04 88 01 '1160' 00 'windows-1252' 00` → `1160`), or null.
String? netPlanCodepageOf(Uint8List v) {
  if (v.length < 6) return null;
  final b = StringBuffer();
  for (var i = 5; i < v.length && v[i] >= 0x30 && v[i] <= 0x39; i++) {
    b.writeCharCode(v[i]);
  }
  return b.isEmpty ? null : b.toString();
}

const List<int> _cp1252High = [
  0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
  0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
];

String _cp1252(Uint8List b) => String.fromCharCodes([
  for (final c in b) c >= 0x80 && c < 0xA0 ? _cp1252High[c - 0x80] : c,
]);

/// Mac Roman 0x80..0xFF (SAP 1127, declared with an empty name).
const String _macRomanHigh =
    'ÄÅÇÉÑÖÜáàâäãåçéèêëíìîïñóòôöõúùûü'
    '†°¢£§•¶ß®©™´¨≠ÆØ∞±≤≥¥µ∂∑∏π∫ªºΩæø'
    '¿¡¬√ƒ≈∆«»… ÀÃÕŒœ–—“”‘’÷◊ÿŸ⁄€‹›ﬁﬂ'
    '‡·‚„‰ÂÊÁËÈÍÎÏÌÓÔÒÚÛÙıˆ˜¯˘˙˚¸˝˛ˇ';

String _macRoman(Uint8List b) => String.fromCharCodes([
  for (final c in b) c >= 0x80 ? _macRomanHigh.codeUnitAt(c - 0x80) : c,
]);

// ---------------------------------------------------------------------------
// The node click
// ---------------------------------------------------------------------------

/// The NetPlanGraphics frontend event every graph interaction raises.
const int netPlanEventId = 1;

/// The command stream a node double-click leaves for the server's read-back
/// (`CDBCL\nCn\nC<id>\nCs\nC<area>`, a recorded session gui[14]/[20]/[29],
/// a recorded session gui[16], a recorded session):
/// `DBCL` = double click, `n` = on a node, the node id, then `s` and the
/// hit area — `b` on 4 of the 5 recorded clicks, `a` on the STMS target
/// group node `/DOMAIN/`.
String netPlanNodeCommand(String nodeId, {String area = 'b'}) =>
    'CDBCL\nCn\nC$nodeId\nCs\nC$area';

/// The event XML exactly as the Windows GUI spells it (gui[12]).
Uint8List netPlanEventXml(String shell) => Uint8List.fromList(
  ('<?xml version="1.0" encoding="sap*"?><DATAMANAGER> <EVENTS>  '
          '<EVENT SHELLID ="$shell" EVENTID ="$netPlanEventId">   '
          '<PARAM PID ="0" VALUE ="1"/></EVENT></EVENTS></DATAMANAGER>')
      .codeUnits,
);

/// The `%_GC <shell> 1` event round. [windows]: the Windows GUI's own frame
/// (a recorded session gui[12]: the tree-event shape with OK event mode
/// 0x03, SCROLL_INFOS2 carrying only the dynpro area and no 16/15/1
/// UI_EVENT_SOURCE); else the Java spelling.
List<Uint8List> netPlanEventItems(
  ActionContext ctx, {
  required String shell,
  bool windows = true,
}) {
  final java = treeEventItems(
    ctx,
    shell: shell,
    eventId: netPlanEventId,
    nodeKey: '1',
  );
  final items = windows
      ? windowsActionItems(java, controlEvent: true, ctx: ctx)
      : java;
  final out = <Uint8List>[];
  for (final raw in items) {
    final walk = walkItems(raw);
    if (walk.items.length != 1) {
      out.add(raw);
      continue;
    }
    final it = walk.items.single;
    if (it.type == itemXmlBlob) {
      out.add(xmlBlobItem(netPlanEventXml(shell)));
    } else if (windows && it.isAppl && it.id == 15 && it.sid == 1) {
      // the graph event carries no UI_EVENT_SOURCE
    } else if (windows &&
        it.isAppl &&
        it.id == 5 &&
        it.sid == 1 &&
        it.value.length >= 2) {
      final v = Uint8List.fromList(it.value);
      // the graph's 16/9/18: the control half of the acked paint
      // ([windowsOkMode] — stms gui[12] 0x03 on a `01` paint), the cursor
      // half on a main-window paint that itself ended in a 16/9/11
      // ([windowsControlOkMode], the generic control event's rule); 0x03
      // without a paint mode
      v[1] = windowsControlOkMode(ctx,
          fallback: 0x03, cursorPaint: ctx.modalNo == 0);
      out.add(buildApplItem(5, 1, v));
    } else if (windows && it.isAppl && it.id == 12 && it.sid == 6) {
      // SCROLL_INFOS2 of the graph event: the pairs zero, the dynpro area
      // (16/12/7) last — gui[12] `… 00 00 00 26 00 00 01 0c 01` on the
      // 38 x 268 SAPLSTCE/0600 area (a recorded session gui[14]
      // alike)
      final v = Uint8List(33);
      final bd = ByteData.sublistView(v);
      bd.setUint32(24, ctx.areaRows);
      bd.setUint32(28, ctx.areaCols);
      v[32] = 1;
      out.add(buildApplItem(12, 6, v));
    } else {
      out.add(raw);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// The stream read-back answer
// ---------------------------------------------------------------------------

/// The INURL a SAPLCNDP DP_GET pull names, or null when [v] is not one.
String? _pullUrl(Uint8List v) {
  if (_indexOf(v, 'DP_GET_CLIENT_TABLE'.codeUnits) < 0) return null;
  final i = _indexOf(v, 'INURL'.codeUnits);
  if (i < 0) return null;
  final m = _pullUrlRx.firstMatch(latin1.decode(Uint8List.sublistView(v, i), allowInvalid: true));
  return m?.group(0);
}

Uint8List _emptyColumn(String name, int width) {
  final b = BytesBuilder(copy: false)
    ..add([0x03, 0x01, (name.length >> 8) & 0xff, name.length & 0xff])
    ..add(name.codeUnits)
    ..add([0x03, 0x01, 0x03, 0x02, 0x00, 0x08])
    ..add([
      (width >> 24) & 0xff,
      (width >> 16) & 0xff,
      (width >> 8) & 0xff,
      width & 0xff,
      0,
      0,
      0,
      0,
    ])
    ..add([0x03, 0x02]);
  return b.takeBytes();
}

String _le32(int v) => String.fromCharCodes([
  v & 0xff,
  (v >> 8) & 0xff,
  (v >> 16) & 0xff,
  (v >> 24) & 0xff,
]);

/// The DP_GET_CLIENT_TABLE45A RESULT the frontend returns for a NetPlan
/// stream read-back: TYPE/SUBTYPE echoed, DATE/TIME zero, TOTALSIZE the
/// stream's length with its NUL (0 for the empty stream), the DATASTR
/// scalar, then empty FORMAT / PROPS columns (width 80) — byte-identical
/// after the connection prefix to a recorded session gui[14].
Uint8List netPlanStreamAnswer([String command = '']) {
  final data = command.isEmpty
      ? '\x00'
      : '${String.fromCharCodes(utf8.encode(command))}\x00';
  return buildDpAnswer(
    scalars: {
      'TYPE': 'APPLICATION',
      'SUBTYPE': 'sapbarc-stream',
      'DATE': '00000000',
      'TIME': '000000',
      'DESCRIPTION': '',
      'TOTALSIZE': _le32(command.isEmpty ? 0 : data.length),
      'PLATTFORM': '',
    },
    extraScalars: [('DATASTR', data)],
    tableRegion: Uint8List.fromList([
      ..._emptyColumn('FORMAT', 80),
      ..._emptyColumn('PROPS', 80),
    ]),
  );
}

// ---------------------------------------------------------------------------
// The session-side tracker
// ---------------------------------------------------------------------------

bool _isNetPlanClass(String cls) {
  final c = cls.toUpperCase();
  return c.contains('NETPLANGRAPHICS') ||
      c.contains('733CAE93-3959-11D0-83AF-0000E81EEFA0') ||
      c.contains('JNET');
}

final RegExp _digits = RegExp(r'^\d+$');

class _Slot {
  _Slot(this.program, this.dynpro, this.modal);
  final String? program;
  final String? dynpro;
  final bool modal;
}

/// The network-graph state of one session: the NetPlanGraphics controls
/// created (class, parent, container / dynpro links), each control's graph
/// as pushed (full streams and delta brackets), the dynpro each graph was
/// painted with, and the stream read-back sinks the server pulls.
class SapNetPlanTracker {
  /// shell -> creation class, for every control seen created
  final Map<String, String> classOf = {};

  /// shell -> parent shell its CreateControl named
  final Map<String, String> parentOf = {};

  /// container shell -> dynpro custom-control name (`LinkContainer`)
  final Map<String, String> linkedName = {};

  /// NetPlan shells in creation order (a re-created shell moves last)
  final List<String> netPlanShells = [];

  final Map<String, _Graph> _graphs = {};
  final Map<String, _Slot> _slots = {};
  final Set<String> _unbound = {};

  /// read-back sink url -> NetPlan shell ('' when unresolved)
  final Map<String, String> _sinks = {};
  (String, String)? _pending;

  /// True when a pushed graph waits for the paint that shows it.
  bool get hasUnbound => _unbound.isNotEmpty;

  String? containerOf(String shell) {
    var s = shell;
    for (var guard = 0; guard < 32; guard++) {
      final n = linkedName[s];
      if (n != null) return n;
      final p = parentOf[s];
      if (p == null) return null;
      s = p;
    }
    return null;
  }

  /// The graph last pushed to [shell] (null when it has none yet).
  SapNetPlanModel? build(String shell) {
    final g = _graphs[shell];
    if (g == null || g.isEmpty) return null;
    return g.model(shell: shell, container: containerOf(shell));
  }

  /// Fold one complete OLE_FLUSH_CALL RFC value: control facts, graph
  /// pushes, read-back sinks. [shellOf] resolves a client-minted handle to
  /// its kernel shell; [isLive] rejects destroyed controls in the fallback
  /// (a replayed recording keeps the recording client's handles: the
  /// newest live NetPlan control). Returns the shells whose graph changed.
  /// [parsed] = [rfc] already parsed.
  Set<String> foldCall(
    Uint8List rfc, {
    String? Function(String owner)? shellOf,
    bool Function(String shell)? isLive,
    FlushCall? parsed,
  }) {
    final call = parsed ?? parseFlushCall(rfc);
    _recordControls(call);
    final touched = <String>{};
    final bindings = [
      for (final b in dpPushBindings(call))
        if (b.role == 'DATA') b,
    ];
    if (bindings.isNotEmpty) {
      final cache = DpCache()..ingestValue(rfc);
      for (final b in bindings) {
        for (final u in b.urls) {
          final seg = cache.byUrl[u];
          if (seg == null) continue;
          final body = netPlanStreamBytes(seg);
          if (body.isEmpty) continue;
          // a push to another known control (the bar chart's sapbarc-stream,
          // sap_barchart.dart) is not a graph's, whatever NetPlan is alive
          if (_isOtherControl(b.shell ?? b.owner, shellOf)) continue;
          final shell = _netPlanOf(b.shell ?? b.owner, shellOf, isLive);
          if (shell == null) continue;
          final full = _indexOf(body, _gtypeMark) >= 0;
          final g = _graphs[shell] ??= _Graph();
          g.apply(_pushSections(_decodeStream(body)), full: full);
          touched.add(shell);
          if (!_slots.containsKey(shell)) _unbound.add(shell);
        }
      }
    }
    _recordSinks(call, shellOf, isLive);
    return touched;
  }

  void _recordControls(FlushCall call) {
    for (var i = 1; i <= call.verbs.length; i++) {
      final verb = call.verbs[i - 1];
      final a = verbNamedArgs(call, i);
      final shell = (a['#1'] ?? '').trim();
      if (verb.startsWith('CreateControl')) {
        if (!_digits.hasMatch(shell)) continue;
        final cls = (a['#2'] ?? '').trim();
        classOf[shell] = cls;
        final parent = (a['#4'] ?? '').trim();
        if (_digits.hasMatch(parent)) {
          parentOf[shell] = parent;
        } else {
          parentOf.remove(shell);
        }
        linkedName.remove(shell); // a reused shell id is a new control
        _forget(shell);
        if (_isNetPlanClass(cls)) netPlanShells.add(shell);
      } else if (verb == 'LinkContainer') {
        final name = (a['#2'] ?? '').trim();
        if (_digits.hasMatch(shell) && name.isNotEmpty) {
          linkedName[shell] = name;
        }
      } else if (verb == 'LinkControl') {
        // the control fills its dynpro (`LinkControl(118, NETZOCX1, 300)`):
        // the dynpro it belongs to, without waiting for the paint
        final prog = (a['#2'] ?? '').trim();
        final dyn = (a['#3'] ?? '').trim();
        if (_digits.hasMatch(shell) && prog.isNotEmpty && dyn.isNotEmpty) {
          _slots[shell] = _Slot(prog, dyn.padLeft(4, '0'), false);
          _unbound.remove(shell);
        }
      } else if (verb == 'DestroyWindow') {
        if (_digits.hasMatch(shell)) {
          _forget(shell);
          classOf.remove(shell);
        }
      }
    }
  }

  void _forget(String shell) {
    netPlanShells.remove(shell);
    _graphs.remove(shell);
    _slots.remove(shell);
    _unbound.remove(shell);
    _sinks.removeWhere((_, s) => s == shell);
  }

  bool _isNetPlan(String? shell) =>
      shell != null && _isNetPlanClass(classOf[shell] ?? '');

  String? _netPlanOf(
    String? ref,
    String? Function(String owner)? shellOf,
    bool Function(String shell)? isLive,
  ) {
    final r = ref?.trim();
    if (r != null && r.isNotEmpty) {
      if (_isNetPlan(r) && (isLive?.call(r) ?? true)) {
        // a kernel shell named directly
        final aliased = shellOf?.call(r);
        if (aliased == null || !_isNetPlan(aliased)) return r;
      }
      final s = shellOf?.call(r);
      if (_isNetPlan(s)) return s;
    }
    for (final s in netPlanShells.reversed) {
      if (isLive?.call(s) ?? true) return s;
    }
    return null;
  }

  /// `AssignProperty2(<handle>, DATASTREAM, <dp>, stream)` +
  /// `SaveDataToUrl(…, SAPR3://<sink>)`: remember the sink the server will
  /// pull the control's command stream from.
  void _recordSinks(
    FlushCall call,
    String? Function(String owner)? shellOf,
    bool Function(String shell)? isLive,
  ) {
    String? source;
    var sawStream = false;
    for (var i = 1; i <= call.verbs.length; i++) {
      final verb = call.verbs[i - 1];
      final a = verbNamedArgs(call, i);
      if (verb == 'AssignProperty2' &&
          (a['#2'] ?? '').trim() == 'DATASTREAM' &&
          (a['#4'] ?? '').trim() == 'stream') {
        source = (a['#1'] ?? '').trim();
        sawStream = true;
      } else if (verb == 'SaveDataToUrl' && sawStream) {
        final url = (a['#3'] ?? '').trim();
        final sub = (a['#2'] ?? '').trim().toLowerCase();
        if (url.startsWith('SAPR3://') &&
            sub == 'sapbarc-stream' &&
            !_isOtherControl(source, shellOf)) {
          _sinks[url] = _netPlanOf(source, shellOf, isLive) ?? '';
        }
        sawStream = false;
      }
    }
  }

  /// True when [ref] resolves through [shellOf] to a known control that is
  /// not a NetPlan graph (a chart editor's stream read-back is not ours).
  bool _isOtherControl(String? ref, String? Function(String owner)? shellOf) {
    final r = ref?.trim();
    if (r == null || r.isEmpty) return false;
    final s = shellOf?.call(r);
    return s != null && classOf.containsKey(s) && !_isNetPlan(s);
  }

  /// Whether [url] is (or was just answered as) a NetPlan read-back sink
  /// [answerPull] owns — the session's generic client-table pass over the
  /// same frame runs AFTER [answerPullsOf] and must not answer the pull a
  /// second time (it did: two DP answers to one pull).
  bool hasSink(String url) =>
      _sinks.containsKey(url) || _answered.contains(url);

  /// The sink urls [answerPull] answered lately (bounded).
  final Set<String> _answered = {};

  /// Give up the read-back sink [url] (another control's tracker — the bar
  /// chart's — owns it).
  void dropSink(String url) => _sinks.remove(url);

  /// Arm the next stream read-back of [shell] with [command] (one shot).
  void queueCommand(String shell, String command) {
    _pending = (shell, command);
  }

  /// The RFC answer to a server pull of a NetPlan read-back sink: the
  /// queued command stream when one is armed for that control, else the
  /// empty stream. Null when [value] is no pull of a sink seen here.
  Uint8List? answerPull(Uint8List value) {
    final url = _pullUrl(value);
    if (url == null) return null;
    final shell = _sinks.remove(url);
    if (shell == null) return null;
    _answered.add(url);
    if (_answered.length > 64) _answered.remove(_answered.first);
    final p = _pending;
    if (p != null && (shell.isEmpty || p.$1 == shell)) {
      _pending = null;
      return netPlanStreamAnswer(p.$2);
    }
    return netPlanStreamAnswer();
  }

  /// The client frames answering every NetPlan read-back pull [frame]
  /// carries (16/8/1 DP answer stamped with the pull frame's own step —
  /// a recorded session srv[22] step 34 → gui[14] step 34).
  List<Uint8List> answerPullsOf(Uint8List frame, int fallbackStep) {
    final dec = decompressFrame(frame);
    if (dec == null) return const [];
    var step = fallbackStep;
    final out = <Uint8List>[];
    for (final it in dec.walk.items) {
      if (it.isAppl && it.id == 4 && it.sid == 38 && it.value.length >= 4) {
        step = it.value.buffer
            .asByteData(it.value.offsetInBytes, 4)
            .getUint32(0);
      }
      if (!it.isAppl || it.id != applRfcTr || it.value.isEmpty) continue;
      final rfc = answerPull(Uint8List.fromList(it.value));
      if (rfc == null) continue;
      out.add(
        clientFrame([stepItem(step), buildApplItem(8, 1, rfc), eomBytes]),
      );
    }
    return out;
  }

  /// Bind the graphs pushed since the last paint to [screen] (the paint
  /// that names their dynpro; a popup's paint binds them as popup graphs).
  void bindUnbound(ScreenModel? screen) {
    if (screen == null || screen.program == null) return;
    for (final shell in _unbound) {
      _slots[shell] = _Slot(
        screen.program,
        screen.dynpro,
        screen.modalLevel > 0,
      );
    }
    _unbound.clear();
  }

  /// The pushed graphs of the screen on display: the controls bound to the
  /// base (full-screen) dynpro, and to the popup when one is up, in
  /// creation order; [destroyed] = shells the server destroyed.
  List<SapNetPlanModel> pushedOn(
    ScreenModel? screen,
    ScreenModel? base,
    Set<String> destroyed,
  ) {
    final popup = screen != null && screen.modalLevel > 0 ? screen : null;
    final full = popup != null ? base : screen;
    bool on(_Slot s) {
      final w = s.modal ? popup : full;
      if (w == null || w.program == null) return false;
      return w.program == s.program &&
          (s.dynpro == null || w.dynpro == s.dynpro);
    }

    return [
      for (final shell in netPlanShells)
        if (!destroyed.contains(shell))
          if (_slots[shell] case final s? when on(s))
            if (build(shell) case final m?) m,
    ];
  }
}

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call (audit #7 / zcode P-12).
final RegExp _pullUrlRx = RegExp(
    'SAPR3://[0-9A-Za-z]+',
  );
