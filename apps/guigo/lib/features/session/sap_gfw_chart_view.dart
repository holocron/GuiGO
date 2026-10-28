import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

import 'gfw_calendar.dart';
import 'sap_chart_view.dart'
    show ChartLabelCache, ChartSeriesData, categoryLabel, niceTicks;
import 'sap_chart_xy.dart';

/// The GFW business graphic (Graphitti chart fed by SAPGUI.GraphittiAdapt.1)
/// drawn from its model and the customizing the server sent with it
/// ([SapChartModel.gfw], [SapChartSeries.gfw]): the drawing area's title
/// font, the series' palette colours, point overrides (gradient / hatch /
/// label), the y axis' fixed range, scales and value-range band, the data
/// sheet, a histogram's density curve, the milestone trend analysis'
/// triangle with its calendar headers, the time axis at its day width.
/// Backgrounds stay the app's theme.
class GfwChartView extends StatefulWidget {
  const GfwChartView({super.key, required this.model});

  final SapChartModel model;

  @override
  State<GfwChartView> createState() => _GfwChartViewState();
}

/// The automatic colours of series the customizing leaves uncoloured.
const List<Color> _auto = [
  Color(0xFF5B9BD5), Color(0xFFED7D31), Color(0xFF70AD47), Color(0xFFFFC000),
  Color(0xFF9E7CC1), Color(0xFF4BC0C0), Color(0xFFE05A6F), Color(0xFF8C8C8C),
];

Color? _pal(int? id) => id == null ? null : gfwPalette[id];

/// A text colour the customizing sent: its default black (1) reads as the
/// theme's text on the dark background.
Color _textColor(int? id, Color theme) =>
    id == null || id == 1 ? theme : (_pal(id) ?? theme);

/// The fill of series [i]: its sent palette colour; a GFW series sent no
/// colour at all draws Graphitti's default, white (GFW_DEMO_HIER3's chart:
/// white bars with black outlines), the next ones the automatic palette.
Color gfwSeriesFill(SapChartSeries s, int i) {
  final c = _pal(s.gfw?.fill ?? s.color) ?? _pal(s.color);
  if (c != null) return c;
  return i == 0 ? const Color(0xFFFFFFFF) : _auto[i % _auto.length];
}

/// The line / marker colour of series [i] (line-family charts).
Color gfwSeriesLine(SapChartSeries s, int i) =>
    _pal(s.color) ?? _pal(s.gfw?.line) ?? _auto[i % _auto.length];

/// The outline of a filled series' areas (1033); Graphitti's default
/// white fill keeps its black outline (GFW_DEMO_HIER3's chart).
Color? gfwSeriesOutline(SapChartSeries s) =>
    _pal(s.gfw?.line) ??
    (_pal(s.gfw?.fill ?? s.color) == null ? const Color(0xFF000000) : null);

/// The GFW painters' texts: laid out through the view's [ChartLabelCache]
/// when the painter holds one ([labels]), so a repaint — a pan frame of
/// the time axis, a server turn rebuilding the screen — draws the labels
/// without laying them out again (audit 2026-10-23 P-8); a painter built
/// on its own lays each out per paint.
mixin _GfwText {
  ChartLabelCache? get labels;

  void _txt(Canvas c, String s, Offset at, Color color,
          {TextAlign align = TextAlign.left,
          double size = 11,
          double? maxWidth,
          bool vertical = false,
          Color? box,
          Color? boxBorder}) =>
      _txtWith(labels, c, s, at, color,
          align: align,
          size: size,
          maxWidth: maxWidth,
          vertical: vertical,
          box: box,
          boxBorder: boxBorder);

  double _textWidth(String s, {double size = 11}) =>
      _textWidthWith(labels, s, size: size);
}

/// [_GfwText._txt] for a text laid out through [cache] (null: per paint).
void _txtWith(ChartLabelCache? cache, Canvas c, String s, Offset at, Color color,
    {TextAlign align = TextAlign.left,
    double size = 11,
    double? maxWidth,
    bool vertical = false,
    Color? box,
    Color? boxBorder}) {
  {
    final width = maxWidth ?? 400;
    final tp = cache != null
        ? cache.label(s, color, size, maxWidth: width, ellipsis: '…')
        : (TextPainter(
            text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
            textDirection: TextDirection.ltr,
            maxLines: 1,
            ellipsis: '…',
          )..layout(maxWidth: width));
    final dx = switch (align) {
      TextAlign.right => -tp.width,
      TextAlign.center => -tp.width / 2,
      _ => 0.0,
    };
    c.save();
    c.translate(at.dx, at.dy);
    if (vertical) c.rotate(-math.pi / 2);
    final r = Rect.fromLTWH(dx, -tp.height / 2, tp.width, tp.height);
    if (box != null) {
      final b = r.inflate(3);
      c.drawRect(b, Paint()..color = box);
      if (boxBorder != null) {
        c.drawRect(b, Paint()
          ..color = boxBorder
          ..style = PaintingStyle.stroke);
      }
    }
    tp.paint(c, r.topLeft);
    c.restore();
    if (cache == null) tp.dispose();
  }
}

/// The unconstrained width of [s] (the cache measures the 11 pt labels
/// every caller asks for; null: per call).
double _textWidthWith(ChartLabelCache? cache, String s, {double size = 11}) {
  if (cache != null && size == 11) return cache.measure(s).width;
  final tp = TextPainter(
    text: TextSpan(text: s, style: TextStyle(fontSize: size)),
    textDirection: TextDirection.ltr,
  )..layout();
  final w = tp.width;
  tp.dispose();
  return w;
}

String _num(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(v.abs() < 10 ? 2 : 1);
}

