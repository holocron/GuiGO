/// OLE_FLUSH_CALL parsing — verbs, arguments, result slots, cached props
/// (ea_flushcall port, DOI-relevant subset).
library;

import 'dart:typed_data';

import '../framing/decode_stats.dart';
import 'svars.dart';

/// concrete VARIANT return type per method (result_types.METHOD_TYPE + the
/// DOI table, 501+ entries mined from the reference engine).
const Map<String, int> methodType = {
  'ABAPSelItemKey': 8, 'ABAPSelItemName': 8, 'ABAPSelNodeKey': 8,
  'ACTIVATE': 0, 'ACTIVEDOCUMENT': 9, 'ACTIVESHEET': 9, 'ACTIVEWORKBOOK': 9,
  'ADD': 9, 'APPLICATION': 9, 'AUTOFIT': 0, 'Activate': 0,
  'ActiveDocument': 9, 'ActiveSheet': 9, 'ActiveWorkbook': 9, 'Add': 9,
  'AddButton': 0, 'AddControl': 20, 'AddEx2': 9, 'AddInternalTable': 3,
  'AddMenu': 3, 'AddMenuBar': 3, 'AddMenuItem': 3, 'AddMultiple': 0,
  'AddSchema2': 3, 'AddStringItem': 3, 'AddStringItem2': 3,
  'Application': 9, 'AssignProperty2': 0, 'AutoFit': 0, 'AutoRedraw': 0,
  'AutoZoom': 3, 'Autofit': 0, 'BORDERS': 9, 'BackColor': 20, 'Border': 3,
  'Borders': 9, 'BrowseForFolder': 8, 'CELL': 9, 'CELLS': 9, 'CHARTS': 9,
  'CLEAR': 0, 'CLIPBOARDEXPORT': 2, 'CLOSE': 0, 'COLUMNS': 9, 'COPY': 0,
  'CalcInterval': 8, 'Cell': 9, 'Cells': 9, 'Charts': 9,
  'CheckRegisteredProgIDs': 3, 'Clear': 0, 'ClipboardExport': 2, 'Close': 0,
  'CloseDocument': 3, 'Color': 20, 'Colors': 9, 'Columns': 9, 'Copy': 0,
  'Count': 3, 'CreateBitmapWindow': 9, 'CreateControl': 9,
  'CreateControl2': 9, 'CreateDirectory': 20, 'CreateDocument': 3,
  'CreateObject': 9, 'CreateScreenshot': 8, 'CreateTable': 9,
  'CreateTextWindow': 9, 'CrossHairs': 3, 'CurrentCellCol': 20,
  'CurrentCellColID': 8, 'CurrentCellColIDNumeric': 20,
  'CurrentCellColumn': 8, 'CurrentCellRow': 20, 'CurrentCellRowID': 8,
  'CurrentCellRowIDNumeric': 20, 'CurrentCellRowIDSubNumeric': 20,
  'CurrentCellText': 8, 'DELETE': 0, 'DOCUMENTS': 9, 'Delete': 0,
  'DeleteFile': 20, 'DeleteRange': 3, 'DeleteRegKey': 20,
  'DeleteRegValue': 20, 'DirectoryExists': 20, 'DisableHistoryForField': 20,
  'Documents': 9, 'DrawMode': 3, 'DropEvtParam': 9, 'END': 9, 'Effect': 19,
  'EnableSAPSSO': 3, 'End': 9, 'Events': 20, 'Exec': 20, 'ExecuteMacro': 3,
  'ExecuteNew': 20, 'FONT': 9, 'FileCopy': 20, 'FileExists': 11,
  'FileOpenDialog': 20, 'FileSaveDialog': 8, 'FileSaveDialogEx': 8,
  'FirstVisibleCol': 20, 'FirstVisibleColID': 8,
  'FirstVisibleColIDNumeric': 20, 'FirstVisibleLine': 20,
  'FirstVisibleRow': 20, 'FirstVisibleRowID': 8,
  'FirstVisibleRowIDNumeric': 20, 'FirstVisibleRowIDSubNumeric': 20,
  'Flavor': 8, 'FlavorCount': 20, 'Font': 9, 'FontName': 8, 'FontSize': 20,
  'Fonts': 9, 'Force': 9, 'ForeColor': 20, 'FreeObject': 0,
  'GetABAPDragDropID': 20, 'GetABAPLastErrorID': 20,
  'GetABAPLastErrorItemName': 8, 'GetABAPName': 8, 'GetABAPSelItemKey': 8,
  'GetABAPSelItemName': 8, 'GetABAPSelNodeKey': 8, 'GetABAPSelectCols': 11,
  'GetActiveSheet': 8, 'GetAllfields': 3, 'GetBackColor': 20,
  'GetBeanSubtype': 8, 'GetCellFormat2': 3, 'GetCharsetString': 8,
  'GetCheckBoxState': 20, 'GetClickHeaders': 11, 'GetColumnCount': 20,
  'GetColumnWidth': 20, 'GetComputerName': 8, 'GetContainer': 20,
  'GetCurrentCellCol': 20, 'GetCurrentCellColID': 8,
  'GetCurrentCellColIDNumeric': 20, 'GetCurrentCellColumn': 8,
  'GetCurrentCellRow': 20, 'GetCurrentCellRowID': 8,
  'GetCurrentCellRowIDNumeric': 20, 'GetCurrentCellRowIDSubNumeric': 20,
  'GetCurrentCellText': 8, 'GetCurrentDirectory': 8, 'GetDataAsFormat': 9,
  'GetDefaultInsertsDrop': 11, 'GetDesktopDirectory': 8, 'GetDimension': 3,
  'GetDocumentProxyInterface': 9, 'GetDownloadPath': 8, 'GetDriveType': 8,
  'GetDroppedFiles': 8, 'GetEnvVariable': 8, 'GetEventParam': 8,
  'GetEvents': 20, 'GetExpandOnDblClick': 11, 'GetFileAttribute': 11,
  'GetFileInfo': 8, 'GetFileSeparator': 8, 'GetFileSize': 20,
  'GetFileSizeLong': 20, 'GetFirstVisibleCol': 20, 'GetFirstVisibleColID': 8,
  'GetFirstVisibleColIDNumeric': 20, 'GetFirstVisibleRow': 20,
  'GetFirstVisibleRowID': 8, 'GetFirstVisibleRowIDNumeric': 20,
  'GetFirstVisibleRowIDSubNumeric': 20, 'GetFreeSpaceForDrive': 20,
  'GetFreeSpaceForDriveLong': 20, 'GetFullPathName': 8, 'GetGuiFeatures': 8,
  'GetGuiServices': 9, 'GetGuiVersion': 20, 'GetHideSelection': 11,
  'GetHierarchyHeaderWidth': 20, 'GetID': 20, 'GetIPAddress': 8,
  'GetIconFlag': 11, 'GetIndentation': 20, 'GetIsHighLighted': 20,
  'GetItemText': 8, 'GetItemType': 20, 'GetKeyString': 8,
  'GetListDisplay': 11, 'GetMinimumHeight': 20, 'GetMoveHeaders': 11,
  'GetNextNodeKey': 8, 'GetNodeChildrenCount': 20,
  'GetNodeChildrenCountByKey': 20, 'GetNodeChildrenCountByPath': 20,
  'GetNodeKeyByPath': 8, 'GetNodePathByKey': 8, 'GetNodeTextByKey': 8,
  'GetNodeTextByPath': 8, 'GetNodeType': 20, 'GetNodeTypeString': 8,
  'GetOperatingSystem': 8, 'GetOperatingSystemVersion': 8, 'GetParent': 8,
  'GetParentNodeKey': 8, 'GetPlatformEx': 3, 'GetPreviousNodeKey': 8,
  'GetProfileString': 8, 'GetProgramName': 8, 'GetProgramPath': 8,
  'GetProperty': 8, 'GetProtection': 8, 'GetRangesData2': 3,
  'GetRegDWValueEx': 20, 'GetRegValue': 8, 'GetRegValueEx': 8,
  'GetRowCount': 20, 'GetRowHeight': 20, 'GetSapLogonCodepage': 20,
  'GetSapWorkDir': 8, 'GetScreenUpdate': 11, 'GetScrollbars': 20,
  'GetSelectMode': 20, 'GetSelectedNode': 8, 'GetSelectionMode': 20,
  'GetServiceByName': 9, 'GetSheets2': 3, 'GetSrcProp': 9,
  'GetSystemDirectory': 8, 'GetTable': 9, 'GetTargetProp': 9,
  'GetTempPath': 8, 'GetText': 8, 'GetTopNode': 8, 'GetTopNodeKey': 8,
  'GetTreeType': 20, 'GetTypeId': 8, 'GetUploadPath': 8, 'GetUserName': 8,
  'GetVisibleRowCount': 20, 'GetWindowsBuildNumber': 8,
  'GetWindowsDirectory': 8, 'GetWindowsPlatform': 20, 'GetWindowsVersion': 8,
  'GetWithHeader': 11, 'Grid': 3, 'GridHStep': 5, 'GridHStepUnit': 3,
  'GridModified': 11, 'GridStyle': 3, 'GridVStep': 5, 'GridVStepUnit': 3,
  // the DOI proxy's "did the document change?" — CL_FP_FB_TEMPLATE_DESIGNER
  // ->has_changed (read on the test system) pulls ret_value into `DATA return_value
  // TYPE i VALUE 1` and compares `return_value = 0`: the answer MUST be a
  // numeric zero, anything else (or a retcode non-zero) reads CHANGED and
  // SFP's pai_layout pops FPUIFB 051 — the 'Impossible de sauvegarder
  // modifications de mise en forme en mode affich.!' Information modal —
  // when the user works in the read-only Designer (live the test system/the test system). So a
  // plain VT_I4 '0' like its sibling DOI methods: the VT_BOOL '0' reached
  // the i as 1/failed, and a blank BSTR converts worse.
  'HasDocumentChanged': 3, 'HasDocumentInterface': 3, 'Headers': 9,
  'HideRows': 3, 'HierarchyHeader': 9, 'INTERIOR': 9, 'Image': 9,
  'InitControl': 3, 'InitViewers': 8, 'InsertEx': 9, 'InsertHierarchy': 9,
  'InsertRange': 3, 'Interior': 9, 'IsFolder': 11, 'IsScriptingActive': 20,
  'IsSimpleTree': 11, 'IsTerminalServicesRunning': 8, 'IsTextModified': 11,
  'ItemEx': 9, 'Kill': 0, 'LISTFILES': 20, 'LastError': 3,
  'LastErrorString': 8, 'LastVisibleLine': 20, 'Level': 9, 'LinkContainer': 0,
  'ListFiles': 20, 'ListFilesExt': 20, 'LoadImageFromURL': 3,
  'MajorGrid': 3, 'MajorGridHStep': 5, 'MajorGridHStepUnit': 3,
  'MajorGridStyle': 3, 'MajorGridVStep': 5, 'MajorGridVStepUnit': 3,
  'MessageBox': 20, 'Nodes': 9, 'OpenDocument': 3,
  'OpenDocumentOrApplication': 20, 'PAGESETUP': 9, 'PARAGRAPHFORMAT': 9,
  'PARAGRAPHS': 9, 'PASTE': 0, 'PageSetup': 9, 'ParagraphFormat': 9,
  'Paragraphs': 9, 'Paste': 0, 'PostData': 9, 'PropName': 8, 'PropValue': 8,
  'ProtectDocument': 3, 'PublishUrl': 11, 'QUIT': 0, 'Quit': 0, 'RANGE': 9,
  'ROWS': 9, 'Range': 9, 'RegisterCachedProp': 0, 'RegisterEvent': 0,
  'RegisterOcxEvent': 0, 'RegisterServer': 20, 'ReleaseAllDocuments': 3,
  'ReleaseDocument': 3, 'RemoveDataObject': 0, 'RemoveDirectory': 20,
  'ResetUserInfo': 0, 'RowHeight': 20, 'Rows': 9, 'Ruler': 3,
  'RulerGridTicks': 3, 'RulerMajorGridText': 3, 'SAVE': 0, 'SAVEAS': 0,
  'SAVEAS2': 0, 'SELECT': 0, 'SELECTION': 9, 'SETFONT': 9, 'SHADING': 9,
  'SHEETS': 9, 'Save': 0, 'SaveAs': 0, 'SaveAs2': 0, 'SaveDataToUrl': 8,
  'SaveDocumentToURL': 3, 'SecureSaveDataToUrl': 20, 'SelIndexEnd': 20,
  'SelIndexStart': 20, 'SelPosEndCol': 20, 'SelPosEndLine': 20,
  'SelPosStartCol': 20, 'SelPosStartLine': 20, 'Select': 0,
  'SelectedNode': 8, 'Selection': 9, 'Set3DBorder': 0, 'SetColumnMode': 0,
  'SetColumnSash': 20, 'SetColumnWidth': 20, 'SetCurrentCellIDNumeric': 0,
  'SetCurrentDirectory': 20, 'SetDataFromUrl': 0,
  'SetDragDropHandleControl': 0, 'SetDragDropHandleImage': 0,
  'SetEnvVariable': 20, 'SetFileAttribute': 20,
  'SetFirstVisibleRowIDNumeric': 0, 'SetFont': 9, 'SetGrid': 20,
  'SetProfileString': 20, 'SetProperty': 0, 'SetRangesData2': 3,
  'SetRangesData3': 3, 'SetRangesFormat2': 3, 'SetRegDWValueEx': 20,
  'SetRegValue': 20, 'SetRegValueEx': 20, 'SetRowHeight': 20,
  'SetRowMode': 20, 'SetRowSash': 20, 'SetSelection': 3, 'SetToolTip': 0,
  'Shading': 9, 'Sheets': 9, 'ShellExecute': 20, 'ShellExecuteEx': 20,
  'ShellIDSrc': 20, 'ShellIDTarget': 20, 'ShowData': 8, 'ShowDocument': 8,
  'ShowRows': 3, 'ShowURL': 20, 'ShowUrl': 3, 'SnapToGrid': 3,
  'StopLinkServer': 3, 'Structures': 9, 'TABLES': 9, 'TYPEPARAGRAPH': 0,
  'TYPETEXT': 0, 'Tables': 9, 'Text': 8, 'TextModified': 11,
  'TextStream': 8, 'TextStreamOnlyWhenModified': 8, 'ThemeName': 8,
  'Today': 8, 'TopNode': 8, 'TopNodeKey': 8, 'TrackerStyle': 3,
  'TrackerWidth': 3, 'Transparent': 3, 'TypeAheadExport': 20,
  'TypeParagraph': 0, 'TypeText': 0, 'URLPrefixLocal': 8,
  'UnregisterServer': 20, 'Version': 3, 'WORKBOOKS': 9, 'WORKSHEETS': 9,
  'WidthInChar': 20, 'WinHelp': 20, 'WindowsPlatform': 20, 'Workbooks': 9,
  'Worksheets': 9, 'Zoom': 3, 'ZoomMax': 3, 'ZoomMin': 3, 'ZoomStep': 3,
  'automationObject': 9, 'browseForFolder': 8, 'createDirectory': 20,
  'createScreenshot': 8, 'data': 9, 'deleteFile': 20, 'deleteRegKey': 20,
  'deleteRegValue': 20, 'directoryExists': 20, 'disableHistoryForField': 20,
  'displayMode': 0, 'exec': 20, 'executeNew': 20, 'fileCopy': 20,
  'fileExists': 11, 'fileOpenDialog': 20, 'fileSaveDialog': 8,
  'fileSaveDialogEx': 8, 'formats': 9, 'getComputerName': 8,
  'getCurrentDirectory': 8, 'getDesktopDirectory': 8, 'getDownloadPath': 8,
  'getDriveType': 8, 'getEnvVariable': 8, 'getFileAttribute': 11,
  'getFileInfo': 8, 'getFileSeparator': 8, 'getFileSize': 20,
  'getFileSizeLong': 20, 'getFreeSpaceForDrive': 20,
  'getFreeSpaceForDriveLong': 20, 'getFullPathName': 8, 'getGuiFeatures': 8,
  'getGuiVersion': 20, 'getIPAddress': 8, 'getOperatingSystem': 8,
  'getOperatingSystemVersion': 8, 'getProfileString': 8,
  'getProgramName': 8, 'getProgramPath': 8, 'getRegDWValueEx': 20,
  'getRegValue': 8, 'getRegValueEx': 8, 'getSapWorkDir': 8,
  'getSelectOptions': 3, 'getSystemDirectory': 8, 'getTempPath': 8,
  'getTypeId': 8, 'getUploadPath': 8, 'getUserName': 8,
  'getWindowsBuildNumber': 8, 'getWindowsDirectory': 8,
  'getWindowsPlatform': 20, 'getWindowsVersion': 8,
  'isTerminalServicesRunning': 8, 'listFiles': 20, 'listFilesExt': 20,
  'loadImageFromURL': 3, 'loadImageFromURLAsync': 0, 'messageBox': 20,
  'openDocumentOrApplication': 20, 'r3TableAutoObj': 9,
  'registerServer': 20, 'removeDirectory': 20, 'setCurrentDirectory': 20,
  'setEnvVariable': 20, 'setFileAttribute': 20, 'setProfileString': 20,
  'setRegDWValueEx': 20, 'setRegValue': 20, 'setRegValueEx': 20,
  'setTimer': 3, 'shellExecute': 20, 'shellExecuteEx': 20,
  'showDocument': 8, 'showURL': 20, 'unregisterServer': 20, 'winHelp': 20,
  // DOI (doi.dart doiMethodTypes): the real Office 16 GUI's VT_I4 '0' on
  // every one (a recorded session — the chart / spreadsheet / Word 97 /
  // pivot demos; SO10 / SMARTFORMS's SAPscript Word editor; the SFP
  // Designer). Unmapped, each was answered a fresh object handle where the
  // ABAP reads an int (the CONVT_NO_NUMBER / UC_OBJECTS_NOT_CONVERTIBLE
  // dump family).
  'StartLinkServer': 3, 'AddTableItem': 3, 'AddBinaryItem': 3,
  'InsertRange2': 3, 'InsertRangeDim2': 3, 'InsertOneTable': 3,
  'SetFieldtype': 3, 'SetSelection2': 3, 'SetSourceTable': 3, 'SetFrame': 3,
  'FitWidest': 3, 'DrillUp': 3, 'DrillDown': 3,
  'InstallReadOnlyTemplate': 3, 'SetTemplate': 3, 'ExecuteMacro2': 3,
  'SetInPlaceBorderSpace': 3,
  // the SOI spreadsheet's formatting calls (OFFICEINTEGRATIONDOCPROXYIMP
  // i_oi_spreadsheet~set_format / set_color / cell_format / screen_update
  // / load_lib: RESULT = l_error->error_nr, an int) — XXL's insert_full,
  // the real GUI's t3 `0` on every one (a recorded session
  // gui[37]-[42], a recorded session gui[41]-[46]).
  // GetApplicationProperty's retvalue is a CHAR (t8 `.`, the decimal
  // separator: xxl gui[36]); the PIVOT proxy's InsertFull2 its status text
  // (t8 `''`, xxl_two_runs gui[48]). SetFont stays the table's object (an
  // automation Font), stamped VT_I4 on a DOI proxy (doiObserveCall)
  'SetFormat': 3, 'SetColor': 3, 'CellFormat': 3, 'ScreenUpdating': 3,
  'LoadLib': 3, 'GetApplicationProperty': 8, 'InsertFull2': 8,
  // the ALV in-place Excel's own members of the same spreadsheet proxy
  // (SAPoipe8.OCX; CL_SALV_GRU_VIEW_EXCEL update: set_data_table /
  // set_info_table / set_fixed_cols / setlocale / update_frontend, and the
  // view's get_selected_cells): the real GUI's t3 `0` on each
  // (a recorded session srv[55]-[58] -> gui[39]-[42],
  // srv[61] -> gui[45]). Unmapped they were answered a blank BSTR (or an
  // object handle) where the ABAP reads an int. The Office manager's
  // GetRegisteredProgIDs('BASIC', table) the same (OAOR srv[171] ->
  // gui[143]); its table rides the SaveDataToUrl upload (doi.dart).
  'SetDataTable': 3, 'SetInfoTable': 3, 'SetFixedCols': 3, 'SetLocale': 3,
  'UpdateFrontend': 3, 'GetSelectedAreas': 3, 'GetRegisteredProgIDs': 3,
  // the GFW business graphic (CL_GFW_GP_PRES_CHART): the chart's
  // ValueToDateString(f, 1) is read into a CHAR40 'mm/dd/yyyy hh:mm:ss'
  // (CONVERT_FLOAT_TO_DATETIME, on a scroll / zoom event) — a BSTR, not
  // an object handle. Its other adapter / chart calls (LoadURL,
  // SetVersion, SendObjId, SetLanguage, ShowLegendSymbol, SaveImage,
  // PrintOut, SaveAsJPeg) import no result.
  'ValueToDateString': 8,
};

