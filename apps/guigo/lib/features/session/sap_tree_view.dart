import 'dart:async';
import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../../core/sap_icons.dart';
import 'column_edge_grip.dart';
import 'sap_graph_view.dart';
import 'session_busy.dart';

/// A server tree control (the SAP Easy Access menu, SE80's object list,
/// the DBA cockpit's navigation tree, …) as an indented, expandable list,
/// with SAP GUI's two hit areas per row:
///
/// * the EXPANDER (the arrow before a folder, [expanderHitWidth] wide):
/// opens or closes the folder. Children already on the client toggle
/// locally (no round — the real GUI sends no event for them, and a
/// second 18 on a loaded node dumps CL_GUI_ALV_TREE's
/// SET_CHILDREN_AT_FRONT, reference client click_node); a folder whose children
/// are still on the server (EXPANDER) asks for them through [onExpand]
/// (18 EXPANDNOCHILDREN, a recorded session gui[105]) and opens
/// when they arrive. Every local open / close goes to [onToggle] (the
/// tree's `ExpandedKeys` read-back).
/// * the node's ICON and TEXT: a tap selects the node ([onSelect]: the
/// tree's SelectionKeys, its 21 SELCHANGE when registered); a DOUBLE tap
/// is SAP GUI's double-click — the tree's node / item double-click event
/// through [onActivate] for a leaf AND a folder (SE80's object root
/// `SAPMS01GNEW` opens the program: a recorded session gui[26] `%_GC
/// 152 25` on the root ` 1`, gui[44] on the folder ` 4`), the
/// folder left as it was. Only a tree that handles no double-click
/// ([handlesDoubleClick] false) toggles the folder instead, the front
/// end's own default. A folder whose children were never pushed is
/// opened AND activated — [onActivate] for it too, the session sending
/// WDTTREE.OCX's pair: 18 ExpandNoChildren, then, once its children
/// came, 25 on the same key (a recorded session gui[61]
/// / gui[63], SapSessionTree.doubleClickTreeNode); the row opens at once
/// and ends selected. (the reference client's live 25 ALONE on SEGW's collapsed
/// project node abended the Tree Model: complaint-segw+20261002-121852
/// F1 — never without the 18 first.)
/// * the view's first row is the tree's `TopNodeKey` ([onTopNode], after
/// a scroll): the next event flushes it (gui[61]).
///
/// A double tap is ONE gesture, as SAP GUI's double-click is: its taps do
/// not also act as two clicks (the live SE80 tree, 2026-10-12, folded the
/// folder its first tap had opened and fired a leaf twice). That rule is
/// for the nodes whose double tap is the double-click; a LINK item's tap
/// is its own event (LINKCLICK 35, fired by the real GUI on the click
/// itself), so a simple tree's link leaf fires on the tap at once, with no
/// double-tap wait and no node double-click — the column tree's link cell
/// model ([onItemClick]).
///
/// A screen reader gets each row as a button: its label, selected and
/// expanded state, the click as the tap action and the double-click as a
/// custom action ('Open') — VoiceOver / TalkBack have no double tap of
/// their own; the expander is named 'Expand' / 'Collapse'.
///
/// A simple tree scrolls sideways as a whole when its rows' chrome (the
/// indent, the expander, the icon and a label's room) outgrows the pane —
/// SAP GUI's tree control scrolls the hierarchy sideways too — and a long
/// label at natural row height wraps to two lines (the real GUI shows it
/// on one and scrolls; a phone has no room for that).
///
/// A COLUMN tree ([columns] with item columns: SAP.TableTreeControl.1, the
/// ALV tree — /AIF/IFMON's interface overview) is drawn as SAP GUI draws
/// it: a fixed header row (the hierarchy column's heading, then each item
/// column's, in the HeaderNames display order, its quick info as the
/// tooltip), the hierarchy column (the rows above: expander, node icon,
/// text) at its declared width, then the item columns at theirs (the
/// declared characters x [charWidth]), each cell its item's icon (`@xx@`
/// through the SAP icon font) and text, the columns ruled apart. The
/// hierarchy area and the item area scroll sideways each on their own
/// (each with its scroll bar, like the real GUI's two), the rows scroll
/// up and down together. A tap on a LINK or BUTTON item is its click
/// ([onItemClick]: the session's LINKCLICK 35 / BUTTONCLICK 29), on a
/// text item it selects the row; a double tap on a cell is the item
/// double-click ([onItemActivate], ITEMDBLCLICK 22 with its column).
class SapTreeView extends StatefulWidget {
  const SapTreeView({
    super.key,
    required this.tree,
    required this.busy,
    required this.onRunTcode,
    required this.onExpand,
    this.dragShell,
    this.onActivate,
    this.handlesDoubleClick = true,
    this.onSelect,
    this.onToggle,
    this.onContextMenu,
    this.onTopNode,
    this.columns,
    this.headerStrip,
    this.listItems = false,
    this.charWidth,
    this.paneCols,
    this.paneRows,
    this.icons,
    this.onItemClick,
    this.onItemActivate,
    this.expandedKeys,
    this.columnWidths,
  });

  /// The column widths the user dragged on this column tree, in characters
  /// ([charWidth] points each): the hierarchy area under
  /// [SapTreeColumns.hierarchyItem], an item column under its name. A
  /// mutable map the caller keeps for the session (per tree shell), so a
  /// width outlives the view; null: the view keeps its own. Client-only:
  /// the real GUI's column resize sends nothing (a recorded session
  /// step 8, see [ColumnEdgeGrip]).
  final Map<String, double>? columnWidths;

  /// The folders the session holds OPEN (SapSessionTree.treeExpandedKeys):
  /// the server's own expansion — its `ABAPExpandNodes` verbs, its
  /// `ExpandedKeys` pushes — and the user's opens and closes ([onToggle]).
  /// A folder is drawn open only when it is in here or the user opened it
  /// in this view, like the real GUI's tree control: the DBA cockpit's
  /// navigation tree opens "Statut actuel" alone, its EXPANDER folders
  /// (Performance, Configuration, …) closed until their 18 brings the
  /// children (a recorded session srv[21]). Null: none open.
  /// A key that joins the set later (the server expands a folder, a
  /// restore re-opens the user's) opens; one that leaves it closes.
  final Set<String>? expandedKeys;

  /// A column tree's layout ([SapTreeColumns]); null or without item
  /// columns = a simple tree, drawn as a list.
  final SapTreeColumns? columns;

