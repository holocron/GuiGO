/// Kerberos crypto for SNC: string-to-key (RC4-HMAC, AES-128/256),
/// RFC 3961 key derivation (n-fold + DK), AES-CBC-CTS (CS3), and the
/// RFC 1964 (RC4) / RFC 4121 (AES) GSS tokens — MIC and Wrap.
library;

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'der.dart';

// ---------------------------------------------------------------------------
// primitives
// ---------------------------------------------------------------------------

Uint8List md4(Uint8List data) {
  // RFC 1320: each op updates v[i%4] with F over the other three vars.
  final v = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476];
  final len = data.length;
  final buf = Uint8List(((len + 71) ~/ 64) * 64);
  buf.setRange(0, len, data);
  buf[len] = 0x80;
  final bd = ByteData.view(buf.buffer);
  bd.setUint32(buf.length - 8, len * 8, Endian.little);
  int rotl(int x, int n) => ((x << n) | (x >>> (32 - n))) & 0xffffffff;

  const r2Order = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15];
  const r3Order = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15];
  const s1 = [3, 7, 11, 19];
  const s2 = [3, 5, 9, 13];
  const s3 = [3, 9, 11, 15];

  for (var blk = 0; blk < buf.length; blk += 64) {
    final x = [for (var i = 0; i < 16; i++) bd.getUint32(blk + i * 4, Endian.little)];
    final init = List<int>.of(v);
    for (var i = 0; i < 16; i++) {
      final j = [0, 3, 2, 1][i % 4];
      final f = (v[(j + 1) % 4] & v[(j + 2) % 4]) | (~v[(j + 1) % 4] & v[(j + 3) % 4]);
      v[j] = rotl((v[j] + f + x[i]) & 0xffffffff, s1[i % 4]);
    }
    for (var i = 0; i < 16; i++) {
      final j = [0, 3, 2, 1][i % 4];
      final f = (v[(j + 1) % 4] & v[(j + 2) % 4]) |
          (v[(j + 1) % 4] & v[(j + 3) % 4]) |
          (v[(j + 2) % 4] & v[(j + 3) % 4]);
      v[j] = rotl((v[j] + f + x[r2Order[i]] + 0x5a827999) & 0xffffffff, s2[i % 4]);
    }
    for (var i = 0; i < 16; i++) {
      final j = [0, 3, 2, 1][i % 4];
      final f = v[(j + 1) % 4] ^ v[(j + 2) % 4] ^ v[(j + 3) % 4];
      v[j] = rotl((v[j] + f + x[r3Order[i]] + 0x6ed9eba1) & 0xffffffff, s3[i % 4]);
    }
    for (var i = 0; i < 4; i++) {
      v[i] = (v[i] + init[i]) & 0xffffffff;
    }
  }
  final out = Uint8List(16);
  final ob = ByteData.view(out.buffer);
  for (var i = 0; i < 4; i++) {
    ob.setUint32(i * 4, v[i], Endian.little);
  }
  return out;
}

Uint8List utf16le(String s) {
  final out = Uint8List(s.length * 2);
  final bd = ByteData.view(out.buffer);
  for (var i = 0; i < s.length; i++) {
    bd.setUint16(i * 2, s.codeUnitAt(i), Endian.little);
  }
  return out;
}

class Rc4 {
  Rc4(Uint8List key) {
    for (var i = 0; i < 256; i++) {
      s[i] = i;
    }
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + s[i] + key[i % key.length]) & 0xff;
      final t = s[i];
      s[i] = s[j];
      s[j] = t;
    }
  }

  final s = List<int>.filled(256, 0);
  int i = 0;
  int j = 0;

  Uint8List process(Uint8List data) {
    final out = Uint8List(data.length);
    for (var k = 0; k < data.length; k++) {
      i = (i + 1) & 0xff;
      j = (j + s[i]) & 0xff;
      final t = s[i];
      s[i] = s[j];
      s[j] = t;
      out[k] = data[k] ^ s[(s[i] + s[j]) & 0xff];
    }
    return out;
  }
}