/// The frontend dialect a session speaks (the connect frame's profile).
enum GuiDialect { java, windows }

const List<String> _winI2 = [
  'SetColumnWidth', 'SetGrid', 'AddControl', 'TypeAheadExport', 'GetColumnWidth',
  'GetRowHeight', 'SetRowHeight', 'SetRowMode', 'SetRowSash', 'SetColumnSash',
  'SetColumnMode', 'LISTFILES', 'TextModified', 'LoadCUACode',
  // CL_GUI_FRONTEND_SERVICES=>FILE_DELETE: VT_I2, the Win32 error code —
  // `2` for a missing file, `0` once deleted (a recorded session
  // inplace srv[131] -> gui[108], srv[144] -> gui[119]); the Java
  // GuiSapInfo's int stays the base table's
  'DeleteFile', 'deleteFile',
];
const List<String> _winI4 = [
  'GetContainer', 'CurrentCellColIDNumeric', 'CurrentCellRowIDNumeric',
  'CurrentCellRowIDSubNumeric', 'FirstVisibleRow', 'GetFirstVisibleRowIDNumeric',
  'GetFirstVisibleRowIDSubNumeric', 'GetGuiVersion', 'WidthInChar', 'FontSize',
  'SecureSaveDataToUrl', 'SecureSetDataFromUrl', 'Count', 'ShowData', 'ShowUrl',
  'EnableSAPSSO', 'loadImageFromURL', 'LoadImageFromURL', 'GetWindow', 'LoadBitmap',
  'SetSelection2', 'SetSourceTable',
  // the browser launches (browser_launch.dart): the real SAP GUI for
  // Windows stamps VT_I4 — ShowURLInDetachedBrowser '0'
  // (a recorded session srv[80] -> gui[65]; unmapped it was
  // answered a blank VT_BSTR), ShellExecute '42' (a recorded session
  // srv[102] -> gui[91], a recorded session srv[1565] -> gui[1285];
  // the base table's VT_I8 is the Java GuiSapInfo's long). ShowURLInBrowser
  // / ShellExecuteEx: the same OCX families, unrecorded.
  'ShowURLInDetachedBrowser', 'ShowURLInBrowser', 'ShellExecute', 'ShellExecuteEx',
];
const List<String> _winUi4 = [
  'BackColor', 'ForeColor', 'Color', 'Effect', 'SelPosStartCol', 'FirstVisibleLine',
  'SelPosStartLine',
];

