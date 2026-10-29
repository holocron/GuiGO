/// Editor controls — the workbench's ABAP editor (SE38 / SE80 / SE37 / SE24
/// source) and the SAPGUI TextEdit control — with the text the server
/// pushes into them through the DataProvider, and the text the client hands
/// back when the server pulls it (the save side, below).
///
/// Wire shape, ABAP editor (live the test system, the reference client's Windows-dialect SE38
/// display of 2026-10-10, a recorded session; the same as
/// the real SAP GUI for Windows, a recorded session srv[26..48] and
/// a recorded session S30): the GetGuiFeatures answer declares
/// `abapeditor exists/ab4`, so the server builds the new front-end editor
/// `SAPGUI.AbapEditor.1` (sapab4edit.ocx):
/// * step 26 (F7 on SAPLWBABAP/0100): `CreateControl(117,
/// SAPGUI.CONTAINERCTRL.1, …, 10)` + `LinkContainer(117, EDITOR)` +
/// `LinkControl(117, SAPLS38E, 500)`, then `CreateControl(118,
/// SAPGUI.AbapEditor.1, …, 117)` + `LoadLexerDataFromUrl` +
/// `LoadPropsFromDP` (the editor's own settings, an APPLICATION/
/// PROPERTIES push) — no text yet;
/// * step 28: the lexer data (APPLICATION/LEXER_DATA, ~1.5 MB raw) in
/// eleven 30 kB sid-4 chunks — the syntax colouring tables, not text;
/// * step 30 (on the editor HANDLE the client minted): `AddEmptyDoc(
/// RSPARAM, 0, ABAP.2)`, `CreateObject(GuiDataProvider)` +
/// `SetDataFromUrl(APPLICATION, ABAP_SOURCE, SAPR3://…)` +
/// `LoadDocFromDP(RSPARAM, <dp>)`, `SetCurrentDocReadOnly(1)`,
/// `SetSelectionPosInLine(1, 1)`, `FirstVisibleLine(=1)`; the paint
/// (SAPLS38E/0500) follows at step 31;
/// * a second program on the same editor (F3, then F7 on RSPFPAR, step
/// 40) reuses the control: no CreateControl, only a new
/// `SetDataFromUrl` + `LoadDocFromDP` pair.
/// The document is the push's DATABIN table: the WHOLE text as UTF-16LE,
/// lines separated by a lone CR, cut into rows of the declared width (one
/// `03 05` LZH cell here; inline `03 04` rows on other pushes), the last
/// row NUL-padded, the length in the TOTALSIZE scalar (RSPFPAR: 79 400 B =
/// 1 212 lines; ea_editor_databin.databin_text).
///
/// Wire shape, TextEdit (`SAPGUI.TextEditCtrl.1` on Windows, the Java
/// SapTextEdit; reference client ): the body rides an
/// `AssignProperty2(<dataobj>, data | r3TableAutoObj, <editor>,
/// TextAsR3Table | TextAsR3Stream)` push — fixed-width DATAASC records,
/// one line each, the session's UTF-8 — or an inline `TextStream` put.
///
/// The save side. Typing sends nothing (a recorded session:
/// no wire traffic while typing); the control's cached props change —
/// TextModified 1, Version, LineCount, the caret — and ride the next round
/// of any kind (F11: a recorded session g[41]; `=CHECK`: smartforms
/// gui[35]). Their TextModified 1 is what makes the server PULL the text in
/// that round's PAI (an F11 whose props say 0 pulls nothing: smartforms
/// gui[47]):
/// * ABAP editor (SAP GUI for Windows, sapab4edit.ocx): `SaveDocToDP(#1,
/// #2 = <dp>)` on the editor + `SaveDataToUrl(…, SAPR3://<sink>)` on that
/// DataProvider (wda srv[46], smartforms srv[39]), then an UNTYPED
/// `DP_GET_CLIENT_TABLE45A` of the sink declaring `DATABIN` 120 / FORMAT
/// 80 / PROPS 80 (wda srv[47]); the OCX answers APPLICATION /
/// ABAP_SOURCE, the whole document as UTF-16LE with a lone CR between
/// lines in DATABIN rows of the declared width ([abapSourcePullAnswer];
/// wda g[44], smartforms gui[37]). `SetSavePoint(0)` then clears
/// TextModified (wda s[48] -> g[45] `TextModified 0`), a reload clears
/// Version too (wda s[54] -> g[51] `Version 0`; smartforms gui[40]).
/// SE38 / SE80's REPORT save (Ctrl+S) wraps the same pull in the
/// editor's state: `CreateObject(<DataProvider>)` + `StoreStateIntoDP
/// (#1 = it)` first (a recorded session s[29]: the client
/// answers the minted handle, nothing else — the state stays in the
/// frontend's object, no pull), the pull (s[30] / s[31] -> g[25]), then
/// `SetSavePoint(0)` … `RestoreStateFromDP(#1 = that handle)` (s[33]
/// -> g[26] `TextModified 0` alone: the caret and the view are the ones
/// stored). SE38's check (Ctrl+F2) pulls the same document without the
/// state and without the save point (a recorded session
/// paste s[40] / s[41] -> g[34]: TOTALSIZE 6766 = the saved 6764 + the
/// one character typed since, `x`; TextModified stays 1); a check of an
/// unmodified document pulls nothing (g[30]: a bare round, no
/// CONTROLS). SE80's display -> change switch (Ctrl+F1) reloads the
/// document inside a stored state: `StoreStateIntoDP` (s[92]), then
/// `SetCurrentDocReadOnly(0)` + `LoadDocFromDP` + `RestoreStateFromDP`
/// (s[93]) — answered with no CONTROLS (g[83] / g[84]: the same text,
/// nothing moved);
/// * TextEdit (the SAP GUI for Java's SapTextEdit; the SE38 of
/// a recorded session): `AssignProperty2(<editor>,
/// TextAsR3Table, <obj>, data)` + `SaveDataToUrl(…, SAPR3://<sink>)`
/// (srv[31]), then `DP_GET_CLIENT_TABLE45A` of the sink declaring
/// DATAASC 765 (srv[32]); the bean answers APPLICATION / X-R3ABAP, one
/// blank-padded UTF-8 record per line ([r3AbapPullAnswer]; gui[22]).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../framing/envelope.dart' show containsBytes;
import 'client_table_pull.dart' show clientTablePullTableWidth;
import 'dp_cache.dart';
import 'flush_call.dart';
import 'reply_container.dart'
    show buildDpAnswer, rfcToken, tableColumn, tableInlineMax;
import 'tree_header_names.dart' show collapseInlineRow;

/// One editor control as the server last loaded it.
class SapTextEditor {
  SapTextEditor({
    required this.shell,
    this.container,
    required this.kind,
    List<String>? lines,
    this.readOnly = false,
    this.cursorLine,
    this.cursorCol,
    this.firstVisibleLine,
    Set<int>? breakpoints,
  }) : lines = lines ?? [],
       breakpoints = breakpoints ?? {};

  /// The kernel shell id of the editor control (118 on SE38).
  String shell;

  /// The dynpro custom-control area hosting it (`EDITOR`), null when its
  /// container is not linked to one.
  String? container;

  /// 'ab4' (the ABAP front-end editor, `SAPGUI.AbapEditor.1`) or
  /// 'textedit' (`SAPGUI.TextEditCtrl.1` / SapTextEdit).
  String kind;

  /// The text, one entry per line (right-trimmed records for TextEdit): as
  /// the server last loaded it, or as the user edited it since
  /// (SapSession.editEditorText) — what a pull of the document answers.
  List<String> lines;

