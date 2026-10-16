/// Dynpro screen model: fold received frames latest-wins into what the UI
/// renders (screen_model/screen_atoms port, UI-relevant subset).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../codepages.dart';
import '../framing/diag_frame.dart';
import '../framing/envelope.dart';
import '../items/dynt_atom.dart';
import 'field_routing.dart';
import 'listbox_valueset.dart';
import 'menu_entries.dart';
import 'sap_netplan.dart';
import 'table_controls.dart';
import 'type_ahead.dart' show xmlpropArmsTypeAhead;

export 'field_routing.dart' show FieldRouting;
export 'menu_entries.dart';
export 'table_controls.dart' show TableControlInfo, TcPlaneItem, tcRoutingSids;

enum FieldKind {
  input,
  output,
  label,
  checkbox,
  radio,
  pushbutton,
  tabstrip,
  combobox,
}

class ScreenField {
  ScreenField({
    required this.kind,
    required this.row,
    required this.col,
    this.name,
    this.text = '',
    this.label = '',
    this.mlen = 0,
    this.maxnrchars = 0,
    this.on = false,
    this.fcode,
    this.invisible = false,
    this.isProtected = false,
    this.area = 0,
    this.block = 0,
    this.group = 0,
    this.dlg1 = 0,
    this.dlg2 = 0,
    this.pageId,
    this.attr = 0,
    int? wireRow,
    int? wireCol,
    this.container,
    this.tableControl,
    this.tcLine,
    this.tcColumn,
  }) : wireRow = wireRow ?? row,
       wireCol = wireCol ?? col;

  FieldKind kind;

  /// The field's ABSOLUTE cell in its window (0-based): every enclosing
  /// container's origin applied (subscreen / AREA / tabstrip / table
  /// control). For a modal popup it is relative to the POPUP's own client
  /// area (the SES x/y position places the popup on the screen), never to
  /// the covered base screen. Layout and rendering use these.
  int row;
  int col;

  /// The cell the KERNEL addresses the field by: the wire atom's
  /// container-local row/col (equal to [row]/[col] outside containers).
  /// Value submits (`fillItems`, `radioSelectItems`) must send these — the
  /// reference client keeps the wire row/col for its write primitives and carries
  /// the absolute cell beside it (engine/screen_model_fold._fold_atoms).
  /// A table-control cell has no atom: it is written by (tableControl,
  /// tcLine, tcColumn), and its wire cell is its absolute cell.
  int wireRow;
  int wireCol;

  /// The innermost declared container the field is painted in (16/10/6
  /// NAME), null at the window's root.
  String? container;

  /// Set on table-control cells: the control's name (e.g. `SINGLE`).
  String? tableControl;

  /// Set on table-control cells: the 1-based VISIBLE line of the control.
  int? tcLine;

  /// Set on table-control cells: the 1-based column-catalog index (the
  /// selector column not counted) — the 16/9/11 focus column of a cell.
  int? tcColumn;
  String? name; // FNAME (e.g. RSYST-BNAME)
  String text; // value / button text
  String label; // paired label text (left of the field)
  int mlen;
  int maxnrchars;
  bool on; // checkbox/radio state
  String? fcode; // pushbutton/tabstrip function code
  bool invisible;
  bool isProtected;
  int area;
  int block;
  int group;
  int dlg1;
  int dlg2;
  int? pageId; // tabstrip page
  int attr; // the painted atom's attribute byte (echoed on a value submit)

  /// The container plane a value write into this field travels (a field
  /// on a tabstrip page / in a nested subscreen chain), null on the
  /// window root (the flat write) — see [FieldRouting].
  FieldRouting? routing;

  /// The field offers value help (F4): an atom of its cell carries the
  /// MATCHCODE bit (0x10), or the F4-button COMBOSTYLE bit (0x80) on a cell
  /// that is no listbox (etype 126) — reference client screen_atoms `f4`.
  bool hasF4 = false;

  /// A dropdown LISTBOX (etype 126): its value-set id, function code,
  /// with-key flag and painted KEY ([text] is the key); null otherwise.
  ListboxAtom? listbox;

  /// The field is armed for TYPE-AHEAD (server proposals while typing):
  /// the etype-120 XMLPROP property bag of its cell carries
  /// `<CustomProperty typeahead="X"/>` (screen/type_ahead.dart; reference client
  /// screen_atoms._propertybag -> `typeahead`).
  bool typeAhead = false;
}

/// One non-blank line of a classic ABAP list (a report, an F4 hit list in
/// a popup — SAPMSSY0/0120): its BUFFER row (the list-pick line), its first
/// painted column, the text from there (box-drawing runs rendered as
/// glyphs) and the column a pick's cursor goes to — the line's first data
/// column past its frame rail and blanks (reference client screen_listscreen
/// _parse_list_lines + raw_listpick._list_hotspot_col).
///
/// [segments] are the line's painted runs with their SFE attributes
/// ([ListSegment]); a line built without them (a test, a caller) reads as
/// one plain segment of [text].
class ListLine {
  ListLine(this.line, this.col0, this.text, [List<ListSegment>? segments])
      : segments = segments ?? [ListSegment(col0, text)];
  final int line;
  final int col0;
  final String text;

  /// The painted runs, left to right, with their attributes: frame rails,
  /// coloured text bands, icons, input / checkbox cells (the gaps between
  /// them are unpainted columns).
  final List<ListSegment> segments;

  /// A rule line: every painted cell is a frame glyph or blank, no icon,
  /// no input cell (the box's top, a header separator, its bottom, a blank
  /// row) — painted, never picked.
  bool get isRule =>
      segments.every((s) => s.icon == null && !s.input) &&
      text.codeUnits
          .every((c) => c == 0x20 || _listFrameGlyphUnits.contains(c));

  /// The input cells of the line (`WRITE … INPUT`, `AS CHECKBOX`).
  Iterable<ListSegment> get inputs => segments.where((s) => s.input);

  /// The line is painted in COL_TOTAL (SFE colour 3) throughout: every
  /// coloured run that is no box line is colour 3 — how the list processor
  /// paints a SELECTED line (F9 / block select F6 on SAPMSSY0/0120: the
  /// line's data runs `0a 02 00` / `08 02 00` repainted `0a 03 00` /
  /// `08 03 00`, attribute and extension kept, the `08 00 08` box runs
  /// untouched — a recorded session s22..24).
  /// The mark is the server's: no round carries it, every repaint of the
  /// window recolours the selected lines inside it, so it is read from
  /// each paint afresh, never kept.
  bool get highlighted {
    var any = false;
    for (final s in segments) {
      if (s.frame || s.color == 0) continue;
      if (s.color != 3) return false;
      any = true;
    }
    return any;
  }

  int get hotspotCol {
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch != ' ' && !_listFrameGlyphs.contains(ch)) {
        final c = col0 + i;
        // a ticked checkbox is no data column: the pick aims past it
        if (segments.any((s) => s.checkbox && s.covers(c))) continue;
        return c;
      }
    }
    for (final s in segments) {
      if (s.icon != null) return s.col; // an icon-only line: the icon
    }
    return col0;
  }

  @override
  String toString() => 'ListLine($line@$col0 "$text")';
}

/// One painted run of a classic list line: its buffer column, its DISPLAY
/// text (icon / quick-info tokens resolved, the line-element font as box
/// glyphs) and the run's SFE triple (item type 10: attribute, colour,
/// extension), byte-pinned on SHOWCOLO (SAPMSSY0/0120, every colour x
/// INTENSIFIED / INTENSIFIED OFF / INVERSE / INPUT, a recorded session
/// trace srv_…_SAPMSSY0_28, kept as a recorded session) and the
/// SE38 where-used list (a recorded session srv[84], real Java GUI):
///
/// * attribute: 0x08 = protected (output only; clear = an INPUT cell, `00`
/// and `02` alike — SHOWCOLO's "INPUT" columns), 0x02 = INTENSIFIED;
/// * colour: the list colour 0..7 (COL_BACKGROUND, COL_HEADING, COL_NORMAL,
/// COL_TOTAL, COL_KEY, COL_POSITIVE, COL_NEGATIVE, COL_GROUP);
/// * extension: 0x01 = a CHECKBOX (the where-used "selection column" `00 00
/// 01` / `02 00 01`), 0x04 = HOTSPOT, 0x08 = the line-element (box) font,
/// 0x40 = INVERSE.
class ListSegment {
  ListSegment(this.col, this.text,
      {this.sfe = defaultSfe, this.icon, this.tip});

  /// The SFE of a run painted without one: protected, COL_BACKGROUND.
  static const int defaultSfe = 0x080000;

  final int col;
  final String text;

  /// The raw SFE triple, big-endian: attribute << 16 | colour << 8 | ext.
  final int sfe;

  /// The icon code of an icon run (`@3R\Q…@` -> `3R`), two cells wide.
  final String? icon;

  /// The run's quick info (`@\QNom de la table@…`), null without one.
  final String? tip;

  int get attribute => sfe >> 16 & 0xff;
  int get extension => sfe & 0xff;
  int get color => sfe >> 8 & 0x07;
  int get width => text.length;
  int get end => col + text.length;
  bool get intensified => attribute & 0x02 != 0;
  bool get input => attribute & 0x08 == 0;
  bool get checkbox => extension & 0x01 != 0;
  bool get hotspot => extension & 0x04 != 0;
  bool get frame => extension & 0x08 != 0;
  bool get inverse => extension & 0x40 != 0;

