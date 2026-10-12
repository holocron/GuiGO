/// DYNT atom parse/build (pysap SAPDiagDyntAtomItem port).
///
/// Head (13 bytes): atom_length u16 BE, dlg_flag_1 u8, dlg_flag_2 u8,
/// etype u8, area u8, block u8, group u8, row u16 BE, col u16 BE, attr u8.
/// The tail depends on the etype (see [_parseTail]).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../codepages.dart';

// etypes (pysap diag_atom_etypes)
const int etypeEField = 101;
const int etypeOField = 102;
const int etypeKeyword = 103;
const int etypeCheckButton4 = 104;
const int etypeRadioButton0 = 105;
const int etypePushButton3 = 106;
const int etypeFrame3 = 107;
const int etypeLoop6 = 108;
const int etypeSubscreen = 109;
const int etypeProperty = 111;
const int etypeIcon0 = 112;
const int etypePushButton1 = 113;
const int etypeFname = 114;
const int etypePushButton2 = 115;
const int etypeTabstripButton = 116;
const int etypeCombobox = 117;
const int etypeCheckButton1 = 118;
const int etypeRadioButton1 = 119;
const int etypeXmlprop = 120;
const int etypeEField1 = 121;
const int etypeOField1 = 122;
const int etypeKeyword1 = 123;
const int etypeCheckButton2 = 124;
const int etypeRadioButton0b = 125;
const int etypeCombobox1 = 126;
const int etypeFrame1 = 127;
const int etypeCheckButton3 = 128;
const int etypeRadioButton3 = 129;
const int etypeEField2 = 130;
const int etypeOField2 = 131;
const int etypeKeyword2 = 132;

// etype families (screen_atoms)
const Set<int> etypeInput = {101, 121, 130};
const Set<int> etypeOutput = {102, 122, 131};
const Set<int> etypeLabel = {103, 123, 132};
const Set<int> etypeCombo = {117, 126};
const Set<int> etypeFrames = {127, 107};
const Set<int> etypeTailBounded = {
  etypeFname,
  etypePushButton2,
  etypeTabstripButton,
  etypeXmlprop,
  etypeEField1,
  etypeOField1,
  etypeKeyword1,
  etypeFrame1,
  etypeRadioButton3,
  etypeEField2,
  etypeOField2,
  etypeKeyword2
};

// attr bits (header byte 12)
const int attrCombostyle = 0x80;
const int attrYes3d = 0x40;
const int attrPropfont = 0x20;
const int attrMatchcode = 0x10;
const int attrJustright = 0x08;
const int attrIntensify = 0x04;
const int attrInvisible = 0x02;
const int attrProtected = 0x01;

class DyntAtom {
  DyntAtom({
    required this.atomLength,
    required this.dlgFlag1,
    required this.dlgFlag2,
    required this.etype,
    required this.area,
    required this.block,
    required this.group,
    required this.row,
    required this.col,
    required this.attr,
  });

  final int atomLength;
  final int dlgFlag1;
  final int dlgFlag2;
  final int etype;
  final int area;
  final int block;
  final int group;
  final int row; // 0-based char cell
  final int col; // 0-based char cell
  final int attr;

  // per-etype tails
  String? nameText; // 114 FNAME
  int pushbuttonVLength = 0; // 115
  int pushbuttonVHeight = 0;
  int pushbuttonFunctionCodeOffset = 0;
  int pushbuttonTextOffset = 0;
  String? pushbuttonText;
  String? pushbuttonFunctionCode;
  int tabstripVLength = 0; // 116
  int tabstripVHeight = 0;
  int tabstripPageId = 0;
  int tabstripFunctionCodeOffset = 0;
  int tabstripTextOffset = 0;
  int tabstripIdOffset = 0;
  String? tabstripText;
  String? tabstripFunctionCode;
  String? tabstripId;
  String? xmlpropText; // 120
  int fieldFlag1 = 0; // 121/122/123 and 130/131/132
  int fieldDlen = 0;
  int fieldMlen = 0;
  int fieldMaxnrchars = 0;
  String? fieldText;
  int frameDrows = 0; // 127
  int frameDcols = 0;
  String? frameText;
  int radiobuttonButton = 0; // 129
  int radiobuttonVisibleLabelLength = 0;
  int radiobuttonEventIdOff = 0;
  int radiobuttonEventIdLen = 0;
  int radiobuttonTextOff = 0;
  int radiobuttonTextLength = 0;
  String? radiobuttonText;
  Uint8List? value; // other etypes

  /// The atom's own wire bytes (may be shorter than the parse-consumed span
  /// for fusing etype-115 tails).
  late final Uint8List ownBytes;

  bool get isInvisible => attr & attrInvisible != 0;
  bool get isProtected => attr & attrProtected != 0;
  bool get isIntensified => attr & attrIntensify != 0;
  bool get isScrollableInput => dlgFlag1 == 4; // maxnrchars > mlen
  bool get radioOn => dlgFlag2 & 0x80 != 0;
}

