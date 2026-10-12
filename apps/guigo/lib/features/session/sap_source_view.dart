import 'dart:math' as math;

import 'package:flutter/material.dart';

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

/// An ABAP source editor control (SE38 / SE80 / SE24) as a code view:
/// numbered lines, syntax colours, breakpoint markers in the gutter (a
/// gutter tap toggles one through [onToggleBreakpoint]), a double tap on a
/// token navigates to its definition ([onNavigate], 1-based line and
/// column, like the editor's double-click), a long press offers navigation
/// and the where-used list ([onWhereUsed]).
class SapSourceView extends StatefulWidget {
  const SapSourceView({
    super.key,
    required this.lines,
    this.breakpoints = const {},
    this.currentLine,
    this.firstVisibleLine,
    this.onToggleBreakpoint,
    this.onNavigate,
    this.onWhereUsed,
    this.onViewport,
    this.onCaret,
  });

  final List<String> lines;
  final Set<int> breakpoints;
  final int? currentLine;

  /// The line the server scrolled the editor to (its FirstVisibleLine
  /// property, 1-based): a navigation — a where-used pick, a double-click
  /// on a FORM — opens the editor there, not on line 1.
  final int? firstVisibleLine;
  final void Function(int line)? onToggleBreakpoint;
  final void Function(int line, int col)? onNavigate;
  final void Function(int line, int col)? onWhereUsed;

  /// The lines the view actually shows (1-based first / last), reported
  /// after the first layout and whenever the user's scrolling changes them
  /// — the editor control's client state the server reads back
  /// (FirstVisibleLine / LastVisibleLine).
  final void Function(int firstLine, int lastLine)? onViewport;

  /// A single tap in the code: the caret (1-based line, column) — the
  /// control's SelPosStartLine / SelPosStartCol.
  final void Function(int line, int col)? onCaret;

  @override
  State<SapSourceView> createState() => _SapSourceViewState();
}

class _SapSourceViewState extends State<SapSourceView> {
  static const double _fontSize = 13;
  static const double _lineH = 20;
  final _h = ScrollController();
  final _v = ScrollController();
  (int, int)? _selected; // the token the last gesture hit (line, col)
  double? _charW;

  (int, int)? _view; // the (first, last) lines last reported

  @override
  void initState() {
    super.initState();
    _v.addListener(_reportView);
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

  @override
  void didUpdateWidget(SapSourceView old) {
    super.didUpdateWidget(old);
    // only a position the SERVER changed moves the view: the user's own
    // scrolling stays until the next navigation (and a caret the user
    // tapped is no server move); the view is reported again after it,
    // a server scroll having reset the control's client state
    if (old.firstVisibleLine != widget.firstVisibleLine ||
        (old.currentLine != widget.currentLine && widget.currentLine != _selected?.$1) ||
        !identical(old.lines, widget.lines)) {
      _view = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _follow();
        _reportView();
      });
    }
  }

  /// Scroll to the server's first visible line; without one, bring the
  /// cursor line into view.
  void _follow() {
    if (!mounted || !_v.hasClients) return;
    final p = _v.position;
    double? to;
    final first = widget.firstVisibleLine;
    final cur = widget.currentLine;
    if (first != null && first > 0) {
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
    return tp.width / 10;
  }

  /// 1-based (line, col) of a pointer inside a code row.
  (int, int) _hit(int index, Offset local) =>
      // the code text starts after the row's 8-point left padding
      (index + 1, ((local.dx - 8) / (_charW ?? 8)).floor().clamp(0, 1 << 20) + 1);

  Future<void> _menu(int line, int col, Offset at) async {
    final word = wordAt(widget.lines[line - 1], col - 1);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        if (widget.onNavigate != null)
          PopupMenuItem(value: 'nav', child: Text(word == null ? 'Naviguer' : 'Naviguer vers ${word.$1}')),
        if (widget.onWhereUsed != null)
          const PopupMenuItem(value: 'wu', child: Text("Liste d'utilisation")),
        if (widget.onToggleBreakpoint != null)
          PopupMenuItem(
              value: 'bp',
              child: Text(widget.breakpoints.contains(line) ? 'Supprimer le point d\'arrêt' : 'Point d\'arrêt')),
      ],
    );
    switch (action) {
      case 'nav':
        widget.onNavigate?.call(line, col);
      case 'wu':
        widget.onWhereUsed?.call(line, col);
      case 'bp':
        widget.onToggleBreakpoint?.call(line);
    }
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
    final digits = '${widget.lines.length}'.length;
    final double gutterW = digits * (_charW ?? 8.0) + 28;
    final longest = widget.lines.fold<int>(0, (a, l) => l.length > a ? l.length : a);
    final double codeW = (longest + 2) * (_charW ?? 8.0);

    return LayoutBuilder(builder: (context, cons) {
      final width = math.max(gutterW + codeW, cons.maxWidth);
      return Scrollbar(
        controller: _h,
        child: SingleChildScrollView(
          controller: _h,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: ListView.builder(
              controller: _v,
              itemCount: widget.lines.length,
              itemExtent: _lineH,
              itemBuilder: (context, i) {
                final line = i + 1;
                final bp = widget.breakpoints.contains(line);
                final current = widget.currentLine == line;
                final sel = _selected?.$1 == line;
                return Container(
                  color: current
                      ? scheme.tertiaryContainer.withValues(alpha: 0.5)
                      : (sel ? scheme.secondaryContainer.withValues(alpha: 0.35) : null),
                  child: Row(children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onToggleBreakpoint == null ? null : () => widget.onToggleBreakpoint!(line),
                      child: Container(
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
                    ),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: widget.onCaret == null
                            ? null
                            : (d) {
                                final hit = _hit(i, d.localPosition);
                                setState(() => _selected = hit);
                                widget.onCaret!(hit.$1, hit.$2);
                              },
                        onDoubleTapDown: (d) => setState(() => _selected = _hit(i, d.localPosition)),
                        onDoubleTap: widget.onNavigate == null
                            ? null
                            : () {
                                final hit = _selected;
                                if (hit != null) widget.onNavigate!(hit.$1, hit.$2);
                              },
                        onLongPressStart: (d) {
                          final hit = _hit(i, d.localPosition);
                          setState(() => _selected = hit);
                          _menu(hit.$1, hit.$2, d.globalPosition);
                        },
                        child: Padding(
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
                      ),
                    ),
                  ]),
                );
              },
            ),
          ),
        ),
      );
    });
  }
}