  /// A checkbox ticked in the paint (`X`).
  bool get checked => checkbox && text.trim().isNotEmpty;

  bool covers(int c) => c >= col && c < end;

  @override
  String toString() =>
      'ListSegment($col "${icon != null ? '@$icon@' : text}" '
      '${sfe.toRadixString(16).padLeft(6, '0')})';
}

/// The SAP line-element font (an SFE extension 0x08 run, `08 00 08`):
/// digit codes of the box-drawing frame a boxed list paints. Corners 0-3
/// (┌ └ ┐ ┘), the rules 4 / 5 (─ │), the tees 6-9 (├ ┤ ┴ ┬), the cross
/// `:` — byte-pinned on every closed box of the corpus: SHOWCOLO's
/// `0…2` top / `1…8…3` bottom / `6…:…7` separators, the where-used list's
/// `0…9…2` / `1…8…3` (a recorded session srv[7]). the reference client's
/// _SAP_LINE_FONT reads 1/3/6/7/8/9 differently (complaint-list-line-font).
const Map<String, String> _listLineFont = {
  '0': '┌', '1': '└', '2': '┐', '3': '┘', '4': '─', '5': '│',
  '6': '├', '7': '┤', '8': '┴', '9': '┬', ':': '┼',
};
final Set<String> _listFrameGlyphs = _listLineFont.values.toSet();

/// [_listLineFont] / [_listFrameGlyphs] by code unit (every glyph is one).
final Map<int, int> _listLineFontUnits = {
  for (final e in _listLineFont.entries)
    e.key.codeUnitAt(0): e.value.codeUnitAt(0),
};
final Set<int> _listFrameGlyphUnits = {
  for (final g in _listFrameGlyphs) g.codeUnitAt(0),
};

class ScreenFrame {
  ScreenFrame(this.row, this.col, this.drows, this.dcols, this.text);
  final int row;
  final int col;
  final int drows;
  final int dcols;
  final String text;
}

class FKey {
  FKey(this.vkey, this.text);
  final int vkey;
  final String text;
}

/// A declared container (16/10/<kind> geometry + 16/10/6 NAME) at its
/// ABSOLUTE window cell (reference client engine/diag_geometry._geom9 +
/// screen_model_fold._fold_path_marker).
class ScreenContainer {
  ScreenContainer(
    this.name,
    this.kind,
    this.row,
    this.col,
    this.width,
    this.height,
    this.localRow,
    this.localCol,
    this.parent, {
    this.program,
    this.dynpro,
  });
  final String name;

  /// 3 SUBSCREEN, 5 TABLE, 8 TABSTRIP, 9 TABSTRIP_PAGE, 10 CONTROL, 16 AREA
  /// (13/14 splitter levels).
  final int kind;
  final int row;
  final int col;
  final int width;
  final int height;

  /// The wire's origin, relative to [parent].
  final int localRow;
  final int localCol;
  final String? parent;

  /// The dynpro the 16/10/6 NAME names after the container's name
  /// (`NAME\0PROG\0DYNP`): for a subscreen area / splitter cell the
  /// subscreen dynpro it HOSTS, for an element the dynpro that defines it.
  /// The ABAP Debugger (a recorded session s[27]/s[28], RSTPDAMAIN
  /// /0100): `TPDAMAIN SAPLSTPDA_CARRIER 0100`, splitter `HOR
  /// SAPLSTPDA_CARRIER 0450`, its cell `LEFT SAPLSTPDA_TOOL_EDITOR 0100`
  /// (the source tool), `RIGHT SAPLSTPDA_CARRIER 0400`, `TOOL_BAR
  /// SAPLSTPDA_TOOLBAR 0100`. Null when the NAME carries none.
  final String? program;
  final String? dynpro;

  @override
  String toString() =>
      'ScreenContainer($name kind $kind r${row}c$col ${width}x$height)';
}

/// The kernel's logon program: the logon dynpro (0020), the multi-logon
/// wall, a remote logon's 0029 all paint under it.
const String kKernelLogonProgram = 'SAPMSYST';

/// The transaction code the logon screen reports (the logon dynpro before
/// any transaction runs).
const String kKernelLogonTcode = 'S000';

final RegExp _secretFieldName = RegExp(r'BCODE|PASSW|PWD', caseSensitive: false);

/// Whether [f] holds a secret: an invisible (password) input, or a field
/// named like one (a logon screen's BCODE, a PASSW* / PWD field) — its
/// value never reaches a trace (SapSession's staged fields) nor a stored
/// input history (the app's).
bool isSecretField(ScreenField f) =>
    f.invisible || _secretFieldName.hasMatch(f.name ?? '');

class ScreenModel {
  String? program;
  String? dynpro;
  String? tcode;

  /// Whether this screen is the kernel's logon program
  /// ([kKernelLogonProgram]): the logon, the multi-logon wall, a remote
  /// logon — never an application screen.
  bool get isKernelLogon =>
      (program ?? '').trim().toUpperCase() == kKernelLogonProgram;

  /// Whether this screen reports the logon transaction ([kKernelLogonTcode]).
  bool get isKernelLogonTcode =>
      (tcode ?? '').trim().toUpperCase() == kKernelLogonTcode;
  String? guiStatus;
  String title = '';
  String message = '';
  int messageSeverity = 0; // 0 none, 1 success, 2 info, 3 warning, 4 error
  int modalLevel = 0;

  /// The window's position on the screen in cells (SES y_pos / x_pos —
  /// the popup's origin; 0/0 for the main window) and its size (SES
  /// dim_row / dim_col). Every [ScreenField.row]/[ScreenField.col] of this
  /// model is relative to this window's own client area.
  int windowRow = 0;
  int windowCol = 0;
  int windowRows = 0;
  int windowCols = 0;
  final List<ScreenField> fields = [];
  final List<ScreenFrame> frames = [];
  final List<FKey> fkeys = [];

  /// The menu bar's top-level entries (18/11/1, entries with a text).
  /// Empty on a popup (its 18/11/1 packet is empty).
  final List<MenuEntry> menuBar = [];

  /// The dropdown entries (18/11/2 MNUENTRY), withheld on low-speed
  /// connections.
  final List<MenuEntry> menuTree = [];

  /// The application toolbar (18/11/3), separators dropped. A button's
  /// [MenuEntry.text] is usually its icon code (`@15@`) and its name the
  /// [MenuEntry.tooltip]; it fires by [MenuEntry.vkey].
  final List<MenuEntry> toolbar = [];

  /// The function-key table (18/11/4): entries with a vkey and a text.
  final List<MenuEntry> functionKeys = [];

  /// The classic table controls of this window, at absolute cells.
  final List<TableControlInfo> tableControls = [];

  /// The containers declared in this window's paint (16/10 path markers),
  /// by name, at absolute cells.
  final Map<String, ScreenContainer> containers = {};

  /// Every dynpro the paint's container NAMEs name ([ScreenContainer
  /// .program] / [ScreenContainer.dynpro]): the main dynpro's own elements
  /// and each subscreen it hosts — the ABAP Debugger's RSTPDAMAIN/0100
  /// hosts SAPLSTPDA_CARRIER 0100 / 0450 / 0400 / 0501 / 0700,
  /// SAPLSTPDA_TOOL_EDITOR 0100, SAPLSTPDA_TOOLBAR 0100, …
  /// (a recorded session s[27]/s[28]). A control LinkControl'ed to
  /// one of them shows on this screen.
  final Set<(String, String)> hostedDynpros = {};

  /// Whether a control LinkControl'ed to ([program], [dynpro]) is on this
  /// screen: the main dynpro, or a subscreen the paint hosts.
  bool showsDynpro(String program, String dynpro) =>
      (program == this.program && dynpro == this.dynpro) ||
      hostedDynpros.contains((program, dynpro));

  /// The container PATH of every custom-control area this paint declares,
  /// by area name (`GRIDCONTROL`, …): the level bytes of the area's group
  /// legs (16/10/3 … 16/10/10, level 0 skipped) — what a control event on
  /// the control hosted there carries in its 16/15/1 (a recorded session
  /// srv[49]: GRIDCONTROL = SUB0 01, SUB2 03, SUB2 02, SUB1 01, CONTROL 01
  /// -> `01 03 02 01 01`, the path of gui[45]'s event source).
  final Map<String, List<int>> controlPaths = {};

  /// The network graphs this paint carried INLINE — the classic
  /// Basis-Graphik GRAPH item 16/2/5 (CNG9 / SAPLGRAP), decoded in the
  /// codepage the paint declared before it; empty on most screens.
  final List<SapNetPlanModel> netPlans = [];

  /// The inline GRAPH conversation on this screen ([InlineGraphStream]):
  /// the transmission the paint opened, extended by the continuation items
  /// of later frames until complete; null on every other screen and once
  /// the server closed the graph (`KNETZ`, cng9 srv[34]). Its
  /// [InlineGraphStream.kind] says what it carries: a network graph (parsed
  /// into [netPlans]) or a classic business / statistics graphic, whose
  /// joined [InlineGraphStream.bytes] are kept as received. The profile
  /// (INI) service on the same item never lands here.
  InlineGraphStream? inlineGraph;

  /// The classic ABAP list this window paints (empty on a dynpro): its
  /// pickable lines — no blank row, no frame rule.
  final List<ListLine> listLines = [];

  /// Every painted row of the list, the frame rules ([ListLine.isRule])
  /// included, by buffer row — what a renderer draws ([listLines] is the
  /// subset a pick can aim at, the same objects).
  final List<ListLine> listPaint = [];

