/// The files the server has the FRONTEND write, delete and open — the
/// CL_GUI_FRONTEND_SERVICES file services on the SAP GUI for Windows'
/// `SAPGUI.InfoCtrl.1` and DataProvider — and the Office automation
/// GuiGo refuses.
///
/// Wire (the real SAP GUI for Windows with Office 16, the test system,
/// a recorded session; kept indices):
/// * `FileSaveDialogEx(title, ext, file name, filter, dir, encoding,
/// prompt)` (FILE_SAVE_DIALOG, srv[105] -> gui[86]) answers t8
/// `<rc>;<full path>` — the Windows OCX leaves rc EMPTY
/// (`;C:\test\EXPORT_20261014_163925.xlsx`), the Java GuiSapInfo writes
/// `0;` (a recorded session gui[12]); the ABAP SPLITs at `;` and reads
/// a blank rc as 0, a blank path as cancel. The headless frontend has no
/// dialog: it takes the server's proposal — the initial folder (`C:\\TEMP`
/// on the wire: its doubled separators collapsed) and file name;
/// * `SecureSaveDataToUrl(APPLICATION, X-UNKNOWN, file://<path>)` on a
/// DataProvider object loaded by `SetDataFromUrl` in the same flush
/// (GUI_DOWNLOAD; the ALV export's server-built .xlsx srv[107], OAOR's
/// RTF srv[191], the Word form letter's data srv[133]) writes that push
/// to the PC — held here, keyed by the path;
/// * `ShellExecute('OPEN', <path>, '', '', '5')` (EXECUTE, srv[109] /
/// [193]) opens it: t3 `42` (> 32 = success). A held file is handed to
/// the user ([FrontendFileStore.opened] — the app's share sheet /
/// viewer, the iPad's "open with"); any other local path stays `0`
/// (browser_launch.dart [shellExecuteAnswer]);
/// * `DeleteFile(<path>)` (FILE_DELETE, srv[131] / [144]) answers t2 the
/// Win32 code: `0` deleted (a held file is dropped), `2` not found.
///
/// The Office applications' OLE2 automation (ole2incl: CREATE OBJECT
/// 'Word.Document' — the ALV's "Traitement de texte" form letter, srv[138]
/// `CreateObject('Word.Document', 1033)` then Application / WordBasic /
/// Documents.Open / FileSaveAs / MailMergeOpenDataSource…) drives Word or
/// Excel themselves: GuiGo hosts neither. The CreateObject's queue is
/// refused with SAPLOLEA's error envelope `CALL_METHOD_FAILED` — the one
/// the real GUI answers a ProgID it cannot create (a recorded session
/// srv[20] -> gui[13], `CreateObject('No.Such.Application')`; ABAP
/// sy-subrc 2): the whole queue, no result row (a recorded session
/// gui[24]). Fail-open (a fresh handle per getter, as before) the program
/// believed Word ran and went on writing files and mail-merging nothing.
library;

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'browser_launch.dart' show verbArgText;
import 'dp_cache.dart';
import 'flush_call.dart';
import 'frontend_registry.dart' show windowsSapGuiCurrentDirectory;

/// One file the server had the frontend write.
class FrontendFile {
  FrontendFile({required this.path, required this.bytes, required this.step});

  /// The Windows path the server wrote it to (`C:\test\EXPORT_….xlsx`).
  final String path;

  /// The content as pushed (bounded by the push's TOTALSIZE).
  final Uint8List bytes;

  /// The dialog step of the flush that wrote it.
  final int step;

  /// The file's name: [path]'s last component (`EXPORT_….xlsx`,
  /// `DEMOWORD97RTF1` — OAOR names a BDS document without an extension).
  String get name {
    final i = path.lastIndexOf(RegExp(r'[\\/]'));
    return i < 0 ? path : path.substring(i + 1);
  }

  @override
  String toString() => 'FrontendFile($name, ${bytes.length} B, step $step)';
}

/// The files the server wrote to this frontend, and those it opened.
class FrontendFileStore {
  /// Files kept at most / bytes kept at most (the oldest out first): a long
  /// session of exports never grows without bound.
  static const int maxFiles = 32;
  static const int maxBytes = 64 << 20;

  final Map<String, FrontendFile> _files = {};

