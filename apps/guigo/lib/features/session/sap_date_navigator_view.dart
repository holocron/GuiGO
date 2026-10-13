import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

import 'session_busy.dart';

/// A server-hosted date NAVIGATOR (SAP.CalendarControl.1 in its horizontal
/// display style — [SapCalendarModel.horizontal]: /AIF/IFMON's lower-left
/// pane) drawn as the real control draws it: the months side by side, each
/// a block of week COLUMNS under its `YYYY/M` header, the week numbers in a
/// row across the top, the weekdays as ROWS down the left (the server's
/// DayNames, `LU` … `DI`), scrolled sideways over the months the control
/// holds. The weekend rows (InitViewers #10) italic blue on grey, the
/// server's selection (its `Selection`) orange, the server's today framed
/// red and bold, the days the server marks (DayInfo) boxed in their colour
/// with their text as the tooltip.
///
/// A tap is the control's date-selected event ([onPick] → SapSession.
/// pickCalendarDate, `%_GC <shell> 3` with (from, to, 0) — the jar's
/// SapCalendar.valueChanged → fireDateSelected): a day picks that day; with
/// the week / month selection styles a week number picks its week, a month
/// header its month; with the interval style a long press extends the
/// selection from the last day picked (the desktop's shift-click). The
/// picked interval shows at once (the control selects before it fires);
/// the server's next Selection replaces it.
class SapDateNavigatorView extends StatefulWidget {
  const SapDateNavigatorView({
    super.key,
    required this.calendar,
    required this.onPick,
    this.busy = false,
  });

  final SapCalendarModel calendar;
  final void Function(DateTime from, DateTime to) onPick;
  final bool busy;

  /// The months held each side of the focus month (the SAP GUI for
  /// Windows' held interval, [calendarHeldInterval]: focus ± 7).
  static const int heldMonths = 7;

  /// The week-number row's label in the logon language of the DayNames
  /// push (the control's own resource text, not on the wire; the jar's is
  /// `WN`).
  static String weekLabel(String language) => switch (language.toUpperCase()) {
    'F' => 'NS',
    'D' => 'KW',
    'S' => 'Sm',
    'I' => 'Set',
    _ => 'WN',
  };

  /// The boxed colours 1 … 8 of DayInfo: (fill, outline). The OCX's own
  /// palette is not on the wire; the hues follow the jar's Belize set
  /// (`calendarColorFill<n>` / `calendarColorOutline<n>`) arranged so that
  /// /AIF/IFMON's meanings read as on the desktop — 2 "sans erreur" green,
  /// 4 "avertissement" amber, 6 "erreur" red.
  static const Map<int, (Color, Color)> markColors = {
    1: (Color(0xFFC9DEFF), Color(0xFF678BC7)),
    2: (Color(0xFFD9E8B0), Color(0xFF759421)),
    3: (Color(0xFFB3E5FC), Color(0xFF0092D1)),
    4: (Color(0xFFFFE9B5), Color(0xFFE09D00)),
    5: (Color(0xFFF7CBEE), Color(0xFFAB218E)),
    6: (Color(0xFFFAB4B4), Color(0xFFC14646)),
    7: (Color(0xFFD3F2F2), Color(0xFF1A9898)),
    8: (Color(0xFFFFCAA8), Color(0xFFE6600D)),
  };

  @override
  State<SapDateNavigatorView> createState() => _SapDateNavigatorViewState();
}

/// The colours of the navigator in the current theme.
class _NavColors {
  _NavColors(BuildContext context)
    : dark = Theme.of(context).brightness == Brightness.dark,
      scheme = Theme.of(context).colorScheme;

  final bool dark;
  final ColorScheme scheme;

  Color get text => scheme.onSurface;
  Color get label => scheme.onSurfaceVariant;
  Color get headerBack => dark ? const Color(0xFF263238) : const Color(0xFFDCE6F0);
  Color get weekendBack => dark ? const Color(0xFF2C3036) : const Color(0xFFE8E8E8);
  Color get weekendText => dark ? const Color(0xFF8AB4F8) : const Color(0xFF1F4FB4);
  Color get selection => dark ? const Color(0xFFB8620A) : const Color(0xFFFFB74D);
  Color get selectionText => dark ? Colors.white : Colors.black;
  Color get today => dark ? const Color(0xFFFF6B6B) : const Color(0xFFD32F2F);
  Color get grid => scheme.outlineVariant;

  (Color, Color)? mark(int color) {
    final c = SapDateNavigatorView.markColors[color];
    if (c == null) return null;
    // dark: the fill dimmed onto the surface, the outline as is
    return dark ? (c.$2.withValues(alpha: 0.30), c.$2) : c;
  }
}

