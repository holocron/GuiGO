part of 'sap_session.dart';

/// The CFW COMBO BOX (CL_GUI_COMBOBOX: `SAPGUI.SAPComboBoxCtrl.1`, the Java
/// `com.sap.components.controls.combobox.SapComboBox`) and the CFW INPUT
/// FIELD (CL_GUI_INPUT_FIELD: `SAPGUI.SAPInputField.1`, the Java
/// `SapInputField`) — SE80's Repository Browser object-list type and object
/// name above its tree. Real SAP GUI for Windows ground truth:
///
/// * the creation waves, a recorded session srv[10..12] (steps 23 / 25
/// / 27): combo box 149 — CreateControl, `InitControl(0, '', 1)`,
/// `LabelText ''`, `LabelWidth 1` on its handle; its ITEMS a DataProvider
/// `X-R3TABLE` push bound by `AssignProperty2(<dp>, 'r3TableAutoObj',
/// <combo>, 'Items')` (two columns, positional: KEY, TEXT — `_QS` …
/// `P Programme` … `YC Interf. / composant Web Dynpro`); the selection
/// the `CurSel` PUT on the same handle (`CurSel = YC`, the KEY); events
/// RegisterOcxEvent -600 / 2 / 1 / 2 / 3. Input field 153 —
/// CreateControl, `ActivateFindButton`, `ButtonIcon @10@`, `ButtonTooltip
/// 'Afficher ou créer objet'`, `InputPrompt 'Saisir nom de l'objet'`,
/// `InitControl(1, '', 1)`; events 1 / 2 / -600 / 3 / 4; srv[12]
/// `RegisterCachedProp(153, 'Text')`, `SetProperty(153, 290, 1)`, `Text
/// = Y_FIRST_WEBDYNPRO` (the last object) on its handle;
/// * the gestures, a recorded session gui[97] / gui[99] (scrubbed;
/// raw 98 / 100 — SE80 with the combo box on 150, the field on 154):
/// the pick `%_GC 150 -600` `<EVENT SHELLID ="150" EVENTID ="-600">
/// <PARAM PID ="0" VALUE ="P"/></EVENT>` (the item KEY), the submit
/// `%_GC 154 -600` PARAM 0 = the typed name AND, the field having
/// registered `Text`, ` <CONTROLS> <CONTROL SHELLID ="154"> <PROPERTY
/// VALUE ="sapms01gnew" NAME ="Text"/></CONTROL></CONTROLS>`; both in the
/// Windows control-event envelope with the focus on the event shell
/// (16/9/18) and no 16/15/1 (a docked control);
/// * the read-back: the field's registered `Text` is reported in the
/// answer of every queue that sets it (gui[94] step 128, gui[98] step
/// 135, gui[104] step 146 — the value the server put, even when that
/// queue did not register it again).
///
/// The Java bean fires the same -600 (sapInputFieldS.jar
/// SapInputFieldEncEventAdaptor: handleSubmit = -600 — Enter and the find
/// button both submit); this client sends the Windows spelling only.

/// The submit / select event of both controls (SapInputField MID -600; the
/// combo box's pick, a recorded session gui[97]).
const int cfwFieldSubmitEvent = -600;

/// The cached property an input field registers for its value.
const String cfwInputTextProp = 'Text';

final RegExp _comboClassRx = RegExp('combobox', caseSensitive: false);
final RegExp _inputFieldClassRx = RegExp('inputfield', caseSensitive: false);

/// One entry of a combo box's item list.
class SapComboBoxItem {
  const SapComboBoxItem(this.key, this.text);
  final String key;
  final String text;

  @override
  String toString() => '$key=$text';
}

/// A CFW combo box as the server built it.
class SapComboBox {
  const SapComboBox({
    required this.shell,
    required this.items,
    this.selectedKey,
    this.label = '',
    this.enabled = true,
    this.selectRegistered = true,
  });

