import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/sap_icons.dart';
import 'dynpro_view.dart' show SapIconAtlasStrip, iconQuickInfo, sapIconText;

/// An ALV grid control (the SE16 result list, …) as a spreadsheet: sticky
/// column headings, the rows below, horizontal scrolling across the
/// columns and vertical scrolling down the rows — SAP GUI's grid shape.
/// Column widths follow the field catalog's display widths when known,
/// else the longest of heading and values (in character cells).
class SapGridView extends StatefulWidget {
  const SapGridView({
    super.key,
    required this.columns,
    required this.titles,
    required this.widths,
    required this.rows,
    this.totalRows,
    this.onColumnsSelected,
    this.onRowsSelected,
    this.onColumnAction,
    this.rowCount,
    this.rowAt,
    this.onNeedRows,
    this.onCellValueHelp,
    this.onCellDoubleTap,
    this.hotspotColumns = const {},
    this.hotspotCells = const {},
    this.onHotspotTap,
    this.modifiedCells = const {},
  });

  final List<String> columns;
  final List<String> titles;
  final List<int> widths;
  final List<List<String>> rows;
  final int? totalRows;

  /// The selected column ids changed (a header tap toggles its column,
  /// like SAP GUI's header click; the server reads the selection with
  /// the next key — sort, filter, …).
  final void Function(List<String> columnIds)? onColumnsSelected;

  /// The selected rows changed (1-based grid lines; a row-number tap
  /// toggles it, the row selector of SAP GUI).
  final void Function(List<int> rows)? onRowsSelected;

  /// A column header's menu (long press): 'sortAsc', 'sortDesc' or
  /// 'filter' on that column — the column is selected first.
  final void Function(String action, String columnId)? onColumnAction;

  /// A grid larger than its loaded rows (the server pushes the first
  /// block, the client fetches the rest as it scrolls): [rowCount] lines
  /// in all, [rowAt] (0-based) null for a line not loaded yet, and
  /// [onNeedRows] asked — once the scrolling settles — for the first
  /// missing line on screen (1-based) with the first visible line; it
  /// answers false when it could not run (the session was busy) and is
  /// asked again shortly.
  final int? rowCount;
  final List<String>? Function(int index)? rowAt;
  final Future<bool> Function(int line, int firstVisible)? onNeedRows;

  /// Value help (F4) on a cell (a long press on it): the 1-based line and
  /// the column id — the server opens the field's search help.
  final void Function(int line, String columnId)? onCellValueHelp;

  /// A double tap on a data cell: the 1-based line and the column id —
  /// SAP GUI's double-click on an ALV cell (the ST22 hit list opens the
  /// dump, SE16 the record). A single tap still toggles the row.
  final void Function(int line, String columnId)? onCellDoubleTap;

  /// The columns whose cells are hotspots (drawn as links): a single tap
  /// on one fires [onHotspotTap] instead of toggling the row.
  final Set<String> hotspotColumns;

  /// Single hotspot CELLS beyond [hotspotColumns] (1-based line -> column
  /// ids): the cell style the server set one by one — the DBA cockpit's
  /// KPI checkboxes (SapGridModel.hotspotCells).
  final Map<int, Set<String>> hotspotCells;
  final void Function(int line, String columnId)? onHotspotTap;

  /// Cells the server changed and the client adopted but not yet
  /// committed (1-based line -> column id -> value), drawn marked.
  final Map<int, Map<String, String>> modifiedCells;

  @override
  State<SapGridView> createState() => _SapGridViewState();
}

/// Each column's width in character cells.
List<int> gridColumnCells(
  List<String> columns,
  List<String> titles,
  List<int> widths,
  List<List<String>> rows,
) {
  return [
    for (var i = 0; i < columns.length; i++)
      () {
        final head = i < titles.length && titles[i].trim().isNotEmpty
            ? titles[i].trim()
            : columns[i];
        var n = i < widths.length && widths[i] > 0 ? widths[i] : 0;
        if (n == 0) {
          for (final r in rows) {
            if (i < r.length) n = math.max(n, r[i].trimRight().length);
          }
        }
        return math.max(n, head.length).clamp(3, 40);
      }(),
  ];
}

