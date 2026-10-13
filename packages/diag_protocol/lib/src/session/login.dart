/// Login: credential atoms, frame patches, multi-logon wall detection and
/// the Windows-dialect wall answer (raw_base/_login_atoms + raw_login_replay
/// + diag_login_wall ports).
library;

import 'dart:typed_data';

import '../codepages.dart';
import '../framing/diag_frame.dart';
import '../framing/envelope.dart';
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

/// The SAPMSYST/0020 logon paint (block=1 col=20; LANGU is at ROW 5, not 4).
const Map<String, LoginPlane> loginPlanes0020 = {
  'RSYST-MANDT': LoginPlane(0, 20, 3, 3, 0, 0, false),
  'RSYST-BNAME': LoginPlane(2, 20, 12, 12, 0, 1, false),
  'RSYST-BCODE': LoginPlane(3, 20, 40, 12, 4, 1, true),
  'RSYST-LANGU': LoginPlane(5, 20, 2, 2, 0, 0, false),
};

/// The login DyntAtom items (client / user / password / optional language) —
/// etype-130 value atoms, YES3D attr, BCODE additionally INVISIBLE.
List<Uint8List> loginAtoms(String? client, String user, String pw,
    [String language = '']) {
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
    atoms.add(atom(loginPlanes0020['RSYST-MANDT']!, client));
  }
  atoms.add(atom(loginPlanes0020['RSYST-BNAME']!, user));
  atoms.add(atom(loginPlanes0020['RSYST-BCODE']!, pw, invisible: true));
  if (language.isNotEmpty) {
    atoms.add(atom(loginPlanes0020['RSYST-LANGU']!, language));
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
  WallInfo(this.nameToRow, this.rowToOption);
  final Map<String, int> nameToRow;

  /// row -> (label, currentlyOn)
  final Map<int, (String, bool)> rowToOption;

  bool get isWall => nameToRow.isNotEmpty;
}

/// Parse the wall's atoms from server frames: radio rows + MULTI_LOGON_OPT
/// FNAME atoms.
WallInfo readWall(List<Uint8List> frames) {
  final nameToRow = <String, int>{};
  final rowToOption = <int, (String, bool)>{};
  for (final f in frames) {
    final dec = decompressFrame(f);
    if (dec == null) continue;
    final walk = dec.walk;
    for (final it in walk.items) {
      if (!it.isAppl || it.id != 9 || (it.sid != 2 && it.sid != 16)) continue;
      for (final a in parseDyntAtoms(it.value).atoms) {
        if (a.etype == etypeRadioButton3) {
          final on = a.radiobuttonButton == 1 ||
              a.radiobuttonButton == 0x58 ||
              a.dlgFlag2 & 0x80 != 0;
          rowToOption[a.row] = (a.radiobuttonText ?? '', on);
        } else if (a.etype == etypeFname) {
          final nm = a.nameText ?? '';
          if (nm.contains('MULTI_LOGON_OPT')) {
            nameToRow[nm] = a.row;
          }
        }
      }
    }
  }
  return WallInfo(nameToRow, rowToOption);
}

const int _winWallOptionWidth = 0x4e;

/// The multi-logon wall's default pick when no live selection is known:
/// row 0x0b on, row 0x10 cleared (the reference answer's).
const int _wallDefaultOnRow = 0x0b, _wallDefaultOffRow = 0x10;

Uint8List _u32be(List<int> vals) {
  final bd = ByteData(vals.length * 4);
  for (var i = 0; i < vals.length; i++) {
    bd.setUint32(i * 4, vals[i]);
  }
  return bd.buffer.asUint8List();
}

/// The Windows multi-logon answer (diag_login_wall _OPT2_WIN_ENVELOPE
/// spelled as fields): the live Step; the SES of a function-key Enter in
/// the wall popup (eventarray 0x50, modal_no 1, the popup's dims); the
/// okcode-extra 16/4/36 ([windowRect], else [windowsWindowRect]'s
/// reference value); the Windows codepage and
/// identity atoms (16/4/15 = 109 on this round); OK event mode 0x05; the
/// popup's SCROLL_INFOS2 (17 x 80 area, 18 x 82 visible); a zero 16/10/1;
/// the radio group rebuilt from the live selection (chosen on,
/// previously-on siblings cleared) and the cursor on the chosen row.
List<Uint8List> windowsWallItems(int step, WallInfo wall, int chosenRow,
    {Uint8List? windowRect}) {
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
  final ses = Uint8List(17)
    ..[0] = itemSes
    ..[1] = 0x50 // the Windows FKEY event, eventid1 0 (Enter)
    ..[8] = 1 // modal_no
    ..[9] = 0x0a
    ..[10] = 0x0a
    ..[15] = 0x93 // dims: the popup window's pixel pair, low bytes
    ..[16] = 0x3e;
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
    buildApplItem(4, 15, _u32be([109])),
    buildApplItem(4, 25, Uint8List(2)),
    buildApplItem(5, 1, okEvent),
    // SCROLL_INFOS2: scroll pair, area, (0, 0), visible part, flag 1
    buildApplItem(12, 6,
        Uint8List.fromList([..._u32be([17, 80, 17, 80, 0, 0, 18, 82]), 1])),
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
