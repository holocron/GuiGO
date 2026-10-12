import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One part of a composed SAP window: the dynpro, a docked tree, the
/// message grid, … at its window cells (row/col units of the dynpro grid).
class ComposedPane {
  const ComposedPane({
    required this.cells,
    required this.builder,
    this.main = false,
  });

  /// left = col, top = row, width = cols, height = rows (window cells).
  final Rect cells;

  /// Builds the pane for the window's cell size (points per character
  /// column x per row), so a dynpro inside lines up with its neighbours.
  final Widget Function(BuildContext context, Size cell) builder;

  /// The window's own dynpro (drawn without a pane border).
  final bool main;
}

/// A SAP window composed of several panes — docking containers, splitter
/// cells and the dynpro between them — drawn the way the reference client's
/// screenshot draws it: every pane at its window cells, a cell twice as
/// tall as wide (diag_render CELL_W 9 x CELL_H 18). The window is scaled
/// to the available width; below [minCellW] points per cell it keeps that
/// size and pans / pinch-zooms like a screenshot instead.
class ScreenComposer extends StatefulWidget {
  const ScreenComposer({
    super.key,
    required this.panes,
    this.minCellW = 6.0,
    this.window,
    this.resizeKey,
    this.resizable = true,
    this.fixedSashes = const [],
    this.fillHeight = false,
  });

  final List<ComposedPane> panes;
  final double minCellW;

  /// The SAP window's own size in cells (columns x rows, the SES window
  /// the server paints into). The scale fits THIS, not the panes the
  /// current screen happens to carry: the window keeps its zoom while the
  /// user moves between screens (ST04's tree picks swap the detail panes).
  final Size? window;

  /// The dividers between panes can be dragged, like SAP GUI's splitter
  /// sashes and docking-container edges. The sizes are the client's own
  /// (nothing goes to the server: no capture shows what the real GUI
  /// reports after a drag) and hold while [resizeKey] (the transaction)
  /// stays the same.
  final bool resizable;
  final Object? resizeKey;

  /// The dividers the program fixed (SetRowSash / SetColumnSash movable or
  /// visible false), as zero-width lines in window cells: a divider on one
  /// of them does not move.
  final List<Rect> fixedSashes;

  /// The window FILLS the height of the view: when it fits by its width
  /// and its rows at [cellAspect] leave room below, the rows grow (up to
  /// [maxFillStretch] times the aspect) so the window ends at the bottom —
  /// the session's own window, whose size GuiGo reported to the server from
  /// this very view (sap_window_size.dart): a resizable custom-control area
  /// (SE38's editor) the server laid out to the last row is drawn down to
  /// the bottom edge, not at a fixed share of the height.
  final bool fillHeight;

  /// The most a [fillHeight] window stretches its rows (a window the server
  /// laid out for a shorter view keeps legible text spacing).
  static const double maxFillStretch = 1.6;

  /// The cell aspect of the reference client's renderer (CELL_H / CELL_W).
  static const double cellAspect = 2.0;

  /// The window extent the panes span, in cells.
  static Size extentOf(List<ComposedPane> panes) {
    var cols = 0.0, rows = 0.0;
    for (final p in panes) {
      cols = math.max(cols, p.cells.right);
      rows = math.max(rows, p.cells.bottom);
    }
    return Size(cols, rows);
  }

  @override
  State<ScreenComposer> createState() => _ScreenComposerState();
}

/// A divider between panes: a vertical one at column [at] (panes ending
/// there on its left, panes starting there on its right) or a horizontal
/// one at row [at], spanning [from]..[to] along its length.
class PaneSash {
  PaneSash(this.vertical, this.at, this.from, this.to, this.before, this.after);
  final bool vertical;
  final double at;
  final double from, to;

  /// Indexes of the panes ending at / starting at the divider.
  final List<int> before, after;

  String get key => '${vertical ? 'v' : 'h'}:${at.toStringAsFixed(2)}';
}

const double _eps = 0.01;

