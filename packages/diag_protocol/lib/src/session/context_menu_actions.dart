/// Client frames of the server-driven CFW CONTEXT MENUS (reference client
/// / raw_grid_state.control_function port): the request
/// a right-click sends, and the pick of an entry of the menu the server
/// pushed in answer (cfw/context_menu.dart decodes the push).
///
/// SapTree (simple / column / list tree) — both dialects:
///
/// * NODE request `%_GC <tree> 36` (REQUESTNODECONTEXTMENU, sapTreeS.jar
/// SapTreeEncEventAdaptor): PARAM 0 = the node key — a recorded session
/// dragdrop_ctxmenu gui[36] / [40] (Windows, SAP.TableTreeControl.1 154,
/// `Root` / `Child1`), a recorded session gui[26] / [30] / [44],
/// a recorded session gui[12] / [37] (Windows),
/// a recorded session gui[39] / [51] (Java);
/// * ITEM request `%_GC <tree> 26` (REQUESTITEMCONTEXTMENU): PARAM 0 = the
/// node key, PARAM 1 = the item (column) name — a recorded session
/// nodecreate_pick gui[23] / [25], a recorded session gui[12] / [33] /
/// [41], a recorded session gui[35] / [37]
/// (Windows column trees), a recorded session gui[122],
/// a recorded session gui[14] (Java);
/// * the PICK `%_GS <tree> 14` (the context-menu FUNCTION event), PARAM 0 =
/// the entry's FCODE (never its label) — Windows with `SHELLEVENT ="X"`
/// after EVENTID (a recorded session gui[38] / [42] `Entry1`,
/// a recorded session gui[27] `NEW_WI`, a recorded session
/// painters gui[14] `NEW_SEC`, a recorded session gui[49]
/// `CT_NEW_NODE`), Java without (a recorded session gui[124]
/// `WCRT`, a recorded session gui[16] `PR_COPY`).
///
/// The tree request carries the right-click's SELECTION change as the
/// tree's registered cached props when they changed (the jar's
/// TreeMouseListener.selectPathForEvent; changed props only): a node
/// request `ABAPSelNodeKey=<key>` (gui[36] `Root`, gui[40] `Child1`), an item
/// request on a tree that registered ABAPSelNodeKey, ABAPSelItemKey AND
/// ABAPSelItemName `ABAPSelNodeKey="" ABAPSelItemKey=<key> [TopNodeKey=
/// <top>] ABAPSelItemName=<item>` in that OCX order, TopNodeKey when the
/// tree registered it and its top node is known (a recorded session
/// gui[12] `%_GC 122 26` TopNodeKey `FORMNAME`; gui[33] / [41] and
/// smartforms gui[23] without — unchanged / unregistered; reference client 534a50c
/// §1); segw gui[35] only the key — the item name was unchanged; gui[37] /
/// smartforms gui[25] nothing — all unchanged); none at all on a tree whose
/// `DisableSelChngOnCxtMenuReq`
/// is set (a recorded session gui[26]: the server selects the node
/// itself).
///
/// * BACKGROUND request `%_GC <tree> 42` (REQUESTBACKGROUNDCONTEXTMENU):
/// NO PARAM, the selection cleared (`ABAPSelNodeKey=""` when the server
/// held a node) — a recorded session gui[7] (Easy
/// Access tree 105, which registered 36 and 42 in srv[4]);
/// * a tree that registered none of 26 / 36 / 41 / 42 sends NOTHING on a
/// right-click (a recorded session: ST03N tree 122
/// registered 15 / 25 / 18 only in srv[8]; no client frame between the
/// paint and `/nex`).
///
/// OO-ALV grid (GridView.ocx) — Windows: the request `%_GC <grid> 9` and
/// the pick `%_GC <grid> 13` ([gridEventContextMenu] /
/// [gridEventContextMenuSelected]; sap_session_context_menu.dart builds
/// them on the grid event envelope of grid_edit_actions.dart).
///
/// Designer canvas (ICDATAFLOW.ICDataFlowCtrl.1) — Windows only:
///
/// * the OBJECT PICK `%_GC <canvas> 4194304`, PARAM 0 = the canvas object
/// id (a recorded session gui[37] `1` = the MARA table header,
/// gui[53] `313` = the auto-FK link) — the right-click; the server answers
/// with the SetContextMenu queue of THAT object (srv[39] / [56]);
/// * the PICK `%_GC <canvas> 2` (CONTEXTMENUSEL), PARAM 0 = `0`, PARAM 1 =
/// the fcode (gui[39] `F_TDEL`, gui[55] `F_LDEL`) — the ABAP handler
/// dereferences PARAM 1 (reference client control_knowledge required_params).
///
/// The Windows envelope (every frame above, item for item): step, SES (no
/// event), 16/6/35, 16/12/4 okcode, the identity atoms 4/9 4/29 4/15 4/25,
/// 16/5/1 the window-state OK mode over zeros (gui[36] 0x0d: srv[46]'s
/// flat dynpro cursor on a paint declaring the named TREE_CONTAINER
/// group; 0x0b once the tree holds the focus — gui[38]),
/// 16/12/8 window pixels, the PAINTED 16/12/6 + the paint's tabstrip echo
/// (smartforms gui[23] `10/1 10/8 9/15`), the 16/15/1 control-event source
/// ONLY on a control hosted by a dynpro custom control — its container path
/// (gui[36] `0001 01` under TREE_CONTAINER, wda_context_create gui[12]
/// `0004 01020101` under CC_LAYOUT, bwadapter gui[37] `0001 01` under
/// MAIN_CONTAINER), none on a DOCKED one (smartforms gui[23], sfp gui[12],
/// segw gui[35]: no 16/15/1 at all) — then 16/9/18 = the event shell (the
/// right-click focuses it, on the first request too: gui[36] OK 0x0d with
/// `9/18 "154"`), the type-17 DATAMANAGER in the OCX spelling, EOM —
/// [windowsControlEventEnvelope] lays the OK mode, the geometry and the
/// modal shape over it.
library;

