import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

import 'sap_toolbar.dart' show vkeyName;

/// SAP GUI's MENU BAR (Menu / Edit / Goto / … / System / Help) behind one
/// compact button: the painted bar's menus (18/11/1, [bar]) cascade into
/// their dropdowns (18/11/2, [tree]) — submenus open beside, separators are
/// rules, entries the PF-status deactivated are greyed, an entry's function
/// key (its vkey's name, as SAP GUI prints it) trails its text. Picking an
/// entry calls [onSelect] (SapSession.selectMenu: the real GUI's position
/// click). Disabled while [busy] or without a bar (a popup paints none).
class SapMenuButton extends StatelessWidget {
  const SapMenuButton({
    super.key,
    required this.bar,
    required this.tree,
    required this.onSelect,
    this.busy = false,
  });

  final List<MenuEntry> bar;
  final List<MenuEntry> tree;
  final ValueChanged<MenuEntry> onSelect;
  final bool busy;

  /// The key text trailing an entry: its function key's name (`F8`,
  /// `Shift+F1`), else a multi-character accelerator the server sent; a
  /// one-letter accelerator is the entry's mnemonic, not a shortcut.
  static String? shortcutOf(MenuEntry e) {
    if (e.vkey != menuNoKey) {
      final k = vkeyName(e.vkey);
      if (k != null && e.vkey != 0) return k;
    }
    final a = e.accel.trim();
    return a.length > 1 ? a : null;
  }

  List<Widget> _entries(MenuChildIndex index, List<int> parent) {
    final out = <Widget>[];
    for (final e in index.children(parent)) {
      if (e.separator) {
        // no rule first, last, or doubled
        if (out.isNotEmpty && out.last is! Divider) {
          out.add(const Divider(height: 1));
        }
        continue;
      }
      if (e.submenu || index.hasEntries(e.path)) {
        final sub = _entries(index, e.path);
        out.add(
          SubmenuButton(
            menuChildren: sub,
            child: Text(e.text.isEmpty ? '…' : e.text),
          ),
        );
        continue;
      }
      final key = shortcutOf(e);
      out.add(
        MenuItemButton(
          onPressed: e.active ? () => onSelect(e) : null,
          trailingIcon: key == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Text(key),
                ),
          child: Text(e.text),
        ),
      );
    }
    while (out.isNotEmpty && out.last is Divider) {
      out.removeLast();
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !busy && bar.isNotEmpty;
    final index = MenuChildIndex.of(tree);
    return MenuAnchor(
      menuChildren: [
        for (final b in bar)
          SubmenuButton(
            menuChildren: _entries(index, b.path),
            child: Text(b.text),
          ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: 'Menu',
        icon: const Icon(Icons.menu),
        onPressed: enabled
            ? () => controller.isOpen ? controller.close() : controller.open()
            : null,
      ),
    );
  }
}

/// The dropdown [tree]'s entries grouped by parent path in ONE pass —
/// what [menuChildren] answers per call by a scan of the whole tree (a
/// cascade asking it per entry is O(n²)). Built once per tree list
/// ([of] memoizes by identity: the screen model's list is the same until
/// the server paints a new one).
class MenuChildIndex {
  MenuChildIndex(List<MenuEntry> tree) {
    for (final e in tree) {
      final p = e.position;
      int at(int i) => i < p.length ? p[i] : 0;
      // the entry's depth: its last non-zero position; it sits under the
      // positions before it (menuChildren: positions after it all zero)
      var d = 4;
      while (d > 0 && at(d - 1) == 0) {
        d--;
      }
      if (d < 2) continue; // a bar header (or nothing) is no one's child
      final key = _key([for (var i = 0; i < d - 1; i++) at(i)]);
      if (e.separator) {
        (_all[key] ??= []).add(e);
      } else if (e.text.isNotEmpty) {
        (_all[key] ??= []).add(e);
        _withEntries.add(key);
      }
    }
  }

  static final _memo = Expando<MenuChildIndex>('MenuChildIndex');

  /// The index of [tree], built on its first use.
  static MenuChildIndex of(List<MenuEntry> tree) =>
      _memo[tree] ??= MenuChildIndex(tree);

  final _all = <String, List<MenuEntry>>{};
  final _withEntries = <String>{};

  static String _key(List<int> path) => path.join('.');

  /// [menuChildren] (separators kept) of [parent], in paint order.
  List<MenuEntry> children(List<int> parent) =>
      parent.isEmpty || parent.length >= 4
      ? const []
      : _all[_key(parent)] ?? const [];

  /// Whether [parent] has an entry that is not a separator.
  bool hasEntries(List<int> parent) =>
      parent.isNotEmpty &&
      parent.length < 4 &&
      _withEntries.contains(_key(parent));
}
