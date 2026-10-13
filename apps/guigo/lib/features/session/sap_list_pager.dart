import 'dart:async';
import 'dart:math' as math;

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
/// screen (the real GUI's VSCROLL round); never while [busy] or while a
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
        _c.jumpTo(_offsetOf(p.first)
            .clamp(0.0, _c.position.maxScrollExtent.isFinite
                ? math.max(_c.position.maxScrollExtent, 0.0)
                : double.infinity));
      }
    }
    if (moved || (old.busy && !widget.busy) || _owed) _scheduleCheck();
  }

  @override
  void dispose() {
    _settle?.cancel();
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
    if (widget.busy || _inFlight) {
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
    requests++;
    ask(target).whenComplete(() {
      _inFlight = false;
      if (mounted) _scheduleCheck();
    });
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    final press = widget.onPress;
    if (press == null || e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k != LogicalKeyboardKey.pageDown && k != LogicalKeyboardKey.pageUp) {
      return KeyEventResult.ignored;
    }
    if (widget.busy) return KeyEventResult.handled;
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
    final body = Scrollbar(
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
          itemCount: p.total,
          itemBuilder: (context, i) {
            final r = p.rowOfLine(i);
            if (r != null) return widget.row(r);
            // a line of the list the server has not sent yet
            return SizedBox(key: ValueKey('sap-list-pending-$i'), height: lh);
          },
        ),
      ),
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
