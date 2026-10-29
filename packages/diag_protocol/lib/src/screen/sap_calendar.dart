/// The calendar control a server hosts for F4 on a date (DATS) field — the
/// ActiveX `SAP.CalendarControl.1` (sapcalen.ocx) on the SAP GUI for
/// Windows, `com.sap.components.controls.calendar.SapCalendar` on the Java
/// GUI — read side; the pick is SapSession.pickCalendarDate
/// (sap_session_calendar.dart, frames: calendar_actions.dart). Port of the
/// reference client's reading of the control ( `Today`,
/// raw_grid_state.control_event; RECORDING_INDEX a recorded session).
///
/// Wire shape (real SAP GUI for Windows: a recorded session, the test system
/// 2026-09-15, ME9F → F4 on S_BEDAT-LOW / -HIGH, post-trim indices;
/// a recorded session, the test system 2026-09-07, /AIF/IFMON BT_SELECTDT):
/// * the CREATION queue (a recorded session srv[1], step 17): a
/// generic OLE2 `CreateObject` (the {83658045-…} helper), then
/// `CreateControl(115, SAPGUI.CONTAINERCTRL.1, …, 11)` — the host,
/// `LinkContainer(115, CONTAINER)` / `LinkControl(115, SAPLSCAC, 100)`
/// (the popup "Calendrier" SAPLSCAC/0100, painted at srv[4] with the
/// custom-control area CONTAINER at level 1, 12 x 42), RegisterCachedProp
/// 120 / 300 on it — and in the SAME queue
/// `CreateControl(116, SAP.CalendarControl.1, …, 115)` + SetProperty(116,
/// 10, 15), the tooltip host `CreateObject(SAPGUI.InfoCtrl.1)` and
/// GetGuiFeatures. (the reference client's DECODE §3 names the calendar's mint
/// "dialect (1) CreateObject"; the verbs as this port decodes them carry
/// it as a plain CreateControl hosted by 115 — either way it is the
/// ProgID row of that queue, and it is what this tracker keys on.)
/// * the SETUP queue (srv[2], step 19): two GuiDataProvider pushes on the
/// calendar — `SetDataFromUrl(…SAPR3://…)` then `AssignProperty2(<dp>,
/// r3TableAutoObj, <calendar>, DayNames)`: 7 rows LANG | NUMBER (1 =
/// Monday) | SHORT | LONG (`F 1 LU Lundi` … `F 7 DI Dimanche`); the same
/// for `MonthNames` (12 rows `F 01 JAN Janvier` …); then `Today =
/// 20260915` — the SERVER's date (the capture's own day) — and
/// `InitViewers(1027, 1, DD.MM.YYYY, 3, 20260915, 1, 1, 0, 0, '')`:
/// #01 the display style, #02 the selection style, #03 the user's date
/// format, #04 the months shown, #05 the date the field holds, #07 the
/// week rule, #10 the weekend days (sapCalendarS.jar SapCalendar.
/// initViewers; [SapCalendarModel]) — #05 empty on an empty field (the
/// AIF navigator: `InitViewers(1028, 15, DD.MM.YYYY, 3, '', 0, 1, 0, 0,
/// 67)`). InitViewers is a METHOD with a string `_RESULT` the front end
/// answers with the date interval the control holds,
/// `<first>,<last>` (YYYYMMDD) — [calendarHeldInterval]; the server
/// reads it back as the DATE_FROM / DATE_TO of the DayInfo it pushes
/// next. A blank answer aborts the transaction (SAPMSDYP "Le paramètre
/// DATE_FROM possède la valeur non valide ' . .'", the test system ME2N F4 on
/// S_BEDAT-LOW, live 2026-10-11; the reference client answers it blank too).
/// `CalcInterval` (no arguments, string `_RESULT`) asks the same after
/// the server assigned a `Selection` (a recorded session srv[101]
/// step 157 → gui[89] `20250526,20270502`);
/// * the EVENT queue (srv[3], step 21): `Today = <the #05 date>` again
/// (the test system srv: creation Today 20260907, InitViewers #05 20260824, then
/// Today 20260824 — the date the month view opens on),
/// RegisterOcxEvent(116, 3 / 7 / 8 / 4 / 522), the `DayInfo` push (3
/// columns; empty in every capture — the holidays when a factory
/// calendar is set);
/// * the PICK (gui[6], step 22): `%_GC 116 3` with PARAMs [from, to, "0"]
/// (YYYYMMDD; a single day sends it twice) — [calendarEventDateSelected];
/// * the TEARDOWN (srv[6], step 25): DestroyWindow(116), FreeObject,
/// DestroyWindow(115); then the calling screen repaints with the date in
/// its field (srv[7], step 26: RM06ENDR_ALV/1000).
///
/// The object token later queues name the calendar by is the frontend's own
/// mint for its CreateControl result (the session alias); a queue recorded
/// from another frontend names ITS mint — then the token is bound to the
/// newest calendar created without one (the verbs are the control's own).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../cfw/dp_cache.dart';
import '../cfw/flush_call.dart';
import '../cfw/tree_header_names.dart' show expandInlineRow;
import 'sap_tree.dart' show DpTable, decodeNamedDpTable;
import 'screen_model.dart' show ScreenField, FieldKind;

/// The calendar's ProgID (Windows) or bean class (Java GUI: the /AIF/IFMON
/// date restriction, a recorded session srv CreateControl 145).
final RegExp calendarClassRx = RegExp(
  r'^(?:SAP\.CalendarControl\.\d+|'
  r'com\.sap\.components\.controls\.calendar\.SapCalendar)$',
);

/// Whether [cls] names the calendar control.
bool isCalendarClass(String cls) => calendarClassRx.hasMatch(cls.trim());

