import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsRole;

/// Whether every dropdown listbox shows its KEY beside its text — SAP GUI's
/// "show keys in all dropdown lists" option (SAP GUI for Java
/// `GuiApplication.isListboxKeyAlwaysShown`). On, as on the SAP GUI for
/// Windows this client is compared with (PA20 infotype 0006: `1 Domicile
/// fixe`, `CH Suisse`); a listbox painted WITH KEY ([ListboxAtom.withKey])
/// shows it whatever the option.
const bool showAllListboxKeys = true;

/// A classic dynpro DROPDOWN LISTBOX (etype 126): the selected entry —
/// `key text` ([listboxDisplayText]) once the field's value set is held,
/// the bare key until then — in a box with the dropdown arrow. The entry
/// list opens as a popup under the box (the selected entry checked, the
/// list virtualized: a cost-center set of hundreds of entries builds the
/// rows in view, not every one — audit 2026-10-23 P-9 — and from
/// [filterFrom] entries up a filter line narrows it, as the F4 dialog's
/// does); a pick calls [onPick] with the entry's KEY. Display-only (a PROTECTED listbox, the
/// change-mode-less screen) when [onPick] is null, the field is protected
/// or no entry is known: the box is drawn, nothing opens — the real GUI
/// refuses that pick locally too (a recorded session).
class DynproListboxView extends StatelessWidget {
  const DynproListboxView({
    super.key,
    required this.field,
    this.valueSet,
    this.onPick,
    this.busy = false,
    this.fontSize = 14,
    this.monospace = false,
    this.showKeys = showAllListboxKeys,
    this.height,
  });

  final ScreenField field;

  /// The field's entries, null while none is held.
  final ValueSet? valueSet;
  final Future<void> Function(String key)? onPick;
  final bool busy;
  final double fontSize;

  /// The dynpro grid's cell font (Menlo) instead of the form's.
  final bool monospace;

  /// [showAllListboxKeys] — the frontend option.
  final bool showKeys;

  /// The box height; null = the dense input height.
  final double? height;

  /// The painted KEY as the value set spells it (leading blanks kept).
  String get _key => field.listbox?.key ?? field.text;

  bool get _keyShown => showKeys || (field.listbox?.withKey ?? false);

  /// The text the box shows.
  String get displayText =>
      listboxDisplayText(_key, valueSet, showKey: _keyShown);

  String _entryText(ValueSetEntry e) => _keyShown
      ? (e.key.trim().isEmpty ? e.text : '${e.key.trim()}  ${e.text}')
      : (e.text.isNotEmpty ? e.text : e.key);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = valueSet?.entries ?? const <ValueSetEntry>[];
    final enabled =
        !busy && onPick != null && !field.isProtected && entries.isNotEmpty;
    final style = TextStyle(
      fontSize: fontSize,
      color: field.isProtected ? scheme.onSurfaceVariant : scheme.onSurface,
      fontFamily: monospace ? 'Menlo' : null,
      fontFamilyFallback: monospace ? const ['Courier New', 'monospace'] : null,
      letterSpacing: monospace ? 0 : null,
      height: 1.1,
    );
    final selected = _key.trimRight();
    final box = Container(
      height: height,
      padding: const EdgeInsets.only(left: 4),
      decoration: BoxDecoration(
        color: field.isProtected
            ? scheme.surfaceContainerHighest
            : scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              displayText,
              key: ValueKey('listbox-text-${field.name}'),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          Icon(
            Icons.arrow_drop_down,
            key: ValueKey('listbox-arrow-${field.name}'),
            size: fontSize + 4,
            color: enabled ? scheme.onSurfaceVariant : scheme.outline,
          ),
        ],
      ),
    );
    final tip = field.label.isNotEmpty ? field.label : (field.name ?? '');
    final menu = Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: ValueKey('listbox-${field.name}'),
        onTap: enabled ? () => _open(context, entries, selected) : null,
        child: box,
      ),
    );
    return tip.isEmpty ? menu : Tooltip(message: tip, child: menu);
  }

  /// Entries from which the popup carries a filter line.
  static const int filterFrom = 20;

  /// The row height of the popup's entries.
  static const double entryHeight = 36;

  Future<void> _open(
    BuildContext context,
    List<ValueSetEntry> entries,
    String selected,
  ) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final key = await Navigator.of(context).push(
      _ListboxPopupRoute(
        anchor: anchor,
        entries: entries,
        selected: selected,
        entryText: _entryText,
        textStyle: DefaultTextStyle.of(context).style,
      ),
    );
    if (key != null && key != selected) await onPick?.call(key);
  }
}

/// The entry list of a [DynproListboxView], under its box (above it when
/// the room below is short), as wide as its longest entry within the
/// screen; the barrier is clear and a tap on it closes the list. Pops
/// with the picked KEY, null when dismissed.
class _ListboxPopupRoute extends PopupRoute<String> {
  _ListboxPopupRoute({
    required this.anchor,
    required this.entries,
    required this.selected,
    required this.entryText,
    required this.textStyle,
  });

