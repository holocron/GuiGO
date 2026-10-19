import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

import 'session_busy.dart';

/// The SAP GUI for Windows F4 value-help dialog (SAP.TABControl.1): the
/// restriction pages as tabs, each page's inputs, the search / close
/// buttons, the server's status line and the hit list; a tapped row is the
/// pick (the server then fills the field and tears the dialog down).
///
/// Over a hit list a filter field narrows the rows shown — on the client,
/// no round: a case-insensitive substring over the shown columns (the
/// desktop's Ctrl+F in the hit list; 500 hits are twenty phone screens).
/// It narrows what the server delivered and no more (the status line
/// says when more exist than the max hits: the restriction search is the
/// way to those), and a pick still sends the row's wire index.
class SapValueHelpView extends StatefulWidget {
  const SapValueHelpView({
    super.key,
    required this.dialog,
    this.busy = false,
    required this.onSearch,
    required this.onPage,
    required this.onPick,
    required this.onClose,
  });

  final SapValueHelpDialog dialog;
  final bool busy;

  /// Search page [page] with the typed restrictions (item id -> value).
  final void Function(String page, Map<String, String> restrictions) onSearch;
  final void Function(String page) onPage;

  /// Pick hit-list row [row] (1-based).
  final void Function(int row) onPick;
  final VoidCallback onClose;

  @override
  State<SapValueHelpView> createState() => _SapValueHelpViewState();
}

class _SapValueHelpViewState extends State<SapValueHelpView> {
  /// Typed restrictions per page, item id -> controller.
  final Map<String, Map<String, TextEditingController>> _inputs = {};

  /// The measured width of each hit-list text (by text and style) at
  /// [_measuredAt]: the dialog rebuilds with every session turn while it is
  /// open, and its 300 x columns cells are laid out once, not per build.
  final Map<(String, TextStyle), double> _widths = {};
  TextScaler? _measuredAt;

  /// How many texts were laid out (tests read it).
  @visibleForTesting
  int measured = 0;

  /// The hit-list filter: its field, and the rows' haystacks (the shown
  /// columns joined, lowercased) built once per result list and column
  /// set — the dialog rebuilds every session turn, 500 x N cells are not
  /// lowercased per build.
  final _filter = TextEditingController();
  List<List<String>>? _haystackRows;
  List<int> _haystackShown = const [];
  List<String> _haystack = const [];

  List<String> _haystackOf(List<List<String>> rows, List<int> shown) {
    if (identical(rows, _haystackRows) && _sameInts(shown, _haystackShown)) {
      return _haystack;
    }
    _haystackRows = rows;
    _haystackShown = shown;
    return _haystack = [
      for (final r in rows)
        [
          for (final i in shown)
            if (i < r.length) r[i],
        ].join('\u0000').toLowerCase(),
    ];
  }

