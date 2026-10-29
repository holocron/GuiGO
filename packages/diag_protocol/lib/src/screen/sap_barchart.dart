/// The SAP bar chart (SAPbarc.OCX, `SAPGUI.BarchartGraphics.1` — the
/// Gantt-style "diagramme à barres" of GRAL BARCOCX1, BARCHART_CREATE /
/// CL_GUI_BARCHART of package SGRC, function group BARC): its
/// `sapbarc-stream` decoded into charts, table rows, bars and symbols, the
/// LoadCUACode function-code round and the command-stream read-back.
///
/// Control pair (the test system BARCOCX1 + a recorded session srv[19]
/// / [41], a recorded session srv[12]): BARCHART_CREATE →
/// CONTROL_CREATE 'BALK' → `CreateControl(<shell>,
/// SAPGUI.BarchartGraphics.1, 1342177280, <parent>)`, then one flush
/// `LinkControl(<shell>, BARCOCX1, 300)`, `SetProperty(<shell>, 10, 15)`,
/// `RegisterOcxEvent(<shell>, 1)`, `SetLanguage`, `useStreaming`,
/// `OpenBracket(0, 0)`, the data pushes, `CloseBracket`. It is NO GFW /
/// Graphitti business chart (the class name only says chart).
///
/// Data path (BARC_GRAPHIC_PBO, LBARCF01 send routines): a DataProvider
/// push per table, each `CreateObject(GuiDataProvider)` →
/// `SetDataFromUrl(APPLICATION, <subtype>, SAPR3://…)` → `GetDataAsFormat`
/// → `AssignProperty2(<dp>, <member>, <control handle>, <property>)`:
/// * the `/$SECTION` stream itself: subtype `sapbarc-stream`, member ''
/// and property `DATA` — the NetPlan carrier ([netPlanStreamBytes]);
/// the header after a section name is its record arity (`/$HLTS 4`);
/// * the value tables the stream only names (`/$FVALS 4` + `/$DPFVALS
/// 1`): X-R3TABLE pushes, member `r3TableAutoObj`, properties
/// `DPFVALSDATA` (format id i4 | field c1 | key c2 | value c48),
/// `DP1BVALSDATA` (box id i4 | key c2 | value c240), `DP1NVALSDATA`
/// (node id i4 | chart i4 | key c2 | value c240), `DPCALVALSDATA`
/// (calendar id i4 | key c2 | value c54), `DPPOSDATA` (chart i4 |
/// kind c1 N/B | object id i4 | row c8) — the INT4 columns little
/// endian, aligned to 4 in the row (the FORMAT descriptor's offsets are
/// unaligned: DPPOSDATA is 4+1+3 pad+4+8 = 20 B).
/// A later push of the same stream without `/$CHARTS` is a delta (the
/// status line `/$OUTPUT`, a new `/$TITLE` — barcocx1_open srv[16] / [24]).
///
/// Function codes (BARCHART_SET_FUNCTION_CODE, the toolbar / menu of the
/// GRAFIK status): `LoadCUACode(<code>)`, VT_I2 result — `1` = the control
/// applied the code itself, no read-back follows (OZIN, OZOU, SALL, UALL:
/// a recorded session g[16] / [19] / [27] / [30]);
/// `0` = it queued a command for the program (XBO5, barcocx1_open g[15];
/// ODEL, interactions g[22]); then the server reads the command stream
/// back — `Force(APPLICATION, sapbarc-stream)`, `AssignProperty2(<handle>,
/// DATASTREAM, <dp>, stream)`, `SaveDataToUrl(…, SAPR3://<sink>)` and a
/// SAPLCNDP DP_GET_CLIENT_TABLE45A pull of that sink — answered DATASTR
/// `CACTBAR\nC<code>\0` for an unknown code (barcocx1_open g[17]),
/// `CADEL\nCn\nC<chart>\nC<node>\n\0` for Supprimer on the marked bar
/// (interactions g[24]; the mark is local, the click sends nothing), else
/// the empty stream (one NUL); TOTALSIZE = the DATASTR length with its NUL
/// (14 / 16 / 1). A bar drag is the OCX's event 1 (`%_GC <shell> 1`) and
/// an `AMOVENODE` read-back (interactions g[32] / g[34]) — read
/// ([barChartMoveOf]), never sent: its header tokens and date arithmetic
/// are not decoded.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../cfw/dp_cache.dart';
import '../cfw/flush_call.dart';
import '../cfw/reply_container.dart' show buildDpAnswer;
import '../framing/diag_frame.dart';
import '../framing/envelope.dart';
import '../session/frames.dart';
import 'sap_netplan.dart'
    show netPlanStreamBytes, netPlanPushSections, netPlanInlineSections;
import 'screen_model.dart';

// ---------------------------------------------------------------------------
// The control class
// ---------------------------------------------------------------------------

/// The bar chart OCX's creation class.
const String barChartClass = 'SAPGUI.BarchartGraphics.1';

/// Whether [cls] is the bar chart OCX (SAPbarc.OCX).
bool isBarChartClass(String cls) =>
    cls.trim().toUpperCase().startsWith('SAPGUI.BARCHARTGRAPHICS.');

// ---------------------------------------------------------------------------
// The model
// ---------------------------------------------------------------------------

/// A /$HLTS colour set: (id, line, fill, third) — the positional colours
/// of THLT. [line] draws a bar's / box's outline and a line layer, [fill]
/// the bar body / box background / ribbon cell / grid shading; [third] is
/// the text colour of a box (BLACK on the yellow table rows) and the
/// shadow of a bar. /$HVALS adds keyed attributes ([values]).
class BarChartHighlight {
  BarChartHighlight(this.id, this.line, this.fill, this.third,
      [Map<String, String>? values])
      : values = values ?? {};
  final String id;
  final String line;
  final String fill;
  final String third;
  final Map<String, String> values;
}

/// A /$FMTS text format: (id, kind, template) — kind N node / L layer /
/// B box / T table row; the template names the fields it shows
/// (`[$a/$b/$c]` = box values 1, 2, 3), and /$FVALS (DPFVALSDATA) their
/// attributes by field: `c` colour, `t` the table column (`01`…, `00` /
/// `99` none), `h` font height, `b` / `f` / `l` / `w` / `u` / `o` / `v`
/// the rest of the font and frame.
class BarChartFormat {
  BarChartFormat(this.id, this.kind, this.template);
  final String id;
  final String kind;
  final String template;

  /// field letter (`a`) -> attribute key (`c`) -> value
  final Map<String, Map<String, String>> fields = {};

  /// The template's field letters in order (`[$a/$b]` -> a, b).
  List<String> get fieldNames => [
        for (final m in _fieldRx.allMatches(template)) m.group(1)!,
      ];

  /// The colour name of [field] (`c`), null when unset.
  String? colorOf(String field) {
    final c = fields[field]?['c'];
    return c == null || c.isEmpty ? null : c;
  }

  /// The table column (1-based) [field] fills, null when it fills none.
  int? columnOf(String field) {
    final t = int.tryParse((fields[field]?['t'] ?? '').trim());
    return t == null || t <= 0 || t >= 99 ? null : t;
  }
}

final RegExp _fieldRx = RegExp(r'\$([a-z])');

/// The value index a template field letter shows (`a` -> 1).
int barChartFieldIndex(String letter) => letter.codeUnitAt(0) - 0x60;

/// One table-part object (/$BOXES: id, kind, chart, format, highlight):
/// kind `B` the chart's title cell over its table, `R` a table row (row 0
/// = the column header row). Its values (/$BVALS, DP1BVALSDATA) by key:
/// `0` the object's name, `1`… the cells its format's fields show.
class BarChartBox {
  BarChartBox({
    required this.id,
    required this.kind,
    required this.chart,
    this.format = '',
    this.highlight = '',
    Map<String, String>? values,
    this.row,
  }) : values = values ?? {};
  final String id;
  final String kind;
  final String chart;
  final String format;
  final String highlight;
  final Map<String, String> values;

  /// The table row (/$POSITION, DPPOSDATA kind `B`): 0 = the header row,
  /// null for a title cell.
  int? row;

  bool get isTitle => kind == 'B';
}

/// A /$MAKRO layer macro (`/f/1/s/2/h/300/o/-150/p/001/`): the node time
/// values the layer spans ([from] → [to], NVALS keys), the symbol shape a
/// symbol layer draws ([symbol], `t`), its height and vertical offset in
/// per-mille of the half row ([height] `h`, [offset] `o`, positive =
/// downwards), its drawing level ([priority] `p`, `001`).
class BarChartMacro {
  BarChartMacro({
    this.from,
    this.to,
    this.symbol,
    this.height,
    this.offset = 0,
    this.priority,
    Map<String, String>? raw,
  }) : raw = raw ?? {};
  final int? from;
  final int? to;
  final int? symbol;
  final double? height;
  final double offset;
  final String? priority;
  final Map<String, String> raw;

  static BarChartMacro parse(String text) {
    final parts = text.split('/').where((p) => p.isNotEmpty).toList();
    final raw = <String, String>{};
    for (var i = 0; i + 1 < parts.length; i += 2) {
      raw[parts[i].trim()] = parts[i + 1].trim();
    }
    // `h/2.000`: the server's own number format (thousands separator)
    double? num(String? v) => v == null
        ? null
        : double.tryParse(v.replaceAll('.', '').replaceAll(',', '.'));
    return BarChartMacro(
      from: int.tryParse(raw['f'] ?? ''),
      to: int.tryParse(raw['s'] ?? ''),
      symbol: int.tryParse(raw['t'] ?? ''),
      height: num(raw['h']),
      offset: num(raw['o']) ?? 0,
      priority: raw['p'],
      raw: raw,
    );
  }
}

