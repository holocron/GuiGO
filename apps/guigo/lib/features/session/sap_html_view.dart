import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// One block of a converted HTML document: a heading, a paragraph, a list
/// item or a table row, as styled runs.
class HtmlBlock {
  HtmlBlock(this.kind, this.runs, {this.level = 0});

  /// 'h' (heading, [level] 1..6), 'p', 'li', 'tr', 'pre', 'frame' (a frame
  /// whose document was not pushed).
  final String kind;
  final int level;
  final List<HtmlRun> runs;

  String get text => runs.map((r) => r.text).join();
}

/// A run of text with its inline style and, for an anchor, its target. A
/// form control's run is drawn as a control ([control]); a button of a
/// `SAPEVENT:` form (a dynamic document's `A1F2B3NAME:BT_SELECTDT`) carries
/// its id in [button].
class HtmlRun {
  HtmlRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.mono = false,
    this.href,
    this.button,
    this.control = false,
    this.image,
    this.input,
    this.inputId,
    this.value = '',
    this.size,
  });
  final String text;
  final bool bold, italic, mono;
  final String? href;
  final String? button;
  final bool control;

  /// A button's image (`<button><img src="s_t_date.gif">`, an input of
  /// type image): its src as the page spells it — the button is drawn as
  /// that image (a pushed part of the document), its label the tooltip.
  final String? image;

  /// A text input: its field name (`A1F2I4`, what a submit posts), its DOM
  /// id (`A1F2I4NAME:INPUT_BEGINDT`), its painted value and its `size`.
  final String? input;
  final String? inputId;
  final String value;
  final int? size;

  /// A tap does something: a link, or a form button.
  bool get tappable => href != null || button != null;

  HtmlRun withText(String t) => HtmlRun(t,
      bold: bold,
      italic: italic,
      mono: mono,
      href: href,
      button: button,
      control: control,
      image: image,
      input: input,
      inputId: inputId,
      value: value,
      size: size);
}

/// HTML's collapsible whitespace (not U+00A0, which Dart's \s includes).
final _htmlSpace = RegExp(r'[ \t\r\n\f]+');

const _entities = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': '\u00A0',
  'eacute': 'é', 'egrave': 'è', 'ecirc': 'ê', 'agrave': 'à', 'acirc': 'â',
  'ccedil': 'ç', 'ocirc': 'ô', 'ucirc': 'û', 'ugrave': 'ù', 'icirc': 'î',
  'iuml': 'ï', 'euml': 'ë', 'auml': 'ä', 'ouml': 'ö', 'uuml': 'ü', 'szlig': 'ß',
  'Eacute': 'É', 'laquo': '«', 'raquo': '»', 'hellip': '…', 'ndash': '–',
  'mdash': '—', 'rsquo': '’', 'lsquo': '‘', 'rdquo': '”', 'ldquo': '“',
  'copy': '©', 'reg': '®', 'deg': '°', 'euro': '€', 'middot': '·', 'bull': '•',
};

final _entityRx = RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[A-Za-z]+);');

/// The character of a numeric reference: U+FFFD for what is no Unicode
/// scalar value (0, a surrogate, past U+10FFFF, digits that overflow) —
/// as HTML's parser does — instead of a throw on a hostile page.
String _charRef(String digits, int radix) {
  final cp = digits.length > 8 ? null : int.tryParse(digits, radix: radix);
  final ok = cp != null &&
      cp > 0 &&
      cp <= 0x10FFFF &&
      (cp < 0xD800 || cp > 0xDFFF);
  return String.fromCharCode(ok ? cp : 0xFFFD);
}

String _decodeEntities(String s) => !s.contains('&')
    ? s
    : s.replaceAllMapped(_entityRx, (m) {
        final e = m.group(1)!;
        if (e.startsWith('#x')) return _charRef(e.substring(2), 16);
        if (e.startsWith('#')) return _charRef(e.substring(1), 10);
        return _entities[e] ?? m.group(0)!;
      });