/// The _RESULT type overrides per dialect, over [methodType] (the engine's
/// result_types.METHOD_TYPE_BY_DIALECT): one type per verb per dialect over
/// the step-paired corpus (48 Windows / 37 Java captures). Windows OCX
/// stamps VT_I2 setters, VT_I4 getters, VT_UI4 colours and PublishUrl as a
/// BSTR; the Java jars VT_I8 numerics and VT_BOOL for loadImageFromURL
/// (sapImageS.jar SapImage.loadImageFromURL -> boolean).
final Map<GuiDialect, Map<String, int>> methodTypeByDialect = {
  GuiDialect.java: const {
    'loadImageFromURL': 11, 'LoadImageFromURL': 11, 'PublishUrl': 11,
    'TextModified': 11, 'Count': 20, 'Effect': 20, 'SetColumnMode': 20,
    'SecureSetDataFromUrl': 20, 'ShowData': 8, 'ShowUrl': 8, 'EnableSAPSSO': 8,
    // SapBrowser's void launches (javap rev14), stamped like their ShowUrl /
    // EnableSAPSSO siblings; GuiSapInfo.shellExecute* return long (base 20)
    'ShowURLInDetachedBrowser': 8, 'ShowURLInBrowser': 8,
    'ShowDataInBrowser': 8,
  },
  GuiDialect.windows: {
    for (final m in _winI2) m: 2,
    for (final m in _winI4) m: 3,
    for (final m in _winUi4) m: 19,
    'PublishUrl': 8,
    'IsScriptingActive': 11,
  },
};

