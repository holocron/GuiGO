/// The Windows registry the frontend answers CL_GUI_FRONTEND_SERVICES=>
/// REGISTRY_GET_VALUE with (`GetRegValueEx(root, key, value)`, VT_BSTR):
/// GuiGo keeps a Windows PC's Office 16 identity, so the Office install
/// probes read what that PC's registry holds; every other key reads blank,
/// as the recorded GUIs answer them.
///
/// Pinned on the real SAP GUI for Windows with Office 16 (the test system, the ALV
/// grid's probe flush — a recorded session srv[61] -> gui answer at step
/// 97, a recorded session srv[35], a recorded session,
/// a recorded session, a recorded session, a recorded session,
/// a recorded session, a recorded session,
/// a recorded session):
/// * HKEY_CLASSES_ROOT (root 0) `Excel.Application\CurVer` ->
/// `Excel.Application.16`, `Word.Application\CurVer` ->
/// `Word.Application.16`;
/// * `Lotus123.Workbook\CLSID`, `OrgPublisher.Document.2\CLSID`
/// (a recorded session) and HKEY_LOCAL_MACHINE (root 2)
/// `SOFTWARE\Classes\CLSID\{2F848BE4-…}\InprocServer32` `Assembly` ->
/// blank (no Lotus, no OrgPublisher, no such .NET assembly);
/// * HKEY_CURRENT_USER (root 1) `Software\SAP\SAPGUI Front\SAP Frontend
/// Server\Filetransfer` `PathDownload` / `PathUpload` -> blank on the
/// Windows GUI (a recorded session; the macOS Java GUI answers its
/// own folders, a recorded session) — left to the blank default.
///
/// HKEY_CLASSES_ROOT `ExcelWorksheet\protocol\StdFileEditing\server` —
/// the Excel executable XXL_CHECK_API / XXL_FULL_API (function group TXXL,
/// DWDM "Api test simple", XXLSTEST) read as "Excel is installed": a blank
/// one sends the XXL list viewer down its SYLK + XXL_EXPORT_AND_START path
/// (the legacy SAPLGRAP channel) instead of the DOI spreadsheet. The real
/// GUI's value, capital `Root` (a recorded session srv[16]
/// / [24] -> gui[9] / [17]).
///
/// The same InfoCtrl's path probes (`SAPfewin.OCX`), Windows only, VT_BSTR
/// (xxl srv[18] / [20] -> gui[11] / [13]): `GetProgramPath` -> the SAP
/// GUI install folder, which XXL concatenates into its `LISTFILES` paths
/// (srv[25] `…\SAPGUI\XXL\XXLSTART.FLG`); `GetCurrentDirectory` -> the
/// GUI's work folder under the user profile (`…\Documents\SAP\SAP GUI`;
/// the recorded profile part is redacted — a neutral profile name here).
///
/// HKEY_CLASSES_ROOT `Excel.Sheet` (default value) — the Excel worksheet
/// class's name, `Microsoft Excel Worksheet` on the real GUI
/// (a recorded session srv[95] -> the &XXL export's probe,
/// srv[113] / [117] / [123] PC_OLE_SERVER_CHECK's TOLE `EXCEL.SHEET` row).
///
/// DELIBERATELY BLANK, unlike that GUI: the Word Basic class
/// `CLSID\{000209FE-0000-0000-C000-000000000046}` (`Microsoft Word Basic`
/// there, srv[114]) and `Word.Basic\CurVer` (`Word.Basic.9`, srv[136]).
/// PC_OLE_SERVER_CHECK reads the first as "MS Word is installed"
/// (TOLE `WORD.BASIC`): ALV_CHECK_PC_APP then sends the ALV's "Traitement
/// de texte" (&AQW) down RSAQTXT_TEXT_HANDLING / MS_WORD_OLE_FORMLETTER,
/// i.e. OLE2 automation of Word itself (CreateObject('Word.Document'),
/// WordBasic, Documents.Open, MailMerge…) — which GuiGo cannot drive.
/// Blank, the server's own no-Word branch runs (ALV_CHECK_PC_APP answers
/// 0: no automation verb is ever sent); the CreateObject that would be
/// sent anyway is refused ([refusedAutomationVerb]).
///
/// Only the Windows dialect: the Java GUI (macOS) answers every Office
/// probe blank (a recorded session, a recorded session,
/// a recorded session …).
library;

