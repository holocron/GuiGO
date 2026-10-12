/// A HEADLESS OFFICE for SAP Desktop Office Integration (screen_doi port):
/// hosts `SAP.DocumentContainerControl.1` and the Office proxies as session
/// objects backed by an in-memory document model, answers every DOI call,
/// and serves the ranges/contents/sheets pulls from the model.
library;

import 'dart:typed_data';

import '../lzh/lzh.dart';
import 'dp_cache.dart';
import 'ea_responder.dart';
import 'flush_call.dart';
import 'reply_container.dart';
import 'rfc_cells.dart';

const String macroRefusedRc = '30';
const String macroRefusedText =
    'macro not executed: no macro engine on this client';
const String defaultSheet = 'Tabelle1';
final RegExp containerClassRx = RegExp(r'^SAP\.DocumentContainerControl\.\d+$', caseSensitive: false);

const Set<String> rangeRoles = {'RangeDef', 'Ranges', 'Content2', 'Content'};

/// DOI typing table entries (merged into the responder's methodType).
const Map<String, int> doiMethodTypes = {
  'InitControl': 3, 'AddInternalTable': 3, 'CreateDocument': 3, 'OpenDocument': 3, 'LastError': 3,
  'GetDocumentProxyInterface': 9, 'HasDocumentInterface': 3, 'CloseDocument': 3, 'SaveDocumentToURL': 3,
  'ReleaseDocument': 3, 'ReleaseAllDocuments': 3, 'StopLinkServer': 3, 'SetRangesData3': 3,
  'SetRangesData2': 3, 'GetRangesData2': 3, 'SetRangesFormat2': 3, 'GetCellFormat2': 3, 'GetSheets2': 3,
  'GetActiveSheet': 8, 'GetProtection': 8, 'GetDimension': 3, 'GetAllfields': 3, 'AddStringItem': 3,
  'AddStringItem2': 3, 'ExecuteMacro': 3, 'LastErrorString': 8, 'AddMenuBar': 3, 'AddMenu': 3,
  'AddMenuItem': 3, 'HideRows': 3, 'ShowRows': 3, 'InsertRange': 3, 'DeleteRange': 3, 'SetSelection': 3,
  'ProtectDocument': 3, 'AddSchema2': 3, 'HasDocumentChanged': 3, 'CheckRegisteredProgIDs': 3,
};

class DocRange {
  int top = 1;
  int left = 1;
  int rows = 1;
  int cols = 1;
  String code = '';
}

/// One DOI document — the shared model every backend renders.
class Document {
  Document(this.cls, this.number, {this.sourceUrl}) {
    sheets[defaultSheet] = {};
  }

  final String cls;
  final int number;
  final String? sourceUrl;

  final Map<String, Map<(int, int), String>> sheets = {};
  String activeSheet = defaultSheet;
  final Map<String, DocRange> ranges = {};
  final List<String> rangeOrder = [];
  final List<(String, String)> stringItems = [];
  final Map<String, String> tables = {};
  bool closed = false;
  final List<String> savedUrls = [];
  final List<String> notes = [];

  void defineRange(String name, int top, int left, int rows, int cols, [String code = '']) {
    final n = name.trim();
    if (!ranges.containsKey(n)) rangeOrder.add(n);
    final r = ranges.putIfAbsent(n, DocRange.new);
    if (top > 0) r.top = top;
    if (left > 0) r.left = left;
    if (rows > 0) r.rows = rows;
    if (cols > 0) r.cols = cols;
    if (code.isNotEmpty) r.code = code;
  }

  void setCell(int row, int col, String value, [String? sheet]) {
    sheets.putIfAbsent(sheet ?? activeSheet, () => {})[(row, col)] = value;
  }

  String cell(int row, int col, [String? sheet]) =>
      (sheets[sheet ?? activeSheet] ?? const {})[(row, col)] ?? '';

  /// SOI_RANGE_LIST rows (name, rows, columns, code) in definition order.
  List<(String, int, int, String)> rangeRows() => [
        for (final n in rangeOrder)
          (n, ranges[n]!.rows, ranges[n]!.cols, ranges[n]!.code)
      ];