final _boolAttrRx = RegExp(r'(?:^|\s)(checked|selected|disabled)(?=\s|/|$)', caseSensitive: false);
final _hrefSplitRx = RegExp(r'[/\\?:=&#]');
final _sapeventRx = RegExp(r'''sapevent:[^'"\s)]+''', caseSensitive: false);
final _commentRx = RegExp(r'<!--.*?-->', dotAll: true);
final _droppedRx = RegExp(r'<(script|style|head|title|noscript)\b.*?</\1\s*>', caseSensitive: false, dotAll: true);
final _declRx = RegExp(r'<![^>]*>|<\?[^>]*>');
final _leadSpaceRx = RegExp(r'^[ \t\r\n\f]+');
final _trailSpaceRx = RegExp(r'[ \t\r\n\f]+$');
final _leadBlanksRx = RegExp(r'^ +');
final _tagRx = RegExp(r'<(/?)([A-Za-z][A-Za-z0-9]*)([^>]*)>');

final _attrRx = RegExp(r'''([A-Za-z_:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))''');

/// A tag's attributes, names lower-cased, values entity-decoded and trimmed.
Map<String, String> _attrs(String raw) => {
      for (final a in _attrRx.allMatches(raw))
        a.group(1)!.toLowerCase(): _decodeEntities(a.group(2) ?? a.group(3) ?? a.group(4) ?? '').trim(),
      // a bare boolean attribute (`checked`, `selected`)
      for (final b in _boolAttrRx.allMatches(raw))
        b.group(1)!.toLowerCase(): '',
    };

String? _nonEmpty(String? s) => s == null || s.isEmpty ? null : s;

/// A readable label for a link without text: the last part of its target
/// (`SAPEVENT:QUICKLINK?ID=USER_ACCESS` -> `USER_ACCESS`, `…/help.htm` ->
/// `help.htm`).
String hrefLabel(String href) {
  final parts = href.split(_hrefSplitRx).where((p) => p.trim().isNotEmpty).toList();
  return parts.isEmpty ? href : parts.last.trim();
}

/// The `sapevent:` url an inline handler navigates to (`onclick=
/// "location.href='SAPEVENT:X'"`), or null.
String? _sapeventIn(String? js) =>
    js == null ? null : _sapeventRx.firstMatch(js)?.group(0);

/// The SAP control name of a dynamic document control id
/// (`A1F2B3NAME:BT_SELECTDT` -> `BT_SELECTDT`).
String _controlName(String id) => id.substring(id.indexOf(':') + 1);

