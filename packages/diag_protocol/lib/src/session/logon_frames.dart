/// The two frames a logon opens with — the DIAG CONNECT frame and the
/// SAPMSYST 0020 LOGON SUBMIT — built from their protocol fields, with no
/// recorded byte blob and no host / user value of a recording.
///
/// Field layouts: pysap's SAPDiagDP (the 200-byte dispatcher head),
/// SAPDiagItems (16/4/2 CONNECT, 16/4/11 SUPPORTDATA, 16/4/13 WSIZE) and the
/// ST_USER item table (SAPDiag.diag_appl_sids[0x04]); the support-flag
/// names from SAPfront.dll's flag table (reference client SAPGUI-windows/
/// support_bits_SAPfront.txt). The VALUES are the ones the reference client's
/// frontend_profile.connect_frame / patch_login_frame put on the wire — the
/// real SAP GUI for Windows 8.00 pl 18 connect (a recorded session
/// gui raw[0]) on the reference fixture's connection words, and the
/// fixture's logon submit re-spelled for the Windows dialect — so a logon
/// built here sends what the fixture-based ladder sent, item for item,
/// except the TERMINAL name (configurable, [defaultLogonTerminal]) and the
/// real Windows GUI's logon-submit atoms the fixture lacks ([logonItems]:
/// the window's first-round trio, the logon identity, the window pixels).
library;

import 'dart:typed_data';

import '../cfw/flush_call.dart' show GuiDialect;
import '../framing/diag_frame.dart';
import '../framing/envelope.dart';
import 'actions.dart' show ActionContext, xmlBlobItem;
import 'frames.dart';
import 'frontend_profile.dart'
    show
        uiEventFunctionKeyJava,
        winCodepageValue,
        winIdentity,
        windowsFirstRoundAtoms;
import 'gui_profile.dart';
import 'login.dart' show loginAtoms;
import 'table_cell.dart' show windowsEventWindowPx;

/// The terminal name a logon presents when the caller names none (the DP
/// head's `terminal`, the label SM04 / AL08 show for the front end).
const String defaultLogonTerminal = 'GUIGO';

/// The message-server-less dispatcher port a connection names when it
/// names none (32NN, instance 00).
const int defaultSapPort = 3200;

/// The logon language a connection names when it names none.
const String defaultLogonLanguage = 'EN';

/// The SAP one-letter language keys and their ISO 639-1 codes (the
/// standard T002 pairs) — [connectLanguage] for a one-letter logon
/// language.
const Map<String, String> _isoOfSapLanguage = {
  'E': 'EN', 'D': 'DE', 'F': 'FR', 'S': 'ES', 'I': 'IT', 'P': 'PT',
  'N': 'NL', 'J': 'JA', 'R': 'RU', 'L': 'PL', 'K': 'DA', 'V': 'SV',
  'O': 'NO', 'U': 'FI', 'C': 'CS', 'Q': 'SK', 'H': 'HR', 'T': 'TR',
  '1': 'ZH', '3': 'KO', 'A': 'AR', 'B': 'HE', 'G': 'EL', 'W': 'BG',
};

/// The ISO language (2 letters) the connect frame's ST_USER 39 names for
/// the logon [language]: a 2-letter code as is (upper case), a SAP
/// one-letter key mapped, anything else (an empty language: the user's
/// default) [defaultLogonLanguage].
String connectLanguage(String language) {
  final l = language.trim().toUpperCase();
  if (l.length == 2 && l.codeUnits.every((c) => c >= 0x41 && c <= 0x5a)) {
    return l;
  }
  return _isoOfSapLanguage[l] ?? defaultLogonLanguage;
}

// ---------------------------------------------------------------------------
// The DP (dispatcher) head
// ---------------------------------------------------------------------------

/// Length of the DP head in front of a connect frame's DIAG payload.
const int dpHeadLen = 200;

