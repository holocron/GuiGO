import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

import 'sap_graph_view.dart';

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
/// opened (18), not activated: no capture shows a 25 on one, and the
/// reference client's live 25 on SEGW's collapsed project node abended the Tree
/// Model (complaint-segw+20261002-121852 F1, reference client raw_tree).
///
/// A double tap is ONE gesture, as SAP GUI's double-click is: its taps do
/// not also act as two clicks (the live SE80 tree, 2026-10-12, folded the
/// folder its first tap had opened and fired a leaf twice).
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
  });

  /// The width of a folder's expander hit area: a finger's, not the
  /// arrow's 20 px.
  static const double expanderHitWidth = 36;

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

  @override
  State<SapTreeView> createState() => _SapTreeViewState();
}

/// The transaction code of an Easy Access entry text: the leading
/// technical name before " - " (shown when "display technical names" is
/// on). Null for folders' plain texts and entries without one.
String? tcodeOfText(String text) => _tcodeRx.firstMatch(text)?.group(1);

final _tcodeRx = RegExp(r'^([A-Z0-9_/]{2,30}) - ');

class _SapTreeViewState extends State<SapTreeView> {
  final Set<String> _open = {};
  bool _seeded = false;

  /// The node the user last selected (tapped or double-tapped).
  String? _selected;

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
      _seeded = false;
      _selected = null;
      return;
    }
    // the same tree re-pushed (children arrived, a refresh): keep what is
    // open, forget nodes that are gone
    final nodes = widget.tree.nodes;
    _open.removeWhere((k) => !nodes.containsKey(k));
    if (_selected != null && !nodes.containsKey(_selected)) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final tree = widget.tree;
    if (!_seeded && tree.roots.isNotEmpty) {
      // like SAP GUI: the top-level folders start open
      _open.addAll(tree.roots.map((n) => n.key));
      _seeded = true;
    }
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
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
      itemCount: rows.length,
      itemBuilder: (context, i) => _row(context, rows[i].$1, rows[i].$2),
    );
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
      if (widget.busy) return false;
      // open optimistically: the children extend the model when the
      // server answers, and the row is already marked open for them
      setState(() => _open.add(n.key));
      widget.onExpand(n.key);
      return true;
    }
    setState(() => open ? _open.remove(n.key) : _open.add(n.key));
    widget.onToggle?.call(n.key, !open);
    return false;
  }

  /// A tap on [n]'s icon or text: it becomes the selection.
  void _select(SapTreeNode n) {
    if (widget.busy) return;
    setState(() => _selected = n.key);
    widget.onSelect?.call(n.key);
  }

  /// A double tap on [n]'s icon or text — SAP GUI's double-click.
  void _doubleClick(SapTreeNode n) {
    if (widget.busy) return;
    final folder = _isFolder(n);
    final activate = widget.onActivate;
    if (activate != null && widget.handlesDoubleClick) {
      // a folder whose children never came is opened, not activated
      if (folder && _remoteOnly(n) && !_open.contains(n.key)) {
        _toggle(n);
        return;
      }
      setState(() => _selected = n.key);
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

  Widget _row(BuildContext context, SapTreeNode n, int depth) {
    final scheme = Theme.of(context).colorScheme;
    final open = _open.contains(n.key);
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
    final label = n.text.isEmpty ? n.key : n.text;

    final menu = widget.onContextMenu;
    // the expander: a folder's arrow in a finger-wide hit area of its own
    // (a disabled folder still opens: SapTree.doExpand has no enabled gate)
    final expander = SizedBox(
      width: SapTreeView.expanderHitWidth,
      height: 32,
      child: folder
          ? InkWell(
              key: ValueKey('tree-expander-${n.key}'),
              customBorder: const CircleBorder(),
              onTap: () => _toggle(n),
              child: Icon(
                open ? Icons.expand_more : Icons.chevron_right,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            )
          : null,
    );
    // the node: its icon and text — a tap selects, a double tap is the
    // double-click
    final node = InkWell(
      onTap: n.disabled ? null : () => _select(n),
      onDoubleTap: n.disabled ? null : () => _doubleClick(n),
      onSecondaryTapUp: menu == null || widget.busy
          ? null
          : (d) => menu(n.key, d.globalPosition),
      onLongPress: menu == null || widget.busy || widget.dragShell != null
          ? null
          : () {
              final box = context.findRenderObject() as RenderBox?;
              menu(n.key, box?.localToGlobal(Offset.zero) ?? Offset.zero);
            },
      borderRadius: BorderRadius.circular(6),
      child: Ink(
        decoration: BoxDecoration(
          color: selected ? scheme.secondaryContainer : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: folder
                    ? scheme.primary
                    : (tcode != null
                          ? scheme.tertiary
                          : scheme.onSurfaceVariant),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: depth == 0
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: n.disabled
                        ? scheme.outline
                        : (selected ? scheme.onSecondaryContainer : null),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // a pane narrower than a row's chrome (a docked pane on a small window)
    // clips the row instead of overflowing it
    final row = LayoutBuilder(
      builder: (context, cons) {
        final content = Padding(
          padding: EdgeInsets.only(left: 20.0 * depth, right: 8),
          child: Row(children: [expander, Expanded(child: node)]),
        );
        final minWidth = 20.0 * depth + SapTreeView.expanderHitWidth + 140;
        if (cons.maxWidth >= minWidth) return content;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: SizedBox(width: minWidth, child: content),
        );
      },
    );
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
