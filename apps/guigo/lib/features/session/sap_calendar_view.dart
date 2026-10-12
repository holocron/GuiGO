import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

/// The date picker the server hosts for F4 on a date field
/// (SAP.CalendarControl.1, [SapCalendarModel]) drawn as a native month
/// grid in its region: it opens on the month of the field's date (selected),
/// else of the SERVER's today, which it marks; a tapped day is
/// the pick ([onPick] -> SapSession.pickCalendarDate). The server then
/// closes the popup and writes the date into the field — nothing is
/// decided client-side.
class SapCalendarView extends StatelessWidget {
  const SapCalendarView({
    super.key,
    required this.calendar,
    required this.onPick,
    this.busy = false,
  });

  final SapCalendarModel calendar;
  final void Function(DateTime day) onPick;
  final bool busy;

  static final DateTime _first = DateTime(1900);
  static final DateTime _last = DateTime(9999, 12, 31);

  /// The picker's natural size (Material's day grid with its header); the
  /// region scales it to fit.
  static const Size natural = Size(328, 360);

  DateTime _clamp(DateTime d) =>
      d.isBefore(_first) ? _first : (d.isAfter(_last) ? _last : d);

  @override
  Widget build(BuildContext context) {
    final today = calendar.today ?? DateTime.now();
    final selected = calendar.selected;
    return Semantics(
      label: 'Calendar ${calendar.shell}',
      child: AbsorbPointer(
        absorbing: busy,
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox.fromSize(
            size: natural,
            child: CalendarDatePicker(
              key: ValueKey('calendar-picker-${calendar.shell}'),
              // the selected day = the field's date; without one the month
              // opens on the server's today with no day selected
              initialDate: selected == null ? null : _clamp(selected),
              currentDate: _clamp(today),
              firstDate: _first,
              lastDate: _last,
              onDateChanged: onPick,
            ),
          ),
        ),
      ),
    );
  }
}
