/// Login: credential atoms, frame patches, multi-logon wall detection and
/// the Windows-dialect wall answer (raw_base/_login_atoms + raw_login_replay
/// + diag_login_wall ports).
library;

import 'dart:typed_data';

import '../codepages.dart';
import '../framing/diag_frame.dart';
import '../framing/envelope.dart';
import '../framing/decode_worker.dart' show dyntAtomsOf;
import '../items/dynt_atom.dart';
import 'frames.dart';
import 'frontend_profile.dart' show winCodepageValue, windowsWindowRect;
import 'gui_profile.dart' show emulatedGuiPatchLevel, emulatedGuiRelease;

class LoginPlane {
  const LoginPlane(this.row, this.col, this.maxlen, this.mlen, this.dlg1,
      this.dlg2, this.invisible);
  final int row;
  final int col;
  final int maxlen;
  final int mlen;
  final int dlg1;
  final int dlg2;
  final bool invisible;
}

/// The SAPMSYST/0020 logon paint (block=1 col=20; LANGU is at ROW 5, not 4):
/// the RECORDED planes of the kernel logon dynpro's four input fields, the
/// first-round default of the credential submit (audit 2026-10-23 §5.2).
/// Provenance: the reference client fixture's 0020 paint; the same cells on every
/// kernel of the corpus (a recorded session srv[0] paints
/// RSYST-MANDT / BNAME / LANGU at rows 0 / 2 / 5, col 20, mlen 3 / 12 / 2).
/// One layout snapshot all the same: a kernel repaint of 0020 (a longer
/// user name field, a moved client) breaks the seed. Direction:
/// [loginPlanes] reads the first paint's atoms and submits at the live
/// coordinates when they differ from these — taken only then, this table
/// stays the default while the paint agrees with it (or sends no atoms,
/// as the password field is never painted as an input: a prefilled 0020
/// paints its label alone).
const Map<String, LoginPlane> loginPlanes0020 = {
  'RSYST-MANDT': LoginPlane(0, 20, 3, 3, 0, 0, false),
  'RSYST-BNAME': LoginPlane(2, 20, 12, 12, 0, 1, false),
  'RSYST-BCODE': LoginPlane(3, 20, 40, 12, 4, 1, true),
  'RSYST-LANGU': LoginPlane(5, 20, 2, 2, 0, 0, false),
};

/// The logon fields' planes as the kernel's 0020 PAINT places them: for
/// every RSYST-* field whose FNAME atom (etype 114, the field's own — a
/// paint names the label at col 1 and the field at col 20) shares its row
/// and col with a value atom ([etypeInput]) of the same 9/2 item, that
/// atom's plane (row, col, maxnrchars, mlen, the dialog flags, INVISIBLE).
/// Fields the paint shows no value atom for (the password, a prefilled
/// logon's) are absent. Empty when [frames] paint no logon.
Map<String, LoginPlane> loginPlanesFromPaint(List<Uint8List> frames) {
  final out = <String, LoginPlane>{};
  for (final f in frames) {
    final dec = decompressFrame(f);
    if (dec == null) continue;
    for (final it in dec.walk.items) {
      if (!it.isAppl || it.id != 9 || (it.sid != 2 && it.sid != 16)) continue;
      final atoms = dyntAtomsOf(it).atoms;
      final inputs = <(int, int), DyntAtom>{
        for (final a in atoms)
          if (etypeInput.contains(a.etype)) (a.row, a.col): a,
      };
      for (final a in atoms) {
        if (a.etype != etypeFname) continue;
        final name = a.nameText ?? '';
        if (!loginPlanes0020.containsKey(name) || out.containsKey(name)) {
          continue;
        }
        final v = inputs[(a.row, a.col)];
        if (v == null) continue;
        out[name] = LoginPlane(v.row, v.col, v.fieldMaxnrchars, v.fieldMlen,
            v.dlgFlag1, v.dlgFlag2, v.isInvisible);
      }
    }
  }
  return out;
}

bool _samePlane(LoginPlane a, LoginPlane b) =>
    a.row == b.row &&
    a.col == b.col &&
    a.maxlen == b.maxlen &&
    a.mlen == b.mlen &&
    a.dlg1 == b.dlg1 &&
    a.dlg2 == b.dlg2 &&
    a.invisible == b.invisible;

