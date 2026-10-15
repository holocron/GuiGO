/// The GFW business graphic (CL_GUI_GP_PRES with PROD_ID CO_PROD_CHART —
/// GRAL's GFW_DEMO_PRES1, GFW_DEMO_HIER3's bottom-middle chart, the
/// GFW_PROG_BAR / _PIE / _MTA / _TIME_AXIS … programming examples): the
/// Graphitti chart control and its data ADAPTER, decoded into a
/// [SapChartModel] (read side only).
///
/// Control pair (ABAP CL_GFW_GP_PRES_CHART->CONSTRUCTOR, the test system):
/// * the chart, `super->constructor( clsid = ctrl_name )` — ctrl_name the
/// product table TGPN's TECH_NAME for BUSG / CHART: `Graphitti.Chart.1`
/// (WN32), `com.iCube.beans.chtchart.CHTChart` (JAVA);
/// * the adapter, same parent: `SAPGUI.GraphittiAdapt.1` (Windows) /
/// `com.sap.components.controls.chart.Adapter` (Java bean), then a
/// flush, then adapter `LoadURL(<the chart's h_control-obj>)`,
/// `SetVersion(2)`, `SendObjId`, the chart's `AllowContextMenus` /
/// `AllowDialogs` / `AllowTextEdit` / `AllowSelect` / `AllowValueChange`
/// = 0 and adapter `SetLanguage(sy-langu)`.
///
/// Data path (IF_GP_PRODUCT~FILL): `ReDraw = 0`, then DataProvider tables
/// assigned to the ADAPTER (DP_CONTROL_ASSIGN_TABLE h_cntl = adapt_handle,
/// medium R3TABLE — on the wire `CreateObject(GuiDataProvider)` →
/// `SetDataFromUrl(APPLICATION, X-R3TABLE, SAPR3://…)` → `GetDataAsFormat`
/// → `AssignProperty2(<dp>, data, <adapter handle>, <property>)`):
/// * `DATA` (FILL_COMPLETE, ty_dc_data): CUREF c40 | GRPID c40 |
/// XVAL c40 | YVAL c40 | OBJID c40 | LABEL c80 — one row per data
/// container object; GRPID = the series, XVAL the category (or an x
/// value / `yyyymmddhhmmss` time), YVAL the value (a float's
/// `2.0000000000000000E+01`, or a time);
/// * `UpdateData` (FILL_UPDATE, ty_dc_upd_data): OBJID | GRPID | XVAL |
/// YVAL | CUREF c40 | LABEL c80 | PRED c40 | MODE i (1 deleted,
/// 2 changed, 3 inserted after PRED);
/// * `CUSTDATA` (CL_GUI_GP->WRITE_CU_BUNDLES, GFWCUDPS): OBJECT_ID c40 |
/// BUNDLE_ID int1 | ATTR_ID c40 | MASTER c1 | VALUE c80 — each bundle's
/// attributes once per (OBJECT_ID, BUNDLE_ID) (nested display contexts
/// at their base + attr: a values bundle's curve context at 1000), and
/// per use a PORT row: MASTER 'P', ATTR_ID = the bundle's key (a series
/// GRPID / point OBJID, blank for all), VALUE = the port
/// (IF_GRAPHIC_PROXY: 1 diagram, 2 chart, 5 x / 11 y primary axis);
/// * `XLABEL` / `YLABEL` (ty_dc_label: ID c40 | LABEL c80) — texts for
/// categories / groups when the DC names T_DIM1 / T_GRP_ID;
/// * then `ReDraw = 1`.
/// Wire-confirmed on the REAL SAP GUI for Java (reference client recording
/// a recorded session srv[48..49], GRAL → GFW_PROG_BAR: chart 119
/// CHTChart, adapter 120 in container 118 `CONTAINER`; DATA 12 rows x 280,
/// CUSTDATA 738 rows x 162, both under X-UNKNOWN FORMAT descriptors). The
/// Windows wave (Graphitti.Chart.1 / SAPGUI.GraphittiAdapt.1) is the same
/// ABAP and unrecorded.
library;

import 'dart:typed_data';

import '../cfw/dp_cache.dart';
import 'sap_chart.dart';

/// The adapter control classes (upper-cased) a GFW chart pairs with.
const Set<String> gfwAdapterClasses = {
  'SAPGUI.GRAPHITTIADAPT.1',
  'COM.SAP.COMPONENTS.CONTROLS.CHART.ADAPTER',
};

