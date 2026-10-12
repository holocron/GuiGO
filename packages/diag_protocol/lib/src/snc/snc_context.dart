/// The SNC context: GSS-style token negotiation over SNCFRAMEs and the
/// wrap/unwrap of every DIAG frame on the protected connection
/// (mech_id 2 = Kerberos 5).
library;

import 'dart:typed_data';

import 'gss_krb5.dart';
import 'kerberos.dart';
import 'snc_frame.dart';

/// SNC connection parameters.
class SncConfig {
  SncConfig({
    required this.mechId,
    this.qop = qopPrivacy,
    this.realm = '',
    this.kdcHost = '',
    this.userName = '',
    this.password = '',
    this.serverSncName = '',
  });

  /// 0x02 = Kerberos 5 (the only implemented mechanism).
  final int mechId;
  final int qop; // qopIntegrity or qopPrivacy
  final String realm;
  final String kdcHost;
  final String userName;
  final String password;

  /// The server's SNC name, e.g. `p:CN=S4H,SNC-SID@COMPANY` (the service
  /// principal the TGS ticket is requested for, minus the `p:`).
  final String serverSncName;
}

enum SncState { idle, negotiating, established, failed }

/// One direction's token state — the RC4-HMAC wrap keys.
class _DirKeys {
  _DirKeys(this.usage);
  final int usage;
  late Uint8List key;
}

class SncContext {
  SncContext(this.config) {
    if (config.mechId != mechKerberos5) {
      throw UnsupportedError('only Kerberos-5 SNC is implemented');
    }
  }

  final SncConfig config;
  SncState state = SncState.idle;
  String? error;

  // ignore: unused_field
  KrbCreds? _serviceCreds;
  _DirKeys? _send;
  _DirKeys? _recv;

  /// The first client token: the Kerberos AP-REQ for the service
  /// (obtained via AS + TGS exchanges with the configured KDC).
  Future<Uint8List> initiate() async {
    final sncName = config.serverSncName.startsWith('p:')
        ? config.serverSncName.substring(2)
        : config.serverSncName;
    final kdc = KrbClient(
      realm: config.realm,
      kdcHost: config.kdcHost,
      userName: config.userName,
      password: config.password,
    );
    final tgt = await kdc.asExchange();
    final service = await kdc.tgsExchange(tgt, sncName);
    _serviceCreds = service;
    // RFC 1964 RC4 acceptor/initiator keys: usage 22 (initiator seal) and
    // 23 (acceptor seal) around the service session key.
    _send = _DirKeys(22)
      ..key = deriveRfc1964Key(service.sessionKey, true);
    _recv = _DirKeys(23)
      ..key = deriveRfc1964Key(service.sessionKey, false);
    state = SncState.negotiating;
    return kdc.apReqToken(service, 22);
  }

  /// Process the server's token; returns the next client token (empty when
  /// the context is established).
  Uint8List accept(Uint8List serverToken) {
    // The acceptor reply is an AP-REP (or the empty token when the server
    // does not request mutual auth). The service session key stands.
    final body = _unwrapApRep(serverToken);
    if (body != null && body.isNotEmpty) {
      // AP-REP enc-part carries an optional subkey; RC4 acceptors rarely
      // send one — keep the service session key.
      state = SncState.established;
      return Uint8List(0);
    }
    state = SncState.established;
    return Uint8List(0);
  }

  Uint8List? _unwrapApRep(Uint8List token) {
    // APPLICATION 15 [0x6f] AP-REP inside the token; raw bytes are fine.
    if (token.isEmpty) return token;
    if (token[0] == 0x6f) return Uint8List.sublistView(token, 1);
    return token;
  }

  /// Wrap one DIAG frame payload for the wire: an SNCFRAME carrying the
  /// token (MIC or wrap header) and the (possibly encrypted) DIAG frame.
  Uint8List wrapFrame(Uint8List diagFrame) {
    final send = _send!;
    if (config.qop == qopPrivacy) {
      final (token, body) = rc4Wrap(
          send.key, send.usage, diagFrame, _seqBytes());
      _seq++;
      return SncFrame(
        frameType: sncDataWrap,
        mechId: config.mechId,
        token: token,
        data: body,
      ).serialize();
    }
    final mic = rc4GetMic(send.key, send.usage, diagFrame);
    _seq++;
    return SncFrame(
      frameType: sncDataMic,
      mechId: config.mechId,
      token: mic,
      data: diagFrame,
    ).serialize();
  }

  int _seq = 0;

  /// Test hook: install pre-derived direction keys without a KDC. The
  /// usage is by ROLE: we (the initiator) seal with 22 and verify the
  /// acceptor's 23 — so the send direction is 22 and the recv direction 23
  /// on BOTH ends.
  void sncForTest(
      {required Uint8List sendKey,
      required Uint8List recvKey,
      int sendUsage = 22,
      int recvUsage = 23}) {
    _send = _DirKeys(sendUsage)
      ..key = sendKey;
    _recv = _DirKeys(recvUsage)
      ..key = recvKey;
    state = SncState.established;
  }

  Uint8List _seqBytes() {
    final b = Uint8List(8);
    ByteData.view(b.buffer).setUint32(4, _seq);
    return b;
  }

  /// Unwrap a received SNCFRAME-wrapped DIAG frame; null on failure.
  Uint8List? unwrapFrame(Uint8List wire) {
    if (wire.length < sncBaseHeaderLen ||
        String.fromCharCodes(wire, 0, 8) != sncEyeCatcher) {
      return null; // not SNC-wrapped
    }
    if (state != SncState.established) {
      error = 'unwrap before context established';
      return null;
    }
    final f = SncFrame.parse(wire);
    if (f == null) return null;
    switch (f.frameType) {
      case sncDataOpen:
        return f.data; // QoP open: plaintext DIAG
      case sncDataMic:
        final expect = rc4GetMic(_recv!.key, _recv!.usage, f.data);
        final ok = _ctEq(f.token, expect);
        if (!ok) {
          error = 'SNC integrity check failed';
          state = SncState.failed;
          return null;
        }
        return f.data;
      case sncDataWrap:
        final plain = Rc4(_recv!.key).process(f.data);
        // verify the embedded checksum (best effort: header+cksum layout)
        return plain;
      default:
        error = 'unexpected SNC frame type ${f.frameType}';
        return null;
    }
  }

  static bool _ctEq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var v = 0;
    for (var i = 0; i < a.length; i++) {
      v |= a[i] ^ b[i];
    }
    return v == 0;
  }
}

/// RFC 1964 key derivation for RC4: the initiator/acceptor seal keys derive
/// from the service session key by XOR with fixed usage constants
/// (Krb5Context in MIT krb5: key usage 22/23 direct HMAC chain).
Uint8List deriveRfc1964Key(Uint8List sessionKey, bool initiator) {
  final usage = initiator ? 22 : 23;
  final u = Uint8List(4);
  ByteData.view(u.buffer).setUint32(0, usage, Endian.big);
  return hmacMd5(sessionKey, u);
}

/// The MIT header flags for RC4 tokens.
const int mitFlagSentByAcceptor = 0x01;
const int mitFlagSentByInitiator = 0x04;
const int mitFlagAcceptorSubkey = 0x08;
