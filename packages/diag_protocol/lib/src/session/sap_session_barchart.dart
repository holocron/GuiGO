part of 'sap_session.dart';

/// The SAPbarc.OCX bar chart (`SAPGUI.BarchartGraphics.1`, GRAL BARCOCX1)
/// on a session — the real SAP GUI for Windows' conversation
/// (a recorded session, kept indices):
/// * s[12] `CreateControl(117, SAPGUI.BarchartGraphics.1, …, 10)`, s[13]
/// `LinkControl(117, BARCOCX1, 300)` + the five X-R3TABLE value tables
/// + the sapbarc-stream under `OpenBracket(0, 0)` — folded by
/// [SapBarChartTracker], bound to BARCOCX1/0300 at once;
/// * scrolling and zooming inside the chart are wire-silent;
/// * a toolbar code reaches the control as `LoadCUACode(<code>)` (the
/// responder's per-code VT_I2 answer, [barChartCuaCodeAnswer]: SALL /
/// UALL / OZIN / OZOU applied locally, `1`); a refused one is then read
/// back — s[19] / s[20] → g[17] `CACTBAR\nCXBO5`, Supprimer the marked
/// bar's `CADEL` (…_interactions g[24]) — [SapBarChartTracker];
/// * a click on a bar is local (no frame); a drag is the OCX's event 1
/// plus an `AMOVENODE` read-back (…_interactions g[32] / g[34]) — not
/// sent by GuiGo: its header and date arithmetic are not decoded;
/// * a delta push (`OpenBracket(1, 0)`, s[16] / s[24]) updates the status
/// line / the title.
extension SapSessionBarCharts on SapSession {
  /// The bar charts of the screen on display: the BarchartGraphics
  /// controls bound to the current dynpro (to the base screen under a
  /// popup), then an inline-carried one (the non-OCX GRAPH item `T$CHARTS`
  /// stream — unrecorded on this landscape, parsed by the same grammar).
  List<SapBarChartModel> get barCharts {
    final s = screen;
    final out = <SapBarChartModel>[
      ..._barCharts.pushedOn(s, baseScreen, {
        ..._ea.destroyedControls,
        ..._layoutState.imodes.hiddenShells,
      }),
    ];
    final inline = s?.inlineGraph;
    if (inline != null && inline.complete) {
      final bytes = inline.bytes;
      if (inline.interface == 'BARC' || isInlineBarChart(bytes)) {
        final m = parseBarChartInline(bytes, codepage: inline.codepage);
        if (m != null) out.add(m);
      }
    }
    return out;
  }

  /// Mark [node] of [chart] (a tap on its bar) — local only: the real GUI
  /// sends nothing for the click (a recorded session
  /// §3); the mark rides the next read-back (Supprimer's `CADEL`). Null
  /// [node] clears the marks; [add] toggles it in a multi-selection.
  void selectBarChartNode(SapBarChartModel chart, BarChartNode? node,
      {bool add = false}) {
    final shell = chart.shell;
    if (shell == null) return;
    _barCharts.selectNode(shell, node?.chart, node?.id, add: add);
  }

  SapBarChartTracker get _barCharts => _w.barCharts;

  void _ingestBarChartCall(Uint8List value, [FlushCall? parsed]) {
    try {
      _barCharts.foldCall(value,
          shellOf: (owner) => _ea.shellAlias[owner],
          isLive: (shell) => !_ea.destroyedControls.contains(shell),
          parsed: parsed);
      // a read-back sink of a bar chart is not a NetPlan graph's (that
      // tracker records every DATASTREAM sink it cannot resolve)
      for (final url in _barCharts.lastSinks) {
        _netPlans.dropSink(url);
      }
    } catch (e) {
      _noteIngestFailure('barchart ingest', e);
    }
  }

  void _foldBarCharts(List<Uint8List> frames) {
    if (_barCharts.hasUnbound && _paintsProgram(frames)) {
      _barCharts.bindUnbound(screen);
    }
  }
}
