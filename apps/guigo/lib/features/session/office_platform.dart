import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:office_doc/office_doc.dart';

/// The host side of the Office pane (ios/Runner/AppDelegate.swift,
/// android/…/MainActivity.kt) over one method channel:
///
/// * `preview` {bytes, fileName} — iOS: QuickLook (QLPreviewController) on
/// a temp file named [fileName] (its extension picks the renderer:
/// .rtf .doc .docx .xls .xlsx …); the file is deleted when the preview
/// is dismissed. Answers true once presented.
/// * `share` {bytes, fileName, mimeType} — iOS: the share sheet
/// (UIActivityViewController: Save to Files, AirDrop, Mail, …) on a temp
/// file, deleted after the sheet closes. Answers whether the user
/// completed an activity.
/// * `saveToDownloads` {bytes, fileName, mimeType} — Android: the file
/// written to Downloads/GuiGo (MediaStore, API 29+) or the app's
/// documents folder; answers where it went.
///
/// Nothing here talks to the SAP server: export is client-side only.
abstract final class OfficePlatform {
  static const MethodChannel channel = MethodChannel('guigo/office_document');

  static bool get _ios =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Whether the platform has a document viewer to hand bytes to.
  static bool get canPreview => _ios;

  /// Whether a document can be exported here (iOS share sheet, Android
  /// Downloads).
  static bool get canExport => _ios || _android;

  /// Shows [bytes] in the platform viewer (iOS QuickLook).
  static Future<bool> preview(Uint8List bytes, String fileName) async {
    if (!_ios) return false;
    final r = await channel.invokeMethod<bool>('preview', {
      'bytes': bytes,
      'fileName': fileName,
    });
    return r ?? false;
  }

  /// Hands [e] to the platform: the share sheet on iOS (null when the user
  /// cancelled, else 'shared'), Downloads on Android (the location it was
  /// saved to).
  static Future<String?> export(OfficeExport e) async {
    final args = {
      'bytes': e.bytes,
      'fileName': e.fileName,
      'mimeType': e.mimeType,
    };
    if (_ios) {
      final done = await channel.invokeMethod<bool>('share', args);
      return done == true ? 'shared' : null;
    }
    if (_android) {
      return channel.invokeMethod<String>('saveToDownloads', args);
    }
    throw UnsupportedError('export is not available on this platform');
  }
}