Uint8List hmacMd5(Uint8List key, Uint8List data) =>
    (HMac(MD5Digest(), 64)..init(KeyParameter(key))).process(data);

Uint8List hmacSha1(Uint8List key, Uint8List data) =>
    (HMac(SHA1Digest(), 64)..init(KeyParameter(key))).process(data);

// (SHA-1 via pointycastle's digest, used through hmacSha1)

Uint8List concat(List<List<int>> parts) {
  var n = 0;
  for (final p in parts) {
    n += p.length;
  }
  final out = Uint8List(n);
  var off = 0;
  for (final p in parts) {
    out.setRange(off, off + p.length, p);
    off += p.length;
  }
  return out;
}

// ---------------------------------------------------------------------------
// string-to-key
// ---------------------------------------------------------------------------

/// RC4-HMAC (etype 23) string-to-key: MD4(UTF-16LE(password)).
Uint8List rc4StringToKey(String password) => md4(utf16le(password));

/// AES string-to-key (RFC 3962): random-to-key(PBKDF2(UTF-16LE(pass+salt))).
Uint8List aesStringToKey(String password, String salt, int keyLen) {
  final dk = PBKDF2KeyDerivator(HMac(SHA1Digest(), 64))
    ..init(Pbkdf2Parameters(utf16le(salt), 4096, keyLen));
  return dk.process(utf16le(password));
}

// ---------------------------------------------------------------------------
// RFC 3961 n-fold + DK (AES key derivation)
// ---------------------------------------------------------------------------

/// n-fold (RFC 3961 §5.1): length-preserving multiple-of-n repetition of
/// the input with a one-bit-shifted add.
Uint8List nFold(Uint8List inb, int outLen) {
  final inLen = inb.length * 8;
  final outBits = outLen * 8;
  final gcd = _gcd(inLen, outBits);
  final lcm = inLen * outBits ~/ gcd;
  final out = List<int>.filled(outLen, 0);
  var sum = 0;
  for (var i = lcm - 1; i >= 0; i--) {
    final msbit = ((inLen - 1) + (((inLen << 4) % lcm) == 0 ? i : i * 13)) % lcm; // see note
    sum = ((sum << 1) + ((inb[(inLen - 1 - (msbit % inLen)) ~/ 8] >> (msbit % 8)) & 1)) & 0xff;
    final o = outBits - 1 - (i % outBits);
    out[o ~/ 8] = (out[o ~/ 8] << 1 | (sum & 1)) & 0xff;
  }
  // carry propagation
  var carry = 0;
  for (var i = outLen - 1; i >= 0; i--) {
    final v = out[i] + carry;
    out[i] = v & 0xff;
    carry = v >> 8;
  }
  if (carry != 0) {
    for (var i = outLen - 1; i >= 0; i--) {
      final v = out[i] + carry;
      out[i] = v & 0xff;
      carry = v >> 8;
      if (carry == 0) break;
    }
  }
  return Uint8List.fromList(out);
}

int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

/// The AES "dr" random-to-key derivation (RFC 3961 §16.3 / 3962 §3):
/// DK(base, wellKnown) = random-to-key(DR(base, wellKnown)).
Uint8List deriveKeyAes(Uint8List key, Uint8List constant) {
  final keyLen = key.length;
  final n = (constant.length + keyLen - 1) ~/ keyLen * keyLen;
  final folded = nFold(constant, n);
  // DR: CBC-encrypt the folded constant with the base key, then
  // CBC-decrypt each block and XOR it with the PREVIOUS ciphertext block
  // (the RFC 3961 derivation primitive) — the first keyLen bytes are DK.
  final e = <Uint8List>[];
  for (var i = 0; i + 16 <= folded.length; i += 16) {
    e.add(Uint8List.fromList(folded.sublist(i, i + 16)));
  }
  final cipherBytes = AesCts.cbc(key, Uint8List(16), e, true);
  final cipher = <Uint8List>[
    for (var i = 0; i + 16 <= cipherBytes.length; i += 16)
      Uint8List.fromList(cipherBytes.sublist(i, i + 16))
  ];
  final decBlocks = AesCts.cbc(key, Uint8List(16), cipher, false);
  // XOR each decrypted block with the PREVIOUS ciphertext block (DR)
  final result = Uint8List(keyLen);
  var done = 0;
  for (var i = 0; i < cipher.length && done < keyLen; i++) {
    final decd = Uint8List.sublistView(decBlocks, i * 16, i * 16 + 16);
    final prevC = i == 0 ? Uint8List(16) : cipher[i - 1];
    for (var k = 0; k < 16 && done < keyLen; k++) {
      result[done++] = decd[k] ^ prevC[k];
    }
  }
  return result;
}

