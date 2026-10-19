import 'package:flutter/material.dart';

/// A password prompt that owns its text controller: the controller lives
/// as long as the dialog's widget (through its exit animation) and is
/// disposed with it. Pops the typed text, or null on [cancelLabel].
/// Enter on the keyboard pops the text as [okLabel] does.
class PasswordDialog extends StatefulWidget {
  const PasswordDialog({
    super.key,
    required this.title,
    this.label = 'Password',
    this.error,
    this.note,
    this.cancelLabel = 'Cancel',
    this.okLabel = 'OK',
  });

  final String title;
  final String label;

  /// Shown above the field in the error colour (SAP's refusal).
  final String? error;

  /// Small print below the field.
  final String? note;
  final String cancelLabel;
  final String okLabel;


  @override
  State<PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<PasswordDialog> {
  final _ctrl = TextEditingController();

  /// The eye toggle: SAP passwords are case-sensitive and often complex,
  /// typed blind on a phone keyboard they are mistyped — and a mistyped
  /// value stored by the list screen is only found out as a refusal at
  /// logon (which SAP counts towards its failed-logon lock).
  bool _show = false;

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
      obscureText: !_show,
      // once revealed the field is plain text to the keyboard: no
      // autocorrect or suggestions on a password
      autocorrect: false,
      enableSuggestions: false,
      autofocus: true,
      decoration: InputDecoration(
        labelText: widget.label,
        // the toggle never takes the focus from the field
        suffixIcon: ExcludeFocus(
          child: IconButton(
            tooltip: _show ? 'Hide password' : 'Show password',
            icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _show = !_show),
          ),
        ),
      ),
      onSubmitted: (v) => Navigator.pop(context, v),
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
