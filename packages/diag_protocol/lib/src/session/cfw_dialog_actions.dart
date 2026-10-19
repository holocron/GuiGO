/// Client frames of the CFW modal dialog / HTML viewer gestures and of F1
/// on a field, in the real SAP GUI for Windows spelling.
///
/// * a CFW toolbar button (SAP.Toolbar.1 — the F1 Performance Assistant's
/// BACK / FORW / FIND / TECH / PRINT / CLOSE …): `%_GC <toolbar> 1` with
/// PARAM 0 = the button code — the real GUI's TECH click,
/// a recorded session gui[119] (scrubbed; raw 122): 4/38, a SES
/// without an event (dims = the window pixels' low bytes), 6/35, 12/4,
/// the identity atoms 4/9 4/29 4/15 4/25, the OK event mode 0x05 over
/// zeros, 12/8 window pixels, 12/6 SCROLL_INFOS2, the painted cursor
/// 16/9/11 (no 16/15/1, no 9/18), the type-17 EVENTS XML in the OCX's
/// `NAME ="value"` spelling, EOM;
/// * the dialog's X button: `%_GC <dialog> 8` with no PARAM (the reference client's
/// raw_dialogs.dialog_close: GuiDialogShell DIALOG_CLOSE = 8, the event
/// the dialog's RegisterEvent(…, 8) asks for) in the same frame;
/// * a `SAPEVENT:` link in the viewer: `%_GC <viewer> 1` with the
/// non-empty PARAMs of 0 = the anchor's target frame, 1 = '0' (a GET),
/// 2 = the url as the href spells it (a recorded session
/// raw gui[10], [htmlLinkItems]); a FORM submit: 0 = the form's frame,
/// 1 = the POST length, 2 = `sapevent:<form>` (a recorded session
/// raw gui[27], [htmlFormSubmitItems]);
/// * F1 on a field: the key round with the HELP UI_EVENT_SOURCE — event
/// type 2 on a FIELD at the field's cell — and the cursor on that cell
/// (a recorded session gui[113], raw 116: F1 on FB03's document
/// number, `02 0002 0001 00 000000 0003 0019 0001 00` + 16/9/11
/// `01 0003 0019 00000001 00`).
library;

import 'dart:typed_data';

import '../codepages.dart';
import '../framing/envelope.dart';
import 'actions.dart';
import 'frames.dart';
import 'frontend_profile.dart';
import 'grid_edit_actions.dart' show uiEventControlAt;

/// The CFW dialog's close event (GuiDialogShell DIALOG_CLOSE).
const int cfwDialogCloseEvent = 8;

/// The HTML viewer's SAPEVENT navigation event and the target frame the
/// real JAVA GUI names (a recorded session gui[38]; the Windows
/// OCX names the form's own frame, [htmlFormSubmitItems]).
const int htmlSapEvent = 1;
const String htmlTargetFrame = 'frame0';

String _attr(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// The ` <CONTROLS>…</CONTROLS>` block of a Windows event XML: one CONTROL
/// per shell with the cached props it reports (a recorded session
/// gui[6]: ` <CONTROLS> <CONTROL SHELLID ="115"> <PROPERTY VALUE ="141"
/// NAME ="120"/> <PROPERTY VALUE ="327" NAME ="300"/></CONTROL>
/// </CONTROLS>`, the calendar's container after its EVENTS); empty for none.
String cfwControlsXml(Map<String, List<(String, String)>> controls) {
  if (controls.isEmpty) return '';
  final b = StringBuffer(' <CONTROLS>');
  controls.forEach((shell, props) {
    b.write('  <CONTROL SHELLID ="${_attr(shell)}">');
    for (final (name, value) in props) {
      b.write('   <PROPERTY VALUE ="${_attr(value)}" NAME ="${_attr(name)}"/>');
    }
    b.write('</CONTROL>');
  });
  b.write('</CONTROLS>');
  return b.toString();
}

/// The OCX spelling of an EVENTS block (gui[119]: `<EVENT SHELLID ="124"
/// EVENTID ="1"> <PARAM PID ="0" VALUE ="TECH"/></EVENT>`), then the
/// [controls] cached-prop report ([cfwControlsXml]). [omitEmpty]: only
/// the non-empty PARAMs, each under its own PID (the HTML OCX's
/// DoSAPEVENT — a recorded session raw gui[10]: PID1 / PID2
/// alone, no PID0 for an untargeted link, no PID3..9).
Uint8List cfwEventXml(
  String shell,
  int eventId,
  List<String> params, {
  Map<String, List<(String, String)>> controls = const {},
  bool omitEmpty = false,
}) {
  final b = StringBuffer(
    '<?xml version="1.0" encoding="sap*"?><DATAMANAGER> <EVENTS>  '
    '<EVENT SHELLID ="${_attr(shell)}" EVENTID ="$eventId"',
  );
  if (params.isEmpty || (omitEmpty && params.every((p) => p.isEmpty))) {
    b.write('/>');
  } else {
    b.write('>');
    for (var i = 0; i < params.length; i++) {
      if (omitEmpty && params[i].isEmpty) continue;
      b.write('   <PARAM PID ="$i" VALUE ="${_attr(params[i])}"/>');
    }
    b.write('</EVENT>');
  }
  b.write('</EVENTS>${cfwControlsXml(controls)}</DATAMANAGER>');
  return wireText(b.toString());
}

Uint8List _u32s(List<int> v) {
  final out = Uint8List(4 * v.length);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < v.length; i++) {
    bd.setUint32(4 * i, v[i]);
  }
  return out;
}