  /// SOI_GENERIC_ITEM rows (row, column, value) of the named ranges, cells
  /// addressed RELATIVE to each range (1-based), blanks included.
  List<(int, int, String)> contentRows([List<String>? names]) {
    final out = <(int, int, String)>[];
    for (final n in names ?? rangeOrder) {
      final rg = ranges[n];
      if (rg == null) continue;
      for (var r = 0; r < rg.rows; r++) {
        for (var c = 0; c < rg.cols; c++) {
          out.add((r + 1, c + 1, cell(rg.top + r, rg.left + c)));
        }
      }
    }
    return out;
  }

  /// SetRangesData: apply the bound pushes (SOI_RANGE_LIST / placements /
  /// SOI_GENERIC_ITEM content).
  void applyRangesData(List<List<String>> rangeListRows, List<List<String>> placementRows,
      List<List<String>> contentRowsList) {
    final listed = <String>[];
    for (final cells in rangeListRows) {
      if (cells.length >= 3 && cells[0].isNotEmpty) {
        final have = ranges[cells[0].trim()];
        final (top, left) = have != null ? (have.top, have.left) : _nextFree();
        defineRange(cells[0], top, left, _int(cells[1], 1), _int(cells[2], 1),
            cells.length > 3 ? cells[3] : (have?.code ?? ''));
        listed.add(cells[0]);
      }
    }
    for (final cells in placementRows) {
      final name = cells.length >= 5 ? cells[4] : '';
      if (name.isNotEmpty) {
        defineRange(name, _int(cells[0], 1), _int(cells[1], 1), _int(cells[2], 1), _int(cells[3], 1),
            ranges[name]?.code ?? '');
      }
    }
    final targets = listed.isNotEmpty ? listed : rangeOrder;
    var it = contentRowsList.iterator;
    for (final name in targets) {
      final rg = ranges[name];
      if (rg == null) continue;
      for (var k = 0; k < rg.rows * rg.cols; k++) {
        if (!it.moveNext()) return;
        final cells = it.current;
        if (cells.length >= 3) {
          setCell(rg.top + _int(cells[0], 1) - 1, rg.left + _int(cells[1], 1) - 1,
              _text(cells.last));
        }
      }
    }
  }

  (int, int) _nextFree() {
    var bottom = 0;
    for (final rg in ranges.values) {
      final b = rg.top + rg.rows - 1;
      if (b > bottom) bottom = b;
    }
    return (bottom > 0 ? bottom + 2 : 1, 1);
  }

  /// CSV serialisation (the mobile backend's file form).
  Uint8List toCsv() {
    final b = StringBuffer();
    final cells = sheets[activeSheet] ?? {};
    var maxR = 0;
    var maxC = 0;
    for (final (r, c) in cells.keys) {
      if (r > maxR) maxR = r;
      if (c > maxC) maxC = c;
    }
    for (var r = 1; r <= maxR; r++) {
      final row = <String>[];
      for (var c = 1; c <= maxC; c++) {
        var v = cells[(r, c)] ?? '';
        if (v.contains(',') || v.contains('"') || v.contains('\n')) {
          v = '"${v.replaceAll('"', '""')}"';
        }
        row.add(v);
      }
      b.writeln(row.join(','));
    }
    return Uint8List.fromList(b.toString().codeUnits);
  }
}

int _int(String? v, int dflt) => int.tryParse((v ?? '').trim()) ?? dflt;

/// A pushed cell value: a UCS-2 field decoded to its NUL terminator.
String _text(String v) {
  if (v.contains('\x00')) {
    return v.split('\x00')[0].trim();
  }
  return v.trim();
}

/// Session DOI state.
class DoiState {
  final Map<String, Map<String, Object?>> containers = {}; // shell -> record
  final Map<String, Document> proxies = {}; // row:/obj: -> doc
  final Map<String, (String, Object)> dpRoles = {}; // row:/obj: -> (role, doc or url)
  final Map<String, Uint8List> docBytes = {}; // url -> serialized doc
  final Map<Object, String> docErrors = {}; // url/number -> reason
  final Map<String, String> docSinks = {}; // sink url -> doc url
  final List<(String, Document)> createdDocs = [];
  final List<String> pendingActivation = [];
  final Map<String, String> dpPropertySinks = {}; // sink -> 'doi:<family>'
  final Map<String, String> dpPropertySinkSrc = {}; // sink -> proxy key

