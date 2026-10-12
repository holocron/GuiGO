import 'package:flutter/material.dart';

/// A password prompt that owns its text controller: the controller lives
/// as long as the dialog's widget (through its exit animation) and is
/// disposed with it. Pops the typed text, or null on [cancelLabel].
class PasswordDialog extends StatefulWidget {
  const PasswordDialog({
    super.key,
    required this.title,
    this.label = 'Password',
    this.error,
    this.note,
    this.cancelLabel = 'Cancel',
    this.okLabel = 'OK',
    this.submitOnEnter = false,
  });

  final String title;
  final String label;

  /// Shown above the field in the error colour (SAP's refusal).
  final String? error;

  /// Small print below the field.
  final String? note;
  final String cancelLabel;
  final String okLabel;

  /// Enter on the keyboard pops the text, as [okLabel] does.
  final bool submitOnEnter;

  @override
  State<PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<PasswordDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = widget.error, note = widget.note;
    final field = TextField(
      controller: _ctrl,
      obscureText: true,
      autofocus: true,
      decoration: InputDecoration(labelText: widget.label),
      onSubmitted: widget.submitOnEnter
          ? (v) => Navigator.pop(context, v)
          : null,
    );
    return AlertDialog(
      title: Text(widget.title),
      content: error == null && note == null
          ? field
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                field,
                if (note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(note, style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: Text(widget.okLabel),
        ),
      ],
    );
  }
}
