/// The SAP GUI for Windows F4 value-help dialog — the ActiveX
/// `SAP.TABControl.1` (WDTMCTRL.OCX) a server hosts instead of the classic
/// SAPLSDH4 hit-list dynpro whenever the connect bitmap carries OCX_SUPPORT
/// (read side; the gestures are SapSession.searchValueHelp / … in
/// sap_session_value_help.dart). Port of the reference client's
/// .
///
/// Wire shape (real SAP GUI for Windows: a recorded session,
/// a recorded session, a recorded session,
/// a recorded session, a recorded session):
/// * `CreateControl(<shell>, SAP.TABControl.1, …)` alone in its queue
/// (f4_modes srv[25], scrubbed index — raw 27), then
/// `LinkControl(<shell>, <program>, <dynpro>)` — the calling popup
/// (SAPMS01GNEW/0010 on SU53)
/// or the control-only SAPLWDTM/0100 (`MCX_DUMMY_POPUP`, me51n srv[49]);
/// * the dialog MODEL, each a GuiDataProvider push ON the control's
/// automation object (the role is the verb — [dpPushBindings]):
/// - `setMessages` — `mctbc_cmsg` M_NUMBER | MESSAGE (84 texts);
/// - `setDialogPages` — `MCTBC_DP` TABCTRL | DIALOGNR (the page id) |
/// TITLE | RESULT | MATCHCODE | MC_ID (`S` = the pre-selected page,
/// MAT1W on a collective help) | SHLP_NAME (f4_modes srv[28]: one
/// page `1 | 10 | Restrictions | … | S | USER_ADDR`; prefilled srv
/// 42-45: 30 pages);
/// - `setDialogItems` — `MCTBC_DI` … TYPE | ID | POS_X | POS_Y |
/// SIZE_X | SIZE_Y | TEXT | RESULT | ICON | FIELDNAME | WSSTYLE: B =
/// button (1 "Lancer rech.", 2 "Sélection multiple", 4 "Fermer"),
/// T = label, X = input (ID 18xx, FIELDNAME = the hit-list column it
/// restricts), `4` = a PRE-FILLED input (TEXT = its default, ICON =
/// the option word — prefilled 1801 SPRAS `FR` / `EQ`), E = the
/// max-hits item (TEXT = the count);
/// - `setSelOpts` — `ddshselopt` SHLPNAME (= the page) | SHLPFIELD |
/// SIGN | OPTION | LOW | HIGH, the pre-fill (empty on most dialogs);
/// - `setResultTableCols` — `mctbc_coln` FIELDNAME | SCRTEXT |
/// APPEARANCE | SCRTEXT_M | SCRTEXT_L, one row per hit-list column;
/// - `createResultDialog(<dp>, 0, <key field>, 4)` — the hit list
/// itself, a table in its own structure (P_USER_ADDR, 500 rows,
/// f4_modes srv[38]); it rides the CREATION wave when the server
/// ran the search itself (prefilled Division srv 21-23: no page to
/// search, the hit list only);
/// * scalar verbs on the object: `createTab(<caption>, 1)`,
/// `setActivePage(<page>)`, `setSearchField`, `setSearchResultStatusLine`;
/// * the teardown: `destroyTab` on the object, `DestroyWindow(<shell>)`
/// (f4_modes srv[40] / [41]) after a pick or a close.
///
/// The object token the verbs name is the frontend's own mint for the
/// CreateControl result (the session alias); a queue recorded from another
/// frontend names ITS mint — then the token is bound to the newest dialog
/// created without one (the verbs are the control's own, no other class
/// answers them).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../cfw/dp_cache.dart';
import '../cfw/flush_call.dart';
import 'sap_tree.dart' show DpTable, decodeNamedDpTable;

/// The ProgID of the value-help control.
final RegExp valueHelpClassRx = RegExp(r'^SAP\.TABControl\.\d+$');

/// The control's event ids (`%_GC <shell> <id>`): 2 = a page ITEM pressed
/// (PARAMs page, item, 1, X — item 1001 the search, 1002 the close),
/// 4 = a hit-list row picked, 8 = a restriction page activated (PARAMs
/// TABCTRL, page) — a recorded session gui raw[26] / raw[34],
/// a recorded session gui raw[65].
const int valueHelpEventItem = 2;
const int valueHelpEventPick = 4;
const int valueHelpEventPage = 8;