/// Value ticks over [lo, hi] at most one per [minGap] px of [length]: the
/// sent label step (doubled until the labels fit), else 1-2-5 steps.
List<double> gfwTicks(double lo, double hi, double length,
    {double? step, double minGap = 22}) {
  if (hi <= lo) hi = lo + 1;
  final maxCount = math.max(1, (length / minGap).floor());
  var s = step ?? 0.0;
  if (s <= 0) {
    // the finest 1-2-5 step whose labels keep [minGap] apart
    final raw = (hi - lo) / maxCount;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    s = mag;
    for (final f in const [1, 2, 5, 10]) {
      s = f * mag;
      if ((hi - lo) / s <= maxCount) break;
    }
  }
  while ((hi - lo) / s > maxCount) {
    s *= 2;
  }
  final a = (lo / s).ceil(), b = (hi / s).floor();
  return [for (var k = a; k <= b; k++) double.parse((k * s).toStringAsPrecision(12))];
}

/// A rect filled as a GFW display context sends it: solid, a vertical
/// gradient (fading 0: [color] → [color2] downward; 3: [color2] at both
/// edges, [color] in the middle) or a hatch of [color2] lines over [color].
void gfwFillRect(Canvas c, Rect r, GfwFill? f, Color base) {
  final c1 = _pal(f?.color) ?? base;
  final c2 = _pal(f?.color2) ?? c1;
  if (f != null && f.gradient) {
    final colors = f.fading == 3 ? [c2, c1, c2] : [c1, c2];
    c.drawRect(r, Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: colors,
      ).createShader(r));
    return;
  }
  c.drawRect(r, Paint()..color = c1);
  if (f != null && f.hatched) {
    c.save();
    c.clipRect(r);
    final p = Paint()
      ..color = c2
      ..strokeWidth = 1.2;
    if (f.pattern == 6 || f.pattern == 0) {
      for (var y = r.top + 2; y < r.bottom; y += 4) {
        c.drawLine(Offset(r.left, y), Offset(r.right, y), p);
      }
    } else {
      for (var x = r.left - r.height; x < r.right; x += 5) {
        c.drawLine(Offset(x, r.bottom), Offset(x + r.height, r.top), p);
      }
    }
    c.restore();
  }
}

/// A GFW marker: 1 square, 2 diamond, 8 circle, else a triangle (the
/// milestone triangle, 81's default).
void gfwMarker(Canvas c, Offset p, int? style, Color color, {double r = 4}) {
  final paint = Paint()..color = color;
  switch (style) {
    case 1:
      c.drawRect(Rect.fromCenter(center: p, width: 2 * r, height: 2 * r), paint);
    case 2:
      c.drawPath(
        Path()
          ..moveTo(p.dx, p.dy - r - 1)
          ..lineTo(p.dx + r + 1, p.dy)
          ..lineTo(p.dx, p.dy + r + 1)
          ..lineTo(p.dx - r - 1, p.dy)
          ..close(),
        paint,
      );
    case 8:
      c.drawCircle(p, r, paint);
    default:
      c.drawPath(
        Path()
          ..moveTo(p.dx, p.dy - r - 1)
          ..lineTo(p.dx + r + 1, p.dy + r)
          ..lineTo(p.dx - r - 1, p.dy + r)
          ..close(),
        paint,
      );
  }
}

void _dashedPath(Canvas c, List<Offset> pts, Paint p, {bool dashed = false}) {
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    if (!dashed) {
      c.drawLine(a, b, p);
      continue;
    }
    final d = b - a, len = d.distance;
    if (len == 0) continue;
    final u = d / len;
    for (var t = 0.0; t < len; t += 9) {
      c.drawLine(a + u * t, a + u * math.min(len, t + 5), p);
    }
  }
}

/// The view's kind of a GFW model.
enum GfwKind { category, bars, pie, histogram, milestone, timeAxis, xy }

GfwKind gfwKindOf(SapChartModel m) => switch (m.chartType) {
  'Pie' => GfwKind.pie,
  'Histogram' => GfwKind.histogram,
  'MilestoneTrend' => GfwKind.milestone,
  'Bars' => GfwKind.bars,
  _ when m.xTime && !m.yTime && m.series.any((s) => s.xs.isNotEmpty) =>
    GfwKind.timeAxis,
  _ when m.series.any((s) => s.xs.isNotEmpty) => GfwKind.xy,
  _ => GfwKind.category,
};

/// The time axis chart's pixels per day at a day width of [mm]
/// (96 dpi logical pixels).
double gfwPxPerDay(double mm) => mm * 96 / 25.4;

class _GfwChartViewState extends State<GfwChartView> {
  /// Per model: the pie's and the xy chart's painter series.
  static final _pieSeries = Expando<List<ChartSeriesData>>();
  static final _xySeries = Expando<List<ChartSeriesData>>();

  /// The time axis' pan: the first visible day's offset from the axis
  /// start, in days.
  double _pan = 0;

  /// The laid-out texts of the chart, kept across paints: a pan frame of
  /// the time axis, a rebuild with the same model, draws them and lays
  /// none out again (audit 2026-10-23 P-8).
  final _labels = ChartLabelCache();

  /// How many text layouts the chart made (tests read it).
  int get labelLayouts => _labels.layouts;

  @override
  void dispose() {
    _labels.clear();
    super.dispose();
  }

