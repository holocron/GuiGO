import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A node of a network graph / designer canvas, in the control's own
/// coordinates ([x], [y], [w], [h]) when the server placed it, else on a
/// layout grid ([col], [row]); with neither, the view lays it out by level.
class GraphNode {
  const GraphNode({
    required this.id,
    this.label = '',
    this.type = '',
    this.x,
    this.y,
    this.w,
    this.h,
    this.col,
    this.row,
    this.fill,
    this.border,
  });
  final String id;
  final String label;
  final String type;
  final double? x, y, w, h;
  final int? col, row;

  /// The server's own colours (a NetPlan highlight set); null = tint by
  /// [type].
  final Color? fill, border;
}

class GraphEdge {
  const GraphEdge(this.from, this.to, {this.label = ''});
  final String from;
  final String to;
  final String label;
}

/// A JNet colour name (`BLUE_3`, `BROWN_1`, `DARKGREEN`, `GRAY_1`, …) as a
/// colour: the base hue, lighter as the shade number grows. Null when the
/// name is unknown.
Color? jnetColor(String? name) {
  if (name == null) return null;
  final m = RegExp(r'^(DARK|LIGHT)?([A-Z]+?)(?:_(\d+))?$')
      .firstMatch(name.trim().toUpperCase());
  if (m == null) return null;
  const base = {
    'BLUE': 0xFF2F6DB5,
    'RED': 0xFFC0392B,
    'GREEN': 0xFF2E8B57,
    'YELLOW': 0xFFE1B12C,
    'ORANGE': 0xFFE67E22,
    'BROWN': 0xFF8B5A2B,
    'GRAY': 0xFF7F8C8D,
    'GREY': 0xFF7F8C8D,
    'BLACK': 0xFF222222,
    'WHITE': 0xFFF5F5F5,
    'CYAN': 0xFF17A2B8,
    'MAGENTA': 0xFFB03A8C,
    'PINK': 0xFFE88AA9,
    'PURPLE': 0xFF7D3C98,
    'VIOLET': 0xFF7D3C98,
  };
  final b = base[m.group(2)];
  if (b == null) return null;
  var hsl = HSLColor.fromColor(Color(b));
  final shade = int.tryParse(m.group(3) ?? '') ?? 0;
  var l = hsl.lightness + shade * 0.08;
  if (m.group(1) == 'DARK') l -= 0.15;
  if (m.group(1) == 'LIGHT') l += 0.2;
  hsl = hsl.withLightness(l.clamp(0.08, 0.92));
  return hsl.toColor();
}

/// What a tree row carries when it is dragged (long-press) onto a canvas:
/// the source control and the row's node key. Drag it with
/// `dragAnchorStrategy: pointerDragAnchorStrategy` — the drop point the
/// canvas reports is the feedback's origin, which is then the finger.
class TreeRowDrag {
  const TreeRowDrag({
    required this.shell,
    required this.nodeKey,
    this.label = '',
  });
  final String shell;
  final String nodeKey;
  final String label;
}

/// A network graph (NetPlan / JNet: STMS transport routes, workflow
/// definitions) or a designer canvas (BW network planner, join designer):
/// boxes and arrows on a pan-and-zoom surface.
///
/// Gestures, each reported only when its callback is set:
/// * tap a node → it is selected (outlined), [onTapNode];
/// * double-tap a node → [onDoubleTapNode] with the point (control
/// coordinates);
/// * drag a node → it moves; released → [onMoveNode] with its new
/// position in the control's coordinates;
/// * with no [onMoveNode], drag from a node [canLinkFrom] accepts onto
/// another → [onConnect] (a rubber-band line follows the finger) —
/// the canvas pans from everywhere else;
/// * long-press a node and drag onto another → [onConnect] too;
/// * drop a dragged tree row ([TreeRowDrag]) on the surface →
/// [onExternalDrop] with the drop point (control coordinates) and the
/// node under it, if any.
class SapGraphView extends StatefulWidget {
  const SapGraphView({
    super.key,
    required this.nodes,
    required this.edges,
    this.title = '',
    this.busy = false,
    this.onTapNode,
    this.onDoubleTapNode,
    this.onMoveNode,
    this.canLinkFrom,
    this.onConnect,
    this.onExternalDrop,
    this.onContextMenu,
  });

  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
  final String title;
  final bool busy;
  final void Function(GraphNode n)? onTapNode;