  /// How many documents (created, and saved serializations) are kept —
  /// the oldest out first (audit #12: a long session never grows them).
  static const int maxDocs = 64;

  void capDocs() {
    if (createdDocs.length > maxDocs) {
      createdDocs.removeRange(0, createdDocs.length - maxDocs);
    }
    if (docBytes.length > maxDocs) {
      for (final u in docBytes.keys.take(docBytes.length - maxDocs).toList()) {
        docBytes.remove(u);
      }
    }
  }
}

Map<String, Object?> _containerRecord(DoiState st, String shell) => st.containers.putIfAbsent(shell, () {
    return <String, Object?>{
      'docs': <Document>[],
      'current': null as Object?,
      'pending_items': <(String, String)>[],
      'pending_tables': <String, String>{},
    };
  });

Map<String, String> _containerShells(EaSession session) {
  final out = <String, String>{};
  for (final c in session.createdControls) {
    if (containerClassRx.hasMatch(c.cls) && !session.destroyedControls.contains(c.handle)) {
      out[c.handle] = c.cls;
    }
  }
  return out;
}

String? _shellOfObject(EaSession session, FlushCall call, VerbMeta m, Map<String, String> containers) {
  final obj = m.obj.trim();
  final meta = verbMeta(call);
  for (var i = 0; i < call.verbs.length; i++) {
    if (!call.verbs[i].startsWith('CreateControl')) continue;
    final res = meta[i].result?.trim() ?? '';
    if (res == obj) {
      final args = verbArgs(call, i + 1);
      for (final (_n, v) in args) {
        if (_n == '#1' && RegExp(r'^\d+$').hasMatch(v.trim())) return v.trim();
      }
    }
  }
  final v = m.objValue.trim();
  if (RegExp(r'^\d+$').hasMatch(v)) {
    return session.shellAlias[v] ?? v;
  }
  return null;
}

Document? _currentDoc(DoiState st, String? shell) {
  final cont = shell != null ? st.containers[shell] : null;
  if (cont != null && cont['current'] != null) return cont['current'] as Document;
  for (final c in st.containers.values) {
    if (c['current'] != null) return c['current'] as Document;
  }
  return null;
}

Document? _numberedDoc(DoiState st, String? shell, String? number) {
  final n = _int(number, 1);
  final conts = <Map<String, Object?>>[
    if (shell != null && st.containers.containsKey(shell)) st.containers[shell]!,
    ...st.containers.values.where((c) => shell == null || c != st.containers[shell])
  ];
  for (final c in conts) {
    for (final d in (c['docs'] as List<Document>)) {
      if (d.number == n && !d.closed) return d;
    }
  }
  for (final c in conts) {
    for (final d in (c['docs'] as List<Document>)) {
      if (d.number == n) return d;
    }
  }
  return null;
}

Document? _anyDoc(DoiState st) =>
    st.createdDocs.isNotEmpty ? st.createdDocs.last.$2 : null;

Document? _docOf(DoiState st, EaSession session, VerbMeta m, Map<String, String> containers) {
  final obj = m.obj.trim();
  final objv = m.objValue.trim();
  final d = st.proxies['obj:$objv'] ?? st.proxies['row:$obj'];
  if (d != null) return d;
  if (RegExp(r'^\d+$').hasMatch(objv)) {
    for (final e in containers.entries) {
      if (objv == e.key || objv == (session.shellAlias[e.key] ?? e.key)) {
        return _currentDoc(st, e.key);
      }
    }
  }
  if (st.createdDocs.length == 1) return st.createdDocs.first.$2;
  return null;
}

