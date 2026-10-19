/// Browser launches — the server asking the FRONTEND to open a URL in the
/// system's web browser, outside the GUI window (CL_GUI_HTML_VIEWER's
/// detached browser, CL_GUI_FRONTEND_SERVICES=>EXECUTE, an ArchiveLink
/// document, a Web Dynpro / Fiori start), and the SAP logon-ticket SSO the
/// real GUI arms for it.
///
/// Each is an ordinary OLE_FLUSH_CALL verb — the URL is on the DIAG wire,
/// the page itself is then fetched over HTTP by the browser:
///
/// * `ShowURLInDetachedBrowser(url, 1)` on an `SAP.HTMLControl.1` the
/// same server created for it (the real SAP GUI for Windows, the test system DBA
/// cockpit "switch to Web Dynpro": a recorded session
/// srv[80] step 129, url = SVARS item 1, the Web Dynpro application
/// `https://<host>/sap/bc/webdynpro/sap/dba_cockpit?…`; the GUI answers
/// VT_I4 '0', gui[65]). `ShowURLInBrowser(url)` is its sibling (the
/// jar: sapHtmlS.jar SapBrowser.ShowURLInBrowser /
/// ShowURLInDetachedBrowser both call openContentInExternalBrowser);
/// * `ShellExecute(operation, document, parameter, directory, show)` on
/// the frontend services (CL_GUI_FRONTEND_SERVICES=>EXECUTE): the
/// document is #2 (an SVARS item when long). The real Windows GUI
/// answers VT_I4 '42' — the ABAP reads rc < 32 as a failure
/// (a recorded session srv[102]/[111] -> gui[91]/[98],
/// a recorded session srv[1565] -> gui[1285]); a URL document
/// is a browser launch (the reference client's a recorded session: the signed
/// SAP Content Server url of an archived attachment);
/// * `openDocumentOrApplication(document, application, …)` /
/// `showURL(url)` on the Java GUI's GuiSapInfo (platinr3S.jar: an empty
/// application and an `isURL` document -> openBrowser; the real Java GUI
/// answers VT_I8 '0', a recorded session srv[32] -> gui[24],
/// a recorded session srv[32] -> gui[23]).
///
/// SSO (single sign-on to the browser): the server ARMS the HTML control
/// before it launches — `EnableSAPSSO(1, <token>, <service url>)`, the
/// service being `https://<host>:443/sap/public/myssocntl?sap-client=<c>`
/// (a recorded session srv[79] verb 9, on the control
/// CreateControl made in the same flush; the GUI answers VT_I4, gui[64]).
/// The token is NOT a MYSAPSSO2 cookie: the frontend POSTs it to the
/// service — form fields `sap-mysapsso=<token>` and `sap-mysapred=<target
/// url>` — and the server answers with its MYSAPSSO2 cookie for its own
/// domain and a redirect to the target (sapHtmlS.jar SapBrowser:
/// EnableSAPSSO(boolean, String, String) stores mEnabledSSO / mSSOTicket /
/// mSSOServiceURL; openContentInExternalBrowser opens SSO_REDIRECT_PAGE,
/// a self-submitting `<form method="post" action="%s">` with those two
/// hidden inputs, then CLEARS mEnabledSSO — one launch per arming; the
/// in-control browser sends the same two as headers to the same service).
///
/// The token is a credential: it is never traced ([BrowserSso.toString],
/// [BrowserLaunch.toString] redact it), lives only in the launch event, and
/// is attached ONLY when the service and the target are both https on the
/// same host and port — never handed to a host the server did not launch.
library;

import 'flush_call.dart';
import 'svars.dart' show Rec;

/// The token the frontend posts to the ticket service, and that service.
class BrowserSso {
  BrowserSso(this.serviceUrl, this.token);

  /// `https://<host>[:port]/sap/public/myssocntl?sap-client=<c>` — the
  /// server's SSO service, same scheme / host / port as the launch.
  final Uri serviceUrl;