/// The _RESULT type of [verb] for [dialect] (null = the dialect-less base
/// table); null when neither table maps it.
int? methodTypeOf(String? verb, GuiDialect? dialect) {
  if (verb == null) return null;
  if (dialect != null) {
    final t = methodTypeByDialect[dialect]![verb];
    if (t != null) return t;
  }
  return methodType[verb];
}

const Set<String> kindFollowsRequest = {'GetDataAsFormat', 'End', 'Start'};

class FlushCall {
  FlushCall(this.raw);

  final Uint8List raw;
  late final Map<String, SvarsColumn> columns;

  List<String> verbs = [];
  List<String> verbCalls = [];
  List<String> verbKinds = [];
  List<String> verbObjects = [];
  List<Rec> params = [];
  List<Rec> vars = [];
  Map<int, int> resultTypes = {}; // PARAMS row index -> VARIANT type
  List<(String, String)> cachedProps = []; // (shell, prop)
  Map<(String, String), String> setProps = {}; // (shell, propId) -> value
  List<(String, int)> registeredEvents = [];
  List<String> svars = [];
  String? metricsShell;

  /// the dialect the result types were keyed on (null = base table)
  GuiDialect? dialect;

  /// mint side-channel (set by the responder after a queue is answered)
  List<(String, int, bool)> mintTrace = [];
  List<(String, String)> shellAliases = [];

