import 'dart:async';
import 'dart:convert';

import 'package:diag_protocol/diag_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The dropdown listboxes' value-set cache on disk — SAP GUI for Windows'
/// `Cache1\DataP_sapvaluesetI<id>` file cache (sapdatap.ocx
/// `ValuesetCache_Lookup` / `ValuesetCache_SetAt`): a set the server marked
/// CACHEABLE under its CONTENT id (32 hex) is kept across logons and app
/// launches, so a later screen showing the same list asks the server for
/// nothing (a recorded session: no request with the cache warm;
/// a recorded session: the request once it is wiped).
///
/// [attach] seeds [ValueSetCache.shared] from the app's preferences and
/// writes every set stored afterwards back (debounced). A corrupt store
/// reads as empty. Only the newest [maxSets] are written.
class ValueSetDiskCache {
  ValueSetDiskCache._(this._prefs, this._cache);

  static const String prefsKey = 'guigo.valueSetCache';

  /// The bound of the persisted copy (the in-memory cache keeps its own).
  static const int maxSets = 400;

  final SharedPreferences _prefs;
  final ValueSetCache _cache;
  Timer? _pending;

  /// Load the persisted sets into [cache] (default the shared one) and
  /// persist its later stores; a platform without preferences (a widget
  /// test) leaves the cache memory-only.
  static Future<ValueSetDiskCache?> attach([ValueSetCache? cache]) async {
    final c = cache ?? ValueSetCache.shared;
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } on Object {
      return null;
    }
    final disk = ValueSetDiskCache._(prefs, c);
    c.load(decode(prefs.getString(prefsKey)));
    c.onStore = (_) => disk._schedule();
    return disk;
  }

  void _schedule() {
    _pending?.cancel();
    _pending = Timer(const Duration(seconds: 2), flush);
  }

  /// Write the cache now.
  Future<void> flush() async {
    _pending?.cancel();
    _pending = null;
    final sets = _cache.sets.toList();
    final keep = sets.length > maxSets
        ? sets.sublist(sets.length - maxSets)
        : sets;
    await _prefs.setString(prefsKey, encode(keep));
  }

  /// The persisted form: a JSON list of `{n: id, e: [[key, text], …]}`.
  static String encode(Iterable<ValueSet> sets) => jsonEncode([
    for (final s in sets)
      {
        'n': s.name,
        'e': [
          for (final e in s.entries) [e.key, e.text],
        ],
      },
  ]);

  /// The sets of a persisted [raw] form; [] when it is absent or corrupt.
  static List<ValueSet> decode(String? raw) {
    if (raw == null) return const [];
    Object? j;
    try {
      j = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (j is! List) return const [];
    final out = <ValueSet>[];
    for (final s in j) {
      if (s is! Map) continue;
      final name = s['n'];
      final entries = s['e'];
      if (name is! String || entries is! List) continue;
      out.add(
        ValueSet(name, [
          for (final e in entries)
            if (e is List && e.length == 2 && e[0] is String && e[1] is String)
              ValueSetEntry(e[0] as String, e[1] as String),
        ], cacheable: true),
      );
    }
    return out;
  }
}
