/// Client DIAG frame construction: step item, whole-frame LZH compression,
/// UI-event helpers (diag_construct port).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../framing/diag_frame.dart';
import '../framing/envelope.dart';
import '../items/dynt_atom.dart' show etypeCheckButton3, etypeRadioButton3;
import '../lzh/lzh.dart';

/// The `16/4/38` Step item every client frame opens with — the dialog-step
/// counter the server echoes/advances. Value: 4-byte BE int.
Uint8List stepItem(int step) {
  final value = Uint8List(4);
  value.buffer.asByteData().setUint32(0, step);
  return buildApplItem(4, 38, value);
}

/// `msg_info` (header byte 5) the real GUI sets with `compress` (byte 7):
/// 0x01 on every LZH-compressed client frame, 0x00 on plain ones.
const int msgInfoCompressed = 0x01;

/// The uncompressed item stream of a compressed client frame over the
/// kernel's request buffer, as [clientFrame] built it: the request stream
/// plans its chunks from it instead of inflating the frame again (audit
/// 2026-10-17 N3). Null for any other frame.
Uint8List? clientFrameBody(Uint8List frame) => _oversizeBodies[frame];

final Expando<Uint8List> _oversizeBodies = Expando('oversize client bodies');

/// Serialise one client DIAG frame: 8-byte header + item stream, LZH-
/// compressed (whole-frame codec both dialects use on every client frame ≥
/// ~150 B except the connect frame).
Uint8List clientFrame(List<Uint8List> itemBytes,
    {int mode = 0, bool compress = true}) {
  final stream = BytesBuilder();
  for (final b in itemBytes) {
    stream.add(b);
  }
  final body = stream.takeBytes();
  final h = DiagFrameHeader(
      mode: mode & 0xff,
      comFlag: 0,
      modeStat: 0,
      errNo: 0,
      msgType: 0,
      msgInfo: compress ? msgInfoCompressed : 0,
      msgRc: 0,
      compress: compress ? 1 : 0);
  final payload = compress ? lzhCompress(body) : body;
  final out = Uint8List(diagHeaderLen + payload.length);
  out[0] = h.mode;
  out[1] = h.comFlag;
  out[2] = h.modeStat;
  out[3] = h.errNo;
  out[4] = h.msgType;
  out[5] = h.msgInfo;
  out[6] = h.msgRc;
  out[7] = h.compress;
  out.setRange(diagHeaderLen, out.length, payload);
  if (compress && body.length > kernelRequestBodyMax) _oversizeBodies[out] = body;
  return out;
}

/// `rawFrame` with its item stream UNCOMPRESSED (same header, compress=0) —
/// byte-level patches work on this form.
Uint8List plainFrame(Uint8List rawFrame) {
  final d = decompressFrame(rawFrame);
  if (d == null || d.partial != null) return rawFrame;
  return rebuildUncompressed(rawFrame)!;
}

/// The 16-byte `16/15/1` UI_EVENT_SOURCE value of a FUNCTION-KEY press on the
/// dynpro: byte 0 = valid flags (0x08 = key data), bytes 1-2 = event type 7,
/// bytes 3-4 = control type 10 (DYNPRO), byte 5 = the key number.
Uint8List uiEventFunctionKey(int vkey) {
  final v = Uint8List(16);
  v[0] = 0x08;
  v[1] = 0x00;
  v[2] = 0x07;
  v[3] = 0x00;
  v[4] = 0x0a;
  v[5] = vkey & 0xff;
  return v;
}

