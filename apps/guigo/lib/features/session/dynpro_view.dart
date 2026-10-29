import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/gestures.dart'
    show kDoubleTapSlop, kDoubleTapTimeout, kTouchSlop;
import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
        HardwareKeyboard,
        KeyDownEvent,
        KeyUpEvent,
        LogicalKeyboardKey,
        TextInputFormatter;

import '../../core/sap_icons.dart';
import 'column_edge_grip.dart';
import 'dynpro_grid.dart';
import 'dynpro_listbox_view.dart';
import 'sap_list_pager.dart';
import 'sap_list_view.dart';
import 'screen_composer.dart' show ScreenComposer;
import 'session_busy.dart';
import 'type_ahead.dart';

/// The grid renderer's character cell bounds (points): below the minimum
/// the screen reflows by rows instead; above the maximum it stops growing.
const double _minCellW = 7.0;

const double _maxCellW = 12.0;

/// The point size a composed window's dynpro pane's cell WIDTH never holds
/// its text under ([dynproLegibleCell]; the row height, the server's
/// layout, still bounds it at 0.78 x row): the 12 points of GuiGo's own ALV grid cells and
/// headings (sap_grid_view.dart) — Apple's caption size, below which the
/// iPad's text stops reading at arm's length. The composer's window cell
/// alone gave SE80's class builder 9.8 points (117 columns in an 820-point
/// portrait window, a 7-point cell: font = 1.4 x cell) beside the
/// repository tree's 13.
const double dynproMinFont = 12.0;

/// The share of a dynpro pushbutton's face height its icon fills (SAP
/// GUI's 16-pixel icon in its ~20-pixel button).
const double dynproButtonGlyphShare = 0.8;

/// The least em a dynpro pushbutton's icon is drawn at, in points: the
/// bundled icon font draws its icons in ~77 % of the em (ICON_SEARCH 75 x 77
/// of 100), so 20 points draw a 15-point icon — the size the iPad needs to
/// tell SAP's icons apart (SE80's docked class builder drew them at 9).
const double dynproButtonIconEm = 20;

/// The stroke a dynpro pushbutton's icon glyph is thickened by, as a share
/// of its em: the icon font's hairlines plus 0.05 em (1 point at 20) on
/// each side — SAP GUI's bitmaps are 1-pixel lines on a 16-pixel icon, a
/// 1/16 line weight the font draws at a third of that.
const double dynproGlyphStroke = 0.05;

/// A disabled dynpro element's foreground: the on-surface colour at 70 %
/// over the surface — greyed like SAP GUI's inactive icons and labels, yet
/// at least 4.5 : 1 against the surface in both themes (Material's 38 %
/// left the class builder's icons unreadable on dark grey).
Color dynproDisabledForeground(ColorScheme scheme) =>
    Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.7), scheme.surface);

/// The composer's window [cell] (DynproView.cell) widened so a composed
/// pane's text (DynproView's grid: min(1.4 x width, 0.78 x height)) is not
/// held under [dynproMinFont] by the cell's WIDTH. Only the width: the
/// rows are the window rows GuiGo reported to the server, which laid the
/// dynpro out for exactly them (SAPLSEOD/2000's methods table ends on the
/// window's last row) — taller rows ran the tab strip and the table's
/// header off the pane's top. SE80's class builder at 7 x 15.2 points is
/// drawn at 8.57 x 15.2: 11.9-point text (the row's bound) instead of 9.8,
/// its columns scrolling sideways in the pane.
Size dynproLegibleCell(Size cell) =>
    Size(math.max(cell.width, dynproMinFont / 1.4), cell.height);

/// The widest painted grid (columns) seen per program, for one logon: the
/// cell size of a transaction stays put while its screens change. The
/// session screen provides one per session (the main window's: a popup is
/// its own window and fits its own width); a DynproView outside any scope
/// keeps its own.
class DynproZoomScope extends InheritedWidget {
  const DynproZoomScope({
    super.key,
    required this.widest,
    this.columnWidths,
    required super.child,
  });

  /// program -> the widest grid (columns) painted for it.
  final Map<String, int> widest;

  /// The session's table-control column widths the user dragged
  /// ([tcColumnKey] -> column index -> width in cells): kept for the
  /// session, per control, as SAP GUI keeps them while the logon lives.
  /// Client-only — no wire item carries a classic table control's resized
  /// column (no recording holds one; the Windows 16/9/14 echo is the
  /// painted header's 60-byte prefix alone, a recorded session
  /// gui[7]). Null: the view keeps its own.
  final Map<String, Map<int, double>>? columnWidths;

  static Map<String, int>? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DynproZoomScope>()?.widest;

  static Map<String, Map<int, double>>? columnWidthsOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DynproZoomScope>()?.columnWidths;

  @override
  bool updateShouldNotify(DynproZoomScope old) =>
      !identical(old.widest, widest) ||
      !identical(old.columnWidths, columnWidths);
}

/// The key a table control's dragged column widths are kept under
/// ([DynproZoomScope.columnWidths]): its program, dynpro and name.
String tcColumnKey(ScreenModel m, TableControlInfo tc) =>
    '${m.program}:${m.dynpro}:${tc.name}';

/// A paint's derived layouts, computed once per model: every server turn
/// rebuilds the session screen, and an unchanged paint (the same model) must
/// not be classified / gridded again. Keyed weakly on the model; the field
/// count guards a model mutated after it was first laid out (tests build
/// models in place).
class _Derived {
  _Derived(
    this.fieldCount,
    this.layout,
    this.grid,
    this.radioGroups,
    this.nextInput,
  );
  final int fieldCount;
  final DynproLayout layout;
  final DynproGrid grid;
  final Map<String, List<ScreenField>> radioGroups;

  /// The soft keyboard's Next: each typeable input's successor in reading
  /// order (row, then column — a table control's line left to right,
  /// fixed then moving columns, then its next line), null for the last;
  /// a protected input (an icon output among them) is no stop. Keyed by
  /// cell ([_cellKey], the inputs' own key).
  final Map<String, String?> nextInput;
}

/// An input's key in the view's state: its cell.
String _cellKey(ScreenField f) => '${f.area}:${f.row}:${f.col}';

final Expando<_Derived> _derived = Expando('dynpro layout');

/// How many times a paint was laid out (tests read it).
@visibleForTesting
int dynproLayoutCount = 0;

/// How many times a dynpro view was built (tests read it: a list-cursor
/// tap or a busy flip redraws its leaves, not the view).
@visibleForTesting
int dynproBuildCount = 0;

_Derived _derive(ScreenModel m) {
  final d = _derived[m];
  if (d != null && d.fieldCount == m.fields.length) return d;
  dynproLayoutCount++;
  // radio groups: the whole group decides the current member
  final radioGroups = <String, List<ScreenField>>{};
  for (final f in m.fields.where((f) => f.kind == FieldKind.radio)) {
    radioGroups.putIfAbsent('${f.area}:${f.block}:${f.group}', () => []).add(f);
  }
  for (final g in radioGroups.values) {
    g.sort(
      (a, b) =>
          a.row != b.row ? a.row.compareTo(b.row) : a.col.compareTo(b.col),
    );
  }
  // the inputs one can type into, in reading order: the paint lists them
  // in PAINT order (a subscreen's after the main dynpro's), so sorted
  final typeable = [
    for (final f in m.fields)
      if (f.kind == FieldKind.input && !f.isProtected) f,
  ]..sort(
    (a, b) => a.row != b.row
        ? a.row.compareTo(b.row)
        : a.col != b.col
        ? a.col.compareTo(b.col)
        : a.area.compareTo(b.area),
  );
  final nextInput = <String, String?>{
    for (var i = 0; i < typeable.length; i++)
      _cellKey(typeable[i]): i + 1 < typeable.length
          ? _cellKey(typeable[i + 1])
          : null,
  };
  return _derived[m] = _Derived(
    m.fields.length,
    layoutDynpro(m.fields),
    DynproGrid.of(m),
    radioGroups,
    nextInput,
  );
}

/// The width a dynpro paint wants on the SAP grid at a comfortable cell
/// size — a modal window sizes itself to its popup with it.
double dynproPreferredWidth(ScreenModel m) {
  final g = _derive(m).grid;
  // a classic list (an F4 hit list popup) wants its painted columns
  final list = sapListColumns(m.listPaint) * 8.0;
  return math.max(g.isEmpty ? 0 : g.cols * 10.0, list);
}

/// The generic mobile-reflow dynpro renderer.
///
/// Layout follows the paint's own geometry the way the reference client's screenshot
/// does: every dynpro row is laid out left to right in column order — the
/// caption cell (the nearest text cell to an input's left, the reference client's
/// `_pair_text_labels` rule), the inputs sized by their mlen, in-between
/// text ("à" between a LOW and a HIGH field), icon pushbuttons. Rows wrap on
/// a narrow screen instead of being torn into unrelated lists. Text cells
/// left of the input column that no input claims form the side text panel
/// (the logon screen's system notes). Radio groups are selectable through
/// [onRadio]. [compact] trims paddings for embedding in a modal window.
class DynproView extends StatefulWidget {
  const DynproView({
    super.key,
    required this.model,
    required this.busy,
    required this.onFill,
    required this.onPress,
    required this.onOkcode,
    this.onRadio,
    this.radioSelection,
    this.onRadioTap,
    this.compact = false,
    this.controls = const {},
    this.overlays = const [],
    this.cell,
    this.maxCols,
    this.windowCells,
    this.onEdit,
    this.onValueHelp,
    this.onListPick,
    this.onListCursor,
    this.onListCell,
    this.onListScroll,
    this.onFocusField,
    this.onContextMenu,
    this.onDoubleClick,
    this.listboxValueSet,
    this.onListboxPick,
    this.onCheckbox,
    this.onTableColumnWidths,
    this.onTablePage,
  });

  final ScreenModel model;
  final bool busy;
  final Future<void> Function(ScreenField f, String text) onFill;
  final Future<void> Function(int vkey) onPress;
  final Future<void> Function(String cmd) onOkcode;
  final Future<void> Function(List<ScreenField> group, ScreenField chosen)?
  onRadio;

  /// Local (no-PAI) radio selection: [radioSelection] is the currently
  /// chosen field, [onRadioTap] is invoked on tap — used by dialogs whose
  /// answer is composed elsewhere (the logon wall).
  final ScreenField? radioSelection;
  final void Function(List<ScreenField> group, ScreenField chosen)? onRadioTap;
  final bool compact;

  /// Controls hosted in the screen's custom containers (a chart, …), keyed
  /// by container name: drawn at the container's cells on the grid, or
  /// below the screen when the paint does not place that container.
  final Map<String, Widget> controls;

  /// The regions of a composed window that lie on this dynpro (its custom-
  /// control areas' bars, charts, grids in their splitter cells), at their
  /// own cells: part of the dynpro's canvas, so a sash drag, a resize or a
  /// scroll moves them with the text around them. Drawn only on the SAP
  /// grid of a fixed [cell].
  final List<DynproOverlay> overlays;

  /// A fixed character cell (points per column x per row) — set when the
  /// dynpro is one pane of a composed window, so its grid lines up with
  /// the panes around it; null = fit the grid to the width.
  final Size? cell;

  /// The pane's width in cells when the dynpro is one pane of a composed
  /// window ([cell] set): a table control is boxed to it, its columns past
  /// the pane scroll inside the box (SE80 sideways: a 98-column frame in
  /// an 84-column pane ran off the screen). Null: unbounded.
  final int? maxCols;

  /// The session's current SAP window (rows, cols) — the cells the kernel
  /// lays a window-following screen out for ([followsWindow]); null falls
  /// back to the paint's own SES dimensions.
  final (int, int)? windowCells;

  /// A field's text changed (not yet submitted): the session stages it,
  /// and it rides the next action — any key, button or okcode — the way
  /// SAP GUI sends every changed field with the PAI.
  final void Function(ScreenField f, String text)? onEdit;

  /// Value help (F4) on a field that has it ([ScreenField.hasF4]): on the
  /// SAP grid the small button inside the focused field, as SAP GUI shows
  /// it; on the phone reflow a button on every field that offers it (the
  /// matchcode button is the field's only touch route there).
  final Future<void> Function(ScreenField f)? onValueHelp;

  /// A dynpro checkbox ticked / unticked to [on]: the session stages the
  /// value, and it rides the next PAI the way SAP GUI sends a changed box
  /// (the box shows the tick at once). Null: a tap sends a bare Enter.
  final void Function(ScreenField f, bool on)? onCheckbox;

  /// The user let go of a table-control column edge: the control's column
  /// widths in characters (by column id), the dragged one rounded. The
  /// session reports them in the next round's 16/9/14 and the server
  /// mirrors them in its next paint (a recorded session g[27]
  /// -> s[37]: SapSession.noteTableColumnLayout). Null: the resize stays
  /// the view's own.
  final void Function(TableControlInfo tc, List<int> widths)?
  onTableColumnWidths;

  /// Page a table control: [vkey] 82 (Page Down) or 81 (Page Up) with the
  /// cursor in it — the SERVER pages and repaints the control's lines
  /// (a recorded session g[28] -> s[38];
  /// SapSession.pageTableControl). Its scroll bar's track and a vertical
  /// swipe over its lines fire it. Null: no paging.
  final void Function(TableControlInfo tc, int vkey)? onTablePage;

  /// An input took the keyboard focus: the field F1 asks help for.
  final void Function(ScreenField f)? onFocusField;

  /// SAP GUI's context menu (right click / long press): at [at] (global),
  /// on input [field] when the gesture hit one, else on the screen.
  final void Function(Offset at, ScreenField? field)? onContextMenu;

  /// A classic list line tapped (an F4 hit list, a report list, the
  /// classic F1 popup): the list's own pick (F2 on the line).
  final Future<void> Function(ListLine line)? onListPick;

  /// A tap on a classic list line placed the list cursor at (buffer row,
  /// column) — locally, the next list round carries it (no round of its
  /// own; a double-tap then [onListPick]s the line).
  final void Function(int row, int col)? onListCursor;

  /// A list input cell changed (a checkbox ticked: `X` / blank): the
  /// session stages it, and it rides the next list key round.
  final void Function(ListLine line, ListSegment cell, String text)?
  onListCell;

  /// The list is scrolled past the page the server painted (a classic list
  /// longer than its window, [ListPage.scrolls]): ask the server for the
  /// page starting at list line [firstLine] (0-based) — the session's
  /// `scrollList`, the real GUI's VSCROLL round ([SapPagedList]).
  final Future<void> Function(int firstLine)? onListScroll;

  /// SAP GUI's double-click on a field (an icon field too) or a
  /// table-control cell: the choose key (F2) with the cursor on it — the
  /// session's `doubleClick`. A label / text outside a table control takes
  /// no cursor and answers none. A single tap keeps its own meaning (an input takes the
  /// focus, a button fires its function code); a pushbutton has no
  /// double-click of its own (its first click fires it).
  final Future<void> Function(ScreenField f)? onDoubleClick;

  /// The entries of dropdown listbox [f] ([FieldKind.combobox]) the session
  /// holds (`SapSession.listboxValueSet`), null while none — the box then
  /// shows its bare key.
  final ValueSet? Function(ScreenField f)? listboxValueSet;

  /// An entry KEY picked in listbox [f] (`SapSession.pickListbox`); null =
  /// listboxes are display-only.
  final Future<void> Function(ScreenField f, String key)? onListboxPick;

  @override
  State<DynproView> createState() => _DynproViewState();
}

/// A control drawn on the dynpro's canvas at [cells] — dynpro cells: left
/// = column, top = row, width = columns, height = rows (from the dynpro's
/// origin, the composed window's AREASIZE area corner).
class DynproOverlay {
  const DynproOverlay(
    this.cells,
    this.child, {
    this.id,
    this.minPoints,
    this.builder,
  });
  final Rect cells;
  final Widget child;

  /// Keys the overlay's box on the canvas (`ValueKey('overlay-$id')`).
  final String? id;

  /// The box's least extent in points, grown about its centre (a sash
  /// grip's finger-wide hit area across a zero-width line); a zero-width or
  /// zero-height [cells] is drawn only with one.
  final Size? minPoints;

  /// Builds the child for the canvas' own cell (points per column x per
  /// row) — what a drag on it converts by; [child] without one.
  final Widget Function(Size cell)? builder;
}

// ---------------------------------------------------------------------------
// layout classification (pure, testable)
// ---------------------------------------------------------------------------

bool _isText(ScreenField f) =>
    f.kind == FieldKind.output || f.kind == FieldKind.label;

bool _isEditable(ScreenField f) =>
    f.kind == FieldKind.input || f.kind == FieldKind.combobox;

bool _isInteractive(ScreenField f) => !_isText(f);

/// One painted dynpro row: its cells in column order.
class DynproRow {
  DynproRow(this.area, this.block, this.row, this.cells);
  final int area;
  final int block;
  final int row;
  final List<ScreenField> cells;

  bool get hasInteractive => cells.any(_isInteractive);
}

/// The classified paint: captions, the side panel and the rows.
class DynproLayout {
  DynproLayout(this.captionOf, this.panel, this.rows)
    : captions = captionOf.values.toSet();

  /// Each captioned input's caption cell (rendered in place, styled as a
  /// label).
  final Map<ScreenField, ScreenField> captionOf;

  /// The text cells claimed as captions.
  final Set<ScreenField> captions;

  /// The side text panel, in reading order.
  final List<ScreenField> panel;

  /// The remaining cells, grouped per painted row.
  final List<DynproRow> rows;
}

