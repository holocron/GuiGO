import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:office_doc/office_doc.dart';

import 'office_platform.dart';
import 'sap_chart_view.dart';
import 'sap_form_view.dart';
import 'sap_grid_view.dart';

/// A DOI document container (SAP.DocumentContainerControl.1) — the Word /
/// Excel document the server opened in-place — shown read-only:
///
/// * an Excel workbook: the server's .xlsx through the package reader, else
/// the spreadsheet interface's cells (SetRangesData …) — a grid per
/// sheet, a chart sheet as its column chart (a created `Excel.Chart`:
/// Excel's default chart object), sheet tabs when there are several;
/// * a Word document: RTF (SO10 / SmartForms text) or .docx as styled,
/// selectable text;
/// * anything else (a binary .doc / .xls, an Adobe form …): what arrived,
/// and on iOS the system viewer (QuickLook).
///
/// The header offers "Open in viewer" (iOS) and the client-side export
/// ([officeExports]: an .xlsx / .docx, plus the original bytes).
class SapOfficeView extends StatefulWidget {
  const SapOfficeView({
    super.key,
    required this.document,
    this.onActivate,
    this.now,
  });

  final SapOfficeDocument document;

  /// The user's first TAP in the document (once per document) — a
  /// pointer up within [kTouchSlop] of its down; a scroll or a drag is
  /// not one, nor is a tap on the pane's own header: the user entered the
  /// in-place document ([SapSessionOffice.officeDocumentEntered]). Nothing
  /// goes on the wire for it — a click into SAP GUI's in-place Word sends
  /// nothing; the container's OnCloseDocument goes out when the user's
  /// next round leaves the document, as the real GUI's did.
  final VoidCallback? onActivate;

  /// The clock export file names are dated with (tests pin it).
  final DateTime Function()? now;

  @override
  State<SapOfficeView> createState() => _SapOfficeViewState();
}

/// What the pane shows, parsed once per document version.
sealed class _Body {
  const _Body();
}

class _TextBody extends _Body {
  const _TextBody(this.doc);
  final RichDocument doc;
}

class _SheetBody extends _Body {
  const _SheetBody(this.book, {this.note});
  final Workbook book;
  final String? note;
}

class _FormBody extends _Body {
  const _FormBody(this.form);
  final XfaForm form;
}

class _OpaqueBody extends _Body {
  const _OpaqueBody(this.message);
  final String message;
}

class _SapOfficeViewState extends State<SapOfficeView> {
  (int, Uint8List?, Object?)? _parsedKey;
  _Body? _body;
  int _sheet = -1;

  /// The document [SapOfficeView.onActivate] fired for (shell, ProgID).
  (String, String)? _activated;

  /// Where the finger went down in the document, until it comes up or
  /// moves away (a second finger is ignored).
  Offset? _down;

  SapOfficeDocument get _doc => widget.document;

  void _tapped() {
    final id = (_doc.shell, _doc.progId);
    if (_activated == id || widget.onActivate == null) return;
    _activated = id;
    widget.onActivate!();
  }

  /// A pointer up within the touch slop of its down: the tap. Read from
  /// pointer events, not a gesture recognizer: the body already owns the
  /// arena (the text's selection, the sheet's cells), and an outer
  /// recognizer would lose it, as DoubleTapListener's comment says.
  void _onPointerUp(PointerUpEvent e) {
    final down = _down;
    _down = null;
    if (down == null || (e.position - down).distance > kTouchSlop) return;
    _tapped();
  }

  _Body _parse() {
    final d = _doc;
    final key = (d.version, d.bytes, d.sheet);
    final cached = _body;
    if (cached != null &&
        _parsedKey != null &&
        _parsedKey!.$1 == key.$1 &&
        identical(_parsedKey!.$2, key.$2) &&
        identical(_parsedKey!.$3, key.$3)) {
      return cached;
    }
    _parsedKey = key;
    return _body = _bodyOf(d);
  }

