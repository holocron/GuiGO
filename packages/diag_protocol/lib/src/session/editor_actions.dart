/// Client frames of the source-editor gestures on the ABAP editor
/// (`SAPGUI.AbapEditor.1`) and TextEdit controls, Windows dialect.
///
/// * a cursor-keyed function key (session breakpoint Ctrl+Shift+F12 =
/// vkey 48, where-used Ctrl+Shift+F3 = vkey 39): the key round with the
/// editor's cursor as its cached properties (`FirstVisibleLine`,
/// `SelPosStart/EndLine/Col` — the props the editor registered at
/// creation) under `<CONTROLS>`. Two spellings:
/// - [EditorKeyFocus.dynpro]: the reference client's round — the Windows key
/// round as built (16/15/1 + the painted 16/9/11 field cursor), the
/// live METRICS XML with the CONTROLS block appended (live the test system,
/// a recorded session step 32: answered by
/// `SetMarker(2, ",378")`, the breakpoint). The breakpoint keys now
/// go out as the real GUI's bare key round in the editor with only
/// the owed props ([editorFocusKeyItems]: a recorded session
/// breakpoint_scrolled g[38], a recorded session
/// marker g[20] / g[35]);
/// - [EditorKeyFocus.editor]: the real GUI's key round with the focus
/// IN the editor (a recorded session gui raw[152]: `9/18 =
/// <editor shell>` in place of 16/15/1 + 16/9/11, a CONTROLS-only
/// XML). The function then runs on the editor's token; with the
/// field cursor (the reference client's step 46) the server ran the PROGRAM's
/// where-used (SAPLSEUA/0400 for RSPFPAR) instead;
/// * a double-click on a token (forward navigation): the ABAP editor's
/// OCX event 12 with (line text, line, column - 1, 0, 0), then the CFW
/// double-click event -601 with the cursor span under `<CONTROLS>`
/// (a recorded session gui raw[139]/[148] `%_GC 175 12` /
/// `%_GC 175 -601`; the reference client's live pair, steps 38 / 39, answered by
/// the server's read-back of FirstVisibleLine / SelPosStartLine /
/// SelPosStartCol, then `SetSelectionPosInLine(300, 6)` +
/// `FirstVisibleLine(=295)` — the jump to `form read_actual_par_values`).
/// A TextEdit sends the -601 round alone (the reference client's Java oracle,
/// a recorded session);
/// * a click in the margin (the breakpoint gutter): the OCX event
/// BorderClick `%_GC <editor> 18` (line, ctrl, shift) with only the
/// changed cached props ([editorBorderClickItems]) — what the real GUI
/// sends; the Ctrl+Shift+F12 key round above is its keyboard form.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../framing/envelope.dart';
import 'actions.dart';
import 'canvas_actions.dart';
import 'frontend_profile.dart';

/// The CFW double-click event of a source editor.
const int editorDoubleClickEvent = -601;

/// The ABAP editor OCX event the real GUI fires with the clicked line's
/// text before the double-click (CL_GUI_SOURCEEDIT: EVENT_QUICK_INFO).
const int ab4LineEvent = 12;

/// The ABAP editor OCX event a click in its MARGIN fires:
/// `BorderClick(nLine, bCtrlPressed, bShiftPressed)` (sapab4edit.ocx
/// typelib `_DAB4R3EditorEvents`, dispid 18; a recorded session
/// g[26] / g[29] in SE38, g[69] in the debugger). The server toggles the
/// SESSION breakpoint of the statement holding the line.
const int ab4BorderClickEvent = 18;

/// Ctrl+Shift+F12: set / remove a session breakpoint at the cursor (the
/// keyboard form of the margin click: [ab4BorderClickEvent]; the real
/// GUI's round is [editorFocusKeyItems]).
const int vkeySessionBreakpoint = 48;

/// Ctrl+Shift+F9: SAPLS38E's "Activer/Supprimer point d'arrêt externe" —
/// the EXTERNAL (user) breakpoint key, the application toolbar's `@VB@`
/// button (ICON_USER_BREAKPOINT, a red dot with a small person) and
/// Utilities > Breakpoints. Never sent by an editor gesture: only the
/// toolbar / menu entry fires it.
const int vkeyExternalBreakpoint = 45;

/// Ctrl+Shift+F3: where-used list of the object under the cursor.
const int vkeyWhereUsed = 39;

/// Where the focus of a cursor-keyed editor key round sits.
enum EditorKeyFocus { dynpro, editor }

const String _xmlDecl = '<?xml version="1.0" encoding="sap*"?>';