/// Classify a paint the reference client's way.
///
/// Captions: on the same plane (area, block) and row, the nearest text cell
/// to an editable field's LEFT (blank padding cells skipped) carrying text is
/// its caption; any other cell in between (a radio, a checkbox, another
/// input) means the field has no caption of its own, so none is invented.
DynproLayout layoutDynpro(List<ScreenField> fields) {
  final byLine = <String, List<ScreenField>>{};
  for (final f in fields) {
    if (_isText(f) && f.text.trim().isEmpty) continue; // blank padding
    byLine.putIfAbsent('${f.area}:${f.block}:${f.row}', () => []).add(f);
  }
  for (final line in byLine.values) {
    line.sort((a, b) => a.col.compareTo(b.col));
  }

  final captionOf = <ScreenField, ScreenField>{};
  for (final line in byLine.values) {
    for (var i = 1; i < line.length; i++) {
      final f = line[i];
      if (!_isEditable(f)) continue;
      final left = line[i - 1];
      if (_isText(left)) captionOf[f] = left;
    }
  }
  final captions = captionOf.values.toSet();

  // the side text panel: text cells STARTING left of the input column
  // that no field claimed as its caption (their text may wrap past it)
  final inputs = fields.where(
    (f) =>
        _isEditable(f) ||
        f.kind == FieldKind.checkbox ||
        f.kind == FieldKind.radio,
  );
  final inputMinCol = inputs.isEmpty
      ? null
      : inputs.map((f) => f.col).reduce((a, b) => a < b ? a : b);
  final panel = <ScreenField>[];
  final rows = <DynproRow>[];
  final lines = byLine.values.toList()
    ..sort((a, b) {
      final x = a.first, y = b.first;
      final r = x.row.compareTo(y.row);
      if (r != 0) return r;
      final ar = x.area.compareTo(y.area);
      return ar != 0 ? ar : x.block.compareTo(y.block);
    });
  for (final line in lines) {
    final cells = <ScreenField>[];
    for (final f in line) {
      final toPanel =
          _isText(f) &&
          !captions.contains(f) &&
          inputMinCol != null &&
          f.col <= inputMinCol - 2;
      if (toPanel) {
        panel.add(f);
      } else {
        cells.add(f);
      }
    }
    if (cells.isNotEmpty) {
      final f = cells.first;
      rows.add(DynproRow(f.area, f.block, f.row, cells));
    }
  }
  panel.sort(
    (a, b) => a.row != b.row ? a.row.compareTo(b.row) : a.col.compareTo(b.col),
  );
  return DynproLayout(captionOf, panel, rows);
}

final RegExp _quickInfoRx = RegExp(r'@[0-9A-Z]{0,2}\\Q([^@]*)@');

/// The quick-info of an icon token (`@1F\QSélection multiple@` → "Sélection
/// multiple"; an icon-less `@\QSélection options de sélection@` too — the
/// empty option button of SAPLALDB/3000), or null when the text carries
/// none.
String? iconQuickInfo(String text) {
  if (!text.contains('@')) return null; // most fields carry no token
  final m = _quickInfoRx.firstMatch(text);
  return m?.group(1)?.trim();
}

// ---------------------------------------------------------------------------

/// The view's cursor state, one notifier: the cursor field's key (SAP GUI's
/// cursor field, kept when the keyboard goes), and the focused input's
/// type-ahead with its key. One value, because a focus gain changes both
/// together and a leaf must see the controller go before it is disposed.
typedef _Cursor = ({String? key, String? taKey, TypeAheadController? ta});

class _DynproViewState extends State<DynproView> {
  final Map<String, TextEditingController> _controllers = {};

  /// Each input's own focus node, keyed like [_controllers]: a repaint
  /// that adds or drops a field keeps the keyboard on the field with the
  /// same key, and a server round never touches it (an input is never
  /// disabled for busy — SAP GUI's hourglass keeps the cursor in its
  /// field).
  final Map<String, FocusNode> _focusNodes = {};

  /// Inputs typed into since the last paint of their field.
  final Set<String> _edited = {};

  /// The value the server last painted into each input.
  final Map<String, String> _painted = {};

  /// Show the painted value unless the user is typing over it; a value the
  /// server CHANGED (an F4 pick, a default, a check's correction) wins over
  /// the user's text — SAP GUI repaints the field with it.
  void _syncPainted(String key, TextEditingController ctrl, String painted) {
    final before = _painted[key];
    _painted[key] = painted;
    if (before != null && before != painted) _edited.remove(key);
    if (ctrl.text != painted && !_edited.contains(key)) {
      // the caret at the end: a field that keeps the focus across the
      // round is not left with an invalid selection
      ctrl.value = TextEditingValue(
        text: painted,
        selection: TextSelection.collapsed(offset: painted.length),
      );
    }
  }

  /// The cursor field and the focused input's type-ahead ([_Cursor]): a
  /// notifier, so a focus change redraws the field it left and the field
  /// it lands on ([_Select] leaves), not the whole view.
  final ValueNotifier<_Cursor> _cursorN =
      ValueNotifier((key: null, taKey: null, ta: null));

  String? get _focused => _cursorN.value.key;

  /// Input [key] took the focus: SAP GUI's cursor field until another
  /// field takes it or the screen changes.
  void _setCursor(String key) {
    final c = _cursorN.value;
    if (c.key != key) _cursorN.value = (key: key, taKey: c.taKey, ta: c.ta);
  }

  // --- type-ahead (type_ahead.dart): the focused input's dropdown -------

  /// The focused input's type-ahead (null: no [TypeAheadScope] above, or
  /// no input has the keyboard focus).
  TypeAheadController? get _ta => _cursorN.value.ta;

  /// Inputs the user typed into since their value was last kept in the
  /// input history (kept on Enter / leaving the field, as SAP GUI does).
  final Set<String> _typedSinceKept = {};

  /// The type-ahead of input [key] when it is the focused one.
  TypeAheadController? _typeAheadOf(String key) =>
      _cursorN.value.taKey == key ? _cursorN.value.ta : null;

  void _typeAheadFocus(String key, ScreenField f, bool has,
      TextEditingController ctrl) {
    if (!has) {
      if (_cursorN.value.taKey != key) return;
      _keepTyped();
      _dropTypeAhead();
      return;
    }
    final cfg = TypeAheadScope.read(context);
    if (cfg == null || _cursorN.value.taKey == key) return;
    // the next field may take the focus before the last one hears it lost
    _keepTyped();
    _dropTypeAhead();
    _cursorN.value = (
      key: _cursorN.value.key,
      taKey: key,
      ta: TypeAheadController(cfg, widget.model, f),
    );
  }

  /// SAP GUI keeps a typed value on leaving the field: the focused
  /// input's, when the user typed into it since it was last kept.
  void _keepTyped() {
    final ta = _ta, key = _cursorN.value.taKey;
    if (ta == null || key == null || !_typedSinceKept.remove(key)) return;
    final text = _controllers[key]?.text;
    if (text != null) ta.recordHistory(text);
  }

  void _typeAheadEdited(String key, TextEditingController ctrl) {
    _typedSinceKept.add(key);
    _typeAheadOf(key)?.userEdited(ctrl.value);
  }

  void _typeAheadSubmitted(String key, String value) {
    final ta = _typeAheadOf(key);
    if (ta == null) return;
    ta.close();
    if (_typedSinceKept.remove(key)) ta.recordHistory(value);
  }

  /// A proposal picked: written into the field the way typing writes it
  /// (the staged value rides the next round — the real GUI sends nothing
  /// for a pick, a recorded session).
  void _typeAheadPick(String key, ScreenField f, TextEditingController ctrl,
      TypeAheadProposal p) {
    var v = p.value;
    if (f.maxnrchars > 0 && v.length > f.maxnrchars) {
      v = v.substring(0, f.maxnrchars);
    }
    ctrl.value = TextEditingValue(
      text: v,
      selection: TextSelection.collapsed(offset: v.length),
    );
    _edited.add(key);
    _typedSinceKept.add(key);
    widget.onEdit?.call(f, v);
    _typeAheadOf(key)?.close();
  }

  void _dropTypeAhead() {
    final ta = _ta;
    if (ta == null) return;
    ta.focusLost();
    // the field's leaf lets go of it in this frame (the notifier marks it
    // to rebuild: from a focus callback the next frame's build, from
    // didUpdateWidget the build under way)
    _cursorN.value = (key: _cursorN.value.key, taKey: null, ta: null);
    WidgetsBinding.instance.addPostFrameCallback((_) => ta.dispose());
  }

  /// A server round started while an input kept the focus: SAP GUI keeps
  /// the typed value in the history on the PAI and the dropdown goes; the
  /// controller stays, so typing after the answer proposes again (the
  /// field never lost the focus).
  void _busyRose() {
    final ta = _ta;
    if (ta == null) return;
    _keepTyped();
    ta.close();
  }

  /// [field] (input [key]) under its type-ahead dropdown [ta] when a
  /// [TypeAheadScope] is above; the plain field otherwise.
  Widget _typeAheadAnchor(String key, ScreenField f,
      TextEditingController ctrl, TypeAheadController? ta, Widget field) {
    if (TypeAheadScope.maybeOf(context) == null) return field;
    ta?.rebind(widget.model, f);
    return TypeAheadAnchor(
      controller: ta,
      onPick: (p) => _typeAheadPick(key, f, ctrl, p),
      child: field,
    );
  }

  KeyEventResult _typeAheadKey(String key, ScreenField f,
          TextEditingController ctrl, KeyEvent e) =>
      TypeAheadAnchor.handleKey(
          _typeAheadOf(key), e, (p) => _typeAheadPick(key, f, ctrl, p));

  // --- the keyboard's action key, a hardware Return --------------------

  /// The field's Enter: its value sent with SAP GUI's Enter
  /// ([DynproView.onFill], the fill round) — the soft keyboard's Done on
  /// the last field (or a password's), a hardware Return in any field.
  /// Nothing while a round runs.
  Future<void> _submit(String key, ScreenField f, String value) async {
    if (_busyNow) return;
    _edited.remove(key);
    _typeAheadSubmitted(key, value);
    await widget.onFill(f, value);
  }

  /// The input after [key] for the Next key ([_Derived.nextInput]), null
  /// when [f] is the last one — or a password: its Return is the logon's
  /// Enter, not a jump to the language field.
  String? _nextOf(String key, ScreenField f) =>
      f.invisible ? null : _derive(widget.model).nextInput[key];

  /// The keyboard's action key of input [key]: Next between the fields,
  /// Done on the last ([_actionKey]).
  TextInputAction _actionOf(String key, ScreenField f) =>
      _nextOf(key, f) == null ? TextInputAction.done : TextInputAction.next;

