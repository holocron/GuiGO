/// The classic dynpro DROPDOWN LISTBOX (DIAG_DGOTYP_COMBOBOX_1, etype 126)
/// and its entries — the `application/x-sapvaluesets` DataProvider rowset.
///
/// The paint carries {value-set id, function code, KEY} only; the entry
/// texts never ride it. Grounding:
///
/// * the atom payload — SAP GUI for Java's native atom reader
/// (libJPlatin64.dylib `AgiComboControl::DiagIContent`, the etype-126
/// branch reads the payload at atom offset 13): byte 0 = the FLAGS, kept
/// whole (`AgiComboControl+0x308`); bit 0x01 = a dropdown listbox, bit
/// 0x02 = a listbox WITH KEY (`AgiComboControl::IsaDropDownComboWithKey`
/// = flags & 2 → `GuiComboBoxProxy::setKeyShown` → `GuiComboBox
/// .isKeyShown`, the renderer then shows `key text`; the frontend
/// option `GuiApplication.isListboxKeyAlwaysShown` shows it for every
/// listbox). Then u16 offset + u8 length of the VALUE-SET ID ([2..4],
/// [4]), u16 offset + u8 length of the FCODE ([5..7], [7]), u16 offset
/// of the VALUE ([8..10]), u16 its length ([12..14] is the one read; [10
/// ..12] repeats it), u8 the visible width ([14]), u16 ([15..17]); the
/// strings from byte 17. GuiGo read byte 0 as a constant `01` marker:
/// a listbox WITH KEY (byte 0 = `03` — PA20 infotype 0006's
/// `P0006-STATE`, a recorded session srv[228]; FB03's year popup,
/// a recorded session srv[21]) failed that check and the
/// whole payload (binary prefix, the 32-hex id, then the key) was shown
/// as the text.
/// A value shorter than its declared length is read as far as it goes.
/// * the id: SAP GUI for Windows paints a CONTENT id (32 hex — the same id
/// for the same entry list on any screen or system), SAP GUI for Java the
/// FIELDNAME+PROGRAM (a recorded session); the push is named by it
/// (GuiComboBox.setupValueSet: `mValueID == GuiValueSet.getName`).
/// * the push (a recorded session srv[18], a recorded session
/// nodecreate_pick srv[34] / srv[37]): DP_PUT_CLIENT_TABLE TYPE
/// `application` SUBTYPE `x-sapvaluesets` CACHEABLE `X`, three X-UNKNOWN
/// columns (marker 1, key 120, text 240 bytes): `T TYPE application/x-
/// sapvaluesets`, `X NAME <id>`, then one ` <key> <text>` row per entry
/// (platinr3S.jar GuiValueSetsDriver.computeValueSets).
/// * the Windows GUI keeps the sets in a FILE cache keyed by the id
/// (sapdatap.ocx `ValuesetCache_Lookup`, `Cache1\DataP_sapvaluesetI<id>`)
/// and asks only for an id it does not hold (frontend_profile.dart
/// [windowsValueSetRequestItems]).
library;

import 'dart:typed_data';

import '../cfw/dp_cache.dart';
import '../codepages.dart';
import '../framing/diag_frame.dart';
import '../items/dynt_atom.dart';

/// One decoded etype-126 listbox atom.
class ListboxAtom {
  const ListboxAtom({
    required this.flags,
    required this.id,
    required this.fcode,
    required this.key,
    required this.width,
    required this.keyLength,
  });

  /// The payload's byte 0 (0x01 listbox, 0x02 with key).
  final int flags;

  /// The value-set id the entries are pushed under (32 hex on the Windows
  /// dialect, FIELDNAME+PROGRAM on the Java one), verbatim.
  final String id;

  /// The function code a pick fires (`=CHANGE_MAINTFLAG`), '' when none.
  final String fcode;

  /// The selected KEY as painted (blank-padded to [keyLength] or shorter
  /// when the kernel dropped its trailing blanks).
  final String key;

  /// The box's visible width in cells (key + text).
  final int width;

  /// The KEY's declared length (the field's length).
  final int keyLength;

  /// Listbox "with key": the frontend shows `key text`.
  bool get withKey => flags & 0x02 != 0;
}

/// [v] = an etype-126 atom's payload (past its 13-byte head); null when it
/// is no listbox payload (too short, no listbox flag, offsets out of it).
ListboxAtom? decodeListboxAtom(Uint8List? v) {
  const prefix = 17;
  if (v == null || v.length < prefix || v[0] & 0x01 == 0) return null;
  final idOff = (v[2] << 8) | v[3];
  final idLen = v[4];
  final fcOff = (v[5] << 8) | v[6];
  final fcLen = v[7];
  final valOff = (v[8] << 8) | v[9];
  final valLen = (v[12] << 8) | v[13];
  final strs = v.length - prefix;
  if (idOff + idLen > strs || fcOff + fcLen > strs || valOff > strs) {
    return null;
  }
  String str(int off, int len) {
    final end = off + len > strs ? strs : off + len;
    return wireDecode(Uint8List.sublistView(v, prefix + off, prefix + end));
  }

  return ListboxAtom(
    flags: v[0],
    id: str(idOff, idLen).trim(),
    fcode: str(fcOff, fcLen).trim(),
    key: str(valOff, valLen),
    width: v[14],
    keyLength: valLen,
  );
}