String _attr(String v) => v
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// The editor's cursor as the cached props a round flushes: the scroll
/// ([firstVisibleLine] / [lastVisibleLine], when given) and the (empty)
/// selection span at ([line], [col]), 1-based.
List<(String, String)> editorCursorProps(
  int line,
  int col, {
  int? firstVisibleLine,
  int? lastVisibleLine,
}) => [
  if (firstVisibleLine != null) ('FirstVisibleLine', '$firstVisibleLine'),
  if (lastVisibleLine != null) ('LastVisibleLine', '$lastVisibleLine'),
  ('SelPosStartLine', '$line'),
  ('SelPosStartCol', '$col'),
  ('SelPosEndLine', '$line'),
  ('SelPosEndCol', '$col'),
];

/// The real GUI's ` <CONTROLS>…</CONTROLS>` block (` ="` separators).
String _winControls(String shell, List<(String, String)> props) {
  final b = StringBuffer(' <CONTROLS>  <CONTROL SHELLID ="${_attr(shell)}">');
  for (final (n, v) in props) {
    b.write('   <PROPERTY VALUE ="${_attr(v)}" NAME ="${_attr(n)}"/>');
  }
  b.write('</CONTROL></CONTROLS>');
  return b.toString();
}

/// The real GUI's ` <CONTROLS>…</CONTROLS>` block of several controls
/// (ascending shell, as the OCX flushes them: a recorded session
/// g[26] `118 {120, 300}` then `119 {LastVisibleLine}`); '' when none.
String _winControlsOf(List<(String, List<(String, String)>)> controls) {
  if (controls.isEmpty) return '';
  return ' <CONTROLS>${windowsControlBlocks(controls)}</CONTROLS>';
}

/// The real GUI's CONTROL blocks of [controls] (per shell, in the order
/// given), the body of a ` <CONTROLS>` section.
String windowsControlBlocks(List<(String, List<(String, String)>)> controls) {
  final b = StringBuffer();
  for (final (shell, props) in controls) {
    b.write('  <CONTROL SHELLID ="${_attr(shell)}">');
    for (final (n, v) in props) {
      b.write('   <PROPERTY VALUE ="${_attr(v)}" NAME ="${_attr(n)}"/>');
    }
    b.write('</CONTROL>');
  }
  return b.toString();
}

/// the reference client's `<CONTROLS>…</CONTROLS>` block (plain `="` separators).
String _controlsBlock(String shell, List<(String, String)> props) {
  final b = StringBuffer('<CONTROLS><CONTROL SHELLID="${_attr(shell)}">');
  for (final (n, v) in props) {
    b.write('<PROPERTY VALUE="${_attr(v)}" NAME="${_attr(n)}"/>');
  }
  b.write('</CONTROL></CONTROLS>');
  return b.toString();
}

/// The Windows key round of [vkey] with the editor [shell]'s cursor
/// [props] flushed (see the library doc for the two [focus] spellings).
/// The items are in the Windows dialect already.
List<Uint8List> editorKeyItems(
  ActionContext ctx,
  int vkey, {
  required String shell,
  required List<(String, String)> props,
  EditorKeyFocus focus = EditorKeyFocus.dynpro,
}) {
  // the round's focus is the caller's, not the paint's: the editor
  // spelling IS the Windows key round with a CFW control focused
  // (frontend_profile.windowsActionItems, a recorded session
  // gui[37]/[42]/[151]: OK 0x0b, 16/12/8, the painted 16/12/6, 16/9/18
  // <editor>), the caret riding as the pending CONTROLS block; the dynpro
  // spelling the field-cursor key round
  final saved = ctx.paintedControlFocus;
  ctx.paintedControlFocus = focus == EditorKeyFocus.editor ? shell : null;
  final List<Uint8List> base;
  try {
    base = windowsActionItems(pressItems(ctx, vkey), ctx: ctx);
  } finally {
    ctx.paintedControlFocus = saved;
  }
  if (focus == EditorKeyFocus.editor) {
    return [
      for (final raw in base)
        if (raw.length == 1 && raw[0] == itemEom) ...[
          xmlBlobItem(
            Uint8List.fromList(
              utf8.encode(
                '$_xmlDecl<DATAMANAGER>${_winControls(shell, props)}'
                '</DATAMANAGER>',
              ),
            ),
          ),
          raw,
        ] else
          raw,
    ];
  }
  final out = <Uint8List>[];
  for (final raw in base) {
    final walk = walkItems(raw);
    final it = walk.items.length == 1 ? walk.items.single : null;
    if (it != null && it.type == itemXmlBlob) {
      final metrics = latin1.decode(it.value);
      final at = metrics.lastIndexOf('</DATAMANAGER>');
      final xml = at < 0
          ? metrics
          : '${metrics.substring(0, at)}${_controlsBlock(shell, props)}'
                '${metrics.substring(at)}';
      out.add(xmlBlobItem(Uint8List.fromList(utf8.encode(xml))));
    } else {
      out.add(raw);
    }
  }
  return out;
}

