/// The frontend side of a server `DP_GET_CLIENT_TABLE45A` pull (SAPLCNDP):
/// the kernel reads back a client data object the OLE queue saved under a
/// `SAPR3://` sink — typically a control property read-back,
/// `AssignProperty2(<ctl>, <prop>, <dp>, 'data')` + `SaveDataToUrl(…,
/// <sink>)`, then the pull of that sink in the NEXT server frame. The pull
/// is SYNCHRONOUS: the server sits in DP_GET_STREAM_FROM_FRONT until the
/// frontend answers, so a pull left unanswered is a dead session (the ST04
/// launch stall: the DBA cockpit nav tree's `ExpandedKeys` read-back,
/// a recorded session srv[17]/[18] -> gui[10]).
///
/// Port of the reference client's ea_selectedrows `build_client_empty_table_answer`
/// / `build_client_node_key_answer` (the real Windows GUI's split-envelope
/// client table: TYPE and SUBTYPE as separate scalars, the client clock,
/// empty FORMAT/PROPS and the `06 67` trailer).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../lzh/lzh.dart';
import 'dp_cache.dart' show dpColumnCells;
import 'flush_call.dart';
import 'reply_container.dart' show buildDpAnswer, rfcToken;
import 'rfc_cells.dart' show cellTableClose, wrap0305Cell;
import 'tree_header_names.dart' show collapseInlineRow;

/// One control-property read-back sink: the data object a SaveDataToUrl
/// wrote, filled from property [prop] of the object [source].
class PropertySink {
  const PropertySink(this.source, this.prop);

  /// The control/object token the AssignProperty2 named (#1).
  final String source;

  /// The property read back (`ExpandedKeys`, `SelectionKeys`, …).
  final String prop;

  @override
  String toString() => 'PropertySink($source, $prop)';
}

/// The read-back sinks [call] registers: `AssignProperty2(src, prop, dp,
/// 'data')` followed by `SaveDataToUrl(…, SAPR3://sink)` on the same queue
/// (the reference client's control_property_sinks).
Map<String, PropertySink> propertySinksOf(FlushCall call) {
  final out = <String, PropertySink>{};
  PropertySink? pending;
  for (var i = 1; i <= call.verbs.length; i++) {
    final verb = call.verbs[i - 1];
    final a = verbNamedArgs(call, i);
    if (verb == 'AssignProperty2' && (a['#4'] ?? '').trim() == 'data') {
      pending = PropertySink((a['#1'] ?? '').trim(), (a['#2'] ?? '').trim());
    } else if (verb == 'SaveDataToUrl') {
      final url = (a['#3'] ?? '').trim();
      if (pending != null && url.startsWith('SAPR3://')) out[url] = pending;
      pending = null;
    }
  }
  return out;
}

/// True when the RFC value [v] is a SAPLCNDP DP_GET_CLIENT_TABLE pull.
bool isClientTablePull(Uint8List v) =>
    _indexOf(v, 'DP_GET_CLIENT_TABLE'.codeUnits) >= 0;

/// How far past its `INURL` name a pull's url is looked for: the scalar's
/// value token follows the name at once (`INURL 02 01 02 03 <len>
/// SAPR3://…`); the whole rest of a multi-MB value was decoded to text.
const int _inurlWindow = 4096;

/// The INURL a pull names (`SAPR3://<hex>`), or null.
String? clientTablePullUrl(Uint8List v) {
  final i = _indexOf(v, 'INURL'.codeUnits);
  if (i < 0) return null;
  final end = i + _inurlWindow < v.length ? i + _inurlWindow : v.length;
  final m = _clientTablePullUrlRx
      .firstMatch(latin1.decode(Uint8List.sublistView(v, i, end)));
  return m?.group(0);
}