/// The dividers of a pane layout: every edge where one pane ends and a
/// neighbour that overlaps it along the edge begins.
List<PaneSash> paneSashes(List<Rect> rects) {
  final out = <PaneSash>[];
  for (final vertical in [true, false]) {
    final edges = <double>{
      for (final r in rects) vertical ? r.right : r.bottom,
    };
    for (final at in edges) {
      final before = <int>[], after = <int>[];
      for (var i = 0; i < rects.length; i++) {
        final r = rects[i];
        if (((vertical ? r.right : r.bottom) - at).abs() < _eps) before.add(i);
        if (((vertical ? r.left : r.top) - at).abs() < _eps) after.add(i);
      }
      if (before.isEmpty || after.isEmpty) continue;
      // the stretch where both sides touch
      double lo = double.infinity, hi = -double.infinity;
      for (final b in before) {
        for (final a in after) {
          final rb = rects[b], ra = rects[a];
          final s = math.max(
            vertical ? rb.top : rb.left,
            vertical ? ra.top : ra.left,
          );
          final e = math.min(
            vertical ? rb.bottom : rb.right,
            vertical ? ra.bottom : ra.right,
          );
          if (e - s > _eps) {
            lo = math.min(lo, s);
            hi = math.max(hi, e);
          }
        }
      }
      if (hi > lo) out.add(PaneSash(vertical, at, lo, hi, before, after));
    }
  }
  return out;
}

/// Whether divider [sh] lies on the fixed line [line] (a zero-height rect
/// for a row sash, zero-width for a column sash), within half a cell.
bool sashOnLine(PaneSash sh, Rect line) {
  final vertical = line.width.abs() < _eps && line.height > 0;
  if (vertical != sh.vertical) return false;
  final at = vertical ? line.left : line.top;
  if ((at - sh.at).abs() > 0.5) return false;
  final lo = vertical ? line.top : line.left;
  final hi = vertical ? line.bottom : line.right;
  return math.min(hi, sh.to) - math.max(lo, sh.from) > _eps;
}

/// The least a pane keeps when a divider squeezes it, in cells.
const double _minPaneCells = 3;

/// [rects] with each divider moved by its offset (cells), clamped so no
/// pane on either side shrinks below [_minPaneCells].
List<Rect> applySashes(
  List<Rect> rects,
  List<PaneSash> sashes,
  Map<String, double> offsets,
) {
  final out = List.of(rects);
  for (final sh in sashes) {
    var d = offsets[sh.key] ?? 0;
    if (d == 0) continue;
    double size(Rect r) => sh.vertical ? r.width : r.height;
    final room = [for (final b in sh.before) size(out[b]) - _minPaneCells]
        .fold<double>(double.infinity, math.min);
    final roomAfter = [for (final a in sh.after) size(out[a]) - _minPaneCells]
        .fold<double>(double.infinity, math.min);
    d = d.clamp(-math.max(0, room), math.max(0, roomAfter)).toDouble();
    for (final b in sh.before) {
      final r = out[b];
      out[b] = sh.vertical
          ? Rect.fromLTWH(r.left, r.top, r.width + d, r.height)
          : Rect.fromLTWH(r.left, r.top, r.width, r.height + d);
    }
    for (final a in sh.after) {
      final r = out[a];
      out[a] = sh.vertical
          ? Rect.fromLTWH(r.left + d, r.top, r.width - d, r.height)
          : Rect.fromLTWH(r.left, r.top + d, r.width, r.height - d);
    }
  }
  return out;
}

class _ScreenComposerState extends State<ScreenComposer> {
  /// Divider offsets (cells) by [PaneSash.key], for the current resizeKey.
  final Map<String, double> _offsets = {};
  String? _dragging;

  /// The panes' built contents for [_builtFor] at [_builtCell]: a divider
  /// drag (a setState per pointer move) moves and resizes the panes but
  /// hands them the same content widgets, so no pane rebuilds — only the
  /// layout follows the finger.
  List<ComposedPane>? _builtFor;
  Size? _builtCell;
  ThemeData? _builtTheme;
  List<Widget> _built = const [];

