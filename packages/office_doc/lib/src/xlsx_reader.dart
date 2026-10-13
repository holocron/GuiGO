/// An .xlsx (SpreadsheetML) reader: sheets in workbook order, cell values
/// (shared / inline strings, numbers, booleans, errors, formulas as their
/// cached value), date-formatted numbers shown as dates, column widths,
/// merged cells.
library;

import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'ooxml.dart';
import 'workbook.dart';
import 'zip.dart';

/// Reads the .xlsx package [bytes]; at most [maxCells] cells per sheet are
/// kept (the rest of a huge sheet is dropped).
Workbook readXlsx(Uint8List bytes, {int maxCells = 500000}) =>
    readXlsxFrom(ZipReader(bytes), maxCells: maxCells);

Workbook readXlsxFrom(ZipReader zip, {int maxCells = 500000}) {
  final main = mainPartOf(zip, 'xl/workbook.xml');
  final wb = parseXmlPart(zip.readText(main));
  if (wb == null) throw const FormatException('no readable xl/workbook.xml');
  final rels = {
    for (final (id, _, path) in relationshipsOf(zip, main)) id: path,
  };
  final shared = _sharedStrings(
    zip,
    relatedPart(zip, main, '/sharedStrings') ?? 'xl/sharedStrings.xml',
  );
  final dates = _dateStyles(
    parseXmlPart(
      zip.readText(relatedPart(zip, main, '/styles') ?? 'xl/styles.xml'),
    ),
  );
  var date1904 = false;
  var active = 0;
  final sheets = <Worksheet>[];
  for (final e in wb.rootElement.descendantElements) {
    switch (e.name.local) {
      case 'workbookPr':
        date1904 = _truthy(attr(e, 'date1904'));
      case 'workbookView':
        active = int.tryParse(attr(e, 'activeTab') ?? '') ?? active;
      case 'sheet':
        final name = attr(e, 'name') ?? 'Sheet${sheets.length + 1}';
        final id = attr(e, 'id');
        final path = id == null ? null : rels[id];
        final hidden =
            attr(e, 'state') == 'hidden' || attr(e, 'state') == 'veryHidden';
        final x = path == null ? null : parseXmlPart(zip.readText(path));
        sheets.add(
          x == null
              ? Worksheet(name, hidden: hidden)
              : _sheet(name, x, shared, dates, date1904, hidden, maxCells),
        );
    }
  }
  return Workbook(
    sheets,
    activeSheet: active.clamp(0, sheets.isEmpty ? 0 : sheets.length - 1),
    title: coreTitle(zip),
  );
}

bool _truthy(String? v) => v == '1' || v == 'true';

List<String> _sharedStrings(ZipReader zip, String path) {
  final x = parseXmlPart(zip.readText(path));
  if (x == null) return const [];
  return [
    for (final si in x.rootElement.childElements)
      if (si.name.local == 'si') _richText(si),
  ];
}

/// An `<si>` / `<is>`: its `<t>` texts, phonetic runs (`rPh`) skipped.
String _richText(XmlElement e) {
  final b = StringBuffer();
  void walk(XmlElement x) {
    for (final c in x.childElements) {
      switch (c.name.local) {
        case 't':
          b.write(c.innerText);
        case 'r':
          walk(c);
      }
    }
  }

  walk(e);
  return b.toString();
}

/// The cellXfs indices whose number format is a date / time.
Set<int> _dateStyles(XmlDocument? styles) {
  if (styles == null) return const {};
  final custom = <int, String>{};
  for (final f in styles.findAllElements('numFmt', namespace: '*')) {
    final id = int.tryParse(attr(f, 'numFmtId') ?? '');
    if (id != null) custom[id] = attr(f, 'formatCode') ?? '';
  }
  final out = <int>{};
  final xfs = styles.findAllElements('cellXfs', namespace: '*').firstOrNull;
  if (xfs == null) return out;
  var i = 0;
  for (final xf in xfs.childElements) {
    if (xf.name.local != 'xf') continue;
    final id = int.tryParse(attr(xf, 'numFmtId') ?? '') ?? 0;
    if (_isDateFormat(id, custom[id])) out.add(i);
    i++;
  }
  return out;
}

bool _isDateFormat(int id, String? code) {
  if ((id >= 14 && id <= 22) ||
      (id >= 27 && id <= 36) ||
      (id >= 45 && id <= 47) ||
      (id >= 50 && id <= 58)) {
    return true;
  }
  if (code == null) return false;
  final bare = code
      .replaceAll(RegExp(r'"[^"]*"'), '')
      .replaceAll(RegExp(r'\[[^\]]*\]'), '')
      .replaceAll(RegExp(r'\\.'), '')
      .toLowerCase();
  return RegExp(r'[ydhs]').hasMatch(bare) ||
      (bare.contains('m') && !RegExp(r'[0#]').hasMatch(bare));
}