/// The planes the credential submit writes at: [loginPlanes0020] — the
/// recorded table, the first-round default — with a field's plane
/// replaced by the live one where the 0020 [paint] (the connect reply's
/// frames) places that field ELSEWHERE; null / no logon paint / a paint
/// agreeing with the table leaves the table (audit 2026-10-23 §5.2).
Map<String, LoginPlane> loginPlanes(List<Uint8List>? paint) {
  if (paint == null) return loginPlanes0020;
  final live = loginPlanesFromPaint(paint);
  if (live.isEmpty) return loginPlanes0020;
  var changed = false;
  final out = <String, LoginPlane>{};
  for (final MapEntry(key: name, value: recorded) in loginPlanes0020.entries) {
    final l = live[name];
    if (l == null || _samePlane(l, recorded)) {
      out[name] = recorded;
    } else {
      out[name] = l;
      changed = true;
    }
  }
  return changed ? out : loginPlanes0020;
}

/// The login DyntAtom items (client / user / password / optional language) —
/// etype-130 value atoms, YES3D attr, BCODE additionally INVISIBLE — at
/// [planes] ([loginPlanes0020] when null; [loginPlanes] for a paint's).
List<Uint8List> loginAtoms(String? client, String user, String pw,
    [String language = '', Map<String, LoginPlane>? planes]) {
  final at = planes ?? loginPlanes0020;
  Uint8List atom(LoginPlane p, String text, {bool invisible = false}) {
    final body = wireText(text);
    // the atom's dlen is one byte: a longer value must not wrap silently
    if (body.length > 255) {
      throw ArgumentError('logon value too long (${body.length} bytes)');
    }
    const head = 13;
    const tailFixed = 2 + 1 + 1 + 2; // flag1 u16, dlen u8, mlen u8, maxn u16
    final out = Uint8List(head + tailFixed + body.length);
    final bd = out.buffer.asByteData();
    bd.setUint16(0, out.length); // atom_length
    out[2] = p.dlg1;
    out[3] = p.dlg2;
    out[4] = etypeEField2; // 130
    out[6] = 1; // block
    bd.setUint16(8, p.row);
    bd.setUint16(10, p.col);
    out[12] = 0x40 | (invisible ? 0x02 : 0); // YES3D (+INVISIBLE)
    final o = head;
    bd.setUint16(o, 0); // flag1
    out[o + 2] = body.length; // dlen
    out[o + 3] = p.mlen;
    bd.setUint16(o + 4, p.maxlen);
    out.setRange(o + 6, out.length, body);
    return out;
  }

  final atoms = <Uint8List>[];
  if (client != null && client.isNotEmpty) {
    atoms.add(atom(at['RSYST-MANDT']!, client));
  }
  atoms.add(atom(at['RSYST-BNAME']!, user));
  atoms.add(atom(at['RSYST-BCODE']!, pw, invisible: true));
  if (language.isNotEmpty) {
    atoms.add(atom(at['RSYST-LANGU']!, language));
  }
  return atoms;
}

Uint8List _concatAtoms(List<Uint8List> atoms) {
  var n = 0;
  for (final a in atoms) {
    n += a.length;
  }
  final out = Uint8List(n);
  var off = 0;
  for (final a in atoms) {
    out.setRange(off, off + a.length, a);
    off += a.length;
  }
  return out;
}

Uint8List _rebuildItem(DiagItem it, Uint8List value) {
  return it.type == itemAppl4 ? buildAppl4Item(it.id, it.sid, value) : buildApplItem(it.id, it.sid, value);
}

/// Replace the login DyntAtom (item 9/2) of the captured login frame with one
/// carrying THIS session's credentials, keeping every other item intact;
/// re-serialized LZH-compressed as the real GUI's logon submit is.
Uint8List patchLoginFrame(Uint8List rawFrame,
    {String? client, required String user, required String pw, String language = ''}) {
  final plain = plainFrame(rawFrame);
  final walk = walkItems(Uint8List.sublistView(plain, diagHeaderLen));
  final dynt = _concatAtoms(loginAtoms(client, user, pw, language));
  final out = <Uint8List>[];
  var replaced = false;
  for (final it in walk.items) {
    if (!replaced && it.isAppl && it.id == 9 && it.sid == 2) {
      out.add(_rebuildItem(it, dynt));
      replaced = true;
    } else {
      out.add(it.itemBytes);
    }
  }
  if (!replaced) {
    throw StateError('login DyntAtom (9/2) not present in login frame');
  }
  return clientFrame(out, mode: plain[0]);
}