/// Fold one parsed OLE_FLUSH_CALL into the document model BEFORE answering;
/// returns {VARS row index: value bytes} for model-known results — merged
/// into the answer's prop store (observe_call port).
Map<int, Uint8List> doiObserveCall(EaSession session, DoiState st, FlushCall call) {
  final out = <int, Uint8List>{};
  final verbs = call.verbs;
  if (verbs.isEmpty) return out;
  final meta = verbMeta(call);
  final containers = _containerShells(session);
  final lastError = <String, String>{};
  final dpUrlByRow = <String, String>{};
  if (containers.isEmpty && st.proxies.isEmpty && !verbs.any((v) => v == 'CreateDocument' || v == 'OpenDocument')) {
    return out;
  }
  for (final b in dpPushBindings(call)) {
    if (rangeRoles.contains(b.role ?? '')) {
      for (final u in b.urls) {
        session.dpUrlOwner[u] = b;
      }
    }
  }
  for (var i = 1; i <= verbs.length; i++) {
    final verb = verbs[i - 1];
    final m = meta[i - 1];
    final args = {for (final a in verbArgs(call, i)) a.$1: a.$2};
    final obj = m.obj.trim();
    final objv = m.objValue.trim();
    final res = m.result?.trim() ?? '';
    if (verb == 'SetDataFromUrl') {
      final u = (args['#3'] ?? '').trim();
      if (u.startsWith('SAPR3://') && obj.isNotEmpty) {
        dpUrlByRow[obj] = u;
        if (st.docBytes.containsKey(u)) {
          st.dpRoles['row:$obj'] = ('document', u);
        }
      }
    } else if (verb == 'CreateDocument' || verb == 'OpenDocument') {
      var shell = _shellOfObject(session, call, m, containers);
      if (!containers.containsKey(shell ?? '') && containers.length == 1) {
        shell = containers.keys.first;
      }
      if (shell == null) continue;
      final cont = _containerRecord(st, shell);
      String? url;
      Uint8List? data;
      if (verb == 'OpenDocument') {
        url = (args['#3'] ?? '').trim();
        if (url.isNotEmpty) {
          final seg = session.dpCache.byUrl[url];
          if (seg != null) {
            final content = dpPutContent(seg);
            data = content?.content;
          }
        }
      }
      final doc = Document(args['#1'] ?? '', (cont['docs'] as List<Document>).length + 1, sourceUrl: url);
      if (url != null && url.isNotEmpty && data == null) {
        doc.notes.add('OpenDocument source $url not in the DP cache; the model starts empty');
      }
      doc.stringItems.addAll(cont['pending_items'] as List<(String, String)>);
      doc.tables.addAll(cont['pending_tables'] as Map<String, String>);
      cont['pending_items'] = <(String, String)>[];
      cont['pending_tables'] = <String, String>{};
      (cont['docs'] as List<Document>).add(doc);
      cont['current'] = doc;
      st.createdDocs.add((shell, doc));
      st.capDocs();
      st.pendingActivation.add(shell);
      if (res.isNotEmpty) {
        out[int.parse(res) - 1] = Uint8List.fromList(doc.number.toString().codeUnits);
      }
    } else if (verb == 'GetDocumentProxyInterface') {
      final shell = _shellOfObject(session, call, m, containers);
      final doc = _currentDoc(st, shell);
      if (doc != null && res.isNotEmpty) {
        st.proxies['row:$res'] = doc;
      }
    } else if (verb == 'HasDocumentInterface') {
      if (res.isNotEmpty) {
        final shell = _shellOfObject(session, call, m, containers);
        final has = _currentDoc(st, shell) != null;
        final one = has ? '1' : '0';
        out[int.parse(res) - 1] = Uint8List.fromList(one.codeUnits);
      }
    } else if (verb == 'AddStringItem' || verb == 'AddStringItem2') {
      final doc = _docOf(st, session, m, containers);
      final item = (rfcCellsArgText(args['#1'] ?? ''), rfcCellsArgText(args['#2'] ?? ''));
      if (doc != null) {
        doc.stringItems.add(item);
      } else {
        var shell = _shellOfObject(session, call, m, containers);
        if (!containers.containsKey(shell ?? '')) {
          shell = containers.isNotEmpty ? containers.keys.last : (shell ?? '?');
        }
        final cont = _containerRecord(st, shell ?? '?');
        (cont['pending_items'] as List<(String, String)>).add(item);
      }
    } else if (verb == 'AddInternalTable') {
      final doc = _docOf(st, session, m, containers);
      final name = rfcCellsArgText(args['#1'] ?? '');
      final url = (args['#3'] ?? '').trim();
      if (doc != null) {
        doc.tables[name] = url;
      } else {
        var shell = _shellOfObject(session, call, m, containers);
        if (!containers.containsKey(shell ?? '')) {
          shell = containers.isNotEmpty ? containers.keys.last : (shell ?? '?');
        }
        final cont = _containerRecord(st, shell ?? '?');
        (cont['pending_tables'] as Map<String, String>)[name] = url;
      }
    } else if (verb == 'SetRangesData3' || verb == 'SetRangesData2') {
      final doc = _docOf(st, session, m, containers);
      if (doc != null) {
        _applyBoundRanges(session, st, doc, objv);
      }
    } else if (verb == 'GetRangesData2') {
      final doc = _docOf(st, session, m, containers);
      if (doc != null) {
        final slots = m.slots;
        final r1 = slots['#1']?.trim() ?? '';
        final r2 = slots['#2']?.trim() ?? '';
        if (r1.isNotEmpty) st.dpRoles['row:$r1'] = ('ranges', doc);
        if (r2.isNotEmpty) st.dpRoles['row:$r2'] = ('contents', doc);
      }
    } else if (verb == 'GetSheets2') {
      final doc = _docOf(st, session, m, containers);
      final row = m.slots['#1']?.trim() ?? '';
      if (doc != null && row.isNotEmpty) {
        st.dpRoles['row:$row'] = ('sheets', doc);
      }
    } else if (verb == 'GetActiveSheet') {
      final doc = _docOf(st, session, m, containers);
      if (doc != null && res.isNotEmpty) {
        out[int.parse(res) - 1] = Uint8List.fromList(doc.activeSheet.codeUnits);
      }
    } else if (verb == 'ExecuteMacro') {
      final doc = _docOf(st, session, m, containers);
      final name = (args['#1'] ?? '').trim();
      if (res.isNotEmpty) {
        out[int.parse(res) - 1] = Uint8List.fromList(macroRefusedRc.codeUnits);
      }
      lastError[obj] = '$macroRefusedText ($name)';
      doc?.notes.add('ExecuteMacro \'$name\' refused (rc $macroRefusedRc)');
    } else if (verb == 'LastErrorString') {
      final text = lastError[obj] ?? (lastError.isNotEmpty ? lastError.values.first : '');
      if (res.isNotEmpty && text.isNotEmpty) {
        out[int.parse(res) - 1] = Uint8List.fromList(text.codeUnits);
      }
    } else if (verb == 'SaveDocumentToURL') {
      final shell = _shellOfObject(session, call, m, containers);
      final doc = _numberedDoc(st, shell, args['#1']);
      final url = (args['#2'] ?? '').trim();
      if (doc != null && url.isNotEmpty) {
        st.docBytes
          ..remove(url) // newest last: the cap drops the oldest save
          ..[url] = doc.toCsv();
        doc.savedUrls.add(url);
        st.capDocs();
      }
    } else if (verb == 'CloseDocument') {
      final shell = _shellOfObject(session, call, m, containers);
      final doc = _numberedDoc(st, shell, args['#1']);
      if (doc != null) {
        doc.closed = true;
      }
    } else if (verb == 'SaveDataToUrl') {
      final sink = (args['#3'] ?? '').trim();
      if (!sink.startsWith('SAPR3://')) continue;
      var role = st.dpRoles['row:$obj'] ?? st.dpRoles['obj:$objv'];
      if (role == null && dpUrlByRow.containsKey(obj) && st.docBytes.containsKey(dpUrlByRow[obj])) {
        role = ('document', dpUrlByRow[obj]!);
      }
      if (role == null) continue;
      if (role.$1 == 'document') {
        st.docSinks[sink] = role.$2 as String;
      } else {
        st.dpPropertySinks[sink] = 'doi:${role.$1}';
        st.dpPropertySinkSrc[sink] = _proxyKey(st, role.$2);
      }
    }
  }
  return out;
}

