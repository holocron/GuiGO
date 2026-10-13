/// A minimal .docx writer for a [RichDocument]: paragraphs (alignment,
/// indents, spacing, shading, style name kept as a custom paragraph
/// style), runs (bold / italic / underline / strike / super- and
/// subscript / size / colour / highlight / font, tabs and line breaks) and
/// tables with a single-line grid. The package carries the parts Word,
/// Pages and LibreOffice expect (content types, package and document
/// relationships, styles, core properties, a section with an A4 page).
library;

import 'dart:typed_data';

import 'ooxml.dart';
import 'rich_text.dart';
import 'zip.dart';

const _xmlHead = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';
const _nsW = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _nsRel =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

/// Serialises [doc] as a .docx package. [defaultFontSize] (points) is the
/// document default a run without a size gets.
Uint8List writeDocx(RichDocument doc, {double defaultFontSize = 11}) {
  final styles = _StyleIds();
  final body = StringBuffer();
  for (final b in doc.blocks) {
    switch (b) {
      case RichParagraph():
        body.write(_paragraph(b, styles));
      case RichTable():
        body.write(_table(b, styles));
    }
  }
  // Word ends every body (and every cell) with a paragraph
  if (doc.blocks.isEmpty || doc.blocks.last is RichTable) body.write('<w:p/>');
  body.write(
    '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
    '<w:pgMar w:top="1417" w:right="1417" w:bottom="1134" w:left="1417" '
    'w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>',
  );

  final zip = ZipWriter();
  zip.addText(
    '[Content_Types].xml',
    '$_xmlHead<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
        '</Types>',
  );
  zip.addText(
    '_rels/.rels',
    '$_xmlHead<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="$_nsRel/officeDocument" Target="word/document.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '<Relationship Id="rId3" Type="$_nsRel/extended-properties" Target="docProps/app.xml"/>'
        '</Relationships>',
  );
  zip.addText('docProps/core.xml', corePropsXml(doc.title));
  zip.addText(
    'docProps/app.xml',
    '$_xmlHead<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
        '<Application>GuiGo</Application></Properties>',
  );
  zip.addText(
    'word/_rels/document.xml.rels',
    '$_xmlHead<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="$_nsRel/styles" Target="styles.xml"/>'
        '</Relationships>',
  );
  zip.addText(
    'word/document.xml',
    '$_xmlHead<w:document xmlns:w="$_nsW" xmlns:r="$_nsRel"><w:body>$body</w:body></w:document>',
  );
  zip.addText('word/styles.xml', styles.xml(defaultFontSize));
  return zip.finish();
}

/// The source's paragraph style names as custom styles `S1`, `S2`, …
class _StyleIds {
  final Map<String, String> ids = {};

  String idOf(String name) => ids.putIfAbsent(name, () => 'S${ids.length + 1}');

  String xml(double size) {
    final b = StringBuffer(
      '$_xmlHead<w:styles xmlns:w="$_nsW">'
      '<w:docDefaults><w:rPrDefault><w:rPr>'
      '<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/>'
      '<w:sz w:val="${(size * 2).round()}"/><w:szCs w:val="${(size * 2).round()}"/>'
      '</w:rPr></w:rPrDefault><w:pPrDefault><w:pPr/></w:pPrDefault></w:docDefaults>'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
      '<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/>'
      '<w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/>'
      '<w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/>'
      '</w:tblCellMar></w:tblPr></w:style>',
    );
    for (final e in ids.entries) {
      b.write(
        '<w:style w:type="paragraph" w:customStyle="1" w:styleId="${e.value}">'
        '<w:name w:val="${xmlEscape(e.key)}"/><w:basedOn w:val="Normal"/></w:style>',
      );
    }
    b.write('</w:styles>');
    return b.toString();
  }
}

String _tw(double pt) => (pt * 20).round().toString();

