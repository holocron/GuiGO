/// The HTML viewer control (CL_GUI_HTML_VIEWER — Windows `SAP.HTMLControl.1`
/// / SAPHTML.OCX, Java `SapHtmlViewer`) and the documents the server feeds
/// it over DIAG.
///
/// The viewer is created like any CFW control; its document arrives as a
/// DataProvider push (SAPLCNDP DP_PUT_CLIENT_TABLE45A) keyed by a DESURL,
/// and a load verb on the viewer then shows that url:
///
/// * `ShowData('HTML000001.htm', '', 1)` names the pushed document by its
/// last path segment — the F1 Performance Assistant on the test system (live reference client
/// capture a recorded session step 41: DESURL
/// `SAPHTMLP://htmlviewer.sap.com/<prefix>/HTML000001.htm`, TYPE `text`,
/// SUBTYPE `html`, SEND_STRING_DATA `X`, the whole page in the DATASTR
/// scalar, UTF-8 as its meta tag declares);
/// * the opsdash ShowData family carries it in a DATABIN column instead
/// (reference client diag_showdata.assemble_databin_html: one LZH object split in
/// `03 05 … 00 fa` chunks with the DP message-boundary admin header
/// spliced in), the LOAD_DATA family in a DATAASC column
/// (assemble_dataasc_html);
/// * `ShowUrl` / `Url` with an http(s) url is off-DIAG: the frontend's
/// browser fetches the page over HTTP and the bytes never cross this
/// connection (reference client html_offdiag.document_state).
///
/// Links inside such a page are `SAPEVENT:<action>` urls: the browser does
/// not follow them but raises the viewer's SAPEVENT control event (EVENTID
/// 1, `%_GC <shell> 1`: frame, post-data length, the url — the reference client's
/// screen_html / a recorded session).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'dp_cache.dart' show DpCache, dpColumnCells;
import '../lzh/lzh.dart';
import '../screen/screen_layout.dart' show CellRect, ScreenRegion;

/// One document an HTML viewer control shows.
class SapHtmlDocument {
  SapHtmlDocument({
    required this.shell,
    required this.url,
    required this.html,
    this.container,
    this.parts = const {},
    this.dialog,
    this.dialogTitle,
    this.verb = 'ShowData',
    this.step = 0,
  });

  /// The viewer's kernel shell id (the `%_GC <shell> …` target).
  final String shell;

  /// Where it sits: the dynpro custom-control area its container is linked
  /// to (an area name such as `HTML_CONTROL_CON`), else the container shell
  /// that hosts it (the PA's splitter cell `120`).
  final String? container;

  /// The url the viewer was told to show (the DataProvider DESURL, or the
  /// http(s) url of an off-DIAG page).
  final String url;

  /// The decoded document ('' when the page is off-DIAG / not delivered).
  final String html;

  /// The other files pushed beside the document (images, style sheets), by
  /// url — every push under the document's own url directory.
  final Map<String, Uint8List> parts;

  /// The CFW modal dialog (SAPGUI.DIALOGCTRL.1) the viewer lives in, with
  /// its caption ('Performance Assistant'); null on a dynpro.
  final String? dialog;
  final String? dialogTitle;

  /// The load verb (`ShowData`, `ShowUrl`, …) and the step it came at.
  final String verb;
  final int step;

  /// The page reached this connection (not an off-DIAG http page).
  bool get delivered => html.isNotEmpty;

  /// The page as the viewer's browser shows it: [html] with every
  /// `<frameset>` / `<frame src>` / `<iframe src>` replaced by the body of
  /// the pushed part it names (see [inlineHtmlFrames]). A dynamic document
  /// (CL_DD_DOCUMENT — SM04's header, the AIF monitor's selection; by its
  /// live `ShowData(HTML000002.htm)` SACM's quick links too) shows
  /// `HTML000002.htm` = `<frameset><frame name=Frame0 src="HTML000001.htm">`
  /// over its content page; SBWP's start page is `<frameset><frame
  /// SRC="template.htm">`.
  late final String content = parts.isEmpty
      ? html
      : inlineHtmlFrames(html, url, parts);

  // title / text / links / forms are derived once per document like
  // [content] (a document never changes; every UI rebuild read them anew)

  /// The `<title>` of the page (else of the first frame document it shows
  /// that has one), or null.
  late final String? title = _title();