  static _Body _bodyOf(SapOfficeDocument d) {
    final bytes = d.bytes;
    // the SFP Designer's form template: the read-only form viewer
    final xdp = _readFormTemplate(d);
    if (xdp != null) return _FormBody(xdp);
    final content = bytes == null || bytes.isEmpty
        ? null
        : readOfficeDocument(bytes);
    switch (content) {
      case OfficeText(:final document) when _blank(document):
        // what the server sent holds no visible text (a SAPscript /
        // SmartForms text COMPOSE_RTF exported with no lines: its one
        // default `* ` paragraph) — said so, not a blank pane that reads
        // as "not loaded"; nothing is made up
        return _OpaqueBody(
          'The document holds no text '
          '(${detectOfficeFormat(bytes!).label}, ${_size(bytes.length)} '
          'as sent)',
        );
      case OfficeText(:final document):
        return _TextBody(document);
      case OfficeSheet(:final workbook):
        return _SheetBody(workbook);
      default:
    }
    final model = d.kind == OfficeDocKind.excel && d.sheet != null
        ? workbookOfDoiDocument(d.sheet!)
        : null;
    final received = switch (content) {
      OfficeOpaque(:final format, :final size, :final error) =>
        '${format.label} received (${_size(size)})'
            '${error == null ? '' : ' — not readable: $error'}',
      _ => null,
    };
    if (model != null &&
        model.sheets.any((s) => s.cells.isNotEmpty || s.isChart)) {
      return _SheetBody(
        model,
        note: received == null
            ? null
            : '$received; shown from the spreadsheet interface\'s cells',
      );
    }
    if (received != null) return _OpaqueBody(received);
    if (model != null) return _SheetBody(model);
    return _OpaqueBody(
      d.kind == OfficeDocKind.other
          ? '${d.progId} document'
          : 'Document not received from the server (yet)',
    );
  }

  /// No visible character in [doc]: every paragraph and table cell blank.
  static bool _blank(RichDocument doc) => doc.plainText.trim().isEmpty;

  static String _size(int n) => n < 1024
      ? '$n B'
      : n < 1024 * 1024
      ? '${(n / 1024).toStringAsFixed(n < 10240 ? 1 : 0)} KB'
      : '${(n / 1024 / 1024).toStringAsFixed(1)} MB';

  /// The document as an XFA form template when it is one — the Designer's
  /// `.xdp` (by extension, or an `<?xml …<xdp:xdp` head). Null when it is
  /// not a form or the template is damaged (the opaque fallback shows).
  static XfaForm? _readFormTemplate(SapOfficeDocument d) {
    final b = d.bytes;
    if (b == null || b.isEmpty) return null;
    var isXdp = d.fileExtension == '.xdp';
    if (!isXdp) {
      final head = String.fromCharCodes(b.length > 512 ? b.sublist(0, 512) : b);
      isXdp = head.contains('<?xml') && head.contains('<xdp:xdp');
    }
    if (!isXdp) return null;
    return tryReadXdp(b);
  }

  String _baseName(_Body body) {
    final title = switch (body) {
      _TextBody(:final doc) => doc.title,
      _SheetBody(:final book) => book.title,
      _ => null,
    };
    if (title != null && title.trim().isNotEmpty) return title;
    final kind = switch (_doc.kind) {
      OfficeDocKind.word => 'word',
      OfficeDocKind.excel => 'excel',
      OfficeDocKind.other => 'document',
    };
    return datedFileName(
      '${_doc.progId.isEmpty ? 'office' : _doc.progId}-$kind',
      (widget.now ?? DateTime.now)(),
    );
  }

  List<OfficeExport> _exports(_Body body) {
    final sheet = switch (body) {
      _SheetBody(:final book) => book,
      _ => _doc.sheet == null ? null : workbookOfDoiDocument(_doc.sheet!),
    };
    final out = officeExports(
      word: _doc.kind == OfficeDocKind.word,
      excel: _doc.kind == OfficeDocKind.excel,
      bytes: _doc.bytes,
      sheet: sheet,
      baseName: _baseName(body),
    );
    final b = _doc.bytes;
    if (out.isEmpty && b != null && b.isNotEmpty) {
      // another document class (the SFP Designer's XDP …): its bytes as sent
      final ext = _doc.fileExtension;
      out.add(
        OfficeExport(
          fileName: '${sanitizeFileName(_baseName(body))}$ext',
          bytes: b,
          mimeType: ext == '.xdp'
              ? 'application/vnd.adobe.xdp+xml'
              : 'application/octet-stream',
          label: 'Original ($ext, as sent)',
          converted: false,
        ),
      );
    }
    return out;
  }