Uint8List _ses(ActionContext ctx, {int eventArray = 0, int vkey = 0}) {
  final ses = Uint8List(16);
  ses[0] = eventArray;
  ses[1] = vkey & 0xff;
  ses[7] = ctx.modalNo & 0xff;
  if (ctx.modalNo != 0) {
    ses[8] = ctx.modalX & 0xff;
    ses[9] = ctx.modalY & 0xff;
  }
  ses[14] = ctx.winPxHeight & 0xff;
  ses[15] = ctx.winPxWidth & 0xff;
  return Uint8List.fromList([itemSes, ...ses]);
}

/// The SES item of a Windows CFW event round (no event, no key): the modal
/// level and popup position, the window pixels' low bytes — shared by the
/// value-help and grid event builders (value_help_actions.dart,
/// grid_edit_actions.dart).
Uint8List windowsEventSes(ActionContext ctx) => _ses(ctx);

List<Uint8List> _tail(ActionContext ctx) => [
  // F1 on a field ([fieldHelpItems]) names its 16/9/11: the cursor half of
  // the acked paint ([windowsOkMode]), 0x05 without one (an event round's
  // mode is the envelope's, [windowsControlEventEnvelope])
  buildApplItem(
    5,
    1,
    Uint8List(22)..[1] = windowsOkMode(ctx, cursor: true, fallback: 0x05),
  ),
  buildApplItem(
    12,
    ctx.modalNo != 0 ? 14 : 8,
    ctx.windowAreaPx(ctx.winPxHeight, ctx.winPxWidth),
  ),
  buildApplItem(
    12,
    6,
    Uint8List.fromList([
      ..._u32s([ctx.screenRows, ctx.screenCols, ctx.screenRows]),
      ..._u32s([ctx.screenCols, 0, 0, ctx.screenRows, ctx.screenCols]),
      1,
    ]),
  ),
];

/// The painted cursor the round echoes, in its CLIENT form
/// ([windowsClientCursor]: a nested cursor without its painted trailing
/// zero level — every Windows `%_GC` event of the corpus on a nested
/// painted cursor sends it so, a recorded session gui[59] / [130],
/// never the server form), else the zero cursor.
Uint8List _focus(ActionContext ctx) {
  final p = ctx.paintedFocus;
  if (p != null && p.length >= 10) return windowsClientCursor(p);
  return Uint8List(10)..[0] = 1;
}

