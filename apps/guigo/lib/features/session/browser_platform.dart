import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// How a [BrowserLaunch] was handed to the platform.
enum BrowserOpened {
  /// The system browser (Safari / the default Android browser), the url as
  /// the server sent it.
  external,

  /// GuiGo's in-app browser, signed on with the server's SSO token.
  signedOn,
}

/// The host side of a server's browser launch (ios/Runner/AppDelegate.swift,
/// android/…/MainActivity.kt, macos/Runner/AppDelegate.swift) over one
/// method channel, `guigo/browser`:
///
/// * `openExternal` {url} — the system browser (iOS UIApplication.open:
/// Safari; Android ACTION_VIEW; macOS NSWorkspace.open). What the real SAP GUI does with
/// ShowURLInDetachedBrowser / ShellExecute / openDocumentOrApplication
/// when no SSO was armed. Answers whether the browser took it.
/// * `openSso` {serviceUrl, url, body} — the launch the server ARMED with
/// its logon-ticket SSO (`EnableSAPSSO`): an in-app web view
/// (iOS WKWebView on a non-persistent data store; Android WebView, its
/// cookies wiped when closed) POSTs [body] — the real GUI's
/// `sap-mysapsso` / `sap-mysapred` form (sapHtmlS.jar SSO_REDIRECT_PAGE)
/// — to the server's SSO service, which sets its MYSAPSSO2 cookie in that
/// web view only and redirects to [url]. "Open in Safari / browser"
/// hands the page on (signed off: Safari / Custom Tabs cannot receive
/// the session's cookie). The host re-checks: both https, one host.
/// A host without it (macOS) leaves the method unimplemented and the
/// launch goes to the system browser, signed off.
///
/// Why not the system browser for SSO: the token must be POSTed (a url
/// would leave it in history and server logs), and neither Safari /
/// SFSafariViewController nor an Android browser intent can be handed a
/// POST body or a cookie — the in-app view is the only place the ticket
/// exchange can happen. The token is never logged, never persisted: it
/// lives in the launch event and the web view's request, nothing else.
abstract final class BrowserPlatform {
  static const MethodChannel channel = MethodChannel('guigo/browser');

  /// Hand [launch] to the platform: signed on in the in-app view when the
  /// server armed SSO for this https host, else the system browser.
  static Future<BrowserOpened> open(BrowserLaunch launch) async {
    final sso = launch.sso;
    if (sso != null && ssoEligible(sso.serviceUrl, launch.url)) {
      try {
        await channel.invokeMethod<bool>('openSso', {
          'serviceUrl': sso.serviceUrl.toString(),
          'url': launch.urlText,
          'body': sso.formBody(launch.urlText),
        });
        return BrowserOpened.signedOn;
      } on MissingPluginException {
        // a host without the in-app view (macos/Runner/AppDelegate.swift):
        // the system browser, signed off — what the real GUI does unarmed
      }
    }
    final ok = await channel.invokeMethod<bool>('openExternal', {
      'url': launch.urlText,
    });
    if (ok == false) {
      throw PlatformException(
        code: 'not_opened',
        message: 'no browser opened ${redactUrl(launch.url)}',
      );
    }
    return BrowserOpened.external;
  }

  /// [open], its failure as a short message for the user (null: opened).
  /// Never names the token, nor the url's query.
  static Future<String?> openOrExplain(BrowserLaunch launch) async {
    try {
      await open(launch);
      return null;
    } on PlatformException catch (e) {
      debugPrint('browser launch failed: ${redactUrl(launch.url)} (${e.code})');
      return 'Could not open ${launch.url.host} in the browser'
          '${e.code == 'not_opened' ? '' : ' (${e.code})'}';
    } on MissingPluginException {
      return 'Opening a browser is not available on this device';
    }
  }
}
