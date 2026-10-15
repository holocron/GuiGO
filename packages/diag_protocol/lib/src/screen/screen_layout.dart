/// The SCREEN COMPOSITION — where every piece of the current window sits:
/// the dynpro area, the docked panes beside / below it, the splitter cells
/// inside them, the dynpro's custom-control regions, and what each region
/// shows. A port of the reference client screenshot renderer's LAYOUT DECISIONS
/// (the reference client engine; every rule below names the function it
/// mirrors), without the drawing:
///
/// * the control registry (ea_control_tree.control_tree parents,
/// diag_control_props SetProperty store, ea_facts LinkContainer
/// registry, splitter_layout.splitter_facts, raw_controls_graph
/// .kind_of_creation_class, ea_facts.record_control_toolbars);
/// * the shell boxes (splitter_layout.shell_boxes: docked_layout
/// .docked_boxes, the area-linked containers, _share_pane, the
/// parent walk with splitter cells by _cell_box / _shares and
/// _empty_cell_collapse, _toolbar_rows);
/// * the window carve (render_tiler.content_sized_docks / carve_window,
/// render_prepare.area_edges);
/// * the per-region rung (render_regions.draw_regions / _resolve /
/// _dispatch / _rung_tail / _rung_gauge, render_ladder RUNGS,
/// render_prepare.build_cell_items / ledger_dock_hosts / pair_hosts).
///
/// Units: the reference client's dynpro char cells — its canvas is CELL_W 9 x
/// CELL_H 18 px per cell — and docking pixel extents convert with the
/// session METRICS the reference client advertises (ea_controlxml _METRIC_X2 8 /
/// _METRIC_Y2 29 px per column / row).
library;

import 'dart:math' as math;

import 'sap_barchart.dart' show isBarChartClass;
import 'sap_calendar.dart' show calendarClassRx;
import 'screen_model.dart';

/// A rectangle in window character cells (the dynpro grid units).
class CellRect {
  const CellRect(this.row, this.col, this.rows, this.cols);
  final double row;
  final double col;
  final double rows;
  final double cols;

  @override
  bool operator ==(Object other) =>
      other is CellRect &&
      other.row == row &&
      other.col == col &&
      other.rows == rows &&
      other.cols == cols;

  @override
  int get hashCode => Object.hash(row, col, rows, cols);

  @override
  String toString() => 'CellRect(r$row c$col ${rows}x$cols)';
}

/// One region of the window composition.
class ScreenRegion {
  const ScreenRegion({
    required this.kind,
    required this.rect,
    required this.rung,
    required this.reason,
    this.shell,
    this.container,
    this.gauge,
    this.gaugeText,
  });

  /// 'dynpro' | 'tree' | 'grid' | 'chart' | 'image' | 'html' | 'netplan' |
  /// 'canvas' | 'editor' | 'calendar' | 'office' | 'control'
  final String kind;

  /// The hosted control shell (a 'dynpro' region: null).
  final String? shell;

  /// The dynpro custom-control area / docking container the region is.
  final String? container;

  /// Absolute in the window (the dynpro region's rect is the dynpro grid's
  /// origin and the AREASIZE area).
  final CellRect rect;

  /// the reference client ladder rung (render_ladder.RUNGS: 'R1' … 'R9'; 'TB' for a
  /// control toolbar drawn in its box — render_stacked.draw_toolbars).
  final String rung;

  /// the reference client's ledger text for the region.
  final String reason;

  /// R5 nominal gauge fill 0..1 (render_regions.gauge_pair).
  final double? gauge;
  final String? gaugeText;

  @override
  String toString() =>
      'ScreenRegion($kind ${shell ?? container ?? ''} $rect $rung: $reason)';
}

/// the reference client's char-cell canvas metrics (diag_render CELL_W / CELL_H).
const int cellW = 9;
const int cellH = 18;

/// The px per char column / row the reference client converts docking extents by
/// (ea_controlxml _METRIC_X2 / _METRIC_Y2).
const int metricX2 = 8;
const int metricY2 = 29;

/// The CFW control properties the layout and docking code reads and
/// writes (SAP GUI's numeric property ids, the registry's keys): the
/// control's height and width (in the METRICS units [metricY2] /
/// [metricX2]), a docking container's side (`1` / `2` left / right, `3` /
/// `4` top / bottom) and its visibility (`0` hidden).
const String propControlHeight = '120';
const String propControlWidth = '300';
const String propDockSide = '470';
const String propVisible = '290';

/// The CFW alignment / position props a control's box inside its parent
/// follows (the jar's com.sap.platin.r3.cet.GuiCtlProperty: SAP_PROP_ALIGN
/// 10, SAP_PROP_TOP 270, SAP_PROP_METRIC 410), the ALIGN bits
/// (SAP_ALIGN_AT_TOP 4, SAP_ALIGN_AT_BOTTOM 8; 15 = fill) and
/// SAP_METRIC_PIXEL 1.
const String propAlign = '10';
const String propTop = '270';
const String propMetric = '410';
const int alignAtTop = 4;
const int alignAtBottom = 8;
const String metricPixel = '1';

/// render_ladder.RUNGS
const Map<String, String> ladderRungs = {
  'R1': 'composited dynpro atoms',
  'R2': 'hosted table/tree',
  'R3': 'picture from the download store',
  'R4': 'editor body',
  'R5': 'chart schematic',
  'R6': 'graph schematic',
  'R7': 'content not delivered yet (creation wave)',
  'R7b': 'on-demand window partly fetched',
  'R8': 'off-DIAG HTML viewer',
  'R9': 'wireframe with structure',
  'R10': 'HTML document delivered over DIAG',
  // GuiGo's own rung: the date-picker control (sap_calendar.dart) drawn as
  // a month grid in its region — the reference client draws it as a generic control
  'R11': 'calendar month grid',
  // GuiGo's own rung: a CFW combo box / input field (CL_GUI_COMBOBOX,
  // CL_GUI_INPUT_FIELD) drawn as its widget in its box
  'CF': 'CFW combo box / input field',
  // GuiGo's own rung: a DOI container (SAP.DocumentContainerControl.1)
  // drawn as the Office document it holds (SapSession.officeDocuments)
  'OF': 'Office document (DOI container)',
};

/// The CFW field controls drawn by the 'CF' rung (SAPGUI.SAPComboBoxCtrl.1,
/// SAPGUI.SAPInputField.1 — the session's SapSessionCfwFields classes).
final RegExp _cfwFieldClass = RegExp(
  'combobox|inputfield',
  caseSensitive: false,
);

const Set<String> _structuralKinds = {'container', 'toolbar'};
const List<String> _drivableKinds = [
  'tree',
  'grid',
  'editor',
  'html',
  'toolbar',
];

/// raw_controls_graph.kind_of_creation_class (toolbar marks of
/// raw_services._TOOLBAR_CONTROL_MARKS; the control_knowledge rungs this
/// port carries: image and chart).
String controlKind(String cls) {
  final c = cls;
  if (c.contains('SapToolBar') || c.contains('SAP.Toolbar')) return 'toolbar';
  // SAP.CalendarControl.1 / the Java SapCalendar (sap_calendar.dart)
  if (calendarClassRx.hasMatch(c.trim())) return 'calendar';
  if (c.contains('Grid')) return 'grid';
  if (c.contains('Tree')) return 'tree';
  if (['TextEdit', 'AbapEditor', 'EditCtrl'].any(c.contains)) return 'editor';
  if (c.contains('Html') || c.contains('HTML')) return 'html';
  // the DOI container (doi.dart containerClassRx) — before the container
  // test, which its `Container` (not `CONTAINER`) never matched anyway
  if (_officeClass.hasMatch(c.trim())) return 'office';
  if (c.contains('NetPlanGraphics') || c.contains('JNet')) return 'jnet';
  // the SAPbarc.OCX bar chart (GRAL BARCOCX1): a graphic of the same SAP
  // Graphics family, drawn as a graph region — no business chart
  if (isBarChartClass(c)) return 'jnet';
  if (['CONTAINER', 'Splitter', 'DOCKING', 'DIALOGCTRL'].any(c.contains)) {
    return 'container';
  }
  final u = c.toUpperCase();
  if (u == 'SAPGUI.IMAGECTRL.1' ||
      u == 'COM.SAP.COMPONENTS.CONTROLS.IMAGE.SAPIMAGE') {
    return 'image';
  }
  if (const {
    'SAPGRAPHICS.CHART.1',
    'GRAPHITTI.CHART.1',
    // the GFW business graphic's Java bean (TGPN JAVA / BUSG / CHART)
    'COM.ICUBE.BEANS.CHTCHART.CHTCHART',
  }.contains(u)) {
    return 'chart';
  }
  return 'control';
}

bool _isDockingClass(String cls) => cls.toUpperCase().contains('DOCKING');

final RegExp _digits = RegExp(r'^\d+$');

/// SAP.DocumentContainerControl.N (doi.dart containerClassRx).
final RegExp _officeClass = RegExp(
  r'^SAP\.DocumentContainerControl\.\d+$',
  caseSensitive: false,
);

/// One CreateControl of the registry (ea_control_tree.note_created_controls:
/// program, step, shell, class).
class LayoutControl {
  LayoutControl(this.program, this.step, this.shell, this.cls);
  final String? program;
  final int step;
  final String shell;
  final String cls;
}

/// A splitter record (splitter_layout._new_record).
class LayoutSplitter {
  LayoutSplitter(this.parent);
  String parent;
  int rows = 0;
  int cols = 0;
  final Map<(int, int), String> cells = {};
  final Map<int, double> rowPct = {};
  final Map<int, double> colPct = {};
  int rowMode = 1;
  int colMode = 1;

  /// SetRowSash / SetColumnSash(sash, type, value): type 0 movable, 1
  /// visible (CL_GUI_SPLITTER_CONTAINER type_movable / type_sashvisible),
  /// value 0 = false. Sash k lies between row (column) k and k + 1. Read
  /// from the INI-file screen's queue (a recorded session
  /// srv step 104: `SetRowSash(1, 0, 0)`, `SetRowSash(1, 1, 0)`) and the
  /// ALV dialogs' (`SetColumnSash(1, 1, 0)`).
  final Map<int, bool> rowSashMovable = {};
  final Map<int, bool> rowSashVisible = {};
  final Map<int, bool> colSashMovable = {};
  final Map<int, bool> colSashVisible = {};

  /// Whether the user cannot drag sash [k] (locked or hidden).
  bool rowSashFixed(int k) =>
      rowSashMovable[k] == false || rowSashVisible[k] == false;
  bool colSashFixed(int k) =>
      colSashMovable[k] == false || colSashVisible[k] == false;
}

/// The verbs the layout reads, already decoded by the caller: one entry
/// per verb of a flush call (name, named args, on-object VARS row, its
/// value token, the verb's _RESULT row).
class LayoutVerb {
  LayoutVerb(this.verb, this.args, this.obj, this.objValue, this.result);
  final String verb;
  final Map<String, String> args;
  final String obj;
  final String objValue;
  final String result;
}

/// The session's control facts, folded call by call.
class ControlRegistry {
  final List<LayoutControl> created = [];

  /// shell -> CreateControl #4 parent (splitter cells: their splitter)
  final Map<String, String> parents = {};

  /// shell -> {propId: value}, last SetProperty wins
  final Map<String, Map<String, String>> props = {};

  /// shell -> {propId: every value the server SET, in order} — the dock
  /// extents it requested (see _dockedBoxes)
  final Map<String, Map<String, List<String>>> requested = {};

  /// dock shell -> the window-minus-area delta (cells) of the server pair
  /// when the session last REPORTED its realized layout (the `%_GS 0 3`
  /// round); a later different delta is the server's re-layout
  final Map<String, int> reportedDelta = {};

  /// dock shell -> the painted window-minus-area delta (cells) when the
  /// USER dragged its edge (SapSession.resizeDock): while the server still
  /// paints that delta the pane is ours to realize (the dragged
  /// [LayoutInputs.dockFraction]); once it re-lays out to our report the
  /// painted delta is trusted again (a recorded session KEY DECODE 3)
  final Map<String, int> draggedDelta = {};

  /// shell -> the cached props its RegisterCachedProp verbs registered,
  /// in registration order (the CONTROLS report's order)
  final Map<String, List<String>> cachedProps = {};

  /// shell -> the size props (120 / 300) the client already flushed for
  /// it, by value: a later round reports a size only when it changed
  /// (a recorded session g[26] reports container 118's realized
  /// 120 / 300 with the first margin click after the editor's creation,
  /// g[29] — the next click — nothing). A re-created shell starts afresh.
  final Map<String, Map<String, String>> flushedSizes = {};

  /// AREA -> (container shell, program, step) — LinkContainer
  final Map<String, (String, String?, int)> areaLinks = {};

  /// container shell -> (program, dynpro) — LinkControl: the dynpro the
  /// container shows on, wherever it was created (SE38's EDITOR container,
  /// built on SAPLWBABAP for SAPLS38E/0500, is shown again by a later F7)
  final Map<String, (String, String)> controlLinks = {};
  final Map<String, LayoutSplitter> splitters = {};

  /// toolbar shell -> fcodes its AddButton verbs gave it
  final Map<String, List<String>> toolbarButtons = {};

  /// shell -> the text its latest SetToolTip verb gave it (CL_GUI_PICTURE
  /// set_tooltip: the DB50 overview's bar pictures carry their value —
  /// "130,53 GB /250,00 GB", the CPU bar's "7 %")
  final Map<String, String> toolTips = {};

  /// Drop every per-shell fact of [shells] — controls the frontend tore
  /// down with their internal mode (imode_scope.dart, `delIMode`): a later
  /// control minted on the same kernel shell id starts with none of them
  /// (no inherited dock extents, buttons, area links or cached props). The
  /// [created] history stays (creation order / generation), so a dead
  /// shell is still known — liveness answers whether it is on screen.
  void forget(Set<String> shells) {
    if (shells.isEmpty) return;
    for (final m in [
      props,
      requested,
      reportedDelta,
      draggedDelta,
      cachedProps,
      flushedSizes,
      controlLinks,
      splitters,
      toolbarButtons,
      toolTips,
    ]) {
      shells.forEach(m.remove);
    }
    areaLinks.removeWhere((_, l) => shells.contains(l.$1));
  }

  /// Relabel everything recorded during the action that opened a new
  /// screen generation (reference client ea_facts.retag_generation): creations and
  /// area links tagged [old] at a step >= [since] become [now]'s. The
  /// creation wave of a screen is answered before the paint that names its
  /// program, so it is folded under the program before it; relabelled, a
  /// later RETURN to [now] (F3 out of a nested screen, which re-sends no
  /// CreateControl) finds its controls again — a recorded session SM59:
  /// tree 125 minted at scrubbed srv[41] under SAPLSMTR_NAVIGATION, shown
  /// again by SAPMCRFC/0100 at srv[69]. [since] must be a HOME-system step
  /// (imode_scope.dart, D2): a relayed remote logon's step 1 relabelled
  /// the whole login wave in the reference client (a recorded session
  /// DECODE.md Finding 3).
  int retag(String old, String now, {required int since}) {
    if (old == now) return 0;
    var n = 0;
    for (var i = 0; i < created.length; i++) {
      final c = created[i];
      if (c.program == old && c.step >= since) {
        created[i] = LayoutControl(now, c.step, c.shell, c.cls);
        n++;
      }
    }
    for (final e in areaLinks.entries.toList()) {
      final (sh, prog, st) = e.value;
      if (prog == old && st >= since) {
        areaLinks[e.key] = (sh, now, st);
        n++;
      }
    }
    return n;
  }