  /// Whether the server set the document read-only (display mode):
  /// `SetCurrentDocReadOnly(1)` on SE38 display, `(0)` once Ctrl+F1 switched
  /// to change mode (a recorded session s[28] / s[43]). A read-only
  /// document takes no user edit (SapSession.editEditorText).
  bool readOnly;

  /// Whether the text differs from the server's last save point — the
  /// control's TextModified cached prop: set by a user edit
  /// (SapSession.editEditorText; a recorded session g[41]
  /// `TextModified 1`), cleared by the server's `SetSavePoint` (s[48] ->
  /// g[45] `TextModified 0`) and by a document (re)load
  /// (a recorded session srv[43] -> gui[40]).
  bool textModified = false;

  /// The control's Version cached prop: its count of edit steps since the
  /// document was loaded — 2 after a Return and one typed run
  /// (a recorded session g[41]; a recorded session g[22]
  /// 0 -> 2, g[27] 2 -> 4 after its save), 8 after the smartforms user
  /// replaced the text by three typed lines (gui[35]), +303 for a paste of
  /// 152 line breaks and 151 lines ([ab4InsertUndoSteps]; ab4_editor_save
  /// g[32] 4 -> 307), +1 for each character typed (g[41] 308;
  /// a recorded session g[77] `ab` +2), +1 for each
  /// Delete (g[53] `WRI` deleted: +3), back down by Ctrl+Z (g[73]: six
  /// steps undone to the save point, Version 1544, TextModified 0); a
  /// document (re)load resets it (wda s[54] -> g[51] `Version 0`), a save
  /// point does not (g[45]; ab4_editor_save g[26] -> g[27]), nor does a
  /// check's pull (g[34] -> g[41]).
  int version = 0;

  /// The 1-based line the server put the cursor on, null when it set none.
  int? cursorLine;

  /// The 1-based column of the cursor (the server's
  /// `SetSelectionPosInLine(line, col)`, or the position an editor action
  /// last flushed), null when unknown.
  int? cursorCol;

  /// The far end of the user's selection (1-based line, column AFTER the
  /// last selected character — the editor's `SelPosEndLine` /
  /// `SelPosEndCol`; [cursorLine] / [cursorCol] are its start), as the app
  /// reports it (SapSession.setEditorClientState); null = no selection,
  /// the span collapsed on the cursor (every recorded flush:
  /// a recorded session gui[19] SelPosEnd* = SelPosStart*).
  int? selEndLine;
  int? selEndCol;

  /// The first line the editor shows (the server's `FirstVisibleLine(=n)`
  /// put), null when it set none.
  int? firstVisibleLine;

  /// A TextEdit's word wrap as the server configured it: `WordWrapMode`
  /// (0 none, 1 at the window border, 2 at a fixed position),
  /// `WordWrapPosition` (the column of mode 2), `ConvertWordWrapToLineBreak`
  /// (1: a read-back returns the wrapped lines as lines) — PPOSE's long
  /// text: 2 / 72 / 1 (a recorded session s[18]
  /// verbs 589..591). Null until the server set it. [textEditReadBackLines]
  /// applies it.
  int? wordWrapMode;
  int? wordWrapPosition;
  bool wordWrapToLineBreak = false;

  /// How many `FirstVisibleLine(=n)` puts the server sent: each one
  /// scrolls the control (a navigation), even one repeating the last
  /// line after the user scrolled away. A view follows a CHANGE of this
  /// count, never the stale [firstVisibleLine] alone — a breakpoint toggle
  /// answers only `SetSelectionPosInLine` + `SetMarker` (a recorded session
  /// abap_debugger s[32]/s[33], a recorded session
  /// live step 34) and the control keeps the user's scroll.
  int firstVisibleLinePuts = 0;

  /// The first / last line the user's view of the control actually shows
  /// (1-based), as the app reports it (SapSession.setEditorClientState);
  /// null = not reported since the server last scrolled the control. The
  /// real GUI answers the server's read-back of FirstVisibleLine from its
  /// LIVE view (a recorded session gui[22]: 184 after
  /// the user scrolled), not from the server's last put.
  int? viewFirstLine;
  int? viewLastLine;

  /// The line a `SetSelPosInLineCentered(l, c)` asked the control to
  /// center, until the session resolved the scroll it implies (by the
  /// view's capacity: SapSessionEditor) — null otherwise.
  int? centerLine;

  /// The height in rows of the dynpro custom-control area the control was
  /// last painted in (SAPLS38E/0500's EDITOR: 37 rows in the 38-row window
  /// of a recorded session), null before any paint
  /// showed it. Kept while another screen is up: the control outlives its
  /// screen (F3 back to SAPLWBABAP/0100, F7 reloads it) and keeps its size —
  /// the reload's answer reports the view of that size (g[30]).
  int? areaRows;

  /// The 1-based lines carrying a session breakpoint: the ABAP editor's
  /// marker 2, set by `SetMarker(2, ",<line>")`, cleared by
  /// `RemoveMarker(2, ",<line>")` / `RemoveAllMarker(2)` (live the test system,
  /// a recorded session steps 34 / 37).
  final Set<int> breakpoints;

  /// The 1-based lines of EVERY marker kind the server set (`SetMarker(
  /// <kind>, ",<line>…")`, cleared by `RemoveMarker` / `RemoveAllMarker`),
  /// by kind; [breakpoints] is kind 2. sapab4edit.ocx predefines the
  /// breakpoint, bookmark, disabled / session / external breakpoint,
  /// ERROR, POSITION LINE and EXECUTION LINE markers ("Only 1 execution
  /// line marker allowed: backend sent %i") — the ABAP Debugger's current
  /// statement on the SAP GUI for Windows is the execution-line kind, whose
  /// number no capture pins yet (the Windows-dialect debugger wave is
  /// unrecorded: a recorded session is the Java GUI, whose source is
  /// the TC_SOURCE table control).
  final Map<int, Set<int>> markers = {};

  /// The 1-based lines carrying a breakpoint of ANOTHER kind than the
  /// session breakpoint ([breakpoints]): the breakpoint-family markers the
  /// server resets before every rewrite (SE38 `RemoveAllMarker` 2, 5, 4,
  /// 15; the debugger 10, 9, 3, 2, 5, 4 — a recorded session
  /// whereused s[22], a recorded session s[50]) other than 2:
  /// the external (user) breakpoint set by the toolbar's Ctrl+Shift+F9 —
  /// kind 4 ([externalBreakpoints], a recorded session
  /// marker) — or a disabled one. Drawn apart from the session dots; a
  /// margin click on one is still the BorderClick the server decides on
  /// (on an external dot it removes the external breakpoint).
  Set<int> get otherBreakpoints => {
    for (final k in ab4OtherBreakpointMarkers) ...?markers[k],
  };

  /// The 1-based lines carrying an EXTERNAL (user) breakpoint: the ABAP
  /// editor's marker 4 ([ab4ExternalBreakpointMarker]), set by the
  /// toolbar's @VB@ / Ctrl+Shift+F9 (`SetMarker(4, ",<line>")` — the server
  /// picks the line and first clears a session marker there:
  /// `RemoveMarker(2, ",1")`, `SetMarker(4, ",1")`), removed by the same
  /// key or by a margin click on its dot (`RemoveMarker(4, ",1")`, no
  /// session marker set in its place) — a recorded session
  /// breakpoint_marker s[25] / s[28] / s[37] / s[39]. A subset of
  /// [otherBreakpoints].
  Set<int> get externalBreakpoints => {...?markers[ab4ExternalBreakpointMarker]};

