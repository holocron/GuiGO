/// The picture control (CL_GUI_PICTURE): which picture each
/// `SAPGUI.ImageCtrl.1` shows, how it is scaled, and the picture's bytes.
///
/// Wire contract (a recorded session srv[12..14], the STMS initial screen
/// SAPLTMSU/0100, real SAP GUI for Windows): ONE flush call — chunked over
/// three frames, step 20 — carries
///
/// CreateControl 117 SAPGUI.CONTAINERCTRL.1 · LinkContainer 117
/// GN_DYN102_IMAGE · CreateControl 118 SAPGUI.ImageCtrl.1 (parent 117,
/// _RESULT row 29) · 29 displayMode = 1 · 29 loadImageFromURLAsync(
/// SAPR3://005056AE930C1FD1AC8056D4B3F4A000)
///
/// and, in the SAME call's RFC_QUEUE, the unsolicited SAPLCNDP
/// DP_PUT_CLIENT_TABLE45A for that DESURL: `TYPE=image SUBTYPE=X-UNKNOWN`,
/// a DATABIN column whose SAP-LZH object inflates to the picture (a GIF87a
/// 547 x 236 there, TOTALSIZE 26392). The frontend requests nothing to get
/// the bytes — no DATAREQUEST, no MIME / HTTP fetch: its answer to the call
/// (gui[6]) is the plain flush answer (the container's 120 / 300 cached
/// props and METRICS). The SE78 form graphic is the same contract with a
/// Windows BMP (reference client, a recorded session s39).
///
/// The `SAPR3://WebRepository/…` family (the Easy Access SESS_IMAGE) is
/// probed with `PublishUrl` first; the push rides only when the frontend
/// answers blank (not cached) — then in the call that re-issues the
/// PublishUrl + loadImageFromURL (a recorded session). A
/// WebRepository picture nobody pushed (the ST04 bar backgrounds
/// DB6_BG_GRAY / DB6_BG_WHITE) has no bytes here: those stay the layout's
/// schematic gauges.
///
/// Display modes — sapImageS.jar `SapImage$DISPLAYMODE` (javap): 0 Normal,
/// 1 Stretch, 2 Fit, 3 NormalCentered, 4 FitCentered — CL_GUI_PICTURE's
/// display_mode_normal / _stretch / _fit / _normal_center / _fit_center.
library;

import 'dart:typed_data';

import '../cfw/dp_cache.dart';
import '../cfw/flush_call.dart';
import '../cfw/html_viewer.dart' show dpScalars, htmlPushOf;

/// CL_GUI_PICTURE display modes (sapImageS.jar SapImage$DISPLAYMODE).
enum SapPictureMode {
  /// 0: the picture at its own size, top-left
  normal,

  /// 1: scaled to fill the control (aspect not kept)
  stretch,

  /// 2: scaled to fit, aspect kept, top-left
  fit,

  /// 3: its own size, centred
  normalCentered,

  /// 4: scaled to fit, aspect kept, centred
  fitCentered;

  static SapPictureMode of(int v) =>
      v >= 0 && v < values.length ? values[v] : normal;
}

/// One pushed picture: the bytes of a DESURL and what the push called them.
class SapPictureContent {
  const SapPictureContent(this.url, this.type, this.subtype, this.bytes);
  final String url;
  final String type;
  final String subtype;
  final Uint8List bytes;
}

/// The picture one image control shows.
class SapPicture {
  const SapPicture({
    required this.shell,
    required this.url,
    required this.bytes,
    this.mode = SapPictureMode.normal,
  });
  final String shell;
  final String url;
  final Uint8List bytes;
  final SapPictureMode mode;

  /// 'gif' | 'png' | 'jpeg' | 'bmp' | null (by the bytes' magic).
  String? get format => pictureFormat(bytes);

  /// The picture's (width, height) in pixels from its header, or null.
  (int, int)? get size => pictureSize(bytes);

  @override
  String toString() =>
      'SapPicture($shell $url ${format ?? '?'} ${size ?? '?'} '
      '${bytes.length} B ${mode.name})';
}