  /// _RESULT VARS rows (0-based) the answer carries as the NULL object
  /// reference `O-1`, no handle minted — set by the DOI fold before the
  /// answer: GetDocumentProxyInterface after an OpenDocument whose class
  /// this frontend cannot start (a recorded session gui[21]).
  Set<int> nullObjectRows = {};

  /// the object handle the answer minted per _RESULT VARS row (0-based row
  /// -> handle; set by the responder) — what a later queue names the object
  /// by (a DATAREQUEST reply's `InsertPacket` on its provider)
  Map<int, int> resultHandles = {};

  /// This parse re-keyed on [dialect] — what [parseFlushCall] of [raw] with
  /// that dialect returns, without decoding the call again: the tables
  /// (columns, PARAMS / VARS / VERBS rows, SVARS) are the dialect-free
  /// decode and are SHARED (no reader writes them; [verbMeta]'s derived
  /// tables stay valid), only the `_RESULT` types are re-typed. The
  /// collections the answer path WRITES (cached / set properties, the mint
  /// side channel) are the copy's own, so the answer's additions never show
  /// up in this parse (audit #2: the answer re-parsed — re-inflating
  /// every cell of — a call the frame's readers had just parsed).
  FlushCall withDialect(GuiDialect? dialect) {
    final c = FlushCall(raw)
      ..dialect = dialect
      ..columns = columns
      ..svars = svars
      ..params = params
      ..vars = vars
      ..verbs = verbs
      ..verbCalls = verbCalls
      ..verbKinds = verbKinds
      ..verbObjects = verbObjects
      ..cachedProps = [...cachedProps]
      ..setProps = {...setProps}
      ..registeredEvents = [...registeredEvents]
      ..metricsShell = metricsShell;
    // a verb-less call returns from the parse before its results are typed
    if (_typed) _typeResults(c);
    return c;
  }

  bool _typed = false;
}

/// The concrete VARIANT type per `_RESULT` PARAMS row of [call], for its
/// [FlushCall.dialect].
void _typeResults(FlushCall call) {
  call._typed = true;
  for (var pI = 0; pI < call.params.length; pI++) {
    final p = call.params[pI];
    if (p.name != '_RESULT' && p.name != '_RESULT_QUEUEONLY') continue;
    final oid = p.objid.trim();
    String? meth;
    if (_isDigits(oid)) {
      final i = int.parse(oid);
      if (i >= 1 && i <= call.verbs.length) meth = call.verbs[i - 1];
    }
    call.resultTypes[pI] = methodTypeOf(meth, call.dialect) ?? 9;
  }
}