  /// The cached properties (FirstVisibleLine, LastVisibleLine, LineCount,
  /// SelPos*, TextModified, Version) as the SERVER last holds them: the control's creation state
  /// (all 1), then every value the client flushed — in a round or in a
  /// flush's answer — or answered a read-back with. A server put
  /// (`FirstVisibleLine(=n)`) or a method that moves one
  /// (`SetSelectionPosInLine(l, c)`, a document load's LineCount) leaves it
  /// owed: the OCX tracks its cached props against what IT last reported,
  /// so the flush's answer reports the moved value — the put line too
  /// (a recorded session g[30] / g[32];
  /// a recorded session gui[43]: `FirstVisibleLine 36`
  /// after the server's own `FirstVisibleLine(=36)`). A round flushes only
  /// the props whose client value differs (a recorded session
  /// g[26]: the margin click after the creation carries LastVisibleLine
  /// 28 — the server's 1 is stale — and not FirstVisibleLine, read back as
  /// 1; g[29]: none;
  /// a recorded session g[31]: the scrolled view
  /// 97 / 140 and the caret 92 / 35, LineCount not — its load's answer
  /// reported it).
  final Map<String, String> serverProps = Map.of(ab4InitialCachedProps);

  @override
  String toString() =>
      'SapTextEditor($kind $shell${container == null ? '' : ' in $container'}'
      ': ${lines.length} line(s)${readOnly ? ', read-only' : ''})';
}

/// The kind of an editor creation class, null for any other control.
String? textEditorKind(String cls) {
  final c = cls.toUpperCase();
  if (c.contains('ABAPEDITOR') || c.contains('AB4')) return 'ab4';
  if (c.contains('TEXTEDIT')) return 'textedit';
  return null;
}

/// The ABAP editor's own verbs (sapab4edit.ocx; no other control has
/// them): an unresolved on-object handle still names an ABAP editor.
const Set<String> _ab4Verbs = {
  'AddEmptyDoc',
  'LoadDocFromDP',
  'SetCurrentDocReadOnly',
  'SetSelectionPosInLine',
  'SetSelPosInLineCentered',
  'SetMarker',
  'RemoveMarker',
  'RemoveAllMarker',
  'FirstVisibleLine',
  // the save side (a recorded session srv[46] / s[48], on the real
  // GUI's editor handle 72)
  'SaveDocToDP',
  'SetSavePoint',
};

/// The undo steps sapab4edit.ocx counts for [text] inserted in one go (a
/// paste, a dictated or autocorrected run) — what its Version cached prop
/// moves by; a typed character is the one-character case (1: every typed
/// character is a step of its own, `ab` +2 and then `c` +1 in
/// a recorded session g[77] / g[81], `sdfsdf` +6 in
/// g[38]), a Return the one-break case (1). A multi-line text counts one
/// step per line break, plus one for its characters: the five lines put
/// into the emptied document of a recorded session g[27]
/// moved Version 2 -> 8, the 1 500 lines put over a Ctrl+A g[43] 14 ->
/// 1517 (the selection's deletion 2, as g[22]: 0 -> 2). The CRLF block
/// pasted from Notepad in a recorded session g[32] counted a
/// step per line break AND per non-empty line (152 + 151: 4 -> 307, the
/// same paste of a recorded session g[25] 0 -> 303):
/// read as the OCX inserting a CRLF text line by line. Neither capture
/// logged the keys, so the two readings are the ones that fit every
/// recorded count, not a decoded rule. No recorded pull depends on the
/// count: the check after six Ctrl+Z back to the save point (Version 1544,
/// TextModified 0, _long g[73]) was pulled like the others.
int ab4InsertUndoSteps(String text) {
  final runs = text.split(_splitEditorLinesRx);
  final breaks = runs.length - 1;
  final filled = runs.where((r) => r.isNotEmpty).length;
  final n = text.contains('\r\n')
      ? breaks + filled
      : breaks + (filled > 0 ? 1 : 0);
  return n < 1 ? 1 : n;
}

/// The ABAP editor's session-breakpoint marker kind (`SetMarker(2, …)`).
const int ab4BreakpointMarker = 2;

/// The ABAP editor's EXTERNAL (user) breakpoint marker kind
/// (`SetMarker(4, …)`: a recorded session).
const int ab4ExternalBreakpointMarker = 4;

/// The breakpoint-family marker kinds other than the session breakpoint
/// ([SapTextEditor.otherBreakpoints]; 4 = the external one).
const Set<int> ab4OtherBreakpointMarkers = {3, 4, 5, 9, 10};

/// The view / caret cached props of a fresh ABAP editor control (its
/// state before any flush: line 1, column 1) — [SapTextEditor.serverProps].
const Map<String, String> ab4InitialCachedProps = {
  'FirstVisibleLine': '1',
  'LastVisibleLine': '1',
  // the empty document's one line (the creation reply: a recorded session
  // se38_breakpoint_scrolled g[10] `LineCount 1`); a load's answer reports
  // the new count (g[23] 6, g[30] 1212)
  'LineCount': '1',
  'SelPosStartLine': '1',
  'SelPosStartCol': '1',
  'SelPosEndLine': '1',
  'SelPosEndCol': '1',
  // the unedited document (the creation reply's `TextModified 0` /
  // `Version 0`); a user edit moves both (a recorded session g[41])
  'TextModified': '0',
  'Version': '0',
};

/// A fresh SAP GUI for Windows TextEdit's (`SAPGUI.TextEditCtrl.1`) cached
/// props as its creation answer reports them: the caret on 1/1, the view
/// from line 1, no selection index, unmodified — not the numeric default
/// 0 (a recorded session g[10], a recorded session
/// longtext_nonempty g[16], a recorded session g[13]
/// TextEdit 178: SelPosStartCol 1, FirstVisibleLine 1,
/// SelPosEndLine 1, TextModified 0, SelPosStartLine 1, SelIndexEnd 0,
/// SelPosEndCol 1, SelIndexStart 0).
const Map<String, String> textEditInitialCachedProps = {
  'SelPosStartCol': '1',
  'FirstVisibleLine': '1',
  'SelPosEndLine': '1',
  'TextModified': '0',
  'SelPosStartLine': '1',
  'SelIndexEnd': '0',
  'SelPosEndCol': '1',
  'SelIndexStart': '0',
};

/// The TextEdit's cached props in the order textedit.dll flushes them —
/// its creation answer (a recorded session g[10]) and
/// every later report a subsequence of it (the save rounds of
/// a recorded session g[19] / g[32]: SelPosStartCol,
/// TextModified, SelIndexEnd, SelPosEndCol, SelIndexStart).
const List<String> textEditFlushOrder = [
  'SelPosStartCol',
  'FirstVisibleLine',
  'SelPosEndLine',
  'TextModified',
  'SelPosStartLine',
  'SelIndexEnd',
  'SelPosEndCol',
  'SelIndexStart',
];

/// A TextEdit's SelIndex of the 1-based position ([line], [col]) in
/// [lines]: the 0-based character offset in the control's text (the caret
/// after ten typed characters on line 1 is SelIndex 10, SelPosStartCol 11:
/// a recorded session g[19]; the emptied box 0 / 1:
/// g[32]). A line break counts one character — no recorded round has the
/// caret past one, so that count is unproven.
int textEditSelIndex(List<String> lines, int line, int col) {
  var off = 0;
  for (var i = 0; i < line - 1 && i < lines.length; i++) {
    off += lines[i].length + 1;
  }
  return off + (col < 1 ? 0 : col - 1);
}

/// The ABAP editor's cached props in the order sapab4edit.ocx flushes them
/// (its property map's own order, not the registration order) — every
/// Windows creation answer of the corpus (a recorded session
/// scrolled g[10], a recorded session g[12] / g[41],
/// a recorded session g[13], a recorded session g[27], …)
/// and every later report a subsequence of it (g[24], g[30], g[31]).
const List<String> ab4FlushOrder = [
  'SelPosStartCol',
  'FirstVisibleLine',
  'LineCount',
  'SelPosEndLine',
  'LastVisibleLine',
  'TextModified',
  'SelPosStartLine',
  'Version',
  'SelPosEndCol',
];

