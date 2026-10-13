/// Client-side export of a DOI document: which files the user can save
/// for a Word / Excel document, given what the server sent.
///
/// * Excel: the server's own OOXML package (.xlsx / .xlsm) verbatim when it
/// sent one; otherwise a fresh .xlsx written from the spreadsheet model
/// (the ranges / cells the spreadsheet interface filled), with the
/// original binary .xls as a secondary choice when it exists.
/// * Word: the server's .docx / .docm verbatim; otherwise RTF (SO10,
/// SmartForms) converted to a fresh .docx, the original .rtf (or a
/// binary .doc) as the secondary choice.
library;

import 'dart:typed_data';

import 'detect.dart';
import 'docx_writer.dart';
import 'rtf_reader.dart';
import 'workbook.dart';
import 'xlsx_writer.dart';

class OfficeExport {
  const OfficeExport({
    required this.fileName,
    required this.bytes,
    required this.mimeType,
    required this.label,
    required this.converted,
  });

  /// File name with extension, safe for any file system.
  final String fileName;
  final Uint8List bytes;
  final String mimeType;

  /// What the menu shows ("Excel workbook (.xlsx)").
  final String label;

  /// Whether GuiGo wrote the file (vs the server's bytes verbatim).
  final bool converted;

  String get extension {
    final i = fileName.lastIndexOf('.');
    return i < 0 ? '' : fileName.substring(i);
  }
}

/// The export files for a document, the primary (an .xlsx / .docx) first.
/// [word] / [excel] say which application the document belongs to (its
/// ProgID); [bytes] is the document as the server sent it, [sheet] the
/// spreadsheet model; [baseName] names the files (sanitised here).
List<OfficeExport> officeExports({
  required bool word,
  required bool excel,
  Uint8List? bytes,
  Workbook? sheet,
  required String baseName,
}) {
  final name = sanitizeFileName(baseName);
  final format = bytes == null || bytes.isEmpty
      ? OfficeFileFormat.unknown
      : detectOfficeFormat(bytes);
  final out = <OfficeExport>[];
  OfficeExport verbatim(OfficeFileFormat f, Uint8List b) => OfficeExport(
    fileName: '$name${f.extension}',
    bytes: b,
    mimeType: f.mimeType,
    label: '${f.label} (${f.extension}, as sent)',
    converted: false,
  );

  if (excel || (!word && format.isExcel)) {
    if (bytes != null &&
        (format == OfficeFileFormat.xlsx || format == OfficeFileFormat.xlsm)) {
      out.add(verbatim(format, bytes));
    } else if (sheet != null) {
      out.add(
        OfficeExport(
          fileName: '$name.xlsx',
          bytes: writeXlsx(sheet),
          mimeType: OfficeFileFormat.xlsx.mimeType,
          label: 'Excel workbook (.xlsx)',
          converted: true,
        ),
      );
    }
    if (bytes != null && format.isBinaryOffice) {
      out.add(verbatim(format, bytes));
    }
    return out;
  }
  if (word || format.isWord) {
    if (bytes == null) return out;
    switch (format) {
      case OfficeFileFormat.docx || OfficeFileFormat.docm:
        out.add(verbatim(format, bytes));
      case OfficeFileFormat.rtf:
        out.add(
          OfficeExport(
            fileName: '$name.docx',
            bytes: writeDocx(readRtf(bytes)),
            mimeType: OfficeFileFormat.docx.mimeType,
            label: 'Word document (.docx)',
            converted: true,
          ),
        );
        out.add(verbatim(format, bytes));
      case OfficeFileFormat.binaryWord || OfficeFileFormat.binaryOther:
        out.add(verbatim(format, bytes));
      default:
    }
  }
  return out;
}

/// [s] as a file name: path separators, reserved and control characters
/// replaced, whitespace collapsed, at most 80 characters, never empty.
String sanitizeFileName(String s) {
  var n = s
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f\x7f]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'^\.+'), '');
  if (n.length > 80) n = n.substring(0, 80).trim();
  return n.isEmpty ? 'document' : n;
}

/// `<what>-yyyymmdd-hhmm` for a document without a title.
String datedFileName(String what, DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '$what-${at.year}${two(at.month)}${two(at.day)}-${two(at.hour)}${two(at.minute)}';
}
