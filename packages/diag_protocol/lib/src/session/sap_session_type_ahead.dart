/// TYPE-AHEAD on a [SapSession] through its PUBLIC rounds (model + rules:
/// screen/type_ahead.dart).
///
/// The COMMAND FIELD's request is the plain typed-okcode round the session
/// already sends ([SapSession.okcode]): a recorded session
/// gui[20] (RAW) `%_SEARCH_OKCODE me` = `16/12/4` + OK mode 0x03 +
/// `16/9/10`, no 16/15/1; gui[18] `%_SEARCH_OKCODE me2` with a dirty
/// dynpro field = that field's 16/10/1 + 16/9/2 atom and its 16/9/11
/// (caret = the value length), OK mode 0x05 — the session's staged-okcode
/// round. The answer is one `TypeAheadExport` flush the session's
/// responder already answers (`_RESULT` 0) and a no-op repaint; the table
/// is read from the turn's DataProvider push ([findTypeAheadTable]).
///
/// The DYNPRO-FIELD request (`%_SEARCH <text>` with the type-ahead 16/15/1
/// on the field, [typeAheadRequestItems]) needs the session's action
/// pipeline with the staged values — a `part` of sap_session.dart.
library;

import '../cfw/flush_call.dart' show GuiDialect;
import '../screen/type_ahead.dart';
import 'sap_session.dart';

extension SapSessionTypeAhead on SapSession {
  /// Whether this connection can ask the command-field type-ahead: the
  /// Windows dialect, whose connect advertises support bit 222
  /// OKCODE_TYPEAHEAD_ALL_RESULTS (logon_frames.dart — the real GUI's
  /// recorded bitmap). No Java-GUI type-ahead round is recorded.
  bool get commandFieldTypeAheadAvailable =>
      answerDialect == GuiDialect.windows;

  /// The command-field proposals for [typed] (the text in the command
  /// field): null — nothing sent — when [commandFieldTypeAheadAllowed]
  /// says the GUI would not ask, or the dialect has no recorded request.
  /// The typed values of the screen ride the request (gui[18]).
  Future<TypeAheadTable?> commandFieldTypeAhead(String typed) async {
    final t = typed.trim();
    if (!commandFieldTypeAheadAvailable || !commandFieldTypeAheadAllowed(t)) {
      return null;
    }
    final frames = await okcode('$typeAheadOkcodeCommand $t');
    return findTypeAheadTable(frames);
  }
}

/// The command a pick of [row] from a command-field [table] puts into the
/// command field (the client applies `SDSH_TYPE_OKCODE_PREFIX`, `/n`:
/// a recorded session — the Enter after the pick of
/// `ME23N` is the plain okcode `/nME23N`).
String commandFieldPickText(TypeAheadTable table, TypeAheadRow row) =>
    '${table.okcodePrefix}${row.key}';