  void _snack(String text) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _export(OfficeExport e) async {
    try {
      final where = await OfficePlatform.export(e);
      if (!mounted || where == null) return;
      if (where != 'shared') _snack('Saved to $where');
    } on PlatformException catch (x) {
      if (mounted) _snack('Export failed: ${x.message ?? x.code}');
    } on UnsupportedError {
      if (mounted) _snack('Export is not available on this device');
    }
  }

  Future<void> _preview() async {
    final b = _doc.bytes;
    if (b == null) return;
    try {
      final format = detectOfficeFormat(b);
      final ext = format == OfficeFileFormat.unknown
          ? _doc.fileExtension
          : format.extension;
      await OfficePlatform.preview(
        b,
        '${sanitizeFileName(_baseName(_parse()))}$ext',
      );
    } on PlatformException catch (x) {
      if (mounted) _snack('Viewer failed: ${x.message ?? x.code}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = _parse();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, body),
        const Divider(height: 1),
        Expanded(
          // the document alone: "Open in viewer" and the export are
          // GuiGo's own chrome, no work in the in-place document
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (e) => _down ??= e.position,
            onPointerCancel: (_) => _down = null,
            onPointerUp: _onPointerUp,
            child: switch (body) {
              _TextBody(:final doc) => SapRichTextView(document: doc),
              _SheetBody(:final book, :final note) => _sheetPane(book, note),
              _FormBody(:final form) => SapFormView(form: form),
              _OpaqueBody(:final message) => _opaque(context, message),
            },
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, _Body body) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final icon = switch (_doc.kind) {
      OfficeDocKind.word => Icons.description_outlined,
      OfficeDocKind.excel => Icons.grid_on_outlined,
      OfficeDocKind.other => Icons.insert_drive_file_outlined,
    };
    final what = switch (_doc.kind) {
      OfficeDocKind.word => 'Word',
      OfficeDocKind.excel => 'Excel',
      OfficeDocKind.other => 'Document',
    };
    final canPreview = OfficePlatform.canPreview && _doc.bytes != null;
    return Container(
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      height: 36,
      // a narrow pane (SMARTFORMS' text node beside its tree) drops the
      // read-only chip and lets the title shrink away: the buttons stay
      child: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            Icon(icon, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '$what · ${_doc.progId}'
                '${_doc.format.isEmpty ? '' : ' (${_doc.format})'}',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge,
              ),
            ),
            if (_doc.readOnly && box.maxWidth >= _chipMinWidth) ...[
              const SizedBox(width: 6),
              Container(
                key: const ValueKey('office-readonly'),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Read-only',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
            const Spacer(),
            if (canPreview)
              IconButton(
                key: const ValueKey('office-preview'),
                tooltip: 'Open in viewer',
                style: _compactButton,
                iconSize: 18,
                icon: const Icon(Icons.open_in_new),
                onPressed: _preview,
              ),
            if (OfficePlatform.canExport) _exportButton(body),
          ],
        ),
      ),
    );
  }

  /// The header's narrowest width that still shows the read-only chip.
  static const double _chipMinWidth = 260;

  /// The header's buttons drawn at 32 points (two of them and the kind
  /// icon fit the narrowest pane); their touch target is the theme's
  /// padded 48-point box, 36 tall in this header — a shrink-wrapped
  /// target left the two actions a phone needs on a document (preview,
  /// export) at 32 points side by side.
  static final ButtonStyle _compactButton = IconButton.styleFrom(
    minimumSize: const Size.square(32),
    fixedSize: const Size.square(32),
    padding: EdgeInsets.zero,
  );

