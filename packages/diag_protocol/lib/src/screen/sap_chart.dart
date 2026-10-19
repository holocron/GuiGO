/// SAP Chart Engine controls (`SAPGraphics.Chart.1`, CL_GUI_CHART_ENGINE —
/// the DBACOCKPIT/DB50 metric histories, GRAPHICS_GUI_CE_DEMO, …): the
/// chart's data and customizing XML the server pushes through the
/// DataProvider, decoded into series for rendering (read side only).
///
/// Wire shape (real SAP GUI for Windows, a recorded session
/// srv[28..36], ST04 → DB50/0219 "Historique des tailles de BD"):
/// * `CreateControl(263, SAPGUI.CONTAINERCTRL.1, …, 10)` +
/// `LinkContainer(263, CONTAINER_DB_SIZE_MEM_CHART)` — the custom
/// container bound to the dynpro's custom-control area;
/// * `CreateControl(264, SAPGraphics.Chart.1, …, 263)` — the chart, its
/// own flush; the client mints its handle (140 on that wire);
/// * a later flush hands it two X-R3TABLE DataProvider pushes
/// (`CreateObject({799104C5-…})` → `SetDataFromUrl(SAPR3://…)` →
/// `GetDataAsFormat` → `AssignProperty2(…, <handle>, XmlData)` and
/// `… XmlCustomizing`), each a UTF-8 XML document in the DATAASC column:
/// `<ChartData>` (or the demo's `<SimpleChartData>`) and
/// `<SAPChartCustomizing>` (chart type, title, …);
/// * every re-render (the GRTYPE metric switch, F5) re-pushes both under
/// fresh urls to the same handle.
/// The pushes name the chart only by the handle its creation minted, so the
/// shell is resolved through the session's alias map (and, for a replayed
/// recording whose handles are the recording client's, the newest live
/// chart control).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../cfw/dp_cache.dart';
import '../cfw/flush_call.dart';
import 'sap_barchart.dart' show isBarChartClass;
import 'sap_gfw_chart.dart';

/// One data series of a chart.
class SapChartSeries {
  SapChartSeries({
    required this.label,
    List<double?>? values,
    List<String>? keys,
    List<double?>? xs,
    List<String>? pointLabels,
    this.color,
    this.style,
    this.gfw,
  }) : values = values ?? [],
       keys = keys ?? [],
       xs = xs ?? [],
       pointLabels = pointLabels ?? [];

  /// The series label (`Mémoire occupée (Go)`).
  String label;

  /// The point values in order; null where a point carries no number.
  List<double?> values;

  /// Each point's x / time key (`20231223`), parallel to [values]; for a
  /// `<SimpleChartData>` document the category of the point.
  List<String> keys;

  /// An xy chart's x value per point, parallel to [values] (a GFW scatter /
  /// milestone trend / time axis: a number, or a time in days since
  /// 1970-01-01 when [SapChartModel.xTime]); empty for a category chart.
  List<double?> xs;

  /// Each point's own text (a GFW data container object's TEXT), parallel
  /// to [values]; empty when the wire carries none.
  List<String> pointLabels;

  /// The series' colour as the customizing names it: a GFW palette id
  /// (CL_CU_DISPLAY_CONTEXT *_CLR_PLT_ID — 3 blue, 5 green, 7 red, …);
  /// null = the chart's automatic colour.
  int? color;

  /// The GFW values style (CL_CU_VALUES=>CO_STYLE) the series is drawn in;
  /// null outside the GFW chart.
  int? style;

  /// The GFW series' customizing (colours, markers, point overrides, a
  /// histogram's density); null outside the GFW chart.
  GfwSeriesLook? gfw;

  @override
  String toString() => 'SapChartSeries($label: ${values.length} points)';
}

/// One chart control as last pushed.
class SapChartModel {
  SapChartModel({
    required this.shell,
    this.container,
    this.chartType = '',
    this.title = '',
    List<String>? categories,
    List<SapChartSeries>? series,
    this.xAxisTitle = '',
    this.yAxisTitle = '',
    this.xTime = false,
    this.yTime = false,
    Set<int>? events,
    this.gfw,
  }) : categories = categories ?? [],
       series = series ?? [],
       events = events ?? {};

