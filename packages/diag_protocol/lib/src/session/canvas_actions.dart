/// Client frames of the designer-canvas gestures, in the real SAP GUI for
/// Windows spelling (Windows OCX dialect only — ICDataFlow.ocx /
/// wdbdadpt.ocx have no Java-GUI counterpart):
///
/// * the DROP of a tree row on the canvas — the bare CFW GuiService event
/// `%_GS <target> 15` with `SHELLEVENT="X"` and no PARAM
/// (a recorded session gui[8] / gui[14]); everything about the
/// drop is then READ by the server through the SAPGUIService.DragDrop.1
/// poll (dragdrop_service.dart);
/// * the LINK draw node -> node — the ICDataFlow OCX event `%_GC <shell>
/// 1048576` (`OnNewLinkCreated(NewLink_Id, SrcObjId, DestObjId)`) with
/// PARAMs `(2147483647, src, dst)` (a recorded session gui[8] /
/// gui[11]);
/// * the DOUBLE CLICK on a table or row — `%_GC <shell> 32`
/// (OnLeftButtonDblClk, a recorded session gui[51] / [52]; see
/// [canvasDoubleClickEvent]); a single click sends nothing on every
/// recorded canvas ([canvasObjectSelectedEvent]).
///
/// The drop and the link draw are the real GUI's control-event round
/// (a recorded session' `%_GC` frame, [windowsActionItems] with
/// `controlEvent: true`: 4/38, SES, 6/35, 12/4, 4/9, 4/29, 4/15, 4/25, 5/1,
/// 12/8, 12/6, 15/1, <focus>, type-17 XML, EOM). The focus item is what the
/// two captures differ in: the drop names the dragged-from tree as the
/// focused shell (`9/18 = 116` — the mouse-down on the row focused it, on
/// both drops), the link draw carries no focused shell (`9/10`, empty).
/// The DATAMANAGER XML is spelled exactly as the Windows GUI writes it
/// (` ="` attribute separators, one/two/three-blank indentation, no line
/// breaks, no trailing NUL) — byte-identical to gui[14] / gui[11].
library;

import 'dart:convert';
import 'dart:typed_data';

import '../codepages.dart';
import '../framing/envelope.dart';
import 'actions.dart';
import 'context_menu_actions.dart' show windowsContextMenuEventItems;
import 'frontend_profile.dart';

const String _xmlDecl = '<?xml version="1.0" encoding="sap*"?>';

