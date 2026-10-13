import 'dart:async';

import 'package:diag_protocol/diag_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/input_history.dart';

/// SAP GUI's TYPE-AHEAD under an input: the field's earlier values (the
/// local input history, core/input_history.dart) and the SERVER's proposals
/// ("enhanced search": a field the server armed with `typeahead="X"`,
/// [ScreenField.typeAhead] — the `%_SEARCH <text>` round, diag_protocol
/// screen/type_ahead.dart) in one dropdown.
///
/// The real GUI asks the server once per PAUSE, never per keystroke
/// (a recorded session: `z`, `zn`; `1`, `10` — SAPfewui.dll's
/// WM_CHAR → SetTimer → TypeAheadTimer → TypeAheadSendSearchOKCode), and a
/// pick sends nothing: the key is written into the field and rides the
/// next round like typed text. The rules here ([TypeAheadController]):
/// * a server request goes out [TypeAheadConfig.debounce] after the LAST
/// keystroke (each keystroke restarts the timer — [Debouncer]); never
/// while an IME composition is open, never for a programmatic change
/// (only [TypeAheadController.userEdited] starts one), never once the
/// field lost the focus;
/// * at most ONE request in flight per field: a pause while one is out
/// queues the latest text, sent when the answer is in;
/// * every keystroke, close and focus loss bumps a generation counter: an
/// answer for an older generation is dropped — it never overwrites a
/// newer state;
/// * the history list follows each keystroke at once (local);
/// * the dropdown closes on Escape, on focus loss, on submit and on a
/// pick; ↑ / ↓ move in it, Enter or a tap picks.

/// Runs an action [delay] after the LAST [run] call: each call cancels the
/// pending one (the debounce of SAP GUI's type-ahead timer).
class Debouncer {
  Debouncer({this.delay = const Duration(milliseconds: 300)});

  final Duration delay;
  Timer? _timer;

  /// Whether an action is waiting for its delay.
  bool get pending => _timer?.isActive ?? false;

  /// (Re)start the delay for [action]; a pending action is dropped.
  void run(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      action();
    });
  }

  /// Drop the pending action, if any.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => cancel();
}

/// Where a proposal came from.
enum TypeAheadSource { server, history }

/// One row of the dropdown.
class TypeAheadProposal {
  const TypeAheadProposal(
    this.value, {
    this.description = '',
    this.source = TypeAheadSource.history,
    this.marks = const [],
  });

  /// What a pick writes into the field (a server row's key column).
  final String value;

  /// The text beside it (a server row's description column).
  final String description;
  final TypeAheadSource source;

  /// The spans of [value] the server marked as the match.
  final List<(int, int)> marks;

  @override
  String toString() => 'TypeAheadProposal($value, $source)';
}

/// What a field asks for: the input, its screen and the text so far.
class TypeAheadQuery {
  const TypeAheadQuery(this.model, this.field, this.text);
  final ScreenModel model;
  final ScreenField field;
  final String text;
}

/// A provider's answer: the proposals and the "more results" footer the
/// server adds when it cut the list (`SDSH_TYPE_AHEAD_MORE_DIALOG`).
class TypeAheadAnswer {
  const TypeAheadAnswer(this.proposals, {this.more = ''});
  static const TypeAheadAnswer none = TypeAheadAnswer([]);
  final List<TypeAheadProposal> proposals;
  final String more;
}

/// A source of proposals for a field (the server's type-ahead, a test
/// stub): the plug the session's request fits in.
abstract class TypeAheadProvider {
  /// Whether [q] is one this provider answers (an armed field, enough
  /// characters) — asked before the request is debounced.
  bool accepts(TypeAheadQuery q);

  /// The proposals for [q]; a failure is the caller's to swallow.
  Future<TypeAheadAnswer> propose(TypeAheadQuery q);
}

/// The server's type-ahead of an armed dynpro field ([ScreenField.typeAhead])
/// through [request] — `SapSession.fieldTypeAhead(f, text)` once the
/// session offers it (the `%_SEARCH <text>` round). From [minChars] on
/// (one character: `z` and `1` went out on the real GUI).
class ServerTypeAheadProvider implements TypeAheadProvider {
  ServerTypeAheadProvider(this.request, {this.minChars = 1});

