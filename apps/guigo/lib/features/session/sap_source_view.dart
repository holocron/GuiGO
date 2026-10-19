import 'dart:async';
import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart'
    show ab4InsertUndoSteps, editorVisibleLines;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// ABAP keywords highlighted in the source view (the common statement and
/// clause words; the server's own editor colours by its keyword table).
const _abapKeywords = {
  'REPORT', 'PROGRAM', 'FUNCTION', 'ENDFUNCTION', 'FORM', 'ENDFORM', 'PERFORM',
  'CLASS', 'ENDCLASS', 'METHOD', 'ENDMETHOD', 'METHODS', 'DEFINITION',
  'IMPLEMENTATION', 'PUBLIC', 'PROTECTED', 'PRIVATE', 'SECTION', 'INTERFACE',
  'ENDINTERFACE', 'DATA', 'TYPES', 'TYPE', 'REF', 'TO', 'LIKE', 'VALUE',
  'CONSTANTS', 'PARAMETERS', 'SELECT-OPTIONS', 'SELECTION-SCREEN', 'TABLES',
  'FIELD-SYMBOLS', 'IF', 'ELSEIF', 'ELSE', 'ENDIF', 'CASE', 'WHEN', 'ENDCASE',
  'DO', 'ENDDO', 'WHILE', 'ENDWHILE', 'LOOP', 'AT', 'ENDLOOP', 'ENDAT', 'SELECT',
  'ENDSELECT', 'FROM', 'INTO', 'WHERE', 'AND', 'OR', 'NOT', 'IS', 'INITIAL',
  'BOUND', 'ASSIGNED', 'IN', 'TABLE', 'APPENDING', 'CORRESPONDING', 'FIELDS',
  'UP', 'ROWS', 'ORDER', 'BY', 'GROUP', 'HAVING', 'SINGLE', 'DISTINCT', 'JOIN',
  'INNER', 'LEFT', 'OUTER', 'ON', 'READ', 'WITH', 'KEY', 'BINARY', 'SEARCH',
  'MODIFY', 'INSERT', 'DELETE', 'UPDATE', 'APPEND', 'CLEAR', 'REFRESH', 'FREE',
  'MOVE', 'WRITE', 'MESSAGE', 'CALL', 'TRANSACTION', 'SCREEN', 'EXPORTING',
  'IMPORTING', 'CHANGING', 'RETURNING', 'RAISING', 'EXCEPTIONS', 'TRY', 'CATCH',
  'CLEANUP', 'ENDTRY', 'RAISE', 'EXCEPTION', 'NEW', 'CREATE', 'OBJECT',
  'RETURN', 'EXIT', 'CONTINUE', 'CHECK', 'START-OF-SELECTION',
  'END-OF-SELECTION', 'INITIALIZATION', 'AT SELECTION-SCREEN', 'INCLUDE',
  'STRUCTURE', 'BEGIN', 'END', 'OF', 'OCCURS', 'STANDARD', 'SORTED', 'HASHED',
  'UNIQUE', 'DEFAULT', 'OBLIGATORY', 'CONCATENATE', 'SPLIT', 'CONDENSE',
  'TRANSLATE', 'REPLACE', 'FIND', 'SHIFT', 'SORT', 'DESCENDING', 'ASCENDING',
  'COMMIT', 'ROLLBACK', 'WORK', 'AUTHORITY-CHECK', 'ID', 'FIELD', 'ASSIGN',
  'COMPONENT', 'CASTING', 'ABAP_TRUE', 'ABAP_FALSE', 'ME', 'SUPER', 'FINAL',
  'ABSTRACT', 'INHERITING', 'STATIC', 'CLASS-METHODS', 'CLASS-DATA', 'ALIASES',
  'EVENTS', 'FOR', 'HANDLER', 'SET', 'GET', 'PARAMETER', 'SUBMIT', 'AND RETURN',
};

/// One highlighted piece of a source line.
class SourceToken {
  SourceToken(this.text, this.kind);
  final String text;

  /// 'kw', 'comment', 'string', 'number', 'text'.
  final String kind;
}

/// Split one ABAP line into highlighted tokens: a `*` in column 1 or a `"`
/// starts a comment, '…' / `…` / |…| are literals, keywords by the table.
List<SourceToken> tokenizeAbap(String line) {
  // once per line text: a caret tap, a selection drag or a scroll rebuilt
  // the rows on screen, each re-tokenized (a bounded memo)
  final known = _tokensMemo[line];
  if (known != null) return known;
  if (_tokensMemo.length >= 4096) _tokensMemo.clear();
  return _tokensMemo[line] = _tokenize(line);
}

final Map<String, List<SourceToken>> _tokensMemo = {};

final RegExp _abapTokenRx = RegExp(r'''("[^\n]*$)|('(?:[^']|'')*'?)|(`(?:[^`]|``)*`?)|(\|[^|]*\|?)|(\b\d+\b)|([A-Za-z_/][A-Za-z0-9_/\-~>=]*)|(\s+|.)''');

final RegExp _abapWordRx = RegExp(r'[A-Za-z0-9_/\-~>=]+');

List<SourceToken> _tokenize(String line) {
  if (line.startsWith('*')) return [SourceToken(line, 'comment')];
  final out = <SourceToken>[];
  for (final m in _abapTokenRx.allMatches(line)) {
    final t = m.group(0)!;
    if (m.group(1) != null) {
      out.add(SourceToken(t, 'comment'));
    } else if (m.group(2) != null || m.group(3) != null || m.group(4) != null) {
      out.add(SourceToken(t, 'string'));
    } else if (m.group(5) != null) {
      out.add(SourceToken(t, 'number'));
    } else if (m.group(6) != null && _abapKeywords.contains(t.toUpperCase())) {
      out.add(SourceToken(t, 'kw'));
    } else {
      out.add(SourceToken(t, 'text'));
    }
  }
  return out;
}

/// The word (identifier) under character column [col] (0-based) of [line],
/// with its start column — what a double-click navigates on.
(String, int)? wordAt(String line, int col) {
  if (col < 0 || col >= line.length) return null;
  for (final m in _abapWordRx.allMatches(line)) {
    if (col >= m.start && col < m.end) return (m.group(0)!, m.start);
  }
  return null;
}


/// The text between two positions of [lines] — (1-based line, 0-based
/// character offset), [start] before [end] — the lines joined with '\n'.
/// Every line is taken as the editor holds it (the server's own trailing
/// blanks kept, a TextEdit's records already right-trimmed); an offset past
/// a line's end is its end: no virtual blanks are invented, as the SAP
/// editors copy only the characters a line has.
String sourceSelectionText(
    List<String> lines, (int, int) start, (int, int) end) {
  if (lines.isEmpty) return '';
  final l1 = start.$1.clamp(1, lines.length), l2 = end.$1.clamp(1, lines.length);
  if (l2 < l1) return '';
  String cut(int l, int from, int to) {
    final s = lines[l - 1];
    final a = from.clamp(0, s.length), b = to.clamp(0, s.length);
    return b <= a ? '' : s.substring(a, b);
  }

  if (l1 == l2) return cut(l1, start.$2, end.$2);
  return [
    cut(l1, start.$2, 1 << 30),
    for (var l = l1 + 1; l < l2; l++) lines[l - 1],
    cut(l2, 0, end.$2),
  ].join('\n');
}

class _SelectAllIntent extends Intent {
  const _SelectAllIntent();
}

class _CopyIntent extends Intent {
  const _CopyIntent();
}

class _ClearSelectionIntent extends Intent {
  const _ClearSelectionIntent();
}

class _BreakpointKeyIntent extends Intent {
  const _BreakpointKeyIntent();
}

class _PasteIntent extends Intent {
  const _PasteIntent();
}

class _CutIntent extends Intent {
  const _CutIntent();
}

/// The text a line of an edited source starts with in the platform's
/// editing value: a zero-width space before the line's own text, so a
/// Backspace at the line's start still deletes something the platform can
/// report — the line break to join ([_SapSourceViewState.updateEditingValue]).
const String _imeLead = '\u200B';

final RegExp _lineBreakRx = RegExp('\r\n|\r|\n');

/// The blanks a line starts with (its indentation).
final RegExp _leadingBlanksRx = RegExp(r'^[ \t]*');

