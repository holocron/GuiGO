/// A .docx (WordprocessingML) reader: the main document part's paragraphs,
/// runs and tables into a [RichDocument], with minimal style resolution
/// (document defaults, paragraph / character styles and their `basedOn`
/// chain for bold / italic / underline / size / colour / font /
/// alignment).
///
/// Content controls, hyperlinks, insertions and simple fields are read
/// through; deletions, field instructions, drawings and hidden (`vanish`)
/// text are skipped. Nested tables are flattened into their cell.
library;

import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'ooxml.dart';
import 'rich_text.dart';
import 'zip.dart';

/// Reads the .docx package [bytes]. Throws [ZipException] / [FormatException]
/// for a damaged package.
RichDocument readDocx(Uint8List bytes) {
  final zip = ZipReader(bytes);
  return readDocxFrom(zip);
}

RichDocument readDocxFrom(ZipReader zip) {
  final main = mainPartOf(zip, 'word/document.xml');
  final doc = parseXmlPart(zip.readText(main));
  if (doc == null) throw const FormatException('no readable word/document.xml');
  final stylesPath = relatedPart(zip, main, '/styles') ?? 'word/styles.xml';
  final styles = _Styles(parseXmlPart(zip.readText(stylesPath)));
  final body = doc.rootElement.childElements
      .where((e) => e.name.local == 'body')
      .firstOrNull;
  final blocks = <RichBlock>[];
  if (body != null) _readBlocks(body, styles, blocks);
  return RichDocument(blocks, title: coreTitle(zip));
}

class _RunFmt {
  bool? b, i, u, s, hidden;
  String? vert; // superscript / subscript / baseline
  double? size;
  int? color, highlight;
  String? font;

  void apply(_RunFmt o) {
    b = o.b ?? b;
    i = o.i ?? i;
    u = o.u ?? u;
    s = o.s ?? s;
    hidden = o.hidden ?? hidden;
    vert = o.vert ?? vert;
    size = o.size ?? size;
    color = o.color ?? color;
    highlight = o.highlight ?? highlight;
    font = o.font ?? font;
  }

  _RunFmt copy() => _RunFmt()..apply(this);
}

class _ParaFmt {
  RichAlign? align;
  double? left, right, first, before, after;
  int? shading;

  void apply(_ParaFmt o) {
    align = o.align ?? align;
    left = o.left ?? left;
    right = o.right ?? right;
    first = o.first ?? first;
    before = o.before ?? before;
    after = o.after ?? after;
    shading = o.shading ?? shading;
  }
}

class _Style {
  String? name, basedOn;
  _RunFmt run = _RunFmt();
  _ParaFmt para = _ParaFmt();
}

class _Styles {
  _Styles(XmlDocument? x) {
    if (x == null) return;
    for (final e in x.rootElement.childElements) {
      if (e.name.local == 'docDefaults') {
        final rpr = e.descendantElements
            .where((d) => d.name.local == 'rPr')
            .firstOrNull;
        if (rpr != null) defaults = _runFmt(rpr);
        final ppr = e.descendantElements
            .where((d) => d.name.local == 'pPr')
            .firstOrNull;
        if (ppr != null) paraDefaults = _paraFmt(ppr);
      } else if (e.name.local == 'style') {
        final id = attr(e, 'styleId');
        if (id == null) continue;
        final s = _Style()
          ..name = attr(child(e, 'name') ?? e, 'val')
          ..basedOn = child(e, 'basedOn') == null
              ? null
              : attr(child(e, 'basedOn')!, 'val');
        final rpr = child(e, 'rPr');
        if (rpr != null) s.run = _runFmt(rpr);
        final ppr = child(e, 'pPr');
        if (ppr != null) s.para = _paraFmt(ppr);
        byId[id] = s;
        if (attr(e, 'default') == '1' && attr(e, 'type') == 'paragraph') {
          defaultPara = id;
        }
      }
    }
  }

  _RunFmt defaults = _RunFmt();
  _ParaFmt paraDefaults = _ParaFmt();
  final Map<String, _Style> byId = {};
  String? defaultPara;