/// A graphical element type (/$LAYERS: id, chart, kind, highlight): kind
/// `R` a bar (rectangle from one time value to another), `S` a symbol (a
/// milestone at one time value), `L` a line; its macro via /$LVALS key `M`.
class BarChartLayer {
  BarChartLayer(this.id, this.chart, this.kind, this.highlight, this.macro);
  final String id;
  final String chart;
  final String kind;
  final String highlight;
  final BarChartMacro macro;

  bool get isBar => kind == 'R';
  bool get isSymbol => kind == 'S';
  bool get isLine => kind == 'L';
}

/// The symbol shapes of a symbol layer's `t` = BCLAYSYTYP + 1 (LBARCFAZ
/// fill_layer_vals): 01 arrow down, 02 triangle down, 03 `>`, 04 narrow
/// triangle up, 05 triangle right, 06 triangle left, 07 rhombus, 08
/// hourglass, 09 narrow triangle down, 10 square, 11 circle; 12-21 the same
/// inside a circle. BARCOCX1's row 7 draws t 2…7 (the real GUI: a down
/// arrow, a triangle, a chevron, a slim triangle, a right and a left one).
enum BarChartSymbol {
  square,
  arrowDown,
  triangleDown,
  chevron,
  slimTriangleUp,
  triangleRight,
  triangleLeft,
  diamond,
  hourglass,
  slimTriangleDown,
  circle,
}

/// The shape of symbol type [t].
BarChartSymbol barChartSymbolOf(int? t) => switch (t) {
      2 => BarChartSymbol.arrowDown,
      3 => BarChartSymbol.triangleDown,
      4 => BarChartSymbol.chevron,
      5 => BarChartSymbol.slimTriangleUp,
      6 => BarChartSymbol.triangleRight,
      7 => BarChartSymbol.triangleLeft,
      8 => BarChartSymbol.diamond,
      9 => BarChartSymbol.hourglass,
      10 => BarChartSymbol.slimTriangleDown,
      11 => BarChartSymbol.square,
      12 => BarChartSymbol.circle,
      // 13-22: types 01-10 drawn inside a circle
      final n? when n >= 13 && n <= 22 => barChartSymbolOf(n - 11),
      _ => BarChartSymbol.square,
    };

/// One diagram-part object (/$NODES: id, chart, format, highlight) — the
/// carrier of a row's bars and symbols. /$NVALS (DP1NVALSDATA: node, chart,
/// key, value): `0` the node's name, `1`… its time values, `A` (repeated)
/// the layers it draws, `C` the calendar its bars follow.
class BarChartNode {
  BarChartNode({
    required this.id,
    required this.chart,
    this.format = '',
    this.highlight = '',
    Map<String, List<String>>? values,
    Map<int, DateTime>? times,
    List<String>? layers,
    this.calendar,
    this.row,
    this.selected = false,
  })  : values = values ?? {},
        times = times ?? {},
        layers = layers ?? [];
  final String id;
  final String chart;
  final String format;
  final String highlight;
  final Map<String, List<String>> values;
  final Map<int, DateTime> times;
  final List<String> layers;
  final String? calendar;

  /// Marked (selected): by a tap (local — the click sends nothing,
  /// interactions §3), by SALL, or by the server's NVALS `S 1`.
  final bool selected;

  /// The chart row the node is drawn in (/$POSITION kind `N`), 1-based.
  int? row;

  String get name => (values['0'] ?? const ['']).first;
}

/// A /$SECTION of the time axis: from [start] on, one [unit] is [width]
/// wide (SECTION: id, start, unit, size — hundredths of a millimetre, the
/// unit the customizing gives every length in; BARCOCX1 widens the middle
/// section of the demo to 100 a day).
class BarChartTimeSection {
  BarChartTimeSection(this.id, this.start, this.unit, this.width);
  final String id;
  final DateTime start;
  final int unit;
  final double width;
}

/// A header ribbon (/$RIBBON: id, chart, section, unit, highlight): one row
/// of the calendar header over [section] of [chart], one cell per [unit].
class BarChartRibbon {
  BarChartRibbon(this.id, this.chart, this.section, this.unit, this.highlight);
  final String id;
  final String chart;
  final String section;
  final int unit;
  final String highlight;
}

/// A time grid (/$GRIDS: id, chart, kind, section, value, highlight): kind
/// `C` shades the non-working times of calendar [value], `L` draws a line
/// at every [value] unit.
class BarChartGrid {
  BarChartGrid(
      this.id, this.chart, this.kind, this.section, this.value, this.highlight);
  final String id;
  final String chart;
  final String kind;
  final String section;
  final int value;
  final String highlight;

  bool get isCalendar => kind == 'C';
}

/// A working-time calendar (/$CALENDAR, /$CALVALS, /$PROFILE, /$PVALS,
/// /$TIMEOBJ, /$INTERVAL, /$IVALS): the weekdays it has off (a profile's
/// recurring time objects, `R 0 6` / `R 0 7` = Saturday / Sunday) and its
/// free intervals ([free], `[start, end)`).
class BarChartCalendar {
  BarChartCalendar(this.id);
  final String id;

  /// ISO weekdays off (6 Saturday, 7 Sunday).
  final Set<int> weekdaysOff = {};
  final List<(DateTime, DateTime)> free = [];

  /// Whether [t] is non-working time.
  bool isOff(DateTime t) {
    if (weekdaysOff.contains(t.weekday)) return true;
    for (final (a, b) in free) {
      if (!t.isBefore(a) && t.isBefore(b)) return true;
    }
    return false;
  }

  /// The non-working spans inside [from, to), day-granular, merged.
  List<(DateTime, DateTime)> offSpans(DateTime from, DateTime to) {
    final out = <(DateTime, DateTime)>[];
    if (!from.isBefore(to)) return out;
    var d = DateTime.utc(from.year, from.month, from.day);
    DateTime? open;
    var guard = 0;
    while (d.isBefore(to) && guard++ < 40000) {
      final next = d.add(const Duration(days: 1));
      if (isOff(d)) {
        open ??= d.isBefore(from) ? from : d;
      } else if (open != null) {
        out.add((open, d));
        open = null;
      }
      d = next;
    }
    if (open != null) out.add((open, to));
    return out;
  }
}

/// A date line (/$DATELIN: id, chart, date, highlight — the "Ligne de la
/// date…" XBO5 object).
class BarChartDateLine {
  BarChartDateLine(this.chart, this.highlight, this.date);
  final String chart;
  final String highlight;
  final DateTime date;
}

/// One chart of the control (/$CHARTS: id, flags, table columns, order,
/// height): its table part (column widths /$CLMWD, the boxes), its rows
/// (heights /$ROWWD), its header ribbons and grids, its nodes.
class BarChartChart {
  BarChartChart({
    required this.id,
    this.columns = 0,
    this.order = 0,
    this.height = 100,
    this.flags = '',
  });
  final String id;
  final int columns;
  final int order;

  /// The chart's share of the control's height (CHARTS field 5: the demo's
  /// 300 / 200 — the top chart is the taller).
  final double height;
  final String flags;

  /// Column widths in hundredths of a character (CLMWD: chart, column,
  /// width), by 1-based column.
  final Map<int, double> columnWidths = {};

  /// Row heights in per-mille of the standard row (ROWWD: chart, row,
  /// height), by row (0 = the header row).
  final Map<int, double> rowHeights = {};
  final List<BarChartBox> boxes = [];
  final List<BarChartNode> nodes = [];
  final List<BarChartRibbon> ribbons = [];
  final List<BarChartGrid> grids = [];
  final List<BarChartDateLine> dateLines = [];

  /// /$CVALS by key (LBARCF01 send_chart_vals): `3` the table-section
  /// colour, `4` the diagram-section colour, `2` the time scale's, `1` the
  /// title's (highlight ids), `f` / `n` the default box / node format, `b`
  /// / `t` the border / title box ids.
  final Map<String, String> values = {};

  /// The highlight of the diagram (time) area's background.
  String? get diagramHighlight => values['4'];

  /// The highlight of the table area's background.
  String? get tableHighlight => values['3'];

  /// The number of table columns drawn ([columns], else the widths given).
  int get columnCount =>
      math.max(columns, columnWidths.keys.fold(0, math.max));

  /// The data rows (1-based), the highest any box or node sits in.
  int get rowCount => _index()._rows;

  BarChartBox? get titleBox =>
      boxes.where((b) => b.isTitle).firstOrNull;
  BarChartBox? get headerBox =>
      boxes.where((b) => !b.isTitle && b.row == 0).firstOrNull;

  /// The table row box of [row] (the first non-title box placed there).
  BarChartBox? boxAt(int row) => _index()._boxByRow[row];

  /// The nodes drawn in [row], in the stream's order (read-only).
  List<BarChartNode> nodesAt(int row) =>
      _index()._nodesByRow[row] ?? const [];

  // The rows indexed once, on first use: [boxes] and [nodes] are only
  // filled inside [buildBarChart] (a change arrives as a fresh model), and
  // the painter asks per row per frame — a scan of every box and node per
  // question was O(rows x (boxes + nodes)) per paint, and the geometry's
  // row heights the same per pinch frame. Rebuilt when the lists grew (a
  // chart built by hand); a [BarChartBox.row] / [BarChartNode.row] set
  // after the first question is not seen.
  _BarChartRowIndex? _rowIndex;