String rfcCellsArgText(String v) => argText(v);

String _proxyKey(DoiState st, Object docOrUrl) {
  if (docOrUrl is Document) {
    for (final e in st.proxies.entries) {
      if (identical(e.value, docOrUrl) && e.key.startsWith('obj:')) return e.key.substring(4);
    }
    return 'doc${docOrUrl.number}';
  }
  return docOrUrl.toString();
}

void _applyBoundRanges(EaSession session, DoiState st, Document doc, String proxyHandle) {
  final key = proxyHandle.isNotEmpty ? proxyHandle : _proxyKey(st, doc);
  final ranges = _boundPushRows(session, key, 'Ranges');
  final placements = _boundPushRows(session, key, 'RangeDef');
  final content = _boundPushRows(session, key, 'Content2').isNotEmpty
      ? _boundPushRows(session, key, 'Content2')
      : _boundPushRows(session, key, 'Content');
  doc.applyRangesData(ranges, placements, content);
}

List<List<String>> _boundPushRows(EaSession session, String docKey, String role) {
  for (final url in session.dpCache.order.reversed) {
    final b = session.dpUrlOwner[url];
    if (b?.role != role || b?.owner != docKey) continue;
    final seg = session.dpCache.byUrl[url];
    if (seg == null) continue;
    final (_, rows) = pushTableByFormat(seg);
    return [
      for (final row in rows)
        [for (final c in row.split(' | ')) c.trim()]
    ];
  }
  return const [];
}

