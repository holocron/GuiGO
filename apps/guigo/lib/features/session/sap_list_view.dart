import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../../core/sap_icons.dart';

/// SAP's classic list colours (ABAP `FORMAT COLOR n`): 0 COL_BACKGROUND,
/// 1 COL_HEADING, 2 COL_NORMAL, 3 COL_TOTAL, 4 COL_KEY, 5 COL_POSITIVE,
/// 6 COL_NEGATIVE, 7 COL_GROUP — each as an INTENSIFIED band and a lighter
/// INTENSIFIED OFF one, the INVERSE form a coloured foreground on the list
/// background (the SFE triple a run carries, [ListSegment]).
class SapListPalette {
  const SapListPalette._(
    this._bands,
    this._inverse,
    this.text,
    this.bandText,
    this.frame,
    this.input,
    this.inputBorder,
  );

  /// (INTENSIFIED, INTENSIFIED OFF) band per colour 1..7.
  final List<(Color, Color)> _bands;
  final List<Color> _inverse;

  /// Text on the list background, text on a colour band.
  final Color text;
  final Color bandText;

  /// The box lines (sy-vline / sy-uline).
  final Color frame;

  /// An input cell (`WRITE … INPUT`): its field and its outline.
  final Color input;
  final Color inputBorder;

  /// The dark list, as the Java GUI's dark theme: the heading band a grey
  /// blue, the key band a dark blue, the intensified band the brighter.
  static const dark = SapListPalette._(
    [
      (Color(0xFF465567), Color(0xFF353F4B)), // COL_HEADING
      (Color(0xFF30363D), Color(0xFF262B31)), // COL_NORMAL
      (Color(0xFF7A6A17), Color(0xFF574D1B)), // COL_TOTAL
      (Color(0xFF1F5182), Color(0xFF1D3F63)), // COL_KEY
      (Color(0xFF2F6837), Color(0xFF274B2C)), // COL_POSITIVE
      (Color(0xFF85302F), Color(0xFF5E2D2D)), // COL_NEGATIVE
      (Color(0xFF8C561C), Color(0xFF634525)), // COL_GROUP
    ],
    [
      Color(0xFFE3E3E3), // COL_BACKGROUND
      Color(0xFFA9BCD2),
      Color(0xFFCBD1D8),
      Color(0xFFF0D04A),
      Color(0xFF74B4F0),
      Color(0xFF79D284),
      Color(0xFFF07A78),
      Color(0xFFF2A65A),
    ],
    Color(0xFFE3E3E3),
    Color(0xFFF1F3F5),
    Color(0xFF7D8590),
    Color(0xFF14171B),
    Color(0xFF8C96A3),
  );

  /// The light list, as SAP GUI's classic colours.
  static const light = SapListPalette._(
    [
      (Color(0xFFB7CADD), Color(0xFFD9E4EF)), // COL_HEADING
      (Color(0xFFE2E8EE), Color(0xFFF1F4F7)), // COL_NORMAL
      (Color(0xFFF4DE68), Color(0xFFFBF0B9)), // COL_TOTAL
      (Color(0xFF8EBFE6), Color(0xFFC6DEF2)), // COL_KEY
      (Color(0xFF9AD39C), Color(0xFFCFEBCF)), // COL_POSITIVE
      (Color(0xFFEF9C9A), Color(0xFFF8D0CF)), // COL_NEGATIVE
      (Color(0xFFF1BD73), Color(0xFFFADDB5)), // COL_GROUP
    ],
    [
      Color(0xFF1F1F1F),
      Color(0xFF3F5F7F),
      Color(0xFF4A4F55),
      Color(0xFF8A6F00),
      Color(0xFF1A5A9C),
      Color(0xFF2E7D32),
      Color(0xFFC62828),
      Color(0xFFB85F00),
    ],
    Color(0xFF1F1F1F),
    Color(0xFF111111),
    Color(0xFF8A939D),
    Color(0xFFFFFFFF),
    Color(0xFF7F8A96),
  );

  static SapListPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// The band behind [s], null on the list background.
  Color? band(ListSegment s) {
    if (s.frame || s.inverse || s.color == 0) return null;
    final b = _bands[s.color - 1];
    return s.intensified ? b.$1 : b.$2;
  }

  /// The text colour of [s].
  Color foreground(ListSegment s) {
    if (s.inverse) return _inverse[s.color];
    return band(s) != null ? bandText : text;
  }
}

