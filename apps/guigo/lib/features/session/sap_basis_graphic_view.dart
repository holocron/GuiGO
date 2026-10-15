import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart'
    show
        BusgChartKind,
        SapBasisGraphic,
        SapBusinessGraphic,
        SapStatGraphic,
        StatAxis,
        StatCurve,
        StatCurveStyle,
        StatMarker;
import 'package:flutter/material.dart';

import 'sap_chart_view.dart';

/// The classic Basis-Graphik colour index of a statistics curve (STAT_GRAPH
/// `SET COLOR n`) on its black plot. Grounded by the real SAP GUI for
/// Windows drawing GRSTAT_1 (a recorded session + its
/// screenshot): 7 cyan (the cosine), 4 green (the sine), 3 yellow (the
/// markers). The other indices are not on any recording: an ordinary
/// sixteen-colour set around them.
const Map<int, Color> statPalette = {
  0: Color(0xFFFFFFFF),
  1: Color(0xFFFF3030),
  2: Color(0xFF4060FF),
  3: Color(0xFFFFFF00),
  4: Color(0xFF00FF00),
  5: Color(0xFFFF00FF),
  6: Color(0xFFFFFFFF),
  7: Color(0xFF00FFFF),
  8: Color(0xFFA0A0A0),
  9: Color(0xFFA00000),
  10: Color(0xFF0000A0),
  11: Color(0xFFA0A000),
  12: Color(0xFF00A000),
  13: Color(0xFFA000A0),
  14: Color(0xFFD0D0D0),
  15: Color(0xFF00A0A0),
};

const List<Color> _autoCurve = [
  Color(0xFF00FFFF), Color(0xFF00FF00), Color(0xFFFFFF00),
  Color(0xFFFF00FF), Color(0xFFFF3030), Color(0xFFFFFFFF),
];

/// A statistics curve's colour: its COLOR index, else by position.
Color statCurveColor(StatCurve c, int i) =>
    statPalette[c.color] ?? _autoCurve[i % _autoCurve.length];

/// The classic BUSINESS (GRAPH_2D / GRAPH_3D / GRAPH_MATRIX_*) or
/// STATISTICS (STAT_GRAPH) graphic of an inline GRAPH stream as the screen
/// body: what the real SAP GUI for Windows opens in a graphics window of
/// its own. "Légende" and "Options globales" are local: the real GUI's
/// legend toggle leaves no wire trace (a recorded session
/// — the only client message is the close, `D E0`).
class SapBasisGraphicView extends StatefulWidget {
  const SapBasisGraphicView({super.key, required this.graphic});

  final SapBasisGraphic graphic;

  @override
  State<SapBasisGraphicView> createState() => _SapBasisGraphicViewState();
}

class _SapBasisGraphicViewState extends State<SapBasisGraphicView> {
  bool _legend = false;

  void _showOptions() {
    final o = widget.graphic.options;
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Options globales'),
        content: SizedBox(
          width: 360,
          child: o.isEmpty
              ? const Text('(aucune option)')
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final e in o.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text('${e.key} = ${e.value}',
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 13)),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.graphic;
    return Container(
      color: const Color(0xFF8C8C8C),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              OutlinedButton(
                key: const ValueKey('basis-graphic-options'),
                onPressed: _showOptions,
                child: const Text('Options globales'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                key: const ValueKey('basis-graphic-legend'),
                onPressed: () => setState(() => _legend = !_legend),
                child: const Text('Légende'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: switch (g) {
              SapStatGraphic() => _stat(g),
              SapBusinessGraphic() => _business(g),
            },
          ),
        ],
      ),
    );
  }