  /// The list's 16/12/2 window: total lines, total cols, visible lines,
  /// visible cols, first line (u32 each) — null without a list.
  List<int>? listWindow;

  /// The list cursor the paint set — its 16/12/13 `01 <row u16> <col u16>`
  /// as (buffer row, column), the row a [ListLine.line]: null when the
  /// paint carries none (the server drops it once the cursor's line is
  /// scrolled out of the window — a recorded session
  /// _scroll s37..39 after Page Down) or paints no list.
  (int, int)? listCursor;

  /// The system that painted this window — ST_R3INFO 16/6/2 DBNAME (the
  /// system id), 16/6/3 CPUNAME (its application server) and 16/6/12
  /// CLIENT of the turn's frames (reference client diag_controlstate _R3INFO 2 / 3 /
  /// 12). A remote logon relayed from an RFC target names the TARGET here
  /// (a recorded session SAPMSYST_1 frame 2: `<SID2>`, `<host2>`,
  /// client `000` under the logon system's 200). Null when the turn named none (and no
  /// earlier paint of the window did).
  String? systemId;
  String? appServer;
  String? client;

  /// The SECONDARY logon this window asks for — the SAPMSYST/0029 dynpro a
  /// cross-system RFC paints mid-session (/SDF/TRCHECK, SE39's split
  /// compare, STMS on a virtual system): the target's system id, host and
  /// the client the logon proposes. reference client remote_login.detect: program
  /// SAPMSYST, the RSYST-MANDT / RSYST-BNAME / RSYST-BCODE inputs painted
  /// and editable, and a painted SYST-SYSID naming the target — the real
  /// 0020 logon paints none (a recorded session frame 1), the real
  /// 0029 does, read-only (a recorded session SAPMSYST_1: SYST-SYSID
  /// `<SID2>` r2 c58, SYST-HOST `<host2>` r3 c58, RSYST-MANDT `000`;
  /// a recorded session SAPMSYST_1: `<SID3>`, `<host3>`).
  /// Whether it names ANOTHER system than the logon's own is the session's
  /// call ([SapSession.remoteLogon]); null otherwise. The credentials are
  /// the user's to type: nothing here fills them.
  ({String sysid, String host, String client})? get remoteLogon {
    if (!isKernelLogon) return null;
    ScreenField? input(String name) {
      ScreenField? best;
      for (final f in fields) {
        if (f.name != name || f.kind != FieldKind.input) continue;
        if (best == null || f.col > best.col) best = f;
      }
      return best;
    }

    for (final n in const ['RSYST-MANDT', 'RSYST-BNAME', 'RSYST-BCODE']) {
      final f = input(n);
      if (f == null || f.isProtected) return null;
    }
    final sid = input('SYST-SYSID');
    if (sid == null || sid.text.trim().isEmpty) return null;
    return (
      sysid: sid.text.trim(),
      host: input('SYST-HOST')?.text.trim() ?? appServer ?? '',
      client: input('RSYST-MANDT')!.text.trim(),
    );
  }

  bool get isEmpty =>
      program == null && fields.isEmpty && title.isEmpty && message.isEmpty;
}

/// The last 16/6/2 / 16/6/3 / 16/6/12 values of [frames] (system id, app
/// server, client), each null when absent.
(String?, String?, String?) _systemOf(List<Uint8List> frames) {
  String? db, cpu, client;
  String text(Uint8List v) {
    var end = v.indexOf(0);
    if (end < 0) end = v.length;
    return wireDecode(Uint8List.sublistView(v, 0, end)).trim();
  }

  for (final f in frames) {
    final dec = decompressFrame(f);
    if (dec == null) continue;
    for (final it in dec.walk.items) {
      if (!it.isAppl || it.id != applStR3Info) continue;
      if (it.sid == 2) db = text(it.value);
      if (it.sid == 3) cpu = text(it.value);
      if (it.sid == 12) client = text(it.value);
    }
  }
  return (db, cpu, client);
}

/// One SES window segment: the SES that opens it plus every item that
/// follows it in the turn's ordered item stream.
class _WindowSegment {
  _WindowSegment(this.modalNo);
  final int? modalNo; // null = items before any SES (continuation)
  Uint8List? ses; // the latest SES value of this window

  /// Whether one of the segment's SES announced a NEW screen (not a delta
  /// paint — [sesIsDeltaPaint]): the segment then repaints the window.
  bool newScreen = false;
  final List<DiagItem> items = [];

  /// Indexes into [items] where a new frame's items start: the container
  /// path (16/10 markers) is a per-frame local (reference client
  /// screen_model_fold.fold_frame).
  final Set<int> frameStarts = {};
}

/// The windows a turn paints: the ACTIVE window (the one the last SES
/// opened — a popup when its modal level is > 0) and, when it covers one,
/// the BASE window behind it.
class WindowedFold {
  WindowedFold(this.active, this.coveredBase);
  final ScreenModel active;
  final ScreenModel? coveredBase;
}

/// Fold a turn's frames into windows (the engine's `_last_ses` rule: a
/// paint that opens a popup carries the covered window's items first and
/// the popup's after its own SES — the value after the LAST SES names the
/// active window). Each window's fields come from ITS items only, so a
/// popup never absorbs the screen behind it.
WindowedFold foldWindows(
  ScreenModel? previousBase,
  ScreenModel? previousActive,
  List<Uint8List> frames,
) {
  final segments = <_WindowSegment>[_WindowSegment(null)];
  for (final f in frames) {
    final dec = decompressFrame(f);
    if (dec == null) continue;
    segments.last.frameStarts.add(segments.last.items.length);
    for (final it in dec.walk.items) {
      if (it.type == itemSes && it.value.length >= 8) {
        final lvl = it.value[7];
        // a later frame at the SAME level repaints the same window —
        // merge (latest wins per cell); a level CHANGE opens a new one
        final fresh = !sesIsDeltaPaint(it.value);
        if (segments.last.modalNo == lvl) {
          segments.last
            ..ses = it.value
            ..newScreen |= fresh;
          continue;
        }
        segments.add(
          _WindowSegment(lvl)
            ..frameStarts.add(0)
            ..ses = it.value
            ..newScreen = fresh,
        );
      } else {
        segments.last.items.add(it);
      }
    }
  }

  final activeSeg = segments.last;
  final activeModal =
      activeSeg.modalNo ??
      (previousActive != null && previousActive.modalLevel > 0
          ? previousActive.modalLevel
          : 0);

  // the covered base: the latest earlier segment at a LOWER modal level
  _WindowSegment? baseSeg;
  if (activeModal > 0) {
    for (var i = segments.length - 2; i >= 0; i--) {
      final lvl = segments[i].modalNo;
      if (lvl != null && lvl < activeModal) {
        baseSeg = segments[i];
        break;
      }
    }
  }

  // what the ACTIVE window resumes from: a popup repaint at the same level
  // carries itself; a level-0 paint after a popup resumes the COVERED base —
  // never the popup, whose title/program must not bleed into the base (the
  // stale "Info licence…" title over an empty Easy Access after the wall
  // was answered).
  final ScreenModel? activeCarry;
  if (activeModal > 0) {
    activeCarry =
        previousActive != null && previousActive.modalLevel == activeModal
        ? previousActive // popup repaint at the same level
        : null; // popup first paint: no carry-over
  } else if (previousActive == null || previousActive.modalLevel == 0) {
    activeCarry = previousActive; // plain base repaint (or first paint)
  } else {
    activeCarry = previousBase != null && previousBase.modalLevel == 0
        ? previousBase // the popup closed: resume the window it covered
        : null;
  }
  final active = _foldSegment(activeCarry, activeSeg, activeModal);
  // the system rides ST_R3INFO ahead of the frame's SES (every frame): the
  // turn's, else the window's previous paint's
  final (db, cpu, client) = _systemOf(frames);
  void system(ScreenModel m, ScreenModel? carry) {
    m
      ..systemId = db ?? carry?.systemId
      ..appServer = cpu ?? carry?.appServer
      ..client = client ?? carry?.client;
  }

  system(active, activeCarry);

  if (baseSeg != null) {
    final base = _foldSegment(previousBase, baseSeg, baseSeg.modalNo ?? 0);
    system(base, previousBase);
    return WindowedFold(active, base);
  }
  // no base segment in this turn: the carried base stays covered
  if (activeModal > 0 && previousBase != null) {
    return WindowedFold(active, previousBase);
  }
  return WindowedFold(active, null);
}

