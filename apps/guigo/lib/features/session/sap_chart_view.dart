import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One plotted series: its label and a value per category (null = gap).
class ChartSeriesData {
  const ChartSeriesData(this.label, this.values);
  final String label;
  final List<double?> values;
}

/// A SAP chart control (the DBA cockpit's metric history, Chart Engine
/// demos, …) drawn from its `<ChartData>`: categories on the x axis, one
/// line / column run per series. Touch and drag reads the values under the
/// finger. [type] follows the chart customizing ('Columns', 'TimeScatter',
/// …); no type is the Chart Engine's default, columns; an unknown one draws
/// lines.
class SapChartView extends StatefulWidget {
  const SapChartView({
    super.key,
    required this.type,
    required this.title,
    required this.categories,
    required this.series,
  });

  final String type;
  final String title;
  final List<String> categories;
  final List<ChartSeriesData> series;

  @override
  State<SapChartView> createState() => _SapChartViewState();
}

/// The chart family of a customizing chart type.
enum ChartKind { line, area, column, bar }

ChartKind chartKindOf(String type) {
  final t = type.toLowerCase();
  // no ChartType in the customizing: the Chart Engine's default, columns
  // (the GFW demo's click names its element "Columns")
  if (t.trim().isEmpty) return ChartKind.column;
  // time series (ST04's TimeScatter, Lines, Scatter…) read best as lines
  if (t.contains('scatter') || t.contains('line')) return ChartKind.line;
  if (t.contains('area')) return ChartKind.area;
  if (t.contains('column')) return ChartKind.column;
  if (t.contains('bar')) return ChartKind.bar;
  return ChartKind.line;
}

/// A category key as an axis label: 8-digit dates (20231223) read as
/// 2023-12-23; anything else as is.
String categoryLabel(String c) {
  final s = c.trim();
  if (RegExp(r'^\d{8}$').hasMatch(s)) {
    return '${s.substring(0, 4)}-${s.substring(4, 6)}-${s.substring(6)}';
  }
  return s;
}

/// "Nice" axis ticks covering [lo, hi] (1-2-5 steps), about [count] of them.
List<double> niceTicks(double lo, double hi, {int count = 5}) {
  if (hi <= lo) hi = lo + 1;
  final raw = (hi - lo) / count;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final step = (norm < 1.5 ? 1 : norm < 3 ? 2 : norm < 7 ? 5 : 10) * mag;
  // whole steps from the one at/below lo to the one at/above hi, so the
  // axis always covers the data (computed by index: no float drift)
  final a = (lo / step).floor(), b = (hi / step).ceil();
  return [for (var k = a; k <= b; k++) double.parse((k * step).toStringAsPrecision(12))];
}