/// Whether [cls] is a GFW chart adapter (never a chart itself, though the
/// Java bean's class name says `chart`).
bool isGfwAdapterClass(String cls) =>
    gfwAdapterClasses.contains(cls.trim().toUpperCase());

/// The adapter properties the GFW chart's data rides.
const String gfwData = 'DATA';
const String gfwUpdateData = 'UpdateData';
const String gfwCustData = 'CUSTDATA';
const String gfwXLabel = 'XLABEL';
const String gfwYLabel = 'YLABEL';

const Set<String> gfwAdapterRoles = {
  gfwData,
  gfwUpdateData,
  gfwCustData,
  gfwXLabel,
  gfwYLabel,
};

// ---------------------------------------------------------------------------
// The DataProvider tables
// ---------------------------------------------------------------------------

/// One DATA row (a data container object as the chart reads it).
class GfwDataRow {
  GfwDataRow({
    this.curef = '',
    this.grpid = '',
    this.xval = '',
    this.yval = '',
    this.objid = '',
    this.label = '',
  });
  String curef, grpid, xval, yval, objid, label;

  @override
  String toString() => 'GfwDataRow($objid $grpid x=$xval y=$yval)';
}

/// One CUSTDATA row (GFWCUDPS).
class GfwCuRow {
  GfwCuRow(this.objectId, this.bundleId, this.attrId, this.master, this.value);
  final String objectId;
  final int bundleId;
  final String attrId;
  final String master;
  final String value;

  bool get isPort => master == 'P';
}

/// The fields of a pushed R3TABLE, per row per column (raw bytes, FORMAT
/// order): the push's own FORMAT descriptor when it has one, else
/// [widths] (the ABAP structure's character lengths). Empty when the push
/// holds no rows.
List<List<(Uint8List, int)>> gfwTableFields(Uint8List seg, List<int> widths) {
  final (_, (fw, fn), fcells) = dpColumnCells(seg, 'FORMAT');
  final fb = BytesBuilder(copy: false);
  for (final c in fcells) {
    fb.add(c);
  }
  var fmt = fb.takeBytes();
  if (fw > 0 && fn > 0 && fmt.length > fw * fn) {
    fmt = Uint8List.sublistView(fmt, 0, fw * fn);
  }
  var cols = fmt.isEmpty ? null : placeholderColumns(fmt);
  if (cols == null || cols.isEmpty) {
    var off = 0;
    cols = [
      for (final (i, w) in widths.indexed)
        FmtColumn(i + 1, (off += w) - w, w, w == 1 && i == 1 ? 98 : 67, ''),
    ];
  }
  final (_, (dw, dn), dcells) = dpColumnCells(seg, 'DATAASC');
  final db = BytesBuilder(copy: false);
  for (final c in dcells) {
    // inline rows arrive one per cell, each cut at its trailing blanks:
    // pad them to the declared width
    if (dw > 0 && dn > 0 && dcells.length == dn && c.length < dw) {
      db.add(c);
      db.add(Uint8List(dw - c.length)..fillRange(0, dw - c.length, 0x20));
    } else {
      db.add(c);
    }
  }
  final data = db.takeBytes();
  var rl = 0;
  for (final c in cols) {
    if (c.offset + c.length > rl) rl = c.offset + c.length;
  }
  if (dw > 0 && dw >= rl) rl = dw;
  if (rl <= 0 || data.isEmpty) return const [];
  final n = dn > 0 && dn * rl <= data.length ? dn : data.length ~/ rl;
  return [
    for (var k = 0; k < n; k++)
      [
        for (final c in cols)
          (
            Uint8List.sublistView(
              data,
              (k * rl + c.offset).clamp(0, data.length),
              (k * rl + (c.offset + c.length > rl ? rl : c.offset + c.length))
                  .clamp(0, data.length),
            ),
            c.type,
          ),
      ],
  ];
}

String _text((Uint8List, int) f) => decodeRsField(f.$1, f.$2).trim();

/// A one-byte INT1 cell (BUNDLE_ID: type 98, the byte itself), else its
/// digits.
int _int1((Uint8List, int) f) {
  final (raw, type) = f;
  if (raw.length == 1 && (type == 98 || raw[0] < 0x20)) return raw[0];
  return int.tryParse(String.fromCharCodes(raw).trim()) ?? -1;
}