/// The character cell of a list: the monospace advance at [fontSize] and
/// the row height (rows touch: the frame's rails join from row to row).
class SapListMetrics {
  SapListMetrics(this.style, this.cw, this.lh);

  /// The cells measured so far, by (base style, font size, line floor): a
  /// list rebuild — a tap, a tick, a busy flip — laid a TextPainter out
  /// anew.
  static final Map<(TextStyle, double, double), SapListMetrics> _measured = {};

  /// The line a finger lands on: a classic list line on a touch platform
  /// is never under it, whatever the font (a 170-column where-used list
  /// fitted to a phone's width reads at the 10-point floor: 15-point
  /// lines, a finger over two or three). A tap floor, not SAP geometry —
  /// the character cell keeps the server's grid, and the frame's rails
  /// still join as every line is the same height. The same 30 points as
  /// an ALV grid row and the dynpro's field row cap.
  static const double touchLine = 30;

  /// The floor [of] applies when none is given: [touchLine] on a touch
  /// platform (the phones; a widget test runs as Android), none on a
  /// desktop (the macOS target keeps SAP GUI's 1.5-em lines).
  static double get defaultMinLine => switch (defaultTargetPlatform) {
    TargetPlatform.iOS ||
    TargetPlatform.android ||
    TargetPlatform.fuchsia => touchLine,
    _ => 0,
  };

  factory SapListMetrics.of(
    TextStyle base,
    double fontSize, {
    double? minLine,
  }) {
    final floor = minLine ?? defaultMinLine;
    final key = (base, fontSize, floor);
    final known = _measured[key];
    if (known != null) return known;
    if (_measured.length >= 64) _measured.clear(); // a bound, never reached
    return _measured[key] = SapListMetrics._measure(base, fontSize, floor);
  }

