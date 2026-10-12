/// Front-end RFC over DIAG — GuiGo as the `DESTINATION 'SAPGUI'` responder
/// (the reference client's port).
///
/// An ABAP `CALL FUNCTION <fname> DESTINATION 'SAPGUI'` reaches the front end
/// INSIDE the DIAG stream as an RFC_TR item (16/8/<sid>) of the session's own
/// window. Request and reply are ONE flat token stream
/// `<tag:2> <len:BE16> <data> <tag:2> … ff ff 00 00 ff ff`; the roles read
/// here: 0x0102 the function name, 0x0205 a declared parameter, 0x0201 /
/// 0x0203 a supplied parameter's name / value, 0x0130 the caller program,
/// 0x0401 the exception a reply raises, 0x0667 the reply's statistics double.
///
/// The TRANSPORT decides whether a reply is owed, not the function:
/// * a SYNCHRONOUS call arrives on sid 0/1 and the kernel waits on its
/// reply — unanswered, the window hangs. The real GUI answers every one:
/// `SAPGUI_PROGRESS_INDICATOR` in a server-opened window (a recorded session
/// _session raw srv[40] mode 2 step 1, sid 0 -> raw gui[28] mode 2 step 1,
/// a bare success; a recorded session srv[32] -> gui[22], the Java GUI),
/// `SAPGUI_SET_PROPERTY` ACTIVATE (a recorded session srv[22] ->
/// gui[17]; a recorded session srv[17] -> gui[9]), `RFC_PING` /
/// `RFC_SYSTEM_INFO` (a recorded session srv[8] / [9] -> gui[10]
/// / [11]) and an unknown function with `RFC_FUNCTION_NOT_FOUND`
/// (a recorded session srv[6] -> gui[14]; the caller's ABAP gets
/// sy-subrc 3 — a clean exception, never a hang);
/// * the NON-BLOCKING progress tick arrives on sid 6 (`SAPGUI_PROGRESS_
/// INDICATOR`'s shim, `RFCControl 'CODE' 'n'`): the kernel reads NO reply —
/// one is `RFCGUI_UNEXPECTED_DATA` and aborts the transaction (reference client
/// complaint-frontend_rfc+20260904-224346). Receive-only.
library;

import 'dart:typed_data';

import '../codepages.dart';
import '../framing/envelope.dart';
import '../session/frames.dart';
import 'reply_container.dart';

const int rfcTagFunction = 0x0102;
const int rfcTagParamDecl = 0x0205;
const int rfcTagParamName = 0x0201;
const int rfcTagParamValue = 0x0203;
const int rfcTagException = 0x0401;
const int rfcTagStats = 0x0667;

/// The exception the real front end raises for a function it does not
/// implement (a recorded session gui[14]).
const String rfcFunctionNotFound = 'RFC_FUNCTION_NOT_FOUND';

const Map<int, String> _contextTags = {
  0x0008: 'server',
  0x0006: 'destination',
  0x0130: 'caller',
  0x0111: 'user',
  0x0114: 'client',
  0x0003: 'sysid',
  0x0002: 'host',
  0x0013: 'kernel',
  0x0012: 'kernel_patch',
  0x0127: 'transport',
};

/// (tag, data) of an RFC_TR container up to its terminator; a malformed
/// tail stops the walk (the tokens before it are returned). Never throws.
List<(int, Uint8List)> rfcTokens(Uint8List b) {
  final out = <(int, Uint8List)>[];
  var i = 0;
  while (i + 4 <= b.length) {
    if (i + 6 <= b.length &&
        b[i] == 0xff &&
        b[i + 1] == 0xff &&
        b[i + 2] == 0 &&
        b[i + 3] == 0 &&
        b[i + 4] == 0xff &&
        b[i + 5] == 0xff) {
      break;
    }
    final n = b[i + 2] << 8 | b[i + 3];
    if (i + 6 + n > b.length ||
        b[i + 4 + n] != b[i] ||
        b[i + 5 + n] != b[i + 1]) {
      break;
    }
    out.add((b[i] << 8 | b[i + 1], Uint8List.sublistView(b, i + 4, i + 4 + n)));
    i += 6 + n;
  }
  return out;
}