/// The gutter mark of a breakpoint of another kind than the session one
/// (an external / user breakpoint): SAP's ICON_USER_BREAKPOINT, a red dot
/// with a small person over its corner.
class _OtherBreakpointDot extends StatelessWidget {
  const _OtherBreakpointDot({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'External breakpoint',
        child: SizedBox(
          width: 14,
          height: 14,
          child: Stack(clipBehavior: Clip.none, children: [
            Positioned(
              left: 0,
              top: 0,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5484D),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF8E1B1F), width: 1),
                ),
              ),
            ),
            const Positioned(
              right: -1,
              bottom: -1,
              child: Icon(Icons.person, size: 9, color: Color(0xFF3B4A57)),
            ),
          ]),
        ),
      );
}

/// A key action of the view, enabled only while [enabled] holds.
class _ViewAction<T extends Intent> extends Action<T> {
  _ViewAction(this.enabled, this.run);
  final bool Function() enabled;
  final void Function() run;

  @override
  bool isEnabled(T intent) => enabled();

  @override
  Object? invoke(T intent) {
    run();
    return null;
  }
}

/// An ABAP source editor control (SE38 / SE80 / SE24, and the TextEdit
/// long-text control) as a code view: numbered lines, syntax colours,
/// breakpoint markers in the gutter.
///
/// Gestures (touch first, as text reads on an iPad; a vertical swipe stays
/// the scroll):
/// * tap in the code: the caret ([onCaret]); a tap in the gutter of a
/// line — its left margin, its number, a breakpoint dot on it — is the
/// editor's margin click on that line ([onToggleBreakpoint]: the server
/// sets the session breakpoint, or removes the one there). It is the
/// only thing a gutter tap does: never another key. The 6-point gap
/// between the gutter and the code belongs to the code: a finger that
/// aimed at a line's first character and landed short parks the caret
/// on column 1 instead of planting a breakpoint;
/// * double tap on a token: navigate to its definition ([onNavigate],
/// 1-based line and column, the editor's double-click; the first tap
/// put the caret there, as the real GUI's click before its -601);
/// * long press: selects the word under the finger and shows the
/// system's text toolbar — Copy, Select all, navigate, where-used
/// ([onWhereUsed]), breakpoint; keep the finger down and drag to extend
/// the selection character by character, or drag the selection's
/// handles afterwards. A long press in the gutter selects whole lines;
/// * a mouse / trackpad drag selects directly, the secondary click opens
/// the toolbar;
/// * hardware keyboard (the view focused by a tap): Cmd/Ctrl+A selects
/// all, Cmd/Ctrl+C copies, Esc drops the selection, Ctrl+Shift+F12 sets
/// / removes the session breakpoint on the caret's line
/// ([onBreakpointKey], the editor's own shortcut).
///
/// Display mode (the default) is read-only: the source changes on the
/// server only, there is no cut or paste and no keyboard comes up. With
/// [editable] (the ABAP editor in change mode: the server's
/// `SetCurrentDocReadOnly(0)`, SapSession.editorEditable) a tap also puts
/// an editing caret in the code and brings the keyboard — the iPad's
/// soft keyboard or a hardware one — and every edit is handed to
/// [onEdit]: typing (a selection is replaced), Return splits the line —
/// the new line indented as the text before the break, as the ABAP
/// editor keeps a block's indentation on Enter — Backspace / Delete join
/// lines at their ends, Cmd/Ctrl+V and the toolbar's Paste insert (a
/// multi-line text splits into lines), Cut, the arrows / Home / End move
/// the caret, Tab / Shift+Tab indent / outdent (the soft keyboards have
/// no Tab: the long-press menu's Indent / Outdent shift the caret's line
/// or the selected lines by two). Nothing is sent per keystroke: the
/// real SAP GUI keeps the edit in the control and reports it in the next
/// round (a recorded session: no traffic while typing; the
/// F11 of a recorded session g[41] carries TextModified 1).
class SapSourceView extends StatefulWidget {
  const SapSourceView({
    super.key,
    required this.lines,
    this.editable = false,
    this.onEdit,
    this.breakpoints = const {},
    this.otherBreakpoints = const {},
    this.externalBreakpoints = const {},
    this.currentLine,
    this.firstVisibleLine,
    this.scrollSerial = 0,
    this.onToggleBreakpoint,
    this.onBreakpointKey,
    this.onNavigate,
    this.onWhereUsed,
    this.onViewport,
    this.onViewLines,
    this.onCaret,
    this.onSelection,
  });

  final List<String> lines;

  /// Whether the user may edit the text (the editor in change mode); false
  /// is display mode — no caret, no keyboard, no edit.
  final bool editable;

  /// An edit of an [editable] view: the whole text after it, the caret
  /// (1-based line and column, the slot after its last character at most)
  /// and how many undo steps the edit opens — 1 for a Return, a typed
  /// character (each one: `ab` is 2, a recorded session
  /// g[77]), a deletion, a cut; a paste's or a multi-line insert's
  /// [ab4InsertUndoSteps] (the five lines of _long g[27]: 6). The
  /// control's Version counts the steps.
  final void Function(
    List<String> lines,
    int caretLine,
    int caretCol,
    int undoSteps,
  )? onEdit;

  /// The lines with a SESSION breakpoint (the server's marker 2): a solid
  /// red dot.
  final Set<int> breakpoints;

  /// The lines with a breakpoint of another kind (an external / user
  /// breakpoint the toolbar's Ctrl+Shift+F9 set, a disabled one —
  /// SapTextEditor.otherBreakpoints): a red dot with a small person, as
  /// SAP's ICON_USER_BREAKPOINT.
  final Set<int> otherBreakpoints;

  /// The lines of [otherBreakpoints] that carry an EXTERNAL breakpoint
  /// (SapTextEditor.externalBreakpoints, the server's marker 4): a margin
  /// click on one removes it (a recorded session
  /// s[28]), so the long-press menu says so.
  final Set<int> externalBreakpoints;
  final int? currentLine;

  /// The line the server scrolled the editor to (its FirstVisibleLine
  /// property, 1-based): a navigation — a where-used pick, a double-click
  /// on a FORM — opens the editor there, not on line 1. Followed when it
  /// (or [scrollSerial]) changes or a new text arrives, never on a round
  /// that leaves it as it was: the user's own scrolling stands.
  final int? firstVisibleLine;

  /// The count of the server's FirstVisibleLine puts
  /// (SapTextEditor.firstVisibleLinePuts): a new put scrolls the view to
  /// [firstVisibleLine] even when it repeats the last one (a navigation
  /// back to the same spot after the user scrolled away).
  final int scrollSerial;

  /// A tap in the gutter of a line — its margin, its number or the dot on
  /// it; not the gap before the code (the editor's margin click), or the
  /// long-press menu's breakpoint entry: the one breakpoint action of the
  /// view.
  final void Function(int line)? onToggleBreakpoint;

  /// Ctrl+Shift+F12 on a hardware keyboard: the breakpoint KEY with the
  /// caret's line (1 when no caret was placed).
  final void Function(int line)? onBreakpointKey;
  final void Function(int line, int col)? onNavigate;
  final void Function(int line, int col)? onWhereUsed;

  /// The lines the view actually shows (1-based first / last), reported
  /// after the first layout and whenever the user's scrolling changes them
  /// — the editor control's client state the server reads back
  /// (FirstVisibleLine / LastVisibleLine).
  final void Function(int firstLine, int lastLine)? onViewport;

  /// How many lines the laid-out view shows from its top — its viewport's
  /// capacity, [editorVisibleLines] of its height at [lineHeight] a line —
  /// reported after the first layout and whenever its height changes: the
  /// count the session's LastVisibleLine of a NEW document is computed
  /// from (SapSession.editorViewLines) before the view shows it, so the
  /// [onViewport] that follows reports the same last line.
  final void Function(int lines)? onViewLines;

  /// The height of one source line (points): the view's row pitch.
  static const double lineHeight = 20;

  /// How many lines a view [height] points tall shows from its top (the
  /// partly visible last one counted): what [onViewLines] reports.
  static int linesFitting(double height) =>
      editorVisibleLines(height, lineHeight);

  /// A single tap in the code: the caret (1-based line, column) — the
  /// control's SelPosStartLine / SelPosStartCol, the selection collapsed.
  final void Function(int line, int col)? onCaret;