  /// The soft keyboard's action key pressed in input [key]. Next moves the
  /// focus to the next typeable field in reading order with no round: the
  /// typed value is staged already ([DynproView.onEdit]) and rides the
  /// next action, as SAP GUI's Tab moves the cursor locally — the field
  /// stays marked typed ([_edited]), or the next repaint would put the
  /// painted value back ([_syncPainted]). Done is the Enter round
  /// ([_submit]). The round lives here, not in onSubmitted: EditableText
  /// calls onSubmitted after this for every action, Next included, so the
  /// fields leave it unset. The focus stays in its field on Done
  /// (Flutter's default unfocuses): SAP GUI's Enter keeps the cursor in
  /// its field.
  void _actionKey(String key, ScreenField f, TextEditingController ctrl) {
    ctrl.clearComposing();
    final next = _nextOf(key, f);
    if (next == null) {
      _submit(key, f, ctrl.text);
      return;
    }
    final node = _nodeOf(next);
    if (node.context != null) {
      node.requestFocus();
      return;
    }
    // the next cell is not built: a table control's column scrolled out
    // of the built window ([_TcColumns]) — the cursor key keeps it built,
    // so it takes the focus once the frame mounts it (and scrolls itself
    // into view); until then the cursor mark runs ahead of the focus
    _setCursor(next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && node.context != null) node.requestFocus();
    });
  }

  /// A hardware key in input [key]: the type-ahead's first (its dropdown's
  /// ↓ / ↑ / Esc / Enter), then a physical Return is SAP GUI's Enter
  /// whatever the soft keyboard's action label — iOS delivers it as the
  /// field's own action, and a Next would move the cursor instead of
  /// running the PAI (a Mac, an iPad keyboard: hardware_function_keys_test
  /// has the screen's own Return) — taken here so the field's action never
  /// sees it. A modified Return, and Tab (Flutter's traversal), are not
  /// taken.
  KeyEventResult _inputKey(
    String key,
    ScreenField f,
    TextEditingController ctrl,
    KeyEvent e,
  ) {
    final taken = _typeAheadKey(key, f, ctrl, e);
    if (taken != KeyEventResult.ignored || e is KeyUpEvent) return taken;
    final k = e.logicalKey;
    if (k != LogicalKeyboardKey.enter && k != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final hw = HardwareKeyboard.instance;
    if (hw.isShiftPressed ||
        hw.isControlPressed ||
        hw.isMetaPressed ||
        hw.isAltPressed) {
      return KeyEventResult.ignored;
    }
    // held down: one round, not one per repeat
    if (e is KeyDownEvent) {
      ctrl.clearComposing();
      _submit(key, f, ctrl.text);
    }
    return KeyEventResult.handled;
  }

  /// The list checkboxes ticked since the paint, by line (identity) and
  /// column — the paint's own value until the server repaints the list.
  final Map<ListLine, Map<int, bool>> _listTicks = Map.identity();

  /// The last tick (line, column, value): a notifier like [_listCursor] —
  /// a tick redraws its own line, not the whole view.
  final ValueNotifier<(ListLine, int, bool)?> _listTicked =
      ValueNotifier(null);

  /// The list cursor a tap placed since the paint (buffer row, column) —
  /// the paint's own ([ScreenModel.listCursor]) until then; a repaint of
  /// the list sets it again (the server's cursor). A notifier: a tap
  /// redraws the cursor's old and new lines, not the whole view.
  final ValueNotifier<(int, int)?> _listCursor = ValueNotifier(null);

  /// The zoom memory when no [DynproZoomScope] provides the session's.
  final Map<String, int> _ownWidest = {};

  /// The dragged column widths when no [DynproZoomScope] provides the
  /// session's.
  final Map<String, Map<int, double>> _ownTcWidths = {};

  /// The dynpro checkboxes ticked since the paint, by field (identity) —
  /// the paint's own value until the server repaints the box (the
  /// [_listTicks] pattern); [_boxTick] bumps so the box alone redraws.
  final Map<ScreenField, bool> _boxTicks = Map.identity();
  final ValueNotifier<int> _boxTick = ValueNotifier(0);

  /// A checkbox tapped: the session stages the tick ([DynproView.onCheckbox])
  /// and the box shows it; without a stager, today's bare Enter round.
  void _tickBox(ScreenField f) {
    final stage = widget.onCheckbox;
    if (stage == null) {
      widget.onPress(0);
      return;
    }
    final on = !(_boxTicks[f] ?? f.on);
    _boxTicks[f] = on;
    _boxTick.value++;
    stage(f, on);
  }

  /// Busy now — the view's own flag or the session's ([SessionBusy]) —
  /// for a gesture handler (no dependency: the view does not rebuild).
  bool get _busyNow => widget.busy || SessionBusy.peek(context);

  /// A control drawn from the busy state (a button, a choice, a listbox
  /// goes inert): it alone rebuilds when the session's busy flips, not the
  /// whole view ([BusyBuilder]). An input is never drawn busy: it keeps its
  /// look, its focus and the keyboard, as SAP GUI's hourglass keeps the
  /// cursor in its field — [_absorbing] blocks the taps.
  Widget _leaf(Widget Function(bool busy) build) =>
      BusyBuilder(busy: widget.busy, builder: (_, busy) => build(busy));

  /// [fields] (the dynpro's canvas or form, below the scroll views) with
  /// pointer input absorbed while busy — SAP GUI's locked window during a
  /// round trip. One leaf: a flip updates one AbsorbPointer, the identical
  /// child is skipped; the keyboard reaches the focused input still, and
  /// [_busyFormatter] refuses what it types.
  Widget _absorbing(Widget fields) => BusyBuilder(
    busy: widget.busy,
    builder: (_, busy) => AbsorbPointer(
      key: const ValueKey('dynpro-busy'),
      absorbing: busy,
      child: fields,
    ),
  );

  /// Typing during a round trip is refused (the field keeps the keyboard):
  /// a value typed then would sit in the field while the session's answer
  /// drops every staged value (`_dropStaged('the screen was repainted')`),
  /// and the screen would show what the server never got. No dependency:
  /// [_busyNow] peeks.
  late final TextInputFormatter _busyFormatter = TextInputFormatter
      .withFunction((old, next) => _busyNow ? old : next);

  /// The session's busy notifier this view listens to for the rising edge
  /// ([_busyRose]).
  ValueListenable<bool>? _busyScope;
  bool _wasBusy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = SessionBusy.listenableOf(context);
    if (identical(s, _busyScope)) return;
    _busyScope?.removeListener(_busyChanged);
    _busyScope = s?..addListener(_busyChanged);
    _wasBusy = _busyNow;
  }

  void _busyChanged() {
    final now = _busyNow;
    if (now && !_wasBusy) _busyRose();
    _wasBusy = now;
  }

  @override
  void didUpdateWidget(DynproView old) {
    super.didUpdateWidget(old);
    if (widget.busy != old.busy) _busyChanged();
    // a repainted list: the server's cursor again
    if (!identical(old.model.listPaint.firstOrNull,
        widget.model.listPaint.firstOrNull)) {
      _listCursor.value = null;
    }
    // a repainted list drops the ticks of the lines it no longer paints
    if (_listTicks.isNotEmpty) {
      final now = Set<ListLine>.identity()..addAll(widget.model.listPaint);
      _listTicks.removeWhere((l, _) => !now.contains(l));
    }
    final sameScreen = old.model.program == widget.model.program &&
        old.model.dynpro == widget.model.dynpro &&
        old.model.modalLevel == widget.model.modalLevel;
    if (!sameScreen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }
    // another screen: the cursor field was the old screen's
    if (!sameScreen && _focused != null) {
      _cursorN.value = (
        key: null,
        taKey: _cursorN.value.taKey,
        ta: _cursorN.value.ta,
      );
    }
    if (!identical(old.model, widget.model)) {
      // a turn that painted the dynpro dropped every staged value
      // (SapSession `_dropStaged('the screen was repainted')`): the paint
      // is what the inputs show now, as SAP GUI shows it after a round.
      // foldWindows carries the field OBJECTS over a turn that paints no
      // body (a flush, the type-ahead answer's body-less delta —
      // delta_paint_test), so a fresh object is a repaint even when it
      // repeats the old value; the ticked boxes go the same way
      if (_edited.isNotEmpty || _boxTicks.isNotEmpty) {
        final was = Set<ScreenField>.identity()..addAll(old.model.fields);
        if (widget.model.fields.any((f) => !was.contains(f))) {
          _edited.clear();
          _boxTicks.clear();
        }
      }
      // the same screen repainted while an input keeps the focus: the host
      // keys its cursor field by the model it was painted on (F1 / F4 and
      // the menu act on it) — told again for the new paint
      final focused = _focused;
      if (sameScreen &&
          focused != null &&
          (_focusNodes[focused]?.hasFocus ?? false)) {
        final f = _fieldAt(widget.model, focused);
        if (f != null) widget.onFocusField?.call(f);
      }
    }
    // another program / dynpro: the old screen's inputs are gone — their
    // controllers, focus nodes, painted values and typed marks go with
    // them (kept, they grew with every screen of the logon, and a typed
    // mark could survive onto the next screen's field at the same cell)
    if (old.model.program != widget.model.program ||
        old.model.dynpro != widget.model.dynpro) {
      _pruneInputs();
    }
    // another screen (or window level): the dropdown was the old field's
    if (_ta != null && !sameScreen) {
      _typedSinceKept.clear();
      _dropTypeAhead(); // the build follows
    }
  }

  /// The input painted at cell [key] (`area:row:col`) of [m].
  static ScreenField? _fieldAt(ScreenModel m, String key) {
    for (final f in m.fields) {
      if (f.kind == FieldKind.input && '${f.area}:${f.row}:${f.col}' == key) {
        return f;
      }
    }
    return null;
  }

  void _pruneInputs() {
    if (_controllers.isEmpty &&
        _focusNodes.isEmpty &&
        _painted.isEmpty &&
        _edited.isEmpty) {
      return;
    }
    final gone = _controllers.values.toList();
    final nodes = _focusNodes.values.toList();
    _controllers.clear();
    _focusNodes.clear();
    _painted.clear();
    _edited.clear();
    // the old fields' TextFields still hold them until this build replaces
    // them: disposed once the frame is done
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in gone) {
        c.dispose();
      }
      for (final n in nodes) {
        n.dispose();
      }
    });
  }

  /// The number of live input controllers (tests read it).
  @visibleForTesting
  int get controllerCount => _controllers.length;

  /// The number of live input focus nodes (tests read it).
  @visibleForTesting
  int get focusNodeCount => _focusNodes.length;

  /// Each scrolling table control's horizontal scroll position, by name.
  final Map<String, ScrollController> _tcScroll = {};

  /// The body's vertical scroll: a NEW screen (program / dynpro / popup
  /// level) opens at its top, as SAP GUI's does — a same-screen repaint
  /// keeps the offset (the server's scroll position rides the paint).
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _busyScope?.removeListener(_busyChanged);
    _ta?.dispose();
    _cursorN.dispose();
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final n in _focusNodes.values) {
      n.dispose();
    }
    for (final c in _tcScroll.values) {
      c.dispose();
    }
    _scroll.dispose();
    _listCursor.dispose();
    _listTicked.dispose();
    _boxTick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    dynproBuildCount++;
    final body = _buildBody(context);
    final menu = widget.onContextMenu;
    if (menu == null) return body;
    // the screen's context menu: a secondary click anywhere, a long press
    // where no input / button claims it (an input's own long press selects
    // text; its menu rides the text toolbar below)
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: (d) => menu(d.globalPosition, null),
      onLongPressStart: (d) => menu(d.globalPosition, null),
      child: body,
    );
  }

  /// An input's text toolbar (copy / paste …) plus SAP GUI's entries for
  /// the field: its help, its value help, the screen's functions.
  Widget _fieldTextMenu(
    BuildContext context,
    EditableTextState state,
    ScreenField f,
  ) {
    final at = state.contextMenuAnchors.primaryAnchor;
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        ...state.contextMenuButtonItems,
        ContextMenuButtonItem(
          label: 'SAP…',
          onPressed: () {
            ContextMenuController.removeAny();
            widget.onContextMenu?.call(at, f);
          },
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final m = widget.model;
    final derived = _derive(m);
    final layout = derived.layout;
    final icons = SapIconAtlasStrip.of(context);
    final radioGroups = derived.radioGroups;

    final panelText = layout.panel.map((f) => f.text.trim()).join('\n');

    final grid = derived.grid;
    final widestCols = DynproZoomScope.maybeOf(context) ?? _ownWidest;
    // a composed window's pane: the cell is the window's, not the pane's
    // width, and nothing below reads the constraints — built once per view
    // build, not once per sash step (a LayoutBuilder re-runs its builder
    // whenever the pane's constraints change); no width clamps a hosted
    // control there (the composed path hosts none)
    final fixed = widget.cell;
    final rows = _listRows(widget.model);
    // controls whose container the paint does not place
    final below = [
      for (final e in widget.controls.entries)
        if (!widget.model.containers.containsKey(e.key))
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SizedBox(height: 380, child: e.value),
          ),
    ];
    // a screen whose layout follows the window: at the window's own cell
    // (a fixed-size dynpro keeps the tree it always had — no LayoutBuilder
    // above its list view)
    final windowRows = (widget.windowCells?.$1 ?? 0) > 0
        ? widget.windowCells!.$1
        : m.windowRows;
    if (fixed == null &&
        !widget.compact &&
        rows.isEmpty &&
        below.isEmpty &&
        followsWindow(m, windowRows)) {
      return LayoutBuilder(
        builder: (context, cons) {
          final window = _windowOf(m, cons.maxWidth);
          if (window != null &&
              cons.maxHeight.isFinite &&
              followsWindow(m, window.$1)) {
            return _windowBody(grid, layout, radioGroups, icons, window, cons);
          }
          return _listBody(
            context,
            m,
            grid,
            layout,
            radioGroups,
            icons,
            panelText,
            widestCols,
            rows,
            below,
          );
        },
      );
    }
    return _listBody(
      context,
      m,
      grid,
      layout,
      radioGroups,
      icons,
      panelText,
      widestCols,
      rows,
      below,
    );
  }

  Widget _listBody(
    BuildContext context,
    ScreenModel m,
    DynproGrid grid,
    DynproLayout layout,
    Map<String, List<ScreenField>> radioGroups,
    SapIconAtlas? icons,
    String panelText,
    Map<String, int> widestCols,
    List<ListLine?> rows,
    List<Widget> below,
  ) {
    final fixed = widget.cell;
    // a composed window's pane: its cell, raised to the legible floor
    // ([dynproLegibleCell]) — the pane then holds fewer columns (a table control
    // is boxed to them and scrolls its columns sideways inside), and a
    // dynpro wider than the pane scrolls sideways in it
    // (a pane carrying CFW regions on its cells — the Easy Access tree and
    // picture, an ALV tree's toolbar — keeps the window cell: those
    // controls draw their own legible text, and their regions must stay
    // where the window's layout put them)
    final cell = fixed == null
        ? null
        : (widget.overlays.isEmpty ? dynproLegibleCell(fixed) : fixed);
    final paneCols = widget.maxCols == null || cell == null
        ? null
        : math.max(1, (widget.maxCols! * fixed!.width / cell.width).floor());
    final body = fixed != null
        ? _absorbing(
            _buildGrid(
              context,
              grid,
              layout,
              radioGroups,
              icons,
              cell!.width,
              double.infinity,
              rowHeight: cell.height,
              maxCols: paneCols,
            ),
          )
        : _fittedBody(
            m,
            grid,
            layout,
            radioGroups,
            icons,
            panelText,
            widestCols,
          );

    // the paint's classic list (an F4 hit list, a report list — thousands
    // of lines): its lines built as they scroll into view
    if (widget.cell != null) {
      // a pane of a composed window: the grid starts at the pane's origin;
      // raised to the legible cell it may run past the pane: sideways
      if (rows.isEmpty) {
        final raised = cell!.width > fixed!.width + 0.01;
        return SingleChildScrollView(
          child: raised
              ? SingleChildScrollView(
                  key: const ValueKey('dynpro-pane-sideways'),
                  scrollDirection: Axis.horizontal,
                  child: body,
                )
              : body,
        );
      }
      final paged = _pagedList(rows, body, const [], EdgeInsets.zero);
      if (paged != null) return paged;
      return _withList(context, rows, 0, (line, width, _) {
        return ListView.builder(
          controller: _scroll,
          padding: EdgeInsets.zero,
          itemCount: 1 + rows.length,
          itemBuilder: (context, i) => i == 0
              ? Center(heightFactor: 1, child: body)
              : line(i - 1),
        );
      });
    }
    final hPad = widget.compact ? 8.0 : 12.0;
    Widget listView(Widget Function(int i)? line, int count) =>
        ListView.builder(
          controller: widget.compact ? null : _scroll,
          shrinkWrap: widget.compact,
          physics: widget.compact
              ? const NeverScrollableScrollPhysics()
              : null,
          padding: EdgeInsets.fromLTRB(
            hPad,
            8,
            hPad,
            widget.compact ? 8 : 96,
          ),
          itemCount: 1 + count + below.length,
          itemBuilder: (context, i) {
            if (i == 0) return body;
            if (i <= count) return line!(i - 1);
            return below[i - 1 - count];
          },
        );
    if (rows.isEmpty) return listView(null, 0);
    final paged = _pagedList(
      rows,
      body,
      below,
      EdgeInsets.fromLTRB(hPad, 8, hPad, widget.compact ? 8 : 24),
    );
    if (paged != null) return paged;
    return _withList(
      context,
      rows,
      2 * hPad,
      (line, width, _) => listView(line, rows.length),
    );
  }

  /// The SAP window (rows, cols) a main-window paint was laid out for: the
  /// session's current one (the paint's SES dimensions can lag one screen
  /// behind a resize), else the paint's own — only when that window fits
  /// [width] at the legible cell, i.e. could be this view's (a window the
  /// session never sized is another client's: ME21N recorded at 45 x 255
  /// keeps the free-standing grid); null when neither holds.
  (int, int)? _windowOf(ScreenModel m, double width) {
    final w = widget.windowCells;
    if (w != null && w.$1 > 0 && w.$2 > 0) return w;
    if (m.windowRows > 0 &&
        m.windowCols > 0 &&
        m.windowCols * _minCellW <= width) {
      return (m.windowRows, m.windowCols);
    }
    return null;
  }

  /// A screen whose layout follows the window ([followsWindow]) drawn at
  /// the window's own cell, the one the session sized the window from
  /// ([sapWindowCells]: rows at the composer's 2:1 cell, 18 points at the
  /// least): SE24's methods table at 18 x 124 in an 874 x 258 body is cw
  /// 7.05 x ch 14.33, the table ending at 243.7 — at the free-standing
  /// grid's 22-point rows it ran 220 points past the body. Measured OUTSIDE the scroll view (an
  /// item of the ListView has no height bound), with no paddings and no
  /// scroll tail (the composer has none either); the program's zoom
  /// memory is neither read nor widened: the window's columns are the
  /// cell. Below the legible cell the grid keeps 7 points (rows at least
  /// 14) and scrolls.
  Widget _windowBody(
    DynproGrid grid,
    DynproLayout layout,
    Map<String, List<ScreenField>> radioGroups,
    SapIconAtlas? icons,
    (int, int) window,
    BoxConstraints cons,
  ) {
    final m = widget.model;
    final (windowRows, windowCols) = window;
    // the painted extent (hosted controls' containers count, as in
    // [_fittedBody]) and the window's columns: the cell is the window's
    var painted = grid.cols;
    for (final name in widget.controls.keys) {
      final c = m.containers[name];
      if (c != null) painted = math.max(painted, c.col + c.width);
    }
    final cols = math.max(painted, windowCols);
    final cw = (cons.maxWidth / cols).clamp(_minCellW, _maxCellW);
    final ch = (cons.maxHeight / windowRows).clamp(
      cw * ScreenComposer.cellAspect,
      cw * ScreenComposer.cellAspect * ScreenComposer.maxFillStretch,
    );
    Widget body = _absorbing(
      _buildGrid(
        context,
        grid,
        layout,
        radioGroups,
        icons,
        cw,
        cols * cw,
        windowRow: ch,
      ),
    );
    // the legible cell's floor wider than the body (upright, 80 columns
    // at 7 points in 402): the window scrolls sideways
    if (painted * cw > cons.maxWidth + 0.5) {
      body = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: body,
      );
    }
    return SingleChildScrollView(controller: _scroll, child: body);
  }

  /// The body fitted to the window: SAP GUI geometry whenever the painted
  /// grid fits the width at a legible cell size; a phone-narrow window (or
  /// the logon screen's side text panel) keeps the row reflow.
  Widget _fittedBody(
    ScreenModel m,
    DynproGrid grid,
    DynproLayout layout,
    Map<String, List<ScreenField>> radioGroups,
    SapIconAtlas? icons,
    String panelText,
    Map<String, int> widestCols,
  ) {
    return LayoutBuilder(
      builder: (context, cons) {
        // SAP GUI geometry whenever the painted grid fits the width at a
        // legible cell size; a phone-narrow window (or the logon screen's
        // side text panel) keeps the row reflow below
        final hostsPlaced = widget.controls.keys.any(m.containers.containsKey);
        // the side-text panel reflow is the phone's logon screen: a tablet
        // keeps SAP GUI's geometry whatever text the screen carries (PA20's
        // infotype list read as a "panel" and tore the screen into a phone
        // form, field names for captions)
        final tablet = cons.maxWidth >= 600 && !m.isKernelLogon;
        if ((!grid.isEmpty || hostsPlaced) &&
            (panelText.length <= 60 || tablet)) {
          // the hosted controls' containers count toward the painted width
          // (DB50/0219: fields to col 125, the chart container to col 163)
          var cols = grid.cols;
          for (final name in widget.controls.keys) {
            final c = m.containers[name];
            if (c != null) cols = math.max(cols, c.col + c.width);
          }
          // the zoom of a transaction holds across its screens / tabs: the
          // cell fits the WIDEST screen of the program seen so far (ME21N's
          // header tabs each paint another width; SAP GUI's cell never
          // moves). A popup is its own window, sized to its content: it
          // fits its own columns and neither reads nor widens the memory
          // (a 40-column popup of ME21N's program in its 448-point box was
          // laid out for 160 columns — the phone reflow on an iPad)
          if (m.modalLevel == 0) {
            final prog = m.program ?? '';
            cols = math.max(cols, widestCols[prog] ?? 0);
            widestCols[prog] = cols;
          }
          final cw = cons.maxWidth / cols;
          if (cw >= _minCellW) {
            return _absorbing(
              _buildGrid(
                context,
                grid,
                layout,
                radioGroups,
                icons,
                math.min(cw, _maxCellW),
                cons.maxWidth,
              ),
            );
          }
          // a table control only reads as its columns: too narrow for the
          // legible cell, the grid keeps it and the window scrolls sideways
          // (the row reflow tore TC_1211's lines into slivers of inputs)
          // the same on any SAP-wide screen of a tablet: the row reflow is
          // the phone's (it tore ME21N's header tabs into chips)
          if (m.tableControls.isNotEmpty || cons.maxWidth >= 600) {
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: _absorbing(
                _buildGrid(
                  context,
                  grid,
                  layout,
                  radioGroups,
                  icons,
                  _minCellW,
                  cols * _minCellW,
                ),
              ),
            );
          }
        }
        final wide = cons.maxWidth > 560 && panelText.length > 60;
        final panelWidth = wide
            ? (cons.maxWidth * 0.38).clamp(160.0, 320.0)
            : 0.0;
        final formWidth = wide
            ? cons.maxWidth - panelWidth - 24
            : cons.maxWidth;
        final rows = _buildRows(context, layout, radioGroups, icons, formWidth);
        // the reflow has no cells to place hosted controls at: they follow
        // the form, full width
        final hosted = [
          for (final e in widget.controls.entries)
            if (m.containers.containsKey(e.key))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SizedBox(height: 380, child: e.value),
              ),
        ];
        final form = _absorbing(
          hosted.isEmpty
              ? rows
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [rows, ...hosted],
                ),
        );
        if (!wide) {
          // narrow: the text panel reads first, the form below
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (panelText.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextPanel(text: panelText, compact: widget.compact),
                ),
              form,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: panelWidth,
              child: TextPanel(text: panelText, compact: widget.compact),
            ),
            const VerticalDivider(width: 24, thickness: 1),
            Expanded(child: form),
          ],
        );
      },
    );
  }

  /// A classic list the server PAGES ([listPageOf]: longer than its
  /// window): the page heading fixed, the body scrolling over the whole
  /// list, the page the server sent at its own lines ([SapPagedList]) —
  /// null for a list the paint holds whole (drawn as before). [rows] are
  /// the painted buffer rows from the first painted one ([_listRows]).
  Widget? _pagedList(
    List<ListLine?> rows,
    Widget body,
    List<Widget> below,
    EdgeInsets padding,
  ) {
    final m = widget.model;
    final page = listPageOf(m);
    if (page == null || !page.scrolls || m.listPaint.isEmpty) return null;
    final base = m.listPaint.first.line;
    return _withList(context, rows, padding.horizontal, (line, width, lh) {
      return SapPagedList(
        page: page,
        lineHeight: lh,
        identity: (m.program, m.dynpro, m.title, m.modalLevel),
        row: (r) {
          final i = r - base;
          return i >= 0 && i < rows.length
              ? line(i)
              : SizedBox(width: width, height: lh);
        },
        top: m.fields.isEmpty ? null : body,
        bottom: below,
        busy: widget.busy,
        onScroll: widget.onListScroll,
        onPress: widget.onPress,
        padding: padding,
        compact: widget.compact,
        autofocus: m.fields.isEmpty,
      );
    });
  }

  /// The rows a list renderer draws: every painted buffer row from the
  /// first to the last ([ScreenModel.listPaint], a gap an unpainted blank
  /// row), else the pickable lines alone (a model built without a paint).
  static final Expando<List<ListLine?>> _rowsMemo = Expando('list rows');

  List<ListLine?> _listRows(ScreenModel m) {
    final memo = _rowsMemo[m];
    if (memo != null) return memo;
    final List<ListLine?> rows;
    if (m.listPaint.isEmpty) {
      rows = m.listLines;
    } else {
      final first = m.listPaint.first.line;
      rows = List<ListLine?>.filled(m.listPaint.last.line - first + 1, null);
      for (final l in m.listPaint) {
        rows[l.line - first] = l;
      }
    }
    // a model mutated after its first build (tests) is read afresh
    if (m.listPaint.isNotEmpty || m.listLines.isNotEmpty) _rowsMemo[m] = rows;
    return rows;
  }

  /// The pickable lines of [lines] as an identity set, once per list (a
  /// rebuild — a tick, busy — does not re-hash every line); the length
  /// guards a list mutated in place (tests build models so).
  static final Expando<(int, Set<ListLine>)> _pickableMemo =
      Expando('pickable lines');

  static Set<ListLine> _pickableOf(List<ListLine> lines) {
    final memo = _pickableMemo[lines];
    if (memo != null && memo.$1 == lines.length) return memo.$2;
    final set = Set<ListLine>.identity()..addAll(lines);
    _pickableMemo[lines] = (lines.length, set);
    return set;
  }

  /// [sapListColumns] of [rows], once per rows list ([_listRows] memoizes
  /// the list per model).
  static final Expando<(int, int)> _columnsMemo = Expando('list columns');

  static int _columnsOf(List<ListLine?> rows) {
    final memo = _columnsMemo[rows];
    if (memo != null && memo.$1 == rows.length) return memo.$2;
    final cols = sapListColumns(rows);
    _columnsMemo[rows] = (rows.length, cols);
    return cols;
  }

  /// The list on SAP's character grid: the cell fitted to the width (down
  /// to a legible minimum, then the list scrolls sideways — a 170-column
  /// where-used list), the frame drawn as continuous lines, the checkboxes
  /// real ones. [build] gets the line builder and the list's width.
  Widget _withList(
    BuildContext context,
    List<ListLine?> rows,
    double padding,
    Widget Function(Widget Function(int i) line, double width, double lh)
    build,
  ) {
    final palette = SapListPalette.of(context);
    final icons = SapIconAtlasStrip.of(context);
    final pickable = _pickableOf(widget.model.listLines);
    final cols = math.max(1, _columnsOf(rows));
    const base = TextStyle(
      fontFamily: 'Menlo',
      fontFamilyFallback: ['Courier New', 'monospace'],
    );
    return LayoutBuilder(
      builder: (context, cons) {
        final avail = cons.maxWidth - padding;
        final size = widget.compact ? 12.0 : 13.0;
        var mt = SapListMetrics.of(base, size);
        if (cols * mt.cw > avail && avail > 0) {
          final fit = size * avail / (cols * mt.cw);
          mt = SapListMetrics.of(base, math.max(10.0, fit.floorToDouble()));
        }
        final width = cols * mt.cw;
        final painted = widget.model.listCursor;
        final cursorColor = Theme.of(context).colorScheme.primary;
        Widget line(int i) {
          final l = rows[i];
          if (l == null) return SizedBox(width: width, height: mt.lh);
          final cell = widget.onListCell;
          // a tap places the list cursor (no round); a double-tap is the
          // pick there — F2 with the cursor on the tapped cell
          void tapAt(int col) {
            _listCursor.value = (l.line, col);
            widget.onListCursor?.call(l.line, col);
          }

          // busy, the cursor and a tick redraw this line alone
          return _leaf(
            (busy) => _ListCursorLine(
              cursor: _listCursor,
              ticked: _listTicked,
              line: l,
              painted: painted,
              row: l.line,
              builder: (cursorCol) {
                final pick = pickable.contains(l) &&
                    !busy &&
                    widget.onListPick != null;
                return SapListLineView(
                  line: l,
                  metrics: mt,
                  palette: palette,
                  width: width,
                  icons: icons,
                  cursorCol: cursorCol,
                  cursorColor: cursorColor,
                  onTapAt: busy ? null : tapAt,
                  onDoubleTapAt: busy
                      ? null
                      : (col) {
                          tapAt(col);
                          if (pick) widget.onListPick!(l);
                        },
                  onCheck: cell == null || busy
                      ? null
                      : (s, on) {
                          (_listTicks[l] ??= {})[s.col] = on;
                          _listTicked.value = (l, s.col, on);
                          cell(l, s, on ? 'X' : ' ');
                        },
                  checkedOf: (s) => _listTicks[l]?[s.col] ?? s.checked,
                );
              },
            ),
          );
        }

        final list = build(line, width, mt.lh);
        if (width <= avail || !cons.hasBoundedWidth) return list;
        // wider than the window even at the minimum cell: sideways
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: width + padding, child: list),
        );
      },
    );
  }

  /// The SAP GUI layout: every field Positioned at its painted cell on a
  /// [cw]-point character grid (the reference client screenshot's absolute geometry),
  /// group boxes as titled frames, tabstrips as a tab bar.
  Widget _buildGrid(
    BuildContext context,
    DynproGrid grid,
    DynproLayout layout,
    Map<String, List<ScreenField>> radioGroups,
    SapIconAtlas? icons,
    double cw,
    double maxWidth, {
    double? rowHeight,
    double? windowRow,
    int? maxCols,
  }) {
    final scheme = Theme.of(context).colorScheme;
    // [windowRow]: a window-following screen at the window's own row
    // ([_windowBody]); [rowHeight]: a composed window's pane
    final ch = rowHeight ?? windowRow ?? (cw * 2.6).clamp(22.0, 30.0);
    final windowCell = rowHeight != null || windowRow != null;
    // a fixed (composed-window) cell scales the text with it, like the
    // reference client's picture; a fitted grid keeps a readable minimum (a window
    // row keeps it too, as far as the row holds it)
    final font = rowHeight != null
        ? math.min(cw * 1.4, rowHeight * 0.78)
        : windowRow != null
        ? math.min((cw * 1.35).clamp(11.0, 15.0), windowRow * 0.78)
        : (cw * 1.35).clamp(11.0, 15.0);
    // a composed window's pane and a window-following screen start at the
    // dynpro's row 0 — the window cell its neighbours and its overlays are
    // placed by; a free-standing grid skips the blank rows above its first
    // painted one
    final top = windowCell ? 0 : grid.firstRow;
    // a table control's right edge: the box visible inside its subscreen
    // ([TableControlInfo.boxWidth]), bounded by the pane
    int right(TableControlInfo tc) =>
        math.min(tc.col + tc.boxWidth, maxCols ?? (1 << 30));
    double y(int row) => (row - top) * ch;

    final children = <Widget>[];
    for (final fr in widget.model.frames) {
      if (fr.drows < 2 || fr.dcols < 2) continue;
      children.add(
        Positioned(
          left: fr.col * cw + cw / 2,
          top: y(fr.row) + ch / 2,
          width: (fr.dcols - 1) * cw,
          height: (fr.drows - 1) * ch,
          child: _GridFrame(title: fr.text.trim(), fontSize: font),
        ),
      );
    }
    // classic table controls: the control's box, its title bar, the column
    // headings on the header row above line 1 and the line selectors. The
    // columns past the fixed ones scroll sideways inside the box, as in
    // SAP GUI (TC_1211 paints 35 columns, 292 cells wide, into 157)
    final scrolling = <String, _TcScroll>{};
    // each control's columns at the widths the user dragged (the server's
    // until a header edge is dragged)
    final store =
        DynproZoomScope.columnWidthsOf(context) ?? _ownTcWidths;
    final tcCols = {
      for (final tc in widget.model.tableControls)
        tc.name: _TcCols(tc, store[tcColumnKey(widget.model, tc)]),
    };
    for (final tc in widget.model.tableControls) {
      children.add(
        Positioned(
          left: tc.col * cw,
          top: y(tc.row),
          width: (right(tc) - tc.col) * cw,
          height: tc.height * ch,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      );
      final sc = _TcScroll.of(tcCols[tc.name]!, right(tc));
      if (sc != null) scrolling[tc.name] = sc;
      // the cells of the fixed (or only) columns: field boxes on the
      // control's ground, the gaps between them its grid
      children.add(
        Positioned(
          key: ValueKey('tc-grid-${tc.name}'),
          left: 0,
          top: y(tc.row),
          width: right(tc) * cw,
          height: tc.height * ch,
          child: CustomPaint(
            painter: _TcGridPainter(
              tc,
              tcCols[tc.name]!,
              sc,
              cw,
              ch,
              scheme.surfaceContainerHigh,
              moving: false,
            ),
          ),
        ),
      );
      if (tc.title.isNotEmpty && tc.headerRows >= 1) {
        children.add(
          Positioned(
            left: (tc.col + 1) * cw,
            top: y(tc.row),
            width: math.max(0, right(tc) - tc.col - 2) * cw,
            height: ch,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                tc.title,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontSize: font,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ),
        );
      }
      if (tc.hasSelectionColumn && tc.headerRows >= 1) {
        for (var line = 1; line <= tc.visibleRows; line++) {
          children.add(
            Positioned(
              left: tc.col * cw + 1,
              top: y(tc.lineRow(line)) + 2,
              width: cw - 2,
              height: ch - 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  border: Border.all(color: scheme.outlineVariant, width: 0.5),
                ),
              ),
            ),
          );
        }
      }
    }
    // the cells of a scrolling control's moving columns, per control, at
    // cells relative to its scroll origin
    final moving = <String, List<_TcCell>>{};
    bool moves(TableControlInfo tc, int column) =>
        scrolling[tc.name] != null &&
        tcCols[tc.name]!.position(column) >= scrolling[tc.name]!.fixed;
    for (final tc in widget.model.tableControls) {
      if (tc.headerRows < 1 || tc.title.isNotEmpty && tc.headerRows < 2) {
        continue; // a lone chrome row is the title bar
      }
      final sc = scrolling[tc.name];
      final cols = tcCols[tc.name]!;
      final key = tcColumnKey(widget.model, tc);
      final grips = <void Function()>[];
      for (var i = 0; i < tc.columns.length; i++) {
        if (i >= cols.count) continue;
        // the heading the control paints ("Pos", "UA"), else the column's
        // DDIC title; the long title is the heading's tooltip
        final heading = i < tc.headings.length
            ? tc.headings[i]
            : (i < tc.titles.length ? tc.titles[i].trim() : '');
        final tip = i < tc.headingTips.length && tc.headingTips[i].isNotEmpty
            ? tc.headingTips[i]
            : (i < tc.titles.length ? tc.titles[i].trim() : '');
        final move = moves(tc, i);
        final left = (cols.left(i) - (move ? sc!.left : 0)) * cw;
        final top = move
            ? (tc.headerRows - 1) * ch
            : y(tc.row + tc.headerRows - 1);
        final width = cols.width(i) * cw;
        void place(Widget w, double from, double to) => move
            ? moving.putIfAbsent(tc.name, () => []).add(_TcCell(from, to, w))
            : children.add(w);
        // the column's header BUTTON — a grey box with a gap to its
        // neighbour, its heading cut inside it with an ellipsis ("T…" of
        // SAPLSEOD/2000's 3-cell method-type column, a recorded session
        // column_resize methods_tab_screenshot.png): a heading never runs
        // into the next ("Met" against "Description" read
        // "MetDescription")
        place(
          Positioned(
            key: heading.isEmpty ? null : ValueKey('tc-heading-${tc.name}-$i'),
            left: left,
            top: top,
            width: width,
            height: ch,
            child: Padding(
              padding: const EdgeInsets.only(right: _tcGap, bottom: _tcGap),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                ),
                child: heading.isEmpty
                    ? const SizedBox.expand()
                    : Tooltip(
                        message: tip == heading ? '' : tip,
                        child: ClipRect(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: _iconText(
                                heading,
                                icons,
                                style: TextStyle(
                                  fontSize: font,
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onSurfaceVariant,
                                ),
                                clip: true,
                                ellipsis: true,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ),
          left,
          left + width,
        );
        // the column's right edge in the header row: the real control's
        // header separator, and its grip — a drag resizes the column (the
        // columns to its right follow; the control scrolls sideways once
        // they run past its box); the layout rides the next round
        // ([DynproView.onTableColumnWidths]). Placed after every header
        // button, so no neighbour's button covers its right half
        final edge = left + width;
        grips.add(() => place(
          Positioned(
            key: ValueKey('tc-edge-${tc.name}-$i'),
            left: edge - ColumnEdgeGrip.width / 2,
            top: top,
            width: ColumnEdgeGrip.width,
            height: ch,
            child: ColumnEdgeGrip(
              color: scheme.outlineVariant,
              // from the stored width: several drag steps may land
              // before the rebuild this one schedules
              onDrag: (dx) => setState(() {
                final now = store[key]?[i] ?? tc.widths[i].toDouble();
                (store[key] ??= {})[i] = (now + dx / cw).clamp(
                  _tcMinCells,
                  _tcMaxCells,
                );
              }),
              // let go: whole characters (a SAP column width is one), and
              // the layout to the session for the next round
              onDragEnd: () => _tcDragEnded(tc, store, key),
            ),
          ),
          edge - ColumnEdgeGrip.width / 2,
          edge + ColumnEdgeGrip.width / 2,
        ));
      }
      for (final g in grips) {
        g();
      }
    }
    final tcByName = {for (final tc in widget.model.tableControls) tc.name: tc};
    // the fields, keyed by their cell (a repaint that adds or drops a field
    // keeps every other field's element — its TextField, its focus) and
    // grouped by painted row, each row its own repaint boundary: a caret
    // blink or a typed character repaints its row, not the screen
    final fieldsAt = children.length;
    final keys = <String>{};
    final rowFields = <int, List<Widget>>{};
    final rowRight = <int, double>{};
    for (final c in grid.cells) {
      final f = c.field;
      // a table cell keeps to its column, from the column's (moved) left
      // edge: a text cell never runs on over an empty neighbour column (a
      // method name across SAPLSEOD/2000's 3-cell type column into the
      // Level text); in a column the user resized a text cell fills it, an
      // input keeps its own length within it
      final tcc = f.tableControl == null ? null : tcCols[f.tableControl];
      final ci = (f.tcColumn ?? 1) - 1;
      final inCatalog = tcc != null && ci >= 0 && ci < tcc.count;
      var cells = c.width.toDouble();
      if (inCatalog) {
        final room = math.max(
          1.0,
          tcc.width(ci) - (c.col - tcc.tc.columnOffsets[ci]),
        );
        cells = _isText(f) && tcc.resized(ci) ? room : math.min(cells, room);
      }
      final w = cells * cw;
      Widget child;
      switch (f.kind) {
        case FieldKind.label:
        case FieldKind.output:
          // a text atom outside a table control takes no cursor (the
          // session refuses its double-click): only a cell answers
          child = _doubleTappable(
            f,
            enabled: f.tableControl != null,
            Align(
              alignment: Alignment.centerLeft,
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  fontSize: font,
                  color: scheme.onSurface,
                  height: 1.1,
                ),
                maxLines: 1,
                // a table control's cell: the control's one font, cut at
                // the column's edge as SAP GUI cuts it (never shrunk to fit:
                // SAPLSEOD/2000's method names drew at a different size row
                // by row); elsewhere proportional text can run wider than
                // its painted cells: shrink it to fit
                child: f.tableControl != null
                    ? _tcText(f, icons, w, clamped: c.clamped || cells < c.own)
                    : c.clamped
                    ? _clampedText(f, icons, w)
                    : FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: _iconText(f.text.trimRight(), icons),
                      ),
              ),
            ),
          );
        case FieldKind.input when isIconOutput(f):
          // a protected field holding an icon (a selection screen's option
          // icon in front of LOW, `@28\QSélectionner : inclure modèle@`):
          // the glyph and its quick info, not the token's text
          child = _doubleTappable(f, _iconOutput(f, icons, font, ch));
        case FieldKind.input:
          child = _doubleTappable(
            f,
            _gridInput(
              f,
              font,
              cw,
              width: w,
              semanticsLabel: _accessibleName(f, layout, tcByName, icons),
            ),
          );
        case FieldKind.combobox:
          child = _doubleTappable(f, _listbox(f, font, monospace: true));
        case FieldKind.pushbutton:
          child = _gridButton(f, icons, font, cw);
        case FieldKind.tabstrip:
          child = _leaf(
            (busy) => _GridTab(
              text: icons?.stripTokens(f.text).trim() ?? f.text.trim(),
              active: f.on,
              fontSize: font,
              onTap: (busy || (f.fcode ?? '').isEmpty)
                  ? null
                  : () => widget.onOkcode(f.fcode!),
            ),
          );
        case FieldKind.checkbox:
          // a table control's checkbox column: a glyph, not a Material
          // toggle (four animation controllers, a focus node and a ripple
          // per cell, times the control's lines, for a box whose tap is
          // the cell's own); a free box keeps its Material target
          final bare = f.tableControl != null && _choiceText(f).isEmpty;
          final name = _tcCellName(f, tcByName, icons);
          child = _leaf(
            (busy) => _Select(
              source: _boxTick,
              select: (_) => _boxTicks[f] ?? f.on,
              builder: (on) {
                final enabled = !busy && !f.isProtected;
                return _gridChoice(
                  f,
                  font,
                  ch,
                  bare
                      ? SapCheckGlyph(on: on, enabled: enabled, size: ch - 6)
                      : Checkbox(
                          value: on,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          onChanged: enabled ? (_) => _tickBox(f) : null,
                        ),
                  enabled ? () => _tickBox(f) : null,
                  semanticsLabel: name,
                );
              },
            ),
          );
        case FieldKind.radio:
          final group = radioGroups['${f.area}:${f.block}:${f.group}'] ?? [f];
          final name = _tcCellName(f, tcByName, icons);
          child = _leaf(
            (busy) =>
                _gridRadio(f, group, font, ch, busy, semanticsLabel: name),
          );
      }
      // a composed window's small fixed cell: every field fills its row
      // (a 4-point inset would clip the glyphs of a 12-point row)
      final h = f.kind == FieldKind.tabstrip || windowCell ? ch : ch - 4;
      final tc = tcByName[f.tableControl];
      final move = tc != null && moves(tc, (f.tcColumn ?? 1) - 1);
      // a table cell keeps to its column; a free checkbox keeps a target
      final choice = f.kind == FieldKind.checkbox || f.kind == FieldKind.radio;
      final cellKey = '${f.area}:${f.row}:${f.col}';
      var k = 'field-$cellKey';
      for (var n = 1; !keys.add(k); n++) {
        k = 'field-$cellKey#$n'; // two fields painted at one cell
      }
      final shift = inCatalog ? tcc.shift(ci) : 0.0;
      final left =
          (c.col + shift - (move ? scrolling[tc.name]!.left : 0)) * cw;
      final width = choice && tc == null ? math.max(w, ch + 8) : w;
      final placed = Positioned(
        key: ValueKey(k),
        left: left,
        // a row's field: from its row's top
        top: (move ? (c.row - tc.row) * ch : 0) + (ch - h) / 2,
        width: width,
        height: h,
        child: child,
      );
      if (move) {
        moving
            .putIfAbsent(tc.name, () => [])
            .add(_TcCell(left, left + width, placed, cellKey));
      } else {
        rowFields.putIfAbsent(c.row, () => []).add(placed);
        rowRight[c.row] = math.max(rowRight[c.row] ?? 0, left + width);
      }
    }
    children.insertAll(fieldsAt, [
      for (final e in rowFields.entries)
        Positioned(
          key: ValueKey('row-${e.key}'),
          left: 0,
          top: y(e.key),
          width: rowRight[e.key],
          height: ch,
          child: RepaintBoundary(
            child: Stack(clipBehavior: Clip.none, children: e.value),
          ),
        ),
    ]);
    for (final tc in widget.model.tableControls) {
      final sc = scrolling[tc.name];
      if (sc == null) continue;
      // the moving columns' cell boxes, under their fields, scrolled with
      // them
      final extent = (sc.content - sc.left) * cw;
      moving
          .putIfAbsent(tc.name, () => [])
          .insert(
            0,
            _TcCell(
              0,
              extent,
              Positioned(
                key: ValueKey('tc-grid-moving-${tc.name}'),
                left: 0,
                top: 0,
                width: extent,
                height: tc.height * ch,
                child: CustomPaint(
                  painter: _TcGridPainter(
                    tc,
                    tcCols[tc.name]!,
                    sc,
                    cw,
                    ch,
                    scheme.surfaceContainerHigh,
                    moving: true,
                  ),
                ),
              ),
            ),
          );
      final ctl = _tcScroll.putIfAbsent(tc.name, ScrollController.new);
      children.add(
        Positioned(
          left: sc.left * cw,
          top: y(tc.row),
          width: (sc.right - sc.left) * cw,
          height: tc.height * ch,
          child: Scrollbar(
            controller: ctl,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: ctl,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: (sc.content - sc.left) * cw,
                height: tc.height * ch,
                // only the columns near the scrolled window are built
                child: RepaintBoundary(
                  child: _TcColumns(
                    controller: ctl,
                    viewport: (sc.right - sc.left) * cw,
                    cells: moving[tc.name] ?? const [],
                    cursor: _cursorN,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    // each table control's vertical scroll bar — the server's model rows,
    // first row and page (18/9/14 bytes 36..41) — and its paging: a tap on
    // the track above / below the thumb, or a swipe over the lines, is the
    // real GUI's Page Up / Page Down with the cursor in the control; the
    // server repaints the lines (the dynpro pane itself never scrolls for
    // it: the tab strip and the headings stay put)
    final page = widget.onTablePage;
    for (final tc in widget.model.tableControls) {
      final total = tc.totalRows, first = tc.firstRow, rows = tc.pageRows;
      if (page == null || total == null || first == null || rows == null) {
        continue;
      }
      if (total <= rows && first == 0) continue; // one page: nothing to page
      final up = first > 0, down = first + rows < total;
      final top = y(tc.lineRow(1));
      final height = tc.visibleRows * ch;
      if (height <= 0) continue;
      void fire(int vkey) {
        if (_busyNow) return;
        if (vkey == _vkeyPageDown && !down) return;
        if (vkey == _vkeyPageUp && !up) return;
        page(tc, vkey);
      }

      children.add(
        Positioned(
          key: ValueKey('tc-swipe-${tc.name}'),
          left: tc.col * cw,
          top: top,
          width: (right(tc) - tc.col) * cw - _TcPageBar.width,
          height: height,
          child: _TcSwipe(onPage: fire),
        ),
      );
      children.add(
        Positioned(
          key: ValueKey('tc-vscroll-${tc.name}'),
          left: right(tc) * cw - _TcPageBar.width - 1,
          top: top,
          width: _TcPageBar.width,
          height: height,
          child: _TcPageBar(
            total: total,
            first: first,
            rows: rows,
            onPage: fire,
          ),
        ),
      );
    }
    // hosted controls at their container's cells (never wider than the
    // window, never too short to read)
    var canvasW = grid.cols * cw, canvasH = (grid.rows - top) * ch;
    for (final e in widget.controls.entries) {
      final c = widget.model.containers[e.key];
      if (c == null) continue;
      final left = c.col * cw;
      final w = math.min(c.width * cw, maxWidth - left);
      // (a window-following screen's control is its cells: the window
      // fits the body exactly)
      final h = windowRow != null
          ? c.height * ch
          : math.max(c.height * ch, 260.0);
      children.add(
        Positioned(
          left: left,
          top: y(c.row),
          width: w,
          height: h,
          child: e.value,
        ),
      );
      canvasW = math.max(canvasW, left + w);
      canvasH = math.max(canvasH, y(c.row) + h);
    }
    // a composed window's regions on this dynpro, exactly at their cells
    // (a one-row bar stays one row: no legibility minimum)
    if (rowHeight != null) {
      // one area may hold several regions (a splitter's cells: /AIF/IFMON's
      // MAIN_CUSTOM holds the HTML form AND the date navigator) — a repeated
      // id gets a '#n' suffix, the first keeps the plain key
      final seenIds = <String, int>{};
      for (final o in widget.overlays) {
        final r = o.cells;
        final min = o.minPoints;
        if (min == null && (r.width <= 0 || r.height <= 0)) continue;
        if (r.width < 0 || r.height < 0) continue;
        var left = r.left * cw, t = (r.top - top) * ch;
        var w = r.width * cw, h = r.height * ch;
        if (min != null && w < min.width) {
          left -= (min.width - w) / 2;
          w = min.width;
        }
        if (min != null && h < min.height) {
          t -= (min.height - h) / 2;
          h = min.height;
        }
        String? key;
        if (o.id != null) {
          final n = seenIds.update(o.id!, (v) => v + 1, ifAbsent: () => 0);
          key = n == 0 ? 'overlay-${o.id}' : 'overlay-${o.id}#$n';
        }
        children.add(
          Positioned(
            key: key == null ? null : ValueKey(key),
            left: left,
            top: t,
            width: w,
            height: h,
            child: o.builder?.call(Size(cw, ch)) ?? o.child,
          ),
        );
        canvasW = math.max(canvasW, left + w);
        canvasH = math.max(canvasH, t + h);
      }
    }
    final canvas = SizedBox(
      width: canvasW,
      height: canvasH,
      child: Stack(clipBehavior: Clip.none, children: children),
    );
    return Align(alignment: Alignment.topLeft, child: canvas);
  }

  /// A table-control column edge let go ([DynproView.onTableColumnWidths]).
  void _tcDragEnded(
    TableControlInfo tc,
    Map<String, Map<int, double>> store,
    String key,
  ) {
    final over = store[key];
    if (over == null) return;
    setState(() {
      for (final e in over.entries) {
        over[e.key] = e.value.roundToDouble();
      }
    });
    final n = math.min(tc.widths.length, tc.columnOffsets.length);
    final widths = [
      for (var i = 0; i < n; i++) (over[i] ?? tc.widths[i]).round(),
    ];
    var changed = false;
    for (var i = 0; i < n; i++) {
      if (widths[i] != tc.widths[i]) changed = true;
    }
    if (changed) widget.onTableColumnWidths?.call(tc, widths);
  }

  /// A table control's text cell: one fixed font for every cell of the
  /// control, cut at the column's edge — SAP GUI clips a cell's text to its
  /// column and never scales it (SAPLSEOD/2000's methods table: a 55-
  /// character method name in its 35-cell column and a short one beside it
  /// draw at the same size). 2 points on either side keep a cell's glyphs
  /// off its neighbours' (the Level text touched the Method column). A cut
  /// cell ([clamped]) has its full text as its tooltip (on hover).
  Widget _tcText(
    ScreenField f,
    SapIconAtlas? icons,
    double w, {
    required bool clamped,
  }) {
    final text = f.text.trimRight();
    // the cell's DIAG attribute (18/9/17, the record its 18/9/5 line head
    // names): fixed-pitch unless PROPFONT, link-blue when INTENSIFY — the
    // real GUI's methods table draws Méthode / Type / Visibilité in the
    // fixed font, Description (attr 0x61) proportional, and the method
    // names of the intensified lines (0x45) blue, the others (0x41) plain
    // (a recorded session s[35], methods_tab_screenshot.png)
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontFamily: f.attr & attrPropfont != 0 ? null : 'Menlo',
      fontFamilyFallback: f.attr & attrPropfont != 0
          ? null
          : const ['Courier New', 'monospace'],
      color: f.attr & attrIntensify != 0 ? scheme.primary : null,
    );
    final cell = ClipRect(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _tcCellInset),
        child: Align(
          alignment: Alignment.centerLeft,
          child: _iconText(text, icons, clip: true, style: style),
        ),
      ),
    );
    if (!clamped) return cell;
    return Tooltip(
      message: icons?.stripTokens(text).trim() ?? text,
      // a pointer's hover: a long press stays the screen's context menu
      triggerMode: TooltipTriggerMode.manual,
      child: cell,
    );
  }

  /// The points a table control's text cell keeps clear on either side.
  static const double _tcCellInset = 2;

  /// A free text cell its row clamped below its own width
  /// ([GridCell.clamped]; a table control's cell is [_tcText]) — text
  /// past the cells it may use, which SAP GUI clips. It still shrinks to
  /// fit down to [_minCellTextScale] of its font (a proportional overrun),
  /// past that it ends in an ellipsis instead of shrinking on (to 6 points
  /// a row, the font jumping line to line); the full text is its tooltip
  /// (on hover).
  /// A table cell keeps 2 points before the next column, so its last
  /// glyph never touches it.
  Widget _clampedText(ScreenField f, SapIconAtlas? icons, double w) {
    final text = f.text.trimRight();
    final inset = f.tableControl != null ? 2.0 : 0.0;
    final room = math.max(0.0, w - inset);
    return Tooltip(
      message: icons?.stripTokens(text).trim() ?? text,
      // a pointer's hover: a long press stays the screen's context menu
      triggerMode: TooltipTriggerMode.manual,
      child: Padding(
        padding: EdgeInsets.only(right: inset),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: room / _minCellTextScale),
            child: _iconText(text, icons, clip: true, ellipsis: true),
          ),
        ),
      ),
    );
  }

  /// The smallest a clamped text cell is shrunk to ([_clampedText]).
  static const double _minCellTextScale = 0.8;

  /// What an input field keeps beside its text besides its padding, in
  /// points: the caret's margin (cursor width + gap, 3) and a point to
  /// spare (the outline's label gap is off: `gapPadding: 0`).
  static const double _fieldInsets = 4;

  /// The input font's advance per em (Menlo ~0.602), measured once.
  static double? _advance;
  static double _monoAdvance() => _advance ??= () {
    const n = 20;
    final tp = TextPainter(
      text: TextSpan(
        text: '0' * n,
        style: const TextStyle(
          fontSize: 100,
          fontFamily: 'Menlo',
          fontFamilyFallback: ['Courier New', 'monospace'],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final a = tp.width / (n * 100);
    tp.dispose();
    // only a monospace-like advance is trusted: a face that did not load
    // measures 0, the test font's square glyphs a full em — the estimate
    // stands in for either
    return a >= 0.5 && a <= 0.75 ? a : 0.62;
  }();

  /// A dropdown listbox (dynpro_listbox_view.dart): key and text, the
  /// arrow, its entries on tap when it is not display-only.
  Widget _listbox(
    ScreenField f,
    double font, {
    bool monospace = false,
    double? height,
  }) =>
      _leaf(
        (busy) => DynproListboxView(
          field: f,
          valueSet: widget.listboxValueSet?.call(f),
          onPick: widget.onListboxPick == null
              ? null
              : (key) => widget.onListboxPick!(f, key),
          busy: busy,
          fontSize: font,
          monospace: monospace,
          height: height,
        ),
      );

  /// [f] offers value help the view can ask for.
  bool _offersF4(ScreenField f) =>
      f.hasF4 && !f.isProtected && widget.onValueHelp != null;

  /// SAP GUI's F4 (matchcode) button of input [f]: inert while busy (a
  /// leaf of its own, so the field around it never redraws for a flip).
  Widget _f4Button(ScreenField f, {double? iconSize}) => _leaf(
    (busy) => IconButton(
      tooltip: 'Value help (F4)',
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      iconSize: iconSize,
      icon: const Icon(Icons.manage_search),
      onPressed: busy ? null : () => widget.onValueHelp!(f),
    ),
  );

  /// The controller and the focus node of input [key], made on first use.
  (TextEditingController, FocusNode) _inputState(String key, String text) => (
    _controllers.putIfAbsent(key, () => TextEditingController(text: text)),
    _nodeOf(key),
  );

  /// The focus node of input [key], made on first use — before its field
  /// is built when the Next key points at a cell not built yet
  /// ([_actionKey]); the field takes it over when it is.
  FocusNode _nodeOf(String key) =>
      _focusNodes.putIfAbsent(key, () => FocusNode(debugLabel: 'dynpro $key'));

  Widget _gridInput(
    ScreenField f,
    double font,
    double cw, {
    double? width,
    String? semanticsLabel,
  }) {
    final key = _cellKey(f);
    // a monospace glyph is ~0.6 em: shrink the font so the field's own
    // character count fits its painted width (a 3-cell "200" clipped)
    var chars = math.max(
      f.text.trimRight().length,
      f.mlen > 0 ? f.mlen : (f.maxnrchars > 0 ? f.maxnrchars : 1),
    );
    // a table cell shows its COLUMN's width (TC_1211's 40-char article in
    // a 20-cell column): a longer value scrolls in the cell, the font stays
    if (f.tableControl != null && width != null) {
      chars = math.min(chars, math.max(1, (width / cw).round()));
    }
    if (width != null && chars > 0) {
      // the text's room: the cell less the content padding (0.3 cw a side)
      // and what the field keeps beside its text ([_fieldInsets]) — a
      // 4-cell " 250" overflowed its box when only the padding was taken
      // off
      final room = width - cw * 0.6 - _fieldInsets;
      font = math.min(font, math.max(6.0, room / (chars * _monoAdvance())));
    }
    final (ctrl, node) = _inputState(key, f.text);
    _syncPainted(key, ctrl, f.text);
    final scheme = Theme.of(context).colorScheme;
    final f4 = _offersF4(f);
    // the Focus wrapper adds no semantics node of its own: the field's
    // EditableText exposes the focus (a phantom "focusable" stop read
    // before every input otherwise) — nor a traversal stop: a hardware
    // Tab lands in the next field's text, not on its wrapper
    return Focus(
      includeSemantics: false,
      skipTraversal: true,
      onKeyEvent: (_, e) => _inputKey(key, f, ctrl, e),
      onFocusChange: (has) {
        _typeAheadFocus(key, f, has, ctrl);
        // SAP GUI's cursor field: it stays the current field when the
        // keyboard is put away (F1 / F4 still act on it) until another
        // field takes the focus or the screen changes — a focus loss, or
        // the cursor field taking the focus again, changes nothing to draw
        if (!has) return;
        widget.onFocusField?.call(f);
        _setCursor(key);
      },
      // the cursor mark, the F4 button and the dropdown follow the cursor
      // notifier: a focus move redraws the field it left and the field it
      // lands on, not the screen
      child: _Select(
        source: _cursorN,
        select: (c) => (cursor: c.key == key, ta: c.taKey == key ? c.ta : null),
        builder: (s) {
          Widget field = TextField(
            controller: ctrl,
            focusNode: node,
            enabled: !f.isProtected,
            obscureText: f.invisible,
            maxLength: f.maxnrchars > 0 ? f.maxnrchars : null,
            textAlignVertical: TextAlignVertical.center,
            // SAP tokens, not prose: no autocorrect, no suggestions, no
            // smart punctuation, no sentence case (a phone's keyboard
            // rewrote "ekko" and split a material number)
            keyboardType: TextInputType.text,
            autocorrect: false,
            enableSuggestions: false,
            smartDashesType: SmartDashesType.disabled,
            smartQuotesType: SmartQuotesType.disabled,
            textCapitalization: TextCapitalization.none,
            inputFormatters: [_busyFormatter],
            style: TextStyle(
              fontSize: font,
              fontFamily: 'Menlo',
              fontFamilyFallback: const ['Courier New', 'monospace'],
              // no tracking: Material 3's body text adds 0.5 pt a glyph, which
              // pushed a full field's last glyph past its box
              letterSpacing: 0,
              // a display field's value reads at full contrast (Material's
              // disabled text is 38 %: ME21N's totals went grey)
              color: f.isProtected ? scheme.onSurfaceVariant : null,
            ),
            onChanged: (value) {
              _edited.add(key);
              widget.onEdit?.call(f, value);
              _typeAheadEdited(key, ctrl);
            },
            contextMenuBuilder: widget.onContextMenu == null
                ? null
                : (context, state) => _fieldTextMenu(context, state, f),
            // Next between the fields, Done on the last: the action key
            // ([_actionKey]; onSubmitted stays unset — it fires after a
            // Next too)
            textInputAction: _actionOf(key, f),
            onEditingComplete: () => _actionKey(key, f, ctrl),
            decoration: InputDecoration(
              // SAP GUI's F4 button at the right edge of the focused field
              suffixIcon: f4 && s.cursor
                  ? _f4Button(f, iconSize: font + 2)
                  : null,
              suffixIconConstraints: BoxConstraints.tightFor(
                width: font + 8,
                height: font + 6,
              ),
              isDense: true,
              counterText: '',
              filled: true,
              fillColor: f.isProtected
                  ? scheme.surfaceContainerHighest
                  : scheme.surfaceContainerLowest,
              contentPadding: EdgeInsets.symmetric(
                horizontal: cw * 0.3,
                vertical: 0,
              ),
              // gapPadding 0: the outline's label gap (4 pt a side, for a
              // floating label these fields never have) is taken off the
              // text's width — 8 pt a 2-cell field cannot spare.
              // The box of a field one can type into is drawn in
              // `outline` (3:1 against the dark page, WCAG 1.4.11 — the
              // variant was a 2:1 hairline), a display field's in the
              // quieter variant: SAP GUI's "bright box = type here"
              border: OutlineInputBorder(
                gapPadding: 0,
                borderRadius: BorderRadius.circular(3),
                borderSide: BorderSide(color: scheme.outline),
              ),
              enabledBorder: OutlineInputBorder(
                gapPadding: 0,
                borderRadius: BorderRadius.circular(3),
                // the cursor field keeps its mark without the keyboard
                borderSide: s.cursor
                    ? BorderSide(color: scheme.primary, width: 1.5)
                    : BorderSide(color: scheme.outline),
              ),
              disabledBorder: OutlineInputBorder(
                gapPadding: 0,
                borderRadius: BorderRadius.circular(3),
                borderSide: BorderSide(color: scheme.outlineVariant),
              ),
            ),
          );
          // the field's accessible name (its caption, a table column's
          // heading): a label-only wrapper merges into the field's own
          // node — "Client, text field, 100"
          if (semanticsLabel != null) {
            field = Semantics(label: semanticsLabel, child: field);
          }
          return _typeAheadAnchor(key, f, ctrl, s.ta, field);
        },
      ),
    );
  }

  Widget _gridButton(
    ScreenField f,
    SapIconAtlas? icons,
    double font, [
    double? cell,
  ]) => _leaf((busy) => _gridButtonOf(f, icons, font, busy, cell));

  Widget _gridButtonOf(
    ScreenField f,
    SapIconAtlas? icons,
    double font,
    bool busy, [
    double? cell,
  ]) {
    final enabled = !busy && (f.fcode ?? '').isNotEmpty;
    final plain = (icons?.stripTokens(f.text) ?? f.text).trim();
    final token = SapIconAtlas.tokenRx.firstMatch(f.text);
    final cp = token != null ? icons?.codepoint(token.group(1)!) : null;
    // the quick info, else (an icon-only button without one) the icon's
    // name: a long press shows it — on a touch screen the only way to learn
    // what an icon means, as SAP GUI's hover tooltip
    final tip =
        iconQuickInfo(f.text) ??
        (plain.isEmpty && token != null
            ? _iconTitle(icons?.iconName(token.group(1)!))
            : null);
    if (token == null && plain.isEmpty) {
      // a button painted without text or icon (TC_1211's status column
      // until the item has messages): an empty face, no invented bullet;
      // in a table control the flat cell SAP GUI draws
      final tap = enabled ? () => widget.onOkcode(f.fcode!) : null;
      // a table control's button cell with a quick info but no icon
      // (SAPLALDB/3000's option column before an option is chosen,
      // `@\QSélection options de sélection@`): SAP GUI's small raised
      // square, the quick info its tooltip; a bare one (TC_1211's status
      // column) stays the flat cell
      if (f.tableControl != null && tip == null) return InkWell(onTap: tap);
      if (f.tableControl != null) {
        final scheme = Theme.of(context).colorScheme;
        return Tooltip(
          message: tip,
          child: Material(
            color: scheme.surfaceContainerHigh,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: scheme.outline, width: 0.8),
              borderRadius: BorderRadius.circular(3),
            ),
            child: InkWell(
              onTap: tap,
              borderRadius: BorderRadius.circular(3),
              child: const SizedBox.expand(),
            ),
          ),
        );
      }
      return OutlinedButton(
        onPressed: tap,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        child: const SizedBox.shrink(),
      );
    }
    // the face at full contrast in both themes — the label and the icon in
    // the on-surface colour, as SAP GUI draws them black on its grey
    // button (a recorded session methods_tab_screenshot.png),
    // not the theme's primary; a disabled one greyed but still legible
    // ([dynproDisabledForeground]), not Material's 38 % on dark grey
    final scheme = Theme.of(context).colorScheme;
    // a tonal face with no outline: the 0.8-point outline rectangle around
    // a thin line-art glyph read as one more line of the glyph on the
    // iPad's dark grey (SE24's method toolbar, live 2026-10-21) — the
    // filled face sets the button off from the dynpro instead, as the
    // app's own key bar does, and the glyph stands alone on it
    final style = OutlinedButton.styleFrom(
      // an icon-only button gives its icon the whole face
      padding: EdgeInsets.symmetric(horizontal: plain.isEmpty ? 0 : 2),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: TextStyle(fontSize: font),
      foregroundColor: scheme.onSurface,
      disabledForegroundColor: dynproDisabledForeground(scheme),
      backgroundColor: scheme.surfaceContainerHighest,
      disabledBackgroundColor: scheme.surfaceContainerHigh,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    );
    final onPressed = enabled ? () => widget.onOkcode(f.fcode!) : null;
    return LayoutBuilder(
      builder: (context, box) {
        // the icon sized from the BUTTON, not from the label's font: SAP
        // GUI's 16-pixel icon fills most of its ~20-pixel button face
        // (methods_tab_screenshot.png's Paramètre / Exceptions / Code
        // srce and the icon-only row) — [dynproButtonGlyphShare] of the
        // face's height, within the two cells the icon takes of the
        // button's painted length ([cell] points each), never under the
        // label's own size
        // — and never under [dynproButtonIconEm]: the font's icons fill
        // ~77 % of their em, so a 15-point drawing needs a 20-point em, more
        // than a composed window's 15-point row (SE80's docked class
        // builder) — the icon then overflows the face into the row's
        // margin instead of shrinking with it. An icon-only button lends
        // its icon its whole width (no padding), never more: it never
        // overlaps the next field
        final iconOnly = plain.isEmpty;
        var size = box.maxHeight.isFinite
            ? box.maxHeight * dynproButtonGlyphShare
            : font + 2;
        size = math.max(size, dynproButtonIconEm);
        if (iconOnly && box.maxWidth.isFinite) {
          size = math.min(size, box.maxWidth);
        }
        size = math.max(size, font);
        final faceHeight = box.maxHeight.isFinite ? box.maxHeight : size;
        final glyphColor = enabled
            ? scheme.onSurface
            : dynproDisabledForeground(scheme);
        Widget? glyph = cp != null
            ? _boldGlyph(
                String.fromCharCode(cp),
                ValueKey('button-glyph-${token!.group(1)}'),
                size,
                glyphColor,
              )
            : (token != null
                  ? Icon(Icons.more_horiz, size: size, color: glyphColor)
                  : null);
        if (glyph != null && size > faceHeight) {
          // taller than the face: laid out at the face's height (the
          // label's FittedBox must not shrink it back), painted at its own
          glyph = SizedBox(
            width: size,
            height: faceHeight,
            child: OverflowBox(
              maxWidth: size,
              maxHeight: size,
              child: glyph,
            ),
          );
        }
        // the room inside the frame (2 points of padding a side)
        final inner = box.maxWidth.isFinite ? box.maxWidth - 4 : null;
        final glyphPart = glyph != null ? size + _glyphGap : 0.0;
        if (inner != null && glyph != null && plain.isNotEmpty) {
          final text = TextPainter(
            text: TextSpan(
              text: plain,
              style: DefaultTextStyle.of(context).style
                  .merge(TextStyle(fontSize: font)),
            ),
            maxLines: 1,
            textDirection: TextDirection.ltr,
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          final natural = text.width;
          text.dispose();
          if (inner < glyphPart + natural * _minButtonTextScale) {
            // a button shorter than its text (GO_DETAIL clamped to 3 cells
            // by the next button, `@3R\QPasser aux propriétés@ Propriétés`):
            // SAP GUI clips the text at the button's edge, icon first, so
            // the icon alone, at full size — not the whole face shrunk to
            // a 3-point glyph and a 2.6-point label; the text stays its
            // tooltip and its accessible name
            return Tooltip(
              message: tip ?? plain,
              child: Semantics(
                label: plain,
                child: OutlinedButton(
                  onPressed: onPressed,
                  style: style,
                  child: ExcludeSemantics(
                    child: FittedBox(fit: BoxFit.scaleDown, child: glyph),
                  ),
                ),
              ),
            );
          }
        }
        // the label bounded so it never shrinks below
        // [_minButtonTextScale] of its font: past that it ends in an
        // ellipsis (under the FittedBox alone a Flexible gets no bound)
        final maxText = inner != null
            ? ((inner - (glyph != null ? glyphPart : 0)) / _minButtonTextScale)
                  .clamp(0.0, double.infinity)
            : double.infinity;
        return Tooltip(
          message: tip ?? '',
          child: OutlinedButton(
            onPressed: onPressed,
            style: style,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ?glyph,
                  if (glyph != null && plain.isNotEmpty)
                    const SizedBox(width: _glyphGap),
                  if (plain.isNotEmpty)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxText),
                      child: Text(
                        plain,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// A pushbutton's icon-font glyph drawn heavier than the font's hairline
  /// strokes: the fill (the keyed text, its own colour — nothing dims it)
  /// over the same glyph stroked [dynproGlyphStroke] of its em, so the
  /// 14-point icon on a dark face reads as SAP GUI's 16-pixel bitmap does,
  /// not as a pencil sketch (SE24's method toolbar, live 2026-10-21).
  static Widget _boldGlyph(String ch, Key key, double size, Color color) {
    final base = TextStyle(fontFamily: 'SapIcons', fontSize: size, height: 1);
    return Stack(
      alignment: Alignment.center,
      children: [
        Text(
          ch,
          semanticsLabel: '',
          style: base.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = size * dynproGlyphStroke
              ..strokeJoin = StrokeJoin.round
              ..color = color,
          ),
        ),
        Text(ch, key: key, style: base.copyWith(color: color)),
      ],
    );
  }

  /// `ICON_SEARCH_NEXT` as "Search next"; null for none.
  static String? _iconTitle(String? name) {
    if (name == null || name.isEmpty) return null;
    final words = name.replaceFirst(RegExp('^ICON_'), '').toLowerCase();
    final t = words.replaceAll('_', ' ').trim();
    return t.isEmpty ? null : t[0].toUpperCase() + t.substring(1);
  }

  /// The gap between a pushbutton's icon and its label, in points (SAP
  /// GUI's 2–3 pixels).
  static const double _glyphGap = 3;

  /// The smallest a pushbutton's label is shrunk to fit its button (of its
  /// font size): past it the label ends in an ellipsis, or a button with an
  /// icon shows the icon alone.
  static const double _minButtonTextScale = 0.8;

  /// [child] answering a double tap on [f] with [DynproView.onDoubleClick]
  /// (a [Listener]: the child keeps every gesture of its own — an input's
  /// focus and selection, a list's scroll).
  Widget _doubleTappable(ScreenField f, Widget child, {bool enabled = true}) {
    final cb = widget.onDoubleClick;
    if (cb == null || !enabled) return child;
    return DoubleTapListener(
      onDoubleTap: () {
        if (!_busyNow) cb(f);
      },
      child: child,
    );
  }

  /// A protected icon field ([isIconOutput]): the glyph, its quick info as
  /// the tooltip.
  Widget _iconOutput(
    ScreenField f,
    SapIconAtlas? icons,
    double font,
    double height,
  ) {
    final token = SapIconAtlas.tokenRx.firstMatch(f.text);
    final cp = token == null ? null : icons?.codepoint(token.group(1)!);
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: iconQuickInfo(f.text) ?? '',
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant, width: 0.6),
          borderRadius: BorderRadius.circular(3),
        ),
        child: cp != null
            ? Text(
                String.fromCharCode(cp),
                style: TextStyle(fontFamily: 'SapIcons', fontSize: font + 1),
              )
            : Text(
                token?.group(1) ?? '',
                style: TextStyle(fontSize: font * 0.8),
              ),
      ),
    );
  }

  /// A choice on the grid: the box / button and its caption read as ONE
  /// element (the merge sits outside the InkWell, as Flutter's own
  /// CheckboxListTile does: inside, its tap action would be forced out
  /// into the cell around it). A bare box (a table control's column) has
  /// no caption to merge: [semanticsLabel] names it by its column.
  Widget _gridChoice(
    ScreenField f,
    double font,
    double ch,
    Widget leading,
    VoidCallback? onTap, {
    String? semanticsLabel,
  }) {
    final text = _choiceText(f);
    if (text.isEmpty) {
      // a bare box (a table control's checkbox column): it fits its cells
      Widget box = InkWell(
        onTap: onTap,
        child: FittedBox(child: leading),
      );
      if (semanticsLabel != null) {
        box = Semantics(label: semanticsLabel, child: box);
      }
      return MergeSemantics(child: box);
    }
    return MergeSemantics(
      child: InkWell(
        onTap: onTap,
        child: Row(
          children: [
            SizedBox(
              width: ch,
              height: ch,
              child: FittedBox(child: leading),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: font),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _gridRadio(
    ScreenField f,
    List<ScreenField> group,
    double font,
    double ch,
    bool busy, {
    String? semanticsLabel,
  }) {
    ScreenField? current =
        widget.radioSelection != null && group.contains(widget.radioSelection)
        ? widget.radioSelection
        : null;
    if (current == null) {
      final painted = group.where((f) => f.on).toList();
      current = painted.isNotEmpty ? painted.first : null;
    }
    final enabled =
        !busy && (widget.onRadio != null || widget.onRadioTap != null);
    void choose() {
      if (widget.onRadio != null) {
        widget.onRadio!(group, f);
      } else {
        widget.onRadioTap?.call(group, f);
      }
    }

    return _gridChoice(
      f,
      font,
      ch,
      // ignore: deprecated_member_use
      Radio<ScreenField>(
        value: f,
        // ignore: deprecated_member_use
        groupValue: current,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        // ignore: deprecated_member_use
        onChanged: enabled ? (_) => choose() : null,
      ),
      enabled ? choose : null,
      semanticsLabel: semanticsLabel,
    );
  }

  /// The heading of table-control cell [f]'s column, as the control paints
  /// it ("Pos", "UA"), else the column's DDIC title; '' outside a control.
  static String _tcHeading(
    ScreenField f,
    Map<String, TableControlInfo> tcs,
    SapIconAtlas? icons,
  ) {
    final tc = tcs[f.tableControl];
    if (tc == null) return '';
    final i = (f.tcColumn ?? 0) - 1;
    if (i < 0) return '';
    var h = i < tc.headings.length ? tc.headings[i] : '';
    if (h.trim().isEmpty && i < tc.titles.length) h = tc.titles[i];
    return (icons?.stripTokens(h) ?? h.replaceAll(SapIconAtlas.tokenRx, ''))
        .trim();
  }

  /// The accessible name of table-control cell [f]: its column's heading
  /// and its line ("Quantity, line 3" — what SAP GUI's own accessibility
  /// layer exposes for a cell; the cell to its left is a VALUE, never a
  /// caption), else the field's name, else the line alone; null outside a
  /// table control.
  static String? _tcCellName(
    ScreenField f,
    Map<String, TableControlInfo> tcs,
    SapIconAtlas? icons,
  ) {
    if (f.tableControl == null) return null;
    final h = _tcHeading(f, tcs, icons);
    if (h.isNotEmpty) return '$h, line ${f.tcLine}';
    final n = (f.name ?? '').trim();
    return n.isNotEmpty ? n : 'Line ${f.tcLine}';
  }

  /// The accessible name of input [f] — what a screen reader says before
  /// "text field": a table cell's column ([_tcCellName]); else the label
  /// the fold paired with the field, else the caption the layout paired
  /// (the nearest text to its left, its icon tokens stripped), else the
  /// technical name; null when there is none.
  static String? _accessibleName(
    ScreenField f,
    DynproLayout layout,
    Map<String, TableControlInfo> tcs,
    SapIconAtlas? icons,
  ) {
    final cell = _tcCellName(f, tcs, icons);
    if (cell != null) return cell;
    var s = f.label.trim();
    if (s.isEmpty) {
      final cap = layout.captionOf[f];
      if (cap != null) {
        s = (icons?.stripTokens(cap.text) ??
                cap.text.replaceAll(SapIconAtlas.tokenRx, ''))
            .trim();
      }
    }
    if (s.isEmpty) s = (f.name ?? '').trim();
    return s.isEmpty ? null : s;
  }

  Widget _buildRows(
    BuildContext context,
    DynproLayout layout,
    Map<String, List<ScreenField>> radioGroups,
    SapIconAtlas? icons,
    double maxWidth,
  ) {
    if (layout.rows.isEmpty) {
      // a list, a hosted control: the screen is painted, just not by
      // dynpro fields
      final m = widget.model;
      if (m.listPaint.isNotEmpty ||
          m.listLines.isNotEmpty ||
          widget.controls.isNotEmpty ||
          m.netPlans.isNotEmpty) {
        return const SizedBox.shrink();
      }
      // an inline GRAPH item whose graph is not whole yet (its
      // continuation not received) or holds no node: say so, not "nothing";
      // only a NETZ stream is a network graph — a classic business /
      // statistics graphic (BUSG / STAT) gets a neutral slot of its own
      final graph = m.inlineGraph;
      final network = graph?.kind == InlineGraphKind.network;
      final what = network ? 'network graph' : 'classic graphic';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          graph == null
              ? '(nothing painted on this screen)'
              : !graph.complete
                  ? '($what incomplete: ${graph.length} bytes received)'
                  : network
                      ? '(network graph without nodes)'
                      : '(classic graphic ${graph.interface ?? ''})'
                          .replaceFirst(' )', ')'),
          textAlign: TextAlign.center,
        ),
      );
    }
    final frames =
        widget.model.frames.where((f) => f.text.trim().isNotEmpty).toList()
          ..sort((a, b) => a.row.compareTo(b.row));
    var frameIx = 0;
    final children = <Widget>[];
    DynproRow? prev;
    for (final r in layout.rows) {
      // group-box titles head the rows they frame
      while (frameIx < frames.length && frames[frameIx].row <= r.row) {
        children.add(_FrameTitle(frames[frameIx].text.trim()));
        frameIx++;
      }
      // a painted blank line keeps a little air between the rows
      if (prev != null && prev.area == r.area && r.row - prev.row > 1) {
        children.add(const SizedBox(height: 10));
      }
      children.add(
        Padding(
          padding: EdgeInsets.symmetric(vertical: r.hasInteractive ? 3 : 2),
          child: _rowWidget(context, r, layout, radioGroups, icons, maxWidth),
        ),
      );
      prev = r;
    }
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
    if (!layout.rows.any((r) => r.hasInteractive)) {
      return column; // text only: no form chrome
    }
    return Card(
      elevation: widget.compact ? 0 : null,
      child: Padding(
        padding: EdgeInsets.all(widget.compact ? 8 : 12),
        child: column,
      ),
    );
  }

  /// One painted row, the reference client's geometry reflowed for a phone: the
  /// leading caption keeps a column aligned to its input's painted column
  /// (SE16's labels at col 2, inputs at col 34), the field group after it is
  /// a Row whose inputs shrink in proportion to their mlen before the group
  /// drops under the caption. Text-only rows simply wrap.
  Widget _rowWidget(
    BuildContext context,
    DynproRow r,
    DynproLayout layout,
    Map<String, List<ScreenField>> radioGroups,
    SapIconAtlas? icons,
    double maxWidth,
  ) {
    Widget cellOf(ScreenField f) =>
        _cell(context, f, layout, radioGroups, icons, maxWidth);
    if (!r.hasInteractive) {
      return Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [for (final f in r.cells) cellOf(f)],
      );
    }
    final cells = r.cells;
    ScreenField? lead;
    if (cells.length > 1 && layout.captions.contains(cells.first)) {
      lead = cells.first;
    }
    final rest = lead == null ? cells : cells.sublist(1);
    final groupChildren = <Widget>[
      for (final f in rest)
        if (_isEditable(f))
          Flexible(flex: _inputChars(f), child: cellOf(f))
        else if (_isText(f) && f.text.trim().length > 40)
          Flexible(flex: 40, child: cellOf(f))
        else if (f.kind == FieldKind.radio || f.kind == FieldKind.checkbox)
          // a choice's label wraps rather than overflow (the wall's French
          // options on a 402 px phone: 256 / 274 px past the dialog)
          Flexible(flex: f.text.trim().length.clamp(1, 80), child: cellOf(f))
        else
          cellOf(f),
    ];
    // a row of choices wider than the phone (SM37's six job-status boxes,
    // a selection screen's option row) flows onto further lines, each box
    // with its whole caption: squeezed into one Row the captions wrapped
    // letter by letter beside overflowing 48 pt boxes
    final choicesOnly = rest.isNotEmpty &&
        rest.every(
          (f) => f.kind == FieldKind.radio || f.kind == FieldKind.checkbox,
        );
    var choiceWidth = 0.0;
    if (choicesOnly) {
      for (final f in rest) {
        choiceWidth += 48 + _choiceText(f).length * 8.0 + 8;
      }
    }
    final flowChoices = choicesOnly && rest.length > 1 && choiceWidth > maxWidth;
    Widget choiceFlow() => Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [for (final f in rest) cellOf(f)],
    );
    if (lead == null) {
      if (flowChoices) return choiceFlow();
      return Row(spacing: 8, children: groupChildren);
    }
    // the caption column: the painted distance to its input, in cells
    final target = layout.captionOf.entries
        .where((e) => e.value == lead)
        .map((e) => e.key)
        .first;
    final colWidth = ((target.col - lead.col) * 8.0).clamp(0.0, maxWidth * 0.4);
    final caption = ConstrainedBox(
      constraints: BoxConstraints(minWidth: colWidth),
      child: cellOf(lead),
    );
    // does the painted row fit on one line? (estimated from the geometry:
    // a text cell ~8 px per character, an input its mlen width, a button 48)
    var estimate = colWidth.clamp(lead.text.trim().length * 8.0, maxWidth);
    for (final f in rest) {
      estimate += 8;
      if (_isEditable(f)) {
        // an F4 field carries its button ([_input] paints it so)
        estimate += _inputChars(f) * 9.0 + 32 + (_offersF4(f) ? 44 : 0);
      } else if (_isText(f)) {
        estimate += f.text.trim().length * 8.0 + 8;
      } else {
        estimate += 48 + f.text.trim().length * 8.0;
      }
    }
    if (estimate <= maxWidth && !flowChoices) {
      return Row(spacing: 8, children: [caption, ...groupChildren]);
    }
    // too wide: the caption heads its own line, the fields shrink below it
    // (a row of choices flows instead)
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(bottom: 2), child: caption),
        if (flowChoices) choiceFlow() else Row(spacing: 8, children: groupChildren),
      ],
    );
  }

  Widget _cell(
    BuildContext context,
    ScreenField f,
    DynproLayout layout,
    Map<String, List<ScreenField>> radioGroups,
    SapIconAtlas? icons,
    double maxWidth,
  ) {
    final scheme = Theme.of(context).colorScheme;
    switch (f.kind) {
      case FieldKind.label:
      case FieldKind.output:
        final caption = layout.captions.contains(f);
        return _doubleTappable(
          f,
          enabled: f.tableControl != null,
          _iconText(
            f.text.trim(),
            icons,
            style: caption
                ? TextStyle(color: scheme.onSurfaceVariant)
                : TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
          ),
        );
      case FieldKind.input when isIconOutput(f):
        return _doubleTappable(f, _iconOutput(f, icons, 15, 26));
      case FieldKind.input:
        return _doubleTappable(
          f,
          _input(
            f,
            layout.captionOf.containsKey(f),
            maxWidth,
            semanticsLabel: _accessibleName(f, layout, const {}, icons),
          ),
        );
      case FieldKind.combobox:
        return _doubleTappable(
          f,
          ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: 64,
              maxWidth: (_inputChars(f) * 9.0 + 40).clamp(
                64.0,
                maxWidth.clamp(64.0, 440.0),
              ),
            ),
            child: _listbox(f, 14, height: 36),
          ),
        );
      case FieldKind.checkbox:
        return _leaf(
          (busy) => _Select(
            source: _boxTick,
            select: (_) => _boxTicks[f] ?? f.on,
            builder: (on) {
              final enabled = !busy && !f.isProtected;
              return _Choice(
                leading: Checkbox(
                  value: on,
                  onChanged: enabled ? (_) => _tickBox(f) : null,
                ),
                text: _choiceText(f),
                onTap: enabled ? () => _tickBox(f) : null,
              );
            },
          ),
        );
      case FieldKind.radio:
        final group = radioGroups['${f.area}:${f.block}:${f.group}'] ?? [f];
        return _leaf((busy) => _radio(f, group, busy));
      case FieldKind.pushbutton:
        return _leaf((busy) => _button(f, icons, busy));
      case FieldKind.tabstrip:
        return _leaf(
          (busy) => ChoiceChip(
            label: Text(icons?.stripTokens(f.text).trim() ?? f.text),
            selected: f.on,
            onSelected: (busy || (f.fcode ?? '').isEmpty)
                ? null
                : (_) => widget.onOkcode(f.fcode!),
          ),
        );
    }
  }

  Widget _radio(ScreenField f, List<ScreenField> group, bool busy) {
    // an explicit selection wins; else the painted-ON member
    ScreenField? current =
        widget.radioSelection != null && group.contains(widget.radioSelection)
        ? widget.radioSelection
        : null;
    if (current == null) {
      final painted = group.where((f) => f.on).toList();
      current = painted.isNotEmpty ? painted.first : null;
    }
    final enabled =
        !busy && (widget.onRadio != null || widget.onRadioTap != null);
    void choose() {
      if (widget.onRadio != null) {
        widget.onRadio!(group, f);
      } else {
        widget.onRadioTap?.call(group, f);
      }
    }

    return _Choice(
      // ignore: deprecated_member_use
      leading: Radio<ScreenField>(
        value: f,
        // ignore: deprecated_member_use
        groupValue: current,
        // ignore: deprecated_member_use
        onChanged: enabled ? (_) => choose() : null,
      ),
      text: _choiceText(f),
      onTap: enabled ? choose : null,
    );
  }

  Widget _button(ScreenField f, SapIconAtlas? icons, bool busy) {
    final enabled = !busy && (f.fcode ?? '').isNotEmpty;
    final onPressed = enabled ? () => widget.onOkcode(f.fcode!) : null;
    final tip = iconQuickInfo(f.text);
    final plain = (icons?.stripTokens(f.text) ?? f.text).trim();
    final token = SapIconAtlas.tokenRx.firstMatch(f.text);
    final cp = token != null ? icons?.codepoint(token.group(1)!) : null;
    if (plain.isEmpty && token != null) {
      // an icon-only button: the reference client's selection-screen arrow
      return IconButton.filledTonal(
        tooltip: tip,
        onPressed: onPressed,
        icon: cp != null
            ? Text(
                String.fromCharCode(cp),
                style: const TextStyle(fontFamily: 'SapIcons', fontSize: 20),
              )
            : const Icon(Icons.more_horiz),
      );
    }
    return Tooltip(
      message: tip ?? '',
      child: FilledButton.tonal(
        onPressed: onPressed,
        child: Text(plain.isEmpty ? (tip ?? '•') : plain),
      ),
    );
  }

  Widget _input(
    ScreenField f,
    bool captioned,
    double maxWidth, {
    String? semanticsLabel,
  }) {
    final key = _cellKey(f);
    final (ctrl, node) = _inputState(key, f.text);
    _syncPainted(key, ctrl, f.text);
    // the reflow has no focused-field button: every F4 field carries its
    // matchcode button (SAP's most used help; the text-selection toolbar
    // was its only touch route), its width budgeted so a 4-character
    // order type keeps room for its text
    final f4 = _offersF4(f);
    // the painted width: mlen (or the type's max) in character cells; a
    // Flexible parent may shrink it, never widen it
    final width = (_inputChars(f) * 9.0 + 32 + (f4 ? 44 : 0)).clamp(
      64.0,
      maxWidth.clamp(64.0, 440.0),
    );
    Widget field(TypeAheadController? ta) {
      Widget w = TextField(
        controller: ctrl,
        focusNode: node,
        enabled: !f.isProtected,
        obscureText: f.invisible,
        // SAP tokens, not prose: no autocorrect, no suggestions, no smart
        // punctuation, no sentence case
        keyboardType: TextInputType.text,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        textCapitalization: TextCapitalization.none,
        inputFormatters: [_busyFormatter],
        onChanged: (value) {
          _edited.add(key);
          widget.onEdit?.call(f, value);
          _typeAheadEdited(key, ctrl);
        },
        contextMenuBuilder: widget.onContextMenu == null
            ? null
            : (context, state) => _fieldTextMenu(context, state, f),
        // Next between the fields, Done on the last: the action key
        // ([_actionKey]; onSubmitted stays unset — it fires after a Next
        // too)
        textInputAction: _actionOf(key, f),
        onEditingComplete: () => _actionKey(key, f, ctrl),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 10,
          ),
          suffixIcon: f4 ? _f4Button(f) : null,
          // a finger-sized button; the field grows to it
          suffixIconConstraints: f4
              ? const BoxConstraints(minWidth: 44, minHeight: 44)
              : null,
          // a field without a painted caption shows its name as the hint
          hintText: !captioned && (f.name ?? '').isNotEmpty ? f.name : null,
          hintStyle: TextStyle(color: Colors.blueGrey.shade400, fontSize: 12),
        ),
      );
      // a captioned field's accessible name; an uncaptioned one is named
      // by its hint while empty (a name twice otherwise) — one holding a
      // value stays unnamed, a known gap
      if (captioned && semanticsLabel != null) {
        w = Semantics(label: semanticsLabel, child: w);
      }
      return _typeAheadAnchor(key, f, ctrl, ta, w);
    }

    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: 48, maxWidth: width),
      // no semantics node, no traversal stop of its own (the grid's
      // wrapper above says why)
      child: Focus(
        includeSemantics: false,
        skipTraversal: true,
        onKeyEvent: (_, e) => _inputKey(key, f, ctrl, e),
        onFocusChange: (has) {
          _typeAheadFocus(key, f, has, ctrl);
          // the reflow's field is the cursor field too: hardware F1 / F4
          // and the screen menu act on it
          if (!has) return;
          widget.onFocusField?.call(f);
          _setCursor(key);
        },
        child: _Select(
          source: _cursorN,
          select: (c) => c.taKey == key ? c.ta : null,
          builder: field,
        ),
      ),
    );
  }
}

