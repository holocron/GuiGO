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

import 'dart:convert' show LineSplitter, utf8;
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
    this.captionPlace = 'left',
    this.captionReserve,
    this.captionFont,
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

  /// Where the caption sits relative to the widget (`left` — XFA's
  /// default — `right`, `top`, `bottom`).
  final String captionPlace;

  /// The caption's reserved minimum along its axis, in points, null when
  /// the caption declared none (the estimate then sizes it).
  final double? captionReserve;

  /// The caption element's own font, null when it inherits the field's.
  final XfaFont? captionFont;

  /// Where the geometry pass put the caption (inside [rect], on the
  /// [captionPlace] side); null when the field carries no caption.
  XfaRect? captionRect;

  /// Where the geometry pass put the widget proper: [rect] minus the
  /// caption's share. Null when the widget takes the whole field rect.
  XfaRect? widgetRect;
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

  /// `position` (empty: XFA's default), `tb`, `lr-tb`, `rl-tb`, `row`.
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

  /// [source] as lines (the Source tab's rows, built as they scroll into
  /// view): a CRLF a Windows Designer or a server round trip left in the
  /// template splits like a bare LF, no '\r' rides a row.
  late final List<String> lines = const LineSplitter().convert(source);

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
    final cap = _child(e, 'caption');
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
      captionPlace:
          (cap?.getAttribute('place') ?? 'left').trim().toLowerCase(),
      captionReserve: cap == null ? null : pt(cap.getAttribute('reserve')),
      captionFont: cap == null ? null : _fontOf(cap),
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
    // the caption is NOT the widget's text: it is laid out and painted in
    // its own area beside the widget (captionRect), so a field with an
    // empty value shows an empty box next to its label
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
        // a pageSet's children are the pageAreas themselves; a pageArea
        // places its subforms like a positioned container: a declared
        // y is ABSOLUTE from the content origin (FOOTER pinned at the
        // page bottom, HEADER_TEXT right under the header), and a MISSING
        // y flows the subform directly below the previously-placed one
        // (XFA 3.3 §5.5 — MAIN, the paginating body, has no y)
        for (final area in child.children) {
          page = area.page;
          var flow = 0.0;
          for (final sub in area.children) {
            if (sub is XfaSubform && sub.rect == null) {
              final a = form.pages[page.clamp(0, form.pages.length - 1)];
              _layoutSubform(
                sub,
                a,
                _Reader.pt(sub.attrs['x'], whole: a.w) ?? 0,
                _Reader.pt(sub.attrs['y'], whole: a.h) ?? flow,
                page,
              );
              flow = sub.rect!.bottom;
            }
          }
          flowed = flow;
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
  // XFA 3.3 §4.4.1: a subform without `layout` is a POSITIONED container —
  // its children sit at their declared x/y. Treating that as tb stacked
  // the positioned cells of a Designer table row onto successive lines
  // (every column one step lower and further right).
  switch (s.layout.isEmpty ? 'position' : s.layout) {
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
        // a flowed child wider than its container is clamped to it (the
        // 55mm page-number fields inside a 29mm column), then wrapped
        // when the line's remaining space cannot take it
        final cw = (_Reader.pt(c.attrs['w'], whole: w) ?? _autoWidth(c, w))
            .clamp(0.0, w);
        final ch = _Reader.pt(c.attrs['h'], whole: h) ?? _autoHeight(c, cw);
        // the hair of tolerance: a full-width cell pair (mm-rounded widths
        // summing to the container's own mm width) must not wrap on
        // 1e-10pt of drift
        if (x > ox && x + cw > ox + w + 0.75) {
          x = ox;
          y += rowH;
          rowH = 0;
        }
        _place(c, page, x, y, cw, ch, pageIndex);
        x += cw;
        // the LAID height (a subform child's own pass), not the estimate
        final bottom = c.rect?.bottom ?? y + ch;
        if (bottom - y > rowH) rowH = bottom - y;
      }
    case 'row':
      // XFA's table row (the Designer's Table object): the cells share ONE
      // line, side by side — stacking them (the tb default) painted every
      // cell on its own line. A declared x anchors the cell at that
      // offset; a declared y nudges it inside the row.
      var cursor = ox;
      for (final c in s.children) {
        if (c.rect != null) continue;
        final cw = (_Reader.pt(c.attrs['w'], whole: w) ?? _autoWidth(c, w))
            .clamp(0.0, w);
        final ch = _Reader.pt(c.attrs['h'], whole: h) ?? _autoHeight(c, cw);
        final cx = _Reader.pt(c.attrs['x'], whole: w) ?? cursor;
        final cy = _Reader.pt(c.attrs['y'], whole: h) ?? 0;
        _place(c, page, cx, oy + cy, cw, ch, pageIndex);
        if (cx + cw > cursor) cursor = cx + cw;
      }
    default: // tb (and rl-tb, stacked for the read-only view)
      var y = oy;
      for (final c in s.children) {
        if (c.rect != null) continue;
        final cw = (_Reader.pt(c.attrs['w'], whole: w) ?? _autoWidth(c, w))
            .clamp(0.0, w);
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
        // advance past what the child actually took: a subform's own pass
        // sizes it (a row of cells is ONE line), the flat estimate is only
        // the fallback
        y = c.rect?.bottom ?? y + ch;
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
      _layoutCaption(p, x, y, w, h);
    default:
      c.rect = null;
  }
}

