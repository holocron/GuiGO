import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

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
/// list opens as a popup menu (the selected entry checked); a pick calls
/// [onPick] with the entry's KEY. Display-only (a PROTECTED listbox, the
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
    final menu = PopupMenuButton<String>(
      key: ValueKey('listbox-${field.name}'),
      enabled: enabled,
      tooltip: '',
      initialValue: selected,
      position: PopupMenuPosition.under,
      onSelected: (key) {
        if (key != selected) onPick?.call(key);
      },
      itemBuilder: (_) => [
        for (final e in entries)
          CheckedPopupMenuItem<String>(
            value: e.key,
            checked: e.key == selected,
            height: 36,
            child: Text(_entryText(e)),
          ),
      ],
      child: box,
    );
    return tip.isEmpty ? menu : Tooltip(message: tip, child: menu);
  }
}