/// The image format by magic bytes.
String? pictureFormat(Uint8List b) {
  bool at(List<int> m) {
    if (b.length < m.length) return false;
    for (var i = 0; i < m.length; i++) {
      if (b[i] != m[i]) return false;
    }
    return true;
  }

  if (at(const [0x47, 0x49, 0x46, 0x38])) return 'gif'; // GIF8
  if (at(const [0x89, 0x50, 0x4e, 0x47])) return 'png';
  if (at(const [0xff, 0xd8, 0xff])) return 'jpeg';
  if (at(const [0x42, 0x4d])) return 'bmp'; // BM
  return null;
}

/// (width, height) from a GIF / PNG / BMP / JPEG header, or null.
(int, int)? pictureSize(Uint8List b) {
  final f = pictureFormat(b);
  final d = ByteData.sublistView(b);
  switch (f) {
    case 'gif' when b.length >= 10:
      return (d.getUint16(6, Endian.little), d.getUint16(8, Endian.little));
    case 'png' when b.length >= 24:
      return (d.getUint32(16), d.getUint32(20));
    case 'bmp' when b.length >= 26:
      return (
        d.getInt32(18, Endian.little),
        d.getInt32(22, Endian.little).abs(),
      );
    case 'jpeg':
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xff) return null;
        final marker = b[i + 1];
        final len = d.getUint16(i + 2);
        // SOF0..SOF15 except DHT (c4), JPG (c8), DAC (cc)
        if (marker >= 0xc0 &&
            marker <= 0xcf &&
            marker != 0xc4 &&
            marker != 0xc8 &&
            marker != 0xcc) {
          return (d.getUint16(i + 7), d.getUint16(i + 5));
        }
        i += 2 + len;
      }
      return null;
    default:
      return null;
  }
}

/// The picture a DP push segment carries, or null when it is no picture
/// (TYPE `image`, or bytes that sniff as one).
SapPictureContent? pictureContentOf(Uint8List seg) {
  final p = htmlPushOf(seg);
  if (p == null) return null;
  var bytes = p.bytes;
  // htmlPushOf ends a string push at its C terminator: a binary picture's
  // trailing zero bytes (BMP pixel rows) come back up to TOTALSIZE
  final ts = dpScalars(seg)['TOTALSIZE'];
  if (ts != null && ts.length == 4) {
    final n = ByteData.sublistView(ts).getUint32(0, Endian.little);
    if (n > bytes.length && n - bytes.length <= 1 << 20) {
      bytes = Uint8List(n)..setRange(0, bytes.length, bytes);
    }
  }
  final isImage = p.type.toLowerCase() == 'image';
  if (!isImage && pictureFormat(bytes) == null) return null;
  return SapPictureContent(p.url, p.type, p.subtype, bytes);
}

const List<String> _loadVerbs = [
  'loadImageFromURL',
  'LoadImageFromURL',
  'loadImageFromURLAsync',
  'LoadImageFromURLAsync',
];

bool _isImageClass(String cls) {
  final u = cls.trim().toUpperCase();
  return u == 'SAPGUI.IMAGECTRL.1' ||
      u == 'COM.SAP.COMPONENTS.CONTROLS.IMAGE.SAPIMAGE';
}

final RegExp _digits = RegExp(r'^\d+$');

/// The picture state of one session window: every image control's url and
/// display mode by shell, and the pushed pictures by url (bounded).
class SapPictureTracker {
  SapPictureTracker({this.maxPictures = 32, this.maxBytes = 16 << 20});

  final int maxPictures;
  final int maxBytes;

  /// image shells in creation order (a re-created shell moves last)
  final List<String> imageShells = [];

  /// shell -> the url its latest loadImageFromURL[Async] named
  final Map<String, String> urlOf = {};

  /// shell -> its latest displayMode
  final Map<String, SapPictureMode> modeOf = {};

  /// url -> the pushed picture (arrival order = eviction order)
  final Map<String, SapPictureContent> byUrl = {};