  /// Fold one flush call. [shellOfHandle] bridges a live handle to its
  /// kernel shell (the session alias); [isLive] answers liveness.
  void foldCall(
    List<LayoutVerb> verbs, {
    required String? program,
    required int step,
    String? Function(String handle)? shellOfHandle,
    bool Function(String shell)? isLive,
  }) {
    // ea_facts.verb_object_shell_resolver
    final rowShell = <String, String>{};
    for (final v in verbs) {
      if (!v.verb.startsWith('CreateControl')) continue;
      final sh = (v.args['#1'] ?? '').trim();
      if (v.result.isNotEmpty && _digits.hasMatch(sh)) rowShell[v.result] = sh;
    }
    final createdSet = {for (final c in created) c.shell};
    String? shellOf(LayoutVerb v) {
      final s = rowShell[v.obj.trim()];
      if (s != null) return s;
      final h = v.objValue.trim();
      if (!_digits.hasMatch(h)) return null;
      if (createdSet.contains(h)) return h;
      return shellOfHandle?.call(h) ?? h;
    }

    // ea_control_tree.control_tree + note_created_controls
    var lastSplitter = '';
    for (final v in verbs) {
      if (!v.verb.startsWith('CreateControl')) continue;
      final shell = (v.args['#1'] ?? '').trim();
      if (!_digits.hasMatch(shell)) continue;
      final cls = [v.args['#1'], v.args['#2']].whereType<String>().firstWhere(
        (x) => x.contains(_letterRx),
        orElse: () => '',
      );
      var par = (v.args['#4'] ?? '').trim();
      if (cls.contains('Splitter')) {
        lastSplitter = shell;
      } else if (v.verb == 'CreateControl2' &&
          !_digits.hasMatch(par) &&
          lastSplitter.isNotEmpty) {
        par = lastSplitter;
      }
      created.add(LayoutControl(program, step, shell, cls));
      requested.remove(shell); // a re-created shell starts a new history
      flushedSizes.remove(shell); // … and owes its realized size again
      props[shell]?.remove(propVisible); // … and visible (see [hidden])
      if (_digits.hasMatch(par)) parents[shell] = par;
    }
    if (created.length > 1000) created.removeRange(0, created.length - 1000);

    for (final v in verbs) {
      final a = v.args;
      if (v.verb == 'SetProperty') {
        final sh = (a['#1'] ?? '').trim();
        final p = (a['#2'] ?? '').trim();
        if (_digits.hasMatch(sh) && p.isNotEmpty) {
          final val = (a['#3'] ?? '').trim();
          (props[sh] ??= {})[p] = val;
          ((requested[sh] ??= {})[p] ??= []).add(val);
        }
      } else if (v.verb == 'SetToolTip') {
        final sh = shellOf(v);
        final t = (a['#1'] ?? '').trim();
        if (sh != null && t.isNotEmpty) toolTips[sh] = t;
      } else if (v.verb == 'LinkContainer') {
        final sh = (a['#1'] ?? '').trim();
        final nm = (a['#2'] ?? '').trim().toUpperCase();
        if (_digits.hasMatch(sh) && nm.isNotEmpty) {
          areaLinks[nm] = (sh, program, step);
        }
      } else if (v.verb == 'LinkControl') {
        final sh = (a['#1'] ?? '').trim();
        final prog = (a['#2'] ?? '').trim();
        final dyn = (a['#3'] ?? '').trim();
        if (_digits.hasMatch(sh) && prog.isNotEmpty && dyn.isNotEmpty) {
          controlLinks[sh] = (prog, dyn.padLeft(4, '0'));
        }
      } else if (v.verb == 'RegisterCachedProp') {
        final sh = (a['#1'] ?? '').trim();
        final p = (a['#2'] ?? '').trim();
        final list = cachedProps[sh] ??= [];
        if (_digits.hasMatch(sh) && p.isNotEmpty && !list.contains(p)) {
          list.add(p);
        }
      } else if (v.verb == 'AddButton') {
        final sh = shellOf(v);
        final fc = (a['#1'] ?? '').trim();
        if (sh != null && fc.isNotEmpty) (toolbarButtons[sh] ??= []).add(fc);
      }
    }
    _foldSplitters(verbs, shellOf, isLive);
  }

  /// splitter_layout.splitter_facts + record_splitter_facts
  void _foldSplitters(
    List<LayoutVerb> verbs,
    String? Function(LayoutVerb) shellOf,
    bool Function(String)? isLive,
  ) {
    final out = <String, LayoutSplitter>{};
    final createdHere = <String>{};
    String? cur;
    (int, int)? pending;
    for (final v in verbs) {
      final a = v.args;
      if (v.verb.startsWith('CreateControl')) {
        final shell = (a['#1'] ?? '').trim();
        final cls = (a['#2'] ?? '').trim();
        if (v.verb == 'CreateControl' &&
            cls.contains('Splitter') &&
            _digits.hasMatch(shell)) {
          cur = shell;
          out[shell] = LayoutSplitter((a['#4'] ?? '').trim());
          createdHere.add(shell);
          pending = null;
        } else if (v.verb == 'CreateControl2' &&
            cur != null &&
            pending != null &&
            _digits.hasMatch(shell)) {
          out[cur]!.cells[pending] = shell;
          pending = null;
        }
        continue;
      }
      String? target;
      final sh = shellOf(v);
      if (sh != null && (out.containsKey(sh) || splitters.containsKey(sh))) {
        target = sh;
      }
      if (target == null) {
        if (_digits.hasMatch(v.objValue.trim())) {
          target = _onlySplitterWithSash(v.verb, a, createdHere, isLive);
        } else {
          target = cur;
        }
      }
      if (target == null) continue;
      final f = out[target] ??= _SashOnly(target);
      int i(String k) => int.tryParse((a[k] ?? '').trim()) ?? 0;
      // an ABAP number writes its sign AFTER the digits: SM12's list round
      // sizes its splitter 119 SetRowHeight(1, 0), (2, "1-"), (3, 0)
      // (a recorded session srv[114] / srv[116] verbs [509]-[510]) — row 2,
      // the lock list, takes the whole splitter (see _shares)
      double d(String k) {
        final t = (a[k] ?? '').trim();
        if (t.endsWith('-')) {
          return -(double.tryParse(t.substring(0, t.length - 1)) ?? 0);
        }
        return double.tryParse(t) ?? 0;
      }
      switch (v.verb) {
        case 'SetGrid':
          f
            ..rows = i('#1')
            ..cols = i('#2');
        case 'GetContainer':
          pending = (i('#1'), i('#2'));
        case 'SetRowHeight':
          f.rowPct[i('#1')] = d('#2');
        case 'SetColumnWidth':
          f.colPct[i('#1')] = d('#2');
        case 'SetRowSash' || 'SetColumnSash':
          final row = v.verb == 'SetRowSash';
          final type = i('#2');
          final on = i('#3') != 0;
          if (type == 0) {
            (row ? f.rowSashMovable : f.colSashMovable)[i('#1')] = on;
          } else if (type == 1) {
            (row ? f.rowSashVisible : f.colSashVisible)[i('#1')] = on;
          }
        case 'SetRowMode':
          f.rowMode = i('#1');
        case 'SetColumnMode':
          f.colMode = i('#1');
      }
    }
    for (final e in out.entries) {
      final f = e.value;
      if (f is! _SashOnly) {
        splitters[e.key] = f;
        continue;
      }
      final live = splitters[e.key];
      if (live == null) continue;
      live.rowPct.addAll(f.rowPct);
      live.colPct.addAll(f.colPct);
      live.rowSashMovable.addAll(f.rowSashMovable);
      live.rowSashVisible.addAll(f.rowSashVisible);
      live.colSashMovable.addAll(f.colSashMovable);
      live.colSashVisible.addAll(f.colSashVisible);
      if (f.touchedModes) {
        live
          ..rowMode = f.rowMode
          ..colMode = f.colMode;
      }
      if (f.rows != 0 || f.cols != 0) {
        live
          ..rows = f.rows
          ..cols = f.cols;
      }
    }
  }

  /// splitter_layout._only_splitter_with_sash
  String? _onlySplitterWithSash(
    String verb,
    Map<String, String> args,
    Set<String> exclude,
    bool Function(String)? isLive,
  ) {
    final rowAxis = verb == 'SetRowHeight' || verb == 'SetRowMode';
    final colAxis = verb == 'SetColumnWidth' || verb == 'SetColumnMode';
    if (!rowAxis && !colAxis) return null;
    final idx = (verb == 'SetRowHeight' || verb == 'SetColumnWidth')
        ? int.tryParse((args['#1'] ?? '').trim()) ?? 0
        : 1;
    final hits = [
      for (final e in splitters.entries)
        if (!exclude.contains(e.key))
          if ((rowAxis ? e.value.rows : e.value.cols) case final n
              when n >= 2 && idx >= 1 && idx <= n)
            if (isLive?.call(e.key) ?? true) e.key,
    ];
    return hits.length == 1 ? hits.single : null;
  }

  /// Whether [shell] is HIDDEN: its own or an ancestor's latest
  /// SetProperty 290 (VISIBLE — CL_GUI_CONTROL set_visible) is 0. Every CFW
  /// container is created with 290 = 1; a program hides one, and so its
  /// whole subtree, with 290 = 0 and shows it again with 290 = 1. SM12
  /// (RS_ENQ_ADMIN/0101, a recorded session scrubbed srv[114], step 171)
  /// creates its lock-list splitter 119 in CONTAINER_MAIN (grids 126-129 in
  /// its cells) and its server-administration dock 130 (left, 300 = 200,
  /// SAP.TableTreeControl 131 inside), then ends the creation queue with
  /// SetProperty(119, 290, 0) and SetProperty(130, 290, 0): the real GUI's
  /// paint (srv[115]) lays the dynpro over the whole window (AREASIZE 38 x
  /// 268 of 38 x 268) and it sends no layout round. The list's "execute"
  /// reply (srv[116], step 174) opens with SetProperty(119, 290, 1); dock
  /// 130 stays hidden (srv[118] re-sends 290 = 0) until the application
  /// toolbar's "Administration des serveurs" shows it.
  bool hidden(String shell) {
    final seen = <String>{};
    String? sh = shell;
    while (sh != null && seen.add(sh)) {
      if ((props[sh]?[propVisible] ?? '').trim() == '0') return true;
      sh = parents[sh];
    }
    return false;
  }

  /// raw_controls_graph.control_graph kinds: {shell: kind}
  Map<String, String> kinds() => {
    for (final c in created) c.shell: controlKind(c.cls),
  };

  Map<String, String> classes() => {for (final c in created) c.shell: c.cls};
}

/// The answers the SAP GUI for Windows gives to a splitter's size READS in
/// one flush call — `GetRowHeight(row)` / `GetColumnWidth(col)` on a
/// SAPGUI.SplitterCtrl — by 0-based VARS row of each read's `_RESULT`:
/// the extent the server last SET on that row / column (in the splitter's
/// mode: percent, or pixels when absolute — never normalised, a negative
/// one included), else the share an undeclared one holds (relative mode:
/// what the declared ones leave, split evenly). a recorded session
/// (raw srv[39] step 51 -> gui[32]): /AIF/IFMON's BT_SELECTDT reads its
/// three splitters before it re-lays them out — the 1 x 1 splitter 120
/// rows 1 / 2: `100`, `-104`; the 1 x 2 splitter 122 columns: `30`, `80`;
/// the left pane's 3 x 1 splitter 125 (row 1 empty, row 2 the HTML
/// selection, row 3 the date navigator): `0`, `20`, `0` — each the value
/// the launch set (the Java oracle a recorded session shows those
/// sets: srv[26] step 39 SetRowHeight(1, 100) / (2, -104) on 120, …) —
/// and srv[40] then sets the three from what it read: (100, -104), (30,
/// 80), (0, 10, 10). The Java GUI answers the same reads alike (srv[53] ->
/// its step-73 answer) but for 120's row 1, `-1` (a dialect divergence
/// left unmodelled: the server sets it back unchanged). GuiGo answered
/// every row `0` and every column `31` (the responder's numeric
/// defaults), so the server re-laid the pane out from zeros — the likely
/// cause of the live the test system "Afficher calendrier" (2026-10-13 15:08: one
/// read, two sets, the HTML row gone and the whole pane blank).
///
/// [verbs] = the call's verbs in wire order (a Set* in the same call
/// before a read is what that read sees); [shellOfHandle] bridges the
/// object token a verb names to its kernel shell (the session alias).
/// Reads on anything but a known splitter are not answered here (the
/// responder's defaults stay).
///
/// [held] = the layout the CLIENT holds since the server's last set of a
/// splitter axis, (splitter, rows?) -> index -> value: a sash the user
/// dragged ([splitterValuesFromExtents]). A drag is wire-silent; the next
/// read reports it (a recorded session KEY DECODE 1, 5), in the
/// splitter's own units, the row sum kept. a recorded session
/// calendar shows both on splitter 123 (O17): its first read (raw s43)
/// answers 4 / 16 / 0 after the launch set 0 / 20 / 0, and the read after
/// the first hide (raw s64) 4 / 11 / 9 after the set 4 / 20 / 0 — while
/// the read after the SECOND hide (raw s105), the same set 4 / 20 / 0, the
/// same verbs and the same button, echoes 4 / 20 / 0: identical wire
/// inputs, different answers, so no wire rule yields them — the human's
/// sash drags (the top sash down before the first submit, the calendar
/// sash up while it was hidden) do. The server then sets back what it
/// read (4 / 10 / 10 keeping row 1, 4 / 11 / 9): its Set* is the new
/// baseline and ends the hold ([splitterAxesSet]).
Map<int, String> splitterSizeReads(
  List<LayoutVerb> verbs,
  ControlRegistry reg, {
  String? Function(String handle)? shellOfHandle,
  Map<(String, bool), Map<int, double>> held = const {},
}) {
  final out = <int, String>{};
  // the extents this call set so far, over the registry's
  final setHere = <(String, bool), Map<int, double>>{};
  String? splitterOf(LayoutVerb v) => _splitterOfVerb(v, reg, shellOfHandle);

  String fmt(double x) =>
      x == x.roundToDouble() ? x.toInt().toString() : x.toString();

  for (final v in verbs) {
    final rowAxis = v.verb == 'GetRowHeight' || v.verb == 'SetRowHeight';
    final colAxis = v.verb == 'GetColumnWidth' || v.verb == 'SetColumnWidth';
    if (!rowAxis && !colAxis) continue;
    final sh = splitterOf(v);
    if (sh == null) continue;
    final f = reg.splitters[sh]!;
    final idx = int.tryParse((v.args['#1'] ?? '').trim());
    if (idx == null) continue;
    final declared = {
      ...(rowAxis ? f.rowPct : f.colPct),
      // the client's own layout since the server's last set (a drag)
      ...?(setHere.containsKey((sh, rowAxis)) ? null : held[(sh, rowAxis)]),
      ...?setHere[(sh, rowAxis)],
    };
    if (v.verb.startsWith('Set')) {
      final t = (v.args['#2'] ?? '').trim();
      final n = t.endsWith('-')
          ? -(double.tryParse(t.substring(0, t.length - 1)) ?? 0)
          : double.tryParse(t);
      if (n != null) (setHere[(sh, rowAxis)] ??= {})[idx] = n;
      continue;
    }
    final row = int.tryParse(v.result.trim());
    if (row == null || row < 1) continue;
    final n = math.max(rowAxis ? f.rows : f.cols, 1);
    final String value;
    if (declared.containsKey(idx)) {
      value = fmt(declared[idx]!);
    } else if (idx < 1 || idx > n) {
      continue; // past the grid, never set: not known here
    } else if ((rowAxis ? f.rowMode : f.colMode) != 0) {
      final set = [
        for (var i = 1; i <= n; i++)
          if (declared.containsKey(i)) math.max(declared[i]!, 0.0),
      ];
      final free = n - set.length;
      final left = 100 - set.fold(0.0, (a, b) => a + b);
      value = '${math.max(_pyRound(left / math.max(free, 1)), 0)}';
    } else {
      continue; // an absolute splitter's undeclared pixels: not known here
    }
    out[row - 1] = value;
  }
  return out;
}

