part of 'sap_session.dart';

/// Classic dynpro CHECKBOXES — the tick / untick transport (reference client
/// raw_checkbox / screen_checkbox, complaint-TRCHECK+20260919-211350 C).
///
/// A box is the radio's boolean twin ([FieldKind.checkbox], the painted
/// etype-128 atom) but transports ALONE: platinr3S.jar GuiToggleButton
/// .getValueChanges emits one GuiToggleButtonChange for the changed box,
/// no group sibling (the radio's GuiButtonGroup.setGroupChanged). Its wire
/// form is the Windows dialect's 24-byte etype-128 value atom
/// ([checkboxValueAtom]) inside the routed field-write envelope — byte
/// oracle a recorded session gui[38], the real SAP GUI for Windows' Enter
/// after a listbox pick and the INPLACE tick: ONE 16/9/2 carrying both
/// atoms, the focus at offset 0, no 16/15/1 (the Java dialect's 104 label
/// atom is live-unconfirmed; GuiGo's Windows modification round is the
/// pinned one).
///
/// Ticking is pure client state, as typing is (SapSessionFields): a box
/// without a function code is STAGED and rides the next action's field
/// round with the typed values — never an Enter of its own, which would
/// cost a spinner per tap and two PAIs when text is typed. A box WITH its
/// own function code fires PAI on its click (the radio's `=TOGGLE` rule):
/// the code rides 16/12/4 with the CHECKBUTTON element event
/// ([checkboxSelectItems]). The staged tick follows every staged-value rule:
/// dropped on a repaint and by a `/n…` command, sent first as an Enter
/// round before an action no field round carries.
extension SapSessionCheckbox on SapSession {
  /// Tick ([on]) / untick checkbox [f] of the active window WITHOUT a round
  /// trip: the state rides the next action's frame. [f] is matched by its
  /// place and name ([_sameField]) so the screen's CURRENT box decides —
  /// a box the paint marks PROTECTED is refused before anything is staged
  /// (the kernel answers a tick on one with "input for protected field",
  /// T100 00 123, and tears the transaction down).
  void stageCheckbox(ScreenField f, bool on) {
    final (m, cur) = _checkboxOf(f);
    _staged.removeWhere((s) => _sameField(s.field, cur));
    _staged.add(StagedField(cur, on ? 'X' : ' '));
    _stagedScreen = _screenIdentity(m);
  }

  /// Tick ([on]) / untick checkbox [f]: a box without a function code is
  /// staged ([stageCheckbox], nothing sent); a box with its own function
  /// code sends at once — the code, the typed values and the tick in ONE
  /// field round with the box's element event, the focus on the box
  /// ([checkboxSelectItems]), the turn handled as any action's.
  Future<void> setCheckbox(ScreenField f, bool on) async {
    final (_, cur) = _checkboxOf(f);
    final fc = (cur.fcode ?? '').trim();
    if (fc.isEmpty) {
      stageCheckbox(cur, on);
      return;
    }
    // table-control cells cannot ride a screen field's round: theirs first
    if (_stagedHasCells) await _sendStagedCellsFirst();
    await _act(
      _stagedRound(
        okcode: fc,
        extra: StagedField(cur, on ? 'X' : ' '),
        eventSource: choiceEventSource(
          cur.wireRow,
          cur.wireCol,
          cur.routing?.path ?? [cur.area & 0xff],
          controlType: checkboxElementKind,
        ),
      ),
      consumesStaged: true,
    );
  }

  /// The box of the active screen [f] names, with the screen; throws when
  /// [f] is no checkbox of it or is protected.
  (ScreenModel, ScreenField) _checkboxOf(ScreenField f) {
    final m = screen;
    ScreenField? cur;
    if (m != null) {
      for (final x in m.fields) {
        if (_sameField(x, f)) {
          cur = x;
          break;
        }
      }
    }
    if (m == null || cur == null) {
      throw ArgumentError('${f.name} is not a field of the active window');
    }
    if (cur.kind != FieldKind.checkbox) {
      throw ArgumentError('${f.name} is not a checkbox');
    }
    if (cur.tableControl != null) {
      // a table-control cell has no screen atom: its tick is written in
      // the control's TABLE plane (TcCellWrite checkbox, submitCell) —
      // sent as a 16/9/2 atom the kernel answers "FOCUS DATA"
      throw ArgumentError(
        '${f.name} is a table-control cell: tick it through submitCell',
      );
    }
    if (cur.isProtected) {
      throw ArgumentError(
        '${f.name} is a protected checkbox: the kernel refuses a tick on it',
      );
    }
    return (m, cur);
  }
}