  final String shell;

  /// The `Items` push, in the server's order.
  final List<SapComboBoxItem> items;

  /// The `CurSel` KEY (the server's last put, or the user's pick).
  final String? selectedKey;

  /// The `LabelText` the server put ('' = none, SE80's).
  final String label;

  final bool enabled;

  /// The server registered the -600 select event (a pick goes out); not
  /// registered, a pick only changes the local selection.
  final bool selectRegistered;

  /// The selected item (null: none, or a key not in [items]).
  SapComboBoxItem? get selected {
    for (final i in items) {
      if (i.key == selectedKey) return i;
    }
    return null;
  }
}

/// A CFW input field (CL_GUI_INPUT_FIELD) as the server built it.
class SapInputFieldControl {
  const SapInputFieldControl({
    required this.shell,
    this.text = '',
    this.prompt = '',
    this.label = '',
    this.findButton = false,
    this.buttonIcon = '',
    this.buttonTooltip = '',
    this.enabled = true,
    this.submitRegistered = true,
    this.cachesText = false,
  });

  final String shell;

  /// The value: the server's `Text` put, else what the user typed.
  final String text;

  /// The `InputPrompt` shown while the field is empty.
  final String prompt;
  final String label;

  /// `ActivateFindButton`: the field shows its button ([buttonIcon] /
  /// [buttonTooltip]); pressing it submits, as Enter does.
  final bool findButton;
  final String buttonIcon;
  final String buttonTooltip;
  final bool enabled;

  /// The server registered -600: a submit goes out.
  final bool submitRegistered;

  /// The field registered its `Text` as a cached property: the submit
  /// flushes it ([SapSessionCfwFields.submitInputField]).
  final bool cachesText;
}

class _Combo {
  _Combo(this.shell);
  final String shell;
  List<SapComboBoxItem> items = const [];
  String? selected;
  String label = '';
  bool enabled = true;
}

class _Input {
  _Input(this.shell);
  final String shell;
  String text = '';
  String prompt = '';
  String label = '';
  bool findButton = false;
  String buttonIcon = '';
  String buttonTooltip = '';
  bool enabled = true;
}

class _CfwFieldState {
  final Map<String, _Combo> combos = {};
  final Map<String, _Input> inputs = {};

  /// object handle -> shell, learned from the verbs that name one family
  /// only (`Items` / `CurSel` a combo box, `Text` / `InputPrompt` … an
  /// input field) — a replayed recording keeps the recording client's
  /// handles, which this session never minted.
  final Map<String, String> handles = {};
}

final Expando<_CfwFieldState> _cfwFieldStates = Expando('cfwFieldState');

const Set<String> _comboOnlyVerbs = {'CurSel'};
const Set<String> _inputOnlyVerbs = {
  'Text',
  'InputPrompt',
  'ActivateFindButton',
  'ButtonIcon',
  'ButtonTooltip',
  'ActivateHistory',
  'ActivateAutoSubmit',
};
const Set<String> _sharedVerbs = {
  'LabelText',
  'LabelWidth',
  'InitControl',
  'Changeable',
  'Enabled',
};

/// The CFW combo box and input field on a [SapSession]: their state
/// ([comboBoxes], [cfwInputFields]), the pick ([pickComboBox]) and the
/// submit ([submitInputField]); the field's `Text` answers the server's
/// read-backs. Windows dialect only.
extension SapSessionCfwFields on SapSession {
  _CfwFieldState get _cfState => _cfwFieldStates[_w] ??= _CfwFieldState();

  bool _isCombo(String sh) =>
      _comboClassRx.hasMatch(_layoutState.registry.classes()[sh] ?? '');
  bool _isInputField(String sh) =>
      _inputFieldClassRx.hasMatch(_layoutState.registry.classes()[sh] ?? '');