  Widget _stat(SapStatGraphic g) {
    const mono = TextStyle(
        fontFamily: 'monospace', color: Colors.white, fontSize: 15);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (g.title.isNotEmpty)
          Text(g.title, textAlign: TextAlign.center, style: mono),
        if (g.subtitle.isNotEmpty)
          Text(g.subtitle,
              textAlign: TextAlign.center,
              style: mono.copyWith(fontSize: 13)),
        const SizedBox(height: 6),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: CustomPaint(
                  key: const ValueKey('stat-graphic-plot'),
                  painter: StatGraphicPainter(g),
                  size: Size.infinite,
                ),
              ),
              if (_legend) ...[
                const SizedBox(width: 8),
                _StatLegend(g),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _business(SapBusinessGraphic g) {
    final type = switch (g.kind) {
      BusgChartKind.pie => 'Pie',
      BusgChartKind.columns => 'Columns',
      BusgChartKind.bars => 'Bars',
      BusgChartKind.lines => 'Lines',
    };
    final title = g.valueTitle.isEmpty || g.kind == BusgChartKind.pie
        ? g.title
        : '${g.title} (${g.valueTitle})';
    final chart = Container(
      color: Colors.white,
      padding: const EdgeInsets.all(8),
      child: SapChartView(
        key: ValueKey('busg-${g.title}-${g.categories.length}'),
        type: type,
        title: title,
        categories: g.categories,
        series: [
          for (final (i, s) in g.values.indexed)
            ChartSeriesData(
                i < g.seriesLabels.length ? g.seriesLabels[i] : '${i + 1}', s),
        ],
      ),
    );
    if (!_legend) return chart;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: chart),
        const SizedBox(width: 8),
        _BusinessLegend(g),
      ],
    );
  }
}

class _StatLegend extends StatelessWidget {
  const _StatLegend(this.g);
  final SapStatGraphic g;

  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('basis-graphic-legend-panel'),
        width: 200,
        color: Colors.black,
        padding: const EdgeInsets.all(8),
        child: ListView(
          children: [
            for (final (i, c) in g.curves.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  SizedBox(
                    width: 22,
                    height: 12,
                    child: CustomPaint(
                        painter: _LegendMark(c, statCurveColor(c, i))),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      [c.legend, if (c.description.isNotEmpty) c.description]
                          .where((s) => s.isNotEmpty)
                          .join('  '),
                      style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                          fontSize: 12),
                    ),
                  ),
                ]),
              ),
          ],
        ),
      );
}

class _BusinessLegend extends StatelessWidget {
  const _BusinessLegend(this.g);
  final SapBusinessGraphic g;

  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('basis-graphic-legend-panel'),
        width: 200,
        color: Colors.white,
        padding: const EdgeInsets.all(8),
        child: ListView(
          children: [
            for (final (r, label) in g.categories.indexed)
              Text(
                '$label: ${[
                  for (final s in g.values)
                    if (r < s.length && s[r] != null) _plain(s[r]!),
                ].join(' / ')}'
                '${g.valueTitle.isEmpty ? '' : ' ${g.valueTitle}'}',
                style: const TextStyle(fontSize: 12),
              ),
          ],
        ),
      );
}

String _plain(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

class _LegendMark extends CustomPainter {
  _LegendMark(this.c, this.color);
  final StatCurve c;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.center(Offset.zero);
    if (c.style == StatCurveStyle.line) {
      canvas.drawLine(Offset(0, mid.dy), Offset(size.width, mid.dy),
          Paint()
            ..color = color
            ..strokeWidth = c.thickness.toDouble());
    }
    if (c.style == StatCurveStyle.markers || c.marker != StatMarker.none) {
      drawStatMarker(canvas, mid, c.marker, color);
    }
  }

  @override
  bool shouldRepaint(_LegendMark old) => old.c != c || old.color != color;
}

