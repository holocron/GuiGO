/// A minimal .xlsx writer: one worksheet per [Worksheet], numbers as
/// numbers, booleans as booleans, everything else through the shared
/// string table; formulas with their cached value; column widths; merged
/// cells. The package has the parts Excel, Numbers and LibreOffice expect
/// (content types, relationships, workbook, styles, shared strings, core
/// properties).
library;

import 'dart:typed_data';

import 'ooxml.dart';
import 'workbook.dart';
import 'zip.dart';

const _xmlHead = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';
const _nsMain = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const _nsRel =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

/// Serialises [book] as an .xlsx package.
Uint8List writeXlsx(Workbook book) {
  final sheets = book.sheets.isEmpty ? [Worksheet('Sheet1')] : book.sheets;
  final names = sheetNames([for (final s in sheets) s.name]);
  final strings = <String>[];
  final stringIndex = <String, int>{};
  int sst(String s) =>
      stringIndex.putIfAbsent(s, () => (strings..add(s)).length - 1);

  final zip = ZipWriter();
  zip.addText('[Content_Types].xml', _contentTypes(sheets.length));
  zip.addText(
    '_rels/.rels',
    '$_xmlHead<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="$_nsRel/officeDocument" Target="xl/workbook.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '<Relationship Id="rId3" Type="$_nsRel/extended-properties" Target="docProps/app.xml"/>'
        '</Relationships>',
  );
  zip.addText('docProps/core.xml', corePropsXml(book.title));
  zip.addText(
    'docProps/app.xml',
    '$_xmlHead<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
        '<Application>GuiGo</Application></Properties>',
  );
  final active = book.activeSheet.clamp(0, sheets.length - 1);
  final wb = StringBuffer(
    '$_xmlHead<workbook xmlns="$_nsMain" xmlns:r="$_nsRel">'
    '<bookViews><workbookView activeTab="$active"/></bookViews><sheets>',
  );
  for (var i = 0; i < sheets.length; i++) {
    final state = sheets[i].hidden && i != active ? ' state="hidden"' : '';
    wb.write(
      '<sheet name="${xmlEscape(names[i])}" sheetId="${i + 1}"$state r:id="rId${i + 1}"/>',
    );
  }
  wb.write('</sheets></workbook>');
  zip.addText('xl/workbook.xml', wb.toString());

  final wbRels = StringBuffer(
    '$_xmlHead<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
  );
  for (var i = 0; i < sheets.length; i++) {
    wbRels.write(
      '<Relationship Id="rId${i + 1}" Type="$_nsRel/worksheet" Target="worksheets/sheet${i + 1}.xml"/>',
    );
  }
  final n = sheets.length;
  wbRels.write(
    '<Relationship Id="rId${n + 1}" Type="$_nsRel/styles" Target="styles.xml"/>'
    '<Relationship Id="rId${n + 2}" Type="$_nsRel/sharedStrings" Target="sharedStrings.xml"/>'
    '</Relationships>',
  );
  zip.addText('xl/_rels/workbook.xml.rels', wbRels.toString());

  for (var i = 0; i < sheets.length; i++) {
    zip.addText(
      'xl/worksheets/sheet${i + 1}.xml',
      _sheetXml(sheets[i], sst, selected: i == active),
    );
  }

  final ss = StringBuffer(
    '$_xmlHead<sst xmlns="$_nsMain" count="${strings.length}" uniqueCount="${strings.length}">',
  );
  for (final s in strings) {
    final keep = s != s.trim() || s.contains('\n')
        ? ' xml:space="preserve"'
        : '';
    ss.write('<si><t$keep>${xmlEscape(s)}</t></si>');
  }
  ss.write('</sst>');
  zip.addText('xl/sharedStrings.xml', ss.toString());
  zip.addText('xl/styles.xml', _styles);
  return zip.finish();
}

String _contentTypes(int sheets) {
  final b = StringBuffer(
    '$_xmlHead<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
  );
  for (var i = 1; i <= sheets; i++) {
    b.write(
      '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
    );
  }
  b.write(
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
    '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
    '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
    '</Types>',
  );
  return b.toString();
}

// one font, the mandatory two fills, one border; xf 0 General, xf 1 a date
const _styles =
    '$_xmlHead<styleSheet xmlns="$_nsMain">'
    '<fonts count="1"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>'
    '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    '<xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>'
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
    '</styleSheet>';