  String? _title() {
    String? titleOf(String h) {
      final m = RegExp(
        r'<title[^>]*>(.*?)</title>',
        caseSensitive: false,
        dotAll: true,
      ).firstMatch(h);
      final t = m == null ? '' : htmlToText(m.group(1)!).trim();
      return t.isEmpty ? null : t;
    }

    if (titleOf(html) case final t?) return t;
    final frameRx = RegExp(r'<i?frame\b([^>]*)>', caseSensitive: false);
    for (final f in frameRx.allMatches(html)) {
      final src = htmlAttributes(f.group(1)!)['src'] ?? '';
      final b = _partFor(src, url, parts);
      if (b == null) continue;
      if (titleOf(decodeHtmlBytes(b)) case final t?) return t;
    }
    return null;
  }

  /// The readable text of the page, frames inlined (see [htmlToText]).
  late final String text = htmlToText(content);

  /// Every `SAPEVENT:` link of the page, frames inlined, in document order
  /// (read-only: shared by every reader).
  late final List<SapHtmlLink> links =
      List.unmodifiable(sapEventLinks(content));

  /// Every `SAPEVENT:` form of the page, frames inlined (see
  /// [sapEventForms]; read-only: shared by every reader).
  late final List<SapHtmlForm> forms =
      List.unmodifiable(sapEventForms(content));

  @override
  String toString() =>
      'SapHtmlDocument(shell $shell in ${container ?? '-'}'
      '${dialog != null ? ' dialog $dialog' : ''}, $url, ${html.length} chars)';
}

/// A `SAPEVENT:` link (`<a href>` or image-map `<area href>`) of a page.
class SapHtmlLink {
  const SapHtmlLink(this.href, this.label, {this.target = ''});

  /// The full href (`SAPEVENT:DOCU_LINK\DS:DE.TABNAME16`).
  final String href;

  /// The link's text (or its alt / title).
  final String label;

  /// The anchor's own `target=` frame name, '' when it names none — what
  /// the Windows OCX reports as the click's FrameName (PID0).
  final String target;

  /// The action after the scheme (`DOCU_LINK\DS:DE.TABNAME16`).
  String get event => href.substring(href.indexOf(':') + 1);

  @override
  String toString() => 'SapHtmlLink($label -> $href)';
}

/// A `<form action="SAPEVENT:…">` of a page — a dynamic document's form
/// (CL_DD_FORM_AREA: `A1F2`, hidden `sapbu_cl` / `sapse_cl` / `sapin_cl`,
/// buttons `A1F2B3NAME:BT_SELECTDT`). The browser submits it as the
/// viewer's SAPEVENT with a POST body (reference client screen_html.sapevent_forms /
/// post_body; real GUI a recorded session gui[38] + gui[41]).
class SapHtmlForm {
  const SapHtmlForm({
    required this.name,
    required this.action,
    required this.fields,
    required this.inputs,
    required this.buttons,
    this.buttonLabels = const {},
    this.frame = '',
  });

  final String name;

  /// The frame the browser navigates for a submit: the form's own
  /// `target=`, else the name of the frameset frame its page is shown in
  /// (HTML000002's `<frame name=Frame0 src="HTML000001.htm">`), as the page
  /// spells it; '' for a form of an unframed page. The Windows OCX reports
  /// it as the sapevent's FrameName, PID0 (a recorded session raw
  /// gui[27]: `Frame0` for /AIF/IFMON's A1F1).
  final String frame;

  /// The action as the page spells it (`SAPEVENT:A1F2`).
  final String action;

  /// The fields a submit posts, in DOM order: (name, painted value).
  final List<(String, String)> fields;

  /// field name -> its control id (`A1F2I1` -> `A1F2I1NAME:INPUT_MAXERR`).
  final Map<String, String> inputs;

  /// The clickable control ids, in document order.
  final List<String> buttons;

  /// button id -> its label (text, value, img alt or title).
  final Map<String, String> buttonLabels;

  /// The sapevent target after the scheme (`A1F2`).
  String get event => action.substring(action.indexOf(':') + 1);

  /// The url the Windows browser reports for a submit: the action with the
  /// scheme lower-cased — the page's `action="SAPEVENT:A1F1"` goes up as
  /// `sapevent:A1F1` (a recorded session raw gui[27] / [40] / [54] /
  /// [86]; a LINK's href goes up as the page spells it, a recorded session
  /// sacm_quicklinks raw gui[10]).
  String get windowsUrl => 'sapevent:$event';