/// One marker of a statistics curve at [at].
void drawStatMarker(Canvas canvas, Offset at, StatMarker m, Color color,
    {double r = 3.5}) {
  final fill = Paint()..color = color;
  final stroke = Paint()
    ..color = color
    ..strokeWidth = 1.5
    ..style = PaintingStyle.stroke;
  switch (m) {
    case StatMarker.square || StatMarker.none:
      canvas.drawRect(Rect.fromCircle(center: at, radius: r), fill);
    case StatMarker.circle:
      canvas.drawCircle(at, r, fill);
    case StatMarker.plus:
      canvas
        ..drawLine(at.translate(-r, 0), at.translate(r, 0), stroke)
        ..drawLine(at.translate(0, -r), at.translate(0, r), stroke);
    case StatMarker.cross:
      canvas
        ..drawLine(at.translate(-r, -r), at.translate(r, r), stroke)
        ..drawLine(at.translate(-r, r), at.translate(r, -r), stroke);
    case StatMarker.triangle:
      canvas.drawPath(
          Path()
            ..moveTo(at.dx, at.dy - r)
            ..lineTo(at.dx + r, at.dy + r)
            ..lineTo(at.dx - r, at.dy + r)
            ..close(),
          fill);
    case StatMarker.diamond:
      canvas.drawPath(
          Path()
            ..moveTo(at.dx, at.dy - r)
            ..lineTo(at.dx + r, at.dy)
            ..lineTo(at.dx, at.dy + r)
            ..lineTo(at.dx - r, at.dy)
            ..close(),
          fill);
  }
}

/// One laid-out axis: its value range and tick values.
class StatScale {
  StatScale(this.lo, this.hi, this.ticks, this.log, this.decimals);
  final double lo, hi;
  final List<double> ticks;
  final bool log;
  final int decimals;

  double _t(double v) => log ? math.log(math.max(v, 1e-300)) / math.ln10 : v;

  /// [v]'s position in 0 … 1 over the range.
  double frac(double v) {
    final a = _t(lo), b = _t(hi);
    return b == a ? 0.5 : (_t(v) - a) / (b - a);
  }

  String label(double v) => v.toStringAsFixed(decimals);

  /// The axis of [axis] over the data values [data]: the manual range
  /// (SCALE MAN) and its tick count (XTCKS 13 over 0 … 360 = every 30), else
  /// a step (STEPX), else 1-2-5 ticks over the data.
  static StatScale of(StatAxis axis, Iterable<double> data) {
    var lo = axis.min, hi = axis.max;
    final log = axis.logarithmic;
    if (lo == null || hi == null) {
      var a = double.infinity, b = double.negativeInfinity;
      for (final v in data) {
        if (log && v <= 0) continue;
        a = math.min(a, v);
        b = math.max(b, v);
      }
      if (!a.isFinite || !b.isFinite) {
        a = log ? 1 : 0;
        b = log ? 10 : 1;
      }
      if (log) {
        lo ??= math.pow(10, (math.log(a) / math.ln10).floor()).toDouble();
        hi ??= math.pow(10, (math.log(b) / math.ln10).ceil()).toDouble();
      } else {
        final t = niceTicks(a, b);
        lo ??= t.first;
        hi ??= t.last;
      }
    }
    if (hi <= lo) hi = lo + 1;
    if (log && lo <= 0) lo = hi / 1000;
    final ticks = <double>[];
    if (log) {
      for (var e = (math.log(lo) / math.ln10).floor();
          e <= (math.log(hi) / math.ln10).ceil() && ticks.length < 40;
          e++) {
        final v = math.pow(10, e).toDouble();
        if (v >= lo * 0.999 && v <= hi * 1.001) ticks.add(v);
      }
    } else if ((axis.ticks ?? 0) >= 2 && axis.ticks! <= 200) {
      final n = axis.ticks!;
      for (var i = 0; i < n; i++) {
        ticks.add(lo + (hi - lo) * i / (n - 1));
      }
    } else if (axis.step != null && (hi - lo) / axis.step! <= 200) {
      for (var v = lo; v <= hi + axis.step! * 1e-9; v += axis.step!) {
        ticks.add(v);
      }
    } else {
      ticks.addAll(niceTicks(lo, hi).where((v) => v >= lo! && v <= hi!));
    }
    return StatScale(lo, hi, ticks, log, axis.decimals ?? 1);
  }
}

/// The statistics graphic as the SAP GUI draws it (GRSTAT_1): a black plot
/// area with a grey grid, red axis lines, the magenta zero line (ZL_FLAG
/// 1), every curve a polyline or its markers (C_ART 1), the tick labels in
/// white monospace and the axis title (TAXIS) at the bottom right.
class StatGraphicPainter extends CustomPainter {
  StatGraphicPainter(this.g);
  final SapStatGraphic g;

