/// A HEADLESS OFFICE for SAP Desktop Office Integration (screen_doi port):
/// hosts `SAP.DocumentContainerControl.1` and the Office proxies as session
/// objects backed by an in-memory document model, answers every DOI call,
/// and serves the ranges/contents/sheets pulls from the model.
library;

import 'dart:convert' show utf8;
import 'dart:typed_data';

import '../framing/envelope.dart' show containsBytes;
import '../lzh/lzh.dart';
import 'browser_launch.dart' show verbArgText;
import 'dp_cache.dart';
import 'ea_responder.dart';
import 'flush_call.dart';
import 'doi_alv_sheet.dart' show alvColumnAt, applyAlvTable;
import 'doi_chart.dart' show DoiChart;
import 'doi_default_chart.dart' show applyDefaultChart, isExcelChartClass;
import 'doi_pivot.dart' show applyInsertFull2;
import 'frontend_rfc.dart' show buildFrontendExceptionReply;
import 'office_document.dart';
import 'reply_container.dart';
import 'rfc_cells.dart';
import 'tree_header_names.dart' show collapseInlineRow;

const String macroRefusedRc = '30';
const String macroRefusedText =
    'macro not executed: no macro engine on this client';
// The two sheet names GuiGo answers without a document to read them from.
// They are NOT two defaults of one kind: the first
// is a document's OWN name, the second the emulated Office's. Both are
// replayed byte-for-byte against their recordings (doi_replay_test,
// xxl_word_demos_replay_test), so neither is a free choice — the
// localisation they carry is part of the emulated-client identity, like
// the Windows GUI version string.

/// The sheet a document OPENED from bytes GuiGo cannot read starts with —
/// the BDS demo sheet's own `Tabelle1` (a recorded session gui[84]): the
/// name lives in the document, not in Office, so a German demo document
/// answers German wherever it is opened. Not a client default.
const String defaultSheet = 'Tabelle1';

/// THE client default: the sheet a CREATED workbook starts with. It is the
/// new-workbook name of the Office this client emulates — the French Office
/// 16 of the reference captures (XXL's GetActiveSheet, a recorded session
/// two_runs srv[56] -> gui[47] t8 `Feuil1`, InsertFull2's source sheet #5;
/// the created chart's data sheet, doi_default_chart.dart). A server flow
/// branching on the sheet name sees this locale on every device, exactly
/// as it would from that Office; a per-device name would break the
/// recorded replays and buy nothing (no SAP flow in the captures reads it
/// back as text). Every created sheet name goes through this constant.
const String createdSheet = 'Feuil1';
final RegExp containerClassRx = RegExp(r'^SAP\.DocumentContainerControl\.\d+$', caseSensitive: false);

const Set<String> rangeRoles = {'RangeDef', 'Ranges', 'Content2', 'Content'};

/// The container's event 2 (`%_GC <shell> 2`): SAPsdcc.OCX's typelib
/// names it `_SAPContainerControlEvents.OnCloseDocument(nCookie,
/// bEverChanged, bChangedAfterSave)` (dispid 2; 1 is OnCustomEvent, 3
/// OnSaveDocument), PARAMs 0..2 in that order ([doiCloseEventParams]); the
/// ABAP's ON_CLOSE_DOCUMENT. The real GUI raised it on a DOI container in
/// eleven recorded rounds, each when the user was DONE with the document:
///
/// * an Office window closed by the user — a recorded session gui[19]
/// (the chart), a recorded session gui[43] / [58] /
/// [90], a recorded session gui[50] / [86],
/// a recorded session gui[118] (DECODE: "the operator
/// closed Word / Excel");
/// * an in-place document left for the SAP window, the event round right
/// before the user's SAP action — a recorded session
/// gui[41] then `/nex` gui[43] (SO10 display), a recorded session
/// gui[15] then the Save key gui[17] (SO10 change, after typing in
/// Word), a recorded session gui[956] then F3 gui[958] (SO10
/// display) and gui[1234] then F3 gui[1239] (SMARTFORMS display),
/// a recorded session gui[156] then the tree click gui[158]
/// (OAOR's Word).
///
/// Never on the click INTO the document (a selection, a click in Word
/// sends nothing: editor_selection_redo DECODE §3) and never on a document
/// the user did not work in: a recorded session opened ten
/// SMARTFORMS text nodes in place, each container registering event 2
/// (srv[21] RegisterOcxEvent(134, 2)), and left them by tree clicks with no
/// event at all; a recorded session went to `/nex` without
/// it. The server's answer is ON_CLOSE_DOCUMENT's: SO10 frees the document
/// proxies (editor_selection_redo srv[50]), SMARTFORMS tears the Word
/// editor down (connect_su53 srv[1507..1509]: CloseDocument, ReleaseDocument,
/// ReleaseAllDocuments, StopLinkServer, DestroyWindow) — so a frontend that
/// raised it on the first touch closed the document under the user's
/// finger. GuiGo raises it on leaving ([SapSession.officeDocumentEntered]).
const int officeCloseDocumentEvent = 2;

/// The SAPscript Word template's own macros the recorded Office 16 GUI ran
/// (rc '0', LastErrorString ''): SO10 srv[47] `ExecuteMacro2('AutoExec')`,
/// srv[48] `ExecuteMacro('ProtectDocument')` (a recorded session
/// selection_redo gui[39] / gui[40]), SMARTFORMS `UnProtectDocument`
/// (a recorded session gui[45]). Any other macro gets the
/// recorded refusal ([macroRefusedRc]: SAPRDEMOWORD97INTEGRATION's
/// `R3UpdateTables` / `swap_color`, a recorded session gui[122]).
const Set<String> templateMacros = {
  'autoexec', 'protectdocument', 'unprotectdocument',
};

/// What the recorded Office 16 proxies answer `GetVersion` (the Word proxy,
/// SO10 gui[30]: 8 '16.0') and `Version` on a document proxy (type 8: the
/// Excel proxy '5', a recorded session gui[44]; the Designer
/// '11.0.9.20250609.2.65', a recorded session gui[38]) — the
/// FormPainter's `Version` stays the int build [methodType] maps (3 '230').
/// A Word proxy's `Version` is on no record: it keeps the table's type.
const String officeGetVersion = '16.0';
const String excelProxyVersion = '5';
const String designerProxyVersion = '11.0.9.20250609.2.65';

/// The `Version` a document proxy of [doc]'s class answers, null when none
/// is on record.
String? proxyVersionOf(Document doc) {
  if (doc.kind == OfficeDocKind.excel) return excelProxyVersion;
  if (doc.cls.toLowerCase().startsWith('pdfxmldesigner.')) {
    return designerProxyVersion;
  }
  return null;
}

/// DOI typing table — every entry pinned on the real SAP GUI for Windows
/// with Office 16 (a recorded session, a recorded session,
/// a recorded session, a recorded session,
/// a recorded session; doi_replay_test pairs them) and carried by
/// [methodType]. `Version` / `GetVersion` are context-typed:
/// [doiObserveCall] stamps 8 on a document proxy's row.
const Map<String, int> doiMethodTypes = {
  'InitControl': 3, 'AddInternalTable': 3, 'CreateDocument': 3, 'OpenDocument': 3, 'LastError': 3,
  'GetDocumentProxyInterface': 9, 'HasDocumentInterface': 3, 'CloseDocument': 3, 'SaveDocumentToURL': 3,
  'ReleaseDocument': 3, 'ReleaseAllDocuments': 3, 'StopLinkServer': 3, 'SetRangesData3': 3,
  'SetRangesData2': 3, 'GetRangesData2': 3, 'SetRangesFormat2': 3, 'GetCellFormat2': 3, 'GetSheets2': 3,
  'GetActiveSheet': 8, 'GetProtection': 8, 'GetDimension': 3, 'GetAllfields': 3, 'AddStringItem': 3,
  'AddStringItem2': 3, 'ExecuteMacro': 3, 'LastErrorString': 8, 'AddMenuBar': 3, 'AddMenu': 3,
  'AddMenuItem': 3, 'HideRows': 3, 'ShowRows': 3, 'InsertRange': 3, 'DeleteRange': 3, 'SetSelection': 3,
  'ProtectDocument': 3, 'AddSchema2': 3, 'CheckRegisteredProgIDs': 3,
  // the proxy's "did the document change?" — CL_FP_FB_TEMPLATE_DESIGNER
  // ->has_changed (read on the test system) pulls ret_value into `DATA return_value
  // TYPE i VALUE 1` and tests `return_value = 0`: the answer must be a
  // NUMERIC ZERO (VT_I4 '0', like every sibling DOI method) or — retcode
  // apart — SFP's pai_layout reads CHANGED and pops FPUIFB 051 (the
  // 'Impossible de sauvegarder modifications de mise en forme en mode
  // affich.!' Information modal) when the user works in the read-only
  // Designer. The typed-11 '0' and the blank-BSTR attempt both failed
  // live (the test system/the test system): the i keeps its 1 default unless the row converts.
  'HasDocumentChanged': 3,
  // a recorded session: the chart / spreadsheet / Word 97 / pivot demos
  'StartLinkServer': 3, 'AddTableItem': 3, 'AddBinaryItem': 3, 'InsertRange2': 3,
  'InsertRangeDim2': 3, 'InsertOneTable': 3, 'SetFieldtype': 3, 'SetSelection2': 3,
  'SetSourceTable': 3, 'SetFrame': 3, 'FitWidest': 3, 'DrillUp': 3, 'DrillDown': 3,
  // SO10 / SMARTFORMS (the SAPscript Word editor), SFP (the Designer)
  'InstallReadOnlyTemplate': 3, 'SetTemplate': 3, 'ExecuteMacro2': 3, 'SetInPlaceBorderSpace': 3,
  // XXL's insert_full (a recorded session srv[45]-[51],
  // a recorded session srv[49]-[57]): the spreadsheet's
  // formatting calls, error_nr ints like the rest; the decimal separator
  // and the pivot's status text strings
  'SetFormat': 3, 'SetColor': 3, 'CellFormat': 3, 'ScreenUpdating': 3, 'LoadLib': 3,
  'GetApplicationProperty': 8, 'InsertFull2': 8,
  // the ALV in-place sheet's members (a recorded session
  // srv[55]-[58], [61]: t3 `0`) and the Office manager's ProgID list
  // (srv[171] -> gui[143])
  'SetDataTable': 3, 'SetInfoTable': 3, 'SetFixedCols': 3, 'SetLocale': 3,
  'UpdateFrontend': 3, 'GetSelectedAreas': 3, 'GetRegisteredProgIDs': 3,
};

/// The SUBTYPE and DATABIN record width a document's save-back upload
/// carries, by its family and format — the real GUI's uploads: Excel
/// NATIVE `x-ole-document` x 1022 (a recorded session gui[28], the chart's
/// CFB workbook), Word 97 NATIVE `msword` x 1022 (gui[117]), Word RTF
/// (SO10) `x-ole-document` x 256 (a recorded session gui[20]). Null:
/// no upload of that kind is on record — the pull is refused.
(String, int)? uploadShapeOf(OfficeDocKind kind, String format) {
  final rtf = format.trim().toUpperCase() == 'RTF';
  return switch (kind) {
    OfficeDocKind.excel => rtf ? null : ('x-ole-document', 1022),
    OfficeDocKind.word => rtf ? ('x-ole-document', 256) : ('msword', 1022),
    OfficeDocKind.other => null,
  };
}

class DocRange {
  int top = 1;
  int left = 1;
  int rows = 1;
  int cols = 1;
  String code = '';
}

