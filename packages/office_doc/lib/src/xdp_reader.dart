/// An XDP (XML Data Package) reader: the Adobe form template SFP's Layout
/// tab edits through the LiveCycle Designer — the layout packet's
/// `template` element tree (subforms, fields, draws) with every attribute,
/// script and data binding kept, and a geometry pass that gives each
/// element a rectangle so the layout can be drawn read-only (GuiGo hosts
/// no Designer; the XDP the server pushes is rendered, never executed).
///
/// What is read:
///
/// * the `template` packet: `subform` (the container: `layout="position"`
/// places children at their `x`/`y`; `tb` stacks them; `lr-tb` lays them
/// out left-right with wrap), `field` (the interactive widgets: text /
/// numeric / date edits, checkboxes, dropdowns, images, buttons), `draw`
/// (the static text / lines / rectangles / images), `pageSet` /
/// `pageArea` (the pages), `occur` (a subform's cardinality) and the
/// `event`/`script` (FormCalc / JavaScript), `bind`, `calculate` and
/// `validate` elements wherever they sit;
/// * the `config` packet's generator note; every packet is listed by name.
///
/// Not read (never needed to SHOW a form): the scripts are collected
/// verbatim but never run, the `datasets` / `localeSet` packets are
/// skipped, and XFA features beyond the template geometry (breaks,
/// anchors, scripting-driven visibility) fall back to sane defaults.
library;

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:xml/xml.dart';

/// Reads and lays out the XDP [bytes]. Throws [FormatException] when it is
/// not an XDP (`<xdp:xdp>` root) or carries no template packet.
XfaForm readXdp(Uint8List bytes) {
  final text = _decode(bytes);
  final doc = XmlDocument.parse(text);
  final root = doc.rootElement;
  if (root.name.local != 'xdp') {
    throw const FormatException('not an XDP: no <xdp:xdp> root');
  }
  final packets = <String>[for (final e in root.childElements) e.name.local];
  final template = root.childElements
      .where((e) => e.name.local == 'template')
      .firstOrNull;
  if (template == null) {
    throw const FormatException('XDP without a template packet');
  }
  final reader = _Reader();
  final rootForm = template.childElements
      .where((e) => e.name.local == 'subform')
      .firstOrNull
      ?.let(reader.readSubform);
  final form = XfaForm(
    generator: _generatorOf(text),
    packets: packets,
    root: rootForm,
    pages: reader.pages.isEmpty ? [XfaPageArea.fallback()] : reader.pages,
    elements: reader.elements,
    source: text,
  );
  layoutXfaForm(form);
  return form;
}

/// [readXdp] that answers null instead of throwing for bytes that are not
/// an XFA template (a caller showing a document it knows little about).
XfaForm? tryReadXdp(Uint8List bytes) {
  try {
    return readXdp(bytes);
  } on FormatException {
    return null;
  } on XmlException {
    return null;
  }
}

String _decode(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return String.fromCharCodes(bytes);
  }
}

String? _generatorOf(String text) {
  const marker = 'generator="';
  final i = text.indexOf(marker);
  if (i < 0) return null;
  final j = text.indexOf('"', i + marker.length);
  return j < 0 ? null : text.substring(i + marker.length, j);
}

extension<T> on T? {
  R? let<R>(R Function(T) f) => this == null ? null : f(this as T);
}

// ---------------------------------------------------------------------------
// The model
// ---------------------------------------------------------------------------

/// What an element is for the viewer. Only the interesting tags get a
/// kind; everything else stays [other] (still listed in the structure
/// tree with its attributes).
enum XfaKind { pageSet, pageArea, subform, field, draw, other }

/// One element of the template tree: the tag as XFA names it, its `name`,
/// EVERY attribute the packet carried, and the rectangle the geometry pass
/// placed it at ([rect] null while hidden / not laid out).
class XfaElement {
  XfaElement({
    required this.kind,
    required this.tag,
    required this.som,
    this.name,
    required this.attrs,
    List<XfaElement>? children,
  }) : children = children ?? const [];

  final XfaKind kind;

  /// The XML tag (`subform`, `field`, `draw`, `bind`, `event`, …).
  final String tag;

  /// The element's SOM path (`data.HEADER.LOGO`): the `name`s up the
  /// subform chain, unnamed links skipped.
  final String som;

  /// The `name` attribute, null when absent.
  final String? name;

