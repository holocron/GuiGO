import Flutter
import QuickLook
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// The Office pane's host side (lib/features/session/office_platform.dart).
  private var officeDocuments: OfficeDocumentChannel?
  /// The server's browser launches (lib/features/session/browser_platform.dart).
  private var browser: BrowserChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GuiGoOfficeDocument") {
      officeDocuments = OfficeDocumentChannel(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GuiGoBrowser") {
      browser = BrowserChannel(messenger: registrar.messenger())
    }
  }
}

/// The view controller to present from: the key window's topmost.
private func topPresenter() -> UIViewController? {
  let windows = UIApplication.shared.connectedScenes
    .compactMap { $0 as? UIWindowScene }
    .flatMap { $0.windows }
  var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
  while let presented = top?.presentedViewController { top = presented }
  return top
}

/// `guigo/browser`: a url the SAP server asked the frontend to open in the
/// web browser (ShowURLInDetachedBrowser, ShellExecute, …).
///
/// * `openExternal` {url}: Safari (UIApplication.open), http / https only;
///   answers whether it opened.
/// * `openSso` {serviceUrl, url, body}: the launch the server armed with
///   its logon-ticket SSO. A WKWebView on a NON-PERSISTENT data store POSTs
///   body (`sap-mysapsso=…&sap-mysapred=<url>`, the real SAP GUI's SSO form)
///   to serviceUrl; the server sets its MYSAPSSO2 cookie in that store only
///   and redirects to url. Refused unless serviceUrl and url are both https
///   on the same host and port. The token is never logged and dies with the
///   view controller (request and data store released on dismissal).
final class BrowserChannel: NSObject {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "guigo/browser", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private static func webURL(_ text: String?) -> URL? {
    guard let text = text, let url = URL(string: text),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host, !host.isEmpty
    else { return nil }
    return url
  }

  private static func port(_ url: URL) -> Int {
    if let p = url.port { return p }
    return url.scheme?.lowercased() == "https" ? 443 : 80
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "openExternal":
      guard let url = BrowserChannel.webURL(args?["url"] as? String) else {
        result(FlutterError(code: "bad_url", message: "an http(s) url is required", details: nil))
        return
      }
      UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
    case "openSso":
      guard let service = BrowserChannel.webURL(args?["serviceUrl"] as? String),
        let target = BrowserChannel.webURL(args?["url"] as? String),
        let body = args?["body"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "serviceUrl, url and body required", details: nil))
        return
      }
      // the token goes to the host the server launched, over https only
      guard service.scheme?.lowercased() == "https", target.scheme?.lowercased() == "https",
        service.host?.lowercased() == target.host?.lowercased(),
        BrowserChannel.port(service) == BrowserChannel.port(target)
      else {
        result(FlutterError(code: "sso_refused", message: "the SSO service is not the launched https host", details: nil))
        return
      }
      guard let presenter = topPresenter() else {
        result(FlutterError(code: "no_window", message: "no view controller to present from", details: nil))
        return
      }
      var request = URLRequest(url: service)
      request.httpMethod = "POST"
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.httpBody = Data(body.utf8)
      let browser = SsoBrowserController(request: request, title: target.host ?? "")
      let nav = UINavigationController(rootViewController: browser)
      nav.modalPresentationStyle = .fullScreen
      presenter.present(nav, animated: true)
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// The in-app browser of an SSO launch: one WKWebView on its own
/// non-persistent website data store (cookies, the MYSAPSSO2 the server
/// sets included, vanish with it), "Open in Safari" for the current page.
final class SsoBrowserController: UIViewController, WKNavigationDelegate, WKUIDelegate {
  private var pending: URLRequest?
  private let host: String
  private var webView: WKWebView?

  init(request: URLRequest, title: String) {
    pending = request
    host = title
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = host
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    // identify as Mobile Safari: WKWebView's own user agent carries no
    // `Version/… Safari/…` token, and Web Dynpro ABAP's browser check
    // refuses it — "Impossible de traiter le message E WEBDYNPRO_RT 015"
    // (This browser is not supported) on a Web Dynpro test launch
    let ios = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    config.applicationNameForUserAgent = "Version/\(ios).0 Mobile/15E148 Safari/604.1"
    let web = WKWebView(frame: view.bounds, configuration: config)
    web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    web.navigationDelegate = self
    web.uiDelegate = self
    view.addSubview(web)
    webView = web
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done, target: self, action: #selector(close))
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "Open in Safari", style: .plain, target: self, action: #selector(openInSafari))
    if let request = pending {
      web.load(request)
    }
    // the token rides only the request just handed to WebKit
    pending = nil
  }