/// A leaf drawn from one slice of a notifier's value: [builder] gets
/// [select] of [source]'s value and rebuilds only when that slice changes
/// (the [_ListCursorLine] pattern) — a focus move redraws two fields, a
/// checkbox tick one box, not the view.
class _Select<S, T> extends StatefulWidget {
  const _Select({
    required this.source,
    required this.select,
    required this.builder,
  });

  final ValueListenable<S> source;
  final T Function(S value) select;
  final Widget Function(T selected) builder;

  @override
  State<_Select<S, T>> createState() => _SelectState<S, T>();
}

class _SelectState<S, T> extends State<_Select<S, T>> {
  late T _last;

  @override
  void initState() {
    super.initState();
    widget.source.addListener(_changed);
  }

  @override
  void didUpdateWidget(_Select<S, T> old) {
    super.didUpdateWidget(old);
    if (!identical(old.source, widget.source)) {
      old.source.removeListener(_changed);
      widget.source.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.source.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (widget.select(widget.source.value) != _last) setState(() {});
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(_last = widget.select(widget.source.value));
}

/// A checkbox drawn as a glyph: a table control's checkbox column (and a
/// classic list's), where a Material toggle's animation controllers, focus
/// node and ripple per cell buy nothing — the tap is the cell's own. Its
/// states keep Material's colours; a screen reader hears the state.
class SapCheckGlyph extends StatelessWidget {
  const SapCheckGlyph({
    super.key,
    required this.on,
    required this.enabled,
    required this.size,
  });

  final bool on;
  final bool enabled;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      checked: on,
      enabled: enabled,
      child: Icon(
        on ? Icons.check_box : Icons.check_box_outline_blank,
        size: size,
        color: !enabled
            ? scheme.onSurface.withValues(alpha: 0.38)
            : on
                ? scheme.primary
                : scheme.onSurfaceVariant,
      ),
    );
  }
}

