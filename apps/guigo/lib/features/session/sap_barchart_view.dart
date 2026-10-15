import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;

import 'sap_graph_view.dart' show jnetColor;

/// A BARC colour name (THLT / FVALS: `BLACK`, `GRAY_2`, `YELLOW_3`,
/// `BLUE_7`, …) as a colour. The numbered greys darken with the number (the
/// demo's diagram is GRAY_2 and its non-working shading GRAY_4…6 — the real
/// GUI's grey grid with darker non-working bars); the numbered colours
/// lighten. Unrecorded as pixels: the OCX's palette is not on the wire.
Color? barChartColor(String? name) {
  if (name == null) return null;
  final m = RegExp(r'^([A-Z]+)(?:_(\d+))?$').firstMatch(name.trim().toUpperCase());
  if (m == null) return jnetColor(name);
  final n = int.tryParse(m.group(2) ?? '') ?? 0;
  switch (m.group(1)) {
    case 'GRAY' || 'GREY':
      final v = (0xE6 - n * 0x13).clamp(0x40, 0xF0);
      return Color.fromARGB(255, v, v, v);
    case 'YELLOW':
      return const [
        Color(0xFFFFF59A), Color(0xFFFFF0A8), Color(0xFFF8E27A),
        Color(0xFFEDD35E), Color(0xFFE6C84A),
      ][n.clamp(0, 4)];
    case 'BLACK':
      return const Color(0xFF000000);
    case 'WHITE':
      return const Color(0xFFFFFFFF);
    case 'RED':
      return Color.lerp(const Color(0xFFE01010), Colors.white, n * 0.09);
    case 'GREEN':
      return Color.lerp(const Color(0xFF10A030), Colors.white, n * 0.09);
    case 'BLUE':
      return Color.lerp(const Color(0xFF1838D8), Colors.white, n * 0.09);
    case 'CYAN':
      return Color.lerp(const Color(0xFF10B8D8), Colors.white, n * 0.09);
  }
  return jnetColor(name);
}

/// The SAPbarc.OCX bar chart (GRAL BARCOCX1, `SAPGUI.BarchartGraphics.1`)
/// as the real SAP GUI for Windows draws it: the charts stacked by their
/// /$CHARTS height share, each with its table part on the left (columns
/// /$CLMWD, the yellow box rows, the header row) and its diagram part on
/// the right — the calendar header (one ribbon per unit, months over
/// days), the time area (the diagram colour, a calendar grid's shaded
/// non-working time, a line grid), the bars / lines / milestones of each
/// row's nodes in their layer's colours.
///
/// Lengths are the stream's hundredths of a millimetre at 96 dpi
/// ([pxPerMm]); the time axis' [SapBarChartModel.xOf]. Scrolling (drag,
/// wheel, each chart's scroll bar) and pinch zoom are local: the real GUI
/// sends nothing for them (a recorded session §5). The
/// toolbar's Agrandir / Réduire reach the control from the server
/// (LoadCUACode OZIN / OZOU) and arrive as [SapBarChartModel.zoom] steps.
class SapBarChartView extends StatefulWidget {
  const SapBarChartView({super.key, required this.chart, this.onSelect});

  final SapBarChartModel chart;

  /// A tap marked [node] (null: a tap on no bar cleared the marks). The
  /// view marks it at once; the session keeps the mark for the next
  /// read-back (Supprimer's `CADEL`) — the click itself sends nothing.
  final void Function(BarChartNode? node)? onSelect;

  /// Logical pixels per millimetre (the Windows GUI's 96 dpi).
  static const double pxPerMm = 96 / 25.4;

  /// The time-axis factor of one server zoom step (OZIN; unrecorded — the
  /// OCX's own factor is not on the wire).
  static const double zoomStep = 1.5;

  @override
  State<SapBarChartView> createState() => _SapBarChartViewState();
}

class _SapBarChartViewState extends State<SapBarChartView> {
  /// the pinch factor (local)
  double _pinch = 1;
  double _pinchStart = 1;

