/// One compact DIAG trace line per answered DOI flush: every verb with the
/// value GuiGo answered for it — what a live Office-integration failure
/// (an `E` message out of C_OI_ERRORS) is diagnosed from, since the
/// session's `flush answered (N verbs)` line names no verb.
library;

import 'dart:typed_data';

import 'browser_launch.dart' show verbArgText;
import 'doi.dart';
import 'flush_call.dart';
import 'svars.dart';

/// The DataProvider verbs a DOI flush carries besides the Office ones (the
/// BDS document's PublishUrl probe, the save-back SetDataFromUrl /
/// SaveDataToUrl).
const Set<String> _doiDpVerbs = {'PublishUrl', 'SetDataFromUrl', 'SaveDataToUrl'};

/// The longest answer value the line shows (a LastErrorString text, a sink
/// url) before it is cut.
const int _valueCap = 32;

/// `DOI flush: OpenDocument=1(src 29184 B) LastError=0 … SaveDocumentToURL=33
/// (refused)` for [call] answered with [items], null when [call] is no DOI
/// flush. Values only: no document bytes, no argument text beyond the
/// verbs' names — a document open says whether its source bytes are held,
/// a save whether its upload is held or refused.
String? doiFlushTrace(DoiState st, FlushCall call, List<Uint8List> items) {
  final verbs = call.verbs;
  if (verbs.isEmpty) return null;
  final office = verbs.any(doiMethodTypes.containsKey);
  if (!office &&
      !(st.containers.isNotEmpty && verbs.any(_doiDpVerbs.contains))) {
    return null;
  }
  final results = _answerResults(items);
  final parts = <String>[];
  for (var i = 1; i <= verbs.length; i++) {
    final verb = verbs[i - 1];
    final v = results[i];
    var part = v == null ? verb : '$verb=${_cut(v)}';
    if (verb == 'OpenDocument') {
      final url = (verbArgText(call, i, '#3') ?? '').trim();
      Document? doc;
      for (final (_, d) in st.createdDocs.reversed) {
        if (d.sourceUrl == url) {
          doc = d;
          break;
        }
      }
      final n = doc?.sourceBytes?.length;
      part += n == null ? '(src none)' : '(src $n B)';
    } else if (verb == 'SaveDocumentToURL') {
      final url = (verbArgText(call, i, '#2') ?? '').trim();
      if (st.docErrors.containsKey(url)) {
        part += '(refused)';
      } else if (st.docBytes.containsKey(url)) {
        part += '(held ${st.docBytes[url]!.length} B)';
      }
    }
    parts.add(part);
  }
  return 'DOI flush: ${parts.join(' ')}';
}

String _cut(String v) {
  final s = v.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length <= _valueCap ? s : '${s.substring(0, _valueCap)}…';
}

/// verb index (1-based) -> the `_RESULT` value of the answer [items] (its
/// 16/8/1 RFC's PARAMS / VARS).
Map<int, String> _answerResults(List<Uint8List> items) {
  Uint8List? rfc;
  for (final it in items) {
    if (it.length >= 5 && it[0] == 0x10 && it[1] == 0x08 && it[2] == 0x01) {
      final len = (it[3] << 8) | it[4];
      if (5 + len <= it.length) rfc = Uint8List.sublistView(it, 5, 5 + len);
      break;
    }
  }
  if (rfc == null) return const {};
  final cols = rfcColumns(rfc, only: const {'PARAMS', 'VARS'});
  final p = cols['PARAMS'], v = cols['VARS'];
  final params = p != null
      ? parseSvars(p.blob, p.width ?? paramsW)
      : [
          for (final (i, r) in inlineColumnRows(rfc, 'PARAMS', paramsW).indexed)
            Rec(i, r),
        ];
  final vars = v != null
      ? parseSvars(v.blob, v.width ?? varsW)
      : [
          for (final (i, r) in inlineColumnRows(rfc, 'VARS', varsW).indexed)
            Rec(i, r),
        ];
  final out = <int, String>{};
  for (final r in params) {
    if (r.name != '_RESULT') continue;
    final oid = int.tryParse(r.objid.trim());
    final slot = int.tryParse(r.slot.trim());
    if (oid == null || slot == null || slot < 1 || slot > vars.length) continue;
    out[oid] = vars[slot - 1].valueText;
  }
  return out;
}
