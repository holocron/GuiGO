/// A small rich-text model shared by the RTF and .docx readers and the .docx
/// writer: paragraphs of styled runs, and simple tables of paragraphs.
///
/// Units are points (1/72 inch) throughout; colours are 0xRRGGBB.
library;

/// One run of uniformly formatted text. Tabs are `\t`, a manual line
/// break inside the paragraph is `\n`.
class RichRun {
  const RichRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.superscript = false,
    this.subscript = false,
    this.fontSize,
    this.color,
    this.highlight,
    this.font,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool superscript;
  final bool subscript;

  /// Font size in points, null = the reader's default.
  final double? fontSize;

  /// Text colour 0xRRGGBB, null = automatic (the theme's text colour).
  final int? color;

  /// Background (highlight / character shading) 0xRRGGBB, null = none.
  final int? highlight;

  /// Font family name, null = default.
  final String? font;

  /// Same formatting as [o] (text ignored): adjacent runs merge.
  bool sameFormat(RichRun o) =>
      bold == o.bold &&
      italic == o.italic &&
      underline == o.underline &&
      strike == o.strike &&
      superscript == o.superscript &&
      subscript == o.subscript &&
      fontSize == o.fontSize &&
      color == o.color &&
      highlight == o.highlight &&
      font == o.font;

  RichRun withText(String t) => RichRun(
    t,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    superscript: superscript,
    subscript: subscript,
    fontSize: fontSize,
    color: color,
    highlight: highlight,
    font: font,
  );

  @override
  String toString() {
    final f = [
      if (bold) 'b',
      if (italic) 'i',
      if (underline) 'u',
      if (strike) 's',
      if (fontSize != null) '${fontSize}pt',
      if (color != null) '#${color!.toRadixString(16).padLeft(6, '0')}',
      ?font,
    ];
    return 'RichRun(${f.join(',')} "$text")';
  }
}

enum RichAlign { left, center, right, justify }

/// A block of the document: a [RichParagraph] or a [RichTable].
sealed class RichBlock {
  const RichBlock();

  /// The block's text: paragraphs by line, table cells by tab.
  String get plainText;
}

class RichParagraph extends RichBlock {
  RichParagraph(
    List<RichRun> runs, {
    this.align = RichAlign.left,
    this.leftIndent = 0,
    this.rightIndent = 0,
    this.firstIndent = 0,
    this.spaceBefore = 0,
    this.spaceAfter = 0,
    this.shading,
    this.style,
    this.listMarker,
  }) : runs = List.unmodifiable(_merge(runs));

  final List<RichRun> runs;
  final RichAlign align;

  /// Indents in points ([firstIndent] relative to [leftIndent], may be
  /// negative: a hanging indent).
  final double leftIndent;
  final double rightIndent;
  final double firstIndent;
  final double spaceBefore;
  final double spaceAfter;

  /// Paragraph background 0xRRGGBB (RTF `\cbpat`, docx `w:shd`).
  final int? shading;

  /// The paragraph style's name (SAPscript: the paragraph format, e.g.
  /// `AS Paragraphe type`), null when unstyled.
  final String? style;

  /// A list bullet / number already rendered as text (RTF `\listtext`).
  final String? listMarker;

  @override
  String get plainText =>
      '${listMarker ?? ''}${runs.map((r) => r.text).join()}';

  bool get isEmpty => runs.every((r) => r.text.isEmpty) && listMarker == null;

  static List<RichRun> _merge(List<RichRun> runs) {
    final out = <RichRun>[];
    for (final r in runs) {
      if (r.text.isEmpty) continue;
      if (out.isNotEmpty && out.last.sameFormat(r)) {
        out[out.length - 1] = out.last.withText(out.last.text + r.text);
      } else {
        out.add(r);
      }
    }
    return out;
  }

  @override
  String toString() => 'RichParagraph(${style ?? ''} $runs)';
}

class RichTableCell {
  RichTableCell(List<RichParagraph> paragraphs, {this.width, this.span = 1})
    : paragraphs = List.unmodifiable(paragraphs);

  final List<RichParagraph> paragraphs;

  /// Width in points when the source states it.
  final double? width;

  /// Columns this cell spans (docx `w:gridSpan`).
  final int span;

  String get plainText => paragraphs.map((p) => p.plainText).join('\n');
}

class RichTable extends RichBlock {
  RichTable(List<List<RichTableCell>> rows)
    : rows = List.unmodifiable([
        for (final r in rows) List<RichTableCell>.unmodifiable(r),
      ]);

  final List<List<RichTableCell>> rows;

  int get columnCount => rows.fold(
    0,
    (m, r) => r.fold<int>(0, (n, c) => n + c.span) > m
        ? r.fold<int>(0, (n, c) => n + c.span)
        : m,
  );

  @override
  String get plainText =>
      rows.map((r) => r.map((c) => c.plainText).join('\t')).join('\n');
}

/// A rich-text document: its blocks in reading order.
class RichDocument {
  RichDocument(List<RichBlock> blocks, {this.title})
    : blocks = List.unmodifiable(blocks);

  final List<RichBlock> blocks;

  /// The document's title metadata (RTF `\info\title`, docx core title)
  /// when it has one.
  final String? title;

  Iterable<RichParagraph> get paragraphs sync* {
    for (final b in blocks) {
      switch (b) {
        case RichParagraph():
          yield b;
        case RichTable():
          for (final r in b.rows) {
            for (final c in r) {
              yield* c.paragraphs;
            }
          }
      }
    }
  }

  String get plainText => blocks.map((b) => b.plainText).join('\n');
}