  Widget _exportButton(_Body body) {
    return PopupMenuButton<int>(
      key: const ValueKey('office-export'),
      tooltip: 'Download / Export',
      style: _compactButton,
      icon: const Icon(Icons.download, size: 18),
      itemBuilder: (context) {
        final exports = _exports(body);
        if (exports.isEmpty) {
          return const [
            PopupMenuItem<int>(
              enabled: false,
              child: Text('Nothing to export'),
            ),
          ];
        }
        return [
          for (var i = 0; i < exports.length; i++)
            PopupMenuItem<int>(
              value: i,
              onTap: () => _export(exports[i]),
              child: Text(exports[i].label),
            ),
        ];
      },
    );
  }

  Widget _sheetPane(Workbook book, String? note) {
    final visible = [
      for (var i = 0; i < book.sheets.length; i++)
        if (!book.sheets[i].hidden || book.sheets.length == 1) i,
    ];
    if (visible.isEmpty) return _opaque(context, 'Empty workbook');
    if (!visible.contains(_sheet)) {
      _sheet = visible.contains(book.activeSheet)
          ? book.activeSheet
          : visible.first;
    }
    final sheet = book.sheets[_sheet];
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: Text(
              note,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        Expanded(
          child: switch (sheet.chart) {
            final chart? => SapSheetChart(
              key: ValueKey('office-chart-${sheet.name}'),
              chart: chart,
            ),
            null => SapSheetGrid(
              key: ValueKey('office-sheet-${sheet.name}'),
              sheet: sheet,
            ),
          },
        ),
        if (visible.length > 1)
          Container(
            color: scheme.surfaceContainerHigh,
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final i in visible)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 3,
                    ),
                    child: ChoiceChip(
                      key: ValueKey('office-tab-$i'),
                      avatar: book.sheets[i].isChart
                          ? const Icon(Icons.bar_chart, size: 16)
                          : null,
                      label: Text(book.sheets[i].name),
                      selected: i == _sheet,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _sheet = i),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _opaque(BuildContext context, String message) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              size: 36,
              color: scheme.outline,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            if (OfficePlatform.canPreview && _doc.bytes != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _preview,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open in viewer'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The DOI spreadsheet model (doi.dart's [Document]: the cells the
/// spreadsheet interface's SetRangesData calls wrote, per sheet; a created
/// chart object's chart sheet + data sheet) as a [Workbook]: numbers typed
/// as numbers, empty values dropped, a chart sheet with its chart.
Workbook workbookOfDoiDocument(Document d) {
  final sheets = officeSheetsOf(d);
  final names = [for (final s in sheets) s.name];
  return Workbook(
    [
      for (final s in sheets)
        Worksheet(
          s.name,
          cells: {
            for (final MapEntry(key: at, value: v) in s.cells.entries)
              if (at.$1 > 0 && at.$2 > 0)
                at: switch (v) {
                  final num n => SheetCell(
                    d.cell(at.$1, at.$2, s.name),
                    kind: CellKind.number,
                    number: n,
                  ),
                  _ => SheetCell.guess('$v'),
                },
          },
          chart: switch (s.chart) {
            null => null,
            final c => _sheetChartOf(c),
          },
        ),
    ],
    activeSheet: names.contains(d.activeSheet)
        ? names.indexOf(d.activeSheet)
        : 0,
  );
}

/// A DOI chart as the workbook's [SheetChart]: the resolved series with
/// the cell references they were read from.
SheetChart _sheetChartOf(SapOfficeChart c) {
  String ref(DoiCellRange r) =>
      sheetRangeRef(r.sheet, CellRange(r.top, r.left, r.bottom, r.right));
  return SheetChart(
    type: switch (c.type) {
      DoiChartType.clusteredColumn => SheetChartType.clusteredColumn,
    },
    gapWidth: c.gapWidth,
    overlap: c.overlap,
    series: [
      for (final s in c.series)
        ChartSeries(
          name: s.name,
          categories: s.categories,
          values: s.values,
          nameRef: ref(s.source.name),
          categoriesRef: ref(s.source.categories),
          valuesRef: ref(s.source.values),
        ),
    ],
  );
}

/// A chart sheet read-only: its clustered column chart (a column per
/// series and category, the legend, the value and category axes) in the
/// app's chart view, themed like the rest of the screen.
class SapSheetChart extends StatelessWidget {
  const SapSheetChart({super.key, required this.chart});

  final SheetChart chart;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: SapChartView(
        type: switch (chart.type) {
          SheetChartType.clusteredColumn => 'Columns',
        },
        title: '',
        categories: chart.categories,
        series: [
          for (final s in chart.series)
            ChartSeriesData(s.name, [for (final v in s.values) v?.toDouble()]),
        ],
        gapWidth: chart.gapWidth,
      ),
    );
  }
}

/// One worksheet read-only in GuiGo's grid ([SapGridView]): column letters
/// as headings, Excel's column widths, rows on demand.
class SapSheetGrid extends StatelessWidget {
  const SapSheetGrid({super.key, required this.sheet});

