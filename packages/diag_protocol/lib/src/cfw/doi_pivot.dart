/// The pivot table XXL's PIVOT proxy has Excel build: `InsertFull2(<data
/// titles>, <key titles>, <header>, <roles>, <source sheet>, <data rows>,
/// <data columns>, <key columns>)` on the proxy `GetDocumentProxyInterface
/// (1, 'PIVOT')` returned (`SAP.OfficeIntegration.Excel97Proxy.1`'s
/// ISAPOfficeIntegrationPivot, SAPoipe8.OCX) — the real SAP GUI for Windows
/// with Office 16, a recorded session srv[57] -> gui[48] (t8 `''`):
/// * #1: the data fields' titles (`Sales` … `Net Profit`), #2: the key
/// fields' titles (`Services` … `Year`) — ROW / COL / VALUE records;
/// * #3: the report header block (`Report-Type` = `Central`, …);
/// * #4: per source column its type and role (`STR`/`DFT` for the 4 keys,
/// `NUM`/`ADD` for the 5 data columns);
/// * #5 the source sheet (`Feuil1`, GetActiveSheet's answer), #6..#8 the
/// data rows / data columns / key columns (60 / 5 / 4).
/// The OCX builds the pivot through Excel's object model (PivotCaches.Add /
/// CreatePivotTable) — nothing of it is on the wire, and no screenshot is
/// on record (the operator reports it on `Feuil2`, the flat table on
/// `Feuil1`). Modelled as Excel's new worksheet before the source, active:
/// the header block, then a row per key combination (sorted) with the sums
/// of the data fields (`ADD`), and the grand total. A model of what the
/// pivot holds, not Excel's exact layout.
library;

import 'dart:math' show min;

import 'doi.dart' show Document;

/// Excel's (French Office 16) label of a summed data field and of the
/// grand total row.
const String pivotSumLabel = 'Somme de';
const String pivotGrandTotal = 'Total général';

/// Builds [doc]'s pivot sheet from the InsertFull2 tables: [dataTitles] /
/// [keyTitles] (records `row, col, title`), [header] (records `seq, name,
/// value`), [roles] (records `seq, type, role, …`), over [source]'s cells
/// (its header row: the one whose first cell is the first key title, the
/// data the [dataRows] rows below it). Returns the new sheet's name, null
/// when the tables hold nothing to summarize.
String? applyInsertFull2(
  Document doc, {
  required List<List<String>> dataTitles,
  required List<List<String>> keyTitles,
  required List<List<String>> header,
  required List<List<String>> roles,
  required String source,
  required int dataRows,
  required int dataCols,
  required int keyCols,
}) {
  String title(List<String> r) =>
      r.length >= 3 ? r[2] : (r.isEmpty ? '' : r.last);
  final keys = [for (final r in keyTitles) title(r)];
  final data = [for (final r in dataTitles) title(r)];
  // the wire's column counts clamped to a sheet's width: unbounded, one
  // InsertFull2 ran a billion-iteration key loop and a 16 GB sum list
  // (audit 2026-10-17 P0-6)
  final nKeys = min(keyCols > 0 ? keyCols : keys.length, Document.maxRangeCols);
  final nData = min(dataCols > 0 ? dataCols : data.length, Document.maxRangeCols);
  if (nKeys <= 0 || nData <= 0 || dataRows <= 0) return null;
  final src = source.trim().isEmpty ? doc.activeSheet : source.trim();
  final cells = doc.sheets[src];
  if (cells == null) return null;
  // the source's header row: where the first key title stands in column 1
  var head = 1;
  if (keys.isNotEmpty) {
    for (var r = 1; r <= 16; r++) {
      if (doc.cell(r, 1, src) == keys.first) {
        head = r;
        break;
      }
    }
  }
  // rows read: as many as the range-cell budget allows over this width
  final cap = min(
    min(dataRows, Document.maxRangeRows),
    Document.maxRangeCells ~/ (nKeys + nData),
  );
  // the roles: a data column is summed unless its role says otherwise
  // (only ADD is on record)
  final groups = <String, (List<String>, List<num>)>{};
  for (var r = head + 1; r <= head + cap; r++) {
    final k = [for (var c = 1; c <= nKeys; c++) doc.cell(r, c, src)];
    if (k.every((v) => v.isEmpty)) continue;
    final g = groups.putIfAbsent(
      k.join('\u0000'),
      () => (k, List<num>.filled(nData, 0)),
    );
    for (var c = 0; c < nData; c++) {
      final v = doc.valueAt(r, nKeys + 1 + c, src);
      if (v is num) g.$2[c] += v;
    }
  }
  if (groups.isEmpty) return null;
  final rows = groups.values.toList()
    ..sort((a, b) {
      for (var i = 0; i < a.$1.length; i++) {
        final c = a.$1[i].compareTo(b.$1[i]);
        if (c != 0) return c;
      }
      return 0;
    });
  final name = _newSheetName(doc);
  // Excel's new worksheet goes before the active one and becomes active
  final before = Map.of(doc.sheets);
  doc.sheets
    ..clear()
    ..[name] = {};
  for (final e in before.entries) {
    doc.sheets[e.key] = e.value;
  }
  var row = 1;
  for (final h in header) {
    if (h.length < 3 || (h[1].isEmpty && h[2].isEmpty)) continue;
    doc.setCell(row, 1, h[1], name);
    doc.setCell(row, 2, h[2], name);
    row++;
  }
  if (row > 1) row++; // a blank row under the header block
  for (var c = 0; c < nKeys; c++) {
    doc.setCell(row, c + 1, c < keys.length ? keys[c] : '', name);
  }
  for (var c = 0; c < nData; c++) {
    final t = c < data.length ? data[c] : '';
    final role = nKeys + c < roles.length && roles[nKeys + c].length > 2
        ? roles[nKeys + c][2]
        : 'ADD';
    if (role != 'ADD') doc.notes.add('pivot: data role $role summed');
    doc.setCell(row, nKeys + 1 + c, '$pivotSumLabel $t', name);
  }
  final total = List<num>.filled(nData, 0);
  for (final (k, sums) in rows) {
    row++;
    for (var c = 0; c < nKeys; c++) {
      doc.setCell(row, c + 1, k[c], name);
    }
    for (var c = 0; c < nData; c++) {
      doc.setNumber(row, nKeys + 1 + c, _round(sums[c]), name);
      total[c] += sums[c];
    }
  }
  row++;
  doc.setCell(row, 1, pivotGrandTotal, name);
  for (var c = 0; c < nData; c++) {
    doc.setNumber(row, nKeys + 1 + c, _round(total[c]), name);
  }
  doc.activeSheet = name;
  doc.version++;
  return name;
}

/// The next free `FeuilN` (the French Office's new-sheet name).
String _newSheetName(Document doc) {
  for (var n = doc.sheets.length + 1; ; n++) {
    final s = 'Feuil$n';
    if (!doc.sheets.containsKey(s)) return s;
  }
}

/// A sum of 2-decimal values without the binary noise (`0.1 + 0.2`).
num _round(num v) {
  final r = (v * 1e6).round() / 1e6;
  return r == r.roundToDouble() && r.abs() < 1e15 ? r.toInt() : r;
}