/// The splitter [v] addresses (its object token, a kernel shell or a
/// handle [shellOfHandle] binds to one), or null.
String? _splitterOfVerb(
  LayoutVerb v,
  ControlRegistry reg,
  String? Function(String handle)? shellOfHandle,
) {
  final h = v.objValue.trim();
  if (h.isEmpty) return null;
  if (reg.splitters.containsKey(h)) return h;
  final sh = shellOfHandle?.call(h);
  return sh != null && reg.splitters.containsKey(sh) ? sh : null;
}

/// The splitter axes (splitter, rows?) [verbs] SET (`SetRowHeight` /
/// `SetColumnWidth`): the server's layout replaces whatever the client
/// held there ([splitterSizeReads] `held`).
Set<(String, bool)> splitterAxesSet(
  List<LayoutVerb> verbs,
  ControlRegistry reg, {
  String? Function(String handle)? shellOfHandle,
}) => {
  for (final v in verbs)
    if (v.verb == 'SetRowHeight' || v.verb == 'SetColumnWidth')
      if (_splitterOfVerb(v, reg, shellOfHandle) case final sh?)
        (sh, v.verb == 'SetRowHeight'),
};

/// The values a RELATIVE splitter axis reports once the user dragged its
/// sashes to [extents] (each row's / column's extent, in any one unit —
/// cells, pixels): the extents rescaled to the sum of the values it held
/// ([current], index -> value; 100 when they sum to nothing or one is
/// unset), whole numbers whose sum stays that sum (largest
/// remainder). a recorded session splitter 123: 0 / 20 / 0
/// dragged to 1 : 4 : 0 → 4 / 16 / 0; 4 / 20 / 0 dragged to 4 : 11 : 9 → 4 /
/// 11 / 9 — the sum (20, then 24) kept by every read the real GUI gave.
/// Null when [extents] is empty or sums to nothing, or a held value is
/// negative (an absolute or reserved extent: not a share to rescale).
Map<int, double>? splitterValuesFromExtents(
  Map<int, double> current,
  List<num> extents,
) {
  final n = extents.length;
  final total = extents.fold<num>(0, (a, b) => a + math.max(b, 0));
  if (n == 0 || total <= 0) return null;
  var sum = 0.0;
  var unset = false;
  for (var i = 1; i <= n; i++) {
    final v = current[i];
    if (v == null) {
      unset = true;
      continue;
    }
    if (v < 0) return null;
    sum += v;
  }
  // a share left unset takes what the declared ones leave of 100 (the
  // Easy Access splitter: SetColumnWidth(1, 31) alone): the whole is 100
  if (sum <= 0 || unset) sum = 100;
  final exact = [for (final e in extents) math.max(e, 0) * sum / total];
  final out = [for (final x in exact) x.floorToDouble()];
  var left = (sum - out.fold<double>(0, (a, b) => a + b)).round();
  final order = List.generate(n, (i) => i)
    ..sort((a, b) {
      final c = (exact[b] - out[b]).compareTo(exact[a] - out[a]);
      return c != 0 ? c : a.compareTo(b);
    });
  for (final i in order) {
    if (left <= 0) break;
    out[i] += 1;
    left--;
  }
  return {for (var i = 0; i < n; i++) i + 1: out[i]};
}

class _SashOnly extends LayoutSplitter {
  _SashOnly(String shell) : super('');
  bool get touchedModes => rowMode != 1 || colMode != 1;
}

/// A decoded table a region may host (the reference client's grid_tables entry:
/// `shell`, `tree`, its non-empty preview rows).
class LayoutTable {
  const LayoutTable(
    this.shell,
    this.rows, {
    this.tree = false,
    this.canvas = false,
  });
  final String shell;
  final int rows;
  final bool tree;

  /// A designer canvas (sap_canvas.dart): the reference client's
  /// canvas_rowsets.canvas_schematic_tables entry (`canvas: True`), which
  /// sapw_screenshot appends to grid_tables so the canvas is drawn
  /// in its splitter cell like a table (render_prepare.build_cell_items).
  final bool canvas;
}

/// Everything [composeScreen] reads besides the registry.
class LayoutInputs {
  LayoutInputs({
    required this.screen,
    this.window,
    this.area,
    this.tables = const [],
    this.chartShells = const {},
    this.graphShells = const {},
    this.contentShells = const {},
    this.editorLines = const {},
    this.htmlShells = const {},
    this.calendarShells = const {},
    this.pictureShells = const {},
    this.isLive,
    this.sinceStep,
    this.dockFraction,
    this.splitterHeld = const {},
  });

  final ScreenModel screen;

  /// The AREASIZE pairs (16/12/7: window, area), null without one.
  final (int, int)? window;
  final (int, int)? area;
  final List<LayoutTable> tables;
  final Set<String> chartShells;
  final Set<String> graphShells;

  /// shells a DataProvider push was bound to (render_ladder facts content)
  final Set<String> contentShells;

  /// editor shell -> line count, for every editor with a delivered body
  /// (render_ladder R4 'editor body'; text_editor.dart)
  final Map<String, int> editorLines;

  /// HTML viewer shells whose page arrived over DIAG (R10 — the DP push a
  /// ShowData named; html_viewer.dart)
  final Set<String> htmlShells;

  /// Calendar shells whose control is up (sap_calendar.dart): drawn as a
  /// month grid in their region (R11)
  final Set<String> calendarShells;

  /// Image control shells whose picture arrived (sap_picture.dart): drawn
  /// in their region (R3 'picture from the download store')
  final Set<String> pictureShells;
  final bool Function(String shell)? isLive;

  /// the step the current screen generation began at (_prog_since_step)
  final int? sinceStep;

  /// The layout the CLIENT holds on a splitter axis since the user dragged
  /// its sashes, (splitter, rows?) -> index -> value (the splitter's own
  /// units — [splitterValuesFromExtents]): over the server's values until
  /// the server sets that axis again (SapSession.noteSplitterSash).
  final Map<(String, bool), Map<int, double>> splitterHeld;

  /// The share of the window width a lone left/right dock realizes when
  /// the server's area is provisional (null: the latest request / 8 px
  /// per column, a fresh profile) — see _dockedBoxes.
  final double? dockFraction;
}

/// One box of the reference client's shell-box map, in dynpro-AREA cells (negative
/// top/left = a pane left of / above the area).
class _Box {
  _Box(
    this.top,
    this.left,
    this.height,
    this.width,
    this.kind, {
    this.parent,
    this.side,
    this.px,
    this.area,
  });
  int top;
  int left;
  int height;
  int width;
  String kind;
  String? parent;
  String? side;
  int? px;
  String? area;
  int contentRows = 0;
  bool paintsNothing = false;

  _Box copy() =>
      _Box(
          top,
          left,
          height,
          width,
          kind,
          parent: parent,
          side: side,
          px: px,
          area: area,
        )
        ..contentRows = contentRows
        ..paintsNothing = paintsNothing;

  (int, int, int, int) get rect => (top, left, height, width);
}

/// Python's round (banker's rounding) — the reference client's px -> cell rule.
int _pyRound(double x) {
  final f = x.floorToDouble();
  final d = x - f;
  if (d > 0.5) return f.toInt() + 1;
  if (d < 0.5) return f.toInt();
  return f.toInt().isEven ? f.toInt() : f.toInt() + 1;
}

/// The facts the layout derives from the registry once per compose.
class _Facts {
  _Facts(this.reg, this.inputs) : kinds = reg.kinds(), classes = reg.classes() {
    for (final c in reg.created) {
      order[c.shell] = order.length;
      gen[c.shell] = c.program;
      genStep[c.shell] = c.step;
    }
  }
  final ControlRegistry reg;
  final LayoutInputs inputs;
  final Map<String, String> kinds;
  final Map<String, String> classes;
  final Map<String, int> order = {};

  /// Splitter [sp]'s row ([rows]) or column values: the server's, the
  /// user's drag over them ([LayoutInputs.splitterHeld]).
  Map<int, double> pctOf(String sp, LayoutSplitter f, bool rows) {
    final held = inputs.splitterHeld[(sp, rows)];
    final own = rows ? f.rowPct : f.colPct;
    return held == null ? own : {...own, ...held};
  }

  /// the area width / height when a dock's extent departs from the
  /// AREASIZE pair (see _dockedBoxes), else null
  int? areaCols;
  int? areaRows;
  final Map<String, String?> gen = {};
  final Map<String, int> genStep = {};

  bool shellLive(String sh) => inputs.isLive?.call(sh) ?? true;

  /// [ControlRegistry.hidden], memoized for one compose
  bool hidden(String sh) => _hidden[sh] ??= reg.hidden(sh);
  final Map<String, bool> _hidden = {};

  /// render_ladder._current_generation_shells ∩ liveness
  bool liveThisGeneration(String sh) {
    if (!shellLive(sh)) return false;
    final prog = inputs.screen.program;
    final g = gen[sh];
    if (prog == null || g == prog) return true;
    final since = inputs.sinceStep;
    final st = genStep[sh];
    return since != null && st != null && st >= since;
  }

  /// editor_push.current_area_links, plus the binding rule of the jar (see
  /// [_bindsByName]): a link of an older screen generation still binds
  /// when its container would bind to this screen's area of that name.
  Map<String, String> currentAreaLinks() {
    final prog = inputs.screen.program;
    final since = inputs.sinceStep;
    final here = (prog, inputs.screen.dynpro);
    return {
      for (final e in reg.areaLinks.entries)
        if (prog == null ||
            e.value.$2 == prog ||
            (since != null && e.value.$3 >= since) ||
            reg.controlLinks[e.value.$1] == here ||
            _bindsByName(e.value.$1))
          if (shellLive(e.value.$1)) e.key: e.value.$1,
    };
  }

  /// Whether the LinkContainer'd container [sh] binds to the painted area
  /// of its name whatever screen generation linked it — the frontend's own
  /// rule, which never looks at the generation (platinr3S.jar
  /// GuiSession.checkCustomControlList, from GuiShell.linkContainer ->
  /// GuiCtlMgr.registerShellCustomControl, and the reverse order through
  /// GuiCustomControl.doRegistration -> GuiCtlMgr.checkShellList): the
  /// area name equal, the shell's program empty (no LinkControl) or the
  /// area's, its dynpro -1 or the area's, and its DYNPRO LEVEL equal — the
  /// CreateControl parent argument 10..19 (GuiCtlMgr.CreateControl: a
  /// session-level shell awaiting a link; 10 = the main window, 10 + n the
  /// n-th popup, GuiSession.computeDynproLevel). Liveness / the internal
  /// mode stay the caller's ([shellLive]).
  ///
  /// the reference client's generation filter alone (the link's program, or a step
  /// of the current generation) drops a link the moment the screen
  /// generation moves on without re-linking — a 16/6/13 program change, a
  /// later action's paint: PPOSE's TREE_CONTAINER 147, LIST_HOLDER 153 and
  /// LONGTEXT 161 (a recorded session srv[17] step 26: parent 10,
  /// LinkContainer only, no LinkControl, the areas declared at step 35)
  /// then fell to the R9 "no hosted shell known" wireframe, all three at
  /// once, although their tree / grid / TextEdit were up and fed — the
  /// live the test system (Windows) symptom; the live trigger itself is not recorded.
  bool _bindsByName(String sh) {
    final level = int.tryParse(reg.parents[sh] ?? '');
    if (level == null || level < 10 || level > 19) return false;
    if (level != 10 + inputs.screen.modalLevel) return false;
    final lc = reg.controlLinks[sh];
    if (lc == null) return true;
    final m = inputs.screen;
    return lc == (m.program, m.dynpro) || m.hostedDynpros.contains(lc);
  }

  /// parent -> children, built once per compose (the registry holds still
  /// while it runs): [subtree] asked for it per call, per dock and cell
  /// (audit #15). Read-only.
  Map<String, List<String>> children() => _children;

  late final Map<String, List<String>> _children = () {
    final out = <String, List<String>>{};
    reg.parents.forEach((sh, par) => (out[par] ??= []).add(sh));
    return out;
  }();

  /// [_emptyCellCollapse] of this compose (the box map and the sash pass
  /// both read it). Read-only.
  late final Map<String, (Set<int>, Set<int>)> collapse =
      _emptyCellCollapse(this);

  /// render_tiler.subtree_shells
  Set<String> subtree(String root) {
    final ch = children();
    final out = {root};
    final stack = [root];
    while (stack.isNotEmpty) {
      for (final k in ch[stack.removeLast()] ?? const <String>[]) {
        if (out.add(k)) stack.add(k);
      }
    }
    return out;
  }

  bool subtreeHasDrivable(String shell) {
    final ch = children();
    final seen = <String>{};
    final stack = [shell];
    while (stack.isNotEmpty) {
      final sh = stack.removeLast();
      if (!seen.add(sh)) continue;
      if (_drivableKinds.contains(kinds[sh])) return true;
      stack.addAll(ch[sh] ?? const []);
    }
    return false;
  }
}

