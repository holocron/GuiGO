import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart' show SapChartModel;
import 'package:flutter/material.dart';

import 'sap_chart_view.dart';
import 'sap_gfw_chart_view.dart';

/// The GFW chart palette (CL_CU_DISPLAY_CONTEXT *_CLR_PLT_ID, 1 – 64;
/// CL_CU=>GET_CLR_PLT_ID lays them out as the chart palette's eight lines
/// of eight). The RGB values live in the front end's chart control, not in
/// the ABAP: these are read from what the ABAP's own comments name
/// (GFW_PROG_MTA "5 green" / "7 red" / "18 grau" / "49 hellgelb" /
/// "50 ocker", GFW_PROG_TIME_AXIS "3 blue", GFW_PROG_SPEEDOMETER "4
/// yellow") and what the real Windows GUI draws for the ids the recorded
/// demos send (a recorded session: PRES1's 4 yellow and 11 navy
/// columns, its 53 orange gradient end and 9 light-blue diagram, HIER3's
/// default 2 white with 1 black outlines); the first line's order (2, 1, 7,
/// 4, 5, 8, 3, 6: white, black, red, yellow, green, cyan, blue, magenta)
/// and its darker second line (11 navy, 12 olive, 13 dark green, 14
/// purple, 15 maroon, 16 teal) complete the basic sixteen. An id outside
/// this map takes the chart's automatic colour.
const Map<int, Color> gfwPalette = {
  1: Color(0xFF000000),
  2: Color(0xFFFFFFFF),
  3: Color(0xFF2F5FE0),
  4: Color(0xFFFFE000),
  5: Color(0xFF2EB82E),
  6: Color(0xFFE040E0),
  7: Color(0xFFE02020),
  8: Color(0xFF20D0E0),
  9: Color(0xFFA6CAF0),
  10: Color(0xFFC0C0C0),
  11: Color(0xFF1A237E),
  12: Color(0xFF808000),
  13: Color(0xFF007F00),
  14: Color(0xFF800080),
  15: Color(0xFF800000),
  16: Color(0xFF008080),
  17: Color(0xFFE0E0E0),
  18: Color(0xFF9E9E9E),
  49: Color(0xFFFFF4B0),
  50: Color(0xFFC8A04B),
  53: Color(0xFFFF9020),
};

/// The chart view of a [SapChartModel] (the session's charts): the GFW
/// business graphic with its customizing ([GfwChartView]), the Chart
/// Engine's charts ([SapChartView]).
Widget sapChartViewOf(SapChartModel c, {Key? key}) => c.gfw != null
    ? GfwChartView(key: key, model: c)
    : SapChartView(
        key: key,
        type: c.chartType,
        title: c.title,
        categories: c.categories,
        xTime: c.xTime,
        yTime: c.yTime,
        series: [
          for (final s in c.series)
            ChartSeriesData(
              s.label,
              s.values,
              xs: s.xs,
              color: s.color == null ? null : gfwPalette[s.color],
            ),
        ],
      );

const List<Color> _auto = [
  Color(0xFF5B9BD5), Color(0xFFED7D31), Color(0xFF70AD47), Color(0xFFFFC000),
  Color(0xFF9E7CC1), Color(0xFF4BC0C0), Color(0xFFE05A6F), Color(0xFF8C8C8C),
];

Color _colorOf(ChartSeriesData s, int i) => s.color ?? _auto[i % _auto.length];

/// A time value (days since 1970-01-01) as a date label.
String dayLabel(double days) {
  final t = DateTime.fromMillisecondsSinceEpoch(
    (days * Duration.millisecondsPerDay).round(),
    isUtc: true,
  );
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

String _num(double v) {
  final a = v.abs();
  if (a >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
  if (a >= 1e4) return '${(v / 1e3).toStringAsFixed(0)}k';
  if (a == a.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(a < 10 ? 2 : 1);
}

void _text(Canvas c, String s, Offset at, Color color,
    {TextAlign align = TextAlign.left, double size = 11, double? maxX}) {
  final tp = TextPainter(
    text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout(maxWidth: 200);
  var dx = switch (align) {
    TextAlign.right => at.dx - tp.width,
    TextAlign.center => at.dx - tp.width / 2,
    _ => at.dx,
  };
  if (maxX != null) dx = dx.clamp(0.0, math.max(0.0, maxX - tp.width));
  tp.paint(c, Offset(dx, at.dy - tp.height / 2));
  tp.dispose();
}

/// A pie: the first series' values over the categories, one slice each.
class PieChartPainter extends CustomPainter {
  PieChartPainter({
    required this.categories,
    required this.series,
    required this.text,
  });

  final List<String> categories;
  final List<ChartSeriesData> series;
  final Color text;

  static Color sliceColor(int i) => _auto[i % _auto.length];

  @override
  void paint(Canvas canvas, Size size) {
    final values = series.isEmpty ? const <double?>[] : series.first.values;
    final total = values.fold<double>(
      0,
      (a, v) => a + (v != null && v > 0 ? v : 0),
    );
    if (total <= 0) {
      _text(canvas, '(no chart data)', size.center(Offset.zero), text,
          align: TextAlign.center);
      return;
    }
    final r = math.max(4.0, math.min(size.width, size.height) / 2 - 24);
    final c = size.center(Offset.zero);
    var a = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null || v <= 0) continue;
      final sweep = v / total * 2 * math.pi;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), a, sweep, true,
          Paint()..color = sliceColor(i));
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), a, sweep, true,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.7)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
      final mid = a + sweep / 2;
      final at = c + Offset(math.cos(mid), math.sin(mid)) * (r * 0.65);
      if (sweep > 0.25) {
        _text(canvas, '${(v / total * 100).round()} %', at, Colors.black87,
            align: TextAlign.center);
      }
      a += sweep;
    }
  }

  @override
  bool shouldRepaint(PieChartPainter old) =>
      old.series != series || old.categories != categories || old.text != text;
}