  /// The heading of the header strip over a tree with no item column
  /// (SapSessionTree.treeHeaderStrip: `WithHeader(1)` on a CL_GUI_COLUMN_
  /// TREE of the hierarchy alone — GFW_DEMO_HIER3's trees, a blank grey
  /// strip in the real GUI, no column headings); null = none.
  final String? headerStrip;

  /// A LIST tree (SapSessionTree.treeIsListTree: `ListDisplay(1)`,
  /// CL_GUI_LIST_TREE): a node shows its items side by side
  /// ([SapTreeNode.listText]) and its own icon — SMARTFORMS' Form Builder
  /// tree, `%PAGE1 Nouvelle page`, `MAIN Fenêtre principale`.
  final bool listItems;

  /// Points per declared character of a column width: the composer's cell
  /// width. Null: the pane's width over [paneCols] when given, else 7 (the
  /// dynpro renderer's cell).
  final double? charWidth;

  /// The pane's width in window cells (the composed region's columns): the
  /// character width is the pane's width over it.
  final int? paneCols;

  /// The pane's height in window rows (the composed region's rows): a
  /// simple tree too tall for a short pane draws a row per window row
  /// ([denseRowExtent]). Null: natural rows.
  final int? paneRows;

  /// The SAP icon font's codemap (the items' and nodes' `@xx@` icons).
  final SapIconAtlas? icons;

  /// A tap on a link or button item of a column tree: (node key, item
  /// name) — the item's click event.
  final void Function(String nodeKey, String itemName)? onItemClick;

  /// A double tap on a column tree's cell: (node key, item name) — the
  /// item double-click. Null: [onActivate] with the node key.
  final void Function(String nodeKey, String itemName)? onItemActivate;

  /// The width of a folder's expander hit area: a finger's, not the
  /// arrow's 20 px.
  static const double expanderHitWidth = 36;

  /// The least width a simple tree's row of [depth] is laid out at: its
  /// indent, the expander and 140 points for the node's icon, paddings
  /// and a label's room (about 90 points of text).
  static double rowMinWidth(int depth) => 20.0 * depth + expanderHitWidth + 140;

  /// The points a column tree row of [depth] needs for its chrome beyond
  /// what the OCX's own takes inside the declared hierarchy width: GuiGo's
  /// indent (20 pt a level), expander ([expanderHitWidth]), node icon and
  /// paddings, less the SAP GUI's (about 2 characters a level, the root's
  /// expander included, and 2 for the node icon, at [cw] points per
  /// character). Never negative.
  static double hierarchyChromeExtra(int depth, double cw) {
    final ours =
        20.0 * depth + 4 + expanderHitWidth + 12 + 20 + 10 + 8;
    final sap = ((depth + 1) * 2 + 2) * cw;
    return ours > sap ? ours - sap : 0;
  }


  final SapTreeModel tree;
  final bool busy;
  final Future<void> Function(String tcode) onRunTcode;

  /// Fire the tree's expand event for a folder the server still holds the
  /// children of; the node key is the server's own NODE_KEY string.
  final Future<void> Function(String nodeKey) onExpand;

  /// The tree control's shell when its rows can be dragged onto a canvas
  /// (long-press a row: a [TreeRowDrag] the canvas accepts); null = rows
  /// are not draggable.
  final String? dragShell;

  /// SAP GUI's double-click on a node — the tree's node / item double-click
  /// event, which the server handles (an Easy Access entry starts its
  /// transaction, an SE80 object opens, the DBA cockpit's "Threads"
  /// shows). Null = only tcode leaves act, through [onRunTcode].
  final Future<void> Function(String nodeKey)? onActivate;

  /// Whether the tree registered a double-click event ([onActivate] then
  /// sends it); false = the double-click is the front end's own (a folder
  /// toggles, a leaf is clicked).
  final bool handlesDoubleClick;

  /// A node became the tree's selection (a tap on its icon or text).
  final void Function(String nodeKey)? onSelect;

  /// A folder was opened ([open]) or closed on the client.
  final void Function(String nodeKey, bool open)? onToggle;

  /// The control's context menu on a row (a secondary click; a long press
  /// on a tree that does not drag): the server's menu for that node.
  final void Function(String nodeKey, Offset at)? onContextMenu;

  /// The first row the view shows changed (the user scrolled): its node
  /// key — the tree control's `TopNodeKey` (SapSessionTree.noteTreeTopNode).
  final void Function(String nodeKey)? onTopNode;

  /// The row extent of a DENSE simple tree, or null for the natural rows
  /// (32-point rows under an 8-point top padding): a pane of
  /// [paneRows] window rows [paneHeight] points tall that cannot show
  /// [rows] natural rows (and a [headerStrip]) and holds fewer than three
  /// draws one row per window row, as SAP GUI's tree does. PA20's object
  /// manager "Recherche de" (a recorded session srv[184]: `Personne`
  /// and its three search links in a 5-row pane under the toolbar): the
  /// header strip and the first natural row filled the pane — `Personne`
  /// open, its children below the pane's edge. Never under 12 points.
  static double? denseRowExtent({
    required double paneHeight,
    required int? paneRows,
    required int rows,
    required bool headerStrip,
  }) {
    if (paneRows == null || paneRows <= 0 || !paneHeight.isFinite) return null;
    final head = headerStrip ? _SapTreeViewState.headerHeight : 0.0;
    const natural = _SapTreeViewState.naturalRowHeight;
    const pad = _SapTreeViewState._padTop;
    if (head + pad + rows * natural <= paneHeight) return null;
    if (head + pad + 3 * natural <= paneHeight) return null;
    return (paneHeight / paneRows).clamp(12.0, natural);
  }

  @override
  State<SapTreeView> createState() => _SapTreeViewState();
}

/// How many times a tree view flattened its open tree (tests read it).
@visibleForTesting
int sapTreeFlattens = 0;

/// The transaction code of an Easy Access entry text: the leading
/// technical name before " - " (shown when "display technical names" is
/// on). Null for folders' plain texts and entries without one.
String? tcodeOfText(String text) => _tcodeRx.firstMatch(text)?.group(1);

final _tcodeRx = RegExp(r'^([A-Z0-9_/]{2,30}) - ');

class _SapTreeViewState extends State<SapTreeView> {
  final Set<String> _open = {};

  /// The session's expanded keys (trimmed) already applied to [_open]
  /// ([_syncExpanded]); a key whose node the tree does not hold yet waits.
  Set<String> _serverSeen = const {};
  SapTreeModel? _syncTree;
  int _syncNodes = -1;
  int _syncRev = -1;
  Set<String> _syncWant = const {};