/// An input's painted width in character cells (mlen, else the type's max).
int _inputChars(ScreenField f) =>
    (f.mlen > 0 ? f.mlen : (f.maxnrchars > 0 ? f.maxnrchars : 20)).clamp(3, 40);

/// A text run with its `@xx@` icon tokens drawn as icon-font glyphs; plain
/// [Text] when the run carries none.
Widget _iconText(
  String text,
  SapIconAtlas? icons, {
  TextStyle? style,
  bool clip = false,
  bool ellipsis = false,
}) {
  final overflow = clip
      ? (ellipsis ? TextOverflow.ellipsis : TextOverflow.clip)
      : null;
  final maxLines = clip ? 1 : null;
  final softWrap = clip ? false : null;
  if (!SapIconAtlas.tokenRx.hasMatch(text)) {
    return Text(
      text,
      style: style,
      overflow: overflow,
      maxLines: maxLines,
      softWrap: softWrap,
    );
  }
  final spans = <InlineSpan>[];
  var at = 0;
  for (final m in SapIconAtlas.tokenRx.allMatches(text)) {
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
    final cp = icons?.codepoint(m.group(1)!);
    if (cp != null) {
      spans.add(
        TextSpan(
          text: String.fromCharCode(cp),
          style: const TextStyle(fontFamily: 'SapIcons'),
        ),
      );
    }
    at = m.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return Text.rich(
    TextSpan(children: spans, style: style),
    overflow: overflow,
    maxLines: maxLines,
    softWrap: softWrap,
  );
}

class _Choice extends StatelessWidget {
  const _Choice({required this.leading, required this.text, this.onTap});
  final Widget leading;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // the box / button and its caption read as one element (the merge
    // outside the InkWell, as CheckboxListTile does)
    return MergeSemantics(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            leading,
            // the row bounds it (a Flexible cell): a long label wraps
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FrameTitle extends StatelessWidget {
  const _FrameTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

/// The left-side informational text block.
class TextPanel extends StatelessWidget {
  const TextPanel({super.key, required this.text, this.compact = false});

  final String text;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final icons = SapIconAtlasStrip.of(context);
    final stripped = icons?.stripTokens(text) ?? text;
    return Container(
      padding: EdgeInsets.all(compact ? 8 : 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        stripped.trim(),
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          height: 1.35,
        ),
      ),
    );
  }
}

/// Inherited icon atlas so widgets can strip @xx@ tokens.
class SapIconAtlasStrip extends InheritedWidget {
  const SapIconAtlasStrip({
    super.key,
    required this.atlas,
    required super.child,
  });

  final SapIconAtlas? atlas;

  static SapIconAtlas? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SapIconAtlasStrip>()?.atlas;

  @override
  bool updateShouldNotify(SapIconAtlasStrip old) => old.atlas != atlas;
}

/// A dynpro group box on the grid: a thin rounded border, its title cut
/// into the top edge (the real GUI's frame). The border leaves a gap under
/// the title rather than masking it with a surface colour: the grid is
/// drawn on the page, in a popup and in a composed pane, each its own
/// surface (a scaffold-coloured patch sat behind every title in a popup).
class _GridFrame extends StatelessWidget {
  const _GridFrame({required this.title, required this.fontSize});
  final String title;
  final double fontSize;

  /// Where the title starts on the frame's edge.
  static const double _titleLeft = 12;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      color: scheme.primary,
    );
    double? titleWidth;
    if (title.isNotEmpty) {
      // measured as the Text draws it (the same text scaling)
      final tp = TextPainter(
        text: TextSpan(text: title, style: style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      titleWidth = tp.width;
      tp.dispose();
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _FrameBorderPainter(
              color: scheme.outlineVariant,
              gapStart: titleWidth == null ? null : _titleLeft,
              gapExtent: titleWidth ?? 0,
            ),
          ),
        ),
        if (title.isNotEmpty)
          Positioned(
            left: _titleLeft,
            top: -fontSize * 0.75,
            child: Text(title, style: style),
          ),
      ],
    );
  }
}