  static bool _sameInts(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void didUpdateWidget(SapValueHelpView old) {
    super.didUpdateWidget(old);
    // a new search's hits (another list): a stale filter would hide them
    if (!identical(old.dialog.resultRows, widget.dialog.resultRows)) {
      _filter.clear();
    }
  }

  double _measure(String text, TextStyle style, TextScaler scaler) {
    if (scaler != _measuredAt || _widths.length > 20000) {
      _widths.clear();
      _measuredAt = scaler;
    }
    return _widths.putIfAbsent((text, style), () {
      measured++;
      final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final w = tp.width;
      tp.dispose();
      return w;
    });
  }

  @override
  void dispose() {
    for (final page in _inputs.values) {
      for (final c in page.values) {
        c.dispose();
      }
    }
    _filter.dispose();
    super.dispose();
  }

  TextEditingController _ctrl(SapValueHelpPage page, SapValueHelpItem item) {
    final m = _inputs.putIfAbsent(page.id, () => {});
    return m.putIfAbsent(item.id, () {
      // a pre-filled input shows its pushed default
      final pre = item.isPrefilledInput ? item.text : '';
      return TextEditingController(text: pre);
    });
  }

  void _search(SapValueHelpPage page) {
    final out = <String, String>{};
    for (final item in page.fields) {
      final c = _inputs[page.id]?[item.id];
      if (c != null) out[item.id] = c.text;
    }
    widget.onSearch(page.id, out);
  }

  /// Busy as the last build drew it: the view's flag or the session's
  /// ([SessionBusy], depended on in [build]).
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    _busy = widget.busy || SessionBusy.of(context);
    final d = widget.dialog;
    final theme = Theme.of(context);
    final page = d.activePage;
    final title = d.title.trim().isNotEmpty ? d.title.trim() : 'Value help';
    return Material(
      elevation: 8,
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: _busy ? null : widget.onClose,
                ),
              ],
            ),
          ),
          if (d.pages.length > 1)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final p in d.pages)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(
                          p.title.trim().isNotEmpty ? p.title.trim() : p.id,
                        ),
                        selected: p.id == page?.id,
                        onSelected: _busy || p.id == page?.id
                            ? null
                            : (_) => widget.onPage(p.id),
                      ),
                    ),
                ],
              ),
            ),
          if (page != null) _restrictions(page),
          if ((d.statusLine ?? '').trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(
                d.statusLine!.trim(),
                style: theme.textTheme.bodySmall,
              ),
            ),
          const Divider(height: 1),
          Expanded(child: _hitList(d)),
        ],
      ),
    );
  }

  Widget _restrictions(SapValueHelpPage page) {
    final fields = page.fields;
    final maxHits = page.maxHits;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in fields)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: TextField(
                  controller: _ctrl(page, item),
                  enabled: !_busy,
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    labelText: item.label.trim().isNotEmpty
                        ? item.label.trim()
                        : item.fieldName,
                  ),
                  onSubmitted: (_) => _search(page),
                ),
              ),
            Row(
              children: [
                if (maxHits != null)
                  Expanded(
                    child: Text(
                      'Max. hits: ${maxHits.text.trim()}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                else
                  const Spacer(),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _search(page),
                  icon: const Icon(Icons.search),
                  label: const Text('Search'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _hitList(SapValueHelpDialog d) {
    if (!d.hasResults) {
      return const Center(child: Text('Enter restrictions and search'));
    }
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    const headStyle = TextStyle(fontWeight: FontWeight.w600, fontSize: 14);
    const cellStyle = TextStyle(fontFamily: 'Menlo', fontSize: 13);
    final keyStyle = cellStyle.copyWith(fontWeight: FontWeight.w600);
    double measure(String text, TextStyle style) =>
        _measure(text, style, scaler);

    // a column's heading: the longest the server gave (SCRTEXT_M / _L over
    // the short SCRTEXT, as the OCX widens a narrow key column's title)
    final heading = <String, String>{
      for (final c in d.resultColumns)
        c.fieldName: [c.mediumTitle, c.longTitle, c.title]
            .map((t) => t.trim())
            .firstWhere((t) => t.isNotEmpty, orElse: () => c.fieldName),
    };
    // the shown columns: the headed ones in the hit list's order, else all
    final shown = <int>[
      for (var i = 0; i < d.resultFields.length; i++)
        if (heading.isEmpty || heading.containsKey(d.resultFields[i])) i,
    ];
    final key = d.keyColumn;
    // the filter: the rows whose shown cells hold the typed text, as
    // their ORIGINAL indexes (a pick sends the wire row); the widths stay
    // the unfiltered rows' so the table does not reflow per keystroke
    final q = _filter.text.trim().toLowerCase();
    final all = d.resultRows;
    final visible = q.isEmpty
        ? [for (var i = 0; i < all.length; i++) i]
        : () {
            final hay = _haystackOf(all, shown);
            return [
              for (var i = 0; i < all.length; i++)
                if (hay[i].contains(q)) i,
            ];
          }();
    const pad = 16.0 + 4; // the cell's padding and a little air
    final natural = <int, double>{
      for (final i in shown)
        i: () {
          var w = measure(
            heading[d.resultFields[i]] ?? d.resultFields[i],
            headStyle,
          );
          for (final r in d.resultRows.take(300)) {
            if (i < r.length) {
              final v = measure(
                r[i].trimRight(),
                i == key ? keyStyle : cellStyle,
              );
              if (v > w) w = v;
            }
          }
          return (w + pad).clamp(48.0, 420.0);
        }(),
    };
    Widget cell(String text, double w, {TextStyle? style}) => SizedBox(
      width: w,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    );
    final table = LayoutBuilder(
      builder: (context, box) {
        // the columns at their natural widths; spare width goes to the last
        final sum = natural.values.fold<double>(0, (a, b) => a + b);
        final widths = Map.of(natural);
        if (shown.isNotEmpty && sum < box.maxWidth) {
          widths[shown.last] = widths[shown.last]! + box.maxWidth - sum;
        }
        final total = widths.values.fold<double>(0, (a, b) => a + b);
        return Scrollbar(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: total,
              child: Column(
                children: [
                  Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Row(
                      children: [
                        for (final i in shown)
                          cell(
                            heading[d.resultFields[i]] ?? d.resultFields[i],
                            widths[i]!,
                            style: headStyle,
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: visible.isEmpty
                        ? Center(
                            child: Text(
                              'No hits match "${_filter.text.trim()}"',
                              style: theme.textTheme.bodyMedium,
                            ),
                          )
                        : ListView.builder(
                            itemCount: visible.length,
                            itemBuilder: (context, v) {
                              final r = visible[v];
                              final row = all[r];
                              return Material(
                                // striped by the place shown, not the row
                                color: v.isOdd
                                    ? theme.colorScheme.surfaceContainerLow
                                    : theme.colorScheme.surface,
                                child: InkWell(
                                  onTap: _busy
                                      ? null
                                      : () => widget.onPick(r + 1),
                                  child: Row(
                                    children: [
                                      for (final i in shown)
                                        cell(
                                          i < row.length
                                              ? row[i].trimRight()
                                              : '',
                                          widths[i]!,
                                          style: i == key
                                              ? keyStyle
                                              : cellStyle,
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    // the filter field over the list (near the dialog's top: the soft
    // keyboard it opens must not cover the list it narrows); on while
    // busy, it is the client's alone
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
          child: TextField(
            key: const ValueKey('f4-hit-filter'),
            controller: _filter,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.filter_list),
              labelText: 'Filter ${all.length} hits',
              suffixText: q.isEmpty
                  ? null
                  : '${visible.length} of ${all.length}',
              suffixIcon: q.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(_filter.clear),
                    ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(child: table),
      ],
    );
  }
}
