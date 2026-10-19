/// The ALV grid's in-place Excel view ("Excel intégré", CL_SALV_GRU_VIEW_
/// EXCEL): the spreadsheet proxy of the template the server opened
/// in the grid's own docking container gets the ALV's own tables —
/// `SetDataTable(<LVC_T_DATA>)` then `SetInfoTable(<LVC_T_INFO>)`,
/// `SetFixedCols(n)`, `SetLocale(1, '')`, `UpdateFrontend` (the real SAP
/// GUI for Windows with Office 16, a recorded session srv[55]
/// -[58]; SAPoipe8.OCX renders them into the template's sheet — nothing of
/// that is on the wire, and no screenshot is on record):
/// * the data table, a 17-column X-R3TABLE of LVC_S_DATA cells (`COL_POS`,
/// `ROW_POS`, `STYLE`, `VALUE` C128, …): one record per cell, `COL_POS
/// -1` the row-id cell (srv[55]: 272 records = 4 rows x (67 + 1));
/// * the info table, the 26-column field catalog LVC_S_INFO (`FIELDNAME`,
/// `HIERLEVEL`, `COL_POS`, `TEXT`, …, `INTTYPE`, …, `REPTEXT`) — one row
/// per OUTPUT column (the structure has no NO_OUT: the catalog the view
/// hands the frontend is already the displayed one; srv[56]: 67 rows).
/// Modelled as the sheet Excel shows: the catalog's column texts as the
/// header row, in catalog order, then one row per data row, a cell of a
/// numeric INTTYPE (`P`, `I`, `F`, `b`, `s`, `8`, `a`, `e`) typed as a
/// number. A model of what the sheet holds, not the template's styling.
library;

import 'dart:typed_data';

import '../screen/sap_tree.dart' show DpTable, decodeNamedDpTable;
import 'doi.dart' show Document;

/// LVC_S_INFO field positions (0-based, its 26-field FORMAT).
const int _infoName = 0, _infoColPos = 2, _infoText = 3, _infoIntType = 12;
const int _infoTextM = 14, _infoTextS = 15, _infoRepText = 16;
const int _infoColId = 17;

/// LVC_S_DATA field positions (0-based, its 17-field FORMAT).
const int _dataColPos = 0, _dataRowPos = 1, _dataValue = 3;

/// The ABAP internal types Excel receives as numbers.
const Set<String> alvNumericIntTypes = {'P', 'I', 'F', 'b', 's', '8', 'a', 'e'};

/// The ALV tables a spreadsheet proxy received, as pushed.
class AlvSheetTables {
  Uint8List? data;
  Uint8List? info;
}

final Expando<AlvSheetTables> _alvTables = Expando('alv sheet tables');

/// The field name and catalog column id (LVC_S_INFO `COL_ID`) of the
/// sheet's column [col] (1-based, the output columns in catalog order),
/// ('', '') when [doc] holds no ALV catalog or no such column.
(String, String) alvColumnAt(Document doc, int col) {
  final seg = _alvTables[doc]?.info;
  final t = seg == null ? null : decodeNamedDpTable(seg);
  if (t == null || t.columns.length <= _infoColId) return ('', '');
  var k = 0;
  for (final r in t.rows) {
    final pos = int.tryParse(_f(t, r, _infoColPos));
    if (pos == null || pos <= 0) continue;
    if (++k == col) return (_f(t, r, _infoName), _f(t, r, _infoColId));
  }
  return ('', '');
}

/// Fold `SetDataTable` ([isInfo] false) / `SetInfoTable` push [seg] into
/// [doc] and, once both arrived, rebuild its active sheet from them.
/// Returns whether the sheet was (re)built.
bool applyAlvTable(Document doc, Uint8List seg, {required bool isInfo}) {
  final t = _alvTables[doc] ??= AlvSheetTables();
  if (isInfo) {
    t.info = seg;
  } else {
    t.data = seg;
  }
  final data = t.data, info = t.info;
  if (data == null || info == null) return false;
  final dt = decodeNamedDpTable(data), it = decodeNamedDpTable(info);
  if (dt == null || it == null) return false;
  return _build(doc, dt, it);
}