/// The DP answer to a client-table pull, Windows GUI shape: [rows] as the
/// DATAASC records (each [rowWidth] bytes), TOTALSIZE = [totalSize], an
/// empty or one-record FORMAT ([formatRecord]), an empty PROPS. [now] =
/// the client clock the DATE (MM/DD/YY) / TIME (the GUI's 7-char cut of
/// HH:MM:SS) scalars carry.
Uint8List clientTableAnswer({
  List<Uint8List> rows = const [],
  int rowWidth = 12,
  int totalSize = 0,
  Uint8List? formatRecord,
  List<Uint8List>? formatRecords,
  DateTime? now,
  String? date,
  String? time,
}) {
  final t = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  date ??= '${two(t.month)}/${two(t.day)}/${two(t.year % 100)}';
  final clock =
      time ??
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}'.substring(0, 7);
  final table = BytesBuilder(copy: false)
    ..add(_column('DATAASC', rowWidth, rows))
    ..add(_column('FORMAT', 80, formatRecords ?? [?formatRecord]))
    ..add(_column('PROPS', 80, const []));
  return buildDpAnswer(
    scalars: {
      'TYPE': 'APPLICATION',
      'SUBTYPE': 'X-R3TABLE',
      'DATE': date,
      'TIME': clock,
      'DESCRIPTION': '',
      'TOTALSIZE': String.fromCharCodes([
        totalSize & 0xff,
        (totalSize >> 8) & 0xff,
        (totalSize >> 16) & 0xff,
        (totalSize >> 24) & 0xff,
      ]),
      'PLATTFORM': '',
    },
    tableRegion: table.takeBytes(),
  );
}

/// The SAPR3 urls [call] re-saves a LOADED data object under: a
/// SaveDataToUrl that no `AssignProperty2(…, 'data')` property read-back
/// feeds — the F1 Performance Assistant's `formats` / `Force(APPLICATION,
/// X-R3TABLE)` / `AssignProperty2(…, R3TABLE, …, r3TableAutoObj)` /
/// `SaveDataToUrl(SAPR3://…)` queue (a recorded session srv[130]).
Set<String> loadedObjectSinksOf(FlushCall call) {
  final out = <String>{};
  var property = false;
  for (var i = 1; i <= call.verbs.length; i++) {
    final verb = call.verbs[i - 1];
    final a = verbNamedArgs(call, i);
    if (verb == 'AssignProperty2' && (a['#4'] ?? '').trim() == 'data') {
      property = true;
    } else if (verb == 'SaveDataToUrl') {
      final url = (a['#3'] ?? '').trim();
      if (!property && url.startsWith('SAPR3://')) out.add(url);
      property = false;
    }
  }
  return out;
}

