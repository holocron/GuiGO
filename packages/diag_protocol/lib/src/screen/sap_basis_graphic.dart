/// The classic Basis-Graphik BUSINESS and STATISTICS graphics (function
/// group GRAP / SAPLGRAP, dynpro 0100): the inline GRAPH item 16/2/5 stream
/// ([InlineGraphStream], interface `BUSG` / `STAT`) decoded into a chart
/// model — the network editor `NETZ` is [parseNetPlanInline]'s.
///
/// The stream (the ABAP's own GR_SEND, include LGRAPFGL): NUL-terminated
/// tokens, each led by its kind character — `T<section>` a section header,
/// `C<text>` a text field, `N<number>` a number. A type P number is the
/// user's WRITE format (GRBUSG_3 sends 153470 as `N153.470`, logon FR), a
/// type F one the F-to-C move (`N-1.0000000000000000E+00`). The preamble
/// before the first section — `1V3.4 LF B<iface> D, I<iface> D, 13 $V01 $A`
/// — and the `E R` end are framing.
///
/// STAT_GRAPH (GRSTAT_1; a recorded session srv[21], one
/// 3 352 B chunk, the real SAP GUI for Windows' own trace) sends:
/// * `T$OPTS` the global options `CSET <KEY> <value>` — SYSID / SAPRL /
/// SAPSYS, MAIL, ZL_FLAG (the zero line), SCALE MAN|AUTO, X_ART / Y_ART
/// LIN|LOG, XTCKS / YTCKS (tick counts), STEPX / STEPY, XDECS / YDECS,
/// GRIDDISP / GRIDTYPE / GRIDDENS, CLR_* — and, under SCALE MAN, `CSET
/// XRNGL` + `N<lower>` … `CSET YRNGU` + `N<upper>`;
/// * `T$TEXT` key / value pairs: TITLE, TTEXT (title), UTEXT (subtitle),
/// TAXIS (axis title), VALT;
/// * per curve `T$BEGIN`, `T$DATA` its rows' numeric components (x, y
/// pairs: GRSTAT_1's DATA is W TYPE P, F TYPE F), then `T$OPTS` its
/// options from the caller's OPTS table — COLOR, THICK, LTEXT (legend
/// text), DTEXT, C_ART (1 = markers only: GRSTAT_1's third curve, yellow
/// squares), CTYPE (the marker: 4 = square), IDENT.
///
/// GRAPH_2D / GRAPH_MATRIX_2D (GRBUSG_1, GRBUSG_3 —
/// a recorded session srv[71]) send `T$TEXT 2` ($TITL, title,
/// $VALT, value unit), `T$LIST 2` label / value pairs, `T$INDX` the
/// `row col` origin of each value, `T$OPTS` (`SET P2TYPE PI` = pie, VB
/// vertical bars, TD perspective bars …). GRAPH_3D (GRBUSG_2) sends
/// `T$TEXT 2` with DIM1 / DIM2 titles, `T$DIMS 2`, `TDIM1` one (blank)
/// label per value column, `TDIM2` the row labels, `T$DATA` the values row
/// by row and `T$INDX` their `row col`.
///
/// Hostile input: every list is capped, a malformed number is a gap, the
/// parse never throws.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'sap_netplan.dart' show InlineGraphKind, InlineGraphStream;

// ---------------------------------------------------------------------------
// Caps
// ---------------------------------------------------------------------------

/// At most this many tokens of one stream are read.
const int maxBasisGraphicTokens = 200000;

/// At most this many curves (STAT) / value columns (BUSG).
const int maxBasisGraphicSeries = 64;

/// At most this many points per curve / categories per business graphic.
const int maxBasisGraphicPoints = 20000;

/// Texts longer than this are cut.
const int _maxText = 256;

// ---------------------------------------------------------------------------
// The model
// ---------------------------------------------------------------------------

/// A decoded classic business or statistics graphic.
sealed class SapBasisGraphic {
  SapBasisGraphic({required this.interface, required this.options});

  /// The stream's interface (`BUSG`, `STAT`, or a WINID starting with it).
  final String interface;

  /// The global `SET` options, by upper-case key, in stream order
  /// (`SYSID` → `the test system`, `SCALE` → `MAN`, `P2TYPE` → `PI`, `XRNGL` → `0.0…`).
  final Map<String, String> options;

  /// The graphic's heading.
  String get title;
}

/// One axis of a statistics graphic.
class StatAxis {
  const StatAxis({
    this.min,
    this.max,
    this.ticks,
    this.step,
    this.decimals,
    this.logarithmic = false,
  });