ScreenModel _foldSegment(
  ScreenModel? previous,
  _WindowSegment seg,
  int modalLevel,
) {
  final m = ScreenModel();
  if (previous != null) {
    m.program = previous.program;
    m.dynpro = previous.dynpro;
    m.tcode = previous.tcode;
    m.guiStatus = previous.guiStatus;
    m.title = previous.title;
    // the status-bar message belongs to the dialog step that sent it: a
    // server paint (an SES) carries its 16/6/11 again when the message
    // still shows and none when it is gone — a recorded session raw
    // srv[95] (Easy Access answering the next search round) has none after
    // srv[93]'s "E: Transaction XYZ123 inexistante", and the real GUI
    // clears the bar. Only a frame that is no dialog step (an OLE flush, a
    // receipt: no SES) keeps it.
    if (seg.ses == null) {
      m.message = previous.message;
      m.messageSeverity = previous.messageSeverity;
    }
    // the menus / toolbar / keys are latest-wins per 18/11 sid: a repaint
    // that does not resend them keeps the previous paint's
    m.fkeys.addAll(previous.fkeys);
    m.menuBar.addAll(previous.menuBar);
    m.menuTree.addAll(previous.menuTree);
    m.toolbar.addAll(previous.toolbar);
    m.functionKeys.addAll(previous.functionKeys);
  }
  m.modalLevel = modalLevel;
  if (previous != null && previous.modalLevel == modalLevel) {
    m.windowRow = previous.windowRow;
    m.windowCol = previous.windowCol;
    m.windowRows = previous.windowRows;
    m.windowCols = previous.windowCols;
  }
  final ses = seg.ses;
  if (ses != null && ses.length >= 16) {
    // pysap SAPDiagSES: … modal_no[7] x_pos[8] y_pos[9] imode[10] flag_1[11]
    // padd u16[12] dim_row[14] dim_col[15] (reference client screen_model_fold:
    // modal_pos = {row: y_pos, col: x_pos})
    m.windowCol = ses[8];
    m.windowRow = ses[9];
    m.windowRows = ses[14];
    m.windowCols = ses[15];
  }
  final st = _FoldState()
    ..graph = previous != null && previous.modalLevel == modalLevel
        ? previous.inlineGraph
        : null;
  for (var i = 0; i < seg.items.length; i++) {
    if (seg.frameStarts.contains(i)) st.newFrame();
    final it = seg.items[i];
    switch (it.type) {
      case itemTit:
        if (it.value.isNotEmpty) m.title = wireDecode(it.value);
        break;
      case itemSba: // a list run's position: row = off >> 8, col = off & ff
        if (it.value.length >= 2) {
          st.listAt = (it.value[0], it.value[1]);
          st.listFont = null;
        }
        break;
      case itemSba2: // the same past column 255: u16 row, u16 col
        if (it.value.length >= 4) {
          st.listAt = (
            it.value[0] << 8 | it.value[1],
            it.value[2] << 8 | it.value[3],
          );
          st.listFont = null;
        }
        break;
      case itemSfe: // the run's font / format
        st.listFont = Uint8List.fromList(it.value);
        break;
      case itemAppl:
      case itemAppl4:
        _foldAppl(m, it, st);
        break;
      default:
        break;
    }
  }
  // a DELTA paint of the same dynpro (the SES screen flag's NEW-SCREEN bit
  // clear — [sesIsDeltaPaint]) updates the window in place: what it does
  // not repaint stays (an error message's paint resends only the inputs,
  // the type-ahead answer's paint nothing at all)
  final delta = previous != null &&
      previous.modalLevel == modalLevel &&
      ses != null &&
      !seg.newScreen &&
      m.program == previous.program &&
      m.dynpro == previous.dynpro;
  // a turn that paints nothing of the dynpro — no DYNT atom / container
  // item, no program / dynpro name (a flush or receipt after the paint,
  // ME21N's header-only end of turn), or a delta paint without a body —
  // keeps the window's painted fields (the reference client folds over the screen's
  // frames, it never empties them)
  if (previous != null &&
      previous.modalLevel == modalLevel &&
      (!seg.items.any(_paintsDynpro) ||
          (delta && !seg.items.any(_paintsBody)))) {
    m.fields.addAll(previous.fields);
    m.frames.addAll(previous.frames);
    m.tableControls.addAll(previous.tableControls);
    m.containers.addAll(previous.containers);
    m.hostedDynpros.addAll(previous.hostedDynpros);
    m.controlPaths.addAll(previous.controlPaths);
    // an inline graph this turn continued or closed is the turn's own
    m.netPlans.addAll(previous.netPlans
        .where((g) => !st.graphTouched || g.shell != null));
    if (!st.graphTouched) m.inlineGraph = previous.inlineGraph;
    m.listLines.addAll(previous.listLines);
    m.listPaint.addAll(previous.listPaint);
    m.listWindow = previous.listWindow;
    m.listCursor = previous.listCursor;
    return m;
  }
  _buildFields(m, st.atoms);
  _buildTableControls(m, st);
  _buildListLines(m, st);
  m.containers.addAll(st.path.declared);
  m.hostedDynpros.addAll(st.path.dynpros);
  if (delta) _mergeDelta(m, previous, keepGraph: !st.graphTouched);
  m.fields.sort((x, y) {
    final c = x.row.compareTo(y.row);
    return c != 0 ? c : x.col.compareTo(y.col);
  });
  return m;
}

/// Whether a server SES (16 bytes, pysap SAPDiagSES) announces a DELTA
/// paint: its `screen_flag` (byte 6) has bit 0x01 — a new screen — clear.
/// Across every recording (GuiGo testdata + the reference client's, ~4000 paints) a
/// paint of ANOTHER screen always sets it (flag 0x01 / 0x11 / 0x21); a
/// clear flag only repaints the screen already shown: the error message's
/// paint resends the inputs alone (a recorded session srv[184] full
/// SAPMSVMA/0100, 29 atoms + flag 01 -> srv[185] `E: La table/vue V_T000
/// n'existe pas…`, 17 atoms + flag 00: the output, the frame box and the
/// four pushbuttons are not resent and stay on the real GUI's screen), and
/// the type-ahead answer's paint resends nothing (a recorded session
/// pick raw srv[17] / [19]…, selection_options raw srv[16]: SES `…00 …`,
/// the program / dynpro names, no atom).
bool sesIsDeltaPaint(Uint8List? ses) =>
    ses != null && ses.length >= 16 && ses[6] & 0x01 == 0;

/// The dynpro BODY items of [_paintsDynpro] — everything but the program /
/// dynpro names a delta paint repeats without repainting anything.
bool _paintsBody(DiagItem it) =>
    _paintsDynpro(it) &&
    !(it.isAppl && it.id == applStR3Info && (it.sid == 13 || it.sid == 14));

/// A delta paint ([sesIsDeltaPaint]) folded over the window's [previous]
/// paint: the cells it repaints are its own, every other field, frame box,
/// table control, container, list and graph stays as painted. A repainted
/// input keeps its caption and type-ahead arming when the delta resent
/// neither.
void _mergeDelta(ScreenModel m, ScreenModel previous,
    {bool keepGraph = true}) {
  (String?, int, int) cell(ScreenField f) => (f.container, f.row, f.col);
  final prevAt = {for (final f in previous.fields) cell(f): f};
  final painted = <(String?, int, int)>{};
  for (final f in m.fields) {
    painted.add(cell(f));
    final was = prevAt[cell(f)];
    if (was == null || was.kind != f.kind) continue;
    if (f.label.isEmpty) f.label = was.label;
    // a radio / checkbox resent for its state carries no caption (su53
    // srv[271]: the four RS37A-FUN* radios, text empty)
    if ((f.kind == FieldKind.radio || f.kind == FieldKind.checkbox) &&
        f.text.trim().isEmpty) {
      f.text = was.text;
    }
    if (f.name == null || f.name!.isEmpty) f.name = was.name;
    f.typeAhead = f.typeAhead || was.typeAhead;
  }
  for (final f in previous.fields) {
    if (!painted.contains(cell(f))) m.fields.add(f);
  }
  final boxes = {for (final b in m.frames) (b.row, b.col)};
  for (final b in previous.frames) {
    if (!boxes.contains((b.row, b.col))) m.frames.add(b);
  }
  if (m.tableControls.isEmpty) m.tableControls.addAll(previous.tableControls);
  for (final e in previous.containers.entries) {
    m.containers.putIfAbsent(e.key, () => e.value);
  }
  m.hostedDynpros.addAll(previous.hostedDynpros);
  for (final e in previous.controlPaths.entries) {
    m.controlPaths.putIfAbsent(e.key, () => e.value);
  }
  if (keepGraph && m.netPlans.isEmpty) {
    m.netPlans.addAll(previous.netPlans);
    m.inlineGraph ??= previous.inlineGraph;
  }
  if (m.listPaint.isEmpty) {
    m.listLines.addAll(previous.listLines);
    m.listPaint.addAll(previous.listPaint);
    m.listWindow ??= previous.listWindow;
    m.listCursor ??= previous.listCursor;
  }
}

/// An icon (`@3R@`, `@3R\Q<quick info>@`) or a quick-info wrapper
/// (`@\QNom de la table@`) inside a list run: an icon paints two cells,
/// a quick info none — the next run's SBA lands there (a recorded session
/// queue `@G9@` at col 6, the next run at 8; a recorded session srv[68]
/// `@\QColonne de sélection@ ` at col 1, the next run at 3). A token cut
/// off by the run ends at its end (the table-control heading's rule).
final RegExp _listToken = RegExp(r'@([0-9A-Z]{2})?(?:\\Q([^@]*))?(?:@|$)');