bool _sameList<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// [gridColumnCells], kept up to date incrementally: the rows a grid
/// fetches as it scrolls (a 40-line window at a time) are measured once —
/// a re-push with the same catalog only measures the lines it added. The
/// session rebuilds its grid model on every read (new row lists around the
/// same cell strings), so a row counts as unchanged while its cells are the
/// same strings; any other change re-measures everything, so the result is
/// always exactly [gridColumnCells]'s.
/// The character cells a grid value takes: an icon token (`@29\QExclure
/// le modèle@`, the option grid's ICON column of SAPLALDB/0651) is its
/// glyph — two cells — not its wire text.
int gridCellChars(String v) {
  final t = v.trimRight();
  if (!t.contains('@')) return t.length;
  return t.replaceAll(SapIconAtlas.tokenRx, '  ').length;
}

class GridColumnCells {
  List<String> _columns = const [], _titles = const [];
  List<int> _widths = const [];
  List<List<String>> _rows = const [];

  /// Per column: the longest trimmed value over [_rows] (only for the
  /// columns without a catalog width), else null.
  List<int?> _longest = const [];
  List<int> _cells = const [];

  /// How many rows the last update measured (tests read it).
  int measured = 0;

  List<int> cellsFor(
    List<String> columns,
    List<String> titles,
    List<int> widths,
    List<List<String>> rows,
  ) {
    measured = 0;
    final sameCatalog =
        _sameList(columns, _columns) &&
        _sameList(titles, _titles) &&
        _sameList(widths, _widths);
    if (sameCatalog && identical(rows, _rows)) return _cells;
    final scan = [
      for (var i = 0; i < columns.length; i++)
        if (!(i < widths.length && widths[i] > 0)) i,
    ];
    var from = 0;
    if (sameCatalog && rows.length >= _rows.length) {
      // the rows already measured must be the same cells
      from = _rows.length;
      for (var r = 0; r < _rows.length && from == _rows.length; r++) {
        final a = _rows[r], b = rows[r];
        if (identical(a, b)) continue;
        for (final i in scan) {
          final x = i < a.length ? a[i] : null, y = i < b.length ? b[i] : null;
          if (!identical(x, y) && x != y) {
            from = 0;
            break;
          }
        }
      }
    }
    final longest = from == 0
        ? List<int?>.filled(columns.length, null)
        : List<int?>.of(_longest);
    for (final i in scan) {
      longest[i] ??= 0;
    }
    for (var r = scan.isEmpty ? rows.length : from; r < rows.length; r++) {
      final row = rows[r];
      measured++;
      for (final i in scan) {
        if (i < row.length) {
          final n = gridCellChars(row[i]);
          if (n > longest[i]!) longest[i] = n;
        }
      }
    }
    _columns = columns;
    _titles = titles;
    _widths = widths;
    _rows = rows;
    _longest = longest;
    _cells = [
      for (var i = 0; i < columns.length; i++)
        () {
          final head = i < titles.length && titles[i].trim().isNotEmpty
              ? titles[i].trim()
              : columns[i];
          var n = i < widths.length && widths[i] > 0 ? widths[i] : 0;
          if (n == 0) n = longest[i] ?? 0;
          return math.max(n, head.length).clamp(3, 40);
        }(),
    ];
    return _cells;
  }
}

class _SapGridViewState extends State<SapGridView> {
  final _cellTracker = GridColumnCells();
  final _h = ScrollController();
  final Set<int> _rows = {}; // selected row indexes (0-based)
  final Set<int> _cols = {}; // selected column indexes
  final Set<int> _asked = {}; // first lines of the windows fetched (1-based)
  static const int _window = 40; // lines one fetch asks for
  final _v = ScrollController();
  Timer? _settle;

