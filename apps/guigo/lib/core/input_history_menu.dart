import 'package:flutter/material.dart';

import 'input_history.dart';

/// SAP GUI's "Local Data > History" options for every connection: input
/// history On / Off (on by default) and "Clear History" (all systems).
///
/// Mounted as the local-options overflow of a screen's app bar (SAP GUI
/// keeps these under Customize Local Layout, not under the server's
/// System menu): a `more_vert` trigger by default — a clock icon beside
/// the systems list read as "recent connections", not as the typing
/// history inside SAP screens. A screen that already has an overflow
/// passes its own [icon] / [tooltip].
class InputHistoryMenu extends StatelessWidget {
  const InputHistoryMenu({
    super.key,
    required this.history,
    this.icon = const Icon(Icons.more_vert),
    this.tooltip = 'Options',
  });

  final InputHistoryStore history;
  final Widget icon;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: history,
      builder: (context, _) => PopupMenuButton<String>(
        tooltip: tooltip,
        icon: icon,
        onSelected: (v) async {
          if (v == 'toggle') {
            await history.setEnabled(!history.enabled);
          } else if (v == 'clear') {
            await history.clear();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Input history cleared')),
              );
            }
          }
        },
        itemBuilder: (context) => [
          CheckedPopupMenuItem(
            value: 'toggle',
            checked: history.enabled,
            child: const Text('Input history'),
          ),
          PopupMenuItem(
            value: 'clear',
            enabled: !history.isEmpty,
            child: const Text('Clear input history'),
          ),
        ],
      ),
    );
  }
}
