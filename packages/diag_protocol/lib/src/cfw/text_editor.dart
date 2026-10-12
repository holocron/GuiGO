/// Editor controls — the workbench's ABAP editor (SE38 / SE80 / SE37 / SE24
/// source display) and the SAPGUI TextEdit control — with the text the
/// server pushes into them through the DataProvider (read side only).
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
library;

import 'dart:convert';
import 'dart:typed_data';

import 'dp_cache.dart';
import 'flush_call.dart';

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

  /// The text, one entry per line (right-trimmed records for TextEdit).
  List<String> lines;

  /// Whether the server set the document read-only (display mode).
  bool readOnly;

  /// The 1-based line the server put the cursor on, null when it set none.
  int? cursorLine;

  /// The 1-based column of the cursor (the server's
  /// `SetSelectionPosInLine(line, col)`, or the position an editor action
  /// last flushed), null when unknown.
  int? cursorCol;

  /// The first line the editor shows (the server's `FirstVisibleLine(=n)`
  /// put), null when it set none.
  int? firstVisibleLine;

  /// The first / last line the user's view of the control actually shows
  /// (1-based), as the app reports it (SapSession.setEditorClientState);
  /// null = not reported since the server last scrolled the control. The
  /// real GUI answers the server's read-back of FirstVisibleLine from its
  /// LIVE view (a recorded session gui[22]: 184 after
  /// the user scrolled), not from the server's last put.
  int? viewFirstLine;
  int? viewLastLine;

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
  'SetMarker',
  'RemoveMarker',
  'RemoveAllMarker',
  'FirstVisibleLine',
};

/// The ABAP editor's session-breakpoint marker kind (`SetMarker(2, …)`).
const int ab4BreakpointMarker = 2;

/// The editor verbs whose on-object is the editor itself.
const Set<String> _editorVerbs = {
  ..._ab4Verbs,
  'ReadOnly',
  'ReadOnlyMode',
  'TextStream',
  'Text',
};

/// The DataProvider-fed TextEdit body properties (reference client PUSH_PROPS).
const Set<String> _pushProps = {'TextAsR3Table', 'TextAsR3Stream'};

final RegExp _digits = RegExp(r'^\d+$');

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
    final text = latin1.decode(rfc, allowInvalid: true);
    if (!text.contains('OLE_FLUSH_CALL')) return const {};
    final call = parsed ?? parseFlushCall(rfc);
    if (call.verbs.isEmpty) return const {};
    final meta = verbMeta(call);
    final rowShell = <String, String>{}; // CreateControl _RESULT row -> shell
    final rowUrl = <String, String>{}; // DataProvider row -> its url
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
        areaOf.remove(shell);
        linkOf.remove(shell);
        paintedOn.remove(shell);
        loaded.remove(shell);
        final kind = textEditorKind(named['#2'] ?? '');
        _order.remove(shell);
        _editors.remove(shell);
        if (kind != null) {
          _editors[shell] = SapTextEditor(shell: shell, kind: kind);
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
        case 'AddEmptyDoc':
          e.lines = [];
          e.cursorLine = null;
          e.cursorCol = null;
          e.viewFirstLine = null;
          e.viewLastLine = null;
          e.breakpoints.clear();
          e.markers.clear();
        case 'LoadDocFromDP':
          // the DataProvider it loads from: by row, else the last url set
          final dpRow = (m.slots['#2'] ?? '').trim();
          final url =
              rowUrl[dpRow] ??
              (rowUrl.values.isEmpty ? null : rowUrl.values.last);
          final seg = url == null ? null : segment(url);
          final doc = seg == null ? null : databinText(seg);
          if (doc == null) continue;
          e.lines = splitEditorLines(doc);
        case 'SetCurrentDocReadOnly' || 'ReadOnly' || 'ReadOnlyMode':
          e.readOnly = _truthy(arg('#1'));
          text = false;
        case 'SetSelectionPosInLine':
          e.cursorLine = int.tryParse(arg('#1').trim());
          e.cursorCol = int.tryParse((named['#2'] ?? '').trim());
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
  for (final m in RegExp(r'\d+').allMatches(v)) int.parse(m.group(0)!),
];

/// Split an editor document into lines (CR, LF or CRLF separated; a
/// trailing separator ends the last line, it opens no empty one).
List<String> splitEditorLines(String doc) {
  if (doc.isEmpty) return [];
  final lines = doc.split(RegExp('\r\n|\r|\n'));
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
  final c = dpPutContent(seg);
  final total = c != null && c.column == 'DATABIN' ? c.expected : 0;
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
  if (name.isEmpty || cells.isEmpty) return null;
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