  /// Every attribute of the XML element, in document order.
  final Map<String, String> attrs;

  /// The geometry pass's rectangle in points, page-relative; null when the
  /// element has no place (hidden, or not part of the layout).
  XfaRect? rect;

  /// The 0-based index of the [XfaForm.pages] page the element sits on.
  int page = 0;

  /// The structural children (pageSet -> pageArea -> subforms); empty for
  /// placed elements.
  final List<XfaElement> children;

  /// A short viewer label: the name, else the tag.
  String get label => (name ?? '').isNotEmpty ? name! : tag;
}

/// A laid-out page (`pageArea`): its size and orientation as declared.
class XfaPageArea {
  XfaPageArea({
    required this.name,
    required this.w,
    required this.h,
    required this.landscape,
  });

  /// A4 portrait — the page of a template without a pageSet.
  XfaPageArea.fallback()
      : name = 'Page1',
        w = 595.28,
        h = 841.89,
        landscape = false;

  final String name;
  final double w, h;
  final bool landscape;
}

/// A rectangle in points (XFA's coordinate system: origin top-left, y
/// grows down).
class XfaRect {
  const XfaRect(this.x, this.y, this.w, this.h);
  final double x, y, w, h;

  double get right => x + w;
  double get bottom => y + h;

  @override
  String toString() =>
      '(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)}, '
      '${w.toStringAsFixed(1)}x${h.toStringAsFixed(1)})';
}

/// A static or interactive element the layout renderer draws.
class XfaPlaced extends XfaElement {
  XfaPlaced({
    required super.kind,
    required super.tag,
    required super.som,
    super.name,
    required super.attrs,
    required this.ui,
    required this.text,
    required this.font,
    required this.border,
    required this.fill,
    required this.image,
    this.access,
    this.captionText,
  });

  /// The widget: textEdit / numericEdit / dateEdit / checkButton /
  /// choiceList / imageEdit / button / signature / barcode for a field;
  /// text / line / rect / image for a draw.
  final String ui;

  /// The element's text: a draw's static text, a choice list's first item,
  /// a field's caption when it has no value.
  final String text;

  /// The font the element declared (null: inherit the viewer's default).
  final XfaFont? font;

  /// The border edges in declaration order, each with its thickness.
  final List<XfaEdge> border;

  /// The background fill, null when none.
  final XfaColor? fill;

  /// A base64 image (an image draw / imageEdit's picture), null when none.
  final XfaImage? image;

  /// The field's `access` (`open`, `readOnly`, `protected`).
  final String? access;

  /// The caption's own text when the field carries one.
  final String? captionText;
}

/// A script an element carries, verbatim: the event it runs on, its
/// language and source.
class XfaScript extends XfaElement {
  XfaScript({
    required super.som,
    required super.attrs,
    required this.event,
    required this.activity,
    required this.language,
    required this.runAt,
    required this.source,
  }) : super(kind: XfaKind.other, tag: 'script');

  /// The owner element's SOM path.
  final String event;

  /// The event's `activity` (`click`, `initialize`, …); `calculate` /
  /// `validate` for those elements' scripts.
  final String? activity;

  /// `application/x-javascript`, `application/x-formcalc`, …
  final String language;

  /// `client`, `server` or `both` — where the template wants it run.
  final String runAt;

  /// The script source, verbatim (de-indented, trimmed).
  final String source;

  /// The language as a short label (`JavaScript`, `FormCalc`).
  String get languageLabel => language.toLowerCase().contains('javascript')
      ? 'JavaScript'
      : language.toLowerCase().contains('formcalc')
      ? 'FormCalc'
      : language;
}

/// A field's data binding.
class XfaBinding extends XfaElement {
  XfaBinding({
    required String fieldSom,
    required super.attrs,
    required this.match,
    required this.ref,
    required this.ui,
    required this.picture,
    required this.calculate,
  }) : super(kind: XfaKind.other, tag: 'bind', som: fieldSom, name: null);

  /// `bind match`: `dataRef` (bound to [ref]), `global` or `none`.
  final String match;

  /// The data node it binds (`data.HEADER.TITLE`), null when none.
  final String? ref;

  /// The bound field's widget (`textEdit`, `numericEdit`, …).
  final String ui;

  /// The value picture clause (`date{DD.MM.YYYY}`), null when none.
  final String? picture;

