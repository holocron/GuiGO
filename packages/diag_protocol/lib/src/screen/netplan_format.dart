/// The LOOK of a NetPlan graph (SAPGUI.NetPlanGraphics.1 = SAPnetz.OCX) —
/// what the legacy `/$SECTION` stream says beyond its nodes and lines
/// ([SapNetPlanModel]): the box formats (/$FMTS), the frames around groups
/// of nodes (/$CLUSTER + /$CVALS), the free boxes (/$BOXES + /$BVALS), the
/// legend (/$LEGEND) and the control's options (/$OPTS).
///
/// Read off the real SAP GUI for Windows pushes (reference client recordings, read in
/// place): GRAL → NETZOCX1 (a recorded session srv[20], the
/// network demo: seven node types, two frames, a legend), GRAL →
/// GFW_DEMO_HIER3 (a recorded session srv[32], the structure
/// graphic: /$GTYPE T, 30 nodes of one format), STMS (a recorded session
/// srv[19]) and SWDD (a recorded session srv[25]).
///
/// /$FMTS is a list of 4-field records (owner, level, attribute, value):
/// * level `n` — a NODE-level attribute of the format the owner names
/// (`FMT001`; a blank owner continues the format before): `l` (`b` for
/// a frame / box format) the field layout `[$a--$b--($c//$d)]` —
/// `--` / `-` stack (rows, `--` ruled between them), `//` / `/` set side
/// by side (cells, `//` ruled), `$x` a text field, `@x` a picture field;
/// `f` the box shape (1 rectangle, 3 capsule, 4 hexagon, 5
/// parallelogram, 10 circle, 0 none — a line's / an invisible box's);
/// `e` table rules between the rows, `d` a double outline, `s` a shadow
/// (`x` = on); `t` a tag text the box carries beside it (NETZOCX1's
/// FMT005 `Test`, an ellipse on the parallelogram); `w` the outline's
/// width in 1/100 points (`0200` = 2); `c` the rule colour; `a` a line
/// format's arrow size;
/// * level `i` — an ITEM attribute of the field the owner names (`a`,
/// `b`, …) in the format before: `t` the node value it shows (an
/// /$NVALS key: 0 = the label, 1, 2 …), `o` / `v` its horizontal (l c
/// r) / vertical (t c b) alignment, `f` the font family (h Helvetica, c
/// Courier, t Times), `b` the style (bit 1 bold, bit 2 italic: NETZOCX1
/// node 5's `Text.a`, b 3 = bold italic, size 18, cyan), `h` the size in
/// points, `w` the width in 1/100 characters, `l` the lines, `c` the
/// text colour, `u` underlined; a picture field's `g` file, `z` / `y`
/// its size.
///
/// The /$HLTS sets ([SapNetPlanModel.highlights]) colour them: `h` the
/// fill, `l` the outline, `s` the shadow, `k` a symbol drawn over the box
/// (4 = a cross: NETZOCX1's Typ.7, the green circle with a red X) in `C`.
library;

/// One field of a box format ([NetPlanFormat.fields]).
class NetPlanField {
  NetPlanField(this.letter);

  /// The field's letter in the layout (`a` of `$a`).
  final String letter;

  /// Every item attribute by its letter (`t`, `o`, `v`, `f`, `b`, `h`,
  /// `w`, `l`, `c`, `u`, `g`, `z`, `y`, …).
  final Map<String, String> attrs = {};

  /// The /$NVALS key whose value the field shows (`t`), null for none (a
  /// picture field).
  String? get valueKey {
    final t = attrs['t']?.trim();
    return t == null || t.isEmpty ? null : t;
  }

  /// `l` / `c` / `r` (`o`; centred by default).
  String get align => (attrs['o'] ?? 'c').trim();

  /// `t` / `c` / `b` (`v`; centred by default).
  String get valign => (attrs['v'] ?? 'c').trim();

  /// `h` Helvetica, `c` Courier, `t` Times (`f`).
  String get family => (attrs['f'] ?? 'h').trim();

  int get _style => int.tryParse((attrs['b'] ?? '').trim()) ?? 0;
  bool get bold => _style & 1 != 0;
  bool get italic => _style & 2 != 0;

  /// The font size in points (`h`; 10 when absent).
  double get size {
    final h = int.tryParse((attrs['h'] ?? '').trim());
    return h == null || h <= 0 ? 10 : h.toDouble();
  }

  /// The width in characters (`w` in 1/100 characters), null when the
  /// field declares none (it takes its row's).
  double? get width {
    final w = int.tryParse((attrs['w'] ?? '').trim());
    return w == null || w <= 0 ? null : w / 100;
  }

  /// The text lines (`l`; 1 by default).
  int get lines {
    final l = int.tryParse((attrs['l'] ?? '').trim());
    return l == null || l < 1 ? 1 : l;
  }