/// A four-byte INT4 cell (UpdateData MODE): its digits when it reads as
/// text, else the small value of either byte order.
int _int4((Uint8List, int) f) {
  final (raw, _) = f;
  final t = int.tryParse(String.fromCharCodes(raw).trim());
  if (t != null) return t;
  if (raw.length != 4) return -1;
  final bd = ByteData.sublistView(raw);
  final le = bd.getUint32(0, Endian.little), be = bd.getUint32(0);
  return le <= 0xffff ? le : be;
}

/// The DATA rows of a push.
List<GfwDataRow> parseGfwData(Uint8List seg) => [
  for (final r in gfwTableFields(seg, const [40, 40, 40, 40, 40, 80]))
    if (r.length >= 5)
      GfwDataRow(
        curef: _text(r[0]),
        grpid: _text(r[1]),
        xval: _text(r[2]),
        yval: _text(r[3]),
        objid: _text(r[4]),
        label: r.length > 5 ? _text(r[5]) : '',
      ),
];

/// The UpdateData rows of a push: (row, predecessor objid, mode).
List<(GfwDataRow, String, int)> parseGfwUpdate(Uint8List seg) => [
  for (final r in gfwTableFields(seg, const [40, 40, 40, 40, 40, 80, 40, 4]))
    if (r.length >= 8)
      (
        GfwDataRow(
          objid: _text(r[0]),
          grpid: _text(r[1]),
          xval: _text(r[2]),
          yval: _text(r[3]),
          curef: _text(r[4]),
          label: _text(r[5]),
        ),
        _text(r[6]),
        _int4(r[7]),
      ),
];

/// The CUSTDATA rows of a push.
List<GfwCuRow> parseGfwCustomizing(Uint8List seg) => [
  for (final r in gfwTableFields(seg, const [40, 1, 40, 1, 80]))
    if (r.length >= 5)
      GfwCuRow(_text(r[0]), _int1(r[1]), _text(r[2]), _text(r[3]), _text(r[4])),
];

/// The XLABEL / YLABEL rows of a push: id -> label.
Map<String, String> parseGfwLabels(Uint8List seg) => {
  for (final r in gfwTableFields(seg, const [40, 80]))
    if (r.length >= 2 && _text(r[0]).isNotEmpty) _text(r[0]): _text(r[1]),
};

// ---------------------------------------------------------------------------
// The customizing
// ---------------------------------------------------------------------------

/// CL_CU bundle ids (CL_CU=>CO_CLSID_*).
const int gfwBundleDrawingArea = 1;
const int gfwBundleAxis = 3;
const int gfwBundleValues = 6;

/// IF_GRAPHIC_PROXY ports.
const int gfwPortDiagram = 1;
const int gfwPortChart = 2;
const int gfwPortXAxis = 5;
const int gfwPortYAxis = 11;

/// The customizing bundles one CUSTDATA push declares.
class GfwCustomizing {
  GfwCustomizing(List<GfwCuRow> rows) {
    for (final r in rows) {
      final k = (r.objectId, r.bundleId);
      if (r.isPort) {
        ports.add((k, r.attrId, int.tryParse(r.value.trim()) ?? -1));
      } else {
        // a bundle's attributes are written once (WRITE_CU_BUNDLES keeps
        // the first write per object / bundle type)
        (attrs[k] ??= {}).putIfAbsent(r.attrId, () => r.value);
      }
    }
  }

  /// (object, bundle) -> attr id -> value
  final Map<(String, int), Map<String, String>> attrs = {};

  /// ((object, bundle), key, port) in push order
  final List<((String, int), String, int)> ports = [];

  /// The value of attribute [attr] of the [bundle]-type bundle used at
  /// [port] under [key] ('' = the bundle for all), null when none sets it.
  /// [ownOnly]: skip the generated default bundles (SAP000000x), whose
  /// values are the product's defaults, not the program's.
  String? valueAt(
    int bundle,
    int attr, {
    int port = gfwPortChart,
    String key = '',
    bool ownOnly = false,
  }) {
    final a = attr.toString();
    for (final (k, kKey, kPort) in ports) {
      if (k.$2 != bundle || kPort != port || kKey != key) continue;
      if (ownOnly && k.$1.startsWith('SAP000000')) continue;
      final v = attrs[k]?[a];
      if (v != null) return v;
    }
    return null;
  }