/// The 200-byte DP head of a DIAG connect frame (pysap SAPDiagDP). Every
/// multi-byte word is big-endian except [length] (little-endian, the DIAG
/// payload's byte count — set by [toBytes]). The `unused*` words carry the
/// sending GUI's own residue; the kernel validates the head as a whole
/// (reference client live bisect, the test system 2026-09-07: the Windows head verbatim on a
/// foreign connection is `invalid gui data`), so the defaults are the
/// accepted combination.
class DpHead {
  const DpHead({
    this.requestId = -1,
    this.retcode = 0x0a,
    this.senderId = 0,
    this.actionType = 0,
    this.reqInfo = 0,
    this.tid = -1,
    this.uid = -1,
    this.mode = 0xff,
    this.wpId = -1,
    this.wpCaBlk = -1,
    this.appcCaBlk = -1,
    this.newStat = 0,
    this.unused1 = -1,
    this.rqId = -1,
    this.terminal = defaultLogonTerminal,
    this.unused3 = const [],
    this.unused5 = 0,
    this.unused6 = 0,
    this.unused7 = -1,
    this.unused8 = 0,
    this.unused9 = 0x01,
    this.unused10 = const [],
  });

  final int requestId; // i32 @0
  final int retcode; // u8 @4
  final int senderId; // u8 @5
  final int actionType; // u8 @6
  final int reqInfo; // u32 @7
  final int tid; // i32 @11
  final int uid; // i16 @15
  final int mode; // u8 @17
  final int wpId; // i32 @18
  final int wpCaBlk; // i32 @22
  final int appcCaBlk; // i32 @26
  // length: u32 LE @30 — the DIAG payload length
  final int newStat; // u8 @34
  final int unused1; // i32 @35
  final int rqId; // i16 @39
  // unused2: 40 spaces @41
  /// 15 bytes @81, NUL-padded (ASCII; longer names are cut).
  final String terminal;

  /// 10 bytes @96 (zero-padded).
  final List<int> unused3;
  // unused4: 20 spaces @106
  final int unused5; // u32 @126
  final int unused6; // u32 @130
  final int unused7; // i32 @134
  final int unused8; // u32 @138
  final int unused9; // u8 @142

  /// 57 bytes @143 (zero-padded).
  final List<int> unused10;

  DpHead copyWith({String? terminal}) => DpHead(
    requestId: requestId,
    retcode: retcode,
    senderId: senderId,
    actionType: actionType,
    reqInfo: reqInfo,
    tid: tid,
    uid: uid,
    mode: mode,
    wpId: wpId,
    wpCaBlk: wpCaBlk,
    appcCaBlk: appcCaBlk,
    newStat: newStat,
    unused1: unused1,
    rqId: rqId,
    terminal: terminal ?? this.terminal,
    unused3: unused3,
    unused5: unused5,
    unused6: unused6,
    unused7: unused7,
    unused8: unused8,
    unused9: unused9,
    unused10: unused10,
  );

  Uint8List toBytes(int payloadLength) {
    final out = Uint8List(dpHeadLen);
    final bd = out.buffer.asByteData();
    bd.setInt32(0, requestId);
    out[4] = retcode;
    out[5] = senderId;
    out[6] = actionType;
    bd.setUint32(7, reqInfo);
    bd.setInt32(11, tid);
    bd.setInt16(15, uid);
    out[17] = mode;
    bd.setInt32(18, wpId);
    bd.setInt32(22, wpCaBlk);
    bd.setInt32(26, appcCaBlk);
    bd.setUint32(30, payloadLength, Endian.little);
    out[34] = newStat;
    bd.setInt32(35, unused1);
    bd.setInt16(39, rqId);
    out.fillRange(41, 81, 0x20);
    final term = terminal.codeUnits;
    for (var i = 0; i < 15 && i < term.length; i++) {
      out[81 + i] = term[i] < 0x80 ? term[i] : 0x3f; // '?' off ASCII
    }
    _put(out, 96, 10, unused3);
    out.fillRange(106, 126, 0x20);
    bd.setUint32(126, unused5);
    bd.setUint32(130, unused6);
    bd.setInt32(134, unused7);
    bd.setUint32(138, unused8);
    out[142] = unused9;
    _put(out, 143, 57, unused10);
    return out;
  }

