/// The GetGuiFeatures answer the frontend ships (ea_frontend_features port):
/// the feature list rides the SVARS XML channel, its VARS result row the
/// index '1'.
library;

import 'dart:typed_data';

import '../codepages.dart';

const String guiFeaturesXml = r'''<AvailableFeatures>
  <component>
    <sapinfocntl>
       <overwriteonprompt win = 'X' plat = 'X' web = ' ' />
       <CL_GUI_FRONTEND_SERVICES win = 'X' plat = 'X' web = ' ' />
       <CHECK_GUI_SUPPORT win = 'X' plat = 'X' web = ' ' />
       <CLIPBOARD_EXPORT win = 'X' plat = 'X' web = ' ' />
       <CLIPBOARD_IMPORT win = 'X' plat = 'X' web = ' ' />
       <DIRECTORY_BROWSE win = 'X' plat = 'X' web = ' ' />
       <DIRECTORY_CREATE win = 'X' plat = 'X' web = ' ' />
       <DIRECTORY_DELETE win = 'X' plat = 'X' web = ' ' />
       <DIRECTORY_DELETE_FILES win = 'X' plat = 'X' web = ' ' />
       <DIRECTORY_EXIST win = 'X' plat = 'X' web = ' ' />
       <DIRECTORY_GET_CURRENT win = 'X' plat = 'X' web = ' ' />
       <DIRECTORY_LIST_FILES win = 'X' plat = 'X' web = ' ' />
       <DISABLEHISTORYFORFIELD win = 'X' plat = 'X' web = ' ' />
       <ENVIRONMENT_GET_VARIABLE win = 'X' plat = 'X' web = ' ' />
       <EXECUTE win = 'X' plat = 'X' web = ' ' />
       <FILE_COPY win = 'X' plat = 'X' web = ' ' />
       <FILE_DELETE win = 'X' plat = 'X' web = ' ' />
       <FILE_EXIST win = 'X' plat = 'X' web = ' ' />
       <NATIVE_FILE_EXIST win = 'X' plat = 'X' web = ' ' />
       <FILE_GET_ATTRIBUTES win = 'X' plat = 'X' web = ' ' />
       <FILE_GET_SIZE win = 'X' plat = 'X' web = ' ' />
       <FILE_GET_VERSION win = 'X' plat = 'X' web = ' ' />
       <FILE_OPEN_DIALOG win = 'X' plat = 'X' web = ' ' />
       <FILE_SAVE_DIALOG win = 'X' plat = 'X' web = ' ' />
       <GET_FILE_SEPARATOR win = 'X' plat = 'X' web = ' ' />
       <GET_FREE_SPACE_FOR_DRIVE win = 'X' plat = 'X' web = ' ' />
       <GET_DOWNLOAD_PATH win = 'X' plat = 'X' web = ' ' />
       <GET_UPLOAD_PATH win = 'X' plat = 'X' web = ' ' />
       <GET_GUI_FEATURES_TAB win = 'X' plat = 'X' web = ' ' />
       <GET_GUI_PROPERTIES win = 'X' plat = 'X' web = ' ' />
       <GET_GUI_VERSION win = 'X' plat = 'X' web = ' ' />
       <GET_IP_ADDRESS win = 'X' plat = 'X' web = ' ' />
       <GET_LF_FOR_DESTINATION_GUI win = 'X' plat = 'X' web = ' ' />
       <GET_PLATFORM win = 'X' plat = 'X' web = ' ' />
       <GET_SAPGUI_DIRECTORY win = 'X' plat = 'X' web = ' ' />
       <GET_SAPGUI_WINDOW_STATE win = 'X' plat = 'X' web = ' ' />
       <GET_SAPGUI_WORKDIR win = 'X' plat = 'X' web = ' ' />
       <saplogoncodepage win = 'X' plat = 'X' web = ' ' />
       <GET_SYSTEM_DIRECTORY win = 'X' plat = 'X' web = ' ' />
       <GET_TEMP_DIRECTORY win = 'X' plat = 'X' web = ' ' />
       <GET_UPLOAD_DOWNLOAD_PATH win = 'X' plat = 'X' web = ' ' />
       <GET_USER_NAME win = 'X' plat = 'X' web = ' ' />
       <GUI_DOWNLOAD win = 'X' plat = 'X' web = ' ' />
       <GUI_UPLOAD win = 'X' plat = 'X' web = ' ' />
       <GET_COMPUTER_NAME win = 'X' plat = 'X' web = ' ' />
       <GET_SCREENSHOT win = 'X' plat = 'X' web = ' ' />
       <SHOWDOCUMENT win = 'X' plat = 'X' web = ' ' />
       <DIRECTORY_LIST_FILES_EXT win = 'X' plat = 'X' web = ' ' />
       <FILE_GET_SIZE_LONG win = 'X' plat = 'X' web = 'X' />
       <GET_FREE_SPACE_FOR_DRIVE_LONG win = 'X' plat = 'X' web = ' ' />
       <IS_SCRIPTING_ACTIVE win = 'X' plat = 'X' web = ' ' />
       <TYPEAHEAD_EXPORT win = 'X' plat = 'X' web = ' ' />
       <REMOTELEVEL win = 'X' plat = 'X' web = ' ' />
    </sapinfocntl>
  </component>
  <component>
    <dataprovider>
      <tableasstring win = 'X' plat = 'X' web = ' ' />
    </dataprovider>
  </component>
  <component>
    <sapguiresources>
      <getthemename win = 'X' plat = 'X' web = ' ' />
    </sapguiresources>
  </component>
  <component>
    <treeandgrid>
      <getdroppedexternalfiles win = 'X' plat = 'X' web = ' ' />
      <dragacceptfiles win = 'X' plat = 'X' web = ' ' />
    </treeandgrid>
  </component>
  <component>
    <treecontrol>
      <disableselchange win = 'X' plat = 'X' web = ' ' />
    </treecontrol>
  </component>
  <component>
    <sappicture>
      <Tooltip win = 'X' plat = 'X' web = ' ' />
    </sappicture>
  </component>
  <component>
    <SAPComboBoxCtrl>
      <exists win = 'X' plat = 'X' web = ' ' />
    </SAPComboBoxCtrl>
  </component>
  <component>
    <input_field>
      <exists win = 'X' plat = 'X' web = ' ' />
    </input_field>
  </component>
  <component>
    <gridview>
      <RowGrouping win = 'X' plat = 'X' web = ' ' />
      <CacheSelectedRows win = 'X' plat = 'X' web = ' ' />
      <FixedRowsBottom win = 'X' plat = 'X' web = 'X'/>
      <OneUXServiceIcons win = 'X' plat = 'X' web = 'X'/>
      <DisabledRowSelectors win = 'X' plat = 'X' web = 'X'/>
    </gridview>
  </component>
  <component>
    <gridview>
      <StretchingHeader win = 'X' plat = 'X' web = ' ' />
    </gridview>
  </component>
  <component>
    <gridview>
      <Stretching win = 'X' plat = 'X' web = ' ' />
    </gridview>
  </component>
  <component>
    <sapcalen>
     <hijricalendarsupport win='X' plat='X' web=' ' />
    </sapcalen>
  </component>
  <component>
    <toolbar>
      <AlignRight win = 'X' plat = 'X' web = 'X' />
      <SetFocusButton win = 'X' plat = 'X' web = 'X' />
    </toolbar>
  </component>
  <component>
    <saphtml>
      <simplebrowse win = 'X' plat = 'X' web = ' ' />
      <detachurlinbrowser win = 'X' plat = 'X' web = ' ' />
      <getcharsetstring win = 'X' plat = 'X' web = ' ' />
      <DetachedBrowser win = 'X' plat = 'X' web = ' ' />
      <EndSessionFeature win = 'X' plat = 'X' web = ' ' />
      <EnableSSO win = 'X' plat = 'X' web = ' ' />
      <LoadIconFont win = 'X' plat = 'X' web = ' ' />
      <EnableSecSess win = 'X' plat = 'X' web = ' ' />
      <dragacceptfiles win = 'X' plat = 'X' web = ' ' />
      <GetBrowserEngine win = 'X' plat = 'X' web = ' ' />
    </saphtml>
  </component>
  <component>
    <toolbarcontainer>
      <exists win = 'X' plat = 'X' web = ' ' />
      <title  win = 'X' plat = 'X' web = ' ' />
      <TextOverflowOnly  win = 'X' plat = 'X' web = ' ' />
      <DropDownButton  win = 'X' plat = 'X' web = ' ' />
    </toolbarcontainer>
  </component>
  <component>
    <personas>
      <optimizedXmlSending win = 'X' plat = 'X' web = ' ' />
    </personas>
  </component>
  <component>
    <icons>
      <alvexpandcollapse win = 'X' plat = 'X' web = ' ' />
      <shoppingcarts win = 'X' plat = 'X' web = ' ' />
    </icons>
  </component>
  <component>
    <typeahead>
      <more_results_dialog win = 'X' plat = 'X' web = ' ' />
      <extended_format win = 'X' plat = 'X' web = ' ' />
      <okcode_prefix win = 'X' plat = 'X' web = ' ' />
    </typeahead>
  </component>
</AvailableFeatures>
''';

