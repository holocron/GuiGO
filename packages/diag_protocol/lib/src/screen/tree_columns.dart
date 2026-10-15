/// A COLUMN tree's columns — SAP.TableTreeControl.1 (WDTTREE.OCX, the
/// Java bean's SapTree in column mode): the CL_COLUMN_TREE_MODEL /
/// CL_ALV_TREE_BASE / CL_SALV_TREE layout the server declares through the
/// tree's two automation collections, read off the flush calls:
///
/// * `Structures` — the ITEM columns: `InsertHierarchy('&Hierarchy')`
/// the hierarchy item, `AddEx2(<item name>)` a column, `ItemEx(<name>)`
/// an existing one, `RemoveEx(<name>)` drops it; on the column object
/// `Hidden(0|1)`, `Alignment(<n>)`, `ExpandOnDblClick`, `HasFocusRect`;
/// * `Headers` — the column HEADINGS: `HierarchyHeader` the hierarchy
/// column's, `ItemEx(<name>)` an item column's; on the header object
/// `Heading(<text>)`, `ToolTip(<text>)`, `Image(<@xx@>)`,
/// `Alignment(<n>)`, `ABAPWidth(<chars>, 0)` (its width in characters —
/// what a `WidthInChar` read answers, tree_header_names.dart);
/// * the `HeaderNames` table assigned to the tree (tree_header_names.dart):
/// the visible header keys in DISPLAY order.
///
/// Real SAP GUI for Windows wire, /AIF/IFMON's interface overview
/// (a recorded session, RAW numbering): the launch batch (srv[20..22],
/// step 32) creates the tree (`CreateControl(136, SAP.TableTreeControl.1)`,
/// its methods addressed through the call's result row), inserts
/// `&Hierarchy`, adds 32 columns `C 1` … `C 32`, removes 18
/// of them again and assigns HeaderNames `C 8, 9, 10, 20, 21, 22, 23, 25,
/// 26, 24, 29, 30, 31, 32` (the order the real GUI draws: Alerte | Notif. |
/// Statut | Tout | Avertis. | Erreurs | Err. tech. | Réussite | Annulé |
/// EnCrsTrait | …), the hierarchy header "Interfaces ; dernière mise à jour
/// le : …" 60 characters wide; after the BT_SELECTDT select the server
/// re-declares every header (srv[47], step 67), the tree now named by the
/// handle the client minted (`28`): widths 10 / 11 / 10 / 15 x 7 / 50 / 50 /
/// 6 / 30, the headings and tooltips anew.
library;

import '../cfw/flush_call.dart';

/// One column of a column tree: an item column (its [name] the ITEM_NAME
/// of the cells under it), or the hierarchy column ([SapTreeColumns
/// .hierarchy], the node texts).
class SapTreeColumn {
  SapTreeColumn(this.name);

  /// The ITEM_NAME / header key (`C 8`; `&Hierarchy` for the
  /// hierarchy column).
  final String name;

  /// The header's text, quick info and icon (`@xx@`, '' for none).
  String heading = '';
  String tooltip = '';
  String image = '';

  /// The header's `Alignment` (0 = the default, left) and the item
  /// column's own (`Structures` … `Alignment`), null when not declared.
  int headerAlignment = 0;
  int? itemAlignment;

  /// The declared width in characters (`ABAPWidth`), null when none.
  int? width;

  /// `Hidden(1)` on the column.
  bool hidden = false;

  @override
  String toString() =>
      'SapTreeColumn($name, "$heading", ${width ?? '-'} ch'
      '${hidden ? ', hidden' : ''})';
}

/// The column layout of one column tree.
class SapTreeColumns {
  /// The hierarchy column's ITEM_NAME (the jar's / the OCX's own).
  static const String hierarchyItem = '&Hierarchy';

  final SapTreeColumn hierarchy = SapTreeColumn(hierarchyItem);

  /// The item columns in declaration order.
  final Map<String, SapTreeColumn> byName = {};

  /// The header keys in display order (the HeaderNames table), null when
  /// none was assigned.
  List<String>? headerNames;

  /// `WithHeader(1)`: the tree shows its header row (true until the
  /// server says otherwise — a column tree's default).
  bool withHeader = true;

  /// Whether the server put `WithHeader` at all: a tree with no item
  /// column draws its (hierarchy) header strip only when told to.
  bool withHeaderDeclared = false;