/// The 24-byte VALUE atom of one CHOICE element on its own plane — a radio
/// group member ([etypeRadioButton3], 129) or a checkbox
/// ([etypeCheckButton3], 128) — the shape the Windows dialect writes for
/// both: the PAINTED dlg flags echoed, PROPFONT, the state `X` / blank, the
/// PAINTED visible label length ([labelWidth]: the atom's declared width,
/// not the label text's length) and no label text. The checkbox is the
/// radio's layout with its own etype (reference client screen_checkbox
/// .checkbox_value_atom; byte oracle a recorded session gui[38]: `0018 0000
/// 80 00 01 00 0003 0004 20 58 0026` + eight zero bytes, the real GUI
/// ticking INPLACE on srv[46]'s paint).
Uint8List choiceValueAtom(
    int etype, int area, int block, int group, int row, int col, bool on,
    {int labelWidth = 0, int dlg1 = 0, int dlg2 = 0}) {
  const attrPropfont = 0x20;
  const atomLen = 24;
  final out = Uint8List(atomLen);
  final bd = out.buffer.asByteData();
  bd.setUint16(0, atomLen);
  out[2] = dlg1 & 0xff;
  out[3] = dlg2 & 0xff;
  out[4] = etype & 0xff;
  out[5] = area & 0xff;
  out[6] = block & 0xff;
  out[7] = group & 0xff;
  bd.setUint16(8, row & 0xffff);
  bd.setUint16(10, col & 0xffff);
  out[12] = attrPropfont;
  out[13] = on ? 0x58 : 0x20; // 'X' chosen / ' ' cleared
  bd.setUint16(14, labelWidth & 0xffff);
  return out;
}

/// The etype-129 radio VALUE atom of one radio group member — what a radio
/// click puts on the wire for every CHANGED member of the group
/// ([choiceValueAtom]).
Uint8List radioValueAtom(
        int area, int block, int group, int row, int col, bool on,
        {int labelWidth = 0, int dlg1 = 0, int dlg2 = 0}) =>
    choiceValueAtom(etypeRadioButton3, area, block, group, row, col, on,
        labelWidth: labelWidth, dlg1: dlg1, dlg2: dlg2);

/// The etype-128 checkbox VALUE atom of ONE checkbox — a tick / untick
/// transports only the changed box, never a group (platinr3S.jar
/// GuiToggleButton.getValueChanges emits one GuiToggleButtonChange;
/// [choiceValueAtom]).
Uint8List checkboxValueAtom(
        int area, int block, int group, int row, int col, bool on,
        {int labelWidth = 0, int dlg1 = 0, int dlg2 = 0}) =>
    choiceValueAtom(etypeCheckButton3, area, block, group, row, col, on,
        labelWidth: labelWidth, dlg1: dlg1, dlg2: dlg2);

/// Build an APPL4 item (`type 0x12 <id u8> <sid u8> <len u32 BE> <value>`).
Uint8List buildAppl4Item(int id, int sid, Uint8List value) {
  final out = Uint8List(7 + value.length);
  final bd = out.buffer.asByteData();
  out[0] = itemAppl4;
  out[1] = id;
  out[2] = sid;
  bd.setUint32(3, value.length);
  out.setRange(7, out.length, value);
  return out;
}

/// The `16/8/1` item of a client RFC reply [value]: APPL up to its u16
/// length, APPL4 past it — a frame that large is always over the kernel's
/// request buffer, so the session never sends the APPL4 item itself: the
/// request stream cuts its value into `16/8/4` chunks + the `16/8/1` tail
/// (client_request_stream.dart; the real GUI's 171 KB upload,
/// a recorded session gui[22..27]). An ABAP editor document
/// past ~64 KB of answer — a long source the LZH cell does not shrink below
/// it — is such a reply; the OCX's own answer of a 150 000-byte source was
/// 5 032 B (a recorded session g[47]), the shape past
/// 64 KB is unrecorded.
Uint8List rfcReplyItem(Uint8List value) => value.length > 0xffff
    ? buildAppl4Item(8, 1, value)
    : buildApplItem(8, 1, value);

/// The `16/6/35` codepage item declaring 4110 / UTF-8 (full item bytes).
final Uint8List okCodepageItem = () {
  final value = Uint8List.fromList(
      [0, 0, 0x10, 0x0e, 0x01, ...'4110'.codeUnits, 0, ...'UTF8'.codeUnits, 0]);
  return buildApplItem(6, 35, value);
}();

/// Base64 decoder convenience for embedded templates.
Uint8List b64(String s) => base64Decode(s);