/// The page-level items the dialog's buttons fire (EVENTID 2 PID 1).
const String valueHelpItemSearch = '1001';
const String valueHelpItemClose = '1002';

/// One item of a page (MCTBC_DI row).
class SapValueHelpItem {
  const SapValueHelpItem({
    required this.id,
    required this.type,
    required this.page,
    this.text = '',
    this.label = '',
    this.fieldName = '',
    this.icon = '',
    this.x = 0,
    this.y = 0,
    this.width = 0,
    this.height = 0,
    this.tabControl = '',
  });

  /// The item id (`1800`, `1001`, …) — what a restriction upload names.
  final String id;

  /// B button, T label, X input, `4` pre-filled input, E max hits.
  final String type;

  /// The page (DIALOGNR) the item is on.
  final String page;

  /// The item's text: a button's / label's caption, an input's pushed
  /// default (prefilled 1801 `FR`), the max-hits count (`500`).
  final String text;

  /// An input's label: the T item painted on the same row of its page.
  final String label;

  /// The hit-list column an input restricts (`BNAME`, `MAKTG`, …).
  final String fieldName;

  /// The ICON column: a button's icon (`@B_OKAY@`), `X` on a plain input,
  /// the option word on a pre-filled one (`EQ`), `MAXHITS` on the E item.
  final String icon;

  /// The item's place on the page (POS_X / POS_Y / SIZE_X / SIZE_Y, the
  /// OCX's dialog units).
  final int x;
  final int y;
  final int width;
  final int height;

  /// The TABCTRL the page belongs to (EVENTID 8's PID 0).
  final String tabControl;

  bool get isInput => type != 'B' && type != 'T' && type != 'E';

  /// A PRE-FILLED input (type `4`): it shows its pushed default [text]
  /// (prefilled 1801 `FR`) — a plain input (`X`) starts empty. Not
  /// [isInput], which holds for both.
  bool get isPrefilledInput => type == '4';

  @override
  String toString() =>
      'SapValueHelpItem($type $id "$text"'
      '${fieldName.isEmpty ? '' : ' $fieldName'})';
}

/// One restriction page (tab) of the dialog (MCTBC_DP row + its items).
class SapValueHelpPage {
  const SapValueHelpPage({
    required this.id,
    this.tabControl = '1',
    this.title = '',
    this.searchHelp = '',
    this.selected = false,
    this.items = const [],
  });

  /// DIALOGNR — EVENTID 2's PID 0 and EVENTID 8's PID 1.
  final String id;

  /// TABCTRL — EVENTID 8's PID 0.
  final String tabControl;
  final String title;

  /// The elementary search help the page runs (SHLP_NAME).
  final String searchHelp;

  /// MC_ID `S`: the page the server pre-selected.
  final bool selected;

  /// Every item of the page, in push order.
  final List<SapValueHelpItem> items;

  /// The restriction inputs (X and pre-filled `4` items), labelled.
  List<SapValueHelpItem> get fields => [
    for (final i in items)
      if (i.isInput) i,
  ];

  List<SapValueHelpItem> get buttons => [
    for (final i in items)
      if (i.type == 'B') i,
  ];

  /// The max-hits item (its text is the count), null when none.
  SapValueHelpItem? get maxHits {
    for (final i in items) {
      if (i.type == 'E') return i;
    }
    return null;
  }

  /// The input a restriction key names: its item id, its FIELDNAME or its
  /// label (case-insensitive); null when none.
  SapValueHelpItem? field(String key) {
    final k = key.trim();
    for (final f in fields) {
      if (f.id == k) return f;
    }
    for (final f in fields) {
      if (f.fieldName.toUpperCase() == k.toUpperCase() ||
          (f.label.isNotEmpty && f.label.toLowerCase() == k.toLowerCase())) {
        return f;
      }
    }
    return null;
  }

  @override
  String toString() =>
      'SapValueHelpPage($id "$title" $searchHelp, '
      '${fields.length} fields)';
}

/// One hit-list column (mctbc_coln row).
class SapValueHelpColumn {
  const SapValueHelpColumn({
    required this.fieldName,
    this.title = '',
    this.mediumTitle = '',
    this.longTitle = '',
    this.appearance = '',
  });
  final String fieldName;

  /// SCRTEXT — the short heading the OCX shows by default.
  final String title;
  final String mediumTitle;
  final String longTitle;

  /// APPEARANCE (`H` on the key column of the SU53 hit list).
  final String appearance;