  factory SapListMetrics._measure(
    TextStyle base,
    double fontSize,
    double minLine,
  ) {
    // every glyph on the cell's advance: no inherited letter / word
    // spacing (the theme's bodyMedium carries 0.25), no weight
    final style = base.copyWith(
      fontSize: fontSize,
      height: 1.0,
      letterSpacing: 0,
      wordSpacing: 0,
      fontWeight: FontWeight.w400,
      fontStyle: FontStyle.normal,
    );
    final tp = TextPainter(
      text: TextSpan(text: 'M' * 20, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final cw = tp.width / 20;
    tp.dispose();
    final lh = math.max((fontSize * 1.5).roundToDouble(), minLine);
    return SapListMetrics(style, cw, lh);
  }

  final TextStyle style;
  final double cw;
  final double lh;
}

/// The painted columns of [rows] (the widest line's end).
int sapListColumns(Iterable<ListLine?> rows) {
  var cols = 0;
  for (final l in rows) {
    if (l == null) continue;
    for (final s in l.segments) {
      cols = math.max(cols, s.end);
    }
    cols = math.max(cols, l.col0 + l.text.length);
  }
  return cols;
}

/// One classic list line on the SAP character grid: the colour bands, the
/// box lines drawn as continuous strokes, the text (hotspots underlined),
/// icons and input cells — a checkbox a real one. As on the real GUI a tap
/// reports the tapped column ([onTapAt]) — the owner places the list
/// cursor there (no round: a recorded session, a
/// click sends no frame) — and a second tap in time the double-click
/// ([onDoubleTapAt]: the pick, F2 with the cursor there, g9). A tap on a
/// HOTSPOT run (`FORMAT HOTSPOT`, SFE extension 0x04: the SE16 standard
/// list's cells, a recorded session srv_17_18; the SE11 hit
/// list's sort headings, a recorded session srv_60_68) is the pick at
/// once, as the real GUI's single click on one is, and a second tap in
/// time is not also a double-click (the grid's rule for its hotspots). A
/// checkbox tap stages its value ([onCheck]) and wins over the line's.
/// [cursorCol] draws the list cursor's cell and tints the cursor's line.
///
/// A screen reader gets the line's tap at its first hotspot (else its
/// first text run) and the pick as a custom action, 'Choose (F2)'.
class SapListLineView extends StatelessWidget {
  const SapListLineView({
    super.key,
    required this.line,
    required this.metrics,
    required this.palette,
    required this.width,
    this.icons,
    this.onTapAt,
    this.onDoubleTapAt,
    this.cursorCol,
    this.cursorColor,
    this.onCheck,
    this.checkedOf,
  });

  final ListLine? line;
  final SapListMetrics metrics;
  final SapListPalette palette;
  final double width;
  final SapIconAtlas? icons;

  /// A tap at buffer column (the cell under the finger), and the pick
  /// there: the second tap of a double-tap, or the single tap of a
  /// hotspot cell.
  final ValueChanged<int>? onTapAt;
  final ValueChanged<int>? onDoubleTapAt;

  /// The list cursor's column on this line, null when it is elsewhere.
  final int? cursorCol;
  final Color? cursorColor;
  final void Function(ListSegment cell, bool on)? onCheck;

  /// The checkbox's current value (a staged tick over the painted one).
  final bool Function(ListSegment cell)? checkedOf;

  @override
  Widget build(BuildContext context) {
    final l = line;
    final cw = metrics.cw, lh = metrics.lh;
    if (l == null) return SizedBox(width: width, height: lh);
    final boxes = <Widget>[]; // the checkboxes: above the line's taps
    // a glyph's box — an icon's, a checkbox's: the line's height, at most
    // its two-cell slot (a finger-high line keeps character-sized glyphs)
    final box = math.min(lh, cw * 2.4);
    final children = <Widget>[
      Positioned.fill(
        child: CustomPaint(painter: _ListLinePainter(l, cw, lh, palette)),
      ),
      // the cursor's line, tinted the width of the list: the cell box
      // alone is a few points wide (over the bands and under the text)
      if (cursorCol != null)
        Positioned.fill(
          key: const ValueKey('sap-list-cursor-band'),
          child: IgnorePointer(
            child: ColoredBox(
              color: (cursorColor ?? palette.text).withValues(alpha: 0.10),
            ),
          ),
        ),
      if (cursorCol != null)
        Positioned(
          key: const ValueKey('sap-list-cursor'),
          left: cursorCol! * cw,
          top: 1,
          width: cw,
          height: lh - 2,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: cursorColor ?? palette.text,
                  width: 1.5,
                ),
              ),
            ),
          ),
        ),
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(children: _spans(l)),
            softWrap: false,
            maxLines: 1,
            overflow: TextOverflow.clip,
            textScaler: TextScaler.noScaling,
            style: metrics.style.copyWith(color: palette.text),
          ),
        ),
      ),
    ];
    for (final s in l.segments) {
      final code = s.icon;
      if (code != null) {
        final cp = icons?.codepoint(code);
        Widget glyph = cp == null
            ? Icon(Icons.circle_outlined, size: box * 0.6, color: palette.text)
            : Text(
                String.fromCharCode(cp),
                textScaler: TextScaler.noScaling,
                // the glyph is a private-use character: its quick info
                // is what a reader says
                semanticsLabel: s.tip ?? '',
                style: TextStyle(
                  fontFamily: 'SapIcons',
                  fontSize: box * 0.72,
                  height: 1.0,
                  color: palette.foreground(s),
                ),
              );
        if (s.tip != null) glyph = Tooltip(message: s.tip!, child: glyph);
        children.add(Positioned(
          left: s.col * cw,
          top: 0,
          width: 2 * cw,
          height: lh,
          child: Center(child: glyph),
        ));
      } else if (s.checkbox) {
        final on = checkedOf?.call(s) ?? s.checked;
        final enabled = s.input && onCheck != null;
        // the hit area: the box's cell and one either side (the list
        // paints a blank cell after it: the where-used list's at column
        // 2, SM37's at 1), the line's full height — a finger's, where the
        // glyph is 14-19 points
        final hit = math.max(box, 3 * cw);
        boxes.add(Positioned(
          left: s.col * cw + cw / 2 - hit / 2,
          top: 0,
          width: hit,
          height: lh,
          child: SapListCheckGlyph(
            on: on,
            enabled: enabled,
            size: box,
            onTap: enabled ? () => onCheck!(s, !on) : null,
          ),
        ));
      }
    }
    if (onTapAt == null && onDoubleTapAt == null) {
      return SizedBox(
        width: width,
        height: lh,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [...children, ...boxes],
        ),
      );
    }
    // the cell under the finger; a SERIAL tap recognizer reports the tap
    // count (a double-tap recognizer would hold every tap for the
    // double-tap timeout). The checkboxes lie above it, outside it: a tap
    // on one is the checkbox's alone
    final taps = RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        SerialTapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<SerialTapGestureRecognizer>(
          SerialTapGestureRecognizer.new,
          (r) => r.onSerialTapUp = (d) {
            final col = math.max(0, (d.localPosition.dx / cw).floor());
            if (_hotspotAt(l, col)) {
              // the hotspot click: the pick, at once; a second tap in
              // time is not also a double-click (sap_grid_view
              // _cellGestures: the click already went to the server)
              if (d.count == 1) (onDoubleTapAt ?? onTapAt)?.call(col);
              return;
            }
            final f = d.count >= 2 ? onDoubleTapAt ?? onTapAt : onTapAt;
            f?.call(col);
          },
        ),
      },
      child: Stack(clipBehavior: Clip.hardEdge, children: children),
    );
    // a screen reader's tap lands on the first hotspot, else the first
    // text run; the pick (the double-click) is its own action
    final readerCol = _readerColumn(l);
    final pick = onDoubleTapAt ?? onTapAt;
    return SizedBox(
      width: width,
      height: lh,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned.fill(
            child: Semantics(
              onTap: onTapAt == null ? null : () => onTapAt!(readerCol),
              customSemanticsActions: pick == null
                  ? null
                  : {
                      const CustomSemanticsAction(label: 'Choose (F2)'): () =>
                          pick(readerCol),
                    },
              child: taps,
            ),
          ),
          ...boxes,
        ],
      ),
    );
  }

  /// Whether buffer column [col] of [l] lies in a hotspot run (any run:
  /// `WRITE icon AS ICON HOTSPOT` too, and a blank hotspot run).
  static bool _hotspotAt(ListLine l, int col) {
    for (final s in l.segments) {
      if (s.hotspot && s.covers(col)) return true;
    }
    return false;
  }

  /// The column a screen reader's tap lands on: the first hotspot run's,
  /// else the first text run's, else the line's start.
  static int _readerColumn(ListLine l) {
    for (final s in l.segments) {
      if (s.hotspot) return s.col;
    }
    final plain = _plainOf(l);
    for (final s in plain) {
      if (s.text.trim().isNotEmpty) return s.col;
    }
    return l.col0;
  }

  /// The line's text as spans on the cell grid: frames, icons and
  /// checkboxes are painted over blank cells, unpainted columns blank.
  List<InlineSpan> _spans(ListLine l) {
    final out = <InlineSpan>[];
    var at = 0;
    final plain = _plainOf(l);
    // trailing blanks are not text (the plain text a reader sees)
    var last = plain.length - 1;
    while (last >= 0 && plain[last].text.trim().isEmpty) {
      last--;
    }
    for (var i = 0; i <= last; i++) {
      final s = plain[i];
      if (s.col < at) continue; // painted over (never on the wire)
      if (s.col > at) out.add(TextSpan(text: ' ' * (s.col - at)));
      final text = i == last ? s.text.trimRight() : s.text;
      out.add(TextSpan(
        text: text,
        style: TextStyle(
          // the colour carries INTENSIFIED, never the weight: a bold
          // glyph may not keep the cell's advance
          color: palette.foreground(s),
          decoration: s.hotspot ? TextDecoration.underline : null,
          decorationColor: palette.foreground(s),
        ),
      ));
      at = s.col + text.length;
    }
    return out;
  }
}