  /// per chart id: the horizontal (time) and vertical scroll offsets
  final Map<String, double> _dx = {};
  final Map<String, double> _dy = {};

  /// the marked nodes (chart, node id): the model's, then the taps
  late Set<(String, String)> _selected = _marksOf(widget.chart);

  /// per chart id: the last painter (its hit boxes)
  final Map<String, BarChartPainter> _painters = {};

  static Set<(String, String)> _marksOf(SapBarChartModel m) => {
        for (final c in m.charts)
          for (final n in c.nodes)
            if (n.selected) (c.id, n.id),
      };

  @override
  void didUpdateWidget(SapBarChartView old) {
    super.didUpdateWidget(old);
    if (!identical(old.chart, widget.chart)) _selected = _marksOf(widget.chart);
  }

  void _tap(BarChartChart c, Offset local) {
    final hit = _painters[c.id]?.nodeAt(local);
    setState(() {
      _selected = hit == null ? {} : {(c.id, hit.id)};
    });
    widget.onSelect?.call(hit);
  }

  double get _hScale =>
      _pinch * math.pow(SapBarChartView.zoomStep, widget.chart.zoom);

  @override
  Widget build(BuildContext context) {
    final m = widget.chart;
    final total = m.charts.fold<double>(0, (s, c) => s + math.max(c.height, 1));
    return LayoutBuilder(builder: (context, box) {
      final panes = <Widget>[];
      for (final (i, c) in m.charts.indexed) {
        if (i > 0) {
          panes.add(const Divider(height: 3, thickness: 3, color: Color(0xFF8A8A8A)));
        }
        panes.add(Expanded(
          flex: math.max(1, (math.max(c.height, 1) / total * 1000).round()),
          child: _pane(c),
        ));
      }
      if (m.status.isNotEmpty) {
        panes.add(Container(
          key: const ValueKey('barchart-status'),
          color: const Color(0xFFEFEFEF),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          alignment: Alignment.centerLeft,
          child: Text(m.status,
              style: const TextStyle(fontSize: 11, color: Colors.black87)),
        ));
      }
      return ColoredBox(
        color: const Color(0xFFDADADA),
        child: Column(children: panes),
      );
    });
  }