  @objc private func close() {
    webView?.stopLoading()
    dismiss(animated: true)
  }

  /// The page as it is now, in Safari — signed off there (its cookie jar is
  /// not this view's).
  @objc private func openInSafari() {
    guard let url = webView?.url,
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else { return }
    UIApplication.shared.open(url, options: [:], completionHandler: nil)
  }

  // a target=_blank link / window.open: in this view (one window)
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if navigationAction.targetFrame == nil {
      webView.load(navigationAction.request)
    }
    return nil
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    title = webView.url?.host ?? host
  }
}

/// `guigo/office_document`: hands a DOI document's bytes to iOS.
///
/// * `preview` {bytes, fileName}: QuickLook (QLPreviewController) on a temp
///   file named fileName — its extension picks the renderer (.rtf .doc
///   .docx .xls .xlsx …); the file is deleted when the preview is dismissed.
/// * `share` {bytes, fileName, mimeType}: the share sheet
///   (UIActivityViewController: Save to Files, AirDrop, Mail …) on a temp
///   file, deleted when the sheet closes; answers whether an activity
///   completed.
///
/// Client-side only: nothing goes back to the SAP server.
final class OfficeDocumentChannel: NSObject, QLPreviewControllerDataSource,
  QLPreviewControllerDelegate
{
  private let channel: FlutterMethodChannel
  /// The file the open preview shows, and its private temp folder.
  private var previewItem: URL?
  private var previewFolder: URL?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "guigo/office_document", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "preview" || call.method == "share" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any],
      let data = args["bytes"] as? FlutterStandardTypedData,
      let name = args["fileName"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "bytes and fileName required", details: nil))
      return
    }
    guard let presenter = topViewController() else {
      result(FlutterError(code: "no_window", message: "no view controller to present from", details: nil))
      return
    }
    let file: (folder: URL, url: URL)
    do {
      file = try writeTemp(data.data, named: name)
    } catch {
      result(FlutterError(code: "write_failed", message: error.localizedDescription, details: nil))
      return
    }
    if call.method == "preview" {
      cleanUpPreview()
      previewItem = file.url
      previewFolder = file.folder
      let ql = QLPreviewController()
      ql.dataSource = self
      ql.delegate = self
      presenter.present(ql, animated: true)
      result(true)
    } else {
      let sheet = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
      if let pop = sheet.popoverPresentationController {
        // iPad: anchored at the top right, where the pane's export button is
        pop.sourceView = presenter.view
        pop.sourceRect = CGRect(x: presenter.view.bounds.maxX - 44, y: 44, width: 1, height: 1)
        pop.permittedArrowDirections = [.up]
      }
      var answered = false
      sheet.completionWithItemsHandler = { _, completed, _, _ in
        try? FileManager.default.removeItem(at: file.folder)
        if !answered {
          answered = true
          result(completed)
        }
      }
      presenter.present(sheet, animated: true)
    }
  }

  /// [data] in a fresh folder of the temp directory under [name] (path
  /// separators stripped: the Dart side already sanitised it).
  private func writeTemp(_ data: Data, named name: String) throws -> (folder: URL, url: URL) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("guigo-office-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var safe = name.replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    if safe.isEmpty || safe.hasPrefix(".") { safe = "document" + safe }
    let url = folder.appendingPathComponent(safe, isDirectory: false)
    try data.write(to: url, options: [.atomic, .completeFileProtection])
    return (folder, url)
  }

  private func cleanUpPreview() {
    if let folder = previewFolder { try? FileManager.default.removeItem(at: folder) }
    previewFolder = nil
    previewItem = nil
  }

  private func topViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  // MARK: QLPreviewControllerDataSource / Delegate

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    return previewItem == nil ? 0 : 1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
    -> QLPreviewItem
  {
    return (previewItem ?? URL(fileURLWithPath: "/dev/null")) as NSURL
  }

  func previewControllerDidDismiss(_ controller: QLPreviewController) {
    cleanUpPreview()
  }
}