  /// The calculate script's source when the field computes its value.
  final String? calculate;
}

class XfaFont {
  const XfaFont({this.typeface, this.size, this.weight, this.posture});
  final String? typeface;
  final double? size;
  final String? weight; // normal / bold
  final String? posture; // normal / italic

  bool get bold => weight?.toLowerCase() == 'bold';
  bool get italic => posture?.toLowerCase() == 'italic';
}

class XfaColor {
  const XfaColor(this.r, this.g, this.b);
  final int r, g, b;

  /// `#rrggbb` as a color, null when absent / another form.
  static XfaColor? of(String? c) {
    if (c == null) return null;
    final h = c.trim().replaceFirst('#', '');
    if (h.length == 6 && h.codeUnits.every(_isHex)) {
      return XfaColor(
        int.parse(h.substring(0, 2), radix: 16),
        int.parse(h.substring(2, 4), radix: 16),
        int.parse(h.substring(4, 6), radix: 16),
      );
    }
    return null;
  }
}

bool _isHex(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x46) ||
    (c >= 0x61 && c <= 0x66);

class XfaEdge {
  const XfaEdge({required this.thickness, required this.presence, this.color});
  final double thickness; // in points
  final String presence; // visible / invisible / hidden
  final XfaColor? color;
}

class XfaImage {
  const XfaImage({required this.contentType, required this.base64});
  final String contentType;
  final String base64;
}

/// A `subform`: the container. Its [layout] drives how the geometry pass
/// places its children; `occur min` bounds its repetition (a table row).
class XfaSubform extends XfaElement {
  XfaSubform({
    required super.som,
    super.name,
    required super.attrs,
    required this.layout,
    required super.children,
    required this.occurrences,
  }) : super(kind: XfaKind.subform, tag: 'subform');

  /// `position`, `tb`, `lr-tb`, `rl-tb` (empty: inherit `tb`).
  final String layout;

  /// How many copies the geometry pass lays out (`occur` min, >= 1).
  final int occurrences;

  late final List<XfaElement> laidOut = [
    for (final c in children)
      if (c.rect != null) c,
  ];
}

/// The read, laid-out form.
class XfaForm {
  XfaForm({
    required this.generator,
    required this.packets,
    required this.root,
    required this.pages,
    required this.elements,
    required this.source,
  });

  /// The `<?xfa generator="…">` note (the Designer build that saved it).
  final String? generator;

  /// The XDP's packet names (`template`, `config`, `localeSet`, …).
  final List<String> packets;

  final XfaSubform? root;
  final List<XfaPageArea> pages;

  /// Every element read, in document order (the structure tree's rows).
  final List<XfaElement> elements;

  /// The raw XML text (the Source tab shows it).
  final String source;

  late final List<XfaScript> scripts = [
    for (final e in elements)
      if (e is XfaScript) e,
  ];

  late final List<XfaBinding> bindings = [
    for (final e in elements)
      if (e is XfaBinding) e,
  ];

  /// The placed elements that have a rectangle, in paint order.
  late final List<XfaPlaced> placed = [
    for (final e in elements)
      if (e is XfaPlaced && e.rect != null) e,
  ];
}

// ---------------------------------------------------------------------------
// The reader
// ---------------------------------------------------------------------------

class _Reader {
  final List<XfaElement> elements = [];
  final List<XfaPageArea> pages = [];
  final List<String> _som = [];

  static const _ptPerUnit = {
    'in': 72.0,
    'pt': 1.0,
    'pc': 12.0,
    'cm': 72.0 / 2.54,
    'mm': 72.0 / 25.4,
    'px': 0.75,
    'em': 12.0,
  };