  /// Whether [wanted] names button [id]: its full DOM id or the SAP control
  /// name after `NAME:` (reference client screen_html.control_matches),
  /// case-insensitively.
  static bool controlMatches(String id, String wanted) {
    final c = id.toUpperCase(), w = wanted.trim().toUpperCase();
    return w.isNotEmpty &&
        (c == w || c.endsWith('NAME:$w') || c.endsWith(':$w'));
  }

  /// The button of this form [wanted] names, or null.
  String? buttonOf(String wanted) {
    for (final b in buttons) {
      if (controlMatches(b, wanted)) return b;
    }
    return null;
  }

  /// The body the browser posts when [buttonId] is clicked: the fields in
  /// DOM order, `sapbu_cl` = the button, `sapse_cl` / `sapin_cl` = ' ' (the
  /// page's ButtonClick), the rest their painted value unless [values]
  /// names them (by field name or control id); `name=value` joined by `&`,
  /// not url-encoded (oracle: `sapbu_cl=A1F1B3NAME:BT_SELECTDT&sapse_cl=
  /// &sapin_cl= &A1F1I1=1000`).
  String postBody(String buttonId, {Map<String, String> values = const {}}) {
    final out = <String>[];
    for (final (name, value) in fields) {
      var v = value;
      if (name == 'sapbu_cl') {
        v = buttonId;
      } else if (name == 'sapse_cl' || name == 'sapin_cl') {
        v = ' ';
      } else {
        for (final e in values.entries) {
          if (e.key == name || controlMatches(inputs[name] ?? '', e.key)) {
            v = e.value;
          }
        }
      }
      out.add('$name=$v');
    }
    return out.join('&');
  }

  /// [postBody] as the bytes the browser posts (UTF-8).
  Uint8List postBytes(
    String buttonId, {
    Map<String, String> values = const {},
  }) => Uint8List.fromList(utf8.encode(postBody(buttonId, values: values)));

  @override
  String toString() => 'SapHtmlForm($name -> $action, $buttons)';
}

/// A CFW modal dialog (`SAPGUI.DIALOGCTRL.1`, CL_GUI_DIALOGBOX_CONTAINER):
/// a floating window the server creates over the screen — no dynpro popup
/// paints for it (the screen's modal level stays 0). The F1 Performance
/// Assistant is one: shell 117 "Performance Assistant", a splitter with
/// the toolbar cell and the HTML viewer cell.
class SapCfwDialog {
  const SapCfwDialog({
    required this.shell,
    required this.title,
    required this.rect,
    required this.regions,
    this.toolbar,
    this.buttons = const [],
  });

  final String shell;

  /// The caption (SetProperty 60).
  final String title;

  /// Where it floats, in window cells (its SetProperty left 170 / top 270 /
  /// width 300 / height 120 pixels at the session's pixels per cell).
  final CellRect rect;

  /// The controls it hosts, in window cells: an 'html' region per viewer
  /// (rung 'R10' with its document, 'R7' before it arrives), a 'control' /
  /// 'TB' region per toolbar, 'grid' / 'tree' as in the window composition.
  final List<ScreenRegion> regions;

  /// The toolbar control the dialog hosts (the PA's SAP.Toolbar.1) and its
  /// buttons in AddButton order, with the state the server's latest
  /// SetButtonState set — [SapSession.cfwToolbarButton] clicks one.
  final String? toolbar;
  final List<SapToolbarButton> buttons;

  @override
  String toString() => 'SapCfwDialog($shell "$title" $rect)';
}

/// One button of a CFW toolbar (SAP.Toolbar.1 AddButton(code, icon,
/// enabled, type, text, quickinfo, checked) — the PA's
/// `AddButton(TECH, @45@, 1, 0, '', 'Informations techniques', 0)`;
/// SetButtonState(code, enabled, checked) updates it).
class SapToolbarButton {
  SapToolbarButton({
    required this.code,
    this.icon = '',
    this.text = '',
    this.tooltip = '',
    this.type = 0,
    this.enabled = true,
    this.checked = false,
  });

  final String code;

  /// The SAP icon code (`@45@`), '' for none.
  final String icon;
  final String text;
  final String tooltip;

  /// 0 button, 1 menu button, 2 menu, 3 separator, 4 radio, 5 check box.
  final int type;
  bool enabled;
  bool checked;

  bool get separator => type == 3;

  /// A menu button: 1 split (the body fires [code], the arrow opens the
  /// menu), 2 menu only (the whole button opens it) — control_toolbar.dart.
  bool get hasMenu => type == 1 || type == 2;
  bool get splitMenu => type == 1;

  /// A check (toggle) button: [checked] is its state.
  bool get toggle => type == 5;