/// The frame's border with the floating-label cut Flutter's outline border
/// draws: a gap of [gapExtent] (plus the outline's own padding a side) from
/// [gapStart]; no gap without a title.
class _FrameBorderPainter extends CustomPainter {
  const _FrameBorderPainter({
    required this.color,
    required this.gapStart,
    required this.gapExtent,
  });

  final Color color;
  final double? gapStart;
  final double gapExtent;

  @override
  void paint(Canvas canvas, Size size) {
    OutlineInputBorder(
      borderSide: BorderSide(color: color),
      borderRadius: BorderRadius.circular(4),
      gapPadding: 4,
    ).paint(
      canvas,
      Offset.zero & size,
      gapStart: gapStart,
      gapExtent: gapExtent,
      gapPercentage: 1.0,
      // DIAG cells are left to right whatever the locale
      textDirection: TextDirection.ltr,
    );
  }

  @override
  bool shouldRepaint(_FrameBorderPainter old) =>
      old.color != color ||
      old.gapStart != gapStart ||
      old.gapExtent != gapExtent;
}

/// One tab of a tabstrip's tab bar.
class _GridTab extends StatelessWidget {
  const _GridTab({
    required this.text,
    required this.active,
    required this.fontSize,
    this.onTap,
  });
  final String text;
  final bool active;
  final double fontSize;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: active ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

/// A radio / checkbox caption: the parser's bare label (its event id
/// stripped), else the wire text, else the field name.
String _choiceText(ScreenField f) {
  if (f.label.trim().isNotEmpty) return f.label.trim();
  if (f.text.trim().isNotEmpty) return f.text.trim();
  // a table control's checkbox column has its heading, never a caption:
  // the field name is no text SAP GUI paints (MEPO1211-IUID_RELEVANT)
  if (f.tableControl != null) return '';
  return f.name ?? '';
}

/// A table control's column geometry in cells: the server's widths
/// (18/9/14) and offsets, with the widths the user dragged ([over], column
/// index -> cells) in their place — every column after a resized one moves
/// by as much, as SAP GUI's header drag pushes the columns to its right.
/// The columns stand in the control's DISPLAY order
/// ([TableControlInfo.order]: a column the user moved, mirrored by the
/// server — a recorded session s[40]).
class _TcCols {
  _TcCols(this.tc, Map<int, double>? over) : over = over ?? const {} {
    final n = count;
    final o = tc.order;
    final valid = o.length == n && o.every((i) => i >= 0 && i < n);
    for (var p = 0; p < n; p++) {
      _byPos.add(valid ? o[p] : p);
    }
    _shift.addAll(List.filled(n, 0.0));
    _pos.addAll(List.filled(n, 0));
    var shift = 0.0;
    for (var p = 0; p < n; p++) {
      final i = _byPos[p];
      _shift[i] = shift;
      _pos[i] = p;
      final w = this.over[i];
      if (w != null) shift += w - tc.widths[i];
    }
  }