  bool _cfwRegistered(String shell) {
    final reg = _canvasState.tracker.registeredEvents[shell];
    // nothing recorded (an offline replay that missed the registration):
    // the event goes out, as the reference client's control_event does
    return reg == null || reg.isEmpty || reg.contains(cfwFieldSubmitEvent);
  }

  /// The combo boxes of the current screen (live, shown), by shell.
  Map<String, SapComboBox> get comboBoxes {
    final st = _cfState;
    final out = <String, SapComboBox>{};
    for (final c in _layoutState.registry.created) {
      final sh = c.shell;
      if (!_comboClassRx.hasMatch(c.cls) || out.containsKey(sh)) continue;
      if (!_onScreen(sh) || !_shellVisible(sh)) continue;
      final m = st.combos[sh];
      out[sh] = SapComboBox(
        shell: sh,
        items: List.unmodifiable(m?.items ?? const <SapComboBoxItem>[]),
        selectedKey: m?.selected,
        label: m?.label ?? '',
        enabled: m?.enabled ?? true,
        selectRegistered: _cfwRegistered(sh),
      );
    }
    return out;
  }

  /// The CFW input fields of the current screen (live, shown), by shell.
  Map<String, SapInputFieldControl> get cfwInputFields {
    final st = _cfState;
    final cached = _layoutState.registry.cachedProps;
    final out = <String, SapInputFieldControl>{};
    for (final c in _layoutState.registry.created) {
      final sh = c.shell;
      if (!_inputFieldClassRx.hasMatch(c.cls) || out.containsKey(sh)) continue;
      if (!_onScreen(sh) || !_shellVisible(sh)) continue;
      final m = st.inputs[sh];
      out[sh] = SapInputFieldControl(
        shell: sh,
        text: m?.text ?? '',
        prompt: m?.prompt ?? '',
        label: m?.label ?? '',
        findButton: m?.findButton ?? false,
        buttonIcon: m?.buttonIcon ?? '',
        buttonTooltip: m?.buttonTooltip ?? '',
        enabled: m?.enabled ?? true,
        submitRegistered: _cfwRegistered(sh),
        cachesText: cached[sh]?.contains(cfwInputTextProp) ?? false,
      );
    }
    return out;
  }

  /// Pick item [key] of combo box [shell] (a unique item TEXT is taken
  /// for its key): the local selection changes, and — the server having
  /// registered it — `%_GC <shell> -600` PARAM 0 = the KEY goes out
  /// (a recorded session gui[97]); the item already selected sends
  /// nothing (the OCX fires no event for it). Refused, nothing sent: no such
  /// combo box on the screen, a key the item list does not hold
  /// ([ArgumentError]). Returns the frames of the server's answer (empty
  /// when nothing was sent).
  Future<List<Uint8List>> pickComboBox(String shell, String key) async {
    _windowsOnly('a combo box pick');
    final sh = shell.trim();
    final box = comboBoxes[sh];
    if (box == null) {
      throw ArgumentError('no combo box $sh on this screen — nothing sent');
    }
    var k = key;
    if (box.items.isNotEmpty && !box.items.any((i) => i.key == k)) {
      final byText = box.items.where((i) => i.text == key).toList();
      if (byText.length != 1) {
        throw ArgumentError(
          'combo box $sh has no item "$key" (${box.items.join(', ')}) — '
          'nothing sent',
        );
      }
      k = byText.single.key;
    }
    // the item already selected: the OCX fires no select event — the real
    // GUI's re-pick of "Programme" sent nothing (a recorded session
    // subnode_dblclick: no frame on combo 149 in the whole session, its
    // CurSel `P` the server's own put, srv[23]); a CHANGED pick does
    // (a recorded session gui[97] `%_GC 150 -600` "P" after "O")
    if (box.selectedKey == k) {
      _trace('combo box $sh: $k is the selection already — nothing sent');
      return const [];
    }
    (_cfState.combos[sh] ??= _Combo(sh)).selected = k;
    if (!box.selectRegistered) {
      _trace('combo box $sh: $k picked locally (-600 not registered)');
      return const [];
    }
    await _flushStagedFirst();
    _trace('combo box $sh pick $k');
    return _act(_cfwFieldEventRound(sh, [k]), dialectReady: true);
  }