  /// The manual range (`SCALE MAN`: XRNGL / XRNGU); null = from the data.
  final double? min, max;

  /// The number of tick marks (XTCKS 13 over 0 … 360 = every 30).
  final int? ticks;

  /// An explicit step (STEPX / STEPY).
  final double? step;

  /// Label decimals (XDECS / YDECS).
  final int? decimals;

  /// `X_ART LOG` / `Y_ART LOG`.
  final bool logarithmic;
}

/// How a statistics curve is drawn.
enum StatCurveStyle { line, markers }

/// The marker of a statistics curve (CTYPE). Only 4 = square is grounded
/// (GRSTAT_1 / the real GUI's yellow squares); the others are guesses.
enum StatMarker { none, plus, cross, circle, square, triangle, diamond }

/// One curve of a statistics graphic.
class StatCurve {
  StatCurve({
    required this.points,
    this.color,
    this.thickness = 1,
    this.legend = '',
    this.description = '',
    this.style = StatCurveStyle.line,
    this.marker = StatMarker.none,
    this.options = const {},
  });

  /// The (x, y) points in data order.
  final List<(double, double)> points;

  /// The SAP graphic colour index (COLOR); null = automatic.
  final int? color;

  /// THICK.
  final int thickness;

  /// LTEXT (the legend) and DTEXT (the description).
  final String legend, description;

  /// C_ART 1 = markers only, else a line.
  final StatCurveStyle style;

  /// CTYPE.
  final StatMarker marker;

  /// Every option of the curve, by key.
  final Map<String, String> options;
}

/// A statistics graphic (STAT_GRAPH: GRSTAT_*).
final class SapStatGraphic extends SapBasisGraphic {
  SapStatGraphic({
    required super.interface,
    required super.options,
    required this.title,
    this.subtitle = '',
    this.axisTitle = '',
    this.windowTitle = '',
    this.valueTitle = '',
    this.x = const StatAxis(),
    this.y = const StatAxis(),
    this.zeroLine = false,
    required this.curves,
  });

  /// TTEXT, UTEXT, TAXIS, TITLE, VALT.
  @override
  final String title;
  final String subtitle, axisTitle, windowTitle, valueTitle;

  final StatAxis x, y;

  /// `ZL_FLAG 1`: the zero line is drawn.
  final bool zeroLine;

  final List<StatCurve> curves;
}

/// How a business graphic is drawn (its P2TYPE / P3TYPE code).
enum BusgChartKind { pie, columns, bars, lines }

/// A business graphic (GRAPH_2D / GRAPH_3D / GRAPH_MATRIX_*: GRBUSG_*).
final class SapBusinessGraphic extends SapBasisGraphic {
  SapBusinessGraphic({
    required super.interface,
    required super.options,
    required this.title,
    this.valueTitle = '',
    this.dimensionTitles = const [],
    required this.categories,
    required this.seriesLabels,
    required this.values,
  });

  /// $TITL and $VALT (the value unit, `DM`).
  @override
  final String title;
  final String valueTitle;

  /// DIM1, DIM2, DIM3 titles of a 3D / 4D graphic.
  final List<String> dimensionTitles;

  /// The category (row) labels: a 2D list's labels, a 3D one's rows.
  final List<String> categories;

  /// One label per value column (series).
  final List<String> seriesLabels;

  /// values[series][category]; null = no value.
  final List<List<double?>> values;

  /// The 2D type code (P2TYPE: PI, VB, TD …), the 3D one (P3TYPE).
  String get type2d => options['P2TYPE'] ?? '';
  String get type3d => options['P3TYPE'] ?? '';

  /// The kind drawn: a single-series graphic follows P2TYPE (PI = pie —
  /// GRBUSG_3), several series P3TYPE then P2TYPE; VB / TD (the vertical
  /// and perspective bars GRBUSG_3 names) and no code are columns. HB and
  /// LN / LI are guesses (no recording names them).
  BusgChartKind get kind {
    final code = (values.length <= 1 ? type2d : _or(type3d, type2d))
        .trim()
        .toUpperCase();
    return switch (code) {
      'PI' when values.length <= 1 => BusgChartKind.pie,
      'HB' => BusgChartKind.bars,
      'LN' || 'LI' || 'LS' => BusgChartKind.lines,
      _ => BusgChartKind.columns,
    };
  }

  static String _or(String a, String b) => a.trim().isEmpty ? b : a;
}