  /// The one-time logon token `EnableSAPSSO` carried. Secret: never log,
  /// never persist.
  final String token;

  /// The form the real GUI posts to [serviceUrl] (its SSO_REDIRECT_PAGE):
  /// the token and the page the service redirects to once it has set the
  /// MYSAPSSO2 cookie — [redirect] verbatim, as the server spelled it
  /// ([BrowserLaunch.urlText]).
  Map<String, String> formFields(String redirect) => {
    'sap-mysapsso': token,
    'sap-mysapred': redirect,
  };

  /// [formFields] as an `application/x-www-form-urlencoded` body.
  String formBody(String redirect) => formFields(redirect).entries
      .map(
        (e) =>
            '${Uri.encodeQueryComponent(e.key)}='
            '${Uri.encodeQueryComponent(e.value)}',
      )
      .join('&');

  @override
  String toString() => 'BrowserSso(${redactUrl(serviceUrl)}, token redacted)';
}

/// One URL the server asked the frontend to open in the web browser.
class BrowserLaunch {
  BrowserLaunch({
    required this.url,
    String? urlText,
    required this.verb,
    required this.step,
    this.shell,
    this.sso,
  }) : urlText = urlText ?? url.toString();

  /// The page to open (http / https only).
  final Uri url;

  /// [url] exactly as the server spelled it (a [Uri] lower-cases the host):
  /// what is opened, and what the SSO form redirects to.
  final String urlText;

  /// The flush verb that asked (`ShowURLInDetachedBrowser`, `ShellExecute`,
  /// `openDocumentOrApplication`, …).
  final String verb;

  /// The dialog step of the flush that carried it.
  final int step;

  /// The control the verb ran on (the HTML control's shell), when known.
  final String? shell;

  /// The SSO the server armed for this launch, when it did and the target
  /// is eligible ([BrowserLaunchTracker]); null = open the url as is.
  final BrowserSso? sso;

  /// Always a new browser window: the real GUI never navigates its own.
  String get target => '_blank';

  /// GET the url, or POST the SSO form to the service (which redirects).
  String get method => sso == null ? 'GET' : 'POST';

  @override
  String toString() =>
      'BrowserLaunch($verb ${redactUrl(url)}${sso == null ? '' : ', SSO'}, '
      'step $step)';
}

/// [url] without its user info, query and fragment — a content-server url
/// carries a bearer `secKey=` there — for traces (the reference client's
/// ea_download.redact_url).
String redactUrl(Uri url) {
  final port = url.hasPort ? ':${url.port}' : '';
  final base = '${url.scheme}://${url.host}$port${url.path}';
  return url.hasQuery || url.hasFragment ? '$base?…' : base;
}

/// The HTML control's external-browser verbs (sapHtmlS.jar SapBrowser).
const Set<String> detachedBrowserVerbs = {
  'ShowURLInDetachedBrowser',
  'ShowURLInBrowser',
};

/// CL_GUI_FRONTEND_SERVICES=>EXECUTE on the Windows OCX (and the Java
/// GuiSapInfo's lower-case twins).
const Set<String> shellExecuteVerbs = {
  'ShellExecute',
  'ShellExecuteEx',
  'shellExecute',
  'shellExecuteEx',
};

/// The Java GuiSapInfo document opens: `openDocumentOrApplication` and
/// `showURL` (lower-case s — `ShowURL` is the HTML viewer's in-place load).
const Set<String> documentOpenVerbs = {
  'openDocumentOrApplication',
  'OpenDocumentOrApplication',
  'showURL',
};

/// The answer the real SAP GUI for Windows gives a `ShellExecute` that
/// opened its document: Win32's HINSTANCE > 32 contract, VT_I4 '42'
/// (a recorded session gui[91]/[98], a recorded session
/// gui[1285]); the ABAP raises on rc < 32.
const String shellExecuteOpened = '42';

