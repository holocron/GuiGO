import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Resolves SAP wire icon tokens (`@0S@`, `@5F\Q...@`) to glyphs of the
/// bundled clean-room icon font, with semantic colors for the LED/message
/// families.
class SapIconAtlas {
  SapIconAtlas._(this._codes, this._names);

  final Map<String, int> _codes; // "0S" -> codepoint
  final Map<String, String> _names; // "0S" -> ICON_SYSTEM_SAVE

  static SapIconAtlas? _instance;

  static Future<SapIconAtlas> load() async {
    if (_instance != null) return _instance!;
    final raw = await rootBundle.loadString('assets/fonts/font_codemap.json');
    return _instance = SapIconAtlas.parse(raw);
  }

  /// The atlas of a font codemap (`{"0S": {"cp": …, "name": …}, …}`), its
  /// codes normalised to upper case once here — wire codes are upper case,
  /// so a lookup needs no case folding.
  factory SapIconAtlas.parse(String codemap) {
    final j = jsonDecode(codemap) as Map<String, dynamic>;
    final codes = <String, int>{};
    final names = <String, String>{};
    j.forEach((code, meta) {
      final cp = (meta as Map<String, dynamic>)['cp'] as int?;
      final name = meta['name'] as String?;
      if (cp != null) {
        final c = code.toUpperCase();
        codes[c] = cp;
        if (name != null) names[c] = name;
      }
    });
    // a code whose glyph in the bundled font draws another icon is drawn
    // with the font's glyph of the icon it names (the font itself is kept)
    // (looked up in the font's own map: one override never feeds another)
    final own = Map.of(codes);
    glyphOf.forEach((code, drawnAs) {
      final cp = own[drawnAs];
      if (cp != null && codes.containsKey(code)) codes[code] = cp;
    });
    return SapIconAtlas._(codes, names);
  }

  /// Codes drawn with ANOTHER code's glyph of the bundled font: `9S`
  /// ICON_ARROW_LEFT — the "previous" arrow of a control toolbar (PA20's
  /// object manager `SEARCH_PREV` "Résultat recherche précédent", PPOSE's
  /// `NM_BACK` "Faire défiler vers l'arrière"; a recorded session
  /// srv[184], a recorded session srv[17]) — is drawn pointing RIGHT
  /// in the font, beside its `9T` ICON_ARROW_RIGHT: the pair read as two
  /// "forward" buttons. It takes `2M` ICON_SYSTEM_BACK's left arrow.
  ///
  /// The Class Builder's methods tab (SAPLSEOD/2000's pushbutton row,
  /// a recorded session srv[35], drawn in methods_tab_
  /// screenshot.png):
  /// * `03` ICON_FAILURE — "Exceptions" — is SAP's lightning bolt; the font
  /// draws a bare X (the cancel cross): it takes `9Y` ICON_ACTIVITY's
  /// lightning;
  /// * `9U` ICON_ABAP — "Code srce" — is drawn as a plus in a square (an
  /// "insert"): it takes `9V` ICON_ABAP_LOCAL's `</>` code glyph;
  /// * `17` ICON_INSERT_ROW — "Insérer méthode" — is drawn as an EMPTY
  /// square (read as a blank button): it takes `XQ`'s plus in a square
  /// (the font's glyph of that code is the "add" plus).
  static const Map<String, String> glyphOf = {
    '9S': '2M',
    '03': '9Y',
    '9U': '9V',
    '17': 'XQ',
  };

  /// The codepoint for a wire code (without the @ delimiters), or null.
  /// Folded to upper case only when the code is not found as given.
  int? codepoint(String code) => _codes[code] ?? _codes[_upper(code)];

  String? iconName(String code) => _names[code] ?? _names[_upper(code)];

  static String _upper(String code) {
    for (var i = 0; i < code.length; i++) {
      final u = code.codeUnitAt(i);
      if (u >= 0x61 && u <= 0x7A) return code.toUpperCase();
    }
    return ''; // already upper case: its miss stands
  }

  /// An icon token `@<code>[\Q<quick info>]@`; a text cut off by its
  /// field length (the debugger's `@UM\QMaximiser horiz…`) ends the token
  /// at the end of the text.
  static final RegExp tokenRx = RegExp(r'@([0-9A-Z]{1,2})(?:\\Q[^@]*)?(?:@|$)');

  /// A quick-info-only token (`@\QOrganisation achats@OrgAchats`, the
  /// tooltip of a heading or label with no icon).
  static final RegExp quickInfoRx = RegExp(r'@\\Q[^@]*(?:@|$)');

  /// Strip icon and quick-info tokens from a wire text, returning plain text.
  String stripTokens(String text) =>
      text.replaceAllMapped(tokenRx, (m) => '').replaceAll(quickInfoRx, '');
}