  /// The user's typing in input field [shell], kept locally (no round):
  /// what the field answers a read-back with until the next submit.
  void setInputFieldText(String shell, String text) {
    final sh = shell.trim();
    if (!_isInputField(sh)) return;
    (_cfState.inputs[sh] ??= _Input(sh)).text = text;
  }

  /// Submit [text] in input field [shell] (Enter, or its find button):
  /// `%_GC <shell> -600` PARAM 0 = [text] and, when the field registered
  /// it, its cached `Text` = [text] in the same DATAMANAGER
  /// (a recorded session gui[99]). Refused, nothing sent: no such
  /// field on the screen ([ArgumentError]); not registered: the value is
  /// only kept locally. Returns the frames of the server's answer.
  Future<List<Uint8List>> submitInputField(String shell, String text) async {
    _windowsOnly('an input field submit');
    final sh = shell.trim();
    final f = cfwInputFields[sh];
    if (f == null) {
      throw ArgumentError('no input field $sh on this screen — nothing sent');
    }
    (_cfState.inputs[sh] ??= _Input(sh)).text = text;
    if (!f.submitRegistered) {
      _trace('input field $sh: "$text" kept locally (-600 not registered)');
      return const [];
    }
    await _flushStagedFirst();
    _trace('input field $sh submit');
    return _act(
      _cfwFieldEventRound(sh, [
        text,
      ], props: f.cachesText ? [(cfwInputTextProp, text)] : const []),
      dialectReady: true,
    );
  }

  /// The Windows -600 round on [shell]: [cfwEventItems] with the focus on
  /// the event shell (gui[97] / gui[99] `16/9/18`), the 16/15/1 source of
  /// a dynpro-hosted control (none docked), and the OCX DATAMANAGER — the
  /// EVENT, then ONE CONTROLS section in ascending shell order: the first-
  /// visible GENERIC of the other live grids (as every Windows control
  /// event carries it, [_treeEventRound]) and the shell's own [props].
  List<Uint8List> _cfwFieldEventRound(
    String shell,
    List<String> params, {
    List<(String, String)> props = const [],
  }) {
    _ea.recordEvent(shell, {for (final (i, p) in params.indexed) i: p});
    final items = cfwEventItems(
      ctx,
      shell: shell,
      eventId: cfwFieldSubmitEvent,
      params: params,
      sourcePath: _hostedSourcePath(shell),
      focusShell: shell,
    );
    final controls =
        [
          for (final g in _toolbarGenerics(shell))
            if (g.shell != shell) g,
          if (props.isNotEmpty) GridControlState(shell, props: props),
        ]..sort(
          (a, b) => (int.tryParse(a.shell) ?? 0).compareTo(
            int.tryParse(b.shell) ?? 0,
          ),
        );
    if (controls.isEmpty) return items;
    final xml = ocxDataManagerXml(
      eventShell: shell,
      eventId: cfwFieldSubmitEvent,
      eventParams: params,
      controls: controls,
    );
    return [
      for (final raw in items)
        if (_isXmlItem(raw)) xmlBlobItem(wireText(xml)) else raw,
    ];
  }

