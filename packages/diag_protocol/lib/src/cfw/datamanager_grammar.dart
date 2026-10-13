/// The grammar of the client's DATAMANAGER XML (the type-17 item of a
/// round, the XML_DATA_STREAM of a flush answer) as the server's parser
/// takes it — CL_GUI_DATAMANAGER->TRACE_XML, the kernel's hand-rolled
/// scanner behind the CFW DataManager, dumps MESSAGE_TYPE_X CNDP 008
/// "<stream start>; balise act.: <TAG>" on what it cannot place.
///
/// Derived from the recordings, not from a schema: every DATAMANAGER of
/// every real-GUI client frame of the reference client's corpus (5107 documents,
/// Java and Windows, 2026-10-12) — the parent > child pairs, the
/// attributes per tag, the block multiplicities and, in the Windows OCX
/// spelling, the orders:
///
/// DATAMANAGER > TABLES | EVENTS | CONTROLS | BLOBS | COPY, each at most
/// once (OCX order TABLES, EVENTS, CONTROLS, BLOBS, COPY)
/// TABLES > DATACHANGES(HANDLE) > IT(IDX, OP, C1..Cn)
/// | DATAREQUEST(HANDLE, FIRSTLINE, NLINES)
/// EVENTS > exactly one EVENT(SHELLID, EVENTID[, SHELLEVENT])
/// > PARAM(PID, VALUE …), PIDs distinct
/// CONTROLS > CONTROL(SHELLID), one per shell
/// > PROPERTY(VALUE, NAME), names distinct,
/// non-blank and unpadded; GENERIC
/// (FVCID, FVRID, FVRIDS) at most once
/// BLOBS > REQUEST
/// COPY > GUI > METRICS | DIMENSIONS
///
/// No text between the tags (whitespace only), nothing after the root but
/// NUL padding, attribute values free of `<` and of bare `&`. In the OCX
/// spelling (`NAME ="v"`) the attribute orders are the OCX's: PARAM PID
/// first, GENERIC FVCID FVRID FVRIDS (a Java-ordered GENERIC dumped "balise
/// GENERIC" live — reference client dm_windows_shape, complaint-db13+20260920-
/// 104420), PROPERTY VALUE first. (IT cells: no order — the OCX writes a
/// wide row's C<n> in hash order, a recorded session gui[23].)
library;

import 'dart:typed_data';

const String _decl = '<?xml version="1.0" encoding="sap*"?>';

const Map<String, Set<String>> _children = {
  'DATAMANAGER': {'TABLES', 'EVENTS', 'CONTROLS', 'BLOBS', 'COPY'},
  'TABLES': {'DATACHANGES', 'DATAREQUEST'},
  'DATACHANGES': {'IT'},
  'EVENTS': {'EVENT'},
  'EVENT': {'PARAM'},
  'CONTROLS': {'CONTROL'},
  'CONTROL': {'PROPERTY', 'GENERIC'},
  'BLOBS': {'REQUEST'},
  'COPY': {'GUI'},
  'GUI': {'METRICS', 'DIMENSIONS'},
};

const Map<String, List<String>> _required = {
  'DATACHANGES': ['HANDLE'],
  'IT': ['IDX', 'OP'],
  'DATAREQUEST': ['HANDLE', 'FIRSTLINE', 'NLINES'],
  'EVENT': ['SHELLID', 'EVENTID'],
  'PARAM': ['PID', 'VALUE'],
  'CONTROL': ['SHELLID'],
  'PROPERTY': ['VALUE', 'NAME'],
  'GENERIC': ['FVCID', 'FVRID', 'FVRIDS'],
};

/// The OCX block order under DATAMANAGER.
const List<String> _ocxBlockOrder = [
  'TABLES',
  'EVENTS',
  'CONTROLS',
  'BLOBS',
  'COPY',
];

final RegExp _tag = RegExp(
  r'<(/?)([A-Za-z_][A-Za-z0-9_]*)((?:\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*"[^"]*")*)\s*(/?)>',
);
final RegExp _attr = RegExp(r'([A-Za-z_][A-Za-z0-9_]*)(\s*)=\s*"([^"]*)"');
final RegExp _entity = RegExp(r'&(?:amp|lt|gt|quot|apos|#\d+|#x[0-9A-Fa-f]+);');

class _Node {
  _Node(this.name, this.attrs);
  final String name;
  final List<(String, String)> attrs;
  final List<_Node> kids = [];
  String? attr(String n) {
    for (final (k, v) in attrs) {
      if (k == n) return v;
    }
    return null;
  }
}