  static void _put(Uint8List out, int at, int width, List<int> v) {
    for (var i = 0; i < width && i < v.length; i++) {
      out[at + i] = v[i] & 0xff;
    }
  }
}

/// The DP head's trailing `unused10` as the connect frames send it: 33 zero
/// bytes, eight 0xff, then two little-endian 64-bit words — the reference
/// Java GUI's own process words, the "connection words" the reference client carries
/// over from its fixture (frontend_profile._DP_CONNECTION_WORDS; the
/// Windows GUI's own head has zeros there and is refused on a foreign
/// connection). Numbers, no identity.
Uint8List dpTailWords(int a, int b) {
  final out = Uint8List(57);
  out.fillRange(33, 41, 0xff);
  final bd = out.buffer.asByteData();
  bd.setUint64(41, a, Endian.little);
  bd.setUint64(49, b, Endian.little);
  return out;
}

const int _dpTailA = 0x0000011803103d00, _dpTailB = 0x0000011802f1b5d0;

/// The SAP GUI for Windows' DP head (a recorded session gui raw[0])
/// with the reference client's connection words: rq_id 0 and the [dpTailWords] tail
/// (the fixture's), the terminal neutral.
final DpHead windowsDpHead = DpHead(
  rqId: 0,
  unused3: const [0x00, 0x23, 0x7a, 0x23, 0x23],
  unused5: 0x574e4c4f, // the Windows GUI's buffer residue ("WNLO")
  unused6: 0x41445f43, // ("AD_C")
  unused8: 0xec3afa7f,
  unused10: dpTailWords(_dpTailA, _dpTailB),
);

/// The SAP GUI for Java's DP head (the reference fixture's frame 0), the
/// terminal neutral.
final DpHead javaDpHead = DpHead(
  rqId: 0,
  unused3: const [0x00, 0x00, 0x18, 0x01],
  unused5: 0x0000f008,
  unused6: 0x6f031801,
  unused10: dpTailWords(_dpTailA, _dpTailB),
);

// ---------------------------------------------------------------------------
// The 16/4/11 SUPPORTDATA bitmap
// ---------------------------------------------------------------------------

/// The 32-byte support bitmap with [flags] set (the kernel's LSB-first
/// convention: byte = flag >> 3, mask = 1 << (flag & 7)).
Uint8List supportBitmap(Iterable<int> flags) {
  final out = Uint8List(32);
  for (final f in flags) {
    out[f >> 3] |= 1 << (f & 7);
  }
  return out;
}