/// How many lines a source view [viewportHeight] tall shows at
/// [lineHeight] a line, from its top: the partly visible last line counted
/// (at least 1). ONE formula for the session and the app: the ABAP
/// editor's LastVisibleLine is `first + editorVisibleLines(...) - 1`
/// (capped by the document), and GuiGo's SapSourceView reports exactly
/// that as its last line (`ceil((offset + viewport) / lineHeight)`).
int editorVisibleLines(double viewportHeight, double lineHeight) {
  if (!(viewportHeight > 0) || !(lineHeight > 0)) return 1;
  final n = (viewportHeight / lineHeight).ceil();
  return n < 1 ? 1 : n;
}

/// The ABAP editor's line pitch in the kernel's window pixels (its 22 px
/// cell row): the session's model of the real sapab4edit.ocx view when no
/// app reports one — [editorVisibleLines] of the custom-control area's
/// rows x 22 px. Fitted on every Windows capture that shows a full view:
/// the 37-row SAPLS38E/0500 EDITOR area (814 px; its container reports
/// 120 = 434) shows 44 lines (a recorded session
/// g[30] / g[31] 97..140, a recorded session g[20] /
/// g[21] 184..227, a recorded session g[29] / g[45] 151..194), a
/// 34-row one (748 px; 120 = 399) 41 (token_whereused g[25], its _s4d
/// g[19]), the debugger's 33-row source (726 px; 120 = 387) 40
/// (a recorded session g[56] 10..49): ceil(px / pitch) gives all
/// three for a pitch in [18.5, 18.61) px.
const double ab4KernelLinePx = 18.55;

/// The editor verbs whose on-object is the editor itself.
const Set<String> _editorVerbs = {
  // the TextEdit's word wrap (SapTextEditor.wordWrapMode)
  'WordWrapMode',
  'WordWrapPosition',
  'ConvertWordWrapToLineBreak',
  ..._ab4Verbs,
  'ReadOnly',
  'ReadOnlyMode',
  'TextStream',
  'Text',
  'TextModified',
};

/// The DataProvider-fed TextEdit body properties (reference client PUSH_PROPS).
const Set<String> _pushProps = {'TextAsR3Table', 'TextAsR3Stream'};

final RegExp _digits = RegExp(r'^\d{1,9}$');

/// The editor document sinks a [SapTextEditorTracker] holds unanswered at
/// most ([SapTextEditorTracker.docSinks]): the server pulls each one in the
/// round after it names it (one or two per save), so a backlog past this is
/// a server that never pulls — the oldest goes.
const int maxEditorDocSinks = 64;

/// Folds the OLE flush calls into the editors they create and load.
class SapTextEditorTracker {
  /// shell -> the editor as last loaded
  final Map<String, SapTextEditor> _editors = {};

  /// editor shells in creation order
  final List<String> _order = [];

  /// shell -> its CreateControl parent shell (#4)
  final Map<String, String> parentOf = {};

  /// container shell -> the dynpro custom-control area (LinkContainer)
  final Map<String, String> areaOf = {};

  /// container shell -> (program, dynpro) it is linked to (LinkControl)
  final Map<String, (String, String)> linkOf = {};

  /// editor shells loaded but bound to no dynpro yet (no LinkControl on
  /// their container chain): the next paint binds them
  final Set<String> unbound = {};

  /// editor shells whose text the server delivered (an empty document
  /// included)
  final Set<String> loaded = {};

  /// editor shell -> (program, dynpro) of the paint that bound it
  final Map<String, (String, String)> paintedOn = {};

  /// SAPR3 sink -> the ABAP editor whose document a `SaveDocToDP` put into
  /// the DataProvider saved under it: `SaveDocToDP(#1, #2 = 74)` on the
  /// editor, `SaveDataToUrl(…, SAPR3://…E20000)` ON 74 (a recorded session
  /// save srv[46]: the DataProvider is `#2`, a handle minted earlier, `#1`
  /// blank — SAPLSTXB on a recorded session srv[39]). The
  /// server pulls the sink next ([abapSourcePullAnswer]); taken when
  /// answered. Wire-fed, so bounded: the newest [maxEditorDocSinks] are
  /// kept (oldest out), and a shell re-created as a new control drops its.
  final Map<String, String> docSinks = {};

  /// Every editor seen, in creation order.
  List<SapTextEditor> get all => [for (final s in _order) _editors[s]!];

  /// The editor of [shell], null when none was created there.
  SapTextEditor? operator [](String shell) => _editors[shell];

  /// The (program, dynpro) [shell]'s container chain is linked to, else
  /// the paint that bound it.
  (String, String)? screenOf(String shell) {
    var sh = shell;
    for (var i = 0; i < 16; i++) {
      final l = linkOf[sh];
      if (l != null) return l;
      final p = parentOf[sh];
      if (p == null) break;
      sh = p;
    }
    return paintedOn[shell];
  }

  /// The dynpro area of [shell]'s nearest linked container.
  String? _areaOf(String shell) {
    var sh = shell;
    for (var i = 0; i < 16; i++) {
      final a = areaOf[sh];
      if (a != null) return a;
      final p = parentOf[sh];
      if (p == null) break;
      sh = p;
    }
    return null;
  }

  /// Bind the unbound editors to the screen a paint just named.
  void bindUnbound(String program, String dynpro) {
    for (final sh in unbound) {
      paintedOn[sh] = (program, dynpro);
    }
    unbound.clear();
  }