  /// [valueAt] for [key], falling back to the bundle for all.
  String? valueFor(int bundle, int attr, String key, {int port = gfwPortChart}) =>
      (key.isEmpty ? null : valueAt(bundle, attr, port: port, key: key)) ??
      valueAt(bundle, attr, port: port);
}

/// CL_CU_VALUES=>CO_STYLE values (a subset is in the GFW type pool:
/// gfw_prestype_vertical_bars 1, horizontal_bars 8, lines 17, pie_chart 27,
/// area 38, time_axis 100; the programs add 34 xy scatter, 49 bubble,
/// 81 milestone triangle, 89 histogram, 90 speedometer) -> the chart type
/// [SapChartModel.chartType] names. Codes between the known anchors are
/// read as the family the anchor below them opens (an assumption: the
/// Graphitti style table is front-end side).
String gfwChartType(int style) {
  if (style <= 0) return 'Columns';
  if (style < 8) return 'Columns';
  if (style < 17) return 'Bars';
  if (style < 27) return 'Lines';
  if (style < 34) return 'Pie';
  if (style < 38) return 'Scatter';
  if (style < 49) return 'Area';
  if (style < 80) return 'Scatter'; // bubble & co: drawn as xy points
  if (style < 89) return 'MilestoneTrend';
  if (style == 89) return 'Histogram'; // HistogramByRectStdDev
  if (style == 90) return 'Pie'; // speedometer: a share of a whole
  if (style == 100 || style == 101) return 'TimeLines';
  return 'Columns';
}

/// The chart types drawn on two value axes (x numeric or time, per point).
const Set<String> gfwXyTypes = {'Scatter', 'MilestoneTrend', 'TimeLines'};

final RegExp _timeRx = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})?(\d{2})?(\d{2})?$');

/// A GFW time value (`yyyymmdd` / `yyyymmddhhmmss`) in days since
/// 1970-01-01 (UTC), null when [s] is none.
double? gfwTimeDays(String s) {
  final m = _timeRx.firstMatch(s.trim());
  if (m == null) return null;
  final y = int.parse(m.group(1)!), mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(3)!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  final t = DateTime.utc(
    y,
    mo,
    d,
    int.parse(m.group(4) ?? '0'),
    int.parse(m.group(5) ?? '0'),
    int.parse(m.group(6) ?? '0'),
  );
  return t.millisecondsSinceEpoch / Duration.millisecondsPerDay;
}

/// A GFW number: a float's `5.0000000000000000E+01`, an integer, ABAP's
/// trailing minus (`5-`); null when [s] is none.
double? gfwNumber(String s) {
  var t = s.trim();
  if (t.isEmpty) return null;
  var neg = false;
  if (t.endsWith('-')) {
    neg = true;
    t = t.substring(0, t.length - 1).trim();
  }
  final v = double.tryParse(t);
  if (v == null) return null;
  return neg ? -v : v;
}

