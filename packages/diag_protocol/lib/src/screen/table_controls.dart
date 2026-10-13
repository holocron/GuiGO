/// Classic dynpro TABLE CONTROLS (step loops) — the 18/9/<sid> DYNT family
/// that paints a control's catalog and its visible lines: 18/9/14
/// TABLE_HEADER, 18/9/13 column names, 18/9/21 column tooltips (titles),
/// 18/9/17 per-line column attribute records, 18/9/5 line heads and 18/9/8
/// per-line value buffers. Their cells are never DyntAtoms, so the atom
/// fold cannot see them.
///
/// Port of the reference client's
/// (`parse_table_controls` / `_parse_scan_item`, `_table_header_fields`,
/// `_table_header_widths`, `_decode_row_buffers`, `_line_attr_record`)
/// plus the screen geometry of (`_tc_header_rows`,
/// `tc_line_focus`'s cell column = left + selector + preceding widths).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../codepages.dart';

/// One classic table control painted in a window.
class TableControlInfo {
  TableControlInfo({
    required this.name,
    required this.row,
    required this.col,
    required this.width,
    required this.height,
    required this.visibleRows,
    required this.headerRows,
    required this.columns,
    required this.titles,
    required this.widths,
    required this.columnOffsets,
    required this.hasSelectionColumn,
    required this.rows,
    this.title = '',
    this.headings = const [],
    this.headingTips = const [],
    this.fixedCols = 0,
    this.container,
    this.headerRaw,
    this.controlArea,
    this.scrollGeometry,
    this.routing = const [],
    this.tabstripRouting = const [],
    this.treeNames,
    this.tabPages,
  });

  /// The control's name (the 16/10/6 NAME before its items, e.g. `SINGLE`).
  final String name;

  /// The control's top-left cell, WINDOW-relative and absolute (every
  /// enclosing container's origin applied — SINGLE sits at r3c1 of the
  /// SAPLALDB/3000 popup, inside TAB_STRIP r1c0 > SCREEN_HEADER r3c1).
  final int row;
  final int col;

  /// The control's screen extent in cells (the 16/10/5 TABLE geometry):
  /// the header row(s), the data lines and the horizontal-scroll row.
  final int width;
  final int height;
  int get cols => width;

  /// Number of painted data lines (the 18/9/5 line heads of the paint; the
  /// header's own visible-row byte when the paint carries no line).
  final int visibleRows;

  /// Chrome rows above line 1 (column headings / title bar):
  /// `height - visibleRows - 1` (reference client raw_tabline._tc_header_rows).
  final int headerRows;

  /// Absolute row of visible line [line] (1-based).
  int lineRow(int line) => row + headerRows + (line - 1);

  /// The column catalog (18/9/13): dynpro field names in display order.
  final List<String> columns;

  /// Per-column titles (18/9/21 DefaultTooltip; '' where none).
  final List<String> titles;

  /// The control's title bar text (the header row above the headings on a
  /// control with two chrome rows), '' when it declares none.
  final String title;

  /// Per-column HEADINGS as the control paints them over its columns (the
  /// 18/9/14 header's title strings: "Pos", "I", "UA" on ME21N's TC_1211,
  /// where [titles] holds the long DDIC texts), a quick-info-only token
  /// split off into [headingTips]. Empty when the header carries none.
  final List<String> headings;
  final List<String> headingTips;

  /// The leading columns that stay put when the control scrolls
  /// horizontally (18/9/14 byte 16, TC_FIXCOL; 3 on TC_1211).
  final int fixedCols;

  /// Per-column display widths (18/9/14), empty when undecodable.
  final List<int> widths;

  /// Per-column ABSOLUTE start column (control col + selector column +
  /// the preceding widths).
  final List<int> columnOffsets;

  /// The control declares a line-selector column (drawn at [col]).
  final bool hasSelectionColumn;

  /// Decoded cell values per painted line, in line order (index 0 = line
  /// 1). A pushbutton cell reads its function code (reference client convention).
  final List<List<String>> rows;

  /// The innermost enclosing container the control is declared in.
  final String? container;

  // --- the TABLE-plane pieces a cell write echoes (reference client
  // raw_tabline._windows_tc_plane_items) -------------------------------------