/// Convert an HTML document (SAP's F1 documentation, a viewer page) into
/// blocks of styled runs: scripts, styles, the head and `<!…>` markup (a
/// dynamic document's `<!%_BODYSTART>`, SBWP's `<!MESSAGE!>`) dropped,
/// block tags break paragraphs, b/strong/i/em/code/tt style runs, a href
/// becomes a link run — labelled by its image's alt / title, else the last
/// part of its target, when it has no text — and whitespace collapses
/// outside <pre>. Form controls read as controls: a button (`<button>`, an
/// input of type button / submit / image) is a run with its id
/// ([HtmlRun.button]) and its form's SAPEVENT, labelled by its text, value,
/// image alt or title; a text input shows its value, a check box / radio
/// its state, a select its chosen option. A frame left in the page (its
/// document was not pushed) is a 'frame' block naming its src.
List<HtmlBlock> htmlToBlocks(String html) {
  final s = html
      .replaceAll(_commentRx, '')
      .replaceAll(_droppedRx, '')
      .replaceAll(_declRx, '');
  final blocks = <HtmlBlock>[];
  var runs = <HtmlRun>[];
  var kind = 'p';
  var level = 0;
  var bold = 0, italic = 0, mono = 0, pre = 0;
  String? href;
  var anchorAt = -1; // the run index the open <a> started at
  String? anchorLabel; // its image's alt / title, else its own title
  String? formAction; // the open SAPEVENT form's action
  // the open <button>: its id, its sapevent, its first run, its label,
  // its image
  String? buttonId, buttonHref, buttonLabel, buttonImage;
  var buttonAt = -1;
  // the open <select>: its options (text, selected)
  List<(String, bool)>? options;
  var optionText = StringBuffer();
  var optionSelected = false;
  var inOption = false;

  String runsText([int from = 0]) => runs.skip(from < 0 ? 0 : from).map((r) => r.text).join();

  void flush() {
    if (runsText().trim().isNotEmpty) {
      // trim the block's outer whitespace, keep inner runs
      while (runs.first.text.trim().isEmpty && !runs.first.control) {
        runs.removeAt(0);
      }
      while (runs.last.text.trim().isEmpty && !runs.last.control) {
        runs.removeLast();
      }
      runs[0] = runs[0].withText(runs[0].text.replaceFirst(_leadSpaceRx, ''));
      final l = runs.length - 1;
      runs[l] = runs[l].withText(runs[l].text.replaceFirst(_trailSpaceRx, ''));
      blocks.add(HtmlBlock(kind, runs, level: level));
    }
    runs = <HtmlRun>[];
    kind = 'p';
    level = 0;
    if (anchorAt >= 0) anchorAt = 0;
    if (buttonAt >= 0) buttonAt = 0;
  }

  void gap() {
    if (runsText().trim().isNotEmpty && !runs.last.text.endsWith(' ')) runs.add(HtmlRun(' '));
  }

  void control(String label,
      {String? button, String? link, String? image, String? input, String? inputId, String value = '', int? size}) {
    gap();
    runs.add(HtmlRun(label,
        bold: bold > 0,
        href: link,
        button: button,
        control: true,
        image: image,
        input: input,
        inputId: inputId,
        value: value,
        size: size));
    runs.add(HtmlRun(' '));
  }

  void text(String t) {
    // collapsed whitespace after a control's own gap
    if (pre == 0 && runs.isNotEmpty && runs.last.text.endsWith(' ')) t = t.replaceFirst(_leadBlanksRx, '');
    if (t.isEmpty) return;
    if (options != null) {
      if (inOption) optionText.write(t);
      return;
    }
    final inButton = buttonAt >= 0;
    runs.add(HtmlRun(t,
        bold: bold > 0 || kind == 'h',
        italic: italic > 0,
        mono: mono > 0 || pre > 0,
        href: inButton ? buttonHref : href,
        button: inButton ? buttonId : null,
        control: inButton && t.trim().isNotEmpty));
  }

  void endOption() {
    if (inOption) options?.add((optionText.toString().replaceAll(_htmlSpace, ' ').trim(), optionSelected));
    inOption = false;
    optionText = StringBuffer();
  }

  var at = 0;
  for (final m in _tagRx.allMatches(s)) {
    if (m.start > at) {
      var t = _decodeEntities(s.substring(at, m.start));
      if (pre == 0) t = t.replaceAll(_htmlSpace, ' ');
      text(t);
    }
    at = m.end;
    final closing = m.group(1) == '/';
    final tag = m.group(2)!.toLowerCase();
    final raw = m.group(3) ?? '';
    switch (tag) {
      case 'br':
        runs.add(HtmlRun('\n'));
      case 'p' || 'div' || 'table' || 'tbody' || 'ul' || 'ol' || 'blockquote' || 'center' || 'body' || 'html' ||
            'form' || 'fieldset' || 'dl' || 'dt' || 'dd' || 'hr' || 'caption' || 'section' || 'article' ||
            'nav' || 'header' || 'footer':
        flush();
        if (tag == 'form') {
          final action = closing ? null : _attrs(raw)['action'];
          formAction = action != null && action.toLowerCase().startsWith('sapevent:') ? action : null;
        }
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        flush();
        if (!closing) {
          kind = 'h';
          level = int.parse(tag.substring(1));
        }
      case 'li':
        flush();
        if (!closing) kind = 'li';
      case 'tr':
        flush();
        if (!closing) kind = 'tr';
      case 'td' || 'th':
        // a cell after a non-empty one: a gap (empty spacer cells add none)
        if (!closing && runsText().trim().isNotEmpty && !runsText().endsWith('   ')) {
          runs.add(HtmlRun('   '));
        }
        if (tag == 'th') closing ? bold-- : bold++;
      case 'pre':
        flush();
        closing ? pre-- : pre++;
        if (!closing) kind = 'pre';
      case 'b' || 'strong':
        closing ? bold-- : bold++;
      case 'i' || 'em':
        closing ? italic-- : italic++;
      case 'code' || 'tt' || 'kbd' || 'samp':
        closing ? mono-- : mono++;
      case 'a':
        if (closing) {
          final h = href;
          if (h != null && anchorAt >= 0 && runsText(anchorAt).trim().isEmpty) {
            gap();
            runs.add(HtmlRun(anchorLabel ?? hrefLabel(h), bold: bold > 0, href: h));
          }
          href = null;
          anchorAt = -1;
          anchorLabel = null;
        } else {
          final a = _attrs(raw);
          // a SAPEVENT href as it is; else the SAPEVENT a script navigates
          // to (`href="#" onclick="location.href='SAPEVENT:X'"`, `href=
          // "javascript:…'SAPEVENT:X'…"`) — what the browser ends up at
          final h = _nonEmpty(a['href']);
          href = h != null && h.toLowerCase().startsWith('sapevent:')
              ? h
              : _sapeventIn(a['onclick']) ?? _sapeventIn(h) ?? h;
          anchorAt = runs.length;
          anchorLabel = _nonEmpty(a['title']);
        }
      case 'img':
        final a = _attrs(raw);
        final label = _nonEmpty(a['alt']) ?? _nonEmpty(a['title']);
        if (buttonAt >= 0) {
          buttonLabel ??= label;
          buttonImage ??= _nonEmpty(a['src']);
        } else if (href != null && label != null) {
          anchorLabel = label;
        }
      case 'area':
        final a = _attrs(raw);
        final h = _nonEmpty(a['href']);
        if (h != null) control(_nonEmpty(a['alt']) ?? _nonEmpty(a['title']) ?? hrefLabel(h), link: h);
      case 'button':
        if (closing) {
          if (buttonAt >= 0 && runsText(buttonAt).trim().isEmpty) {
            final id = buttonId;
            control(buttonLabel ?? (id == null ? 'Button' : _controlName(id)),
                button: id, link: buttonHref, image: buttonImage);
          }
          buttonAt = -1;
          buttonId = buttonHref = buttonLabel = buttonImage = null;
        } else {
          final a = _attrs(raw);
          buttonId = _nonEmpty(a['id']);
          buttonHref = _sapeventIn(a['onclick']) ?? (buttonId == null ? null : formAction);
          buttonLabel = _nonEmpty(a['title']);
          gap();
          buttonAt = runs.length;
        }
      case 'input':
        final a = _attrs(raw);
        final type = (a['type'] ?? 'text').toLowerCase();
        final id = _nonEmpty(a['id']);
        switch (type) {
          case 'hidden':
            break;
          case 'button' || 'submit' || 'reset' || 'image':
            final label = _nonEmpty(a['value']) ??
                _nonEmpty(a['alt']) ??
                _nonEmpty(a['title']) ??
                _nonEmpty(a['name']) ??
                (id == null ? type : _controlName(id));
            control(label,
                button: id,
                link: _sapeventIn(a['onclick']) ?? (id == null ? null : formAction),
                image: type == 'image' ? _nonEmpty(a['src']) : null);
          case 'checkbox':
            control(a.containsKey('checked') ? '☑' : '☐');
          case 'radio':
            control(a.containsKey('checked') ? '◉' : '○');
          case 'password':
            control('[${'•' * (a['value'] ?? '').length}]');
          default:
            // a text input: editable, its field name posted by a submit
            control('[${a['value'] ?? ''}]',
                input: _nonEmpty(a['name']),
                inputId: id,
                value: a['value'] ?? '',
                size: int.tryParse(a['size'] ?? ''));
        }
      case 'select':
        if (closing) {
          endOption();
          final o = options ?? const <(String, bool)>[];
          options = null;
          final chosen = o.where((x) => x.$2).firstOrNull ?? o.firstOrNull;
          control('[${chosen?.$1 ?? ''} ▾]');
        } else {
          options = [];
        }
      case 'option':
        endOption();
        if (!closing && options != null) {
          inOption = true;
          optionSelected = _attrs(raw).containsKey('selected');
        }
      case 'frame' || 'iframe':
        if (!closing) {
          final src = _attrs(raw)['src'] ?? '';
          flush();
          blocks.add(HtmlBlock('frame', [HtmlRun('[frame: ${src.isEmpty ? '(no source)' : src}]', italic: true)]));
        }
      default:
        break;
    }
    bold = bold.clamp(0, 99);
    italic = italic.clamp(0, 99);
    mono = mono.clamp(0, 99);
    pre = pre.clamp(0, 99);
  }
  if (at < s.length) {
    var t = _decodeEntities(s.substring(at));
    if (pre == 0) t = t.replaceAll(_htmlSpace, ' ');
    text(t);
  }
  flush();
  return blocks;
}