  /// Fold one complete OLE_FLUSH_CALL [rfc]. [shellOf] maps a client
  /// handle to its kernel shell (the session's alias map); [dpSegment]
  /// looks up a DataProvider push the call does not carry itself (one
  /// snooped from an earlier frame); [isLive] filters destroyed controls.
  /// Returns the editor shells whose text, mode or cursor changed.
  /// [parsed] = [rfc] already parsed.
  Set<String> foldCall(
    Uint8List rfc, {
    String? Function(String handle)? shellOf,
    Uint8List? Function(String url)? dpSegment,
    bool Function(String shell)? isLive,
    FlushCall? parsed,
  }) {
    if (!containsBytes(rfc, 'OLE_FLUSH_CALL')) return const {};
    final call = parsed ?? parseFlushCall(rfc);
    if (call.verbs.isEmpty) return const {};
    final meta = verbMeta(call);
    final rowShell = <String, String>{}; // CreateControl _RESULT row -> shell
    final rowUrl = <String, String>{}; // DataProvider row -> its url
    final docSaves = <String, String>{}; // SaveDocToDP's DataProvider -> editor
    final touched = <String>{};
    DpCache? cache;
    Uint8List? segment(String url) {
      cache ??= DpCache()..ingestValue(rfc);
      return cache!.byUrl[url] ?? dpSegment?.call(url);
    }

    String? editorOf(VerbMeta m, String verb) {
      final row = m.obj.trim();
      final tok = m.objValue.trim();
      final cands = [
        rowShell[row],
        if (_digits.hasMatch(tok)) ...[shellOf?.call(tok), tok],
      ];
      for (final c in cands) {
        if (c != null && _editors.containsKey(c)) return c;
      }
      if (!_digits.hasMatch(tok) || !_ab4Verbs.contains(verb)) return null;
      // a handle no alias resolves (a replayed recording keeps the
      // recording client's handles): the newest live ABAP editor
      for (final s in _order.reversed) {
        if (_editors[s]!.kind == 'ab4' && (isLive?.call(s) ?? true)) return s;
      }
      return null;
    }

    for (var i = 1; i <= call.verbs.length; i++) {
      final verb = call.verbs[i - 1];
      final m = meta[i - 1];
      final named = verbNamedArgs(call, i);
      if (verb.startsWith('CreateControl')) {
        final shell = (named['#1'] ?? '').trim();
        if (!_digits.hasMatch(shell)) continue;
        final res = m.result?.trim() ?? '';
        if (res.isNotEmpty) rowShell[res] = shell;
        final parent = (named['#4'] ?? '').trim();
        if (_digits.hasMatch(parent)) {
          parentOf[shell] = parent;
        } else {
          parentOf.remove(shell);
        }
        // a reused shell id is a new control
        docSinks.removeWhere((_, sh) => sh == shell);
        areaOf.remove(shell);
        linkOf.remove(shell);
        paintedOn.remove(shell);
        loaded.remove(shell);
        final kind = textEditorKind(named['#2'] ?? '');
        _order.remove(shell);
        _editors.remove(shell);
        if (kind != null) {
          final e = _editors[shell] = SapTextEditor(shell: shell, kind: kind);
          // what the creation answer reports a TextEdit holds (the
          // responder's registration report: [textEditInitialCachedProps])
          if (kind == 'textedit') {
            e.serverProps
              ..clear()
              ..addAll(textEditInitialCachedProps);
          }
          _order.add(shell);
        }
        continue;
      }
      if (verb == 'LinkContainer') {
        final shell = (named['#1'] ?? '').trim();
        final name = (named['#2'] ?? '').trim();
        if (_digits.hasMatch(shell) && name.isNotEmpty) areaOf[shell] = name;
        continue;
      }
      if (verb == 'LinkControl') {
        final shell = (named['#1'] ?? '').trim();
        final prog = (named['#2'] ?? '').trim();
        final dyn = (named['#3'] ?? '').trim();
        if (_digits.hasMatch(shell) && prog.isNotEmpty && dyn.isNotEmpty) {
          linkOf[shell] = (prog, dyn.padLeft(4, '0'));
        }
        continue;
      }
      if (verb == 'SetDataFromUrl') {
        final u = (named['#3'] ?? '').trim();
        if (u.startsWith('SAPR3://') && m.obj.trim().isNotEmpty) {
          rowUrl[m.obj.trim()] = u;
        }
        continue;
      }
      if (verb == 'SaveDataToUrl') {
        // the sink of an editor document a SaveDocToDP of this queue put
        // into the DataProvider (on-object = its #2): the pull that follows
        // reads it (a recorded session srv[46] -> srv[47])
        final u = (named['#3'] ?? '').trim();
        final sh = docSaves.remove(m.objValue.trim()) ??
            (docSaves.length == 1 ? docSaves.remove(docSaves.keys.single) : null);
        if (sh != null && u.startsWith('SAPR3://')) {
          docSinks.remove(u); // a re-named sink is the newest
          docSinks[u] = sh;
          if (docSinks.length > maxEditorDocSinks) {
            docSinks.remove(docSinks.keys.first);
          }
        }
        continue;
      }
      if (verb == 'SetProperty') {
        // SetProperty(<shell>, ReadOnly, 1): the TextEdit read-only mode
        final sh = (named['#1'] ?? '').trim();
        final prop = (named['#2'] ?? '').trim();
        final e = _editors[shell(sh, shellOf)];
        if (e != null && (prop == 'ReadOnly' || prop == 'ReadOnlyMode')) {
          e.readOnly = _truthy(named['#3']);
          touched.add(e.shell);
        }
        continue;
      }
      if (!_editorVerbs.contains(verb)) continue;
      final sh = editorOf(m, verb);
      if (sh == null) continue;
      final e = _editors[sh]!;
      final args = verbArgs(call, i);
      String arg(String name) =>
          named[name] ?? (args.isNotEmpty ? args.first.$2 : '');
      var text = true;
      switch (verb) {
        case 'SaveDocToDP':
          // the document into the DataProvider #2, saved under a sink by
          // the queue's SaveDataToUrl on it ([docSinks])
          final dp = (named['#2'] ?? '').trim();
          if (dp.isNotEmpty) docSaves[dp] = sh;
          continue;
        case 'SetSavePoint':
          // the text the server pulled is its saved state now: TextModified
          // 0, reported in this flush's answer, Version kept
          // (a recorded session s[48] -> g[45])
          e.textModified = false;
          text = false;
        case 'TextModified':
          // a put (`TextModified(=0)`, a recorded session
          // s[34]); a getter (`TextModified(_RESULT=)`) reads it back
          final v = [
            for (final a in args)
              if (!a.$1.startsWith('_')) a.$2,
          ];
          if (v.isEmpty) continue;
          e.textModified = _truthy(v.first);
          text = false;
        case 'AddEmptyDoc':
          e.textModified = false;
          e.version = 0;
          e.lines = [];
          e.cursorLine = null;
          e.cursorCol = null;
          e.selEndLine = null;
          e.selEndCol = null;
          e.viewFirstLine = null;
          e.viewLastLine = null;
          e.breakpoints.clear();
          e.markers.clear();
          // [SapTextEditor.serverProps] stay: what the server last HEARD
          // of the control, a new document or not — the debugger's switch
          // to LBTCUTIL2U01 (CloseDoc / AddEmptyDoc / LoadDocFromDP /
          // SetSelPosInLineCentered(29, 1)) is answered with SelPosStartCol
          // 1, the server holding the 25 the F5 round sent
          // (a recorded session g[55] / g[56])
        case 'LoadDocFromDP':
          // a (re)load is the unedited document: TextModified and Version 0,
          // reported in the flush's answer when the server held other
          // values (a recorded session s[54] -> g[51] `Version 0`,
          // a recorded session srv[43] -> gui[40])
          final edited = e.textModified || e.version != 0;
          e.textModified = false;
          e.version = 0;
          // the DataProvider it loads from: by row, else the last url set
          final dpRow = (m.slots['#2'] ?? '').trim();
          final url =
              rowUrl[dpRow] ??
              (rowUrl.values.isEmpty ? null : rowUrl.values.last);
          final seg = url == null ? null : segment(url);
          final doc = seg == null ? null : databinText(seg);
          if (doc == null) {
            // the reset is reported all the same
            if (edited) touched.add(e.shell);
            continue;
          }
          e.lines = splitEditorLines(doc);
        case 'SetCurrentDocReadOnly' || 'ReadOnly' || 'ReadOnlyMode':
          e.readOnly = _truthy(arg('#1'));
          text = false;
        case 'SetSelectionPosInLine' || 'SetSelPosInLineCentered':
          e.cursorLine = int.tryParse(arg('#1').trim());
          e.cursorCol = int.tryParse((named['#2'] ?? '').trim());
          if (verb == 'SetSelPosInLineCentered' && e.cursorLine != null) {
            // the ABAP Debugger's current line (a recorded session
            // debugger s[50] / s[66]): the control also SCROLLS to center
            // it — by its own view's height, which the session resolves
            // ([centerLine]); the reported view is stale
            e.centerLine = e.cursorLine;
            e.viewFirstLine = null;
            e.viewLastLine = null;
          }
          // the server's caret collapses the user's selection
          e.selEndLine = null;
          e.selEndCol = null;
          // … and moves the control's cached SelPos* props: a METHOD the
          // server cannot mirror, so the client reports the moved caret in
          // this flush's answer ([SapTextEditor.serverProps] stays what the
          // server last heard — a recorded session
          // g[32]: SelPosStartCol 1, SelPosEnd/StartLine 136, SelPosEndCol
          // 1 after SetSelectionPosInLine(136, 1); a recorded session
          // debugger g[27])
          text = false;
        case 'FirstVisibleLine':
          // a put carries the line (`FirstVisibleLine(=295)`); a getter
          // (`FirstVisibleLine(_RESULT=)`) reads it back and changes nothing
          final v = [
            for (final a in args)
              if (!a.$1.startsWith('_')) a.$2,
          ];
          final n = v.isEmpty ? null : int.tryParse(v.first.trim());
          if (n == null) continue;
          e.firstVisibleLine = n;
          e.firstVisibleLinePuts++;
          // NOT what the server holds now: the OCX reports the moved view
          // in this flush's answer like a method-moved caret
          // (a recorded session gui[43] / [47] / [53] /
          // [59]: FirstVisibleLine 36 / 37 / 45 / 1141 after the put)
          // the server scrolled the control: the reported view is stale
          e.viewFirstLine = null;
          e.viewLastLine = null;
          text = false;
        case 'SetMarker' || 'RemoveMarker' || 'RemoveAllMarker':
          text = false;
          final kind = int.tryParse((named['#1'] ?? '').trim());
          if (kind != null) {
            final lines = markerLines(named['#2'] ?? '');
            final set = e.markers[kind] ??= {};
            if (verb == 'SetMarker') {
              set.addAll(lines);
            } else if (verb == 'RemoveMarker') {
              set.removeAll(lines);
            } else {
              set.clear();
            }
            _markLoaded(e, touched, text: false);
          }
          if (kind != ab4BreakpointMarker) continue;
          final at = markerLines(named['#2'] ?? '');
          if (verb == 'SetMarker') {
            e.breakpoints.addAll(at);
          } else if (verb == 'RemoveMarker') {
            e.breakpoints.removeAll(at);
          } else {
            e.breakpoints.clear();
          }
        case 'WordWrapMode':
          e.wordWrapMode = int.tryParse(arg('#1').trim());
          text = false;
        case 'WordWrapPosition':
          e.wordWrapPosition = int.tryParse(arg('#1').trim());
          text = false;
        case 'ConvertWordWrapToLineBreak':
          e.wordWrapToLineBreak = _truthy(arg('#1'));
          text = false;
        case 'TextStream' || 'Text':
          e.lines = splitEditorLines(arg('#1'));
      }
      _markLoaded(e, touched, text: text);
    }
    // TextEdit bodies: AssignProperty2(<dataobj>, …, <editor>, TextAs…)
    for (final b in dpPushBindings(call)) {
      if (!_pushProps.contains(b.role)) continue;
      String? sh = b.shell?.trim();
      final owner = b.owner?.trim();
      if (sh == null || !_editors.containsKey(sh)) {
        sh = owner == null ? null : shell(owner, shellOf);
      }
      final e = sh == null ? null : _editors[sh];
      if (e == null) continue;
      for (final u in b.urls) {
        final seg = segment(u);
        final body = seg == null
            ? null
            : r3TableText(seg, stream: b.role == 'TextAsR3Stream');
        if (body == null) continue;
        e.lines = body;
        _markLoaded(e, touched);
      }
    }
    return touched;
  }