  final Future<TypeAheadTable?> Function(ScreenField f, String text) request;
  final int minChars;

  @override
  bool accepts(TypeAheadQuery q) =>
      q.field.typeAhead &&
      q.field.kind == FieldKind.input &&
      !q.field.isProtected &&
      !q.field.invisible &&
      q.text.trim().length >= minChars;

  @override
  Future<TypeAheadAnswer> propose(TypeAheadQuery q) async {
    final t = await request(q.field, q.text);
    if (t == null) return TypeAheadAnswer.none;
    return TypeAheadAnswer([
      for (final r in t.rows)
        if (r.key.isNotEmpty)
          TypeAheadProposal(
            r.key,
            description: r.cells.skip(1).where((c) => c.isNotEmpty).join('  '),
            source: TypeAheadSource.server,
            marks: r.marks.isEmpty ? const [] : r.marks.first,
          ),
    ], more: t.moreRow.isNotEmpty ? t.moreRow : t.message);
  }
}

/// What the dynpro inputs below get: the input history and the server's
/// provider (null: none plugged in), the debounce delay.
class TypeAheadConfig {
  const TypeAheadConfig({
    this.history,
    this.server,
    this.debounce = const Duration(milliseconds: 300),
  });

  final InputHistoryStore? history;
  final TypeAheadProvider? server;
  final Duration debounce;

  TypeAheadConfig copyWith({
    InputHistoryStore? history,
    TypeAheadProvider? server,
    Duration? debounce,
  }) => TypeAheadConfig(
    history: history ?? this.history,
    server: server ?? this.server,
    debounce: debounce ?? this.debounce,
  );
}

/// Provides a [TypeAheadConfig] to the dynpro views below (the app's root
/// gives the input history; a session screen may add its server provider
/// with [TypeAheadConfig.copyWith]). No scope: no type-ahead at all.
class TypeAheadScope extends InheritedWidget {
  const TypeAheadScope({super.key, required this.config, required super.child});

  final TypeAheadConfig config;

  static TypeAheadConfig? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TypeAheadScope>()?.config;

  /// [maybeOf] without a dependency — for event handlers.
  static TypeAheadConfig? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TypeAheadScope>()?.config;

  @override
  bool updateShouldNotify(TypeAheadScope old) =>
      old.config.history != config.history ||
      old.config.server != config.server ||
      old.config.debounce != config.debounce;
}

/// The type-ahead state of ONE focused input (see the library doc for the
/// rules): the dropdown rows, the highlighted row, the debounced and
/// generation-guarded server request.
class TypeAheadController extends ChangeNotifier {
  TypeAheadController(this.config, this.model, this.field)
    : _debounce = Debouncer(delay: config.debounce);

  final TypeAheadConfig config;

  /// The field's screen and the field itself as last painted: a repaint of
  /// the same screen replaces the objects ([rebind]) — a request names the
  /// field the session holds now.
  ScreenModel model;
  ScreenField field;
  final Debouncer _debounce;

  /// The view repainted the same input: ask with the new objects.
  void rebind(ScreenModel m, ScreenField f) {
    model = m;
    field = f;
  }

  String _text = '';
  int _gen = 0;
  bool _inFlight = false;
  bool _queued = false;
  bool _active = true;
  bool _disposed = false;
  bool _shown = false;
  List<TypeAheadProposal> _server = const [];
  List<TypeAheadProposal> _history = const [];
  String _more = '';
  int _highlight = -1;

  /// Requests sent to the server provider (tests read it).
  int requestsSent = 0;

  /// Answers dropped because a newer state had replaced theirs.
  int staleDropped = 0;

  /// The rows shown: the server's proposals, then the history's (a value
  /// both offer once, as the server's).
  List<TypeAheadProposal> get proposals {
    if (!_shown) return const [];
    final seen = {for (final p in _server) p.value};
    return [
      ..._server,
      for (final h in _history)
        if (!seen.contains(h.value)) h,
    ];
  }

  /// The server's "more results" footer of the shown answer.
  String get more => _shown ? _more : '';

  bool get isOpen => proposals.isNotEmpty;

  /// The highlighted row (-1: none).
  int get highlight => _highlight;

  /// Whether a server request is out.
  bool get inFlight => _inFlight;