/// The value-set ids of every listbox atom server [frames] paint, in paint
/// order, each once — what a frontend must hold (or ask for) to show them.
List<String> listboxIdsOf(Iterable<Uint8List> frames) {
  final out = <String>[];
  for (final f in frames) {
    final dec = decompressFrame(f);
    if (dec == null) continue;
    for (final it in dec.walk.items) {
      if (!it.isAppl || it.id != 9 || it.sid != 2) continue;
      for (final a in parseDyntAtoms(Uint8List.fromList(it.value)).atoms) {
        if (a.etype != etypeCombobox1) continue;
        final id = decodeListboxAtom(a.value)?.id ?? '';
        if (id.isNotEmpty && !out.contains(id)) out.add(id);
      }
    }
  }
  return out;
}

/// One entry of a value set.
class ValueSetEntry {
  const ValueSetEntry(this.key, this.text);
  final String key;
  final String text;

  @override
  String toString() => '$key=$text';
}

/// One `application/x-sapvaluesets` set: its [name] (the listbox atom's
/// id) and its entries in wire order (the GUI may present them sorted).
class ValueSet {
  const ValueSet(this.name, this.entries, {this.cacheable = false});
  final String name;
  final List<ValueSetEntry> entries;

  /// The push's CACHEABLE scalar is `X`: the Windows GUI keeps it in its
  /// file cache.
  final bool cacheable;

  /// The text of [key] (keys compare right-trimmed), null when absent.
  String? textOf(String key) {
    final k = key.trimRight();
    for (final e in entries) {
      if (e.key == k) return e.text;
    }
    return null;
  }

  bool hasKey(String key) => textOf(key) != null;
}

const List<int> _subtype = [
  0x78, 0x2d, 0x73, 0x61, 0x70, 0x76, 0x61, 0x6c, 0x75, 0x65, 0x73, 0x65,
  0x74, 0x73, // x-sapvaluesets
];

