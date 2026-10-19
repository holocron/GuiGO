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
      final src = doc?.sourceBytes;
      final text = src == null ? null : rtfVisibleCharCount(src);
      part += src == null
          ? '(src none)'
          : text == null
          ? '(src ${src.length} B)'
          : '(src ${src.length} B, text $text chars)';
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

/// How many visible, non-blank characters the RTF document [rtf] holds —
/// the body text Word shows, the font / colour / style tables, `\info`,
/// starred destinations (`\*\ud`, `\*\fldinst` …) and hidden text (`\v`)
/// left out; null when [rtf] is no RTF. A count, never the text: the DOI
/// trace line tells a SAPscript / SmartForms text the server sent empty
/// (COMPOSE_RTF's one default `* ` paragraph: 0) from one GuiGo failed to
/// show (a recorded session srv[42]: 0; SO10
/// a recorded session srv[36]: the 15 text lines).
int? rtfVisibleCharCount(Uint8List rtf) {
  const head = [0x7b, 0x5c, 0x72, 0x74, 0x66]; // {\rtf
  if (rtf.length < head.length) return null;
  for (var i = 0; i < head.length; i++) {
    if (rtf[i] != head[i]) return null;
  }
  const skipWords = {
    'fonttbl', 'colortbl', 'stylesheet', 'info', 'pict', 'object',
    'header', 'headerl', 'headerr', 'headerf', 'footer', 'footerl',
    'footerr', 'footerf', 'footnote', 'annotation', 'listtable',
    'listoverridetable', 'rsidtbl', 'generator', 'themedata',
    'colorschememapping', 'latentstyles', 'datastore', 'xmlnstbl',
  };
  final skip = <bool>[false];
  final hidden = <bool>[false];
  var first = false; // the next token is a group's first
  var fallback = 0; // \uN fallback characters still to drop
  var uc = 1;
  var n = 0;
  bool alpha(int c) => (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
  bool digit(int c) => c >= 0x30 && c <= 0x39;
  void visible(bool blank) {
    if (fallback > 0) {
      fallback--;
      return;
    }
    if (!skip.last && !hidden.last && !blank) n++;
  }

  var i = 0;
  while (i < rtf.length) {
    final c = rtf[i];
    if (c == 0x7b) {
      skip.add(skip.last);
      hidden.add(hidden.last);
      first = true;
      i++;
      continue;
    }
    if (c == 0x7d) {
      if (skip.length > 1) skip.removeLast();
      if (hidden.length > 1) hidden.removeLast();
      first = false;
      i++;
      continue;
    }
    final wasFirst = first;
    first = false;
    if (c == 0x0d || c == 0x0a) {
      i++;
      continue;
    }
    if (c != 0x5c) {
      visible(c == 0x20 || c == 0x09);
      i++;
      continue;
    }
    // a control word / symbol
    i++;
    if (i >= rtf.length) break;
    final d = rtf[i];
    if (!alpha(d)) {
      i++;
      if (d == 0x2a) {
        if (wasFirst) skip[skip.length - 1] = true; // {\* ignorable
      } else if (d == 0x27) {
        // \'hh — COMPOSE_RTF writes a text's spaces as \'20
        final h = i + 2 <= rtf.length
            ? int.tryParse(String.fromCharCodes(rtf, i, i + 2), radix: 16)
            : null;
        i += 2;
        visible(h == 0x20 || h == 0x09 || h == 0xa0);
      } else if (d == 0x5c || d == 0x7b || d == 0x7d || d == 0x7e) {
        visible(d == 0x7e); // \\ \{ \} literally, \~ a blank
      } else if (fallback > 0) {
        fallback--; // `\ ` — COMPOSE_RTF's \uN fallback symbol
      }
      continue;
    }
    final ws = i;
    while (i < rtf.length && alpha(rtf[i])) {
      i++;
    }
    final word = String.fromCharCodes(rtf, ws, i);
    final ps = i;
    if (i < rtf.length && (rtf[i] == 0x2d || digit(rtf[i]))) i++;
    while (i < rtf.length && digit(rtf[i])) {
      i++;
    }
    final p = ps == i ? null : int.tryParse(String.fromCharCodes(rtf, ps, i));
    if (i < rtf.length && rtf[i] == 0x20) i++;
    if (wasFirst && skipWords.contains(word)) {
      skip[skip.length - 1] = true;
    } else if (word == 'v') {
      hidden[hidden.length - 1] = p != 0;
    } else if (word == 'plain') {
      hidden[hidden.length - 1] = false;
    } else if (word == 'uc') {
      uc = p ?? 1;
    } else if (word == 'u') {
      visible(false);
      fallback = uc;
    } else if (word == 'bin') {
      i += p ?? 0;
    }
  }
  return n;
}

// hoisted: [_cut] runs per traced verb value (audit 2026-10-17 N1)
final RegExp _blankRunRx = RegExp(r'\s+');

String _cut(String v) {
  final s = v.replaceAll(_blankRunRx, ' ').trim();
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