// ---------------------------------------------------------------------------
// The stream
// ---------------------------------------------------------------------------

final Expando<_Memo> _memo = Expando('basisGraphic');

class _Memo {
  _Memo(this.value);
  final SapBasisGraphic? value;
}

/// Whether [g] carries a business or statistics graphic (by its kind, or a
/// WINID-named interface starting with `BUSG` / `STAT` — the ABAP checks
/// `G_WINID(4) = DEF_ID`).
bool isBasisChartStream(InlineGraphStream? g) {
  if (g == null) return false;
  if (g.kind == InlineGraphKind.business ||
      g.kind == InlineGraphKind.statistics) {
    return true;
  }
  final i = g.interface ?? '';
  return i.startsWith('BUSG') || i.startsWith('STAT');
}

/// The business / statistics graphic [g] holds once complete (memoized per
/// stream), null for any other stream or one still being transmitted.
SapBasisGraphic? basisGraphicOf(InlineGraphStream? g) {
  if (g == null || !g.complete || !isBasisChartStream(g)) return null;
  final m = _memo[g];
  if (m != null) return m.value;
  final v = parseBasisGraphic(g.bytes, codepage: g.codepage);
  _memo[g] = _Memo(v);
  return v;
}

/// One token of the stream: its kind character and its value.
typedef BasisToken = (String kind, String value);

/// One section of the stream: its name (`$OPTS`, `$LIST`, `DIM1`), the
/// arity after it (`$TEXT 2` → 2) and its tokens.
class BasisSection {
  BasisSection(this.name, this.arity);
  final String name;
  final int? arity;
  final List<BasisToken> tokens = [];
}

/// The preamble's interface (`ISTAT` → `STAT`) and the sections of the
/// stream [bytes] in SAP [codepage].
(String?, List<BasisSection>) basisGraphicSections(
  Uint8List bytes, {
  String codepage = '1160',
}) {
  final text = _decode(bytes, codepage);
  String? iface;
  final sections = <BasisSection>[];
  var start = 0;
  var count = 0;
  // the kind byte (05 / 04) of the first chunk leads the first token
  while (start < text.length && text.codeUnitAt(start) < 0x20) {
    start++;
  }
  for (var i = start; i <= text.length; i++) {
    if (i < text.length && text.codeUnitAt(i) != 0) continue;
    final tok = text.substring(start, i);
    start = i + 1;
    if (++count > maxBasisGraphicTokens) break;
    if (tok.isEmpty) continue;
    final kind = tok[0];
    if (kind == 'T') {
      final head = tok.substring(1).trim();
      final sp = head.indexOf(' ');
      sections.add(sp < 0
          ? BasisSection(head, null)
          : BasisSection(head.substring(0, sp),
              int.tryParse(head.substring(sp + 1).trim())));
      continue;
    }
    if (sections.isEmpty) {
      if (kind == 'I' && iface == null && tok.length > 1 && tok.length <= 21) {
        iface = tok.substring(1);
      }
      continue;
    }
    // the end framing
    if (tok == 'E' || tok == 'R') continue;
    sections.last.tokens.add((kind, tok.substring(1)));
  }
  return (iface, sections);
}

/// The business / statistics graphic of the stream [bytes] (its joined
/// GRAPH items), null when it names neither interface or holds no section.
SapBasisGraphic? parseBasisGraphic(Uint8List bytes, {String codepage = '1160'}) {
  try {
    final (iface, sections) = basisGraphicSections(bytes, codepage: codepage);
    if (iface == null || sections.isEmpty) return null;
    if (iface.startsWith('STAT')) return _stat(iface, sections);
    if (iface.startsWith('BUSG')) return _busg(iface, sections);
    return null;
  } catch (_) {
    return null; // never throws on a hostile stream
  }
}

// ---------------------------------------------------------------------------
// Options and numbers
// ---------------------------------------------------------------------------

String _cut(String s) => s.length > _maxText ? s.substring(0, _maxText) : s;