  final Worksheet sheet;

  /// Columns / rows drawn at most (a pushed workbook may be huge).
  static const int maxColumns = 256;
  static const int maxRows = 100000;

  @override
  Widget build(BuildContext context) {
    final cols = sheet.colCount.clamp(1, maxColumns);
    final rows = sheet.rowCount.clamp(1, maxRows);
    List<String> rowAt(int i) => [
      for (var c = 1; c <= cols; c++) sheet.cell(i + 1, c)?.text ?? '',
    ];
    final ids = [for (var c = 1; c <= cols; c++) columnLetters(c)];
    // Excel widths are characters of the default font; 0 = hidden (drawn
    // narrow); unset = measured from the values
    final widths = [
      for (var c = 1; c <= cols; c++)
        switch (sheet.columnWidths[c] ?? sheet.defaultColumnWidth) {
          null => 0,
          final w when w <= 0 => 3,
          final w => w.round(),
        },
    ];
    final sample = [for (var i = 0; i < rows && i < 200; i++) rowAt(i)];
    return SapGridView(
      columns: ids,
      titles: ids,
      widths: widths,
      rows: sample,
      rowCount: rows,
      rowAt: rowAt,
    );
  }
}

/// A [RichDocument] as styled, selectable text: paragraphs with their
/// alignment / indents / spacing / shading, runs with their fonts, sizes
/// and colours (dark-theme aware: automatic and near-black text takes the
/// theme's colour, backgrounds are toned down), tables with a grid.
class SapRichTextView extends StatelessWidget {
  const SapRichTextView({super.key, required this.document});

  final RichDocument document;

  /// Points to logical pixels: a 12 pt SAPscript text reads at 14-15 px.
  static const double ptScale = 1.2;

  @override
  Widget build(BuildContext context) {
    final blocks = document.blocks;
    return SelectionArea(
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: blocks.isEmpty ? 1 : blocks.length,
        itemBuilder: (context, i) {
          if (blocks.isEmpty) return const SizedBox.shrink();
          return switch (blocks[i]) {
            final RichParagraph p => _paragraph(context, p),
            final RichTable t => _table(context, t),
          };
        },
      ),
    );
  }

  static bool _dark(BuildContext c) =>
      Theme.of(c).colorScheme.brightness == Brightness.dark;

  static Color _rgb(int v) => Color(0xff000000 | (v & 0xffffff));

  /// [rgb] as text on this theme's surface: automatic text and colours
  /// too close to the background take the theme's text colour.
  static Color? textColor(BuildContext context, int? rgb) {
    if (rgb == null) return null;
    final c = _rgb(rgb);
    final l = c.computeLuminance();
    final dark = _dark(context);
    if (dark && l < 0.08) return null;
    if (!dark && l > 0.85) return null;
    return c;
  }

  /// A highlight / shading colour behind text: full on a light theme, a
  /// translucent tint on a dark one (so the theme's text stays readable).
  static Color? backColor(BuildContext context, int? rgb) {
    if (rgb == null) return null;
    final c = _rgb(rgb);
    return _dark(context) ? c.withValues(alpha: 0.28) : c;
  }

