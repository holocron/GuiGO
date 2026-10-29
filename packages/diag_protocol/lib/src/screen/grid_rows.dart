/// OO-ALV grid rows ON DEMAND — the read side of a DATAREQUEST reply.
///
/// An on-demand grid (`SAPGUI.GridViewCtrl.1` over `SAP.DataPOnDemand.1`
/// providers) is pushed with its first OptPacket of cells only
/// (/IWFND/MAINT_SERVICE: 1446 rows, ~81 pushed). The real GUI asks for the
/// rest as the user scrolls (session/grid_rows_request.dart builds that
/// frame); the server answers with an OLE queue that names its target by
/// the provider's OBJECT HANDLE — the handle the client minted for the
/// provider's `CreateObject(SAP.DataPOnDemand.1)` _RESULT in the creation
/// queue — not by shell:
///
/// ```text
/// CreateObject {799104C5-…} a plain DataProvider
/// SetDataFromUrl APPLICATION X-R3TABLE SAPR3://… the cells
/// InsertPacket obj=<provider handle> #1=<FIRSTLINE>
/// ```
///
/// Oracle: a recorded session (real SAP GUI for Windows, AL11 file grid
/// shell 140): creation srv[96] declares DataTableOnDemand `Handle =17`
/// on CreateObject _RESULT VARS row 172; the GUI's answer gui[72] mints
/// 47 for that row; its DATAREQUEST gui[74] (`HANDLE ="17" NLINES ="929"
/// FIRSTLINE ="2033"`) is answered by srv[99] `InsertPacket obj=47
/// #1=2033` with 929 cell records `colid, row, …, text` that carry their
/// ABSOLUTE row (226..329).
library;

import 'dart:typed_data';

import '../cfw/dp_cache.dart';
import '../cfw/flush_call.dart';
import 'sap_grid.dart';
import 'sap_tree.dart';

/// One on-demand DataProvider object a creation queue declared.
class GridProviderObject {
  GridProviderObject(this.resultRow);

  /// The 1-based VARS row of its CreateObject _RESULT (the row the answer
  /// mints the object handle into: [FlushCall.resultHandles][row - 1]).
  final int resultRow;

  /// Its registration handle (`Handle =N`, what a DATAREQUEST names).
  int? handle;
  int? lineCount;
  int? optPacket;

  /// Its role (AssignProperty2: `DataTableOnDemand`, …) and grid shell
  /// (AssignDataObjToShell), joined from [dpPushBindings].
  String? role;
  String? shell;

  @override
  String toString() =>
      'GridProviderObject(row $resultRow h=$handle $role@$shell '
      'lc=$lineCount opt=$optPacket)';
}

/// Every `SAP.*OnDemand*` provider [call] creates, with its handle,
/// LineCount, OptPacket and (from the push bindings) role and shell.
/// [shellOf] resolves a binding that names its grid by an owner token
/// only (a control minted in an earlier queue).
List<GridProviderObject> gridProviderObjects(
  FlushCall call, {
  String? Function(String owner)? shellOf,
}) {
  final meta = verbMeta(call);
  final out = <GridProviderObject>[];
  final byRow = <String, GridProviderObject>{};
  int? num(String? v) => int.tryParse((v ?? '').trim());
  for (var i = 1; i <= call.verbs.length; i++) {
    final verb = call.verbs[i - 1];
    final m = meta[i - 1];
    if (verb == 'CreateObject') {
      final cls = verbArgs(call, i)
          .map((a) => a.$2)
          .firstWhere((v) => v.contains(_letterRx), orElse: () => '');
      final row = num(m.result);
      if (cls.toLowerCase().contains('ondemand') && row != null) {
        final p = GridProviderObject(row);
        out.add(p);
        byRow['$row'] = p;
      }
      continue;
    }
    final p = byRow[m.obj.trim()];
    if (p == null) continue;
    int? scalar() {
      for (final a in verbArgs(call, i)) {
        final n = num(a.$2);
        if (n != null) return n;
      }
      return null;
    }

    switch (verb) {
      case 'Handle':
        p.handle ??= scalar();
      case 'LineCount':
        p.lineCount ??= scalar();
      case 'OptPacket':
        p.optPacket ??= scalar();
    }
  }
  final bindings = dpPushBindings(call);
  final ownerShell = <String, String>{
    for (final b in bindings)
      if ((b.owner?.trim() ?? '').isNotEmpty &&
          (b.shell?.trim() ?? '').isNotEmpty)
        b.owner!.trim(): b.shell!.trim(),
  };
  for (final b in bindings) {
    if (b.handle == null || b.role == null) continue;
    var shell = b.shell?.trim();
    if (shell == null || shell.isEmpty) {
      final o = b.owner?.trim() ?? '';
      shell = o.isEmpty ? null : (shellOf?.call(o) ?? ownerShell[o]);
    }
    for (final p in out) {
      if (p.handle == b.handle && p.role == null) {
        p
          ..role = b.role
          ..shell = shell;
      }
    }
  }
  return out;
}