/// The chart the GFW pushes of one chart draw, null without DATA.
SapChartModel? buildGfwChart({
  required String shell,
  String? container,
  required List<GfwDataRow> rows,
  List<GfwCuRow> customizing = const [],
  Map<String, String> xLabels = const {},
  Map<String, String> yLabels = const {},
  Set<int> events = const {},
  String language = '',
}) {
  final cu = GfwCustomizing(customizing);
  // the series (GRPID) in first-appearance order
  final groups = <String>[];
  final byGroup = <String, List<GfwDataRow>>{};
  for (final r in rows) {
    final g = byGroup[r.grpid];
    if (g == null) {
      groups.add(r.grpid);
      byGroup[r.grpid] = [r];
    } else {
      g.add(r);
    }
  }
  int styleOf(String g) =>
      int.tryParse(
        (cu.valueFor(gfwBundleValues, 3, g) ?? '').trim(),
      ) ??
      1;
  final type = gfwChartType(groups.isEmpty ? 1 : styleOf(groups.first));
  final title = (cu.valueAt(gfwBundleDrawingArea, 1) ??
          cu.valueAt(gfwBundleDrawingArea, 1, port: gfwPortDiagram) ??
          '')
      .trim();
  String axisTitle(int port) =>
      (cu.valueAt(gfwBundleAxis, 0, port: port) ?? '').trim();
  bool timeAxis(int port) =>
      (cu.valueAt(gfwBundleAxis, 2, port: port) ?? '').trim() == '3';
  final xy = gfwXyTypes.contains(type);
  final xTime =
      timeAxis(gfwPortXAxis) ||
      type == 'MilestoneTrend' ||
      type == 'TimeLines' ||
      (xy &&
          rows.isNotEmpty &&
          rows.every((r) => gfwTimeDays(r.xval) != null));
  final yTime =
      timeAxis(gfwPortYAxis) ||
      type == 'MilestoneTrend' ||
      (xy &&
          rows.isNotEmpty &&
          rows.every((r) => gfwTimeDays(r.yval) != null));
  double? yOf(String v) => yTime ? gfwTimeDays(v) : gfwNumber(v);
  double? xOf(String v) => xTime ? gfwTimeDays(v) : gfwNumber(v);
  // a series' colour: the palette id its values bundle's curve context
  // (base 1000) sets — its own (keyed) bundle, else the bundle for all
  // series (GFW_DEMO_PRES1's GFW1T 1102 = 4 yellow for Company 1, its
  // GFW1T_2 1102 = 11 navy for Company 2; GFW_DEMO_HIER3's chart only the
  // generated default, 2 white): a filled family's background
  // (CO_BG_CLR_PLT_ID 102; GFW_PROG_BAR's GFWBARV1 / V2 1102 = 5 / 7, their
  // 1033 = 1 the bar outline), a line family's line (CO_BL_CLR_PLT_ID 33),
  // then its markers (CO_MR_BG_CLR_PLT_ID 106: GFW_PROG_MTA's 5 / 7)
  final lineFamily = xy || type == 'Lines';
  int? intOf(String? v) => int.tryParse((v ?? '').trim());
  int? colorOf(String g) {
    for (final a in lineFamily ? const [1033, 1106] : const [1102]) {
      final n = intOf(cu.valueFor(gfwBundleValues, a, g));
      if (n != null && n > 0) return n;
    }
    return null;
  }

  GfwSeriesLook lookOf(String g, List<GfwDataRow> pts) {
    String? v(int a) => cu.valueFor(gfwBundleValues, a, g);
    final look = GfwSeriesLook(
      fill: intOf(v(1102)),
      line: intOf(v(1033)),
      marker: intOf(v(1106)),
      markerStyle: intOf(v(1104)),
      lineStyle: intOf(v(1037)),
    );
    if (styleOf(g) == 89) {
      // HistogramByRectStdDev: the normal curve's parameters ride the
      // values bundle (CO_STD_DISTRIB_MEAN 10 / _DEVIATION 11 / _TITLE 13 —
      // GFW_PROG_HISTOGRAM's GFWHI1: 30, 8, 'Density function')
      look.distMean = gfwNumber(v(10) ?? '');
      look.distSigma = gfwNumber(v(11) ?? '');
      look.distTitle = (v(13) ?? '').trim();
    }
    for (final (i, p) in pts.indexed) {
      if (p.curef.isEmpty) continue;
      final pl = gfwPointLook(cu, p.curef, p.label);
      if (pl != null) look.points[i] = pl;
    }
    return look;
  }

  String catLabel(String x) {
    final l = xLabels[x];
    if (l != null && l.isNotEmpty) return l;
    if (xTime) {
      final m = _timeRx.firstMatch(x.trim());
      if (m != null) return '${m.group(1)}${m.group(2)}${m.group(3)}';
    }
    return x;
  }

  final series = <SapChartSeries>[];
  final categories = <String>[];
  if (xy) {
    for (final g in groups) {
      final pts = byGroup[g]!;
      series.add(
        SapChartSeries(
          label: yLabels[g] ?? g,
          values: [for (final p in pts) yOf(p.yval)],
          keys: [for (final p in pts) p.xval],
          xs: [for (final p in pts) xOf(p.xval)],
          pointLabels: [for (final p in pts) p.label],
          color: colorOf(g),
          style: styleOf(g),
          gfw: lookOf(g, pts),
        ),
      );
    }
  } else {
    final index = <String, int>{};
    for (final r in rows) {
      index.putIfAbsent(r.xval, () {
        categories.add(catLabel(r.xval));
        return categories.length - 1;
      });
    }
    final keys = [for (final e in index.entries) e.key];
    for (final g in groups) {
      final values = List<double?>.filled(keys.length, null);
      final labels = List<String>.filled(keys.length, '');
      final look = lookOf(g, const []);
      for (final p in byGroup[g]!) {
        final i = index[p.xval]!;
        values[i] = yOf(p.yval);
        labels[i] = p.label;
        if (p.curef.isNotEmpty) {
          final pl = gfwPointLook(cu, p.curef, p.label);
          if (pl != null) look.points[i] = pl;
        }
      }
      series.add(
        SapChartSeries(
          label: yLabels[g] ?? g,
          values: values,
          keys: List.of(keys),
          pointLabels: labels,
          color: colorOf(g),
          style: styleOf(g),
          gfw: look,
        ),
      );
    }
  }
  return SapChartModel(
    shell: shell,
    container: container,
    chartType: type,
    title: title,
    categories: categories,
    series: series,
    xAxisTitle: axisTitle(gfwPortXAxis),
    yAxisTitle: axisTitle(gfwPortYAxis),
    xTime: xy && xTime,
    yTime: yTime,
    events: events,
    gfw: gfwChartLook(cu, groups.isEmpty ? 1 : styleOf(groups.first),
        language: language),
  );
}

