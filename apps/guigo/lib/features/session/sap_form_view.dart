import 'dart:convert' show base64Decode;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:office_doc/office_doc.dart';

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
  final Map<String, ui.Image> _images = {};

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
          setState(() => _images[img.base64] = frame.image);
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              _StructureTile(
                element: root,
                depth: 0,
                selected: _selected,
                onSelect: (e) => setState(() => _selected = e),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 4,
          child: _selected == null
              ? Center(
                  child: Text(
                    'Select an element',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : _DetailsPane(element: _selected!, form: _form, full: true),
        ),
      ],
    );
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
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerLowest,
      child: SingleChildScrollView(
        child: SelectionArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _form.source,
              style: TextStyle(
                fontFamily: 'Menlo',
                fontSize: 11,
                color: scheme.onSurface,
              ),
            ),
          ),
        ),
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
  });

  final XfaForm form;
  final Map<String, ui.Image> images;
  final XfaElement? selected;
  final ValueChanged<XfaElement> onSelect;

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
      return InteractiveViewer(
        maxScale: 8,
        minScale: 0.2,
        child: SizedBox(
          width: page.w,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (final w in pages) ...[w, const SizedBox(height: 24)],
            ],
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
  });

  final XfaForm form;
  final int pageIndex;
  final Map<String, ui.Image> images;
  final XfaElement? selected;
  final ValueChanged<XfaElement> onSelect;

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
      child: Container(
        width: page.w,
        height: page.h,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
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
  });

  final XfaForm form;
  final int pageIndex;
  final Map<String, ui.Image> images;
  final ThemeData theme;
  final XfaElement? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final scheme = theme.colorScheme;
    // subform containers first (background grouping), then the elements
    for (final e in form.elements) {
      if (e is XfaSubform &&
          e.page == pageIndex &&
          e.rect != null &&
          e != form.root) {
        _paintSubform(canvas, e, scheme);
      }
    }
    for (final e in form.placed) {
      if (e.page != pageIndex) continue;
      _paintPlaced(canvas, e, scheme);
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

  void _paintSubform(Canvas canvas, XfaSubform s, ColorScheme scheme) {
    final r = s.rect!;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = scheme.outlineVariant.withValues(alpha: 0.6);
    canvas.drawRect(Rect.fromLTWH(r.x, r.y, r.w, r.h), paint);
  }

  void _paintPlaced(Canvas canvas, XfaPlaced e, ColorScheme scheme) {
    final r = e.rect!;
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
          ..color = e.border.isEmpty ? _ink(scheme) : _edge(e.border.first, scheme)
          ..style = PaintingStyle.stroke;
        canvas.drawLine(rect.topLeft, rect.bottomRight, p);
      case 'rect':
        final p = Paint()
          ..strokeWidth = e.border.isEmpty ? 0.5 : e.border.first.thickness
          ..color = e.border.isEmpty ? _ink(scheme) : _edge(e.border.first, scheme)
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
              ..color = scheme.outline,
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
                ..color = (readOnly ? scheme.surfaceContainerHigh : scheme.surface)
                    .withValues(alpha: 0.9),
            );
            _paintEdges(canvas, rect, e, scheme,
                fallback: readOnly ? scheme.outlineVariant : scheme.outline);
          }
        }
        if (e.ui == 'checkButton') {
          _paintCheck(canvas, rect, e, scheme);
          return;
        }
        _paintText(canvas, rect, e, scheme, readOnly: readOnly);
        if (e.ui == 'choiceList') {
          _paintArrow(canvas, rect, scheme);
        }
    }
  }

  void _paintEdges(Canvas canvas, Rect rect, XfaPlaced e, ColorScheme scheme,
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
      ..color = _edge(e.border.first, scheme);
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
        ..color = _edge(ed, scheme);
      canvas.drawLine(segs[i].$1, segs[i].$2, p);
    }
  }

  void _paintCheck(Canvas canvas, Rect rect, XfaPlaced e, ColorScheme scheme) {
    final side = rect.height < 10 ? rect.height : 10.0;
    final box = Rect.fromLTWH(rect.left, rect.topCenter.dy - side / 2, side, side);
    canvas.drawRect(
      box,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.75
        ..color = _ink(scheme),
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
      scheme,
      readOnly: false,
    );
  }

  void _paintArrow(Canvas canvas, Rect rect, ColorScheme scheme) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = scheme.onSurfaceVariant;
    final cx = rect.right - 7;
    final cy = rect.topCenter.dy;
    canvas.drawLine(Offset(cx - 2.5, cy - 1), Offset(cx, cy + 1.5), p);
    canvas.drawLine(Offset(cx, cy + 1.5), Offset(cx + 2.5, cy - 1), p);
  }

  void _paintText(Canvas canvas, Rect rect, XfaPlaced e, ColorScheme scheme,
      {required bool readOnly}) {
    final text = e.text;
    final font = e.font;
    final size = (font?.size ?? 10).clamp(4.0, 200.0);
    final style = TextStyle(
      fontFamily: font?.typeface,
      fontFamilyFallback: const ['Helvetica', 'Arial', 'sans-serif'],
      fontSize: size,
      fontWeight: font?.bold == true ? FontWeight.bold : FontWeight.normal,
      fontStyle: font?.italic == true ? FontStyle.italic : FontStyle.normal,
      color: readOnly ? scheme.onSurfaceVariant : _ink(scheme),
    );
    if (text.isEmpty) {
      // an empty field still shows its extent: a faint baseline dot row is
      // noise; nothing to draw
      return;
    }
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: rect.height < size * 1.6 ? 1 : null,
      ellipsis: '…',
    )..layout(minWidth: 0, maxWidth: rect.width <= 0 ? 1 : rect.width);
    tp.paint(
      canvas,
      Offset(rect.left + 1, rect.top + (rect.height - tp.height) / 2),
    );
  }

  Color _ink(ColorScheme scheme) => scheme.brightness == Brightness.dark
      ? const Color(0xffe6e6e6)
      : const Color(0xff1a1a1a);

  Color _ui(XfaColor c) => Color.fromARGB(255, c.r, c.g, c.b);

  Color _edge(XfaEdge e, ColorScheme scheme) => e.color == null
      ? _ink(scheme)
      : Color.fromARGB(255, e.color!.r, e.color!.g, e.color!.b);

  @override
  bool shouldRepaint(_FormPainter old) =>
      old.selected != selected ||
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
      XfaSubform() => e.layout.isEmpty ? 'tb' : e.layout,
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
                if (detail.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    detail,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
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

  static bool _mono(String v) =>
      v.contains(RegExp(r'^[\w.$#/{}\[\] :,-]+$')) && v.length > 8;
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