String _text(Uint8List data) {
  // the declared 16/6/35 codepage (UTF-8), up to the first NUL, control
  // bytes dropped (reference client _text: wire_decode + strip)
  final s = wireDecodeNull(data);
  return s.replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
}

/// One front-end RFC request (reference client parse_frontend_call).
class FrontendCall {
  FrontendCall(
    this.fname,
    this.declared,
    this.params,
    this.paramsRaw,
    this.context,
  );

  /// The 0x0102 function name, upper-cased; null when the container names
  /// none.
  final String? fname;
  final List<String> declared;
  final Map<String, String> params;
  final Map<String, Uint8List> paramsRaw;
  final Map<String, String> context;

  /// A SAPGUI_PROGRESS_INDICATOR's PERCENTAGE — a 4-byte LITTLE-endian
  /// ABAP I read from the RAW value (the text view loses 0x0a / 0x0d / 0:
  /// reference client _percentage_int); null when absent, 0 when empty.
  int? get percentage {
    final raw = paramsRaw['PERCENTAGE'];
    if (raw == null) return null;
    if (raw.isEmpty) return 0;
    var v = 0;
    for (var k = raw.length < 4 ? raw.length - 1 : 3; k >= 0; k--) {
      v = v << 8 | raw[k];
    }
    return v;
  }

  @override
  String toString() =>
      'FrontendCall($fname from ${context['caller']}, params ${params.keys})';
}

FrontendCall parseFrontendCall(Uint8List container) {
  String? fname;
  final declared = <String>[];
  final params = <String, String>{};
  final raw = <String, Uint8List>{};
  final ctx = <String, String>{};
  String? pending;
  for (final (tag, data) in rfcTokens(container)) {
    if (tag == rfcTagFunction && fname == null) {
      fname = _text(data).toUpperCase();
    } else if (tag == rfcTagParamDecl) {
      declared.add(_text(data));
    } else if (tag == rfcTagParamName) {
      pending = _text(data);
    } else if (tag == rfcTagParamValue && pending != null) {
      params[pending] = _text(data);
      raw[pending] = Uint8List.fromList(data);
      pending = null;
    } else if (_contextTags[tag] case final role?) {
      ctx.putIfAbsent(role, () => _text(data));
    }
  }
  return FrontendCall(fname, declared, params, raw, ctx);
}

