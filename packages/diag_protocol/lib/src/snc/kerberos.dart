/// A minimal Kerberos client for SNC: AS exchange (password preauth) and
/// TGS exchange for the SAP service principal, yielding the service
/// session key + ticket for the RFC 4121 AP-REQ.
///
/// RC4-HMAC (etype 23) is the wire default — the common AD configuration;
/// AES-128/256 keys derive identically once negotiated.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'der.dart';
import 'gss_krb5.dart';

class KrbCreds {
  KrbCreds(this.sessionKey, this.ticket, this.etype, this.clientPrincipal);
  final Uint8List sessionKey;
  final Uint8List ticket; // the DER APPLICATION ticket (opaque)
  final int etype;
  final String clientPrincipal;
}

class KrbException implements Exception {
  KrbException(this.message);
  final String message;
  @override
  String toString() => 'KrbException: $message';
}

class KrbClient {
  KrbClient({
    required this.realm,
    required this.kdcHost,
    this.kdcPort = 88,
    required this.userName,
    required this.password,
  });

  final String realm;
  final String kdcHost;
  final int kdcPort;
  final String userName;
  final String password;

  /// One TCP round trip (4-byte BE length prefix, like NI).
  Future<Uint8List> _tcpExchange(Uint8List req) async {
    final s = await Socket.connect(kdcHost, kdcPort,
        timeout: const Duration(seconds: 10));
    try {
      final out = Uint8List(4 + req.length);
      ByteData.view(out.buffer).setUint32(0, req.length);
      out.setRange(4, out.length, req);
      s.add(out);
      final data = <int>[];
      final completer = Completer<Uint8List>();
      late final StreamSubscription sub;
      sub = s.listen((chunk) {
        data.addAll(chunk);
        if (data.length >= 4) {
          final head = Uint8List.fromList(data.take(4).toList());
          final len = ByteData.view(head.buffer).getUint32(0);
          if (data.length >= 4 + len) {
            sub.cancel();
            if (!completer.isCompleted) {
              completer.complete(
                  Uint8List.fromList(data.sublist(4, 4 + len)));
            }
          }
        }
      }, onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      });
      return await completer.future
          .timeout(const Duration(seconds: 10));
    } finally {
      s.destroy();
    }
  }

  // ---------------------------------------------------------------- AS

  Future<KrbCreds> asExchange() async {
    final key = rc4StringToKey(password);
    final req = _asReq(pa: [_paEncTimestamp(key)]);
    final resp = await _tcpExchange(req);
    final msg = _expectRep(resp, 11); // AS-REP
    var encPart = <int>[];
    Uint8List? ticket;
    var cname = userName;
    for (final (t, c) in DerReader(msg).children()) {
      if (t == 0xa0 + 6) encPart = c; // [6] enc-part
      if (t == 0xa0 + 2) ticket = _ticketOf(c); // [2] ticket
      if (t == 0xa0 + 8) cname = _cnameOf(c); // [8] cname
    }
    final plain = _decryptEncPart(Uint8List.fromList(encPart), key);
    final sessionKey = _sessionKeyOf(plain);
    if (ticket == null || sessionKey.isEmpty) {
      throw KrbException('AS-REP missing ticket/session key');
    }
    return KrbCreds(sessionKey, ticket, 23, cname);
  }

  // ---------------------------------------------------------------- TGS

  /// Service principal from an SNC name: `p:CN@REALM` → `CN@REALM` (the
  /// AD UPN/SPN the KDC knows the service by).
  Future<KrbCreds> tgsExchange(KrbCreds tgt, String servicePrincipal) async {
    final (spn, srealm) = _splitPrincipal(servicePrincipal);
    final subkey = rc4StringToKey('${DateTime.now().microsecondsSinceEpoch}');
    final authenticator = _authenticator(tgt, subkey);
    final apReq = _apReq(tgt, authenticator);
    final req = _tgsReq(apReq, spn, srealm);
    final resp = await _tcpExchange(req);
    final msg = _expectRep(resp, 13); // TGS-REP
    var encPart = <int>[];
    Uint8List? ticket;
    for (final (t, c) in DerReader(msg).children()) {
      if (t == 0xa0 + 6) encPart = c;
      if (t == 0xa0 + 2) ticket = _ticketOf(c);
    }
    final plain = _decryptEncPart(Uint8List.fromList(encPart), tgt.sessionKey);
    final sessionKey = _sessionKeyOf(plain);
    if (ticket == null || sessionKey.isEmpty) {
      throw KrbException('TGS-REP missing ticket/session key');
    }
    return KrbCreds(sessionKey, ticket, 23, tgt.clientPrincipal);
  }

  (String, String) _splitPrincipal(String p) {
    final at = p.lastIndexOf('@');
    if (at < 0) return (p, realm);
    return (p.substring(0, at), p.substring(at + 1));
  }

  // ---------------------------------------------------------------- DER builders

  Uint8List _paEncTimestamp(Uint8List key) {
    final now = DateTime.now().toUtc();
    String p2(int v) => v.toString().padLeft(2, '0');
    final ts = '${now.year}${p2(now.month)}${p2(now.day)}'
        '${p2(now.hour)}${p2(now.minute)}${p2(now.second)}Z';
    final cipher = Rc4(key).process(Uint8List.fromList(ts.codeUnits));
    final w = DerWriter()
      ..seq((e) {
        e.integer(2); // PA-ENC-TIMESTAMP
        e.seq((v) {
          v.integer(23);
          v.octetString(cipher);
        });
      });
    return w.bytes();
  }

  Uint8List _asReq({required List<Uint8List> pa}) =>
      _kdcReq(msgType: 10, pa: pa, sname: 'krbtgt/$realm');

  Uint8List _tgsReq(Uint8List apReq, String spn, String srealm) =>
      _kdcReq(msgType: 12, pa: [apReq], sname: spn, srealm: srealm);

  Uint8List _kdcReq(
      {required int msgType,
      required List<Uint8List> pa,
      required String sname,
      String? srealm}) {
    final w = DerWriter()
      ..ctxSeq(1, (a) {
        a.integer(5); // pvno
        a.integer(msgType);
        a.ctxSeq(4, (pw) {
          for (final p in pa) {
            pw.raw(0x30, p);
          }
        });
        a.ctxSeq(3, (b) {
          b.ctxSeq(0, (c) {
            c.seq((n) => n.generalString(userName));
          });
          b.integer(0x40810000); // kdc-options: renewable, forwardable off
          b.ctxSeq(1, (c) {
            c.seq((n) => n.generalString(srealm ?? realm));
          });
          b.ctxSeq(2, (c) {
            final parts = sname.split('/');
            for (final p in parts) {
              c.seq((n) => n.generalString(p));
            }
          });
          b.ctxSeq(7, (c) {
            c.seq((n) => n.integer(23)); // etype RC4-HMAC
          });
        });
      });
    return w.bytes();
  }

  Uint8List _authenticator(KrbCreds creds, Uint8List subkey) {
    final now = DateTime.now().toUtc();
    final w = DerWriter()
      ..seq((a) {
        a.integer(5); // avno
        a.ctxSeq(1, (r) {
          r.seq((n) => n.generalString(creds.clientPrincipal.split('@').first));
          r.seq((n) => n.generalString(realm));
        });
        a.ctxSeq(2, (t) {
          t.generalString(_krbTime(now));
        });
        a.ctxSeq(6, (t) {
          t.generalString(_krbTime(now));
        });
        a.ctxSeq(7, (t) {
          t.integer(0);
        });
        a.ctxSeq(8, (t) {
          t.seq((k) {
            k.integer(23);
            k.octetString(subkey);
          });
        });
        a.ctxSeq(9, (t) {
          final seqBytes = Uint8List(4);
          ByteData.view(seqBytes.buffer)
              .setUint32(0, DateTime.now().microsecondsSinceEpoch & 0x7fffffff);
          t.integerBytes(seqBytes);
        });
      });
    return w.bytes();
  }

  Uint8List _apReq(KrbCreds creds, Uint8List authenticator) {
    final cipher = Rc4(creds.sessionKey).process(authenticator);
    final w = DerWriter()
      ..seq((a) {
        a.integer(5); // pvno
        a.integer(14); // AP-REQ
        a.integer(1); // ap-options: mutual NOT required
        a.raw(0x61, creds.ticket); // ticket
        a.seq((e) {
          e.integer(23);
          e.octetString(cipher);
        });
      });
    final body = w.bytes();
    return Uint8List.fromList([0x6e, ...derLength(body.length), ...body]);
  }

  /// The RFC 4121 init-token body the SNC INIT_REQ carries: the raw AP-REQ
  /// application tag.
  Uint8List apReqToken(KrbCreds serviceCreds, int usage) {
    final subkey = serviceCreds.sessionKey;
    final authenticator = _authenticator(serviceCreds, subkey);
    return _apReq(serviceCreds, authenticator);
  }

  // ---------------------------------------------------------------- parsers

  Uint8List _expectRep(Uint8List resp, int wantType) {
    // APPLICATION tag 11 (AS-REP) / 13 (TGS-REP) / 30 (KRB-ERROR)
    final r = DerReader(resp);
    final (tag, body) = r.next();
    if (tag == 0x7e) {
      // KRB-ERROR
      var code = 0;
      var text = '';
      for (final (t, c) in DerReader(body).children()) {
        if (t == 0xa0 + 5) {
          for (final (t2, c2) in DerReader(c).children()) {
            if (t2 == 0x30) {
              var k = 0;
              var v = '';
              for (final (t3, c3) in DerReader(c2).children()) {
                if (t3 == 0x02) k = DerReader(c3).nextInt();
                if (t3 == 0x1b) v = String.fromCharCodes(c3);
              }
              code = k;
              text = v;
            }
          }
        }
      }
      throw KrbException('KDC error $code: $text');
    }
    if (tag != 0x6b && tag != 0x6d) {
      throw KrbException('unexpected reply tag 0x${tag.toRadixString(16)}');
    }
    return body;
  }

  Uint8List? _ticketOf(Uint8List c) {
    // the ticket is an APPLICATION [1] (0x61) inside [2]
    final r = DerReader(c);
    while (!r.atEnd) {
      final (t, body) = r.next();
      if (t == 0x61) return Uint8List.fromList([0x61, ...derLength(body.length), ...body]);
    }
    return null;
  }

  String _cnameOf(Uint8List c) {
    for (final (t, body) in DerReader(c).children()) {
      if (t == 0x30) {
        for (final (t2, g) in DerReader(body).children()) {
          if (t2 == 0x1b) return String.fromCharCodes(g);
        }
      }
    }
    return userName;
  }

  Uint8List _decryptEncPart(Uint8List encPart, Uint8List key) {
    // EncryptedData { etype, kvno?, cipher } — RC4: plain = RC4(key, cipher)
    var etype = 23;
    var cipher = Uint8List(0);
    for (final (t, c) in DerReader(encPart).children()) {
      if (t == 0x02) etype = DerReader(c).nextInt();
      if (t == 0x04) cipher = c;
    }
    if (etype != 23) {
      throw KrbException('etype $etype not supported by this client');
    }
    return Rc4(key).process(cipher);
  }

  Uint8List _sessionKeyOf(Uint8List plain) {
    // EncASRepPart [0] key { keytype, keyvalue }
    for (final (t, c) in DerReader(plain).children()) {
      if (t == 0xa0) {
        for (final (t2, c2) in DerReader(c).children()) {
          if (t2 == 0x30) {
            for (final (t3, c3) in DerReader(c2).children()) {
              if (t3 == 0x04) return c3;
            }
          }
        }
      }
    }
    return Uint8List(0);
  }

  String _krbTime(DateTime t) {
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${p2(t.month)}${p2(t.day)}'
        '${p2(t.hour)}${p2(t.minute)}${p2(t.second)}Z';
  }
}
