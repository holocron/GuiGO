part of 'sap_session.dart';

/// DYNPRO-FIELD TYPE-AHEAD on a [SapSession] (model: screen/type_ahead.dart;
/// the round: type_ahead_actions.dart; the command field:
/// sap_session_type_ahead.dart). Ground truth: a recorded session
/// (RAW gui[8] / [10] / [12] / [14]) and a recorded session
/// gui[8] — `%_SEARCH <text so far>` with the type-ahead 16/15/1 and the
/// 16/9/11 on the field, the typed values of the screen riding it as atoms.
/// The PICK of a proposal sends nothing: the caller stages the key
/// ([stageField]) and it rides the next round, as on the real GUI.
extension SapSessionFieldTypeAhead on SapSession {
  /// Ask the server's proposals for armed input [f] ([ScreenField.typeAhead])
  /// for [text] (the field's text so far). Every staged value rides the
  /// request (and is committed by it); [f]'s own staged value gives the
  /// caret. Null when nothing came back. Throws [UnsupportedError] on the
  /// Java dialect (no Java type-ahead round is recorded) and
  /// [ArgumentError] for a field the server did not arm.
  Future<TypeAheadTable?> fieldTypeAhead(ScreenField f, String text) async {
    if (answerDialect != GuiDialect.windows) {
      throw UnsupportedError(
          'type-ahead: no SAP GUI for Java type-ahead round is recorded');
    }
    // the field as the session holds it now (a no-op repaint of the same
    // screen may have replaced the caller's object)
    final m = screen;
    final cur = m?.fields.where((x) => _sameField(x, f)).firstOrNull;
    if (cur == null || !cur.typeAhead || cur.kind != FieldKind.input ||
        cur.isProtected) {
      throw ArgumentError('${f.name} is no type-ahead field of this screen');
    }
    f = cur;
    if (text.isEmpty) return null;
    // table-control cells never ride as atoms (their control's plane)
    if (_stagedHasCells) await _sendStagedCellsFirst();
    final own = _staged.where((s) => _sameField(s.field, f)).lastOrNull;
    final pending = [
      for (final s in _staged)
        if (!_sameField(s.field, f)) _writeOf(s),
      if (own != null) _writeOf(own), // the cursor field's segment last
    ];
    final items = typeAheadRequestItems(
      ctx,
      row: f.wireRow,
      col: f.wireCol,
      path: f.routing?.path ?? [f.area & 0xff],
      text: text,
      caret: own == null ? 0 : wireText(own.text.trimRight()).length,
      pending: pending,
    );
    final frames = await _act(items, dialectReady: true, consumesStaged: true);
    return findTypeAheadTable(frames);
  }
}