  /// The chart control's kernel shell id (`264`).
  String shell;

  /// The dynpro custom-control (container) name hosting the chart
  /// (`CONTAINER_DB_SIZE_MEM_CHART`) — a key of `ScreenModel.containers`
  /// for its geometry; null when the wire never linked one.
  String? container;

  /// The customizing's default chart type (`TimeScatter`, `Columns`,
  /// `Lines`, `Bars`, `Pie`, `Area`, …); '' when the server sent none — the
  /// Chart Engine then draws its default, columns.
  String chartType;

  /// The chart title (the customizing's ChartElements/Title caption); ''
  /// when the wire carries none.
  String title;

  /// The x-axis categories in order.
  List<String> categories;

  List<SapChartSeries> series;

  /// The axis titles (a GFW axis bundle's CO_TITLE); '' when none.
  String xAxisTitle, yAxisTitle;

  /// An xy chart's x values are times (days since 1970-01-01, the series'
  /// [SapChartSeries.xs]); the y values are times ([SapChartSeries.values]:
  /// a GFW milestone trend analysis plots dates on both axes).
  bool xTime, yTime;

  /// The control events the server registered on the chart
  /// (`RegisterEvent(<chart>, id)`: the GFW chart's 13 value changed /
  /// 14 label changed / 6 custom changed / 12 selected / 16 double click).
  /// None of them is a plain click the view fires.
  Set<int> events;

  /// The GFW chart's customizing (title font, value ranges, scales, data
  /// table, …); null outside the GFW chart.
  GfwChartLook? gfw;

  @override
  String toString() =>
      'SapChartModel($shell${container == null ? '' : ' in $container'} '
      '$chartType "$title": ${categories.length} categories, '
      '${series.length} series)';
}

// ---------------------------------------------------------------------------
// The XML documents
// ---------------------------------------------------------------------------

/// A decoded `<ChartData>` / `<SimpleChartData>` document.
class SapChartData {
  SapChartData(this.categories, this.series);
  final List<String> categories;
  final List<SapChartSeries> series;
}

/// A decoded `<SAPChartCustomizing>` document (the parts read so far).
class SapChartCustomizing {
  SapChartCustomizing({this.chartType = '', this.title = ''});
  final String chartType;
  final String title;
}

final RegExp _seriesRx = RegExp(
  r'<Series\b([^>]*)>(.*?)</Series>',
  dotAll: true,
);
final RegExp _labelRx = RegExp(r'''\blabel\s*=\s*(?:"([^"]*)"|'([^']*)')''');
final RegExp _pointRx = RegExp(r'<Point\b[^>]*>(.*?)</Point>', dotAll: true);
final RegExp _valueRx = RegExp(
  r'''<Value\b[^>]*?\btype\s*=\s*["']([^"']*)["'][^>]*>(.*?)</Value>''',
  dotAll: true,
);
final RegExp _chartTypeRx = RegExp(
  r'<ChartType>(.*?)</ChartType>',
  dotAll: true,
);
final RegExp _captionRx = RegExp(r'<Caption>(.*?)</Caption>', dotAll: true);

List<String> _elements(String doc, String tag) => [
  for (final m in RegExp(
    '<$tag(?:\\s[^>]*)?>(.*?)</$tag>',
    dotAll: true,
  ).allMatches(doc))
    _unescape(m.group(1)!.trim()),
];

/// The span between `<tag…>` and `</tag>` (first occurrence), or null.
String? _span(String doc, String tag) {
  final m = RegExp(
    '<$tag(?:\\s[^>]*)?>(.*?)</$tag>',
    dotAll: true,
  ).firstMatch(doc);
  return m?.group(1);
}