  /// The hierarchy item's own ITEM_NAME — `InsertHierarchy(<name>)` /
  /// `LastHierarchyItemName(<name>)`: `&Hierarchy` for the ALV tree, `HD`
  /// for CL_GUI_COLUMN_TREE's trees of GFW_DEMO_HIER3
  /// (a recorded session srv[28] verbs 116 / 132). Its cells
  /// are the node texts, never an item column of their own (read as one
  /// the trees were drawn as two-column trees, "Gerr | Germany").
  String hierarchyName = hierarchyItem;

  /// Whether the server declared any item column.
  bool get isEmpty => byName.isEmpty;

  /// The item columns the tree shows, in display order: those of the
  /// HeaderNames table it was assigned (keys matched blank-insensitively),
  /// else every declared one; hidden ones left out.
  List<SapTreeColumn> get visible {
    final order = headerNames;
    if (order == null || order.isEmpty) {
      return [
        for (final c in byName.values)
          if (!c.hidden) c,
      ];
    }
    final out = <SapTreeColumn>[];
    for (final n in order) {
      final c = byName[n] ?? _byTrimmed(n);
      if (c != null && !c.hidden && !out.contains(c)) out.add(c);
    }
    return out;
  }

  SapTreeColumn? _byTrimmed(String name) {
    final t = name.trim();
    for (final c in byName.values) {
      if (c.name.trim() == t) return c;
    }
    return null;
  }

  /// Whether [name] names the hierarchy column (its item or its header).
  bool isHierarchy(String name) =>
      name == hierarchyItem ||
      name == 'HierarchyHeader' ||
      name.trim() == hierarchyName.trim();

  /// The column [name] (blank-insensitive), created when [create].
  SapTreeColumn? column(String name, {bool create = false}) {
    if (isHierarchy(name)) return hierarchy;
    final hit = byName[name] ?? _byTrimmed(name);
    if (hit != null || !create) return hit;
    return byName[name] = SapTreeColumn(name);
  }

  /// Forget every declaration (the tree created anew: the kernel reuses
  /// a destroyed control's shell id).
  void clear() {
    final h = SapTreeColumn(hierarchyItem);
    hierarchy
      ..heading = h.heading
      ..tooltip = h.tooltip
      ..image = h.image
      ..headerAlignment = h.headerAlignment
      ..itemAlignment = h.itemAlignment
      ..width = h.width
      ..hidden = h.hidden;
    byName.clear();
    headerNames = null;
    withHeader = true;
    withHeaderDeclared = false;
    hierarchyName = hierarchyItem;
  }

  void remove(String name) {
    final c = byName[name] ?? _byTrimmed(name);
    if (c != null) byName.remove(c.name);
  }

  @override
  String toString() =>
      'SapTreeColumns(hierarchy ${hierarchy.width ?? '-'} ch, '
      '${visible.length}/${byName.length} visible)';
}

/// What an object row of one flush call stands for.
enum _Kind { tree, structures, headers, structItem, headerItem }

class _Obj {
  const _Obj(this.kind, this.tree, [this.column]);
  final _Kind kind;
  final String tree;
  final SapTreeColumn? column;
}