/// splitter_layout._shares / _round_to
List<int> _shares(
  Map<int, double> pcts0,
  int n0,
  int total0,
  int mode,
  int pxPerCell, {
  Set<int> collapse = const {},
}) {
  final n = math.max(n0, 1);
  final total = math.max(total0, 0);
  final absolute = mode == 0;
  // a NEGATIVE extent (SetRowHeight(2, -1)) declares nothing: the row
  // takes its auto share of the rest. SM12's list (a recorded session
  // srv[116]: rows 0 / -1 / 0) shows the lock list alone, and srv[122]'s
  // (-1, 40) a 40 % detail row under it; read as 0 the -1 row vanished and
  // the empty statistics row 3 took the whole splitter
  final pcts = {
    for (final e in pcts0.entries)
      if (e.value >= 0) e.key: e.value,
  };
  if (!absolute) {
    final pct = {
      for (var i = 1; i <= n; i++)
        if (pcts.containsKey(i) && !collapse.contains(i))
          i: math.max(pcts[i]!, 0.0),
    };
    final sPct = pct.values.fold(0.0, (a, b) => a + b);
    var auto = [
      for (var i = 1; i <= n; i++)
        if (!pct.containsKey(i) && !collapse.contains(i)) i,
    ];
    Map<int, double> declared;
    if (sPct <= 100 && auto.isNotEmpty) {
      declared = pct.map((i, v) => MapEntry(i, total * v / 100.0));
    } else {
      declared = pct.map(
        (i, v) => MapEntry(i, sPct > 0 ? total * v / sPct : 0.0),
      );
      auto = [];
    }
    final rest = math.max(
      total - declared.values.fold(0.0, (a, b) => a + b),
      0.0,
    );
    final want = [
      for (var i = 1; i <= n; i++)
        collapse.contains(i)
            ? 0.0
            : declared[i] ?? (auto.contains(i) ? rest / auto.length : 0.0),
    ];
    return _roundTo(want, total);
  }
  final declared = <int, double>{};
  for (var i = 1; i <= n; i++) {
    if (!pcts.containsKey(i) || collapse.contains(i)) continue;
    declared[i] = math.max(pcts[i]! / pxPerCell, 0.0);
  }
  final dTotal = declared.values.fold(0.0, (a, b) => a + b);
  final auto = [
    for (var i = 1; i <= n; i++)
      if (!declared.containsKey(i) && !collapse.contains(i)) i,
  ];
  List<double> want;
  if (dTotal <= total) {
    final rest = total - dTotal;
    final share = auto.isEmpty ? 0.0 : rest / auto.length;
    want = [
      for (var i = 1; i <= n; i++)
        collapse.contains(i)
            ? 0.0
            : declared[i] ?? (auto.contains(i) ? share : 0.0),
    ];
  } else {
    final mean = declared.isEmpty ? 0.0 : dTotal / declared.length;
    final raw = [
      for (var i = 1; i <= n; i++)
        collapse.contains(i) ? 0.0 : declared[i] ?? mean,
    ];
    final s = raw.fold(0.0, (a, b) => a + b);
    want = [for (final x in raw) total * x / (s == 0 ? 1.0 : s)];
  }
  return _roundTo(want, total);
}

List<int> _roundTo(List<double> want, int total) {
  final out = [for (final x in want) math.max(_pyRound(x), 0)];
  final diff = total - out.fold<int>(0, (a, b) => a + b);
  if (out.isNotEmpty && diff != 0) {
    var j = out.length - 1;
    if (diff < 0) {
      j = 0;
      for (var k = 1; k < out.length; k++) {
        if (out[k] > out[j]) j = k;
      }
    }
    out[j] = math.max<int>(out[j] + diff, 0);
  }
  return out;
}

/// splitter_layout._cell_box
_Box _cellBox(
  _Box spb,
  LayoutSplitter f,
  int rr0,
  int cc0,
  Set<int> collapseRows,
  Set<int> collapseCols,
  String parent, {
  Map<int, double>? rowPct,
  Map<int, double>? colPct,
}) {
  final rh = _shares(
    rowPct ?? f.rowPct,
    f.rows == 0 ? 1 : f.rows,
    spb.height,
    f.rowMode,
    metricY2,
    collapse: collapseRows,
  );
  final cw = _shares(
    colPct ?? f.colPct,
    f.cols == 0 ? 1 : f.cols,
    spb.width,
    f.colMode,
    metricX2,
    collapse: collapseCols,
  );
  final rr = math.max(rr0, 1), cc = math.max(cc0, 1);
  var top = spb.top + rh.take(rr - 1).fold<int>(0, (a, b) => a + b);
  var left = spb.left + cw.take(cc - 1).fold<int>(0, (a, b) => a + b);
  final h = rh[math.min(rr, rh.length) - 1];
  final w = cw[math.min(cc, cw.length) - 1];
  final pb = spb.top + spb.height, pr = spb.left + spb.width;
  top = math.min<int>(math.max<int>(top, spb.top), pb);
  left = math.min<int>(math.max<int>(left, spb.left), pr);
  return _Box(
    top,
    left,
    math.max<int>(math.min<int>(h, pb - top), 0),
    math.max<int>(math.min<int>(w, pr - left), 0),
    'cell',
    parent: parent,
  );
}

/// Whether the painted window-minus-area [delta] (cells) of a LONE left /
/// right docking pane is the server's PROVISIONAL estimate, the pane
/// GuiGo's to realize and report in the `%_GS 0 3` layout round:
/// [requests] = the pane's 300 requests in cells (wire order, latest
/// last), [reportedDelta] = the delta the session last reported at. The
/// pair stands when the server laid out the LATEST request
/// (a recorded session: 50 = round(398 / 8);
/// a recorded session srv[11]: 25 = 200 / 8) or re-laid out
/// after our report (a recorded session srv[25]: 6 -> 105).
/// Anything else is provisional — the reference client's stale placeholder of an
/// EARLIER request (docked_layout.committed_extent: ST04 srv[23] 6 =
/// round(50 / 8) while the latest is 1360) AND a delta matching no request
/// at all, where the reference client trusts the pair and sends nothing:
/// a recorded session srv[21] paints 268 - 252 = 16 cols for dock 118
/// (requests 204 then 110: 26 / 14 cols) and the real Windows GUI DOES
/// report (gui[18]; srv[23] re-lays out to 54 cols); the live the test system ST04
/// launch paints 8 cols for 50 then 523 (6 / 65 cols).
bool provisionalDockDelta(int delta, List<int> requests, {int? reportedDelta}) {
  // within ONE cell: the server's px -> cells is not round (reference client
  // 2711bbc: a recorded session paints a 300-px request as 37 cols,
  // round(300 / 8) = 38)
  final current = requests.isNotEmpty && (requests.last - delta).abs() <= 1;
  final relaid = reportedDelta != null && reportedDelta != delta;
  return !current && !relaid;
}

/// docked_layout.committed_extent for ONE pane on an axis: (cells, stale)
/// from the painted window-minus-area [delta] and the pane's request
/// history [requests] in px (latest last), px -> cells by [metric] (each
/// at least 1): the delta when it is the latest request or no request at
/// all; the LATEST request, stale, when the delta is an EARLIER request's
/// placeholder; the latest request when nothing was painted.
(int, bool) committedExtent(int delta, List<int> requests, int metric) {
  int cellsOf(int px) => math.max(_pyRound(px / metric), 1);
  if (requests.isEmpty) return (0, false);
  final latest = cellsOf(requests.last);
  if (delta <= 0) return (latest, false);
  // cells compare within ONE cell (the server's px conversion is not
  // round: a recorded session 300 px -> 37 cols — reference client 2711bbc)
  bool near(int a, int b) => (a - b).abs() <= 1;
  if (near(delta, latest)) return (delta, false);
  final earlier = [
    for (final px in requests.sublist(0, requests.length - 1)) cellsOf(px),
  ];
  if (earlier.any((c) => near(delta, c))) return (latest, true);
  return (delta, false);
}

/// docked_layout.docked_boxes
Map<String, _Box> _dockedBoxes(
  _Facts fx,
  int areaRows,
  int areaCols0,
  (int, int)? window,
) {
  var areaCols = areaCols0;
  final out = <String, _Box>{};
  final winRows = window?.$1 ?? 0, winCols = window?.$2 ?? 0;
  final latestClass = <String, String>{};
  for (final c in fx.reg.created) {
    latestClass[c.shell] = c.cls;
  }
  const sides = {'1': 'left', '2': 'right', '3': 'top', '4': 'bottom'};
  for (final e in latestClass.entries) {
    final h = e.key;
    // a hidden dock (SetProperty 290 = 0) takes no window space: SM12's
    // server-administration dock 130 (a recorded session srv[114]/[115])
    if (!_isDockingClass(e.value) || !fx.shellLive(h) || fx.hidden(h)) {
      continue;
    }
    final p = fx.reg.props[h] ?? const {};
    final side = sides[(p[propDockSide] ?? '').trim()];
    final wRaw = (p[propControlWidth] ?? '').trim(),
        hRaw = (p[propControlHeight] ?? '').trim();
    final wPx = wRaw.isEmpty ? 0 : int.tryParse(wRaw);
    final hPx = hRaw.isEmpty ? 0 : int.tryParse(hRaw);
    if (wPx == null || hPx == null) continue;
    final horizontal = side != null
        ? (side == 'left' || side == 'right')
        : (wPx > 0 && hPx == 0);
    _Box box;
    if (horizontal) {
      if (wPx <= 0) continue;
      final cells = math.max(_pyRound(wPx / metricX2), 1);
      final left = side == 'right' ? areaCols : -cells;
      box = _Box(0, left, areaRows, cells, 'dock', px: wPx);
    } else {
      if (hPx <= 0) continue;
      final cells = math.max(_pyRound(hPx / metricY2), 1);
      final top = side == 'bottom' ? areaRows : -cells;
      box = _Box(top, 0, cells, areaCols, 'dock', px: hPx);
    }
    box.side = side ?? (horizontal ? 'left' : 'top');
    out[h] = box;
  }
  final horiz = [
    for (final e in out.entries)
      if (e.value.side == 'left' || e.value.side == 'right') e.key,
  ];
  final vert = [
    for (final e in out.entries)
      if (e.value.side == 'top' || e.value.side == 'bottom') e.key,
  ];
  // the reference client's docked_boxes adopted the stale-placeholder half of this
  // rule in 37e6240 (committed_extent: the latest request when the delta is
  // an EARLIER request's placeholder); what remains GuiGo's own is the
  // delta matching NO request (provisionalDockDelta — SE80 srv[21], the real
  // GUI reports it) and the remembered sash (dockFraction) in place of the
  // latest request. On the Windows profile the server's
  // 16/12/7 area is PROVISIONAL until the frontend reports the extent it
  // realized: the DB50 overview paints window 268 / area 262 cols
  // (a recorded session srv[23]) — 6 cols = round(50 / 8),
  // the dock's FIRST requested extent (300 = 50), stale against its final
  // request (300 = 1360) — and only after the real GUI's `%_GS 0 3` round
  // reports its realized area (gui[15] 16/12/8: window 1880 / area 1141 px,
  // CONTROL 135 PROPERTY 300 = 845) does the server re-lay out to area 163
  // (srv[25]/[27]): 105 cols = 39 % of the window, the operator's
  // reference-overview.png. So window minus area is taken only when it is
  // NOT one of the server's own requests (then it echoes a frontend-
  // realized extent); otherwise the latest request stands, converted at
  // the 8 px per column the reference client already uses — exactly what a fresh real
  // GUI realizes: 1360 -> 1190 px of 1880 (98-col area,
  // a recorded session gui[17]) and 742 -> 649 px
  // (a recorded session gui[18]), both = request / 8 cols.
  var horizChanged = false;
  if (horiz.length == 1 && winCols > areaCols && areaCols > 0) {
    final h = horiz.single;
    final b = out[h]!;
    final delta = winCols - areaCols;
    final asks = fx.reg.requested[h]?[propControlWidth] ?? const <String>[];
    int cellsOf(String v) => _pyRound((int.tryParse(v) ?? -1) / metricX2);
    // The pair is trusted when the server laid out its LATEST request (the
    // netplan test: area 243 = 268 - 200 / 8, a recorded session
    // srv[11]) or re-laid out after the frontend's report (the pair moved
    // since our layout round: the capture's srv[25] 6 -> 105). Anything
    // else is the server's provisional estimate and the pane is OURS to
    // realize: the capture's first paint (6 cols, the first request 50
    // while the latest is 1360) and the live the test system launch of 2026-10-09
    // (window 272 / area 264: 8 cols, matching neither request 50 nor
    // 523 — the reference client trace st04live, srv SAPLSHDBCCMS_35/36).
    final provisional = provisionalDockDelta(delta, [
      for (final v in asks) cellsOf(v),
    ], reportedDelta: fx.reg.reportedDelta[h]);
    // a pane the user dragged is ours until the server lays the area out
    // to it (a repaint at another delta)
    final dragged = fx.reg.draggedDelta[h] == delta;
    if (!provisional && !dragged) {
      b.width = delta;
    } else {
      // the extent we realize ourselves: a remembered sash share of the
      // window (SapSession.dockFraction), else the request (fresh profile)
      final f = fx.inputs.dockFraction;
      if (f != null) b.width = math.max(_pyRound(f * winCols), 1);
      horizChanged = true;
    }
    if (b.side == 'left') b.left = -b.width;
  }
  if (horizChanged && winCols > 0) {
    // the area is what the panes leave of the window (never below 1 col)
    var used = 0;
    for (final k in horiz) {
      final b = out[k]!;
      b.width = math.min(b.width, math.max(winCols - 1 - used, 1));
      used += b.width;
      if (b.side == 'left') b.left = -b.width;
    }
    fx.areaCols = winCols - used;
    for (final k in horiz) {
      if (out[k]!.side == 'right') out[k]!.left = fx.areaCols!;
    }
    areaCols = fx.areaCols!;
  }
  if (vert.length == 1 && winRows > areaRows && areaRows > 0) {
    // the reference client's committed_extent on the vertical axis (37e6240): the
    // painted window-minus-area is the pane's height unless it is the
    // server's STALE placeholder of an EARLIER 120 request while a later
    // one exists — then the pane takes the latest request and the area is
    // what it leaves of the window (the layout round reports it, as on the
    // horizontal axis). No corpus capture shows a lone vertical dock
    // painted stale (the ST04 bottom band is two panes: the painted delta
    // stands), so the reference client's strict rule is taken as it is.
    final h = vert.single;
    final b = out[h]!;
    final asks = [
      for (final v in fx.reg.requested[h]?[propControlHeight] ?? const <String>[])
        if (int.tryParse(v) case final px? when px > 0) px,
    ];
    final (cells, stale) = committedExtent(
      winRows - areaRows,
      asks.isEmpty ? [b.px ?? 0] : asks,
      metricY2,
    );
    b.height = cells;
    if (stale) {
      areaRows = math.max(winRows - cells, 1);
      fx.areaRows = areaRows;
      if (b.side == 'bottom') b.top = areaRows;
      for (final k in horiz) {
        out[k]!.height = areaRows;
      }
    }
    if (b.side == 'top') b.top = -b.height;
  }
  for (final (sideKey, edge) in [('bottom', areaRows), ('top', 0)]) {
    final group = [
      for (final e in out.entries)
        if (e.value.side == sideKey) e.key,
    ]..sort((a, b) => -(fx.order[a] ?? 0).compareTo(fx.order[b] ?? 0));
    if (group.length < 2) continue;
    var pos = sideKey == 'bottom' ? edge : -out[group.first]!.height;
    for (final k in group) {
      final b = out[k]!;
      b.top = pos;
      pos = sideKey == 'bottom' ? pos + b.height : pos - b.height;
    }
  }
  var leftW = 0, rightW = 0;
  for (final b in out.values) {
    if (b.side == 'left') leftW += b.width;
    if (b.side == 'right') rightW += b.width;
  }
  if (leftW > 0 || rightW > 0) {
    for (final b in out.values) {
      if (b.side == 'top' || b.side == 'bottom') {
        b.left = -leftW;
        b.width = areaCols + leftW + rightW;
      }
    }
  }
  return out;
}