  /// Whether a server request waits for its debounce delay.
  bool get debouncing => _debounce.pending;

  String get _system => inputHistorySystem(model);

  TypeAheadQuery _query(String text) => TypeAheadQuery(model, field, text);

  /// The user changed the field's text to [value] (a keystroke, a paste —
  /// never a programmatic write): the history list follows at once, the
  /// server request is (re)debounced. An open IME composition asks for
  /// nothing until it is committed.
  void userEdited(TextEditingValue value) {
    if (_disposed || !_active) return;
    _gen++;
    _text = value.text;
    final composing = value.composing.isValid && !value.composing.isCollapsed;
    if (composing) {
      _debounce.cancel();
      return;
    }
    _shown = true;
    _highlight = -1;
    final h = config.history;
    _history =
        h == null ||
            !inputHistoryEligible(
              model,
              field,
              maxFieldLength: h.maxFieldLength,
            )
        ? const []
        : [
            for (final v in h.matches(_system, field.name!, _text))
              TypeAheadProposal(v),
          ];
    final server = config.server;
    if (server != null && server.accepts(_query(_text))) {
      _debounce.run(_fire);
    } else {
      _debounce.cancel();
      _server = const [];
      _more = '';
    }
    notifyListeners();
  }

  void _fire() {
    if (_disposed || !_active) return;
    if (_inFlight) {
      _queued = true; // one request per field: the latest text goes next
      return;
    }
    _send();
  }

  Future<void> _send() async {
    final server = config.server;
    if (server == null) return;
    final gen = _gen;
    _inFlight = true;
    requestsSent++;
    TypeAheadAnswer? answer;
    try {
      answer = await server.propose(_query(_text));
    } on Object {
      answer = null; // a failed request shows nothing new
    } finally {
      _inFlight = false;
    }
    if (_disposed) return;
    if (gen != _gen || !_active) {
      staleDropped++;
    } else if (answer != null) {
      _server = answer.proposals;
      _more = answer.more;
      _shown = true;
      _highlight = -1;
      notifyListeners();
    }
    // a pause came while this one was out: the LATEST text goes now (its
    // keystroke made this answer stale)
    if (_queued) {
      _queued = false;
      if (_active && server.accepts(_query(_text))) unawaited(_send());
    }
  }

  /// Close the dropdown (Escape, submit, a pick): the pending request is
  /// dropped, an answer in flight is stale. Typing again re-opens it.
  void close() {
    if (_disposed) return;
    _gen++;
    _debounce.cancel();
    _queued = false;
    final was = isOpen || more.isNotEmpty;
    _shown = false;
    _highlight = -1;
    _server = const [];
    _history = const [];
    _more = '';
    if (was) notifyListeners();
  }

  /// The field lost the focus: closed for good (no request after it).
  void focusLost() {
    close();
    _active = false;
  }

  /// Move the highlight by [delta] rows (wrapping).
  void moveHighlight(int delta) {
    final n = proposals.length;
    if (n == 0) return;
    _highlight = _highlight < 0
        ? (delta > 0 ? 0 : n - 1)
        : (_highlight + delta) % n;
    if (_highlight < 0) _highlight += n;
    notifyListeners();
  }

  /// The highlighted proposal, null when none is.
  TypeAheadProposal? get highlighted {
    final p = proposals;
    return _highlight >= 0 && _highlight < p.length ? p[_highlight] : null;
  }

  /// Keep the value the user took over (Enter, leaving the field) in the
  /// input history of the field — when the field may keep one.
  void recordHistory(String value) {
    final h = config.history;
    if (h == null) return;
    if (!inputHistoryEligible(model, field, maxFieldLength: h.maxFieldLength)) {
      return;
    }
    unawaited(h.record(_system, field.name!, value));
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    _debounce.dispose();
    super.dispose();
  }
}

/// The dropdown of [controller] under [child] (the input), drawn in the
/// overlay; [onPick] writes a picked value into the field. ↑ / ↓ / Enter /
/// Escape are read by [handleKey] (the input's Focus calls it). A null
/// [controller] (the input has no focus) shows nothing — the anchor stays
/// in the tree either way, so the input's element (and its focus) never
/// moves when the focus arrives.
class TypeAheadAnchor extends StatefulWidget {
  const TypeAheadAnchor({
    super.key,
    required this.controller,
    required this.onPick,
    required this.child,
  });

