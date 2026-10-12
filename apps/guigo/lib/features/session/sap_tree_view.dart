import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

import 'sap_graph_view.dart';

/// A server tree control (the SAP Easy Access menu, …) as an indented,
/// expandable list. Folders whose children were pushed expand locally; a
/// folder whose children are still on the server (EXPANDER) asks the
/// server for them through [onExpand] and opens when they arrive. A
/// transaction entry ("SM04 - …", technical names on) runs its code.
class SapTreeView extends StatefulWidget {
  const SapTreeView({
    super.key,
    required this.tree,
    required this.busy,
    required this.onRunTcode,
    required this.onExpand,
    this.dragShell,
    this.onActivate,
    this.onContextMenu,
  });

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

  /// Activate a node the server handles itself (a leaf without a
  /// transaction code: the DBA cockpit's "Threads", …) — the tree's
  /// node / item double-click event. Null = only tcode leaves act.
  final Future<void> Function(String nodeKey)? onActivate;

  /// The control's context menu on a row (a secondary click; a long press
  /// on a tree that does not drag): the server's menu for that node.
  final void Function(String nodeKey, Offset at)? onContextMenu;

  @override
  State<SapTreeView> createState() => _SapTreeViewState();
}

/// The transaction code of an Easy Access entry text: the leading
/// technical name before " - " (shown when "display technical names" is
/// on). Null for folders' plain texts and entries without one.
String? tcodeOfText(String text) {
  final m = RegExp(r'^([A-Z0-9_/]{2,30}) - ').firstMatch(text);
  return m?.group(1);
}

class _SapTreeViewState extends State<SapTreeView> {
  final Set<String> _open = {};
  bool _seeded = false;

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

  Widget _row(BuildContext context, SapTreeNode n, int depth) {
    final scheme = Theme.of(context).colorScheme;
    final open = _open.contains(n.key);
    final folder = n.isFolder || n.children.isNotEmpty;
    final tcode = folder ? null : tcodeOfText(n.text);
    final remoteOnly = folder && n.children.isEmpty && n.expander;

    IconData icon;
    if (folder) {
      icon = open ? Icons.folder_open : Icons.folder;
    } else {
      icon = tcode != null
          ? Icons.play_circle_outline
          : Icons.description_outlined;
    }
    final label = n.text.isEmpty ? n.key : n.text;

    void onTap() {
      if (folder) {
        if (remoteOnly) {
          if (widget.busy) return;
          // open optimistically: the children extend the model when the
          // server answers, and the row is already marked open for them
          setState(() => _open.add(n.key));
          widget.onExpand(n.key);
          return;
        }
        setState(() => open ? _open.remove(n.key) : _open.add(n.key));
      } else if (tcode != null && !widget.busy) {
        widget.onRunTcode(tcode);
      } else if (widget.onActivate != null && !widget.busy) {
        widget.onActivate!(n.key);
      }
    }

    final menu = widget.onContextMenu;
    final row = InkWell(
      onTap: n.disabled ? null : onTap,
      onSecondaryTapUp: menu == null || widget.busy
          ? null
          : (d) => menu(n.key, d.globalPosition),
      onLongPress: menu == null || widget.busy || widget.dragShell != null
          ? null
          : () {
              final box = context.findRenderObject() as RenderBox?;
              menu(n.key, box?.localToGlobal(Offset.zero) ?? Offset.zero);
            },
      // a pane narrower than a row's chrome (a docked pane on a small
      // window) clips the row instead of overflowing it
      child: LayoutBuilder(
        builder: (context, cons) {
          final content = Padding(
            padding: EdgeInsets.only(
              left: 20.0 * depth,
              top: 6,
              bottom: 6,
              right: 8,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: folder
                      ? Icon(
                          open ? Icons.expand_more : Icons.chevron_right,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        )
                      : null,
                ),
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
                      color: n.disabled ? scheme.outline : null,
                    ),
                  ),
                ),
              ],
            ),
          );
          if (cons.maxWidth >= 180) return content;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: SizedBox(width: 180, child: content),
          );
        },
      ),
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
