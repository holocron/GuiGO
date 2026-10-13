/// The Office document a DOI container holds, as the screen shows it
/// (SAP.DocumentContainerControl.1 — doi.dart's headless Office): what the
/// server sent, never a re-serialisation of ours.
library;

import 'dart:typed_data';

import 'doi.dart' show Document;

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

  @override
  String toString() =>
      'SapOfficeDocument($shell $progId $format '
      '${bytes?.length ?? '-'} B $fileExtension'
      '${readOnly ? ' read-only' : ''} v$version)';
}

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
