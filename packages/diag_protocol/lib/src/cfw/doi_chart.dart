/// The chart of an Excel chart sheet in the DOI document model (doi.dart's
/// headless Office): the chart type and its series, each series naming the
/// cells it plots the way Excel's SERIES / BRAI records do (a name cell,
/// the category cells, the value cells) — resolved against the document's
/// cells when the screen draws it.
library;

import 'doi.dart' show Document;

/// The chart types the model knows (Excel's BAR record: pcOverlap 0,
/// vertical, not stacked = clustered columns).
enum DoiChartType { clusteredColumn }

/// A rectangle of cells of [sheet], 1-based and inclusive.
class DoiCellRange {
  const DoiCellRange(this.sheet, this.top, this.left, this.bottom, this.right);

  /// One cell.
  const DoiCellRange.cell(this.sheet, this.top, this.left)
    : bottom = top,
      right = left;

  final String sheet;
  final int top, left, bottom, right;

  /// The cells row by row, as (row, column).
  Iterable<(int, int)> get cells sync* {
    for (var r = top; r <= bottom; r++) {
      for (var c = left; c <= right; c++) {
        yield (r, c);
      }
    }
  }

  @override
  bool operator ==(Object other) =>
      other is DoiCellRange &&
      other.sheet == sheet &&
      other.top == top &&
      other.left == left &&
      other.bottom == bottom &&
      other.right == right;

  @override
  int get hashCode => Object.hash(sheet, top, left, bottom, right);

  @override
  String toString() => 'DoiCellRange($sheet R${top}C$left:R${bottom}C$right)';
}

/// One plotted series: where its name, categories and values live.
class DoiChartSeries {
  const DoiChartSeries({
    required this.name,
    required this.categories,
    required this.values,
  });

  final DoiCellRange name;
  final DoiCellRange categories;
  final DoiCellRange values;
}

/// A chart sheet's chart.
class DoiChart {
  const DoiChart({
    this.type = DoiChartType.clusteredColumn,
    required this.series,
    this.gapWidth = 150,
    this.overlap = 0,
  });

  final DoiChartType type;
  final List<DoiChartSeries> series;

  /// The gap between category clusters, % of one column's width (BAR
  /// pcGap).
  final int gapWidth;

  /// The overlap of a cluster's columns, % (BAR pcOverlap).
  final int overlap;
}

/// A series of a [DoiChart] resolved against a document's cells.
class DoiChartSeriesData {
  const DoiChartSeriesData({
    required this.name,
    required this.categories,
    required this.values,
    required this.source,
  });

  final String name;
  final List<String> categories;

  /// A value per category: the typed number, a numeric text, else null (a
  /// gap).
  final List<num?> values;

  /// The cells the series was read from.
  final DoiChartSeries source;
}

/// [chart]'s series with the current names / categories / values of
/// [doc]'s cells.
List<DoiChartSeriesData> resolveDoiChart(Document doc, DoiChart chart) => [
  for (final s in chart.series)
    DoiChartSeriesData(
      name: doc.cell(s.name.top, s.name.left, s.name.sheet),
      categories: [
        for (final (r, c) in s.categories.cells)
          doc.cell(r, c, s.categories.sheet),
      ],
      values: [
        for (final (r, c) in s.values.cells)
          doc.numberAt(r, c, s.values.sheet) ??
              num.tryParse(doc.cell(r, c, s.values.sheet).trim()),
      ],
      source: s,
    ),
];
