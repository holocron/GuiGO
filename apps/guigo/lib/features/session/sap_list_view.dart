import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

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

  factory SapListMetrics.of(TextStyle base, double fontSize) {
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
    return SapListMetrics(style, cw, (fontSize * 1.5).roundToDouble());
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
/// icons and input cells — a checkbox a real one. A tap on the line is the
/// list's pick ([onTap]); a checkbox tap stages its value ([onCheck]).
class SapListLineView extends StatelessWidget {
  const SapListLineView({
    super.key,
    required this.line,
    required this.metrics,
    required this.palette,
    required this.width,
    this.icons,
    this.onTap,
    this.onCheck,
    this.checkedOf,
  });

  final ListLine? line;
  final SapListMetrics metrics;
  final SapListPalette palette;
  final double width;
  final SapIconAtlas? icons;
  final VoidCallback? onTap;
  final void Function(ListSegment cell, bool on)? onCheck;

  /// The checkbox's current value (a staged tick over the painted one).
  final bool Function(ListSegment cell)? checkedOf;

  @override
  Widget build(BuildContext context) {
    final l = line;
    final cw = metrics.cw, lh = metrics.lh;
    if (l == null) return SizedBox(width: width, height: lh);
    final children = <Widget>[
      Positioned.fill(
        child: CustomPaint(painter: _ListLinePainter(l, cw, lh, palette)),
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
            ? Icon(Icons.circle_outlined, size: lh * 0.6, color: palette.text)
            : Text(
                String.fromCharCode(cp),
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontFamily: 'SapIcons',
                  fontSize: lh * 0.72,
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
        final box = math.min(lh, cw * 2.4);
        children.add(Positioned(
          left: s.col * cw + cw / 2 - box / 2,
          top: (lh - box) / 2,
          width: box,
          height: box,
          child: FittedBox(
            child: Checkbox(
              value: on,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: enabled ? (v) => onCheck!(s, v ?? false) : null,
            ),
          ),
        ));
      }
    }
    return SizedBox(
      width: width,
      height: lh,
      child: InkWell(
        onTap: onTap,
        child: Stack(clipBehavior: Clip.hardEdge, children: children),
      ),
    );
  }

  /// The line's text as spans on the cell grid: frames, icons and
  /// checkboxes are painted over blank cells, unpainted columns blank.
  List<InlineSpan> _spans(ListLine l) {
    final out = <InlineSpan>[];
    var at = 0;
    final segs = [...l.segments]..sort((a, b) => a.col.compareTo(b.col));
    final plain = <ListSegment>[
      for (final s in segs)
        if (!s.frame && s.icon == null && !s.checkbox) s,
    ];
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

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint();
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
        canvas.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = palette.inputBorder,
        );
      }
    }
    final pen = Paint()
      ..color = palette.frame
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
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
