/// An RTF subset reader: enough for the SAPscript / SmartForms Word editor
/// (SO10, SE71, SMARTFORMS text nodes) and ordinary Word RTF — paragraphs,
/// runs (bold / italic / underline / strike / super- and subscript / size /
/// colour / highlight / font), tabs, line breaks, paragraph alignment,
/// indents, spacing and shading, `\uN` Unicode with its `\ucN` fallback,
/// `\'hh` bytes through the Windows code pages, `\upr`/`\ud` (the Unicode
/// twin is read, the ANSI one skipped), style names, simple tables
/// (`\trowd \cellx \intbl \cell \row`), field results, hidden text skipped.
///
/// Pictures, objects, headers/footers, footnotes, field instructions and
/// every ignorable (`\*`) destination it does not know are skipped.
library;

import 'dart:typed_data';

import 'codepages.dart';
import 'rich_text.dart';

/// Reads RTF [bytes] (the document as the server pushed it; bytes after the
/// outermost group's closing brace — padding — are ignored).
RichDocument readRtf(Uint8List bytes) => _RtfReader(bytes).read();

/// [readRtf] over a string whose code units are the RTF's bytes.
RichDocument readRtfString(String rtf) =>
    _RtfReader(Uint8List.fromList([for (final c in rtf.codeUnits) c & 0xff]))
        .read();

/// Whether [bytes] start like an RTF document (`{\rtf`).
bool looksLikeRtf(Uint8List bytes) {
  var i = 0;
  while (i < bytes.length && i < 8 && _isSpace(bytes[i])) {
    i++;
  }
  const sig = [0x7b, 0x5c, 0x72, 0x74, 0x66]; // {\rtf
  if (bytes.length - i < sig.length) return false;
  for (var k = 0; k < sig.length; k++) {
    if (bytes[i + k] != sig[k]) return false;
  }
  return true;
}

bool _isSpace(int c) => c == 0x20 || c == 0x0a || c == 0x0d || c == 0x09;

enum _Dest { normal, skip, fontTable, colorTable, styleSheet, upr, title }

typedef _Char = ({
  bool b,
  bool i,
  bool u,
  bool s,
  bool sup,
  bool sub,
  int fs,
  int cf,
  int hl,
  int f,
  bool hidden,
});

class _Para {
  _Para();
  RichAlign align = RichAlign.left;
  int li = 0, ri = 0, fi = 0, sb = 0, sa = 0;
  int shading = 0; // \cbpat colour index
  int? style;
  bool inTable = false;

  _Para copy() => _Para()
    ..align = align
    ..li = li
    ..ri = ri
    ..fi = fi
    ..sb = sb
    ..sa = sa
    ..shading = shading
    ..style = style
    ..inTable = inTable;
}

class _Group {
  _Group(this.dest, this.ch, this.para, this.uc);
  _Dest dest;
  _Char ch;
  _Para para;
  int uc;

  /// `\upr`: the first child group (the ANSI twin) is skipped.
  int children = 0;

  _Group copy() => _Group(dest, ch, para.copy(), uc);
}

class _Font {
  String name = '';
  int? codepage;
}

class _RtfReader {
  _RtfReader(this.src);

  final Uint8List src;
  int pos = 0;

  static const _Char _plain = (
    b: false,
    i: false,
    u: false,
    s: false,
    sup: false,
    sub: false,
    fs: 24,
    cf: 0,
    hl: 0,
    f: -1,
    hidden: false,
  );

  int codepage = 1252;
  int defaultFont = -1;
  final Map<int, _Font> fonts = {};
  final List<int?> colors = [];
  final Map<int, String> styles = {};
  String? title;

  // font / colour / style table entry under construction
  int _fontId = -1;
  int? _fontCharset;
  final StringBuffer _entryText = StringBuffer();
  int _red = 0, _green = 0, _blue = 0;
  bool _colorSet = false;
  int? _styleId;

  final List<_Group> stack = [];
  late _Group g;

  // output
  final List<RichBlock> blocks = [];
  final List<RichRun> runs = [];
  final StringBuffer text = StringBuffer();
  _Char? textCh;
  int skipChars = 0; // \uN fallback still to skip

  // table under construction
  final List<List<RichTableCell>> tableRows = [];
  List<RichTableCell> rowCells = [];
  final List<RichParagraph> cellParas = [];
  final List<int> cellx = [];
  bool _cellDirty = false;