/// The date-selected event (`%_GC <shell> 3`, PARAMs from, to, "0" —
/// a recorded session gui[6] / gui[11], a recorded session gui[45]
/// / gui[59], the Java a recorded session gui[51]). The other ids
/// the server registers (7, 8, 4, 522; srv[3]) never fire in a capture.
const int calendarEventDateSelected = 3;

/// The calendar's YYYYMMDD wire spelling of [d].
String calendarWireDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}'
    '${d.month.toString().padLeft(2, '0')}'
    '${d.day.toString().padLeft(2, '0')}';

/// [s] (YYYYMMDD) as a date, null when it is none (an empty #05, `0000…`).
DateTime? parseCalendarDate(String s) {
  final t = s.trim();
  if (!_parseCalendarDateRx.hasMatch(t) || t == '00000000') return null;
  final y = int.parse(t.substring(0, 4));
  final m = int.parse(t.substring(4, 6));
  final d = int.parse(t.substring(6, 8));
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  final dt = DateTime(y, m, d);
  return dt.month == m ? dt : null;
}

/// The date interval the calendar holds around [focus] — what the front end
/// answers to `InitViewers` / `CalcInterval` (both string `_RESULT`s,
/// `<first>,<last>` YYYYMMDD), stretched to cover [from] / [to] when given.
/// The rule is the [dialect]'s:
///
/// SAP GUI for Windows (SAP.CalendarControl.1, sapcalen.ocx; its typelib
/// is unreadable, the wire is the contract): the months [focus] − 7
/// through [focus] + 7, from the Monday on or before the first day of the
/// first month to the Sunday on or after the last day of the last month.
/// Pinned on every real-GUI answer on the wire:
/// * #05 20260915 (a recorded session srv[2] → gui[4]) and 20260907
/// (a recorded session srv[58] → gui[43]; a recorded session
/// srv[944] → gui[814]) → `20260126,20270502`;
/// * #05 20260504 (a recorded session srv[937] → gui[808]) →
/// `20250929,20270103`;
/// * #05 20260824 (a recorded session srv[50] → gui[43]) →
/// `20251229,20270404`;
/// * the AIF navigator's empty #05 under `Today 20260907` (the test system srv[18..20]
/// step 32 → gui[14]) → `20260126,20270502`;
/// * CalcInterval after `Selection` 18.06.2025 .. 18.06.2026 on that
/// navigator (the test system srv[101] → gui[89]) → `20250526,20270502`.
///
/// SAP GUI for Java (com.sap.components.controls.calendar.SapCalendar,
/// sapCalendarS.jar `calendar2.SapCalendar`): the months [focus] − 5
/// through [focus] + 5, from the first day of the first month to the last
/// day of the last month — no week padding. One oracle: a recorded session
/// calmark_java srv[27] → gui[21], #05 20260916 → `20260401,20270228`.
/// The jar's `initViewers(…)` returns `getCalcInterval` (bytecode: the
/// navigator's getStartDate + "," + getEndDate), so a later CalcInterval
/// answers the same held interval; a `Selection` goes through the
/// navigator's selectRange, which calls setCalendarInterval(from, to) —
/// the month stretch here (no Java CalcInterval is on the wire).
(DateTime, DateTime) calendarHeldInterval(
  DateTime focus, {
  DateTime? from,
  DateTime? to,
  GuiDialect dialect = GuiDialect.windows,
}) {
  final span = dialect == GuiDialect.java ? 5 : 7;
  return calendarStretch(
    (
      _monthBounds(DateTime(focus.year, focus.month - span), dialect).$1,
      _monthBounds(DateTime(focus.year, focus.month + span), dialect).$2,
    ),
    [?from, ?to],
    dialect: dialect,
  );
}

/// [interval] widened to cover the months of [dates], in the [dialect]'s
/// bounds of [calendarHeldInterval] (Windows: the Monday on or before the
/// month's first day .. the Sunday on or after its last; Java: the first ..
/// the last day).
(DateTime, DateTime) calendarStretch(
  (DateTime, DateTime) interval,
  Iterable<DateTime> dates, {
  GuiDialect dialect = GuiDialect.windows,
}) {
  var (first, last) = interval;
  for (final d in dates) {
    final (lo, hi) = _monthBounds(d, dialect);
    if (lo.isBefore(first)) first = lo;
    if (hi.isAfter(last)) last = hi;
  }
  return (first, last);
}

/// The first and last day the calendar shows for the month of [d].
(DateTime, DateTime) _monthBounds(DateTime d, GuiDialect dialect) {
  final first = DateTime(d.year, d.month);
  final last = DateTime(d.year, d.month + 1, 0);
  if (dialect == GuiDialect.java) return (first, last);
  return (
    // DateTime.weekday: 1 = Monday … 7 = Sunday (the DayNames order)
    DateTime(first.year, first.month, first.day - (first.weekday - 1)),
    DateTime(last.year, last.month, last.day + (7 - last.weekday)),
  );
}

/// [calendarHeldInterval] as the wire answer, `<first>,<last>` YYYYMMDD.
String calendarIntervalAnswer((DateTime, DateTime) interval) =>
    '${calendarWireDate(interval.$1)},${calendarWireDate(interval.$2)}';

/// Whether input field [f] shows a date: its painted text is a date in one
/// of the SAP user formats (DD.MM.YYYY, MM/DD/YYYY, MM-DD-YYYY,
/// YYYY.MM.DD, YYYY/MM/DD, YYYY-MM-DD). An EMPTY field gives no evidence
/// (its DDIC type is not on the wire).
bool fieldShowsDate(ScreenField f) {
  if (f.kind != FieldKind.input) return false;
  return _fieldShowsDateRx
      .hasMatch(f.text.trim());
}