/// splitter_layout._area_size
(int, int) _areaSize(LayoutInputs inp) {
  final a = inp.area;
  if (a != null && a.$1 != 0 && a.$2 != 0) return a;
  var rows = 0, cols = 0;
  for (final g in inp.screen.containers.values) {
    rows = math.max(rows, g.row + g.height);
    cols = math.max(cols, g.col + g.width);
  }
  if (rows != 0 && cols != 0) return (rows, cols);
  return (inp.screen.windowRows, inp.screen.windowCols);
}

/// A bar the server builds from two pictures: a 1 x 2 splitter in the
/// hosted subtree [hs] whose cells both hold an image and whose column 1
/// width (relative mode, percent) it set — (splitter, percent, the
/// pictures' tooltip or "<percent> %").
(String, double, String)? _splitterGauge(_Facts fx, Set<String> hs) {
  final ch = fx.children();
  bool hostsImage(String sh) =>
      fx.subtree(sh).any((k) => fx.kinds[k] == 'image');
  for (final sp in hs) {
    final f = fx.reg.splitters[sp];
    if (f == null || f.cols != 2 || f.rows > 1 || f.colMode != 1) continue;
    final pct = f.colPct[1];
    final a = f.cells[(1, 1)], b = f.cells[(1, 2)];
    if (pct == null || pct < 0 || a == null || b == null) continue;
    if (!hostsImage(a) || !hostsImage(b)) continue;
    String? tip;
    for (final c in [a, b]) {
      for (final k in [c, ...?ch[c]]) {
        tip ??= fx.reg.toolTips[k];
      }
    }
    return (sp, pct, tip ?? '${_g(pct)} %');
  }
  return null;
}

/// The control kinds that make a splitter cell hold content: the reference client's
/// drivable ones plus the controls drawn from what the server pushes — a
/// chart (`SAPGraphics.Chart.1`), a network graph, the date picker. The
/// reference client's _DRIVABLE_KINDS alone read a chart's cell as EMPTY and
/// collapsed it to 0 rows: the grids of the other cells took the whole
/// area and the chart, its cell gone, was drawn over all of them (the DBA
/// cockpit's load history; chart_splitter_cell_test.dart).
/// splitter_layout._empty_cell_collapse: a row / column collapses only when
/// NO control is under any of its cells — any control kind holds its cell,
/// only layout containers (container / splitter / docking: 'container')
/// do not (reference client 6c9ed12; the jar's GuiSplitterLayout never inspects cell
/// content). SE80's object-list row (a recorded session srv[10]:
/// splitter 140, the combo box 149 and the name field 153 in column 1 =
/// 225 px) lost column 1 and row 2 to the drivable-kinds rule.
Map<String, (Set<int>, Set<int>)> _emptyCellCollapse(_Facts fx) {
  if (fx.kinds.isEmpty) return {};
  final ch = fx.children();
  bool hasContent(String sh, Set<String> seen) {
    if (!seen.add(sh)) return false;
    final k = fx.kinds[sh];
    if (k != null && k.isNotEmpty && k != 'container') return true;
    return (ch[sh] ?? const []).any((k) => hasContent(k, seen));
  }

  final out = <String, (Set<int>, Set<int>)>{};
  fx.reg.splitters.forEach((sp, f) {
    if (f.cells.isEmpty) return;
    final rows = {for (final k in f.cells.keys) k.$1};
    final cols = {for (final k in f.cells.keys) k.$2};
    bool empty((int, int) k) => !hasContent(f.cells[k]!, {});
    final er = {
      for (final rr in rows)
        if ([
          for (final cc in cols)
            if (f.cells.containsKey((rr, cc))) (rr, cc),
        ].every(empty))
          rr,
    };
    final ec = {
      for (final cc in cols)
        if ([
          for (final rr in rows)
            if (f.cells.containsKey((rr, cc))) (rr, cc),
        ].every(empty))
          cc,
    };
    if (er.isNotEmpty || ec.isNotEmpty) out[sp] = (er, ec);
  });
  return out;
}

/// splitter_layout._share_pane (with _persistent_pane_roots)
void _sharePane(
  _Facts fx,
  Map<String, _Box> boxes,
  int areaRows,
  int areaCols,
  int winCols,
) {
  final prog = fx.inputs.screen.program;
  final roots = <String>{};
  fx.reg.parents.forEach((sh, par) {
    if ((par != '0' && par != '10') || boxes.containsKey(sh)) return;
    if (fx.gen[sh] == prog) return;
    // DEPARTURE from _persistent_pane_roots: a container LinkContainer'd
    // to a dynpro area shows only while that area is painted (the
    // area_links loop boxes it then). The Easy Access menu (101 linked to
    // SAPLSMTR_NAVIGATION's IMAGE_CONTAINER) is never destroyed by the
    // ST04 launch (a recorded session srv[11..27]) yet the
    // real GUI shows no trace of it beside DB50/0100
    // (a recorded session the
    // left pane is the DBA cockpit tree alone).
    if (fx.reg.areaLinks.values.any((l) => l.$1 == sh)) return;
    if (_isDockingClass(fx.classes[sh] ?? '')) return;
    if (!fx.shellLive(sh) || fx.hidden(sh)) return;
    if (fx.subtreeHasDrivable(sh)) roots.add(sh);
  });
  if (roots.isEmpty) return;
  final sorted = roots.toList()
    ..sort(
      (a, b) => a.length != b.length ? a.length - b.length : a.compareTo(b),
    );
  String? dsh;
  _Box? b;
  for (final e in boxes.entries) {
    if (e.value.kind == 'dock' && e.value.side == 'left') {
      dsh = e.key;
      b = e.value;
      break;
    }
  }
  if (b == null) {
    if (!(winCols != 0 &&
        areaCols != 0 &&
        0 < areaCols &&
        areaCols < winCols)) {
      return;
    }
    final w = winCols - areaCols;
    b = _Box(0, -w, math.max(areaRows, 1), w, 'pane');
  }
  final tenants = [...sorted];
  if (dsh != null && fx.subtreeHasDrivable(dsh)) tenants.add(dsh);
  final top = b.top, left = b.left, width = b.width, height = b.height;
  final share = math.max(height ~/ tenants.length, 1);
  for (var i = 0; i < tenants.length; i++) {
    final t = tenants[i];
    final tTop = math.min(top + i * share, top + height - 1);
    final tH = math.max(math.min(share, top + height - tTop), 1);
    if (t == dsh) {
      b
        ..top = tTop
        ..height = tH;
    } else {
      boxes[t] = _Box(tTop, left, tH, width, 'pane');
    }
  }
}

/// splitter_layout._toolbar_rows
void _toolbarRows(_Facts fx, Map<String, _Box> boxes) {
  if (fx.kinds.isEmpty) return;
  final byRect = <(String?, (int, int, int, int)), List<String>>{};
  boxes.forEach((sh, b) {
    if (b.kind == 'control') (byRect[(b.parent, b.rect)] ??= []).add(sh);
  });
  byRect.forEach((key, kids) {
    final tbs = [
      for (final k in kids)
        if (fx.kinds[k] == 'toolbar') k,
    ];
    final others = [
      for (final k in kids)
        if (fx.kinds[k] != 'toolbar') k,
    ];
    final rect = key.$2;
    if (tbs.length != 1 || others.isEmpty || rect.$3 <= 1) return;
    boxes[tbs.single]!.height = 1;
    for (final o in others) {
      boxes[o]!
        ..top = rect.$1 + 1
        ..height = math.max(rect.$3 - 1, 1);
    }
  });
}

/// splitter_layout.shell_boxes
Map<String, _Box> _shellBoxes(_Facts fx) {
  final boxes = <String, _Box>{};
  final (ar, ac) = _areaSize(fx.inputs);
  final win = fx.inputs.window;
  boxes.addAll(_dockedBoxes(fx, ar, ac, win));
  fx.currentAreaLinks().forEach((name, sh) {
    final g = fx.inputs.screen.containers[name];
    if (g == null || fx.hidden(sh)) return;
    boxes[sh] = _Box(g.row, g.col, g.height, g.width, 'container', area: name);
  });
  if (boxes.isEmpty) return boxes;
  _sharePane(fx, boxes, fx.areaRows ?? ar, fx.areaCols ?? ac, win?.$2 ?? 0);
  final cellOf = <String, (String, (int, int))>{};
  fx.reg.splitters.forEach((sp, f) {
    f.cells.forEach((rc, cell) => cellOf[cell] = (sp, rc));
  });
  final collapse = fx.collapse;
  var changed = true;
  var guard = 0;
  while (changed && guard < 64) {
    changed = false;
    guard++;
    fx.reg.parents.forEach((sh, par) {
      if (boxes.containsKey(sh) || !boxes.containsKey(par)) return;
      // a hidden control and its subtree take no box: nothing of it is
      // drawn (SM12's splitter 119 and its grids, a recorded session
      // srv[114] SetProperty(119, 290, 0))
      if (fx.hidden(sh)) return;
      final cell = cellOf[sh];
      if (cell != null) {
        final (sp, (rr, cc)) = cell;
        final spb = boxes[sp];
        if (spb == null) return;
        final (er, ec) = collapse[sp] ?? (<int>{}, <int>{});
        final f = fx.reg.splitters[sp]!;
        boxes[sh] = _cellBox(
          spb,
          f,
          rr,
          cc,
          er,
          ec,
          sp,
          rowPct: fx.pctOf(sp, f, true),
          colPct: fx.pctOf(sp, f, false),
        );
      } else {
        final pb = boxes[par]!;
        boxes[sh] = _Box(
          pb.top,
          pb.left,
          pb.height,
          pb.width,
          fx.reg.splitters.containsKey(sh) ? 'splitter' : 'control',
          parent: par,
        );
      }
      changed = true;
    });
  }
  _toolbarRows(fx, boxes);
  _alignedStack(fx, boxes);
  return boxes;
}

/// Two sibling controls sharing their parent's box, one ALIGNED to its
/// top with a HEIGHT (no bottom bit), one to its bottom (no top bit) below
/// a TOP: the first keeps that strip, the second the rest — the ALV grid's
/// in-place Excel view (CL_SALV_GRU_VIEW_EXCEL set_visible, the real SAP
/// GUI for Windows' a recorded session srv[59]: the grid
/// 118 `ALIGN 7` (left|right|top) `HEIGHT 22` — its toolbar strip — and
/// the Office container 246 `METRIC 1` (pixel) `TOP 22` `ALIGN 11`
/// (left|right|bottom), both children of the docking container 117). The
/// switch back (srv[90]) is the grid's `ALIGN 15` (fill) and the
/// container's `290 = 0` (hidden: no box) — the rule no longer applies.
void _alignedStack(_Facts fx, Map<String, _Box> boxes) {
  final byRect = <(String?, (int, int, int, int)), List<String>>{};
  boxes.forEach((sh, b) {
    if (b.kind == 'control') (byRect[(b.parent, b.rect)] ??= []).add(sh);
  });
  String prop(String sh, String id) => (fx.reg.props[sh]?[id] ?? '').trim();
  int? align(String sh) => int.tryParse(prop(sh, propAlign));
  // a pixel extent / position in rows (the default metric's units are the
  // METRICS ones, [metricY2]); 0 when unset
  int rows(String sh, String id) {
    final v = double.tryParse(prop(sh, id));
    if (v == null || v <= 0) return 0;
    final per = prop(sh, propMetric) == metricPixel ? cellH : metricY2;
    return math.max(_pyRound(v / per), 1);
  }

  byRect.forEach((key, kids) {
    final rect = key.$2;
    if (kids.length < 2 || rect.$3 <= 1) return;
    String? strip, rest;
    for (final k in kids) {
      final a = align(k);
      if (a == null) continue;
      final top = a & alignAtTop != 0, bottom = a & alignAtBottom != 0;
      if (top && !bottom && rows(k, propControlHeight) > 0) strip ??= k;
      if (bottom && !top) rest ??= k;
    }
    if (strip == null || rest == null) return;
    final h = math.min(rows(strip, propControlHeight), rect.$3 - 1);
    final off = math.min(
      math.max(rows(rest, propTop), h),
      rect.$3 - 1,
    );
    boxes[strip]!.height = h;
    boxes[rest]!
      ..top = rect.$1 + off
      ..height = rect.$3 - off;
  });
}

/// render_tiler.content_sized_docks (+ _dock_drawable, _apply_shifts)
Map<String, _Box> _contentSizedDocks(_Facts fx, Map<String, _Box> boxes) {
  final out = <String, _Box>{};
  final docks = {
    for (final e in boxes.entries)
      if (e.value.kind == 'dock') e.key: e.value,
  };
  if (docks.isEmpty) return out;
  final shifts = <(String, int, int)>[];
  docks.forEach((k, b) {
    final sub = fx.subtree(k);
    bool inDock(String sh) {
      final cb = boxes[sh];
      if (cb == null || (cb.kind != 'cell' && cb.kind != 'control')) {
        return false;
      }
      return cb.top >= b.top &&
          cb.left >= b.left &&
          cb.top + cb.height <= b.top + b.height &&
          cb.left + cb.width <= b.left + b.width;
    }

    var rows = 0;
    for (final t in fx.inputs.tables) {
      if (t.shell.isNotEmpty && (sub.contains(t.shell) || inDock(t.shell))) {
        rows = math.max(rows, t.rows);
      }
    }
    var drawable = rows > 0;
    if (!drawable) {
      for (final sh in fx.reg.toolbarButtons.keys) {
        final tb = boxes[sh];
        if (sub.contains(sh) && tb != null && tb.height > 0 && tb.width > 0) {
          drawable = true;
          break;
        }
      }
    }
    if (rows > 0 && b.height < 2 + math.min<int>(rows, 4)) {
      final newH = 2 + math.min<int>(rows, 4);
      out[k] = b.copy()
        ..height = newH
        ..contentRows = rows;
      for (final sh in sub) {
        final cb = boxes[sh];
        if (cb == null || sh == k) continue;
        if (cb.rect == b.rect) out[sh] = cb.copy()..height = newH;
      }
    } else if (!drawable && b.height > 0) {
      out[k] = b.copy()
        ..height = 0
        ..paintsNothing = true;
      shifts.add((b.side ?? '', b.top + b.height, b.height));
    }
  });
  for (final (side, fromTop, delta) in shifts) {
    docks.forEach((k2, b2) {
      if ((b2.side ?? '') != side || b2.top < fromTop) return;
      final base = out[k2] ?? b2;
      out[k2] = base.copy()..top = base.top - delta;
      for (final sh in fx.subtree(k2)) {
        if (sh == k2) continue;
        final cb = out[sh] ?? boxes[sh];
        if (cb != null && (boxes[sh]?.top ?? 0) >= fromTop) {
          out[sh] = cb.copy()..top = cb.top - delta;
        }
      }
    });
  }
  return out;
}