  /// The shell a combo box / input field verb acts on: the CreateControl
  /// of the same queue ([rowShell]), the handle as a shell or through the
  /// responder's alias, a handle learned earlier; else, for a verb only
  /// one family has, the newest live control of that family (the handle
  /// learned from then on).
  String? _cfwShellOf(VerbMeta m, String verb, Map<String, String> rowShell) {
    bool ours(String? sh) => sh != null && (_isCombo(sh) || _isInputField(sh));
    final st = _cfState;
    final r = rowShell[m.obj.trim()];
    if (ours(r)) return r;
    final h = m.objValue.trim();
    if (h.isEmpty) return null;
    if (ours(h)) return h;
    final a = _ea.shellAlias[h];
    if (ours(a)) return a;
    final learned = st.handles[h];
    if (ours(learned) && _live(learned!)) {
      // a learned handle of the other family: a reused handle, re-learn
      final combo = _isCombo(learned);
      if (!(_comboOnlyVerbs.contains(verb) && !combo) &&
          !(_inputOnlyVerbs.contains(verb) && combo)) {
        return learned;
      }
    }
    final RegExp? family = _comboOnlyVerbs.contains(verb)
        ? _comboClassRx
        : _inputOnlyVerbs.contains(verb)
        ? _inputFieldClassRx
        : null;
    if (family == null) return null;
    for (final c in _layoutState.registry.created.reversed) {
      if (family.hasMatch(c.cls) && _live(c.shell)) {
        st.handles[h] = c.shell;
        return c.shell;
      }
    }
    return null;
  }

  /// Fold one flush call into the combo box / input field models, and
  /// make its answer report the field's registered `Text` with the value
  /// the queue put (gui[94] / gui[98] / gui[104]: the real GUI echoes it,
  /// registered in this queue or before).
  void _foldCfwFieldCall(Uint8List value, FlushCall call) {
    if (call.verbs.isEmpty) return;
    final st = _cfState;
    final meta = verbMeta(call);
    final rowShell = <String, String>{};
    for (var i = 1; i <= call.verbs.length && i <= meta.length; i++) {
      final verb = call.verbs[i - 1];
      if (!verb.startsWith('CreateControl')) continue;
      final a = verbNamedArgs(call, i);
      final sh = (a['#1'] ?? '').trim();
      final cls = a['#2'] ?? '';
      final res = (meta[i - 1].result ?? '').trim();
      if (_comboClassRx.hasMatch(cls)) {
        st.combos[sh] = _Combo(sh); // a re-created control starts afresh
      } else if (_inputFieldClassRx.hasMatch(cls)) {
        st.inputs[sh] = _Input(sh);
      } else {
        continue;
      }
      if (res.isNotEmpty) rowShell[res] = sh;
      st.handles.removeWhere((_, v) => v == sh);
    }
    final setText = <String, String>{};
    for (var i = 1; i <= call.verbs.length && i <= meta.length; i++) {
      final verb = call.verbs[i - 1];
      if (!_comboOnlyVerbs.contains(verb) &&
          !_inputOnlyVerbs.contains(verb) &&
          !_sharedVerbs.contains(verb)) {
        continue;
      }
      final m = meta[i - 1];
      // a getter (`Text(_RESULT=)`): answered by [_cfwFieldPropAnswers]
      if (m.result != null) continue;
      final sh = _cfwShellOf(m, verb, rowShell);
      if (sh == null) continue;
      final args = [
        for (final (n, v) in verbArgs(call, i))
          if (!n.trim().startsWith('_')) v,
      ];
      final v = args.isEmpty ? '' : args.first;
      if (_isCombo(sh)) {
        final c = st.combos[sh] ??= _Combo(sh);
        switch (verb) {
          case 'CurSel':
            c.selected = v;
          case 'LabelText':
            c.label = v;
          case 'Changeable' || 'Enabled':
            c.enabled = _cfwTruthy(v);
        }
      } else {
        final f = st.inputs[sh] ??= _Input(sh);
        switch (verb) {
          case 'Text':
            f.text = v;
            setText[sh] = v;
          case 'InputPrompt':
            f.prompt = v;
          case 'LabelText':
            f.label = v;
          case 'ActivateFindButton':
            f.findButton = true;
          case 'ButtonIcon':
            f.buttonIcon = v;
          case 'ButtonTooltip':
            f.buttonTooltip = v;
          case 'Changeable' || 'Enabled':
            f.enabled = _cfwTruthy(v);
        }
      }
    }
    // the Items pushes (AssignProperty2(<dp>, …, <combo>, 'Items'))
    DpCache? own;
    for (final b in dpPushBindings(call)) {
      if (b.role != 'Items' || b.attach != null) continue;
      final o = (b.shell ?? b.owner ?? '').trim();
      String? sh = _isCombo(o) ? o : null;
      sh ??= _isCombo(_ea.shellAlias[o] ?? '') ? _ea.shellAlias[o] : null;
      sh ??= _isCombo(st.handles[o] ?? '') ? st.handles[o] : null;
      if (sh == null) {
        for (final c in _layoutState.registry.created.reversed) {
          if (_comboClassRx.hasMatch(c.cls) && _live(c.shell)) {
            sh = c.shell;
            break;
          }
        }
        if (sh == null) continue;
        if (o.isNotEmpty) st.handles[o] = sh;
      }
      for (final u in b.urls) {
        final seg =
            _ea.dpCache.byUrl[u] ??
            (own ??= DpCache()..ingestValue(value)).byUrl[u];
        if (seg == null) continue;
        final t = decodeNamedDpTable(seg);
        if (t == null || t.columns.isEmpty) continue;
        final k = t.columns;
        (st.combos[sh] ??= _Combo(sh)).items = [
          for (final r in t.rows)
            SapComboBoxItem(
              (r[k[0]] ?? '').trim(),
              k.length > 1 ? (r[k[1]] ?? '').trim() : (r[k[0]] ?? '').trim(),
            ),
        ];
        _trace('combo box $sh: ${t.rows.length} item(s)');
      }
    }
    // the answer's control state: the field's registered Text, with its
    // value — the server's put of this queue, else the field's own
    final cached = _layoutState.registry.cachedProps;
    for (final (sh, prop) in call.cachedProps) {
      if (prop != cfwInputTextProp || !_isInputField(sh)) continue;
      call.setProps[(sh, prop)] = st.inputs[sh]?.text ?? '';
    }
    setText.forEach((sh, v) {
      if (!(cached[sh]?.contains(cfwInputTextProp) ?? false)) return;
      if (!call.cachedProps.contains((sh, cfwInputTextProp))) {
        call.cachedProps.add((sh, cfwInputTextProp));
      }
      call.setProps[(sh, cfwInputTextProp)] = v;
    });
  }