/// Re-serialize a captured client frame with its Step item set to `step`.
Uint8List patchStep(Uint8List rawFrame, int step) {
  final plain = plainFrame(rawFrame);
  final walk = walkItems(Uint8List.sublistView(plain, diagHeaderLen));
  final out = <Uint8List>[];
  var replaced = false;
  for (final it in walk.items) {
    if (!replaced && it.isAppl && it.id == 4 && it.sid == 38) {
      out.add(stepItem(step));
      replaced = true;
    } else {
      out.add(it.itemBytes);
    }
  }
  return clientFrame(out, mode: plain[0]);
}

/// Byte-level patch of the login frame's window size: SES dims (offsets
/// 14/15 of the 16-byte SES value) + METRICS Y3/X3 (same digit width only).
Uint8List patchScreenSize(Uint8List rawFrame, int rows, int cols) {
  final plain = plainFrame(rawFrame);
  final b = Uint8List.fromList(plain);
  // SES dims: patch the SES item's value in place
  final walk = walkItems(Uint8List.sublistView(b, diagHeaderLen));
  for (final it in walk.items) {
    if (it.type == itemSes && it.value.length >= 16) {
      final valueOff = it.value.offsetInBytes;
      b[valueOff + 14] = rows & 0xff;
      b[valueOff + 15] = cols & 0xff;
      break;
    }
  }
  // METRICS pixel window: Y3 = rows*Y2, X3 = cols*X2 (same digit width only)
  final s = String.fromCharCodes(b);
  final y2 = _metric(s, 'Y2') ?? 29;
  final x2 = _metric(s, 'X2') ?? 8;
  _patchMetric(b, s, 'Y3', (rows * y2).toString());
  _patchMetric(b, s, 'X3', (cols * x2).toString());
  // re-serialize compressed
  final items = <Uint8List>[for (final it in walk.items) it.itemBytes];
  return clientFrame(items, mode: b[0]);
}

int? _metric(String s, String attr) {
  final m = RegExp('$attr="(\\d+)"').firstMatch(s);
  return m == null ? null : int.tryParse(m.group(1)!);
}

void _patchMetric(Uint8List b, String s, String attr, String val) {
  final m = RegExp('$attr="(\\d+)"').firstMatch(s);
  if (m == null) return;
  final orig = m.group(1)!;
  if (orig.length != val.length) return; // same width -> safe in place only
  final gs = m.start + attr.length + 2; // position of the digits
  for (var i = 0; i < val.length; i++) {
    b[gs + i] = val.codeUnitAt(i);
  }
}

// ---------------------------------------------------------------------------
// Multi-logon wall
// ---------------------------------------------------------------------------

class WallInfo {
  WallInfo(this.nameToRow, this.rowToOption,
      {this.popupGeometry, this.popupXy});
  final Map<String, int> nameToRow;

  /// row -> (label, currentlyOn)
  final Map<int, (String, bool)> rowToOption;

  /// The wall POPUP's painted 16/12/6 (the 33-byte SCROLL_INFOS2 value:
  /// scroll pair, area, (0, 0), visible rows x cols, flag) — the first
  /// 16/12/6 after the popup's 16/12/7 window item in the frame carrying
  /// the MULTI_LOGON atoms; null when the paint declares none
  /// ([readWall]). What the real GUI's answer echoes verbatim and sizes its
  /// SES dims from ([windowsWallItems]).
  final Uint8List? popupGeometry;

  /// The wall paint's SES `x` / `y` (value bytes 8 / 9: the popup's
  /// position the kernel sent, pysap SAPDiagSES) — echoed by the answer;
  /// null when the paint carries no SES before the atoms.
  final (int, int)? popupXy;

  bool get isWall => nameToRow.isNotEmpty;

  /// The popup's visible rows x cols from [popupGeometry] (u32 at 24 / 28);
  /// null without one.
  (int, int)? get popupCells {
    final g = popupGeometry;
    if (g == null || g.length < 32) return null;
    final bd = ByteData.sublistView(g);
    return (bd.getUint32(24), bd.getUint32(28));
  }
}