  /// Column virtualization: only the columns near the horizontal viewport
  /// are built (MARA has 309 — building every cell of every row made the
  /// list crawl); the range moves with the horizontal scroll.
  double _viewW = 1000;
  (int, int) _colRange = (0, 0);
  List<double> _lefts = const []; // each column's left edge (content x)
  List<double> _widthsCache = const [];
  Object? _cellsKey;
  List<int>? _cellsOf; // the cells [_widthsCache] / [_lefts] derive from

  (int, int) _visibleColumns() {
    final n = _lefts.length;
    if (n == 0) return (0, 0);
    final x = _h.hasClients ? _h.offset : 0.0;
    final lo = x - _viewW, hi = x + 2 * _viewW; // a viewport of margin
    var a = 0;
    while (a < n - 1 && _lefts[a] + _widthsCache[a] < lo) {
      a++;
    }
    var b = a;
    while (b < n - 1 && _lefts[b + 1] < hi) {
      b++;
    }
    return (a, b + 1);
  }

  void _onHScroll() {
    final r = _visibleColumns();
    if (r != _colRange) setState(() => _colRange = r);
  }

  bool _fetching = false;

  /// A missing line was built: fetch what is on screen once the scrolling
  /// pauses (never from inside build) — a fling past hundreds of lines asks
  /// for the lines it stops on, not every window it crossed.
  void _need(int index, int firstVisible) {
    if (widget.onNeedRows == null) return;
    _schedule(const Duration(milliseconds: 150));
  }

  void _schedule(Duration after) {
    _settle?.cancel();
    _settle = Timer(after, _fetchVisible);
  }

  bool _covered(int line) => _asked.any((a) => line >= a && line < a + _window);

  Future<void> _fetchVisible() async {
    final ask = widget.onNeedRows, rowAt = widget.rowAt;
    if (!mounted || ask == null || rowAt == null || _fetching) return;
    final total = widget.rowCount ?? widget.rows.length;
    var first = 0, count = 12;
    if (_v.hasClients) {
      final pos = _v.position;
      first = (pos.pixels / _rowH).floor().clamp(0, total);
      count = (pos.viewportDimension / _rowH).ceil() + 1;
    }
    // the screen first, then one window ahead of it (prefetched while the
    // user reads, so a steady scroll finds its lines loaded)
    int? line;
    for (var i = first; i < math.min(total, first + count + _window); i++) {
      if (rowAt(i) == null && !_covered(i + 1)) {
        line = i + 1;
        break;
      }
    }
    if (line == null) return;
    _fetching = true;
    bool ran;
    try {
      ran = await ask(line, first + 1);
    } catch (_) {
      ran = true; // the session reported it; do not hammer the line
    } finally {
      _fetching = false;
    }
    if (!mounted) return;
    if (!ran) {
      _schedule(const Duration(milliseconds: 400)); // busy: try again
      return;
    }
    _asked.add(line);
    setState(() {});
    _schedule(Duration.zero); // more of the screen may still be missing
  }

  @override
  void dispose() {
    _settle?.cancel();
    _v.dispose();
    _h.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _h.addListener(_onHScroll);
  }

  @override
  void didUpdateWidget(SapGridView old) {
    super.didUpdateWidget(old);
    // a re-push (sort, filter, refresh) may drop lines: ask again then
    if (!identical(old.rowAt, widget.rowAt) && widget.rowAt != null) {
      _asked.removeWhere((l) => widget.rowAt!(l - 1) != null);
    }
  }

  void _toggleColumn(int i) {
    setState(() => _cols.contains(i) ? _cols.remove(i) : _cols.add(i));
    widget.onColumnsSelected?.call([
      for (final c in (_cols.toList()..sort())) widget.columns[c],
    ]);
  }

  /// Whether cell ([r] 0-based row, column [i]) is a hotspot.
  bool _isHotspot(int r, int i) =>
      widget.onHotspotTap != null &&
      (widget.hotspotColumns.contains(widget.columns[i]) ||
          (widget.hotspotCells[r + 1]?.contains(widget.columns[i]) ??
              false));