  RichDocument read() {
    g = _Group(_Dest.normal, _plain, _Para(), 1);
    var depth = 0;
    var started = false;
    while (pos < src.length) {
      final c = src[pos];
      if (c == 0x7b) {
        // {
        pos++;
        final parent = g;
        stack.add(parent);
        g = parent.copy();
        skipChars = 0;
        if (parent.dest == _Dest.upr) {
          if (parent.children++ == 0) g.dest = _Dest.skip;
        }
        depth++;
        started = true;
      } else if (c == 0x7d) {
        // }
        pos++;
        _endGroup();
        skipChars = 0;
        if (stack.isEmpty) break;
        g = stack.removeLast();
        depth--;
        if (started && depth == 0) break; // the document's closing brace
      } else if (c == 0x5c) {
        pos++;
        _control();
      } else if (c == 0x0d || c == 0x0a) {
        pos++; // source line breaks are not text
      } else {
        pos++;
        if (skipChars > 0) {
          skipChars--;
          continue;
        }
        _text(
          c >= 0x80 ? decodeAnsiByte(c, _codepage()) : String.fromCharCode(c),
        );
      }
    }
    _finish();
    return RichDocument(blocks, title: title);
  }

  int _codepage() {
    final f = fonts[g.ch.f < 0 ? defaultFont : g.ch.f];
    return f?.codepage ?? codepage;
  }

  void _endGroup() {
    switch (g.dest) {
      case _Dest.fontTable:
        _endFontEntry();
      case _Dest.styleSheet:
        _endStyleEntry();
      case _Dest.title:
        title = _entryText.toString().trim();
        _entryText.clear();
      default:
    }
  }

  // --- control words -----------------------------------------------------

  void _control() {
    if (pos >= src.length) return;
    final c = src[pos];
    if (!_isAlpha(c)) {
      pos++;
      switch (c) {
        case 0x27: // \'hh
          final h = pos + 2 <= src.length
              ? int.tryParse(String.fromCharCodes(src, pos, pos + 2), radix: 16)
              : null;
          pos += 2;
          if (h == null) return;
          if (skipChars > 0) {
            skipChars--;
            return;
          }
          _text(decodeAnsiByte(h, _codepage()));
        case 0x2a: // \* — ignorable destination unless the word is known
          _ignorable();
        case 0x7e: // \~
          _text('\u{a0}');
        case 0x5f: // \_
          _text('\u{2011}');
        case 0x2d: // \- optional hyphen
          break;
        case 0x0a || 0x0d: // \<newline> = \par
          _word('par', null);
        case 0x09:
          _word('tab', null);
        default: // \\ \{ \} and anything else literally
          if (skipChars > 0) {
            skipChars--;
            return;
          }
          _text(String.fromCharCode(c));
      }
      return;
    }
    final (word, param) = _readWord();
    _word(word, param);
  }

  (String, int?) _readWord() {
    final start = pos;
    while (pos < src.length && _isAlpha(src[pos])) {
      pos++;
    }
    final word = String.fromCharCodes(src, start, pos);
    int? param;
    if (pos < src.length && (src[pos] == 0x2d || _isDigit(src[pos]))) {
      final ps = pos;
      pos++;
      while (pos < src.length && _isDigit(src[pos]) && pos - ps < 11) {
        pos++;
      }
      param = int.tryParse(String.fromCharCodes(src, ps, pos));
    }
    if (pos < src.length && src[pos] == 0x20) pos++; // the delimiter
    return (word, param);
  }

  void _ignorable() {
    // look at the next control word without consuming anything else
    while (pos < src.length && _isSpace(src[pos])) {
      pos++;
    }
    if (pos < src.length && src[pos] == 0x5c) {
      final save = pos;
      pos++;
      if (pos < src.length && _isAlpha(src[pos])) {
        final (word, param) = _readWord();
        // known words a writer may still star: the Unicode twin of \upr,
        // style definitions (SAPscript's stylesheet stars \s and \cs)
        const known = {
          'ud',
          's',
          'cs',
          'ds',
          'ts',
          'listtext',
          'pntext',
          'fldrslt',
        };
        if (known.contains(word)) {
          if (word == 'ud') {
            g.dest = _Dest.normal;
          } else {
            _word(word, param);
          }
          return;
        }
      }
      pos = save;
    }
    g.dest = _Dest.skip;
  }