/// An HTML viewer control's document as readable text: headings, paragraphs,
/// list items, table rows, form controls; a link tap is reported through
/// [onLink] (SAP's `sapevent:` links go back to the server as the viewer's
/// event), a form button's through [onFormSubmit] with its id and the
/// values typed into the page's inputs (else [onFormButton] with the id
/// alone; else — neither — [onLink] with its form's action). A text input
/// is editable: what is typed rides the next submit's POST body, Enter in
/// it is the page's InputKeyDown submit ([onFormEnter], `sapin_cl` = the
/// input + `sapENTER`). A button with an image (`s_t_date.gif`, the
/// dynamic document's icons) is drawn as that image from [parts] (the
/// files pushed beside the document, resolved against [baseUrl]), its
/// label the tooltip. A page without readable text shows its source.
class SapHtmlView extends StatefulWidget {
  const SapHtmlView({
    super.key,
    required this.html,
    this.onLink,
    this.onFormButton,
    this.onFormSubmit,
    this.onFormEnter,
    this.parts = const {},
    this.baseUrl = '',
  });

  final String html;
  final void Function(String href)? onLink;
  final void Function(String buttonId)? onFormButton;

  /// A form button: its id and the page's input values by field name.
  final void Function(String buttonId, Map<String, String> values)? onFormSubmit;