/// One DOI document: what the server sent ([sourceBytes], uploaded back
/// unchanged on a save — never a serialisation of ours) and, for a
/// spreadsheet, the range / cell model the SOI calls fill. A Word document
/// has no spreadsheet model ([sheets] stays empty): its model is the source
/// bytes, the format and the bookmarks.
class Document {
  Document(this.cls, this.number,
      {this.sourceUrl, String format = 'NATIVE', this.created = false})
      : kind = officeKindOf(cls),
        format = format.trim().isEmpty ? 'NATIVE' : format.trim().toUpperCase() {
    if (created) activeSheet = createdSheet;
    if (kind != OfficeDocKind.word) sheets[activeSheet] = {};
  }

  final String cls;
  final int number;
  final String? sourceUrl;

  /// The Office family of [cls].
  final OfficeDocKind kind;

  /// The format the server opened / created the document in: `NATIVE` or
  /// `RTF` (OpenDocument / CreateDocument #2).
  final String format;

  /// Made by CreateDocument (a new, empty document — the frontend holds no
  /// bytes the server sent), not opened from a url.
  final bool created;

  /// The document's bytes as the server pushed them (bounded by the push's
  /// TOTALSIZE), null when none arrived (a CreateDocument, a BDS document
  /// only published).
  Uint8List? get sourceBytes => _sourceBytes;
  Uint8List? _sourceBytes;

  /// The SUBTYPE the server's push of [sourceBytes] declared
  /// (`x-oleobject` for SO10's RTF), '' when unknown.
  String sourceSubtype = '';

  /// Opened read-only (OpenDocument's open flags bit 0x200 — SO10 display
  /// 513 vs the demos' 257) or protected (ProtectDocument / the SAPscript
  /// template's `ProtectDocument` macro; `UnProtectDocument` lifts it).
  bool readOnly = false;

  /// Opened in Office's own window, not in place: CreateDocument /
  /// OpenDocument's open mode (#4) C_OI_CONTAINER_CONTROL_PROXY=>
  /// OPEN_MODE_EDIT -2 (`open_inplace = ''` — XXL_FULL_API's created
  /// `Excel.Sheet`, the chart demo's created chart, the Word 97 demo), vs
  /// OPEN_MODE_INPLACEEDIT -4 / INPLACEVIEW -5 (the BDS sheet,
  /// a recorded session srv[49]). The real GUI shows such a document in an
  /// Excel / Word window that outlives the SAP control (release_document).
  bool outOfPlace = false;

  /// The read-only template the document was attached to (SetTemplate
  /// after InfoCtrl.InstallReadOnlyTemplate) and its bytes as pushed.
  String? templateName;
  Uint8List? templateBytes;

  /// The Word model's bookmarks (no bookmark verb is on record yet: G6).
  final List<String> bookmarks = [];

  /// Bumps on every change of the document (bytes, cells, ranges).
  int version = 0;

  void setSource(Uint8List bytes, {String subtype = ''}) {
    _sourceBytes = bytes;
    sourceSubtype = subtype;
    version++;
  }

  /// The sheets in tab order (a chart sheet holds no cells): sheet ->
  /// (row, column) 1-based -> the cell's text.
  final Map<String, Map<(int, int), String>> sheets = {};

  /// The cells typed as numbers ([setNumber]: the created chart's data),
  /// their text in [sheets]; a [setCell] makes a cell text again.
  final Map<String, Map<(int, int), num>> numbers = {};

  /// The chart sheets' charts, by sheet name (doi_default_chart.dart: a
  /// created `Excel.Chart`).
  final Map<String, DoiChart> charts = {};
  String activeSheet = defaultSheet;
  final Map<String, DocRange> ranges = {};
  final List<String> rangeOrder = [];
  final List<(String, String)> stringItems = [];
  final Map<String, String> tables = {};
  bool closed = false;

  /// The server released the document (ReleaseDocument /
  /// ReleaseAllDocuments): its Office window may live on ([outOfPlace]),
  /// but no later verb of another container addresses it
  /// (a recorded session srv[54]/[55]).
  bool released = false;
  final List<String> savedUrls = [];
  final List<String> notes = [];

  /// The largest range one push may declare: a row/column bound (Excel's
  /// own sheet limits) and a cell budget — [contentRows] materializes
  /// rows x cols tuples, so a pushed 10^6 x 10^6 range would hang the
  /// 'contents' pull.
  static const int maxRangeRows = 1048576;
  static const int maxRangeCols = 16384;
  static const int maxRangeCells = 1 << 20;

  void defineRange(String name, int top, int left, int rows, int cols, [String code = '']) {
    final n = name.trim();
    if (!ranges.containsKey(n)) rangeOrder.add(n);
    final r = ranges.putIfAbsent(n, DocRange.new);
    if (top > 0) r.top = top;
    if (left > 0) r.left = left;
    if (rows > 0) r.rows = rows;
    if (cols > 0) r.cols = cols;
    if (r.rows > maxRangeRows) r.rows = maxRangeRows;
    if (r.cols > maxRangeCols) r.cols = maxRangeCols;
    if (r.rows * r.cols > maxRangeCells) {
      r.rows = maxRangeCells ~/ r.cols;
      if (r.rows < 1) r.rows = 1;
    }
    if (code.isNotEmpty) r.code = code;
    version++;
  }

  void setCell(int row, int col, String value, [String? sheet]) {
    sheets.putIfAbsent(sheet ?? activeSheet, () => {})[(row, col)] = value;
    numbers[sheet ?? activeSheet]?.remove((row, col));
    version++;
  }

  String cell(int row, int col, [String? sheet]) =>
      (sheets[sheet ?? activeSheet] ?? const {})[(row, col)] ?? '';

  /// A number cell: [value] typed, its text (`12`, `1.5`) in [sheets].
  void setNumber(int row, int col, num value, [String? sheet]) {
    final s = sheet ?? activeSheet;
    final whole = value is int ||
        (value.isFinite && value == value.roundToDouble() && value.abs() < 1e15);
    setCell(row, col, whole ? value.toInt().toString() : value.toString(), s);
    numbers.putIfAbsent(s, () => {})[(row, col)] = value;
  }

  /// The typed number of a [setNumber] cell, null for a text cell.
  num? numberAt(int row, int col, [String? sheet]) =>
      numbers[sheet ?? activeSheet]?[(row, col)];

  /// The numeric formats SetFormat gave named ranges: range -> decimals
  /// (i_oi_spreadsheet~set_format(range, typ 1, currency, decimals) — XXL's
  /// data columns DATA5..DATA9, a recorded session srv[52]).
  final Map<String, int> numberFormats = {};

  /// What Excel holds at the cell: a [setNumber] number, the number a
  /// numeric text becomes in a range [numberFormats] formats (the server
  /// sends `2976986.78000000000000` as text; Excel stores the number), else
  /// the text.
  Object valueAt(int row, int col, [String? sheet]) {
    final s = sheet ?? activeSheet;
    final n = numberAt(row, col, s);
    if (n != null) return n;
    final text = cell(row, col, s);
    if (text.isNotEmpty && s == activeSheetOfRanges && numberFormats.isNotEmpty) {
      for (final MapEntry(key: name, value: _) in numberFormats.entries) {
        final rg = ranges[name];
        if (rg == null ||
            row < rg.top ||
            row >= rg.top + rg.rows ||
            col < rg.left ||
            col >= rg.left + rg.cols) {
          continue;
        }
        final v = num.tryParse(text.trim());
        if (v != null) {
          return v == v.roundToDouble() && v.abs() < 1e15 ? v.toInt() : v;
        }
      }
    }
    return text;
  }

  /// The sheet the named ranges were placed on (InsertRangeDim2 places them
  /// on the active sheet; a later pivot sheet does not move them).
  String activeSheetOfRanges = '';

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
          // the cell budget bounds the whole answer, not just one range
          if (out.length >= maxRangeCells) return out;
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

  /// Office's dirty state as the frontend reports it — OnCloseDocument's
  /// bEverChanged ([everChanged]) and bChangedAfterSave ([changedSinceSave],
  /// also CloseDocument's out-parameter bChanged: SAPsdcc.OCX typelib
  /// `CloseDocument(nCookie, nSaveMode, bChanged)`). A document is dirty
  /// once CREATED (a recorded session gui[19], xxl_excel_word_demos
  /// gui[43] / [58], xxl_two_runs gui[50] / [86]: (1, 1, 1)) or once a
  /// macro RAN in it (rc 0: the SAPscript template's AutoExec /
  /// ProtectDocument — editor_selection_redo gui[41], text_html gui[15],
  /// connect_su53 gui[956] / [1234] (1, 1, 1); R3UpdateTables in
  /// macros_disabled gui[118] (1, 1, 1)); a refused macro or a plain open
  /// leaves it clean (xxl_excel_word_demos gui[90] after rc 30,
  /// alv_excel_inplace gui[156] OAOR's protected Word: (1, 0, 0)). A
  /// SaveDocumentToURL clears [changedSinceSave]. CloseDocument answers
  /// [changedSinceSave] whatever its save flag — every recorded close:
  /// 1 for SMARTFORMS' nine text nodes with no event (a recorded session
  /// smartforms_text_word srv[39] .. [123]) and connect_su53 srv[1497] /
  /// [1105] / [1507], a recorded session srv[32], xxl_excel_word_demos
  /// srv[77], macros_disabled srv[144]; 0 after a save (text_html srv[28],
  /// save srv[23]), after a refused macro (xxl_excel_word_demos srv[107],
  /// word_demo_links srv[43], a recorded session srv[170]) and for an
  /// opened document no macro ran in (a recorded session srv[103],
  /// bds_cold_cache srv[48] / [66], macros_disabled srv[45] — ranges the
  /// server wrote into an opened sheet do not count).
  late bool everChanged = created;

  /// See [everChanged].
  late bool changedSinceSave = created;
}

int _int(String? v, int dflt) => int.tryParse((v ?? '').trim()) ?? dflt;

/// An ABAP integer argument as the kernel writes it — a trailing sign for
/// a negative one (`2-`, `1-`: a recorded session's open modes and
/// `updating`); null when not a number.
int? _abapInt(String? v) {
  final s = (v ?? '').trim();
  if (s.endsWith('-')) {
    final n = int.tryParse(s.substring(0, s.length - 1).trim());
    return n == null ? null : -n;
  }
  return int.tryParse(s);
}

/// C_OI_CONTAINER_CONTROL_PROXY=>OPEN_MODE_EDIT: the document opens in
/// Office's own window (`open_inplace = ''`); INPLACEEDIT is -4,
/// INPLACEVIEW -5.
const int openModeEdit = -2;

/// The decimal separator the Office 16 Excel reports
/// (Application.International) — the en-US / fr-CH Windows default. NOT on
/// record: the recorded PC's locale is unknown.
const String excelDecimalSeparator = '.';

/// What the Excel application answers GetApplicationProperty([property],
/// [sub]) with, null when unknown (the blank default).
String? excelApplicationProperty(String property, String sub) {
  final p = property.trim().toUpperCase(), s = sub.trim().toUpperCase();
  if (p == 'INTERNATIONAL' && s == 'DECIMAL_SEPARATOR') {
    return excelDecimalSeparator;
  }
  return null;
}

/// A pushed cell value as text: the decoded field, trimmed.
String _text(String v) {
  final z = v.indexOf('\x00');
  return (z >= 0 ? v.substring(0, z) : v).trim();
}

/// One field of a DOI range push by its FORMAT type letter (the SOI
/// structures' ABAP types, X-UNKNOWN catalogs): `I` a little-endian INT4
/// (the Content2 ROW / COLUMN columns), `X` the 512-byte UTF-16LE VALUE
/// column — decoded up to its first NUL code unit, never cut at the first
/// zero BYTE (which kept one character of every value: a recorded session
/// srv[53] `31 00 32 00 …` read `1` for `12`) — and `C` (the Ranges push's
/// `range1` / ` 12` / ` 5`) as 1-byte text up to its first NUL.
String doiPushField(Uint8List raw, int type) {
  if (raw.isEmpty) return '';
  if (type == 0x49 /* I */ && raw.length <= 8) {
    var v = 0;
    for (var i = raw.length - 1; i >= 0; i--) {
      v = (v << 8) | raw[i];
    }
    // a signed INT4
    if (raw.length == 4 && v >= 0x80000000) v -= 0x100000000;
    return '$v';
  }
  if (type == 0x58 /* X */ && raw.length.isEven) {
    final units = <int>[];
    for (var i = 0; i + 1 < raw.length; i += 2) {
      final cu = raw[i] | (raw[i + 1] << 8);
      if (cu == 0) break;
      units.add(cu);
    }
    return String.fromCharCodes(units).trim();
  }
  return decodeRsField(raw, type).trim();
}

