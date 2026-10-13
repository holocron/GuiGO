import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/gestures.dart'
    show kDoubleTapSlop, kDoubleTapTimeout, kTouchSlop;
import 'package:flutter/material.dart';

import '../../core/sap_icons.dart';
import 'dynpro_grid.dart';
import 'sap_list_view.dart';
import 'type_ahead.dart';

/// The grid renderer's character cell bounds (points): below the minimum
/// the screen reflows by rows instead; above the maximum it stops growing.
const double _minCellW = 7.0;

const double _maxCellW = 12.0;

/// The widest painted grid (columns) seen per program, for one logon: the
/// cell size of a transaction stays put while its screens change. The
/// session screen provides one per session (its main window and its modal
/// dialogs share it); a DynproView outside any scope keeps its own.
class DynproZoomScope extends InheritedWidget {
  const DynproZoomScope({
    super.key,
    required this.widest,
    required super.child,
  });

  /// program -> the widest grid (columns) painted for it.
  final Map<String, int> widest;

  static Map<String, int>? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DynproZoomScope>()?.widest;

  @override
  bool updateShouldNotify(DynproZoomScope old) =>
      !identical(old.widest, widest);
}

/// A paint's derived layouts, computed once per model: every server turn
/// rebuilds the session screen, and an unchanged paint (the same model) must
/// not be classified / gridded again. Keyed weakly on the model; the field
/// count guards a model mutated after it was first laid out (tests build
/// models in place).
class _Derived {
  _Derived(this.fieldCount, this.layout, this.grid, this.radioGroups);
  final int fieldCount;
  final DynproLayout layout;
  final DynproGrid grid;
  final Map<String, List<ScreenField>> radioGroups;
}

final Expando<_Derived> _derived = Expando('dynpro layout');

/// How many times a paint was laid out (tests read it).
@visibleForTesting
int dynproLayoutCount = 0;

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
  return _derived[m] = _Derived(
    m.fields.length,
    layoutDynpro(m.fields),
    DynproGrid.of(m),
    radioGroups,
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
    this.onEdit,
    this.onValueHelp,
    this.onListPick,
    this.onListCell,
    this.onFocusField,
    this.onContextMenu,
    this.onDoubleClick,
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

  /// A field's text changed (not yet submitted): the session stages it,
  /// and it rides the next action — any key, button or okcode — the way
  /// SAP GUI sends every changed field with the PAI.
  final void Function(ScreenField f, String text)? onEdit;

  /// Value help (F4) on a field that has it ([ScreenField.hasF4]): the
  /// small button inside the focused field, as SAP GUI shows it.
  final Future<void> Function(ScreenField f)? onValueHelp;

  /// An input took the keyboard focus: the field F1 asks help for.
  final void Function(ScreenField f)? onFocusField;

  /// SAP GUI's context menu (right click / long press): at [at] (global),
  /// on input [field] when the gesture hit one, else on the screen.
  final void Function(Offset at, ScreenField? field)? onContextMenu;

  /// A classic list line tapped (an F4 hit list, a report list, the
  /// classic F1 popup): the list's own pick (F2 on the line).
  final Future<void> Function(ListLine line)? onListPick;

  /// A list input cell changed (a checkbox ticked: `X` / blank): the
  /// session stages it, and it rides the next list key round.
  final void Function(ListLine line, ListSegment cell, String text)?
  onListCell;

  /// SAP GUI's double-click on a field (an icon field too) or a
  /// table-control cell: the choose key (F2) with the cursor on it — the
  /// session's `doubleClick`. A label / text outside a table control takes
  /// no cursor and answers none. A single tap keeps its own meaning (an input takes the
  /// focus, a button fires its function code); a pushbutton has no
  /// double-click of its own (its first click fires it).
  final Future<void> Function(ScreenField f)? onDoubleClick;

  @override
  State<DynproView> createState() => _DynproViewState();
}

/// A control drawn on the dynpro's canvas at [cells] — dynpro cells: left
/// = column, top = row, width = columns, height = rows (from the dynpro's
/// origin, the composed window's AREASIZE area corner).
class DynproOverlay {
  const DynproOverlay(this.cells, this.child, {this.id});
  final Rect cells;
  final Widget child;