import 'dart:typed_data';

import '../codepages.dart';
import '../framing/envelope.dart';
import 'actions.dart';
import 'cfw_dialog_actions.dart' show windowsEventSes;
import 'frames.dart';
import 'frontend_profile.dart';
import 'grid_edit_actions.dart' show uiEventControlAt;

/// sapTreeS.jar SapTreeEncEventAdaptor: the context-menu request family.
const int treeEventRequestItemContextMenu = 26;
const int treeEventRequestNodeContextMenu = 36;
const int treeEventRequestHeaderContextMenu = 41;
const int treeEventRequestBackgroundContextMenu = 42;

/// The context-menu FUNCTION event a tree menu pick fires (`%_GS`).
const int contextMenuFunctionEvent = 14;

/// GridView.ocx (OO-ALV grid) ContextMenu: the right-click's request,
/// `%_GC <grid> 9` with NO PARAM — the target is the CurrentCell* /
/// selection delta riding the same DATAMANAGER (a recorded session
/// context_menu gui[12] cell, gui[18] header, gui[24] row selector).
const int gridEventContextMenu = 9;

/// GridView.ocx ContextMenuSelected: the pick, `%_GC <grid> 13` PARAM 0 =
/// the entry's fcode, no CurrentCell* / DATACHANGES (gui[16] `&OPTIMIZE`,
/// gui[22] `&SORT_ASC`; a recorded session gui[22] the
/// application entry `&MEREQDETAIL`).
const int gridEventContextMenuSelected = 13;

/// The ICDataFlow canvas object pick (the right-click hit).
const int canvasObjectPickEvent = 4194304;

/// The ICDataFlow CONTEXTMENUSEL event and its constant PARAM 0.
const int canvasContextMenuSelectEvent = 2;
const String canvasContextMenuSelectPid0 = '0';

String _attr(String v) => v
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// The DATAMANAGER of a context-menu event in the OCX spelling — byte for
/// byte a recorded session gui[36] (`<EVENT SHELLID ="154"
/// EVENTID ="36"> <PARAM PID ="0" VALUE ="Root"/></EVENT>` + ` <CONTROLS>
/// <CONTROL SHELLID ="154"> <PROPERTY VALUE ="Root" NAME
/// ="ABAPSelNodeKey"/>…`) and gui[38] (` SHELLEVENT ="X"` after EVENTID on
/// a [service] (`%_GS`) event).
String windowsContextMenuXml(
  String shell,
  int eventId,
  List<String> params, {
  bool service = false,
  Map<String, List<(String, String)>> controls = const {},
}) {
  final b = StringBuffer(
    '<?xml version="1.0" encoding="sap*"?><DATAMANAGER> <EVENTS>  '
    '<EVENT SHELLID ="${_attr(shell)}" EVENTID ="$eventId"'
    '${service ? ' SHELLEVENT ="X"' : ''}',
  );
  if (params.isEmpty) {
    b.write('/>');
  } else {
    b.write('>');
    for (var i = 0; i < params.length; i++) {
      b.write('   <PARAM PID ="$i" VALUE ="${_attr(params[i])}"/>');
    }
    b.write('</EVENT>');
  }
  b.write('</EVENTS>');
  if (controls.isNotEmpty) {
    b.write(' <CONTROLS>');
    controls.forEach((sh, props) {
      b.write('  <CONTROL SHELLID ="${_attr(sh)}">');
      for (final (n, v) in props) {
        b.write('   <PROPERTY VALUE ="${_attr(v)}" NAME ="${_attr(n)}"/>');
      }
      b.write('</CONTROL>');
    });
    b.write('</CONTROLS>');
  }
  b.write('</DATAMANAGER>');
  return b.toString();
}

