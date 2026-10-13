import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

import '../../core/sap_icons.dart';
import 'session_busy.dart';

/// The key name of a SAP virtual key (`8` → "F8", `13` → "Shift+F1"), or
/// null for keys without a function-key spelling.
String? vkeyName(int vkey) {
  if (vkey == 0) return 'Enter';
  if (vkey >= 1 && vkey <= 12) return 'F$vkey';
  if (vkey >= 13 && vkey <= 24) return 'Shift+F${vkey - 12}';
  if (vkey >= 25 && vkey <= 36) return 'Ctrl+F${vkey - 24}';
  if (vkey >= 37 && vkey <= 48) return 'Ctrl+Shift+F${vkey - 36}';
  return null;
}

/// The application toolbar of a PF-status (the 18/11 sid-3 menu entries):
/// SAP GUI's row of icon buttons, each with its name beside the glyph (the
/// entry's text, else its quick info); the row scrolls sideways when it
/// does not fit. Greyed entries are
/// disabled; a button fires its virtual key.
class SapToolbar extends StatelessWidget {
  const SapToolbar({
    super.key,
    required this.entries,
    required this.icons,
    required this.busy,
    required this.onPress,
    this.wrap = false,
  });

  final List<MenuEntry> entries;
  final SapIconAtlas? icons;
  final bool busy;
  final Future<void> Function(int vkey) onPress;

  /// Wrap onto several lines (a modal's button area) instead of scrolling
  /// horizontally (the main window's toolbar row).
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    // the session's busy too ([SessionBusy]: a modal's button area)
    final busy = this.busy || SessionBusy.of(context);
    final buttons = [
      for (final e in entries)
        if (!e.separator) _button(context, e, busy),
    ];
    if (wrap) {
      return Wrap(
        alignment: WrapAlignment.end,
        spacing: 6,
        runSpacing: 6,
        children: buttons,
      );
    }
    return ScrollingButtonRow(children: buttons);
  }

  Widget _button(BuildContext context, MenuEntry e, bool busy) {
    final token = SapIconAtlas.tokenRx.firstMatch(e.text);
    final cp = token != null ? icons?.codepoint(token.group(1)!) : null;
    final plain = (icons?.stripTokens(e.text) ?? e.text)
        .replaceAll(SapIconAtlas.tokenRx, '')
        .trim();
    final quick = e.tooltip.trim();
    final key = vkeyName(e.vkey);
    final tip = [
      if (quick.isNotEmpty) quick else if (plain.isNotEmpty) plain,
      if (key != null) '($key)',
    ].join(' ');
    final enabled = !busy && e.active;
    final scheme = Theme.of(context).colorScheme;
    final glyph = cp != null
        ? Text(
            String.fromCharCode(cp),
            style: TextStyle(
              fontFamily: 'SapIcons',
              fontSize: 20,
              // bright on the tonal fill; dimmed when greyed
              color: enabled
                  ? scheme.onSecondaryContainer
                  : scheme.onSurface.withValues(alpha: 0.38),
            ),
          )
        : null;
    // the button's name beside its icon (an icon-only button names itself
    // by its quick info): an icon alone does not say what it does
    // (a popup's button area keeps icon-only buttons: their names would
    // stack the dialog's buttons several rows deep)
    final label = plain.isNotEmpty
        ? plain
        : (glyph == null || !wrap ? quick : '');
    final onPressed = enabled ? () => onPress(e.vkey) : null;
    final style = FilledButton.styleFrom(
      minimumSize: const Size(40, 36),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    );
    return Tooltip(
      message: tip,
      child: FilledButton.tonal(
        onPressed: onPressed,
        style: style,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ?glyph,
            if (glyph != null && label.isNotEmpty) const SizedBox(width: 6),
            if (label.isNotEmpty) Text(label),
          ],
        ),
      ),
    );
  }
}

/// A row of buttons wider than the window (an application toolbar with a
/// dozen functions): scrolls sideways, and says so — an arrow at each end
/// while more buttons lie that way (a tap pages the row), the hidden edge
/// faded, a thin scrollbar under it.
class ScrollingButtonRow extends StatefulWidget {
  const ScrollingButtonRow({
    super.key,
    required this.children,
    this.bottomGap = 6,
    this.arrowSize = 24,
  });
  final List<Widget> children;

  /// The strip under the buttons the scroll bar is drawn in, and the size
  /// of the page arrows (a compact control row: smaller).
  final double bottomGap;
  final double arrowSize;

  @override
  State<ScrollingButtonRow> createState() => _ScrollingButtonRowState();
}

class _ScrollingButtonRowState extends State<ScrollingButtonRow> {
  final _c = ScrollController();
  bool _left = false, _right = false;

  /// The edge-fade mask and what it was made for: one callback per
  /// (left, right, background) — a stable one keeps the ShaderMask from
  /// repainting on every rebuild — and one shader per rect it paints.
  ShaderCallback? _mask;
  (bool, bool, Color)? _maskFor;

  ShaderCallback _maskOf(Color bg) {
    final key = (_left, _right, bg);
    final cached = _mask;
    if (cached != null && key == _maskFor) return cached;
    final gradient = LinearGradient(
      colors: [
        _left ? bg.withValues(alpha: 0) : Colors.white,
        Colors.white,
        Colors.white,
        _right ? bg.withValues(alpha: 0) : Colors.white,
      ],
      stops: const [0, 0.04, 0.96, 1],
    );
    Rect? at;
    Shader? shader;
    _maskFor = key;
    return _mask = (r) {
      if (shader == null || r != at) {
        at = r;
        shader = gradient.createShader(r);
      }
      return shader!;
    };
  }

  @override
  void initState() {
    super.initState();
    _c.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void didUpdateWidget(ScrollingButtonRow old) {
    super.didUpdateWidget(old);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _update() {
    if (!mounted || !_c.hasClients) return;
    final p = _c.position;
    final l = p.pixels > p.minScrollExtent + 1;
    final r = p.pixels < p.maxScrollExtent - 1;
    if (l != _left || r != _right) {
      setState(() {
        _left = l;
        _right = r;
      });
    }
  }

  void _page(int dir) {
    if (!_c.hasClients) return;
    final p = _c.position;
    final to = (p.pixels + dir * p.viewportDimension * 0.8).clamp(
      p.minScrollExtent,
      p.maxScrollExtent,
    );
    _c.animateTo(
      to,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    Widget arrow(int dir) => SizedBox(
      width: 32,
      child: IconButton(
        tooltip: dir < 0
            ? 'More buttons to the left'
            : 'More buttons to the right',
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        iconSize: widget.arrowSize,
        icon: Icon(dir < 0 ? Icons.chevron_left : Icons.chevron_right),
        color: scheme.primary,
        onPressed: () => _page(dir),
      ),
    );
    final row = Scrollbar(
      controller: _c,
      thumbVisibility: _left || _right,
      thickness: 3,
      child: Padding(
        padding: EdgeInsets.only(bottom: widget.bottomGap),
        child: SingleChildScrollView(
          controller: _c,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(spacing: 6, children: widget.children),
        ),
      ),
    );
    return Row(
      children: [
        if (_left) arrow(-1),
        Expanded(
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: _maskOf(bg),
            child: row,
          ),
        ),
        if (_right) arrow(1),
      ],
    );
  }
}
