part of 'sap_session.dart';

/// The browser-launch side of a [SapSession] (browser_launch.dart): the
/// URLs the server asks the frontend to open in the web browser, with the
/// SSO the server armed for them, as [browserLaunches] events.
///
/// Receive-only: the flush that carried the launch is answered as the real
/// GUI answers it (VT_I4 '0' / '42', flush_call.dart, ea_responder.dart)
/// whether or not anybody listens — the session never waits on the app's
/// browser.
class _BrowserState {
  final BrowserLaunchTracker tracker = BrowserLaunchTracker();
  final StreamController<BrowserLaunch> launches =
      StreamController<BrowserLaunch>.broadcast();
}

final Expando<_BrowserState> _browserStates = Expando('browserState');

extension SapSessionBrowser on SapSession {
  _BrowserState get _browser => _browserStates[this] ??= _BrowserState();

  /// Every URL the server asks the frontend to open in a web browser
  /// (`ShowURLInDetachedBrowser`, `ShellExecute` of a web url, the Java
  /// GUI's `openDocumentOrApplication`), in wire order — with
  /// [BrowserLaunch.sso] when the server armed its logon-ticket SSO for the
  /// same https host. Broadcast: a launch nobody listens to is dropped.
  /// The event carries the SSO token; it is never traced or kept here.
  Stream<BrowserLaunch> get browserLaunches => _browser.launches.stream;

  /// Fold one complete flush call (closed at [closingStep]): arm the SSO it
  /// enables, and publish its launches.
  void _foldBrowserCall(FlushCall call, int closingStep) {
    final st = _browser;
    final launches = st.tracker.fold(
      call,
      step: closingStep,
      aliasOf: (h) => _ea.shellAlias[h],
      note: _trace,
    );
    for (final l in launches) {
      // the url without its query (a bearer secKey rides there), never the
      // token
      _trace('browser launch: $l');
      if (!st.launches.isClosed) st.launches.add(l);
    }
  }

  /// The session ended: drop every armed token and close the stream.
  Future<void> _closeBrowserLaunches() async {
    final st = _browserStates[this];
    if (st == null) return;
    st.tracker.clear();
    await st.launches.close();
  }
}