  /// A double tap on a node, with the point in the control's coordinates.
  final void Function(GraphNode n, Offset at)? onDoubleTapNode;
  final void Function(GraphNode n, Offset to)? onMoveNode;

  /// Which nodes a plain drag draws a link from (with [onConnect] and no
  /// [onMoveNode]); null = every node.
  final bool Function(GraphNode n)? canLinkFrom;
  final void Function(GraphNode from, GraphNode to)? onConnect;
  final void Function(TreeRowDrag drag, Offset at, GraphNode? onto)?
  onExternalDrop;

  /// The control's context menu on a node (a secondary click, or a long
  /// press released on the node itself — dragging on instead draws a link).
  final void Function(GraphNode n, Offset at)? onContextMenu;

  @override
  State<SapGraphView> createState() => _SapGraphViewState();
}

/// The placed box of every node (control coordinates): the server's own
/// geometry, else the layout grid, else a level layout (roots left, each
/// edge one column to the right, siblings stacked).
Map<String, Rect> layoutGraph(List<GraphNode> nodes, List<GraphEdge> edges) {
  const w = 150.0, h = 52.0, gapX = 70.0, gapY = 28.0;
  final out = <String, Rect>{};
  final placed = nodes.where((n) => n.x != null && n.y != null);
  for (final n in placed) {
    out[n.id] = Rect.fromLTWH(n.x!, n.y!, n.w ?? w, n.h ?? h);
  }
  final gridded = nodes.where(
    (n) => !out.containsKey(n.id) && n.col != null && n.row != null,
  );
  if (gridded.isNotEmpty) {
    // grid units: compact the used columns/rows to consecutive slots
    final cols = gridded.map((n) => n.col!).toSet().toList()..sort();
    final rows = gridded.map((n) => n.row!).toSet().toList()..sort();
    for (final n in gridded) {
      out[n.id] = Rect.fromLTWH(
        cols.indexOf(n.col!) * (w + gapX),
        rows.indexOf(n.row!) * (h + gapY),
        w,
        h,
      );
    }
  }
  final rest = nodes.where((n) => !out.containsKey(n.id)).toList();
  if (rest.isEmpty) return out;
  // level layout for the rest: longest path from a root (cycle-safe)
  final ids = rest.map((n) => n.id).toSet();
  final level = <String, int>{for (final id in ids) id: 0};
  for (var pass = 0; pass < ids.length; pass++) {
    var changed = false;
    for (final e in edges) {
      if (!ids.contains(e.from) || !ids.contains(e.to) || e.from == e.to) {
        continue;
      }
      final want = level[e.from]! + 1;
      if (want > level[e.to]! && want < ids.length) {
        level[e.to] = want;
        changed = true;
      }
    }
    if (!changed) break;
  }
  final x0 = out.isEmpty
      ? 0.0
      : out.values.map((r) => r.right).reduce(math.max) + gapX;
  final perLevel = <int, int>{};
  for (final n in rest) {
    final l = level[n.id]!;
    final i = perLevel[l] = (perLevel[l] ?? -1) + 1;
    out[n.id] = Rect.fromLTWH(x0 + l * (w + gapX), i * (h + gapY), w, h);
  }
  return out;
}

/// The inputs [layoutGraph] reads, flattened: two equal keys lay out
/// alike, so a rebuild with the same graph (every server turn rebuilds the
/// screen, with freshly built node lists) reuses the layout.
List<Object?> _layoutKey(List<GraphNode> nodes, List<GraphEdge> edges) => [
  nodes.length,
  for (final n in nodes) ...[n.id, n.x, n.y, n.w, n.h, n.col, n.row],
  edges.length,
  for (final e in edges) ...[e.from, e.to],
];