/// Fold the column declarations of [call] into [columnsOf] — the layout
/// of the tree a token names (created on first use). [treeOf] resolves a
/// handle / shell token the call addresses a tree by (an on-object value)
/// to the tree's key, null when it is no tree; the call's own
/// `CreateControl` of a tree class names its shell directly. Returns the
/// keys of the trees the call declared columns of.
Set<String> foldTreeColumns(
  FlushCall call, {
  required SapTreeColumns Function(String tree) columnsOf,
  required String? Function(String token) treeOf,
}) {
  final touched = <String>{};
  if (!call.verbs.any(_columnVerbs.contains)) return touched;
  final meta = verbMeta(call);
  final rows = <String, _Obj>{};
  for (var i = 1; i <= call.verbs.length && i <= meta.length; i++) {
    final verb = call.verbs[i - 1];
    final m = meta[i - 1];
    final res = m.result?.trim() ?? '';
    if (verb.startsWith('CreateControl')) {
      final a = verbNamedArgs(call, i);
      final cls = (a['#2'] ?? '').trim();
      final sh = (a['#1'] ?? '').trim();
      if (res.isNotEmpty) {
        if (cls.contains('Tree') && sh.isNotEmpty) {
          rows[res] = _Obj(_Kind.tree, sh);
          // a tree created anew starts without columns
          columnsOf(sh).clear();
        } else {
          rows.remove(res);
        }
      }
      continue;
    }
    var owner = rows[m.obj.trim()];
    if (owner == null && (verb == 'Structures' || verb == 'Headers')) {
      final t = treeOf(m.objValue.trim());
      if (t != null) owner = _Obj(_Kind.tree, t);
    }
    if (owner == null) {
      // a result row the call reuses for another object
      if (res.isNotEmpty) rows.remove(res);
      continue;
    }
    final cols = columnsOf(owner.tree);
    switch (owner.kind) {
      case _Kind.tree:
        if (verb == 'Structures' && res.isNotEmpty) {
          rows[res] = _Obj(_Kind.structures, owner.tree);
        } else if (verb == 'Headers' && res.isNotEmpty) {
          rows[res] = _Obj(_Kind.headers, owner.tree);
        } else if (verb == 'WithHeader') {
          cols
            ..withHeader = _value(call, i) != '0'
            ..withHeaderDeclared = true;
        } else if (verb == 'LastHierarchyItemName') {
          final n = _value(call, i).trimRight();
          if (n.trim().isNotEmpty) _renameHierarchy(cols, n);
        } else if (res.isNotEmpty) {
          rows.remove(res);
        }
      case _Kind.structures:
        final name = (verbNamedArgs(call, i)['#1'] ?? '').trimRight();
        switch (verb) {
          case 'InsertHierarchy' || 'AddEx2' || 'ItemEx':
            if (name.trim().isEmpty) break;
            if (verb == 'InsertHierarchy') _renameHierarchy(cols, name);
            final c = cols.column(name, create: true)!;
            touched.add(owner.tree);
            if (res.isNotEmpty) {
              rows[res] = _Obj(_Kind.structItem, owner.tree, c);
            }
          case 'RemoveEx':
            if (name.trim().isNotEmpty) {
              cols.remove(name);
              touched.add(owner.tree);
            }
          default:
            if (res.isNotEmpty) rows.remove(res);
        }
      case _Kind.headers:
        String? name;
        if (verb == 'HierarchyHeader') {
          name = SapTreeColumns.hierarchyItem;
        } else if (verb == 'ItemEx') {
          name = (verbNamedArgs(call, i)['#1'] ?? '').trimRight();
        }
        if (name == null || name.trim().isEmpty) {
          if (res.isNotEmpty) rows.remove(res);
          break;
        }
        final c = cols.column(name, create: true)!;
        touched.add(owner.tree);
        if (res.isNotEmpty) rows[res] = _Obj(_Kind.headerItem, owner.tree, c);
      case _Kind.structItem:
        final c = owner.column!;
        switch (verb) {
          case 'Hidden':
            c.hidden = _value(call, i) == '1';
          case 'Alignment':
            c.itemAlignment = int.tryParse(_value(call, i));
        }
      case _Kind.headerItem:
        final c = owner.column!;
        switch (verb) {
          case 'Heading':
            c.heading = _value(call, i).trimRight();
          case 'ToolTip':
            c.tooltip = _value(call, i).trimRight();
          case 'Image':
            c.image = _value(call, i).trim();
          case 'Alignment':
            c.headerAlignment = int.tryParse(_value(call, i)) ?? 0;
          case 'ABAPWidth':
            final w = _width(call, i, meta[i - 1]);
            if (w != null) c.width = w;
        }
    }
  }
  return touched;
}

/// The hierarchy item is [name]: a column declared under it before is
/// the hierarchy's.
void _renameHierarchy(SapTreeColumns cols, String name) {
  final t = name.trim();
  final stray = cols.byName[name] ??
      cols.byName.values.where((c) => c.name.trim() == t).firstOrNull;
  cols.hierarchyName = name;
  if (stray != null) cols.byName.remove(stray.name);
}

const Set<String> _columnVerbs = {
  'Structures',
  'Headers',
  'InsertHierarchy',
  'AddEx2',
};

/// A property put's value: its first non-reserved argument.
String _value(FlushCall call, int i) {
  for (final (n, v) in verbArgs(call, i)) {
    if (n.trim().startsWith('_')) continue;
    return v;
  }
  return '';
}

/// `ABAPWidth(<chars>, 0)`: the first non-object argument (a later wave
/// may pass the tree handle first — declaredHeaderWidths).
int? _width(FlushCall call, int i, VerbMeta m) {
  for (final name in ['#1', '#2', '#3']) {
    final r = int.tryParse(m.slots[name] ?? '');
    if (r == null || r < 1 || r > call.vars.length) continue;
    final v = call.vars[r - 1];
    if (v.type == 'O') continue;
    return int.tryParse(v.valueText.trim());
  }
  return null;
}