  @override
  String toString() =>
      'SapToolbarButton($code $icon "${text.isEmpty ? tooltip : text}"'
      '${enabled ? '' : ' disabled'})';
}

/// One DataProvider push decoded for a viewer: the DESURL, the MIME type
/// the push declares and the content bytes.
class HtmlPush {
  HtmlPush(this.url, this.type, this.subtype, this.bytes);
  final String url;
  final String type;
  final String subtype;
  final Uint8List bytes;

  bool get isHtml =>
      subtype.toLowerCase().contains('htm') || looksLikeHtml(bytes);

  /// The content as text (see [decodeHtmlBytes]).
  String get text => decodeHtmlBytes(bytes);

  @override
  String toString() => 'HtmlPush($url $type/$subtype ${bytes.length} B)';
}

/// The verbs that LOAD a document into a viewer (the reference client's
/// html_offdiag._DOC_LOAD_VERBS: SapBrowser ShowURL / ShowURLInBrowser /
/// ShowURLInDetachedBrowser / ShowData / ShowDataInBrowser and the Url
/// property), case-insensitively.
const Set<String> htmlLoadVerbs = {
  'showurl',
  'showurlinbrowser',
  'showurlindetachedbrowser',
  'showdata',
  'showdatainbrowser',
  'url',
  'seturl',
  'loadurl',
};

bool isHtmlLoadVerb(String verb) => htmlLoadVerbs.contains(verb.toLowerCase());

/// The named scalars of a DP push element: `02 01 <len> NAME 02 01` then
/// its value token(s) `02 03 <len> DATA 02 03` — consecutive value tokens
/// joined (a string longer than one u16 token).
Map<String, Uint8List> dpScalars(Uint8List seg) {
  final out = <String, Uint8List>{};
  final bd = ByteData.sublistView(seg);
  var i = 0;
  while (i + 6 <= seg.length) {
    if (seg[i] != 0x02 || seg[i + 1] != 0x01) {
      i++;
      continue;
    }
    final ln = bd.getUint16(i + 2);
    final close = i + 4 + ln;
    if (close + 2 > seg.length ||
        seg[close] != 0x02 ||
        seg[close + 1] != 0x01) {
      i++;
      continue;
    }
    final name = latin1.decode(Uint8List.sublistView(seg, i + 4, close));
    var j = close + 2;
    final value = BytesBuilder(copy: false);
    var tokens = 0;
    while (j + 4 <= seg.length && seg[j] == 0x02 && seg[j + 1] == 0x03) {
      final vl = bd.getUint16(j + 2);
      final end = j + 4 + vl;
      if (end + 2 > seg.length || seg[end] != 0x02 || seg[end + 1] != 0x03) {
        break;
      }
      value.add(Uint8List.sublistView(seg, j + 4, end));
      tokens++;
      j = end + 2;
    }
    if (tokens > 0) out.putIfAbsent(name, () => value.takeBytes());
    i = tokens > 0 ? j : close + 2;
  }
  return out;
}

/// The DP message-boundary admin header the transport splices into a long
/// column (reference client diag_showdata._ADMIN_RX: 24 hex chars, `SAPGUI`, a pad,
/// `00000001`, a 4-byte counter).
final RegExp _adminHeader = RegExp(
  r'[0-9A-Fa-f]{24}SAPGUI {2,40}0{7}1[\s\S]{4}',
);

Uint8List stripDpAdminHeaders(Uint8List b) {
  final s = latin1.decode(b);
  if (!s.contains('SAPGUI')) return b;
  return Uint8List.fromList(latin1.encode(s.replaceAll(_adminHeader, '')));
}

/// The content of one DP push for a viewer, or null when it carries none:
/// the DATASTR string (SEND_STRING_DATA), else the DATABIN column (one LZH
/// object across its chunks), else the DATAASC column.
HtmlPush? htmlPushOf(Uint8List seg) {
  final sc = dpScalars(seg);
  String txt(String k) => latin1.decode(sc[k] ?? Uint8List(0)).trim();
  final url = txt('DESURL');
  if (url.isEmpty) return null;
  var bytes = sc['DATASTR'];
  if (bytes == null || bytes.isEmpty) bytes = _databinContent(seg);
  if (bytes == null || bytes.isEmpty) {
    final (_, _, cells) = dpColumnCells(seg, 'DATAASC');
    if (cells.isNotEmpty) bytes = stripDpAdminHeaders(_join(cells));
  }
  if (bytes == null || bytes.isEmpty) return null;
  // the declared size bounds a padded last record
  final ts = sc['TOTALSIZE'];
  if (ts != null && ts.length == 4) {
    final n = ByteData.sublistView(ts).getUint32(0, Endian.little);
    if (n > 0 && n < bytes.length) bytes = Uint8List.sublistView(bytes, 0, n);
  }
  // a string push ends with its C terminator
  var end = bytes.length;
  while (end > 0 && bytes[end - 1] == 0) {
    end--;
  }
  if (end < bytes.length) bytes = Uint8List.sublistView(bytes, 0, end);
  return HtmlPush(url, txt('TYPE'), txt('SUBTYPE'), bytes);
}