/// One name of the DayNames / MonthNames pushes.
class SapCalendarName {
  const SapCalendarName(this.number, this.short, this.long);

  /// The NUMBER column: the weekday (1 = Monday … 7 = Sunday) or month.
  final int number;
  final String short;
  final String long;

  @override
  String toString() => 'SapCalendarName($number $short $long)';
}

/// One day the server marks — a `DayInfo` row with a date: the control's
/// colour [color] and its text (the tooltip; /AIF/IFMON: `2 erreur (550
/// tous)`, the day's message count). The push's table is (COLOR I4, DATE
/// C8, TEXT C30), one row per push, the pushes accumulating day by day
/// until `ResetDayInfo` (a recorded session raw srv[25..32] step 38:
/// 711 pushes, the last assigned by step 40; the Java a recorded session
/// sapevent step 45 the same; jar
/// sapCalendarS.jar SapCalendar.setDayInfo → CalDateNavigator.setDayInfo
/// per date). A row with NO date names a colour instead ([SapCalendarModel
/// .colorLegend]: the jar's mColorDayInfo).
class SapCalendarDay {
  const SapCalendarDay(this.date, this.color, this.text);

  final DateTime date;

  /// The colour id: 1 … 8 the control's boxed colours (a fill and an
  /// outline each — the jar's CalDateNavigator.setupColorMap, Belize
  /// `calendarColorFill<n>` / `calendarColorOutline<n>`); others draw no
  /// box.
  final int color;

  /// The day's text (trimmed), shown as its tooltip; '' for none.
  final String text;

  /// Whether the control draws the day boxed in [color].
  bool get boxed => color >= 1 && color <= 8;

  @override
  String toString() =>
      'SapCalendarDay(${calendarWireDate(date)} $color "$text")';
}

/// One calendar control the server hosts.
class SapCalendarModel {
  const SapCalendarModel({
    required this.shell,
    this.container,
    this.today,
    this.selected,
    this.focus,
    this.rangeMode,
    this.dateFormat = '',
    this.viewStyle,
    this.selectionStyle,
    this.displayMonths,
    this.firstDayOfWeek = DateTime.monday,
    this.weekends = const {},
    this.initViewers = const [],
    this.dayNames = const [],
    this.monthNames = const [],
    this.language = '',
    this.dayInfo = const [],
    this.colorLegend = const {},
    this.selectionFrom,
    this.selectionTo,
    this.events = const {},
    this.program,
  });

  /// The calendar's kernel shell (`116`) — what `%_GC <shell> 3` names.
  final String shell;

  /// The container hosting it (CreateControl #4: `115`, the
  /// SAPGUI.CONTAINERCTRL.1 LinkContainer'd into the popup's CONTAINER
  /// area). Its region is the area's ([SapSession.modalRegions]).
  final String? container;

  /// The server's date: the creation queue's `Today` (srv[2] `20260915`,
  /// the capture's own day) — what the control marks as today.
  final DateTime? today;

  /// The date the field holds (InitViewers #05), null on an empty field.
  final DateTime? selected;

  /// The date the month view opens on: the `Today` after InitViewers
  /// (srv[3]; the test system 20260824 = #05), else [selected], else [today].
  final DateTime? focus;

  /// Whether the control picks a RANGE (PID 0 = from, PID 1 = to differ):
  /// the selection style's interval bit ([selectionStyle] & 8 — the jar's
  /// CalDateNavigator.changeSelection extends the selection only then).
  /// Null when no InitViewers came. The F4 popups (style 1) pick one day
  /// (PID 0 == PID 1); /AIF/IFMON's navigator (15) a range.
  final bool? rangeMode;

  /// The user's date format (InitViewers #03: `DD.MM.YYYY`).
  final String dateFormat;

  /// InitViewers #01, the display style (sapCalendarS.jar SapCalendar.
  /// intInitViewers → CalDateNavigator(…, style, …)): bit 1 a date-picker
  /// field, 2 / 4 / 8 a navigator — 4 HORIZONTAL (the weekdays as rows,
  /// the weeks as columns, the months side by side), 512 no week numbers,
  /// 256 / 1024 the alignment, 2048 the weekend highlight, 4096
  /// simplified. 1027 on an F4 popup, 1028 on the /AIF/IFMON navigator.
  final int? viewStyle;

  /// InitViewers #02, the selection style: 1 a day, 2 a week (its number
  /// cell), 4 a month (its header), 8 an interval (CalDateNavigator.
  /// isWeekSelectionEnabled / isMonthSelectionEnabled / changeSelection).
  /// 1 on an F4 popup, 15 on the AIF navigator.
  final int? selectionStyle;

  /// InitViewers #04: the months shown at once (3 everywhere).
  final int? displayMonths;

  /// InitViewers #07's week rule as the first weekday ([DateTime.monday]
  /// … [DateTime.sunday]): 7 Sunday, 6 Saturday, else the ISO week
  /// (Monday; SapCalendar.getWeekInfo). The week numbers are ISO's under
  /// Monday, the Sunday / Saturday rule's (minimal days 1) otherwise.
  final int firstDayOfWeek;

  /// InitViewers #10: the weekend days ([DateTime.weekday] numbers; `67`
  /// = Saturday + Sunday on the AIF navigator, none on an F4 popup —
  /// CalDateNavigator.isWeekend reads the digits).
  final Set<int> weekends;

  /// Every InitViewers argument as the server sent it (#01 … #10).
  final List<String> initViewers;

  /// The pushed weekday names, Monday first (DayNames), and month names
  /// (MonthNames, January first) in the logon language.
  final List<SapCalendarName> dayNames;
  final List<SapCalendarName> monthNames;