  /// Fold one complete flush call. [shellOfHandle] resolves a handle the
  /// frontend minted to its kernel shell (the session alias). Returns the
  /// image shells whose url, mode or picture changed.
  Set<String> foldCall(
    FlushCall call, {
    String? Function(String handle)? shellOfHandle,
  }) {
    final touched = <String>{};
    final verbs = call.verbs;
    final meta = verbMeta(call);
    final rowShell = <String, String>{};
    var hasImageVerb = false;
    for (var i = 1; i <= verbs.length; i++) {
      final v = verbs[i - 1];
      if (v.startsWith('CreateControl')) {
        final a = verbNamedArgs(call, i);
        final sh = (a['#1'] ?? '').trim();
        if (!_digits.hasMatch(sh)) continue;
        final res = i <= meta.length ? meta[i - 1].result : null;
        if (res != null && res.isNotEmpty) rowShell[res] = sh;
        imageShells.remove(sh);
        if (_isImageClass(a['#2'] ?? '')) {
          imageShells.add(sh);
          // a re-created shell starts without the old control's picture
          urlOf.remove(sh);
          modeOf.remove(sh);
          touched.add(sh);
        }
      } else if (v == 'displayMode' ||
          v == 'PublishUrl' ||
          _loadVerbs.contains(v)) {
        hasImageVerb = true;
      }
    }
    if (imageShells.length > 256) {
      imageShells.removeRange(0, imageShells.length - 256);
    }
    if (!hasImageVerb) return touched;

    String? shellOf(int i) {
      if (i > meta.length) return null;
      final m = meta[i - 1];
      final s = rowShell[m.obj.trim()];
      if (s != null) return s;
      final h = m.objValue.trim();
      if (h.isEmpty) return null;
      final alias = shellOfHandle?.call(h);
      if (alias != null && imageShells.contains(alias)) return alias;
      if (imageShells.contains(h)) return h;
      // a replayed recording keeps the recording client's handles: the
      // newest image control
      return imageShells.lastOrNull;
    }

    // the pictures pushed in this call (the push rides the call that loads
    // it: a recorded session srv[12..14]; the cold Easy Access re-publish)
    final cache = DpCache()..ingestValue(call.raw);
    for (final u in cache.order) {
      final c = pictureContentOf(cache.byUrl[u]!);
      if (c == null) continue;
      _store(u, c);
      for (final e in urlOf.entries) {
        if (e.value == u) touched.add(e.key);
      }
    }

    for (var i = 1; i <= verbs.length; i++) {
      final v = verbs[i - 1];
      if (v == 'displayMode') {
        final sh = shellOf(i);
        final args = verbArgs(call, i);
        final val = args.isEmpty ? null : int.tryParse(args.first.$2.trim());
        if (sh != null && val != null) {
          modeOf[sh] = SapPictureMode.of(val);
          touched.add(sh);
        }
      } else if (_loadVerbs.contains(v)) {
        final sh = shellOf(i);
        final url = (verbNamedArgs(call, i)['#1'] ?? '').trim();
        if (sh != null && url.isNotEmpty) {
          urlOf[sh] = url;
          touched.add(sh);
        }
      }
    }
    return touched;
  }

  void _store(String url, SapPictureContent c) {
    byUrl
      ..remove(url)
      ..[url] = c;
    var total = 0;
    for (final p in byUrl.values) {
      total += p.bytes.length;
    }
    while (byUrl.length > 1 &&
        (byUrl.length > maxPictures || total > maxBytes)) {
      final k = byUrl.keys.first;
      total -= byUrl.remove(k)!.bytes.length;
    }
  }

  /// Forget the controls of [shells] (torn down with their imode).
  void forget(Iterable<String> shells) {
    for (final s in shells) {
      urlOf.remove(s);
      modeOf.remove(s);
      imageShells.remove(s);
    }
  }

  /// The picture [shell] shows, its bytes from this tracker's pushes or
  /// [segment] (a push the session's cache holds for the url); null while
  /// no bytes are known for its url.
  SapPicture? build(String shell, {Uint8List? Function(String url)? segment}) {
    final url = urlOf[shell];
    if (url == null) return null;
    var c = byUrl[url];
    if (c == null) {
      final seg = segment?.call(url);
      if (seg != null) c = pictureContentOf(seg);
    }
    if (c == null || c.bytes.isEmpty) return null;
    return SapPicture(
      shell: shell,
      url: url,
      bytes: c.bytes,
      mode: modeOf[shell] ?? SapPictureMode.normal,
    );
  }
}