  _BarChartRowIndex _index() {
    final i = _rowIndex;
    if (i != null && i._boxes == boxes.length && i._nodes == nodes.length) {
      return i;
    }
    return _rowIndex = _BarChartRowIndex(boxes, nodes);
  }

  /// The header ribbons, coarsest unit on top (months over weeks).
  List<int> get ribbonUnits {
    final u = {for (final r in ribbons) r.unit}.toList()
      ..sort((a, b) => barChartUnitDays(b).compareTo(barChartUnitDays(a)));
    return u;
  }
}

/// A chart's rows: the highest row, the first row box per row, the nodes
/// per row in order — what [BarChartChart.rowCount] / [BarChartChart.boxAt]
/// / [BarChartChart.nodesAt] answered by scanning.
class _BarChartRowIndex {
  _BarChartRowIndex(List<BarChartBox> boxes, List<BarChartNode> nodes)
      : _boxes = boxes.length,
        _nodes = nodes.length {
    final byRow = <int, List<BarChartNode>>{};
    for (final b in boxes) {
      final r = b.row;
      if (r == null) continue;
      if (r > _rows) _rows = r;
      if (!b.isTitle) _boxByRow.putIfAbsent(r, () => b);
    }
    for (final n in nodes) {
      final r = n.row;
      if (r == null) continue;
      if (r > _rows) _rows = r;
      (byRow[r] ??= []).add(n);
    }
    for (final MapEntry(key: r, value: ns) in byRow.entries) {
      _nodesByRow[r] = List.unmodifiable(ns);
    }
  }

  /// The list lengths indexed (a grown list is indexed again).
  final int _boxes, _nodes;
  int _rows = 0;
  final Map<int, BarChartBox> _boxByRow = {};
  final Map<int, List<BarChartNode>> _nodesByRow = {};
}

/// A bar chart control as last delivered.
class SapBarChartModel {
  SapBarChartModel({
    this.shell,
    this.container,
    this.title = '',
    this.status = '',
    required this.start,
    required this.end,
    List<BarChartTimeSection>? sections,
    List<BarChartChart>? charts,
    Map<String, BarChartHighlight>? highlights,
    Map<String, BarChartFormat>? formats,
    Map<String, BarChartLayer>? layers,
    Map<String, BarChartCalendar>? calendars,
    List<String>? monthNames,
    List<String>? dayNames,
    Map<String, String>? options,
    this.zoom = 0,
  })  : sections = sections ?? [],
        charts = charts ?? [],
        highlights = highlights ?? {},
        formats = formats ?? {},
        layers = layers ?? {},
        calendars = calendars ?? {},
        monthNames = monthNames ?? [],
        dayNames = dayNames ?? [],
        options = options ?? {};

  /// The hosting control's kernel shell; null for the inline carrier.
  final String? shell;

  /// The custom container hosting the control (null when it is linked to
  /// the whole dynpro — BARCOCX1's `LinkControl(…, BARCOCX1, 300)`).
  final String? container;
  final String title;

  /// The status line the control shows (/$OUTPUT: `Fin de l'opération
  /// chargement`).
  final String status;

  /// The time axis (/$TIME: start; end).
  final DateTime start;
  final DateTime end;
  final List<BarChartTimeSection> sections;

  /// The charts top to bottom (CHARTS order).
  final List<BarChartChart> charts;
  final Map<String, BarChartHighlight> highlights;
  final Map<String, BarChartFormat> formats;
  final Map<String, BarChartLayer> layers;
  final Map<String, BarChartCalendar> calendars;

  /// /$DMONTH / /$DDAY: the logon language's month and day names.
  final List<String> monthNames;
  final List<String> dayNames;

  /// /$OPTS / /$INIT / /$STATUS `SET <key> <value>` settings.
  final Map<String, String> options;

  /// The zoom steps the control applied itself (OZIN +1 / OZOU -1 —
  /// LoadCUACode answered 1: no wire round follows).
  final int zoom;

  BarChartHighlight? highlight(String id) => highlights[id];

  /// The x of [t] on the time axis in hundredths of a millimetre at zoom
  /// 1, 0 at [start].
  double xOf(DateTime t) {
    if (sections.isEmpty) {
      return t.difference(start).inMinutes / 1440.0 * 100.0;
    }
    var x = 0.0;
    var from = start;
    for (var i = 0; i < sections.length; i++) {
      final s = sections[i];
      final secEnd = i + 1 < sections.length ? sections[i + 1].start : end;
      final pxPerDay = s.width / barChartUnitDays(s.unit);
      final a = i == 0 ? from : s.start;
      final b = t.isBefore(secEnd) || i == sections.length - 1 ? t : secEnd;
      if (b.isAfter(a)) {
        x += b.difference(a).inMinutes / 1440.0 * pxPerDay;
      } else if (i == 0 && b.isBefore(a)) {
        return -a.difference(b).inMinutes / 1440.0 * pxPerDay;
      }
      if (!t.isAfter(secEnd)) break;
      from = secEnd;
    }
    return x;
  }

  /// The whole time axis' width (mm/100) at zoom 1.
  double get axisWidth => xOf(end);

  /// The height of [row] of [chart] in mm/100: its /$ROWWD height (else
  /// [defaultRow]), grown to hold every layer its nodes draw — a bar spans
  /// its `o` ± `h`/2 around the row centre, a symbol [symbolSize] (the
  /// real GUI's BARCOCX1 rows differ in height: row 1's bars reach 1 000
  /// below the centre, so that row is ~2 cm tall).
  double rowHeight(BarChartChart chart, int row,
      {double defaultRow = 600, double symbolSize = 450}) {
    var h = chart.rowHeights[row] ?? defaultRow;
    var half = 0.0;
    for (final n in chart.nodesAt(row)) {
      for (final id in n.layers) {
        final l = layers[id];
        if (l == null) continue;
        final m = l.macro;
        final ext = l.isSymbol
            ? symbolSize / 2
            : l.isLine
                ? 30.0
                : (m.height ?? barDefaultHeight) / 2;
        half = math.max(half, m.offset.abs() + ext);
      }
    }
    return math.max(h, 2 * half + 100);
  }

  /// The height of a bar whose macro gives none (mm/100).
  static const double barDefaultHeight = 400;

  /// The section [t] falls in.
  BarChartTimeSection? sectionAt(DateTime t) {
    BarChartTimeSection? s;
    for (final x in sections) {
      if (!x.start.isAfter(t)) s = x;
    }
    return s ?? sections.firstOrNull;
  }

  /// The short month label of [month] (1-12): its /$DMONTH name, cut.
  String monthLabel(int month, {int max = 3}) {
    final n = month >= 1 && month <= monthNames.length
        ? monthNames[month - 1]
        : const [
            'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
            'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
          ][(month - 1) % 12];
    return n.length <= max ? n : n.substring(0, max);
  }

  @override
  String toString() => 'SapBarChartModel(${shell ?? 'inline'} "$title": '
      '${charts.length} charts, '
      '${charts.fold(0, (n, c) => n + c.nodes.length)} nodes)';
}

/// The length of one time unit in days (BARC unit codes, LBARCCON: 1
/// year, 2 quarter, 3 month, 4 week, 5 day, 6 hour, 7 minute, 8 second;
/// the demo's sections are day-based, its ribbons months (3) over days
/// (5), its line grid monthly).
double barChartUnitDays(int unit) => switch (unit) {
      1 => 365.25,
      2 => 91.3125,
      3 => 30.4375,
      4 => 7.0,
      5 => 1.0,
      6 => 1 / 24.0,
      7 => 1 / 1440.0,
      8 => 1 / 86400.0,
      _ => 1.0,
    };

/// The start of the [unit] period [t] falls in (unit codes of
/// [barChartUnitDays]; a week starts on Monday).
DateTime barChartUnitStart(DateTime t, int unit) {
  final d = DateTime.utc(t.year, t.month, t.day);
  return switch (unit) {
    1 => DateTime.utc(t.year),
    2 => DateTime.utc(t.year, ((t.month - 1) ~/ 3) * 3 + 1),
    3 => DateTime.utc(t.year, t.month),
    4 => d.subtract(Duration(days: d.weekday - 1)),
    6 => DateTime.utc(t.year, t.month, t.day, t.hour),
    7 => DateTime.utc(t.year, t.month, t.day, t.hour, t.minute),
    8 => DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second),
    _ => d,
  };
}

/// The next [unit] period after the one starting at [t].
DateTime barChartUnitNext(DateTime t, int unit) => switch (unit) {
      1 => DateTime.utc(t.year + 1),
      2 => DateTime.utc(t.year, t.month + 3),
      3 => DateTime.utc(t.year, t.month + 1),
      4 => t.add(const Duration(days: 7)),
      6 => t.add(const Duration(hours: 1)),
      7 => t.add(const Duration(minutes: 1)),
      8 => t.add(const Duration(seconds: 1)),
      _ => DateTime.utc(t.year, t.month, t.day + 1),
    };

// ---------------------------------------------------------------------------
// The stream grammar
// ---------------------------------------------------------------------------