  /// The DayNames push's LANG (`F`: the logon language), '' before it.
  final String language;

  /// The days the server marks ([SapCalendarDay], the DayInfo pushes so
  /// far, by date ascending).
  final List<SapCalendarDay> dayInfo;

  /// The DayInfo rows without a date: colour id -> its meaning.
  final Map<int, String> colorLegend;

  /// The interval the server's last `Selection` assigned: the rows of
  /// type 1 (from) and 2 (to); a single-row Selection is that day. Null
  /// before any (a recorded session raw srv[21]: 20260824 x 3; raw
  /// srv[101]: 18.06.2025 .. 18.06.2026).
  final DateTime? selectionFrom;
  final DateTime? selectionTo;

  /// The OCX events the server registered (RegisterOcxEvent: 3, 7, 8, 4,
  /// 522). Empty before the event queue.
  final Set<int> events;

  /// The program of the screen the calendar opened over.
  final String? program;

  /// Whether it shows as a horizontal date navigator ([viewStyle] bit 4:
  /// /AIF/IFMON's lower-left pane) rather than an F4 popup's month view.
  bool get horizontal => ((viewStyle ?? 0) & 4) != 0;

  /// Whether the week numbers are shown ([viewStyle] without bit 512).
  bool get showWeekNumbers => ((viewStyle ?? 0) & 512) == 0;

  /// Whether a week (its number cell) / a month (its header) can be picked.
  bool get selectsWeeks => ((selectionStyle ?? 0) & 2) != 0;
  bool get selectsMonths => ((selectionStyle ?? 0) & 4) != 0;

  /// Whether [d] is a weekend day of the control ([weekends]).
  bool isWeekend(DateTime d) => weekends.contains(d.weekday);

  /// The mark of [d], null when the server set none.
  SapCalendarDay? dayInfoOf(DateTime d) {
    final k = calendarWireDate(d);
    for (final x in dayInfo) {
      if (calendarWireDate(x.date) == k) return x;
    }
    return null;
  }

  /// Whether [d] lies in the assigned selection ([selectionFrom] ..
  /// [selectionTo]).
  bool inSelection(DateTime d) {
    final a = selectionFrom, b = selectionTo ?? selectionFrom;
    if (a == null || b == null) return false;
    final x = DateTime(d.year, d.month, d.day);
    return !x.isBefore(a) && !x.isAfter(b);
  }

  /// The short name of weekday [weekday] (1 = Monday): the pushed DayNames
  /// (`LU` … `DI`), else '' (no client-side locale is invented).
  String weekdayShort(int weekday) {
    for (final n in dayNames) {
      if (n.number == weekday) return n.short;
    }
    return '';
  }

  /// The week number of [d] under [firstDayOfWeek] (ISO under Monday).
  int weekNumber(DateTime d) => calendarWeekNumber(d, firstDayOfWeek);

  /// The day [d] as the field shows it, in [dateFormat] (DD.MM.YYYY when
  /// none was pushed).
  String formatDate(DateTime d) {
    final f = dateFormat.trim().isEmpty ? 'DD.MM.YYYY' : dateFormat.trim();
    return f
        .replaceAll('YYYY', d.year.toString().padLeft(4, '0'))
        .replaceAll('MM', d.month.toString().padLeft(2, '0'))
        .replaceAll('DD', d.day.toString().padLeft(2, '0'));
  }

  @override
  String toString() =>
      'SapCalendarModel($shell in $container, today ${_d(today)}, '
      'selected ${_d(selected)}, focus ${_d(focus)})';
}

/// The week number of [d] for weeks starting on [firstDay] (a
/// [DateTime.weekday]): ISO 8601 under Monday (the week holding the
/// year's first Thursday is 1 — java.time WeekFields.ISO); under Sunday /
/// Saturday the week holding January 1 is 1 (WeekFields.SUNDAY_START /
/// of(SATURDAY, 1), minimal days 1).
int calendarWeekNumber(DateTime d, int firstDay) {
  final day = DateTime.utc(d.year, d.month, d.day);
  if (firstDay == DateTime.monday) {
    // the Thursday of d's week decides the year
    final thu = day.add(Duration(days: DateTime.thursday - day.weekday));
    final jan1 = DateTime.utc(thu.year);
    return (thu.difference(jan1).inDays ~/ 7) + 1;
  }
  int offset(DateTime x) => (x.weekday - firstDay + 7) % 7;
  final jan1 = DateTime.utc(day.year);
  final start = jan1.subtract(Duration(days: offset(jan1)));
  return (day.difference(start).inDays ~/ 7) + 1;
}

/// The first day of the week holding [d] for weeks starting on [firstDay].
DateTime calendarWeekStart(DateTime d, int firstDay) {
  final x = DateTime(d.year, d.month, d.day);
  return DateTime(x.year, x.month, x.day - (x.weekday - firstDay + 7) % 7);
}

String _d(DateTime? d) => d == null ? '-' : calendarWireDate(d);

final RegExp _digits = RegExp(r'^\d{1,9}$');

class _Cal {
  _Cal(this.shell, this.container, this.seq, this.program, this.step);
  final String shell;
  final String? container;
  final int seq;

  /// The program the calendar opened over and the step it was created at
  /// (a screen's creation wave is folded under the program BEFORE it:
  /// [SapCalendarTracker.retag] moves it to the screen it built).
  String? program;
  final int step;

  /// The object token later queues name the control by.
  String? token;
  bool closed = false;
  bool initSeen = false;
  DateTime? today;
  DateTime? selected;
  DateTime? focus;
  String dateFormat = '';
  int? viewStyle;
  int? selectionStyle;
  int? displayMonths;
  int firstDayOfWeek = DateTime.monday;
  Set<int> weekends = const {};
  List<String> initViewers = const [];
  List<SapCalendarName> dayNames = const [];
  List<SapCalendarName> monthNames = const [];
  String language = '';