  /// Bumped whenever [_open] changes: the flattened rows ([_rowsOf]) are
  /// walked again only for another tree or another set of open folders —
  /// a selection tap rebuilt the view and walked the whole open tree.
  int _openGen = 0;
  SapTreeModel? _rowsTree;
  int _rowsGen = -1;
  int _rowsNodes = -1;
  int _rowsRev = -1;


  /// Busy now — the view's flag or the session's ([SessionBusy]) — for a
  /// gesture handler (no dependency).
  bool get _busyNow => widget.busy || SessionBusy.peek(context);

  /// The rows as last built (the scroll position's first row is read from
  /// them) and the first row last reported ([SapTreeView.onTopNode]).
  List<(SapTreeNode, int)> _rows = const [];
  String? _top;

  static const double _padTop = 8;

  /// A simple tree's natural row: the 32-point expander beside the node's
  /// 20-point icon and text in 6-point paddings.
  static const double naturalRowHeight = 32;

  /// The list's paddings as last built (a dense tree has none on top):
  /// [_reportTop] reads the rows' extent from them.
  double _padTopNow = _padTop;
  double _padBottomNow = 96;

  /// A column tree's row and header heights, and its scroll controllers:
  /// the two row lists (hierarchy area, item area) scroll up and down
  /// together, each area sideways on its own.
  static const double rowHeight = 32;
  static const double headerHeight = 28;
  final ScrollController _vHier = ScrollController();
  final ScrollController _vItems = ScrollController();
  final ScrollController _hHier = ScrollController();
  final ScrollController _hItems = ScrollController();

