/// What a document's bytes are, and reading them into a model.
library;

import 'dart:typed_data';

import 'docx_reader.dart';
import 'rich_text.dart';
import 'rtf_reader.dart';
import 'workbook.dart';
import 'xlsx_reader.dart';
import 'zip.dart';

enum OfficeFileFormat {
  rtf,
  docx,

  /// a macro-enabled Word package (.docm)
  docm,
  xlsx,

  /// a macro-enabled Excel package (.xlsm)
  xlsm,

  /// an OLE2 compound file holding a Word 97-2003 document (.doc)
  binaryWord,

  /// an OLE2 compound file holding an Excel 97-2003 workbook (.xls)
  binaryExcel,

  /// an OLE2 compound file of another / unknown kind
  binaryOther,

  /// a zip package that is neither Word nor Excel (.pptx, …)
  zipOther,
  unknown,
}

extension OfficeFileFormatInfo on OfficeFileFormat {
  /// The file extension (with the dot) for this format.
  String get extension => switch (this) {
    OfficeFileFormat.rtf => '.rtf',
    OfficeFileFormat.docx => '.docx',
    OfficeFileFormat.docm => '.docm',
    OfficeFileFormat.xlsx => '.xlsx',
    OfficeFileFormat.xlsm => '.xlsm',
    OfficeFileFormat.binaryWord => '.doc',
    OfficeFileFormat.binaryExcel => '.xls',
    OfficeFileFormat.binaryOther => '.bin',
    OfficeFileFormat.zipOther => '.zip',
    OfficeFileFormat.unknown => '.bin',
  };

  String get mimeType => switch (this) {
    OfficeFileFormat.rtf => 'application/rtf',
    OfficeFileFormat.docx =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    OfficeFileFormat.docm => 'application/vnd.ms-word.document.macroEnabled.12',
    OfficeFileFormat.xlsx =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    OfficeFileFormat.xlsm => 'application/vnd.ms-excel.sheet.macroEnabled.12',
    OfficeFileFormat.binaryWord => 'application/msword',
    OfficeFileFormat.binaryExcel => 'application/vnd.ms-excel',
    OfficeFileFormat.zipOther => 'application/zip',
    _ => 'application/octet-stream',
  };

  /// A short human label ("Word 97-2003 document").
  String get label => switch (this) {
    OfficeFileFormat.rtf => 'RTF document',
    OfficeFileFormat.docx => 'Word document',
    OfficeFileFormat.docm => 'Word macro-enabled document',
    OfficeFileFormat.xlsx => 'Excel workbook',
    OfficeFileFormat.xlsm => 'Excel macro-enabled workbook',
    OfficeFileFormat.binaryWord => 'Word 97-2003 document',
    OfficeFileFormat.binaryExcel => 'Excel 97-2003 workbook',
    OfficeFileFormat.binaryOther => 'binary Office document',
    OfficeFileFormat.zipOther => 'Office package',
    OfficeFileFormat.unknown => 'document',
  };

  bool get isBinaryOffice =>
      this == OfficeFileFormat.binaryWord ||
      this == OfficeFileFormat.binaryExcel ||
      this == OfficeFileFormat.binaryOther;

  bool get isWord =>
      this == OfficeFileFormat.rtf ||
      this == OfficeFileFormat.docx ||
      this == OfficeFileFormat.docm ||
      this == OfficeFileFormat.binaryWord;

  bool get isExcel =>
      this == OfficeFileFormat.xlsx ||
      this == OfficeFileFormat.xlsm ||
      this == OfficeFileFormat.binaryExcel;
}

const _ole2Magic = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1];

/// Whether [bytes] are an OLE2 compound file (the .doc / .xls container).
bool looksLikeOle2(Uint8List bytes) {
  if (bytes.length < 8) return false;
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != _ole2Magic[i]) return false;
  }
  return true;
}

/// The format of [bytes], from their signature and (for a zip package) its
/// part names; an OLE2 file by its directory's stream names.
OfficeFileFormat detectOfficeFormat(Uint8List bytes) {
  if (looksLikeRtf(bytes)) return OfficeFileFormat.rtf;
  if (looksLikeOle2(bytes)) {
    if (_hasUtf16(bytes, 'WordDocument')) return OfficeFileFormat.binaryWord;
    if (_hasUtf16(bytes, 'Workbook') || _hasUtf16(bytes, 'Book')) {
      return OfficeFileFormat.binaryExcel;
    }
    return OfficeFileFormat.binaryOther;
  }
  if (looksLikeZip(bytes)) {
    try {
      final zip = ZipReader(bytes);
      final types = zip.entries.containsKey('[Content_Types].xml')
          ? zip.readText('[Content_Types].xml') ?? ''
          : '';
      if (zip.entries.containsKey('word/document.xml') ||
          types.contains('wordprocessingml.document.main') ||
          types.contains('ms-word.document.macroEnabled')) {
        return types.contains('macroEnabled')
            ? OfficeFileFormat.docm
            : OfficeFileFormat.docx;
      }
      if (zip.entries.containsKey('xl/workbook.xml') ||
          types.contains('spreadsheetml.sheet.main') ||
          types.contains('ms-excel.sheet.macroEnabled')) {
        return types.contains('macroEnabled')
            ? OfficeFileFormat.xlsm
            : OfficeFileFormat.xlsx;
      }
      return OfficeFileFormat.zipOther;
    } on Object {
      return OfficeFileFormat.zipOther;
    }
  }
  return OfficeFileFormat.unknown;
}

bool _hasUtf16(Uint8List b, String name) {
  final pat = [
    for (final c in name.codeUnits) ...[c, 0],
  ];
  final end = b.length - pat.length;
  outer:
  for (var i = 0; i <= end; i++) {
    for (var k = 0; k < pat.length; k++) {
      if (b[i + k] != pat[k]) continue outer;
    }
    return true;
  }
  return false;
}

/// A document's bytes read into a model.
sealed class OfficeContent {
  const OfficeContent(this.format);
  final OfficeFileFormat format;
}

class OfficeText extends OfficeContent {
  const OfficeText(super.format, this.document);
  final RichDocument document;
}

class OfficeSheet extends OfficeContent {
  const OfficeSheet(super.format, this.workbook);
  final Workbook workbook;
}

/// Bytes with no reader here (an OLE2 .doc / .xls, another package): the
/// platform viewer may still show them.
class OfficeOpaque extends OfficeContent {
  const OfficeOpaque(super.format, this.size, {this.error});
  final int size;

  /// Why a readable format failed to read, when it did.
  final String? error;
}

/// Reads [bytes] with the reader their format calls for; never throws —
/// a damaged document comes back as [OfficeOpaque] with the error.
OfficeContent readOfficeDocument(Uint8List bytes) {
  final f = detectOfficeFormat(bytes);
  try {
    switch (f) {
      case OfficeFileFormat.rtf:
        return OfficeText(f, readRtf(bytes));
      case OfficeFileFormat.docx || OfficeFileFormat.docm:
        return OfficeText(f, readDocx(bytes));
      case OfficeFileFormat.xlsx || OfficeFileFormat.xlsm:
        return OfficeSheet(f, readXlsx(bytes));
      default:
        return OfficeOpaque(f, bytes.length);
    }
  } on Object catch (e) {
    return OfficeOpaque(f, bytes.length, error: '$e');
  }
}