/// A DOI range push's rows decoded by its own FORMAT ([doiPushField] per
/// column; [pushTableByFormat]'s layout), each a list of cell texts.
List<List<String>> doiPushRows(Uint8List seg) => _pushRows[seg] ??=
    List.unmodifiable([for (final r in _doiPushRows(seg)) List<String>.unmodifiable(r)]);

/// [doiPushRows] per cached segment: a push's rows are read by every
/// verb that names it (Ranges / RangeDef / Content per range read), and a
/// cached segment never changes.
final Expando<List<List<String>>> _pushRows = Expando('DOI push rows');

List<List<String>> _doiPushRows(Uint8List seg) {
  final (_, (fw, fn), fcells) = dpColumnCells(seg, 'FORMAT');
  final fmt = BytesBuilder(copy: false);
  for (final c in fcells) {
    fmt.add(c);
  }
  var f = fmt.takeBytes();
  if (fw > 0 && fn > 0 && f.length > fw * fn) {
    f = Uint8List.sublistView(f, 0, fw * fn);
  }
  final cols = f.isNotEmpty ? placeholderColumns(f) : null;
  if (cols == null || cols.isEmpty) return const [];
  final (_, (dw, dn), dcells) = dpColumnCells(seg, 'DATAASC');
  final data = BytesBuilder(copy: false);
  for (final c in dcells) {
    data.add(c);
  }
  final d = data.takeBytes();
  var rl = 0;
  for (final c in cols) {
    if (c.offset + c.length > rl) rl = c.offset + c.length;
  }
  if (dw > 0 && dw >= rl) rl = dw;
  if (rl <= 0) return const [];
  final n = dn > 0 && dn * rl <= d.length ? dn : d.length ~/ rl;
  return [
    for (var k = 0; k < n; k++)
      [
        for (final c in cols)
          doiPushField(
              Uint8List.sublistView(
                  d,
                  k * rl + c.offset,
                  k * rl + (c.offset + c.length > rl ? rl : c.offset + c.length)),
              c.type),
      ],
  ];
}

/// Session DOI state.
class DoiState {
  final Map<String, Map<String, Object?>> containers = {}; // shell -> record
  final Map<String, Document> proxies = {}; // row:/obj: -> doc
  final Map<String, (String, Object)> dpRoles = {}; // row:/obj: -> (role, doc or url)
  final Map<String, Uint8List> docBytes = {}; // url -> the document as sent
  final Map<String, (String, int)> docShapes = {}; // url -> (SUBTYPE, width)
  final Map<Object, String> docErrors = {}; // url/number -> reason
  final Map<String, String> docSinks = {}; // sink url -> doc url
  final List<(String, Document)> createdDocs = [];
  final Map<String, String> dpPropertySinks = {}; // sink -> 'doi:<family>'
  final Map<String, String> dpPropertySinkSrc = {}; // sink -> proxy key

  /// CheckRegisteredProgIDs result sinks: sink url -> the pushed ProgID
  /// table segment the Office manager checked (a recorded session
  /// srv[26]: SetDataFromUrl(dp, …028000) CheckRegisteredProgIDs
  /// SaveDataToUrl(dp, …02A000), pulled by srv[27]).
  final Map<String, Uint8List> progIdSinks = {};

  /// GetRegisteredProgIDs result sinks: sink url -> the pushed (empty)
  /// table whose FORMAT the list is uploaded in (a recorded session
  /// inplace srv[171]: SetDataFromUrl(dp, …8000) GetRegisteredProgIDs
  /// ('BASIC', dp) SaveDataToUrl(…, …A000), pulled by srv[172]).
  final Map<String, Uint8List> progIdListSinks = {};

  /// The containers whose open document has not raised its OnCloseDocument
  /// yet ([officeCloseDocumentEvent]) — once per opened document; a
  /// CloseDocument of the server's ends it.
  final Set<String> closeEventPending = {};

  /// The containers whose in-place document the user ENTERED (tapped into)
  /// since it opened, entry order: the next user round leaves it, and its
  /// OnCloseDocument goes out first ([SapSession.officeDocumentEntered]).
  final Set<String> entered = {};

  /// The OCX events each container registered (RegisterOcxEvent).
  final Map<String, Set<int>> registeredEvents = {};

  /// InfoCtrl.InstallReadOnlyTemplate: template file name -> its bytes as
  /// the server pushed them (SO10's SAPscriptWord2007.dotm, srv[40..45]).
  final Map<String, Uint8List> templates = {};

  /// How many documents (created, and saved serializations) are kept —
  /// the oldest out first (a long session never grows them).
  static const int maxDocs = 64;

  /// How many entries each handle-keyed map (containers, proxies, DP
  /// roles, sinks, errors) keeps — the oldest out first.
  static const int maxEntries = 256;

  void capDocs() {
    if (createdDocs.length > maxDocs) {
      createdDocs.removeRange(0, createdDocs.length - maxDocs);
    }
    // the containers hold every Document they created: bound them too, or
    // they defeat the createdDocs cap
    for (final c in containers.values) {
      final docs = c['docs'];
      if (docs is List<Document> && docs.length > maxDocs) {
        docs.removeRange(0, docs.length - maxDocs);
      }
    }
    _capOldest(containers, maxEntries);
    _capOldest(proxies, maxEntries);
    _capOldest(dpRoles, maxEntries);
    _capOldest(docErrors, maxEntries);
    _capOldest(docSinks, maxEntries);
    _capOldest(dpPropertySinks, maxEntries);
    _capOldest(dpPropertySinkSrc, maxEntries);
    _capOldest(progIdSinks, maxEntries);
    _capOldest(progIdListSinks, maxEntries);
    _capOldest(registeredEvents, maxEntries);
    _capOldest(templates, maxDocs);
    for (final s in [closeEventPending, entered]) {
      if (s.length > maxEntries) {
        s.removeAll(s.take(s.length - maxEntries).toList());
      }
    }
    if (docBytes.length > maxDocs) {
      for (final u in docBytes.keys.take(docBytes.length - maxDocs).toList()) {
        docBytes.remove(u);
        docShapes.remove(u);
      }
    }
    _capOldest(docShapes, maxEntries);
  }
}

/// Drop [m]'s oldest (first-inserted) entries past [max].
void _capOldest<K, V>(Map<K, V> m, int max) {
  if (m.length <= max) return;
  for (final k in m.keys.take(m.length - max).toList()) {
    m.remove(k);
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
      for (final (n, v) in args) {
        if (n == '#1' && _digitsOnlyRx.hasMatch(v.trim())) return v.trim();
      }
    }
  }
  final v = m.objValue.trim();
  if (_digitsOnlyRx.hasMatch(v)) {
    return session.shellAlias[v] ?? v;
  }
  return null;
}

