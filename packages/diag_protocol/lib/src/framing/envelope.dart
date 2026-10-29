/// Structural DIAG item-envelope walk (diag_envelope.walk port).
///
/// Item envelope ABI: `item_type` u8; `item_id`/`item_sid` u8 present on
/// APPL (0x10) / APPL4 (0x12) only; value length u16 BE on APPL, u32 BE on
/// DIAG_XMLBLOB (0x11) / APPL4; every other type a fixed value size.
library;

import 'dart:typed_data';

// Item types.
const int itemSes = 0x01;
const int itemIco = 0x02;
const int itemTit = 0x03;
const int itemDiagMessage = 0x07;
const int itemOkc = 0x08;
const int itemChl = 0x09;
const int itemSfe = 0x0a;
const int itemSba = 0x0b;
const int itemEom = 0x0c;
const int itemAppl = 0x10;
const int itemXmlBlob = 0x11;
const int itemAppl4 = 0x12;
const int itemSlc = 0x13;
const int itemSba2 = 0x15;

// APPL ids (subset of pysap's diag_appl_ids).
const int applScript = 0x01;
const int applGraph = 0x02;
const int applIxos = 0x03;
const int applStUser = 0x04;
const int applDynn = 0x05;
const int applStR3Info = 0x06;
const int applPopu = 0x07;
const int applRfcTr = 0x08;
const int applDynt = 0x09;
const int applContainer = 0x0a;
const int applMnEntry = 0x0b;
const int applVarInfo = 0x0c;
const int applControl = 0x0e;
const int applUiEvent = 0x0f;
const int applAccList = 0x12;
const int applRcui = 0x13;
const int applGuiPacket = 0x14;

/// Fixed value sizes of non-length-prefixed types (diag_sba2 corrected
/// table); 0xffff = unknown type, value = rest of the buffer.
const Map<int, int> fixedItemLengths = {
  itemSes: 16,
  itemIco: 20,
  itemTit: 3,
  itemDiagMessage: 76,
  itemOkc: 0,
  itemChl: 22,
  itemSfe: 3,
  itemSba: 2,
  itemEom: 0,
  itemSlc: 2,
  itemSba2: 4,
};

const int restOfBuffer = 0xffff;

class DiagItem {
  DiagItem(this.type, this.id, this.sid, this.declaredLen, this.value,
      this.itemBytes);

  final int type;

  /// APPL item id (0x01..0x14); -1 off APPL/APPL4.
  final int id;

  /// APPL item sub-id; -1 off APPL/APPL4.
  final int sid;
  final int declaredLen;
  final Uint8List value;
  final Uint8List itemBytes;

  bool get isAppl => type == itemAppl || type == itemAppl4;
  bool get isEom => type == itemEom;
}

class ItemWalk {
  ItemWalk(this.items, this.trailing);
  final List<DiagItem> items;

  /// Bytes left when the buffer ends inside an item header (the pysap Raw
  /// layer) — non-null only for truncated streams.
  final Uint8List? trailing;
}

/// Walk one DIAG item stream (a frame body after its header, or a nested
/// RFC-carried stream).
ItemWalk walkItems(Uint8List body) {
  final out = <DiagItem>[];
  final n = body.length;
  var off = 0;
  final bd = body.buffer.asByteData(body.offsetInBytes, body.lengthInBytes);
  while (off < n) {
    final t = body[off];
    int h, ln, i = -1, s = -1;
    if (t == itemAppl || t == itemAppl4) {
      if (t == itemAppl) {
        h = 5;
        if (off + h > n) return ItemWalk(out, Uint8List.sublistView(body, off));
        ln = bd.getUint16(off + 3);
      } else {
        h = 7;
        if (off + h > n) return ItemWalk(out, Uint8List.sublistView(body, off));
        ln = bd.getUint32(off + 3);
      }
      i = body[off + 1];
      s = body[off + 2];
    } else if (t == itemXmlBlob) {
      h = 5;
      if (off + h > n) return ItemWalk(out, Uint8List.sublistView(body, off));
      ln = bd.getUint32(off + 1);
    } else {
      h = 1;
      ln = fixedItemLengths[t] ?? restOfBuffer;
    }
    var end = off + h + ln;
    if (end > n) end = n; // value cut at the buffer end (StrLenField)
    final v = Uint8List.sublistView(body, off + h, end);
    out.add(DiagItem(t, i, s, ln, v, Uint8List.sublistView(body, off, end)));
    off = end;
  }
  return ItemWalk(out, null);
}

// --- item builders -----------------------------------------------------------

/// `<type u8><id u8><sid u8><len u16 BE><value>` (APPL item). Throws
/// [ArgumentError] for a value over 65535 bytes (the u16 length would wrap
/// and desync the server's item walk — such a value needs an APPL4 item,
/// frames.dart [buildAppl4Item]) or an id/sid outside 0..255.
Uint8List buildApplItem(int id, int sid, Uint8List value) {
  if (value.length > 0xffff) {
    throw ArgumentError.value(value.length, 'value.length',
        'APPL $id/$sid value exceeds the u16 length '
        '(an APPL4 item carries it: buildAppl4Item)');
  }
  RangeError.checkValueInInterval(id, 0, 0xff, 'id');
  RangeError.checkValueInInterval(sid, 0, 0xff, 'sid');
  final out = Uint8List(5 + value.length);
  final bd = out.buffer.asByteData();
  out[0] = itemAppl;
  out[1] = id;
  out[2] = sid;
  bd.setUint16(3, value.length);
  out.setRange(5, out.length, value);
  return out;
}

/// EOM marker (type 0x0c, no payload).
final Uint8List eomBytes = Uint8List.fromList([itemEom]);

// --- byte search -------------------------------------------------------------

/// Whether [haystack] holds [needle]'s code units (latin-1 bytes) as a
/// contiguous run — the allocation-free marker test (`OLE_FLUSH_CALL`,
/// `DP_GET`, `<SVARS>` …). It replaces `String.fromCharCodes(value).
/// contains(needle)`, which copied a whole multi-MB call value into a String
/// for one substring test. Same answer for every
/// input: a code unit over 0xff never matches a byte, as it never matched a
/// latin-1 char either.
bool containsBytes(Uint8List haystack, String needle) =>
    indexOfBytes(haystack, needle) >= 0;

/// The first index at or after [from] where [needle]'s code units start in
/// [haystack], or -1 ([containsBytes]). An empty needle is found at [from].
int indexOfBytes(Uint8List haystack, String needle, [int from = 0]) {
  final n = needle.length;
  if (n == 0) return from <= haystack.length ? from : -1;
  final first = needle.codeUnitAt(0);
  final last = haystack.length - n;
  for (var i = from < 0 ? 0 : from; i <= last; i++) {
    if (haystack[i] != first) continue;
    var j = 1;
    while (j < n && haystack[i + j] == needle.codeUnitAt(j)) {
      j++;
    }
    if (j == n) return i;
  }
  return -1;
}