  /// How many times the panes' builders ran (tests read it).
  @visibleForTesting
  int paneBuilds = 0;

  List<Widget> _paneContents(BuildContext context, Size cell) {
    final panes = widget.panes;
    final theme = Theme.of(context);
    if (!identical(panes, _builtFor) ||
        cell != _builtCell ||
        !identical(theme, _builtTheme)) {
      _builtFor = panes;
      _builtCell = cell;
      _builtTheme = theme;
      paneBuilds++;
      _built = [for (final p in panes) p.builder(context, cell)];
    }
    return _built;
  }

  @override
  void didUpdateWidget(ScreenComposer old) {
    super.didUpdateWidget(old);
    if (old.resizeKey != widget.resizeKey) _offsets.clear();
  }

  @override
  Widget build(BuildContext context) {
    final panes = widget.panes;
    if (panes.isEmpty) return const SizedBox.shrink();
    final minCellW = widget.minCellW;
    final spanned = ScreenComposer.extentOf(panes);
    final w = widget.window;
    final extent = w == null || w.width <= 0 || w.height <= 0
        ? spanned
        : Size(
            math.max(w.width, spanned.width),
            math.max(w.height, spanned.height),
          );
    final base = [for (final p in panes) p.cells];
    final sashes = widget.resizable
        ? [
            for (final sh in paneSashes(base))
              if (!widget.fixedSashes.any((l) => sashOnLine(sh, l))) sh,
          ]
        : const <PaneSash>[];
    final rects = applySashes(base, sashes, _offsets);
    return LayoutBuilder(
      builder: (context, cons) {
        // the whole window on the screen, like SAP GUI's: the cell fits the
        // width AND the height (a tall splitter window — /IWFND/MAINT_SERVICE's
        // catalog over its two detail grids — must not push its bottom panes
        // below the fold)
        var fitted = extent.width <= 0
            ? minCellW
            : cons.maxWidth / extent.width;
        if (cons.maxHeight.isFinite && extent.height > 0) {
          fitted = math.min(
            fitted,
            cons.maxHeight / (extent.height * ScreenComposer.cellAspect),
          );
        }
        final cw = math.max(fitted, minCellW);
        var ch = cw * ScreenComposer.cellAspect;
        if (widget.fillHeight &&
            fitted >= minCellW &&
            cons.maxHeight.isFinite &&
            extent.height > 0) {
          final tall = cons.maxHeight / extent.height;
          if (tall > ch) {
            ch = math.min(tall, ch * ScreenComposer.maxFillStretch);
          }
        }
        final cell = Size(cw, ch);
        final scheme = Theme.of(context).colorScheme;
        final contents = _paneContents(context, cell);
        final window = SizedBox(
          width: extent.width * cw,
          height: extent.height * ch,
          child: Stack(
            children: [
              for (var i = 0; i < panes.length; i++)
                Positioned(
                  left: rects[i].left * cw,
                  top: rects[i].top * ch,
                  width: rects[i].width * cw,
                  height: rects[i].height * ch,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: panes[i].main
                          ? null
                          : Border.all(
                              color: scheme.outlineVariant,
                              width: 0.5,
                            ),
                    ),
                    child: contents[i],
                  ),
                ),
              for (final sh in sashes) _sashHandle(sh, rects, cw, ch, scheme),
            ],
          ),
        );
        if (fitted >= minCellW) {
          return SingleChildScrollView(
            physics: _dragging != null
                ? const NeverScrollableScrollPhysics()
                : null,
            child: window,
          );
        }
        // too wide to read at the window's width: the whole window drawn at
        // the minimum cell, opened scaled to fit the width — every pane in
        // its true proportion, like the reference client's screenshot — and pinch-zoom
        // for detail
        return _FittedWindow(
          window: window,
          fit: fitted / cw,
          frozen: _dragging != null,
        );
      },
    );
  }

  /// The grab strip over a divider (wider than the line, for a finger).
  /// Raw pointer events, not a gesture recognizer: the zoomable window
  /// around it must not win the drag; it is frozen while one runs.
  Widget _sashHandle(
    PaneSash sh,
    List<Rect> rects,
    double cw,
    double ch,
    ColorScheme scheme,
  ) {
    const grab = 28.0; // a finger's width: the divider is easy to take
    final at = sh.vertical
        ? rects[sh.before.first].right * cw
        : rects[sh.before.first].bottom * ch;
    final from = sh.from * (sh.vertical ? ch : cw);
    final len = (sh.to - sh.from) * (sh.vertical ? ch : cw);
    final active = _dragging == sh.key;
    // always visible (SAP GUI's sash), a grip in its middle; bold while
    // dragged
    final line = Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: sh.vertical ? (active ? 3 : 2) : null,
          height: sh.vertical ? null : (active ? 3 : 2),
          color: active ? scheme.primary : scheme.outlineVariant,
        ),
        Container(
          width: sh.vertical ? 6 : 36,
          height: sh.vertical ? 36 : 6,
          decoration: BoxDecoration(
            color: active ? scheme.primary : scheme.outline,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ],
    );
    return Positioned(
      left: sh.vertical ? at - grab / 2 : from,
      top: sh.vertical ? from : at - grab / 2,
      width: sh.vertical ? grab : len,
      height: sh.vertical ? len : grab,
      child: MouseRegion(
        cursor: sh.vertical
            ? SystemMouseCursors.resizeColumn
            : SystemMouseCursors.resizeRow,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => setState(() => _dragging = sh.key),
          onPointerMove: (e) {
            if (_dragging != sh.key) return;
            setState(() {
              final d = sh.vertical
                  ? e.localDelta.dx / cw
                  : e.localDelta.dy / ch;
              _offsets[sh.key] = (_offsets[sh.key] ?? 0) + d;
            });
          },
          onPointerUp: (_) => setState(() => _dragging = null),
          onPointerCancel: (_) => setState(() => _dragging = null),
          child: Semantics(
            label: sh.vertical ? 'Column divider' : 'Row divider',
            child: Center(child: line),
          ),
        ),
      ),
    );
  }
}