bool _contains(Uint8List b, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= b.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      var c = b[i + j];
      if (c >= 0x41 && c <= 0x5a) c += 0x20; // case-insensitive
      if (c != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Whether DP push segment [seg] is a value-set rowset (cheap pre-check).
bool isValueSetPush(Uint8List seg) => _contains(seg, _subtype);

/// The value set one DP push segment carries, null when [seg] is none
/// (another push, no NAME row, an undecodable table).
ValueSet? decodeValueSetPush(Uint8List seg) {
  if (!isValueSetPush(seg)) return null;
  final (_, (w, n), cells) = dpColumnCells(seg, 'DATAASC');
  if (w <= 0 || cells.isEmpty) return null;
  final data = BytesBuilder(copy: false);
  for (final c in cells) {
    data.add(c);
  }
  final rows = data.takeBytes();
  // the FORMAT's columns (marker, key, text), else the oracle's geometry
  var cols = <(int, int)>[(0, 1), (1, 120), (121, 240)];
  final (_, _, fcells) = dpColumnCells(seg, 'FORMAT');
  if (fcells.isNotEmpty) {
    final fb = BytesBuilder(copy: false);
    for (final c in fcells) {
      fb.add(c);
    }
    final fc = placeholderColumns(fb.takeBytes());
    if (fc != null && fc.length >= 3) {
      cols = [for (final c in fc.take(3)) (c.offset, c.length)];
    }
  }
  if (cols.last.$1 + cols.last.$2 > w) return null;
  String cell(int r, (int, int) c) =>
      wireDecode(Uint8List.sublistView(rows, r * w + c.$1, r * w + c.$1 + c.$2))
          .trimRight();
  String? name;
  final entries = <ValueSetEntry>[];
  final count = n > 0 ? n : rows.length ~/ w;
  for (var r = 0; r < count && (r + 1) * w <= rows.length; r++) {
    final marker = cell(r, cols[0]).trim();
    if (marker == 'X') {
      name = cell(r, cols[2]).trim();
    } else if (marker == 'T') {
      continue; // `T TYPE application/x-sapvaluesets`
    } else {
      entries.add(ValueSetEntry(cell(r, cols[1]), cell(r, cols[2])));
    }
  }
  if (name == null || name.isEmpty) return null;
  final cacheable = _scalar(seg, 'CACHEABLE') == 'X';
  return ValueSet(name, List.unmodifiable(entries), cacheable: cacheable);
}

String? _scalar(Uint8List seg, String name) {
  final n = name.codeUnits;
  for (var i = 0; i + 4 + n.length + 6 <= seg.length; i++) {
    if (seg[i] != 0x02 || seg[i + 1] != 0x01) continue;
    final ln = (seg[i + 2] << 8) | seg[i + 3];
    if (ln != n.length) continue;
    var same = true;
    for (var k = 0; k < ln; k++) {
      if (seg[i + 4 + k] != n[k]) {
        same = false;
        break;
      }
    }
    if (!same) continue;
    final j = i + 4 + ln + 2;
    if (j + 4 > seg.length || seg[j] != 0x02 || seg[j + 1] != 0x03) continue;
    final vl = (seg[j + 2] << 8) | seg[j + 3];
    if (j + 4 + vl > seg.length) return null;
    return String.fromCharCodes(seg, j + 4, j + 4 + vl).trim();
  }
  return null;
}

/// Every value set the DataProvider pushes of server [frame] carry (a
/// frame's own pushes; a push streamed across frames is the session's
/// fold's).
List<ValueSet> valueSetsOfFrame(Uint8List frame) {
  final c = DpCache()..ingestFrame(frame);
  return [
    for (final u in c.order)
      if (decodeValueSetPush(c.byUrl[u]!) case final vs?) vs,
  ];
}

/// Whether [id] is a CONTENT id (the Windows dialect's 32 hex digits): the
/// same id names the same entry list everywhere, so it may be kept across
/// logons. A FIELDNAME+PROGRAM id (the Java dialect) names a field, not a
/// content — never kept past its session.
bool isContentValueSetId(String id) => _hex32.hasMatch(id);
final RegExp _hex32 = RegExp(r'^[0-9A-F]{32}$');

/// The frontend's value-set cache across sessions — the Windows GUI's
/// `Cache1\DataP_sapvaluesetI<id>` file cache (sapdatap.ocx
/// ValuesetCache_Lookup / ValuesetCache_SetAt), holding CONTENT-keyed,
/// CACHEABLE sets only. [shared] is the process-wide instance every session
/// reads; the app persists it ([onStore] / [load]).
class ValueSetCache {
  ValueSetCache({this.maxSets = 2000});

  static final ValueSetCache shared = ValueSetCache();

  /// The bound: the oldest sets go first past it.
  final int maxSets;
  final Map<String, ValueSet> _sets = {};

  /// Called for every set stored (the app writes it to disk).
  void Function(ValueSet set)? onStore;

  ValueSet? lookup(String id) => _sets[id];

  int get length => _sets.length;
  Iterable<ValueSet> get sets => _sets.values;

  /// Keep [set] when it is cacheable and content-keyed; true when stored.
  bool store(ValueSet set) {
    if (!set.cacheable || !isContentValueSetId(set.name)) return false;
    _sets
      ..remove(set.name)
      ..[set.name] = set;
    while (_sets.length > maxSets) {
      _sets.remove(_sets.keys.first);
    }
    onStore?.call(set);
    return true;
  }

  /// Seed from a persisted copy (no [onStore] call).
  void load(Iterable<ValueSet> sets) {
    for (final s in sets) {
      if (isContentValueSetId(s.name)) _sets[s.name] = s;
    }
  }

  void clear() => _sets.clear();
}

/// A session's value sets: every set pushed to it (the Java GUI's
/// GuiValueSetMgr), backed by the cross-session [cache].
class ValueSetStore {
  ValueSetStore({ValueSetCache? cache}) : cache = cache ?? ValueSetCache.shared;

  final ValueSetCache cache;
  final Map<String, ValueSet> _sets = {};

  /// The ids a value-set request named already (asked once — SAPfront.dll
  /// `AppendValuesetRequest: value set '%s' has been requested before.`).
  final Set<String> requested = {};

  /// The set named [id]: pushed to this session, else the shared cache's.
  ValueSet? operator [](String id) => _sets[id] ?? cache.lookup(id);

  /// Whether the frontend holds [id] (no request owed).
  bool holds(String id) => this[id] != null;

  /// Fold one pushed set (the latest push of a name wins).
  void put(ValueSet set) {
    _sets[set.name] = set;
    if (_sets.length > 1000) _sets.remove(_sets.keys.first);
    cache.store(set);
  }

  /// Fold DP push segment [seg] when it is a value set; the set or null.
  ValueSet? ingest(Uint8List seg) {
    final vs = decodeValueSetPush(seg);
    if (vs != null) put(vs);
    return vs;
  }

  /// The frontend's own store holds [ids] already (a replay of a real GUI
  /// whose cache was warm — it sent no request for them): none is owed.
  void assumeHeld(Iterable<String> ids) => requested.addAll(ids);

  /// The ids of [ids] (paint order) a request is owed for: not held, not
  /// asked yet, each once.
  List<String> missing(Iterable<String> ids) {
    final out = <String>[];
    for (final id in ids) {
      if (id.isEmpty || holds(id) || requested.contains(id)) continue;
      if (!out.contains(id)) out.add(id);
    }
    return out;
  }
}

/// The text a listbox shows for [key] given its entries [set]: `key text`
/// when [showKey] (the atom's with-key flag or the frontend's "show keys"
/// option), else the text; the bare key when the set does not hold it (or
/// is not known yet).
String listboxDisplayText(String key, ValueSet? set, {required bool showKey}) {
  final k = key.trimRight();
  final text = set?.textOf(k);
  if (text == null) return k.trim();
  if (!showKey || k.trim().isEmpty) return text;
  return '${k.trim()}  $text';
}