  @override
  String toString() => 'SapValueHelpColumn($fieldName "$title")';
}

/// One select-option row (DDSHSELOPT / DDSHSELOPTEX): a pushed pre-fill
/// or a restriction the search uploads.
class SapValueHelpSelectOption {
  const SapValueHelpSelectOption({
    required this.name,
    required this.field,
    this.sign = 'I',
    this.option = '',
    this.low = '',
    this.high = '',
  });

  /// SHLPNAME — the page on a pushed pre-fill, the frontend's user token
  /// on an upload.
  final String name;

  /// SHLPFIELD — the input item's id.
  final String field;
  final String sign;
  final String option;
  final String low;
  final String high;

  @override
  String toString() =>
      '$name/$field $sign ${option.isEmpty ? '--' : option} '
      '$low${high.isEmpty ? '' : '..$high'}';
}

/// The value-help dialog of one SAP.TABControl.1, as its pushes built it.
class SapValueHelpDialog {
  SapValueHelpDialog({
    required this.shell,
    this.title = '',
    this.pages = const [],
    this.activePageId,
    this.messages = const {},
    this.selectOptions = const [],
    this.resultColumns = const [],
    this.resultFields = const [],
    this.resultRows = const [],
    this.keyField,
    this.resultSearchField,
    this.statusLine,
    this.searchField,
  });

  /// The control's kernel shell id — every event targets it.
  final String shell;

  /// The dialog's caption (`createTab`; f4_modes: "Nom d'utilisateur dans
  /// la fiche utilisateur (1)").
  final String title;

  /// The restriction pages, in push order (empty on a result-only hit
  /// list).
  final List<SapValueHelpPage> pages;

  /// The page shown: the one the session activated, else the server's
  /// `setActivePage`, else the MC_ID `S` page, else the first.
  final String? activePageId;

  /// The OCX's own texts (M_NUMBER -> MESSAGE).
  final Map<int, String> messages;

  /// The pushed pre-fill (`setSelOpts`), usually empty.
  final List<SapValueHelpSelectOption> selectOptions;

  /// The hit-list columns' headings (`setResultTableCols`).
  final List<SapValueHelpColumn> resultColumns;

  /// The hit list's own columns (its structure's fields, e.g. P_USER_ADDR
  /// BNAME | MC_NAMELAS | …) — [resultRows] cells are in this order.
  final List<String> resultFields;

  /// The hit list, row i = wire row i + 1 (the pick's PID 0).
  final List<List<String>> resultRows;

  /// The hit-list column whose value the pick exports (its PID 2) — the
  /// column the server named with `setSearchField`, else the one
  /// `setResultTableCols` marks APPEARANCE `H`, else `createResultDialog`
  /// #3, else the first: the real GUI picks ME51N's material by MATNR
  /// (a recorded session gui[20]: `900557`; setSearchField MATNR, MATNR the
  /// `H` column) although createResultDialog names MAKTG (srv[25]); a hit
  /// list without named columns (F0001 …) is keyed by the `H` column's
  /// position (gui[31] / [41]: `BTE` / `1010`, the first column). Null
  /// before a hit list arrived.
  final String? keyField;

  /// The column `createResultDialog` named (its #3: BNAME on SU53, MAKTG
  /// on the material help, empty on a hit list pushed with the creation
  /// wave).
  final String? resultSearchField;

  /// The status line the server set (`setSearchResultStatusLine`: "Il y a
  /// plus de 500 entrées possibles").
  final String? statusLine;

  /// The search field the server named (`setSearchField`).
  final String? searchField;

  SapValueHelpPage? get activePage {
    if (pages.isEmpty) return null;
    for (final p in pages) {
      if (p.id == activePageId) return p;
    }
    for (final p in pages) {
      if (p.selected) return p;
    }
    return pages.first;
  }

  /// No restriction page was pushed: a hit list to pick from only (the
  /// SE80 object-selector list, a recorded session S46) — its pick
  /// carries no key value (G48).
  bool get resultOnly => pages.isEmpty;

  bool get hasResults => resultRows.isNotEmpty;

  /// The index of [keyField] in [resultFields] (0 when none).
  int get keyColumn {
    final k = keyField;
    if (k != null) {
      final i = resultFields.indexOf(k);
      if (i >= 0) return i;
    }
    return 0;
  }

  /// The key value of hit-list row [row] (1-based).
  String keyOf(int row) {
    final r = resultRows[row - 1];
    final c = keyColumn;
    return c < r.length ? r[c] : '';
  }