  /// An XFA measurement as points ("10mm", "0.5in", "72pt", "3"), null
  /// when absent / unparsable; a percent scales [whole] when given.
  static double? pt(String? v, {double? whole}) {
    if (v == null) return null;
    final s = v.trim();
    if (s.isEmpty) return null;
    if (s.endsWith('%')) {
      final p = double.tryParse(s.substring(0, s.length - 1));
      return p == null || whole == null ? null : whole * p / 100;
    }
    var i = 0;
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      final numeric =
          (c >= 0x30 && c <= 0x39) || c == 0x2e || c == 0x2c || c == 0x2d;
      if (!numeric) break;
      i++;
    }
    final n = double.tryParse(s.substring(0, i).replaceAll(',', '.'));
    if (n == null) return null;
    final unit = s.substring(i).trim().toLowerCase();
    if (unit.isEmpty) return n; // XFA's unitless default: points
    final per = _ptPerUnit[unit];
    return per == null ? null : n * per;
  }

  // --- tree -----------------------------------------------------------------

  XfaSubform readSubform(XmlElement e) {
    final name = e.getAttribute('name');
    final (som, pushed) = _push(name);
    final s = XfaSubform(
      som: som,
      name: name,
      attrs: _attrsOf(e),
      layout: (e.getAttribute('layout') ?? '').trim().toLowerCase(),
      children: [],
      occurrences: _occurrencesOf(e),
    );
    elements.add(s);
    for (final c in e.childElements) {
      switch (c.name.local) {
        case 'pageSet':
          s.children.add(_readPageSet(c));
        case 'subform':
          s.children.add(readSubform(c));
        case 'field':
          s.children.add(_readPlaced(c, XfaKind.field));
        case 'draw':
          s.children.add(_readPlaced(c, XfaKind.draw));
        default:
          // bind / calculate / validate / event / margin / … : not laid
          // out; their scripts and bindings are collected for this subform
          _collectNested(c);
      }
    }
    if (pushed) _som.removeLast();
    return s;
  }

  XfaElement _readPageSet(XmlElement e) {
    final name = e.getAttribute('name');
    final (som, pushed) = _push(name);
    final s = XfaElement(
      kind: XfaKind.pageSet,
      tag: e.name.local,
      som: som,
      name: name,
      attrs: _attrsOf(e),
      children: [],
    );
    elements.add(s);
    for (final c in e.childElements) {
      switch (c.name.local) {
        case 'pageArea':
          s.children.add(_readPageArea(c));
        case 'pageSet':
          s.children.add(_readPageSet(c));
      }
    }
    if (pushed) _som.removeLast();
    return s;
  }

  XfaElement _readPageArea(XmlElement e) {
    final name = e.getAttribute('name') ??
        e.getAttribute('id') ??
        'Page${pages.length + 1}';
    final w = pt(e.getAttribute('w'), whole: 595.28) ?? 595.28;
    final h = pt(e.getAttribute('h'), whole: 841.89) ?? 841.89;
    final orient = (e.getAttribute('orient') ?? '').toLowerCase();
    pages.add(XfaPageArea(
      name: name,
      w: w,
      h: h,
      landscape:
          orient == 'landscape' || (w > h && orient != 'portrait'),
    ));
    final (som, pushed) = _push(name);
    final node = XfaElement(
      kind: XfaKind.pageArea,
      tag: 'pageArea',
      som: som,
      name: name,
      attrs: _attrsOf(e),
      children: [],
    )
      ..rect = XfaRect(0, 0, w, h)
      ..page = pages.length - 1;
    elements.add(node);
    for (final c in e.childElements) {
      if (c.name.local == 'subform') {
        node.children.add(readSubform(c));
      }
    }
    if (pushed) _som.removeLast();
    return node;
  }

  XfaPlaced _readPlaced(XmlElement e, XfaKind kind) {
    final name = e.getAttribute('name');
    final (som, pushed) = _push(name);
    final p = XfaPlaced(
      kind: kind,
      tag: e.name.local,
      som: som,
      name: name,
      attrs: _attrsOf(e),
      ui: _uiOf(e),
      text: _textOf(e),
      font: _fontOf(e),
      border: _borderOf(e),
      fill: _fillOf(e),
      image: _imageOf(e),
      access: e.getAttribute('access'),
      captionText: _captionOf(e),
    );
    elements.add(p);
    _collectNested(e);
    if (pushed) _som.removeLast();
    return p;
  }

  /// The scripts and bindings under [e], recursively — attributed to the
  /// SOM path of the element currently being read.
  void _collectNested(XmlElement e) {
    for (final c in e.childElements) {
      switch (c.name.local) {
        case 'event':
          final activity = c.getAttribute('activity');
          for (final s in c.childElements) {
            if (s.name.local == 'script') _readScript(s, activity);
          }
        case 'script':
          _readScript(c, null);
        case 'calculate':
          for (final s in c.childElements) {
            if (s.name.local == 'script') _readScript(s, 'calculate');
          }
        case 'validate':
          for (final s in c.childElements) {
            if (s.name.local == 'script') _readScript(s, 'validate');
          }
        case 'bind':
          _readBinding(c);
          _collectNested(c); // its calculate script also lists as a script
        default:
          _collectNested(c);
      }
    }
  }

  void _readScript(XmlElement e, String? activity) {
    final owner = _som.isEmpty ? '' : _som.join('.');
    elements.add(XfaScript(
      som: owner,
      attrs: _attrsOf(e),
      event: owner,
      activity: activity,
      language:
          e.getAttribute('contentType') ?? 'application/x-formcalc',
      runAt: e.getAttribute('runAt') ?? 'client',
      source: deIndent(e.innerText),
    ));
  }

  void _readBinding(XmlElement e) {
    final fieldSom = _som.isEmpty ? '' : _som.join('.');
    String? picture;
    String? calculate;
    for (final c in e.childElements) {
      if (c.name.local == 'picture' && picture == null) {
        final t = c.innerText.trim();
        picture = t.isNotEmpty ? t : c.getAttribute('picture');
      } else if (c.name.local == 'calculate') {
        for (final s in c.childElements) {
          if (s.name.local == 'script') calculate = deIndent(s.innerText);
        }
      }
    }
    final ui = elements
        .whereType<XfaPlaced>()
        .lastWhereOrNull((p) => p.som == fieldSom)
        ?.ui;
    elements.add(XfaBinding(
      fieldSom: fieldSom,
      attrs: _attrsOf(e),
      match: e.getAttribute('match') ?? 'dataRef',
      ref: e.getAttribute('ref'),
      ui: ui ?? '',
      picture: picture,
      calculate: calculate,
    ));
  }

  // --- text and styling -------------------------------------------------

  String _uiOf(XmlElement e) {
    if (e.name.local == 'draw') {
      final v = _child(e, 'value');
      if (v != null) {
        for (final c in v.childElements) {
          return c.name.local; // text / line / rect / image / barcode
        }
      }
      return 'text';
    }
    final ui = _child(e, 'ui');
    if (ui != null) {
      for (final c in ui.childElements) {
        if (c.name.local != 'extras' && c.name.local != 'picture') {
          return c.name.local;
        }
      }
    }
    return 'textEdit';
  }

  String _textOf(XmlElement e) {
    final v = _child(e, 'value');
    if (v != null) {
      final t = _child(v, 'text');
      if (t != null) return _textOfNode(t);
      final ex = _child(v, 'exData');
      if (ex != null) return _textOfNode(ex);
    }
    final cap = _captionOf(e);
    if (cap != null) return cap;
    if (e.name.local == 'field') {
      // a choice list's first save/show item
      final items = _child(e, 'items');
      if (items != null) {
        for (final it in items.childElements) {
          if (it.name.local == 'text') {
            final t = _textOfNode(it);
            if (t.isNotEmpty) return t;
          }
        }
      }
    }
    return '';
  }

  String _textOfNode(XmlElement t) {
    // <text> holds plain text or an embedded XHTML <body>
    final body = t.childElements
        .where((e) => e.name.local == 'body')
        .firstOrNull;
    if (body != null) return _xhtmlText(body);
    return t.innerText.trim();
  }

  String _xhtmlText(XmlElement body) {
    final out = StringBuffer();
    void walk(XmlElement e) {
      for (final n in e.children) {
        if (n is XmlText) {
          out.write(n.value);
        } else if (n is XmlElement) {
          if (n.name.local == 'br') out.write('\n');
          if (n.name.local == 'p' && out.isNotEmpty) out.write('\n');
          walk(n);
        }
      }
    }

    walk(body);
    return out.toString().trim();
  }

  String? _captionOf(XmlElement e) {
    final cap = _child(e, 'caption');
    if (cap == null) return null;
    final v = _child(cap, 'value');
    if (v != null) {
      final t = _child(v, 'text');
      if (t != null) return _textOfNode(t);
    }
    return null;
  }

  XfaFont? _fontOf(XmlElement e) {
    final font = _firstDescendant(e, 'font');
    if (font == null) return null;
    return XfaFont(
      typeface:
          _firstDescendant(font, 'typeface')?.getAttribute('name') ??
              font.getAttribute('typeface'),
      size: pt(font.getAttribute('size')),
      weight: font.getAttribute('weight'),
      posture: font.getAttribute('posture'),
    );
  }

  List<XfaEdge> _borderOf(XmlElement e) {
    final b = _firstDescendant(e, 'border');
    if (b == null) return const [];
    return [
      for (final edge in b.childElements.where((x) => x.name.local == 'edge'))
        XfaEdge(
          thickness: pt(edge.getAttribute('thickness')) ?? 0.5,
          presence: edge.getAttribute('presence') ?? 'visible',
          color: XfaColor.of(edge.getAttribute('color')),
        ),
    ];
  }

  XfaColor? _fillOf(XmlElement e) {
    final b = _firstDescendant(e, 'border');
    if (b == null) return null;
    final fill = _child(b, 'fill');
    if (fill == null) return null;
    return XfaColor.of(_firstDescendant(fill, 'color')?.getAttribute('value'));
  }

  XfaImage? _imageOf(XmlElement e) {
    final img = _firstDescendant(e, 'image');
    if (img == null) return null;
    final data = img.innerText.trim();
    if (data.isEmpty) return null;
    return XfaImage(
      contentType: img.getAttribute('contentType') ?? 'image/png',
      base64: data.replaceAll(RegExp(r'\s'), ''),
    );
  }

  XmlElement? _child(XmlElement e, String name) =>
      e.childElements.where((x) => x.name.local == name).firstOrNull;

  XmlElement? _firstDescendant(XmlElement e, String name) {
    for (final c in e.descendantElements) {
      if (c.name.local == name) return c;
    }
    return null;
  }

  Map<String, String> _attrsOf(XmlElement e) => {
        for (final a in e.attributes) a.name.local: a.value,
      };

  int _occurrencesOf(XmlElement e) {
    final occur = _child(e, 'occur');
    if (occur == null) return 1;
    final min = int.tryParse(occur.getAttribute('min')?.trim() ?? '') ?? 1;
    return min.clamp(1, 50);
  }

  /// Appends [name] to the SOM chain when non-empty; the caller pops it
  /// from [_som] only when [pushed] is true.
  (String, bool) _push(String? name) {
    final pushed = (name ?? '').isNotEmpty;
    if (pushed) _som.add(name!);
    return (_som.join('.'), pushed);
  }

  /// A script's source, de-indented to its first line and trimmed.
  static String deIndent(String s) {
    final lines = s.split('\n');
    while (lines.isNotEmpty && lines.first.trim().isEmpty) {
      lines.removeAt(0);
    }
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    if (lines.isEmpty) return '';
    final indent = lines.first.length - lines.first.trimLeft().length;
    return [
      for (var i = 0; i < lines.length; i++)
        i == 0 || lines[i].length < indent
            ? lines[i].trimRight()
            : lines[i].substring(indent).trimRight(),
    ].join('\n').trim();
  }
}

