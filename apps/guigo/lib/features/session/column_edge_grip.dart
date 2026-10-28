import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A column's right edge in a header row — a classic table control's
/// heading, a column tree's hierarchy / item header: the header separator
/// line, centred in a finger-wide grip whose horizontal drag resizes the
/// column, as SAP GUI's header edge does ([onDrag]: the points moved since
/// the last step; [onDragEnd] when the finger lifts). The drag itself
/// sends nothing. A column tree's resize stays wire-silent
/// (a recorded session step 8, a recorded session g[33]:
/// no `HierarchyHeaderWidth` / `ABAPColWidthTab` report); a classic table
/// control's rides the NEXT round's 16/9/14 (a recorded session
/// resize g[27]; DynproView.onTableColumnWidths).
///
/// Inside a sideways scroll view the grip's drag wins over the scroll: its
/// recognizer is deeper in the hit path, so it claims the arena first.
class ColumnEdgeGrip extends StatefulWidget {
  const ColumnEdgeGrip({
    super.key,
    required this.color,
    required this.onDrag,
    this.onDragEnd,
  });

  /// The separator's colour at rest.
  final Color color;

  final ValueChanged<double> onDrag;

  /// The finger lifted (or the drag was cancelled).
  final VoidCallback? onDragEnd;

  /// The grip's width in points: a finger's, around a 1-point line.
  static const double width = 12;

  @override
  State<ColumnEdgeGrip> createState() => _ColumnEdgeGripState();
}

class _ColumnEdgeGripState extends State<ColumnEdgeGrip> {
  bool _active = false;

  void _set(bool on) {
    if (_active != on) setState(() => _active = on);
  }

  @override
  Widget build(BuildContext context) {
    final color = _active
        ? Theme.of(context).colorScheme.primary
        : widget.color;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: (_) => _set(true),
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) {
          _set(false);
          widget.onDragEnd?.call();
        },
        onHorizontalDragCancel: () {
          _set(false);
          widget.onDragEnd?.call();
        },
        child: Center(
          child: SizedBox(
            width: _active ? 2 : 1,
            height: double.infinity,
            child: ColoredBox(color: color),
          ),
        ),
      ),
    );
  }
}