  /// The files a ShellExecute opened, oldest first, until the session
  /// hands them to the app ([takeOpened]).
  final List<FrontendFile> _opened = [];

  int get length => _files.length;

  /// The file held at [path] (case-insensitive, `/` or `\`), null when none.
  FrontendFile? operator [](String path) => _files[frontendPathKey(path)];

  void hold(FrontendFile f) {
    final k = frontendPathKey(f.path);
    _files
      ..remove(k)
      ..[k] = f;
    var total = 0;
    for (final x in _files.values) {
      total += x.bytes.length;
    }
    while (_files.length > maxFiles ||
        (total > maxBytes && _files.length > 1)) {
      final first = _files.keys.first;
      total -= _files.remove(first)!.bytes.length;
    }
  }

  /// Drop the file at [path]; whether one was held.
  bool delete(String path) => _files.remove(frontendPathKey(path)) != null;

  void noteOpened(FrontendFile f) {
    _opened.add(f);
    if (_opened.length > maxFiles) _opened.removeAt(0);
  }

  /// The files opened since the last call, oldest first.
  List<FrontendFile> takeOpened() {
    final out = List<FrontendFile>.of(_opened);
    _opened.clear();
    return out;
  }

  void clear() {
    _files.clear();
    _opened.clear();
  }
}

/// [path] as a store key: a `file://` url's path, `/` as `\`, doubled
/// separators collapsed, lower case (the Windows file system ignores case).
String frontendPathKey(String path) => windowsPathOf(path).toLowerCase();