/// Parse the wall's atoms from server frames: radio rows + MULTI_LOGON_OPT
/// FNAME atoms, and the popup's own paint around them ([WallInfo
/// .popupGeometry] / [WallInfo.popupXy]: the last SES and 16/12/7 before
/// the atoms' item, the first 16/12/6 after that window item).
WallInfo readWall(List<Uint8List> frames) {
  final nameToRow = <String, int>{};
  final rowToOption = <int, (String, bool)>{};
  Uint8List? popupGeometry;
  (int, int)? popupXy;
  for (final f in frames) {
    final dec = decompressFrame(f);
    if (dec == null) continue;
    final walk = dec.walk;
    Uint8List? ses, geometry;
    var windowSeen = false;
    for (final it in walk.items) {
      if (it.type == itemSes && it.value.length >= 16) {
        ses = it.value;
        continue;
      }
      if (it.isAppl && it.id == 12 && it.sid == 7) {
        windowSeen = true;
        geometry = null;
        continue;
      }
      if (it.isAppl && it.id == 12 && it.sid == 6) {
        if (windowSeen && geometry == null) geometry = it.value;
        continue;
      }
      if (!it.isAppl || it.id != 9 || (it.sid != 2 && it.sid != 16)) continue;
      var wallAtoms = false;
      for (final a in dyntAtomsOf(it).atoms) {
        if (a.etype == etypeRadioButton3) {
          final on = a.radiobuttonButton == 1 ||
              a.radiobuttonButton == 0x58 ||
              a.dlgFlag2 & 0x80 != 0;
          rowToOption[a.row] = (a.radiobuttonText ?? '', on);
        } else if (a.etype == etypeFname) {
          final nm = a.nameText ?? '';
          if (nm.contains('MULTI_LOGON_OPT')) {
            nameToRow[nm] = a.row;
            wallAtoms = true;
          }
        }
      }
      if (wallAtoms) {
        popupGeometry ??= geometry == null ? null : Uint8List.fromList(geometry);
        popupXy ??= ses == null ? null : (ses[8], ses[9]);
      }
    }
  }
  return WallInfo(nameToRow, rowToOption,
      popupGeometry: popupGeometry, popupXy: popupXy);
}

/// The radio value atoms' label width of the wall answer (the reference
/// answer's 0x4e, a recorded session gui raw[2]).
const int _winWallOptionWidth = 0x4e;

/// The multi-logon wall's default pick when no live selection is known:
/// row 0x0b on, row 0x10 cleared — the reference answer's rows (OPT2 at
/// 11, OPT3 at 16 in a recorded session raw[2] and the the test system
/// paint, a recorded session srv[0]); a live wall's rows come
/// from its MULTI_LOGON_OPT atoms ([readWall]), this pair rides only an
/// answer built without a paint (audit 2026-10-23 §6.2).
const int _wallDefaultOnRow = 0x0b, _wallDefaultOffRow = 0x10;

/// The wall popup of the reference wall paint: 18 visible rows x 82 cols
/// (its 16/12/7 `0012 0052`, a recorded session srv[0]) —
/// what the recorded answer's SES dims and SCROLL_INFOS2 below are the
/// echo of (audit 2026-10-23 §6.2).
const (int, int) recordedWallPopupCells = (18, 82);

/// The recorded wall answer's SES dims (value bytes 14 / 15: the popup's
/// pixel pair, low bytes — a recorded session gui raw[2] `93 3e`)
/// = [wallSesDims] of [recordedWallPopupCells] at the reference kernel
/// cell: 18 x 22 + 7 = 403 → 0x93, 82 x 7 = 574 → 0x3e. Sent as long as the
/// live popup paints 18 x 82; another popup takes the derived pair.
const (int, int) recordedWallSesDims = (0x93, 0x3e);

/// The recorded wall answer's SES x / y (value bytes 8 / 9, `0a 0a`): the
/// popup position the wall paint's own SES carries (srv[0] above `… 11 01
/// 0a 0a …`), echoed. Sent as long as the live paint carries the same
/// pair (or none); another pair is echoed instead.
const (int, int) recordedWallPopupXy = (0x0a, 0x0a);

/// The recorded wall answer's SCROLL_INFOS2 (16/12/6: scroll pair, area,
/// (0, 0), visible part — `17 80 17 80 0 0 18 82`, flag 1) = the popup's
/// painted 16/12/6 echoed verbatim (srv[0] above). Sent as long as the
/// live popup paints [recordedWallPopupCells]; another popup's 16/12/6 is
/// echoed instead ([WallInfo.popupGeometry]).
const List<int> recordedWallScrollInfos = [17, 80, 17, 80, 0, 0, 18, 82];