/// The support flags the SAP GUI for Windows 8.00 announces (its connect
/// frame's 16/4/11; names from SAPfront.dll).
const List<int> windowsSupportFlags = [
  0, // PROGRESS_INDICATOR
  1, // SAPGUI_LABELS
  2, // SAPGUI_DIAGVERSION
  3, // SAPGUI_SELECT_RECT
  4, // SAPGUI_SYMBOL_RIGHT
  5, // SAPGUI_FONT_METRIC
  6, // SAPGUI_COMPR_ENHANCED
  7, // SAPGUI_IMODE
  8, // SAPGUI_LONG_MESSAGE
  9, // SAPGUI_TABLE
  10, // SAPGUI_FOCUS_1
  11, // SAPGUI_PUSHBUTTON_1
  12, // UPPERCASE
  13, // SAPGUI_TABPROPERTY
  14, // INPUT_UPPERCASE
  17, // FKEY_TABLE
  19, // STOP_TRANS
  20, // FULL_MENU
  21, // OBJECT_NAMES
  22, // CONTAINER_TYPE
  23, // DLGH_FLAGS
  24, // APPL_MNU
  26, // MESDUM_FLAG1
  27, // TABSEL_ATTRIB
  35, // NEW_BSD_JUSTRIGHT
  36, // MESSAGE_VARS
  37, // OCX_SUPPORT
  38, // SCROLL_INFOS
  40, // MESSAGE_INFO2
  41, // VARINFO_OKCODE
  42, // CURR_TCODE
  44, // (unnamed)
  45, // TABSTRIP
  47, // TABSCROLL_INFOS
  48, // TABLE_FIELD_NAMES
  49, // NEW_MODE_REQUEST
  50, // RFCBLOB_DIAG_PARSER
  52, // CONTROL_CONTAINER
  53, // APPTOOLBAR_FIXED
  57, // COMBOBOX
  58, // INPUT_REQUIRED
  59, // ISO_LANGUAGE
  60, // COMBOBOX_TABLE
  62, // CHECKRADIO_EVENTS
  63, // R3INFO_USERID
  65, // USER_TURNTIME2
  66, // NUM_FIELD
  68, // CONTEXT_MENU
  69, // SCROLLABLE_TABSTRIP_PAGE
  70, // EVENT_DESCRIPTION
  71, // LABEL_OWNER
  72, // CLICKABLE_FIELD
  75, // TABLE_ROW_REFERENCES_2
  76, // PROPFONT_VALID
  81, // XML_BLOBS
  82, // RFC_QUEUE
  83, // RFC_COMPRESS
  85, // DPLOADONDEMAND
  86, // CTL_PROPCACHE
  88, // RFC_ASYNC_BLOB
  89, // KEEP_SCROLLPOS
  92, // XML_PROPERTIES
  95, // HAS_CACHE
  96, // XML_PROP_TABLE
  98, // ENJOY_IMODEUUID2
  101, // PROPERTYPUMP
  104, // SUPPBIT_AREA_SIZE
  105, // DPLOADONDEMAND_WRITE
  106, // CONTROL_FOCUS
  107, // ENTRY_HISTORY
  108, // AUTO_CODEPAGE
  109, // CACHED_VSETS
  111, // AREA2FRONT
  112, // SCROLLBAR_WIDTH
  114, // EDIT_VARLEN
  116, // PRINTDATA
  120, // TOOLBAR_HEIGHT
  121, // XMLPROP_CONTAINER
  122, // XMLPROP_DYNPRO
  124, // DYNAMIC_PASSPORT
  127, // CONTROL_FOCUS_ON_LIST
  128, // CBU_RBUDUMMY_2
  129, // EOKDUMMY_1
  130, // GUI_USER_SCRIPTING
  131, // SLC
  133, // ECATT
  134, // ENJOY_IMODEUUID3
  135, // ENABLE_UTF8
  136, // R3INFO_AUTOLOGOUT_TIME
  137, // VARINFO_ICON_TITLE_LIST
  140, // R3INFO_CODEPAGE_APP
  141, // ENABLE_APPL4
  142, // GUIPATCHLEVEL
  145, // GUI_THEME
  146, // TOP_WINDOW
  147, // EVENT_DESCRIPTION_1
  148, // SPLITTER
  149, // VALUE_4_HISTORY
  150, // ACC_LIST
  151, // GUI_USER_SCRIPTING_INFO
  152, // TEXTEDIT_STREAM
  153, // DYNT_NOFOCUS
  155, // FRAME_1
  157, // ACC_LIST_PROPS
  158, // TABSEL_ATTRIB_INPUT
  159, // DEFAULT_TOOLTIP
  160, // XML_PROP_TABLE_2
  161, // CBU_RBUDUMMY_3
  163, // CONTROL_FOCUS_ON_LIST_2
  164, // TABLE_COLUMNWIDTH_INPUT
  166, // OBJECT_NAMES_4_LOGIN_PROCESS
  167, // RFC_SERVER_4_GUI
  168, // R3INFO_FLAGS_2
  172, // R3INFO_KERNEL_VERSION
  174, // EOKDUMMY_2
  176, // SBA2
  178, // GUIPATCHLEVEL_2
  179, // DISPLAY_SIZE
  180, // GUI_PACKET
  181, // DIALOG_STEP_NUMBER
  182, // TC_KEEP_SCROLL_POSITION
  183, // MESSAGE_SERVICE_REQUEST
  184, // DYNT_FOCUS_FRAME
  188, // XMLPROP_LIST_DYNPRO
  191, // ALLWAYS_SEND_CLIENT
  193, // GUI_SIGNATURE_COLOR
  194, // MAX_WSIZE
  198, // AMC
  199, // EXTMODE_FONT_METRIC
  202, // NO_FOCUS_ON_LIST
  205, // MSGINFO_WITH_CODEPAGE
  213, // GUI_SYSTEM_COLOR
  222, // OKCODE_TYPEAHEAD_ALL_RESULTS
];