Worksheet _sheet(
  String name,
  XmlDocument x,
  List<String> shared,
  Set<int> dates,
  bool date1904,
  bool hidden,
  int maxCells,
) {
  final cells = <(int, int), SheetCell>{};
  final widths = <int, double>{};
  final merged = <CellRange>[];
  double? defaultWidth;
  final root = x.rootElement;
  for (final e in root.childElements) {
    switch (e.name.local) {
      case 'sheetFormatPr':
        defaultWidth = double.tryParse(attr(e, 'defaultColWidth') ?? '');
      case 'cols':
        for (final c in children(e, 'col')) {
          final min = int.tryParse(attr(c, 'min') ?? '');
          final max = int.tryParse(attr(c, 'max') ?? '');
          final w = double.tryParse(attr(c, 'width') ?? '');
          if (min == null || max == null || w == null) continue;
          final hiddenCol = _truthy(attr(c, 'hidden'));
          // a <col> spanning to 16384 styles the rest of the sheet: keep
          // the widths of the first 256 columns only
          for (var k = min; k <= max && k <= 256; k++) {
            widths[k] = hiddenCol ? 0 : w;
          }
        }
      case 'sheetData':
        var rowNo = 0;
        for (final row in children(e, 'row')) {
          rowNo = int.tryParse(attr(row, 'r') ?? '') ?? rowNo + 1;
          var colNo = 0;
          for (final c in children(row, 'c')) {
            final ref = attr(c, 'r');
            colNo = (ref == null ? null : columnOfRef(ref)) ?? colNo + 1;
            if (cells.length >= maxCells) break;
            final cell = _cell(c, shared, dates, date1904);
            if (cell != null) cells[(rowNo, colNo)] = cell;
          }
        }
      case 'mergeCells':
        for (final m in children(e, 'mergeCell')) {
          final r = CellRange.parse(attr(m, 'ref') ?? '');
          if (r != null && (r.rows > 1 || r.cols > 1)) merged.add(r);
        }
    }
  }
  return Worksheet(
    name,
    cells: cells,
    columnWidths: widths,
    merged: merged,
    defaultColumnWidth: defaultWidth,
    hidden: hidden,
  );
}

SheetCell? _cell(
  XmlElement c,
  List<String> shared,
  Set<int> dates,
  bool date1904,
) {
  final t = attr(c, 't') ?? 'n';
  final v = child(c, 'v')?.innerText;
  final f = child(c, 'f')?.innerText;
  final formula = f == null || f.isEmpty ? null : f;
  switch (t) {
    case 's':
      final i = int.tryParse(v ?? '');
      if (i == null || i < 0 || i >= shared.length) return null;
      return SheetCell(shared[i], formula: formula);
    case 'inlineStr':
      final is_ = child(c, 'is');
      return SheetCell(is_ == null ? '' : _richText(is_), formula: formula);
    case 'str':
      return SheetCell(v ?? '', formula: formula);
    case 'b':
      return SheetCell(
        v == '1' ? 'TRUE' : 'FALSE',
        kind: CellKind.boolean,
        number: v == '1' ? 1 : 0,
        formula: formula,
      );
    case 'e':
      return SheetCell(v ?? '#N/A', kind: CellKind.error, formula: formula);
    default:
      if (v == null || v.isEmpty) {
        return formula == null ? null : SheetCell('', formula: formula);
      }
      final n = num.tryParse(v);
      if (n == null) return SheetCell(v, formula: formula);
      final style = int.tryParse(attr(c, 's') ?? '') ?? 0;
      if (dates.contains(style)) {
        return SheetCell(
          excelDateText(n, date1904: date1904),
          kind: CellKind.date,
          number: n,
          formula: formula,
        );
      }
      return SheetCell(
        numberText(n),
        kind: CellKind.number,
        number: n,
        formula: formula,
      );
  }
}

/// [n] as Excel's General format would show it, roughly: integers without
/// a fraction, others in their shortest round-trip form.
String numberText(num n) {
  if (n is int) return '$n';
  if (n.isFinite && n == n.roundToDouble() && n.abs() < 1e15) {
    return n.toInt().toString();
  }
  final s = n.toString();
  return s;
}

/// An Excel date serial as `yyyy-mm-dd` (plus ` hh:mm[:ss]` when it has a
/// time part).
String excelDateText(num serial, {bool date1904 = false}) {
  final base = date1904 ? DateTime.utc(1904, 1, 1) : DateTime.utc(1899, 12, 30);
  final ms = (serial * 86400000).round();
  final d = base.add(Duration(milliseconds: ms));
  String two(int v) => v.toString().padLeft(2, '0');
  final date =
      '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
  if (ms % 86400000 == 0) return date;
  final sec = d.second == 0 ? '' : ':${two(d.second)}';
  if (serial.abs() < 1) return '${two(d.hour)}:${two(d.minute)}$sec';
  return '$date ${two(d.hour)}:${two(d.minute)}$sec';
}
