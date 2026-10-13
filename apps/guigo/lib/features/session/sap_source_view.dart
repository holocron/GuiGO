import 'dart:async';
import 'dart:math' as math;

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
  if (line.startsWith('*')) return [SourceToken(line, 'comment')];
  final out = <SourceToken>[];
  final rx = RegExp(r'''("[^\n]*$)|('(?:[^']|'')*'?)|(`(?:[^`]|``)*`?)|(\|[^|]*\|?)|(\b\d+\b)|([A-Za-z_/][A-Za-z0-9_/\-~>=]*)|(\s+|.)''');
  for (final m in rx.allMatches(line)) {
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
  final rx = RegExp(r'[A-Za-z0-9_/\-~>=]+');
  for (final m in rx.allMatches(line)) {
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
/// * tap in the code: the caret ([onCaret]); a tap in the gutter toggles
/// a breakpoint ([onToggleBreakpoint]);
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
/// all, Cmd/Ctrl+C copies, Esc drops the selection.
///
/// The view is read-only (the source changes on the server only): there
/// is no cut or paste.
class SapSourceView extends StatefulWidget {
  const SapSourceView({
    super.key,
    required this.lines,
    this.breakpoints = const {},
    this.currentLine,
    this.firstVisibleLine,
    this.scrollSerial = 0,
    this.onToggleBreakpoint,
    this.onNavigate,
    this.onWhereUsed,
    this.onViewport,
    this.onCaret,
    this.onSelection,
  });

  final List<String> lines;
  final Set<int> breakpoints;
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
  final void Function(int line)? onToggleBreakpoint;
  final void Function(int line, int col)? onNavigate;
  final void Function(int line, int col)? onWhereUsed;

  /// The lines the view actually shows (1-based first / last), reported
  /// after the first layout and whenever the user's scrolling changes them
  /// — the editor control's client state the server reads back
  /// (FirstVisibleLine / LastVisibleLine).
  final void Function(int firstLine, int lastLine)? onViewport;

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

class _SapSourceViewState extends State<SapSourceView> {
  static const double _fontSize = 13;
  static const double _lineH = 20;
  final _h = ScrollController();
  final _v = ScrollController();
  final _listKey = GlobalKey();
  final _focus = FocusNode(debugLabel: 'SapSourceView');
  final _toolbar = ContextMenuController();
  (int, int)? _selected; // the token the last gesture hit (line, col)
  double? _charW;
  double _gutterW = 0;

  (int, int)? _view; // the (first, last) lines last reported

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

  @override
  void initState() {
    super.initState();
    _v.addListener(_reportView);
    _v.addListener(_hideOnScroll);
    _h.addListener(_hideOnScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _follow();
      _reportView();
    });
  }

  /// Report the lines on screen through [SapSourceView.onViewport] when
  /// they changed.
  void _reportView() {
    final cb = widget.onViewport;
    final n = widget.lines.length;
    if (cb == null || n == 0 || !_v.hasClients) return;
    final p = _v.position;
    if (!p.hasPixels || !p.hasViewportDimension) return;
    final first = (p.pixels / _lineH).floor().clamp(0, n - 1) + 1;
    final last = ((p.pixels + p.viewportDimension) / _lineH).ceil().clamp(first, n);
    if (_view == (first, last)) return;
    _view = (first, last);
    cb(first, last);
  }

  void _hideOnScroll() {
    if (!_dragging && _toolbar.isShown) _toolbar.remove();
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
    // tapped is no server move at all
    final newText = !identical(old.lines, widget.lines) &&
        !listEquals(old.lines, widget.lines);
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

  int _lineOf(double y) => (y / _lineH).floor().clamp(0, widget.lines.length - 1) + 1;

  /// 1-based (line, col) of the character under a pointer (what a tap,
  /// a double tap, a navigation acts on).
  (int, int)? _cellAt(Offset global) {
    final c = _content(global);
    if (c == null || widget.lines.isEmpty) return null;
    return (_lineOf(c.dy), ((c.dx - _textLeft) / _cw).floor().clamp(0, 1 << 20) + 1);
  }

  /// (1-based line, 0-based offset) of the character boundary nearest a
  /// pointer (a selection end).
  (int, int)? _posAt(Offset global) {
    final c = _content(global);
    if (c == null || widget.lines.isEmpty) return null;
    final line = _lineOf(c.dy);
    final len = widget.lines[line - 1].length;
    return (line, ((c.dx - _textLeft) / _cw).round().clamp(0, len));
  }

  bool _inGutter(Offset global) {
    final c = _content(global);
    return c != null && c.dx < _gutterW;
  }

  static int _cmp((int, int) a, (int, int) b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2;

  bool get _hasSelection => _anchor != null && _extent != null && _anchor != _extent;
  (int, int) get _start => _cmp(_anchor!, _extent!) <= 0 ? _anchor! : _extent!;
  (int, int) get _end => _cmp(_anchor!, _extent!) <= 0 ? _extent! : _anchor!;

  String get _selectedText => _hasSelection ? sourceSelectionText(widget.lines, _start, _end) : '';

  bool get _allSelected {
    if (!_hasSelection || widget.lines.isEmpty) return false;
    final n = widget.lines.length;
    return _start == (1, 0) && _end == (n, widget.lines[n - 1].length);
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

  /// Report the selection as the control's client state.
  void _reportSelection() {
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
    final n = widget.lines.length;
    if (n == 0) return;
    setState(() {
      _anchor = (1, 0);
      _extent = (n, widget.lines[n - 1].length);
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

  // ---- gestures ----------------------------------------------------------

  /// Whether a pointer is below the last line (the empty rest of a short
  /// text): a tap there hits no line.
  bool _pastText(Offset global) {
    final c = _content(global);
    return c == null || c.dy >= widget.lines.length * _lineH;
  }

  void _onTapUp(TapUpDetails d) {
    if (_pastText(d.globalPosition)) {
      _clearSelection();
      return;
    }
    if (_inGutter(d.globalPosition)) {
      final hit = _cellAt(d.globalPosition);
      if (hit != null) widget.onToggleBreakpoint?.call(hit.$1);
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
    widget.onCaret?.call(hit.$1, hit.$2);
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
        _extent = (line, widget.lines[line - 1].length);
        _menuAt = (line, 1);
        _selected = (line, 1);
      });
      return;
    }
    final w = wordAt(widget.lines[line - 1], hit.$2 - 1);
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
        _extent = (hi, widget.lines[hi - 1].length);
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
    if (_hasSelection) {
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
        _extent = (pos.$1, widget.lines[pos.$1 - 1].length);
      } else {
        _anchor = _extent = pos;
      }
      _menuAt = _cellAt(d.globalPosition);
    });
  }

  void _onMousePanEnd() {
    if (!_dragging) return;
    _dragging = false;
    if (_hasSelection) {
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
    final hit = _menuAt ?? (_hasSelection ? (_start.$1, _start.$2 + 1) : null);
    final word = hit == null ? null : wordAt(widget.lines[hit.$1 - 1], hit.$2 - 1);
    void close() => _toolbar.remove();
    final items = <ContextMenuButtonItem>[
      if (_hasSelection)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () {
            close();
            _copy();
          },
        ),
      if (!_allSelected && widget.lines.isNotEmpty)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          onPressed: () {
            close();
            _selectAll();
            _showToolbar();
          },
        ),
      if (hit != null && widget.onNavigate != null)
        ContextMenuButtonItem(
          label: word == null ? 'Naviguer' : 'Naviguer vers ${word.$1}',
          onPressed: () {
            close();
            widget.onNavigate!(hit.$1, hit.$2);
          },
        ),
      if (hit != null && widget.onWhereUsed != null)
        ContextMenuButtonItem(
          label: "Liste d'utilisation",
          onPressed: () {
            close();
            widget.onWhereUsed!(hit.$1, hit.$2);
          },
        ),
      if (hit != null && widget.onToggleBreakpoint != null)
        ContextMenuButtonItem(
          label: widget.breakpoints.contains(hit.$1) ? 'Remove breakpoint' : 'Set breakpoint',
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
    final len = widget.lines[line - 1].length;
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
    final digits = '${widget.lines.length}'.length;
    final double gutterW = digits * _cw + 28;
    _gutterW = gutterW;
    final longest = widget.lines.fold<int>(0, (a, l) => l.length > a ? l.length : a);
    final double codeW = (longest + 2) * _cw;

    Widget row(BuildContext context, int i) {
      final line = i + 1;
      final bp = widget.breakpoints.contains(line);
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
            padding: const EdgeInsets.only(right: 6),
            color: scheme.surfaceContainerHigh,
            child: Row(children: [
              SizedBox(
                width: 18,
                child: bp
                    ? Center(
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(color: Color(0xFFE5484D), shape: BoxShape.circle),
                        ),
                      )
                    : null,
            ),
              Expanded(
                child: Text('$line',
                    textAlign: TextAlign.right,
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
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text.rich(
                    TextSpan(children: [
                      for (final t in tokenizeAbap(widget.lines[i]))
                        TextSpan(
                          text: t.text,
                          style: _mono.copyWith(
                            color: colors[t.kind],
                            fontStyle: t.kind == 'comment' ? FontStyle.italic : null,
                            fontWeight: t.kind == 'kw' ? FontWeight.w600 : null,
                          ),
                        ),
                    ]),
                    softWrap: false,
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
                  child: ListView.builder(
                    key: _listKey,
                    controller: _v,
                    itemCount: widget.lines.length,
                    itemExtent: _lineH,
                    itemBuilder: row,
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
        SingleActivator(LogicalKeyboardKey.keyA, meta: true): _SelectAllIntent(),
        SingleActivator(LogicalKeyboardKey.keyA, control: true): _SelectAllIntent(),
        SingleActivator(LogicalKeyboardKey.keyC, meta: true): _CopyIntent(),
        SingleActivator(LogicalKeyboardKey.keyC, control: true): _CopyIntent(),
        SingleActivator(LogicalKeyboardKey.escape): _ClearSelectionIntent(),
      },
      child: Actions(
        // enabled only when they apply: a key they do not take goes on up
        actions: {
          _SelectAllIntent: _ViewAction<_SelectAllIntent>(
              () => widget.lines.isNotEmpty, _selectAll),
          _CopyIntent: _ViewAction<_CopyIntent>(() => _hasSelection, _copy),
          _ClearSelectionIntent: _ViewAction<_ClearSelectionIntent>(
              () => _hasSelection, _clearSelection),
        },
        child: Focus(focusNode: _focus, child: view),
      ),
    );
  }
}
