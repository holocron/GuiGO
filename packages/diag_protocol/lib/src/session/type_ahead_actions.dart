/// The SAP GUI for Windows TYPE-AHEAD request round of a dynpro field
/// (model + okcodes: screen/type_ahead.dart). Pinned item by item against
/// the real GUI (reference client recordings, RAW numbering of their DECODE.md):
///
/// * a recorded session gui[8] — `%_SEARCH 100` on SE16's
/// MATNR-LOW, nothing typed elsewhere: step; SES eventarray 0; 16/6/35;
/// 16/12/4 `%_SEARCH 100` right after the codepage; the GUI identity;
/// 16/5/1 OK mode 0x05; 16/12/8; the painted 16/12/6; 16/15/1
/// `02 0004 0001 00000000 <row> <col> 0001 00` (UI event type 4 on the
/// FIELD at its cell); 16/9/11 on the field, caret 0; the metrics
/// DATAMANAGER. NO 16/9/2 atom: the text typed so far is not committed
/// by the request (it rides the next round's atom);
/// * a recorded session gui[12] / gui[14] — a dirty field rides
/// the request: 16/10/1 (zeros) + ONE 16/9/2 with its value atom after
/// the geometry, the 16/15/1 + 16/9/11 after them (the PICKED `ZNCC` of
/// AUART rides the VKORG `%_SEARCH 1`; the re-asked `zn` carries its own
/// atom with caret 2); no metrics item then.
///
/// The command field's request (`%_SEARCH_OKCODE <text>`, gui[18] / [20])
/// is the plain typed-okcode round (no 16/15/1: the cursor is in the
/// command field, `16/9/10`, or a dirty field's atom + cursor) — the
/// session's ordinary okcode (sap_session_type_ahead.dart).
library;

import 'dart:typed_data';

import '../framing/envelope.dart';
import '../screen/type_ahead.dart';
import 'actions.dart';
import 'frontend_profile.dart';

/// The UI event type of a type-ahead request (16/15/1 byte 2..3).
const int uiEventTypeAhead = 4;

/// The 16/15/1 of a dynpro-field type-ahead request: flags 0x02, event type
/// 4, control type 1 (a dynpro field), 4 zero bytes, the field's wire
/// row/col, the container path (u16 count + bytes) — gui[8]
/// `02 0004 0001 00000000 0001 0022 0001 00`.
Uint8List uiEventTypeAheadWindows(int row, int col, List<int> path) {
  final p = path.isEmpty ? const [0] : path;
  final v = Uint8List(15 + p.length);
  final bd = ByteData.sublistView(v);
  v[0] = 0x02;
  bd.setUint16(1, uiEventTypeAhead);
  bd.setUint16(3, 0x0001);
  bd.setUint16(9, row & 0xffff);
  bd.setUint16(11, col & 0xffff);
  bd.setUint16(13, p.length);
  v.setRange(15, v.length, p);
  return v;
}

/// The 16/9/11 of the request: depth = the path length, the field's wire
/// cell, [caret], the path — gui[8] `01 0001 0022 00000000 00`.
Uint8List typeAheadCursor(int row, int col, List<int> path, int caret) {
  final p = path.isEmpty ? const [0] : path;
  final v = Uint8List(9 + p.length);
  final bd = ByteData.sublistView(v);
  v[0] = p.length;
  bd.setUint16(1, row & 0xffff);
  bd.setUint16(3, col & 0xffff);
  bd.setUint32(5, caret);
  v.setRange(9, v.length, p);
  return v;
}

/// The Windows dynpro-field type-ahead request for the field at wire cell
/// ([row], [col]) of container [path] (the field's routing path, `[area]`
/// on a flat dynpro), asking for [text] — the text typed so far, verbatim.
///
/// [pending] = the typed values not yet committed (the session's staged
/// fields, the last one the field's own when it was staged): their atoms
/// ride this round, as on the real GUI. [caret] = the cursor offset in the
/// field (the length of its own pending value, 0 when it has none —
/// gui[12] `zn` caret 2, gui[8] caret 0).
List<Uint8List> typeAheadRequestItems(
  ActionContext ctx, {
  required int row,
  required int col,
  List<int> path = const [0],
  required String text,
  int caret = 0,
  List<FieldWrite> pending = const [],
}) {
  final cmd = '$typeAheadOkcode $text';
  final base = windowsActionItems(
    pending.isEmpty
        ? okcodeItems(ctx, cmd)
        : fieldRoundItems(ctx, pending, okcode: cmd),
    ctx: ctx,
  );
  final out = <Uint8List>[];
  for (final raw in base) {
    final walk = walkItems(raw).items;
    final it = walk.length == 1 ? walk.single : null;
    if (it == null) {
      out.add(raw);
      continue;
    }
    if (it.isEom) {
      out
        ..add(
          buildApplItem(15, 1, uiEventTypeAheadWindows(row, col, path)),
        )
        ..add(buildApplItem(9, 11, typeAheadCursor(row, col, path, caret)));
      // the bare request closes with the metrics DATAMANAGER (gui[8]); one
      // carrying atoms does not (gui[12] / [14])
      if (pending.isEmpty) {
        out.add(xmlBlobItem(liveMetricsXml(ctx.screenRows, ctx.screenCols)));
      }
      out.add(raw);
      continue;
    }
    if (it.isAppl && it.id == 9 && (it.sid == 10 || it.sid == 11)) continue;
    if (it.isAppl && it.id == 15 && it.sid == 1) continue;
    if (it.isAppl && it.id == 4 && it.sid == 36) continue;
    if (!it.isAppl && !it.isEom && it.type == 17) continue; // rebuilt above
    if (it.isAppl && it.id == 5 && it.sid == 1 && it.value.length >= 2) {
      // the cursor sits in a field: the acked paint's cursor half (0x05 on
      // a flat dynpro — gui[8], gui[12], gui[14])
      out.add(
        buildApplItem(
          5,
          1,
          Uint8List.fromList(it.value)
            ..[1] = windowsOkMode(ctx, cursor: true, fallback: winOkModePlain),
        ),
      );
      continue;
    }
    out.add(raw);
  }
  return out;
}