  final Rect anchor;
  final List<ValueSetEntry> entries;
  final String selected;
  final String Function(ValueSetEntry e) entryText;
  final TextStyle textStyle;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final media = MediaQuery.of(context);
    // the width of the longest entry — the longest string measured, not
    // every entry laid out (the popup menu measured each child)
    var longest = '';
    for (final e in entries) {
      final t = entryText(e);
      if (t.length > longest.length) longest = t;
    }
    final painter = TextPainter(
      text: TextSpan(text: longest, style: textStyle),
      textDirection: TextDirection.ltr,
      textScaler: media.textScaler,
    )..layout();
    final textW = painter.width;
    painter.dispose();
    // the check mark's column (a CheckedPopupMenuItem is a ListTile with a
    // leading icon: 16 + 40 + 16 + text + 16)
    final width = math.max(anchor.width, textW + 16 + 40 + 16 + 16);
    final filtered = entries.length >= DynproListboxView.filterFrom;
    return CustomSingleChildLayout(
      delegate: _UnderAnchor(
        anchor: anchor,
        width: width,
        screen: media.size,
        padding: media.padding,
      ),
      child: FadeTransition(
        opacity: animation,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          // the entries are menu items (their check mark's semantics need
          // a menu around them)
          child: Semantics(
            role: SemanticsRole.menu,
            explicitChildNodes: true,
            child: _ListboxEntries(
              entries: entries,
              selected: selected,
              entryText: entryText,
              filter: filtered,
            ),
          ),
        ),
      ),
    );
  }
}

/// Places the list under [anchor] (above it when the room above is the
/// larger and the list does not fit below), within the screen's safe area.
class _UnderAnchor extends SingleChildLayoutDelegate {
  const _UnderAnchor({
    required this.anchor,
    required this.width,
    required this.screen,
    required this.padding,
  });

  final Rect anchor;
  final double width;
  final Size screen;
  final EdgeInsets padding;

  static const double _margin = 8;

  double get _below => screen.height - padding.bottom - _margin - anchor.bottom;
  double get _above => anchor.top - padding.top - _margin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final maxW = math.max(0.0, screen.width - 2 * _margin);
    final room = math.max(_below, _above);
    return BoxConstraints(
      minWidth: math.min(width, maxW),
      maxWidth: maxW,
      maxHeight: math.max(0.0, math.min(room, screen.height * 0.6)),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = anchor.left
        .clamp(_margin, math.max(_margin, size.width - _margin - childSize.width))
        .toDouble();
    final top = childSize.height <= _below
        ? anchor.bottom
        : anchor.top - childSize.height;
    return Offset(left, top.clamp(padding.top + _margin, size.height).toDouble());
  }

  @override
  bool shouldRelayout(_UnderAnchor old) =>
      anchor != old.anchor ||
      width != old.width ||
      screen != old.screen ||
      padding != old.padding;
}

/// The virtualized entry list, with a filter line when [filter].
class _ListboxEntries extends StatefulWidget {
  const _ListboxEntries({
    required this.entries,
    required this.selected,
    required this.entryText,
    required this.filter,
  });

  final List<ValueSetEntry> entries;
  final String selected;
  final String Function(ValueSetEntry e) entryText;
  final bool filter;

  @override
  State<_ListboxEntries> createState() => _ListboxEntriesState();
}

class _ListboxEntriesState extends State<_ListboxEntries> {
  final _query = TextEditingController();
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    // opened at the selected entry (a couple of rows above it in view)
    final i = widget.entries.indexWhere((e) => e.key == widget.selected);
    _scroll = ScrollController(
      initialScrollOffset: i <= 0
          ? 0
          : math.max(0.0, (i - 2) * DynproListboxView.entryHeight),
    );
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.text.trim().toLowerCase();
    final shown = q.isEmpty
        ? widget.entries
        : [
            for (final e in widget.entries)
              if (widget.entryText(e).toLowerCase().contains(q)) e,
          ];
    final list = shown.isEmpty
        ? const Padding(
            padding: EdgeInsets.all(12),
            child: Text('No entry matches'),
          )
        : ListView.builder(
            controller: _scroll,
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemExtent: DynproListboxView.entryHeight,
            itemCount: shown.length,
            itemBuilder: (context, i) {
              final e = shown[i];
              return CheckedPopupMenuItem<String>(
                value: e.key,
                checked: e.key == widget.selected,
                height: DynproListboxView.entryHeight,
                child: Text(widget.entryText(e)),
              );
            },
          );
    if (!widget.filter) return list;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
          child: TextField(
            key: const ValueKey('listbox-filter'),
            controller: _query,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'Filter',
              isDense: true,
            ),
          ),
        ),
        Flexible(child: list),
      ],
    );
  }
}