/// Parse an OLE_FLUSH_CALL RFC_TR value (parse_flush_call port).
FlushCall parseFlushCall(Uint8List rfc, {GuiDialect? dialect}) {
  DecodeStats.flushParses++;
  final call = FlushCall(rfc)
    ..dialect = dialect
    ..columns = rfcColumns(rfc)
    ..svars = parseSvarsItems(rfc);
  final cols = call.columns;
  // rfcColumns sees only `03 05` CELLS — a direct query whose PARAMS/VERBS
  // arrive as INLINE `03 04` rows (the GetColumnWidth flush the Easy Access
  // tree answers on a transaction launch, the engine's opsdash srv[18]) looked
  // VERBS-less, so its numeric _RESULT was typed as an object (the engine's
  // GET_USER_TAG dump) — or, upstream, never counted as a call at all.
  // Supplement from the inline rows (ea_flushcall.parse_flush_call_uncached).
  Uint8List? inline(String name, int w) {
    final rows = inlineColumnRows(rfc, name, w);
    if (rows.isEmpty) return null;
    return Uint8List.fromList([for (final r in rows) ...r]);
  }

  if (cols.containsKey('PARAMS')) {
    call.params =
        parseSvars(cols['PARAMS']!.blob, cols['PARAMS']!.width ?? paramsW);
  } else {
    final b = inline('PARAMS', paramsW);
    if (b != null) call.params = parseSvars(b, paramsW);
  }
  if (cols.containsKey('VARS')) {
    call.vars = parseSvars(cols['VARS']!.blob, cols['VARS']!.width ?? varsW);
  } else {
    final b = inline('VARS', varsW);
    if (b != null) call.vars = parseSvars(b, varsW);
  }
  final Uint8List? verbsBlob;
  final int verbsWidth;
  if (cols.containsKey('VERBS')) {
    verbsBlob = cols['VERBS']!.blob;
    verbsWidth = cols['VERBS']!.width ?? verbsW;
  } else {
    verbsBlob = inline('VERBS', verbsW);
    verbsWidth = verbsW;
  }
  if (verbsBlob == null) {
    return call;
  }
  final vrecs = parseSvars(verbsBlob, verbsWidth);
  call.verbs = [for (final v in vrecs) _name(v, 10, 52)];
  call.verbCalls = [for (final v in vrecs) _name(v, 0, 8)];
  call.verbKinds = [for (final v in vrecs) _name(v, 52, 53)];
  call.verbObjects = [for (final v in vrecs) _name(v, 0, 10)];

  // result types: the concrete VARIANT type per _RESULT PARAMS row
  final resultSlotByVerb = <int, String>{};
  for (final p in call.params) {
    final oid = p.objid.trim();
    if (!_isDigits(oid)) continue;
    if (p.name == '_RESULT' || p.name == '_RESULT_QUEUEONLY') {
      resultSlotByVerb.putIfAbsent(int.parse(oid), () => p.slot.trim());
    }
  }
  _typeResults(call);

  String? val(String slot) {
    if (_isDigits(slot) && int.parse(slot) < call.vars.length) {
      return call.vars[int.parse(slot)].slot.trim();
    }
    return null;
  }

  for (var i = 1; i <= call.verbs.length; i++) {
    final name = call.verbs[i - 1];
    if (name == 'RegisterCachedProp') {
      final argv = verbNamedArgs(call, i);
      final shell = argv['#1'], prop = argv['#2'];
      if (_isDigits(shell ?? '') && (prop ?? '').isNotEmpty) {
        call.cachedProps.add((shell!, prop!));
      }
    } else if (name == 'GetProperty') {
      // a property READ, never a cached-prop registration: the real GUI
      // answers it on the verb's _RESULT var and echoes no PROPERTY for it
      // (a recorded session srv[39] -> gui[31], the DBA
      // cockpit's dock-width read GetProperty(135, 300) after a nav-tree
      // item double-click; the corpus' 37 GetProperty verbs, numeric
      // propIds and `GetProperty(Control, Version)` alike). Taking its
      // values as (shell, name) pairs echoed phantom blocks the server's
      // CL_GUI_DATAMANAGER rejects — CNDP 008 "balise act.: PROPERTY"
      // (live 2026-10-12 `%_GC 148 22`: `<CONTROL SHELLID="300"><PROPERTY
      // VALUE="" NAME=""/>`; live 2026-10-13 `%_GC 150 22` the same dump):
      // [val] reads the row AFTER a slot (the reference client's `_val`), so the read
      // took the propId for the shell and whatever followed — the _RESULT
      // row, or the next verb's argument mid-queue — for a property name.
    } else if (name == 'SetProperty') {
      final argv = verbNamedArgs(call, i);
      final shell = argv['#1'], prop = argv['#2'], v = argv['#3'];
      if (_isDigits(shell ?? '') && (prop ?? '').isNotEmpty) {
        call.setProps[(shell!, prop!)] = v ?? '';
      }
    } else if (name == 'RegisterEvent' ||
        name == 'RegisterOcxEvent' ||
        name == 'RegisterGlobalOcxEvent') {
      final argv = verbNamedArgs(call, i);
      final a1 = argv['#1'], a2 = argv['#2'];
      if (_isDigits(a1 ?? '') && _isDigits(a2 ?? '')) {
        call.registeredEvents.add((a1!, int.parse(a2!)));
      } else if (_isDigits(a1 ?? '') && _sapNegativeRe.hasMatch(a2 ?? '')) {
        // a negative id in ABAP's trailing-minus spelling: the CFW input
        // field's / combo box's `RegisterOcxEvent(153, '600-')` = -600
        // (a recorded session srv[11])
        final n = a2!.trim();
        final id = int.tryParse(n.substring(0, n.length - 1));
        if (id != null) call.registeredEvents.add((a1!, -id));
      } else if (_isDigits(a1 ?? '')) {
        final tgt = call.verbCalls[i - 1];
        if (_isDigits(tgt)) {
          call.registeredEvents.add((tgt, int.parse(a1!)));
        }
      }
    } else if (name.startsWith('CreateControl') && call.metricsShell == null) {
      final v = val(resultSlotByVerb[i] ?? '');
      if (_isDigits(v ?? '')) call.metricsShell = v;
    }
  }
  return call;
}

String _name(Rec v, int start, int end) =>
    String.fromCharCodes(v.raw, start, end < v.raw.length ? end : v.raw.length).trim();

final RegExp _digitsRe = RegExp(r'^\d+$');

bool _isDigits(String? s) => s != null && _digitsRe.hasMatch(s);

final RegExp _sapNegativeRe = RegExp(r'^\s*\d+-\s*$');