  /// The text colour's JNet name (`c`), null for the default.
  String? get color {
    final c = attrs['c']?.trim();
    return c == null || c.isEmpty ? null : c;
  }

  bool get underline => (attrs['u'] ?? '').trim() == 'x';

  /// A picture field's file (`g`), null for a text field.
  String? get picture {
    final g = attrs['g']?.trim();
    return g == null || g.isEmpty ? null : g;
  }

  @override
  String toString() => 'NetPlanField($letter, $attrs)';
}

/// One cell of a format's layout: a field ([NetPlanLeaf]) or a split of
/// cells ([NetPlanSplit]).
sealed class NetPlanCell {
  const NetPlanCell();

  /// Every field letter under this cell, in layout order.
  List<String> get letters;
}

class NetPlanLeaf extends NetPlanCell {
  const NetPlanLeaf(this.letter, {this.picture = false});

  /// The field's letter (`a` of `$a` / `@a`).
  final String letter;

  /// `@x`: a picture field.
  final bool picture;

  @override
  List<String> get letters => [letter];

  @override
  String toString() => '${picture ? '@' : r'$'}$letter';
}

class NetPlanSplit extends NetPlanCell {
  const NetPlanSplit(this.children, {required this.across, this.ruled = true});

  /// The parts, top to bottom ([across] false) or left to right.
  final List<NetPlanCell> children;

  /// `//` / `/` (side by side) rather than `--` / `-` (stacked).
  final bool across;

  /// `--` / `//`: a rule between the parts.
  final bool ruled;

  @override
  List<String> get letters => [for (final c in children) ...c.letters];

  @override
  String toString() =>
      '(${children.join(across ? (ruled ? '//' : '/') : (ruled ? '--' : '-'))})';
}

// Hoisted: the field-name test ran per CHARACTER of a layout expression,
// compiling a RegExp each time (audit 2026-10-17 N1).
final RegExp _fieldCharRx = RegExp(r'[A-Za-z0-9_]');
final RegExp _blankRunRx = RegExp(r'\s+');

/// The layout expression [text] (`[$a--$b--($c//$d)]`) as cells; null
/// when it holds no field.
NetPlanCell? parseNetPlanLayout(String text) {
  var s = text.trim();
  if (s.startsWith('[')) s = s.substring(1);
  if (s.endsWith(']')) s = s.substring(0, s.length - 1);
  final toks = <String>[];
  for (var i = 0; i < s.length;) {
    final c = s[i];
    if (c == r'$' || c == '@') {
      var j = i + 1;
      while (j < s.length && _fieldCharRx.hasMatch(s[j])) {
        j++;
      }
      toks.add(s.substring(i, j));
      i = j;
    } else if (c == '-' || c == '/') {
      final two = i + 1 < s.length && s[i + 1] == c;
      toks.add(two ? '$c$c' : c);
      i += two ? 2 : 1;
    } else if (c == '(' || c == ')') {
      toks.add(c);
      i++;
    } else {
      i++; // blanks, stray characters
    }
  }
  var at = 0;
  late NetPlanCell? Function() expr;
  NetPlanCell? factor() {
    if (at >= toks.length) return null;
    final t = toks[at];
    if (t == '(') {
      at++;
      final e = expr();
      if (at < toks.length && toks[at] == ')') at++;
      return e;
    }
    if ((t.startsWith(r'$') || t.startsWith('@')) && t.length > 1) {
      at++;
      return NetPlanLeaf(t.substring(1), picture: t.startsWith('@'));
    }
    return null;
  }

  NetPlanCell? split(bool across) {
    final parts = <NetPlanCell>[];
    var ruled = false;
    final first = across ? factor() : split(true);
    if (first != null) parts.add(first);
    while (at < toks.length) {
      final op = toks[at];
      final isOp = across ? (op == '//' || op == '/') : (op == '--' || op == '-');
      if (!isOp) break;
      at++;
      ruled |= op.length == 2;
      final next = across ? factor() : split(true);
      if (next != null) parts.add(next);
    }
    if (parts.isEmpty) return null;
    if (parts.length == 1) return parts.single;
    return NetPlanSplit(parts, across: across, ruled: ruled);
  }

  expr = () => split(false);
  return expr();
}

/// One /$FMTS format: a node's, a line's, a frame's or a box's.
class NetPlanFormat {
  NetPlanFormat(this.id);

  final String id;

  /// Every node-level attribute by its letter (`l`, `b`, `f`, `e`, `d`,
  /// `s`, `t`, `w`, `c`, `a`, `x`, …).
  final Map<String, String> attrs = {};

  /// The fields by letter, in declaration order.
  final Map<String, NetPlanField> fields = {};