/// An xy chart: every series a run of (x, y) points joined in data order
/// with markers — a GFW scatter / time axis, and the milestone trend
/// analysis ([milestone]: dates on both axes over one shared range, the
/// diagonal "reached" line, the report-date axis at the top).
class XyChartPainter extends CustomPainter {
  XyChartPainter({
    required this.series,
    required this.xTime,
    required this.yTime,
    required this.milestone,
    required this.axis,
    required this.grid,
    this.lines = true,
  });

  final List<ChartSeriesData> series;
  final bool xTime, yTime, milestone, lines;
  final Color axis, grid;

  static const _left = 76.0, _right = 14.0, _top = 10.0, _bottom = 28.0;

  Rect plotRect(Size s) => milestone
      ? Rect.fromLTRB(_left, _bottom, s.width - _right, s.height - _top)
      : Rect.fromLTRB(_left, _top, s.width - _right, s.height - _bottom);

  @override
  void paint(Canvas canvas, Size size) {
    var xLo = double.infinity, xHi = -double.infinity;
    var yLo = double.infinity, yHi = -double.infinity;
    for (final s in series) {
      for (var i = 0; i < s.values.length && i < s.xs.length; i++) {
        final x = s.xs[i], y = s.values[i];
        if (x == null || y == null) continue;
        xLo = math.min(xLo, x);
        xHi = math.max(xHi, x);
        yLo = math.min(yLo, y);
        yHi = math.max(yHi, y);
      }
    }
    if (xLo == double.infinity) {
      _text(canvas, '(no chart data)', size.center(Offset.zero), axis,
          align: TextAlign.center);
      return;
    }
    if (milestone) {
      // one range on both axes: the triangle over the diagonal
      xLo = yLo = math.min(xLo, yLo);
      xHi = yHi = math.max(xHi, yHi);
    }
    final xt = niceTicks(xLo, xHi), yt = niceTicks(yLo, yHi);
    final x0 = xt.first, x1 = xt.last == xt.first ? xt.first + 1 : xt.last;
    final y0 = yt.first, y1 = yt.last == yt.first ? yt.first + 1 : yt.last;
    final plot = plotRect(size);
    double px(double x) => plot.left + (x - x0) / (x1 - x0) * plot.width;
    // the milestone trend's y (the forecast date) grows downward from the
    // report-date axis at the top
    double py(double y) => milestone
        ? plot.top + (y - y0) / (y1 - y0) * plot.height
        : plot.bottom - (y - y0) / (y1 - y0) * plot.height;
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    String xl(double v) => xTime ? dayLabel(v) : _num(v);
    String yl(double v) => yTime ? dayLabel(v) : _num(v);
    // as many x labels as fit side by side (measured on the widest, + a gap)
    var widest = 0.0;
    for (final v in xt) {
      final tp = TextPainter(
        text: TextSpan(text: xl(v), style: const TextStyle(fontSize: 11)),
        textDirection: TextDirection.ltr,
      )..layout();
      widest = math.max(widest, tp.width);
      tp.dispose();
    }
    final slot = plot.width / math.max(1, xt.length - 1);
    final every = math.max(1, ((widest + 12) / slot).ceil());
    for (var k = 0; k < xt.length; k++) {
      final p = px(xt[k]);
      canvas.drawLine(Offset(p, plot.top), Offset(p, plot.bottom), gridPaint);
      if (k % every == 0) {
        _text(canvas, xl(xt[k]),
            Offset(p, milestone ? plot.top - 12 : plot.bottom + 12), axis,
            align: TextAlign.center, maxX: size.width);
      }
    }
    for (final t in yt) {
      final p = py(t);
      canvas.drawLine(Offset(plot.left, p), Offset(plot.right, p), gridPaint);
      _text(canvas, yl(t), Offset(plot.left - 6, p), axis,
          align: TextAlign.right);
    }
    canvas.drawRect(plot, Paint()
      ..color = axis
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8);
    canvas.save();
    canvas.clipRect(plot.inflate(6));
    if (milestone) {
      canvas.drawLine(Offset(px(x0), py(x0)), Offset(px(x1), py(x1)), Paint()
        ..color = axis
        ..strokeWidth = 1.2);
    }
    for (final (si, s) in series.indexed) {
      final color = _colorOf(s, si);
      final pts = <Offset>[
        for (var i = 0; i < s.values.length && i < s.xs.length; i++)
          if (s.xs[i] != null && s.values[i] != null)
            Offset(px(s.xs[i]!), py(s.values[i]!)),
      ];
      if (lines && pts.length > 1) {
        final path = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (final p in pts.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path, Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round);
      }
      final marker = Paint()..color = color;
      for (final p in pts) {
        if (milestone) {
          // the milestone triangle
          canvas.drawPath(
            Path()
              ..moveTo(p.dx, p.dy - 5)
              ..lineTo(p.dx + 5, p.dy + 4)
              ..lineTo(p.dx - 5, p.dy + 4)
              ..close(),
            marker,
          );
        } else {
          canvas.drawCircle(p, 3.5, marker);
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(XyChartPainter old) =>
      old.series != series ||
      old.xTime != xTime ||
      old.yTime != yTime ||
      old.milestone != milestone ||
      old.axis != axis;
}