String _unescape(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_unescapeRx, (m) {
    final e = m.group(1)!;
    // a reference past U+10FFFF (or too long to parse) stays as written
    // (audit 2026-10-17 P0-3)
    if (e.startsWith('#')) {
      final v = e.startsWith('#x')
          ? int.tryParse(e.substring(2), radix: 16)
          : int.tryParse(e.substring(1));
      return v != null && v <= 0x10FFFF ? String.fromCharCode(v) : m.group(0)!;
    }
    return switch (e) {
      'amp' => '&',
      'lt' => '<',
      'gt' => '>',
      'quot' => '"',
      'apos' => "'",
      _ => m.group(0)!,
    };
  });
}

double? _number(String s) => double.tryParse(s.trim());

/// Decode a chart data document: `<ChartData>` (categories + series of
/// `<Point>`s with a `y` value and a `time`/`x` key — the DBACOCKPIT
/// histories) or `<SimpleChartData>` (categories `<C>` + series of bare
/// `<S>` values — GRAPHICS_GUI_CE_DEMO). Null when [xml] holds neither.
SapChartData? parseChartDataXml(String xml) {
  final simple = _span(xml, 'SimpleChartData');
  if (simple != null) {
    final cats = _elements(_span(simple, 'Categories') ?? '', 'C');
    final series = <SapChartSeries>[];
    for (final m in _seriesRx.allMatches(simple)) {
      final values = [for (final v in _elements(m.group(2)!, 'S')) _number(v)];
      series.add(
        SapChartSeries(
          label: _labelOf(m.group(1)!),
          values: values,
          keys: [
            for (var i = 0; i < values.length; i++)
              i < cats.length ? cats[i] : '',
          ],
        ),
      );
    }
    return SapChartData(cats, series);
  }
  final doc = _span(xml, 'ChartData');
  if (doc == null) return null;
  final cats = _elements(_span(doc, 'Categories') ?? '', 'Category');
  final series = <SapChartSeries>[];
  for (final m in _seriesRx.allMatches(doc)) {
    final s = SapChartSeries(label: _labelOf(m.group(1)!));
    for (final p in _pointRx.allMatches(m.group(2)!)) {
      String? y, key;
      for (final v in _valueRx.allMatches(p.group(1)!)) {
        final type = v.group(1)!.trim().toLowerCase();
        final text = _unescape(v.group(2)!.trim());
        if (type == 'y') {
          y = text;
        } else if (type == 'time' || type == 'x') {
          key ??= text;
        }
      }
      s.values.add(y == null ? null : _number(y));
      s.keys.add(key ?? '');
    }
    series.add(s);
  }
  return SapChartData(cats, series);
}

String _labelOf(String attrs) {
  final m = _labelRx.firstMatch(attrs);
  return _unescape((m?.group(1) ?? m?.group(2) ?? '').trim());
}

/// Decode a `<SAPChartCustomizing>` document: the default chart type
/// (GlobalSettings/Defaults/ChartType) and the chart title
/// (Elements/ChartElements/Title/Caption — not an axis title). Null when
/// [xml] is not one.
SapChartCustomizing? parseChartCustomizingXml(String xml) {
  final doc = _span(xml, 'SAPChartCustomizing');
  if (doc == null) return null;
  final defaults = _span(_span(doc, 'GlobalSettings') ?? '', 'Defaults');
  final type =
      _chartTypeRx.firstMatch(defaults ?? '') ?? _chartTypeRx.firstMatch(doc);
  final title = _span(_span(doc, 'ChartElements') ?? '', 'Title');
  final caption = _captionRx.firstMatch(title ?? '');
  return SapChartCustomizing(
    chartType: _unescape((type?.group(1) ?? '').trim()),
    title: _unescape((caption?.group(1) ?? '').trim()),
  );
}

// ---------------------------------------------------------------------------
// Folding the flushes
// ---------------------------------------------------------------------------

/// The roles the Chart Engine's data / customizing pushes bind under.
const String _dataRole = 'XmlData';
const String _customizingRole = 'XmlCustomizing';

/// A chart control class: the Chart Engine's, the GFW business graphic's
/// Graphitti chart / Java CHTChart — not the GFW chart ADAPTER, whose Java
/// bean class (`com.sap.components.controls.chart.Adapter`) also says
/// chart — and not the SAPbarc.OCX bar chart (`SAPGUI.BarchartGraphics.1`,
/// GRAL BARCOCX1: a Gantt chart fed by its own sapbarc-stream,
/// sap_barchart.dart; claimed here it drew "(no chart data)").
bool _isChartClass(String cls) =>
    cls.toLowerCase().contains('chart') &&
    !isGfwAdapterClass(cls) &&
    !isBarChartClass(cls);