/// A Windows CFW control event `%_GC <shell> <eventId>` with [params]
/// (see the library doc: a recorded session gui[119]), in the
/// generic Windows control-event envelope ([windowsControlEventEnvelope],
/// reference client edfd931): the window-state OK mode (gui[119]: 0x05 — FB03's flat
/// painted cursor), the PAINTED 16/12/6 (gui[119] = srv[…]'s `6 x 53 …
/// 26 x 10c`) and the paint's tabstrip echo after it, no 16/12/8 in a
/// modal and the 16/4/36 after the okcode when owed
/// ([windowsModalWindowRectOwed]). The focus item stays the current
/// 16/9/11 (gui[119]; su53 gui[271] names the viewer `16/9/18 "122"` on
/// the same TECH click — which control holds the keyboard focus is
/// unsettled, the reference client sends the event shell). [sourcePath] = the path of
/// the painted custom control the event shell was LinkContainer'd into:
/// the 16/15/1 control-event source right before the focus slot; null (a
/// docked / dialog-hosted control — gui[119], su53 gui[271]) = none
/// (reference client 534a50c §3, hosted_control_event_source). [focusShell] = the
/// control holding the keyboard focus: `16/9/18 <shell>` in place of the
/// 16/9/11 (the calendar pick, a recorded session gui[6] `16/9/18
/// "116"` = the event shell, the popup's painted control focus);
/// [controls] = the cached props reported after the EVENTS
/// ([cfwControlsXml]).
List<Uint8List> cfwEventItems(
  ActionContext ctx, {
  required String shell,
  required int eventId,
  List<String> params = const [],
  List<int>? sourcePath,
  String? focusShell,
  Map<String, List<(String, String)>> controls = const {},
  bool omitEmptyParams = false,
}) => windowsControlEventEnvelope([
  stepItem(ctx.step),
  _ses(ctx),
  buildApplItem(6, 35, winCodepageValue),
  buildApplItem(12, 4, wireText(cfwGenericEventOkcode(shell, eventId))),
  for (final (sid, value) in winIdentity) buildApplItem(4, sid, value),
  ..._tail(ctx),
  if (sourcePath != null) buildApplItem(15, 1, uiEventControlAt(sourcePath)),
  if (focusShell != null)
    buildApplItem(9, 18, wireText(focusShell))
  else
    buildApplItem(9, 11, _focus(ctx)),
  xmlBlobItem(
    cfwEventXml(
      shell,
      eventId,
      params,
      controls: controls,
      omitEmpty: omitEmptyParams,
    ),
  ),
  eomBytes,
], ctx);

/// A CFW toolbar button click: `%_GC <toolbar> 1`, PARAM 0 = [code].
List<Uint8List> cfwToolbarButtonItems(
  ActionContext ctx, {
  required String toolbarShell,
  required String code,
  List<int>? sourcePath,
}) => cfwEventItems(
  ctx,
  shell: toolbarShell,
  eventId: 1,
  params: [code],
  sourcePath: sourcePath,
);

/// The X of a CFW modal dialog: `%_GC <dialog> 8`, no PARAM.
List<Uint8List> cfwDialogCloseItems(
  ActionContext ctx, {
  required String dialogShell,
}) => cfwEventItems(ctx, shell: dialogShell, eventId: cfwDialogCloseEvent);

/// A `SAPEVENT:` link followed in the HTML viewer [viewerShell]: the
/// Windows OCX's DoSAPEVENT(FrameName, PostDataLen, ppURL1) with only the
/// non-empty PARAMs — PID1 `0` (a GET, no body), PID2 = the href verbatim,
/// PID0 = the anchor's own `target=` frame and absent when it names none
/// (real SAP GUI for Windows, a recorded session raw gui[10]:
/// `<PARAM PID ="1" VALUE ="0"/> <PARAM PID ="2" VALUE
/// ="SAPEVENT:A1F1L4"/>` for an untargeted anchor inside Frame0). The
/// click put the focus in the viewer: 16/9/18 <viewer>, no 16/9/11.
List<Uint8List> htmlLinkItems(
  ActionContext ctx, {
  required String viewerShell,
  required String url,
  String frame = '',
  List<int>? sourcePath,
}) => cfwEventItems(
  ctx,
  shell: viewerShell,
  eventId: htmlSapEvent,
  params: [frame, '0', url],
  sourcePath: sourcePath,
  focusShell: viewerShell,
  omitEmptyParams: true,
);

/// A `SAPEVENT:` form submitted in the HTML viewer [viewerShell] (a
/// dynamic document's button — the page's ButtonClick script submits the
/// form): the Windows OCX's DoSAPEVENT(FrameName, PostDataLen, ppURL1) —
/// PID0 [frame] (the frame the form's page is shown in, absent when '' as
/// a link's), PID1 the POST body's byte length [postLength], PID2 [url]
/// (the action, scheme lower-cased: [SapHtmlForm.windowsUrl] — IE; the
/// Edge control: no frame, the action verbatim, [SapHtmlForm.submitUrl] /
/// [SapHtmlForm.submitFrame], a recorded session raw
/// gui[30] `<PARAM PID ="1" VALUE ="65"/> <PARAM PID ="2" VALUE
/// ="SAPEVENT:A1F1"/>`), no PID3..9;
/// the source 16/15/1 at the viewer's custom-control area, the focus IN
/// the viewer (16/9/18). Real SAP GUI for Windows, a recorded session
/// raw gui[27]: `<PARAM PID ="0" VALUE ="Frame0"/> <PARAM PID ="1"
/// VALUE ="65"/> <PARAM PID ="2" VALUE ="sapevent:A1F1"/>` for
/// /AIF/IFMON's BT_SELECTDT. The body goes up on the server's PostData
/// pull ([htmlWindowsPostAnswer]).
List<Uint8List> htmlFormSubmitItems(
  ActionContext ctx, {
  required String viewerShell,
  required String url,
  required int postLength,
  String frame = '',
  List<int>? sourcePath,
}) => cfwEventItems(
  ctx,
  shell: viewerShell,
  eventId: htmlSapEvent,
  params: [frame, '$postLength', url],
  sourcePath: sourcePath,
  focusShell: viewerShell,
  omitEmptyParams: true,
);

