import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

import '../../core/sap_icons.dart';
import 'session_busy.dart';
import 'type_ahead.dart';

/// The CFW combo box (CL_GUI_COMBOBOX, `SAPGUI.SAPComboBoxCtrl.1` — SE80's
/// object-list type): the selected item's text in a compact box styled
/// like the dynpro inputs, the item list as a popup menu (the selected one
/// checked); a pick is the control's -600 select event
/// ([SapSessionCfwFields.pickComboBox]).
class SapComboBoxView extends StatelessWidget {
  const SapComboBoxView({
    super.key,
    required this.box,
    required this.onPick,
    this.busy = false,
  });

  final SapComboBox box;
  final bool busy;
  final void Function(String key) onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sel = box.selected;
    final enabled = !(busy || SessionBusy.of(context)) &&
        box.enabled &&
        box.items.isNotEmpty;
    return LayoutBuilder(
      builder: (context, cons) {
        final h = cons.maxHeight.isFinite ? cons.maxHeight : 28.0;
        final font = (h * 0.55).clamp(9.0, 15.0);
        final label = Text(
          sel?.text ?? box.selectedKey ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: font,
            color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
          ),
        );
        return PopupMenuButton<String>(
          key: ValueKey('combo-${box.shell}'),
          enabled: enabled,
          tooltip: box.label.isNotEmpty ? box.label : '',
          initialValue: box.selectedKey,
          position: PopupMenuPosition.under,
          onSelected: onPick,
          itemBuilder: (_) => [
            for (final i in box.items)
              CheckedPopupMenuItem<String>(
                value: i.key,
                checked: i.key == box.selectedKey,
                height: 36,
                child: Text(i.text.isNotEmpty ? i.text : i.key),
              ),
          ],
          child: Container(
            height: h,
            padding: const EdgeInsets.only(left: 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              children: [
                if (box.label.isNotEmpty) ...[
                  Text(
                    box.label,
                    style: TextStyle(
                      fontSize: font,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(child: label),
                Icon(
                  Icons.arrow_drop_down,
                  size: font + 6,
                  color: enabled ? scheme.onSurfaceVariant : scheme.outline,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The input-history name of a CFW input field: no dynpro field names it,
/// so the screen's program and the field's prompt (SE80's "Saisir nom de
/// l'objet") — the same field on the next visit, whatever shell number the
/// server gives it then.
String cfwInputHistoryName(String? program, SapInputFieldControl f) =>
    '%INPUTFIELD.${program ?? ''}.'
    '${f.prompt.isNotEmpty ? f.prompt : f.shell}';

/// The CFW input field (CL_GUI_INPUT_FIELD, `SAPGUI.SAPInputField.1` —
/// SE80's object name): a text field styled like the dynpro inputs, its
/// `InputPrompt` as the hint, its find button (`ActivateFindButton`, the
/// `ButtonIcon` glyph with its `ButtonTooltip`) at the right edge; Enter
/// or the button submits ([SapSessionCfwFields.submitInputField]). Under a
/// [TypeAheadScope] with a [model], the input history of the field (the
/// SAP GUI's "HistoryPerField") is offered while typing.
class SapInputFieldView extends StatefulWidget {
  const SapInputFieldView({
    super.key,
    required this.field,
    required this.onSubmit,
    this.onChanged,
    this.model,
    this.icons,
    this.busy = false,
  });

  final SapInputFieldControl field;
  final bool busy;
  final SapIconAtlas? icons;

  /// The screen the field is on (the type-ahead's / history's context);
  /// null: no type-ahead.
  final ScreenModel? model;
  final void Function(String text) onSubmit;

  /// The user's typing (kept as the field's client state).
  final ValueChanged<String>? onChanged;

  @override
  State<SapInputFieldView> createState() => _SapInputFieldViewState();
}

class _SapInputFieldViewState extends State<SapInputFieldView> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.field.text,
  );
  bool _edited = false;

  @override
  void didUpdateWidget(SapInputFieldView old) {
    super.didUpdateWidget(old);
    // the server's put replaces the text unless the user is typing in it
    if (!_edited && widget.field.text != _ctrl.text) {
      _ctrl.value = TextEditingValue(
        text: widget.field.text,
        selection: TextSelection.collapsed(offset: widget.field.text.length),
      );
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Busy as the last build drew it: the view's flag or the session's
  /// ([SessionBusy], depended on in [build]).
  bool _busy = false;

  bool get _enabled =>
      !_busy && widget.field.enabled && widget.field.submitRegistered;

  void _submit() {
    if (!_enabled) return;
    _edited = false;
    widget.onSubmit(_ctrl.text);
  }

  Widget? _findButton(double font) {
    final f = widget.field;
    if (!f.findButton) return null;
    final token = SapIconAtlas.tokenRx.firstMatch(f.buttonIcon);
    final cp = token != null ? widget.icons?.codepoint(token.group(1)!) : null;
    return IconButton(
      key: ValueKey('inputfield-find-${f.shell}'),
      tooltip: f.buttonTooltip.isNotEmpty ? f.buttonTooltip : 'Submit',
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      iconSize: font + 2,
      icon: cp != null
          ? Text(
              String.fromCharCode(cp),
              style: TextStyle(fontFamily: 'SapIcons', fontSize: font + 2),
            )
          : const Icon(Icons.arrow_forward),
      onPressed: _enabled ? _submit : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    _busy = widget.busy || SessionBusy.of(context);
    final scheme = Theme.of(context).colorScheme;
    final f = widget.field;
    return LayoutBuilder(
      builder: (context, cons) {
        final h = cons.maxHeight.isFinite ? cons.maxHeight : 28.0;
        final font = (h * 0.55).clamp(9.0, 15.0);
        final find = _findButton(font);
        Widget textField(
          ValueChanged<String>? taChanged,
          ValueChanged<String>? taSubmitted,
        ) => TextField(
          key: ValueKey('inputfield-${f.shell}'),
          controller: _ctrl,
          enabled: !_busy && f.enabled,
          textAlignVertical: TextAlignVertical.center,
          textInputAction: TextInputAction.go,
          style: TextStyle(
            fontSize: font,
            fontFamily: 'Menlo',
            fontFamilyFallback: const ['Courier New', 'monospace'],
            letterSpacing: 0,
          ),
          onChanged: (v) {
            _edited = true;
            taChanged?.call(v);
            widget.onChanged?.call(v);
          },
          onSubmitted: (v) {
            taSubmitted?.call(v);
            _submit();
          },
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: scheme.surfaceContainerLowest,
            hintText: f.prompt.isNotEmpty ? f.prompt : null,
            hintStyle: TextStyle(color: scheme.outline, fontSize: font),
            contentPadding: const EdgeInsets.symmetric(horizontal: 6),
            suffixIcon: find,
            suffixIconConstraints: BoxConstraints.tightFor(
              width: font + 10,
              height: h,
            ),
            border: OutlineInputBorder(
              gapPadding: 0,
              borderRadius: BorderRadius.circular(3),
              borderSide: BorderSide(color: scheme.outlineVariant),
            ),
            enabledBorder: OutlineInputBorder(
              gapPadding: 0,
              borderRadius: BorderRadius.circular(3),
              borderSide: BorderSide(color: scheme.outlineVariant),
            ),
          ),
        );
        final model = widget.model;
        final config = TypeAheadScope.maybeOf(context);
        final Widget child = model == null || config == null
            ? textField(null, null)
            : TypeAheadInput(
                config: config,
                model: model,
                field: ScreenField(
                  kind: FieldKind.input,
                  row: 0,
                  col: 0,
                  name: cfwInputHistoryName(model.program, f),
                ),
                controller: _ctrl,
                builder: (context, onChanged, onSubmitted) =>
                    textField(onChanged, onSubmitted),
                onPicked: (v) {
                  _edited = true;
                  widget.onChanged?.call(v);
                },
              );
        return SizedBox(height: h, child: child);
      },
    );
  }
}

/// The pane of CFW control [shell] when it is a combo box or an input
/// field of [session]'s screen ([SapSessionCfwFields]), else null — the
/// session screen's per-region choice. [run] runs a session action (the
/// screen's busy / error handling).
Widget? cfwFieldControlView(
  SapSession? session,
  String shell, {
  required bool busy,
  required Future<void> Function(Future<void> Function() action) run,
  SapIconAtlas? icons,
}) {
  final s = session;
  if (s == null) return null;
  final box = s.comboBoxes[shell];
  if (box != null) {
    return SapComboBoxView(
      key: ValueKey('cfw-combo-$shell'),
      box: box,
      busy: busy,
      onPick: (key) => run(() async => s.pickComboBox(shell, key)),
    );
  }
  final field = s.cfwInputFields[shell];
  if (field != null) {
    return SapInputFieldView(
      key: ValueKey('cfw-input-$shell'),
      field: field,
      busy: busy,
      icons: icons,
      model: s.screen,
      onChanged: (v) => s.setInputFieldText(shell, v),
      onSubmit: (v) => run(() async => s.submitInputField(shell, v)),
    );
  }
  return null;
}