bool _sameKey(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _SapGraphViewState extends State<SapGraphView> {
  final _tc = TransformationController();
  final _surface = GlobalKey();
  Map<String, Rect> _boxes = {};

  /// The graph [_boxes] were laid out for: identical lists skip even the
  /// key; equal inputs skip the layout (O(V x E) + O(n^2)).
  List<GraphNode>? _laidNodes;
  List<GraphEdge>? _laidEdges;
  List<Object?> _laidKey = const [];

  Map<String, Rect> _layout() {
    final nodes = widget.nodes, edges = widget.edges;
    if (identical(nodes, _laidNodes) && identical(edges, _laidEdges)) {
      return _boxes;
    }
    final key = _layoutKey(nodes, edges);
    _laidNodes = nodes;
    _laidEdges = edges;
    if (_laidKey.isNotEmpty && _sameKey(key, _laidKey)) return _boxes;
    _laidKey = key;
    return layoutGraph(nodes, edges);
  }
  final Map<String, Offset> _moved = {}; // local drags not yet repainted
  String? _dragging, _linkFrom, _selected;
  Offset? _linkEnd;
  String? _hoverDrop;
  String? _fitted; // the graph the view was last fitted to

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  Rect _box(String id) {
    final b = _boxes[id]!;
    final m = _moved[id];
    return m == null ? b : Rect.fromLTWH(m.dx, m.dy, b.width, b.height);
  }

  GraphNode? _nodeAt(Offset p) {
    for (final n in widget.nodes.reversed) {
      if (_boxes.containsKey(n.id) && _box(n.id).contains(p)) return n;
    }
    return null;
  }

  /// A global pointer position in surface (control) coordinates.
  Offset _toSurface(Offset global) {
    final rb = _surface.currentContext?.findRenderObject() as RenderBox?;
    return rb == null ? global : rb.globalToLocal(global);
  }

  @override
  void didUpdateWidget(SapGraphView old) {
    super.didUpdateWidget(old);
    // a server repaint places the nodes itself
    if (!identical(old.nodes, widget.nodes)) _moved.clear();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    _boxes = _layout();
    if (_boxes.isEmpty) {
      return const Center(child: Text('(empty graph)'));
    }
    var extent = Rect.zero;
    for (final id in _boxes.keys) {
      extent = extent.expandToInclude(_box(id));
    }
    final size = Size(extent.right + 80, extent.bottom + 80);
    final types = widget.nodes.map((n) => n.type).toSet().toList()..sort();
    Color tint(String type) {
      const hues = [210.0, 140.0, 30.0, 280.0, 0.0, 180.0, 60.0, 320.0];
      final i = types.indexOf(type);
      return HSLColor.fromAHSL(
        1,
        hues[(i < 0 ? 0 : i) % hues.length],
        0.45,
        Theme.of(context).brightness == Brightness.dark ? 0.32 : 0.82,
      ).toColor();
    }

    // a plain drag from a node draws a link when nodes do not move
    bool linkDrag(GraphNode n) =>
        widget.onConnect != null &&
        widget.onMoveNode == null &&
        (widget.canLinkFrom?.call(n) ?? true);
    // the link gesture ends at [at] (surface coordinates): onto another
    // node → onConnect; released on the node itself (a long press) → its
    // context menu
    void endLink(
      GraphNode from,
      Offset? at, {
      required bool contextMenu,
      Offset? global,
    }) {
      final target = at == null ? null : _nodeAt(at);
      setState(() {
        _linkFrom = null;
        _linkEnd = null;
      });
      if (target != null && target.id != from.id) {
        widget.onConnect!(from, target);
      } else if (contextMenu && target?.id == from.id && global != null) {
        widget.onContextMenu?.call(from, global);
      }
    }

    final nodes = <Widget>[
      for (final n in widget.nodes)
        if (_boxes.containsKey(n.id))
          Positioned.fromRect(
            rect: _box(n.id),
            child: _NodeBox(
              key: ValueKey('graph-node-${n.id}'),
              node: n,
              color: n.fill ?? tint(n.type),
              selected:
                  _dragging == n.id ||
                  _linkFrom == n.id ||
                  _hoverDrop == n.id ||
                  _selected == n.id,
              onTap:
                  (widget.onTapNode == null &&
                          widget.onDoubleTapNode == null) ||
                      widget.busy
                  ? null
                  : () {
                      setState(() => _selected = n.id);
                      widget.onTapNode?.call(n);
                    },
              onDoubleTap: widget.onDoubleTapNode == null || widget.busy
                  ? null
                  : (global) {
                      setState(() => _selected = n.id);
                      widget.onDoubleTapNode!(n, _toSurface(global));
                    },
              onPanStart: widget.busy
                  ? null
                  : widget.onMoveNode != null
                  ? (_) => setState(() => _dragging = n.id)
                  : linkDrag(n)
                  ? (d) => setState(() {
                      _linkFrom = n.id;
                      _linkEnd = _toSurface(d.globalPosition);
                    })
                  : null,
              onPanUpdate: widget.busy
                  ? null
                  : widget.onMoveNode != null
                  ? (d) => setState(() {
                      final b = _box(n.id);
                      _moved[n.id] = b.topLeft + d.delta;
                    })
                  : linkDrag(n)
                  ? (d) =>
                        setState(() => _linkEnd = _toSurface(d.globalPosition))
                  : null,
              onPanEnd: widget.busy
                  ? null
                  : widget.onMoveNode != null
                  ? (_) {
                      final to = _box(n.id).topLeft;
                      setState(() => _dragging = null);
                      widget.onMoveNode!(n, to);
                    }
                  : linkDrag(n)
                  ? (_) => endLink(n, _linkEnd, contextMenu: false)
                  : null,
              onPanCancel: widget.onMoveNode == null && linkDrag(n)
                  ? () => setState(() {
                      _linkFrom = null;
                      _linkEnd = null;
                    })
                  : null,
              onSecondaryTapUp: widget.onContextMenu == null || widget.busy
                  ? null
                  : (d) => widget.onContextMenu!(n, d.globalPosition),
              onLongPressStart: widget.onConnect == null || widget.busy
                  ? null
                  : (d) => setState(() {
                      _linkFrom = n.id;
                      _linkEnd = _toSurface(d.globalPosition);
                    }),
              onLongPressMove: widget.onConnect == null || widget.busy
                  ? null
                  : (d) =>
                        setState(() => _linkEnd = _toSurface(d.globalPosition)),
              onLongPressEnd: widget.onConnect == null || widget.busy
                  ? null
                  : (d) => endLink(
                      n,
                      _toSurface(d.globalPosition),
                      contextMenu: true,
                      global: d.globalPosition,
                    ),
            ),
          ),
    ];

    Widget surface = SizedBox.fromSize(
      key: _surface,
      size: size,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _EdgePainter(
                edges: widget.edges,
                box: (id) => _boxes.containsKey(id) ? _box(id) : null,
                color: scheme.onSurfaceVariant,
                rubberFrom: _linkFrom == null ? null : _box(_linkFrom!).center,
                rubberTo: _linkEnd,
                accent: scheme.primary,
              ),
            ),
          ),
          ...nodes,
        ],
      ),
    );

    if (widget.onExternalDrop != null) {
      // the builder must capture the plain surface, not the variable it
      // is about to be reassigned through (that builds itself forever)
      final plain = surface;
      surface = DragTarget<TreeRowDrag>(
        onWillAcceptWithDetails: (_) => !widget.busy,
        onMove: (d) {
          final n = _nodeAt(_toSurface(d.offset));
          if (n?.id != _hoverDrop) setState(() => _hoverDrop = n?.id);
        },
        onLeave: (_) => setState(() => _hoverDrop = null),
        onAcceptWithDetails: (d) {
          final at = _toSurface(d.offset);
          setState(() => _hoverDrop = null);
          widget.onExternalDrop!(d.data, at, _nodeAt(at));
        },
        builder: (context, candidates, _) => DecoratedBox(
          decoration: BoxDecoration(
            border: candidates.isEmpty
                ? null
                : Border.all(color: scheme.primary, width: 2),
          ),
          child: plain,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.title.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(6),
            child: Text(
              widget.title.trim(),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, cons) {
              // first show of a graph: scale it down to fit the view
              const margin = 24.0;
              final key =
                  '${widget.nodes.length}:${widget.edges.length}:${widget.title}';
              if (_fitted != key &&
                  cons.maxWidth.isFinite &&
                  cons.maxHeight.isFinite) {
                _fitted = key;
                final fit = math.min(
                  1.0,
                  math.min(
                    cons.maxWidth / (size.width + 2 * margin),
                    cons.maxHeight / (size.height + 2 * margin),
                  ),
                );
                _tc.value = Matrix4.identity()..scaleByDouble(fit, fit, 1, 1);
              }
              return ClipRect(
                child: InteractiveViewer(
                  transformationController: _tc,
                  constrained: false,
                  boundaryMargin: const EdgeInsets.all(400),
                  minScale: 0.2,
                  maxScale: 3,
                  // node drags and link gestures own the pointer while active
                  panEnabled: _dragging == null && _linkFrom == null,
                  child: Padding(
                    padding: const EdgeInsets.all(margin),
                    child: surface,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A node's drag: accepted after the TOUCH slop (18 pt), not the pan slop
/// (36 pt) a plain [PanGestureRecognizer] waits for. The canvas sits in
/// zoomable / scrollable parents — the graph's own and the composed
/// window's InteractiveViewer (scale recognizers, accepting after the pan
/// slop) and the window's SingleChildScrollView (a vertical drag, after
/// the touch slop): with the pan slop a vertical drag from a node went to
/// the scroll view. At the touch slop the node, deepest in the hit path
/// and so first to see each move, claims the drag before any of them.
class _NodeDragRecognizer extends PanGestureRecognizer {
  _NodeDragRecognizer({super.debugOwner});

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      globalDistanceMoved.abs() >
      computeHitSlop(pointerDeviceKind, gestureSettings);
}

class _NodeBox extends StatelessWidget {
  const _NodeBox({
    super.key,
    required this.node,
    required this.color,
    required this.selected,
    this.onTap,
    this.onDoubleTap,
    this.onPanStart,
    this.onPanUpdate,
    this.onPanEnd,
    this.onPanCancel,
    this.onSecondaryTapUp,
    this.onLongPressStart,
    this.onLongPressMove,
    this.onLongPressEnd,
  });

  final GraphNode node;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  /// A double tap, with the global point of its second touch.
  final void Function(Offset global)? onDoubleTap;
  final GestureDragStartCallback? onPanStart;
  final GestureDragUpdateCallback? onPanUpdate;
  final GestureDragEndCallback? onPanEnd;
  final GestureDragCancelCallback? onPanCancel;
  final GestureTapUpCallback? onSecondaryTapUp;
  final GestureLongPressStartCallback? onLongPressStart;
  final GestureLongPressMoveUpdateCallback? onLongPressMove;
  final GestureLongPressEndCallback? onLongPressEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = node.label.trim().isEmpty ? node.id : node.label.trim();
    final gestures = <Type, GestureRecognizerFactory>{
      if (onTap != null || onSecondaryTapUp != null)
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(debugOwner: this),
              (r) => r
                ..onTap = onTap
                ..onSecondaryTapUp = onSecondaryTapUp,
            ),
      if (onDoubleTap != null)
        DoubleTapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
              () => DoubleTapGestureRecognizer(debugOwner: this),
              (r) {
                Offset? at;
                r
                  ..onDoubleTapDown = ((d) => at = d.globalPosition)
                  ..onDoubleTap = (() => onDoubleTap!(at ?? Offset.zero));
              },
            ),
      if (onPanStart != null || onPanUpdate != null || onPanEnd != null)
        _NodeDragRecognizer:
            GestureRecognizerFactoryWithHandlers<_NodeDragRecognizer>(
              () => _NodeDragRecognizer(debugOwner: this),
              (r) => r
                // the node follows the finger from where it touched down:
                // with the default (start after the slop) the slop's
                // distance is lost
                ..dragStartBehavior = DragStartBehavior.down
                ..onStart = onPanStart
                ..onUpdate = onPanUpdate
                ..onEnd = onPanEnd
                ..onCancel = onPanCancel,
            ),
      if (onLongPressStart != null ||
          onLongPressMove != null ||
          onLongPressEnd != null)
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(debugOwner: this),
              (r) => r
                ..onLongPressStart = onLongPressStart
                ..onLongPressMoveUpdate = onLongPressMove
                ..onLongPressEnd = onLongPressEnd,
            ),
    };
    return RawGestureDetector(
      gestures: gestures,
      // no Tooltip: its long-press would take the connect gesture
      child: Semantics(
        label: [label, if (node.type.isNotEmpty) node.type, node.id].join(', '),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? scheme.primary
                  : (node.border ?? scheme.outline),
              width: selected ? 2.5 : 1,
            ),
            boxShadow: const [
              BoxShadow(
                blurRadius: 3,
                color: Colors.black26,
                offset: Offset(0, 1),
              ),
            ],
          ),
          // a canvas table's caption heads its box (its rows sit below)
          alignment: node.type == 'table'
              ? Alignment.topCenter
              : Alignment.center,
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: color.computeLuminance() > 0.45
                  ? Colors.black87
                  : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _EdgePainter extends CustomPainter {
  _EdgePainter({
    required this.edges,
    required this.box,
    required this.color,
    required this.accent,
    this.rubberFrom,
    this.rubberTo,
  });

  final List<GraphEdge> edges;
  final Rect? Function(String id) box;
  final Color color, accent;
  final Offset? rubberFrom, rubberTo;

  /// Where the segment from [r]'s centre towards [to] leaves [r]'s border.
  static Offset _exit(Rect r, Offset to) {
    final c = r.center;
    final d = to - c;
    if (d == Offset.zero) return c;
    final sx = d.dx == 0 ? double.infinity : (r.width / 2) / d.dx.abs();
    final sy = d.dy == 0 ? double.infinity : (r.height / 2) / d.dy.abs();
    return c + d * math.min(sx, sy);
  }

  void _arrow(Canvas c, Offset a, Offset b, Paint p) {
    c.drawLine(a, b, p);
    final dir = (b - a);
    if (dir.distance < 1) return;
    final u = dir / dir.distance;
    final n = Offset(-u.dy, u.dx);
    final head = Path()
      ..moveTo(b.dx, b.dy)
      ..lineTo((b - u * 10 + n * 5).dx, (b - u * 10 + n * 5).dy)
      ..lineTo((b - u * 10 - n * 5).dx, (b - u * 10 - n * 5).dy)
      ..close();
    c.drawPath(head, Paint()..color = p.color);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    for (final e in edges) {
      final a = box(e.from), b = box(e.to);
      if (a == null || b == null || e.from == e.to) continue;
      final from = _exit(a, b.center), to = _exit(b, a.center);
      _arrow(canvas, from, to, p);
      if (e.label.trim().isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: e.label.trim(),
            style: TextStyle(color: color, fontSize: 11),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 140);
        final mid = (from + to) / 2;
        tp.paint(canvas, mid - Offset(tp.width / 2, tp.height + 2));
      }
    }
    if (rubberFrom != null && rubberTo != null) {
      _arrow(
        canvas,
        rubberFrom!,
        rubberTo!,
        Paint()
          ..color = accent
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) => true;
}