  /// The painted 18/9/14 TABLE_HEADER, verbatim (latest paint).
  final Uint8List? headerRaw;

  /// The painted 18/12/2 control-area descriptor right after the header,
  /// verbatim — the client echoes it as 16/12/2 (its first u32 is the
  /// server's line count: 8 on the empty SINGLE popup, 9 after line 1).
  final Uint8List? controlArea;

  /// The first 16/12/6 of the frame (window) that painted the header — the
  /// window's own scroll geometry the cell write sends back verbatim
  /// (reference client screen_tablecontrol._apply_table_header `scroll_geometry`).
  final Uint8List? scrollGeometry;

  /// The control's container group as painted: the 16/10/<sid> legs from
  /// the group's 16/10/1 OPEN to its 16/10/5 CL5 close (16/10/6 names
  /// excluded), with any 16/12/6 the server declared right after a 16/10/9
  /// page leg kept in place (reference client diag_container_tree Container.routing +
  /// geom_after). SINGLE on SAPLALDB/3000: 1, 8, 9, 12/6, 5.
  final List<TcPlaneItem> routing;

  /// The window's (last) tabstrip tree-names item: the 16/10 legs of the
  /// group it follows, its painted 18/9/15 and the 18/9/16 pages descriptor
  /// right after it (reference client ContainerTree.tree_names_group / _item,
  /// raw_tabline._tabstrip_pages_after). Empty / null without a tabstrip.
  final List<TcPlaneItem> tabstripRouting;
  final Uint8List? treeNames;
  final Uint8List? tabPages;

  /// The 16/9/11 container path of a cursor on this control: byte 0 of every
  /// routing leg after the root OPEN, the CL5 included (reference client
  /// mode_envelope.tc_cursor_geometry) — `01 02 01` for SINGLE.
  List<int> get focusPath => [
    for (final leg in routing.skip(1))
      if (leg.id == 10 &&
          tcRoutingSids.contains(leg.sid) &&
          leg.value.isNotEmpty)
        leg.value[0],
  ];

  @override
  String toString() =>
      'TableControlInfo($name r${row}c$col ${width}x$height, $visibleRows '
      'lines, header $headerRows, columns $columns, titles $titles, '
      'widths $widths)';
}

/// One painted item of a table control's TABLE plane: a 16/10/<sid>
/// container leg (id 10) or a 16/12/6 geometry declared inside the chain
/// (id 12, sid 6).
class TcPlaneItem {
  const TcPlaneItem(this.id, this.sid, this.value);
  final int id;
  final int sid;
  final Uint8List value;
}

/// The 16/10 sids a cursor path counts (reference client mode_envelope._ROUTING_SIDS).
const Set<int> tcRoutingSids = {1, 3, 5, 8, 9, 10, 13, 14};

/// One decoded 18/9/8 cell.
class TcCell {
  TcCell(this.kind, this.value, {this.fcode, this.buttonText, this.maxlen});

  /// 'text' | 'checkbox' | 'listbox' | 'pushbutton'
  final String kind;
  final String value;
  final String? fcode;
  final String? buttonText;
  final int? maxlen;
}

/// The 18/9/14 TABLE_HEADER fixed-prefix scalars
/// (reference client screen_tablecontrol._table_header_fields).
class TcHeader {
  TcHeader({
    required this.n,
    required this.width,
    required this.capacityRows,
    required this.visibleRows,
    required this.fixedCols,
    required this.hasSelectionColumn,
    required this.columnHeading,
    required this.widths,
    this.title = '',
    this.headings = const [],
    this.headingTips = const [],
  });
  final int n;
  final int width; // bytes 6..7
  final int capacityRows; // bytes 8..9 (the control height)
  final int visibleRows; // byte 14
  final int fixedCols; // byte 16 (TC_FIXCOL)
  final bool hasSelectionColumn; // byte 20 == 1 or byte 19 & 0x04
  final bool columnHeading; // byte 35 bit 0 (TC_HEADER)
  final List<int>? widths;
  final String title; // the title bar text after the widths
  final List<String> headings; // then one heading per column
  final List<String> headingTips;
}

const int _thNameBlockEnd = 130; // 60 prefix + 40 program + 30 control name
const int _thMaxCols = 512;
const int _thMaxWidth = 1024;