/// diag_render._field_cells
int _fieldCells(ScreenField f) {
  final mx = f.maxnrchars, ml = f.mlen;
  final width = mx == 0 ? ml : (ml != 0 ? math.min(mx, ml) : mx);
  return math.max(math.max(width, f.text.length), 1);
}

class _Carve {
  int rows = 0;
  int cols = 0;
  int originRow = 0;
  int originCol = 0;
  bool carved = false;
  String degraded = '';
}

/// render_tiler.carve_window (fields_fit, unique_docks, _carve_pane,
/// _carve_children). [boxes] is updated in place.
_Carve _carveWindow(
  LayoutInputs inp,
  Map<String, _Box> boxes,
  int cols0,
  int rows0,
  (int, int)? area, {
  Map<String, int> created = const {},
}) {
  final win = inp.window;
  final docks = {
    for (final e in boxes.entries)
      if (e.value.kind == 'dock') e.key: e.value,
  };
  var fit = true;
  if (win != null) {
    var fr = 0, fc = 0;
    for (final f in inp.screen.fields) {
      fr = math.max(fr, f.row);
      fc = math.max(fc, f.col + _fieldCells(f));
    }
    fit = fr < win.$1 && fc <= win.$2 * 2;
  }
  final out = _Carve();
  if (win != null &&
      area != null &&
      fit &&
      win.$1 >= area.$1 &&
      area.$1 >= 0 &&
      win.$2 >= area.$2 &&
      area.$2 > 0) {
    final (wr, wc) = win;
    final (ar, ac) = area;
    final uniq = <(String?, (int, int, int, int)), _Box>{};
    for (final b in docks.values) {
      uniq.putIfAbsent((b.side, b.rect), () => b);
    }
    // The docks in ATTACH order, the way the frontend lays its working pane
    // out (platinr3S.jar GuiWorkingPaneLayout.doGuiLayout: the main
    // window's components in order, each GuiDockShell taking the FULL
    // length of its side within the rectangle still free at its turn —
    // West (left, top, w, free height), South (left, bottom - h, free
    // width, h), … — the user area the rest). So the pane docked first
    // spans its whole side and a later one only what is left beside it:
    // the DBA cockpit's message strip (created before the navigation dock)
    // runs under the tree across the window, the tree ends above it; two
    // panes never overlap and their sashes never cross. The extent on an
    // axis is capped so the free rectangle keeps the painted AREA (the
    // 16/12/7 pair is what the server laid the dynpro out for): a dock
    // grown to its content rows (_contentSizedDocks) must not cover the
    // area's last rows and run through the side panes.
    final order = <_Box, int>{
      for (final e in docks.entries) e.value: created[e.key] ?? 0,
    };
    final attach = uniq.values.toList()
      ..sort((a, b) => (order[a] ?? 0).compareTo(order[b] ?? 0));
    var fTop = 0, fLeft = 0, fBottom = wr, fRight = wc;
    // (no room at all: the pair does not account for the pane — the Java
    // dialect paints area = window, a recorded session — and
    // the pane keeps its extent, as before the attach walk)
    int capped(int ext, int room) => room <= 0 || ext <= room ? ext : room;
    final placed = <_Box, (int, int, int, int)>{}; // window cells
    for (final b in attach) {
      switch (b.side) {
        case 'left':
          final w = capped(b.width, fRight - fLeft - ac);
          placed[b] = (fTop, fLeft, fBottom - fTop, w);
          fLeft += w;
        case 'right':
          final w = capped(b.width, fRight - fLeft - ac);
          placed[b] = (fTop, fRight - w, fBottom - fTop, w);
          fRight -= w;
        case 'top':
          final h = capped(b.height, fBottom - fTop - ar);
          placed[b] = (fTop, fLeft, h, fRight - fLeft);
          fTop += h;
        case 'bottom':
          final h = capped(b.height, fBottom - fTop - ar);
          placed[b] = (fBottom - h, fLeft, h, fRight - fLeft);
          fBottom -= h;
      }
    }
    final originRow = fTop, originCol = fLeft;
    final carved = <String, _Box>{};
    docks.forEach((k2, b2) {
      if (!identical(uniq[(b2.side, b2.rect)], b2)) return;
      final p = placed[b2];
      if (p == null) return;
      final old = b2.rect;
      final nb = b2.copy()
        ..top = p.$1 - originRow
        ..left = p.$2 - originCol
        ..height = p.$3
        ..width = p.$4;
      carved[k2] = nb;
      final (dTop, dLeft) = (nb.top - old.$1, nb.left - old.$2);
      // a box of the pane's own subtree (its parent chain reaches the
      // dock): only those fill the carved pane. A dynpro AREA's control
      // that merely shares the band of a full-height left dock — SE80's
      // welcome HTML 157 in container 156 LinkContainer'd to IMAGE (rows
      // 0..37, the dock 118's rows too; a recorded session srv[12])
      // — was carved INTO the dock, over the Repository Browser.
      bool inPane(_Box b) {
        var p = b.parent;
        for (var i = 0; p != null && i < 64; i++) {
          if (p == k2) return true;
          p = boxes[p]?.parent;
        }
        return false;
      }

      boxes.forEach((sh2, cb2) {
        if (carved.containsKey(sh2) ||
            (cb2.kind != 'cell' && cb2.kind != 'control')) {
          return;
        }
        final cr = cb2.rect;
        final vertical = b2.side == 'top' || b2.side == 'bottom';
        final same =
            inPane(cb2) &&
            (cr == old ||
                (vertical &&
                    (cr.$2, cr.$3, cr.$4) == (old.$2, old.$3, old.$4)) ||
                (!vertical && (cr.$1, cr.$3) == (old.$1, old.$3)));
        if (same) {
          carved[sh2] = cb2.copy()
            ..width = nb.width
            ..left = nb.left
            ..top = nb.top
            ..height = nb.height;
        } else if ((dTop != 0 || dLeft != 0) &&
            cr.$1 >= old.$1 &&
            cr.$2 >= old.$2 &&
            cr.$1 + cr.$3 <= old.$1 + old.$3 &&
            cr.$2 + cr.$4 <= old.$2 + old.$4) {
          // a cell inside the pane moves with it
          carved[sh2] = cb2.copy()
            ..top = cr.$1 + dTop
            ..left = cr.$2 + dLeft;
        }
      });
    });
    boxes.addAll(carved);
    return out
      ..cols = wc
      ..rows = wr
      ..originRow = originRow
      ..originCol = originCol
      ..carved = true;
  }
  var originRow = 0, originCol = 0, cols = cols0, rows = rows0;
  for (final b in docks.values) {
    originRow = math.max(originRow, -b.top);
    originCol = math.max(originCol, -b.left);
  }
  for (final b in docks.values) {
    cols = math.max(cols, b.left + b.width);
    rows = math.max(rows, b.top + b.height);
  }
  out
    ..cols = cols + originCol
    ..rows = rows + originRow
    ..originRow = originRow
    ..originCol = originCol;
  out.degraded = (win == null || area == null)
      ? 'no AREASIZE on the paint — the canvas is the content bounding '
            'box; the tiling invariants are unverifiable'
      : 'the painted AREASIZE cannot hold this screen\'s atoms (a stale '
            'pair) — the canvas is the content bounding box; the tiling '
            'invariants are unverifiable';
  return out;
}

/// render_prepare.content_extent (fields, frames, controls)
(int, int) _contentExtent(ScreenModel m, int? areaBottom) {
  var cols = 80, rows = 24;
  for (final f in m.fields) {
    cols = math.max(cols, f.col + _fieldCells(f) + 1);
    rows = math.max(rows, f.row + 2);
  }
  for (final fr in m.frames) {
    cols = math.max(cols, fr.col + math.max(fr.dcols, fr.text.length + 1));
    rows = math.max(rows, fr.row + fr.drows + 1);
  }
  for (final c in m.containers.values) {
    if (c.kind != 10 || c.width == 0) continue;
    if (areaBottom != null && c.row >= areaBottom) continue;
    cols = math.max(cols, c.col + c.width);
    var rh = c.row + c.height;
    if (areaBottom != null) rh = math.min(rh, areaBottom);
    rows = math.max(rows, rh);
  }
  return (cols, rows);
}

final RegExp _numRx = RegExp(r'[0-9][0-9\s.,]*');

/// render_regions.gauge_ratio: (used, limit, ratio) of a `used / limit`
/// meter text ('129,85 GB /250,00 GB' -> (129.85, 250, 0.519)).
(double, double, double)? gaugeRatio(String value) {
  final parts = value.split('/');
  if (parts.length != 2) return null;
  final nums = <double>[];
  for (final p in parts) {
    final m = _numRx.firstMatch(p);
    if (m == null) return null;
    final v = double.tryParse(
      m.group(0)!.replaceAll(_whitespaceRx, '').replaceAll(',', '.'),
    );
    if (v == null) return null;
    nums.add(v);
  }
  final (used, limit) = (nums[0], nums[1]);
  if (limit <= 0 || used < 0) return null;
  return (used, limit, math.max(0.0, math.min(used / limit, 1.0)));
}

/// Python's `{x:g}` for the ledger text.
String _g(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  var s = v.toStringAsPrecision(6);
  if (s.contains('.') && !s.contains('e')) {
    s = s.replaceFirst(_trailingZerosRx, '').replaceFirst(_trailingDotRx, '');
  }
  return s;
}

String _kindOfShell(String? k) => switch (k) {
  'tree' => 'tree',
  'grid' => 'grid',
  'chart' => 'chart',
  'image' => 'image',
  'html' => 'html',
  'jnet' => 'netplan',
  'editor' => 'editor',
  'calendar' => 'calendar',
  'office' => 'office',
  _ => 'control',
};

String _reason(String rung, String? shell, String note) {
  final b = StringBuffer(ladderRungs[rung] ?? rung);
  if (shell != null && shell.isNotEmpty) b.write(' (shell $shell)');
  if (note.isNotEmpty) b.write(' — $note');
  return b.toString();
}

