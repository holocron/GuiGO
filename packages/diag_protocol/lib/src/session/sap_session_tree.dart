part of 'sap_session.dart';

/// Tree control actions on a SPECIFIC tree shell — a screen can host
/// several trees (the DBA cockpit's navigation tree beside an Easy Access
/// tree that is still alive), so the newest-tree default of
/// [SapSession.expandTreeNode] is not enough.
extension SapSessionTree on SapSession {
  /// Activate [nodeKey] of tree [shell] — SAP GUI's double-click on a node
  /// (a leaf opens its function). A COLUMN tree that registered EVENTID 22
  /// ITEMDBLCLICK gets the item event with the node's first item name, as
  /// the real GUI sends it on the DBA cockpit's navigation tree
  /// (a recorded session gui[19]: `%_GC 147 22`, PARAM0
  /// " 206", PARAM1 "Task"); a simple tree gets 25 NODEDBLCLICK, or 21
  /// SELCHANGE when only that one is registered (reference client raw_tree
  /// `pick_tree_event`, TREE_ACTIVATE_EVENTS = (25, 21)).
  Future<List<Uint8List>> activateTreeNode(String shell, String nodeKey) {
    final reg = _canvasState.tracker.registeredEvents[shell] ?? const <int>{};
    String? item;
    int ev;
    if (reg.contains(22)) {
      ev = 22;
      final items = trees[shell]?.nodes[nodeKey]?.items.keys;
      item = (items == null || items.isEmpty) ? '1' : items.first;
    } else {
      ev = _pickTreeEvent(shell, const [treeEventNodeDoubleClick, 21]);
    }
    _ea.recordEvent(shell, {0: nodeKey, if (item != null) 1: item});
    return _act(
      treeEventItems(
        ctx,
        shell: shell,
        eventId: ev,
        nodeKey: nodeKey,
        itemName: item,
      ),
      controlEvent: true,
    );
  }

  /// Ask tree [shell] for the children of folder [nodeKey] (EVENTID 18
  /// EXPANDNOCHILDREN, or 19 EXPAND when only that one is registered).
  Future<List<Uint8List>> expandTreeNodeOf(String shell, String nodeKey) {
    final ev = _pickTreeEvent(shell, const [treeEventExpandNoChildren, 19]);
    _ea.recordEvent(shell, {0: nodeKey});
    (_expandedKeys[shell] ??= []).add(nodeKey);
    return _act(
      treeEventItems(ctx, shell: shell, eventId: ev, nodeKey: nodeKey),
      controlEvent: true,
    );
  }

  /// The first of [family] the tree registered (RegisterEvent verbs seen
  /// on the wire), else the family's first when nothing was recorded.
  int _pickTreeEvent(String shell, List<int> family) {
    final reg = _canvasState.tracker.registeredEvents[shell];
    if (reg == null || reg.isEmpty) return family.first;
    for (final e in family) {
      if (reg.contains(e)) return e;
    }
    return family.first;
  }
}