  /// The marked days by YYYYMMDD (DayInfo pushes accumulate per date until
  /// ResetDayInfo) and the dateless rows' colour meanings.
  final Map<String, SapCalendarDay> days = {};
  final Map<int, String> legend = {};
  final Set<int> events = {};

  /// The interval last answered to InitViewers / CalcInterval.
  (DateTime, DateTime)? held;

  /// The dates of the last `Selection` the server assigned.
  List<DateTime> selection = const [];

  /// That `Selection` push's DATAASC records, each at the table's width
  /// (the inline cells expanded).
  List<Uint8List> selectionRecords = const [];

  /// The model is rebuilt only after a fold touched the calendar (a
  /// navigator holds hundreds of marked days: every UI rebuild read it).
  SapCalendarModel? _model;
  void touch() => _model = null;

  SapCalendarModel get model => _model ??= _build();

  SapCalendarModel _build() {
    final (from, to) = _selectionRange(selectionRecords, selection);
    final sorted = days.keys.toList()..sort();
    return SapCalendarModel(
      shell: shell,
      container: container,
      today: today,
      selected: selected,
      focus: focus ?? selected ?? today,
      rangeMode: selectionStyle == null ? null : (selectionStyle! & 8) != 0,
      dateFormat: dateFormat,
      viewStyle: viewStyle,
      selectionStyle: selectionStyle,
      displayMonths: displayMonths,
      firstDayOfWeek: firstDayOfWeek,
      weekends: Set.unmodifiable(weekends),
      initViewers: initViewers,
      dayNames: dayNames,
      monthNames: monthNames,
      language: language,
      dayInfo: List.unmodifiable([for (final k in sorted) days[k]!]),
      colorLegend: Map.unmodifiable(legend),
      selectionFrom: from,
      selectionTo: to,
      events: Set.unmodifiable(events),
      program: program,
    );
  }
}