/// The SVARS XML parameter bytes for [values] in the Windows form: numeric
/// character references, no XML prolog (diag_svars.build_svars_xml port).
Uint8List buildSvarsXmlWindows(List<String> values) {
  final items = [
    for (final v in values) '<item><VALUE>${_winEscape(v)}</VALUE></item>'
  ];
  return wireText('<SVARS>${items.join()}</SVARS>');
}

String _winEscape(String s) => s
    .replaceAll('&', '&#38;')
    .replaceAll('<', '&#60;')
    .replaceAll('>', '&#62;')
    .replaceAll("'", '&#39;')
    .replaceAll('"', '&#34;');

/// The SAP GUI for Windows answer to GetGuiFeatures (SAPGUI.InfoCtrl.1),
/// the real GUI's value verbatim (reference client ea_frontend_features
/// GUI_FEATURES_XML_WINDOWS: a recorded session gui[2] step 10,
/// SVARS item 1 unescaped, 9473 chars; identical in
/// a recorded session). Unlike the Java document it declares
/// `<sapinfocntl><platformex win = 'X'/>`, the feature
/// CL_GUI_FRONTEND_SERVICES=>GET_PLATFORM checks before it asks
/// GetPlatformEx (else the legacy GetWindowsPlatform/GetWindowsVersion
/// pair). Declared at logon it is what elects the native DB50/0219
/// chart (SAPGraphics.Chart.1) over the off-DIAG SAP.HTMLControl.1 /
/// Plotly viewer (reference client d6c5662, a recorded session).
const String guiFeaturesXmlWindows =
    '   <AvailableFeatures>     <component>        '
    '<toolbar>          <StretchStructure win = \'X\' plat = \' '
    '\' web = \' \' />          '
    '<AlignRight win =\'X\' plat =\' \' web =\' \' />\t\t  '
    '<SetFocusButton win =\'X\' plat =\' \' web =\' \' />        '
    '</toolbar>    </component>    <component>        '
    '<ControlModeF4>            '
    '<MultiInsDelPVL win = \'X\' plat = \' \' web = \' \' />       '
    '     <ColheaderAbbrevation win="X" plat="" web="" />    '
    '    </ControlModeF4>    </component>    '
    '<component>        <officeintegration>            '
    '<setmergetemplate win = \'X\' plat = \' \' web = \' \' />     '
    '       <saveerrorcheck win = \'X\' plat = \' \' web = \' \' />'
    '\t    <setwebdavserver win = \'X\' plat = \' \' web = \' \' />\t'
    '    <installreadonlytemplate win = \'X\' plat = \' \' web = '
    '\' \' />\t    <XXLSetRangesData win=\'X\' plat = \' \' web = \' '
    '\' />        </officeintegration>    </component>    '
    '<component>        <saphtml>            '
    '<simplebrowse win = \'X\' plat = \' \' web = \' \' />         '
    '   <detachurlinbrowser win = \'X\' plat = \' \' web = \' \' />'
    '            <getcharsetstring win = \'X\' plat = \' \' web ='
    ' \' \' />            <DetachedBrowser win = \'X\' plat = \' \''
    ' web = \' \' />            '
    '<EndSessionFeature win = \'X\' plat = \' \' web = \' \' />    '
    '        <LoadIconFont win = \'X\' plat = \' \' web = \' \' /> '
    '           <EnableSecSess win = \'X\' plat = \' \' web = \' \''
    ' />            <dragacceptfiles win = \'X\' plat = \' \' web'
    ' = \' \' />            '
    '<InitScreenDetails win = \'X\' plat = \' \' web = \' \' />    '
    '        <EdgeCOMAccess win = \'X\' plat = \' \' web = \' \' />'
    '            <EdgeCustomURI win = \'X\' plat = \' \' web = \' '
    '\' />            <GetBrowserEngine win = \'X\' plat = \'X\' w'
    'eb = \'X\' />        </saphtml>    </component>    '
    '<component>        <sapawole>            '
    '<paramsasstring win = \'X\' plat = \' \' web = \' \' />       '
    ' </sapawole>    </component>    <component>        '
    '<sapinfocntl>            '
    '<customdlg win = \'X\' plat = \' \' web = \' \' />            '
    '<overwriteonprompt win = \'X\' plat = \' \' web = \' \' />    '
    '        <saplogoncodepage  win = \'X\' plat = \' \' web = \' '
    '\' />            <platformex     win = \'X\' plat = \' \' web'
    ' = \' \' />   \t\t\t<CHECK_GUI_SUPPORT win = \'X\' plat = \'\' we'
    'b = \' \' />   \t\t\t<CLIPBOARD_EXPORT win = \'X\' plat = \'\' we'
    'b = \' \' />   \t\t\t<CLIPBOARD_IMPORT win = \'X\' plat = \'\' we'
    'b = \' \' />   \t\t\t<DIRECTORY_BROWSE win = \'X\' plat = \'\' we'
    'b = \' \' />   \t\t\t<DIRECTORY_CREATE win = \'X\' plat = \'\' we'
    'b = \' \' />   \t\t\t<DIRECTORY_DELETE win = \'X\' plat = \'\' we'
    'b = \' \' />   \t\t\t<DIRECTORY_EXIST win = \'X\' plat = \'\' web'
    ' = \' \' />   \t\t\t<DIRECTORY_GET_CURRENT win = \'X\' plat = \''
    '\' web = \' \' />   \t\t\t'
    '<DIRECTORY_LIST_FILES win = \'X\' plat = \'X\' web = \'X\' /> '
    '  \t\t\t<DIRECTORY_LIST_FILES_EXT win = \'X\' plat = \'X\' web '
    '= \'X\' />   \t\t\t<DIRECTORY_SET_CURRENT win = \'X\' plat = \'\''
    ' web = \' \' />   \t\t\t<DISABLEHISTORYFORFIELD win = \'X\' pla'
    't = \'\' web = \' \' />   \t\t\t'
    '<ENVIRONMENT_GET_VARIABLE win = \'X\' plat = \'\' web = \' \' '
    '/>   \t\t\t<ENVIRONMENT_SET_VARIABLE win = \'X\' plat = \'\' we'
    'b = \' \' />   \t\t\t<EXECUTE win = \'X\' plat = \'\' web = \' \' /'
    '>   \t\t\t<FILE_COPY win = \'X\' plat = \'\' web = \' \' />   \t\t\t'
    '<FILE_DELETE win = \'X\' plat = \'\' web = \' \' />   \t\t\t'
    '<FILE_EXIST win = \'X\' plat = \'\' web = \' \' />   \t\t\t'
    '<FILE_GET_ATTRIBUTES win = \'X\' plat = \'\' web = \' \' />   '
    '\t\t\t<FILE_GET_SIZE win = \'X\' plat = \'X\' web = \'X\' />   \t\t'
    '\t<FILE_GET_SIZE_LONG win = \'X\' plat = \'X\' web = \'X\' />  '
    ' \t\t\t<FILE_GET_VERSION win = \'X\' plat = \'\' web = \' \' />  '
    ' \t\t\t<FILE_OPEN_DIALOG win = \'X\' plat = \'\' web = \' \' />  '
    ' \t\t\t<FILE_SAVE_DIALOG win = \'X\' plat = \'\' web = \' \' />  '
    ' \t\t\t<FILE_SET_ATTRIBUTES win = \'X\' plat = \'\' web = \' \' /'
    '>   \t\t\t<FREESPACEINMB win = \'X\' plat = \'\' web = \' \' />  '
    ' \t\t\t<GET_COMPUTER_NAME win = \'X\' plat = \'\' web = \' \' /> '
    '  \t\t\t<GET_DESKTOP_DIRECTORY win = \'X\' plat = \'\' web = \' '
    '\' />   \t\t\t<GET_DRIVE_FREE_SPACE_MEGABYTE win = \'\' plat ='
    ' \'X\' web = \' \' />   \t\t\t'
    '<GET_DRIVE_TYPE win = \'X\' plat = \'\' web = \' \' />   \t\t\t'
    '<GET_FILE_SEPARATOR win = \'X\' plat = \'\' web = \' \' />   \t'
    '\t\t<GET_FREE_SPACE_FOR_DRIVE win = \'X\' plat = \'X\' web = \''
    ' \' />   \t\t\t<GET_FREE_SPACE_FOR_DRIVE_LONG win = \'X\' plat'
    ' = \'X\' web = \' \' />   \t\t\t'
    '<GET_GUI_FEATURES_TAB win = \'X\' plat = \'\' web = \' \' />  '
    ' \t\t\t<GET_GUI_PROPERTIES win = \'X\' plat = \'\' web = \' \' />'
    '   \t\t\t<GET_GUI_VERSION win = \'X\' plat = \'\' web = \' \' /> '
    '  \t\t\t<GET_IP_ADDRESS win = \'X\' plat = \'\' web = \' \' />   '
    '\t\t\t<GET_LF_FOR_DESTINATION_GUI win = \'X\' plat = \'\' web ='
    ' \' \' />   \t\t\t<GET_PLATFORM win = \'X\' plat = \'\' web = \' \''
    ' />   \t\t\t<GET_SAPGUI_DIRECTORY win = \'X\' plat = \'\' web ='
    ' \' \' />   \t\t\t<GET_SAPGUI_WORKDIR win = \'X\' plat = \'\' web'
    ' = \' \' />   \t\t\t<GET_SAPLOGON_ENCODING win = \'X\' plat = \''
    '\' web = \' \' />   \t\t\t'
    '<GET_SCREENSHOT win = \'X\' plat = \'\' web = \' \' />   \t\t\t'
    '<GET_SYSTEM_DIRECTORY win = \'X\' plat = \'\' web = \' \' />  '
    ' \t\t\t<GET_TEMP_DIRECTORY win = \'X\' plat = \'\' web = \' \' />'
    '   \t\t\t<GET_DOWNLOAD_PATH win = \'X\' plat = \'\' web = \' \' /'
    '>   \t\t\t<GET_UPLOAD_DOWNLOAD_PATH win = \'X\' plat = \'\' web'
    ' = \' \' />   \t\t\t<GET_UPLOAD_PATH win = \'X\' plat = \'\' web '
    '= \' \' />   \t\t\t<GET_USER_NAME win = \'X\' plat = \'\' web = \''
    ' \' />   \t\t\t<GET_WINDOWS_DIRECTORY win = \'X\' plat = \'\' we'
    'b = \' \' />   \t\t\t<GET_WINDOWS_VERSION_EX win = \'X\' plat ='
    ' \'\' web = \' \' />   \t\t\t'
    '<GUI_DOWNLOAD win = \'X\' plat = \'\' web = \' \' />   \t\t\t'
    '<GUI_UPLOAD win = \'X\' plat = \'\' web = \' \' />   \t\t\t'
    '<IS_FEATURE_SUPPORTED win = \'X\' plat = \'\' web = \' \' />  '
    ' \t\t\t<IS_TERMINAL_SERVER win = \'X\' plat = \'\' web = \' \' />'
    '   \t\t\t<NATIVE_FILE_EXIST win = \'X\' plat = \'\' web = \' \' /'
    '>   \t\t\t<REGISTRY_DELETE_KEY win = \'X\' plat = \'\' web = \' '
    '\' />   \t\t\t<REGISTRY_DELETE_VALUE win = \'X\' plat = \'\' web'
    ' = \' \' />   \t\t\t<REGISTRY_GET_DWORD_VALUE win = \'X\' plat '
    '= \'\' web = \' \' />   \t\t\t'
    '<REGISTRY_GET_VALUE win = \'X\' plat = \'\' web = \' \' />   \t'
    '\t\t<REGISTRY_SET_DWORD_VALUE win = \'X\' plat = \'\' web = \' '
    '\' />   \t\t\t<REGISTRY_SET_VALUE win = \'X\' plat = \'\' web = '
    '\' \' />\t\t\t   <RAISE_SCRIPTING_EVENT win = \'X\' plat = \'\' w'
    'eb = \' \' />\t\t\t   <IS_SCRIPTING_ACTIVE win = \'X\' plat = \''
    '\' web = \' \' />            '
    '<SHOWDOCUMENT win = \'X\' plat = \'X\' web = \' \' />\t    '
    '<TYPEAHEAD_EXPORT win = \'X\' plat = \'X\' web = \' \' />     '
    '   </sapinfocntl>    </component>    '
    '<component>        <dataprovider>            '
    '<tableasstring win = \'X\' plat = \' \' web = \' \' />        '
    '</dataprovider>    </component>    <component>        '
    '<treecontrol>            '
    '<disableselchange win = \'X\' plat = \' \' web = \' \' />     '
    '   </treecontrol>    </component>    '
    '<component>            <ganttcontrol>                '
    '<usedataasstream win = \'X\' plat = \' \' web = \' \' />      '
    '          <collapsed_hierarchy win = \'X\' plat = \' \' web '
    '= \' \' />                '
    '<multmove3 win = \'X\' plat = \' \' web = \' \' />            '
    '    <startdayofweek win = \'X\' plat = \' \' web = \' \' />   '
    '         </ganttcontrol>    </component>    '
    '<component>            <netcontrol>                '
    '<usedataasstream win = \'X\' plat = \' \' web = \' \' />      '
    '      </netcontrol>    </component>    '
    '<component>        <LSAPIWrapper>            '
    '<v100 win = \'X\' plat = \' \' web = \' \' />            '
    '<v101 win = \'X\' plat = \' \' web = \' \' />            '
    '<v102 win = \'X\' plat = \' \' web = \' \' />        '
    '</LSAPIWrapper>    </component>    <component>        '
    '<abapeditor>            '
    '<exists win = \'X\' plat = \' \' web = \' \' />            '
    '<ab4 win = \'X\' plat = \' \' web = \' \' />            '
    '<extended_f1 win = \'X\' plat = \' \' web = \' \' />          '
    '  <backend_rfc_prop win = \'X\' plat = \' \' web = \' \' />\t\t\t'
    '<language_spec win = \'X\' plat = \' \' web = \' \' />        '
    '</abapeditor>    </component>    <component>        '
    '<sapfront>            '
    '<new_bp_icons win = \'X\' plat = \' \' web = \' \' />        '
    '</sapfront>    </component>    <component>        '
    '<gridview>            '
    '<cacheselectedrows win = \'X\' plat = \' \' web = \' \' />\t   '
    ' <stretching win="X" plat="" web="" />\t    '
    '<stretchingHeader win="X" plat="" web="" />\t    '
    '<stretchingToolbar win="X" plat="" web="" />      '
    '<excelinplacewithoutmacros win="X" plat="" web="" />\t   '
    ' <RowGrouping win="X" plat="" web="" />\t\t'
    '<OneUXServiceIcons win="X" plat="" web="" />          '
    '<DisabledRowSelectors win="X" plat="" web="" />        '
    '</gridview>    </component>    <component>        '
    '<crcontainer>            '
    '<feat1 win="X" plat="" web="" />        '
    '</crcontainer>    </component>    <component>        '
    '<sappicture>            '
    '<Tooltip win = \'X\' plat = \' \' web = \' \' />        '
    '</sappicture>    </component><component>   '
    '<sapcache>      <getcachedir win="X" plat="" web="" />  '
    ' </sapcache></component><component>  '
    '<sapguiresources>    '
    '<getthemename win="X" plat="" web="" />   '
    '</sapguiresources></component><component>\t'
    '<treeandgrid>\t\t<dragacceptfiles win="X" plat="" web="" /'
    '>\t</treeandgrid></component><component>\t<treeandgrid>\t\t'
    '<getdroppedexternalfiles win="X" plat="" web="" />\t'
    '</treeandgrid></component><component>        '
    '<sapcalen>\t    <stretchingdaynames win="X" plat="" web="'
    '" />\t    <hijricalendarsupport win=\'X\' plat=\' \' web=\' \' '
    '/>        </sapcalen></component><component>\t'
    '<typeahead>\t\t<more_results_dialog win="X" plat="" web=""'
    ' />\t\t<extended_format win="X" plat="" web="" />\t\t'
    '<okcode_prefix win="X" plat="X" web="X" />\t</typeahead>'
    '</component><component>     <input_field>  \t\t'
    '<exists win = \'X\' plat = \' \' web = \' \' />        '
    '<HistoryPerField win="X" plat=" " web=" "/>\t '
    '</input_field></component><component>\t'
    '<SAPComboBoxCtrl>     \t '
    '<exists win = \'X\' plat = \' \' web = \' \' />\t'
    '</SAPComboBoxCtrl></component><!--<component>   '
    '<Personas>      <AvoidUnnecessaryProxiesActive win = \'X\''
    ' plat = \' \' web = \' \'  />   </Personas></component>-->'
    '<component>\t<icons>\t\t'
    '<alvexpandcollapse win = \'X\' plat = \' \' web = \' \' />\t\t'
    '<shoppingcarts win = \'X\' plat = \' \' web = \' \' />\t\t'
    '<artificialintelligence win = \'X\' plat = \' \' web = \' \' /'
    '>\t</icons></component>   </AvailableFeatures>';
