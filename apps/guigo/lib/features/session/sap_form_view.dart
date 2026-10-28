import 'dart:convert' show base64Decode;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:office_doc/office_doc.dart';

import 'sap_netplan_view.dart' show StyledLabelCache;

/// An Adobe form template (SFP's Layout tab, `PDFXMLDesigner.Document`)
/// shown READ-ONLY, all of it:
///
/// * **Layout** — the pages as the geometry pass laid them out (zoom and
/// pan); a tap selects an element and shows its details below;
/// * **Structure** — every element of the template tree with its
/// attributes;
/// * **Scripts** — every FormCalc / JavaScript the template carries,
/// verbatim;
/// * **Bindings** — every field's data binding;
/// * **Source** — the raw XDP.
///
/// No Designer runs here and no script executes — this is the inspection
/// view of what the server pushed.
class SapFormView extends StatefulWidget {
  const SapFormView({super.key, required this.form});

  final XfaForm form;

  @override
  State<SapFormView> createState() => _SapFormViewState();
}

class _SapFormViewState extends State<SapFormView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  XfaElement? _selected;
  // replaced (not mutated) per decoded image: the painter's shouldRepaint
  // compares snapshots, and a mutated map IS the old painter's map too —
  // the logo decoded but the page never repainted
  Map<String, ui.Image> _images = {};

  /// The laid-out texts of the pages, kept across paints: a tap on a
  /// field (the selection repaint) or a decoded image draws them, it lays
  /// none out again (audit 2026-10-23 P-8).
  final _labels = StyledLabelCache();

  /// How many text layouts the pages made (tests read it).
  int get labelLayouts => _labels.layouts;

  XfaForm get _form => widget.form;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: _form.scripts.isEmpty && _form.bindings.isEmpty ? 3 : 5,
      vsync: this,
    );
    _decodeImages();
  }

  @override
  void dispose() {
    _tabs.dispose();
    for (final i in _images.values) {
      i.dispose();
    }
    _labels.clear();
    super.dispose();
  }

  void _decodeImages() {
    for (final p in _form.placed) {
      final img = p.image;
      if (img == null || _images.containsKey(img.base64)) continue;
      try {
        final bytes = base64Decode(img.base64);
        ui.instantiateImageCodec(bytes).then((codec) async {
          final frame = await codec.getNextFrame();
          if (!mounted) {
            frame.image.dispose();
            return;
          }
          // a NEW map: the painter diff must see a different snapshot
          setState(() => _images = {..._images, img.base64: frame.image});
        });
      } on FormatException {
        // a broken picture: the frame outline is drawn instead
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tabs = <Tab>[
      const Tab(text: 'Layout'),
      const Tab(text: 'Structure'),
      if (_form.scripts.isNotEmpty || _form.bindings.isNotEmpty) ...[
        Tab(text: 'Scripts (${_form.scripts.length})'),
        const Tab(text: 'Bindings'),
      ],
      const Tab(text: 'Source'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: scheme.surfaceContainerHigh,
          child: TabBar(
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            dividerHeight: 0,
            tabs: tabs,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              _layoutTab(context),
              _structureTab(context),
              if (_form.scripts.isNotEmpty || _form.bindings.isNotEmpty) ...[
                _scriptsTab(context),
                _bindingsTab(context),
              ],
              _sourceTab(context),
            ],
          ),
        ),
      ],
    );
  }

  // --- Layout -----------------------------------------------------------------

  Widget _layoutTab(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _FormPages(
            form: _form,
            images: _images,
            selected: _selected,
            labels: _labels,
            onSelect: (e) => setState(() => _selected = e),
          ),
        ),
        if (_selected != null)
          Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
        if (_selected != null)
          SizedBox(
            height: 160,
            child: _DetailsPane(element: _selected!, form: _form),
          ),
      ],
    );
  }

  // --- Structure ---------------------------------------------------------------

  Widget _structureTab(BuildContext context) {
    final root = _form.root;
    if (root == null) return const Center(child: Text('Empty template'));
    final scheme = Theme.of(context).colorScheme;
    final tree = ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        _StructureTile(
          element: root,
          depth: 0,
          selected: _selected,
          onSelect: (e) => setState(() => _selected = e),
        ),
      ],
    );
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < 600) {
        // a phone's width split in two left the SOM paths and the values
        // a few characters each: below the tablet breakpoint the details
        // stack under the tree (as the Layout tab's do), the tree taking
        // the whole height while nothing is selected
        final sel = _selected;
        final h = box.hasBoundedHeight
            ? (box.maxHeight * 0.4).clamp(160.0, 280.0)
            : 200.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: tree),
            if (sel != null) ...[
              Divider(height: 1, color: scheme.outlineVariant),
              SizedBox(
                key: const ValueKey('form-structure-details'),
                height: h,
                child: _DetailsPane(element: sel, form: _form, full: true),
              ),
            ],
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 5, child: tree),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 4,
            child: _selected == null
                ? Center(
                    child: Text(
                      'Select an element',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  )
                : _DetailsPane(element: _selected!, form: _form, full: true),
          ),
        ],
      );
    });
  }

  // --- Scripts -----------------------------------------------------------------

  Widget _scriptsTab(BuildContext context) {
    final scripts = _form.scripts;
    if (scripts.isEmpty) {
      return const Center(child: Text('The template carries no scripts'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: scripts.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _ScriptCard(script: scripts[i]),
    );
  }

  // --- Bindings ------------------------------------------------------------------

  Widget _bindingsTab(BuildContext context) {
    final bindings = _form.bindings;
    if (bindings.isEmpty) {
      return const Center(child: Text('The template declares no bindings'));
    }
    final scheme = Theme.of(context).colorScheme;
    final rows = bindings.toList();
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingTextStyle: TextStyle(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
            columns: const [
              DataColumn(label: Text('Field'), tooltip: 'SOM path'),
              DataColumn(label: Text('Binds'), tooltip: 'bind ref'),
              DataColumn(label: Text('Widget')),
              DataColumn(label: Text('Match')),
              DataColumn(label: Text('Picture')),
              DataColumn(label: Text('Calculates'), tooltip: 'calculate script'),
            ],
            rows: [
              for (final b in rows)
                DataRow(
                  selected: identical(_selected, b),
                  onSelectChanged: (_) => setState(() => _selected = b),
                  cells: [
                    DataCell(
                      SizedBox(
                        width: 260,
                        child: Tooltip(
                          message: b.som,
                          child: Text(
                            b.som,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontFamily: 'Menlo'),
                          ),
                        ),
                      ),
                    ),
                    DataCell(
                      SizedBox(
                        width: 280,
                        child: Tooltip(
                          message: b.ref ?? '',
                          child: Text(
                            b.ref ?? '—',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Menlo',
                              color: b.ref == null
                                  ? scheme.onSurfaceVariant
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                    DataCell(Text(b.ui)),
                    DataCell(Text(b.match)),
                    DataCell(Text(b.picture ?? '')),
                    DataCell(
                      b.calculate == null
                          ? Text('—', style: TextStyle(color: scheme.onSurfaceVariant))
                          : const Text('yes'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Source -----------------------------------------------------------------

  Widget _sourceTab(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = _form.lines;
    final mono = TextStyle(
      fontFamily: 'Menlo',
      fontSize: 11,
      color: scheme.onSurface,
    );
    // a line a row, built as the rows scroll into view: a template runs
    // to hundreds of KB (a logo is one base64 line), and one paragraph of
    // all of it was shaped whole on every visit to the tab. The rows
    // wrap, as the one paragraph did. The selection reaches only the rows
    // on screen, so the whole source copies from the header's button
    return Container(
      color: scheme.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 36,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${lines.length} lines',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('form-source-copy'),
                  tooltip: 'Copy source',
                  iconSize: 18,
                  icon: const Icon(Icons.copy_all_outlined),
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: _form.source)),
                ),
              ],
            ),
          ),
          Expanded(
            child: Scrollbar(
              child: SelectionArea(
                child: ListView.builder(
                  key: const ValueKey('form-source'),
                  padding: const EdgeInsets.all(8),
                  itemCount: lines.length,
                  itemBuilder: (_, i) => Text(lines[i], style: mono),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The page renderer
// ---------------------------------------------------------------------------

class _FormPages extends StatelessWidget {
  const _FormPages({
    required this.form,
    required this.images,
    required this.selected,
    required this.onSelect,
    this.labels,
  });

  final XfaForm form;
  final Map<String, ui.Image> images;
  final XfaElement? selected;
  final ValueChanged<XfaElement> onSelect;
  final StyledLabelCache? labels;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final page = form.pages.first;
      final pages = <Widget>[
        for (var i = 0; i < form.pages.length; i++)
          _PageCard(
            form: form,
            pageIndex: i,
            images: images,
            selected: selected,
            onSelect: onSelect,
            labels: labels,
          ),
      ];
      if (form.pages.length == 1) {
        // fit the one page to the pane's width
        return InteractiveViewer(
          maxScale: 8,
          minScale: 0.2,
          child: Center(
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: page.w,
                height: page.h,
                child: pages.single,
              ),
            ),
          ),
        );
      }
      // several pages: constrained:false or the viewer hands the Column
      // the pane's bounded height and the stack of 842-pt pages overflows
      // it (the striped band on the live form). The stack is fitted to
      // the pane's width — never past its natural size, as the one page
      // is — the FittedBox keeping the Column self-sized: an A4 page on a
      // phone opened at 100 %, its right third off screen until a pinch
      final fitW =
          box.hasBoundedWidth ? math.min(box.maxWidth, page.w) : page.w;
      return InteractiveViewer(
        maxScale: 8,
        minScale: 0.2,
        constrained: false,
        child: SizedBox(
          width: fitW,
          child: FittedBox(
            fit: BoxFit.fitWidth,
            child: SizedBox(
              width: page.w,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  for (final w in pages) ...[w, const SizedBox(height: 24)],
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _PageCard extends StatelessWidget {
  const _PageCard({
    required this.form,
    required this.pageIndex,
    required this.images,
    required this.selected,
    required this.onSelect,
    this.labels,
  });

  final XfaForm form;
  final int pageIndex;
  final Map<String, ui.Image> images;
  final XfaElement? selected;
  final ValueChanged<XfaElement> onSelect;
  final StyledLabelCache? labels;

  static const double _scale = 1.0; // 1 pt = 1 logical px before zoom

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final page = form.pages[pageIndex];
    return GestureDetector(
      key: ValueKey('form-page-$pageIndex'),
      onTapUp: (d) {
        final p = d.localPosition / _scale;
        XfaElement? hit;
        // topmost = last painted = last in the placed list
        for (final e in form.placed) {
          if (e.page != pageIndex) continue;
          final r = e.rect!;
          if (p.dx >= r.x && p.dx <= r.right && p.dy >= r.y && p.dy <= r.bottom) {
            hit = e;
          }
        }
        if (hit != null) onSelect(hit);
      },
      // the page, its border and shadow recorded once: a pinch or a pan
      // replays the picture under the viewer's transform instead of
      // laying every field's text out again on each frame of the gesture
      // (the viewer rebuilds per frame; the nearest boundary above was the
      // tab page's)
      child: RepaintBoundary(
        child: Container(
        width: page.w,
        height: page.h,
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          // the page is PAPER whatever the app theme — a dark surface made
          // the sheet vanish into the dark UI and the form read as empty
          color: const Color(0xffffffff),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: CustomPaint(
          size: Size(page.w, page.h),
          painter: _FormPainter(
            form: form,
            pageIndex: pageIndex,
            images: images,
            theme: Theme.of(context),
            selected: selected,
            labels: labels,
          ),
        ),
        ),
      ),
    );
  }
}

class _FormPainter extends CustomPainter {
  _FormPainter({
    required this.form,
    required this.pageIndex,
    required this.images,
    required this.theme,
    required this.selected,
    this.labels,
  });

  final XfaForm form;
  final int pageIndex;
  final Map<String, ui.Image> images;
  final ThemeData theme;
  final XfaElement? selected;

  /// The view's laid-out texts, kept across paints (audit 2026-10-23
  /// P-8); null lays each out per paint (a painter built on its own).
  final StyledLabelCache? labels;

  /// [text] in [style] laid out for [rect] — one line when the rect is
  /// shorter than 1.6 lines, else as many as fit — from the cache when
  /// the view holds one. The caller disposes it only when [labels] is
  /// null.
  TextPainter _layout(String text, TextStyle style, Rect rect, double size) {
    final maxLines = rect.height < size * 1.6 ? 1 : null;
    // the element's own width (XFA millimetres): the same per element on
    // every paint, so one layout per element
    final maxWidth = rect.width <= 0 ? 1.0 : rect.width;
    final cache = labels;
    if (cache != null) {
      return cache.label(text, style,
          maxLines: maxLines, maxWidth: maxWidth, ellipsis: '…');
    }
    return TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(minWidth: 0, maxWidth: maxWidth);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scheme = theme.colorScheme;
    // subform containers first (background grouping), then the elements
    for (final e in form.elements) {
      if (e is XfaSubform &&
          e.page == pageIndex &&
          e.rect != null &&
          e != form.root) {
        _paintSubform(canvas, e);
      }
    }
    for (final e in form.placed) {
      if (e.page != pageIndex) continue;
      _paintPlaced(canvas, e);
    }
    final sel = selected;
    if (sel != null && sel.rect != null && sel.page == pageIndex) {
      final r = sel.rect!;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = scheme.primary;
      canvas.drawRect(
        Rect.fromLTWH(r.x - 1, r.y - 1, r.w + 2, r.h + 2),
        paint,
      );
    }
  }

  // The page is paper: document colors are FIXED, not themed — the ink is
  // dark and the fills light whatever the app's dark mode does.
  static const Color docInk = Color(0xff202124);
  static const Color docFaint = Color(0xff5f6368);
  static const Color docEdge = Color(0xff9aa0a6);
  static const Color docFillReadOnly = Color(0xffeff0f2);

  void _paintSubform(Canvas canvas, XfaSubform s) {
    final r = s.rect!;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = const Color(0x1a000000); // 10% black grouping box
    canvas.drawRect(Rect.fromLTWH(r.x, r.y, r.w, r.h), paint);
  }

  void _paintPlaced(Canvas canvas, XfaPlaced e) {
    final r = e.widgetRect ?? e.rect!;
    final rect = Rect.fromLTWH(r.x, r.y, r.w, r.h);
    // background
    if (e.fill != null) {
      canvas.drawRect(rect, Paint()..color = _ui(e.fill!));
    }
    // the widget chrome
    switch (e.ui) {
      case 'line':
        final p = Paint()
          ..strokeWidth = e.border.isEmpty ? 0.5 : e.border.first.thickness
          ..color = e.border.isEmpty ? docInk : _edge(e.border.first)
          ..style = PaintingStyle.stroke;
        canvas.drawLine(rect.topLeft, rect.bottomRight, p);
      case 'rect':
        final p = Paint()
          ..strokeWidth = e.border.isEmpty ? 0.5 : e.border.first.thickness
          ..color = e.border.isEmpty ? docInk : _edge(e.border.first)
          ..style = PaintingStyle.stroke;
        canvas.drawRect(rect, p);
      case 'image' when e.image != null:
        final img = images[e.image!.base64];
        if (img != null) {
          canvas.drawImageRect(
            img,
            Rect.fromLTWH(
              0,
              0,
              img.width.toDouble(),
              img.height.toDouble(),
            ),
            rect,
            Paint()..filterQuality = FilterQuality.medium,
          );
        } else {
          canvas.drawRect(
            rect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.5
              ..color = docEdge,
          );
        }
      default:
        // text, textEdit, numericEdit, dateEdit, choiceList, checkButton,
        // button, signature, barcode: a box with the text inside
        final readOnly = e.access == 'readOnly' || e.access == 'protected';
        if (e.kind == XfaKind.field) {
          final isCheck = e.ui == 'checkButton';
          if (!isCheck) {
            canvas.drawRect(
              rect,
              Paint()
                ..color = readOnly
                    ? docFillReadOnly.withValues(alpha: 0.9)
                    : const Color(0xffffffff).withValues(alpha: 0.9),
            );
            _paintEdges(canvas, rect, e,
                fallback: readOnly ? const Color(0xffbdc1c6) : docEdge);
          }
        }
        if (e.ui == 'checkButton') {
          _paintCheck(canvas, rect, e);
        } else {
          _paintText(canvas, rect, e, readOnly: readOnly);
          if (e.ui == 'choiceList') {
            _paintArrow(canvas, rect);
          }
        }
    }
    // the field's caption: its own area beside the widget (left of it by
    // XFA's default), in the caption's own font — never inside the box
    final cr = e.captionRect;
    final cap = e.captionText;
    if (cr != null && cap != null && cap.isNotEmpty) {
      _paintLabel(canvas, Rect.fromLTWH(cr.x, cr.y, cr.w, cr.h), e);
    }
  }

  void _paintLabel(Canvas canvas, Rect rect, XfaPlaced e) {
    final f = e.captionFont ?? e.font;
    final size = (f?.size ?? 10).clamp(4.0, 200.0);
    final style = TextStyle(
      fontFamily: f?.typeface,
      fontFamilyFallback: const ['Helvetica', 'Arial', 'sans-serif'],
      fontSize: size,
      fontWeight: f?.bold == true ? FontWeight.bold : FontWeight.normal,
      fontStyle: f?.italic == true ? FontStyle.italic : FontStyle.normal,
      color: docInk,
    );
    final tp = _layout(e.captionText!, style, rect, size);
    tp.paint(
      canvas,
      Offset(rect.left, rect.top + (rect.height - tp.height) / 2),
    );
    if (labels == null) tp.dispose();
  }

  void _paintEdges(Canvas canvas, Rect rect, XfaPlaced e,
      {required Color fallback}) {
    final n = e.border.length;
    if (n == 0) {
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5
          ..color = fallback,
      );
      return;
    }
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..color = _edge(e.border.first);
    if (n == 1) {
      paint.strokeWidth = e.border.first.thickness;
      canvas.drawRect(rect, paint);
      return;
    }
    // XFA's edge order on a box: top, right, bottom, left
    final edges = [
      e.border[0],
      if (n > 1) e.border[1] else e.border[0],
      if (n > 2) e.border[2] else e.border[0],
      if (n > 3) e.border[3] else e.border[0],
    ];
    final segs = [
      (rect.topLeft, rect.topRight),
      (rect.topRight, rect.bottomRight),
      (rect.bottomRight, rect.bottomLeft),
      (rect.bottomLeft, rect.topLeft),
    ];
    for (var i = 0; i < 4; i++) {
      final ed = edges[i];
      if (ed.presence != 'visible') continue;
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ed.thickness
        ..color = _edge(ed);
      canvas.drawLine(segs[i].$1, segs[i].$2, p);
    }
  }

  void _paintCheck(Canvas canvas, Rect rect, XfaPlaced e) {
    final side = rect.height < 10 ? rect.height : 10.0;
    final box = Rect.fromLTWH(rect.left, rect.topCenter.dy - side / 2, side, side);
    canvas.drawRect(
      box,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.75
        ..color = docInk,
    );
    _paintText(
      canvas,
      Rect.fromLTWH(
        box.right + 4,
        rect.top,
        rect.width - side - 4,
        rect.height,
      ),
      e,
      readOnly: false,
    );
  }

  void _paintArrow(Canvas canvas, Rect rect) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = docFaint;
    final cx = rect.right - 7;
    final cy = rect.topCenter.dy;
    canvas.drawLine(Offset(cx - 2.5, cy - 1), Offset(cx, cy + 1.5), p);
    canvas.drawLine(Offset(cx, cy + 1.5), Offset(cx + 2.5, cy - 1), p);
  }

  void _paintText(Canvas canvas, Rect rect, XfaPlaced e, {required bool readOnly}) {
    final text = e.text;
    final font = e.font;
    final size = (font?.size ?? 10).clamp(4.0, 200.0);
    final style = TextStyle(
      fontFamily: font?.typeface,
      fontFamilyFallback: const ['Helvetica', 'Arial', 'sans-serif'],
      fontSize: size,
      fontWeight: font?.bold == true ? FontWeight.bold : FontWeight.normal,
      fontStyle: font?.italic == true ? FontStyle.italic : FontStyle.normal,
      color: readOnly ? docFaint : docInk,
    );
    if (text.isEmpty) {
      // an empty field still shows its extent: a faint baseline dot row is
      // noise; nothing to draw
      return;
    }
    final tp = _layout(text, style, rect, size);
    tp.paint(
      canvas,
      Offset(rect.left + 1, rect.top + (rect.height - tp.height) / 2),
    );
    if (labels == null) tp.dispose();
  }

  Color _ui(XfaColor c) => Color.fromARGB(255, c.r, c.g, c.b);

  Color _edge(XfaEdge e) => e.color == null
      ? docInk
      : Color.fromARGB(255, e.color!.r, e.color!.g, e.color!.b);

  /// The selection as far as THIS page is concerned: an element on another
  /// page is none of its business, so a tap on page 2 repaints page 2
  /// alone.
  XfaElement? get _ownSelection =>
      selected?.page == pageIndex ? selected : null;

  @override
  bool shouldRepaint(_FormPainter old) =>
      old._ownSelection != _ownSelection ||
      old.pageIndex != pageIndex ||
      old.images.length != images.length ||
      !identical(old.form, form);
}

// ---------------------------------------------------------------------------
// Structure tree and details
// ---------------------------------------------------------------------------

class _StructureTile extends StatelessWidget {
  const _StructureTile({
    required this.element,
    required this.depth,
    required this.selected,
    required this.onSelect,
  });

  final XfaElement element;
  final int depth;
  final XfaElement? selected;
  final ValueChanged<XfaElement> onSelect;

  IconData get _icon {
    return switch (element.kind) {
      XfaKind.pageSet => Icons.layers_outlined,
      XfaKind.pageArea => Icons.crop_portrait,
      XfaKind.subform => Icons.folder_outlined,
      XfaKind.field => Icons.input_outlined,
      XfaKind.draw => Icons.text_fields,
      XfaKind.other => Icons.code,
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final e = element;
    final kids = e.children;
    final isSel = identical(selected, e);
    final label = e.label;
    final detail = switch (e) {
      XfaPlaced() => e.ui,
      XfaSubform() => e.layout.isEmpty ? 'position' : e.layout,
      _ => '',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => onSelect(element),
          child: Container(
            color: isSel ? scheme.primaryContainer : null,
            padding: EdgeInsets.only(
              left: 8.0 + depth * 14,
              top: 3,
              bottom: 3,
              right: 8,
            ),
            child: Row(
              children: [
                Icon(_icon, size: 15, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Flexible(
                  flex: 3,
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: e.name == null ? 'Menlo' : null,
                      color: e.name == null ? scheme.onSurfaceVariant : null,
                    ),
                  ),
                ),
                // the widget kind gives way too (a quarter of the room at
                // most): a deep tree on a phone overflowed the row once the
                // indent and the kind alone outgrew it
                if (detail.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      detail,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
                if (e is XfaPlaced && e.access == 'readOnly') ...[
                  const SizedBox(width: 4),
                  Icon(Icons.lock_outline,
                      size: 11, color: scheme.onSurfaceVariant),
                ],
              ],
            ),
          ),
        ),
        for (final k in kids)
          _StructureTile(
            element: k,
            depth: depth + 1,
            selected: selected,
            onSelect: onSelect,
          ),
      ],
    );
  }
}

/// The selected element's details: identity, geometry, EVERY attribute,
/// its binding and its scripts.
class _DetailsPane extends StatelessWidget {
  const _DetailsPane({required this.element, required this.form, this.full = false});

  final XfaElement element;
  final XfaForm form;
  final bool full;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final el = element;
    final placed = el is XfaPlaced ? el : null;
    final binding = placed == null
        ? null
        : form.bindings
            .where((b) => b.som == placed.som && b.ref != null)
            .firstOrNull;
    final scripts = [
      for (final s in form.scripts)
        if (s.event == element.som) s,
    ];
    final base = TextStyle(fontSize: 12, color: scheme.onSurface);
    final head = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: scheme.onSurfaceVariant,
    );
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 92,
                child: Text(k, style: head),
              ),
              Expanded(
                child: Text(
                  v,
                  style: base.copyWith(fontFamily: _mono(v) ? 'Menlo' : null),
                ),
              ),
            ],
          ),
          // (a value with a slash/dot reads better monospaced)
        );
    return Container(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.4),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Text(
            element.label,
            style: theme.textTheme.titleSmall,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          row('Kind', switch (element.kind) {
            XfaKind.pageSet => 'page set',
            XfaKind.pageArea => 'page area',
            XfaKind.subform => 'subform',
            XfaKind.field => 'field',
            XfaKind.draw => 'draw',
            XfaKind.other => element.tag,
          }),
          if (element.som.isNotEmpty) row('SOM', element.som),
          if (element.rect != null) row('Rect', '${element.rect} pt'),
          if (placed != null) ...[
            row('Widget', placed.ui),
            if (placed.access != null) row('Access', placed.access!),
            if (placed.captionText case final cap?)
              row('Caption', '$cap · ${placed.captionPlace}'),
            if (placed.font case final f?)
              row(
                'Font',
                [
                  if (f.typeface != null) f.typeface!,
                  if (f.size != null) '${f.size!.toStringAsFixed(1)} pt',
                  if (f.bold) 'bold',
                  if (f.italic) 'italic',
                ].join(' · '),
              ),
          ],
          if (binding != null) ...[
            row('Binds', binding.ref!),
            if (binding.match != 'dataRef') row('Match', binding.match),
            if (binding.picture != null) row('Picture', binding.picture!),
          ] else if (placed != null) ...[
            row('Binds', '—'),
          ],
          if (scripts.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Scripts (${scripts.length})',
              style: head,
            ),
            for (final s in scripts.take(full ? scripts.length : 2)) ...[
              const SizedBox(height: 2),
              Text(
                '${s.activity ?? 'script'} · ${s.languageLabel} · runs ${s.runAt}',
                style: base.copyWith(
                  fontFamily: 'Menlo',
                  color: scheme.primary,
                ),
              ),
            ],
          ],
          if (element.attrs.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Attributes (${element.attrs.length})', style: head),
            for (final a in element.attrs.entries) row(a.key, a.value),
          ],
          ],
        ),
      ),
    );
  }

  static final _monoRx = RegExp(r'^[\w.$#/{}\[\] :,-]+$');

  static bool _mono(String v) => v.length > 8 && v.contains(_monoRx);
}

// ---------------------------------------------------------------------------
// Scripts
// ---------------------------------------------------------------------------

class _ScriptCard extends StatelessWidget {
  const _ScriptCard({required this.script});

  final XfaScript script;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  script.event.isEmpty ? '(form)' : script.event,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontFamily: 'Menlo',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (script.activity != null)
                  _chip(context, '@${script.activity}', scheme.secondaryContainer),
                _chip(context, script.languageLabel, scheme.primaryContainer),
                _chip(context, 'runs ${script.runAt}', scheme.tertiaryContainer),
              ],
            ),
            const SizedBox(height: 8),
            SelectionArea(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  script.source,
                  style: TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 12,
                    height: 1.4,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, String text, Color back) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: back,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}