  /// [id]'s chain, root first (bounded: a cyclic basedOn ends).
  List<_Style> chain(String? id) {
    final out = <_Style>[];
    var cur = id;
    final seen = <String>{};
    while (cur != null && seen.add(cur) && out.length < 16) {
      final s = byId[cur];
      if (s == null) break;
      out.insert(0, s);
      cur = s.basedOn;
    }
    return out;
  }
}

double? _twips(String? v) {
  final n = v == null ? null : double.tryParse(v);
  return n == null ? null : n / 20;
}

int? _hex(String? v) {
  if (v == null || v == 'auto' || v.length != 6) return null;
  return int.tryParse(v, radix: 16);
}

const _highlights = {
  'black': 0x000000,
  'blue': 0x0000ff,
  'cyan': 0x00ffff,
  'green': 0x00ff00,
  'magenta': 0xff00ff,
  'red': 0xff0000,
  'yellow': 0xffff00,
  'white': 0xffffff,
  'darkBlue': 0x000080,
  'darkCyan': 0x008080,
  'darkGreen': 0x008000,
  'darkMagenta': 0x800080,
  'darkRed': 0x800000,
  'darkYellow': 0x808000,
  'darkGray': 0x808080,
  'lightGray': 0xc0c0c0,
};

_RunFmt _runFmt(XmlElement rpr) {
  final f = _RunFmt();
  for (final e in rpr.childElements) {
    switch (e.name.local) {
      case 'b':
        f.b = onOff(e);
      case 'i':
        f.i = onOff(e);
      case 'u':
        f.u = attr(e, 'val') != 'none';
      case 'strike' || 'dstrike':
        f.s = onOff(e);
      case 'vanish':
        f.hidden = onOff(e);
      case 'vertAlign':
        f.vert = attr(e, 'val');
      case 'sz':
        final v = double.tryParse(attr(e, 'val') ?? '');
        if (v != null && v > 0) f.size = v / 2;
      case 'color':
        f.color = _hex(attr(e, 'val'));
      case 'highlight':
        f.highlight = _highlights[attr(e, 'val')];
      case 'shd':
        f.highlight ??= _hex(attr(e, 'fill'));
      case 'rFonts':
        f.font = attr(e, 'ascii') ?? attr(e, 'hAnsi');
    }
  }
  return f;
}

_ParaFmt _paraFmt(XmlElement ppr) {
  final f = _ParaFmt();
  for (final e in ppr.childElements) {
    switch (e.name.local) {
      case 'jc':
        f.align = switch (attr(e, 'val')) {
          'center' => RichAlign.center,
          'right' || 'end' => RichAlign.right,
          'both' || 'distribute' => RichAlign.justify,
          _ => RichAlign.left,
        };
      case 'ind':
        f.left = _twips(attr(e, 'left') ?? attr(e, 'start'));
        f.right = _twips(attr(e, 'right') ?? attr(e, 'end'));
        final hanging = _twips(attr(e, 'hanging'));
        f.first = hanging != null ? -hanging : _twips(attr(e, 'firstLine'));
      case 'spacing':
        f.before = _twips(attr(e, 'before'));
        f.after = _twips(attr(e, 'after'));
      case 'shd':
        f.shading = _hex(attr(e, 'fill'));
    }
  }
  return f;
}

void _readBlocks(XmlElement parent, _Styles styles, List<RichBlock> out) {
  for (final e in parent.childElements) {
    switch (e.name.local) {
      case 'p':
        out.add(_paragraph(e, styles));
      case 'tbl':
        out.add(_table(e, styles));
      case 'sdt':
        final content = child(e, 'sdtContent');
        if (content != null) _readBlocks(content, styles, out);
      case 'customXml' || 'ins' || 'smartTag':
        _readBlocks(e, styles, out);
    }
  }
}