  /// The 1-based hit-list row whose key column — else, when unambiguous,
  /// any column — holds [value] (the reference client's find_result_row); null when
  /// none or several match.
  int? rowOf(String value) {
    final v = value.trim();
    for (var i = 0; i < resultRows.length; i++) {
      if (keyOf(i + 1).trim() == v) return i + 1;
    }
    int? hit;
    for (var i = 0; i < resultRows.length; i++) {
      if (resultRows[i].any((c) => c.trim() == v)) {
        if (hit != null) return null;
        hit = i + 1;
      }
    }
    return hit;
  }

  @override
  String toString() =>
      'SapValueHelpDialog($shell "$title" '
      '${pages.length} pages, ${resultRows.length} hits)';
}

/// The per-shell state the pushes accumulate.
class _Dlg {
  _Dlg(this.shell, this.seq, this.base);
  final String shell;
  final int seq;

  /// The base program the dialog was created over (screen generation).
  final String? base;
  bool closed = false;
  String title = '';
  String? activePage;
  String? statusLine;
  String? searchField;
  final Map<String, DpTable> tables = {};
  SapValueHelpDialog? model;
}

/// The TABControl's own verbs (WDTMCTRL.OCX's dispatch names on the wire):
/// a queue calling one of them on an object token names a value-help
/// dialog.
const Set<String> _ownVerbs = {
  'setMessages',
  'setHomeDynpro',
  'onlyOnDynpro',
  'enableTabCtl',
  'SetPVLSupport',
  'SetMCCLight',
  'searchResult',
  'setDialogPages',
  'setDialogItems',
  'setSelOpts',
  'createTab',
  'setActivePage',
  'setSearchField',
  'seteditstyle',
  'setResultTableCols',
  'setSearchHelpUsed',
  'createResultDialog',
  'resulttableSetTopRow',
  'setSearchHelpMode',
  'setSearchResultStatusLine',
  'destroyTab',
  'getSelectOptions',
};

/// Every SAP.TABControl.1 of the session, folded call by call.
class SapValueHelpTracker {
  final Map<String, _Dlg> _dialogs = {};
  final Map<String, String> _ownerShell = {};
  int _seq = 0;

  /// The dialog the newest `getSelectOptions` ran on — its select-options
  /// data object is saved (`SaveDataToUrl`) in a LATER queue (f4_modes
  /// srv[32] then srv[33]), so the pairing is queue order.
  String? _selOptsPending;

  /// SAPR3 sink -> the dialog whose select options were saved there.
  final Map<String, String> _selOptSinks = {};