// ---------------------------------------------------------------------------
// The look the customizing sends (CL_CU_* bundles; nested display contexts
// at base + attribute, CL_CU_DISPLAY_CONTEXT: 0 visibility, 6 pattern,
// 11 colour fading, 19 second (gradient / pattern) colour, 33 line colour,
// 37 line style, 53 area style, 71 text colour, 77 font size, 102
// background colour, 104 marker style, 106 marker colour)
// ---------------------------------------------------------------------------

/// CL_CU bundle ids beyond the ones above.
const int gfwBundleDisplayContext = 0;
const int gfwBundleDiagram = 2;
const int gfwBundleScale = 4;
const int gfwBundleGrid = 5;
const int gfwBundleDataSheet = 7;
const int gfwBundlePoint = 8;

/// An area fill of a display context (at [base]).
class GfwFill {
  GfwFill({this.color, this.color2, this.area = 0, this.fading = 0, this.pattern = 0});

  /// CO_BG_CLR_PLT_ID (102): the fill colour (a gradient's first).
  int? color;

  /// CO_CLR_PLT_ID (19): a gradient's / pattern's second colour.
  int? color2;

  /// CO_AREA_STYLE (53): 0 solid, 1 none, 2 gradient, 3 pattern (read from
  /// the recorded charts: PRES1's March point 2 = yellow → orange, its
  /// January point 3 = hatched, the y value range 2 = red ↔ white).
  int area;

  /// CO_COLOR_FADING (11): a gradient's run — 0 [color] at the top to
  /// [color2] at the bottom, 3 [color2] at both edges and [color] in the
  /// middle (PRES1's value range band: red → white → red).
  int fading;

  /// CO_PATTERN_STYLE (6): the hatch of [area] 3 (6 = horizontal lines,
  /// PRES1's January Company 2).
  int pattern;

  bool get gradient => area == 2;
  bool get hatched => area == 3;

  @override
  String toString() => 'GfwFill($color/$color2 area $area fading $fading pattern $pattern)';
}

GfwFill? _fillAt(String? Function(int attr) v, int base) {
  int? n(int a) => int.tryParse((v(base + a) ?? '').trim());
  if (v(base + 102) == null && v(base + 53) == null) return null;
  return GfwFill(
    color: n(102),
    color2: n(19),
    area: n(53) ?? 0,
    fading: n(11) ?? 0,
    pattern: n(6) ?? 0,
  );
}

/// A data point's own customizing (a CL_CU_POINT bundle keyed by the
/// point's CU_REFOBJ).
class GfwPointLook {
  GfwPointLook({this.fill, this.label, this.labelBg, this.noLine = false});

  /// The point's area (its display context, base 500).
  GfwFill? fill;

  /// The label the chart writes at the point: its DC text when the bundle
  /// switches CO_AUTO (3) off (PRES1's 'Caffeine record' on Point1).
  String? label;

  /// The label box's colour (label context base 1000, 102).
  int? labelBg;

  /// CO_BL_STYLE 1 in the point's display context: no line segment into
  /// the point (GFW_PROG_TIME_AXIS's point 4, "used to create a gap").
  bool noLine;

