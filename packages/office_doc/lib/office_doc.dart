/// Pure-Dart Office document support for GuiGo's DOI (Desktop Office
/// Integration) pane: an RTF subset reader, .docx / .xlsx readers and
/// minimal writers, format detection (incl. OLE2 .doc / .xls), and the
/// client-side export choices. No Flutter imports.
library;

export 'src/detect.dart';
export 'src/docx_reader.dart' show readDocx;
export 'src/docx_writer.dart';
export 'src/export.dart';
export 'src/rich_text.dart';
export 'src/rtf_reader.dart';
export 'src/workbook.dart';
export 'src/xdp_reader.dart';
export 'src/xlsx_reader.dart' show readXlsx, excelDateText, numberText;
export 'src/xlsx_writer.dart';
export 'src/zip.dart'
    show ZipReader, ZipWriter, ZipEntry, ZipException, looksLikeZip, crc32;