/// RFC 4121 per-usage keys from the session key.
class KerbKeys {
  KerbKeys(this.base, this.usage) {
    kc = deriveKeyAes(base, _usageConstant(usage, 0x99));
    ke = deriveKeyAes(base, _usageConstant(usage, 0xaa));
    ki = deriveKeyAes(base, _usageConstant(usage, 0x55));
  }

  final Uint8List base;
  final int usage;
  late final Uint8List kc; // checksum (HMAC-SHA1)
  late final Uint8List ke; // encryption
  late final Uint8List ki; // integrity

  static Uint8List _usageConstant(int usage, int kind) {
    final b = Uint8List(5);
    ByteData.view(b.buffer).setUint32(0, usage, Endian.big);
    b[4] = kind;
    return b;
  }
}

// ---------------------------------------------------------------------------
// AES-CBC-CTS (CS3)
// ---------------------------------------------------------------------------

/// AES-CBC ciphertext stealing, CS3 block order (RFC 3962): the last TWO
/// ciphertext blocks are swapped relative to CS1.
class AesCts {
  AesCts._();

  static Uint8List cbc(Uint8List key, Uint8List iv, List<Uint8List> blocks, bool encrypt) {
    // manual chaining on raw ECB
    final out = <Uint8List>[];
    var chain = Uint8List.fromList(iv);
    if (encrypt) {
      for (final blk in blocks) {
        final x = Uint8List(16);
        for (var i = 0; i < 16; i++) {
          x[i] = blk[i] ^ chain[i];
        }
        chain = _ecb(key, x, true);
        out.add(chain);
      }
    } else {
      for (final blk in blocks) {
        final d = _ecb(key, blk, false);
        final x = Uint8List(16);
        for (var i = 0; i < 16; i++) {
          x[i] = d[i] ^ chain[i];
        }
        out.add(x);
        chain = Uint8List.fromList(blk);
      }
    }
    return concat(out);
  }

  static Uint8List _ecb(Uint8List key, Uint8List blk, bool encrypt) {
    final ecb = ECBBlockCipher(AESEngine())..init(encrypt, KeyParameter(key));
    final out = Uint8List(16);
    ecb.processBlock(Uint8List.fromList(blk), 0, out, 0);
    return out;
  }

  static List<Uint8List> _blocks(Uint8List data) => [
        for (var i = 0; i + 16 <= data.length; i += 16)
          Uint8List.fromList(data.sublist(i, i + 16))
      ];