  @override
  String toString() => 'GfwPointLook($fill label=$label noLine=$noLine)';
}

/// The CL_CU_POINT bundle keyed [curef], null when none is sent.
GfwPointLook? gfwPointLook(GfwCustomizing cu, String curef, String text) {
  String? v(int a) => cu.valueAt(gfwBundlePoint, a, key: curef);
  if (!cu.ports.any((p) => p.$1.$2 == gfwBundlePoint && p.$2 == curef)) {
    return null;
  }
  final auto = (v(3) ?? 'X').trim() == 'X';
  return GfwPointLook(
    fill: _fillAt(v, 500),
    label: !auto && text.trim().isNotEmpty ? text.trim() : null,
    labelBg: int.tryParse((v(1102) ?? '').trim()),
    noLine: (v(537) ?? '').trim() == '1',
  );
}

/// A series' customizing (its values bundle, else the one for all).
class GfwSeriesLook {
  GfwSeriesLook({
    this.fill,
    this.line,
    this.marker,
    this.markerStyle,
    this.lineStyle,
    Map<int, GfwPointLook>? points,
  }) : points = points ?? {};

  /// Palette ids: area background (1102), line / outline (1033), marker
  /// (1106).
  int? fill, line, marker;

  /// CO_MR_STYLE (1104): 1 square (GFW_PROG_TIME_AXIS), 2 diamond
  /// (GFW_PROG_MTA's "Raute"), 8 circle (GFW_PROG_SPEEDOMETER).
  int? markerStyle;

  /// CO_BL_STYLE (1037): 1 none, 2 continuous.
  int? lineStyle;

  /// Point index -> the point's own customizing.
  final Map<int, GfwPointLook> points;

  /// The normal density a histogram (style 89) overlays; null without.
  double? distMean, distSigma;
  String distTitle = '';

  @override
  String toString() =>
      'GfwSeriesLook(fill $fill line $line marker $marker/$markerStyle '
      'points $points dist $distMean/$distSigma)';
}

/// A value-range mark of the y axis (CL_CU_AXIS CO_MIN / OPT /
/// MAX_RANGE_VALUE 28 / 29 / 30, titled 7 / 9 / 11, shown by 31 / 32 / 33).
class GfwValueRange {
  GfwValueRange(this.value, this.title);
  final double value;
  final String title;

  @override
  String toString() => 'GfwValueRange($value "$title")';
}

/// The chart-wide customizing the GFW view draws.
class GfwChartLook {
  GfwChartLook({required this.style});

  /// The first series' CO_STYLE.
  final int style;

  /// The adapter's SetLanguage (sy-langu: 'F', 'D', 'E', …).
  String language = '';

  /// The title's text colour / size (the drawing area's title context,
  /// base 1000: 71 / 77 — PRES1 7 red, 18 pt).
  int? titleColor;
  int? titleSize;

  /// The y axis' fixed range (CO_MIN_VALUE 3 / CO_MAX_VALUE 4 when
  /// CO_MIN / MAX_VALUE_AUTO 13 / 14 are off — PRES1 0 … 210).
  double? yMin, yMax;

  /// The y scales' steps (CL_CU_SCALE CO_STEP 5 when CO_INTERVAL_AUTO 4 is
  /// off): the finer is the grid, the coarser the labels (PRES1 10 / 50).
  double? yGridStep, yLabelStep;

  /// The x axis' day width in mm when CO_DAY_WIDTH_AUTO (22) is off
  /// (CO_DAY_WIDTH 5 in 1/100 mm — GFW_PROG_TIME_AXIS 300 = 3 mm a day):
  /// the time axis opens at that zoom and pans.
  double? xDayWidthMm;

  /// The y axis' value-range marks and the band's fill (the axis' range
  /// context, base 2500).
  final List<GfwValueRange> ranges = [];
  GfwFill? rangeFill;

  /// The data sheet (CL_CU_DATA_SHEET) is shown: the values table under
  /// the x axis.
  bool dataTable = false;

  /// The x / y time axes' header cells' fill (the scale's display context
  /// 602 — GFW_PROG_MTA's GFWMTAX / GFWMTAY 50 ochre).
  int? headerFill;

  /// The legend box' colour (the drawing area's legend context 2102).
  int? legendBg;