  /// The editor an on-object handle [token] names: [shell], else (a
  /// replayed recording keeps the recording client's handles) the newest
  /// live ABAP editor. Null for no editor.
  String? editorOfHandle(
    String token, {
    String? Function(String handle)? shellOf,
    bool Function(String shell)? isLive,
  }) {
    final sh = shell(token, shellOf);
    if (sh != null) return sh;
    if (!_digits.hasMatch(token.trim())) return null;
    for (final s in _order.reversed) {
      if (_editors[s]!.kind == 'ab4' && (isLive?.call(s) ?? true)) return s;
    }
    return null;
  }

  /// [token] as an editor shell: itself, else its alias, else null.
  String? shell(String token, String? Function(String handle)? shellOf) {
    final t = token.trim();
    if (_editors.containsKey(t)) return t;
    final a = shellOf?.call(t);
    if (a != null && _editors.containsKey(a)) return a;
    return null;
  }

  void _markLoaded(SapTextEditor e, Set<String> touched, {bool text = true}) {
    e.container ??= _areaOf(e.shell);
    if (text) loaded.add(e.shell);
    if (screenOf(e.shell) == null) unbound.add(e.shell);
    touched.add(e.shell);
  }
}

bool _truthy(String? v) {
  final t = (v ?? '').trim().toUpperCase();
  return t == '1' || t == 'X' || t == 'TRUE' || t == '-1';
}

/// The line numbers of a marker verb's line list (`,378` / `,12,40`).
List<int> markerLines(String v) => [
  for (final m in _markerLinesRx.allMatches(v)) int.parse(m.group(0)!),
];

/// Split an editor document into lines (CR, LF or CRLF separated; a
/// trailing separator ends the last line, it opens no empty one).
List<String> splitEditorLines(String doc) {
  if (doc.isEmpty) return [];
  final lines = doc.split(_splitEditorLinesRx);
  if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
  return lines;
}

/// The document text of a DATABIN push (the ABAP editor's ABAP_SOURCE
/// table): the column's rows joined, cut to the TOTALSIZE length, NUL
/// padding dropped, decoded as UTF-16LE (surrogate pairs kept). Null when
/// the segment carries no DATABIN column.
String? databinText(Uint8List seg) {
  final (name, (w, n), cells) = dpColumnCells(seg, 'DATABIN');
  if (name.isEmpty || cells.isEmpty) return null;
  final b = BytesBuilder(copy: false);
  for (final c in cells) {
    b.add(c);
  }
  var raw = b.takeBytes();
  // dpPutContent's bound of the DATABIN content, without decoding (and
  // joining) the column a second time: TOTALSIZE, else the
  // declared dims — when no DATAASC column takes precedence
  final total = name == 'DATABIN' && dpColumnCells(seg, 'DATAASC').$3.isEmpty
      ? (dpTotalSize(seg) > 0
          ? dpTotalSize(seg)
          : (w > 0 && n > 0 ? w * n : raw.length))
      : 0;
  if (total > 0 && total < raw.length) {
    raw = Uint8List.sublistView(raw, 0, total);
  } else if (w > 0 && n > 0 && w * n < raw.length) {
    raw = Uint8List.sublistView(raw, 0, w * n);
  }
  var end = raw.length & ~1;
  while (end >= 2 && raw[end - 1] == 0 && raw[end - 2] == 0) {
    end -= 2;
  }
  final units = Uint16List(end ~/ 2);
  for (var i = 0; i < units.length; i++) {
    units[i] = raw[2 * i] | (raw[2 * i + 1] << 8);
  }
  return String.fromCharCodes(units);
}

/// The lines of a TextEdit DATAASC push: fixed-width records of the
/// declared width, each one line (UTF-8, latin-1 for a stray non-UTF-8
/// record), right-trimmed, the trailing blank records dropped; [stream]
/// (TextAsR3Stream): the records joined and split at the line breaks.
List<String>? r3TableText(Uint8List seg, {bool stream = false}) {
  final (name, (w, n), cells) = dpColumnCells(seg, 'DATAASC');
  if (name.isEmpty) return null;
  // a DATAASC column DECLARED with no rows is the empty document, which is
  // still a delivered body: PPOSE's LONGTEXT TextEdit 162 for an object
  // with no description (a recorded session srv[17] step 26:
  // `AssignProperty2(<dp>, data, <162>, TextAsR3Table)` over a DP_PUT whose
  // DATAASC is (12288, 0) and TOTALSIZE empty). Read as "no body", the
  // control was never loaded and its area fell to the R9 "no hosted shell
  // known" wireframe although the TextEdit is up. A column absent, or rows
  // declared but not (yet) delivered, stays "no body".
  if (cells.isEmpty) return n == 0 ? <String>[] : null;
  // inline `03 04` records, each with its trailing blanks cut to one (the
  // Windows OCX's one-record read-back, a recorded session
  // nonempty g[23]; the kernel's inline pushes alike): a row per cell, not
  // the cells joined and sliced by the width they ran together
  if (!stream &&
      w > 0 &&
      n > 1 &&
      cells.length == n &&
      cells.every((c) => c.length <= w) &&
      cells.fold(0, (a, c) => a + c.length) < w * n) {
    final rows = [
      for (final c in cells) utf8.decode(c, allowMalformed: true).trimRight(),
    ];
    while (rows.isNotEmpty && rows.last.trim().isEmpty) {
      rows.removeLast();
    }
    return rows;
  }
  final b = BytesBuilder(copy: false);
  for (final c in cells) {
    b.add(c);
  }
  var raw = b.takeBytes();
  if (w > 0 && n > 0 && w * n < raw.length) {
    raw = Uint8List.sublistView(raw, 0, w * n);
  }
  String decode(Uint8List r) {
    var e = r.length;
    while (e > 0 && r[e - 1] == 0) {
      e--;
    }
    final v = Uint8List.sublistView(r, 0, e);
    try {
      return utf8.decode(v);
    } on FormatException {
      return latin1.decode(v);
    }
  }

  if (stream) return splitEditorLines(decode(raw));
  final width = w > 0 ? w : raw.length;
  final out = <String>[
    for (var i = 0; i < raw.length; i += width)
      decode(
        Uint8List.sublistView(
          raw,
          i,
          i + width > raw.length ? raw.length : i + width,
        ),
      ).trimRight(),
  ];
  while (out.isNotEmpty && out.last.trim().isEmpty) {
    out.removeLast();
  }
  return out;
}