final RegExp _digits = RegExp(r'^\d{1,9}$');

/// The chart state of one session: the control facts the binding needs
/// (creation class, parent, container links — folded from every complete
/// flush) and the latest pushed document pair per chart shell.
class SapChartTracker {
  /// shell -> creation class (`SAPGraphics.Chart.1`, …)
  final Map<String, String> classOf = {};

  /// shell -> the parent shell its CreateControl named
  final Map<String, String> parentOf = {};

  /// container shell -> the dynpro custom-control name `LinkContainer`
  /// bound it to
  final Map<String, String> linkedName = {};

  /// chart-class shells in creation order (a re-created shell moves last)
  final List<String> chartShells = [];

  final Map<String, SapChartData> _data = {};
  final Map<String, SapChartCustomizing> _custom = {};

  /// GFW chart adapter shell -> the chart shell it feeds (the chart its
  /// CL_GFW_GP_PRES_CHART constructor created just before it in the same
  /// parent; its `LoadURL(<chart handle>)` when that resolves)
  final Map<String, String> adapterOf = {};

  /// GFW adapter shells in creation order
  final List<String> adapterShells = [];

  /// chart shell -> the event ids `RegisterEvent` registered on it
  final Map<String, Set<int>> eventsOf = {};

  /// chart shell -> the language its adapter's SetLanguage named
  final Map<String, String> languageOf = {};

  /// chart shell -> its GFW pushes (DATA / CUSTDATA / labels)
  final Map<String, GfwChartState> _gfw = {};

  /// Shells with a data push so far.
  Iterable<String> get shells => {
    ..._data.keys,
    for (final e in _gfw.entries)
      if (e.value.rows != null) e.key,
  };

  /// The dynpro container name hosting [shell]: the nearest ancestor (or
  /// the shell itself) a `LinkContainer` named.
  String? containerOf(String shell) {
    var s = shell;
    for (var guard = 0; guard < 32; guard++) {
      final n = linkedName[s];
      if (n != null) return n;
      final p = parentOf[s];
      if (p == null) return null;
      s = p;
    }
    return null;
  }

  /// The chart as last pushed to [shell], null when it has no data yet.
  SapChartModel? build(String shell) {
    final g = _gfw[shell];
    if (g != null && g.rows != null) {
      return buildGfwChart(
        shell: shell,
        container: containerOf(shell),
        rows: [
          for (final r in g.rows!)
            GfwDataRow(
              curef: r.curef,
              grpid: r.grpid,
              xval: r.xval,
              yval: r.yval,
              objid: r.objid,
              label: r.label,
            ),
        ],
        customizing: g.customizing,
        xLabels: g.xLabels,
        yLabels: g.yLabels,
        events: {...?eventsOf[shell]},
        language: languageOf[shell] ?? '',
      );
    }
    final d = _data[shell];
    if (d == null) return null;
    final c = _custom[shell];
    return SapChartModel(
      shell: shell,
      container: containerOf(shell),
      chartType: c?.chartType ?? '',
      title: c?.title ?? '',
      categories: List.of(d.categories),
      series: [
        for (final s in d.series)
          SapChartSeries(
            label: s.label,
            values: List.of(s.values),
            keys: List.of(s.keys),
          ),
      ],
      events: {...?eventsOf[shell]},
    );
  }