/// The real GUI's key round of [vkey] typed IN the editor [shell] (the
/// focus there, 16/9/18 <editor>, no okcode, no 16/15/1): the bare key
/// round, with ONLY the cached props the client changed since it last
/// reported them as its CONTROLS ([controls], per shell ascending, as
/// [editorBorderClickItems]) — none at all when nothing changed, and then
/// no item 17 (a recorded session g[38] / g[40] and
/// a recorded session g[33]: Ctrl+Shift+F12 with the caret
/// already on the line the server put it on, 172 bytes; the F3 round g[24]
/// of the same capture carries the props a creation left dirty). The
/// server reads the line from the caret it holds.
List<Uint8List> editorFocusKeyItems(
  ActionContext ctx,
  int vkey, {
  required String shell,
  List<(String, List<(String, String)>)> controls = const [],
}) {
  final saved = ctx.paintedControlFocus;
  ctx.paintedControlFocus = shell;
  final List<Uint8List> base;
  try {
    base = windowsActionItems(pressItems(ctx, vkey), ctx: ctx);
  } finally {
    ctx.paintedControlFocus = saved;
  }
  final block = _winControlsOf(controls);
  if (block.isEmpty) return base;
  return [
    for (final raw in base)
      if (raw.length == 1 && raw[0] == itemEom) ...[
        xmlBlobItem(
          Uint8List.fromList(
            utf8.encode('$_xmlDecl<DATAMANAGER>$block</DATAMANAGER>'),
          ),
        ),
        raw,
      ] else
        raw,
  ];
}

/// The ABAP editor's OCX line event 12 (the first round of a
/// double-click): `%_GC <shell> 12` with (line text, line, col - 1, 0, 0).
List<Uint8List> ab4LineEventItems(
  ActionContext ctx, {
  required String shell,
  required String lineText,
  required int line,
  required int col,
  List<int>? path,
}) {
  final params = [lineText, '$line', '${col - 1}', '0', '0'];
  final b = StringBuffer(
    '$_xmlDecl<DATAMANAGER> <EVENTS>  <EVENT SHELLID ="${_attr(shell)}" '
    'EVENTID ="$ab4LineEvent">',
  );
  for (var i = 0; i < params.length; i++) {
    b.write('   <PARAM PID ="$i" VALUE ="${_attr(params[i])}"/>');
  }
  b.write('</EVENT></EVENTS></DATAMANAGER>');
  return canvasEventItems(
    ctx,
    okcode: cfwGenericEventOkcode(shell, ab4LineEvent),
    xml: Uint8List.fromList(utf8.encode(b.toString())),
    focusShell: shell,
    sourcePath: path,
    // the editor's 16/9/18: the control half of the acked paint
    okMode: windowsOkMode(
      ctx,
      cursor: false,
      fallback: winOkModeControlFocus,
    ),
  );
}

/// The PARAM values [ab4LineEventItems] sends, by PID.
Map<int, String> ab4LineEventParams(String lineText, int line, int col) => {
  0: lineText,
  1: '$line',
  2: '${col - 1}',
  3: '0',
  4: '0',
};

/// The PARAM values of a margin click ([editorBorderClickItems]), by PID.
Map<int, String> borderClickParams(
  int line, {
  bool ctrl = false,
  bool shift = false,
}) => {0: '$line', 1: ctrl ? '1' : '0', 2: shift ? '1' : '0'};