/// One list run's text into the grid at the pending position, with its
/// SFE attributes: the line-element font's digit codes rendered as box
/// glyphs, icon tokens as two-cell icons, quick-info wrappers zero-width.
void _listRun(_FoldState st, Uint8List v) {
  final (row, col) = st.listAt!;
  st.listAt = null;
  // SBA2 positions are two wire u16s: a hostile run at row/col 65535 would
  // grow the row arrays a cell at a time to the column, for every row
  if (row < 0 || row >= maxListRows || col < 0 || col >= maxListCols) return;
  final f = st.listFont;
  final sfe = f != null && f.length >= 3
      ? f[0] << 16 | f[1] << 8 | f[2]
      : ListSegment.defaultSfe;
  final text = wireDecode(v);
  final cells = st.listGrid.putIfAbsent(row, _ListRow.new);
  var run = ++st.listRunId;
  if (sfe & 0x08 != 0) {
    for (var i = 0; i < text.length; i++) {
      final u = text.codeUnitAt(i);
      cells.put(col + i, _listLineFontUnits[u] ?? u, sfe, run);
    }
    return;
  }
  var c = col, at = 0;
  if (text.contains('@')) {
    for (final t in _listToken.allMatches(text)) {
      final code = t.group(1), tip = t.group(2)?.trim();
      if (code == null && tip == null) continue; // a literal '@'
      c = cells.putText(c, text.substring(at, t.start), sfe, run);
      at = t.end;
      if (code == null) {
        if (tip!.isNotEmpty) cells.tips[run] = tip;
        continue;
      }
      final icon = ++st.listRunId;
      cells.put(c, 0x20, sfe, icon);
      cells.put(c + 1, 0x20, sfe, icon);
      cells.icons[c] = code;
      if (tip != null && tip.isNotEmpty) cells.tips[icon] = tip;
      c += 2;
      run = ++st.listRunId; // the text after an icon: a run of its own
    }
  }
  cells.putText(c, text.substring(at), sfe, run);
}

/// The classic-list paint bounds: the widest ABAP list line (LINE-SIZE
/// max 1023) with margin, and the most lines one paint can place. A list
/// run positioned or extending past them is dropped (cells past the
/// column bound are clipped), never grown into.
const int maxListCols = 1280;
const int maxListRows = 1024;

/// One classic-list line being painted: the code unit, SFE and run per
/// column (-1 = unpainted) — audit #15: a Map entry and a one-char String
/// per cell (12k of them for a 200 x 60 list) per repaint.
class _ListRow {
  final List<int> units = [];
  final List<int> sfes = [];
  final List<int> runs = [];

  /// Icon codes by the icon's first column; quick infos by run.
  final Map<int, String> icons = {};
  final Map<int, String> tips = {};
  int lo = -1, hi = -1; // the painted columns' span; -1: none yet

  void put(int col, int unit, int sfe, int run) {
    if (col >= maxListCols) return; // a run past the widest list line
    while (units.length <= col) {
      units.add(-1);
      sfes.add(0);
      runs.add(0);
    }
    units[col] = unit;
    sfes[col] = sfe;
    runs[col] = run;
    icons.remove(col); // a later run paints over an icon
    if (lo < 0 || col < lo) lo = col;
    if (col > hi) hi = col;
  }

  /// [text] from [col]; the column after it.
  int putText(int col, String text, int sfe, int run) {
    for (var i = 0; i < text.length; i++) {
      put(col + i, text.codeUnitAt(i), sfe, run);
    }
    return col + text.length;
  }
}

void _buildListLines(ScreenModel m, _FoldState st) {
  for (final r in st.listGrid.keys.toList()..sort()) {
    final cells = st.listGrid[r]!;
    if (cells.hi < 0) continue;
    final lo = cells.lo, hi = cells.hi;
    final text = String.fromCharCodes([
      for (var c = lo; c <= hi; c++)
        cells.units[c] < 0 ? 0x20 : cells.units[c],
    ]).trimRight();
    // the painted runs: a segment per run and SFE, an icon its own
    final segments = <ListSegment>[];
    var c = lo;
    while (c <= hi) {
      if (cells.units[c] < 0) {
        c++;
        continue;
      }
      final run = cells.runs[c], sfe = cells.sfes[c];
      var e = c + 1;
      while (e <= hi &&
          cells.units[e] >= 0 &&
          cells.runs[e] == run &&
          cells.sfes[e] == sfe &&
          !cells.icons.containsKey(e)) {
        e++;
      }
      segments.add(ListSegment(
        c,
        String.fromCharCodes(cells.units.sublist(c, e)),
        sfe: sfe,
        icon: cells.icons[c],
        tip: cells.tips[run],
      ));
      c = e;
    }
    final line = ListLine(r, lo, text, segments);
    m.listPaint.add(line);
    // a cosmetic frame rule, a blank row: no pickable line (an icon is)
    final noText = text.codeUnits
        .every((c) => c == 0x20 || _listFrameGlyphUnits.contains(c));
    if (noText && !segments.any((s) => s.icon != null)) continue;
    m.listLines.add(line);
  }
}

/// True when [frames] (re)paint the dynpro of a window — DYNT atoms,
/// containers, a list, the program / dynpro name — not a flush or a receipt.
bool framesPaintDynpro(Iterable<Uint8List> frames) {
  for (final f in frames) {
    if (_framePaintsDynpro[f] ??= _paintsDynproFrame(f)) return true;
  }
  return false;
}

/// [framesPaintDynpro]'s verdict per frame object, memoized like its walk
/// (the fold asks it twice per turn; audit zcode P-05).
final Expando<bool> _framePaintsDynpro = Expando('frame paints dynpro');

bool _paintsDynproFrame(Uint8List f) {
  final dec = decompressFrame(f);
  if (dec == null) return false;
  final items = dec.walk.items;
  if (items.any(_paintsBody)) return true;
  // the program / dynpro names alone: a new screen's paint, unless the
  // frame's SES marks it a delta of the screen shown (the type-ahead
  // answer's body-less repaint — typed values staged meanwhile stay)
  if (items.any(_paintsDynpro)) {
    final ses = items
        .where((it) => it.type == itemSes && it.value.length >= 16)
        .lastOrNull;
    if (!sesIsDeltaPaint(ses?.value)) return true;
  }
  return false;
}

/// An item that (re)paints the dynpro: a DYNT atom family item (18/9/*,
/// 16/9/2), a 16/10 container item, the program / dynpro name (16/6/13,
/// 16/6/14) or an inline graph's first item — never the conversation's
/// later items (a continuation, the bare receive cng9 srv[33]): folded as
/// a paint they wiped the graph the paint before had just drawn.
bool _paintsDynpro(DiagItem it) {
  if (it.type == itemSba) return true; // a classic list run
  if (!it.isAppl) return false;
  if (it.id == applDynt && it.sid != 10 && it.sid != 11) return true;
  if (it.id == applContainer) return true;
  if (it.id == applGraph) {
    return isInlineGraphHead(it.value);
  }
  return it.id == applStR3Info && (it.sid == 13 || it.sid == 14);
}

/// Fold server frames (one turn's worth) into a screen model, starting from
/// [previous] state (latest-wins per item family).
ScreenModel foldScreen(ScreenModel? previous, List<Uint8List> frames) =>
    foldWindows(previous, null, frames).active;

/// A DYNT atom with the ABSOLUTE origin of the container it is painted in.
class _PlacedAtom {
  _PlacedAtom(this.atom, this.container, this.top, this.left,
      [this.plane, this.group]);
  final DyntAtom atom;
  final String? container;
  final int top;
  final int left;

  /// The frame's container declaration and the group the atom follows.
  final RoutingFrame? plane;
  final RoutingGroup? group;
  int get row => atom.row + top;
  int get col => atom.col + left;

  /// The container instance the atom is painted in: its name AND absolute
  /// origin — ME21N paints several subscreens all named SUB1 (SAPLMEGUI
  /// 1105 / 6000, SAPLMEVIEWS …), whose (0,0) cells are different fields.
  /// Spelled once per atom (it was re-interpolated per key, per access).
  late final String scope = '$container@$top,$left';

  // The field-assembly keys of [_buildFields] as records (audit #15: 6–8
  // interpolated strings per atom per repaint): the same identities as the
  // `scope:area:block:…` strings they replace.

  /// (scope, area, block, group, row, col): a field's cell in its group.
  late final _GroupCell groupCell =
      (scope, atom.area, atom.block, atom.group, atom.row, atom.col);

  /// (scope, area, block, row, col): a cell, whatever group paints it.
  late final _Cell cell = (scope, atom.area, atom.block, atom.row, atom.col);

  /// (scope, area, block, row): a painted line of a block.
  late final _Line line = (scope, atom.area, atom.block, atom.row);
}

typedef _GroupCell = (String, int, int, int, int, int);
typedef _Cell = (String, int, int, int, int);
typedef _Line = (String, int, int, int);

class _Level {
  _Level(this.kind, this.name, this.top, this.left);
  final int kind;
  final String name;
  final int top; // absolute
  final int left;
}

/// The 16/10 container PATH of a paint (reference client
/// engine/screen_model_fold._fold_path_marker + diag_geometry._geom9): a
/// 16/10/1 RESET, then per level a 9-byte geometry record (16/10/<kind>:
/// seq u8, top u16 BE, left u16 BE, width u16 BE, height u16 BE) closed by
/// its 16/10/6 NAME (`NAME\0PROG\0DYNP`). Every level's origin is RELATIVE
/// to the level declared before it since the RESET; the atoms that follow
/// a path are painted relative to the hosting level, so their absolute
/// cell is the atom's plus that level's summed origin.
class _ContainerPath {
  final List<_Level> levels = [];
  _Level? host; // the level the following atoms are painted in
  (int, int, int, int, int)? pending; // kind, top, left, width, height
  final Map<String, ScreenContainer> declared = {};

  /// Every (PROG, DYNP) a NAME of the paint named ([ScreenModel
  /// .hostedDynpros]) — [declared] keeps one container per name.
  final Set<(String, String)> dynpros = {};

  void reset() {
    levels.clear();
    host = null;
    pending = null;
  }

