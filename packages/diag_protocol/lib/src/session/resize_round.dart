/// The SAP GUI for Windows' WINDOW-RESIZE round — what the real GUI sends on
/// its own when the user resizes the window over a screen whose server
/// layout depends on the window size (a custom-control area, a step loop):
/// a standalone round with SES eventarray 0x52 (`DIAG_EVENT_RESIZE`,
/// SAPfewdp.dll / SAPfront.dll `CSession::Update_Window_Size_px`), no
/// okcode, no UI event source, the new window pixels in 16/12/8, and the
/// server answers with the screen laid out again for that window (an OLE
/// flush first when CFW containers follow, then the repaint).
///
/// Pinned on the real Windows GUI:
/// * a recorded session gui[13] / gui[14] / gui[19] (scrubbed
/// numbering; SE71 SAPMSSCF/1160, a server-windowed step loop, a painted
/// dynpro cursor): Step, SES `52 00 … <h & ff> <w & ff>`, 16/6/35, the
/// 16/4 identity atoms, 16/5/1 OK mode 0x0d over zeros, 16/12/8 = h, w,
/// h, w (u32 BE), 16/12/6 = the PAINT's SCROLL_INFOS2 echoed (it "lags":
/// the new size is not in it), 16/9/11 = the painted cursor, EOM; each
/// answered by a repaint whose 16/12/7 is the new window in kernel cells
/// (659 x 1568 px -> 29 x 224, srv[17]).
/// * a recorded session gui[2] / gui[4] (Easy Access,
/// SAPLSMTR_NAVIGATION/0100 — the tree's custom-control area, no dynpro
/// cursor): the same frame with OK mode 0x0b and the empty 16/9/10 (and
/// an item-17 CONTROLS report of the container's cached size props,
/// which GuiGo does not model on an undocked screen — the SE71 rounds
/// carry no item 17 and the server lays out from 16/12/8 alone);
/// answered srv[10] OLE flush -> srv[11] repaint 39 x 268 (868 x 1882
/// px), srv[13] 38 x 268 (853 x 1880).
/// * a recorded session g[28] (the DBA cockpit's load
/// history, docked left and below): the second 16/12/8 pair is the
/// dynpro AREA — the window less the docked panes, whose pixel extents
/// stay put (762 x 1510 / 663 x 1188 after 597 x 1161 / 498 x 839) —
/// and the server lays the screen out to it (srv[48]: 34 x 215 / 30 x
/// 169); item 17 reports the docks' extents along the window and the
/// grids' first-visible cells ([SapSession]'s resize builds it).
///
/// The first resize round after the window left its MAXIMIZED state carries
/// the outer window rect 16/4/36 after the SES (se71 gui[12], st04 none):
/// GuiGo's window is never "restored", so never.
///
/// A CFW CONTROL focus (a paint ending in a non-dialog 16/9/18 — SE38's
/// editor) is not in the corpus for this round; it follows the `%_GS 0 3`
/// layout round's focus-class rule ([windowsLayoutRoundItems],
/// a recorded session gui[26]): OK 0x0b, the paint's tabstrip echo and
/// the 16/9/18 after the 16/12/6.
library;

import 'dart:typed_data';

import '../codepages.dart';
import '../framing/envelope.dart';
import 'actions.dart';
import 'frames.dart';
import 'frontend_profile.dart';

/// The SES eventarray byte of the Windows resize round (0x50 | 0x02 — the
/// Windows dialect's event family byte with the resize bit; the Java GUI
/// spells it 0x05, which the Windows-dialect kernel refuses).
const int winSesResize = 0x52;

/// The resize round's items for [ctx]'s window (Windows dialect, ready to
/// send): its CURRENT pixels ([ActionContext.winPxHeight] /
/// [ActionContext.winPxWidth]) — the window, then the dynpro area beside
/// the docked panes ([ActionContext.windowAreaPx]: the area the server
/// lays the screen out to) — and the last paint's geometry / focus.
///
/// [xml] = the item-17 CONTROLS report of a docked screen: the docks'
/// realized extents and the grids' first-visible cells, as the layout
/// round reports them (a recorded session g[28]: 117 `300`,
/// 135 `120`, the GENERIC of 118 / 180 / 280 / 281 after the 16/9/11);
/// null = none (the SE71 rounds carry none).
List<Uint8List> windowsResizeRoundItems(ActionContext ctx, {String? xml}) {
  final ses = Uint8List(16)
    ..[0] = winSesResize
    ..[7] = ctx.modalNo & 0xff
    ..[14] = ctx.winPxHeight & 0xff
    ..[15] = ctx.winPxWidth & 0xff;
  final control = ctx.paintedControlFocus;
  final painted = control == null ? ctx.paintedFocus : null;
  final focus = painted == null ? null : windowsClientCursor(painted);
  // the focus item decides the half, the acked paint the mode
  // ([windowsOkMode]); 0x0d / 0x0b without a paint mode
  final ok = Uint8List(22)
    ..[1] = windowsOkMode(ctx,
        cursor: focus != null,
        fallback: focus != null ? winOkModeNested : winOkModeControlFocus);
  return [
    stepItem(ctx.step),
    Uint8List.fromList([itemSes, ...ses]),
    buildApplItem(6, 35, winCodepageValue),
    for (final (sid, value) in winIdentity) buildApplItem(4, sid, value),
    buildApplItem(5, 1, ok),
    buildApplItem(12, 8, ctx.windowAreaPx(ctx.winPxHeight, ctx.winPxWidth)),
    buildApplItem(12, 6, windowsPaintedGeometry(ctx, _screenGeometry(ctx))),
    if (control != null) ...[
      ...ctx.paintedTabstripEcho,
      buildApplItem(9, 18, wireText(control)),
    ] else if (focus != null)
      buildApplItem(9, 11, focus)
    else
      buildApplItem(9, 10, Uint8List(0)),
    if (xml != null) xmlBlobItem(wireText(xml)),
    eomBytes,
  ];
}

/// SCROLL_INFOS2 spelled with the negotiated screen when no paint declared
/// one (frontend_profile's okcode / key fallback).
Uint8List _screenGeometry(ActionContext ctx) {
  final out = Uint8List(33);
  final bd = ByteData.sublistView(out);
  for (final at in const [0, 8, 24]) {
    bd
      ..setUint32(at, ctx.screenRows)
      ..setUint32(at + 4, ctx.screenCols);
  }
  out[32] = 1;
  return out;
}
