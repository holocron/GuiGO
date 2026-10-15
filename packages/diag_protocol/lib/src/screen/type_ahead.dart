/// SAP GUI TYPE-AHEAD ("enhanced search"): the field arming, the request
/// okcodes and the proposal table the server pushes back — the pure model
/// half (the request round: session/type_ahead_actions.dart).
///
/// Ground truth = the REAL SAP GUI for Windows (reference client recordings, RAW
/// numbering of their DECODE.md):
/// * a recorded session (SE16/MARA `SAPLSETB/1000`,
/// MATNR-LOW): srv[14] arms `I1-LOW` / `I1-HIGH` with the etype-120
/// XMLPROP `<Propertybag><CustomProperty typeahead="X"/>…`; gui[8] =
/// `%_SEARCH 100`; srv[15] = ONE OLE flush (`AssignProperty2
/// ClipBoardDataTable`, `TypeAheadExport`) whose DataProvider table holds
/// the `SDSH_TYPE_AHEAD_*` records; Escape sends nothing;
/// * a recorded session (VA01 `SAPMV45B/0101`): AUART / VKORG
/// armed the same way; one request per DEBOUNCED pause (`z`, `zn`; `1`,
/// `10` — never one per keystroke), 1 character is enough; the PICK of a
/// proposal sends NO frame (the key is written into the field locally and
/// rides the next round's ordinary 16/9/2 atom); the COMMAND FIELD is
/// armed by connect support bit 222 OKCODE_TYPEAHEAD_ALL_RESULTS (not by
/// a property), asks `%_SEARCH_OKCODE <text>` from 2 characters on, and
/// its answer carries `SDSH_TYPE_OKCODE_PREFIX` (`/n`) + the
/// `SDSH_TYPE_AHEAD_MORE_DIALOG` row ("show all results",
/// `%_SEARCH_OCDIALOG <text>` -> the SAPLOKCODE_TA_DIALOG/4242 popup);
/// * a recorded session: the pick of `ME23N` from the
/// okcode list = NO frame, Enter = the plain okcode round `/nME23N`.
/// reference client port: (parse_table, is_capable).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../cfw/dp_cache.dart';

/// The XMLPROP custom property that arms a dynpro field (`typeahead="X"`).
const String typeAheadProperty = 'typeahead';

/// The dynpro-field request okcode (`SAPfront.dll` literal; the reference client's
/// OKCODE_WINDOWS): `%_SEARCH <text so far>`.
const String typeAheadOkcode = '%_SEARCH';

/// The command-field request okcode (`SAPfewui.dll` CMyCombo).
const String typeAheadOkcodeCommand = '%_SEARCH_OKCODE';

/// The command field's "show all results" row (`%_SEARCH_OCDIALOG <text>`).
const String typeAheadOkcodeAllResults = '%_SEARCH_OCDIALOG';

/// Whether the typed okcode [okcode] is a type-ahead REQUEST
/// (`%_SEARCH <text>` / `%_SEARCH_OKCODE <text>`): the rounds answered by
/// one `TypeAheadExport` flush and a no-op repaint. `%_SEARCH_OCDIALOG`
/// opens the 4242 dialog — an ordinary dialog step, not a request.
bool isTypeAheadRequestOkcode(String okcode) =>
    okcode.startsWith('$typeAheadOkcode ') ||
    okcode.startsWith('$typeAheadOkcodeCommand ');

/// The connect support bit that arms the command-field type-ahead.
const int supportBitOkcodeTypeAheadAllResults = 222;

/// The OCX verb of the answer flush.
const String typeAheadExportVerb = 'TypeAheadExport';

/// The fewest characters a command-field request goes out with (the wire:
/// no 1-character `%_SEARCH_OKCODE` frame exists; SAP GUI help "Enhanced
/// search is triggered after two characters").
const int typeAheadCommandMinChars = 2;

/// The fewest characters a dynpro-field request goes out with (`z`, `1`).
const int typeAheadFieldMinChars = 1;

final RegExp _armed = RegExp(
  r'<CustomProperty\b[^>]*\btypeahead\s*=\s*"\s*X\s*"',
  caseSensitive: false,
);