  /// Folds one marker; returns the level a NAME closed, if any.
  _Level? marker(int sid, Uint8List v) {
    if (sid == 6) {
      final g = pending;
      pending = null;
      var end = 0;
      while (end < v.length && v[end] != 0) {
        end++;
      }
      final name = wireDecode(Uint8List.sublistView(v, 0, end)).trim();
      if (name.isEmpty || g == null) return null;
      final parent = levels.isNotEmpty ? levels.last : null;
      final lv = _Level(
        g.$1,
        name,
        (parent?.top ?? 0) + g.$2,
        (parent?.left ?? 0) + g.$3,
      );
      levels.add(lv);
      // the NUL-separated PROG / DYNP after the name
      final tail = [
        for (final s in wireDecode(
          Uint8List.sublistView(v, end < v.length ? end + 1 : v.length),
        ).split('\x00'))
          s.trim(),
      ];
      final prog = tail.isNotEmpty && tail[0].isNotEmpty ? tail[0] : null;
      final dyn = tail.length > 1 && tail[1].isNotEmpty ? tail[1] : null;
      if (prog != null && dyn != null) dynpros.add((prog, dyn));
      declared[name] = ScreenContainer(
        name,
        g.$1,
        lv.top,
        lv.left,
        g.$4,
        g.$5,
        g.$2,
        g.$3,
        parent?.name,
        program: prog,
        dynpro: dyn,
      );
      switch (g.$1) {
        case 3: // SUBSCREEN — the reference client's classic fold offsets its atoms
        // by the subscreen's own (parent-relative) origin; the summed path
        // origin is the screen cell (equal at the root; diag_controlstate's
        // path rule — ME21N SUB0>SUB2>SUB2>SUB1 sums to row 12 col 3)
        case 8: // TABSTRIP — its 18/9/16 tab buttons sit at the strip
        case 9: // TABSTRIP_PAGE — the page hosts its dynpro's atoms
          // (diag_controlstate.parse_stream: atoms/tab pages are painted
          // relative to the innermost path level)
          host = lv;
          break;
        case 16: // AREA: a root AREA, or one nested in an AREA, hosts its
          // atoms; an AREA nested in a SUBSCREEN keeps the subscreen as the
          // container (reference client _fold_path_marker, the 4004 RMSCH-RAHMENT2 pin)
          if (parent == null || parent.kind == 16) host = lv;
          break;
        default:
          break;
      }
      return lv;
    }
    if (sid == 1) {
      reset();
      return null;
    }
    if (v.length == 9) {
      int u16(int o) => (v[o] << 8) | v[o + 1];
      pending = (sid, u16(1), u16(3), u16(5), u16(7));
    }
    return null;
  }
}

/// The per-window fold state carried across a segment's items.
class _FoldState {
  final atoms = <_PlacedAtom>[];
  final path = _ContainerPath();
  final tcs = <String, TcBuilder>{};
  final tableLevels = <String, _Level>{};
  final tableGeoms = <String, ScreenContainer>{};
  String? tcName; // the latest 16/10/6 NAME of the frame (reference client st["name"])

  /// The SAP codepage the latest 16/6/35 declared (an inline GRAPH item is
  /// decoded in the one declared right before it — 1160 on CNG9).
  String graphCodepage = '4110';

  /// The inline GRAPH conversation this segment continues (the window's
  /// previous paint's, then each item's), and whether an item of this
  /// segment opened, extended or closed it.
  InlineGraphStream? graph;
  bool graphTouched = false;

  /// The TABLE-plane bookkeeping of a cell write (reference client
  /// diag_container_tree / screen_tablecontrol): the first 16/12/6 of the
  /// frame, the container group being declared (16/10/1 OPEN … the next
  /// OPEN, names excluded, a 16/12/6 after a 16/10/9 page leg kept in
  /// place), each control's CL5-terminated group by name, and the last
  /// tabstrip tree-names item with the legs of the group it follows and the
  /// 18/9/16 pages descriptor after it.
  Uint8List? frameScroll;
  List<TcPlaneItem>? group;
  final Map<String, List<TcPlaneItem>> tcRouting = {};
  List<TcPlaneItem> treeNamesLegs = const [];
  Uint8List? treeNames, tabPages;
  bool expectPages = false;

  /// The frame's container groups for a field write ([FieldRouting]).
  RoutingFrame plane = RoutingFrame();

  /// Classic list runs: the pending run position and font, and the painted
  /// cells by buffer row / column.
  (int, int)? listAt;
  Uint8List? listFont;
  int listRunId = 0;
  final Map<int, _ListRow> listGrid = {};

  void newFrame() {
    path.reset();
    plane = RoutingFrame();
    tcName = null;
    frameScroll = null;
    group = null;
    expectPages = false;
    for (final b in tcs.values) {
      b.endPaint();
    }
  }

  TcBuilder tc(String name) => tcs.putIfAbsent(name, () => TcBuilder(name));
}

/// One inline GRAPH item 16/2/5: a graph's first item opens the screen's
/// conversation, a `04`-led item continues an unterminated one (its graph
/// parsed once the stream ends: gral_netzocx1_java srv[38] + srv[39]), the
/// close message ends it; the server's bare receive (`04`, cng9 srv[33])
/// and any other message leave it as it is.
void _foldInlineGraph(ScreenModel m, Uint8List v, _FoldState st) {
  // the profile (INI) service shares the item and is no graphic: it leaves
  // the conversation as it is (xxl_excel_word_demos srv[21] BPROF / srv[22]
  // KPROF — drawn, it was the "network graph without nodes" of XXLSTEST)
  if (isInlineProfileMessage(v)) return;
  final opened = InlineGraphStream.open(v, st.graphCodepage);
  final was = st.graph;
  final InlineGraphStream? now;
  if (opened != null) {
    now = opened;
  } else if (was != null && inlineGraphCloses(v, was.interface)) {
    now = null;
  } else {
    now = was?.extend(v);
    if (now == null) return;
  }
  st
    ..graph = now
    ..graphTouched = true;
  m.inlineGraph = now;
  m.netPlans.removeWhere((g) => g.shell == null);
  // the first item is parsed as it is (a one-item graph, cng9 srv[32]); a
  // continued one once complete — never a classic BUSG / STAT graphic (its
  // raw stream stays on [ScreenModel.inlineGraph] for its renderer)
  final g = now != null &&
          now.kind != InlineGraphKind.business &&
          now.kind != InlineGraphKind.statistics &&
          (opened != null || now.complete)
      ? now.model
      : null;
  if (g != null) m.netPlans.add(g);
}