/// The record arity the BARC send routines (LBARCF01) declare per section
/// — read from the stream's own header (`/$HLTS 4`) first; these are the
/// values of the BARCOCX1 stream (a recorded session
/// srv[42]) for a carrier that drops the header.
const Map<String, int> barChartArity = {
  'DMONTH': 1, 'DWEEK': 1, 'DDAY': 1, 'TITLE': 1, 'SYEAR': 1,
  'CLMWD': 3, 'TIME': 2, 'DSTVALS': 2, 'DATELAY': 2, 'RIBLAY': 2,
  'SECTION': 4, 'HLTS': 4, 'HVALS': 3, 'CHARTS': 5, 'CALENDAR': 2,
  'RIBBON': 5, 'FMTS': 3, 'FVALS': 4, 'TIMEOBJ': 4, 'INTERVAL': 2,
  'IVALS': 3, 'PROFILE': 2, 'PVALS': 3, 'CALVALS': 3, 'GRIDS': 6,
  'LAYERS': 4, 'MAKRO': 3, 'LVALS': 3, 'BOXES': 5, 'CVALS': 3, 'BVALS': 3,
  'NODES': 4, 'NVALS': 4, 'POSITION': 4, 'ROWWD': 3, 'OUTPUT': 1,
  'BRACKET': 1, 'DATELIN': 4, 'DVALS': 3, 'DELETE': 3, 'AUTOAXIS': 2,
  'AUTOFIT': 3, 'AVALS': 3, 'SVALS': 3, 'GVALS': 3, 'RVALS': 3,
};

/// The `SET <key> <value>` sections (their header number is no arity).
const Set<String> _setSections = {'OPTS', 'STATUS', 'INIT'};

final RegExp _pushHeaderRx = RegExp(r'^\s*/\$([A-Z0-9]+)[ \t]+(\d+)', multiLine: true);
final RegExp _inlineHeaderRx = RegExp('\x00T\\\$([A-Z0-9]+)[ \t]+(\\d+)\x00');

Map<String, int> _arities(String text, {bool inline = false}) {
  final out = <String, int>{};
  for (final m in (inline ? _inlineHeaderRx : _pushHeaderRx).allMatches(text)) {
    out.putIfAbsent(m.group(1)!, () => int.parse(m.group(2)!));
  }
  return out;
}

/// The stream's records per section name (without `/$`), each record its
/// fields in order.
typedef BarChartRecords = Map<String, List<List<String>>>;

BarChartRecords _records(Map<String, List<String>> sections,
    Map<String, int> declared) {
  final out = <String, List<List<String>>>{};
  for (final MapEntry(key: k, value: fields) in sections.entries) {
    final name = k.startsWith(r'/$') ? k.substring(2) : k;
    if (_setSections.contains(name)) {
      out[name] = [for (final f in fields) [f]];
      continue;
    }
    final n = declared[name] ?? barChartArity[name] ?? 1;
    out[name] = [
      for (var i = 0; i + n <= fields.length; i += n)
        fields.sublist(i, i + n),
    ];
  }
  return out;
}

String _decode(Uint8List body) {
  try {
    return utf8.decode(body);
  } on FormatException {
    return latin1.decode(body);
  }
}

/// The records of a DataProvider-carried bar chart stream ([body] a DP
/// segment or the stream itself), or null when it holds none.
BarChartRecords? barChartStreamRecords(Uint8List body) {
  final s = netPlanStreamBytes(body);
  if (s.isEmpty) return null;
  final text = _decode(s);
  return _records(netPlanPushSections(text), _arities(text));
}

/// Whether [value] (an inline GRAPH item 16/2/5 — the non-OCX carrier
/// SAPLGRAP sends when the frontend is no WN32 GUI: GRAPH_RECEIVE in
/// BARCOCX1) is a bar chart stream: its `T$CHARTS` header.
bool isInlineBarChart(Uint8List value) =>
    // on the bytes: a latin-1 decode of the whole (up to 4 MB) value per
    // test was the round-4 #8 pattern
    containsBytes(value, '\x00T\$CHARTS');

/// The records of the inline carrier (NUL tokens, `T$NAME n` headers,
/// `C<value>` fields) decoded in SAP [codepage].
BarChartRecords barChartInlineRecords(Uint8List value,
    {String codepage = '1160'}) {
  final text = codepage == '4110'
      ? utf8.decode(value, allowMalformed: true)
      : latin1.decode(value, allowInvalid: true);
  return _records(netPlanInlineSections(text), _arities(text, inline: true));
}

// ---------------------------------------------------------------------------
// The R3 value tables
// ---------------------------------------------------------------------------

/// The value-table properties a bar chart's stream names (the AssignProperty2
/// property -> the section its rows stand for).
const Map<String, String> barChartTableSections = {
  'DPFVALSDATA': 'FVALS',
  'DP1BVALSDATA': 'BVALS',
  'DP1NVALSDATA': 'NVALS',
  'DPCALVALSDATA': 'CALVALS',
  'DPPOSDATA': 'POSITION',
};

