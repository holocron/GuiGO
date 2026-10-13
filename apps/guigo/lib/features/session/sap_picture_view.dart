import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';

/// A picture control (CL_GUI_PICTURE / SAPGUI.ImageCtrl.1) in its region:
/// the bytes the server pushed for it (the STMS landscape GIF, the SE78
/// form graphic BMP) drawn the way its display mode asks — sapImageS.jar
/// SapImage$DISPLAYMODE: Normal (own size, top-left), Stretch (fills the
/// control), Fit (scaled, aspect kept, top-left), NormalCentered,
/// FitCentered. The control has no background of its own: the window shows
/// around a picture smaller than it.
class SapPictureView extends StatelessWidget {
  const SapPictureView({super.key, required this.picture});

  final SapPicture picture;

  static (BoxFit, Alignment) placement(SapPictureMode mode) => switch (mode) {
    SapPictureMode.normal => (BoxFit.none, Alignment.topLeft),
    SapPictureMode.stretch => (BoxFit.fill, Alignment.center),
    SapPictureMode.fit => (BoxFit.contain, Alignment.topLeft),
    SapPictureMode.normalCentered => (BoxFit.none, Alignment.center),
    SapPictureMode.fitCentered => (BoxFit.contain, Alignment.center),
  };

  @override
  Widget build(BuildContext context) {
    final (fit, alignment) = placement(picture.mode);
    return Semantics(
      image: true,
      label: 'Picture ${picture.shell}',
      child: ClipRect(
        child: SizedBox.expand(
          child: Image.memory(
            picture.bytes,
            fit: fit,
            alignment: alignment,
            // the picture's own pixels for Normal: no device-scale blow-up
            scale: 1,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            excludeFromSemantics: true,
            // bytes no codec reads: an empty control, as SAP GUI shows it
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