/// The window composition of [inputs.screen] (render orchestration:
/// shell boxes -> content-sized docks -> carve -> cell items / dock hosts
/// -> control regions through the ladder). Regions are in WINDOW cells
/// (the carve origin applied).
List<ScreenRegion> composeScreen(
  ControlRegistry reg,
  LayoutInputs inputs, {
  List<SplitterSash>? sashes,
  Map<String, CellRect>? boxesOut,
}) {
  final fx = _Facts(reg, inputs);
  final m = inputs.screen;
  final modelBoxes = _shellBoxes(fx);
  final boxes = {for (final e in modelBoxes.entries) e.key: e.value.copy()};
  boxes.addAll(_contentSizedDocks(fx, boxes));

  // render_prepare.area_edges
  int? areaBottom, areaRight;
  final bt = [
    for (final b in modelBoxes.values)
      if (b.kind == 'dock' && b.side == 'bottom') b.top,
  ];
  if (bt.isNotEmpty) areaBottom = bt.reduce(math.min);
  final win = inputs.window;
  // the area the docks leave (_dockedBoxes' departure), else the pair's
  final area = inputs.area == null
      ? null
      : (fx.areaRows ?? inputs.area!.$1, fx.areaCols ?? inputs.area!.$2);
  if (win != null &&
      area != null &&
      win.$1 >= area.$1 &&
      area.$1 >= 0 &&
      win.$2 >= area.$2 &&
      area.$2 > 0) {
    areaRight = area.$2;
    areaBottom = area.$1;
  }
  final (cols0, rows0) = _contentExtent(m, areaBottom);
  final carve = _carveWindow(
    inputs,
    boxes,
    cols0,
    rows0,
    area,
    created: fx.order,
  );
  final oRow = carve.originRow, oCol = carve.originCol;
  CellRect at(int top, int left, int h, int w) => CellRect(
    (top + oRow).toDouble(),
    (left + oCol).toDouble(),
    h.toDouble(),
    w.toDouble(),
  );

  final regions = <ScreenRegion>[];
  final ar = area?.$1 ?? (carve.rows - oRow);
  final ac = area?.$2 ?? (carve.cols - oCol);
  regions.add(
    ScreenRegion(
      kind: 'dynpro',
      rect: at(0, 0, ar, ac),
      rung: 'R1',
      reason: _reason(
        'R1',
        null,
        carve.carved
            ? 'the AREASIZE area ${ar}x$ac of the ${carve.rows}x${carve.cols} '
                  'window (render_tiler.carve_window)'
            : carve.degraded,
      ),
    ),
  );

  // render_prepare.build_cell_items: a table drawn in its shell's box
  _Box? boxOf(String sh) {
    final b = boxes[sh];
    if (b != null &&
        (b.kind == 'cell' || b.kind == 'control') &&
        b.height != 0 &&
        b.width != 0) {
      return b;
    }
    return null;
  }

  final cellItems = <(_Box, LayoutTable)>[];
  final seenCell = <(int, int, int, int)>{};
  for (final t in inputs.tables) {
    final b = boxOf(t.shell);
    if (b == null) continue;
    // diag_render._one_item_per_cell: one item per cell rect
    if (!seenCell.add(b.rect)) continue;
    cellItems.add((b, t));
  }

  // render_prepare.ledger_dock_hosts
  final dockNote = <String, String>{};
  final namedDocks = <String>{};
  for (final (cb, t) in cellItems) {
    var key = cb.parent ?? '';
    var box = boxes[key];
    while (box != null && box.kind != 'dock') {
      key = box.parent ?? '';
      box = boxes[key];
    }
    var reason = _reason('R2', t.shell, 'splitter cell drawn with content');
    if (box != null && namedDocks.add(key)) {
      final rows = box.contentRows;
      final sub = box.height < 2 && (box.side == 'top' || box.side == 'bottom');
      final note =
          '${box.side} docked pane hosts it (${box.px} px strip'
          '${sub ? ' — sub-cell extent, minimum strip' : ''}'
          '${rows != 0 ? '; $rows data row(s) delivered — pane expanded' : ''})';
      dockNote[key] = note;
      reason = _reason('R2', t.shell, note);
    } else if (box != null) {
      reason = _reason('R2', t.shell, dockNote[key]!);
    }
    regions.add(
      ScreenRegion(
        kind: t.tree
            ? 'tree'
            : t.canvas
            ? 'canvas'
            : _kindOfShell(fx.kinds[t.shell]),
        shell: t.shell,
        container: box != null ? key : null,
        rect: at(cb.top, cb.left, cb.height, cb.width),
        rung: 'R2',
        reason: reason,
      ),
    );
  }

  // the docks that paint nothing (render: note_stacked R1)
  boxes.forEach((dk, db) {
    if (db.kind != 'dock' || !db.paintsNothing) return;
    regions.add(
      ScreenRegion(
        kind: 'control',
        shell: dk,
        container: dk,
        rect: at(db.top, db.left, db.height, db.width),
        rung: 'R1',
        reason: _reason(
          'R1',
          dk,
          'docked pane paints nothing — no delivered content under it '
              '(extent ${db.px} px stays on the wire)',
        ),
      ),
    );
  });

  // render_stacked.draw_toolbars: a toolbar with buttons in its box
  reg.toolbarButtons.forEach((sh, buttons) {
    final b = boxOf(sh);
    if (b == null || buttons.isEmpty || !fx.shellLive(sh)) return;
    regions.add(
      ScreenRegion(
        kind: 'control',
        shell: sh,
        rect: at(b.top, b.left, b.height, b.width),
        rung: 'TB',
        reason:
            'control toolbar, ${buttons.length} button(s) drawn in its box '
            '(render_stacked.draw_toolbars)',
      ),
    );
  });

  // GuiGo's own: a DOI container in a DOCKED pane drawn as its Office
  // document in its box — the ALV in-place Excel's container 246 in the
  // grid's docking container 117 (a recorded session srv[50],
  // below the grid's strip: [_alignedStack]), OAOR's 127 in dock 122
  // (srv[170]). A container in a dynpro area takes the area's 'OF' rung
  // (the containers loop below); a docked one had no rung at all.
  fx.kinds.forEach((sh, kind) {
    if (kind != 'office') return;
    final b = boxOf(sh);
    if (b == null || !fx.shellLive(sh) || fx.hidden(sh)) return;
    var key = b.parent;
    var up = key == null ? null : boxes[key];
    for (var guard = 0; up != null && up.kind != 'dock' && guard < 32; guard++) {
      key = up.parent;
      up = key == null ? null : boxes[key];
    }
    if (up == null) return;
    regions.add(
      ScreenRegion(
        kind: 'office',
        shell: sh,
        container: key,
        rect: at(b.top, b.left, b.height, b.width),
        rung: 'OF',
        reason: _reason('OF', sh, 'Office document drawn in its docked box'),
      ),
    );
  });

  // GuiGo's own: a CFW combo box / input field drawn in its box (SE80's
  // object-list type and object name, splitter 140's cells 143 / 145 —
  // a recorded session srv[10..11]; session/sap_session_cfw_fields.dart
  // holds their state). the reference client's renderer draws neither, so no rung
  // took them: their row of the dock stayed empty and the controls were
  // never on the screen.
  fx.classes.forEach((sh, cls) {
    if (!_cfwFieldClass.hasMatch(cls)) return;
    final b = boxOf(sh);
    if (b == null || !fx.shellLive(sh) || fx.hidden(sh)) return;
    regions.add(
      ScreenRegion(
        kind: 'control',
        shell: sh,
        rect: at(b.top, b.left, b.height, b.width),
        rung: 'CF',
        reason: _reason('CF', sh, 'drawn in its box'),
      ),
    );
  });

  // the dynpro's control regions through the ladder (draw_regions)
  final links = fx.currentAreaLinks();
  final fieldBoxes = _fieldBoxes(m);
  final contentShells = {
    ...inputs.contentShells,
    for (final t in inputs.tables) t.shell,
    ...reg.toolbarButtons.keys,
    ...inputs.chartShells,
    ...inputs.graphShells,
    ...inputs.calendarShells,
  };
  final tableShells = {for (final t in inputs.tables) t.shell};
  for (final c in m.containers.values) {
    if (c.kind != 10) continue;
    final name = c.name;
    final top = c.row, left = c.col, wch = c.width;
    var h = c.height;
    final beyond = areaBottom != null && top >= areaBottom;
    final rightClipped = areaRight != null && left >= areaRight;
    final hostRoots = <String>{
      ?links[name.toUpperCase()],
      for (final e in modelBoxes.entries)
        if (e.value.area == name) e.key,
    };
    final hs = <String>{};
    // the hidden part of the hosted subtree (SetProperty 290 = 0 on it or
    // above it): not drawn, not waited for
    final hiddenHs = <String>{};
    for (final r in hostRoots) {
      for (final sh in fx.subtree(r)) {
        (fx.hidden(sh) ? hiddenHs : hs).add(sh);
      }
    }
    final hsSorted = hs.toList()
      ..sort(
        (a, b) => a.length != b.length ? a.length - b.length : a.compareTo(b),
      );
    final rect = at(top, left, c.height, wch);
    ScreenRegion region(
      String rung,
      String note, {
      String? shell,
      String? kind,
      double? gauge,
      String? gaugeText,
      CellRect? at,
    }) => ScreenRegion(
      kind: kind ?? 'control',
      shell: shell,
      container: name,
      rect: at ?? rect,
      rung: rung,
      reason: _reason(rung, shell, note),
      gauge: gauge,
      gaugeText: gaugeText,
    );
    if (beyond || rightClipped) {
      regions.add(
        region('R1', 'beyond the painted area — the window clips it'),
      );
      continue;
    }
    if (areaBottom != null && top + h > areaBottom) {
      h = math.max(areaBottom - top, 0);
      if (h <= 0) {
        regions.add(
          region('R1', 'beyond the painted area — the window clips it'),
        );
        continue;
      }
    }
    if (h == 0 || wch == 0) {
      regions.add(region('R9', 'no screen region'));
      continue;
    }
    // _resolve
    final composited = fieldBoxes.any(
      (f) =>
          f.$1 >= top &&
          f.$1 < top + h &&
          f.$2 >= left &&
          f.$2 + f.$3 <= left + wch,
    );
    final chartSh = hsSorted.where(inputs.chartShells.contains).firstOrNull;
    final graphSh = hsSorted.where(inputs.graphShells.contains).firstOrNull;
    // an editor / HTML viewer in a SPLITTER CELL of the area is drawn in
    // its cell, not over the whole area (where it covered the cells beside
    // it), and not at all when its cell is collapsed. SBWP (SAPLSINWP/1000,
    // a recorded session reference client recv steps 18..30): SINWP_CONTAINER 115 ->
    // splitter 116 1 x 2 (column 1 = 33 %): cell 117 the folder tree 122 |
    // cell 118 -> splitter 119 2 x 1: cell 120 the document list 125, cell
    // 121 the HTML viewer 126; step 30 sizes 119's rows 0 / 100 — the
    // start page fills the right column, the tree stays beside it. The
    // viewer drawn on the area's 170 columns hid the tree.
    CellRect? ownCell(String sh) {
      final b = boxes[sh];
      if (b == null || (b.kind != 'cell' && b.kind != 'control')) return null;
      return CellRect(
        (b.top + oRow).toDouble(),
        (b.left + oCol).toDouble(),
        b.height.toDouble(),
        b.width.toDouble(),
      );
    }

    bool shown(String sh) {
      final r = ownCell(sh);
      return r == null || (r.rows > 0 && r.cols > 0);
    }

    // a calendar in a collapsed cell (its row sized 0) shows nothing: as
    // the area's calendar it took the dispatch from the HTML viewer in the
    // cell beside it (below)
    final calSh = hsSorted
        .where(
          (sh) =>
              inputs.calendarShells.contains(sh) &&
              fx.shellLive(sh) &&
              shown(sh),
        )
        .firstOrNull;
    // a calendar in a SPLITTER CELL of the area of its own is drawn in that
    // cell, whatever else the area's other cells hold — as a chart is
    // (above). /AIF/IFMON's left pane (a recorded session raw srv[17]
    // / srv[20]: MAIN_CUSTOM 119 -> splitter 122 column 1 -> splitter 125
    // 3 x 1: cell 127 the HTML selection 129, cell 128 the date navigator
    // 144) shows the selection form AND, once the server sizes row 3
    // (raw srv[40] step 53: rows 0 / 10 / 10) and shows the navigator
    // (raw srv[47]: SetProperty(144, 290, 1)), the month grid under it:
    // the one area dispatch below drew one of them only.
    final calInCell = () {
      if (calSh == null) return false;
      final c = ownCell(calSh);
      return c != null &&
          c != rect &&
          c.row >= rect.row &&
          c.col >= rect.col &&
          c.row + c.rows <= rect.row + rect.rows &&
          c.col + c.cols <= rect.col + rect.cols;
    }();
    if (calInCell) {
      regions.add(
        region(
          'R11',
          'calendar drawn in its splitter cell',
          shell: calSh,
          kind: 'calendar',
          at: ownCell(calSh!),
        ),
      );
    }
    // a picture in a SPLITTER CELL of its own is drawn in that cell,
    // beside whatever the area's other cells hold — the Easy Access
    // IMAGE_CONTAINER: container 101 -> splitter 102 1 x 2 (column 1 31 %,
    // no sash verb: movable), the menu tree 105 in cell 103, the session
    // picture SESS_IMAGE 106 (displayMode 1) in cell 104
    // (a recorded session srv[5]: its bytes pushed on the
    // cold PublishUrl, srv[6..12]). Read as the area's one dispatch the
    // tree took it and the picture was never drawn
    bool inOwnCell(String sh) {
      final c = ownCell(sh);
      return c != null &&
          c != rect &&
          c.row >= rect.row &&
          c.col >= rect.col &&
          c.row + c.rows <= rect.row + rect.rows &&
          c.col + c.cols <= rect.col + rect.cols;
    }

    // (a picture the server builds a bar from — the DB50 overview's, a
    // 1 x 2 splitter of a picture beside its value — stays the gauge)
    final gauged =
        _gaugePair(name, m.fields) != null || _splitterGauge(fx, hs) != null;
    final picCells = [
      if (!gauged)
        for (final sh in hsSorted)
          if (inputs.pictureShells.contains(sh) &&
              fx.shellLive(sh) &&
              !fx.hidden(sh) &&
              shown(sh) &&
              inOwnCell(sh))
            sh,
    ];
    for (final sh in picCells) {
      regions.add(
        region(
          'R3',
          'picture drawn in its splitter cell',
          shell: sh,
          kind: 'image',
          at: ownCell(sh),
        ),
      );
    }

    final editSh = hsSorted
        .where(
          (sh) =>
              inputs.editorLines.containsKey(sh) &&
              fx.shellLive(sh) &&
              shown(sh),
        )
        .firstOrNull;
    final htmlSh = hsSorted
        .where(
          (sh) =>
              inputs.htmlShells.contains(sh) && fx.shellLive(sh) && shown(sh),
        )
        .firstOrNull;
    // a DOI container: its area shows the Office document it holds
    final officeSh = hsSorted
        .where(
          (sh) => fx.kinds[sh] == 'office' && fx.shellLive(sh) && shown(sh),
        )
        .firstOrNull;
    // a cell item belongs to this area when the area HOSTS its shell (its
    // LinkContainer'd subtree), else when its box lies in the area's
    // DECLARED rect — not the window-clipped one ([h]): the box map lays
    // the area out at its painted geometry, and the clip to the window
    // comes last (_clipToArea). Against the clipped rect an area reaching
    // past the window's bottom never held its own grid: PPOSE's LIST_HOLDER
    // (r12, 8 rows in a 17-row window — a recorded session srv[22],
    // the dynpro 22 rows tall) drew grid 154 AND the R9 "no hosted shell
    // known" wireframe over it.
    bool inside(_Box b) =>
        b.top >= top &&
        b.left >= left &&
        b.top + b.height <= top + c.height &&
        b.left + b.width <= left + wch;
    bool hostedCell((_Box, LayoutTable) ci) =>
        hs.contains(ci.$2.shell) || inside(ci.$1);
    final hostsCells = cellItems.any(hostedCell);
    final structOnly =
        hs.isNotEmpty &&
        hs.every((sh) => _structuralKinds.contains(fx.kinds[sh])) &&
        chartSh == null &&
        graphSh == null &&
        calSh == null &&
        !hostsCells;
    // render_ladder R3: the picture the server pushed for the control
    // (STMS SAPLTMSU/0100: GN_DYN102_IMAGE -> container 117 -> picture
    // 118, a recorded session srv[12..14]). An area that also hosts a
    // tree / grid (the Easy Access IMAGE_CONTAINER: menu tree 105 beside
    // the SESS_IMAGE picture 106) keeps its table reading, and a picture
    // the server builds a bar from (the DB50 overview: a picture beside its
    // value field, a 1 x 2 splitter of two) stays the schematic gauge.
    final picSh =
        hs.any(tableShells.contains) ||
            _gaugePair(name, m.fields) != null ||
            _splitterGauge(fx, hs) != null
        ? null
        : hsSorted
              .where(
                (sh) =>
                    inputs.pictureShells.contains(sh) &&
                    fx.shellLive(sh) &&
                    shown(sh) &&
                    !picCells.contains(sh),
              )
              .firstOrNull;
    // _dispatch
    if (chartSh != null || graphSh != null) {
      // a chart / graph in a SPLITTER CELL of the area is drawn in its own
      // cell, as the editor / HTML viewer below are — over the whole area
      // it covered the grids in the cells beside it (DBACOCKPIT's load
      // history: the hosts and KPI grids in the upper cells, the time
      // series chart in its own cell, all in one custom-control area).
      // Every charted cell is its own region; a chart without a cell of
      // its own (DB50/0219: directly in CONTAINER_DB_SIZE_MEM_CHART) takes
      // the area. the reference client draws the first chart over the whole area
      // (render_regions._rung_chart_graph).
      bool inCell(String sh) {
        final c = ownCell(sh);
        return c != null &&
            c != rect &&
            c.row >= rect.row &&
            c.col >= rect.col &&
            c.row + c.rows <= rect.row + rect.rows &&
            c.col + c.cols <= rect.col + rect.cols;
      }

      final drawn = [
        for (final sh in hsSorted)
          if ((inputs.chartShells.contains(sh) ||
                  inputs.graphShells.contains(sh)) &&
              !fx.hidden(sh) &&
              shown(sh))
            sh,
      ];
      final own = drawn.any(inCell);
      for (final sh in own ? drawn.where(inCell) : [chartSh ?? graphSh!]) {
        final chart = inputs.chartShells.contains(sh);
        regions.add(
          region(
            chart ? 'R5' : 'R6',
            chart ? 'chart drawn in its region' : 'graph drawn',
            shell: sh,
            kind: chart ? 'chart' : 'netplan',
            at: own ? ownCell(sh) : null,
          ),
        );
      }
    } else if (calSh != null && !calInCell) {
      // the date picker the server hosts for a DATS F4 (a recorded session
      // controls srv[1]: container 115 LinkContainer'd into the popup's
      // CONTAINER area, the calendar 116 in it): the whole area
      regions.add(
        region(
          'R11',
          'calendar drawn in its region',
          shell: calSh,
          kind: 'calendar',
          at: ownCell(calSh),
        ),
      );
    } else if (editSh != null) {
      regions.add(
        region(
          'R4',
          'editor body, ${inputs.editorLines[editSh]} line(s)',
          shell: editSh,
          kind: 'editor',
          at: ownCell(editSh),
        ),
      );
    } else if (htmlSh != null) {
      regions.add(
        region(
          'R10',
          'HTML document drawn in its region',
          shell: htmlSh,
          kind: 'html',
          at: ownCell(htmlSh),
        ),
      );
    } else if (officeSh != null) {
      regions.add(
        region(
          'OF',
          'Office document container',
          shell: officeSh,
          kind: 'office',
          at: ownCell(officeSh),
        ),
      );
    } else if (picSh != null) {
      regions.add(
        region(
          'R3',
          'picture drawn in its region',
          shell: picSh,
          kind: 'image',
          at: ownCell(picSh),
        ),
      );
    } else if ((calInCell || picCells.isNotEmpty) && !hostsCells) {
      // the calendar / picture alone: drawn in its cell above
    } else if (composited) {
      regions.add(region('R1', 'invisible layout container'));
    } else if (!hostsCells &&
        hiddenHs.isNotEmpty &&
        hs.every((sh) => _structuralKinds.contains(fx.kinds[sh]))) {
      // every control the area hosts is hidden: the area shows its empty
      // container, as SAP GUI does — not a "content not delivered" R7 box
      // (SM12 before its list runs: CONTAINER_MAIN 118 -> hidden splitter
      // 119 -> grids 126-129, a recorded session srv[114]/[115])
      final top = (hiddenHs.toList()
            ..sort(
              (a, b) => (fx.order[a] ?? 0).compareTo(fx.order[b] ?? 0),
            ))
          .first;
      regions.add(
        region(
          'R1',
          'hosted controls hidden (SetProperty $top 290 = 0) — the empty '
              'container shows',
        ),
      );
    } else if (structOnly) {
      regions.add(
        region('R1', 'invisible layout container (structural shells only)'),
      );
    } else if (hostsCells) {
      // render_regions._rung_cells: the reference client's ledger names the first
      // cell's shell, but the content is drawn by the cell items alone
      // (render_stacked.draw_cells) — the area region itself draws nothing.
      // So the shell rides the reason only: as the region's [shell] it
      // made a consumer draw the hosted control a second time over the
      // whole area — the ST04 "Fichiers INI" tree 327 at the container's
      // row 0 AND in its splitter cell one row lower, below toolbar 326
      // (a recorded session srv step 104: container 322
      // LinkContainer INIFILE_CONTENTS_ALV_CONTAINER -> splitter 323 ->
      // cell 325 hosting toolbar 326 + tree 327).
      final inCells = [
        for (final ci in cellItems)
          if (hostedCell(ci)) ci.$2.shell,
      ];
      regions.add(
        ScreenRegion(
          kind: 'control',
          container: name,
          rect: rect,
          rung: 'R2',
          reason: _reason(
            'R2',
            inCells.firstOrNull,
            '${inCells.length} splitter cell(s) drawn with content',
          ),
        ),
      );
    } else {
      // _rung_tail (no on-demand window model here)
      final waiting = [
        for (final sh in hsSorted)
          if (fx.liveThisGeneration(sh) &&
              !contentShells.contains(sh) &&
              fx.kinds[sh] != null &&
              !_structuralKinds.contains(fx.kinds[sh]))
            sh,
      ];
      if (waiting.isNotEmpty) {
        final w0 = waiting.first;
        final imgSh = hsSorted
            .where((sh) => fx.kinds[sh] == 'image')
            .firstOrNull;
        final pair = imgSh == null ? null : _gaugePair(name, m.fields);
        if (pair != null) {
          final (f, used, limit, ratio) = pair;
          final seg = (f.name ?? '').split('-').last;
          regions.add(
            region(
              'R5',
              'schematic gauge (R5 nominal: image-display host $imgSh + '
                  'paired field) — ${_pyRound(ratio * 100)}% from field '
                  '$seg (${_g(used)}/${_g(limit)}); picture url not bound',
              kind: 'image',
              gauge: ratio,
              gaugeText: f.text.trim(),
            ),
          );
        } else if (_splitterGauge(fx, hs) case (
          final sp,
          final pct,
          final text,
        )) {
          // no paired field (the overview's CPU bar: GRAPH_DB_CPU, its
          // value only in the pictures' tooltip "7 %"): the bar as the
          // server built it — a 1 x 2 splitter of two pictures (a grey
          // fill, a white rest) whose column 1 is the value in percent
          // (a recorded session srv[21]: splitter 254
          // SetColumnWidth(1, 7), images 258 DB6_BG_GRAY / 257
          // DB6_BG_WHITE). The pictures are MIME repository backgrounds
          // (loadImageFromURLAsync SAPR3://WebRepository/…): nothing
          // more is ever pushed for them — the reference client's R7 "no content
          // channel yet" waited for content that never comes.
          regions.add(
            region(
              'R5',
              'schematic gauge (image-display host $imgSh in splitter '
                  '$sp) — ${_g(pct)}% from its column 1 width',
              kind: 'image',
              gauge: (pct / 100).clamp(0.0, 1.0),
              gaugeText: text,
            ),
          );
        } else {
          regions.add(
            region(
              'R7',
              '${fx.kinds[w0]} control, no content channel yet',
              shell: w0,
              kind: _kindOfShell(fx.kinds[w0]),
            ),
          );
        }
      } else {
        regions.add(region('R9', 'no hosted shell known'));
      }
    }
  }
  // the splitter sashes the program fixed (locked or hidden): 'sash'
  // regions, drawn by nothing — the client keeps them where the server
  // put them (a free sash is the client's to drag)
  final collapse = fx.collapse;
  fx.reg.splitters.forEach((sp, f) {
    final spb = boxes[sp];
    if (spb == null || !fx.shellLive(sp)) return;
    final (er, ec) = collapse[sp] ?? (<int>{}, <int>{});
    final rows = f.rows == 0 ? 1 : f.rows, cols = f.cols == 0 ? 1 : f.cols;
    final rh = _shares(
      fx.pctOf(sp, f, true),
      rows,
      spb.height,
      f.rowMode,
      metricY2,
      collapse: er,
    );
    final cw = _shares(
      fx.pctOf(sp, f, false),
      cols,
      spb.width,
      f.colMode,
      metricX2,
      collapse: ec,
    );
    final box = at(spb.top, spb.left, spb.height, spb.width);
    var y = spb.top;
    for (var k = 1; k < rows; k++) {
      y += rh[k - 1];
      sashes?.add(
        SplitterSash(
          splitter: sp,
          rows: true,
          index: k,
          line: at(y, spb.left, 0, spb.width),
          box: box,
          spans: List.unmodifiable(rh),
          fixed: f.rowSashFixed(k) || er.contains(k) || er.contains(k + 1),
          mode: f.rowMode,
        ),
      );
      if (!f.rowSashFixed(k)) continue;
      regions.add(
        ScreenRegion(
          kind: 'sash',
          shell: null,
          container: sp,
          rect: at(y, spb.left, 0, spb.width),
          rung: 'SASH',
          reason: 'splitter $sp row sash $k fixed (SetRowSash)',
        ),
      );
    }
    var x = spb.left;
    for (var k = 1; k < cols; k++) {
      x += cw[k - 1];
      sashes?.add(
        SplitterSash(
          splitter: sp,
          rows: false,
          index: k,
          line: at(spb.top, x, spb.height, 0),
          box: box,
          spans: List.unmodifiable(cw),
          fixed: f.colSashFixed(k) || ec.contains(k) || ec.contains(k + 1),
          mode: f.colMode,
        ),
      );
      if (!f.colSashFixed(k)) continue;
      regions.add(
        ScreenRegion(
          kind: 'sash',
          shell: null,
          container: sp,
          rect: at(spb.top, x, spb.height, 0),
          rung: 'SASH',
          reason: 'splitter $sp column sash $k fixed (SetColumnSash)',
        ),
      );
    }
  });
  if (boxesOut != null) {
    boxes.forEach((sh, b) {
      boxesOut[sh] = at(b.top, b.left, b.height, b.width);
    });
  }
  return _clipToArea(regions);
}