String _f(DpTable t, Map<String, String> row, int i) =>
    i < t.columns.length ? (row[t.columns[i]] ?? '').trim() : '';

bool _build(Document doc, DpTable data, DpTable info) {
  if (info.columns.length <= _infoIntType ||
      data.columns.length <= _dataValue) {
    return false;
  }
  // the output columns in catalog order: COL_POS -> (sheet column, type)
  final cols = <int, (int, String)>{};
  final headers = <String>[];
  for (final r in info.rows) {
    final pos = int.tryParse(_f(info, r, _infoColPos));
    if (pos == null || pos <= 0 || cols.containsKey(pos)) continue;
    final header = [
      _f(info, r, _infoText),
      _f(info, r, _infoRepText),
      _f(info, r, _infoTextM),
      _f(info, r, _infoTextS),
      _f(info, r, _infoName),
    ].firstWhere((s) => s.isNotEmpty, orElse: () => '');
    headers.add(header);
    cols[pos] = (headers.length, _f(info, r, _infoIntType));
  }
  if (cols.isEmpty) return false;
  final sheet = doc.activeSheet;
  doc.sheets[sheet] = {};
  doc.numbers.remove(sheet);
  for (var c = 0; c < headers.length; c++) {
    doc.setCell(1, c + 1, headers[c], sheet);
  }
  for (final r in data.rows) {
    final col = cols[int.tryParse(_f(data, r, _dataColPos)) ?? 0];
    final row = int.tryParse(_f(data, r, _dataRowPos)) ?? 0;
    if (col == null || row <= 0) continue; // the row-id cell (-1), …
    final (c, type) = col;
    final text = (r[data.columns[_dataValue]] ?? '').trim();
    if (text.isEmpty) continue;
    final n = alvNumericIntTypes.contains(type) ? alvNumber(text) : null;
    if (n != null) {
      doc.setNumber(row + 1, c, n, sheet);
    } else {
      doc.setCell(row + 1, c, text, sheet);
    }
  }
  return true;
}

// Hoisted: [alvNumber] runs per numeric cell of every in-place sheet; a
// RegExp built per call is compiled per call (audit 2026-10-17 N1).
// The blanks: whitespace, NBSP and the narrow NBSP of a French grouping.
final RegExp _alvBlankRx = RegExp(r'[\s  ]');
final RegExp _alvDecimalRx = RegExp(r'^\d+(\.\d+)?$');

/// An ALV cell's number: `1234`, `-5`, `5-` (ABAP's trailing sign),
/// `1.234,56` / `1,234.56` / `1 234,56` (the user's format: the last
/// separator is the decimal one when both occur), else null.
num? alvNumber(String text) {
  var s = text.replaceAll(_alvBlankRx, '');
  var neg = false;
  if (s.endsWith('-')) {
    neg = true;
    s = s.substring(0, s.length - 1);
  } else if (s.startsWith('-')) {
    neg = true;
    s = s.substring(1);
  }
  if (s.isEmpty) return null;
  final dot = s.lastIndexOf('.'), comma = s.lastIndexOf(',');
  if (dot >= 0 && comma >= 0) {
    final dec = dot > comma ? '.' : ',';
    final grp = dec == '.' ? ',' : '.';
    s = s.replaceAll(grp, '').replaceAll(dec, '.');
  } else if (comma >= 0) {
    // one comma = the decimal comma; several = thousands groups
    s = ','.allMatches(s).length == 1
        ? s.replaceAll(',', '.')
        : s.replaceAll(',', '');
  }
  if (!_alvDecimalRx.hasMatch(s)) return null;
  final v = num.parse(s);
  final n = v == v.roundToDouble() && v.abs() < 1e15 ? v.toInt() : v;
  return neg ? -n : n;
}