String _attr(String v) => v
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// The ` <CONTROLS>…</CONTROLS>` block of a Windows event XML: one CONTROL
/// per shell, its changed cached props (a recorded session gui[8]
/// `<CONTROL SHELLID ="115"> <PROPERTY VALUE ="459" NAME ="120"/>…`).
String _controlsXml(Map<String, List<(String, String)>> controls) {
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

/// The DATAMANAGER XML of a canvas drop: `<EVENT SHELLID ="<target>"
/// EVENTID ="15" SHELLEVENT ="X"/>` plus the [controls] whose cached props
/// changed with the drop (a single-select source tree's ABAPSelNodeKey).
Uint8List canvasDropXml(
  String targetShell, {
  Map<String, List<(String, String)>> controls = const {},
}) => Uint8List.fromList(
  utf8.encode(
    '$_xmlDecl<DATAMANAGER> <EVENTS>  <EVENT SHELLID ="${_attr(targetShell)}" '
    'EVENTID ="15" SHELLEVENT ="X"/></EVENTS>'
    '${_controlsXml(controls)}</DATAMANAGER>',
  ),
);

/// The `NewLink_Id` placeholder of a link draw: the server allocates the
/// link id (63 / 64 on the capture).
const String canvasNewLinkPlaceholder = '2147483647';

/// The DATAMANAGER XML of a node -> node link draw on the ICDataFlow shell
/// (plus [controls] whose cached props changed with it).
Uint8List canvasConnectXml(
  String shell,
  String srcObjId,
  String dstObjId, {
  Map<String, List<(String, String)>> controls = const {},
}) => Uint8List.fromList(
  utf8.encode(
    '$_xmlDecl<DATAMANAGER> <EVENTS>  <EVENT SHELLID ="${_attr(shell)}" '
    'EVENTID ="1048576">'
    '   <PARAM PID ="0" VALUE ="$canvasNewLinkPlaceholder"/>'
    '   <PARAM PID ="1" VALUE ="${_attr(srcObjId)}"/>'
    '   <PARAM PID ="2" VALUE ="${_attr(dstObjId)}"/>'
    '</EVENT></EVENTS>${_controlsXml(controls)}</DATAMANAGER>',
  ),
);

/// A Windows control-event round carrying [okcode] and [xml]: the tree
/// event round re-spelled for Windows, its okcode / XML swapped, and the
/// focus item = `9/18 <focusShell>`, or `9/10` (no focused shell) when
/// [focusShell] is null. The items are already in the Windows dialect.
///
/// [sourcePath] = the container path of the dynpro custom control hosting
/// the event's control: the 16/15/1 control-event source then carries it
/// (an editor's events — a recorded session gui[75] `01 02 01` on
/// SE37's SOURCE tab, gui[32] `01` on SE38, gui[138] `01 02 01 01`); null
/// = a control no painted custom control hosts: NO 16/15/1 (reference client
/// 534a50c §3 — never a default `01`). [okMode] overrides the window-state
/// OK mode (an editor event is 0x0b: reference client reshape_editor_event_items).
List<Uint8List> canvasEventItems(
  ActionContext ctx, {
  required String okcode,
  required Uint8List xml,
  String? focusShell,
  List<int>? sourcePath,
  int? okMode,
}) {
  final java = treeEventItems(
    ctx,
    shell: focusShell ?? '0',
    eventId: 0,
    nodeKey: '',
  );
  final out = <Uint8List>[];
  for (final raw in windowsActionItems(
    java,
    controlEvent: true,
    controlSourcePath: sourcePath,
    ctx: ctx,
  )) {
    final walk = walkItems(raw);
    final it = walk.items.length == 1 ? walk.items.single : null;
    if (it != null && it.isAppl && it.id == 12 && it.sid == 4) {
      out.add(buildApplItem(12, 4, wireText(okcode)));
    } else if (it != null && it.type == itemXmlBlob) {
      out.add(xmlBlobItem(xml));
    } else if (it != null && it.isAppl && it.id == 9 && it.sid == 18) {
      out.add(
        focusShell == null
            ? buildApplItem(9, 10, Uint8List(0))
            : buildApplItem(9, 18, wireText(focusShell)),
      );
    } else if (okMode != null &&
        it != null &&
        it.isAppl &&
        it.id == 5 &&
        it.sid == 1) {
      out.add(buildApplItem(5, 1, Uint8List(it.value.length)..[1] = okMode));
    } else {
      out.add(raw);
    }
  }
  return out;
}

/// The drop of a tree row on canvas [targetShell]: `%_GS <target> 15`,
/// the drag-source tree [sourceShell] as the focused shell.
List<Uint8List> canvasDropItems(
  ActionContext ctx, {
  required String targetShell,
  required String sourceShell,
  Map<String, List<(String, String)>> controls = const {},
  List<int>? sourcePath,
}) => canvasEventItems(
  ctx,
  okcode: '%_GS $targetShell 15',
  xml: canvasDropXml(targetShell, controls: controls),
  focusShell: sourceShell,
  sourcePath: sourcePath,
);

/// The node -> node link draw on the ICDataFlow [shell]:
/// `%_GC <shell> 1048576` with `(2147483647, src, dst)`.
List<Uint8List> canvasConnectItems(
  ActionContext ctx, {
  required String shell,
  required String srcObjId,
  required String dstObjId,
  Map<String, List<(String, String)>> controls = const {},
  List<int>? sourcePath,
}) => canvasEventItems(
  ctx,
  okcode: '%_GC $shell 1048576',
  xml: canvasConnectXml(shell, srcObjId, dstObjId, controls: controls),
  sourcePath: sourcePath,
);

// ---------------------------------------------------------------------------
// Clicks on the canvas (ICDataFlow.ocx `_DICDataFlowEvents`)
// ---------------------------------------------------------------------------
//
// The wire EVENTID of an ICDataFlow event is its `EnabledEvents` mask bit
// (`RegisterOcxEvent(<shell>, <mask>)`). Four masks are on the wire with a
// gesture attached, and they place the typelib's event list on the bits:
// 2 = ContextMenuSelected (the menu pick, a recorded session gui[33]),
// 32 = OnLeftButtonDblClk (below), 1048576 = OnNewLinkCreated
// (a recorded session gui[8]), 4194304 = ContextMenuRequest (the
// right-click: every recorded one is the narrated right-click —
// a recorded session gui[53] / [65] / [67] = the MARA header, the link,
// the empty canvas `-1` — and most are followed by a 2 pick). Read in
// typelib order (ICDataFlow.ocx string table: OnObjectDblClk,
// ContextMenuSelected, OnLeftButtonDown, …, OnObjectSelected, OnObjectMoved)
// the same bits make 2048 = OnLinkLeftButtonDblClk and 134217728 =
// OnObjectSelected — registered by RSNPG_TEST_NETPLAN1's shell 122
// (a recorded session srv[8]) but by none of the SQVI / SQ02
// canvases, and on no recorded wire.

/// OnLeftButtonDblClk — a double click on a table (its header) or on one of
/// its rows. PARAMs `(table id, row id, column, area, x, y)`:
/// a recorded session gui[51] `1, -1, -1, 2, 176, 11` (the narrated
/// double click on the MARA header: nothing happened), gui[52] `1, 15, 2, 3,
/// 48, 174` (on the MEINS row — object 15 — the server answered with the
/// field documentation, srv[57]); a recorded session gui[63] / [67] /
/// [69] (`1, 29, 2, 3, 35, 528`, `308, 310, 2, 3, 48, 64`, `1, 42, 2, 3, 27,
/// 487`, each answered by the SAPLAQSF/0120 field-info popup). The right
/// click on the MARA header (a recorded session gui[53]) fires no 32
/// although that canvas registered it — 32 is the double click, not a
/// button-down. PARAM 2 = the clicked cell's column (the MEINS row's field
/// name is its `Tables` column 2: col_0 key icon, col_2 name, col_3 text);
/// PARAM 3 = 2 on the header, 3 on a row cell; PARAM 4/5 = the pointer —
/// pixels, origin not pinned (no recorded handler reads them).
const int canvasDoubleClickEvent = 32;

/// PARAM 3 of [canvasDoubleClickEvent]: the table header / a row cell.
const String canvasHitHeader = '2';
const String canvasHitCell = '3';

/// OnLinkLeftButtonDblClk (mask 2048): registered by the net-plan canvas,
/// on no capture — the SQ02 link double click (a recorded session §7)
/// fired nothing on a canvas that did not register it.
const int canvasLinkDoubleClickEvent = 2048;

/// OnObjectSelected (mask 134217728, `ObjectId, ObjectType`): registered by
/// the net-plan canvas, on no capture. The SQVI / SQ02 canvases register no
/// selection event: a single click there is wire-silent (every left click
/// of a recorded session / a recorded session sends nothing).
const int canvasObjectSelectedEvent = 134217728;

/// The PARAMs of a double click on table [tableId]'s header ([rowId] null)
/// or on its row [rowId] in [column], at pointer ([x], [y]).
List<String> canvasDoubleClickParams({
  required String tableId,
  String? rowId,
  int column = 0,
  int x = 0,
  int y = 0,
}) => rowId == null
    ? [tableId, '-1', '-1', canvasHitHeader, '$x', '$y']
    : [tableId, rowId, '$column', canvasHitCell, '$x', '$y'];

/// The double-click round on the ICDataFlow [shell]: `%_GC <shell> 32`
/// with [params] ([canvasDoubleClickParams]); the click focuses the canvas
/// (`9/18 <shell>`), the 16/15/1 names its container ([sourcePath]) —
/// item for item a recorded session gui[51] / [52] and
/// a recorded session gui[63] (the context-menu round's envelope,
/// [windowsContextMenuEventItems], with the window-state OK mode).
List<Uint8List> canvasDoubleClickItems(
  ActionContext ctx, {
  required String shell,
  required List<String> params,
  List<int>? sourcePath,
}) => windowsContextMenuEventItems(
  ctx,
  shell: shell,
  eventId: canvasDoubleClickEvent,
  params: params,
  sourcePath: sourcePath,
);