  /// Enter in a text input: its DOM id (else field name) and the values.
  final void Function(String inputId, Map<String, String> values)? onFormEnter;

  /// The document's pushed files by url, and the document's own url (the
  /// relative image srcs resolve against its directory).
  final Map<String, Uint8List> parts;
  final String baseUrl;

  /// The pushed file [src] names, null when none was pushed: by its url
  /// (absolute), its url under [baseUrl]'s directory, else any pushed file
  /// of that name.
  static Uint8List? partFor(String src, String baseUrl, Map<String, Uint8List> parts) {
    if (parts.isEmpty || src.isEmpty) return null;
    final direct = parts[src];
    if (direct != null) return direct;
    final dir = baseUrl.contains('/') ? baseUrl.substring(0, baseUrl.lastIndexOf('/') + 1) : '';
    final rel = parts['$dir$src'];
    if (rel != null) return rel;
    final name = src.split('/').last.toLowerCase();
    for (final e in parts.entries) {
      if (e.key.toLowerCase().endsWith('/$name')) return e.value;
    }
    return null;
  }

  @override
  State<SapHtmlView> createState() => _SapHtmlViewState();
}

class _SapHtmlViewState extends State<SapHtmlView> {
  /// The document [_blocks] were parsed from: a rebuild of the same page
  /// (every server turn rebuilds the screen) does not parse it again.
  String? _parsed;
  List<HtmlBlock> _blocks = const [];

