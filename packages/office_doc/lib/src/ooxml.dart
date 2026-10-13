/// Shared OOXML package plumbing: part lookup through the relationships,
/// namespace-agnostic element / attribute access, XML text escaping.
library;

import 'package:xml/xml.dart';

import 'zip.dart';

/// Parses [text] as XML; DTDs / entities are not expanded by `package:xml`
/// beyond the five predefined ones, so a hostile part cannot blow up.
XmlDocument? parseXmlPart(String? text) {
  if (text == null) return null;
  try {
    return XmlDocument.parse(text);
  } on XmlException {
    return null;
  }
}

/// The package's main part (`_rels/.rels` officeDocument relationship),
/// else [fallback].
String mainPartOf(ZipReader zip, String fallback) {
  final rels = parseXmlPart(zip.readText('_rels/.rels'));
  if (rels != null) {
    for (final r in rels.findAllElements('Relationship', namespace: '*')) {
      final type = r.getAttribute('Type') ?? '';
      if (type.endsWith('/officeDocument')) {
        final t = r.getAttribute('Target') ?? '';
        if (t.isNotEmpty) return resolvePartPath('', t);
      }
    }
  }
  return fallback;
}

/// The relationships of [part] (`dir/_rels/name.rels`): (id, type, part
/// path) of each internal target.
List<(String, String, String)> relationshipsOf(ZipReader zip, String part) {
  final slash = part.lastIndexOf('/');
  final dir = slash < 0 ? '' : part.substring(0, slash);
  final name = part.substring(slash + 1);
  final relsPath = dir.isEmpty ? '_rels/$name.rels' : '$dir/_rels/$name.rels';
  final rels = parseXmlPart(zip.readText(relsPath));
  final out = <(String, String, String)>[];
  if (rels == null) return out;
  for (final r in rels.findAllElements('Relationship', namespace: '*')) {
    final id = r.getAttribute('Id');
    final t = r.getAttribute('Target');
    if (id == null || t == null) continue;
    if (r.getAttribute('TargetMode') == 'External') continue;
    out.add((id, r.getAttribute('Type') ?? '', resolvePartPath(dir, t)));
  }
  return out;
}

/// The part [part] relates to by a relationship type ending [typeSuffix]
/// (`/styles`, `/sharedStrings`), if any.
String? relatedPart(ZipReader zip, String part, String typeSuffix) {
  for (final (_, type, path) in relationshipsOf(zip, part)) {
    if (type.endsWith(typeSuffix)) return path;
  }
  return null;
}

/// [target] relative to the directory [dir] ('' = package root; a leading
/// `/` is package-absolute), `..` segments folded.
String resolvePartPath(String dir, String target) {
  final segs = <String>[];
  final base = target.startsWith('/') ? '' : dir;
  for (final s in [...base.split('/'), ...target.split('/')]) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') {
      if (segs.isNotEmpty) segs.removeLast();
    } else {
      segs.add(s);
    }
  }
  return segs.join('/');
}

/// The attribute named [local] in any namespace (`w:val`, `val`).
String? attr(XmlElement e, String local) {
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

/// The first child element named [local] (any namespace).
XmlElement? child(XmlElement e, String local) {
  for (final c in e.childElements) {
    if (c.name.local == local) return c;
  }
  return null;
}

Iterable<XmlElement> children(XmlElement e, String local) =>
    e.childElements.where((c) => c.name.local == local);

/// An OOXML on/off property (`<w:b/>`, `<w:b w:val="0"/>`), null if absent.
bool? onOff(XmlElement? e) {
  if (e == null) return null;
  final v = attr(e, 'val');
  return v == null || !(v == '0' || v == 'false' || v == 'off' || v == 'none');
}

/// [s] escaped for XML text / attribute content; characters XML 1.0 forbids
/// (C0 controls other than tab / newline / CR, unpaired surrogates, U+FFFE/F)
/// are dropped.
String xmlEscape(String s) {
  final b = StringBuffer();
  final units = s.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final c = units[i];
    if (c >= 0xd800 && c <= 0xdbff) {
      if (i + 1 < units.length &&
          units[i + 1] >= 0xdc00 &&
          units[i + 1] <= 0xdfff) {
        b.writeCharCode(c);
        b.writeCharCode(units[++i]);
      }
      continue;
    }
    if (c >= 0xdc00 && c <= 0xdfff) continue;
    switch (c) {
      case 0x26:
        b.write('&amp;');
      case 0x3c:
        b.write('&lt;');
      case 0x3e:
        b.write('&gt;');
      case 0x22:
        b.write('&quot;');
      case 0x09 || 0x0a || 0x0d:
        b.writeCharCode(c);
      default:
        if (c < 0x20 || c == 0xfffe || c == 0xffff) continue;
        b.writeCharCode(c);
    }
  }
  return b.toString();
}

/// `docProps/core.xml`'s `dc:title`, if any.
String? coreTitle(ZipReader zip) {
  final core = parseXmlPart(zip.readText('docProps/core.xml'));
  if (core == null) return null;
  for (final t in core.descendantElements) {
    if (t.name.local == 'title') {
      final s = t.innerText.trim();
      if (s.isNotEmpty) return s;
    }
  }
  return null;
}

/// A minimal `docProps/core.xml` carrying [title].
String corePropsXml(String? title) =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
    'xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
    '${title == null || title.isEmpty ? '' : '<dc:title>${xmlEscape(title)}</dc:title>'}'
    '<dc:creator>GuiGo</dc:creator>'
    '</cp:coreProperties>';