/// The `SET` options of [tokens] by key: `SET KEY VALUE`, `SET KEY=VALUE`,
/// and `SET KEY` followed by its `N` value (the manual range).
Map<String, String> _options(List<BasisToken> tokens) {
  final out = <String, String>{};
  for (var i = 0; i < tokens.length; i++) {
    final (kind, value) = tokens[i];
    if (kind != 'C') continue;
    var s = value.trim();
    if (s.length >= 4 && s.substring(0, 4).toUpperCase() == 'SET ') {
      s = s.substring(4).trimLeft();
    }
    if (s.isEmpty) continue;
    var k = 0;
    while (k < s.length && s[k] != ' ' && s[k] != '=') {
      k++;
    }
    final key = s.substring(0, k).toUpperCase();
    var v = s.substring(k).trim();
    if (v.startsWith('=')) v = v.substring(1).trim();
    if (v.isEmpty && i + 1 < tokens.length && tokens[i + 1].$1 == 'N') {
      v = tokens[++i].$2.trim();
    }
    if (key.isEmpty || out.length >= 512) continue;
    out[key] = _cut(v);
  }
  return out;
}

/// The decimal separator of a stream's WRITE-formatted numbers: SCDECC
/// when set, else read off the numbers themselves — a mark that occurs
/// twice in one number or is followed by exactly three digits groups
/// thousands (`153.470` under logon FR is 153 470), any other one is the
/// decimal mark; both in one number: the later is the decimal.
String _decimalMark(Iterable<String> numbers, String? scdecc) {
  final d = scdecc?.trim() ?? '';
  if (d == ',' || d == '.') return d;
  var dotDecimal = 0, commaDecimal = 0;
  for (final raw in numbers) {
    final s = raw.trim();
    if (s.contains('E') || s.contains('e')) continue;
    final dot = s.lastIndexOf('.'), comma = s.lastIndexOf(',');
    if (dot >= 0 && comma >= 0) {
      dot > comma ? dotDecimal++ : commaDecimal++;
      continue;
    }
    for (final (mark, at) in [('.', dot), (',', comma)]) {
      if (at < 0) continue;
      final twice = s.indexOf(mark) != at;
      final digits = s.substring(at + 1).replaceAll(RegExp(r'[^0-9]'), '');
      if (!twice && digits.length != 3) {
        mark == '.' ? dotDecimal++ : commaDecimal++;
      } else {
        mark == '.' ? commaDecimal++ : dotDecimal++;
      }
    }
  }
  // no evidence: a thousands-grouped P value ('.' groups under the
  // default logon format, GRBUSG_3), the decimal is ','
  if (dotDecimal == 0 && commaDecimal == 0) return ',';
  return dotDecimal >= commaDecimal ? '.' : ',';
}

/// A stream number: `N1.0000000000000000E+00` (type F), `N-12`, `153.470`
/// / `1.234,56-` (type P, WRITE-formatted, trailing sign) in [decimal]
/// notation. Null when malformed or not finite.
double? sapGraphicNumber(String raw, {String decimal = ','}) {
  var s = raw.trim().replaceAll(' ', '');
  if (s.isEmpty || s.length > 64) return null;
  var negative = false;
  if (s.endsWith('-')) {
    negative = true;
    s = s.substring(0, s.length - 1);
  }
  if (s.startsWith('-')) {
    negative = !negative;
    s = s.substring(1);
  } else if (s.startsWith('+')) {
    s = s.substring(1);
  }
  if (s.contains('E') || s.contains('e')) {
    s = s.replaceAll(',', '.');
  } else if (decimal == ',') {
    s = s.replaceAll('.', '').replaceAll(',', '.');
  } else {
    s = s.replaceAll(',', '');
  }
  final v = double.tryParse(s);
  if (v == null || !v.isFinite) return null;
  return negative ? -v : v;
}

int? _int(String? s) => s == null ? null : int.tryParse(s.trim());

// ---------------------------------------------------------------------------
// STAT
// ---------------------------------------------------------------------------