  /// Fold one complete OLE_FLUSH_CALL RFC value: record its control facts,
  /// then its chart pushes. [shellOf] resolves a push's owner handle (the
  /// session's alias map: our minted handle -> kernel shell); [isLive]
  /// rejects a destroyed control for the owner-less fallback. Returns the
  /// chart shells whose data or customizing changed. [parsed] = [rfc]
  /// already parsed.
  Set<String> foldCall(
    Uint8List rfc, {
    String? Function(String owner)? shellOf,
    bool Function(String shell)? isLive,
    FlushCall? parsed,
  }) {
    final call = parsed ?? parseFlushCall(rfc);
    final bindings = [
      for (final b in dpPushBindings(call))
        if (b.role == _dataRole ||
            b.role == _customizingRole ||
            gfwAdapterRoles.contains(b.role))
          b,
    ];
    if (bindings.isEmpty) {
      _recordControls(call, shellOf);
      return const {};
    }
    final cache = DpCache()..ingestValue(rfc);
    return foldParsed(call, cache.byUrl, shellOf: shellOf, isLive: isLive);
  }

  /// [foldCall] over an already parsed call whose DataProvider pushes are
  /// [pushes] (url -> segment).
  Set<String> foldParsed(
    FlushCall call,
    Map<String, Uint8List> pushes, {
    String? Function(String owner)? shellOf,
    bool Function(String shell)? isLive,
  }) {
    _recordControls(call, shellOf);
    final bindings = [
      for (final b in dpPushBindings(call))
        if (b.role == _dataRole ||
            b.role == _customizingRole ||
            gfwAdapterRoles.contains(b.role))
          b,
    ];
    if (bindings.isEmpty) return const {};
    final touched = <String>{};
    for (final b in bindings) {
      if (gfwAdapterRoles.contains(b.role)) {
        final shell = _gfwChartOf(b, shellOf, isLive);
        if (shell == null) continue;
        for (final u in b.urls) {
          final seg = pushes[u];
          if (seg == null) continue;
          if (_foldGfw(shell, b.role!, seg)) touched.add(shell);
        }
        continue;
      }
      final shell = _chartOf(b, shellOf, isLive);
      if (shell == null) continue;
      for (final u in b.urls) {
        final seg = pushes[u];
        if (seg == null) continue;
        final xml = _documentOf(seg);
        if (xml == null) continue;
        if (b.role == _dataRole) {
          final d = parseChartDataXml(xml);
          if (d == null) continue;
          _data[shell] = d;
        } else {
          final c = parseChartCustomizingXml(xml);
          if (c == null) continue;
          _custom[shell] = c;
        }
        touched.add(shell);
      }
    }
    return touched;
  }

  void _recordControls(
    FlushCall call, [
    String? Function(String owner)? shellOf,
  ]) {
    for (var i = 1; i <= call.verbs.length; i++) {
      final verb = call.verbs[i - 1];
      if (verb.startsWith('CreateControl')) {
        final a = verbNamedArgs(call, i);
        final shell = (a['#1'] ?? '').trim();
        if (!_digits.hasMatch(shell)) continue;
        final cls = (a['#2'] ?? '').trim();
        classOf[shell] = cls;
        final parent = (a['#4'] ?? '').trim();
        if (_digits.hasMatch(parent)) {
          parentOf[shell] = parent;
        } else {
          parentOf.remove(shell);
        }
        linkedName.remove(shell); // a reused shell id is a new control
        chartShells.remove(shell);
        adapterShells.remove(shell);
        adapterOf.remove(shell);
        eventsOf.remove(shell);
        _gfw.remove(shell);
        if (isGfwAdapterClass(cls)) {
          // CL_GFW_GP_PRES_CHART->CONSTRUCTOR: the chart, then its adapter
          // in the same parent
          adapterShells.add(shell);
          for (final c in chartShells.reversed) {
            if (parentOf[c] == parentOf[shell]) {
              adapterOf[shell] = c;
              break;
            }
          }
        } else if (_isChartClass(cls)) {
          chartShells.add(shell);
        }
      } else if (verb == 'LinkContainer') {
        final a = verbNamedArgs(call, i);
        final shell = (a['#1'] ?? '').trim();
        final name = (a['#2'] ?? '').trim();
        if (_digits.hasMatch(shell) && name.isNotEmpty) {
          linkedName[shell] = name;
        }
      } else if (verb == 'SetLanguage' && adapterShells.isNotEmpty) {
        // adapter SetLanguage(sy-langu): the month names of a time axis
        final lang = (verbNamedArgs(call, i)['#1'] ?? '').trim();
        final own = shellOf?.call(verbMeta(call)[i - 1].objValue.trim());
        final chart =
            adapterOf[own ?? ''] ?? adapterOf[adapterShells.last];
        if (chart != null && lang.isNotEmpty) languageOf[chart] = lang;
      } else if (verb == 'LoadURL' && shellOf != null) {
        // adapter LoadURL(<the chart's h_control-obj>): both handles the
        // client minted, resolved through the alias map
        final adapter = shellOf(verbMeta(call)[i - 1].objValue.trim());
        final chart = shellOf((verbNamedArgs(call, i)['#1'] ?? '').trim());
        if (adapter != null &&
            chart != null &&
            adapterShells.contains(adapter) &&
            _isChart(chart)) {
          adapterOf[adapter] = chart;
        }
      }
    }
    for (final (shell, id) in call.registeredEvents) {
      if (_isChart(shell)) (eventsOf[shell] ??= {}).add(id);
    }
  }