/// The ABAP editor's document as its OCX hands it to the server: the lines
/// joined by a lone CR (U+000D), no trailing separator, UTF-16LE — a line
/// break inside a line (never typed: a paste is split into lines first)
/// is that CR too (a recorded session g[44] `method … .\rendmethod.\r*
/// reference client oracle`, a recorded session gui[37]).
Uint8List abapSourceBytes(List<String> lines) {
  final text = lines.join('\r').replaceAll(_splitEditorLinesRx, '\r');
  final out = Uint8List(2 * text.length);
  for (var i = 0; i < text.length; i++) {
    final u = text.codeUnitAt(i);
    out[2 * i] = u & 0xff;
    out[2 * i + 1] = u >> 8;
  }
  return out;
}

/// The DATABIN row width the ABAP editor's document pull declares (120 on
/// every recorded pull: a recorded session srv[47],
/// a recorded session srv[40]) — the width a request that
/// declares none is answered in.
const int abapSourceRowWidth = 120;

/// The SAP GUI for Windows OCX's answer to the server's pull of the ABAP
/// editor's document (`DP_GET_CLIENT_TABLE45A` of the [SapTextEditorTracker.
/// docSinks] sink, [request] its RFC value) holding [lines]: TYPE
/// APPLICATION, SUBTYPE ABAP_SOURCE, DATE `00000000` / TIME `000000`,
/// blank DESCRIPTION and PLATTFORM, TOTALSIZE = the document's byte count
/// (LE u32), then the DATABIN table the request declared — [abapSourceBytes]
/// cut into rows of its width (120), the last one short — and FORMAT /
/// PROPS as empty tables of their declared widths (80), the 06 67 trailer
/// (a recorded session g[44]: 112 B in one row; a recorded session
/// code_tab_save gui[37]: 158 B in a 120 + 38 row pair). NOT the Java
/// bean's X-R3ABAP DATAASC records ([r3AbapPullAnswer]): the kernel reads
/// the table it DECLARED, a DATAASC answer to a DATABIN pull commits an
/// EMPTY text (the reference client's complaint-smartforms-code-tab-save-confirmed).
///
/// A document past one 250-byte segment rides as ONE `03 05` LZH cell of the
/// fixed-width rows ([tableColumn], every reply table's rule), the last row
/// NUL-padded and cut by TOTALSIZE — the OCX's own answer of every pull of
/// a recorded session (SE38 g[25] 352 B: DATABIN 120 x 3, 360
/// bytes inflated; g[30] 384 B, the line `* comment é ü ß` 16 UTF-16 units;
/// the pasted g[34] / g[39] 6728 B and g[43] / g[48] 6730 B: 120 x 57;
/// SE80 g[88] 420 B; a recorded session g[28] 6764 B,
/// g[34] 6766 B), the same cell lead and 250-byte segment padding, the
/// same FORMAT / PROPS and trailer after it. The inline rows of the two
/// small captures (112 B, 158 B) and the cell from 352 B on put the
/// switch between 158 and 352 bytes: the reply tables' 250 is inside it
/// (no capture pins it closer). Inline rows of a long source would also
/// overflow the reply item's u16 length. The LZH bytes are this encoder's,
/// not the OCX's (the inflated rows are the same); the 06 67 trailer's
/// double is the frontend's per-call statistics (80.0, 69.0, 195.0 …
/// across those answers), not a version. A document past 64 KB is
/// unrecorded.
Uint8List abapSourcePullAnswer(Uint8List request, List<String> lines) {
  final doc = abapSourceBytes(lines);
  final declared = clientTablePullTableWidth(request, 'DATABIN');
  final w = declared > 0 ? declared : abapSourceRowWidth;
  final rows = [
    for (var i = 0; i < doc.length; i += w)
      Uint8List.sublistView(doc, i, i + w > doc.length ? doc.length : i + w),
  ];
  final table = BytesBuilder(copy: false)
    ..add(_tableHead('DATABIN', w, rows.length))
    ..add(tableColumn(rows, width: w));
  for (final aux in const ['FORMAT', 'PROPS']) {
    final aw = clientTablePullTableWidth(request, aux);
    table.add(_tableHead(aux, aw > 0 ? aw : 80, 0));
  }
  return buildDpAnswer(
    scalars: {
      'TYPE': 'APPLICATION',
      'SUBTYPE': 'ABAP_SOURCE',
      'DATE': '00000000',
      'TIME': '000000',
      'DESCRIPTION': '',
      'TOTALSIZE': _le32(doc.length),
      'PLATTFORM': '',
    },
    tableRegion: table.takeBytes(),
  );
}

/// The TextEdit's X-R3ABAP record width when the read-back declares none:
/// 255 characters of UTF-8, 765 bytes (a recorded session
/// srv[32] declares it, gui[22] answers in it).
const int r3AbapRecordWidth = 765;

/// The SAP GUI for Java's answer to the server's read-back of a TextEdit's
/// text (`AssignProperty2(<editor>, TextAsR3Table, <obj>, data)` +
/// `SaveDataToUrl`, then `DP_GET_CLIENT_TABLE45A` of the sink — [request]
/// its RFC value) holding [lines]: TYPE APPLICATION, SUBTYPE X-R3ABAP, blank
/// DATE / TIME / DESCRIPTION / PLATTFORM, TOTALSIZE = the records' byte
/// count, the SEND_DATA_AS_STRING flag, one DATAASC record per line — its
/// UTF-8 blank-padded to the declared width (765), a longer line cut —
/// in one LZH cell, a FORMAT record of the bean's own (blank name, offset
/// 1, length = the width, type `X`), an empty PROPS, NO 06 67 trailer
/// (a recorded session gui[22]: 8 x 765 = 6 120 B). The SAP GUI
/// for Windows TextEdit OCX's object: [r3AbapWindowsPullAnswer].
Uint8List r3AbapPullAnswer(Uint8List request, List<String> lines) {
  final declared = clientTablePullTableWidth(request);
  final w = declared > 0 ? declared : r3AbapRecordWidth;
  final rows = [for (final line in lines) _r3AbapRecord(line, w)];
  final format = Uint8List(79)
    ..setRange(60, 76, [
      ..._le64(1),
      ..._le64(w),
    ])
    ..[76] = 0x58 // 'X'
    ..[77] = 0x01;
  final table = BytesBuilder(copy: false)
    ..add(_tableHead('DATAASC', w, rows.length))
    ..add(tableColumn(rows, width: w))
    ..add(_tableHead('FORMAT', 80, 1))
    ..add(tableColumn([format]))
    ..add(_tableHead('PROPS', 80, 0));
  return buildDpAnswer(
    scalars: {
      'TYPE': 'APPLICATION',
      'SUBTYPE': 'X-R3ABAP',
      'DATE': '',
      'TIME': '',
      'DESCRIPTION': '',
      'TOTALSIZE': _le32(w * rows.length),
      'PLATTFORM': '',
    },
    extraScalars: const [('SEND_DATA_AS_STRING', '')],
    tableRegion: table.takeBytes(),
    trailer: false,
  );
}

