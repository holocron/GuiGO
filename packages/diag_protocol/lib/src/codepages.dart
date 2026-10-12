/// SAP codepage ↔ text conversion (raw_base port). This client declares
/// codepage 4110 / UTF-8 on every frame, which is what the kernel then uses
/// for DYNT values, TC cells and ok-codes.
library;

import 'dart:convert';
import 'dart:typed_data';

const String okCodepage = '4110';

/// codepage id -> codec used by the reference engine; unlisted ids decode
/// latin-1 (never throws).
const Map<String, String> codepageCodecs = {
  '4110': 'utf-8',
  '1100': 'latin-1',
  '1160': 'cp1252',
  '1127': 'mac-roman',
};

/// Server wire bytes → String. UTF-8 first with latin-1 fallback so a stray
/// byte never throws.
String wireDecode(Uint8List data, [String codepage = okCodepage]) {
  if (data.isEmpty) return '';
  if (codepage == '4110') {
    return utf8.decode(data, allowMalformed: true);
  }
  return latin1.decode(data, allowInvalid: true);
}

/// String → wire bytes under the declared codepage.
Uint8List wireText(String text, [String codepage = okCodepage]) {
  if (codepage == '4110') return Uint8List.fromList(utf8.encode(text));
  return Uint8List.fromList(latin1.encode(text));
}

/// Character count for dynpro column arithmetic (differs from UTF-8 byte
/// length on accents).
int wireChars(String text) => text.length;

/// Decode a NUL-terminated wire string.
String wireDecodeNull(Uint8List data, [String codepage = okCodepage]) {
  for (var i = 0; i < data.length; i++) {
    if (data[i] == 0) {
      return wireDecode(Uint8List.sublistView(data, 0, i), codepage);
    }
  }
  return wireDecode(data, codepage);
}