/// The flags only the Windows GUI sets (vs the Java GUI 8.10).
const Set<int> _windowsOnlyFlags = {
  4,
  37,
  59,
  65,
  71,
  72,
  76,
  107,
  109,
  136,
  150,
  157,
  158,
  164,
  167,
  198,
  222,
};

/// The flags only the Java GUI sets: MENU_SHORTCUT, NOGRAPH, NOSAPSCRIPT,
/// TABLE_SIZE_OK, R3INFO_FLAGS, JAVA_BEANS, CBURBU_NEW_STATE,
/// BINARY_EVENTID, R3INFO_CODEPAGE_APP_1, CELLINFO, VARINFO_CONTAINER_LOOP,
/// MAINAREA_SIZE, MAX_STRING_LEN, VARINFO_CONTAINER_1, STD_TOOLBAR_ITEMS,
/// SAP_PERSONAS, GROUPBOX, AGI_ID_TS_BUTTON, OBJECT_NAMES_ENFORCE,
/// MESDUMMY_FLAGS_2_3, GUIPATCHLEVEL_3, ACTIVE_ENTER_BUTTON, OKCODE_SEARCH,
/// TOOLBARS_SEND_INACTIVE_ITEMS_2.
const Set<int> _javaOnlyFlags = {
  18,
  29,
  33,
  39,
  61,
  84,
  143,
  144,
  154,
  162,
  173,
  177,
  185,
  186,
  187,
  195,
  200,
  201,
  209,
  210,
  216,
  217,
  219,
  220,
};

/// The support flags the SAP GUI for Java 8.10 announces.
final List<int> javaSupportFlags = [
  for (final f in windowsSupportFlags)
    if (!_windowsOnlyFlags.contains(f)) f,
  ..._javaOnlyFlags,
]..sort();

// ---------------------------------------------------------------------------
// The connect frame
// ---------------------------------------------------------------------------

Uint8List _u16(int v) => (ByteData(2)..setUint16(0, v)).buffer.asUint8List();

Uint8List _u32s(List<int> vals) {
  final bd = ByteData(vals.length * 4);
  for (var i = 0; i < vals.length; i++) {
    bd.setUint32(i * 4, vals[i]);
  }
  return bd.buffer.asUint8List();
}

Uint8List _u16s(List<int> vals) {
  final bd = ByteData(vals.length * 2);
  for (var i = 0; i < vals.length; i++) {
    bd.setUint16(i * 2, vals[i]);
  }
  return bd.buffer.asUint8List();
}

/// 16/4/2 CONNECT (pysap SAPDiagUserConnect): protocol version, codepage,
/// workstation type.
Uint8List userConnectItem({
  int protocolVersion = 100200,
  int codePage = 1100,
  required int wsType,
}) => buildApplItem(4, 2, _u32s([protocolVersion, codePage, wsType]));

/// The WSIZE a Windows connect announces when the caller knows no window:
/// the reference GUI's 45 x 272 cells (a recorded session gui
/// raw[0]).
const (int, int) recordedConnectWindowCells = (45, 272);