int _u16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];

TcHeader? parseTableHeader(Uint8List b) {
  if (b.length < _thNameBlockEnd) return null;
  final n = b[12];
  if (n < 1 || n > _thMaxCols) return null;
  final hasSel =
      (b.length > 20 && b[20] == 1) || (b.length > 19 && b[19] & 0x04 != 0);
  final located = _headerWidths(b, n);
  final heads = located == null
      ? null
      : _headerHeadings(b, n, located.$2 + 2 * n);
  return TcHeader(
    n: n,
    width: _u16(b, 6),
    capacityRows: _u16(b, 8),
    visibleRows: b[14],
    fixedCols: b[16],
    hasSelectionColumn: hasSel,
    columnHeading: b.length > 35 && b[35] & 0x01 != 0,
    widths: located?.$1,
    title: heads?.$1 ?? '',
    headings: heads?.$2 ?? const [],
    headingTips: heads?.$3 ?? const [],
  );
}

bool _indexArrayAt(Uint8List b, int n, int off) {
  if (off + 2 * n > b.length) return false;
  for (var i = 0; i < n; i++) {
    if (_u16(b, off + 2 * i) != i + 1) return false;
  }
  return true;
}

/// Whether an [_indexArrayAt] array starts at some offset in [from]..[to]
/// — in ONE pass per byte parity (audit #15: a probe per offset re-read
/// up to n words each, quadratic on a hostile header). The words 1, 2, …,
/// n are distinct, so a broken run can only restart on a word 1.
bool _indexArrayIn(Uint8List b, int n, int from, int to) {
  if (n <= 0) return from <= to && from <= b.length;
  for (var parity = 0; parity < 2; parity++) {
    var run = 0; // words 1..run matched, ending before off
    for (var off = from + parity; off + 2 <= b.length; off += 2) {
      final w = _u16(b, off);
      run = w == run + 1 ? run + 1 : (w == 1 ? 1 : 0);
      if (run == n) {
        if (off - 2 * (n - 1) <= to) return true;
        break; // later starts lie further right
      }
      if (run == 0 && off > to) break; // no run can still start in range
    }
  }
  return false;
}

/// reference client _table_header_widths: the widths the header's own prefix
/// offsets locate (bytes 17..18 index array, 29..30 widths, 25..26 n);
/// the text-run fallback when they do not validate. Null (fail loud) for
/// anything else. With the widths' own offset: the title strings follow.
(List<int>, int)? _headerWidths(Uint8List b, int n) {
  if (_thNameBlockEnd + 2 * n > b.length) return null;
  int? wStart;
  final idxOff = _u16(b, 17), wOff = _u16(b, 29), nAgain = _u16(b, 25);
  if (nAgain == n &&
      idxOff >= _thNameBlockEnd &&
      wOff >= idxOff + 2 * n &&
      wOff + 2 * n <= b.length &&
      _indexArrayAt(b, n, idxOff)) {
    wStart = wOff;
  } else {
    // FALLBACK: the widths sit right before the first printable text run
    int? title;
    for (var i = _thNameBlockEnd; i + 1 < b.length; i++) {
      if (b[i] >= 0x20 &&
          b[i] <= 0x7e &&
          b[i + 1] >= 0x20 &&
          b[i + 1] <= 0x7e) {
        title = i;
        break;
      }
    }
    if (title == null) return null;
    wStart = title - 2 * n;
    if (wStart < _thNameBlockEnd) return null;
    if (!_indexArrayIn(b, n, _thNameBlockEnd, wStart)) return null;
  }
  final widths = [for (var i = 0; i < n; i++) _u16(b, wStart + 2 * i)];
  if (!widths.every((w) => w > 0 && w <= _thMaxWidth)) return null;
  return (widths, wStart);
}

/// The token a heading may lead with: an icon code and / or a quick info
/// (`@\QPoste@Pos`, `@1F\QSélection@Text`).
final _headingTip = RegExp(r'^@([0-9A-Z]{0,2})(?:\\Q([^@]*))?@');

