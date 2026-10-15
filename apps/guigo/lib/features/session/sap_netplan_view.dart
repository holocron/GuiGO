import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

import 'sap_graph_view.dart' show jnetColor;

/// A NetPlan graph (SAPGUI.NetPlanGraphics.1) drawn the way SAPnetz.OCX
/// draws it, from the stream's own look ([NetPlanDecor]): every node in
/// its format's SHAPE (rectangle / table box, capsule, hexagon,
/// parallelogram, circle) with its fields in rows and cells, each field's
/// font, style, size and colour; the highlight set's fill, outline,
/// shadow and symbol; the frames (/$CLUSTER) around their member nodes
/// with their titles; orthogonal lines with rounded corners leaving and
/// entering the side their anchor code names (`EA` = from the END side
/// into the START side), coloured by their highlight set, a junction dot
/// where lines share a port and an arrowhead (a bar before it when the
/// line's `E` value asks one); the legend (/$LEGEND: a sample per node
/// type between its caption lines).
///
/// At its NATURAL scale (100 %), in a viewport that scrolls both ways
/// (scroll bars always shown), a toolbar of zoom buttons above it, and —
/// when the control shows one ([NetPlanDecor.overview]: GFW_DEMO_HIER3's
/// structure graphic) — the overview window beside it: the whole graph in
/// miniature, the visible part framed; a tap or drag there scrolls to it.
///
/// Placement: the /$POS raster when the stream carries one (SWDD), else —
/// the streams of the corpus send NO position (NETZOCX1, HIER3, STMS;
/// the OCX lays them out itself) — a hierarchy (/$GTYPE `T`) top-down as
/// an org chart, a network left to right by its links, each frame's
/// members kept together.
class SapNetPlanView extends StatefulWidget {
  const SapNetPlanView({super.key, required this.graph, this.onTapNode});

  final SapNetPlanModel graph;

  /// A tap on a node (the control's node event).
  final void Function(NetPlanNode node)? onTapNode;

  @override
  State<SapNetPlanView> createState() => _SapNetPlanViewState();
}

class _SapNetPlanViewState extends State<SapNetPlanView> {
  final _h = ScrollController();
  final _v = ScrollController();
  double _zoom = 1;
  NetPlanScene? _scene;
  SapNetPlanModel? _sceneOf;

  NetPlanScene get scene {
    if (!identical(_sceneOf, widget.graph) || _scene == null) {
      _sceneOf = widget.graph;
      _scene = layoutNetPlan(widget.graph);
    }
    return _scene!;
  }

  @override
  void dispose() {
    _h.dispose();
    _v.dispose();
    super.dispose();
  }

  void _setZoom(double z) =>
      setState(() => _zoom = z.clamp(0.25, 3.0).toDouble());