  final TypeAheadController? controller;
  final void Function(TypeAheadProposal p) onPick;
  final Widget child;

  /// The key handling of an input with an open dropdown: ↑ / ↓ move the
  /// highlight, Enter picks the highlighted row, Escape closes. Anything
  /// else (and these with the dropdown closed) is left to the field.
  static KeyEventResult handleKey(
    TypeAheadController? c,
    KeyEvent e,
    void Function(TypeAheadProposal p) onPick,
  ) {
    if (c == null || e is KeyUpEvent || !c.isOpen) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      c.moveHighlight(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      c.moveHighlight(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      c.close();
      return KeyEventResult.handled;
    }
    if ((k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.numpadEnter) &&
        c.highlighted != null) {
      onPick(c.highlighted!);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  State<TypeAheadAnchor> createState() => _TypeAheadAnchorState();
}

class _TypeAheadAnchorState extends State<TypeAheadAnchor> {
  final LayerLink _link = LayerLink();
  final OverlayPortalController _portal = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_changed);
  }

  @override
  void didUpdateWidget(TypeAheadAnchor old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller?.removeListener(_changed);
      widget.controller?.addListener(_changed);
      // never show / hide the portal during this build: after it
      WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final c = widget.controller;
    final open = c != null && (c.isOpen || c.more.isNotEmpty);
    if (open && !_portal.isShowing) {
      _portal.show();
    } else if (!open && _portal.isShowing) {
      _portal.hide();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) => _dropdown(context),
        child: widget.child,
      ),
    );
  }

  Widget _dropdown(BuildContext context) {
    final c = widget.controller;
    if (c == null) return const SizedBox.shrink();
    final rows = c.proposals;
    final box = this.context.findRenderObject() as RenderBox?;
    final width = (box?.hasSize ?? false) ? box!.size.width : 200.0;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Positioned(
      left: 0,
      top: 0,
      child: CompositedTransformFollower(
        link: _link,
        targetAnchor: Alignment.bottomLeft,
        showWhenUnlinked: false,
        // a tap in the list is a tap "inside" the field: it keeps the focus
        child: TextFieldTapRegion(
          child: Material(
            key: const ValueKey('typeAheadDropdown'),
            elevation: 6,
            borderRadius: BorderRadius.circular(4),
            color: scheme.surfaceContainerHigh,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: width.clamp(160.0, 480.0),
                maxWidth: (width * 2).clamp(240.0, 520.0),
                maxHeight: 280,
              ),
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                shrinkWrap: true,
                children: [
                  for (var i = 0; i < rows.length; i++)
                    _row(rows[i], i == c.highlight, scheme, text),
                  if (c.more.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
                      child: Text(
                        c.more,
                        style: text.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(
    TypeAheadProposal p,
    bool highlighted,
    ColorScheme scheme,
    TextTheme text,
  ) {
    final base = text.bodyMedium?.copyWith(fontFamily: 'Menlo');
    final spans = <TextSpan>[];
    var at = 0;
    for (final (s, e) in p.marks) {
      if (s < at || e > p.value.length || s >= e) continue;
      if (s > at) spans.add(TextSpan(text: p.value.substring(at, s)));
      spans.add(
        TextSpan(
          text: p.value.substring(s, e),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      );
      at = e;
    }
    if (at < p.value.length) spans.add(TextSpan(text: p.value.substring(at)));
    return InkWell(
      key: ValueKey('typeAhead:${p.source.name}:${p.value}'),
      onTap: () => widget.onPick(p),
      child: Container(
        color: highlighted ? scheme.primaryContainer : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Icon(
              p.source == TypeAheadSource.history
                  ? Icons.history
                  : Icons.manage_search,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text.rich(TextSpan(children: spans, style: base)),
            if (p.description.isNotEmpty) ...[
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  p.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The name the COMMAND FIELD's type-ahead and input history go by (the
/// field is the toolbar's okcode combobox, `wnd[0]/tbar[0]/okcd`, no
/// dynpro field).
const String commandFieldName = '%OKCODE';

/// The command field as a [ScreenField] for [TypeAheadInput].
ScreenField commandFieldOf() =>
    ScreenField(kind: FieldKind.input, row: 0, col: 0, name: commandFieldName);

/// The server's command-field type-ahead ("enhanced search for the command
/// field") through [request] — `SapSession.commandFieldTypeAhead(text)`
/// (`%_SEARCH_OKCODE <text>`, from two characters on, never for a `.` or
/// `/` command). A picked row is `<SDSH_TYPE_OKCODE_PREFIX><key>` (`/nME23N`).
class CommandFieldTypeAheadProvider implements TypeAheadProvider {
  CommandFieldTypeAheadProvider(this.request);

  final Future<TypeAheadTable?> Function(String text) request;

  @override
  bool accepts(TypeAheadQuery q) =>
      q.field.name == commandFieldName && commandFieldTypeAheadAllowed(q.text);

  @override
  Future<TypeAheadAnswer> propose(TypeAheadQuery q) async {
    final t = await request(q.text);
    if (t == null) return TypeAheadAnswer.none;
    return TypeAheadAnswer([
      for (final r in t.rows)
        if (r.key.isNotEmpty)
          TypeAheadProposal(
            '${t.okcodePrefix}${r.key}',
            description: r.text,
            source: TypeAheadSource.server,
            marks: [
              for (final (s, e)
                  in r.marks.isEmpty ? const <(int, int)>[] : r.marks.first)
                (s + t.okcodePrefix.length, e + t.okcodePrefix.length),
            ],
          ),
    ], more: t.moreRow.isNotEmpty ? t.moreRow : t.message);
  }
}

/// A free-standing input (the command field) with the type-ahead
/// dropdown: [builder] builds the TextField over [controller] and must
/// route its `onChanged` / `onSubmitted` through the callbacks it gets (so
/// only USER edits ask). [config] null: the plain field. A pick writes the
/// value into [controller] and calls [onPicked].
class TypeAheadInput extends StatefulWidget {
  const TypeAheadInput({
    super.key,
    required this.config,
    required this.model,
    required this.field,
    required this.controller,
    required this.builder,
    this.onPicked,
  });

  final TypeAheadConfig? config;
  final ScreenModel model;
  final ScreenField field;
  final TextEditingController controller;
  final Widget Function(
    BuildContext context,
    ValueChanged<String> onChanged,
    ValueChanged<String> onSubmitted,
  )
  builder;
  final ValueChanged<String>? onPicked;

  @override
  State<TypeAheadInput> createState() => _TypeAheadInputState();
}

class _TypeAheadInputState extends State<TypeAheadInput> {
  TypeAheadController? _ta;
  bool _typed = false;

  @override
  void dispose() {
    _ta?.dispose();
    super.dispose();
  }

  void _focus(bool has) {
    final cfg = widget.config;
    if (has) {
      if (cfg == null || _ta != null) return;
      setState(
        () => _ta = TypeAheadController(cfg, widget.model, widget.field),
      );
      return;
    }
    final ta = _ta;
    if (ta == null) return;
    if (_typed) ta.recordHistory(widget.controller.text);
    _typed = false;
    ta.focusLost();
    setState(() => _ta = null);
    WidgetsBinding.instance.addPostFrameCallback((_) => ta.dispose());
  }

  void _changed(String _) {
    _typed = true;
    _ta?.userEdited(widget.controller.value);
  }

  void _submitted(String v) {
    final ta = _ta;
    if (ta == null) return;
    ta.close();
    if (_typed && v.trim().isNotEmpty) ta.recordHistory(v);
    _typed = false;
  }

  void _pick(TypeAheadProposal p) {
    widget.controller.value = TextEditingValue(
      text: p.value,
      selection: TextSelection.collapsed(offset: p.value.length),
    );
    _typed = true;
    _ta?.close();
    widget.onPicked?.call(p.value);
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.builder(context, _changed, _submitted);
    if (widget.config == null) return field;
    _ta?.rebind(widget.model, widget.field);
    return Focus(
      onKeyEvent: (_, e) => TypeAheadAnchor.handleKey(_ta, e, _pick),
      onFocusChange: _focus,
      child: TypeAheadAnchor(controller: _ta, onPick: _pick, child: field),
    );
  }
}
