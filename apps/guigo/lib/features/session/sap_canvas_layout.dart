import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

import 'sap_graph_view.dart';

/// A designer canvas (BW network planner, SQVI join designer) as graph
/// boxes: each table a box with a header, its rows stacked inside it as
/// their own nodes — the rows are what links join and what a drop lands
/// on. A table the server placed (non-zero geometry) keeps its place;
/// the rest go left to right. Row boxes come after their table so they
/// paint, and hit-test, on top; each names its table as its parent, so a
/// table moved on the view takes its rows (and their links) along.
(List<GraphNode>, List<GraphEdge>) canvasGraph(SapCanvasModel c,
    {Color? tableFill}) {
  const tableW = 250.0, header = 34.0, rowH = 28.0, gap = 60.0;
  final tables = c.nodes.where((n) => n.type == 'table').toList();
  final rowsOf = <String, List<CanvasNode>>{};
  for (final n in c.nodes.where((n) => n.type != 'table')) {
    rowsOf.putIfAbsent(n.parent ?? '', () => []).add(n);
  }
  final out = <GraphNode>[];
  var nextX = 0.0;
  for (final t in tables) {
    final placed = (t.x ?? 0) != 0 || (t.y ?? 0) != 0;
    final rows = rowsOf[t.id] ?? const [];
    final w = (t.w ?? 0) > 0 ? t.w! : tableW;
    final h = math.max(header + rows.length * rowH + 6, (t.h ?? 0));
    final x = placed ? t.x! : nextX;
    final y = placed ? t.y! : 0.0;
    nextX = math.max(nextX, x + w + gap);
    out.add(GraphNode(
      id: t.id,
      label: t.label,
      type: 'table',
      x: x,
      y: y,
      w: w,
      h: h,
      fill: tableFill,
    ));
    for (final (i, r) in rows.indexed) {
      out.add(GraphNode(
        id: r.id,
        label: r.label,
        type: 'row',
        x: x + 4,
        y: y + header + i * rowH,
        w: w - 8,
        h: rowH - 3,
        parent: t.id, // a row moves with its table
      ));
    }
  }
  // rows whose table the canvas does not carry: a column of their own
  final orphans = [
    for (final e in rowsOf.entries)
      if (!tables.any((t) => t.id == e.key)) ...e.value,
  ];
  for (final (i, r) in orphans.indexed) {
    out.add(GraphNode(
        id: r.id, label: r.label, type: 'row', x: nextX, y: i * rowH, w: tableW, h: rowH - 3));
  }
  return (out, [for (final l in c.links) GraphEdge(l.from, l.to)]);
}