/// The PARAMS rows per verb (the objid column, trimmed), built once per
/// parsed PARAMS table. [verbArgs] / [verbNamedArgs] are asked once per
/// verb by every ingest pass; a scan of the whole table per verb is
/// O(verbs x params) — the /AIF/IFMON tree-data batch (a recorded session
/// srv[23..30] step 38: 4 264 verbs, 10 660 PARAMS rows) took minutes per
/// pass and the answer was owed while the server waited.
final Expando<Map<String, List<Rec>>> _paramsByObjid =
    Expando('PARAMS rows by verb');

List<Rec> _paramsOfVerb(FlushCall call, int i) {
  final rows = call.params;
  final byObjid = _paramsByObjid[rows] ??= () {
    final m = <String, List<Rec>>{};
    for (final p in rows) {
      (m[p.objid.trim()] ??= []).add(p);
    }
    return m;
  }();
  return byObjid[i.toString()] ?? const [];
}

/// {'#1': value, '#2': value, …} of the i-th (1-based) verb's named args.
Map<String, String> verbNamedArgs(FlushCall call, int i) {
  final argv = <String, String>{};
  for (final p in _paramsOfVerb(call, i)) {
    final pname = p.name;
    if (!pname.startsWith('#')) continue;
    final s = p.slot.trim();
    if (_isDigits(s) && int.parse(s) > 0 && int.parse(s) <= call.vars.length) {
      argv[pname.trim()] = call.vars[int.parse(s) - 1].valueText;
    }
  }
  return argv;
}

/// Ordered [(param_name, value)] of the i-th verb's arguments.
List<(String, String)> verbArgs(FlushCall call, int i) {
  final out = <(String, String)>[];
  for (final p in _paramsOfVerb(call, i)) {
    final s = p.slot.trim();
    if (_isDigits(s) && int.parse(s) > 0 && int.parse(s) <= call.vars.length) {
      out.add((p.name, call.vars[int.parse(s) - 1].valueText));
    }
  }
  return out;
}

/// Per-verb WIRE REFERENCES beyond the argument values (verb_meta port).
class VerbMeta {
  VerbMeta(this.obj, this.objValue);
  final String obj; // on-object VARS row (1-based)
  String objValue = ''; // that row's value token
  String? result; // the verb's _RESULT VARS row
  final Map<String, String> slots = {}; // #-named arg -> VARS row
}

/// The derived per-call tables every side model of one flush reads — the
/// grid, chart, NetPlan, canvas, context-menu and editor folds, the layout
/// / html / value-help folds and the responder each asked for the same
/// [verbMeta] / [dpPushBindings] over the same call (O(verbs) apiece, ~10x
/// per call: the 4 264-verb /AIF/IFMON batch). Built once per call, keyed on
/// the call AND the identity of the tables it was derived from (a call whose
/// VERBS / PARAMS / VARS are reassigned is derived afresh). Shared and
/// unmodifiable: readers never change them.
class _Derived {
  _Derived(FlushCall c)
      : verbs = c.verbs,
        objects = c.verbObjects,
        params = c.params,
        vars = c.vars;
  final List<String> verbs, objects;
  final List<Rec> params, vars;
  List<VerbMeta>? meta;
  List<DpPushBinding>? bindings;

  bool of(FlushCall c) =>
      identical(verbs, c.verbs) &&
      identical(objects, c.verbObjects) &&
      identical(params, c.params) &&
      identical(vars, c.vars);
}

final Expando<_Derived> _derived = Expando('flush call derived tables');

_Derived _derivedOf(FlushCall call) {
  final d = _derived[call];
  if (d != null && d.of(call)) return d;
  return _derived[call] = _Derived(call);
}

List<VerbMeta> verbMeta(FlushCall call) =>
    _derivedOf(call).meta ??= List.unmodifiable(_verbMeta(call));

List<VerbMeta> _verbMeta(FlushCall call) {
  String rowValue(String s) {
    if (_isDigits(s) && int.parse(s) > 0 && int.parse(s) <= call.vars.length) {
      return call.vars[int.parse(s) - 1].valueText;
    }
    return '';
  }

  final meta = [
    for (final obj in call.verbObjects) VerbMeta(obj, rowValue(obj))
  ];
  for (final p in call.params) {
    final oid = p.objid.trim();
    if (!(_isDigits(oid) && int.parse(oid) >= 1 && int.parse(oid) <= meta.length)) {
      continue;
    }
    final m = meta[int.parse(oid) - 1];
    if (p.name == '_RESULT' || p.name == '_RESULT_QUEUEONLY') {
      m.result ??= p.slot.trim();
    } else {
      m.slots.putIfAbsent(p.name.trim(), () => p.slot.trim());
    }
  }
  return meta;
}

final RegExp _treeTableVerbRx =
    RegExp(r'^(?:Add|Update|Set|SetUpdate)(R3|Item)Table$', caseSensitive: false);
/// The SAP.TABControl.1 (WDTMCTRL.OCX) value-help model pushes, each ON the
/// control (`setDialogPages(<dp>)` …; a recorded session srv raw[28] /
/// [30] / [40]) — the push's role is the verb itself. Anchored with a real
/// `$`: the escaped `\$` of the first port never matched a verb name, so no
/// value-help push was ever bound.
final RegExp _tabctlTableVerbRx = RegExp(
    r'^(setDialogPages|setDialogItems|setSelOpts|setMessages|setResultTableCols|createResultDialog)$');

/// The IDENTITY of every DataProvider push a queue declares
/// (dp_push_bindings_from_verbs port): {urls, owner, role, shell, class}.
List<DpPushBinding> dpPushBindings(FlushCall call) =>
    _derivedOf(call).bindings ??= List.unmodifiable(_dpPushBindings(call));