/// A checkbox cell — a list's, a table control's — as a glyph, not a
/// Material toggle: a Checkbox brings four animation controllers, a focus
/// node and a dozen elements to every cell (SM37, SP01: one per line on
/// screen; ME21N's two checkbox columns) for a tick that only stages a
/// value. The glyph keeps Material's three looks — on in the primary
/// colour, off outlined, disabled greyed — and a reader's checked state;
/// without [onTap] it is inert and still swallows the tap (a disabled box
/// is not the line's cursor cell); with none the owner's own tap layer
/// (a table control cell's InkWell) takes it.
class SapListCheckGlyph extends StatelessWidget {
  const SapListCheckGlyph({
    super.key,
    required this.on,
    required this.enabled,
    required this.size,
    this.onTap,
  });

  final bool on;
  final bool enabled;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = !enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : on
        ? scheme.primary
        : scheme.onSurfaceVariant;
    final glyph = Center(
      child: Icon(
        on ? Icons.check_box : Icons.check_box_outline_blank,
        size: size,
        color: color,
      ),
    );
    return Semantics(
      checked: on,
      enabled: enabled,
      child: onTap == null && enabled
          ? glyph
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: glyph,
            ),
    );
  }
}

/// The text runs of [l] in column order (no frame, icon or checkbox cell),
/// sorted once per line: a cursor move or a busy flip rebuilds the line,
/// not its runs. The segment count guards a line mutated in place.
final Expando<(int, List<ListSegment>)> _plainRuns = Expando('list runs');