RichTable _table(XmlElement tbl, _Styles styles) {
  final rows = <List<RichTableCell>>[];
  for (final tr in tbl.childElements.where((e) => e.name.local == 'tr')) {
    final cells = <RichTableCell>[];
    for (final tc in tr.childElements.where((e) => e.name.local == 'tc')) {
      final paras = <RichParagraph>[];
      void collect(XmlElement x) {
        for (final e in x.childElements) {
          switch (e.name.local) {
            case 'p':
              paras.add(_paragraph(e, styles));
            case 'tbl':
              for (final r in children(e, 'tr')) {
                for (final c in children(r, 'tc')) {
                  collect(c);
                }
              }
            case 'sdt':
              final content = child(e, 'sdtContent');
              if (content != null) collect(content);
          }
        }
      }

      collect(tc);
      final pr = child(tc, 'tcPr');
      final span = int.tryParse(
        attr(child(pr ?? tc, 'gridSpan') ?? tc, 'val') ?? '',
      );
      final w = child(pr ?? tc, 'tcW');
      final width = w != null && attr(w, 'type') == 'dxa'
          ? _twips(attr(w, 'w'))
          : null;
      cells.add(
        RichTableCell(paras, width: width, span: (span ?? 1).clamp(1, 64)),
      );
    }
    rows.add(cells);
  }
  return RichTable(rows);
}

RichParagraph _paragraph(XmlElement p, _Styles styles) {
  final ppr = child(p, 'pPr');
  final styleId = ppr == null
      ? styles.defaultPara
      : (child(ppr, 'pStyle') == null
            ? styles.defaultPara
            : attr(child(ppr, 'pStyle')!, 'val'));
  final chain = styles.chain(styleId);
  final pf = _ParaFmt()..apply(styles.paraDefaults);
  final base = _RunFmt()..apply(styles.defaults);
  for (final s in chain) {
    pf.apply(s.para);
    base.apply(s.run);
  }
  if (ppr != null) pf.apply(_paraFmt(ppr));
  final runs = <RichRun>[];
  _runs(p, styles, base, runs);
  return RichParagraph(
    runs,
    align: pf.align ?? RichAlign.left,
    leftIndent: pf.left ?? 0,
    rightIndent: pf.right ?? 0,
    firstIndent: pf.first ?? 0,
    spaceBefore: pf.before ?? 0,
    spaceAfter: pf.after ?? 0,
    shading: pf.shading,
    style: chain.isEmpty ? null : chain.last.name,
  );
}

void _runs(XmlElement x, _Styles styles, _RunFmt base, List<RichRun> out) {
  for (final e in x.childElements) {
    switch (e.name.local) {
      case 'r':
        _run(e, styles, base, out);
      case 'hyperlink' ||
          'ins' ||
          'smartTag' ||
          'fldSimple' ||
          'customXml' ||
          'bdo' ||
          'dir':
        _runs(e, styles, base, out);
      case 'sdt':
        final content = child(e, 'sdtContent');
        if (content != null) _runs(content, styles, base, out);
    }
  }
}

void _run(XmlElement r, _Styles styles, _RunFmt base, List<RichRun> out) {
  final f = base.copy();
  final rpr = child(r, 'rPr');
  if (rpr != null) {
    final cs = child(rpr, 'rStyle');
    if (cs != null) {
      for (final s in styles.chain(attr(cs, 'val'))) {
        f.apply(s.run);
      }
    }
    f.apply(_runFmt(rpr));
  }
  if (f.hidden ?? false) return;
  final text = StringBuffer();
  for (final e in r.childElements) {
    switch (e.name.local) {
      case 't':
        text.write(e.innerText);
      case 'tab' || 'ptab':
        text.write('\t');
      case 'br' || 'cr':
        text.write('\n');
      case 'noBreakHyphen':
        text.write('\u{2011}');
      case 'softHyphen':
        break;
      case 'sym':
        final ch = int.tryParse(attr(e, 'char') ?? '', radix: 16);
        if (ch != null) text.writeCharCode(ch >= 0xf000 ? ch - 0xf000 : ch);
    }
  }
  if (text.isEmpty) return;
  out.add(
    RichRun(
      text.toString(),
      bold: f.b ?? false,
      italic: f.i ?? false,
      underline: f.u ?? false,
      strike: f.s ?? false,
      superscript: f.vert == 'superscript',
      subscript: f.vert == 'subscript',
      fontSize: f.size,
      color: f.color,
      highlight: f.highlight,
      font: f.font,
    ),
  );
}