void _foldAppl(ScreenModel m, DiagItem it, _FoldState st) {
  if (it.id == applStR3Info && it.sid == 35) {
    st.graphCodepage =
        netPlanCodepageOf(Uint8List.fromList(it.value)) ?? st.graphCodepage;
  } else if (it.id == applGraph && it.sid == 5) {
    _foldInlineGraph(m, Uint8List.fromList(it.value), st);
    return;
  }
  switch (it.id) {
    case applStR3Info:
      final v = it.value;
      if (v.isEmpty) return;
      final text = wireDecode(v).trim();
      if (text.isEmpty) return;
      switch (it.sid) {
        case 7:
          m.tcode = text;
          break;
        case 13:
          m.program = text;
          break;
        case 14:
          m.dynpro = text;
          break;
        case 11:
          m.message = text;
          break;
        case 16:
          // the PF-status (16/6/16 — CSEL_POP_TS on SAPLALDB/3000); 16/6/15
          // is the CUA program (reference client screen_model_fold._fold_info_string)
          m.guiStatus = text;
          break;
        case 19:
          m.fkeys
            ..clear()
            ..addAll(_parseFkeys(v));
          break;
      }
      break;
    case applVarInfo:
      if (it.sid == 9 && it.value.isNotEmpty) {
        final t = wireDecode(it.value).trim();
        if (t.isNotEmpty) m.title = t;
      } else if (it.type == itemAppl && it.sid == 11 && st.listAt != null) {
        _listRun(st, it.value);
      } else if (it.type == itemAppl && it.sid == 2 && it.value.length >= 24) {
        final bd = ByteData.sublistView(Uint8List.fromList(it.value));
        m.listWindow = [for (var k = 0; k < 5; k++) bd.getUint32(k * 4)];
      } else if (it.type == itemAppl &&
          it.sid == 13 &&
          it.value.length >= 5 &&
          it.value[0] == 1) {
        final v = it.value;
        m.listCursor = (v[1] << 8 | v[2], v[3] << 8 | v[4]);
      } else if (it.type == itemAppl && it.sid == 7) {
        st.plane.window(Uint8List.fromList(it.value));
      } else if (it.type == itemAppl && it.sid == 6) {
        final v = Uint8List.fromList(it.value);
        st.plane.geometry(v);
        st.frameScroll ??= v;
        final g = st.group;
        if (g != null && g.isNotEmpty && g.last.id == 10 && g.last.sid == 9) {
          g.add(TcPlaneItem(12, 6, v)); // the page's geometry, in-chain
        }
      } else if (it.type == itemAppl4 && it.sid == 2) {
        // the control-area descriptor painted right after its TABLE_HEADER
        final name = st.tcName;
        if (name != null && st.tcs.containsKey(name)) {
          st.tcs[name]!.controlArea = Uint8List.fromList(it.value);
        }
      }
      break;
    case applContainer:
      if (it.sid == 1) {
        st.group = [TcPlaneItem(10, 1, Uint8List.fromList(it.value))];
        st.plane.open(Uint8List.fromList(it.value));
      } else if (it.sid != 6) {
        st.group?.add(TcPlaneItem(10, it.sid, Uint8List.fromList(it.value)));
        st.plane.leg(it.sid, Uint8List.fromList(it.value));
      }
      final lv = st.path.marker(it.sid, it.value);
      if (it.sid == 6) {
        var end = 0;
        while (end < it.value.length && it.value[end] != 0) {
          end++;
        }
        final nm = wireDecode(Uint8List.sublistView(it.value, 0, end)).trim();
        if (nm.isNotEmpty) st.tcName = nm;
        st.plane.name(nm);
        final g = st.group;
        final legs = g?.where((l) => l.id == 10).toList() ?? const [];
        if (nm.isNotEmpty && legs.isNotEmpty && legs.last.sid == 5) {
          st.tcRouting[nm] = List.of(g!);
        }
        if (nm.isNotEmpty && legs.isNotEmpty && legs.last.sid == 10) {
          m.controlPaths[nm] = [
            for (final l in legs)
              if (l.sid != 1 && l.value.isNotEmpty && l.value[0] != 0)
                l.value[0],
          ];
        }
        if (lv != null && lv.kind == 5) {
          st.tableLevels[lv.name] = lv;
          st.tableGeoms[lv.name] = st.path.declared[lv.name]!;
        }
      }
      break;
    case applMnEntry:
      // reference client engine/screen_model.parse_screen: the LATEST 18/11 packet per
      // sid — 1 menu bar, 2 dropdowns, 3 app toolbar (separators dropped),
      // 4 function keys (entries with a vkey and a text)
      final entries = parseMenuEntries(it.value);
      switch (it.sid) {
        case 1:
          m.menuBar
            ..clear()
            ..addAll(entries.where((e) => e.text.isNotEmpty));
          break;
        case 2:
          m.menuTree
            ..clear()
            ..addAll(entries);
          break;
        case 3:
          m.toolbar
            ..clear()
            ..addAll(entries.where((e) => !e.separator));
          break;
        case 4:
          final keys = entries.where((e) => e.vkey != 0 && e.text.isNotEmpty);
          m.functionKeys
            ..clear()
            ..addAll(keys);
          m.fkeys
            ..clear()
            ..addAll(keys.map((e) => FKey(e.vkey, e.text)));
          break;
      }
      break;
    case applDynt:
      if (it.sid == 15) {
        // a tabstrip's tree-names item (the last one wins) and the group it
        // follows; its 18/9/16 pages descriptor comes right after
        st.treeNames = Uint8List.fromList(it.value);
        st.plane.treeNamesItem(st.treeNames!);
        st.treeNamesLegs = [
          for (final l in st.group ?? const <TcPlaneItem>[])
            if (l.id == 10) l,
        ];
        st.tabPages = null;
        st.expectPages = true;
        return;
      }
      if (it.sid == 16 && st.expectPages) {
        st.tabPages = Uint8List.fromList(it.value);
        st.expectPages = false;
      }
      // atoms ride 9/2 (dynpro paint) and 9/16 (tabstrip paint, APPL4)
      if (it.sid == 2 || it.sid == 16) {
        final host = st.path.host;
        for (final a in parseDyntAtoms(it.value).atoms) {
          st.atoms.add(
            _PlacedAtom(a, host?.name, host?.top ?? 0, host?.left ?? 0,
                st.plane, st.plane.current),
          );
        }
        return;
      }
      // the table-control family (reference client screen_tablecontrol._parse_scan_item):
      // every 18/9 item after a NAME belongs to that control
      final name = st.tcName;
      if (name == null) return;
      if (!const {5, 8, 13, 14, 17, 21}.contains(it.sid)) return;
      final c = st.tc(name);
      final routing = st.tcRouting[name];
      if (routing != null) c.routing = routing;
      final lv = st.tableLevels[name];
      if (lv != null) {
        final g = st.tableGeoms[name]!;
        c
          ..absTop = lv.top
          ..absLeft = lv.left
          ..width = g.width
          ..height = g.height
          ..container = g.parent;
      }
      final v = it.value;
      switch (it.sid) {
        case 13:
          final cols = [for (final t in _nulTokens(v)) t];
          if (cols.isNotEmpty) c.columns = cols;
          break;
        case 21:
          final tips = parseTcTooltips(v);
          if (tips.isNotEmpty) c.titles = tips;
          break;
        case 5:
          c.lineHead(v);
          break;
        case 8:
          c.rowBuffer(v);
          break;
        case 17:
          c.lineAttrRecord(v);
          break;
        case 14:
          c.header = parseTableHeader(v) ?? c.header;
          c.headerRaw = Uint8List.fromList(v);
          c.scrollGeometry = st.frameScroll ?? c.scrollGeometry;
          break;
      }
      break;
    default:
      break;
  }
}

List<String> _nulTokens(Uint8List v) {
  final out = <String>[];
  var s = 0;
  for (var i = 0; i <= v.length; i++) {
    if (i == v.length || v[i] == 0) {
      if (i > s) out.add(latin1.decode(Uint8List.sublistView(v, s, i)));
      s = i + 1;
    }
  }
  return out;
}

/// GUI_FKEY (16/6/19): runs of `<vkey u8><len u8><text><NUL>` … layout per
/// a recorded session: `\x01 09 \x00 &F \x00 9 \x20 \x00\x00` — vkey, text
/// length, text, NUL terminator; a trailing NUL NUL ends the table.
List<FKey> _parseFkeys(Uint8List v) {
  final out = <FKey>[];
  var i = 0;
  while (i + 1 < v.length) {
    // entries look like: <vkey u8> <0x00> <text...> <0x00> — heuristic parse:
    // the observed shape is vkey, NUL, text bytes, NUL
    final vk = v[i];
    if (vk == 0 && i + 1 < v.length && v[i + 1] == 0) break;
    var j = i + 1;
    final txt = BytesBuilder(copy: false);
    while (j < v.length && v[j] != 0) {
      txt.addByte(v[j]);
      j++;
    }
    if (txt.length > 0) {
      out.add(FKey(vk, wireDecode(txt.takeBytes()).trim()));
    }
    i = j + 1;
  }
  return out;
}