extension _LastWhereOrNull<T> on Iterable<T> {
  T? lastWhereOrNull(bool Function(T) f) {
    T? found;
    for (final v in this) {
      if (f(v)) found = v;
    }
    return found;
  }
}

// ---------------------------------------------------------------------------
// The geometry pass
// ---------------------------------------------------------------------------

/// Lays [form] out: subforms per their `layout` (`position` places the
/// children at their `x`/`y`, `tb` stacks them, `lr-tb` wraps), the placed
/// elements inside them. Mutates the elements' [XfaElement.rect]s and
/// [XfaElement.page]s — `readXdp` has already run it.
void layoutXfaForm(XfaForm form) {
  final root = form.root;
  if (root == null) return;
  // the subforms of every pageArea start at their page's origin (plus
  // their own x/y when declared); the flowed children of the root (not
  // under a pageArea) stack on the page the last pageArea declared, below
  // its content — a read-only approximation of XFA's content flowing
  // through the pageSet
  var page = 0;
  var flowed = 0.0;
  for (final child in root.children) {
    switch (child.kind) {
      case XfaKind.pageSet:
        // a pageSet's children are the pageAreas themselves
        for (final area in child.children) {
          page = area.page;
          var y = 0.0;
          for (final sub in area.children) {
            if (sub is XfaSubform && sub.rect == null) {
              final a = form.pages[page.clamp(0, form.pages.length - 1)];
              _layoutSubform(
                sub,
                a,
                _Reader.pt(sub.attrs['x'], whole: a.w) ?? 0,
                y + (_Reader.pt(sub.attrs['y'], whole: a.h) ?? 0),
                page,
              );
              y = sub.rect!.bottom;
            }
          }
          flowed = y;
        }
      default:
        if (child is XfaSubform && child.rect == null) {
          final a = form.pages[page.clamp(0, form.pages.length - 1)];
          _layoutSubform(
            child,
            a,
            _Reader.pt(child.attrs['x'], whole: a.w) ?? 0,
            flowed + (_Reader.pt(child.attrs['y'], whole: a.h) ?? 0),
            page,
          );
          flowed = child.rect!.bottom;
        }
    }
  }
}