/// The `ShellExecute` answer for verb [i] (1-based) of [call]: [shellExecute
/// Opened] when its document is a web url this frontend hands the browser,
/// else '0' — a local file (`C:\…\gw_client_data_….txt`) this device never
/// downloaded is not opened, and the ABAP reports the failure.
String shellExecuteAnswer(FlushCall call, int i) =>
    browserUrlOfVerb(call, i) != null ? shellExecuteOpened : '0';

/// The text of verb [i]'s (1-based) argument [name] (`#1`, `#2` …): its
/// VARS value, or — a `_SPARAMETER` row — the SVARS item that row numbers
/// (a value longer than a VARS cell: every url on record rides there).
String? verbArgText(FlushCall call, int i, String name) {
  final p = _paramByVerbArg(call.params)['$i\u0000$name'];
  if (p == null) return null;
  final s = int.tryParse(p.slot.trim());
  if (s == null || s < 1 || s > call.vars.length) return null;
  final row = call.vars[s - 1];
  if (row.name == '_SPARAMETER') {
    final k = int.tryParse(row.valueText);
    if (k == null || k < 1 || k > call.svars.length) return null;
    return call.svars[k - 1].trim();
  }
  return row.valueText;
}

/// The FIRST PARAMS row per (verb objid, argument name), both trimmed —
/// built once per parsed PARAMS table. [verbArgText] is asked per argument
/// of every verb by the DOI fold and the frontend-file answers; a scan of
/// the whole table per argument is O(args x params) (the 4 264-verb /
/// 10 660-row batch: ~10^8 compares per pass).
final Expando<Map<String, Rec>> _paramArgIndex =
    Expando('PARAMS row by verb argument');

Map<String, Rec> _paramByVerbArg(List<Rec> rows) =>
    _paramArgIndex[rows] ??= () {
      final m = <String, Rec>{};
      for (final p in rows) {
        m.putIfAbsent('${p.objid.trim()}\u0000${p.name.trim()}', () => p);
      }
      return m;
    }();

/// The web url verb [i] (1-based) of [call] asks the frontend to open in a
/// browser, or null (not a launch verb, no url, not http / https).
Uri? browserUrlOfVerb(FlushCall call, int i) {
  final t = browserUrlTextOfVerb(call, i);
  return t == null ? null : webUrl(t);
}

/// [browserUrlOfVerb] as the server spelled it, or null.
String? browserUrlTextOfVerb(FlushCall call, int i) {
  if (i < 1 || i > call.verbs.length) return null;
  final verb = call.verbs[i - 1];
  String? arg;
  if (detachedBrowserVerbs.contains(verb)) {
    arg = verbArgText(call, i, '#1');
  } else if (shellExecuteVerbs.contains(verb)) {
    arg = verbArgText(call, i, '#2');
  } else if (verb == 'showURL') {
    arg = verbArgText(call, i, '#1');
  } else if (documentOpenVerbs.contains(verb)) {
    // an application named: the document is opened WITH it, not browsed
    if ((verbArgText(call, i, '#2') ?? '').trim().isNotEmpty) return null;
    arg = verbArgText(call, i, '#1');
  }
  return webUrl(arg) == null ? null : arg!.trim();
}

/// [text] as an absolute http / https url with a host, else null.
Uri? webUrl(String? text) {
  final t = text?.trim() ?? '';
  if (t.isEmpty) return null;
  final u = Uri.tryParse(t);
  if (u == null || !u.hasAuthority || u.host.isEmpty) return null;
  final scheme = u.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  return u;
}

/// Whether the SSO [service] may receive the token for a launch of
/// [target]: both https, the same host (case-insensitive) and port.
bool ssoEligible(Uri service, Uri target) =>
    service.scheme.toLowerCase() == 'https' &&
    target.scheme.toLowerCase() == 'https' &&
    service.host.isNotEmpty &&
    service.host.toLowerCase() == target.host.toLowerCase() &&
    service.port == target.port;