/// The ST_USER items of a connect frame, in the sending GUI's wire order.
/// Windows: ST_USER 39 names [language] ([connectLanguage]), WSIZE the
/// client [window] (rows, cols — the device-derived window the logon then
/// reports; [recordedConnectWindowCells] when null).
List<Uint8List> connectItems(
  GuiDialect dialect, {
  String language = defaultLogonLanguage,
  (int, int)? window,
}) => switch (dialect) {
  // a recorded session gui raw[0]
  GuiDialect.windows => [
    userConnectItem(wsType: 3000),
    buildApplItem(4, 11, supportBitmap(windowsSupportFlags)),
    // WSIZE (pysap SAPDiagWindowSize): window rows x cols, area rows x cols
    buildApplItem(4, 13, () {
      final (rows, cols) = window ?? recordedConnectWindowCells;
      return _u32s([rows, cols, rows, cols]);
    }()),
    // FONTMETRIC: cell height / width, char height / width (px)
    buildApplItem(4, 4, _u16s([21, 7, 15, 7])),
    buildApplItem(4, 23, _u16(34)), // TOOLBAR_HEIGHT (px)
    buildApplItem(4, 22, _u16(17)), // SCROLLBAR_WIDTH (px)
    // ST_USER 39 (past pysap's table): the GUI's ISO language
    buildApplItem(4, 39, Uint8List.fromList(connectLanguage(language).codeUnits)),
  ],
  // the reference fixture's frame 0 (SAP GUI for Java 8.10)
  GuiDialect.java => [
    userConnectItem(codePage: 1127, wsType: 5004),
    buildApplItem(4, 11, supportBitmap(javaSupportFlags)),
    buildApplItem(4, 37, _u16(2)), // GUI_TYPE
    buildApplItem(4, 9, Uint8List.fromList('810'.codeUnits)), // GUIVERSION
  ],
};

/// The DIAG CONNECT frame (frame 0 of a logon): the DP head, then the
/// uncompressed DIAG payload — the 8-byte header (mode 0, com_flag
/// TERM_INI) and the dialect's ST_USER items ([connectItems]: the logon
/// [language], the client [window]). [terminal] replaces the head's
/// terminal name ([defaultLogonTerminal] when null); [head] the whole head
/// (tests, A/B probes).
Uint8List buildConnectFrame({
  required GuiDialect dialect,
  String? terminal,
  DpHead? head,
  String language = defaultLogonLanguage,
  (int, int)? window,
}) {
  final body = BytesBuilder(copy: false)
    ..add(Uint8List.fromList([0, comFlagTermIni, 0, 0, 0, 0, 0, 0]));
  for (final it in connectItems(dialect, language: language, window: window)) {
    body.add(it);
  }
  final payload = body.takeBytes();
  var h = head ?? (dialect == GuiDialect.windows ? windowsDpHead : javaDpHead);
  if (terminal != null) h = h.copyWith(terminal: terminal);
  return Uint8List.fromList([...h.toBytes(payload.length), ...payload]);
}

// ---------------------------------------------------------------------------
// The logon submit
// ---------------------------------------------------------------------------

/// The client-window figures a logon submit reports (all in the SAP GUI's
/// own units). The defaults are the reference logon's (the reference client
/// fixture's SAPMSYST 0020 submit, a 26 x 146 window): the kernel takes the
/// negotiated screen from the SES dims and the METRICS XML, which
/// [buildLogonFrame] computes from the requested rows / cols; these ride
/// as sent. The window's own atoms (16/4/4, 16/4/36, 16/4/40, 16/12/8) are
/// the session window's ([logonItems] `window`), the toolbar / scrollbar
/// the real Windows GUI's (= its connect frame's own 16/4/23 / 16/4/22).
class LogonGeometry {
  const LogonGeometry({
    this.toolbarHeight = 0x22,
    this.scrollbarWidth = 0x11,
    this.viewportPx = (938, 1694),
    this.areaRows = 26,
    this.areaCols = 146,
    this.visibleRows = 22,
    this.visibleCols = 84,
    this.scrollRow = 19,
    this.scrollCol = 91,
    this.passwordCursorOffset = 8,
    this.cellWidth = metricsCellX,
    this.cellHeight = metricsCellY,
  });