/// The 16/4/15 value of the wall answer (109 = 0x6d; the per-round
/// identity block's is [winFrameCounterValue] 0x5d): the reference GUI's
/// connection-side flush counter, which varies per frame in the oracle
/// (0x5d, 0x6d, 0x5bd, 0x158 — reference client raw_services._GOS_415) and the
/// kernel ignores. Replayed as recorded; direction: one per-session
/// counter for both once an A/B run pins that the kernel ignores it
/// (audit 2026-10-23 §6.5).
const int wallFrameCounterValue = 109;

/// The kernel cell the wall answer's SES dims are sized with when the
/// caller passes none: the reference FONTMETRIC's 22 x 7 px
/// ([ActionContext.kernelCell]'s default).
const ({int height, int width}) wallKernelCell = (height: 22, width: 7);

/// The SES dims a Windows round sent from inside a popup of [rows] x
/// [cols] carries: the low bytes of the popup's pixel size, rows x cell
/// height + 7 and cols x cell width (frontend_profile.dart
/// windowsModalSesDims — 272 of the corpus' 300 Windows popup rounds).
(int, int) wallSesDims((int, int) cells, {({int height, int width})? cell}) {
  final c = cell ?? wallKernelCell;
  final (rows, cols) = cells;
  return ((rows * c.height + 7) & 0xff, (cols * c.width) & 0xff);
}

Uint8List _u32be(List<int> vals) {
  final bd = ByteData(vals.length * 4);
  for (var i = 0; i < vals.length; i++) {
    bd.setUint32(i * 4, vals[i]);
  }
  return bd.buffer.asUint8List();
}