/// The problems of DATAMANAGER document [xml] by the grammar above; empty
/// when the server's parser takes it as the real GUI's. A text without a
/// `<DATAMANAGER` is no DATAMANAGER document and has none.
List<String> datamanagerProblems(String xml) {
  final p = <String>[];
  var s = xml;
  while (s.endsWith('\u0000')) {
    s = s.substring(0, s.length - 1);
  }
  final root = s.indexOf('<DATAMANAGER');
  if (root < 0) return p;
  final head = s.substring(0, root);
  if (head.trim().isNotEmpty && head.trim() != _decl) {
    p.add('text before <DATAMANAGER>: "${head.trim()}"');
  }
  if (s.contains('\u0000')) p.add('a NUL inside the document');
  var ocx = false;
  final stack = <_Node>[];
  _Node? top;
  var pos = root;
  for (final m in _tag.allMatches(s, root)) {
    if (m.start != pos) {
      final gap = s.substring(pos, m.start);
      if (gap.trim().isNotEmpty) {
        p.add('text "${_clip(gap)}" before <${m[1]}${m[2]}>');
      }
    }
    pos = m.end;
    if (top != null && stack.isEmpty) {
      p.add('<${m[1]}${m[2]}> after </DATAMANAGER>');
      break;
    }
    final name = m[2]!;
    if (m[1] == '/') {
      if (stack.isEmpty || stack.last.name != name) {
        p.add(
          '</$name> closes '
          '${stack.isEmpty ? 'nothing' : '<${stack.last.name}>'}',
        );
        return p;
      }
      stack.removeLast();
      continue;
    }
    final attrs = <(String, String)>[];
    for (final a in _attr.allMatches(m[3]!)) {
      if (a[2]!.isNotEmpty) ocx = true;
      final v = a[3]!;
      if (v.contains('<')) p.add('<$name ${a[1]}> value holds "<"');
      if (v.replaceAll(_entity, '').contains('&')) {
        p.add('<$name ${a[1]}> value holds a bare "&"');
      }
      if (attrs.any((x) => x.$1 == a[1])) {
        p.add('<$name> repeats attribute ${a[1]}');
      }
      attrs.add((a[1]!, v));
    }
    final node = _Node(name, attrs);
    if (stack.isEmpty) {
      if (top != null || name != 'DATAMANAGER') {
        p.add('<$name> outside <DATAMANAGER>');
        return p;
      }
      top = node;
    } else {
      final parent = stack.last;
      final allowed = _children[parent.name];
      if (allowed == null || !allowed.contains(name)) {
        p.add('<$name> inside <${parent.name}>');
      }
      parent.kids.add(node);
    }
    if (m[4] != '/') stack.add(node);
  }
  if (top == null) return p..add('no <DATAMANAGER> element');
  if (stack.isNotEmpty) {
    p.add('unclosed ${[for (final n in stack) '<${n.name}>'].join(' ')}');
  }
  final tail = s.substring(pos);
  if (tail.trim().isNotEmpty) p.add('text after the root: "${_clip(tail)}"');
  _check(top, p, ocx);
  return p;
}

/// Whether item-17 value [value] (latin-1 / codepage bytes) is a sound
/// DATAMANAGER document — throws a [StateError] naming the problems
/// otherwise. For `assert` in the builders (debug and tests only).
bool debugCheckDatamanager(Uint8List value, {String what = 'item 17'}) {
  final problems = datamanagerProblems(String.fromCharCodes(value));
  if (problems.isEmpty) return true;
  throw StateError(
    'malformed DATAMANAGER ($what): ${problems.join('; ')} — '
    '${_clip(String.fromCharCodes(value), 400)}',
  );
}

/// Every DATAMANAGER document [text] holds (an outgoing frame's
/// decompressed body: the round's item 17, a flush answer's XML stream),
/// in order — each from its declaration (or `<DATAMANAGER` tag) through
/// `</DATAMANAGER>`.
List<String> datamanagerDocuments(String text) {
  final out = <String>[];
  var at = 0;
  while (true) {
    var q = text.indexOf(_decl, at);
    final t = text.indexOf('<DATAMANAGER', at);
    if (q < 0 || (t >= 0 && t < q)) q = t;
    if (q < 0) break;
    final e = text.indexOf('</DATAMANAGER>', q);
    if (e < 0) break;
    out.add(text.substring(q, e + '</DATAMANAGER>'.length));
    at = e + '</DATAMANAGER>'.length;
  }
  return out;
}

/// [xml] for a trace line: what the user typed masked — the non-numeric
/// cells of DATACHANGES rows (`IT … C<n> ="…"`: grid cell edits; the row /
/// column numbers stay) and the grid's CurrentCellText — each value
/// replaced by `*` x its length, the structure (tags, attribute names,
/// shells, property names, event ids) kept as sent; line breaks shown as
/// `\n`.
String datamanagerTraceText(String xml) => xml
    .replaceAllMapped(_itRx, (m) => m[0]!.replaceAllMapped(_cellRx, (c) {
          final v = c[3]!;
          return _numericRx.hasMatch(v) ? c[0]! : '${c[1]}${c[2]}"${'*' * v.length}"';
        }))
    .replaceAllMapped(_cellTextRx, (m) => '${m[1]}"${'*' * m[2]!.length}"${m[3]}')
    .replaceAll('\n', r'\n')
    .replaceAll('\u0000', '');