  /// One tap recognizer per tappable run of the current document, made on
  /// first build and disposed with the document / the view. A tap reads
  /// the CURRENT callbacks, so a recognizer outlives a busy toggle.
  final Map<HtmlRun, TapGestureRecognizer> _taps = {};

  /// The text inputs of the current document by field name: what the user
  /// typed (a new page from the server starts them over at its values).
  final Map<String, TextEditingController> _inputs = {};

  List<HtmlBlock> _blocksOf(String html) {
    if (!identical(html, _parsed) && html != _parsed) {
      _disposeTaps();
      _disposeInputs();
      _parsed = html;
      _blocks = htmlToBlocks(html);
    }
    return _blocks;
  }

  void _disposeTaps() {
    for (final t in _taps.values) {
      t.dispose();
    }
    _taps.clear();
  }

  void _disposeInputs() {
    for (final c in _inputs.values) {
      c.dispose();
    }
    _inputs.clear();
  }

  @override
  void dispose() {
    _disposeTaps();
    _disposeInputs();
    super.dispose();
  }

  /// The values of the page's text inputs by field name, as typed.
  Map<String, String> get _values => {
        for (final e in _inputs.entries) e.key: e.value.text,
      };

  bool get _canSubmit => widget.onFormSubmit != null || widget.onFormButton != null;

  void _submit(HtmlRun r) {
    final b = r.button, h = r.href;
    if (b != null && widget.onFormSubmit != null) {
      widget.onFormSubmit!(b, _values);
    } else if (b != null && widget.onFormButton != null) {
      widget.onFormButton!(b);
    } else if (h != null) {
      widget.onLink?.call(h);
    }
  }

  TapGestureRecognizer? _tapFor(HtmlRun r) {
    final button = r.button, href = r.href;
    final form = button != null && _canSubmit;
    if (!form && !(href != null && widget.onLink != null)) return null;
    // a form button goes to onFormSubmit / onFormButton when one is set,
    // a link to onLink — as the run reads at tap time
    return _taps.putIfAbsent(r, () => TapGestureRecognizer()..onTap = () => _submit(r));
  }

