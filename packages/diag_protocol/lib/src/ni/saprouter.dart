/// SAProuter route requests (NI_ROUTE), per the pysap SAPRouter layout.
///
/// The client connects to the first router hop, sends one NI-framed
/// NI_ROUTE packet listing every hop through to the target, and gets back
/// NI_PONG (route open — the socket now talks to the target) or NI_RTERR.
library;

import 'dart:convert';
import 'dart:typed_data';

class RouteHop {
  RouteHop(this.host, this.port, [this.password = '']);

  final String host;
  final String port; // number or service name, sent as text
  final String password;

  @override
  String toString() => '/H/$host/S/$port${password.isEmpty ? '' : '/W/***'}';
}

final _nonPrintable = RegExp(r'[^\x20-\x7e]');
final _hopRe = RegExp(r'/[hH]/([\w.\-]+)(?:/[sS]/(\w+))?(?:/[pwPW]/([\w.]+))?');

/// Parse `(/H/host/S/service/W/pass)*`; a hop without /S/ uses 3299.
List<RouteHop> parseRouteString(String route) => [
  for (final m in _hopRe.allMatches(route))
    RouteHop(m.group(1)!, m.group(2) ?? '3299', m.group(3) ?? ''),
];

/// The TCP port of an SAP service named on a route's `/S/` (the first hop
/// is the one connected to): a number as is, else the SAP standard service
/// names of /etc/services — `sapdp<NN>` 32NN (`sapdp99` the SAProuter's
/// 3299), `sapgw<NN>` 33NN, their secure `sapdp<NN>s` 47NN / `sapgw<NN>s`
/// 48NN, and `saprouter` 3299. Any other name (a `sapms<SID>` message
/// server, a site alias) has no fixed port: an [ArgumentError] says so,
/// instead of a bare FormatException from parsing it as a number.
int resolveServicePort(String service) {
  final s = service.trim();
  final n = int.tryParse(s);
  if (n != null) {
    if (n < 1 || n > 65535) {
      throw ArgumentError.value(service, 'service', 'port out of range');
    }
    return n;
  }
  final low = s.toLowerCase();
  if (low == 'saprouter') return 3299;
  final m = _resolveServicePortRx.firstMatch(low);
  if (m != null) {
    final nn = int.parse(m.group(2)!);
    final secure = m.group(3)!.isNotEmpty;
    final base = switch ((m.group(1), secure)) {
      ('dp', false) => 3200,
      ('gw', false) => 3300,
      ('dp', true) => 4700,
      _ => 4800,
    };
    return base + nn;
  }
  throw ArgumentError.value(
      service,
      'service',
      'SAP service name with no well-known port: give the port number '
          '(e.g. /S/3299)');
}

const _routeEyecatcher = 'NI_ROUTE';
const _pongEyecatcher = 'NI_PONG';
const _errEyecatcher = 'NI_RTERR';

/// The NI_ROUTE payload (without the NI length prefix) for [hops], the last
/// of which is the target application server.
Uint8List buildRouteRequest(List<RouteHop> hops) {
  if (hops.length < 2) {
    throw ArgumentError('a route needs at least a router and a target');
  }
  final encoded = [
    for (final h in hops)
      [
        ...latin1.encode(h.host),
        0,
        ...latin1.encode(h.port),
        0,
        ...latin1.encode(h.password),
        0,
      ],
  ];
  final routeLen = encoded.fold<int>(0, (n, e) => n + e.length);
  final b = BytesBuilder();
  b.add(latin1.encode(_routeEyecatcher));
  b.addByte(0);
  b.addByte(2); // router protocol version
  b.addByte(40); // NI version
  b.addByte(hops.length); // entries
  b.addByte(0); // talk mode: NI_MSG_IO
  b.add([0, 0]); // padding
  b.addByte(hops.length - 1); // rest nodes
  final ints = ByteData(8)
    ..setUint32(0, routeLen)
    ..setUint32(4, encoded.first.length); // offset to the next hop
  b.add(ints.buffer.asUint8List());
  for (final e in encoded) {
    b.add(e);
  }
  return b.toBytes();
}

class SapRouterException implements Exception {
  SapRouterException(this.message);
  final String message;
  @override
  String toString() => 'SAProuter: $message';
}

/// Throws unless [payload] (one NI payload) is the router's NI_PONG.
void checkRouteReply(Uint8List payload) {
  final text = latin1.decode(payload, allowInvalid: true);
  if (text.startsWith(_pongEyecatcher)) return;
  if (text.startsWith(_errEyecatcher)) {
    // the error body is a run of NUL-separated text fields (*ERR* … *ERR*);
    // keep the readable ones for the message
    final parts = text
        .split('\x00')
        .map((s) => s.replaceAll(_nonPrintable, '').trim())
        .where((s) => s.length > 1 && s != '*ERR*' && s != _errEyecatcher)
        .toList();
    throw SapRouterException(
      parts.isEmpty ? 'route refused' : parts.join(' | '),
    );
  }
  throw SapRouterException('unexpected reply to route request');
}

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call.
final RegExp _resolveServicePortRx = RegExp(r'^sap(dp|gw)(\d\d)(s?)$');