/// [text] (a path or a `file://` url) as a Windows path: the url's scheme
/// stripped (`file://C:\x`, `file:///C:/x`), `/` as `\`, runs of
/// separators collapsed (FileSaveDialogEx's `C:\\TEMP`), trimmed.
String windowsPathOf(String text) {
  var p = text.trim();
  if (p.toLowerCase().startsWith('file:')) {
    p = p.substring(5);
    while (p.startsWith('/') || p.startsWith(r'\')) {
      p = p.substring(1);
    }
  }
  p = p.replaceAll('/', r'\');
  // a UNC path keeps its leading pair
  final unc = p.startsWith(r'\\');
  p = p.replaceAll(RegExp(r'\\{2,}'), r'\');
  return unc ? '\\$p' : p;
}

/// The Windows answer to `FileSaveDialogEx` verb [i] (1-based) of [call]:
/// `;<initial folder>\<proposed file name>` (the rc field empty — see the
/// library doc), the folder defaulting to the SAP GUI work folder, the
/// default extension added to a name without one. Null when the server
/// proposed no file name (the blank answer: the ABAP's cancel).
String? fileSaveDialogExAnswer(FlushCall call, int i) {
  final name = (verbArgText(call, i, '#3') ?? '').trim();
  if (name.isEmpty) return null;
  var dir = windowsPathOf(verbArgText(call, i, '#5') ?? '');
  if (dir.isEmpty) dir = windowsSapGuiCurrentDirectory;
  if (dir.endsWith(r'\')) dir = dir.substring(0, dir.length - 1);
  final ext = (verbArgText(call, i, '#2') ?? '').trim();
  final file = ext.isNotEmpty && !name.contains('.') ? '$name.$ext' : name;
  return ';$dir\\$file';
}

/// The DataProvider file write verb.
const Set<String> fileWriteVerbs = {'SecureSaveDataToUrl'};

/// The file delete verbs (InfoCtrl / Java GuiSapInfo).
const Set<String> fileDeleteVerbs = {'DeleteFile', 'deleteFile'};

/// The shell open verbs (browser_launch.dart [shellExecuteVerbs]).
const Set<String> fileOpenVerbs = {
  'ShellExecute',
  'ShellExecuteEx',
  'shellExecute',
  'shellExecuteEx',
};

/// Fold [call] into [store] BEFORE it is answered: the files its
/// SecureSaveDataToUrl verbs write (the push its DataProvider was loaded
/// from — [cache], else the call's own pushes), the ones it deletes and
/// opens, in verb order. Returns {0-based VARS row: value} for the
/// answers it decides — DeleteFile `0` / `2`, ShellExecute `42` for a
/// held file (merged into the answer's prop store).
Map<int, Uint8List> frontendFilesObserveCall(
  FrontendFileStore store,
  DpCache cache,
  FlushCall call, {
  int step = 0,
}) {
  final out = <int, Uint8List>{};
  final verbs = call.verbs;
  if (verbs.isEmpty) return out;
  if (!verbs.any(
    (v) =>
        fileWriteVerbs.contains(v) ||
        fileDeleteVerbs.contains(v) ||
        fileOpenVerbs.contains(v),
  )) {
    return out;
  }
  final meta = verbMeta(call);
  DpCache? own;
  // the DataProvider object row -> the url its SetDataFromUrl loaded
  final loaded = <String, String>{};
  String? lastLoaded;
  void put(String? res, String v) {
    final n = int.tryParse((res ?? '').trim());
    if (n != null && n >= 1) out[n - 1] = Uint8List.fromList(utf8.encode(v));
  }

  for (var i = 1; i <= verbs.length; i++) {
    final verb = verbs[i - 1];
    final m = meta[i - 1];
    if (verb == 'SetDataFromUrl') {
      final u = (verbArgText(call, i, '#3') ?? '').trim();
      if (u.startsWith('SAPR3://')) {
        loaded[m.obj.trim()] = u;
        lastLoaded = u;
      }
    } else if (fileWriteVerbs.contains(verb)) {
      final target = (verbArgText(call, i, '#3') ?? '').trim();
      if (!target.toLowerCase().startsWith('file:')) continue;
      final src = loaded[m.obj.trim()] ?? lastLoaded;
      if (src == null) continue;
      final seg =
          cache.byUrl[src] ??
          (own ??= DpCache()..ingestValue(call.raw)).byUrl[src];
      final bytes = seg == null ? null : _pushedFile(seg);
      if (bytes == null) continue;
      store.hold(
        FrontendFile(path: windowsPathOf(target), bytes: bytes, step: step),
      );
    } else if (fileDeleteVerbs.contains(verb)) {
      final p = verbArgText(call, i, '#1') ?? '';
      // ERROR_FILE_NOT_FOUND unless the server wrote it here
      put(m.result, store.delete(p) ? '0' : '2');
    } else if (fileOpenVerbs.contains(verb)) {
      final f = store[verbArgText(call, i, '#2') ?? ''];
      if (f == null) continue;
      store.noteOpened(f);
      put(m.result, '42');
    }
  }
  return out;
}

/// The bytes push [seg] delivers, bounded by its TOTALSIZE (the records
/// are padded past the file), null when it carries none.
Uint8List? _pushedFile(Uint8List seg) {
  final c = dpPutContent(seg);
  if (c == null || c.content.isEmpty) return null;
  final total = dpTotalSize(seg);
  final data = total > 0 && total < c.content.length
      ? Uint8List.sublistView(c.content, 0, total)
      : c.content;
  return Uint8List.fromList(data);
}

/// The 1-based index of the verb of [call] that creates an Office
/// application's automation object (`CreateObject('Word.Document' |
/// 'Word.Basic' | 'Excel.Application' | …)`), which GuiGo refuses — the
/// whole queue answered SAPLOLEA's `CALL_METHOD_FAILED`; null when none.
int? refusedAutomationVerb(FlushCall call) {
  for (var i = 1; i <= call.verbs.length; i++) {
    if (call.verbs[i - 1] != 'CreateObject') continue;
    final cls = (verbArgText(call, i, '#1') ?? '').trim();
    if (officeAutomationProgIdRx.hasMatch(cls)) return i;
  }
  return null;
}

/// The Office applications' own ProgIDs (`Word.Document`, `WORD.BASIC`,
/// `Excel.Application`, `PowerPoint.Application`, `Outlook.Application`,
/// …): their OLE automation drives the application itself. The SAP
/// classes the DOI and the frontend services create (`SAP.Office
/// Integration.Manager.1`, `SAPGUI.InfoCtrl.1`, the DataProvider CLSID)
/// never match.
final RegExp officeAutomationProgIdRx = RegExp(
  r'^(word|excel|powerpoint|outlook|msaccess|access|visio|msproject)\.',
  caseSensitive: false,
);

/// SAPLOLEA's automation error envelope's exception (a recorded session
/// gui raw[15], a recorded session gui[13] / [24]).
const String oleCallMethodFailed = 'CALL_METHOD_FAILED';