/// Every viewer content push nested in one RFC value (an OLE flush call's
/// RFC_QUEUE, or a standalone DP push), in queue order.
List<HtmlPush> htmlPushesOf(Uint8List rfc) {
  final c = DpCache()..ingestValue(rfc);
  return [
    for (final u in c.order)
      if (htmlPushOf(c.byUrl[u]!) case final p?) p,
  ];
}

const List<int> _cell0 = [0x03, 0x05, 0x00, 0xfa];
const List<int> _delim = [0x03, 0x05, 0x03, 0x05, 0x00, 0xfa];
const List<int> _colEnd = [0x03, 0x05, 0x03, 0x06];

/// reference client diag_showdata.assemble_databin_html: the DATABIN chunks joined,
/// the admin headers removed, one LZH decode bounded by its own header.
Uint8List? _databinContent(Uint8List seg) {
  final db = _find(seg, 'DATABIN'.codeUnits, 0);
  if (db < 0) return null;
  final start = _find(seg, _cell0, db);
  if (start >= 0) {
    final end0 = _find(seg, _colEnd, start);
    final region = Uint8List.sublistView(
      seg,
      start + _cell0.length,
      end0 < 0 ? seg.length : end0,
    );
    final payload = BytesBuilder(copy: false);
    var from = 0;
    while (true) {
      final d = _find(region, _delim, from);
      payload.add(
        stripDpAdminHeaders(
          Uint8List.sublistView(region, from, d < 0 ? region.length : d),
        ),
      );
      if (d < 0) break;
      from = d + _delim.length;
    }
    final p = payload.takeBytes();
    final m = _find(p, const [0x1f, 0x9d], 0);
    if (m >= 5) {
      final out = lzhInflate(Uint8List.sublistView(p, m - 5));
      final declared = ByteData.sublistView(
        p,
        m - 5,
      ).getUint32(0, Endian.little);
      if (out != null && out.length == declared) return out;
    }
  }
  // inline 03 04 rows / per-cell LZH objects
  final (_, _, cells) = dpColumnCells(seg, 'DATABIN');
  return cells.isEmpty ? null : stripDpAdminHeaders(_join(cells));
}

Uint8List _join(List<Uint8List> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.takeBytes();
}

int _find(Uint8List b, List<int> needle, int from) {
  outer:
  for (var i = from; i + needle.length <= b.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (b[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Whether [b] starts like an HTML document.
bool looksLikeHtml(Uint8List b) {
  final head = latin1
      .decode(Uint8List.sublistView(b, 0, b.length < 4096 ? b.length : 4096))
      .toLowerCase();
  return head.contains('<html') ||
      head.contains('<body') ||
      head.contains('<!doctype');
}

/// The text of an HTML document's bytes: UTF-16 when it carries a BOM (or
/// reads as UTF-16LE ASCII), else the charset its meta tag declares —
/// UTF-8 by default (the the test system / the test system F1 pages declare `charset=utf-8` and
/// carry `C3 A9` for é), Latin-1 when it says so or does not decode.
String decodeHtmlBytes(Uint8List b) {
  if (b.length >= 2 && b[0] == 0xff && b[1] == 0xfe) {
    return _utf16le(Uint8List.sublistView(b, 2));
  }
  if (b.length >= 3 && b[0] == 0xef && b[1] == 0xbb && b[2] == 0xbf) {
    b = Uint8List.sublistView(b, 3);
  }
  if (b.length >= 8 && b[1] == 0 && b[3] == 0 && b[5] == 0 && b[0] != 0) {
    return _utf16le(b);
  }
  final head = latin1
      .decode(Uint8List.sublistView(b, 0, b.length < 2048 ? b.length : 2048))
      .toLowerCase();
  final cs = RegExp(r'charset\s*=\s*"?([a-z0-9_-]+)').firstMatch(head);
  final charset = cs?.group(1) ?? 'utf-8';
  if (charset.contains('8859') || charset.contains('latin')) {
    return latin1.decode(b);
  }
  try {
    return utf8.decode(b);
  } on FormatException {
    return latin1.decode(b);
  }
}

String _utf16le(Uint8List b) {
  final bd = ByteData.sublistView(b);
  final units = [
    for (var i = 0; i + 1 < b.length; i += 2) bd.getUint16(i, Endian.little),
  ];
  return String.fromCharCodes(units);
}

const Map<String, String> _entities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
};

String _unescape(String s) =>
    s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[A-Za-z]+);'), (m) {
      final e = m.group(1)!;
      if (e.startsWith('#x')) {
        return String.fromCharCode(int.parse(e.substring(2), radix: 16));
      }
      if (e.startsWith('#')) {
        return String.fromCharCode(int.parse(e.substring(1)));
      }
      return _entities[e] ?? m.group(0)!;
    });