/// A click in the MARGIN of [line] (1-based) of the ABAP editor [shell]:
/// the OCX event BorderClick `%_GC <shell> 18` with PIDs (line, ctrl,
/// shift) — a recorded session g[26] / g[29] (SE38, editor 119,
/// line 9) and g[69] (the debugger, editor 104, line 19), in the generic
/// Windows control-event envelope (OK 0x0b, 16/15/1 with the editor's
/// custom-control [path], 16/9/18 <editor>). [controls] = ONLY the cached
/// properties that changed since the client last flushed them, per shell
/// in ascending order — the first round after the editor's creation
/// carries its container's realized size (120 / 300) and the editor's
/// LastVisibleLine (g[26]); the next click none at all (g[29]: no
/// `<CONTROLS>`). The server answers SetSelectionPosInLine(line, 1), then
/// SetMarker(2, ",<line>") + SetSavePoint (set, s[32] / s[33]) or
/// RemoveMarker(2, ",<line>") (removal, s[35] / s[36]); it resolves the
/// line to its statement itself (g[69] line 19 removed the breakpoint of
/// line 9).
List<Uint8List> editorBorderClickItems(
  ActionContext ctx, {
  required String shell,
  required int line,
  bool ctrl = false,
  bool shift = false,
  List<(String, List<(String, String)>)> controls = const [],
  List<int>? path,
}) {
  final params = borderClickParams(line, ctrl: ctrl, shift: shift);
  final b = StringBuffer(
    '$_xmlDecl<DATAMANAGER> <EVENTS>  <EVENT SHELLID ="${_attr(shell)}" '
    'EVENTID ="$ab4BorderClickEvent">',
  );
  for (final e in params.entries) {
    b.write('   <PARAM PID ="${e.key}" VALUE ="${_attr(e.value)}"/>');
  }
  b.write('</EVENT></EVENTS>${_winControlsOf(controls)}</DATAMANAGER>');
  return canvasEventItems(
    ctx,
    okcode: cfwGenericEventOkcode(shell, ab4BorderClickEvent),
    xml: Uint8List.fromList(utf8.encode(b.toString())),
    focusShell: shell,
    sourcePath: path,
    // the editor's 16/9/18: the control half of the acked paint
    okMode: windowsOkMode(
      ctx,
      cursor: false,
      fallback: winOkModeControlFocus,
    ),
  );
}

/// The CFW double-click round `%_GC <shell> -601` with the cursor span
/// [props] under `<CONTROLS>`.
List<Uint8List> editorDoubleClickItems(
  ActionContext ctx, {
  required String shell,
  required List<(String, String)> props,
  List<int>? path,
}) => canvasEventItems(
  ctx,
  okcode: cfwGenericEventOkcode(shell, editorDoubleClickEvent),
  xml: Uint8List.fromList(
    utf8.encode(
      '$_xmlDecl<DATAMANAGER> <EVENTS>  <EVENT SHELLID ="${_attr(shell)}" '
      'EVENTID ="$editorDoubleClickEvent"/></EVENTS>'
      '${_winControls(shell, props)}</DATAMANAGER>',
    ),
  ),
  focusShell: shell,
  sourcePath: path,
  // the editor's 16/9/18: the control half of the acked paint
  okMode: windowsOkMode(
    ctx,
    cursor: false,
    fallback: winOkModeControlFocus,
  ),
);

/// The ABAP editor's F1 event (AbapEditor.1 control event 3 — the real
/// GUI's F1 with the focus INSIDE the editor; reference client windows_control_
/// event_round.EDITOR_HELP_EVENTID).
const int ab4HelpEvent = 3;

/// F1 inside the ABAP editor [shell]: `%_GC <shell> 3` with no PARAM and
/// the caret [props] under `<CONTROLS>`, in the generic Windows envelope
/// with the editor's control-event source — a recorded session
/// gui[75] (F1 in shell 123 on SE37's SOURCE tab, srv[82]) item for item:
/// SES without an event, 16/6/35, 16/12/4, the identity atoms, OK 0x0b
/// over zeros, 16/12/8, the PAINTED 16/12/6, the tabstrip echo (16/10/1
/// zeros, 16/10/8, 16/9/15 short), 16/15/1 `00 000d 000b … <count> [path]`
/// + 16 zero bytes ([path] = the hosting custom control's container
/// levels, `01 02 01` there), 16/9/18 <editor>, the XML, EOM — no 16/9/11,
/// no 16/4/36, no help-on-field source. The server answers with a
/// SendCompletionCommand on the editor (srv[83]), a DP_GET (srv[84]) and
/// the Performance Assistant's SAPGUI.DIALOGCTRL.1 creation (srv[86]).
List<Uint8List> editorHelpItems(
  ActionContext ctx, {
  required String shell,
  required List<(String, String)> props,
  List<int>? path,
}) => canvasEventItems(
  ctx,
  okcode: cfwGenericEventOkcode(shell, ab4HelpEvent),
  xml: Uint8List.fromList(
    utf8.encode(
      '$_xmlDecl<DATAMANAGER> <EVENTS>  <EVENT SHELLID ="${_attr(shell)}" '
      'EVENTID ="$ab4HelpEvent"/></EVENTS>'
      '${_winControls(shell, props)}</DATAMANAGER>',
    ),
  ),
  focusShell: shell,
  sourcePath: path,
  // the editor's 16/9/18: the control half of the acked paint
  okMode: windowsOkMode(
    ctx,
    cursor: false,
    fallback: winOkModeControlFocus,
  ),
);