void _layoutSubform(
    XfaSubform s, XfaPageArea page, double ox, double oy, int pageIndex) {
  final w = _Reader.pt(s.attrs['w'], whole: page.w) ?? page.w;
  final h = _Reader.pt(s.attrs['h'], whole: page.h) ??
      _stackedHeight(s, w);
  s.rect = XfaRect(ox, oy, w, h);
  s.page = pageIndex;
  switch (s.layout.isEmpty ? 'tb' : s.layout) {
    case 'position':
      for (final c in s.children) {
        if (c.rect != null) continue;
        final cw = _Reader.pt(c.attrs['w'], whole: w) ?? _autoWidth(c, w);
        final ch = _Reader.pt(c.attrs['h'], whole: h) ?? _autoHeight(c, cw);
        _place(c, page, ox + (_Reader.pt(c.attrs['x'], whole: w) ?? 0),
            oy + (_Reader.pt(c.attrs['y'], whole: h) ?? 0), cw, ch, pageIndex);
      }
    case 'lr-tb':
      var x = ox, y = oy, rowH = 0.0;
      for (final c in s.children) {
        if (c.rect != null) continue;
        final cw = _Reader.pt(c.attrs['w'], whole: w) ?? _autoWidth(c, w);
        final ch = _Reader.pt(c.attrs['h'], whole: h) ?? _autoHeight(c, cw);
        if (x > ox && x + cw > ox + w) {
          x = ox;
          y += rowH;
          rowH = 0;
        }
        _place(c, page, x, y, cw, ch, pageIndex);
        x += cw;
        if (ch > rowH) rowH = ch;
      }
    default: // tb (and rl-tb, stacked for the read-only view)
      var y = oy;
      for (final c in s.children) {
        if (c.rect != null) continue;
        final cw = _Reader.pt(c.attrs['w'], whole: w) ?? _autoWidth(c, w);
        final ch = _Reader.pt(c.attrs['h'], whole: h) ?? _autoHeight(c, cw);
        _place(
          c,
          page,
          ox + (_Reader.pt(c.attrs['x'], whole: w) ?? 0),
          y,
          cw,
          ch,
          pageIndex,
        );
        y += ch;
      }
  }
}