  Widget _pane(BarChartChart c) {
    final m = widget.chart;
    final geo = BarChartGeometry(m, c, hScale: _hScale);
    return LayoutBuilder(builder: (context, box) {
      const bar = 12.0;
      final viewW = math.max(0.0, box.maxWidth - geo.tableWidth);
      final viewH = math.max(0.0, box.maxHeight - bar - geo.headerHeight);
      final maxDx = math.max(0.0, geo.axisWidth - viewW);
      final maxDy = math.max(0.0, geo.rowsHeight - viewH);
      final dx = (_dx[c.id] ?? 0).clamp(0.0, maxDx);
      final dy = (_dy[c.id] ?? 0).clamp(0.0, maxDy);
      void scrollBy(double ddx, double ddy) => setState(() {
            _dx[c.id] = (dx + ddx).clamp(0.0, maxDx);
            _dy[c.id] = (dy + ddy).clamp(0.0, maxDy);
          });
      return Column(children: [
        Expanded(
          child: Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) {
                final d = e.scrollDelta;
                // a plain wheel scrolls the time axis, shift the rows
                scrollBy(d.dy.abs() > d.dx.abs() && !HardwareKeyboard.instance.isShiftPressed
                    ? d.dy
                    : d.dx, 0);
              }
            },
            child: GestureDetector(
              onTapUp: (d) => _tap(c, d.localPosition),
              onScaleStart: (_) => _pinchStart = _pinch,
              onScaleUpdate: (d) {
                if (d.pointerCount > 1) {
                  final focusX = d.localFocalPoint.dx - geo.tableWidth;
                  final before = (dx + focusX) / _hScale;
                  setState(() {
                    _pinch = (_pinchStart * d.horizontalScale).clamp(0.1, 20.0);
                    _dx[c.id] = math.max(0.0, before * _hScale - focusX);
                  });
                } else {
                  scrollBy(-d.focalPointDelta.dx, -d.focalPointDelta.dy);
                }
              },
              child: ClipRect(
                child: CustomPaint(
                  key: ValueKey('barchart-${m.shell ?? 'inline'}-${c.id}'),
                  painter: _painters[c.id] =
                      BarChartPainter(geo, dx: dx, dy: dy, selected: _selected),
                  size: Size.infinite,
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          height: bar,
          child: Row(children: [
            SizedBox(width: math.min(geo.tableWidth, box.maxWidth)),
            Expanded(
              child: _ScrollStrip(
                key: ValueKey('barchart-scroll-${c.id}'),
                offset: dx,
                extent: geo.axisWidth,
                view: viewW,
                onScroll: (v) => setState(() => _dx[c.id] = v.clamp(0.0, maxDx)),
              ),
            ),
          ]),
        ),
      ]);
    });
  }
}

/// A chart's horizontal scroll bar: the thumb is the visible share of the
/// time axis; dragging or tapping it scrolls.
class _ScrollStrip extends StatelessWidget {
  const _ScrollStrip({
    super.key,
    required this.offset,
    required this.extent,
    required this.view,
    required this.onScroll,
  });
  final double offset, extent, view;
  final void Function(double offset) onScroll;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      final share = extent <= 0 ? 1.0 : (view / extent).clamp(0.05, 1.0);
      final thumb = w * share;
      final travel = math.max(1.0, w - thumb);
      final maxOff = math.max(0.0, extent - view);
      final at = maxOff <= 0 ? 0.0 : offset / maxOff * travel;
      void jump(double x) =>
          onScroll(((x - thumb / 2) / travel).clamp(0.0, 1.0) * maxOff);
      return GestureDetector(
        onTapDown: (d) => jump(d.localPosition.dx),
        onHorizontalDragUpdate: (d) => jump(d.localPosition.dx),
        child: CustomPaint(
          size: Size(w, box.maxHeight),
          painter: _StripPainter(at, thumb),
        ),
      );
    });
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter(this.at, this.thumb);
  final double at, thumb;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFE8E8E8));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(at, 2, thumb, size.height - 4), const Radius.circular(3)),
      Paint()..color = const Color(0xFF9A9A9A),
    );
  }

  @override
  bool shouldRepaint(_StripPainter old) => old.at != at || old.thumb != thumb;
}

/// One chart's layout in logical pixels: the table width, the header, the
/// rows, the time axis at the current horizontal scale.
class BarChartGeometry {
  BarChartGeometry(this.model, this.chart, {this.hScale = 1}) {
    var x = 0.0;
    for (var col = 1; col <= chart.columnCount; col++) {
      columnX.add(x);
      x += px(chart.columnWidths[col] ?? 2000);
    }
    tableWidth = chart.columnCount == 0 ? 0 : x;
    final units = chart.ribbonUnits;
    ribbonUnits = units.isEmpty ? const [3, 5] : units;
    headerHeight = math.max(2, ribbonUnits.length) * ribbonHeight;
    var y = 0.0;
    for (var r = 1; r <= chart.rowCount; r++) {
      rowY.add(y);
      y += px(model.rowHeight(chart, r));
    }
    rowY.add(y);
    rowsHeight = y;
  }

  final SapBarChartModel model;
  final BarChartChart chart;
  final double hScale;
  static const double ribbonHeight = 18;

  /// The left of each table column (index 0 = column 1).
  final List<double> columnX = [];
  late final double tableWidth;
  late final List<int> ribbonUnits;
  late final double headerHeight;

  /// The top of each row (index 0 = row 1), then the bottom of the last.
  final List<double> rowY = [];
  late final double rowsHeight;

  static double px(double mm100) => mm100 / 100 * SapBarChartView.pxPerMm;