  void _toggleRow(int r) {
    setState(() => _rows.contains(r) ? _rows.remove(r) : _rows.add(r));
    widget.onRowsSelected?.call([
      for (final x in (_rows.toList()..sort())) x + 1,
    ]);
  }

  Future<void> _cellMenu(int r, int i, Offset at) async {
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: const [PopupMenuItem(value: 'f4', child: Text('Value help (F4)'))],
    );
    if (action == 'f4') widget.onCellValueHelp?.call(r + 1, widget.columns[i]);
  }

  Future<void> _columnMenu(int i, Offset at) async {
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: const [
        PopupMenuItem(
          value: 'sortAsc',
          child: Text('Sort ascending'),
        ),
        PopupMenuItem(
          value: 'sortDesc',
          child: Text('Sort descending'),
        ),
        PopupMenuItem(value: 'filter', child: Text('Filter')),
      ],
    );
    if (action == null) return;
    // the action works on the selected column, as in SAP GUI
    if (!_cols.contains(i)) {
      setState(() {
        _cols
          ..clear()
          ..add(i);
      });
      widget.onColumnsSelected?.call([widget.columns[i]]);
    }
    widget.onColumnAction?.call(action, widget.columns[i]);
  }

  static const double _cw = 8.6; // points per character cell
  static const double _rowH = 30;
  static const double _numW = 44;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icons = SapIconAtlasStrip.of(context);
    // the column widths: measured once per pushed block, not per frame
    final key = (widget.columns, widget.titles, widget.widths, widget.rows);
    if (_cellsKey != key) {
      _cellsKey = key;
      final cells = _cellTracker.cellsFor(
        widget.columns,
        widget.titles,
        widget.widths,
        widget.rows,
      );
      if (!identical(cells, _cellsOf)) {
        _cellsOf = cells;
        _widthsCache = [for (final n in cells) n * _cw + 12];
        var x = _numW;
        _lefts = [for (final w in _widthsCache) (x += w) - w];
      }
      _colRange = _visibleColumns();
    }
    final widths = _widthsCache;
    final total = _numW + widths.fold<double>(0, (a, b) => a + b);
    final (c0, c1) = _colRange;
    // the space the unbuilt columns left of the range take
    final skip = c0 < _lefts.length ? _lefts[c0] - _numW : 0.0;
    const mono = TextStyle(
      fontFamily: 'Menlo',
      fontFamilyFallback: ['Courier New', 'monospace'],
      fontSize: 13,
    );

    // one rule and one decoration per fill for every cell of the build
    // (each cell allocated its own BoxDecoration, Border and BorderSide)
    final rule = Border(
      right: BorderSide(color: scheme.outlineVariant, width: 0.5),
    );
    final decorations = <Color?, BoxDecoration>{};
    final hotspotStyle = mono.copyWith(
      color: scheme.primary,
      decoration: TextDecoration.underline,
    );
    final numStyle = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
    final selectedFill = scheme.primaryContainer.withValues(alpha: 0.35);

    Widget cell(
      String text,
      double w, {
      TextStyle? style,
      Alignment align = Alignment.centerLeft,
      Color? fill,
    }) {
      return Container(
        width: w,
        height: _rowH,
        alignment: align,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: decorations[fill] ??= BoxDecoration(
          color: fill,
          border: rule,
        ),
        child: SapIconAtlas.tokenRx.hasMatch(text)
            // an icon cell: the glyph, its quick info the tooltip
            ? Tooltip(
                message: iconQuickInfo(text) ?? '',
                child: sapIconText(text, icons, style: style, clip: true),
              )
            : Text(
                text,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
      );
    }

    final header = Container(
      color: scheme.surfaceContainerHigh,
      child: Row(
        children: [
          cell('', _numW),
          if (skip > 0) SizedBox(width: skip),
          for (var i = c0; i < c1; i++)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _toggleColumn(i),
              onLongPressStart: widget.onColumnAction == null
                  ? null
                  : (d) => _columnMenu(i, d.globalPosition),
              child: Semantics(
                label: widget.columns[i],
                selected: _cols.contains(i),
                child: cell(
                  i < widget.titles.length && widget.titles[i].trim().isNotEmpty
                      ? widget.titles[i].trim()
                      : widget.columns[i],
                  widths[i],
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                  fill: _cols.contains(i) ? scheme.primaryContainer : null,
                ),
              ),
            ),
        ],
      ),
    );

    final count = widget.totalRows ?? widget.rowCount ?? widget.rows.length;
    return LayoutBuilder(
      builder: (context, cons) {
        if (cons.maxWidth.isFinite && cons.maxWidth != _viewW) {
          _viewW = cons.maxWidth;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _onHScroll();
          });
        }
        // a short pane (the DBA cockpit's 3-row message strip) keeps its
        // heading and rows, not the row-count line
        final roomy = !cons.maxHeight.isFinite || cons.maxHeight >= 120;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (roomy)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                child: Text(
                  '$count ${count == 1 ? 'row' : 'rows'} · ${widget.columns.length} columns',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
            Expanded(
              child: Scrollbar(
                controller: _h,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _h,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: total,
                    child: Column(
                      children: [
                        header,
                        Divider(height: 1, color: scheme.outline),
                        Expanded(
                          child: ListView.builder(
                            padding: const EdgeInsets.only(bottom: 96),
                            controller: _v,
                            itemCount: widget.rowCount ?? widget.rows.length,
                            itemExtent: _rowH,
                            itemBuilder: (context, r) {
                              final loaded = widget.rowAt != null
                                  ? widget.rowAt!(r)
                                  : (r < widget.rows.length
                                        ? widget.rows[r]
                                        : null);
                              if (loaded == null) {
                                _need(r, (r - 12).clamp(0, r));
                              }
                              final row = loaded ?? const <String>[];
                              final sel = _rows.contains(r);
                              final modified = widget.modifiedCells[r + 1];
                              return Material(
                                color: sel
                                    ? scheme.secondaryContainer
                                    : (r.isOdd
                                          ? scheme.surfaceContainerLow
                                          : scheme.surface),
                                child: InkWell(
                                  onTap: () => _toggleRow(r),
                                  child: Row(
                                    children: [
                                      cell(
                                        '${r + 1}',
                                        _numW,
                                        style: numStyle,
                                        align: Alignment.centerRight,
                                      ),
                                      if (skip > 0) SizedBox(width: skip),
                                      for (var i = c0; i < c1; i++)
                                        if (_isHotspot(r, i) case final hot)
                                        GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          // a hotspot cell's single tap is
                                          // its own (the inner detector
                                          // wins over the row's InkWell)
                                          onTap: loaded != null && hot
                                              ? () => widget.onHotspotTap!(
                                                  r + 1,
                                                  widget.columns[i],
                                                )
                                              : null,
                                          onDoubleTap:
                                              loaded == null ||
                                                  widget.onCellDoubleTap == null
                                              ? null
                                              : () => widget.onCellDoubleTap!(
                                                  r + 1,
                                                  widget.columns[i],
                                                ),
                                          onLongPressStart:
                                              widget.onCellValueHelp == null
                                              ? null
                                              : (d) => _cellMenu(
                                                  r,
                                                  i,
                                                  d.globalPosition,
                                                ),
                                          child: cell(
                                            i < row.length
                                                ? row[i].trimRight()
                                                : '',
                                            widths[i],
                                            style: hot ? hotspotStyle : mono,
                                            fill:
                                                modified?.containsKey(
                                                          widget.columns[i],
                                                        ) ==
                                                    true
                                                ? scheme.tertiaryContainer
                                                : _cols.contains(i)
                                                ? selectedFill
                                                : null,
                                          ),
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
              ),
            ),
          ],
        );
      },
    );
  }
}