class DyntAtomWalk {
  DyntAtomWalk(this.atoms, this.trailing);
  final List<DyntAtom> atoms;

  /// Bytes an atom parse could not consume (scapy's trailing Raw layer).
  final Uint8List? trailing;
}

/// Parse the atom list of a DYNT blob — the REPAIRED walk (screen_atoms
/// semantics): atoms iterated by their declared atom_length, each parsed from
/// its own slice. This reproduces the engine's repair of pysap's fusing
/// dissection (etype-115's unbounded text tail and dlen-0xFF unbounded
/// values otherwise swallow every following atom).
DyntAtomWalk parseDyntAtoms(Uint8List blob) {
  final out = <DyntAtom>[];
  final n = blob.length;
  final bd = blob.buffer.asByteData(blob.offsetInBytes, blob.lengthInBytes);
  var off = 0;
  while (off + 13 <= n) {
    final atomLength = bd.getUint16(off);
    if (atomLength < 13 || off + atomLength > n) {
      return DyntAtomWalk(out, Uint8List.sublistView(blob, off));
    }
    final a = DyntAtom(
      atomLength: atomLength,
      dlgFlag1: blob[off + 2],
      dlgFlag2: blob[off + 3],
      etype: blob[off + 4],
      area: blob[off + 5],
      block: blob[off + 6],
      group: blob[off + 7],
      row: bd.getUint16(off + 8),
      col: bd.getUint16(off + 10),
      attr: blob[off + 12],
    );
    final end = off + atomLength;
    _parseTail(blob, bd, off, end, a);
    a.ownBytes = Uint8List.sublistView(blob, off, end);
    out.add(a);
    off = end;
  }
  return DyntAtomWalk(out, off < n ? Uint8List.sublistView(blob, off) : null);
}

String _tailText(Uint8List blob, int start, int end) {
  // wire bytes → text; the declared codepage is UTF-8 (4110) in this client
  return utf8.decode(Uint8List.sublistView(blob, start, end),
      allowMalformed: true);
}

/// The fixed tail bytes (past the 13-byte head) each etype reads before its
/// variable part; an atom shorter than `13 + tail` keeps its raw tail in
/// [DyntAtom.value] and none of the typed fields — never a read past its
/// own slice into the next atom (or past the blob: a RangeError).
const Map<int, int> _fixedTail = {
  etypePushButton2: 6, // vlen, vheight, fcode off u16, text off u16
  etypeTabstripButton: 9, // vlen, vheight, page id, 3 x u16 offsets
  etypeEField1: 1, // flag1 u8 (+ dlen/mlen/maxnrchars, guarded later)
  etypeOField1: 1,
  etypeKeyword1: 1,
  etypeFrame1: 4, // drows u16, dcols u16
  etypeCheckButton3: 10, // button, label len u16, event off u16, event
  etypeRadioButton3: 10, // len u8, text off u16, text len u16
  etypeEField2: 2, // flag1 u16
  etypeOField2: 2,
  etypeKeyword2: 2,
};

int _parseTail(Uint8List b, ByteData bd, int off, int end, DyntAtom a) {
  // `off` = atom start; the atom's slice is [off, end).
  final e = a.etype;
  final tail = _fixedTail[e];
  if (tail != null && off + 13 + tail > end) {
    a.value = Uint8List.sublistView(b, off + 13, end); // short atom
    return end;
  }
  switch (e) {
    case etypeFname: // 114: name_text = atom_length - 13
      a.nameText = _tailText(b, off + 13, end);
      return end;
    case etypePushButton2: // 115: text/fcode at atom-relative NUL-terminated offsets
      a.pushbuttonVLength = b[off + 13];
      a.pushbuttonVHeight = b[off + 14];
      a.pushbuttonFunctionCodeOffset = bd.getUint16(off + 15);
      a.pushbuttonTextOffset = bd.getUint16(off + 17);
      a.pushbuttonText = _zstr(b, off + a.pushbuttonTextOffset, end);
      a.pushbuttonFunctionCode = _zstr(b, off + a.pushbuttonFunctionCodeOffset, end);
      return end;
    case etypeTabstripButton: // 116
      a.tabstripVLength = b[off + 13];
      a.tabstripVHeight = b[off + 14];
      a.tabstripPageId = b[off + 15];
      a.tabstripFunctionCodeOffset = bd.getUint16(off + 16);
      a.tabstripTextOffset = bd.getUint16(off + 18);
      a.tabstripIdOffset = bd.getUint16(off + 20);
      var p = off + 22; // 9 bytes of sizes/offsets after the 13-byte head
      p = _strNull(b, p, end, (s) => a.tabstripText = s);
      p = _strNull(b, p, end, (s) => a.tabstripFunctionCode = s);
      p = _strNull(b, p, end, (s) => a.tabstripId = s);
      return end;
    case etypeXmlprop: // 120
      a.xmlpropText = _tailText(b, off + 13, end);
      return end;
    case etypeEField1:
    case etypeOField1:
    case etypeKeyword1: // 121/122/123: flag1 u8
      a.fieldFlag1 = b[off + 13];
      _parseFieldCommon(b, bd, off + 14, end, a);
      return end;
    case etypeFrame1: // 127
      a.frameDrows = bd.getUint16(off + 13);
      a.frameDcols = bd.getUint16(off + 15);
      a.frameText = _tailText(b, off + 17, end);
      return end;
    case etypeCheckButton3: // 128 — the radio's twin, same layout (reference client
    // screen_checkbox: DIAG_DGOTYP_CHECKBUTTON_3)
    case etypeRadioButton3: // 129
      a.radiobuttonButton = b[off + 13];
      a.radiobuttonVisibleLabelLength = bd.getUint16(off + 14);
      a.radiobuttonEventIdOff = bd.getUint16(off + 16);
      a.radiobuttonEventIdLen = b[off + 18];
      a.radiobuttonTextOff = bd.getUint16(off + 19);
      a.radiobuttonTextLength = bd.getUint16(off + 21);
      final textLen = a.radiobuttonEventIdLen + a.radiobuttonTextLength;
      a.radiobuttonText = _tailText(b, off + 23, _min(end, off + 23 + textLen));
      // a checkbox also keeps its raw tail (the generic decode the golden
      // atom census pins, a recorded session srv #34)
      if (a.etype == etypeCheckButton3) {
        a.value = Uint8List.sublistView(b, off + 13, end);
      }
      return end;
    case etypeEField2:
    case etypeOField2:
    case etypeKeyword2: // 130/131/132: flag1 u16
      a.fieldFlag1 = bd.getUint16(off + 13);
      _parseFieldCommon(b, bd, off + 15, end, a);
      return end;
    default:
      a.value = Uint8List.sublistView(b, off + 13, end);
      return end;
  }
}