/// Every calendar control of the session, folded call by call.
class SapCalendarTracker {
  SapCalendarTracker({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final Map<String, _Cal> _cals = {};
  int _seq = 0;

  /// SAPR3 sink url -> the calendar shell whose `Selection` the server
  /// reads back through it ([takeSelectionRead]).
  final Map<String, String> _selectionSinks = {};

  /// The front end's day, for a calendar whose server sent no date at all.
  final DateTime Function() _clock;

  /// The `_RESULT` answers of the last [foldCall], by 0-based VARS row: the
  /// held interval for each InitViewers / CalcInterval
  /// ([calendarHeldInterval], in the call's dialect) — the responder's prop
  /// store for that call. The interval is held per calendar handle (the
  /// reference client's calendar_answers state): a CalcInterval answers the interval
  /// its own calendar's InitViewers set, stretched over the Selection the
  /// server assigned to that calendar.
  final Map<int, String> answers = {};

  /// Fold one complete flush call ([rfc] its value: the DayNames /
  /// MonthNames / DayInfo pushes ride it). [shellOf] = the session alias
  /// (object token -> kernel shell); [base] = the program of the screen the
  /// calendar opens over; [dialect] = the session's answer dialect, which
  /// picks the interval rule (default: the call's parse dialect, else
  /// Windows). Returns the shells whose model changed.
  Set<String> foldCall(
    FlushCall call,
    Uint8List rfc, {
    String? Function(String token)? shellOf,
    String? base,
    GuiDialect? dialect,
    int step = 0,
  }) {
    final rule = dialect ?? call.dialect ?? GuiDialect.windows;
    final touched = <String>{};
    answers.clear();
    final meta = verbMeta(call);
    final rowShell = <String, String>{}; // CreateControl result row -> shell
    // the push the next AssignProperty2 assigns — carried over from the
    // call before when that one ended on its SetDataFromUrl (the step-38
    // DayInfo batch's 711th push, assigned by step 40's first verb:
    // a recorded session raw srv[32] / srv[33])
    String? lastUrl = _pending?.$1;
    var unassigned = false; // the call's last push not yet assigned
    var usedPending = false;
    _Cal? selectionRead; // a Selection read-back awaiting its SaveDataToUrl
    DpCache? cache;
    for (var i = 1; i <= call.verbs.length; i++) {
      final verb = call.verbs[i - 1];
      final m = meta[i - 1];
      final args = verbNamedArgs(call, i);
      if (verb.startsWith('CreateControl')) {
        final sh = (args['#1'] ?? '').trim();
        final cls = (args['#2'] ?? '').trim();
        if (isCalendarClass(cls) && _digits.hasMatch(sh)) {
          final par = (args['#4'] ?? '').trim();
          // a reused shell id is a new calendar (a second F4: 120 / 121)
          _cals[sh] = _Cal(
            sh,
            _digits.hasMatch(par) ? par : null,
            _seq++,
            base,
            step,
          );
          final res = m.result?.trim() ?? '';
          if (res.isNotEmpty) rowShell[res] = sh;
          touched.add(sh);
        }
        continue;
      }
      if (verb == 'DestroyWindow') {
        final c = _cals[(args['#1'] ?? '').trim()];
        if (c != null && !c.closed) {
          c.closed = true;
          touched.add(c.shell);
        }
        continue;
      }
      if (verb == 'SetDataFromUrl') {
        final u = (args['#3'] ?? '').trim();
        if (u.startsWith('SAPR3://')) {
          lastUrl = u;
          unassigned = true;
        }
        continue;
      }
      if (verb == 'SaveDataToUrl') {
        final u = (args['#3'] ?? '').trim();
        final c = selectionRead;
        if (c != null && u.startsWith('SAPR3://')) {
          _selectionSinks[u] = c.shell;
          if (_selectionSinks.length > 64) {
            _selectionSinks.remove(_selectionSinks.keys.first);
          }
        }
        selectionRead = null;
        continue;
      }
      if (verb == 'RegisterOcxEvent') {
        final c = _cals[(args['#1'] ?? '').trim()];
        final id = int.tryParse((args['#2'] ?? '').trim());
        if (c != null && id != null) {
          c.events.add(id);
          touched.add(c.shell);
        }
        continue;
      }
      if (verb == 'AssignProperty2') unassigned = false;
      if (verb == 'AssignProperty2' &&
          (args['#2'] ?? '').trim() == 'Selection' &&
          (args['#4'] ?? '').trim() == 'r3TableAutoObj') {
        // the READ direction: the calendar's Selection copied into a data
        // object the queue then saves to a sink the server pulls
        // (a recorded session raw srv[23] step 34: AssignProperty2(29,
        // 'Selection', -1, 'r3TableAutoObj') + SaveDataToUrl -> the pull
        // at 36; raw srv[88] / srv[120] the same)
        selectionRead = _calOf(
          (args['#1'] ?? '').trim(),
          m.slots['#1'],
          rowShell,
          shellOf,
        );
        continue;
      }
      if (verb == 'AssignProperty2') {
        final prop = (args['#4'] ?? '').trim();
        if (!const {
          'DayNames',
          'MonthNames',
          'DayInfo',
          'Selection',
        }.contains(prop)) {
          continue;
        }
        // the target: #3 = the calendar's token, or (in its creation
        // queue) the CreateControl _RESULT row
        final c = _calOf(
          (args['#3'] ?? '').trim(),
          m.slots['#3'],
          rowShell,
          shellOf,
        );
        final url = lastUrl;
        if (c == null || url == null) continue;
        cache ??= DpCache()..ingestValue(rfc);
        var seg = cache.byUrl[url];
        if (seg == null && _pending?.$1 == url) {
          seg = _pending!.$2;
          usedPending = true;
        }
        if (prop == 'Selection') {
          if (seg == null) continue;
          c.selection = _selectionDates(seg);
          c.selectionRecords = _records(seg);
          touched.add(c.shell);
          continue;
        }
        if (prop == 'DayInfo') {
          // one (COLOR, DATE, TEXT) row per push, accumulated by date; a
          // dateless row names its colour (SapCalendar.setDayInfo)
          if (seg == null) continue;
          for (final (color, date, text) in _dayInfoRows(seg)) {
            if (date == null) {
              c.legend[color] = text;
            } else {
              c.days[calendarWireDate(date)] = SapCalendarDay(
                date,
                color,
                text,
              );
            }
          }
          touched.add(c.shell);
          continue;
        }
        final t = seg == null ? null : decodeNamedDpTable(seg);
        if (t == null) continue;
        switch (prop) {
          case 'DayNames':
            c.dayNames = _names(t);
            // the LANG column (`F`): the logon language the names are in
            if (t.rows.isNotEmpty && t.columns.isNotEmpty) {
              c.language = (t.rows.first[t.columns.first] ?? '').trim();
            }
          default:
            c.monthNames = _names(t);
        }
        touched.add(c.shell);
        continue;
      }
      if (verb == 'ResetDayInfo') {
        // the marks dropped before the next DayInfo wave (raw srv[88]
        // step 142, ahead of step 146's DayInfo wave)
        final c = _calOf(m.objValue.trim(), m.obj, rowShell, shellOf);
        if (c == null) continue;
        c.days.clear();
        touched.add(c.shell);
        continue;
      }
      if (verb != 'Today' && verb != 'InitViewers' && verb != 'CalcInterval') {
        continue;
      }
      final c = _calOf(m.objValue.trim(), m.obj, rowShell, shellOf);
      if (c == null) continue;
      touched.add(c.shell);
      if (verb == 'CalcInterval') {
        // the interval THIS calendar holds (its InitViewers answer; around
        // its date when none was asked) stretched over the Selection the
        // server assigned it (the test system srv[101] -> gui[89]: Feb 2026 .. Apr 2027
        // held, Selection 18.06.2025 .. 18.06.2026 -> 20250526,20270502)
        c.held = calendarStretch(
          c.held ??
              calendarHeldInterval(
                c.focus ?? c.selected ?? c.today ?? _clock(),
                dialect: rule,
              ),
          c.selection,
          dialect: rule,
        );
        _answer(m, c.held!);
        continue;
      }
      if (verb == 'Today') {
        // the property put's value (its only argument)
        final v = verbArgs(
          call,
          i,
        ).map((a) => a.$2.trim()).where((s) => _digits.hasMatch(s)).firstOrNull;
        final d = v == null ? null : parseCalendarDate(v);
        if (d == null) continue;
        if (!c.initSeen) {
          c.today = d;
        } else {
          c.focus = d;
        }
        continue;
      }
      // InitViewers(#01 … #10)
      final a = [
        for (final (k, v) in verbArgs(call, i))
          if (k.trim().startsWith('#')) v,
      ];
      c
        ..initSeen = true
        ..initViewers = List.unmodifiable(a)
        // (display style, selection style, date format, months shown,
        // date, stand-alone, week rule, -, -, weekends): SapCalendar.
        // initViewers(int, int, String, int, String, boolean, int, int,
        // int, String)
        ..viewStyle = a.isNotEmpty ? int.tryParse(a[0].trim()) : null
        ..selectionStyle = a.length > 1 ? int.tryParse(a[1].trim()) : null
        ..dateFormat = a.length > 2 ? a[2].trim() : ''
        ..displayMonths = a.length > 3 ? int.tryParse(a[3].trim()) : null
        ..selected = a.length > 4 ? parseCalendarDate(a[4]) : null
        ..firstDayOfWeek = switch (a.length > 6 ? a[6].trim() : '') {
          '7' => DateTime.sunday,
          '6' => DateTime.saturday,
          _ => DateTime.monday,
        }
        ..weekends = {
          if (a.length > 9)
            for (final ch in a[9].trim().split(''))
              if (int.tryParse(ch) case final n? when n >= 1 && n <= 7) n,
        };
      // the held interval around #05, else the server's Today (an empty
      // field on the AIF navigator), else the front end's own day
      c.held = calendarHeldInterval(
        c.selected ?? c.today ?? _clock(),
        dialect: rule,
      );
      _answer(m, c.held!);
    }
    // a push the call set up but did not assign: the next call may
    final last = lastUrl;
    if (unassigned && last != null) {
      cache ??= DpCache()..ingestValue(rfc);
      final seg = cache.byUrl[last];
      _pending = seg == null ? null : (last, seg);
    } else if (usedPending || last != _pending?.$1) {
      _pending = null;
    }
    for (final sh in touched) {
      _cals[sh]?.touch();
    }
    return touched;
  }

  /// The last push of the previous call ([foldCall]): (url, segment).
  (String, Uint8List)? _pending;

  void _answer(VerbMeta m, (DateTime, DateTime) interval) {
    final row = int.tryParse(m.result?.trim() ?? '');
    if (row == null || row < 1) return;
    answers[row - 1] = calendarIntervalAnswer(interval);
  }

  /// The calendar a verb names: by its CreateControl row in this queue,
  /// by the alias of its token, by a token already bound — else the token
  /// is bound to the newest open calendar without one.
  _Cal? _calOf(
    String token,
    String? row,
    Map<String, String> rowShell,
    String? Function(String)? shellOf,
  ) {
    final byRow = row == null ? null : rowShell[row.trim()];
    if (byRow != null) return _cals[byRow];
    if (token.isEmpty) return null;
    final sh = shellOf?.call(token);
    if (sh != null && _cals[sh] != null) return _cals[sh]!..token = token;
    if (_cals[token] != null) return _cals[token];
    for (final c in _cals.values) {
      if (c.token == token && !c.closed) return c;
    }
    _Cal? newest;
    for (final c in _cals.values) {
      if (c.closed || c.token != null) continue;
      if (newest == null || c.seq > newest.seq) newest = c;
    }
    return newest?..token = token;
  }

  /// Relabel the calendars created over [old] at a step >= [since] as
  /// [now]'s — the screen generation the action that created them opened
  /// (ControlRegistry.retag, reference client ea_facts.retag_generation). A
  /// calendar the server builds INTO a new screen is created in that
  /// screen's PBO flush, which is answered before the paint that names the
  /// program: /AIF/IFMON's date navigator (CreateControl 144,
  /// SAP.CalendarControl.1, in the left pane's splitter cell 128 —
  /// a recorded session raw srv[20..22], step 32) was stamped with the
  /// SAP Easy Access program it was launched from, so [calendars] never
  /// listed it under /AIF/ERR_OVERVIEW and it was never drawn — its cell
  /// stayed blank once the server showed it (live the test system 2026-10-13). Returns
  /// how many were relabelled.
  int retag(String old, String now, {required int since}) {
    if (old == now) return 0;
    var n = 0;
    for (final c in _cals.values) {
      if (c.program == old && c.step >= since) {
        c
          ..program = now
          ..touch();
        n++;
      }
    }
    return n;
  }

  /// The open calendars, newest first: not torn down, live ([isLive]),
  /// created over [base] when given.
  List<SapCalendarModel> calendars({
    bool Function(String shell)? isLive,
    String? base,
  }) {
    final out = [
      for (final c in _cals.values)
        if (!c.closed &&
            (isLive?.call(c.shell) ?? true) &&
            (base == null || c.program == null || c.program == base))
          c,
    ]..sort((a, b) => b.seq.compareTo(a.seq));
    return [for (final c in out) c.model];
  }

  /// Every calendar shell the tracker knows, open or not.
  Set<String> get shells => _cals.keys.toSet();

  /// The records a pull of sink [url] reads back when it is a calendar's
  /// `Selection` read-back (null otherwise; the sink is consumed): the
  /// rows of the Selection the server last assigned that calendar whose
  /// type field (the I4 after the date) is set — the interval's from (1)
  /// and to (2) — at their full width. The SAP GUI for Windows' answer in
  /// a recorded session: the server assigns three rows (date, 0) /
  /// (from, 1) / (to, 2) and reads back the last two — raw srv[23] ->
  /// gui[17] (20260824 x 3 -> 20260824 / 20260824), srv[72] -> gui[76] at
  /// step 144 (20260618 x 3), srv[103] -> gui[106] at 192 (20250618,
  /// 20250618, 20260618 -> 20250618 / 20260618). GuiGo answered the
  /// read-back with no rows.
  List<Uint8List>? takeSelectionRead(String url) {
    final sh = _selectionSinks.remove(url);
    if (sh == null) return null;
    final c = _cals[sh];
    if (c == null) return const [];
    return [
      for (final r in c.selectionRecords)
        if (r.length < 12 ||
            ByteData.sublistView(r, 8, 12).getUint32(0, Endian.little) != 0)
          r,
    ];
  }
}

/// The DATAASC records of a push at the table's declared width: its inline
/// `03 04` cells carry each record with its trailing run collapsed to one
/// byte ([expandInlineRow] undoes it); one LZH cell is the records back
/// to back.
List<Uint8List> _records(Uint8List seg) {
  final (_, (w, n), cells) = dpColumnCells(seg, 'DATAASC');
  if (w <= 0 || n <= 0 || cells.isEmpty) return const [];
  if (cells.length == n) {
    return [for (final c in cells) expandInlineRow(c, w)];
  }
  final all = BytesBuilder(copy: false);
  for (final c in cells) {
    all.add(c);
  }
  final b = all.takeBytes();
  return [
    for (var i = 0; (i + 1) * w <= b.length && i < n; i++)
      Uint8List.fromList(b.sublist(i * w, (i + 1) * w)),
  ];
}

/// The dates of a `Selection` push: every YYYYMMDD in its DATAASC cells
/// (the test system srv[101]: 20250618 / 20250618 / 20260618 — the X-R3TABLE's rows,
/// from and to, not split by the generic table decoder).
List<DateTime> _selectionDates(Uint8List seg) {
  final text = String.fromCharCodes(seg);
  final at = text.indexOf('DATAASC');
  if (at < 0) return const [];
  var end = text.indexOf('FORMAT', at);
  if (end < 0) end = text.length;
  return [
    for (final m in _selectionDatesRx
        .allMatches(text.substring(at, end)))
      ?parseCalendarDate(m.group(0)!),
  ];
}

List<SapCalendarName> _names(DpTable t) {
  final out = <SapCalendarName>[];
  for (final r in t.rows) {
    // LANG | NUMBER | SHORT | LONG (positional columns 1..4)
    final cols = t.columns;
    if (cols.length < 4) continue;
    final n = int.tryParse((r[cols[1]] ?? '').trim());
    if (n == null) continue;
    out.add(
      SapCalendarName(n, (r[cols[2]] ?? '').trim(), (r[cols[3]] ?? '').trim()),
    );
  }
  out.sort((a, b) => a.number.compareTo(b.number));
  return List.unmodifiable(out);
}

/// The (from, to) of a `Selection` push: its rows' type field (the I4
/// after the date: 1 = from, 2 = to — a recorded session raw srv[101]
/// 20250618 / 20250618 (1) / 20260618 (2)); a push without typed rows
/// spans its dates; (null, null) for none.
(DateTime?, DateTime?) _selectionRange(
  List<Uint8List> records,
  List<DateTime> dates,
) {
  DateTime? from, to;
  for (final r in records) {
    if (r.length < 12) continue;
    final d = parseCalendarDate(String.fromCharCodes(r, 0, 8));
    if (d == null) continue;
    switch (ByteData.sublistView(r, 8, 12).getUint32(0, Endian.little)) {
      case 1:
        from = d;
      case 2:
        to = d;
    }
  }
  if (from == null && to == null) {
    if (dates.isEmpty) return (null, null);
    return (dates.first, dates.last);
  }
  from ??= to;
  to ??= from;
  return to!.isBefore(from!) ? (to, from) : (from, to);
}

/// The rows of a `DayInfo` push as (colour, date or null, text): the
/// table's FORMAT columns (COLOR I4, DATE C8, TEXT C30 — the AIF pushes'
/// [4, 8, 30] / types I C C) read at their offsets from each record (the
/// inline cells expanded to the declared width: the generic table decoder
/// read the 43-byte inline cell of a 44-byte record as no row).
List<(int, DateTime?, String)> _dayInfoRows(Uint8List seg) {
  final t = decodeNamedDpTable(seg);
  final lengths = t?.lengths ?? const <int>[];
  final types = t?.types ?? const <int>[];
  // the column order: the I4 colour, the C8 date, the text (by type and
  // length, not by name — the FORMAT names are positional)
  var colorAt = 0, dateAt = 4, textAt = 12, textLen = 30;
  if (lengths.length >= 3 && types.length >= 3) {
    var off = 0;
    for (var i = 0; i < lengths.length; i++) {
      if (types[i] == 0x49 && lengths[i] == 4) {
        colorAt = off;
      } else if (lengths[i] == 8 && types[i] != 0x49) {
        dateAt = off;
      } else {
        textAt = off;
        textLen = lengths[i];
      }
      off += lengths[i];
    }
  }
  final out = <(int, DateTime?, String)>[];
  for (final r in _records(seg)) {
    if (r.length < colorAt + 4 || r.length < dateAt + 8) continue;
    final color = ByteData.sublistView(
      r,
      colorAt,
      colorAt + 4,
    ).getInt32(0, Endian.little);
    final raw = String.fromCharCodes(r, dateAt, dateAt + 8).trim();
    final date = raw.isEmpty ? null : parseCalendarDate(raw);
    if (raw.isNotEmpty && date == null) continue;
    final end = (textAt + textLen).clamp(0, r.length);
    final text = textAt < end
        ? _text(Uint8List.sublistView(r, textAt, end))
        : '';
    out.add((color, date, text));
  }
  return out;
}

/// A text field of a push: UTF-8 when it decodes as such, else Latin-1;
/// trailing blanks / NULs dropped.
String _text(Uint8List b) {
  var n = b.length;
  while (n > 0 && (b[n - 1] == 0 || b[n - 1] == 0x20)) {
    n--;
  }
  final v = Uint8List.sublistView(b, 0, n);
  try {
    return utf8.decode(v).trim();
  } on FormatException {
    return latin1.decode(v).trim();
  }
}

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call.
final RegExp _parseCalendarDateRx = RegExp(r'^\d{8}$');
final RegExp _fieldShowsDateRx = RegExp(r'^(?:\d{2}[./-]\d{2}[./-]\d{4}|\d{4}[./-]\d{2}[./-]\d{2})$');
final RegExp _selectionDatesRx = RegExp(r'(?<!\d)\d{8}(?!\d)');