  /// VARS row -> value of the combo box / input field read-backs a flush
  /// carries (`CurSel(_RESULT=)`, `Text(_RESULT=)` on the control's
  /// handle): the control's client state — the user's pick / typing, else
  /// the server's own put.
  Map<int, Uint8List> _cfwFieldPropAnswers(FlushCall call) {
    final out = <int, Uint8List>{};
    if (call.verbs.isEmpty) return out;
    final st = _cfState;
    if (st.combos.isEmpty && st.inputs.isEmpty) return out;
    final meta = verbMeta(call);
    for (var i = 1; i <= call.verbs.length && i <= meta.length; i++) {
      final verb = call.verbs[i - 1];
      if (verb != 'CurSel' && verb != 'Text') continue;
      final m = meta[i - 1];
      final res = int.tryParse(m.result?.trim() ?? '');
      if (res == null || res < 1) continue;
      if (verbArgs(call, i).any((a) => !a.$1.trim().startsWith('_'))) continue;
      final sh = _cfwShellOf(m, verb, const {});
      if (sh == null) continue;
      final v = verb == 'CurSel'
          ? st.combos[sh]?.selected
          : st.inputs[sh]?.text;
      if (v == null) continue;
      out[res - 1] = wireText(v);
    }
    return out;
  }
}

bool _cfwTruthy(String v) {
  final t = v.trim().toUpperCase();
  return t == '1' || t == 'X' || t == 'TRUE' || t == '-1';
}