  @override
  String toString() =>
      'GfwChartLook(style $style title $titleColor/$titleSize y $yMin..$yMax '
      'steps $yGridStep/$yLabelStep day ${xDayWidthMm}mm ranges $ranges '
      'band $rangeFill table $dataTable header $headerFill)';
}

/// The chart-wide look of [cu].
GfwChartLook gfwChartLook(GfwCustomizing cu, int style, {String language = ''}) {
  final l = GfwChartLook(style: style)..language = language;
  int? n(String? v) => int.tryParse((v ?? '').trim());
  bool on(String? v) => (v ?? '').trim() == 'X';
  l.titleColor = n(cu.valueAt(gfwBundleDrawingArea, 1071));
  l.titleSize = n(cu.valueAt(gfwBundleDrawingArea, 1077));
  l.legendBg = n(cu.valueAt(gfwBundleDrawingArea, 2102));
  String? ya(int a) => cu.valueAt(gfwBundleAxis, a, port: gfwPortYAxis);
  String? xa(int a) => cu.valueAt(gfwBundleAxis, a, port: gfwPortXAxis);
  if (ya(13) != null && !on(ya(13))) l.yMin = gfwNumber(ya(3) ?? '');
  if (ya(14) != null && !on(ya(14))) l.yMax = gfwNumber(ya(4) ?? '');
  final steps = <double>[
    for (final key in const ['1', '2'])
      if (cu.valueAt(gfwBundleScale, 4, port: gfwPortYAxis, key: key)
              case final auto?
          when !on(auto))
        if (gfwNumber(
              cu.valueAt(gfwBundleScale, 5, port: gfwPortYAxis, key: key) ??
                  '',
            )
            case final st? when st > 0)
          st,
  ]..sort();
  if (steps.isNotEmpty) {
    l.yGridStep = steps.first;
    l.yLabelStep = steps.last;
  }
  if (xa(22) != null && !on(xa(22))) {
    final w = gfwNumber(xa(5) ?? '');
    if (w != null && w > 0) l.xDayWidthMm = w / 100;
  }
  for (final (value, title, shown) in const [(28, 7, 31), (29, 9, 32), (30, 11, 33)]) {
    if (!on(ya(shown))) continue;
    final v = gfwNumber(ya(value) ?? '');
    final t = (ya(title) ?? '').trim();
    if (v != null && (t.isNotEmpty || v != 0)) l.ranges.add(GfwValueRange(v, t));
  }
  if (l.ranges.isNotEmpty) l.rangeFill = _fillAt(ya, 2500);
  // the data sheet bundle's display context visibility (500): PRES1's
  // GFW1T 'X' draws the table; GFW_DEMO_HIER3's GFWHIER3 and the
  // generated defaults leave it blank
  l.dataTable = on(cu.valueAt(gfwBundleDataSheet, 500));
  l.headerFill = n(cu.valueAt(gfwBundleScale, 602, port: gfwPortXAxis, key: '1')) ??
      n(cu.valueAt(gfwBundleScale, 602, port: gfwPortYAxis, key: '1'));
  return l;
}

/// The pushed state of one GFW chart.
class GfwChartState {
  List<GfwDataRow>? rows;
  List<GfwCuRow> customizing = const [];
  Map<String, String> xLabels = const {};
  Map<String, String> yLabels = const {};

  /// Apply one FILL_UPDATE delta (CL_GFW_GP_PRES_CHART->FILL_UPDATE's
  /// m_dc_data_tab bookkeeping: delete by objid, insert after PRED or
  /// first, change in place).
  void applyUpdate(List<(GfwDataRow, String, int)> delta) {
    final list = rows ??= [];
    for (final (r, pred, mode) in delta) {
      final at = list.indexWhere((x) => x.objid == r.objid);
      switch (mode) {
        case 1:
          if (at >= 0) list.removeAt(at);
        case 3:
          if (at >= 0) list.removeAt(at);
          final p = pred.isEmpty
              ? -1
              : list.indexWhere((x) => x.objid == pred);
          list.insert(pred.isEmpty ? 0 : p + 1, r);
        default:
          if (at >= 0) {
            list[at]
              ..grpid = r.grpid
              ..xval = r.xval
              ..yval = r.yval
              ..curef = r.curef
              ..label = r.label;
          } else {
            list.add(r);
          }
      }
    }
  }
}