  /// A selection the user made (long press, handles, mouse drag, select
  /// all): its start and end, 1-based, [endCol] the column AFTER the last
  /// selected character — the control's SelPosStartLine / SelPosStartCol /
  /// SelPosEndLine / SelPosEndCol client state (a collapsed caret flushes
  /// the same column twice, a recorded session gui[19]).
  final void Function(int startLine, int startCol, int endLine, int endCol)?
      onSelection;

  @override
  State<SapSourceView> createState() => _SapSourceViewState();
}

class _SapSourceViewState extends State<SapSourceView> with TextInputClient {
  static const double _fontSize = 13;
  static const double _lineH = SapSourceView.lineHeight;

  /// The gutter's content-free strip before the code (the number's right
  /// padding): drawn and hit-tested with the same width, so a tap in it
  /// is the code's — the caret on column 1 — and never a margin click.
  static const double _gutterPad = 6;
  final _h = ScrollController();
  final _v = ScrollController();
  final _listKey = GlobalKey();
  final _focus = FocusNode(debugLabel: 'SapSourceView');
  final _toolbar = ContextMenuController();
  (int, int)? _selected; // the token the last gesture hit (line, col)
  double? _charW;
  double _gutterW = 0;

  (int, int)? _view; // the (first, last) lines last reported
  int? _capacity; // the view's line capacity last reported

  // the selection: (1-based line, 0-based character offset) — the anchor
  // the gesture started from, the extent it moved to
  (int, int)? _anchor;
  (int, int)? _extent;
  // the word a long press selected: the selection grows from its far side
  (int, int, int)? _word; // (line, start, end)
  bool _lineMode = false; // a gutter long press selects whole lines
  int? _lineAnchor;
  (int, int)? _menuAt; // the (line, col) the toolbar's navigate acts on
  bool _dragging = false;
  double _grabDy = 0; // a handle's grip: finger to line centre

  // the first tap of a possible double tap (its hit and the window)
  Timer? _tapWindow;
  (int, int)? _firstTap;
  Offset? _firstTapAt;

  // ---- editing (an [SapSourceView.editable] view) ----
  /// The text as the user edited it, until the parent hands the same text
  /// back as [SapSourceView.lines] (or the server replaces it).
  List<String>? _doc;
  List<String> get _lines => _doc ?? widget.lines;

  /// The editing caret: (1-based line, 0-based character offset).
  (int, int)? _caret;

  TextInputConnection? _input;

  /// The platform's editing value: [_imeLead] + the caret's line.
  TextEditingValue _ime = const TextEditingValue();

  bool get _editing => widget.editable && widget.onEdit != null;

