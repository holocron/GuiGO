/// SAP codepage ↔ text conversion (raw_base port). This client declares
/// codepage 4110 / UTF-8 on every frame, which is what the kernel then uses
/// for DYNT values, TC cells and ok-codes.
library;

import 'dart:convert';
import 'dart:typed_data';

const String okCodepage = '4110';

/// codepage id -> codec name, as the reference engine lists them. Every
/// listed id decodes and encodes through [codepageCodec]; an unlisted id
/// decodes latin-1 (never throws). The table was once declarative only —
/// [wireDecode] routed every non-4110 id through latin-1, so cp1252's
/// 0x80..0x9f (`€ ‚ ƒ … ™`) and the whole Mac Roman upper half came out
/// as C1 controls / Latin-1 letters while the table implied otherwise.
const Map<String, String> codepageCodecs = {
  '4110': 'utf-8',
  '1100': 'latin-1',
  '1160': 'cp1252',
  '1127': 'mac-roman',
};

/// The [Encoding] behind a SAP codepage id ([codepageCodecs]); latin-1 for
/// an unlisted id.
Encoding codepageCodec(String codepage) => switch (codepage) {
      okCodepage => utf8,
      '1160' => cp1252,
      '1127' => macRoman,
      _ => latin1,
    };

/// Server wire bytes → String under [codepage] ([codepageCodec]); every
/// codec here is lenient, so a stray byte never throws (UTF-8 replaces,
/// the single-byte tables map every byte).
String wireDecode(Uint8List data, [String codepage = okCodepage]) {
  if (data.isEmpty) return '';
  if (codepage == okCodepage) return utf8.decode(data, allowMalformed: true);
  if (codepage == '1160') return cp1252.decode(data);
  if (codepage == '1127') return macRoman.decode(data);
  return latin1.decode(data, allowInvalid: true);
}

/// String → wire bytes under the declared codepage. The single-byte codecs
/// throw on a character outside their repertoire, as latin-1 always did.
Uint8List wireText(String text, [String codepage = okCodepage]) {
  if (codepage == okCodepage) return Uint8List.fromList(utf8.encode(text));
  return Uint8List.fromList(codepageCodec(codepage).encode(text));
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

/// Windows-1252 (SAP 1160): latin-1 with the C1 range 0x80..0x9f mapped to
/// the Windows symbols; the five unassigned slots (0x81 0x8d 0x8f 0x90 0x9d)
/// decode to the control they stand on, as Windows itself does.
const Encoding cp1252 = _TableEncoding('cp1252', _cp1252High);

/// Mac OS Roman (SAP 1127): ASCII below 0x80, Apple's table above (Unicode
/// mapping ROMAN.TXT; 0xdb is the euro sign of Mac OS 8.5+, not the old
/// currency sign).
const Encoding macRoman = _TableEncoding('mac-roman', _macRomanHigh);

/// A single-byte encoding: ASCII below 0x80, [high] (128 code points) above.
class _TableEncoding extends Encoding {
  const _TableEncoding(this.name, this.high);

  @override
  final String name;
  final List<int> high;

  @override
  Converter<List<int>, String> get decoder => _TableDecoder(high);

  @override
  Converter<String, List<int>> get encoder => _TableEncoder(name, high);
}

class _TableDecoder extends Converter<List<int>, String> {
  const _TableDecoder(this.high);
  final List<int> high;

  @override
  String convert(List<int> input) {
    final out = Uint16List(input.length);
    for (var i = 0; i < input.length; i++) {
      final b = input[i] & 0xff;
      out[i] = b < 0x80 ? b : high[b - 0x80];
    }
    return String.fromCharCodes(out);
  }
}

class _TableEncoder extends Converter<String, List<int>> {
  const _TableEncoder(this.name, this.high);
  final String name;
  final List<int> high;

  @override
  List<int> convert(String input) {
    final runes = input.runes.toList();
    final out = Uint8List(runes.length);
    for (var i = 0; i < runes.length; i++) {
      final r = runes[i];
      if (r < 0x80) {
        out[i] = r;
        continue;
      }
      final at = high.indexOf(r);
      if (at < 0) {
        throw ArgumentError.value(input, 'input',
            'Contains a character U+${r.toRadixString(16)} outside $name');
      }
      out[i] = 0x80 + at;
    }
    return out;
  }
}

// 0x80..0xff of Windows-1252.
const List<int> _cp1252High = [
  0x20ac, 0x0081, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
  0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008d, 0x017d, 0x008f,
  0x0090, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
  0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0x009d, 0x017e, 0x0178,
  0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xab,
  0xac, 0xad, 0xae, 0xaf, 0xb0, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7,
  0xb8, 0xb9, 0xba, 0xbb, 0xbc, 0xbd, 0xbe, 0xbf, 0xc0, 0xc1, 0xc2, 0xc3,
  0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xcb, 0xcc, 0xcd, 0xce, 0xcf,
  0xd0, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xdb,
  0xdc, 0xdd, 0xde, 0xdf, 0xe0, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7,
  0xe8, 0xe9, 0xea, 0xeb, 0xec, 0xed, 0xee, 0xef, 0xf0, 0xf1, 0xf2, 0xf3,
  0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff,
];

// 0x80..0xff of Mac OS Roman.
const List<int> _macRomanHigh = [
  0x00c4, 0x00c5, 0x00c7, 0x00c9, 0x00d1, 0x00d6, 0x00dc, 0x00e1,
  0x00e0, 0x00e2, 0x00e4, 0x00e3, 0x00e5, 0x00e7, 0x00e9, 0x00e8,
  0x00ea, 0x00eb, 0x00ed, 0x00ec, 0x00ee, 0x00ef, 0x00f1, 0x00f3,
  0x00f2, 0x00f4, 0x00f6, 0x00f5, 0x00fa, 0x00f9, 0x00fb, 0x00fc,
  0x2020, 0x00b0, 0x00a2, 0x00a3, 0x00a7, 0x2022, 0x00b6, 0x00df,
  0x00ae, 0x00a9, 0x2122, 0x00b4, 0x00a8, 0x2260, 0x00c6, 0x00d8,
  0x221e, 0x00b1, 0x2264, 0x2265, 0x00a5, 0x00b5, 0x2202, 0x2211,
  0x220f, 0x03c0, 0x222b, 0x00aa, 0x00ba, 0x03a9, 0x00e6, 0x00f8,
  0x00bf, 0x00a1, 0x00ac, 0x221a, 0x0192, 0x2248, 0x2206, 0x00ab,
  0x00bb, 0x2026, 0x00a0, 0x00c0, 0x00c3, 0x00d5, 0x0152, 0x0153,
  0x2013, 0x2014, 0x201c, 0x201d, 0x2018, 0x2019, 0x00f7, 0x25ca,
  0x00ff, 0x0178, 0x2044, 0x20ac, 0x2039, 0x203a, 0xfb01, 0xfb02,
  0x2021, 0x00b7, 0x201a, 0x201e, 0x2030, 0x00c2, 0x00ca, 0x00c1,
  0x00cb, 0x00c8, 0x00cd, 0x00ce, 0x00cf, 0x00cc, 0x00d3, 0x00d4,
  0xf8ff, 0x00d2, 0x00da, 0x00db, 0x00d9, 0x0131, 0x02c6, 0x02dc,
  0x00af, 0x02d8, 0x02d9, 0x02da, 0x00b8, 0x02dd, 0x02db, 0x02c7,
];