List<DpPushBinding> _dpPushBindings(FlushCall call) {
  final out = <DpPushBinding>[];
  final meta = verbMeta(call);
  DpPushBinding? ondemand;
  String? pendingUrl;
  final rowShell = <String, String>{}; // CreateControl result row -> kernel shell
  final rowUrl = <String, String>{}; // DP-chain-derived rows -> url

  int? num(String? v) => int.tryParse((v ?? '').trim());
  bool isNum(String? v) => num(v) != null;

  void flush() {
    final od = ondemand;
    if (od != null && (od.urls.isNotEmpty || od.role != null)) {
      out.add(od);
    }
    ondemand = null;
  }

  for (var i = 1; i <= call.verbs.length; i++) {
    final verb = call.verbs[i - 1];
    final named = verbNamedArgs(call, i);
    final m = meta[i - 1];
    final objRow = m.obj.trim();
    final resRow = m.result?.trim() ?? '';
    if (resRow.isNotEmpty) {
      if (rowUrl.containsKey(objRow)) {
        rowUrl[resRow] = rowUrl[objRow]!;
      } else {
        rowUrl.remove(resRow);
      }
      rowShell.remove(resRow);
    }
    if (verb == 'CreateObject') {
      final args = verbArgs(call, i);
      final cls = args
          .map((a) => a.$2)
          .firstWhere((v) => v.isNotEmpty && v.contains(_letterRx), orElse: () => '');
      if (cls.toLowerCase().contains('ondemand')) {
        flush();
        ondemand = DpPushBinding(owner: null, role: null, urls: [], cls: cls);
      } else {
        pendingUrl = null; // a plain GuiDataProvider block opens
      }
      continue;
    }
    if (verb.startsWith('CreateControl')) {
      final sh = (named['#1'] ?? '').trim();
      if (resRow.isNotEmpty && isNum(sh)) {
        rowShell[resRow] = sh;
      }
      continue;
    }
    if (verb == 'SetDataFromUrl') {
      final u = (named['#3'] ?? '').trim();
      if (u.startsWith('SAPR3://')) {
        pendingUrl = u;
        if (objRow.isNotEmpty) rowUrl[objRow] = u;
      }
    } else if (verb == 'InsertPacket') {
      final od = ondemand;
      if (pendingUrl != null && od != null) {
        od.urls.add(pendingUrl);
      } else if (pendingUrl != null) {
        final prov = m.objValue.trim();
        out.add(DpPushBinding(
          urls: [pendingUrl],
          owner: null,
          role: null,
          cls: 'GuiDataProvider',
          provider: isNum(prov) ? prov : null,
          firstline: num(named['#1']),
          attach: 'InsertPacket',
        ));
      }
      pendingUrl = null;
    } else if (_tabctlTableVerbRx.hasMatch(verb)) {
      final url = rowUrl[(m.slots['#1'] ?? '').trim()] ?? pendingUrl;
      final owner = m.objValue.trim();
      out.add(DpPushBinding(
          urls: [if (url != null) url],
          owner: isNum(owner) ? owner : null,
          role: verb,
          shell: rowShell[objRow],
          cls: 'TabControl',
          attach: verb,
          field: verb == 'createResultDialog' ? (named['#3'] ?? '').trim() : null));
      pendingUrl = null;
    } else if (_treeTableVerbRx.hasMatch(verb)) {
      final role = '${_treeTableVerbRx.firstMatch(verb)!.group(1)}Table';
      final url = rowUrl[(m.slots['#1'] ?? '').trim()] ?? pendingUrl;
      final owner = m.objValue.trim();
      out.add(DpPushBinding(
          urls: [if (url != null) url],
          owner: isNum(owner) ? owner : null,
          role: role,
          shell: rowShell[objRow],
          cls: 'SapTree',
          attach: verb));
      pendingUrl = null;
    } else if (verb == 'AssignProperty2') {
      final role = (named['#4'] ?? '').trim();
      final owner = (named['#3'] ?? '').trim();
      if (role.isEmpty) continue;
      final shell = owner.isEmpty ? rowShell[(m.slots['#3'] ?? '').trim()] : null;
      if (pendingUrl != null) {
        out.add(DpPushBinding(
            urls: [pendingUrl],
            owner: owner.isEmpty ? null : owner,
            role: role,
            shell: shell,
            cls: 'GuiDataProvider'));
        pendingUrl = null;
      } else if (ondemand != null && ondemand!.role == null) {
        ondemand!.role = role;
        ondemand!.owner = owner.isEmpty ? null : owner;
        if (shell != null && ondemand!.shell == null) ondemand!.shell = shell;
      }
    } else if (ondemand != null && verb == 'Handle' && ondemand!.handle == null) {
      for (final na in verbArgs(call, i)) {
        final v = na.$2;
        final n = num(v);
        if (n != null) {
          ondemand!.handle = n;
          break;
        }
      }
    } else if (ondemand != null &&
        verb == 'LineCount' &&
        ondemand!.lineCount == null) {
      // the provider's line count (`LineCount(=249)`): the DataTableOnDemand
      // provider counts CELLS (rows x (columns + the row-id cell)), the
      // RowIDNumericOnDemand provider counts ROWS
      for (final na in verbArgs(call, i)) {
        final n = num(na.$2);
        if (n != null) {
          ondemand!.lineCount = n;
          break;
        }
      }
    } else if (ondemand != null && verb == 'AssignDataObjToShell') {
      final h = num(named['#1']);
      final sh = (named['#2'] ?? '').trim();
      if (h != null && h == ondemand!.handle && isNum(sh)) {
        ondemand!.shell = sh;
      }
    }
  }
  flush();
  return out;
}

class DpPushBinding {
  DpPushBinding({
    required this.urls,
    this.owner,
    this.role,
    this.shell,
    this.cls = 'GuiDataProvider',
    this.handle,
    this.lineCount,
    this.provider,
    this.firstline,
    this.attach,
    this.field,
  });

  final List<String> urls;
  String? owner;
  String? role;
  String? shell;
  String cls;
  int? handle;

  /// an on-demand provider's `LineCount` (null when the queue sets none)
  int? lineCount;
  String? provider;
  int? firstline;
  String? attach;
  String? field;
}

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call (audit #7 / zcode P-12).
final RegExp _letterRx = RegExp(r'[A-Za-z]');