/// Whether an etype-120 XMLPROP property bag arms its field for type-ahead.
bool xmlpropArmsTypeAhead(String? xml) =>
    xml != null && xml.isNotEmpty && _armed.hasMatch(xml);

/// Whether the command-field (okcode) type-ahead may ask for [text]: from
/// two characters on ("Enhanced search is triggered after two
/// characters" — SAP GUI help; no 1-character `%_SEARCH_OKCODE` frame on
/// the wire), never for a `.` fast path or a `/` command (`/i1`, `/nex`).
/// The help's `/n` / `/o` + two characters search is NOT recorded (what
/// text the request then carries is unknown), so it is not asked.
bool commandFieldTypeAheadAllowed(String text) {
  final t = text.trim();
  if (t.startsWith('.') || t.startsWith('/')) return false;
  return t.length >= typeAheadCommandMinChars;
}

/// One proposal of a [TypeAheadTable] (an `SDSH_TYPE_AHEAD_DATA` record):
/// the cells with the server's `<b>`/`</b>` match markers stripped, and
/// the marked spans per cell.
class TypeAheadRow {
  TypeAheadRow(this.cells, this.marks);
  final List<String> cells;

  /// Per cell, the (start, end) spans the server marked as the match.
  final List<List<(int, int)>> marks;

  /// The value a pick writes into the field: the first column.
  String get key => cells.isEmpty ? '' : cells.first;

  /// The description column (the second), '' when none.
  String get text => cells.length > 1 ? cells[1] : '';

  @override
  String toString() => 'TypeAheadRow(${cells.join(' | ')})';
}

/// The decoded proposal table of one `TypeAheadExport` answer.
class TypeAheadTable {
  TypeAheadTable({
    this.header = const [],
    this.targetFields = const [],
    this.rows = const [],
    this.moreRow = '',
    this.message = '',
    this.okcodePrefix = '',
  });

  /// The column titles (`SDSH_TYPE_AHEAD_HEADER`).
  final List<String> header;

  /// The field(s) a pick writes (`SDSH_TYPE_AHEAD_FIELDS`, `VBAK-AUART`;
  /// `tstc-tcode` for the command field).
  final List<String> targetFields;

  /// At most 10 proposals (`SDSH_TYPE_AHEAD_DATA`).
  final List<TypeAheadRow> rows;

  /// The "show all results" row text (`SDSH_TYPE_AHEAD_MORE_DIALOG` /
  /// `_MORE`): present exactly when the result set was truncated.
  final String moreRow;

  /// A server message instead of / beside the rows (`_MESSAGE`).
  final String message;

  /// The command-field flavour marker (`SDSH_TYPE_OKCODE_PREFIX`, `/n`):
  /// the picked key goes into the command field as `<prefix><key>`.
  final String okcodePrefix;

  bool get isEmpty => rows.isEmpty;

  @override
  String toString() =>
      'TypeAheadTable(${targetFields.join(',')}: ${rows.length} rows'
      '${moreRow.isEmpty ? '' : ', more'}'
      '${okcodePrefix.isEmpty ? '' : ', prefix $okcodePrefix'})';
}

const String _recPrefix = 'SDSH_TYPE_';
const int _tagWidth = 30; // srv[15]: a record = 30-byte tag + N x 132 cells
const int _cellWidth = 132;
final RegExp _markRx = RegExp(r'<b>(.*?)</b>', dotAll: true);

/// (text without `<b>`/`</b>`, the marked spans in the stripped text).
(String, List<(int, int)>) stripTypeAheadMarks(String s) {
  final out = StringBuffer();
  final spans = <(int, int)>[];
  var last = 0;
  for (final m in _markRx.allMatches(s)) {
    out.write(s.substring(last, m.start));
    final start = out.length;
    out.write(m.group(1));
    spans.add((start, out.length));
    last = m.end;
  }
  out.write(s.substring(last));
  return (out.toString(), spans);
}

bool _tagAt(Uint8List b, int at) {
  if (at < 0 || at + _recPrefix.length > b.length) return false;
  for (var i = 0; i < _recPrefix.length; i++) {
    if (b[at + i] != _recPrefix.codeUnitAt(i)) return false;
  }
  return true;
}