  /// A simple tree's sideways scroll (its rows wider than the pane).
  final ScrollController _hPlain = ScrollController();
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _vHier.addListener(() => _follow(_vHier, _vItems));
    _vItems.addListener(() => _follow(_vItems, _vHier));
  }

  @override
  void dispose() {
    _dropClick();
    _vHier.dispose();
    _vItems.dispose();
    _hHier.dispose();
    _hItems.dispose();
    _hPlain.dispose();
    super.dispose();
  }

  /// [other] row list to [lead]'s scroll offset.
  void _follow(ScrollController lead, ScrollController other) {
    if (_syncing || !lead.hasClients || !other.hasClients) return;
    final o = lead.offset;
    if ((other.offset - o).abs() < 0.5) return;
    _syncing = true;
    other.jumpTo(o.clamp(0.0, other.position.maxScrollExtent));
    _syncing = false;
  }

  /// The item columns the view draws (none for a simple tree).
  List<SapTreeColumn> get _itemColumns =>
      widget.columns?.visible ?? const <SapTreeColumn>[];

  /// The node the user last selected (tapped or double-tapped).
  String? _selected;

  /// The dragged column widths when the caller keeps none.
  final Map<String, double> _ownWidths = {};
  Map<String, double> get _widths => widget.columnWidths ?? _ownWidths;

  /// Which tree the expansion state belongs to: its roots (key and text).
  /// The same element can be handed another tree (the screen's tree
  /// replaced by another program's, a pane reused for another control):
  /// that one starts fresh, top-level folders open, like SAP GUI.
  static List<String> _rootsOf(SapTreeModel t) => [
    for (final r in t.roots) '${r.key}\u0000${r.text}',
  ];

  @override
  void didUpdateWidget(SapTreeView old) {
    super.didUpdateWidget(old);
    if (identical(old.tree, widget.tree)) return;
    final was = _rootsOf(old.tree), now = _rootsOf(widget.tree);
    var same = was.length == now.length;
    for (var i = 0; same && i < was.length; i++) {
      same = was[i] == now[i];
    }
    if (!same) {
      _open.clear();
      _openGen++;
      _serverSeen = const {};
      _selected = null;
      _dropClick(); // a click on the old tree's row
      return;
    }
    // the same tree re-pushed (children arrived, a refresh): keep what is
    // open, forget nodes that are gone
    final nodes = widget.tree.nodes;
    _open.removeWhere((k) => !nodes.containsKey(k));
    _openGen++;
    if (_selected != null && !nodes.containsKey(_selected)) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final tree = widget.tree;
    _syncExpanded(tree);
    final rows = _rows = _rowsOf(tree);
    final cols = widget.columns;
    if (cols != null && _itemColumns.isNotEmpty) {
      return _columnTree(context, rows, cols);
    }
    final strip = widget.headerStrip;
    return LayoutBuilder(
      builder: (context, cons) => _plainTree(
        context,
        rows,
        strip,
        widget.paneRows == null
            ? null
            : SapTreeView.denseRowExtent(
                paneHeight: cons.maxHeight,
                paneRows: widget.paneRows,
                rows: rows.length,
                headerStrip: strip != null,
              ),
        cons,
      ),
    );
  }

  /// A simple tree's list (under its header strip), its rows [dense]
  /// points tall when given ([denseRowExtent]), laid out at least as wide
  /// as its deepest row's chrome ([SapTreeView.rowMinWidth]) and scrolled
  /// sideways when that outgrows the pane (a docked SE80 object list, a
  /// DBA cockpit tree on a phone: the real GUI's tree scrolls sideways
  /// there, and clipped rows hid their labels for good). Always wrapped —
  /// a wrap that came and went with an expand re-parented the list and
  /// lost its scroll offset; at the pane's width it scrolls nothing.
  Widget _plainTree(
    BuildContext context,
    List<(SapTreeNode, int)> rows,
    String? strip,
    double? dense,
    BoxConstraints cons,
  ) {
    _padTopNow = dense == null ? _padTop : 0;
    _padBottomNow = dense ?? 96;
    final list = ListView.builder(
      padding: EdgeInsets.fromLTRB(8, _padTopNow, 8, _padBottomNow),
      itemCount: rows.length,
      itemExtent: dense,
      itemBuilder: (context, i) => _busyLeaf(
        (context, busy) =>
            _row(context, rows[i].$1, rows[i].$2, busy: busy, extent: dense),
      ),
    );
    final Widget listed = widget.onTopNode == null
        ? list
        : NotificationListener<ScrollEndNotification>(
            onNotification: (n) {
              _reportTop(n.metrics);
              return false;
            },
            child: list,
          );
    Widget body = listed;
    if (cons.hasBoundedWidth) {
      var depth = 0;
      for (final (_, d) in rows) {
        if (d > depth) depth = d;
      }
      // the list's 8-point paddings either side
      final width = 16 + SapTreeView.rowMinWidth(depth);
      // outside the scroll-end listener: a sideways scroll's end never
      // reports a top node
      body = Scrollbar(
        controller: _hPlain,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _hPlain,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width > cons.maxWidth ? width : cons.maxWidth,
            child: listed,
          ),
        ),
      );
    }
    if (strip == null) return body;
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelMedium;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const ValueKey('tree-header-strip'),
          height: dense ?? headerHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Text(
            strip,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: dense == null
                ? labelStyle
                : labelStyle?.copyWith(
                    fontSize: (dense * 0.7).clamp(8.0, 12.0),
                    height: 1,
                  ),
          ),
        ),
        Expanded(child: body),
      ],
    );
  }

  /// Apply the session's expansion ([SapTreeView.expandedKeys]) to the
  /// open folders: a key new to it opens, a key gone from it closes —
  /// nothing else (no folder opens by default: an EXPANDER folder the
  /// server left closed is drawn closed, its chevron right). Keys are
  /// matched trimmed (the server's verb names `100`, the tree holds
  /// ` 100`).
  void _syncExpanded(SapTreeModel tree) {
    final want = widget.expandedKeys;
    if ((want == null || want.isEmpty) && _serverSeen.isEmpty) return;
    final now = {for (final k in want ?? const <String>{}) k.trim()};
    if (now.length == _serverSeen.length && now.containsAll(_serverSeen)) {
      return;
    }
    // a key the tree does not hold keeps the sets apart: walk the nodes
    // again only for another tree, more nodes or another set
    if (identical(tree, _syncTree) &&
        tree.nodes.length == _syncNodes &&
        tree.revision == _syncRev &&
        now.length == _syncWant.length &&
        now.containsAll(_syncWant)) {
      return;
    }
    _syncTree = tree;
    _syncNodes = tree.nodes.length;
    _syncRev = tree.revision;
    _syncWant = now;
    final own = <String, String>{
      for (final k in tree.nodes.keys) k.trim(): k,
    };
    final seen = <String>{};
    var changed = false;
    for (final k in now) {
      final key = own[k];
      if (key == null) continue; // not pushed yet: applied when it is
      seen.add(k);
      if (!_serverSeen.contains(k)) changed |= _open.add(key);
    }
    for (final k in _serverSeen) {
      if (now.contains(k)) continue;
      changed |= _open.remove(own[k] ?? k);
    }
    _serverSeen = seen;
    if (changed) _openGen++;
  }

  /// The rows the open tree shows (node, depth), walked once per tree and
  /// set of open folders; the node count guards a model grown in place.
  List<(SapTreeNode, int)> _rowsOf(SapTreeModel tree) {
    // a push applied into the SAME model (SapTreeModel.revision) relabels,
    // hides or moves nodes without changing their count
    if (identical(tree, _rowsTree) &&
        _rowsGen == _openGen &&
        _rowsNodes == tree.nodes.length &&
        _rowsRev == tree.revision) {
      return _rows;
    }
    sapTreeFlattens++;
    final rows = <(SapTreeNode, int)>[];
    void walk(SapTreeNode n, int depth) {
      if (n.hidden) return;
      rows.add((n, depth));
      if (_open.contains(n.key)) {
        for (final c in n.children) {
          walk(c, depth + 1);
        }
      }
    }

    for (final r in tree.roots) {
      walk(r, 0);
    }
    _rowsTree = tree;
    _rowsGen = _openGen;
    _rowsNodes = tree.nodes.length;
    _rowsRev = tree.revision;
    return rows;
  }

  /// A row drawn from the busy state: it alone rebuilds when the session's
  /// busy flips ([BusyBuilder]), not the tree.
  Widget _busyLeaf(Widget Function(BuildContext context, bool busy) build) =>
      BusyBuilder(busy: widget.busy, builder: build);

  // -------------------------------------------------------------------------
  // taps: a click shows at once, a double tap is ONE double-click
  // -------------------------------------------------------------------------

  /// A click waiting out the double-tap timeout before it is reported (its
  /// row is drawn selected at once — InkWell's double-tap arena held the
  /// whole tap ~300 ms), and the selection it replaced.
  Timer? _clickTimer;
  VoidCallback? _clickReport;
  String? _beforeClick;

  /// Report the waiting click now (another row's tap, the timeout).
  void _flushClick() {
    final report = _clickReport;
    _dropClick();
    report?.call();
  }

  void _dropClick() {
    _clickTimer?.cancel();
    _clickTimer = null;
    _clickReport = null;
  }

  /// [child] answering taps the way SAP GUI does, without the double-tap
  /// wait (the [SerialTapGestureRecognizer] of SapListLineView): the first
  /// tap draws [n] selected now and is reported as [click] once no second
  /// tap follows within the double-tap timeout; a second tap in time drops
  /// it — undrawn — for [doubleClick] alone. A double tap is still ONE
  /// gesture: its taps never also act as two clicks.
  Widget _taps({
    Key? key,
    required SapTreeNode n,
    required VoidCallback click,
    required VoidCallback doubleClick,
    required Widget child,
  }) => RawGestureDetector(
    key: key,
    behavior: HitTestBehavior.opaque,
    gestures: {
      SerialTapGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<SerialTapGestureRecognizer>(
            SerialTapGestureRecognizer.new,
            (r) => r
              // a second tap down in time: the click waits for its up
              ..onSerialTapDown = (d) {
                if (d.count.isEven) {
                  _clickTimer?.cancel();
                  _clickTimer = null;
                }
              }
              ..onSerialTapCancel = (_) {
                _flushClick();
              }
              ..onSerialTapUp = (d) {
                _tapUp(n, d.count, click, doubleClick);
              },
          ),
    },
    child: child,
  );

  void _tapUp(
    SapTreeNode n,
    int count,
    VoidCallback click,
    VoidCallback doubleClick,
  ) {
    if (count.isEven) {
      final waiting = _clickReport != null;
      _dropClick();
      // the first tap's selection undone: the double-click decides it
      if (waiting) setState(() => _selected = _beforeClick);
      doubleClick();
      return;
    }
    _flushClick();
    if (_busyNow) return; // a click while busy selects nothing (_select)
    _beforeClick = _selected;
    setState(() => _selected = n.key);
    _clickReport = () {
      if (!mounted) return;
      setState(() => _selected = _beforeClick);
      click();
    };
    _clickTimer = Timer(kDoubleTapTimeout, _flushClick);
  }

  /// Report the node of the first row the scrolled view shows (the rows'
  /// uniform extent read from the scroll metrics) when it changed.
  void _reportTop(ScrollMetrics m) {
    final cb = widget.onTopNode;
    final rows = _rows;
    if (cb == null || rows.isEmpty || m.axis != Axis.vertical) return;
    final content =
        m.maxScrollExtent + m.viewportDimension - _padTopNow - _padBottomNow;
    if (content <= 0) return;
    final extent = content / rows.length;
    final i = ((m.pixels - _padTopNow) / extent).floor().clamp(
      0,
      rows.length - 1,
    );
    final key = rows[i].$1.key;
    if (key == _top) return;
    _top = key;
    cb(key);
  }

  // -------------------------------------------------------------------------
  // column tree
  // -------------------------------------------------------------------------

  /// A column tree: the header row over the rows, the hierarchy area and
  /// the item area side by side.
  Widget _columnTree(
    BuildContext context,
    List<(SapTreeNode, int)> rows,
    SapTreeColumns cols,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final items = _itemColumns;
    return LayoutBuilder(
      builder: (context, cons) {
        final paneW = cons.maxWidth.isFinite ? cons.maxWidth : 1024.0;
        final cw =
            widget.charWidth ??
            (widget.paneCols != null && widget.paneCols! > 0
                ? paneW / widget.paneCols!
                : 7.0);
        // the declared width is the column the OCX draws its tree lines,
        // expanders, icons AND the text in; GuiGo's rows carry wider,
        // finger-sized chrome, which the column gets on top so the deepest
        // visible row keeps the text room the declared width gives it (the
        // error management tree: 30 characters, its message leaves three
        // levels down read "1: 17" — ABAPWidth(30, 0),
        // a recorded session srv call 198 v217)
        var depth = 0;
        for (final (_, d) in rows) {
          if (d > depth) depth = d;
        }
        // a column the user dragged keeps its dragged characters
        final store = _widths;
        const hierKey = SapTreeColumns.hierarchyItem;
        final hierW = store[hierKey] != null
            ? store[hierKey]! * cw
            : columnWidth(cols.hierarchy, cw, hierarchy: true) +
                  SapTreeView.hierarchyChromeExtra(depth, cw);
        final widths = [
          for (final c in items)
            store[c.name] != null
                ? math.max(store[c.name]! * cw, _minColumn)
                : columnWidth(c, cw),
        ];
        final itemsW = widths.fold(0.0, (a, b) => a + b);
        // the hierarchy area: its column's own width — the server's
        // (CL_GUI_COLUMN_TREE's hierarchy header width) or the user's —
        // never squeezed below it while the pane holds it (SE80's object
        // tree cut its names at 60 % of the dock: "ZCL_Z_BC_ARCI"); only a
        // pane too narrow for it leaves the item area a strip of
        // [_itemStrip] to drag the boundary back from
        final hierArea = itemsW <= 0
            ? paneW
            : math.max(
                math.min(_minColumn, paneW),
                math.min(hierW, paneW - 1 - math.min(itemsW, _itemStrip)),
              );
        final rule = BorderSide(color: scheme.outlineVariant, width: 1);
        // a header edge's drag: the column's width in characters, from
        // the stored one (several steps may land before the rebuild)
        void resize(String key, double drawn, double dx) => setState(() {
          final now = store[key] ?? drawn / cw;
          store[key] = (now + dx / cw).clamp(_minColumn / cw, _maxChars);
        });
        Widget grip(String key, double drawn) => ColumnEdgeGrip(
          key: ValueKey('tree-edge-${_keyText(key)}'),
          color: Colors.transparent,
          onDrag: (dx) => resize(key, drawn, dx),
        );
        Widget header(Widget child, double w, {String tip = ''}) {
          final cell = Container(
            width: w,
            height: headerHeight,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              border: Border(right: rule, bottom: rule),
            ),
            child: child,
          );
          return tip.isEmpty ? cell : Tooltip(message: tip, child: cell);
        }

        final hierHeader = header(
          _headerFace(context, cols.hierarchy),
          hierW,
          tip: cols.hierarchy.tooltip,
        );
        // each item header's right edge drags its column (the last one's
        // grip kept inside the area, where it can be hit)
        final edges = <Widget>[];
        var at = 0.0;
        for (var i = 0; i < items.length; i++) {
          at += widths[i];
          edges.add(
            Positioned(
              left: math.min(
                at - ColumnEdgeGrip.width / 2,
                itemsW - ColumnEdgeGrip.width,
              ),
              top: 0,
              width: ColumnEdgeGrip.width,
              height: headerHeight,
              child: grip(items[i].name, widths[i]),
            ),
          );
        }
        final itemHeader = Stack(
          children: [
            Row(
              key: const ValueKey('tree-header-items'),
              children: [
                for (var i = 0; i < items.length; i++)
                  KeyedSubtree(
                    key: ValueKey('tree-header-${_keyText(items[i].name)}'),
                    child: header(
                      _headerFace(context, items[i]),
                      widths[i],
                      tip: items[i].tooltip,
                    ),
                  ),
              ],
            ),
            ...edges,
          ],
        );
        const pad = EdgeInsets.only(bottom: 24);
        final hierList = ListView.builder(
          key: const ValueKey('tree-hierarchy-rows'),
          controller: _vHier,
          padding: pad,
          itemExtent: rowHeight,
          itemCount: rows.length,
          itemBuilder: (context, i) => _busyLeaf(
            (context, busy) => _row(
              context,
              rows[i].$1,
              rows[i].$2,
              columnMode: true,
              busy: busy,
            ),
          ),
        );
        final itemList = ListView.builder(
          key: const ValueKey('tree-item-rows'),
          controller: _vItems,
          padding: pad,
          itemExtent: rowHeight,
          itemCount: rows.length,
          itemBuilder: (context, i) => _busyLeaf(
            (context, busy) =>
                _itemRow(context, rows[i].$1, items, widths, rule, busy),
          ),
        );
        Widget area({
          required ScrollController h,
          required double width,
          required Widget head,
          required Widget list,
          required Key key,
        }) => Scrollbar(
          controller: h,
          thumbVisibility: true,
          child: SingleChildScrollView(
            key: key,
            controller: h,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (cols.withHeader) head,
                  // the scroll bar's strip under the rows
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: list,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        final areas = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: hierArea,
              child: area(
                key: const ValueKey('tree-hierarchy-area'),
                h: _hHier,
                width: hierW,
                head: hierHeader,
                list: hierList,
              ),
            ),
            // the rule between the areas (the real GUI's splitter)
            if (itemsW > 0)
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: scheme.outline.withValues(alpha: 0.6),
              ),
            if (itemsW > 0)
              Expanded(
                child: area(
                  key: const ValueKey('tree-item-area'),
                  h: _hItems,
                  width: itemsW,
                  head: itemHeader,
                  list: itemList,
                ),
              ),
          ],
        );
        // the hierarchy column's right edge — the boundary between the
        // areas: its drag resizes the hierarchy column (in the header row;
        // a tree without headings has it the whole height)
        final body = itemsW <= 0
            ? areas
            : Stack(
                children: [
                  Positioned.fill(child: areas),
                  Positioned(
                    left: hierArea + 0.5 - ColumnEdgeGrip.width / 2,
                    top: 0,
                    width: ColumnEdgeGrip.width,
                    height: cols.withHeader ? headerHeight : null,
                    bottom: cols.withHeader ? null : 0,
                    child: grip(hierKey, hierW),
                  ),
                ],
              );
        if (widget.onTopNode == null) return body;
        return NotificationListener<ScrollEndNotification>(
          onNotification: (n) {
            final m = n.metrics;
            if (m.axis == Axis.vertical && _rows.isNotEmpty) {
              final i = (m.pixels / rowHeight).floor().clamp(
                0,
                _rows.length - 1,
              );
              final key = _rows[i].$1.key;
              if (key != _top) {
                _top = key;
                widget.onTopNode!(key);
              }
            }
            return false;
          },
          child: body,
        );
      },
    );
  }

  /// The least a column is drawn at, in points (a finger's), the most a
  /// dragged one gets in characters, and the strip of the item area a pane
  /// too narrow for the hierarchy column still shows.
  static const double _minColumn = 28;
  static const double _maxChars = 255;
  static const double _itemStrip = 24;

  /// A column's drawn width: its declared characters x [cw] (the
  /// hierarchy column 30 characters when it declares none, an item column
  /// 10), never under a finger's 28 points.
  static double columnWidth(
    SapTreeColumn c,
    double cw, {
    bool hierarchy = false,
  }) {
    final chars = (c.width ?? 0) > 0 ? c.width! : (hierarchy ? 30 : 10);
    final w = chars * cw;
    return w < 28 ? 28 : w;
  }

  /// A header's face: its icon and heading, cut at the column's edge.
  Widget _headerFace(BuildContext context, SapTreeColumn c) {
    final icon = _iconGlyph(c.image, 16, null);
    final text = Text(
      c.heading,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      style: Theme.of(
        context,
      ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    if (icon == null) return text;
    return Row(
      children: [
        icon,
        const SizedBox(width: 4),
        Flexible(child: text),
      ],
    );
  }

  /// The SAP icon font glyph of an `@xx@` code, null when it names none
  /// the font holds.
  Widget? _iconGlyph(String image, double size, Color? color) {
    final code = iconCodeOf(image);
    if (code == null) return null;
    final cp = widget.icons?.codepoint(code);
    if (cp == null) return null;
    return Text(
      String.fromCharCode(cp),
      key: ValueKey('tree-icon-$code'),
      // a private-use character: nothing for a screen reader to say
      semanticsLabel: '',
      style: TextStyle(
        fontFamily: 'SapIcons',
        fontSize: size,
        height: 1,
        color: color,
      ),
    );
  }

  /// The item cells of node [n]'s row.
  Widget _itemRow(
    BuildContext context,
    SapTreeNode n,
    List<SapTreeColumn> items,
    List<double> widths,
    BorderSide rule,
    bool busy,
  ) {
    // a selected node is painted in the hierarchy column alone — its
    // icon and text, as the real GUI's column tree paints it ([_row]): the
    // item cells beside it stay unpainted
    return Row(
      key: ValueKey('tree-item-row-${_keyText(n.key)}'),
      children: [
        for (var i = 0; i < items.length; i++)
          _itemCell(context, n, items[i], widths[i], rule, busy),
      ],
    );
  }

  Widget _itemCell(
    BuildContext context,
    SapTreeNode n,
    SapTreeColumn col,
    double width,
    BorderSide rule,
    bool busy,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final cell = n.cells[col.name] ?? _cellByTrimmed(n, col.name);
    final key = ValueKey(
      'tree-cell-${_keyText(n.key)}-${_keyText(col.name)}',
    );
    final box = BoxDecoration(border: Border(right: rule));
    if (cell == null || cell.hidden) {
      return Container(key: key, width: width, decoration: box);
    }
    final enabled = !busy && !cell.disabled && !n.disabled;
    final link = cell.isLink, button = cell.isButton;
    final fg = !enabled && (cell.disabled || n.disabled)
        ? scheme.outline
        : (link ? scheme.primary : null);
    final icon = _iconGlyph(cell.image, 16, fg);
    final text = cell.textIsQuickInfo ? '' : cell.text;
    final right = cell.alignment == 2 || col.itemAlignment == 2;
    Widget face = Row(
      mainAxisAlignment: right ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (cell.isCheckbox)
          Icon(
            cell.chosen ? Icons.check_box : Icons.check_box_outline_blank,
            size: 18,
            color: fg ?? scheme.onSurfaceVariant,
          ),
        if (cell.isCheckbox && (icon != null || text.isNotEmpty))
          const SizedBox(width: 4),
        ?icon,
        if (icon != null && text.isNotEmpty) const SizedBox(width: 4),
        if (text.isNotEmpty)
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: TextStyle(
                fontSize: 13,
                color: fg,
                decoration: link ? TextDecoration.underline : null,
                decorationColor: fg,
              ),
            ),
          ),
      ],
    );
    if (button) {
      face = DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: face,
        ),
      );
    }
    final tip = cell.quickInfo.isNotEmpty
        ? cell.quickInfo
        : (cell.textIsQuickInfo ? cell.text : '');
    Widget content = Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: right ? Alignment.centerRight : Alignment.centerLeft,
      decoration: box,
      child: face,
    );
    if (tip.isNotEmpty) content = Tooltip(message: tip, child: content);
    final click = widget.onItemClick;
    // a link / button item fires on the tap itself (no double-tap wait)
    if ((link || button) && click != null) {
      return InkWell(
        key: key,
        onTap: enabled
            ? () {
                setState(() => _selected = n.key);
                click(n.key, cell.name);
              }
            : null,
        child: content,
      );
    }
    if (n.disabled) return InkWell(key: key, child: content);
    return Semantics(
      onTap: () => _select(n),
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Open'): () =>
            _doubleClickItem(n, cell.name),
      },
      child: _taps(
        key: key,
        n: n,
        click: () => _select(n),
        doubleClick: () => _doubleClickItem(n, cell.name),
        child: content,
      ),
    );
  }

  /// The item a simple tree draws as node [n]'s label: its hierarchy
  /// item, else its item `1`, else the first item carrying its text.
  static SapTreeItem? _labelItem(SapTreeNode n) {
    final c = n.cells[SapTreeColumns.hierarchyItem] ?? n.cells['1'];
    if (c != null) return c;
    for (final c in n.cells.values) {
      if (c.text.isNotEmpty && c.text == n.text) return c;
    }
    return null;
  }

  /// A node key / item name as a widget key spells it: its blank padding
  /// cut, inner runs of blanks one (`tree-cell-1-C 20`).
  static String _keyText(String s) => s.trim().replaceAll(_blanks, ' ');
  static final RegExp _blanks = RegExp(r'\s+');

  static SapTreeItem? _cellByTrimmed(SapTreeNode n, String name) {
    final t = name.trim();
    for (final c in n.cells.values) {
      if (c.name.trim() == t) return c;
    }
    return null;
  }

  /// A double tap on [n]'s cell in column [item]: the item double-click,
  /// else the node's own ([_doubleClick]).
  void _doubleClickItem(SapTreeNode n, String item) {
    final cb = widget.onItemActivate;
    if (cb == null || _busyNow || !widget.handlesDoubleClick) {
      _doubleClick(n);
      return;
    }
    setState(() => _selected = n.key);
    cb(n.key, item);
  }

  /// A folder: its children are pushed, or the server holds them.
  static bool _isFolder(SapTreeNode n) => n.isFolder || n.children.isNotEmpty;

  /// A folder whose children were never pushed (EXPANDER): opening it is a
  /// server round.
  static bool _remoteOnly(SapTreeNode n) =>
      _isFolder(n) && n.children.isEmpty && n.expander;

  /// The expander: open or close folder [n]. Returns whether it started a
  /// server round (the children asked for).
  bool _toggle(SapTreeNode n) {
    final open = _open.contains(n.key);
    if (!open && _remoteOnly(n)) {
      if (_busyNow) return false;
      // open optimistically: the children extend the model when the
      // server answers, and the row is already marked open for them
      setState(() {
        _open.add(n.key);
        _openGen++;
      });
      widget.onExpand(n.key);
      return true;
    }
    setState(() {
      open ? _open.remove(n.key) : _open.add(n.key);
      _openGen++;
    });
    widget.onToggle?.call(n.key, !open);
    return false;
  }

  /// A tap on [n]'s icon or text: it becomes the selection.
  void _select(SapTreeNode n) {
    if (_busyNow) return;
    setState(() => _selected = n.key);
    widget.onSelect?.call(n.key);
  }

  /// A double tap on [n]'s icon or text — SAP GUI's double-click.
  void _doubleClick(SapTreeNode n) {
    if (_busyNow) return;
    final folder = _isFolder(n);
    final activate = widget.onActivate;
    if (activate != null && widget.handlesDoubleClick) {
      // a folder whose children never came opens at once (its children
      // extend it when the 18 is answered) and is activated after it —
      // both rounds the session's (doubleClickTreeNode)
      setState(() {
        if (folder && _remoteOnly(n)) {
          _open.add(n.key);
          _openGen++;
        }
        _selected = n.key;
      });
      activate(n.key);
      return;
    }
    if (folder) {
      // the front end's own double-click: the folder toggles (and is
      // clicked, unless the toggle went to the server)
      if (!_toggle(n)) _select(n);
      return;
    }
    final tcode = tcodeOfText(n.text);
    if (activate == null && tcode != null) {
      setState(() => _selected = n.key);
      widget.onRunTcode(tcode);
      return;
    }
    _select(n);
  }

  Widget _row(
    BuildContext context,
    SapTreeNode n,
    int depth, {
    bool columnMode = false,
    bool busy = false,
    double? extent,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final open = _open.contains(n.key);
    // a dense row ([SapTreeView.denseRowExtent]): its icons and text sized
    // to the window row it is drawn in
    final iconSize = extent == null ? 20.0 : (extent * 0.85).clamp(10.0, 20.0);
    final fontSize = extent == null ? null : (extent * 0.72).clamp(9.0, 14.0);
    final folder = _isFolder(n);
    final tcode = folder ? null : tcodeOfText(n.text);
    final selected = _selected == n.key;

    IconData icon;
    if (folder) {
      icon = open ? Icons.folder_open : Icons.folder;
    } else {
      icon = tcode != null
          ? Icons.play_circle_outline
          : Icons.description_outlined;
    }
    // a node's own icons as the server sends them (N_IMAGE / EXP_IMAGE),
    // the front end's folder / leaf when it sends none: /AIF/IFMON's
    // namespace folder `@U8@`, SMARTFORMS' windows `@89@`, the HR object
    // manager's `Personne` `@5W\QPersonne@` and its search links `@13@`
    // (a recorded session srv[184]), the Easy Access favorites `@6D@`
    final nodeImage = _iconGlyph(
      open && n.expandedImage.isNotEmpty ? n.expandedImage : n.image,
      iconSize,
      null,
    );
    // the hierarchy column's text: its `&Hierarchy` item's; a list
    // tree's items side by side; else the node's label
    final hier = n.cells[SapTreeColumns.hierarchyItem]?.text;
    final listed = !columnMode && widget.listItems ? n.listText : '';
    final label = columnMode && hier != null && hier.isNotEmpty
        ? hier
        : listed.isNotEmpty
        ? listed
        : (n.text.isEmpty ? n.key : n.text);
    // a simple tree's LINK leaf (its label item CLASS 5): drawn as the
    // real GUI's hyperlink, underlined, its tap the item's click (LINKCLICK
    // 35 when registered: PPOSE's `Recherche structurelle`, a recorded session
    // basic_data g23 `%_GC 126 35` PARAM1 `&Hierarchy`) — the object
    // manager's `Aide à la recherche groupée`, `Critère de recherche`,
    // `Recherche libre` under `Personne`, whose own link item (a folder)
    // is drawn plain
    final labelItem = columnMode || widget.listItems ? null : _labelItem(n);
    final link = labelItem != null && labelItem.isLink && !folder;
    final itemClick = widget.onItemClick;
    final linkColor = n.disabled || (labelItem?.disabled ?? false)
        ? null
        : (selected ? scheme.onSecondaryContainer : scheme.primary);

    final menu = widget.onContextMenu;
    // the expander: a folder's arrow in a finger-wide hit area of its own
    // (a disabled folder still opens: SapTree.doExpand has no enabled gate)
    final expander = SizedBox(
      width: SapTreeView.expanderHitWidth,
      height: extent ?? 32,
      child: folder
          ? InkWell(
              key: ValueKey('tree-expander-${n.key}'),
              customBorder: const CircleBorder(),
              onTap: () => _toggle(n),
              child: Icon(
                open ? Icons.expand_more : Icons.chevron_right,
                size: iconSize,
                color: scheme.onSurfaceVariant,
                semanticLabel: open ? 'Collapse' : 'Expand',
              ),
            )
          : null,
    );
    // the node: its icon and text — a tap selects, a double tap is the
    // double-click. In a column tree the selection is painted round the
    // icon and text alone, cut at the hierarchy column's edge (the real
    // GUI's selected node: never a band across the row into the item
    // columns); a simple tree's row keeps its full-width face
    final labelText = Text(
      label,
      key: link ? ValueKey('tree-link-${n.key}') : null,
      // a long label wraps to two lines at natural height (a dense row's
      // extent is fixed: one line, cut); a column tree's label is one line
      // cut at its column, as the OCX cuts it
      maxLines: extent == null && !columnMode ? 2 : 1,
      softWrap: !columnMode,
      overflow: columnMode ? TextOverflow.clip : TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: fontSize,
        height: extent == null ? null : 1.1,
        fontWeight: depth == 0 ? FontWeight.w600 : FontWeight.normal,
        color: n.disabled
            ? scheme.outline
            : link
            ? linkColor
            : (selected ? scheme.onSecondaryContainer : null),
        decoration: link ? TextDecoration.underline : null,
        decorationColor: link ? linkColor : null,
      ),
    );
    final faceBox = Ink(
      key: columnMode ? ValueKey('tree-face-${_keyText(n.key)}') : null,
      decoration: BoxDecoration(
        color: selected ? scheme.secondaryContainer : null,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 6,
          vertical: extent == null ? 6 : 0,
        ),
        child: Row(
          mainAxisSize: columnMode ? MainAxisSize.min : MainAxisSize.max,
          children: [
            nodeImage ??
                Icon(
                  icon,
                  size: iconSize,
                  color: folder
                      ? scheme.primary
                      : (tcode != null
                            ? scheme.tertiary
                            : scheme.onSurfaceVariant),
                ),
            SizedBox(width: extent == null ? 10 : 6),
            if (columnMode)
              Flexible(child: labelText)
            else
              Expanded(child: labelText),
          ],
        ),
      ),
    );
    // (the row's hit area stays the whole column: the tap detectors are
    // opaque, only the paint hugs the label)
    final face = columnMode
        ? Align(alignment: Alignment.centerLeft, child: faceBox)
        : faceBox;
    // the node: its icon and text — a tap selects, a double tap is the
    // double-click (serial taps: the click shows without the double-tap
    // wait). A LINK leaf's tap is its click at once, as a column tree's
    // link cell (_itemCell): SAP GUI fires LINK_CLICK on the click itself,
    // no double-tap wait, no node double-click (a second tap in time is
    // dropped by the busy gate while the round runs).
    final linkTap =
        link && itemClick != null && !labelItem.disabled && !n.disabled;
    // the reader's row: a button with the label (the Text and the icon
    // glyph under it excluded: not read twice), its states, the click as
    // its tap and the double-click as 'Open'
    Widget readable(
      Widget child, {
      VoidCallback? onTap,
      Map<CustomSemanticsAction, VoidCallback>? actions,
    }) => Semantics(
      button: true,
      label: label,
      selected: selected,
      expanded: folder ? open : null,
      enabled: !n.disabled,
      excludeSemantics: true,
      onTap: onTap,
      customSemanticsActions: actions,
      child: child,
    );
    final node = InkWell(
      onTap: linkTap
          ? () {
              if (_busyNow) return;
              setState(() => _selected = n.key);
              itemClick(n.key, labelItem.name);
            }
          : null,
      onSecondaryTapUp: menu == null || busy
          ? null
          : (d) => menu(n.key, d.globalPosition),
      onLongPress: menu == null || busy || widget.dragShell != null
          ? null
          : () {
              final box = context.findRenderObject() as RenderBox?;
              menu(n.key, box?.localToGlobal(Offset.zero) ?? Offset.zero);
            },
      borderRadius: BorderRadius.circular(6),
      child: n.disabled || linkTap
          ? readable(face)
          : readable(
              _taps(
                n: n,
                click: () => _select(n),
                doubleClick: () => _doubleClick(n),
                child: face,
              ),
              onTap: () => _select(n),
              actions: {
                const CustomSemanticsAction(label: 'Open'): () =>
                    _doubleClick(n),
              },
            ),
    );
    final content = Padding(
      padding: EdgeInsets.only(
        left: 20.0 * depth + (columnMode ? 4 : 0),
        right: 8,
      ),
      child: Row(
        children: [
          expander,
          Expanded(child: node),
        ],
      ),
    );
    // a COLUMN tree's row narrower than its chrome (the hierarchy column
    // at its declared width, a deep row: hierarchyChromeExtra gives the
    // deepest row the OCX's text room, no more) is clipped, as the OCX
    // clips it, instead of overflowing; a simple tree's rows are laid out
    // at the deepest row's width and scroll sideways (_plainTree)
    final Widget row = columnMode
        ? LayoutBuilder(
            builder: (context, cons) {
              final minWidth = SapTreeView.rowMinWidth(depth);
              if (cons.maxWidth >= minWidth) return content;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                child: SizedBox(width: minWidth, child: content),
              );
            },
          )
        : content;
    final shell = widget.dragShell;
    if (shell == null || n.disabled) return row;
    return LongPressDraggable<TreeRowDrag>(
      data: TreeRowDrag(shell: shell, nodeKey: n.key, label: label),
      // the canvas reads the drop point from the feedback's origin
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 8),
              Text(label),
            ],
          ),
        ),
      ),
      child: row,
    );
  }
}
