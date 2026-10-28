import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

import '../../core/sap_icons.dart';
import 'sap_toolbar.dart' show ScrollingButtonRow;
import 'session_busy.dart';

/// A CFW control toolbar — the OO-ALV grid's own button row (sort, filter,
/// totals, export, "Modifier mise en forme" …) or a SAP.Toolbar.1 control
/// (diag_protocol control_toolbar.dart): SAP GUI's compact icon buttons,
/// each with its quick info as the tooltip and its text beside the icon
/// when it has one — and, at the natural row height, an icon-only button
/// named by its quick info beside its icon, as the application toolbar
/// names its own (sap_toolbar.dart: an icon alone does not say what it
/// does, and a phone has no hover; SAP GUI draws these icon-only). The
/// flat one-cell row keeps the glyph alone ([_ToolbarMetrics.flat]).
/// Separators as thin rules; a menu button with a small dropdown arrow — a
/// split one (type 1) fires its function from the body and opens the menu
/// from the arrow, a menu-only one (type 2) opens it from anywhere; a
/// disabled button greyed, a checked one highlighted. The row scrolls
/// sideways when it does not fit, and a "More" button past it (outside
/// the scrolling row, so it never scrolls away) lists every button by name
/// in a sheet of finger-sized rows — the standard ALV toolbar's 15-20
/// functions on a phone.
///
/// In a control ROW shorter than its natural [naturalHeight] (a splitter
/// cell's one-cell toolbar row: /AIF/IFMON's ALV tree toolbar, SE80's
/// dock rows — [ControlRowExtent] names the height) the buttons are laid
/// out AT that height, icon and text sized to it, instead of the natural
/// row scaled down whole: scaled, a one-cell row (~16 points) drew the
/// buttons at under half size — 8-point icons, 6-point labels — however
/// much width the row had.
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

  /// The height the row is drawn in by default: 30-point buttons over the
  /// scroll bar's 6-point strip.
  static const double naturalHeight = 36;

  @override
  Widget build(BuildContext context) {
    final m = _ToolbarMetrics.of(context);
    final children = <Widget>[];
    final codes = <String>{};
    for (var i = 0; i < buttons.length; i++) {
      final b = buttons[i];
      if (b.separator) {
        // a leading, trailing or doubled separator draws nothing
        if (children.isEmpty || i == buttons.length - 1) continue;
        if (buttons[i + 1].separator) continue;
        children.add(_ToolbarSeparator(height: m.separator));
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
            metrics: m,
            onPressed: onPressed,
            onDropdown: onDropdown,
          ),
        );
      }
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.topLeft,
            // a compact row: SAP GUI's tight spacing, so a one-cell dock
            // pane's two buttons (SE80's F4 / Display beside the object
            // name, 56 points wide) fit beside the More button
            child: ScrollingButtonRow(
              bottomGap: m.bottomGap,
              arrowSize: m.arrow + 4,
              spacing: m.flat ? 2 : 6,
              padding: EdgeInsets.symmetric(horizontal: m.flat ? 2 : 8),
              children: children,
            ),
          ),
        ),
        _MoreButton(
          buttons: buttons,
          icons: icons,
          busy: busy,
          metrics: m,
          onPressed: onPressed,
          onDropdown: onDropdown,
        ),
      ],
    );
  }
}

/// The name a button goes by: its text, else its quick info, else its
/// function code (SAP GUI shows an empty slot).
String _nameOf(SapToolbarButton b, SapIconAtlas? icons) {
  final text = (icons?.stripTokens(b.text) ?? b.text)
      .replaceAll(SapIconAtlas.tokenRx, '')
      .trim();
  if (text.isNotEmpty) return text;
  final quick = b.tooltip.trim();
  return quick.isNotEmpty ? quick : b.code;
}

/// The SAP icon font glyph of [b]'s icon, null without one the atlas holds.
Widget? _glyphOf(
  SapToolbarButton b,
  SapIconAtlas? icons,
  double size,
  Color fg,
) {
  final token = SapIconAtlas.tokenRx.firstMatch(b.icon);
  final cp = token != null ? icons?.codepoint(token.group(1)!) : null;
  if (cp == null) return null;
  return Text(
    String.fromCharCode(cp),
    semanticsLabel: '',
    style: TextStyle(
      fontFamily: 'SapIcons',
      fontSize: size,
      height: 1,
      color: fg,
    ),
  );
}