/// The Windows 16/15/1 of F1 on a field: flags 0x02, event type 2 (help),
/// control type 1 (FIELD), no event data, the field's row / col, one
/// container, the modal flag (gui[113] `02 0002 0001 00 000000 0003 0019
/// 0001 00`).
Uint8List uiEventFieldHelpWindows({
  required int row,
  required int col,
  bool modal = false,
}) {
  final v = Uint8List(16);
  v[0] = 0x02;
  v[2] = 0x02;
  v[4] = 0x01;
  final bd = ByteData.sublistView(v);
  bd.setUint16(9, row & 0xffff);
  bd.setUint16(11, col & 0xffff);
  v[14] = 1;
  v[15] = modal ? 1 : 0;
  return v;
}

/// The 16/9/11 cursor ON a field: depth = the path length, the cell, the
/// caret offset, the container path.
Uint8List _fieldFocus(int row, int col, List<int> path, int caret) {
  final focus = Uint8List(9 + path.length);
  focus[0] = path.length;
  final bd = ByteData.sublistView(focus);
  bd.setUint16(1, row);
  bd.setUint16(3, col);
  bd.setUint32(5, caret);
  focus.setRange(9, focus.length, path);
  return focus;
}

/// F1 on a field in the SAP GUI for JAVA spelling (the real Java GUI's F1:
/// a recorded session gui[24] — SES `01 01`, the FUNCTIONKEY 16/15/1
/// `08 0007 000a 01 …` and the 16/9/11 cursor ON the field, `01 0000 0019
/// 00000000 01`, in place of the bare key round's empty 16/9/10; the
/// Windows form is [fieldHelpItems]. NB: a recorded session is a WINDOWS
/// capture, not the Java oracle — reference client ba50b32).
List<Uint8List> fieldHelpItemsJava(
  ActionContext ctx, {
  required int row,
  required int col,
  List<int> path = const [0],
  int caret = 0,
}) => [
  for (final raw in pressItems(ctx, 1))
    if (raw.isNotEmpty && raw[0] == itemSes)
      // the Java FKEY eventarray (gui[24] `01 01`), not the Windows 0x50
      Uint8List.fromList(raw)..[1] = 0x01
    else if (raw.length >= 3 &&
        raw[0] == itemAppl &&
        raw[1] == 9 &&
        raw[2] == 10)
      ...[
        buildApplItem(15, 1, uiEventFunctionKeyJava(1)),
        buildApplItem(9, 11, _fieldFocus(row, col, path, caret)),
      ]
    else
      raw,
];

/// F1 on the field at the wire cell ([row], [col]) of container [path]
/// (the field's routing chain; `[area]` on a plain dynpro): the key round
/// SES 0x50 / vkey 1 with the help event and the cursor ON the field —
/// [caret] = the cursor offset inside it (gui[113]: 1).
List<Uint8List> fieldHelpItems(
  ActionContext ctx, {
  required int row,
  required int col,
  List<int> path = const [0],
  int caret = 0,
}) {
  final focus = _fieldFocus(row, col, path, caret);
  return [
    stepItem(ctx.step),
    _ses(ctx, eventArray: 0x50, vkey: 1),
    buildApplItem(6, 35, winCodepageValue),
    for (final (sid, value) in winIdentity) buildApplItem(4, sid, value),
    for (final raw in _tail(ctx))
      // the PAINTED main 16/12/6 (gui[113] = FB03's `6 x 53 … 26 x 10c`)
      if (raw[1] == 12 && raw[2] == 6)
        buildApplItem(
          12,
          6,
          windowsPaintedGeometry(ctx, Uint8List.sublistView(raw, 5)),
        )
      else
        raw,
    buildApplItem(
      15,
      1,
      uiEventFieldHelpWindows(row: row, col: col, modal: ctx.modalNo != 0),
    ),
    buildApplItem(9, 11, focus),
    xmlBlobItem(liveMetricsXml(ctx.screenRows, ctx.screenCols)),
    eomBytes,
  ];
}