  /// Fold one complete flush call. [shellOf] = the session alias (object
  /// token -> kernel shell); [base] = the program of the screen the dialog
  /// opens over. Returns the shells whose model changed.
  Set<String> foldCall(
    FlushCall call,
    Uint8List rfc, {
    String? Function(String token)? shellOf,
    String? base,
  }) {
    final touched = <String>{};
    final meta = verbMeta(call);
    final rowShell = <String, String>{}; // CreateControl result row -> shell
    for (var i = 1; i <= call.verbs.length; i++) {
      final verb = call.verbs[i - 1];
      final m = meta[i - 1];
      final args = verbNamedArgs(call, i);
      if (verb.startsWith('CreateControl')) {
        final sh = (args['#1'] ?? '').trim();
        final cls = (args['#2'] ?? '').trim();
        if (valueHelpClassRx.hasMatch(cls) && _digits.hasMatch(sh)) {
          // a reused shell id is a new dialog (the amodal display mode
          // reuses one shell across F4s: a recorded session)
          _ownerShell.removeWhere((_, s) => s == sh);
          _dialogs.remove(sh);
          _dialogs[sh] = _Dlg(sh, _seq++, base);
          final res = m.result?.trim() ?? '';
          if (res.isNotEmpty) rowShell[res] = sh;
          touched.add(sh);
        }
        continue;
      }
      if (verb == 'DestroyWindow') {
        final d = _dialogs[(args['#1'] ?? '').trim()];
        if (d != null && !d.closed) {
          d.closed = true;
          touched.add(d.shell);
        }
        continue;
      }
      if (verb == 'FreeObject') {
        // the token is released: a later dialog's object may reuse it
        final t = (args['#1'] ?? '').trim();
        final sh = _ownerShell[t];
        if (sh != null && (_dialogs[sh]?.closed ?? true)) _ownerShell.remove(t);
        continue;
      }
      if (!_ownVerbs.contains(verb)) continue;
      final d = _dialogOf(m, rowShell, shellOf);
      if (d == null) continue;
      touched.add(d.shell);
      String arg(String k) => _text(args[k] ?? '');
      switch (verb) {
        case 'createTab':
          d.title = arg('#1').trim();
        case 'setActivePage':
          d.activePage = arg('#1').trim();
        case 'setSearchResultStatusLine':
          d.statusLine = arg('#1').trim();
        case 'setSearchField':
          d.searchField = arg('#1').trim();
        case 'destroyTab':
          d.closed = true;
        case 'getSelectOptions':
          _selOptsPending = d.shell;
      }
      d.model = null;
    }
    // the save of the select-options object armed by an earlier queue
    final pend = _selOptsPending;
    if (pend != null && call.verbs.contains('SaveDataToUrl')) {
      for (var i = 1; i <= call.verbs.length; i++) {
        if (call.verbs[i - 1] != 'SaveDataToUrl') continue;
        final u = (verbNamedArgs(call, i)['#3'] ?? '').trim();
        if (u.startsWith('SAPR3://')) {
          _selOptSinks[u] = pend;
          _selOptsPending = null;
        }
      }
    }
    // the model pushes, by role
    final bindings = [
      for (final b in dpPushBindings(call))
        if (b.cls == 'TabControl' && b.role != null) b,
    ];
    if (bindings.isEmpty) return touched;
    final cache = DpCache()..ingestValue(rfc);
    for (final b in bindings) {
      final sh = b.shell ?? _shellOfToken(b.owner, shellOf);
      final d = sh == null ? null : _dialogs[sh];
      if (d == null) continue;
      for (final u in b.urls) {
        final seg = cache.byUrl[u];
        final t = seg == null ? null : _decodeTable(seg);
        if (t == null || t.columns.isEmpty) continue;
        d.tables[b.role!] = t;
        if (b.role == 'createResultDialog') {
          d.tables['_key:${(b.field ?? '').trim()}'] = t;
        }
      }
      d.model = null;
      touched.add(d.shell);
    }
    return touched;
  }

  /// The dialog whose select options were saved under [url] (consumed).
  String? takeSelectOptionsSink(String url) => _selOptSinks.remove(url);

  /// Whether [url] is a value-help select-options sink.
  bool isSelectOptionsSink(String url) => _selOptSinks.containsKey(url);

  /// The page the session activated on [shell] (EVENTID 8).
  void activatePage(String shell, String page) {
    final d = _dialogs[shell];
    if (d == null) return;
    d.activePage = page;
    d.model = null;
  }

  /// The dialog a pick / close dismissed (the server's teardown follows).
  void dismissed(String shell) => _dialogs[shell]?.closed = true;

  /// Every open dialog with a model, newest first. [isLive] = the session's
  /// control liveness; [base] = the current base program (a dialog created
  /// over another program was abandoned without its teardown — `/n` ends
  /// the program that hosted it).
  List<SapValueHelpDialog> dialogs({
    bool Function(String shell)? isLive,
    String? base,
  }) {
    final out = <SapValueHelpDialog>[];
    final all = _dialogs.values.toList()
      ..sort((a, b) => b.seq.compareTo(a.seq));
    for (final d in all) {
      if (d.closed) continue;
      if (isLive != null && !isLive(d.shell)) continue;
      if (base != null && d.base != null && d.base != base) continue;
      final m = d.model ??= _build(d);
      if (m == null) continue;
      out.add(m);
    }
    return out;
  }

  _Dlg? _dialogOf(
    VerbMeta m,
    Map<String, String> rowShell,
    String? Function(String)? shellOf,
  ) {
    final sh = rowShell[m.obj.trim()] ?? _shellOfToken(m.objValue, shellOf);
    return sh == null ? null : _dialogs[sh];
  }

  String? _shellOfToken(String? token, String? Function(String)? shellOf) {
    final t = token?.trim() ?? '';
    if (!_digits.hasMatch(t)) return null;
    final alias = shellOf?.call(t);
    if (alias != null && _dialogs.containsKey(alias)) {
      _ownerShell[t] = alias;
      return alias;
    }
    final known = _ownerShell[t];
    if (known != null && _dialogs.containsKey(known)) return known;
    // a token no alias names (a queue recorded from another frontend):
    // the newest open dialog no token is bound to yet
    final bound = _ownerShell.values.toSet();
    final free =
        _dialogs.values
            .where((d) => !d.closed && !bound.contains(d.shell))
            .toList()
          ..sort((a, b) => b.seq.compareTo(a.seq));
    if (free.isEmpty) return null;
    _ownerShell[t] = free.first.shell;
    return free.first.shell;
  }
}