  /// CBC-CS3 ciphertext stealing. With n-1 full blocks and an L-byte tail:
  /// `C1..C(n-2)` encrypt normally; `D = E(P(n-1) ^ C(n-2))`; `Cn =
  /// E(P'n ^ D)` over the zero-padded tail; the wire carries
  /// `C1..C(n-2) || D[0:L] || Cn` (CS3: the truncated piece precedes the
  /// full stolen block). All-full input: plain CBC with the last two
  /// ciphertext blocks swapped.
  static Uint8List encrypt(Uint8List key, Uint8List iv, Uint8List data) {
    if (data.isEmpty) return Uint8List(0);
    if (data.length <= 16) {
      final padded = Uint8List(16)..setRange(0, data.length, data);
      final ct = cbc(key, iv, [padded], true);
      return Uint8List.sublistView(ct, 0, data.length);
    }
    final l = data.length % 16;
    if (l == 0) {
      final cs = _blocks(cbc(key, iv, _blocks(data), true));
      return concat([...cs.take(cs.length - 2), cs.last, cs[cs.length - 2]]);
    }
    final headEnd = data.length - 16 - l; // end of C1..C(n-2) region
    final head = _blocks(Uint8List.sublistView(data, 0, headEnd));
    final pLastFull = Uint8List.fromList(data.sublist(headEnd, headEnd + 16));
    final pTail = Uint8List(16)..setRange(0, l, data, headEnd + 16);
    // C(n-2) = the last ciphertext of the head (or the IV)
    final headCt = head.isEmpty ? Uint8List(0) : cbc(key, iv, head, true);
    final cPrev = head.isEmpty
        ? Uint8List.fromList(iv)
        : Uint8List.fromList(headCt.sublist(headCt.length - 16));
    var x = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      x[i] = pLastFull[i] ^ cPrev[i];
    }
    final dN = _ecb(key, x, true);
    x = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      x[i] = pTail[i] ^ dN[i];
    }
    final cN = _ecb(key, x, true);
    return concat([
      headCt,
      Uint8List.sublistView(dN, 0, l),
      cN,
    ]);
  }

  static Uint8List decrypt(Uint8List key, Uint8List iv, Uint8List data) {
    if (data.isEmpty) return Uint8List(0);
    if (data.length <= 16) {
      final padded = Uint8List(16)..setRange(0, data.length, data);
      final pt = cbc(key, iv, [padded], false);
      return Uint8List.sublistView(pt, 0, data.length);
    }
    final l = data.length % 16;
    if (l == 0) {
      final cs = _blocks(data);
      final unswapped = [...cs.take(cs.length - 2), cs.last, cs[cs.length - 2]];
      return cbc(key, iv, unswapped, false);
    }
    final headLen = data.length - 16 - l;
    final head = _blocks(Uint8List.sublistView(data, 0, headLen));
    final dnTrunc = Uint8List.fromList(data.sublist(headLen, headLen + l));
    final cN = Uint8List.fromList(data.sublist(headLen + l));
    // D(Cn) provides D's missing tail (the tail plaintext was zero-padded)
    final dCn = _ecb(key, cN, false);
    final dN = Uint8List(16)..setRange(0, l, dnTrunc);
    for (var i = l; i < 16; i++) {
      dN[i] = dCn[i];
    }
    final headPt = head.isEmpty ? Uint8List(0) : cbc(key, iv, head, false);
    final cPrev = head.isEmpty ? Uint8List.fromList(iv) : head.last;
    final dDn = _ecb(key, dN, false);
    final pLastFull = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      pLastFull[i] = dDn[i] ^ cPrev[i];
    }
    final pTail = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      pTail[i] = dCn[i] ^ dN[i];
    }
    return concat([headPt, pLastFull, Uint8List.sublistView(pTail, 0, l)]);
  }
}

// ---------------------------------------------------------------------------
// RFC 1964 / RFC 4757 tokens (RC4-HMAC)
// ---------------------------------------------------------------------------

const List<int> krb5MechOid = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x12, 0x01, 0x02, 0x02];

/// The RFC 1964 application token: `60 <len> 06 09 2a864886f712010202 …`.
Uint8List rfc1964TokenHeader() {
  final w = DerWriter();
  w.raw(0x06, krb5MechOid);
  final body = w.bytes();
  return Uint8List.fromList([0x60, body.length, ...body]);
}

Uint8List _rc4UsageKey(Uint8List key, int usage) {
  final u = Uint8List(4);
  ByteData.view(u.buffer).setUint32(0, usage, Endian.big);
  return hmacMd5(key, u);
}

