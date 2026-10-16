import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

import 'dynpro_view.dart';
import 'sap_toolbar.dart';
import 'session_busy.dart';

/// A modal dynpro window: any paint with modalLevel > 0 renders as this
/// overlay card over the dimmed base window. The content is the generic
/// renderer; the action row carries the modal's own pushbuttons plus any
/// caller-provided actions — or, when the paint offers neither (a message
/// dialog), a default OK that sends Enter, the real GUI's green ✓.
class ModalDynproWindow extends StatelessWidget {
  const ModalDynproWindow({
    super.key,
    required this.model,
    required this.busy,
    required this.onFill,
    required this.onPress,
    required this.onOkcode,
    this.onRadio,
    this.radioSelection,
    this.onRadioTap,
    this.extraActions = const [],
    this.content,
    this.contentWidth,
    this.onEdit,
    this.onValueHelp,
    this.onListPick,
    this.onListCursor,
    this.onListCell,
    this.onListScroll,
    this.onFocusField,
    this.onContextMenu,
    this.onDoubleClick,
    this.listboxValueSet,
    this.onListboxPick,
  });

  final ScreenModel model;
  final bool busy;
  final Future<void> Function(ScreenField f, String text) onFill;
  final Future<void> Function(int vkey) onPress;
  final Future<void> Function(String cmd) onOkcode;
  final Future<void> Function(List<ScreenField> group, ScreenField chosen)?
  onRadio;
  final ScreenField? radioSelection;
  final void Function(List<ScreenField> group, ScreenField chosen)? onRadioTap;
  final List<Widget> extraActions;

  /// The popup's composed body (its dynpro plus the grids / trees hosted
  /// in its containers) in place of the plain dynpro, [contentWidth]
  /// points wide; null = the dynpro alone.
  final Widget? content;
  final double? contentWidth;
  final void Function(ScreenField f, String text)? onEdit;
  final Future<void> Function(ScreenField f)? onValueHelp;
  final Future<void> Function(ListLine line)? onListPick;
  final void Function(int row, int col)? onListCursor;
  final void Function(ListLine line, ListSegment cell, String text)?
  onListCell;
  final Future<void> Function(int firstLine)? onListScroll;
  final void Function(ScreenField f)? onFocusField;
  final void Function(Offset at, ScreenField? field)? onContextMenu;
  final Future<void> Function(ScreenField f)? onDoubleClick;
  final ValueSet? Function(ScreenField f)? listboxValueSet;
  final Future<void> Function(ScreenField f, String key)? onListboxPick;

  @override
  Widget build(BuildContext context) {
    final icons = SapIconAtlasStrip.of(context);
    final title = model.title.trim().isNotEmpty
        ? (icons?.stripTokens(model.title) ?? model.title).trim()
        : (model.tcode ?? 'Dialog');
    final message = model.message.trim();
    // A modal that paints no pushbutton and gets no caller action is a plain
    // message dialog — the real GUI's lone green ✓: Enter (vkey 0) closes it.
    final ownButtons = model.fields.any((f) => f.kind == FieldKind.pushbutton);
    // the popup's own PF-status toolbar (Reprendre, Insérer ligne, …) is
    // its button area, as in SAP GUI
    final toolbar = extraActions.isEmpty
        ? model.toolbar.where((e) => !e.separator).toList()
        : const <MenuEntry>[];
    final actions = [
      ...extraActions,
      if (toolbar.isNotEmpty)
        SapToolbar(
          entries: toolbar,
          icons: icons,
          busy: busy,
          onPress: onPress,
          wrap: true,
        ),
      if (extraActions.isEmpty && toolbar.isEmpty && !ownButtons)
        BusyBuilder(
          busy: busy,
          builder: (_, busy) => FilledButton.icon(
            onPressed: busy ? null : () => onPress(0),
            icon: const Icon(Icons.check),
            label: const Text('OK'),
          ),
        ),
    ];
    return ConstrainedBox(
      // the popup's own painted width on the SAP grid (a 90-column
      // multiple-selection popup), never narrower than a message dialog
      constraints: BoxConstraints(
        maxWidth: math.max(
          480.0,
          (contentWidth ?? dynproPreferredWidth(model)) + 48,
        ),
      ),
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(16),
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: Text(
                    message,
                    style: TextStyle(
                      color: model.messageSeverity >= 3
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const Divider(height: 12),
              if (content != null)
                SizedBox(width: contentWidth, child: content)
              else
                DynproView(
                  onEdit: onEdit,
                  onValueHelp: onValueHelp,
                  onListPick: onListPick,
                  onListCursor: onListCursor,
                  onListCell: onListCell,
                  onListScroll: onListScroll,
                  onFocusField: onFocusField,
                  onContextMenu: onContextMenu,
                  onDoubleClick: onDoubleClick,
                  listboxValueSet: listboxValueSet,
                  onListboxPick: onListboxPick,
                  model: model,
                  busy: busy,
                  compact: true,
                  onFill: onFill,
                  onPress: onPress,
                  onOkcode: onOkcode,
                  onRadio: onRadio,
                  radioSelection: radioSelection,
                  onRadioTap: onRadioTap,
                ),
              if (actions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OverflowBar(
                    alignment: MainAxisAlignment.end,
                    spacing: 8,
                    children: actions,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