  /// 16/4/23 TOOLBAR_HEIGHT, 16/4/22 SCROLLBAR_WIDTH (px).
  final int toolbarHeight, scrollbarWidth;

  /// 16/4/42 (height, width px) — the reference client fixture's; the real Windows
  /// logon submit sends none.
  final (int, int) viewportPx;

  /// The logon dynpro's area and visible part (chars) and its scroll
  /// position, as the OK event / SCROLL_INFOS2 / container items spell them.
  final int areaRows, areaCols, visibleRows, visibleCols, scrollRow, scrollCol;

  /// The cursor's offset inside RSYST-BCODE (16/9/11, the OK event's col).
  final int passwordCursorOffset;

  /// The METRICS XML cell size (px): X3 = cols x [cellWidth], Y3 = rows x
  /// [cellHeight].
  final int cellWidth, cellHeight;
}

/// The SAPMSYST 0020 logon dynpro: RSYST-BCODE's row / col (login.dart
/// loginPlanes0020).
const int _bcodeRow = 3, _bcodeCol = 20;

/// The 16/5/1 OK event of the logon submit (22 bytes, actions.dart
/// _okEvent layout): mode 0x05 (field submit), the cursor, the area /
/// visible rectangle (b7 = the constant modification flag 0x29), scroll.
Uint8List _logonOkEvent(LogonGeometry g) {
  final ok = Uint8List(22);
  ok[1] = 0x05;
  ok[4] = _bcodeRow;
  ok[5] = (_bcodeCol + g.passwordCursorOffset) & 0xff;
  ok[6] = g.visibleRows & 0xff;
  ok[7] = 0x29;
  ok[8] = g.areaCols & 0xff;
  ok[9] = g.visibleCols & 0xff;
  ok[10] = g.areaRows & 0xff;
  ok[11] = g.areaCols & 0xff;
  ok[13] = g.scrollRow & 0xff;
  ok[16] = g.scrollCol & 0xff;
  return ok;
}

/// The METRICS DATAMANAGER XML of the logon submit (the window size in px).
Uint8List logonMetricsXml(
  int rows,
  int cols, [
  LogonGeometry g = const LogonGeometry(),
]) => Uint8List.fromList(
  ('<?xml version="1.0" encoding="sap*"?>\n<DATAMANAGER>'
          '<COPY id="copy"><GUI id="gui">'
          '${metricsElement(rows, cols, cellX: g.cellWidth, cellY: g.cellHeight)}'
          '</GUI></COPY></DATAMANAGER>')
      .codeUnits,
);