final RegExp _itRx = RegExp(r'<IT\b[^>]*>');
final RegExp _cellRx = RegExp(r'(\bC\d+)(\s*=\s*)"([^"]*)"');
final RegExp _numericRx = RegExp(r'^\s*-?\d*\s*$');
final RegExp _cellTextRx = RegExp(
  r'(<PROPERTY\s+VALUE\s*=\s*)"([^"]*)"(\s+NAME\s*=\s*"CurrentCellText")',
);

void _check(_Node n, List<String> p, bool ocx) {
  for (final a in _required[n.name] ?? const <String>[]) {
    if (n.attr(a) == null) p.add('<${n.name}> without $a');
  }
  if (_children.containsKey(n.name) == false && n.kids.isNotEmpty) {
    p.add('<${n.name}> has children');
  }
  switch (n.name) {
    case 'DATAMANAGER':
      final seen = <String>[];
      for (final k in n.kids) {
        if (seen.contains(k.name)) p.add('a second <${k.name}> section');
        seen.add(k.name);
      }
      if (ocx) {
        final order = [
          for (final b in _ocxBlockOrder)
            if (seen.contains(b)) b,
        ];
        final got = [
          for (final b in seen)
            if (_ocxBlockOrder.contains(b)) b,
        ];
        if (got.join(',') != order.join(',')) {
          p.add(
            'OCX block order ${got.join(',')} (the OCX writes '
            '${order.join(',')})',
          );
        }
      }
    case 'EVENTS':
      if (n.kids.length != 1) {
        p.add('<EVENTS> holds ${n.kids.length} events (exactly one)');
      }
    case 'EVENT':
      final pids = [for (final k in n.kids) k.attr('PID')];
      if (pids.toSet().length != pids.length) p.add('<EVENT> repeats a PID');
    case 'CONTROLS':
      final ids = [for (final k in n.kids) k.attr('SHELLID')?.trim()];
      for (final id in ids.toSet()) {
        if (ids.where((x) => x == id).length > 1) {
          p.add('CONTROL $id twice in one <CONTROLS>');
        }
      }
    case 'CONTROL':
      final sh = n.attr('SHELLID') ?? '';
      if (!_digitsOnlyRx.hasMatch(sh)) p.add('CONTROL SHELLID "$sh"');
      final names = [
        for (final k in n.kids)
          if (k.name == 'PROPERTY') k.attr('NAME'),
      ];
      // a nameless PROPERTY names no cached prop (the phantom
      // `<CONTROL SHELLID="300"><PROPERTY VALUE="" NAME=""/>` a numeric
      // GetProperty once echoed — flush_call.dart)
      if (names.contains('')) p.add('CONTROL $sh holds a nameless PROPERTY');
      // a blank or padded name names no cached prop either: the real GUI's
      // are propIds (`120`) or identifiers (`ABAPSelItemKey`), never
      // spaced (the corpus' 5107 documents)
      for (final nm in names) {
        if (nm == null || nm.isEmpty) continue;
        if (nm.trim().isEmpty) {
          p.add('CONTROL $sh holds a blank-named PROPERTY');
        } else if (nm.trim() != nm || nm.contains(' ')) {
          p.add('CONTROL $sh names PROPERTY "$nm" with blanks');
        }
      }
      // one PROPERTY per name, whatever its padding
      final trimmed = [for (final nm in names) nm?.trim()];
      for (final nm in trimmed.toSet()) {
        if (nm == null || nm.isEmpty) continue;
        if (trimmed.where((x) => x == nm).length > 1) {
          p.add('CONTROL $sh names PROPERTY $nm twice');
        }
      }
      if (n.kids.where((k) => k.name == 'GENERIC').length > 1) {
        p.add('CONTROL $sh holds two GENERIC');
      }
  }
  if (ocx) {
    final keys = [for (final (k, _) in n.attrs) k];
    switch (n.name) {
      case 'PARAM' when keys.isNotEmpty && keys.first != 'PID':
      case 'PROPERTY' when keys.isNotEmpty && keys.first != 'VALUE':
      case 'GENERIC' when keys.join(',') != 'FVCID,FVRID,FVRIDS':
        p.add('OCX attribute order <${n.name} ${keys.join(' ')}>');
    }
  }
  for (final k in n.kids) {
    _check(k, p, ocx);
  }
}

String _clip(String s, [int n = 60]) {
  final t = s.replaceAll('\n', r'\n').replaceAll('\u0000', r'\0');
  return t.length <= n ? t : '${t.substring(0, n)}…';
}

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call (audit #7 / zcode P-12).
final RegExp _digitsOnlyRx = RegExp(r'^\d+$');