  @override
  void initState() {
    super.initState();
    _v.addListener(_reportView);
    _v.addListener(_hideOnScroll);
    _h.addListener(_hideOnScroll);
    _focus.addListener(_onFocus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _follow();
      _reportView();
    });
  }

  /// Report the lines on screen through [SapSourceView.onViewport] when
  /// they changed.
  void _reportView() {
    if (!_v.hasClients) return;
    final p = _v.position;
    if (!p.hasPixels || !p.hasViewportDimension) return;
    final fits = SapSourceView.linesFitting(p.viewportDimension);
    if (fits != _capacity) {
      _capacity = fits;
      widget.onViewLines?.call(fits);
    }
    final cb = widget.onViewport;
    final n = _lines.length;
    if (cb == null || n == 0) return;
    final first = (p.pixels / _lineH).floor().clamp(0, n - 1) + 1;
    final last = ((p.pixels + p.viewportDimension) / _lineH).ceil().clamp(first, n);
    if (_view == (first, last)) return;
    _view = (first, last);
    cb(first, last);
  }

  void _hideOnScroll() {
    if (!_dragging && _toolbar.isShown) _toolbar.remove();
  }

  /// The longest line's length, once per text (every build — a caret tap,
  /// a drag — folded over the whole document); the length guards a list
  /// grown in place.
  List<String>? _longestFor;
  int _longestLen = -1;
  int _longest = 0;

  int _longestOf(List<String> lines) {
    if (identical(lines, _longestFor) && lines.length == _longestLen) {
      return _longest;
    }
    _longestFor = lines;
    _longestLen = lines.length;
    return _longest = lines.fold<int>(0, (a, l) => l.length > a ? l.length : a);
  }

  @override
  void didUpdateWidget(SapSourceView old) {
    super.didUpdateWidget(old);
    // only a scroll the SERVER sent moves the view to its first visible
    // line (a FirstVisibleLine put, a new text): the user's own scrolling
    // stays until the next navigation. A cursor the server moved without
    // scrolling (a breakpoint toggle answers SetSelectionPosInLine +
    // SetMarker only, a recorded session s[32]/s[33]) is brought
    // into view only when off screen — the stale first visible line of the
    // last put must not undo the user's scroll ("I scroll down, set a
    // breakpoint, the code scrolls back to line 24"); a caret the user
    // tapped is no server move at all. The text the user edited, handed
    // back as the same lines, is no new text either: the caret, the
    // scroll and the keyboard stay
    final shown = _doc ?? old.lines;
    final newText = !identical(shown, widget.lines) &&
        !listEquals(shown, widget.lines);
    // the user's edit handed back as the session's own copy: the same
    // text, the same longest line (no fold over the document again)
    if (!newText && identical(shown, _longestFor)) {
      _longestFor = widget.lines;
      _longestLen = widget.lines.length;
    }
    _doc = null;
    if (newText || !_editing) {
      if (!_editing) {
        _caret = null;
        _closeInput();
      } else if (_caret != null) {
        // the server's text: the caret kept where it still exists
        final n = widget.lines.length;
        final l = _caret!.$1.clamp(1, n < 1 ? 1 : n);
        final len = n == 0 ? 0 : widget.lines[l - 1].length;
        _caret = (l, _caret!.$2.clamp(0, len));
        WidgetsBinding.instance.addPostFrameCallback((_) => _syncInput());
      }
    }
    final scrolled = old.firstVisibleLine != widget.firstVisibleLine ||
        old.scrollSerial != widget.scrollSerial;
    if (scrolled || newText) {
      // reported again after it: a server scroll resets the control's
      // client state
      _view = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _follow();
        _reportView();
      });
    } else if (old.currentLine != widget.currentLine &&
        widget.currentLine != _selected?.$1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _follow(toFirstLine: false);
        _reportView();
      });
    }
    // a new text: the selection was in the old one
    if (newText) {
      _anchor = _extent = null;
      _word = null;
      if (_toolbar.isShown) _toolbar.remove();
    }
  }

  /// Scroll to the server's first visible line; without one (or with
  /// [toFirstLine] false: the server moved the cursor only), bring the
  /// cursor line into view when it is off screen.
  void _follow({bool toFirstLine = true}) {
    if (!mounted || !_v.hasClients) return;
    final p = _v.position;
    double? to;
    final first = widget.firstVisibleLine;
    final cur = widget.currentLine;
    if (toFirstLine && first != null && first > 0) {
      to = (first - 1) * _lineH;
    } else if (cur != null && cur > 0) {
      final top = (cur - 1) * _lineH;
      if (top < p.pixels || top + _lineH > p.pixels + p.viewportDimension) {
        to = top - p.viewportDimension / 3;
      }
    }
    if (to != null) _v.jumpTo(to.clamp(p.minScrollExtent, p.maxScrollExtent));
  }

  @override
  void dispose() {
    _tapWindow?.cancel();
    _toolbar.remove();
    _closeInput();
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _h.dispose();
    _v.dispose();
    super.dispose();
  }

  // letterSpacing 0: the hit test measures glyphs untracked; Material 3's
  // body text (0.25 pt a glyph) drew them wider, so a double tap near the
  // end of a long name hit the column after it (SE38 line 26
  // `workflow_instance_delete.` → "Position du curseur erronée")
  TextStyle get _mono => const TextStyle(
      fontFamily: 'Menlo',
      fontFamilyFallback: ['Courier New', 'monospace'],
      fontSize: _fontSize,
      height: 1.0,
      letterSpacing: 0);

  double _measureCharW() {
    final tp = TextPainter(
      text: TextSpan(text: 'MMMMMMMMMM', style: _mono),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = tp.width / 10;
    tp.dispose();
    return w;
  }

  double get _cw => _charW ?? 8;

  // the code text starts after the gutter and the row's 8-point padding
  double get _textLeft => _gutterW + 8;

  RenderBox? get _listBox => _listKey.currentContext?.findRenderObject() as RenderBox?;

  /// A global pointer position in the list's content coordinates (x across
  /// the full width, y from the first line).
  Offset? _content(Offset global) {
    final box = _listBox;
    if (box == null || !_v.hasClients) return null;
    final l = box.globalToLocal(global);
    return Offset(l.dx, l.dy + _v.offset);
  }

  int _lineOf(double y) => (y / _lineH).floor().clamp(0, _lines.length - 1) + 1;

  /// 1-based (line, col) of the character under a pointer (what a tap,
  /// a double tap, a navigation acts on).
  (int, int)? _cellAt(Offset global) {
    final c = _content(global);
    if (c == null || _lines.isEmpty) return null;
    return (_lineOf(c.dy), ((c.dx - _textLeft) / _cw).floor().clamp(0, 1 << 20) + 1);
  }

  /// (1-based line, 0-based offset) of the character boundary nearest a
  /// pointer (a selection end).
  (int, int)? _posAt(Offset global) {
    final c = _content(global);
    if (c == null || _lines.isEmpty) return null;
    final line = _lineOf(c.dy);
    final len = _lines[line - 1].length;
    return (line, ((c.dx - _textLeft) / _cw).round().clamp(0, len));
  }

  bool _inGutter(Offset global) {
    final c = _content(global);
    return c != null && c.dx < _gutterW - _gutterPad;
  }

  static int _cmp((int, int) a, (int, int) b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2;

  bool get _hasSelection => _anchor != null && _extent != null && _anchor != _extent;
  (int, int) get _start => _cmp(_anchor!, _extent!) <= 0 ? _anchor! : _extent!;
  (int, int) get _end => _cmp(_anchor!, _extent!) <= 0 ? _extent! : _anchor!;

  String get _selectedText => _hasSelection ? sourceSelectionText(_lines, _start, _end) : '';

  bool get _allSelected {
    if (!_hasSelection || _lines.isEmpty) return false;
    final n = _lines.length;
    return _start == (1, 0) && _end == (n, _lines[n - 1].length);
  }

  void _clearSelection() {
    if (_toolbar.isShown) _toolbar.remove();
    if (_anchor == null && _extent == null) return;
    setState(() {
      _anchor = _extent = null;
      _word = null;
      _lineMode = false;
    });
  }

  /// Whether a whole-line selection of the gutter is up (an empty line
  /// selected alone included: its span is the line break).
  bool get _hasLineSelection => _lineMode && _anchor != null && _extent != null;

  /// Report the selection as the control's client state: 1-based, the end
  /// the slot AFTER the last selected character (exclusive — a word of 8
  /// at line 5 col 15 is (5,15)-(5,23): a recorded session
  /// carrier gui[21]). A whole-line selection of lines a..b in the gutter
  /// ends at the START of line b+1 — (a,1)-(b+1,1), its last line break
  /// included (the carrier's margin drag over 2..4: (2,1)-(5,1), gui[23])
  /// — and, on the document's last line, after its last character
  /// (b, len+1), as Select All's end (a recorded session
  /// (1,1)-(6,28); the capture holds no margin select of the last line).
  void _reportSelection() {
    // editing, the caret sits at the selection's moving end and the
    // keyboard comes up: what is typed next replaces the selection
    final x = _extent;
    if (_editing && x != null) {
      _caret = x;
      _openInput();
    }
    if (_hasLineSelection) {
      final n = _lines.length;
      final a = _start.$1, b = _end.$1;
      final (el, ec) = b < n ? (b + 1, 1) : (b, _lines[b - 1].length + 1);
      widget.onSelection?.call(a, 1, el, ec);
      return;
    }
    if (!_hasSelection) return;
    final s = _start, e = _end;
    widget.onSelection?.call(s.$1, s.$2 + 1, e.$1, e.$2 + 1);
  }

  Future<void> _copy() async {
    final text = _selectedText;
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
  }

  void _selectAll() {
    final n = _lines.length;
    if (n == 0) return;
    setState(() {
      _anchor = (1, 0);
      _extent = (n, _lines[n - 1].length);
      _word = null;
      _lineMode = false;
    });
    _reportSelection();
  }

  /// Bring the line under a dragging finger into view at the edges.
  void _autoScroll(Offset global) {
    final box = _listBox;
    if (box == null || !_v.hasClients) return;
    final y = box.globalToLocal(global).dy;
    final p = _v.position;
    double? to;
    if (y < _lineH) {
      to = p.pixels - _lineH;
    } else if (y > p.viewportDimension - _lineH) {
      to = p.pixels + _lineH;
    }
    if (to != null) _v.jumpTo(to.clamp(p.minScrollExtent, p.maxScrollExtent));
  }

  // ---- editing -----------------------------------------------------------

  void _onFocus() {
    if (!_focus.hasFocus) _closeInput();
    if (mounted && _editing) setState(() {}); // the caret shows while focused
  }

  /// Put the editing caret at ([line], 0-based [offset]) and bring the
  /// keyboard up — an [SapSourceView.editable] view only.
  void _placeCaret(int line, int offset) {
    if (!_editing) return;
    final n = _lines.length;
    final l = line.clamp(1, n < 1 ? 1 : n);
    final len = n == 0 ? 0 : _lines[l - 1].length;
    setState(() => _caret = (l, offset.clamp(0, len)));
    _openInput();
  }

  /// The platform's editing value for the caret's line: [_imeLead] + its
  /// text, the selection at the caret.
  TextEditingValue _imeValue() {
    final c = _caret;
    final text = c == null || _lines.isEmpty ? '' : _lines[c.$1 - 1];
    return TextEditingValue(
      text: '$_imeLead$text',
      selection: TextSelection.collapsed(
        offset: _imeLead.length + (c?.$2 ?? 0).clamp(0, text.length),
      ),
    );
  }

  void _openInput() {
    if (!_editing) return;
    final i = _input;
    if (i == null || !i.attached) {
      _input = TextInput.attach(
        this,
        TextInputConfiguration(
          inputType: TextInputType.multiline,
          inputAction: TextInputAction.newline,
          // ABAP source: no autocorrect, no suggestions, no smart quotes
          // or dashes, no capitals put in
          autocorrect: false,
          enableSuggestions: false,
          smartDashesType: SmartDashesType.disabled,
          smartQuotesType: SmartQuotesType.disabled,
          textCapitalization: TextCapitalization.none,
          keyboardAppearance: Theme.of(context).brightness,
        ),
      );
    }
    _ime = _imeValue();
    _input!.setEditingState(_ime);
    _input!.show();
  }

  /// Hand the platform the caret's line again (after an edit or a caret
  /// move it did not make itself).
  void _syncInput() {
    final i = _input;
    if (!mounted || i == null || !i.attached) return;
    _ime = _imeValue();
    i.setEditingState(_ime);
  }

  void _closeInput() {
    _input?.close();
    _input = null;
  }

  /// Replace the text from [from] to [to] (each (1-based line, 0-based
  /// offset), [from] first) with [text] — a multi-line text splits into
  /// lines — and hand the result to [SapSourceView.onEdit]: the caret
  /// after the inserted text, the selection gone.
  ///
  /// [sync]: hand the platform the caret's line afterwards (false: the
  /// platform's own edit, whose value already is that line). [caretAt]:
  /// where the caret goes instead (an indent / outdent keeps it on its
  /// character).
  void _replace((int, int) from, (int, int) to, String text,
      {required int steps, bool sync = true, (int, int)? caretAt}) {
    final doc = _lines.isEmpty ? <String>[''] : List<String>.of(_lines);
    final la = from.$1.clamp(1, doc.length), lb = to.$1.clamp(1, doc.length);
    final oa = from.$2.clamp(0, doc[la - 1].length);
    final ob = to.$2.clamp(0, doc[lb - 1].length);
    final parts = text.split(_lineBreakRx);
    final head = doc[la - 1].substring(0, oa), tail = doc[lb - 1].substring(ob);
    final inserted = parts.length == 1
        ? ['$head${parts.single}$tail']
        : [
            '$head${parts.first}',
            ...parts.sublist(1, parts.length - 1),
            '${parts.last}$tail',
          ];
    // the longest line kept up to date: only the longest line replaced by
    // shorter ones (a deletion in it) folds the document again
    final memo = identical(_longestFor, _lines) &&
        _lines.length == _longestLen;
    var removed = 0, added = 0;
    for (var i = la - 1; memo && i < lb && i < _lines.length; i++) {
      if (_lines[i].length > removed) removed = _lines[i].length;
    }
    for (final l in inserted) {
      if (l.length > added) added = l.length;
    }
    doc.replaceRange(la - 1, lb, inserted);
    if (memo && (removed < _longest || added >= removed)) {
      _longestFor = doc;
      _longestLen = doc.length;
      if (added > _longest) _longest = added;
    }
    var caret = (
      la + parts.length - 1,
      parts.length == 1 ? oa + parts.single.length : parts.last.length,
    );
    if (caretAt != null) {
      final l = caretAt.$1.clamp(1, doc.length);
      caret = (l, caretAt.$2.clamp(0, doc[l - 1].length));
    }
    setState(() {
      _doc = doc;
      _caret = caret;
      _selected = (caret.$1, caret.$2 + 1);
      _anchor = _extent = null;
      _word = null;
      _lineMode = false;
    });
    if (_toolbar.isShown) _toolbar.remove();
    widget.onEdit?.call(doc, caret.$1, caret.$2 + 1, steps);
    if (sync) _syncInput();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCaret());
  }

  /// Type [text] at the caret, over the selection when one is up: each
  /// typed character and each Return is an undo step of its own (a
  /// multi-line text: [ab4InsertUndoSteps]).
  void _insert(String text) {
    final c = _caret;
    if (c == null) return;
    final sel = _hasSelection;
    final from = sel ? _start : c, to = sel ? _end : c;
    _replace(from, to, text, steps: ab4InsertUndoSteps(text));
  }

  /// The text a Return inserts at [at]: the line break and the
  /// indentation of what stands BEFORE the break — the leading blanks of
  /// the line up to the caret, as the ABAP editor carries a block's
  /// indentation onto the next line. A Return inside the leading blanks
  /// carries only the blanks before it (the rest stays with the tail), so
  /// an indented line split at its start never doubles its indentation.
  String _breakAt((int, int) at) {
    final i = at.$1 - 1;
    final line = i < 0 || i >= _lines.length ? '' : _lines[i];
    final head = line.substring(0, at.$2.clamp(0, line.length));
    return '\n${_leadingBlanksRx.firstMatch(head)!.group(0)!}';
  }

  /// Return: the line splits at the caret (over the selection, replacing
  /// it), the new line indented as the text before the break — the one
  /// undo step a Return is (the indentation is the editor's, not typed).
  void _newline() {
    final c = _caret;
    if (c == null) return;
    final sel = _hasSelection;
    final from = sel ? _start : c, to = sel ? _end : c;
    _replace(from, to, _breakAt(from), steps: 1);
  }

  /// Tab on a hardware keyboard: blanks up to the next 2-column stop at
  /// the caret; over a selection, the selected lines indented. Taken here
  /// so the key does not go on to the focus traversal, which would blur
  /// the view and drop the keyboard.
  void _tab() {
    final c = _caret;
    if (c == null) return;
    if (_hasSelection) return _shiftLines(_start.$1, _end.$1, 2);
    _insert(' ' * (2 - c.$2 % 2));
  }

  /// Indent ([by] > 0) or outdent the lines [a]..[b]: [by] blanks put
  /// before each, or up to that many leading blanks taken off — one
  /// replace over the whole range, one undo step; the caret keeps its
  /// character when it sits in the range without a selection. Lines that
  /// would not change (an outdent of unindented lines) are no edit.
  void _shiftLines(int a, int b, int by) {
    if (_lines.isEmpty || by == 0) return;
    final lo = a.clamp(1, _lines.length), hi = b.clamp(lo, _lines.length);
    final c = _caret;
    final out = <String>[];
    var caretShift = 0;
    for (var l = lo; l <= hi; l++) {
      final s = _lines[l - 1];
      final String t;
      if (by > 0) {
        t = '${' ' * by}$s';
      } else {
        var k = 0;
        while (k < -by && k < s.length && s[k] == ' ') {
          k++;
        }
        t = s.substring(k);
      }
      if (c != null && c.$1 == l) caretShift = t.length - s.length;
      out.add(t);
    }
    if (listEquals(out, _lines.sublist(lo - 1, hi))) return;
    final keep = c != null && !_hasSelection && c.$1 >= lo && c.$1 <= hi
        ? (c.$1, c.$2 + caretShift)
        : null;
    _replace((lo, 0), (hi, _lines[hi - 1].length), out.join('\n'),
        steps: 1, caretAt: keep);
  }

  /// The long-press menu's Indent / Outdent: the selected lines, else the
  /// caret's line, else the line the menu was opened on.
  void _shiftFromMenu(int by, (int, int)? hit) {
    if (_hasSelection) return _shiftLines(_start.$1, _end.$1, by);
    final l = _caret?.$1 ?? hit?.$1;
    if (l != null) _shiftLines(l, l, by);
  }

  /// Backspace: the selection, else the character before the caret, else
  /// (at a line's start) the line break before it — the line joins the one
  /// above.
  void _backspace() {
    final c = _caret;
    if (c == null) return;
    if (_hasSelection) return _replace(_start, _end, '', steps: 1);
    if (c.$2 > 0) return _replace((c.$1, c.$2 - 1), c, '', steps: 1);
    if (c.$1 > 1) {
      final prev = _lines[c.$1 - 2].length;
      _replace((c.$1 - 1, prev), c, '', steps: 1);
    }
  }

  /// Delete: the selection, else the character after the caret, else (at a
  /// line's end) the line break after it — the next line joins this one.
  void _deleteForward() {
    final c = _caret;
    if (c == null || _lines.isEmpty) return;
    if (_hasSelection) return _replace(_start, _end, '', steps: 1);
    final len = _lines[c.$1 - 1].length;
    if (c.$2 < len) return _replace(c, (c.$1, c.$2 + 1), '', steps: 1);
    if (c.$1 < _lines.length) {
      _replace(c, (c.$1 + 1, 0), '', steps: 1);
    }
  }

  Future<void> _paste() async {
    if (!_editing || _caret == null) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted || text == null || text.isEmpty) return;
    final c = _caret!;
    // the OCX counts a step per line break, and one for the characters
    // (a recorded session g[27]: five lines, +6)
    _replace(_hasSelection ? _start : c, _hasSelection ? _end : c, text,
        steps: ab4InsertUndoSteps(text));
  }

  Future<void> _cut() async {
    if (!_editing || !_hasSelection) return;
    final s = _start, e = _end;
    await Clipboard.setData(ClipboardData(text: _selectedText));
    if (!mounted) return;
    _replace(s, e, '', steps: 1);
  }

  /// Move the caret to ([line], [offset]) (clamped), the selection dropped.
  void _moveCaret(int line, int offset) {
    final n = _lines.length;
    if (n == 0) return;
    final l = line.clamp(1, n);
    setState(() {
      _caret = (l, offset.clamp(0, _lines[l - 1].length));
      _selected = (l, _caret!.$2 + 1);
      _anchor = _extent = null;
      _word = null;
    });
    widget.onCaret?.call(l, _caret!.$2 + 1);
    _syncInput();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCaret());
  }

  /// The hardware keys an editing view takes itself (the text a key types
  /// comes through the platform's text input, [updateEditingValue]); every
  /// other key — and every key in display mode — goes on up (Ctrl+S, the
  /// function keys, the view's own shortcuts).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final c = _caret;
    if (!_editing || c == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = HardwareKeyboard.instance;
    if (k.isMetaPressed || k.isControlPressed || k.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final len = _lines.isEmpty ? 0 : _lines[c.$1 - 1].length;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _newline();
    } else if (key == LogicalKeyboardKey.tab) {
      if (k.isShiftPressed) {
        _shiftLines(_hasSelection ? _start.$1 : c.$1,
            _hasSelection ? _end.$1 : c.$1, -2);
      } else {
        _tab();
      }
    } else if (key == LogicalKeyboardKey.backspace) {
      _backspace();
    } else if (key == LogicalKeyboardKey.delete) {
      _deleteForward();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      if (c.$2 > 0) {
        _moveCaret(c.$1, c.$2 - 1);
      } else if (c.$1 > 1) {
        _moveCaret(c.$1 - 1, _lines[c.$1 - 2].length);
      }
    } else if (key == LogicalKeyboardKey.arrowRight) {
      if (c.$2 < len) {
        _moveCaret(c.$1, c.$2 + 1);
      } else if (c.$1 < _lines.length) {
        _moveCaret(c.$1 + 1, 0);
      }
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _moveCaret(c.$1 - 1, c.$2);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _moveCaret(c.$1 + 1, c.$2);
    } else if (key == LogicalKeyboardKey.home) {
      _moveCaret(c.$1, 0);
    } else if (key == LogicalKeyboardKey.end) {
      _moveCaret(c.$1, len);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Scroll the caret into view after an edit or a caret move.
  void _revealCaret() {
    final c = _caret;
    if (!mounted || c == null) return;
    if (_v.hasClients) {
      final p = _v.position;
      final top = (c.$1 - 1) * _lineH;
      double? to;
      if (top < p.pixels) {
        to = top;
      } else if (top + _lineH > p.pixels + p.viewportDimension) {
        to = top + _lineH - p.viewportDimension;
      }
      if (to != null) _v.jumpTo(to.clamp(p.minScrollExtent, p.maxScrollExtent));
    }
    if (_h.hasClients) {
      final p = _h.position;
      final x = _textLeft + c.$2 * _cw;
      double? to;
      if (x - _textLeft < p.pixels) {
        to = x - _textLeft;
      } else if (x + 2 * _cw > p.pixels + p.viewportDimension) {
        to = x + 2 * _cw - p.viewportDimension;
      }
      if (to != null) _h.jumpTo(to.clamp(p.minScrollExtent, p.maxScrollExtent));
    }
  }

  // ---- the platform's text input (TextInputClient) ----

  @override
  TextEditingValue? get currentTextEditingValue => _ime;

  @override
  AutofillScope? get currentAutofillScope => null;

  /// The platform's edit of the caret's line ([_imeLead] + its text): the
  /// soft keyboard's (and a hardware keyboard's) typed text, a dictation, a
  /// paste from the system menu, a Return ('\n': the line splits), a
  /// Backspace — at the line's start it deletes [_imeLead]: the line joins
  /// the one above. A value whose text is unchanged moves the caret only.
  @override
  void updateEditingValue(TextEditingValue value) {
    final c = _caret;
    if (!_editing || c == null) return;
    final old = _ime;
    if (value.text == old.text) {
      _ime = value;
      final off = value.selection.isValid
          ? value.selection.extentOffset - _imeLead.length
          : c.$2;
      if (off >= 0 && off != c.$2) _moveCaret(c.$1, off);
      return;
    }
    if (!value.text.startsWith(_imeLead)) {
      // the lead deleted: Backspace at the line's start
      _backspace();
      return;
    }
    // what changed: the common head and tail kept, the middle replaced
    final a = old.text, b = value.text;
    var p = 0;
    while (p < a.length && p < b.length && a.codeUnitAt(p) == b.codeUnitAt(p)) {
      p++;
    }
    var q = 0;
    while (q < a.length - p &&
        q < b.length - p &&
        a.codeUnitAt(a.length - 1 - q) == b.codeUnitAt(b.length - 1 - q)) {
      q++;
    }
    final inserted = b.substring(p, b.length - q);
    final lead = _imeLead.length;
    // the soft keyboard's Return (one bare line break): the new line takes
    // the indentation of the text before the break, as a hardware Return
    // does — still the one step a Return is; a dictation or a pasted text
    // that merely holds a break goes in as it is
    final steps = ab4InsertUndoSteps(inserted);
    final isReturn = inserted == '\n';
    if (_hasSelection) {
      // the selection is the view's, not the platform's: what was typed
      // replaces it
      _replace(_start, _end, isReturn ? _breakAt(_start) : inserted,
          steps: steps);
      return;
    }
    final from = (c.$1, (p - lead).clamp(0, 1 << 30));
    final to = (c.$1, (a.length - q - lead).clamp(0, 1 << 30));
    _replace(from, to, isReturn ? _breakAt(from) : inserted,
        steps: steps, sync: false);
    // the platform's value is the line now (a composition in progress kept
    // as it is); a split / join changed the line: handed back
    final want = _imeValue();
    if (want.text == value.text) {
      _ime = value;
    } else {
      _ime = want;
      _input?.setEditingState(want);
    }
  }

  // the Return of a multi-line input is the '\n' it inserts
  @override
  void performAction(TextInputAction action) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    // the platform dropped the keyboard: the caret stays, a tap reopens it
    _input = null;
  }

  // ---- gestures ----------------------------------------------------------

  /// Whether a pointer is below the last line (the empty rest of a short
  /// text): a tap there hits no line.
  bool _pastText(Offset global) {
    final c = _content(global);
    return c == null || c.dy >= _lines.length * _lineH;
  }

  void _onTapUp(TapUpDetails d) {
    if (_pastText(d.globalPosition)) {
      _clearSelection();
      // a click below the text parks the caret in the slot after the last
      // character (a recorded session: (6, 28) on a 6-line
      // source whose last line has 27 characters)
      final n = _lines.length;
      if (n > 0 && !_inGutter(d.globalPosition)) {
        _focus.requestFocus();
        final end = (n, _lines[n - 1].length + 1);
        setState(() => _selected = end);
        _placeCaret(n, end.$2 - 1);
        widget.onCaret?.call(end.$1, end.$2);
      } else if (n == 0 && _editing) {
        // the empty document: its one (empty) line
        _focus.requestFocus();
        _placeCaret(1, 0);
      }
      return;
    }
    if (_inGutter(d.globalPosition)) {
      final hit = _cellAt(d.globalPosition);
      if (hit != null && widget.onToggleBreakpoint != null) {
        // the margin click goes to the server at once and its dot comes
        // back with the answer: the tap is acknowledged under the finger
        // meanwhile (a haptic the iPad gives too; Feedback.forTap is
        // silent on iOS)
        HapticFeedback.selectionClick();
        widget.onToggleBreakpoint!(hit.$1);
      }
      return;
    }
    _focus.requestFocus();
    _clearSelection();
    final hit = _cellAt(d.globalPosition);
    if (hit == null) return;
    final first = _firstTap, at = _firstTapAt;
    if (_tapWindow?.isActive == true &&
        first != null &&
        at != null &&
        (d.globalPosition - at).distance < kDoubleTapSlop) {
      // the second tap: navigate on the first one's token
      _tapWindow?.cancel();
      _firstTap = _firstTapAt = null;
      setState(() => _selected = first);
      widget.onNavigate?.call(first.$1, first.$2);
      return;
    }
    _tapWindow?.cancel();
    _tapWindow = Timer(kDoubleTapTimeout, () {});
    _firstTap = hit;
    _firstTapAt = d.globalPosition;
    setState(() => _selected = hit);
    // the caret: past a line's end it parks in the slot after its last
    // character (len + 1), as the control's SelPos* report it
    final len = _lines[hit.$1 - 1].length;
    final col = hit.$2 > len + 1 ? len + 1 : hit.$2;
    // editing, the caret goes to the character boundary nearest the finger
    // and that is the column reported (the slot it types into)
    final pos = _posAt(d.globalPosition);
    final slot = pos?.$1 == hit.$1 ? pos!.$2 : col - 1;
    _placeCaret(hit.$1, slot);
    widget.onCaret?.call(hit.$1, _editing ? slot + 1 : col);
  }

  void _onLongPressStart(LongPressStartDetails d) {
    final g = d.globalPosition;
    if (_pastText(g)) return;
    final hit = _cellAt(g);
    final pos = _posAt(g);
    if (hit == null || pos == null) return;
    _focus.requestFocus();
    _tapWindow?.cancel();
    if (_toolbar.isShown) _toolbar.remove();
    Feedback.forLongPress(context);
    _dragging = true;
    final line = hit.$1;
    if (_inGutter(g)) {
      // the gutter: the whole line, a drag adds lines
      setState(() {
        _lineMode = true;
        _lineAnchor = line;
        _word = null;
        _anchor = (line, 0);
        _extent = (line, _lines[line - 1].length);
        _menuAt = (line, 1);
        _selected = (line, 1);
      });
      return;
    }
    final w = wordAt(_lines[line - 1], hit.$2 - 1);
    setState(() {
      _lineMode = false;
      _menuAt = hit;
      _selected = hit;
      if (w != null) {
        _word = (line, w.$2, w.$2 + w.$1.length);
        _anchor = (line, w.$2);
        _extent = (line, w.$2 + w.$1.length);
      } else {
        _word = null;
        _anchor = _extent = pos;
      }
    });
  }

  /// Move the selection's moving end to the pointer (a long-press drag).
  void _extendTo(Offset global) {
    if (!_dragging) return; // no selection gesture started
    _autoScroll(global);
    final pos = _posAt(global);
    if (pos == null) return;
    setState(() {
      if (_lineMode) {
        final a = _lineAnchor ?? pos.$1, b = pos.$1;
        final lo = math.min(a, b), hi = math.max(a, b);
        _anchor = (lo, 0);
        _extent = (hi, _lines[hi - 1].length);
        return;
      }
      final w = _word;
      if (w != null) {
        // from the word's far side, as a long-press drag grows it
        final ws = (w.$1, w.$2), we = (w.$1, w.$3);
        if (_cmp(pos, ws) < 0) {
          _anchor = we;
          _extent = pos;
        } else if (_cmp(pos, we) > 0) {
          _anchor = ws;
          _extent = pos;
        } else {
          _anchor = ws;
          _extent = we;
        }
      } else {
        _extent = pos;
      }
    });
  }

  void _onSelectEnd() {
    if (!_dragging) return;
    _dragging = false;
    if (_hasSelection || _hasLineSelection) {
      _reportSelection();
    } else {
      final at = _anchor;
      setState(() => _anchor = _extent = null);
      if (at != null) widget.onCaret?.call(at.$1, at.$2 + 1);
    }
    _showToolbar();
  }

  void _onMousePanStart(DragStartDetails d) {
    final pos = _posAt(d.globalPosition);
    if (pos == null) return;
    _focus.requestFocus();
    if (_toolbar.isShown) _toolbar.remove();
    _dragging = true;
    final gutter = _inGutter(d.globalPosition);
    setState(() {
      _word = null;
      _lineMode = gutter;
      _lineAnchor = pos.$1;
      if (gutter) {
        _anchor = (pos.$1, 0);
        _extent = (pos.$1, _lines[pos.$1 - 1].length);
      } else {
        _anchor = _extent = pos;
      }
      _menuAt = _cellAt(d.globalPosition);
    });
  }

  void _onMousePanEnd() {
    if (!_dragging) return;
    _dragging = false;
    if (_hasSelection || _hasLineSelection) {
      _reportSelection();
    } else {
      setState(() => _anchor = _extent = null);
    }
  }

  void _onSecondaryTapUp(TapUpDetails d) {
    final hit = _cellAt(d.globalPosition);
    if (hit == null) return;
    _focus.requestFocus();
    _menuAt = hit;
    _selected = hit;
    _showToolbar(at: d.globalPosition);
  }

  void _onHandleStart(bool isStart, DragStartDetails d) {
    if (!_hasSelection) return;
    final s = _start, e = _end;
    // the dragged end moves, the other one stays
    _anchor = isStart ? e : s;
    _extent = isStart ? s : e;
    _word = null;
    _lineMode = false;
    _dragging = true;
    if (_toolbar.isShown) _toolbar.remove();
    final box = _listBox;
    if (box != null) {
      final centre = box.localToGlobal(Offset(0, (_extent!.$1 - 0.5) * _lineH - _v.offset));
      _grabDy = d.globalPosition.dy - centre.dy;
    }
  }

  void _onHandleUpdate(DragUpdateDetails d) {
    if (_anchor == null) return;
    final g = d.globalPosition - Offset(0, _grabDy);
    _autoScroll(g);
    final pos = _posAt(g);
    if (pos == null) return;
    setState(() => _extent = pos);
  }

  // ---- toolbar -----------------------------------------------------------

  /// The system's text toolbar (the iOS edit menu on an iPad) at the
  /// selection, or at [at] when nothing is selected.
  void _showToolbar({Offset? at}) {
    final box = _listBox;
    if (box == null || !mounted) return;
    Offset g(int line, int pos, {bool bottom = false}) => box.localToGlobal(
        Offset(_textLeft + pos * _cw, (line - (bottom ? 0 : 1)) * _lineH - _v.offset));
    final Offset primary, secondary;
    if (at == null && _hasSelection) {
      primary = g(_start.$1, _start.$2);
      secondary = g(_end.$1, _end.$2, bottom: true);
    } else {
      final m = _menuAt;
      if (at == null && m == null) return;
      primary = at ?? g(m!.$1, m.$2 - 1);
      secondary = at ?? g(m!.$1, m.$2 - 1, bottom: true);
    }
    final at0 = _menuAt ?? (_hasSelection ? (_start.$1, _start.$2 + 1) : null);
    // an edit may have removed the line the menu was opened on
    final hit = at0 != null && at0.$1 <= _lines.length ? at0 : null;
    final word = hit == null ? null : wordAt(_lines[hit.$1 - 1], hit.$2 - 1);
    void close() => _toolbar.remove();
    final items = <ContextMenuButtonItem>[
      if (_hasSelection && _editing)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.cut,
          onPressed: () {
            close();
            _cut();
          },
        ),
      if (_hasSelection)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () {
            close();
            _copy();
          },
        ),
      if (_editing)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.paste,
          onPressed: () {
            close();
            _paste();
          },
        ),
      if (!_allSelected && _lines.isNotEmpty)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          onPressed: () {
            close();
            _selectAll();
            _showToolbar();
          },
        ),
      // the soft keyboards have no Tab: the selected lines, else the line
      // under the finger, shifted by two
      if (_editing && _lines.isNotEmpty)
        ContextMenuButtonItem(
          label: 'Indent',
          onPressed: () {
            close();
            _shiftFromMenu(2, hit);
          },
        ),
      if (_editing && _lines.isNotEmpty)
        ContextMenuButtonItem(
          label: 'Outdent',
          onPressed: () {
            close();
            _shiftFromMenu(-2, hit);
          },
        ),
      if (hit != null && widget.onNavigate != null)
        ContextMenuButtonItem(
          label: word == null ? 'Navigate' : 'Navigate to ${word.$1}',
          onPressed: () {
            close();
            widget.onNavigate!(hit.$1, hit.$2);
          },
        ),
      if (hit != null && widget.onWhereUsed != null)
        ContextMenuButtonItem(
          label: 'Where-used list',
          onPressed: () {
            close();
            widget.onWhereUsed!(hit.$1, hit.$2);
          },
        ),
      if (hit != null && widget.onToggleBreakpoint != null)
        ContextMenuButtonItem(
          // the margin click: it sets or removes the SESSION breakpoint, on
          // an external one's dot removes that one; on a line with another
          // kind only, the server decides
          label: widget.breakpoints.contains(hit.$1)
              ? 'Remove breakpoint'
              : widget.externalBreakpoints.contains(hit.$1)
                  ? 'Remove external breakpoint'
                  : widget.otherBreakpoints.contains(hit.$1)
                      ? 'Toggle breakpoint'
                      : 'Set breakpoint',
          onPressed: () {
            close();
            widget.onToggleBreakpoint!(hit.$1);
          },
        ),
    ];
    if (items.isEmpty) return;
    _toolbar.show(
      context: context,
      contextMenuBuilder: (_) => AdaptiveTextSelectionToolbar.buttonItems(
        anchors: TextSelectionToolbarAnchors(primaryAnchor: primary, secondaryAnchor: secondary),
        buttonItems: items,
      ),
    );
  }

  // ---- painting ----------------------------------------------------------

  /// The selected span of one line: (from, to) offsets and whether its line
  /// break is selected too; null when the line has none.
  (int, int, bool)? _rowSelection(int line) {
    if (!_hasSelection) return null;
    final s = _start, e = _end;
    if (line < s.$1 || line > e.$1) return null;
    final len = _lines[line - 1].length;
    final a = line == s.$1 ? math.min(s.$2, len) : 0;
    final b = line == e.$1 ? math.min(e.$2, len) : len;
    final br = line < e.$1;
    if (b <= a && !br) return null;
    return (a, b, br);
  }

  Widget _handle(bool isStart, Color color) {
    final pos = isStart ? _start : _end;
    const w = 32.0, knob = 10.0;
    final x = _textLeft + pos.$2 * _cw - (_h.hasClients ? _h.offset : 0);
    final y = (pos.$1 - 1) * _lineH - (_v.hasClients ? _v.offset : 0);
    return Positioned(
      key: ValueKey(isStart ? 'sel-start' : 'sel-end'),
      left: x - w / 2,
      top: isStart ? y - knob : y,
      width: w,
      height: _lineH + knob,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) => _onHandleStart(isStart, d),
        onPanUpdate: _onHandleUpdate,
        onPanEnd: (_) => _onSelectEnd(),
        onPanCancel: () => _dragging = false,
        child: Stack(children: [
          Positioned(
            left: w / 2 - 1,
            width: 2,
            top: isStart ? knob : 0,
            height: _lineH,
            child: ColoredBox(color: color),
          ),
          Positioned(
            left: w / 2 - knob / 2,
            width: knob,
            height: knob,
            top: isStart ? 0 : _lineH,
            child: DecoratedBox(decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    _charW ??= _measureCharW();
    final colors = {
      'kw': dark ? const Color(0xFF7AA2F7) : const Color(0xFF1F4FB5),
      'comment': dark ? const Color(0xFF8A8F98) : const Color(0xFF6A737D),
      'string': dark ? const Color(0xFF9ECE6A) : const Color(0xFF22863A),
      'number': dark ? const Color(0xFFE0AF68) : const Color(0xFFB45309),
      'text': scheme.onSurface,
    };
    final selColor = DefaultSelectionStyle.of(context).selectionColor ?? scheme.primary.withValues(alpha: 0.3);
    final handleColor = DefaultSelectionStyle.of(context).cursorColor ?? scheme.primary;
    final digits = '${_lines.length}'.length;
    final double gutterW = digits * _cw + 28;
    _gutterW = gutterW;
    final longest = _longestOf(_lines);
    final double codeW = (longest + 2) * _cw;
    // one style per token kind for every row of the build
    final styles = {
      for (final e in colors.entries)
        e.key: _mono.copyWith(
          color: e.value,
          fontStyle: e.key == 'comment' ? FontStyle.italic : null,
          fontWeight: e.key == 'kw' ? FontWeight.w600 : null,
        ),
    };

    Widget row(BuildContext context, int i) {
      final line = i + 1;
      final bp = widget.breakpoints.contains(line);
      final other = !bp && widget.otherBreakpoints.contains(line);
      final current = widget.currentLine == line;
      final sel = _selected?.$1 == line && !_hasSelection;
      final span = _rowSelection(line);
      return Container(
        color: current
            ? scheme.tertiaryContainer.withValues(alpha: 0.5)
            : (sel ? scheme.secondaryContainer.withValues(alpha: 0.35) : null),
        child: Row(children: [
          Container(
            width: gutterW,
            height: _lineH,
            padding: const EdgeInsets.only(right: _gutterPad),
            color: scheme.surfaceContainerHigh,
            child: Row(children: [
              SizedBox(
                width: 18,
                child: bp
                    ? Center(
                        child: Container(
                          key: ValueKey('bp-$line'),
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(color: Color(0xFFE5484D), shape: BoxShape.circle),
                        ),
                      )
                    : other
                        ? Center(child: _OtherBreakpointDot(key: ValueKey('bp-other-$line')))
                        : null,
            ),
              Expanded(
                child: Text('$line',
                    textAlign: TextAlign.right,
                    textScaler: TextScaler.noScaling,
                    style: _mono.copyWith(color: scheme.onSurfaceVariant, fontSize: 11)),
              ),
            ]),
          ),
          Expanded(
            child: Stack(children: [
              if (span != null)
                Positioned(
                  left: 8 + span.$1 * _cw,
                  width: (span.$2 - span.$1 + (span.$3 ? 1 : 0)) * _cw,
                  top: 0,
                  bottom: 0,
                  child: ColoredBox(color: selColor),
                ),
              // the editing caret (no selection up: typing replaces it)
              if (_editing &&
                  _focus.hasFocus &&
                  !_hasSelection &&
                  _caret?.$1 == line)
                Positioned(
                  key: const ValueKey('edit-caret'),
                  left: 8 + _caret!.$2 * _cw - 1,
                  width: 2,
                  top: 1,
                  bottom: 1,
                  child: ColoredBox(color: handleColor),
                ),
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text.rich(
                    TextSpan(children: [
                      for (final t in tokenizeAbap(
                          i < _lines.length ? _lines[i] : ''))
                        TextSpan(
                          text: t.text,
                          style: styles[t.kind] ??
                              _mono.copyWith(
                                color: colors[t.kind],
                                fontStyle: t.kind == 'comment' ? FontStyle.italic : null,
                                fontWeight: t.kind == 'kw' ? FontWeight.w600 : null,
                              ),
                        ),
                    ]),
                    softWrap: false,
                    textScaler: TextScaler.noScaling,
                  ),
                ),
              ),
            ]),
          ),
        ]),
      );
    }

    final view = LayoutBuilder(builder: (context, cons) {
      final width = math.max(gutterW + codeW, cons.maxWidth);
      return Stack(children: [
        Scrollbar(
          controller: _h,
          child: SingleChildScrollView(
            controller: _h,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              // a mouse / trackpad drag selects; a finger's drag scrolls
              child: GestureDetector(
                supportedDevices: const {PointerDeviceKind.mouse},
                // the selection starts where the button went down
                dragStartBehavior: DragStartBehavior.down,
                onPanStart: _onMousePanStart,
                onPanUpdate: (d) => _extendTo(d.globalPosition),
                onPanEnd: (_) => _onMousePanEnd(),
                onPanCancel: () => _dragging = false,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _onTapUp,
                  onSecondaryTapUp: _onSecondaryTapUp,
                  onLongPressStart: _onLongPressStart,
                  onLongPressMoveUpdate: (d) => _extendTo(d.globalPosition),
                  onLongPressEnd: (_) => _onSelectEnd(),
                  onLongPressCancel: () => _dragging = false,
                  // a new height (the pane resized) reports the view again
                  child: NotificationListener<ScrollMetricsNotification>(
                    onNotification: (_) {
                      _reportView();
                      return false;
                    },
                    child: ListView.builder(
                      key: _listKey,
                      controller: _v,
                      // an empty document being edited shows its one line
                      itemCount: _lines.isEmpty && _editing ? 1 : _lines.length,
                      itemExtent: _lineH,
                      itemBuilder: row,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_hasSelection)
          Positioned.fill(
            child: ListenableBuilder(
              listenable: Listenable.merge([_h, _v]),
              builder: (context, _) => Stack(children: [
                _handle(true, handleColor),
                _handle(false, handleColor),
              ]),
            ),
          ),
      ]);
    });

    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyV, meta: true): _PasteIntent(),
        SingleActivator(LogicalKeyboardKey.keyV, control: true): _PasteIntent(),
        SingleActivator(LogicalKeyboardKey.keyX, meta: true): _CutIntent(),
        SingleActivator(LogicalKeyboardKey.keyX, control: true): _CutIntent(),
        SingleActivator(LogicalKeyboardKey.keyA, meta: true): _SelectAllIntent(),
        SingleActivator(LogicalKeyboardKey.keyA, control: true): _SelectAllIntent(),
        SingleActivator(LogicalKeyboardKey.keyC, meta: true): _CopyIntent(),
        SingleActivator(LogicalKeyboardKey.keyC, control: true): _CopyIntent(),
        SingleActivator(LogicalKeyboardKey.escape): _ClearSelectionIntent(),
        SingleActivator(LogicalKeyboardKey.f12, control: true, shift: true): _BreakpointKeyIntent(),
      },
      child: Actions(
        // enabled only when they apply: a key they do not take goes on up
        actions: {
          _SelectAllIntent: _ViewAction<_SelectAllIntent>(
              () => _lines.isNotEmpty, _selectAll),
          _CopyIntent: _ViewAction<_CopyIntent>(() => _hasSelection, _copy),
          _PasteIntent: _ViewAction<_PasteIntent>(
              () => _editing && _caret != null, _paste),
          _CutIntent: _ViewAction<_CutIntent>(
              () => _editing && _hasSelection, _cut),
          _ClearSelectionIntent: _ViewAction<_ClearSelectionIntent>(
              () => _hasSelection, _clearSelection),
          _BreakpointKeyIntent: _ViewAction<_BreakpointKeyIntent>(
              () => widget.onBreakpointKey != null && _lines.isNotEmpty,
              () => widget.onBreakpointKey!(_selected?.$1 ?? 1)),
        },
        child: Focus(focusNode: _focus, onKeyEvent: _onKey, child: view),
      ),
    );
  }
}