  static const _mono = {
    'courier new',
    'courier',
    'consolas',
    'lucida console',
    'menlo',
  };

  TextSpan _run(BuildContext context, RichRun r, TextStyle base) {
    final size = (r.fontSize ?? 12) * ptScale;
    final mono = r.font != null && _mono.contains(r.font!.toLowerCase());
    final shifted = r.superscript || r.subscript;
    return TextSpan(
      text: r.text,
      style: base.copyWith(
        fontWeight: r.bold ? FontWeight.bold : null,
        fontStyle: r.italic ? FontStyle.italic : null,
        decoration: TextDecoration.combine([
          if (r.underline) TextDecoration.underline,
          if (r.strike) TextDecoration.lineThrough,
        ]),
        fontSize: shifted ? size * 0.7 : size,
        fontFeatures: [
          if (r.superscript) const FontFeature.superscripts(),
          if (r.subscript) const FontFeature.subscripts(),
        ],
        color: textColor(context, r.color),
        backgroundColor: backColor(context, r.highlight),
        fontFamily: mono ? 'Menlo' : r.font,
        fontFamilyFallback: mono
            ? const ['Courier New', 'Courier', 'monospace']
            : null,
      ),
    );
  }

  Widget _paragraph(BuildContext context, RichParagraph p) {
    final base = DefaultTextStyle.of(context).style.copyWith(height: 1.25);
    final align = switch (p.align) {
      RichAlign.left => TextAlign.left,
      RichAlign.center => TextAlign.center,
      RichAlign.right => TextAlign.right,
      RichAlign.justify => TextAlign.justify,
    };
    final left = (p.leftIndent + (p.firstIndent < 0 ? p.firstIndent : 0))
        .clamp(0, 400)
        .toDouble();
    final first = p.firstIndent > 0 ? p.firstIndent * ptScale : 0.0;
    final size =
        (p.runs.isEmpty ? 12 : (p.runs.first.fontSize ?? 12)) * ptScale;
    return Container(
      color: backColor(context, p.shading),
      padding: EdgeInsets.only(
        left: left * ptScale,
        right: p.rightIndent.clamp(0, 400) * ptScale,
        top: p.spaceBefore.clamp(0, 100).toDouble(),
        bottom: p.spaceAfter.clamp(0, 100).toDouble(),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            if (first > 0) WidgetSpan(child: SizedBox(width: first)),
            if (p.listMarker != null) TextSpan(text: p.listMarker),
            for (final r in p.runs) _run(context, r, base),
            // an empty paragraph keeps its line
            if (p.isEmpty)
              TextSpan(
                text: ' ',
                style: base.copyWith(fontSize: size),
              ),
          ],
        ),
        textAlign: align,
      ),
    );
  }

  Widget _table(BuildContext context, RichTable t) {
    final scheme = Theme.of(context).colorScheme;
    final cols = t.columnCount;
    if (cols == 0) return const SizedBox.shrink();
    final widths = <int, TableColumnWidth>{};
    for (final r in t.rows) {
      if (r.length == cols && r.every((c) => c.width != null && c.span == 1)) {
        for (var i = 0; i < cols; i++) {
          widths[i] = FixedColumnWidth((r[i].width! * ptScale).clamp(24, 900));
        }
        break;
      }
    }
    Widget cell(RichTableCell? c) => Padding(
      padding: const EdgeInsets.all(4),
      child: c == null
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final p in c.paragraphs) _paragraph(context, p)],
            ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          border: TableBorder.all(color: scheme.outlineVariant, width: 0.5),
          defaultColumnWidth: const IntrinsicColumnWidth(),
          columnWidths: widths,
          children: [
            for (final r in t.rows)
              TableRow(
                children: [
                  // a spanning cell takes its first column, the rest blank
                  for (final c in r) ...[
                    cell(c),
                    for (var k = 1; k < c.span; k++) cell(null),
                  ],
                  for (
                    var k = r.fold<int>(0, (n, c) => n + c.span);
                    k < cols;
                    k++
                  )
                    cell(null),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