import 'flush_call.dart';

/// The registry-read verbs answered here (CL_GUI_FRONTEND_SERVICES=>
/// REGISTRY_GET_VALUE's `GetRegValueEx`).
const Set<String> registryReadVerbs = {'GetRegValueEx', 'getRegValueEx'};

/// CL_GUI_FRONTEND_SERVICES=>HKEY_CLASSES_ROOT.
const String hkeyClassesRoot = '0';

/// The Excel executable an Office 16 (Click-to-Run) PC registers as the
/// `ExcelWorksheet` OLE server.
const String officeExcelServerPath =
    r'C:\Program Files\Microsoft Office\Root\Office16\EXCEL.EXE';

/// HKEY_CLASSES_ROOT default values (value name '') of the Office 16 PC,
/// keyed by the lower-cased key (the registry ignores case).
const Map<String, String> windowsOfficeClassesRoot = {
  r'excelworksheet\protocol\stdfileediting\server': officeExcelServerPath,
  r'excel.application\curver': 'Excel.Application.16',
  r'word.application\curver': 'Word.Application.16',
  'excel.sheet': 'Microsoft Excel Worksheet',
};

/// The value the Windows Office 16 PC's registry holds for [root] / [key] /
/// [valueName], null when it holds none (the caller's blank).
String? windowsRegistryValue(String root, String key, String valueName) {
  if (root.trim() != hkeyClassesRoot || valueName.trim().isNotEmpty) {
    return null;
  }
  return windowsOfficeClassesRoot[key.trim().toLowerCase()];
}

/// The answer to registry read verb [verbIndex] (1-based) of [call]: the
/// Office identity's value for its (root, key, value name) on the Windows
/// dialect, else null (the type-defaulted blank).
String? registryReadAnswer(FlushCall call, int verbIndex) {
  if (call.dialect != GuiDialect.windows) return null;
  final a = {for (final x in verbArgs(call, verbIndex)) x.$1: x.$2};
  return windowsRegistryValue(a['#1'] ?? '', a['#2'] ?? '', a['#3'] ?? '');
}

/// The SAP GUI for Windows install folder `GetProgramPath` answers.
const String windowsSapGuiProgramPath = r'C:\Program Files\SAP\FrontEnd\SAPGUI';

/// The SAP GUI work folder `GetCurrentDirectory` answers.
const String windowsSapGuiCurrentDirectory =
    r'C:\Users\GuiGo\Documents\SAP\SAP GUI';

/// The SAP GUI temp folder `GetTempPath` answers (CL_GUI_FRONTEND_
/// SERVICES=>GET_TEMP_DIRECTORY): `…\AppData\Local\SAP\SAP GUI\tmp`
/// under the user profile, no trailing separator (a recorded session
/// excel_inplace srv[93] -> gui[75]; the profile part redacted there).
const String windowsSapGuiTempPath =
    r'C:\Users\GuiGo\AppData\Local\SAP\SAP GUI\tmp';

/// The InfoCtrl's answer to path probe [verb] on [dialect], null when it
/// is none (or the dialect's is unrecorded: the Java GUI's).
/// `GetSapWorkDir` is the work folder `GetCurrentDirectory` names
/// (alv_excel_inplace srv[187] -> gui[159], OAOR's download folder).
String? infoCtrlPathAnswer(String verb, GuiDialect? dialect) {
  if (dialect != GuiDialect.windows) return null;
  return switch (verb) {
    'GetProgramPath' => windowsSapGuiProgramPath,
    'GetCurrentDirectory' || 'GetSapWorkDir' => windowsSapGuiCurrentDirectory,
    'GetTempPath' => windowsSapGuiTempPath,
    _ => null,
  };
}
