import 'dart:async';
import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'session_busy.dart';

/// A classic ABAP list the server pages (package list_scroll.dart): the
/// page heading fixed on top, the body a scroll extent covering the WHOLE
/// list ([ListPage.total] lines) with the received page drawn at its own
/// lines and the rest blank until the server sends it — SAP GUI's list
/// window, whose scroll bar spans the list and asks the server for the page
/// it was dragged to.
///
/// When the scrolling SETTLES ([settle] after the last scroll event — one
/// round per gesture, not one per frame) with lines on screen the page does
/// not hold, [onScroll] asks for the page starting at the top line on
/// screen (the real GUI's VSCROLL round — its scroll-bar drag sends ONE
/// round on release, its wheel one round PER LINE: a recorded session
/// _mainwindow_list_scroll g13 / g15..g53; GuiGo settles both, scrolling
/// locally inside the received page); never while [busy] or while a
/// previous request is in flight — the check runs again once it is done.
/// The server's new page lands in place (the lines keep their positions);
/// a page that moved elsewhere (a paging key) scrolls into view.
///
/// Page Up / Page Down (Ctrl: first / last page) are the list's paging keys
/// ([onPress] with vkey 81 / 82 / 80 / 83), as on the real GUI.
class SapPagedList extends StatefulWidget {
  const SapPagedList({
    super.key,
    required this.page,
    required this.lineHeight,
    required this.row,
    this.identity,
    this.top,
    this.bottom = const [],
    this.busy = false,
    this.onScroll,
    this.onPress,
    this.padding = EdgeInsets.zero,
    this.compact = false,
    this.autofocus = false,
    this.settle = const Duration(milliseconds: 250),
  });

  final ListPage page;
  final double lineHeight;

  /// The widget of painted buffer row [row] (a heading row, a body row).
  final Widget Function(int row) row;

  /// What names the list (a new one starts at its page, scrolled there).
  final Object? identity;

  /// The dynpro body above the list (its fields), if any.
  final Widget? top;

  /// Controls below the list.
  final List<Widget> bottom;
  final bool busy;
  final Future<void> Function(int firstLine)? onScroll;
  final Future<void> Function(int vkey)? onPress;
  final EdgeInsets padding;

  /// A popup's list: the body sized to the page instead of the space left.
  final bool compact;
  final bool autofocus;
  final Duration settle;

  @override
  State<SapPagedList> createState() => SapPagedListState();
}

class SapPagedListState extends State<SapPagedList> {
  late ScrollController _c;
  Timer? _settle;
  bool _inFlight = false;

  /// [_inFlight] for the fetch bar over the list's top edge: a leaf of its
  /// own redraws for it, never the lines.
  final _inFlightN = ValueNotifier<bool>(false);
  bool _owed = false;

  /// The last target asked for and the page's first line when it was: the
  /// server answering with the same page again is not asked twice.
  int? _asked;
  int? _askedFrom;

  /// The scroll requests sent (tests read it).
  @visibleForTesting
  int requests = 0;