/// Splits a captioned field's rect: the caption takes its side
/// (`captionPlace`, `captionReserve` at minimum, grown to fit the text),
/// the widget takes what is left.
void _layoutCaption(XfaPlaced p, double x, double y, double w, double h) {
  if (p.captionText == null) return;
  final reserve = p.captionReserve ?? 0;
  switch (p.captionPlace) {
    case 'right':
    case 'left':
      final capW = _captionExtent(p, reserve, w);
      final leftward = p.captionPlace != 'right';
      p.captionRect =
          XfaRect(leftward ? x : x + w - capW, y, capW, h);
      p.widgetRect = XfaRect(
          leftward ? x + capW : x, y, (w - capW).clamp(0.0, w), h);
    case 'bottom':
    case 'top':
      final size = p.captionFont?.size ?? p.font?.size ?? 10;
      final capH = (reserve > 0 ? reserve : size * 1.5).clamp(0.0, h);
      final upward = p.captionPlace != 'bottom';
      p.captionRect = XfaRect(x, upward ? y : y + h - capH, w, capH);
      p.widgetRect =
          XfaRect(x, upward ? y + capH : y, w, (h - capH).clamp(0.0, h));
  }
}

/// The caption's share of the field's cross axis: the declared reserve
/// grown to the estimated text width, never beyond the field itself.
double _captionExtent(XfaPlaced p, double reserve, double w) {
  final size = p.captionFont?.size ?? p.font?.size ?? 10;
  final estimate = (p.captionText ?? '').length * size * 0.5;
  return (estimate > reserve ? estimate : reserve).clamp(0.0, w);
}

/// The height a subform without one takes: its children stacked.
double _stackedHeight(XfaSubform s, double w) {
  // a row (one line of cells) is as tall as its tallest cell, not the sum
  if (s.layout == 'row') {
    var tallest = 0.0;
    for (final c in s.children) {
      final cw =
          c is XfaSubform ? (_Reader.pt(c.attrs['w'], whole: w) ?? w) : w;
      final ch = _Reader.pt(c.attrs['h'], whole: cw) ?? _autoHeight(c, cw);
      if (ch > tallest) tallest = ch;
    }
    return tallest > 0 ? tallest : 20;
  }
  // a positioned container is as tall as its lowest child (its children
  // carry absolute y), not the sum of their heights
  if (s.layout.isEmpty || s.layout == 'position') {
    var lowest = 0.0;
    for (final c in s.children) {
      final cw =
          c is XfaSubform ? (_Reader.pt(c.attrs['w'], whole: w) ?? w) : w;
      final ch = c is XfaPlaced
          ? (_Reader.pt(c.attrs['h'], whole: cw) ?? _autoHeight(c, cw))
          : (_Reader.pt(c.attrs['h'], whole: cw) ??
              _stackedHeight(c as XfaSubform, cw));
      final bottom =
          (_Reader.pt(c.attrs['y'], whole: w) ?? 0) + ch;
      if (bottom > lowest) lowest = bottom;
    }
    return lowest > 0 ? lowest : 20;
  }
  // an lr-tb container: its children wrapped into rows, one estimate pass
  if (s.layout == 'lr-tb' || s.layout == 'rl-tb') {
    var x = 0.0, rows = 0.0, rowH = 0.0;
    for (final c in s.children) {
      final cw = c is XfaSubform
          ? (_Reader.pt(c.attrs['w'], whole: w) ?? w)
          : (_Reader.pt(c.attrs['w'], whole: w) ?? _autoWidth(c, w));
      final ch = c is XfaSubform
          ? (_Reader.pt(c.attrs['h'], whole: cw) ??
              _stackedHeight(c, cw))
          : (_Reader.pt(c.attrs['h'], whole: cw) ?? _autoHeight(c, cw));
      if (x > 0 && x + cw > w + 0.75) {
        rows += rowH;
        x = 0;
        rowH = 0;
      }
      x += cw;
      if (ch > rowH) rowH = ch;
    }
    final total = rows + rowH;
    return total > 0 ? total : 20;
  }
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
    final perLine = w <= 1 ? size * 80.0 : w / (size * 0.5);
    final lines = e.text.isEmpty
        ? 1
        : (e.text.length / perLine).ceil().clamp(1, 200);
    return size * 1.35 * lines + 4;
  }
  return 14;
}

double _autoWidth(XfaElement e, double parentW) {
  if (e is XfaPlaced) {
    final size = e.font?.size ?? 10;
    // clamp(lower, upper) throws when lower > upper: a parent narrower
    // than the floor would crash the whole layout
    final want = e.text.length * size * 0.5;
    return want < 4 ? 4.0 : (want > parentW ? parentW : want);
  }
  return parentW;
}