  /// The layout expression (`l`, a frame's / box's `b`), '' for none.
  String get layoutText => (attrs['l'] ?? attrs['b'] ?? '').trim();

  NetPlanCell? _cell;
  bool _parsed = false;

  /// The layout as cells, null when the format declares none.
  NetPlanCell? get layout {
    if (!_parsed) {
      _parsed = true;
      _cell = parseNetPlanLayout(layoutText);
    }
    return _cell;
  }

  /// The shape code (`f`): 1 rectangle, 3 capsule, 4 hexagon, 5
  /// parallelogram, 10 circle, 0 none; 1 when absent.
  int get shape => int.tryParse((attrs['f'] ?? '').trim()) ?? 1;

  bool _on(String a) => (attrs[a] ?? '').trim() == 'x';

  /// `e`: rules between the rows (a table box).
  bool get table => _on('e');

  /// `d`: a double outline.
  bool get doubleOutline => _on('d');

  /// `s`: a shadow.
  bool get shadow => _on('s');

  /// `t`: the tag text drawn beside the box ('' for none).
  String get tag => (attrs['t'] ?? '').trim();

  /// `w`: the outline's width in points (1 when absent).
  double get outlineWidth {
    final w = int.tryParse((attrs['w'] ?? '').trim());
    return w == null || w <= 0 ? 1 : w / 100;
  }

  /// `c`: the rule colour's JNet name, null for none.
  String? get ruleColor {
    final c = attrs['c']?.trim();
    return c == null || c.isEmpty ? null : c;
  }

  @override
  String toString() => 'NetPlanFormat($id, $layoutText, shape $shape)';
}

/// The /$FMTS records [f] (owner, level, attribute, value) as formats by
/// id. A record out of step (its level neither `n` nor `i`: a reassembly
/// artifact) is skipped one field at a time until the records align again.
Map<String, NetPlanFormat> parseNetPlanFormats(List<String> f) {
  final out = <String, NetPlanFormat>{};
  NetPlanFormat? cur;
  var i = 0;
  while (i + 3 < f.length) {
    final level = f[i + 1].trim();
    if (level != 'n' && level != 'i') {
      i++;
      continue;
    }
    final owner = f[i].trim(), attr = f[i + 2].trim(), value = f[i + 3];
    i += 4;
    if (attr.isEmpty) continue;
    if (level == 'n') {
      if (owner.isNotEmpty) cur = out[owner] = NetPlanFormat(owner);
      cur?.attrs[attr] = value;
    } else if (cur != null && owner.isNotEmpty) {
      (cur.fields[owner] ??= NetPlanField(owner)).attrs[attr] = value;
    }
  }
  return out;
}

/// A frame drawn around a group of nodes (/$CLUSTER id, format,
/// highlight; /$CVALS id, key, value: `A` a member node, `0` the title).
/// NETZOCX1's `C1` "Cadre 1" (yellow, its title red and bold) holds nodes
/// 1, 2, 3; `C2` "Cadre 2" (green) 4, 5, 6.
class NetPlanCluster {
  NetPlanCluster(this.id, {this.format = '', this.highlight = ''});

  final String id;
  String format;
  String highlight;
  String label = '';
  final List<String> members = [];

  /// Every other /$CVALS value by key.
  final Map<String, String> values = {};

  NetPlanCluster copy() => NetPlanCluster(id, format: format, highlight: highlight)
    ..label = label
    ..members.addAll(members)
    ..values.addAll(values);

  @override
  String toString() => 'NetPlanCluster($id "$label" $members)';
}

/// A free box of the graph (/$BOXES id, kind, format; /$BVALS id, key,
/// value: `0` its text, `H` its highlight) — NETZOCX1's title box `B1`.
class NetPlanBox {
  NetPlanBox(this.id, {this.format = ''});

  final String id;
  String format;
  final Map<String, String> values = {};

  NetPlanBox copy() => NetPlanBox(id, format: format)..values.addAll(values);
}

/// One line of the legend (/$LEGEND: a blank, the sample's format and
/// highlight, its text). A line without a format is a caption (NETZOCX1:
/// the title "Légende", the footer "SAP AG"); one with a format is a
/// sample box of that node type (Typ.1 … Typ.7).
class NetPlanLegendEntry {
  const NetPlanLegendEntry({
    required this.format,
    required this.highlight,
    required this.text,
  });

  final String format;
  final String highlight;
  final String text;

  bool get isCaption => format.isEmpty;

  @override
  String toString() => 'NetPlanLegendEntry($format/$highlight "$text")';
}

/// Everything of a graph's look ([SapNetPlanModel.decor]): formats,
/// frames, boxes, legend and options, as the last full stream sent them
/// (a delta push replaces the sections it carries).
class NetPlanDecor {
  final Map<String, NetPlanFormat> formats = {};
  final List<NetPlanCluster> clusters = [];
  final List<NetPlanBox> boxes = [];
  final List<NetPlanLegendEntry> legend = [];