  @override
  void initState() {
    super.initState();
    _c = ScrollController(initialScrollOffset: _offsetOf(widget.page.first));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleCheck());
  }

  double _offsetOf(int line) => line * widget.lineHeight;

  /// The session's busy ([SessionBusy]) — listened to, not depended on:
  /// its end runs the owed check without rebuilding the list.
  ValueListenable<bool>? _scope;

  bool get _busy => widget.busy || (_scope?.value ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = SessionBusy.listenableOf(context);
    if (identical(s, _scope)) return;
    _scope?.removeListener(_scopeBusyChanged);
    _scope = s?..addListener(_scopeBusyChanged);
  }

  void _scopeBusyChanged() {
    if (!_busy) _scheduleCheck();
  }

  @override
  void didUpdateWidget(SapPagedList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    final p = widget.page, o = old.page;
    final moved = p.first != o.first || p.total != o.total ||
        widget.identity != old.identity;
    if (moved && _c.hasClients) {
      final top = _topLine();
      final inside = top >= p.first && top < p.first + math.max(1, p.received);
      if (!inside || widget.identity != old.identity || p.total != o.total) {
        // after the layout: a short last page (Page Down past the last
        // full page) grows the extent the jump needs
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_c.hasClients) return;
          final max = _c.position.maxScrollExtent;
          _c.jumpTo(_offsetOf(widget.page.first)
              .clamp(0.0, max.isFinite ? math.max(max, 0.0) : double.infinity));
          _scheduleCheck();
        });
      }
    }
    if (moved || (old.busy && !widget.busy) || _owed) _scheduleCheck();
  }

  @override
  void dispose() {
    _scope?.removeListener(_scopeBusyChanged);
    _settle?.cancel();
    _inFlightN.dispose();
    _c.dispose();
    super.dispose();
  }

  int _topLine() {
    if (!_c.hasClients) return widget.page.first;
    return (_c.position.pixels / widget.lineHeight)
        .floor()
        .clamp(0, math.max(0, widget.page.total - 1));
  }

  void _scheduleCheck() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollUpdateNotification || n is ScrollEndNotification) {
      _settle?.cancel();
      _settle = Timer(widget.settle, _check);
    }
    return false;
  }

  /// The page the screen needs, asked for when the received one does not
  /// cover what is shown.
  void _check() {
    _settle?.cancel();
    _settle = null;
    final ask = widget.onScroll;
    if (!mounted || ask == null || !_c.hasClients) return;
    if (_busy || _inFlight) {
      _owed = true;
      return;
    }
    _owed = false;
    final p = widget.page;
    final pos = _c.position;
    final top = _topLine();
    final shown =
        math.max(1, (pos.viewportDimension / widget.lineHeight).ceil());
    final end = math.min(p.total, top + math.min(shown, p.visible));
    if (top >= p.first && end <= p.first + p.received) return;
    final target = p.clampFirst(top);
    if (target == p.first) return; // the page is already the best one
    if (target == _asked && p.first == _askedFrom) return; // not moved
    _asked = target;
    _askedFrom = p.first;
    _inFlight = true;
    _inFlightN.value = true;
    requests++;
    ask(target).whenComplete(() {
      _inFlight = false;
      if (!mounted) return;
      _inFlightN.value = false;
      _scheduleCheck();
    });
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    final press = widget.onPress;
    if (press == null || e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k != LogicalKeyboardKey.pageDown && k != LogicalKeyboardKey.pageUp) {
      return KeyEventResult.ignored;
    }
    if (_busy) return KeyEventResult.handled;
    final hw = HardwareKeyboard.instance;
    final ctrl = hw.isControlPressed || hw.isMetaPressed;
    final down = k == LogicalKeyboardKey.pageDown;
    press(down
        ? (ctrl ? vkeyLastPage : vkeyPageDown)
        : (ctrl ? vkeyFirstPage : vkeyPageUp));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.page;
    final lh = widget.lineHeight;
    final scheme = Theme.of(context).colorScheme;
    // a line the server has not sent yet: an ellipsis at its start (a
    // blank row read as an empty line of the list)
    final pendingStyle = TextStyle(
      color: scheme.onSurfaceVariant,
      fontSize: math.min(13.0, lh * 0.7),
      height: 1,
    );
    // the extent: the whole list — and past its end when the server's page
    // starts there: Page Down does not stop at the last full page (from
    // 154 of 220 lines, 46 visible, the server answers first 200 with the
    // 20 lines left — a recorded session g55), and that
    // page is shown at the top as on the real GUI
    final body = LayoutBuilder(
      builder: (context, cons) {
        final shown = cons.hasBoundedHeight
            ? (cons.maxHeight / lh).ceil()
            : p.visible;
        final count = math.max(p.total, p.first + shown);
        final list = Scrollbar(
          controller: _c,
          thumbVisibility: true,
          interactive: true,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: ListView.builder(
              key: const ValueKey('sap-paged-list'),
              controller: _c,
              padding: EdgeInsets.zero,
              itemExtent: lh,
              itemCount: count,
              itemBuilder: (context, i) {
                final r = p.rowOfLine(i);
                if (r != null) return widget.row(r);
                // past the list's end: blank, never asked for
                if (i >= p.total) {
                  return SizedBox(key: ValueKey('sap-list-end-$i'), height: lh);
                }
                // a line of the list the server has not sent yet
                return SizedBox(
                  key: ValueKey('sap-list-pending-$i'),
                  height: lh,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text('…', style: pendingStyle),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        // the fetch bar: the page's round is on its way (over the list's
        // top edge — an overlay, so the list keeps its height; static, as
        // the session's own spinner already turns for the round)
        return Stack(
          children: [
            list,
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ValueListenableBuilder<bool>(
                valueListenable: _inFlightN,
                builder: (_, inFlight, _) => inFlight
                    ? SizedBox(
                        height: 2,
                        child: ColoredBox(
                          key: const ValueKey('sap-list-fetching'),
                          color: scheme.primary,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        );
      },
    );
    final header = [for (var r = 0; r < p.headerRows; r++) widget.row(r)];
    final top = widget.top;
    final Widget column;
    if (widget.compact) {
      column = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ?top,
          ...header,
          SizedBox(height: math.min(p.visible, p.total) * lh, child: body),
          ...widget.bottom,
        ],
      );
    } else {
      column = LayoutBuilder(
        builder: (context, cons) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (top != null)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: cons.hasBoundedHeight
                      ? cons.maxHeight * 0.4
                      : double.infinity,
                ),
                child: SingleChildScrollView(child: top),
              ),
            ...header,
            if (cons.hasBoundedHeight)
              Expanded(child: body)
            else
              SizedBox(height: math.min(p.visible, p.total) * lh, child: body),
            ...widget.bottom,
          ],
        ),
      );
    }
    return Focus(
      autofocus: widget.autofocus,
      onKeyEvent: _key,
      child: Padding(padding: widget.padding, child: column),
    );
  }
}