/// The same DATAMANAGER in the SAP GUI for JAVA spelling — a recorded session
/// addstep_branch_java gui[122] (`<EVENT SHELLID="245" EVENTID="26"><PARAM
/// VALUE="000010" PID="0"/><PARAM VALUE="C1" PID="1"/></EVENT>`), gui[124]
/// (the pick: no SHELLEVENT), a recorded session gui[14]
/// (`<CONTROLS><CONTROL SHELLID="128"><PROPERTY VALUE=" 14"
/// NAME="ABAPSelItemKey"/>`).
String javaContextMenuXml(
  String shell,
  int eventId,
  List<String> params, {
  Map<String, List<(String, String)>> controls = const {},
}) {
  final b = StringBuffer(
    '<?xml version="1.0" encoding="sap*"?>\n<DATAMANAGER><EVENTS>'
    '<EVENT SHELLID="${_attr(shell)}" EVENTID="$eventId">',
  );
  for (var i = 0; i < params.length; i++) {
    b.write('<PARAM VALUE="${_attr(params[i])}" PID="$i"/>');
  }
  b.write('</EVENT></EVENTS>');
  if (controls.isNotEmpty) {
    b.write('<CONTROLS>');
    controls.forEach((sh, props) {
      b.write('<CONTROL SHELLID="${_attr(sh)}">');
      for (final (n, v) in props) {
        b.write('<PROPERTY VALUE="${_attr(v)}" NAME="${_attr(n)}"/>');
      }
      b.write('</CONTROL>');
    });
    b.write('</CONTROLS>');
  }
  b.write('</DATAMANAGER>');
  return b.toString();
}

Uint8List _u32s(List<int> v) {
  final out = Uint8List(4 * v.length);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < v.length; i++) {
    bd.setUint32(4 * i, v[i]);
  }
  return out;
}

