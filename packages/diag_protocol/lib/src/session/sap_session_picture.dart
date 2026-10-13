part of 'sap_session.dart';

/// The picture controls of a [SapSession] (sap_picture.dart): the STMS
/// landscape picture, the SE78 form graphic, the Easy Access SESS_IMAGE —
/// every `SAPGUI.ImageCtrl.1` whose `loadImageFromURL[Async]` url arrived
/// with its bytes (a DP push in the same flush call, or one the session's
/// push cache holds). The frontend fetches nothing for them: the server
/// pushes the picture unsolicited (a recorded session srv[12..14]).
extension SapSessionPicture on SapSession {
  SapPictureTracker get _pictureTracker => _w.pictureTracker;

  /// Fold one complete, parsed flush call's picture facts.
  void _ingestPictureCall(FlushCall call) {
    _guarded('picture ingest', () {
      final touched = _pictureTracker.foldCall(
        call,
        shellOfHandle: (h) => _ea.shellAlias[h],
      );
      for (final sh in touched) {
        final p = picture(sh);
        if (p != null) _trace('picture $p');
      }
    });
  }

  /// The picture image control [shell] shows, or null while it has no
  /// bytes (a WebRepository picture nobody pushed, a dead control).
  SapPicture? picture(String shell) {
    if (!_onScreen(shell)) return null;
    return _pictureTracker.build(
      shell,
      segment: (url) => _ea.dpCache.byUrl[url],
    );
  }

  /// Every live, shown picture of the current internal mode by shell.
  Map<String, SapPicture> get pictures => {
    for (final sh in _pictureTracker.urlOf.keys)
      if (_shellVisible(sh))
        if (picture(sh) case final p?) sh: p,
  };

  /// The image shells with a picture (the R3 rung of the composition).
  Set<String> get _pictureShells => pictures.keys.toSet();
}