  static const _skipDestinations = {
    'pict',
    'object',
    'objdata',
    'result',
    'fldinst',
    'header',
    'headerl',
    'headerr',
    'headerf',
    'footer',
    'footerl',
    'footerr',
    'footerf',
    'footnote',
    'annotation',
    'atnid',
    'atnauthor',
    'xe',
    'tc',
    'txe',
    'rxe',
    'bkmkstart',
    'bkmkend',
    'themedata',
    'colorschememapping',
    'latentstyles',
    'datastore',
    'xmlnstbl',
    'listtable',
    'listoverridetable',
    'rsidtbl',
    'generator',
    'revtbl',
    'filetbl',
    'pgdsctbl',
    'mmathPr',
    'pn',
    'nonshppict',
    'shp',
    'shpinst',
    'private',
    'template',
    'docvar',
    'userprops',
    'author',
    'operator',
    'company',
    'subject',
    'keywords',
    'comment',
    'doccomm',
    'creatim',
    'revtim',
    'printim',
    'buptim',
    'falt',
    'panose',
    'fname',
    'stylesheet0',
    'wgrffmtfilter',
    'defchp',
    'defpap',
    'protusertbl',
    'ftnsep',
    'ftnsepc',
    'aftnsep',
    'aftnsepc',
    'aftncn',
    'ftncn',
    'oleclsid',
    'blipuid',
    'background',
    'passwordhash',
    'formfield',
    'datafield',
  };

  void _word(String w, int? p) {
    final dest = g.dest;
    if (dest == _Dest.skip) {
      if (w == 'bin') _skipBin(p);
      return;
    }
    if (_skipDestinations.contains(w)) {
      g.dest = _Dest.skip;
      return;
    }
    switch (w) {
      case 'fonttbl':
        g.dest = _Dest.fontTable;
        return;
      case 'colortbl':
        g.dest = _Dest.colorTable;
        return;
      case 'stylesheet':
        g.dest = _Dest.styleSheet;
        return;
      case 'upr':
        g.dest = _Dest.upr;
        g.children = 0;
        return;
      case 'info':
        g.dest = _Dest.skip; // \title is read below when it comes first
        _infoTitle();
        return;
      case 'title':
        g.dest = _Dest.title;
        _entryText.clear();
        return;
      case 'bin':
        _skipBin(p);
        return;
      case 'ansicpg':
        if (p != null && p > 0) codepage = p;
        return;
      case 'deff':
        defaultFont = p ?? -1;
        return;
      case 'uc':
        g.uc = (p ?? 1).clamp(0, 8);
        return;
      case 'u':
        if (p == null) return;
        final cu = p < 0 ? p + 65536 : p;
        if (dest == _Dest.normal ||
            dest == _Dest.title ||
            dest == _Dest.fontTable ||
            dest == _Dest.styleSheet) {
          _text(String.fromCharCode(cu & 0xffff), keepSkip: true);
        }
        skipChars = g.uc;
        return;
    }
    switch (dest) {
      case _Dest.fontTable:
        _fontWord(w, p);
        return;
      case _Dest.colorTable:
        _colorWord(w, p);
        return;
      case _Dest.styleSheet:
        _styleWord(w, p);
        return;
      case _Dest.upr || _Dest.title:
        return;
      default:
    }
    _formatWord(w, p);
  }

  void _infoTitle() {
    // \info's groups are skipped as a whole except a leading {\title …}:
    // scan ahead (bounded) for it
    final end = src.length < pos + 4096 ? src.length : pos + 4096;
    final s = String.fromCharCodes(src, pos, end);
    final m = RegExp(r'\{\\title ([^{}\\]*)\}').firstMatch(s);
    if (m != null && m.group(1)!.trim().isNotEmpty) title = m.group(1)!.trim();
  }

  void _skipBin(int? n) {
    if (n != null && n > 0) pos = (pos + n).clamp(0, src.length);
  }

