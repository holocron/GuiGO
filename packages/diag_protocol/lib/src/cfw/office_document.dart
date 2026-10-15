/// The Office document a DOI container holds, as the screen shows it
/// (SAP.DocumentContainerControl.1 — doi.dart's headless Office): what the
/// server sent, never a re-serialisation of ours.
library;

import 'dart:typed_data';

import 'doi.dart' show Document;
import 'doi_chart.dart';

/// The Office family of a DOI document, by the ProgID the server opened.
enum OfficeDocKind { word, excel, other }

/// [progId]'s family: `Word.*` / `Excel.*` (case-insensitive), else other
/// (`PDFXMLDesigner.Document`, PowerPoint, …).
OfficeDocKind officeKindOf(String progId) {
  final c = progId.trim().toLowerCase();
  if (c.startsWith('word.')) return OfficeDocKind.word;
  if (c.startsWith('excel.')) return OfficeDocKind.excel;
  return OfficeDocKind.other;
}

/// One live document of a DOI container control.
class SapOfficeDocument {
  const SapOfficeDocument({
    required this.shell,
    required this.progId,
    required this.kind,
    required this.format,
    this.bytes,
    required this.fileExtension,
    this.readOnly = false,
    this.sheet,
    this.version = 0,
  });

  /// The CFW shell of the DOI container control
  /// (SAP.DocumentContainerControl.1) the document is open in.
  final String shell;

  /// The document class the server opened (`Word.Document.12`,
  /// `Excel.Sheet.8`, `Excel.Chart`, `PDFXMLDesigner.Document`, …).
  final String progId;

  final OfficeDocKind kind;

  /// The format the document was opened / created in: `NATIVE` or `RTF`.
  final String format;

  /// The document as the server sent it (unchanged), null until its bytes
  /// arrived — a created document (CreateDocument) and a BDS document the
  /// server only published (PublishUrl) have none.
  final Uint8List? bytes;

  /// The file extension the bytes are best opened with ('.rtf', '.doc',
  /// '.docx', '.docm', '.xls', '.xlsx', '.xlsm', '.xdp', '.bin'):
  /// [officeFileExtension].
  final String fileExtension;

  /// Opened read-only (the open flags' read-only bit, a ProtectDocument).
  final bool readOnly;

  /// The spreadsheet range / cell model the server's SOI calls fill
  /// (SetRangesData, …) — Excel documents only.
  final Document? sheet;

  /// Bumps on any change of the document (bytes, cells, ranges).
  final int version;

  /// The spreadsheet model's sheets in tab order (an Excel document's
  /// [sheet]; empty otherwise): worksheets with their cells, chart sheets
  /// with their chart resolved against the cells (a created `Excel.Chart`:
  /// doi_default_chart.dart).
  List<SapOfficeSheet> get sheets {
    final d = sheet;
    return d == null ? const [] : officeSheetsOf(d);
  }

  /// The index in [sheets] of the sheet Excel shows (the model's active
  /// sheet), 0 when unknown.
  int get activeSheet {
    final d = sheet;
    if (d == null) return 0;
    final i = d.sheets.keys.toList().indexOf(d.activeSheet);
    return i < 0 ? 0 : i;
  }

  @override
  String toString() =>
      'SapOfficeDocument($shell $progId $format '
      '${bytes?.length ?? '-'} B $fileExtension'
      '${readOnly ? ' read-only' : ''} v$version)';
}

/// One sheet of a DOI spreadsheet model, as the screen shows it.
class SapOfficeSheet {
  const SapOfficeSheet({required this.name, required this.cells, this.chart});

  final String name;

  /// The non-empty cells, (row, column) 1-based -> a [num] for a cell
  /// typed as a number, else its [String] text.
  final Map<(int, int), Object> cells;

  /// A chart sheet's chart (it holds no cells), null for a worksheet.
  final SapOfficeChart? chart;

  bool get isChart => chart != null;

  @override
  String toString() =>
      'SapOfficeSheet($name ${isChart ? 'chart' : '${cells.length} cells'})';
}

/// A chart sheet's chart with the data it plots.
class SapOfficeChart {
  const SapOfficeChart({
    required this.type,
    required this.series,
    this.gapWidth = 150,
    this.overlap = 0,
  });