/// The NUL-terminated strings of [b] from [start] (to [count] of them, or
/// to the end).
List<String> _cStrings(Uint8List b, int start, {int? count}) {
  final strs = <String>[];
  var s = start;
  for (var i = start; i < b.length; i++) {
    if (b[i] != 0) continue;
    strs.add(wireDecode(Uint8List.sublistView(b, s, i)).trimRight());
    s = i + 1;
    if (count != null && strs.length == count) return strs;
  }
  if (s < b.length && count == null) {
    strs.add(wireDecode(Uint8List.sublistView(b, s)).trimRight());
  }
  return strs;
}

(String, List<String>, List<String>) _splitHeadings(
  String title,
  List<String> strs,
) {
  final texts = <String>[], tips = <String>[];
  for (final raw in strs) {
    final tip = _headingTip.firstMatch(raw);
    // a quick-info-only token goes to the tooltip; an icon token stays (its
    // glyph is the heading)
    final iconless = tip != null && (tip.group(1) ?? '').isEmpty;
    texts.add(iconless ? raw.substring(tip.end).trim() : raw.trim());
    tips.add(tip?.group(2)?.trim() ?? '');
  }
  return (title, texts, tips);
}

/// The header's title and headings. The 60-byte prefix locates them (the
/// reference client's 0432777, verified on its 63 distinct headers; jar platinr3S
/// GuiTableControl getTableTitle / setColumnTitleAt): bytes 48..49 = the
/// offset of the TITLE string (NUL-terminated, 0 = no title bar), bytes
/// 50..51 = the offset of the HEADINGS block (exactly n NUL-terminated
/// strings, 0 = no heading row). TC_1211: `Statut`, `@\QPoste@Pos`, …;
/// TCTRL_V_ICON: `Gestion des icones` then its 14; TC_CONT / TC_BIN_EXP a
/// title only; OBJTYPES_TABCNTRL / TC_BIN_IMP neither. Headers whose
/// offsets do not validate fall back to the strings after the widths
/// ([start]): n + 1 = title + headings, n = headings, a lone string over
/// several columns = a title only. Null for anything else.
(String, List<String>, List<String>)? _headerHeadings(
  Uint8List b,
  int n,
  int start,
) {
  if (b.length >= 52) {
    final tOff = _u16(b, 48), hOff = _u16(b, 50);
    bool ok(int o) => o == 0 || (o >= _thNameBlockEnd && o < b.length);
    if ((tOff != 0 || hOff != 0) && ok(tOff) && ok(hOff)) {
      final title = tOff == 0
          ? ''
          : (_cStrings(b, tOff, count: 1).firstOrNull ?? '').trim();
      if (hOff == 0) return (title, const <String>[], const <String>[]);
      final strs = _cStrings(b, hOff, count: n);
      if (strs.length == n) return _splitHeadings(title, strs);
    }
  }
  if (start > b.length) return null;
  final strs = _cStrings(b, start);
  var title = '';
  if (strs.length == n + 1) {
    title = strs.removeAt(0).trim();
  } else if (strs.length == 1 && n > 1) {
    return (strs.single.trim(), const <String>[], const <String>[]);
  } else if (strs.length != n) {
    return null;
  }
  return _splitHeadings(title, strs);
}

/// 18/9/21: NUL-separated `<Propertybag><DefaultTooltip>TEXT</…>` blocks,
/// one per column (reference client _grid_tooltips).
List<String> parseTcTooltips(Uint8List raw) {
  final re = _parseTcTooltipsRx;
  return [
    for (final chunk in utf8.decode(raw, allowMalformed: true).split('\x00'))
      _htmlUnescape(re.firstMatch(chunk)?.group(1) ?? ''),
  ];
}

String _htmlUnescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

/// 18/9/17: one record per painted line, n x 9-byte cells
/// `[0][line][etype][?][line][0][ATTR][flags][0]` — (line, etypes, attrs).
(int, List<int>, List<int>)? parseTcLineAttrs(Uint8List b) {
  if (b.isEmpty || b.length % 9 != 0) return null;
  final n = b.length ~/ 9;
  return (
    b[1],
    [for (var i = 0; i < n; i++) b[i * 9 + 2]],
    [for (var i = 0; i < n; i++) b[i * 9 + 6]],
  );
}

bool _isDigits(Uint8List t) =>
    t.isNotEmpty && t.every((c) => c >= 0x30 && c <= 0x39);

