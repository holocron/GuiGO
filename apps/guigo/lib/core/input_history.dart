import 'dart:convert';

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SAP GUI's local INPUT HISTORY (SAP GUI for Windows help, "Local Data >
/// History"): a value is stored "as soon as you take over a value you typed
/// (by pressing ENTER or leaving the field)"; while typing, the earlier
/// values of the same field that match the input are offered. It is keyed
/// by the FIELD NAME (the dynpro field, e.g. `VBAK-AUART` — the same field
/// on another screen shares its history) per system; "Maximum Number of
/// Entries" values per field, most recent first; only fields up to "Enable
/// History for Fields up to" characters (default 59); never fields the
/// application keeps out (passwords). "Clear History" deletes it across all
/// systems. On by default.
///
/// Persisted in the app's preferences (the connections store's pattern,
/// core/connections.dart) — one JSON map system -> field -> values; a
/// corrupt store reads as empty, never as a crash.
class InputHistoryStore extends ChangeNotifier {
  /// A store over [prefs]; null = memory only (tests, no plugin).
  InputHistoryStore({
    SharedPreferences? prefs,
    this.maxPerField = 20,
    this.maxFieldLength = 59,
  }) : _prefs = prefs {
    if (prefs != null) _read(prefs);
  }

  /// The app's store, loaded from the platform preferences; a platform
  /// without them (a widget test without mock values) gets a memory store.
  static Future<InputHistoryStore> create() async {
    try {
      return InputHistoryStore(prefs: await SharedPreferences.getInstance());
    } on Object {
      return InputHistoryStore();
    }
  }

  final SharedPreferences? _prefs;

  /// Values kept per field (SAP GUI's "Maximum Number of Entries").
  final int maxPerField;

  /// The longest field (characters) whose input is kept (SAP GUI's "Enable
  /// History for Fields up to", default 59).
  final int maxFieldLength;

  static const String prefsKey = 'guigo.inputHistory';
  static const String enabledKey = 'guigo.inputHistory.enabled';

  /// system -> field name -> values, most recent first.
  final Map<String, Map<String, List<String>>> _data = {};
  bool _enabled = true;

  void _read(SharedPreferences p) {
    _enabled = p.getBool(enabledKey) ?? true;
    final raw = p.getString(prefsKey);
    if (raw == null) return;
    Object? j;
    try {
      j = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (j is! Map) return;
    for (final MapEntry(key: sys, value: fields) in j.entries) {
      if (sys is! String || fields is! Map) continue;
      final out = <String, List<String>>{};
      for (final MapEntry(key: name, value: values) in fields.entries) {
        if (name is! String || values is! List) continue;
        final vs = [
          for (final v in values)
            if (v is String && v.isNotEmpty) v,
        ];
        if (vs.isNotEmpty) out[name] = vs.take(maxPerField).toList();
      }
      if (out.isNotEmpty) _data[sys] = out;
    }
  }

  Future<void> _write() async {
    final p = _prefs;
    if (p == null) return;
    try {
      await p.setString(prefsKey, jsonEncode(_data));
    } on Object {
      // a store that cannot be written keeps the memory copy
    }
  }

  /// Whether the history records and offers values (SAP GUI: On / Off).
  bool get enabled => _enabled;

  Future<void> setEnabled(bool on) async {
    if (_enabled == on) return;
    _enabled = on;
    notifyListeners();
    try {
      await _prefs?.setBool(enabledKey, on);
    } on Object {
      // kept for this run
    }
  }

  /// The values of [field] on [system], most recent first.
  List<String> entries(String system, String field) =>
      List.unmodifiable(_data[system]?[field] ?? const <String>[]);

  /// The earlier values of [field] on [system] that start with [typed]
  /// (case-insensitive; every value for an empty input — SAP GUI's history
  /// on Backspace in an empty field), most recent first, the typed value
  /// itself left out. Nothing when the history is off.
  List<String> matches(
    String system,
    String field,
    String typed, {
    int limit = 10,
  }) {
    if (!_enabled) return const [];
    final t = typed.trimRight().toLowerCase();
    return [
      for (final v in entries(system, field))
        if (v.toLowerCase().startsWith(t) && v != typed.trimRight()) v,
    ].take(limit).toList();
  }

  /// Keep [value] typed into [field] on [system] (the most recent first;
  /// an earlier copy moves up; at most [maxPerField]). Blank values and
  /// values longer than [maxFieldLength] are not kept; nothing when off.
  Future<void> record(String system, String field, String value) async {
    final v = value.trimRight();
    if (!_enabled || field.isEmpty || v.trim().isEmpty) return;
    if (v.length > maxFieldLength) return;
    final list = (_data[system] ??= {})[field] ??= [];
    if (list.isNotEmpty && list.first == v) return;
    list
      ..remove(v)
      ..insert(0, v);
    if (list.length > maxPerField) list.removeRange(maxPerField, list.length);
    notifyListeners();
    await _write();
  }

  /// Forget [value] of [field] (SAP GUI: Del in the history list).
  Future<void> remove(String system, String field, String value) async {
    final list = _data[system]?[field];
    if (list == null || !list.remove(value)) return;
    if (list.isEmpty) _data[system]!.remove(field);
    notifyListeners();
    await _write();
  }

  /// SAP GUI's "Clear History": every entry of every system.
  Future<void> clear() async {
    if (_data.isEmpty) return;
    _data.clear();
    notifyListeners();
    final p = _prefs;
    try {
      await p?.remove(prefsKey);
    } on Object {
      // nothing stored to clear
    }
  }

  /// Whether any value is kept.
  bool get isEmpty => _data.isEmpty;
}

/// The history key of the system that painted [m]: its system id and
/// client (ST_R3INFO 16/6/2 / 16/6/12 — [ScreenModel.systemId] /
/// [ScreenModel.client]), so two systems never mix their values.
String inputHistorySystem(ScreenModel m) =>
    '${m.systemId ?? '-'}/${m.client ?? '-'}';

/// Whether [f] of [m] may keep an input history: a named, editable, visible
/// input — never a password / invisible field (the INVISIBLE attribute,
/// [ScreenField.invisible]; a BCODE / PASSW / PWD name like the session's
/// secret rule), never a field of the logon program SAPMSYST, never one
/// longer than [maxFieldLength].
bool inputHistoryEligible(
  ScreenModel m,
  ScreenField f, {
  int maxFieldLength = 59,
}) {
  final name = f.name ?? '';
  if (f.kind != FieldKind.input || f.isProtected || f.invisible) return false;
  if (name.isEmpty) return false;
  if ((m.program ?? '').trim().toUpperCase() == 'SAPMSYST') return false;
  if (RegExp(r'BCODE|PASSW|PWD', caseSensitive: false).hasMatch(name)) {
    return false;
  }
  final len = f.maxnrchars > 0 ? f.maxnrchars : f.mlen;
  return len <= maxFieldLength;
}