/// AFTER the answer minted handles: bind row-keyed proxies/roles to handles
/// (note_answer port).
void doiNoteAnswer(DoiState st, FlushCall call) {
  final meta = verbMeta(call);
  final mints = call.mintTrace;
  var k = 0;
  for (var i = 1; i <= call.verbs.length; i++) {
    final verb = call.verbs[i - 1];
    final res = meta[i - 1].result?.trim() ?? '';
    String? minted;
    const mintVerbs = {
      'CreateObject', 'CreateControl', 'CreateControl2', 'GetDocumentProxyInterface',
      'GetContainer', 'GetDataAsFormat', 'automationObject', 'GetActiveSheet'
    };
    if (mintVerbs.contains(verb) && k < mints.length) {
      final (mv, handle, _al) = mints[k];
      if (mv == verb) {
        minted = handle.toString();
        k++;
      }
    }
    if (minted == null) continue;
    if (verb == 'GetDocumentProxyInterface' && st.proxies.containsKey('row:$res')) {
      st.proxies['obj:$minted'] = st.proxies.remove('row:$res')!;
    }
    if (verb == 'CreateObject' && st.dpRoles.containsKey('row:$res')) {
      st.dpRoles['obj:$minted'] = st.dpRoles.remove('row:$res')!;
    }
  }
}

Document? docForSource(DoiState st, String src) {
  final d = st.proxies['obj:$src'];
  if (d != null) return d;
  final m = RegExp(r'^doc(\d+)$').firstMatch(src);
  if (m != null) {
    for (final e in st.createdDocs) {
      if (e.$2.number == int.parse(m.group(1)!)) return e.$2;
    }
  }
  return _anyDoc(st);
}

// ---------------------------------------------------------------------------
// DP_GET answers from the model
// ---------------------------------------------------------------------------

/// The INURL a DP_GET names.
String? dpgetInurl(Uint8List requestV) {
  final m = RegExp('SAPR3://[0-9A-Fa-f]+').firstMatch(String.fromCharCodes(requestV));
  return m?.group(0);
}

/// The REQUEST's own FORMAT records ((width, records)).
(int, List<Uint8List>) dpgetFormat(Uint8List requestV) {
  final anchor = Uint8List.fromList([
    0x03, 0x01, 0x00, 0x06, ...'FORMAT'.codeUnits, 0x03, 0x01,
  ]);
  var i = _indexOf(requestV, anchor, 0);
  if (i < 0) return (0, const []);
  final ds = i + anchor.length;
  var end = requestV.length;
  for (final needle in [
    [0x02, 0x13],
    [0x03, 0x01, 0x00]
  ]) {
    final e = _indexOfBytes(requestV, needle, ds);
    if (e >= 0 && e < end) end = e;
  }
  final bd = requestV.buffer
      .asByteData(requestV.offsetInBytes, requestV.lengthInBytes);
  var width = 0;
  if (ds + 8 <= requestV.length &&
      requestV[ds] == 0x03 && requestV[ds + 1] == 0x02 &&
      bd.getUint16(ds + 2) >= 8) {
    width = bd.getUint32(ds + 4);
  }
  final records = <Uint8List>[];
  var j = ds;
  while (j < end - 4) {
    if (requestV[j] == 0x03 && requestV[j + 1] == 0x04) {
      final rl = bd.getUint16(j + 2);
      if (rl >= 77) records.add(Uint8List.sublistView(requestV, j + 4, j + 4 + rl));
      j += 6 + rl;
    } else if (requestV[j] == 0x03 && requestV[j + 1] == 0x05) {
      final cell = find0305Cells(Uint8List.sublistView(requestV, j, end));
      if (cell.isEmpty) break;
      final p = parse0305Cell(cell.first.bytes);
      if (p != null) {
        final blob = lzhInflate(p.lzh);
        if (blob != null) {
          final w = width > 0 ? width : 80;
          for (var q = 0; q + w <= blob.length; q += w) {
            records.add(Uint8List.sublistView(blob, q, q + w));
          }
        }
      }
      j = cell.first.endOff;
    } else {
      j += 1;
    }
  }
  return (width, records);
}