String _fmt(double v) {
  final a = v.abs();
  if (a >= 1e6) return '${(v / 1e6).toStringAsFixed(a >= 1e7 ? 0 : 1)}M';
  if (a >= 1e4) return '${(v / 1e3).toStringAsFixed(0)}k';
  if (a == a.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(a < 10 ? 2 : 1);
}

const _palette = [
  Color(0xFF5B9BD5), Color(0xFFED7D31), Color(0xFF70AD47), Color(0xFFFFC000),
  Color(0xFF9E7CC1), Color(0xFF4BC0C0), Color(0xFFE05A6F), Color(0xFF8C8C8C),
];

/// The chart's laid-out label texts, kept across paints and rebuilds: a
/// repaint (a hover move, a server turn rebuilding the screen) draws the
/// axis labels without laying them out again. Keyed by text, colour and
/// size; [clear]ed when it grows past [_limit] (a re-pushed chart with new
/// categories) and with the view.
class ChartLabelCache {
  final Map<(String, Color?, double), TextPainter> _labels = {};
  final Map<String, Size> _measured = {};
  static const _limit = 1024;

  /// How many label layouts the cache made (tests read it).
  int layouts = 0;

  /// [s] laid out as an axis label (one line, at most 160 wide).
  TextPainter label(String s, Color? color, double size) {
    if (_labels.length >= _limit) _clearLabels();
    return _labels.putIfAbsent((s, color, size), () {
      layouts++;
      return TextPainter(
        text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: 160);
    });
  }

  /// The unconstrained size of category label [s] (the label-fit measure).
  Size measure(String s) {
    if (_measured.length >= _limit) _measured.clear();
    return _measured.putIfAbsent(s, () {
      layouts++;
      final tp = TextPainter(
        text: TextSpan(text: s, style: const TextStyle(fontSize: 11)),
        textDirection: TextDirection.ltr,
      )..layout();
      final size = tp.size;
      tp.dispose();
      return size;
    });
  }

  void _clearLabels() {
    for (final tp in _labels.values) {
      tp.dispose();
    }
    _labels.clear();
  }

  void clear() {
    _clearLabels();
    _measured.clear();
  }
}

class _SapChartViewState extends State<SapChartView> {
  int? _hover;
  final _labels = ChartLabelCache();

  /// How many label layouts the chart made (tests read it).
  int get labelLayouts => _labels.layouts;

  @override
  void dispose() {
    _labels.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kind = chartKindOf(widget.type);
    final n = widget.categories.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.title.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(widget.title.trim(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall),
          ),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 14,
          children: [
            for (final (i, s) in widget.series.indexed)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 12, height: 12, color: _palette[i % _palette.length]),
                const SizedBox(width: 6),
                Text(s.label, style: const TextStyle(fontSize: 12)),
              ]),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: LayoutBuilder(builder: (context, cons) {
            final painter = _ChartPainter(
              kind: kind,
              categories: widget.categories,
              series: widget.series,
              axis: scheme.onSurfaceVariant,
              grid: scheme.outlineVariant.withValues(alpha: 0.5),
              text: scheme.onSurface,
              labels: _labels,
            );
            // the read-out under the finger is its own layer of paint: a
            // hover move repaints it, not the axes and the data
            final readout = _HoverPainter(chart: painter, hover: _hover);
            int? indexAt(Offset p) {
              if (n == 0) return null;
              final plot = painter.plotRect(cons.biggest);
              final t = kind == ChartKind.bar
                  ? (p.dy - plot.top) / plot.height
                  : (p.dx - plot.left) / plot.width;
              return (t * n).floor().clamp(0, n - 1);
            }

            return GestureDetector(
              onPanStart: (d) => setState(() => _hover = indexAt(d.localPosition)),
              onPanUpdate: (d) => setState(() => _hover = indexAt(d.localPosition)),
              onPanEnd: (_) => setState(() => _hover = null),
              onTapDown: (d) => setState(() => _hover = indexAt(d.localPosition)),
              child: CustomPaint(
                size: cons.biggest,
                painter: painter,
                foregroundPainter: readout,
              ),
            );
          }),
        ),
      ],
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.kind,
    required this.categories,
    required this.series,
    required this.axis,
    required this.grid,
    required this.text,
    required this.labels,
  });

  final ChartKind kind;
  final List<String> categories;
  final List<ChartSeriesData> series;
  final Color axis, grid, text;
  final ChartLabelCache labels;

  static const _left = 56.0, _bottom = 28.0, _top = 8.0, _right = 12.0;
  double _width = double.infinity; // the canvas width, labels stay inside

  Rect plotRect(Size s) => kind == ChartKind.bar
      ? Rect.fromLTRB(96, _top, s.width - _right, s.height - _bottom)
      : Rect.fromLTRB(_left, _top, s.width - _right, s.height - _bottom);

  void _label(Canvas c, String s, Offset at,
      {TextAlign align = TextAlign.left, Color? color, double size = 11}) {
    final tp = labels.label(s, color ?? axis, size);
    final dx = switch (align) {
      TextAlign.right => at.dx - tp.width,
      TextAlign.center => at.dx - tp.width / 2,
      _ => at.dx,
    };
    tp.paint(c,
        Offset(dx.clamp(0.0, math.max(0.0, _width - tp.width)), at.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    _width = size.width;
    final n = categories.length;
    if (n == 0 || series.isEmpty) {
      _label(canvas, '(no chart data)', size.center(Offset.zero), align: TextAlign.center);
      return;
    }
    final plot = plotRect(size);
    var lo = double.infinity, hi = -double.infinity;
    for (final s in series) {
      for (final v in s.values) {
        if (v == null) continue;
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }
    if (lo == double.infinity) lo = hi = 0;
    // columns/bars/areas grow from zero; lines zoom to the data's range
    if (kind != ChartKind.line) lo = math.min(lo, 0);
    final ticks = niceTicks(lo, hi);
    final vLo = ticks.first, vHi = ticks.last == ticks.first ? ticks.first + 1 : ticks.last;

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    final horizontal = kind == ChartKind.bar;
    double vPos(double v) => horizontal
        ? plot.left + (v - vLo) / (vHi - vLo) * plot.width
        : plot.bottom - (v - vLo) / (vHi - vLo) * plot.height;
    double cPos(int i) => horizontal
        ? plot.top + (i + 0.5) / n * plot.height
        : plot.left + (i + 0.5) / n * plot.width;

    // value axis
    for (final t in ticks) {
      final p = vPos(t);
      if (horizontal) {
        canvas.drawLine(Offset(p, plot.top), Offset(p, plot.bottom), gridPaint);
        _label(canvas, _fmt(t), Offset(p, plot.bottom + 12), align: TextAlign.center);
      } else {
        canvas.drawLine(Offset(plot.left, p), Offset(plot.right, p), gridPaint);
        _label(canvas, _fmt(t), Offset(plot.left - 6, p), align: TextAlign.right);
      }
    }
    // category axis: as many labels as fit side by side (measured on the
    // longest label, plus a gap)
    final axisLen = horizontal ? plot.height : plot.width;
    var longest = 0.0;
    for (final c in categories.take(200)) {
      final tp = labels.measure(categoryLabel(c));
      longest = math.max(longest, horizontal ? tp.height : tp.width);
    }
    final slot = longest + (horizontal ? 6 : 16);
    final every = math.max(1, (slot / (axisLen / n)).ceil());
    for (var i = 0; i < n; i += every) {
      final p = cPos(i);
      final s = categoryLabel(categories[i]);
      if (horizontal) {
        _label(canvas, s, Offset(plot.left - 6, p), align: TextAlign.right);
      } else {
        _label(canvas, s, Offset(p, plot.bottom + 12), align: TextAlign.center);
      }
    }
    canvas.drawRect(plot, Paint()
      ..color = axis
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8);

    // the data
    canvas.save();
    canvas.clipRect(plot.inflate(1));
    final band = (horizontal ? plot.height : plot.width) / n;
    for (final (si, s) in series.indexed) {
      final color = _palette[si % _palette.length];
      if (kind == ChartKind.column || kind == ChartKind.bar) {
        final w = math.max(band * 0.8 / series.length, 0.6);
        final paint = Paint()..color = color;
        final zero = vPos(math.max(vLo, 0));
        for (var i = 0; i < n && i < s.values.length; i++) {
          final v = s.values[i];
          if (v == null) continue;
          final c0 = cPos(i) - band * 0.4 + si * w;
          final r = horizontal
              ? Rect.fromLTRB(math.min(zero, vPos(v)), c0, math.max(zero, vPos(v)), c0 + w)
              : Rect.fromLTRB(c0, math.min(zero, vPos(v)), c0 + w, math.max(zero, vPos(v)));
          canvas.drawRect(r, paint);
        }
        continue;
      }
      final path = Path();
      var open = false;
      final pts = <Offset>[];
      for (var i = 0; i < n && i < s.values.length; i++) {
        final v = s.values[i];
        if (v == null) {
          open = false;
          continue;
        }
        final o = Offset(cPos(i), vPos(v));
        pts.add(o);
        open ? path.lineTo(o.dx, o.dy) : path.moveTo(o.dx, o.dy);
        open = true;
      }
      if (kind == ChartKind.area && pts.length > 1) {
        final fill = Path.from(path)
          ..lineTo(pts.last.dx, vPos(math.max(vLo, 0)))
          ..lineTo(pts.first.dx, vPos(math.max(vLo, 0)))
          ..close();
        canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.25));
      }
      canvas.drawPath(path, Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round);
      if (pts.length == 1) canvas.drawCircle(pts.first, 3, Paint()..color = color);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.series != series ||
      old.categories != categories ||
      old.kind != kind ||
      old.axis != axis;
}

/// The read-out under the finger over a [_ChartPainter]'s chart: the
/// cross line and the values box, painted after the chart (the foreground
/// of the same CustomPaint) so it repaints alone as the finger moves.
class _HoverPainter extends CustomPainter {
  _HoverPainter({required this.chart, required this.hover});

  final _ChartPainter chart;
  final int? hover;

  @override
  void paint(Canvas canvas, Size size) {
    final categories = chart.categories, series = chart.series;
    final n = categories.length;
    if (n == 0 || series.isEmpty) return;
    final plot = chart.plotRect(size);
    final horizontal = chart.kind == ChartKind.bar;
    final text = chart.text, grid = chart.grid;
    double cPos(int i) => horizontal
        ? plot.top + (i + 0.5) / n * plot.height
        : plot.left + (i + 0.5) / n * plot.width;
    final h = hover;
    if (h != null && h < n) {
      final p = cPos(h);
      final cross = Paint()
        ..color = text.withValues(alpha: 0.6)
        ..strokeWidth = 1;
      horizontal
          ? canvas.drawLine(Offset(plot.left, p), Offset(plot.right, p), cross)
          : canvas.drawLine(Offset(p, plot.top), Offset(p, plot.bottom), cross);
      final lines = [
        categoryLabel(categories[h]),
        for (final s in series)
          '${s.label}: ${h < s.values.length && s.values[h] != null ? _fmt(s.values[h]!) : '—'}',
      ];
      final tp = TextPainter(
        text: TextSpan(
            text: lines.join('\n'),
            style: TextStyle(color: text, fontSize: 12, height: 1.3)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 260);
      var x = (horizontal ? plot.left + 8 : p + 10);
      if (x + tp.width + 12 > plot.right) x = p - tp.width - 22;
      final y = horizontal ? p + 10 : plot.top + 8;
      final box = Rect.fromLTWH(x, y, tp.width + 12, tp.height + 8);
      canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(6)),
          Paint()..color = grid.withValues(alpha: 0.95));
      tp.paint(canvas, Offset(x + 6, y + 4));
      tp.dispose();
    }
  }

  @override
  bool shouldRepaint(_HoverPainter old) =>
      old.hover != hover || old.chart.shouldRepaint(chart);
}