/// The SAP GUI for Windows' answer to the server's read-back of a TextEdit
/// (`SAPGUI.TextEditCtrl.1`, textedit.dll) holding [lines]: the OCX's
/// X-R3ABAP object — `AssignProperty2(<editor>, TextAsR3Table, <obj>,
/// r3TableAutoObj)` + `SaveDataToUrl(APPLICATION, X-R3ABAP, <sink>)`, then
/// the untyped DP_GET of the sink ([request] its RFC value). The empty
/// text's answer is a recorded session g[19] (and g[24] …
/// g[45], all seven pulls of PPOSE's long text): TYPE APPLICATION, SUBTYPE
/// X-R3ABAP, DATE `00000000` / TIME `000000`, blank DESCRIPTION and
/// PLATTFORM, TOTALSIZE 0, the DATAASC table at the width the request
/// declares (243 there) with no row, FORMAT and PROPS 80 x 0, the 06 67
/// trailer — no SEND_DATA_AS_STRING scalar (the Java bean's object has one
/// and no trailer: [r3AbapPullAnswer]).
///
/// A text is answered as the Java bean's records ([r3AbapPullAnswer], the
/// only recorded non-empty X-R3ABAP read-back: a recorded session
/// saved gui[22]): one DATAASC record per line, its UTF-8 blank-padded to
/// the declared width, TOTALSIZE = the records' bytes, the request's own
/// FORMAT records echoed. A non-empty Windows answer is UNRECORDED — its
/// record encoding, TOTALSIZE and FORMAT are this reading, never an empty
/// table for a control that holds text.
Uint8List r3AbapWindowsPullAnswer(Uint8List request, List<String> lines) {
  final declared = clientTablePullTableWidth(request);
  final w = declared > 0 ? declared : r3AbapRecordWidth;
  final rows = [for (final line in lines) _r3AbapRecord(line, w)];
  // inline `03 04` records go with their trailing blanks cut to one (the
  // one-record text of a recorded session g[23]: a
  // 243-wide record sent as its text + one blank); the switch to the LZH
  // cell is by the full records' bytes (243 inline, 5 x 243 = 1215 one
  // cell: g[28] / g[32]) — the rows in the cell keep their padding
  final inline = rows.fold(0, (a, r) => a + r.length) <= tableInlineMax;
  final (_, (fw, fn), fcells) = dpColumnCells(request, 'FORMAT');
  final f = BytesBuilder(copy: false);
  for (final c in fcells) {
    f.add(c);
  }
  final fb = f.takeBytes();
  final frw = fw > 0 ? fw : 80;
  final formats = [
    for (var i = 0; (i + 1) * frw <= fb.length && (fn <= 0 || i < fn); i++)
      Uint8List.sublistView(fb, i * frw, (i + 1) * frw),
  ];
  final table = BytesBuilder(copy: false)
    ..add(_tableHead('DATAASC', w, rows.length))
    ..add(
      tableColumn(
        inline ? [for (final r in rows) collapseInlineRow(r)] : rows,
        width: w,
      ),
    )
    ..add(_tableHead('FORMAT', frw, formats.length))
    ..add(tableColumn(formats, width: frw))
    ..add(_tableHead('PROPS', 80, 0));
  return buildDpAnswer(
    scalars: {
      'TYPE': 'APPLICATION',
      'SUBTYPE': 'X-R3ABAP',
      'DATE': '00000000',
      'TIME': '000000',
      'DESCRIPTION': '',
      'TOTALSIZE': _le32(w * rows.length),
      'PLATTFORM': '',
    },
    tableRegion: table.takeBytes(),
  );
}

/// The lines a TextEdit's read-back returns for its text [e]: with the
/// server's fixed-position word wrap converted to line breaks
/// (`WordWrapMode` 2, `WordWrapPosition` p, `ConvertWordWrapToLineBreak`
/// 1 — CL_GUI_TEXTEDIT's wordwrap_to_linebreak_mode) each line wrapped at
/// p ([wrapTextEditLine]); otherwise the lines as held. Every recorded
/// read-back returns the pushed lines unchanged: PPOSE pushes its long text
/// already cut at 72 (a recorded session s[18]: 8
/// lines of at most 72 characters, read back as the same 8 records, g[18])
/// — a pushed line past the position is unrecorded, its wrap is the
/// control's documented mode, not a wire-proven one. Mode 1 (the window
/// border) depends on the control's width and is not applied.
List<String> textEditReadBackLines(SapTextEditor e) {
  final p = e.wordWrapPosition;
  if (e.wordWrapMode != 2 || !e.wordWrapToLineBreak || p == null || p < 1) {
    return e.lines;
  }
  return [for (final l in e.lines) ...wrapTextEditLine(l, p)];
}

/// [line] wrapped at column [position]: each piece at most [position]
/// characters, broken after the last blank that fits — the blank itself
/// not kept (the 71-character records of a recorded session
/// accent_long end without their separator); a word longer than
/// [position] is cut hard at it. A line that fits is returned as it is.
List<String> wrapTextEditLine(String line, int position) {
  final out = <String>[];
  var rest = line;
  while (rest.length > position) {
    final cut = rest.lastIndexOf(' ', position);
    if (cut <= 0) {
      out.add(rest.substring(0, position));
      rest = rest.substring(position);
    } else {
      out.add(rest.substring(0, cut));
      rest = rest.substring(cut + 1);
    }
  }
  out.add(rest);
  return out;
}

/// One X-R3ABAP record: [line]'s UTF-8 blank-padded to [w] bytes, a longer
/// line cut on a character boundary (a split UTF-8 sequence is no text).
Uint8List _r3AbapRecord(String line, int w) {
  final b = utf8.encode(line);
  final r = Uint8List(w)..fillRange(0, w, 0x20);
  var n = b.length < w ? b.length : w;
  while (n < b.length && n > 0 && (b[n] & 0xc0) == 0x80) {
    n--;
  }
  r.setRange(0, n, b);
  return r;
}

/// A reply table's name and dims: `03 01 <name> 03 01`, `03 02 <width u32>
/// <rows u32> 03 02` (its rows follow: [tableColumn]).
Uint8List _tableHead(String name, int width, int rows) {
  final dims = ByteData(8)
    ..setUint32(0, width)
    ..setUint32(4, rows);
  return Uint8List.fromList([
    ...rfcToken(0x03, 0x01, Uint8List.fromList(name.codeUnits)),
    ...rfcToken(0x03, 0x02, dims.buffer.asUint8List()),
  ]);
}

/// [n] as the 4 characters of a little-endian u32 (a TOTALSIZE scalar).
String _le32(int n) => String.fromCharCodes([
  n & 0xff,
  (n >> 8) & 0xff,
  (n >> 16) & 0xff,
  (n >> 24) & 0xff,
]);

List<int> _le64(int n) => [
  for (var i = 0; i < 8; i++) i < 4 ? (n >> (8 * i)) & 0xff : 0,
];

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call.
final RegExp _markerLinesRx = RegExp(r'\d+');
final RegExp _splitEditorLinesRx = RegExp('\r\n|\r|\n');