  /// The chart shell a GFW adapter push feeds: its owner handle's adapter
  /// (through the alias map, else taken as a shell), else — a replayed
  /// recording keeps the recording client's handles — the newest live
  /// adapter's chart.
  String? _gfwChartOf(
    DpPushBinding b,
    String? Function(String owner)? shellOf,
    bool Function(String shell)? isLive,
  ) {
    final owner = b.owner?.trim() ?? '';
    for (final c in [
      b.shell?.trim(),
      if (owner.isNotEmpty) ...[shellOf?.call(owner), owner],
    ]) {
      if (c == null) continue;
      final chart = adapterOf[c];
      if (chart != null) return chart;
      if (_isChart(c)) return c;
    }
    for (final a in adapterShells.reversed) {
      final chart = adapterOf[a];
      if (chart != null && (isLive?.call(a) ?? true)) return chart;
    }
    return null;
  }

  /// Fold one GFW adapter push of [role] into [shell]'s chart; whether it
  /// changed what the chart draws.
  bool _foldGfw(String shell, String role, Uint8List seg) {
    final g = _gfw[shell] ??= GfwChartState();
    switch (role) {
      case gfwData:
        g.rows = parseGfwData(seg);
      case gfwUpdateData:
        g.applyUpdate(parseGfwUpdate(seg));
      case gfwCustData:
        g.customizing = parseGfwCustomizing(seg);
      case gfwXLabel:
        g.xLabels = parseGfwLabels(seg);
      case gfwYLabel:
        g.yLabels = parseGfwLabels(seg);
      default:
        return false;
    }
    return g.rows != null;
  }

  bool _isChart(String? shell) =>
      shell != null && _isChartClass(classOf[shell] ?? '');

  String? _chartOf(
    DpPushBinding b,
    String? Function(String owner)? shellOf,
    bool Function(String shell)? isLive,
  ) {
    final owner = b.owner?.trim();
    final candidates = [
      b.shell?.trim(),
      if (owner != null && owner.isNotEmpty) ...[shellOf?.call(owner), owner],
    ];
    for (final c in candidates) {
      if (_isChart(c)) return c;
    }
    // the handle resolves to no chart we saw created (a replayed recording
    // keeps the recording client's handles): the newest live chart control
    for (final s in chartShells.reversed) {
      if (isLive?.call(s) ?? true) return s;
    }
    return null;
  }
}

/// The UTF-8 XML document a chart push carries in its DATAASC column
/// (trailing cell padding dropped), or null when the column is empty.
String? _documentOf(Uint8List seg) {
  final (_, _, cells) = dpColumnCells(seg, 'DATAASC');
  if (cells.isEmpty) return null;
  final b = BytesBuilder(copy: false);
  for (final c in cells) {
    b.add(c);
  }
  final text = utf8.decode(b.takeBytes(), allowMalformed: true);
  final start = text.indexOf('<');
  return start < 0 ? null : text.substring(start).trimRight();
}

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call (audit #7 / zcode P-12).
final RegExp _unescapeRx = RegExp(r'&(#x[0-9a-fA-F]+|#\d+|\w+);');