  @override
  void didUpdateWidget(GfwChartView old) {
    super.didUpdateWidget(old);
    if (old.model.shell != widget.model.shell) _pan = 0;
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.model;
    final scheme = Theme.of(context).colorScheme;
    final look = m.gfw;
    final kind = gfwKindOf(m);
    final text = scheme.onSurface;
    final title = m.title.trim();
    final legend = <(String, Color, Widget?)>[
      if (kind == GfwKind.pie)
        for (final (i, c) in m.categories.indexed)
          (categoryLabel(c), PieChartPainter.sliceColor(i), null)
      else
        for (final (i, s) in m.series.indexed)
          if (s.label.isNotEmpty || m.series.length == 1)
            (
              s.label,
              kind == GfwKind.timeAxis || kind == GfwKind.xy
                  ? gfwSeriesLine(s, i)
                  : gfwSeriesFill(s, i),
              kind == GfwKind.timeAxis
                  ? CustomPaint(
                      size: const Size(28, 12),
                      painter: _LineSample(
                        gfwSeriesLine(s, i),
                        s.gfw?.markerStyle,
                        dashed: s.style == 34,
                      ),
                    )
                  : null,
            ),
      if (kind == GfwKind.histogram)
        for (final s in m.series)
          if ((s.gfw?.distSigma ?? 0) > 0)
            (s.gfw!.distTitle, scheme.surface, null),
    ];
    final body = switch (kind) {
      GfwKind.timeAxis => _timeAxis(m, scheme),
      _ => LayoutBuilder(
        builder: (context, cons) => CustomPaint(
          size: cons.biggest,
          painter: switch (kind) {
            // the series mapped once per model: a rebuild with the same
            // model keeps the painters' shouldRepaint false
            GfwKind.pie => PieChartPainter(
              categories: m.categories,
              series: _pieSeries[m] ??= [
                for (final s in m.series) ChartSeriesData(s.label, s.values),
              ],
              text: text,
            ),
            GfwKind.histogram => GfwHistogramPainter(m, scheme, labels: _labels),
            GfwKind.milestone => GfwMtaPainter(m, scheme, labels: _labels),
            GfwKind.xy => XyChartPainter(
              series: _xySeries[m] ??= [
                for (final (i, s) in m.series.indexed)
                  ChartSeriesData(s.label, s.values,
                      xs: s.xs, color: gfwSeriesLine(s, i)),
              ],
              xTime: m.xTime,
              yTime: m.yTime,
              milestone: false,
              axis: scheme.onSurfaceVariant,
              grid: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
            _ => GfwCategoryPainter(m, scheme,
                horizontal: kind == GfwKind.bars, labels: _labels),
          },
        ),
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _textColor(look?.titleColor, text),
                fontSize: (look?.titleSize ?? 12).clamp(9, 24).toDouble(),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        Expanded(child: body),
        // the legend: boxed, centred below the chart (the MTA's sits in
        // its plot)
        if (kind != GfwKind.milestone && legend.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  child: Wrap(
                    spacing: 12,
                    children: [
                      for (final (label, color, sample) in legend)
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          sample ??
                              Container(
                                width: 11,
                                height: 11,
                                decoration: BoxDecoration(
                                  color: color,
                                  border: Border.all(color: scheme.outline),
                                ),
                              ),
                          if (label.isNotEmpty) ...[
                            const SizedBox(width: 5),
                            Text(label, style: const TextStyle(fontSize: 11)),
                          ],
                        ]),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _timeAxis(SapChartModel m, ColorScheme scheme) {
    return LayoutBuilder(builder: (context, cons) {
      final geo = GfwTimeAxisPainter.geometry(m, cons.biggest);
      final maxPan = math.max(0.0, geo.spanDays - geo.visibleDays);
      final pan = _pan.clamp(0.0, maxPan);
      final painter = GfwTimeAxisPainter(m, scheme, pan: pan, labels: _labels);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: GestureDetector(
              onHorizontalDragUpdate: (d) => setState(() {
                _pan = (pan - d.delta.dx / geo.pxPerDay).clamp(0.0, maxPan);
              }),
              child: CustomPaint(size: Size.infinite, painter: painter),
            ),
          ),
          // the scrollbar under the axis: drag the thumb to pan
          if (maxPan > 0)
            SizedBox(
              height: 14,
              child: LayoutBuilder(builder: (context, bar) {
                final w = bar.maxWidth - geo.left;
                final thumb = math.max(24.0, w * geo.visibleDays / geo.spanDays);
                final x = geo.left + (w - thumb) * (pan / maxPan);
                return GestureDetector(
                  onHorizontalDragUpdate: (d) => setState(() {
                    _pan = (pan + d.delta.dx / math.max(1, w - thumb) * maxPan)
                        .clamp(0.0, maxPan);
                  }),
                  child: CustomPaint(
                    size: Size(bar.maxWidth, 14),
                    painter: _ScrollbarPainter(
                      Rect.fromLTWH(x, 3, thumb, 8),
                      Rect.fromLTWH(geo.left, 3, w, 8),
                      scheme,
                    ),
                  ),
                );
              }),
            ),
        ],
      );
    });
  }
}

class _ScrollbarPainter extends CustomPainter {
  _ScrollbarPainter(this.thumb, this.track, this.scheme);
  final Rect thumb, track;
  final ColorScheme scheme;

  @override
  void paint(Canvas c, Size size) {
    c.drawRRect(RRect.fromRectAndRadius(track, const Radius.circular(4)),
        Paint()..color = scheme.surfaceContainerHighest);
    c.drawRRect(RRect.fromRectAndRadius(thumb, const Radius.circular(4)),
        Paint()..color = scheme.outline);
  }

  @override
  bool shouldRepaint(_ScrollbarPainter o) => o.thumb != thumb || o.track != track;
}

class _LineSample extends CustomPainter {
  _LineSample(this.color, this.marker, {this.dashed = false});
  final Color color;
  final int? marker;
  final bool dashed;

  @override
  void paint(Canvas c, Size s) {
    final y = s.height / 2;
    _dashedPath(c, [Offset(0, y), Offset(s.width, y)],
        Paint()
          ..color = color
          ..strokeWidth = 1.5,
        dashed: dashed);
    gfwMarker(c, Offset(s.width / 2, y), marker, color, r: 3);
  }

  @override
  bool shouldRepaint(_LineSample o) => o.color != color || o.marker != marker;
}

// ---------------------------------------------------------------------------
// Columns / bars / lines on categories
// ---------------------------------------------------------------------------

/// Columns (bars: [horizontal]) or lines over the categories, with the
/// sent y range and scales, the value-range band and its titles, point
/// overrides and labels, the data sheet under the axis.
class GfwCategoryPainter extends CustomPainter with _GfwText {
  GfwCategoryPainter(this.m, this.scheme,
      {this.horizontal = false, this.labels});

  @override
  final ChartLabelCache? labels;

  final SapChartModel m;
  final ColorScheme scheme;
  final bool horizontal;

  bool get _lines => m.chartType == 'Lines' || m.chartType == 'Area';

  @override
  void paint(Canvas c, Size size) {
    final look = m.gfw;
    final n = m.categories.length;
    final text = scheme.onSurface, axis = scheme.onSurfaceVariant;
    if (n == 0 || m.series.isEmpty) {
      _txt(c, '(no chart data)', size.center(Offset.zero), axis,
          align: TextAlign.center);
      return;
    }
    // the data sheet: a row per series under the axis, when it fits
    final rowH = 15.0;
    final table = (look?.dataTable ?? false) &&
        !horizontal &&
        size.height > 140 + m.series.length * rowH;
    final nameW = table
        ? m.series.fold<double>(0, (a, s) => math.max(a, _textWidth(s.label))) + 22
        : 0.0;
    var lo = double.infinity, hi = -double.infinity;
    for (final s in m.series) {
      for (final v in s.values) {
        if (v == null) continue;
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }
    for (final r in look?.ranges ?? const <GfwValueRange>[]) {
      lo = math.min(lo, r.value);
      hi = math.max(hi, r.value);
    }
    if (lo == double.infinity) lo = hi = 0;
    lo = look?.yMin ?? math.min(lo, 0);
    if (look?.yMax != null) {
      hi = look!.yMax!;
    } else {
      final t = niceTicks(lo, hi);
      hi = t.last;
    }
    if (hi <= lo) hi = lo + 1;
    final left = math.max(horizontal ? 90.0 : 44.0, nameW);
    final bottom = 22.0 + (table ? m.series.length * rowH + 4 : 0);
    final plot = Rect.fromLTRB(left, 8, size.width - 10, size.height - bottom);
    if (plot.width <= 4 || plot.height <= 4) return;
    double vPos(double v) => horizontal
        ? plot.left + (v - lo) / (hi - lo) * plot.width
        : plot.bottom - (v - lo) / (hi - lo) * plot.height;
    final bandLen = (horizontal ? plot.height : plot.width) / n;
    double cPos(int i) => horizontal
        ? plot.top + (i + 0.5) * bandLen
        : plot.left + (i + 0.5) * bandLen;
    final grid = Paint()
      ..color = scheme.outlineVariant.withValues(alpha: 0.45)
      ..strokeWidth = 1;

    // the value-range band (the y axis' range context) behind the data
    final ranges = look?.ranges ?? const <GfwValueRange>[];
    if (ranges.length >= 2) {
      final a = vPos(ranges.first.value), b = vPos(ranges.last.value);
      final r = horizontal
          ? Rect.fromLTRB(math.min(a, b), plot.top, math.max(a, b), plot.bottom)
          : Rect.fromLTRB(plot.left, math.min(a, b), plot.right, math.max(a, b));
      c.save();
      c.clipRect(r);
      gfwFillRect(c, r, look!.rangeFill, scheme.primary.withValues(alpha: 0.2));
      c.restore();
    }
    // the grid: the finer scale's step, the labels at the coarser one —
    // both thinned to what the pane's length can carry
    final len = horizontal ? plot.width : plot.height;
    // labels at least 28 px apart (a small pane's axis — GFW_DEMO_HIER3's
    // chart — keeps a few readable ones), the grid at least 8 px
    final labels = gfwTicks(lo, hi, len, step: look?.yLabelStep, minGap: 28);
    final gridTicks = gfwTicks(lo, hi, len, step: look?.yGridStep, minGap: 8);
    for (final t in gridTicks) {
      final p = vPos(t);
      horizontal
          ? c.drawLine(Offset(p, plot.top), Offset(p, plot.bottom), grid)
          : c.drawLine(Offset(plot.left, p), Offset(plot.right, p), grid);
    }
    for (final t in labels) {
      final p = vPos(t);
      horizontal
          ? _txt(c, _num(t), Offset(p, plot.bottom + 10), axis,
              align: TextAlign.center)
          : _txt(c, _num(t), Offset(plot.left - 5, p), axis,
              align: TextAlign.right);
    }
    // category boundaries and mid lines
    for (var i = 0; i <= n; i++) {
      final p = (horizontal ? plot.top : plot.left) + i * bandLen;
      final mid = p + bandLen / 2;
      if (horizontal) {
        c.drawLine(Offset(plot.left, p), Offset(plot.right, p), grid);
      } else {
        c.drawLine(Offset(p, plot.top), Offset(p, plot.bottom), grid);
        if (i < n) {
          c.drawLine(Offset(mid, plot.top), Offset(mid, plot.bottom), grid);
        }
      }
    }
    c.drawRect(plot, Paint()
      ..color = axis
      ..style = PaintingStyle.stroke);
    // category labels (as many as fit)
    var widest = 0.0;
    for (final s in m.categories) {
      widest = math.max(widest, _textWidth(categoryLabel(s)));
    }
    final every = horizontal ? 1 : labelEvery(widest, bandLen);
    for (var i = 0; i < n; i += every) {
      final s = categoryLabel(m.categories[i]);
      horizontal
          ? _txt(c, s, Offset(plot.left - 6, cPos(i)), axis,
              align: TextAlign.right, maxWidth: left - 10)
          : _txt(c, s, Offset(cPos(i), plot.bottom + 10), axis,
              align: TextAlign.center, maxWidth: bandLen * every);
    }

    // the data
    c.save();
    c.clipRect(plot.inflate(1));
    final k = m.series.length;
    final barW = bandLen * 0.6 / k;
    final zero = vPos(math.max(lo, 0));
    final pointLabels = <(Offset, String, int?)>[];
    for (final (si, s) in m.series.indexed) {
      final fill = gfwSeriesFill(s, si);
      final outline = gfwSeriesOutline(s);
      if (_lines) {
        final pts = <Offset>[
          for (var i = 0; i < n && i < s.values.length; i++)
            if (s.values[i] != null) Offset(cPos(i), vPos(s.values[i]!)),
        ];
        final line = gfwSeriesLine(s, si);
        _dashedPath(c, pts, Paint()
          ..color = line
          ..strokeWidth = 2);
        for (final p in pts) {
          gfwMarker(c, p, s.gfw?.markerStyle, line, r: 3);
        }
        continue;
      }
      for (var i = 0; i < n && i < s.values.length; i++) {
        final v = s.values[i];
        if (v == null) continue;
        final c0 = cPos(i) - bandLen * 0.3 + si * barW;
        final r = horizontal
            ? Rect.fromLTRB(math.min(zero, vPos(v)), c0, math.max(zero, vPos(v)), c0 + barW)
            : Rect.fromLTRB(c0, math.min(zero, vPos(v)), c0 + barW, math.max(zero, vPos(v)));
        final pl = s.gfw?.points[i];
        gfwFillRect(c, r, pl?.fill, fill);
        if (outline != null && r.width > 0 && r.height > 0) {
          c.drawRect(r, Paint()
            ..color = outline
            ..style = PaintingStyle.stroke);
        }
        if (pl?.label != null) {
          pointLabels.add((
            horizontal ? r.centerRight + const Offset(6, 0) : r.topCenter - const Offset(0, 10),
            pl!.label!,
            pl.labelBg,
          ));
        }
      }
    }
    c.restore();
    for (final (at, s, bg) in pointLabels) {
      _txt(c, s, at, Colors.black,
          align: horizontal ? TextAlign.left : TextAlign.center,
          box: _pal(bg) ?? Colors.white,
          boxBorder: Colors.black54);
    }
    // the value-range titles: grey boxes at the plot's left
    for (final r in ranges) {
      if (r.title.isEmpty) continue;
      final p = vPos(r.value);
      _txt(c, r.title,
          horizontal ? Offset(p, plot.top + 10) : Offset(plot.left + 6, p),
          Colors.black,
          box: const Color(0xFFC0C0C0),
          boxBorder: Colors.black54,
          align: horizontal ? TextAlign.center : TextAlign.left);
    }
    // the data sheet: swatch, name, the value per category
    if (table) {
      var y = plot.bottom + 22 + rowH / 2;
      for (final (si, s) in m.series.indexed) {
        c.drawRect(Rect.fromLTWH(4, y - 5, 10, 10),
            Paint()..color = gfwSeriesFill(s, si));
        _txt(c, s.label, Offset(18, y), text, maxWidth: left - 20);
        for (var i = 0; i < n && i < s.values.length; i++) {
          final v = s.values[i];
          _txt(c, v == null ? '–' : _num(v), Offset(cPos(i), y), text,
              align: TextAlign.center, maxWidth: bandLen);
        }
        c.drawLine(Offset(0, y + rowH / 2), Offset(plot.right, y + rowH / 2), grid);
        y += rowH;
      }
    }
  }

  @override
  bool shouldRepaint(GfwCategoryPainter o) =>
      !identical(o.m, m) || o.scheme != scheme || o.horizontal != horizontal;
}

// ---------------------------------------------------------------------------
// The histogram with its normal density
// ---------------------------------------------------------------------------

/// The bins of a histogram: each category value x_i opens the bin
/// [x_i, x_i+1) (the last as wide as the one before it), heights the
/// values.
List<(double, double, double)> gfwHistogramBins(SapChartModel m) {
  final s = m.series.isEmpty ? null : m.series.first;
  if (s == null) return const [];
  final xs = <double>[
    for (final k in s.keys) double.tryParse(k.trim()) ?? double.nan,
  ];
  final out = <(double, double, double)>[];
  for (var i = 0; i < xs.length && i < s.values.length; i++) {
    final x = xs[i];
    if (x.isNaN) continue;
    final w = i + 1 < xs.length && !xs[i + 1].isNaN
        ? xs[i + 1] - x
        : (i > 0 && !xs[i - 1].isNaN ? x - xs[i - 1] : 1.0);
    out.add((x, x + w, s.values[i] ?? 0));
  }
  return out;
}

/// The density the histogram overlays: the normal density of the sent
/// mean / deviation (CO_STD_DISTRIB_MEAN / _DEVIATION) scaled to the
/// histogram's area (Σ height x width), so the curve and the bars cover
/// the same area — GFW_PROG_HISTOGRAM: 30 / 8 over 120 x 10 = 1200, its
/// peak 1200 / (8 √(2π)) ≈ 59.8.
double Function(double x)? gfwDensity(SapChartModel m) {
  final s = m.series.isEmpty ? null : m.series.first;
  final mu = s?.gfw?.distMean, sigma = s?.gfw?.distSigma;
  if (mu == null || sigma == null || sigma <= 0) return null;
  final area = gfwHistogramBins(m)
      .fold<double>(0, (a, b) => a + b.$3 * (b.$2 - b.$1));
  final k = area / (sigma * math.sqrt(2 * math.pi));
  return (x) => k * math.exp(-math.pow(x - mu, 2) / (2 * sigma * sigma));
}

class GfwHistogramPainter extends CustomPainter with _GfwText {
  GfwHistogramPainter(this.m, this.scheme, {this.labels});

  @override
  final ChartLabelCache? labels;
  final SapChartModel m;
  final ColorScheme scheme;

  @override
  void paint(Canvas c, Size size) {
    final bins = gfwHistogramBins(m);
    final axis = scheme.onSurfaceVariant, text = scheme.onSurface;
    if (bins.isEmpty) return;
    final s = m.series.first;
    final f = gfwDensity(m);
    final mu = s.gfw?.distMean, sigma = s.gfw?.distSigma;
    var xLo = bins.first.$1, xHi = bins.last.$2;
    if (f != null) {
      xLo = math.min(xLo, mu! - 3.75 * sigma!);
      xHi = math.max(xHi, mu + 3.75 * sigma);
    }
    var yHi = bins.fold<double>(0, (a, b) => math.max(a, b.$3));
    if (f != null) yHi = math.max(yHi, f(mu!));
    final plot = Rect.fromLTRB(40, 8, size.width - 10, size.height - 34);
    if (plot.width <= 4 || plot.height <= 4) return;
    final xt = gfwTicks(xLo, xHi, plot.width, minGap: 24);
    final x0 = math.min(xLo, xt.first), x1 = math.max(xHi, xt.last);
    final yt = gfwTicks(0, yHi, plot.height, minGap: 16);
    final y1 = math.max(yHi, yt.last);
    double px(double x) => plot.left + (x - x0) / (x1 - x0) * plot.width;
    double py(double y) => plot.bottom - y / y1 * plot.height;
    final grid = Paint()
      ..color = scheme.outlineVariant.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    for (final t in yt) {
      c.drawLine(Offset(plot.left, py(t)), Offset(plot.right, py(t)), grid);
      _txt(c, _num(t), Offset(plot.left - 5, py(t)), axis, align: TextAlign.right);
    }
    for (final t in xt) {
      c.drawLine(Offset(px(t), plot.bottom), Offset(px(t), plot.bottom + 3), grid);
      // the x labels rotated, as Graphitti writes them
      _txt(c, _num(t), Offset(px(t), plot.bottom + 5), axis,
          vertical: true, align: TextAlign.right);
    }
    c.drawRect(plot, Paint()
      ..color = axis
      ..style = PaintingStyle.stroke);
    final fill = gfwSeriesFill(s, 0);
    final outline = gfwSeriesOutline(s);
    for (final (a, b, h) in bins) {
      if (h <= 0) continue;
      final r = Rect.fromLTRB(px(a), py(h), px(b), py(0));
      c.drawRect(r, Paint()..color = fill);
      if (outline != null) {
        c.drawRect(r, Paint()
          ..color = outline
          ..style = PaintingStyle.stroke);
      }
    }
    if (f == null) return;
    final path = Path();
    final fillPath = Path()..moveTo(plot.left, py(0));
    for (var i = 0; i <= 200; i++) {
      final x = x0 + (x1 - x0) * i / 200;
      final o = Offset(px(x), py(f(x)));
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      fillPath.lineTo(o.dx, o.dy);
    }
    fillPath
      ..lineTo(plot.right, py(0))
      ..close();
    c.save();
    c.clipRect(plot);
    // the area under the curve: a translucent overlap over the bars
    c.drawPath(fillPath, Paint()..color = text.withValues(alpha: 0.16));
    c.drawPath(path, Paint()
      ..color = text
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6);
    c.restore();
    final title = s.gfw!.distTitle;
    if (title.isNotEmpty) {
      _txt(c, title, Offset(px(mu!) + 6, py(f(mu)) + 10), text);
    }
  }

  @override
  bool shouldRepaint(GfwHistogramPainter o) => !identical(o.m, m) || o.scheme != scheme;
}

// ---------------------------------------------------------------------------
// Calendar header bands (the MTA's and the time axis')
// ---------------------------------------------------------------------------

/// One header band: [cells] laid along [band] (horizontal: x from
/// [pos]; vertical: y from [pos], upward), each a filled, bordered cell
/// with its label — the full one where it fits, else the short one, else
/// every [labelEvery]-th label (RI 1, RI 3, …). With [visible] (days,
/// from–to) only the cells meeting it are drawn — a pan frame lays out the
/// labels on screen, not the whole axis; the every-k labelling still
/// counts from the first cell, so it holds still while panning.
void gfwPaintBand(
  Canvas c,
  Rect band,
  List<CalCell> cells,
  double Function(double day) pos, {
  required bool vertical,
  required Color fill,
  required Color border,
  required Color text,
  bool rotate = false,
  (double, double)? visible,
  ChartLabelCache? labels,
}) {
  final b = Paint()
    ..color = border
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.8;
  final f = Paint()..color = fill;
  final widest = _widestShort[cells] ??= cells.fold<double>(
    0,
    (w, cell) => math.max(
        w, _textWidthWith(labels, cell.short.isEmpty ? cell.label : cell.short)),
  );
  double along(CalCell cell) => (pos(cell.to) - pos(cell.from)).abs();
  final typical = cells.isEmpty ? 0.0 : cells.map(along).reduce(math.max);
  final labelLen = vertical && !rotate ? 13.0 : widest;
  final every = labelEvery(labelLen, typical);
  for (final (i, cell) in cells.indexed) {
    if (visible != null &&
        (cell.to < visible.$1 || cell.from > visible.$2)) {
      continue;
    }
    final a = pos(cell.from), z = pos(cell.to);
    final r = vertical
        ? Rect.fromLTRB(band.left, math.min(a, z), band.right, math.max(a, z))
        : Rect.fromLTRB(math.min(a, z), band.top, math.max(a, z), band.bottom);
    if (r.width <= 0 || r.height <= 0) continue;
    c.drawRect(r, f);
    c.drawRect(r, b);
    final room = vertical && !rotate ? r.width : (vertical ? r.height : r.width);
    var label = cell.label;
    if (_textWidthWith(labels, label) + 4 > room) label = cell.short;
    if (label.isEmpty || _textWidthWith(labels, label) + 4 > room) {
      if (every > 1 && i % every != 0) continue;
      label = cell.short.isEmpty ? cell.label : cell.short;
      if (_textWidthWith(labels, label) > room * every) continue;
    }
    _txtWith(labels, c, label, r.center, text,
        align: TextAlign.center, vertical: vertical && rotate, maxWidth: 200);
  }
}

/// Per cell list (a time axis' memoized weeks): its widest short label.
final _widestShort = Expando<double>();

// ---------------------------------------------------------------------------
// The milestone trend analysis
// ---------------------------------------------------------------------------

class GfwMtaPainter extends CustomPainter with _GfwText {
  GfwMtaPainter(this.m, this.scheme, {this.labels});

  @override
  final ChartLabelCache? labels;
  final SapChartModel m;
  final ColorScheme scheme;

  static const monthBand = 18.0, riBand = 18.0, riCol = 46.0;

  @override
  void paint(Canvas c, Size size) {
    var lo = double.infinity, hi = -double.infinity;
    for (final s in m.series) {
      for (final v in [...s.xs, ...s.values]) {
        if (v == null) continue;
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }
    if (lo == double.infinity) return;
    final (a, z) = mtaRange(lo, hi);
    final lang = m.gfw?.language ?? '';
    final plot = Rect.fromLTRB(monthBand + riCol, monthBand + riBand,
        size.width - 6, size.height - 6);
    if (plot.width <= 8 || plot.height <= 8) return;
    double px(double d) => plot.left + (d - a) / (z - a) * plot.width;
    // the forecast axis grows upward: RI 1 at the bottom
    double py(double d) => plot.bottom - (d - a) / (z - a) * plot.height;
    final axis = scheme.onSurfaceVariant, text = scheme.onSurface;
    final sent = _pal(m.gfw?.headerFill);
    final fill = sent == null
        ? scheme.surfaceContainerHighest
        : Color.alphaBlend(sent.withValues(alpha: 0.28), scheme.surface);
    final border = scheme.outline;
    final months = monthCells(a, z, lang), weeks = weekCells(a, z);
    // x headers above the plot: months over the reporting intervals
    gfwPaintBand(c, Rect.fromLTRB(plot.left, 0, plot.right, monthBand), months, px,
        vertical: false, fill: fill, border: border, text: text, labels: labels);
    gfwPaintBand(c, Rect.fromLTRB(plot.left, monthBand, plot.right, monthBand + riBand),
        weeks, px,
        vertical: false, fill: fill, border: border, text: text, labels: labels);
    // y headers on the left: months as tall vertical bands, the
    // reporting intervals in rows
    gfwPaintBand(c, Rect.fromLTRB(0, plot.top, monthBand, plot.bottom), months, py,
        vertical: true,
        rotate: true,
        fill: fill,
        border: border,
        text: text,
        labels: labels);
    gfwPaintBand(c, Rect.fromLTRB(monthBand, plot.top, monthBand + riCol, plot.bottom),
        weeks, py,
        vertical: true, fill: fill, border: border, text: text, labels: labels);
    // the triangle: grid lines only above the diagonal (forecast >= report)
    final grid = Paint()
      ..color = scheme.outlineVariant.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    for (var t = a; t <= z + 1e-9; t += 7) {
      c.drawLine(Offset(px(t), py(t)), Offset(px(t), plot.top), grid);
      c.drawLine(Offset(plot.left, py(t)), Offset(px(t), py(t)), grid);
    }
    final edge = Paint()
      ..color = axis
      ..strokeWidth = 1.2;
    c.drawLine(plot.bottomLeft, plot.topRight, edge);
    c.drawLine(plot.bottomLeft, plot.topLeft, edge);
    c.drawLine(plot.topLeft, plot.topRight, edge);
    // the milestones: thin lines, diamond markers
    for (final (si, s) in m.series.indexed) {
      final color = gfwSeriesLine(s, si);
      final pts = <Offset>[
        for (var i = 0; i < s.xs.length && i < s.values.length; i++)
          if (s.xs[i] != null && s.values[i] != null)
            Offset(px(s.xs[i]!), py(s.values[i]!)),
      ];
      _dashedPath(c, pts, Paint()
        ..color = color
        ..strokeWidth = 1.4);
      for (final p in pts) {
        gfwMarker(c, p, s.gfw?.markerStyle ?? 2, color, r: 3.5);
      }
    }
    // the legend: boxed at the bottom right, in the empty half
    final rows = [
      for (final (si, s) in m.series.indexed) (s.label, gfwSeriesLine(s, si), s.gfw?.markerStyle ?? 2),
    ];
    if (rows.isEmpty) return;
    final w = rows.fold<double>(0, (x, r) => math.max(x, _textWidth(r.$1))) + 30;
    final h = rows.length * 16.0 + 6;
    final box = Rect.fromLTWH(plot.right - w - 8, plot.bottom - h - 8, w, h);
    c.drawRect(box, Paint()..color = scheme.surface);
    c.drawRect(box, Paint()
      ..color = border
      ..style = PaintingStyle.stroke);
    for (final (i, (label, color, marker)) in rows.indexed) {
      final y = box.top + 11 + i * 16.0;
      c.drawLine(Offset(box.left + 4, y), Offset(box.left + 20, y), Paint()
        ..color = color
        ..strokeWidth = 1.4);
      gfwMarker(c, Offset(box.left + 12, y), marker, color, r: 3);
      _txt(c, label, Offset(box.left + 25, y), text);
    }
  }

  @override
  bool shouldRepaint(GfwMtaPainter o) => !identical(o.m, m) || o.scheme != scheme;
}

// ---------------------------------------------------------------------------
// The time axis chart
// ---------------------------------------------------------------------------

/// The time axis chart's layout in one size.
class GfwTimeGeometry {
  GfwTimeGeometry(this.start, this.end, this.pxPerDay, this.plot, this.left);
  final double start, end, pxPerDay, left;
  final Rect plot;
  double get spanDays => end - start;
  double get visibleDays => plot.width / pxPerDay;
}

class GfwTimeAxisPainter extends CustomPainter with _GfwText {
  GfwTimeAxisPainter(this.m, this.scheme, {this.pan = 0, this.labels});

  @override
  final ChartLabelCache? labels;
  final SapChartModel m;
  final ColorScheme scheme;
  final double pan;

  static const left = 40.0, dayRow = 16.0, riRow = 16.0;

  static (double, double) _range(SapChartModel m) {
    var lo = double.infinity, hi = -double.infinity;
    for (final s in m.series) {
      for (final x in s.xs) {
        if (x == null) continue;
        lo = math.min(lo, x);
        hi = math.max(hi, x);
      }
    }
    if (lo == double.infinity) return (0, 1);
    return (dayFloor(lo), dayFloor(hi) + 1);
  }

  static GfwTimeGeometry geometry(SapChartModel m, Size size) {
    final (a, z) = _range(m);
    final plot = Rect.fromLTRB(left, 8, size.width - 8, size.height - dayRow - riRow - 4);
    // the sent day width (CO_DAY_WIDTH, 1/100 mm, when not automatic)
    // opens the axis at that zoom; without one it fits the whole range
    final mm = m.gfw?.xDayWidthMm;
    final ppd = mm != null
        ? gfwPxPerDay(mm)
        : (plot.width / math.max(1, z - a));
    return GfwTimeGeometry(a, z, ppd, plot, left);
  }

  @override
  void paint(Canvas c, Size size) {
    final g = geometry(m, size);
    final plot = g.plot;
    if (plot.width <= 4 || plot.height <= 4) return;
    final axis = scheme.onSurfaceVariant, text = scheme.onSurface;
    final v0 = g.start + pan, v1 = v0 + g.visibleDays;
    double px(double d) => plot.left + (d - v0) * g.pxPerDay;
    // y: from the lowest value to the highest + 10 %, on whole label steps
    var lo = double.infinity, hi = -double.infinity;
    for (final s in m.series) {
      for (final v in s.values) {
        if (v == null) continue;
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }
    if (lo == double.infinity) lo = hi = 0;
    final pad = (hi - lo) * 0.1;
    final ticks = gfwTicks(lo, hi + pad, plot.height, minGap: 30);
    final step = ticks.length > 1 ? ticks[1] - ticks[0] : 1.0;
    final y0 = (lo / step).floor() * step, y1 = ((hi + pad) / step).ceil() * step;
    double py(double v) => plot.bottom - (v - y0) / (y1 - y0) * plot.height;
    final grid = Paint()
      ..color = scheme.outlineVariant.withValues(alpha: 0.4)
      ..strokeWidth = 1;
    // a horizontal line per y unit (when they stay apart), labels per step
    final unit = (y1 - y0) / plot.height * 4 <= 1 ? 1.0 : step;
    for (var v = y0; v <= y1 + 1e-9; v += unit) {
      c.drawLine(Offset(plot.left, py(v)), Offset(plot.right, py(v)), grid);
    }
    for (var v = y0; v <= y1 + 1e-9; v += step) {
      _txt(c, _num(v), Offset(plot.left - 5, py(v)), axis, align: TextAlign.right);
      c.drawLine(Offset(plot.left - 3, py(v)), Offset(plot.left, py(v)), grid);
    }
    c.save();
    c.clipRect(Rect.fromLTRB(plot.left, 0, plot.right, size.height));
    // a vertical line per day
    for (var d = dayFloor(v0); d <= v1; d++) {
      c.drawLine(Offset(px(d), plot.top), Offset(px(d), plot.bottom), grid);
    }
    // the two header rows below the plot: day labels, reporting intervals —
    // the visible span's only (a label's cell from just left of it on, on
    // the axis' own every-k grid from its first day)
    final every = labelEvery(_textWidth('00.00'), g.pxPerDay);
    final first = dayFloor(g.start);
    final k = math.max(0, ((v0 - first) / every).floor() - 1);
    final days = dayCells(
      first + k * every,
      math.min(g.end, v1 + every),
      every,
    );
    final fill = _pal(m.gfw?.headerFill) == null || m.gfw?.headerFill == 2
        ? scheme.surfaceContainerHighest
        : Color.alphaBlend(_pal(m.gfw!.headerFill)!.withValues(alpha: 0.28), scheme.surface);
    for (final d in days) {
      _txt(c, d.label, Offset(px(d.from), plot.bottom + dayRow / 2 + 2), axis,
          align: TextAlign.center);
    }
    gfwPaintBand(c, Rect.fromLTRB(plot.left, plot.bottom + dayRow + 2, plot.right,
            plot.bottom + dayRow + riRow + 2),
        _weeks[m] ??= weekCells(g.start, g.end), px,
        vertical: false, fill: fill, border: scheme.outline, text: text,
        visible: (v0 - 1, v1 + 1), labels: labels);
    // the series: thin dashed lines (style 34), square markers; a point
    // whose bundle switches its line off breaks the line into it
    c.clipRect(plot.inflate(5));
    for (final (si, s) in m.series.indexed) {
      final color = gfwSeriesLine(s, si);
      final p = Paint()
        ..color = color
        ..strokeWidth = 1.3;
      Offset? prev;
      for (var i = 0; i < s.xs.length && i < s.values.length; i++) {
        final x = s.xs[i], v = s.values[i];
        if (x == null || v == null) {
          prev = null;
          continue;
        }
        final o = Offset(px(x), py(v));
        if (prev != null && !(s.gfw?.points[i]?.noLine ?? false)) {
          _dashedPath(c, [prev, o], p, dashed: s.style == 34);
        }
        prev = o;
      }
      for (var i = 0; i < s.xs.length && i < s.values.length; i++) {
        final x = s.xs[i], v = s.values[i];
        if (x == null || v == null) continue;
        final own = _pal(s.gfw?.points[i]?.fill?.color);
        gfwMarker(c, Offset(px(x), py(v)), s.gfw?.markerStyle,
            own != null && own != const Color(0xFFFFFFFF) ? own : color, r: 3.5);
      }
    }
    c.restore();
    c.drawRect(plot, Paint()
      ..color = axis
      ..style = PaintingStyle.stroke);
  }

  /// Per model: the axis' week cells (the range is the model's alone — a
  /// pan frame reuses them and their measured labels).
  static final _weeks = Expando<List<CalCell>>();

  @override
  bool shouldRepaint(GfwTimeAxisPainter o) =>
      !identical(o.m, m) || o.pan != pan || o.scheme != scheme;
}