final RegExp _digits = RegExp(r'^\d+$');

/// A push decoded by its FORMAT: [decodeNamedDpTable], else — a hit list
/// whose FORMAT names no structure, only the columns (prefilled srv[23]:
/// `F0001` … `F0008` over a 4000-byte DATAASC record, the Division hit
/// list) — the same read with the record width the DATAASC declares.
DpTable? _decodeTable(Uint8List seg) {
  final named = decodeNamedDpTable(seg);
  if (named != null) return named;
  final (_, (fw, fn), fcells) = dpColumnCells(seg, 'FORMAT');
  final fmt = _join(fcells);
  if (fw != 80 || fn <= 0 || fmt.length < fw * fn) return null;
  final bd = ByteData.sublistView(fmt);
  final cols = <(String, int, int, int)>[];
  for (var i = 0; i < fn; i++) {
    final o = i * fw;
    final name = String.fromCharCodes(fmt, o + 30, o + 60).trim();
    if (name.isEmpty) return null;
    cols.add((
      name,
      bd.getUint32(o + 64, Endian.little),
      bd.getUint32(o + 68, Endian.little),
      bd.getUint32(o + 76, Endian.little),
    ));
  }
  final (_, (dw, dn), dcells) = dpColumnCells(seg, 'DATAASC');
  final data = _join(dcells);
  final rows = <Map<String, String>>[];
  for (var r = 0; dw > 0 && r < dn && (r + 1) * dw <= data.length; r++) {
    final rec = Uint8List.sublistView(data, r * dw, (r + 1) * dw);
    rows.add({
      for (final (name, off, len, type) in cols)
        name: _cell(rec, off, len, type),
    });
  }
  return DpTable(
    '',
    [for (final c in cols) c.$1],
    rows,
    lengths: [for (final c in cols) c.$3],
    types: [for (final c in cols) c.$4],
  );
}

String _cell(Uint8List rec, int off, int len, int type) {
  if (off >= rec.length) return '';
  final end = off + len > rec.length ? rec.length : off + len;
  final raw = Uint8List.sublistView(rec, off, end);
  if (type == 0x49 && raw.length >= 4) {
    return ByteData.sublistView(raw).getInt32(0, Endian.little).toString();
  }
  var n = raw.length;
  while (n > 0 && (raw[n - 1] == 0 || raw[n - 1] == 0x20)) {
    n--;
  }
  return utf8.decode(Uint8List.sublistView(raw, 0, n), allowMalformed: true);
}