/// The button past the scrolling row: every toolbar function by name in a
/// bottom sheet (finger-sized rows), with the same wiring as the row — a
/// menu-only button opens its menu, a split one fires from its row and
/// opens the menu from its trailing arrow. Not a dropdown glyph (the
/// row's own arrows are counted by tests and are the menu buttons'), not a
/// framed button (a frame counts as a button of the row).
class _MoreButton extends StatelessWidget {
  const _MoreButton({
    required this.buttons,
    required this.icons,
    required this.busy,
    required this.metrics,
    required this.onPressed,
    required this.onDropdown,
  });

  final List<SapToolbarButton> buttons;
  final SapIconAtlas? icons;
  final bool busy;
  final _ToolbarMetrics metrics;
  final void Function(String fcode) onPressed;
  final void Function(String fcode, Offset at) onDropdown;

  @override
  Widget build(BuildContext context) {
    final enabled = !(busy || SessionBusy.of(context));
    return Padding(
      padding: EdgeInsets.only(bottom: metrics.bottomGap),
      child: Builder(
        builder: (ctx) => IconButton(
          key: const ValueKey('ctb-more'),
          tooltip: 'All toolbar functions',
          icon: const Icon(Icons.more_horiz),
          iconSize: metrics.icon,
          padding: EdgeInsets.zero,
          constraints: BoxConstraints.tightFor(
            width: metrics.button,
            height: metrics.button,
          ),
          // a compact row: the button its own size, not padded to the
          // 48-point tap minimum (which left a one-cell dock pane's
          // buttons a 0-point viewport); no smaller than the row's own
          // buttons
          style: identical(metrics, _ToolbarMetrics.natural)
              ? null
              : IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  minimumSize: Size.zero,
                ),
          onPressed: enabled ? () => _open(ctx) : null,
        ),
      ),
    );
  }

  /// [context]: the button's own (the menus open under it).
  void _open(BuildContext context) {
    // the menus open under the More button, inside the control: the
    // server's cascade is anchored at the point it is told
    final at = _ToolbarButton._below(context);
    // the sheet closes over the buttons as pushed now: a re-push while it
    // is open leaves it stale, as an open menu is (and it is closed by a
    // pick or a swipe)
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) {
        final scheme = Theme.of(sheet).colorScheme;
        final busyNow = busy || SessionBusy.of(sheet);
        final rows = [
          for (final b in buttons)
            if (!b.separator) b,
        ];
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.5,
          minChildSize: 0.25,
          maxChildSize: 0.95,
          builder: (sheet, controller) => ListView.builder(
            controller: controller,
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final b = rows[i];
              final enabled = !busyNow && b.enabled;
              final fg = enabled
                  ? scheme.onSurface
                  : scheme.onSurface.withValues(alpha: 0.38);
              void pick(void Function() act) {
                Navigator.pop(sheet);
                act();
              }

              return ListTile(
                key: ValueKey('ctb-more-${b.code}'),
                enabled: enabled,
                selected: b.checked,
                leading: SizedBox(
                  width: 24,
                  child: Center(child: _glyphOf(b, icons, 18, fg)),
                ),
                title: Text(_nameOf(b, icons)),
                // a split button: its row fires, its arrow opens the menu
                trailing: b.splitMenu
                    ? IconButton(
                        key: ValueKey('ctb-more-${b.code}-menu'),
                        tooltip: 'Menu',
                        icon: const Icon(Icons.arrow_drop_down),
                        onPressed: enabled
                            ? () => pick(() => onDropdown(b.code, at))
                            : null,
                      )
                    : (b.hasMenu ? const Icon(Icons.arrow_drop_down) : null),
                onTap: !enabled
                    ? null
                    : b.hasMenu && !b.splitMenu
                    ? () => pick(() => onDropdown(b.code, at))
                    : () => pick(() => onPressed(b.code)),
              );
            },
          ),
        );
      },
    );
  }
}

/// The height of the control row a [SapControlToolbarView] is drawn in
/// when its pane gives it less than [SapControlToolbarView.naturalHeight]
/// (the session screen's control rows): its buttons are laid out at it.
class ControlRowExtent extends InheritedWidget {
  const ControlRowExtent({
    super.key,
    required this.height,
    required super.child,
  });

  final double height;

  static double? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ControlRowExtent>()?.height;

  @override
  bool updateShouldNotify(ControlRowExtent old) => old.height != height;
}