  void _formatWord(String w, int? p) {
    final ch = g.ch;
    bool on() => p == null || p != 0;
    switch (w) {
      // paragraphs, breaks, tables
      case 'par' || 'sect' || 'page':
        _endParagraph();
      case 'line':
        _text('\n');
      case 'tab':
        _text('\t');
      case 'cell' || 'nestcell':
        _endCell();
      case 'row' || 'nestrow':
        _endRow();
      case 'trowd':
        cellx.clear();
      case 'cellx':
        if (p != null) cellx.add(p);
      case 'intbl':
        g.para.inTable = true;
      case 'itap':
        g.para.inTable = (p ?? 0) > 0;
      case 'pard':
        g.para = _Para();
      case 'plain':
        g.ch = _plain;
      case 's':
        g.para.style = p;
      case 'ql':
        g.para.align = RichAlign.left;
      case 'qc':
        g.para.align = RichAlign.center;
      case 'qr':
        g.para.align = RichAlign.right;
      case 'qj' || 'qd':
        g.para.align = RichAlign.justify;
      case 'li':
        g.para.li = p ?? 0;
      case 'ri':
        g.para.ri = p ?? 0;
      case 'fi':
        g.para.fi = p ?? 0;
      case 'sb':
        g.para.sb = p ?? 0;
      case 'sa':
        g.para.sa = p ?? 0;
      case 'cbpat':
        g.para.shading = p ?? 0;
      // characters
      case 'b':
        g.ch = _with(ch, b: on());
      case 'i':
        g.ch = _with(ch, i: on());
      case 'ul' || 'uld' || 'uldb' || 'ulw' || 'uldash' || 'ulth' || 'ulwave':
        g.ch = _with(ch, u: on());
      case 'ulnone':
        g.ch = _with(ch, u: false);
      case 'strike' || 'striked':
        g.ch = _with(ch, s: on());
      case 'super':
        g.ch = _with(ch, sup: true, sub: false);
      case 'sub':
        g.ch = _with(ch, sub: true, sup: false);
      case 'nosupersub':
        g.ch = _with(ch, sup: false, sub: false);
      case 'up':
        g.ch = _with(ch, sup: (p ?? 6) > 0, sub: false);
      case 'dn':
        g.ch = _with(ch, sub: (p ?? 6) > 0, sup: false);
      case 'fs':
        if (p != null && p > 0) g.ch = _with(ch, fs: p);
      case 'cf':
        g.ch = _with(ch, cf: p ?? 0);
      case 'highlight' || 'chcbpat' || 'cb':
        g.ch = _with(ch, hl: p ?? 0);
      case 'f':
        g.ch = _with(ch, f: p ?? -1);
      case 'v':
        g.ch = _with(ch, hidden: on());
      // special characters
      case 'emdash':
        _text('\u{2014}');
      case 'endash':
        _text('\u{2013}');
      case 'bullet':
        _text('\u{2022}');
      case 'lquote':
        _text('\u{2018}');
      case 'rquote':
        _text('\u{2019}');
      case 'ldblquote':
        _text('\u{201c}');
      case 'rdblquote':
        _text('\u{201d}');
      case 'emspace':
        _text('\u{2003}');
      case 'enspace':
        _text('\u{2002}');
      case 'qmspace':
        _text('\u{2005}');
      case 'zwj':
        _text('\u{200d}');
      case 'zwnj':
        _text('\u{200c}');
      default:
    }
  }

  static _Char _with(
    _Char c, {
    bool? b,
    bool? i,
    bool? u,
    bool? s,
    bool? sup,
    bool? sub,
    int? fs,
    int? cf,
    int? hl,
    int? f,
    bool? hidden,
  }) => (
    b: b ?? c.b,
    i: i ?? c.i,
    u: u ?? c.u,
    s: s ?? c.s,
    sup: sup ?? c.sup,
    sub: sub ?? c.sub,
    fs: fs ?? c.fs,
    cf: cf ?? c.cf,
    hl: hl ?? c.hl,
    f: f ?? c.f,
    hidden: hidden ?? c.hidden,
  );

  // --- tables of the header ----------------------------------------------

  void _fontWord(String w, int? p) {
    if (w == 'f') {
      _endFontEntry();
      _fontId = p ?? -1;
      _fontCharset = null;
    } else if (w == 'fcharset') {
      _fontCharset = p;
    } else if (w == 'cpg' && p != null && hasCodepage(p)) {
      _fontCharset = -p; // an explicit code page wins
    }
  }

  void _endFontEntry() {
    if (_fontId < 0) {
      _entryText.clear();
      return;
    }
    final f = fonts.putIfAbsent(_fontId, _Font.new);
    final name = _entryText.toString().replaceAll(';', '').trim();
    if (name.isNotEmpty) f.name = name;
    final cs = _fontCharset;
    if (cs != null) f.codepage = cs < 0 ? -cs : codepageOfCharset(cs);
    _entryText.clear();
    _fontId = -1;
  }