Uint8List _join(List<Uint8List> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

/// A verb argument decoded to text: the flush parse reads it in the
/// session codepage already (svars.dart [Rec.valueText]); one still read
/// one byte per code unit is re-read as UTF-8 when it is valid UTF-8, and
/// kept as it is otherwise (the reference client's ea_flushcall.arg_text).
String _text(String s) {
  if (s.codeUnits.any((c) => c > 0xff)) return s;
  try {
    return utf8.decode(latin1.encode(s));
  } on FormatException {
    return s;
  }
}

/// The pick's key column (see [SapValueHelpDialog.keyField]).
String? _keyField(
  List<String> fields,
  String? searchField,
  DpTable? cols,
  String? createKey,
) {
  if (fields.isEmpty) return null;
  if (searchField != null && fields.contains(searchField)) return searchField;
  final heads = cols?.rows ?? const <Map<String, String>>[];
  for (var i = 0; i < heads.length; i++) {
    if ((heads[i]['APPEARANCE'] ?? '').trim().toUpperCase() != 'H') continue;
    final name = (heads[i]['FIELDNAME'] ?? '').trim();
    if (fields.contains(name)) return name;
    if (i < fields.length) return fields[i];
  }
  if (createKey != null && fields.contains(createKey)) return createKey;
  return fields.first;
}

SapValueHelpDialog? _build(_Dlg d) {
  final pagesT = d.tables['setDialogPages'];
  final itemsT = d.tables['setDialogItems'];
  final colsT = d.tables['setResultTableCols'];
  final rowsT = d.tables['createResultDialog'];
  if (pagesT == null && itemsT == null && colsT == null && rowsT == null) {
    return null; // created, its model not delivered yet
  }
  String v(Map<String, String> r, String c) => (r[c] ?? '').trim();
  int n(Map<String, String> r, String c) => int.tryParse(v(r, c)) ?? 0;

  // items by page, labels joined to inputs by their row (POS_Y)
  final byPage = <String, List<Map<String, String>>>{};
  for (final r in itemsT?.rows ?? const <Map<String, String>>[]) {
    (byPage[v(r, 'DIALOGNR')] ??= []).add(r);
  }
  List<SapValueHelpItem> itemsOf(String page) {
    final rows = byPage[page] ?? const [];
    final labels = <int, String>{};
    for (final r in rows) {
      if (v(r, 'TYPE').toUpperCase() == 'T') {
        labels.putIfAbsent(n(r, 'POS_Y'), () => v(r, 'TEXT'));
      }
    }
    return [
      for (final r in rows)
        SapValueHelpItem(
          id: v(r, 'ID'),
          type: v(r, 'TYPE').toUpperCase(),
          page: page,
          text: v(r, 'TEXT'),
          label: const {'B', 'T', 'E'}.contains(v(r, 'TYPE').toUpperCase())
              ? ''
              : labels[n(r, 'POS_Y')] ?? '',
          fieldName: v(r, 'FIELDNAME'),
          icon: v(r, 'ICON'),
          x: n(r, 'POS_X'),
          y: n(r, 'POS_Y'),
          width: n(r, 'SIZE_X'),
          height: n(r, 'SIZE_Y'),
          tabControl: v(r, 'TABCTRL'),
        ),
    ];
  }

  final pages = <SapValueHelpPage>[
    for (final r in pagesT?.rows ?? const <Map<String, String>>[])
      SapValueHelpPage(
        id: v(r, 'DIALOGNR'),
        tabControl: v(r, 'TABCTRL'),
        title: v(r, 'TITLE'),
        searchHelp: v(r, 'SHLP_NAME'),
        selected: v(r, 'MC_ID').toUpperCase() == 'S',
        items: itemsOf(v(r, 'DIALOGNR')),
      ),
  ];
  // items pushed without a page table: one page per DIALOGNR
  if (pages.isEmpty && byPage.isNotEmpty) {
    for (final p in byPage.keys) {
      pages.add(
        SapValueHelpPage(
          id: p,
          tabControl: v(byPage[p]!.first, 'TABCTRL'),
          items: itemsOf(p),
        ),
      );
    }
  }
  final keyEntry = d.tables.keys.where((k) => k.startsWith('_key:')).lastOrNull;
  final key = keyEntry?.substring(5);
  final fields = rowsT?.columns ?? const <String>[];
  return SapValueHelpDialog(
    shell: d.shell,
    title: d.title,
    pages: List.unmodifiable(pages),
    activePageId: d.activePage,
    messages: {
      for (final r
          in d.tables['setMessages']?.rows ?? const <Map<String, String>>[])
        n(r, 'M_NUMBER'): v(r, 'MESSAGE'),
    },
    selectOptions: [
      for (final r
          in d.tables['setSelOpts']?.rows ?? const <Map<String, String>>[])
        SapValueHelpSelectOption(
          name: v(r, 'SHLPNAME'),
          field: v(r, 'SHLPFIELD'),
          sign: v(r, 'SIGN'),
          option: v(r, 'OPTION'),
          low: v(r, 'LOW'),
          high: v(r, 'HIGH'),
        ),
    ],
    resultColumns: [
      for (final r in colsT?.rows ?? const <Map<String, String>>[])
        SapValueHelpColumn(
          fieldName: v(r, 'FIELDNAME'),
          title: v(r, 'SCRTEXT'),
          mediumTitle: v(r, 'SCRTEXT_M'),
          longTitle: v(r, 'SCRTEXT_L'),
          appearance: v(r, 'APPEARANCE'),
        ),
    ],
    resultFields: List.unmodifiable(fields),
    resultRows: [
      for (final r in rowsT?.rows ?? const <Map<String, String>>[])
        [for (final c in fields) v(r, c)],
    ],
    keyField: _keyField(fields, d.searchField, colsT, key),
    resultSearchField: key == null || key.isEmpty ? null : key,
    statusLine: d.statusLine,
    searchField: d.searchField,
  );
}
