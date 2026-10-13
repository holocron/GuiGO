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
    return SapIconAtlas._(codes, names);
  }

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