/// The values a splitter axis holds once the user dragged its cells to
/// [extents] (cells): a relative axis its shares rescaled to the sum it
/// held ([splitterValuesFromExtents]); an ABSOLUTE one (SetRowMode /
/// SetColumnMode 0) its pixels — each cell's [metricY2] / [metricX2] px,
/// the composition's own conversion — its last row (column) left to take
/// the rest unless [current] declares it. Null when nothing can be held.
Map<int, double>? splitterHeldValues(
  Map<int, double> current,
  List<num> extents, {
  required bool absolute,
  required bool rows,
}) {
  if (!absolute) return splitterValuesFromExtents(current, extents);
  final n = extents.length;
  if (n == 0) return null;
  final px = rows ? metricY2 : metricX2;
  return {
    for (var i = 1; i <= n; i++)
      if (i < n || current.containsKey(i))
        i: (math.max(extents[i - 1], 0) * px).roundToDouble(),
  };
}

/// What a client round reports after the user dragged the sashes of the
/// splitters [dragged]: per shell, ascending, the realized size (120
/// height / 300 width) of every shell INSIDE them that registered it as a
/// cached prop (RegisterCachedProp), the server did not set itself
/// ([ControlRegistry.props]) and whose value differs from the one last
/// flushed ([ControlRegistry.flushedSizes], updated here: the drag is
/// reported once) — the real GUI's dirty report: a sash drag sends nothing
/// of its own, its effect rides the next round as these sizes
/// (a recorded session KEY DECODE 1 / 2: `CONTROLS 262 300=1799
/// only`, the pane a drag grew; a recorded session: its
/// splitter cells register nothing, so a drag inside LOAD_HISTORY_CONTAINER
/// adds nothing). [boxes] = the shells' composed boxes in window cells
/// ([composeScreen] boxesOut); the values in the session's METRICS (cols x
/// 8, rows x 13.64, the area containers' model). [isLive] filters the
/// shells on screen.
List<(String, List<(String, String)>)> splitterDragSizes(
  ControlRegistry reg,
  Map<String, CellRect> boxes,
  Set<String> dragged, {
  bool Function(String shell)? isLive,
}) {
  bool under(String sh) {
    String? p = reg.parents[sh];
    for (var i = 0; i < 32 && p != null; i++) {
      if (dragged.contains(p)) return true;
      p = reg.parents[p];
    }
    return false;
  }

  final shells = [
    for (final e in reg.cachedProps.entries)
      if ((isLive?.call(e.key) ?? true) &&
          under(e.key) &&
          (e.value.contains(propControlHeight) ||
              e.value.contains(propControlWidth)))
        e.key,
  ]..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
  final out = <(String, List<(String, String)>)>[];
  for (final sh in shells) {
    final b = boxes[sh];
    if (b == null) continue;
    final set = reg.props[sh] ?? const <String, String>{};
    final done = reg.flushedSizes[sh] ??= {};
    final props = <(String, String)>[];
    for (final p in reg.cachedProps[sh]!) {
      if (set.containsKey(p)) continue;
      final v = switch (p) {
        propControlWidth => '${b.cols.round() * 8}',
        propControlHeight => '${(b.rows * 13.64 + 0.5).floor()}',
        _ => null,
      };
      if (v == null || done[p] == v) continue;
      done[p] = v;
      props.add((p, v));
    }
    if (props.isNotEmpty) out.add((sh, props));
  }
  return out;
}

/// One sash of a splitter as the composition lays it out — between its
/// row (column) [index] and [index] + 1: a zero-height (row) / zero-width
/// (column) [line] in window cells, the splitter's [box], the extents
/// ([spans], cells) of all its rows (columns). [fixed]: the program locked
/// or hid it (SetRowSash / SetColumnSash movable / visible false), or a
/// cell beside it holds nothing and collapsed — the user cannot drag it;
/// a free sash is the client's own to drag (SapSession.noteSplitterSash).
/// [mode] = the axis' SetRowMode / SetColumnMode (1 relative, 0 absolute).
class SplitterSash {
  const SplitterSash({
    required this.splitter,
    required this.rows,
    required this.index,
    required this.line,
    required this.box,
    required this.spans,
    required this.fixed,
    required this.mode,
  });

  final String splitter;
  final bool rows;
  final int index;
  final CellRect line;
  final CellRect box;
  final List<int> spans;
  final bool fixed;
  final int mode;

  /// The extents after moving this sash by [delta] cells (down / right
  /// positive), each of the two cells beside it kept at least [minCells]
  /// (a cell already under it stays as it is): the drag the user made, as
  /// SapSession.noteSplitterSash takes it.
  List<int> movedBy(int delta, {int minCells = 1}) {
    final out = List.of(spans);
    final a = index - 1, b = index;
    if (a < 0 || b >= out.length) return out;
    final lo = -math.max(out[a] - math.min(minCells, out[a]), 0);
    final hi = math.max(out[b] - math.min(minCells, out[b]), 0);
    final d = delta.clamp(lo, hi).toInt();
    out[a] += d;
    out[b] -= d;
    return out;
  }

  @override
  String toString() =>
      'SplitterSash($splitter ${rows ? 'row' : 'column'} $index '
      '${fixed ? 'fixed' : 'free'} $line $spans)';
}

/// Every region that starts inside the dynpro area ends at its edges: the
/// window shows a custom-control area — and the splitter cells in it — only
/// as far as the area reaches (SAP GUI clips the dynpro there; the reference client
/// clips its drawing to the area's bottom, render_regions.draw_regions, and
/// to its canvas). Unclipped, a container painted past the area's bottom
/// lay over the bottom docked pane (the DBA cockpit's message list), and
/// one past its right edge widened the composed window — every pane of it
/// drawn smaller. A region starting outside the area (a docked pane, an R1
/// region beyond the area) keeps its rect.
List<ScreenRegion> _clipToArea(List<ScreenRegion> regions) {
  final dyn = regions.where((r) => r.kind == 'dynpro').firstOrNull?.rect;
  if (dyn == null) return regions;
  final bottom = dyn.row + dyn.rows, right = dyn.col + dyn.cols;
  return [
    for (final r in regions)
      if (r.kind == 'dynpro' ||
          r.rect.row < dyn.row ||
          r.rect.col < dyn.col ||
          r.rect.row >= bottom ||
          r.rect.col >= right ||
          (r.rect.row + r.rect.rows <= bottom &&
              r.rect.col + r.rect.cols <= right))
        r
      else
        ScreenRegion(
          kind: r.kind,
          shell: r.shell,
          container: r.container,
          rect: CellRect(
            r.rect.row,
            r.rect.col,
            math.min(r.rect.rows, bottom - r.rect.row),
            math.min(r.rect.cols, right - r.rect.col),
          ),
          rung: r.rung,
          reason: r.reason,
          gauge: r.gauge,
          gaugeText: r.gaugeText,
        ),
  ];
}

/// render_regions.gauge_pair: GRAPH_<X> <-> the field whose name's last
/// segment is <X> and whose text parses as used / limit.
(ScreenField, double, double, double)? _gaugePair(
  String name,
  List<ScreenField> fields,
) {
  if (!name.startsWith('GRAPH_')) return null;
  final want = name.substring(6).trim().toUpperCase();
  if (want.isEmpty) return null;
  for (final f in fields) {
    final seg = (f.name ?? '').split('-').last.trim().toUpperCase();
    if (seg != want) continue;
    final g = gaugeRatio(f.text);
    if (g != null) return (f, g.$1, g.$2, g.$3);
  }
  return null;
}

/// The drawn field boxes (render_passes.draw_fields) in cells: (row, col,
/// width) — input fields at their capacity, outputs at their text.
List<(int, int, int)> _fieldBoxes(ScreenModel m) => [
  for (final f in m.fields)
    if (!f.invisible)
      if (f.kind == FieldKind.input && !f.isProtected)
        (f.row, f.col, _fieldCells(f))
      else if (f.text.trim().isNotEmpty)
        (f.row, f.col, f.text.length),
];

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call (audit #7 / zcode P-12).
final RegExp _letterRx = RegExp('[A-Za-z]');
final RegExp _whitespaceRx = RegExp(r'\s');
final RegExp _trailingZerosRx = RegExp(r'0+$');
final RegExp _trailingDotRx = RegExp(r'\.$');