SapStatGraphic _stat(String iface, List<BasisSection> sections) {
  final numbers = [
    for (final s in sections)
      for (final t in s.tokens)
        if (t.$1 == 'N') t.$2,
  ];
  final globals = <String, String>{};
  final texts = <String, String>{};
  final curves = <StatCurve>[];
  final dec = _decimalMark(numbers.take(4096), null);
  List<(double, double)>? points;
  var started = false;

  void flush(Map<String, String> o) {
    final p = points;
    if (p == null) return;
    points = null;
    if (curves.length >= maxBasisGraphicSeries) return;
    curves.add(StatCurve(
      points: p,
      color: _int(o['COLOR']),
      thickness: (_int(o['THICK']) ?? 1).clamp(1, 16),
      legend: o['LTEXT'] ?? '',
      description: o['DTEXT'] ?? '',
      style: o['C_ART']?.trim() == '1'
          ? StatCurveStyle.markers
          : StatCurveStyle.line,
      marker: _marker(o['CTYPE'], o['C_ART']),
      options: o,
    ));
  }

  for (final s in sections) {
    switch (s.name) {
      case r'$OPTS':
        final o = _options(s.tokens);
        if (!started) {
          globals.addAll(o);
        } else {
          flush(o);
        }
      case r'$TEXT':
        final t = s.tokens;
        for (var i = 0; i + 1 < t.length; i += 2) {
          texts[t[i].$2.trim().toUpperCase()] = _cut(t[i + 1].$2.trim());
        }
      case r'$BEGIN':
        flush(const {});
        started = true;
        points = <(double, double)>[];
      case r'$DATA':
        points ??= <(double, double)>[];
        final row = <double?>[
          for (final t in s.tokens)
            if (t.$1 == 'N') sapGraphicNumber(t.$2, decimal: dec),
        ];
        for (var i = 0; i + 1 < row.length; i += 2) {
          if (points!.length >= maxBasisGraphicPoints) break;
          final x = row[i], y = row[i + 1];
          if (x != null && y != null) points!.add((x, y));
        }
      default:
        break;
    }
  }
  flush(const {});

  StatAxis axis(String a) {
    final man = (globals['SCALE'] ?? '').toUpperCase() == 'MAN';
    double? n(String k) =>
        man ? sapGraphicNumber(globals[k] ?? '', decimal: dec) : null;
    final step = sapGraphicNumber(globals['STEP$a'] ?? '', decimal: dec);
    return StatAxis(
      min: n('${a}RNGL'),
      max: n('${a}RNGU'),
      ticks: _int(globals['${a}TCKS']),
      step: step != null && step > 0 ? step : null,
      decimals: _int(globals['${a}DECS'])?.clamp(0, 10),
      logarithmic: (globals['${a}_ART'] ?? '').toUpperCase() == 'LOG',
    );
  }

  return SapStatGraphic(
    interface: iface,
    options: globals,
    title: texts['TTEXT'] ?? texts['TITLE'] ?? '',
    subtitle: texts['UTEXT'] ?? '',
    axisTitle: texts['TAXIS'] ?? '',
    windowTitle: texts['TITLE'] ?? '',
    valueTitle: texts['VALT'] ?? '',
    x: axis('X'),
    y: axis('Y'),
    zeroLine: (globals['ZL_FLAG'] ?? '').trim() == '1',
    curves: curves,
  );
}

StatMarker _marker(String? ctype, String? cArt) => switch (ctype?.trim()) {
      '1' => StatMarker.plus,
      '2' => StatMarker.cross,
      '3' => StatMarker.circle,
      '4' => StatMarker.square,
      '5' => StatMarker.triangle,
      '6' => StatMarker.diamond,
      // markers-only without a CTYPE: squares (the one recorded marker)
      _ => cArt?.trim() == '1' ? StatMarker.square : StatMarker.none,
    };

// ---------------------------------------------------------------------------
// BUSG
// ---------------------------------------------------------------------------