/// A toolbar row's sizes: the natural ones, or those of a compact row of
/// a given height (buttons its full height, the icon and the label sized
/// to it, the scroll bar over the buttons' lower edge).
class _ToolbarMetrics {
  const _ToolbarMetrics({
    required this.button,
    required this.icon,
    required this.font,
    required this.arrow,
    required this.separator,
    required this.bottomGap,
    required this.padding,
    this.flat = false,
  });

  final double button, icon, font, arrow, separator, bottomGap, padding;

  /// A row of one window cell (a docked pane's toolbar: PA20's object
  /// manager, `SEARCH_PREV @9S@` … `COLLAPSE_ALL @69@`, a recorded session
  /// enjoy srv[184]): SAP GUI's flat buttons — the glyph fills the
  /// button, no frame, a disabled one greyed but legible. Framed, an 11-
  /// point line glyph at 38 % in a 13-point box drew as an empty box.
  final bool flat;

  static const natural = _ToolbarMetrics(
    button: 30,
    icon: 18,
    font: 13,
    arrow: 18,
    separator: 22,
    bottomGap: 6,
    padding: 6,
  );

  static _ToolbarMetrics of(BuildContext context) {
    final h = ControlRowExtent.maybeOf(context);
    if (h == null || h >= SapControlToolbarView.naturalHeight) return natural;
    final gap = h >= 28 ? 4.0 : 1.0;
    final b = h - gap;
    final flat = b < 24;
    return _ToolbarMetrics(
      flat: flat,
      button: b,
      icon: (b * (flat ? 1.0 : 0.85)).clamp(9.0, 18.0),
      font: (b * 0.68).clamp(8.0, 13.0),
      arrow: (b * 0.9).clamp(10.0, 18.0),
      separator: (b * 0.75).clamp(8.0, 22.0),
      bottomGap: gap,
      padding: b < 20 ? (flat ? 2 : 4) : 6,
    );
  }
}

class _ToolbarSeparator extends StatelessWidget {
  const _ToolbarSeparator({this.height = 22});

  final double height;

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: height,
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
    this.metrics = _ToolbarMetrics.natural,
  });

  final SapToolbarButton button;
  final SapIconAtlas? icons;
  final bool busy;
  final _ToolbarMetrics metrics;
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
    final enabled = !(busy || SessionBusy.of(context)) && b.enabled;
    final fg = enabled
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: metrics.flat ? 0.5 : 0.38);
    final token = SapIconAtlas.tokenRx.firstMatch(b.icon);
    final cp = token != null ? icons?.codepoint(token.group(1)!) : null;
    final text = (icons?.stripTokens(b.text) ?? b.text)
        .replaceAll(SapIconAtlas.tokenRx, '')
        .trim();
    final quick = b.tooltip.trim();
    // a text-less button names itself by its quick info, else by its
    // function code (SAP GUI shows an empty slot) — beside its icon too,
    // at the natural height (the font is 13 there, legible); a flat
    // one-cell row (PA20's object manager, SE80's dock) keeps the glyph
    // filling the button, a name would blow a server-sized cell sideways
    final label = text.isNotEmpty
        ? text
        : (cp == null || !metrics.flat
              ? (quick.isNotEmpty ? quick : b.code)
              : '');
    final face = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (cp != null)
          Text(
            String.fromCharCode(cp),
            style: TextStyle(
              fontFamily: 'SapIcons',
              fontSize: metrics.icon,
              height: 1,
              color: fg,
            ),
          ),
        if (cp != null && label.isNotEmpty) const SizedBox(width: 4),
        if (label.isNotEmpty)
          Text(label, style: TextStyle(fontSize: metrics.font, color: fg)),
      ],
    );
    final arrow = Icon(Icons.arrow_drop_down, size: metrics.arrow, color: fg);
    final radius = BorderRadius.circular(4);
    final border = metrics.flat
        ? null
        : Border.all(color: scheme.outlineVariant);
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
          constraints: BoxConstraints(
            minWidth: metrics.button < 30 ? metrics.button : 32,
            minHeight: metrics.button,
          ),
          padding: EdgeInsets.symmetric(horizontal: metrics.padding),
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
          Container(
            width: 1,
            height: metrics.arrow,
            color: scheme.outlineVariant,
          ),
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
        // the label is the name drawn on the face: not read twice
        excludeSemantics: true,
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
