import 'dart:convert';

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A stored connection: everything except the password lives in plain
/// preferences; the password sits in the platform secure store (iOS
/// Keychain, device-only `unlocked_this_device`; Android
/// `EncryptedSharedPreferences`; macOS the login keychain). With biometrics enrolled it is read only
/// after Face ID / Touch ID / fingerprint succeeds; without, it is used
/// directly — then protected only by the store (on iOS readable only while
/// this device is unlocked; on Android encrypted at rest, no unlock gate).
/// See `releaseStoredPassword` (core/password_gate.dart).
class ConnectionEntry {
  ConnectionEntry({
    required this.id,
    required this.name,
    required this.host,
    this.port = defaultSapPort,
    this.routerString = '',
    this.client = defaultLogonClient,
    this.user = '',
    this.language = defaultLogonLanguage,
    this.storePassword = true,
    this.keepOtherSessions = false,
  });

  final String id;
  String name;
  String host;
  int port;
  String routerString;
  String client;
  String user;
  String language;
  bool storePassword;

  /// At SAP's multi-logon dialog ("already logged on"), continue without
  /// ending the other sessions (OPT2) instead of asking. Off by default:
  /// the dialog then asks with SAP's own preselection (OPT3, terminate this
  /// logon) — a second logon is a licensing matter the user decides.
  bool keepOtherSessions;

  /// What the entry is called on screen: its name, or `host:port` when
  /// it has none (the list, the delete and password prompts, the logon
  /// dialog — never an empty title).
  String get label => name.isEmpty ? '$host:$port' : name;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'router': routerString,
        'client': client,
        'user': user,
        'language': language,
        'storePassword': storePassword,
        'keepOtherSessions': keepOtherSessions,
      };

  factory ConnectionEntry.fromJson(Map<String, dynamic> j) => ConnectionEntry(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        host: j['host'] as String? ?? '',
        port: (j['port'] as num?)?.toInt() ?? defaultSapPort,
        routerString: j['router'] as String? ?? '',
        client: j['client'] as String? ?? defaultLogonClient,
        user: j['user'] as String? ?? '',
        language: j['language'] as String? ?? defaultLogonLanguage,
        storePassword: j['storePassword'] as bool? ?? true,
        keepOtherSessions: j['keepOtherSessions'] as bool? ?? false,
      );

  SapSystem toSystem() => SapSystem(
        name: name,
        host: host,
        port: port,
        routerString: routerString,
        client: client,
        user: user,
        language: language,
      );
}

class ConnectionStore {
  ConnectionStore(this._prefs, this._secure);

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  static const _key = 'guigo.connections';

  static Future<ConnectionStore> create() async {
    final prefs = await SharedPreferences.getInstance();
    const secure = FlutterSecureStorage();
    return ConnectionStore(prefs, secure);
  }

  /// The stored connections. A corrupt store (unparsable JSON, a wrong
  /// shape) or a malformed entry never crashes the list: what cannot be
  /// read is skipped.
  List<ConnectionEntry> list() {
    final raw = _prefs.getString(_key);
    if (raw == null) return [];
    Object? j;
    try {
      j = jsonDecode(raw);
    } on FormatException {
      return [];
    }
    if (j is! List) return [];
    final out = <ConnectionEntry>[];
    for (final e in j) {
      if (e is! Map<String, dynamic>) continue;
      try {
        out.add(ConnectionEntry.fromJson(e));
      } on TypeError {
        // a field of the wrong type (id missing, a number as text …)
      }
    }
    return out;
  }

  Future<void> saveAll(List<ConnectionEntry> entries) async {
    await _prefs.setString(
        _key, jsonEncode([for (final e in entries) e.toJson()]));
  }

  Future<void> savePassword(String id, String password) async {
    await _secure.write(
        key: 'guigo.pw.$id',
        value: password,
        aOptions: _androidOpts,
        iOptions: _iosOpts,
        mOptions: _macOpts);
  }

  Future<String?> readPassword(String id) async {
    return _secure.read(
        key: 'guigo.pw.$id',
        aOptions: _androidOpts,
        iOptions: _iosOpts,
        mOptions: _macOpts);
  }

  /// Whether a password is stored for [id] — asked of the secure store
  /// without reading the value (the value itself is read by [readPassword]
  /// only once `releaseStoredPassword` lets it out: after the biometric
  /// prompt when biometrics are enrolled, directly when none are).
  Future<bool> hasPassword(String id) {
    return _secure.containsKey(
        key: 'guigo.pw.$id',
        aOptions: _androidOpts,
        iOptions: _iosOpts,
        mOptions: _macOpts);
  }

  Future<void> deletePassword(String id) async {
    await _secure.delete(
        key: 'guigo.pw.$id',
        aOptions: _androidOpts,
        iOptions: _iosOpts,
        mOptions: _macOpts);
  }

  /// Whether the user has seen (and dismissed) the unencrypted-connection
  /// notice for connection [id].
  bool plaintextNoticeSeen(String id) =>
      _prefs.getBool('$_plaintextKey.$id') ?? false;

  Future<void> markPlaintextNoticeSeen(String id) async {
    await _prefs.setBool('$_plaintextKey.$id', true);
  }

  static const _plaintextKey = 'guigo.plaintextNoticeSeen';

  /// Which system value the status bar shows (SAP GUI's status-bar
  /// dropdown: system, client, user, program, transaction) — one choice
  /// for every connection, like SAP GUI's own.
  String get statusInfo => _prefs.getString(_statusInfoKey) ?? 'system';

  Future<void> setStatusInfo(String key) async {
    await _prefs.setString(_statusInfoKey, key);
  }

  static const _statusInfoKey = 'guigo.statusInfo';

  static const _androidOpts = AndroidOptions(encryptedSharedPreferences: true);
  static const _iosOpts =
      IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device);

  /// macOS: the login (file-based) keychain, not the data-protection one —
  /// that needs a `keychain-access-groups` entitlement, i.e. a build signed
  /// with a development team; without one every call fails with -34018
  /// (errSecMissingEntitlement). The login keychain is still per-user,
  /// encrypted at rest and locked with the Mac's login.
  static const _macOpts = MacOsOptions(useDataProtectionKeyChain: false);
}