/// A Windows context-menu event round (see the library doc): `%_GC` (or
/// `%_GS` with [service]) `<shell> <eventId>` with [params], the
/// [controls] cached-prop delta, and the 16/15/1 at [sourcePath] — null =
/// a docked control, no 16/15/1. The OK mode is the window state's
/// ([windowsWindowStateOkMode]) — the request round's too: a flat dynpro
/// cursor goes out 0x0d on these screens because their paint declares a
/// named container (gui[36] TREE_CONTAINER), not because of the
/// right-click (reference client 534a50c §2).
List<Uint8List> windowsContextMenuEventItems(
  ActionContext ctx, {
  required String shell,
  required int eventId,
  required List<String> params,
  bool service = false,
  Map<String, List<(String, String)>> controls = const {},
  List<int>? sourcePath,
}) => windowsControlEventEnvelope(
  [
    stepItem(ctx.step),
    windowsEventSes(ctx),
    buildApplItem(6, 35, winCodepageValue),
    buildApplItem(
      12,
      4,
      wireText('${service ? '%_GS' : '%_GC'} $shell $eventId'),
    ),
    for (final (sid, value) in winIdentity) buildApplItem(4, sid, value),
    buildApplItem(5, 1, Uint8List(22)), // the window-state mode: the envelope
    buildApplItem(
      12,
      8,
      _u32s([ctx.winPxHeight, ctx.winPxWidth, ctx.winPxHeight, ctx.winPxWidth]),
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
    if (sourcePath != null) buildApplItem(15, 1, uiEventControlAt(sourcePath)),
    buildApplItem(9, 18, wireText(shell)),
    xmlBlobItem(
      wireText(
        windowsContextMenuXml(
          shell,
          eventId,
          params,
          service: service,
          controls: controls,
        ),
      ),
    ),
    eomBytes,
  ],
  ctx,
);

/// A Java context-menu event round: the tree event round (16/9/18 = the
/// tree, a recorded session gui[122] / [124]) with the
/// okcode `%_GC` / `%_GS` and the Java DATAMANAGER.
List<Uint8List> javaContextMenuEventItems(
  ActionContext ctx, {
  required String shell,
  required int eventId,
  required List<String> params,
  bool service = false,
  Map<String, List<(String, String)>> controls = const {},
}) {
  final out = <Uint8List>[];
  for (final raw in treeEventItems(
    ctx,
    shell: shell,
    eventId: eventId,
    nodeKey: params.isEmpty ? '' : params.first,
  )) {
    final w = walkItems(raw).items;
    final it = w.length == 1 ? w.single : null;
    if (it != null && it.isAppl && it.id == 12 && it.sid == 4) {
      out.add(
        buildApplItem(
          12,
          4,
          wireText('${service ? '%_GS' : '%_GC'} $shell $eventId'),
        ),
      );
    } else if (it != null && it.type == itemXmlBlob) {
      out.add(
        xmlBlobItem(
          Uint8List.fromList(
            javaContextMenuXml(
              shell,
              eventId,
              params,
              controls: controls,
            ).codeUnits,
          ),
        ),
      );
    } else {
      out.add(raw);
    }
  }
  return out;
}

/// A tree's context-menu REQUEST: the node request (36) or, with
/// [itemName], the item request (26).
List<Uint8List> treeContextMenuRequestItems(
  ActionContext ctx, {
  required String shell,
  required String nodeKey,
  String? itemName,
  Map<String, List<(String, String)>> controls = const {},
  List<int>? sourcePath,
  bool windows = true,
}) {
  final ev = itemName == null
      ? treeEventRequestNodeContextMenu
      : treeEventRequestItemContextMenu;
  final params = [nodeKey, if (itemName != null) itemName];
  return windows
      ? windowsContextMenuEventItems(
          ctx,
          shell: shell,
          eventId: ev,
          params: params,
          controls: controls,
          sourcePath: sourcePath,
        )
      : javaContextMenuEventItems(
          ctx,
          shell: shell,
          eventId: ev,
          params: params,
          controls: controls,
        );
}

/// A tree's BACKGROUND request `%_GC <tree> 42` (REQUESTBACKGROUNDCONTEXT
/// MENU, the OCX's ABAPContextMenuEmptyClient): an empty EVENT element, no
/// PARAM — a recorded session gui[7] `%_GC 105 42`
/// with the cleared selection `ABAPSelNodeKey=""` as its [controls].
/// Windows only (no Java capture).
List<Uint8List> treeBackgroundContextMenuRequestItems(
  ActionContext ctx, {
  required String shell,
  Map<String, List<(String, String)>> controls = const {},
  List<int>? sourcePath,
}) => windowsContextMenuEventItems(
  ctx,
  shell: shell,
  eventId: treeEventRequestBackgroundContextMenu,
  params: const [],
  controls: controls,
  sourcePath: sourcePath,
);

/// A tree menu PICK: `%_GS <tree> 14` PARAM 0 = [fcode].
List<Uint8List> treeContextMenuPickItems(
  ActionContext ctx, {
  required String shell,
  required String fcode,
  List<int>? sourcePath,
  bool windows = true,
}) => windows
    ? windowsContextMenuEventItems(
        ctx,
        shell: shell,
        eventId: contextMenuFunctionEvent,
        params: [fcode],
        service: true,
        sourcePath: sourcePath,
      )
    : javaContextMenuEventItems(
        ctx,
        shell: shell,
        eventId: contextMenuFunctionEvent,
        params: [fcode],
        service: true,
      );

/// The canvas OBJECT PICK (the right-click on object [objectId]).
List<Uint8List> canvasContextMenuRequestItems(
  ActionContext ctx, {
  required String shell,
  required String objectId,
  List<int>? sourcePath,
}) => windowsContextMenuEventItems(
  ctx,
  shell: shell,
  eventId: canvasObjectPickEvent,
  params: [objectId],
  sourcePath: sourcePath,
);

/// The canvas menu PICK: `%_GC <canvas> 2` PARAMs `0`, [fcode].
List<Uint8List> canvasContextMenuPickItems(
  ActionContext ctx, {
  required String shell,
  required String fcode,
  List<int>? sourcePath,
}) => windowsContextMenuEventItems(
  ctx,
  shell: shell,
  eventId: canvasContextMenuSelectEvent,
  params: [canvasContextMenuSelectPid0, fcode],
  sourcePath: sourcePath,
);