/// The browser launches of a session's flush calls, and the SSO armed on
/// the HTML controls between them (`EnableSAPSSO` in one flush, the launch
/// in a later one: a recorded session srv[79] -> srv[80]).
class BrowserLaunchTracker {
  /// Armed controls kept at most (a screen arms its own; the oldest go).
  static const int maxArmed = 8;

  final Map<String, (Uri, String)> _armed = {};

  /// How many controls hold an armed SSO token.
  int get armedCount => _armed.length;

  /// Forget every armed token (the session ends).
  void clear() => _armed.clear();

  /// Fold [call] (the flush closed at [step]): arm / disarm the controls
  /// its `EnableSAPSSO` verbs name, and return its launches in verb order.
  ///
  /// A verb's control is the shell its object resolves to: a CreateControl
  /// of the same flush (its `_RESULT` row), else [aliasOf] the object's
  /// handle (the session's server-handle <-> shell map), else the handle.
  /// [note] hears why an armed token was NOT attached (never the token).
  List<BrowserLaunch> fold(
    FlushCall call, {
    required int step,
    String? Function(String handle)? aliasOf,
    void Function(String why)? note,
  }) {
    final verbs = call.verbs;
    if (verbs.isEmpty) return const [];
    var any = false;
    for (final v in verbs) {
      if (v == 'EnableSAPSSO' ||
          detachedBrowserVerbs.contains(v) ||
          shellExecuteVerbs.contains(v) ||
          documentOpenVerbs.contains(v)) {
        any = true;
        break;
      }
    }
    if (!any) return const [];
    final meta = verbMeta(call);
    // CreateControl's _RESULT row -> the shell it created
    final rowShell = <String, String>{};
    for (var i = 1; i <= verbs.length; i++) {
      if (!verbs[i - 1].startsWith('CreateControl')) continue;
      final sh = (verbNamedArgs(call, i)['#1'] ?? '').trim();
      final res = i <= meta.length ? (meta[i - 1].result ?? '').trim() : '';
      if (res.isNotEmpty && sh.isNotEmpty) rowShell[res] = sh;
    }
    String? controlOf(int i) {
      if (i > meta.length) return null;
      final m = meta[i - 1];
      final created = rowShell[m.obj.trim()];
      if (created != null) return created;
      final handle = m.objValue.trim();
      if (handle.isEmpty) return null;
      return aliasOf?.call(handle) ?? handle;
    }

    final out = <BrowserLaunch>[];
    for (var i = 1; i <= verbs.length; i++) {
      final verb = verbs[i - 1];
      if (verb == 'EnableSAPSSO') {
        final key = controlOf(i);
        if (key == null) continue;
        final on = (verbArgText(call, i, '#1') ?? '').trim().toUpperCase();
        final token = (verbArgText(call, i, '#2') ?? '').trim();
        final service = webUrl(verbArgText(call, i, '#3'));
        _armed.remove(key);
        if ((on == '1' || on == 'X' || on == 'TRUE' || on == '-1') &&
            token.isNotEmpty &&
            service != null) {
          _armed[key] = (service, token);
          while (_armed.length > maxArmed) {
            _armed.remove(_armed.keys.first);
          }
        }
        continue;
      }
      final text = browserUrlTextOfVerb(call, i);
      final url = webUrl(text);
      if (text == null || url == null) continue;
      String? shell;
      BrowserSso? sso;
      if (detachedBrowserVerbs.contains(verb)) {
        shell = controlOf(i);
        // one launch per arming (the jar clears mEnabledSSO after use)
        final armed = shell == null ? null : _armed.remove(shell);
        if (armed != null) {
          final (service, token) = armed;
          if (ssoEligible(service, url)) {
            sso = BrowserSso(service, token);
          } else {
            note?.call(
              'SSO not applied: service ${redactUrl(service)} is not '
              'https on the launched host ${url.host}',
            );
          }
        }
      }
      out.add(
        BrowserLaunch(
          url: url,
          urlText: text,
          verb: verb,
          step: step,
          shell: shell,
          sso: sso,
        ),
      );
    }
    return out;
  }
}