String _str(Uint8List t) => utf8.decode(t, allowMalformed: true);

/// Decode ONE 18/9/8 per-line value buffer into [ncols] cells, or null when
/// the token walk does not consume the buffer exactly (never sliced by
/// guess). Port of reference client _decode_row_buffers: a run of NUL-terminated
/// strings walked column by column — TEXT = value + two numeric attribute
/// tokens (the second-to-last is the cell's length), CHECKBOX = state + one
/// empty token, LISTBOX = `\x01` + binding + '' + value + width, PUSHBUTTON
/// = fcode + text.
List<TcCell>? decodeTcRowBuffer(Uint8List buf, int ncols) {
  final toks = <Uint8List>[];
  var s = 0;
  for (var i = 0; i < buf.length; i++) {
    if (buf[i] == 0) {
      toks.add(Uint8List.sublistView(buf, s, i));
      s = i + 1;
    }
  }
  toks.add(Uint8List.sublistView(buf, s)); // python split's last piece
  if (toks.isNotEmpty && toks.last.isEmpty) toks.removeLast();

  final row = <TcCell>[];
  var pos = 0;
  for (var ci = 0; ci < ncols; ci++) {
    if (pos >= toks.length) return null;
    final v = toks[pos];
    Uint8List? at(int k) => pos + k < toks.length ? toks[pos + k] : null;
    if (v.length == 1 && v[0] == 0x01) {
      final nxt = at(1) ?? Uint8List(0);
      if (nxt.isEmpty) {
        row.add(TcCell('checkbox', 'X'));
        pos += 2;
      } else {
        if (pos + 3 >= toks.length) return null;
        row.add(TcCell('listbox', _str(toks[pos + 3]).trim()));
        pos += 5;
      }
      continue;
    }
    final nxt = at(1), nxt2 = at(2);
    if (nxt != null && nxt2 != null && _isDigits(nxt) && _isDigits(nxt2)) {
      row.add(
        TcCell(
          'text',
          _str(v).trimRight(),
          maxlen: int.tryParse(ascii.decode(nxt)),
        ),
      );
      pos += 3;
    } else if (nxt != null &&
        nxt2 != null &&
        v.isEmpty &&
        nxt.isEmpty &&
        nxt2.isEmpty) {
      row.add(TcCell('text', '')); // empty text / unchecked (java)
      pos += 3;
    } else if (nxt != null && nxt.isEmpty) {
      final st = _str(v).trim();
      row.add(TcCell('checkbox', st == '\x01' || st == 'X' ? 'X' : ''));
      pos += 2;
    } else if (nxt != null &&
        v.isNotEmpty &&
        v[0] == 0x3d /* = */ &&
        !_isDigits(nxt)) {
      final fc = _str(v).trim();
      row.add(
        TcCell('pushbutton', fc, fcode: fc, buttonText: _str(nxt).trimRight()),
      );
      pos += 2;
    } else {
      row.add(TcCell('text', _str(v).trimRight()));
      pos += 3;
    }
  }
  if (pos == toks.length || pos == toks.length + 1) return row;
  return null;
}

/// The running state of one control while a window's items are folded.
class TcBuilder {
  TcBuilder(this.name);
  final String name;
  String? container;
  int? absTop, absLeft, width, height; // from the TABLE path level
  List<String> columns = [];
  List<String> titles = [];
  TcHeader? header;
  final Map<int, List<int>> lineEtypes = {};
  final Map<int, List<int>> lineAttrs = {};
  final Map<int, List<TcCell>> cellsByLine = {}; // latest paint per line
  final Map<int, int> lineTypes = {};
  int maxLinesPerPaint = 0;
  int linesThisPaint = 0;
  Uint8List? headerRaw, controlArea, scrollGeometry;
  List<TcPlaneItem> routing = const [];
  List<TcPlaneItem> tabstripRouting = const [];
  Uint8List? treeNames, tabPages;
  final List<int> pendingLines = [];
  int buffersThisPaint = 0;

  /// Every frame restarts the per-paint line count (reference client: visible rows =
  /// the max 18/9/5 count across paints).
  void endPaint() {
    if (linesThisPaint > maxLinesPerPaint) maxLinesPerPaint = linesThisPaint;
    linesThisPaint = 0;
    buffersThisPaint = 0;
    pendingLines.clear();
  }

