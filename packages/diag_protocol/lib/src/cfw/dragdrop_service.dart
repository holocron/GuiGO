/// The CFW drag & drop service poll — answering the server's read-back of
/// a drop the client fired (`%_GS <target> 15`), as the real SAP GUI for
/// Windows does (the reference client's ea_dragdrop port, drop-object half).
///
/// Wire (a recorded session srv[10]/[11] -> gui[9]/[10], drop 2
/// srv[18]/[19] -> gui[15]/[16]; the same contract as
/// a recorded session and a recorded session):
/// * poll A, one OLE queue: `GetGuiServices`, `GetServiceByName(
/// 'SAPGUIService.DragDrop.1')`, `DropEvtParam` (object), `FlavorCount`
/// / `ShellIDSrc` / `ShellIDTarget` (VT 20), `Effect` (VT 19),
/// `GetSrcProp` / `GetTargetProp` (objects), `Count` (VT 3) on each
/// property object — the real GUI answered 1, 116, 123, 2, 4, 3;
/// * poll B, the next queue: `Flavor(i)` on the drop object,
/// `PropName(i)` / `PropValue(i)` (VT 8) on the property objects, which
/// it names by the HANDLES the client minted for them in poll A
/// (`obj=1(22)`, `obj=4(23)`, `obj=28(24)`).
/// So the answer needs the pending drop (armed by the session right before
/// the event) and the poll-A mint of each role's handle ([noteDragDropMints]
/// after the responder minted them). Both hook into [buildAnswer]; nothing
/// here branches on a transaction.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'ea_responder.dart';
import 'flush_call.dart';

/// The drop the session is about to fire, and what the poll read of it.
class PendingDrop {
  PendingDrop({
    required this.sourceShell,
    required this.targetShell,
    required this.flavors,
    required this.sourceProps,
    required this.targetProps,
    required this.effect,
  });

  final String sourceShell;
  final String targetShell;
  final List<String> flavors;

  /// The SOURCE property bag (name, value), in the order PropName(i) reads.
  final List<(String, String)> sourceProps;

  /// The TARGET property bag.
  final List<(String, String)> targetProps;

  /// The drop effect the drop object answers (2 on a BWAdapter canvas —
  /// both recorded canvas drops; 1 on the tree / editor / picture drops of
  /// the DWDM and ME21N oracles).
  final int effect;

  /// handle -> role ('drop' / 'src' / 'target') of the objects minted in
  /// poll A
  final Map<String, String> objects = {};

  /// (verb, role, value, index) — every value the poll read, in order
  final List<(String, String, String, int?)> answered = [];

  /// Poll-B objects whose handle no mint of this session names (only a
  /// replayed recording, whose queue carries the recording client's
  /// handles): first unknown property object = the source bag, second = the
  /// target bag — the order the server minted them (GetSrcProp before
  /// GetTargetProp). A live session always resolves by handle.
  final List<String> _unknownBags = [];

  @override
  String toString() =>
      'PendingDrop($sourceShell -> $targetShell, flavors $flavors, '
      'read ${answered.length})';
}

const String ddRoleDrop = 'drop', ddRoleSource = 'src', ddRoleTarget = 'target';
const Map<String, String> _roleByMintVerb = {
  'DropEvtParam': ddRoleDrop,
  'GetSrcProp': ddRoleSource,
  'GetTargetProp': ddRoleTarget,
};

final Expando<PendingDrop> _pending = Expando('pendingDrop');

/// Arm [drop] on [session]: the next drag & drop poll is answered from it.
void armDrop(EaSession session, PendingDrop drop) => _pending[session] = drop;

/// Drop the pending state; returns it (with what the poll read).
PendingDrop? disarmDrop(EaSession session) {
  final p = _pending[session];
  _pending[session] = null;
  return p;
}

PendingDrop? pendingDropOf(EaSession session) => _pending[session];

