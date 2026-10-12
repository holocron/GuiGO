import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart';

/// The SAP GUI geometry of a dynpro paint: every field sits on the painted
/// character grid at its (row, col) cell, as wide as its painted length —
/// the reference client screenshot's layout (: CELL_W 9 × CELL_H 18,
/// `_field_cells`, `_tab_bar_layout`). Pure, so the widget and the tests
/// share it.
class DynproGrid {
  DynproGrid._(this.cells, this.cols, this.rows, this.firstRow);

  /// The placed cells, in paint order (frames are not cells).
  final List<GridCell> cells;

  /// The painted extent in character columns / dynpro rows (from row 0).
  final int cols;
  final int rows;

  /// The first painted row (rows above it are blank and can be skipped).
  final int firstRow;

  bool get isEmpty => cells.isEmpty;

  static DynproGrid of(ScreenModel m) {
    final shown = m.fields.where(_painted).toList();

    // a tabstrip's tab buttons form a horizontal TAB BAR from the row's
    // first tab, each as wide as its caption box (len + 2) — whatever
    // 1-column step the dynpro painted the tab atoms at (_tab_bar_layout)
    final tabCol = <ScreenField, int>{};
    final tabRows = <String, List<ScreenField>>{};
    for (final f in shown.where((f) => f.kind == FieldKind.tabstrip)) {
      tabRows.putIfAbsent('${f.area}:${f.block}:${f.row}', () => []).add(f);
    }
    for (final tabs in tabRows.values) {
      tabs.sort((a, b) => a.col.compareTo(b.col));
      var at = tabs.first.col;
      for (final t in tabs) {
        tabCol[t] = at;
        at += _ownCells(t);
      }
    }

    final placed = <GridCell>[
      for (final f in shown)
        GridCell(f, f.row, tabCol[f] ?? f.col, _ownCells(f)),
    ];

    // a text cell may run up to the next cell of its row; an input never
    // overlaps its right neighbour (a 1-character field keeps 2 cells of
    // touch target only when there is room)
    final byRow = <int, List<GridCell>>{};
    for (final c in placed) {
      byRow.putIfAbsent(c.row, () => []).add(c);
    }
    for (final line in byRow.values) {
      line.sort((a, b) => a.col.compareTo(b.col));
      for (var i = 0; i < line.length; i++) {
        final c = line[i];
        final next = i + 1 < line.length ? line[i + 1].col : null;
        final room = next == null ? null : next - c.col;
        if (_isText(c.field) && !_iconOnly(c.field)) {
          // labels pad to the next cell (the reference client's grey label box); an
          // icon output is its glyph alone (the debugger's TOOL_BAR
          // `@UP\QFermer l'outil@` at col 81 padded 84 cells over the
          // call stack beside it, a recorded session s[27])
          c.width = room == null ? c.width : math.max(c.width, room - 1);
        } else if (c.field.kind == FieldKind.input ||
            c.field.kind == FieldKind.combobox) {
          if (c.width < 2 && (room == null || room > 2)) c.width = 2;
        }
        if (room != null && room > 0) c.width = math.min(c.width, room);
      }
    }

    var cols = 0, rows = 0, first = 1 << 30;
    for (final c in placed) {
      // a table control's cells past its right edge scroll inside the
      // control (TC_1211 paints 35 columns to col 292 in a 157-wide box):
      // the control's box is its extent, never its column catalog
      if (c.field.tableControl == null) cols = math.max(cols, c.col + c.width);
      rows = math.max(rows, c.row + 1);
      first = math.min(first, c.row);
    }
    for (final tc in m.tableControls) {
      cols = math.max(cols, tc.col + tc.width);
      rows = math.max(rows, tc.row + tc.height);
      first = math.min(first, tc.row);
    }
    for (final fr in m.frames) {
      cols = math.max(cols, fr.col + fr.dcols);
      rows = math.max(rows, fr.row + fr.drows);
      first = math.min(first, fr.row);
    }
    return DynproGrid._(placed, cols, rows, first == 1 << 30 ? 0 : first);
  }
}

/// One field on the grid: its cell and its width in cells.
class GridCell {
  GridCell(this.field, this.row, this.col, this.width);
  final ScreenField field;
  final int row;
  final int col;
  int width;
}

bool _isText(ScreenField f) =>
    f.kind == FieldKind.output || f.kind == FieldKind.label;

/// Painted cells only: blank text padding (SE16's VALU_PUSH cell under its
/// button, a popup's SCR_TITL) draws nothing, nor does a cell painted
/// INVISIBLE (attr 0x02) that is no input — on an input the bit only
/// masks the typed text (the password); ME21N's TEXTFLAG column button
/// rides every line invisible until the item has a text.
bool _painted(ScreenField f) =>
    !(_isText(f) && f.text.trim().isEmpty) &&
    !(f.invisible && f.kind != FieldKind.input && f.kind != FieldKind.combobox);

final _iconToken = RegExp(r'@[0-9A-Z]{1,2}(?:\\Q[^@]*)?@');

/// A text that is one icon token and nothing else (blank padding aside).
bool _iconOnly(ScreenField f) {
  final t = f.text.trim();
  final m = _iconToken.matchAsPrefix(t);
  return m != null && m.end == t.length;
}

/// A field's own painted width in cells (the reference client's `_field_cells`).
int _ownCells(ScreenField f) {
  final plain = f.text.replaceAll(_iconToken, '').trimRight();
  final hasIcon = _iconToken.hasMatch(f.text);
  // the painted text with each `@xx\Q…@` icon token as the glyph it draws
  // (two cells): the quick info is the tooltip, never drawn — the ABAP
  // Debugger's TOOL_BAR fields (`@UM\QMaximiser horizontal.@`, mlen 2,
  // a recorded session s[27]) are 2-cell icon buttons in the reference client
  // render; measured raw they ran 27 cells over the call stack beside them
  final shown = f.text.replaceAll(_iconToken, '##').trimRight().length;
  switch (f.kind) {
    case FieldKind.input:
    case FieldKind.combobox:
      final n = f.mlen > 0 && f.maxnrchars > 0
          ? math.min(f.mlen, f.maxnrchars)
          : (f.mlen > 0 ? f.mlen : f.maxnrchars);
      // a combobox painted without a length (DB50/0219's metric choice)
      // still needs room for its entries
      final floor = f.kind == FieldKind.combobox && n == 0 ? 20 : 1;
      return math.max(math.max(n, shown), floor);
    case FieldKind.output:
    case FieldKind.label:
      return math.max(shown, 1);
    case FieldKind.pushbutton:
      if (plain.trim().isEmpty) return 3; // icon-only button
      return plain.trim().length + (hasIcon ? 4 : 2);
    case FieldKind.tabstrip:
      return plain.trim().length + 2;
    case FieldKind.checkbox:
    case FieldKind.radio:
      // the caption without its event id (ScreenField.label)
      final cap = f.label.trim().isNotEmpty ? f.label.trim() : plain.trim();
      return 2 + cap.length;
  }
}