int _indexOf(Uint8List b, Uint8List needle, int from) {
  for (var i = from; i + needle.length <= b.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (b[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

int _indexOfBytes(Uint8List b, List<int> needle, int from) {
  for (var i = from; i + needle.length <= b.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (b[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

class FmtRec {
  FmtRec(this.index, this.offset, this.length, this.decimals, this.type, this.raw);
  final int index;
  final int offset;
  final int length;
  final int decimals;
  final int type;
  final Uint8List raw;
}

FmtRec fmtRec(Uint8List rec) {
  final bd = rec.buffer.asByteData(rec.offsetInBytes, rec.lengthInBytes);
  return FmtRec(bd.getUint32(60, Endian.little), bd.getUint32(64, Endian.little),
      bd.getUint32(68, Endian.little), bd.getUint32(72, Endian.little), rec[76], rec);
}

/// Fixed-width rows laid out by the request's own FORMAT records.
List<Uint8List> layoutRowsByFormat(List<Uint8List> records, List<Map<String, String>> rows) {
  final geom = <(String, int, int)>[];
  var rowLen = 0;
  for (final rec in records) {
    final name = String.fromCharCodes(rec, 30, 60).trim().toUpperCase();
    final f = fmtRec(rec);
    geom.add((name, f.offset, f.length));
    final extent = f.offset + f.length;
    if (extent > rowLen) rowLen = extent;
  }
  final out = <Uint8List>[];
  for (final row in rows) {
    final buf = Uint8List(rowLen)..fillRange(0, rowLen, 0x20);
    for (final (name, off, ln) in geom) {
      var v = row[name] ?? '';
      if (v.length > ln) v = v.substring(0, ln);
      for (var i = 0; i < v.length; i++) {
        buf[off + i] = v.codeUnitAt(i) & 0xff;
      }
    }
    out.add(buf);
  }
  return out;
}

/// The property read-back answer envelope: the request's FORMAT + our rows
/// (build_property_table_answer port).
Uint8List? buildPropertyTableAnswer(Uint8List requestV, List<Uint8List> rows) {
  final (width0, records) = dpgetFormat(requestV);
  if (records.isEmpty) return null;
  var width = width0;
  if (width == 0) {
    width = records.map((r) => r.length).reduce((a, b) => a > b ? a : b);
  }
  var fmtLen = 0;
  for (final rec in records) {
    final f = fmtRec(rec);
    final extent = f.offset + f.length;
    if (extent > fmtLen) fmtLen = extent;
  }
  final rowLen = fmtLen;
  if (rowLen <= 0) return null;
  final cells = [
    for (final x in rows)
      Uint8List.fromList([
        ...x.take(rowLen),
        ...List.filled(rowLen > x.length ? rowLen - x.length : 0, 0x20)
      ])
  ];
  final table = BytesBuilder(copy: false);
  table.add(_tok('DATAASC'));
  table.add(_dims(rowLen, cells.length));
  table.add(tableColumn(cells, width: rowLen));
  table.add(_tok('FORMAT'));
  table.add(_dims(width, records.length));
  table.add(tableColumn(records, width: width));
  table.add(_tok('PROPS'));
  table.add(_dims(80, 0));
  final scalars = <String, String>{
    'TYPE': 'APPLICATION/X-R3TABLE',
    'SUBTYPE': 'X-R3TABLE',
    'DATE': '',
    'TIME': '',
    'DESCRIPTION': '',
    'TOTALSIZE': '\x00\x00\x00\x00',
    'PLATTFORM': '',
  };
  return buildDpAnswer(
      scalars: scalars,
      tableRegion: table.takeBytes(),
      extraScalars: [('SEND_DATA_AS_STRING', '')],
      trailer: false);
}

Uint8List _tok(String name) {
  final n = Uint8List.fromList(name.codeUnits);
  return Uint8List.fromList([0x03, 0x01, (n.length >> 8) & 0xff, n.length & 0xff, ...n, 0x03, 0x01]);
}

Uint8List _dims(int w, int c) {
  final o = Uint8List(12);
  o[0] = 0x03;
  o[1] = 0x02;
  o.buffer.asByteData().setUint16(2, 8);
  o.buffer.asByteData().setUint32(4, w);
  o.buffer.asByteData().setUint32(8, c);
  return o;
}

/// The RFC reply of a model pull (sent by the session loop as 16/8/1).
Uint8List? doiAnswerPullRfc(EaSession session, DoiState st, Uint8List value) {
  final inurl = dpgetInurl(value);
  if (inurl == null) return null;
  final family = st.dpPropertySinks[inurl];
  if (family == null || !family.startsWith('doi:')) return null;
  final src = st.dpPropertySinkSrc[inurl];
  if (src == null) return null;
  final doc = docForSource(st, src);
  if (doc == null) return null;
  final fam = family.split(':')[1];
  List<Map<String, String>> rows;
  if (fam == 'ranges') {
    rows = [
      for (final (n, r, c, code) in doc.rangeRows())
        {'1': n, '2': r.toString().padLeft(4, '0'), '3': c.toString().padLeft(4, '0'), '4': code}
    ];
  } else if (fam == 'contents') {
    rows = [
      for (final (rr, cc, v) in doc.contentRows())
        {'1': rr.toString().padLeft(4, '0'), '2': cc.toString().padLeft(4, '0'), '3': v}
    ];
  } else if (fam == 'sheets') {
    rows = [
      for (final n in (doc.sheets.keys.toList()..sort()))
        {'1': n}
    ];
  } else {
    return null;
  }
  final (_, records) = dpgetFormat(value);
  return buildPropertyTableAnswer(value, layoutRowsByFormat(records, rows));
}

/// The save-back document pull's verdict: true = ours and serialised,
/// null = ours but REFUSED (unserialised), false = not a document pull.
bool? doiDocumentPullVerdict(DoiState st, Uint8List value) {
  if (!String.fromCharCodes(value).contains('DP_GET')) return false;
  final inurl = dpgetInurl(value);
  if (inurl == null) return false;
  final url = st.docSinks[inurl];
  if (url == null) return false;
  if (st.docErrors.containsKey(url)) return null;
  return st.docBytes.containsKey(url);
}

/// The RFC reply of the save-back document pull: the document bytes as the
/// recorded upload envelope (TYPE application, SUBTYPE x-ole-document,
/// TOTALSIZE u32 LE, DATABIN 1022-byte records). Null when not ours.
Uint8List? doiAnswerDocumentPullRfc(DoiState st, Uint8List value) {
  if (doiDocumentPullVerdict(st, value) != true) return null;
  final inurl = dpgetInurl(value)!;
  final data = st.docBytes[st.docSinks[inurl]]!;
  final b = BytesBuilder(copy: false);
  for (var i = 0; i < data.length; i += 1022) {
    final end = (i + 1022) < data.length ? i + 1022 : data.length;
    b.add(Uint8List.sublistView(data, i, end));
    if (end < data.length) b.add(Uint8List.fromList([0x03, 0x05, 0x03, 0x05]));
  }
  final databin = wrap0305Cell(lzhCompressStored(b.takeBytes()));
  final table = BytesBuilder(copy: false)
    ..add(_tok('DATABIN'))
    ..add(_dims(1022, (data.length / 1022).ceil()))
    ..add(databin)
    ..add(Uint8List.fromList([0x03, 0x06]));
  final scalars = <String, String>{
    'TYPE': 'application',
    'SUBTYPE': 'x-ole-document',
    'DATE': '',
    'TIME': '',
    'DESCRIPTION': '',
    'TOTALSIZE': _leU32Str(data.length),
    'PLATTFORM': '',
  };
  return buildDpAnswer(scalars: scalars, tableRegion: table.takeBytes());
}

String _leU32Str(int v) => String.fromCharCodes([
      v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff,
    ]);


