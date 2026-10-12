/// The Windows GUI's `%_GS 0 3` LAYOUT ROUND — the round a real SAP GUI for
/// Windows sends on its own after a paint whose creation waves docked or
/// resized containers: it reports the window / dynpro-area pixels it
/// realized (16/12/8) and the changed cached control properties (the item
/// 17 CONTROLS report), and the server re-lays the screen out to that area
/// in its reply (a recorded session gui[15] after the
/// DB50/0100 paint srv[23]: area 1141 of 1880 px; the server's next
/// AREASIZE, srv[25], is 34 x 163 of 38 x 268).
///
/// Item order, byte-pinned against every Windows-dialect `%_GS 0 3` of the
/// corpus (a recorded session gui[15],
/// a recorded session gui[44],
/// a recorded session gui[18], a recorded session gui[1191]):
/// Step, SES (no event, the window pixels' low bytes as dims), 16/6/35,
/// 16/12/4 `%_GS 0 3`, the 16/4 identity atoms (no 16/4/36), 16/5/1 OK
/// event (mode by the paint's focus class: 0x0d + the painted 16/9/11,
/// 0x0b + the empty 16/9/10 without a focus, 0x0b + the tabstrip echo +
/// the 16/9/18 after a control-focus paint — a recorded session gui[26]),
/// 16/12/8 window + area pixels, 16/12/6 the paint's own SCROLL_INFOS2
/// echoed, the focus item, item 17, EOM. Screens with table controls /
/// step loops additionally echo their 16/10 and 16/9/15 state (su53
/// gui[1191]) — not built here.
library;

import 'dart:typed_data';

import '../codepages.dart';
import '../framing/envelope.dart';
import 'actions.dart';
import 'frames.dart';
import 'frontend_profile.dart';

/// The layout round's okcode (GuiSystemAction shell 0, event 3).
const String layoutOkcode = '%_GS 0 3';

/// One CONTROL block of the report: the shell, its GENERIC first-visible
/// cell (grids: FVCID / FVRID) and its changed PROPERTY values in
/// registration order.
class ControlReport {
  const ControlReport(this.shell, {this.generic, this.props = const []});
  final String shell;
  final (int, int)? generic;
  final List<(String, String)> props;
}

/// The Windows GUI's CONTROLS report text, in its own spacing
/// (`<CONTROL SHELLID ="117"> <PROPERTY VALUE ="2163" NAME ="300"/>` —
/// a recorded session gui[15]); no trailing NUL.
String windowsControlsXml(List<ControlReport> controls) {
  final b = StringBuffer(
    '<?xml version="1.0" encoding="sap*"?><DATAMANAGER> <CONTROLS>',
  );
  for (final c in controls) {
    b.write('  <CONTROL SHELLID ="${c.shell}">');
    if (c.generic case (final col, final row)) {
      b.write('   <GENERIC FVCID ="$col" FVRID ="$row" FVRIDS ="0"/>');
    }
    for (final (name, value) in c.props) {
      b.write('   <PROPERTY VALUE ="$value" NAME ="$name"/>');
    }
    b.write('</CONTROL>');
  }
  b.write('</CONTROLS></DATAMANAGER>');
  return b.toString();
}

/// The `%_GS 0 3` round's items (Windows dialect, ready to send):
/// [windowPx] / [areaPx] = (height, width) in pixels, [scrollInfos2] = the
/// paint's 16/12/6 value, [xml] = the item-17 report.
List<Uint8List> windowsLayoutRoundItems(
  ActionContext ctx, {
  required (int, int) windowPx,
  required (int, int) areaPx,
  required Uint8List scrollInfos2,
  required String xml,
}) {
  final ses = Uint8List(16)
    ..[7] = ctx.modalNo
    ..[14] = windowPx.$1 & 0xff
    ..[15] = windowPx.$2 & 0xff;
  // the OK mode + focus item BY THE PAINT'S FOCUS CLASS (reference client 2711bbc,
  // every `%_GS 0 3` of the corpus): a trailing 16/9/18 control focus ->
  // 0x0b + that 16/9/18 + the paint's tabstrip echo after the 16/12/6
  // (a recorded session gui[26] on srv[33] `"122"`); a painted 16/9/11
  // -> 0x0d + it verbatim (a recorded session gui[15]); no
  // focus -> 0x0b + the empty 16/9/10 (a recorded session gui[18],
  // a recorded session gui[44])
  final control = ctx.paintedControlFocus;
  // the painted cursor in its client form ([windowsClientCursor]: a nested
  // one without the trailing zero level, as every Windows round sends it)
  final painted = control == null ? ctx.paintedFocus : null;
  final focus = painted == null ? null : windowsClientCursor(painted);
  // the focus item decides the half, the acked paint the mode
  // ([windowsOkMode]: st04_dbsize gui[15] 0x0d on a `09` paint); 0x0d /
  // 0x0b without a paint mode
  final ok = Uint8List(22)
    ..[1] = windowsOkMode(ctx,
        cursor: focus != null,
        fallback: focus != null ? winOkModeNested : winOkModeControlFocus);
  final px = ByteData(16)
    ..setUint32(0, windowPx.$1)
    ..setUint32(4, windowPx.$2)
    ..setUint32(8, areaPx.$1)
    ..setUint32(12, areaPx.$2);
  return [
    stepItem(ctx.step),
    Uint8List.fromList([itemSes, ...ses]),
    buildApplItem(6, 35, winCodepageValue),
    buildApplItem(12, 4, wireText(layoutOkcode)),
    for (final (sid, value) in winIdentity) buildApplItem(4, sid, value),
    buildApplItem(5, 1, ok),
    buildApplItem(12, ctx.modalNo != 0 ? 14 : 8, px.buffer.asUint8List()),
    buildApplItem(12, 6, scrollInfos2),
    if (control != null) ...[
      ...ctx.paintedTabstripEcho,
      buildApplItem(9, 18, wireText(control)),
    ] else if (focus != null)
      buildApplItem(9, 11, focus)
    else
      buildApplItem(9, 10, Uint8List(0)),
    xmlBlobItem(wireText(xml)),
    eomBytes,
  ];
}
