/// The calendar cells of a GFW time axis header (Graphitti's two-level
/// header: months over reporting intervals on the milestone trend
/// analysis, days over reporting intervals on the time axis chart).
///
/// Times are days since 1970-01-01 (UTC), as the chart model carries them.
/// A reporting interval ("RI n") is the ISO-8601 calendar week n: the time
/// axis' RI 1 spans Mon 29.12.1997 – Sun 04.01.1998 (ISO week 1 of 1998)
/// and the MTA's RI 1 … 17 the weeks of January – April 1998. The
/// customizing sends no interval unit (CL_CU_SCALE CO_INTERVAL_AUTO 'X'):
/// the week is Graphitti's own automatic unit for a days-wide axis; both
/// recorded axes start in ISO week 1, so "ISO week" and "week counted from
/// the axis start" read alike there.
library;

/// One header cell: the span [from, to) in days and its label.
class CalCell {
  const CalCell(this.from, this.to, this.label, [this.short = '']);
  final double from, to;

  /// The label; [short] the abbreviation drawn when [label] does not fit.
  final String label, short;

  @override
  bool operator ==(Object other) =>
      other is CalCell &&
      other.from == from &&
      other.to == to &&
      other.label == label;

  @override
  int get hashCode => Object.hash(from, to, label);

  @override
  String toString() => 'CalCell($from..$to "$label")';
}

DateTime _date(double days) => DateTime.fromMillisecondsSinceEpoch(
  (days * Duration.millisecondsPerDay).round(),
  isUtc: true,
);

double _days(DateTime d) =>
    d.millisecondsSinceEpoch / Duration.millisecondsPerDay;

/// The day number of [days]' midnight.
double dayFloor(double days) => days.floorToDouble();

/// The Monday (00:00) of the ISO week holding [days].
double weekStart(double days) {
  final d = dayFloor(days);
  final wd = _date(d).weekday; // 1 = Monday
  return d - (wd - 1);
}

/// The ISO-8601 week number of [d].
int isoWeek(DateTime d) {
  final day = DateTime.utc(d.year, d.month, d.day);
  final thursday = day.add(Duration(days: 4 - day.weekday));
  final jan1 = DateTime.utc(thursday.year, 1, 1);
  return 1 + thursday.difference(jan1).inDays ~/ 7;
}

const Map<String, List<String>> _months = {
  'F': ['Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin', 'Juillet',
      'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre'],
  'D': ['Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli',
      'August', 'September', 'Oktober', 'November', 'Dezember'],
  'E': ['January', 'February', 'March', 'April', 'May', 'June', 'July',
      'August', 'September', 'October', 'November', 'December'],
};

const Map<String, List<String>> _monthsShort = {
  'F': ['Janv.', 'Fév.', 'Mars', 'Avr.', 'Mai', 'Juin', 'Juil.', 'Août',
      'Sept.', 'Oct.', 'Nov.', 'Déc.'],
  'D': ['Jan.', 'Feb.', 'März', 'Apr.', 'Mai', 'Juni', 'Juli', 'Aug.',
      'Sep.', 'Okt.', 'Nov.', 'Dez.'],
  'E': ['Jan.', 'Feb.', 'Mar.', 'Apr.', 'May', 'June', 'July', 'Aug.',
      'Sep.', 'Oct.', 'Nov.', 'Dec.'],
};

/// The name of [month] (1–12) in the logon language [language] (the
/// adapter's SetLanguage: sy-langu 'F' / 'D' / 'E'; others read English).
String monthName(int month, String language, {bool short = false}) {
  final l = language.trim().toUpperCase();
  final t = (short ? _monthsShort : _months)[l] ??
      (short ? _monthsShort : _months)['E']!;
  return t[(month - 1) % 12];
}

/// The month cells of [from, to), clipped to the range.
List<CalCell> monthCells(double from, double to, String language) {
  final out = <CalCell>[];
  var d = _date(from);
  var m = DateTime.utc(d.year, d.month);
  while (_days(m) < to) {
    final next = DateTime.utc(m.year, m.month + 1);
    final a = _days(m) < from ? from : _days(m);
    final b = _days(next) > to ? to : _days(next);
    if (b > a) {
      out.add(CalCell(a, b, monthName(m.month, language),
          monthName(m.month, language, short: true)));
    }
    m = next;
  }
  return out;
}

/// The reporting-interval (ISO week) cells of [from, to), clipped:
/// `RI <week>`.
List<CalCell> weekCells(double from, double to) {
  final out = <CalCell>[];
  var w = weekStart(from);
  while (w < to) {
    final a = w < from ? from : w, b = w + 7 > to ? to : w + 7;
    if (b > a) out.add(CalCell(a, b, 'RI ${isoWeek(_date(w))}'));
    w += 7;
  }
  return out;
}

/// Day ticks of [from, to) every [every] days from [from]'s midnight:
/// `dd.mm`.
List<CalCell> dayCells(double from, double to, int every) {
  final out = <CalCell>[];
  String two(int v) => v.toString().padLeft(2, '0');
  for (var d = dayFloor(from); d < to; d += every) {
    final t = _date(d);
    out.add(CalCell(d, d + every, '${two(t.day)}.${two(t.month)}'));
  }
  return out;
}

/// The milestone trend analysis' time range: whole ISO weeks from the
/// Monday of the earliest date to the end of the week of the latest.
(double, double) mtaRange(double lo, double hi) {
  final a = weekStart(lo);
  var b = weekStart(hi) + 7;
  if (b <= a) b = a + 7;
  return (a, b);
}

/// Every how many cells a label of [labelWidth] fits into cells of
/// [cellWidth] (at least 1): the MTA's 'RI 1, RI 3, …', the time axis'
/// day label every 4 days.
int labelEvery(double labelWidth, double cellWidth) {
  if (cellWidth <= 0) return 1 << 20;
  var k = 1;
  while (k * cellWidth < labelWidth + 4 && k < 1 << 20) {
    k++;
  }
  return k;
}