  void lineHead(Uint8List v) {
    linesThisPaint++;
    if (v.length >= 2) {
      final line = _u16(v, 0);
      pendingLines.add(line);
      if (v.length >= 4) lineTypes[line] = _u16(v, 2);
    }
  }

  void rowBuffer(Uint8List v) {
    buffersThisPaint++;
    final line = pendingLines.isNotEmpty
        ? pendingLines.removeAt(0)
        : buffersThisPaint;
    _rawByLine[line] = Uint8List.fromList(v);
  }

  final Map<int, Uint8List> _rawByLine = {};

  void lineAttrRecord(Uint8List v) {
    final r = parseTcLineAttrs(v);
    if (r == null) return;
    lineEtypes[r.$1] = r.$2;
    lineAttrs[r.$1] = r.$3;
  }

  /// The per-line record of [line], else the nearest earlier painted one,
  /// else the first (reference client column_etype / column_protected).
  List<int>? recordFor(Map<int, List<int>> recs, int line) {
    if (recs.isEmpty) return null;
    // one pass, no sorted key copy per painted line (audit #10): the
    // greatest line <= [line], else the smallest
    int? below, first;
    for (final l in recs.keys) {
      if (first == null || l < first) first = l;
      if (l <= line && (below == null || l > below)) below = l;
    }
    return recs[below ?? first];
  }

  /// Decode the buffers once the catalog is known.
  void decodeRows() {
    if (columns.isEmpty) return;
    for (final e in _rawByLine.entries) {
      final cells = decodeTcRowBuffer(e.value, columns.length);
      if (cells != null) cellsByLine[e.key] = cells;
    }
    _rawByLine.clear();
  }

  TableControlInfo build() {
    endPaint();
    decodeRows();
    final h = header;
    final lines = maxLinesPerPaint > 0
        ? maxLinesPerPaint
        : (h?.visibleRows ?? cellsByLine.length);
    final ht = height ?? h?.capacityRows ?? 0;
    final wd = width ?? h?.width ?? 0;
    var chrome = 1;
    if (ht > 0 && lines > 0 && ht - lines - 1 >= 0) {
      chrome = ht - lines - 1;
      if (chrome == 0 && (h?.columnHeading ?? false)) chrome = 1;
    }
    final widths = h?.widths ?? const <int>[];
    final sel = (h?.hasSelectionColumn ?? false) ? 1 : 0;
    final left = absLeft ?? 0;
    final offsets = <int>[];
    var acc = left + sel;
    for (var i = 0; i < columns.length; i++) {
      offsets.add(acc);
      acc += i < widths.length ? widths[i] : 0;
    }
    final sortedLines = cellsByLine.keys.toList()..sort();
    return TableControlInfo(
      name: name,
      row: absTop ?? 0,
      col: left,
      width: wd,
      height: ht,
      visibleRows: lines,
      headerRows: chrome,
      columns: List.unmodifiable(columns),
      titles: List.unmodifiable([
        for (var i = 0; i < columns.length; i++)
          i < titles.length ? titles[i] : '',
      ]),
      widths: List.unmodifiable(widths),
      columnOffsets: List.unmodifiable(offsets),
      hasSelectionColumn: sel == 1,
      title: h?.title ?? '',
      headings: List.unmodifiable(h?.headings ?? const <String>[]),
      headingTips: List.unmodifiable(h?.headingTips ?? const <String>[]),
      fixedCols: h?.fixedCols ?? 0,
      rows: List.unmodifiable([
        for (final l in sortedLines)
          List<String>.unmodifiable(cellsByLine[l]!.map((c) => c.value)),
      ]),
      container: container,
      headerRaw: headerRaw,
      controlArea: controlArea,
      scrollGeometry: scrollGeometry,
      routing: List.unmodifiable(routing),
      tabstripRouting: List.unmodifiable(tabstripRouting),
      treeNames: treeNames,
      tabPages: tabPages,
    );
  }
}

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call (audit #7 / zcode P-12).
final RegExp _parseTcTooltipsRx = RegExp(r'<DefaultTooltip>(.*?)</DefaultTooltip>', dotAll: true);