String _hex(int c) =>
    (c & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase();

String _paragraph(RichParagraph p, _StyleIds styles) {
  final ppr = StringBuffer();
  if (p.style != null && p.style!.trim().isNotEmpty) {
    ppr.write('<w:pStyle w:val="${styles.idOf(p.style!.trim())}"/>');
  }
  if (p.shading != null) {
    ppr.write(
      '<w:shd w:val="clear" w:color="auto" w:fill="${_hex(p.shading!)}"/>',
    );
  }
  if (p.spaceBefore != 0 || p.spaceAfter != 0) {
    ppr.write(
      '<w:spacing w:before="${_tw(p.spaceBefore)}" w:after="${_tw(p.spaceAfter)}"/>',
    );
  }
  if (p.leftIndent != 0 || p.rightIndent != 0 || p.firstIndent != 0) {
    final first = p.firstIndent < 0
        ? ' w:hanging="${_tw(-p.firstIndent)}"'
        : p.firstIndent > 0
        ? ' w:firstLine="${_tw(p.firstIndent)}"'
        : '';
    ppr.write(
      '<w:ind w:left="${_tw(p.leftIndent)}" w:right="${_tw(p.rightIndent)}"$first/>',
    );
  }
  final jc = switch (p.align) {
    RichAlign.left => null,
    RichAlign.center => 'center',
    RichAlign.right => 'right',
    RichAlign.justify => 'both',
  };
  if (jc != null) ppr.write('<w:jc w:val="$jc"/>');
  final b = StringBuffer('<w:p>');
  if (ppr.isNotEmpty) b.write('<w:pPr>$ppr</w:pPr>');
  if (p.listMarker != null && p.listMarker!.isNotEmpty) {
    b.write(_run(RichRun(p.listMarker!)));
  }
  for (final r in p.runs) {
    b.write(_run(r));
  }
  b.write('</w:p>');
  return b.toString();
}

String _run(RichRun r) {
  final rpr = StringBuffer();
  if (r.font != null && r.font!.isNotEmpty) {
    final f = xmlEscape(r.font!);
    rpr.write('<w:rFonts w:ascii="$f" w:hAnsi="$f" w:cs="$f"/>');
  }
  if (r.bold) rpr.write('<w:b/><w:bCs/>');
  if (r.italic) rpr.write('<w:i/><w:iCs/>');
  if (r.strike) rpr.write('<w:strike/>');
  if (r.color != null) rpr.write('<w:color w:val="${_hex(r.color!)}"/>');
  if (r.fontSize != null && r.fontSize! > 0) {
    final hp = (r.fontSize! * 2).round().clamp(2, 3276);
    rpr.write('<w:sz w:val="$hp"/><w:szCs w:val="$hp"/>');
  }
  // CT_RPr's sequence: … sz, szCs, highlight, u, effect, bdr, shd, …
  if (r.underline) rpr.write('<w:u w:val="single"/>');
  if (r.highlight != null) {
    rpr.write(
      '<w:shd w:val="clear" w:color="auto" w:fill="${_hex(r.highlight!)}"/>',
    );
  }
  if (r.superscript) {
    rpr.write('<w:vertAlign w:val="superscript"/>');
  } else if (r.subscript) {
    rpr.write('<w:vertAlign w:val="subscript"/>');
  }
  final b = StringBuffer('<w:r>');
  if (rpr.isNotEmpty) b.write('<w:rPr>$rpr</w:rPr>');
  final t = StringBuffer();
  void flush() {
    if (t.isEmpty) return;
    b.write('<w:t xml:space="preserve">${xmlEscape(t.toString())}</w:t>');
    t.clear();
  }

  for (final ch in r.text.split('')) {
    if (ch == '\t') {
      flush();
      b.write('<w:tab/>');
    } else if (ch == '\n') {
      flush();
      b.write('<w:br/>');
    } else if (ch == '\r') {
      continue;
    } else {
      t.write(ch);
    }
  }
  flush();
  b.write('</w:r>');
  return b.toString();
}

String _table(RichTable t, _StyleIds styles) {
  final cols = t.columnCount < 1 ? 1 : t.columnCount;
  // grid widths: the first row that states every width, else equal parts
  // of a 9000-twip text width
  List<double>? grid;
  for (final r in t.rows) {
    if (r.every((c) => c.width != null && c.span == 1) && r.length == cols) {
      grid = [for (final c in r) c.width!];
      break;
    }
  }
  grid ??= List.filled(cols, 450 / cols);
  const border = 'w:val="single" w:sz="4" w:space="0" w:color="auto"';
  final b = StringBuffer(
    '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders>'
    '<w:top $border/><w:left $border/><w:bottom $border/><w:right $border/>'
    '<w:insideH $border/><w:insideV $border/></w:tblBorders>'
    '<w:tblLook w:val="04A0"/></w:tblPr><w:tblGrid>',
  );
  for (final w in grid) {
    b.write('<w:gridCol w:w="${_tw(w)}"/>');
  }
  b.write('</w:tblGrid>');
  for (final r in t.rows) {
    b.write('<w:tr>');
    var used = 0;
    for (final c in r) {
      var w = c.width;
      if (w == null) {
        w = 0;
        for (var k = used; k < used + c.span && k < grid.length; k++) {
          w = w! + grid[k];
        }
      }
      used += c.span;
      b.write('<w:tc><w:tcPr><w:tcW w:w="${_tw(w!)}" w:type="dxa"/>');
      if (c.span > 1) b.write('<w:gridSpan w:val="${c.span}"/>');
      b.write('</w:tcPr>');
      if (c.paragraphs.isEmpty) {
        b.write('<w:p/>');
      } else {
        for (final p in c.paragraphs) {
          b.write(_paragraph(p, styles));
        }
      }
      b.write('</w:tc>');
    }
    // a short row is padded so every row spans the grid
    for (; used < cols; used++) {
      b.write(
        '<w:tc><w:tcPr><w:tcW w:w="${_tw(grid[used])}" w:type="dxa"/></w:tcPr><w:p/></w:tc>',
      );
    }
    b.write('</w:tr>');
  }
  b.write('</w:tbl>');
  return b.toString();
}