  /// Keys the overlay's box on the canvas (`ValueKey('overlay-$id')`).
  final String? id;
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

/// The quick-info of an icon token (`@1F\QSélection multiple@` → "Sélection
/// multiple"; an icon-less `@\QSélection options de sélection@` too — the
/// empty option button of SAPLALDB/3000), or null when the text carries
/// none.
String? iconQuickInfo(String text) {
  final m = RegExp(r'@[0-9A-Z]{0,2}\\Q([^@]*)@').firstMatch(text);
  return m?.group(1)?.trim();
}

// ---------------------------------------------------------------------------

class _DynproViewState extends State<DynproView> {
  final Map<String, TextEditingController> _controllers = {};
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
    if (ctrl.text != painted && !_edited.contains(key)) ctrl.text = painted;
  }

  String? _focused; // the cursor field (keeps it when the keyboard goes)

  // --- type-ahead (type_ahead.dart): the focused input's dropdown -------

  /// The focused input's type-ahead (null: no [TypeAheadScope] above, or
  /// no input has the keyboard focus) and its input's key.
  TypeAheadController? _ta;
  String? _taKey;

  /// Inputs the user typed into since their value was last kept in the
  /// input history (kept on Enter / leaving the field, as SAP GUI does).
  final Set<String> _typedSinceKept = {};

  /// The type-ahead of input [key] when it is the focused one.
  TypeAheadController? _typeAheadOf(String key) => _taKey == key ? _ta : null;

  void _typeAheadFocus(String key, ScreenField f, bool has,
      TextEditingController ctrl) {
    if (!has) {
      if (_taKey != key) return;
      _keepTyped();
      _dropTypeAhead();
      return;
    }
    final cfg = TypeAheadScope.read(context);
    if (cfg == null || _taKey == key) return;
    // the next field may take the focus before the last one hears it lost
    _keepTyped();
    _dropTypeAhead();
    setState(() {
      _ta = TypeAheadController(cfg, widget.model, f);
      _taKey = key;
    });
  }