/// The pushed table each loaded object [call] re-saves was filled from, by
/// sink: `SetDataFromUrl(APPLICATION, X-R3TABLE, <push>)` +
/// `AssignProperty2(<dp>, 'r3TableAutoObj', <obj>, <prop>)` fill `<obj>`'s
/// `<prop>` from the push; `AssignProperty2(<obj>, <prop>, <dp2>,
/// 'r3TableAutoObj')` + `SaveDataToUrl(…, <sink>)` save it back — XXL's
/// `LISTFILES` queue on the InfoCtrl's `R3TABLE`
/// (a recorded session srv[25] / [28] / [30]).
Map<String, String> loadedObjectSourcesOf(FlushCall call) {
  final out = <String, String>{};
  final filled = <String, String>{}; // '<obj>|<prop>' -> the push url
  String? loaded, pending;
  for (var i = 1; i <= call.verbs.length; i++) {
    final verb = call.verbs[i - 1];
    final a = verbNamedArgs(call, i);
    String arg(String k) => (a[k] ?? '').trim();
    if (verb == 'SetDataFromUrl') {
      final url = arg('#3');
      loaded = url.startsWith('SAPR3://') ? url : null;
    } else if (verb == 'AssignProperty2' && arg('#2') == 'r3TableAutoObj') {
      if (loaded != null) filled['${arg('#3')}|${arg('#4')}'] = loaded;
    } else if (verb == 'AssignProperty2' && arg('#4') == 'r3TableAutoObj') {
      pending = filled['${arg('#1')}|${arg('#2')}'];
    } else if (verb == 'SaveDataToUrl') {
      final url = arg('#3');
      if (pending != null && url.startsWith('SAPR3://')) out[url] = pending;
      pending = null;
    }
  }
  return out;
}

/// The FORMAT records of a pushed table segment [seg] (its 80-byte column
/// descriptors), empty without any.
List<Uint8List> pushedTableFormatRows(Uint8List seg) {
  final (_, (w, n), cells) = dpColumnCells(seg, 'FORMAT');
  if (w <= 0 || n <= 0) return const [];
  final b = BytesBuilder(copy: false);
  for (final c in cells) {
    b.add(c);
  }
  final all = b.takeBytes();
  return [
    for (var i = 0; i < n && (i + 1) * w <= all.length; i++)
      Uint8List.sublistView(all, i * w, (i + 1) * w),
  ];
}

/// The declared DATAASC record width of a pull request (its `03 02`
/// geometry; 1024 on the F1 help-table pull), 0 without one.
int clientTablePullRowWidth(Uint8List v) => clientTablePullTableWidth(v);

/// The declared record width of table [name] of a pull request (its `03 02`
/// geometry after the `03 01 <name> 03 01` token): DATAASC 1024 on the F1
/// help-table pull, DATAASC 765 on the TextEdit's X-R3ABAP read-back
/// (a recorded session srv[32]), DATABIN 120 on the ABAP
/// editor's document pull (a recorded session srv[47]); 0 when the
/// request declares no such table.
int clientTablePullTableWidth(Uint8List v, [String name = 'DATAASC']) {
  final i = _indexOf(v, [0x03, 0x01, 0x00, name.length, ...name.codeUnits]);
  if (i < 0) return 0;
  final j = i + 4 + name.length + 2;
  if (j + 12 > v.length || v[j] != 0x03 || v[j + 1] != 0x02) return 0;
  final w = ByteData.sublistView(v, j + 4, j + 12).getUint32(0);
  // a wire u32: a record wider than any decode could produce is hostile —
  // the answer is laid out at the default width, never allocated to it
  return w > csMaxDecodedLength ? 0 : w;
}

/// The FORMAT records of a pull request (its FORMAT column's `03 04`
/// rows — `X-UNKNOWN … 1 … C` on the F1 pull).
List<Uint8List> clientTablePullFormatRows(Uint8List v) {
  final i = _indexOf(v, [0x03, 0x01, 0x00, 0x06, ...'FORMAT'.codeUnits]);
  if (i < 0) return const [];
  var j = i + 4 + 6 + 2;
  final out = <Uint8List>[];
  while (j + 4 <= v.length && v[j] == 0x03) {
    final tag = v[j + 1];
    if (tag != 0x02 && tag != 0x04) break;
    final ln = (v[j + 2] << 8) | v[j + 3];
    if (j + 6 + ln > v.length) break;
    if (tag == 0x04) out.add(Uint8List.sublistView(v, j + 4, j + 4 + ln));
    j += 6 + ln;
  }
  return out;
}

/// The answer to a pull of a LOADED data object re-saved by
/// [loadedObjectSinksOf] — the real Windows GUI's a recorded session
/// gui[116] (F1 on FB03): the object's own DATE `00000000` / TIME `000000`
/// (not the clock a property read-back carries), the DATAASC at the
/// request's record width, the request's FORMAT record echoed. [rows]: the
/// object's records — the real GUI returned four client-side records the
/// server never pushed ('8000', '1', '18', '2308737'); none is what the
/// reference client answers live (the test system 2026-10-10, no dump).
///
/// A request that declares no FORMAT gets [sourceFormat] — the descriptors
/// of the pushed table the object was filled from
/// ([loadedObjectSourcesOf]): XXL's empty `LISTFILES` table comes back
/// with the push's 15 `X-UNKNOWN` columns (xxl_excel_word_demos gui[19] /
/// [22] / [24], equal to srv[25]'s push).
Uint8List loadedObjectPullAnswer(
  Uint8List request, {
  List<Uint8List> rows = const [],
  List<Uint8List> sourceFormat = const [],
}) {
  final w = clientTablePullRowWidth(request);
  final fmt = clientTablePullFormatRows(request);
  return clientTableAnswer(
    rows: rows,
    rowWidth: w == 0 ? 1024 : w,
    formatRecord: fmt.isEmpty ? null : fmt.first,
    formatRecords: fmt.isEmpty && sourceFormat.isNotEmpty ? sourceFormat : null,
    date: '00000000',
    time: '000000',
  );
}

/// The answer to a pull of a calendar's `Selection` read-back
/// (SapCalendarTracker.takeSelectionRead): the loaded-object envelope (DATE
/// `00000000`, TIME `000000`), the [records] inline at the request's record
/// width (12: the date C8 + the type I4), each with its trailing run
/// collapsed, and the request's own FORMAT records (its two 80-byte
/// descriptors, LZH in the request) inline the same way — the SAP GUI for
/// Windows' raw gui[17] / gui[76] / gui[106] of a recorded session.
Uint8List calendarSelectionPullAnswer(
  Uint8List request,
  List<Uint8List> records,
) {
  final w = clientTablePullRowWidth(request);
  final (_, (fw, fn), cells) = dpColumnCells(request, 'FORMAT');
  final fmt = BytesBuilder(copy: false);
  for (final c in cells) {
    fmt.add(c);
  }
  final f = fmt.takeBytes();
  final rw = fw > 0 ? fw : 80;
  final formats = [
    for (var i = 0; (i + 1) * rw <= f.length && (fn <= 0 || i < fn); i++)
      collapseInlineRow(Uint8List.sublistView(f, i * rw, (i + 1) * rw)),
  ];
  return clientTableAnswer(
    rows: [for (final r in records) collapseInlineRow(r)],
    rowWidth: w == 0 ? 12 : w,
    formatRecords: formats,
    date: '00000000',
    time: '000000',
  );
}

/// The DATABIN row width an HTML viewer posts its sapevent body in
/// (a recorded session gui[41]: 255 x 1 for 65 bytes).
const int htmlPostRowWidth = 255;

/// gui[41]'s FORMAT (80 x 1: the one 255-byte string column) and PROPS
/// (80 x 0) columns, verbatim (the reference client's ea_html).
final Uint8List _htmlPostFormatProps = _hex(
  '03010006464f524d4154030103020008000000500000000103020304004f0000'
  '0000000000000000000000000000000000000000000000000000000000000000'
  '0000000000000000000000000000000000000000000000000000010000000000'
  '0000ff0000000000000058010003040301000550524f50530301030200080000'
  '0050000000000302',
);

Uint8List _hex(String h) => Uint8List.fromList([
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
]);

/// The answer to the pull of an HTML viewer's sapevent POST body (the
/// PostData object's SaveDataToUrl sink): the real GUI's
/// a recorded session gui[41] — TYPE `TEXT` / SUBTYPE `HTML`, blank
/// DATE / TIME, TOTALSIZE = the body's UTF-16 length + BOM, the
/// SEND_DATA_AS_STRING flag, the body in a 255-wide DATABIN (one LZH
/// cell, blank-padded rows), its FORMAT / PROPS, no 06 67 trailer (the
/// reference client's ea_html.build_html_post_answer) — the JAVA bean's object.
/// [windows]: the SAP GUI for Windows OCX's object instead
/// ([htmlWindowsPostAnswer]); [body] empty: a link's GET —
/// [htmlGetPullAnswer].
Uint8List htmlPostPullAnswer(
  Uint8List body, {
  bool windows = false,
  DateTime? now,
}) {
  if (body.isEmpty) return htmlGetPullAnswer(now: now);
  if (windows) return htmlWindowsPostAnswer(body, now: now);
  final n = (body.length + htmlPostRowWidth - 1) ~/ htmlPostRowWidth;
  final padded = Uint8List(htmlPostRowWidth * n)
    ..fillRange(0, htmlPostRowWidth * n, 0x20);
  padded.setRange(0, body.length, body);
  final ts = 2 * body.length + 2;
  final dims = ByteData(8)
    ..setUint32(0, htmlPostRowWidth)
    ..setUint32(4, n);
  final table = BytesBuilder(copy: false)
    ..add(rfcToken(0x03, 0x01, Uint8List.fromList('DATABIN'.codeUnits)))
    ..add(rfcToken(0x03, 0x02, dims.buffer.asUint8List()))
    ..add(wrap0305Cell(lzhCompress(padded)))
    ..add(cellTableClose)
    ..add(_htmlPostFormatProps);
  return buildDpAnswer(
    scalars: {
      'TYPE': 'TEXT',
      'SUBTYPE': 'HTML',
      'DATE': '',
      'TIME': '',
      'DESCRIPTION': '',
      'TOTALSIZE': String.fromCharCodes([
        ts & 0xff,
        (ts >> 8) & 0xff,
        (ts >> 16) & 0xff,
        (ts >> 24) & 0xff,
      ]),
      'PLATTFORM': '',
    },
    extraScalars: const [('SEND_DATA_AS_STRING', '')],
    tableRegion: table.takeBytes(),
    trailer: false,
  );
}

/// The answer to the POST-object pull of a body-less GET navigation (an
/// HTML viewer link): the real SAP GUI for Windows' object,
/// a recorded session raw gui[13] — TYPE `SAPEVENT:` /
/// SUBTYPE `PostData`, the DATE / TIME stamp, blank DESCRIPTION, TOTALSIZE
/// 0, blank PLATTFORM, a DATASTR scalar of ONE NUL, then FORMAT and PROPS
/// as 80 x 0 columns — no DATABIN, no SEND_DATA_AS_STRING.
Uint8List htmlGetPullAnswer({DateTime? now}) =>
    htmlWindowsPostAnswer(Uint8List(0), now: now);

/// The DATASTR quantum of the Windows POST object: the body goes up
/// blank-padded to a whole number of 256-byte blocks, then one NUL (every
/// form submit of a recorded session — raw gui[30] 65 B, gui[43]
/// 133 B, gui[57] 131 B, gui[89] 144 B — is a 257-byte DATASTR; the GET's
/// is the NUL alone, sacm gui[13]). A body past 256 bytes has no capture:
/// the next whole block is the reading of that shape.
const int htmlWindowsPostBlock = 256;

/// The SAP GUI for Windows OCX's answer to the pull of a viewer's PostData
/// object (a form submit's body, or none — [htmlGetPullAnswer]):
/// a recorded session raw gui[30] — TYPE `SAPEVENT:` / SUBTYPE
/// `PostData`, the DATE (MM/DD/YY) / TIME (7 chars) stamp, blank
/// DESCRIPTION, TOTALSIZE = the body's byte length (little-endian u32),
/// blank PLATTFORM, the body in the DATASTR scalar blank-padded to whole
/// [htmlWindowsPostBlock]s + one NUL, FORMAT and PROPS as 80 x 0 columns,
/// the 06 67 trailer. The Java bean's TEXT / HTML DATABIN object
/// ([htmlPostPullAnswer]) is not what the Windows dialect's server reads:
/// /AIF/IFMON's form buttons did nothing on it (live the test system 2026-10-12).
Uint8List htmlWindowsPostAnswer(Uint8List body, {DateTime? now}) {
  final t = now ?? DateTime.now();
  final blocks =
      (body.length + htmlWindowsPostBlock - 1) ~/ htmlWindowsPostBlock;
  final data = Uint8List(blocks * htmlWindowsPostBlock + 1)
    ..fillRange(0, blocks * htmlWindowsPostBlock, 0x20)
    ..setRange(0, body.length, body);
  final n = body.length;
  String two(int v) => v.toString().padLeft(2, '0');
  final table = BytesBuilder(copy: false)
    ..add(_column('FORMAT', 80, const []))
    ..add(_column('PROPS', 80, const []));
  return buildDpAnswer(
    scalars: {
      'TYPE': 'SAPEVENT:',
      'SUBTYPE': 'PostData',
      'DATE': '${two(t.month)}/${two(t.day)}/${two(t.year % 100)}',
      // 7 characters, the seconds' last digit cut (sic, as the GUI sends)
      'TIME': '${two(t.hour)}:${two(t.minute)}:${two(t.second)}'.substring(
        0,
        7,
      ),
      'DESCRIPTION': '',
      'TOTALSIZE': String.fromCharCodes([
        n & 0xff,
        (n >> 8) & 0xff,
        (n >> 16) & 0xff,
        (n >> 24) & 0xff,
      ]),
      'PLATTFORM': '',
    },
    extraScalars: [('DATASTR', latin1.decode(data))],
    tableRegion: table.takeBytes(),
  );
}

/// The width of a tree NODE_KEY (C(11)) in the node-key tables.
const int nodeKeyWidth = 11;

/// The `octet-stream` FORMAT record of the node-key table (one C(11)
/// column, offset 0) — a recorded session gui[101].
final Uint8List nodeKeyFormatRecord = Uint8List.fromList([
  ...'octet-stream'.codeUnits,
  ...List.filled(48, 0x20),
  1, 0, 0, 0, 0, 0, 0, 0, nodeKeyWidth, 0, 0, 0, 0, 0, 0, 0, 0x43, 0x20,
]);

/// The answer to a tree's node-key read-back (`ExpandedKeys`,
/// `SelectionKeys`): one 12-byte record per key (right-justified in 11 +
/// a blank), TOTALSIZE 11 x N; no key = the empty client table the real
/// GUI sends (a recorded session gui[10]).
Uint8List nodeKeyTableAnswer(List<String> keys, {DateTime? now}) {
  if (keys.isEmpty) return clientTableAnswer(now: now);
  final rows = [
    for (final k in keys)
      Uint8List.fromList([..._rjust(k.trim(), nodeKeyWidth).codeUnits, 0x20]),
  ];
  return clientTableAnswer(
    rows: rows,
    totalSize: nodeKeyWidth * rows.length,
    formatRecord: nodeKeyFormatRecord,
    now: now,
  );
}

/// The node keys of a node-key table the SERVER pushed (a DP push's
/// DATAASC records, [nodeKeyTableAnswer]'s layout: the key right-justified
/// in 11 + a blank) — `AssignProperty2(<dp>, 'data', <tree>,
/// 'ExpandedKeys')`, a recorded session srv[26] `{1}`.
/// Each key as 11 characters (the tree's NODE_KEY spelling); empty when
/// [seg] holds no such records.
List<String> nodeKeyTableKeys(Uint8List seg) {
  final (_, (w, n), cells) = dpColumnCells(seg, 'DATAASC');
  if (w < 1 || n < 1) return const [];
  final b = BytesBuilder(copy: false);
  for (final c in cells) {
    b.add(c);
  }
  final data = b.takeBytes();
  // a row per `03 04` cell with its trailing blanks cut: the HIER3 trees'
  // ExpandedKeys (a recorded session srv[29] — width 12, 9
  // rows, 27 bytes: `N1 ` … `N9 `, the keys left-justified) — joined and
  // sliced by the width they ran together (`N1 N2 N3 N4`, no node open)
  if (data.length < w * n &&
      cells.length == n &&
      cells.every((c) => c.length <= w)) {
    return [
      for (final c in cells)
        if (latin1.decode(c).trim() case final k when k.isNotEmpty)
          _rjust(k, nodeKeyWidth),
    ];
  }
  return [
    for (var r = 0; r < n && (r + 1) * w <= data.length; r++)
      if (latin1.decode(Uint8List.sublistView(data, r * w, (r + 1) * w))
          case final rec when rec.trim().isNotEmpty)
        _rjust(rec.trim(), nodeKeyWidth),
  ];
}

String _rjust(String s, int w) {
  if (s.length >= w) return s.substring(s.length - w);
  return s.padLeft(w);
}

Uint8List _column(String name, int width, List<Uint8List> rows) {
  final b = BytesBuilder(copy: false)
    ..add(rfcToken(0x03, 0x01, Uint8List.fromList(name.codeUnits)));
  final dims = ByteData(8)
    ..setUint32(0, width)
    ..setUint32(4, rows.length);
  b.add(rfcToken(0x03, 0x02, dims.buffer.asUint8List()));
  for (final r in rows) {
    b.add(rfcToken(0x03, 0x04, r));
  }
  return b.takeBytes();
}

int _indexOf(Uint8List hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call (audit #7 / zcode P-12).
final RegExp _clientTablePullUrlRx = RegExp('SAPR3://[0-9A-Za-z]+');