/// {VARS row index (0-based): value} answering the drag & drop service
/// verbs of [call] from the pending drop; {} when none is pending or the
/// queue reads no drop object. Merged into the responder's prop store.
Map<int, Uint8List> dragDropAnswers(EaSession session, FlushCall call) {
  final pend = _pending[session];
  if (pend == null || call.verbs.isEmpty) return const {};
  final out = <int, Uint8List>{};
  final meta = verbMeta(call);
  // objects minted IN this queue, by their result VARS row
  final inQueue = <String, String>{};
  for (var i = 0; i < call.verbs.length; i++) {
    final role = _roleByMintVerb[call.verbs[i]];
    final res = meta[i].result?.trim() ?? '';
    if (role != null && res.isNotEmpty) inQueue[res] = role;
  }
  for (var i = 1; i <= call.verbs.length; i++) {
    final verb = call.verbs[i - 1];
    final m = meta[i - 1];
    final handle = m.objValue.trim();
    var role = inQueue[m.obj.trim()] ?? pend.objects[handle];
    if (role == null &&
        handle.isNotEmpty &&
        !inQueue.containsKey(m.obj.trim())) {
      if (verb == 'Flavor') {
        role = ddRoleDrop;
      } else if (verb == 'PropName' || verb == 'PropValue') {
        if (!pend._unknownBags.contains(handle)) pend._unknownBags.add(handle);
        final k = pend._unknownBags.indexOf(handle);
        role = k == 0 ? ddRoleSource : (k == 1 ? ddRoleTarget : null);
      }
    }
    if (role == null) continue;
    String? val;
    int? k;
    if (role == ddRoleDrop) {
      switch (verb) {
        case 'FlavorCount':
          val = '${pend.flavors.length}';
        case 'ShellIDSrc':
          val = pend.sourceShell;
        case 'ShellIDTarget':
          val = pend.targetShell;
        case 'Effect':
          val = '${pend.effect}';
        case 'Flavor':
          k = _indexArg(call, i);
          val = k != null && k >= 0 && k < pend.flavors.length
              ? pend.flavors[k]
              : '';
      }
    } else {
      final props = role == ddRoleSource ? pend.sourceProps : pend.targetProps;
      switch (verb) {
        case 'Count':
          val = '${props.length}';
        case 'PropName':
        case 'PropValue':
          k = _indexArg(call, i);
          final pair = k != null && k >= 0 && k < props.length
              ? props[k]
              : ('', '');
          val = verb == 'PropName' ? pair.$1 : pair.$2;
      }
    }
    if (val == null) continue;
    final res = int.tryParse(m.result?.trim() ?? '');
    if (res == null || res < 1) continue;
    out[res - 1] = Uint8List.fromList(utf8.encode(val));
    pend.answered.add((verb, role, val, k));
  }
  return out;
}

/// After the responder minted the queue's objects: bind the handles minted
/// for DropEvtParam / GetSrcProp / GetTargetProp to their roles, so poll B's
/// Flavor / PropName / PropValue on those handles resolve.
void noteDragDropMints(EaSession session, FlushCall call) {
  final pend = _pending[session];
  if (pend == null) return;
  for (final (verb, handle, _) in call.mintTrace) {
    final role = _roleByMintVerb[verb];
    if (role != null) pend.objects['$handle'] = role;
  }
}

int? _indexArg(FlushCall call, int i) {
  for (final (name, v) in verbArgs(call, i)) {
    if (name.trim() == '#1') return int.tryParse(v.trim());
  }
  return null;
}

/// The SOURCE property bag of a tree drag (the reference client's source_props):
/// a single-select tree `KEY, NOITEM`; a multi-select tree `NOITEM,
/// MULTISEL, COUNT, KEY1..KEYn` (a recorded session gui[10]:
/// `NOITEM X, MULTISEL X, COUNT 1, KEY1 ' 2'`). Keys are the
/// tree's own NODE_KEY strings, verbatim.
List<(String, String)> treeSourceProps(
  List<String> keys, {
  required bool multi,
}) {
  if (!multi) {
    return [('KEY', keys.isEmpty ? '' : keys.first), ('NOITEM', 'X')];
  }
  return [
    ('NOITEM', 'X'),
    ('MULTISEL', 'X'),
    ('COUNT', '${keys.length}'),
    for (var i = 0; i < keys.length; i++) ('KEY${i + 1}', keys[i]),
  ];
}

/// The TARGET property bag of a drop on a BWAdapter canvas: the canvas
/// object under the pointer and the drop pixel in the control
/// (a recorded session gui[10] `OBJID 15, XPOS 683, YPOS 677`,
/// gui[16] `39 / 103 / 256`).
List<(String, String)> canvasTargetProps(String objId, int x, int y) => [
  ('OBJID', objId),
  ('XPOS', '$x'),
  ('YPOS', '$y'),
];

/// The drop Effect a BWAdapter canvas target answers (both recorded
/// plain-mouse canvas drops: 2).
const int canvasDropEffect = 2;