/// The server's own first-visible rows in [call]
/// (`SetFirstVisibleRowIDNumeric(row, subRow)` on a grid control, which
/// re-created grids get: srv[96] 288) as (shell, row).
List<(String, int)> gridFirstVisibleSets(
  FlushCall call, {
  String? Function(String owner)? shellOf,
}) {
  final meta = verbMeta(call);
  final ownerShell = <String, String>{
    for (final b in dpPushBindings(call))
      if ((b.owner?.trim() ?? '').isNotEmpty &&
          (b.shell?.trim() ?? '').isNotEmpty)
        b.owner!.trim(): b.shell!.trim(),
  };
  final out = <(String, int)>[];
  for (var i = 1; i <= call.verbs.length; i++) {
    if (call.verbs[i - 1] != 'SetFirstVisibleRowIDNumeric') continue;
    final own = meta[i - 1].objValue.trim();
    final row = int.tryParse((verbNamedArgs(call, i)['#1'] ?? '').trim());
    final shell = shellOf?.call(own) ?? ownerShell[own];
    if (shell != null && row != null && row > 0) out.add((shell, row));
  }
  return out;
}

/// What a provider object handle names: its grid and role.
typedef GridProviderRef = ({String shell, String role});

/// Fold the cell packets a DATAREQUEST reply ([rfc], one complete
/// OLE_FLUSH_CALL value) inserts into on-demand providers into [grids].
/// [providerOf] maps the InsertPacket's object handle back to its grid;
/// a packet whose object it does not know goes to [fallbackShell] (the
/// grid the session's in-flight DATAREQUEST asked, the reply being
/// solicited) when given. [covered] is the in-flight request's row span
/// per shell — rows inside it count as whole even where the provider
/// omitted an initial cell. [parsed] = [rfc] already parsed. Returns the
/// shells it touched.
Set<String> foldGridPacketCall(
  Uint8List rfc,
  Map<String, SapGridAssembler> grids, {
  required GridProviderRef? Function(String object) providerOf,
  String? fallbackShell,
  Map<String, (int, int)> covered = const {},
  FlushCall? parsed,
}) {
  final call = parsed ?? parseFlushCall(rfc);
  final packets = [
    for (final b in dpPushBindings(call))
      if (b.attach == 'InsertPacket' && b.role == null && b.provider != null) b,
  ];
  if (packets.isEmpty) return const {};
  final cache = DpCache()..ingestValue(rfc);
  final touched = <String>{};
  for (final b in packets) {
    final ref = providerOf(b.provider!);
    if (ref != null && ref.role != 'DataTableOnDemand') continue;
    final shell = ref?.shell ?? fallbackShell;
    final g = shell == null ? null : grids[shell];
    if (g == null) continue;
    var any = false;
    for (final u in b.urls) {
      final seg = cache.byUrl[u];
      final t = seg == null ? null : decodeNamedDpTable(seg);
      if (t != null && g.applyCellPacket(t, firstLine: b.firstline)) {
        any = true;
      }
    }
    if (!any) continue;
    if (covered[shell] case (final first, final last)) {
      g.markRowsCovered(first, last);
    }
    touched.add(shell!);
  }
  return touched;
}

// Patterns hoisted out of their call sites: a RegExp built per call is
// compiled per call.
final RegExp _letterRx = RegExp('[A-Za-z]');