  /// An editable text input (its painted value to start with, `size`
  /// characters wide).
  Widget _inputBox(HtmlRun r, TextStyle style, ColorScheme scheme) {
    final name = r.input!;
    final c = _inputs.putIfAbsent(name, () => TextEditingController(text: r.value));
    final fs = style.fontSize ?? 14;
    final chars = (r.size ?? 10).clamp(2, 40);
    final enter = widget.onFormEnter;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: SizedBox(
        width: chars * fs * 0.62 + 14,
        height: fs * 1.9,
        child: TextField(
          key: ValueKey('html-input-$name'),
          controller: c,
          style: style,
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            border: const OutlineInputBorder(),
            filled: true,
            fillColor: scheme.surfaceContainerLowest,
          ),
          onSubmitted: enter == null ? null : (_) => enter(r.inputId ?? name, _values),
        ),
      ),
    );
  }

  /// A button drawn as its image (the pushed GIF, else an icon of its
  /// kind), its label the tooltip.
  Widget _imageButton(HtmlRun r, TextStyle style, ColorScheme scheme) {
    final fs = style.fontSize ?? 14;
    final src = r.image!;
    final bytes = SapHtmlView.partFor(src, widget.baseUrl, widget.parts);
    final side = (fs * 1.35).roundToDouble();
    final fallback = Icon(_iconFor(src), size: side, color: scheme.primary);
    final img = bytes == null
        ? fallback
        : Image.memory(
            bytes,
            width: side,
            height: side,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.none,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => fallback,
          );
    final label = r.text.trim();
    final enabled = r.button != null ? _canSubmit : (r.href != null && widget.onLink != null);
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: InkWell(
          key: ValueKey('html-button-${r.button ?? r.href ?? label}'),
          onTap: enabled ? () => _submit(r) : null,
          borderRadius: BorderRadius.circular(3),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outline),
              borderRadius: BorderRadius.circular(3),
              color: scheme.surfaceContainerHighest,
            ),
            child: img,
          ),
        ),
      ),
    );
  }

  /// The icon standing in for a button image that was not pushed: the
  /// SAP icon file names of the dynamic documents (`s_t_date` the
  /// calendar, `s_t_time` the clock, `s_b_*` a plain push button).
  static IconData _iconFor(String src) {
    final n = src.toLowerCase();
    if (n.contains('date') || n.contains('cale')) return Icons.calendar_month;
    if (n.contains('time') || n.contains('clock')) return Icons.schedule;
    if (n.contains('noac')) return Icons.check_box_outline_blank;
    return Icons.crop_square;
  }

  @override
  Widget build(BuildContext context) {
    final html = widget.html;
    final scheme = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle(fontSize: 14);
    final blocks = _blocksOf(html);
    if (blocks.isEmpty) return _source(context, base);
    InlineSpan span(HtmlRun r, TextStyle style) {
      var st = style.copyWith(
        fontWeight: r.bold ? FontWeight.w600 : null,
        fontStyle: r.italic ? FontStyle.italic : null,
        fontFamily: r.mono ? 'Menlo' : null,
      );
      if (r.control && r.input != null) {
        return WidgetSpan(alignment: PlaceholderAlignment.middle, child: _inputBox(r, st, scheme));
      }
      if (r.control && r.image != null) {
        return WidgetSpan(alignment: PlaceholderAlignment.middle, child: _imageButton(r, st, scheme));
      }
      if (r.control) {
        st = st.copyWith(
          color: r.tappable ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
          backgroundColor: r.tappable ? scheme.secondaryContainer : scheme.surfaceContainerHighest,
          fontWeight: r.tappable ? FontWeight.w600 : null,
        );
      } else if (r.tappable) {
        st = st.copyWith(color: scheme.primary, decoration: TextDecoration.underline);
      }
      return TextSpan(
        text: r.control ? ' ${r.text.trim()} ' : r.text,
        style: st,
        recognizer: _tapFor(r),
      );
    }

    Widget block(HtmlBlock b) => Padding(
          padding: EdgeInsets.only(
              top: b.kind == 'h' ? 10 : 2, bottom: b.kind == 'h' ? 4 : 6,
              left: b.kind == 'li' ? 16 : 0),
          child: Text.rich(
            TextSpan(children: [
              if (b.kind == 'li') const TextSpan(text: '•  '),
              for (final r in b.runs)
                if (!r.control || r.text.trim().isNotEmpty || r.input != null)
                  span(
                    r,
                    b.kind == 'h'
                        ? base.copyWith(
                            fontSize: (base.fontSize ?? 14) + (7 - b.level.clamp(1, 6)) * 1.5,
                            fontWeight: FontWeight.w600)
                        : b.kind == 'frame'
                            ? base.copyWith(color: scheme.onSurfaceVariant)
                            : base,
                  ),
            ]),
          ),
        );

    // the blocks built as they scroll into view (an F1 document runs to
    // hundreds of blocks); the input controllers live in the state, so a
    // block scrolled away and back keeps what was typed
    return SelectionArea(
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: blocks.length,
        itemBuilder: (context, i) => block(blocks[i]),
      ),
    );
  }

  /// No readable text: what arrived, as source.
  Widget _source(BuildContext context, TextStyle base) {
    final html = widget.html;
    final scheme = Theme.of(context).colorScheme;
    if (html.trim().isEmpty) return const Center(child: Text('(empty document)'));
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('No readable text in this page. View source (${html.length} characters):',
            style: base.copyWith(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic)),
        const SizedBox(height: 8),
        SelectableText(html, style: base.copyWith(fontFamily: 'Menlo', fontSize: (base.fontSize ?? 14) - 2)),
      ],
    );
  }
}