SapBusinessGraphic _busg(String iface, List<BasisSection> sections) {
  final options = <String, String>{};
  final texts = <String, String>{};
  final list = <(String, BasisToken)>[];
  final dims = <String, List<String>>{};
  final data = <String>[];
  final index = <(int, int)?>[];
  for (final s in sections) {
    final t = s.tokens;
    switch (s.name) {
      case r'$OPTS':
        options.addAll(_options(t));
      case r'$TEXT':
        for (var i = 0; i + 1 < t.length; i += 2) {
          texts[t[i].$2.trim().toUpperCase()] = _cut(t[i + 1].$2.trim());
        }
      case r'$LIST':
        for (var i = 0; i + 1 < t.length; i += 2) {
          if (list.length >= maxBasisGraphicPoints) break;
          list.add((_cut(t[i].$2.trim()), t[i + 1]));
        }
      case 'DIM1' || 'DIM2' || 'DIM3':
        dims[s.name] = [
          for (final x in t.take(maxBasisGraphicPoints)) _cut(x.$2.trim()),
        ];
      case r'$DATA':
        for (final x in t) {
          if (data.length >= maxBasisGraphicPoints * 4) break;
          if (x.$1 == 'N' || x.$1 == 'C') data.add(x.$2);
        }
      case r'$INDX':
        for (final x in t.take(maxBasisGraphicPoints * 4)) {
          final p = x.$2.trim().split(RegExp(r'\s+'));
          final r = p.isNotEmpty ? int.tryParse(p.first) : null;
          final c = p.length > 1 ? int.tryParse(p[1]) : null;
          index.add(r != null && c != null ? (r, c) : null);
        }
      default:
        break;
    }
  }
  final dec = _decimalMark(
    [...list.map((e) => e.$2.$2), ...data].take(4096),
    options['SCDECC'],
  );
  final title = texts[r'$TITL'] ?? '';
  final valt = texts[r'$VALT'] ?? '';
  final dimTitles = [
    for (final k in ['DIM1', 'DIM2', 'DIM3'])
      if (texts[k] != null) texts[k]!,
  ];
  if (list.isNotEmpty) {
    // a 2D list: one series of label / value pairs
    return SapBusinessGraphic(
      interface: iface,
      options: options,
      title: title,
      valueTitle: valt,
      dimensionTitles: dimTitles,
      categories: [for (final e in list) e.$1],
      seriesLabels: [valt],
      values: [
        [for (final e in list) sapGraphicNumber(e.$2.$2, decimal: dec)],
      ],
    );
  }
  // a 3D matrix: $DATA row by row, each value's `row col` in $INDX (value
  // columns 2 … 7, the first is the row text)
  final rows = dims['DIM2'] ?? const <String>[];
  final values = [for (final d in data) sapGraphicNumber(d, decimal: dec)];
  final cells = <(int, int), double?>{};
  var maxRow = rows.length, minCol = 1 << 30, maxCol = 0;
  final width = (dims['DIM1']?.length ?? 0) > 0
      ? dims['DIM1']!.length
      : rows.isEmpty
          ? 1
          : (values.length / rows.length).ceil().clamp(1, 64);
  for (var i = 0; i < values.length; i++) {
    final at = i < index.length ? index[i] : null;
    final rc = at ?? (i ~/ width + 1, i % width + 2);
    if (rc.$1 < 1 || rc.$2 < 1 || rc.$1 > maxBasisGraphicPoints) continue;
    cells[rc] = values[i];
    if (rc.$1 > maxRow) maxRow = rc.$1;
    if (rc.$2 < minCol) minCol = rc.$2;
    if (rc.$2 > maxCol) maxCol = rc.$2;
  }
  if (cells.isEmpty) {
    minCol = 2;
    maxCol = 1;
  }
  final cols = [
    for (var c = minCol; c <= maxCol && c - minCol < maxBasisGraphicSeries; c++)
      c,
  ];
  final colLabels = dims['DIM1'] ?? const <String>[];
  return SapBusinessGraphic(
    interface: iface,
    options: options,
    title: title,
    valueTitle: valt,
    dimensionTitles: dimTitles,
    categories: [
      for (var r = 1; r <= maxRow; r++)
        r - 1 < rows.length && rows[r - 1].isNotEmpty ? rows[r - 1] : '$r',
    ],
    seriesLabels: [
      for (final c in cols)
        c - minCol < colLabels.length && colLabels[c - minCol].isNotEmpty
            ? colLabels[c - minCol]
            : '${c - minCol + 1}',
    ],
    values: [
      for (final c in cols)
        [for (var r = 1; r <= maxRow; r++) cells[(r, c)]],
    ],
  );
}

// ---------------------------------------------------------------------------
// Codepages
// ---------------------------------------------------------------------------

String _decode(Uint8List b, String codepage) => switch (codepage) {
      '4110' => utf8.decode(b, allowMalformed: true),
      '1160' => String.fromCharCodes([
          for (final c in b)
            c >= 0x80 && c < 0xA0 ? _cp1252High[c - 0x80] : c,
        ]),
      '1127' => String.fromCharCodes([
          for (final c in b)
            c >= 0x80 ? _macRomanHigh.codeUnitAt(c - 0x80) : c,
        ]),
      _ => latin1.decode(b, allowInvalid: true),
    };

const List<int> _cp1252High = [
  0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
  0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
];

const String _macRomanHigh =
    'ÄÅÇÉÑÖÜáàâäãåçéèêëíìîïñóòôöõúùûü'
    '†°¢£§•¶ß®©™´¨≠ÆØ∞±≤≥¥µ∂∑∏π∫ªºΩæø'
    '¿¡¬√ƒ≈∆«»… ÀÃÕŒœ–—“”‘’÷◊ÿŸ⁄€‹›ﬁﬂ'
    '‡·‚„‰ÂÊÁËÈÍÎÏÌÓÔÒÚÛÙıˆ˜¯˘˙˚¸˝˛ˇ';