/// The record start offsets of [b]: the fixed record width when every
/// record sits on it (a 30-byte tag + whole 132-byte cells — the bytes
/// are fixed-width, a UTF-8 `é` counts two), else every tag occurrence.
List<int> _recordStarts(Uint8List b) {
  var second = -1;
  for (var i = 1; i + _recPrefix.length <= b.length; i++) {
    if (_tagAt(b, i)) {
      second = i;
      break;
    }
  }
  if (second < 0) return [0];
  final w = second;
  if (w > _tagWidth && (w - _tagWidth) % _cellWidth == 0) {
    final fixed = [for (var at = 0; at < b.length; at += w) at];
    if (fixed.every((at) => _tagAt(b, at))) return fixed;
  }
  return [
    for (var i = 0; i + _recPrefix.length <= b.length; i++)
      if (_tagAt(b, i)) i,
  ];
}

String _field(Uint8List b, int start, int end) => utf8
    .decode(Uint8List.sublistView(b, start, end), allowMalformed: true)
    .replaceAll('\u0000', ' ')
    .trim();

/// The proposal table of a `SDSH_TYPE_AHEAD_*` record stream (a
/// DataProvider table's DATAASC content), or null when [blob] is none.
TypeAheadTable? parseTypeAheadTable(Uint8List blob) {
  if (!_tagAt(blob, 0)) return null;
  final header = <String>[], fields = <String>[], rows = <TypeAheadRow>[];
  var more = '', message = '', prefix = '';
  final starts = _recordStarts(blob);
  for (var i = 0; i < starts.length; i++) {
    final st = starts[i];
    final end = i + 1 < starts.length ? starts[i + 1] : blob.length;
    final tagEnd = (st + _tagWidth).clamp(st, end);
    final tag = _field(blob, st, tagEnd);
    final cells = <String>[
      for (var c = tagEnd; c < end; c += _cellWidth)
        _field(blob, c, (c + _cellWidth).clamp(c, end)),
    ];
    while (cells.isNotEmpty && cells.last.isEmpty) {
      cells.removeLast();
    }
    switch (tag) {
      case 'SDSH_TYPE_AHEAD_HEADER':
        header.addAll(cells);
      case 'SDSH_TYPE_AHEAD_FIELDS':
        fields.addAll(cells.where((c) => c.isNotEmpty));
      case 'SDSH_TYPE_AHEAD_DATA':
        final plain = <String>[], marks = <List<(int, int)>>[];
        for (final c in cells) {
          final (t, m) = stripTypeAheadMarks(c);
          plain.add(t);
          marks.add(m);
        }
        rows.add(TypeAheadRow(plain, marks));
      case 'SDSH_TYPE_AHEAD_MORE_DIALOG' || 'SDSH_TYPE_AHEAD_MORE':
        more = cells.isEmpty ? '' : stripTypeAheadMarks(cells.first).$1;
      case 'SDSH_TYPE_OKCODE_PREFIX':
        prefix = cells.isEmpty ? '' : cells.first;
      case 'SDSH_TYPE_AHEAD_MESSAGE':
        message = stripTypeAheadMarks(cells.join(' ')).$1;
    }
  }
  return TypeAheadTable(
    header: header,
    targetFields: fields,
    rows: rows,
    moreRow: more,
    message: message,
    okcodePrefix: prefix,
  );
}

/// The proposal table pushed in [frames] (a request round's answer: the
/// OLE flush's DataProvider push, read through a one-turn [DpCache]), or
/// null when none came back. The newest table wins.
TypeAheadTable? findTypeAheadTable(Iterable<Uint8List> frames) {
  TypeAheadTable? found;
  for (final f in frames) {
    final cache = DpCache();
    try {
      cache.ingestFrame(f);
    } on Object {
      continue; // not a DIAG data frame (a mode-control frame, garbage)
    }
    for (final seg in cache.byUrl.values) {
      final c = dpPutContent(seg);
      if (c == null) continue;
      final t = parseTypeAheadTable(c.content);
      if (t != null) found = t;
    }
  }
  return found;
}