/// The logon submit's items in wire order, the Windows dialect: the real
/// SAP GUI for Windows' logon submit (a recorded session gui[1],
/// a recorded session gui[1]) — Step, SES (eventarray 0x50), the
/// window's first-round trio 16/4/4 FONTMETRIC + 16/4/36 DISPLAY_SIZE +
/// 16/4/40 MAINAREA_SIZE right after the SES (frontend_profile
/// windowsFirstRoundAtoms: mode 0's first round IS the logon submit, so no
/// later round of the logon window owes them), 16/4/23 TOOLBAR_HEIGHT,
/// 16/4/22 SCROLLBAR_WIDTH, the Windows codepage, the logon-only identity
/// 16/4/31 / 32 / 33 / 37 (the [profile]'s EmulatedGuiProfile
/// .logonIdentity; the host's — EmulatedGuiProfile.host — when null) then
/// the per-frame
/// [winIdentity], the OK event, 16/12/8 the window pixels (the session
/// window's — [window], the reference 853 x 1880 unless sized), the
/// container reset, the credential atoms, the cursor, the METRICS XML.
/// GuiGo keeps three items of the reference client fixture the real submit does not
/// carry (16/4/42, the 16/12/6 SCROLL_INFOS2, the Java 16/15/1) and the
/// fixture's spelling of the SES dims (rows / cols), the OK event, the
/// 16/10/1 and the METRICS block.
List<Uint8List> logonItems({
  String? client,
  required String user,
  required String password,
  String language = '',
  int screenRows = 40,
  int screenCols = 146,
  int step = 1,
  LogonGeometry geometry = const LogonGeometry(),
  ActionContext? window,
  EmulatedGuiProfile? profile,
}) {
  final g = geometry;
  final identity = (profile ?? EmulatedGuiProfile.host()).logonIdentity;
  final w = window ?? ActionContext();
  final ses = Uint8List(17)
    ..[0] = itemSes
    ..[1] =
        0x50 // the Windows FKEY event, eventid1 0 (Enter)
    ..[15] = screenRows & 0xff
    ..[16] = screenCols & 0xff;
  final cursor = Uint8List(10)
    ..[0] =
        1 // depth 1, area 0
    ..buffer.asByteData().setUint16(1, _bcodeRow)
    ..buffer.asByteData().setUint16(3, _bcodeCol)
    ..buffer.asByteData().setUint32(5, g.passwordCursorOffset);
  final atoms = BytesBuilder(copy: false);
  for (final a in loginAtoms(client, user, password, language)) {
    atoms.add(a);
  }
  return [
    stepItem(step),
    ses,
    ...windowsFirstRoundAtoms(w),
    buildApplItem(4, 23, _u16(g.toolbarHeight)),
    buildApplItem(4, 22, _u16(g.scrollbarWidth)),
    buildApplItem(6, 35, winCodepageValue),
    for (final (sid, value) in identity) buildApplItem(4, sid, value),
    for (final (sid, value) in winIdentity) buildApplItem(4, sid, value),
    buildApplItem(4, 42, _u32s([g.viewportPx.$1, g.viewportPx.$2])),
    buildApplItem(5, 1, _logonOkEvent(g)),
    buildApplItem(12, 8, windowsEventWindowPx(w)),
    // SCROLL_INFOS2: scroll pair, area, (0, 0), visible part, flag 1
    buildApplItem(
      12,
      6,
      Uint8List.fromList([
        ..._u32s([
          g.scrollRow,
          g.scrollCol,
          g.areaRows,
          g.areaCols,
          0,
          0,
          g.visibleRows,
          g.visibleCols,
        ]),
        1,
      ]),
    ),
    // 16/10/1 container: the visible part (cols @6, rows @8)
    buildApplItem(
      10,
      1,
      Uint8List(9)
        ..[6] = g.visibleCols & 0xff
        ..[8] = g.visibleRows & 0xff,
    ),
    buildAppl4Item(9, 2, atoms.takeBytes()), // the credential DyntAtoms
    buildApplItem(15, 1, uiEventFunctionKeyJava(0)),
    buildApplItem(9, 11, cursor), // the cursor in RSYST-BCODE
    xmlBlobItem(logonMetricsXml(screenRows, screenCols, g)),
    eomBytes,
  ];
}

/// The LOGON SUBMIT (frame 1 of a logon): [logonItems] LZH-compressed in
/// mode 0, the Windows-dialect frame the kernel answers with the Easy
/// Access ladder.
Uint8List buildLogonFrame({
  String? client,
  required String user,
  required String password,
  String language = '',
  int screenRows = 40,
  int screenCols = 146,
  int step = 1,
  LogonGeometry geometry = const LogonGeometry(),
  ActionContext? window,
  EmulatedGuiProfile? profile,
}) => clientFrame(
  logonItems(
    client: client,
    user: user,
    password: password,
    language: language,
    screenRows: screenRows,
    screenCols: screenCols,
    step: step,
    geometry: geometry,
    window: window,
    profile: profile,
  ),
);
