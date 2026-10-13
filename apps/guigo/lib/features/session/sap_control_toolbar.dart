import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

import '../../core/sap_icons.dart';
import 'sap_toolbar.dart' show ScrollingButtonRow;

/// A CFW control toolbar — the OO-ALV grid's own button row (sort, filter,
/// totals, export, "Modifier mise en forme" …) or a SAP.Toolbar.1 control
/// (diag_protocol control_toolbar.dart): SAP GUI's compact icon buttons,
/// each with its quick info as the tooltip and its text beside the icon
/// when it has one; separators as thin rules; a menu button with a small
/// dropdown arrow — a split one (type 1) fires its function from the body
/// and opens the menu from the arrow, a menu-only one (type 2) opens it
/// from anywhere; a disabled button greyed, a checked one highlighted. The
/// row scrolls sideways when it does not fit.
class SapControlToolbarView extends StatelessWidget {
  const SapControlToolbarView({
    super.key,
    required this.buttons,
    required this.onPressed,
    required this.onDropdown,
    this.icons,
    this.busy = false,
  });

  final List<SapToolbarButton> buttons;
  final SapIconAtlas? icons;

  /// While the session is busy every button is inert.
  final bool busy;

  /// A button pressed (a plain or check button, a split button's body).
  final void Function(String fcode) onPressed;

  /// A menu button's menu asked for, at the global position under the
  /// button (where the menu opens).
  final void Function(String fcode, Offset at) onDropdown;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    final codes = <String>{};
    for (var i = 0; i < buttons.length; i++) {
      final b = buttons[i];
      if (b.separator) {
        // a leading, trailing or doubled separator draws nothing
        if (children.isEmpty || i == buttons.length - 1) continue;
        if (buttons[i + 1].separator) continue;
        children.add(const _ToolbarSeparator());
      } else {
        children.add(
          _ToolbarButton(
            // unique among the row: the code alone while it is (stable
            // across a re-push that inserts a button), index + code for
            // an empty or repeated code
            key: ValueKey(
              b.code.isNotEmpty && codes.add(b.code)
                  ? 'ctb-${b.code}'
                  : 'ctb-$i-${b.code}',
            ),
            button: b,
            icons: icons,
            busy: busy,
            onPressed: onPressed,
            onDropdown: onDropdown,
          ),
        );
      }
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.topLeft,
      child: ScrollingButtonRow(children: children),
    );
  }
}

class _ToolbarSeparator extends StatelessWidget {
  const _ToolbarSeparator();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 22,
    color: Theme.of(context).colorScheme.outlineVariant,
  );
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    super.key,
    required this.button,
    required this.icons,
    required this.busy,
    required this.onPressed,
    required this.onDropdown,
  });

  final SapToolbarButton button;
  final SapIconAtlas? icons;
  final bool busy;
  final void Function(String fcode) onPressed;
  final void Function(String fcode, Offset at) onDropdown;

  /// Where a menu opened from [context] (the tapped part) belongs: under
  /// its left edge.
  static Offset _below(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Offset.zero;
    return box.localToGlobal(Offset(0, box.size.height));
  }

  @override
  Widget build(BuildContext context) {
    final b = button;
    final scheme = Theme.of(context).colorScheme;
    final enabled = !busy && b.enabled;
    final fg = enabled
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: 0.38);
    final token = SapIconAtlas.tokenRx.firstMatch(b.icon);
    final cp = token != null ? icons?.codepoint(token.group(1)!) : null;
    final text = (icons?.stripTokens(b.text) ?? b.text)
        .replaceAll(SapIconAtlas.tokenRx, '')
        .trim();
    final quick = b.tooltip.trim();
    // an icon-less, text-less button names itself by its quick info, else
    // by its function code (SAP GUI shows an empty slot)
    final label = text.isNotEmpty
        ? text
        : (cp == null ? (quick.isNotEmpty ? quick : b.code) : '');
    final face = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (cp != null)
          Text(
            String.fromCharCode(cp),
            style: TextStyle(fontFamily: 'SapIcons', fontSize: 18, color: fg),
          ),
        if (cp != null && label.isNotEmpty) const SizedBox(width: 4),
        if (label.isNotEmpty)
          Text(label, style: TextStyle(fontSize: 13, color: fg)),
      ],
    );
    final arrow = Icon(Icons.arrow_drop_down, size: 18, color: fg);
    final radius = BorderRadius.circular(4);
    final border = Border.all(color: scheme.outlineVariant);
    final selected = b.checked;
    final bg = selected ? scheme.secondaryContainer : Colors.transparent;

    Widget part({
      required Widget child,
      required VoidCallback? onTap,
      BorderRadius? r,
      Key? key,
    }) => Material(
      key: key,
      color: Colors.transparent,
      child: InkWell(
        borderRadius: r ?? radius,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 32, minHeight: 30),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );

    final Widget body;
    if (b.splitMenu) {
      // the body fires the function, the arrow opens the menu
      body = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          part(
            child: face,
            r: const BorderRadius.horizontal(left: Radius.circular(4)),
            onTap: enabled ? () => onPressed(b.code) : null,
          ),
          Container(width: 1, height: 18, color: scheme.outlineVariant),
          Builder(
            builder: (ctx) => part(
              key: ValueKey('ctb-${b.code}-menu'),
              child: arrow,
              r: const BorderRadius.horizontal(right: Radius.circular(4)),
              onTap: enabled ? () => onDropdown(b.code, _below(ctx)) : null,
            ),
          ),
        ],
      );
    } else if (b.hasMenu) {
      body = Builder(
        builder: (ctx) => part(
          child: Row(mainAxisSize: MainAxisSize.min, children: [face, arrow]),
          onTap: enabled ? () => onDropdown(b.code, _below(ctx)) : null,
        ),
      );
    } else {
      body = part(child: face, onTap: enabled ? () => onPressed(b.code) : null);
    }
    final tip = quick.isNotEmpty ? quick : (text.isNotEmpty ? text : b.code);
    return Tooltip(
      message: tip,
      child: Semantics(
        button: true,
        enabled: enabled,
        selected: selected,
        label: tip,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: radius,
            border: border,
          ),
          child: body,
        ),
      ),
    );
  }
}