  final TableControlInfo tc;
  final Map<int, double> over;
  final List<double> _shift = [];
  final List<int> _byPos = [];
  final List<int> _pos = [];

  int get count => math.min(tc.columnOffsets.length, tc.widths.length);

  /// The column drawn at display position [p].
  int at(int p) => _byPos[p];

  /// Column [i]'s display position (its index past the catalog).
  int position(int i) => i >= 0 && i < _pos.length ? _pos[i] : i;

  /// Column [i]'s width: the dragged one, else the server's.
  double width(int i) => over[i] ?? tc.widths[i].toDouble();

  /// Column [i]'s left cell after the resized columns before it.
  double left(int i) => tc.columnOffsets[i] + _shift[i];

  /// How far column [i]'s cells move (0 for a column past the catalog).
  double shift(int i) => i >= 0 && i < _shift.length ? _shift[i] : 0;

  /// Whether the user resized column [i].
  bool resized(int i) => over.containsKey(i);
}

/// The gap between a table control's cell boxes and header buttons, in
/// points: the control's grid (the real GUI's white seams between its
/// filled cells — a recorded session
/// methods_tab_screenshot.png).
const double _tcGap = 1;

/// The cell boxes of [tc]'s data lines — every column × visible line, in
/// the coordinates of the control's fixed layer (from the window's left
/// edge and the control's top row) or, [moving], of its scrolled content
/// (from the scroll origin [sc]). A vertical gap separates the columns when
/// the control declares vertical grid lines, a horizontal one the lines
/// when it declares horizontal ones ([TableControlInfo.verticalLines] /
/// [TableControlInfo.horizontalLines], 18/9/14 byte 35 — both on
/// SAPLSEOD/MC); without them the boxes join.
List<Rect> _tcCellRects(
  TableControlInfo tc,
  _TcCols cols,
  _TcScroll? sc,
  double cw,
  double ch, {
  required bool moving,
}) {
  final out = <Rect>[];
  final vGap = tc.verticalLines ? _tcGap : 0.0;
  final hGap = tc.horizontalLines ? _tcGap : 0.0;
  for (var i = 0; i < cols.count; i++) {
    final moves = sc != null && cols.position(i) >= sc.fixed;
    if (moves != moving) continue;
    final x = (cols.left(i) - (moving ? sc!.left : 0)) * cw;
    final w = cols.width(i) * cw - vGap;
    if (w <= 0) continue;
    for (var line = 1; line <= tc.visibleRows; line++) {
      final top = (tc.lineRow(line) - tc.row) * ch;
      out.add(Rect.fromLTWH(x, top, w, ch - hGap));
    }
  }
  return out;
}

/// Paints a table control's cell boxes ([_tcCellRects]) in [fill].
///
/// The boxes are derived when painted, not when the painter is made, and
/// [shouldRepaint] compares what they derive from — the cell size, the
/// control's rows and grid lines, the scroll origin and each column's
/// place and width, O(columns) — not the columns x lines rectangles,
/// which every turn built twice (the new list, and the old one to compare
/// against) for a control that had not changed.
class _TcGridPainter extends CustomPainter {
  _TcGridPainter(
    this.tc,
    this.cols,
    this.sc,
    this.cw,
    this.ch,
    this.fill, {
    required this.moving,
  });
  final TableControlInfo tc;
  final _TcCols cols;
  final _TcScroll? sc;
  final double cw, ch;
  final Color fill;
  final bool moving;