/// The readable text of [html]: head, scripts and styles dropped, block
/// tags break lines, tags stripped, entities decoded, whitespace collapsed.
String htmlToText(String html) {
  var s = html.replaceAll(
    RegExp(
      r'<(head|script|style)\b[^>]*>.*?</\1\s*>',
      caseSensitive: false,
      dotAll: true,
    ),
    ' ',
  );
  s = s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ');
  s = s.replaceAll(
    RegExp(
      r'<\s*(br|/?p|/?div|/?h[1-6]|/?li|/?tr|/?table|/?ul|/?ol)\b[^>]*>',
      caseSensitive: false,
    ),
    '\n',
  );
  s = s.replaceAll(RegExp(r'<[^>]*>'), ' ');
  s = _unescape(s);
  final lines = [
    for (final l in s.split('\n'))
      if (l.replaceAll(RegExp(r'[ \t\r\f ]+'), ' ').trim() case final t
          when t.isNotEmpty)
        t,
  ];
  return lines
      .join('\n')
      .replaceAllMapped(RegExp(r' ([.,;:)])'), (m) => m.group(1)!);
}

/// A `sapevent:` url inside a script (an onclick, a `javascript:` href).
final RegExp _scriptSapEvent = RegExp(
  r'''sapevent:[^'"\s)]+''',
  caseSensitive: false,
);

/// Every `SAPEVENT:` link of [html] (`<a href>` / `<area href>`, or the
/// SAPEVENT its onclick / `javascript:` href navigates to), in document
/// order, its href entity-decoded as the browser navigates to it (reference client
/// screen_html.sapevent_links).
List<SapHtmlLink> sapEventLinks(String html) {
  final out = <SapHtmlLink>[];
  final rx = RegExp(
    r'<(a|area)\b([^>]*)>(?:(.*?)</a\s*>)?',
    caseSensitive: false,
    dotAll: true,
  );
  for (final m in rx.allMatches(html)) {
    // quoted or bare values, entities decoded — the url the browser
    // navigates to (and the app's link run carries)
    final attrs = htmlAttributes(m.group(2)!);
    var href = (attrs['href'] ?? '').trim();
    if (!href.toLowerCase().startsWith('sapevent:')) {
      // a script's navigation: `href="#" onclick="location.href=
      // 'SAPEVENT:X'"`, `href="javascript:…'SAPEVENT:X'…"`
      final js = _scriptSapEvent.firstMatch(
        '${attrs['onclick'] ?? ''} ${href.toLowerCase().startsWith('javascript:') ? href : ''}',
      );
      if (js == null) continue;
      href = js.group(0)!;
    }
    final label = m.group(1)!.toLowerCase() == 'a'
        ? htmlToText(m.group(3) ?? '').replaceAll('\n', ' ').trim()
        : '';
    out.add(
      SapHtmlLink(
        href,
        label.isNotEmpty ? label : (attrs['alt'] ?? attrs['title'] ?? ''),
        target: attrs['target'] ?? '',
      ),
    );
  }
  return out;
}

final RegExp _attrRx = RegExp(
  r"""([A-Za-z_:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))""",
);

/// The attributes of a tag's attribute text, names lower-cased, values
/// entity-decoded.
Map<String, String> htmlAttributes(String raw) => {
  // a bare boolean attribute (`selected`, `checked`) reads as ''
  for (final b in RegExp(
    r'(?:^|\s)(checked|selected|disabled|readonly)(?=\s|/|$)',
    caseSensitive: false,
  ).allMatches(raw))
    b.group(1)!.toLowerCase(): '',
  for (final a in _attrRx.allMatches(raw))
    a.group(1)!.toLowerCase(): _unescape(
      a.group(2) ?? a.group(3) ?? a.group(4) ?? '',
    ),
};