/// The rows of a pushed X-R3TABLE value table as text fields: the push's
/// own FORMAT descriptor, INT4 columns (type `I`) aligned to 4 and read
/// little endian (the Windows OCX's byte order — DPPOSDATA's object ids,
/// DP1NVALSDATA's node / chart), text columns UTF-8 (else latin-1).
List<List<String>> barChartTableRows(Uint8List seg) {
  final (_, (fw, fn), fcells) = dpColumnCells(seg, 'FORMAT');
  final fb = BytesBuilder(copy: false);
  for (final c in fcells) {
    fb.add(c);
  }
  var fmt = fb.takeBytes();
  if (fw > 0 && fn > 0 && fmt.length > fw * fn) {
    fmt = Uint8List.sublistView(fmt, 0, fw * fn);
  }
  final cols = fmt.isEmpty ? null : placeholderColumns(fmt);
  if (cols == null || cols.isEmpty) return const [];
  // the in-memory row: each INT4 at a 4-aligned offset
  final layout = <(int, int, int)>[]; // offset, length, type
  var off = 0;
  for (final c in cols) {
    final isInt = c.type == 0x49 || c.type == 8; // 'I' / an int type id
    if (isInt) off = (off + 3) & ~3;
    layout.add((off, c.length, isInt ? 0x49 : c.type));
    off += c.length;
  }
  final (_, (dw, dn), dcells) = dpColumnCells(seg, 'DATAASC');
  final db = BytesBuilder(copy: false);
  for (final c in dcells) {
    if (dw > 0 && dn > 0 && dcells.length == dn && c.length < dw) {
      db.add(c);
      db.add(Uint8List(dw - c.length)..fillRange(0, dw - c.length, 0x20));
    } else {
      db.add(c);
    }
  }
  final data = db.takeBytes();
  var rl = off;
  if (dw > 0 && dw >= rl) rl = dw;
  if (rl <= 0 || data.isEmpty) return const [];
  final n = dn > 0 && dn * rl <= data.length ? dn : data.length ~/ rl;
  final out = <List<String>>[];
  for (var k = 0; k < n; k++) {
    final row = <String>[];
    for (final (o, len, type) in layout) {
      final a = k * rl + o, b = a + len;
      if (b > data.length) {
        row.add('');
        continue;
      }
      final raw = Uint8List.sublistView(data, a, b);
      if (type == 0x49 && len == 4) {
        final bd = ByteData.sublistView(raw);
        final le = bd.getInt32(0, Endian.little), be = bd.getInt32(0);
        // little endian on the Windows wire; a big-endian push (a Java
        // carrier, unrecorded) reads as the smaller magnitude
        row.add((le.abs() <= be.abs() ? le : be).toString());
      } else {
        var end = raw.length;
        while (end > 0 && (raw[end - 1] == 0x20 || raw[end - 1] == 0)) {
          end--;
        }
        row.add(_decode(Uint8List.sublistView(raw, 0, end)).trim());
      }
    }
    out.add(row);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Building the model
// ---------------------------------------------------------------------------

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call — [barChartDate] runs per date value of a stream.
final RegExp _digitRunRx = RegExp(r'\d+');
final RegExp _dateLayoutRx = RegExp(r'YYYY|MM|DD');
final RegExp _blankRunRx = RegExp(r'\s+');

/// Parse "DD.MM.YYYY;hh:mm:ss;" in the stream's /$DATELAY layout.
DateTime? barChartDate(String text,
    {String dateLayout = 'DD.MM.YYYY', String timeLayout = 'hh:mm:ss'}) {
  final parts = text.trim().split(';');
  final d = parts.first.trim();
  if (d.isEmpty) return null;
  final digits = _digitRunRx.allMatches(d).map((m) => m.group(0)!).toList();
  if (digits.length < 3) return null;
  final order = <String>[];
  for (final m in _dateLayoutRx.allMatches(dateLayout.toUpperCase())) {
    order.add(m.group(0)!);
  }
  if (order.length != 3) order..clear()..addAll(['DD', 'MM', 'YYYY']);
  int pick(String k) => int.tryParse(digits[order.indexOf(k)]) ?? 0;
  final y = pick('YYYY'), mo = pick('MM'), da = pick('DD');
  if (y <= 0 || mo <= 0 || da <= 0) return null;
  var h = 0, mi = 0, s = 0;
  if (parts.length > 1) {
    final t = _digitRunRx
        .allMatches(parts[1])
        .map((m) => int.parse(m.group(0)!))
        .toList();
    if (t.isNotEmpty) h = t[0];
    if (t.length > 1) mi = t[1];
    if (t.length > 2) s = t[2];
  }
  return DateTime.utc(y, mo, da, h, mi, s);
}

String _f(List<String> r, int i) => i < r.length ? r[i].trim() : '';
int _i(List<String> r, int i, [int def = 0]) =>
    int.tryParse(_f(r, i).replaceAll('.', '')) ?? def;
double _d(List<String> r, int i, [double def = 0]) =>
    double.tryParse(_f(r, i).replaceAll('.', '').replaceAll(',', '.')) ?? def;

/// Build the model from a full stream's records ([records], value tables
/// merged in) — null when the stream draws no chart.
SapBarChartModel? buildBarChart(BarChartRecords records,
    {String? shell,
    String? container,
    int zoom = 0,
    Set<(String, String)> selected = const {}}) {
  List<List<String>> sec(String n) => records[n] ?? const [];
  final charts = <String, BarChartChart>{};
  for (final r in sec('CHARTS')) {
    final id = _f(r, 0);
    if (id.isEmpty) continue;
    charts[id] = BarChartChart(
      id: id,
      flags: _f(r, 1),
      columns: _i(r, 2),
      order: _i(r, 3, charts.length + 1),
      height: _d(r, 4, 100),
    );
  }
  if (charts.isEmpty) return null;
  final options = <String, String>{};
  for (final n in _setSections) {
    for (final r in sec(n)) {
      final p = _f(r, 0).split(_blankRunRx);
      if (p.length >= 2 && p[0] == 'SET') {
        options[p[1]] = p.length > 2 ? p.sublist(2).join(' ') : '';
      }
    }
  }
  final dl = sec('DATELAY').firstOrNull;
  final dateLayout = dl == null || _f(dl, 0).isEmpty ? 'DD.MM.YYYY' : _f(dl, 0);
  DateTime? date(String s) => barChartDate(s, dateLayout: dateLayout);
  final time = sec('TIME').firstOrNull;
  final start = (time == null ? null : date(_f(time, 0))) ??
      DateTime.utc(DateTime.now().year);
  var end = (time == null ? null : date(_f(time, 1))) ??
      DateTime.utc(start.year + 1);
  if (!end.isAfter(start)) end = start.add(const Duration(days: 365));
  final sections = <BarChartTimeSection>[
    for (final r in sec('SECTION'))
      if (date(_f(r, 1)) case final s?)
        BarChartTimeSection(_f(r, 0), s, _i(r, 2, 1), _d(r, 3, 50)),
  ]..sort((a, b) => a.start.compareTo(b.start));
  // highlights + their keyed values
  final highlights = <String, BarChartHighlight>{};
  for (final r in sec('HLTS')) {
    final id = _f(r, 0);
    if (id.isEmpty) continue;
    highlights[id] = BarChartHighlight(id, _f(r, 1), _f(r, 2), _f(r, 3));
  }
  for (final r in sec('HVALS')) {
    highlights[_f(r, 0)]?.values[_f(r, 1)] = _f(r, 2);
  }
  final formats = <String, BarChartFormat>{};
  for (final r in sec('FMTS')) {
    formats[_f(r, 0)] = BarChartFormat(_f(r, 0), _f(r, 1), _f(r, 2));
  }
  for (final r in sec('FVALS')) {
    final f = formats[_f(r, 0)];
    if (f == null) continue;
    (f.fields[_f(r, 1)] ??= {})[_f(r, 2)] = _f(r, 3);
  }
  // layers + macros (LVALS key M -> MAKRO id)
  final macros = {for (final r in sec('MAKRO')) _f(r, 0): _f(r, 2)};
  final macroOf = <String, String>{};
  for (final r in sec('LVALS')) {
    if (_f(r, 1) == 'M') macroOf[_f(r, 0)] = _f(r, 2);
  }
  final layers = <String, BarChartLayer>{};
  for (final r in sec('LAYERS')) {
    final id = _f(r, 0);
    layers[id] = BarChartLayer(id, _f(r, 1), _f(r, 2), _f(r, 3),
        BarChartMacro.parse(macros[macroOf[id] ?? id] ?? ''));
  }
  // positions: (chart, kind, id) -> row
  final rowOf = <(String, String, String), int>{};
  for (final r in sec('POSITION')) {
    final row = int.tryParse(_f(r, 3));
    if (row != null) rowOf[(_f(r, 0), _f(r, 1), _f(r, 2))] = row;
  }
  // boxes + values
  final boxVals = <String, Map<String, String>>{};
  for (final r in sec('BVALS')) {
    (boxVals[_f(r, 0)] ??= {})[_f(r, 1)] = _f(r, 2);
  }
  for (final r in sec('BOXES')) {
    final c = charts[_f(r, 2)];
    if (c == null) continue;
    final id = _f(r, 0);
    c.boxes.add(BarChartBox(
      id: id,
      kind: _f(r, 1),
      chart: c.id,
      format: _f(r, 3),
      highlight: _f(r, 4),
      values: boxVals[id],
      row: rowOf[(c.id, 'B', id)],
    ));
  }
  // nodes + values (NVALS: node, chart, key, value)
  final nodeVals = <String, Map<String, List<String>>>{};
  for (final r in sec('NVALS')) {
    final key = _f(r, 2);
    ((nodeVals[_f(r, 0)] ??= {})[key] ??= []).add(_f(r, 3));
  }
  for (final r in sec('NODES')) {
    final c = charts[_f(r, 1)];
    if (c == null) continue;
    final id = _f(r, 0);
    final vals = nodeVals[id] ?? {};
    final times = <int, DateTime>{};
    for (final e in vals.entries) {
      final k = int.tryParse(e.key);
      if (k == null || k <= 0) continue;
      final t = date(e.value.first);
      if (t != null) times[k] = t;
    }
    c.nodes.add(BarChartNode(
      id: id,
      chart: c.id,
      format: _f(r, 2),
      highlight: _f(r, 3),
      values: vals,
      times: times,
      layers: List.of(vals['A'] ?? const []),
      calendar: vals['C']?.firstOrNull,
      row: rowOf[(c.id, 'N', id)],
      selected: selected.contains((c.id, id)),
    ));
  }
  for (final r in sec('CVALS')) {
    charts[_f(r, 0)]?.values[_f(r, 1)] = _f(r, 2);
  }
  for (final r in sec('CLMWD')) {
    charts[_f(r, 0)]?.columnWidths[_i(r, 1)] = _d(r, 2, 1000);
  }
  for (final r in sec('ROWWD')) {
    charts[_f(r, 0)]?.rowHeights[_i(r, 1)] = _d(r, 2, 1000);
  }
  for (final r in sec('RIBBON')) {
    charts[_f(r, 1)]?.ribbons.add(
        BarChartRibbon(_f(r, 0), _f(r, 1), _f(r, 2), _i(r, 3, 1), _f(r, 4)));
  }
  for (final r in sec('GRIDS')) {
    charts[_f(r, 1)]?.grids.add(BarChartGrid(
        _f(r, 0), _f(r, 1), _f(r, 2), _f(r, 3), _i(r, 4), _f(r, 5)));
  }
  for (final r in sec('DATELIN')) {
    // a date line: id | chart | date | highlight (LBARCF01 send_datelines;
    // XBO5 "Insérer ligne de date…" adds one) — unrecorded on the wire
    final t = date(_f(r, 2));
    if (t != null) {
      charts[_f(r, 1)]?.dateLines.add(BarChartDateLine(_f(r, 1), _f(r, 3), t));
    }
  }
  // calendars: CALVALS a = profile, u = free interval; PVALS a = a
  // recurring time object; TIMEOBJ (id, R|U, weekday base, weekday|date)
  final timeObj = {for (final r in sec('TIMEOBJ')) _f(r, 0): r};
  final intervals = <String, (String?, String?)>{};
  for (final r in sec('IVALS')) {
    final iv = intervals[_f(r, 0)] ?? (null, null);
    intervals[_f(r, 0)] = _f(r, 1) == 'S' ? (_f(r, 2), iv.$2) : (iv.$1, _f(r, 2));
  }
  DateTime? absolute(String? to) {
    final r = timeObj[to];
    if (r == null || _f(r, 1) != 'U') return null;
    return date(_f(r, 3));
  }

  final profiles = <String, List<String>>{};
  for (final r in sec('PVALS')) {
    if (_f(r, 1) == 'a') (profiles[_f(r, 0)] ??= []).add(_f(r, 2));
  }
  final calendars = <String, BarChartCalendar>{};
  for (final r in sec('CALENDAR')) {
    calendars[_f(r, 0)] = BarChartCalendar(_f(r, 0));
  }
  for (final r in sec('CALVALS')) {
    final cal = calendars[_f(r, 0)] ??= BarChartCalendar(_f(r, 0));
    final key = _f(r, 1), v = _f(r, 2);
    if (key == 'a') {
      for (final to in profiles[v] ?? const <String>[]) {
        final o = timeObj[to];
        if (o != null && _f(o, 1) == 'R') {
          final wd = _i(o, 3);
          if (wd >= 1 && wd <= 7) cal.weekdaysOff.add(wd);
        }
      }
    } else if (key == 'u') {
      final iv = intervals[v];
      final a = absolute(iv?.$1), b = absolute(iv?.$2);
      if (a != null && b != null && b.isAfter(a)) cal.free.add((a, b));
    }
  }
  String first(String n) {
    final r = sec(n).firstOrNull;
    return r == null ? '' : _f(r, 0);
  }

  final ordered = charts.values.toList()
    ..sort((a, b) => a.order.compareTo(b.order));
  return SapBarChartModel(
    shell: shell,
    container: container,
    title: first('TITLE'),
    status: first('OUTPUT'),
    start: start,
    end: end,
    sections: sections,
    charts: ordered,
    highlights: highlights,
    formats: formats,
    layers: layers,
    calendars: calendars,
    monthNames: [for (final r in sec('DMONTH')) _f(r, 0)],
    dayNames: [for (final r in sec('DDAY')) _f(r, 0)],
    options: options,
    zoom: zoom,
  );
}

/// Parse one full DataProvider bar chart stream ([body]: the DP segment
/// or the stream) with its value tables ([tables]: the AssignProperty2
/// property -> its DP segment), or null when it draws no chart.
SapBarChartModel? parseBarChartStream(Uint8List body,
    {Map<String, Uint8List> tables = const {}, String? shell}) {
  final recs = barChartStreamRecords(body);
  if (recs == null) return null;
  for (final MapEntry(key: prop, value: seg) in tables.entries) {
    final name = barChartTableSections[prop];
    if (name != null) recs[name] = barChartTableRows(seg);
  }
  return buildBarChart(recs, shell: shell);
}

/// Parse the inline carrier (GRAPH item 16/2/5), or null.
SapBarChartModel? parseBarChartInline(Uint8List value,
    {String codepage = '1160'}) {
  if (!isInlineBarChart(value)) return null;
  return buildBarChart(barChartInlineRecords(value, codepage: codepage));
}

// ---------------------------------------------------------------------------
// The function codes and the command read-back
// ---------------------------------------------------------------------------

/// The function codes the OCX applies entirely by itself (LoadCUACode
/// answered `1`, no read-back follows): zoom in / out and select / unselect
/// all — a recorded session g[16] SALL, g[19] UALL,
/// g[27] OZOU, g[30] OZIN all ` 1` (and barcocx1_open g[12] OZIN). A `0`
/// means the control queued a command into its stream for the server
/// (ADEL for a delete, ACTBAR for a code it does not know), and every `0`
/// is followed by the read-back. OINS / OMOD / ODUP (edit codes beside ODEL
/// in the OCX's table) are unrecorded: answered `0` with the empty stream.
const Set<String> barChartLocalCodes = {'OZIN', 'OZOU', 'SALL', 'UALL'};

/// The CUA codes SAPbarc.OCX knows (its code table, SAPbarc.OCX 8000.1 at
/// 0x8a058 — barcocx1_open DECODE.md §5). Membership does NOT decide the
/// answer (ODEL is in it and answers ` 0`): a known code the control does
/// not finish logs its OWN command (ODEL → `CADEL\nCn\n<chart>\n<node>\n`,
/// interactions g[24]); an unknown one is reported as `ACTBAR`.
const Set<String> barChartOcxCodes = {
  'SAVE', 'EXIT', 'HELP', 'BACK', 'OZIN', 'OZOU', 'QUIT', 'TODO', 'GRAF',
  'EDIT', 'OPTS', 'MHLP', 'OPEN', 'UPLD', 'PRNT', 'PRN1', 'PRN2', 'PRN3',
  'PRN4', 'PRN5', 'PRN6', 'PRN7', 'PRN8', 'PRN9', 'PRNA', 'PRNB', 'PRNC',
  'PRND', 'PRNE', 'PRNF', 'PRNG', 'OINS', 'OMOD', 'ODEL', 'ODUP', 'OCON',
  'OSEL', 'OLAB', 'ILAB', 'OUND', 'OSET', 'SALL', 'UALL', 'SCMP', 'SCHT',
  'SLIN', 'SLAY', 'SSEL', 'RLAY', 'LLAY', 'LAY1', 'LAY2', 'LAY3', 'LAY4',
  'LAY5', 'LAY6', 'LAY7', 'LAY8', 'LAY9', 'LA10', 'LA32', 'LA33', 'LA34',
  'LA35', 'LA36', 'LA37', 'LA38', 'LA39', 'LA40', 'LA41', 'LA42', 'SNOD',
  'SBOX', 'SNUB', 'SNLY', 'MARK', 'MBOX', 'GRAN', 'SASE', 'RESE', 'MSUR',
  'MINV', 'MPCK', 'MPCL', 'MP3D', 'MPFD', 'MOUR', 'MONV', 'MOCK', 'MOCL',
  'JEAR', 'QURT', 'MONT', 'WEEK', 'GDAY', 'HOUR', 'MINT', 'SECD', 'INFT',
  'INON', 'INOF', 'BORD', 'BOON', 'BOOF', 'TERM', 'TLFT', 'TRGT', 'TLFW',
  'TRGW', 'FHLP', 'EXTH', 'FKEY', 'GLOS', 'INFO', 'TOGS', 'INXT', 'NLGD',
  'BLGD', 'UWTO', 'UNWT', 'PFST', 'PLST', 'DBUG', 'DIAG', 'SBIL', 'TMEV',
  'DZIO', 'RPRJ',
};

/// The VT_I2 LoadCUACode result for [code]: `1` applied by the control
/// ([barChartLocalCodes]), `0` = a command was queued for the program
/// (USER_COMMAND_0300: retval 0 → its check routine reads the stream back).
String barChartCuaCodeAnswer(String code) =>
    barChartLocalCodes.contains(code.trim().toUpperCase()) ? '1' : '0';

/// The command a refused [code] leaves for the next read-back, or null:
/// `CACTBAR\nC<code>` for a code the OCX does not know (barcocx1_open
/// g[17], XBO5 — the one recorded instance); ODEL's `CADEL` comes from the
/// selection ([barChartDeleteCommand], the tracker); another known code's
/// own log is unrecorded (the empty stream).
String? barChartRefusedCommand(String code) {
  final c = code.trim().toUpperCase();
  if (c.isEmpty || barChartOcxCodes.contains(c)) return null;
  return barChartActionCommand(c);
}

/// The command stream entry a refused function code leaves for the
/// read-back: `CACTBAR\nC<code>` (barcocx1_open gui[17], XBO5).
String barChartActionCommand(String code) => 'CACTBAR\nC${code.trim()}';

/// The delete command ODEL leaves for the selected [nodes] ((chart, node
/// id) pairs): `CADEL\nCn\nC<chart>\nC<node>\n` — interactions g[24]
/// `CADEL\nCn\nC1\nC2\n` (node 2 of chart 1, the clicked bar; the server
/// answers `/$DELETE 3 :1 :N :2`), exit capture g[35] (`…C1\nC1\n`). Only
/// ONE selected node is recorded; several are written one group each
/// (unrecorded). Null when nothing is selected — the empty stream (a
/// delete with nothing marked is unrecorded).
String? barChartDeleteCommand(Iterable<(String, String)> nodes) {
  if (nodes.isEmpty) return null;
  final b = StringBuffer('CADEL\n');
  for (final (chart, id) in nodes) {
    b.write('Cn\nC$chart\nC$id\n');
  }
  return b.toString();
}

/// One command of a read-back stream (`C<token>\n` lines): its name
/// (`ACTBAR`, `ADEL`, `AMOVENODE`, `DBCL`, `CREORG`) and argument tokens.
typedef BarChartCommand = ({String name, List<String> args});

/// Parse a read-back stream into its tokens (each `C`-tagged line, the
/// first the command) — null when [text] holds none.
BarChartCommand? parseBarChartCommand(String text) {
  final toks = [
    for (final l in text.replaceAll('\x00', '').split('\n'))
      if (l.startsWith('C')) l.substring(1),
  ];
  if (toks.isEmpty) return null;
  return (name: toks.first, args: toks.sublist(1));
}

/// A bar move as the OCX reports it after its event 1 (interactions g[34],
/// 135 B): `AMOVENODE`, four header tokens (`1 1 1 1` — the chart and
/// node moved and, presumably, the target chart / row; NOT decoded), the
/// `sel` marker, then per layer of the node its id and (date index, new
/// stamp) pairs — g[34]: layer 9 → 2 = 23.04.1999;16:00:00;, 3 =
/// 30.07.1999;16:00:00;, layer 8 → 1 = 19.02.1999;16:00:00;, 2 =
/// 23.04.1999;16:00:00;. Null when [c] is no AMOVENODE.
({List<String> header, Map<String, Map<int, String>> layers})?
    barChartMoveOf(BarChartCommand c) {
  if (c.name != 'AMOVENODE') return null;
  final a = c.args;
  final sel = a.indexOf('sel');
  if (sel < 0) return null;
  final layers = <String, Map<int, String>>{};
  String? layer;
  for (var i = sel + 1; i < a.length; i++) {
    if (i + 1 < a.length && a[i + 1].contains(';') && layer != null &&
        int.tryParse(a[i]) != null) {
      layers[layer]![int.parse(a[i])] = a[i + 1];
      i++;
    } else {
      layer = a[i];
      layers[layer] = {};
    }
  }
  return (header: a.sublist(0, sel), layers: layers);
}

String _le32(int v) => String.fromCharCodes(
    [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);

Uint8List _emptyColumn(String name, int width) {
  final b = BytesBuilder(copy: false)
    ..add([0x03, 0x01, (name.length >> 8) & 0xff, name.length & 0xff])
    ..add(name.codeUnits)
    ..add([0x03, 0x01, 0x03, 0x02, 0x00, 0x08])
    ..add([
      (width >> 24) & 0xff, (width >> 16) & 0xff, (width >> 8) & 0xff,
      width & 0xff, 0, 0, 0, 0,
    ])
    ..add([0x03, 0x02]);
  return b.takeBytes();
}

/// The DP_GET_CLIENT_TABLE45A RESULT a bar chart's command read-back gets:
/// TYPE / SUBTYPE echoed, DATE / TIME zero, TOTALSIZE the DATASTR length
/// WITH its NUL (the empty stream: 1 — as the NETZOCX2 exit g[21] too;
/// STMS's NetPlan read-back answers 0, netPlanStreamAnswer), the
/// DATASTR scalar, empty FORMAT / PROPS columns (width 80) — the real GUI's
/// gui[17] of a recorded session (`CACTBAR\nCXBO5`, 14) and
/// gui[12] of a recorded session (empty, 1).
Uint8List barChartStreamAnswer([String command = '']) {
  final data = '${String.fromCharCodes(utf8.encode(command))}\x00';
  return buildDpAnswer(
    scalars: {
      'TYPE': 'APPLICATION',
      'SUBTYPE': 'sapbarc-stream',
      'DATE': '00000000',
      'TIME': '000000',
      'DESCRIPTION': '',
      'TOTALSIZE': _le32(data.length),
      'PLATTFORM': '',
    },
    extraScalars: [('DATASTR', data)],
    tableRegion: Uint8List.fromList([
      ..._emptyColumn('FORMAT', 80),
      ..._emptyColumn('PROPS', 80),
    ]),
  );
}

// ---------------------------------------------------------------------------
// The session-side tracker
// ---------------------------------------------------------------------------

final RegExp _digits = RegExp(r'^\d{1,9}$');
final RegExp _pullUrlRx = RegExp('SAPR3://[0-9A-Za-z]+');

int _indexOf(Uint8List b, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= b.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (b[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

String? _pullUrl(Uint8List v) {
  if (_indexOf(v, 'DP_GET_CLIENT_TABLE'.codeUnits) < 0) return null;
  final i = _indexOf(v, 'INURL'.codeUnits);
  if (i < 0) return null;
  final end = i + 4096 < v.length ? i + 4096 : v.length;
  return _pullUrlRx
      .firstMatch(latin1.decode(Uint8List.sublistView(v, i, end)))
      ?.group(0);
}

class _Slot {
  _Slot(this.program, this.dynpro, this.modal);
  final String? program;
  final String? dynpro;
  final bool modal;
}

/// One control's stream state: the records of its last full stream, the
/// deltas folded over them, its value tables.
class _State {
  BarChartRecords records = {};
  int zoom = 0;

  /// the marked nodes (chart, node id) — local to the control
  final Set<(String, String)> selected = {};
  SapBarChartModel? _memo;

  /// Every (chart, node id) the stream declares.
  Set<(String, String)> get nodes => {
        for (final r in records['NODES'] ?? const <List<String>>[])
          if (r.length >= 2) (r[1].trim(), r[0].trim()),
      };

  /// Fold one stream push: a full stream (`/$CHARTS`) replaces; a delta
  /// (barcocx1_open srv[16] `/$OUTPUT`, srv[24] `/$TITLE`, under
  /// `OpenBracket(1, 0)`) replaces the single-value sections it carries,
  /// upserts the records of the others by object id and applies its
  /// /$DELETE (chart, object type, id).
  void apply(BarChartRecords recs, Map<String, List<List<String>>> tables) {
    final full = recs.containsKey('CHARTS');
    if (full) records = {};
    for (final r in full ? const <List<String>>[] : recs['DELETE'] ?? const []) {
      if (r.length < 3) continue;
      final sec = _deleteSection[r[1].trim()];
      final id = r[2].trim();
      if (sec == null) continue;
      records[sec]?.removeWhere((x) => x.isNotEmpty && x.first.trim() == id);
      final vals = _valueSection[sec];
      if (vals != null) {
        records[vals]?.removeWhere((x) => x.isNotEmpty && x.first.trim() == id);
      }
    }
    void put(String k, List<List<String>> v) {
      final old = records[k];
      if (full || old == null || _singleSections.contains(k) || v.isEmpty) {
        records[k] = v;
        return;
      }
      final keys = {for (final r in v) _keyOf(k, r)};
      records[k] = [
        for (final r in old)
          if (!keys.contains(_keyOf(k, r))) r,
        ...v,
      ];
    }

    for (final MapEntry(key: k, value: v) in recs.entries) {
      if (k == 'BRACKET' || k == 'DELETE') continue;
      if (!full && v.isEmpty) continue;
      put(k, v);
    }
    for (final MapEntry(key: k, value: v) in tables.entries) {
      // a delta's empty table (the move's DPPOSDATA, interactions s[38]:
      // descriptor only) changes nothing
      if (!full && v.isEmpty) continue;
      put(k, v);
    }
    // the server's own marks (NVALS `S 1`: the moved node, s[38]) and the
    // deleted nodes' marks
    for (final r in recs['NVALS'] ?? const <List<String>>[]) {
      _mark(r);
    }
    for (final r in tables['NVALS'] ?? const <List<String>>[]) {
      _mark(r);
    }
    selected.retainWhere(nodes.contains);
    _memo = null;
  }

  void _mark(List<String> r) {
    if (r.length < 4 || r[2].trim() != 'S') return;
    final key = (r[1].trim(), r[0].trim());
    if (r[3].trim() == '1') {
      selected.add(key);
    } else {
      selected.remove(key);
    }
  }

  static String _keyOf(String section, List<String> r) => section == 'POSITION'
      ? r.take(3).map((f) => f.trim()).join('|')
      : (r.isEmpty ? '' : r.first.trim());
}

/// The sections whose one record is the value (a delta replaces them).
const Set<String> _singleSections = {
  'TITLE', 'OUTPUT', 'TIME', 'DATELAY', 'RIBLAY', 'SYEAR', 'DMONTH',
  'DWEEK', 'DDAY', 'DSTVALS', 'OPTS', 'STATUS', 'INIT',
};

/// /$DELETE object types (LBARCF01 send_deletions) -> the section.
const Map<String, String> _deleteSection = {
  'B': 'BOXES', 'N': 'NODES', 'L': 'LAYERS', 'D': 'DATELIN', 'R': 'RIBBON',
  'G': 'GRIDS', 'H': 'HLTS', 'C': 'CHARTS', 's': 'SECTION', 'A': 'CALENDAR',
  'I': 'INTERVAL', 'E': 'TIMEOBJ',
};

/// An object section -> the section of its keyed values.
const Map<String, String> _valueSection = {
  'BOXES': 'BVALS', 'NODES': 'NVALS', 'LAYERS': 'LVALS', 'CALENDAR': 'CALVALS',
  'INTERVAL': 'IVALS', 'HLTS': 'HVALS', 'CHARTS': 'CVALS',
};

/// The bar chart state of one session: the BarchartGraphics controls
/// created (class, parent, container / dynpro links), each one's chart as
/// pushed, the function codes it was given, the command read-back sinks.
class SapBarChartTracker {
  /// shell -> creation class, for every control seen created
  final Map<String, String> classOf = {};

  /// shell -> parent shell its CreateControl named
  final Map<String, String> parentOf = {};

  /// container shell -> dynpro custom-control name (`LinkContainer`)
  final Map<String, String> linkedName = {};

  /// bar chart shells in creation order (a re-created shell moves last)
  final List<String> barChartShells = [];

  final Map<String, _State> _states = {};
  final Map<String, _Slot> _slots = {};
  final Set<String> _unbound = {};

  /// read-back sink url -> bar chart shell
  final Map<String, String> _sinks = {};

  /// shell -> the command its next read-back answers (a refused code)
  final Map<String, String> _pending = {};

  /// The urls answered lately (a later pass over the same frame skips them).
  final Set<String> _answered = {};

  bool get hasUnbound => _unbound.isNotEmpty;

  /// The read-back sinks recorded by the last [foldCall].
  final List<String> lastSinks = [];

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

  /// The chart last pushed to [shell] (null when it has none yet).
  SapBarChartModel? build(String shell) {
    final st = _states[shell];
    if (st == null || st.records.isEmpty) return null;
    return st._memo ??= buildBarChart(st.records,
        shell: shell,
        container: containerOf(shell),
        zoom: st.zoom,
        selected: st.selected);
  }

  /// Mark node [node] of [chart] on [shell] (a tap on its bar — local, the
  /// real GUI sends nothing): the only mark unless [add]; null [node]
  /// clears every mark. The next ODEL read-back names the marks.
  void selectNode(String shell, String? chart, String? node,
      {bool add = false}) {
    final st = _states[shell];
    if (st == null) return;
    if (!add) st.selected.clear();
    if (chart != null && node != null) {
      final k = (chart, node);
      if (add && st.selected.contains(k)) {
        st.selected.remove(k);
      } else {
        st.selected.add(k);
      }
    }
    st._memo = null;
  }

  /// The marked nodes of [shell] ((chart, node id)).
  Set<(String, String)> selectionOf(String shell) =>
      Set.of(_states[shell]?.selected ?? const {});

  /// The zoom steps [shell] applied itself.
  int zoomOf(String shell) => _states[shell]?.zoom ?? 0;

  bool _isBar(String? shell) =>
      shell != null && isBarChartClass(classOf[shell] ?? '');

  String? _barOf(String? ref, String? Function(String owner)? shellOf,
      bool Function(String shell)? isLive) {
    final r = ref?.trim();
    if (r != null && r.isNotEmpty) {
      final s = shellOf?.call(r);
      if (_isBar(s)) return s;
      if (s != null && classOf.containsKey(s)) return null; // another control
      if (_isBar(r) && (isLive?.call(r) ?? true)) return r;
      if (s != null) return null;
    }
    // a replay keeps the recording client's handles: the newest live one
    for (final s in barChartShells.reversed) {
      if (isLive?.call(s) ?? true) return s;
    }
    return null;
  }

  /// Fold one complete OLE_FLUSH_CALL RFC value: control facts, stream
  /// and table pushes, function codes, read-back sinks. [shellOf] resolves
  /// a client-minted handle to its kernel shell; [isLive] rejects
  /// destroyed controls. Returns the shells whose chart changed.
  Set<String> foldCall(
    Uint8List rfc, {
    String? Function(String owner)? shellOf,
    bool Function(String shell)? isLive,
    FlushCall? parsed,
  }) {
    final call = parsed ?? parseFlushCall(rfc);
    lastSinks.clear();
    _recordControls(call);
    final touched = <String>{};
    if (barChartShells.isEmpty) return touched;
    final bindings = [
      for (final b in dpPushBindings(call))
        if (b.role == 'DATA' || barChartTableSections.containsKey(b.role)) b,
    ];
    if (bindings.isNotEmpty) {
      DpCache? cache;
      final streams = <String, List<Uint8List>>{};
      final tables = <String, Map<String, List<List<String>>>>{};
      for (final b in bindings) {
        final shell = _barOf(b.shell ?? b.owner, shellOf, isLive);
        if (shell == null) continue;
        cache ??= DpCache()..ingestValue(rfc);
        for (final u in b.urls) {
          final seg = cache.byUrl[u];
          if (seg == null) continue;
          if (b.role == 'DATA') {
            final body = netPlanStreamBytes(seg);
            if (body.isNotEmpty) (streams[shell] ??= []).add(body);
          } else {
            (tables[shell] ??= {})[barChartTableSections[b.role]!] =
                barChartTableRows(seg);
          }
        }
      }
      for (final shell in {...streams.keys, ...tables.keys}) {
        final st = _states[shell] ??= _State();
        final pushes = streams[shell] ?? const <Uint8List>[];
        if (pushes.isEmpty) {
          st.apply(const {}, tables[shell] ?? const {});
        }
        for (final (i, body) in pushes.indexed) {
          final recs = barChartStreamRecords(body) ?? {};
          st.apply(recs, i == 0 ? tables[shell] ?? const {} : const {});
        }
        touched.add(shell);
        if (!_slots.containsKey(shell)) _unbound.add(shell);
      }
    }
    _recordCodesAndSinks(call, shellOf, isLive, touched);
    return touched;
  }

  void _recordControls(FlushCall call) {
    for (var i = 1; i <= call.verbs.length; i++) {
      final verb = call.verbs[i - 1];
      if (verb != 'CreateControl' &&
          verb != 'LinkContainer' &&
          verb != 'LinkControl' &&
          verb != 'DestroyWindow') {
        continue;
      }
      final a = verbNamedArgs(call, i);
      final shell = (a['#1'] ?? '').trim();
      if (!_digits.hasMatch(shell)) continue;
      if (verb == 'CreateControl') {
        final cls = (a['#2'] ?? '').trim();
        classOf[shell] = cls;
        final parent = (a['#4'] ?? '').trim();
        if (_digits.hasMatch(parent)) {
          parentOf[shell] = parent;
        } else {
          parentOf.remove(shell);
        }
        linkedName.remove(shell);
        _forget(shell);
        if (isBarChartClass(cls)) barChartShells.add(shell);
      } else if (verb == 'LinkContainer') {
        final name = (a['#2'] ?? '').trim();
        if (name.isNotEmpty) linkedName[shell] = name;
      } else if (verb == 'LinkControl') {
        final prog = (a['#2'] ?? '').trim();
        final dyn = (a['#3'] ?? '').trim();
        if (_isBar(shell) && prog.isNotEmpty && dyn.isNotEmpty) {
          _slots[shell] = _Slot(prog, dyn.padLeft(4, '0'), false);
          _unbound.remove(shell);
        }
      } else if (verb == 'DestroyWindow') {
        _forget(shell);
        classOf.remove(shell);
      }
    }
  }

  void _forget(String shell) {
    barChartShells.remove(shell);
    _states.remove(shell);
    _slots.remove(shell);
    _unbound.remove(shell);
    _pending.remove(shell);
    _sinks.removeWhere((_, s) => s == shell);
  }

  /// `LoadCUACode(<code>)` on a bar chart: a local code moves its zoom, a
  /// refused one arms the next read-back with `CACTBAR`; `AssignProperty2(
  /// <handle>, DATASTREAM, <dp>, stream)` + `SaveDataToUrl(…, SAPR3://…)`:
  /// the sink the server pulls the command stream from.
  void _recordCodesAndSinks(
    FlushCall call,
    String? Function(String owner)? shellOf,
    bool Function(String shell)? isLive,
    Set<String> touched,
  ) {
    final meta = verbMeta(call);
    String? source;
    for (var i = 1; i <= call.verbs.length; i++) {
      final verb = call.verbs[i - 1];
      if (verb == 'LoadCUACode') {
        final shell = _barOf(meta[i - 1].objValue, shellOf, isLive);
        if (shell == null) continue;
        final code = (verbNamedArgs(call, i)['#1'] ?? '').trim().toUpperCase();
        if (code.isEmpty) continue;
        if (barChartLocalCodes.contains(code)) {
          final st = _states[shell] ??= _State();
          switch (code) {
            case 'OZIN' || 'OZOU':
              st.zoom = (st.zoom + (code == 'OZIN' ? 1 : -1)).clamp(-6, 8);
            case 'SALL':
              st.selected.addAll(st.nodes);
            case 'UALL':
              st.selected.clear();
          }
          st._memo = null;
          touched.add(shell);
          _pending.remove(shell);
        } else if (code == 'ODEL') {
          final c = barChartDeleteCommand(
              (_states[shell]?.selected ?? const <(String, String)>{})
                  .toList()
                ..sort((a, b) => '${a.$1}/${a.$2}'.compareTo('${b.$1}/${b.$2}')));
          if (c == null) {
            _pending.remove(shell);
          } else {
            _pending[shell] = c;
          }
        } else if (barChartRefusedCommand(code) case final c?) {
          _pending[shell] = c;
        } else {
          _pending.remove(shell);
        }
      } else if (verb == 'AssignProperty2') {
        final a = verbNamedArgs(call, i);
        if ((a['#2'] ?? '').trim() == 'DATASTREAM' &&
            (a['#4'] ?? '').trim() == 'stream') {
          source = (a['#1'] ?? '').trim();
        }
      } else if (verb == 'SaveDataToUrl' && source != null) {
        final a = verbNamedArgs(call, i);
        final url = (a['#3'] ?? '').trim();
        final sub = (a['#2'] ?? '').trim().toLowerCase();
        final shell = _barOf(source, shellOf, isLive);
        if (url.startsWith('SAPR3://') &&
            sub == 'sapbarc-stream' &&
            shell != null) {
          _sinks[url] = shell;
          lastSinks.add(url);
        }
        source = null;
      }
    }
  }

  /// Whether [url] is (or just was) a bar chart read-back sink.
  bool hasSink(String url) =>
      _sinks.containsKey(url) || _answered.contains(url);

  /// The RFC answer to a server pull of a bar chart read-back sink: the
  /// refused function code's `CACTBAR` command when one is armed for that
  /// control, else the empty stream. Null when [value] is no such pull.
  Uint8List? answerPull(Uint8List value) {
    final url = _pullUrl(value);
    if (url == null) return null;
    final shell = _sinks.remove(url);
    if (shell == null) return null;
    _answered.add(url);
    if (_answered.length > 64) _answered.remove(_answered.first);
    return barChartStreamAnswer(_pending.remove(shell) ?? '');
  }

  /// The client frames answering every bar chart read-back pull [frame]
  /// carries (16/8/1 DP answer stamped with the pull frame's own step).
  List<Uint8List> answerPullsOf(Uint8List frame, int fallbackStep) {
    if (_sinks.isEmpty) return const [];
    final dec = decompressFrame(frame);
    if (dec == null) return const [];
    var step = fallbackStep;
    final out = <Uint8List>[];
    for (final it in dec.walk.items) {
      if (it.isAppl && it.id == 4 && it.sid == 38 && it.value.length >= 4) {
        step = it.value.buffer
            .asByteData(it.value.offsetInBytes, 4)
            .getUint32(0);
      }
      if (!it.isAppl || it.id != applRfcTr || it.value.isEmpty) continue;
      final rfc = answerPull(it.value); // read, never kept
      if (rfc == null) continue;
      out.add(
          clientFrame([stepItem(step), buildApplItem(8, 1, rfc), eomBytes]));
    }
    return out;
  }

  /// Bind the charts pushed since the last paint to [screen].
  void bindUnbound(ScreenModel? screen) {
    if (screen == null || screen.program == null) return;
    for (final shell in _unbound) {
      _slots[shell] = _Slot(screen.program, screen.dynpro, screen.modalLevel > 0);
    }
    _unbound.clear();
  }

  /// The pushed charts of the screen on display (base dynpro, and the
  /// popup when one is up), in creation order; [destroyed] = shells gone.
  List<SapBarChartModel> pushedOn(
    ScreenModel? screen,
    ScreenModel? base,
    Set<String> destroyed,
  ) {
    final popup = screen != null && screen.modalLevel > 0 ? screen : null;
    final full = popup != null ? base : screen;
    bool on(_Slot s) {
      final w = s.modal ? popup : full;
      if (w == null || w.program == null) return false;
      return w.program == s.program &&
          (s.dynpro == null || w.dynpro == s.dynpro);
    }

    return [
      for (final shell in barChartShells)
        if (!destroyed.contains(shell))
          if (_slots[shell] case final s? when on(s))
            if (build(shell) case final m?) m,
    ];
  }
}