/// An image control the screen uses as a gauge (DB50's memory / disk
/// bars): a filled bar and its value text.
class SapGauge extends StatelessWidget {
  const SapGauge({super.key, required this.fraction, this.text = ''});

  final double fraction;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final f = fraction.clamp(0.0, 1.0);
    final color = f >= 0.9
        ? scheme.error
        : (f >= 0.75 ? Colors.orange : scheme.primary);
    return Tooltip(
      message: text.isNotEmpty ? text : '${(f * 100).round()} %',
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outline, width: 0.8),
          color: scheme.surfaceContainerLowest,
        ),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: f,
          child: Container(color: color),
        ),
      ),
    );
  }
}

/// A window wider than the view: opened at [fit] (the view width over the
/// window width), zoomable from there up to legible detail.
class _FittedWindow extends StatefulWidget {
  const _FittedWindow({
    required this.window,
    required this.fit,
    this.frozen = false,
  });
  final Widget window;
  final double fit;

  /// A divider drag runs: no pan / zoom meanwhile.
  final bool frozen;

  @override
  State<_FittedWindow> createState() => _FittedWindowState();
}

class _FittedWindowState extends State<_FittedWindow> {
  final _tc = TransformationController();
  double? _fittedTo;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_fittedTo != widget.fit) {
      // a new window size (rotation, another screen): fit it again
      _fittedTo = widget.fit;
      _tc.value = Matrix4.identity()
        ..scaleByDouble(widget.fit, widget.fit, 1, 1);
    }
    return InteractiveViewer(
      transformationController: _tc,
      constrained: false,
      panEnabled: !widget.frozen,
      scaleEnabled: !widget.frozen,
      minScale: math.min(widget.fit, 1.0),
      maxScale: 4,
      boundaryMargin: EdgeInsets.zero,
      child: widget.window,
    );
  }
}
