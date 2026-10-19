/// What a NEW Excel chart object holds: Excel's built-in default content
/// for an `Excel.Chart` the server creates (CreateDocument, no bytes from
/// the server — SAPRDEMOEXCELINTEGRATION's "Créer document"). Excel makes
/// a workbook of a chart sheet (active) plotting a small data sheet.
///
/// Ground truth: the real SAP GUI for Windows' Office 16 (French) save-back
/// of exactly such a created chart — a recorded session srv[35], the GUI's
/// upload: a chart sheet `Graphique1` (clustered columns: BAR pcOverlap 0,
/// pcGap 150; three SERIES of six points, names from row 1, categories
/// from column A, values from columns B..D of `Feuil1`), then the
/// worksheet `Feuil1` holding the table below. Only the content is
/// modelled here — no file of Excel's.
library;

import 'doi.dart' show Document;
import 'doi_chart.dart';

/// The chart sheet / data sheet names (the French Office's).
const String defaultChartSheet = 'Graphique1';
const String defaultChartDataSheet = 'Feuil1';

/// The data sheet's series names (row 1, columns B..D).
const List<String> defaultChartSeriesNames = ['Repas', 'Essence', 'Hotel'];

/// The data sheet's categories (column A, rows 2..7).
const List<String> defaultChartCategories = [
  'Janvier', 'Février', 'Mars', 'Avr', 'Mai', 'Juin',
];

/// The data sheet's values, a row per category, a column per series.
const List<List<int>> defaultChartValues = [
  [12, 17, 10],
  [17, 11, 21],
  [22, 29, 14],
  [14, 10, 17],
  [12, 17, 10],
  [19, 15, 20],
];

/// Whether [cls] is Excel's chart object class (`Excel.Chart`,
/// `Excel.Chart.8`).
bool isExcelChartClass(String cls) =>
    _excelChartClassRx.hasMatch(cls.trim().toLowerCase());

// hoisted: a RegExp built per call is compiled per call (audit
// 2026-10-17 N1)
final RegExp _excelChartClassRx = RegExp(r'^excel\.chart(\.\d+)?$');

/// [doc] (a created `Excel.Chart`) as Excel makes it: the chart sheet
/// first and active, then the data sheet, its values typed as numbers.
/// The document keeps no source bytes (its save-back stays refused).
void applyDefaultChart(Document doc) {
  const data = defaultChartDataSheet;
  doc.sheets.clear();
  doc.charts.clear();
  doc.sheets[defaultChartSheet] = {};
  doc.sheets[data] = {};
  final cols = defaultChartSeriesNames.length;
  final rows = defaultChartCategories.length;
  for (var s = 0; s < cols; s++) {
    doc.setCell(1, s + 2, defaultChartSeriesNames[s], data);
  }
  for (var r = 0; r < rows; r++) {
    doc.setCell(r + 2, 1, defaultChartCategories[r], data);
    for (var s = 0; s < cols; s++) {
      doc.setNumber(r + 2, s + 2, defaultChartValues[r][s], data);
    }
  }
  doc.charts[defaultChartSheet] = DoiChart(
    series: [
      for (var s = 0; s < cols; s++)
        DoiChartSeries(
          name: DoiCellRange.cell(data, 1, s + 2),
          categories: DoiCellRange(data, 2, 1, rows + 1, 1),
          values: DoiCellRange(data, 2, s + 2, rows + 1, s + 2),
        ),
    ],
  );
  doc.activeSheet = defaultChartSheet;
}
