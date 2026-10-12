/// SNC frame codec (pysap SAPSNCFrame port): the PDU that wraps DIAG
/// traffic on an SNC-protected connection.
///
/// Layout: `"SNCFRAME"` eye-catcher (8), frame_type u8, protocol_version
/// u8 (=5), header_length u16 (=24), token_length u32, data_length u32,
/// mech_id u16, flags u16 [, ext_flags u32, ext_field_length u16,
/// ext_fields], token, data.
library;

import 'dart:typed_data';

// frame types
const int sncReverseReq = 0x00;
const int sncInitReq = 0x01;
const int sncInit = 0x02;
const int sncInitAck = 0x03;
const int sncAccept = 0x04;
const int sncAcceptAck = 0x05;
const int sncAcceptFailed = 0x06;
const int sncDataOpen = 0x07;
const int sncDataMic = 0x08; // DATA_SIGNED
const int sncDataWrap = 0x09; // DATA_SEALED
const int sncShutdown = 0x0a;
const int sncShutdownMsg = 0x0b;
const int sncRejected = 0x0c;
const int sncError = 0x0d;

// mech ids
const int mechKerberos5 = 0x02; // Kerberos 5 / GSS-API v2
const int mechSecude = 0x03;

// quality of protection
const int qopOpen = 0x01;
const int qopIntegrity = 0x02;
const int qopPrivacy = 0x03;

const String sncEyeCatcher = 'SNCFRAME';
const int sncBaseHeaderLen = 24;
const int sncProtocolVersion = 5;

class SncFrame {
  SncFrame({
    required this.frameType,
    this.protocolVersion = sncProtocolVersion,
    this.headerLength = sncBaseHeaderLen,
    required this.mechId,
    this.flags = 0,
    this.extFlags,
    this.extFields = const [],
    required this.token,
    required this.data,
  });

  final int frameType;
  final int protocolVersion;
  final int headerLength;
  final int mechId;
  final int flags;
  final int? extFlags;
  final List<int> extFields;
  final Uint8List token;
  final Uint8List data;

  static SncFrame? parse(Uint8List b) {
    if (b.length < sncBaseHeaderLen) return null;
    for (var i = 0; i < 8; i++) {
      if (b[i] != sncEyeCatcher.codeUnitAt(i)) return null;
    }
    final bd = b.buffer.asByteData(b.offsetInBytes, b.lengthInBytes);
    final frameType = b[8];
    final version = b[9];
    final hlen = bd.getUint16(10);
    final tokenLen = bd.getUint32(12);
    final dataLen = bd.getUint32(16);
    final mech = bd.getUint16(20);
    final flags = bd.getUint16(22);
    int? extFlags;
    var extFields = const <int>[];
    var off = hlen;
    if (hlen > sncBaseHeaderLen && b.length >= hlen + 6) {
      extFlags = bd.getUint32(24);
      final extLen = bd.getUint16(28);
      extFields = b.sublist(30, 30 + extLen > b.length ? b.length : 30 + extLen);
      off = 30 + extLen;
    }
    if (off + tokenLen + dataLen > b.length) return null;
    return SncFrame(
      frameType: frameType,
      protocolVersion: version,
      headerLength: hlen,
      mechId: mech,
      flags: flags,
      extFlags: extFlags,
      extFields: extFields,
      token: Uint8List.sublistView(b, off, off + tokenLen),
      data: Uint8List.sublistView(b, off + tokenLen, off + tokenLen + dataLen),
    );
  }

  Uint8List serialize() {
    final ext = headerLength > sncBaseHeaderLen;
    final out = Uint8List(headerLength + token.length + data.length + extFields.length);
    final bd = out.buffer.asByteData();
    for (var i = 0; i < 8; i++) {
      out[i] = sncEyeCatcher.codeUnitAt(i);
    }
    out[8] = frameType;
    out[9] = protocolVersion;
    bd.setUint16(10, headerLength);
    bd.setUint32(12, token.length);
    bd.setUint32(16, data.length);
    bd.setUint16(20, mechId);
    bd.setUint16(22, flags);
    var off = sncBaseHeaderLen;
    if (ext) {
      bd.setUint32(24, extFlags ?? 0);
      bd.setUint16(28, extFields.length);
      out.setRange(30, 30 + extFields.length, extFields);
      off = 30 + extFields.length;
    }
    out.setRange(off, off + token.length, token);
    out.setRange(off + token.length, out.length, data);
    return out;
  }
}