Document? _currentDoc(DoiState st, String? shell) {
  final cont = shell != null ? st.containers[shell] : null;
  if (cont != null && cont['current'] != null) return cont['current'] as Document;
  for (final c in st.containers.values) {
    final d = c['current'];
    if (d is Document && !d.released) return d;
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

/// Write the X-R3TABLE push [seg] into [rg] of [doc], row by row from its
/// top-left (clipped to the range), each field as the Office 16 sheet held
/// it (a recorded session gui[69], the SFLIGHT rows): C
/// text trimmed (`AA`, `747-400`), N a number (`0017` -> 17), D
/// `dd.mm.yyyy` (`20260324` -> `24.03.2026`), P the packed decimal with its
/// FORMAT decimals (`422.94`, `192518.34`), I / s the integer. The FORMAT
/// record: column, offset, length, decimals, ABAP type (u32 LE each, from
/// byte 60).
void applyOneTable(Document doc, DocRange rg, Uint8List seg) {
  final (_, (fw, fn), fcells) = dpColumnCells(seg, 'FORMAT');
  final (_, (dw, dn), dcells) = dpColumnCells(seg, 'DATAASC');
  if (fw != 80 || fn <= 0 || dw <= 0 || dn <= 0) return;
  Uint8List join(List<Uint8List> parts) {
    final b = BytesBuilder(copy: false);
    for (final p in parts) {
      b.add(p);
    }
    return b.toBytes();
  }

  final fmt = join(fcells);
  if (fmt.length < fw * fn) return;
  // one `03 04` cell per row has its trailing blanks cut: pad each back to
  // the record width (decodeNamedDpTable)
  final perRow = dcells.length == dn && dcells.every((c) => c.length <= dw);
  final data = perRow ? _padRows(dcells, dw, dn) : join(dcells);
  final fb = ByteData.sublistView(fmt);
  final cols = [
    for (var i = 0; i < fn && i < rg.cols; i++)
      (
        fb.getUint32(i * fw + 64, Endian.little),
        fb.getUint32(i * fw + 68, Endian.little),
        fb.getUint32(i * fw + 72, Endian.little),
        fb.getUint32(i * fw + 76, Endian.little),
      ),
  ];
  for (var r = 0; r < dn && r < rg.rows && (r + 1) * dw <= data.length; r++) {
    final rec = Uint8List.sublistView(data, r * dw, (r + 1) * dw);
    for (final (c, (off, len, dec, type)) in cols.indexed) {
      if (off + len > rec.length) continue;
      final raw = Uint8List.sublistView(rec, off, off + len);
      final row = rg.top + r, col = rg.left + c;
      final n = _oneTableNumber(raw, dec, type);
      if (n != null) {
        doc.setNumber(row, col, n);
        continue;
      }
      var text = utf8.decode(raw, allowMalformed: true)
          .replaceAll('\u0000', '')
          .trim();
      if (type == 0x44 && _yyyymmddRx.hasMatch(text)) {
        // D: the OCX's day.month.year
        text = '${text.substring(6)}.${text.substring(4, 6)}.'
            '${text.substring(0, 4)}';
      }
      doc.setCell(row, col, text);
    }
  }
}

/// The [n] row cells of a `03 04`-per-row DATAASC column, each padded with
/// blanks back to the record width [w], as ONE `w * n` buffer: one
/// allocation and one fill for the table instead of a padded copy per row
/// plus the join. Same bytes as padding each row.
Uint8List _padRows(List<Uint8List> cells, int w, int n) {
  final out = Uint8List(w * n)..fillRange(0, w * n, 0x20);
  for (var r = 0; r < n; r++) {
    final c = cells[r];
    out.setRange(r * w, r * w + c.length, c);
  }
  return out;
}

// Hoisted out of the row x column loop of [applyOneTable]:
// a D cell's `yyyymmdd`, an N cell's digits.
final RegExp _yyyymmddRx = RegExp(r'^\d{8}$');
final RegExp _nDigitsRx = RegExp(r'^\d{1,15}$');

/// A one-table field of ABAP [type] as a number: N digits, P packed BCD
/// with [dec] decimals, I / s little-endian integers; null otherwise.
num? _oneTableNumber(Uint8List raw, int dec, int type) {
  final bd = ByteData.sublistView(raw);
  switch (type) {
    case 0x49 when raw.length >= 4: // I
      return bd.getInt32(0, Endian.little);
    case 0x73 when raw.length >= 2: // s
      return bd.getInt16(0, Endian.little);
    case 0x4e: // N
      final t = String.fromCharCodes(raw).trim();
      return _nDigitsRx.hasMatch(t) ? int.parse(t) : null;
    case 0x50 when raw.isNotEmpty && raw.length <= 9: // P (17 digits fit)
      var v = 0;
      for (var k = 0; k < raw.length; k++) {
        final hi = raw[k] >> 4, lo = raw[k] & 15;
        if (hi > 9) return null;
        v = v * 10 + hi;
        if (k < raw.length - 1) {
          if (lo > 9) return null;
          v = v * 10 + lo;
        } else if (lo < 10) {
          return null; // no sign nibble
        }
      }
      final neg = (raw.last & 15) == 0xD || (raw.last & 15) == 0xB;
      final s = neg ? -v : v;
      if (dec <= 0) return s;
      if (dec > 15) return null;
      var p = 1;
      for (var k = 0; k < dec; k++) {
        p *= 10;
      }
      return s % p == 0 ? s ~/ p : s / p;
  }
  return null;
}

/// Whether Excel accepts [name] as a defined name (its documented rules:
/// a letter, `_` or `\` first, then letters, digits, `.`, `_`, `\`, `?`;
/// at most 255 characters; never `C` / `R` alone nor a cell reference such
/// as `A1` / `XFD1048576` / `R1C1`). `22` fails (a recorded session
/// disabled gui[57]: InsertRange2 6), `ert` passes (a recorded session
/// srv[61]: 0).
// [excelNameValid]'s rules, compiled once.
final RegExp _excelNameRx =
    RegExp(r'^[\p{L}_\\][\p{L}\p{N}._\\?]*$', unicode: true);
final RegExp _r1c1Rx = RegExp(r'^R\d*C\d*$');
final RegExp _a1Rx = RegExp(r'^([A-Z]{1,3})(\d+)$');

bool excelNameValid(String name) {
  final n = name.trimRight();
  if (n.isEmpty || n.length > 255) return false;
  if (!_excelNameRx.hasMatch(n)) return false;
  final u = n.toUpperCase();
  if (u == 'C' || u == 'R') return false;
  if (_r1c1Rx.hasMatch(u)) return false;
  final a1 = _a1Rx.firstMatch(u);
  if (a1 != null) {
    var col = 0;
    for (final c in a1.group(1)!.codeUnits) {
      col = col * 26 + c - 64;
    }
    final row = int.tryParse(a1.group(2)!) ?? 0;
    if (col <= 16384 && row >= 1 && row <= 1048576) return false;
  }
  return true;
}

/// The container [shell] raised OnCloseDocument ([officeCloseDocumentEvent])
/// with [params] (nCookie, bEverChanged, bChangedAfterSave): the dirty
/// state it reports is that document's ([Document.everChanged]) — what the
/// CloseDocument that follows answers. GuiGo's own event reports its own
/// flags; in the replays this takes the real GUI's (a macro that GUI ran
/// and this one refuses: a recorded session gui[118]).
void doiNoteCloseEvent(DoiState st, String shell, Map<int, String> params) {
  final docs = st.containers[shell.trim()]?['docs'];
  if (docs is! List<Document>) return;
  final n = _int(params[0], 1);
  for (final d in docs.reversed) {
    if (d.number == n && !d.closed) {
      d.everChanged = (params[1] ?? '').trim() == '1';
      d.changedSinceSave = (params[2] ?? '').trim() == '1';
      return;
    }
  }
}

/// OnCloseDocument's PARAMs 0..2 for [d] as SAPsdcc.OCX raises them:
/// nCookie (the container's document number), bEverChanged,
/// bChangedAfterSave ([Document.everChanged]) — `1, 1, 1` for SO10's /
/// SMARTFORMS' SAPscript text (editor_selection_redo gui[41]),
/// `1, 0, 0` for OAOR's protected Word (alv_excel_inplace gui[156]).
List<String> doiCloseEventParams(Document d) => [
  '${d.number}',
  d.everChanged ? '1' : '0',
  d.changedSinceSave ? '1' : '0',
];

Document? _anyDoc(DoiState st) =>
    st.createdDocs.isNotEmpty ? st.createdDocs.last.$2 : null;

Document? _docOf(DoiState st, EaSession session, VerbMeta m, Map<String, String> containers) {
  final obj = m.obj.trim();
  final objv = m.objValue.trim();
  final d = st.proxies['obj:$objv'] ?? st.proxies['row:$obj'];
  if (d != null) return d;
  if (_digitsOnlyRx.hasMatch(objv)) {
    for (final e in containers.entries) {
      if (objv == e.key || objv == (session.shellAlias[e.key] ?? e.key)) {
        // THAT container's document only: before its CreateDocument /
        // OpenDocument it has none, and the link-server items wait for it
        // (pending) — never the document of another, released container
        // (a recorded session srv[64]-[67] / srv[90]: the
        // chart demo's and the Word demo's items landed on the previous
        // scene's sheet / chart)
        return st.containers[e.key]?['current'] as Document?;
      }
    }
  }
  if (st.createdDocs.length == 1 && !st.createdDocs.first.$2.released) {
    return st.createdDocs.first.$2;
  }
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
  // a container this queue creates (its CreateControl may not be folded
  // into the session's control facts yet: a chunked creation wave)
  for (var i = 1; i <= verbs.length; i++) {
    if (!verbs[i - 1].startsWith('CreateControl')) continue;
    final a = {for (final x in verbArgs(call, i)) x.$1: x.$2};
    final sh = (a['#1'] ?? '').trim();
    final cls = (a['#2'] ?? '').trim();
    if (_digitsOnlyRx.hasMatch(sh) &&
        containerClassRx.hasMatch(cls) &&
        !session.destroyedControls.contains(sh)) {
      containers.putIfAbsent(sh, () => cls);
    }
  }
  final lastError = <String, String>{};
  final dpUrlByRow = <String, String>{};
  // the teardown flush destroys its container in the same queue (its
  // DestroyWindow is folded first) after the proxies were freed: its
  // ReleaseAllDocuments still releases the documents
  // (a recorded session srv[49] / [67])
  if (containers.isEmpty &&
      st.proxies.isEmpty &&
      !verbs.any((v) =>
          v == 'CreateDocument' ||
          v == 'OpenDocument' ||
          v == 'ReleaseDocument' ||
          v == 'ReleaseAllDocuments' ||
          v == 'CheckRegisteredProgIDs' ||
          v == 'GetRegisteredProgIDs')) {
    return out;
  }
  for (final (sh, ev) in call.registeredEvents) {
    if (containers.containsKey(sh)) (st.registeredEvents[sh] ??= {}).add(ev);
  }
  for (final b in dpPushBindings(call)) {
    if (rangeRoles.contains(b.role ?? '')) {
      for (final u in b.urls) {
        session.dpUrlOwner[u] = b;
      }
    }
  }
  // the pushes this queue carries itself, joined across its chunks (SO10's
  // template rides the InstallReadOnlyTemplate flush, srv[40..45]; the SFP
  // XDP the OpenDocument one) — read once, only when a verb needs them
  DpCache? own;
  DpCache ownPushes() => own ??= (DpCache()..ingestValue(call.raw));
  final checksProgIds = verbs.contains('CheckRegisteredProgIDs');
  final listsProgIds = verbs.contains('GetRegisteredProgIDs');
  String? lastLoaded; // the url the last SetDataFromUrl of the call loaded
  // the container objects whose OpenDocument this call could not start:
  // the LastError code each answers next (the OpenDocument wrapper's
  // one-flush batch, a recorded session srv[28])
  final openFailed = <String, String>{};
  for (var i = 1; i <= verbs.length; i++) {
    final verb = verbs[i - 1];
    final m = meta[i - 1];
    // a `_SPARAMETER` argument (a url longer than a VARS cell) is the SVARS
    // item it numbers, never its row's `1`: the Word 97 demo's BDS
    // OpenDocument #3 (a recorded session srv[125] -> SAPR3://SAPR3CMS/get/
    // …/DEMOWORD97DOC) — read as `1`, the document the server pushed under
    // that url was never found, and its SaveDocumentToURL refused (33 ->
    // SOFFICEINTEGRATION 133, SAPRDEMOWORD97INTEGRATION SELECT, live
    // 2026-10-14) where the real GUI saved it (srv[126] '0', gui[117])
    final args = {
      for (final a in verbArgs(call, i))
        a.$1: verbArgText(call, i, a.$1) ?? a.$2,
    };
    final obj = m.obj.trim();
    final objv = m.objValue.trim();
    final res = m.result?.trim() ?? '';
    final failKey = objv.isNotEmpty ? objv : obj;
    if (verb == 'FreeObject') {
      // a released handle names no proxy / data object any more: the next
      // object reuses its number (Windows handle reuse) — a stale binding
      // put the chart demo's link-server items on the XXL sheet's document
      // (a recorded session srv[53] frees the proxies,
      // srv[62] mints the next container under a freed number)
      final h = (args['#1'] ?? '').trim();
      if (_digitsOnlyRx.hasMatch(h)) {
        st.proxies.remove('obj:$h');
        st.dpRoles.remove('obj:$h');
      }
      continue;
    }
    if (verb == 'SetDataFromUrl') {
      final u = (args['#3'] ?? '').trim();
      if (u.startsWith('SAPR3://') && obj.isNotEmpty) {
        dpUrlByRow[obj] = u;
        lastLoaded = u;
        if (st.docBytes.containsKey(u) || st.docErrors.containsKey(u)) {
          st.dpRoles['row:$obj'] = ('document', u);
        }
      }
    } else if (verb == 'OpenDocument' && !progIdHosted(args['#1'] ?? '')) {
      // a class this frontend cannot start (no Lotus 1-2-3 …): ordinary
      // typed results and NO document — OpenDocument 0, LastError 8, the
      // proxy the null object, LastError 40 (a recorded session
      // srv[28] -> gui[21]; recorded values, SAPsdcc.OCX's enum unread).
      // The server then tears the container down itself (srv[30])
      openFailed[failKey] = '8';
      if (res.isNotEmpty) {
        _putResult(out, res, Uint8List.fromList('0'.codeUnits));
      }
    } else if (verb == 'LastError' && openFailed.containsKey(failKey)) {
      if (res.isNotEmpty) {
        _putResult(out, res, Uint8List.fromList(openFailed[failKey]!.codeUnits));
      }
    } else if (verb == 'GetDocumentProxyInterface' &&
        openFailed.containsKey(failKey)) {
      // `O-1`, no handle minted, no proxy bound (gui[21] row 20)
      final row = int.tryParse(res);
      if (row != null && row >= 1) call.nullObjectRows.add(row - 1);
      openFailed[failKey] = '40';
    } else if (verb == 'CreateDocument' || verb == 'OpenDocument') {
      var shell = _shellOfObject(session, call, m, containers);
      if (!containers.containsKey(shell ?? '') && containers.length == 1) {
        shell = containers.keys.first;
      }
      if (shell == null) continue;
      final cont = _containerRecord(st, shell);
      String? url;
      (Uint8List, String)? data;
      if (verb == 'OpenDocument') {
        url = (args['#3'] ?? '').trim();
        if (url.isNotEmpty) {
          data = _pushedBytes(session.dpCache.byUrl[url]) ??
              _pushedBytes(ownPushes().byUrl[url]);
        }
      }
      // the frontend numbers documents per container from 1 and frees a
      // number on ReleaseDocument: the re-open after ReleaseDocument(1) is
      // document 1 again (a recorded session, the second Word
      // session), never len(docs)+1
      final live = {
        for (final d in cont['docs'] as List<Document>)
          if (!d.released) d.number,
      };
      var number = 1;
      while (live.contains(number)) {
        number++;
      }
      final doc = Document(args['#1'] ?? '', number,
          sourceUrl: url, format: args['#2'] ?? '', created: verb == 'CreateDocument');
      if (data != null) {
        doc.setSource(data.$1, subtype: data.$2);
      } else if (url != null && url.isNotEmpty) {
        doc.notes.add('OpenDocument source $url not in the DP cache; the model starts empty');
      }
      // a new chart object: Excel's default chart sheet + data sheet
      // (doi_default_chart.dart, a recorded session srv[35])
      if (doc.created && isExcelChartClass(doc.cls)) applyDefaultChart(doc);
      // the open flags: 0x200 = read-only (SO10 / SMARTFORMS display 513)
      if (((int.tryParse((args['#5'] ?? '').trim()) ?? 0) & 0x200) != 0) {
        doc.readOnly = true;
      }
      // the open mode: -2 = OPEN_MODE_EDIT, Office's own window
      if (_abapInt(args['#4']) == openModeEdit) doc.outOfPlace = true;
      doc.stringItems.addAll(cont['pending_items'] as List<(String, String)>);
      doc.tables.addAll(cont['pending_tables'] as Map<String, String>);
      cont['pending_items'] = <(String, String)>[];
      cont['pending_tables'] = <String, String>{};
      (cont['docs'] as List<Document>).add(doc);
      cont['current'] = doc;
      st.createdDocs.add((shell, doc));
      st.closeEventPending
        ..remove(shell)
        ..add(shell);
      st.entered.remove(shell); // a new document: not entered yet
      st.capDocs();
      if (res.isNotEmpty) {
        _putResult(out, res, Uint8List.fromList(doc.number.toString().codeUnits));
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
        _putResult(out, res, Uint8List.fromList(one.codeUnits));
      }
    } else if (verb == 'AddStringItem' || verb == 'AddStringItem2') {
      final doc = _docOf(st, session, m, containers);
      final item = (rfcCellsArgText(args['#1'] ?? ''), rfcCellsArgText(args['#2'] ?? ''));
      if (doc != null) {
        doc.stringItems.add(item);
        doc.version++;
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
      // a Word document has no spreadsheet model
      if (doc != null && doc.kind != OfficeDocKind.word) {
        _applyBoundRanges(session, st, doc, objv);
      }
    } else if (verb == 'GetRangesData2') {
      final doc = _docOf(st, session, m, containers);
      if (doc != null && doc.kind != OfficeDocKind.word) {
        final slots = m.slots;
        final r1 = slots['#1']?.trim() ?? '';
        final r2 = slots['#2']?.trim() ?? '';
        if (r1.isNotEmpty) st.dpRoles['row:$r1'] = ('ranges', doc);
        if (r2.isNotEmpty) st.dpRoles['row:$r2'] = ('contents', doc);
      }
    } else if (verb == 'GetSheets2') {
      final doc = _docOf(st, session, m, containers);
      final row = m.slots['#1']?.trim() ?? '';
      if (doc != null && doc.kind != OfficeDocKind.word && row.isNotEmpty) {
        st.dpRoles['row:$row'] = ('sheets', doc);
      }
    } else if (verb == 'GetActiveSheet') {
      final doc = _docOf(st, session, m, containers);
      if (doc != null && res.isNotEmpty) {
        _putResult(out, res, Uint8List.fromList(doc.activeSheet.codeUnits));
      }
    } else if (verb == 'Version') {
      // on a DOI document proxy only: a string (8), not the FormPainter's
      // int build (3 '230', a recorded session gui[54])
      final doc = st.proxies['obj:$objv'] ?? st.proxies['row:$obj'];
      final v = doc == null ? null : proxyVersionOf(doc);
      if (v != null && res.isNotEmpty) {
        _stampResultType(call, i, 8);
        _putResult(out, res, Uint8List.fromList(v.codeUnits));
      }
    } else if (verb == 'GetVersion') {
      // the Word proxy's Office version (SO10 gui[30], SMARTFORMS gui[40]:
      // 8 '16.0' — the Office 16 the connect profile declares)
      if (res.isNotEmpty) {
        _stampResultType(call, i, 8);
        _putResult(out, res, Uint8List.fromList(officeGetVersion.codeUnits));
      }
    } else if (verb == 'InsertRange2') {
      // i_oi_spreadsheet~insert_range(rows, columns, name, updating): Excel
      // names the selection — a name Excel refuses fails with the proxy's
      // status 6 (C_OI_ERRORS=>TRANSLATE_PROXY_ERROR_CODE: message
      // SOFFICEINTEGRATION 206 "Error occurred while setting object
      // property") and nothing is inserted: a recorded session
      // disabled srv[66] '22' -> gui[57] 6, its next ranges upload gui[59]
      // byte-equal to gui[51]; a recorded session srv[61] 'ert' -> 0
      if (res.isNotEmpty && !excelNameValid(args['#3'] ?? '')) {
        _putResult(out, res, Uint8List.fromList('6'.codeUnits));
      }
    } else if (verb == 'InsertOneTable') {
      // i_oi_spreadsheet~insert_one_table(rangename, <dp url>, wholetable):
      // the pushed table written into the named range — a recorded session
      // macros_disabled srv[75] (94 SFLIGHT rows into InsertRangeDim2's
      // 94 x 14 `sflight`), the next contents upload gui[69] carrying them
      // ([applyOneTable]); a range of no rows (a recorded session srv[69],
      // its push empty) stays empty
      final doc = _docOf(st, session, m, containers);
      final rg = doc?.ranges[(args['#1'] ?? '').trim()];
      final url = (args['#2'] ?? '').trim();
      final seg = session.dpCache.byUrl[url] ?? ownPushes().byUrl[url];
      if (doc != null && doc.kind == OfficeDocKind.excel && rg != null &&
          seg != null) {
        applyOneTable(doc, rg, seg);
      }
    } else if (verb == 'InsertRangeDim2') {
      // i_oi_spreadsheet~insert_range_dim(name, left, top, rows, columns,
      // updating, sheetname): the named range Excel creates at those cells
      // — XXL's insert_full places its ranges so (DATA<n>, TESTVKEY,
      // TESTHKEY, TEST<n>, TESTKEYS) before SetRangesData3 fills them BY
      // NAME (OFFICEINTEGRATIONDOCPROXYIMP). A range of no rows (the pivot
      // demo's `sflight`, rows 0 — a recorded session srv[69]; the
      // InsertOneTable after it sizes it) is left to that fill.
      final doc = _docOf(st, session, m, containers);
      final name = (args['#1'] ?? '').trim();
      final left = _abapInt(args['#2']) ?? 0;
      final top = _abapInt(args['#3']) ?? 0;
      final rows = _abapInt(args['#4']) ?? 0;
      final cols = _abapInt(args['#5']) ?? 0;
      final sheet = (args['#7'] ?? '').trim();
      if (doc != null &&
          doc.kind == OfficeDocKind.excel &&
          name.isNotEmpty &&
          top > 0 &&
          left > 0 &&
          rows > 0 &&
          cols > 0 &&
          (sheet.isEmpty || sheet == doc.activeSheet)) {
        doc.defineRange(name, top, left, rows, cols);
        if (doc.activeSheetOfRanges.isEmpty) {
          doc.activeSheetOfRanges = doc.activeSheet;
        }
      }
    } else if (verb == 'SetFormat') {
      // i_oi_spreadsheet~set_format(range, typ, currency, decimals): typ 1
      // a number with that many decimals (xxl_two_runs srv[52] DATA5 `1,
      // '', 2`; the text columns `0, '', 1-`)
      final doc = st.proxies['obj:$objv'] ?? st.proxies['row:$obj'];
      final name = (args['#1'] ?? '').trim();
      if (doc != null && doc.kind == OfficeDocKind.excel && name.isNotEmpty) {
        if ((args['#2'] ?? '').trim() == '1') {
          doc.numberFormats[name] = _abapInt(args['#4']) ?? 0;
        } else {
          doc.numberFormats.remove(name);
        }
      }
    } else if (verb == 'InsertFull2') {
      // the PIVOT proxy's pivot over the filled sheet (doi_pivot.dart,
      // xxl_two_runs srv[57]); its answer is the OCX's empty status text
      final doc = st.proxies['obj:$objv'] ?? st.proxies['row:$obj'];
      if (doc != null && doc.kind == OfficeDocKind.excel) {
        List<List<String>> table(String arg) {
          final u = dpUrlByRow[(m.slots[arg] ?? '').trim()];
          final seg = u == null
              ? null
              : session.dpCache.byUrl[u] ?? ownPushes().byUrl[u];
          return seg == null ? const [] : doiPushRows(seg);
        }

        final made = applyInsertFull2(
          doc,
          dataTitles: table('#1'),
          keyTitles: table('#2'),
          header: table('#3'),
          roles: table('#4'),
          source: args['#5'] ?? '',
          dataRows: _abapInt(args['#6']) ?? 0,
          dataCols: _abapInt(args['#7']) ?? 0,
          keyCols: _abapInt(args['#8']) ?? 0,
        );
        if (made == null) doc.notes.add('InsertFull2: no pivot data');
      }
      if (res.isNotEmpty) {
        _stampResultType(call, i, 8);
        _putResult(out, res, Uint8List(0));
      }
    } else if (verb == 'SetDataTable' || verb == 'SetInfoTable') {
      // the ALV in-place view's own tables on the spreadsheet proxy
      // (doi_alv_sheet.dart; a recorded session srv[55] /
      // [56]): the DataProvider #1 was loaded in the same flush
      final doc = st.proxies['obj:$objv'] ?? st.proxies['row:$obj'];
      final u = dpUrlByRow[(m.slots['#1'] ?? '').trim()] ?? lastLoaded;
      final seg = u == null
          ? null
          : session.dpCache.byUrl[u] ?? ownPushes().byUrl[u];
      if (doc != null && doc.kind == OfficeDocKind.excel && seg != null) {
        if (applyAlvTable(doc, seg, isInfo: verb == 'SetInfoTable')) {
          doc.version++;
        }
      }
    } else if (verb == 'GetSelectedAreas') {
      // the in-place view's selection read (CL_SALV_GRU_VIEW_EXCEL
      // get_selected_cells, srv[61] / [67]): three DataProviders the OCX
      // fills — the selected areas, their rows, their columns — each
      // saved back by a later SaveDataToUrl and pulled (srv[62]-[66])
      final doc = st.proxies['obj:$objv'] ?? st.proxies['row:$obj'];
      if (doc != null && doc.kind == OfficeDocKind.excel) {
        for (final (arg, family) in const [
          ('#1', 'selareas'),
          ('#2', 'selrows'),
          ('#3', 'selcols'),
        ]) {
          final row = (m.slots[arg] ?? '').trim();
          if (row.isNotEmpty) st.dpRoles['row:$row'] = (family, doc);
        }
      }
    } else if (verb == 'SetFont') {
      // i_oi_spreadsheet~set_font: RESULT = error_nr, an int — the table's
      // object type (an automation Font) is wrong on a spreadsheet proxy
      final doc = st.proxies['obj:$objv'] ?? st.proxies['row:$obj'];
      if (doc != null && doc.kind == OfficeDocKind.excel && res.isNotEmpty) {
        _stampResultType(call, i, 3);
        _putResult(out, res, Uint8List.fromList('0'.codeUnits));
      }
    } else if (verb == 'GetApplicationProperty') {
      // i_oi_document_proxy~get_application_property: insert_full reads
      // ('INTERNATIONAL', 'DECIMAL_SEPARATOR') and TRANSLATEs its
      // SET COUNTRY 'DE' numbers (`1234,5`) with it; blank, every value's
      // comma became a space
      final v = excelApplicationProperty(args['#1'] ?? '', args['#2'] ?? '');
      if (v != null && res.isNotEmpty) {
        _putResult(out, res, Uint8List.fromList(v.codeUnits));
      }
    } else if (verb == 'ExecuteMacro' || verb == 'ExecuteMacro2') {
      final doc = _docOf(st, session, m, containers);
      final name = (args['#1'] ?? args['#01'] ?? '').trim();
      final key = name.toLowerCase();
      if (templateMacros.contains(key)) {
        // the SAPscript template's own macros: run (rc 0, no error text)
        if (res.isNotEmpty) {
          _putResult(out, res, Uint8List.fromList('0'.codeUnits));
        }
        if (doc != null) {
          if (key == 'protectdocument') doc.readOnly = true;
          if (key == 'unprotectdocument') doc.readOnly = false;
          // a macro that ran dirtied the document ([Document.everChanged])
          doc
            ..everChanged = true
            ..changedSinceSave = true;
        }
        continue;
      }
      if (res.isNotEmpty) {
        _putResult(out, res, Uint8List.fromList(macroRefusedRc.codeUnits));
      }
      lastError[obj] = '$macroRefusedText ($name)';
      doc?.notes.add('ExecuteMacro \'$name\' refused (rc $macroRefusedRc)');
    } else if (verb == 'LastErrorString') {
      final text = lastError[obj] ?? (lastError.isNotEmpty ? lastError.values.first : '');
      if (res.isNotEmpty && text.isNotEmpty) {
        _putResult(out, res, Uint8List.fromList(text.codeUnits));
      }
    } else if (verb == 'ProtectDocument') {
      final doc = _docOf(st, session, m, containers);
      doc?.readOnly = true;
    } else if (verb == 'InstallReadOnlyTemplate') {
      // the template rides this queue's own pushes (SO10 srv[40..45]: the
      // ~120 KB .dotm, a PK package): the one push that is a document
      final name = (args['#1'] ?? '').trim();
      final t = _templatePush(ownPushes()) ?? _templatePush(session.dpCache);
      if (name.isNotEmpty && t != null) {
        st.templates
          ..remove(name)
          ..[name] = t;
      }
    } else if (verb == 'SetTemplate') {
      final doc = _docOf(st, session, m, containers);
      final name = (args['#1'] ?? '').trim();
      if (doc != null && name.isNotEmpty) {
        doc.templateName = name;
        doc.templateBytes = st.templates[name];
      }
    } else if (verb == 'SaveDocumentToURL') {
      final shell = _shellOfObject(session, call, m, containers);
      final doc = _numberedDoc(st, shell, args['#1']);
      final url = (args['#2'] ?? '').trim();
      if (doc != null && url.isNotEmpty) {
        _saveDocument(st, doc, url);
        doc.savedUrls.add(url);
        // saved: clean again (a recorded session gui[15] (1, 1, 1),
        // srv[23] save, srv[28] close -> 0; [Document.everChanged])
        doc.changedSinceSave = false;
        st.capDocs();
        // a refused save is the Office's failed save, error_nr 33: with
        // officeintegration/saveerrorcheck declared (frontend_features
        // .dart) SAVE_DOCUMENT_TO_TABLE then skips its DP_GET_STREAM pull
        // and the program gets an error retcode — the pull's exception
        // reply was the CNDP 002 MESSAGE_TYPE_X dump (SAPRDEMOWORD97
        // INTEGRATION OPEN, live 2026-10-14; OFFICEINTEGRATIONDOCPROXYIMP
        // save_document_to_table, C_OI_CONTAINER_CONTROL_PROXY
        // SAVE_DOCUMENT_TO_URL: RESULT = error_nr)
        if (res.isNotEmpty && st.docErrors.containsKey(url)) {
          _putResult(out, res, Uint8List.fromList('33'.codeUnits));
        }
      }
    } else if (verb == 'ReleaseDocument' || verb == 'ReleaseAllDocuments') {
      final shell = _shellOfObject(session, call, m, containers);
      final cont = st.containers[shell ?? ''];
      if (cont != null) {
        for (final d in cont['docs'] as List<Document>) {
          if (verb == 'ReleaseAllDocuments' ||
              d.number == _int(args['#1'], 1)) {
            d.released = true;
          }
        }
      }
    } else if (verb == 'CloseDocument') {
      final shell = _shellOfObject(session, call, m, containers);
      final doc = _numberedDoc(st, shell, args['#1']);
      if (doc != null) {
        if (res.isNotEmpty) {
          // bChanged (see [Document.everChanged])
          _putResult(out, res,
              Uint8List.fromList((doc.changedSinceSave ? '1' : '0').codeUnits));
        }
        doc.closed = true;
        doc.version++;
        for (final e in st.containers.entries) {
          if (identical(e.value['current'], doc)) {
            // the server closed it: no OnCloseDocument of the frontend's
            // follows (a recorded session srv[39] .. [123])
            st.closeEventPending.remove(e.key);
            st.entered.remove(e.key);
          }
        }
      }
    } else if (verb == 'SaveDataToUrl') {
      final sink = (args['#3'] ?? '').trim();
      if (!sink.startsWith('SAPR3://')) continue;
      if (checksProgIds && res.isNotEmpty) {
        // the ProgID-check flush's answer echoes the sink url in this verb's
        // string result (a recorded session gui[20]: row 16 carried
        // `SAPR3://…02A000` where GuiGo's blank made the Form Builder abort
        // with "cannot start the design tool")
        _putResult(out, res, Uint8List.fromList(sink.codeUnits));
      }
      if (listsProgIds && dpUrlByRow.containsKey(obj)) {
        // the Office manager's registered ProgIDs, uploaded in the pushed
        // table's FORMAT (OAOR srv[171] -> gui[144])
        final src = dpUrlByRow[obj]!;
        final seg = session.dpCache.byUrl[src] ?? ownPushes().byUrl[src];
        if (seg != null) {
          st.progIdListSinks
            ..remove(sink)
            ..[sink] = Uint8List.fromList(seg);
          continue;
        }
      }
      if (checksProgIds && dpUrlByRow.containsKey(obj)) {
        // the Office manager's check result (a recorded session
        // srv[26]): the ProgID table the DP object was loaded from
        final src = dpUrlByRow[obj]!;
        final seg = session.dpCache.byUrl[src] ?? ownPushes().byUrl[src];
        if (seg != null) {
          st.progIdSinks
            ..remove(sink)
            ..[sink] = Uint8List.fromList(seg);
          continue;
        }
      }
      var role = st.dpRoles['row:$obj'] ?? st.dpRoles['obj:$objv'];
      if (role == null &&
          dpUrlByRow.containsKey(obj) &&
          (st.docBytes.containsKey(dpUrlByRow[obj]) ||
              st.docErrors.containsKey(dpUrlByRow[obj]))) {
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
  st.capDocs();
  return out;
}

/// SaveDocumentToURL(n, url): the frontend now holds the document under
/// [url] for the save-back pull — the bytes the SERVER sent, unchanged, in
/// the upload shape the real GUI used for that kind ([uploadShapeOf]). A
/// document with no such bytes (a CreateDocument, a BDS document never
/// pushed) or of a kind no upload is on record for is REFUSED at the pull
/// ([doiAnswerDocumentPullRfc]) — never a serialisation of our own model
/// (the CSV this used to upload as `x-ole-document` would have replaced
/// the server's document).
void _saveDocument(DoiState st, Document doc, String url) {
  st.docBytes.remove(url);
  st.docShapes.remove(url);
  st.docErrors.remove(url);
  final data = doc.sourceBytes;
  final shape = uploadShapeOf(doc.kind, doc.format);
  if (data == null || shape == null) {
    final why = data == null
        ? 'document ${doc.number} (${doc.cls}) holds no bytes the server sent'
        : 'no ${doc.cls} ${doc.format} upload is on record';
    st.docErrors[url] = why;
    doc.notes.add('SaveDocumentToURL refused: $why');
    return;
  }
  st.docBytes[url] = data; // newest last: the cap drops the oldest save
  st.docShapes[url] = shape;
}

/// The (content bounded by TOTALSIZE, SUBTYPE) a DP push [seg] delivers,
/// null when it carries none.
(Uint8List, String)? _pushedBytes(Uint8List? seg) {
  if (seg == null) return null;
  final c = dpPutContent(seg);
  if (c == null || c.content.isEmpty) return null;
  var data = c.content;
  // the DATAASC/DATABIN records are padded past the document: TOTALSIZE
  // is its length (SO10 srv[36]: 47 x 134 = 6298 B for a 6172-B RTF)
  final total = dpTotalSize(seg);
  if (total > 0 && total < data.length) {
    data = Uint8List.sublistView(data, 0, total);
  }
  return (Uint8List.fromList(data), _subtypeOf(seg));
}

/// The SUBTYPE scalar a push declares (`02 01 <u16 7> SUBTYPE 02 01 02 03
/// <u16 len> value 02 03`), '' when none.
String _subtypeOf(Uint8List seg) {
  const name = 'SUBTYPE';
  final end = seg.length > 8192 ? 8192 : seg.length;
  outer:
  for (var i = 0; i + 4 + name.length + 6 <= end; i++) {
    if (seg[i] != 0x02 || seg[i + 1] != 0x01 || seg[i + 2] != 0 ||
        seg[i + 3] != name.length) {
      continue;
    }
    for (var k = 0; k < name.length; k++) {
      if (seg[i + 4 + k] != name.codeUnitAt(k)) continue outer;
    }
    final j = i + 4 + name.length + 2; // past the closing 02 01
    if (j + 4 > seg.length || seg[j] != 0x02 || seg[j + 1] != 0x03) {
      continue;
    }
    final ln = (seg[j + 2] << 8) | seg[j + 3];
    if (j + 4 + ln > seg.length) return '';
    return String.fromCharCodes(seg, j + 4, j + 4 + ln).trim();
  }
  return '';
}

/// The one document-shaped push of [cache] (a zip package / OLE2 file —
/// a .dotm / .dot template), null when none or several.
Uint8List? _templatePush(DpCache cache) {
  Uint8List? found;
  for (final u in cache.order) {
    final p = _pushedBytes(cache.byUrl[u]);
    if (p == null) continue;
    final b = p.$1;
    final doc = b.length >= 4 &&
        ((b[0] == 0x50 && b[1] == 0x4b && b[2] == 0x03 && b[3] == 0x04) ||
            (b[0] == 0xd0 && b[1] == 0xcf && b[2] == 0x11 && b[3] == 0xe0));
    if (!doc) continue;
    if (found != null) return null;
    found = b;
  }
  return found;
}

/// Override the VARIANT type of verb [verbIndex]'s `_RESULT` PARAMS
/// row(s) — a verb whose type depends on the object it runs on (the
/// reference client's screen_doi._stamp_result_type).
void _stampResultType(FlushCall call, int verbIndex, int type) {
  for (var pI = 0; pI < call.params.length; pI++) {
    final p = call.params[pI];
    if ((p.name == '_RESULT' || p.name == '_RESULT_QUEUEONLY') &&
        p.objid.trim() == '$verbIndex') {
      call.resultTypes[pI] = type;
    }
  }
}

/// A verb argument as text: [verbArgs] hands it decoded already (UTF-8,
/// latin-1 fallback — `Ventes de véhicules`); only a value that is still
/// UTF-8 bytes in latin-1 form is decoded once more. ([argText] decoded
/// every one again: a decoded `é` became U+FFFD, a recorded session
/// srv[19]'s chart titles.)
String rfcCellsArgText(String v) {
  final s = v.trim();
  for (final cu in s.codeUnits) {
    if (cu > 0xff) return s;
  }
  try {
    return utf8.decode(s.codeUnits);
  } on FormatException {
    return s;
  }
}

/// [value] at the 0-based VARS row of a verb's result slot [res]. A slot
/// that is not a row number skips that one result instead of throwing out
/// of (and losing) the whole DOI fold.
void _putResult(Map<int, Uint8List> out, String res, Uint8List value) {
  final n = int.tryParse(res);
  if (n != null && n >= 1) out[n - 1] = value;
}

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
    return doiPushRows(seg);
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
      final (mv, handle, _) = mints[k];
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
  final m = _docForSourceRx.firstMatch(src);
  if (m != null) {
    for (final e in st.createdDocs) {
      if (e.$2.number == int.tryParse(m.group(1)!)) return e.$2;
    }
  }
  return _anyDoc(st);
}

// ---------------------------------------------------------------------------
// DP_GET answers from the model
// ---------------------------------------------------------------------------

/// The INURL a DP_GET names.
String? dpgetInurl(Uint8List requestV) {
  final m = _dpgetInurlRx.firstMatch(String.fromCharCodes(requestV));
  return m?.group(0);
}

/// The REQUEST's own FORMAT records ((width, records)).
(int, List<Uint8List>) dpgetFormat(Uint8List requestV) {
  final anchor = rfcColumnNameToken('FORMAT');
  var i = _indexOf(requestV, anchor, 0);
  if (i < 0) return (0, const []);
  final ds = i + anchor.length;
  // The column ends at the next column (`03 01 00`) or the table's close
  // (`02 13`) — looked for only BETWEEN cells, as [dpColumnCells] does: an
  // LZH cell's stream may hold those bytes (a recorded session
  // disabled srv[69] / [77], the ranges pulls after InsertRange2 /
  // InsertOneTable: a `02 13` inside the FORMAT cell left no records and
  // the pull unanswered, where the real GUI uploaded gui[59] / gui[67]).
  int endFrom(int from) {
    var end = requestV.length;
    for (final needle in [
      rfcTagBytes(rfcTagTableEnd),
      [...rfcTagBytes(rfcTagColumnName), 0x00],
    ]) {
      final e = _indexOfBytes(requestV, needle, from);
      if (e >= 0 && e < end) end = e;
    }
    return end;
  }

  var end = endFrom(ds);
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
      // a record running past the FORMAT region is a truncated or hostile
      // request: it ends the records, never a RangeError
      if (j + 4 + rl > end) break;
      if (rl >= _fmtRecMin) {
        records.add(Uint8List.sublistView(requestV, j + 4, j + 4 + rl));
      }
      j += 6 + rl;
    } else if (requestV[j] == 0x03 && requestV[j + 1] == 0x05) {
      final cell = find0305Cells(Uint8List.sublistView(requestV, j));
      if (cell.isEmpty || cell.first.openOff != 0) break;
      final p = parse0305Cell(cell.first.bytes);
      if (p != null) {
        final blob = lzhInflate(p.lzh);
        if (blob != null) {
          final w = width > 0 ? width : 80;
          // records narrower than a descriptor cannot be read by [fmtRec]
          for (var q = 0; w >= _fmtRecMin && q + w <= blob.length; q += w) {
            records.add(Uint8List.sublistView(blob, q, q + w));
          }
        }
      }
      j += cell.first.endOff; // the cell's offsets are relative to j
      end = endFrom(j);
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

/// The shortest FORMAT descriptor record [fmtRec] reads (its type byte is
/// at 76).
const int _fmtRecMin = 77;

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
  // the descriptor's u32 offsets/lengths come off the wire: a row layout
  // past what any decode could produce is a hostile request, not a table
  if (rowLen * rows.length > csMaxDecodedLength) return const [];
  final out = <Uint8List>[];
  for (final row in rows) {
    final buf = Uint8List(rowLen)..fillRange(0, rowLen, 0x20);
    for (final (name, off, ln) in geom) {
      // the session codepage (UTF-8, 4110): a non-ASCII cell value is its
      // UTF-8 bytes, cut at a character boundary — never its code units
      // masked to a byte
      final v = utf8.encode(row[name] ?? '');
      var cut = v.length > ln ? ln : v.length;
      while (cut < v.length && cut > 0 && (v[cut] & 0xc0) == 0x80) {
        cut--;
      }
      buf.setRange(off, off + cut, v);
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
  // the request's u32 width / offsets / lengths come off the wire: a table
  // past what any decode could produce is a hostile request
  if (rowLen <= 0 ||
      rowLen * rows.length > csMaxDecodedLength ||
      width * records.length > csMaxDecodedLength) {
    return null;
  }
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

Uint8List _tok(String name) => rfcColumnNameToken(name);

/// A column's `03 02 <u16 8> <u32 width> <u32 count> 03 02` dims token.
Uint8List _dims(int w, int c) {
  final o = Uint8List(14);
  o[0] = 0x03;
  o[1] = 0x02;
  o.buffer.asByteData().setUint16(2, 8);
  o.buffer.asByteData().setUint32(4, w);
  o.buffer.asByteData().setUint32(8, c);
  o[12] = 0x03;
  o[13] = 0x02;
  return o;
}

/// The RFC reply of a model pull (sent by the session loop as 16/8/1): a
/// `doi:<family>` sink (ranges / contents / sheets) answered from the
/// document, or an Office manager's CheckRegisteredProgIDs result sink.
Uint8List? doiAnswerPullRfc(EaSession session, DoiState st, Uint8List value) {
  final inurl = dpgetInurl(value);
  if (inurl == null) return null;
  final progIds = st.progIdSinks.remove(inurl);
  if (progIds != null) return progIdCheckAnswer(value, progIds);
  final list = st.progIdListSinks.remove(inurl);
  if (list != null) return registeredProgIdsAnswer(value, list);
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
      for (final (n, r, c, _) in doc.rangeRows())
        // CODE blank: the real Excel reports none back, whatever the
        // Ranges push set (a recorded session gui[47]: `range1 00110003 `)
        {'1': n, '2': r.toString().padLeft(4, '0'), '3': c.toString().padLeft(4, '0'), '4': ''}
    ];
  } else if (fam == 'contents') {
    rows = [
      for (final (rr, cc, v) in doc.contentRows())
        // left-aligned in blanks (a recorded session gui[49] `1 1 3`),
        // where the ranges' ROWS / COLUMNS are zero-filled (gui[47] `0011`)
        {'1': '$rr', '2': '$cc', '3': v}
    ];
  } else if (fam == 'selareas' || fam == 'selrows' || fam == 'selcols') {
    return selectionPullAnswer(value, doc, fam);
  } else if (fam == 'sheets') {
    // the workbook's sheet order (the reference client's answer_pull), not sorted
    rows = [
      for (final n in (doc.sheets.isEmpty ? const [defaultSheet] : doc.sheets.keys))
        {'1': n}
    ];
  } else {
    return null;
  }
  final (_, records) = dpgetFormat(value);
  return doiTableAnswer(value, layoutRowsByFormat(records, rows));
}

/// The in-place spreadsheet's selection read-back ([fam] `selareas` /
/// `selrows` / `selcols`): the headless sheet's selection is Excel's
/// initial one, cell A1 — the real GUI's uploads after the open
/// (a recorded session srv[62] / [64] / [66] -> gui[45] /
/// [47] / [49], the same at srv[68]-[72]): the areas table one record
/// TOP 1, LEFT 1, ROWS 1, COLUMNS 1 (INT4 LE) and a blank flag, the OCX's
/// own `0`s after it (bytes 17-19 of its 20-byte record); the rows table one
/// record row 1 with no ALV row id (row 1 is the header row); the columns
/// table one record column 1, its field name and column id from the
/// catalog. The tables' FORMAT / record width are the request's. Null
/// when the request declares no FORMAT.
Uint8List? selectionPullAnswer(Uint8List requestV, Document doc, String fam) {
  final (_, records) = dpgetFormat(requestV);
  if (records.isEmpty || records.any((r) => r.length < _fmtRecMin)) {
    return null;
  }
  final fields = [for (final r in records) fmtRec(r)];
  // the request's own DATAASC record width (20 B for the areas)
  var rowLen = dpColumnCells(requestV, 'DATAASC').$2.$1;
  for (final f in fields) {
    if (f.offset + f.length > rowLen) rowLen = f.offset + f.length;
  }
  if (rowLen <= 0 || rowLen > 1 << 16) return null;
  final (name, id) = alvColumnAt(doc, 1);
  final List<Object> values = switch (fam) {
    'selareas' => [1, 1, 1, 1, ''],
    'selrows' => [1, '', ''],
    _ => [1, name, id],
  };
  final row = Uint8List(rowLen)..fillRange(0, rowLen, 0x20);
  for (var k = 0; k < fields.length && k < values.length; k++) {
    final f = fields[k];
    final v = values[k];
    if (f.type == 0x49 /* I */ && f.length == 4 && v is int) {
      ByteData.sublistView(row, f.offset, f.offset + 4)
          .setInt32(0, v, Endian.little);
    } else {
      final b = utf8.encode('$v');
      final n = b.length < f.length ? b.length : f.length;
      row.setRange(f.offset, f.offset + n, b);
    }
  }
  final last = fields.last;
  if (fam == 'selareas') {
    // the OCX's `0`s past the fields (gui[45]: `… 20 30` collapsed)
    row.fillRange(last.offset + last.length, rowLen, 0x30);
  }
  return doiTableAnswer(requestV, [row], rowLength: rowLen);
}

/// A DOI read-back's answer in the real GUI's envelope (a recorded session
/// gui[47] / gui[49] / gui[84], the ranges / contents / sheets uploads):
/// TYPE `APPLICATION`, SUBTYPE `X-R3TABLE`, DATE `00000000`, TIME
/// `000000`, TOTALSIZE [totalSize] (0 on those; the loaded ProgID table's
/// byte count on a recorded session gui[19]), DATAASC = [rows] at
/// the request FORMAT's row length, the request's own FORMAT records, an
/// empty PROPS and the `06 67` trailer. Null when the request declares no
/// FORMAT (nothing to lay the rows out by).
Uint8List? doiTableAnswer(Uint8List requestV, List<Uint8List> rows,
    {int totalSize = 0, List<Uint8List>? formatRecords, int? rowLength}) {
  final (width0, reqRecords) = dpgetFormat(requestV);
  final records = formatRecords ?? reqRecords;
  if (records.isEmpty) return null;
  var width = width0;
  if (width == 0) {
    width = records.map((r) => r.length).reduce((a, b) => a > b ? a : b);
  }
  var rowLen = 0;
  for (final rec in records) {
    if (rec.length < _fmtRecMin) continue;
    final f = fmtRec(rec);
    final extent = f.offset + f.length;
    if (extent > rowLen) rowLen = extent;
  }
  // a record wider than its fields (the selection areas' 20 B for 17 B of
  // fields, a recorded session gui[45])
  if (rowLength != null && rowLength > rowLen) rowLen = rowLength;
  // the request's u32 width / offsets / lengths come off the wire: a table
  // past what any decode could produce is a hostile request
  if (rowLen <= 0 ||
      rowLen * rows.length > csMaxDecodedLength ||
      width * records.length > csMaxDecodedLength) {
    return null;
  }
  final cells = [
    for (final x in rows)
      Uint8List.fromList([
        ...x.take(rowLen),
        ...List.filled(rowLen > x.length ? rowLen - x.length : 0, 0x20)
      ])
  ];
  final table = BytesBuilder(copy: false)
    ..add(_tok('DATAASC'))
    ..add(_dims(rowLen, cells.length))
    ..add(_doiColumn(cells, rowLen))
    ..add(_tok('FORMAT'))
    ..add(_dims(width, records.length))
    ..add(_doiColumn(records, width))
    ..add(_tok('PROPS'))
    ..add(_dims(80, 0));
  return buildDpAnswer(scalars: {
    'TYPE': 'APPLICATION',
    'SUBTYPE': 'X-R3TABLE',
    'DATE': '00000000',
    'TIME': '000000',
    'DESCRIPTION': '',
    'TOTALSIZE': _leU32Str(totalSize),
    'PLATTFORM': '',
  }, tableRegion: table.takeBytes());
}

/// A table column as the Windows GUI writes a DOI upload: up to one cell
/// segment ([tableInlineMax]) inline `03 04` rows, each with its trailing
/// run collapsed ([collapseInlineRow]: the 80-B FORMAT records of
/// a recorded session gui[49] / gui[84] go out as 78 B); past it one LZH
/// cell of the rows verbatim (gui[47]'s 4 x 80 FORMAT, its 3 x 137 rows).
Uint8List _doiColumn(List<Uint8List> rows, int width) {
  final total = rows.fold(0, (a, r) => a + r.length);
  if (rows.isEmpty || total > tableInlineMax) {
    return tableColumn(rows, width: width);
  }
  return tableColumn([for (final r in rows) collapseInlineRow(r)]);
}

/// Whether this frontend (an Office 16 GUI: the connect profile's `Office
/// 16`) has [progId] registered: the Word and Excel document classes, and
/// the Adobe Designer's form-template class (`PDFXMLDesigner.Document` —
/// the SFP Layout tab's document, hosted read-only: the XDP the server
/// pushes is rendered by the app, never handed to a local Designer).
/// GuiGo hosts no other OLE server (no PowerPoint, Visio).
bool progIdRegistered(String progId) {
  final p = progId.trim().toLowerCase();
  return officeKindOf(p) != OfficeDocKind.other || p.startsWith('pdfxmldesigner.');
}

/// Whether OpenDocument can start a document of class [progId] here: a
/// class [progIdRegistered] hosts, or one the Office 16 PC registers
/// ([officeRegisteredProgIds], its version-independent name too —
/// `PowerPoint.Show` for `PowerPoint.Show.12`). Not `Lotus123.Workbook`
/// (a recorded session srv[28]: that PC had no Lotus).
bool progIdHosted(String progId) {
  final p = progId.trim().toLowerCase();
  if (p.isEmpty || progIdRegistered(p)) return true;
  for (final (id, _, _, _, _) in officeRegisteredProgIds) {
    final r = id.toLowerCase();
    if (r == p || r.startsWith('$p.')) return true;
  }
  return false;
}

/// The answer to the Office manager's CheckRegisteredProgIDs result pull:
/// the ProgID table the server pushed ([pushSeg]), each row written back
/// with its last column (the 1-char registered flag) `X` when
/// [progIdRegistered], blank otherwise — a recorded session gui[19]
/// (srv[26] pushed `PDFXMLDesigner.Document` with the flag blank; that GUI,
/// with the Designer installed, answered the row with `X`, its other
/// columns filled from its registry: GuiGo keeps the server's). TOTALSIZE
/// is the table's byte count (467 there), the FORMAT the push's own.
Uint8List? progIdCheckAnswer(Uint8List requestV, Uint8List pushSeg) {
  final (_, (fw, fn), fcells) = dpColumnCells(pushSeg, 'FORMAT');
  final fb = BytesBuilder(copy: false);
  for (final c in fcells) {
    fb.add(c);
  }
  final f = fb.takeBytes();
  final w = fw > 0 ? fw : cat80;
  final records = [
    for (var i = 0; (i + 1) * w <= f.length && (fn <= 0 || i < fn); i++)
      Uint8List.sublistView(f, i * w, (i + 1) * w),
  ];
  final cols = f.isEmpty ? null : placeholderColumns(
      Uint8List.sublistView(f, 0, records.length * w));
  if (cols == null || cols.isEmpty) return null;
  final (_, (dw, dn), dcells) = dpColumnCells(pushSeg, 'DATAASC');
  final db = BytesBuilder(copy: false);
  for (final c in dcells) {
    db.add(c);
  }
  final d = db.takeBytes();
  var rl = 0;
  for (final c in cols) {
    if (c.offset + c.length > rl) rl = c.offset + c.length;
  }
  if (dw > rl) rl = dw;
  if (rl <= 0) return null;
  final n = dn > 0 && dn * rl <= d.length ? dn : d.length ~/ rl;
  final flag = cols.last;
  final first = cols.first;
  final rows = <Uint8List>[];
  for (var k = 0; k < n; k++) {
    final r = Uint8List.fromList(Uint8List.sublistView(d, k * rl, (k + 1) * rl));
    final id = String.fromCharCodes(
            r, first.offset, first.offset + first.length)
        .replaceAll('\x00', '')
        .trim();
    if (flag.length >= 1 && flag.offset < r.length) {
      r[flag.offset] = progIdRegistered(id) ? 0x58 : 0x20;
    }
    rows.add(r);
  }
  return doiTableAnswer(requestV, rows,
      totalSize: rl * rows.length, formatRecords: records);
}

/// The Office document classes an Office 16 PC registers, as the Office
/// manager's `GetRegisteredProgIDs('BASIC', table)` lists them: ProgID,
/// description, short type, product, capability flags — the real SAP GUI
/// for Windows' upload, row for row (a recorded session
/// srv[172] -> gui[144], 9 records of the pushed 6-column X-UNKNOWN
/// table, the 6th column blank). The table GuiGo's Office 16 identity
/// (frontend_features.dart, frontend_registry.dart) answers with: a
/// document of these classes is shown read-only in the Office pane
/// (PowerPoint's as its bytes, the platform viewer). The no-Office table
/// is unrecorded.
const List<(String, String, String, String, String)> officeRegisteredProgIds = [
  ('Excel.Chart.8', 'Microsoft Excel Chart', 'Chart', 'Microsoft Excel 2003',
      'BASIC FORM SPREADSHEET PIVOT'),
  ('Excel.Sheet.12', 'Microsoft Excel Worksheet', 'Worksheet',
      'Microsoft Excel 12', 'BASIC FORM SPREADSHEET PIVOT'),
  ('Excel.Sheet.8', 'Microsoft Excel 97-2003 Worksheet', 'Worksheet',
      'Microsoft Excel 2003', 'BASIC FORM SPREADSHEET PIVOT'),
  ('PowerPoint.Show.12', 'Microsoft PowerPoint Presentation', 'Presentation',
      'Microsoft PowerPoint Presentation', 'BASIC'),
  ('PowerPoint.Show.8', 'Microsoft PowerPoint 97-2003 Presentation',
      'Presentation', 'Microsoft PowerPoint 97-2003 Presentation', 'BASIC'),
  ('PowerPoint.Slide.12', 'Microsoft PowerPoint Slide', 'Slide',
      'Microsoft PowerPoint Slide', 'BASIC'),
  ('PowerPoint.Slide.8', 'Microsoft PowerPoint 97-2003 Slide', 'Slide',
      'Microsoft PowerPoint 97-2003 Slide', 'BASIC'),
  ('Word.Document.12', 'Microsoft Word Document', 'Document', 'Microsoft Word',
      'BASIC WORDPROCESSOR MAILMERGE FORM'),
  ('Word.Document.8', 'Microsoft Word 97 - 2003 Document', 'Document',
      'Microsoft Word 97 - 2003', 'BASIC WORDPROCESSOR MAILMERGE FORM'),
];

/// The answer to the Office manager's GetRegisteredProgIDs result pull:
/// [officeRegisteredProgIds] laid out by the pushed table's FORMAT
/// ([pushSeg]: six C columns 70 / 70 / 20 / 50 / 256 / 1), in the DOI
/// upload envelope (TOTALSIZE 0, as gui[144]). Null when the push declares
/// no FORMAT.
Uint8List? registeredProgIdsAnswer(Uint8List requestV, Uint8List pushSeg) {
  final (_, (fw, fn), fcells) = dpColumnCells(pushSeg, 'FORMAT');
  final fb = BytesBuilder(copy: false);
  for (final c in fcells) {
    fb.add(c);
  }
  final f = fb.takeBytes();
  final w = fw > 0 ? fw : cat80;
  final records = [
    for (var i = 0; (i + 1) * w <= f.length && (fn <= 0 || i < fn); i++)
      Uint8List.sublistView(f, i * w, (i + 1) * w),
  ];
  if (records.isEmpty || records.any((r) => r.length < _fmtRecMin)) {
    return null;
  }
  final names = [
    for (final r in records) String.fromCharCodes(r, 30, 60).trim().toUpperCase(),
  ];
  final rows = [
    for (final (a, b, c, d, e) in officeRegisteredProgIds)
      {
        for (final (k, v) in [a, b, c, d, e, ''].indexed)
          if (k < names.length) names[k]: v,
      },
  ];
  return doiTableAnswer(requestV, layoutRowsByFormat(records, rows),
      formatRecords: records);
}

/// The save-back document pull's verdict: true = ours, the bytes held;
/// null = ours but REFUSED (no bytes the server sent, an unrecorded
/// kind); false = not a document pull.
bool? doiDocumentPullVerdict(DoiState st, Uint8List value) {
  if (!containsBytes(value, 'DP_GET')) return false;
  final inurl = dpgetInurl(value);
  if (inurl == null) return false;
  final url = st.docSinks[inurl];
  if (url == null) return false;
  if (st.docErrors.containsKey(url)) return null;
  return st.docBytes.containsKey(url) && st.docShapes.containsKey(url);
}

/// The RFC reply of the save-back document pull. Held: the document AS THE
/// SERVER SENT IT in the real GUI's upload envelope (a recorded session
/// gui[28] / gui[117], a recorded session gui[20]): TYPE
/// `application`, SUBTYPE and DATABIN width by kind ([uploadShapeOf]:
/// `x-ole-document` / `msword`, 1022 or 256), the client DATE (MM/DD/YY) /
/// TIME (its 7-char cut of HH:MM:SS), TOTALSIZE u32 LE = the document's
/// length, DATABIN one LZH cell of the records padded with blanks, empty
/// FORMAT / PROPS, the `06 67` trailer. Refused: the front end's RFC
/// exception reply `RFC_FUNCTION_NOT_FOUND` — the one refusal envelope on
/// record (a recorded session gui[14]; a document-pull refusal is
/// not recorded, G3): the ABAP gets a clean exception, never a hang (the
/// pull is synchronous) and never an empty or foreign document stored over
/// its own. Null when the pull is not a document save-back.
Uint8List? doiAnswerDocumentPullRfc(DoiState st, Uint8List value,
    {DateTime? now}) {
  final verdict = doiDocumentPullVerdict(st, value);
  if (verdict == null) return buildFrontendExceptionReply();
  if (verdict != true) return null;
  final inurl = dpgetInurl(value)!;
  final url = st.docSinks[inurl]!;
  final data = st.docBytes[url]!;
  final (subtype, w) = st.docShapes[url]!;
  final n = data.isEmpty ? 0 : (data.length + w - 1) ~/ w;
  final padded = Uint8List(n * w)..fillRange(0, n * w, 0x20);
  padded.setRange(0, data.length, data);
  final table = BytesBuilder(copy: false)
    ..add(_tok('DATABIN'))
    ..add(_dims(w, n));
  if (n > 0) {
    table
      ..add(wrap0305Cell(lzhCompress(padded)))
      ..add(cellTableClose);
  }
  table
    ..add(_tok('FORMAT'))
    ..add(_dims(80, 0))
    ..add(_tok('PROPS'))
    ..add(_dims(80, 0));
  final t = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final scalars = <String, String>{
    'TYPE': 'application',
    'SUBTYPE': subtype,
    'DATE': '${two(t.month)}/${two(t.day)}/${two(t.year % 100)}',
    'TIME': '${two(t.hour)}:${two(t.minute)}:${two(t.second)}'.substring(0, 7),
    'DESCRIPTION': '',
    'TOTALSIZE': _leU32Str(data.length),
    'PLATTFORM': '',
  };
  return buildDpAnswer(scalars: scalars, tableRegion: table.takeBytes());
}

String _leU32Str(int v) => String.fromCharCodes([
      v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff,
    ]);

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call.
final RegExp _digitsOnlyRx = RegExp(r'^\d{1,9}$');
final RegExp _docForSourceRx = RegExp(r'^doc(\d+)$');
final RegExp _dpgetInurlRx = RegExp('SAPR3://[0-9A-Fa-f]+');