  final DoiChartType type;
  final List<DoiChartSeriesData> series;

  /// The gap between category clusters, % of a column's width.
  final int gapWidth;

  /// The overlap of a cluster's columns, %.
  final int overlap;

  /// The category labels (the first series').
  List<String> get categories =>
      series.isEmpty ? const [] : series.first.categories;
}

/// [doc]'s sheets in tab order: [SapOfficeDocument.sheets].
List<SapOfficeSheet> officeSheetsOf(Document doc) => [
  for (final MapEntry(key: name, value: cells) in doc.sheets.entries)
    SapOfficeSheet(
      name: name,
      cells: {
        for (final MapEntry(key: at, value: text) in cells.entries)
          if (text.isNotEmpty) at: doc.valueAt(at.$1, at.$2, name),
      },
      chart: switch (doc.charts[name]) {
        null => null,
        final c => SapOfficeChart(
          type: c.type,
          series: resolveDoiChart(doc, c),
          gapWidth: c.gapWidth,
          overlap: c.overlap,
        ),
      },
    ),
];

/// The extension [bytes] (else [progId] / [format]) are best opened with:
/// the content's magic first — `{\rtf` RTF, `PK\x03\x04` an OOXML package
/// (`.docm` / `.xlsm` when it carries a VBA project), `D0 CF 11 E0` an OLE2
/// compound file (Word 97 `.doc`, Excel 97 `.xls`), `<?xml` an XDP form
/// template — then the ProgID (`*.12` OOXML, `*.8` and unnumbered the 97
/// binary formats).
String officeFileExtension(String progId, String format, Uint8List? bytes) {
  final kind = officeKindOf(progId);
  final p = progId.trim().toLowerCase();
  final b = bytes;
  if (b != null && b.isNotEmpty) {
    if (_startsWith(b, const [0x7b, 0x5c, 0x72, 0x74, 0x66])) return '.rtf';
    if (_startsWith(b, const [0x50, 0x4b, 0x03, 0x04])) {
      final macro = _contains(b, 'vbaProject.bin');
      return switch (kind) {
        OfficeDocKind.word => macro ? '.docm' : '.docx',
        OfficeDocKind.excel => macro ? '.xlsm' : '.xlsx',
        OfficeDocKind.other => '.zip',
      };
    }
    if (_startsWith(b, const [0xd0, 0xcf, 0x11, 0xe0])) {
      return switch (kind) {
        OfficeDocKind.word => '.doc',
        OfficeDocKind.excel => '.xls',
        OfficeDocKind.other => '.bin',
      };
    }
    if (p.startsWith('pdfxmldesigner.') || _xmlHead(b)) return '.xdp';
  }
  if (format.trim().toUpperCase() == 'RTF') return '.rtf';
  if (p.startsWith('pdfxmldesigner.')) return '.xdp';
  final ooxml = p.endsWith('.12');
  return switch (kind) {
    OfficeDocKind.word => ooxml ? '.docx' : '.doc',
    OfficeDocKind.excel =>
      p.contains('macroenabled')
          ? '.xlsm'
          : ooxml
          ? '.xlsx'
          : '.xls',
    OfficeDocKind.other => '.bin',
  };
}

bool _startsWith(Uint8List b, List<int> magic) {
  if (b.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (b[i] != magic[i]) return false;
  }
  return true;
}

bool _xmlHead(Uint8List b) {
  var i = 0;
  // a UTF-8 byte order mark, then white space
  if (_startsWith(b, const [0xef, 0xbb, 0xbf])) i = 3;
  while (i < b.length &&
      i < 64 &&
      (b[i] == 0x20 || b[i] == 0x0a || b[i] == 0x0d || b[i] == 0x09)) {
    i++;
  }
  return i + 5 <= b.length && String.fromCharCodes(b, i, i + 5) == '<?xml';
}

/// Whether the latin-1 [needle] occurs in [b] (a zip central directory
/// names its parts in clear).
bool _contains(Uint8List b, String needle) {
  final n = needle.codeUnits;
  outer:
  for (var i = 0; i + n.length <= b.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (b[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}