/// Every `<form>` of [html] whose action is a `SAPEVENT:` url, in document
/// order, with its posted fields, input ids and buttons (reference client
/// screen_html.sapevent_forms: a `<button>` or an input of type button /
/// submit / reset / image is a button when it has an id; every other named
/// input / select / textarea is a field) and the frame a submit names
/// ([SapHtmlForm.frame]: its `target=`, else the inlined frame it sits in).
List<SapHtmlForm> sapEventForms(String html) {
  final out = <SapHtmlForm>[];
  final formRx = RegExp(
    r'<form\b([^>]*)>(.*?)</form\s*>',
    caseSensitive: false,
    dotAll: true,
  );
  final tagRx = RegExp(
    r'<(input|button|select|textarea)\b([^>]*)>',
    caseSensitive: false,
  );
  for (final m in formRx.allMatches(html)) {
    final fa = htmlAttributes(m.group(1)!);
    final action = fa['action'] ?? '';
    if (!action.toLowerCase().startsWith('sapevent:')) continue;
    final fields = <(String, String)>[];
    final inputs = <String, String>{};
    final buttons = <String>[];
    final labels = <String, String>{};
    final body = m.group(2)!;
    for (final t in tagRx.allMatches(body)) {
      final tag = t.group(1)!.toLowerCase();
      final a = htmlAttributes(t.group(2)!);
      final kind = (a['type'] ?? '').toLowerCase();
      if (tag == 'button' ||
          const {'button', 'submit', 'reset', 'image'}.contains(kind)) {
        final id = a['id'] ?? '';
        if (id.isEmpty) continue;
        buttons.add(id);
        var label = a['value'] ?? '';
        if (tag == 'button') {
          final close = body.toLowerCase().indexOf('</button', t.end);
          final inner = close < 0 ? '' : body.substring(t.end, close);
          label = htmlToText(inner).replaceAll('\n', ' ').trim();
          if (label.isEmpty) {
            final img = RegExp(
              r'<img\b([^>]*)>',
              caseSensitive: false,
            ).firstMatch(inner);
            final ia = img == null
                ? const <String, String>{}
                : htmlAttributes(img.group(1)!);
            label = (ia['alt'] ?? ia['title'] ?? '').trim();
          }
        }
        if (label.trim().isEmpty) label = (a['title'] ?? a['alt'] ?? '').trim();
        if (label.trim().isEmpty) label = id.substring(id.indexOf(':') + 1);
        labels[id] = label.trim();
        continue;
      }
      final name = a['name'];
      if (name == null || name.isEmpty) continue;
      var value = a['value'] ?? '';
      if (tag == 'select') {
        final close = body.toLowerCase().indexOf('</select', t.end);
        final opts = close < 0 ? '' : body.substring(t.end, close);
        final o = RegExp(
          r'<option\b([^>]*)>',
          caseSensitive: false,
        ).allMatches(opts).map((x) => htmlAttributes(x.group(1)!)).toList();
        final sel =
            o.where((x) => x.containsKey('selected')).firstOrNull ??
            o.firstOrNull;
        value = sel?['value'] ?? '';
      } else if (tag == 'textarea') {
        final close = body.toLowerCase().indexOf('</textarea', t.end);
        value = close < 0 ? '' : _unescape(body.substring(t.end, close));
      }
      fields.add((name, value));
      if (a['id'] case final id? when id.isNotEmpty) inputs[name] = id;
    }
    final target = (fa['target'] ?? '').trim();
    out.add(
      SapHtmlForm(
        name: fa['name'] ?? '',
        action: action,
        fields: fields,
        inputs: inputs,
        buttons: buttons,
        buttonLabels: labels,
        frame: target.isNotEmpty ? target : _frameAt(html, m.start),
      ),
    );
  }
  return out;
}