/// The Windows multi-logon answer (diag_login_wall _OPT2_WIN_ENVELOPE
/// spelled as fields): the live Step; the SES of a function-key Enter in
/// the wall popup (eventarray 0x50, modal_no 1, the popup's x / y and
/// dims); the okcode-extra 16/4/36 ([windowRect], else
/// [windowsWindowRect]'s reference value); the Windows codepage and
/// identity atoms (16/4/15 = [wallFrameCounterValue] on this round); OK
/// event mode 0x05; the popup's SCROLL_INFOS2 (17 x 80 area, 18 x 82
/// visible); a zero 16/10/1; the radio group rebuilt from the live
/// selection (chosen on, previously-on siblings cleared) and the cursor
/// on the chosen row.
///
/// The popup figures (audit 2026-10-23 §6.2): the recorded answer's
/// ([recordedWallSesDims], [recordedWallPopupXy], [recordedWallScrollInfos])
/// are the first-round default — the bytes a live kernel accepts today;
/// the live paint's ([wall]'s popup geometry and SES, [readWall]) replace
/// them only when the paint shows ANOTHER popup than the recorded 18 x 82
/// at (10, 10): then the SES dims are [wallSesDims] of the painted cells
/// at [cell] ([wallKernelCell] when null) and the 16/12/6 is the painted
/// one echoed, as every other popup round derives them.
List<Uint8List> windowsWallItems(int step, WallInfo wall, int chosenRow,
    {Uint8List? windowRect, ({int height, int width})? cell}) {
  final group = <Uint8List>[];
  if (chosenRow >= 0) {
    // ONLY the changed members ride the answer: the chosen row turned on
    // plus the previously-painted-on sibling(s) cleared — the server
    // pre-selects OPT3 ("terminate this logon"), and leaving that on
    // alongside the choice stalls the logon. An explicit clear of a
    // never-on row is an invalid delta the kernel discards the answer
    // for; the real GUI sends exactly the chosen + previously-on pair
    // (a recorded session gui raw[2]: rows 0x0b 'X' / 0x10 ' ',
    // OPT1's row absent).
    group.add(radioValueAtom(0, 1, 1, chosenRow, 0, true,
        labelWidth: _winWallOptionWidth));
    for (final row in wall.rowToOption.keys.toList()..sort()) {
      final paintedOn = wall.rowToOption[row]?.$2 ?? false;
      if (row != chosenRow && paintedOn) {
        group.add(radioValueAtom(0, 1, 1, row, 0, false,
            labelWidth: _winWallOptionWidth));
      }
    }
  } else {
    // no live selection (offline/synthetic): the reference answer's pair
    group
      ..add(radioValueAtom(0, 1, 1, _wallDefaultOnRow, 0, true,
          labelWidth: _winWallOptionWidth))
      ..add(radioValueAtom(0, 1, 1, _wallDefaultOffRow, 0, false,
          labelWidth: _winWallOptionWidth));
  }
  // the popup's figures: the recorded answer's unless the paint shows
  // another popup (see above)
  final cells = wall.popupCells;
  final livePopup = cells != null && cells != recordedWallPopupCells;
  final (dimRow, dimCol) =
      livePopup ? wallSesDims(cells, cell: cell) : recordedWallSesDims;
  final (x, y) = wall.popupXy ?? recordedWallPopupXy;
  final scrollInfos = livePopup
      ? wall.popupGeometry!
      : Uint8List.fromList([..._u32be(recordedWallScrollInfos), 1]);
  // the SES value rides at [1..16]: value byte k is item byte k + 1
  final ses = Uint8List(17)
    ..[0] = itemSes
    ..[1] = 0x50 // the Windows FKEY event, eventid1 0 (Enter)
    ..[8] = 1 // modal_no
    ..[9] = x // the popup's position, the paint's SES x / y echoed
    ..[10] = y
    ..[15] = dimRow // dims: the popup window's pixel pair, low bytes
    ..[16] = dimCol;
  final okEvent = Uint8List(22)..[1] = 0x05;
  // the cursor: depth 1, row u16 BE, col 0, offset 0, path = area 0
  final cursor = Uint8List(10)..[0] = 1;
  cursor.buffer
      .asByteData()
      .setUint16(1, chosenRow >= 0 ? chosenRow : _wallDefaultOnRow);
  return [
    stepItem(step),
    ses,
    buildApplItem(4, 36, windowRect ?? windowsWindowRect(null)),
    buildApplItem(6, 35, winCodepageValue),
    buildApplItem(4, 9, Uint8List.fromList(emulatedGuiRelease.codeUnits)),
    buildApplItem(4, 29, Uint8List.fromList(emulatedGuiPatchLevel.codeUnits)),
    buildApplItem(4, 15, _u32be([wallFrameCounterValue])),
    buildApplItem(4, 25, Uint8List(2)),
    buildApplItem(5, 1, okEvent),
    // SCROLL_INFOS2: scroll pair, area, (0, 0), visible part, flag 1
    buildApplItem(12, 6, scrollInfos),
    buildApplItem(10, 1, Uint8List(9)),
    buildApplItem(9, 2, _concatAtoms(group)),
    buildApplItem(9, 11, cursor),
    eomBytes,
  ];
}

/// The user-facing wall choices.
enum WallOption { keepOthers, endOthers, cancelLogon }

/// The wall row carrying the named option (OPT1 end-others, OPT2
/// keep-others, OPT3 terminate this logon); null when not offered.
int? wallRowFor(WallInfo wall, WallOption which) {
  final tag = switch (which) {
    WallOption.keepOthers => 'OPT2',
    WallOption.endOthers => 'OPT1',
    WallOption.cancelLogon => 'OPT3',
  };
  for (final e in wall.nameToRow.entries) {
    if (e.key.contains(tag)) return e.value;
  }
  return null;
}

/// Choose the wall row: keep-others (OPT2) by default; OPT1 when
/// [endOtherSessions]. Returns null when keep-others is unavailable.
int? chooseWallRow(WallInfo wall, {required bool endOtherSessions}) {
  if (endOtherSessions) {
    for (final e in wall.nameToRow.entries) {
      if (e.key.contains('OPT1')) return e.value;
    }
    throw ArgumentError('wall has no OPT1');
  }
  for (final e in wall.nameToRow.entries) {
    if (e.key.contains('OPT2')) return e.value;
  }
  // no OPT2: this system disallows multiple logons — caller decides
  return null;
}

/// The ready-to-send wall answer frame (compressed).
Uint8List wallAnswerFrame(List<Uint8List> serverFrames, int step,
    {bool endOtherSessions = false}) {
  final wall = readWall(serverFrames);
  final row = chooseWallRow(wall, endOtherSessions: endOtherSessions);
  if (row == null) {
    throw StateError('WallKeepOthersUnavailable');
  }
  return clientFrame(windowsWallItems(step, wall, row));
}
