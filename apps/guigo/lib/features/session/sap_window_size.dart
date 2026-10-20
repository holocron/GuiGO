import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/widgets.dart';

import 'screen_composer.dart';

/// The SAP window GuiGo reports for a session body of [body] points — the
/// region below the command row and above the status / key bar — in
/// character cells, (rows, cols).
///
/// The server lays the window-size-dependent elements out for it (a
/// custom-control area with resizing — SE38's editor —, docking panes, table
/// controls and step loops) and GuiGo draws those composed windows with the
/// [ScreenComposer]'s cell: [ScreenComposer.cellAspect] times as tall as
/// wide, the window scaled to the body width. So:
///
/// * COLUMNS from a cell of [cellWidth] points — the dynpro renderer's own
/// legible minimum (dynpro_view's 7 pt) and SAP GUI's 7 px character
/// cell: iPad portrait (820 pt) -> 117 cols, landscape (1180 pt) -> 168;
/// an 80-col dynpro fits either way at >= 10 pt a cell, a 132-col one
/// fits landscape and stays legible portrait (the dynpro view fits its
/// own painted width, independent of the window). Clamped to
/// [minCols]..[maxCols] (a narrow split view keeps 80: SAP's standard
/// width; a dynpro never exceeds 255).
/// * ROWS so the composer's cell (body width / cols, times the aspect)
/// fills the body height: the server's resizable areas then end at the
/// bottom of the body instead of a fixed share of it. Floored at the
/// session's own [SapSession.minWindowRows], no higher: a phone held
/// sideways holds ~18 rows at the width-fitting cell, and a 20-row floor
/// had the composer (which fits the WHOLE window to the body) shrink the
/// cell to 5.5 pt and the Easy Access window to 78 % of the width (live
/// 2026-10-19). The kernel honours small windows: at 18 x 124 the Easy
/// Access tree and picture filled the body edge to edge (live), and at
/// 13 x 81 — a 4-inch phone sideways — the reference client's oracle had
/// SE38 paint its editor container r1c0 12x81, the rows asked, not more.
///
/// The cell ASPECT stays the renderer's 2:1, not the kernel's 22:7 (~3.14).
/// The kernel never sees GuiGo's points: the session reports the window
/// in the pixels of the KERNEL's 22 x 7 cell for exactly these rows x cols
/// (ActionContext.sizeWindow: rows x 22 + 17, cols x 7 + 4 px —
/// a recorded session: 853 x 1880 px -> 38 x 268), so the server
/// lays out the rows GuiGo draws, whatever height GuiGo gives a row. Rows
/// at 22:7 would only drop a third of them (an iPad portrait body: 45
/// instead of 71) and leave the dynpro's 2:1 rows (dynpro_view, the
/// composer) a third of the body short — or stretch every row to 3.14x
/// its width, far looser than SAP GUI's own text spacing.
(int, int) sapWindowCells(
  Size body, {
  double cellWidth = 7.0,
  int minCols = 80,
  int maxCols = 255,
  int minRows = SapSession.minWindowRows,
  int maxRows = 200,
}) {
  if (!body.width.isFinite ||
      !body.height.isFinite ||
      body.width <= 0 ||
      body.height <= 0) {
    return (40, 146); // nothing to measure: the reference window
  }
  final cols = (body.width / cellWidth).floor().clamp(minCols, maxCols);
  final cw = body.width / cols;
  final rows = (body.height / (cw * ScreenComposer.cellAspect)).floor().clamp(
    minRows,
    maxRows,
  );
  return (rows, cols);
}