  static const _labelStyle = TextStyle(
      color: Colors.white, fontFamily: 'monospace', fontSize: 11);

  /// The plot rectangle inside [size].
  Rect plotRect(Size size, {double left = 52}) => Rect.fromLTRB(
      math.min(left, size.width / 3),
      10,
      math.max(math.min(left, size.width / 3) + 1, size.width - 24),
      math.max(11, size.height - 40));

  /// Draws [s] at [at] unless it would start left of [after] (a crowded
  /// axis skips the label); returns its right edge, or [after] if skipped.
  double _text(Canvas c, String s, Offset at,
      {TextAlign align = TextAlign.center,
      double after = double.negativeInfinity}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: _labelStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 260);
    final dx = switch (align) {
      TextAlign.right => at.dx - tp.width,
      TextAlign.center => at.dx - tp.width / 2,
      _ => at.dx,
    };
    final right = dx + tp.width;
    if (dx >= after) tp.paint(c, Offset(dx, at.dy - tp.height / 2));
    tp.dispose();
    return dx >= after ? right + 4 : after;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 40 || size.height < 40) return;
    final xs = StatScale.of(g.x, g.curves.expand((c) => c.points.map((p) => p.$1)));
    final ys = StatScale.of(g.y, g.curves.expand((c) => c.points.map((p) => p.$2)));
    final plot = plotRect(size);
    canvas.drawRect(plot, Paint()..color = Colors.black);
    Offset at(double x, double y) => Offset(
        plot.left + xs.frac(x) * plot.width,
        plot.bottom - ys.frac(y) * plot.height);
    final grid = Paint()
      ..color = const Color(0xFF6E6E6E)
      ..strokeWidth = 1;
    var after = double.negativeInfinity;
    for (final t in xs.ticks) {
      final px = plot.left + xs.frac(t) * plot.width;
      canvas.drawLine(Offset(px, plot.top), Offset(px, plot.bottom), grid);
      after = _text(canvas, xs.label(t), Offset(px, plot.bottom + 10),
          after: after);
    }
    for (final t in ys.ticks) {
      final py = plot.bottom - ys.frac(t) * plot.height;
      canvas.drawLine(Offset(plot.left, py), Offset(plot.right, py), grid);
      _text(canvas, ys.label(t), Offset(plot.left - 4, py),
          align: TextAlign.right);
    }
    final axis = Paint()
      ..color = const Color(0xFFFF2020)
      ..strokeWidth = 1.5;
    canvas
      ..drawLine(plot.bottomLeft, plot.bottomRight, axis)
      ..drawLine(plot.bottomLeft, plot.topLeft, axis);
    canvas.save();
    canvas.clipRect(plot);
    if (g.zeroLine && !ys.log && ys.lo < 0 && ys.hi > 0) {
      final py = at(xs.lo, 0).dy;
      canvas.drawLine(Offset(plot.left, py), Offset(plot.right, py),
          Paint()
            ..color = const Color(0xFFFF00FF)
            ..strokeWidth = 1.5);
    }
    for (final (i, c) in g.curves.indexed) {
      final color = statCurveColor(c, i);
      final pts = [
        for (final (x, y) in c.points)
          if (!(xs.log && x <= 0) && !(ys.log && y <= 0)) at(x, y),
      ];
      if (c.style == StatCurveStyle.line && pts.length > 1) {
        final path = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (final p in pts.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(
            path,
            Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeWidth = c.thickness.toDouble().clamp(1, 8)
              ..strokeJoin = StrokeJoin.round);
      }
      if (c.style == StatCurveStyle.markers || c.marker != StatMarker.none) {
        for (final p in pts) {
          drawStatMarker(canvas, p, c.marker, color);
        }
      }
    }
    canvas.restore();
    if (g.axisTitle.isNotEmpty) {
      _text(canvas, g.axisTitle, Offset(plot.right, plot.bottom + 28),
          align: TextAlign.right);
    }
  }

  @override
  bool shouldRepaint(StatGraphicPainter old) => old.g != g;
}