  void _colorWord(String w, int? p) {
    final v = (p ?? 0).clamp(0, 255);
    switch (w) {
      case 'red':
        _red = v;
        _colorSet = true;
      case 'green':
        _green = v;
        _colorSet = true;
      case 'blue':
        _blue = v;
        _colorSet = true;
    }
  }

  void _styleWord(String w, int? p) {
    if (w == 's' || w == 'cs' || w == 'ds' || w == 'ts') {
      _endStyleEntry();
      _styleId = w == 's' ? (p ?? 0) : null;
    } else if (w == 'snext' || w == 'sbasedon') {
      // not the entry's own number
    }
  }

  void _endStyleEntry() {
    final id = _styleId;
    final name = _entryText.toString().replaceAll(';', '').trim();
    if (id != null && name.isNotEmpty) styles[id] = name;
    _entryText.clear();
    _styleId = null;
  }

  // --- text --------------------------------------------------------------

  void _text(String s, {bool keepSkip = false}) {
    if (!keepSkip && skipChars > 0) {
      skipChars--;
      return;
    }
    switch (g.dest) {
      case _Dest.normal:
        break;
      case _Dest.fontTable || _Dest.title:
        _entryText.write(s);
        return;
      case _Dest.styleSheet:
        if (s == ';') {
          _endStyleEntry();
        } else {
          _entryText.write(s);
        }
        return;
      case _Dest.colorTable:
        if (s == ';') {
          colors.add(_colorSet ? (_red << 16) | (_green << 8) | _blue : null);
          _red = _green = _blue = 0;
          _colorSet = false;
        }
        return;
      default:
        return;
    }
    if (g.ch.hidden) return;
    if (textCh != null && textCh != g.ch) _flushRun();
    textCh = g.ch;
    text.write(s);
    if (g.para.inTable) _cellDirty = true;
  }

  void _flushRun() {
    final ch = textCh;
    if (ch == null || text.isEmpty) {
      text.clear();
      return;
    }
    final font = fonts[ch.f < 0 ? defaultFont : ch.f]?.name;
    runs.add(
      RichRun(
        text.toString(),
        bold: ch.b,
        italic: ch.i,
        underline: ch.u,
        strike: ch.s,
        superscript: ch.sup,
        subscript: ch.sub,
        fontSize: ch.fs / 2,
        color: _color(ch.cf),
        highlight: _color(ch.hl),
        font: (font == null || font.isEmpty) ? null : font,
      ),
    );
    text.clear();
  }

  int? _color(int idx) => idx > 0 && idx < colors.length ? colors[idx] : null;

  RichParagraph _paragraph() {
    _flushRun();
    final p = g.para;
    final para = RichParagraph(
      List.of(runs),
      align: p.align,
      leftIndent: p.li / 20,
      rightIndent: p.ri / 20,
      firstIndent: p.fi / 20,
      spaceBefore: p.sb / 20,
      spaceAfter: p.sa / 20,
      shading: _color(p.shading),
      style: p.style == null ? null : styles[p.style!],
    );
    runs.clear();
    textCh = null;
    return para;
  }

  void _endParagraph() {
    final para = _paragraph();
    if (g.para.inTable) {
      cellParas.add(para);
      _cellDirty = true;
    } else {
      _closeTable();
      blocks.add(para);
    }
  }

  void _endCell() {
    final hasText = runs.isNotEmpty || text.isNotEmpty;
    if (hasText || cellParas.isEmpty) cellParas.add(_paragraph());
    final i = rowCells.length;
    double? width;
    if (i < cellx.length) {
      final left = i == 0 ? 0 : cellx[i - 1];
      width = (cellx[i] - left) / 20;
      if (width <= 0) width = null;
    }
    rowCells.add(RichTableCell(List.of(cellParas), width: width));
    cellParas.clear();
    _cellDirty = false;
  }

  void _endRow() {
    if (_cellDirty) _endCell();
    if (rowCells.isNotEmpty) tableRows.add(rowCells);
    rowCells = [];
  }

  void _closeTable() {
    if (_cellDirty) _endCell();
    if (rowCells.isNotEmpty) _endRow();
    if (tableRows.isEmpty) return;
    blocks.add(RichTable(List.of(tableRows)));
    tableRows.clear();
  }

  void _finish() {
    _flushRun();
    final pending = runs.any((r) => r.text.trim().isNotEmpty);
    if (pending) {
      _endParagraph();
    } else {
      runs.clear();
    }
    _closeTable();
  }

  static bool _isAlpha(int c) =>
      (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a);
  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
}