  /// The boxes, derived once when first painted.
  late final List<Rect> cells = _tcCellRects(
    tc,
    cols,
    sc,
    cw,
    ch,
    moving: moving,
  );

  /// What [cells] derives from, as one list of numbers.
  late final List<double> _derivedFrom = [
    cw,
    ch,
    moving ? 1 : 0,
    tc.visibleRows.toDouble(),
    tc.headerRows.toDouble(),
    tc.verticalLines ? 1 : 0,
    tc.horizontalLines ? 1 : 0,
    sc?.left ?? -1,
    (sc?.fixed ?? -1).toDouble(),
    for (var i = 0; i < cols.count; i++) ...[
      cols.left(i),
      cols.width(i),
      cols.position(i).toDouble(),
    ],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = fill;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final r in cells) {
      canvas.drawRect(r, p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TcGridPainter old) =>
      old.fill != fill || !listEquals(old._derivedFrom, _derivedFrom);
}

/// The real GUI's paging keys in a table control (a recorded session
/// resize g[28]: SES `50 52`).
const int _vkeyPageUp = 81, _vkeyPageDown = 82;

/// A table control's vertical scroll bar: the thumb at the server's first
/// row of its model rows, as long as a page; a tap above it pages up, below
/// it down ([onPage] with the vkey). The thumb itself does not drag: the
/// Windows GUI's scroll to an arbitrary row is unrecorded.
class _TcPageBar extends StatelessWidget {
  const _TcPageBar({
    required this.total,
    required this.first,
    required this.rows,
    required this.onPage,
  });

  final int total, first, rows;
  final void Function(int vkey) onPage;

  /// The bar's width in points (a finger's tap on the track).
  static const double width = 14;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, cons) {
        final h = cons.maxHeight;
        final n = math.max(total, 1);
        final len = (h * rows / n).clamp(math.min(24.0, h), h).toDouble();
        final at = ((h - len) * first / math.max(1, n - rows))
            .clamp(0.0, h - len)
            .toDouble();
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            final dy = d.localPosition.dy;
            if (dy < at) onPage(_vkeyPageUp);
            if (dy > at + len) onPage(_vkeyPageDown);
          },
          child: Semantics(
            label: 'Table rows',
            value: '${first + 1} to ${math.min(first + rows, total)} '
                'of $total',
            increasedValue: 'next page',
            decreasedValue: 'previous page',
            onIncrease: () => onPage(_vkeyPageDown),
            onDecrease: () => onPage(_vkeyPageUp),
            child: DecoratedBox(
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest),
              child: Stack(
                children: [
                  Positioned(
                    key: const ValueKey('tc-vscroll-thumb'),
                    left: 3,
                    right: 3,
                    top: at,
                    height: len,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.outline,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A vertical swipe over a table control's lines: up pages down, down pages
/// up ([onPage] with the vkey) — translucent, so the cells under it keep
/// their taps.
class _TcSwipe extends StatefulWidget {
  const _TcSwipe({required this.onPage});
  final void Function(int vkey) onPage;

  @override
  State<_TcSwipe> createState() => _TcSwipeState();
}

class _TcSwipeState extends State<_TcSwipe> {
  double _dy = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onVerticalDragStart: (_) => _dy = 0,
    onVerticalDragUpdate: (d) => _dy += d.delta.dy,
    onVerticalDragEnd: (d) {
      final v = d.velocity.pixelsPerSecond.dy;
      final dy = _dy.abs() >= 24 ? _dy : (v.abs() >= 300 ? v : 0.0);
      if (dy < 0) widget.onPage(_vkeyPageDown);
      if (dy > 0) widget.onPage(_vkeyPageUp);
    },
  );
}

/// The narrowest and widest a dragged table-control column gets, in cells
/// (a heading letter's room; the longest painted value).
const double _tcMinCells = 1;
const double _tcMaxCells = 255;

/// The horizontal scroll of a table control whose columns run past its
/// box: the columns from [fixed] on move, from cell [left] to the box's
/// right edge [right]; [content] is where the last column ends.
class _TcScroll {
  _TcScroll(this.fixed, this.left, this.right, this.content);
  final int fixed;
  final double left;
  final int right;
  final double content;

  /// Null when every column fits the box (nothing scrolls).
  /// [right]: the box's right edge in cells (the visible box, bounded by
  /// the pane). A column dragged wider can make a control scroll that the
  /// server laid out to fit ([_TcCols]).
  static _TcScroll? of(_TcCols cols, int right) {
    final tc = cols.tc;
    final n = cols.count;
    if (n == 0) return null;
    var content = 0.0;
    for (var i = 0; i < n; i++) {
      content = math.max(content, cols.left(i) + cols.width(i));
    }
    if (content <= right) return null;
    // TC_FIXCOL columns (the first ones DISPLAYED) stay put — unless they
    // leave no room to scroll
    var fixed = math.min(tc.fixedCols, n);
    if (fixed == n || cols.left(cols.at(fixed)) >= right - 4) fixed = 0;
    return _TcScroll(fixed, cols.left(cols.at(fixed)), right, content);
  }
}

/// Whether [f] is a protected field holding only an icon token (a selection
/// screen's option icon `%_…_%_APP_%-OPTI_PUSH`, painted as a protected
/// etype-130 field): drawn as the icon, not as an input.
bool isIconOutput(ScreenField f) {
  if (f.kind != FieldKind.input || !f.isProtected) return false;
  final t = f.text.trim();
  final m = SapIconAtlas.tokenRx.firstMatch(t);
  return m != null && m.start == 0 && t.substring(m.end).trim().isEmpty;
}

/// [_iconText] for other widgets: a text run with its `@xx@` icon tokens as
/// icon-font glyphs (the ALV grid's ICON cells use it too).
Widget sapIconText(
  String text,
  SapIconAtlas? icons, {
  TextStyle? style,
  bool clip = false,
}) => _iconText(text, icons, style: style, clip: clip);

/// Reports a double tap on [child] without taking part in the gesture
/// arena: two pointer-ups within [kDoubleTapTimeout], [kDoubleTapSlop]
/// apart, neither of them a drag. The child keeps its own gestures (a text
/// field's focus, caret and word selection).
class DoubleTapListener extends StatefulWidget {
  const DoubleTapListener({
    super.key,
    required this.onDoubleTap,
    required this.child,
  });

  final VoidCallback? onDoubleTap;
  final Widget child;

  @override
  State<DoubleTapListener> createState() => _DoubleTapListenerState();
}

class _DoubleTapListenerState extends State<DoubleTapListener> {
  Offset? _down;
  Duration? _lastUp;
  Offset? _lastUpAt;

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: (e) => _down = e.position,
    onPointerCancel: (_) => _down = null,
    onPointerUp: (e) {
      final down = _down;
      _down = null;
      if (down == null || (e.position - down).distance > kTouchSlop) {
        _lastUp = null; // a drag, no tap
        return;
      }
      final last = _lastUp, at = _lastUpAt;
      if (last != null &&
          at != null &&
          e.timeStamp - last <= kDoubleTapTimeout &&
          (e.position - at).distance <= kDoubleTapSlop) {
        _lastUp = null;
        widget.onDoubleTap?.call();
        return;
      }
      _lastUp = e.timeStamp;
      _lastUpAt = e.position;
    },
    child: widget.child,
  );
}

/// A classic list line drawn with the list cursor when it is on [row]:
/// [cursor] (a tap's) over [painted] (the paint's). A tap moves the cursor
/// by the notifier — the line it left and the line it lands on rebuild,
/// the view and every other line do not; a checkbox tick ([ticked])
/// rebuilds its own line alone the same way.
class _ListCursorLine extends StatefulWidget {
  const _ListCursorLine({
    required this.cursor,
    required this.ticked,
    required this.line,
    required this.painted,
    required this.row,
    required this.builder,
  });

  final ValueListenable<(int, int)?> cursor;

  /// The view's last checkbox tick: this [line]'s own rebuilds it.
  final ValueListenable<(ListLine, int, bool)?> ticked;
  final ListLine line;
  final (int, int)? painted;
  final int row;
  final Widget Function(int? cursorCol) builder;

  @override
  State<_ListCursorLine> createState() => _ListCursorLineState();
}

class _ListCursorLineState extends State<_ListCursorLine> {
  int? _col;

  int? _colNow() {
    final c = widget.cursor.value ?? widget.painted;
    return c != null && c.$1 == widget.row ? c.$2 : null;
  }

  @override
  void initState() {
    super.initState();
    widget.cursor.addListener(_moved);
    widget.ticked.addListener(_ticked);
  }

  @override
  void didUpdateWidget(_ListCursorLine old) {
    super.didUpdateWidget(old);
    if (!identical(old.cursor, widget.cursor)) {
      old.cursor.removeListener(_moved);
      widget.cursor.addListener(_moved);
    }
    if (!identical(old.ticked, widget.ticked)) {
      old.ticked.removeListener(_ticked);
      widget.ticked.addListener(_ticked);
    }
  }

  @override
  void dispose() {
    widget.cursor.removeListener(_moved);
    widget.ticked.removeListener(_ticked);
    super.dispose();
  }

  void _moved() {
    if (_colNow() != _col) setState(() {});
  }

  void _ticked() {
    if (identical(widget.ticked.value?.$1, widget.line)) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(_col = _colNow());
}

/// One cell of a table control's scrolling columns (a heading, a field)
/// between [left] and [right] on the scrolled content; [cellKey] names a
/// field's cell (the focus is kept on it).
class _TcCell {
  _TcCell(this.left, this.right, this.widget, [this.cellKey]);
  final double left, right;
  final Widget widget;
  final String? cellKey;
}

/// A table control's scrolling columns, only those near the scrolled
/// window built (a viewport of margin on either side — TC_1211's 35
/// columns are all of them; a control hundreds of cells wide builds a
/// few): rebuilt when the scroll moves a viewport, not per scroll frame.
/// The cursor field's cell ([cursor]'s key) stays built wherever it
/// scrolls, so it keeps its focus; a cursor move rebuilds this alone (its
/// children are the same instances: nothing below redraws).
class _TcColumns extends StatefulWidget {
  const _TcColumns({
    required this.controller,
    required this.viewport,
    required this.cells,
    required this.cursor,
  });

  final ScrollController controller;
  final double viewport;
  final List<_TcCell> cells;
  final ValueListenable<_Cursor> cursor;

  @override
  State<_TcColumns> createState() => _TcColumnsState();
}

class _TcColumnsState extends State<_TcColumns> {
  int _page = 0;
  String? _keep;

  int _pageNow() {
    final c = widget.controller;
    if (!c.hasClients || widget.viewport <= 0) return 0;
    return (c.offset / widget.viewport).floor();
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scrolled);
    widget.cursor.addListener(_cursorMoved);
  }

  @override
  void didUpdateWidget(_TcColumns old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_scrolled);
      widget.controller.addListener(_scrolled);
    }
    if (!identical(old.cursor, widget.cursor)) {
      old.cursor.removeListener(_cursorMoved);
      widget.cursor.addListener(_cursorMoved);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scrolled);
    widget.cursor.removeListener(_cursorMoved);
    super.dispose();
  }

  void _scrolled() {
    if (_pageNow() != _page) setState(() {});
  }

  void _cursorMoved() {
    if (widget.cursor.value.key != _keep) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final page = _page = _pageNow();
    final keep = _keep = widget.cursor.value.key;
    final v = widget.viewport;
    final lo = (page - 1) * v, hi = (page + 3) * v;
    return Stack(
      children: [
        for (final c in widget.cells)
          if ((c.right >= lo && c.left <= hi) ||
              (c.cellKey != null && c.cellKey == keep))
            c.widget,
      ],
    );
  }
}