bool _contains(Uint8List hay, String needle) {
  final n = needle.codeUnits;
  outer:
  for (var i = 0; i + n.length <= hay.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (hay[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Whether the 16/8/[sid] item [value] is a front-end RFC request — one
/// naming a function the automation / DataProvider families do not own
/// (OLE_FLUSH_CALL, DP_GET_ / DP_PUT_CLIENT_TABLE are answered by their own
/// responders). sid 0/1 (synchronous) or 6 (the async progress tick); the
/// sid-4 content pushes carry no function-name grammar (reference client
/// is_frontend_call).
bool isFrontendCall(Uint8List value, int sid) {
  if (sid != 0 && sid != 1 && sid != 6) return false;
  if (_contains(value, 'OLE_FLUSH_CALL') ||
      _contains(value, 'DP_GET_CLIENT_TABLE') ||
      _contains(value, 'DP_PUT_CLIENT_TABLE')) {
    return false;
  }
  for (final (tag, data) in rfcTokens(value)) {
    if (tag == rfcTagFunction) return _text(data).isNotEmpty;
  }
  return false;
}

/// Whether a front-end RFC on [sid] owes a reply: the synchronous sid 0/1
/// call yes, the sid-6 progress tick never (reference client reply_owed).
bool frontendReplyOwed(int sid) => sid == 0 || sid == 1;

Uint8List _tok(int tag, List<int> data) {
  final out = Uint8List(6 + data.length);
  out[0] = tag >> 8;
  out[1] = tag & 0xff;
  out[2] = data.length >> 8 & 0xff;
  out[3] = data.length & 0xff;
  out.setRange(4, 4 + data.length, data);
  out[4 + data.length] = tag >> 8;
  out[5 + data.length] = tag & 0xff;
  return out;
}

/// The front end's exception reply `<client prefix> 0401 <exception> END`
/// (a recorded session gui[14], byte-exact for that GUI's prefix).
Uint8List buildFrontendExceptionReply({
  String exception = rfcFunctionNotFound,
  Uint8List? prefix,
}) {
  return Uint8List.fromList([
    ...(prefix ?? constPrefix),
    ..._tok(rfcTagException, exception.codeUnits),
    ...rfcTerm,
  ]);
}

/// The front end's SUCCESS reply (a recorded session gui[10] /
/// [11]): `<client prefix>`, one `0201 <name>` / `0203 <value>` pair per
/// returned EXPORTING parameter, the `0667` statistics trailer (an IEEE-754
/// little-endian double the GUI fills per reply — 14.0 on a recorded session
/// session gui[28], 2.0 / 3.0 on rfc_success; a timing figure the kernel
/// does not validate, at least 1.0), the terminator. No 0401: sy-subrc 0.
Uint8List buildFrontendSuccessReply({
  Map<String, Uint8List> exports = const {},
  double elapsedMs = 1.0,
  Uint8List? prefix,
}) {
  final stats = ByteData(8)
    ..setFloat64(0, elapsedMs < 1.0 ? 1.0 : elapsedMs, Endian.little);
  return Uint8List.fromList([
    ...(prefix ?? constPrefix),
    for (final e in exports.entries) ...[
      ..._tok(rfcTagParamName, e.key.codeUnits),
      ..._tok(rfcTagParamValue, e.value),
    ],
    ..._tok(rfcTagStats, stats.buffer.asUint8List()),
    ...rfcTerm,
  ]);
}

/// RFCSI — the fixed-width structure RFC_SYSTEM_INFO exports (RFCSI_EXPORT,
/// 245 bytes), as the real SAP GUI for WINDOWS fills it for itself
/// (a recorded session srv[9] -> gui[11]): its constants
/// (protocol 011, char type 4110, LIT / IE3, RFCSYSID SAPGUI, RFCMACH
/// ` 562`, RFCOPSYS `Windows 2K`) and the front end's identity — RFCDEST
/// and RFCHOST2 the host name, RFCHOST its first 8 characters, the client
/// address, the GUI build as release / kernel. the reference client fills the Java
/// GUI's (a recorded session gui[16]: RFCDEST blank, RFCMACH
/// ` 1025`, RFCOPSYS the host OS).
const List<(String, int)> rfcsiFields = [
  ('RFCPROTO', 3),
  ('RFCCHARTYP', 4),
  ('RFCINTTYP', 3),
  ('RFCFLOTYP', 3),
  ('RFCDEST', 32),
  ('RFCHOST', 8),
  ('RFCSYSID', 8),
  ('RFCDATABS', 8),
  ('RFCDBHOST', 32),
  ('RFCDBSYS', 10),
  ('RFCSAPRL', 4),
  ('RFCMACH', 5),
  ('RFCOPSYS', 10),
  ('RFCTZONE', 6),
  ('RFCDAYST', 1),
  ('RFCIPADDR', 15),
  ('RFCKERNRL', 4),
  ('RFCHOST2', 32),
  ('RFCSI_RESV', 12),
  ('RFCIPV6ADDR', 45),
];

Uint8List rfcsiExport({
  String host = '',
  String clientAddr = constClientAddr,
  String guiBuild = constGuiBuild,
}) {
  final v = <String, String>{
    'RFCPROTO': '011',
    'RFCCHARTYP': '4110',
    'RFCINTTYP': 'LIT',
    'RFCFLOTYP': 'IE3',
    'RFCDEST': host,
    'RFCHOST': host.length > 8 ? host.substring(0, 8) : host,
    'RFCSYSID': 'SAPGUI',
    'RFCSAPRL': guiBuild,
    'RFCMACH': '  562',
    'RFCOPSYS': 'Windows 2K',
    'RFCIPADDR': clientAddr,
    'RFCKERNRL': guiBuild,
    'RFCHOST2': host,
    'RFCIPV6ADDR': clientAddr,
  };
  final out = BytesBuilder(copy: false);
  for (final (name, width) in rfcsiFields) {
    final s = v[name] ?? '';
    final cut = s.length > width ? s.substring(0, width) : s.padRight(width);
    out.add([for (final c in cut.codeUnits) c > 0xff ? 0x3f : c]);
  }
  return out.takeBytes();
}

/// The reply GuiGo owes the synchronous front-end RFC [call]: a bare
/// success for the functions a SAP GUI implements that import nothing
/// (SAPGUI_PROGRESS_INDICATOR, SAPGUI_SET_PROPERTY, RFC_PING), the RFCSI
/// structure for RFC_SYSTEM_INFO, RFC_FUNCTION_NOT_FOUND for every other —
/// RFC_REMOTE_EXEC included: GuiGo starts no front-end program (the real
/// Windows GUI that started `gnetx.exe` answers a success,
/// a recorded session srv[21] -> gui[16]; the reference client's
/// rfc_remote_exec without an enabled helper answers not-found too).
///
/// [prefix] = the reply's connection descriptor (the client constant by
/// default; a Windows session's carries the host-name token,
/// [withHostToken]); [clientAddr] fills the RFCSI address slots.
Uint8List frontendRfcReply(
  FrontendCall call, {
  double elapsedMs = 1.0,
  String host = '',
  String clientAddr = constClientAddr,
  Uint8List? prefix,
}) {
  switch (call.fname) {
    case 'SAPGUI_PROGRESS_INDICATOR':
    case 'SAPGUI_SET_PROPERTY':
    case 'RFC_PING':
      return buildFrontendSuccessReply(elapsedMs: elapsedMs, prefix: prefix);
    case 'RFC_SYSTEM_INFO':
      return buildFrontendSuccessReply(
        exports: {
          'RFCSI_EXPORT': rfcsiExport(host: host, clientAddr: clientAddr),
        },
        elapsedMs: elapsedMs,
        prefix: prefix,
      );
    default:
      return buildFrontendExceptionReply(prefix: prefix);
  }
}

/// The descriptor's second client-address token and the SAP GUI for
/// Windows' host-name token right after it.
const int rfcTagAddr2 = 0x0018, rfcTagHost = 0x0008;

/// [prefix] (a reply connection descriptor — [constPrefix], or a whole
/// reply that starts with one) with the SAP GUI for WINDOWS' host-name
/// token `0008 <len> <host> 0008` inserted right after the 0018 address
/// token: every Windows reply carries it — a recorded session
/// gui[10] / gui[11], a recorded session gui[27] (scrubbed), `0008 000d
/// "the recording host"` (reference client diag_reply_container.with_host_token, 847ec3a);
/// the Java GUI's has none (a recorded session gui[22]). Unchanged when
/// [host] is empty, the token is already there, or the descriptor does
/// not parse.
Uint8List withHostToken(Uint8List prefix, String host) {
  if (host.isEmpty) return prefix;
  var i = 0;
  while (i + 4 <= prefix.length) {
    final tag = prefix[i] << 8 | prefix[i + 1];
    final n = prefix[i + 2] << 8 | prefix[i + 3];
    final end = i + 6 + n;
    if (end > prefix.length ||
        prefix[end - 2] != prefix[i] ||
        prefix[end - 1] != prefix[i + 1]) {
      return prefix;
    }
    if (tag == rfcTagHost) return prefix;
    if (tag == rfcTagAddr2) {
      if (end + 2 <= prefix.length &&
          (prefix[end] << 8 | prefix[end + 1]) == rfcTagHost) {
        return prefix;
      }
      return Uint8List.fromList([
        ...prefix.sublist(0, end),
        ..._tok(rfcTagHost, [for (final c in host.codeUnits) c & 0xff]),
        ...prefix.sublist(end),
      ]);
    }
    i = end;
  }
  return prefix;
}

/// The client frame items of a front-end RFC [reply] at [step]: Step, the
/// 16/8/1 reply, EOM — and on the WINDOWS dialect a SECOND EOM, as every
/// Windows reply frame of the corpus ends (a recorded session
/// gui[10] / gui[11], a recorded session gui[27]; reference client
/// diag_frontend_rfc.reply_items, 847ec3a); the Java GUI's one
/// (a recorded session gui[22]).
List<Uint8List> frontendRfcReplyItems(int step, Uint8List reply,
        {bool windows = false}) =>
    [
      stepItem(step),
      buildApplItem(8, 1, reply),
      eomBytes,
      if (windows) eomBytes,
    ];
