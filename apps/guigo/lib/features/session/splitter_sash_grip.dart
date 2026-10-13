import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// The grip of a FREE splitter sash inside a dynpro custom-control area
/// ([SapSession.splitterSashes]: the cells of one CFW splitter drawn as
/// overlays on the dynpro canvas — the error management screen's 2 x 2,
/// the Easy Access menu beside its picture). A thin rule along the sash, a
/// pill handle at its middle, a finger-wide hit area ([hitPoints], at least
/// 24 pt) across it. Dragging moves the sash by whole cells, each cell
/// beside it kept at least [minCells]: [onMoved] gets the splitter's new
/// extents ([SplitterSash.movedBy]) at every cell step — the session holds
/// them and the regions re-lay out ([SapSession.noteSplitterSash]); the
/// drag itself sends nothing (the real GUI's next round carries the
/// resized cells' sizes).
class SplitterSashGrip extends StatefulWidget {
  const SplitterSashGrip({
    super.key,
    required this.sash,
    required this.cell,
    required this.onMoved,
    this.minCells = 2,
  });

  final SplitterSash sash;

  /// Points per character column x per row of the canvas.
  final Size cell;

  final void Function(List<int> extents) onMoved;
  final int minCells;

  /// The grip's hit area across the sash, in points.
  /// The canvas points of the hit area: a composed window may draw the
  /// dynpro's canvas scaled down to its pane (the Easy Access: 0.85), so
  /// 32 canvas points keep at least [minHitPoints] on the screen.
  static const double hitPoints = 32;

  /// The least on-screen hit area across a sash (Apple's 24 pt minimum
  /// for a secondary target).
  static const double minHitPoints = 24;

  /// The overlay rect (dynpro cells) of [sash]'s line, [origin] = the
  /// dynpro's top-left in window cells: a zero-width (column) / zero-height
  /// (row) rect the canvas grows to [hitPoints] across
  /// ([DynproOverlay.minPoints]).
  static Rect cellsOf(SplitterSash sash, Offset origin) {
    final l = sash.line;
    return Rect.fromLTWH(
      l.col - origin.dx,
      l.row - origin.dy,
      sash.rows ? l.cols : 0,
      sash.rows ? 0 : l.rows,
    );
  }

  @override
  State<SplitterSashGrip> createState() => _SplitterSashGripState();
}

class _SplitterSashGripState extends State<SplitterSashGrip> {
  double _drag = 0;
  int _applied = 0;
  SplitterSash? _start;
  bool _active = false;

  void _begin() {
    _start = widget.sash;
    _drag = 0;
    _applied = 0;
    setState(() => _active = true);
  }

  void _update(double d) {
    final s = _start ?? widget.sash;
    _drag += d;
    final per = s.rows ? widget.cell.height : widget.cell.width;
    final cells = per <= 0 ? 0 : (_drag / per).round();
    if (cells == _applied) return;
    _applied = cells;
    widget.onMoved(s.movedBy(cells, minCells: widget.minCells));
  }

  void _end() {
    _start = null;
    setState(() => _active = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = widget.sash.rows;
    final color = _active ? scheme.primary : scheme.outline;
    final rule = Container(
      width: rows ? double.infinity : (_active ? 2 : 1),
      height: rows ? (_active ? 2 : 1) : double.infinity,
      color: color.withValues(alpha: _active ? 0.9 : 0.6),
    );
    final pill = Container(
      width: rows ? 28 : 6,
      height: rows ? 6 : 28,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
    return MouseRegion(
      cursor: rows
          ? SystemMouseCursors.resizeRow
          : SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onVerticalDragStart: rows ? (_) => _begin() : null,
        onVerticalDragUpdate: rows ? (d) => _update(d.delta.dy) : null,
        onVerticalDragEnd: rows ? (_) => _end() : null,
        onVerticalDragCancel: rows ? _end : null,
        onHorizontalDragStart: rows ? null : (_) => _begin(),
        onHorizontalDragUpdate: rows ? null : (d) => _update(d.delta.dx),
        onHorizontalDragEnd: rows ? null : (_) => _end(),
        onHorizontalDragCancel: rows ? null : _end,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(child: rule),
            pill,
          ],
        ),
      ),
    );
  }
}