  /// /$OPTS `SET <NAME> <value>` by name (`LAYOUT`, `LEGEND`,
  /// `MASTERVIEW`, `DISPBACKGR`, `ROUNDED`, …).
  final Map<String, String> options = {};

  bool get isEmpty =>
      formats.isEmpty && clusters.isEmpty && boxes.isEmpty && legend.isEmpty;

  /// The graph's background colour's JNet name (`DISPBACKGR`), null when
  /// unset.
  String? get background {
    final b = options['DISPBACKGR']?.trim();
    return b == null || b.isEmpty ? null : b;
  }

  /// Whether the control shows its overview window (the navigator: the
  /// whole graph in miniature, the visible part framed in `NAVFRAME`):
  /// `MASTERVIEW` with bit 2 — GFW_DEMO_HIER3's structure graphic (6,
  /// the real GUI's navigator beside it; SWDD 7), not NETZOCX1 (4, none
  /// beside its graph). An inference from the two screens, not a
  /// documented code.
  bool get overview {
    final m = int.tryParse((options['MASTERVIEW'] ?? '').trim());
    return m != null && m & 2 != 0;
  }

  /// Corner lines are rounded (`ROUNDED 1`).
  bool get rounded => (options['ROUNDED'] ?? '').trim() == '1';

  NetPlanCluster? cluster(String id) {
    for (final c in clusters) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Fold one stream's sections ({/$NAME: fields}) in: a [full] stream
  /// replaces everything, a delta the sections it carries.
  void apply(Map<String, List<String>> s, {required bool full}) {
    if (full) {
      formats.clear();
      clusters.clear();
      boxes.clear();
      legend.clear();
      options.clear();
    }
    final opts = s[r'/$OPTS'];
    if (opts != null) {
      for (final o in opts) {
        final p = o.trim().split(_blankRunRx);
        if (p.length >= 2 && p[0] == 'SET') {
          options[p[1]] = p.length > 2 ? p.sublist(2).join(' ') : '';
        }
      }
    }
    final fm = s[r'/$FMTS'];
    if (fm != null) formats.addAll(parseNetPlanFormats(fm));
    final cl = s[r'/$CLUSTER'];
    if (cl != null) {
      for (var i = 0; i + 3 <= cl.length; i += 3) {
        final id = cl[i].trim();
        if (id.isEmpty) continue;
        final c = cluster(id);
        if (c == null) {
          clusters.add(NetPlanCluster(id, format: cl[i + 1].trim(),
              highlight: cl[i + 2].trim()));
        } else {
          c
            ..format = cl[i + 1].trim()
            ..highlight = cl[i + 2].trim();
        }
      }
    }
    final cv = s[r'/$CVALS'];
    if (cv != null) {
      final reset = <String>{};
      for (var i = 0; i + 3 <= cv.length; i += 3) {
        final c = cluster(cv[i].trim());
        if (c == null) continue;
        final key = cv[i + 1].trim(), v = cv[i + 2];
        if (key == 'A') {
          if (reset.add(c.id)) c.members.clear();
          if (v.trim().isNotEmpty) c.members.add(v.trim());
        } else if (key == '0') {
          c.label = v.trim();
        } else {
          c.values[key] = v;
        }
      }
    }
    final bx = s[r'/$BOXES'];
    if (bx != null) {
      for (var i = 0; i + 3 <= bx.length; i += 3) {
        final id = bx[i].trim();
        if (id.isEmpty) continue;
        boxes.removeWhere((b) => b.id == id);
        boxes.add(NetPlanBox(id, format: bx[i + 2].trim()));
      }
    }
    final bv = s[r'/$BVALS'];
    if (bv != null) {
      for (var i = 0; i + 3 <= bv.length; i += 3) {
        final id = bv[i].trim();
        for (final b in boxes) {
          if (b.id == id) b.values[bv[i + 1].trim()] = bv[i + 2];
        }
      }
    }
    final lg = s[r'/$LEGEND'];
    if (lg != null) {
      legend.clear();
      for (var i = 0; i + 4 <= lg.length; i += 4) {
        legend.add(NetPlanLegendEntry(
          format: lg[i + 1].trim(),
          highlight: lg[i + 2].trim(),
          text: lg[i + 3].trim(),
        ));
      }
    }
  }

  NetPlanDecor copy() {
    final d = NetPlanDecor()
      ..formats.addAll(formats) // formats are not changed in place
      ..clusters.addAll([for (final c in clusters) c.copy()])
      ..boxes.addAll([for (final b in boxes) b.copy()])
      ..legend.addAll(legend)
      ..options.addAll(options);
    return d;
  }
}
