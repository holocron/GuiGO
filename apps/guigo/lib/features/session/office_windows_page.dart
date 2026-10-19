import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

import 'sap_office_view.dart';

/// The session's Office windows ([SapSessionOffice.officeWindows]): the
/// documents the server opened in Excel's / Word's OWN window rather than
/// in place — XXL's spreadsheet (DWDM "Api test simple"). SAP GUI for
/// Windows brings that Office window up beside the session; GuiGo shows it
/// on this page, opened from the session's app bar, one tab per window,
/// each closable ([SapSessionOffice.dismissOfficeWindow]). Read-only, like
/// the in-place pane ([SapOfficeView]); nothing goes on the wire.
class OfficeWindowsPage extends StatefulWidget {
  const OfficeWindowsPage({super.key, required this.windows, this.onClose});

  /// The windows, newest first.
  final List<SapOfficeDocument> Function() windows;

  /// The user closed [window].
  final void Function(SapOfficeDocument window)? onClose;

  @override
  State<OfficeWindowsPage> createState() => _OfficeWindowsPageState();
}

/// The title an Office window carries: its application, by family.
String officeWindowTitle(SapOfficeDocument d) => switch (d.kind) {
  OfficeDocKind.excel => 'Microsoft Excel',
  OfficeDocKind.word => 'Microsoft Word',
  OfficeDocKind.other => d.progId,
};

class _OfficeWindowsPageState extends State<OfficeWindowsPage> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final wins = widget.windows();
    if (_index >= wins.length) _index = wins.isEmpty ? 0 : wins.length - 1;
    final current = wins.isEmpty ? null : wins[_index];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          current == null ? 'Office' : officeWindowTitle(current),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (current != null && widget.onClose != null)
            IconButton(
              tooltip: 'Close window',
              icon: const Icon(Icons.close),
              onPressed: () {
                widget.onClose!(current);
                if (widget.windows().isEmpty) {
                  Navigator.of(context).maybePop();
                } else {
                  setState(() {});
                }
              },
            ),
        ],
        bottom: wins.length < 2
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: [
                      for (final (i, w) in wins.indexed)
                        ButtonSegment<int>(
                          value: i,
                          label: Text('${officeWindowTitle(w)} ${i + 1}'),
                        ),
                    ],
                    selected: {_index},
                    onSelectionChanged: (s) =>
                        setState(() => _index = s.single),
                  ),
                ),
              ),
      ),
      body: current == null
          ? const Center(child: Text('No Office window is open.'))
          : SapOfficeView(
              // by shell alone: a tab closed or shifted keeps the view (and
              // its parsed document) of the window still shown
              key: ValueKey('office-window-${current.shell}'),
              document: current,
            ),
    );
  }
}