/// [html] with its frames shown: a `<frameset>` becomes the bodies of the
/// documents its `<frame src>`s name, an `<iframe src>` the body of its
/// document, each looked up in [parts] (the pushes beside the page, by url)
/// — an absolute src by its url, a relative one under [url]'s directory,
/// else by its last path segment, case-insensitively. A frame whose
/// document was not pushed stays as it is; nested frames resolve up to
/// four levels deep.
String inlineHtmlFrames(
  String html,
  String url,
  Map<String, Uint8List> parts, {
  int depth = 0,
}) {
  if (depth > 3 || !RegExp(r'<i?frame', caseSensitive: false).hasMatch(html)) {
    return html;
  }
  String? bodyOf(String src) {
    final bytes = _partFor(src, url, parts);
    if (bytes == null) return null;
    final text = decodeHtmlBytes(bytes);
    if (!looksLikeHtml(bytes) &&
        !RegExp(r'<[a-z]', caseSensitive: false).hasMatch(text)) {
      return null;
    }
    final inner = inlineHtmlFrames(text, src, parts, depth: depth + 1);
    final b = RegExp(
      r'<body\b[^>]*>(.*?)(?:</body\s*>|$)',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(inner);
    if (b != null) return b.group(1)!;
    // a frameset page inlined above, or a fragment: drop its head
    return inner.replaceAll(
      RegExp(r'<head\b.*?</head\s*>', caseSensitive: false, dotAll: true),
      '',
    );
  }

  String srcOf(String attrs) => (htmlAttributes(attrs)['src'] ?? '').trim();
  final frameRx = RegExp(r'<frame\b([^>]*)>', caseSensitive: false);
  var s = html;
  // the frameset (with its nested framesets): its frames' bodies in order
  final fs = RegExp(r'<frameset\b', caseSensitive: false).firstMatch(s);
  if (fs != null) {
    final lastClose = RegExp(
      r'</frameset\s*>',
      caseSensitive: false,
    ).allMatches(s).lastOrNull;
    final end = lastClose?.end ?? s.length;
    final block = s.substring(fs.start, end);
    final bodies = <String>[];
    var resolved = false;
    for (final f in frameRx.allMatches(block)) {
      final b = bodyOf(srcOf(f.group(1)!));
      resolved |= b != null;
      bodies.add(
        b == null
            ? f.group(0)!
            : '<div>${_frameMark(f.group(1)!)}$b$_frameEnd</div>',
      );
    }
    if (resolved) {
      s =
          '${s.substring(0, fs.start)}<body>${bodies.join('\n')}</body>'
          '${s.substring(end)}';
    }
  }
  // inline frames
  s = s.replaceAllMapped(
    RegExp(
      r'<iframe\b([^>]*)>(?:.*?</iframe\s*>)?',
      caseSensitive: false,
      dotAll: true,
    ),
    (m) {
      final b = bodyOf(srcOf(m.group(1)!));
      return b == null
          ? m.group(0)!
          : '<div>${_frameMark(m.group(1)!)}$b$_frameEnd</div>';
    },
  );
  return s;
}

/// The comments [inlineHtmlFrames] brackets an inlined frame's body with:
/// `<!--sapframe:Frame0-->` … `<!--/sapframe-->` (the frame's `name=`) —
/// what [sapEventForms] reads a form's frame from; a reader of the text
/// drops comments.
String _frameMark(String frameAttrs) =>
    '<!--sapframe:${(htmlAttributes(frameAttrs)['name'] ?? '').trim()}-->';
const String _frameEnd = '<!--/sapframe-->';
final RegExp _frameMarkRx = RegExp(r'<!--(/?)sapframe:?([^>]*?)-->');

/// The name of the inlined frame open at [offset] of [html] (see
/// [_frameMark]), '' outside every frame.
String _frameAt(String html, int offset) {
  final open = <String>[];
  for (final m in _frameMarkRx.allMatches(html)) {
    if (m.start >= offset) break;
    if (m.group(1) == '/') {
      if (open.isNotEmpty) open.removeLast();
    } else {
      open.add(m.group(2)!);
    }
  }
  return open.isEmpty ? '' : open.last;
}

/// The pushed part a frame's [src] names, relative to the page [base].
Uint8List? _partFor(String src, String base, Map<String, Uint8List> parts) {
  if (src.isEmpty) return null;
  final want = src.split('#').first.split('?').first;
  final lower = {for (final e in parts.entries) e.key.toLowerCase(): e.value};
  if (want.contains('://')) {
    if (lower[want.toLowerCase()] case final b?) return b;
  } else {
    final slash = base.lastIndexOf('/');
    final dir = slash < 0 ? '' : base.substring(0, slash + 1);
    final rel = want.startsWith('./') ? want.substring(2) : want;
    if (lower['$dir$rel'.toLowerCase()] case final b?) return b;
  }
  final seg = want.substring(want.lastIndexOf('/') + 1).toLowerCase();
  if (seg.isEmpty) return null;
  for (final e in lower.entries) {
    if (e.key.endsWith('/$seg')) return e.value;
  }
  return null;
}
