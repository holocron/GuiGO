/// A read model of a spreadsheet: sheets of cells keyed by 1-based
/// (row, column), column widths, merged ranges.
library;

enum CellKind { string, number, boolean, error, date }

class SheetCell {
  const SheetCell(
    this.text, {
    this.kind = CellKind.string,
    this.number,
    this.formula,
  });

  /// A cell holding [text], typed as a number when it reads as one (the
  /// DOI spreadsheet interface delivers every value as text).
  factory SheetCell.guess(String text) {
    final t = text.trim();
    final n = _numberRx.hasMatch(t) ? num.tryParse(t) : null;
    return n == null
        ? SheetCell(text)
        : SheetCell(text, kind: CellKind.number, number: n);
  }

  static final _numberRx = RegExp(r'^-?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$');

  /// The value as displayed (the cached value of a formula cell).
  final String text;
  final CellKind kind;

  /// The numeric value of a number / date cell (a date: the Excel serial).
  final num? number;

  /// The formula without its leading `=`, when the cell has one.
  final String? formula;

  @override
  bool operator ==(Object other) =>
      other is SheetCell &&
      other.text == text &&
      other.kind == kind &&
      other.number == number &&
      other.formula == formula;

  @override
  int get hashCode => Object.hash(text, kind, number, formula);

  @override
  String toString() =>
      'SheetCell($kind "$text"${formula == null ? '' : ' =$formula'})';
}

/// A rectangle of cells, 1-based and inclusive.
class CellRange {
  const CellRange(this.top, this.left, this.bottom, this.right);

  final int top, left, bottom, right;

  int get rows => bottom - top + 1;
  int get cols => right - left + 1;

  bool contains(int row, int col) =>
      row >= top && row <= bottom && col >= left && col <= right;

  /// Parses `A1:C3` / `B2` (null when it is not a cell reference).
  static CellRange? parse(String ref) {
    final parts = ref.replaceAll(r'$', '').split(':');
    final a = parseCellRef(parts.first);
    final b = parts.length > 1 ? parseCellRef(parts[1]) : a;
    if (a == null || b == null) return null;
    return CellRange(
      a.$1 < b.$1 ? a.$1 : b.$1,
      a.$2 < b.$2 ? a.$2 : b.$2,
      a.$1 > b.$1 ? a.$1 : b.$1,
      a.$2 > b.$2 ? a.$2 : b.$2,
    );
  }

  String get ref => top == bottom && left == right
      ? cellRef(top, left)
      : '${cellRef(top, left)}:${cellRef(bottom, right)}';

  @override
  bool operator ==(Object other) =>
      other is CellRange &&
      other.top == top &&
      other.left == left &&
      other.bottom == bottom &&
      other.right == right;

  @override
  int get hashCode => Object.hash(top, left, bottom, right);

  @override
  String toString() => 'CellRange($ref)';
}

class Worksheet {
  Worksheet(
    this.name, {
    Map<(int, int), SheetCell>? cells,
    Map<int, double>? columnWidths,
    List<CellRange>? merged,
    this.defaultColumnWidth,
    this.hidden = false,
  }) : cells = cells ?? {},
       columnWidths = columnWidths ?? {},
       merged = merged ?? [];

  final String name;

  /// (row, column) 1-based -> cell.
  final Map<(int, int), SheetCell> cells;

  /// Column (1-based) -> width in characters of the default font.
  final Map<int, double> columnWidths;
  final List<CellRange> merged;
  final double? defaultColumnWidth;
  final bool hidden;

  SheetCell? cell(int row, int col) => cells[(row, col)];

  /// The highest row / column holding a cell or covered by a merge.
  int get rowCount {
    var m = 0;
    for (final (r, _) in cells.keys) {
      if (r > m) m = r;
    }
    for (final g in merged) {
      if (g.bottom > m) m = g.bottom;
    }
    return m;
  }

  int get colCount {
    var m = 0;
    for (final (_, c) in cells.keys) {
      if (c > m) m = c;
    }
    for (final g in merged) {
      if (g.right > m) m = g.right;
    }
    return m;
  }

  /// The merge whose top-left is (row, col), or null.
  CellRange? mergeAt(int row, int col) {
    for (final g in merged) {
      if (g.top == row && g.left == col) return g;
    }
    return null;
  }

  /// Whether (row, col) is covered by a merge without being its top-left.
  bool isCovered(int row, int col) {
    for (final g in merged) {
      if (g.contains(row, col) && !(g.top == row && g.left == col)) return true;
    }
    return false;
  }
}

class Workbook {
  Workbook(List<Worksheet> sheets, {this.activeSheet = 0, this.title})
    : sheets = List.unmodifiable(sheets);

  final List<Worksheet> sheets;

  /// Index of the sheet Excel opens on.
  final int activeSheet;
  final String? title;
}

/// `A`, `B`, … `Z`, `AA`, … for a 1-based column.
String columnLetters(int col) {
  final b = StringBuffer();
  var n = col;
  final out = <int>[];
  while (n > 0) {
    final r = (n - 1) % 26;
    out.add(0x41 + r);
    n = (n - 1) ~/ 26;
  }
  for (final c in out.reversed) {
    b.writeCharCode(c);
  }
  return b.toString();
}

String cellRef(int row, int col) => '${columnLetters(col)}$row';

/// `B12` -> (12, 2); null when [ref] is not a cell reference.
(int, int)? parseCellRef(String ref) {
  final m = RegExp(r'^\$?([A-Za-z]{1,3})\$?(\d{1,7})$').firstMatch(ref.trim());
  if (m == null) return null;
  var col = 0;
  for (final c in m.group(1)!.toUpperCase().codeUnits) {
    col = col * 26 + (c - 0x40);
  }
  final row = int.parse(m.group(2)!);
  if (row < 1) return null;
  return (row, col);
}

/// The column part of a cell reference (`C7` -> 3), or null.
int? columnOfRef(String ref) {
  final m = RegExp(r'^\$?([A-Za-z]{1,3})').firstMatch(ref.trim());
  if (m == null) return null;
  var col = 0;
  for (final c in m.group(1)!.toUpperCase().codeUnits) {
    col = col * 26 + (c - 0x40);
  }
  return col;
}