class _SapDateNavigatorViewState extends State<SapDateNavigatorView> {
  final ScrollController _scroll = ScrollController();

  /// The interval picked here and not yet answered by a new Selection.
  (DateTime, DateTime)? _picked;

  /// The day the last tap picked: the anchor a long press extends from.
  DateTime? _anchor;

  /// The cell width the scroll position was placed for (null: not yet).
  double? _placedFor;

  SapCalendarModel get _c => widget.calendar;

  @override
  void didUpdateWidget(SapDateNavigatorView old) {
    super.didUpdateWidget(old);
    final a = old.calendar, b = widget.calendar;
    if (a.selectionFrom != b.selectionFrom || a.selectionTo != b.selectionTo) {
      // the server's Selection replaces what was picked here
      _picked = null;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  /// The month the view opens on: the selection's, else the focus.
  DateTime get _focusMonth {
    final d = _c.selectionFrom ?? _c.focus ?? _c.today ?? DateTime.now();
    return DateTime(d.year, d.month);
  }

  /// The months held: focus ± [SapDateNavigatorView.heldMonths], stretched
  /// over the selection and today.
  List<DateTime> get _months {
    final f = _focusMonth;
    var first = DateTime(f.year, f.month - SapDateNavigatorView.heldMonths);
    var last = DateTime(f.year, f.month + SapDateNavigatorView.heldMonths);
    for (final d in [?_c.selectionFrom, ?_c.selectionTo, ?_c.today]) {
      final m = DateTime(d.year, d.month);
      if (m.isBefore(first)) first = m;
      if (m.isAfter(last)) last = m;
    }
    return [
      for (var m = first; !m.isAfter(last); m = DateTime(m.year, m.month + 1))
        m,
    ];
  }

  /// The first days of the weeks a month's block shows (a week straddling
  /// two months shows in both, its other month's days blank).
  List<DateTime> _weeksOf(DateTime month) {
    final last = DateTime(month.year, month.month + 1, 0);
    final out = <DateTime>[];
    for (
      var w = calendarWeekStart(month, _c.firstDayOfWeek);
      !w.isAfter(last);
      w = DateTime(w.year, w.month, w.day + 7)
    ) {
      out.add(w);
    }
    return out;
  }

  bool _selected(DateTime d) {
    final p = _picked;
    if (p != null) return !d.isBefore(p.$1) && !d.isAfter(p.$2);
    return _c.inSelection(d);
  }

  void _pick(DateTime from, DateTime to) {
    if (_busy) return;
    final a = _day(from), b = _day(to);
    final (lo, hi) = b.isBefore(a) ? (b, a) : (a, b);
    setState(() => _picked = (lo, hi));
    widget.onPick(lo, hi);
  }

  void _tapDay(DateTime d) {
    _anchor = d;
    _pick(d, d);
  }

  void _extendTo(DateTime d) {
    if (_c.rangeMode != true) return _tapDay(d);
    final from = _anchor ?? _c.selectionFrom ?? d;
    _pick(from, d);
  }

  /// Busy as the last build drew it: the view's flag or the session's
  /// ([SessionBusy], depended on in [build]).
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    _busy = widget.busy || SessionBusy.of(context);
    final colors = _NavColors(context);
    final months = _months;
    return LayoutBuilder(
      builder: (context, box) {
        // a header row, the week-number row and 7 weekday rows over the
        // scroll bar
        const bar = 10.0;
        final h = box.maxHeight.isFinite ? box.maxHeight : 260.0;
        final cellH = ((h - bar) / 9).clamp(12.0, 30.0);
        final cellW = (cellH * 1.3).clamp(18.0, 40.0);
        final font = (cellH * 0.55).clamp(8.0, 15.0);
        final widths = [
          for (final m in months) _weeksOf(m).length * cellW + 1,
        ];
        _place(months, widths, cellW);
        final weekdays = [
          for (var i = 0; i < 7; i++) (_c.firstDayOfWeek - 1 + i) % 7 + 1,
        ];
        final labelW = (font * 2.6).clamp(22.0, 44.0);
        Widget label(String t, {bool weekend = false}) => Container(
          width: labelW,
          height: cellH,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 3),
          color: weekend ? colors.weekendBack : null,
          child: Text(
            t,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontSize: font,
              fontWeight: FontWeight.w600,
              fontStyle: weekend ? FontStyle.italic : null,
              color: weekend ? colors.weekendText : colors.label,
            ),
          ),
        );
        return Semantics(
          label: 'Date navigator ${_c.shell}',
          child: AbsorbPointer(
            absorbing: _busy,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: labelW, height: cellH),
                    if (_c.showWeekNumbers)
                      label(SapDateNavigatorView.weekLabel(_c.language)),
                    for (final wd in weekdays)
                      label(_c.weekdayShort(wd), weekend: _c.weekends.contains(wd)),
                  ],
                ),
                Expanded(
                  child: Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: ListView.builder(
                      key: ValueKey('navigator-${_c.shell}'),
                      controller: _scroll,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(bottom: bar),
                      itemCount: months.length,
                      itemExtentBuilder: (i, _) =>
                          i < widths.length ? widths[i] : null,
                      itemBuilder: (context, i) => _month(
                        months[i],
                        weekdays,
                        cellW,
                        cellH,
                        font,
                        colors,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Put the scroll position on the focus month once per cell size (the
  /// first layout, a new region size).
  void _place(List<DateTime> months, List<double> widths, double cellW) {
    if (_placedFor == cellW) return;
    _placedFor = cellW;
    final f = _focusMonth;
    var offset = 0.0;
    for (var i = 0; i < months.length; i++) {
      if (months[i] == f) break;
      offset += widths[i];
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(offset.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  Widget _month(
    DateTime month,
    List<int> weekdays,
    double cellW,
    double cellH,
    double font,
    _NavColors colors,
  ) {
    final weeks = _weeksOf(month);
    final today = _c.today == null ? null : _day(_c.today!);
    final first = month;
    final last = DateTime(month.year, month.month + 1, 0);
    Widget header = Container(
      key: ValueKey('navmonth-${calendarWireDate(month).substring(0, 6)}'),
      height: cellH,
      width: weeks.length * cellW,
      alignment: Alignment.center,
      color: colors.headerBack,
      child: Text(
        '${month.year}/${month.month}',
        style: TextStyle(
          fontSize: font,
          fontWeight: FontWeight.w600,
          color: colors.text,
        ),
      ),
    );
    if (_c.selectsMonths) {
      header = GestureDetector(
        onTap: () => _pick(first, last),
        child: header,
      );
    }
    Widget weekCell(DateTime w) {
      // the number of the week as the month block shows it (its first day
      // inside the month decides — a straddling week shows in both)
      final inMonth = w.isBefore(first) ? first : w;
      final n = _c.weekNumber(inMonth);
      Widget cell = Container(
        key: ValueKey('navweek-${calendarWireDate(w)}-${month.month}'),
        width: cellW,
        height: cellH,
        alignment: Alignment.center,
        child: Text(
          '$n',
          style: TextStyle(fontSize: font * 0.9, color: colors.label),
        ),
      );
      if (_c.selectsWeeks) {
        cell = GestureDetector(
          onTap: () => _pick(w, DateTime(w.year, w.month, w.day + 6)),
          child: cell,
        );
      }
      return cell;
    }

    Widget dayCell(DateTime d, bool weekendRow) {
      final inMonth = !d.isBefore(first) && !d.isAfter(last);
      final back = weekendRow ? colors.weekendBack : null;
      if (!inMonth) {
        return Container(width: cellW, height: cellH, color: back);
      }
      final sel = _selected(d);
      final isToday = today != null && d == today;
      final info = _c.dayInfoOf(d);
      final mark = info != null && info.boxed ? colors.mark(info.color) : null;
      final textColor = sel
          ? colors.selectionText
          : weekendRow
          ? colors.weekendText
          : colors.text;
      Widget cell = Container(
        key: ValueKey('navday-${calendarWireDate(d)}'),
        width: cellW,
        height: cellH,
        color: sel ? colors.selection : back,
        padding: const EdgeInsets.all(1),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: sel ? null : mark?.$1,
            border: isToday
                ? Border.all(color: colors.today, width: 2)
                : mark == null
                ? null
                : Border.all(color: mark.$2, width: 1.2),
          ),
          child: Text(
            '${d.day}',
            style: TextStyle(
              fontSize: font,
              color: textColor,
              fontStyle: weekendRow ? FontStyle.italic : null,
              fontWeight: isToday ? FontWeight.w800 : null,
            ),
          ),
        ),
      );
      if (info != null && info.text.isNotEmpty) {
        cell = Tooltip(message: info.text, child: cell);
      }
      return GestureDetector(
        onTap: () => _tapDay(d),
        onLongPress: () => _extendTo(d),
        child: cell,
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: colors.grid, width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          if (_c.showWeekNumbers)
            Row(children: [for (final w in weeks) weekCell(w)]),
          for (var r = 0; r < 7; r++)
            Row(
              children: [
                for (final w in weeks)
                  dayCell(
                    DateTime(w.year, w.month, w.day + r),
                    _c.weekends.contains(weekdays[r]),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