/// RFC 4757 GetMic (SGN): MIT header (8) + RC4-encrypted HMAC-MD5 (16).
Uint8List rc4GetMic(Uint8List sessionKey, int usage, Uint8List data) {
  final ksign = _rc4UsageKey(sessionKey, usage);
  final header = Uint8List(8);
  header.buffer.asByteData().setUint16(0, 16, Endian.little);
  header[4] = 0x11; // SGN_ALG_HMAC ? conservative default per RFC 4757 §7.2
  final digest = hmacMd5(ksign, concat([header, data]));
  final cksum = Rc4(_rc4UsageKey(ksign, usage)).process(digest);
  return concat([header, cksum]);
}

/// RFC 4757 Wrap (SEAL): MIT header + encrypted cksum + RC4-encrypted data.
(Uint8List token, Uint8List body) rc4Wrap(
    Uint8List sessionKey, int usage, Uint8List data, Uint8List seqNum) {
  final ksign = _rc4UsageKey(sessionKey, usage);
  final header = Uint8List(8);
  header.buffer.asByteData().setUint16(0, 8, Endian.little);
  header[4] = 0x10; // SEAL_ALG_RC4
  final digest = hmacMd5(ksign, concat([header, data]));
  final cksum = Rc4(_rc4UsageKey(ksign, usage)).process(digest);
  final seq = Rc4(_rc4UsageKey(ksign, usage)).process(seqNum.length == 8
      ? seqNum
      : Uint8List.fromList([0, 0, 0, 0, 0, 0, ...seqNum.take(2)]));
  final bodyEnc = Rc4(_rc4UsageKey(sessionKey, usage)).process(data);
  final tokenOut = concat([header, cksum.sublist(0, 8), seq.sublist(0, 8), cksum.sublist(8, 16)]);
  return (concat([tokenOut]), bodyEnc);
}

// ---------------------------------------------------------------------------
// RFC 4121 tokens (AES)
// ---------------------------------------------------------------------------

const int tokIdMic = 0x0101;
const int tokIdWrap = 0x0201;

Uint8List rfc4121Header(int tokId, int flags, int filler, int ec, int rrc, int seq) {
  // TOK_ID(2) | Flags(1) | Filler(5) | EC(2) | RRC(2) | Seq(4) = 16 bytes
  final h = Uint8List(16);
  final bd = ByteData.view(h.buffer);
  bd.setUint16(0, tokId);
  h[2] = flags;
  bd.setUint16(8, ec);
  bd.setUint16(10, rrc);
  bd.setUint32(12, seq);
  return h;
}

/// RFC 4121 get_mic: token = header(16, EC=RRC=0) || HMAC-SHA1(Ki, ...).
Uint8List aesGetMic(KerbKeys keys, int usage, Uint8List data, int seq) {
  final header = rfc4121Header(tokIdMic, 0x04, 0, 0, 0, seq);
  final mic = hmacSha1(keys.ki, concat([header, data]));
  return concat([header, mic]);
}

/// RFC 4121 wrap with privacy (RRC=EC=0 "header outside" form used by SNC):
/// token = header(16); body = AES-CTS(Ke, iv=0, EC-filler || data || mic).
(Uint8List token, Uint8List body) aesWrap(
    KerbKeys keys, int usage, Uint8List data, int seq, {int ec = 0}) {
  final header = rfc4121Header(tokIdWrap, 0x06, 0, 0, 0, seq); // privacy+sealed
  final filler = Uint8List(ec);
  final plain = concat([filler, data, header]);
  final bodyEnc = AesCts.encrypt(keys.ke, Uint8List(16), plain);
  return (header, bodyEnc);
}

/// RFC 4121 wrap integrity-only (MIC in place of ciphertext).
(Uint8List token, Uint8List body) aesWrapIntegrityOnly(
    KerbKeys keys, int usage, Uint8List data, int seq,
    {int ec = 0}) {
  final header = rfc4121Header(tokIdWrap, 0x04, 0, 0, 0, seq);
  final filler = Uint8List(ec);
  final mic = hmacSha1(keys.ki, concat([filler, data, header]));
  return (concat([header, mic]), data);
}