String _sheetXml(
  Worksheet s,
  int Function(String) sst, {
  required bool selected,
}) {
  final rows = s.rowCount, cols = s.colCount;
  final b = StringBuffer(
    '$_xmlHead<worksheet xmlns="$_nsMain" xmlns:r="$_nsRel">',
  );
  b.write(
    '<dimension ref="${rows == 0 || cols == 0 ? 'A1' : CellRange(1, 1, rows, cols).ref}"/>',
  );
  b.write(
    '<sheetViews><sheetView workbookViewId="0"${selected ? ' tabSelected="1"' : ''}/></sheetViews>',
  );
  b.write(
    '<sheetFormatPr defaultRowHeight="15"'
    '${s.defaultColumnWidth == null ? '' : ' defaultColWidth="${s.defaultColumnWidth}"'}/>',
  );
  final widths =
      s.columnWidths.entries.where((e) => e.key >= 1 && e.key <= 16384).toList()
        ..sort((a, b) => a.key.compareTo(b.key));
  if (widths.isNotEmpty) {
    b.write('<cols>');
    for (final w in widths) {
      final hidden = w.value <= 0;
      b.write(
        '<col min="${w.key}" max="${w.key}" width="${hidden ? 0 : _num(w.value)}"'
        ' customWidth="1"${hidden ? ' hidden="1"' : ''}/>',
      );
    }
    b.write('</cols>');
  }
  b.write('<sheetData>');
  final byRow = <int, List<(int, SheetCell)>>{};
  for (final e in s.cells.entries) {
    final (r, c) = e.key;
    if (r < 1 || c < 1 || r > 1048576 || c > 16384) continue;
    byRow.putIfAbsent(r, () => []).add((c, e.value));
  }
  for (final r in byRow.keys.toList()..sort()) {
    final cells = byRow[r]!..sort((a, b) => a.$1.compareTo(b.$1));
    b.write('<row r="$r">');
    for (final (c, cell) in cells) {
      final ref = cellRef(r, c);
      final f = cell.formula == null
          ? ''
          : '<f>${xmlEscape(cell.formula!.startsWith('=') ? cell.formula!.substring(1) : cell.formula!)}</f>';
      final n = cell.number;
      switch (cell.kind) {
        case CellKind.number when n != null && n.isFinite:
          b.write('<c r="$ref">$f<v>${_num(n)}</v></c>');
        case CellKind.date when n != null && n.isFinite:
          b.write('<c r="$ref" s="1">$f<v>${_num(n)}</v></c>');
        case CellKind.boolean:
          b.write('<c r="$ref" t="b">$f<v>${(n ?? 0) != 0 ? 1 : 0}</v></c>');
        case CellKind.error:
          b.write('<c r="$ref" t="e">$f<v>${xmlEscape(cell.text)}</v></c>');
        default:
          if (cell.text.isEmpty && f.isEmpty) continue;
          if (f.isNotEmpty) {
            b.write('<c r="$ref" t="str">$f<v>${xmlEscape(cell.text)}</v></c>');
          } else {
            b.write('<c r="$ref" t="s"><v>${sst(cell.text)}</v></c>');
          }
      }
    }
    b.write('</row>');
  }
  b.write('</sheetData>');
  final merges = [
    for (final m in s.merged)
      if (m.rows > 1 || m.cols > 1) m,
  ];
  if (merges.isNotEmpty) {
    b.write('<mergeCells count="${merges.length}">');
    for (final m in merges) {
      b.write('<mergeCell ref="${m.ref}"/>');
    }
    b.write('</mergeCells>');
  }
  b.write(
    '<pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>',
  );
  b.write('</worksheet>');
  return b.toString();
}

String _num(num n) {
  if (n is int) return '$n';
  if (n == n.roundToDouble() && n.abs() < 1e15) return n.toInt().toString();
  return n.toString();
}

/// Valid, unique Excel sheet names for [names]: at most 31 characters,
/// none of `[]:*?/\`, not empty, not starting / ending with `'`; a
/// duplicate (case-insensitive) gets ` (2)`, ` (3)` ….
List<String> sheetNames(List<String> names) {
  final seen = <String>{};
  final out = <String>[];
  for (var i = 0; i < names.length; i++) {
    var n = names[i]
        .replaceAll(RegExp(r'[\[\]:*?/\\\x00-\x1f]'), '_')
        .trim()
        .replaceAll(RegExp(r"^'+|'+$"), '');
    if (n.isEmpty || n.toLowerCase() == 'history') n = 'Sheet${i + 1}';
    if (n.length > 31) n = n.substring(0, 31);
    var cand = n;
    var k = 2;
    while (!seen.add(cand.toLowerCase())) {
      final suffix = ' (${k++})';
      cand =
          (n.length + suffix.length > 31
              ? n.substring(0, 31 - suffix.length)
              : n) +
          suffix;
    }
    out.add(cand);
  }
  return out;
}