void _parseFieldCommon(Uint8List b, ByteData bd, int off, int end, DyntAtom a) {
  // off points at dlen; layout: dlen u8, mlen u8, maxnrchars u16, text
  if (off + 4 > end) return;
  a.fieldDlen = b[off]; // 0xFF = unbounded: the value is NUL-terminated
  a.fieldMlen = b[off + 1];
  a.fieldMaxnrchars = bd.getUint16(off + 2);
  final textStart = off + 4;
  if (a.fieldDlen == 0xff) {
    a.fieldText = _zstr(b, textStart, end);
  } else {
    a.fieldText = _tailText(b, textStart, _min(end, textStart + a.fieldDlen));
  }
}

/// NUL-terminated string within [start, end) — null when [start] is
/// outside it.
String? _zstr(Uint8List b, int start, int end) {
  if (start < 0 || start >= end) return null;
  for (var i = start; i < end; i++) {
    if (b[i] == 0) return _tailText(b, start, i);
  }
  return _tailText(b, start, end);
}

int _strNull(Uint8List b, int off, int n, void Function(String) set) {
  if (off >= n) {
    set('');
    return n;
  }
  for (var i = off; i < n; i++) {
    if (b[i] == 0) {
      set(_tailText(b, off, i));
      return i + 1;
    }
  }
  set(_tailText(b, off, n));
  return n;
}

int _min(int a, int b) => a < b ? a : b;

/// Build a value-only etype-130 input atom (raw_fields._submit_atom shape).
Uint8List buildValueAtom130({
  required int area,
  required int block,
  required int group,
  required int row,
  required int col,
  required String text,
  int dlg1 = 0,
  int dlg2 = 0,
  int attr = 0,
  int mlen = 132,
  int maxnrchars = 0,
}) {
  final body = wireText(text);
  // dlen is a u8: a longer value would wrap and desync the atom
  if (body.length > 0xff) {
    throw ArgumentError.value(body.length, 'text',
        'etype-130 value of ${body.length} bytes exceeds the u8 dlen');
  }
  final out = Uint8List(13 + 2 + 1 + 1 + 2 + body.length);
  final bd = out.buffer.asByteData();
  bd.setUint16(0, out.length); // atom_length (post_build fixes it anyway)
  out[2] = dlg1;
  out[3] = dlg2;
  out[4] = etypeEField2;
  out[5] = area;
  out[6] = block;
  out[7] = group;
  bd.setUint16(8, row);
  bd.setUint16(10, col);
  out[12] = attr;
  final o = 13;
  bd.setUint16(o, 0); // flag1
  out[o + 2] = body.length; // dlen
  out[o + 3] = mlen; // mlen
  bd.setUint16(o + 4, maxnrchars);
  out.setRange(o + 6, out.length, body);
  return out;
}

/// Build an etype-114/0 pair is not needed — names ride the paint; this
/// builds the DYNT container item value for [atoms].
Uint8List buildDyntContainer(List<Uint8List> atoms) {
  var total = 0;
  for (final a in atoms) {
    total += a.length;
  }
  final out = Uint8List(total);
  var off = 0;
  for (final a in atoms) {
    out.setRange(off, off + a.length, a);
    off += a.length;
  }
  return out;
}