void _place(XfaElement c, XfaPageArea page, double x, double y, double w,
    double h, int pageIndex) {
  switch (c) {
    case XfaSubform s:
      _layoutSubform(s, page, x, y, pageIndex);
    case XfaPlaced p:
      p.rect = XfaRect(x, y, w, h);
      p.page = pageIndex;
    default:
      c.rect = null;
  }
}

/// The height a subform without one takes: its children stacked.
double _stackedHeight(XfaSubform s, double w) {
  var total = 0.0;
  for (final c in s.children) {
    if (c is XfaPlaced) {
      total += _Reader.pt(c.attrs['h'], whole: w) ?? _autoHeight(c, w);
    } else if (c is XfaSubform) {
      final cw = _Reader.pt(c.attrs['w'], whole: w) ?? w;
      total +=
          _Reader.pt(c.attrs['h'], whole: cw) ?? _stackedHeight(c, cw);
    }
  }
  return total > 0 ? total : 20;
}

double _autoHeight(XfaElement e, double w) {
  if (e is XfaPlaced) {
    final size = e.font?.size ?? 10;
    final lines = e.text.isEmpty
        ? 1
        : (e.text.length / (w / (size * 0.5))).ceil().clamp(1, 200);
    return size * 1.35 * lines + 4;
  }
  return 14;
}

double _autoWidth(XfaElement e, double parentW) {
  if (e is XfaPlaced) {
    final size = e.font?.size ?? 10;
    return (e.text.length * size * 0.5).clamp(30.0, parentW);
  }
  return parentW;
}