List<ListSegment> _plainOf(ListLine l) {
  final memo = _plainRuns[l];
  if (memo != null && memo.$1 == l.segments.length) return memo.$2;
  final segs = [...l.segments]..sort((a, b) => a.col.compareTo(b.col));
  final plain = <ListSegment>[
    for (final s in segs)
      if (!s.frame && s.icon == null && !s.checkbox) s,
  ];
  _plainRuns[l] = (l.segments.length, plain);
  return plain;
}

/// The bands, input cells and box lines of one list line.
class _ListLinePainter extends CustomPainter {
  _ListLinePainter(this.line, this.cw, this.lh, this.palette);
  final ListLine line;
  final double cw, lh;
  final SapListPalette palette;

  /// The arms of each box glyph: up, down, left, right.
  static const Map<int, int> _arms = {
    0x250C: _d | _r, // ┌
    0x2514: _u | _r, // └
    0x2510: _d | _l, // ┐
    0x2518: _u | _l, // ┘
    0x2500: _l | _r, // ─
    0x2502: _u | _d, // │
    0x251C: _u | _d | _r, // ├
    0x2524: _u | _d | _l, // ┤
    0x2534: _u | _l | _r, // ┴
    0x252C: _d | _l | _r, // ┬
    0x253C: _u | _d | _l | _r, // ┼
  };
  static const _u = 1, _d = 2, _l = 4, _r = 8;

  /// The painter's brushes, one set for every line (a paint per line per
  /// frame allocated three).
  static final Paint _fill = Paint();
  static final Paint _border = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  static final Paint _pen = Paint()
    ..strokeWidth = 1
    ..style = PaintingStyle.stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = _fill;
    for (final s in line.segments) {
      final band = palette.band(s);
      final rect = Rect.fromLTWH(s.col * cw, 0, s.width * cw, lh);
      if (band != null) {
        canvas.drawRect(rect, fill..color = band);
      }
      if (s.input && !s.checkbox && !s.frame) {
        // an editable cell: SAP GUI's white field in the list
        final r = rect.deflate(1);
        // a coloured input keeps its band (SHOWCOLO's INPUT columns)
        if (band == null) canvas.drawRect(r, fill..color = palette.input);
        canvas.drawRect(r, _border..color = palette.inputBorder);
      }
    }
    final pen = _pen..color = palette.frame;
    final y = (lh / 2).floorToDouble() + 0.5;
    // the horizontal arms of a rule join into ONE stroke per run (cell by
    // cell, a fractional cell width paints a dotted rule)
    double? from;
    var to = 0.0;
    void flush() {
      if (from != null) canvas.drawLine(Offset(from!, y), Offset(to, y), pen);
      from = null;
    }

    for (final s in line.segments) {
      if (!s.frame) continue;
      for (var i = 0; i < s.text.length; i++) {
        final arms = _arms[s.text.codeUnitAt(i)];
        final x0 = (s.col + i) * cw;
        final x = (x0 + cw / 2).floorToDouble() + 0.5;
        if (arms == null) {
          flush();
          continue;
        }
        if (arms & _u != 0) canvas.drawLine(Offset(x, 0), Offset(x, y), pen);
        if (arms & _d != 0) canvas.drawLine(Offset(x, y), Offset(x, lh), pen);
        final l = arms & _l != 0, r = arms & _r != 0;
        if (l && from != null && (to - x0).abs() < 0.01) {
          to = r ? x0 + cw : x; // the stroke runs on
        } else {
          flush();
          if (l || r) {
            from = l ? x0 : x - 0.5;
            to = r ? x0 + cw : x + 0.5;
          }
        }
        if (!r) flush();
      }
      flush();
    }
  }

  @override
  bool shouldRepaint(_ListLinePainter old) =>
      !identical(old.line, line) ||
      old.cw != cw ||
      old.lh != lh ||
      !identical(old.palette, palette);
}