  void _tap(Offset local) {
    final cb = widget.onTapNode;
    if (cb == null) return;
    final p = local / _zoom;
    final s = scene;
    for (final n in widget.graph.nodes.reversed) {
      final r = s.nodes[n.id];
      if (r != null && r.contains(p)) {
        cb(n);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = scene;
    final g = widget.graph;
    final bg = netPlanBackground(g.decor.background);
    final canvas = GestureDetector(
      key: const ValueKey('netplan-surface'),
      onTapUp: (d) => _tap(d.localPosition),
      child: CustomPaint(
        size: s.size * _zoom,
        painter: NetPlanPainter(g, s, zoom: _zoom),
      ),
    );
    final viewport = ColoredBox(
      color: bg,
      child: Scrollbar(
        controller: _h,
        thumbVisibility: true,
        child: Scrollbar(
          controller: _v,
          thumbVisibility: true,
          notificationPredicate: (n) => n.depth == 1,
          child: SingleChildScrollView(
            key: const ValueKey('netplan-h'),
            controller: _h,
            scrollDirection: Axis.horizontal,
            child: SingleChildScrollView(
              key: const ValueKey('netplan-v'),
              controller: _v,
              child: canvas,
            ),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(context),
        Expanded(
          // one Row whether or not the overview shows: the viewport keeps
          // its element (and its scroll positions) when it comes and goes
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: viewport),
              if (g.decor.overview) ...[
                const VerticalDivider(width: 1),
                SizedBox(
                  width: 168,
                  child: _NetPlanOverview(
                    key: const ValueKey('netplan-overview'),
                    graph: g,
                    scene: s,
                    zoom: _zoom,
                    h: _h,
                    v: _v,
                    background: bg,
                    frame: jnetColor(g.decor.options['NAVFRAME']) ??
                        Colors.green,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _toolbar(BuildContext context) {
    final t = Theme.of(context).textTheme.bodySmall;
    Widget b(IconData i, String tip, VoidCallback on, {Key? key}) =>
        IconButton(
          key: key,
          tooltip: tip,
          icon: Icon(i, size: 18),
          visualDensity: VisualDensity.compact,
          onPressed: on,
        );
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            b(Icons.zoom_out, 'Zoom out', () => _setZoom(_zoom / 1.25),
                key: const ValueKey('netplan-zoom-out')),
            SizedBox(
              width: 44,
              child: Text('${(_zoom * 100).round()} %',
                  textAlign: TextAlign.center, style: t),
            ),
            b(Icons.zoom_in, 'Zoom in', () => _setZoom(_zoom * 1.25),
                key: const ValueKey('netplan-zoom-in')),
            b(Icons.crop_free, 'Natural size', () => _setZoom(1)),
            b(Icons.fit_screen, 'Fit', () {
              final box = context.findRenderObject() as RenderBox?;
              if (box == null) return;
              final s = scene.size;
              _setZoom(math.min(
                1,
                math.min(box.size.width / (s.width + 8),
                    (box.size.height - 32) / (s.height + 8)),
              ));
            }),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.graph.title,
                overflow: TextOverflow.ellipsis,
                style: t,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The overview window: the whole graph scaled into the pane, the
/// viewport's visible part framed; a tap / drag scrolls there.
class _NetPlanOverview extends StatelessWidget {
  const _NetPlanOverview({
    super.key,
    required this.graph,
    required this.scene,
    required this.zoom,
    required this.h,
    required this.v,
    required this.background,
    required this.frame,
  });

  final SapNetPlanModel graph;
  final NetPlanScene scene;
  final double zoom;
  final ScrollController h, v;
  final Color background, frame;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, cons) {
      final k = math.min(
        cons.maxWidth / scene.size.width,
        cons.maxHeight / scene.size.height,
      );
      void jump(Offset p) {
        if (!h.hasClients || !v.hasClients) return;
        if (!h.position.hasContentDimensions ||
            !v.position.hasContentDimensions) {
          return;
        }
        final c = p / k * zoom;
        final vw = h.position.viewportDimension;
        final vh = v.position.viewportDimension;
        h.jumpTo((c.dx - vw / 2).clamp(0.0, h.position.maxScrollExtent));
        v.jumpTo((c.dy - vh / 2).clamp(0.0, v.position.maxScrollExtent));
      }

      return GestureDetector(
        onTapDown: (d) => jump(d.localPosition),
        onPanUpdate: (d) => jump(d.localPosition),
        child: ColoredBox(
          color: background,
          child: AnimatedBuilder(
            animation: Listenable.merge([h, v]),
            builder: (context, _) {
              Rect? seen;
              if (h.hasClients &&
                  v.hasClients &&
                  h.position.hasViewportDimension &&
                  v.position.hasViewportDimension) {
                seen = Rect.fromLTWH(
                  h.offset / zoom,
                  v.offset / zoom,
                  h.position.viewportDimension / zoom,
                  v.position.viewportDimension / zoom,
                );
              }
              return CustomPaint(
                size: Size(cons.maxWidth, cons.maxHeight),
                painter: NetPlanPainter(graph, scene,
                    zoom: k, seen: seen, seenColor: frame, overview: true),
              );
            },
          ),
        ),
      );
    },
  );
}

/// The graph's background: its `DISPBACKGR` colour lightened the way the
/// OCX's display background is (GRAY = a light grey), white when unset.
Color netPlanBackground(String? name) {
  final c = jnetColor(name);
  if (c == null) return Colors.white;
  return Color.lerp(c, Colors.white, 0.72)!;
}

// ---------------------------------------------------------------------------
// The layout
// ---------------------------------------------------------------------------

/// Where every part of a graph sits, in control points at 100 %.
class NetPlanScene {
  NetPlanScene({
    required this.size,
    required this.nodes,
    required this.cells,
    required this.clusters,
    required this.lines,
    required this.legend,
    required this.legendItems,
  });

  final Size size;

  /// Node id -> its box.
  final Map<String, Rect> nodes;

  /// Node id -> its field cells (letter, rect), in layout order.
  final Map<String, List<(NetPlanLeaf, Rect)>> cells;

  /// Cluster id -> its frame.
  final Map<String, Rect> clusters;

  /// Every line as its polyline (port to port) with the start port's
  /// junction flag (more lines leave the same port).
  final List<NetPlanLine> lines;

  /// The legend's box, null for none, and its entries' rects.
  final Rect? legend;
  final List<(NetPlanLegendEntry, Rect)> legendItems;
}

class NetPlanLine {
  NetPlanLine(this.edge, this.points, {this.junction});
  final NetPlanEdge edge;
  final List<Offset> points;

  /// The shared port point where a dot marks the branching, null when the
  /// port is the line's own.
  final Offset? junction;
}

const double _gapX = 64, _gapY = 36, _margin = 24;
const double _framePad = 14, _frameTitle = 26;

/// The width in points of one character of a [size] point font.
double _charW(double size) => size * 0.62;

/// The height of one text line of a [size] point font.
double _lineH(double size) => size * 1.5;

/// The box of [n] laid out by [fmt]: its size and its field cells.
(Size, List<(NetPlanLeaf, Rect)>) measureNetPlanNode(
  NetPlanNode? n,
  NetPlanFormat? fmt, {
  Map<String, String>? values,
}) {
  final vals = values ?? n?.values ?? const <String, String>{};
  final cell = fmt?.layout;
  if (fmt == null || cell == null) {
    final text = n?.caption ?? '';
    return (Size(math.max(90, text.length * _charW(10) + 16), 28), [
      (const NetPlanLeaf('a'), const Rect.fromLTWH(0, 0, 0, 0)),
    ]);
  }
  bool shown(NetPlanLeaf l) {
    final f = fmt.fields[l.letter];
    if (l.picture) return true;
    final k = f?.valueKey;
    return k != null && (vals[k] ?? '').trim().isNotEmpty;
  }

  Size leafSize(NetPlanLeaf l) {
    final f = fmt.fields[l.letter];
    if (l.picture) {
      final z = int.tryParse((f?.attrs['z'] ?? '').trim()) ?? 2000;
      final y = int.tryParse((f?.attrs['y'] ?? '').trim()) ?? 2000;
      return Size(z / 100, y / 100);
    }
    final size = f?.size ?? 10;
    // the width counts characters of the control's standard font, not the
    // field's own (NETZOCX1's 18 point `Text.a` keeps its 30 characters)
    final w = (f?.width ?? 12) * _charW(10) + 8;
    if (!shown(l)) return Size(w, 0);
    return Size(w, _lineH(size) * (f?.lines ?? 1) + 4);
  }

  Size measure(NetPlanCell c) => switch (c) {
    NetPlanLeaf() => leafSize(c),
    NetPlanSplit(:final children, :final across) => () {
      var w = 0.0, h = 0.0;
      for (final k in children) {
        final s = measure(k);
        if (across) {
          w += s.width;
          h = math.max(h, s.height);
        } else {
          w = math.max(w, s.width);
          h += s.height;
        }
      }
      return Size(w, h);
    }(),
  };

  final inner = measure(cell);
  final out = <(NetPlanLeaf, Rect)>[];
  void place(NetPlanCell c, Rect r) {
    switch (c) {
      case NetPlanLeaf():
        out.add((c, r));
      case NetPlanSplit(:final children, :final across):
        final sizes = [for (final k in children) measure(k)];
        final total = sizes.fold<double>(
            0, (a, s) => a + (across ? s.width : s.height));
        var at = across ? r.left : r.top;
        for (var i = 0; i < children.length; i++) {
          final share = total <= 0
              ? 0.0
              : (across ? sizes[i].width : sizes[i].height) /
                  total *
                  (across ? r.width : r.height);
          place(
            children[i],
            across
                ? Rect.fromLTWH(at, r.top, share, r.height)
                : Rect.fromLTWH(r.left, at, r.width, share),
          );
          at += share;
        }
    }
  }

  // the shape's own margins around the fields
  final hgt = math.max(inner.height, 22.0);
  final (padX, padY) = switch (fmt.shape) {
    3 => (hgt / 2, 0.0), // capsule: the round ends
    4 => (hgt * 0.35, 0.0), // hexagon: the points
    5 => (hgt * 0.4, 0.0), // parallelogram: the slant
    10 => (0.0, 0.0),
    _ => (0.0, 0.0),
  };
  if (fmt.shape == 10) {
    // a circle (NETZOCX1's Typ.7), its text under it
    const d = 40.0;
    final w = math.max(d, inner.width);
    place(cell, Rect.fromLTWH((w - inner.width) / 2, d + 2, inner.width,
        inner.height));
    return (Size(w, d + 2 + inner.height), out);
  }
  place(cell, Rect.fromLTWH(padX, padY, inner.width, hgt));
  return (Size(inner.width + 2 * padX, hgt + 2 * padY), out);
}

/// Lay [g] out: the boxes, frames, lines and legend ([NetPlanScene]).
NetPlanScene layoutNetPlan(SapNetPlanModel g) {
  final d = g.decor;
  final sizes = <String, Size>{};
  final cellsRel = <String, List<(NetPlanLeaf, Rect)>>{};
  for (final n in g.nodes) {
    final (s, c) = measureNetPlanNode(n, d.formats[n.format]);
    sizes[n.id] = s;
    cellsRel[n.id] = c;
  }
  final vertical =
      g.gtype == 'T' || (d.options['LAYOUT'] ?? '').trim() == '1';
  final memberOf = <String, String>{
    for (final c in d.clusters)
      for (final m in c.members) m: c.id,
  };
  final framed = memberOf.isNotEmpty;
  final top = _margin + (framed ? _frameTitle + _framePad : 0);
  final left = _margin + (framed ? _framePad : 0);
  final pos = <String, Offset>{};
  final hasPos = g.nodes.any((n) => n.col != null && n.row != null);
  if (hasPos) {
    // the server's raster: a cell half a box wide and high
    final mw = sizes.values.fold<double>(0, (a, s) => math.max(a, s.width));
    final mh = sizes.values.fold<double>(0, (a, s) => math.max(a, s.height));
    for (final n in g.nodes) {
      if (n.col == null || n.row == null) continue;
      pos[n.id] = Offset(left + (n.col! - 1) * (mw / 2 + _gapX / 2),
          top + (n.row! - 1) * (mh / 2 + _gapY / 2));
    }
  }
  final rest = [
    for (final n in g.nodes)
      if (!pos.containsKey(n.id)) n.id,
  ];
  if (rest.isNotEmpty && g.gtype == 'T') {
    _treeLayout(g, rest, sizes, pos, Offset(left, top));
  } else if (rest.isNotEmpty) {
    _levelLayout(g, rest, sizes, pos, memberOf,
        Offset(left, top + (pos.isEmpty ? 0 : _bottom(pos, sizes) + _gapY)),
        vertical: vertical);
  }
  final nodes = <String, Rect>{
    for (final n in g.nodes)
      if (pos[n.id] case final p?) n.id: p & sizes[n.id]!,
  };
  // the frames: their members' bounds and the title band; a node of no
  // frame caught inside one moves below the frames
  final clusters = <String, Rect>{};
  for (final c in d.clusters) {
    Rect? r;
    for (final m in c.members) {
      final b = nodes[m];
      if (b == null) continue;
      r = r == null ? b : r.expandToInclude(b);
    }
    if (r == null) continue;
    clusters[c.id] = Rect.fromLTRB(r.left - _framePad,
        r.top - _framePad - _frameTitle, r.right + _framePad,
        r.bottom + _framePad);
  }
  if (clusters.isNotEmpty) {
    var below = clusters.values.fold<double>(0, (a, r) => math.max(a, r.bottom));
    for (final n in g.nodes) {
      if (memberOf.containsKey(n.id)) continue;
      final b = nodes[n.id];
      if (b == null || !clusters.values.any((f) => f.overlaps(b))) continue;
      nodes[n.id] = Offset(b.left, below + _gapY / 2) & b.size;
      below += b.height + _gapY / 2;
    }
  }
  final cells = <String, List<(NetPlanLeaf, Rect)>>{
    for (final e in cellsRel.entries)
      if (nodes[e.key] case final b?)
        e.key: [for (final (l, r) in e.value) (l, r.shift(b.topLeft))],
  };
  final lines = _route(g, nodes, vertical: vertical);
  var bounds = Rect.zero;
  for (final r in [...nodes.values, ...clusters.values]) {
    bounds = bounds.expandToInclude(r);
  }
  for (final l in lines) {
    for (final p in l.points) {
      bounds = bounds.expandToInclude(Rect.fromCircle(center: p, radius: 4));
    }
  }
  // the legend below the graph
  Rect? legend;
  final items = <(NetPlanLegendEntry, Rect)>[];
  if (d.legend.isNotEmpty) {
    final x0 = _margin, y0 = bounds.bottom + _gapY;
    var y = y0 + 8;
    var w = 0.0;
    for (final e in d.legend) {
      if (e.isCaption) {
        final s = Size(math.max(80, e.text.length * _charW(11) + 16), 22);
        items.add((e, Offset(x0 + 8, y) & s));
        w = math.max(w, s.width);
        y += s.height + 6;
      } else {
        final (s, _) = measureNetPlanNode(null, d.formats[e.format],
            values: const {});
        final k = math.min(1.0, 140 / math.max(1, s.width));
        final box = Size(s.width * k, math.max(18, s.height * k));
        items.add((e, Offset(x0 + 8, y) & box));
        w = math.max(w, box.width + 8 + e.text.length * _charW(10) + 16);
        y += box.height + 6;
      }
    }
    legend = Rect.fromLTRB(x0, y0, x0 + w + 16, y + 2);
    bounds = bounds.expandToInclude(legend);
  }
  return NetPlanScene(
    size: Size(bounds.right + _margin, bounds.bottom + _margin),
    nodes: nodes,
    cells: cells,
    clusters: clusters,
    lines: lines,
    legend: legend,
    legendItems: items,
  );
}

double _bottom(Map<String, Offset> pos, Map<String, Size> sizes) =>
    pos.entries.fold<double>(
        0, (a, e) => math.max(a, e.value.dy + sizes[e.key]!.height));

/// A hierarchy (/$GTYPE T) as an org chart: each root's tree top-down,
/// a parent centred over its children, the roots side by side.
void _treeLayout(SapNetPlanModel g, List<String> ids, Map<String, Size> sizes,
    Map<String, Offset> pos, Offset origin) {
  final want = ids.toSet();
  final kids = <String, List<String>>{};
  final hasParent = <String>{};
  for (final e in g.edges) {
    if (!want.contains(e.from) || !want.contains(e.to) || e.from == e.to) {
      continue;
    }
    if (!hasParent.add(e.to)) continue; // a second parent: not a tree link
    (kids[e.from] ??= []).add(e.to);
  }
  final mh = sizes.values.fold<double>(0, (a, s) => math.max(a, s.height));
  final rowStep = mh + _gapY + 12;
  var x = origin.dx;
  final seen = <String>{};
  // the subtree of [id] from [x0]: returns its width
  double place(String id, double x0, int depth) {
    seen.add(id);
    final s = sizes[id]!;
    final cs = [for (final c in kids[id] ?? const <String>[]) if (!seen.contains(c)) c];
    if (cs.isEmpty) {
      pos[id] = Offset(x0, origin.dy + depth * rowStep);
      return s.width;
    }
    var cx = x0;
    for (final c in cs) {
      cx += place(c, cx, depth + 1) + _gapX / 3;
    }
    final span = cx - _gapX / 3 - x0;
    final first = pos[cs.first]!, last = pos[cs.last]!;
    final mid = (first.dx + last.dx + sizes[cs.last]!.width) / 2;
    final px = math.max(x0, mid - s.width / 2);
    pos[id] = Offset(px, origin.dy + depth * rowStep);
    return math.max(span, px + s.width - x0);
  }

  for (final id in ids) {
    if (hasParent.contains(id) || seen.contains(id)) continue;
    x += place(id, x, 0) + _gapX;
  }
  for (final id in ids) {
    if (!seen.contains(id)) x += place(id, x, 0) + _gapX;
  }
}

/// A network by its links: the longest path from a root decides a node's
/// level (left to right, top-down when [vertical]); within a level the
/// members of one frame stay together.
void _levelLayout(
  SapNetPlanModel g,
  List<String> ids,
  Map<String, Size> sizes,
  Map<String, Offset> pos,
  Map<String, String> memberOf,
  Offset origin, {
  required bool vertical,
}) {
  final want = ids.toSet();
  final level = {for (final id in ids) id: 0};
  for (var pass = 0; pass < ids.length; pass++) {
    var changed = false;
    for (final e in g.edges) {
      if (!want.contains(e.from) || !want.contains(e.to) || e.from == e.to) {
        continue;
      }
      final l = level[e.from]! + 1;
      if (l > level[e.to]! && l < ids.length) {
        level[e.to] = l;
        changed = true;
      }
    }
    if (!changed) break;
  }
  final byLevel = <int, List<String>>{};
  for (final id in ids) {
    (byLevel[level[id]!] ??= []).add(id);
  }
  final order = {for (var i = 0; i < ids.length; i++) ids[i]: i};
  final clusterOrder = <String, int>{};
  for (final id in ids) {
    final c = memberOf[id];
    if (c != null) clusterOrder.putIfAbsent(c, () => clusterOrder.length);
  }
  final levels = byLevel.keys.toList()..sort();
  var along = vertical ? origin.dy : origin.dx;
  var prevCluster = <String?>{};
  for (final l in levels) {
    final list = byLevel[l]!
      ..sort((a, b) {
        final ca = clusterOrder[memberOf[a]] ?? 1 << 20;
        final cb = clusterOrder[memberOf[b]] ?? 1 << 20;
        return ca != cb ? ca.compareTo(cb) : order[a]!.compareTo(order[b]!);
      });
    // a frame boundary between levels takes the frames' padding too
    final clusters = {for (final id in list) memberOf[id]};
    if (prevCluster.isNotEmpty &&
        !clusters.any((c) => c != null && prevCluster.contains(c))) {
      along += 2 * _framePad + (vertical ? _frameTitle : 0);
    }
    prevCluster = clusters;
    var across = vertical ? origin.dx : origin.dy;
    var extent = 0.0;
    String? cur;
    for (final id in list) {
      final s = sizes[id]!;
      final c = memberOf[id];
      if (cur != null && c != cur) {
        across += 2 * _framePad + (vertical ? 0 : _frameTitle);
      }
      cur = c;
      pos[id] = vertical ? Offset(across, along) : Offset(along, across);
      across += (vertical ? s.width : s.height) + (vertical ? _gapX / 2 : _gapY);
      extent = math.max(extent, vertical ? s.height : s.width);
    }
    along += extent + (vertical ? _gapY + 12 : _gapX);
  }
}

/// The side of a box an anchor letter names: `E` the end side (right; the
/// bottom in a top-down graph), `A` the start side (left; the top).
Offset _port(Rect r, String side, {required bool vertical}) {
  final end = side == 'E';
  if (vertical) return end ? r.bottomCenter : r.topCenter;
  return end ? r.centerRight : r.centerLeft;
}

Offset _out(String side, {required bool vertical}) {
  final s = side == 'E' ? 1.0 : -1.0;
  return vertical ? Offset(0, s) : Offset(s, 0);
}

final RegExp _anchorRx = RegExp(r'^[AE]{2}$');

/// The anchor code of [e]: its /$LINES terminator as /$LVALS key 0 names
/// it (`EA` …), else the flow's own (`EA`).
String netPlanAnchor(NetPlanEdge e) {
  final v = (e.values['0'] ?? '').trim();
  return _anchorRx.hasMatch(v) ? v : 'EA';
}

List<NetPlanLine> _route(SapNetPlanModel g, Map<String, Rect> nodes,
    {required bool vertical}) {
  const stub = 16.0;
  final out = <NetPlanLine>[];
  final portUse = <(String, String), int>{};
  for (final e in g.edges) {
    final code = netPlanAnchor(e);
    portUse[(e.from, code[0])] = (portUse[(e.from, code[0])] ?? 0) + 1;
  }
  for (final e in g.edges) {
    final a = nodes[e.from], b = nodes[e.to];
    if (a == null || b == null) continue;
    final code = netPlanAnchor(e);
    final p0 = _port(a, code[0], vertical: vertical);
    final p1 = _port(b, code[1], vertical: vertical);
    final d0 = _out(code[0], vertical: vertical);
    final d1 = _out(code[1], vertical: vertical);
    final s0 = p0 + d0 * stub, s1 = p1 + d1 * stub;
    Offset along(Offset p, double v) =>
        vertical ? Offset(p.dx, v) : Offset(v, p.dy);
    Offset cross(Offset p, double v) =>
        vertical ? Offset(v, p.dy) : Offset(p.dx, v);
    double ax(Offset p) => vertical ? p.dy : p.dx;
    double lo(Rect r) => vertical ? r.left : r.top;
    double hi(Rect r) => vertical ? r.right : r.bottom;
    final s0a = ax(s0), s1a = ax(s1);
    final dir0 = vertical ? d0.dy : d0.dx, dir1 = vertical ? d1.dy : d1.dx;
    // the candidate routes between the two stubs, the plain one first: the
    // first that crosses no box wins (NETZOCX1's 1 -> 3 `EE` ran through
    // node 2 straight; 2 -> 4 `AA`, both on one row, through node 2)
    final candidates = <List<Offset>>[];
    if (dir0 == dir1) {
      // the same side (EE / AA): out past both, then back in
      final m = dir0 > 0 ? math.max(s0a, s1a) : math.min(s0a, s1a);
      candidates.add([along(s0, m), along(s1, m)]);
    } else if (dir0 * (s1a - s0a) > 0) {
      // facing each other: across at the middle
      final m = (s0a + s1a) / 2;
      candidates.add([along(s0, m), along(s1, m)]);
    }
    // round through a channel across the flow: between the two boxes,
    // above / below either, above / below every box
    final channels = <double>[
      if (hi(a) < lo(b)) (hi(a) + lo(b)) / 2,
      if (hi(b) < lo(a)) (hi(b) + lo(a)) / 2,
      lo(a) - 12, hi(a) + 12, lo(b) - 12, hi(b) + 12,
      nodes.values.fold<double>(double.infinity, (v, r) => math.min(v, lo(r))) - 14,
      nodes.values.fold<double>(-double.infinity, (v, r) => math.max(v, hi(r))) + 14,
    ];
    for (final c in channels) {
      candidates.add([cross(s0, c), cross(s1, c)]);
    }
    int crossings(List<Offset> mid) {
      final path = [s0, ...mid, s1];
      var n = 0;
      for (var i = 1; i < path.length; i++) {
        final seg = Rect.fromPoints(path[i - 1], path[i]).inflate(0.5);
        for (final r in nodes.values) {
          if (seg.overlaps(r.deflate(2))) n++;
        }
      }
      return n;
    }

    var best = candidates.first;
    var bestN = crossings(best);
    for (final c in candidates.skip(1)) {
      if (bestN == 0) break;
      final n = crossings(c);
      if (n < bestN) {
        best = c;
        bestN = n;
      }
    }
    final pts = <Offset>[p0, s0, ...best, s1, p1];
    // drop zero-length steps
    final clean = <Offset>[pts.first];
    for (final p in pts.skip(1)) {
      if ((p - clean.last).distance > 0.5) clean.add(p);
    }
    out.add(NetPlanLine(e, clean,
        junction: (portUse[(e.from, code[0])] ?? 0) > 1 ? s0 : null));
  }
  return out;
}

// ---------------------------------------------------------------------------
// The painter
// ---------------------------------------------------------------------------

class NetPlanPainter extends CustomPainter {
  NetPlanPainter(
    this.graph,
    this.scene, {
    this.zoom = 1,
    this.seen,
    this.seenColor = Colors.green,
    this.overview = false,
  });

  final SapNetPlanModel graph;
  final NetPlanScene scene;
  final double zoom;

  /// The overview's frame of the visible part (control points).
  final Rect? seen;
  final Color seenColor;

  /// Drawn as the overview: no texts.
  final bool overview;

  Map<String, String> _hl(String id) => graph.highlights[id] ?? const {};

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(zoom);
    final d = graph.decor;
    // frames first, under everything
    for (final c in d.clusters) {
      final r = scene.clusters[c.id];
      if (r != null) _frame(canvas, c, r);
    }
    for (final l in scene.lines) {
      _line(canvas, l, rounded: d.rounded);
    }
    for (final n in graph.nodes) {
      final r = scene.nodes[n.id];
      if (r == null) continue;
      _node(canvas, r, d.formats[n.format], _hl(n.highlight),
          scene.cells[n.id] ?? const [], n.values, fallback: n.caption);
    }
    if (scene.legend case final lg?) _legend(canvas, lg);
    if (seen case final s?) {
      canvas.drawRect(
        s,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = seenColor
          ..strokeWidth = 2 / zoom,
      );
    }
    canvas.restore();
  }

  void _frame(Canvas canvas, NetPlanCluster c, Rect r) {
    final hl = _hl(c.highlight);
    final fmt = graph.decor.formats[c.format];
    final fill = jnetColor(hl['h']) ?? const Color(0xFFFFF59D);
    final line = jnetColor(hl['l']) ?? Colors.black;
    canvas.drawRect(r, Paint()..color = fill);
    canvas.drawRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = line
        ..strokeWidth = fmt?.outlineWidth ?? 1,
    );
    if (overview || c.label.isEmpty) return;
    final f = fmt?.fields['a'];
    _text(
      canvas,
      c.label,
      Rect.fromLTWH(r.left + 6, r.top + 2, r.width - 12, _frameTitle - 2),
      f,
      fallbackColor: Colors.black,
    );
  }

  void _line(Canvas canvas, NetPlanLine l, {required bool rounded}) {
    final hl = _hl(l.edge.highlight);
    final color = jnetColor(hl['l']) ?? jnetColor(hl['h']) ?? Colors.black;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..color = color
      ..strokeWidth = 1.4;
    final pts = l.points;
    if (pts.length < 2) return;
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    const radius = 6.0;
    for (var i = 1; i < pts.length; i++) {
      final cur = pts[i];
      if (!rounded || i == pts.length - 1) {
        path.lineTo(cur.dx, cur.dy);
        continue;
      }
      final prev = pts[i - 1], next = pts[i + 1];
      final r = math.min(
        radius,
        math.min((cur - prev).distance, (next - cur).distance) / 2,
      );
      final a = cur - _unit(cur - prev) * r;
      final b = cur + _unit(next - cur) * r;
      path
        ..lineTo(a.dx, a.dy)
        ..quadraticBezierTo(cur.dx, cur.dy, b.dx, b.dy);
    }
    canvas.drawPath(path, p);
    // the arrowhead into the target, a bar before it when the line's E
    // value asks one (NETZOCX1 lines 1 and 5: E 40 / 44)
    final tip = pts.last, from = pts[pts.length - 2];
    final u = _unit(tip - from);
    final n = Offset(-u.dy, u.dx);
    const len = 9.0, half = 4.5;
    final base = tip - u * len;
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo((base + n * half).dx, (base + n * half).dy)
        ..lineTo((base - n * half).dx, (base - n * half).dy)
        ..close(),
      Paint()..color = color,
    );
    if ((l.edge.values['E'] ?? '').trim().isNotEmpty) {
      final bar = base - u * 3;
      canvas.drawLine(bar + n * half, bar - n * half, p..strokeWidth = 2);
    }
    if (l.junction case final j?) {
      canvas.drawCircle(j, 3, Paint()..color = color);
    }
    if (overview) return;
    final label = netPlanLineLabel(graph, l.edge);
    if (label.isNotEmpty) {
      final mid = pts[pts.length ~/ 2 - 1] + (pts[pts.length ~/ 2] - pts[pts.length ~/ 2 - 1]) / 2;
      _text(canvas, label, Rect.fromCenter(center: mid - const Offset(0, 9), width: 160, height: 16), null,
          fallbackColor: color);
    }
  }

  static Offset _unit(Offset o) {
    final d = o.distance;
    return d == 0 ? Offset.zero : o / d;
  }

  void _node(
    Canvas canvas,
    Rect r,
    NetPlanFormat? fmt,
    Map<String, String> hl,
    List<(NetPlanLeaf, Rect)> cells,
    Map<String, String> values, {
    String fallback = '',
    bool sample = false,
  }) {
    final fill = jnetColor(hl['h']) ?? const Color(0xFFE0E0E0);
    final line = jnetColor(hl['l']) ?? Colors.black;
    final shape = fmt?.shape ?? 1;
    // a circle sits over its text (measureNetPlanNode)
    final sr = shape == 10 ? netPlanCircle(r, cells) : r;
    final path = netPlanShape(shape, sr);
    if (fmt?.shadow ?? false) {
      canvas.drawPath(path.shift(const Offset(3, 3)),
          Paint()..color = jnetColor(hl['s']) ?? Colors.black26);
    }
    canvas.drawPath(path, Paint()..color = fill);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..color = line
      ..strokeWidth = fmt?.outlineWidth ?? 1;
    canvas.drawPath(path, stroke);
    if (fmt?.doubleOutline ?? false) {
      canvas.drawPath(netPlanShape(shape, sr.deflate(3.5)), stroke);
    }
    // the rules between the cells (a `--` / `//` split, a table box)
    if (fmt != null && fmt.layout is NetPlanSplit && shape != 10) {
      canvas.save();
      canvas.clipPath(path);
      final rule = Paint()
        ..color = jnetColor(fmt.ruleColor) ?? line
        ..strokeWidth = 0.8;
      _rules(canvas, fmt.layout!, cells, rule, table: fmt.table);
      canvas.restore();
    }
    final k = (hl['k'] ?? '').trim();
    if (k == '4') {
      // the cross symbol (NETZOCX1 Typ.7's red X)
      final c = jnetColor(hl['C']) ?? Colors.red;
      final s = Paint()
        ..color = c
        ..strokeWidth = 2.5;
      final sq = sr;
      final q = sq.deflate(sq.shortestSide * 0.22);
      canvas
        ..drawLine(q.topLeft, q.bottomRight, s)
        ..drawLine(q.topRight, q.bottomLeft, s);
    }
    if (fmt != null && fmt.tag.isNotEmpty && !sample) {
      // the tag (FMT005 `Test`): a small ellipse on the box's top right
      final e = Rect.fromCenter(
          center: r.topRight + const Offset(-10, -4), width: 40, height: 18);
      canvas.drawOval(e, Paint()..color = Colors.white);
      canvas.drawOval(e, Paint()
        ..style = PaintingStyle.stroke
        ..color = line);
      if (!overview) {
        _text(canvas, fmt.tag, e, null, fallbackColor: Colors.black);
      }
    }
    if (overview) return;
    if (fmt == null) {
      _text(canvas, fallback, r, null, fallbackColor: _contrast(fill));
      return;
    }
    for (final (leaf, cr) in cells) {
      final f = fmt.fields[leaf.letter];
      if (leaf.picture || f == null) continue;
      final key = f.valueKey;
      final v = key == null ? '' : (values[key] ?? '');
      if (v.trim().isEmpty || cr.height <= 0) continue;
      _text(canvas, v, cr.deflate(2), f, fallbackColor: _contrast(fill));
    }
  }

  void _rules(Canvas canvas, NetPlanCell c, List<(NetPlanLeaf, Rect)> cells,
      Paint p, {required bool table}) {
    if (c is! NetPlanSplit) return;
    Rect? boundsOf(NetPlanCell k) {
      Rect? r;
      for (final (l, cr) in cells) {
        if (!k.letters.contains(l.letter) || cr.height <= 0 && !c.across) {
          continue;
        }
        r = r == null ? cr : r.expandToInclude(cr);
      }
      return r;
    }

    if (c.ruled || table) {
      for (var i = 0; i + 1 < c.children.length; i++) {
        final a = boundsOf(c.children[i]);
        if (a == null || a.isEmpty) continue;
        if (c.across) {
          canvas.drawLine(a.topRight, a.bottomRight, p);
        } else {
          // no rule under the last row that shows
          final rest = [
            for (final k in c.children.skip(i + 1))
              if (boundsOf(k) case final b? when b.height > 0) b,
          ];
          if (rest.isEmpty) continue;
          canvas.drawLine(a.bottomLeft, a.bottomRight, p);
        }
      }
    }
    for (final k in c.children) {
      _rules(canvas, k, cells, p, table: table);
    }
  }

  void _legend(Canvas canvas, Rect lg) {
    canvas.drawRect(lg, Paint()..color = const Color(0xFFD9D9D9));
    canvas.drawRect(
        lg,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.black54);
    for (final (e, r) in scene.legendItems) {
      final hl = _hl(e.highlight);
      if (e.isCaption) {
        final fill = jnetColor(hl['h']) ?? Colors.grey;
        canvas.drawRect(r, Paint()..color = Color.lerp(fill, Colors.white, 0.4)!);
        canvas.drawRect(r, Paint()
          ..style = PaintingStyle.stroke
          ..color = jnetColor(hl['l']) ?? Colors.black);
        if (!overview) {
          _text(canvas, e.text, r, null,
              fallbackColor: Colors.black, bold: true);
        }
        continue;
      }
      final fmt = graph.decor.formats[e.format];
      final (_, cells) = measureNetPlanNode(null, fmt, values: const {});
      final k = r.width / math.max(1, _naturalWidth(fmt));
      final scaled = [
        for (final (l, c) in cells)
          (l, Rect.fromLTWH(r.left + c.left * k, r.top + c.top * k,
              c.width * k, c.height * k)),
      ];
      _node(canvas, r, fmt, hl, scaled, const {}, sample: true);
      if (!overview) {
        _text(
          canvas,
          e.text,
          Rect.fromLTWH(r.right + 8, r.top, lg.right - r.right - 12, r.height),
          null,
          fallbackColor: Colors.black,
          align: TextAlign.left,
        );
      }
    }
  }

  double _naturalWidth(NetPlanFormat? fmt) =>
      measureNetPlanNode(null, fmt, values: const {}).$1.width;

  void _text(
    Canvas canvas,
    String text,
    Rect r,
    NetPlanField? f, {
    required Color fallbackColor,
    bool bold = false,
    TextAlign? align,
  }) {
    if (r.width <= 2 || r.height <= 2) return;
    final style = TextStyle(
      color: jnetColor(f?.color) ?? fallbackColor,
      fontSize: f?.size ?? 11,
      fontWeight: (f?.bold ?? bold) ? FontWeight.bold : FontWeight.normal,
      fontStyle: (f?.italic ?? false) ? FontStyle.italic : FontStyle.normal,
      fontFamily: switch (f?.family) {
        'c' => 'monospace',
        't' => 'serif',
        _ => null,
      },
      decoration: (f?.underline ?? false) ? TextDecoration.underline : null,
      height: 1.2,
    );
    final ta = align ??
        switch (f?.align) {
          'l' => TextAlign.left,
          'r' => TextAlign.right,
          _ => TextAlign.center,
        };
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: ta,
      textDirection: TextDirection.ltr,
      maxLines: f?.lines ?? 1,
      ellipsis: '…',
    )..layout(minWidth: r.width, maxWidth: r.width);
    final dy = switch (f?.valign) {
      't' => 0.0,
      'b' => r.height - tp.height,
      _ => (r.height - tp.height) / 2,
    };
    canvas.save();
    canvas.clipRect(r.inflate(1));
    tp.paint(canvas, Offset(r.left, r.top + dy));
    canvas.restore();
    tp.dispose();
  }

  static Color _contrast(Color fill) =>
      fill.computeLuminance() > 0.45 ? Colors.black : Colors.white;

  @override
  bool shouldRepaint(NetPlanPainter old) =>
      !identical(old.graph, graph) ||
      !identical(old.scene, scene) ||
      old.zoom != zoom ||
      old.seen != seen;
}

/// The text a line carries: its format's fields' values (`[$a-$b]` = key
/// 0 then 1: STMS's `Livraison`, `200->200`) — never its anchor code (the
/// NETZOCX1 demo writes `EA` / `AA` … as each line's text; the real GUI
/// draws no relation type on the lines).
String netPlanLineLabel(SapNetPlanModel g, NetPlanEdge e) {
  final fmt = g.decor.formats[e.format];
  final keys = <String>[
    for (final l in fmt?.layout?.letters ?? const ['a'])
      if (fmt?.fields[l]?.valueKey case final k?) k else if (fmt == null) '0',
  ];
  final parts = [
    for (final k in keys)
      if ((e.values[k] ?? (k == '0' ? e.label : '')).trim() case final v
          when v.isNotEmpty && !_anchorRx.hasMatch(v))
        v,
  ];
  return parts.join(' ');
}

/// The circle of a shape-10 box [r]: the square above its text cells.
Rect netPlanCircle(Rect r, List<(NetPlanLeaf, Rect)> cells) {
  var top = r.bottom;
  for (final (_, c) in cells) {
    if (c.height > 0) top = math.min(top, c.top);
  }
  final d = math.max(8.0, math.min(r.width, top - r.top - 2));
  return Rect.fromLTWH(r.center.dx - d / 2, r.top, d, d);
}

/// The outline of shape code [shape] in [r]: 3 a capsule, 4 a hexagon, 5 a
/// parallelogram, 10 a circle, else a rectangle.
Path netPlanShape(int shape, Rect r) {
  switch (shape) {
    case 3:
      return Path()
        ..addRRect(RRect.fromRectAndRadius(r, Radius.circular(r.height / 2)));
    case 4:
      final k = math.min(r.height * 0.35, r.width / 4);
      return Path()
        ..moveTo(r.left + k, r.top)
        ..lineTo(r.right - k, r.top)
        ..lineTo(r.right, r.center.dy)
        ..lineTo(r.right - k, r.bottom)
        ..lineTo(r.left + k, r.bottom)
        ..lineTo(r.left, r.center.dy)
        ..close();
    case 5:
      final k = math.min(r.height * 0.4, r.width / 4);
      return Path()
        ..moveTo(r.left + k, r.top)
        ..lineTo(r.right, r.top)
        ..lineTo(r.right - k, r.bottom)
        ..lineTo(r.left, r.bottom)
        ..close();
    case 10:
      final d = math.min(r.width, r.height);
      return Path()..addOval(Rect.fromCenter(center: r.center, width: d, height: d));
    default:
      return Path()..addRect(r);
  }
}

/// Whether [g] is drawn by [SapNetPlanView]: a control-hosted graph whose
/// stream sent the formats of all its nodes (an inline GRAPH item, and a
/// stream without formats, stay on the generic graph view).
bool netPlanHasLook(SapNetPlanModel g) =>
    g.shell != null &&
    g.nodes.isNotEmpty &&
    g.nodes.every((n) => g.decor.formats.containsKey(n.format));