  /// The x of [t] in the time area (before scrolling).
  double xOf(DateTime t) => px(model.xOf(t)) * hScale;
  double get axisWidth => xOf(model.end);

  double rowTop(int row) => rowY[(row - 1).clamp(0, rowY.length - 1)];
  double rowHeight(int row) =>
      row >= 1 && row < rowY.length ? rowY[row] - rowY[row - 1] : 0;
}

/// Paints one chart. Records what it drew (bars, symbols, header cells,
/// table texts) in [drawn] for tests.
class BarChartPainter extends CustomPainter {
  BarChartPainter(this.geo,
      {this.dx = 0, this.dy = 0, this.selected = const {}});

  /// The marked nodes (chart, node id): drawn with the mark colour
  /// (/$OPTS `SET MARKCOL`, the demo's CYAN).
  final Set<(String, String)> selected;

  /// What the last paint placed per node, in the widget's coordinates.
  final List<(Rect, BarChartNode)> hits = [];

  /// The node whose bar / line / symbol is at [p] (widget coordinates),
  /// the topmost drawn; null on none.
  BarChartNode? nodeAt(Offset p) {
    for (final (r, n) in hits.reversed) {
      if (r.inflate(3).contains(p)) return n;
    }
    return null;
  }

  void _hit(Rect contentRect, BarChartNode n, Canvas canvas) {
    hits.add((contentRect.translate(geo.tableWidth - dx, geo.headerHeight - dy), n));
    if (!selected.contains((geo.chart.id, n.id))) return;
    canvas.drawRect(
        contentRect.inflate(2),
        Paint()
          ..color = barChartColor(m.options['MARKCOL'] ?? 'CYAN') ?? Colors.cyan
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
    drawn.add('mark');
  }
  final BarChartGeometry geo;
  final double dx, dy;

  /// What the last paint drew: `bar`, `line`, `symbol:<shape>`, `ribbon`,
  /// `shade`, `gridline`, `cell:<text>`, `header:<text>`, `dateline`.
  final List<String> drawn = [];

  SapBarChartModel get m => geo.model;
  BarChartChart get c => geo.chart;

  Color _c(String? name, Color fallback) => barChartColor(name) ?? fallback;
  BarChartHighlight? _h(String? id) => id == null ? null : m.highlight(id);

  @override
  void paint(Canvas canvas, Size size) {
    drawn.clear();
    hits.clear();
    final left = geo.tableWidth;
    final top = geo.headerHeight;
    final timeArea = Rect.fromLTRB(left, top, size.width, size.height);
    // backgrounds: the table and diagram section colours
    canvas.drawRect(Rect.fromLTRB(0, 0, left, size.height),
        Paint()..color = _c(_h(c.tableHighlight)?.fill, const Color(0xFFD9D9D9)));
    canvas.drawRect(timeArea,
        Paint()..color = _c(_h(c.diagramHighlight)?.fill, const Color(0xFFCFCFCF)));
    // the visible time span
    final t0 = _timeAt(dx), t1 = _timeAt(dx + timeArea.width);
    canvas.save();
    canvas.clipRect(timeArea);
    canvas.translate(left - dx, top - dy);
    _grids(canvas, t0, t1, timeArea.height + dy);
    _rows(canvas, timeArea, t0, t1);
    _dateLines(canvas, timeArea.height + dy);
    canvas.restore();
    // the header (scrolls horizontally only)
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(left, 0, size.width, top));
    canvas.translate(left - dx, 0);
    _header(canvas, t0, t1);
    canvas.restore();
    // the table (scrolls vertically only)
    _table(canvas, size);
    // the frame lines between the parts
    final frame = Paint()
      ..color = const Color(0xFF505050)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(left, 0), Offset(left, size.height), frame);
    canvas.drawLine(Offset(0, top), Offset(size.width, top), frame);
  }

  DateTime _timeAt(double x) {
    // invert xOf by bisection over the axis
    var a = m.start, b = m.end;
    if (x <= 0) return a;
    if (x >= geo.axisWidth) return b;
    for (var i = 0; i < 40; i++) {
      final mid = a.add(Duration(seconds: b.difference(a).inSeconds ~/ 2));
      if (geo.xOf(mid) < x) {
        a = mid;
      } else {
        b = mid;
      }
      if (b.difference(a).inMinutes < 30) break;
    }
    return a;
  }

  /// The section span [s] covers: its start to the next section's (or the
  /// axis end).
  (DateTime, DateTime) _sectionSpan(String sectionId) {
    final secs = m.sections;
    final i = secs.indexWhere((s) => s.id == sectionId);
    if (i < 0) return (m.start, m.end);
    final end = i + 1 < secs.length ? secs[i + 1].start : m.end;
    final start = i == 0 && m.start.isBefore(secs[i].start) ? m.start : secs[i].start;
    return (start, end);
  }

  void _grids(Canvas canvas, DateTime t0, DateTime t1, double height) {
    for (final g in c.grids) {
      final (gs, ge) = g.section.isEmpty ? (m.start, m.end) : _sectionSpan(g.section);
      final a = gs.isAfter(t0) ? gs : t0, b = ge.isBefore(t1) ? ge : t1;
      if (!b.isAfter(a)) continue;
      final h = _h(g.highlight);
      if (g.isCalendar) {
        final cal = m.calendars['${g.value}'];
        if (cal == null) continue;
        final p = Paint()..color = _c(h?.fill, const Color(0xFFA8A8A8));
        for (final (x0, x1) in cal.offSpans(a, b)) {
          canvas.drawRect(
              Rect.fromLTRB(geo.xOf(x0), 0, geo.xOf(x1), height), p);
          drawn.add('shade');
        }
      } else {
        final p = Paint()
          ..color = _c(h?.line, Colors.black54)
          ..strokeWidth = double.tryParse(h?.values['t'] ?? '') ?? 1;
        var t = barChartUnitStart(a, g.value);
        for (var guard = 0; t.isBefore(b) && guard < 5000; guard++) {
          if (!t.isBefore(a)) {
            final x = geo.xOf(t);
            canvas.drawLine(Offset(x, 0), Offset(x, height), p);
            drawn.add('gridline');
          }
          t = barChartUnitNext(t, g.value);
        }
      }
    }
  }

  void _rows(Canvas canvas, Rect area, DateTime t0, DateTime t1) {
    final sep = Paint()
      ..color = const Color(0x40000000)
      ..strokeWidth = 0.5;
    for (var r = 1; r <= c.rowCount; r++) {
      final y0 = geo.rowTop(r), rh = geo.rowHeight(r);
      if (y0 > dy + area.height || y0 + rh < dy) continue;
      canvas.drawLine(Offset(dx, y0 + rh), Offset(dx + area.width, y0 + rh), sep);
      final mid = y0 + rh / 2;
      // the row's layers in drawing order: by the macro's level (`p`), the
      // taller first — a node's frame-high bars (BARCOCX1 node 2, h 2 000)
      // never hide a lower node's slim ones (node 1, h 500 / 400)
      final order = <(BarChartNode, BarChartLayer, int)>[];
      for (final n in c.nodesAt(r)) {
        for (final id in n.layers) {
          final l = m.layers[id];
          if (l != null) order.add((n, l, order.length));
        }
      }
      double level(BarChartLayer l) => double.tryParse(l.macro.priority ?? '') ?? 0;
      double tall(BarChartLayer l) => l.isBar
          ? (l.macro.height ?? SapBarChartModel.barDefaultHeight)
          : 0;
      order.sort((a, b) {
        final p = level(a.$2).compareTo(level(b.$2));
        if (p != 0) return p;
        final t = tall(b.$2).compareTo(tall(a.$2));
        return t != 0 ? t : a.$3.compareTo(b.$3);
      });
      for (final (n, l, _) in order) {
        {
          final cal = n.calendar == null ? null : m.calendars[n.calendar];
          final mac = l.macro;
          final h = _h(l.highlight);
          final from = n.times[mac.from ?? 1];
          if (from == null) continue;
          final cy = mid + BarChartGeometry.px(mac.offset);
          if (l.isSymbol) {
            final at = Offset(geo.xOf(from), cy);
            final size = BarChartGeometry.px(450);
            _symbol(canvas, at, barChartSymbolOf(mac.symbol), size, h);
            _hit(Rect.fromCircle(center: at, radius: size / 2), n, canvas);
            continue;
          }
          final to = n.times[mac.to ?? 2];
          if (to == null) continue;
          final x0 = geo.xOf(from.isBefore(to) ? from : to);
          final x1 = geo.xOf(from.isBefore(to) ? to : from);
          if (x1 < dx - 4 || x0 > dx + area.width + 4) continue;
          if (l.isLine) {
            canvas.drawLine(Offset(x0, cy), Offset(x1, cy),
                Paint()
                  ..color = _c(h?.line, Colors.black)
                  ..strokeWidth = 1.5);
            drawn.add('line');
            _hit(Rect.fromLTRB(x0, cy - 2, x1, cy + 2), n, canvas);
            continue;
          }
          final bh = BarChartGeometry.px(mac.height ?? SapBarChartModel.barDefaultHeight);
          _bar(canvas, x0, x1, cy - bh / 2, cy + bh / 2, h,
              off: cal?.offSpans(from.isBefore(to) ? from : to,
                  from.isBefore(to) ? to : from));
          _hit(Rect.fromLTRB(x0, cy - bh / 2, x1, cy + bh / 2), n, canvas);
        }
      }
    }
  }

  /// A bar; on a calendar ([off]) it is interrupted by the non-working
  /// spans (thin connector across them) — the dashed look of the real
  /// GUI's row 6.
  void _bar(Canvas canvas, double x0, double x1, double y0, double y1,
      BarChartHighlight? h, {List<(DateTime, DateTime)>? off}) {
    final fill = Paint()..color = _c(h?.fill, Colors.blue);
    final border = Paint()
      ..color = _c(h?.line, Colors.black)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final pieces = <(double, double)>[];
    var at = x0;
    for (final (a, b) in off ?? const <(DateTime, DateTime)>[]) {
      final xa = geo.xOf(a), xb = geo.xOf(b);
      if (xa > at) pieces.add((at, math.min(xa, x1)));
      at = math.max(at, xb);
    }
    if (at < x1) pieces.add((at, x1));
    if (off != null && off.isNotEmpty && pieces.length > 1) {
      final mid = (y0 + y1) / 2;
      canvas.drawLine(Offset(x0, mid), Offset(x1, mid), border);
    }
    for (final (a, b) in pieces) {
      final r = Rect.fromLTRB(a, y0, math.max(b, a + 1), y1);
      canvas.drawRect(r, fill);
      canvas.drawRect(r, border);
      drawn.add('bar');
    }
  }

  void _symbol(Canvas canvas, Offset at, BarChartSymbol s, double size,
      BarChartHighlight? h) {
    final fill = Paint()..color = _c(h?.fill, Colors.blue);
    final line = Paint()
      ..color = _c(h?.line, Colors.black)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final r = size / 2;
    final x = at.dx, y = at.dy;
    Path poly(List<Offset> pts) => Path()..addPolygon(pts, true);
    final path = switch (s) {
      BarChartSymbol.arrowDown => Path()
        ..moveTo(x - r * 0.3, y - r)
        ..lineTo(x + r * 0.3, y - r)
        ..lineTo(x + r * 0.3, y)
        ..lineTo(x + r * 0.8, y)
        ..lineTo(x, y + r)
        ..lineTo(x - r * 0.8, y)
        ..lineTo(x - r * 0.3, y)
        ..close(),
      BarChartSymbol.triangleDown =>
        poly([Offset(x - r, y - r), Offset(x + r, y - r), Offset(x, y + r)]),
      BarChartSymbol.chevron => poly([
          Offset(x - r, y - r), Offset(x - r * 0.4, y - r), Offset(x + r, y),
          Offset(x - r * 0.4, y + r), Offset(x - r, y + r), Offset(x + r * 0.3, y),
        ]),
      BarChartSymbol.slimTriangleUp =>
        poly([Offset(x, y - r), Offset(x + r * 0.45, y + r), Offset(x - r * 0.45, y + r)]),
      BarChartSymbol.triangleRight =>
        poly([Offset(x - r, y - r), Offset(x + r, y), Offset(x - r, y + r)]),
      BarChartSymbol.triangleLeft =>
        poly([Offset(x + r, y - r), Offset(x - r, y), Offset(x + r, y + r)]),
      BarChartSymbol.diamond =>
        poly([Offset(x, y - r), Offset(x + r, y), Offset(x, y + r), Offset(x - r, y)]),
      BarChartSymbol.hourglass => poly([
          Offset(x - r, y - r), Offset(x, y), Offset(x - r, y + r),
          Offset(x + r, y + r), Offset(x, y), Offset(x + r, y - r),
        ]),
      BarChartSymbol.slimTriangleDown =>
        poly([Offset(x - r * 0.45, y - r), Offset(x + r * 0.45, y - r), Offset(x, y + r)]),
      BarChartSymbol.circle =>
        Path()..addOval(Rect.fromCircle(center: at, radius: r)),
      BarChartSymbol.square =>
        Path()..addRect(Rect.fromCircle(center: at, radius: r * 0.8)),
    };
    canvas.drawPath(path, fill);
    canvas.drawPath(path, line);
    drawn.add('symbol:${s.name}');
  }

  void _dateLines(Canvas canvas, double height) {
    for (final d in c.dateLines) {
      final x = geo.xOf(d.date);
      canvas.drawLine(Offset(x, 0), Offset(x, height),
          Paint()
            ..color = _c(_h(d.highlight)?.line, Colors.red)
            ..strokeWidth = 2);
      drawn.add('dateline');
    }
  }

  void _header(Canvas canvas, DateTime t0, DateTime t1) {
    final units = geo.ribbonUnits;
    for (final (i, unit) in units.indexed) {
      final y0 = i * BarChartGeometry.ribbonHeight;
      final y1 = y0 + BarChartGeometry.ribbonHeight;
      // label every k-th cell when one cell is too narrow for its label
      final cellW = BarChartGeometry.px(
              (m.sectionAt(t0)?.width ?? 50) * barChartUnitDays(unit)) *
          geo.hScale;
      final daily = unit >= 5;
      final step = daily && cellW < 16 ? 7 : 1;
      var t = barChartUnitStart(t0, step == 7 ? 4 : unit);
      for (var guard = 0; t.isBefore(t1) && guard < 2000; guard++) {
        final next = step == 7
            ? barChartUnitNext(t, 4)
            : barChartUnitNext(t, unit);
        final x0 = geo.xOf(t), x1 = geo.xOf(next);
        final rib = c.ribbons
            .where((r) => r.unit == unit && _inSection(r.section, t))
            .firstOrNull;
        final h = _h(rib?.highlight);
        final cell = Rect.fromLTRB(x0, y0, x1, y1);
        canvas.drawRect(cell, Paint()..color = _c(h?.fill, const Color(0xFFF3E28A)));
        canvas.drawRect(
            cell,
            Paint()
              ..color = _c(h?.line, Colors.black54)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.6);
        final label = switch (unit) {
          1 => '${t.year}',
          2 => 'T${(t.month - 1) ~/ 3 + 1} ${t.year}',
          3 => x1 - x0 > 52
              ? "${m.monthLabel(t.month)} '${(t.year % 100).toString().padLeft(2, '0')}"
              : m.monthLabel(t.month),
          4 => t.day.toString().padLeft(2, '0'),
          _ => t.day.toString().padLeft(2, '0'),
        };
        _text(canvas, label, cell, _c(h?.third, Colors.black), center: true);
        drawn.add('ribbon');
        t = next;
      }
    }
  }

  bool _inSection(String section, DateTime t) {
    if (section.isEmpty) return true;
    final (a, b) = _sectionSpan(section);
    return !t.isBefore(a) && t.isBefore(b);
  }

  void _table(Canvas canvas, Size size) {
    if (geo.tableWidth <= 0) return;
    final top = geo.headerHeight;
    final grid = Paint()
      ..color = const Color(0xFF6A6A6A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;
    // the corner: the title cell over the column header row
    final title = c.titleBox;
    final header = c.headerBox;
    final hRows = geo.ribbonUnits.length;
    final rowH = BarChartGeometry.ribbonHeight;
    if (title != null) {
      final r = Rect.fromLTWH(0, 0, geo.tableWidth, rowH * math.max(1, hRows - 1));
      final h = _h(title.highlight);
      canvas.drawRect(r, Paint()..color = _c(h?.fill, const Color(0xFFB7C7E0)));
      canvas.drawRect(r, grid);
      final t = title.values['0'] ?? title.values['1'] ?? '';
      _text(canvas, t, r.deflate(3), _c(h?.third, Colors.black));
      drawn.add('header:$t');
    }
    if (header != null) {
      final y = title != null ? rowH * math.max(1, hRows - 1) : 0.0;
      _boxRow(canvas, header, y, top - y, grid, isHeader: true);
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, top, geo.tableWidth, size.height));
    canvas.translate(0, top - dy);
    for (var row = 1; row <= c.rowCount; row++) {
      final b = c.boxAt(row);
      final y0 = geo.rowTop(row), rh = geo.rowHeight(row);
      if (b == null) {
        canvas.drawRect(Rect.fromLTWH(0, y0, geo.tableWidth, rh), grid);
        continue;
      }
      _boxRow(canvas, b, y0, rh, grid);
    }
    canvas.restore();
  }

  void _boxRow(Canvas canvas, BarChartBox b, double y, double h, Paint grid,
      {bool isHeader = false}) {
    final hl = _h(b.highlight);
    final fmt = m.formats[b.format];
    final fields = fmt?.fieldNames ?? const <String>[];
    for (var col = 1; col <= c.columnCount; col++) {
      final x0 = geo.columnX[col - 1];
      final x1 = col < c.columnCount ? geo.columnX[col] : geo.tableWidth;
      final cell = Rect.fromLTRB(x0, y, x1, y + h);
      canvas.drawRect(cell, Paint()..color = _c(hl?.fill, const Color(0xFFF7E26B)));
      canvas.drawRect(cell, grid);
      // field k of the format shows value k in column k (`[$a/$b/$c]`)
      final letter = col <= fields.length
          ? fields[col - 1]
          : String.fromCharCode(0x60 + col);
      final text = b.values['${barChartFieldIndex(letter)}'] ?? '';
      if (text.isEmpty) continue;
      final color = isHeader
          ? _c(hl?.third, Colors.black)
          : _c(fmt?.colorOf(letter) ?? hl?.third, Colors.black);
      _text(canvas, text, cell.deflate(3), color);
      drawn.add(isHeader ? 'header:$text' : 'cell:$text');
    }
  }

  void _text(Canvas canvas, String s, Rect r, Color color, {bool center = false}) {
    if (s.isEmpty || r.width < 4 || r.height < 6) return;
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: TextStyle(
              fontSize: math.min(12, r.height * 0.75), color: color)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(0, r.width));
    final dxText = center ? r.left + (r.width - tp.width) / 2 : r.left;
    tp.paint(canvas, Offset(dxText, r.top + (r.height - tp.height) / 2));
  }

  @override
  bool shouldRepaint(BarChartPainter old) =>
      old.geo.model != geo.model ||
      old.geo.hScale != geo.hScale ||
      old.dx != dx ||
      old.dy != dy ||
      !setEquals(old.selected, selected);
}