void _buildFields(ScreenModel m, List<_PlacedAtom> placed) {
  // merged repaints: the LAST atom at a cell wins
  // (the container is part of a cell's identity: two subscreens paint
  // their own row 0 — reference client screen_model_fold._fold_atoms keys by it)
  final byCell = <(int, _GroupCell), _PlacedAtom>{};
  for (final p in placed) {
    byCell[(p.atom.etype, p.groupCell)] = p;
  }
  placed = byCell.values.toList();
  // names by (container, area, block, group, row, col)
  final names = <_GroupCell, String>{};
  for (final p in placed) {
    final a = p.atom;
    if (a.etype == etypeFname && (a.nameText ?? '').isNotEmpty) {
      names[p.groupCell] = a.nameText!;
    }
  }
  // labels by (row, col) for left-adjacent pairing
  final labels = <_Line, List<(int, String)>>{};
  for (final p in placed) {
    final a = p.atom;
    if (etypeLabel.contains(a.etype)) {
      final t = a.fieldText ?? '';
      if (t.trim().isNotEmpty) {
        (labels[p.line] ??= []).add((a.col, t.trimRight()));
      }
    }
  }

  // cells a stronger presentation atom claims (reference client screen_atoms
  // _fold_atoms rank: input/checkbox 4 > combo 3 > output 2 > label 1) —
  // a label atom alone on its cell is display text of its own (SE16's
  // "Nom de table" before DATABROWSE-TABLENAME), not only a caption
  final presented = <_GroupCell>{};
  for (final p in placed) {
    final a = p.atom;
    if (etypeInput.contains(a.etype) ||
        etypeOutput.contains(a.etype) ||
        etypeCombo.contains(a.etype) ||
        a.etype == etypeCheckButton3 ||
        a.etype == etypeRadioButton3) {
      presented.add(p.groupCell);
    }
  }

  // value help per cell: MATCHCODE on any atom of the cell, or the F4
  // button (COMBOSTYLE) on a cell without a listbox (reference client screen_atoms)
  final cellMc = <_Cell>{}, cellCs = <_Cell>{}, cellCombo = <_Cell>{};
  final cellTypeAhead = <_GroupCell>{};
  for (final p in placed) {
    final a = p.atom;
    final cell = p.cell;
    if (a.etype == etypeXmlprop && xmlpropArmsTypeAhead(a.xmlpropText)) {
      cellTypeAhead.add(p.groupCell);
    }
    if (a.attr & 0x10 != 0) cellMc.add(cell);
    if (a.attr & 0x80 != 0) cellCs.add(cell);
    if (etypeCombo.contains(a.etype)) cellCombo.add(cell);
  }

  for (final p in placed) {
    final a = p.atom;
    final key = p.groupCell;
    ScreenField? f;
    if (etypeLabel.contains(a.etype) &&
        !presented.contains(key) &&
        (a.fieldText ?? '').trim().isNotEmpty) {
      f = ScreenField(
        kind: FieldKind.label,
        row: p.row,
        col: p.col,
        wireRow: a.row,
        wireCol: a.col,
        container: p.container,
        text: (a.fieldText ?? '').trimRight(),
        area: a.area,
        block: a.block,
        group: a.group,
      )..name = names[key];
    } else if (etypeInput.contains(a.etype)) {
      // the painted value is blank-padded to mlen (SE16's table name is 30
      // blanks); the frontend shows and edits the trimmed value — appending
      // typed text after the padding sent a 34-char value whose cursor fell
      // past the field's end and was refused "FOCUS DATA" (2026-10-09)
      f =
          ScreenField(
              kind: FieldKind.input,
              row: p.row,
              col: p.col,
              wireRow: a.row,
              wireCol: a.col,
              container: p.container,
              text: (a.fieldText ?? '').trimRight(),
              mlen: a.fieldMlen,
              maxnrchars: a.fieldMaxnrchars,
              invisible: a.isInvisible,
              isProtected: a.isProtected,
              area: a.area,
              block: a.block,
              group: a.group,
              dlg1: a.dlgFlag1,
              dlg2: a.dlgFlag2,
              attr: a.attr,
            )
            ..name = names[key]
            ..label = _labelFor(labels, p);
    } else if (etypeOutput.contains(a.etype)) {
      f =
          ScreenField(
              kind: FieldKind.output,
              row: p.row,
              col: p.col,
              wireRow: a.row,
              wireCol: a.col,
              container: p.container,
              text: a.fieldText ?? '',
              // the painted (visible) length: an icon output shows its
              // icon in mlen cells, its `\Q` quick info is the tooltip —
              // the debugger's TOOL_BAR OK_SYS_CLOSE_TOOL `@UP\QFermer
              // l'outil@` is mlen 2 (a recorded session s[27])
              mlen: a.fieldMlen,
              maxnrchars: a.fieldMaxnrchars,
              area: a.area,
              block: a.block,
              group: a.group,
            )
            ..name = names[key]
            ..label = _labelFor(labels, p);
    } else if (a.etype == etypeCheckButton3) {
      f = ScreenField(
        kind: FieldKind.checkbox,
        row: p.row,
        col: p.col,
        wireRow: a.row,
        wireCol: a.col,
        container: p.container,
        text: a.radiobuttonText ?? '',
        on:
            a.radiobuttonButton == 1 ||
            a.radiobuttonButton == 0x58 ||
            a.dlgFlag2 & 0x80 != 0,
        area: a.area,
        block: a.block,
        group: a.group,
      )
        ..name = names[key]
        ..label = _radioLabel(a);
    } else if (a.etype == etypeRadioButton3) {
      f = ScreenField(
        kind: FieldKind.radio,
        row: p.row,
        col: p.col,
        wireRow: a.row,
        wireCol: a.col,
        container: p.container,
        text: a.radiobuttonText ?? '',
        on:
            a.radiobuttonButton == 1 ||
            a.radiobuttonButton == 0x58 ||
            a.dlgFlag2 & 0x80 != 0,
        area: a.area,
        block: a.block,
        group: a.group,
      )
        ..name = names[key]
        ..label = _radioLabel(a);
    } else if (a.etype == etypePushButton2) {
      f = ScreenField(
        kind: FieldKind.pushbutton,
        row: p.row,
        col: p.col,
        wireRow: a.row,
        wireCol: a.col,
        container: p.container,
        text: (a.pushbuttonText ?? '').trimRight(),
        fcode: (a.pushbuttonFunctionCode ?? '').trim().isEmpty
            ? null
            : (a.pushbuttonFunctionCode ?? '').trim(),
        area: a.area,
        block: a.block,
        group: a.group,
      );
    } else if (a.etype == etypeTabstripButton) {
      f = ScreenField(
        kind: FieldKind.tabstrip,
        row: p.row,
        col: p.col,
        wireRow: a.row,
        wireCol: a.col,
        container: p.container,
        text: (a.tabstripText ?? '').trimRight(),
        fcode: (a.tabstripFunctionCode ?? '').trim().isEmpty
            ? null
            : (a.tabstripFunctionCode ?? '').trim(),
        pageId: a.tabstripPageId,
        on: a.tabstripPageId != 0,
        area: a.area,
        block: a.block,
        group: a.group,
      );
    } else if (etypeCombo.contains(a.etype)) {
      final lb = decodeListboxAtom(a.value);
      f =
          ScreenField(
              kind: FieldKind.combobox,
              row: p.row,
              col: p.col,
              wireRow: a.row,
              wireCol: a.col,
              container: p.container,
              // the KEY only — never the payload's binary prefix or its
              // value-set id (listbox_valueset.dart)
              text: lb?.key.trim() ?? '',
              // the listbox's visible box width (20 / 40 cells)
              mlen: lb?.width ?? 0,
              // a display-mode listbox paints PROTECTED (attr c1): the
              // frontend refuses a pick locally (a recorded session)
              isProtected: a.isProtected,
              invisible: a.isInvisible,
              attr: a.attr,
              area: a.area,
              block: a.block,
              group: a.group,
            )
            ..name = names[key]
            ..label = _labelFor(labels, p)
            ..listbox = lb;
    } else if (a.etype == etypeFrame1) {
      m.frames.add(
        ScreenFrame(
          p.row,
          p.col,
          a.frameDrows,
          a.frameDcols,
          (a.frameText ?? '').trimRight(),
        ),
      );
    }
    if (f != null) {
      f.routing = p.plane?.routingFor(p.group, a.area);
      final cell = p.cell;
      f.hasF4 = f.kind == FieldKind.input &&
          (cellMc.contains(cell) ||
              (cellCs.contains(cell) && !cellCombo.contains(cell)));
      f.typeAhead =
          f.kind == FieldKind.input && cellTypeAhead.contains(p.groupCell);
      m.fields.add(f);
    }
  }
}

String _labelFor(Map<_Line, List<(int, String)>> labels, _PlacedAtom p) {
  // a label sits to the LEFT of its field on the same row: the nearest one
  // leftwards (ME21N's top line: "Date doc." at col 78 captions BEDAT at
  // 89, not EBELN at 21)
  final a = p.atom;
  final row = labels[p.line];
  if (row == null || a.col == 0) return '';
  (int, String)? best;
  for (final l in row) {
    if (l.$1 < a.col && (best == null || l.$1 >= best.$1)) best = l;
  }
  return best?.$2 ?? '';
}

/// The table controls of a window and their visible cells as fields
/// (reference client engine/screen_tablecontrol.parse_table_controls: only a control
/// that carried a column catalog is a grid). A cell sits at its line's
/// screen row (control top + the header rows + line - 1, reference client
/// raw_tabline._tc_line_rows) and its column's start (control left + the
/// selector column + the preceding widths, raw_tabline.tc_line_focus).
void _buildTableControls(ScreenModel m, _FoldState st) {
  for (final b in st.tcs.values) {
    if (b.columns.isEmpty) continue;
    if (st.treeNames != null) {
      b
        ..treeNames = st.treeNames
        ..tabPages = st.tabPages
        ..tabstripRouting = st.treeNamesLegs;
    }
    final tc = b.build();
    m.tableControls.add(tc);
    final lines = b.cellsByLine.keys.toList()..sort();
    for (final line in lines) {
      final cells = b.cellsByLine[line]!;
      final etypes = b.recordFor(b.lineEtypes, line);
      final attrs = b.recordFor(b.lineAttrs, line);
      for (var ci = 0; ci < cells.length && ci < tc.columns.length; ci++) {
        final cell = cells[ci];
        final et = etypes != null && ci < etypes.length ? etypes[ci] : null;
        final at = attrs != null && ci < attrs.length ? attrs[ci] : 0;
        final row = tc.lineRow(line), col = tc.columnOffsets[ci];
        final width = ci < tc.widths.length ? tc.widths[ci] : 0;
        final protected = at & attrProtected != 0;
        final FieldKind kind;
        if (cell.kind == 'pushbutton' || et == etypePushButton2) {
          kind = FieldKind.pushbutton;
        } else if (cell.kind == 'checkbox' || et == etypeCheckButton2) {
          kind = FieldKind.checkbox;
        } else if (cell.kind == 'listbox') {
          kind = FieldKind.combobox;
        } else if (et != null && etypeInput.contains(et) && !protected) {
          kind = FieldKind.input;
        } else {
          kind = FieldKind.output;
        }
        // an empty line's text cells carry the dynpro's `___` template
        var text = cell.value;
        if (kind != FieldKind.pushbutton &&
            text.isNotEmpty &&
            text.split('').every((c) => c == '_')) {
          text = '';
        }
        if (kind == FieldKind.pushbutton) text = cell.buttonText ?? '';
        final len = cell.maxlen ?? width;
        m.fields.add(
          ScreenField(
            kind: kind,
            row: row,
            col: col,
            name: tc.columns[ci],
            text: kind == FieldKind.checkbox ? '' : text,
            on: kind == FieldKind.checkbox && cell.value == 'X',
            fcode: cell.fcode,
            mlen: kind == FieldKind.pushbutton ? width : len,
            maxnrchars: kind == FieldKind.pushbutton ? width : len,
            invisible: at & attrInvisible != 0,
            isProtected: protected,
            attr: at,
            container: tc.name,
            tableControl: tc.name,
            tcLine: line,
            tcColumn: ci + 1,
          ),
        );
      }
    }
  }
}

/// A radio / checkbox atom's display label: its text minus the leading
/// event id (`radiobutton_event_id_len` bytes, e.g. "=STATSEL_CHANGE"
/// before "Groupe …") — reference client screen_atoms `_radio` label `raw[elen:]`.
/// The field's `text` keeps the whole wire text, which a select echoes.
String _radioLabel(DyntAtom a) {
  final t = a.radiobuttonText ?? '';
  final n = a.radiobuttonEventIdLen;
  if (n <= 0 || n >= t.length) return t.trimRight();
  final rest = t.substring(n).trimRight();
  return rest.isEmpty ? t.trimRight() : rest;
}