  /// SAP GUI keeps a typed value on leaving the field: the focused
  /// input's, when the user typed into it since it was last kept.
  void _keepTyped() {
    final ta = _ta, key = _taKey;
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

  void _dropTypeAhead({bool rebuild = true}) {
    final ta = _ta;
    if (ta == null) return;
    ta.focusLost();
    _ta = null;
    _taKey = null;
    if (rebuild && mounted) setState(() {});
    // the anchor lets go of it in this frame
    WidgetsBinding.instance.addPostFrameCallback((_) => ta.dispose());
  }

  /// [field] (input [key]) under its type-ahead dropdown when a
  /// [TypeAheadScope] is above; the plain field otherwise.
  Widget _typeAheadAnchor(String key, ScreenField f,
      TextEditingController ctrl, Widget field) {
    if (TypeAheadScope.maybeOf(context) == null) return field;
    final ta = _typeAheadOf(key);
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

  /// The list checkboxes ticked since the paint, by line (identity) and
  /// column — the paint's own value until the server repaints the list.
  final Map<ListLine, Map<int, bool>> _listTicks = Map.identity();

  /// The zoom memory when no [DynproZoomScope] provides the session's.
  final Map<String, int> _ownWidest = {};

  @override
  void didUpdateWidget(DynproView old) {
    super.didUpdateWidget(old);
    // a repainted list drops the ticks of the lines it no longer paints
    if (_listTicks.isNotEmpty) {
      final now = Set<ListLine>.identity()..addAll(widget.model.listPaint);
      _listTicks.removeWhere((l, _) => !now.contains(l));
    }
    // another screen: the cursor field was the old screen's
    if (old.model.program != widget.model.program ||
        old.model.dynpro != widget.model.dynpro ||
        old.model.modalLevel != widget.model.modalLevel) {
      _focused = null;
    }
    // another program / dynpro: the old screen's inputs are gone — their
    // controllers, painted values and typed marks go with them (kept, they
    // grew with every screen of the logon, and a typed mark could survive
    // onto the next screen's field at the same cell)
    if (old.model.program != widget.model.program ||
        old.model.dynpro != widget.model.dynpro) {
      _pruneInputs();
    }
    // another screen (or window level): the dropdown was the old field's
    if (_ta != null &&
        (old.model.program != widget.model.program ||
            old.model.dynpro != widget.model.dynpro ||
            old.model.modalLevel != widget.model.modalLevel)) {
      _typedSinceKept.clear();
      _dropTypeAhead(rebuild: false); // the build follows
    }
  }

  void _pruneInputs() {
    if (_controllers.isEmpty && _painted.isEmpty && _edited.isEmpty) return;
    final gone = _controllers.values.toList();
    _controllers.clear();
    _painted.clear();
    _edited.clear();
    // the old fields' TextFields still hold them until this build replaces
    // them: disposed once the frame is done
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in gone) {
        c.dispose();
      }
    });
  }

  /// The number of live input controllers (tests read it).
  @visibleForTesting
  int get controllerCount => _controllers.length;

  /// Each scrolling table control's horizontal scroll position, by name.
  final Map<String, ScrollController> _tcScroll = {};

  @override
  void dispose() {
    _ta?.dispose();
    _ta = null;
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final c in _tcScroll.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
    final body = LayoutBuilder(
      builder: (context, cons) {
        // SAP GUI geometry whenever the painted grid fits the width at a
        // legible cell size; a phone-narrow window (or the logon screen's
        // side text panel) keeps the row reflow below
        final fixed = widget.cell;
        if (fixed != null) {
          return _buildGrid(
            context,
            grid,
            radioGroups,
            icons,
            fixed.width,
            cons.maxWidth,
            rowHeight: fixed.height,
          );
        }
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
          // header tabs each paint another width; SAP GUI's cell never moves)
          final prog = m.program ?? '';
          cols = math.max(cols, widestCols[prog] ?? 0);
          widestCols[prog] = cols;
          final cw = cons.maxWidth / cols;
          if (cw >= _minCellW) {
            return _buildGrid(
              context,
              grid,
              radioGroups,
              icons,
              math.min(cw, _maxCellW),
              cons.maxWidth,
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
              child: _buildGrid(
                context,
                grid,
                radioGroups,
                icons,
                _minCellW,
                cols * _minCellW,
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
        final form = hosted.isEmpty
            ? rows
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [rows, ...hosted],
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

    // the paint's classic list (an F4 hit list, a report list — thousands
    // of lines): its lines built as they scroll into view
    final rows = _listRows(widget.model);
    if (widget.cell != null) {
      // a pane of a composed window: the grid starts at the pane's origin
      if (rows.isEmpty) return SingleChildScrollView(child: body);
      return _withList(context, rows, 0, (line, width) {
        return ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: 1 + rows.length,
          itemBuilder: (context, i) => i == 0
              ? Center(heightFactor: 1, child: body)
              : line(i - 1),
        );
      });
    }
    // controls whose container the paint does not place
    final below = [
      for (final e in widget.controls.entries)
        if (!widget.model.containers.containsKey(e.key))
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SizedBox(height: 380, child: e.value),
          ),
    ];
    final hPad = widget.compact ? 8.0 : 12.0;
    Widget listView(Widget Function(int i)? line, int count) =>
        ListView.builder(
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
    return _withList(
      context,
      rows,
      2 * hPad,
      (line, width) => listView(line, rows.length),
    );
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

  /// The list on SAP's character grid: the cell fitted to the width (down
  /// to a legible minimum, then the list scrolls sideways — a 170-column
  /// where-used list), the frame drawn as continuous lines, the checkboxes
  /// real ones. [build] gets the line builder and the list's width.
  Widget _withList(
    BuildContext context,
    List<ListLine?> rows,
    double padding,
    Widget Function(Widget Function(int i) line, double width) build,
  ) {
    final palette = SapListPalette.of(context);
    final icons = SapIconAtlasStrip.of(context);
    final pickable = Set<ListLine>.identity()..addAll(widget.model.listLines);
    final cols = math.max(1, sapListColumns(rows));
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
        Widget line(int i) {
          final l = rows[i];
          final pick = l != null &&
              pickable.contains(l) &&
              !widget.busy &&
              widget.onListPick != null;
          final cell = widget.onListCell;
          return SapListLineView(
            line: l,
            metrics: mt,
            palette: palette,
            width: width,
            icons: icons,
            onTap: pick ? () => widget.onListPick!(l) : null,
            onCheck: l == null || cell == null || widget.busy
                ? null
                : (s, on) {
                    setState(() => (_listTicks[l] ??= {})[s.col] = on);
                    cell(l, s, on ? 'X' : ' ');
                  },
            checkedOf: l == null
                ? null
                : (s) => _listTicks[l]?[s.col] ?? s.checked,
          );
        }

        final list = build(line, width);
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
    Map<String, List<ScreenField>> radioGroups,
    SapIconAtlas? icons,
    double cw,
    double maxWidth, {
    double? rowHeight,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final ch = rowHeight ?? (cw * 2.6).clamp(22.0, 30.0);
    // a fixed (composed-window) cell scales the text with it, like the
    // reference client's picture; a fitted grid keeps a readable minimum
    final font = rowHeight != null
        ? math.min(cw * 1.4, rowHeight * 0.78)
        : (cw * 1.35).clamp(11.0, 15.0);
    // a composed window's pane starts at the dynpro's row 0 — the window
    // cell its neighbours and its overlays are placed by; a free-standing
    // grid skips the blank rows above its first painted one
    final top = rowHeight != null ? 0 : grid.firstRow;
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
    for (final tc in widget.model.tableControls) {
      children.add(
        Positioned(
          left: tc.col * cw,
          top: y(tc.row),
          width: tc.width * cw,
          height: tc.height * ch,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      );
      final sc = _TcScroll.of(tc);
      if (sc != null) scrolling[tc.name] = sc;
      if (tc.title.isNotEmpty && tc.headerRows >= 1) {
        children.add(
          Positioned(
            left: (tc.col + 1) * cw,
            top: y(tc.row),
            width: (tc.width - 2) * cw,
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
    final moving = <String, List<Widget>>{};
    bool moves(TableControlInfo tc, int column) =>
        scrolling[tc.name] != null && column >= scrolling[tc.name]!.fixed;
    for (final tc in widget.model.tableControls) {
      if (tc.headerRows < 1 || tc.title.isNotEmpty && tc.headerRows < 2) {
        continue; // a lone chrome row is the title bar
      }
      final sc = scrolling[tc.name];
      for (var i = 0; i < tc.columns.length; i++) {
        if (i >= tc.columnOffsets.length || i >= tc.widths.length) continue;
        // the heading the control paints ("Pos", "UA"), else the column's
        // DDIC title; the long title is the heading's tooltip
        final heading = i < tc.headings.length
            ? tc.headings[i]
            : (i < tc.titles.length ? tc.titles[i].trim() : '');
        if (heading.isEmpty) continue;
        final tip = i < tc.headingTips.length && tc.headingTips[i].isNotEmpty
            ? tc.headingTips[i]
            : (i < tc.titles.length ? tc.titles[i].trim() : '');
        final move = moves(tc, i);
        final left = (tc.columnOffsets[i] - (move ? sc!.left : 0)) * cw;
        final top = move
            ? (tc.headerRows - 1) * ch
            : y(tc.row + tc.headerRows - 1);
        final w = Positioned(
          left: left,
          top: top,
          // clipped to the column, as the real control clips it
          width: tc.widths[i] * cw,
          height: ch,
          child: Tooltip(
            message: tip == heading ? '' : tip,
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
              ),
            ),
          ),
        );
        (move ? moving.putIfAbsent(tc.name, () => []) : children).add(w);
      }
    }
    final tcByName = {for (final tc in widget.model.tableControls) tc.name: tc};
    for (final c in grid.cells) {
      final f = c.field;
      final w = c.width * cw;
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
                // proportional text can run wider than its painted cells:
                // shrink it to fit, as SAP GUI's cell font always fits
                child: FittedBox(
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
        case FieldKind.combobox:
          child = _doubleTappable(f, _gridInput(f, font, cw, width: w));
        case FieldKind.pushbutton:
          child = _gridButton(f, icons, font);
        case FieldKind.tabstrip:
          child = _GridTab(
            text: icons?.stripTokens(f.text).trim() ?? f.text.trim(),
            active: f.on,
            fontSize: font,
            onTap: (widget.busy || (f.fcode ?? '').isEmpty)
                ? null
                : () => widget.onOkcode(f.fcode!),
          );
        case FieldKind.checkbox:
          child = _gridChoice(
            f,
            font,
            ch,
            Checkbox(
              value: f.on,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: widget.busy || f.isProtected
                  ? null
                  : (_) => widget.onPress(0),
            ),
            widget.busy || f.isProtected ? null : () => widget.onPress(0),
          );
        case FieldKind.radio:
          final group = radioGroups['${f.area}:${f.block}:${f.group}'] ?? [f];
          child = _gridRadio(f, group, font, ch);
      }
      // a composed window's small fixed cell: every field fills its row
      // (a 4-point inset would clip the glyphs of a 12-point row)
      final h = f.kind == FieldKind.tabstrip || rowHeight != null ? ch : ch - 4;
      final tc = tcByName[f.tableControl];
      final move = tc != null && moves(tc, (f.tcColumn ?? 1) - 1);
      // a table cell keeps to its column; a free checkbox keeps a target
      final choice = f.kind == FieldKind.checkbox || f.kind == FieldKind.radio;
      final placed = Positioned(
        left: (c.col - (move ? scrolling[tc.name]!.left : 0)) * cw,
        top: (move ? (c.row - tc.row) * ch : y(c.row)) + (ch - h) / 2,
        width: choice && tc == null ? math.max(w, ch + 8) : w,
        height: h,
        child: child,
      );
      (move ? moving.putIfAbsent(tc.name, () => []) : children).add(placed);
    }
    for (final tc in widget.model.tableControls) {
      final sc = scrolling[tc.name];
      if (sc == null) continue;
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
                child: Stack(children: moving[tc.name] ?? const []),
              ),
            ),
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
      final h = math.max(c.height * ch, 260.0);
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
      for (final o in widget.overlays) {
        final r = o.cells;
        if (r.width <= 0 || r.height <= 0) continue;
        final left = r.left * cw, t = (r.top - top) * ch;
        children.add(
          Positioned(
            key: o.id == null ? null : ValueKey('overlay-${o.id}'),
            left: left,
            top: t,
            width: r.width * cw,
            height: r.height * ch,
            child: o.child,
          ),
        );
        canvasW = math.max(canvasW, left + r.width * cw);
        canvasH = math.max(canvasH, t + r.height * ch);
      }
    }
    final canvas = SizedBox(
      width: canvasW,
      height: canvasH,
      child: Stack(clipBehavior: Clip.none, children: children),
    );
    return Align(alignment: Alignment.topLeft, child: canvas);
  }

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

  Widget _gridInput(ScreenField f, double font, double cw, {double? width}) {
    final key = '${f.area}:${f.row}:${f.col}';
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
    final ctrl = _controllers.putIfAbsent(
      key,
      () => TextEditingController(text: f.text),
    );
    _syncPainted(key, ctrl, f.text);
    final enabled = !widget.busy && !f.isProtected;
    final scheme = Theme.of(context).colorScheme;
    final f4 =
        f.hasF4 && enabled && widget.onValueHelp != null && _focused == key;
    return Focus(
      onKeyEvent: (_, e) => _typeAheadKey(key, f, ctrl, e),
      onFocusChange: (has) {
        _typeAheadFocus(key, f, has, ctrl);
        // SAP GUI's cursor field: it stays the current field when the
        // keyboard is put away (F1 / F4 still act on it) until another
        // field takes the focus or the screen changes — a focus loss, or
        // the cursor field taking the focus again, changes nothing to draw
        if (!has) return;
        widget.onFocusField?.call(f);
        if (_focused != key) setState(() => _focused = key);
      },
      child: _typeAheadAnchor(key, f, ctrl, TextField(
        controller: ctrl,
        enabled: enabled,
        obscureText: f.invisible,
        maxLength: f.maxnrchars > 0 ? f.maxnrchars : null,
        textAlignVertical: TextAlignVertical.center,
        style: TextStyle(
          fontSize: font,
          fontFamily: 'Menlo',
          fontFamilyFallback: const ['Courier New', 'monospace'],
          // no tracking: Material 3's body text adds 0.5 pt a glyph, which
          // pushed a full field's last glyph past its box
          letterSpacing: 0,
        ),
        onTap: () => _edited.add(key),
        onChanged: (value) {
          _edited.add(key);
          widget.onEdit?.call(f, value);
          _typeAheadEdited(key, ctrl);
        },
        contextMenuBuilder: widget.onContextMenu == null
            ? null
            : (context, state) => _fieldTextMenu(context, state, f),
        onSubmitted: (value) async {
          _edited.remove(key);
          _typeAheadSubmitted(key, value);
          await widget.onFill(f, value);
        },
        decoration: InputDecoration(
          // SAP GUI's F4 button at the right edge of the focused field
          suffixIcon: f4
              ? IconButton(
                  tooltip: 'Value help (F4)',
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  iconSize: font + 2,
                  icon: const Icon(Icons.manage_search),
                  onPressed: () => widget.onValueHelp!(f),
                )
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
          // text's width — 8 pt a 2-cell field cannot spare
          border: OutlineInputBorder(
            gapPadding: 0,
            borderRadius: BorderRadius.circular(3),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            gapPadding: 0,
            borderRadius: BorderRadius.circular(3),
            // the cursor field keeps its mark without the keyboard
            borderSide: _focused == key
                ? BorderSide(color: scheme.primary, width: 1.5)
                : BorderSide(color: scheme.outlineVariant),
          ),
        ),
      )),
    );
  }

  Widget _gridButton(ScreenField f, SapIconAtlas? icons, double font) {
    final enabled = !widget.busy && (f.fcode ?? '').isNotEmpty;
    final tip = iconQuickInfo(f.text);
    final plain = (icons?.stripTokens(f.text) ?? f.text).trim();
    final token = SapIconAtlas.tokenRx.firstMatch(f.text);
    final cp = token != null ? icons?.codepoint(token.group(1)!) : null;
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
    final glyph = cp != null
        ? Text(
            String.fromCharCode(cp),
            style: TextStyle(fontFamily: 'SapIcons', fontSize: font + 2),
          )
        : (token != null ? Icon(Icons.more_horiz, size: font + 2) : null);
    return Tooltip(
      message: tip ?? '',
      child: OutlinedButton(
        onPressed: enabled ? () => widget.onOkcode(f.fcode!) : null,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: TextStyle(fontSize: font),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ?glyph,
              if (glyph != null && plain.isNotEmpty) const SizedBox(width: 4),
              if (plain.isNotEmpty)
                Flexible(
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
  }

  /// [child] answering a double tap on [f] with [DynproView.onDoubleClick]
  /// (a [Listener]: the child keeps every gesture of its own — an input's
  /// focus and selection, a list's scroll).
  Widget _doubleTappable(ScreenField f, Widget child, {bool enabled = true}) {
    final cb = widget.onDoubleClick;
    if (cb == null || !enabled) return child;
    return DoubleTapListener(
      onDoubleTap: widget.busy ? null : () => cb(f),
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

  Widget _gridChoice(
    ScreenField f,
    double font,
    double ch,
    Widget leading,
    VoidCallback? onTap,
  ) {
    final text = _choiceText(f);
    if (text.isEmpty) {
      // a bare box (a table control's checkbox column): it fits its cells
      return InkWell(
        onTap: onTap,
        child: FittedBox(child: leading),
      );
    }
    return InkWell(
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
    );
  }

  Widget _gridRadio(
    ScreenField f,
    List<ScreenField> group,
    double font,
    double ch,
  ) {
    ScreenField? current =
        widget.radioSelection != null && group.contains(widget.radioSelection)
        ? widget.radioSelection
        : null;
    if (current == null) {
      final painted = group.where((f) => f.on).toList();
      current = painted.isNotEmpty ? painted.first : null;
    }
    final enabled =
        !widget.busy && (widget.onRadio != null || widget.onRadioTap != null);
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
    );
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
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text(
          '(nothing painted on this screen)',
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
        else
          cellOf(f),
    ];
    if (lead == null) {
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
        estimate += _inputChars(f) * 9.0 + 32;
      } else if (_isText(f)) {
        estimate += f.text.trim().length * 8.0 + 8;
      } else {
        estimate += 48 + f.text.trim().length * 8.0;
      }
    }
    if (estimate <= maxWidth) {
      return Row(spacing: 8, children: [caption, ...groupChildren]);
    }
    // too wide: the caption heads its own line, the fields shrink below it
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(bottom: 2), child: caption),
        Row(spacing: 8, children: groupChildren),
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
      case FieldKind.combobox:
        return _doubleTappable(
          f,
          _input(f, layout.captionOf.containsKey(f), maxWidth),
        );
      case FieldKind.checkbox:
        return _Choice(
          leading: Checkbox(
            value: f.on,
            onChanged: widget.busy ? null : (_) => widget.onPress(0),
          ),
          text: _choiceText(f),
          onTap: widget.busy ? null : () => widget.onPress(0),
        );
      case FieldKind.radio:
        final group = radioGroups['${f.area}:${f.block}:${f.group}'] ?? [f];
        return _radio(f, group);
      case FieldKind.pushbutton:
        return _button(f, icons);
      case FieldKind.tabstrip:
        return ChoiceChip(
          label: Text(icons?.stripTokens(f.text).trim() ?? f.text),
          selected: f.on,
          onSelected: (widget.busy || (f.fcode ?? '').isEmpty)
              ? null
              : (_) => widget.onOkcode(f.fcode!),
        );
    }
  }

  Widget _radio(ScreenField f, List<ScreenField> group) {
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
        !widget.busy && (widget.onRadio != null || widget.onRadioTap != null);
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

  Widget _button(ScreenField f, SapIconAtlas? icons) {
    final enabled = !widget.busy && (f.fcode ?? '').isNotEmpty;
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

  Widget _input(ScreenField f, bool captioned, double maxWidth) {
    final key = '${f.area}:${f.row}:${f.col}';
    final ctrl = _controllers.putIfAbsent(
      key,
      () => TextEditingController(text: f.text),
    );
    _syncPainted(key, ctrl, f.text);
    // the painted width: mlen (or the type's max) in character cells; a
    // Flexible parent may shrink it, never widen it
    final width = (_inputChars(f) * 9.0 + 32).clamp(
      64.0,
      maxWidth.clamp(64.0, 440.0),
    );
    final field = TextField(
        controller: ctrl,
        enabled: !widget.busy && !f.isProtected,
        obscureText: f.invisible,
        onTap: () => _edited.add(key),
        onChanged: (value) {
          _edited.add(key);
          widget.onEdit?.call(f, value);
          _typeAheadEdited(key, ctrl);
        },
        contextMenuBuilder: widget.onContextMenu == null
            ? null
            : (context, state) => _fieldTextMenu(context, state, f),
        onSubmitted: (value) async {
          _edited.remove(key);
          _typeAheadSubmitted(key, value);
          await widget.onFill(f, value);
        },
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 10,
          ),
          // a field without a painted caption shows its name as the hint
          hintText: !captioned && (f.name ?? '').isNotEmpty ? f.name : null,
          hintStyle: TextStyle(color: Colors.blueGrey.shade400, fontSize: 12),
        ),
      );
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: 48, maxWidth: width),
      child: TypeAheadScope.maybeOf(context) == null
          ? field
          : Focus(
              onKeyEvent: (_, e) => _typeAheadKey(key, f, ctrl, e),
              onFocusChange: (has) => _typeAheadFocus(key, f, has, ctrl),
              child: _typeAheadAnchor(key, f, ctrl, field),
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
}) {
  final overflow = clip ? TextOverflow.clip : null;
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          leading,
          Padding(padding: const EdgeInsets.only(right: 8), child: Text(text)),
        ],
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
/// into the top edge (the real GUI's frame).
class _GridFrame extends StatelessWidget {
  const _GridFrame({required this.title, required this.fontSize});
  final String title;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        if (title.isNotEmpty)
          Positioned(
            left: 8,
            top: -fontSize * 0.75,
            child: Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ),
          ),
      ],
    );
  }
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

/// The horizontal scroll of a table control whose columns run past its
/// box: the columns from [fixed] on move, from cell [left] to the box's
/// right edge [right]; [content] is where the last column ends.
class _TcScroll {
  _TcScroll(this.fixed, this.left, this.right, this.content);
  final int fixed;
  final int left;
  final int right;
  final int content;

  /// Null when every column fits the box (nothing scrolls).
  static _TcScroll? of(TableControlInfo tc) {
    final n = math.min(tc.columnOffsets.length, tc.widths.length);
    if (n == 0) return null;
    final right = tc.col + tc.width;
    var content = 0;
    for (var i = 0; i < n; i++) {
      content = math.max(content, tc.columnOffsets[i] + tc.widths[i]);
    }
    if (content <= right) return null;
    // TC_FIXCOL columns stay put — unless they leave no room to scroll
    var fixed = math.min(tc.fixedCols, n);
    if (fixed == n || tc.columnOffsets[fixed] >= right - 4) fixed = 0;
    return _TcScroll(fixed, tc.columnOffsets[fixed], right, content);
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
